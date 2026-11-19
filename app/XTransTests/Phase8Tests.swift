import XCTest
@testable import XTrans

/// 翻译一直挂着，直到测试手动放行——用来复现"上一次翻译还没回来，又开始了新的操作"。
@MainActor
final class GatedEngine: TranslationEngine {
    let name = "gated"
    private var gates: [CheckedContinuation<Void, Never>?] = []
    var started: Int { gates.count }

    func translate(_ text: String, from: LanguageOption, to: LanguageOption) async throws -> String {
        await withCheckedContinuation { gates.append($0) }
        return "T(\(text))"
    }

    func release(_ index: Int) {
        gates[index]?.resume()
        gates[index] = nil
    }
}

/// 代码审查后修复的状态机问题：被取消的任务不能破坏新操作的状态，也不能留下"僵尸"轮次。
@MainActor
final class CancellationTests: XCTestCase {
    private var recognizer: FakeRecognizer!
    private var synthesizer: FakeSynthesizer!

    override func setUp() async throws {
        recognizer = FakeRecognizer()
        synthesizer = FakeSynthesizer()
    }

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

    /// 上一句的翻译还没回来就又发了一句：旧的那句晚到时，不能把 phase 改回 idle，
    /// 也不能让旧的那一轮永远停在"翻译中"。
    func testSendWhileTranslating_staleResultDoesNotClobberPhase() async {
        let engine = GatedEngine()
        let session = ConversationSession(recognizer: recognizer, synthesizer: synthesizer, engine: engine)

        session.sendText("a")
        await waitUntil("第一次翻译开始") { engine.started == 1 }
        session.sendText("b")
        await waitUntil("第二次翻译开始") { engine.started == 2 }

        engine.release(0)                                   // 旧的先回来
        try? await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(session.phase, .busy, "新的翻译还在进行，不能被旧任务改成空闲")
        if case .failed = session.turns[0].state {} else {
            XCTFail("被取代的那一轮应该标成已取消，而不是停在 \(session.turns[0].state)")
        }

        engine.release(1)
        await waitUntil("第二轮完成") { session.turns.last?.state == .done }
        XCTAssertEqual(session.turns.last?.translatedText, "T(b)")
        XCTAssertEqual(session.phase, .idle)
    }

    /// 同声传译说到一半被结束：不能留下一条永远"正在听"的残句。
    func testStopEavesdropMidSentence_leavesNoOrphanTurn() async {
        recognizer.holdOpen = true
        recognizer.script = [.partial("hello every")]
        let session = ConversationSession(recognizer: recognizer, synthesizer: synthesizer, engine: ScriptedEngine())

        session.startEavesdrop()
        await waitUntil("听到半句") { session.turns.first?.sourceText == "hello every" }
        session.stopEavesdrop()
        await waitUntil("残句被清理") { session.turns.isEmpty }

        XCTAssertFalse(session.isEavesdropping)
        XCTAssertEqual(session.phase, .idle)
    }

    /// cancelAll（比如退到后台）必须同时结束同声传译，否则界面还写着"同声传译中"，循环却已经死了，也没法重新开始。
    func testCancelAllEndsEavesdropping() async {
        recognizer.holdOpen = true
        let session = ConversationSession(recognizer: recognizer, synthesizer: synthesizer, engine: ScriptedEngine())

        session.startEavesdrop()
        await waitUntil("进入同声传译聆听") { session.phase == .listening(.them) }
        session.cancelAll()

        XCTAssertFalse(session.isEavesdropping)
        session.startEavesdrop()                            // 能重新开始
        XCTAssertTrue(session.isEavesdropping)
        session.stopEavesdrop()
    }

    // MARK: 审查后补的其他修复

    /// 编辑原文后翻译失败：不能把旧译文当成新原文的译文留在界面上（还会被存进历史）。
    func testEditSourceFailure_clearsStaleTranslation() async {
        let engine = ScriptedEngine()
        let session = ConversationSession(recognizer: recognizer, synthesizer: synthesizer, engine: engine)
        session.speakOnSend = false
        session.sendText("你好")
        await waitUntil("首次翻译") { session.turns.first?.state == .done }

        engine.shouldFail = true
        session.editSource(session.turns[0].id, to: "谢谢")
        await waitUntil("编辑后失败") { if case .failed = session.turns[0].state { return true } else { return false } }

        XCTAssertEqual(session.turns[0].sourceText, "谢谢")
        XCTAssertNil(session.turns[0].translatedText, "旧译文 T(你好) 不应该还挂在新原文上")
    }

    /// 选了另一边正在用的语言：两边对调，不会出现两边同一种语言。
    func testChoosingPartnersLanguageSwaps() {
        let session = ConversationSession(me: .zhHans, them: .en, recognizer: recognizer,
                                          synthesizer: synthesizer, engine: ScriptedEngine())
        session.choose(.en, for: .me)
        XCTAssertEqual(session.me, .en)
        XCTAssertEqual(session.them, .zhHans)

        session.choose(.zhHans, for: .them)         // 已经是 them，不变
        XCTAssertEqual(session.me, .en)
        XCTAssertEqual(session.them, .zhHans)

        session.choose(.en, for: .them)
        XCTAssertEqual(session.them, .en)
        XCTAssertEqual(session.me, .zhHans)

        session.choose(.zhHans, for: .me)           // 选的是自己已有的：不变
        XCTAssertEqual(session.me, .zhHans)
        XCTAssertEqual(session.them, .en)
    }

    /// 对话中途交换了语言：早先的那一句重新翻译时，仍然按它当时的语言（中→英），而不是被反过来。
    func testRetranslateUsesTheLanguagesTheTurnWasSpokenIn() async {
        let engine = ScriptedEngine()
        let session = ConversationSession(me: .zhHans, them: .en, recognizer: recognizer,
                                          synthesizer: synthesizer, engine: engine)
        session.speakOnSend = false
        session.sendText("你好")
        await waitUntil("首次翻译") { session.turns.first?.state == .done }

        session.swapLanguages()                     // 现在 me = en, them = zh
        session.retranslate(session.turns[0].id)
        await waitUntil("重新翻译") { engine.calls.count == 2 && session.phase == .idle }

        XCTAssertEqual(engine.calls[1].from, "zh-Hans")
        XCTAssertEqual(engine.calls[1].to, "en")
        XCTAssertTrue(ConversationSession.transcript(turns: session.turns, me: session.me, them: session.them)
            .contains("中文"), "导出文本里这一句仍应标注为中文")
    }

    /// 每一轮的语言对会随历史一起存下来、读出来。
    func testTurnLanguagesSurviveHistoryRoundTrip() throws {
        let container = try SwiftDataHistoryStore.makeContainer(inMemory: true)
        let store = SwiftDataHistoryStore(container: container)
        let id = UUID()
        let info = ConversationInfo(id: id, title: "t", me: .zhHans, them: .en, createdAt: Date())
        store.save(Turn(speaker: .me, sourceText: "你好", translatedText: "Hello", state: .done,
                        fromID: "zh-Hans", toID: "en"), in: info)

        let loaded = store.turns(in: id)
        XCTAssertEqual(loaded.first?.fromID, "zh-Hans")
        XCTAssertEqual(loaded.first?.toID, "en")
        withExtendedLifetime(container) {}
    }

    /// 删掉作为标题来源的第一句后，历史里的标题要跟着更新，而不是还显示被删掉的话。
    func testDeletingFirstTurnRefreshesStoredTitle() async {
        let history = FakeHistory()
        let session = ConversationSession(recognizer: recognizer, synthesizer: synthesizer,
                                          engine: ScriptedEngine(), history: history)
        session.speakOnSend = false
        session.sendText("第一句")
        await waitUntil("第一句") { session.turns.count == 1 && session.phase == .idle }
        session.sendText("第二句")
        await waitUntil("第二句") { session.turns.count == 2 && session.phase == .idle }

        session.deleteTurn(session.turns[0].id)

        XCTAssertEqual(history.saved.last?.info.title, "第二句")
    }

    /// 还在等权限弹窗时用户已经松手：不能随后开一个没人来结束的按住说话会话。
    func testReleaseBeforeRecognizerStarts_doesNotStartListening() async {
        let gated = GatedPermissionRecognizer()
        let session = ConversationSession(recognizer: gated, synthesizer: synthesizer, engine: ScriptedEngine())

        session.holdBegan(.me)
        await waitUntil("进入聆听（等权限）") { session.phase == .listening(.me) && gated.isWaiting }
        session.holdEnded(.me)
        gated.openGate()
        await waitUntil("回到空闲") { session.phase == .idle }

        XCTAssertEqual(gated.listenCount, 0)
        XCTAssertTrue(session.turns.isEmpty)
        XCTAssertNil(session.notice, "用户主动松手不算'没听清'")
    }
}

/// 权限请求一直挂着，直到测试放行——模拟系统权限弹窗还没点。
@MainActor
final class GatedPermissionRecognizer: SpeechRecognizing {
    private var gate: CheckedContinuation<Void, Never>?
    private(set) var listenCount = 0
    var isWaiting: Bool { gate != nil }

    func requestPermissions() async -> PermissionResult {
        await withCheckedContinuation { gate = $0 }
        return .granted
    }
    func openGate() { gate?.resume(); gate = nil }

    func listen(locale: Locale, autoEndpoint: Bool) -> AsyncThrowingStream<RecognitionEvent, Error> {
        listenCount += 1
        return AsyncThrowingStream { $0.finish() }
    }
    func stop() {}
}

/// 第二轮审查（拍照 / 粘贴翻译）的修复。
@MainActor
final class LinesReviewTests: XCTestCase {
    func testSpeechTextAddsPausesWithoutDoublingPunctuation() {
        XCTAssertEqual(LinesModel.speechText(["Hello", "World."], for: .en), "Hello. World.")
        XCTAssertEqual(LinesModel.speechText(["你好", "再见。"], for: .zhHans), "你好。再见。")
        XCTAssertEqual(LinesModel.speechText(["Hi", "  ", "Bye!"], for: .en), "Hi. Bye!", "空行不朗读")
    }

    func testSelectedCountOnlyCountsLinesThatHaveTranslations() async {
        let session = ConversationSession(recognizer: FakeRecognizer(), synthesizer: FakeSynthesizer(), engine: ScriptedEngine())
        let model = LinesModel()
        model.items = [LinesModel.Item(original: "a", translation: "A"), LinesModel.Item(original: "b")]
        XCTAssertEqual(model.selectedCount, 1, "没翻译出来的那行不能算进已选")
        XCTAssertEqual(model.selectedTranslations, ["A"])
        _ = session
    }

    func testPastedLinesAreCapped() async {
        let session = ConversationSession(recognizer: FakeRecognizer(), synthesizer: FakeSynthesizer(), engine: ScriptedEngine())
        let model = LinesModel()
        let lines = (1...(LinesModel.maxLines + 25)).map { "line \($0)" }
        await model.load(source: .lines(lines), session: session, recognizer: VisionTextRecognizer())
        XCTAssertEqual(model.items.count, LinesModel.maxLines)
        XCTAssertEqual(model.omitted, 25)
    }
}

/// 朗读声音的选择与保存。
@MainActor
final class VoiceSettingsTests: XCTestCase {
    private func voice(_ id: String, _ name: String, _ lang: String, _ q: VoiceChoice.Quality = .standard) -> VoiceChoice {
        VoiceChoice(id: id, name: name, language: lang, quality: q, gender: .unspecified)
    }

    func testChoicesKeepSameLanguageAndSortByRegionThenQuality() {
        let all = [
            voice("a", "Aaron", "en-GB", .premium), voice("b", "Bella", "en-US"), voice("c", "Chris", "en-US", .enhanced),
            voice("d", "Daniel", "fr-FR"), voice("e", "Eva", "en-AU", .premium),
        ]
        let ids = VoiceCatalog.choices(for: "en-US", among: all).map(\.id)
        XCTAssertEqual(ids, ["c", "b", "a", "e"], "同区域在前，其余按质量；其他语言不出现")
    }

    func testNoveltyVoicesAreHidden() {
        let all = [
            voice("com.apple.speech.synthesis.voice.Albert", "Albert", "en-US"),
            voice("com.apple.speech.synthesis.voice.BadNews", "Bad News", "en-US"),
            voice("com.apple.voice.compact.en-US.Samantha", "Samantha", "en-US"),
        ]
        XCTAssertEqual(VoiceCatalog.choices(for: "en-US", among: all).map(\.name), ["Samantha"])
        let onlyNovelty = [voice("com.apple.speech.synthesis.voice.Fred", "Fred", "en-US")]
        XCTAssertEqual(VoiceCatalog.choices(for: "en-US", among: onlyNovelty).count, 1, "没有别的声音时不能让列表空着")
    }

    func testChineseOnlyOffersMandarinVoices() {
        let all = [voice("m", "Tingting", "zh-CN"), voice("c", "Sinji", "zh-HK"), voice("t", "Meijia", "zh-TW")]
        XCTAssertEqual(VoiceCatalog.choices(for: "zh-CN", among: all).map(\.id), ["m"])
    }

    func testSettingsPersistAndResetVoices() {
        let suite = "xtrans.test.voices.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.voiceIDs["en-US"] = "com.apple.voice.premium.en-US.Zoe"

        let reloaded = AppSettings(defaults: defaults)
        XCTAssertEqual(reloaded.voiceIDs["en-US"], "com.apple.voice.premium.en-US.Zoe")
        XCTAssertNotEqual(settings.snapshot, AppSettings(defaults: UserDefaults(suiteName: suite + ".x")!).snapshot,
                          "换声音要触发同步到朗读组件")
        reloaded.resetToDefaults()
        XCTAssertTrue(AppSettings(defaults: defaults).voiceIDs.isEmpty)
    }

    func testResolveFallsBackWhenSelectedVoiceIsGone() {
        let voice = AppleSpeechSynthesizer.resolveVoice(ttsCode: "en-US", preferredID: "com.apple.voice.deleted.nonexistent")
        XCTAssertNotNil(voice, "指定的声音没了，要退回系统默认，而不是没声音")
        XCTAssertEqual(voice?.language, "en-US")
        XCTAssertNotNil(AppleSpeechSynthesizer.resolveVoice(ttsCode: "en-US", preferredID: VoiceCatalog.autoID))
    }

    func testPreviewUsesTheGivenVoiceAndLanguage() async {
        let synth = FakeSynthesizer()
        let session = ConversationSession(recognizer: FakeRecognizer(), synthesizer: synth, engine: ScriptedEngine())
        session.previewVoice("voice.x", for: .en)
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(synth.voiceIDs.last, "voice.x")
        XCTAssertEqual(synth.spoken.last?.code, "en-US")
        XCTAssertEqual(synth.spoken.last?.text, VoiceCatalog.sample(for: .en))
    }
}

/// 双屏摆放（D1/D2 帐篷）的切换规则。
final class TentModeTests: XCTestCase {
    func testSettingPersistsAndResets() {
        let suite = "xtrans.test.tent.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.tentMode, .auto)
        settings.tentMode = .on
        XCTAssertEqual(AppSettings(defaults: defaults).tentMode, .on)
        settings.resetToDefaults()
        XCTAssertEqual(AppSettings(defaults: defaults).tentMode, .auto)
    }

    func testWideThresholdMatchesDuoInnerScreen() {
        XCTAssertEqual(LayoutClass.forSize(CGSize(width: 466, height: 678)), .compact, "Duo 外屏")
        XCTAssertEqual(LayoutClass.forSize(CGSize(width: 669, height: 951)), .wide, "Duo 内屏（竖）")
        XCTAssertEqual(LayoutClass.forSize(CGSize(width: 951, height: 669)), .wide, "Duo 内屏（横）")
        XCTAssertEqual(LayoutClass.forSize(CGSize(width: 440, height: 956)), .compact, "最宽的直板 iPhone")
    }
}

/// 面对面版面的几何：两个半屏必须严格对称（用户明确要求：麦克风的间距、离边缘的距离都不能不一样）。
final class FaceGeometryTests: XCTestCase {
    typealias Insets = (top: CGFloat, leading: CGFloat, bottom: CGFloat, trailing: CGFloat)

    private struct Device {
        let name: String
        let size: CGSize
        let insets: Insets
    }

    /// 每个设备 / 方向用真实尺寸和（模拟器里量到的）安全区。
    private let devices: [Device] = [
        Device(name: "iPhone 17 竖", size: CGSize(width: 402, height: 874), insets: (62, 0, 34, 0)),
        Device(name: "iPhone 17 横", size: CGSize(width: 874, height: 402), insets: (0, 62, 21, 62)),
        Device(name: "iPhone SE 竖", size: CGSize(width: 375, height: 667), insets: (20, 0, 0, 0)),
        Device(name: "Duo 外屏 竖", size: CGSize(width: 466, height: 678), insets: (0, 0, 34, 84)),
        Device(name: "Duo 外屏 横", size: CGSize(width: 678, height: 466), insets: (0, 0, 21, 84)),
        Device(name: "Duo 内屏 横", size: CGSize(width: 951, height: 669), insets: (0, 0, 34, 84)),
        Device(name: "Duo 内屏 竖", size: CGSize(width: 669, height: 951), insets: (62, 0, 34, 0)),
        Device(name: "iPad mini 竖", size: CGSize(width: 744, height: 1133), insets: (24, 0, 20, 0)),
        // 系统竖排栏在左侧：Duo 外屏横翻转 / 内屏分屏里靠左的 App（栏在最外侧）
        Device(name: "Duo 外屏 横翻转", size: CGSize(width: 678, height: 466), insets: (0, 84, 21, 0)),
        Device(name: "Duo 内屏分屏 左 App", size: CGSize(width: 476, height: 669), insets: (0, 84, 34, 0)),
        Device(name: "Duo 内屏分屏 右 App", size: CGSize(width: 476, height: 669), insets: (0, 0, 34, 84)),
        Device(name: "iPhone SE 横", size: CGSize(width: 667, height: 375), insets: (0, 0, 21, 0)),
    ]

    func testHalvesAreSameSizeAndMicsAreEquidistantFromTheirEdges() {
        for d in devices {
            for arrangement in [FaceGeometry.Arrangement.stacked, .stackedFold, .sideBySide] {
                let g = FaceGeometry.compute(size: d.size, insets: d.insets, arrangement: arrangement)
                let label = "\(d.name) \(arrangement)"
                XCTAssertEqual(g.them.size.width, g.me.size.width, accuracy: 0.01, "\(label) 宽度不同")
                XCTAssertEqual(g.them.size.height, g.me.size.height, accuracy: 0.01, "\(label) 高度不同")
                // 对方半屏离屏幕上沿的距离 == 我这半屏离屏幕下沿的距离（麦克风就贴着这两条边）
                XCTAssertEqual(g.them.minY, d.size.height - g.me.maxY, accuracy: 0.01, "\(label) 上下边距不同")
                XCTAssertGreaterThanOrEqual(g.them.minY, d.insets.top - 0.01, "\(label) 压到了上方安全区")
                XCTAssertGreaterThanOrEqual(d.size.height - g.me.maxY, d.insets.bottom - 0.01, "\(label) 压到了下方安全区")
            }
        }
    }

    func testStackedStripIsExactlyCentered() {
        for d in devices {
            let g = FaceGeometry.compute(size: d.size, insets: d.insets, arrangement: .stacked)
            XCTAssertEqual(g.strip.midY, d.size.height / 2, accuracy: 0.01, "\(d.name) 控制条不在正中")
            XCTAssertEqual(g.them.maxY, g.strip.minY, accuracy: 0.01)
            XCTAssertEqual(g.me.minY, g.strip.maxY, accuracy: 0.01)
        }
    }

    func testNothingOverlapsAndStaysInsideTheSafeArea() {
        for d in devices {
            for arrangement in [FaceGeometry.Arrangement.stacked, .stackedFold, .sideBySide] {
                let g = FaceGeometry.compute(size: d.size, insets: d.insets, arrangement: arrangement)
                let safe = CGRect(x: d.insets.leading, y: 0, width: d.size.width - d.insets.leading - d.insets.trailing, height: d.size.height)
                for (name, r) in [("them", g.them), ("me", g.me), ("strip", g.strip)] {
                    XCTAssertTrue(safe.insetBy(dx: -0.01, dy: -0.01).contains(r), "\(d.name) \(arrangement) \(name) 超出安全区 \(r)")
                }
                XCTAssertFalse(g.them.intersects(g.me), "\(d.name) \(arrangement) 两个半屏重叠")
                XCTAssertTrue(g.them.intersection(g.strip).isEmpty || g.them.intersection(g.strip).height < 0.01 || g.them.intersection(g.strip).width < 0.01,
                              "\(d.name) \(arrangement) 对方半屏压到控制条")
            }
        }
    }

    func testFoldedLayoutsKeepInteractiveContentOutOfTheFold() {
        let size = CGSize(width: 669, height: 951)
        let g = FaceGeometry.compute(size: size, insets: (0, 0, 34, 0), arrangement: .stackedFold)
        let fold = CGRect(x: 0, y: size.height / 2 - FaceGeometry.foldGap / 2, width: size.width, height: FaceGeometry.foldGap)
        XCTAssertFalse(g.strip.intersects(fold), "控制条不能放在折叠处")
        XCTAssertFalse(g.me.intersects(fold))
        XCTAssertFalse(g.them.intersects(fold))
        XCTAssertGreaterThan(g.strip.minY, fold.maxY - 0.01, "控制条在我这一侧（折叠处下方）")

        let land = CGSize(width: 951, height: 669)
        let s = FaceGeometry.compute(size: land, insets: (0, 0, 34, 84), arrangement: .sideBySide)
        let cx = (0 + (land.width - 84)) / 2
        let vfold = CGRect(x: cx - FaceGeometry.foldGap / 2, y: 0, width: FaceGeometry.foldGap, height: land.height)
        XCTAssertFalse(s.them.intersects(vfold))
        XCTAssertFalse(s.me.intersects(vfold))
        XCTAssertFalse(s.strip.intersects(vfold))
        XCTAssertGreaterThan(s.me.minX, s.them.maxX, "我在右、对方在左")
    }

    func testMicPlacementFollowsScreenOrientation() {
        let portrait = FaceGeometry.compute(size: CGSize(width: 402, height: 874), insets: (62, 0, 34, 0), arrangement: .stacked)
        XCTAssertEqual(portrait.micPlacement, .bottom, "竖着拿：半屏虽然比较宽，麦克风仍在下方")
        let landscape = FaceGeometry.compute(size: CGSize(width: 874, height: 402), insets: (0, 62, 21, 62), arrangement: .stacked)
        XCTAssertEqual(landscape.micPlacement, .trailing)
        let side = FaceGeometry.compute(size: CGSize(width: 951, height: 669), insets: (0, 0, 34, 84), arrangement: .sideBySide)
        XCTAssertEqual(side.micPlacement, .bottom, "左右分屏的半屏是竖条")
    }

    func testArrangementRules() {
        let inner = CGSize(width: 951, height: 669), innerPortrait = CGSize(width: 669, height: 951)
        let phone = CGSize(width: 402, height: 874), phoneLandscape = CGSize(width: 874, height: 402)
        // 窄屏永远上下分屏，不管铰链状态
        XCTAssertEqual(FaceGeometry.arrangement(size: phone, mode: .on, hinge: .partiallyOpen, fold: nil), .stacked)
        XCTAssertEqual(FaceGeometry.arrangement(size: phoneLandscape, mode: .auto, hinge: .partiallyOpen, fold: nil), .stacked)
        // 内屏：展开 → 上下；半开 → 横向左右、竖向折叠上下
        XCTAssertEqual(FaceGeometry.arrangement(size: inner, mode: .auto, hinge: .fullyOpen, fold: nil), .stacked)
        XCTAssertEqual(FaceGeometry.arrangement(size: inner, mode: .auto, hinge: .partiallyOpen, fold: nil), .sideBySide)
        XCTAssertEqual(FaceGeometry.arrangement(size: innerPortrait, mode: .auto, hinge: .partiallyOpen, fold: nil), .stackedFold)
        // 系统给了折叠区域就以它为准
        XCTAssertEqual(FaceGeometry.arrangement(size: innerPortrait, mode: .auto, hinge: .partiallyOpen,
                                                fold: CGRect(x: 320, y: 0, width: 40, height: 951)), .sideBySide)
        // 手动
        XCTAssertEqual(FaceGeometry.arrangement(size: inner, mode: .off, hinge: .partiallyOpen, fold: nil), .stacked)
        XCTAssertEqual(FaceGeometry.arrangement(size: inner, mode: .on, hinge: .fullyOpen, fold: nil), .sideBySide)
    }
}

/// 第 10k 轮：键盘 / 发送相关的状态问题。
@MainActor
final class SendResultTests: XCTestCase {
    /// 空文本发不出去，调用方（输入框、短语）据此决定要不要关闭界面。
    func testSendText_emptyReturnsFalse() {
        let session = ConversationSession(recognizer: FakeRecognizer(), synthesizer: FakeSynthesizer(), engine: ScriptedEngine())
        XCTAssertFalse(session.sendText("   "))
        XCTAssertFalse(session.sendDraft(), "草稿是空的")
        XCTAssertTrue(session.turns.isEmpty)
    }

    func testSendText_returnsTrueAndAddsTurn() {
        let session = ConversationSession(recognizer: FakeRecognizer(), synthesizer: FakeSynthesizer(), engine: ScriptedEngine())
        XCTAssertTrue(session.sendText("你好"))
        XCTAssertEqual(session.turns.count, 1)
    }

    /// 正在聆听时发送会被拒绝（返回 false）——界面不能因此把输入框关掉、把用户的草稿"吃"掉。
    func testSendText_whileListening_returnsFalseAndKeepsDraft() async {
        let recognizer = FakeRecognizer()
        recognizer.holdOpen = true
        recognizer.script = [.partial("hello")]
        let session = ConversationSession(recognizer: recognizer, synthesizer: FakeSynthesizer(), engine: ScriptedEngine())
        session.micTapped(.me)
        let deadline = ContinuousClock.now + .seconds(2)
        while !session.isListening, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(session.isListening)

        session.updateDraft("想发的话")
        XCTAssertFalse(session.sendDraft())
        XCTAssertEqual(session.draft, "想发的话", "没发出去，草稿必须还在")
        session.cancelAll()
    }
}
