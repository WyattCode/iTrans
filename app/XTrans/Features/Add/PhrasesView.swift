import SwiftData
import SwiftUI

/// PH · 常用短语：我常说的话，点一下就翻译并朗读给对方，同时写进对话。
/// 只列出用"我现在说的语言"写的短语。
struct PhrasesView: View {
    let session: ConversationSession
    let onSent: () -> Void

    @Environment(\.modelContext) private var context
    @State private var query = ""
    @State private var adding = false
    @State private var newText = ""
    @State private var duplicate = false
    @State private var category: PhraseCategory = .all

    var body: some View {
        // Duo 的屏里推进来的页面没有系统返回：自己画页头（返回 + 标题 + 添加）
        PaneAware { duo in
            if duo {
                PaneDetailPage(title: "常用短语", trailing: AnyView(addButton)) {
                    // 屏内没有分类条（已知缺口）：页头是浮条，会给里面所有滚动视图加顶部边距 + 渐隐遮罩，
                    // 直接把分类条叠在列表上面会被页头盖住 / 顶出一大块空白；Duo 内屏在模拟器里看不了，没把握就不加
                    PhrasesList(session: session, query: query, onSent: onSent)
                }
            } else {
                standardBody
            }
        }
        .paneTextPrompt("添加短语", prompt: "用\(session.me.nativeName)写一句常说的话", actionTitle: "添加",
                        isPresented: $adding, text: $newText) {
            // 什么都没写就点「添加」：什么也不做（原来被当成「重复」，弹「这句已经在短语里了」）
            if newText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return }
            if PhraseLibrary.add(text: newText, translated: nil, language: session.me, in: context) {
                // 在某个具体分类里添加：新短语就归到这个分类
                if PhraseCategory.assignable.contains(category) {
                    let text = newText.trimmingCharacters(in: .whitespacesAndNewlines)
                    let langID = session.me.id
                    let descriptor = FetchDescriptor<PhraseRecord>(predicate: #Predicate { $0.text == text && $0.langID == langID })
                    if let phrase = try? context.fetch(descriptor).first { phrase.category = category.rawValue; try? context.save() }
                }
            } else { duplicate = true }
        }
        .alert("这句已经在短语里了", isPresented: $duplicate) { Button("好") {} }
    }

    /// 分类胶囊条：全部 / 置顶 / 问路 / 点餐 / 住宿 / 紧急 / 购物 / 未分类（长按短语可「移到分类」）
    private var categoryBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(PhraseCategory.allCases) { item in
                    Button { category = item } label: {
                        Label(item.title, systemImage: item.symbol)
                            .labelStyle(.titleOnly)
                            .font(.subheadline.weight(category == item ? .semibold : .regular))
                            .foregroundStyle(Theme.fg)
                            .padding(.horizontal, 14).frame(minHeight: 36)
                            .background(category == item ? Theme.control.opacity(0.4) : Theme.fg.opacity(0.08), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(category == item ? .isSelected : [])
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
        }
    }

    private var addButton: some View {
        Button { newText = ""; adding = true } label: {
            Image(systemName: "plus")
                .font(.system(size: 17))
                .foregroundStyle(Theme.fg)
                .frame(width: 44, height: 44)
                .glass(in: Circle(), interactive: true)
        }
        .accessibilityLabel("添加短语")
    }

    private var standardBody: some View {
        PhrasesList(session: session, query: query, category: category, onSent: onSent)
            .contentMargins(.top, 0, for: .scrollContent)
            .safeAreaInset(edge: .top, spacing: 0) { categoryBar }
            .background { PageBackground() }
            .containerBackground(.clear, for: .navigation)      // 推进来的页面默认是系统实色底（浅色下是一块白板）；Duo 的屏里底是 DuoPanes 的极光
            .navigationTitle("常用短语")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: "搜索短语")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { newText = ""; adding = true } label: { Label("添加短语", systemImage: "plus") }
                }
            }
    }
}

/// 短语列表本体（不带标题栏 / 搜索），宽屏的工具面板里直接内嵌它。
struct PhrasesList: View {
    let session: ConversationSession
    var query = ""
    /// 只列这个分类（Duo 双栏）
    var category: PhraseCategory = .all
    /// 宽屏工具面板里内嵌时：没有短语就收成一行虚线提示（不是大块空状态），行高 52
    var embedded = false
    let onSent: () -> Void

    @Environment(\.modelContext) private var context
    @Query(sort: \PhraseRecord.createdAt, order: .reverse) private var all: [PhraseRecord]

    private var phrases: [PhraseRecord] {
        let mine = all.filter { $0.langID == session.me.id && category.contains($0) }
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = q.isEmpty ? mine : mine.filter {
            $0.text.localizedCaseInsensitiveContains(q) || ($0.translatedText?.localizedCaseInsensitiveContains(q) ?? false)
        }
        return PhraseLibrary.sorted(filtered)
    }

    var body: some View {
        Group {
            if phrases.isEmpty && embedded {
                Text("长按你说过的话 → 收藏为短语")
                    .font(.footnote)          // 随系统字号缩放（原来固定 15pt）
                    .foregroundStyle(Theme.mut)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, minHeight: 64)
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Theme.fg.opacity(0.2), style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .frame(maxHeight: .infinity, alignment: .top)
            } else if phrases.isEmpty {
                ContentUnavailableView(
                    query.isEmpty ? "还没有短语" : "没有找到",
                    systemImage: "book",
                    description: Text(query.isEmpty
                        ? "在对话里长按你说过的话，选“收藏为短语”，或点星标。"
                        : "换个关键词试试。")
                )
            } else {
                list
            }
        }
    }

    private var list: some View {
        List {
            ForEach(phrases) { phrase in
                Button {
                    // 正在聆听时发不出去：先结束聆听，不关闭面板，让用户再点一次
                    if session.sendText(phrase.text) { onSent() } else if session.isListening { session.stopListening() }
                } label: {
                    row(phrase)
                }
                .listRowBackground(CardRowBackground())
                .contextMenu {
                    Menu("移到分类") {
                        ForEach(PhraseCategory.assignable) { item in
                            Button { phrase.category = item.rawValue; try? context.save() } label: { Label(item.title, systemImage: item.symbol) }
                        }
                        Button { phrase.category = nil; try? context.save() } label: { Label("未分类", systemImage: PhraseCategory.other.symbol) }
                    }
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(role: .destructive) { PhraseLibrary.delete(phrase, in: context) } label: {
                        Label("删除", systemImage: "trash")
                    }
                    .tint(Theme.err)
                }
                .swipeActions(edge: .leading) {
                    Button { PhraseLibrary.togglePinned(phrase, in: context) } label: {
                        Label(phrase.pinned ? "取消置顶" : "置顶", systemImage: phrase.pinned ? "pin.slash" : "pin")
                    }
                    .tint(Theme.control)       // meFill 上的白字只有 3.3:1，和历史页的收藏滑动按钮一致用 control
                }
            }
        }
        .dismissKeyboardInScrollArea()
        .scrollContentBackground(.hidden)
        .duoListInset()
        .environment(\.defaultMinListRowHeight, embedded ? 52 : 44)
        .modifier(EmbeddedListMargins(embedded: embedded))
    }

    private func row(_ phrase: PhraseRecord) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if phrase.pinned {
                        Image(systemName: "pin.fill").font(.system(size: 11)).foregroundStyle(Theme.meText)
                    }
                    Text(phrase.text)
                        .font(.system(.body).weight(.semibold))
                        .foregroundStyle(Theme.fg)
                }
                if let translated = phrase.translatedText {
                    Text(translated).font(Theme.caption).foregroundStyle(Theme.sub)
                }
            }
            Spacer(minLength: 8)
            Image(systemName: "speaker.wave.2")
                .foregroundStyle(Theme.fg)
                .frame(width: 44, height: 44)
        }
        .frame(minHeight: 44)
        .accessibilityElement(children: .combine)
        .accessibilityHint("点按后翻译并朗读给对方")
    }
}


/// 内嵌在加入面板里时：紧贴上面的「常用短语」标题（原来列表顶端空了一大块）、左右 20pt 和磁贴 / 分隔线对齐。
/// 非内嵌时一律不动内容边距——外面的浮条（页头）要靠它给列表让位，写 0 会把它盖掉（第一行被页头压住）
private struct EmbeddedListMargins: ViewModifier {
    let embedded: Bool
    func body(content: Content) -> some View {
        if embedded {
            content
                .contentMargins(.top, 4, for: .scrollContent)
                .contentMargins(.horizontal, 20, for: .scrollContent)
        } else {
            content
        }
    }
}
