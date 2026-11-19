import SwiftData
import SwiftUI

/// K1 · 直板 / 外屏键盘输入：替换下半屏。上半屏实时预览"对方将看到的译文"（标注未发送），
/// 发送键在输入框右端；发送后要不要朗读由旁边的朗读开关定（亮着朗读，关掉只显示）。适合安静场合、地名人名等语音难识别的内容。
struct ComposerView: View {
    let session: ConversationSession
    let onSent: () -> Void
    /// 很矮的屏幕（横着拿、键盘占掉大半）：间距收紧
    var compact = false
    /// 在操作行下面放一排常用短语（点一下填进输入框）：只在屏幕够高的横向打字里
    var showsPhrases = false
    /// 紧凑时仍保留右上角的「收起键盘」（竖放的短屏：打字时系统栏收起了，这是唯一的出口）
    var keepsClose = false
    /// 键盘上方只剩 ~225pt（iPhone SE 横屏）：间距、输入框、发送行再收紧一档
    var tight = false
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .title3) private var editorLineHeight: CGFloat = 24
    @Query(sort: \PhraseRecord.createdAt, order: .reverse) private var allPhrases: [PhraseRecord]

    init(session: ConversationSession, compact: Bool = false, showsPhrases: Bool = false, keepsClose: Bool = false, tight: Bool = false, onSent: @escaping () -> Void) {
        self.session = session
        self.tight = tight
        self.compact = compact
        self.showsPhrases = showsPhrases
        self.keepsClose = keepsClose
        self.onSent = onSent
    }

    private var phrases: [PhraseRecord] {
        Array(PhraseLibrary.sorted(allPhrases.filter { $0.langID == session.me.id }).prefix(8))
    }

    private var hasText: Bool { !session.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    @AppStorage(TypingSpeakToggle.key) private var speaks = true

    var body: some View {
        VStack(alignment: .leading, spacing: tight ? 4 : (compact ? 6 : 12)) {
            // 很矮的屏幕（横着拿 + 键盘）：省掉这一行标题 / 收起键，把高度留给输入框和发送键（键盘键在中间条上也能收起）
            if !compact || keepsClose {
            Text("\(session.me.nativeName) · 我")
                .font(Theme.label)
                .foregroundStyle(Theme.mut)
                .frame(maxWidth: .infinity, minHeight: 20, alignment: .leading)
            }

            // 有底板和描边，一眼看得出是输入框；提示字比真正输入的字细一档、淡一档（原来和输入的字一样粗一样深，空框看起来像已有内容）
            HStack(alignment: .bottom, spacing: 8) {
            // 输入框左边放和输入条（`ComposerDock`）同一个「收起键盘」键：所有版面同一个图标、同一个位置（原来高的版面是右上角一个 ✕）
            Group {
                Button(action: onSent) {
                    Image(systemName: "keyboard.chevron.compact.down")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(Theme.fg)
                        .frame(width: 44, height: 44)
                        .glass(in: Circle(), interactive: true)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("收起键盘输入")
                .padding(.bottom, 2)
            }
            TextField(text: Binding(get: { session.draft }, set: { session.updateDraft($0, composing: TextComposition.isComposing) }),
                      prompt: Text("输入要说的话…").font(.system(.title3).weight(.regular)).foregroundStyle(Theme.mut.opacity(0.8)),
                      axis: .vertical) {
                Text("输入要说的话…")
            }
                .font(.system(.title3).weight(.semibold))
                .foregroundStyle(Theme.fg)
                .lineLimit(1...(typeSize.isAccessibilitySize ? 2 : 5))
                .layoutPriority(1)
                .focused($focused)
                .submitLabel(.send)
                .disablesReturnKeyWhenEmpty(isFocused: focused)          // 空输入时键盘上的发送键置灰（原来亮蓝可按，和灰着的发送钮矛盾）
                .onSubmit(send)
                .padding(.leading, 14)
                .padding(.trailing, 50)          // 右端让给发送键
                .padding(.vertical, 12)
                // 多行 TextField 在最大字号下会低估自身高度，至少为两行真实行高留出空间。
                .frame(minHeight: typeSize.isAccessibilitySize && !compact ? editorLineHeight * 2 + 24 : (tight ? 44 : (compact ? 48 : 60)), alignment: .leading)          // 矮屏（compact）不留两行的高度：发送按钮会被挤到键盘后面
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .refocusOnTap($focused)
                .refocusOnActive($focused)
                // 和输入条同一套：圆角 22、深色下 15% 的白、描边 20%
                .background(colorScheme == .dark ? Color.white.opacity(0.15) : Theme.glassFill, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(reduceTransparency ? Theme.stroke : Theme.fg.opacity(0.2), lineWidth: 1))
                // 发送键在输入框右端（设计稿 typing-send 方案 C，用户选的）：原来下面单独一行「发送并朗读」「仅显示」两个大按钮，占地方
                .overlay(alignment: .bottomTrailing) {
                    TypingSendButton(enabled: hasText, action: send)
                        .padding(.trailing, 6).padding(.bottom, tight ? 4 : (compact ? 6 : 12))
                }
            // 朗读开关：亮着 = 发送后朗读，关掉 = 只显示。这个版面矮，只放图标，和输入框同一行（省掉原来整整一行按钮的高度）。
            TypingSpeakToggle(speaks: $speaks, showsLabel: false)
                .padding(.bottom, 2)
            }

            if showsPhrases, !compact, !phrases.isEmpty { phraseChips }
        }
        .scaledWidth(0.84, minWidth: 315)            // 输入框原来铺满整行，太长：收到 80% 并居中（窄屏不低于 300pt）；再长 5%：84% / 315pt
        .dynamicTypeSize(...(compact ? DynamicTypeSize.xxxLarge : DynamicTypeSize.accessibility1))          // 横放键盘上方只有一百多点高：超大字号下输入框把发送按钮挤到键盘后面（外屏横放 / 直板横屏），封顶一档（和撰写卡、内屏弹层一致）
        .padding(.horizontal, 20)
        .padding(.vertical, tight ? 2 : (compact ? 6 : 14))
        .frame(maxWidth: .infinity, alignment: .topLeading)
        // 等输入框真正进了窗口再要键盘（直接在 onAppear 里设，首次布局时常常不生效 / 键盘在转场中途才冒出来）
        .task { await Task.yield(); focused = true }
    }

    /// 常用短语：点一下把这句填进输入框（输入框里已有字就接在后面），不直接发送，改一改再发也行。
    private var phraseChips: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("常用短语")
                .font(Theme.caption)
                .foregroundStyle(Theme.mut)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(phrases) { phrase in
                        Button {
                            let draft = session.draft
                            session.updateDraft(draft.isEmpty ? phrase.text : draft + " " + phrase.text)
                            focused = true
                        } label: {
                            Text(phrase.text)
                                .font(.system(.subheadline))
                                .foregroundStyle(Theme.fg)
                                .lineLimit(1)
                                .padding(.horizontal, 14)
                                .frame(minHeight: 44)          // 点按区域够 44pt（原来 36pt + 向外 4pt 的补偿被横向滚动视图裁掉）
                                .glass(in: Capsule(), interactive: true)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(.top, 8)
    }

    private func send() {
        guard hasText else { focused = true; return }          // 只有空格时按回车：留在输入里（回车会让多行输入框失焦）
        // 拼音还没上屏就点发送：先让输入框把组合提交掉（失焦时系统会提交）再发——
        // 否则发出去的是带空格的拼音字母，发完系统还会把提交的字母写回输入框
        if TextComposition.isComposing { dismissKeyboard() }          // 同步失焦：系统当场把组合提交进输入框，草稿随即更新
        sendNow()
    }

    private func sendNow() {
        guard hasText else { focused = true; return }
        if session.isListening {
            session.stopListening()
            Haptics.warning()
            focused = true          // 没发出去：留在输入里（回车发送会让输入框失焦）
            session.speakOnSend = true          // 这次没发出去：「仅显示」不能留给下一次（短语 / 对话流发送会静音一次）
            return
        }
        session.speakOnSend = speaks          // 到这里才定：前面任何一步没发出去，都不会把「不朗读」留给下一次（常用语 / 对话流发送）
        if session.sendDraft() {
            Haptics.light()
            onSent()
        } else {
            focused = true
        }
    }
}

/// 键盘输入的输入条（设计稿 typing-v3 方案 A）：对话页**原地不动**，一条输入条贴在键盘上沿——
/// 外屏、内屏横放、内屏竖放、直板竖屏都是这同一条，只是宽度不同（最宽 640）。不是弹层，没有 ✓：
/// 第一行「收起键 ⌄ + 输入框」，第一行输入框右端是发送键；第二行「语言对 + 朗读开关」。译文不在条里：面对面页显示在对方那半屏，对话流页显示在对话末尾。
/// 键盘升降由系统带着它走（它在键盘安全区内）；键盘被收起而输入框是空的，它跟着收起。
struct ComposerDock: View {
    let session: ConversationSession
    let onPickLanguage: () -> Void
    let onClose: () -> Void
    /// 为 true 时键盘收起也不自动关（正在选语言：选完还要回来接着打）
    var keepsOpen = false
    /// 条的上沿在窗口里的位置：页面按它让开被条和键盘盖住的内容
    var onTopChange: ((CGFloat) -> Void)?
    /// 只为预热视图（看不见的那一份）：不要键盘、不自动关
    var prewarming = false
    @FocusState private var focused: Bool
    /// 这一次打字里软键盘真的升起过（接了实体键盘时软键盘不出现，也就谈不上「被收起」）
    @State private var sawKeyboard = false
    /// 正在选语言：键盘是我们自己让出去的，不算「用户收起键盘」；选完回来接着打
    @State private var pickingLanguage = false
    /// 正在提交输入法组合（拼音没上屏就点了发送）：这一下失焦是我们自己做的，不算「用户收起键盘」
    @State private var committing = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.activeFold) private var activeFold

    /// 横放时把条从「内容区正中」挪到「整屏正中」的距离：键盘是整屏宽的，条贴在键盘上，就该和键盘对中
    ///（内容区被右侧的系统竖栏占掉一截，按内容区居中时条相对键盘偏左约 42pt）。放不下（外屏：条几乎占满内容区）或半开时不挪。
    static func screenCenterShift(folded: Bool) -> CGFloat {
        guard !folded else { return 0 }
        let window = DuoLayout.currentWindowSize
        let insets = DuoLayout.windowSafeInsets
        let content = window.width - insets.left - insets.right
        let dock = min(640, content - 20)
        let slack = (content - dock) / 2 - 10
        return max(0, min((insets.right - insets.left) / 2, slack))
    }

    /// 半开且折痕竖着（横放像书一样打开）：条整个放在折痕右边我这半屏里，不压在折痕上（键盘自己也是分成两半的）。
    /// 返回条左边要让出的宽度（从内容区左沿算到折痕右沿）。
    private var foldLeading: CGFloat {
        guard let fold = activeFold, fold.height > fold.width else { return 0 }
        return max(0, fold.maxX - DuoLayout.windowSafeInsets.left)
    }

    private var hasText: Bool { !session.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    @AppStorage(TypingSpeakToggle.key) private var speaks = true

    var body: some View {
        VStack(spacing: 8) {
            HStack(alignment: .bottom, spacing: 8) {
                Button(action: close) {
                    Image(systemName: "keyboard.chevron.compact.down")          // 「收起键盘」的图标（原来的 ⌄ 和键盘候选栏的展开箭头是同一个形状）
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(Theme.fg)
                        .frame(width: 44, height: 44)
                        .glass(in: Circle(), interactive: true)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("收起键盘输入")
                .padding(.bottom, 2)

                HStack(alignment: .bottom, spacing: 4) {          // 多行时发送键贴着最后一行（居中的话打到三行它浮在中间）
                    TextField(text: Binding(get: { session.draft }, set: { session.updateDraft($0, composing: TextComposition.isComposing) }),
                              prompt: Text(verbatim: "\u{2009}" + String(localized: "输入要说的话…"))          // 前面垫一个窄空格：光标不压在第一个字上
                                .font(.system(.title3).weight(.regular)).foregroundStyle(Theme.mut),
                              axis: .vertical) { Text("输入要说的话…") }
                        .font(.system(.title3).weight(.semibold))
                        .foregroundStyle(Theme.fg)
                        .lineLimit(1...(typeSize.isAccessibilitySize ? 2 : 3))
                        .focused($focused)
                        .submitLabel(.send)
                        .disablesReturnKeyWhenEmpty(isFocused: focused)
                        .onSubmit { send(speaks: speaks) }
                        .accessibilityIdentifier("dock.draft")
                        .frame(minHeight: 36)          // 单行时和发送键一样高：底对齐后文字仍在发送键的竖直正中
                    // 发送键在输入框右端（设计稿 typing-send 方案 C，用户选的）。原来这个位置是清除键 ✕：两个放一起外屏上打字的地方只剩一百来点宽，去掉了
                    TypingSendButton(enabled: hasText) { send(speaks: speaks) }
                }
                .padding(.leading, 14).padding(.trailing, 4).padding(.vertical, 6)
                .frame(minHeight: 48, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .refocusOnTap($focused)
                .refocusOnActive($focused)
                // 比条本身亮：能输入的地方最亮（浅色下是白的；深色下 glassFill 只有 9% 的白、和条分不开，提到 15%）。
                // 圆角 22：单行时接近胶囊，和旁边的圆钮、胶囊按钮是同一种形状
                .background(colorScheme == .dark ? Color.white.opacity(0.15) : Theme.glassFill, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(reduceTransparency ? Theme.stroke : Theme.fg.opacity(0.2), lineWidth: 1))
            }

            // 第二行：语言对 + 朗读开关（原来是「仅显示」「发送并朗读」两个按钮）。大字号放不下：这一行退字号，语言名不截成「En…」
            ViewThatFits(in: .horizontal) {
                secondRow()
                secondRow().dynamicTypeSize(...DynamicTypeSize.xLarge)
                secondRow(fixedPair: false).dynamicTypeSize(...DynamicTypeSize.large)
            }
        }
        .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 8)
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)          // 辅助功能超大字号下条会长到盖住对方的预览：封顶一档
        .frame(maxWidth: 640)
        .glass(in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 18, y: 6)
        .onGeometryChange(for: CGFloat.self) { ($0.frame(in: .global).minY).rounded() } action: { DockTrace.log("dock.top=\($0)"); onTopChange?($0) }
        .padding(.horizontal, 10)
        .padding(.bottom, 8)          // 离键盘留一点缝
        .frame(maxWidth: .infinity)
        .padding(.leading, foldLeading)
        .offset(x: Self.screenCenterShift(folded: activeFold != nil))
        // 条先出现（0.12s 淡入），再要键盘：键盘第一次加载会卡住主线程约 0.3s，如果同时进行，条的淡入会被卡在半路、
        // 看起来是「键盘先到位、条慢半拍才出来」。现在是条先在位，再跟着键盘一起升上去
        .task {
            guard !prewarming else { return }
            // 键盘已经加载过（热）：马上要键盘，条和键盘一起、同一个节奏从底部升起（原来一律等 170ms：条先在底部淡入、停一会儿，再「跳」着跟上键盘）。
            // 还没加载过（冷，键盘首次加载会占住主线程几百毫秒）：条先淡入站稳（0.12s），再要键盘
            if KeyboardVisibility.shared.isWarm { await Task.yield() }
            else { try? await Task.sleep(for: .milliseconds(170)) }
            focused = true
        }
        #if DEBUG || PERF_HOOKS
        // 调试：`-XTransAutoSwap` 输入条出现后每 120ms 点一次条里的「互换语言」共 80 次（和 `ControlStrip` 里的同一个开关）
        .task {
            guard ProcessInfo.processInfo.arguments.contains("-XTransAutoSwap"), !prewarming else { return }
            try? await Task.sleep(for: .seconds(4))
            for _ in 0..<80 { swapTapped(); try? await Task.sleep(for: .milliseconds(120)) }
        }
        #endif
        .onAppear { DockTrace.log("dock.onAppear warm=\(KeyboardVisibility.shared.isWarm)") }
        .onDisappear { DockTrace.log("dock.onDisappear") }
        .onChange(of: focused) { _, now in DockTrace.log("dock.focused=\(now)") }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { note in
            sawKeyboard = true
            DockTrace.log("kb.willShow dur=\((note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? -1)")
        }
        // 条永远和键盘在一起：用户把键盘收起（下滑键盘 / 点页面空白处）= 收起输入条，打了一半的字留在草稿里，下次打开还在。
        // 只认「输入框真的失去焦点」的收起——转屏 / 折叠时系统会先收键盘再弹回来，输入框一直是第一响应者，不算；选语言时也不算。
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { note in
            DockTrace.log("kb.willHide dur=\((note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? -1) dismissedJustNow=\(KeyboardVisibility.shared.dismissedJustNow)")
            guard !prewarming, sawKeyboard, !pickingLanguage, !keepsOpen, !committing else { return }
            // 是我们自己（点空白处 / 点收起键）马上收的键盘：这一刻就跟着收，输入条和键盘同一时刻起步往下落
            if KeyboardVisibility.shared.dismissedJustNow { close(); return }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(40))          // 等焦点状态落定（下滑收键盘这类不经过我们的）
                guard !focused, !pickingLanguage, !keepsOpen, !committing, !KeyboardVisibility.shared.isVisible else { return }
                close()
            }
        }
        // 选完语言回来：接着打（键盘回来）
        .onChange(of: keepsOpen) { was, now in
            guard was, !now else { return }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(120))
                focused = true
                pickingLanguage = false
            }
        }
    }

    private func secondRow(fixedPair: Bool = true) -> some View {
        HStack(spacing: 8) {
            languagePair.fixedSize(horizontal: fixedPair, vertical: false)
            Spacer(minLength: 2)
            TypingSpeakToggle(speaks: $speaks)
        }
    }

    /// 互换箭头累计转过的角度（和首页语言条同一套：每次互换转半圈）
    @State private var swapAngle = 0.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 互换语言：和首页语言条（`ControlStrip.swapLanguages`）同一套反馈——忙碌时给一次警告触觉（原来点了完全没反应），
    /// 能换时一次选择触觉、箭头转半圈、两个名字互换位置
    private func swapTapped() {
        guard session.phase == .idle else { Haptics.warning(); return }
        Haptics.selection()
        if !reduceMotion { withAnimation(.smooth(duration: 0.3)) { swapAngle += 180 } }
        session.swapLanguages()
    }

    private func nameTransition(towards: CGFloat) -> AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .offset(x: 8 * towards))
    }

    /// 语言对：点语言名换语言，点中间对调
    private var languagePair: some View {
        HStack(spacing: 2) {
            // 三个点按区域互不重叠：名字就是自己的框（44 高），箭头的框加宽到 34（原来名字各向外扩 6、箭头向外扩 8，两边各重叠约 12pt，点名字的边缘会变成对调）
            Button { LanguagePickerEntry.startsOnThem = false; pickLanguage() } label: {
                Text(session.me.nativeName).id(session.me.id).transition(nameTransition(towards: 1))
                    .frame(minWidth: 30, minHeight: 44).contentShape(Rectangle())
            }
                .accessibilityLabel("我说的语言：\(session.me.nativeName)，点按更改")
            Button(action: swapTapped) {
                Image(systemName: "arrow.left.arrow.right").font(.system(size: 13, weight: .semibold))
                    .rotationEffect(.degrees(swapAngle))
                    .frame(width: 34, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("交换语言")
            Button { LanguagePickerEntry.startsOnThem = true; pickLanguage() } label: {
                Text(session.them.nativeName).id(session.them.id).transition(nameTransition(towards: -1))
                    .frame(minWidth: 30, minHeight: 44).contentShape(Rectangle())
            }
                .accessibilityLabel("对方说的语言：\(session.them.nativeName)，点按更改")
        }
        .font(.system(.subheadline).weight(.semibold)).foregroundStyle(Theme.sub).buttonStyle(.plain)
        .lineLimit(1).minimumScaleFactor(0.75)
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .padding(.horizontal, 8)
        // 很淡的胶囊底：看得出这一组能点（原来像一行纯文字）。底只有 36 高，点按区域仍是 44
        .background { Capsule().fill(Theme.fg.opacity(0.07)).padding(.vertical, 4) }
        // 名字互换的转场（和首页语言条一致；原来这里直接跳变）
        .animation(reduceMotion ? .reduced : .smooth(duration: 0.3), value: session.me.id)
        .animation(reduceMotion ? .reduced : .smooth(duration: 0.3), value: session.them.id)
    }

    private func send(speaks: Bool) {
        guard hasText else { refocusSoon(); return }
        // 拼音还没上屏就点发送：先让输入框把组合提交掉（失焦时系统会提交）再发（见 `ComposerView.send`）
        if TextComposition.isComposing {
            committing = true
            dismissKeyboard()          // 同步失焦：系统当场把组合提交进输入框，草稿随即更新；紧接着发送、收起，和平时同一个收起动画
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(200))
                committing = false
            }
        }
        sendNow(speaks: speaks)
    }

    private func sendNow(speaks: Bool) {
        guard hasText else { refocusSoon(); return }
        if session.isListening { session.stopListening(); Haptics.warning(); refocusSoon(); return }
        session.speakOnSend = speaks
        if session.sendDraft() { Haptics.light(); close() } else { refocusSoon() }
    }

    /// 没发出去（正在聆听 / 空内容）：留在输入里。回车发送会让多行输入框失焦，不拉回来的话输入条会跟着键盘一起被收掉
    private func refocusSoon() {
        Task { @MainActor in focused = true }
    }

    private func pickLanguage() {
        pickingLanguage = true          // 先立旗再让出键盘：收键盘的通知到的时候已经知道「这不是用户收起的」
        onPickLanguage()
    }

    private func close() { DockTrace.log("dock.close()"); focused = false; onClose() }
}

/// 输入条里的按钮：按下时略暗；禁用时**不**自动压淡（颜色由按钮自己按状态给）
struct DockButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// 打字的发送键：圆形、放在输入框右端（设计稿 typing-send 方案 C）。空输入时变淡、按不了。
struct TypingSendButton: View {
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.up")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(enabled ? Color.white : Theme.mut)
                .frame(width: 36, height: 36)
                .background(enabled ? AnyShapeStyle(Theme.control) : AnyShapeStyle(Theme.fg.opacity(0.12)), in: Circle())
                .contentShape(Rectangle().inset(by: -4))          // 看起来 36，点按区域 44
        }
        .buttonStyle(DockButtonStyle())
        .disabled(!enabled)
        .animation(.ui, value: enabled)
        .accessibilityLabel("发送")
    }
}

/// 打字发送后要不要朗读译文：亮着 = 朗读，关掉 = 只显示（原来是每次发送时在「发送并朗读」「仅显示」两个按钮里选）。选择会记住。
struct TypingSpeakToggle: View {
    static let key = "typing.speaksOnSend"
    @Binding var speaks: Bool
    var showsLabel = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button { Haptics.selection(); speaks.toggle() } label: {
            HStack(spacing: 6) {
                Image(systemName: speaks ? "speaker.wave.2.fill" : "speaker.slash.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .contentTransition(reduceMotion ? .opacity : .symbolEffect(.replace))
                    .frame(width: 20)          // 两个图标宽度不一样：给固定宽度，切换时胶囊的边不跳
                if showsLabel { Text("朗读").lineLimit(1) }
            }
            .font(.system(.subheadline).weight(.semibold))
            // 关着也用正常的字色（原来变灰，看起来像「不可用」而不是「只显示」）：靠图标上的斜线和一圈描边区分
            .foregroundStyle(speaks ? Theme.fg : Theme.sub)
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, showsLabel ? 14 : 0)
            .frame(minWidth: 44, minHeight: 44)
            .glass(in: Capsule(), interactive: true)
            .overlay(Capsule().strokeBorder(Theme.fg.opacity(speaks ? 0 : 0.28), lineWidth: 1))
        }
        .buttonStyle(DockButtonStyle())
        // 图标替换、颜色、描边一起过渡（原来改状态不在任何动画事务里，图标的替换效果根本没跑，整个按钮是硬切）
        .animation(reduceMotion ? .reduced : .ui, value: speaks)
        .accessibilityLabel("发送后朗读译文")
        .accessibilityValue(speaks ? Text("开") : Text("关"))
        .accessibilityAddTraits(.isToggle)
    }
}


/// 调试：`-XTransAutoTyping` 时把输入条开合过程里各事件的精确时刻打到系统日志（subsystem `DockTrace`），用来量「谁先谁后、隔多久」。
enum DockTrace {
    #if DEBUG
    private static let enabled = ProcessInfo.processInfo.arguments.contains("-XTransAutoTyping") || ProcessInfo.processInfo.arguments.contains("-XTransTrace")
    static func log(_ text: @autoclosure () -> String) {
        guard enabled else { return }
        NSLog("DockTrace %.3f %@", CACurrentMediaTime(), text())
    }
    #else
    @inline(__always) static func log(_ text: @autoclosure () -> String) {}
    #endif
}
