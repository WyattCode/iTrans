import Foundation
import SwiftData

// MARK: - 对话层用到的存储协议（便于单元测试用假实现）

/// 一场对话的基本信息，保存轮次时一并带上。
struct ConversationInfo: Equatable {
    var id: UUID
    var title: String
    var me: LanguageOption
    var them: LanguageOption
    var createdAt: Date
    /// 标题是用户自己改的（不是由第一句话自动生成的）：自动标题不能再覆盖它
    var titleIsCustom = false
}

@MainActor
protocol HistoryStoring: AnyObject {
    func save(_ turn: Turn, in conversation: ConversationInfo)
    func delete(turnID: UUID)
    func deleteConversation(id: UUID)
    /// 用户重命名：之后保存新的轮次时不会再用自动标题覆盖它
    func rename(conversationID: UUID, to title: String)
    func setFavorite(_ value: Bool, conversationID: UUID)
    /// 清空全部历史（设置里的"清除对话历史"）
    func deleteAll()
    func turns(in conversationID: UUID) -> [Turn]
    func info(of conversationID: UUID) -> ConversationInfo?
}

// MARK: - SwiftData 模型

@Model
final class ConversationRecord {
    @Attribute(.unique) var id: UUID
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var meID: String
    var themID: String
    /// 收藏 / 标题是否被用户改过。有默认值，旧数据可以自动迁移。
    var isFavorite: Bool = false
    var titleIsCustom: Bool = false
    @Relationship(deleteRule: .cascade, inverse: \TurnRecord.conversation)
    var turns: [TurnRecord] = []

    init(id: UUID, title: String, createdAt: Date, meID: String, themID: String) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = createdAt
        self.meID = meID
        self.themID = themID
    }
}

@Model
final class TurnRecord {
    @Attribute(.unique) var id: UUID
    var speakerRaw: String
    var sourceText: String
    var translatedText: String?
    var engineName: String?
    var latency: Double?
    var createdAt: Date
    /// 这一轮的来源（语音 / 键盘 / 图片 / 粘贴 / 同声传译）。有默认值，旧数据可以自动迁移。
    var kindRaw: String = "voice"
    /// 这一轮当时的原文 / 译文语言（可选，旧数据没有，可以自动迁移）
    var fromID: String?
    var toID: String?
    var conversation: ConversationRecord?

    init(id: UUID, speakerRaw: String, sourceText: String, translatedText: String?,
         engineName: String?, latency: Double?, createdAt: Date, kindRaw: String = "voice",
         fromID: String? = nil, toID: String? = nil) {
        self.fromID = fromID
        self.toID = toID
        self.id = id
        self.speakerRaw = speakerRaw
        self.sourceText = sourceText
        self.translatedText = translatedText
        self.engineName = engineName
        self.latency = latency
        self.createdAt = createdAt
        self.kindRaw = kindRaw
    }
}

// MARK: - SwiftData 实现

/// 历史只存在本机（设计稿"隐私透明"原则）。
@MainActor
final class SwiftDataHistoryStore: HistoryStoring {
    let container: ModelContainer
    private var context: ModelContext { container.mainContext }

    init(container: ModelContainer) {
        self.container = container
    }

    static func makeContainer(inMemory: Bool) throws -> ModelContainer {
        try ModelContainer(
            for: ConversationRecord.self, TurnRecord.self, PhraseRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: inMemory)
        )
    }

    func save(_ turn: Turn, in info: ConversationInfo) {
        let conversation = fetchConversation(info.id) ?? {
            let new = ConversationRecord(id: info.id, title: info.title, createdAt: info.createdAt,
                                         meID: info.me.id, themID: info.them.id)
            new.titleIsCustom = info.titleIsCustom
            context.insert(new)
            return new
        }()
        // 用户改过的标题不能被"第一句话"的自动标题覆盖
        if info.titleIsCustom || !conversation.titleIsCustom {
            conversation.title = info.title
            conversation.titleIsCustom = conversation.titleIsCustom || info.titleIsCustom
        }
        conversation.meID = info.me.id
        conversation.themID = info.them.id
        conversation.updatedAt = Date()

        if let existing = fetchTurn(turn.id) {
            existing.sourceText = turn.sourceText
            existing.translatedText = turn.translatedText
            existing.engineName = turn.engineName
            existing.latency = turn.latency
        } else {
            let record = TurnRecord(
                id: turn.id, speakerRaw: turn.speaker == .me ? "me" : "them",
                sourceText: turn.sourceText, translatedText: turn.translatedText,
                engineName: turn.engineName, latency: turn.latency, createdAt: turn.createdAt,
                kindRaw: turn.kind.rawValue, fromID: turn.fromID, toID: turn.toID
            )
            record.conversation = conversation
            context.insert(record)
        }
        try? context.save()
    }

    func delete(turnID: UUID) {
        if let record = fetchTurn(turnID) {
            context.delete(record)
            try? context.save()
        }
    }

    func deleteConversation(id: UUID) {
        if let record = fetchConversation(id) {
            context.delete(record)
            try? context.save()
        }
    }

    func rename(conversationID: UUID, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let record = fetchConversation(conversationID) else { return }
        record.title = trimmed
        record.titleIsCustom = true
        try? context.save()
    }

    func setFavorite(_ value: Bool, conversationID: UUID) {
        guard let record = fetchConversation(conversationID) else { return }
        record.isFavorite = value
        try? context.save()
    }

    func deleteAll() {
        try? context.delete(model: ConversationRecord.self)
        try? context.delete(model: TurnRecord.self)
        try? context.save()
    }

    func turns(in conversationID: UUID) -> [Turn] {
        guard let conversation = fetchConversation(conversationID) else { return [] }
        return conversation.turns
            .sorted { $0.createdAt < $1.createdAt }
            .map(Self.turn(from:))
    }

    func info(of conversationID: UUID) -> ConversationInfo? {
        guard let record = fetchConversation(conversationID) else { return nil }
        let me = LanguageOption.all.first { $0.id == record.meID } ?? .zhHans
        let them = LanguageOption.all.first { $0.id == record.themID } ?? .en
        return ConversationInfo(id: record.id, title: record.title, me: me, them: them,
                                createdAt: record.createdAt, titleIsCustom: record.titleIsCustom)
    }

    // MARK: 内部

    private func fetchConversation(_ id: UUID) -> ConversationRecord? {
        var descriptor = FetchDescriptor<ConversationRecord>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    private func fetchTurn(_ id: UUID) -> TurnRecord? {
        var descriptor = FetchDescriptor<TurnRecord>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    static func turn(from record: TurnRecord) -> Turn {
        // 没有译文的轮次（当时翻译失败）载入后显示为失败，可以点重试
        let state: TurnState = record.translatedText == nil ? .failed(String(localized: "没有翻译成功")) : .done
        return Turn(
            id: record.id,
            speaker: record.speakerRaw == "me" ? .me : .them,
            sourceText: record.sourceText,
            translatedText: record.translatedText,
            state: state,
            engineName: record.engineName,
            latency: record.latency,
            createdAt: record.createdAt,
            kind: TurnKind(rawValue: record.kindRaw) ?? .voice,
            fromID: record.fromID, toID: record.toID
        )
    }
}

// MARK: - 历史列表的筛选

/// 历史页顶部的筛选：全部 / 已收藏 / 含图片。
enum HistoryFilter: String, CaseIterable, Identifiable {
    case all, favorites, withImages
    var id: String { rawValue }

    func matches(_ record: ConversationRecord) -> Bool {
        switch self {
        case .all: return true
        case .favorites: return record.isFavorite
        case .withImages: return record.turns.contains { $0.kindRaw == TurnKind.photo.rawValue }
        }
    }
}

extension HistoryFilter {
    /// 先按筛选，再按关键词（同时搜标题和每一轮的原文 / 译文）。
    static func apply(_ records: [ConversationRecord], filter: HistoryFilter, query: String) -> [ConversationRecord] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return records.filter { record in
            guard filter.matches(record) else { return false }
            guard !q.isEmpty else { return true }
            return record.title.localizedCaseInsensitiveContains(q)
                || record.turns.contains {
                    $0.sourceText.localizedCaseInsensitiveContains(q)
                        || ($0.translatedText?.localizedCaseInsensitiveContains(q) ?? false)
                }
        }
    }
}

extension ConversationRecord {
    /// 按时间顺序的轮次（SwiftData 的关系数组本身没有顺序保证）
    var orderedTurns: [TurnRecord] { turns.sorted { $0.createdAt < $1.createdAt } }

    var hasImages: Bool { turns.contains { $0.kindRaw == TurnKind.photo.rawValue } }
}
