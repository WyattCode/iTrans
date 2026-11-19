import XCTest
@testable import XTrans

// MARK: - 假实现

@MainActor
final class FakeRecognizer: SpeechRecognizing {
    var permission: PermissionResult = .granted
    var script: [RecognitionEvent] = []
    var failure: Error?
    /// true：流一直开着，直到 stop() 被调用才以 `heldFinal` 收尾（模拟用户还在说话）
    var holdOpen = false
    var heldFinal = ""

    private(set) var stopCount = 0
    private(set) var prepareCount = 0
    func prepare() { prepareCount += 1 }
    private(set) var autoEndpointEnabledCount = 0
    private(set) var lastAutoEndpoint: Bool?
    private(set) var lastLocale: String?
    private var continuation: AsyncThrowingStream<RecognitionEvent, Error>.Continuation?

    func requestPermissions() async -> PermissionResult { permission }
    func enableAutoEndpoint() { autoEndpointEnabledCount += 1 }

    func listen(locale: Locale, autoEndpoint: Bool) -> AsyncThrowingStream<RecognitionEvent, Error> {
        lastAutoEndpoint = autoEndpoint
        lastLocale = locale.identifier
        return AsyncThrowingStream { c in
            self.continuation = c
            for event in self.script { c.yield(event) }
            if let failure = self.failure {
                c.finish(throwing: failure)
            } else if !self.holdOpen {
                c.finish()
            }
        }
    }

    func stop() {
        stopCount += 1
        if holdOpen {
            continuation?.yield(.final(heldFinal))
            continuation?.finish()
        }
    }
}

@MainActor
final class FakeSynthesizer: SpeechSpeaking {
    private(set) var spoken: [(text: String, code: String)] = []
    private(set) var stopCount = 0
    private(set) var voiceIDs: [String?] = []
    func speak(_ text: String, ttsCode: String, voiceID: String?) async {
        spoken.append((text, ttsCode))
        voiceIDs.append(voiceID)
    }
    func stop() { stopCount += 1 }
}

@MainActor
final class ScriptedEngine: TranslationEngine {
    let name = "测试引擎"
    var shouldFail = false
    private(set) var calls: [(text: String, from: String, to: String)] = []

    func translate(_ text: String, from: LanguageOption, to: LanguageOption) async throws -> String {
        calls.append((text, from.id, to.id))
        if shouldFail { throw TranslationFailure.unavailable("引擎坏了") }
        return "T(\(text))"
    }
}

// MARK: - 测试

@MainActor
final class ConversationSessionTests: XCTestCase {
    private var recognizer: FakeRecognizer!
    private var synthesizer: FakeSynthesizer!
    private var engine: ScriptedEngine!
    private var session: ConversationSession!

    override func setUp() async throws {
        recognizer = FakeRecognizer()
        synthesizer = FakeSynthesizer()
        engine = ScriptedEngine()
        session = ConversationSession(recognizer: recognizer, synthesizer: synthesizer, engine: engine)
    }

    /// 轮询等待条件成立（状态机是异步的）
    private func waitUntil(_ message: String = "", timeout: Duration = .seconds(2), _ condition: () -> Bool,
                           file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            if ContinuousClock.now > deadline {
                XCTFail("等待超时：\(message)", file: file, line: line)
                return
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    // MARK: 主流程

    func testMeSpeaks_translatesAndSpeaksInPartnerLanguage() async {
        recognizer.script = [.partial("请问"), .partial("请问最近的地铁站"), .final("请问最近的地铁站怎么走")]
        session.micTapped(.me)
        await waitUntil("轮次完成") { self.session.currentTurn?.state == .done }

        let turn = session.currentTurn
        XCTAssertEqual(turn?.speaker, .me)
        XCTAssertEqual(turn?.sourceText, "请问最近的地铁站怎么走")
        XCTAssertEqual(turn?.translatedText, "T(请问最近的地铁站怎么走)")
        XCTAssertEqual(turn?.engineName, "测试引擎")
        XCTAssertNotNil(turn?.latency)
        XCTAssertEqual(engine.calls.first?.from, "zh-Hans")
        XCTAssertEqual(engine.calls.first?.to, "en")
        XCTAssertEqual(synthesizer.spoken.first?.code, "en-US", "译文要用对方的语言朗读")
        XCTAssertEqual(recognizer.lastLocale, "zh-CN")
        XCTAssertEqual(session.phase, .idle)
    }

    func testPartnerSpeaks_translatesIntoMyLanguage() async {
        recognizer.script = [.final("Go straight and turn left")]
        session.micTapped(.them)
        await waitUntil { self.session.currentTurn?.state == .done }

        XCTAssertEqual(session.currentTurn?.speaker, .them)
        XCTAssertEqual(engine.calls.first?.from, "en")
        XCTAssertEqual(engine.calls.first?.to, "zh-Hans")
        XCTAssertEqual(synthesizer.spoken.first?.code, "zh-CN")
        XCTAssertEqual(recognizer.lastLocale, "en-US")
    }

    func testTextShownOnEachSide() async {
        recognizer.script = [.final("你好")]
        session.micTapped(.me)
        await waitUntil { self.session.currentTurn?.state == .done }
        let turn = session.currentTurn!
        XCTAssertEqual(session.text(of: turn, on: .me), "你好", "说话的人这一半屏显示原话")
        XCTAssertEqual(session.text(of: turn, on: .them), "T(你好)", "对面那一半屏显示译文")
    }

    // MARK: 异常

    func testEmptyResult_showsNoSpeechAndRemovesTurn() async {
        recognizer.script = [.final("   ")]
        session.micTapped(.me)
        await waitUntil { self.session.notice != nil }
        XCTAssertEqual(session.notice, .noSpeech(.me))
        XCTAssertTrue(session.turns.isEmpty)
        XCTAssertEqual(session.phase, .idle)
        XCTAssertTrue(engine.calls.isEmpty, "没听清时不应该去翻译")
    }

    func testMicrophoneDenied() async {
        recognizer.permission = .microphoneDenied
        session.micTapped(.me)
        await waitUntil { self.session.notice != nil }
        XCTAssertEqual(session.notice, .microphoneDenied)
        XCTAssertTrue(session.turns.isEmpty)
        XCTAssertEqual(session.phase, .idle)
    }

    func testSpeechDenied() async {
        recognizer.permission = .speechDenied
        session.micTapped(.them)
        await waitUntil { self.session.notice != nil }
        XCTAssertEqual(session.notice, .speechDenied)
    }

    func testRecognizerError() async {
        recognizer.failure = RecognizerError.unavailable("没有检测到可用的麦克风")
        session.micTapped(.me)
        await waitUntil { self.session.notice != nil }
        XCTAssertEqual(session.notice, .recognizerUnavailable("没有检测到可用的麦克风"))
        XCTAssertTrue(session.turns.isEmpty)
        XCTAssertEqual(session.phase, .idle)
    }

    func testTranslationFailure_thenRetranslateSucceeds() async {
        engine.shouldFail = true
        recognizer.script = [.final("你好")]
        session.micTapped(.me)
        await waitUntil { if case .failed = self.session.currentTurn?.state { return true } else { return false } }
        XCTAssertEqual(session.currentTurn?.state, .failed("引擎坏了"))
        XCTAssertEqual(session.currentTurn?.sourceText, "你好", "失败时原话必须保留")
        XCTAssertEqual(session.phase, .idle)
        XCTAssertTrue(synthesizer.spoken.isEmpty)

        engine.shouldFail = false
        session.retranslate(session.currentTurn!.id)
        await waitUntil { self.session.currentTurn?.state == .done }
        XCTAssertEqual(session.currentTurn?.translatedText, "T(你好)")
        XCTAssertTrue(synthesizer.spoken.isEmpty, "重译只更新文字，不再朗读")
    }

    // MARK: 手势

    func testPushToTalk_disablesAutoEndpointAndStopsOnRelease() async {
        recognizer.holdOpen = true
        recognizer.heldFinal = "你好"
        session.holdBegan(.me)
        await waitUntil("进入聆听") { self.session.phase == .listening(.me) && self.recognizer.lastAutoEndpoint != nil }
        XCTAssertEqual(recognizer.lastAutoEndpoint, false, "对讲机模式不能被停顿自动截断")

        session.holdEnded(.me)
        XCTAssertEqual(recognizer.stopCount, 1)
        await waitUntil { self.session.currentTurn?.state == .done }
        XCTAssertEqual(session.currentTurn?.sourceText, "你好")
    }

    func testTapMode_usesAutoEndpoint() async {
        recognizer.script = [.final("你好")]
        session.micTapped(.me)
        await waitUntil { self.session.currentTurn?.state == .done }
        XCTAssertEqual(recognizer.lastAutoEndpoint, true)
    }

    func testTapWhileListening_stopsEarly() async {
        recognizer.holdOpen = true
        recognizer.heldFinal = "提前结束"
        session.micTapped(.me)
        await waitUntil { self.session.phase == .listening(.me) && self.recognizer.lastAutoEndpoint != nil }
        session.micTapped(.me)
        XCTAssertEqual(recognizer.stopCount, 1)
        await waitUntil { self.session.currentTurn?.state == .done }
        XCTAssertEqual(session.currentTurn?.sourceText, "提前结束")
    }

    func testTapOtherMicWhileListening_isIgnored() async {
        recognizer.holdOpen = true
        session.micTapped(.me)
        await waitUntil { self.session.phase == .listening(.me) && self.recognizer.lastAutoEndpoint != nil }
        session.micTapped(.them)
        XCTAssertEqual(recognizer.stopCount, 0, "聆听中点对面的麦克风不应打断")
        XCTAssertEqual(session.phase, .listening(.me))
        session.cancelAll()
    }

    // MARK: 其他

    func testSwapLanguages_onlyWhenIdle() async {
        session.swapLanguages()
        XCTAssertEqual(session.me, .en)
        XCTAssertEqual(session.them, .zhHans)

        recognizer.holdOpen = true
        session.micTapped(.me)
        await waitUntil { self.session.phase == .listening(.me) && self.recognizer.lastAutoEndpoint != nil }
        session.swapLanguages()
        XCTAssertEqual(session.me, .en, "聆听中不能换语言")
        session.cancelAll()
    }

    func testCancelAll_returnsToIdleAndStopsSpeech() async {
        recognizer.holdOpen = true
        session.micTapped(.me)
        await waitUntil { self.session.phase == .listening(.me) }
        session.cancelAll()
        XCTAssertEqual(session.phase, .idle)
        XCTAssertGreaterThanOrEqual(synthesizer.stopCount, 1)
    }

    func testClear_removesTurnsAndNotice() async {
        recognizer.script = [.final("你好")]
        session.micTapped(.me)
        await waitUntil { self.session.currentTurn?.state == .done }
        session.clear()
        XCTAssertTrue(session.turns.isEmpty)
        XCTAssertNil(session.notice)
        XCTAssertEqual(session.phase, .idle)
    }

    func testDemoSeeds() {
        session.seed(.m3)
        XCTAssertEqual(session.currentTurn?.state, .speaking)
        session.seed(.m4)
        XCTAssertEqual(session.phase, .listening(.them))
        session.seed(.m1)
        XCTAssertTrue(session.turns.isEmpty)
    }
}
