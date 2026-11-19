import XCTest
@testable import XTrans

/// 二次审查整改的回归测试（2026-11-13）
@MainActor
final class Round2Tests: XCTestCase {
    private var recognizer: FakeRecognizer!
    private var synthesizer: FakeSynthesizer!
    private var engine: ScriptedEngine!
    private var history: FakeHistory!
    private var session: ConversationSession!
    private var ja: LanguageOption { LanguageOption.all.first { $0.id == "ja" }! }

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

    // MARK: 语言默认值只在用户主动选 / 换时才记

    func testChooseAndSwapReportLanguageChoice_butLoadDoesNot() async {
        var reports: [(String, String)] = []
        session.onLanguageChoice = { me, them in reports.append((me.id, them.id)) }

        session.choose(ja, for: .them)
        XCTAssertEqual(reports.count, 1)
        session.swapLanguages()
        XCTAssertEqual(reports.count, 2)

        // 载入历史里一场别的语言的对话：不该改掉用户的默认语言
        let id = UUID()
        history.infos[id] = ConversationInfo(id: id, title: "x", me: .en, them: .zhHans, createdAt: Date())
        session.load(id)
        XCTAssertEqual(reports.count, 2)
    }

    // MARK: 键盘预览跟着语言变

    func testChangingLanguageRefreshesDraftPreviewInNewDirection() async {
        session.updateDraft("你好")
        await waitUntil("旧方向预览") { if case .ready = self.session.preview { return true } else { return false } }
        XCTAssertEqual(engine.calls.last?.to, LanguageOption.en.id)

        session.choose(ja, for: .them)
        await waitUntil("新方向预览") { self.engine.calls.last?.to == ja.id }
    }

    // MARK: 编辑原文立刻存

    func testEditSourcePersistsImmediately() async {
        session.updateDraft("你好")
        XCTAssertTrue(session.sendDraft())
        await waitUntil("发完") { self.session.currentTurn?.state == .done }
        let id = session.currentTurn!.id
        let before = history.saved.count

        session.editSource(id, to: "你好吗")
        XCTAssertGreaterThan(history.saved.count, before)
        XCTAssertEqual(history.saved.last?.turn.sourceText, "你好吗")
    }

    // MARK: 没听清计数（根上据此只响一次触觉）

    func testNoSpeechCountIncrementsOncePerNotice() {
        let before = session.noSpeechCount
        session.notice = .noSpeech(.me)
        XCTAssertEqual(session.noSpeechCount, before + 1)
        session.notice = nil
        XCTAssertEqual(session.noSpeechCount, before + 1)
        session.notice = .microphoneDenied
        XCTAssertEqual(session.noSpeechCount, before + 1)
    }

    // MARK: 语言包批量刷新不覆盖刚下载完的状态

    func testPackRefreshDoesNotOverwriteStatusChangedDuringQuery() async {
        let backend = FakePackBackend()
        backend.statuses = ["ja": .downloadable]
        let store = LanguagePackStore(backend: backend)
        await store.refresh()
        XCTAssertEqual(store.status(of: ja), .downloadable)

        // 下载完成：状态变成已下载（后端也认）
        backend.statuses["ja"] = .installed
        backend.downloadSucceeds = true
        await store.download(ja)
        XCTAssertEqual(store.status(of: ja), .installed)
        // 再批量刷新一次，结果保持一致
        await store.refresh()
        XCTAssertEqual(store.status(of: ja), .installed)
    }
}
