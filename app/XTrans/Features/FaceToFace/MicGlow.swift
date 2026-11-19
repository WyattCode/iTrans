import SwiftUI

/// 收音 / 说话时的泛光：以麦克风为光源，柔光"漫"开，把说话人的整个半屏染亮，渐隐到控制条。
/// 亮度随音量涨落（和 Jarvis 通话页的 CallGlowView 同一思路：径向光云，透明度随音量变）。
/// 我 = 粉色，对方 = 青色；对方那半屏随整体旋转 180°，所以天然镜像。
struct MicGlow: View {
    let color: Color
    /// 0...1，近几帧的音量
    let level: CGFloat
    /// 光源（麦克风中心）在这半屏里的位置，单位 = 点
    let source: CGPoint
    /// 这半屏的大小（决定光团半径）
    let size: CGSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        // 用一个自己带渐隐边缘的圆形光团（而不是填满半屏的矩形）：光可以越过半屏的边继续漫开，
        // 也不会在半屏边缘留下一道硬边。
        let radius = max(size.width, size.height) * 0.62
        // 静止（只在聆听）时约 0.22，说话时最高约 0.62；浅色背景上整体再淡一些
        let base: CGFloat = scheme == .dark ? 0.24 : 0.2
        let alpha = reduceMotion ? base + 0.1 : base + min(1, level) * (scheme == .dark ? 0.4 : 0.32)
        // 渐变本身固定，音量只改整体透明度：音量每帧在变，只改 opacity 由 GPU 合成，不必每帧重算渐变的颜色（省电）
        Circle()
            .fill(RadialGradient(
                colors: [color, color.opacity(0.4), color.opacity(0)],
                center: .center, startRadius: 0, endRadius: radius))
            .frame(width: radius * 2, height: radius * 2)
            .opacity(alpha)
            .position(source)
            .frame(width: size.width, height: size.height)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: alpha)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
