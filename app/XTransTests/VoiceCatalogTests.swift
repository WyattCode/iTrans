import XCTest
@testable import XTrans

final class VoiceCatalogTests: XCTestCase {
    private func voice(_ id: String, _ lang: String, _ q: VoiceChoice.Quality = .standard, name: String? = nil) -> VoiceChoice {
        VoiceChoice(id: id, name: name ?? id, language: lang, quality: q, gender: .unspecified)
    }

    func testChoicesFilterAndOrder() {
        let all = [voice("a", "en-GB", .standard), voice("b", "en-US", .premium), voice("c", "en-US", .standard),
                   voice("d", "zh-CN"), voice("e", "zh-HK"), voice("com.apple.speech.synthesis.voice.Fred", "en-US")]
        XCTAssertEqual(VoiceCatalog.choices(for: "en-US", among: all).map(\.id), ["b", "c", "a"], "完全一致的在前，再按音质；趣味声音不列")
        XCTAssertEqual(VoiceCatalog.choices(for: "zh-CN", among: all).map(\.id), ["d"], "中文只要普通话")
    }

    func testOnlyNoveltyVoicesAreStillListed() {
        let all = [voice("com.apple.speech.synthesis.voice.Fred", "en-US")]
        XCTAssertEqual(VoiceCatalog.choices(for: "en-US", among: all).count, 1, "没有正经声音时才退回列出全部")
    }

    func testSelectedNameIgnoresMissingVoice() {
        let all = [voice("x", "en-US", name: "Ava")]
        XCTAssertEqual(VoiceCatalog.selectedName(for: .en, settings: ["en-US": "x"], among: all), "Ava")
        XCTAssertNil(VoiceCatalog.selectedName(for: .en, settings: ["en-US": "gone"], among: all), "被删掉的声音显示成自动")
        XCTAssertNil(VoiceCatalog.selectedName(for: .en, settings: [:], among: all))
    }

    func testCacheIsStableAcrossReads() {
        let first = VoiceCatalog.cachedVoices
        let second = VoiceCatalog.cachedVoices
        XCTAssertEqual(first, second)
    }

    func testCachedReadsAreMuchFasterThanEnumerating() {
        _ = VoiceCatalog.cachedVoices
        let start = CFAbsoluteTimeGetCurrent()
        for _ in 0..<200 { _ = VoiceCatalog.cachedVoices }
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        XCTAssertLessThan(elapsed, 0.05, "200 次读缓存应远小于一次枚举（~20ms）的 10 倍：\(elapsed)s")
    }

    /// 回归：打开「朗读声音」页原来会在主线程枚举 34 次（≈0.7s）。读缓存任意多次都不能再枚举。
    func testReadingCacheNeverReEnumerates() {
        _ = VoiceCatalog.cachedVoices
        let before = VoiceCatalog.enumerationCount
        for _ in 0..<500 { _ = VoiceCatalog.cachedVoices; _ = VoiceCatalog.choices(for: .en); _ = VoiceCatalog.choices(for: .zhHans) }
        XCTAssertEqual(VoiceCatalog.enumerationCount, before, "读缓存不能触发枚举")
    }

    /// 量化：优化前每次重建视图都枚举（≈ installedVoices 一次的耗时）；现在读缓存。打开一次页面约 34 次。
    func testOpeningPageCostBeforeAndAfter() {
        _ = VoiceCatalog.cachedVoices
        let clock = ContinuousClock()
        let before = clock.measure { for _ in 0..<34 { _ = VoiceCatalog.installedVoices() } }          // 旧做法：34 次真枚举
        let after = clock.measure { for _ in 0..<34 { _ = VoiceCatalog.cachedVoices } }                // 新做法：34 次读缓存
        func ms(_ d: Duration) -> Double { Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15 }
        print("VOICE_COST before=\(ms(before)) ms  after=\(ms(after)) ms  voices=\(VoiceCatalog.cachedVoices.count)")
        XCTAssertLessThan(ms(after), ms(before) / 20, "新做法应比旧做法快 20 倍以上")
    }

    func testRefreshUpdatesCache() async {
        let fresh = await VoiceCatalog.refresh()
        XCTAssertEqual(fresh, VoiceCatalog.cachedVoices)
    }

    /// 页面打开只看缓存、不枚举：缓存还没有时是 nil（页面显示加载中）；有了之后每种语言的排序结果也被缓存
    func testPeekNeverEnumeratesAndChoicesAreCached() async {
        let before = VoiceCatalog.enumerationCount
        _ = VoiceCatalog.peek
        _ = VoiceCatalog.cachedChoices(for: "en-US")
        XCTAssertEqual(VoiceCatalog.enumerationCount, before, "peek / cachedChoices 绝不能触发枚举")
        _ = await VoiceCatalog.refresh()
        let afterRefresh = VoiceCatalog.enumerationCount
        let first = try! XCTUnwrap(VoiceCatalog.cachedChoices(for: "en-US"))
        let second = try! XCTUnwrap(VoiceCatalog.cachedChoices(for: "en-US"))
        XCTAssertEqual(first, second)
        XCTAssertEqual(VoiceCatalog.enumerationCount, afterRefresh, "排好序的结果读缓存，不再枚举")
        XCTAssertNotNil(VoiceCatalog.peek)
    }
}
