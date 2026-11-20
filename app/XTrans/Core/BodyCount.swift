import Foundation
import QuartzCore

/// 调试 / 性能用的钩子：数每个视图的 `body` 被求值了多少次（`-XTransCountBodies`）和几个性能对照开关。
/// 只在 Debug 或带 `PERF_HOOKS` 编译条件时才有内容（`xcodebuild ... SWIFT_ACTIVE_COMPILATION_CONDITIONS=PERF_HOOKS`），
/// 发布版里这些全是空实现，每次 body 不做任何事。
enum BodyCount {
    #if DEBUG || PERF_HOOKS
    nonisolated(unsafe) private static var counts: [String: Int] = [:]
    static let noGlass = ProcessInfo.processInfo.arguments.contains("-XTransPerfNoGlass")
    static let noAurora = ProcessInfo.processInfo.arguments.contains("-XTransPerfNoAurora")
    static let noMask = ProcessInfo.processInfo.arguments.contains("-XTransPerfNoMask")
    static let enabled = ProcessInfo.processInfo.arguments.contains("-XTransCountBodies")

    @discardableResult
    static func hit(_ name: String) -> Bool {
        if enabled { counts[name, default: 0] += 1 }
        return true
    }

    /// 每秒打印一次累计值（标准错误，`simctl launch --console` 能看到）
    static func startReporting() {
        guard enabled else { return }
        Task { @MainActor in
            var tick = 0
            while true {
                try? await Task.sleep(for: .seconds(1))
                tick += 1
                let line = counts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
                FileHandle.standardError.write(Data("BODYCOUNT t=\(tick) \(line)\n".utf8))
            }
        }
    }
    #else
    static let noGlass = false
    static let noAurora = false
    static let noMask = false
    @discardableResult @inline(__always) static func hit(_ name: String) -> Bool { true }
    @inline(__always) static func startReporting() {}
    #endif
}

#if DEBUG || PERF_HOOKS
/// 调试：`-XTransHitchLog` 用 CADisplayLink 量主线程卡顿——每一帧间隔超过 26ms（约 1.5 帧）就在系统日志里记一行
/// `XTHITCH <毫秒> t=<unix 秒>`，和自动点屏脚本的时间对起来就知道「哪一次打开卡了多久」。
enum HitchLog {
    nonisolated(unsafe) private static var link: CADisplayLink?
    nonisolated(unsafe) private static let target = HitchTarget()
    static let enabled = ProcessInfo.processInfo.arguments.contains("-XTransHitchLog")

    @MainActor
    static func start() {
        guard enabled, link == nil else { return }
        let display = CADisplayLink(target: target, selector: #selector(HitchTarget.tick(_:)))
        display.add(to: .main, forMode: .common)
        link = display
    }
}

private final class HitchTarget: NSObject {
    private var last: CFTimeInterval = 0
    @objc func tick(_ display: CADisplayLink) {
        let now = display.timestamp
        if last > 0, now - last > 0.026 {
            NSLog("XTHITCH %.0f t=%.3f", (now - last) * 1000, Date().timeIntervalSince1970)
        }
        last = now
    }
}
#endif

/// 走查用的启动开关（只在 Debug / PERF_HOOKS 里有；发布版恒为空）。
enum DebugFlags {
    static var settingsCategory: String? {
        #if DEBUG || PERF_HOOKS
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-XTransSettingsCategory"), i + 1 < args.count else { return nil }
        return args[i + 1]
        #else
        return nil
        #endif
    }
}
