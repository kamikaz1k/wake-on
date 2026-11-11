import QuartzCore
import SwiftUI

@main
struct ChatLabApp: App {
    var body: some Scene {
        WindowGroup {
            NavigationStack { ScenarioListView() }
        }
    }
}

/// All scenarios, grouped as in docs/research/chat-ui-scenarios.md, with your scores.
struct ScenarioListView: View {
    @ObservedObject private var scores = LabScores.shared
    /// "-lab-scenario A4" opens that scenario on launch (for screenshots).
    @State private var opened: String? = ProcessInfo.processInfo.arguments.firstIndex(of: "-lab-scenario")
        .flatMap { ProcessInfo.processInfo.arguments.dropFirst($0 + 1).first }

    var body: some View {
        List {
            Section {
                ForEach(LabLibrary.allCases) { library in
                    let total = scores.total(library)
                    LabeledContent(library.name, value: "\(total.points) pts · \(total.scored)/\(LabScenarios.all.count)")
                }
                ShareLink("Share scores (CSV)", item: scores.csv)
            } header: { Text("Scores") } footer: {
                Text("Open a scenario, then swipe sideways to compare libraries. Score each 0 (fights it), 1 (needs our code) or 2 (out of the box).")
            }
            ForEach(LabGroup.allCases) { group in
                Section(group.rawValue) {
                    ForEach(LabScenarios.all.filter { $0.group == group.id }) { scenario in
                        NavigationLink {
                            ScenarioPager(scenario: scenario)
                        } label: {
                            HStack {
                                Text(scenario.id).font(.caption.monospaced().weight(.semibold)).foregroundStyle(.secondary)
                                    .frame(width: 34, alignment: .leading)
                                Text(scenario.title)
                                Spacer()
                                ScoreDots(scenario: scenario.id)
                            }
                        }
                        .accessibilityIdentifier("scenario-\(scenario.id)")
                    }
                }
            }
        }
        .navigationTitle("Chat Lab")
        .navigationDestination(isPresented: Binding(get: { opened != nil }, set: { if !$0 { opened = nil } })) {
            if let scenario = LabScenarios.all.first(where: { $0.id == opened }) {
                ScenarioPager(scenario: scenario)
            }
        }
    }
}

private struct ScoreDots: View {
    let scenario: String
    @ObservedObject private var scores = LabScores.shared
    var body: some View {
        HStack(spacing: 3) {
            ForEach(LabLibrary.allCases) { library in
                Circle().fill(color(scores.score(scenario, library))).frame(width: 7, height: 7)
            }
        }
        .accessibilityHidden(true)
    }
    private func color(_ score: Int?) -> Color {
        switch score { case 2: .green; case 1: .yellow; case 0: .red; default: Color(.tertiarySystemFill) }
    }
}

/// One scenario: what to look for, replay controls, and a page per library to swipe through.
struct ScenarioPager: View {
    let scenario: LabScenario
    @StateObject private var player = LabPlayer()
    @State private var page: LabLibrary = .plain
    @State private var showNote = true

    init(scenario: LabScenario) {
        self.scenario = scenario
        let initial = ProcessInfo.processInfo.arguments.firstIndex(of: "-lab-library")
            .flatMap { index in ProcessInfo.processInfo.arguments.dropFirst(index + 1).first }
            .flatMap(LabLibrary.init(rawValue:)) ?? .plain
        _page = State(initialValue: initial)
    }

    var body: some View {
        VStack(spacing: 0) {
            if showNote {
                Text(scenario.lookFor)
                    .font(.footnote)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal).padding(.vertical, 8)
                    .background(Color(.secondarySystemBackground))
            }
            TabView(selection: $page) {
                ForEach(LabLibrary.allCases) { library in
                    LibraryPage(scenario: scenario, library: library, player: player)
                        .tag(library)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            controls
        }
        .navigationTitle("\(scenario.id) · \(scenario.title)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Button(showNote ? "Hide note" : "Show note") { withAnimation { showNote.toggle() } }
        }
        .onAppear { player.load(scenario.script()) }
        .onDisappear { player.stop() }
    }

    private var controls: some View {
        VStack(spacing: 6) {
            ProgressView(value: player.progress)
            HStack {
                Button(player.isPlaying ? "Replaying…" : "Replay", systemImage: "arrow.counterclockwise") { player.restart() }
                    .accessibilityIdentifier("lab-replay")
                Spacer()
                // Library switcher, also reachable by swiping.
                HStack(spacing: 6) {
                    ForEach(LabLibrary.allCases) { library in
                        Capsule().fill(library == page ? Color.accentColor : Color(.tertiarySystemFill))
                            .frame(width: library == page ? 18 : 7, height: 7)
                    }
                }
            }
            .font(.footnote)
        }
        .padding(.horizontal).padding(.vertical, 8)
        .background(.bar)
    }
}

/// One library's take on the scenario: name, facts, score, then the chat itself.
struct LibraryPage: View {
    let scenario: LabScenario
    let library: LabLibrary
    @ObservedObject var player: LabPlayer
    @ObservedObject private var scores = LabScores.shared

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(library.name).font(.headline)
                    Spacer()
                    Picker("Score", selection: Binding(get: { scores.score(scenario.id, library) ?? -1 },
                                                       set: { scores.set($0 < 0 ? nil : $0, scenario.id, library) })) {
                        Text("–").tag(-1)
                        Text("0").tag(0)
                        Text("1").tag(1)
                        Text("2").tag(2)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 150)
                    .accessibilityIdentifier("score-\(library.rawValue)")
                }
                if scenario.id == "G2" || scenario.id == "A14" || scenario.id == "G1" {
                    Text(library.facts).font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal).padding(.vertical, 8)
            Divider()
            ZStack(alignment: .topTrailing) {
                if scenario.compact {
                    VStack(spacing: 0) {
                        // Stand-in for the orb and Start chat area on the Simple tab.
                        Circle().fill(.blue.gradient).frame(width: 120, height: 120).padding(.vertical, 16)
                        library.view(player: player)
                            .frame(height: 300)
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                            .padding(.horizontal, 12)
                        Spacer(minLength: 0)
                    }
                } else {
                    library.view(player: player)
                }
                if scenario.showsFrameRate { FrameRateBadge(player: player).padding(8) }
            }
            .frame(maxHeight: .infinity)
        }
    }
}

/// Frames per second and dropped frames while this page is on screen (A14, G1).
struct FrameRateBadge: View {
    @ObservedObject var player: LabPlayer
    @StateObject private var meter = FrameMeter()

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text("\(meter.fps) fps · \(meter.drops) drops")
            Text("\(player.updatesPerSecond) updates/s")
        }
        .font(.caption2.monospacedDigit())
        .padding(6)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .onAppear { meter.start() }
        .onDisappear { meter.stop() }
    }
}

@MainActor
final class FrameMeter: ObservableObject {
    @Published var fps = 0
    @Published var drops = 0
    private var link: CADisplayLink?
    private var frames = 0
    private var windowStart: CFTimeInterval = 0
    private var last: CFTimeInterval = 0

    func start() {
        guard link == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stop() { link?.invalidate(); link = nil }

    @objc private func tick(_ link: CADisplayLink) {
        let expected = link.targetTimestamp - link.timestamp
        if last > 0, expected > 0, link.timestamp - last > expected * 1.5 { drops += 1 }
        last = link.timestamp
        if windowStart == 0 { windowStart = link.timestamp }
        frames += 1
        if link.timestamp - windowStart >= 1 {
            fps = frames
            frames = 0
            windowStart = link.timestamp
        }
    }
}
