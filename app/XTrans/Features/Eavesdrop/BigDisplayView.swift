import SwiftUI

/// 要整页大字展示的内容。
struct BigDisplayRequest: Identifiable {
    let id = UUID()
    /// 我的话（用我的语言写）
    var text: String
    /// 已有的译文（用对方的语言）；没有就进来后自己翻译
    var translation: String?
    /// 这句话当时的原文 / 译文语言（从旧消息进来时带上）：换过语言之后，朗读和重译仍按当时的语言，不用现在的
    var fromID: String? = nil
    var toID: String? = nil
}

/// X1 · 大字展示：把译文用超大字号铺满屏幕给对方看，适合嘈杂环境或对方听不清的时候。
/// 可以直接在底部改字，译文会随之更新。
struct BigDisplayView: View {
    let session: ConversationSession
    let request: BigDisplayRequest
    let onClose: () -> Void

    /// 关闭按钮、大字、输入框三者的左右边距一致
    private static let margin: CGFloat = 20

    @State private var text: String
    @State private var translation: String?
    @State private var failed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.activeFold) private var fold
    @State private var task: Task<Void, Never>?
    @FocusState private var focused: Bool

    init(session: ConversationSession, request: BigDisplayRequest, onClose: @escaping () -> Void) {
        self.session = session
        self.request = request
        self.onClose = onClose
        _text = State(initialValue: request.text)
        _translation = State(initialValue: request.translation)
    }

    var body: some View {
        SideBarHost { vertical in
            bigBody(vertical: vertical)
            .background { AuroraBackground() }
        } items: {
            ToolbarItem(placement: .cancellationAction) {
                Button(action: onClose) { BarLabel("关闭", symbol: "xmark") }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    if let translation { session.speak(translation, in: targetLanguage) }
                } label: { BarLabel("朗读译文", symbol: "speaker.wave.2") }
                .disabled(translation == nil)
            }
        }
        .onAppear {
            if translation == nil { retranslate(after: .zero) }
        }
        // 全屏弹层刚出现时输入框还没进窗口，等一下再要键盘
        .task {
            guard request.text.isEmpty else { return }
            try? await Task.sleep(for: .milliseconds(350))
            focused = true
        }
        .onDisappear { task?.cancel(); session.stopSpeaking() }          // 关掉大字展示时，正在读的译文也要停
    }

    /// 展平：原来的整屏（大字 + 底部输入）。半开：折痕把屏幕切成两半——对方读的大字放在直立的那一半（竖放上半 / 横放左半），
    /// 关闭 / 朗读和输入放在另一半，折痕带本身留空。
    @ViewBuilder
    private func bigBody(vertical: Bool) -> some View {
        GeometryReader { geo in
            let frame = geo.frame(in: .global)
            if let fold, fold.height < fold.width, fold.maxY > frame.minY, fold.minY < frame.maxY {
                VStack(spacing: 0) {
                    display.frame(height: max(0, fold.minY - frame.minY))
                    Color.clear.frame(height: fold.height)
                    VStack(spacing: 0) {
                        if !vertical { topBar }
                        Spacer(minLength: 0)
                        editor
                    }
                }
            } else if let fold, fold.height >= fold.width, fold.maxX > frame.minX, fold.minX < frame.maxX {
                HStack(spacing: 0) {
                    display.frame(width: max(0, fold.minX - frame.minX))
                    Color.clear.frame(width: fold.width)
                    VStack(spacing: 0) {
                        if !vertical { topBar }
                        Spacer(minLength: 0)
                        editor
                    }
                }
            } else {
                VStack(spacing: 0) {
                    if !vertical { topBar }          // 系统竖排工具栏里已有"关闭 / 朗读"
                    display
                    editor
                }
            }
        }
    }

    private var topBar: some View {
        HStack {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.fg)
                    .frame(width: 44, height: 44)
                    .glass(in: Circle(), interactive: true)
            }
            .accessibilityLabel("关闭")
            Spacer()
            Button {
                if let translation { session.speak(translation, in: targetLanguage) }
            } label: {
                Image(systemName: "speaker.wave.2")
                    .font(.system(size: 17))
                    .foregroundStyle(Theme.fg)
                    .frame(width: 44, height: 44)
                    .glass(in: Circle(), interactive: true)
            }
            .disabled(translation == nil)
            .accessibilityLabel("朗读译文")
        }
        .padding(.horizontal, Self.margin)
        .padding(.top, 8)
    }

    /// 译文区：空间够时用超大字号，长句子自动缩小到刚好放下（最小 0.35 倍）；
    /// 键盘弹出、横屏等高度不够时（< 220pt）改小字号并允许滚动，绝不截断。
    private var display: some View {
        GeometryReader { geo in
            let tight = geo.size.height < 220
            Group {
                if tight {
                    ScrollView(.vertical) { displayContent(tight: true) }
                        .scrollBounceBehavior(.basedOnSize)
                        .dismissKeyboardInScrollArea()
                } else {
                    displayContent(tight: false)
                        .frame(maxHeight: .infinity)
                }
            }
            // 点一下译文就收键盘：横屏键盘占掉大半个屏幕时，要让对方看清全文只能先收键盘
            .contentShape(Rectangle())
            .onTapGesture { focused = false }
        }
    }

    private func displayContent(tight: Bool) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            if let translation {
                Text(translation)
                    .font(.system(size: tight ? 30 : 48, weight: .bold))
                    .minimumScaleFactor(tight ? 1 : 0.35)
                    .foregroundStyle(Theme.fg)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(text)
                    .font(.system(.footnote))
                    .foregroundStyle(Theme.mut)
            } else if failed {
                VStack(alignment: .leading, spacing: 10) {
                    Text("翻译失败，请稍后再试").font(.system(.title3)).foregroundStyle(Theme.err)
                    Button("重试") { failed = false; retranslate(after: .zero) }
                        .font(.system(.body).weight(.semibold))
                        .foregroundStyle(Theme.fg)
                        .padding(.horizontal, 18)
                        .frame(minHeight: 44)
                        .glass(in: Capsule(), interactive: true)
                }
            } else if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("在下面写要给对方看的话")
                    .font(.system(.title3))
                    .foregroundStyle(Theme.mut)
            } else {
                ThinkingDots()
            }
        }
        .padding(.horizontal, Self.margin)
        .frame(maxWidth: .infinity, alignment: tight ? .topLeading : .leading)
        // 每敲一个字译文先清空（「…」）、半秒后新译文回来：之前是硬切（给对方看的屏幕会闪），现在交叉淡化。
        // 不保留旧译文：它对应的是上一版原文，对方会读到错的意思
        .animation(reduceMotion ? .reduced : .easeInOut(duration: 0.2), value: translation == nil)
        .accessibilityElement(children: .combine)
    }

    private var editor: some View {
        HStack(spacing: 8) {
            TextField("\(sourceLanguage.nativeName)：写给对方看…", text: $text, axis: .vertical)
                .lineLimit(1...3)
                .focused($focused)
                .font(.system(.body))
                .foregroundStyle(Theme.fg)
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
                .glass(in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .refocusOnTap($focused)
                .refocusOnActive($focused)
                .onChange(of: text) { _, newValue in
                    translation = newValue == request.text ? request.translation : nil
                    failed = false
                    retranslate(after: .milliseconds(500))
                }
        }
        .padding(.horizontal, Self.margin)
        .padding(.vertical, 10)
    }

    private var sourceLanguage: LanguageOption { LanguageOption.with(id: request.fromID) ?? session.me }
    private var targetLanguage: LanguageOption { LanguageOption.with(id: request.toID) ?? session.them }

    private func retranslate(after delay: Duration) {
        task?.cancel()
        let source = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty, translation == nil else { return }
        task = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            do {
                let result = try await session.translateText(source, from: sourceLanguage, to: targetLanguage)
                guard !Task.isCancelled else { return }
                translation = result
            } catch {
                guard !Task.isCancelled else { return }
                failed = true
            }
        }
    }
}
