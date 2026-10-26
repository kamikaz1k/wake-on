import XCTest
@testable import WakeOn

final class VoiceSpectrumTests: XCTestCase {
    private func analyse(_ samples: [Float], rate: Double = 48_000) -> (db: Float, bands: [Float]) {
        let analyzer = SpectrumAnalyzer()
        var bands = [Float](repeating: 0, count: VoiceFrame.bandCount)
        var db: Float = 0
        // Run a few frames so the 0.55 smoothing settles, like a live analyser.
        for _ in 0..<8 { db = samples.withUnsafeBufferPointer { analyzer.analyse($0.baseAddress!, sampleRate: rate, bands: &bands) } }
        return (db, bands)
    }

    func testSineLevelAndBand() {
        // 1 kHz at amplitude 0.1: RMS = 0.1/√2 ≈ −23 dBFS; 1 kHz falls in band 17 of 80 Hz–8 kHz.
        let samples = (0..<SpectrumAnalyzer.size).map { Float(0.1 * sin(2 * Double.pi * 1000 * Double($0) / 48_000)) }
        let result = analyse(samples)
        XCTAssertEqual(result.db, -23.0, accuracy: 0.5)
        let peak = result.bands.indices.max { result.bands[$0] < result.bands[$1] }!
        XCTAssertTrue((16...18).contains(peak), "peak band \(peak)")
        XCTAssertGreaterThan(result.bands[peak], 0.5)
        XCTAssertLessThan(result.bands[2], 0.2)
    }

    func testSilenceIsEmpty() {
        let result = analyse([Float](repeating: 0, count: SpectrumAnalyzer.size))
        XCTAssertLessThan(result.db, -100)
        XCTAssertEqual(result.bands.max(), 0)
    }

    func testRingKeepsNewestSamples() {
        let ring = AudioSampleRing()
        let input = (0..<10_000).map(Float.init)
        input.withUnsafeBufferPointer { ring.write($0.baseAddress!, count: $0.count) }
        var out = [Float](repeating: -1, count: 4)
        let written = out.withUnsafeMutableBufferPointer { ring.copyLatest(into: $0.baseAddress!, count: 4) }
        XCTAssertEqual(written, 10_000)
        XCTAssertEqual(out, [9996, 9997, 9998, 9999])
    }
}
