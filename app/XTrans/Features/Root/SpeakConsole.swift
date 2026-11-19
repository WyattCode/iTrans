import SwiftUI

/// 说话区（iPhone Duo 对话流的第二块屏，设计稿方案 B）：语言对、对方 / 我两个麦克风、当前状态，
/// 以及「加入对话」「键盘输入」「历史」三个入口。说的话、翻译都出现在另一块屏的对话里。
struct SpeakConsole: View {
    let session: ConversationSession
    let packs: LanguagePackStore
    let onAdd: () -> Void
    let onHistory: () -> Void
    let onKeyboard: () -> Void
    var onSettings: () -> Void = {}
    /// 底部要让开的高度：竖放时系统标签栏浮在下屏底部
    var bottomInset: CGFloat = 0
    /// 三个入口排成一行（竖放时下屏矮，放不下两行；横放右屏窄，一行放不下）
    var inlineActions = false
    /// 说话坞（Duo 内屏横放展平）：浮在整屏对话下方正中的玻璃卡片——对方麦克风 · 语言条 · 我的麦克风，下面一行键盘输入 / 历史 / 加入对话。
    /// 语言条正好在屏幕内容区的正中；每个功能只有一个入口（对话页不再有自己的输入栏和历史按钮）。
    var dock = false
    /// 键盘输入 / 历史 / 加入对话 / 设置在系统竖栏里（Duo 内屏横放）：说话区里只留语言条、麦克风和提示
    var actionsInRail = false
    /// 一行说话区（Duo 内屏竖放，设计稿 A）：对方麦克风 · 语言条 · 我的麦克风排成一行，下面一行状态；
    /// 键盘输入 / 历史 / 加入对话 / 设置都在页头的「＋」「⋯」里，这里一个按钮都不放。
    var row = false
    /// 一行说话区要不要自己铺极光底：半开时它是下半屏里单独的一块；展平时浮在整屏对话上，不铺
    var rowBackground = false

    @State private var showingLanguages = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            if row {
                rowContent
            } else if dock {
                dockContent
            } else {
                // 放得下就不滚动：麦克风按钮在 ScrollView 里，手指按住时只要有一点点位移，UIScrollView 就会接管、取消按钮的手势
                // （「按住说话」一按就断，内屏竖放下屏很矮时内容略微超出就会这样）。放不下（超大字号）才用可滚动的版本。
                ViewThatFits(in: .vertical) {
                    consoleContent
                        .padding(.bottom, bottomInset)
                        // 动作都在竖栏里时（Duo 内屏横放半开的右屏）：只剩语言条 + 麦克风 + 提示，在这半屏里垂直居中（原来顶着上沿、下面空一大片）
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: actionsInRail ? .center : .top)
                    ScrollView {
                        consoleContent
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    .contentMargins(.bottom, bottomInset, for: .scrollContent)
                }
                .background { PageBackground() }
            }
        }
        .languagePicker(isPresented: $showingLanguages, session: session, packs: packs, scheme: colorScheme)      // 弹层不继承 App 设的外观，要显式带上；Duo 内屏改成屏内浮层
    }

    private var rowContent: some View {
        VStack(spacing: 4) {
            HStack(alignment: .micCenter, spacing: 12) {
                micColumn(.them, caption: "对方")
                ControlStrip(session: session, keyboardActive: false, compact: true, showsActions: false, opensStream: false,
                             onHistory: {}, onKeyboard: {}, onAdd: {}, onSettings: {},
                             onPickLanguage: { showingLanguages = true }, onOpenStream: {})
                    .frame(maxWidth: 340)
                micColumn(.me, caption: "我")
            }
            statusLine
        }
        .padding(.horizontal, 28)
        .padding(.top, 8)
        .padding(.bottom, bottomInset)
        // 半开（自己占下半屏）：在折痕和标签栏之间垂直居中——原来贴着折痕下沿，下面空出一大片
        .frame(maxWidth: .infinity, maxHeight: rowBackground ? .infinity : nil)
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)          // 一行说话区在辅助功能超大字号下「对方 / 我」和提示会挤在一起：封顶
        .background { if rowBackground { PageBackground() } }
    }

    private var dockContent: some View {
        VStack(spacing: 6) {
            HStack(alignment: .micCenter, spacing: 8) {          // 条对齐到两个麦克风圆球的垂直中线（不是整列，整列下面还有说明文字）
                micColumn(.them, caption: "对方")
                ControlStrip(session: session, keyboardActive: false, compact: false, showsActions: false, opensStream: false,
                             onHistory: {}, onKeyboard: {}, onAdd: {}, onSettings: {},
                             onPickLanguage: { showingLanguages = true }, onOpenStream: {})
                    .fixedSize(horizontal: true, vertical: false)          // 条按自己的宽度排（它自带 maxWidth 340，不收紧会撑出一大块空）
                micColumn(.me, caption: "我")
            }
            statusLine
        }
        .padding(.horizontal, 28)
        .padding(.top, 14)
        .padding(.bottom, 14)
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)          // 说话坞浮在对话上：辅助功能超大字号下「对方 / 我」和提示会把坞撑得又高又挤，封顶一档（和竖放的一行说话区一致）
        .glass(in: RoundedRectangle(cornerRadius: 44, style: .continuous))
        .shadow(color: .black.opacity(0.14), radius: 18, y: 8)
    }

    private var consoleContent: some View {
            VStack(spacing: 0) {
                if !actionsInRail {          // 和竖放一样不要「说话区」标题（只占一行、没有信息）
                    HStack {
                        Text("说话区")
                            .font(.system(.headline))
                            .foregroundStyle(Theme.fg)
                            .accessibilityAddTraits(.isHeader)
                        Spacer(minLength: 0)
                    }
                    .frame(minHeight: inlineActions ? 52 : 64)          // 竖放下屏矮：各段间距收紧，按钮行才不会被浮在底部的标签栏盖住
                    .padding(.horizontal, 20)
                }

                ControlStrip(session: session, keyboardActive: false, compact: true, showsActions: false, opensStream: false,
                             onHistory: {}, onKeyboard: {}, onAdd: {}, onSettings: {},
                             onPickLanguage: { showingLanguages = true }, onOpenStream: {})

                HStack(spacing: 36) {
                    micColumn(.them, caption: "对方")
                    micColumn(.me, caption: "我")
                }
                .padding(.top, inlineActions ? 12 : 24)
                statusLine
                    .padding(.top, inlineActions ? 10 : 14)
                    .accessibilityElement(children: .combine)

                if !actionsInRail {
                    if inlineActions {
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 10) {
                                secondaryButton("键盘输入", symbol: BarSymbol.keyboard, action: onKeyboard)
                                secondaryButton("历史", symbol: BarSymbol.history, action: onHistory)
                                addButton
                                settingsButton
                            }
                            VStack(spacing: 10) {          // 放不下一行：两行两个
                                HStack(spacing: 10) {
                                    secondaryButton("键盘输入", symbol: BarSymbol.keyboard, action: onKeyboard)
                                    secondaryButton("历史", symbol: BarSymbol.history, action: onHistory)
                                }
                                HStack(spacing: 10) { addButton; settingsButton }
                            }
                        }
                        .padding(.top, 12)
                        .padding(.bottom, 8)
                    } else {
                        HStack(spacing: 10) {
                            secondaryButton("键盘输入", symbol: BarSymbol.keyboard, action: onKeyboard)
                            secondaryButton("历史", symbol: BarSymbol.history, action: onHistory)
                        }
                        .padding(.top, 20)
                        HStack(spacing: 10) { addButton; settingsButton }
                            .padding(.vertical, 14)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .dynamicTypeSize(...DynamicTypeSize.accessibility1)          // 半屏的说话区：超大字号下「对方 / 我」和提示挤成一团，封顶一档（和说话坞、一行说话区一致）
    }

    /// 设置入口和键盘输入 / 历史 / 加入对话在同一排（原来单独飘在页头右上角，和其他页面的位置不统一）
    private var settingsButton: some View {
        secondaryButton("设置", symbol: BarSymbol.settings, action: onSettings)
    }

    /// 和「键盘输入」「历史」同一个样式（原来是粉红主按钮，和左边两个按钮不一致）
    private var addButton: some View {
        secondaryButton("加入对话", symbol: BarSymbol.add, action: onAdd)
    }

    private func secondaryButton(_ title: LocalizedStringKey, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(.subheadline))
                .foregroundStyle(Theme.fg)
                .padding(.horizontal, 16)
                .frame(minHeight: 44)
                .glass(in: Capsule(), interactive: true)
        }
        .buttonStyle(.plain)
    }

    private func micColumn(_ side: Speaker, caption: LocalizedStringKey) -> some View {
        VStack(spacing: 6) {
            MicButton(
                speaker: side,
                appearance: appearance(side),
                onTap: {
                    if blocked(side) { PermissionCenter.openSystemSettings() } else { session.micTapped(side) }
                },
                onHoldBegan: { blocked(side) ? false : session.holdBegan(side) },
                onHoldPromotedToTap: { session.holdPromotedToTap(side) },
                onHoldEnded: { session.holdEnded(side) },
                onTouchDown: { session.prepareToListen() }
            )
            .alignmentGuide(.micCenter) { $0[VerticalAlignment.center] }
            Text(caption)
                .font(Theme.label)
                .foregroundStyle(Theme.fg)          // 两个标题同色（原来「对方」是青色字、「我」是前景色，不对称）
        }
    }

    private func blocked(_ side: Speaker) -> Bool {
        side == .me && (session.notice == .microphoneDenied || session.notice == .speechDenied)
    }

    private func appearance(_ side: Speaker) -> MicButton.Appearance {
        if blocked(side) { return .blocked }
        switch session.phase {
        case .listening(let who): return who == side ? .listening : .dimmed
        default:
            if case .noSpeech(let who) = session.notice, who == side { return .error }
            return .idle
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        switch session.phase {
        case .listening(let who):
            Text(who == .me ? "正在聆听 · 我" : "正在聆听 · 对方")
                .font(Theme.caption).foregroundStyle(Theme.sub)
        default:
            if session.notice == .microphoneDenied || session.notice == .speechDenied {
                // 权限被拒：说话区原来没有任何说明和出路（只有左屏的对话里一行小字）
                Button { PermissionCenter.openSystemSettings() } label: {
                    Label("需要权限 · 轻点前往设置", systemImage: "exclamationmark.triangle")
                        .font(Theme.caption).foregroundStyle(Theme.warn)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                Text("轻点自动识别，按住说话")
                    .font(Theme.caption).foregroundStyle(Theme.mut)
            }
        }
    }
}

private extension VerticalAlignment {
    /// 麦克风圆球的垂直中线：说话坞里语言条对齐到它
    struct MicCenter: AlignmentID {
        static func defaultValue(in context: ViewDimensions) -> CGFloat { context[VerticalAlignment.center] }
    }
    static let micCenter = VerticalAlignment(MicCenter.self)
}
