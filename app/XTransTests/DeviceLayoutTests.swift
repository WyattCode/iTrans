import XCTest
@testable import XTrans

/// 设备判定与次级页面的呈现方式：Duo 内屏 / 外屏 / 各种直板机，别互相认错。
@MainActor
final class DeviceLayoutTests: XCTestCase {
    // iPhone Duo
    private let duoInnerLandscape = CGSize(width: 951, height: 669)
    private let duoInnerPortrait = CGSize(width: 669, height: 951)
    private let duoOuterPortrait = CGSize(width: 466, height: 678)
    private let duoOuterLandscape = CGSize(width: 678, height: 466)
    // 直板机
    private let iPhoneProMaxLandscape = CGSize(width: 956, height: 440)
    private let iPhonePlusLandscape = CGSize(width: 932, height: 430)
    private let iPhoneAirLandscape = CGSize(width: 912, height: 420)
    private let iPhonePortrait = CGSize(width: 402, height: 874)
    private let iPhoneLandscape = CGSize(width: 874, height: 402)
    private let iPadPortrait = CGSize(width: 1032, height: 1376)

    func testDuoInnerScreenIsRecognised() {
        XCTAssertTrue(DuoLayout.isDuoLandscape(duoInnerLandscape))
        XCTAssertTrue(DuoLayout.isDuoPortrait(duoInnerPortrait))
        XCTAssertTrue(DuoLayout.isDuoInner(duoInnerLandscape))
        XCTAssertTrue(DuoLayout.isDuoInner(duoInnerPortrait))
    }

    /// 回归：Pro Max / Plus / Air 横屏宽度在 900–1000 之间，曾被当成 Duo 内屏（加入面板变成跨折痕的整屏盖上、键盘输入走 Duo 分栏）
    func testBigIPhonesInLandscapeAreNotDuo() {
        for size in [iPhoneProMaxLandscape, iPhonePlusLandscape, iPhoneAirLandscape, iPhoneLandscape] {
            XCTAssertFalse(DuoLayout.isDuoInner(size), "\(size) 不是 Duo 内屏")
        }
    }

    func testOuterScreenAndOtherDevicesAreNotDuoInner() {
        for size in [duoOuterPortrait, duoOuterLandscape, iPhonePortrait, iPadPortrait] {
            XCTAssertFalse(DuoLayout.isDuoInner(size), "\(size) 不是 Duo 内屏")
        }
    }

    func testPresentationPerDevice() {
        // 直板机和 Duo 外屏：整页推入
        for size in [iPhonePortrait, iPhoneLandscape, iPhoneProMaxLandscape, duoOuterPortrait, duoOuterLandscape] {
            XCTAssertEqual(RootView.PagePresentation.make(for: size), .push, "\(size)")
        }
        // Duo 内屏（展平是一整块连续画布）：屏幕正中的系统表单弹层
        XCTAssertEqual(RootView.PagePresentation.make(for: duoInnerLandscape), .sheet)
        XCTAssertEqual(RootView.PagePresentation.make(for: duoInnerPortrait), .sheet)
        // iPad：整屏盖上
        XCTAssertEqual(RootView.PagePresentation.make(for: iPadPortrait), .cover)
    }

    func testLayoutClass() {
        XCTAssertEqual(LayoutClass.forSize(duoInnerLandscape), .wide)
        XCTAssertEqual(LayoutClass.forSize(duoInnerPortrait), .wide)
        XCTAssertEqual(LayoutClass.forSize(duoOuterPortrait), .compact)
        XCTAssertEqual(LayoutClass.forSize(iPhoneLandscape), .compact)
    }

    /// 展平（完全展开）：折痕区域不起作用，内屏是一整块连续画布——控制条在整屏正中，不让位
    func testFlatInnerScreenIsOneContinuousCanvasWithCenteredStrip() {
        for mode in [TentMode.auto, .off] {
            for (size, insets) in [(duoInnerPortrait, (CGFloat(80), CGFloat(0), CGFloat(34), CGFloat(0))), (duoInnerLandscape, (CGFloat(0), CGFloat(0), CGFloat(34), CGFloat(84)))] {
                let arrangement = FaceGeometry.arrangement(size: size, mode: mode, hinge: .fullyOpen, fold: nil)
                XCTAssertEqual(arrangement, .stacked, "\(mode) \(size)")
                let g = FaceGeometry.compute(size: size, insets: insets, arrangement: arrangement)
                XCTAssertEqual(g.strip.midY, g.area.midY, accuracy: 0.5, "控制条要在整屏正中")
                XCTAssertEqual(g.them.height, g.me.height, accuracy: 0.5)
            }
        }
    }

    /// 半开：折痕区域起作用，控制条和文字让开它
    func testPartiallyOpenFoldDisplacesContent() {
        let horizontalFold = CGRect(x: 0, y: 455.5, width: 669, height: 40)
        let a = FaceGeometry.arrangement(size: duoInnerPortrait, mode: .auto, hinge: .partiallyOpen, fold: horizontalFold)
        XCTAssertEqual(a, .stackedFold)
        let g = FaceGeometry.compute(size: duoInnerPortrait, insets: (80, 0, 34, 0), arrangement: a)
        for frame in [g.them, g.me, g.strip] { XCTAssertFalse(frame.intersects(horizontalFold)) }
        XCTAssertEqual(g.them.height, g.me.height)

        let verticalFold = CGRect(x: 455.5, y: 0, width: 40, height: 669)
        let b = FaceGeometry.arrangement(size: duoInnerLandscape, mode: .auto, hinge: .partiallyOpen, fold: verticalFold)
        XCTAssertEqual(b, .sideBySide)
        let h = FaceGeometry.compute(size: duoInnerLandscape, insets: (0, 0, 34, 84), arrangement: b, crease: verticalFold.minX...verticalFold.maxX)
        for frame in [h.them, h.me, h.strip] { XCTAssertFalse(frame.intersects(verticalFold)) }
    }
}
