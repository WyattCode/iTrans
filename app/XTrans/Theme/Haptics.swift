import UIKit

/// 共用的触觉生成器：每次现分配一个生成器，第一次触发会晚几十毫秒；共用一份并在用完 / 按下时 `prepare()`，下一次就是即时的。
@MainActor
enum Haptics {
    private static let impact = UIImpactFeedbackGenerator(style: .light)
    private static let notification = UINotificationFeedbackGenerator()
    private static let selectionGenerator = UISelectionFeedbackGenerator()

    /// 手指按到按钮上时调用：让引擎提前醒着
    static func prepare() {
        impact.prepare()
        notification.prepare()
        selectionGenerator.prepare()
    }

    static func light() { impact.impactOccurred(); impact.prepare() }
    static func success() { notification.notificationOccurred(.success); notification.prepare() }
    static func warning() { notification.notificationOccurred(.warning); notification.prepare() }
    static func selection() { selectionGenerator.selectionChanged(); selectionGenerator.prepare() }
}
