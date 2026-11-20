import SwiftUI

/// D4 · 历史（主-详细）的右边：只读地看一场对话，可以分享，或者接着聊。
struct HistoryDetailView: View {
    let record: ConversationRecord
    let onContinue: () -> Void
    /// 宽屏分栏里页头和"分享 / 接着聊"由外层画（和整屏面板的页头对齐），这里只留对话本身
    var showsChrome = true
    /// Duo 外屏：分享 / 接着聊放进系统的竖排栏（和其他页的按钮同一列），底部不再放通栏按钮
    @Environment(\.inRailPane) private var inRailPaneEnv
    @Environment(\.inDuoPane) private var inDuoPane
    /// 外屏的系统竖排栏（Duo 内屏的屏里系统栏是隐藏的，页头自己画）
    private var inRailPane: Bool { inRailPaneEnv && !inDuoPane }

    private var me: LanguageOption { LanguageOption.with(id: record.meID) ?? .zhHans }
    private var them: LanguageOption { LanguageOption.with(id: record.themID) ?? .en }
    private var turns: [TurnRecord] { record.orderedTurns }
    /// 每条下面标不标引擎名（只有一种引擎，不标）
    private var showsEngine: Bool { false }

    var body: some View {
        VStack(spacing: 0) {
            // Duo 的屏里页头是浮条（盖在内容上、内容在它下面渐隐）：自己的标题块如果放在滚动区外面会被浮条整个盖掉，
            // 而且滚动区还会再让出一次 64pt（空白翻倍）——所以放进滚动内容里
            if showsChrome && !inDuoPane { header }
            ScrollView {
                LazyVStack(spacing: 14) {
                    if showsChrome && inDuoPane { header.padding(.horizontal, -20).padding(.horizontal, 0) }
                    ForEach(turns) { turn in
                        DetailBubble(turn: SwiftDataHistoryStore.turn(from: turn), showsEngine: showsEngine)
                    }
                }
                .padding(.horizontal, (showsChrome && !inDuoPane) ? 16 : 20)
                .padding(.vertical, 12)
            }
            if showsChrome && !inRailPane { actionBar }
        }
        .background { if showsChrome { PageBackground() } }
        .toolbar {
            if showsChrome && inRailPane {
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(item: record.exportText) { BarLabel("分享", symbol: "square.and.arrow.up") }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: onContinue) { BarLabel("接着聊", symbol: "arrow.right.circle") }
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(record.title)
                    .font(.system(.title3).weight(.bold))
                    .foregroundStyle(Theme.fg)
                    .lineLimit(2)
                Spacer(minLength: 8)
                Text("\(me.shortName) ⇄ \(them.shortName)")
                    .font(Theme.label)
                    .foregroundStyle(Theme.fg)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Theme.meFill.opacity(0.14), in: Capsule())
                    .fixedSize()
            }
            Text("\(record.updatedAt.appFormatted(date: .abbreviated, time: .shortened)) · \(record.turns.count) 条")
                .font(Theme.caption)
                .foregroundStyle(Theme.mut)
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private var actionBar: some View {
        HStack(spacing: 10) {
            ShareLink(item: record.exportText) {
                Label("分享", systemImage: "square.and.arrow.up")
                    .font(.system(.subheadline).weight(.semibold))
                    .foregroundStyle(Theme.fg)
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .glass(in: Capsule())
            }
            Button(action: onContinue) {
                Label("接着聊", systemImage: "arrow.right.circle")
                    .font(.system(.subheadline).weight(.semibold))
                    .foregroundStyle(Theme.fg)
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .primaryGlass(in: Capsule())
            }
        }
        .padding(.horizontal, inDuoPane ? 20 : 16)
        .padding(.vertical, 10)
    }
}

/// 一条消息（只读）：我的消息主文是原话、对方的是译文，和对话流一致。
private struct DetailBubble: View {
    let turn: Turn
    var showsEngine = false
    private var isMe: Bool { turn.speaker == .me }
    private var mainText: String { (isMe ? turn.sourceText : turn.translatedText) ?? turn.sourceText }
    private var subText: String { (isMe ? turn.translatedText : turn.sourceText) ?? "" }

    var body: some View {
        VStack(alignment: isMe ? .trailing : .leading, spacing: 4) {
            VStack(alignment: .leading, spacing: 4) {
                Text(mainText).font(.system(.body).weight(.semibold)).foregroundStyle(Theme.fg)
                if !subText.isEmpty, subText != mainText {
                    Text(subText).font(.system(.subheadline)).foregroundStyle(Theme.sub)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(isMe ? Theme.bubbleMe : Theme.bubbleThem, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .frame(maxWidth: 360, alignment: isMe ? .trailing : .leading)
            MetaLine(text: meta, alignment: isMe ? .trailing : .leading) { EmptyView() }
            .font(Theme.caption).foregroundStyle(Theme.mut).padding(.horizontal, 6)
        }
        .frame(maxWidth: .infinity, alignment: isMe ? .trailing : .leading)
        .accessibilityElement(children: .combine)
    }

    private var meta: String {
        let who = isMe ? String(localized: "我") : String(localized: "对方")
        let time = turn.createdAt.appFormatted(date: .omitted, time: .shortened)
        guard let kind = turn.kind.label else { return "\(who) · \(time)" }
        return "\(who) · \(time) · \(kind)"
    }
}

@MainActor
extension ConversationRecord {
    /// 导出成纯文本：标题 + 整场对话（原文和译文）。不用先载入对话。
    var exportText: String {
        let me = LanguageOption.with(id: meID) ?? .zhHans
        let them = LanguageOption.with(id: themID) ?? .en
        let turns = orderedTurns.map(SwiftDataHistoryStore.turn(from:))
        return title + "\n\n" + ConversationSession.transcript(turns: turns, me: me, them: them)
    }
}
