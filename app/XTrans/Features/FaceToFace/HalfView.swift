import SwiftData
import SwiftUI

/// 一半屏：只用这一半屏主人的语言显示整场对话（设计稿"一人一半屏"）。
/// 上半屏在外层被旋转 180°，朝向对面的人。
struct HalfView: View {
    let session: ConversationSession
    let side: Speaker
    /// 键盘输入中：对方那半屏显示"我正在打的话"的译文预览
    var showsPreview = false
    /// 点"全屏展示"
    var onExpand: (BigDisplayRequest) -> Void = { _ in }
    /// 点"用键盘"（没听清 / 权限被拒时的出路）
    var onKeyboard: () -> Void = {}
    /// 麦克风放在下方（竖向半屏）还是末端（横向半屏，横屏时的上下分屏）
    var micPlacement: FaceGeometry.MicPlacement = .bottom
    /// false = 不放麦克风（竖放外屏打字时上半屏很矮：把高度全给对方的预览文字，麦克风在打字时用不到）
    var showsMic = true
    /// 撰写卡盖着这半屏（竖屏打字，我这一侧）：还没有对话时什么都不放——空状态的「轻点麦克风」在麦克风已让位时是错的指引，还会被卡片切掉半行
    var quiet = false
    /// 空状态的提示贴在麦克风上方（Duo 内屏竖放：半屏又高又空，提示漂在正中、离麦克风 ~200pt 就和它指的东西脱节）
    var hintAtMic = false
    /// 对方半屏的预览空状态要避开盖在上面的撰写卡：在靠卡片的一侧（本半屏旋转 180° 前的顶部）多留的空
    var previewInset: CGFloat = 0
    /// 打字时的空预览提示在屏幕上往右挪多少（让它对准输入条的中线；这半屏旋转了 180°，里面按反方向挪）
    var previewShift: CGFloat = 0

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.compactLines) private var compactLines

    private var language: LanguageOption { session.language(of: side) }
    /// E4 · 超大字号：只保留当前这一句并放大，较早的消息收进对话流。
    private var isHugeType: Bool { dynamicTypeSize >= .accessibility2 }
    private var visibleTurns: [Turn] { Array(session.turns.suffix(isHugeType ? 1 : 2)) }
    /// 用户用手滑动过：朗读期间暂停自动跟随，直到点"回到当前句"或下一句话开始
    @State private var userScrolled = false
    /// 长译文读完后窗口留在原处（锚点保持贴顶），直到下一轮开始——否则读完那一刻锚点切回贴底，内容会跳一下
    @State private var holdsReadingAnchor = false
    /// 内容是否比窗口高（不高就仍然贴底，短句离麦克风近）
    @State private var overflows = false
    @State private var resumeTask: Task<Void, Never>?

    /// 正在给我这一侧读译文时：读到哪一句、共几句、整体进度。没在读（或读的是我自己的话）= nil。
    private var follow: (id: String, index: Int, count: Int, fraction: Double)? {
        guard let id = session.speakingTurnID,
              let turn = session.turns.first(where: { $0.id == id }), turn.speaker != side,
              let text = turn.translatedText, !text.isEmpty else { return nil }
        let sentences = Sentences.split(text)
        let index = Sentences.index(containing: session.spokenOffset, in: sentences)
        let total = max(1, text.utf16.count)
        return (Sentences.id(turn: id, index: index), index, sentences.count, min(1, Double(session.spokenOffset) / Double(total)))
    }

    /// 译文刚出现的那一刻（不论读不读）：窗口从这一段的开头看起，而不是贴着底部只看到结尾。
    private var arrivalTarget: String? {
        guard let turn = session.currentTurn, turn.speaker != side,
              let text = turn.translatedText, !text.isEmpty else { return nil }
        return Sentences.id(turn: turn.id, index: 0)
    }

    /// 阅读线：当前句的上缘放在窗口靠上 1/4 处，前面留一点已读的内容，后面是接下来要读的
    /// `animated: false` 用于译文刚出现时：直接定位到开头（文字本身在淡入，看不到跳），
    /// 否则会先显示贴底的结尾、再一路滑回开头。
    private func scroll(_ proxy: ScrollViewProxy, to id: String, animated: Bool = true) {
        let move = { proxy.scrollTo(id, anchor: UnitPoint(x: 0, y: 0.25)) }
        if reduceMotion || !animated { move() } else { withAnimation(.smooth(duration: 0.3), move) }
    }
    /// E3 · 麦克风 / 语音识别权限被拒：我这一侧整个换成引导页
    private var permissionBlocked: Bool {
        guard side == .me else { return false }
        return session.notice == .microphoneDenied || session.notice == .speechDenied
    }

    var body: some View {
        let _ = BodyCount.hit("HalfView")
        content
        .padding(.horizontal, 20)
        .background { glow }
        // 只在"多了/少了一条消息"时过渡；识别过程中文字逐字更新不做动画（否则每个字都在抖）
        .animation(reduceMotion ? .reduced : .easeOut(duration: 0.2), value: session.turns.count)
        // 提示小字、光晕随"没听清 / 开始聆听"一起淡入淡出，和麦克风的抖动同一节奏
        .animation(reduceMotion ? .reduced : .easeOut(duration: 0.25), value: session.notice)
        .onChange(of: session.notice) { _, notice in
            // 出错时给一下警告触感（只在出现提示的那一侧触发一次）
            // 「没听清」的警告触感由麦克风按钮自己负责；这里只管权限被拒（出现在我这一侧）
            guard let notice else { return }
            if case .noSpeech = notice { return }
            if side == .me { Haptics.warning() }
        }
    }

    @ViewBuilder
    private var content: some View {
        let text = lines
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .dismissKeyboardOnTap()           // 点文字区的空白处收起键盘
            // 打第一个字 / 清空：原内容（或空提示）和译文预览之间交叉淡化，不是一帧替换
            .animation(reduceMotion ? .reduced : .easeInOut(duration: 0.2), value: showsPreview && !session.previewDraft.isEmpty)
            // 两个半屏显示的是同一场对话（只是语言不同、方向相反）：只让我这一侧被 VoiceOver
            // 读出，免得同一句话读两遍。对方那半屏的麦克风仍然可以操作。
            .accessibilityHidden(side == .them && !permissionBlocked)
        switch micPlacement {
        case .bottom:
            VStack(spacing: 0) {
                text
                micNoteView            // 没听清 / 权限被拒：夹在文字和麦克风之间，不压住文字
                if showsMic { mic.frame(height: 104) }
            }
        case .trailing:
            // 横向的半屏很矮：麦克风放在末端、贴着底边，文字占满剩下的宽度和全部高度
            // 麦克风永远是这个 ZStack 的最后一个子视图、位置固定：空对话 ⇄ 有对话（按下开始听、第一句识别文字一出现，
            // `showsEmptyState` 就翻转）时只有文字那一层换分支。原来麦克风跟着分支在 ZStack / HStack 里各放一份，
            // 分支一翻转两个麦克风都被销毁重建，正在进行的长按被系统取消、聆听当场结束（Duo 内屏展平、直板横屏都中）。
            ZStack(alignment: .bottomTrailing) {
                if showsEmptyState || permissionBlocked || showsEmptyPreview {
                    // 空状态 / 引导文案 / 打字时的空预览提示：以整个半屏的中线为中心，和中间的语言条上下对齐（不能被末端的麦克风挤得偏向一边）。
                    // 左右各让出一个麦克风的宽度，文案居中；提示小字叠在麦克风左边。
                    text.padding(.horizontal, 104)
                    HStack(spacing: 0) {
                        micNoteView.frame(maxHeight: .infinity, alignment: .bottom).padding(.bottom, 30)
                        Color.clear.frame(width: 104)
                    }
                } else {
                    HStack(spacing: 0) {
                        text
                        micNoteView.frame(maxHeight: .infinity, alignment: .bottom).padding(.bottom, 30)
                        Color.clear.frame(width: 104)
                    }
                }
                mic
                    .frame(width: 104)
                    .frame(maxHeight: .infinity, alignment: .bottom)
            }
        }
    }


    // MARK: 声光（以麦克风为光源）

    private var glow: some View {
        ListeningGlow(session: session, side: side, micPlacement: micPlacement)
    }

    // MARK: 麦克风旁的一行小字（没听清 / 权限被拒）

    /// 没听清：只有"我说话"那一侧或被点名的那一侧出现；权限被拒只在我这侧。
    private var micNote: (text: String, action: () -> Void)? {
        if permissionBlocked {
            return (String(localized: "需要权限 · 轻点前往设置"), { PermissionCenter.openSystemSettings() })
        }
        if case .noSpeech(let who) = session.notice, who == side {
            return (Strings.noSpeechTap(language), { session.micTapped(side) })
        }
        return nil
    }

    @ViewBuilder
    private var micNoteView: some View {
        if let note = micNote {
            Button(action: note.action) {
                Text(note.text)
                    .font(.system(.footnote).weight(.semibold))
                    .foregroundStyle(Theme.warn)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.7)          // 超大字号 + 较长的语言（俄语、德语）：先缩一点，别截成「…」
                    .padding(.horizontal, 12)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .transition(.opacity)
        }
    }

    /// 打字时对方半屏还没有内容、也没有输入：显示「译文会出现在这里」的提示
    private var showsEmptyPreview: Bool { showsPreview && side == .them && session.previewDraft.isEmpty && session.turns.isEmpty }

    private var showsEmptyState: Bool { session.turns.isEmpty && !showsPreview && !quiet }

    /// 对话内容区。内容再长也不能撑大半屏（否则两个半屏会不等高、麦克风被顶出屏幕），
    /// 所以放进滚动视图里：默认贴着底部（最新的那句离麦克风最近），更早的可以往回滑看。
    @ViewBuilder
    private var lines: some View {
        if permissionBlocked {
            ScrollView(.vertical, showsIndicators: false) {
                PermissionDeniedCard(isMicrophone: session.notice == .microphoneDenied)
                    .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if showsPreview, side == .them, session.previewDraft.isEmpty, session.turns.isEmpty {
            // 打字模式下对方那半屏：还没有内容也没有输入，放一个淡淡的气泡，说明这里是"对方看到的"（不写字：这半屏是对方的语言）
            // 矮屏（竖放外屏 + 键盘）也放：预览区现在是固定的上半（语言条在可用区正中），不会和条叠在一起
            let hint = Text(Strings.previewEmpty(language))
                .font(Theme.caption)
                .foregroundStyle(Theme.mut)
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.7)
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)          // 打字时这半屏很矮（键盘占了一半）：超大字号下一行提示被截成「…」，封顶
            // 矮的半屏（横放打字、键盘占了一块）放不下图标就只留字，不让图标被键盘切掉
            ViewThatFits(in: .vertical) {
                VStack(spacing: 10) {
                    Image(systemName: "text.bubble")
                        .font(.system(size: compactLines ? 36 : 44, weight: .light))
                        .foregroundStyle(Theme.fg.opacity(0.22))
                    hint
                }
                hint
            }
            .padding(.horizontal, 16)
            .padding(.top, previewInset)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .offset(x: -previewShift)
            .accessibilityHidden(true)
        } else if quiet, session.turns.isEmpty {
            Color.clear.accessibilityHidden(true)
        } else if showsEmptyState {
            VStack(spacing: 14) {
                emptyState
                noticeBanner
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: hintAtMic ? .bottom : .center)
            .padding(.bottom, hintAtMic ? 12 : 0)
        } else {
            ScrollViewReader { proxy in
                let follow = self.follow          // 一次渲染只算一次
                let topHeld = holdsReadingAnchor && overflows
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 14) {
                        if showsPreview, side == .them, !session.previewDraft.isEmpty {
                            PreviewLine(preview: session.preview, language: language)
                        } else {
                            ForEach(visibleTurns) { turn in
                                LineRow(session: session, side: side, turn: turn,
                                        isCurrent: turn.id == session.currentTurn?.id, onExpand: onExpand)
                            }
                        }
                        noticeBanner
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 8)
                    .padding(.trailing, 8)         // 给右边的进度条留位置
                }
                // 平时贴底（最新的离麦克风最近）；长译文跟读时贴顶，读完后也不切回去：
                // 译文出现、长高的时候视口不会被带着滑向结尾，读完也不会跳。
                .defaultScrollAnchor(topHeld ? .top : .bottom)
                // 跟读时底部留出一条，让左下角的句数标签不压住最后一行字
                .contentMargins(.bottom, topHeld ? 34 : 0, for: .scrollContent)
                .scrollBounceBehavior(.basedOnSize)
                // 远离麦克风的一端渐隐，提示"上面还有内容，可以滑动"，而不是生硬地截断
                .mask(alignment: .top) {
                    VStack(spacing: 0) {
                        LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: BodyCount.noMask ? 0 : 28)
                        Rectangle()
                        // 跟读时下端也渐隐：下面还有没读的句子，不要被生硬截断（高度渐变，不是突然出现）
                        LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                            .frame(height: follow != nil ? 24 : 0)
                    }
                    .animation(reduceMotion ? .reduced : .easeOut(duration: 0.3), value: follow != nil)
                }
                .onScrollGeometryChange(for: Bool.self) { $0.contentSize.height > $0.containerSize.height + 1 } action: { _, new in
                    overflows = new
                }
                .onScrollPhaseChange { _, phase in
                    if phase == .interacting, follow != nil {
                        userScrolled = true
                        resumeTask?.cancel()
                    } else if phase == .idle, userScrolled {
                        // 手停下 4 秒后自动回到当前句（不用非得去点"回到当前句"）
                        resumeTask?.cancel()
                        resumeTask = Task {
                            try? await Task.sleep(for: .seconds(4))
                            guard !Task.isCancelled, userScrolled, let id = self.follow?.id else { return }
                            userScrolled = false
                            scroll(proxy, to: id)
                        }
                    }
                }
                .onChange(of: follow?.id, initial: true) { old, new in
                    guard let new else { return }
                    holdsReadingAnchor = true
                    if old == nil { userScrolled = false }
                    guard !userScrolled else { return }
                    scroll(proxy, to: new, animated: old != nil)      // 刚开始读：直接定位，之后一句句滑
                }
                .onChange(of: arrivalTarget) { _, new in
                    guard let new else { return }
                    holdsReadingAnchor = true
                    userScrolled = false
                    scroll(proxy, to: new, animated: false)
                }
                .onChange(of: session.turns.count) { _, _ in
                    holdsReadingAnchor = false       // 新一轮开始 / 对话被清空：回到平时的贴底
                    userScrolled = false
                    resumeTask?.cancel()
                }
                .overlay(alignment: .trailing) {
                    if let follow, follow.count > 1 { ReadingRail(fraction: follow.fraction).transition(.opacity) }
                }
                .overlay(alignment: .bottomLeading) {
                    // 读到第几句 / 共几句：窗口跟着滚时行内的状态行会滚出去，所以固定在角上
                    if let follow, follow.count > 1 {
                        HStack(spacing: 5) {
                            Image(systemName: "speaker.wave.2.fill")
                            Text("\(follow.index + 1) / \(follow.count)").monospacedDigit()
                                .contentTransition(reduceMotion ? .opacity : .numericText())
                        }
                        .font(Theme.label)
                        .foregroundStyle(Theme.sub)
                        .padding(.horizontal, 10)
                        .frame(height: 26)
                        .glass(in: Capsule())
                        .padding(.leading, 19)
                        .transition(.opacity)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(String(localized: "朗读进度 \(follow.index + 1) / \(follow.count)"))
                    }
                }
                .overlay(alignment: .bottom) {
                    if userScrolled, let follow {
                        Button { userScrolled = false; resumeTask?.cancel(); scroll(proxy, to: follow.id) } label: {
                            Label("回到当前句", systemImage: "arrow.down")
                                .font(.system(.footnote).weight(.semibold))
                                .foregroundStyle(Theme.fg)
                                .padding(.horizontal, 14)
                                .frame(minHeight: 44)
                                .glass(in: Capsule(), interactive: true)
                        }
                        .buttonStyle(.plain)
                        .transition(.opacity)
                    }
                }
                .animation(reduceMotion ? .reduced : .easeOut(duration: 0.2), value: userScrolled)
                // 进度条 / 句数标签随"开始读 / 读完"淡入淡出；句数数字滚动着换
                .animation(reduceMotion ? .reduced : .easeOut(duration: 0.25), value: follow.map { $0.count > 1 })
                .animation(reduceMotion ? .reduced : .easeOut(duration: 0.2), value: follow?.index)
            }
        }
    }

    // MARK: 空状态（M1）

    /// 空状态的字号跟着系统走，但放不下就退一档（AX1 → xxxLarge → large）：
    /// 外屏的半屏很矮，辅助功能字号下对方那侧的英文标题和说明原来各被截成一行「…」
    private var emptyState: some View {
        ViewThatFits(in: .vertical) {
            emptyStateBody.dynamicTypeSize(...DynamicTypeSize.accessibility1)
            emptyStateBody.dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            emptyStateBody.dynamicTypeSize(...DynamicTypeSize.large)
        }
        .accessibilityElement(children: .combine)
    }

    private var emptyStateBody: some View {
        VStack(spacing: 6) {
            Text(Strings.emptyTitle(language))
                .font(.system(.title3).weight(.semibold))
                .foregroundStyle(Theme.fg)
                .multilineTextAlignment(.center)
            Text(Strings.emptyHint(language))
                .font(Theme.caption)
                .foregroundStyle(Theme.sub)
                .multilineTextAlignment(.center)
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .fixedSize(horizontal: false, vertical: true)          // 按完整换行后的高度量：ViewThatFits 才知道这一档放不放得下
    }

    // MARK: 麦克风

    private var mic: some View {
        MicButton(
            speaker: side,
            appearance: micAppearance,
            onTap: { if permissionBlocked { PermissionCenter.openSystemSettings() } else { session.micTapped(side) } },
            onHoldBegan: { permissionBlocked ? false : session.holdBegan(side) },
            onHoldPromotedToTap: { session.holdPromotedToTap(side) },
            onHoldEnded: { session.holdEnded(side) },
            onTouchDown: { session.prepareToListen() }
        )
        .frame(maxWidth: .infinity)
    }

    private var micAppearance: MicButton.Appearance {
        if permissionBlocked { return .blocked }
        switch session.phase {
        case .listening(let who): return who == side ? .listening : .dimmed
        default:
            // E1：没听清时麦克风变成错误态
            if case .noSpeech(let who) = session.notice, who == side { return .error }
            return .idle
        }
    }

    // MARK: 提示条（E1 没听清 / E3 权限被拒）

    @ViewBuilder
    private var noticeBanner: some View {
        switch session.notice {
        case .recognizerUnavailable(let reason) where side == .me:
            NoticeBanner(icon: "exclamationmark.triangle", text: Text(reason), color: Theme.warn)
        default:
            EmptyView()
        }
    }
}

/// 屏幕很矮时（横着拿 + 键盘占掉大半）预览 / 对话用小一档的字。
private struct CompactLinesKey: EnvironmentKey { static let defaultValue = false }
private struct PreviewLargeKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var compactLines: Bool {
        get { self[CompactLinesKey.self] }
        set { self[CompactLinesKey.self] = newValue }
    }
    /// 横向打字且屏幕够高：对方看到的预览放大到 34（对着对方、隔着桌子也读得清）
    var previewLarge: Bool {
        get { self[PreviewLargeKey.self] }
        set { self[PreviewLargeKey.self] = newValue }
    }
}

// MARK: - 一条对话（说话人圆点 + 文字，不放进卡片）

private struct LineRow: View {
    let session: ConversationSession
    let side: Speaker
    let turn: Turn
    let isCurrent: Bool
    let onExpand: (BigDisplayRequest) -> Void

    @Environment(\.modelContext) private var context
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.compactLines) private var compactLines
    @State private var saved = false
    /// 点收藏的次数：弹跳由点按触发，不是由 `saved` 触发（视图重建时 onAppear 会把 saved 从 false 置成 true，星标会无故弹一下）
    @State private var saveTick = 0
    /// 点点刚被译文换掉时再留一会儿，和译文交叉淡入（版面一次到位，不做高度动画）
    @State private var lingeringDots = false
    @State private var showedDots = false
    // 字号用"具体数值 + 随系统字号缩放"而不是文字样式：数值字号可以插值，上一轮从大变小才能平滑过渡
    @ScaledMetric(relativeTo: .title) private var bigSize: CGFloat = 28
    @ScaledMetric(relativeTo: .title2) private var midSize: CGFloat = 22
    @ScaledMetric(relativeTo: .body) private var smallSize: CGFloat = 17
    private var isHugeType: Bool { dynamicTypeSize >= .accessibility2 }

    private var language: LanguageOption { session.language(of: side) }
    private var dotColor: Color { turn.speaker == .me ? Theme.meDot : Theme.themDot }
    private var accent: Color { turn.speaker == .me ? Theme.meText : Theme.themText }
    private var isSpeakerSide: Bool { turn.speaker == side }
    /// 这一轮自己的原文语言（收藏为短语时用它，不用「现在的我的语言」——互换 / 换语言之后会存错）
    private var turnLanguage: LanguageOption { LanguageOption.with(id: turn.fromID) ?? session.me }
    private var text: String { session.text(of: turn, on: side) ?? "" }

    var body: some View {
        let _ = BodyCount.hit("LineRow")
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(dotColor)
                .frame(width: isCurrent ? 12 : 9, height: isCurrent ? 12 : 9)
                .padding(.top, isCurrent ? 13 : 8)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 6) {
                if isCurrent, isSpeakerSide, turn.state == .listening {
                    StateChip(text: Strings.listening(language), color: accent)
                }

                content

                if isCurrent { extras }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // 新一轮出现时，上一轮从大号粗体平滑缩成小字（字号、圆点、位置一起走 0.3 秒）
        .animation(reduceMotion ? nil : .smooth(duration: 0.3), value: isCurrent)
        // 对话文字作为独立元素读出（带说话人），下面的操作按钮保持各自可操作
        .accessibilityElement(children: .contain)
        // 只有「我」这一侧的操作行用得到 saved：别的行（以及每次视图重建）不做 SwiftData 查询
        .onChange(of: showsActionBlock, initial: true) { _, on in
            if on { saved = PhraseLibrary.contains(text: turn.sourceText, language: turnLanguage, in: context) }
        }
    }

    private var isThinking: Bool {
        guard text.isEmpty else { return false }
        if case .failed = turn.state { return false }
        if turn.state == .listening, isSpeakerSide { return false }      // 还没听到内容：只显示状态条和声波
        return true
    }

    @ViewBuilder
    private var content: some View {
        // 点点和译文叠在同一个位置：译文出现时点点 0.15 秒淡出、译文 0.25 秒淡入
        ZStack(alignment: .topLeading) {
            if !text.isEmpty { textBody }
            if isThinking || lingeringDots {
                // 淡出的那一小会儿点点不再跳（paused），不是一边变淡一边还在动
                ThinkingDots(paused: !isThinking).padding(.vertical, 10).transition(.opacity)
            }
        }
        .onChange(of: isThinking, initial: true) { _, thinking in
            if thinking { showedDots = true }
        }
        .onChange(of: text.isEmpty) { _, empty in
            guard !empty, showedDots else { return }
            showedDots = false
            lingeringDots = true
            Task {
                try? await Task.sleep(for: .milliseconds(60))
                withAnimation(reduceMotion ? .reduced : .easeOut(duration: 0.15)) { lingeringDots = false }
            }
        }
    }

    @ViewBuilder
    private var textBody: some View {
        // 译文这一侧：当前轮和上一轮用同一个视图，只改字号 / 颜色，这样新一轮出现时上一轮的字号是真正的平滑过渡
        // （换成另一种视图的话，系统只能交叉淡化，会有叠影）。
        if !isSpeakerSide {
            // 只有刚翻译出来的这一句才淡入：看过「思考点」的这一行（点点被译文换掉，自动朗读关着时状态直接是 done 也一样）；\n            // 视图被重建（键盘开合、翻页）时没有看过点点，直接显示，不重放淡入
            sentenceFlow.fadeInOnAppear(reduceMotion: reduceMotion, animated: isCurrent && showedDots)
        } else {
            Text(text)
                .font(isCurrent ? lineFont : oldFont)
                .foregroundStyle(isCurrent ? Theme.fg : Theme.sub)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel(turn.speaker == .me ? Text("我说：\(text)") : Text("对方说：\(text)"))
        }
    }

    private var oldFont: Font { .system(size: smallSize, weight: .medium) }

    /// 长一点的译文用小一档的字，窄屏（Duo 外屏）上才能同时看到当前句和下一句。
    /// 按"加权长度"算（汉字 / 假名 / 谚文算 2，其余算 1），中英文才公平；
    /// 说话的人自己的那一半屏在还没说完时不换字号——边说边变大小会跳。
    private var lineFont: Font {
        if isSpeakerSide, turn.state == .listening { return .system(size: compactLines ? midSize : bigSize, weight: .bold) }
        return .system(size: (compactLines || TextMetrics.weightedLength(text) > 60) ? midSize : bigSize, weight: .bold)
    }

    private var spokenOffset: Int? { session.speakingTurnID == turn.id ? session.spokenOffset : nil }

    /// 译文按句分段：朗读时已读的句子变淡、当前句里读到的词变亮、后面的句子等着；读完后整段恢复。
    /// 句子之间的明暗变化是 0.3 秒的渐变（见 `SentenceText`）。
    private var sentenceFlow: some View {
        let sentences = Sentences.split(text)
        let offset = spokenOffset
        let current = offset.map { Sentences.index(containing: $0, in: sentences) }
        return VStack(alignment: .leading, spacing: isCurrent ? 6 : 3) {
            ForEach(sentences, id: \.index) { sentence in
                SentenceText(
                    sentence: sentence,
                    phase: phase(of: sentence, current: current),
                    spokenLocal: offset.map { $0 - sentence.start } ?? 0,
                    font: isCurrent ? lineFont : oldFont,
                    color: isCurrent ? Theme.fg : Theme.sub,
                    animated: !reduceMotion)
                .id(Sentences.id(turn: turn.id, index: sentence.index))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(turn.speaker == .me ? Text("我说：\(text)") : Text("对方说：\(text)"))
    }

    private func phase(of sentence: TextSentence, current: Int?) -> SentenceText.Phase {
        guard let current else { return .plain }
        if sentence.index < current { return .past }
        return sentence.index == current ? .current : .upcoming
    }

    /// 我这一轮的操作行（重新翻译 / 复制 / 收藏 / 全屏）：翻译完成才可用，但位置从翻译开始就预留好（透明），
    /// 出现时只淡入 0.2s，上面的文字不会被顶高一个按钮的高度（动画稿第 7 项）。
    private var showsActionBlock: Bool {
        guard isSpeakerSide, side == .me else { return false }
        switch turn.state {
        case .translating, .speaking, .done: return true
        default: return false
        }
    }

    private func actionBlock(visible: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 18) {
                retranslateControl
                    .disabled(session.phase != .idle)          // 正在朗读 / 翻译时 retranslate 会直接拒绝：按钮不能看着能点却没反应
                    .opacity(session.phase != .idle ? 0.4 : 1)
                actionButton("doc.on.doc", label: Text("复制")) { session.copyText(of: turn, side: side); Haptics.light() }
                actionButton(saved ? "star.fill" : "star", label: Text(saved ? "已收藏为短语" : "收藏为短语")) {
                    if PhraseLibrary.add(text: turn.sourceText, translated: turn.translatedText, language: turnLanguage, in: context) {
                        saved = true
                        saveTick += 1
                        Haptics.success()
                    }
                }
                .symbolEffect(.bounce, value: reduceMotion ? 0 : saveTick)
                actionButton("arrow.up.left.and.arrow.down.right", label: Text("全屏展示")) {
                    onExpand(BigDisplayRequest(text: turn.sourceText, translation: turn.translatedText, fromID: turn.fromID, toID: turn.toID))
                }
            }
            // E4：超大字号下副文（引擎、耗时）先收起，避免挤占当前这一句
            if !isHugeType, !compactLines, captionText != nil || !visible {      // 横屏很矮的半屏：不放这行小字，把空间还给当前这一句
                Text(captionText ?? " ").font(Theme.caption).foregroundStyle(Theme.mut)
            }
        }
        .opacity(visible ? 1 : 0)
        .allowsHitTesting(visible)
        .accessibilityHidden(!visible)
        .animation(reduceMotion ? .easeInOut(duration: 0.12) : .easeOut(duration: 0.2), value: visible)
    }

    @ViewBuilder
    private var extras: some View {
        if showsActionBlock {
            actionBlock(visible: turn.state != .translating)
        } else {
            otherExtras
        }
    }

    @ViewBuilder
    private var otherExtras: some View {
        switch turn.state {
        case .listening where isSpeakerSide:
            EmptyView()            // 声光替代了声波条
        case .listening where side == .me:
            Text(Strings.partnerSpeaking(language)).font(Theme.caption).foregroundStyle(Theme.mut)
        case .speaking where !isSpeakerSide && Sentences.split(text).count <= 1:
            HStack(spacing: 6) {
                Image(systemName: "speaker.wave.2.fill")
                Text(Strings.speaking(language))
            }
            .font(Theme.label)
            .foregroundStyle(Theme.sub)
        case .failed(let reason):
            VStack(alignment: .leading, spacing: 6) {
                Text(reason).font(Theme.caption).foregroundStyle(Theme.err)
                if !turn.sourceText.isEmpty {
                    Text(turn.sourceText).font(Theme.oldLine).foregroundStyle(Theme.sub)
                }
                actionButton("arrow.clockwise", label: Text(Strings.retry(language))) { session.retranslate(turn.id) }
            }
        default:
            EmptyView()
        }
    }

    private var captionText: String? {
        guard let stored = turn.engineName else { return nil }
        let engine = EngineDisplay.name(for: stored)
        if let latency = turn.latency {
            let seconds = latency.formatted(.number.precision(.fractionLength(1)))
            let base = String(localized: "\(engine) · \(seconds) 秒")
            return base
        }
        return engine
    }

    private var retranslateControl: some View {
        actionButton("arrow.clockwise", label: Text("重新翻译")) { session.retranslate(turn.id) }
    }

    private func actionButton(_ symbol: String, label: Text, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17))
                .foregroundStyle(Theme.sub)
                .frame(width: 44, height: compactLines ? 36 : 44, alignment: .leading)
                .contentShape(Rectangle().inset(by: compactLines ? -4 : 0))      // 横屏很矮的半屏按钮 36pt，点按区域补到 44pt
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

// MARK: - 键盘输入的译文预览

private struct PreviewLine: View {
    let preview: Preview
    let language: LanguageOption
    @Environment(\.compactLines) private var compactLines
    @Environment(\.previewLarge) private var previewLarge
    @ScaledMetric(relativeTo: .title) private var baseSize: CGFloat = 28
    @ScaledMetric(relativeTo: .largeTitle) private var largeSize: CGFloat = 34
    @ScaledMetric(relativeTo: .title2) private var midSize: CGFloat = 24

    /// 预览字号：矮屏 24；横向打字 34（长了缩到 24）；其余 28
    private func size(for text: String) -> CGFloat {
        if compactLines { return midSize }
        if previewLarge { return TextMetrics.weightedLength(text) > 60 ? midSize : largeSize }
        return baseSize
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(Theme.meDot)
                .frame(width: 12, height: 12)
                .padding(.top, 13)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                StateChip(text: Strings.previewChip(language), color: Theme.meText, showsDot: false)          // 行首已经有说话人圆点，标签里不再放第二个
                switch preview {
                case .ready(let text):
                    Text(text)
                        .font(.system(size: size(for: text), weight: .bold))
                        .foregroundStyle(Theme.fg)
                        .fixedSize(horizontal: false, vertical: true)
                case .failed:
                    Text("预览翻译失败，仍然可以发送")
                        .font(Theme.caption)
                        .foregroundStyle(Theme.err)
                case .idle, .loading:
                    ThinkingDots().padding(.vertical, 10)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - 小组件

private struct StateChip: View {
    let text: String
    let color: Color
    var showsDot = true

    var body: some View {
        HStack(spacing: 6) {
            if showsDot { Circle().fill(color).frame(width: 6, height: 6) }
            Text(text)
        }
        .font(Theme.label)
        .foregroundStyle(Theme.fg)            // 文字不用粉红；圆点和底色保留说话人颜色
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(color.opacity(0.14), in: Capsule())
    }
}

private struct NoticeBanner: View {
    let icon: String
    let text: Text
    let color: Color
    var actions: [(title: String, run: () -> Void)] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: icon).foregroundStyle(color)
                text.font(Theme.caption).foregroundStyle(Theme.fg)
            }
            if !actions.isEmpty {
                HStack(spacing: 8) {
                    ForEach(Array(actions.enumerated()), id: \.offset) { index, action in
                        Button(action: action.run) {
                            Text(action.title)
                                .font(.system(.footnote).weight(.semibold))
                                .foregroundStyle(Theme.fg)
                                .padding(.horizontal, 14)
                                .frame(minHeight: 44)
                                .glass(in: Capsule(), tint: index == 0 ? Theme.meFill : nil, interactive: true)
                        }
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glass(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

/// E3 · 权限被拒：说明原因（一句标题 + 一句解释）。出路在麦克风上：它带斜杠、琥珀色外圈，
/// 麦克风旁有"轻点前往设置"；想用键盘，点工具栏 / 控制条上的键盘键（文字翻译不依赖麦克风）。
private struct PermissionDeniedCard: View {
    let isMicrophone: Bool

    var body: some View {
        VStack(spacing: 8) {
            Text(isMicrophone ? "需要麦克风\n才能听你说话" : "需要语音识别\n才能把话转成文字")
                .font(.system(.title3).weight(.bold))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(Theme.fg)
            Text(isMicrophone
                 ? "你之前拒绝了麦克风权限。到系统设置里打开就能继续，音频不会被保存。"
                 : "你之前拒绝了语音识别权限。到系统设置里打开就能继续，优先在设备上完成。")
                .font(Theme.caption)
                .foregroundStyle(Theme.sub)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
    }
}


// MARK: - 译文分句 / 进度条

struct TextSentence: Equatable {
    let index: Int
    let text: String
    /// 在整段译文里的 UTF-16 偏移（和朗读器报告的进度同一把尺）
    let start: Int
}

enum TextMetrics {
    /// 汉字 / 假名 / 谚文 / 全角符号算 2，其余算 1：同样的版面宽度里，一个汉字约等于两个拉丁字母。
    static func weightedLength(_ text: String) -> Int {
        text.unicodeScalars.reduce(0) { total, scalar in
            switch scalar.value {
            case 0x2E80...0x9FFF, 0xAC00...0xD7AF, 0xFF00...0xFFEF, 0x20000...0x2FFFF: return total + 2
            default: return total + 1
            }
        }
    }
}

@MainActor
enum Sentences {
    /// 朗读时每读一个词界面都要刷新，同一段译文反复分句很浪费：记住最近几段。
    private static var cache: [String: [TextSentence]] = [:]

    static func split(_ text: String) -> [TextSentence] {
        if let hit = cache[text] { return hit }
        let result = compute(text)
        if cache.count >= 12 { cache.removeAll() }
        cache[text] = result
        return result
    }

    private static func compute(_ text: String) -> [TextSentence] {
        var result: [TextSentence] = []
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: .bySentences) { sub, range, _, _ in
            guard let sub, !sub.isEmpty else { return }
            result.append(TextSentence(index: result.count, text: sub, start: NSRange(range, in: text).location))
        }
        return result.isEmpty ? [TextSentence(index: 0, text: text, start: 0)] : result
    }

    /// 读到 `offset`（刚读完的词的结尾）时正在读第几句。
    static func index(containing offset: Int, in sentences: [TextSentence]) -> Int {
        let probe = max(0, offset - 1)
        return sentences.last(where: { $0.start <= probe })?.index ?? 0
    }

    static func id(turn: Turn.ID, index: Int) -> String { "\(turn)#\(index)" }
}

/// 一句译文，逐字画不透明度（`SweepRenderer`）：读到的地方像扫过去一样一个字一个字亮起，
/// 前沿有两三个字的渐变；句子在"等着 / 正在读 / 已读"之间的明暗变化是 0.3 秒的缓出。
private struct SentenceText: View {
    enum Phase { case plain, past, current, upcoming }
    let sentence: TextSentence
    let phase: Phase
    let spokenLocal: Int
    let font: Font
    var color: Color = Theme.fg
    let animated: Bool

    private var glyphs: Int { sentence.text.count }

    /// 已读到第几个字（连续值，朗读器每报一次词就把目标往前挪，动画把中间补上）
    private var spoken: Double {
        switch phase {
        case .past: return Double(glyphs) + 3
        case .current:
            let local = min(max(0, spokenLocal), sentence.text.utf16.count)
            let idx = String.Index(utf16Offset: local, in: sentence.text)
            return Double(sentence.text.distance(from: sentence.text.startIndex, to: idx))
        default: return 0
        }
    }

    private var base: Double {
        switch phase {
        case .plain: 1
        case .past: 0.4
        case .current, .upcoming: 0.7
        }
    }

    var body: some View {
        Text(sentence.text)
            .font(font)
            .foregroundStyle(color)
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
            .textRenderer(SweepRenderer(spoken: spoken, base: base, lit: phase == .current ? 1 : 0))
            // 词与词之间：线性补间，扫过去的感觉；状态切换（后写的）盖过它，用 0.3 秒缓出
            .animation(animated ? .linear(duration: 0.22) : nil, value: spoken)
            .animation(animated ? .easeOut(duration: 0.3) : nil, value: phase)
    }
}

/// 逐字不透明度：第 i 个字的不透明度 = base + (1 - base) × lit × clamp((spoken - i) / 2.5)。
/// `spoken` / `base` / `lit` 都可插值，所以扫过去、变淡都是连续的。
private struct SweepRenderer: TextRenderer {
    var spoken: Double
    var base: Double
    var lit: Double

    var animatableData: AnimatablePair<Double, AnimatablePair<Double, Double>> {
        get { AnimatablePair(spoken, AnimatablePair(base, lit)) }
        set { spoken = newValue.first; base = newValue.second.first; lit = newValue.second.second }
    }

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        var index = 0
        for line in layout {
            for run in line {
                // 从右往左的文字：屏幕上的字形顺序和"读的顺序"相反，按逻辑顺序编号，扫过才不会反着走
                let slices = Array(run)
                let rtl = run.layoutDirection == .rightToLeft
                for (visual, slice) in slices.enumerated() {
                    let logical = index + (rtl ? slices.count - 1 - visual : visual)
                    let ramp = min(1, max(0, (spoken - Double(logical)) / 2.5))
                    var glyph = context
                    glyph.opacity = base + (1 - base) * lit * ramp
                    glyph.draw(slice)
                }
                index += slices.count
            }
        }
    }
}

/// 窗口右边缘的细进度条：整段译文读了多少。
private struct ReadingRail: View {
    let fraction: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        GeometryReader { geo in
            Capsule().fill(Theme.fg.opacity(0.14))
                .overlay(alignment: .top) {
                    Capsule().fill(Theme.fg.opacity(0.55)).frame(height: geo.size.height * fraction)
                        .animation(reduceMotion ? nil : .linear(duration: 0.25), value: fraction)
                }
        }
        .frame(width: 3)
        .padding(.vertical, 28)
        .accessibilityHidden(true)
    }
}


private struct FadeInOnAppear: ViewModifier {
    let reduceMotion: Bool
    let animated: Bool
    @State private var shown: Bool
    init(reduceMotion: Bool, animated: Bool) {
        self.reduceMotion = reduceMotion
        self.animated = animated
        _shown = State(initialValue: !animated)
    }
    func body(content: Content) -> some View {
        // 只渐变透明度、不动布局：版面一次到位，滚动位置才不会被"长高"的动画带偏
        content.opacity(shown ? 1 : 0).onAppear {
            guard !shown else { return }
            withAnimation(reduceMotion ? .reduced : .easeOut(duration: 0.25)) { shown = true }
        }
    }
}

extension View {
    fileprivate func fadeInOnAppear(reduceMotion: Bool, animated: Bool = true) -> some View {
        modifier(FadeInOnAppear(reduceMotion: reduceMotion, animated: animated))
    }
}

/// 这半屏的人正在说话（聆听）时才有的光晕。单独成视图：`session.levels` 每个音频缓冲（约 47 次 / 秒）都变，
/// 原来在 HalfView.body 里读它，整个半屏（文字、跟读、各行）都跟着每秒重新求值 47 次；现在只有光晕自己重算。
private struct ListeningGlow: View {
    let session: ConversationSession
    let side: Speaker
    let micPlacement: FaceGeometry.MicPlacement
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isListeningHere: Bool {
        // 同声传译时这页被遮在下面，光晕不用画：否则整场会议 47Hz 地重画一个看不见的光晕
        if session.isEavesdropping { return false }
        if case .listening(let who) = session.phase { return who == side }
        return false
    }

    var body: some View {
        // 只给光晕自己做淡入淡出（动画不再罩住整个半屏的布局）
        ZStack {
            if isListeningHere {
                let recent = session.levels.suffix(4).max() ?? 0
                GeometryReader { geo in
                    // 麦克风中心：竖向半屏 = 底部正中；横向半屏 = 右下角（离右边 20 + 52，离底边 52）
                    let source = micPlacement == .bottom
                        ? CGPoint(x: geo.size.width / 2, y: geo.size.height - 52)
                        : CGPoint(x: geo.size.width - 20 - 52, y: geo.size.height - 52)
                    MicGlow(color: side == .me ? Theme.meFill : Theme.themFill, level: CGFloat(recent), source: source, size: geo.size)
                }
                // 光晕从麦克风那一角「绽开」：0.85 倍放大到 1 倍的同时淡入；减少动态效果时只淡入
                .transition(reduceMotion ? .opacity
                            : .opacity.combined(with: .scale(scale: 0.85, anchor: micPlacement == .bottom ? .bottom : .bottomTrailing)))
            }
        }
        .animation(reduceMotion ? .reduced : .smooth(duration: 0.3), value: isListeningHere)
    }
}
