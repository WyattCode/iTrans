import SwiftData
import XCTest
@testable import XTrans

// MARK: - 重命名 / 收藏（状态机）

@MainActor
final class HistoryRenameTests: XCTestCase {
    private var history: FakeHistory!
    private var session: ConversationSession!

    override func setUp() async throws {
        history = FakeHistory()
        session = ConversationSession(recognizer: QueueRecognizer(), synthesizer: FakeSynthesizer(), engine: ScriptedEngine(), history: history)
    }

    private func send(_ text: String) async {
        session.sendText(text)
        let deadline = ContinuousClock.now + .seconds(2)
        while session.currentTurn?.state != .done, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
    }

    func testRenameCurrentConversationOverridesAutomaticTitle() async {
        await send("你好")
        XCTAssertEqual(session.title, "你好")
        session.renameConversation(session.conversationID, to: "  东京行程  ")
        XCTAssertEqual(session.title, "东京行程", "首尾空白要去掉")
        XCTAssertEqual(history.renamed.last?.title, "东京行程")
        XCTAssertEqual(history.renamed.last?.id, session.conversationID)
    }

    func testCustomTitleIsMarkedCustomWhenLaterTurnsAreSaved() async {
        await send("第一句")
        session.renameConversation(session.conversationID, to: "我的标题")
        await send("第二句")
        let last = history.saved.last
        XCTAssertEqual(last?.info.title, "我的标题", "后来的轮次保存时不能把标题改回第一句话")
        XCTAssertEqual(last?.info.titleIsCustom, true)
    }

    func testAutomaticTitleIsNotMarkedCustom() async {
        await send("第一句")
        XCTAssertEqual(history.saved.last?.info.titleIsCustom, false)
    }

    func testBlankRenameIsIgnored() async {
        await send("你好")
        session.renameConversation(session.conversationID, to: "   ")
        XCTAssertEqual(session.title, "你好")
        XCTAssertTrue(history.renamed.isEmpty)
    }

    func testRenamingAnotherConversationDoesNotChangeTheCurrentTitle() async {
        await send("你好")
        let other = UUID()
        session.renameConversation(other, to: "别的对话")
        XCTAssertEqual(session.title, "你好")
        XCTAssertEqual(history.renamed.last?.id, other)
    }

    func testNewConversationClearsCustomTitle() async {
        await send("你好")
        session.renameConversation(session.conversationID, to: "旧标题")
        session.newConversation()
        XCTAssertEqual(session.title, "新对话")
        await send("你好吗")
        XCTAssertEqual(session.title, "你好吗")
        XCTAssertEqual(history.saved.last?.info.titleIsCustom, false)
    }

    func testLoadRestoresACustomTitle() {
        let id = UUID()
        history.infos[id] = ConversationInfo(id: id, title: "自定义", me: .zhHans, them: .en,
                                             createdAt: Date(), titleIsCustom: true)
        history.storedTurns[id] = [Turn(speaker: .me, sourceText: "原话", translatedText: "x", state: .done)]
        session.load(id)
        XCTAssertEqual(session.title, "自定义", "载入后标题仍是用户改的，不是第一句话")
    }

    func testLoadOfAutomaticTitleKeepsDerivingFromFirstSentence() {
        let id = UUID()
        history.infos[id] = ConversationInfo(id: id, title: "原话", me: .zhHans, them: .en, createdAt: Date())
        history.storedTurns[id] = [Turn(speaker: .me, sourceText: "原话", translatedText: "x", state: .done)]
        session.load(id)
        XCTAssertNil(session.customTitle)
    }

    func testSetFavoriteDelegatesToStore() {
        let id = UUID()
        session.setFavorite(true, for: id)
        session.setFavorite(false, for: id)
        XCTAssertEqual(history.favorites.map(\.value), [true, false])
        XCTAssertEqual(history.favorites.first?.id, id)
    }

    func testStaticTranscriptDoesNotNeedALoadedConversation() {
        let turns = [
            Turn(speaker: .me, sourceText: "你好", translatedText: "Hello", state: .done),
            Turn(speaker: .them, sourceText: "Hi", translatedText: "嗨", state: .done),
        ]
        let text = ConversationSession.transcript(turns: turns, me: .zhHans, them: .en)
        XCTAssertTrue(text.contains("我（中文）：你好"))
        XCTAssertTrue(text.contains("→（English）Hello"))
        XCTAssertTrue(text.contains("对方（English）：Hi"))
        XCTAssertTrue(text.contains("→（中文）嗨"))
    }
}

// MARK: - SwiftData 存储里的重命名 / 收藏 / 筛选

@MainActor
final class HistoryStoreFeaturesTests: XCTestCase {
    private var container: ModelContainer!
    private var store: SwiftDataHistoryStore!

    override func setUp() async throws {
        container = try SwiftDataHistoryStore.makeContainer(inMemory: true)
        store = SwiftDataHistoryStore(container: container)
    }

    private func info(_ id: UUID = UUID(), title: String = "自动标题", custom: Bool = false) -> ConversationInfo {
        ConversationInfo(id: id, title: title, me: .zhHans, them: .en, createdAt: Date(timeIntervalSince1970: 100), titleIsCustom: custom)
    }

    private func turn(_ text: String, translated: String = "t", kind: TurnKind = .voice) -> Turn {
        Turn(speaker: .me, sourceText: text, translatedText: translated, state: .done, kind: kind)
    }

    private func records() -> [ConversationRecord] {
        (try? container.mainContext.fetch(FetchDescriptor<ConversationRecord>())) ?? []
    }

    func testRenameSetsTitleAndCustomFlag() {
        let i = info()
        store.save(turn("a"), in: i)
        store.rename(conversationID: i.id, to: "  新名字 ")
        XCTAssertEqual(store.info(of: i.id)?.title, "新名字")
        XCTAssertEqual(store.info(of: i.id)?.titleIsCustom, true)
    }

    func testAutomaticTitleCannotOverwriteACustomOne() {
        let i = info()
        store.save(turn("a"), in: i)
        store.rename(conversationID: i.id, to: "我改的")
        store.save(turn("b"), in: info(i.id, title: "又一个自动标题"))       // 自动标题 → 不能覆盖
        XCTAssertEqual(store.info(of: i.id)?.title, "我改的")
        store.save(turn("c"), in: info(i.id, title: "再次改名", custom: true)) // 用户的改名 → 可以覆盖
        XCTAssertEqual(store.info(of: i.id)?.title, "再次改名")
    }

    func testAutomaticTitleStillFollowsTheFirstSentenceUntilRenamed() {
        let i = info(title: "旧")
        store.save(turn("a"), in: i)
        store.save(turn("b"), in: info(i.id, title: "新"))
        XCTAssertEqual(store.info(of: i.id)?.title, "新")
        XCTAssertEqual(store.info(of: i.id)?.titleIsCustom, false)
    }

    func testBlankOrUnknownRenameIsIgnored() {
        let i = info()
        store.save(turn("a"), in: i)
        store.rename(conversationID: i.id, to: "   ")
        store.rename(conversationID: UUID(), to: "没有这场对话")
        XCTAssertEqual(store.info(of: i.id)?.title, "自动标题")
    }

    func testFavoriteTogglesAndUnknownIDIsIgnored() {
        let i = info()
        store.save(turn("a"), in: i)
        XCTAssertEqual(records().first?.isFavorite, false, "旧数据迁移后默认不收藏")
        store.setFavorite(true, conversationID: i.id)
        XCTAssertEqual(records().first?.isFavorite, true)
        store.setFavorite(false, conversationID: i.id)
        XCTAssertEqual(records().first?.isFavorite, false)
        store.setFavorite(true, conversationID: UUID())          // 不存在的 id：不崩、不影响别的
        XCTAssertEqual(records().first?.isFavorite, false)
    }

    func testFilterAllFavoritesAndImages() {
        let plain = info(title: "普通"), fav = info(title: "收藏的"), photo = info(title: "有图的")
        store.save(turn("hello"), in: plain)
        store.save(turn("world"), in: fav)
        store.setFavorite(true, conversationID: fav.id)
        store.save(turn("菜单", kind: .photo), in: photo)
        let all = records()

        XCTAssertEqual(Set(HistoryFilter.apply(all, filter: .all, query: "").map(\.title)), ["普通", "收藏的", "有图的"])
        XCTAssertEqual(HistoryFilter.apply(all, filter: .favorites, query: "").map(\.title), ["收藏的"])
        XCTAssertEqual(HistoryFilter.apply(all, filter: .withImages, query: "").map(\.title), ["有图的"])
    }

    func testSearchMatchesTitleSourceAndTranslationCaseInsensitively() {
        let a = info(title: "地铁"), b = info(title: "餐厅")
        store.save(turn("请问车站在哪", translated: "Where is the Station"), in: a)
        store.save(turn("来两碗拉面", translated: "Two bowls of ramen"), in: b)
        let all = records()
        XCTAssertEqual(HistoryFilter.apply(all, filter: .all, query: "地铁").map(\.title), ["地铁"], "按标题")
        XCTAssertEqual(HistoryFilter.apply(all, filter: .all, query: "拉面").map(\.title), ["餐厅"], "按原文")
        XCTAssertEqual(HistoryFilter.apply(all, filter: .all, query: "STATION").map(\.title), ["地铁"], "按译文，不分大小写")
        XCTAssertTrue(HistoryFilter.apply(all, filter: .all, query: "不存在").isEmpty)
        XCTAssertEqual(HistoryFilter.apply(all, filter: .all, query: "   ").count, 2, "空白关键词等于没有关键词")
    }

    func testFilterAndSearchCombine() {
        let a = info(title: "甲"), b = info(title: "乙")
        store.save(turn("苹果"), in: a)
        store.save(turn("苹果"), in: b)
        store.setFavorite(true, conversationID: b.id)
        XCTAssertEqual(HistoryFilter.apply(records(), filter: .favorites, query: "苹果").map(\.title), ["乙"])
    }

    func testOrderedTurnsAreChronologicalAndHasImagesIsAccurate() {
        let i = info()
        var late = turn("晚", kind: .photo); late.createdAt = Date(timeIntervalSince1970: 300)
        var early = turn("早"); early.createdAt = Date(timeIntervalSince1970: 100)
        store.save(late, in: i)
        store.save(early, in: i)
        let record = try! XCTUnwrap(records().first)
        XCTAssertEqual(record.orderedTurns.map(\.sourceText), ["早", "晚"])
        XCTAssertTrue(record.hasImages)
    }
}
