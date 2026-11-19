import CoreGraphics

/// 面对面首页的版面几何：纯计算，不依赖 SwiftUI，方便用测试证明"对称"。
///
/// 目标（用户的要求）：对方那半屏和我这半屏**完全对称**——两个麦克风离各自屏幕边缘的距离相同、
/// 两个半屏一样大、控制条正好在中心；直板 iPhone（竖 / 横）、Duo 外屏、Duo 内屏（竖 / 横、展开 / 半开）
/// 都用同一套规则。
struct FaceGeometry: Equatable {
    /// 两个半屏怎么排。
    enum Arrangement: Equatable {
        /// 上下分屏，控制条在正中间（平放、直板、外屏、内屏展开）。
        case stacked
        /// 上下分屏，但中间是折叠处（Duo 内屏竖放且铰链半开：折痕横着）：折叠处不放可点的东西，
        /// 控制条挪到我这半屏的顶部。
        case stackedFold
        /// 左右分屏（Duo 内屏横放且铰链半开：折痕竖着，或手动选了"左右分屏"）：
        /// 左半屏朝对方（倒置），右半屏朝自己，控制条在我这一侧的顶部。
        case sideBySide
    }

    /// 麦克风放在半屏的哪里：竖向半屏（高大于宽）放在下方，横向半屏（宽大于高）放在末端。
    enum MicPlacement: Equatable { case bottom, trailing }

    /// 折叠处（铰链）占的宽度，Apple 文档里折叠区域约 40pt。
    static let foldGap: CGFloat = 40
    /// 控制条占的高度：条本身 56 + 上下各 12 留白，条正好在这一格的中心。
    static let stripSlot: CGFloat = 80

    /// 横向打字时，语言条能不能放在整屏正中（压在两栏分界线上）而不盖住左半屏的麦克风。
    /// 麦克风在左半屏中心（离分界线 width/4）、半径 38pt（再留 4pt）；条的一半宽度要在这之内。放不下就留在右栏里。
    static func centersTypingStrip(width: CGFloat, stripWidth: CGFloat) -> Bool {
        stripWidth <= width / 2 - 84
    }

    /// 整个可用区域（已经扣掉安全区；上下取两者较大的值，保证上下对称）。
    var area: CGRect
    var arrangement: Arrangement
    /// 对方那半屏（在屏幕上的位置，内容要再旋转 180°）。
    var them: CGRect
    /// 我这半屏。
    var me: CGRect
    /// 控制条所在的格子（条在格子中心）。
    var strip: CGRect
    var micPlacement: MicPlacement

    /// - Parameters:
    ///   - size: 视图的完整尺寸（含安全区）。
    ///   - insets: 安全区（上、左、下、右）。
    ///   - crease: 真正的折痕在 `size` 坐标里的水平范围（Duo 内屏横放：窗口宽度的一半 ± 20）。左右分屏时左 / 右屏以它为界——
    ///     原来把「空隙」放在扣掉竖排栏之后的可用区域正中，和真正的折痕差了 ~42pt，右屏的文字和控制条压在折痕上。
    static func compute(size: CGSize, insets: (top: CGFloat, leading: CGFloat, bottom: CGFloat, trailing: CGFloat),
                        arrangement: Arrangement, crease: ClosedRange<CGFloat>? = nil) -> FaceGeometry {
        // 上下取较大值：灵动岛 / 状态栏那一侧和 Home 指示条那一侧不一样高，
        // 不统一的话两个麦克风离边缘的距离就不一样。左右用各自真实的安全区（Duo 外屏右侧是系统保留的摄像头区）。
        let vertical = max(insets.top, insets.bottom)
        let area = CGRect(x: insets.leading, y: vertical,
                          width: max(0, size.width - insets.leading - insets.trailing),
                          height: max(0, size.height - 2 * vertical))
        let gap = foldGap
        let slot = stripSlot
        let them: CGRect, me: CGRect, strip: CGRect

        switch arrangement {
        case .stacked:
            let half = max(0, (area.height - slot) / 2)
            them = CGRect(x: area.minX, y: area.minY, width: area.width, height: half)
            strip = CGRect(x: area.minX, y: area.minY + half, width: area.width, height: slot)
            me = CGRect(x: area.minX, y: strip.maxY, width: area.width, height: half)

        case .stackedFold:
            // 折叠处在正中间；条在折叠处下面（我这一侧）。对方那边在折叠处上面留出同样大的空白，
            // 这样两个半屏一样大、麦克风仍然点对称。
            let centerY = area.midY
            strip = CGRect(x: area.minX, y: centerY + gap / 2, width: area.width, height: slot)
            me = CGRect(x: area.minX, y: strip.maxY, width: area.width, height: max(0, area.maxY - strip.maxY))
            them = CGRect(x: area.minX, y: area.minY, width: area.width, height: me.height)

        case .sideBySide:
            let leftPane: CGRect, rightPane: CGRect
            if let crease {
                leftPane = CGRect(x: area.minX, y: area.minY, width: max(0, crease.lowerBound - area.minX), height: area.height)
                rightPane = CGRect(x: crease.upperBound, y: area.minY, width: max(0, area.maxX - crease.upperBound), height: area.height)
            } else {
                let paneWidth = max(0, (area.width - gap) / 2)
                leftPane = CGRect(x: area.minX, y: area.minY, width: paneWidth, height: area.height)
                rightPane = CGRect(x: area.maxX - paneWidth, y: area.minY, width: paneWidth, height: area.height)
            }
            strip = CGRect(x: rightPane.minX, y: rightPane.minY, width: rightPane.width, height: slot)
            me = CGRect(x: rightPane.minX, y: strip.maxY, width: rightPane.width, height: max(0, area.height - slot))
            // 对方那半屏是我这半屏绕屏幕中心转 180° 的样子：高度一样，空白在屏幕下方（转过来就是他的"上方"）。
            them = CGRect(x: leftPane.minX, y: area.minY, width: leftPane.width, height: me.height)
        }

        // 麦克风的位置跟着"屏幕朝向"走（不是跟着半屏的长宽比）：竖着拿时半屏虽然比较宽，麦克风仍在下方、
        // 离拇指最近；横着拿（上下分屏的半屏又宽又矮）才把麦克风放到末端，文字才有足够的高度。
        // 左右分屏时每个半屏都是竖条，麦克风在下方。
        let placement: MicPlacement = (arrangement != .sideBySide && size.width > size.height) ? .trailing : .bottom
        return FaceGeometry(area: area, arrangement: arrangement, them: them, me: me, strip: strip, micPlacement: placement)
    }

    /// 现在该用哪种排法。
    /// - 只有宽屏（Duo 内屏、iPad）才可能左右分屏 / 折叠分屏；窄屏（直板、Duo 外屏）永远是上下分屏。
    /// - 依据 Apple 文档：折痕（reservedRegions 的 division）**只在半开时起作用，完全展开时宽度为 0**。
    ///   系统报告了正在起作用的折叠区域（`fold`）就以它的方向为准：区域是竖条 → 折痕竖着 → 左右分屏；横条 → 折痕横着 → 折叠分屏。
    /// - 没有起作用的折叠区域（展平）：`.auto` / `.off` 都是上下分屏、控制条在整屏正中；`.on` 是用户手动选的左右分屏。
    /// - 区域信息没来（模拟器 / 旧系统）但铰链状态是半开：竖着拿折痕横着（像笔记本），横着拿折痕竖着（像书）。
    static func arrangement(size: CGSize, mode: TentMode, hinge: HingeMonitor.Status, fold: CGRect?) -> Arrangement {
        guard LayoutClass.forSize(size) == .wide else { return .stacked }
        if let fold { return fold.height > fold.width ? .sideBySide : .stackedFold }
        switch mode {
        case .off: return .stacked
        case .on: return .sideBySide
        case .auto:
            guard hinge == .partiallyOpen else { return .stacked }
            return size.width > size.height ? .sideBySide : .stackedFold
        }
    }

    /// 绕屏幕中心转 180° 的点对称：我这半屏的任何一点，对应对方那半屏里的哪一点。
    static func mirrored(_ rect: CGRect, in size: CGSize) -> CGRect {
        CGRect(x: size.width - rect.maxX, y: size.height - rect.maxY, width: rect.width, height: rect.height)
    }
}
