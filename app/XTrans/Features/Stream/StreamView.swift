import SwiftData
import SwiftUI

/// T1 · 对话流：对话的"记录"视图。每条消息是"主文 + 副文"：
/// 我的消息主文是原话、对方的消息主文是译文（都是我能读懂的语言）。
struct StreamView: View {
    let session: ConversationSession
    var isOnline = true
    let onBack: () -> Void
    let onOpenHistory: () -> Void
    var onAdd: () -> Void = {}
    var onBigDisplay: (BigDisplayRequest) -> Void = { _ in }
    /// 展开态的输入入口统一进入独立的编辑 / 预览页。
    var onKeyboard: (() -> Void)?
    /// 宽屏里工具面板就在旁边，不需要底栏的＋
    var showsAddButton = true
    /// 宽屏：系统工具栏由外层（整屏）接管，这里不再自带；`barsOnSide` = 系统已把返回 / 分享竖排在右侧
    var toolbarHandledByParent = false
    var barsOnSide = false
    /// 宽屏左栏：64pt 页头（标题 + 元信息 + ⋯ 菜单），和右栏"工具"的页头同一条线
    var wideHeader = false
    /// 底部输入栏（方案二里左屏只读，输入在右屏）
    var showsInputBar = true
    /// 页头的 ⋯（重命名 / 分享）：只读的对话窗格（设置 / 历史 / 键盘输入时的第一块屏）不需要
    var showsHeaderMenu = true
    /// Duo 内屏竖放：页头右边是「＋ 加入对话」和「⋯ 更多（历史 / 键盘输入 / 设置 / 重命名 / 分享）」，
    /// 页面里不再画这些按钮（和横放竖栏里是同一组动作）
    var headerActions = false
    /// 底部给浮在对话上的说话区让出的高度（输入栏在它上面）
    var bottomReserve: CGFloat = 0
    /// 在消息末尾显示"正在输入、还没发送"的预览气泡（方案二的键盘输入）
    var showsPreview = false
    /// 输入条上沿在窗口里的位置（键盘输入时）：消息列表被它和键盘盖住的那一截用底部留白让出来，最后一条和预览气泡停在输入条上方
    var coverTop: CGFloat?
    /// 直板 iPhone 竖屏（设计稿 T1）：顶部是「‹ ｜ 面对面｜对话流 ｜ 分享」；没有系统标签栏
    var topSegment = false
    /// 外部（竖栏菜单里的「重命名对话」）请求重命名：值变一次就弹一次
    var renameRequest = 0
    /// 消息列表底部要让开的高度（Duo 内屏横放的说话坞浮在列表下方：列表滚到底时最后一条停在它上面，往上滚时从它后面穿过）
    var bottomInset: CGFloat = 0
    /// 宽页头最右边的设置齿轮（说话坞版式里设置只剩这一个入口）
    var onSettings: (() -> Void)?

    @Environment(\.modelContext) private var context
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var editingID: Turn.ID?
    @State private var editText = ""
    @State private var renamingTitle = false
    @State private var titleText = ""
    @Environment(\.inDuoPane) private var inDuoPane
    /// 消息列表顶端被滚到下面的高度（驱动顶端渐隐）
    @State private var scrolledUnderTop: CGFloat = 0
    /// 消息列表下沿在窗口里的位置
    @State private var listBottom: CGFloat = 0
    @State private var listBottomWindow: CGSize = .zero
    @State private var toast: LocalizedStringKey?
    /// 当前 Toast 的收起计时：再弹一个时先取消旧的，不然第二个会被第一个的计时器提前收掉
    @State private var toastTask: Task<Void, Never>?

    var body: some View {
        let _ = BodyCount.hit("StreamView")
        if toolbarHandledByParent {
            streamBody(vertical: barsOnSide)
        } else {
            SideBarHost(pushOwner: .stream) { vertical in
                streamBody(vertical: vertical)
            } items: {
                // Duo 外屏 / 内屏横向：返回、历史、分享交给系统竖排工具栏
                StreamToolbar(session: session, onBack: onBack, onOpenHistory: onOpenHistory,
                              onAdd: showsAddButton ? onAdd : nil)
            }
        }
    }

    private func streamBody(vertical: Bool) -> some View {
        VStack(spacing: 0) {
            if wideHeader {
                wideHeaderRow(vertical: vertical)
            } else {
                navigationBar(vertical: vertical)
                // 系统字号调到"辅助功能"档位时标题很占地方：让它跟着消息一起滚动，把空间还给消息
                if !typeSize.isAccessibilitySize { header }
            }
            if !isOnline { offlineBanner.riseTransition(reduceMotion: reduceMotion) }
            messages
            if showsInputBar {
                InputBar(session: session, showsAddButton: showsAddButton && !vertical, onAdd: onAdd, onKeyboard: onKeyboard)
                    // 输入条（`ComposerDock`）开着：这条入口让位。平时它在键盘后面看不到；接了实体键盘时输入条落在屏幕底，会和它叠在一起
                    .opacity(showsPreview ? 0 : 1)
                    .allowsHitTesting(!showsPreview)
                    .accessibilityHidden(showsPreview)
                    .animation(showsPreview ? .easeOut(duration: 0.12) : .smooth(duration: 0.28).delay(0.08), value: showsPreview)
            }
            if bottomReserve > 0 { Color.clear.frame(height: bottomReserve) }
        }
        .riseAnimation(value: isOnline, reduceMotion: reduceMotion)
        .onChange(of: renameRequest) { _, _ in
            titleText = session.title
            renamingTitle = true
        }
        .background { PageBackground() }
        .toolbarVisibility(topSegment ? .hidden : .automatic, for: .tabBar)     // 顶部分段负责切换，不要系统标签栏
        .overlay(alignment: .bottom) { toastView }
        .paneTextPrompt("重命名对话", prompt: "对话标题", actionTitle: "重命名",
                        isPresented: $renamingTitle, text: $titleText) {
            session.renameConversation(session.conversationID, to: titleText)
        }
        .paneTextPrompt("修正原文", prompt: "原文", actionTitle: "重新翻译",
                        isPresented: Binding(get: { editingID != nil }, set: { if !$0 { editingID = nil } }), text: $editText) {
            if let id = editingID { session.editSource(id, to: editText) }
            editingID = nil
        }
    }

    // MARK: 顶栏

    /// 顶栏。直板竖屏（`topSegment`）：‹ 回到面对面、分段「面对面｜对话流」、分享（设计稿 T1）；
    /// 其他：历史 + 分享（"面对面 / 对话流"的切换由系统标签栏负责）。系统已把工具栏竖排在右侧时（Duo），这里不再重复。
    @ViewBuilder
    private func navigationBar(vertical: Bool) -> some View {
        if topSegment {
            HStack {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Theme.fg)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("面对面")
                Spacer(minLength: 0)
                ModeSegment(selection: .stream, onSelect: { if $0 == .faceToFace { onBack() } })
                Spacer(minLength: 0)
                if session.turns.isEmpty {
                    Color.clear.frame(width: 44, height: 44)
                } else {
                    ShareLink(item: session.transcript()) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 17))
                            .foregroundStyle(Theme.fg)
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("分享对话")
                }
            }
            .padding(.horizontal, 8)
            .frame(minHeight: 44)
        } else if !vertical {
            HStack {
                Button(action: onOpenHistory) {
                    Image(systemName: BarSymbol.history)
                        .font(.system(size: 17))
                        .foregroundStyle(Theme.fg)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("历史")

                Spacer()

                if !session.turns.isEmpty {
                    ShareLink(item: session.transcript()) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 17))
                            .foregroundStyle(Theme.fg)
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("分享对话")
                }
            }
            .padding(.horizontal, 8)
            .frame(minHeight: 44)
        }
    }

    /// 宽屏页头：高 64。左边标题 17 半粗 + 元信息 13，右边 ⋯（重命名；系统工具栏没接管时还有分享）。
    private func wideHeaderRow(vertical: Bool) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title)
                    .font(.system(.headline))
                    .foregroundStyle(Theme.fg)
                    .lineLimit(1)
                subtitle
                    .font(Theme.caption)
                    .foregroundStyle(Theme.mut)
                    .lineLimit(1)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            if headerActions {
                Button(action: onAdd) {
                    Image(systemName: BarSymbol.add)
                        .font(.system(size: 17))
                        .foregroundStyle(Theme.fg)
                        .frame(width: 44, height: 44)
                        .glass(in: Circle(), interactive: true)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("加入对话")
                Menu {
                    // 菜单自己收起要 ~0.2s：弹层 / 对话框等它收完再出来，两个动画不叠在一起（和竖栏里的菜单一样）
                    Button { afterMenu(onOpenHistory) } label: { Label("历史", systemImage: BarSymbol.history) }
                    if let onKeyboard { Button { afterMenu(onKeyboard) } label: { Label("键盘输入", systemImage: BarSymbol.keyboard) } }
                    if let onSettings { Button { afterMenu(onSettings) } label: { Label("设置", systemImage: BarSymbol.settings) } }
                    if !session.turns.isEmpty {
                        Button {
                            afterMenu {
                                titleText = session.title
                                renamingTitle = true
                            }
                        } label: { Label("重命名对话", systemImage: "pencil") }
                        ShareLink(item: session.transcript()) { Label("分享对话", systemImage: "square.and.arrow.up") }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 17))
                        .foregroundStyle(Theme.fg)
                        .frame(width: 44, height: 44)
                        .glass(in: Circle(), interactive: true)
                }
                .accessibilityLabel("更多")
            } else if !session.turns.isEmpty && showsHeaderMenu {
                Menu {
                    Button {
                        titleText = session.title
                        renamingTitle = true
                    } label: { Label("重命名对话", systemImage: "pencil") }
                    if !vertical {
                        ShareLink(item: session.transcript()) { Label("分享对话", systemImage: "square.and.arrow.up") }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 17))
                        .foregroundStyle(Theme.fg)
                        .frame(width: 44, height: 44)
                        .glass(in: Circle(), interactive: true)
                }
                .accessibilityLabel("更多")
            }
            if let onSettings, !headerActions {
                Button(action: onSettings) {
                    Image(systemName: BarSymbol.settings)
                        .font(.system(size: 17))
                        .foregroundStyle(Theme.fg)
                        .frame(width: 44, height: 44)
                        .glass(in: Circle(), interactive: true)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("设置")
            }
        }
        .padding(.horizontal, 20)
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)          // 页头是固定在上面的一条：超大字号下标题 + 元信息会占掉小半屏（Duo 横放只有 669pt 高），封顶一档
        .frame(minHeight: 64)          // 辅助功能大字号下标题 / 元信息会超出 64pt：只设下限，不能把它切到消息上面
    }

    private func afterMenu(_ action: @escaping () -> Void) {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(220))
            action()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(session.title)
                    .font(.system(.title3).weight(.bold))
                    .foregroundStyle(Theme.fg)
                    .lineLimit(1)
                if !session.turns.isEmpty {
                    Button {
                        titleText = session.title
                        renamingTitle = true
                    } label: {
                        Image(systemName: "pencil")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.mut)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("重命名对话")
                }
            }
            subtitle
                .font(Theme.caption)
                .foregroundStyle(Theme.mut)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.top, 4)
        .padding(.bottom, 8)
    }

    /// E5 · 当前离线：翻译在设备上完成，已下载的语言不受影响，只是没下载的语言用不了。
    private var offlineBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "wifi.slash").foregroundStyle(Theme.warn)
            VStack(alignment: .leading, spacing: 2) {
                Text("当前离线").font(.system(.footnote).weight(.semibold)).foregroundStyle(Theme.fg)
                Text("使用设备上的翻译，只支持已下载的语言。").font(Theme.caption).foregroundStyle(Theme.sub)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .glass(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(.horizontal, inDuoPane ? 20 : 16)
        .padding(.bottom, 6)
        .accessibilityElement(children: .combine)
    }

    private var subtitle: Text {
        let day = session.conversationCreatedAt.formatted(date: .abbreviated, time: .shortened)
        return Text("\(day) · \(session.me.nativeName) ⇄ \(session.them.nativeName) · \(session.turns.count) 条")
    }

    // MARK: 消息列表

    private var messages: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    if typeSize.isAccessibilitySize && !wideHeader { header.padding(.horizontal, -4) }          // 宽页头已经自己画了标题：不再在列表里重复一遍
                    if session.turns.isEmpty {
                        emptyState
                    }
                    ForEach(session.turns) { turn in
                        MessageRow(session: session, turn: turn, onEdit: {
                            editText = turn.sourceText
                            editingID = turn.id
                        }, onFavorite: { favorite(turn) }, onExpand: {
                            onBigDisplay(BigDisplayRequest(text: turn.sourceText, translation: turn.translatedText, fromID: turn.fromID, toID: turn.toID))
                        })
                        .id(turn.id)
                        .riseTransition(reduceMotion: reduceMotion)
                    }
                    if let notice = session.notice {
                        StreamNotice(notice: notice)
                            .riseTransition(reduceMotion: reduceMotion)
                    }
                    if showsPreview, !session.previewDraft.isEmpty {
                        draftPreview.riseTransition(reduceMotion: reduceMotion)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                // 新气泡 / 提示条 / 预览出现时：整列平滑上移，新的从下方淡入（原来是一帧弹出，其余气泡跟着一跳）
                .riseAnimation(value: session.turns.last?.id, reduceMotion: reduceMotion)      // 按「最后一条是谁」触发：删旧消息 / 载入整场对话不会让所有行各自上浮
                .riseAnimation(value: session.notice, reduceMotion: reduceMotion)
                .riseAnimation(value: showsPreview && !session.previewDraft.isEmpty, reduceMotion: reduceMotion)
                .padding(.horizontal, inDuoPane ? 20 : 16)          // Duo 的屏里和页头 / 设置 / 历史同一条 20pt 边
                .padding(.vertical, 8)
            }
            // 两者取大的那个，不相加：平时让开的说话坞（bottomInset）在键盘输入时本身就在键盘后面
            .contentMargins(.bottom, max(bottomInset, coveredHeight), for: .scrollContent)
            .contentMargins(.bottom, max(bottomInset, coveredHeight), for: .scrollIndicators)
            // 只在平时量：输入条开着时底部留白在变，这时再量会和留白互相推（横放实测每轮 +3pt、主线程空转卡死）。
            // 例外：窗口尺寸变了（转屏 / 折叠）——旧的位置已经不对，允许按新窗口量一次
            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxY.rounded() } action: { bottom in
                let window = DuoLayout.currentWindowSize
                if coverTop == nil || window != listBottomWindow {
                    listBottom = bottom
                    listBottomWindow = window
                }
            }
            .onChange(of: coveredHeight) { _, _ in
                // 输入条 / 键盘升起：贴到底，最后一条和预览气泡不被盖住
                if reduceMotion { proxy.scrollTo("bottom", anchor: .bottom) }
                else { withAnimation(.smooth(duration: 0.3)) { proxy.scrollTo("bottom", anchor: .bottom) } }
            }
            .onChange(of: session.previewDraft) { _, _ in if showsPreview { proxy.scrollTo("bottom", anchor: .bottom) } }
            .scrollDismissesKeyboard(.interactively)
            .dismissKeyboardOnTap()           // 点消息列表的空白处收起键盘
            // 列表顶端在页头下面柔和渐隐：原来第一条气泡被页头下沿一刀切开
            .mask {
                VStack(spacing: 0) {
                    // 渐隐的高度跟着「内容被滚到顶端下面多少」走：内容没填满（只有一两条）时不渐隐，
                    // 否则第一条气泡的上沿被蒙上一层暗影（真机截图「你好」顶上的阴影）
                    LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: min(typeSize.isAccessibilitySize ? 44 : 18, scrolledUnderTop))          // 辅助功能字号下标题跟着消息滚动、字很大：渐隐拉长，不露出被切掉一半的一行
                    Rectangle().fill(.black)
                }
            }
            .onScrollGeometryChange(for: CGFloat.self) { max(0, $0.contentOffset.y + $0.contentInsets.top) } action: { _, new in
                scrolledUnderTop = new
            }
            // 键盘弹出 / 收起（可视区变化）时仍然贴着最新一条，不会被键盘盖住
            .defaultScrollAnchor(.bottom, for: .sizeChanges)
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            // Duo 折叠 / 展开 / 转屏：底部让位的高度变了（说话坞 ⇄ 分屏），列表重新贴底——
            // 页面现在不再被重建，不贴的话最后一条会被说话坞压住
            .onChange(of: bottomInset) { _, _ in Task { @MainActor in proxy.scrollTo("bottom", anchor: .bottom) } }
            .onChange(of: bottomReserve) { _, _ in Task { @MainActor in proxy.scrollTo("bottom", anchor: .bottom) } }
            // 新增一条消息时平滑滚到底；同一条消息的文字更新（识别 / 翻译中）直接贴底，不叠加动画。
            // 只用一个 onChange：原来 count 和 turns 各一个，后者那句不带动画的 scrollTo 会把前者的平滑滚动盖掉。
            .onChange(of: session.turns) { old, new in
                // 只有「恰好在末尾多了一条」才平滑滚动；删旧消息（位置不能被带走）、载入整场对话（在溶解快照下面）都不动画
                let appended = new.count == old.count + 1 && old.last?.id == new.dropLast().last?.id
                if appended {
                    if reduceMotion { proxy.scrollTo("bottom", anchor: .bottom) }
                    else { withAnimation(.rise) { proxy.scrollTo("bottom", anchor: .bottom) } }
                } else if new.last?.id != old.last?.id || new.last?.sourceText != old.last?.sourceText || new.last?.translatedText != old.last?.translatedText {
                    // 只看「是不是同一条 / 文字有没有变」：最后一条从「朗读中」变成「完成」不算（原来会把正在往上翻的列表拽回底部）
                    // 最后一句在变（识别 / 翻译中的文字更新）、或整场对话换了：贴底
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
                // 其余（改的是前面的某一条：重译 / 修正原文 / 播放 / 删除）不动滚动位置——用户正在看的那条不能被甩出屏幕
            }
            .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
        }
    }

    /// 消息列表被输入条 + 键盘盖住的高度
    private var coveredHeight: CGFloat {
        guard let coverTop, listBottom > 0, coverTop < listBottom else { return 0 }
        return listBottom - coverTop + 8
    }

    /// 键盘输入时还没发送的那句：我的原话 + 对方将看到的译文（虚线气泡，"预览 · 未发送"）
    private var draftPreview: some View {
        VStack(alignment: .trailing, spacing: 4) {
            VStack(alignment: .leading, spacing: 4) {
                Text(session.previewDraft)
                    .font(.system(.body).weight(.semibold))
                    .foregroundStyle(Theme.fg)
                if case .ready(let translated) = session.preview {
                    Text(translated)
                        .font(.system(.subheadline))
                        .foregroundStyle(Theme.sub)
                } else if session.preview == .failed {
                    Text("预览翻译失败").font(Theme.caption).foregroundStyle(Theme.err)      // 失败不再一直转圈
                } else if session.previewDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    EmptyView()          // 只有空格：没有可翻译的内容
                } else {
                    ThinkingDots()
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Theme.bubbleMe.opacity(0.55), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Theme.fg.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
            .frame(maxWidth: 320, alignment: .trailing)
            Text("预览 · 未发送")
                .font(Theme.caption)
                .foregroundStyle(Theme.mut)
                .padding(.horizontal, 6)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private func favorite(_ turn: Turn) {
        // 按这一轮自己的语言存（原来按「现在的我的语言」：互换 / 换语言之后存到错的语言下，在短语页里找不到）
        let language = LanguageOption.with(id: turn.fromID) ?? session.me
        let added = PhraseLibrary.add(text: turn.sourceText, translated: turn.translatedText, language: language, in: context)
        show(toast: added ? "已收藏为短语" : "这句已经在短语里了")
        // VoiceOver 看不到屏幕上一闪而过的 Toast：朗读一遍
        AccessibilityNotification.Announcement(added ? String(localized: "已收藏为短语") : String(localized: "这句已经在短语里了")).post()
        if added { Haptics.success() }
    }

    private func show(toast text: LocalizedStringKey) {
        withUIAnimation(reduceMotion: reduceMotion) { toast = text }
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(for: .seconds(1.6))
            guard !Task.isCancelled else { return }
            withUIAnimation(reduceMotion: reduceMotion) { toast = nil }
        }
    }

    @ViewBuilder
    private var toastView: some View {
        if let toast {
            Label(toast, systemImage: "star.fill")
                .font(.system(.footnote).weight(.semibold))
                .foregroundStyle(Theme.fg)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .glass(in: Capsule())
                .padding(.bottom, 90)
                .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(Theme.fg.opacity(0.25))
                .padding(.bottom, 6)
                .accessibilityHidden(true)
            Text("还没有消息")
                .font(.system(.title2).weight(.semibold))
                .foregroundStyle(Theme.fg)
            Text(showsInputBar ? "按麦克风说话，或者在下面打字。" : "按麦克风说话。")
                .font(.system(.callout))
                .foregroundStyle(Theme.sub)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 90)
    }
}

// MARK: - 一条消息

private struct MessageRow: View {
    let session: ConversationSession
    let turn: Turn
    let onEdit: () -> Void
    let onFavorite: () -> Void
    let onExpand: () -> Void

    private var isMe: Bool { turn.speaker == .me }
    /// 主文：我的 = 原话；对方的 = 译文（我读得懂的语言）
    private var mainText: String { (isMe ? turn.sourceText : turn.translatedText) ?? "" }
    private var subText: String { (isMe ? turn.translatedText : turn.sourceText) ?? "" }

    @State private var showingActions = false

    var body: some View {
        let _ = BodyCount.hit("MessageRow")
        VStack(alignment: isMe ? .trailing : .leading, spacing: 4) {
            bubble
            meta
        }
        .frame(maxWidth: .infinity, alignment: isMe ? .trailing : .leading)
    }

    private var bubble: some View {
        VStack(alignment: .leading, spacing: 4) {
            switch turn.state {
            case .listening:
                if turn.sourceText.isEmpty {
                    Text(Strings.listening(session.language(of: turn.speaker)))
                        .font(Theme.label)
                        .foregroundStyle(Theme.sub)           // 文字不用粉红 / 青色，说话人由气泡颜色区分
                } else {
                    Text(turn.sourceText + "▍")
                        .font(.system(.body).weight(.semibold))
                        .foregroundStyle(Theme.fg)
                }
            default:
                // 对方的消息还没出译文时先显示原文，避免气泡是空的
                Text(mainText.isEmpty ? turn.sourceText : mainText)
                    .font(.system(.body).weight(.semibold))
                    .foregroundStyle(Theme.fg)
                if !subText.isEmpty && !mainText.isEmpty {
                    Text(subText)
                        .font(.system(.subheadline))
                        .foregroundStyle(Theme.sub)
                } else if turn.state == .translating {
                    ThinkingDots()
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(isMe ? Theme.bubbleMe : Theme.bubbleThem, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            if case .failed = turn.state {
                RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Theme.err, lineWidth: 1.5)
            }
        }
        .frame(maxWidth: 320, alignment: isMe ? .trailing : .leading)
        .paneContextMenu("更多", isPresented: $showingActions) { menu }
        .accessibilityElement(children: .combine)
        .accessibilityHint("长按查看更多操作")
    }

    @ViewBuilder
    private var menu: some View {
        if turn.translatedText != nil {
            Button { act { session.replay(turn.id) } } label: { Label("播放译文", systemImage: "speaker.wave.2") }
                .disabled(session.phase != .idle)          // 忙的时候 replay / retranslate / 修正 / 删除 都会直接拒绝：别看着能点却没反应
            Button { act { UIPasteboard.general.string = turn.translatedText } } label: { Label("复制译文", systemImage: "doc.on.doc") }
        }
        Button { act { UIPasteboard.general.string = turn.sourceText } } label: { Label("复制原文", systemImage: "doc.on.doc") }
        if isMe, !turn.sourceText.isEmpty {
            Button { act(onFavorite) } label: { Label("收藏为短语", systemImage: "star") }
        }
        if isMe, turn.translatedText != nil {
            Button { act(onExpand) } label: { Label("全屏展示", systemImage: "arrow.up.left.and.arrow.down.right") }
        }
        if !turn.sourceText.isEmpty {
            Button { act(onEdit) } label: { Label("修正原文（识别错了）", systemImage: "pencil") }
                .disabled(session.phase != .idle)
            Button { act { session.retranslate(turn.id) } } label: { Label("重新翻译", systemImage: "arrow.clockwise") }
                .disabled(session.phase != .idle)
        }
        Button(role: .destructive) { act { session.deleteTurn(turn.id) } } label: { Label("删除", systemImage: "trash") }
            .disabled(session.phase != .idle)
    }

    private func act(_ action: () -> Void) { showingActions = false; action() }

    /// "我 · 14:06 · 图片文字"
    private var metaLine: String {
        let who = isMe ? String(localized: "我") : String(localized: "对方")
        let time = turn.createdAt.formatted(date: .omitted, time: .shortened)
        let base = "\(who) · \(time)"
        guard let kind = turn.kind.label else { return base }
        return "\(base) · \(kind)"
    }

    @ViewBuilder
    private var meta: some View {
        HStack(spacing: 6) {
            if case .failed(let reason) = turn.state {
                Image(systemName: "exclamationmark.circle").foregroundStyle(Theme.err)
                Text(reason).foregroundStyle(Theme.err)
                Button("点此重试") { session.retranslate(turn.id) }
                    .frame(minHeight: 44)
                    .foregroundStyle(Theme.fg)
            } else {
                MetaLine(text: metaLine, alignment: isMe ? .trailing : .leading) {
                    if turn.state == .speaking {
                        Image(systemName: "speaker.wave.2.fill").foregroundStyle(Theme.fg)
                    }
                }
            }
        }
        .font(Theme.caption)
        .foregroundStyle(Theme.mut)
        .padding(.horizontal, 6)
    }
}

private struct StreamNotice: View {
    let notice: Notice

    var body: some View {
        let row = HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundStyle(color)
            Text(text).font(Theme.caption).foregroundStyle(Theme.fg)
            if needsSettings {
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(Theme.mut)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glass(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        // 权限被拒：整条可点，直接去系统设置（原来只有一行字，说「请到系统设置里打开」却点不了）
        if needsSettings {
            Button { PermissionCenter.openSystemSettings() } label: { row }
                .buttonStyle(.plain)
                .accessibilityHint("打开系统设置")
        } else {
            row
        }
    }

    private var needsSettings: Bool { notice == .microphoneDenied || notice == .speechDenied }

    private var icon: String {
        switch notice {
        case .noSpeech: return "ear"
        case .microphoneDenied: return "mic.slash"
        case .speechDenied: return "waveform.slash"
        case .recognizerUnavailable: return "exclamationmark.triangle"
        }
    }

    private var color: Color {
        switch notice {
        case .noSpeech, .recognizerUnavailable: return Theme.warn
        case .microphoneDenied, .speechDenied: return Theme.err
        }
    }

    private var text: LocalizedStringKey {
        switch notice {
        case .noSpeech: return "没听清，请再说一次"
        case .microphoneDenied: return "需要麦克风权限才能听你说话，请到系统设置里打开。"
        case .speechDenied: return "需要语音识别权限，请到系统设置里打开。"
        case .recognizerUnavailable(let reason): return LocalizedStringKey(reason)
        }
    }
}

// MARK: - 底栏：＋ / 输入框 / 麦克风或发送

private struct InputBar: View {
    let session: ConversationSession
    let showsAddButton: Bool
    let onAdd: () -> Void
    var onKeyboard: (() -> Void)?
    /// 键盘起来时：切换药丸被键盘盖住，输入框把那块空位让回来，底边也贴近键盘
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 发送次数：驱动发送时的轻触觉
    @State private var sentCount = 0
    /// 打字发送后要不要朗读：和打字输入条上的「朗读」开关是同一个设置（原来这里不管开关，关了朗读在这里发还是会读出来）
    @AppStorage(TypingSpeakToggle.key) private var speaks = true

    private var hasText: Bool { !session.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        let _ = BodyCount.hit("InputBar")
        HStack(alignment: .bottom, spacing: 8) {
            if showsAddButton {
                Button(action: onAdd) {
                    Image(systemName: "plus")
                        .font(.system(size: 18))
                        .foregroundStyle(Theme.sub)
                        .frame(width: 44, height: 44)
                        .glass(in: Circle(), interactive: true)
                        .frame(height: 52)          // 和右边 52pt 的输入胶囊同高、居中对齐（原来 44pt 贴着底边，加号比输入栏低 4pt）
                }
                .accessibilityLabel("加入对话")
            }

            // 一枚胶囊（高 52）：输入框在里面，主操作（麦克风 / 发送）是胶囊里右侧的粉红圆钮
            HStack(spacing: 8) {
                field
                trailing
            }
            .padding(.leading, 18)
            .padding(.trailing, 4)
            .frame(minHeight: 52)
            .glass(in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            // 整枚胶囊都能点：原来只有文字那一行能唤起键盘，点上下边缘没反应
            .contentShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
            .refocusOnTap($focused)
            .refocusOnActive($focused)
        }
        .scaledWidth(0.84)        // 输入栏原来铺满整行，太长：收到 80%，之后用户要求对话流的再长 5%（0.8 × 1.05 = 0.84）并居中（窄屏不低于 300pt）
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 8)
        // 麦克风 ⇄ 发送：旧图标缩小淡出、新图标从 0.7 倍放大淡入（动画稿第 2 项）
        .animation(reduceMotion ? .easeInOut(duration: 0.12) : .smooth(duration: 0.18), value: hasText)
        .sensoryFeedback(.impact(weight: .light), trigger: sentCount)
    }

    @ViewBuilder
    private var field: some View {
        if let onKeyboard {
            Button(action: onKeyboard) {
                Text(session.draft.isEmpty ? String(localized: "输入文字…") : session.draft)
                    .font(.body).foregroundStyle(session.draft.isEmpty ? Theme.mut : Theme.fg)
                    .lineLimit(2).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("键盘输入")
        } else {
        TextField("输入文字…", text: Binding(get: { session.draft }, set: { session.updateDraft($0, composing: TextComposition.isComposing) }), axis: .vertical)
            .lineLimit(1...4)
            .font(.system(.body))
            .foregroundStyle(Theme.fg)
            .focused($focused)
            .submitLabel(.send)
            .disablesReturnKeyWhenEmpty(isFocused: focused)          // 空输入时键盘上的发送键置灰（和打字输入条一致）
            .onSubmit { send(); Task { @MainActor in focused = true } }          // 回车会让多行输入框失焦、键盘收起：发完把焦点要回来，接着打下一句
        }
    }

    private func send() {
        guard hasText else { return }
        // 拼音还没上屏就点发送：先让输入框把组合提交掉（失焦时系统会提交）再发，发完把焦点要回来
        if TextComposition.isComposing {
            dismissKeyboard()          // 同步失焦：系统当场把组合提交进输入框
            sendNow()
            Task { @MainActor in focused = true }
            return
        }
        sendNow()
    }

    private func sendNow() {
        guard hasText else { return }
        // 正在聆听时 sendText 会拒绝：先结束聆听，文字留着，用户再点一次发送（原来静默没反应、还震了一下）
        if session.isListening { session.stopListening(); Haptics.warning(); return }
        sentCount += 1
        session.speakOnSend = speaks
        session.sendDraft()
    }

    private var trailingSize: CGFloat { 44 }
    /// 正在听的是「我」才显示停止（对方的麦克风在听时，这颗钮点了会没反应，图标不能写「停止」）
    private var listeningMe: Bool {
        if case .listening(let who) = session.phase { return who == .me }
        return false
    }

    @ViewBuilder
    private var trailing: some View {
        if hasText {
            Button { send() } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(Theme.fg)
                    .frame(width: trailingSize, height: trailingSize)
                    .primaryGlass(in: Circle())
            }
            .accessibilityLabel("发送")
            .transition(swapTransition)
        } else {
            Button { session.micTapped(.me) } label: {
                Image(systemName: listeningMe ? "stop.fill" : "mic.fill")
                    .contentTransition(reduceMotion ? .opacity : .symbolEffect(.replace))
                    .animation(reduceMotion ? .reduced : .smooth(duration: 0.18), value: listeningMe)          // 不绑值的话 🎤 ⇄ ⏹ 的变形是硬切（session.phase 变化不在动画事务里）
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(Theme.fg)
                    .frame(width: trailingSize, height: trailingSize)
                    .primaryGlass(in: Circle())
            }
            .accessibilityLabel(listeningMe ? "停止聆听" : "开始说话")
            .transition(swapTransition)
        }
    }

    private var swapTransition: AnyTransition {
        reduceMotion ? .opacity : .scale(scale: 0.7).combined(with: .opacity)
    }
}

/// 对话流的系统工具栏项：返回、历史、分享（竖排时用图标，溢出菜单里用标题）。
/// Duo 内屏横放（`menu` 不为空）：和面对面页同一套——竖栏里「＋ 加入对话」「⋯ 更多（历史 / 键盘输入 / 设置 / 重命名）」「分享」，
/// 这些动作不再放在页面里（原来摆在底部说话坞下面，和 Duo 把工具栏竖排在右侧的设计不一致）。
struct StreamToolbar: ToolbarContent {
    struct MoreMenu {
        let onKeyboard: () -> Void
        let onSettings: () -> Void
        let onRename: () -> Void
    }

    let session: ConversationSession
    let onBack: () -> Void
    let onOpenHistory: () -> Void
    /// 竖排栏（Duo 外屏）里的「加入对话」：和面对面页同一个位置、同一个图标（原来在输入栏左边，和面对面页不一致）
    var onAdd: (() -> Void)?
    var menu: MoreMenu?

    var body: some ToolbarContent {
        if let onAdd {
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: onAdd) { BarLabel("加入对话", symbol: BarSymbol.add) }
            }
            if #available(iOS 26.0, *) { ToolbarSpacer(.fixed, placement: .topBarTrailing) }
        }
        if let menu {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    // 菜单自己收起要 ~0.2s：页面推入等它收完再开，两个动画不叠在一起
                    Button { later(onOpenHistory) } label: { Label("历史", systemImage: BarSymbol.history) }
                    Button { later(menu.onKeyboard) } label: { Label("键盘输入", systemImage: BarSymbol.keyboard) }
                    Button { later(menu.onSettings) } label: { Label("设置", systemImage: BarSymbol.settings) }
                    if !session.turns.isEmpty {
                        Button { later(menu.onRename) } label: { Label("重命名对话", systemImage: "pencil") }
                    }
                } label: {
                    BarLabel("更多", symbol: "ellipsis")
                }
            }
            if #available(iOS 26.0, *) { ToolbarSpacer(.fixed, placement: .topBarTrailing) }
        } else {
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: onOpenHistory) { BarLabel("历史", symbol: BarSymbol.history) }
            }
        }
        if !session.turns.isEmpty {
            ToolbarItem(placement: .topBarTrailing) {
                ShareLink(item: session.transcript()) { BarLabel("分享对话", symbol: "square.and.arrow.up") }
            }
        }
    }

    private func later(_ action: @escaping () -> Void) {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(220))
            action()
        }
    }
}

/// 「面对面｜对话流」分段（设计稿 T1 顶部）：玻璃胶囊，当前页是更亮的一段。
struct ModeSegment: View {
    enum Page { case faceToFace, stream }
    let selection: Page
    let onSelect: (Page) -> Void

    var body: some View {
        HStack(spacing: 2) {
            segment("面对面", .faceToFace)
            segment("对话流", .stream)
        }
        .padding(3)
        .glass(in: Capsule())
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)       // 再大就放不进一行了（和中间控制条一样封顶）
    }

    private func segment(_ title: LocalizedStringKey, _ page: Page) -> some View {
        Button { onSelect(page) } label: {
            Text(title)
                .font(.system(.subheadline).weight(selection == page ? .semibold : .regular))
                .foregroundStyle(selection == page ? Theme.fg : Theme.sub)
                .padding(.horizontal, 16)
                .frame(minWidth: 76, minHeight: 36)
                .background(selection == page ? Theme.fg.opacity(0.18) : .clear, in: Capsule())
                .verticalHitOutset(4)        // 视觉 36pt，点按区域 44pt
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selection == page ? .isSelected : [])
    }
}

/// 气泡下面那行小字（引擎 · 用时）：一行放得下就横排，放不下就竖排。
struct MetaLine<Trailing: View>: View {
    let text: String
    var alignment: HorizontalAlignment = .leading
    @ViewBuilder var trailing: Trailing

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                Text(text)
                trailing
            }
            .fixedSize(horizontal: true, vertical: false)
            VStack(alignment: alignment, spacing: 2) {
                Text(text)
                trailing
            }
        }
    }
}
