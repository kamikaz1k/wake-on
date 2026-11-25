import AVFoundation
import Foundation

/// How the background "Hey Pixie" listener uses audio. Voice calls ignore these: a call
/// always takes a dedicated, non-shared voice-chat session.
struct ListenerSettings: Equatable {
    /// Mix with other apps' audio, so a video or music does not interrupt listening.
    var shareAudio = true
    /// Restart listening after a call, Siri, an alarm or another interruption ends.
    var autoResume = true
    /// Record from the iPhone's microphone even with Bluetooth headphones connected, so
    /// headphones stay in high-quality playback instead of switching to call quality.
    var builtInMicrophone = true
    /// While sharing, use iOS's default audio mode instead of measurement mode. Measurement
    /// mode switches off system audio processing for the whole route, so other apps' playback
    /// loses its EQ, loudness and spatial effects while the listener runs.
    var fullSoundForOthers = true
    /// Experiment: start a voice conversation when "Hey Pixie" is heard, even in the background.
    var talkOnWake = false

    enum Key {
        static let shareAudio = "listener.shareAudio"
        static let autoResume = "listener.autoResume"
        static let builtInMicrophone = "listener.builtInMicrophone"
        static let fullSoundForOthers = "listener.fullSoundForOthers"
        static let talkOnWake = "listener.talkOnWake"
    }

    /// Bump to reset everyone's saved listener choices to the current defaults once.
    /// Version 2: durable background listening (shared, full sound, resume, iPhone mic).
    static let settingsVersion = 2
    static let versionKey = "listener.settingsVersion"

    /// Clears choices saved by earlier test builds so the defaults apply; later changes stick.
    static func migrate(_ defaults: UserDefaults = .standard) {
        guard defaults.integer(forKey: versionKey) < settingsVersion else { return }
        for key in [Key.shareAudio, Key.autoResume, Key.builtInMicrophone, Key.fullSoundForOthers] {
            defaults.removeObject(forKey: key)
        }
        defaults.set(settingsVersion, forKey: versionKey)
    }

    static var current: ListenerSettings {
        let defaults = UserDefaults.standard
        func value(_ key: String, _ fallback: Bool = true) -> Bool { defaults.object(forKey: key) as? Bool ?? fallback }
        return ListenerSettings(shareAudio: value(Key.shareAudio), autoResume: value(Key.autoResume),
                                builtInMicrophone: value(Key.builtInMicrophone),
                                fullSoundForOthers: value(Key.fullSoundForOthers),
                                talkOnWake: value(Key.talkOnWake, false))
    }

    /// Measurement mode gives the wake model unprocessed audio; it only costs other apps
    /// their sound processing when they play alongside us (sharing on).
    var mode: AVAudioSession.Mode { shareAudio && fullSoundForOthers ? .default : .measurement }

    var categoryOptions: AVAudioSession.CategoryOptions {
        var options: AVAudioSession.CategoryOptions = [.defaultToSpeaker]
        if shareAudio { options.insert(.mixWithOthers) }
        // A2DP keeps headphones in high-quality output; only HFP lets them provide the microphone.
        options.insert(builtInMicrophone ? .allowBluetoothA2DP : .allowBluetoothHFP)
        return options
    }

    var summary: String {
        "share=\(shareAudio) resume=\(autoResume) builtInMic=\(builtInMicrophone) fullSound=\(fullSoundForOthers) mode=\(mode.rawValue)"
    }
}
