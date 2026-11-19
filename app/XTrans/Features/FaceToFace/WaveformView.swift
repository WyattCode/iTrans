import SwiftUI

/// 聆听时的声波条。高度来自真实音量采样。
struct WaveformView: View {
    let levels: [Float]
    let color: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
                Capsule()
                    .fill(color)
                    .frame(width: 3, height: 5 + CGFloat(level) * 24)
            }
        }
        .frame(height: 30, alignment: .center)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: levels)
        .accessibilityHidden(true)
    }
}

/// "还在生成"的三个跳动小点。
struct ThinkingDots: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 暂停跳动（正在淡出时）
    var paused = false
    /// 在不可见的标签页里（TabView 保留着没选中的页）不要继续每秒 20 帧地转
    @State private var visible = true

    var body: some View {
        if reduceMotion {
            Text("…").foregroundStyle(Theme.mut).accessibilityLabel("正在翻译")
        } else {
            // 三个小点不需要 60/120 帧：20 帧足够顺滑，且一屏可能有很多行同时在转
            TimelineView(.animation(minimumInterval: 1.0 / 20, paused: paused || !visible)) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                HStack(spacing: 4) {
                    ForEach(0..<3, id: \.self) { i in
                        Circle()
                            .fill(Theme.mut)
                            .frame(width: 6, height: 6)
                            .opacity(0.45 + 0.55 * max(0, sin(t * 5 - Double(i) * 0.7)))
                    }
                }
            }
            .accessibilityLabel("正在翻译")
            .onAppear { visible = true }
            .onDisappear { visible = false }
        }
    }
}

/// 实时声波：自己读 `session.levels`（每秒变约 47 次）。放在父视图里读，整段转写会跟着每秒重新求值 47 次。
struct LiveWaveform: View {
    let session: ConversationSession
    let color: Color
    var body: some View { WaveformView(levels: session.levels, color: color) }
}
