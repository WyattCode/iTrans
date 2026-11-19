import Foundation
import Observation
import UIKit

enum Speaker: Equatable, Sendable {
    case me, them
    var other: Speaker { self == .me ? .them : .me }
}

enum TurnState: Equatable {
    case listening
    case translating
    case speaking
    case done
    case failed(String)
}

/// 这一轮是怎么来的（决定对话流里的小标签）。
enum TurnKind: String, Equatable {
    case voice, text, photo, paste, eavesdrop

    var label: String? {
        switch self {
        case .voice, .text: return nil
        case .photo: return String(localized: "图片文字")
        case .paste: return String(localized: "粘贴")
        case .eavesdrop: return String(localized: "只听不说")
        }
    }
}

struct Turn: Identifiable, Equatable {
    let id: UUID
    var speaker: Speaker
    var sourceText: String
    var translatedText: String?
    var state: TurnState
    var engineName: String?
    var latency: TimeInterval?
    var createdAt: Date
    var kind: TurnKind
    /// 这一轮说话时的"原文语言 / 译文语言"。对话中途换了语言，早先的轮次仍按当时的语言重新翻译、朗读、导出。
    /// 旧数据 / 演示数据没有记录（nil），退回用当前的语言。
    var fromID: String?
    var toID: String?

    init(id: UUID = UUID(), speaker: Speaker, sourceText: String = "", translatedText: String? = nil,
         state: TurnState = .listening, engineName: String? = nil, latency: TimeInterval? = nil,
         createdAt: Date = Date(), kind: TurnKind = .voice, fromID: String? = nil, toID: String? = nil) {
        self.fromID = fromID
        self.toID = toID
        self.id = id
        self.speaker = speaker
        self.sourceText = sourceText
        self.translatedText = translatedText
        self.state = state
        self.engineName = engineName
        self.latency = latency
        self.createdAt = createdAt
        self.kind = kind
    }
}

enum Phase: Equatable {
    case idle
    case listening(Speaker)
    case busy          // 翻译 / 朗读中
}

enum Notice: Equatable {
    case noSpeech(Speaker)
    case microphoneDenied
    case speechDenied
    case recognizerUnavailable(String)
}

/// 键盘输入时，给对方看的译文预览。
enum Preview: Equatable {
    case idle
    case loading
    case ready(String)
    case failed
}

/// 一场对话：两种语言、一串"轮次"，以及 聆听 → 翻译 → 朗读 的状态机。
/// 只依赖识别 / 翻译 / 朗读 / 存储四个协议，所以可以用假实现做单元测试。
@MainActor
@Observable
final class ConversationSession {
    var me: LanguageOption
    var them: LanguageOption
    private(set) var turns: [Turn] = []
    private(set) var phase: Phase = .idle
    var notice: Notice? {
        didSet { if case .noSpeech = notice { noSpeechCount += 1 } }
    }
    /// 「没听清」累计出现的次数：根上据此响一次警告触觉（哪里的麦克风都一样，不会因为同时有几个麦克风视图就响几次）
    private(set) var noSpeechCount = 0
    /// 最近的音量采样，驱动波形
    private(set) var levels: [Float] = Array(repeating: 0, count: 14)
    /// 正在朗读哪一轮的译文，以及读到了哪（译文里的 UTF-16 偏移）。界面据此高亮已读的词、让窗口跟着滚。
    /// 朗读器不报告进度时 `spokenOffset` 一直是 0。
    private(set) var speakingTurnID: Turn.ID?
    private(set) var spokenOffset = 0
    @ObservationIgnored private var speakToken = 0
    /// 这次朗读有没有收到过真实的进度回调（有些声音不报进度）
    @ObservationIgnored private var progressSeen = false
    /// 朗读开始后多久还没有进度回调，就改按语速估算（跟读窗口不能一直停在第 1 句）
    @ObservationIgnored var progressEstimateDelay: Duration = .seconds(1)
    /// 收到过真实进度之后，隔多久没有新回调就又改按估算往前推（有的声音只报一两次）
    @ObservationIgnored var progressStallTimeout: Duration = .milliseconds(1200)
    /// 朗读语速（AVSpeechUtterance 的 rate，默认 0.5）：估算要按它缩放，慢速时估算才不会跑到真实朗读前面
    @ObservationIgnored var speechRate: Float = 0.5
    @ObservationIgnored private var lastProgressAt = ContinuousClock.now

    // 当前对话的身份（用于历史）
    private(set) var conversationID = UUID()
    private(set) var conversationCreatedAt = Date()

    /// 每译完一句（含重译 / 编辑，不含载入历史 / 插入外来文字）加一：界面据此响「成功」触觉。
    /// 不能看 `phase`：`translatedText` 和 `phase = .idle` 是同一拍变的，不朗读时 onChange 看到的已经不是 `.busy`
    private(set) var translatedCount = 0
    /// 单独朗读（试听声音 / 大字展示）读完加一：界面据此重新安排「空闲后归还音频会话」
    private(set) var speechIdleTick = 0

    /// 同声传译里「已经听完、正在翻译」的任务（不阻塞听下一句）：结束同声传译 / 取消一切时一起取消
    @ObservationIgnored private var detachedTranslations: [Task<Void, Never>] = []
    /// 每一轮「第几次翻译」：同一轮可能同时有两次翻译在路上（同声传译结束后最后一句还在译，用户马上改了它的原文 / 点了重译）。
    /// 晚回来的旧结果认得出自己已经过期，不碰这一轮（原来谁后回来谁赢，旧原文的译文会盖在新原文上，还存进历史）
    @ObservationIgnored private var translationSeq: [Turn.ID: Int] = [:]

    /// 同声传译：持续聆听周围的话，只翻译成我的语言，不朗读。
    private(set) var isEavesdropping = false
    /// 同声传译时一句话没听清后多久重新开始聆听
    @ObservationIgnored var eavesdropRetryDelay: Duration = .milliseconds(300)

    // 键盘输入
    private(set) var draft = ""
    /// 输入法组合中（拼音还没上屏）：组合开始前的草稿。预览按它显示，见 `previewDraft`
    private var composingBase: String?
    /// 给对方看的预览对应的原文：组合中的那段字母不算
    var previewDraft: String { composingBase ?? draft }
    private(set) var preview: Preview = .idle
    /// 发送文字时是否同时朗读译文
    var speakOnSend = true
    /// 语音对话里，翻译完成后是否自动朗读译文（设置里的"自动朗读译文"）
    var speakVoiceReplies = true
    /// 是否把对话写进历史（设置里的"保存对话历史"）
    var savesHistory = true
    /// 磁盘上的历史存储打不开、退回了内存：这次启动的对话退出后就没了（设置里提示）
    var historyIsVolatile = false
    /// 停止打字多久后才去翻译预览（避免每个字都翻一次）
    @ObservationIgnored var previewDelay: Duration = .milliseconds(600)

    @ObservationIgnored private let recognizer: SpeechRecognizing
    @ObservationIgnored private let synthesizer: SpeechSpeaking
    @ObservationIgnored private let engine: TranslationEngine
    @ObservationIgnored private let history: HistoryStoring?
    @ObservationIgnored private var pipeline: Task<Void, Never>?
    @ObservationIgnored private var previewTask: Task<Void, Never>?

    init(
        me: LanguageOption = .zhHans,
        them: LanguageOption = .en,
        recognizer: SpeechRecognizing,
        synthesizer: SpeechSpeaking,
        engine: TranslationEngine,
        history: HistoryStoring? = nil
    ) {
        self.me = me
        self.them = them
        self.recognizer = recognizer
        self.synthesizer = synthesizer
        self.engine = engine
        self.history = history
        (synthesizer as? SpeechProgressReporting)?.onProgress = { [weak self] end in
            guard let self, speakingTurnID != nil else { return }
            progressSeen = true
            lastProgressAt = .now
            spokenOffset = max(spokenOffset, end)
        }
    }

    /// 朗读译文并记录进度；读完 / 被打断后清掉。
    private func speakTracked(_ turnID: Turn.ID, text: String, code: String) async {
        speakToken += 1
        let mine = speakToken
        speakingTurnID = turnID
        spokenOffset = 0
        progressSeen = false
        lastProgressAt = .now
        let estimator = Task { [weak self] in await self?.estimateProgress(text: text, token: mine) }
        await synthesizer.speak(text, ttsCode: code)
        estimator.cancel()
        // 被新的朗读顶掉时，那一次的状态不能被这一次的收尾清掉
        if speakToken == mine { speakingTurnID = nil; spokenOffset = 0 }
    }

    /// 朗读器一直不报进度（部分增强 / 个人声音）：等一会儿还没有，就按平均语速往前推，
    /// 界面的高亮和滚动才不会停在第 1 句。一旦收到真实进度，立刻让位给真实的。
    private func estimateProgress(text: String, token: Int) async {
        try? await Task.sleep(for: progressEstimateDelay)
        let cjk = TextMetrics.weightedLength(text) > text.count + text.count / 2      // 多数是汉字等宽字符
        let perSecond = (cjk ? 4.5 : 15) * Double(max(0.1, speechRate)) / 0.5
        let step = 0.2
        let total = text.utf16.count
        while !Task.isCancelled, speakToken == token, spokenOffset < total {
            // 真实回调还在来（最近没有停滞）就让位；没有回调，或回调停了，才按估算推进
            let live = progressSeen && ContinuousClock.now - lastProgressAt < progressStallTimeout
            if !live { spokenOffset = min(total, spokenOffset + max(1, Int(perSecond * step))) }
            try? await Task.sleep(for: .milliseconds(200))
        }
    }

    // MARK: - 查询

    func language(of speaker: Speaker) -> LanguageOption { speaker == .me ? me : them }

    /// 一轮当时的原文 / 译文语言：优先用它自己记录的，没有记录（旧数据）才用当前语言。
    private func languages(of turn: Turn) -> (from: LanguageOption, to: LanguageOption) {
        (LanguageOption.with(id: turn.fromID) ?? language(of: turn.speaker),
         LanguageOption.with(id: turn.toID) ?? language(of: turn.speaker.other))
    }

    /// 新建一轮，同时记下当前的语言对。
    private func makeTurn(_ speaker: Speaker, kind: TurnKind, sourceText: String = "", translatedText: String? = nil,
                          state: TurnState = .listening, engineName: String? = nil) -> Turn {
        Turn(speaker: speaker, sourceText: sourceText, translatedText: translatedText, state: state,
             engineName: engineName, kind: kind,
             fromID: language(of: speaker).id, toID: language(of: speaker.other).id)
    }

    var currentTurn: Turn? { turns.last }

    var isListening: Bool {
        if case .listening = phase { return true }
        return false
    }

    var engineName: String { engine.name }

    /// 用户自己改过的标题；nil 表示用第一句话自动生成
    private(set) var customTitle: String?

    /// 对话标题：用户改过就用改过的；否则取第一句话的开头；还没说话时叫"新对话"。
    var title: String {
        if let customTitle { return customTitle }
        guard let first = turns.first(where: { !$0.sourceText.isEmpty }) else { return String(localized: "新对话") }
        let text = first.sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.count > 24 ? String(text.prefix(24)) + "…" : text
    }

    /// 某一轮在"某位屏幕主人"那一半屏上显示的文字：自己说的显示原话，对方说的显示译文。
    func text(of turn: Turn, on side: Speaker) -> String? {
        turn.speaker == side ? turn.sourceText : turn.translatedText
    }

    /// 导出为纯文本（分享用）。
    func transcript() -> String {
        Self.transcript(turns: turns, me: me, them: them)
    }

    /// 导出文本。是静态函数，所以历史列表里不用载入对话也能分享。
    static func transcript(turns: [Turn], me: LanguageOption, them: LanguageOption) -> String {
        func language(of speaker: Speaker) -> LanguageOption { speaker == .me ? me : them }
        return turns.compactMap { turn -> String? in
            guard !turn.sourceText.isEmpty else { return nil }
            let who = turn.speaker == .me ? String(localized: "我") : String(localized: "对方")
            let from = (LanguageOption.with(id: turn.fromID) ?? language(of: turn.speaker)).nativeName
            var line = String(localized: "\(who)（\(from)）：\(turn.sourceText)")
            if let t = turn.translatedText {
                let to = (LanguageOption.with(id: turn.toID) ?? language(of: turn.speaker.other)).nativeName
                line += "\n" + String(localized: "→（\(to)）\(t)")
            }
            return line
        }.joined(separator: "\n\n")
    }

    // MARK: - 语音操作

    /// 轻点麦克风：空闲 → 自动模式聆听（停顿 1.2 秒自动结束）；正在聆听 → 提前结束。
    func micTapped(_ speaker: Speaker) {
        if case .listening(let current) = phase {
            if current == speaker { stopListening() }
            return
        }
        startListening(speaker, pushToTalk: false)
    }

    /// 手指刚落到麦克风上：让识别器提前准备（预热音频会话）。只是预热，不开始听。
    func prepareToListen() { recognizer.prepare() }

    /// 手指一按下麦克风就开始听（对讲机模式，松手结束），不等"按够多久"——启动识别本身要几百毫秒，
    /// 再等一个长按判定会显得很慢。返回 false = 没有开始（已经在听）。
    @discardableResult
    func holdBegan(_ speaker: Speaker) -> Bool {
        if case .listening = phase { return false }
        startListening(speaker, pushToTalk: true)
        return true
    }

    /// 按下时已经开始听，但手指很快抬起来了：这是一次"轻点"，改成自动模式（停顿自动结束）。
    func holdPromotedToTap(_ speaker: Speaker) {
        // 标记要无条件先记下：按得很快时，识别任务可能还没跑到"开始聆听"（还在等权限 / 刚排上队），
        // 到时候 `listen` 读到这个标记就直接用自动模式。已经在听了，再通知识别器改模式。
        promotedToAuto = true
        if case .listening(let current) = phase, current == speaker { recognizer.enableAutoEndpoint() }
    }
    @ObservationIgnored private var promotedToAuto = false

    func holdEnded(_ speaker: Speaker) {
        if case .listening(let current) = phase, current == speaker { stopListening() }
    }

    func stopListening() {
        stopRequested = true
        recognizer.stop()
    }

    /// 要求结束聆听时，识别器可能还没真正开始（还在等权限弹窗）——这时 recognizer.stop() 是空操作。
    /// 记下这个请求，识别器一就绪就按"已经松手"处理，否则按住说话的会话会一直开着。
    @ObservationIgnored private var stopRequested = false

    /// 打断一切（朗读、聆听、预览），回到空闲。
    /// 用户主动选 / 换语言之后调用（根上用它把语言存成默认值）
    @ObservationIgnored var onLanguageChoice: ((LanguageOption, LanguageOption) -> Void)?

    func cancelAll(keepingDetached: Bool = false) {
        isEavesdropping = false      // 同声传译循环随之结束，别留下"同声传译中"但其实没在听的状态
        if !keepingDetached {
            detachedTranslations.forEach { $0.cancel() }
            detachedTranslations.removeAll()
        }
        pipeline?.cancel()
        pipeline = nil
        previewTask?.cancel()
        previewTask = nil
        recognizer.stop()
        synthesizer.stop()
        if case .listening = phase { phase = .idle }
        if case .busy = phase { phase = .idle }
    }

    /// 选语言。选的是另一边正在用的那一种时，把两边对调——两边语言相同没有意义，系统翻译还会直接报错。
    func choose(_ language: LanguageOption, for speaker: Speaker) {
        guard language != self.language(of: speaker) else { return }      // 没变：不重写默认值、不取消预览重新翻译
        switch speaker {
        case .me:
            if language == them { them = me }
            me = language
        case .them:
            if language == me { me = them }
            them = language
        }
        languagesChanged()
    }

    func swapLanguages() {
        guard phase == .idle else { return }
        // 不能用 `swap(&me, &them)`：它让两个被观察的属性同时处于「正在修改」，第二个的 willSet 会让 SwiftUI 同步刷新、
        // 刷新时视图读到 `me` → 独占访问冲突 → 直接闪退（真机上连点对调 6~9 次必现，build 20261118.2）。一个一个赋值，每次只改一个。
        let (newMe, newThem) = (them, me)
        me = newMe
        them = newThem
        languagesChanged()
    }

    /// 用户主动选 / 换了语言：记住成下次启动的默认值（载入历史对话时 `load()` 也会改语言，但那不该改默认值，所以不走这里），
    /// 并重算键盘输入的预览——原来预览还是旧方向，发出去却按新方向翻译。
    private func languagesChanged() {
        onLanguageChoice?(me, them)
        previewTask?.cancel()
        if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { preview = .idle } else { updateDraft(draft) }
    }

    func dismissNotice() { notice = nil }

    // MARK: - 键盘输入

    /// 输入框内容变化：更新草稿并（防抖后）翻译一份预览给对方看。
    func updateDraft(_ text: String, composing: Bool = false) {
        if composing {
            // 拼音 / 假名还没上屏：输入框照常显示，但预览停在组合开始前的内容上（不翻译「ni hao」这种中间态）
            if composingBase == nil { composingBase = draft }
            draft = text
            return
        }
        composingBase = nil
        draft = text
        previewTask?.cancel()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            preview = .idle
            return
        }
        preview = .loading
        let from = me, to = them
        previewTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: previewDelay)
            guard !Task.isCancelled else { return }
            do {
                let translated = try await engine.translate(trimmed, from: from, to: to)
                guard !Task.isCancelled else { return }
                preview = .ready(translated)
            } catch {
                guard !Task.isCancelled else { return }
                preview = .failed
            }
        }
    }

    /// 发送文字：作为"我"说的一轮，走和语音相同的 翻译 → （朗读）流程。
    /// 返回 false = 没发出去（空文本，或正在聆听）；调用方据此决定要不要关闭输入界面。
    @discardableResult
    func sendDraft() -> Bool {
        sendText(draft)
    }

    @discardableResult
    func sendText(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if case .listening = phase { return false }          // 正在聆听时不接受发送
        isEavesdropping = false           // 同声传译两句之间发文字：同声传译循环随 pipeline 一起结束，别留下「同声传译中」但没人在听
        pipeline?.cancel()
        previewTask?.cancel()
        synthesizer.stop()
        notice = nil
        draft = ""
        composingBase = nil
        preview = .idle

        let turn = makeTurn(.me, kind: .text, sourceText: trimmed, state: .translating)
        turns.append(turn)
        phase = .busy
        let speak = speakOnSend
        speakOnSend = true          // 「仅显示」只管这一次：不复位的话，之后的常用短语 / 对话流发送都不再朗读
        pipeline = Task { await self.translateAndSpeak(turnID: turn.id, speak: speak) }
        return true
    }

    // MARK: - 对已有轮次的操作

    /// 用当前引擎重新翻译某一轮（不再朗读）。
    func retranslate(_ turnID: Turn.ID) {
        guard phase == .idle, !isEavesdropping, let turn = turns.first(where: { $0.id == turnID }), !turn.sourceText.isEmpty else { return }
        pipeline = Task { await self.translateAndSpeak(turnID: turnID, speak: false) }
    }

    /// 修正识别错误的原文，然后重新翻译。
    func editSource(_ turnID: Turn.ID, to newText: String) {
        let trimmed = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard phase == .idle, !isEavesdropping, !trimmed.isEmpty, turns.contains(where: { $0.id == turnID }) else { return }
        // 原文变了，旧译文就不再对应它：先清掉。否则这次翻译失败时，界面会把旧译文当成新原文的译文显示（还会被存进历史）
        update(turnID) { $0.sourceText = trimmed; $0.translatedText = nil }
        persist(turnID)          // 立刻存：这次翻译若被取消，历史里也不能还是旧原文 / 旧译文
        pipeline = Task { await self.translateAndSpeak(turnID: turnID, speak: false) }
    }

    /// 再朗读一遍译文。
    func replay(_ turnID: Turn.ID) {
        guard phase == .idle, !isEavesdropping, let turn = turns.first(where: { $0.id == turnID }),
              let translated = turn.translatedText else { return }
        let code = languages(of: turn).to.ttsCode
        phase = .busy
        update(turnID) { $0.state = .speaking }
        pipeline = Task {
            guard !Task.isCancelled else { abandon(turnID); return }
            await speakTracked(turnID, text: translated, code: code)
            // 被打断（点麦克风 / 发文字 / 换对话）：这一轮不能永远停在「朗读中」
            guard !Task.isCancelled else { abandon(turnID); return }
            update(turnID) { $0.state = .done }
            phase = .idle
        }
    }

    func deleteTurn(_ turnID: Turn.ID) {
        guard phase == .idle else { return }
        removeTurn(turnID)
        history?.delete(turnID: turnID)
        if turns.isEmpty {
            history?.deleteConversation(id: conversationID)
        } else if let first = turns.first {
            persist(first.id)        // 标题可能来自刚删掉的那句：用剩下的第一句重新生成，历史列表里才不会还显示它
        }
    }

    func copyText(of turn: Turn, side: Speaker) {
        UIPasteboard.general.string = text(of: turn, on: side)
    }

    // MARK: - 同声传译

    /// 开始同声传译：反复聆听"对方语言"的话，翻译成我的语言显示，全程不朗读。
    func startEavesdrop() {
        guard !isEavesdropping else { return }
        cancelAll(keepingDetached: true)          // 上一轮刚「结束」时还在译的几句不能被紧接着的「开始」取消
        notice = nil
        isEavesdropping = true
        if Self.demoListenScript { runListenDemo(); return }
        pipeline = Task { [weak self] in
            guard let self else { return }
            var quickSilences = 0
            while isEavesdropping, !Task.isCancelled {
                let began = ContinuousClock.now
                let result = await runListening(.them, pushToTalk: false, speak: false,
                                                kind: .eavesdrop, reportNoSpeech: false)
                switch result {
                case .completed: quickSilences = 0
                case .noSpeech:
                    // 识别器一启动就失败（没有离线听写模型、音频路由刚变）会被当成「没听清」，每 300ms 重建一遍引擎：
                    // 连着 6 次不到 2 秒就放弃并提示，别空转耗电、界面还写着「正在听…」
                    quickSilences = began.duration(to: .now) < .seconds(2) ? quickSilences + 1 : 0
                    if quickSilences >= 6 {
                        notice = .recognizerUnavailable(String(localized: "语音识别没有响应，已停止聆听。"))
                        isEavesdropping = false
                        break
                    }
                    try? await Task.sleep(for: eavesdropRetryDelay)
                // 权限 / 麦克风问题，别空转。被取消（旧任务在「停止后立刻再开始」时才醒来）不算失败，别把新一轮的标志清掉
                case .failed: if !Task.isCancelled { isEavesdropping = false }
                }
            }
        }
    }

    /// 演示剧本（`-XTransDemo listen`）：第 1 秒开始听第一句，3 秒译完，4.5 秒开始听第二句，5.7 秒译完，7 秒开始听第三句并一直听着
    private func runListenDemo() {
        pipeline = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1000))
            guard let self, isEavesdropping else { return }
            let first = Turn(speaker: .them, sourceText: "The next stop is", state: .listening, kind: .eavesdrop)
            turns.append(first)
            phase = .listening(.them)
            levels = [3, 8, 14, 6, 18, 11, 4, 12, 20, 8, 4, 10, 16, 7].map { $0 / 24 }
            try? await Task.sleep(for: .milliseconds(1200))
            update(first.id) { $0.sourceText = "The next stop is Shibuya. Please mind the gap."; $0.state = .translating }
            try? await Task.sleep(for: .milliseconds(900))
            update(first.id) { $0.translatedText = "下一站是涩谷。请注意站台间隙。"; $0.state = .done; $0.engineName = "Apple 端侧"; $0.latency = 0.4 }
            try? await Task.sleep(for: .milliseconds(1400))
            let second = Turn(speaker: .them, sourceText: "Doors on the left", state: .listening, kind: .eavesdrop)
            turns.append(second)
            try? await Task.sleep(for: .milliseconds(1200))
            update(second.id) { $0.sourceText = "Doors on the left side will open."; $0.translatedText = "左侧车门将会打开。"; $0.state = .done; $0.engineName = "Apple 端侧"; $0.latency = 0.4 }
            try? await Task.sleep(for: .milliseconds(1400))
            turns.append(Turn(speaker: .them, sourceText: "Thank you for riding", state: .listening, kind: .eavesdrop))
        }
    }

    /// 同声传译里某一句翻译失败后重试：不经过 `retranslate`（它在旁听期间被挡住，免得覆盖旁听循环的 pipeline）——
    /// 这里走独立任务，不碰 `phase`，旁听循环照常继续听下一句
    func retryDetached(_ turnID: Turn.ID) {
        guard let turn = turns.first(where: { $0.id == turnID }), !turn.sourceText.isEmpty else { return }
        let task = Task<Void, Never> { [weak self] in
            guard let self else { return }
            await self.translateAndSpeak(turnID: turnID, speak: false, touchesPhase: false)
        }
        detachedTranslations.append(task)
    }

    func stopEavesdrop() {
        isEavesdropping = false
        // 已经听完、正在翻译的那几句让它们译完（原来点「结束」会把它们一起取消，用户刚听到的话就没了）
        cancelAll(keepingDetached: true)
    }

    // MARK: - 给"加入对话"各入口用的辅助

    /// 只翻译、不进对话（图片文字、粘贴文字、大字展示都用它）。
    func translateText(_ text: String, from: LanguageOption, to: LanguageOption) async throws -> String {
        try await engine.translate(text, from: from, to: to)
    }

    /// 正在进行的「单纯朗读」（大字展示 / 图片文字 / 试听）有几个：它们不改 `phase`，空闲归还音频会话前要看这个，不然长句读到一半被掐断
    @ObservationIgnored private var standaloneSpeech = 0
    var isSpeakingStandalone: Bool { standaloneSpeech > 0 }

    /// 单纯朗读一段文字（不产生对话轮次）。
    func speak(_ text: String, in language: LanguageOption) {
        Task { standaloneSpeech += 1; await synthesizer.speak(text, ttsCode: language.ttsCode); standaloneSpeech -= 1; speechIdleTick += 1 }
    }

    /// 试听一个声音（设置里选声音时用）。`voiceID` 为 `VoiceCatalog.autoID` 表示系统默认声音。
    func previewVoice(_ voiceID: String, for language: LanguageOption) {
        Task { standaloneSpeech += 1; await synthesizer.speak(VoiceCatalog.sample(for: language), ttsCode: language.ttsCode, voiceID: voiceID); standaloneSpeech -= 1; speechIdleTick += 1 }
    }

    /// 停止当前朗读（离开设置里的声音页时用）。
    func stopSpeaking() { synthesizer.stop() }

    /// 把"外来的文字"（图片 / 粘贴）连同译文放进对话，算作对方的一轮：原文是对方语言，译文是我的语言。
    @discardableResult
    func addIncoming(source: String, translated: String, kind: TurnKind) -> Turn.ID {
        let turn = makeTurn(.them, kind: kind, sourceText: source, translatedText: translated,
                            state: .done, engineName: engine.name)
        turns.append(turn)
        persist(turn.id)
        return turn.id
    }

    // MARK: - 对话本身

    /// 开始一场新对话（当前这场已经随每一轮保存好了）。
    func newConversation() {
        isEavesdropping = false
        cancelAll()
        turns.removeAll()
        notice = nil
        draft = ""
        composingBase = nil
        preview = .idle
        conversationID = UUID()
        conversationCreatedAt = Date()
        customTitle = nil
    }

    func clear() { newConversation() }

    /// 载入历史里的一场对话，可以接着聊。
    func load(_ id: UUID) {
        guard let history, let info = history.info(of: id) else { return }
        cancelAll()
        notice = nil
        draft = ""
        composingBase = nil
        preview = .idle
        conversationID = id
        conversationCreatedAt = info.createdAt
        customTitle = info.titleIsCustom ? info.title : nil
        me = info.me
        them = info.them
        turns = history.turns(in: id)
    }

    /// 重命名一场对话（当前这场或历史里的任意一场）。空标题忽略。
    func renameConversation(_ id: UUID, to newTitle: String) {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if id == conversationID { customTitle = trimmed }
        history?.rename(conversationID: id, to: trimmed)
    }

    func setFavorite(_ value: Bool, for id: UUID) {
        history?.setFavorite(value, conversationID: id)
    }

    /// 清空全部历史，并开一场新的对话。
    func clearAllHistory() {
        history?.deleteAll()
        newConversation()
    }

    /// 从历史列表删除一场对话；删的是当前这场就同时开一场新的。
    func deleteConversation(_ id: UUID) {
        history?.deleteConversation(id: id)
        if id == conversationID { newConversation() }
    }

    // MARK: - 聆听流程

    private enum ListenResult { case completed, noSpeech, failed }

    private func startListening(_ speaker: Speaker, pushToTalk: Bool) {
        isEavesdropping = false
        pipeline?.cancel()
        synthesizer.stop()
        notice = nil
        promotedToAuto = false
        pipeline = Task { [weak self] in
            guard let self else { return }
            _ = await runListening(speaker, pushToTalk: pushToTalk, speak: speakVoiceReplies, kind: .voice, reportNoSpeech: true)
        }
    }

    /// 完整地听一句：权限 → 识别 → （翻译 → 朗读）。语音轮次和同声传译共用。
    private func runListening(_ speaker: Speaker, pushToTalk: Bool, speak: Bool,
                              kind: TurnKind, reportNoSpeech: Bool) async -> ListenResult {
        // 还没起步就已经被取消（点麦克风的同一瞬间退后台 / 换对话 / 新建对话，`cancelAll` 先到）：什么都不碰。
        // 原来这里照样把 phase 设成「正在听」再退出，之后没人把它改回来——麦克风点了没反应、发不了字、换不了语言
        guard !Task.isCancelled else { return .failed }
        let turn = makeTurn(speaker, kind: kind)
        // 同声传译：一句话从「静音」到「有声音」才加进列表。原来每个静音周期都加 / 删一轮，已挂载的页面在遮罩下反复做「上浮、滚动」动画
        var added = kind != .eavesdrop
        if added { turns.append(turn) }
        func addIfNeeded() {
            guard !added else { return }
            added = true
            turns.append(turn)
        }
        phase = .listening(speaker)
        MicTiming.mark("phaseListening")
        levels = Array(repeating: 0, count: levels.count)
        stopRequested = false

        let language = language(of: speaker)
        let permission = await recognizer.requestPermissions()
        // 等权限弹窗的时候被取消了（比如用户又点了别的）：不要再去开麦克风。
        // 被取消的任务不碰 phase / notice —— 那是取消它的人（新的操作）说了算。
        guard !Task.isCancelled else { removeTurn(turn.id); return .failed }
        if permission == .granted, stopRequested {
            // 等权限的时候用户已经松手 / 又点了一次：这次聆听没有意义，安静地放弃
            removeTurn(turn.id)
            phase = .idle
            return .noSpeech
        }
        guard permission == .granted else {
            removeTurn(turn.id)
            notice = permission == .microphoneDenied ? .microphoneDenied : .speechDenied
            phase = .idle
            return .failed
        }
        var finalText = ""
        do {
            let stream = recognizer.listen(locale: Locale(identifier: language.speechLocale), autoEndpoint: !pushToTalk || promotedToAuto)
            for try await event in stream {
                switch event {
                case .partial(let text):
                    if !text.isEmpty { addIfNeeded() }
                    update(turn.id) { $0.sourceText = text }
                case .level(let level): pushLevel(level)
                case .final(let text): finalText = text
                }
            }
        } catch {
            removeTurn(turn.id)
            notice = .recognizerUnavailable(error.localizedDescription)
            phase = .idle
            return .failed
        }
        // 听到一半被取消（结束同声传译、切到别的对话……）：这一句没走完流程，别留一条永远"正在听"的残句
        guard !Task.isCancelled else { removeTurn(turn.id); return .failed }
        if !finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { addIfNeeded() }
        return await finishUtterance(turnID: turn.id, speaker: speaker, text: finalText,
                                     speak: speak, reportNoSpeech: reportNoSpeech, detached: kind == .eavesdrop)
    }

    private func finishUtterance(turnID: Turn.ID, speaker: Speaker, text: String,
                                 speak: Bool, reportNoSpeech: Bool, detached: Bool = false) async -> ListenResult {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            removeTurn(turnID)
            if reportNoSpeech { notice = .noSpeech(speaker) }
            phase = .idle
            return .noSpeech
        }
        update(turnID) { $0.sourceText = trimmed; $0.state = .translating }
        if detached {
            // 同声传译：翻译放到独立任务里，循环马上回去听下一句。原来在这里 await 翻译（冷启动首次翻译可能几秒），
            // 之后才重新请求权限、建引擎、开始识别——下一句的开头被整段吃掉
            let task = Task<Void, Never> { [weak self] in
                guard let self else { return }
                await self.translateAndSpeak(turnID: turnID, speak: false, touchesPhase: false)
            }
            detachedTranslations.append(task)
            detachedTranslations.removeAll { $0.isCancelled }
            return .completed
        }
        phase = .busy
        await translateAndSpeak(turnID: turnID, speak: speak)
        return .completed
    }

    private func translateAndSpeak(turnID: Turn.ID, speak: Bool, touchesPhase: Bool = true) async {
        // 起步前就已经被取消（同一个 run-loop 里 newConversation / cancelAll 先到）：什么都不碰，phase 是新操作说了算
        guard !Task.isCancelled else { abandon(turnID); return }
        guard let turn = turns.first(where: { $0.id == turnID }) else { if touchesPhase { phase = .idle }; return }
        let (from, to) = languages(of: turn)
        let seq = (translationSeq[turnID] ?? 0) + 1
        translationSeq[turnID] = seq
        update(turnID) { $0.state = .translating }
        if touchesPhase { phase = .busy }
        let started = ContinuousClock.now
        do {
            let translated = try await engine.translate(turn.sourceText, from: from, to: to)
            guard translationSeq[turnID] == seq else { return }          // 这一轮已经有更新的一次翻译在做：这份过期了
            // 被取消的任务不能碰 phase：此时多半已经开始了新的操作（新的翻译 / 聆听），
            // 把 phase 改回 idle 会让界面以为空闲，用户可以在翻译中途再点麦克风或切换语言。
            guard !Task.isCancelled else { abandon(turnID); return }
            let elapsed = started.duration(to: .now)
            let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            update(turnID) {
                $0.translatedText = translated
                $0.engineName = engine.name
                $0.latency = seconds
                $0.state = speak ? .speaking : .done
            }
            translatedCount += 1
            persist(turnID)
            if speak {
                await speakTracked(turnID, text: translated, code: to.ttsCode)
                guard !Task.isCancelled else { abandon(turnID); return }
                update(turnID) { $0.state = .done }
            }
        } catch {
            guard translationSeq[turnID] == seq else { return }
            guard !Task.isCancelled else { abandon(turnID); return }
            update(turnID) { $0.state = .failed(error.localizedDescription) }
            persist(turnID)      // 原话也要保存，之后可以重试
        }
        if touchesPhase { phase = .idle }
    }

    // MARK: - 小工具

    /// 一轮在翻译 / 朗读中被打断：不让它永远停在"翻译中…""朗读中…"。
    /// 已经有译文的（朗读被打断）算完成；还没译完的标成"已取消"，用户可以点重试。
    private func abandon(_ turnID: Turn.ID) {
        update(turnID) {
            switch $0.state {
            case .speaking: $0.state = .done
            case .translating:
                $0.state = $0.translatedText == nil ? .failed(String(localized: "已取消")) : .done
            default: break
            }
        }
    }

    private func persist(_ turnID: Turn.ID) {
        guard savesHistory, let history, let turn = turns.first(where: { $0.id == turnID }) else { return }
        let info = ConversationInfo(id: conversationID, title: title, me: me, them: them,
                                    createdAt: conversationCreatedAt, titleIsCustom: customTitle != nil)
        history.save(turn, in: info)
    }

    private func update(_ id: Turn.ID, _ change: (inout Turn) -> Void) {
        guard let index = turns.firstIndex(where: { $0.id == id }) else { return }
        change(&turns[index])
    }

    private func removeTurn(_ id: Turn.ID) {
        turns.removeAll { $0.id == id }
    }

    private func pushLevel(_ level: Float) {
        levels.removeFirst()
        levels.append(level)
    }
}

// MARK: - 演示数据（截图 / 预览用，不启动任何服务，也不落盘）

extension ConversationSession {
    enum DemoScene: String {
        case m1, m2, m3, m4
        /// 多轮对话，用于对话流和历史的截图
        case stream
        /// 异常状态：没听清 / 麦克风权限被拒
        case e1, e3
        /// 长译文正在朗读：测跟读窗口。`-XTransDemoOffset N` 指定读到译文的第 N 个 UTF-16 单元
        case long
        /// 一句话说完后过一会儿又发一句：测"思考中 → 译文"的交叉淡入和上一轮缩小
        case next
        /// 空闲 1.5 秒后进入「我在聆听」2.5 秒再回到空闲：测聆听光晕的出现 / 消失转场（模拟器没有麦克风）
        case glow
        /// 「只听不说」页的演示：模拟器没有麦克风，页面一出现就按剧本一句一句「听到」（配合 `-XTransScreen eavesdrop`）
        case listen
    }
    /// 演示：只听不说按剧本走，不碰真实识别器
    static var demoListenScript = false

    func seed(_ scene: DemoScene) {
        turns.removeAll()
        notice = nil
        let hello = Turn(speaker: .them, sourceText: "Hello! Welcome to Tokyo.",
                         translatedText: "你好！欢迎来到东京。", state: .done, engineName: "Apple 端侧", latency: 0.3)
        switch scene {
        case .listen:
            Self.demoListenScript = true
            phase = .idle
        case .glow:
            turns = [hello]
            phase = .idle
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(1500))
                self?.phase = .listening(.me)
                try? await Task.sleep(for: .milliseconds(2500))
                self?.phase = .idle
            }
        case .next:
            turns = [hello]
            phase = .idle
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(1500))
                self?.sendText("请问最近的地铁站怎么走？")
            }
        case .long:
            // 和真实流程一致：先"翻译中"，稍等一下译文出现并立刻开始朗读；每 0.1 秒读 2 个 UTF-16 单元（和真实朗读器回调同一条路径）
            let full = String(repeating: "打扰一下，我想办理入住。我用陈这个名字订了三晚的房间。请问早餐几点开始？另外，可以延迟退房吗？我的航班在晚上六点起飞。非常感谢。", count: max(1, UserDefaults.standard.integer(forKey: "XTransDemoRepeat")))
            let turn = Turn(
                speaker: .them,
                sourceText: "Excuse me, I'd like to check in. I booked a room for three nights under the name Chen. Could you tell me what time breakfast starts? Also, is there a late checkout option? My flight leaves at six in the evening. Thank you so much.",
                state: .translating, engineName: "Apple 端侧", latency: 0.4)
            turns = [hello, turn]
            phase = .busy
            let start = UserDefaults.standard.integer(forKey: "XTransDemoOffset")
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(1200))
                self?.update(turn.id) { $0.translatedText = full; $0.state = .speaking }
                self?.speakingTurnID = turn.id
                var offset = start
                while offset < full.utf16.count {
                    self?.spokenOffset = offset
                    try? await Task.sleep(for: .milliseconds(100))
                    offset += 2
                }
                self?.speakingTurnID = nil
                self?.update(turn.id) { $0.state = .done }
            }
        case .m1:
            phase = .idle
        case .m2:
            turns = [hello, Turn(speaker: .me, sourceText: "请问最近的地铁站怎么走", state: .listening)]
            phase = .listening(.me)
            levels = [3, 8, 14, 6, 18, 11, 4, 12, 20, 8, 4, 10, 16, 7].map { $0 / 24 }
        case .m3:
            turns = [hello, Turn(speaker: .me, sourceText: "请问最近的地铁站怎么走？",
                                 translatedText: "Excuse me, how do I get to the nearest subway station?",
                                 state: .speaking, engineName: "Apple 端侧", latency: 0.3)]
            phase = .busy
        case .m4:
            turns = [
                Turn(speaker: .me, sourceText: "请问最近的地铁站怎么走？",
                     translatedText: "Excuse me, how do I get to the nearest subway station?",
                     state: .done, engineName: "Apple 端侧", latency: 0.3),
                Turn(speaker: .them, sourceText: "Go straight and turn left at the", state: .listening),
            ]
            phase = .listening(.them)
            levels = [6, 12, 5, 16, 9, 20, 7, 11, 4, 14, 8, 18, 6, 10].map { $0 / 24 }
        case .e1:
            turns = [hello]
            notice = .noSpeech(.me)
            phase = .idle
        case .e3:
            notice = .microphoneDenied
            phase = .idle
        case .stream:
            let base = Date().addingTimeInterval(-600)
            turns = [
                Turn(speaker: .me, sourceText: "请问最近的地铁站怎么走？",
                     translatedText: "Excuse me, how do I get to the nearest subway station?",
                     state: .done, engineName: "Apple 端侧", latency: 0.3, createdAt: base),
                Turn(speaker: .them, sourceText: "Go straight and turn left at the traffic light.",
                     translatedText: "一直往前走，然后在红绿灯左转。",
                     state: .done, engineName: "Apple 端侧", latency: 0.4, createdAt: base.addingTimeInterval(40)),
                Turn(speaker: .me, sourceText: "多少钱？",
                     translatedText: "How much is it?",
                     state: .done, engineName: "Apple 端侧", latency: 0.3, createdAt: base.addingTimeInterval(240)),
                Turn(speaker: .them, sourceText: "It's 180 yen for one ride.",
                     translatedText: "一次 180 日元。",
                     state: .done, engineName: "Apple 端侧", latency: 0.4, createdAt: base.addingTimeInterval(280)),
            ]
            phase = .idle
        }
    }
}

extension ConversationSession {
    /// 键盘输入界面的演示数据（截图用）：草稿 + 已翻译好的预览。
    func seedCompose() {
        draft = "我在车站东口等你"
        preview = .ready("I'll wait for you at the east exit of the station.")
    }
}
