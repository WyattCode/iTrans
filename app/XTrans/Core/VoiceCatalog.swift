import AVFoundation

/// 一个可选的朗读声音（来自系统，装了更高质量的声音后会自动出现在这里）。
struct VoiceChoice: Identifiable, Hashable {
    enum Quality: Int, Comparable {
        case standard, enhanced, premium
        static func < (a: Quality, b: Quality) -> Bool { a.rawValue < b.rawValue }
    }
    enum Gender { case unspecified, male, female }

    let id: String
    let name: String
    /// 完整的语言区域代码，如 "en-GB"
    let language: String
    let quality: Quality
    let gender: Gender
}

enum VoiceCatalog {
    private static let legacyPrefix = "com.apple.speech.synthesis.voice."

    /// 表示"系统默认声音"（不指定具体声音）。
    static let autoID = ""

    /// 该语言可选的声音：同一种语言（英语包含美 / 英 / 澳等口音），
    /// 但中文只要普通话（粤语声音读普通话文字会很怪）。排序：和朗读语言区域完全一致的在前，再按质量从高到低，最后按名字。
    static func choices(for ttsCode: String, among voices: [VoiceChoice]) -> [VoiceChoice] {
        let primary = String(ttsCode.split(separator: "-").first ?? "")
        let sameLanguage = voices.filter { voice in
            if primary == "zh" { return voice.language == ttsCode }
            return voice.language.split(separator: "-").first.map(String.init) == primary
        }
        // 系统里还带着一批"趣味 / 旧式"声音（Albert、Bad News、Bells、Boing、Fred……），用来翻译会很怪，不列出。
        // 万一一个正经声音都没有，就还是都列出来，免得用户没得选。
        let normal = sameLanguage.filter { !$0.id.hasPrefix(Self.legacyPrefix) }
        let matching = normal.isEmpty ? sameLanguage : normal
        return matching.sorted { a, b in
            let aExact = a.language == ttsCode, bExact = b.language == ttsCode
            if aExact != bExact { return aExact }
            if a.quality != b.quality { return a.quality > b.quality }
            return a.name.localizedCompare(b.name) == .orderedAscending
        }
    }

    /// 缓存：枚举系统声音要 16–20ms（首次 120ms），而且在主线程。页面里的 `@State` 初始值表达式每次重建视图结构体都会执行，
    /// 打开一次「朗读声音」页就枚举了 34 次（≈0.7s）。现在只在需要时枚举一次，页面读缓存。
    nonisolated(unsafe) private static var cache: [VoiceChoice]?
    private static let lock = NSLock()

    /// 缓存里的声音（没有就现枚举一次并记下）。页面渲染用这个。
    /// 注意：枚举放在锁外面——`installedVoices()` 自己也要拿这把锁记次数，`NSLock` 不可重入，在锁里调它会自己等自己（死锁）。
    static var cachedVoices: [VoiceChoice] {
        lock.lock(); let hit = cache; lock.unlock()
        if let hit { return hit }
        let fresh = installedVoices()
        lock.lock(); if cache == nil { cache = fresh }; let result = cache ?? fresh; lock.unlock()
        return result
    }

    /// 缓存里现在有什么（没有就是 nil，**不枚举**）。页面打开时用它：没有就先显示空白、等后台枚举完再填，绝不在主线程等枚举。
    /// 真机上声音比模拟器多得多（几百个），第一次枚举可能要几百毫秒到一秒多。
    static var peek: [VoiceChoice]? {
        lock.lock(); defer { lock.unlock() }
        return cache
    }

    /// 每种语言排好序的声音列表缓存（排序要比较几十个名字；页面每次重建都排一遍太浪费）。`refresh` 时清掉。
    nonisolated(unsafe) private static var choicesCache: [String: [VoiceChoice]] = [:]
    /// `store` 每次加一：`cachedChoices` 在锁外排序期间如果缓存被刷新过，排好的旧结果不能再写回
    nonisolated(unsafe) private static var cacheGeneration = 0

    /// 这种语言可选的声音。缓存里还没有声音列表就返回 nil（调用方显示「加载中」）。
    static func cachedChoices(for ttsCode: String) -> [VoiceChoice]? {
        lock.lock()
        if let hit = choicesCache[ttsCode] { lock.unlock(); return hit }
        guard let all = cache else { lock.unlock(); return nil }
        let generation = cacheGeneration
        lock.unlock()
        let computed = choices(for: ttsCode, among: all)
        lock.lock(); if generation == cacheGeneration { choicesCache[ttsCode] = computed }; lock.unlock()
        return computed
    }

    /// 重新枚举（用户可能刚在系统设置里下载了新声音）：放到后台做，做完更新缓存，返回新列表。
    static func refresh() async -> [VoiceChoice] {
        await Task.detached(priority: .userInitiated) {
            let fresh = installedVoices()
            store(fresh)
            return fresh
        }.value
    }

    /// 同步小函数里拿锁（异步闭包里直接用 `NSLock` 会有并发警告）
    private static func store(_ fresh: [VoiceChoice]) {
        lock.lock(); cache = fresh; choicesCache = [:]; cacheGeneration += 1; lock.unlock()
    }

    /// 启动后空闲时先枚举一次，之后点进「朗读声音」就不用等
    static func warmUp() async { _ = await refresh() }

    /// 真的枚举了几次（测试用：打开页面不能反复枚举）
    nonisolated(unsafe) private(set) static var enumerationCount = 0

    /// 系统里装着的全部声音（每次都真的枚举，不要在视图里直接调——用 `cachedVoices`）。
    static func installedVoices() -> [VoiceChoice] {
        lock.lock(); enumerationCount += 1; lock.unlock()
        return AVSpeechSynthesisVoice.speechVoices().map { voice in
            let quality: VoiceChoice.Quality
            switch voice.quality {
            case .premium: quality = .premium
            case .enhanced: quality = .enhanced
            default: quality = .standard
            }
            let gender: VoiceChoice.Gender
            switch voice.gender {
            case .male: gender = .male
            case .female: gender = .female
            default: gender = .unspecified
            }
            return VoiceChoice(id: voice.identifier, name: voice.name, language: voice.language, quality: quality, gender: gender)
        }
    }

    static func choices(for language: LanguageOption) -> [VoiceChoice] {
        choices(for: language.ttsCode, among: cachedVoices)
    }

    /// 选声音时试听的那句话（用该语言自己的文字，内容而不是界面文案）。
    static func sample(for language: LanguageOption) -> String {
        switch language.id {
        case "zh-Hans": return "你好，很高兴认识你。"
        case "en": return "Hello, nice to meet you."
        case "ja": return "こんにちは、はじめまして。"
        case "ko": return "안녕하세요, 만나서 반갑습니다."
        case "es": return "Hola, mucho gusto."
        case "fr": return "Bonjour, enchanté."
        case "de": return "Hallo, freut mich."
        case "it": return "Ciao, piacere di conoscerti."
        case "pt": return "Olá, muito prazer."
        case "ru": return "Здравствуйте, рад познакомиться."
        default: return "Hello"
        }
    }

    /// 设置里显示的"当前声音"：选了且还装着 → 声音名；否则 nil（表示自动）。
    static func selectedName(for language: LanguageOption, settings: [String: String], among voices: [VoiceChoice]) -> String? {
        guard let id = settings[language.ttsCode], !id.isEmpty else { return nil }
        return voices.first { $0.id == id }?.name
    }
}
