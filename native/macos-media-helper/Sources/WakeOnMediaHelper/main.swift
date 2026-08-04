import AVFoundation
import Foundation

private let maximumFrameBytes = 4 * 1024 * 1024
private let playbackSampleRate = 24_000.0
private let wakeSampleRate = 16_000.0

private enum FrameType {
    static let ready = Character("R").asciiValue!
    static let audio = Character("A").asciiValue!
    static let wakeAudio = Character("W").asciiValue!
    static let playback = Character("P").asciiValue!
    static let playbackDone = Character("D").asciiValue!
    static let state = Character("S").asciiValue!
    static let enableVoiceProcessing = Character("V").asciiValue!
    static let clear = Character("C").asciiValue!
    static let quit = Character("Q").asciiValue!
    static let error = Character("E").asciiValue!
}

private final class StreamingPCMResampler {
    let inputFormat: AVAudioFormat
    let outputFormat: AVAudioFormat
    private let converter: AVAudioConverter

    init(sourceSampleRate: Double, destinationSampleRate: Double) throws {
        guard let inputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sourceSampleRate,
            channels: 1,
            interleaved: false
        ), let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: destinationSampleRate,
            channels: 1,
            interleaved: false
        ), let converter = AVAudioConverter(from: inputFormat, to: outputFormat)
        else {
            throw NSError(
                domain: "WakeOnMediaHelper",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Could not create sample-rate converter"]
            )
        }
        self.inputFormat = inputFormat
        self.outputFormat = outputFormat
        self.converter = converter
        converter.sampleRateConverterQuality = AVAudioQuality.high.rawValue
    }

    func convert(_ input: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        let ratio = outputFormat.sampleRate / inputFormat.sampleRate
        let capacity = AVAudioFrameCount(
            max(1, ceil(Double(input.frameLength) * ratio) + 64)
        )
        guard let output = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: capacity
        ) else {
            throw NSError(
                domain: "WakeOnMediaHelper",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Could not allocate converter output"]
            )
        }

        var suppliedInput = false
        var conversionError: NSError?
        let status = converter.convert(
            to: output,
            error: &conversionError
        ) { _, inputStatus in
            if suppliedInput {
                inputStatus.pointee = .noDataNow
                return nil
            }
            suppliedInput = true
            inputStatus.pointee = .haveData
            return input
        }
        if status == .error {
            throw conversionError ?? NSError(
                domain: "WakeOnMediaHelper",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "Sample-rate conversion failed"]
            )
        }
        return output
    }
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
    private var engine: AVAudioEngine!
    private var player: AVAudioPlayerNode!
    private let writer: FramedWriter
    private let playbackFormat: AVAudioFormat
    private let stateLock = NSLock()
    private var playbackGeneration: UInt64 = 0
    private var wakeResampler: StreamingPCMResampler?
    private var voiceProcessingActive = false
    private var tapInstalled = false

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

        try rebuildGraph(voiceProcessing: false)
        sendState(type: FrameType.ready)
    }

    func setConversationActive(_ active: Bool) throws {
        if active == voiceProcessingActive {
            sendState(type: FrameType.state)
            return
        }

        try rebuildGraph(voiceProcessing: active)
        sendState(type: FrameType.state)
    }

    private func rebuildGraph(voiceProcessing active: Bool) throws {
        stopGraph()
        // The voice-processing Audio Unit cannot reliably be changed back to
        // raw I/O in place. Fully release the old graph before constructing
        // the replacement so Core Audio also releases its ducking session.
        player = nil
        engine = nil
        engine = AVAudioEngine()
        player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: playbackFormat)
        if active {
            try engine.inputNode.setVoiceProcessingEnabled(true)
            if #available(macOS 15.0, *) {
                engine.inputNode.voiceProcessingOtherAudioDuckingConfiguration =
                    AVAudioVoiceProcessingOtherAudioDuckingConfiguration(
                        enableAdvancedDucking: false,
                        duckingLevel: .min
                    )
            }
        }
        voiceProcessingActive = active
        try startGraph()
    }

    private func startGraph() throws {
        let inputFormat = engine.inputNode.outputFormat(forBus: 0)
        wakeResampler = try StreamingPCMResampler(
            sourceSampleRate: inputFormat.sampleRate,
            destinationSampleRate: wakeSampleRate
        )
        let captureFrames = AVAudioFrameCount(max(1, round(inputFormat.sampleRate * 0.02)))
        engine.inputNode.installTap(
            onBus: 0,
            bufferSize: captureFrames,
            format: inputFormat
        ) { [weak self] buffer, _ in
            self?.emitCapture(buffer)
        }
        tapInstalled = true

        engine.prepare()
        try engine.start()
        player.play()
    }

    private func sendState(type: UInt8) {
        let inputFormat = engine.inputNode.outputFormat(forBus: 0)
        writer.sendJSON(
            type,
            value: [
                "mode": voiceProcessingActive ? "aec" : "raw",
                "capture_sample_rate": Int(inputFormat.sampleRate.rounded()),
                "capture_channels": 1,
                "wake_sample_rate": Int(wakeSampleRate),
                "playback_sample_rate": Int(playbackSampleRate),
                "output_latency_ms": engine.outputNode.presentationLatency * 1_000,
                "voice_processing": engine.inputNode.isVoiceProcessingEnabled,
                "voice_processing_agc": engine.inputNode.isVoiceProcessingAGCEnabled,
                "other_audio_ducking": voiceProcessingActive ? "minimum" : "off",
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
        stopGraph()
    }

    private func stopGraph() {
        guard let engine, let player else { return }
        player.stop()
        player.reset()
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        engine.stop()
        wakeResampler = nil
    }

    private func emitCapture(_ buffer: AVAudioPCMBuffer) {
        guard let channels = buffer.floatChannelData else { return }
        let frameCount = Int(buffer.frameLength)
        let channelCount = max(1, Int(buffer.format.channelCount))
        guard let resampler = wakeResampler,
              let mono = AVAudioPCMBuffer(
                  pcmFormat: resampler.inputFormat,
                  frameCapacity: AVAudioFrameCount(frameCount)
              ), let monoChannel = mono.floatChannelData?[0]
        else { return }
        mono.frameLength = AVAudioFrameCount(frameCount)
        for frame in 0 ..< frameCount {
            var mixed: Float = 0
            for channel in 0 ..< channelCount {
                mixed += channels[channel][frame]
            }
            monoChannel[frame] = max(-1, min(1, mixed / Float(channelCount)))
        }
        writer.send(FrameType.audio, payload: encodePCM16(mono))
        do {
            let wake = try resampler.convert(mono)
            if wake.frameLength > 0 {
                writer.send(FrameType.wakeAudio, payload: encodePCM16(wake))
            }
        } catch {
            writer.sendJSON(FrameType.error, value: ["message": error.localizedDescription])
        }
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

private func encodePCM16(_ buffer: AVAudioPCMBuffer) -> Data {
    guard let channel = buffer.floatChannelData?[0] else { return Data() }
    let frameCount = Int(buffer.frameLength)
    var output = Data(count: frameCount * MemoryLayout<Int16>.size)
    output.withUnsafeMutableBytes { raw in
        let destination = raw.bindMemory(to: Int16.self)
        for frame in 0 ..< frameCount {
            let sample = max(-1, min(1, channel[frame]))
            destination[frame] = Int16(
                max(-32_768, min(32_767, Int((sample * 32_767).rounded())))
            ).littleEndian
        }
    }
    return output
}

private func decodePCM16(_ data: Data, format: AVAudioFormat) -> AVAudioPCMBuffer? {
    let sampleCount = data.count / MemoryLayout<Int16>.size
    guard data.count.isMultiple(of: MemoryLayout<Int16>.size),
          let buffer = AVAudioPCMBuffer(
              pcmFormat: format,
              frameCapacity: AVAudioFrameCount(sampleCount)
          ), let channel = buffer.floatChannelData?[0]
    else { return nil }
    buffer.frameLength = AVAudioFrameCount(sampleCount)
    data.withUnsafeBytes { raw in
        let samples = raw.bindMemory(to: Int16.self)
        for index in 0 ..< sampleCount {
            channel[index] = Float(Int16(littleEndian: samples[index])) / 32_768.0
        }
    }
    return buffer
}

private func runOfflineResampler(sourceRate: Double, destinationRate: Double) throws {
    let resampler = try StreamingPCMResampler(
        sourceSampleRate: sourceRate,
        destinationSampleRate: destinationRate
    )
    let input = FileHandle.standardInput.readDataToEndOfFile()
    let bytesPerSample = MemoryLayout<Int16>.size
    let chunkBytes = max(bytesPerSample, Int(sourceRate / 10) * bytesPerSample)
    var offset = 0
    while offset < input.count {
        let end = min(input.count, offset + chunkBytes)
        let chunk = input.subdata(in: offset ..< end)
        guard let buffer = decodePCM16(chunk, format: resampler.inputFormat) else {
            throw NSError(
                domain: "WakeOnMediaHelper",
                code: 5,
                userInfo: [NSLocalizedDescriptionKey: "Invalid offline PCM16 input"]
            )
        }
        let output = try resampler.convert(buffer)
        FileHandle.standardOutput.write(encodePCM16(output))
        offset = end
    }
}

if CommandLine.arguments.count == 4,
   CommandLine.arguments[1] == "--resample-stdin",
   let sourceRate = Double(CommandLine.arguments[2]),
   let destinationRate = Double(CommandLine.arguments[3])
{
    do {
        try runOfflineResampler(
            sourceRate: sourceRate,
            destinationRate: destinationRate
        )
        exit(0)
    } catch {
        FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
        exit(2)
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
    case FrameType.enableVoiceProcessing:
        do {
            try voiceEngine.setConversationActive(true)
        } catch {
            writer.sendJSON(FrameType.error, value: ["message": error.localizedDescription])
        }
    case FrameType.quit:
        break commandLoop
    default:
        writer.sendJSON(FrameType.error, value: ["message": "Unknown command frame"])
    }
}

voiceEngine.stop()
