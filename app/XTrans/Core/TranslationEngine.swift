import Foundation

/// 翻译引擎协议：对话层只依赖它，方便替换实现。
@MainActor
protocol TranslationEngine: AnyObject {
    /// 引擎的**稳定标识符**（如 "apple"）。它会被存进历史数据库，所以不能随界面语言变；
    /// 显示给用户时用 `EngineDisplay.name(for:)` 转成当前界面语言的名字。
    var name: String { get }
    func translate(_ text: String, from: LanguageOption, to: LanguageOption) async throws -> String
}

enum TranslationFailure: LocalizedError {
    case unavailable(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .unavailable(let reason): return reason
        case .cancelled: return String(localized: "翻译已取消")
        }
    }
}

/// 演示 / 测试用引擎：内置一小本中英短语，其余加上 [译] 前缀。
/// 用于模拟器（Apple 翻译框架在模拟器上不一定可用）和单元测试。
@MainActor
final class MockTranslationEngine: TranslationEngine {
    let name = EngineDisplay.demoID
    var delay: Duration = .milliseconds(300)

    private static let book: [(zh: String, en: String)] = [
        ("你好！欢迎来到东京。", "Hello! Welcome to Tokyo."),
        ("请问最近的地铁站怎么走？", "Excuse me, how do I get to the nearest subway station?"),
        ("一直往前走，然后在红绿灯左转。", "Go straight and turn left at the traffic light."),
        ("多少钱？", "How much is it?"),
        ("谢谢！", "Thank you!"),
    ]

    func translate(_ text: String, from: LanguageOption, to: LanguageOption) async throws -> String {
        try await Task.sleep(for: delay)
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for pair in Self.book {
            if from.isChinese, to.id == "en", pair.zh == t { return pair.en }
            if from.id == "en", to.isChinese, pair.en == t { return pair.zh }
        }
        return "[\(to.nativeName)] \(t)"
    }
}

/// 引擎标识符 ↔ 界面上显示的名字。
/// 旧版本直接把中文显示名（"Apple 端侧"、"演示引擎"）存进了历史，这里一并识别，保证旧记录在任何语言下都显示正确。
enum EngineDisplay {
    static let appleID = "apple"
    static let demoID = "demo"

    static func name(for stored: String) -> String {
        switch stored {
        case appleID, "Apple 端侧": return String(localized: "Apple 端侧")
        case demoID, "演示引擎": return String(localized: "演示引擎")
        default: return stored      // 未知的按原样显示
        }
    }
}
