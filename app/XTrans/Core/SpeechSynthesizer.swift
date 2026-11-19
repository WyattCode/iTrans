import AVFoundation

@MainActor
protocol SpeechSpeaking: AnyObject {
    /// 朗读并在读完（或被打断）后返回。
    /// `voiceID`：nil = 用设置里为这种语言选的声音；`VoiceCatalog.autoID` = 系统默认；其他 = 指定这个声音（试听用）。
    func speak(_ text: String, ttsCode: String, voiceID: String?) async
    func stop()
}

extension SpeechSpeaking {
    func speak(_ text: String, ttsCode: String) async {
        await speak(text, ttsCode: ttsCode, voiceID: nil)
    }
}

/// 朗读时报告读到哪了（译文里的 UTF-16 偏移，读完的最后一个词的结尾）。界面据此高亮、跟着滚动。
/// 单独成协议：不支持进度的朗读器（测试里的假朗读器）不用跟着改。
@MainActor
protocol SpeechProgressReporting: AnyObject {
    var onProgress: ((Int) -> Void)? { get set }
}

@MainActor
final class AppleSpeechSynthesizer: NSObject, SpeechSpeaking, SpeechProgressReporting, AVSpeechSynthesizerDelegate {
    var onProgress: ((Int) -> Void)?
    private let synthesizer = AVSpeechSynthesizer()
    private var continuation: CheckedContinuation<Void, Never>?
    /// 当前正在等待的那一句。系统的"被取消 / 读完"回调是异步到达的：
    /// 打断上一句、马上读下一句时，上一句迟到的回调不能把下一句的等待也结束掉。
    private var current: AVSpeechUtterance?
    /// 语速（AVSpeechUtterance 的 rate，默认 0.5，可在设置里改）
    var rate: Float = AVSpeechUtteranceDefaultSpeechRate
    /// 每种语言选的声音：朗读语言代码（如 "zh-CN"）→ 声音标识。没选的语言用系统默认。
    var voiceIDs: [String: String] = [:]

    override init() {
        super.init()
        synthesizer.delegate = self
        // 来电 / Siri 等打断：系统可能既不回 didFinish 也不回 didCancel，朗读的等待就永远不结束，界面卡在「忙」。打断一开始就主动收尾
        NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .began else { return }
            MainActor.assumeIsolated { self?.stop() }
        }
    }

    /// 选哪个声音：指定的声音还在（没被用户删掉）就用它，否则退回这种语言的系统默认声音。
    nonisolated static func resolveVoice(ttsCode: String, preferredID: String?) -> AVSpeechSynthesisVoice? {
        if let id = preferredID, !id.isEmpty, let voice = AVSpeechSynthesisVoice(identifier: id) { return voice }
        return AVSpeechSynthesisVoice(language: ttsCode)
    }

    func speak(_ text: String, ttsCode: String, voiceID: String?) async {
        stop()
        // 空译文：系统不会回 didFinish，等待会永远不结束
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        // 切换音频类别 / 激活会话是同步调用，在主线程做会卡几十到几百毫秒（选声音试听时「点一下卡一下」）：放到后台
        let mine = generation
        let stamp = AppAudioSession.speechStamp()
        let activated = await Task.detached(priority: .userInitiated) { (try? AppAudioSession.activateForSpeech(ifNoListeningSince: stamp)) ?? false }.value
        // 等待期间被 stop() 打断了，或者用户按住麦克风要聆听了（音频会话该留给聆听）：不再开口
        guard mine == generation, activated else { return }
        let utterance = AVSpeechUtterance(string: text)
        utterance.volume = 1.0          // 显式拉满（系统默认也是 1，写明白免得以后被谁改小）
        utterance.voice = Self.resolveVoice(ttsCode: ttsCode, preferredID: voiceID ?? voiceIDs[ttsCode])
        utterance.rate = rate
        // 看门狗：路由失败等情况系统既不回 didFinish 也不回 didCancel。按字数估算时长再加余量，到点还没结束就收尾
        let budget = Duration.seconds(10 + Double(text.count) * 0.5 / Double(max(0.1, rate / AVSpeechUtteranceDefaultSpeechRate)))
        let watchdog = Task { @MainActor [weak self] in
            try? await Task.sleep(for: budget)
            guard !Task.isCancelled, let self, self.current === utterance else { return }
            self.stop()
        }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            continuation = c
            current = utterance
            synthesizer.speak(utterance)
        }
        watchdog.cancel()
    }

    /// 每次 `stop()` 加一：`speak` 在后台激活音频会话的等待期间被打断时靠它认出来
    private var generation = 0

    func stop() {
        generation &+= 1
        current = nil                      // 先作废，再取消：这样迟到的 didCancel 认不出来，不会误伤下一句
        // 无条件停：排队中、还没开口的句子 isSpeaking 也是 false，只在 isSpeaking 时才停会让它照读
        synthesizer.stopSpeaking(at: .immediate)
        resume()
    }

    private func resume() {
        continuation?.resume()
        continuation = nil
    }

    private func finished(_ utterance: AVSpeechUtterance) {
        guard utterance === current else { return }
        current = nil
        resume()
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.finished(utterance) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, willSpeakRangeOfSpeechString characterRange: NSRange, utterance: AVSpeechUtterance) {
        let end = characterRange.location + characterRange.length
        Task { @MainActor in
            guard utterance === self.current else { return }
            self.onProgress?(end)
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.finished(utterance) }
    }
}
