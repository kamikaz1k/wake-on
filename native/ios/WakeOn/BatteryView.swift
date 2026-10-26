import Charts
import SwiftUI

/// Battery and energy use of the background listener (and voice calls), session by session.
struct BatteryView: View {
    @ObservedObject var monitor: BatteryMonitor
    @ObservedObject var wake: WakeController
    @State private var confirmClear = false

    var body: some View {
        List {
            Section {
                LabeledContent("Battery", value: Self.level(monitor.now.batteryLevel) + (monitor.now.charging ? " · charging" : ""))
                LabeledContent("Low Power Mode", value: monitor.now.lowPowerMode ? "On" : "Off")
                LabeledContent("Thermal state", value: Self.thermal(monitor.now.thermalState))
            } header: { Text("Now") } footer: {
                Text("iOS reports the battery level in coarse steps, so battery drop is meaningful over long, unplugged sessions. App power is the kernel's energy estimate for Wake On itself; it does not include the microphone hardware and iOS audio service.")
            }

            if let current = monitor.current {
                Section(current.kind == .listening ? "Listening now" : "Call now") {
                    SessionSummary(session: current)
                    PowerChart(session: current)
                }
            } else {
                Section("Listening now") {
                    Text(wake.enabled ? "Starting…" : "Listening is off. Enable it to start a session.")
                        .foregroundStyle(.secondary)
                }
            }

            Section("Past sessions") {
                if monitor.history.isEmpty {
                    Text("No sessions yet.").foregroundStyle(.secondary)
                }
                ForEach(monitor.history) { session in
                    NavigationLink {
                        SessionDetail(session: session)
                    } label: {
                        SessionRow(session: session)
                    }
                }
            }

            Section {
                if monitor.metricReports.isEmpty {
                    Text("Apple delivers these about once a day. None received yet.").foregroundStyle(.secondary)
                }
                ForEach(monitor.metricReports) { report in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(report.begins.formatted(date: .abbreviated, time: .omitted)).font(.headline)
                        if let audio = report.backgroundAudioSeconds { Text("Background audio: \(Self.duration(audio))") }
                        if let background = report.backgroundSeconds { Text("In background: \(Self.duration(background))") }
                        if let foreground = report.foregroundSeconds { Text("In foreground: \(Self.duration(foreground))") }
                        if let cpu = report.cpuSeconds { Text("CPU time: \(Self.duration(cpu))") }
                    }
                    .font(.subheadline)
                }
            } header: { Text("Daily reports (MetricKit)") }

            Section {
                ShareLink("Export sessions", item: BatteryMonitor.fileURL)
                Button("Clear past sessions", role: .destructive) { confirmClear = true }
                    .disabled(monitor.history.isEmpty)
            }
        }
        .navigationTitle("Battery")
        .confirmationDialog("Delete all past battery sessions?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { monitor.clearHistory() }
        }
    }

    static func level(_ value: Float) -> String { value < 0 ? "Unknown" : "\(Int((value * 100).rounded())) %" }
    static func thermal(_ raw: Int) -> String { ["Nominal", "Fair", "Serious", "Critical"][min(max(raw, 0), 3)] }
    static func duration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        if total >= 3600 { return "\(total / 3600) h \(total % 3600 / 60) min" }
        if total >= 60 { return "\(total / 60) min \(total % 60) s" }
        return "\(total) s"
    }
    static func mw(_ value: Double?) -> String { value.map { String(format: "%.0f mW", $0) } ?? "—" }
}

private struct SessionSummary: View {
    let session: EnergySession
    var body: some View {
        let stats = session.stats
        LabeledContent("Duration", value: BatteryView.duration(stats.seconds))
        LabeledContent("App power, average", value: BatteryView.mw(stats.averageMilliwatts))
        LabeledContent("App power, in background", value: BatteryView.mw(stats.backgroundMilliwatts))
        LabeledContent("App energy", value: String(format: "%.1f mWh", stats.milliwattHours))
        LabeledContent("CPU", value: stats.cpuPercent.map { String(format: "%.1f %% of a core", $0) } ?? "—")
        LabeledContent("CPU wake-ups", value: stats.wakeupsPerSecond.map { String(format: "%.0f / s", $0) } ?? "—")
        LabeledContent("Battery used (unplugged)", value: stats.batteryDrop.map { String(format: "%.0f %%", $0) } ?? "—")
        LabeledContent("Battery per hour", value: stats.batteryDropPerHour.map { String(format: "%.1f %% / h", $0) } ?? "—")
        if session.kind == .listening { LabeledContent("Wakes detected", value: "\(session.wakes)") }
        if let reason = session.endReason {
            LabeledContent("Ended because", value: reason).font(.caption)
        }
    }
}

private struct SessionRow: View {
    let session: EnergySession
    var body: some View {
        let stats = session.stats
        VStack(alignment: .leading, spacing: 2) {
            Text("\(session.kind == .listening ? "Listening" : "Call") · \(session.started.formatted(date: .abbreviated, time: .shortened))")
                .font(.headline)
            Text("\(BatteryView.duration(stats.seconds)) · \(BatteryView.mw(stats.averageMilliwatts))"
                 + (stats.batteryDropPerHour.map { String(format: " · %.1f %%/h", $0) } ?? ""))
                .font(.subheadline).foregroundStyle(.secondary)
            if let reason = session.endReason, reason != "user" {
                Text("Ended: \(reason)").font(.caption).foregroundStyle(.orange)
            }
        }
    }
}

private struct SessionDetail: View {
    let session: EnergySession
    var body: some View {
        List {
            Section { SessionSummary(session: session) }
            Section("Power over time") { PowerChart(session: session) }
        }
        .navigationTitle(session.kind == .listening ? "Listening session" : "Call")
    }
}

/// App power per sampling interval, with background intervals shaded.
private struct PowerChart: View {
    let session: EnergySession

    private struct Point: Identifiable {
        let id: Int
        let minutes: Double
        let milliwatts: Double
        let background: Bool
        let battery: Double?
    }

    private var points: [Point] {
        guard let start = session.samples.first?.uptime else { return [] }
        return zip(session.samples, session.samples.dropFirst()).enumerated().compactMap { index, pair in
            let (a, b) = pair
            let seconds = b.uptime - a.uptime
            guard seconds > 0.5 else { return nil }
            let joules = Double(b.energyNanojoules &- a.energyNanojoules) / 1e9
            return Point(id: index, minutes: (b.uptime - start) / 60, milliwatts: joules / seconds * 1000,
                         background: a.inBackground && b.inBackground,
                         battery: b.batteryLevel >= 0 ? Double(b.batteryLevel) * 100 : nil)
        }
    }

    var body: some View {
        if points.count < 2 {
            Text("The chart appears after a minute or two.").foregroundStyle(.secondary)
        } else {
            Chart(points) { point in
                LineMark(x: .value("Minutes", point.minutes), y: .value("mW", point.milliwatts))
                    .interpolationMethod(.stepEnd)
                    .foregroundStyle(by: .value("App state", point.background ? "Background" : "Foreground"))
            }
            .chartXAxisLabel("minutes")
            .chartYAxisLabel("app power, mW")
            .frame(height: 180)
        }
    }
}
