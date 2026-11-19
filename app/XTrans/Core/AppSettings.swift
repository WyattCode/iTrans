import Foundation
import SwiftUI

enum Appearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: return String(localized: "跟随系统")
        case .light: return String(localized: "浅色")
        case .dark: return String(localized: "深色")
        }
    }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

/// 用户设置，存在 UserDefaults 里。只放真正需要的（设计稿 S1）。
final class AppSettings: ObservableObject {
    static let defaultSpeechRate: Float = 0.5
    static let speechRateRange: ClosedRange<Float> = 0.35...0.6
    static let silenceRange: ClosedRange<Double> = 0.8...2.0

    private let defaults: UserDefaults

    @Published var appearance: Appearance { didSet { defaults.set(appearance.rawValue, forKey: Key.appearance) } }
    /// 语音对话里，翻译完成后自动朗读译文
    @Published var autoSpeak: Bool { didSet { defaults.set(autoSpeak, forKey: Key.autoSpeak) } }
    @Published var speechRate: Float { didSet { defaults.set(speechRate, forKey: Key.speechRate) } }
    /// 每种语言选的朗读声音：朗读语言代码 → 声音标识（没选 = 系统默认）
    @Published var voiceIDs: [String: String] { didSet { defaults.set(voiceIDs, forKey: Key.voices) } }
    /// 停顿多久算一句话说完（秒）
    @Published var silenceTimeout: Double { didSet { defaults.set(silenceTimeout, forKey: Key.silence) } }
    /// 是否保存对话历史（关掉后新的对话不再落盘）
    @Published var saveHistory: Bool { didSet { defaults.set(saveHistory, forKey: Key.saveHistory) } }
    /// 双屏摆放：自动（铰链半开时左右分屏）/ 始终左右分屏 / 始终上下分屏
    @Published var tentMode: TentMode { didSet { defaults.set(tentMode.rawValue, forKey: Key.tent) } }
    /// 界面方案（只在 iPhone Duo 内屏横向生效）
    @Published var onboardingDone: Bool { didSet { defaults.set(onboardingDone, forKey: Key.onboarding) } }
    /// 上次选的语言（下次启动沿用）
    @Published var meLanguageID: String { didSet { defaults.set(meLanguageID, forKey: Key.me) } }
    @Published var themLanguageID: String { didSet { defaults.set(themLanguageID, forKey: Key.them) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        appearance = Appearance(rawValue: defaults.string(forKey: Key.appearance) ?? "") ?? .system
        autoSpeak = defaults.object(forKey: Key.autoSpeak) as? Bool ?? true
        let rate = defaults.object(forKey: Key.speechRate) as? Float ?? Self.defaultSpeechRate
        speechRate = min(max(rate, Self.speechRateRange.lowerBound), Self.speechRateRange.upperBound)
        tentMode = TentMode(rawValue: defaults.string(forKey: Key.tent) ?? "") ?? .auto
        voiceIDs = defaults.dictionary(forKey: Key.voices) as? [String: String] ?? [:]
        let silence = defaults.object(forKey: Key.silence) as? Double ?? 1.2
        silenceTimeout = min(max(silence, Self.silenceRange.lowerBound), Self.silenceRange.upperBound)
        saveHistory = defaults.object(forKey: Key.saveHistory) as? Bool ?? true
        onboardingDone = defaults.bool(forKey: Key.onboarding)
        meLanguageID = defaults.string(forKey: Key.me) ?? LanguageOption.zhHans.id
        themLanguageID = defaults.string(forKey: Key.them) ?? LanguageOption.en.id
    }

    /// 会影响对话 / 语音组件的设置，用来在变化时同步（外观由视图直接读取）。
    struct Snapshot: Equatable {
        var autoSpeak: Bool
        var saveHistory: Bool
        var speechRate: Float
        var silenceTimeout: Double
        var voiceIDs: [String: String]
    }

    var snapshot: Snapshot {
        Snapshot(autoSpeak: autoSpeak, saveHistory: saveHistory, speechRate: speechRate, silenceTimeout: silenceTimeout,
                 voiceIDs: voiceIDs)
    }

    var meLanguage: LanguageOption { LanguageOption.all.first { $0.id == meLanguageID } ?? .zhHans }
    var themLanguage: LanguageOption { LanguageOption.all.first { $0.id == themLanguageID } ?? .en }

    /// 把全部设置恢复成默认值（不动"是否看过引导"）。
    func resetToDefaults() {
        appearance = .system
        autoSpeak = true
        speechRate = Self.defaultSpeechRate
        voiceIDs = [:]
        tentMode = .auto
        silenceTimeout = 1.2
        saveHistory = true
    }

    private enum Key {
        static let appearance = "settings.appearance"
        static let autoSpeak = "settings.autoSpeak"
        static let speechRate = "settings.speechRate"
        static let tent = "settings.tentMode"
        static let voices = "settings.voiceIDs"
        static let silence = "settings.silenceTimeout"
        static let saveHistory = "settings.saveHistory"
        static let onboarding = "settings.onboardingDone"
        static let me = "settings.meLanguage"
        static let them = "settings.themLanguage"
    }
}
