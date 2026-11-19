import XCTest
@testable import XTrans

final class AdaptiveLayoutTests: XCTestCase {
    private func layout(_ w: CGFloat, _ h: CGFloat) -> LayoutClass { LayoutClass.forSize(CGSize(width: w, height: h)) }

    func testPhonesAreCompactInBothOrientations() {
        // 直板 iPhone：iPhone 17（402×874）、最大的 Pro Max 约 440×956；横过来很宽但很矮
        XCTAssertEqual(layout(320, 568), .compact)
        XCTAssertEqual(layout(402, 874), .compact)
        XCTAssertEqual(layout(440, 956), .compact)
        XCTAssertEqual(layout(874, 402), .compact, "横屏直板 iPhone 太矮，放不下工具面板")
        XCTAssertEqual(layout(956, 440), .compact)
    }

    func testDuoOuterDisplayIsCompact() {
        // Xcode 的 iPhone Duo 外屏：1398×2034px @3x = 466×678pt（横过来 678×466 也一样矮）
        XCTAssertEqual(layout(466, 678), .compact)
        XCTAssertEqual(layout(678, 466), .compact)
    }

    func testDuoInnerDisplayIsWideInBothOrientations() {
        // iPhone Duo 内屏：2007×2853px @3x = 669×951pt；展开后默认是横向 951×669
        XCTAssertEqual(layout(669, 951), .wide)
        XCTAssertEqual(layout(951, 669), .wide)
    }

    func testTabletsAreWide() {
        XCTAssertEqual(layout(744, 1133), .wide)   // iPad mini 竖屏
        XCTAssertEqual(layout(1133, 744), .wide)
        XCTAssertEqual(layout(1024, 1366), .wide)
    }

    func testThresholdsAreInclusive() {
        XCTAssertEqual(layout(LayoutClass.wideMinWidth - 0.5, 900), .compact)
        XCTAssertEqual(layout(LayoutClass.wideMinWidth, 900), .wide)
        XCTAssertEqual(layout(900, LayoutClass.wideMinHeight - 0.5), .compact)
        XCTAssertEqual(layout(900, LayoutClass.wideMinHeight), .wide)
    }

    func testToolPaneOnDuoInnerFitsAtLeastTwoTileColumns() {
        // 右栏要放得下至少 2 列磁贴（自适应网格会按宽度决定列数，窄了就少一列，而不是挤坏）
        let rightWidth = 669 * (1 - LayoutClass.conversationFraction)
        let needed = 2 * AddPanelView.tileMinWidth + AddPanelView.tileSpacing + 2 * AddPanelView.panelPadding
        XCTAssertGreaterThanOrEqual(rightWidth, needed, "右栏 \(rightWidth)pt，需要 \(needed)pt")
    }

    func testPortraitPhoneSheetFitsThreeTileColumns() {
        // 竖屏 iPhone 的加入面板（宽 393pt）仍然是 3 列，和设计稿一致
        let needed = 3 * AddPanelView.tileMinWidth + 2 * AddPanelView.tileSpacing + 2 * AddPanelView.panelPadding
        XCTAssertLessThanOrEqual(needed, 393)
    }

    func testConversationFractionIsReasonable() {
        XCTAssertGreaterThan(LayoutClass.conversationFraction, 0.4)
        XCTAssertLessThan(LayoutClass.conversationFraction, 0.65)
    }
}
