import SwiftUI

/// L1 · 语言选择：顶部分段切「我的语言 / 对方语言」，搜索，当前选中的排在最前，每种语言标出离线状态。
/// 选了还没下载的语言时弹出 E2：下载后再用，或取消（没有语言包就不能翻译这种语言）。
/// 系统表单弹层：直板是半屏弹层，Duo 内屏展平是屏幕正中的表单卡片，半开时系统自己让位。
/// 从哪一边点进语言选择的：点「对方语言」要直接停在「对方」那一页（原来一律停在「我」，直接选会改错一边）。
/// 弹层没有「哪一边」的参数（多处共用一个无参回调），入口在弹出前记在这里，弹层创建时读一次。
@MainActor
enum LanguagePickerEntry {
    static var startsOnThem = false
}

struct LanguagePickerSheet: View {
    let session: ConversationSession
    var packs: LanguagePackStore?
    @Environment(\.dismiss) private var dismiss

    private enum Side: Hashable { case me, them }

    private struct Pending: Identifiable {
        let id = UUID()
        let language: LanguageOption
        let isMe: Bool
        /// 点下去时这一边正在用的语言：下载完成后如果这一边已经被改成别的，就不再自动套用
        let previous: LanguageOption
    }

    @State private var pending: Pending?
    @State private var side: Side = LanguagePickerEntry.startsOnThem ? .them : .me
    @State private var query = ""

    private var selection: LanguageOption { side == .me ? session.me : session.them }
    private var other: LanguageOption { side == .me ? session.them : session.me }

    private var others: [LanguageOption] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return LanguageOption.all.filter { lang in
            lang != selection && (q.isEmpty || lang.nativeName.localizedCaseInsensitiveContains(q) || lang.id.localizedCaseInsensitiveContains(q)
                                  // 也认界面语言 / 英文里的叫法：搜「日语」「韩语」「Japanese」都要能找到（列表里显示的是原文名）
                                  || (AppLanguageState.shared.locale.localizedString(forIdentifier: lang.id) ?? "").localizedCaseInsensitiveContains(q)
                                  || (Locale(identifier: "en").localizedString(forIdentifier: lang.id) ?? "").localizedCaseInsensitiveContains(q)
                                  || (Locale(identifier: "zh-Hans").localizedString(forIdentifier: lang.id) ?? "").localizedCaseInsensitiveContains(q))
        }
    }

    var body: some View {
        NavigationStack {
            let request = pending
            List {
                if query.isEmpty {
                    Section("当前") { row(selection) }
                        .listRowBackground(CardRowBackground())
                }
                Section(query.isEmpty ? "全部语言" : "搜索结果") {
                    ForEach(others) { row($0) }
                    if others.isEmpty { Text("没有找到").foregroundStyle(Theme.mut) }
                }
                .listRowBackground(CardRowBackground())
            }
            .scrollContentBackground(.hidden)
            .background { AuroraBackground() }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索语言")
            .task { await packs?.refresh() }
            .onAppear { side = LanguagePickerEntry.startsOnThem ? .them : .me }          // 屏内浮层形态下视图可能被复用：每次出现都按入口对一次
            .navigationTitle("语言")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // 分段放在页头居中（代替标题），不再在搜索框和列表之间留一大块空
                ToolbarItem(placement: .principal) {
                    Picker("语言", selection: $side) {
                        Text("我的语言").tag(Side.me)
                        Text("对方语言").tag(Side.them)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 260)
                }
                DoneToolbarItem { dismiss() }
            }
            .paneConfirmation(request.map { "\($0.language.nativeName) 还没有下载" } ?? "语言",
                              message: request.map { "没有语言包就不能翻译\($0.language.nativeName)。下载后可以离线使用，下载由系统完成。" } ?? "语言",
                              actionTitle: "下载并使用",
                              isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }), role: nil) {
                guard let item = request else { return }
                Task {
                    await packs?.download(item.language)
                    let current = item.isMe ? session.me : session.them
                    if packs?.status(of: item.language) == .installed, current == item.previous {
                        choose(item.language, isMe: item.isMe)
                    }
                }
            }
        }
        .translationModalHost()          // 在语言选择里点「下载并使用」：系统「下载语言」窗口从这个弹层里弹出
        .sheetDetents([.medium, .large])
    }

    private func row(_ lang: LanguageOption) -> some View {
        Button { select(lang, isMe: side == .me) } label: {
            HStack(spacing: 10) {
                Text(lang.nativeName).foregroundStyle(Theme.fg)
                Spacer()
                statusTag(for: lang)
                if lang == selection {
                    Image(systemName: "checkmark").foregroundStyle(Theme.fg)
                } else if lang == other {
                    Text(side == .me ? "对方已选" : "我已选").font(.footnote).foregroundStyle(Theme.mut)
                }
            }
            .frame(minHeight: 44)
        }
        .accessibilityAddTraits(lang == selection ? .isSelected : [])
    }

    @ViewBuilder
    private func statusTag(for language: LanguageOption) -> some View {
        if let packs {
            switch packs.status(of: language) {
            case .installed:
                Text("离线可用").font(Theme.label).foregroundStyle(Theme.ok)
            case .downloadable:
                if packs.downloading.contains(language.id) {
                    ProgressView().controlSize(.small).accessibilityLabel("正在下载")
                } else {
                    Text("可下载").font(Theme.label).foregroundStyle(packs.isDownloading ? Theme.mut.opacity(0.5) : Theme.mut)
                }
            case .unsupported:
                Text("不支持").font(Theme.label).foregroundStyle(Theme.mut)
            case .unknown:
                EmptyView()
            }
        }
    }

    private func select(_ language: LanguageOption, isMe: Bool) {
        if let packs, packs.status(of: language) == .downloadable {
            // 已经有一种在下载：不再弹第二个确认（同时下载会让系统下载窗反复收起再弹）
            guard !packs.isDownloading else { Haptics.warning(); return }
            pending = Pending(language: language, isMe: isMe, previous: isMe ? session.me : session.them)
        } else {
            choose(language, isMe: isMe)
        }
    }

    private func choose(_ language: LanguageOption, isMe: Bool) {
        Haptics.selection()
        session.choose(language, for: isMe ? .me : .them)
    }
}
