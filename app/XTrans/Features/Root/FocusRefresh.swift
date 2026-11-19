import SwiftUI
import UIKit
import GameController

/// 系统软键盘当前是不是显示着（全 App 只需要这一个布尔值）。App 启动时调用 `start()`，之后一直监听。
@MainActor
final class KeyboardVisibility {
    static let shared = KeyboardVisibility()
    private(set) var isVisible = false
    /// 系统键盘已经加载过（这次启动里升起过，或预热过）：再要键盘时只要几十毫秒，输入条可以立刻和键盘一起升起；
    /// 还没加载过时第一次要几百毫秒（主线程被占住），输入条得先淡入站稳再要键盘
    fileprivate(set) var isWarm = false
    /// 最近一次「用户/页面主动收起键盘」的时刻（`dismissKeyboard()` 记的）：输入条据此知道这次收键盘是不是我们自己要的，
    /// 是的话马上跟着收，不用再等一会儿看焦点状态
    private(set) var lastDismiss = Date.distantPast
    func noteDismiss() { lastDismiss = Date() }
    var dismissedJustNow: Bool { Date().timeIntervalSince(lastDismiss) < 0.25 }
    /// 最近一次软键盘的高度（弹层按它算可用高度；还没出现过时为 0）。横放 / 竖放的键盘不一样高，分开记，
    /// 并存进 UserDefaults：下次启动第一次打开弹层就用得上（否则只能按窗口高估）。
    var lastHeight: CGFloat { height(portrait: Self.isPortrait) }
    private var heights: [Bool: CGFloat] = [:]
    private static var isPortrait: Bool { let w = DuoLayout.currentWindowSize; return w.height > w.width }
    /// v2：上一版会把半开时的键盘高度（键盘占满下半屏，比展平时高 ~90pt）记成竖屏的高度，换键名把旧值作废
    private static func key(_ portrait: Bool) -> String { portrait ? "keyboardHeight.v2.portrait" : "keyboardHeight.v2.landscape" }
    /// Duo 半开：键盘铺在折痕下面那半屏，高度和展平时不一样——这时不记（由 RootView 跟着铰链状态设）
    var isFolded = false
    func height(portrait: Bool) -> CGFloat {
        if let known = heights[portrait] { return known }
        let stored = CGFloat(UserDefaults.standard.double(forKey: Self.key(portrait)))
        heights[portrait] = stored
        return stored
    }
    private func remember(_ height: CGFloat) {
        guard !isFolded else { return }
        let portrait = Self.isPortrait
        guard abs(self.height(portrait: portrait) - height) > 0.5 else { return }
        heights[portrait] = height
        UserDefaults.standard.set(Double(height), forKey: Self.key(portrait))
    }
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        let center = NotificationCenter.default
        center.addObserver(forName: UIResponder.keyboardWillShowNotification, object: nil, queue: .main) { note in
            let height = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect)?.height ?? 0
            MainActor.assumeIsolated {
                DockTrace.log("kb.willShow(global) h=\(height)")
                KeyboardVisibility.shared.isVisible = true
                KeyboardVisibility.shared.isWarm = true
                if height > 100 { KeyboardVisibility.shared.remember(height) }
            }
        }
        center.addObserver(forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { KeyboardVisibility.shared.isVisible = false }
        }
    }
}

/// 收起键盘（把焦点从当前输入框上拿走）。没有键盘时什么都不会发生。
@MainActor
func dismissKeyboard() {
    KeyboardVisibility.shared.noteDismiss()
    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
}

extension View {
    /// 列表 / 滚动区：滚动时收键盘。点在空白处收键盘由 `BlankTapKeyboardDismisser`（窗口级、不取消触摸）负责——
    /// 不能在 List / ScrollView 上挂 SwiftUI 的点击手势：它会取消 UIKit 的触摸，行里的按钮和 NavigationLink 就点不动了。
    func dismissKeyboardInScrollArea() -> some View {
        scrollDismissesKeyboard(.interactively)
    }

    /// 点在这块视图的空白处（按钮、输入框、可点的行仍然先响应）就收起键盘。
    func dismissKeyboardOnTap() -> some View {
        contentShape(Rectangle()).onTapGesture { dismissKeyboard() }
    }

    /// 点一下输入框一定能把键盘拉起来。
    /// 焦点状态是 true、但系统键盘已经被收起（下拉收起、切后台再回来、折叠 / 展开 Duo）时，再把 `focused` 设成 true
    /// 什么都不会发生——先放掉焦点、等一拍再要回来，键盘才会重新出现。
    /// 键盘正显示着（用户只是想移动光标、选字）时什么都不做：放掉焦点会让拼音输入的半截字被提交，光标位置也丢了。
    func refocusOnTap(_ focus: FocusState<Bool>.Binding) -> some View {
        onTapGesture {
            if focus.wrappedValue {
                // 外接键盘：不会出现软键盘，`isVisible` 一直是 false——不能每点一下就放焦点再要回来（会丢光标、把拼音半截字提交掉）
                guard !KeyboardVisibility.shared.isVisible, GCKeyboard.coalesced == nil else { return }
                focus.wrappedValue = false
                Task { @MainActor in
                    await Task.yield()
                    focus.wrappedValue = true
                }
            } else {
                focus.wrappedValue = true
            }
        }
    }

    /// 回到前台时，如果这个输入框本来就该有焦点、但键盘不在了，重新要一次键盘。
    func refocusOnActive(_ focus: FocusState<Bool>.Binding) -> some View {
        modifier(RefocusOnActive(focus: focus))
    }
}

private struct RefocusOnActive: ViewModifier {
    var focus: FocusState<Bool>.Binding
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content.onChange(of: scenePhase) { _, phase in
            guard phase == .active, focus.wrappedValue, !KeyboardVisibility.shared.isVisible else { return }
            focus.wrappedValue = false
            Task { @MainActor in
                await Task.yield()
                focus.wrappedValue = true
            }
        }
    }
}


/// 点在列表 / 滚动区的空白处（触摸直接落在 UIScrollView 自己身上，不是某一行、某个按钮）就收起键盘。
/// 窗口级的点击识别：`cancelsTouchesInView = false`，不影响任何行 / 按钮 / 输入框的点按。
@MainActor
final class BlankTapKeyboardDismisser: NSObject, UIGestureRecognizerDelegate {
    static let shared = BlankTapKeyboardDismisser()
    private var installed = false

    private var attempts = 0

    func install() {
        guard !installed else { return }
        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first else {
            // 这一刻还没有 keyWindow（刚启动）：过一会儿再试，最多几次；回到前台时 RootObservers 也会再调一次
            attempts += 1
            if attempts < 8 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.install() }
            }
            return
        }
        installed = true
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
        tap.cancelsTouchesInView = false
        tap.delaysTouchesBegan = false
        tap.delaysTouchesEnded = false
        tap.delegate = self
        window.addGestureRecognizer(tap)
    }

    @objc private func tapped() { dismissKeyboard() }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard let view = touch.view else { return false }
        return view is UIScrollView && !(view is UITextView)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
}

/// TabView 在切页时会短暂报告 SwiftUI onDisappear，取消 .task，但原生输入视图仍留在窗口。
/// 用实际的窗口挂载来安排首次焦点；真正离开窗口会取消请求，用户手动收起后不会反复抢回焦点。
struct WindowAutofocus: UIViewRepresentable {
    /// 进窗口后等多久再聚焦：弹层里要 0（和弹层的上升动画同时起键盘），普通页面留一点余量
    var delay: TimeInterval = 0.35
    let onArrival: () -> Void
    func makeUIView(context: Context) -> Probe {
        let view = Probe()
        view.isUserInteractionEnabled = false
        view.onArrival = onArrival
        view.delay = delay
        return view
    }
    func updateUIView(_ view: Probe, context: Context) { view.onArrival = onArrival }
    static func dismantleUIView(_ view: Probe, coordinator: ()) { view.invalidate(); view.onArrival = nil }

    final class Probe: UIView {
        var onArrival: (() -> Void)?
        var delay: TimeInterval = 0.35
        private var generation = 0
        func invalidate() { generation += 1 }
        override func didMoveToWindow() {
            super.didMoveToWindow()
            invalidate()
            guard window != nil else { return }
            let request = generation
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, generation == request, window != nil else { return }
                onArrival?()
            }
        }
    }
}

// MARK: - 键盘发送键：空输入时置灰

/// SwiftUI 的 TextField 没有 `enablesReturnKeyAutomatically`（UIKit 才有）。字段获得焦点时，给当前第一响应者打开它：
/// 输入框为空时键盘右下角的发送键自动置灰，有字才可按——和屏幕上发送钮的状态一致（原来空输入也是亮蓝可按）。
private enum FirstResponderProbe {
    static weak var current: UIResponder?

    @MainActor
    static func enableReturnKeyAutomatically() {
        current = nil
        UIApplication.shared.sendAction(#selector(UIResponder.xtCaptureFirstResponder), to: nil, from: nil, for: nil)
        if let view = current as? UITextView {
            view.enablesReturnKeyAutomatically = true
            view.reloadInputViews()
        } else if let field = current as? UITextField {
            field.enablesReturnKeyAutomatically = true
            field.reloadInputViews()
        }
    }
}

extension UIResponder {
    @objc fileprivate func xtCaptureFirstResponder() { FirstResponderProbe.current = self }
}

extension View {
    /// 输入框聚焦后让键盘的发送键在空输入时置灰。`isFocused` 传这个输入框的 `@FocusState`。
    func disablesReturnKeyWhenEmpty(isFocused: Bool) -> some View {
        onChange(of: isFocused, initial: true) { _, focused in
            guard focused else { return }
            DispatchQueue.main.async { FirstResponderProbe.enableReturnKeyAutomatically() }
        }
    }
}

// MARK: - 键盘预热

/// 系统键盘第一次出现时，UIKit 要建键盘场景、输入窗口、查一大堆 Swift 协议一致性：模拟器 Release 抽样首次约 300–700ms 主线程，
/// 之后的弹出只要几十毫秒。空闲时让一个看不见的输入框（自定义空输入视图 = 不会真的升起键盘）短暂聚焦再放开，把这部分提前做掉。
@MainActor
enum KeyboardPrewarm {
    private static var done = false

    static func run() async {
        guard !done else { return }
        // 用户已经在打字（或别处已有第一响应者）就不要碰
        guard !KeyboardVisibility.shared.isVisible,
              let window = UIApplication.shared.connectedScenes.compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first else { return }
        done = true
        let field = UITextField(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        field.alpha = 0.01
        field.isUserInteractionEnabled = false
        field.inputView = UIView(frame: .zero)
        field.autocorrectionType = .no
        window.addSubview(field)
        if field.becomeFirstResponder() {
            try? await Task.sleep(for: .milliseconds(250))
            field.resignFirstResponder()
        }
        field.removeFromSuperview()

        // 第二步：真的把系统键盘加载起来（上面那个用的是空输入视图，并不会加载键盘）。同一个 runloop 里聚焦再放开：
        // 键盘还来不及显示，UIKit 已经把键盘场景、输入窗口、输入法建好；之后第一次真正打开键盘输入就不再卡在加载上。
        // 接了实体键盘时没有软键盘，不用做。
        if GCKeyboard.coalesced == nil, !KeyboardVisibility.shared.isVisible {
            let real = UITextField(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
            real.alpha = 0.01
            real.isUserInteractionEnabled = false
            window.addSubview(real)
            DockTrace.log("prewarm.real begin")
            real.becomeFirstResponder()
            real.resignFirstResponder()
            real.removeFromSuperview()
            KeyboardVisibility.shared.isWarm = true
            DockTrace.log("prewarm.real end")
        }
    }
}


/// 输入法的组合状态（拼音 / 假名还没选字上屏的那一段 marked text）。
/// 组合中的字母会原样进到 `TextField` 的绑定里（"ni hao"），不能拿去翻译预览，也不能直接发送。
@MainActor
enum TextComposition {
    private static var firstResponder: UIResponder? {
        FirstResponderProbe.current = nil
        UIApplication.shared.sendAction(#selector(UIResponder.xtCaptureFirstResponder), to: nil, from: nil, for: nil)
        return FirstResponderProbe.current
    }
    /// 当前输入框里有没有还没上屏的组合文字
    static var isComposing: Bool {
        guard let input = firstResponder as? UITextInput, let range = input.markedTextRange else { return false }
        return !range.isEmpty
    }
}
