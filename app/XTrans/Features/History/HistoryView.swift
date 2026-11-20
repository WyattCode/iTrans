import SwiftData
import SwiftUI

/// H1 · 历史：一场场对话的列表。点开可以接着聊；左滑删除；可搜索标题和内容。
/// 历史只存在本机。
struct HistoryView: View {
    let session: ConversationSession
    let onOpen: (UUID) -> Void
    let onNew: () -> Void

    @Query(sort: \ConversationRecord.updatedAt, order: .reverse) private var records: [ConversationRecord]
    @State private var query = ""
    @State private var filter: HistoryFilter = .all
    @State private var renaming: ConversationRecord?
    @State private var renameText = ""
    @State private var actionRecordID: UUID?
    @State private var openedRecordID: UUID?
    /// 宽屏（Duo 展开 / iPad）：左边列表，右边选中那场对话的内容（主-详细）
    @State private var selection: UUID?
    @Environment(\.dismiss) private var dismiss
    /// 直板机整页推入时由根视图给的关闭动作（左上角「‹ 对话」）；nil = 弹层 / 整屏盖上，用 `dismiss`。
    var onClose: (() -> Void)?
    /// 整页推入时左上是「‹ 对话」，不是「完成」
    var usesBackButton = false
    /// 系统正把工具栏竖排在屏幕一侧（Duo 外屏）：自己画页头、隐藏系统栏，第一帧就是最终版面（见 SettingsView.railVertical）
    var railVertical = false
    /// 常驻的页面（藏在屏幕外）现在是不是打开着：每次打开都从干净的状态开始（清掉搜索、筛选）
    var isActive = true
    /// 作为系统导航栈（根上的 NavigationStack）推进来的页面：不再自己包一层 NavigationStack，标题 / 返回用外层的原生导航栏
    var inOuterStack = false
    /// 只要「屏内的页面」（Duo 内屏右屏里那张历史列表）：由根视图放进右屏的导航栈里原生推入
    var paneContent = false
    /// Duo 内屏（展平）的居中表单弹层里：单栏列表（筛选、搜索、按天分组），点开详情在卡片内推入
    var inSheet = false
    /// 历史里推入了二级页（Duo 屏里点开一场对话的详情）：根视图据此决定左缘右滑是返回上一级还是关掉整个历史
    var onSubpage: ((Bool) -> Void)?
    @State private var detailOpen = false
    /// 关页之后如果还停在二级页，换一个 id 把 NavigationStack 重建回列表（在页面藏起来之后做，不影响打开动画）
    @State private var resetToken = 0
    @State private var scrollPosition = ScrollPosition(edge: .top)
    @State private var resetTask: Task<Void, Never>?
    @State private var scrolled = false
    /// iPhone 上系统搜索栏是不是展开着（关页复位时要收起来）
    @State private var searchActive = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isWide = false
    /// 右栏窄（Duo 内屏横向的右屏）：页头分两行
    @State private var compactDetailHeader = false
    @FocusState private var searchFocused: Bool
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    /// 常驻在屏幕外（没打开）的时候，每次保存对话 @Query 都会让这页重新求值；筛选和按天分组每次 body 要算好几遍。
    /// 没打开就直接用上一次打开时算好的结果（看不见，旧一点没关系；打开时 `isActive` 为真会重新算）。
    private final class Memo {
        var filtered: [ConversationRecord]?
        var groups: [(day: Date, items: [ConversationRecord])]?
        var count = -1
        /// 每场对话的「几条 / 有没有图片」：算它要把这场对话的全部轮次从数据库里读出来。按「最后更新时间」记住，对话没变就不再读
        var stats: [UUID: (stamp: Date, count: Int, hasImages: Bool)] = [:]
    }
    @State private var memo = Memo()
    /// 缓存还能不能用：对话条数没变、而且里面没有已经被删掉的记录（读已删除的 SwiftData 对象的属性会崩）
    private var memoUsable: Bool {
        guard let cached = memo.filtered, memo.count == records.count else { return false }
        return !cached.contains { $0.isDeleted || $0.modelContext == nil }
    }

    private var filtered: [ConversationRecord] {
        if !isActive, memoUsable, let cached = memo.filtered { return cached }
        let value = HistoryFilter.apply(records, filter: filter, query: query)
        memo.filtered = value
        memo.groups = nil
        memo.count = records.count
        return value
    }

    private var groups: [(day: Date, items: [ConversationRecord])] {
        if !isActive, memoUsable, let cached = memo.groups { return cached }
        let calendar = Calendar.current
        let byDay = Dictionary(grouping: filtered) { calendar.startOfDay(for: $0.updatedAt) }
        let value = byDay.keys.sorted(by: >).map { ($0, byDay[$0] ?? []) }
        memo.groups = value
        return value
    }

    var body: some View {
        let _ = BodyCount.hit("HistoryView")
        GeometryReader { geo in
            if inSheet {
                listColumn(wide: false, split: false)
            } else if paneContent {
                pinnedHistory
            } else if LayoutClass.forWindow(fallback: geo.size) == .wide {
                // 还没有对话时不分栏：一个居中的空状态占满整页，别在右边再摆一句"在左边点一场对话"
                let split = !records.isEmpty
                if let duo = DuoLayout.make(content: geo.size) {
                    duoBody(duo, split: split)          // iPhone Duo 内屏横向：折痕处留空
                } else {
                HStack(spacing: 0) {
                    wideListColumn(split: split)
                        .frame(width: split ? 340 : nil)
                    if split {
                        Divider().ignoresSafeArea()
                        // 右栏：64pt 的页头（标题 / 副标题、分享、接着聊、完成），下面才是对话
                        VStack(spacing: 0) {
                            detailHeader
                            detail
                        }
                        .background { AuroraBackground().ignoresSafeArea() }
                    }
                }
                }
            } else if railVertical {
                pinnedHistory.background { PageBackground() }.extendsToScreenBottom()
            } else if usesBackButton && inOuterStack {
                // 直板机整页推入：页头（返回 + 居中标题 + 新对话）画在页面里，系统导航栏隐藏（见 `PhonePageHeader`）
                wideListColumn(split: false, selectsRows: false)
                    .background { PageBackground().ignoresSafeArea() }
                    .toolbarVisibility(.hidden, for: .navigationBar)
                    .containerBackground(.clear, for: .navigation)
            } else {
                listColumn(wide: false, split: false)
            }
        }
        .onChange(of: isActive) { _, now in
            resetTask?.cancel()          // 重新打开了：藏起来之后才做的复位不能在滑出 / 滑入途中触发
            if !now {
                searchFocused = false
                searchActive = false
                // 页面滑出去之后（藏起来了）再复位：清掉搜索 / 筛选（无动画，不然列表在滑入时才动画变化）、回到列表顶部；
                // 还停在二级页就重建导航栈。打开动画里不做任何事
                resetTask = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(450))
                    guard !Task.isCancelled, !isActive else { return }
                    memo.filtered = nil; memo.groups = nil          // 先丢缓存，下面一改状态就按新的筛选重算
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        if !query.isEmpty { query = "" }
                        if filter != .all { filter = .all }
                    }
                    // 只在「脏」的时候重建（整张 List 重新建 = 130–280ms 卡顿，不能每次关页都来）；
                    // 重建而不是 scrollTo(edge: .top)：浮条用了内容边距，scrollTo 不可靠
                    guard detailOpen || scrolled else { scrollPosition.scrollTo(edge: .top); return }
                    resetToken += 1
                    scrolled = false
                    if detailOpen { detailOpen = false; onSubpage?(false) }
                }
            }
        }
        .onGeometryChange(for: Bool.self) { _ in LayoutClass.forWindow(fallback: .zero) == .wide } action: { isWide = $0 }
        .onGeometryChange(for: Bool.self) { DuoLayout.make(content: $0.size) != nil } action: { compactDetailHeader = $0 }
        .sheetDetents([.large])
    }

    @ViewBuilder
    private var detail: some View {
        // 有对话时总有一场被选中（默认第一场），所以不需要"选一场对话"的提示；筛选 / 搜索没有结果时右边留空
        // 换选中的对话：旧的淡出、新的淡入，不是硬切
        ZStack {
            if let record = currentRecord {
                HistoryDetailView(record: record, showsChrome: false) { onOpen(record.id) }
                    .id(record.id)
                    .transition(.opacity)
            } else {
                Color.clear
            }
        }
        .animation(reduceMotion ? .reduced : .easeOut(duration: 0.2), value: filtered.first(where: { $0.id == selection })?.id ?? filtered.first?.id)
    }

    /// iPhone Duo 内屏横向：左屏常驻对话、右屏历史列表；没有对话时是一个居中的空状态。
    @ViewBuilder
    private func duoBody(_ duo: DuoLayout, split: Bool) -> some View {
        ZStack {
            // （DuoPanes 自己铺极光，这里不再重复铺一层）
            // 没有对话时也是两块屏（空状态只放在右屏）：整页居中的空状态会压在折痕上。
            // 左屏：正在进行的对话（不动）；右屏：历史的单列列表，点一场对话推入详情
            DuoPanes(layout: duo) {
                ConversationPane(session: session, dimmed: true)
            } right: {
                pinnedHistory
            }
            .duoOverlayInset(duo)
        }
    }

    /// Duo 的屏里：自己画页头（返回 + 标题 + 新对话）、筛选、列表、底部搜索栏；系统栏隐藏。点一场对话推入详情（页头的返回回到列表）。
    private var pinnedHistory: some View {
        stack {
            VStack(spacing: 0) {
                // 列表铺满到页面底边，搜索栏是浮在列表上面的玻璃条（safeAreaInset）：列表在它下面继续滚，不再有一刀切的截断和一条空带
                Group {
                if filtered.isEmpty {
                    ScrollView {
                        content(wide: false)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                } else {
                    List {
                        ForEach(groups, id: \.day) { group in
                            Section(dayLabel(group.day)) {
                                ForEach(group.items) { record in
                                    historyEntry(record)
                                        .listRowBackground(CardRowBackground().clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous)))
                                        .listRowSeparator(.hidden)
                                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {          // 不允许一划到底直接删：删除没有确认也不能撤销，要点一下「删除」
                                            Button(role: .destructive) { session.deleteConversation(record.id) } label: {
                                                Label("删除", systemImage: "trash")
                                            }
                                            .tint(Theme.err)
                                        }
                                        .swipeActions(edge: .leading) {
                                            Button { session.setFavorite(!record.isFavorite, for: record.id) } label: {
                                                Label(record.isFavorite ? "取消收藏" : "收藏", systemImage: record.isFavorite ? "star.slash" : "star")
                                            }
                                            .tint(Theme.control)
                                        }
                                        .contextMenu { if !paneContent { menu(for: record) } }
                                }
                            }
                        }
                    }
                    .scrollContentBackground(.hidden)
                    .listRowSpacing(8)
                    .scrollPosition($scrollPosition)
                    .onScrollGeometryChange(for: Bool.self) { $0.contentOffset.y + $0.contentInsets.top > 4 } action: { _, now in scrolled = now }
                    .duoListInset()
                }
                }
                .floatingBar(.bottom) { if !paneContent { searchBar } }
                .floatingBar(.top) {
                    VStack(spacing: 0) {
                        // Duo 外屏：返回 / 新对话交给系统的竖排栏（和面对面、对话流页的「＋ ⋯」同一列），页面里不再自己画
                        if !usesSystemRail {
                            PaneHeader(title: "历史", onBack: { close() }) {
                                HStack(spacing: 8) {
                                    Button { onNew() } label: {
                                        Image(systemName: "square.and.pencil")
                                            .font(.system(size: 17))
                                            .foregroundStyle(Theme.fg)
                                            .frame(width: 44, height: 44)
                                            .glass(in: Circle(), interactive: true)
                                    }
                                    .accessibilityLabel("新对话")
                                }
                            }
                        } else {
                            Color.clear.frame(height: 8)
                        }
                        if !records.isEmpty { filterPicker }
                        if paneContent { searchBar }
                    }
                }
            }
            .navigationDestination(isPresented: Binding(get: { openedRecordID != nil }, set: { if !$0 { openedRecordID = nil } })) {
                if let id = openedRecordID, let record = records.first(where: { $0.id == id }) {
                    PaneDetailPage(title: "历史") { HistoryDetailView(record: record) { onOpen(record.id) } }
                        .onAppear { detailOpen = true; onSubpage?(true) }
                        .onDisappear { detailOpen = false; onSubpage?(false) }
                }
            }
            .background { PageBackground() }
            .toolbarVisibility(usesSystemRail ? .automatic : .hidden, for: .navigationBar)
            .navigationTitle("历史")
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                if usesSystemRail {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { onNew() } label: { BarLabel("新对话", symbol: "square.and.pencil") }
                    }
                }
            }
            .containerBackground(.clear, for: .navigation)
            .paneTextPrompt("重命名对话", prompt: "对话标题", actionTitle: "重命名",
                            isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } }), text: $renameText) {
                if let record = renaming { session.renameConversation(record.id, to: renameText) }
                renaming = nil
            }
        }
        .environment(\.inRailPane, railVertical)      // 放在导航栈外面：推进去的二级页（朗读声音等）才读得到
        .id(resetToken)
    }

    @ViewBuilder
    private func historyEntry(_ record: ConversationRecord) -> some View {
        if !paneContent {
            NavigationLink {
                PaneDetailPage(title: "历史") { HistoryDetailView(record: record) { onOpen(record.id) } }
                    .onAppear { detailOpen = true; onSubpage?(true) }
                    .onDisappear { detailOpen = false; onSubpage?(false) }
            } label: { row(record) }
        } else {
        HStack(spacing: 8) {
            row(record)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .gesture(LongPressGesture(minimumDuration: 0.6).exclusively(before: TapGesture()).onEnded { result in
                    switch result {
                    case .first(true): if paneContent { dismissKeyboard(); actionRecordID = record.id }
                    case .second: openedRecordID = record.id
                    default: break
                    }
                })
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { openedRecordID = record.id }
                .accessibilityAction(named: Text("更多")) { dismissKeyboard(); actionRecordID = record.id }
            if paneContent {
                Button { dismissKeyboard(); actionRecordID = record.id } label: {
                    Image(systemName: "ellipsis").foregroundStyle(Theme.fg).frame(width: 44, height: 44)
                }.buttonStyle(.borderless).accessibilityLabel("更多")
            }
            Button { openedRecordID = record.id } label: {
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(Theme.mut)
                    .frame(width: 32, height: 44)
            }.buttonStyle(.borderless).accessibilityLabel("打开对话")
        }
        }
    }

    @ViewBuilder
    private func stack<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        if inOuterStack { content() } else { NavigationStack { content() } }
    }

    /// Duo 外屏（系统竖排栏）里原生推入的页面：用系统栏的返回键和按钮，不自己画页头
    private var usesSystemRail: Bool { inOuterStack && railVertical && !paneContent }

    private func close() { if let onClose { onClose() } else { dismiss() } }

    private var currentRecord: ConversationRecord? {
        filtered.first(where: { $0.id == selection }) ?? filtered.first
    }

    /// 右栏页头：高 64，和左栏页头、整屏面板的页头同一条线。
    /// 右栏够宽（> 480）时一行放得下：标题 / 副标题、分享、接着聊、完成；
    /// Duo 内屏横向右屏只有约 370pt，一行放四样会把标题挤没，所以分两行：上面标题 + 完成，下面分享 + 接着聊（整行宽）。
    private var detailHeader: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                if let record = currentRecord {
                    titleBlock(record)
                    Spacer(minLength: 8)
                    if !compactDetailHeader { shareButton(record); continueButton(record) }
                } else {
                    Spacer(minLength: 0)
                }
                PanelDoneButton { close() }
            }
            .padding(.horizontal, 20)
            .frame(height: 64)
            if compactDetailHeader, let record = currentRecord {
                HStack(spacing: 12) {
                    shareButton(record)
                    continueButton(record, fills: true)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
            }
        }
    }

    private func titleBlock(_ record: ConversationRecord) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(record.title)
                .font(.system(.headline))
                .foregroundStyle(Theme.fg)
                .lineLimit(1)
            Text("\(record.updatedAt.appFormatted(date: .abbreviated, time: .shortened)) · \(record.turns.count) 条")
                .font(Theme.caption)
                .foregroundStyle(Theme.mut)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private func shareButton(_ record: ConversationRecord) -> some View {
        ShareLink(item: record.exportText) {
            Image(systemName: "square.and.arrow.up")
                .font(.system(size: 17))
                .foregroundStyle(Theme.fg)
                .frame(width: 44, height: 44)
                .glass(in: Circle(), interactive: true)
        }
        .accessibilityLabel("分享")
    }

    private func continueButton(_ record: ConversationRecord, fills: Bool = false) -> some View {
        Button { onOpen(record.id) } label: {
            Label("接着聊", systemImage: "arrow.right.circle")
                .font(.system(.subheadline).weight(.semibold))
                .foregroundStyle(Theme.fg)
                .padding(.horizontal, 16)
                .frame(maxWidth: fills ? .infinity : nil, minHeight: 44)
                .frame(minWidth: 112)
                .primaryGlass(in: Capsule())
        }
        .buttonStyle(.plain)
    }

    /// 宽屏的左列（没有对话时是整页）：自己画 64pt 页头、筛选、列表、底部搜索栏，不用系统导航栏——
    /// 这样两栏的页头、"完成"都和设置等整屏面板对得上。
    private func wideListColumn(split: Bool, selectsRows: Bool = true) -> some View {
        VStack(spacing: 0) {
            let newButton = Button { onNew() } label: {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 17))
                    .foregroundStyle(Theme.fg)
                    .frame(width: 44, height: 44)
                    .glass(in: Circle(), interactive: true)
            }
            .accessibilityLabel("新对话")
            if usesBackButton && !split {
                // 直板机整页推入：返回在左、标题居中、新对话在右（和设置页同一个页头）
                PhonePageHeader(title: "历史", onBack: { close() }) { newButton }
            } else {
                HStack(spacing: 12) {
                    Text("历史")
                        .font(.system(size: 34, weight: .heavy))
                        .foregroundStyle(Theme.fg)
                        .accessibilityAddTraits(.isHeader)
                    Spacer(minLength: 0)
                    newButton
                    if !split { PanelDoneButton { close() } }
                }
                .padding(.horizontal, 20)
                .frame(height: 64)
            }
            // 直板机横放搜索：键盘占掉大半个屏，筛选条先让出来（否则结果列表只剩一条缝）
            if !records.isEmpty, !(searchFocused && verticalSizeClass == .compact && !selectsRows) { filterPicker.padding(.top, 4) }
            // 手机整页推入（selectsRows == false）没有右栏详情：点一行要真的打开那场对话（原来写死 wide: true 只改选中、不打开）
            content(wide: selectsRows)
                .environment(\.defaultMinListRowHeight, 64)
            searchBar
        }
        .background { AuroraBackground().ignoresSafeArea() }
        .alert("重命名对话", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("对话标题", text: $renameText)
            Button("取消", role: .cancel) { renaming = nil }
            Button("重命名") {
                if let record = renaming { session.renameConversation(record.id, to: renameText) }
                renaming = nil
            }
        }
    }

    /// 底部搜索栏（胶囊，高 44）：没有对话时也在，居中、最宽 520。
    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(Theme.mut)
            TextField("搜索对话", text: $query)
                .foregroundStyle(Theme.fg)
                .submitLabel(.search)
                .focused($searchFocused)
                .onSubmit { searchFocused = false }
                .accessibilityIdentifier("history.search")
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.mut)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清除搜索")
            }
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 44)          // 无障碍字号下文字放不下固定的 44pt
        .glass(in: Capsule())
        .contentShape(Capsule())
        .refocusOnTap($searchFocused)
        .frame(maxWidth: records.isEmpty ? 520 : .infinity)
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
        .padding(.top, 8)
    }

    private func listColumn(wide: Bool, split: Bool) -> some View {
        stack {
            VStack(spacing: 0) {
                if !records.isEmpty { filterPicker }
                content(wide: wide)
            }
            .background { AuroraBackground() }
            .navigationTitle("历史")
            .navigationBarTitleDisplayMode(.inline)          // 居中小标题，和设置页一致（原来非弹层时是大标题靠左）
            .searchable(text: $query, isPresented: $searchActive,
                        placement: inSheet ? .navigationBarDrawer(displayMode: .always) : .automatic, prompt: "搜索对话")
            .toolbar {
                // 注意：工具栏里不能写空分支（`if x { }`）——它会生成 EmptyView，EmptyView 作为 ToolbarContent 只在 iOS 27 以上可用，iOS 18–26 上会出问题
                if !split, !inOuterStack {
                    if usesBackButton { BackToolbarItem { close() } } else { DoneToolbarItem { close() } }
                }
                ToolbarItem(placement: inSheet ? .topBarLeading : .topBarTrailing) {
                    Button {
                        onNew()
                    } label: {
                        Label("新对话", systemImage: "square.and.pencil")
                    }
                }
            }
            .alert("重命名对话", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("对话标题", text: $renameText)
                Button("取消", role: .cancel) { renaming = nil }
                Button("重命名") {
                    if let record = renaming { session.renameConversation(record.id, to: renameText) }
                    renaming = nil
                }
            }
        }
    }

    private var filterPicker: some View {
        HistoryFilterTabs(selection: $filter)
            .padding(.horizontal, 20)
            .padding(.bottom, 8)
    }

    @ViewBuilder
    private func content(wide: Bool) -> some View {
        if records.isEmpty {
            ContentUnavailableView(
                "还没有对话",
                systemImage: "clock",
                description: Text("你说过的话会保存在这里，只存在这台设备上。")
            )
        } else if filtered.isEmpty {
            if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ContentUnavailableView(
                    "没有符合筛选的对话",
                    systemImage: "line.3.horizontal.decrease.circle",
                    description: Text("换个筛选试试。")
                )
            } else {
                ContentUnavailableView.search(text: query)
            }
        } else {
            list(wide: wide)
        }
    }

    private func list(wide: Bool) -> some View {
        List {
            ForEach(groups, id: \.day) { group in
                Section(dayLabel(group.day)) {
                    ForEach(group.items) { record in
                        Button {
                            if wide { withAnimation(reduceMotion ? .reduced : .easeOut(duration: 0.2)) { selection = record.id } } else { onOpen(record.id) }
                        } label: { row(record) }
                            .listRowBackground(wide && record.id == (selection ?? filtered.first?.id)
                                               ? Theme.control.opacity(0.2) : Theme.glassFill)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {          // 不允许一划到底直接删：删除没有确认也不能撤销，要点一下「删除」
                                Button(role: .destructive) {
                                    session.deleteConversation(record.id)
                                } label: {
                                    Label("删除", systemImage: "trash")
                                }
                                .tint(Theme.err)
                            }
                            .swipeActions(edge: .leading) {
                                Button {
                                    session.setFavorite(!record.isFavorite, for: record.id)
                                } label: {
                                    Label(record.isFavorite ? "取消收藏" : "收藏", systemImage: record.isFavorite ? "star.slash" : "star")
                                }
                                .tint(Theme.control)
                            }
                            .paneContextMenu("更多", isPresented: Binding(
                                            get: { actionRecordID == record.id },
                                            set: { actionRecordID = $0 ? record.id : nil })) { menu(for: record) }
                    }
                }
            }
        }
        .dismissKeyboardInScrollArea()
        .scrollContentBackground(.hidden)
        .scrollPosition($scrollPosition)
                    .onScrollGeometryChange(for: Bool.self) { $0.contentOffset.y + $0.contentInsets.top > 4 } action: { _, now in scrolled = now }
    }

    @ViewBuilder
    private func menu(for record: ConversationRecord) -> some View {
        Button {
            actionRecordID = nil
            renameText = record.title
            renaming = record
        } label: {
            Label("重命名", systemImage: "pencil")
        }
        Button {
            actionRecordID = nil
            session.setFavorite(!record.isFavorite, for: record.id)
        } label: {
            Label(record.isFavorite ? "取消收藏" : "收藏", systemImage: record.isFavorite ? "star.slash" : "star")
        }
        ShareLink(item: record.exportText) {
            Label("分享", systemImage: "square.and.arrow.up")
        }
        Button(role: .destructive) {
            actionRecordID = nil
            session.deleteConversation(record.id)
        } label: {
            Label("删除", systemImage: "trash")
        }
    }

    private func stats(_ record: ConversationRecord) -> (count: Int, hasImages: Bool) {
        if let hit = memo.stats[record.id], hit.stamp == record.updatedAt { return (hit.count, hit.hasImages) }
        let turns = record.turns
        let value = (count: turns.count, hasImages: turns.contains { $0.kindRaw == TurnKind.photo.rawValue })
        if memo.stats.count > 400 { memo.stats.removeAll() }
        memo.stats[record.id] = (record.updatedAt, value.count, value.hasImages)
        return value
    }

    private func row(_ record: ConversationRecord) -> some View {
        let stats = stats(record)
        let me = LanguageOption.all.first { $0.id == record.meID } ?? .zhHans
        let them = LanguageOption.all.first { $0.id == record.themID } ?? .en
        let chip = Text("\(me.shortName) ⇄ \(them.shortName)")
            .font(Theme.label)
            .foregroundStyle(Theme.fg)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(Theme.meFill.opacity(0.14), in: Capsule())
            .fixedSize()
        let badges = Group {
            if stats.hasImages {
                Image(systemName: "camera").font(.system(size: 12)).foregroundStyle(Theme.mut)
                    .accessibilityLabel("含图片")
            }
            chip
        }
        // 超大字号下标题和语言对放不进一行：标题允许两行，语言对换到下一行，而不是把标题截成"拉面…"
        let large = dynamicTypeSize.isAccessibilitySize
        return VStack(alignment: .leading, spacing: 4) {
            if large {
                titleLine(record, lines: 2)
                HStack(spacing: 8) { badges }
            } else {
                HStack(spacing: 8) {
                    titleLine(record, lines: 1)
                    badges
                }
            }
            Text("\(record.updatedAt.appFormatted(date: .omitted, time: .shortened)) · \(stats.count) 条")
                .font(Theme.caption)
                .foregroundStyle(Theme.mut)
        }
        .frame(minHeight: 44, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func titleLine(_ record: ConversationRecord, lines: Int) -> some View {
        HStack(spacing: 8) {
            if record.isFavorite {
                Image(systemName: "star.fill").font(.system(size: 12)).foregroundStyle(Theme.meText)
                    .accessibilityLabel("已收藏")
            }
            Text(record.title)
                .font(.system(.body).weight(.semibold))
                .foregroundStyle(Theme.fg)
                .lineLimit(lines)
        }
    }

    private func dayLabel(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return String(localized: "今天") }
        if calendar.isDateInYesterday(day) { return String(localized: "昨天") }
        return day.appFormatted(date: .abbreviated, time: .omitted)
    }
}


/// 历史页的筛选页签（全部 / 已收藏 / 含图片）。系统的分段控件固定 32pt、不能加高，所以自己画：整条 38pt（比系统的高约 20%），
/// 选中的那一段是一块会滑动的底板。
private struct HistoryFilterTabs: View {
    @Binding var selection: HistoryFilter
    @Namespace private var plate
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let items: [(title: LocalizedStringKey, filter: HistoryFilter)] = [
        ("全部", .all), ("已收藏", .favorites), ("含图片", .withImages),
    ]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(items.indices, id: \.self) { index in
                let item = items[index]
                let selected = selection == item.filter
                Button {
                    guard selection != item.filter else { return }
                    Haptics.selection()           // 触觉只由点按触发（原来挂在 selection 上，打开页面时重置筛选也会响）
                    withAnimation(reduceMotion ? .easeInOut(duration: 0.12) : .smooth(duration: 0.25)) { selection = item.filter }
                } label: {
                    Text(item.title)
                        .font(.system(.subheadline).weight(selected ? .semibold : .regular))
                        .foregroundStyle(selected ? Theme.fg : Theme.sub)
                        .frame(maxWidth: .infinity, minHeight: 32)
                        .background {
                            if selected {
                                if reduceMotion {
                                    Capsule().fill(Theme.fg.opacity(0.16))
                                } else {
                                    Capsule().fill(Theme.fg.opacity(0.16)).matchedGeometryEffect(id: "plate", in: plate)
                                }
                            }
                        }
                        .verticalHitOutset(6)        // 选项 32pt 高，点按区域补到 44pt
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(3)
        .glass(in: Capsule())
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("筛选")
    }
}
