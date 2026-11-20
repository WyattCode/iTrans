import XCTest
@testable import XTrans

/// 多语言界面的保障：目录完整、占位符一致，并且界面代码里不能再出现写死的中文。
final class LocalizationTests: XCTestCase {
    // 项目根目录：…/app/XTransTests/LocalizationTests.swift → …/app
    private var appRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    private func loadCatalog(_ name: String) throws -> [String: [String: Any]] {
        let url = appRoot.appendingPathComponent("XTrans/\(name).xcstrings")
        let data = try Data(contentsOf: url)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["sourceLanguage"] as? String, "zh-Hans", "\(name) 的开发语言应该是简体中文")
        return try XCTUnwrap(json["strings"] as? [String: [String: Any]])
    }

    /// 取某语言的所有取值（普通值，或复数变体的 one / other）
    private func values(_ entry: [String: Any], language: String) -> [String] {
        guard let locs = entry["localizations"] as? [String: Any],
              let loc = locs[language] as? [String: Any] else { return [] }
        if let unit = loc["stringUnit"] as? [String: Any], let v = unit["value"] as? String { return [v] }
        if let plural = (loc["variations"] as? [String: Any])?["plural"] as? [String: Any] {
            return ["one", "other"].compactMap { ((plural[$0] as? [String: Any])?["stringUnit"] as? [String: Any])?["value"] as? String }
        }
        return []
    }

    private static let specifier = try! NSRegularExpression(pattern: #"%(?:\d+\$)?[0-9.]*(?:lld|ld|@|d|f|s)"#)

    private func specifiers(in text: String) -> [String] {
        let ns = text as NSString
        return Self.specifier.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) }
    }

    // MARK: 目录完整性

    func testCatalogIsNotEmpty() throws {
        XCTAssertGreaterThan(try loadCatalog("Localizable").count, 150)
    }

    func testEveryKeyHasANonEmptyEnglishTranslation() throws {
        for (key, entry) in try loadCatalog("Localizable") {
            let en = values(entry, language: "en")
            XCTAssertFalse(en.isEmpty, "缺少英文翻译：\(key)")
            for v in en { XCTAssertFalse(v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "英文翻译为空：\(key)") }
        }
    }

    /// 界面语言里除了英文之外的三种：每条都要有、不能空、占位符个数和原文一致
    func testEveryKeyIsTranslatedIntoTraditionalChineseJapaneseAndKorean() throws {
        for (key, entry) in try loadCatalog("Localizable") {
            for language in ["zh-Hant", "ja", "ko"] {
                let translated = values(entry, language: language)
                XCTAssertEqual(translated.count, 1, "缺少 \(language) 翻译：\(key)")
                for v in translated {
                    XCTAssertFalse(v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "\(language) 翻译为空：\(key)")
                    XCTAssertEqual(specifiers(in: v).count, specifiers(in: key).count, "\(language) 占位符数量不一致：\(key) → \(v)")
                }
            }
        }
        for (key, entry) in try loadCatalog("InfoPlist") {
            for language in ["zh-Hant", "ja", "ko"] {
                XCTAssertEqual(values(entry, language: language).count, 1, "权限说明缺少 \(language) 翻译：\(key)")
            }
        }
    }

    /// 设置里手动选的界面语言：`String(localized:)` 立刻从那种语言里取，选回「跟随系统」也能取到
    func testStringLocalizedFollowsTheSelectedAppLanguage() {
        let state = AppLanguageState.shared
        let before = state.selection
        defer { state.selection = before }
        let expected: [AppLanguage: String] = [.zhHans: "设置", .zhHant: "設定", .en: "Settings", .ja: "設定", .ko: "설정"]
        for (language, text) in expected {
            state.selection = language
            XCTAssertEqual(String(localized: "设置"), text, "\(language.rawValue)")
            XCTAssertEqual(state.code, language.rawValue)
        }
        state.selection = .ja
        XCTAssertEqual(String(localized: "\(3) 条消息"), "3件のメッセージ", "带数字的也要走选中的语言")
        state.selection = .system
        XCTAssertTrue(expected.values.contains(String(localized: "设置")))
        XCTAssertEqual(Set(AppLanguage.allCases.map(\.title)).count, AppLanguage.allCases.count, "每种语言的名字不能重复")
    }

    func testAppLanguageSettingIsPersistedAndSurvivesReset() {
        let before = AppLanguageState.shared.selection
        defer { AppLanguageState.shared.selection = before }
        let name = "applang-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.appLanguage, .system)
        settings.appLanguage = .ko
        XCTAssertEqual(AppLanguageState.shared.selection, .ko)
        XCTAssertEqual(AppSettings(defaults: defaults).appLanguage, .ko)
        settings.resetToDefaults()
        XCTAssertEqual(settings.appLanguage, .ko, "恢复默认设置不改界面语言")
        XCTAssertNil(defaults.persistentDomain(forName: name)?["AppleLanguages"], "临时设置不写系统语言偏好")
    }

    func testPlaceholdersMatchBetweenSourceAndEnglish() throws {
        for (key, entry) in try loadCatalog("Localizable") {
            // 键里的占位符是源语言的；中文显式值（如语言简称）没有占位符，跳过
            let expected = specifiers(in: key).count
            for v in values(entry, language: "en") {
                XCTAssertEqual(specifiers(in: v).count, expected,
                               "占位符数量不一致：\(key) → \(v)")
            }
        }
    }

    func testNumberedPlaceholdersCoverEachPositionOnce() throws {
        for (key, entry) in try loadCatalog("Localizable") {
            for v in values(entry, language: "en") {
                let specs = specifiers(in: v)
                guard specs.count > 1, specs.contains(where: { $0.contains("$") }) else { continue }
                let positions = specs.compactMap { Int($0.dropFirst().split(separator: "$").first ?? "") }.sorted()
                XCTAssertEqual(positions, Array(1...specs.count), "多个占位符应该用 %1$@ 这种位置写法并且各出现一次：\(key) → \(v)")
            }
        }
    }

    func testPluralKeysHaveOneAndOther() throws {
        let catalog = try loadCatalog("Localizable")
        let pluralKeys = catalog.filter { (($0.value["localizations"] as? [String: Any])?["en"] as? [String: Any])?["variations"] != nil }
        XCTAssertGreaterThanOrEqual(pluralKeys.count, 3, "至少「N 条消息」「N 个已下载」两类带数量的文案要有复数变体")
        for (key, entry) in pluralKeys {
            XCTAssertEqual(values(entry, language: "en").count, 2, "复数变体需要 one 和 other：\(key)")
        }
    }

    func testLanguageShortNamesHaveExplicitChineseAndEnglish() throws {
        let catalog = try loadCatalog("Localizable")
        for (key, zh, en) in [("语言简称：中文", "中", "ZH"), ("语言简称：日语", "日", "JA"), ("语言简称：韩语", "韩", "KO")] {
            let entry = try XCTUnwrap(catalog[key], key)
            XCTAssertEqual(values(entry, language: "zh-Hans"), [zh], "中文界面下必须显示最终的简称，不能把键本身显示出来")
            XCTAssertEqual(values(entry, language: "en"), [en])
        }
    }

    func testInfoPlistCatalogCoversPermissionDescriptions() throws {
        let catalog = try loadCatalog("InfoPlist")
        for key in ["NSMicrophoneUsageDescription", "NSSpeechRecognitionUsageDescription", "NSCameraUsageDescription"] {
            let entry = try XCTUnwrap(catalog[key], key)
            XCTAssertFalse(values(entry, language: "zh-Hans").isEmpty, "\(key) 缺中文")
            XCTAssertFalse(values(entry, language: "en").isEmpty, "\(key) 缺英文")
        }
    }

    // MARK: 防回退：界面代码里不能再出现写死的中文

    /// 这些中文是"内容"而不是"界面文案"，不随系统语言变：演示数据、模拟引擎的短语本、语言自己的名字、
    /// 按"屏幕主人语言"显示的每半屏提示（Strings）、Xcode 预览名。
    private static let contentLiterals: Set<String> = [
        "请问最近的地铁站怎么走？", "我对花生过敏", "可以便宜一点吗？", "请再说一遍", "多少钱？", "哪里可以买票？",
        "你好！欢迎来到东京。", "下一站是涩谷。请注意站台间隙。", "左侧车门将会打开。", "请问最近的地铁站怎么走", "一直往前走，然后在红绿灯左转。", "一次 180 日元。", "我在车站东口等你",
        "打扰一下，我想办理入住。我用陈这个名字订了三晚的房间。请问早餐几点开始？另外，可以延迟退房吗？我的航班在晚上六点起飞。非常感谢。",   // 长译文演示（-XTransDemo long）
        "谢谢！", "中文", "日本語", "M1 待机", "M3 译文已出",
        "轻点麦克风，开始说话", "译文会显示在这里", "自动识别你和对方的语言，也可以按住说话。", "正在聆听 · ", "正在聆听", "朗读中…", "对方正在说话…",
        "再说一次", "用键盘", "预览 · 未发送", "按住说话",
        "酱油拉面 900 日元", "拉面店菜单",       // 历史页演示数据
        "你好，很高兴认识你。",
        "餃子（6個）  ¥450", "生ビール  ¥600", "本日のおすすめ  ¥1,100",   // 调试用的日文菜单图片（DemoImages）
        "D1 帐篷", "没听清 · 轻点重说", "请问最近的地铁站怎么走？我想去机场，需要换乘吗？大概要多长时间？",                                                       // Xcode 预览名                  // 选朗读声音时的试听句（该语言自己的内容）
    ]

    private static func normalizedKey(_ key: String) -> String {
        let noSpecifiers = specifier.stringByReplacingMatches(in: key, range: NSRange(location: 0, length: (key as NSString).length), withTemplate: "")
        return noSpecifiers.replacingOccurrences(of: "\n", with: "").replacingOccurrences(of: " ", with: "")
    }

    /// 取出一行里所有字符串字面量；插值 `\( … )`（可以嵌套括号和字符串）整体丢掉。
    private func literals(in line: String) -> [String] {
        let chars = Array(line)
        var result: [String] = []
        var i = 0
        while i < chars.count {
            if chars[i] == "/" && i + 1 < chars.count && chars[i + 1] == "/" { break }      // 行内注释
            guard chars[i] == "\"" else { i += 1; continue }
            var text = ""
            i += 1
            while i < chars.count, chars[i] != "\"" {
                if chars[i] == "\\", i + 1 < chars.count {
                    if chars[i + 1] == "(" {                       // 插值：跳到配对的右括号
                        var depth = 1
                        i += 2
                        while i < chars.count, depth > 0 {
                            if chars[i] == "(" { depth += 1 } else if chars[i] == ")" { depth -= 1 }
                            else if chars[i] == "\"" { i += 1; while i < chars.count, chars[i] != "\"" { i += 1 } }
                            i += 1
                        }
                        continue
                    }
                    text.append(chars[i + 1] == "n" ? "\n" : chars[i + 1])
                    i += 2
                    continue
                }
                text.append(chars[i]); i += 1
            }
            i += 1
            result.append(text)
        }
        return result
    }

    /// 扫一段源码，返回所有"不在目录里、也不在内容白名单里"的中文字面量。
    private func offenders(in text: String, fileName: String, catalogKeys: Set<String>) throws -> [String] {
        let allowed = Set(Self.contentLiterals.map(Self.normalizedKey))
        let cjk = try NSRegularExpression(pattern: "[\u{4e00}-\u{9fff}]")
        var found: [String] = []
        for (index, line) in text.components(separatedBy: "\n").enumerated() {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("//") { continue }
            for lit in literals(in: line) {
                let ns = lit as NSString
                guard cjk.firstMatch(in: lit, range: NSRange(location: 0, length: ns.length)) != nil else { continue }
                // 带假名的是日语（半屏提示语按对方语言写，见 `Strings`），不是写死的中文界面文案
                if lit.unicodeScalars.contains(where: { (0x3040...0x30ff).contains($0.value) }) { continue }
                let key = Self.normalizedKey(lit)
                if catalogKeys.contains(key) || allowed.contains(key) { continue }
                found.append("\(fileName):\(index + 1)  “\(lit)”")
            }
        }
        return found
    }

    func testNoHardCodedChineseUIStringsOutsideTheCatalog() throws {
        let catalogKeys = Set(try loadCatalog("Localizable").keys.map(Self.normalizedKey))
        let root = appRoot.appendingPathComponent("XTrans")
        let files = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        var found: [String] = []
        var scanned = 0
        for case let url as URL in files where url.pathExtension == "swift" {
            scanned += 1
            found += try offenders(in: String(contentsOf: url, encoding: .utf8), fileName: url.lastPathComponent, catalogKeys: catalogKeys)
        }
        XCTAssertGreaterThan(scanned, 20, "没有扫描到源码，路径可能不对")
        XCTAssertTrue(found.isEmpty, "这些中文字符串不在字符串目录里，也不在“内容”白名单里（界面文案请用 Text(\"…\") / String(localized:)）：\n" + found.joined(separator: "\n"))
    }

    // 扫描器自己的测试：证明它真的会抓到写死的中文，而不是"什么都没扫到所以通过"

    func testScannerFlagsAHardCodedChineseLiteral() throws {
        let keys = Set(try loadCatalog("Localizable").keys.map(Self.normalizedKey))
        let source = """
        Text("取消")
        let bad = "这是一句写死的话"
        Button("某个没有翻译过的按钮") { }
        """
        let found = try offenders(in: source, fileName: "Fake.swift", catalogKeys: keys)
        XCTAssertEqual(found.count, 2, "应该抓到 2 处：\(found)")
        XCTAssertTrue(found.contains { $0.contains("这是一句写死的话") })
        XCTAssertTrue(found.contains { $0.contains("某个没有翻译过的按钮") })
        XCTAssertFalse(found.contains { $0.contains("取消") }, "目录里有的键不应该被报")
    }

    func testScannerHandlesInterpolationAndNestedQuotes() throws {
        let keys = Set(try loadCatalog("Localizable").keys.map(Self.normalizedKey))
        let source = #"""
        Text("\(settings.silenceTimeout, specifier: "%.1f") 秒")
        Text("\(name) 还没有下载")
        let x = "\(a ? "对" : "错") 未收录的句子"
        """#
        let found = try offenders(in: source, fileName: "Fake.swift", catalogKeys: keys)
        XCTAssertEqual(found.count, 1, "只有最后一行是未收录的：\(found)")
        XCTAssertTrue(found[0].contains("未收录的句子"))
    }

    func testScannerIgnoresCommentsAndNonChineseLiterals() throws {
        let source = """
        // "注释里的中文不算"
        let a = "plain english" // 行尾注释里的中文 "也不算"
        /// 文档注释 "不算"
        """
        let found = try offenders(in: source, fileName: "Fake.swift", catalogKeys: [])
        XCTAssertTrue(found.isEmpty, "\(found)")
    }

    // MARK: 引擎显示名

    func testEngineDisplayNamesAreResolvedFromStableIdentifiers() {
        XCTAssertEqual(EngineDisplay.name(for: EngineDisplay.appleID), String(localized: "Apple 端侧"))
        XCTAssertEqual(EngineDisplay.name(for: EngineDisplay.demoID), String(localized: "演示引擎"))
    }

    func testLegacyChineseEngineNamesStoredInOldHistoryStillMapToDisplayNames() {
        XCTAssertEqual(EngineDisplay.name(for: "Apple 端侧"), EngineDisplay.name(for: EngineDisplay.appleID))
        XCTAssertEqual(EngineDisplay.name(for: "演示引擎"), EngineDisplay.name(for: EngineDisplay.demoID))
    }

    func testUnknownEngineNamesAreShownAsIs() {
        XCTAssertEqual(EngineDisplay.name(for: "MyAI"), "MyAI")
    }

    @MainActor
    func testEnginesStoreStableIdentifiersNotDisplayNames() {
        XCTAssertEqual(MockTranslationEngine().name, "demo")
        XCTAssertEqual(AppleTranslationEngine().name, "apple")
    }
}
