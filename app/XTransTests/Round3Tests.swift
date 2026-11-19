import XCTest
@testable import XTrans

/// 第三轮整改的回归测试（2026-11-14）
@MainActor
final class Round3Tests: XCTestCase {
    private var recognizer: FakeRecognizer!
    private var synthesizer: FakeSynthesizer!
    private var engine: ScriptedEngine!
    private var session: ConversationSession!

    override func setUp() async throws {
        recognizer = FakeRecognizer()
        synthesizer = FakeSynthesizer()
        engine = ScriptedEngine()
        session = ConversationSession(recognizer: recognizer, synthesizer: synthesizer, engine: engine, history: FakeHistory())
        session.eavesdropRetryDelay = .milliseconds(5)
    }

    private func waitUntil(_ message: String = "", timeout: Duration = .seconds(2), _ condition: () -> Bool,
                           file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            if ContinuousClock.now > deadline { XCTFail("等待超时：\(message)", file: file, line: line); return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    /// 重选同一种语言：不重写默认值
    func testChoosingSameLanguageIsNoOp() {
        var reports = 0
        session.onLanguageChoice = { _, _ in reports += 1 }
        session.choose(session.them, for: .them)
        session.choose(session.me, for: .me)
        XCTAssertEqual(reports, 0)
    }

    /// 译完一句 `translatedCount` 加一（不朗读时也加）
    func testTranslatedCountIncrementsEvenWithoutSpeaking() async {
        session.speakOnSend = false
        XCTAssertEqual(session.translatedCount, 0)
        _ = session.sendText("你好")
        await waitUntil("译完") { self.session.phase == .idle && self.session.translatedCount == 1 }
        XCTAssertEqual(session.translatedCount, 1)
    }

    /// 同声传译：没有声音的静音周期不往列表里加轮次
    func testEavesdropDoesNotAppendTurnForSilence() async {
        recognizer.script = []          // 一句话也没听到
        session.startEavesdrop()
        try? await Task.sleep(for: .milliseconds(80))
        XCTAssertTrue(session.turns.isEmpty)
        session.stopEavesdrop()
    }

    /// 同声传译：听到内容后才有一轮，译完留在列表里
    func testEavesdropAppendsTurnOnceSpeechArrives() async {
        recognizer.script = [.partial("hello"), .final("hello")]
        session.startEavesdrop()
        await waitUntil("译完一句") { self.session.turns.contains { $0.translatedText != nil } }
        session.stopEavesdrop()
        XCTAssertTrue(session.turns.allSatisfy { $0.kind == .eavesdrop && !$0.sourceText.isEmpty })
    }

    /// 同声传译两句之间（phase 为 idle）不能重译 / 编辑 / 重播，否则会覆盖同声传译循环的 pipeline
    func testRetranslateEditReplayIgnoredDuringEavesdrop() async {
        recognizer.script = [.partial("hello"), .final("hello")]
        session.startEavesdrop()
        await waitUntil("译完一句") { self.session.turns.contains { $0.translatedText != nil } }
        if let id = session.turns.first?.id {
            session.retranslate(id)
            session.editSource(id, to: "changed")
            session.replay(id)
        }
        try? await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(session.turns.first?.sourceText, "hello")
        XCTAssertFalse(engine.calls.contains { $0.text == "changed" })      // 编辑没有生效、也没有被翻译
        session.stopEavesdrop()
    }

    /// 试听 / 单独朗读读完后 `speechIdleTick` 加一（界面据此重新安排归还音频会话）
    func testSpeechIdleTickAfterStandaloneSpeak() async {
        let before = session.speechIdleTick
        session.speak("hello", in: .en)
        await waitUntil("读完") { self.session.speechIdleTick > before }
    }

    /// 同声传译：识别器一启动就「没听清」连着 6 次（不到 2 秒）→ 放弃并提示，别空转
    func testEavesdropGivesUpAfterRepeatedInstantSilence() async {
        recognizer.script = []
        session.startEavesdrop()
        await waitUntil("放弃同声传译") { !self.session.isEavesdropping }
        if case .recognizerUnavailable = session.notice { } else { XCTFail("应该提示识别没有响应") }
    }

    /// 同声传译：翻译不阻塞听下一句（译文最终仍会写进轮次）
    func testEavesdropTranslationDoesNotBlockListening() async {
        recognizer.script = [.partial("hello"), .final("hello")]
        session.startEavesdrop()
        await waitUntil("译完两句") { self.session.turns.filter { $0.translatedText != nil }.count >= 2 }
        session.stopEavesdrop()
    }
}
