import SwiftUI

/// 朗读声音：每种语言单独选一个声音。当前对话的两种语言排在最前。
struct VoiceSettingsView: View {
    let session: ConversationSession
    @ObservedObject var settings: AppSettings
    /// 宽屏设置里推进来的：用统一的页头 / 宽度
    var wide = false
    /// Duo 外屏（竖排栏）：和内屏一样自己画页头（左上返回、没有「完成」），整个设置里只有一种二级页头
    var pane = false
    var onDone: () -> Void = {}
    /// 推入 / 退出一层时通知设置页（+1 / -1），用来数层数
    var onLevel: (Int) -> Void = { _ in }

    // 初始值只看缓存、不枚举（`@State` 的初始值表达式每次重建视图都会执行；缓存还没有就先空着，后台枚举完再填）
    @State private var installed: [VoiceChoice]? = VoiceCatalog.peek

    private var current: [LanguageOption] { [session.me, session.them] }
    private var others: [LanguageOption] { LanguageOption.all.filter { !current.contains($0) } }

    var body: some View {
        if pane {
            PaneDetailPage(title: "朗读声音") { listBody }
        } else if wide {
            WideDetailPage(title: "朗读声音", onDone: onDone) { listBody }
        } else {
            listBody
        }
    }

    private var listBody: some View {
        List {
            Section("当前对话") {
                ForEach(current) { row($0) }
            }
            .listRowBackground(CardRowBackground())
            Section {
                ForEach(others) { row($0) }
            } header: {
                Text("其他语言")
            } footer: {
                Text("想要更自然的声音：到系统设置的“辅助功能 → 朗读内容 → 声音”里下载“增强”或“高级”声音，下载后会出现在这里。")
            }
            .listRowBackground(CardRowBackground())
        }
        .scrollContentBackground(.hidden)
        .duoListInset()
        .background { if !wide { PageBackground() } }      // 宽屏时背景由外层页面统一画，这里再画一层会露出一块矩形接缝
        .navigationTitle("朗读声音")
        .navigationBarTitleDisplayMode(.inline)
        // 从下级页面 / 系统设置回来：后台重新枚举，列表换成最新的（只在有变化时赋值，不触发无谓刷新）
        .task {
            let fresh = await VoiceCatalog.refresh()
            if fresh != installed { installed = fresh }
        }
    }

    private func row(_ language: LanguageOption) -> some View {
        NavigationLink {
            VoicePickerView(language: language, session: session, settings: settings, wide: wide, pane: pane,
                            onDone: onDone, onLevel: onLevel)
        } label: {
            LabeledContent(language.nativeName) {
                if let installed {
                    if let name = VoiceCatalog.selectedName(for: language, settings: settings.voiceIDs, among: installed) {
                        Text(name).foregroundStyle(Theme.mut)
                    } else {
                        Text("自动").foregroundStyle(Theme.mut)
                    }
                }          // 声音列表还在后台加载：右边先留空，别先写「自动」再变成声音名
            }
        }
    }
}

/// 一种语言的声音列表：点一下就选中并试听。
struct VoicePickerView: View {
    let language: LanguageOption
    let session: ConversationSession
    @ObservedObject var settings: AppSettings
    var wide = false
    var pane = false
    var onDone: () -> Void = {}
    var onLevel: (Int) -> Void = { _ in }

    /// nil = 声音列表还在后台加载（真机上第一次枚举要等一会儿）
    @State private var voices: [VoiceChoice]?

    init(language: LanguageOption, session: ConversationSession, settings: AppSettings,
         wide: Bool = false, pane: Bool = false, onDone: @escaping () -> Void = {}, onLevel: @escaping (Int) -> Void = { _ in }) {
        self.wide = wide
        self.pane = pane
        self.onDone = onDone
        self.onLevel = onLevel
        self.language = language
        self.session = session
        self.settings = settings
        _voices = State(initialValue: VoiceCatalog.cachedChoices(for: language.ttsCode))
    }

    private var selectedID: String { settings.voiceIDs[language.ttsCode] ?? VoiceCatalog.autoID }

    var body: some View {
        if pane {
            PaneDetailPage(title: LocalizedStringKey(language.nativeName)) { listBody }
                .onAppear { onLevel(1) }
                .onDisappear { onLevel(-1) }
        } else if wide {
            WideDetailPage(title: LocalizedStringKey(language.nativeName), onDone: onDone) { listBody }
                .onAppear { onLevel(1) }
                .onDisappear { onLevel(-1) }
        } else {
            listBody
                .onAppear { onLevel(1) }
                .onDisappear { onLevel(-1) }
        }
    }

    private var listBody: some View {
        List {
            Section {
                Button { choose(VoiceCatalog.autoID) } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("自动").foregroundStyle(Theme.fg)
                            Text("使用系统为这种语言选的声音").font(Theme.caption).foregroundStyle(Theme.mut)
                        }
                        Spacer()
                        if let voices, selectedID.isEmpty || !voices.contains(where: { $0.id == selectedID }) {
                            Image(systemName: "checkmark").foregroundStyle(Theme.fg)
                        }
                    }
                    .frame(minHeight: 44)
                }
                .accessibilityAddTraits(voices.map { selectedID.isEmpty || !$0.contains(where: { $0.id == selectedID }) } == true ? .isSelected : [])
            }
            .listRowBackground(CardRowBackground())

            Section {
                if let voices, voices.isEmpty {
                    Text("没有找到这种语言的声音").foregroundStyle(Theme.mut)
                } else if voices == nil {
                    HStack { Spacer(); ProgressView(); Spacer() }.frame(minHeight: 44)
                }
                ForEach(voices ?? []) { voice in
                    Button { choose(voice.id) } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(voice.name).foregroundStyle(Theme.fg)
                                Text(detail(of: voice)).font(Theme.caption).foregroundStyle(Theme.mut)
                            }
                            Spacer()
                            if voice.id == selectedID {
                                Image(systemName: "checkmark").foregroundStyle(Theme.fg)
                            }
                        }
                        .frame(minHeight: 44)
                    }
                    .accessibilityAddTraits(voice.id == selectedID ? .isSelected : [])
                }
            } header: {
                Text("可选的声音")
            } footer: {
                Text("点一下选中并试听。语速在上一页调整。")
            }
            .listRowBackground(CardRowBackground())
        }
        .scrollContentBackground(.hidden)
        .duoListInset()
        .background { if !wide { PageBackground() } }      // 宽屏时背景由外层页面统一画，这里再画一层会露出一块矩形接缝
        .navigationTitle(language.nativeName)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            // 缓存里已经有就不再重新枚举排序（页面一打开就有内容）；没有才等后台枚举
            if voices == nil { voices = VoiceCatalog.cachedChoices(for: language.ttsCode) }
            let fresh = VoiceCatalog.choices(for: language.ttsCode, among: await VoiceCatalog.refresh())
            if fresh != voices { voices = fresh }
        }
        // 只停自己试听的：对话正在读的译文（自动朗读）不能被打断
        .onDisappear { if session.speakingTurnID == nil, session.phase == .idle { session.stopSpeaking() } }
    }

    private func choose(_ id: String) {
        if id.isEmpty {
            settings.voiceIDs[language.ttsCode] = nil
        } else {
            settings.voiceIDs[language.ttsCode] = id
        }
        session.previewVoice(id, for: language)
    }

    /// 例："英语（英国） · 增强 · 女声"
    private func detail(of voice: VoiceChoice) -> String {
        var parts = [AppLanguageState.shared.locale.localizedString(forIdentifier: voice.language) ?? voice.language]
        switch voice.quality {
        case .standard: parts.append(String(localized: "标准音质"))
        case .enhanced: parts.append(String(localized: "增强"))
        case .premium: parts.append(String(localized: "高级"))
        }
        switch voice.gender {
        case .male: parts.append(String(localized: "男声"))
        case .female: parts.append(String(localized: "女声"))
        case .unspecified: break
        }
        return parts.joined(separator: " · ")
    }
}
