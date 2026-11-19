import AVFoundation
import Speech
import UIKit

enum PermissionState: Equatable {
    case notDetermined, granted, denied

    var label: String {
        switch self {
        case .notDetermined: return String(localized: "允许")
        case .granted: return String(localized: "已允许")
        case .denied: return String(localized: "已拒绝")
        }
    }
}

/// 麦克风 / 语音识别权限的查询和申请。相机推迟到第一次用相机时由系统自己弹窗，不在引导里要。
enum PermissionCenter {
    static func microphone() -> PermissionState {
        switch AVAudioApplication.shared.recordPermission {
        case .undetermined: return .notDetermined
        case .granted: return .granted
        case .denied: return .denied
        @unknown default: return .notDetermined
        }
    }

    static func speech() -> PermissionState {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .notDetermined: return .notDetermined
        case .authorized: return .granted
        case .denied, .restricted: return .denied
        @unknown default: return .notDetermined
        }
    }

    @discardableResult
    static func requestMicrophone() async -> PermissionState {
        _ = await AVAudioApplication.requestRecordPermission()
        return microphone()
    }

    @discardableResult
    static func requestSpeech() async -> PermissionState {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            SFSpeechRecognizer.requestAuthorization { _ in c.resume() }
        }
        return speech()
    }

    /// 打开本 App 在系统设置里的页面（权限被拒后唯一的出路）。
    @MainActor
    static func openSystemSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }
}
