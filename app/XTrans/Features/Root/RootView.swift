import SwiftUI

/// 根导航：整个 App 就是一场对话。
/// 面对面 ⇄ 对话流 是同一场对话的两种视图（直板竖屏：中间条上滑进入、对话流顶部分段返回；其余设备用系统标签栏，
/// Duo 上由系统竖排在右侧）；同声传译是整页接管的特殊模式。
/// 设置 / 历史 / 加入面板的呈现方式按设备分三种（`PagePresentation`）：直板机整页从右推入、Duo 内屏只在第二块屏淡入
/// （第一块屏常驻对话）、iPad 整屏盖上；大字展示和首次使用盖满全屏。
struct RootView: View {
    enum Screen { case faceToFace, stream, eavesdrop }

    /// 次级页面怎么出现
    enum PagePresentation {
        /// 直板 iPhone / Duo 外屏：整页从右推入，左上「‹ 对话」返回，左缘右滑（跟手）返回
        case push
        /// Duo 内屏（展平 = 一整块连续画布，regular 尺寸类）：屏幕正中的系统表单弹层（`.sheet` + `.presentationSizing(.form)`），
        /// 单栏、卡片内原生推入；半开（折痕起作用）时系统自己把弹层滑到远离折痕的那一半屏
        case sheet
        /// iPad：系统整屏盖上
        case cover

        /// `sideInsets`：窗口左右有安全区（Duo 外屏旁边的竖排栏、横屏 iPhone 的刘海）。
        /// 这种设备上不能整页滑动：列表（UIKit）的安全区是按它在窗口里的位置算的，页面往右滑出去时右边的安全区越来越大，
        /// 内容被一点点压窄（文字重新折行），滑到位又弹回来——打开后「突然拉长一点」、关闭时「先压缩再收起」。改成整页淡入淡出。
        static func make(for window: CGSize, sideInsets: Bool = false) -> PagePresentation {
            if DuoLayout.isDuoInner(window) { return .sheet }
            if LayoutClass.forSize(window) == .wide { return .cover }
            return .push          // 直板 / Duo 外屏：系统导航栈的原生推入（页面是一整张卡，系统自己处理侧边安全区和右划返回）
        }
    }

    let model: AppModel
    /// 不用 @ObservedObject：设置里任何一项变化（拖语速滑块的每一帧）都会让整个 RootView 重新求值。
    /// 根视图只关心外观和摆放，用 onReceive 各抄一份；其余同步交给 `RootObservers`。
    private let settings: AppSettings
    @State private var scheme: ColorScheme?
    @State private var tentMode: TentMode
    @State private var screen: Screen
    @State private var showingHistory: Bool
    @State private var showingAdd: Bool
    @State private var showingSettings: Bool
    /// 三种面板各自的呈现方式。打开着的时候不改（免得转屏 / 折叠把已打开的页面顶掉），第一次量到尺寸时都要算一遍。
    @State private var historyMode = PagePresentation.push
    @State private var settingsMode = PagePresentation.push
    /// 加入面板：Duo 内屏是第二块屏里的淡入页，其余是半屏弹层
    @State private var layoutSettled = false
    /// 设置里正显示着子页（朗读声音 / 离线语言包）：这时左缘右滑是系统的「返回上一级」，不能同时把设置整个关掉
    @State private var settingsInSubpage = false
    /// 历史里推入了二级页（Duo 屏里点开一场对话的详情）：同上，左缘右滑是返回上一级
    @State private var historyInSubpage = false
    /// 面对面页的键盘输入模式
    @State private var faceTyping: Bool
    /// 系统正把工具栏竖排在右侧（Duo 外屏 / 内屏横向）：这时仍用系统的竖排栏
    @State private var railVertical = false
    /// 页面读到的系统工具栏方向（原值）。折叠 / 展开 Duo 时页面可能没有重新报，所以外屏另按窗口尺寸判定，见 `updateRail()`
    @State private var reportedVertical = false
    /// 同声传译页盖在上面时，下面的标签页还停在哪一个（不能在同声传译淡入的 0.25s 里硬切回「面对面」）
    @State private var tabUnderEavesdrop: Screen = .faceToFace
    /// iPad 整屏盖上路径：历史点了对话后，等盖层收完再在溶解里载入
    @State private var pendingLoad: (() -> Void)?
    @State private var canvasSize = CGSize.zero
    @State private var showingOnboarding: Bool
    @State private var showingDemoPhoto: Bool
    @State private var pendingExit: AddPanelView.Exit?
    /// 历史页里点了某场对话 / 新对话：等页面收起来之后再切页，避免转场躲在页面下面跑完
    @State private var pendingScreen: Screen?
    @State private var bigDisplay: BigDisplayRequest?
    /// 开屏后依次把设置 / 历史 / 加入面板 / 语言列表 / 对话流各建一份（不可见、1×1，每份约一秒）：第一次点开时 SwiftUI 要现场建视图图、
    /// 查 Swift 协议一致性（`swift_conformsToProtocol` 首次查找是线性扫描，模拟器 Release 抽样占首开主线程时间的 35–45%），
    /// 比之后慢好几倍（设置首开约 400–690ms，第二次约 100ms）。提前建一遍，第一次点开也是「第二次」的速度。
    /// 放在一个 `@Observable` 盒子里、只由 `PrewarmHost` 读：原来是 RootView 自己的 `@State`，每换一步（开屏后十来秒里 12 次）
    /// 整个 RootView 连同首页 / 对话流的每一行都要重新求值一遍。
    @State private var prewarm = PrewarmState()
    enum PrewarmStage: CaseIterable { case settings, history, add, languages, stream, dock }
    @Observable final class PrewarmState { var stage: PrewarmStage? }
    /// 设置 / 历史（推入模式）开屏后建一份常驻（藏在屏幕右边外面）：打开只是把已经建好的页面滑进来，关掉也不再拆 List。
    /// 现场建 / 拆一个 List（UICollectionView + 二三十个自适应高度的行）每次要 130–280ms 主线程（模拟器 Release 抽样），
    /// 正好落在推入 / 返回动画里，动画就卡。
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var session: ConversationSession { model.session }

    init(model: AppModel) {
        self.model = model
        KeyboardVisibility.shared.start()
        settings = model.settings
        _scheme = State(initialValue: model.settings.appearance.colorScheme)
        _tentMode = State(initialValue: model.settings.tentMode)
        _screen = State(initialValue: model.launch.screen)
        _showingHistory = State(initialValue: model.launch.showHistory)
        _showingAdd = State(initialValue: model.launch.showAdd)
        _showingSettings = State(initialValue: model.launch.showSettings)
        _showingOnboarding = State(initialValue: model.showsOnboarding)
        _showingDemoPhoto = State(initialValue: model.launch.showPhotoSplit)
        // 启动时就带着面板打开（调试参数 / 恢复现场）：呈现方式按窗口尺寸一开始就定好，不等第一次量尺寸
        let window = Self.currentWindowSize()
        if window.width > 0 {
            _historyMode = State(initialValue: PagePresentation.make(for: window))
            _settingsMode = State(initialValue: PagePresentation.make(for: window))
        }
        // 从对话流回来时，草稿还在就继续显示打字界面（否则草稿在面对面页里看不见）
        _faceTyping = State(initialValue: model.launch.typing || !model.session.draft.isEmpty)
        if model.launch.showBigDisplay {
            _bigDisplay = State(initialValue: BigDisplayRequest(
                text: "请问最近的地铁站怎么走？我想去机场，需要换乘吗？大概要多长时间？",
                translation: "Excuse me, how do I get to the nearest subway station? I want to go to the airport. Do I need to transfer? How long will it take?"))
        }
    }

    /// 有没有整页盖在最上面（引导页）：底下的页面不让 VoiceOver 读到。系统弹层（sheet）自己会处理底下页面的无障碍。
    private var overlayOpen: Bool { showingOnboarding }

    var body: some View {
        let _ = BodyCount.hit("RootView")
        let _ = LaunchClock.mark("root.body")
        rootEffects
    }

    private var rootStack: some View {
        // 不用 GeometryReader：它的内容闭包不会因为外层状态（screen / 竖排栏 / 键盘）变化而重新计算，
        // 同声传译页进不来、控制条不刷新都是这个原因。改成读一次尺寸存进状态，内容直接写在 body 里。
        ZStack {
            // 量到尺寸之前（第一帧）也有底：否则启动 / 重建的那一帧是窗口的白底，深色主题下会闪一下
            AuroraBackground().ignoresSafeArea()
            if canvasSize.width > 0 {
                // 布局类别按整个窗口判断：键盘弹出时可用高度被压矮，Duo 横放会被误判成窄屏
                content(layout: LayoutClass.forWindow(fallback: canvasSize), size: canvasSize, railVertical: railVertical)
                    .accessibilityHidden(overlayOpen)
                    .allowsHitTesting(!overlayOpen)
                    .transition(.identity)           // 开屏直接呈现界面：这个 if 默认带一个淡入转场，会让整页从暗色里慢慢浮出来
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Duo 内屏：根视图不随键盘变尺寸（否则键盘一升起 canvasSize 变化、整页重排）；标签页的内容是系统另外托管的，各自处理键盘
        .ignoresSafeArea(.keyboard, edges: DuoLayout.isDuoInner(windowSize) ? .bottom : [])
        .onGeometryChange(for: CGSize.self) { $0.size } action: { canvasSize = $0 }
        .onChange(of: canvasSize, initial: true) { _, _ in
            // 打开着的时候不改（免得转屏把已打开的页面顶掉）；第一次量到尺寸时（含启动就带着面板）都要算一遍
            let mode = presentation()
            if !showingHistory || !layoutSettled { historyMode = mode }
            if !showingSettings || !layoutSettled { settingsMode = mode }
            let layoutWasSettled = layoutSettled
            layoutSettled = true
            updateRail()
            // 内屏 → 外屏（合上）：内屏的键盘输入弹层收掉（外屏的键盘输入是面对面页自己的版面，不跟着冒出来）
            let inner = DuoLayout.isDuoInner(windowSize)
            if wasInner && !inner { faceTyping = false }
            let crossed = wasInner != inner && layoutWasSettled
            wasInner = inner
            var instant = Transaction()
            instant.disablesAnimations = true
            // 外屏 ⇄ 内屏：两块屏的呈现方式不同（外屏整页推入、内屏居中弹层），开着的页面先按旧方式收掉，
            // 等窗口换好再按新方式重新打开——原来只收不开，用户合上 / 展开一下，正在看的设置 / 历史就没了
            var reopenSettings = false, reopenHistory = false, reopenAdd = false
            withTransaction(instant) {
                if DuoLayout.isDuoInner(windowSize) {
                    if showingSettings && settingsMode == .push { showingSettings = false; reopenSettings = true }
                    if showingHistory && historyMode == .push { showingHistory = false; reopenHistory = true }
                } else {
                    if showingSettings && settingsMode == .sheet { showingSettings = false; reopenSettings = true }
                    if showingHistory && historyMode == .sheet { showingHistory = false; reopenHistory = true }
                }
                // 加入对话弹层的高度 / 拖动条 / 有没有短语区是按打开时那块屏定的：跨屏时也收掉重开
                if crossed && showingAdd { showingAdd = false; reopenAdd = true }
            }
            if reopenSettings || reopenHistory || reopenAdd {
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(450))
                    if reopenSettings, !showingSettings { openSettings() }
                    else if reopenHistory, !showingHistory { openHistory() }
                    else if reopenAdd, !showingAdd { openAdd() }
                }
            }
        }
        // 竖排栏的有无是页面读到系统工具栏之后才知道的：知道了就重新定呈现方式（没打开着时），
        // 免得打开的那一刻才把常驻页从「推入」换成「淡入」、整页重建
        .onChange(of: screen, initial: true) { _, now in if now != .eavesdrop { tabUnderEavesdrop = now } }
        .onChange(of: faceTyping) { _, now in
            if !now, typingFromStream, screen == .faceToFace { typingFromStream = false; go(.stream) }
            if !now { typingFromStream = false }
        }
        .onChange(of: railVertical) { _, _ in
            if !showingHistory { historyMode = presentation() }
            if !showingSettings { settingsMode = presentation() }
        }
        .environment(\.reportBarsVertical, reportVertical)
        .onChange(of: model.hinge.activeFold != nil, initial: true) { _, folded in KeyboardVisibility.shared.isFolded = folded }
        .background { HingeObserver(monitor: model.hinge).ignoresSafeArea() }
        .overlay { if model.launch.foldProbe { FoldProbe(hinge: model.hinge) } }
        .preferredColorScheme(scheme)
        .simultaneousGesture(edgeSwipe)
    }

    /// 弹层 / 全屏盖上（拆成几段：一条修饰符链太长，编译器要很久）
    private var rootCovers: some View {
        rootStack
        // iPad：系统整屏盖上；加入面板在窄屏 / iPad 上是半屏弹层
        .fullScreenCover(isPresented: Binding(get: { layoutSettled && showingHistory && historyMode == .cover }, set: { if !$0 { showingHistory = false } }), onDismiss: historyDismissed) {
            historyPanel(onClose: nil, usesBack: false)
        }
        .fullScreenCover(isPresented: Binding(get: { layoutSettled && showingSettings && settingsMode == .cover }, set: { if !$0 { showingSettings = false } })) {
            settingsView(onClose: nil, usesBack: false)
                .translationModalHost()          // 设置盖在根上：系统「下载语言」窗口从设置里弹出
        }
        // Duo 内屏（展平）：设置 / 历史 / 加入对话都是屏幕正中的系统表单弹层；半开时系统自己让位
        .sheet(isPresented: Binding(get: { layoutSettled && showingSettings && settingsMode == .sheet }, set: { if !$0 { showingSettings = false } })) {
            settingsView(onClose: nil, usesBack: false, asSheet: true)
                .translationModalHost()
                .presentationSizing(.form)
        }
        .sheet(isPresented: Binding(get: { layoutSettled && showingHistory && historyMode == .sheet }, set: { if !$0 { showingHistory = false } }), onDismiss: historyDismissed) {
            historyPanel(onClose: nil, usesBack: false, asSheet: true)
                .presentationSizing(.form)
        }
        .sheet(isPresented: Binding(get: { layoutSettled && showingAdd }, set: { if !$0 { showingAdd = false } }), onDismiss: runPendingExit) {
            AddPanelView(session: session) { pendingExit = $0 }
                .preferredColorScheme(scheme)
                .presentationSizing(.form)
        }
        .fullScreenCover(isPresented: $showingDemoPhoto) {
            PhotoSplitView(image: DemoImages.menu, session: session, title: "图片文字",
                           onSent: { showingDemoPhoto = false }, onClose: { showingDemoPhoto = false })
        }
    }

    private var rootEffects: some View {
        rootCovers
        // 首次使用引导：盖在最上面的整页，不是系统的 fullScreenCover（后者开屏时会从下面滑上来，是一个 App 不该有的开屏动画）。
        // 出现时直接就在；结束时整页淡出。
        .overlay {
            if showingOnboarding {
                OnboardingView(session: session, settings: settings, packs: model.packs) {
                    withAnimation(reduceMotion ? .reducedPage : .page) { showingOnboarding = false }
                }
                .environment(\.activeFold, model.hinge.activeFold?.frame)          // 半开时两栏按折痕分
                .preferredColorScheme(scheme)
                .accessibilityAddTraits(.isModal)
                .transition(.asymmetric(insertion: .identity, removal: .opacity))
                .zIndex(10)
            }
        }
        .onReceive(settings.$appearance) { scheme = $0.colorScheme }
        .onReceive(settings.$tentMode) { tentMode = $0 }
        // 设置同步、触觉、音频会话释放、常亮等「观察会话 / 设置」的副作用都放进 RootObservers：
        // 写在根视图里，每个识别中间结果、每次设置改动都会让整个根视图（含两个标签页）重新求值
        .background { RootObservers(model: model, bigDisplayActive: bigDisplay != nil) }
        .overlay(alignment: .topLeading) { PrewarmHost(state: prewarm) { prewarmViews(for: $0) } }
        .onAppear {
            LaunchClock.mark("root.appear")
            if LaunchClock.enabled {
                DispatchQueue.main.async { LaunchClock.mark("root.appear.nextloop") }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { LaunchClock.mark("root.appear+50ms") }
            }
            BodyCount.startReporting()
            #if DEBUG || PERF_HOOKS
            HitchLog.start()
            #endif
            BlankTapKeyboardDismisser.shared.install()
            // 调试：`-XTransSlowAnim` 把整个窗口的动画放慢到 1/8，逐帧看过渡（模拟器截图的间隔比 0.3s 的动画还长）
            #if DEBUG || PERF_HOOKS
            if ProcessInfo.processInfo.arguments.contains("-XTransSlowAnim") {
                for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
                    scene.windows.forEach { $0.layer.speed = 0.12 }
                }
            }
            #endif
        }
        .task {
            // 排查用（Release 也生效）：`-XTransDumpPacks` 启动时把系统对每种语言包的原始回答打印到 stdout 并写进 Documents，
            // 这样可以用 `devicectl device process launch --console` 在真机上直接读到，不用人截图
            if ProcessInfo.processInfo.arguments.contains("-XTransDumpPacks") {
                let lines = await model.packs.diagnosticLines() + ["--- extra languages (not in our app) ---"] + (await model.packs.extraDiagnosticLines())
                let text = "XTRANS_PACKS_BEGIN\n" + lines.joined(separator: "\n") + "\nXTRANS_PACKS_END\n"
                FileHandle.standardOutput.write(Data(text.utf8))
                if let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
                    try? text.write(to: docs.appendingPathComponent("pack-diagnostics.txt"), atomically: true, encoding: .utf8)
                }
            }
            // 朗读声音列表：一启动就在后台枚举一次存缓存（真机上声音几百个、第一次要好几百毫秒），之后点进「朗读声音」直接有。
            // 以前排在预热序列最后（启动后十几秒），用户早点点进去就在主线程现枚举，很卡
            Task.detached(priority: .utility) { _ = await VoiceCatalog.refresh() }
            guard !ProcessInfo.processInfo.arguments.contains("-XTransNoPrewarm") else { return }
            /// 等用户手上没事再建：按住说话、正在翻译 / 朗读、页面开着、同声传译时都不建，每步之后重新检查
            @MainActor func whenIdle() async {
                while session.phase != .idle || MicButton.pressingCount > 0 || session.isEavesdropping || showingSettings || showingHistory || showingAdd || showingOnboarding {
                    try? await Task.sleep(for: .seconds(1))
                }
            }
            try? await Task.sleep(for: .seconds(1.5))
            // 依次建（设置 → 历史 → 加入 → 语言 → 对话流），每样隔约一秒：一次全建会在开屏后一两秒内卡一下主线程。
            // 设置最先：它的首次打开最重（外屏上约 690ms）
            for stage in PrewarmStage.allCases {
                await whenIdle()
                prewarm.stage = stage
                try? await Task.sleep(for: .milliseconds(stage == .stream ? 1200 : 1000))
                prewarm.stage = nil
                try? await Task.sleep(for: .milliseconds(500))
            }
            // 键盘（系统首次弹出很重）：空闲时无声地走一遍
            await whenIdle()
            await KeyboardPrewarm.run()
            // 最后把「另一个标签页」真正建出来：冻住窗口，切过去、等它排好、再切回来。第一次点标签就不会卡在切换动画里
            try? await Task.sleep(for: .seconds(0.8))
            await whenIdle()
            guard screen == .faceToFace, !faceTyping, bigDisplay == nil, !showingDemoPhoto else { return }
            await withFrozenWindow {
                var instant = Transaction()
                instant.disablesAnimations = true
                withTransaction(instant) { screen = .stream }
                try? await Task.sleep(for: .milliseconds(700))
                withTransaction(instant) { screen = .faceToFace }
                try? await Task.sleep(for: .milliseconds(120))
            }
        }
        // 调试：`-XTransAutoMotion` 自动依次做 切对话流 / 切面对面 / 开设置 / 返回 / 开历史 / 返回，配合 Instruments 的 Animation Hitches 量卡顿（真机没法远程点屏幕）
        #if DEBUG || PERF_HOOKS
        // 调试：`-XTransAutoTyping` 每 5 秒一轮「打开键盘输入 → 点空白处收起」（和点「键盘输入」/ 点页面空白处同一条路径），
        // 配合 `simctl io recordVideo` 逐帧看输入条的开合过渡（模拟器重启后触控通道要等很久，手点没法复现）
        .task {
            guard ProcessInfo.processInfo.arguments.contains("-XTransAutoTyping") else { return }
            func pause(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }
            let start = UserDefaults.standard.double(forKey: "XTransAutoTypingStart")          // `-XTransAutoTypingStart 16`：等预热做完再开始
            await pause(start > 0 ? start : 4)
            for _ in 0..<4 {
                startTyping(); await pause(3.2)
                dismissKeyboard(); await pause(2.3)
            }
        }
        .task {
            guard ProcessInfo.processInfo.arguments.contains("-XTransAutoMotion") else { return }
            func pause(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }
            await pause(3)
            for _ in 0..<2 {
                go(.stream); await pause(2)
                go(.faceToFace); await pause(2)
                openSettings(); await pause(2.5)
                closeSettings(); await pause(2)
                openHistory(); await pause(2.5)
                closeHistory(); await pause(2)
            }
        }
        #endif
    }

    /// Duo 外屏上标签栏一定是竖排的：页面读到的方向在折叠 / 展开的过程中可能是旧的（展开后中间条变长、折回外屏却不恢复短条），
    /// 所以外屏按窗口尺寸直接判定；其他设备用页面读到的值。
    private func updateRail() {
        let value = reportedVertical || DuoLayout.isDuoOuter(windowSize) || DuoLayout.isDuoLandscape(windowSize)      // 内屏横放时系统栏也是竖排在右侧
        if railVertical != value { railVertical = value }
    }

    /// 这台设备现在能不能整页滑动（见 `PagePresentation.make`）
    private func presentation() -> PagePresentation {
        let window = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
        let insets = window?.safeAreaInsets ?? .zero
        return PagePresentation.make(for: windowSize, sideInsets: railVertical || insets.left > 0 || insets.right > 0)
    }

    /// 整个窗口的尺寸：不随键盘变化（`canvasSize` 是安全区里的可用尺寸，键盘一弹出高度就被压矮）。
    private var windowSize: CGSize {
        let size = Self.currentWindowSize()
        return size.width > 0 ? size : canvasSize
    }

    private static func currentWindowSize() -> CGSize {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.compactMap(\.keyWindow).first?.bounds.size
            ?? scenes.first?.screen.bounds.size ?? .zero
    }

    // MARK: 打开 / 关闭次级页面

    /// 推入 / 淡入 / 推出（见下面的动画选择）。
    private func withPush(_ mode: PagePresentation = .push, _ body: () -> Void) {
        // 滑动用 `.push`，整页淡入淡出用 `.page`，减少动态效果用 `.reducedPage`：开和关、按钮和手势都走同一条
        // 推入由系统导航栈负责（它自己的动画 / 手势）；这里只管 Duo 内屏的整页淡入淡出
        if mode == .push || mode == .sheet || mode == .cover { body(); return }
        withAnimation(reduceMotion ? .reducedPage : .page, body)
    }

    /// 打开前先收键盘（键盘输入时点历史 / 设置：键盘不收的话会盖住新页面的下半截，打的字还进了藏在底下的输入框），
    /// 再按当前窗口尺寸重新算一遍呈现方式（转屏、折叠之后旧的可能不对）。
    /// 页面开 / 关之后告诉 VoiceOver 屏幕变了：焦点回到新的最上层页面，不留在被盖住的那一页
    private func announceScreenChange() {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            UIAccessibility.post(notification: .screenChanged, argument: nil)
        }
    }

    private func openHistory() {
        dismissKeyboard()
        typingFromStream = false
        faceTyping = false          // 打字模式不能带进新页面：键盘已经收了，回来时还停在没有键盘的打字版面
        announceScreenChange()
        if !showingHistory { historyMode = presentation() }
        withPush(historyMode) { showingHistory = true }
    }

    private func openSettings() {
        dismissKeyboard()
        typingFromStream = false
        faceTyping = false
        announceScreenChange()
        if !showingSettings { settingsMode = presentation() }
        withPush(settingsMode) { showingSettings = true }
    }

    private func openAdd() {
        dismissKeyboard()
        typingFromStream = false
        faceTyping = false
        announceScreenChange()
        showingAdd = true
    }

    /// 关页面一律先收键盘：常驻页关着的时候不会被拆掉，搜索框的焦点和键盘会一直留在对话页上
    private func closeHistory() {
        dismissKeyboard()
        announceScreenChange()
        if historyMode == .cover || historyMode == .sheet { showingHistory = false }
        else { withPush(historyMode) { showingHistory = false } }
    }

    private func closeSettings() {
        dismissKeyboard()
        announceScreenChange()
        if settingsMode == .cover || settingsMode == .sheet { showingSettings = false } else { withPush(settingsMode) { showingSettings = false } }
    }

    /// 从历史里点了某场对话 / 新对话：直接换页——整页溶解承担转场，不再先把「完全打开的历史页」冻结成快照、
    /// 让下面的滑出动画白跑（iPad 的整屏盖上仍走原来的 onDismiss 路径）。
    /// `load`：载入 / 新建对话。要放进溶解的闭包里：已挂载的对话流页和半屏在快照盖着时才换内容，
    /// 不会在淡出过程中自己做「气泡上浮、列表滚动」。
    private func leaveHistory(to target: Screen, load: @escaping () -> Void) {
        let keyboardWasUp = KeyboardVisibility.shared.isVisible
        dismissKeyboard()
        if historyMode == .cover || historyMode == .sheet {
            pendingLoad = load            // 盖层收完（onDismiss）后在整页溶解里载入：原来先载入，下面的页面在盖层滑下时自己做上浮 / 滚动
            pendingScreen = target
            showingHistory = false
        } else {
            crossfadePage(reduceMotion: reduceMotion, keyboardWasUp: keyboardWasUp) {
                load()
                showingHistory = false
                screen = target
            }
        }
    }

    private func historyPanel(onClose: (() -> Void)?, usesBack: Bool, isActive: Bool = true, inOuterStack: Bool = false, asSheet: Bool = false) -> some View {
        HistoryView(
            session: session,
            onOpen: { id in leaveHistory(to: .stream) { session.load(id) } },
            onNew: { leaveHistory(to: .faceToFace) { session.newConversation() } },
            onClose: onClose,
            usesBackButton: usesBack,
            railVertical: railVertical,
            isActive: isActive,
            inOuterStack: inOuterStack,
            inSheet: asSheet,
            onSubpage: { historyInSubpage = $0 }
        )
        .preferredColorScheme(scheme)
    }

    /// 见 `prewarmStage`：不可见、不可点、不进无障碍树。
    @ViewBuilder
    private func prewarmViews(for stage: PrewarmStage?) -> some View {
        if let stage {
            ZStack {
                switch stage {
                case .settings: settingsView(onClose: nil, usesBack: false, asSheet: true)
                case .history: historyPanel(onClose: nil, usesBack: false, asSheet: true)
                case .add: AddPanelView(session: session) { _ in }.preferredColorScheme(scheme)
                case .languages: LanguagePickerSheet(session: session, packs: model.packs).preferredColorScheme(scheme)
                case .stream:
                    StreamView(session: session, isOnline: true, onBack: {}, onOpenHistory: {}, onAdd: {}, onBigDisplay: { _ in },
                               topSegment: false)
                case .dock:
                    // 键盘输入条：第一次构建要几百毫秒（输入框、玻璃、两排按钮），不预热的话第一次点「键盘输入」时主线程被它占住，条出得慢、动画卡一下
                    ComposerDock(session: session, onPickLanguage: {}, onClose: {}, prewarming: true)
                }
            }
            .environment(\.reportBarsVertical, nil)        // 预热的页面不能把它读到的工具栏方向报给根视图（会把 railVertical 翻一下）
            .frame(width: 390, height: 800)
            .scaleEffect(0.01, anchor: .topLeading)
            .frame(width: 4, height: 8, alignment: .topLeading)
            .clipped()
            .opacity(0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    private func historyDismissed() {
        if let target = pendingScreen {
            pendingScreen = nil
            let load = pendingLoad
            pendingLoad = nil
            crossfadePage(reduceMotion: reduceMotion) { load?(); screen = target }
        }
    }

    /// 页面读到系统工具栏的方向后告诉根视图（延后一拍：避免在页面刷新当中改状态）
    private var reportVertical: (Bool) -> Void {
        { value in DispatchQueue.main.async { reportedVertical = value; updateRail() } }
    }

    private func settingsView(onClose: (() -> Void)?, usesBack: Bool, isActive: Bool = true, inOuterStack: Bool = false, asSheet: Bool = false) -> some View {
        SettingsView(session: session, settings: settings, packs: model.packs, engineName: session.engineName,
                     onClose: onClose, usesBackButton: usesBack, railVertical: asSheet ? false : railVertical, isActive: isActive, inOuterStack: inOuterStack,
                     inSheet: asSheet,
                     onSubpage: { settingsInSubpage = $0 })
            .preferredColorScheme(scheme)
    }

    @ViewBuilder
    private func content(layout: LayoutClass, size: CGSize, railVertical: Bool) -> some View {
        // 直板 iPhone 竖屏（设计稿 iPhone 方案 A）：没有系统标签栏；面对面里把中间条上滑进对话流，对话流顶部分段切回来
        let topSegment = size.height > size.width && !railVertical && layout == .compact
        ZStack {
            // "面对面 / 对话流"是系统标签栏（方案 B）：直板机在底部，Duo 外屏 / 内屏横向由系统竖排在右侧那一列。
            TabView(selection: tabSelection) {
                Tab(value: Screen.faceToFace) {
                    FaceToFaceView(
                        session: session,
                        tentMode: model.launch.forceTent ? .on : tentMode,
                        hinge: model.hinge,
                        typing: typingBinding(for: .faceToFace),
                        hidesTabBar: topSegment,
                        onOpenStream: { go(.stream) },
                        onOpenHistory: { openHistory() },
                        onAdd: { openAdd() },
                        onSettings: { openSettings() },
                        onBigDisplay: { bigDisplay = $0 },
                        packs: model.packs,
                        colorScheme: scheme
                    )
                } label: { BarLabel("面对面", symbol: "person.2", pointSize: 16, maxWidth: 20) }
                Tab(value: Screen.stream) {
                    Group {
                    if layout == .wide {
                        WideConversationView(
                            session: session,
                            isOnline: model.network.isOnline,
                            onBack: { go(.faceToFace) },
                            onOpenHistory: { openHistory() },
                            onBigDisplay: { bigDisplay = $0 },
                            onToolExit: { pendingExit = $0; runPendingExit() },
                            packs: model.packs,
                            onAdd: { openAdd() },
                            onKeyboard: { startTyping() },
                            onSettings: { openSettings() },
                            typing: typingBinding(for: .stream),
                            colorScheme: scheme
                        )
                    } else {
                        StreamView(
                            session: session,
                            isOnline: model.network.isOnline,
                            onBack: { go(.faceToFace) },
                            onOpenHistory: { openHistory() },
                            onAdd: { openAdd() },
                            onBigDisplay: { bigDisplay = $0 },
                            topSegment: topSegment
                        )
                    }
                    }
                } label: { BarLabel("对话流", symbol: "text.alignleft", pointSize: 16, maxWidth: 20) }
            }
            // 设置 / 历史（直板 iPhone 和 Duo 外屏）：在当前标签页自己的导航栈里做系统的原生推入（见 `PushedPages`）
            .environment(\.pushedPages, PushedPages(
                activeScreen: screen == .eavesdrop ? tabUnderEavesdrop : screen,
                settings: Binding(get: { layoutSettled && showingSettings && settingsMode == .push },
                                  set: { if !$0 { showingSettings = false } }),
                history: Binding(get: { layoutSettled && showingHistory && historyMode == .push },
                                 set: { if !$0 { showingHistory = false } }),
                settingsPage: { AnyView(settingsView(onClose: { closeSettings() }, usesBack: true, inOuterStack: true)) },
                historyPage: { AnyView(historyPanel(onClose: { closeHistory() }, usesBack: true, inOuterStack: true)) },
                hidesBar: !railVertical,          // 直板机：设置 / 历史页头画在页面里（`PhonePageHeader`），系统栏隐藏；Duo 外屏竖排栏仍用系统栏
                rail: railVertical,
                settingsSwipeBack: true,          // 系统的右划返回一次退一级（二级页 → 设置 → 对话），不用我们管
                historySwipeBack: true))
            .accessibilityHidden(screen == .eavesdrop || bigDisplay != nil)       // 同声传译 / 大字展示盖在上面：下面的麦克风 / 标签栏不能被 VoiceOver 读到、点到
            .tint(Theme.fg)                  // 选中的标签用前景色，不用粉色
            .toolbarVisibility(topSegment ? .hidden : .automatic, for: .tabBar)

            // 大字展示：和同声传译一样是盖在上面的整页淡入淡出（原来是系统 fullScreenCover 上滑，两种整页接管用了两套转场）
            if let request = bigDisplay {
                BigDisplayView(session: session, request: request) { dismissKeyboard(); bigDisplay = nil }
                    .preferredColorScheme(scheme)
                    .accessibilityAddTraits(.isModal)
                    .zIndex(2)
                    .transition(.opacity)
            }
            if screen == .eavesdrop {
                EavesdropView(session: session, onStop: { session.stopEavesdrop(); go(tabUnderEavesdrop) })      // 回到进来之前的标签页（原来一律回「面对面」，从对话流进来也被送去面对面）
                    .accessibilityAddTraits(.isModal)
                    .zIndex(1)
                    .transition(.opacity)
            }
        }
        // 大字展示的出现 / 消失：整页淡入淡出（和同声传译同一条 `.page`）
        .animation(reduceMotion ? .reducedPage : .page, value: bigDisplay?.id)
        // 半开时的折叠区域（展平 = nil）：同声传译 / 大字展示这样的整页读它来避开折痕
        .environment(\.activeFold, model.hinge.activeFold?.frame)
    }

    /// 键盘输入只属于正在看的那一页：两个标签页都活着，如果都拿到 `faceTyping == true`，就会各建一条输入条、
    /// 两个输入框互相抢焦点（键盘反复起落、主线程空转——Duo 内屏横放对话流实测 CPU 99%、界面卡死）。不在看的那一页永远读到 false。
    private func typingBinding(for tab: Screen) -> Binding<Bool> {
        Binding(get: { faceTyping && tabSelection.wrappedValue == tab },
                set: { faceTyping = $0 })
    }

    /// 标签栏选中的页：同声传译时标签栏被同声传译页盖住，底下仍是面对面。
    private var tabSelection: Binding<Screen> {
        Binding(
            get: { screen == .eavesdrop ? tabUnderEavesdrop : (screen == .stream ? .stream : .faceToFace) },
            set: { newValue in
                // 切标签前先收键盘，避免键盘带着上一页的输入框滑过去
                let keyboardWasUp = KeyboardVisibility.shared.isVisible
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                Haptics.selection()
                crossfadePage(reduceMotion: reduceMotion, keyboardWasUp: keyboardWasUp) {
                    typingFromStream = false
                    faceTyping = false
                    screen = newValue
                }
            }
        )
    }

    /// 从对话流的说话区进的键盘输入：收起后回到对话流（原来收起后留在面对面，用户被带到另一个标签页）
    @State private var typingFromStream = false
    @State private var wasInner = false

    /// 「键盘输入」入口在对话流页里（说话区 / 竖栏菜单 / 输入栏）：
    /// - Duo 内屏：键盘输入是贴在键盘上沿的输入条（`ComposerDock`），直接出现在当前页上，**不切标签**。
    /// - 其他宽屏（iPad）：键盘输入是面对面页的版面，要先切过去，收起后回到对话流。
    private func startTyping() {
        session.prepareForTyping()
        if DuoLayout.isDuoInner(windowSize) {
            typingFromStream = false
            // 输入条直接出现在当前页上（面对面 / 对话流都一样，不切标签）
            withAnimation(reduceMotion ? .easeInOut(duration: 0.15) : .smooth(duration: 0.3)) { faceTyping = true }
            return
        }
        typingFromStream = (screen == .stream)
        go(.faceToFace, thenTyping: true)
    }

    /// `thenTyping`：切过去的同时打开键盘输入——放在同一个瞬时事务里，别让 0.25s 的版面动画叠在整页溶解下面
    private func go(_ target: Screen, thenTyping: Bool = false) {
        // 先收键盘：被移除的页面在转场期间还在，不收的话键盘会一直顶着，新页面还会按"带键盘的安全区"排版
        let keyboardWasUp = KeyboardVisibility.shared.isVisible
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        if target != .eavesdrop, screen != .eavesdrop {
            // 面对面 ⇄ 对话流：整页交叉淡化（见 crossfadePage）
            crossfadePage(reduceMotion: reduceMotion, keyboardWasUp: keyboardWasUp) {
                screen = target
                if thenTyping { faceTyping = true }
            }
        } else {
            withAnimation(reduceMotion ? .reducedPage : .page) { screen = target }
        }
    }

    /// 加入面板关闭后，再去同声传译 / 大字展示（等面板收起来之后切换，避免两个转场互相打架）。
    /// 宽屏的右栏里没有"面板关闭"这回事，所以由它直接调用。
    private func runPendingExit() {
        guard let exit = pendingExit else { return }
        pendingExit = nil
        switch exit {
        case .eavesdrop: go(.eavesdrop)
        case .bigDisplay: bigDisplay = BigDisplayRequest(text: "", translation: nil)
        }
    }

    /// 左缘右滑：对话流页 = 返回面对面（和 iOS 的返回手势一致）；同声传译时不响应（别误触）。
    /// 面对面页上不再「左缘右滑开历史」：历史是从右边推进来的，手指向右、页面却从右边来，方向对不上；入口是中间条最左的按钮。
    /// 只在手势起点离左缘 20pt 内才算，所以不会盖住屏幕左边的按钮。
    private var edgeSwipe: some Gesture {
        DragGesture(minimumDistance: 16).onEnded { value in
            guard value.startLocation.x < 20, value.translation.width > 60,
                  abs(value.translation.width) > abs(value.translation.height),
                  !showingHistory, !showingSettings, !showingAdd, bigDisplay == nil else { return }
            if screen == .stream { go(.faceToFace) }
        }
    }
}



/// 只有它读「现在预热到哪一步」：换一步只重建这一小块，不牵动 RootView。
private struct PrewarmHost<Content: View>: View {
    let state: RootView.PrewarmState
    @ViewBuilder let content: (RootView.PrewarmStage?) -> Content
    var body: some View { content(state.stage) }
}
