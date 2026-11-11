import SwiftUI
import ConversationKit

/// ConversationKit renderer. Placeholder until implemented.
struct ConversationKitRenderer: View {
    @ObservedObject var player: LabPlayer

    var body: some View {
        ContentUnavailableView("Not built yet", systemImage: "hammer", description: Text("ConversationKit"))
    }
}
