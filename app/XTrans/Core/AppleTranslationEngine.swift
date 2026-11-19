import SwiftUI
import Translation

/// 基于系统 `Translation` 框架的端侧翻译。
/// 系统只允许在 SwiftUI 视图里通过 `.translationTask` 拿到 `TranslationSession`，
/// 所以这里用一个"请求队列 + 隐藏宿主视图"的结构：translate() 入队并切换配置，宿主视图的任务负责处理队列。
@MainActor
@Observable
final class AppleTranslationEngine: TranslationEngine {
    let name = EngineDisplay.appleID

    /// 绑给宿主视图的 `.translationTask`；换语言对或需要重跑时会变化 / invalidate。
    var configuration: TranslationSession.Configuration?

    private struct Request {
        let id: UUID
        /// nil 表示"只下载语言包"（prepareTranslation），不翻译文字
        let text: String?
        let source: LanguageOption
        let target: LanguageOption
        let continuation: CheckedContinuation<String, Error>
    }

    @ObservationIgnored private var pending: [Request] = []
    @ObservationIgnored private var currentPair: (String, String)?
    /// 宿主视图正在处理的批数（被取消的旧一批和新一批可能短暂重叠，所以是计数不是开关）
    @ObservationIgnored private var drainDepth = 0
    /// 已经被宿主接走、之后才被调用方取消的请求：轮到它时不再翻译
    @ObservationIgnored private var cancelled: Set<UUID> = []
    /// 已被宿主接走、还没处理完的请求（只有它们被取消才需要记进 `cancelled`，不然已经结束的请求的 id 会永远留在集合里）
    @ObservationIgnored private var inFlight: Set<UUID> = []

    /// 宿主视图栈：系统的「下载语言」窗口是从宿主视图（`.translationTask` 所在的视图）弹出的。根上那个宿主在最底层，
    /// 设置 / 语言选择这些盖在上面的弹层里点「下载」时，系统窗口要从最底层往上弹，容易被盖住或出现得很生硬。
    /// 所以每个弹层出现时也放一个宿主并入栈，**只有栈顶那个宿主拿到配置**（两个宿主同时拿到会各跑一遍、各弹一次窗）。
    private(set) var hostStack: [UUID] = []
    func pushHost(_ id: UUID) { if !hostStack.contains(id) { hostStack.append(id) } }
    func popHost(_ id: UUID) { hostStack.removeAll { $0 == id } }
    /// 这个宿主该不该拿到配置：`hostID == nil` 是根上的宿主（栈空时才轮到它）
    func configuration(for hostID: UUID?) -> TranslationSession.Configuration? {
        hostStack.last == hostID ? configuration : nil
    }

    /// 触发系统自带的语言包下载界面（弹窗由系统负责，这里拿不到进度）。
    func prepare(from: LanguageOption, to: LanguageOption) async throws {
        _ = try await enqueue(text: nil, from: from, to: to)
    }

    /// 请求在多久内没被宿主视图接走，就判定为系统没有响应（例如在模拟器上，或用户关掉了系统弹窗）。
    static let pickupTimeout: Duration = .seconds(10)

    func translate(_ text: String, from: LanguageOption, to: LanguageOption) async throws -> String {
        try await enqueue(text: text, from: from, to: to)
    }

    private func enqueue(text: String?, from: LanguageOption, to: LanguageOption) async throws -> String {
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending.append(Request(id: id, text: text, source: from, target: to, continuation: continuation))
                scheduleTimeout(for: id)
                let pair = (from.id, to.id)
                if currentPair?.0 == pair.0, currentPair?.1 == pair.1, configuration != nil {
                    configuration?.invalidate()
                } else {
                    currentPair = pair
                    configuration = TranslationSession.Configuration(source: from.language, target: to.language)
                }
            }
        } onCancel: {
            Task { @MainActor in
                if !self.fail(id, with: TranslationFailure.cancelled), self.inFlight.contains(id) { self.cancelled.insert(id) }
            }
        }
    }

    /// 只对"还在排队、没被接走"的请求生效；已被宿主视图接走的请求不受影响（可能正在下载语言包）。
    @discardableResult
    private func fail(_ id: UUID, with error: Error) -> Bool {
        guard let index = pending.firstIndex(where: { $0.id == id }) else { return false }
        let request = pending.remove(at: index)
        request.continuation.resume(throwing: error)
        return true
    }

    private func scheduleTimeout(for id: UUID, deferrals: Int = 0) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.pickupTimeout)
            // 宿主视图正在处理别的请求（比如在等系统的语言包下载弹窗）：排在后面的请求不算「没人接」，再等一轮——
            // 但最多顺延 6 轮：宿主挂住（`translate` 永远不返回）时不能让后面的请求永远等下去还不报错
            if let self, self.drainDepth > 0, deferrals < 6, self.pending.contains(where: { $0.id == id }) {
                self.scheduleTimeout(for: id, deferrals: deferrals + 1)
                return
            }
            self?.fail(id, with: TranslationFailure.unavailable(
                String(localized: "系统翻译没有响应。需要在真机上运行，并在系统里下载所需的语言包。")))
        }
    }

    /// 宿主视图的任务回调：处理当前语言对的所有排队请求。
    fileprivate func drain(using session: TranslationSession) async {
        guard let pair = currentPair else { return }
        let mine = pending.filter { ($0.source.id, $0.target.id) == pair }
        pending.removeAll { req in mine.contains { $0.id == req.id } }
        drainDepth += 1
        mine.forEach { inFlight.insert($0.id) }
        defer { drainDepth -= 1; mine.forEach { inFlight.remove($0.id); cancelled.remove($0.id) } }
        for (index, request) in mine.enumerated() {
            if cancelled.remove(request.id) != nil {
                request.continuation.resume(throwing: TranslationFailure.cancelled)
                continue
            }
            do {
                if let text = request.text {
                    let response = try await session.translate(text)
                    request.continuation.resume(returning: response.targetText)
                } else {
                    try await session.prepareTranslation()
                    request.continuation.resume(returning: "")
                }
            } catch {
                // 宿主任务被取消（换了语言对、或同一语言对又来了请求导致重新配置）：还没处理的请求重新排队，等下一次接走，不当成失败
                if Task.isCancelled {         // 只有宿主任务真的被取消才重新排队；单独抛出的 CancellationError（系统弹窗被关掉）算失败，不然会反复弹
                    let rest = Array(mine[index...])
                    pending.insert(contentsOf: rest, at: 0)
                    // 光放回队列没有人再来接：补上拾取超时（原来的可能已过期），并重新触发宿主任务
                    for request in rest { scheduleTimeout(for: request.id) }
                    Task { @MainActor [weak self] in
                        guard let self, !self.pending.isEmpty else { return }
                        self.configuration?.invalidate()
                    }
                    return
                }
                request.continuation.resume(throwing: TranslationFailure.unavailable(error.localizedDescription))
            }
        }
        // 处理期间若又来了别的语言对的请求，切换过去继续
        if let next = pending.first {
            currentPair = (next.source.id, next.target.id)
            configuration = TranslationSession.Configuration(source: next.source.language, target: next.target.language)
        }
    }
}

/// 隐藏的宿主视图：把它放进视图树，`AppleTranslationEngine` 才能拿到会话。
struct TranslationHost: ViewModifier {
    let engine: AppleTranslationEngine
    /// nil = 根上的宿主；弹层里的宿主有自己的编号（见 `AppleTranslationEngine.hostStack`）
    var hostID: UUID?

    func body(content: Content) -> some View {
        content.translationTask(engine.configuration(for: hostID)) { session in
            await engine.drain(using: session)
        }
    }
}

extension View {
    func translationHost(_ engine: AppleTranslationEngine?) -> some View {
        modifier(OptionalTranslationHost(engine: engine))
    }
}

private struct OptionalTranslationHost: ViewModifier {
    let engine: AppleTranslationEngine?
    func body(content: Content) -> some View {
        if let engine {
            content.modifier(TranslationHost(engine: engine))
        } else {
            content
        }
    }
}

private struct TranslationEngineKey: EnvironmentKey {
    static let defaultValue: AppleTranslationEngine? = nil
}
extension EnvironmentValues {
    /// 系统翻译引擎（模拟器 / 演示时没有）：弹层里的宿主视图要用它
    var appleTranslationEngine: AppleTranslationEngine? {
        get { self[TranslationEngineKey.self] }
        set { self[TranslationEngineKey.self] = newValue }
    }
}

/// 放在弹层（sheet / fullScreenCover）的内容上：弹层在屏幕上时，它成为栈顶宿主，系统「下载语言」窗口从弹层里弹出。
private struct TranslationModalHost: ViewModifier {
    @Environment(\.appleTranslationEngine) private var engine
    @State private var id = UUID()
    func body(content: Content) -> some View {
        if let engine {
            content
                .modifier(TranslationHost(engine: engine, hostID: id))
                .onAppear { engine.pushHost(id) }
                .onDisappear { engine.popHost(id) }
        } else {
            content
        }
    }
}

extension View {
    func translationModalHost() -> some View { modifier(TranslationModalHost()) }
}
