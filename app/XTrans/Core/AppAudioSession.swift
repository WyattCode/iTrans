import AVFoundation

/// 全 App 共用的音频会话设置。听（识别）和说（朗读）用同一个类别，来回切换时不会重新协商路由。
enum AppAudioSession {
    /// 所有改音频类别的调用（主线程的 `activate()`、后台的 `prepareForListening` / `activateForSpeech`）都经过这把锁：
    /// 原来「检查类别 → 设置类别」三处各做各的、没有先后——朗读在后台切 `.playback` 要约 100ms，期间用户按住麦克风，
    /// 聆听那边看到的还是 `.playAndRecord` 就不切了，随后迟到的 `.playback` 落下来，音频引擎被改配置、聆听当场失败。
    private static let lock = NSLock()
    /// 每次要聆听（`activate` / `prepareForListening`）加一。朗读的后台激活带着自己开始时看到的值：执行时发现更大了，说明中间有人要聆听，放弃
    nonisolated(unsafe) private static var listenStamp = 0

    /// 朗读开始前取一个戳（主线程），随后传给 `activateForSpeech`
    static func speechStamp() -> Int { lock.lock(); defer { lock.unlock() }; return listenStamp }

    /// 录音 + 播放，默认走扬声器。朗读也必须先调用它：
    /// 不设置的话，朗读会沿用系统默认类别，此时静音开关会把译文读成"无声"。
    static func activate() throws {
        lock.lock(); defer { lock.unlock() }
        listenStamp += 1
        try applyListening()
    }

    private static func applyListening() throws {
        let session = AVAudioSession.sharedInstance()
        // 已经是这个类别就不重复设置（切换类别要重新协商路由，几十到上百毫秒）
        MicTiming.mark("activateEnter")
        if session.category != .playAndRecord || session.mode != .default || !session.categoryOptions.contains(.defaultToSpeaker) {
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP])
            MicTiming.mark("categoryWasReset")          // 计时：这一次重新设了类别（说明上面的「已经是这个类别」判断没命中）
        }
        // 录音类别下系统默认把触感（震动）静音：不开这个，长按麦克风开始聆听的那一下就不会震。每次都设（改类别会把它复位）
        try? session.setAllowHapticsAndSystemSoundsDuringRecording(true)
        try session.setActive(true)
        try? session.setAllowHapticsAndSystemSoundsDuringRecording(true)          // 激活之后再补一次：万一系统在激活时才复位它，震动还是会被吞
        MicTiming.mark("setActiveDone")
    }

    /// 手指一落到麦克风上就在后台把音频会话切到「录音 + 播放」：朗读之后（纯播放类别）第一次聆听要切回来，
    /// 同步切在主线程要几十到上百毫秒，和防误触的那一小段等待并行做掉。
    static func prepareForListening() {
        Task.detached(priority: .userInitiated) { try? activate() }
    }

    /// 朗读专用：纯播放类别 + 朗读模式。
    /// 「录音 + 播放」类别下外放的最大音量比纯播放类别小一截（iPhone Air 这种扬声器本来就单薄的机型尤其明显）——
    /// 译文是用来给对面的人听的，要最响的那条路。静音开关对 `.playback` 不起作用（照样出声）。
    /// 下一次聆听时 `activate()` 会再切回「录音 + 播放」。已经是播放类别就不重复设置（切换类别会重新协商路由）。
    /// `stamp`：`speechStamp()` 在朗读开始时取的值；之后有人要聆听（戳变大了）就不切，返回 false（调用方别再开口）。
    @discardableResult
    static func activateForSpeech(ifNoListeningSince stamp: Int) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard stamp == listenStamp else { return false }
        let session = AVAudioSession.sharedInstance()
        if session.category != .playback || session.mode != .spokenAudio {
            try session.setCategory(.playback, mode: .spokenAudio, options: [])
        }
        try session.setActive(true)
        return true
    }

    /// 用完把音频会话还给系统，正在播音乐 / 播客的其他 App 才会自动恢复。
    /// 如果此刻还有声音在播（比如朗读没结束），系统会拒绝停用——忽略即可，下次空闲时再试。
    /// 空闲多久后才把音频会话还给系统。
    static let releaseDelay: Duration = .seconds(20)

    static func releaseToOthers() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
