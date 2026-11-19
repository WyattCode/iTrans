import SwiftUI

/// 玻璃麦克风：一颗着色玻璃球。
/// 手指一按下就开始听（零等待）：按住超过 `holdThreshold` = 对讲机，松手结束；
/// 更快抬起 = 轻点，改成自动模式（停顿自动结束）。已经在听时按下 = 轻点停止。
struct MicButton: View {
    enum Appearance { case idle, listening, dimmed, error, blocked }

    let speaker: Speaker
    let appearance: Appearance
    let onTap: () -> Void
    /// 按下时调用。返回 true = 已经开始聆听（对讲）；false = 没有开始（已经在听 / 权限被拒），松手按轻点处理。
    let onHoldBegan: () -> Bool
    /// 按下时已开始聆听，但很快抬起：转成轻点（自动模式）
    let onHoldPromotedToTap: () -> Void
    let onHoldEnded: () -> Void
    /// 手指刚落下（防误触等待开始的同时）：提前预热音频，真正开始听时少等一截
    var onTouchDown: () -> Void = {}

    @State private var pressing = false
    @State private var holding = false
    /// 这一次按下是不是由本按钮开始了聆听
    @State private var startedHere = false
    @State private var holdTask: Task<Void, Never>?
    /// 手指是否还按在按钮上。系统取消手势（来电、控制中心、滚动接管）时 onEnded 不会被调用，
    /// 但 GestureState 会自动回到 false——靠它收尾，免得"按住说话"一直开着。
    @GestureState private var touching = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var tint: Color {
        if appearance == .error || appearance == .blocked { return Theme.warn }
        return speaker == .me ? Theme.meFill : Theme.themFill
    }
    private var isAlert: Bool { appearance == .error || appearance == .blocked }
    private var symbol: String {
        switch appearance {
        case .listening: return "stop.fill"
        case .blocked: return "mic.slash.fill"
        default: return "mic.fill"
        }
    }
    /// 每出现一次"没听清"加 1，驱动一次抖动
    @State private var shakeCount = 0
    /// 开了"减少动态效果"时不抖，改成一次短促的变淡（透明度变化不算运动）
    @State private var pulse = false
    private let size: CGFloat = 76
    /// 按多久算"按住"（对讲）。短于它就是轻点。聆听本身在按下的瞬间就开始了，这个值只决定松手后怎么收尾。
    static let holdThreshold: Duration = .milliseconds(200)
    /// 按下后先等这么久再开始聆听：手掌蹭一下、误触（比这还短）不会开麦、也不会弹权限框；人的有意按压远比这长。
    static let graceDelay: Duration = .milliseconds(10)
    /// 测试钩子：麦克风视图被创建（挂到界面上）的累计次数。长按进行中它不该增加——增加 = 麦克风被销毁重建，手势被取消
    nonisolated(unsafe) private(set) static var mountCount = 0
    /// 现在有几个麦克风被手指按着。启动后的后台预热（冻结窗口、切页再切回）据此等手松开再做——页面被重建会取消正在进行的长按
    nonisolated(unsafe) private(set) static var pressingCount = 0

    var body: some View {
        let _ = BodyCount.hit("MicButton")
        ZStack {
            Image(systemName: symbol)
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(Theme.fg)
                .contentTransition(reduceMotion ? .opacity : .symbolEffect(.replace))      // 麦克风 ⇄ 停止 ⇄ 无权限：图标自己变形，不硬切
                .frame(width: size, height: size)
                .glass(in: Circle(), tint: tint, interactive: true)
                .overlay(Circle().strokeBorder(tint.opacity(isAlert ? 0.95 : 0.5), lineWidth: isAlert ? 2.5 : 1))
                .shadow(color: tint.opacity(appearance == .dimmed ? 0 : 0.28), radius: 16, y: 8)
                .scaleEffect(pressing && !reduceMotion ? 0.94 : 1)       // 减少动态效果：不缩放，只靠下面的透明度变化表示按下
                .opacity(appearance == .dimmed ? 0.55 : (pulse ? 0.45 : (pressing && reduceMotion ? 0.8 : 1)))
                .animation(.easeOut(duration: 0.2), value: pulse)
                .animation(.snappy(duration: 0.18), value: pressing)
                // 外圈 / 阴影 / 图标换成"没听清"的样子时淡着过去，不要硬跳
                .animation(reduceMotion ? .reduced : .easeOut(duration: 0.25), value: appearance)
                // 一条连续衰减的左右摆动（不再是几段各自独立的小动画拼起来的）
                .keyframeAnimator(initialValue: CGFloat(0), trigger: shakeCount) { view, dx in
                    view.offset(x: dx)
                } keyframes: { _ in
                    KeyframeTrack {
                        CubicKeyframe(-6, duration: 0.07)
                        CubicKeyframe(5, duration: 0.09)
                        CubicKeyframe(-3, duration: 0.09)
                        CubicKeyframe(1.5, duration: 0.08)
                        CubicKeyframe(0, duration: 0.09)
                    }
                }
        }
        .frame(width: size + 16, height: size + 16)   // 触控区 ≥ 44pt
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .updating($touching) { _, state, _ in state = true }
                .onChanged { _ in pressBegan() }
                .onEnded { _ in pressEnded() }
        )
        .onChange(of: touching) { _, now in
            guard !now, pressing else { return }
            // 正常松手时 onEnded 会把 pressing 清掉；稍等一下还没清，才说明手势是被系统取消的。
            // （不依赖 onEnded 和 GestureState 复位的先后顺序，免得正常的点按被当成取消。）
            Task {
                try? await Task.sleep(for: .milliseconds(80))
                if pressing, !touching { pressCancelled() }
            }
        }
        .onAppear { Self.mountCount += 1 }
        .onDisappear { if pressing { pressCancelled() } }
        // 没听清：外圈变琥珀色并轻轻抖一下（"让麦克风自己说话"，不再弹卡片）
        .onChange(of: appearance) { _, new in
            guard new == .error else { return }
            // 「没听清」的警告触感不放在这里：Duo 上面对面页和说话区各有一个麦克风同时存活，会响两次。由根上的 RootObservers 按会话计数响一次
            if reduceMotion {
                pulse = true
                Task {
                    try? await Task.sleep(for: .milliseconds(260))
                    pulse = false
                }
            } else {
                shakeCount += 1
            }
        }
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onTap() }
    }

    private var label: String {
        let who = speaker == .me ? String(localized: "我") : String(localized: "对方")
        if appearance == .blocked { return String(localized: "麦克风现在不可用（\(who)）") }          // 原来不可用时也读「开始说话」
        return appearance == .listening ? String(localized: "停止聆听（\(who)）") : String(localized: "开始说话（\(who)）")
    }

    private func pressBegan() {
        guard !pressing else { return }          // 触摸移动时每个事件都会进来：prepare 要放在这个 guard 后面
        Haptics.prepare()
        onTouchDown()
        Self.pressingCount += 1
        pressing = true
        holding = false
        startedHere = false
        holdTask = Task {
            // 先过一小段宽限再开麦（见 graceDelay）；比宽限更短的触碰当作轻点处理
            try? await Task.sleep(for: Self.graceDelay)
            guard !Task.isCancelled else { return }
            startedHere = onHoldBegan()
            MicTiming.mark("holdBegan")
            if startedHere { Haptics.light() }
            try? await Task.sleep(for: Self.holdThreshold - Self.graceDelay)
            guard !Task.isCancelled else { return }
            holding = true
        }
    }

    /// 手势被打断：不算点按，只收尾（本次按下开始了聆听就结束它）。
    private func pressCancelled() {
        if pressing { Self.pressingCount -= 1 }
        pressing = false
        holdTask?.cancel()
        if startedHere { onHoldEnded() }
        startedHere = false
        holding = false
    }

    private func pressEnded() {
        if pressing { Self.pressingCount -= 1 }
        pressing = false
        holdTask?.cancel()
        defer { startedHere = false; holding = false }
        if startedHere {
            if holding { onHoldEnded() } else { onHoldPromotedToTap() }
        } else {
            Haptics.light()
            onTap()
        }
    }
}
