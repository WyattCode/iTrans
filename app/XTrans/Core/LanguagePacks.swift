import Foundation
import Translation

/// 一种语言的离线翻译包状态。
enum PackStatus: Equatable {
    case installed       // 已下载，可离线使用
    case downloadable    // 支持，但还没下载
    case unsupported     // 系统不支持
    case unknown         // 还没查询 / 查询失败

    var label: String {
        switch self {
        case .installed: return String(localized: "离线可用")
        case .downloadable: return String(localized: "可下载")
        case .unsupported: return String(localized: "不支持")
        case .unknown: return String(localized: "检查中…")
        }
    }
}

extension PackStatus {
    /// 一种语言有两个方向（X→伙伴、伙伴→X），系统对它们各回答一次。
    /// 用户在系统「翻译」里删了某种语言，我们这边却仍显示「已下载」——只问一个方向不可靠：**两个方向都装了才算已下载**；
    /// 只要有一个方向说「可下载」就是可下载；两个都不支持才是不支持；其余混合情况退回正向的回答（原来的行为）。
    static func combine(forward: PackStatus, backward: PackStatus) -> PackStatus {
        if forward == .installed && backward == .installed { return .installed }
        if forward == .downloadable || backward == .downloadable { return .downloadable }
        if forward == .unsupported && backward == .unsupported { return .unsupported }
        return forward
    }

    /// 诊断页里写的原始回答
    var rawName: String {
        switch self {
        case .installed: return "installed"
        case .downloadable: return "supported (downloadable)"
        case .unsupported: return "unsupported"
        case .unknown: return "unknown"
        }
    }
}

/// 语言包的数据来源。系统 `Translation` 框架只开放：查询状态、触发系统自带的下载界面。
/// 它不提供下载进度、体积和删除，所以这里也不假装有。
@MainActor
protocol LanguagePackBackend: AnyObject {
    func status(of language: LanguageOption, pairedWith partner: LanguageOption) async -> PackStatus
    /// 触发下载。成功返回 true；用户在系统弹窗里取消或出错返回 false。
    func download(_ language: LanguageOption, pairedWith partner: LanguageOption) async -> Bool
}

/// 每种语言配一个"伙伴语言"来查询：英语配中文，其余配英语。
/// （系统是按语言对查询的，已安装表示这两种语言的资源都在设备上。）
@MainActor
@Observable
final class LanguagePackStore {
    private(set) var statuses: [String: PackStatus] = [:]
    private(set) var downloading: Set<String> = []
    private(set) var lastError: String?
    /// 刚刚下载好的那一种语言（1.5 秒后清掉）：列表里高亮一下，再滑进「已下载」
    private(set) var justInstalled: String?
    @ObservationIgnored private let backend: LanguagePackBackend

    init(backend: LanguagePackBackend) {
        self.backend = backend
    }

    static func partner(for language: LanguageOption) -> LanguageOption {
        language.id == LanguageOption.en.id ? .zhHans : .en
    }

    func status(of language: LanguageOption) -> PackStatus { statuses[language.id] ?? .unknown }

    /// 正在下载的那一种（同一时间只会有一种）
    var downloadingLanguage: LanguageOption? {
        downloading.first.flatMap { id in LanguageOption.all.first { $0.id == id } }
    }
    var isDownloading: Bool { !downloading.isEmpty }

    var installedCount: Int { statuses.values.filter { $0 == .installed }.count }

    /// 先把所有语言的状态都查完，再一次性赋值：原来每查一种就改一次 `statuses`，设置页打开的动画期间界面被刷新十几次。
    /// 结果没变化时不赋值（不触发任何刷新）。
    func refresh() async {
        let base = statuses
        var fresh: [String: PackStatus] = [:]
        for language in LanguageOption.all {
            fresh[language.id] = await backend.status(of: language, pairedWith: Self.partner(for: language))
        }
        // 只合并「查询期间没被别处改过」的项：查询要十几个 await，这期间 `download()` 可能刚把某种语言刷成「已下载」，不能拿旧结果盖回去
        var merged = statuses
        for (id, status) in fresh where statuses[id] == base[id] { merged[id] = status }
        if merged != statuses { statuses = merged }
    }

    /// 诊断：系统对每种语言两个方向的原始回答 + 我们据此显示的状态（用户反馈「系统里没装、App 里显示已下载」时用来排查）。
    func diagnosticLines() async -> [String] {
        guard let backend = backend as? AppleLanguagePackBackend else { return ["(simulated backend: no system answers to show; system translation is unsupported in the simulator)"] }
        var lines: [String] = []
        for language in LanguageOption.all {
            let partner = Self.partner(for: language)
            let both = await backend.rawStatuses(of: language, pairedWith: partner)
            let shown = PackStatus.combine(forward: both.forward, backward: both.backward)
            let byText = await backend.textBasedStatus(of: language, pairedWith: partner)
            lines.append("\(language.nativeName) [\(language.id)]\n  \(language.id)->\(partner.id): \(both.forward.rawName)\n  \(partner.id)->\(language.id): \(both.backward.rawName)\n  by sample text: \(byText)\n  app shows: \(shown.rawName)")
        }
        return lines
    }

    /// 排查用：系统对一批我们 App 里没有的语言的回答（设置「翻译」里它们是「可供下载」）
    func extraDiagnosticLines() async -> [String] {
        guard let backend = backend as? AppleLanguagePackBackend else { return [] }
        var lines: [String] = []
        for id in ["ar", "pl", "nl", "th", "tr", "uk", "hi", "id", "vi"] {
            lines.append("\(id)->en: \(await backend.rawStatus(of: id))")
        }
        return lines
    }

    /// 页面刚推入时先别查：系统查询的结果会让界面刷新，正好落在推入动画的中间。等动画走完再查。
    func refreshAfterTransition() async {
        try? await Task.sleep(for: .milliseconds(600))
        guard !Task.isCancelled else { return }
        await refresh()
    }

    func refresh(_ language: LanguageOption) async {
        let status = await backend.status(of: language, pairedWith: Self.partner(for: language))
        if statuses[language.id] != status { statuses[language.id] = status }
    }

    /// 同一时间只下载一种：同时点第二种，会让系统翻译换掉会话配置、把第一种已经弹出的系统下载窗取消再重排，
    /// 两个来回切换，系统窗和界面上的菊花就一直闪。第二次点击直接忽略（界面上其它「下载」按钮此时是灰的）。
    func download(_ language: LanguageOption) async {
        guard downloading.isEmpty else { return }
        downloading.insert(language.id)
        lastError = nil
        let ok = await backend.download(language, pairedWith: Self.partner(for: language))
        downloading.remove(language.id)
        if !ok { lastError = String(localized: "没有下载成功。可以稍后再试，或到系统设置里管理翻译语言。") }
        await refresh(language)
        if status(of: language) == .installed {
            justInstalled = language.id
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(1.5))
                if self?.justInstalled == language.id { self?.justInstalled = nil }
            }
        }
    }
}

// MARK: - 系统实现

@MainActor
final class AppleLanguagePackBackend: LanguagePackBackend {
    private let engine: AppleTranslationEngine

    init(engine: AppleTranslationEngine) {
        self.engine = engine
    }

    func status(of language: LanguageOption, pairedWith partner: LanguageOption) async -> PackStatus {
        let both = await rawStatuses(of: language, pairedWith: partner)
        return PackStatus.combine(forward: both.forward, backward: both.backward)
    }

    /// 系统对这种语言两个方向各自的回答（诊断页也用它）。
    /// 每次查询都新建一个 `LanguageAvailability`：不让一个长期持有的实例替我们缓存（用户在系统设置里删了语言包之后要能马上读到）
    func rawStatuses(of language: LanguageOption, pairedWith partner: LanguageOption) async -> (forward: PackStatus, backward: PackStatus) {
        let availability = LanguageAvailability()
        func map(_ status: LanguageAvailability.Status) -> PackStatus {
            switch status {
            case .installed: return .installed
            case .supported: return .downloadable
            case .unsupported: return .unsupported
            @unknown default: return .unknown
            }
        }
        let forward = map(await availability.status(from: language.language, to: partner.language))
        let backward = map(await availability.status(from: partner.language, to: language.language))
        return (forward, backward)
    }

    /// 排查用：直接问系统某个（我们 App 不支持的）语言到英语的状态，看系统是不是对所有语言都回答「已安装」
    func rawStatus(of identifier: String) async -> String {
        let availability = LanguageAvailability()
        switch await availability.status(from: Locale.Language(identifier: identifier), to: Locale.Language(identifier: "en")) {
        case .installed: return "installed"
        case .supported: return "supported (downloadable)"
        case .unsupported: return "unsupported"
        @unknown default: return "unknown"
        }
    }

    /// 另一种问法：拿一句这种语言的示例文字去问系统「翻成伙伴语言要不要下载」（`status(for:to:)`）。
    /// 和 `status(from:to:)` 走的不是同一个入口，诊断页里并排放，看系统两种回答是否一致。
    func textBasedStatus(of language: LanguageOption, pairedWith partner: LanguageOption) async -> String {
        let availability = LanguageAvailability()
        do {
            let status = try await availability.status(for: VoiceCatalog.sample(for: language), to: partner.language)
            switch status {
            case .installed: return "installed"
            case .supported: return "supported (downloadable)"
            case .unsupported: return "unsupported"
            @unknown default: return "unknown"
            }
        } catch {
            return "error: \(error.localizedDescription)"
        }
    }

    func download(_ language: LanguageOption, pairedWith partner: LanguageOption) async -> Bool {
        do {
            try await engine.prepare(from: language, to: partner)
            // 状态要求两个方向都装好才算已下载：正向准备完了、反向还没装（系统分两个方向各报一次）时，再准备反向，
            // 不然点了「下载」没有任何系统弹窗、状态也永远不变
            let backward = await rawStatuses(of: language, pairedWith: partner).backward
            if backward != .installed { try await engine.prepare(from: partner, to: language) }
            return true
        } catch {
            return false
        }
    }
}

/// 模拟器 / 演示用：系统翻译在模拟器上不受支持，所以用一份假的状态让界面可以演示。
/// 只在使用演示引擎时才会被用到，不会出现在真机的正常使用里。
@MainActor
final class SimulatedLanguagePackBackend: LanguagePackBackend {
    private var installed: Set<String>
    var downloadDelay: Duration = .seconds(1.2)

    init(installed: Set<String> = ["zh-Hans", "en", "ja"]) {
        self.installed = installed
    }

    func status(of language: LanguageOption, pairedWith partner: LanguageOption) async -> PackStatus {
        installed.contains(language.id) ? .installed : .downloadable
    }

    func download(_ language: LanguageOption, pairedWith partner: LanguageOption) async -> Bool {
        try? await Task.sleep(for: downloadDelay)
        installed.insert(language.id)
        return true
    }
}
