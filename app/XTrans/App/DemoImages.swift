import UIKit

/// 调试 / 截图用：程序画出来的一张日文菜单（不用带图片资源，也不碰相册）。
enum DemoImages {
    static var menu: UIImage {
        let size = CGSize(width: 900, height: 600)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            UIColor(red: 0.96, green: 0.92, blue: 0.84, alpha: 1).setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            let lines = ["ラーメン  ¥900", "餃子（6個）  ¥450", "生ビール  ¥600", "本日のおすすめ  ¥1,100"]
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 54, weight: .bold), .foregroundColor: UIColor.black,
            ]
            for (i, line) in lines.enumerated() {
                (line as NSString).draw(at: CGPoint(x: 60, y: 70 + CGFloat(i) * 120), withAttributes: attrs)
            }
        }
    }
}
