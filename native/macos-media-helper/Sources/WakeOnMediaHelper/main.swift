import AVFoundation
import Foundation

private let maximumFrameBytes = 4 * 1024 * 1024
private let playbackSampleRate = 24_000.0

private enum FrameType {
    static let ready = Character("R").asciiValue!
    static let audio = Character("A").asciiValue!
    static let playback = Character("P").asciiValue!
    static let playbackDone = Character("D").asciiValue!
    static let clear = Character("C").asciiValue!
    static let quit = Character("Q").asciiValue!
    static let error = Character("E").asciiValue!
}

private final class FramedWriter {
    private let handle: FileHandle
    private let queue = DispatchQueue(label: "wake-on-media-helper.writer")

    init(handle: FileHandle = .standardOutput) {
        self.handle = handle
    }

    func send(_ type: UInt8, payload: Data = Data()) {
        queue.async { [handle] in
            var length = UInt32(payload.count).bigEndian
            var frame = Data([type])
            withUnsafeBytes(of: &length) { frame.append(contentsOf: $0) }
            frame.append(payload)
            try? handle.write(contentsOf: frame)
        }
    }

    func sendJSON(_ type: UInt8, value: [String: Any]) {
        guard let payload = try? JSONSerialization.data(withJSONObject: value) else { return }
        send(type, payload: payload)
    }
}

private final class VoiceProcessingEngine {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let writer: FramedWriter
    private let playbackFormat: AVAudioFormat
    private let stateLock = NSLock()
    private var playbackGeneration: UInt64 = 0

    init(writer: FramedWriter) {
        self.writer = writer
        playbackFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: playbackSampleRate,
            channels: 1,
            interleaved: false
        )!
    }

    func start() throws {
        guard microphoneAccessAllowed() else {
            throw NSError(
                domain: "WakeOnMediaHelper",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Microphone access was denied"]
            )
        }

        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: playbackFormat)
        try engine.inputNode.setVoiceProcessingEnabled(true)

        let inputFormat = engine.inputNode.outputFormat(forBus: 0)
        let captureFrames = AVAudioFrameCount(max(1, round(inputFormat.sampleRate * 0.02)))
        engine.inputNode.installTap(
            onBus: 0,
            bufferSize: captureFrames,
            format: inputFormat
        ) { [weak self] buffer, _ in
            self?.emitCapture(buffer)
        }

        engine.prepare()
        try engine.start()
        player.play()

        writer.sendJSON(
            FrameType.ready,
            value: [
                "capture_sample_rate": Int(inputFormat.sampleRate.rounded()),
                "capture_channels": Int(inputFormat.channelCount),
                "playback_sample_rate": Int(playbackSampleRate),
                "output_latency_ms": engine.outputNode.presentationLatency * 1_000,
                "voice_processing": engine.inputNode.isVoiceProcessingEnabled,
            ]
        )
    }

    func schedulePlayback(chunkID: UInt64, pcm16: Data) {
        let sampleCount = pcm16.count / MemoryLayout<Int16>.size
        guard sampleCount > 0,
              pcm16.count.isMultiple(of: MemoryLayout<Int16>.size),
              let buffer = AVAudioPCMBuffer(
                  pcmFormat: playbackFormat,
                  frameCapacity: AVAudioFrameCount(sampleCount)
              ),
              let channel = buffer.floatChannelData?[0]
        else { return }

        buffer.frameLength = AVAudioFrameCount(sampleCount)
        pcm16.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            for index in 0 ..< sampleCount {
                channel[index] = Float(Int16(littleEndian: samples[index])) / 32_768.0
            }
        }

        stateLock.lock()
        let generation = playbackGeneration
        stateLock.unlock()
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) {
            [weak self] _ in
            guard let self else { return }
            self.stateLock.lock()
            let stillCurrent = generation == self.playbackGeneration
            self.stateLock.unlock()
            guard stillCurrent else { return }
            var encodedID = chunkID.bigEndian
            let payload = withUnsafeBytes(of: &encodedID) { Data($0) }
            self.writer.send(FrameType.playbackDone, payload: payload)
        }
        if !player.isPlaying { player.play() }
    }

    func clearPlayback() {
        stateLock.lock()
        playbackGeneration &+= 1
        stateLock.unlock()
        player.stop()
        player.reset()
        player.play()
    }

    func stop() {
        clearPlayback()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    private func emitCapture(_ buffer: AVAudioPCMBuffer) {
        guard let channels = buffer.floatChannelData else { return }
        let frameCount = Int(buffer.frameLength)
        let channelCount = max(1, Int(buffer.format.channelCount))
        var output = Data(count: frameCount * MemoryLayout<Int16>.size)
        output.withUnsafeMutableBytes { raw in
            let destination = raw.bindMemory(to: Int16.self)
            for frame in 0 ..< frameCount {
                var mixed: Float = 0
                for channel in 0 ..< channelCount {
                    mixed += channels[channel][frame]
                }
                let sample = max(-1, min(1, mixed / Float(channelCount)))
                destination[frame] = Int16(
                    max(-32_768, min(32_767, Int((sample * 32_767).rounded())))
                ).littleEndian
            }
        }
        writer.send(FrameType.audio, payload: output)
    }

    private func microphoneAccessAllowed() -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .denied, .restricted:
            return false
        case .notDetermined:
            let semaphore = DispatchSemaphore(value: 0)
            var allowed = false
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                allowed = granted
                semaphore.signal()
            }
            semaphore.wait()
            return allowed
        @unknown default:
            return false
        }
    }
}

private func readExactly(_ count: Int, from handle: FileHandle) -> Data? {
    var result = Data()
    while result.count < count {
        guard let chunk = try? handle.read(upToCount: count - result.count),
              !chunk.isEmpty
        else { return nil }
        result.append(chunk)
    }
    return result
}

private func decodeUInt64(_ data: Data) -> UInt64? {
    guard data.count >= MemoryLayout<UInt64>.size else { return nil }
    return data.prefix(MemoryLayout<UInt64>.size).withUnsafeBytes {
        UInt64(bigEndian: $0.loadUnaligned(as: UInt64.self))
    }
}

private let writer = FramedWriter()
private let voiceEngine = VoiceProcessingEngine(writer: writer)

do {
    try voiceEngine.start()
} catch {
    writer.sendJSON(FrameType.error, value: ["message": error.localizedDescription])
    Thread.sleep(forTimeInterval: 0.05)
    exit(2)
}

let input = FileHandle.standardInput
commandLoop: while let header = readExactly(5, from: input) {
    let type = header[header.startIndex]
    let length = header.dropFirst().withUnsafeBytes {
        UInt32(bigEndian: $0.loadUnaligned(as: UInt32.self))
    }
    guard length <= maximumFrameBytes,
          let payload = readExactly(Int(length), from: input)
    else {
        writer.sendJSON(FrameType.error, value: ["message": "Invalid protocol frame"])
        break
    }

    switch type {
    case FrameType.playback:
        guard let chunkID = decodeUInt64(payload) else { continue }
        voiceEngine.schedulePlayback(
            chunkID: chunkID,
            pcm16: payload.dropFirst(MemoryLayout<UInt64>.size)
        )
    case FrameType.clear:
        voiceEngine.clearPlayback()
    case FrameType.quit:
        break commandLoop
    default:
        writer.sendJSON(FrameType.error, value: ["message": "Unknown command frame"])
    }
}

voiceEngine.stop()
