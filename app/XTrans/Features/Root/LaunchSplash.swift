import SwiftUI
import UIKit

/// 开屏动画「一问一答」：粉色气泡从自己的尾巴尖弹出来，青色气泡紧跟着弹出来回应，两个叠在一起的地方亮起白色。
/// 图标在屏幕正中原地出现，不移动。
///
/// - 盖在主界面上面播，主界面在下面照常加载，不拖慢启动。
/// - 还盖着的时候挡住触摸（下面的界面看不见，不能让人误点到麦克风）；点一下屏幕就立刻收起，不用等它播完。
/// - **整段动画用 Core Animation 做，不用 SwiftUI 动画**：SwiftUI 的动画每一帧都在主线程上算，
///   而启动这一秒主线程正忙着搭主界面，动画会一卡一卡的。Core Animation 交给系统的渲染进程去播，主线程再忙也不掉帧。
/// - 系统画的第一帧只有底色：极光底从这个底色里淡入，不会突然换一张底。
/// - 开了「减弱动态效果」：不弹，整个图标原地淡入。
struct LaunchSplash: View {
    /// 正常启动才播。带调试参数（截图 / 性能脚本）或跑单元测试时不播；`-XTransSplash` 强制播。
    static let shouldPlay: Bool = {
        let info = ProcessInfo.processInfo
        if info.arguments.contains("-XTransSplash") || info.arguments.contains("-XTransSplashHold") { return true }
        if info.environment["XCTestConfigurationFilePath"] != nil { return false }
        return !info.arguments.contains { $0.hasPrefix("-XTrans") }
    }()
    /// 调试：停在最后一帧不消失（截图用）
    fileprivate static let holds = ProcessInfo.processInfo.arguments.contains("-XTransSplashHold")

    var onFinish: () -> Void

    var body: some View {
        SplashHost(onFinish: onFinish)
            .ignoresSafeArea()
            .accessibilityHidden(true)
    }
}

private struct SplashHost: UIViewRepresentable {
    var onFinish: () -> Void

    func makeUIView(context: Context) -> SplashView {
        let view = SplashView()
        view.onFinish = onFinish
        return view
    }

    func updateUIView(_ view: SplashView, context: Context) {}
}

private final class SplashView: UIView, CAAnimationDelegate {
    var onFinish: (() -> Void)?

    // 图标原稿（1024）里的坐标
    private static let design = CGRect(x: 152, y: 232, width: 720, height: 560)
    private static let pinkRect = CGRect(x: 163, y: 242, width: 492, height: 358)
    private static let cyanRect = CGRect(x: 370, y: 425, width: 490, height: 357)
    private static let pinkTail = [CGPoint(x: 230, y: 570), CGPoint(x: 203, y: 713), CGPoint(x: 388, y: 592)]
    private static let cyanTail = [CGPoint(x: 640, y: 428), CGPoint(x: 820, y: 310), CGPoint(x: 794, y: 446)]
    private static let corner: CGFloat = 120

    private let aurora = CALayer()
    private let spots = [CAGradientLayer(), CAGradientLayer(), CAGradientLayer()]
    private let mark = UIView()
    private let pink = CAGradientLayer()
    private let cyan = CAGradientLayer()
    private let pinkMask = CAShapeLayer()
    private let cyanMask = CAShapeLayer()
    private let overlap = CAShapeLayer()        // 两个气泡交叠处的白色
    private let word = CATextLayer()
    private var started = false
    private var leaving = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(named: "LaunchBackground")
        layer.addSublayer(aurora)
        for spot in spots {
            spot.type = .radial
            aurora.addSublayer(spot)
        }
        addSubview(mark)
        pink.colors = [UIColor(hex: 0xFF8CB6).cgColor, UIColor(hex: 0xFC5C97).cgColor]
        cyan.colors = [UIColor(hex: 0x3FCBF0).cgColor, UIColor(hex: 0x74E6FF).cgColor]
        for (bubble, mask) in [(pink, pinkMask), (cyan, cyanMask)] {
            bubble.startPoint = .zero
            bubble.endPoint = CGPoint(x: 1, y: 1)
            bubble.mask = mask
            mark.layer.addSublayer(bubble)
        }
        overlap.fillColor = UIColor.white.cgColor
        mark.layer.addSublayer(overlap)

        word.string = "iTrans"
        word.font = UIFont.systemFont(ofSize: 13, weight: .semibold)
        word.fontSize = 13
        word.alignmentMode = .center
        layer.addSublayer(word)
        // 播的过程中切了深浅色：颜色是排版时按当前外观算的，重排一次
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: SplashView, _: UITraitCollection) in
            view.setNeedsLayout()
        }
    }

    /// 点一下就跳过
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        leave(after: 0)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.height > 0 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layoutAurora()
        layoutMark()
        word.contentsScale = traitCollection.displayScale
        word.foregroundColor = UIColor(Theme.mut).resolvedColor(with: traitCollection).cgColor
        word.frame = CGRect(x: 0, y: bounds.height - 54, width: bounds.width, height: 18)
        CATransaction.commit()
        // 等铺满整个窗口再开始：SwiftUI 头一两次排版给的尺寸可能还很小，那时算出来的滑动距离几乎是 0
        if !started, let window, bounds.width >= window.bounds.width - 1, bounds.height >= window.bounds.height - 1 {
            started = true
            play()
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else { return }
        // 保底：万一一直没铺满（不该发生），也别卡着不走
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, !self.started, self.window != nil, self.bounds.width > 0 else { return }
            self.started = true
            self.play()
        }
    }

    /// 和 `AuroraBackground` 同样的三团光斑（位置、半径、颜色都照抄），这样淡出到主界面时底不会变。
    private func layoutAurora() {
        aurora.frame = bounds
        let dark = traitCollection.userInterfaceStyle == .dark
        let specs: [(UInt32, CGFloat, CGPoint, CGFloat)] = dark
            ? [(0x7C5CFF, 0.42, CGPoint(x: 0.10, y: 0.04), 0.62), (0x22D3EE, 0.28, CGPoint(x: 0.94, y: 0.26), 0.56), (0xFF5FA2, 0.34, CGPoint(x: 0.26, y: 0.98), 0.70)]
            : [(0xBEAAFF, 0.28, CGPoint(x: 0.10, y: 0.04), 0.62), (0x78D7FF, 0.28, CGPoint(x: 0.94, y: 0.26), 0.56), (0xFFAACD, 0.28, CGPoint(x: 0.26, y: 0.98), 0.70)]
        aurora.isHidden = UIAccessibility.isReduceTransparencyEnabled
        for (spot, spec) in zip(spots, specs) {
            spot.frame = bounds
            spot.colors = [UIColor(hex: spec.0, alpha: spec.1).cgColor, UIColor(hex: spec.0, alpha: 0).cgColor]
            spot.startPoint = spec.2
            spot.endPoint = CGPoint(x: spec.2.x + spec.3, y: spec.2.y + spec.3)
        }
    }

    private func layoutMark() {
        let width = min(190, max(150, min(bounds.width, bounds.height) * 0.4))
        let scale = width / Self.design.width
        mark.bounds = CGRect(x: 0, y: 0, width: width, height: Self.design.height * scale)
        mark.center = CGPoint(x: bounds.midX, y: bounds.midY)

        // 原稿坐标 → 图标视图里的坐标
        var fit = CGAffineTransform(scaleX: scale, y: scale).translatedBy(x: -Self.design.minX, y: -Self.design.minY)
        func rounded(_ rect: CGRect) -> CGPath {
            CGPath(roundedRect: rect, cornerWidth: Self.corner, cornerHeight: Self.corner, transform: &fit)
        }
        func bubble(_ rect: CGRect, tail: [CGPoint]) -> CGPath {
            let tailPath = CGMutablePath()
            tailPath.addLines(between: tail, transform: fit)
            tailPath.closeSubpath()
            return rounded(rect).union(tailPath)
        }
        // 锚点放在各自的尾巴尖上：气泡是从尾巴尖「长」出来的
        let parts: [(CAGradientLayer, CAShapeLayer, CGPath, CGPoint)] = [
            (pink, pinkMask, bubble(Self.pinkRect, tail: Self.pinkTail), CGPoint(x: 0.08, y: 1)),
            (cyan, cyanMask, bubble(Self.cyanRect, tail: Self.cyanTail), CGPoint(x: 0.92, y: 0)),
        ]
        for (layer, mask, path, anchor) in parts {
            // 渐变只铺在气泡自己的范围里（和图标一致），形状用遮罩裁出来
            let box = path.boundingBoxOfPath
            layer.anchorPoint = anchor
            layer.bounds = CGRect(origin: .zero, size: box.size)
            layer.position = CGPoint(x: box.minX + box.width * anchor.x, y: box.minY + box.height * anchor.y)
            var shift = CGAffineTransform(translationX: -box.minX, y: -box.minY)
            mask.frame = layer.bounds
            mask.path = path.copy(using: &shift)
        }
        overlap.frame = mark.bounds
        overlap.path = rounded(Self.cyanRect).intersection(rounded(Self.pinkRect))
    }

    private func play() {
        let reduceMotion = UIAccessibility.isReduceMotionEnabled

        func fadeIn(_ duration: CFTimeInterval) -> CAAnimation {
            let animation = CABasicAnimation(keyPath: "opacity")
            animation.fromValue = 0
            animation.toValue = 1
            animation.duration = duration
            animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
            return animation
        }
        func pop() -> CAAnimation {
            let spring = CASpringAnimation(perceptualDuration: 0.42, bounce: 0.28)
            spring.keyPath = "transform.scale"
            spring.fromValue = 0.01
            spring.toValue = 1
            spring.duration = spring.settlingDuration
            return spring
        }
        // 动画都包在一个组里再加到图层上，组本身不写开始时间：不写的话，系统在把它交给渲染进程的那一刻才开始计时。
        // 写成「现在 + x 秒」的话，主线程这一轮要是忙了 0.3 秒才提交，动画的前 0.3 秒就直接没了。
        // 先后顺序靠组里每个动画相对组的延迟来排。
        func run(_ target: CALayer, _ animations: [CAAnimation], delay: CFTimeInterval = 0, notify: Bool = false) {
            for animation in animations {
                animation.beginTime = delay
                animation.fillMode = .backwards
            }
            let group = CAAnimationGroup()
            group.animations = animations
            group.duration = delay + (animations.map(\.duration).max() ?? 0)
            if notify { group.delegate = self }
            target.add(group, forKey: "splash")
        }

        run(aurora, [fadeIn(0.4)])
        if reduceMotion {
            run(mark.layer, [fadeIn(0.3)])
            run(word, [fadeIn(0.3)], notify: true)
        } else {
            run(pink, [pop(), fadeIn(0.12)])
            run(cyan, [pop(), fadeIn(0.12)], delay: 0.18)
            // 白色等青色气泡的回弹基本收住再亮：它不跟着气泡缩放，亮早了边缘会和还在动的气泡对不齐
            run(overlap, [fadeIn(0.2)], delay: 0.48)
            run(word, [fadeIn(0.25)], delay: 0.5, notify: true)
        }
        // 保底：正常是下面的 `animationDidStop` 来收尾。万一它没被调用（比如动画还没播 App 就被切到后台、图层被系统清掉），
        // 这一层会一直盖在主界面上，App 看起来就像卡死在开屏。所以到点一定收。
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in self?.leave(after: 0) }
    }

    /// 名字淡入播完（渲染进程里真的播到这儿了）再停一下收尾。不按「开始后过了多少秒」算：
    /// 主线程忙的时候动画实际开始得晚，按秒算会出现气泡刚合上就被收走。
    func animationDidStop(_ anim: CAAnimation, finished flag: Bool) {
        leave(after: UIAccessibility.isReduceMotionEnabled ? 0.4 : 0.22)
    }

    /// 图标略微放大着淡出，露出下面的主界面。只会执行一次。
    private func leave(after delay: TimeInterval) {
        guard !LaunchSplash.holds, !leaving else { return }
        leaving = true
        let reduceMotion = UIAccessibility.isReduceMotionEnabled
        UIView.animate(withDuration: 0.38, delay: delay, options: [.curveEaseInOut]) {
            self.alpha = 0
            if !reduceMotion { self.mark.transform = CGAffineTransform(scaleX: 1.14, y: 1.14) }
        } completion: { _ in
            self.onFinish?()
        }
        // 一开始淡出就不再挡触摸
        if delay == 0 { isUserInteractionEnabled = false }
        else { DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.isUserInteractionEnabled = false } }
    }
}
