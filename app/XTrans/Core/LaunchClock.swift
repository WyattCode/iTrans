import Foundation

/// 启动计时（`-XTransLaunchTiming`，Release 也生效）：打印 `LAUNCHTIME <阶段> +N ms`，只含标签和毫秒。
/// 用来查「冷启动到出现内容」慢在哪一段；不带这个参数时什么都不做。
enum LaunchClock {
    static let enabled = ProcessInfo.processInfo.arguments.contains("-XTransLaunchTiming")
    private static let start = Date()
    nonisolated(unsafe) private static var seen: Set<String> = []

    /// 每个标签只打一次（`body` 会反复求值）
    static func mark(_ label: String) {
        guard enabled else { return }
        _ = start
        guard seen.insert(label).inserted else { return }
        print("LAUNCHTIME \(label) +\(Int(Date().timeIntervalSince(start) * 1000)) ms wall=\(String(format: "%.2f", Date().timeIntervalSince1970))")
    }
}
