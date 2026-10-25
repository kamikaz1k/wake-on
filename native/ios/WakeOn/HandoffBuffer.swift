import Foundation

struct AudioHandoff {
    let id = UUID()
    let phrase: String
    let startFrame: Int
    let wakeFrame: Int
    var samples: [Float]
    var complete = false
    var duration: Double { Double(samples.count) / 16_000 }
    var endFrame: Int { startFrame + samples.count }
}

/// One serial owner supplies all samples. The trigger block belongs to preroll exactly once.
struct HandoffBuffer {
    let capacity: Int
    let tailFrames: Int
    private var ring: [Float]
    private var position = 0
    private var filled = 0
    private(set) var frame = 0
    private(set) var handoff: AudioHandoff?

    init(prerollFrames: Int = 32_000, tailFrames: Int = 48_000) {
        precondition(prerollFrames > 0 && tailFrames > 0)
        capacity = prerollFrames
        self.tailFrames = tailFrames
        ring = Array(repeating: 0, count: prerollFrames)
    }

    mutating func append(_ samples: [Float]) {
        frame += samples.count
        if var capture = handoff {
            guard !capture.complete else { return }
            let remaining = tailFrames - (capture.endFrame - capture.wakeFrame)
            capture.samples.append(contentsOf: samples.prefix(remaining))
            capture.complete = capture.endFrame - capture.wakeFrame == tailFrames
            handoff = capture
            return
        }
        for sample in samples {
            ring[position] = sample
            position = (position + 1) % capacity
            filled = min(filled + 1, capacity)
        }
    }

    mutating func trigger(_ phrase: String) -> AudioHandoff {
        precondition(handoff == nil)
        let start = (position - filled + capacity) % capacity
        let samples = (0..<filled).map { ring[(start + $0) % capacity] }
        let result = AudioHandoff(phrase: phrase, startFrame: frame - filled,
                                  wakeFrame: frame, samples: samples)
        handoff = result
        return result
    }
}
