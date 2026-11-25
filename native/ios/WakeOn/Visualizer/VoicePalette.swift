import SwiftUI

/// Colors for the particle and wave visualizers: one per speaker, plus a resting color.
/// (The bloom orb keeps its own crimson whatever the palette.)
struct VoicePalette: Hashable, Identifiable, Sendable {
    var name: String
    var user: SIMD3<Float>
    var assistant: SIMD3<Float>
    var idle: SIMD3<Float>
    var id: String { name }

    init(name: String, user: UInt32, assistant: UInt32, idle: UInt32) {
        self.name = name
        self.user = Self.rgb(user)
        self.assistant = Self.rgb(assistant)
        self.idle = Self.rgb(idle)
    }

    /// The sky orb's original blue, at rest and for both speakers (Pixie a touch more violet).
    static let daylight = VoicePalette(name: "Daylight", user: 0x3D91FA, assistant: 0x5C86FF, idle: 0x3D91FA)
    static let mintLavender = VoicePalette(name: "Mint and lavender", user: 0x2FC79A, assistant: 0x9A90F0, idle: 0x6E7280)
    static let ocean = VoicePalette(name: "Ocean", user: 0x38D6F5, assistant: 0x4F7BFF, idle: 0x5F6F86)
    static let sunset = VoicePalette(name: "Sunset", user: 0xFFB547, assistant: 0xFF5C8A, idle: 0x7D6A70)
    static let aurora = VoicePalette(name: "Aurora", user: 0x7CF5A8, assistant: 0xD17CFF, idle: 0x5E7470)
    static let mono = VoicePalette(name: "Mono", user: 0xF2F2F2, assistant: 0xC9C9D1, idle: 0x6A6A70)

    static let presets: [VoicePalette] = [.daylight, .mintLavender, .ocean, .sunset, .aurora, .mono]
    static let `default` = VoicePalette.daylight

    static func named(_ name: String) -> VoicePalette { presets.first { $0.name == name } ?? .default }

    /// The color for this moment: the speaker's color while someone talks, idle otherwise.
    func current(_ frame: VoiceFrame) -> SIMD3<Float> {
        let speaking = min(1, frame.level * 3)
        let base = user + (assistant - user) * frame.mix
        return idle + (base - idle) * max(speaking, frame.thinking * 0.8)
    }

    /// The sky orb's color: like `current`, but at rest it shows Pixie's color, softened toward idle,
    /// instead of the grey idle color, so the chosen palette shows when nobody is talking. (An
    /// average of both speakers washes out to grey for complementary pairs like Aurora's.)
    func sky(_ frame: VoiceFrame) -> SIMD3<Float> {
        let speaking = min(1, frame.level * 3)
        let base = user + (assistant - user) * frame.mix
        return skyRest + (base - skyRest) * max(speaking, frame.thinking * 0.8)
    }

    var skyRest: SIMD3<Float> { idle + (assistant - idle) * 0.75 }

    static func color(_ c: SIMD3<Float>, opacity: Double = 1) -> Color {
        Color(.sRGB, red: Double(c.x), green: Double(c.y), blue: Double(c.z), opacity: opacity)
    }

    private static func rgb(_ hex: UInt32) -> SIMD3<Float> {
        SIMD3(Float((hex >> 16) & 0xFF), Float((hex >> 8) & 0xFF), Float(hex & 0xFF)) / 255
    }
}
