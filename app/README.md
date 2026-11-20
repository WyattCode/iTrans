# X-Trans（iOS）

对话优先的 iOS 翻译 App。

## 构建与运行

需要 Xcode 26+（当前用 Xcode 27.2 验证）和 [XcodeGen](https://github.com/yonaskolb/XcodeGen)。

```bash
cd app
xcodegen generate          # 由 project.yml 生成 XTrans.xcodeproj
open XTrans.xcodeproj      # 或用下面的命令行构建
xcodebuild -project XTrans.xcodeproj -scheme XTrans \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -derivedDataPath build CODE_SIGNING_ALLOWED=NO build
xcodebuild ... test        # 跑单元测试（233 个，包括：状态机、键盘输入、历史存储、旁听、图片文字识别、短语库、设置、语言包、自适应布局）
```

真机运行需要在 Xcode 里给 `XTrans` target 选开发者团队（`DEVELOPMENT_TEAM`）。

## 功能

已有：
- 设计令牌与玻璃材质、面对面上下分屏（M1–M4）、按住 / 轻点麦克风、语言选择；
- 识别 → 翻译 → 朗读的状态机，以及没听清 / 权限被拒 / 无麦克风 / 翻译失败的提示；
- **对话流（T1）**：气泡视图，长按菜单（T2）：播放译文、复制译文 / 原文、修正原文并重译、重新翻译、删除；分享整场对话为文字；
- **键盘输入（K1）**：对方那半屏实时预览译文（防抖 0.6 秒，标注"未发送"），可用朗读开关选择发送后是否朗读；
- **历史（H1）**：SwiftData 存本机，每一轮完成就保存；按天分组；"全部 / 已收藏 / 含图片"筛选；搜索（标题 + 原文 + 译文）；左滑删除、右滑收藏；长按重命名 / 分享 / 删除；点开接着聊、新建对话；
- 手势（都有按钮替代）：控制条上滑 / 点小把手 = 对话流；双击控制条空白处 = 交换语言；左缘右滑 = 历史。

- **加入面板（P1，＋）**：
  - **拍照翻译**（真机）/ **相册图片**：Vision 端侧识别图片里的文字，逐行翻译成我的语言，勾选要用的行，一键放进对话（算对方的一条消息，标"图片文字"）或朗读。相册用系统选择器，**不需要相册权限**；相机在模拟器里置灰。
  - **粘贴文本**：读取剪贴板（点了才读，之前只检查有没有）→ 逐段翻译 → 放进对话。
  - **常用短语（PH）**：SwiftData 存本机；对话里点星标或长按"收藏为短语"，或手动添加；点一下就翻译 + 朗读并写进对话；搜索、置顶、左滑删除。
  - **旁听模式**：持续聆听对方语言的话，只翻译成我的语言显示，**全程不朗读**；权限 / 麦克风出问题会停下来并如实显示。
  - **大字展示（X1）**：译文铺满屏幕给对方看，底部可直接改字，实时重译。M3 / 对话流里每条我的话也能"全屏展示"。

- **设置（S1）/ 离线语言包（S2）/ 首次使用（O1/O2）/ 异常状态（E1–E5）**。语言包下载交给系统界面（框架不开放进度 / 删除）。
- **宽屏双栏**：宽度 ≥ 600pt（Duo 展开、iPad）时，"对话流"变成左对话 + 右工具面板（含常驻短语）。



## 结构

```
XTrans/
  App/                 入口与依赖组装、调试启动参数
  Theme/               Theme（令牌）、AuroraBackground（极光）、Glass（玻璃材质）
  Core/
    ConversationSession   聆听 → 翻译 → 朗读的状态机（只依赖下面三个协议）
    SpeechRecognizer      SpeechRecognizing 协议 + SFSpeechRecognizer 实现
    SpeechSynthesizer     SpeechSpeaking 协议 + AVSpeechSynthesizer 实现
    TranslationEngine     TranslationEngine 协议 + 演示引擎
    AppleTranslationEngine  系统 Translation 框架（经隐藏宿主视图取得会话）
    Language              语言列表与界面文案
    History               HistoryStoring 协议 + SwiftData 模型与实现（含每一轮的来源类型）
    Phrase                常用短语模型与 PhraseLibrary
    TextRecognizer        Vision 文字识别（TextRecognizing 协议 + 实现）
  Features/
    FaceToFace/         首页：HalfView（半屏）、MicButton、ControlStrip、ComposerView（键盘输入）、LanguagePickerSheet
    Stream/             对话流 StreamView（消息、长按菜单、输入栏）
    History/            历史列表 HistoryView
    Add/                加入面板 AddPanelView、逐行翻译 TranslateLinesView（图片 / 粘贴共用）、PhrasesView
    Eavesdrop/          旁听 EavesdropView、大字展示 BigDisplayView
    Root/               RootView：面对面 ⇄ 对话流 ⇄ 旁听切换、历史 / 加入面板、大字展示、左缘手势
XTransTests/           状态机 + 存储单元测试（用假的识别 / 朗读 / 翻译 / 历史；存储用内存容器）
```

## 调试启动参数

| 参数 | 作用 |
|---|---|
| `-XTransDemo m1\|m2\|m3\|m4\|stream` | 直接进入设计稿里对应的静态状态，用于截图对照 |
| `-XTransScreen stream\|history\|compose\|add\|eavesdrop` | 启动后直接打开对话流 / 历史 / 键盘输入 / 加入面板 / 旁听 |
| `-XTransNoHistory` | 历史只放内存，不落盘 |
| `-XTransDemoHistory` | 往历史里放几场示例对话（隐含 `-XTransNoHistory`） |
| `-XTransMock` | 用演示翻译引擎（真机默认用 Apple 翻译） |
| `-XTransApple` | 在模拟器上强制用 Apple 翻译（默认模拟器用演示引擎） |
| `-XTransProbe "文本"` | 启动后翻译一句并把结果打印到标准输出 |
| `-XTransSplash` / `-XTransSplashHold` | 带其他调试参数时也播开屏动画 / 停在开屏最后一帧（平时带调试参数启动不播开屏） |

## 测试须知

- 测试用 iPhone 模拟器跑；**同时开着多台模拟器（iPad / Duo）时，测试偶尔会卡很久**——跑测试前先关掉用不到的模拟器。
- 测试断言失败时，Xcode 对调试 dylib 做符号化可能要好几分钟，看起来像"卡死"：先看是不是某条断言失败了。

## 已知限制（务必知道）

- **系统「翻译」功能在模拟器上不受支持**（系统会弹出提示），Apple 端侧翻译只能在真机上验证，
  需要先在系统里下载语言包。模拟器默认改用演示引擎。
- 这台模拟器**没有音频输入**，语音识别无法在模拟器里端到端测试。
- 授权语音识别时，系统弹窗会写"语音数据将发送给 Apple"——这是系统固定文案；
  代码在语言支持时设置了 `requiresOnDeviceRecognition = true`，此时不会上传，但需要真机确认各语言是否都支持端侧识别。
- iPhone Duo 外屏已验证；内屏（展开后）在模拟器里是黑的，没法直接看。宽屏布局用 iPad mini（744pt 宽，同属宽屏档）验证。
- 界面语言：简体中文 + 英文，跟随系统语言。对话内容本身不翻译界面，也不随系统语言变。
- 控制条上的按钮不是 `Button` 而是点按手势：`Button` 会吞掉父视图的拖动手势，导致从按钮上起手的上滑失效。改回 `Button` 前请先确认这一点。
- 对话流里"我"一侧的麦克风只是继续说话；对方说话仍在面对面里完成。
- **相机实时翻译（C1，译文叠在取景画面上）没有做**：它要持续处理相机帧，只能在真机上调试。现在的"拍照翻译"是拍完再选文字（C2）；译文以列表显示，不叠在图片上。
- 图片文字默认按"对方语言 → 我的语言"翻译；如果图里是我自己的语言，需要先交换语言。
- 模拟器的中文拼音键盘会把逐键输入的英文拼成乱码（测试工具的问题，不是 App 的）。
