import XCTest
import SwiftUI
@testable import XTrans

/// 长按麦克风说话：按下后开始聆听、对话里多出一条「正在听」的消息——这一刻半屏从「空状态」换成「有对话」，
/// 麦克风视图不能因此被销毁重建（重建 = 正在进行的长按被取消、聆听当场结束）。
/// 回归：横向版面（Duo 内屏展平、直板横屏）里麦克风原来跟着空状态分支放在两处，按下就断。
@MainActor
final class MicHoldStabilityTests: XCTestCase {
    private func hostedHalf(_ session: ConversationSession, placement: FaceGeometry.MicPlacement, size: CGSize) -> (UIWindow, UIHostingController<some View>) {
        let root = HalfView(session: session, side: .me, micPlacement: placement)
            .frame(width: size.width, height: size.height)
        let host = UIHostingController(rootView: root)
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
        return (window, host)
    }

    private func settle(_ seconds: Double = 0.3) async {
        try? await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }

    private func assertMicSurvivesFirstTurn(placement: FaceGeometry.MicPlacement, size: CGSize,
                                            file: StaticString = #filePath, line: UInt = #line) async {
        let rec = FakeRecognizer(); rec.holdOpen = true
        let session = ConversationSession(recognizer: rec, synthesizer: FakeSynthesizer(), engine: ScriptedEngine())
        let (window, host) = hostedHalf(session, placement: placement, size: size)
        defer { window.isHidden = true; _ = host }
        await settle()
        XCTAssertTrue(session.turns.isEmpty, file: file, line: line)
        let before = MicButton.mountCount
        XCTAssertGreaterThan(before, 0, "麦克风应该已经挂上界面", file: file, line: line)

        XCTAssertTrue(session.holdBegan(.me), file: file, line: line)
        let deadline = ContinuousClock.now + .seconds(2)
        while session.turns.isEmpty, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(session.turns.isEmpty, "开始聆听后会话里应该多出一条消息", file: file, line: line)
        await settle()

        XCTAssertEqual(MicButton.mountCount, before,
                       "长按开始听、对话从空变成有内容时，麦克风不能被销毁重建（\(placement)）", file: file, line: line)
        session.holdEnded(.me)
    }

    func testMicSurvivesFirstTurnInLandscapeLayout() async {
        await assertMicSurvivesFirstTurn(placement: .trailing, size: CGSize(width: 900, height: 330))
    }

    func testMicSurvivesFirstTurnInPortraitLayout() async {
        await assertMicSurvivesFirstTurn(placement: .bottom, size: CGSize(width: 400, height: 380))
    }
}
