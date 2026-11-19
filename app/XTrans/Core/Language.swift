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

/// 界面里需要按"屏幕主人的语言"显示的少量文案：这半屏是谁的，就用谁的语言写（对方看得懂）。
/// 十种语言都有；表里没有的语言退回英文。
enum Strings {
    private static func pick(_ lang: LanguageOption, _ table: [String: String]) -> String {
        if let text = table[lang.id] { return text }
        return (lang.isChinese ? table["zh-Hans"] : table["en"]) ?? ""
    }

    static func emptyTitle(_ lang: LanguageOption) -> String {
        pick(lang, ["zh-Hans": "轻点麦克风，开始说话", "en": "Tap the mic and speak",
                    "ja": "マイクをタップして話してください", "ko": "마이크를 눌러 말씀하세요",
                    "es": "Toca el micrófono y habla", "fr": "Touchez le micro et parlez",
                    "de": "Tippen Sie auf das Mikrofon und sprechen Sie", "it": "Tocca il microfono e parla",
                    "pt": "Toque no microfone e fale", "ru": "Нажмите на микрофон и говорите"])
    }
    static func emptyHint(_ lang: LanguageOption) -> String {
        pick(lang, ["zh-Hans": "自动识别你和对方的语言，也可以按住说话。", "en": "Your partner's words appear here, translated for you.",
                    "ja": "相手の言葉が翻訳されてここに表示されます。", "ko": "상대방의 말이 번역되어 여기에 표시됩니다.",
                    "es": "Aquí verás traducido lo que diga la otra persona.", "fr": "Les paroles de l'autre personne s'affichent ici, traduites.",
                    "de": "Was Ihr Gegenüber sagt, erscheint hier übersetzt.", "it": "Qui vedrai tradotto ciò che dice l'altra persona.",
                    "pt": "O que a outra pessoa disser aparece aqui traduzido.", "ru": "Здесь появится перевод слов собеседника."])
    }
    static func listening(_ lang: LanguageOption) -> String {
        pick(lang, ["zh-Hans": "正在聆听", "en": "Listening", "ja": "聞き取り中", "ko": "듣는 중", "es": "Escuchando", "fr": "Écoute",
                    "de": "Hört zu", "it": "In ascolto", "pt": "Ouvindo", "ru": "Слушаю"]) + " · \(lang.nativeName)"
    }
    static func speaking(_ lang: LanguageOption) -> String {
        pick(lang, ["zh-Hans": "朗读中…", "en": "Speaking…", "ja": "読み上げ中…", "ko": "읽는 중…", "es": "Leyendo…", "fr": "Lecture…",
                    "de": "Liest vor…", "it": "Lettura…", "pt": "Lendo…", "ru": "Озвучивание…"])
    }
    static func partnerSpeaking(_ lang: LanguageOption) -> String {
        pick(lang, ["zh-Hans": "对方正在说话…", "en": "Partner is speaking…", "ja": "相手が話しています…", "ko": "상대방이 말하는 중…",
                    "es": "La otra persona está hablando…", "fr": "L'autre personne parle…", "de": "Ihr Gegenüber spricht…",
                    "it": "L'altra persona sta parlando…", "pt": "A outra pessoa está falando…", "ru": "Собеседник говорит…"])
    }
    static func noSpeech(_ lang: LanguageOption) -> String {
        pick(lang, ["zh-Hans": "没听清，请再说一次", "en": "Didn't catch that — try again", "ja": "聞き取れませんでした。もう一度お願いします",
                    "ko": "잘 못 들었어요. 다시 말씀해 주세요", "es": "No se entendió. Inténtalo de nuevo", "fr": "Pas compris. Réessayez",
                    "de": "Nicht verstanden. Bitte noch einmal", "it": "Non ho capito. Riprova", "pt": "Não entendi. Tente de novo",
                    "ru": "Не расслышал. Повторите, пожалуйста"])
    }
    /// 麦克风旁边的一行小字（没听清）：点它或点麦克风都是重说
    static func noSpeechTap(_ lang: LanguageOption) -> String {
        pick(lang, ["zh-Hans": "没听清 · 轻点重说", "en": "Didn't catch that · tap to retry", "ja": "聞き取れませんでした · タップでやり直し",
                    "ko": "잘 못 들었어요 · 눌러서 다시", "es": "No se entendió · toca para repetir", "fr": "Pas compris · touchez pour réessayer",
                    "de": "Nicht verstanden · tippen zum Wiederholen", "it": "Non ho capito · tocca per riprovare",
                    "pt": "Não entendi · toque para repetir", "ru": "Не расслышал · нажмите, чтобы повторить"])
    }
    static func retry(_ lang: LanguageOption) -> String {
        pick(lang, ["zh-Hans": "再说一次", "en": "Try again", "ja": "もう一度", "ko": "다시 말하기", "es": "Repetir", "fr": "Réessayer",
                    "de": "Noch einmal", "it": "Riprova", "pt": "Tentar de novo", "ru": "Повторить"])
    }
    static func useKeyboard(_ lang: LanguageOption) -> String {
        pick(lang, ["zh-Hans": "用键盘", "en": "Use keyboard", "ja": "キーボードを使う", "ko": "키보드 사용", "es": "Usar teclado",
                    "fr": "Utiliser le clavier", "de": "Tastatur verwenden", "it": "Usa la tastiera", "pt": "Usar teclado", "ru": "Клавиатура"])
    }
    static func previewChip(_ lang: LanguageOption) -> String {
        pick(lang, ["zh-Hans": "预览 · 未发送", "en": "Preview · not sent", "ja": "プレビュー · 未送信", "ko": "미리보기 · 보내지 않음",
                    "es": "Vista previa · sin enviar", "fr": "Aperçu · non envoyé", "de": "Vorschau · nicht gesendet",
                    "it": "Anteprima · non inviato", "pt": "Prévia · não enviado", "ru": "Предпросмотр · не отправлено"])
    }
    /// 打字时对方半屏还没有输入：说明这里会出现译文（用对方的语言写，他看得懂）
    static func previewEmpty(_ lang: LanguageOption) -> String {
        pick(lang, ["zh-Hans": "译文会显示在这里", "en": "The translation will appear here", "ja": "翻訳がここに表示されます",
                    "ko": "번역이 여기에 표시됩니다", "es": "La traducción aparecerá aquí", "fr": "La traduction s'affichera ici",
                    "de": "Die Übersetzung erscheint hier", "it": "La traduzione apparirà qui", "pt": "A tradução aparecerá aqui",
                    "ru": "Перевод появится здесь"])
    }
    static func holdToTalk(_ lang: LanguageOption) -> String {
        pick(lang, ["zh-Hans": "按住说话", "en": "Hold to talk", "ja": "押して話す", "ko": "누르고 말하기", "es": "Mantén pulsado para hablar",
                    "fr": "Maintenez pour parler", "de": "Zum Sprechen halten", "it": "Tieni premuto per parlare",
                    "pt": "Segure para falar", "ru": "Удерживайте, чтобы говорить"])
    }
}
