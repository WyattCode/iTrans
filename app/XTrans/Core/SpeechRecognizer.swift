import AVFoundation
import Speech

enum RecognitionEvent: Equatable {
    case partial(String)
    case level(Float)      // 0...1，给波形用
    case final(String)
}

enum PermissionResult: Equatable {
    case granted
    case microphoneDenied
    case speechDenied
}

@MainActor
protocol SpeechRecognizing: AnyObject {
    func requestPermissions() async -> PermissionResult
    /// 开始聆听；流在出现最终结果（或出错）后结束。取消流等于放弃本次识别。
    func listen(locale: Locale, autoEndpoint: Bool) -> AsyncThrowingStream<RecognitionEvent, Error>
    /// 请求结束本次聆听（松手 / 再点一次）：会把已听到的内容作为最终结果输出。
    func stop()
    /// 按下时就按"对讲"开始听了，随后发现只是轻点：改成自动模式（停顿几秒自动结束）。
    func enableAutoEndpoint()
    /// 手指刚落到麦克风上（还没确定是不是要开始听）：提前把音频会话切好，真正开始时少等一截。
    func prepare()
}

extension SpeechRecognizing {
    func enableAutoEndpoint() {}
    func prepare() {}
}

enum RecognizerError: LocalizedError {
    case unavailable(String)
    var errorDescription: String? {
        switch self { case .unavailable(let r): return r }
    }
}

/// 基于 `SFSpeechRecognizer` 的识别，语言支持时强制端侧识别。
@MainActor
final class AppleSpeechRecognizer: SpeechRecognizing {
    private var engine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var recognizer: SFSpeechRecognizer?
    private var continuation: AsyncThrowingStream<RecognitionEvent, Error>.Continuation?
    private var silenceTask: Task<Void, Never>?
    private var fallbackTask: Task<Void, Never>?
    private var lastText = ""
    private var autoEndpoint = true
    private var finished = false
    /// 每次 listen 加一。上一次聆听的"善后"回调晚到时，靠它认出自己已经过期，不去拆掉新的一次。
    private var generation = 0
    private var observers: [NSObjectProtocol] = []
    private var recognizers: [String: SFSpeechRecognizer] = [:]

    /// 停顿多久自动结束这一句（设计稿默认 1.2 秒，可在设置里改）。
    var silenceTimeout: Duration = .milliseconds(1200)
    /// 轻点开始后一直没人说话，多久放弃（否则会一直占着麦克风，界面卡在"正在听"）。
    var noSpeechTimeout: Duration = .seconds(8)

    /// 手指一落到麦克风上：在后台把音频会话切到「录音 + 播放」（已经是就什么都不做）。
    /// 试过「同时把整台音频引擎也建好」：真机实测它自己要 270–370ms，比真正开始听（35–130ms）晚得多，
    /// 每次都白建，还和正式开始抢同一把音频会话的锁——已撤掉。
    func prepare() {
        MicTiming.begin()
        AppAudioSession.prepareForListening()
    }

    func requestPermissions() async -> PermissionResult {
        // 两项都已经允许（绝大多数时候）：不再走两次异步查询，直接开始
        if PermissionCenter.microphone() == .granted, PermissionCenter.speech() == .granted { return .granted }
        let mic = await AVAudioApplication.requestRecordPermission()
        guard mic else { return .microphoneDenied }
        let status = await withCheckedContinuation { (c: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) }
        }
        return status == .authorized ? .granted : .speechDenied
    }

    func listen(locale: Locale, autoEndpoint: Bool) -> AsyncThrowingStream<RecognitionEvent, Error> {
        AsyncThrowingStream { continuation in
            self.teardown()
            self.generation += 1
            let mine = self.generation
            self.continuation = continuation
            self.autoEndpoint = autoEndpoint
            self.finished = false
            self.lastText = ""
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.generation == mine else { return }
                    self.teardown()
                }
            }
            do {
                try self.begin(locale: locale)
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }

    func enableAutoEndpoint() {
        guard !finished, !autoEndpoint else { return }
        autoEndpoint = true
        restartSilenceTimer(after: lastText.isEmpty ? noSpeechTimeout : nil)
    }

    func stop() {
        guard !finished else { return }
        endAudio()
        // 系统偶尔不回最终结果，兜底 1 秒后用已听到的内容收尾
        fallbackTask?.cancel()
        fallbackTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.emitFinal()
        }
    }

    // MARK: - 内部

    private func begin(locale: Locale) throws {
        // 同一种语言的识别器反复用：每次新建要重新加载模型，第二句开始会更慢
        let cached = recognizers[locale.identifier] ?? SFSpeechRecognizer(locale: locale)
        if let cached { recognizers[locale.identifier] = cached }
        guard let recognizer = cached, recognizer.isAvailable else {
            throw RecognizerError.unavailable(String(localized: "这个语言的语音识别暂时不可用"))
        }
        self.recognizer = recognizer

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        self.request = request

        MicTiming.mark("recognizerReady")
        try AppAudioSession.activate()
        MicTiming.mark("sessionActive")
        let session = AVAudioSession.sharedInstance()

        MicTiming.mark("beginEnter")
        let engine = AVAudioEngine()
        MicTiming.mark("engineCreated")
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        // 没有可用的音频输入时（模拟器无麦克风、耳机刚断开等）格式无效，直接 installTap 会抛出
        // Objective-C 异常导致闪退，Swift 的 try 接不住，所以必须先检查。
        guard format.sampleRate > 0, format.channelCount > 0 else {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            throw RecognizerError.unavailable(String(localized: "没有检测到可用的麦克风"))
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: format,
                         block: Self.makeTap(request: request) { [weak self] level in
            MicTiming.firstAudio()
            Task { @MainActor in self?.continuation?.yield(.level(level)) }
        })
        MicTiming.mark("tapInstalled")
        engine.prepare()
        MicTiming.mark("enginePrepared")
        do {
            try engine.start()
        } catch {
            // 启动失败：把 tap 摘掉、音频会话还给系统，不然会话一直占着
            input.removeTap(onBus: 0)
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            throw error
        }
        self.engine = engine
        MicTiming.mark("engineStarted")
        observeInterruptions(of: engine)
        // 自动模式：开口之前也要有个上限，不然一直不说话就一直听下去
        if autoEndpoint { restartSilenceTimer(after: noSpeechTimeout) }

        // 带上这一轮的代号：上一轮被取消后系统才回的「已取消」错误，不能落到下一轮身上把它收尾成「没听清」
        let mine = generation
        task = recognizer.recognitionTask(with: request, resultHandler: Self.makeResultHandler { [weak self] text, isFinal, error in
            Task { @MainActor in
                guard let self, self.generation == mine else { return }
                self.handle(text: text, isFinal: isFinal, error: error)
            }
        })
    }

    /// 音频线程的回调必须是非隔离的，否则在 MainActor 方法里创建会被推断为主线程隔离而崩溃。
    private nonisolated static func makeTap(
        request: SFSpeechAudioBufferRecognitionRequest,
        onLevel: @escaping @Sendable (Float) -> Void
    ) -> AVAudioNodeTapBlock {
        { buffer, _ in
            request.append(buffer)
            guard let data = buffer.floatChannelData?[0] else { return }
            let n = Int(buffer.frameLength)
            guard n > 0 else { return }
            var sum: Float = 0
            for i in 0..<n { sum += data[i] * data[i] }
            let rms = (sum / Float(n)).squareRoot()
            onLevel(min(1, rms * 8))
        }
    }

    private nonisolated static func makeResultHandler(
        _ handler: @escaping @Sendable (String?, Bool, Error?) -> Void
    ) -> (SFSpeechRecognitionResult?, Error?) -> Void {
        { result, error in
            handler(result?.bestTranscription.formattedString, result?.isFinal ?? false, error)
        }
    }

    private func handle(text: String?, isFinal: Bool, error: Error?) {
        guard !finished else { return }
        if let text, !text.isEmpty {
            lastText = text
            continuation?.yield(.partial(text))
            if autoEndpoint { restartSilenceTimer() }
        }
        if isFinal {
            emitFinal()
        } else if error != nil {
            // 没有说话 / 被中断：用已有内容收尾，空字符串由上层按"没听清"处理
            emitFinal()
        }
    }

    private func restartSilenceTimer(after delay: Duration? = nil) {
        silenceTask?.cancel()
        let wait = delay ?? silenceTimeout
        silenceTask = Task { [weak self] in
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled else { return }
            self?.stop()
        }
    }

    /// 来电、Siri、切到别的 App、耳机拔插都会让音频引擎悄悄停掉，却没有任何识别结果回来——
    /// 界面就会永远卡在"正在听"。遇到这些情况直接收尾（用已经听到的内容）。
    private func observeInterruptions(of engine: AVAudioEngine) {
        removeObservers()
        let center = NotificationCenter.default
        let interrupted = center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            guard raw == AVAudioSession.InterruptionType.began.rawValue else { return }
            Task { @MainActor in self?.stop() }
        }
        let reconfigured = center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.stop() }
        }
        observers = [interrupted, reconfigured]
    }

    private func removeObservers() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
    }

    private func endAudio() {
        silenceTask?.cancel()
        engine?.stop()
        engine?.inputNode.removeTap(onBus: 0)
        request?.endAudio()
    }

    private func emitFinal() {
        guard !finished else { return }
        finished = true
        continuation?.yield(.final(lastText))
        continuation?.finish()
        teardown()
    }

    private func teardown() {
        removeObservers()
        silenceTask?.cancel(); silenceTask = nil
        fallbackTask?.cancel(); fallbackTask = nil
        if let engine {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        engine = nil
        task?.cancel(); task = nil
        request = nil
        recognizer = nil
        continuation = nil
    }
}


/// 排查用计时（`-XTransMicTiming` 启动参数才打印）：手指落下之后每一步用了多少毫秒，用来在真机上量「长按到开始听」的真实耗时。
/// 只打印标签和毫秒，不含任何内容。
enum MicTiming {
    nonisolated(unsafe) private static var t0: CFAbsoluteTime = 0
    nonisolated(unsafe) private static var firstAudioPending = false
    static let enabled = ProcessInfo.processInfo.arguments.contains("-XTransMicTiming")
    static func begin() {
        guard enabled else { return }
        t0 = CFAbsoluteTimeGetCurrent(); firstAudioPending = true
        NSLog("MICTIME touchDown +0ms")
    }
    static func mark(_ label: String) {
        guard enabled, t0 > 0 else { return }
        NSLog("MICTIME %@ +%.0fms", label, (CFAbsoluteTimeGetCurrent() - t0) * 1000)
    }
    static func firstAudio() {
        guard enabled, firstAudioPending else { return }
        firstAudioPending = false
        mark("firstAudio")
    }
}
