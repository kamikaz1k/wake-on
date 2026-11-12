import SwiftUI

/// The libraries being compared. Each one renders the same `LabPlayer` replay.
enum LabLibrary: String, CaseIterable, Identifiable {
    case plain, exyte, conversationKit, languageModelChatUI

    var id: String { rawValue }

    var name: String {
        switch self {
        case .plain: "Our SwiftUI (shadcn rules)"
        case .exyte: "exyte/Chat + MarkdownView"
        case .conversationKit: "ConversationKit"
        case .languageModelChatUI: "LanguageModelChatUI"
        }
    }

    var shortName: String {
        switch self {
        case .plain: "Ours"
        case .exyte: "exyte"
        case .conversationKit: "ConvKit"
        case .languageModelChatUI: "LMChatUI"
        }
    }

    /// G2 facts, shown at the top of each page.
    var facts: String {
        switch self {
        case .plain:
            "Ours · SwiftUI ScrollView + scrollPosition, implements shadcn's scroll rules · iOS 18 · no dependencies · inline markdown only"
        case .exyte:
            "exyte/Chat 3.3.7 (SwiftUI over UITableView, MIT, iOS 17, pulls in Giphy, Kingfisher, MediaPicker) + MarkdownView 3.9.1 (MIT)"
        case .conversationKit:
            "ConversationKit 0.1.1 · SwiftUI · Apache-2.0 · iOS 17 · depends on MarkdownUI · composer always shown"
        case .languageModelChatUI:
            "LanguageModelChatUI 0.2.0 · UIKit (FlowDown) · MIT · iOS 17 · own session + client; driven by a fake model client"
        }
    }

    @MainActor @ViewBuilder
    func view(player: LabPlayer) -> some View {
        switch self {
        case .plain: PlainRenderer(player: player)
        case .exyte: ExyteRenderer(player: player)
        case .conversationKit: ConversationKitRenderer(player: player)
        case .languageModelChatUI: LanguageModelChatUIRenderer(player: player)
        }
    }
}

/// Your 0/1/2 scores per scenario and library, kept on this phone.
@MainActor
final class LabScores: ObservableObject {
    static let shared = LabScores()
    @Published private var scores: [String: Int]
    private let key = "chatlab.scores"

    init() {
        scores = (UserDefaults.standard.dictionary(forKey: key) as? [String: Int]) ?? [:]
    }

    func score(_ scenario: String, _ library: LabLibrary) -> Int? { scores["\(scenario).\(library.rawValue)"] }

    func set(_ value: Int?, _ scenario: String, _ library: LabLibrary) {
        scores["\(scenario).\(library.rawValue)"] = value
        UserDefaults.standard.set(scores, forKey: key)
    }

    func total(_ library: LabLibrary) -> (points: Int, scored: Int) {
        let values = LabScenarios.all.compactMap { score($0.id, library) }
        return (values.reduce(0, +), values.count)
    }

    /// CSV for sharing: scenario, title, one column per library.
    var csv: String {
        var lines = ["scenario,title," + LabLibrary.allCases.map(\.shortName).joined(separator: ",")]
        for scenario in LabScenarios.all {
            let cells = LabLibrary.allCases.map { score(scenario.id, $0).map(String.init) ?? "" }
            lines.append("\(scenario.id),\"\(scenario.title)\"," + cells.joined(separator: ","))
        }
        return lines.joined(separator: "\n")
    }
}
