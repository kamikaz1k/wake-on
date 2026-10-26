import Combine
import Darwin
import Foundation
import MetricKit
import UIKit

/// One reading of the app's own energy counters and the phone's battery.
struct EnergySample: Codable, Equatable {
    var date: Date
    /// Seconds of system uptime (monotonic).
    var uptime: Double
    /// 0–1, or -1 when unknown. iOS reports it in coarse steps.
    var batteryLevel: Float
    var charging: Bool
    var lowPowerMode: Bool
    /// ProcessInfo.ThermalState raw value (0 nominal … 3 critical).
    var thermalState: Int
    var inBackground: Bool
    /// The kernel's energy estimate for this process, in nanojoules (`task_energy`).
    var energyNanojoules: UInt64
    /// User + system CPU time of this process, in nanoseconds.
    var cpuNanoseconds: UInt64
    /// Times the CPU was woken for this process (interrupts + idle exits).
    var wakeups: UInt64

    static func now(inBackground: Bool) -> EnergySample {
        let counters = ProcessEnergy.read()
        let device = UIDevice.current
        return EnergySample(date: Date(), uptime: ProcessInfo.processInfo.systemUptime,
                            batteryLevel: device.batteryLevel,
                            charging: device.batteryState == .charging || device.batteryState == .full,
                            lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
                            thermalState: ProcessInfo.processInfo.thermalState.rawValue,
                            inBackground: inBackground,
                            energyNanojoules: counters.energy, cpuNanoseconds: counters.cpu, wakeups: counters.wakeups)
    }
}

/// A period with the wake listener on (or a voice call), with its samples.
struct EnergySession: Codable, Identifiable, Equatable {
    enum Kind: String, Codable { case listening, call }
    var id = UUID()
    var kind: Kind
    var started: Date
    var ended: Date?
    var samples: [EnergySample]
    var wakes = 0
    /// Why it ended: "user", "voice_call", "interruption …", "route_change …", and so on.
    var endReason: String?

    var stats: EnergyStats { EnergyStats(samples: samples) }
}

/// Figures derived from a session's samples.
struct EnergyStats: Equatable {
    var seconds: Double = 0
    var joules: Double = 0
    /// Average power of this process over the whole session, milliwatts.
    var averageMilliwatts: Double?
    /// Average power counting only intervals spent in the background.
    var backgroundMilliwatts: Double?
    var backgroundSeconds: Double = 0
    /// CPU time ÷ wall time, percent of one core.
    var cpuPercent: Double?
    var wakeupsPerSecond: Double?
    /// Battery percentage points lost while unplugged, and the rate per hour.
    var batteryDrop: Double?
    var batteryDropPerHour: Double?
    var unpluggedSeconds: Double = 0

    var milliwattHours: Double { joules / 3.6 }

    init() {}

    init(samples: [EnergySample]) {
        guard let first = samples.first, let last = samples.last, last.uptime > first.uptime else { return }
        seconds = last.uptime - first.uptime
        joules = Double(last.energyNanojoules &- first.energyNanojoules) / 1e9
        averageMilliwatts = joules / seconds * 1000
        cpuPercent = Double(last.cpuNanoseconds &- first.cpuNanoseconds) / 1e9 / seconds * 100
        wakeupsPerSecond = Double(last.wakeups &- first.wakeups) / seconds
        var backgroundJoules = 0.0
        var drop = 0.0
        for (a, b) in zip(samples, samples.dropFirst()) where b.uptime > a.uptime {
            let interval = b.uptime - a.uptime
            if a.inBackground && b.inBackground {
                backgroundSeconds += interval
                backgroundJoules += Double(b.energyNanojoules &- a.energyNanojoules) / 1e9
            }
            if !a.charging && !b.charging && a.batteryLevel >= 0 && b.batteryLevel >= 0 {
                unpluggedSeconds += interval
                drop += Double(a.batteryLevel - b.batteryLevel) * 100
            }
        }
        if backgroundSeconds > 0 { backgroundMilliwatts = backgroundJoules / backgroundSeconds * 1000 }
        if unpluggedSeconds > 0 {
            batteryDrop = drop
            batteryDropPerHour = drop / unpluggedSeconds * 3600
        }
    }
}

/// Reads this process's cumulative energy counters from the kernel.
enum ProcessEnergy {
    static func read() -> (energy: UInt64, cpu: UInt64, wakeups: UInt64) {
        var info = task_power_info_v2()
        var count = mach_msg_type_number_t(MemoryLayout<task_power_info_v2>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_POWER_INFO_V2), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return (0, 0, 0) }
        let cpu = info.cpu_energy.total_user + info.cpu_energy.total_system
        let wakeups = info.cpu_energy.task_interrupt_wakeups + info.cpu_energy.task_platform_idle_wakeups
        #if arch(arm64)
        return (info.task_energy, cpu, wakeups)
        #else
        return (0, cpu, wakeups) // the simulator has no energy counter
        #endif
    }
}

/// Records energy use while the wake listener runs (and during voice calls), keeps the
/// sessions on disk, and stores Apple's daily MetricKit reports.
@MainActor
final class BatteryMonitor: NSObject, ObservableObject {
    static let shared = BatteryMonitor()

    @Published private(set) var current: EnergySession?
    @Published private(set) var history: [EnergySession] = []
    @Published private(set) var metricReports: [MetricReport] = []
    @Published private(set) var now = EnergySample.now(inBackground: false)

    /// Sampling interval while a session runs. Short enough for a chart, cheap enough to ignore.
    static let interval: TimeInterval = 30
    /// Sessions shorter than this (a five-second direct recording) are not kept.
    static let minimumSeconds: Double = 10

    /// Finished sessions, rewritten only when a session ends.
    static let fileURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("battery-sessions.json")
    /// The running session: a header line, then one appended line per sample (cheap to write).
    static let currentURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("battery-current.jsonl")
    static let metricsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("metrickit", isDirectory: true)

    private var timer: Timer?
    private var bag: Set<AnyCancellable> = []
    private var inBackground = false
    private let writer = DispatchQueue(label: "battery.write", qos: .utility)

    private override init() {
        super.init()
        UIDevice.current.isBatteryMonitoringEnabled = true
        inBackground = UIApplication.shared.applicationState == .background
        load()
        // Sessions follow the wake listener and voice calls; a call pauses listening.
        WakeController.shared.$enabled.removeDuplicates().sink { [weak self] on in
            self?.transition(kind: .listening, active: on)
        }.store(in: &bag)
        VoiceSessionController.shared.$phase.map { $0 != .idle }.removeDuplicates().sink { [weak self] on in
            self?.transition(kind: .call, active: on)
        }.store(in: &bag)
        let center = NotificationCenter.default
        for (name, background) in [(UIApplication.didEnterBackgroundNotification, true),
                                   (UIApplication.willEnterForegroundNotification, false)] {
            center.publisher(for: name).sink { [weak self] _ in
                self?.inBackground = background
                self?.sample() // close the interval at the boundary so it is attributed correctly
            }.store(in: &bag)
        }
        for name in [UIDevice.batteryStateDidChangeNotification, Notification.Name.NSProcessInfoPowerStateDidChange] {
            center.publisher(for: name).receive(on: RunLoop.main).sink { [weak self] _ in self?.sample() }.store(in: &bag)
        }
        MXMetricManager.shared.add(self)
        loadMetricReports()
    }

    /// Call once at launch so sessions start with the first listener.
    func activate() {}

    func noteWake() {
        current?.wakes += 1
    }

    /// Called by the wake listener just before it stops, so the session records why.
    func noteListenerStop(reason: String) {
        guard current?.kind == .listening else { return }
        current?.endReason = reason
        append(["sample": EnergySample.now(inBackground: inBackground)], wakes: current?.wakes ?? 0, reason: reason)
    }

    func clearHistory() {
        history = []
        persist()
    }

    // MARK: - Sessions

    private func transition(kind: EnergySession.Kind, active: Bool) {
        if active {
            if let current, current.kind == kind { return }
            end()
            current = EnergySession(kind: kind, started: Date(), samples: [EnergySample.now(inBackground: inBackground)])
            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.sample() }
            }
            timer?.tolerance = 5
            startCurrentFile()
        } else if current?.kind == kind {
            end()
        }
    }

    private func end() {
        timer?.invalidate()
        timer = nil
        guard var session = current else { return }
        session.samples.append(EnergySample.now(inBackground: inBackground))
        session.ended = Date()
        current = nil
        if session.stats.seconds >= Self.minimumSeconds {
            history.insert(session, at: 0)
            if history.count > 100 { history.removeLast(history.count - 100) }
        }
        persist()
        writer.async { try? FileManager.default.removeItem(at: Self.currentURL) }
    }

    private func sample() {
        now = EnergySample.now(inBackground: inBackground)
        guard var session = current else { return }
        session.samples.append(now)
        current = session
        append(["sample": now], wakes: session.wakes)
    }

    // MARK: - Storage

    private struct Header: Codable { var id: UUID; var kind: EnergySession.Kind; var started: Date }
    private struct Line: Codable { var header: Header?; var sample: EnergySample?; var wakes: Int?; var reason: String? }

    private func persist() {
        let history = self.history
        writer.async {
            guard let data = try? JSONEncoder.iso.encode(history) else { return }
            try? data.write(to: Self.fileURL, options: .atomic)
        }
    }

    private func startCurrentFile() {
        guard let session = current else { return }
        let lines = [Line(header: Header(id: session.id, kind: session.kind, started: session.started))]
            + session.samples.map { Line(sample: $0) }
        writer.async {
            let data = lines.compactMap { try? JSONEncoder.iso.encode($0) }.map { $0 + Data([10]) }.reduce(Data(), +)
            try? data.write(to: Self.currentURL, options: .atomic)
        }
    }

    private func append(_ value: [String: EnergySample], wakes: Int, reason: String? = nil) {
        let line = Line(sample: value["sample"], wakes: wakes, reason: reason)
        writer.async {
            guard var data = try? JSONEncoder.iso.encode(line),
                  let handle = try? FileHandle(forWritingTo: Self.currentURL) else { return }
            data.append(10)
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        }
    }

    private func load() {
        if let data = try? Data(contentsOf: Self.fileURL),
           let stored = try? JSONDecoder.iso.decode([EnergySession].self, from: data) {
            history = stored
        }
        // The app was terminated mid-session (or iOS ended it): keep what was recorded.
        guard let text = try? String(contentsOf: Self.currentURL, encoding: .utf8) else { return }
        let lines = text.split(separator: "\n").compactMap { try? JSONDecoder.iso.decode(Line.self, from: Data($0.utf8)) }
        if let header = lines.first?.header {
            var orphan = EnergySession(id: header.id, kind: header.kind, started: header.started,
                                       samples: lines.compactMap(\.sample))
            orphan.wakes = lines.compactMap(\.wakes).last ?? 0
            orphan.endReason = lines.compactMap(\.reason).last ?? "app was terminated (no stop recorded)"
            orphan.ended = orphan.samples.last?.date
            if orphan.stats.seconds >= Self.minimumSeconds, !history.contains(where: { $0.id == orphan.id }) {
                history.insert(orphan, at: 0)
                persist()
            }
        }
        try? FileManager.default.removeItem(at: Self.currentURL)
    }

    // MARK: - MetricKit

    struct MetricReport: Identifiable {
        let id: String
        let begins: Date
        let ends: Date
        let backgroundAudioSeconds: Double?
        let foregroundSeconds: Double?
        let backgroundSeconds: Double?
        let cpuSeconds: Double?
    }

    private func loadMetricReports() {
        let manager = FileManager.default
        try? manager.createDirectory(at: Self.metricsDirectory, withIntermediateDirectories: true)
        for payload in MXMetricManager.shared.pastPayloads { store(payload) }
        let files = (try? manager.contentsOfDirectory(at: Self.metricsDirectory, includingPropertiesForKeys: nil)) ?? []
        metricReports = files.filter { $0.pathExtension == "json" }.compactMap(Self.report).sorted { $0.begins > $1.begins }
    }

    private func store(_ payload: MXMetricPayload) {
        let name = "metrics-\(Int(payload.timeStampBegin.timeIntervalSince1970)).json"
        try? payload.jsonRepresentation().write(to: Self.metricsDirectory.appendingPathComponent(name), options: .atomic)
    }

    /// Reads the fields this screen shows from a stored MetricKit JSON payload.
    nonisolated static func report(from url: URL) -> MetricReport? {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        func date(_ key: String) -> Date? { (json[key] as? String).flatMap(formatter.date) }
        func seconds(_ section: String, _ key: String) -> Double? {
            guard let text = (json[section] as? [String: Any])?[key] as? String else { return nil }
            // MetricKit writes measurements as "123 sec" or "1,234 ms".
            let parts = text.replacingOccurrences(of: ",", with: "").split(separator: " ")
            guard let value = parts.first.flatMap({ Double($0) }) else { return nil }
            return parts.last == "ms" ? value / 1000 : value
        }
        guard let begins = date("timeStampBegin"), let ends = date("timeStampEnd") else { return nil }
        return MetricReport(id: url.lastPathComponent, begins: begins, ends: ends,
                            backgroundAudioSeconds: seconds("applicationTimeMetrics", "cumulativeBackgroundAudioTime"),
                            foregroundSeconds: seconds("applicationTimeMetrics", "cumulativeForegroundTime"),
                            backgroundSeconds: seconds("applicationTimeMetrics", "cumulativeBackgroundTime"),
                            cpuSeconds: seconds("cpuMetrics", "cumulativeCPUTime"))
    }
}

extension BatteryMonitor: MXMetricManagerSubscriber {
    nonisolated func didReceive(_ payloads: [MXMetricPayload]) {
        Task { @MainActor in
            for payload in payloads { self.store(payload) }
            self.loadMetricReports()
        }
    }
}

extension JSONEncoder {
    static let iso: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}

extension JSONDecoder {
    static let iso: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
