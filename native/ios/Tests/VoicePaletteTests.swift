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

    /// "Mint and lavender" rested lavender; a palette should rest at the color it's named for.
    func testGreenPalettesRestGreen() {
        for palette in [VoicePalette.mintLavender, .meadow] {
            let c = palette.sky(VoiceFrame())
            XCTAssertGreaterThan(c.y, max(c.x, c.z), palette.name)
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

    /// Colors looked like an average of the two speakers: they dipped toward rest between
    /// syllables and blended whenever both levels were up. Through a turn they must stay at the
    /// speaker's full color (reported 2026-11-24).
    @MainActor
    func testColorsStayAtTheSpeakersFullColorThroughATurn() {
        let signal = VoiceSignal.simulated()  // user 1.5–5 s, thinking, assistant 6.8–11.3 s
        let palette = VoicePalette.sunset
        let start = Date(timeIntervalSinceReferenceDate: 1_000_000)
        var worstUser: Float = 0, worstAssistant: Float = 0
        for i in 0...Int(11.2 * 60) {
            let t = Double(i) / 60
            let frame = signal.frame(at: start.addingTimeInterval(t))
            if t > 2.2 && t < 5 {
                worstUser = max(worstUser, simd_distance(palette.current(frame), palette.user))
                worstUser = max(worstUser, simd_distance(palette.sky(frame), palette.user))
            }
            if t > 7.5 && t < 11.2 {
                worstAssistant = max(worstAssistant, simd_distance(palette.current(frame), palette.assistant))
                worstAssistant = max(worstAssistant, simd_distance(palette.sky(frame), palette.assistant))
            }
        }
        XCTAssertLessThan(worstUser, 0.05)
        XCTAssertLessThan(worstAssistant, 0.05)
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
