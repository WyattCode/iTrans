import SwiftUI

/// S1 · 设置：只放真正需要的。分组：语言、翻译、语音、外观、数据与隐私。
struct SettingsView: View {
    let session: ConversationSession
    @ObservedObject var settings: AppSettings
    let packs: LanguagePackStore
    let engineName: String

    @Environment(\.dismiss) private var dismiss
    /// 直板机整页推入时由根视图给的关闭动作（左上角「‹ 对话」）；nil = 弹层 / 整屏盖上，用 `dismiss`。
    var onClose: (() -> Void)?
    /// 整页推入时左上是「‹ 对话」，不是「完成」
    var usesBackButton = false
    /// 系统正把工具栏竖排在屏幕一侧（Duo 外屏）：系统栏要等页面出现之后才排好，页头 / 列表边距会跟着再变一次（设置项突然拉长、返回时页面先跳一下）。
    /// 这时和 Duo 内屏一样自己画页头、隐藏系统栏，第一帧就是最终的版面。
    var railVertical = false
    /// 常驻的页面（藏在屏幕外）现在是不是打开着：每次打开时刷新一次语言包状态
    var isActive = true
    /// 作为系统导航栈（根上的 NavigationStack）推进来的页面：不再自己包一层 NavigationStack，标题 / 返回用外层的原生导航栏
    var inOuterStack = false
    /// 只要「屏内的页面」（Duo 内屏右屏里那张设置列表）：由根视图自己把它放进右屏的导航栈里原生推入，不要再带左屏的 DuoPanes
    var paneContent = false
    /// Duo 内屏（展平）的居中表单弹层里：原来的单栏设置，标题居中（inline），「完成」关掉
    var inSheet = false
    @State private var scrollPosition = ScrollPosition(edge: .top)
    /// 子页（朗读声音 / 离线语言包）出现 / 消失：根视图据此决定左缘右滑是返回上一级还是关掉整个设置
    var onSubpage: ((Bool) -> Void)?
    /// 推入的层数（设置 → 朗读声音 → 某种语言 是两层）：只要还有一层，左缘右滑就是"返回上一级"
    private final class Depth { var value = 0 }
    @State private var depth = Depth()
    /// 关页之后如果还停在二级页，换一个 id 把 NavigationStack 重建回列表（藏起来之后做，不影响打开动画）
    @State private var resetToken = 0
    /// 复位任务：页面重新打开时要取消，不然会在滑出途中把页面复位
    @State private var resetTask: Task<Void, Never>?
    /// 列表是不是滚离了顶部（关页后要不要复位）
    @State private var scrolled = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var confirmingClear = false
    @State private var confirmingReset = false
    @State private var showingLanguages = false
    /// 界面语言刚选完、还没真正换过去的那一小会儿
    @State private var pendingLanguage: AppLanguage?
    @Environment(\.colorScheme) private var colorScheme

    /// Duo 外屏（系统竖排栏）里原生推入的页面：用系统栏的返回键，不自己画页头
    private var usesSystemRail: Bool { inOuterStack && railVertical && !paneContent }

    private func close() { if let onClose { onClose() } else { dismiss() } }

    private func subpage(_ delta: Int) {
        depth.value = max(0, depth.value + delta)
        onSubpage?(depth.value > 0)
    }

    /// 设置的分类（宽屏左边的列表）。
    enum Category: String, CaseIterable, Identifiable {
        case language, translation, speech, appearance, packs, data
        var id: String { rawValue }
        var title: LocalizedStringKey {
            switch self {
            case .language: return "语言"
            case .translation: return "翻译"
            case .speech: return "语音"
            case .appearance: return "外观"
            case .packs: return "离线语言包"
            case .data: return "数据与隐私"
            }
        }
        var symbol: String {
            switch self {
            case .language: return "globe"
            case .translation: return "square.stack.3d.up"
            case .speech: return "speaker.wave.2"
            case .appearance: return "circle.lefthalf.filled"
            case .packs: return "arrow.down.circle"
            case .data: return "lock.shield"
            }
        }
    }

    /// 走查用：`-XTransSettingsCategory translation` 直接停在宽屏设置的某一类（只在 Debug / PERF_HOOKS 生效）
    @State private var category: Category = Category(rawValue: DebugFlags.settingsCategory ?? "") ?? .language

    var body: some View {
        let _ = BodyCount.hit("SettingsView")
        GeometryReader { geo in
            if inSheet {
                compactBody
            } else if paneContent {
                duoSettingsPane
            } else if LayoutClass.forSize(geo.size) == .wide {
                if let duo = DuoLayout.make(content: geo.size) {
                    duoBody(duo)          // iPhone Duo 内屏横向：折痕处留空，左右两屏各是一块
                } else {
                    wideBody(width: geo.size.width)
                }
            } else if railVertical {
                paneSettings
            } else {
                compactBody
            }
        }
        // GeometryReader 只占安全区以内：不放开的话列表在 Home 条上方 34pt 就被一刀切掉（直板机整页推入的设置）
        .ignoresSafeArea(.container, edges: drawsOwnHeader ? .bottom : [])
        .onChange(of: isActive) { _, now in
            resetTask?.cancel()
            if now {
                Task { await packs.refreshAfterTransition() }
            } else {
                // 朗读声音的试听不跟着页面一起藏起来继续读；但对话自己正在读的译文（自动朗读）不能被打断
                if session.speakingTurnID == nil, session.phase == .idle { session.stopSpeaking() }
                // 页面滑出去之后（藏起来了）再回到顶部、回到列表；打开动画里不动
                resetTask = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(450))
                    guard !Task.isCancelled, !isActive else { return }
                    // 只在「脏」的时候才重建（停在二级页 / 滚离了顶部）：重建 = 整张 List 重新建，130–280ms 的卡顿，不能每次关页都来一遍。
                    // 重建而不是 `scrollTo(edge: .top)`：浮条用了内容边距，scrollTo 不再可靠地回到顶。重建发生在页面已经藏起来之后
                    guard depth.value > 0 || scrolled else { return }
                    resetToken += 1
                    scrolled = false
                    if depth.value > 0 {
                        depth.value = 0
                        onSubpage?(false)
                    }
                }
            }
        }
        .paneConfirmation("清除历史对话？",
                          message: "所有保存的对话都会被删除，无法恢复。常用短语不受影响。",
                          actionTitle: "清除历史对话", isPresented: $confirmingClear) { session.clearAllHistory() }
        .paneConfirmation("恢复默认设置？",
                          message: "语速、停顿时间、外观等会回到默认值，不会删除任何对话。",
                          actionTitle: "恢复默认", isPresented: $confirmingReset) {
                            // 外观会跟着回到「跟随系统」：和手动切外观一样走整页溶解，不要整个 App 的主题硬切
                            if settings.appearance != .system {
                                crossfadePage(reduceMotion: reduceMotion, extraSettle: 0.08, punchesChrome: false) { settings.resetToDefaults() }
                            } else {
                                settings.resetToDefaults()
                            }
                        }
        .sheetDetents([.large])
        .languagePicker(isPresented: $showingLanguages, session: session, packs: packs, scheme: colorScheme)
    }

    @ViewBuilder
    private func stack<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        if inOuterStack { content() } else { NavigationStack { content() } }
    }

    /// 窄屏：一个长列表。
    /// 直板机整页推入：页头画在页面里（浮条：列表在它下面继续滚、交界处渐隐），系统导航栏隐藏
    private var drawsOwnHeader: Bool { usesBackButton && !inSheet && inOuterStack }

    private var compactBody: some View {
        stack {
            List {
                languageSection()
                translationSection()
                speechSection()
                appearanceSection()
                dataSection
                versionSection
            }
            .scrollContentBackground(.hidden)
            .scrollPosition($scrollPosition)
            .onScrollGeometryChange(for: Bool.self) { $0.contentOffset.y + $0.contentInsets.top > 4 } action: { _, now in scrolled = now }
            .tint(Theme.fg)
            .task { await packs.refreshAfterTransition() }
            .floatingBar(.top) { if drawsOwnHeader { PhonePageHeader(title: "设置") { close() } } }
            // 浮条的渐隐遮罩只盖到安全区内：列表不铺到屏幕底边的话，最后 34pt 会被一刀切掉
            .extendsToScreenBottom(drawsOwnHeader)
            .toolbarVisibility(drawsOwnHeader ? .hidden : .automatic, for: .navigationBar)
            // 页面背景铺满整个屏幕（含刘海 / 状态栏那一块）：隐藏系统栏之后，导航栈默认的黑底会从顶部露出来
            // 背景必须写在浮条（遮罩）之后：写在前面会被遮罩一起裁掉（弹层形态下导航栏那一条没有极光）
            .background { PageBackground().ignoresSafeArea() }
            .containerBackground(drawsOwnHeader ? .clear : Color.clear, for: .navigation)
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(usesBackButton || inSheet ? .inline : .large)
            .toolbar {
                // 外层导航栈自带原生返回键时什么都不放。不能写空分支：EmptyView 作为 ToolbarContent 只在 iOS 27 以上可用
                if !inOuterStack {
                    if usesBackButton { BackToolbarItem { close() } } else { DoneToolbarItem { close() } }
                }
            }
        }
        .environment(\.inRailPane, railVertical)      // 放在导航栈外面：推进去的二级页（朗读声音等）才读得到
        .id(resetToken)
    }

    /// Duo 内屏的设置：页头（返回 + 标题）自己画，系统栏隐藏（竖排栏会把工具栏按钮收走）。
    private var paneSettings: some View { duoSettingsPane.extendsToScreenBottom() }

    private var duoSettingsPane: some View {
        stack {
            VStack(spacing: 0) {
                List {
                    languageSection()
                    translationSection()
                    speechSection()
                    appearanceSection()
                    dataSection
                    versionSection
                }
                .scrollContentBackground(.hidden)
                .scrollPosition($scrollPosition)
            .onScrollGeometryChange(for: Bool.self) { $0.contentOffset.y + $0.contentInsets.top > 4 } action: { _, now in scrolled = now }
                .duoListInset()
                .tint(Theme.fg)
                .task { await packs.refreshAfterTransition() }
                // 页头浮在列表上面（列表在下面滚，顶端柔和渐隐），不再把列表在页头下沿一刀切
                .floatingBar(.top) { if usesSystemRail { Color.clear.frame(height: 8) } else { PaneHeader(title: "设置") { close() } } }
            }
            .background { PageBackground() }
            .toolbarVisibility(usesSystemRail ? .automatic : .hidden, for: .navigationBar)
            .navigationTitle("设置")
            .toolbarTitleDisplayMode(.inline)
            .containerBackground(.clear, for: .navigation)      // 导航栈默认的黑底会盖住极光
        }
        .environment(\.inRailPane, railVertical)      // 放在导航栈外面：推进去的二级页（朗读声音等）才读得到
        .id(resetToken)
    }

    /// D5 · 宽屏（Duo 内屏 / iPad）设计稿方案 A：设置占满整屏，不是浮层。
    /// 左：分类栏（大标题 + 每行 50pt，选中行染色）；右：当前分类的内容，居中一栏（最宽 560pt）。
    /// 标题和完成键都自己画：系统栏在 Duo 竖排模式下，嵌套的标题会跑到屏幕左上角、空的栏还会把内容糊住，没法按稿排版。
    private func wideBody(width: CGFloat) -> some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 280)
            Rectangle().fill(Theme.fg.opacity(0.1)).frame(width: 1).ignoresSafeArea()
            NavigationStack {
                VStack(spacing: 0) {
                    WideHeader(title: category.title, onDone: { close() })
                    detail(for: category)
                        .frame(maxWidth: 560)
                        .frame(maxWidth: .infinity)
                        .scrollContentBackground(.hidden)
                        .tint(Theme.fg)
                }
                .background { AuroraBackground().ignoresSafeArea() }
                .toolbarVisibility(.hidden, for: .navigationBar)
            }
            .id(category)
            .transition(.opacity)
        }
        // 换分类：旧的淡出、新的淡入（0.15 秒），不是整页硬切
        .animation(reduceMotion ? .reduced : .easeOut(duration: 0.15), value: category)
        .background { AuroraBackground().ignoresSafeArea() }
        .task { await packs.refreshAfterTransition() }
    }

    /// iPhone Duo 内屏横向：按折痕分成左右两屏，文字和控件都不跨折痕。左屏常驻对话，设置只在右屏。
    private func duoBody(_ duo: DuoLayout) -> some View {
        ZStack {
            // （DuoPanes 自己铺极光，这里不再重复铺一层）
            // 左屏：正在进行的对话（不动）；右屏：设置的单列长列表
            DuoPanes(layout: duo) {
                ConversationPane(session: session, dimmed: true)
            } right: {
                duoSettingsPane
            }
            .duoOverlayInset(duo)
        }
        .task { await packs.refreshAfterTransition() }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 和右边那一行（高 64、标题居中）同一条中线，两个标题才对得齐
            Text("设置")
                .font(.largeTitle.weight(.heavy))
                .foregroundStyle(Theme.fg)
                .padding(.horizontal, 24)
                .frame(minHeight: 64, alignment: .leading)
                .padding(.bottom, 8)
                .accessibilityAddTraits(.isHeader)
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(Category.allCases) { item in
                        Button { category = item } label: {
                            HStack(spacing: 12) {
                                Image(systemName: item.symbol)
                                    .font(.system(size: 17))
                                    .frame(width: 24)
                                Text(item.title)
                                Spacer(minLength: 0)
                            }
                            .font(.system(.body))
                            .foregroundStyle(Theme.fg)
                            .padding(.horizontal, 14)
                            .frame(minHeight: 50)
                            .background(category == item ? Theme.control.opacity(0.28) : .clear,
                                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(category == item ? .isSelected : [])
                    }
                }
                .padding(.horizontal, 12)
            }
            .scrollBounceBehavior(.basedOnSize)
            // 版本号放在侧栏底部（原来混在"数据与隐私"里）
            HStack(spacing: 4) {
                Text("版本")
                Text(Self.versionText)
            }
            .font(Theme.caption)
            .foregroundStyle(Theme.mut)
            .padding(.horizontal, 24)
            .padding(.bottom, 20)
            .padding(.top, 8)
        }
        // 延伸到安全区下面：否则底部有一条和上面不是同一层的色带
        .background { Theme.fg.opacity(0.04).ignoresSafeArea() }
    }

    @ViewBuilder
    private func detail(for category: Category) -> some View {
        switch category {
        case .language: List { languageSection(wide: true) }.settingsListMetrics()
        case .translation: List { translationSection(wide: true) }.settingsListMetrics()
        case .speech: List { speechSection(wide: true) }.settingsListMetrics()
        case .appearance: List { appearanceSection(wide: true) }.settingsListMetrics()
        case .packs: LanguagePacksView(packs: packs, showsTitle: false)
        case .data: List { dataSectionWithoutPacks; resetSection }.settingsListMetrics()
        }
    }

    // MARK: 分组

    /// 宽屏的详情页顶上已经有页面标题，分组就不再重复写一遍（"语言"出现两次）。
    @ViewBuilder
    private func group<C: View>(_ title: LocalizedStringKey, footer: LocalizedStringKey? = nil, wide: Bool,
                                @ViewBuilder content: () -> C) -> some View {
        switch (wide, footer) {
        case (true, nil): Section { content() }
        case (true, let f?): Section { content() } footer: { Text(f).padding(.bottom, 12) }
        case (false, nil): Section { content() } header: { Text(title) }
        case (false, let f?): Section { content() } header: { Text(title) } footer: { Text(f).padding(.bottom, 12) }
        }
    }

    private func languageSection(wide: Bool = false) -> some View {
        group("语言", wide: wide) {
            if paneContent {
                Button { LanguagePickerEntry.startsOnThem = false; showingLanguages = true } label: {
                    LabeledContent("我的语言") {
                        HStack(spacing: 8) {
                            Text(session.me.nativeName)
                            Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                        }.foregroundStyle(Theme.sub)
                    }
                }
                Button { LanguagePickerEntry.startsOnThem = true; showingLanguages = true } label: {
                    LabeledContent("对方语言") {
                        HStack(spacing: 8) {
                            Text(session.them.nativeName)
                            Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                        }.foregroundStyle(Theme.sub)
                    }
                }
            } else {
            Picker("我的语言", selection: Binding(get: { session.me }, set: { session.choose($0, for: .me) })) {
                ForEach(LanguageOption.all) { Text($0.nativeName).tag($0) }
            }
            Picker("对方语言", selection: Binding(get: { session.them }, set: { session.choose($0, for: .them) })) {
                ForEach(LanguageOption.all) { Text($0.nativeName).tag($0) }
            }
            }
            Button { session.swapLanguages() } label: {
                // 图标用小一号：默认大小在这一行里比文字重，显得突兀
                Label { Text("对调两边的语言") } icon: {
                    Image(systemName: "arrow.left.arrow.right").imageScale(.small)
                }
            }
        }
        .listRowBackground(CardRowBackground())
    }

    /// 方案 B（设计稿 settings-restructure-options）：云端的和本地的各一张卡片，每张只讲一件事。
    /// 宽屏里「离线语言包」是左侧单独的一类，「本地翻译」卡片里就只写用的是哪个引擎。
    @ViewBuilder
    private func translationSection(wide: Bool = false) -> some View {
        Section {
            if wide {
                LabeledContent("翻译引擎", value: EngineDisplay.name(for: engineName))
            } else {
                packsLink
            }
        } header: {
            Text("本地翻译")
        } footer: {
            Text("使用设备上的翻译，不联网也能用。")
                .padding(.bottom, 12)          // 说明文字和下一栏的标题拉开一点（原来贴得太近，像挤在一起）
        }
        .listRowBackground(CardRowBackground())
    }

    /// 「朗读」是 App 说给你听的，「聆听」是 App 听你说的：原来混在一栏「语音」里，「语速」容易被当成你说话的速度
    @ViewBuilder
    private func speechSection(wide: Bool = false) -> some View {
        Section {
            Toggle("自动朗读译文", isOn: $settings.autoSpeak).tint(Theme.control)
            NavigationLink {
                PaneAware { duo in
                    VoiceSettingsView(session: session, settings: settings, wide: wide || duo || railVertical,
                                      pane: railVertical || duo, onDone: { close() }, onLevel: { subpage($0) })
                }
                    .onAppear { subpage(1) }
                    .onDisappear { subpage(-1) }
            } label: {
                Text("朗读声音")
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("朗读语速")
                    Spacer()
                    Text(rateLabel).foregroundStyle(Theme.mut)
                }
                Slider(value: $settings.speechRate, in: AppSettings.speechRateRange).tint(Theme.control)
                    .accessibilityLabel("朗读语速")
                    .accessibilityValue(Text(rateLabel))
                sliderEnds("慢", "快")
            }
            .padding(.vertical, wide ? 8 : 0)
        } header: {
            Text("朗读")
        }
        .listRowBackground(CardRowBackground())
        Section {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("停顿多久算一句话")
                    Spacer()
                    Text("\(settings.silenceTimeout, specifier: "%.1f") 秒").foregroundStyle(Theme.mut)
                }
                Slider(value: $settings.silenceTimeout, in: AppSettings.silenceRange, step: 0.1).tint(Theme.control)
                    .accessibilityLabel("停顿时间")
                    .accessibilityValue(Text("\(settings.silenceTimeout, specifier: "%.1f") 秒"))
                sliderEnds("短", "长")
            }
            .padding(.vertical, wide ? 8 : 0)
        } header: {
            Text("聆听")
        }
        .listRowBackground(CardRowBackground())
    }

    /// 滑块两端的小字：往哪边拖是什么，不用拖一下才知道
    private func sliderEnds(_ low: LocalizedStringKey, _ high: LocalizedStringKey) -> some View {
        HStack {
            Text(low)
            Spacer()
            Text(high)
        }
        .font(Theme.caption)
        .foregroundStyle(Theme.mut)
        .accessibilityHidden(true)
    }

    private var rateLabel: LocalizedStringKey {
        let range = AppSettings.speechRateRange
        let fraction = (settings.speechRate - range.lowerBound) / (range.upperBound - range.lowerBound)
        switch fraction {
        case ..<0.25: return "慢"
        case ..<0.65: return "标准"
        default: return "快"
        }
    }

    private func appearanceSection(wide: Bool = false) -> some View {
        group("外观", footer: LayoutClass.forWindow(fallback: .zero) == .wide
              ? (DuoLayout.isDuoInner(DuoLayout.currentWindowSize)
                 ? "完全展开平放时，对方在上、你在下，语言条在屏幕正中；半开立起来时按折痕自动分屏，文字和控件让开折痕。"
                 : "“双屏摆放”只在 iPhone Duo 内屏、iPad 等宽屏幕上起作用。自动 = 铰链半开立起来时：横放左右分屏（左半屏朝向对方，右半屏朝向你），竖放上下分屏并让开折叠处；也可以固定成一种。")
              : nil, wide: wide) {
            // 深色 / 浅色切换：整页溶解，不是硬切
            AppearanceSegmented(selection: Binding(get: { settings.appearance },
                                                    set: { new in crossfadePage(reduceMotion: reduceMotion, extraSettle: 0.08, punchesChrome: false) { settings.appearance = new } }))
            // 界面语言：选完整页溶解着换过去，不用重启。
            // 先让系统菜单自己收完（约 0.25 秒）再换：原来一选就换，菜单收起、整页重排、溶解三件事叠在一起，看着一顿一顿的。
            // 这一行先显示新选的那种（`pendingLanguage`），菜单收回来时落在正确的字上。
            Picker("界面语言", selection: Binding(get: { pendingLanguage ?? settings.appLanguage },
                                                 set: { new in
                guard new != settings.appLanguage, pendingLanguage == nil else { return }
                pendingLanguage = new
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(260))
                    // 换语言是全 App 的文字一起重排，比换外观重：快照多盖一会儿，等新页排好再淡出
                    crossfadePage(reduceMotion: reduceMotion, extraSettle: 0.12, punchesChrome: false) { settings.appLanguage = new }
                    pendingLanguage = nil
                }
            })) {
                ForEach(AppLanguage.allCases) { Text(verbatim: $0.title).tag($0) }
            }
            .tint(Theme.mut)
            // 只在宽屏（Duo 内屏 / iPad）起作用：直板和 Duo 外屏上显示出来却没有任何效果
            if LayoutClass.forWindow(fallback: .zero) == .wide && !DuoLayout.isDuoInner(DuoLayout.currentWindowSize) {
                Picker("双屏摆放", selection: $settings.tentMode) {
                    ForEach(TentMode.allCases) { Text($0.title).tag($0) }
                }
            }
        }
        .listRowBackground(CardRowBackground())
    }

    private var dataSection: some View {
        Section {
            if session.historyIsVolatile { volatileNotice }
            Toggle("保存对话历史", isOn: $settings.saveHistory).tint(Theme.control)
            Button("清除历史对话", role: .destructive) { confirmingClear = true }
        } header: {
            Text("数据与隐私")
        } footer: {
            Text("对话只保存在这台设备上。")
                .padding(.bottom, 12)          // 说明文字和下一栏的标题拉开一点（原来贴得太近，像挤在一起）
        }
        .listRowBackground(CardRowBackground())
    }

    private var volatileNotice: some View {
        Label("这台设备上没能打开历史存储，这次的对话退出后会丢失。", systemImage: "exclamationmark.triangle")
            .font(Theme.caption)
            .foregroundStyle(Theme.warn)
    }

    private var packsLink: some View {
        NavigationLink {
                PaneAware { duo in
                    // Duo 外屏（竖排栏）也自己画页头：系统栏在页面出现后才排好，会二次排版
                    if duo || railVertical {
                        PaneDetailPage(title: "离线语言包") { LanguagePacksView(packs: packs, showsTitle: false) }
                    } else {
                        LanguagePacksView(packs: packs)
                    }
                }
                    .onAppear { subpage(1) }
                    .onDisappear { subpage(-1) }
        } label: {
                LabeledContent("离线语言包", value: packs.installedCount > 0 ? String(localized: "\(packs.installedCount) 个已下载") : "")
        }
    }

    /// 宽屏里"离线语言包"是单独的一类，这里不重复。
    private var dataSectionWithoutPacks: some View {
        Section {
            if session.historyIsVolatile { volatileNotice }
            Toggle("保存对话历史", isOn: $settings.saveHistory).tint(Theme.control)
            Button("清除历史对话", role: .destructive) { confirmingClear = true }
        } footer: {
            Text("对话只保存在这台设备上。")
        }
        .listRowBackground(CardRowBackground())
    }

    private static var versionText: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        return build.isEmpty ? version : "\(version) (\(build))"
    }

    /// 「恢复默认设置」和「版本」合成一张卡片（原来各占一张单行卡片）。恢复默认只是把选项改回去、不丢数据，不用警示色
    private var versionSection: some View {
        Section {
            Button { confirmingReset = true } label: { Text("恢复默认设置").foregroundStyle(Theme.fg) }
            LabeledContent("版本", value: Self.versionText)
        } header: {
            Text("关于")
        }
        .listRowBackground(CardRowBackground())
    }

    /// 宽屏的「数据与隐私」页里用：只有恢复默认这一行（版本号在左栏底部）
    private var resetSection: some View {
        Section {
            Button { confirmingReset = true } label: { Text("恢复默认设置").foregroundStyle(Theme.fg) }
        }
        .listRowBackground(CardRowBackground())
    }
}


extension View {
    /// 宽屏设置的列表规格：行高 52、分组间距 24（和图纸一致）。
    func settingsListMetrics() -> some View {
        environment(\.defaultMinListRowHeight, 52)
            .listSectionSpacing(24)
    }
}


/// 外观的三个切换按钮：原来是系统分段控件（约 31pt，偏矮），改成自己画的，整条高度约 37pt（加高 20%）。
/// 系统分段控件没有可靠的方式只调高度（`.frame(height:)` 只是把它放在更高的框里居中，`.controlSize(.large)` 又直接到 47）。
/// 无障碍仍按系统的「分段选择」读。
private struct AppearanceSegmented: View {
    @Binding var selection: Appearance
    @Namespace private var thumb
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let height: CGFloat = 37          // 加上上下各 2pt 的内边距，整条约 41pt（原来系统控件约 31pt，先 +20% = 37，再 +10% = 41）

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Appearance.allCases) { item in
                Button { if selection != item { selection = item } } label: {          // 点已选中的那一段什么都不做（原来也会跑一次整页溶解）
                    Text(item.title)
                        .font(.subheadline.weight(selection == item ? .semibold : .regular))
                        .foregroundStyle(Theme.fg)
                        .frame(maxWidth: .infinity, minHeight: height)
                        .background {
                            if selection == item {
                                // 「减少动态效果」下不滑动，直接换位置淡入（和历史的筛选条一致）
                                if reduceMotion {
                                    Capsule().fill(Theme.fg.opacity(0.18))
                                } else {
                                    Capsule().fill(Theme.fg.opacity(0.18))
                                        .matchedGeometryEffect(id: "thumb", in: thumb)
                                }
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == item ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Theme.fg.opacity(0.08), in: Capsule())
        .animation(reduceMotion ? .reduced : .smooth(duration: 0.25), value: selection)
        .accessibilityRepresentation {
            Picker("外观", selection: $selection) { ForEach(Appearance.allCases) { Text($0.title).tag($0) } }
        }
    }
}
