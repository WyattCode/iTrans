import SwiftData
import SwiftUI

@main
struct XTransApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                .translationHost(model.appleEngine)
                .environment(\.appleTranslationEngine, model.appleEngine)
                // 界面语言：`Text("…")` 跟着它取对应语言的文案。放在最外层，弹层、引导页、整屏盖上的页面才都带得到
                .environment(\.locale, AppLanguageState.shared.locale)
        }
        .modelContainer(model.container)
    }
}

/// 启动时直接进入某个界面的选项（调试 / 截图用）。
struct LaunchOptions {
    var screen: RootView.Screen = .faceToFace
    var showHistory = false
    var showAdd = false
    var showSettings = false
    var typing = false
    /// 调试：强制左右分屏（帐篷）摆放
    var forceTent = false
    /// 调试：直接打开"图片 / 相机"左右分屏（用程序画的一张日文菜单当图片）
    var showPhotoSplit = false
    /// 调试：在屏幕上画出尺寸 / 安全区 / 铰链区域
    var foldProbe = false
    /// 调试：直接打开"大字展示"（用一句较长的话测试横屏）
    var showBigDisplay = false
}

/// 组装依赖。支持几个调试启动参数（在 Xcode scheme 或 `simctl launch` 里传）：
///   -XTransMock            用演示翻译引擎
///   -XTransApple           强制用 Apple 翻译（模拟器默认用演示引擎，因为系统翻译在模拟器上不受支持）
///   -XTransNoHistory       历史只放内存，不落盘
///   -XTransDemo m1|m2|m3|m4|stream|long|listen   直接进入设计稿里对应的静态状态，用于截图对照
///   -XTransDemoHistory     往历史里放几场示例对话（隐含 -XTransNoHistory）
///   -XTransScreen stream|history|compose|typing|add|eavesdrop|settings   启动后直接打开对应界面
///   -XTransDemoPhrases     预置几条常用短语（隐含 -XTransNoHistory）
///   -XTransOnboarding      强制显示首次使用引导
///   -XTransOffline         模拟"当前离线"（只影响提示条）
///   -XTransLockPacks       模拟器里的语言包状态：只有中文和英语是已下载的
///   -XTransProbe "文本"    启动后翻译一句并把结果打印到标准输出
/// 带调试参数启动时，设置用一份临时的、每次清空的存储，不会污染真实设置，也不会被引导挡住。
@MainActor
@Observable
final class AppModel {
    let session: ConversationSession
    let appleEngine: AppleTranslationEngine?
    let container: ModelContainer
    let settings: AppSettings
    let packs: LanguagePackStore
    let network: NetworkMonitor
    let hinge = HingeMonitor()
    var launch = LaunchOptions()
    let showsOnboarding: Bool

    @ObservationIgnored private let recognizer = AppleSpeechRecognizer()
    @ObservationIgnored private let synthesizer = AppleSpeechSynthesizer()

    init() {
        LaunchClock.mark("model.init.begin")
        defer { LaunchClock.mark("model.init.end") }
        let args = ProcessInfo.processInfo.arguments
        func value(of flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        let debugFlags = ["-XTransNoHistory", "-XTransDemo", "-XTransDemoOffset", "-XTransDemoRepeat", "-XTransDemoHistory", "-XTransDemoPhrases", "-XTransScreen", "-XTransOnboarding", "-XTransAutoMotion", "-XTransAutoTyping", "-XTransAutoSwap", "-XTransSettingsCategory", "-XTransAutoTypingStart"]
        let isDebugLaunch = debugFlags.contains { args.contains($0) }

        // 设置
        let settings: AppSettings
        if isDebugLaunch, let suite = UserDefaults(suiteName: "app.xtrans.debug") {
            suite.removePersistentDomain(forName: "app.xtrans.debug")
            settings = AppSettings(defaults: suite)
            settings.onboardingDone = !args.contains("-XTransOnboarding")
        } else {
            settings = AppSettings()
        }
        // 调试：直接指定界面方案（halves / pinned / cards）
        self.settings = settings
        // 自动操作脚本（性能测量）不能被首次使用引导挡住
        showsOnboarding = !settings.onboardingDone && !args.contains("-XTransAutoMotion") && !args.contains("-XTransAutoTyping")

        // 翻译引擎
        let engine: TranslationEngine
        #if targetEnvironment(simulator)
        let useMock = !args.contains("-XTransApple")
        #else
        let useMock = args.contains("-XTransMock")
        #endif
        if useMock {
            engine = MockTranslationEngine()
            appleEngine = nil
            let installed: Set<String> = args.contains("-XTransLockPacks") ? ["zh-Hans", "en"] : ["zh-Hans", "en", "ja"]
            let simulated = SimulatedLanguagePackBackend(installed: installed)
            #if DEBUG
            // 调试：`-XTransPackDelay <秒>` 把模拟下载拉长，才截得到「下载中」的状态
            if let i = args.firstIndex(of: "-XTransPackDelay"), i + 1 < args.count, let seconds = Double(args[i + 1]) {
                simulated.downloadDelay = .seconds(seconds)
            }
            #endif
            packs = LanguagePackStore(backend: simulated)
        } else {
            let apple = AppleTranslationEngine()
            engine = apple
            appleEngine = apple
            packs = LanguagePackStore(backend: AppleLanguagePackBackend(engine: apple))
        }
        let net = NetworkMonitor(forceOffline: args.contains("-XTransOffline"))
        network = net
        #if DEBUG
        if let i = args.firstIndex(of: "-XTransOfflineAfter"), i + 1 < args.count, let seconds = Double(args[i + 1]) {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(seconds))
                net.debugSetOnline(false)
            }
        }
        #endif

        LaunchClock.mark("model.engines")
        // 历史存储
        // 演示场景（`-XTransDemo …`）和自动操作脚本都不能往真实历史里写东西（`next` 场景会走真正的发送流程并落盘）
        let inMemory = args.contains("-XTransNoHistory") || args.contains("-XTransDemoHistory") || args.contains("-XTransDemoPhrases")
            || args.contains("-XTransDemo") || args.contains("-XTransAutoMotion") || args.contains("-XTransAutoTyping")
        let container: ModelContainer
        var historyIsVolatile = false
        if let real = try? SwiftDataHistoryStore.makeContainer(inMemory: inMemory) {
            container = real
        } else {
            // 磁盘存储打不开（极少见）：退回内存，App 仍可用，只是这次不保存历史——设置里要说清楚，别让用户以为在存
            container = try! SwiftDataHistoryStore.makeContainer(inMemory: true)
            historyIsVolatile = true
        }
        LaunchClock.mark("model.container")
        self.container = container
        let store = SwiftDataHistoryStore(container: container)

        session = ConversationSession(
            me: settings.meLanguage,
            them: settings.themLanguage,
            recognizer: recognizer,
            synthesizer: synthesizer,
            engine: engine,
            history: store
        )
        session.historyIsVolatile = historyIsVolatile
        applySettings()
        // 用户主动选 / 换语言后存成下次启动的默认值（载入历史对话改语言不走这里）
        session.onLanguageChoice = { [settings] me, them in
            settings.meLanguageID = me.id
            settings.themLanguageID = them.id
        }

        if args.contains("-XTransDemoHistory") { Self.seedHistory(store) }
        if args.contains("-XTransDemoPhrases") {
            for (text, translated) in [("请问最近的地铁站怎么走？", "Excuse me, how do I get to the nearest subway station?"),
                                       ("我对花生过敏", "I'm allergic to peanuts."),
                                       ("可以便宜一点吗？", "Could you make it a bit cheaper?"),
                                       ("请再说一遍", "Could you say that again?")] {
                PhraseLibrary.add(text: text, translated: translated, language: .zhHans, in: container.mainContext)
            }
        }

        // 调试探针：启动后直接用当前引擎翻译一句并把结果打印到标准输出，用来确认引擎在当前环境可用
        if let text = value(of: "-XTransProbe") {
            Task { @MainActor [engine] in
                try? await Task.sleep(for: .seconds(1))   // 等宿主视图挂载
                do {
                    let out = try await engine.translate(text, from: .zhHans, to: .en)
                    print("PROBE OK [\(engine.name)]: \(text) -> \(out)")
                } catch {
                    print("PROBE FAIL [\(engine.name)]: \(error.localizedDescription)")
                }
            }
        }

        if let name = value(of: "-XTransDemo"), let scene = ConversationSession.DemoScene(rawValue: name) {
            session.seed(scene)
        }
        launch.forceTent = args.contains("-XTransTent")
        launch.foldProbe = args.contains("-XTransFoldProbe")
        switch value(of: "-XTransScreen") {
        case "stream":
            launch.screen = .stream
            if value(of: "-XTransDemo") == nil { session.seed(.stream) }
        case "history": launch.showHistory = true
        case "add": launch.showAdd = true
        case "settings": launch.showSettings = true
        case "eavesdrop": launch.screen = .eavesdrop
        case "bigdisplay":
            launch.screen = .stream
            launch.showBigDisplay = true
            session.seed(.stream)
        case "photo":
            launch.screen = .stream
            launch.showPhotoSplit = true
            session.seed(.stream)
        case "typing": launch.typing = true          // 空对话直接进键盘输入（看空状态用）
        case "compose":
            launch.typing = true
            session.seed(.m3)
            session.seedCompose()
        default: break
        }
    }

    /// 把设置同步到对话和语音组件。设置变化时由 RootView 调用。
    func applySettings() {
        session.speakVoiceReplies = settings.autoSpeak
        session.savesHistory = settings.saveHistory
        synthesizer.rate = settings.speechRate
        session.speechRate = settings.speechRate
        synthesizer.voiceIDs = settings.voiceIDs
        recognizer.silenceTimeout = .milliseconds(Int(settings.silenceTimeout * 1000))
    }

    /// 给历史页截图用的示例对话。
    private static func seedHistory(_ store: SwiftDataHistoryStore) {
        let samples: [(title: String, me: LanguageOption, them: LanguageOption, lines: [(String, String)])] = [
            ("请问最近的地铁站怎么走？", .zhHans, .en,
             [("请问最近的地铁站怎么走？", "Excuse me, how do I get to the nearest subway station?"), ("多少钱？", "How much is it?")]),
            ("我对花生过敏", .zhHans, .en, [("我对花生过敏", "I'm allergic to peanuts.")]),
            ("Where can I buy a ticket?", .en, .zhHans, [("Where can I buy a ticket?", "哪里可以买票？")]),
        ]
        for (index, sample) in samples.enumerated() {
            let id = UUID()
            let info = ConversationInfo(id: id, title: sample.title, me: sample.me, them: sample.them, createdAt: Date())
            for line in sample.lines {
                store.save(Turn(speaker: .me, sourceText: line.0, translatedText: line.1, state: .done,
                                engineName: "Apple 端侧", latency: 0.3), in: info)
            }
            if index == 1 { store.setFavorite(true, conversationID: id) }      // 演示"已收藏"
        }
        // 演示"含图片"：一场里有一条来自图片的消息
        let menuID = UUID()
        store.save(Turn(speaker: .them, sourceText: "Soy Sauce Ramen 900 yen", translatedText: "酱油拉面 900 日元",
                        state: .done, engineName: "Apple 端侧", kind: .photo),
                   in: ConversationInfo(id: menuID, title: "拉面店菜单", me: .zhHans, them: .en, createdAt: Date(), titleIsCustom: true))
    }
}
