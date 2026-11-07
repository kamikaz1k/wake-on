import SwiftUI

/// The three listener audio options. Changing one while listening restarts the listener.
struct ListenerOptionsView: View {
    @ObservedObject var controller: WakeController
    @AppStorage(ListenerSettings.Key.shareAudio) private var shareAudio = true
    @AppStorage(ListenerSettings.Key.autoResume) private var autoResume = true
    @AppStorage(ListenerSettings.Key.builtInMicrophone) private var builtInMicrophone = true
    @AppStorage(ListenerSettings.Key.fullSoundForOthers) private var fullSoundForOthers = true
    @AppStorage(ListenerSettings.Key.talkOnWake) private var talkOnWake = false

    var body: some View {
        Section {
            Toggle("Keep listening while other audio plays", isOn: $shareAudio)
                .accessibilityIdentifier("listener-share-audio")
            Toggle("Full sound for other apps", isOn: $fullSoundForOthers)
                .disabled(!shareAudio)
                .accessibilityIdentifier("listener-full-sound")
            Toggle("Resume after calls, Siri and alarms", isOn: $autoResume)
                .accessibilityIdentifier("listener-auto-resume")
            Toggle("Use iPhone microphone with headphones", isOn: $builtInMicrophone)
                .accessibilityIdentifier("listener-built-in-mic")
            Toggle("Start a conversation on “Hey Lobby”", isOn: $talkOnWake)
                .accessibilityIdentifier("listener-talk-on-wake")
        } header: { Text("Listening options") } footer: {
            Text("Sharing lets videos and music play without stopping the listener; it also hears them. Full sound keeps iOS's normal audio processing for them (the listener otherwise uses raw measurement mode). The iPhone microphone keeps Bluetooth headphones in high-quality playback. Voice calls always use their own audio and pause other sound.")
        }
        .onChange(of: shareAudio) { _, _ in controller.applySettingsChange() }
        .onChange(of: fullSoundForOthers) { _, _ in controller.applySettingsChange() }
        .onChange(of: builtInMicrophone) { _, _ in controller.applySettingsChange() }
    }
}
