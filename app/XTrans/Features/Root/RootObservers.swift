import SwiftUI

/// 根视图的「观察会话 / 设置」的副作用：同步设置、翻译完成的触觉、空闲后归还音频会话、同声传译 / 大字展示时常亮、记住语言、退后台收尾。
/// 单独成一个看不见的小视图：这些 onChange 要读 `session.phase` / `session.currentTurn` / `settings.snapshot`，
/// 写在 RootView 里会让每一次识别中间结果、每一次设置改动都把整个根视图（含两个标签页）重新求值一遍。
struct RootObservers: View {
    let model: AppModel
    let bigDisplayActive: Bool
    /// 只有这个小视图观察设置（`@ObservedObject`）：设置变化时它自己重算，不牵连根视图
    @ObservedObject private var settings: AppSettings

    init(model: AppModel, bigDisplayActive: Bool) {
        self.model = model
        self.bigDisplayActive = bigDisplayActive
        _settings = ObservedObject(wrappedValue: model.settings)
    }
    @Environment(\.scenePhase) private var scenePhase
    /// 空闲一阵后把音频会话还给系统的计时（见 `AppAudioSession.releaseDelay`）
    @State private var releaseTask: Task<Void, Never>?

    private var session: ConversationSession { model.session }

    /// 重新安排「空闲后归还音频会话」：空闲才排，中途又开始聆听 / 朗读就取消
    private func armRelease() {
        releaseTask?.cancel()
        guard session.phase == .idle, !session.isEavesdropping, !session.isSpeakingStandalone else { return }
        releaseTask = Task {
            try? await Task.sleep(for: AppAudioSession.releaseDelay)
            guard !Task.isCancelled, session.phase == .idle, !session.isEavesdropping, !session.isSpeakingStandalone else { return }
            AppAudioSession.releaseToOthers()
        }
    }

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            // 把设置同步到对话和语音组件
            .onChange(of: settings.snapshot) { _, _ in model.applySettings() }
            // 触感：翻译完成 = 成功（载入历史 / 插入外来文字不算；同声传译时手机多半放在桌上，一句一震太吵）
            .onChange(of: session.translatedCount) { _, _ in
                if !session.isEavesdropping { Haptics.success() }
            }
            // 「没听清」的警告触觉：每次出现响一次
            .onChange(of: session.noSpeechCount) { _, _ in Haptics.warning() }
            // 退到后台：系统会收走麦克风，识别不会再有结果。主动收尾，回来时界面是干净的空闲态，
            // 而不是卡在"正在听"。（只看 .background：弹权限框、下拉控制中心只会变成 .inactive，不该打断。）
            .onChange(of: scenePhase) { _, phase in
                if phase == .background {
                    session.cancelAll()
                    // 退到后台就立刻还给系统：挂起的 App 里"空闲 20 秒后再还"的计时不会跑，会话会一直占着，别的 App 的音乐恢复不了
                    releaseTask?.cancel()
                    AppAudioSession.releaseToOthers()
                } else if phase == .active {
                    BlankTapKeyboardDismisser.shared.install()
                    // 回到前台：语言包可能刚在系统设置 / 翻译 App 里被下载或删除，重新读一遍（原来只在打开页面时读，切回来看到的是旧状态）
                    Task { await model.packs.refresh() }
                }
            }
            // 一轮结束回到空闲：把音频会话还给系统，正在放音乐 / 播客的其他 App 才会自动恢复
            // （同声传译期间会反复回到空闲又立刻重新聆听，不释放）
            // 不立刻还：连着说第二句时，重新激活音频会话（还要把输出从扬声器切回麦克风）要几百毫秒，
            // 按下麦克风会明显变慢。空闲满 AppAudioSession.releaseDelay 才还；中途又开始聆听就取消。
            .onChange(of: session.phase) { _, _ in armRelease() }
            // 设置里试听声音、大字展示朗读完：phase 一直是 idle，不会触发上面那条；结束同声传译时 phase 也可能没变
            .onChange(of: session.speechIdleTick) { _, _ in armRelease() }
            .onChange(of: session.isEavesdropping) { _, _ in armRelease() }
            // 同声传译 / 大字展示时手机往往放在桌上、很久不碰：别让自动锁屏把它掐掉（退到后台时同声传译已被结束）
            .onChange(of: session.isEavesdropping || bigDisplayActive, initial: true) { _, keepAwake in
                UIApplication.shared.isIdleTimerDisabled = keepAwake
            }
    }
}
