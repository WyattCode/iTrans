import Observation
import XCTest
@testable import XTrans

/// 独占访问冲突（Swift 的 `swift_beginAccess` 中止）回归测试。
///
/// 真机崩溃（iPhone Air，build 20261118.2，语言对调连点 6~9 次）：`swap(&me, &them)` 让两个被观察的属性同时处于「正在修改」，
/// 第二个属性的 `willSet` 通知 SwiftUI 同步刷新，视图 body 去读 `me` → 它的修改还没结束 → 独占访问冲突 → abort。
/// 是否同步刷新取决于时机，所以要点好几次才碰上。
///
/// 这里用同样的办法逼出来：在 `withObservationTracking` 的 `onChange`（= 属性即将变化的那一刻，同步）里把会话的所有状态读一遍，
/// 并立刻重新注册，这样一次操作里改了几个属性就会被打断几次。冲突会让测试进程直接中止。
@MainActor
final class ExclusivityTests: XCTestCase {
    private var recognizer: FakeRecognizer!
    private var synthesizer: FakeSynthesizer!
    private var session: ConversationSession!
    private var reads = 0

    override func setUp() async throws {
        recognizer = FakeRecognizer()
        synthesizer = FakeSynthesizer()
        session = ConversationSession(recognizer: recognizer, synthesizer: synthesizer, engine: ScriptedEngine(), history: FakeHistory())
        session.previewDelay = .milliseconds(5)
        reads = 0
    }

    /// 读一遍界面会读的所有状态（模拟 SwiftUI 在 onChange 里同步重算 body）
    private func readAll() {
        let s = session!
        _ = (s.me, s.them, s.turns, s.phase, s.notice, s.noSpeechCount, s.levels, s.speakingTurnID, s.spokenOffset)
        _ = (s.conversationID, s.conversationCreatedAt, s.translatedCount, s.speechIdleTick, s.isEavesdropping)
        _ = (s.draft, s.preview, s.speakOnSend, s.speakVoiceReplies, s.savesHistory, s.historyIsVolatile)
        _ = (s.currentTurn, s.title, s.previewDraft)
        reads += 1
    }

    private func track() {
        withObservationTracking {
            readAll()
        } onChange: {
            MainActor.assumeIsolated {
                self.readAll()          // 此刻就是「某个属性即将变化」，别的属性不能还处于修改中
                self.track()
            }
        }
    }

    private func settle() async { try? await Task.sleep(for: .milliseconds(60)) }

    /// 用户报的那个：来回对调。
    func testSwapLanguagesRepeatedly_noExclusivityConflict() {
        track()
        for _ in 0..<12 { session.swapLanguages() }
        XCTAssertGreaterThan(reads, 12, "观察者应该被触发过")
        XCTAssertEqual(session.me.id, LanguageOption.zhHans.id)          // 偶数次，回到原来
    }

    /// 举一反三：其余会同时改几个属性的操作，都在「每次变化都同步读全部状态」的条件下做一遍。
    func testEveryMutationPath_noExclusivityConflict() async {
        track()
        session.choose(.en, for: .me)
        session.swapLanguages()
        session.choose(.zhHans, for: .them)
        session.updateDraft("你好")
        await settle()
        session.sendText("你好")
        await settle()
        session.updateDraft("再见")
        session.speakOnSend = false
        session.sendText("再见")
        await settle()
        session.swapLanguages()
        session.retranslate(session.turns[0].id)
        await settle()
        if let first = session.turns.first { session.deleteTurn(first.id) }
        session.startEavesdrop()
        await settle()
        session.stopEavesdrop()
        session.cancelAll()
        session.newConversation()
        await settle()
        XCTAssertGreaterThan(reads, 40)
    }

    /// 说话 / 同声传译 / 载入历史 / 删除 / 改名 / 清空：边说边读全部状态。
    func testListeningAndConversationManagement_noExclusivityConflict() async {
        track()
        recognizer.script = [.partial("hello"), .final("hello there")]
        session.micTapped(.them)
        await settle()
        recognizer.script = [.partial("你好"), .final("你好吗")]
        session.holdBegan(.me)
        session.holdPromotedToTap(.me)
        await settle()
        session.holdEnded(.me)
        await settle()
        recognizer.holdOpen = true
        recognizer.heldFinal = "see you"
        session.micTapped(.them)
        await settle()
        session.swapLanguages()          // 正在听：应该不动，也不能崩
        session.stopListening()
        await settle()
        recognizer.holdOpen = false
        recognizer.script = [.partial("one"), .final("one two")]
        session.startEavesdrop()
        await settle()
        session.swapLanguages()
        session.stopEavesdrop()
        await settle()
        session.editSource(session.turns[0].id, to: "edited")
        session.replay(session.turns[0].id)
        await settle()
        let id = session.conversationID
        session.renameConversation(id, to: "改名")
        session.setFavorite(true, for: id)
        session.newConversation()
        session.load(id)
        await settle()
        session.deleteConversation(id)
        session.clearAllHistory()
        XCTAssertGreaterThan(reads, 40)
    }

    /// 连点对调的同时有翻译在进行：对调被拒绝（忙碌），不能因为状态在变而冲突。
    func testSwapWhileBusy_noExclusivityConflict() async {
        track()
        for i in 0..<20 {
            session.sendText("n\(i)")
            session.swapLanguages()
            try? await Task.sleep(for: .milliseconds(3))
        }
        await settle()
    }

    // MARK: - 二次审查修的状态 bug

    /// 点麦克风的同一瞬间被取消（退后台 / 换对话）：不能把状态留在「正在听」而实际没在听。
    func testCancelBeforeListeningStarts_doesNotStickInListening() async {
        session.micTapped(.me)
        session.cancelAll()          // 聆听任务还没起步就被取消
        await settle()
        XCTAssertEqual(session.phase, .idle)
        XCTAssertTrue(session.turns.isEmpty, "没开始听就不该留下一轮")
        // 之后还能正常用
        XCTAssertTrue(session.sendText("hi"))
    }

    /// 同一轮同时有两次翻译在路上（同声传译收尾时最后一句还在译，用户马上改了原文）：晚回来的旧结果不能盖掉新的。
    func testStaleDetachedTranslation_doesNotOverwriteEditedSource() async {
        let engine = GatedEngine()
        let session = ConversationSession(recognizer: recognizer, synthesizer: synthesizer, engine: engine, history: FakeHistory())
        let id = session.addIncoming(source: "old", translated: "T(old)", kind: .voice)
        session.retryDetached(id)                    // 第 1 次：译「old」，卡住
        while engine.started < 1 { try? await Task.sleep(for: .milliseconds(5)) }
        session.editSource(id, to: "new")            // 第 2 次：译「new」
        while engine.started < 2 { try? await Task.sleep(for: .milliseconds(5)) }
        engine.release(1)                            // 新的先回来
        await settle()
        engine.release(0)                            // 旧的后回来
        await settle()
        let turn = session.turns.first { $0.id == id }
        XCTAssertEqual(turn?.sourceText, "new")
        XCTAssertEqual(turn?.translatedText, "T(new)", "旧原文的译文不能盖在新原文上")
        XCTAssertEqual(turn?.state, .done)
    }
}
