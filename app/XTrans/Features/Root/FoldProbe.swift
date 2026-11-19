import SwiftUI

/// 调试：把当前视图的尺寸、安全区、铰链 / 摄像头保留区域画在屏幕上（`-XTransFoldProbe`）。
/// 用来在 Duo 模拟器里看 `reservedRegions` 到底给了什么。
struct FoldProbe: View {
    let hinge: HingeMonitor

    var body: some View {
        GeometryReader { geo in
            let text = describe(geo)
            ZStack(alignment: .topLeading) {
                if #available(iOS 27.1, *) {
                    ForEach(geo.reservedRegions(kind: .division, options: .includeInactive)) { region in
                        Rectangle().fill(.red.opacity(region.isActive ? 0.35 : 0.1))
                            .overlay(Rectangle().stroke(.red, lineWidth: 1))
                            .frame(width: region.frame.width, height: region.frame.height)
                            .offset(x: region.frame.minX, y: region.frame.minY)
                    }
                    ForEach(geo.reservedRegions(kind: .occlusion, options: .includeInactive)) { region in
                        Rectangle().fill(.blue.opacity(region.isActive ? 0.35 : 0.1))
                            .overlay(Rectangle().stroke(.blue, lineWidth: 1))
                            .frame(width: region.frame.width, height: region.frame.height)
                            .offset(x: region.frame.minX, y: region.frame.minY)
                    }
                }
                Text(text)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white)
                    .padding(6)
                    .background(.black.opacity(0.7))
                    .padding(.top, 4)
                    .padding(.leading, 4)
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    private func describe(_ geo: GeometryProxy) -> String {
        // GeometryReader 加了 ignoresSafeArea 后读到的安全区是 0，所以直接问窗口
        let s = (UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.keyWindow?.safeAreaInsets) ?? .zero
        var lines = [
            "size \(Int(geo.size.width))×\(Int(geo.size.height))",
            "safe t\(Int(s.top)) b\(Int(s.bottom)) l\(Int(s.left)) r\(Int(s.right))",
            "hinge \(hinge.status) \(hinge.angle.map { String(Int($0 * 180 / .pi)) + "°" } ?? "-")",
        ]
        for r in hinge.regions {
            let f = r.frame
            lines.append("UIKit div \(r.isActive ? "ON" : "off") x\(Int(f.minX)) y\(Int(f.minY)) \(Int(f.width))×\(Int(f.height))")
        }
        if #available(iOS 27.1, *) {
            for kind in [("div", ReservedRegion.Kind.division), ("occ", ReservedRegion.Kind.occlusion)] {
                for r in geo.reservedRegions(kind: kind.1, options: .includeInactive) {
                    let f = r.frame, m = r.margins
                    lines.append("\(kind.0) \(r.isActive ? "ON" : "off") x\(Int(f.minX)) y\(Int(f.minY)) \(Int(f.width))×\(Int(f.height)) m\(Int(m.top))/\(Int(m.leading))/\(Int(m.bottom))/\(Int(m.trailing))")
                }
            }
        }
        return lines.joined(separator: "\n")
    }
}
