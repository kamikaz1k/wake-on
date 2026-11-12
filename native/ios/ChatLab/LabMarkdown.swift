import MarkdownParser
import MarkdownView
import SwiftUI
import UIKit

/// MarkdownView's own SwiftUI wrapper measures its height after layout (async) and starts each
/// new view at 0. In exyte's recycled table cells that made the list's height change by a row
/// every time a Lobby bubble was reused near the top, so the scroll position kept re-clamping:
/// the bounce loop at the top. This wrapper reports its height during layout instead.
struct SizedMarkdown: UIViewRepresentable {
    let text: String

    final class Coordinator { var text: String? }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MarkdownTextView {
        let view = MarkdownTextView()
        view.throttleInterval = nil // apply each update now, so the size we report is current
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
        // Natural width, so short replies get snug bubbles instead of full-width ones.
        return CGSize(width: min(width, ceil(size.width)), height: ceil(size.height))
    }

    private func apply(to view: MarkdownTextView, _ coordinator: Coordinator) {
        guard coordinator.text != text else { return }
        coordinator.text = text
        let content = MarkdownTextView.PreprocessedContent(parserResult: MarkdownParser().parse(text), theme: view.theme)
        view.setMarkdownManually(content)
    }
}
