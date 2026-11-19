import SwiftUI

/// C2 · 选文字并翻译：图片里识别出的文字（或粘贴的文字）逐行列出并翻译，
/// 勾选要用的行，一键放进对话（算作对方的一条消息），或朗读译文。
struct TranslateLinesView: View {
    enum Source {
        case image(UIImage)
        case lines([String])
    }

    let session: ConversationSession
    let source: Source
    let title: LocalizedStringKey
    let onSent: () -> Void
    var recognizer: TextRecognizing = VisionTextRecognizer()
    /// 在顶部显示原图。左右分屏时原图单独放在左边，这里不再重复。
    var showsImage = true
    /// 双栏页（Duo）：识别 / 翻译的状态由两块屏共用（左屏图片上的框和右屏的行是同一份）
    var sharedModel: LinesModel?

    @State private var ownModel = LinesModel()
    private var model: LinesModel { sharedModel ?? ownModel }
    @Environment(\.inDuoPane) private var inDuoPane

    var body: some View {
        // Duo 的屏里推进来的页面：系统导航栏是隐藏 / 竖排的，没有返回——自己画页头（和设置、历史的二级页一致）
        PaneAware { duo in
            if duo && showsImage {
                PaneDetailPage(title: title) { linesBody }
            } else {
                linesBody
            }
        }
    }

    private var linesBody: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if showsImage, case .image(let image) = source {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: 180)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .frame(maxWidth: .infinity)
                            .accessibilityHidden(true)
                    }
                    content
                }
                .padding(inDuoPane ? 20 : 16)          // Duo 的屏里和页头 / 磁贴 / 短语同一条 20pt 边
            }
            actionBar
        }
        .background { PageBackground() }
        .containerBackground(.clear, for: .navigation)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.load(source: source, session: session, recognizer: recognizer) }
        .onDisappear { session.stopSpeaking() }          // 离开页面 / 发送后，正在朗读的译文要停（原来没有停止的办法）
    }

    // MARK: 内容

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .recognizing:
            progress("正在识别图片里的文字…")
        case .empty:
            note("没有识别到文字", "换一张更清晰、文字更大的图片试试。", icon: "text.magnifyingglass")
        case .failed(let message):
            note("出错了", LocalizedStringKey(message), icon: "exclamationmark.triangle")
        case .translating, .ready:
            Text("\(session.them.nativeName) → \(session.me.nativeName) · 共 \(model.items.count) 段，已选 \(model.selectedCount) 段")
                .font(Theme.caption)
                .foregroundStyle(Theme.mut)
            if model.omitted > 0 {
                Text("另有 \(model.omitted) 行没有翻译（一次最多 \(LinesModel.maxLines) 行）")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.err)
            }
            ForEach(Bindable(model).items) { $item in
                LineRow(item: $item, failed: model.translationError != nil)
            }
            if case .translating = model.phase {
                progress("正在翻译…")
            }
            if let error = model.translationError {
                Text(error).font(Theme.caption).foregroundStyle(Theme.err)
                Button("重试") { Task { await model.translateAll(session: session) } }
                    .font(.system(.footnote).weight(.semibold))
                    .foregroundStyle(Theme.fg)
                    .frame(minHeight: 44)
            }
        }
    }

    private func progress(_ text: LocalizedStringKey) -> some View {
        HStack(spacing: 10) {
            ProgressView()
            Text(text).font(Theme.caption).foregroundStyle(Theme.sub)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    private func note(_ title: LocalizedStringKey, _ detail: LocalizedStringKey, icon: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 28)).foregroundStyle(Theme.mut)
            Text(title).font(.system(.headline)).foregroundStyle(Theme.fg)
            Text(detail).font(Theme.caption).foregroundStyle(Theme.sub).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }

    // MARK: 底栏

    private var actionBar: some View {
        HStack(spacing: 10) {
            Button {
                session.speak(LinesModel.speechText(model.selectedTranslations, for: session.me), in: session.me)
            } label: {
                Label("朗读", systemImage: "speaker.wave.2")
                    .font(.system(.subheadline).weight(.semibold))
                    .foregroundStyle(Theme.fg)
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .glass(in: Capsule())
            }
            .disabled(model.selectedTranslations.isEmpty)

            Button {
                session.addIncoming(
                    source: model.selectedOriginals.joined(separator: "\n"),
                    translated: model.selectedTranslations.joined(separator: "\n"),
                    kind: isImage ? .photo : .paste
                )
                onSent()
            } label: {
                Label("发送到对话", systemImage: "arrow.up")
                    .font(.system(.subheadline).weight(.semibold))
                    .foregroundStyle(Theme.fg)
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .glass(in: Capsule(), tint: Theme.meFill, interactive: true)
            }
            .disabled(model.selectedTranslations.isEmpty)
        }
        .opacity(model.selectedTranslations.isEmpty ? 0.5 : 1)
        .padding(.horizontal, inDuoPane ? 20 : 16)
        .padding(.vertical, 10)
    }

    private var isImage: Bool {
        if case .image = source { return true }
        return false
    }
}

// MARK: - 一行

private struct LineRow: View {
    @Binding var item: LinesModel.Item
    /// 翻译整体失败了：没有译文的行不再转圈
    var failed = false

    var body: some View {
        Button {
            item.selected.toggle()
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: item.selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22))
                    .foregroundStyle(item.selected ? Theme.fg : Theme.mut)
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.original)
                        .font(.system(.footnote))
                        .foregroundStyle(Theme.sub)
                    if let translation = item.translation {
                        Text(translation)
                            .font(.system(.body).weight(.semibold))
                            .foregroundStyle(Theme.fg)
                    } else if failed {
                        Text("未翻译").font(Theme.caption).foregroundStyle(Theme.err)
                    } else {
                        ThinkingDots()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(14)
            .glass(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(item.selected ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: - 模型

@MainActor
@Observable
final class LinesModel {
    struct Item: Identifiable, Equatable {
        let id = UUID()
        let original: String
        var translation: String?
        var selected = true
    }

    enum Phase: Equatable {
        case recognizing, translating, ready, empty
        case failed(String)
    }

    private(set) var phase: Phase = .recognizing
    var items: [Item] = []
    /// 图片里每一行的位置（归一化，原点在左下角），和 `items` 一一对应；粘贴的文字没有
    private(set) var boxes: [CGRect] = []
    private(set) var translationError: String?
    /// 超过上限、没有被翻译的行数
    private(set) var omitted = 0
    /// 一次最多处理的行数：整篇文档粘进来时不会一口气排几千个翻译请求
    nonisolated static let maxLines = 100
    @ObservationIgnored private var loaded = false

    /// 已选且已有译文的行数（和"发送"实际会带上的一致，不把还没翻译出来的算进去）
    var selectedCount: Int { usable.count }
    /// 只有"已选且已有译文"的行才会被发送
    private var usable: [Item] { items.filter { $0.selected && $0.translation != nil } }
    var selectedOriginals: [String] { usable.map(\.original) }
    var selectedTranslations: [String] { usable.compactMap(\.translation) }

    func load(source: TranslateLinesView.Source, session: ConversationSession, recognizer: TextRecognizing) async {
        guard !loaded else { return }
        loaded = true
        let texts: [String]
        switch source {
        case .lines(let lines):
            texts = lines
        case .image(let image):
            phase = .recognizing
            do {
                let found = try await recognizer.recognize(image, languages: [session.them.ocrCode, session.me.ocrCode])
                texts = found.map(\.text)
                boxes = found.prefix(Self.maxLines).map(\.box)
            } catch {
                phase = .failed(error.localizedDescription)
                return
            }
        }
        guard !texts.isEmpty else { phase = .empty; return }
        omitted = max(0, texts.count - Self.maxLines)
        items = texts.prefix(Self.maxLines).map { Item(original: $0) }
        await translateAll(session: session)
    }

    /// 朗读用的文字：每行补上句末标点（已经有的不重复），这样行与行之间会有停顿。
    nonisolated static func speechText(_ lines: [String], for language: LanguageOption) -> String {
        let cjk = language.isChinese || language.id == "ja"
        let terminator = cjk ? "。" : "."
        let enders: Set<Character> = ["。", ".", "!", "?", "！", "？", "…", "，", ",", ";", "；", ":", "："]
        return lines.map { line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let last = trimmed.last, !enders.contains(last) else { return trimmed }
            return trimmed + terminator
        }
        .filter { !$0.isEmpty }
        .joined(separator: cjk ? "" : " ")
    }

    func translateAll(session: ConversationSession) async {
        phase = .translating
        translationError = nil
        // 一行失败不拖累后面的行（原来遇到第一个错误就停，后面全是「未翻译」，重试又卡在同一行）；
        // 连着两行都失败多半是没网 / 引擎不可用，才停下来等用户点重试。被取消就直接停
        var failuresInARow = 0
        var lastError: String?          // 循环跑完再写进 translationError：边跑边写的话，还没轮到的行会立刻显示红色「未翻译」、「重试」也提前冒出来
        loop: for index in items.indices where items[index].translation == nil {
            if Task.isCancelled { break }
            do {
                items[index].translation = try await session.translateText(items[index].original,
                                                                          from: session.them, to: session.me)
                failuresInARow = 0
            } catch is CancellationError {
                break loop
            } catch let failure as TranslationFailure {
                // 本地引擎：被取消直接停（不算失败）；「不可用」（没语言包、用户关掉了系统的下载窗）下一行也一样，直接停，别让下载窗再弹一次
                if case .unavailable = failure { lastError = failure.localizedDescription }
                break loop
            } catch {
                lastError = error.localizedDescription
                failuresInARow += 1
                if failuresInARow >= 2 { break loop }
            }
        }
        translationError = lastError
        phase = .ready
    }
}
