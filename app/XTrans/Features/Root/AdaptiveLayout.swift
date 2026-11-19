import CoreGraphics
import SwiftUI

/// 按屏幕尺寸（而不是机型、也不是方向）选择布局，所以直板 iPhone（竖 / 横）、iPhone Duo 外屏 /
/// 内屏（竖 / 横）、iPad 都走同一套逻辑——这也是 Apple 对 iPhone Duo 的要求：用尺寸类别适配，
/// 不要按机型或方向写死。
///
/// 设备实测（iOS 27.1 模拟器，`devicectl`）：
/// - 直板 iPhone：竖 402×874，横 874×402（Pro Max 约 440×956）
/// - Duo 外屏：466×678（紧凑宽度；右侧是系统保留的摄像头 / 状态区）
/// - Duo 内屏：669×951 竖、951×669 横（展开后**默认是横向**；规则尺寸类别）
enum LayoutClass: Equatable {
    /// 单栏：直板 iPhone（竖 / 横）、Duo 外屏
    case compact
    /// 双栏：Duo 内屏（竖 / 横）、iPad。左边对话，右边工具面板
    case wide

    /// 宽、高都够大才用双栏：横过来的直板 iPhone（874×402）虽然很宽，但太矮，放不下工具面板。
    static let wideMinWidth: CGFloat = 600
    static let wideMinHeight: CGFloat = 500

    static func forSize(_ size: CGSize) -> LayoutClass {
        size.width >= wideMinWidth && size.height >= wideMinHeight ? .wide : .compact
    }

    /// 按「整个窗口」判断，不随键盘变化。键盘一弹出，视图读到的可用高度会被压矮：Duo 横放（669）压到 500 以下就会被
    /// 误判成窄屏，页面换成单栏、正在输入的输入框被销毁、键盘落下。
    @MainActor
    static func forWindow(fallback: CGSize = .zero) -> LayoutClass {
        let window = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
        let size = window?.bounds.size ?? .zero
        return forSize(size.width > 0 ? size : fallback)
    }

    /// 双栏时左栏（对话）占的比例；右栏（工具面板）要放得下 2~3 列磁贴，所以不能太窄。
    static let conversationFraction: CGFloat = 0.55
}

extension View {
    /// 宽屏 / 横屏上别让文字行拉得太长：内容限制在一个舒服的宽度里，居中。
    func readableWidth(_ maxWidth: CGFloat = 720) -> some View {
        frame(maxWidth: maxWidth).frame(maxWidth: .infinity)
    }
}

// MARK: - iPhone Duo：系统竖排工具栏

/// 系统是否把工具栏 / 标签栏竖着排在屏幕右侧（iPhone Duo 外屏、内屏横向时）。
/// 直板 iPhone 和 Duo 内屏竖向时是 nil（横排）。iOS 27.1 之前没有这个概念，永远是 false。
/// 根视图用的"系统是否竖排工具栏"：读取发生在各页的导航栈里（根视图那一层读不到），页面通过这个回调告诉根视图。
private struct BarsVerticalReportKey: EnvironmentKey {
    static let defaultValue: ((Bool) -> Void)? = nil
}

extension EnvironmentValues {
    var reportBarsVertical: ((Bool) -> Void)? {
        get { self[BarsVerticalReportKey.self] }
        set { self[BarsVerticalReportKey.self] = newValue }
    }
}

private struct VerticalBarsReader: ViewModifier {
    @Binding var isVertical: Bool
    /// false = 栏被收起（打字时），此时读到的"没有竖排"不可信，沿用上一次的值
    var enabled = true

    func body(content: Content) -> some View {
        if #available(iOS 27.1, *) {
            content.modifier(Inner(isVertical: $isVertical, enabled: enabled))
        } else {
            content
        }
    }

    @available(iOS 27.1, *)
    private struct Inner: ViewModifier {
        @Binding var isVertical: Bool
        let enabled: Bool
        @Environment(\.toolbarVerticalEdge) private var edge
        @Environment(\.reportBarsVertical) private var report

        func body(content: Content) -> some View {
            content.onChange(of: edge, initial: true) { _, new in
                if enabled {
                    isVertical = (new != nil)
                    report?(new != nil)
                }
            }
        }
    }
}

extension View {
    /// 把"系统是否在右侧竖排工具栏"同步到 `isVertical`。
    func readsVerticalBars(_ isVertical: Binding<Bool>, enabled: Bool = true) -> some View {
        modifier(VerticalBarsReader(isVertical: isVertical, enabled: enabled))
    }
}

/// 给整屏接上系统工具栏（Duo 外屏 / 内屏横向时系统把它竖排在右侧）。
/// - 系统竖排时：`items` 里的按钮出现在右侧那一列，`content` 收到 `true`，自己去掉重复的按钮。
/// - 其他情况（直板 iPhone、Duo 内屏竖向）：导航栏整个隐藏，`content` 收到 `false`，保持原来的设计。
struct SideBarHost<Content: View, Items: ToolbarContent>: View {
    /// 初值：Duo 外屏上标签栏一定是竖排的，第一帧就按竖排排，不要先排一遍「带底部按钮」的版本再重排（淡入过程中元素会动）
    @State private var isVertical = DuoLayout.isDuoOuter(DuoLayout.currentWindowSize) || DuoLayout.isDuoLandscape(DuoLayout.currentWindowSize)
    private let content: (Bool) -> Content
    private let items: () -> Items
    /// 这是哪个标签页：设置 / 历史的原生推入挂在它的导航栈里（nil = 不是标签页，不推）
    private let pushOwner: RootView.Screen?

    init(pushOwner: RootView.Screen? = nil,
         @ViewBuilder content: @escaping (Bool) -> Content,
         @ToolbarContentBuilder items: @escaping () -> Items) {
        self.pushOwner = pushOwner
        self.content = content
        self.items = items
    }

    @Environment(\.pushedPages) private var pushedPages

    var body: some View {
        NavigationStack {
            content(isVertical)
                .toolbar { items() }
                .toolbarTitleDisplayMode(.inline)
                .toolbarVisibility(isVertical ? .automatic : .hidden, for: .navigationBar)
                .readsVerticalBars($isVertical)
                .modifier(OptionalPushedPages(owner: pushOwner))
        }
        .environment(\.inRailPane, (pushOwner != nil && isVertical) || (pushedPages?.rail ?? false) && pushOwner != nil)
    }
}

private struct OptionalPushedPages: ViewModifier {
    let owner: RootView.Screen?
    func body(content: Content) -> some View {
        if let owner { content.pushedPages(owner: owner) } else { content }
    }
}

/// 弹层里的"完成"：图标 + 标题。Apple 规定只有标题没有图标的按钮不会进 Duo 的竖排工具栏，
/// 所以外屏上它会横着挤在标题旁边；带图标就能排在竖排那一列的最上面（pinned trailing）。
/// 横排时系统只显示图标（对勾），和 iOS 26 起的标准确认按钮一致。
struct DoneToolbarItem: ToolbarContent {
    let action: () -> Void

    var body: some ToolbarContent {
        if #available(iOS 27.1, *) {
            ToolbarItem(placement: .topBarPinnedTrailing) {
                // 只显示 ✓：iPad 的宽导航栏里系统会把标题也画出来（「✓ 完成」），和其他弹层 / 其他设备上的 ✓ 不一致
                Button(action: action) { BarLabel("完成", symbol: "checkmark").labelStyle(.iconOnly) }
            }
        } else {
            ToolbarItem(placement: .confirmationAction) {
                // 旧系统上也用 ✓ 图标（原来是文字「完成」，和键盘输入卡片、新系统上的 ✓ 不一致）
                Button(action: action) { Image(systemName: "checkmark") }
                    .accessibilityLabel("完成")
            }
        }
    }
}

/// 整页推入（直板机的设置、历史）左上角的返回：只有一个箭头，不写字（读屏仍念「返回对话」）。
struct BackToolbarItem: ToolbarContent {
    let action: () -> Void

    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button(action: action) {
                Image(systemName: "chevron.left").font(.system(.body).weight(.semibold))
            }
            .accessibilityLabel("返回对话")
        }
    }
}

/// 整屏面板（设置、历史）右上角的"完成"：图标 + 文字。只有一个对勾，在长页面里要想一下才知道是关闭。
struct PanelDoneButton: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            // 只有 ✓ 的玻璃圆钮（原来是「✓ 完成」胶囊）：和系统弹层右上角的 ✓、键盘输入卡片的 ✓ 同一种
            Image(systemName: "checkmark")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.fg)
                .frame(width: 44, height: 44)
                .glass(in: Circle(), interactive: true)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("完成")
    }
}

/// 返回钮：玻璃圆钮里一个箭头，不写字。
struct PanelBackButton: View {
    var label: LocalizedStringKey = "返回对话"
    /// 箭头大小：直板机页内页头用 22 / medium，和系统导航栏的返回键（二级页用的就是系统的）同样大
    var chevronSize: CGFloat = 17
    var chevronWeight: Font.Weight = .semibold
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.left")
                .font(.system(size: chevronSize, weight: chevronWeight))
                .foregroundStyle(Theme.fg)
                .frame(width: 44, height: 44)
                .glass(in: Circle(), interactive: true)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// 直板机整页推入的页面（设置、历史）共用的页头：返回圆钮在左、标题居中、右边可放一个动作。画在页面里（不用系统导航栏），
/// 右划返回时它和页面是**刚性的一个整体**——系统导航栏的返回键有视差动画（比页面内容多走一点），用户在 iPhone Air 上看到的「返回按钮位移」就是它。
struct PhonePageHeader<Trailing: View>: View {
    let title: LocalizedStringKey
    let onBack: () -> Void
    @ViewBuilder var trailing: Trailing

    var body: some View {
        ZStack {
            Text(title)
                .font(.headline)
                .foregroundStyle(Theme.fg)
                .lineLimit(1)
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)          // 和系统导航栏一样封顶：辅助功能字号下标题不撑出 44pt 的页头
                .padding(.horizontal, 56)                              // 不压到两边的圆钮
                .accessibilityAddTraits(.isHeader)
            HStack(spacing: 12) {
                PanelBackButton(label: "返回", chevronSize: 22, chevronWeight: .medium, action: onBack)
                Spacer(minLength: 0)
                trailing
            }
        }
        .padding(.horizontal, 20)
        // 和系统导航栏同一条线（44pt 高、紧贴状态栏下沿）：设置里再推进二级页（朗读声音等，用的是系统栏）时，
        // 返回键和标题不会上下跳 10pt；下面留 10pt 再接内容
        .frame(height: 44)
        .padding(.bottom, 10)
    }
}

extension PhonePageHeader where Trailing == EmptyView {
    init(title: LocalizedStringKey, onBack: @escaping () -> Void) {
        self.init(title: title, onBack: onBack) { EmptyView() }
    }
}

/// Duo 内屏某一块屏里的页头：左边返回（只有箭头）、标题、右边可放一个动作。高 64，和宽屏页头同一条线。
/// 系统导航栏在 Duo 的竖排栏里会把工具栏按钮收进右侧那一列（甚至看不见），所以屏内的页面自己画页头、隐藏系统栏。
struct PaneHeader<Trailing: View>: View {
    let title: LocalizedStringKey
    var backLabel: LocalizedStringKey = "返回对话"
    let onBack: () -> Void
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            PanelBackButton(label: backLabel, action: onBack)
            Text(title)
                .font(.headline)
                .foregroundStyle(Theme.fg)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            trailing
        }
        .padding(.horizontal, 20)
        .frame(height: 64)
    }
}

extension PaneHeader where Trailing == EmptyView {
    init(title: LocalizedStringKey, backLabel: LocalizedStringKey = "返回对话", onBack: @escaping () -> Void) {
        self.init(title: title, backLabel: backLabel, onBack: onBack) { EmptyView() }
    }
}

/// 读一下"是不是画在 Duo 的屏里"再决定页面怎么排（环境值要在屏里面才读得到，页面本身在 `DuoPanes` 外面）。
struct PaneAware<Content: View>: View {
    @Environment(\.inDuoPane) private var inDuoPane
    @ViewBuilder let content: (Bool) -> Content
    var body: some View { content(inDuoPane) }
}

/// Duo 屏里从列表推进去的二级页：自己的页头（返回 = 回上一级），隐藏系统栏。
struct PaneDetailPage<Content: View>: View {
    let title: LocalizedStringKey
    var backLabel: LocalizedStringKey = "返回"
    /// 页头右边的动作（例：短语页的「添加」）
    var trailing: AnyView?
    @ViewBuilder var content: Content
    @Environment(\.dismiss) private var dismiss
    @Environment(\.inRailPane) private var inRailPaneEnv
    @Environment(\.inDuoPane) private var inDuoPane
    private var inRailPane: Bool { inRailPaneEnv && !inDuoPane }      // Duo 内屏的屏里系统栏是隐藏的，页头自己画

    var body: some View {
        if inRailPane {
            // Duo 外屏：返回 / 标题交给系统的竖排栏（和面对面、对话流、设置主页同一列），页面里不再自己画页头
            content
                .background { PageBackground() }
                .navigationTitle(title)
                .toolbarTitleDisplayMode(.inline)
                .containerBackground(.clear, for: .navigation)
        } else {
            paneBody
        }
    }

    private var paneBody: some View {
        // 页头浮在内容上面（和设置 / 历史主页一致）：内容从页头下面滚过时渐隐，不再一刀切
        content
            .floatingBar(.top) { PaneHeader(title: title, backLabel: backLabel, onBack: { dismiss() }) { if let trailing { trailing } } }
        .background { PageBackground() }
        .toolbarVisibility(.hidden, for: .navigationBar)
        .containerBackground(.clear, for: .navigation)
        .simultaneousGesture(
            DragGesture(minimumDistance: 16).onEnded { value in
                guard inDuoPane, value.startLocation.x < 24, value.translation.width > 60,
                      abs(value.translation.width) > abs(value.translation.height) else { return }
                dismiss()
            }
        )
        .accessibilityAction(.escape) { dismiss() }
    }
}

/// 宽屏设置的页头：高 64、标题居中、右边"完成"；二级页面（从列表推进去的）左边多一个返回。
/// 系统栏在这些页面里是隐藏的（Duo 竖排模式下嵌套的标题会跑到屏幕左上角），所以自己画。
struct WideHeader: View {
    let title: LocalizedStringKey
    var onBack: (() -> Void)?
    let onDone: () -> Void
    @Environment(\.inDuoPane) private var inDuoPane

    var body: some View {
        if inDuoPane {
            // Duo 的屏里：左边只有返回（二级页回上一级，一级页关掉设置），没有「完成」
            PaneHeader(title: title, backLabel: onBack == nil ? "返回对话" : "返回", onBack: onBack ?? onDone)
        } else {
            wideHeader
        }
    }

    private var wideHeader: some View {
        ZStack {
            Text(title)
                .font(.headline)
                .foregroundStyle(Theme.fg)
                .accessibilityAddTraits(.isHeader)
            HStack {
                if let onBack {
                    Button(action: onBack) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(Theme.fg)
                            .frame(width: 44, height: 44)
                            .glass(in: Circle(), interactive: true)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("返回")
                }
                Spacer()
                PanelDoneButton(action: onDone)
            }
            .padding(.horizontal, 20)
        }
        .frame(height: 64)
    }
}

/// 宽屏设置里从列表推进去的二级页面：同一个页头、同一个最大宽度（560），和一级页面对得上。
struct WideDetailPage<Content: View>: View {
    let title: LocalizedStringKey
    let onDone: () -> Void
    @ViewBuilder var content: Content
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            WideHeader(title: title, onBack: { dismiss() }, onDone: onDone)
            content
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
        }
        .background { PageBackground().ignoresSafeArea() }
        .toolbarVisibility(.hidden, for: .navigationBar)
        .containerBackground(.clear, for: .navigation)
    }
}

// MARK: - 次级页面

/// 常驻的淡入页（Duo 内屏的设置 / 历史）：视图一直活着，开合不再建 / 拆；关着时完全透明、不可点、不进无障碍树。
struct KeptLayer: ViewModifier {
    let open: Bool
    func body(content: Content) -> some View {
        content
            .opacity(open ? 1 : 0)
            .allowsHitTesting(open)
            .accessibilityHidden(!open)
    }
}

/// 设置 / 历史在当前标签页的导航栈里原生推入所需的一切（由根视图放进环境；没有就不推）。
struct PushedPages {
    var activeScreen: RootView.Screen
    var settings: Binding<Bool>
    var history: Binding<Bool>
    var settingsPage: () -> AnyView
    var historyPage: () -> AnyView
    var hidesBar: Bool
    /// 系统竖排栏（Duo 外屏）：推进去的页面和它里面再推的二级页都要知道（目的页的环境来自导航栈，不来自链接所在的位置）
    var rail: Bool
    var settingsSwipeBack: Bool
    var historySwipeBack: Bool
}

private struct PushedPagesKey: EnvironmentKey { static let defaultValue: PushedPages? = nil }

extension EnvironmentValues {
    var pushedPages: PushedPages? {
        get { self[PushedPagesKey.self] }
        set { self[PushedPagesKey.self] = newValue }
    }
}

/// 在某个标签页自己的导航栈里挂上「设置 / 历史」两个原生推入的目的页（只有它是当前标签页时才推）。
private struct PushedPagesModifier: ViewModifier {
    let owner: RootView.Screen
    @Environment(\.pushedPages) private var pushed

    func body(content: Content) -> some View {
        if let pushed {
            let isActive = pushed.activeScreen == owner
            content
                .navigationDestination(isPresented: Binding(
                    get: { isActive && pushed.settings.wrappedValue },
                    set: { pushed.settings.wrappedValue = $0 })) {
                    pushed.settingsPage()
                        .nativePushPage(hidesBar: pushed.hidesBar, swipeBack: pushed.settingsSwipeBack)
                }
                .navigationDestination(isPresented: Binding(
                    get: { isActive && pushed.history.wrappedValue },
                    set: { pushed.history.wrappedValue = $0 })) {
                    pushed.historyPage()
                        .nativePushPage(hidesBar: pushed.hidesBar, swipeBack: pushed.historySwipeBack)
                }
        } else {
            content
        }
    }
}

extension View {
    func pushedPages(owner: RootView.Screen) -> some View { modifier(PushedPagesModifier(owner: owner)) }
}

/// 系统导航栈推进来的整页（设置 / 历史）：隐藏系统导航栏和返回键（页面自己画页头），但保留左缘右滑返回（跟手的系统手势）。
/// `swipeBack`：页面里还推进了二级页（朗读声音等）时关掉外层的手势，让里面那层栈的右划去返回上一级。
extension View {
    /// `hidesBar`：页面自己画页头（Duo 外屏的竖排栏）时隐藏系统导航栏；否则用系统栏（标题 + 原生返回键）
    func nativePushPage(hidesBar: Bool, swipeBack: Bool) -> some View {
        self
            .toolbarVisibility(hidesBar ? .hidden : .automatic, for: .navigationBar)
            .toolbarVisibility(.hidden, for: .tabBar)          // 推进去的整页盖住标签栏（和原生设置一样）
            .background { PopGestureEnabler(enabled: swipeBack) }
    }
}

/// 隐藏导航栏后系统会关掉左缘右滑返回；这里把它重新打开（只在栈里不止一页时才开始）。
struct PopGestureEnabler: UIViewControllerRepresentable {
    let enabled: Bool

    func makeUIViewController(context: Context) -> Controller { Controller() }
    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.enabled = enabled
        controller.apply()
    }
    static func dismantleUIViewController(_ controller: Controller, coordinator: ()) { controller.restore() }

    final class Controller: UIViewController, UIGestureRecognizerDelegate {
        var enabled = true
        private var active = false
        private weak var popGesture: UIGestureRecognizer?
        private weak var originalDelegate: UIGestureRecognizerDelegate?
        private var originalEnabled = true
        private weak var contentGesture: UIGestureRecognizer?
        private var originalContentEnabled = true

        override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); active = true; apply() }
        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            active = false
            restore()
        }
        func apply() {
            guard active, let nav = navigationController else { return }
            if let pop = nav.interactivePopGestureRecognizer {
                if pop.delegate !== self {
                    popGesture = pop
                    originalDelegate = pop.delegate
                    originalEnabled = pop.isEnabled
                }
                pop.delegate = self
                pop.isEnabled = enabled
            }
            // iOS 26+：整页内容任意位置右划返回（系统自带，和原生一致）。Duo 内屏右屏的导航栈不贴着屏幕左缘，
            // 左缘右划（屏幕边缘手势）够不着它，必须靠这个
            if #available(iOS 26.0, *), let content = nav.interactiveContentPopGestureRecognizer {
                if contentGesture == nil {
                    contentGesture = content
                    originalContentEnabled = content.isEnabled
                }
                content.isEnabled = enabled
            }
        }
        func restore() {
            // 委托是弱引用：页面退出后必须交还系统，否则根页也可能开始一次无效的 pop，后续推入会卡死。
            if let pop = popGesture, pop.delegate === self {
                pop.delegate = originalDelegate
                pop.isEnabled = originalEnabled
                contentGesture?.isEnabled = originalContentEnabled
            }
            popGesture = nil
            originalDelegate = nil
            contentGesture = nil
        }
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            enabled && (navigationController?.viewControllers.count ?? 0) > 1
        }
    }
}

// MARK: - 输入框宽度

/// 把内容的宽度收到可用宽度的 `factor` 倍并居中（输入框原来铺满整行，太长）。
/// `minWidth`：窄屏（Duo 的半屏、外屏）不能再收了，至少给这么宽；可用宽度本来就不到 `minWidth` 时用可用宽度。
private struct ScaledWidthLayout: Layout {
    var factor: CGFloat
    var minWidth: CGFloat

    private func target(_ available: CGFloat) -> CGFloat { min(available, max(available * factor, minWidth)) }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        // 无限宽的提议（横向 ScrollView 里）当作没给：target 会变成无限，返回非有限尺寸
        let available = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? 400
        let size = child.sizeThatFits(ProposedViewSize(width: target(available), height: proposal.height))
        return CGSize(width: available, height: size.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let child = subviews.first else { return }
        let width = target(bounds.width)
        child.place(at: CGPoint(x: bounds.midX, y: bounds.minY), anchor: .top,
                    proposal: ProposedViewSize(width: width, height: bounds.height))
    }
}

/// 无障碍字号下不收窄：字已经很大，再把输入框压到 80% 只剩约 176pt，一行放不下几个字
private struct ScaledWidthModifier: ViewModifier {
    let factor: CGFloat
    let minWidth: CGFloat
    @Environment(\.dynamicTypeSize) private var typeSize
    func body(content: Content) -> some View {
        ScaledWidthLayout(factor: typeSize.isAccessibilitySize ? 1 : factor, minWidth: minWidth) { content }
    }
}

extension View {
    func scaledWidth(_ factor: CGFloat = 0.8, minWidth: CGFloat = 300) -> some View {
        modifier(ScaledWidthModifier(factor: factor, minWidth: minWidth))
    }
}

/// 把整个窗口冻成一张快照，在冻住期间做事（内容最后回到原样），结束时直接拿掉快照（无动画）。
/// 用来在用户看不见的时候把「另一个标签页」真正建出来：系统 TabView 的标签页是第一次选中时才建的，
/// 第一次切换的主线程成本（Duo 内屏的对话流 + 说话区 ≈ 300–500ms）会卡在切换动画里。
@MainActor
func withFrozenWindow(_ body: () async -> Void) async {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    guard let window = (scenes.first { $0.activationState == .foregroundActive } ?? scenes.first)?.keyWindow,
          let snapshot = window.snapshotView(afterScreenUpdates: false) else { await body(); return }
    snapshot.frame = window.bounds
    snapshot.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    snapshot.isUserInteractionEnabled = true
    window.addSubview(snapshot)
    await body()
    snapshot.removeFromSuperview()
}

// MARK: - 动效

extension Animation {
    /// 全 App 统一的界面动画：0.25 秒平滑（临界阻尼的弹簧：起步不突兀、收尾不弹、中途被打断也能顺着当前速度接上）。
    static let ui = Animation.smooth(duration: 0.25)
    /// 内容出现 / 移位（新气泡、状态条、半屏高度）：0.25s 平滑，不弹
    static let rise = Animation.smooth(duration: 0.25)
    /// 设置 / 历史等整页推入、推出：开和合用同一条曲线、同一个时长
    static let push = Animation.smooth(duration: 0.34)
    /// 整页淡入淡出（Duo / 刘海横屏的设置 / 历史、同声传译、引导页退出、整页溶解）：一条曲线、一个时长
    static let page = Animation.easeInOut(duration: 0.25)
    /// 「减少动态效果」下整页的替代
    static let reducedPage = Animation.easeInOut(duration: 0.15)
    /// 「减少动态效果」下的替代：0.12s 淡入淡出（透明度变化不算运动）。不要直接用 nil——`.transition(.opacity)` 的元素会直接蹦出来
    static let reduced = Animation.easeInOut(duration: 0.12)
}

extension View {
    /// 只在上下方向把点按区域外扩（视觉 32–38pt 的分段选项补到 44pt）；左右不外扩，不然会抢相邻选项的边缘
    func verticalHitOutset(_ amount: CGFloat) -> some View {
        padding(.vertical, amount).contentShape(Rectangle()).padding(.vertical, -amount)
    }

    /// 内容出现 / 消失时的统一动画：平滑上移 + 淡入；减少动态效果时只做 0.12s 淡入淡出
    func riseAnimation<V: Equatable>(value: V, reduceMotion: Bool) -> some View {
        animation(reduceMotion ? .easeInOut(duration: 0.12) : .rise, value: value)
    }

    /// 出现 / 消失的转场：从下方 10pt 淡入；减少动态效果时只淡入
    func riseTransition(reduceMotion: Bool) -> some View {
        transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 10)))
    }
}

/// 开启"减少动态效果"时只做一次很短的淡入淡出（透明度变化不算运动），不做位移 / 缩放。
@MainActor
func withUIAnimation<R>(reduceMotion: Bool, _ body: () throws -> R) rethrows -> R {
    reduceMotion ? try withAnimation(.easeInOut(duration: 0.15), body) : try withAnimation(.ui, body)
}

// MARK: - 工具栏图标

/// 工具栏 / 标签栏用的图标：细线、17pt。用 UIImage 传入，系统就不会擅自放大或换成"粗实心"变体。
/// （Duo 竖排栏里图标太大会像一排大按钮，参考设计稿 design/duo-typing-and-icons.png）
struct BarLabel: View {
    let title: LocalizedStringKey
    let symbol: String
    var pointSize: CGFloat = 17
    /// 图案的宽度上限：有的符号（如 person.2）天生很宽，同样点数下比别的大一圈，按宽度压回去，几枚图标才视觉等大
    var maxWidth: CGFloat?

    init(_ title: LocalizedStringKey, symbol: String, pointSize: CGFloat = 17, maxWidth: CGFloat? = nil) {
        self.title = title
        self.symbol = symbol
        self.pointSize = pointSize
        self.maxWidth = maxWidth
    }

    private func image() -> UIImage? {
        func make(_ size: CGFloat) -> UIImage? {
            UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: size, weight: .regular))
        }
        guard let first = make(pointSize) else { return nil }
        guard let maxWidth, first.size.width > maxWidth else { return first }
        return make(pointSize * maxWidth / first.size.width) ?? first
    }

    var body: some View {
        Label {
            Text(title)
        } icon: {
            if let image = image() {
                Image(uiImage: image.withRenderingMode(.alwaysTemplate))
            } else {
                Image(systemName: symbol)
            }
        }
    }
}

/// 全 App 统一的几个图标名（改一处，面对面控制条、对话流、竖排栏同时变）。
enum BarSymbol {
    static let history = "clock.arrow.circlepath"
    static let keyboard = "keyboard"
    static let add = "plus"
    static let settings = "gearshape"
}


/// 这个视图里有 UITabBar，但全都是隐藏的（= 标签栏被 `toolbarVisibility(.hidden)` 藏起来了，只剩外壳）
@MainActor
private func containsOnlyHiddenTabBars(_ root: UIView) -> Bool {
    var found = false, anyVisible = false
    func walk(_ view: UIView) {
        if view is UITabBar {
            found = true
            if !view.isHidden, view.alpha > 0.01 { anyVisible = true }
            return
        }
        view.subviews.forEach(walk)
    }
    walk(root)
    return found && !anyVisible
}

/// 窗口里系统标签栏（UITabBar）的位置：直板在底部，Duo 外屏 / 内屏横放在右侧竖排
@MainActor
private func systemTabBarFrames(in window: UIWindow) -> [CGRect] {
    var result: [CGRect] = []
    func walk(_ view: UIView) {
        // 藏起来的视图整棵不看：它的子视图（标签按钮 / 底板）自己不标隐藏，会被误当成可见的标签栏挖洞
        if view.isHidden || view.alpha <= 0.01 { return }
        if view is UITabBar || String(describing: type(of: view)).contains("TabBar") {
            // 直板机的面对面 / 对话流页把系统标签栏藏起来（只留一个 _UIBottomTabBarGroupView 外壳，里面的 UITabBar 是 isHidden）：
            // 外壳本身「可见」，但没有真的标签栏——不能给它挖洞，否则洞里会露出新页底部的输入栏（它在溶解开始前就整个冒出来）
            if !view.isHidden, view.alpha > 0.01, view.bounds.width > 20, view.bounds.height > 20, !containsOnlyHiddenTabBars(view) {
                result.append(view.convert(view.bounds, to: window))
                return
            }
            if containsOnlyHiddenTabBars(view) { return }          // 只剩外壳：不挖，也不往里找
        }
        view.subviews.forEach(walk)
    }
    walk(window)
    return result
}

/// 切换「面对面 ⇄ 对话流」：整张页面作为一个整体交叉淡化，页面里的元素不做任何单独的动画（不位移、不抖、开屏也不淡入）。
/// 做法：先给整个窗口拍一张「旧页」的快照盖在最上面，立刻（不带动画）切到新页——新页是完整的、不透明的，躲在快照下面——
/// 再把快照淡出。系统 TabView 切页时会在那一帧直接换掉旧页，没法让旧页自己淡出，所以只能靠快照。
@MainActor
func crossfadePage(reduceMotion: Bool, keyboardWasUp: Bool = false, extraSettle: Double = 0, punchesChrome: Bool = true, _ change: () -> Void) {
    // 多窗口（iPad）：取前台那个场景的主窗口，不是随便第一个
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    let window = (scenes.first { $0.activationState == .foregroundActive } ?? scenes.first)?.keyWindow
    var instant = Transaction()
    instant.disablesAnimations = true
    // 调试开关：`-XTransNoCrossfade` 不拍快照（性能对照用）
    #if DEBUG || PERF_HOOKS
    if ProcessInfo.processInfo.arguments.contains("-XTransNoCrossfade") { withTransaction(instant, change); return }
    #endif
    guard let window, let snapshot = window.snapshotView(afterScreenUpdates: false) else {
        withTransaction(instant, change)
        return
    }
    // 快照盖着的这 0.2–0.3 秒里，点击不能落到看不见的新页上（用户看到的还是旧页）
    snapshot.isUserInteractionEnabled = true
    // 铺满窗口并跟着窗口变：0.3s 内转屏时不会露出一张尺寸 / 方向不对的快照
    snapshot.frame = window.bounds
    snapshot.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    // 系统标签栏不被快照盖住：用户点的是标签按钮，选中的那块胶囊要在眼前（原生地）滑过去，
    // 不能先冻在旧状态、等溶解完才跳一下——给快照挖一个洞，洞里是真正的标签栏
    // `punchesChrome: false`（外观切换这种整个窗口一起变色的）：不给标签栏 / 竖栏挖洞。设置页是盖在标签栏上面的，
    // 洞里露出的是已经变浅（深）的新页面——切换时屏幕底部先冒出一条白色圆角带、别处还是旧色，不是整页均匀溶解
    let barFrames = punchesChrome ? systemTabBarFrames(in: window) : []
    // Duo 的竖栏（内屏横放 / 外屏：工具栏按钮 + 标签胶囊竖排在最右一列）整列不盖快照：
    // 切换标签时竖栏里的按钮要走系统自己的过渡（淡入淡出 / 滑动），不能被一张静止的旧快照盖住、等溶解完才跳变。
    // 这一列里没有页面内容（只有极光背景，新旧页相同），挖掉不会露出接缝。
    let railWidth = window.safeAreaInsets.right
    let railFrame: CGRect? = (punchesChrome && railWidth > 40) ? CGRect(x: window.bounds.maxX - railWidth, y: 0, width: railWidth, height: window.bounds.height) : nil
    if !barFrames.isEmpty || railFrame != nil {
        let path = UIBezierPath(rect: window.bounds)
        for frame in barFrames {
            path.append(UIBezierPath(roundedRect: frame.insetBy(dx: -4, dy: -4), cornerRadius: min(frame.width, frame.height) / 2 + 4))
        }
        if let railFrame { path.append(UIBezierPath(rect: railFrame)) }
        let mask = CAShapeLayer()
        mask.frame = window.bounds
        mask.path = path.cgPath
        mask.fillRule = .evenOdd
        snapshot.layer.mask = mask
    }
    window.addSubview(snapshot)
    withTransaction(instant, change)
    // 兜底：无论如何 1 秒后快照必须不在了（动画被系统打断时 completion 不一定来）
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { snapshot.removeFromSuperview() }
    // 等新页排好、画出来再开始淡出（两次回到主队列 = 过了 SwiftUI 的下一次更新）。
    // 新页还在布局时就淡出，卡顿会直接表现成「淡出卡一下」；键盘还在收起时再多等 0.2s（收起要 ~0.25s，不然输入栏在溶解里还在动）
    let delay = 0.03 + (keyboardWasUp ? 0.2 : 0) + extraSettle      // extraSettle：外观切换这种整页重绘，多等一会儿让新页先提交
    DispatchQueue.main.async {
        DispatchQueue.main.async {
            UIView.animate(withDuration: reduceMotion ? 0.15 : 0.25, delay: delay,
                           options: [.curveEaseInOut, .allowUserInteraction],
                           animations: { snapshot.alpha = 0 },
                           completion: { _ in snapshot.removeFromSuperview() })
        }
    }
}



/// 屏内确认和编辑表单：Duo 的系统 alert 会在整窗居中，正好压住折痕。
private struct PaneDialog<Dialog: View>: View {
    @ViewBuilder let dialog: Dialog
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        ZStack {
            // 弹出 / 收起的过渡：遮罩淡入，卡片淡入 + 从 96% 轻轻放大（「减少动态效果」时只淡入淡出）。原来整块硬出现、硬消失
            Color.black.opacity(0.35).ignoresSafeArea().contentShape(Rectangle()).onTapGesture {}
                .transition(.opacity)
            ScrollView {
                dialog.padding(24)
            }
            .scrollBounceBehavior(.basedOnSize)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 380)
            .glass(in: RoundedRectangle(cornerRadius: 28))
            .padding(20)
            .accessibilityAddTraits(.isModal)
            .transition(reduceMotion ? .opacity : .scale(scale: 0.96).combined(with: .opacity))
        }
    }
}

extension View {
    /// 屏内弹层的出现 / 消失动画（0.22s 平滑；减少动态效果 0.12s 淡入淡出）。要挂在「始终存在」的容器上，条件里的内容才有过渡。
    fileprivate func paneDialogAnimation(_ shown: Bool, reduceMotion: Bool) -> some View {
        animation(reduceMotion ? .easeInOut(duration: 0.12) : .smooth(duration: 0.22), value: shown)
    }
}

private struct PaneConfirmation: ViewModifier {
    let title: LocalizedStringKey
    let message: LocalizedStringKey
    let actionTitle: LocalizedStringKey
    var role: ButtonRole? = .destructive
    @Binding var isPresented: Bool
    let action: () -> Void
    @Environment(\.inDuoPane) private var inDuoPane
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        content
            .alert(title, isPresented: Binding(get: { isPresented && !inDuoPane }, set: { isPresented = $0 })) {
                Button("取消", role: .cancel) {}
                Button(actionTitle, role: role, action: action)
            } message: { Text(message) }
            .overlay {
                ZStack {
                if inDuoPane && isPresented {
                    PaneDialog {
                        VStack(alignment: .leading, spacing: 16) {
                            Text(title).font(.headline).foregroundStyle(Theme.fg)
                            Text(message).font(.subheadline).foregroundStyle(Theme.sub)
                            HStack(spacing: 12) {
                                Button("取消") { isPresented = false }
                                    .frame(maxWidth: .infinity, minHeight: 44).glass(in: Capsule(), interactive: true)
                                Button(actionTitle, role: role) { action(); isPresented = false }
                                    .frame(maxWidth: .infinity, minHeight: 44).glass(in: Capsule(), interactive: true)
                            }.buttonStyle(.plain).foregroundStyle(Theme.fg)
                        }
                    }
                    .accessibilityAction(.escape) { isPresented = false }
                }
                }
                .paneDialogAnimation(isPresented, reduceMotion: reduceMotion)
            }
    }
}

private struct PaneTextPrompt: ViewModifier {
    let title: LocalizedStringKey
    let prompt: LocalizedStringKey
    let actionTitle: LocalizedStringKey
    @Binding var isPresented: Bool
    @Binding var text: String
    let action: () -> Void
    @Environment(\.inDuoPane) private var inDuoPane
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focused: Bool
    func body(content: Content) -> some View {
        content
            .alert(title, isPresented: Binding(get: { isPresented && !inDuoPane }, set: { isPresented = $0 })) {
                TextField(prompt, text: $text)
                Button("取消", role: .cancel) { isPresented = false }
                Button(actionTitle, action: action)
            }
            .overlay {
                ZStack {
                if inDuoPane && isPresented {
                    PaneDialog {
                        VStack(alignment: .leading, spacing: 16) {
                            Text(title).font(.headline).foregroundStyle(Theme.fg)
                            TextField(prompt, text: $text)
                                .focused($focused).font(.body).foregroundStyle(Theme.fg)
                                .padding(14).background(Theme.fg.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
                                .submitLabel(.done).onSubmit(confirm)
                            HStack(spacing: 12) {
                                Button("取消") { dismissKeyboard(); isPresented = false }
                                Spacer()
                                Button(actionTitle, action: confirm)
                                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            }.buttonStyle(.plain).foregroundStyle(Theme.fg).frame(minHeight: 44)
                        }
                    }
                    .task { focused = true }
                    .accessibilityAction(.escape) { dismissKeyboard(); isPresented = false }
                }
                }
                .paneDialogAnimation(isPresented, reduceMotion: reduceMotion)
            }
    }
    private func confirm() {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        dismissKeyboard(); action(); isPresented = false
    }
}

extension View {
    func paneConfirmation(_ title: LocalizedStringKey, message: LocalizedStringKey, actionTitle: LocalizedStringKey,
                          isPresented: Binding<Bool>, role: ButtonRole? = .destructive, action: @escaping () -> Void) -> some View {
        modifier(PaneConfirmation(title: title, message: message, actionTitle: actionTitle, role: role, isPresented: isPresented, action: action))
    }
    func paneTextPrompt(_ title: LocalizedStringKey, prompt: LocalizedStringKey, actionTitle: LocalizedStringKey,
                        isPresented: Binding<Bool>, text: Binding<String>, action: @escaping () -> Void) -> some View {
        modifier(PaneTextPrompt(title: title, prompt: prompt, actionTitle: actionTitle, isPresented: isPresented, text: text, action: action))
    }
}


/// 弹层的 detent：窄屏（直板）是半屏 / 整屏弹层，带拖动条；宽屏（Duo 内屏、iPad）是居中的表单卡片，
/// 高度由内容决定，不设 detent、不要拖动条（表单卡片自己的尺寸类是 compact，所以按窗口判断）。
private struct SheetDetents: ViewModifier {
    let detents: Set<PresentationDetent>
    var selection: Binding<PresentationDetent>?
    @ViewBuilder func body(content: Content) -> some View {
        if LayoutClass.forWindow(fallback: .zero) == .wide {
            content.presentationDragIndicator(.hidden)
        } else if let selection {
            content.presentationDetents(detents, selection: selection).presentationDragIndicator(.visible)
        } else {
            content.presentationDetents(detents).presentationDragIndicator(.visible)
        }
    }
}

extension View {
    func sheetDetents(_ detents: Set<PresentationDetent>, selection: Binding<PresentationDetent>? = nil) -> some View {
        modifier(SheetDetents(detents: detents, selection: selection))
    }
}
