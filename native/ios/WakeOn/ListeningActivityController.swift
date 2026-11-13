import ActivityKit
import Combine
import UIKit

/// Keeps the listener's Live Activity (the orb in the Dynamic Island) in step with the wake
/// listener and voice calls. The activity starts when listening starts (iOS only allows that
/// while the app is open) and ends when listening is turned off.
@MainActor
final class ListeningActivityController {
    static let shared = ListeningActivityController()
    typealias Mode = ListeningActivityAttributes.ContentState.Mode

    /// How long the activity stays fresh without a refresh. If the app is closed or the phone
    /// restarts, it then shows "Not listening" instead of claiming to listen.
    static let staleAfter: TimeInterval = 20 * 60
    static let refreshEvery: TimeInterval = 10 * 60
    /// How long "Heard you" shows after "Hey Lobby" when no conversation follows.
    static let heardSeconds: TimeInterval = 4

    private var activity: Activity<ListeningActivityAttributes>?
    private var mode: Mode?
    private var since = Date()
    private var heardUntil: Date?
    private var endTask: Task<Void, Never>?
    private var refreshTimer: Timer?
    private var subscriptions: Set<AnyCancellable> = []
    private var loggedBackgroundSkip = false

    #if DEBUG
    /// Audio experiment: no orb this launch; clear any left by an earlier one.
    func endAll() {
        for activity in Activity<ListeningActivityAttributes>.activities {
            Task { await activity.end(nil, dismissalPolicy: .immediate) }
        }
    }
    #endif

    func activate() {
        guard subscriptions.isEmpty else { return }
        // Adopt an activity left by an earlier launch; end any extras.
        let existing = Activity<ListeningActivityAttributes>.activities
        activity = existing.first
        for extra in existing.dropFirst() { Task { await extra.end(nil, dismissalPolicy: .immediate) } }
        let wake = WakeController.shared, voice = VoiceSessionController.shared
        // objectWillChange fires before the change lands, so look a moment later.
        wake.objectWillChange.map { _ in () }
            .merge(with: voice.objectWillChange.map { _ in () })
            .merge(with: NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification).map { _ in () })
            .debounce(for: .milliseconds(100), scheduler: RunLoop.main)
            .sink { [weak self] in self?.sync() }
            .store(in: &subscriptions)
        sync()
    }

    /// "Hey Lobby" was just heard.
    func noteWake() {
        heardUntil = Date().addingTimeInterval(Self.heardSeconds)
        sync()
        Task {
            try? await Task.sleep(for: .seconds(Self.heardSeconds + 0.1))
            self.sync()
        }
    }

    private func desiredMode() -> Mode? {
        let wake = WakeController.shared, voice = VoiceSessionController.shared
        let heard = (heardUntil ?? .distantPast) > Date()
        // Only calls the listener is part of: it was on before, or "Hey Lobby" started this one.
        if voice.phase != .idle, voice.resumeWakeListener || wake.handingOver {
            return voice.phase == .connecting && heard ? .heard : .talking
        }
        if wake.enabled { return heard ? .heard : .listening }
        if wake.autoResumePending { return .paused }
        // Restarting (after a call or a settings change): keep what is shown.
        if wake.busy { return mode }
        return nil
    }

    private func sync() {
        guard let next = desiredMode() else {
            // Wait a moment: the listener stops and starts again for settings changes.
            guard activity != nil, endTask == nil else { return }
            endTask = Task {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                self.endTask = nil
                if self.desiredMode() == nil { self.end() }
            }
            return
        }
        endTask?.cancel()
        endTask = nil
        if next != mode {
            mode = next
            since = Date()
            push()
        } else if activity?.activityState != .active {
            push()
        }
    }

    private func push() {
        guard let mode else { return }
        let content = ActivityContent(state: ListeningActivityAttributes.ContentState(mode: mode, since: since),
                                      staleDate: Date().addingTimeInterval(Self.staleAfter))
        if let activity, activity.activityState == .active {
            Task { await activity.update(content) }
        } else {
            // Dismissed, ended, or never started. iOS only starts one while the app is open.
            guard UIApplication.shared.applicationState != .background else {
                if !loggedBackgroundSkip { VoiceSessionController.appLog("live_activity_start_skipped background") }
                loggedBackgroundSkip = true
                return
            }
            guard ActivityAuthorizationInfo().areActivitiesEnabled else {
                VoiceSessionController.appLog("live_activity_disabled")
                return
            }
            do {
                activity = try Activity.request(attributes: ListeningActivityAttributes(), content: content)
                loggedBackgroundSkip = false
                VoiceSessionController.appLog("live_activity_started mode=\(mode.rawValue)")
            } catch {
                VoiceSessionController.appLog("live_activity_failed \(error.localizedDescription)")
            }
        }
        scheduleRefresh()
    }

    /// Moves the stale date forward while the app is alive and listening.
    private func scheduleRefresh() {
        guard refreshTimer == nil else { return }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: Self.refreshEvery, repeats: true) { _ in
            MainActor.assumeIsolated {
                let controller = ListeningActivityController.shared
                if controller.activity?.activityState == .active { controller.push() }
            }
        }
    }

    private func end() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        mode = nil
        guard let activity else { return }
        self.activity = nil
        VoiceSessionController.appLog("live_activity_ended")
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
    }
}
