import SwiftUI

/// 极光背景：三团柔和的彩色光斑叠在底色上（设计稿 --bgfx）。
/// 夜间光斑更浓，白天只有 28% 强度，保证直接落在上面的文字对比度 ≥ 7:1。
struct AuroraBackground: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        if BodyCount.noAurora {
            Theme.bg.ignoresSafeArea()
        } else if DuoLayout.isDuoInner(DuoLayout.currentWindowSize) {
            // 所有屏内页面都取同一个窗口坐标的底图。不能按每张卡片 / 安全区重新计算光斑。
            GeometryReader { geo in
                let window = DuoLayout.currentWindowSize
                let frame = geo.frame(in: .global)
                aurora
                    .frame(width: window.width, height: window.height)
                    .offset(x: -frame.minX, y: -frame.minY)
                    .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                    .clipped()
            }
            .ignoresSafeArea()
            .dismissKeyboardOnTap()
        } else {
            aurora.ignoresSafeArea().dismissKeyboardOnTap()
        }
    }

    private var aurora: some View {
        ZStack {
            Theme.bg
            if !reduceTransparency {
                spot(scheme == .dark ? Color(hex: 0x7C5CFF, alpha: 0.42) : Color(hex: 0xBEAAFF, alpha: 0.28),
                     center: UnitPoint(x: 0.10, y: 0.04), radius: 0.62)
                spot(scheme == .dark ? Color(hex: 0x22D3EE, alpha: 0.28) : Color(hex: 0x78D7FF, alpha: 0.28),
                     center: UnitPoint(x: 0.94, y: 0.26), radius: 0.56)
                spot(scheme == .dark ? Color(hex: 0xFF5FA2, alpha: 0.34) : Color(hex: 0xFFAACD, alpha: 0.28),
                     center: UnitPoint(x: 0.26, y: 0.98), radius: 0.70)
            }
        }
        // 三个椭圆渐变整体渲染成一张位图再合成：页面切换 / 推入时底下叠着好几层极光，每层都是三次渐变绘制，改成一张贴图后开销小得多
        .drawingGroup()
    }

    private func spot(_ color: Color, center: UnitPoint, radius: CGFloat) -> some View {
        EllipticalGradient(
            colors: [color, color.opacity(0)],
            center: center,
            startRadiusFraction: 0,
            endRadiusFraction: radius
        )
    }
}
