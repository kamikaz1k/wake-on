import MarkdownParser
import MarkdownView
import SwiftUI
import UIKit

/// MarkdownView's own SwiftUI wrapper measures its height after layout (async) and starts each
/// new view at 0. In exyte's recycled table cells that made the list's height change by a row
/// every time a Pixie bubble was reused near the top, so the scroll position kept re-clamping:
/// the bounce loop at the top. This wrapper reports its height during layout instead.
///
/// Tables: MarkdownView puts each table in a sideways scroll view but turns its clipping off,
/// so a wide table drew past the bubble. We clip the whole text view, give messages with a
/// table the full width, and flash the table's scroll bar when it's wider than the view.
struct SizedMarkdown: UIViewRepresentable {
    let text: String

    final class Coordinator {
        var text: String?
        var lastFlash = Date.distantPast
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MarkdownTextView {
        let view = MarkdownTextView()
        view.throttleInterval = nil // apply each update now, so the size we report is current
        view.clipsToBounds = true   // keep wide tables inside the bubble
        view.setContentHuggingPriority(.required, for: .vertical)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }

    func updateUIView(_ view: MarkdownTextView, context: Context) {
        apply(to: view, context.coordinator)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView view: MarkdownTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0 else { return nil }
        apply(to: view, context.coordinator)
        let size = view.boundingSize(for: width)
        // Natural width, so short replies get snug bubbles; a table gets all the room there is.
        let natural = Self.containsTable(text) ? width : min(width, ceil(size.width))
        return CGSize(width: natural, height: ceil(size.height))
    }

    private func apply(to view: MarkdownTextView, _ coordinator: Coordinator) {
        guard coordinator.text != text else { return }
        coordinator.text = text
        let content = MarkdownTextView.PreprocessedContent(parserResult: MarkdownParser().parse(text), theme: view.theme)
        view.setMarkdownManually(content)
        // MarkdownView draws text VoiceOver can't read; expose the message as one element.
        view.isAccessibilityElement = true
        view.accessibilityLabel = text
        // Hint that a too-wide table scrolls sideways (MarkdownView hides its indicators);
        // at most every 2 s, so a table that is still streaming doesn't flicker.
        if Self.containsTable(text), Date().timeIntervalSince(coordinator.lastFlash) > 2 {
            coordinator.lastFlash = Date()
            DispatchQueue.main.async { Self.revealWideTables(in: view) }
        }
    }

    private static func revealWideTables(in view: UIView) {
        for case let scroll as UIScrollView in view.subviewsRecursive
        where scroll.contentSize.width > scroll.bounds.width + 1 {
            scroll.showsHorizontalScrollIndicator = true
            scroll.flashScrollIndicators()
        }
    }

    /// A markdown table: a row of pipes followed by a delimiter row like |---|:--:|.
    static func containsTable(_ text: String) -> Bool {
        text.range(of: #"(?m)^\s*\|.*\|\s*\n\s*\|?\s*:?-{3,}"#, options: .regularExpression) != nil
    }
}

private extension UIView {
    var subviewsRecursive: [UIView] { subviews + subviews.flatMap(\.subviewsRecursive) }
}

/// A message shown on its own at full screen width, for wide tables (Expand action).
struct ExpandedMessage: View {
    let text: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                SizedMarkdown(text: text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .navigationTitle(Agent.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}
