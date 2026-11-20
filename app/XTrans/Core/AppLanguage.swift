import Foundation
import Observation

/// 界面语言。「跟随系统」= 用系统给 App 选的那一种；其余是用户在设置里手动选的。
enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case zhHans = "zh-Hans"
    case zhHant = "zh-Hant"
    case en, ja, ko

    var id: String { rawValue }

    /// 每种语言用它自己的写法（切错了也能认出来、切回去）
    var title: String {
        switch self {
        case .system: return String(localized: "跟随系统")
        case .zhHans: return String(localized: "简体中文")
        case .zhHant: return String(localized: "繁體中文")
        case .en: return "English"
        case .ja: return "日本語"
        case .ko: return "한국어"
        }
    }
}

/// 现在界面用哪种语言。选完立即生效，不用重启：
/// - `Text("…")` 跟着根视图的 `\.locale` 环境值走；
/// - `String(localized:)` 走下面那个同名的初始化方法，从选中语言的 `.lproj` 里取。它读了这里的 `selection`，
///   所以在视图 `body` 里调用过它的界面，换语言时会自己重新算一遍。
/// 系统自己画的界面（权限弹窗、相册选择器等）要等下次打开 App 才跟着变——那是靠写 `AppleLanguages` 实现的。
@Observable
final class AppLanguageState {
    static let shared = AppLanguageState()

    /// 设置里选的那一项。改它会重新算一遍下面三样。
    var selection: AppLanguage = .system { didSet { refresh() } }

    /// 实际用的语言代码（工程里有的那几种之一）
    private(set) var code: String
    /// 日期、数字、语言名字按它来写
    private(set) var locale: Locale
    /// `String(localized:)` 从它里面取文案
    @ObservationIgnored private(set) var bundle: Bundle

    private init() {
        (code, locale, bundle) = Self.resolve(.system)
    }

    /// 系统的语言偏好变了（或者刚改完 `AppleLanguages`）之后调用：「跟随系统」要重新看一眼系统给的是哪种
    func refresh() {
        let (code, locale, bundle) = Self.resolve(selection)
        self.bundle = bundle
        if code != self.code { self.code = code }
        if locale != self.locale { self.locale = locale }
    }

    /// 在工程支持的语言里，按偏好顺序挑第一种能对上的（`zh-HK` 对繁体，`fr` 这种没有的跳过看下一个）
    static func pick(from available: [String], preferences: [String]) -> String {
        Bundle.preferredLocalizations(from: available, forPreferences: preferences).first ?? "zh-Hans"
    }

    private static func resolve(_ selection: AppLanguage) -> (String, Locale, Bundle) {
        let code: String
        let locale: Locale
        if selection != .system {
            code = selection.rawValue
            locale = Locale(identifier: code)
        } else {
            // 系统给 App 选的语言：在工程支持的语言里，按系统的偏好顺序挑第一种
            let available = Bundle.main.localizations.filter { $0 != "Base" }
            let wanted = UserDefaults.standard.stringArray(forKey: "AppleLanguages") ?? Locale.preferredLanguages
            code = pick(from: available, preferences: wanted)
            // 正常情况下就是系统当前的地区设置（带着 24 小时制等个人偏好）。
            // 只有刚从手动选的语言切回「跟随系统」、系统的那份还没跟上时，才自己拼一个
            let current = Locale.current
            let currentCode = Bundle.preferredLocalizations(from: available, forPreferences: [current.identifier(.bcp47)]).first
            if currentCode == code { locale = current }
            else { locale = Locale(identifier: wanted.first { Bundle.preferredLocalizations(from: available, forPreferences: [$0]).first == code } ?? code) }
        }
        let bundle = Bundle.main.path(forResource: code, ofType: "lproj").flatMap(Bundle.init(path:)) ?? .main
        return (code, locale, bundle)
    }
}

extension String {
    /// 盖住系统那个只带一个参数的写法：全工程的 `String(localized: "…")` 不用改，就都跟着设置里选的界面语言走。
    init(localized key: String.LocalizationValue) {
        let state = AppLanguageState.shared
        self.init(localized: key, table: nil, bundle: state.bundle, locale: state.locale, comment: nil)
    }
}

extension Date {
    /// 按界面语言写日期和时间（系统自带的 `formatted(date:time:)` 只认系统语言：界面切成韩文，日期还是「2026年11月20日」）
    func appFormatted(date: Date.FormatStyle.DateStyle, time: Date.FormatStyle.TimeStyle) -> String {
        formatted(Date.FormatStyle(date: date, time: time, locale: AppLanguageState.shared.locale))
    }
}
