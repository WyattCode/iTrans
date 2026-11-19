import XCTest
import AVFoundation
@testable import XTrans

/// 探针：激活音频会话后，「已经是这个类别就不重复设置」的判断会不会命中。
/// 真机实测每次按麦克风激活要 65–100ms（第一次只要 3ms），怀疑是这个判断一直没命中、每次都在重新 `setCategory`。
@MainActor
final class AudioSessionProbeTests: XCTestCase {
    func testCategoryCheckHitsAfterActivate() throws {
        try AppAudioSession.activate()
        let s = AVAudioSession.sharedInstance()
        let hits = s.category == .playAndRecord && s.mode == .default && s.categoryOptions.contains(.defaultToSpeaker)
        print("PROBE category=\(s.category.rawValue) mode=\(s.mode.rawValue) options=\(s.categoryOptions.rawValue) contains(defaultToSpeaker)=\(s.categoryOptions.contains(.defaultToSpeaker)) skipCheckHits=\(hits)")
        XCTAssertTrue(hits, "激活之后，下一次的「已经是这个类别」判断应该命中，否则每次聆听都白白重新 setCategory")
    }
}
