import Combine
import UIKit

/// Keeps the screen on while the iPhone is charging (on a stand) and Wake On is open.
/// iOS only honours this for the app on screen; auto-lock returns when it leaves.
@MainActor
final class ScreenAwake {
    static let shared = ScreenAwake()
    static let key = "screen.awakeWhileCharging"
    private var subscriptions: Set<AnyCancellable> = []

    /// On by default: a phone on a stand is the case this is for.
    static var enabled: Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? true }

    nonisolated static func keepsScreenOn(enabled: Bool, battery: UIDevice.BatteryState) -> Bool {
        enabled && (battery == .charging || battery == .full)
    }

    func activate() {
        guard subscriptions.isEmpty else { return }
        UIDevice.current.isBatteryMonitoringEnabled = true
        NotificationCenter.default.publisher(for: UIDevice.batteryStateDidChangeNotification).map { _ in () }
            .merge(with: NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification).map { _ in () })
            .merge(with: NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification).map { _ in () })
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.update() }
            .store(in: &subscriptions)
        update()
    }

    func update() {
        let on = Self.keepsScreenOn(enabled: Self.enabled, battery: UIDevice.current.batteryState)
        if UIApplication.shared.isIdleTimerDisabled != on {
            UIApplication.shared.isIdleTimerDisabled = on
            VoiceSessionController.appLog("screen_awake \(on)")
        }
    }
}
