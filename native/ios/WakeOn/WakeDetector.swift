import Foundation

enum WakeError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

/// Confined to the audio worker queue. Uses the same model and decoder settings as Python.
final class WakeDetector {
    private let spotter: OpaquePointer
    private let stream: OpaquePointer

    init(bundle: Bundle = .main) throws {
        var strings: [UnsafeMutablePointer<CChar>] = []
        defer { strings.forEach { free($0) } }
        func string(_ value: String) -> UnsafePointer<CChar> {
            let ptr = strdup(value)!
            strings.append(ptr)
            return UnsafePointer(ptr)
        }
        func path(_ name: String, _ ext: String) throws -> UnsafePointer<CChar> {
            guard let url = bundle.url(forResource: name, withExtension: ext) else {
                throw WakeError.message("Missing \(name).\(ext). Run scripts/setup.sh before building.")
            }
            return string(url.path)
        }
        var config = SherpaOnnxKeywordSpotterConfig()
        config.feat_config.sample_rate = 16_000
        config.feat_config.feature_dim = 80
        config.model_config.transducer.encoder = try path("encoder", "onnx")
        config.model_config.transducer.decoder = try path("decoder", "onnx")
        config.model_config.transducer.joiner = try path("joiner", "onnx")
        config.model_config.tokens = try path("tokens", "txt")
        config.model_config.num_threads = 1
        config.model_config.provider = string("cpu")
        config.keywords_file = try path("hey-lobby", "txt")
        config.max_active_paths = 16
        config.num_trailing_blanks = 0
        config.keywords_score = 2
        config.keywords_threshold = 0.1
        guard let spotter = SherpaOnnxCreateKeywordSpotter(&config) else {
            throw WakeError.message("Could not load the wake model.")
        }
        guard let stream = SherpaOnnxCreateKeywordStream(spotter) else {
            SherpaOnnxDestroyKeywordSpotter(spotter)
            throw WakeError.message("Could not create the wake stream.")
        }
        self.spotter = spotter
        self.stream = stream
    }

    deinit {
        SherpaOnnxDestroyOnlineStream(stream)
        SherpaOnnxDestroyKeywordSpotter(spotter)
    }

    func reset() { SherpaOnnxResetKeywordStream(spotter, stream) }

    func accept(_ samples: [Float]) -> String? {
        samples.withUnsafeBufferPointer {
            SherpaOnnxOnlineStreamAcceptWaveform(stream, 16_000, $0.baseAddress, Int32($0.count))
        }
        while SherpaOnnxIsKeywordStreamReady(spotter, stream) != 0 {
            SherpaOnnxDecodeKeywordStream(spotter, stream)
            if let result = SherpaOnnxGetKeywordResult(spotter, stream) {
                let phrase = result.pointee.keyword.map { String(cString: $0) } ?? ""
                SherpaOnnxDestroyKeywordResult(result)
                if !phrase.isEmpty { reset(); return phrase }
            }
        }
        return nil
    }
}
