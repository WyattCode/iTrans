import SwiftUI

/// D3 · 宽屏（Duo 展开 / iPad）：左边是对话，右边是工具面板（图片、粘贴、短语、同声传译、大字展示）。
/// 在右边做的事，结果立刻出现在左边的对话里，不会盖住对话。
struct WideConversationView: View {
    let session: ConversationSession
    let isOnline: Bool
    let onBack: () -> Void
    let onOpenHistory: () -> Void
    let onBigDisplay: (BigDisplayRequest) -> Void
    let onToolExit: (AddPanelView.Exit) -> Void
    /// Duo 内屏：第二块屏是「说话区」，加入面板从它的按钮进入
    var packs: LanguagePackStore?
    var onAdd: () -> Void = {}
    /// 说话区的「键盘输入」：回到面对面并打开键盘输入
    var onKeyboard: () -> Void = {}
    var onSettings: () -> Void = {}
    /// 键盘输入（Duo 内屏）：输入条贴在键盘上沿、叠在对话流上（和面对面页同一条 `ComposerDock`）
    @Binding var typing: Bool
    var colorScheme: ColorScheme?
    @State private var dockTop: CGFloat?
    @State private var showingLanguages = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 正在起作用的折叠区域（半开）；展平 = nil：内屏是一整块连续画布，对话和说话区之间没有 40pt 折痕空隙
    @Environment(\.activeFold) private var activeFold
    /// 说话坞的实际高度：对话列表底部按它让位
    @State private var dockHeight: CGFloat = 130
    @State private var renameRequest = 0
    @State private var keyboardUp = false
    /// 一行说话区的实际高度（含底部让开标签栏的部分）：竖放展平时对话和输入栏按它让位
    @State private var rowHeight: CGFloat = 194          // 初值贴近实测（~194pt），第一帧对话列表不会因为量到真实高度再跳一下

    /// Duo 内屏横放展平：整屏对话 + 底部正中的说话坞（历史在坞里，竖栏里不再放第二个历史按钮）
    private var usesDock: Bool {
        packs != nil && activeFold == nil && DuoLayout.isDuoLandscape(DuoLayout.currentWindowSize)
    }

    /// Duo 内屏横放：系统把工具栏竖排在右侧——加入 / 更多（历史、键盘输入、设置、重命名）/ 分享都在那一列，页面里不再放这些按钮
    private var actionsInRail: Bool {
        packs != nil && DuoLayout.isDuoLandscape(DuoLayout.currentWindowSize)
    }

    /// Duo 内屏竖放（设计稿 A）：页头放「＋」「⋯」，说话区只有一行麦克风 + 语言条，不再有按钮行和分隔线
    private var rowLayout: Bool {
        packs != nil && DuoLayout.isDuoInner(DuoLayout.currentWindowSize) && !actionsInRail
    }

    @ViewBuilder
    private func speakConsole(bottomInset: CGFloat, inline: Bool, dock: Bool = false, inRail: Bool = false,
                              row: Bool = false, rowBackground: Bool = false) -> some View {
        if let packs {
            SpeakConsole(session: session, packs: packs,
                         onAdd: onAdd, onHistory: onOpenHistory, onKeyboard: onKeyboard, onSettings: onSettings,
                         bottomInset: bottomInset, inlineActions: inline, dock: dock, actionsInRail: inRail,
                         row: row, rowBackground: rowBackground)
                // 输入条开着：说话区让位（和面对面页隐掉我这半屏同一个节奏）。平时它在键盘后面；
                // 键盘升起前的那半秒、以及接了实体键盘（输入条落在屏幕底）时，不隐掉就会和输入条叠在一起
                .opacity(docked ? 0 : 1)
                .allowsHitTesting(!docked)
                .accessibilityHidden(docked)
                .animation(docked ? .easeOut(duration: 0.12) : .smooth(duration: 0.28).delay(0.08), value: docked)
        } else {
            AddPanelView(session: session, embedded: true, onExit: onToolExit)
        }
    }

    var body: some View {
        // 系统工具栏放在整屏层：Duo 内屏横向时返回 / 历史 / 分享竖排在最右侧那一列，
        // 左边对话和右边工具面板共用，不再各自占一行顶栏。
        SideBarHost(pushOwner: .stream) { vertical in
          ZStack(alignment: .bottom) {
            GeometryReader { geo in
                if let duo = DuoLayout.make(content: geo.size) {
                    // iPhone Duo 内屏。**对话和说话区始终是同一个容器里的同两个子视图**，半开 / 展平横放 / 展平竖放只改它们的位置和参数：
                    // 原来是三个 if 分支，铰链一动（或转屏）两个视图就被拆掉重建——开着的语言选择、输到一半的重命名、
                    // 正按着的麦克风、列表滚动位置全丢
                    let half = activeFold != nil
                    let landscape = geo.size.width > geo.size.height
                    let mode: DuoConversationLayout.Mode = half ? .panes(duo) : (landscape ? .dock : (rowLayout ? .row : .stacked))
                    let safeBottom = keyboardUp ? 0 : DuoLayout.windowSafeBottom
                    let vertical2 = duo.axis == .vertical
                    DuoConversationLayout(mode: mode, bottom: half ? safeBottom : 0) {
                        PaneSlot {
                            stream(vertical: vertical, dock: mode == .dock, reserve: mode == .row ? rowHeight : 0)
                                .safeAreaPadding(.bottom, half && !vertical2 ? safeBottom : 0)
                        }
                        // 半开时不越过折痕画到另一块屏上；展平时不裁（说话坞的阴影要露出来）
                        .clipShape(Rectangle().inset(by: half ? 0 : -4000))
                        PaneSlot {
                            speakConsole(bottomInset: half ? (vertical2 ? 72 + DuoLayout.windowSafeBottom : 0)
                                                           : (mode == .dock ? 0 : (mode == .row ? 20 : 72) + DuoLayout.windowSafeBottom),
                                         inline: half ? vertical2 : mode != .dock,
                                         dock: mode == .dock,
                                         inRail: half ? !vertical2 : mode == .dock,
                                         row: half ? (rowLayout && vertical2) : mode == .row,
                                         rowBackground: half)
                                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                                    if mode == .dock { dockHeight = height } else if mode == .row { rowHeight = height }
                                }
                                .overlay(alignment: .top) { if mode == .stacked { Divider() } }
                                .safeAreaPadding(.bottom, half ? safeBottom : 0)
                        }
                        .clipShape(Rectangle().inset(by: half ? 0 : -4000))
                    }
                    .environment(\.inDuoPane, half)
                    .ignoresSafeArea(.container, edges: half ? .bottom : [])
                    .background { if half { AuroraBackground().ignoresSafeArea() } }
                    .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in keyboardUp = true }
                    .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in keyboardUp = false }
                } else {
                    HStack(spacing: 0) {
                        stream(vertical: vertical)
                            .frame(width: geo.size.width * LayoutClass.conversationFraction)

                        Divider()

                        AddPanelView(session: session, embedded: true, onExit: onToolExit)
                    }
                }
            }
            // 键盘起来时对话和说话坞不跟着上移（页面不动）；输入条在外面这层 ZStack 里，跟着键盘安全区走
            .ignoresSafeArea(.keyboard)
            if docked, let packs {
                ComposerDock(session: session,
                             onPickLanguage: { showingLanguages = true },
                             onClose: closeTyping,
                             keepsOpen: showingLanguages,
                             onTopChange: { dockTop = $0 })
                    .opacity(showingLanguages ? 0 : 1)
                    .animation(.easeOut(duration: 0.12), value: showingLanguages)
                    .transition(.asymmetric(insertion: .opacity.animation(.easeOut(duration: 0.12)),
                                            removal: .opacity.animation(.easeOut(duration: 0.14))))
                    .zIndex(1)
                    .languagePicker(isPresented: $showingLanguages, session: session, packs: packs, scheme: colorScheme)
            }
          }
          .onChange(of: typing) { _, now in if !now { dockTop = nil } }
        } items: {
            StreamToolbar(session: session, onBack: onBack, onOpenHistory: onOpenHistory,
                          onAdd: actionsInRail ? onAdd : nil,
                          menu: actionsInRail ? .init(onKeyboard: onKeyboard, onSettings: onSettings, onRename: { renameRequest += 1 }) : nil)
        }
    }

    /// 输入条开着（只在 Duo 内屏：其他宽屏的键盘输入在面对面页里）
    private var docked: Bool { typing && packs != nil && DuoLayout.isDuoInner(DuoLayout.currentWindowSize) }

    private func closeTyping() {
        dismissKeyboard()
        withAnimation(reduceMotion ? .easeInOut(duration: 0.15) : .smooth(duration: 0.3)) { typing = false }
    }

    private func stream(vertical: Bool, dock: Bool = false, reserve: CGFloat = 0) -> some View {
        StreamView(
            session: session,
            isOnline: isOnline,
            onBack: onBack,
            onOpenHistory: onOpenHistory,
            onAdd: onAdd,
            onBigDisplay: onBigDisplay,
            onKeyboard: DuoLayout.isDuoInner(DuoLayout.currentWindowSize) ? onKeyboard : nil,
            showsAddButton: false,         // 工具面板就在旁边，不需要＋
            toolbarHandledByParent: true,
            barsOnSide: vertical,
            wideHeader: true,
            showsInputBar: !dock,          // 说话坞版式里输入只有「键盘输入」一个入口
            showsHeaderMenu: !actionsInRail,          // 重命名 / 分享在竖栏的菜单里
            headerActions: rowLayout,
            bottomReserve: reserve,
            showsPreview: docked,          // 还没发送的那句显示在对话末尾（虚线气泡）
            coverTop: docked ? dockTop : nil,
            renameRequest: renameRequest,
            bottomInset: dock ? dockHeight + 26 : 0,
            onSettings: rowLayout ? onSettings : nil
        )
        .ignoresSafeArea(.keyboard)
    }
}


/// Duo 内屏对话流页的版面：两个子视图（[0] 对话、[1] 说话区）始终都在，只按形态摆位置——身份不变，状态不丢。
/// - `panes`：半开，对话和说话区各占折痕一侧（和 `DuoPanes` 同一套尺寸）
/// - `dock`：展平横放，对话铺满，说话坞浮在底部正中（离底 18pt）
/// - `row`：展平竖放，对话铺满，一行说话区贴在最下面
/// - `stacked`：展平竖放（旧版式），说话区按自己的高度在下，对话占其余
struct DuoConversationLayout: Layout {
    enum Mode: Equatable { case panes(DuoLayout), dock, row, stacked }
    let mode: Mode
    /// 半开时两块屏铺到物理屏幕底边：下屏多出来的这一段（Home 条的安全区）
    var bottom: CGFloat = 0

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        let stream = subviews[0], console = subviews[1]
        switch mode {
        case .panes(let layout):
            let horizontal = layout.axis == .horizontal
            let first = CGSize(width: horizontal ? layout.first : bounds.width, height: horizontal ? bounds.height : layout.first)
            let second = CGSize(width: horizontal ? layout.second : bounds.width, height: horizontal ? bounds.height : layout.second + bottom)
            stream.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(first))
            console.place(at: CGPoint(x: bounds.minX + (horizontal ? layout.first + DuoLayout.crease : 0),
                                      y: bounds.minY + (horizontal ? 0 : layout.first + DuoLayout.crease)),
                          anchor: .topLeading, proposal: ProposedViewSize(second))
        case .dock:
            stream.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(bounds.size))
            let size = console.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
            console.place(at: CGPoint(x: bounds.midX, y: bounds.maxY - 18), anchor: .bottom,
                          proposal: ProposedViewSize(width: min(size.width, bounds.width), height: size.height))
        case .row:
            stream.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(bounds.size))
            let size = console.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
            console.place(at: CGPoint(x: bounds.minX, y: bounds.maxY), anchor: .bottomLeading,
                          proposal: ProposedViewSize(width: bounds.width, height: size.height))
        case .stacked:
            let size = console.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
            let consoleHeight = min(size.height, bounds.height * 0.6)
            stream.place(at: bounds.origin, anchor: .topLeading,
                         proposal: ProposedViewSize(width: bounds.width, height: max(0, bounds.height - consoleHeight)))
            console.place(at: CGPoint(x: bounds.minX, y: bounds.maxY), anchor: .bottomLeading,
                          proposal: ProposedViewSize(width: bounds.width, height: consoleHeight))
        }
    }
}
