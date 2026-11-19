import SwiftData
import XCTest
@testable import XTrans

// MARK: - 设置

final class AppSettingsTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        suiteName = "xtrans.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testDefaults() {
        let s = AppSettings(defaults: defaults)
        XCTAssertEqual(s.appearance, .system)
        XCTAssertTrue(s.autoSpeak)
        XCTAssertEqual(s.speechRate, AppSettings.defaultSpeechRate)
        XCTAssertEqual(s.silenceTimeout, 1.2)
        XCTAssertTrue(s.saveHistory)
        XCTAssertFalse(s.onboardingDone)
        XCTAssertEqual(s.meLanguage, .zhHans)
        XCTAssertEqual(s.themLanguage, .en)
    }

    func testValuesPersistAcrossInstances() {
        let a = AppSettings(defaults: defaults)
        a.appearance = .dark
        a.autoSpeak = false
        a.speechRate = 0.42
        a.silenceTimeout = 1.7
        a.saveHistory = false
        a.onboardingDone = true
        a.meLanguageID = "ja"
        a.themLanguageID = "ko"

        let b = AppSettings(defaults: defaults)
        XCTAssertEqual(b.appearance, .dark)
        XCTAssertFalse(b.autoSpeak)
        XCTAssertEqual(b.speechRate, 0.42, accuracy: 0.0001)
        XCTAssertEqual(b.silenceTimeout, 1.7, accuracy: 0.0001)
        XCTAssertFalse(b.saveHistory)
        XCTAssertTrue(b.onboardingDone)
        XCTAssertEqual(b.meLanguage.id, "ja")
        XCTAssertEqual(b.themLanguage.id, "ko")
    }

    func testOutOfRangeStoredValuesAreClamped() {
        defaults.set(5.0, forKey: "settings.speechRate")
        defaults.set(0.01, forKey: "settings.silenceTimeout")
        let s = AppSettings(defaults: defaults)
        XCTAssertEqual(s.speechRate, AppSettings.speechRateRange.upperBound)
        XCTAssertEqual(s.silenceTimeout, AppSettings.silenceRange.lowerBound)
    }

    func testUnknownStoredValuesFallBack() {
        defaults.set("neon", forKey: "settings.appearance")
        defaults.set("xx", forKey: "settings.meLanguage")
        let s = AppSettings(defaults: defaults)
        XCTAssertEqual(s.appearance, .system)
        XCTAssertEqual(s.meLanguage, .zhHans)
    }

    func testResetToDefaultsKeepsOnboardingAndLanguages() {
        let s = AppSettings(defaults: defaults)
        s.appearance = .light
        s.autoSpeak = false
        s.speechRate = 0.4
        s.silenceTimeout = 2.0
        s.saveHistory = false
        s.onboardingDone = true
        s.meLanguageID = "ja"
        s.resetToDefaults()
        XCTAssertEqual(s.appearance, .system)
        XCTAssertTrue(s.autoSpeak)
        XCTAssertEqual(s.speechRate, AppSettings.defaultSpeechRate)
        XCTAssertEqual(s.silenceTimeout, 1.2)
        XCTAssertTrue(s.saveHistory)
        XCTAssertTrue(s.onboardingDone, "恢复默认不应让用户重新看一遍引导")
        XCTAssertEqual(s.meLanguageID, "ja", "也不应改掉用户选的语言")
    }

    func testSnapshotChangesOnlyForRelevantSettings() {
        let s = AppSettings(defaults: defaults)
        let before = s.snapshot
        s.appearance = .dark
        XCTAssertEqual(s.snapshot, before, "外观由视图直接读取，不需要同步到对话组件")
        s.autoSpeak = false
        XCTAssertNotEqual(s.snapshot, before)
    }

    func testAppearanceColorSchemes() {
        XCTAssertNil(Appearance.system.colorScheme)
        XCTAssertEqual(Appearance.light.colorScheme, .light)
        XCTAssertEqual(Appearance.dark.colorScheme, .dark)
        XCTAssertEqual(Appearance.allCases.count, 3)
    }
}

// MARK: - 语言包

@MainActor
final class FakePackBackend: LanguagePackBackend {
    var statuses: [String: PackStatus] = [:]
    var downloadSucceeds = true
    var downloadDelay: Duration = .zero
    private(set) var downloadCalls: [(language: String, partner: String)] = []
    private(set) var statusCalls: [(language: String, partner: String)] = []

    func status(of language: LanguageOption, pairedWith partner: LanguageOption) async -> PackStatus {
        statusCalls.append((language.id, partner.id))
        return statuses[language.id] ?? .unsupported
    }

    func download(_ language: LanguageOption, pairedWith partner: LanguageOption) async -> Bool {
        downloadCalls.append((language.id, partner.id))
        try? await Task.sleep(for: downloadDelay)
        if downloadSucceeds { statuses[language.id] = .installed }
        return downloadSucceeds
    }
}

@MainActor
final class LanguagePackStoreTests: XCTestCase {
    func testPartnerIsEnglishExceptForEnglishItself() {
        XCTAssertEqual(LanguagePackStore.partner(for: .zhHans), .en)
        XCTAssertEqual(LanguagePackStore.partner(for: LanguageOption.all[2]), .en)
        XCTAssertEqual(LanguagePackStore.partner(for: .en), .zhHans)
    }

    func testStatusIsUnknownUntilRefreshed() {
        let store = LanguagePackStore(backend: FakePackBackend())
        XCTAssertEqual(store.status(of: .zhHans), .unknown)
        XCTAssertEqual(store.installedCount, 0)
    }

    func testRefreshQueriesEveryLanguageWithItsPartner() async {
        let backend = FakePackBackend()
        backend.statuses = ["zh-Hans": .installed, "en": .installed, "ja": .downloadable]
        let store = LanguagePackStore(backend: backend)
        await store.refresh()
        XCTAssertEqual(store.status(of: .zhHans), .installed)
        XCTAssertEqual(store.status(of: LanguageOption.all[2]), .downloadable)
        XCTAssertEqual(store.status(of: LanguageOption.all[3]), .unsupported)
        XCTAssertEqual(store.installedCount, 2)
        XCTAssertEqual(backend.statusCalls.count, LanguageOption.all.count)
        XCTAssertEqual(backend.statusCalls.first { $0.language == "en" }?.partner, "zh-Hans")
        XCTAssertEqual(backend.statusCalls.first { $0.language == "ja" }?.partner, "en")
    }

    func testDownloadMarksInProgressThenInstalled() async {
        let backend = FakePackBackend()
        backend.statuses["ja"] = .downloadable
        backend.downloadDelay = .milliseconds(60)
        let store = LanguagePackStore(backend: backend)
        let ja = LanguageOption.all[2]
        await store.refresh(ja)
        XCTAssertEqual(store.status(of: ja), .downloadable)

        let task = Task { await store.download(ja) }
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertTrue(store.downloading.contains("ja"), "下载中要能显示进度指示")
        await task.value
        XCTAssertFalse(store.downloading.contains("ja"))
        XCTAssertEqual(store.status(of: ja), .installed)
        XCTAssertNil(store.lastError)
    }

    func testFailedDownloadReportsErrorAndKeepsStatus() async {
        let backend = FakePackBackend()
        backend.statuses["ja"] = .downloadable
        backend.downloadSucceeds = false
        let store = LanguagePackStore(backend: backend)
        let ja = LanguageOption.all[2]
        await store.download(ja)
        XCTAssertNotNil(store.lastError)
        XCTAssertEqual(store.status(of: ja), .downloadable)
        XCTAssertFalse(store.downloading.contains("ja"))
    }

    func testSecondDownloadWhileRunningIsIgnored() async {
        let backend = FakePackBackend()
        backend.statuses["ja"] = .downloadable
        backend.downloadDelay = .milliseconds(60)
        let store = LanguagePackStore(backend: backend)
        let ja = LanguageOption.all[2]
        async let a: Void = store.download(ja)
        try? await Task.sleep(for: .milliseconds(10))
        await store.download(ja)
        await a
        XCTAssertEqual(backend.downloadCalls.count, 1, "重复点击不能触发两次下载")
    }

    /// 同一时间只下载一种：同时点第二种语言（不同语言）会让系统换掉会话配置、反复收起再弹下载窗——第二次点击直接忽略
    func testDownloadingTwoDifferentLanguagesAtOnceIsSerialized() async {
        let backend = FakePackBackend()
        backend.statuses["ja"] = .downloadable
        backend.statuses["ko"] = .downloadable
        backend.downloadDelay = .milliseconds(80)
        let store = LanguagePackStore(backend: backend)
        let ja = LanguageOption.all.first { $0.id == "ja" }!
        let ko = LanguageOption.all.first { $0.id == "ko" }!
        async let first: Void = store.download(ja)
        try? await Task.sleep(for: .milliseconds(15))
        XCTAssertTrue(store.isDownloading)
        XCTAssertEqual(store.downloadingLanguage?.id, "ja")
        await store.download(ko)
        await first
        XCTAssertEqual(backend.downloadCalls.map(\.language), ["ja"], "第一种没下完时第二种不能开始")
        XCTAssertFalse(store.isDownloading)
        await store.download(ko)
        XCTAssertEqual(backend.downloadCalls.map(\.language), ["ja", "ko"], "第一种下完后可以下载下一种")
    }

    func testJustInstalledHighlightsThenClears() async {
        let backend = FakePackBackend()
        backend.statuses["ja"] = .downloadable
        let store = LanguagePackStore(backend: backend)
        let ja = LanguageOption.all.first { $0.id == "ja" }!
        await store.download(ja)
        XCTAssertEqual(store.justInstalled, "ja", "刚下载好的那一种要高亮")
        try? await Task.sleep(for: .milliseconds(1700))
        XCTAssertNil(store.justInstalled, "1.5 秒后清掉")
    }

    func testFailedDownloadDoesNotHighlight() async {
        let backend = FakePackBackend()
        backend.statuses["ja"] = .downloadable
        backend.downloadSucceeds = false
        let store = LanguagePackStore(backend: backend)
        await store.download(LanguageOption.all.first { $0.id == "ja" }!)
        XCTAssertNil(store.justInstalled)
    }

    /// 用户在系统设置里删了语言包：再 refresh 一次，状态要从「已下载」变回「可下载」（回到前台时会自动 refresh）
    func testRefreshPicksUpPackDeletedInSystemSettings() async {
        let backend = FakePackBackend()
        backend.statuses = ["zh-Hans": .installed, "en": .installed, "ko": .installed]
        let store = LanguagePackStore(backend: backend)
        await store.refresh()
        let ko = LanguageOption.all.first { $0.id == "ko" }!
        XCTAssertEqual(store.status(of: ko), .installed)
        backend.statuses["ko"] = .downloadable          // 用户在系统「翻译」里删掉了韩语
        await store.refresh()
        XCTAssertEqual(store.status(of: ko), .downloadable, "删掉之后不能还显示已下载")
        XCTAssertEqual(store.status(of: .en), .installed, "没动的语言保持原样")
    }

    /// 系统对一个方向说已安装、另一个方向说可下载：不能显示成已下载（用户反馈：系统里没装的韩语 / 法语 / 德语，App 里显示已下载）
    func testStatusNeedsBothDirectionsInstalled() {
        XCTAssertEqual(PackStatus.combine(forward: .installed, backward: .installed), .installed)
        XCTAssertEqual(PackStatus.combine(forward: .installed, backward: .downloadable), .downloadable)
        XCTAssertEqual(PackStatus.combine(forward: .downloadable, backward: .installed), .downloadable)
        XCTAssertEqual(PackStatus.combine(forward: .downloadable, backward: .downloadable), .downloadable)
        XCTAssertEqual(PackStatus.combine(forward: .unsupported, backward: .unsupported), .unsupported)
        XCTAssertEqual(PackStatus.combine(forward: .installed, backward: .unsupported), .installed, "混合情况退回正向的回答（原来的行为）")
        XCTAssertEqual(PackStatus.combine(forward: .unknown, backward: .unknown), .unknown)
    }

    func testSimulatedBackendInstallsAfterDownload() async {
        let backend = SimulatedLanguagePackBackend(installed: ["zh-Hans"])
        backend.downloadDelay = .milliseconds(5)
        let ko = LanguageOption.all[3]
        let before = await backend.status(of: ko, pairedWith: .en)
        XCTAssertEqual(before, .downloadable)
        let ok = await backend.download(ko, pairedWith: .en)
        XCTAssertTrue(ok)
        let after = await backend.status(of: ko, pairedWith: .en)
        XCTAssertEqual(after, .installed)
    }

    func testStatusLabels() {
        XCTAssertEqual(PackStatus.installed.label, "离线可用")
        XCTAssertEqual(PackStatus.downloadable.label, "可下载")
    }
}

// MARK: - 设置对对话的影响

@MainActor
final class SettingsEffectTests: XCTestCase {
    private var recognizer: QueueRecognizer!
    private var synthesizer: FakeSynthesizer!
    private var history: FakeHistory!
    private var session: ConversationSession!

    override func setUp() async throws {
        recognizer = QueueRecognizer()
        synthesizer = FakeSynthesizer()
        history = FakeHistory()
        session = ConversationSession(recognizer: recognizer, synthesizer: synthesizer, engine: ScriptedEngine(), history: history)
    }

    private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = ContinuousClock.now + .seconds(2)
        while !condition() {
            if ContinuousClock.now > deadline { XCTFail("等待超时", file: file, line: line); return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    func testAutoSpeakOff_voiceTurnsAreTranslatedButNotSpoken() async {
        session.speakVoiceReplies = false
        recognizer.scripts = [[.final("你好")]]
        session.micTapped(.me)
        await waitUntil { self.session.currentTurn?.state == .done }
        XCTAssertEqual(session.currentTurn?.translatedText, "T(你好)")
        XCTAssertTrue(synthesizer.spoken.isEmpty)
    }

    func testAutoSpeakOn_voiceTurnsAreSpoken() async {
        recognizer.scripts = [[.final("你好")]]
        session.micTapped(.me)
        await waitUntil { self.session.currentTurn?.state == .done }
        XCTAssertEqual(synthesizer.spoken.count, 1)
    }

    func testAutoSpeakOff_doesNotAffectTypedMessagesWithSpeakOnSend() async {
        session.speakVoiceReplies = false
        session.sendText("你好")
        await waitUntil { self.session.currentTurn?.state == .done }
        XCTAssertEqual(synthesizer.spoken.count, 1, "键盘输入有自己的“发送并朗读”开关，不受语音设置影响")
    }

    func testSaveHistoryOff_nothingIsPersisted() async {
        session.savesHistory = false
        session.sendText("你好")
        await waitUntil { self.session.currentTurn?.state == .done }
        XCTAssertTrue(history.saved.isEmpty)
        XCTAssertEqual(session.turns.count, 1, "关闭保存只影响落盘，当前对话照常显示")
    }

    func testClearAllHistory_wipesStoreAndStartsFresh() async {
        session.sendText("你好")
        await waitUntil { self.session.currentTurn?.state == .done }
        let old = session.conversationID
        session.clearAllHistory()
        XCTAssertEqual(history.deleteAllCount, 1)
        XCTAssertNotEqual(session.conversationID, old)
        XCTAssertTrue(session.turns.isEmpty)
    }

    func testSwiftDataDeleteAllRemovesConversationsAndTurnsButNotPhrases() throws {
        let container = try SwiftDataHistoryStore.makeContainer(inMemory: true)
        let store = SwiftDataHistoryStore(container: container)
        let info = ConversationInfo(id: UUID(), title: "t", me: .zhHans, them: .en, createdAt: Date())
        store.save(Turn(speaker: .me, sourceText: "a", translatedText: "A", state: .done), in: info)
        PhraseLibrary.add(text: "谢谢", translated: nil, language: .zhHans, in: container.mainContext)

        store.deleteAll()
        XCTAssertNil(store.info(of: info.id))
        XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<ConversationRecord>()), 0)
        XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<TurnRecord>()), 0)
        XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<PhraseRecord>()), 1, "清除历史不能删掉常用短语")
    }
}

// MARK: - 文案

final class StringsPhase5Tests: XCTestCase {
    func testUseKeyboardIsLocalizedPerScreenOwner() {
        XCTAssertEqual(Strings.useKeyboard(.zhHans), "用键盘")
        XCTAssertEqual(Strings.useKeyboard(.en), "Use keyboard")
    }

    func testRetryIsLocalizedPerScreenOwner() {
        XCTAssertEqual(Strings.retry(.zhHans), "再说一次")
        XCTAssertEqual(Strings.retry(.en), "Try again")
    }
}


// MARK: - 系统下载窗口的宿主视图栈

@MainActor
final class TranslationHostStackTests: XCTestCase {
    /// 只有栈顶的宿主拿到配置：弹层出现时系统「下载语言」窗口从弹层里弹出，两个宿主不会同时各跑一遍
    func testOnlyTheTopHostGetsTheConfiguration() async {
        let engine = AppleTranslationEngine()
        let task = Task { try? await engine.prepare(from: .zhHans, to: .en) }
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertNotNil(engine.configuration(for: nil), "没有弹层时根上的宿主拿到")
        let sheetA = UUID(), sheetB = UUID()
        engine.pushHost(sheetA)
        XCTAssertNil(engine.configuration(for: nil), "弹层出现后根上的宿主让出")
        XCTAssertNotNil(engine.configuration(for: sheetA))
        engine.pushHost(sheetB)
        XCTAssertNil(engine.configuration(for: sheetA), "再叠一层弹层，只有最上面那层拿到")
        XCTAssertNotNil(engine.configuration(for: sheetB))
        engine.popHost(sheetB)
        XCTAssertNotNil(engine.configuration(for: sheetA))
        engine.popHost(sheetA)
        XCTAssertNotNil(engine.configuration(for: nil), "弹层都收起后回到根上的宿主")
        engine.pushHost(sheetA); engine.pushHost(sheetA)
        XCTAssertEqual(engine.hostStack.count, 1, "同一个宿主重复入栈只算一次")
        task.cancel()
    }
}

@MainActor
final class AudioSessionSerializationTests: XCTestCase {
    /// 朗读开始后用户要聆听（戳变大）：迟到的朗读激活必须放弃，音频会话留给聆听
    func testStaleSpeechActivationIsSkippedAfterListening() throws {
        let stamp = AppAudioSession.speechStamp()
        try? AppAudioSession.activate()          // 聆听来了
        let activated = (try? AppAudioSession.activateForSpeech(ifNoListeningSince: stamp)) ?? false
        XCTAssertFalse(activated, "聆听之后，朗读开始时取的戳已经过期：不能再把类别切回 .playback")
        let fresh = AppAudioSession.speechStamp()
        XCTAssertGreaterThan(fresh, stamp)
    }
}

/// 半屏上的提示语：这半屏是哪种语言，就用哪种语言写（原来只有中文和英文，日语 / 韩语等一律显示英文）
final class HalfScreenStringsTests: XCTestCase {
    func testEveryLanguageHasItsOwnHalfScreenStrings() {
        let english = LanguageOption.en
        for lang in LanguageOption.all where lang != english && !lang.isChinese {
            XCTAssertNotEqual(Strings.previewEmpty(lang), Strings.previewEmpty(english), lang.id)
            XCTAssertNotEqual(Strings.emptyTitle(lang), Strings.emptyTitle(english), lang.id)
            XCTAssertNotEqual(Strings.emptyHint(lang), Strings.emptyHint(english), lang.id)
            XCTAssertNotEqual(Strings.partnerSpeaking(lang), Strings.partnerSpeaking(english), lang.id)
            XCTAssertNotEqual(Strings.noSpeech(lang), Strings.noSpeech(english), lang.id)
            XCTAssertNotEqual(Strings.holdToTalk(lang), Strings.holdToTalk(english), lang.id)
            XCTAssertFalse(Strings.listening(lang).isEmpty)
        }
    }

    func testChineseAndEnglishStringsAreUnchanged() {
        XCTAssertEqual(Strings.previewEmpty(.zhHans), "译文会显示在这里")
        XCTAssertEqual(Strings.previewEmpty(.en), "The translation will appear here")
        XCTAssertEqual(Strings.listening(.zhHans), "正在聆听 · 中文")
        XCTAssertEqual(Strings.listening(.en), "Listening · English")
    }
}
