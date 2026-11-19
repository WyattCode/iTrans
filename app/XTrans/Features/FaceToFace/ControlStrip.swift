import SwiftUI

/// 中间的悬浮玻璃控制条：历史、键盘、语言对、加入（＋）、设置。
/// 手势（都有按钮替代）：上滑 = 对话流，双击空白处 = 交换语言。
struct ControlStrip: View {
    let session: ConversationSession
    let keyboardActive: Bool
    /// 窄条（左右分屏时只有半个屏宽）：图标更窄、间距更小
    var compact = false
    /// false = 历史 / 键盘 / 加入 / 设置已经在系统的竖排工具栏里，这里只留语言对
    var showsActions = true
    /// false = 这一页本来就是对话流（说话区），上滑和「切换到对话流」都没有意义，不提供
    var opensStream = true
    let onHistory: () -> Void
    let onKeyboard: () -> Void
    let onAdd: () -> Void
    let onSettings: () -> Void
    let onPickLanguage: () -> Void
    let onOpenStream: () -> Void
    /// 语言条（只有语言对时）左右再加的总宽度：外屏默认 +9（约 5%）；键盘输入时再长一截（`stripExtraFrom` → `stripExtra` 慢慢变长）
    var stripExtra: CGFloat = 0
    /// 条刚出现时的额外宽度（上一个版面里的值）；不等于 `stripExtra` 就在出现后 0.5 秒内平滑过渡过去
    var stripExtraFrom: CGFloat?
    @State private var animatedExtra: CGFloat?

    /// 版面上实际用的紧凑尺寸
    private var tight: Bool { compact }
    private var snug: Bool { false }

    /// 直板手机（非宽屏）上的条只留「键盘」和「⋯」两个图标，历史 / 加入对话 / 设置收进「⋯」：
    /// 原来四个图标 + 语言对 + 标记挤在一条里，按钮被收窄到 34pt、相邻点按区域重叠约 10pt（容易点错），语言对反而比图标小。
    /// 宽屏（iPad、Duo 内屏）本来就放得下，照旧四个图标。
    private var menuLayout: Bool { showsActions && LayoutClass.forWindow(fallback: .zero) != .wide }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 互换箭头累计转过的角度：每次互换再转 180°（动画稿第 3 项）；减少动态效果时不转
    @State private var swapAngle = 0.0

    /// 互换语言：两个名字互换位置、箭头转半圈、一次选择触觉；忙碌（正在听 / 翻译 / 朗读）时不能换，给一次轻微警告而不是静默无反应
    private func swapLanguages() {
        guard session.phase == .idle else {
            Haptics.warning()
            return
        }
        Haptics.selection()
        // 只有箭头在这个事务里转；两个名字的转场由语言对自己的 `.animation(value:)` 负责。
        // 原来把整个会话状态改动都包进 0.3s 动画：半屏文字、对话流副标题等一切读到语言的地方都被带进去动
        if !reduceMotion { withAnimation(.smooth(duration: 0.3)) { swapAngle += 180 } }
        session.swapLanguages()
    }

    /// 语言名换字时的转场：旧的朝对面那一侧淡出，新的从对面那一侧淡入（`towards` 为 +1 = 对面在右边）
    private func nameTransition(towards: CGFloat) -> AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .offset(x: 10 * towards))
    }

    var body: some View {
        let _ = BodyCount.hit("ControlStrip")
        HStack(spacing: 0) {
            if menuLayout {
                // 左右各一个 44pt 的图标：中间的语言对在整条正中
                stripButton(BarSymbol.keyboard, label: "键盘输入", active: keyboardActive, action: onKeyboard)
                    .padding(.leading, 10)          // 两个图标离条的边再往里收一点（用户要：键盘往右、⋯ 往左）；点按区域仍是 44pt
                Spacer(minLength: 4)
                centerGroup
                Spacer(minLength: 4)
                moreMenu
                    .padding(.trailing, 10)
            } else if showsActions {
                stripButton(BarSymbol.history, label: "历史", action: onHistory)
                stripButton(BarSymbol.keyboard, label: "键盘输入", active: keyboardActive, action: onKeyboard)
                Spacer(minLength: 4)
                centerGroup
                Spacer(minLength: 4)
                stripButton(BarSymbol.add, label: "加入对话", action: onAdd)
                stripButton(BarSymbol.settings, label: "设置", action: onSettings)
            } else {
                centerGroup
            }
        }
        .padding(.horizontal, tight ? 2 : 8)
        .frame(height: 56)
        // E4：系统字号再大，中间条也保持原样——图标不放大、语言对不换行（设计稿）
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .background {
            // 空白处的双击（按钮上的点按优先给按钮）
            Color.clear
                .contentShape(Capsule())
                .onTapGesture(count: 2) { swapLanguages() }
        }
        .glass(in: Capsule())
        .shadow(color: .black.opacity(0.12), radius: 14, y: 6)
        .onAppear {
            guard let from = stripExtraFrom, from != stripExtra, animatedExtra == nil else { return }
            animatedExtra = from
            DispatchQueue.main.async {
                if reduceMotion { animatedExtra = stripExtra } else { withAnimation(.smooth(duration: 0.5)) { animatedExtra = stripExtra } }
            }
        }
        // 宽屏上别拉得太长（带一排按钮时再短 10%：520 → 468）；只剩语言对时更窄（340）
        .frame(maxWidth: showsActions ? 430 : 340)
        .padding(.horizontal, tight ? 6 : 14)
        // 直板机上这根条太宽了：竖放时再收短约 8%（用户要 5%–10%）。窄屏（SE）收不动那么多，给它至少 360 宽，再窄语言名就被挤得缩字。
        // 横放 / iPad 本来就有 430 的上限（原来 468，同样短了 8%）
        .scaledWidth(showsActions ? 0.92 : 1, minWidth: 360)
        .simultaneousGesture(
            DragGesture(minimumDistance: 24).onEnded { value in
                guard opensStream else { return }
                if value.translation.height < -40, abs(value.translation.height) > abs(value.translation.width) {
                    onOpenStream()
                }
            }
        )
        .accessibilityElement(children: .contain)         // 自定义动作要挂在容器上，VoiceOver 才读得到
        .accessibilityAction(named: "切换到对话流") { if opensStream { onOpenStream() } }
        .accessibilityAction(named: "交换语言") { swapLanguages() }
        #if DEBUG || PERF_HOOKS
        // 调试：`-XTransAutoSwap` 启动 4 秒后每 120ms 点一次「互换语言」共 80 次，走的就是手指点箭头的那条路径。
        // 真机上连点 6~9 次就闪退（独占访问冲突，见 `ConversationSession.swapLanguages`），模拟器上用它复现 / 验证
        .task {
            guard ProcessInfo.processInfo.arguments.contains("-XTransAutoSwap") else { return }
            try? await Task.sleep(for: .seconds(4))
            for _ in 0..<80 { swapLanguages(); try? await Task.sleep(for: .milliseconds(120)) }
        }
        #endif
    }

    /// 注意：条上的"按钮"不用 `Button`，而是点按手势 + 按钮无障碍特征。
    /// `Button` 会吞掉父视图的拖动手势，导致从按钮上起手的上滑失效；手势版可以和上滑共存。
    @ViewBuilder
    private func stripButton(_ symbol: String, label: LocalizedStringKey, active: Bool = false, action: (() -> Void)?) -> some View {
        let icon = Image(systemName: symbol)
            .font(.system(size: 19, weight: .regular))
            .foregroundStyle(active && action != nil ? Theme.fg : Theme.sub)
            .frame(width: snug ? 34 : (tight ? 38 : 44), height: 44)
            .background(active ? Theme.meFill.opacity(0.22) : .clear, in: Circle())
            .contentShape(Rectangle().inset(by: snug ? -5 : (tight ? -3 : 0)))      // 紧凑时按钮 38pt 宽，点按区域补到 44pt
            .accessibilityLabel(label)
            .accessibilityAddTraits(active ? [.isButton, .isSelected] : .isButton)
            .accessibilityRemoveTraits(.isImage)
        if let action {
            icon.stripTap(action)
                .accessibilityAction(.default, action)
        } else {
            icon.opacity(0.45).accessibilityHint("即将推出")
        }
    }

    /// 「⋯」：历史 / 加入对话 / 设置。原来是系统 `Menu`——iOS 26 的菜单展开时会把整条语言条隐藏掉，只剩菜单；
    /// 改成从「⋯」弹出的小卡片（`popover`），语言条一直在。

    private var moreMenu: some View {
        // 系统 `Menu`：用户要的是「最早那种」原生弹出效果（自己画的卡片再怎么调弹簧，也没有系统菜单那种原生的顺滑）。
        // 代价是 iOS 26 的系统菜单展开时会把整条语言条隐藏，只剩菜单——这是系统行为，改不掉。
        Menu {
            Button { later(onHistory) } label: { Label("历史", systemImage: BarSymbol.history) }
            Button { later(onAdd) } label: { Label("加入对话", systemImage: BarSymbol.add) }
            Button { later(onSettings) } label: { Label("设置", systemImage: BarSymbol.settings) }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 19, weight: .regular))
                .foregroundStyle(Theme.sub)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("更多")
    }

    /// 菜单自己收起要 ~0.2s：弹层 / 页面等它收完再出来，两个动画不叠在一起
    private func later(_ action: @escaping () -> Void) {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(220))
            action()
        }
    }

    /// 中间一组：「中文 ⇆ English」，左右留白对称。
    private var centerGroup: some View {
        // 直板手机（`menuLayout`，条里只有两个图标）：整组两侧不再留带四个按钮时的那一大截（18pt），改成 2pt——
        // 原来 iPhone Air 这种比 Pro Max 窄的屏上「English」被留白挤得比「中文」小一圈
        let outer: CGFloat = menuLayout ? 2 : (snug ? 1 : (tight ? 3 : 12)) + (animatedExtra ?? stripExtraFrom ?? stripExtra) / 2 + (showsActions ? 6 : 21)
        return HStack(spacing: 0) {
            languagePill.layoutPriority(1)
        }
        .padding(.horizontal, outer)
    }

    private var languagePill: some View {
        HStack(spacing: tight ? 2 : 6) {
            Text(session.me.nativeName)
                .lineLimit(1).minimumScaleFactor(0.6)          // 条的宽度有限（直板机带四个按钮）：大字号下先缩字，不截成「Eng…」
                .id(session.me.id)
                .transition(nameTransition(towards: 1))
                .frame(minHeight: 44)
                .contentShape(Rectangle().inset(by: -8))          // 点按区域向外扩，不在字的两侧撑出看不见的空白
                .stripTap(highlight: 56) { LanguagePickerEntry.startsOnThem = false; onPickLanguage() }
                .accessibilityLabel("我说的语言：\(session.me.nativeName)，点按更改")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction(.default) { LanguagePickerEntry.startsOnThem = false; onPickLanguage() }

            Image(systemName: "arrow.left.arrow.right")
                .foregroundStyle(Theme.fg)
                .rotationEffect(.degrees(swapAngle))
                .frame(width: snug ? 28 : (tight ? 32 : 44), height: 44)
                .contentShape(Rectangle().inset(by: tight ? -6 : 0))      // 紧凑时 32pt 宽，补到 44pt
                .stripTap { swapLanguages() }
                .accessibilityLabel("交换语言")
                .accessibilityAddTraits(.isButton)
                .accessibilityRemoveTraits(.isImage)
                .accessibilityAction(.default) { swapLanguages() }

            Text(session.them.nativeName)
                .lineLimit(1).minimumScaleFactor(0.6)          // 条的宽度有限（直板机带四个按钮）：大字号下先缩字，不截成「Eng…」
                .id(session.them.id)
                .transition(nameTransition(towards: -1))
                .frame(minHeight: 44)
                .contentShape(Rectangle().inset(by: -8))          // 点按区域向外扩，不在字的两侧撑出看不见的空白
                .stripTap(highlight: 56) { LanguagePickerEntry.startsOnThem = true; onPickLanguage() }
                .accessibilityLabel("对方说的语言：\(session.them.nativeName)，点按更改")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction(.default) { LanguagePickerEntry.startsOnThem = true; onPickLanguage() }
        }
        .font(.system(.footnote).weight(.semibold))
        .foregroundStyle(Theme.fg)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        // 选语言（语言选择页）和互换都走同一个转场；互换时外层的 withAnimation 已经带了 0.3s
        .animation(reduceMotion ? .easeInOut(duration: 0.12) : .smooth(duration: 0.3), value: session.me.id)
        .animation(reduceMotion ? .easeInOut(duration: 0.12) : .smooth(duration: 0.3), value: session.them.id)
    }
}


/// 语言条上每一处可点的东西：按下时的反馈（轻轻缩小 + 变暗 + 一个很淡的圆形高亮，松手弹回）+ 点按本身。
/// **一个手势同时管「按下」和「点按」**：第一版是 `onTapGesture` 外面再叠一个零距离拖动来拿按下状态，两个手势互相干扰，点哪里都没反应。
/// 也不用 `Button`：`Button` 会吞掉条上的上滑手势（见 `stripButton` 的说明）。手指拖出去（上滑切对话流）就不算点按。
private struct StripTap: ViewModifier {
    var highlight: CGFloat = 40
    let action: () -> Void
    // GestureState：手势被系统取消（来电 / 横幅 / 系统手势接管）时自动复位，不会卡在「按下」
    @GestureState private var pressing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private func inside(_ value: DragGesture.Value) -> Bool {
        abs(value.translation.width) < 20 && abs(value.translation.height) < 20
    }

    func body(content: Content) -> some View {
        content
            .scaleEffect(pressing && !reduceMotion ? 0.9 : 1)
            .opacity(pressing ? 0.65 : 1)
            .background {
                Circle().fill(Theme.fg.opacity(pressing ? 0.14 : 0)).frame(width: highlight, height: highlight)
            }
            .animation(pressing ? .easeOut(duration: 0.08) : .ui, value: pressing)          // 松手用全局的 0.25s 平滑，不回弹（原来是会弹一下的弹簧）
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .updating($pressing) { value, state, _ in state = inside(value) }
                    .onEnded { value in
                        if inside(value) { action() }
                    })
    }
}

extension View {
    fileprivate func stripTap(highlight: CGFloat = 40, _ action: @escaping () -> Void) -> some View { modifier(StripTap(highlight: highlight, action: action)) }
}
