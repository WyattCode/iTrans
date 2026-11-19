import PhotosUI
import SwiftUI
import AVFoundation
import UIKit

/// 加入面板（＋）：把"别的东西"带进对话——拍照、相册、短语、粘贴、同声传译、大字展示。
/// 做完的结果都以"消息"的形式留在对话里。
struct AddPanelView: View {
    enum Exit { case eavesdrop, bigDisplay }

    let session: ConversationSession
    /// 内嵌在宽屏的右栏里（不是弹出的面板）：没有"完成"，做完回到磁贴页而不是关闭。
    var embedded = false
    /// 内嵌时给一个关闭动作 = 标题行右边出现「完成」（Duo 内屏横向：左屏对话、右屏加入面板，整屏盖上的那种）
    var onClose: (() -> Void)?
    /// 作为屏内导航栈（Duo 内屏右屏）推进来的页面：不再自己包一层 NavigationStack
    var inOuterStack = false
    /// 面板里推进了子页（短语 / 图片 / 粘贴）时通知外层：左缘右划只退一级，不关整个面板
    var onSubpage: ((Bool) -> Void)?
    /// 关闭面板后要去的地方（同声传译 / 大字展示要整页接管，不适合放在面板里）。
    let onExit: (Exit) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.inDuoPane) private var inDuoPane
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    /// 宽屏（Duo 内屏 / iPad）：表单卡片很高，磁贴下面接着放常用短语，点一下就说（和内嵌的工具面板一样）。表单卡片自己的尺寸类是 compact，所以按窗口判断
    private var showsPhrasesBelow: Bool { ((embedded && !inDuoPane) || LayoutClass.forWindow(fallback: .zero) == .wide) && !dynamicTypeSize.isAccessibilitySize }
    @State private var pickerItem: PhotosPickerItem?
    @State private var showingCamera = false
    @State private var pickedImage: UIImage?
    @State private var imageKind: ImageSource = .photoLibrary
    @State private var showPhoto = false
    /// 宽屏：拍 / 选了图之后，左边大图、右边文字列表（D6）
    @State private var showPhotoSplit = false
    @State private var showPhrases = false
    @State private var pasteLines: [String] = []
    @State private var showPaste = false
    @State private var message: LocalizedStringKey?
    @State private var flashTask: Task<Void, Never>?
    @State private var cameraDenied = false
    /// 相册选的图正在读取（iCloud 上的大图要几秒）：磁贴上转圈，别让用户以为没选上
    @State private var loadingImage = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var detent: PresentationDetent = .fraction(0.58)
    @State private var clipboardHasText = UIPasteboard.general.hasStrings
    @Environment(\.scenePhase) private var scenePhase

    enum ImageSource { case camera, photoLibrary }

    /// 磁贴的最小宽度和间距。列数按可用宽度自适应：竖屏 iPhone 的面板放 3 列，Duo 展开后的右栏（约 300pt）放 2 列。
    static let tileMinWidth: CGFloat = 96
    static let tileSpacing: CGFloat = 10
    static let panelPadding: CGFloat = 16
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var columns: [GridItem] {
        // 超大字号下磁贴里的字放不下，改成每行一个
        if dynamicTypeSize >= .accessibility1 { return [GridItem(.flexible())] }
        // 宽屏右栏（约 389pt）正好放 3 列 112pt 的磁贴；其余按可用宽度自适应
        // 内嵌的工具面板（Duo）固定 3 列 × 2 行：横向右屏约 370pt、竖向下屏 669pt 都是这个排法
        if embedded { return Array(repeating: GridItem(.flexible(maximum: 200), spacing: 12), count: 3) }
        // 弹出的面板（直板竖 / 横、Duo 外屏）也固定 3 列 × 2 行：自适应列数在 678pt 宽的外屏横放时会排成 5 + 1
        return Array(repeating: GridItem(.flexible(maximum: 170), spacing: Self.tileSpacing), count: 3)
    }

    @ViewBuilder
    private func stack<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        if inOuterStack { content() } else { NavigationStack { content() } }
    }

    var body: some View {
        stack {
            VStack(spacing: 0) {
                if embedded {
                    // 宽屏右栏自己写标题，不占用导航栏（整屏的系统工具栏在最右侧竖排）。高 64，和左栏页头同一条线。
                    if let onClose {
                        PaneHeader(title: "加入对话", onBack: onClose)
                    } else {
                        HStack {
                            Text("工具")
                                .font(.system(.headline))
                                .foregroundStyle(Theme.fg)
                                .accessibilityAddTraits(.isHeader)
                            Spacer()
                        }
                        .frame(maxWidth: .infinity, minHeight: 64)
                        .padding(.horizontal, 20)
                    }
                }
                tilesScroll
                    .frame(maxHeight: showsPhrasesBelow ? 270 : .infinity)
                    .layoutPriority(1)                                // 竖向下屏较矮时，让短语列表去滚动，别压扁磁贴
                if showsPhrasesBelow {
                    // 宽屏：短语常驻在工具面板下方，点一下就说，结果出现在左边的对话里
                    Divider().padding(.horizontal, 20)
                    HStack {
                        Text("常用短语")
                            .font(.system(.footnote).weight(.semibold))
                            .foregroundStyle(Theme.mut)
                        Spacer()
                        Button { showPhrases = true } label: {
                            Text("管理")
                                .font(.system(.footnote).weight(.semibold))
                                .foregroundStyle(Theme.fg)      // 文字不用粉红（用户不喜欢），只有图标 / 填充用粉红
                                .frame(minWidth: 44, minHeight: 44, alignment: .trailing)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 4)
                    PhrasesList(session: session, embedded: true) { finish() }
                }
            }
            .background { PageBackground() }
            .containerBackground(.clear, for: .navigation)
            .navigationTitle(embedded ? "" : "加入对话")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarVisibility(embedded ? .hidden : .automatic, for: .navigationBar)
            .toolbar {
                if !embedded {
                    DoneToolbarItem { finish() }
                }
            }
            .navigationDestination(isPresented: $showPhrases) {
                PhrasesView(session: session) { finish() }
            }
            .navigationDestination(isPresented: $showPhoto) {
                if let pickedImage {
                    TranslateLinesView(session: session, source: .image(pickedImage),
                                       title: imageKind == .camera ? "拍照翻译" : "图片文字") { finish() }
                }
            }
            .navigationDestination(isPresented: $showPaste) {
                TranslateLinesView(session: session, source: .lines(pasteLines), title: "粘贴文本") { finish() }
            }
        }
        // 窄屏（直板）是半屏弹层；regular（Duo 内屏）是屏幕正中的表单卡片，不用 detent
        .sheetDetents([.fraction(0.58), .large], selection: $detent)          // 默认高度 58% 屏高（先 55%、+5%、+10% 到 65%，再下移 3% 到 62%、再 3% 到 59%、再 1% 到 58%）
        // 进入子页面（短语 / 图片 / 粘贴）时自动展开，给列表足够的空间
        .onChange(of: showPhrases) { _, on in if on { detent = .large }; onSubpage?(showPhrases || showPhoto || showPaste) }
        .onChange(of: showPhoto) { _, on in if on { detent = .large }; onSubpage?(showPhrases || showPhoto || showPaste) }
        .onChange(of: showPaste) { _, on in if on { detent = .large }; onSubpage?(showPhrases || showPhoto || showPaste) }
        .fullScreenCover(isPresented: $showingCamera) {
            CameraPicker { image in
                showingCamera = false
                if let image { open(image, from: .camera) }
            }
            .ignoresSafeArea()
            .preferredColorScheme(colorScheme)
        }
        .alert("需要相机权限", isPresented: $cameraDenied) {
            Button("打开系统设置") { PermissionCenter.openSystemSettings() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("请到系统设置里允许 iTrans 使用相机，才能拍照翻译。")
        }
        // 去别的 App 复制了文字再回来：重新检查剪贴板
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { clipboardHasText = UIPasteboard.general.hasStrings }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIPasteboard.changedNotification)) { _ in
            clipboardHasText = UIPasteboard.general.hasStrings
        }
        // 识别完回到磁贴页：不再留着整张原图
        // 等退场动画走完再丢：马上置空的话，页面还在滑出去，内容已经没了（空白页滑出）
        .onChange(of: showPhoto) { _, on in if !on { releaseImageSoon() } }
        .onChange(of: showPhotoSplit) { _, on in if !on { releaseImageSoon() } }
        .fullScreenCover(isPresented: $showPhotoSplit) {
            if let pickedImage {
                PhotoSplitView(image: pickedImage, session: session,
                               title: imageKind == .camera ? "拍照翻译" : "图片文字") {
                    showPhotoSplit = false
                    finish()
                } onClose: { showPhotoSplit = false }
                .preferredColorScheme(colorScheme)      // 整屏盖上的页面不继承 App 设的外观
            }
        }
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            loadingImage = true
            Task {
                defer { pickerItem = nil; loadingImage = false }
                if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                    open(image, from: .photoLibrary)
                } else {
                    flash("这张图片读取失败，换一张试试。")
                }
            }
        }
    }

    private var tilesScroll: some View {
        ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    LazyVGrid(columns: columns, spacing: Self.tileSpacing) {
                        cameraTile
                        photosTile
                        tile("book", "常用短语", "一点即说") { showPhrases = true }
                        pasteTile
                        tile("ear", "只听不说", "边听边看译文") { onExit(.eavesdrop); finish() }
                        tile("arrow.up.left.and.arrow.down.right", "大字展示", "写给对方看") { onExit(.bigDisplay); finish() }
                    }

                    if let message {
                        Label(message, systemImage: "info.circle")
                            .font(Theme.caption)
                            .foregroundStyle(Theme.sub)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .glass(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .transition(.opacity)
                    }
                }
                .animation(reduceMotion ? .reduced : .easeInOut(duration: 0.2), value: message != nil)
                .padding(.horizontal, embedded ? 20 : Self.panelPadding)          // 内嵌时和页头 / 分隔线 / 短语列表同一条 20pt 边（原来磁贴比下面的短语宽 12pt）
                .padding(.vertical, embedded ? 8 : Self.panelPadding)
            }
    }

    // MARK: 入口

    private var cameraTile: some View {
        let available = CameraPicker.isAvailable
        return tile("camera", "拍照翻译", available ? "拍下来识别" : "此设备无相机", enabled: available) {
            // 权限被拒时系统相机只给一个黑取景框、没有任何说明：先查权限，被拒就说清楚并给去设置的入口
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized: showingCamera = true
            case .notDetermined:
                Task { @MainActor in
                    if await AVCaptureDevice.requestAccess(for: .video) { showingCamera = true } else { cameraDenied = true }
                }
            default: cameraDenied = true
            }
        }
    }

    private var photosTile: some View {
        PhotosPicker(selection: $pickerItem, matching: .images) {
            tileLabel("photo", "相册图片", loadingImage ? "正在读取…" : "选图识别")
                .overlay(alignment: .topTrailing) { if loadingImage { ProgressView().controlSize(.small).padding(10) } }
        }
        .buttonStyle(TilePressStyle())
        .disabled(loadingImage)
    }

    private var pasteTile: some View {
        let has = clipboardHasText    // 只检查有没有，不读内容，不会触发"粘贴"提示
        return tile("doc.on.clipboard", "粘贴文本", has ? "剪贴板有内容" : "剪贴板是空的", enabled: has) {
            // 点下去才真正读取内容
            let lines = (UIPasteboard.general.string ?? "")
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            if lines.isEmpty {
                flash("剪贴板里没有可翻译的文字。")
            } else {
                pasteLines = lines
                showPaste = true
            }
        }
    }

    /// 弹出面板：关闭；内嵌在右栏：退回磁贴页（对话就在左边，不用关）。
    private func finish() {
        if embedded {
            showPhrases = false
            showPhoto = false
            showPaste = false
        } else {
            dismiss()
        }
    }

    /// 提示一条消息，几秒后自己收掉（原来一直留着，而且在内嵌面板里被 270pt 的磁贴区截掉大半）
    private func flash(_ text: LocalizedStringKey) {
        message = text
        flashTask?.cancel()          // 连着提示两条：前一条的计时器不能把后一条提前收掉
        flashTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            message = nil
        }
    }

    private func releaseImageSoon() {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(600))
            if !showPhoto, !showPhotoSplit { pickedImage = nil }
        }
    }

    private func open(_ image: UIImage, from source: ImageSource) {
        pickedImage = image
        imageKind = source
        // 左右分栏的图片页只给没有折痕的宽屏（iPad）：Duo 内屏上它是整屏盖上、图片和文字列表都跨过折痕。
        // Duo 的屏里和直板一样作为一页推进右屏（原图在上、文字列表在下），不跨折痕、动画和别的子页一样
        if embedded && !inDuoPane { showPhotoSplit = true } else { showPhoto = true }
    }

    // MARK: 磁贴

    private func tile(_ symbol: String, _ title: LocalizedStringKey, _ subtitle: LocalizedStringKey, enabled: Bool = true,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) { tileLabel(symbol, title, subtitle) }
            .buttonStyle(TilePressStyle())
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.45)
    }

    private func tileLabel(_ symbol: String, _ title: LocalizedStringKey, _ subtitle: LocalizedStringKey) -> some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 28))
                .foregroundStyle(Theme.meText)
                .frame(height: 34)
            Text(title)
                .font(.system(.subheadline).weight(.semibold))
                .foregroundStyle(Theme.fg)
            Text(subtitle)
                .font(.system(.caption))
                .foregroundStyle(Theme.mut)
                .lineLimit(2)                      // 英文副标题（Write for your partner）一行放不下：允许折两行，不截成「…」
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, minHeight: 112)
        .padding(.horizontal, 4)
        // 统一的实底：不用玻璃采样背景（采样会让靠近极光亮处的磁贴颜色不一样，像是"第一块被选中了"）
        .background(reduceTransparency ? AnyShapeStyle(Theme.fg.opacity(0.12)) : AnyShapeStyle(Theme.glassFill), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Theme.glassBorder, lineWidth: 0.5))
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - 相机（真机才有）

struct CameraPicker: UIViewControllerRepresentable {
    static var isAvailable: Bool { UIImagePickerController.isSourceTypeAvailable(.camera) }

    let onFinish: (UIImage?) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onFinish: (UIImage?) -> Void
        init(onFinish: @escaping (UIImage?) -> Void) { self.onFinish = onFinish }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            onFinish(info[.originalImage] as? UIImage)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { onFinish(nil) }
    }
}

// MARK: - D6 · 图片 / 相机（宽屏）：左边大图，右边识别和译文

/// 左屏看图，右屏同步列出识别到的文字和译文：不遮挡画面，对照着看更清楚。
struct PhotoSplitView: View {
    let image: UIImage
    let session: ConversationSession
    let title: LocalizedStringKey
    let onSent: () -> Void
    let onClose: () -> Void
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                imagePane
                NavigationStack {
                    TranslateLinesView(session: session, source: .image(image), title: title,
                                       onSent: onSent, showsImage: false)
                }
                .frame(width: min(360, geo.size.width * 0.55))      // 再窄的屏幕也给列表留出够用的宽度
            }
        }
        // 整屏盖上的页面必须自己有不透明的底：右栏的导航栈是透明的，不铺底的话下面的加入面板 / 对话会透出来（两个标题叠在一起）
        .background { AuroraBackground().ignoresSafeArea() }
        .background(Color.black.ignoresSafeArea())
    }

    private var imagePane: some View {
            ZStack(alignment: .topLeading) {
                Color.black.ignoresSafeArea()
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityHidden(true)
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 16, weight: .semibold))
                        // 降低透明度时玻璃变成实色底（浅色下近白），白叉看不见
                        .foregroundStyle(reduceTransparency ? Theme.fg : .white)
                        .frame(width: 44, height: 44)
                        .glass(in: Circle())
                }
                .padding(16)
                .accessibilityLabel("关闭")
            }
            .frame(maxWidth: .infinity)
    }
}


/// 磁贴按下：缩到 96%（0.12 秒缓出），松手弹回。
struct TilePressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

