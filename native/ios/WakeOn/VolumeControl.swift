import AVFoundation
import MediaPlayer
import UIKit

/// Pixie's "turn it up / down / set the volume to 30%" tool. iOS has no public API to set the
/// system volume; the standard workaround is the slider inside a hidden `MPVolumeView`, which
/// moves the same volume as the side buttons (and shows the volume HUD). During a call the
/// buttons control the call's volume, so the app hangs up first and then sets it (like
/// `control_media`), when it applies to media again.
enum VolumeControl {
    static let toolName = "set_volume"

    enum Change: String, CaseIterable { case set, up, down }

    /// Turning up or down without an amount moves this much (about two button presses).
    static let defaultStep: Float = 0.15

    static let tool: [String: Any] = [
        "type": "function",
        "name": toolName,
        "description": "Change the phone's media volume (music, podcasts, videos): set it to a level, or turn it up or down.",
        "strict": true,
        "parameters": [
            "type": "object",
            "properties": [
                "change": [
                    "type": "string",
                    "enum": Change.allCases.map(\.rawValue),
                    "description": "set (to level), up or down.",
                ],
                "level": [
                    "type": "integer",
                    "description": "For set: the volume from 0 to 100. For up or down: how much to change it, 0 to 100, or 0 for a normal step.",
                ],
            ],
            "required": ["change", "level"],
            "additionalProperties": false,
        ] as [String: Any],
    ]

    static let delegationInstructions = """
    To change how loud music or videos play (louder, quieter, mute, a percentage), call \
    set_volume; "mute" is set to 0, "a bit louder" is up with level 0.
    """

    struct Request: Equatable {
        var change: Change
        var level: Int

        /// "to 30%", "up", "down by 20%".
        var description: String {
            switch change {
            case .set: "to \(level)%"
            case .up: level > 0 ? "up by \(level)%" : "up"
            case .down: level > 0 ? "down by \(level)%" : "down"
            }
        }
    }

    static func request(change: String, level: Int) -> Request? {
        guard let change = Change(rawValue: change) else { return nil }
        return Request(change: change, level: min(max(level, 0), 100))
    }

    /// The new volume (0–1) from the current one.
    static func target(_ request: Request, current: Float) -> Float {
        let amount = request.level > 0 ? Float(request.level) / 100 : defaultStep
        let value: Float = switch request.change {
        case .set: Float(request.level) / 100
        case .up: current + amount
        case .down: current - amount
        }
        return min(max(value, 0), 1)
    }

    @MainActor private static var volumeView: MPVolumeView?

    /// Sets the volume. `done` gets the volume before and after (0–1), or nil if the system
    /// slider wasn't found.
    @MainActor
    static func apply(_ request: Request, done: @escaping @MainActor ((Float, Float)?) -> Void = { _ in }) {
        let fresh = volumeView == nil
        let view = volumeView ?? makeView()
        // A new MPVolumeView builds its slider on the next layout pass.
        DispatchQueue.main.asyncAfter(deadline: .now() + (fresh ? 0.3 : 0)) {
            guard let slider = view.subviews.compactMap({ $0 as? UISlider }).first else {
                VoiceSessionController.appLog("volume_set failed=no_slider")
                return done(nil)
            }
            // The slider tracks the system volume; `outputVolume` can be stale until the app's
            // audio is active (a fresh launch read 0.55 right after the volume was set to 0.30).
            let before = slider.value
            let after = target(request, current: before)
            slider.value = after
            slider.sendActions(for: .valueChanged)
            VoiceSessionController.appLog(String(format: "volume_set %@ before=%.2f after=%.2f appState=%d",
                                                 request.description, before, after,
                                                 UIApplication.shared.applicationState.rawValue))
            done((before, after))
            // What the system reports a moment later: proof the volume really moved.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                VoiceSessionController.appLog(String(format: "volume_check outputVolume=%.2f slider=%.2f",
                                                     AVAudioSession.sharedInstance().outputVolume, slider.value))
            }
        }
    }

    /// Off screen and nearly transparent: a hidden or detached MPVolumeView doesn't move the
    /// system volume.
    @MainActor private static func makeView() -> MPVolumeView {
        let view = MPVolumeView(frame: CGRect(x: -2000, y: -2000, width: 120, height: 40))
        view.alpha = 0.01
        view.isUserInteractionEnabled = false
        let window = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first { $0.isKeyWindow } ?? UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first
        window?.addSubview(view)
        volumeView = view
        return view
    }
}
