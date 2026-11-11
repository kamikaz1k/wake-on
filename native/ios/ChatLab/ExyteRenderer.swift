import SwiftUI
import ExyteChat

/// exyte/Chat + MarkdownView renderer. Placeholder until implemented.
struct ExyteRenderer: View {
    @ObservedObject var player: LabPlayer

    var body: some View {
        ContentUnavailableView("Not built yet", systemImage: "hammer", description: Text("exyte/Chat + MarkdownView"))
    }
}
