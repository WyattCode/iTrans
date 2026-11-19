import SwiftUI

/// 首次使用：一页完成（设计稿 onboarding-v2 方案 A + 第 2 版文案 + onboarding-layout-options 排版 1）——只问两种语言。
/// 版面沿中轴线居中：App 图标方块（不带文字）+ 一句问话 + 一张列表 + 一个按钮；没有口号。麦克风 / 语音识别在点「开始」时由系统弹窗询问；
/// 相机到第一次拍照时再问。离线语言包只在列表下用一行小字交代状态。
struct OnboardingView: View {
    let session: ConversationSession
    @ObservedObject var settings: AppSettings
    let packs: LanguagePackStore
    let onFinish: () -> Void

    @State private var microphone = PermissionCenter.microphone()
    @State private var speech = PermissionCenter.speech()
    /// 正在走系统权限弹窗：按钮不再响应第二次点按
    @State private var starting = false
    /// 竖放时「标题 + 列表 + 按钮」整组的高度：上下留白按它算
    @State private var portraitHeight: CGFloat = 400
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.activeFold) private var activeFold
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            // 折叠（Duo 半开）：折痕两边各占一半。展平 / 直板：整块画布，不分栏的竖放、平分的横放
            let duo = activeFold != nil ? DuoLayout.make(content: geo.size) : nil
            let landscape = geo.size.width > geo.size.height
            Group {
                if landscape {
                    landscapeLayout(geo.size, folded: duo?.axis == .horizontal ? duo : nil)
                } else if let duo, duo.axis == .vertical {
                    tabletopLayout(duo)          // 折痕横着：上半屏问话、下半屏操作，各占一半
                } else {
                    portraitLayout(geo.size)
                }
            }
            // 折叠 / 展开：两栏的宽度、折痕的位置平滑过渡，竖放的上下分屏和单列之间交叉淡化
            .animation(reduceMotion ? .reduced : .smooth(duration: 0.4), value: duo?.axis == nil ? 0 : (duo?.axis == .horizontal ? 1 : 2))
        }
        .background { AuroraBackground() }
        .task { await packs.refresh() }
        // 从系统设置回来：权限状态要刷新
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { microphone = PermissionCenter.microphone(); speech = PermissionCenter.speech() }
        }
    }

    /// 离线包状态小字的左右缩进（居中显示，缩进只是给长句留边）
    private static let textInset: CGFloat = 36

    /// 列表 + 离线包状态 + 按钮：一个整体
    private var group: some View {
        VStack(alignment: .leading, spacing: 0) {
            form
            footer.padding(.top, 24)
        }
    }

    // MARK: 版面（设计稿 onboarding-layout-options 排版 1：居中对称）

    /// 图标方块 + 标题 + 说明，沿中轴线居中（不带文字的 logo：方块本身就是 App 图标）
    private func hero(tile: CGFloat) -> some View {
        VStack(spacing: tile >= 150 ? 32 : 26) {
            BrandMark(size: tile)
            heading
        }
    }

    /// 方块边长：外屏 / 直板竖放 112，内屏竖放 150，内屏横放 180（矮横屏 112）；字号再大方块也不变
    private func tileSize(for size: CGSize) -> CGFloat {
        if size.width > size.height { return size.height < 500 ? 112 : 180 }
        return size.width >= 600 ? 150 : 112
    }

    /// 横放：左半屏「图标 + 标题」居中，右半屏「列表 + 按钮」居中。展平 = 按内容区平分；折叠 = 折痕左右各占一半
    ///（每半 `duo.first`，折痕 40pt 在正中）。两种状态是同一棵视图树，只有宽度不同，折叠 / 展开时是平滑的宽度过渡。
    private func landscapeLayout(_ size: CGSize, folded duo: DuoLayout?) -> some View {
        let creaseWidth: CGFloat = duo == nil ? 1 : DuoLayout.crease
        let half = duo?.first ?? (size.width - 1) / 2
        return HStack(spacing: 0) {
            ScrollView {
                hero(tile: tileSize(for: size))
                    .frame(maxWidth: 360)
                    .padding(.horizontal, 24)
                    .frame(maxWidth: .infinity, minHeight: size.height)          // 内容矮时垂直居中，高时整栏滚动
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(width: half)

            // 折痕 / 分隔线：线始终在这一格的正中（折叠时这一格是 40pt 的折痕）
            Rectangle().fill(Theme.fg.opacity(0.12)).frame(width: 1)
                .padding(.vertical, 48)
                .frame(width: creaseWidth)

            ScrollView {
                group
                    .frame(maxWidth: 440)
                    .padding(.horizontal, 8)
                    .frame(maxWidth: .infinity, minHeight: size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(width: half)
        }
        // 折叠时两半加折痕正好是整个窗口宽度，比安全区内的宽度多出右边系统那一列：不裁，从列后面延伸出去
        .frame(width: half * 2 + creaseWidth, height: size.height, alignment: .leading)
        // 矮的横屏（外屏横放 / 直板横屏，半栏只有 ~280pt 宽）：辅助功能超大字号下一行只放得下三四个字，封顶
        .dynamicTypeSize(...(size.height < 500 ? DynamicTypeSize.xxLarge : DynamicTypeSize.accessibility2))
    }

    /// 竖放（展平 / 直板 / 外屏）：整组沿中轴线居中，上下留白约 2:3。
    /// 屏太矮 / 字号太大放不下时（iPhone SE + 超大字号：「开始」被屏幕下沿切掉一半）：按钮钉在屏幕底部，上面的内容可以滚动，按钮永远够得着。
    private func portraitLayout(_ size: CGSize) -> some View {
        ViewThatFits(in: .vertical) {
            VStack(spacing: 0) {
                hero(tile: tileSize(for: size))
                group.padding(.top, 26)
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { portraitHeight = $0 }
            .frame(maxWidth: 520)          // 宽屏（Duo 内屏竖向 / iPad）上别把行拉得太长
            .frame(maxWidth: .infinity)
            .padding(.top, max(32, (size.height - portraitHeight) * 0.4))
            .padding(.bottom, 16)

            ScrollView {
                VStack(spacing: 0) {
                    hero(tile: typeSize.isAccessibilitySize ? 72 : min(tileSize(for: size), 96))
                    form.padding(.top, 20)
                }
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
                .padding(.top, 20)
            }
            .scrollBounceBehavior(.basedOnSize)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                footer
                    .frame(maxWidth: 520)
                    .padding(.vertical, 12)
            }
        }
        .transition(.opacity)
    }

    /// 竖放 + Duo 半开（折痕横着，像笔记本）：内容不能跨折痕——上半屏放「图标 + 标题」、下半屏放「列表 + 按钮」，各占一半
    private func tabletopLayout(_ duo: DuoLayout) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                hero(tile: 112)
                    .frame(maxWidth: 520)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
            }
            .scrollBounceBehavior(.basedOnSize)
            .defaultScrollAnchor(.center)
            .frame(height: duo.first)

            Color.clear.frame(height: DuoLayout.crease)          // 折痕：什么都不放

            ScrollView {
                group
                    .frame(maxWidth: 520)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
            }
            .scrollBounceBehavior(.basedOnSize)
            .defaultScrollAnchor(.center)
            .frame(height: duo.second)
        }
        .transition(.opacity)
    }

    // MARK: 问话

    private var heading: some View {
        VStack(spacing: 10) {
            Text("你说什么语言？\n对方说什么？")
                .font(.title.weight(.bold))
                .foregroundStyle(Theme.fg)
                .fixedSize(horizontal: false, vertical: true)
            Text("选好就能开始对话。")
                .font(.system(.body))
                .foregroundStyle(Theme.sub)
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 24)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    // MARK: 语言列表 + 离线包状态

    private var form: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 一张列表（不是两张卡）：和系统设置同一种分组样式
            VStack(spacing: 0) {
                languageRow(title: "我说", selection: Binding(
                    get: { settings.meLanguage },
                    set: { new in
                        // 选了对方正在用的语言：两边对调，别出现"两边同一种语言"
                        if new.id == settings.themLanguageID { settings.themLanguageID = settings.meLanguageID }
                        settings.meLanguageID = new.id
                    }))
                Rectangle().fill(Theme.fg.opacity(0.12)).frame(height: 1).padding(.horizontal, 16)
                languageRow(title: "对方说", selection: Binding(
                    get: { settings.themLanguage },
                    set: { new in
                        if new.id == settings.meLanguageID { settings.meLanguageID = settings.themLanguageID }
                        settings.themLanguageID = new.id
                    }))
            }
            .background(Theme.fg.opacity(0.09), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .padding(.horizontal, 20)

            packNote
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)          // 离线包状态在卡片下居中
                .padding(.horizontal, Self.textInset)
                .padding(.top, 8)
        }
    }

    private func languageRow(title: LocalizedStringKey, selection: Binding<LanguageOption>) -> some View {
        Menu {
            Picker(title, selection: selection) {
                ForEach(LanguageOption.all) { Text($0.nativeName).tag($0) }
            }
        } label: {
            HStack(spacing: 8) {
                Text(title).font(.body).foregroundStyle(Theme.fg).lineLimit(1).layoutPriority(1)
                Spacer()
                Text(selection.wrappedValue.nativeName).font(.body).foregroundStyle(Theme.sub)
                    .lineLimit(1).minimumScaleFactor(0.7)          // 语言名不拆成「Engl / ish」
                Image(systemName: "chevron.up.chevron.down").font(.footnote.weight(.semibold)).foregroundStyle(Theme.sub)          // 提亮一档：看得出这一行能点
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)          // 大字号下行会长高：上下留边，不贴着分隔线
            .frame(maxWidth: .infinity, minHeight: 54)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var uniqueChosen: [LanguageOption] {
        let chosen = [settings.meLanguage, settings.themLanguage]
        return chosen.enumerated().filter { index, language in chosen.firstIndex(of: language) == index }.map(\.element)
    }

    /// 离线语言包：一行小字说清现在的状态；没下载时旁边给一个「现在下载」
    @ViewBuilder
    private var packNote: some View {
        let statuses = uniqueChosen.map { packs.status(of: $0) }
        let downloadable = uniqueChosen.filter { packs.status(of: $0) == .downloadable }
        VStack(alignment: .center, spacing: 4) {
            if statuses.allSatisfy({ $0 == .installed }) {
                note("离线语言包已下载，没网也能用。")
            } else if uniqueChosen.contains(where: { packs.downloading.contains($0.id) }) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    note("正在下载离线语言包…")
                }
            } else if !downloadable.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    note("离线语言包还没下载。")
                    Button("现在下载") {
                        Task { for language in downloadable { await packs.download(language) } }
                    }
                    .font(Theme.caption.weight(.semibold))
                    .foregroundStyle(Theme.fg)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
            } else if statuses.contains(.unsupported) {
                note("这组语言暂时没有离线包，需要联网翻译。")
            } else {
                note(" ")          // 还在查询状态：占住一行，查到后不跳
            }
            if let error = packs.lastError {
                Text(error).font(Theme.caption).foregroundStyle(Theme.err)
            }
        }
    }

    private func note(_ text: LocalizedStringKey) -> some View {
        Text(text).font(Theme.caption).foregroundStyle(Theme.mut).fixedSize(horizontal: false, vertical: true)
    }

    // MARK: 开始

    private var footer: some View {
        VStack(spacing: 0) {
            Button(action: start) {
                Text("开始")
                    .font(.system(.headline))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 50)          // 和卡片等宽、边缘对齐（列宽本身已封顶：竖放 520、横放 440）
                    .background(Theme.control, in: Capsule())          // 实色：不随背后的极光变深变浅
                    .contentShape(Capsule())
            }
            .buttonStyle(DockButtonStyle())
            .disabled(starting)
            .padding(.horizontal, 20)
            .accessibilityIdentifier("onboarding.start")

            // 按钮下：只有权限被拒绝过时才有一行（去系统设置的出口）；平时什么都不放
            Group {
                if !starting, microphone == .denied || speech == .denied {          // 点「开始」后的系统弹窗期间不显示：麦克风刚被拒、语音识别的弹窗还在时，这行一冒出来整页会在弹窗后面跳一下
                    Button("麦克风或语音识别已被拒绝 · 到系统设置里打开") { PermissionCenter.openSystemSettings() }
                        .font(Theme.caption.weight(.semibold))
                        .foregroundStyle(Theme.fg)
                        .multilineTextAlignment(.center)
                        .frame(minHeight: 44)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 20)          // 和卡片、按钮同宽：小字在这个宽度里居中
        }
    }

    /// 点「开始」：还没问过的权限在这里由系统弹窗询问（先麦克风、后语音识别），不管结果如何都进首页——
    /// 被拒绝时首页的麦克风上有「轻点前往设置」的引导。
    private func start() {
        guard !starting else { return }
        starting = true
        Task { @MainActor in
            if microphone == .notDetermined { microphone = await PermissionCenter.requestMicrophone() }
            if speech == .notDetermined { speech = await PermissionCenter.requestSpeech() }
            finish()
        }
    }

    private func finish() {
        // 无动画：引导页正在淡出，中间条的语言名不要在遮罩下面做互换转场
        var instant = Transaction()
        instant.disablesAnimations = true
        withTransaction(instant) {
            session.me = settings.meLanguage
            session.them = settings.themLanguage
        }
        settings.onboardingDone = true
        Haptics.success()
        onFinish()
    }
}


/// 引导页上的品牌图标：就是 App 图标（深紫极光底 + 粉青两个气泡），不带文字。
/// 图标底色和引导页的深色极光很近，边缘会糊掉：加一圈 1pt 的白色细线和一层向下的柔影，方块才站得出来。
struct BrandMark: View {
    let size: CGFloat
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.2237, style: .continuous)
        Image("BrandMark")
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .clipShape(shape)
            .overlay(shape.strokeBorder(Color.white.opacity(0.2), lineWidth: 1))
            .shadow(color: .black.opacity(0.4), radius: size * 0.12, y: size * 0.07)
            .accessibilityHidden(true)
    }
}
