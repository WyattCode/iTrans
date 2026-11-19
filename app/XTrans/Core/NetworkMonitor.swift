import Network
import Observation

/// 只用来在对话流顶部提示"当前离线"。翻译本身在设备上完成，所以离线不影响已下载的语言。
@MainActor
@Observable
final class NetworkMonitor {
    private(set) var isOnline = true
    @ObservationIgnored private let monitor = NWPathMonitor()

    init(forceOffline: Bool = false) {
        if forceOffline {
            isOnline = false
            return
        }
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in self?.isOnline = online }
        }
        monitor.start(queue: DispatchQueue(label: "app.xtrans.network"))
    }

    #if DEBUG
    /// 调试：`-XTransOfflineAfter <秒>` 运行中途把网络改成离线（模拟真机上开飞行模式），测「中途断网」界面有没有跟着变
    func debugSetOnline(_ value: Bool) { isOnline = value }
    #endif

    deinit { monitor.cancel() }
}
