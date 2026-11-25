import SwiftUI

/// Settings shared by the call screen and the gallery.
enum VoiceVisualizerSettings {
    static let styleKey = "voiceVisualizerStyle"
    static let paletteKey = "voiceVisualizerPalette"
}

/// Compare every visualizer on a recorded conversation and pick the one the call screen uses.
struct VoiceVisualizerGallery: View {
    @AppStorage(VoiceVisualizerSettings.styleKey) private var style: VoiceVisualizerStyle = .skyOrb
    @AppStorage(VoiceVisualizerSettings.paletteKey) private var paletteName = VoicePalette.default.name
    @StateObject private var player = SampleConversationPlayer()
    /// Start the sample conversation as soon as the screen opens.
    var autoplay = false

    private var palette: VoicePalette { VoicePalette.named(paletteName) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(spacing: 0) {
                    VoiceVisualizer(style: style, palette: palette, signal: player.signal)
                        .frame(height: 300)
                    Text(player.caption.isEmpty ? "Play the sample to hear a two-voice conversation." : player.caption)
                        .font(.callout)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(player.caption.isEmpty ? .gray
                                         : VoicePalette.color(player.captionIsUser ? palette.user : palette.assistant))
                        .frame(maxWidth: .infinity, minHeight: 66, alignment: .top)
                        .padding(.horizontal)
                        .padding(.bottom, 12)
                }
                .background(Color.black, in: RoundedRectangle(cornerRadius: 20))

                HStack {
                    Button(player.isPlaying ? "Restart sample" : "Play sample conversation",
                           systemImage: "play.fill") { player.play() }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("visualizer-play-sample")
                    if player.isPlaying {
                        Button("Stop", systemImage: "stop.fill") { player.stop() }
                            .buttonStyle(.bordered)
                    }
                }
                if let error = player.error {
                    Text(error).font(.footnote).foregroundStyle(.red)
                }

                Picker("Colors", selection: $paletteName) {
                    ForEach(VoicePalette.presets) { preset in Text(preset.name).tag(preset.name) }
                }
                .pickerStyle(.menu)
                Text("Colors apply to every style except the bloom orb.")
                    .font(.footnote).foregroundStyle(.secondary)

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                    ForEach(VoiceVisualizerStyle.allCases) { option in
                        Button { style = option } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                VoiceVisualizer(style: option, palette: palette, signal: player.signal)
                                    .frame(height: 130)
                                Text(option.title).font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                                Text(option.summary).font(.caption).foregroundStyle(.gray).lineLimit(2)
                            }
                            .padding(10)
                            .background(Color.black, in: RoundedRectangle(cornerRadius: 14))
                            .overlay {
                                RoundedRectangle(cornerRadius: 14)
                                    .strokeBorder(option == style ? Color.accentColor : .clear, lineWidth: 2)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(option.title)
                        .accessibilityAddTraits(option == style ? .isSelected : [])
                    }
                }
            }
            .padding()
        }
        .navigationTitle("Visualizer")
        // The tab bar shows on the main pages only, never over a page's own controls.
        .toolbar(.hidden, for: .tabBar)
        .onAppear { if autoplay && !player.isPlaying { player.play() } }
        .onDisappear { player.stop() }
    }
}

#Preview {
    NavigationStack { VoiceVisualizerGallery() }
}
