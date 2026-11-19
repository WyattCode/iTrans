import Foundation
import SwiftData
import SwiftUI

/// 常用短语：我常说的话。`text` 用 `langID` 这种语言写成，点一下就发给对方（翻译 + 朗读）。
@Model
final class PhraseRecord {
    @Attribute(.unique) var id: UUID
    var text: String
    /// 收藏时已有的译文（仅作列表里的小字参考，发送时仍会重新翻译）
    var translatedText: String?
    var langID: String
    var pinned: Bool
    var createdAt: Date
    /// 分类（`PhraseCategory.rawValue`）；nil = 未分类。可选属性：旧数据自动迁移
    var category: String?

    init(id: UUID = UUID(), text: String, translatedText: String? = nil, langID: String,
         pinned: Bool = false, createdAt: Date = Date(), category: String? = nil) {
        self.id = id
        self.text = text
        self.translatedText = translatedText
        self.langID = langID
        self.pinned = pinned
        self.createdAt = createdAt
        self.category = category
    }
}

/// 常用短语的分类（Duo 内屏双栏的左 / 上屏目录）。`all` / `pinned` 是视图，其余是可指定的分类。
enum PhraseCategory: String, CaseIterable, Identifiable {
    case all, pinned, directions, food, stay, emergency, shopping, other
    var id: String { rawValue }
    var title: LocalizedStringKey {
        switch self {
        case .all: return "全部"
        case .pinned: return "置顶"
        case .directions: return "问路"
        case .food: return "点餐"
        case .stay: return "住宿"
        case .emergency: return "紧急"
        case .shopping: return "购物"
        case .other: return "未分类"
        }
    }
    var symbol: String {
        switch self {
        case .all: return "tray.full"
        case .pinned: return "pin"
        case .directions: return "mappin.and.ellipse"
        case .food: return "fork.knife"
        case .stay: return "bed.double"
        case .emergency: return "exclamationmark.triangle"
        case .shopping: return "bag"
        case .other: return "ellipsis.circle"
        }
    }
    /// 可以让用户指定的分类
    static let assignable: [PhraseCategory] = [.directions, .food, .stay, .emergency, .shopping]

    func contains(_ phrase: PhraseRecord) -> Bool {
        switch self {
        case .all: return true
        case .pinned: return phrase.pinned
        case .other: return !Self.assignable.contains { $0.rawValue == phrase.category }
        default: return phrase.category == rawValue
        }
    }
}

enum PhraseLibrary {
    /// 收藏一条短语。同一种语言里文字相同的不重复收藏，返回 false。
    @MainActor
    @discardableResult
    static func add(text: String, translated: String?, language: LanguageOption, in context: ModelContext) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let langID = language.id
        let descriptor = FetchDescriptor<PhraseRecord>(predicate: #Predicate { $0.text == trimmed && $0.langID == langID })
        if let existing = try? context.fetch(descriptor), !existing.isEmpty { return false }
        context.insert(PhraseRecord(text: trimmed, translatedText: translated, langID: langID))
        try? context.save()
        return true
    }

    @MainActor
    static func contains(text: String, language: LanguageOption, in context: ModelContext) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let langID = language.id
        let descriptor = FetchDescriptor<PhraseRecord>(predicate: #Predicate { $0.text == trimmed && $0.langID == langID })
        return ((try? context.fetchCount(descriptor)) ?? 0) > 0
    }

    @MainActor
    static func delete(_ phrase: PhraseRecord, in context: ModelContext) {
        context.delete(phrase)
        try? context.save()
    }

    @MainActor
    static func togglePinned(_ phrase: PhraseRecord, in context: ModelContext) {
        phrase.pinned.toggle()
        try? context.save()
    }

    /// 置顶的在前，其余按收藏时间倒序。
    static func sorted(_ phrases: [PhraseRecord]) -> [PhraseRecord] {
        phrases.sorted { a, b in
            if a.pinned != b.pinned { return a.pinned }
            return a.createdAt > b.createdAt
        }
    }
}
