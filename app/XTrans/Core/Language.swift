import Foundation

/// 一种可选语言。`id` 是翻译框架用的语言标识，`speechLocale` 给语音识别，`ttsCode` 给朗读。
struct LanguageOption: Identifiable, Hashable, Sendable {
    let id: String
    let nativeName: String
    let speechLocale: String
    let ttsCode: String

    var language: Locale.Language { Locale.Language(identifier: id) }
    var isChinese: Bool { id.hasPrefix("zh") }

    /// 历史列表里的语言对简称，如 "中 ⇄ EN"
    var shortName: String {
        switch id {
        case "zh-Hans": return String(localized: "语言简称：中文")
        case "ja": return String(localized: "语言简称：日语")
        case "ko": return String(localized: "语言简称：韩语")
        default: return id.uppercased()
        }
    }

    static let zhHans = LanguageOption(id: "zh-Hans", nativeName: "中文", speechLocale: "zh-CN", ttsCode: "zh-CN")
    static let en = LanguageOption(id: "en", nativeName: "English", speechLocale: "en-US", ttsCode: "en-US")

    /// 按标识查语言；找不到（或没记录）返回 nil。
    static func with(id: String?) -> LanguageOption? {
        guard let id else { return nil }
        return all.first { $0.id == id }
    }

    static let all: [LanguageOption] = [
        .zhHans,
        .en,
        LanguageOption(id: "ja", nativeName: "日本語", speechLocale: "ja-JP", ttsCode: "ja-JP"),
        LanguageOption(id: "ko", nativeName: "한국어", speechLocale: "ko-KR", ttsCode: "ko-KR"),
        LanguageOption(id: "es", nativeName: "Español", speechLocale: "es-ES", ttsCode: "es-ES"),
        LanguageOption(id: "fr", nativeName: "Français", speechLocale: "fr-FR", ttsCode: "fr-FR"),
        LanguageOption(id: "de", nativeName: "Deutsch", speechLocale: "de-DE", ttsCode: "de-DE"),
        LanguageOption(id: "it", nativeName: "Italiano", speechLocale: "it-IT", ttsCode: "it-IT"),
        LanguageOption(id: "pt", nativeName: "Português", speechLocale: "pt-BR", ttsCode: "pt-BR"),
        LanguageOption(id: "ru", nativeName: "Русский", speechLocale: "ru-RU", ttsCode: "ru-RU"),
    ]
}

/// 界面里需要按"屏幕主人的语言"显示的少量文案。其他语言先退回英文。
enum Strings {
    static func emptyTitle(_ lang: LanguageOption) -> String {
        lang.isChinese ? "轻点麦克风，开始说话" : "Tap the mic and speak"
    }
    static func emptyHint(_ lang: LanguageOption) -> String {
        lang.isChinese ? "自动识别你和对方的语言，也可以按住说话。" : "Your partner's words appear here, translated for you."
    }
    static func listening(_ lang: LanguageOption) -> String {
        lang.isChinese ? "正在聆听 · \(lang.nativeName)" : "Listening · \(lang.nativeName)"
    }
    static func speaking(_ lang: LanguageOption) -> String {
        lang.isChinese ? "朗读中…" : "Speaking…"
    }
    static func partnerSpeaking(_ lang: LanguageOption) -> String {
        lang.isChinese ? "对方正在说话…" : "Partner is speaking…"
    }
    static func noSpeech(_ lang: LanguageOption) -> String {
        lang.isChinese ? "没听清，请再说一次" : "Didn't catch that — try again"
    }
    /// 麦克风旁边的一行小字（没听清）：点它或点麦克风都是重说
    static func noSpeechTap(_ lang: LanguageOption) -> String {
        lang.isChinese ? "没听清 · 轻点重说" : "Didn't catch that · tap to retry"
    }
    static func retry(_ lang: LanguageOption) -> String {
        lang.isChinese ? "再说一次" : "Try again"
    }
    static func useKeyboard(_ lang: LanguageOption) -> String {
        lang.isChinese ? "用键盘" : "Use keyboard"
    }
    static func previewChip(_ lang: LanguageOption) -> String {
        lang.isChinese ? "预览 · 未发送" : "Preview · not sent"
    }
    /// 打字时对方半屏还没有输入：说明这里会出现译文（用对方的语言写，他看得懂）
    static func previewEmpty(_ lang: LanguageOption) -> String {
        lang.isChinese ? "译文会显示在这里" : "The translation will appear here"
    }
    static func holdToTalk(_ lang: LanguageOption) -> String {
        lang.isChinese ? "按住说话" : "Hold to talk"
    }
}
