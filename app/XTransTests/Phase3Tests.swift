import SwiftData
import XCTest
@testable import XTrans

// MARK: - 假存储

@MainActor
final class FakeHistory: HistoryStoring {
    private(set) var saved: [(turn: Turn, info: ConversationInfo)] = []
    private(set) var deletedTurns: [UUID] = []
    private(set) var deletedConversations: [UUID] = []
    var storedTurns: [UUID: [Turn]] = [:]
    var infos: [UUID: ConversationInfo] = [:]

    func save(_ turn: Turn, in conversation: ConversationInfo) { saved.append((turn, conversation)) }
    func delete(turnID: UUID) { deletedTurns.append(turnID) }
    func deleteConversation(id: UUID) { deletedConversations.append(id) }
    private(set) var deleteAllCount = 0
    func deleteAll() { deleteAllCount += 1 }
    private(set) var renamed: [(id: UUID, title: String)] = []
    private(set) var favorites: [(id: UUID, value: Bool)] = []
    func rename(conversationID: UUID, to title: String) { renamed.append((conversationID, title)) }
    func setFavorite(_ value: Bool, conversationID: UUID) { favorites.append((conversationID, value)) }
    func turns(in conversationID: UUID) -> [Turn] { storedTurns[conversationID] ?? [] }
    func info(of conversationID: UUID) -> ConversationInfo? { infos[conversationID] }
}

// MARK: - 状态机：键盘输入 / 对话管理

@MainActor
final class Phase3SessionTests: XCTestCase {
    private var recognizer: FakeRecognizer!
    private var synthesizer: FakeSynthesizer!
    private var engine: ScriptedEngine!
    private var history: FakeHistory!
    private var session: ConversationSession!

    override func setUp() async throws {
        recognizer = FakeRecognizer()
        synthesizer = FakeSynthesizer()
        engine = ScriptedEngine()
        history = FakeHistory()
        session = ConversationSession(recognizer: recognizer, synthesizer: synthesizer, engine: engine, history: history)
        session.previewDelay = .milliseconds(5)
    }

    private func waitUntil(_ message: String = "", timeout: Duration = .seconds(2), _ condition: () -> Bool,
                           file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            if ContinuousClock.now > deadline { XCTFail("等待超时：\(message)", file: file, line: line); return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func sendAndWait(_ text: String) async {
        session.sendText(text)
        await waitUntil("发送完成") { self.session.phase == .idle && self.session.currentTurn?.state == .done }
    }

    // MARK: 文字发送

    func testSendText_translatesSpeaksAndPersists() async {
        await sendAndWait("  我在车站东口等你  ")
        let turn = session.currentTurn
        XCTAssertEqual(turn?.speaker, .me)
        XCTAssertEqual(turn?.sourceText, "我在车站东口等你", "首尾空白要去掉")
        XCTAssertEqual(turn?.translatedText, "T(我在车站东口等你)")
        XCTAssertEqual(synthesizer.spoken.first?.code, "en-US")
        XCTAssertEqual(history.saved.last?.turn.id, turn?.id, "每一轮完成后要保存")
        XCTAssertEqual(history.saved.last?.info.id, session.conversationID)
        XCTAssertEqual(session.draft, "")
    }

    func testSendText_displayOnly_doesNotSpeak() async {
        session.speakOnSend = false
        await sendAndWait("你好")
        XCTAssertTrue(synthesizer.spoken.isEmpty)
        XCTAssertEqual(session.currentTurn?.translatedText, "T(你好)")
    }

    func testSendText_emptyIsIgnored() {
        session.sendText("   \n ")
        XCTAssertTrue(session.turns.isEmpty)
        XCTAssertEqual(session.phase, .idle)
    }

    func testSendText_ignoredWhileListening() async {
        recognizer.holdOpen = true
        session.micTapped(.me)
        await waitUntil { self.session.phase == .listening(.me) && self.recognizer.lastAutoEndpoint != nil }
        let before = session.turns.count
        session.sendText("不该发出去")
        XCTAssertEqual(session.turns.count, before)
        session.cancelAll()
    }

    func testSendDraft_usesDraftAndClearsIt() async {
        session.updateDraft("你好")
        session.sendDraft()
        await waitUntil { self.session.currentTurn?.state == .done }
        XCTAssertEqual(session.currentTurn?.sourceText, "你好")
        XCTAssertEqual(session.draft, "")
        XCTAssertEqual(session.preview, .idle)
    }

    func testSendText_translationFailureKeepsSourceAndPersists() async {
        engine.shouldFail = true
        session.sendText("你好")
        await waitUntil { if case .failed = self.session.currentTurn?.state { return true } else { return false } }
        XCTAssertEqual(session.currentTurn?.sourceText, "你好")
        XCTAssertEqual(history.saved.last?.turn.sourceText, "你好", "失败的轮次也要保存原话，之后可以重试")
        XCTAssertNil(history.saved.last?.turn.translatedText)
    }

    // MARK: 预览

    func testDraftPreview_translatesAfterDebounce() async {
        session.updateDraft("你好")
        XCTAssertEqual(session.preview, .loading)
        await waitUntil("预览出现") { self.session.preview == .ready("T(你好)") }
        XCTAssertEqual(engine.calls.last?.from, "zh-Hans")
        XCTAssertEqual(engine.calls.last?.to, "en")
        XCTAssertTrue(synthesizer.spoken.isEmpty, "预览不能朗读")
        XCTAssertTrue(history.saved.isEmpty, "预览不能落盘")
    }

    func testDraftPreview_debouncesRapidTyping() async {
        session.previewDelay = .milliseconds(80)
        session.updateDraft("你")
        session.updateDraft("你好")
        session.updateDraft("你好吗")
        await waitUntil { self.session.preview == .ready("T(你好吗)") }
        XCTAssertEqual(engine.calls.count, 1, "连续输入只应翻译最后一次")
    }

    func testDraftPreview_clearingResetsToIdle() async {
        session.updateDraft("你好")
        session.updateDraft("")
        XCTAssertEqual(session.preview, .idle)
        try? await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(session.preview, .idle, "清空后不能被晚到的翻译覆盖")
        XCTAssertTrue(engine.calls.isEmpty)
    }

    func testDraftPreview_failureIsReported() async {
        engine.shouldFail = true
        session.updateDraft("你好")
        await waitUntil { self.session.preview == .failed }
    }

    // MARK: 对已有轮次的操作

    func testEditSource_retranslatesWithoutSpeaking() async {
        await sendAndWait("请问最进的地铁站")
        let id = session.currentTurn!.id
        let spokenBefore = synthesizer.spoken.count
        session.editSource(id, to: "请问最近的地铁站")
        await waitUntil { self.session.currentTurn?.translatedText == "T(请问最近的地铁站)" && self.session.phase == .idle }
        XCTAssertEqual(session.currentTurn?.sourceText, "请问最近的地铁站")
        XCTAssertEqual(synthesizer.spoken.count, spokenBefore, "修正原文只更新文字，不重新朗读")
        XCTAssertEqual(history.saved.last?.turn.sourceText, "请问最近的地铁站", "修正后要重新保存")
    }

    func testEditSource_emptyIsRejected() async {
        await sendAndWait("你好")
        session.editSource(session.currentTurn!.id, to: "  ")
        XCTAssertEqual(session.currentTurn?.sourceText, "你好")
    }

    func testReplay_speaksTranslationInTargetLanguage() async {
        await sendAndWait("你好")
        let before = synthesizer.spoken.count
        session.replay(session.currentTurn!.id)
        await waitUntil { self.session.phase == .idle && self.session.currentTurn?.state == .done }
        XCTAssertEqual(synthesizer.spoken.count, before + 1)
        XCTAssertEqual(synthesizer.spoken.last?.text, "T(你好)")
        XCTAssertEqual(synthesizer.spoken.last?.code, "en-US")
    }

    func testDeleteTurn_removesFromListAndStore() async {
        await sendAndWait("一")
        await sendAndWait("二")
        let first = session.turns[0].id
        session.deleteTurn(first)
        XCTAssertEqual(session.turns.map(\.sourceText), ["二"])
        XCTAssertEqual(history.deletedTurns, [first])
        XCTAssertTrue(history.deletedConversations.isEmpty)
    }

    func testDeleteLastTurn_removesConversationFromStore() async {
        await sendAndWait("一")
        session.deleteTurn(session.turns[0].id)
        XCTAssertTrue(session.turns.isEmpty)
        XCTAssertEqual(history.deletedConversations, [session.conversationID], "删光最后一条，这场对话也不该留在历史里")
    }

    // MARK: 对话管理

    func testNewConversation_resetsEverything() async {
        await sendAndWait("你好")
        let oldID = session.conversationID
        session.updateDraft("没发出去的草稿")
        session.newConversation()
        XCTAssertNotEqual(session.conversationID, oldID)
        XCTAssertTrue(session.turns.isEmpty)
        XCTAssertEqual(session.draft, "")
        XCTAssertEqual(session.preview, .idle)
        XCTAssertEqual(session.title, "新对话")
    }

    func testLoad_restoresTurnsLanguagesAndContinuesSameConversation() async {
        let id = UUID()
        let created = Date(timeIntervalSince1970: 1_000_000)
        history.infos[id] = ConversationInfo(id: id, title: "t", me: .en, them: .zhHans, createdAt: created)
        history.storedTurns[id] = [Turn(speaker: .me, sourceText: "Hello", translatedText: "你好", state: .done)]

        session.load(id)
        XCTAssertEqual(session.conversationID, id)
        XCTAssertEqual(session.me, .en)
        XCTAssertEqual(session.them, .zhHans)
        XCTAssertEqual(session.turns.count, 1)
        XCTAssertEqual(session.conversationCreatedAt, created)

        await sendAndWait("How are you?")
        XCTAssertEqual(history.saved.last?.info.id, id, "接着聊的新消息要存进同一场对话")
        XCTAssertEqual(engine.calls.last?.from, "en")
    }

    func testLoad_unknownIDChangesNothing() async {
        await sendAndWait("你好")
        let id = session.conversationID
        session.load(UUID())
        XCTAssertEqual(session.conversationID, id)
        XCTAssertEqual(session.turns.count, 1)
    }

    func testDeleteConversation_currentOneStartsFresh() async {
        await sendAndWait("你好")
        let id = session.conversationID
        session.deleteConversation(id)
        XCTAssertEqual(history.deletedConversations, [id])
        XCTAssertNotEqual(session.conversationID, id)
        XCTAssertTrue(session.turns.isEmpty)
    }

    func testDeleteConversation_otherOneKeepsCurrent() async {
        await sendAndWait("你好")
        let current = session.conversationID
        session.deleteConversation(UUID())
        XCTAssertEqual(session.conversationID, current)
        XCTAssertEqual(session.turns.count, 1)
    }

    func testTitle_isFirstSentenceTruncated() async {
        await sendAndWait("这是一句特别特别特别特别特别特别特别特别长的话用来测试标题截断")
        XCTAssertTrue(session.title.hasSuffix("…"))
        XCTAssertEqual(session.title.count, 25)
    }

    func testTranscript_listsBothSidesWithLanguages() async {
        await sendAndWait("你好")
        let text = session.transcript()
        XCTAssertTrue(text.contains("我（中文）：你好"))
        XCTAssertTrue(text.contains("→（English）T(你好)"))
    }
}

// MARK: - SwiftData 存储（内存容器）

@MainActor
final class SwiftDataHistoryStoreTests: XCTestCase {
    private var store: SwiftDataHistoryStore!

    override func setUp() async throws {
        store = SwiftDataHistoryStore(container: try SwiftDataHistoryStore.makeContainer(inMemory: true))
    }

    private func info(_ id: UUID = UUID(), title: String = "标题") -> ConversationInfo {
        ConversationInfo(id: id, title: title, me: .zhHans, them: .en, createdAt: Date(timeIntervalSince1970: 5_000))
    }

    func testSaveAndLoad_roundTripsAllFieldsInOrder() {
        let i = info()
        let t1 = Turn(speaker: .me, sourceText: "你好", translatedText: "Hello", state: .done,
                      engineName: "Apple 端侧", latency: 0.3, createdAt: Date(timeIntervalSince1970: 100))
        let t2 = Turn(speaker: .them, sourceText: "Hi", translatedText: "嗨", state: .done,
                      createdAt: Date(timeIntervalSince1970: 200))
        store.save(t2, in: i)      // 故意倒序保存，验证读取时按时间排序
        store.save(t1, in: i)

        let loaded = store.turns(in: i.id)
        XCTAssertEqual(loaded.map(\.id), [t1.id, t2.id])
        XCTAssertEqual(loaded[0].speaker, .me)
        XCTAssertEqual(loaded[0].translatedText, "Hello")
        XCTAssertEqual(loaded[0].engineName, "Apple 端侧")
        XCTAssertEqual(loaded[0].latency, 0.3)
        XCTAssertEqual(loaded[1].speaker, .them)
        XCTAssertEqual(loaded[0].state, .done)
    }

    func testSave_sameTurnTwiceUpdatesInsteadOfDuplicating() {
        let i = info()
        var turn = Turn(speaker: .me, sourceText: "错字", translatedText: "x", state: .done)
        store.save(turn, in: i)
        turn.sourceText = "正字"
        turn.translatedText = "y"
        store.save(turn, in: i)
        let loaded = store.turns(in: i.id)
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].sourceText, "正字")
        XCTAssertEqual(loaded[0].translatedText, "y")
    }

    func testTurnWithoutTranslation_loadsAsFailed() {
        let i = info()
        store.save(Turn(speaker: .me, sourceText: "没翻出来", state: .failed("x")), in: i)
        let loaded = store.turns(in: i.id)
        XCTAssertEqual(loaded.count, 1)
        if case .failed = loaded[0].state {} else { XCTFail("没有译文的轮次载入后应显示为失败，才能重试") }
    }

    func testInfo_restoresLanguagesAndFallsBackForUnknown() {
        let i = ConversationInfo(id: UUID(), title: "t", me: .en, them: LanguageOption.all[2], createdAt: Date(timeIntervalSince1970: 9))
        store.save(Turn(speaker: .me, sourceText: "a", translatedText: "b", state: .done), in: i)
        let loaded = store.info(of: i.id)
        XCTAssertEqual(loaded?.me, .en)
        XCTAssertEqual(loaded?.them.id, "ja")
        XCTAssertEqual(loaded?.createdAt, Date(timeIntervalSince1970: 9))
        XCTAssertNil(store.info(of: UUID()))
    }

    func testDeleteTurn_andDeleteConversationCascade() {
        let i = info()
        let a = Turn(speaker: .me, sourceText: "a", translatedText: "A", state: .done)
        let b = Turn(speaker: .me, sourceText: "b", translatedText: "B", state: .done)
        store.save(a, in: i)
        store.save(b, in: i)
        store.delete(turnID: a.id)
        XCTAssertEqual(store.turns(in: i.id).map(\.id), [b.id])

        store.deleteConversation(id: i.id)
        XCTAssertNil(store.info(of: i.id))
        XCTAssertTrue(store.turns(in: i.id).isEmpty)
        // 级联删除：轮次记录也不能残留
        let leftovers = try? store.container.mainContext.fetch(FetchDescriptor<TurnRecord>())
        XCTAssertEqual(leftovers?.count, 0)
    }

    func testConversationsAreIsolated() {
        let i1 = info(), i2 = info()
        store.save(Turn(speaker: .me, sourceText: "1", translatedText: "1", state: .done), in: i1)
        store.save(Turn(speaker: .me, sourceText: "2", translatedText: "2", state: .done), in: i2)
        XCTAssertEqual(store.turns(in: i1.id).map(\.sourceText), ["1"])
        store.deleteConversation(id: i1.id)
        XCTAssertEqual(store.turns(in: i2.id).map(\.sourceText), ["2"])
    }

    func testTitleUpdatesOnLaterSaves() {
        let id = UUID()
        store.save(Turn(speaker: .me, sourceText: "a", translatedText: "A", state: .done), in: info(id, title: "旧"))
        store.save(Turn(speaker: .me, sourceText: "b", translatedText: "B", state: .done), in: info(id, title: "新"))
        XCTAssertEqual(store.info(of: id)?.title, "新")
    }
}
