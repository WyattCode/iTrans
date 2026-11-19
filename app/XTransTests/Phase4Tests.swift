import SwiftData
import UIKit
import XCTest
@testable import XTrans

// MARK: - 假实现

/// 每次 listen() 依次取出一段脚本；脚本用完后表现为"一直没人说话"（空的最终结果）。
@MainActor
final class QueueRecognizer: SpeechRecognizing {
    var permission: PermissionResult = .granted
    var scripts: [[RecognitionEvent]] = []
    private(set) var listenCount = 0
    private(set) var locales: [String] = []

    func requestPermissions() async -> PermissionResult { permission }

    func listen(locale: Locale, autoEndpoint: Bool) -> AsyncThrowingStream<RecognitionEvent, Error> {
        listenCount += 1
        locales.append(locale.identifier)
        let script = scripts.isEmpty ? [RecognitionEvent.final("")] : scripts.removeFirst()
        return AsyncThrowingStream { c in
            for e in script { c.yield(e) }
            c.finish()
        }
    }

    func stop() {}
}

struct StubTextRecognizer: TextRecognizing {
    var lines: [String] = []
    var error: Error?
    func recognize(_ image: UIImage, languages: [String]) async throws -> [RecognizedLine] {
        if let error { throw error }
        return lines.map { RecognizedLine(text: $0, box: .zero) }
    }
}

// MARK: - 同声传译 / 来源类型 / 辅助方法

@MainActor
final class Phase4SessionTests: XCTestCase {
    private var recognizer: QueueRecognizer!
    private var synthesizer: FakeSynthesizer!
    private var engine: ScriptedEngine!
    private var history: FakeHistory!
    private var session: ConversationSession!

    override func setUp() async throws {
        recognizer = QueueRecognizer()
        synthesizer = FakeSynthesizer()
        engine = ScriptedEngine()
        history = FakeHistory()
        session = ConversationSession(recognizer: recognizer, synthesizer: synthesizer, engine: engine, history: history)
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

    // MARK: 同声传译

    func testEavesdrop_translatesEverySentenceWithoutSpeaking() async {
        recognizer.scripts = [[.final("Hello everyone")], [.final("Welcome to the meeting")]]
        session.startEavesdrop()
        XCTAssertTrue(session.isEavesdropping)

        await waitUntil("两句都翻译完") { self.session.turns.filter { $0.state == .done }.count >= 2 }
        let done = session.turns.filter { $0.state == .done }
        XCTAssertEqual(done.map(\.sourceText), ["Hello everyone", "Welcome to the meeting"])
        XCTAssertEqual(done.map(\.translatedText), ["T(Hello everyone)", "T(Welcome to the meeting)"])
        XCTAssertTrue(done.allSatisfy { $0.speaker == .them && $0.kind == .eavesdrop })
        XCTAssertEqual(engine.calls.first?.from, "en", "按对方的语言识别和翻译")
        XCTAssertEqual(engine.calls.first?.to, "zh-Hans")
        XCTAssertTrue(synthesizer.spoken.isEmpty, "同声传译时绝不朗读")
        XCTAssertEqual(recognizer.locales.first, "en-US")
        XCTAssertEqual(history.saved.count, 2, "同声传译的每一句也要保存")

        session.stopEavesdrop()
        XCTAssertFalse(session.isEavesdropping)
        XCTAssertEqual(session.phase, .idle)
    }

    func testEavesdrop_stopsLoopingAfterStop() async {
        session.startEavesdrop()
        await waitUntil("至少听了几轮") { self.recognizer.listenCount >= 3 }
        session.stopEavesdrop()
        try? await Task.sleep(for: .milliseconds(60))
        let count = recognizer.listenCount
        try? await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(recognizer.listenCount, count, "停止后不能继续聆听")
    }

    func testEavesdrop_silenceLeavesNoEmptyTurnsAndNoNotice() async {
        session.startEavesdrop()
        await waitUntil { self.recognizer.listenCount >= 3 }
        XCTAssertNil(session.notice, "同声传译时没人说话不是错误，不该一直提示没听清")
        XCTAssertFalse(session.turns.contains { $0.sourceText.isEmpty && $0.state != .listening })
        session.stopEavesdrop()
    }

    func testEavesdrop_permissionDeniedStopsInsteadOfSpinning() async {
        recognizer.permission = .microphoneDenied
        session.startEavesdrop()
        await waitUntil { !self.session.isEavesdropping }
        XCTAssertEqual(session.notice, .microphoneDenied)
        XCTAssertEqual(recognizer.listenCount, 0)
    }

    func testEavesdrop_startTwiceIsIdempotent() async {
        session.startEavesdrop()
        session.startEavesdrop()
        XCTAssertTrue(session.isEavesdropping)
        session.stopEavesdrop()
    }

    func testNewConversation_endsEavesdrop() async {
        session.startEavesdrop()
        session.newConversation()
        XCTAssertFalse(session.isEavesdropping)
    }

    // MARK: 外来文字（图片 / 粘贴）

    func testAddIncoming_isPartnersTurnWithTranslationAndPersists() {
        let id = session.addIncoming(source: "Menu\nRamen", translated: "菜单\n拉面", kind: .photo)
        let turn = session.turns.first { $0.id == id }
        XCTAssertEqual(turn?.speaker, .them)
        XCTAssertEqual(turn?.kind, .photo)
        XCTAssertEqual(turn?.state, .done)
        XCTAssertEqual(session.text(of: turn!, on: .me), "菜单\n拉面", "我这一侧显示译文")
        XCTAssertEqual(session.text(of: turn!, on: .them), "Menu\nRamen", "对方那一侧显示原文")
        XCTAssertEqual(history.saved.last?.turn.kind, .photo)
    }

    func testTypedMessagesAreMarkedAsText() async {
        session.sendText("你好")
        await waitUntil { self.session.currentTurn?.state == .done }
        XCTAssertEqual(session.currentTurn?.kind, .text)
    }

    func testVoiceTurnsAreMarkedAsVoice() async {
        recognizer.scripts = [[.final("你好")]]
        session.micTapped(.me)
        await waitUntil { self.session.currentTurn?.state == .done }
        XCTAssertEqual(session.currentTurn?.kind, .voice)
    }

    func testTurnKindLabels() {
        XCTAssertNil(TurnKind.voice.label)
        XCTAssertNil(TurnKind.text.label)
        XCTAssertEqual(TurnKind.photo.label, "图片文字")
        XCTAssertEqual(TurnKind.paste.label, "粘贴")
        XCTAssertEqual(TurnKind.eavesdrop.label, "只听不说")
    }

    func testTranslateText_doesNotTouchConversation() async throws {
        let result = try await session.translateText("hi", from: .en, to: .zhHans)
        XCTAssertEqual(result, "T(hi)")
        XCTAssertTrue(session.turns.isEmpty)
        XCTAssertTrue(history.saved.isEmpty)
    }

    func testSpeak_readsInGivenLanguage() async {
        session.speak("你好", in: .zhHans)
        await waitUntil { !self.synthesizer.spoken.isEmpty }
        XCTAssertEqual(synthesizer.spoken.first?.code, "zh-CN")
        XCTAssertTrue(session.turns.isEmpty)
    }
}

// MARK: - 逐行翻译模型（图片 / 粘贴共用）

@MainActor
final class LinesModelTests: XCTestCase {
    private var session: ConversationSession!
    private var engine: ScriptedEngine!

    override func setUp() async throws {
        engine = ScriptedEngine()
        session = ConversationSession(recognizer: QueueRecognizer(), synthesizer: FakeSynthesizer(), engine: engine)
    }

    func testImage_recognizesThenTranslatesEachLineIntoMyLanguage() async {
        let model = LinesModel()
        await model.load(source: .image(UIImage()), session: session,
                         recognizer: StubTextRecognizer(lines: ["Ramen ¥900", "Dumplings ¥450"]))
        XCTAssertEqual(model.phase, .ready)
        XCTAssertEqual(model.items.map(\.original), ["Ramen ¥900", "Dumplings ¥450"])
        XCTAssertEqual(model.items.map(\.translation), ["T(Ramen ¥900)", "T(Dumplings ¥450)"])
        XCTAssertEqual(engine.calls.first?.from, "en", "图片里的字按对方语言翻成我的语言")
        XCTAssertEqual(engine.calls.first?.to, "zh-Hans")
        XCTAssertEqual(model.selectedCount, 2, "默认全选")
    }

    func testLines_skipRecognizer() async {
        let model = LinesModel()
        await model.load(source: .lines(["Excuse me", "Where is the station?"]), session: session,
                         recognizer: StubTextRecognizer(error: TextRecognitionError.invalidImage))
        XCTAssertEqual(model.phase, .ready, "粘贴文字不需要识别，识别器出错也不该影响")
        XCTAssertEqual(model.items.count, 2)
    }

    func testNoTextFound_isEmptyState() async {
        let model = LinesModel()
        await model.load(source: .image(UIImage()), session: session, recognizer: StubTextRecognizer(lines: []))
        XCTAssertEqual(model.phase, .empty)
        XCTAssertTrue(model.items.isEmpty)
    }

    func testRecognizerFailure_isReported() async {
        let model = LinesModel()
        await model.load(source: .image(UIImage()), session: session,
                         recognizer: StubTextRecognizer(error: TextRecognitionError.invalidImage))
        XCTAssertEqual(model.phase, .failed("这张图片无法读取"))
    }

    func testSelection_onlyChosenAndTranslatedLinesAreSent() async {
        let model = LinesModel()
        await model.load(source: .lines(["a", "b", "c"]), session: session, recognizer: StubTextRecognizer())
        model.items[1].selected = false
        XCTAssertEqual(model.selectedCount, 2)
        XCTAssertEqual(model.selectedOriginals, ["a", "c"])
        XCTAssertEqual(model.selectedTranslations, ["T(a)", "T(c)"])
    }

    func testTranslationFailure_keepsListAndAllowsRetry() async {
        engine.shouldFail = true
        let model = LinesModel()
        await model.load(source: .lines(["a", "b"]), session: session, recognizer: StubTextRecognizer())
        XCTAssertEqual(model.phase, .ready)
        XCTAssertNotNil(model.translationError)
        XCTAssertTrue(model.selectedTranslations.isEmpty, "没有译文的行不能被发送")

        engine.shouldFail = false
        await model.translateAll(session: session)
        XCTAssertNil(model.translationError)
        XCTAssertEqual(model.selectedTranslations, ["T(a)", "T(b)"])
    }

    func testLoad_isOnlyDoneOnce() async {
        let model = LinesModel()
        await model.load(source: .lines(["a"]), session: session, recognizer: StubTextRecognizer())
        await model.load(source: .lines(["a"]), session: session, recognizer: StubTextRecognizer())
        XCTAssertEqual(engine.calls.count, 1, "视图重新出现时不能重复翻译")
    }
}

// MARK: - 真实的 Vision 文字识别

@MainActor
final class VisionRecognizerTests: XCTestCase {
    /// 画一张白底黑字的图（大字号、高对比度，Vision 在模拟器上也能稳定识别）。
    private func image(with lines: [String]) -> UIImage {
        let size = CGSize(width: 1200, height: 150 * CGFloat(lines.count) + 100)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 90, weight: .bold),
                .foregroundColor: UIColor.black,
            ]
            for (i, line) in lines.enumerated() {
                (line as NSString).draw(at: CGPoint(x: 50, y: 50 + CGFloat(i) * 150), withAttributes: attrs)
            }
        }
    }

    func testRecognizesPrintedEnglishLinesTopToBottom() async throws {
        let lines = try await VisionTextRecognizer().recognize(image(with: ["Hello World", "Ramen 900"]), languages: ["en-US"])
        let texts = lines.map(\.text)
        XCTAssertEqual(texts.count, 2, "识别结果：\(texts)")
        XCTAssertTrue(texts[0].localizedCaseInsensitiveContains("hello"), "第一行应是 Hello World，实际：\(texts)")
        XCTAssertTrue(texts[1].localizedCaseInsensitiveContains("ramen"), "第二行应是 Ramen 900，实际：\(texts)")
        XCTAssertGreaterThan(lines[0].box.maxY, lines[1].box.maxY, "按从上到下排序")
    }

    func testBlankImageYieldsNoLines() async throws {
        let blank = UIGraphicsImageRenderer(size: CGSize(width: 600, height: 300)).image { ctx in
            UIColor.white.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 600, height: 300))
        }
        let lines = try await VisionTextRecognizer().recognize(blank, languages: ["en-US"])
        XCTAssertTrue(lines.isEmpty)
    }

    func testUnsupportedLanguageCodesAreIgnoredNotFatal() async throws {
        let lines = try await VisionTextRecognizer().recognize(image(with: ["Hello"]), languages: ["xx-YY", "en-US"])
        XCTAssertFalse(lines.isEmpty)
    }

    func testImageWithoutCGImageThrows() async {
        do {
            _ = try await VisionTextRecognizer().recognize(UIImage(), languages: [])
            XCTFail("空图片应该抛错")
        } catch {
            XCTAssertTrue(error is TextRecognitionError)
        }
    }

    func testOCRCodes() {
        XCTAssertEqual(LanguageOption.zhHans.ocrCode, "zh-Hans")
        XCTAssertEqual(LanguageOption.en.ocrCode, "en-US")
    }
}

// MARK: - 短语库 + 来源类型持久化

@MainActor
final class PhraseLibraryTests: XCTestCase {
    // ModelContext 不会持有 ModelContainer：container 必须由测试自己保存，否则会被提前释放导致崩溃。
    private var container: ModelContainer!
    private var context: ModelContext { container.mainContext }

    override func setUp() async throws {
        container = try SwiftDataHistoryStore.makeContainer(inMemory: true)
    }

    private func all() -> [PhraseRecord] {
        (try? context.fetch(FetchDescriptor<PhraseRecord>())) ?? []
    }

    func testAdd_trimsAndStores() {
        XCTAssertTrue(PhraseLibrary.add(text: "  我对花生过敏 ", translated: "I'm allergic to peanuts.", language: .zhHans, in: context))
        XCTAssertEqual(all().count, 1)
        XCTAssertEqual(all()[0].text, "我对花生过敏")
        XCTAssertEqual(all()[0].translatedText, "I'm allergic to peanuts.")
        XCTAssertEqual(all()[0].langID, "zh-Hans")
    }

    func testAdd_rejectsEmptyAndDuplicates() {
        XCTAssertFalse(PhraseLibrary.add(text: "   ", translated: nil, language: .zhHans, in: context))
        XCTAssertTrue(PhraseLibrary.add(text: "谢谢", translated: nil, language: .zhHans, in: context))
        XCTAssertFalse(PhraseLibrary.add(text: " 谢谢 ", translated: "Thanks", language: .zhHans, in: context), "同语言同文字不重复收藏")
        XCTAssertEqual(all().count, 1)
    }

    func testSameTextInAnotherLanguageIsAllowed() {
        XCTAssertTrue(PhraseLibrary.add(text: "OK", translated: nil, language: .zhHans, in: context))
        XCTAssertTrue(PhraseLibrary.add(text: "OK", translated: nil, language: .en, in: context))
        XCTAssertEqual(all().count, 2)
    }

    func testContains() {
        PhraseLibrary.add(text: "谢谢", translated: nil, language: .zhHans, in: context)
        XCTAssertTrue(PhraseLibrary.contains(text: "谢谢", language: .zhHans, in: context))
        XCTAssertFalse(PhraseLibrary.contains(text: "谢谢", language: .en, in: context))
        XCTAssertFalse(PhraseLibrary.contains(text: "再见", language: .zhHans, in: context))
    }

    func testSorted_pinnedFirstThenNewest() {
        let old = PhraseRecord(text: "旧", langID: "zh-Hans", createdAt: Date(timeIntervalSince1970: 100))
        let new = PhraseRecord(text: "新", langID: "zh-Hans", createdAt: Date(timeIntervalSince1970: 300))
        let pinnedOld = PhraseRecord(text: "置顶", langID: "zh-Hans", pinned: true, createdAt: Date(timeIntervalSince1970: 50))
        XCTAssertEqual(PhraseLibrary.sorted([old, new, pinnedOld]).map(\.text), ["置顶", "新", "旧"])
    }

    func testTogglePinnedAndDelete() {
        PhraseLibrary.add(text: "谢谢", translated: nil, language: .zhHans, in: context)
        let phrase = all()[0]
        PhraseLibrary.togglePinned(phrase, in: context)
        XCTAssertTrue(all()[0].pinned)
        PhraseLibrary.togglePinned(phrase, in: context)
        XCTAssertFalse(all()[0].pinned)
        PhraseLibrary.delete(phrase, in: context)
        XCTAssertTrue(all().isEmpty)
    }

    func testTurnKindSurvivesStoreRoundTrip() throws {
        let store = SwiftDataHistoryStore(container: try SwiftDataHistoryStore.makeContainer(inMemory: true))
        let info = ConversationInfo(id: UUID(), title: "t", me: .zhHans, them: .en, createdAt: Date())
        for kind in [TurnKind.voice, .text, .photo, .paste, .eavesdrop] {
            store.save(Turn(speaker: .them, sourceText: kind.rawValue, translatedText: "x", state: .done,
                            createdAt: Date(timeIntervalSince1970: Double(kind.hashValue & 0xFFFF)), kind: kind), in: info)
        }
        let kinds = Set(store.turns(in: info.id).map(\.kind))
        XCTAssertEqual(kinds, [.voice, .text, .photo, .paste, .eavesdrop])
    }
}
