import SwiftUI

/// S2 · 离线语言包：每种语言的状态，以及下载入口。
/// 系统 Translation 框架不开放下载进度、体积和删除：下载由系统弹出自己的界面完成，
/// 已下载的语言要到系统设置里管理——这里如实说明，不画假的进度条。
struct LanguagePacksView: View {
    let packs: LanguagePackStore
    /// 宽屏的设置页自己画了居中的标题，这里不再设系统标题（否则 Duo 竖排栏模式下会跑到屏幕左上角）
    var showsTitle = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 长按页脚说明 → 诊断页：系统对每种语言的原始回答
    @State private var showingDiagnostics = false

    var body: some View {
        List {
            let installed = LanguageOption.all.filter { packs.status(of: $0) == .installed }
            let downloadable = LanguageOption.all.filter { packs.status(of: $0) == .downloadable }
            let unknown = LanguageOption.all.filter { packs.status(of: $0) == .unknown }

            if let language = packs.downloadingLanguage {
                // 正在下载：说明在做什么、要用户做什么，以及为什么别的「下载」点不了
                Section {
                    HStack(spacing: 12) {
                        Image(systemName: "arrow.down.circle").font(.title3).foregroundStyle(Theme.fg)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("正在下载 \(language.nativeName)").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.fg)
                            Text("请在系统弹出的窗口里确认。下载完成前不能同时下载别的。").font(Theme.caption).foregroundStyle(Theme.sub)
                        }
                    }
                    .frame(minHeight: 44)
                    .accessibilityElement(children: .combine)
                    .transition(.opacity)
                }
                .listRowBackground(CardRowBackground())
            }

            if !installed.isEmpty {
                Section("已下载") {
                    ForEach(installed) { language in
                        HStack {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.ok)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(language.nativeName).foregroundStyle(Theme.fg)
                                Text(packs.justInstalled == language.id ? "离线翻译 · 刚下载好" : "离线翻译")
                                    .font(Theme.caption).foregroundStyle(Theme.mut)
                            }
                        }
                        .frame(minHeight: 44)
                        .accessibilityElement(children: .combine)
                        // 刚下载好的那一行绿色高亮 1.5 秒（逐行设背景，高亮只落在它自己身上）
                        .listRowBackground(CardRowBackground().overlay(Theme.ok.opacity(packs.justInstalled == language.id ? 0.16 : 0)))
                    }
                }
            }

            if !downloadable.isEmpty {
                Section("可下载") {
                    ForEach(downloadable) { language in
                        HStack {
                            Text(language.nativeName).foregroundStyle(Theme.fg)
                            Spacer()
                            // 按钮 ⇄ 菊花：同一个宽度、同一个位置淡入淡出，不跳（原来是硬切，宽度也不一样）
                            ZStack {
                                if packs.downloading.contains(language.id) {
                                    ProgressView()
                                        .accessibilityLabel("正在下载")
                                        .transition(.opacity)
                                } else {
                                    Button("下载") { Task { await packs.download(language) } }
                                        .font(.system(.footnote).weight(.semibold))
                                        .buttonStyle(.bordered)
                                        .controlSize(.large)
                                        .tint(Theme.fg)
                                        .disabled(packs.isDownloading)          // 同一时间只下载一种：别的按钮灰着（禁用自带变淡，不再叠一层透明度）
                                        .transition(.opacity)
                                }
                            }
                            .frame(width: 76, height: 40)
                            .animation(reduceMotion ? .reduced : .easeInOut(duration: 0.2), value: packs.downloading)
                            .animation(reduceMotion ? .reduced : .easeInOut(duration: 0.2), value: packs.isDownloading)
                        }
                        .frame(minHeight: 44)
                    }
                }
                .listRowBackground(CardRowBackground())
            }

            if !unknown.isEmpty && installed.isEmpty && downloadable.isEmpty {
                Section { HStack { ProgressView(); Text("正在检查…").foregroundStyle(Theme.sub) } }
                    .listRowBackground(CardRowBackground())
            }

            Section {
                if let error = packs.lastError {
                    Label(error, systemImage: "exclamationmark.triangle").font(Theme.caption).foregroundStyle(Theme.err)
                }
            } footer: {
                Text("点“下载”后，系统会弹出自己的下载界面。已下载的语言包由系统管理，需要删除时请到「设置 → App → 翻译 → 已下载的语言」里操作。语言包用于离线翻译；语音识别优先在设备上完成，如果系统没有这种语言的离线语音，会改为联网识别。")
                    .onLongPressGesture(minimumDuration: 1.0) { showingDiagnostics = true }
            }
            .listRowBackground(CardRowBackground())
        }
        .scrollContentBackground(.hidden)
        .duoListInset()
        .background { PageBackground() }
        .navigationTitle(showsTitle ? LocalizedStringKey("离线语言包") : "")
        .navigationBarTitleDisplayMode(.inline)
        // 状态变了（下载中 / 下载好）：行在分组之间滑过去，不是瞬间消失 / 出现
        .animation(reduceMotion ? .reduced : .smooth(duration: 0.35), value: packs.statuses)
        .animation(reduceMotion ? .reduced : .smooth(duration: 0.3), value: packs.downloadingLanguage?.id)
        .task { await packs.refresh() }
        .refreshable { await packs.refresh() }
        .sheet(isPresented: $showingDiagnostics) { PackDiagnosticsSheet(packs: packs) { showingDiagnostics = false } }
    }
}

/// 语言包诊断：系统对每种语言的原始回答。数据由弹层自己加载（原来在长按后加载再传进来，弹层拿到的是空的）。
private struct PackDiagnosticsSheet: View {
    let packs: LanguagePackStore
    let onDone: () -> Void
    @State private var lines: [String]?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("系统对每种语言的原始回答（用于排查「系统里没装、这里却显示已下载」）。每种语言问两个方向，两个方向都是 installed 才显示已下载。")
                        .font(Theme.caption).foregroundStyle(Theme.sub)
                    if let lines {
                        Text(verbatim: "\(lines.count) entries")
                            .font(.system(.footnote, design: .monospaced)).foregroundStyle(Theme.mut)
                        ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                            Text(verbatim: line)
                                .font(.system(.footnote, design: .monospaced))
                                .foregroundStyle(Theme.fg)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                    } else {
                        HStack(spacing: 10) { ProgressView(); Text(verbatim: "querying…").foregroundStyle(Theme.sub) }
                    }
                }
                .padding(20)
            }
            .background { PageBackground() }
            .navigationTitle("语言包诊断")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(item: (lines ?? []).joined(separator: "\n")) { Text("拷贝") }
                        .disabled(lines == nil)
                }
                DoneToolbarItem(action: onDone)
            }
            .task { lines = await packs.diagnosticLines() }
        }
    }
}
