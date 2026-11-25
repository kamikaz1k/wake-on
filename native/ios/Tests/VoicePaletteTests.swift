import simd
import XCTest
@testable import WakeOn

/// The sky orb rested at each palette's grey idle color, so switching colors in the gallery
/// showed only grey until someone spoke (reported 2026-11-24).
final class VoicePaletteTests: XCTestCase {
    private func saturation(_ c: SIMD3<Float>) -> Float {
        let hi = max(c.x, c.y, c.z), lo = min(c.x, c.y, c.z)
        return hi > 0 ? (hi - lo) / hi : 0
    }

    func testSkyOrbShowsThePaletteAtRest() {
        let rest = VoiceFrame()
        for palette in VoicePalette.presets where palette != .mono {
            XCTAssertGreaterThan(saturation(palette.sky(rest)), 0.3, palette.name)
        }
    }

    func testEachPaletteGivesADifferentRestingSky() {
        let colors = VoicePalette.presets.map { $0.sky(VoiceFrame()) }
        for i in colors.indices {
            for j in colors.indices where j > i {
                XCTAssertGreaterThan(simd_distance(colors[i], colors[j]), 0.1,
                                     "\(VoicePalette.presets[i].name) vs \(VoicePalette.presets[j].name)")
            }
        }
    }

    func testSkyOrbTakesTheSpeakersColorWhileTalking() {
        var frame = VoiceFrame()
        frame.level = 1
        frame.mix = 0
        XCTAssertEqual(VoicePalette.sunset.sky(frame), VoicePalette.sunset.user)
        frame.mix = 1
        XCTAssertEqual(VoicePalette.sunset.sky(frame), VoicePalette.sunset.assistant)
    }
}
