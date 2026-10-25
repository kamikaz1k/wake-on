import AVFoundation

final class MonoConverter {
    private let converter: AVAudioConverter
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                               channels: 1, interleaved: false)!
    private let inputRate: Double
    init(input: AVAudioFormat) throws {
        guard let converter = AVAudioConverter(from: input, to: format) else {
            throw WakeError.message("Cannot convert this microphone format.")
        }
        self.converter = converter
        inputRate = input.sampleRate
    }
    func convert(_ input: AVAudioPCMBuffer) throws -> [Float] {
        let size = AVAudioFrameCount(ceil(Double(input.frameLength) * 16_000 / inputRate) + 64)
        let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: size)!
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, state in
            if supplied { state.pointee = .noDataNow; return nil }
            supplied = true
            state.pointee = .haveData
            return input
        }
        if status == .error { throw error ?? WakeError.message("Audio conversion failed.") as NSError }
        return Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
    }
}
