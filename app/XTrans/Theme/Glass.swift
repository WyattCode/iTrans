import SwiftUI

/// 玻璃材质。iOS 26+ 用系统 Liquid Glass，更早的系统退回 Material + 细描边。
/// 开启"降低透明度"时改为实色并去掉模糊（设计稿第 8 节）。
struct GlassBackground<S: InsettableShape>: ViewModifier {
    let shape: S
    var tint: Color?
    var interactive = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        if reduceTransparency || BodyCount.noGlass {
            solid(content)
        } else {
            translucent(content)
        }
    }

    private func solid(_ content: Content) -> some View {
        // 降低透明度：主按钮（有着色）仍然是粉红实色，不能退化成和普通按钮一样的底色
        // 先铺底色，再叠 40% 的着色：整块铺满着色色时，近白的图标 / 文字压在青色（62DDFF）上只有 1.6:1，浅色主按钮 3.3:1，几乎看不见
        content
            .background { shape.fill(Theme.bg) }
            .background { if let tint { shape.fill(tint.opacity(0.4)) } }
            .overlay(shape.strokeBorder(tint == nil ? Theme.stroke : tint!.opacity(0.7), lineWidth: 1))
    }

    @ViewBuilder
    private func translucent(_ content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(liquidGlass, in: shape)
        } else {
            legacy(content)
        }
    }

    private func legacy(_ content: Content) -> some View {
        let wash: Color = tint?.opacity(0.18) ?? Color.clear
        return content
            .background { shape.fill(.ultraThinMaterial) }
            .background { shape.fill(wash) }
            .overlay(shape.strokeBorder(Theme.glassBorder, lineWidth: 1))
    }

    @available(iOS 26.0, *)
    private var liquidGlass: Glass {
        var g = Glass.regular
        if let tint { g = g.tint(tint.opacity(0.35)) }
        return interactive ? g.interactive() : g
    }
}

extension View {
    /// 主操作的玻璃（发送、接着聊、麦克风按钮）：粉红着色玻璃（原稿主按钮）。
    func primaryGlass<S: InsettableShape>(in shape: S) -> some View {
        glass(in: shape, tint: Theme.control, interactive: true)
    }

    func glass<S: InsettableShape>(in shape: S, tint: Color? = nil, interactive: Bool = false) -> some View {
        modifier(GlassBackground(shape: shape, tint: tint, interactive: interactive))
    }
}
