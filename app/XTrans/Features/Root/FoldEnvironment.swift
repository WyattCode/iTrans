import SwiftUI

private struct ActiveFoldKey: EnvironmentKey { static let defaultValue: CGRect? = nil }

extension EnvironmentValues {
    /// 正在起作用的折叠区域（窗口坐标）。**只有半开时才有值**（Apple 文档：division 保留区域完全展开时宽度为 0、不起作用）；展平 = nil。
    var activeFold: CGRect? {
        get { self[ActiveFoldKey.self] }
        set { self[ActiveFoldKey.self] = newValue }
    }
}

/// 整页内容避开折痕：展平不动；半开时把内容放进折痕一侧够大的那一段
/// （竖放折痕横着 → 折痕下面那一半；横放折痕竖着 → 折痕右边那一半），折痕带本身留空。
private struct AvoidFold: ViewModifier {
    @Environment(\.activeFold) private var fold

    func body(content: Content) -> some View {
        GeometryReader { geo in
            let frame = geo.frame(in: .global)
            let inset = Self.inset(fold: fold, in: frame)
            content
                .padding(.top, inset.top)
                .padding(.leading, inset.leading)
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
    }

    static func inset(fold: CGRect?, in frame: CGRect) -> (top: CGFloat, leading: CGFloat) {
        guard let fold else { return (0, 0) }
        if fold.height < fold.width {
            return fold.maxY > frame.minY && fold.minY < frame.maxY ? (max(0, fold.maxY - frame.minY), 0) : (0, 0)
        }
        return fold.maxX > frame.minX && fold.minX < frame.maxX ? (0, max(0, fold.maxX - frame.minX)) : (0, 0)
    }
}

extension View {
    func avoidingFold() -> some View { modifier(AvoidFold()) }
}
