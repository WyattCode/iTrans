import SwiftUI
import UIKit

/// 设计令牌（对应 design/ui-B-glass-dark.html 夜间稿 与 ui-B-glass-light.html 白天 v3）。
/// 全部走语义命名，组件里不写死颜色；随系统外观自动切换。
enum Theme {
    // MARK: 背景与文字
    static let bg = dynamic(light: 0xF6F7FF, dark: 0x0A0D1E)
    static let fg = dynamic(light: 0x0C1030, dark: 0xF5F7FF)
    static let sub = dynamic(light: 0x2F3563, dark: 0xBCC4E6)
    static let mut = dynamic(light: 0x454C78, dark: 0xA5AED4)
    static let line = dynamic(light: 0xD8DCF0, dark: 0x2B3366)
    static let stroke = dynamic(light: 0x6E76A6, dark: 0x7079B0)

    // MARK: 说话人（粉红 = 我，青色 = 对方）
    /// 文字 / 线条用色（对比度已按设计稿校验）
    static let meText = dynamic(light: 0xBD1F5B, dark: 0xFF8CB6)
    static let themText = dynamic(light: 0x0A6AA1, dark: 0x62DDFF)
    /// 填充 / 圆点 / 玻璃着色用色（不用于文字）
    static let meFill = dynamic(light: 0xFC4687, dark: 0xD6336C)
    static let themFill = dynamic(light: 0x1FB6FF, dark: 0x62DDFF)
    /// 圆点：夜间用更亮的文字色，白天用填充色
    static let meDot = dynamic(light: 0xFC4687, dark: 0xFF8CB6)
    static let themDot = dynamic(light: 0x1FB6FF, dark: 0x62DDFF)

    // MARK: 控件强调色（开关 / 滑块 / 选中行 / 主按钮玻璃）：原稿的粉红填充色 --accfill
    static let control = dynamic(light: 0xC2255F, dark: 0xD6336C)

    // MARK: 对话流气泡（白天 v3：扁平粉彩色块；夜间：同色半透明）
    static let bubbleMe = dynamic(light: 0xFFDCEA, dark: 0xFF8CB6, lightAlpha: 1, darkAlpha: 0.26)
    static let bubbleThem = dynamic(light: 0xD6EFFF, dark: 0x62DDFF, lightAlpha: 1, darkAlpha: 0.22)

    // MARK: 状态
    static let ok = dynamic(light: 0x0E6A4E, dark: 0x4CD39A)
    static let warn = dynamic(light: 0x8A5D00, dark: 0xFFC857)
    static let err = dynamic(light: 0xB3261E, dark: 0xFF8A80)

    // MARK: 玻璃
    static let glassBorder = dynamic(light: 0xFFFFFF, dark: 0xFFFFFF, lightAlpha: 0.96, darkAlpha: 0.20)
    static let glassFill = dynamic(light: 0xFFFFFF, dark: 0xFFFFFF, lightAlpha: 0.72, darkAlpha: 0.09)

    // MARK: 字号（对应 iOS 动态字体样式，全部随系统字号缩放）
    static let currentLine = Font.system(.title, design: .default).weight(.bold)   // Title 1 · 28
    static let currentLongLine = Font.system(.title2, design: .default).weight(.bold)   // 长句：Title 2 · 22
    static let oldLine = Font.system(.body, design: .default).weight(.medium)      // Body · 17
    static let caption = Font.system(.footnote, design: .default)                  // Footnote · 13
    static let label = Font.system(.caption, design: .default).weight(.semibold)   // Caption 1 · 12

    // MARK: 圆角
    static let radiusSheet: CGFloat = 32

    // MARK: 构造
    static func dynamic(light: UInt32, dark: UInt32, lightAlpha: Double = 1, darkAlpha: Double = 1) -> Color {
        Color(UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor(hex: dark, alpha: darkAlpha)
                : UIColor(hex: light, alpha: lightAlpha)
        })
    }
}

extension UIColor {
    convenience init(hex: UInt32, alpha: Double = 1) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(UIColor(hex: hex, alpha: alpha))
    }
}
