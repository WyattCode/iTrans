import SwiftUI

/// iPhone Duo 内屏的几何：中间是约 40pt 的折痕（铰链），任何文字和控件都不能跨过去。
/// - 横向（951×669）：折痕竖着，左屏 | 右屏；右屏最右边还有系统竖排栏（约 85pt，在安全区之外）。
/// - 竖向（669×951）：折痕横着，上屏 / 下屏。
/// 两种方向都是方案 B：第一块屏（左 / 上）常驻对话，第二块屏（右 / 下）放设置、历史、加入面板、键盘输入。
struct DuoLayout: Equatable {
    /// 折痕（铰链）宽度
    static let crease: CGFloat = 40
    enum Axis { case horizontal, vertical }
    let axis: Axis
    /// 第一块屏的长度：横向 = 左屏宽，竖向 = 上屏高
    let first: CGFloat
    /// 第二块屏的长度：横向 = 右屏宽，竖向 = 下屏高
    let second: CGFloat

    var leftWidth: CGFloat { first }
    var rightWidth: CGFloat { second }

    /// 窗口是 Duo 内屏时返回两块屏的尺寸；其他设备（直板、iPad、Duo 外屏）返回 nil。
    /// `content` 是页面能用的区域（不含竖排栏 / 安全区）。
    static func make(content: CGSize) -> DuoLayout? {
        let window = windowSize
        if isDuoLandscape(window) {
            let left = window.width / 2 - crease / 2
            let right = content.width - left - crease
            guard right >= 320, left >= 320 else { return nil }
            return DuoLayout(axis: .horizontal, first: left, second: right)
        }
        if isDuoPortrait(window) {
            // 折痕在窗口正中：上屏从安全区上沿算起，所以要减掉顶部安全区。
            // 键盘弹出时可用高度会变矮，只让下屏变矮（折痕位置不动），所以不因为"下屏太矮"就退回单栏。
            let top = windowSafeTop
            let first = window.height / 2 - crease / 2 - top
            let second = max(content.height - first - crease, 120)
            guard first >= 300 else { return nil }
            return DuoLayout(axis: .vertical, first: first, second: second)
        }
        return nil
    }

    /// 窗口是不是 Duo 内屏横向（951×669）
    static func isDuoLandscape(_ window: CGSize) -> Bool {
        // 高度下限：Pro Max / Plus / Air 横屏（956×440 等）宽度也在这个范围里，但只有 Duo 内屏（669）有这么高
        isPhone && window.width >= 900 && window.width <= 1000 && window.height >= 600 && window.height <= 700
    }

    /// Duo 是手机：iPad 的窗口（台前调度 / 分屏）可以被拉成和 Duo 内屏一样大，那时不能当成 Duo——
    /// 否则语言条 / 对话流的按钮会交给「竖排系统栏」，而 iPad 上没有那一列，历史 / 设置 / 加入全都没有入口
    static var isPhone: Bool { UIDevice.current.userInterfaceIdiom == .phone }

    /// 窗口是不是 Duo 内屏竖向（669×951）
    static func isDuoPortrait(_ window: CGSize) -> Bool {
        isPhone && window.height >= 900 && window.height <= 1000 && window.width >= 640 && window.width <= 700
    }

    static func isDuoInner(_ window: CGSize) -> Bool { isDuoLandscape(window) || isDuoPortrait(window) }

    /// 窗口是不是 Duo 外屏（466×678，横竖都算）：系统在外屏上一直把标签栏竖排在一侧
    static func isDuoOuter(_ window: CGSize) -> Bool {
        let (w, h) = (min(window.width, window.height), max(window.width, window.height))
        return isPhone && w >= 440 && w <= 490 && h >= 650 && h <= 700
    }

    private static var keyWindow: UIWindow? {
        UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
    }
    private static var windowSize: CGSize { keyWindow?.bounds.size ?? .zero }
    static var currentWindowSize: CGSize { windowSize }
    private static var windowSafeTop: CGFloat { keyWindow?.safeAreaInsets.top ?? 0 }
    /// 底部安全区（Home 条）：两块屏要一直铺到物理屏幕底边，列表自己在里面留出这一段
    static var windowSafeBottom: CGFloat { keyWindow?.safeAreaInsets.bottom ?? 0 }
    /// 窗口四边的安全区（Duo 外屏 / 内屏横放：右边是系统竖栏那一列）
    static var windowSafeInsets: UIEdgeInsets { keyWindow?.safeAreaInsets ?? .zero }
}

private struct InDuoPaneKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    /// 页面是不是画在 Duo 内屏的某一块屏里：两块屏共用 `DuoPanes` 画的那一张背景，页面自己不再铺背景（否则两块屏各一张，折痕两边接不上）。
    var inDuoPane: Bool {
        get { self[InDuoPaneKey.self] }
        set { self[InDuoPaneKey.self] = newValue }
    }
}

private struct PaneFrameKey: EnvironmentKey { static let defaultValue = CGRect.zero }

extension EnvironmentValues {
    /// 这块屏在窗口里的位置和大小（全局坐标）。推进屏内的页面要一张不透明的底，底色按它对齐到整屏极光上
    var paneFrame: CGRect {
        get { self[PaneFrameKey.self] }
        set { self[PaneFrameKey.self] = newValue }
    }
}

/// 页面背景：单独成页时铺极光；在 Duo 的屏里时铺「整屏极光里属于这块屏的那一块」（不透明，和 `DuoPanes` 共用的那张完全对齐，没有接缝）。
/// 屏内推进来的卡片需要它：透明的话下面那一页会透出来、和卡片重叠。
struct PageBackground: View {
    var body: some View {
        AuroraBackground()
    }
}

/// 一块屏：量出自己在窗口里的位置，放进环境给里面的页面用（见 `PageBackground`）。
struct PaneSlot<Content: View>: View {
    @ViewBuilder let content: Content
    @State private var frame = CGRect.zero
    var body: some View {
        content
            .environment(\.paneFrame, frame)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame = $0 }
    }
}

/// 语言选择：系统表单弹层（直板是半屏弹层；Duo 内屏展平是屏幕正中的表单卡片，半开时系统自己让位）
private struct LanguagePickerPresenter: ViewModifier {
    @Binding var isPresented: Bool
    let session: ConversationSession
    let packs: LanguagePackStore?
    let scheme: ColorScheme?

    func body(content: Content) -> some View {
        content.sheet(isPresented: $isPresented) {
            LanguagePickerSheet(session: session, packs: packs)
                .preferredColorScheme(scheme)
                .presentationSizing(.form)
        }
    }
}

extension View {
    func languagePicker(isPresented: Binding<Bool>, session: ConversationSession, packs: LanguagePackStore?, scheme: ColorScheme?) -> some View {
        modifier(LanguagePickerPresenter(isPresented: isPresented, session: session, packs: packs, scheme: scheme))
    }
}

/// 浮条（页头 / 搜索栏）和列表的交界：列表内容从条下面滚过时，在条的范围内整个淡出（不留毛玻璃的灰带、不和条上的标题 / 按钮叠在一起），
/// 离开条之后再渐变出现；条本身不受影响。条的高度实测，所以页头加了页签、字号变大都跟着变。
private struct FloatingBar<B: View>: ViewModifier {
    let edge: VerticalEdge
    let bar: B
    @Environment(\.inDuoPane) private var inDuoPane
    @State private var height: CGFloat = 0
    private static var ramp: CGFloat { 22 }
    /// 列表一直铺到物理屏幕底边（见 `extendsToScreenBottom` / `DuoPanes`）：底部条要抬高 Home 条的安全区，条下面这一段也要淡掉
    @State private var keyboardUp = false
    private var inset: CGFloat { (edge == .bottom && !keyboardUp) ? DuoLayout.windowSafeBottom : 0 }

    func body(content: Content) -> some View {
        // 条是盖在列表上面的（overlay），列表自己用内容边距给条让出位置：
        // 不用 safeAreaInset——它夹在 mask 外面时会把列表框挤小，而且 `ScrollPosition(edge: .top)` 会无视安全区、把第一行滚到条下面去
        content
            .contentMargins(edge == .top ? .top : .bottom, height, for: .scrollContent)
            .contentMargins(edge == .top ? .top : .bottom, height, for: .scrollIndicators)
            .mask {
                // 一整条渐变：条的范围内全透明，之后 `ramp` 长度渐变到不透明（按位置比例算）
                GeometryReader { geo in
                    let h = max(geo.size.height, 1)
                    let a = min((height + inset) / h, 1)
                    let b = min((height + inset + (height > 0.5 ? Self.ramp : 0)) / h, 1)          // 没有条（高 0）就不做渐隐，否则列表第一行会半透明
                    LinearGradient(
                        stops: edge == .top
                            ? [.init(color: .clear, location: 0), .init(color: .clear, location: a), .init(color: .black, location: b), .init(color: .black, location: 1)]
                            : [.init(color: .black, location: 0), .init(color: .black, location: 1 - b), .init(color: .clear, location: 1 - a), .init(color: .clear, location: 1)],
                        startPoint: .top, endPoint: .bottom)
                }
                // 遮罩的 GeometryReader 只占安全区以内：列表铺到屏幕底边时，底部那一段会被当成「全透明」一刀切掉
                .ignoresSafeArea(.container, edges: edge == .top ? .bottom : [])
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in keyboardUp = true }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in keyboardUp = false }
            .overlay(alignment: edge == .top ? .top : .bottom) {
                bar
                    .background { if edge == .top && inDuoPane { PageBackground() } }
                    .contentShape(Rectangle())          // 条下面被遮住的列表行不能穿透点到（透明区域原来会把点击漏给下面的行）
                    .accessibilitySortPriority(edge == .top ? 1 : 0)       // 上浮条（返回 / 标题）VoiceOver 先读，不要排在整张列表后面
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }      // overlay 本身已经让出了 safeAreaPadding，不再额外抬高
            }
    }
}

/// 卡片行的底：平时 9% 白（深色）/ 72% 白（浅色）的半透明；降低透明度时极光没了，改成更实的填充，卡片边缘才看得出来
struct CardRowBackground: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var body: some View {
        if reduceTransparency { Theme.fg.opacity(0.12) } else { Theme.glassFill }
    }
}

private struct InRailPaneKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    /// 页面画在系统竖排工具栏旁边（Duo 外屏）：和 Duo 内屏的屏一样，列表右边缘会贴着可用区域的边
    var inRailPane: Bool {
        get { self[InRailPaneKey.self] }
        set { self[InRailPaneKey.self] = newValue }
    }
}

/// Duo 屏里 / 外屏竖排栏旁的列表：右边缘原来贴着可用区域的边（系统只留了左边的页边距）。
/// 用内容边距（`contentMargins`）补右边 20pt，而不是给整个列表框 `padding`：框不缩，滚动条才在页面真正的边缘，不会压在卡片上；
/// 上下两端用系统的柔和渐隐（iOS 26+），不再一刀切。
private struct DuoListInset: ViewModifier {
    @Environment(\.inDuoPane) private var inDuoPane
    @Environment(\.inRailPane) private var inRailPane
    func body(content: Content) -> some View {
        if inDuoPane || inRailPane {
            content
                .railListMargin()
        } else {
            content
        }
    }
}

extension View {
    func duoListInset() -> some View { modifier(DuoListInset()) }

    /// 右边留 20pt：用 `safeAreaPadding`（安全区内缩）而不是给列表框 `padding`——列表自己按安全区内缩卡片，
    /// 列表框和滚动条仍在页面可用区域的真正边缘，不会压在卡片上。
    func railListMargin() -> some View {
        safeAreaPadding(.trailing, 20)
            .contentMargins(.trailing, -22, for: .scrollIndicators)      // 滚动条跟着安全区内缩了，往外挪回卡片外面
    }

    /// 浮在列表上方 / 下方的条（页头、搜索栏）：列表在它下面继续滚，交界处淡出（见 `FloatingBar`）。
    func floatingBar<B: View>(_ edge: VerticalEdge, @ViewBuilder _ bar: () -> B) -> some View {
        modifier(FloatingBar(edge: edge, bar: bar()))
    }

    /// 页面一直铺到物理屏幕底边（Duo 外屏：竖排栏旁边的页面不在 `DuoPanes` 里）：内容用 `safeAreaPadding` 让出 Home 条，
    /// 列表因此能滚到屏幕底边、底部浮条（搜索栏）离底边只留安全距离。在 Duo 内屏的屏里（`DuoPanes` 已经这样做了）不重复。
    func extendsToScreenBottom(_ enabled: Bool = true) -> some View { modifier(ExtendsToScreenBottom(enabled: enabled)) }
}

private struct ExtendsToScreenBottom: ViewModifier {
    var enabled = true
    @Environment(\.inDuoPane) private var inDuoPane
    @State private var keyboardUp = false
    func body(content: Content) -> some View {
        if inDuoPane || !enabled {
            content
        } else {
            content
                .safeAreaPadding(.bottom, keyboardUp ? 0 : DuoLayout.windowSafeBottom)       // 键盘弹出时键盘自己已经占了底部，不再叠加 Home 条
                .ignoresSafeArea(.container, edges: .bottom)
                .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in keyboardUp = true }
                .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in keyboardUp = false }
        }
    }
}

extension DuoLayout {
    /// 对话流页的内容在系统竖排栏的导航栏下面，比叠在上面的设置 / 历史 / 加入面板低这么多：
    /// 面板的两块屏也要让出同样的高度，否则打开面板时左屏的对话会往上跳一下。
    static let railTopInset: CGFloat = 24
}

extension View {
    /// 叠在对话流上面的 Duo 面板：横向时让出和对话流一样的顶部高度
    func duoOverlayInset(_ layout: DuoLayout) -> some View {
        padding(.top, layout.axis == .horizontal ? DuoLayout.railTopInset : 0)
    }
}

/// 整屏内容（同声传译、大字展示）：iPhone Duo 内屏上只放进第二块屏，折痕留空，文字不会跨过去；其他设备原样铺满。
struct DuoContained<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        GeometryReader { geo in
            if let duo = DuoLayout.make(content: geo.size) {
                DuoPanes(layout: duo, taskOnTop: true) { Color.clear } right: { content }
            } else {
                content
            }
        }
    }
}

/// 两块屏：中间的折痕留空。两块屏共用一张极光背景（和单屏的对话一样，不是各铺各的）。
struct DuoPanes<Left: View, Right: View>: View {
    let layout: DuoLayout
    /// 竖放任务页：右侧导航栈放在上屏，原页面保留在下屏，旋转时导航栈身份不变。
    var taskOnTop = false
    var drawsBackground = true
    @ViewBuilder var left: Left
    @ViewBuilder var right: Right

    @State private var keyboardUp = false

    var body: some View {
        // clipped：屏内的推入转场（设置子页、历史详情）不会越过折痕画到另一块屏上
        // 两块屏铺到物理屏幕底边（原来在底部安全区上沿硬切断，列表最后一行下面留一条 34pt 的空带，一屏比另一屏短一截）；
        // 各自用 safeAreaPadding 把内容让出 Home 条，所以内容位置不变，只是列表能滚到屏幕底边
        panes
            .environment(\.inDuoPane, true)
            .ignoresSafeArea(.container, edges: .bottom)
            .background { if drawsBackground { AuroraBackground().ignoresSafeArea() } }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in keyboardUp = true }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in keyboardUp = false }
    }

    private var panes: some View {
        let bottom = keyboardUp ? 0 : DuoLayout.windowSafeBottom
        // 旋转只改变布局，两个 PaneSlot 的身份保持不变。HStack / VStack 分支会拆掉导航栈和 OCR 状态。
        let swapped = taskOnTop && layout.axis == .vertical
        return DuoPaneLayout(layout: layout, bottom: bottom, swapped: swapped) {
            PaneSlot { left.safeAreaPadding(.bottom, layout.axis == .horizontal || swapped ? bottom : 0) }.clipped()
            PaneSlot { right.safeAreaPadding(.bottom, swapped ? 0 : bottom) }.clipped()
        }
    }
}

private struct DuoPaneLayout: Layout {
    let layout: DuoLayout
    let bottom: CGFloat
    var swapped = false

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        let horizontal = layout.axis == .horizontal
        let first = CGSize(width: horizontal ? layout.first : bounds.width,
                           height: horizontal ? bounds.height : layout.first)
        let second = CGSize(width: horizontal ? layout.second : bounds.width,
                            height: horizontal ? bounds.height : layout.second + bottom)
        subviews[swapped ? 1 : 0].place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(first))
        subviews[swapped ? 0 : 1].place(at: CGPoint(x: bounds.minX + (horizontal ? layout.first + DuoLayout.crease : 0),
                                     y: bounds.minY + (horizontal ? 0 : layout.first + DuoLayout.crease)),
                          anchor: .topLeading, proposal: ProposedViewSize(second))
    }
}

/// 左屏的对话：设置 / 历史 / 键盘输入时左屏保持显示正在进行的对话。
struct ConversationPane: View {
    let session: ConversationSession
    var isOnline = true
    var showsInput = true
    var showsPreview = false
    var dimmed = false

    var body: some View {
        StreamView(
            session: session,
            isOnline: isOnline,
            onBack: {},
            onOpenHistory: {},
            showsAddButton: false,
            toolbarHandledByParent: true,
            barsOnSide: true,
            wideHeader: true,
            showsInputBar: showsInput,
            showsHeaderMenu: false,
            showsPreview: showsPreview
        )
        .ignoresSafeArea(.keyboard, edges: .bottom)       // 右屏（历史搜索 / 打字）弹键盘时，压暗的左屏不跟着重排（输入栏会跳到对话气泡上面）
        .opacity(dimmed ? 0.55 : 1)
        .allowsHitTesting(!dimmed)
        .accessibilityHidden(dimmed)       // 压暗的那块屏不让 VoiceOver 读到 / 点到
    }
}

extension View {
    /// 长按弹出的菜单：系统上下文菜单（Duo 的系统菜单半开时会自己让位）
    func paneContextMenu<Actions: View>(_ title: LocalizedStringKey, isPresented: Binding<Bool>, @ViewBuilder actions: () -> Actions) -> some View {
        contextMenu { actions() }
    }
}
