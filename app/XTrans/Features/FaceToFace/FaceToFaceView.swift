import SwiftUI

/// 首页：面对面对话。上半屏朝向对方（倒置），下半屏朝向自己，中间是悬浮的全局控制条。
/// 布局只依赖可用空间，不写死机型，所以直板 iPhone 和 iPhone Duo 的屏幕都能直接用。
struct FaceToFaceView: View {
    let session: ConversationSession
    /// 控制条上滑 / 辅助功能动作：去对话流（标签栏之外的快捷方式）
    var onOpenStream: () -> Void = {}
    var onOpenHistory: () -> Void = {}
    var onAdd: () -> Void = {}
    var onSettings: () -> Void = {}
    var onBigDisplay: (BigDisplayRequest) -> Void = { _ in }
    var packs: LanguagePackStore?
    /// 设置里的"双屏摆放"
    let tentMode: TentMode
    /// 铰链 / 折叠状态（只有 Duo 展开使用时才有值）
    let hinge: HingeMonitor

    @State private var showingLanguages = false
    /// 语言条在"平时"和"打字"两套版面之间原地不动，只有两个半屏重新排布
    @Namespace private var stripNS
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    /// 弹层（语言选择）要跟着 App 的外观设置，所以由外面传进来
    var colorScheme: ColorScheme?
    /// 键盘输入模式：由根视图持有，竖向时四角的"键盘"按钮要用它
    @Binding var typing: Bool
    /// 直板 iPhone 竖屏：没有系统标签栏（中间条上滑 / 对话流页顶部分段负责切换，设计稿 M1–M4 / T1）
    var hidesTabBar = false
    /// 系统正把工具栏竖排在屏幕右侧（Duo 外屏 / 内屏横向）：历史、键盘、加入、设置交给系统栏，
    /// 中间的控制条只留语言对。直板 iPhone 不会进入这个状态，保持原来的设计。
    /// 初值和 `SideBarHost` 一样：Duo 外屏 / 内屏横放系统标签栏一定竖排——第一帧就按竖排排，不要先按「带按钮的条」排一遍再重排（切标签时会闪一下）
    @State private var verticalBars = DuoLayout.isDuoOuter(DuoLayout.currentWindowSize) || DuoLayout.isDuoLandscape(DuoLayout.currentWindowSize)

    init(session: ConversationSession, tentMode: TentMode = .auto, hinge: HingeMonitor,
         typing: Binding<Bool>, hidesTabBar: Bool = false,
         onOpenStream: @escaping () -> Void = {}, onOpenHistory: @escaping () -> Void = {},
         onAdd: @escaping () -> Void = {}, onSettings: @escaping () -> Void = {},
         onBigDisplay: @escaping (BigDisplayRequest) -> Void = { _ in }, packs: LanguagePackStore? = nil,
         colorScheme: ColorScheme? = nil) {
        self.colorScheme = colorScheme
        self._typing = typing
        self.hidesTabBar = hidesTabBar
        self.session = session
        self.tentMode = tentMode
        self.hinge = hinge
        self.packs = packs
        self.onSettings = onSettings
        self.onOpenStream = onOpenStream
        self.onOpenHistory = onOpenHistory
        self.onAdd = onAdd
        self.onBigDisplay = onBigDisplay
    }

    var body: some View {
        let _ = BodyCount.hit("FaceToFaceView")
        let _ = LaunchClock.mark("face.body")
        NavigationStack {
            faceBody
                .toolbar { sideToolbar }
                .toolbarTitleDisplayMode(.inline)
                .toolbarVisibility(verticalBars ? .automatic : .hidden, for: .navigationBar)
                // 打字时只收起标签栏（它在栏的最下面，会被键盘盖住）；上面的工具栏保留，仍然看得见、点得到
                .toolbarVisibility(((typing && !isDuoInnerWindow) || hidesTabBar) ? .hidden : .automatic, for: .tabBar)
                .readsVerticalBars($verticalBars)
                .pushedPages(owner: .faceToFace)
        }
        .environment(\.inRailPane, verticalBars)
    }

    /// 系统竖排工具栏里的四个动作：每项都给图标 + 标题（系统竖排时用图标，溢出菜单里用标题）。
    @ToolbarContentBuilder
    private var sideToolbar: some ToolbarContent {
        // 竖栏保持默认（Apple：别改默认栏位、控件跨姿势一致）：打字时 ＋ ⋯ 仍在原位
        // 方案 B：两枚——"加入"和"更多"（历史 / 键盘输入 / 设置收进菜单）。按钮少、栏矮，键盘弹出后也完整露在键盘上方。
        ToolbarItem(placement: .topBarTrailing) {
            Button(action: onAdd) { BarLabel("加入对话", symbol: BarSymbol.add) }
        }
        // 系统会把相邻的工具栏项合进同一个玻璃胶囊；插一个固定间隔，两枚才是各自独立的圆钮（设计稿 B）
        if #available(iOS 26.0, *) {
            ToolbarSpacer(.fixed, placement: .topBarTrailing)
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                // 菜单自己收起要 ~0.2s：页面推入等它收完再开，两个动画不叠在一起
                Button { afterMenu(onOpenHistory) } label: { Label("历史", systemImage: BarSymbol.history) }
                Button(action: toggleKeyboard) { Label("键盘输入", systemImage: BarSymbol.keyboard) }
                Button { afterMenu(onSettings) } label: { Label("设置", systemImage: BarSymbol.settings) }
            } label: {
                BarLabel("更多", symbol: "ellipsis")
            }
        }
    }

    /// Duo 内屏竖放：页头右上角「＋ 加入对话」「⋯ 更多（历史 / 键盘输入 / 设置）」——和对话流竖放同一组、同一个位置；
    /// 语言条里不再放这四个按钮（原来横放在竖栏、竖放在条里、对话流在页头，三种摆法）
    private var innerHeaderActions: some View {
        HStack(spacing: 12) {
            Button(action: onAdd) {
                Image(systemName: BarSymbol.add)
                    .font(.system(size: 17)).foregroundStyle(Theme.fg)
                    .frame(width: 44, height: 44)
                    .glass(in: Circle(), interactive: true)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("加入对话")
            Menu {
                Button { afterMenu(onOpenHistory) } label: { Label("历史", systemImage: BarSymbol.history) }
                // 键盘输入：输入条先在底部淡入，和菜单收起（~0.2s）重叠一点没关系，少等 100ms
                Button { afterMenu(toggleKeyboard, delay: 120) } label: { Label("键盘输入", systemImage: BarSymbol.keyboard) }
                Button { afterMenu(onSettings) } label: { Label("设置", systemImage: BarSymbol.settings) }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 17)).foregroundStyle(Theme.fg)
                    .frame(width: 44, height: 44)
                    .glass(in: Circle(), interactive: true)
            }
            .accessibilityLabel("更多")
        }
        .padding(.top, 10)          // 和对话流页头的「＋ ⋯」同一条水平线
        .padding(.trailing, 20)
    }

    private func afterMenu(_ action: @escaping () -> Void, delay: Int = 220) {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(delay))
            action()
        }
    }

    /// 打字时对话页不动、输入条贴在键盘上（`ComposerDock`，设计稿 typing-v3 方案 A）：所有竖屏窗口 + Duo 内屏（横 / 竖）。
    /// 直板横屏 / 外屏横放（键盘上方只剩一百多点高）仍是原来的左右两栏版面。
    private var usesComposerCard: Bool {
        let window = DuoLayout.currentWindowSize
        return isDuoInnerWindow || window.height > window.width
    }
    /// 输入条上沿在窗口里的位置（量到的）：对方半屏按它让开被条盖住的那一截
    @State private var dockTop: CGFloat?
    /// 输入条打开约 0.7s 之后：键盘要么已经升起、要么不会升起（接了实体键盘），之后一律用量到的位置
    @State private var dockSettled = false
    @State private var dockSettleToken = 0
    private func coveredFrom(fullHeight: CGFloat) -> CGFloat {
        // 键盘升起后用量到的位置；键盘还没起来（条还在屏幕底）时用预估的，免得键盘升起那一下预览再跳一次
        if let dockTop, dockSettled || dockTop < fullHeight - 200 { return dockTop }
        let portrait = DuoLayout.currentWindowSize.height > DuoLayout.currentWindowSize.width
        let known = KeyboardVisibility.shared.height(portrait: portrait)
        let keyboard = known > 150 ? known : fullHeight * 0.4
        return fullHeight - keyboard - 124          // 条高约 116 + 离键盘 8（原来写 132，和实测差 8pt，键盘到位后预览会小跳一下）
    }
    /// Duo 内屏竖放：底下浮着系统标签栏，下面那个麦克风几乎碰到它、上面那个却很松——
    /// 上下各多让出同样一段（两个人的麦克风仍然关于语言条对称），下面的离标签栏远一点，上面的对称地往里挪
    private func layoutInsets(_ i: (top: CGFloat, leading: CGFloat, bottom: CGFloat, trailing: CGFloat))
        -> (top: CGFloat, leading: CGFloat, bottom: CGFloat, trailing: CGFloat) {
        guard isDuoInnerWindow, !hidesTabBar else { return i }
        let size = DuoLayout.currentWindowSize
        guard size.height > size.width else { return i }
        let vertical = max(i.top, i.bottom) + 36
        return (vertical, i.leading, vertical, i.trailing)
    }
    private var typingReflows: Bool { typing && !usesComposerCard }

    private var faceBody: some View {
        ZStack(alignment: .bottom) {
            pageBody
            if typing && usesComposerCard {
                ComposerDock(session: session,
                             onPickLanguage: { showingLanguages = true },          // 不自己收键盘：系统弹层升起时会把键盘一起带走，关掉后再带回来
                             onClose: { closeKeyboard() },
                             keepsOpen: showingLanguages,
                             onTopChange: { dockTop = $0 })
                    .opacity(showingLanguages ? 0 : 1)          // 选语言时条先让开（不然它会掉到屏幕底、露在弹层后面）
                    .animation(.easeOut(duration: 0.12), value: showingLanguages)
                    // 进场：0.12s 淡入（条先在位，再跟键盘一起升）。退场：0.14s 淡出——条贴着键盘往下落，淡得慢的话半透明的条会压到下面的内容上
                    .transition(.asymmetric(insertion: .opacity.animation(.easeOut(duration: 0.12)),
                                            removal: .opacity.animation(.easeOut(duration: 0.14))))
                    .zIndex(1)          // 必须显式给层级：ZStack 里正在退场的视图会被排到最底下，卡片就被不透明的页面盖住、看起来是瞬间消失（没有淡出下落）
            }
        }
        .languagePicker(isPresented: $showingLanguages, session: session, packs: packs, scheme: colorScheme)
        .overlay(alignment: .topTrailing) {
            if DuoLayout.isDuoPortrait(DuoLayout.currentWindowSize) { innerHeaderActions }          // 只看窗口，不看 verticalBars（它第一帧还没读到系统栏）
        }
        .onChange(of: typing, initial: true) { _, now in          // initial：启动时就带着打字状态（有草稿 / 调试直达）也要走一遍
            dockSettled = false
            dockSettleToken += 1
            let token = dockSettleToken          // 700ms 内关掉又重开：前一次的计时到点时不能把新一轮提前置为「已稳定」
            if now {
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(700))
                    if typing, token == dockSettleToken { dockSettled = true }
                }
            } else {
                dockTop = nil
            }
        }
    }

    private var pageBody: some View {
        // 外层 GeometryReader 尊重安全区，所以能读到真实的安全区（灵动岛 / Home 指示条 / Duo 外屏右侧的摄像头区）。
        // 注意：如果直接给 GeometryReader 加 .ignoresSafeArea()，读到的安全区会变成 0。
        GeometryReader { outer in
            let insets = (top: outer.safeAreaInsets.top, leading: outer.safeAreaInsets.leading,
                          bottom: outer.safeAreaInsets.bottom, trailing: outer.safeAreaInsets.trailing)
            // 完整屏幕尺寸 = 安全区内的尺寸 + 四边的安全区
            let full = CGSize(width: outer.size.width + insets.leading + insets.trailing,
                              height: outer.size.height + insets.top + insets.bottom)
            // 折痕只在半开时存在（division 区域起作用）；展平时是一整块连续画布，控制条就在整屏正中
            let activeFold = hinge.activeFold?.frame
            let arrangement = FaceGeometry.arrangement(size: full,
                                                       // Duo 内屏一律「自动」：展平是一整块连续画布，只有半开才分屏。
                                                       // 「双屏摆放」在 Duo 上已经不显示，旧版本存下的「左右分屏」不能让展平态一直留着写死 40pt 的分屏
                                                       mode: DuoLayout.isDuoInner(DuoLayout.currentWindowSize) ? .auto : tentMode,
                                                       hinge: hinge.status, fold: activeFold)
            if typingReflows {
                // 横屏打字时键盘占了下面一块（算在安全区里），不再追求对称：就在安全区内排
                typingLayout(size: outer.size, full: full, arrangement: arrangement)
            } else {
                // 半开且折痕竖着：左右分屏以真正的折痕（窗口坐标）为界
                let crease: ClosedRange<CGFloat>? = activeFold.flatMap { $0.height > $0.width ? $0.minX...$0.maxX : nil }
                symmetricLayout(FaceGeometry.compute(size: full, insets: layoutInsets(insets), arrangement: arrangement, crease: crease), size: full)
                    .offset(x: -insets.leading, y: -insets.top)       // 把整屏的坐标系挪回屏幕左上角
            }
        }
        // 平时的对称版面不受键盘影响（否则键盘收起的那一刻会先按"被键盘顶过"的安全区排一遍，再弹开）；
        // 竖屏打字也不动（撰写卡自己贴着键盘）；只有横屏打字的左右两栏才让键盘把内容顶上去。
        .ignoresSafeArea(.keyboard, edges: typingReflows ? [] : .bottom)
        .background { AuroraBackground() }
    }

    // MARK: 平时：严格对称

    /// 每个元素都放在 `FaceGeometry` 算好的格子里：两个半屏一样大，麦克风离各自边缘一样远，
    /// 控制条在正中心（折叠时在我这一侧）。
    private func symmetricLayout(_ g: FaceGeometry, size: CGSize) -> some View {
        // 横着拿的直板（半屏只有 ~140pt 高）：当前这一句用小一档的字，不放引擎 / 耗时小字，免得被顶出半屏
        // Duo 外屏 + 大字号：半屏只有 ~300pt，也用小一档的字、不放引擎小字（否则当前这句的第一行被上沿的渐隐吃掉）
        let short = g.me.height < 220 || (isOuter && typeSize > .xLarge)
        return ZStack(alignment: .topLeading) {
            // 竖屏打字（撰写卡）：对方半屏实时显示译文预览；他的麦克风让位，预览能多占一截
            // 打字（输入条）：对方半屏实时显示译文预览，麦克风留在原位（页面不动）；
            // 被输入条盖住的那一截从这半屏的下沿让出来（只缩它的高度，不挪别的）
            let docked = typing && usesComposerCard
            let covered = docked ? min(g.them.height - 76, max(0, g.them.maxY - coveredFrom(fullHeight: size.height) + 14)) : 0          // 对方的字和输入条上沿之间留 14pt（原来 8pt，大字号下贴着）
            // 输入条开着但软键盘没有升起（接了实体键盘）：条落在屏幕底，上面一大片是空的——我这半屏和语言条照常显示，只把被条盖住的那一截让出来
            let dockAtBottom = docked && dockSettled && !KeyboardVisibility.shared.isVisible && (dockTop ?? 0) > size.height - 200          // 软键盘正在升起（已收到 willShow）不算
            let hidesMine = docked && !dockAtBottom
            let myHeight = dockAtBottom ? max(60, min(g.me.height, (dockTop ?? size.height) - 10 - g.me.minY)) : g.me.height
            // Duo 外屏的半屏只有 ~300pt 高：辅助功能超大字号下两行字 + 操作行放不下，字被上沿的渐隐吃掉半行、看起来像被语言条压住——封顶一档
            let typeCap: DynamicTypeSize = isOuter ? .xxxLarge : .accessibility5          // AX1 仍放不下（两条 + 操作行 + 引擎小字），封到 xxxLarge
            // 剩下的高度放不下「麦克风 + 两行预览」时（外屏 + 大字号）：先让麦克风让位，预览不能被输入条切掉
            let roomForMic = !docked || g.micPlacement != .bottom || g.them.height - covered >= 104 + 84
            HalfView(session: session, side: .them, showsPreview: docked, onKeyboard: openKeyboard,
                     micPlacement: g.micPlacement, showsMic: roomForMic, hintAtMic: isDuoInnerWindow && g.micPlacement == .bottom,
                     previewInset: docked ? 14 : 0,          // 空预览的提示离输入条再远一点（半开竖放时只有 ~26pt）
                     previewShift: docked ? ComposerDock.screenCenterShift(folded: hinge.activeFold != nil) : 0)
                .environment(\.compactLines, short)
                .dynamicTypeSize(...typeCap)
                .rotationEffect(.degrees(180))
                .frame(width: g.them.width, height: g.them.height - covered)
                .offset(x: g.them.minX, y: g.them.minY)

            HalfView(session: session, side: .me, onExpand: onBigDisplay, onKeyboard: openKeyboard,
                     micPlacement: g.micPlacement, showsMic: !dockAtBottom, quiet: docked, hintAtMic: isDuoInnerWindow && g.micPlacement == .bottom)
                .environment(\.compactLines, short)
                .dynamicTypeSize(...typeCap)
                .opacity(hidesMine ? 0 : 1)          // 撰写卡在前：我这半屏整块在卡片和键盘后面，只会从两者之间的缝里露出半行字——直接隐掉（原来降到 0.35 仍看得见）
                // 收起时晚 0.12s 再淡回来：等输入条先淡完，不在还没落下的条底下露出来
                // 打开时 0.12s 快速淡掉（赶在键盘加载卡住主线程之前走完，不和输入条半透明地叠在一起）
                .animation(hidesMine ? .easeOut(duration: 0.12) : .smooth(duration: 0.28).delay(0.08), value: hidesMine)          // 淡回来晚 0.08s（原来 0.12s：发送后有两帧上下都是空的）
                .frame(width: g.me.width, height: myHeight, alignment: .top)
                .frame(width: g.me.width, height: g.me.height, alignment: .top)
                .offset(x: g.me.minX, y: g.me.minY)

            stripSlot(compact: g.strip.width < 400)
                .frame(width: g.strip.width, height: g.strip.height)
                .offset(x: g.strip.minX, y: g.strip.minY)
                .zIndex(1)
                .opacity(hidesMine ? 0 : 1)          // 撰写卡盖在它上面（卡片里自带语言对）：隐掉，免得从半透明的卡片后面透出来
                .animation(hidesMine ? .easeOut(duration: 0.12) : .smooth(duration: 0.28).delay(0.08), value: hidesMine)
                .allowsHitTesting(!hidesMine)
                .accessibilityHidden(hidesMine)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }

    /// 控制条（在格子正中）。
    private func stripSlot(compact: Bool) -> some View {
        strip(compact: compact)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: 打字时：键盘占了下面一块，不再追求对称

    @ViewBuilder
    private func typingLayout(size: CGSize, full: CGSize, arrangement: FaceGeometry.Arrangement) -> some View {
        // 横着拿时键盘占掉大半个屏幕高度，上下叠放会把输入框挤没：改成左右两栏（左：给对方看的预览，右：输入）。
        // 横 / 竖按"整个屏幕"的长宽比判断，不能用被键盘压矮了的可用高度——否则键盘一弹出就从上下叠放翻成左右两栏，
        // 输入框被销毁重建、键盘闪一下。
        if arrangement == .sideBySide || full.width > full.height {
            // 条够窄、放得下时，和平时一样放在整屏正中（压在两栏分界线上）；放不下（直板横屏、iPad：带着一排按钮，约 520 宽，
            // 会盖住左半屏的麦克风）就留在右栏里。
            let short = size.height < 500
            // 键盘上方只剩 ~225pt（iPhone SE 横屏 375 高）：语言条、输入框、发送行一起收紧，发送行不被键盘切掉
            let tight = size.height < 260
            let stripSlot: CGFloat = tight ? 56 : 64
            let stripWidth: CGFloat = !verticalBars ? 520 : 340
            let centered = FaceGeometry.centersTypingStrip(width: size.width, stripWidth: stripWidth)
            ZStack(alignment: .top) {
                HStack(spacing: 0) {
                    HalfView(session: session, side: .them, showsPreview: true, onKeyboard: openKeyboard,
                             micPlacement: .bottom, showsMic: !short)          // 矮屏（键盘上方只有一百多点）：麦克风让位，高度全给文字——原来上一句被切掉半行
                        .environment(\.compactLines, short)             // 屏幕矮：预览用小一档的字，别被键盘截掉
                        .environment(\.previewLarge, !short)            // 够高：预览放大到 34，对着对方读得清
                        .dynamicTypeSize(...(short ? DynamicTypeSize.xxxLarge : DynamicTypeSize.accessibility3))          // 矮屏（外屏横放 / 直板横屏）键盘上方只有一百多点：超大字号下预览被键盘切掉一截，封顶
                        .rotationEffect(.degrees(180))
                        .frame(maxWidth: .infinity)
                    Rectangle().fill(Theme.mut.opacity(0.25)).frame(width: 1).padding(.vertical, 24)
                    // 右栏放进滚动视图：键盘占掉大半高度时，"发送"仍然够得着
                    ScrollView {
                        VStack(spacing: 0) {
                            if centered {
                                Color.clear.frame(height: stripSlot)            // 给上面的语言条让位
                            } else {
                                strip(compact: size.width / 2 < 400).frame(height: stripSlot)
                            }
                            composer(compact: short, showsPhrases: !short, tight: tight)
                        }
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    .scrollClipDisabled()
                    .dismissKeyboardInScrollArea()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
                if centered {
                    strip(compact: false)
                        .frame(height: stripSlot)
                        .frame(maxWidth: .infinity)
                }
            }
        } else {
            // 键盘弹出后可用高度只剩一半不到（Duo 外屏 678pt 的屏，键盘占掉约 300pt）。
            // 把键盘上方的可用区当一整块屏：语言条正好在它的中线，上半是对方的预览，下半是我的输入——和平时面对面的版式一致；
            // 条和输入框的位置不随预览有没有字而变（原来预览为空时整组贴顶、键盘上方空 155pt，一输入就被预览顶下去 135pt）。
            // 矮的时候输入区用紧凑版（省掉标题行、输入框矮一档），预览用小一档的字
            let short = size.height < 520
            let stripHeight: CGFloat = short ? 56 : 64
            let half = max(0, (size.height - stripHeight) / 2)
            VStack(spacing: 0) {
                HalfView(session: session, side: .them, showsPreview: true, onKeyboard: openKeyboard,
                         micPlacement: .bottom, showsMic: !short)
                    .environment(\.compactLines, short)
                    .rotationEffect(.degrees(180))
                    .frame(maxHeight: .infinity)
                stripSlot(compact: isOuter).frame(height: stripHeight)
                // 下半至少占一半（条在正中）；输入区比一半还高（大字号）时让预览让位，条上移，发送行不能被键盘盖住
                composer(compact: short, keepsClose: short)
                    .padding(.bottom, short ? 12 : 0)          // 发送行和键盘之间留一点缝，不要贴着
                    .frame(minHeight: half, alignment: .top)
            }
        }
    }

    private func composer(compact: Bool, showsPhrases: Bool = false, keepsClose: Bool = false, tight: Bool = false) -> some View {
        ComposerView(session: session, compact: compact, showsPhrases: showsPhrases, keepsClose: keepsClose, tight: tight) { closeKeyboard() }
            .transition(.opacity)
    }

    private func strip(compact: Bool) -> some View {
        stripView(compact: compact)
            .matchedGeometryEffect(id: "strip", in: stripNS, isSource: !reduceMotion)      // 减少动态效果：中间条不飞过去，只淡入淡出
    }

    private func stripView(compact: Bool) -> some View {
        ControlStrip(
            session: session,
            keyboardActive: typing,
            compact: compact,
            showsActions: !verticalBars && !isDuoInnerWindow,
            onHistory: onOpenHistory,
            onKeyboard: { toggleKeyboard() },
            onAdd: onAdd,
            onSettings: onSettings,
            onPickLanguage: {
                // 先收键盘再展示语言列表，避免内屏竖放的下屏被键盘挤成一小条。
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                showingLanguages = true
            },
            onOpenStream: onOpenStream,
            stripExtra: isOuter ? Self.defaultStripExtra : 0
        )
    }

    /// Duo 外屏：语言条再宽约 5%
    private static let defaultStripExtra: CGFloat = 9
    private var isOuter: Bool { DuoLayout.isDuoOuter(DuoLayout.currentWindowSize) }
    private var isDuoInnerWindow: Bool { DuoLayout.isDuoInner(DuoLayout.currentWindowSize) }

    private func toggleKeyboard() {
        if typing { closeKeyboard() } else { openKeyboard() }
    }

    private func closeKeyboard() {
        if usesComposerCard {
            // 竖屏：页面不动，卡片跟着键盘一起落下并淡出，同时进行（不用先后排队）
            dismissKeyboard()
            if reduceMotion { withAnimation(.easeInOut(duration: 0.15)) { typing = false } }
            else { withAnimation(.smooth(duration: 0.3)) { typing = false } }
            return
        }
        withKeyboardAnimation { typing = false }
    }

    private func openKeyboard() {
        session.prepareForTyping()
        withKeyboardAnimation { typing = true }
    }

    /// 键盘输入开合：0.3s 平滑，贴近系统键盘自己的升降节奏（动画稿第 6 项）；减少动态效果时只淡入淡出
    private func withKeyboardAnimation(_ body: () -> Void) {
        if reduceMotion { withAnimation(.easeInOut(duration: 0.15), body) }
        else { withAnimation(.smooth(duration: 0.3), body) }
    }
}

extension ConversationSession {
    /// 打开键盘输入前：收起提示；正在聆听就先结束，否则"发送"会被静默丢弃
    func prepareForTyping() {
        dismissNotice()
        if isListening { stopListening() }
    }
}

#Preview("M1 待机") {
    FaceToFaceView(session: previewSession(.m1), hinge: HingeMonitor(), typing: .constant(false))
}

#Preview("D1 帐篷", traits: .fixedLayout(width: 951, height: 669)) {
    FaceToFaceView(session: previewSession(.m3), tentMode: .on, hinge: HingeMonitor(), typing: .constant(false))
}

#Preview("M3 译文已出", traits: .fixedLayout(width: 393, height: 852)) {
    FaceToFaceView(session: previewSession(.m3), hinge: HingeMonitor(), typing: .constant(false))
}

@MainActor
private func previewSession(_ scene: ConversationSession.DemoScene) -> ConversationSession {
    let s = ConversationSession(recognizer: AppleSpeechRecognizer(), synthesizer: AppleSpeechSynthesizer(), engine: MockTranslationEngine())
    s.seed(scene)
    return s
}
