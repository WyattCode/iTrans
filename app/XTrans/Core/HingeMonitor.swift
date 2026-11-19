import SwiftUI
import UIKit

/// 铰链状态（iOS 27.1+ 的 `UIHingeInteraction`）。只有带铰链的设备（iPhone Duo 展开时）才会有状态；
/// 其他设备永远是 `.unknown`。用来在"半开立起来"（帐篷摆放）时自动切换成左右分屏。
@MainActor
@Observable
final class HingeMonitor {
    enum Status: Equatable { case unknown, closed, partiallyOpen, fullyOpen }

    private(set) var status: Status = .unknown
    /// 铰链角度（弧度），系统不保证更新频率和精度，所以只用来显示 / 调试，判断用 `status`。
    private(set) var angle: Double?

    /// 折叠区域（铰链），窗口坐标。没有铰链的设备永远是空的。
    private(set) var regions: [FoldRegion] = []

    /// 当前正在折叠（有区域在起作用）时的折叠区域。
    var activeFold: FoldRegion? { regions.first { $0.isActive } }

    func apply(status: Status, angle: Double?) {
        if self.status != status { self.status = status }
        if self.angle != angle { self.angle = angle }
    }

    func apply(regions: [FoldRegion]) {
        if self.regions != regions { self.regions = regions }
    }
}

/// 铰链（折叠处）占据的区域。`frame` 在整个窗口的坐标系里（点）。
struct FoldRegion: Equatable {
    var frame: CGRect
    var isActive: Bool
}

/// 全屏大小、看不见的 UIView：挂上铰链监听，并在布局变化 / 铰链变化时读取折叠区域（`reservedRegions`）。
final class FoldSensingView: UIView {
    weak var monitor: HingeMonitor?
    private var hingeInteraction: AnyObject?
    /// 正在等「折叠区域」跟上铰链状态的任务（见 `hingeChanged`）
    private var settling: Task<Void, Never>?
    private var lastFlip: Date?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        if #available(iOS 27.1, *) {
            let interaction = UIHingeInteraction { [weak self] _, update in
                self?.hingeChanged(update.hinge)
            }
            addInteraction(interaction)
            hingeInteraction = interaction
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        // 没有铰链事件在等结果时（转屏等）才由布局驱动；有事件在等时由 `settling` 一次性提交
        if settling == nil { commit(status: nil, angle: nil, regions: readRegions()) }
    }

    @available(iOS 27.1, *)
    private func hingeChanged(_ hinge: UIHinge?) {
        guard monitor != nil else { return }
        guard let hinge else {
            settling?.cancel(); settling = nil
            commit(status: .unknown, angle: nil, regions: readRegions())      // 离开了提供铰链信息的层级
            return
        }
        let status: HingeMonitor.Status
        switch hinge.status {
        case .closed: status = .closed
        case .partiallyOpen: status = .partiallyOpen
        case .fullyOpen: status = .fullyOpen
        default: status = .unknown
        }
        let angle = Double(hinge.angle)
        // 系统先报「状态变了」，折叠区域（reservedRegions）要等下一次布局才跟上——模拟器实测折起来时晚 0.7 秒：
        // 先应用状态会先按旧区域排一遍（折到一半没反应），区域到了又再变一次（先错后对，「先拉长再突然 50:50」）。
        // 所以状态和区域攒到一起、一次提交：主动触发布局、每 30ms 读一次，区域和状态一致就提交（最多等 1 秒）。
        settling?.cancel()
        let expectActive = status == .partiallyOpen
        settling = Task { @MainActor [weak self] in
            var found: [FoldRegion] = []
            for _ in 0..<34 {
                guard let self, !Task.isCancelled else { return }
                self.setNeedsLayout()
                self.layoutIfNeeded()
                found = self.readRegions()
                if found.contains(where: \.isActive) == expectActive || status == .unknown || status == .closed { break }
                try? await Task.sleep(for: .milliseconds(30))
            }
            guard let self, !Task.isCancelled else { return }
            // 防抖：手在半开的临界角附近晃，系统会连着报「半开 / 展平」。刚翻过一次（0.6 秒内）又要翻回去时，
            // 先等 0.25 秒看它稳不稳——期间来了新事件，这个任务会被取消，按最新的状态重新来
            if let last = self.lastFlip, Date().timeIntervalSince(last) < 0.6,
               (self.monitor?.activeFold != nil) != found.contains(where: \.isActive) {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
            }
            self.settling = nil
            self.commit(status: status, angle: angle, regions: found)
        }
    }

    /// 提交状态和折叠区域。折叠 / 展平（区域是否起作用）变了时整页溶解过渡：对话、说话区、键盘输入卡片都是同一种过渡，
    /// 不再是「有的瞬间跳、有的各自动」。
    private func commit(status: HingeMonitor.Status?, angle: Double?, regions: [FoldRegion]) {
        guard let monitor else { return }
        let flips = (monitor.activeFold != nil) != regions.contains(where: \.isActive)
        let apply = {
            if let status { monitor.apply(status: status, angle: angle) }
            monitor.apply(regions: regions)
        }
        if flips { lastFlip = Date() }
        // 合上（内屏熄灭、窗口正在换到外屏）不做快照溶解：内屏的快照会被拉伸到外屏的尺寸，压扁着淡出
        if flips, window != nil, status != .closed {
            crossfadePage(reduceMotion: UIAccessibility.isReduceMotionEnabled, apply)
        } else {
            apply()
        }
    }

    /// 折叠区域：只有 iOS 27.1+ 的 Duo 才有；其他设备永远是空的。
    private func readRegions() -> [FoldRegion] {
        guard #available(iOS 27.1, *), window != nil else { return [] }
        return reservedRegions(kind: .division, options: [.includeInactive]).map {
            FoldRegion(frame: convert($0.frame, to: nil), isActive: $0.isActive)
        }
    }
}

/// 放进视图层级里（铺满屏幕）的铰链 / 折叠区域监听。
struct HingeObserver: UIViewRepresentable {
    let monitor: HingeMonitor

    func makeUIView(context: Context) -> FoldSensingView {
        let view = FoldSensingView()
        view.monitor = monitor
        return view
    }

    func updateUIView(_ uiView: FoldSensingView, context: Context) {
        uiView.monitor = monitor
    }
}

/// 双屏摆放：左右分屏（帐篷）还是上下分屏。
enum TentMode: String, CaseIterable, Identifiable {
    case auto, on, off
    var id: String { rawValue }
    var title: String {
        switch self {
        case .auto: return String(localized: "自动")
        case .on: return String(localized: "左右分屏")
        case .off: return String(localized: "上下分屏")
        }
    }
}
