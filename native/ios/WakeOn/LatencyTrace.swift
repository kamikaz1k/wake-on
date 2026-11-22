import Foundation
import os
import UIKit

/// Monotonic timing, metadata only. File writes never run on the audio callback.
final class LatencyTrace {
    static let processStart = DispatchTime.now().uptimeNanoseconds
    private static var requestCount = 0 // initialized only by main-thread capture/playback entry points
    static let processID = UUID().uuidString
    static let fileURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("latency.jsonl")
    private static let writer = DispatchQueue(label: "wake.metrics.file", qos: .utility)
    private static let log = OSLog(subsystem: "com.kamikaz1k.wakeon", category: "latency")
    let id = UUID().uuidString
    let origin: UInt64
    private let lock = NSLock()
    private var events: [[String: Any]] = []
    private var names = Set<String>()
    private var finished = false
    private let metadata: [String: Any]

    init(source: String, origin: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        self.origin = origin
        Self.requestCount += 1
        var input = "microphone"
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--fixture") || ProcessInfo.processInfo.arguments.contains("--silence") { input = "fixture" }
        #endif
        #if targetEnvironment(simulator)
        let platform = "simulator"
        #else
        let platform = "device"
        #endif
        metadata = ["schema": 1, "runID": id, "processID": Self.processID,
                    "source": source, "input": input, "requestNumberInProcess": Self.requestCount,
                    "deviceFamily": UIDevice.current.model, "platform": platform,
                    "os": UIDevice.current.systemVersion,
                    "build": Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown",
                    "startedAt": ISO8601DateFormatter().string(from: Date()),
                    "ageSinceAppInitMs": Double(origin >= Self.processStart ? origin - Self.processStart : 0) / 1e6,
                    "appState": UIApplication.shared.applicationState.rawValue]
        mark("request", at: origin)
    }

    func mark(_ name: String, at time: UInt64 = DispatchTime.now().uptimeNanoseconds,
              fields: [String: Any] = [:], once: Bool = false) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished, !once || !names.contains(name) else { return }
        names.insert(name)
        var event = fields
        event["name"] = name
        event["elapsedMs"] = Double(time >= origin ? time - origin : 0) / 1e6
        events.append(event)
        os_signpost(.event, log: Self.log, name: "Capture milestone", "%{public}@ %{public}@", id, name)
    }

    func finish(_ outcome: String, fields: [String: Any] = [:]) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        var report = metadata
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if let index = args.firstIndex(of: "--test-id"), index + 1 < args.count { report["testID"] = args[index + 1] }
        #endif
        #if DEBUG
        report["invocation"] = ProcessInfo.processInfo.arguments.contains("--intent-test") ? "intent_handler_harness" : "system_or_ui"
        #else
        report["invocation"] = "system_or_ui"
        #endif
        report["outcome"] = outcome
        report["events"] = events
        report["summary"] = fields
        lock.unlock()
        Self.writer.async {
            do {
                let manager = FileManager.default
                // Bound retained diagnostics to approximately 4 MB plus one run.
                if let size = try? manager.attributesOfItem(atPath: Self.fileURL.path)[.size] as? NSNumber,
                   size.intValue > 4_000_000 {
                    let previous = Self.fileURL.appendingPathExtension("previous")
                    try? manager.removeItem(at: previous)
                    try manager.moveItem(at: Self.fileURL, to: previous)
                }
                if !manager.fileExists(atPath: Self.fileURL.path) { manager.createFile(atPath: Self.fileURL.path, contents: nil) }
                let handle = try FileHandle(forWritingTo: Self.fileURL)
                defer { try? handle.close() }
                try handle.seekToEnd()
                var data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
                data.append(10)
                try handle.write(contentsOf: data)
            } catch { NSLog("WAKE_METRICS write failed: %@", error.localizedDescription) }
        }
    }
}
