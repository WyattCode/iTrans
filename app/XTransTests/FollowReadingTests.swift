import XCTest
@testable import XTrans

/// 跟读窗口：译文分句、读到哪一句、会话里的朗读进度。
@MainActor
final class FollowReadingTests: XCTestCase {
    private func waitUntil(_ message: String, timeout: Duration = .seconds(2), _ condition: () -> Bool,
                           file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            if ContinuousClock.now > deadline { XCTFail("等待超时：\(message)", file: file, line: line); return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    // MARK: 按下即听：轻点 → 自动模式

    func testHoldStaysPushToTalkMode() async {
        let rec = FakeRecognizer(); rec.holdOpen = true
        let session = ConversationSession(recognizer: rec, synthesizer: FakeSynthesizer(), engine: ScriptedEngine())
        XCTAssertTrue(session.holdBegan(.me))
        await waitUntil("开始聆听") { rec.lastAutoEndpoint != nil }
        XCTAssertEqual(rec.lastAutoEndpoint, false, "按住 = 对讲：不自动结束")
        session.holdEnded(.me)
    }

    func testQuickTapAfterRecognizerStartedSwitchesToAutoMode() async {
        let rec = FakeRecognizer(); rec.holdOpen = true
        let session = ConversationSession(recognizer: rec, synthesizer: FakeSynthesizer(), engine: ScriptedEngine())
        session.holdBegan(.me)
        await waitUntil("开始聆听") { rec.lastAutoEndpoint != nil }
        session.holdPromotedToTap(.me)
        XCTAssertEqual(rec.autoEndpointEnabledCount, 1)
        session.stopListening()
    }

    func testQuickTapBeforeRecognizerStartedStartsInAutoMode() async {
        let rec = FakeRecognizer(); rec.holdOpen = true
        let session = ConversationSession(recognizer: rec, synthesizer: FakeSynthesizer(), engine: ScriptedEngine())
        session.holdBegan(.me)
        session.holdPromotedToTap(.me)               // 识别任务还没排到：标记要先记下
        await waitUntil("开始聆听") { rec.lastAutoEndpoint != nil }
        XCTAssertEqual(rec.lastAutoEndpoint, true)
        session.stopListening()
    }

    func testNextPressStartsFreshInPushToTalkMode() async {
        let rec = FakeRecognizer(); rec.holdOpen = true
        let session = ConversationSession(recognizer: rec, synthesizer: FakeSynthesizer(), engine: ScriptedEngine())
        session.holdBegan(.me)
        session.holdPromotedToTap(.me)
        await waitUntil("第一次开始") { rec.lastAutoEndpoint == true }
        session.stopListening()
        await waitUntil("回到空闲") { session.phase != .listening(.me) }
        session.holdBegan(.me)
        await waitUntil("第二次开始") { session.phase == .listening(.me) && rec.lastAutoEndpoint == false }
        session.holdEnded(.me)
    }

    func testPressWhileAlreadyListeningDoesNotStartAgain() async {
        let rec = FakeRecognizer(); rec.holdOpen = true
        let session = ConversationSession(recognizer: rec, synthesizer: FakeSynthesizer(), engine: ScriptedEngine())
        session.holdBegan(.me)
        await waitUntil("开始聆听") { session.phase == .listening(.me) }
        XCTAssertFalse(session.holdBegan(.me), "已经在听：按下不再开始，松手按轻点停止")
        session.stopListening()
    }

    // MARK: 字号 / 分句缓存

    func testWeightedLengthTreatsCJKAsDoubleWidth() {
        XCTAssertEqual(TextMetrics.weightedLength("你好"), 4)
        XCTAssertEqual(TextMetrics.weightedLength("ab"), 2)
        XCTAssertEqual(TextMetrics.weightedLength("こんにちは"), 10)
        XCTAssertEqual(TextMetrics.weightedLength("안녕"), 4)
    }

    func testSplitIsCachedAndStable() {
        let text = "One. Two. Three."
        XCTAssertEqual(Sentences.split(text), Sentences.split(text))
    }

    // MARK: 朗读器不报进度：按语速估算

    func testEstimatesProgressWhenSynthesizerReportsNothing() async {
        let synth = ProgressSynthesizer()          // 不调用 report：模拟不报进度的声音
        let session = ConversationSession(recognizer: FakeRecognizer(), synthesizer: synth, engine: ScriptedEngine())
        session.progressEstimateDelay = .milliseconds(20)
        session.sendText("hello")
        await synth.waitUntilSpeaking()
        await waitUntil("估算的进度往前走") { session.spokenOffset > 0 }
        synth.finish()
        await waitUntil("读完后清空") { session.speakingTurnID == nil }
        XCTAssertEqual(session.spokenOffset, 0)
    }

    func testEstimateResumesWhenRealCallbacksStall() async {
        let synth = ProgressSynthesizer()
        let session = ConversationSession(recognizer: FakeRecognizer(), synthesizer: synth, engine: ScriptedEngine())
        session.progressEstimateDelay = .milliseconds(10)
        session.progressStallTimeout = .milliseconds(60)
        session.sendText("hello world hello world hello world")
        await synth.waitUntilSpeaking()
        synth.report(4)                            // 只报了一次就不再报
        await waitUntil("回调停滞后，估算接着往前推") { session.spokenOffset > 4 }
        synth.finish()
    }

    func testEstimateScalesWithSpeechRate() async {
        func offsetAfterHalfSecond(rate: Float) async -> Int {
            let synth = ProgressSynthesizer()
            let session = ConversationSession(recognizer: FakeRecognizer(), synthesizer: synth, engine: ScriptedEngine())
            session.progressEstimateDelay = .milliseconds(10)
            session.speechRate = rate
            session.sendText("hello world hello world hello world hello world")
            await synth.waitUntilSpeaking()
            try? await Task.sleep(for: .milliseconds(520))
            let offset = session.spokenOffset
            synth.finish()
            return offset
        }
        let slow = await offsetAfterHalfSecond(rate: 0.3)
        let fast = await offsetAfterHalfSecond(rate: 0.6)
        XCTAssertGreaterThan(fast, slow, "语速快，估算推得也快")
    }

    // MARK: 横向打字：语言条放不放得到正中

    func testTypingStripCenteringRule() {
        XCTAssertTrue(FaceGeometry.centersTypingStrip(width: 866, stripWidth: 340), "Duo 内屏横向：条窄，放得下")
        XCTAssertFalse(FaceGeometry.centersTypingStrip(width: 800, stripWidth: 520), "直板横屏：带按钮的条会盖住麦克风")
        XCTAssertFalse(FaceGeometry.centersTypingStrip(width: 1024, stripWidth: 520), "iPad 横向")
        XCTAssertFalse(FaceGeometry.centersTypingStrip(width: 800, stripWidth: 340), "窄屏连窄条也放不下")
    }

    func testRealProgressTakesOverFromEstimate() async {
        let synth = ProgressSynthesizer()
        let session = ConversationSession(recognizer: FakeRecognizer(), synthesizer: synth, engine: ScriptedEngine())
        session.progressEstimateDelay = .milliseconds(20)
        session.sendText("hello")
        await synth.waitUntilSpeaking()
        synth.report(4)                            // 真实进度到了：估算立刻让位
        try? await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(session.spokenOffset, 4)
        synth.finish()
    }

    func testSplitsChineseAndEnglishSentences() {
        let zh = Sentences.split("打扰一下，我想办理入住。请问早餐几点开始？非常感谢。")
        XCTAssertEqual(zh.map(\.text), ["打扰一下，我想办理入住。", "请问早餐几点开始？", "非常感谢。"])
        XCTAssertEqual(zh.map(\.start), [0, 12, 21])

        let en = Sentences.split("Excuse me. Could you help? Thanks.")
        XCTAssertEqual(en.count, 3)
    }

    func testNoPunctuationIsOneSentence() {
        XCTAssertEqual(Sentences.split("你好").map(\.text), ["你好"])
    }

    func testIndexFollowsSpokenOffset() {
        let s = Sentences.split("打扰一下，我想办理入住。请问早餐几点开始？非常感谢。")
        XCTAssertEqual(Sentences.index(containing: 0, in: s), 0)
        XCTAssertEqual(Sentences.index(containing: 12, in: s), 0, "刚好读完第一句的最后一个字，还停在第一句")
        XCTAssertEqual(Sentences.index(containing: 13, in: s), 1)
        XCTAssertEqual(Sentences.index(containing: 999, in: s), 2)
    }

    func testSessionTracksSpokenProgressAndClearsAfterwards() async {
        let synth = ProgressSynthesizer()
        let session = ConversationSession(recognizer: FakeRecognizer(), synthesizer: synth, engine: ScriptedEngine())
        session.speakOnSend = true
        session.sendText("hello")                  // 走完整的翻译 + 朗读流程
        await synth.waitUntilSpeaking()
        XCTAssertNotNil(session.speakingTurnID)
        synth.report(3)
        synth.report(2)                            // 进度只增不减
        XCTAssertEqual(session.spokenOffset, 3)
        synth.finish()
        for _ in 0..<50 where session.speakingTurnID != nil { try? await Task.sleep(for: .milliseconds(20)) }
        XCTAssertNil(session.speakingTurnID)
        XCTAssertEqual(session.spokenOffset, 0)
    }

    func testTouchDownOnlyPreparesAndNeverStartsListening() {
        let rec = FakeRecognizer()
        let session = ConversationSession(recognizer: rec, synthesizer: FakeSynthesizer(), engine: ScriptedEngine())
        session.prepareToListen()
        XCTAssertEqual(rec.prepareCount, 1, "手指落下时提前预热")
        XCTAssertNil(rec.lastAutoEndpoint, "预热不开始听（也不弹权限框）")
        XCTAssertEqual(session.phase, .idle)
    }

    func testPressTimingsAreShort() {
        XCTAssertLessThanOrEqual(MicButton.graceDelay, .milliseconds(40), "按下到开始听的防误触等待要短")
        XCTAssertLessThanOrEqual(MicButton.holdThreshold, .milliseconds(200))
        XCTAssertLessThan(MicButton.graceDelay, MicButton.holdThreshold)
    }
}

@MainActor
final class ProgressSynthesizer: SpeechSpeaking, SpeechProgressReporting {
    var onProgress: ((Int) -> Void)?
    private var gate: CheckedContinuation<Void, Never>?
    func speak(_ text: String, ttsCode: String, voiceID: String?) async {
        await withCheckedContinuation { gate = $0 }
    }
    func stop() {}
    func report(_ end: Int) { onProgress?(end) }
    func finish() { gate?.resume(); gate = nil }
    func waitUntilSpeaking() async {
        for _ in 0..<100 where gate == nil { try? await Task.sleep(for: .milliseconds(20)) }
    }
}
