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

    var selection: AppLanguage = .system

    /// 实际用的语言代码（工程里有的那几种之一）
    var code: String {
        if selection != .system { return selection.rawValue }
        return Self.systemCode
    }

    var locale: Locale { selection == .system ? Locale.current : Locale(identifier: code) }

    var bundle: Bundle {
        let code = code
        lock.lock(); defer { lock.unlock() }
        if let cached = bundles[code] { return cached }
        let found = Bundle.main.path(forResource: code, ofType: "lproj").flatMap(Bundle.init(path:)) ?? .main
        bundles[code] = found
        return found
    }

    /// 系统给 App 选的语言：在工程支持的语言里，按系统的偏好顺序挑第一种
    private static var systemCode: String {
        let available = Bundle.main.localizations.filter { $0 != "Base" }
        let wanted = UserDefaults.standard.stringArray(forKey: "AppleLanguages") ?? Locale.preferredLanguages
        return Bundle.preferredLocalizations(from: available, forPreferences: wanted).first ?? "zh-Hans"
    }

    @ObservationIgnored private var bundles: [String: Bundle] = [:]
    @ObservationIgnored private let lock = NSLock()
}

extension String {
    /// 盖住系统那个只带一个参数的写法：全工程的 `String(localized: "…")` 不用改，就都跟着设置里选的界面语言走。
    init(localized key: String.LocalizationValue) {
        let state = AppLanguageState.shared
        self.init(localized: key, table: nil, bundle: state.bundle, locale: state.locale, comment: nil)
    }
}
