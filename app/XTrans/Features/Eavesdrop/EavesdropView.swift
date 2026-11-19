import SwiftUI

/// 同声传译：只听不说。持续聆听周围人的话（按"对方语言"识别），翻译成我的语言显示，全程不朗读。
/// 适合开会、听讲、广播、导游讲解。
struct EavesdropView: View {
    let session: ConversationSession
    let onStop: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    // 字号用「具体数值 + 随系统字号缩放」：数值字号可以插值，新的一句出现时上一句才是平滑地从大缩小（和对话流页同一做法）
    @ScaledMetric(relativeTo: .title) private var bigSize: CGFloat = 28
    @ScaledMetric(relativeTo: .body) private var smallSize: CGFloat = 17
    @ScaledMetric(relativeTo: .footnote) private var sourceSize: CGFloat = 13

    /// 进来之前就已经在对话里的同声传译轮次（以前的场次、载入的历史）：这一场不显示
    @State private var hidden: Set<UUID> = []
    private var lines: [Turn] { session.turns.filter { $0.kind == .eavesdrop && !hidden.contains($0.id) } }

    var body: some View {
        SideBarHost { vertical in
            VStack(spacing: 0) {
                header
                transcript.readableWidth(760)
                if !vertical { controls }       // 系统竖排工具栏里已有"结束同声传译 / 返回"
            }
            .avoidingFold()
            .background { AuroraBackground() }
        } items: {
            ToolbarItem(placement: .cancellationAction) {
                Button(action: onStop) {
                    BarLabel(session.isEavesdropping ? "结束聆听" : "返回",
                             symbol: session.isEavesdropping ? "stop" : "chevron.left")
                }
            }
        }
        .onAppear {
            hidden = Set(session.turns.filter { $0.kind == .eavesdrop }.map(\.id))
            session.startEavesdrop()
        }
        .onDisappear { session.stopEavesdrop() }
        .sensoryFeedback(.impact(weight: .light), trigger: session.isEavesdropping)       // 开始 / 结束同声传译各一下轻触
    }

    private var header: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Circle().fill(session.isEavesdropping ? Theme.themDot : Theme.warn).frame(width: 8, height: 8)
                Text(session.isEavesdropping ? "正在听 · 只显示译文" : "已停止聆听")
                    .font(Theme.label)
                    .foregroundStyle(session.isEavesdropping ? Theme.themText : Theme.warn)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background((session.isEavesdropping ? Theme.themFill : Theme.warn).opacity(0.16), in: Capsule())

            Text("\(session.them.nativeName) → \(session.me.nativeName)")
                .font(Theme.caption)
                .foregroundStyle(Theme.mut)
        }
        .padding(.top, 12)
        .padding(.bottom, 8)
        .accessibilityElement(children: .combine)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if lines.isEmpty {
                        VStack(spacing: 6) {
                            // 停下来时顶上的状态条已经写着「已停止聆听」：这里不再重复一句「没有在听」
                            if session.isEavesdropping {
                                Text("正在听…")
                                    .font(.system(.headline)).foregroundStyle(Theme.fg)
                                Text("周围人说的话会翻译成\(session.me.nativeName)显示在这里。")
                                    .font(Theme.caption).foregroundStyle(Theme.sub)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 60)
                        .transition(.opacity)
                    }
                    ForEach(lines) { turn in
                        line(turn, isCurrent: turn.id == lines.last?.id).id(turn.id)
                            // 新的一句从下方淡入，但晚 0.15s：上一句从大缩小变淡的那 0.15s 里（两行缩成一行，字号变化是交叉淡化），
                            // 下一句已经在最终位置上，同时出现会和上一句的残影叠在一起。等上一句收好了，新的一句再上浮
                            .transition(reduceMotion ? .opacity
                                        : .asymmetric(insertion: .opacity.combined(with: .offset(y: 10)).animation(.rise.delay(0.15)),
                                                      removal: .opacity))
                    }
                    if let notice = session.notice, !notice.isNoSpeech {
                        Text(text(for: notice))
                            .font(Theme.caption)
                            .foregroundStyle(Theme.err)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)   // 与上面居中的标题对齐，不再各靠一边
                    }
                    if !session.isEavesdropping {
                        // 停下之后不再是死胡同：能重新开始；权限被拒时能直接去系统设置
                        VStack(spacing: 10) {
                            Button { session.startEavesdrop() } label: {
                                Label("重新开始聆听", systemImage: "play.fill")
                                    .font(.system(.subheadline).weight(.semibold))
                                    .foregroundStyle(Theme.fg)
                                    .padding(.horizontal, 20)
                                    .frame(minHeight: 48)
                                    .primaryGlass(in: Capsule())
                            }
                            .buttonStyle(.plain)
                            // 只有权限问题才给「打开系统设置」（识别器没响应这类原因去设置也没用）
                            if let notice = session.notice, notice == .microphoneDenied || notice == .speechDenied {
                                Button("打开系统设置") { PermissionCenter.openSystemSettings() }
                                    .font(.system(.footnote).weight(.semibold))
                                    .foregroundStyle(Theme.fg)
                                    .frame(minHeight: 44)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 12)
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .riseAnimation(value: lines.map(\.id), reduceMotion: reduceMotion)
                .padding(.horizontal, 22)
                .padding(.vertical, 8)
            }
            // 只用一个 onChange：原来 count 和 turns 各一个，后者无动画的 scrollTo 会盖掉前者的平滑滚动（同对话流页）
            .onChange(of: session.turns) { old, new in
                // 只在「多了一句」或「最后一句在变」时贴底；改的是前面的句子（重试翻译、删除）不动位置，也不会让用户读不了前面的内容
                let appended = new.count == old.count + 1 && old.last?.id == new.dropLast().last?.id
                if appended {
                    if reduceMotion { proxy.scrollTo("end", anchor: .bottom) }
                    else { withAnimation(.rise) { proxy.scrollTo("end", anchor: .bottom) } }
                } else if new.last?.id == old.last?.id, new.last != old.last, new.count == old.count {
                    proxy.scrollTo("end", anchor: .bottom)
                }
            }
        }
    }

    @ViewBuilder
    private func line(_ turn: Turn, isCurrent: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let translated = turn.translatedText {
                // 最新的一句：大字、亮白；更早的：小一档、变灰，退到后面（新的一句出现时 0.3s 平滑缩小变淡）
                Text(translated)
                    .font(.system(size: isCurrent ? bigSize : smallSize, weight: isCurrent ? .bold : .medium))
                    .foregroundStyle(isCurrent ? Theme.fg : Theme.sub)
                    .fixedSize(horizontal: false, vertical: true)
                // 原文小字：不超过旧句译文的 0.8 倍（超大字号下两种缩放不同步，原来原文会比译文还大）
                Text(turn.sourceText)
                    .font(.system(size: min(sourceSize, smallSize * 0.8)))
                    .foregroundStyle(Theme.mut)
                    .opacity(isCurrent ? 1 : 0.75)
            } else if case .failed = turn.state {
                // 翻译失败：显示原文 + 一行失败说明 + 重试（原来一直转圈，用户以为还在翻译）
                Text(turn.sourceText).font(.system(.body)).foregroundStyle(Theme.sub)
                Button { session.retryDetached(turn.id) } label: {
                    Label("翻译失败，点按重试", systemImage: "arrow.clockwise")
                        .font(Theme.caption)
                        .foregroundStyle(Theme.err)
                        .frame(minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else if turn.state == .listening {
                // 正在听的这一句：先显示原文
                Text(turn.sourceText.isEmpty ? "…" : turn.sourceText)
                    .font(.system(.title3).weight(.medium))
                    .foregroundStyle(Theme.sub)
                LiveWaveform(session: session, color: Theme.themText)
            } else {
                Text(turn.sourceText).font(.system(.body)).foregroundStyle(Theme.sub)
                ThinkingDots()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(reduceMotion ? .reduced : .smooth(duration: 0.3), value: isCurrent)          // 0.3s：和面对面「上一句缩小」一致
        .accessibilityElement(children: .combine)
    }

    private var controls: some View {
        Button(action: onStop) {
            Label(session.isEavesdropping ? "结束聆听" : "返回", systemImage: session.isEavesdropping ? "stop.fill" : "chevron.left")
                .font(.system(.headline))
                .foregroundStyle(Theme.fg)
                .frame(maxWidth: .infinity, minHeight: 56)
                .glass(in: Capsule(), tint: Theme.themFill, interactive: true)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .readableWidth(480)            // 横屏 / 宽屏上按钮别拉成一整条
    }

    private func text(for notice: Notice) -> LocalizedStringKey {
        switch notice {
        case .microphoneDenied: return "需要麦克风权限才能聆听，请到系统设置里打开。"
        case .speechDenied: return "需要语音识别权限，请到系统设置里打开。"
        case .recognizerUnavailable(let reason): return LocalizedStringKey(reason)
        case .noSpeech: return ""
        }
    }
}

private extension Notice {
    /// "没听到声音"在同声传译页不需要单独提示（页面本身就写着在听）
    var isNoSpeech: Bool {
        if case .noSpeech = self { return true }
        return false
    }
}
