import SwiftUI

/// Chat Lab's "Ours" page: the shared chat view (ChatUI) over the scenario replay.
struct PlainRenderer: View {
    @ObservedObject var player: LabPlayer

    var body: some View {
        VStack(spacing: 0) {
            ChatTranscriptView(items: player.items, call: player.call)
        }
    }
}

