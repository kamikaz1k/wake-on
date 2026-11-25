import SwiftUI

enum VoiceVisualizerStyle: String, CaseIterable, Identifiable, Sendable {
    case skyOrb, waveOrb, bloomOrb, pills, particleSphere, ringTunnel, saturn, terrain, torus, radialSpectrum

    var id: String { rawValue }

    var title: String {
        switch self {
        case .skyOrb: "Sky orb"
        case .waveOrb: "Wave orb"
        case .bloomOrb: "Bloom orb"
        case .pills: "Bouncing pills"
        case .particleSphere: "Particle sphere"
        case .ringTunnel: "Ring tunnel"
        case .saturn: "Saturn"
        case .terrain: "Particle terrain"
        case .torus: "Particle torus"
        case .radialSpectrum: "Radial spectrum"
        }
    }

    var summary: String {
        switch self {
        case .skyOrb: "Cloud sphere that scales with the voice"
        case .waveOrb: "Live spectrum as waves on a glass sphere"
        case .bloomOrb: "Crimson flower that opens with the voice"
        case .pills: "Four bars, one per frequency range"
        case .particleSphere: "Each band of dots follows one frequency"
        case .ringTunnel: "Rings carry the recent waveform"
        case .saturn: "Bouncy sphere with a 3-second ring"
        case .terrain: "Loudness ripples across a dot grid"
        case .torus: "Voice pulses travel around a donut"
        case .radialSpectrum: "Ring of springy 3D bars"
        }
    }
}

/// An animated voice visualizer for a two-way conversation.
///
/// `VoiceVisualizer()` is the sky orb driven by the live call audio. Pick another
/// `style`, `palette` (not used by the sky or bloom orbs), or `signal` (for example
/// `VoiceSignal.simulated()` in previews).
struct VoiceVisualizer: View {
    var style: VoiceVisualizerStyle = .skyOrb
    var palette: VoicePalette = .default
    var signal: VoiceSignal = .live

    @State private var motion = VisualizerMotion()

    var body: some View {
        TimelineView(.animation) { timeline in
            let frame = signal.frame(at: timeline.date)
            Group {
                switch style {
                case .skyOrb: SkyOrbView(frame: frame)
                case .waveOrb: WaveOrbView(frame: frame, palette: palette)
                case .bloomOrb: BloomOrbView(frame: frame)
                default:
                    Canvas { context, size in
                        VisualizerPainter(style: style, frame: frame, palette: palette, motion: motion)
                            .paint(&context, size: size)
                    }
                }
            }
            .accessibilityElement()
            .accessibilityLabel("Voice activity")
            .accessibilityValue(Self.describe(frame))
        }
    }

    private static func describe(_ frame: VoiceFrame) -> String {
        if frame.isUserSpeaking && frame.isAssistantSpeaking { return "Both talking" }
        if frame.isUserSpeaking { return "You're speaking" }
        if frame.isAssistantSpeaking { return "Assistant speaking" }
        if frame.thinking > 0.5 { return "Thinking" }
        return "Quiet"
    }
}

// MARK: - Orbs (Metal)

private struct SkyOrbView: View {
    let frame: VoiceFrame
    var body: some View {
        let f = frame
        Rectangle()
            .fill(.black)
            .visualEffect { content, proxy in
                content.colorEffect(ShaderLibrary.voiceSkyOrb(
                    .float2(proxy.size), .float(f.time.truncatingRemainder(dividingBy: 3600)), .float(f.skyFlow),
                    .float(f.level), .float(f.spring), .float(f.thinking), .float(f.mix)))
            }
    }
}

private struct BloomOrbView: View {
    let frame: VoiceFrame
    var body: some View {
        let f = frame
        Rectangle()
            .fill(.black)
            .visualEffect { content, proxy in
                content.colorEffect(ShaderLibrary.voiceBloomOrb(
                    .float2(proxy.size), .float(f.time.truncatingRemainder(dividingBy: 3600)), .float(f.skyFlow),
                    .float(f.level), .float(f.spring), .float(f.thinking), .float(f.mix)))
            }
    }
}

private struct WaveOrbView: View {
    let frame: VoiceFrame
    let palette: VoicePalette
    var body: some View {
        let f = frame, user = palette.user, assistant = palette.assistant, current = palette.current(frame)
        Rectangle()
            .fill(.black)
            .visualEffect { content, proxy in
                content.colorEffect(ShaderLibrary.voiceWaveOrb(
                    .float2(proxy.size), .float(f.time.truncatingRemainder(dividingBy: 3600)), .float(f.waveRotation),
                    .float(f.level), .float(f.spring), .float(f.thinking),
                    .float3(user.x, user.y, user.z), .float3(assistant.x, assistant.y, assistant.z),
                    .float3(current.x, current.y, current.z), .floatArray(f.waveHistory)))
            }
    }
}

// MARK: - Canvas visualizers

/// Per-view springs and offsets that persist between frames.
final class VisualizerMotion {
    struct Spring {
        var x: Float = 0, v: Float = 0
        mutating func step(to target: Float, stiffness: Float, damping: Float) {
            v += (target - x) * stiffness
            v *= damping
            x += v
        }
    }
    var pills = [Spring](repeating: Spring(), count: 4)
    var tips = [Spring](repeating: Spring(), count: 64)
    var tunnelOffset: Float = 0
    var lastTime: Float = -1

    /// How many 60 Hz spring steps to run for this frame.
    func steps(at time: Float) -> Int {
        defer { lastTime = time }
        guard lastTime >= 0 else { return 1 }
        return max(0, min(4, Int(((time - lastTime) * 60).rounded())))
    }
}

private struct VisualizerPainter {
    let style: VoiceVisualizerStyle
    let frame: VoiceFrame
    let palette: VoicePalette
    let motion: VisualizerMotion

    private static let fibonacci: [(SIMD3<Float>, Int)] = (0..<520).map { i in
        let y = 1 - 2 * (Float(i) + 0.5) / 520, r = (1 - y * y).squareRoot(), a = Float(i) * 2.39996
        return (SIMD3(cos(a) * r, y, sin(a) * r), min(31, Int((y + 1) / 2 * 31.99)))
    }

    private var t: Float { frame.time }
    private var color: SIMD3<Float> { palette.current(frame) }

    func paint(_ ctx: inout GraphicsContext, size: CGSize) {
        let steps = motion.steps(at: frame.time)
        switch style {
        case .pills: pills(&ctx, size, steps)
        case .particleSphere: sphere(&ctx, size)
        case .ringTunnel: tunnel(&ctx, size)
        case .saturn: saturn(&ctx, size)
        case .terrain: terrain(&ctx, size)
        case .torus: torus(&ctx, size)
        case .radialSpectrum: radial(&ctx, size, steps)
        case .skyOrb, .waveOrb, .bloomOrb: break
        }
    }

    // MARK: Helpers

    private func rotate(_ p: SIMD3<Float>, _ ay: Float, _ ax: Float) -> SIMD3<Float> {
        var x = p.x, y = p.y, z = p.z
        var c = cos(ay), s = sin(ay)
        (x, z) = (x * c + z * s, -x * s + z * c)
        c = cos(ax); s = sin(ax)
        (y, z) = (y * c - z * s, y * s + z * c)
        return SIMD3(x, y, z)
    }

    private struct Projection {
        let center: CGPoint, scale: Float
        func callAsFunction(_ p: SIMD3<Float>) -> (CGPoint, Float) {
            let f = 3 / (3 + p.z)
            return (CGPoint(x: center.x + CGFloat(p.x * f * scale), y: center.y + CGFloat(p.y * f * scale)), f)
        }
    }

    private func projection(_ size: CGSize, _ k: Float) -> Projection {
        Projection(center: CGPoint(x: size.width / 2, y: size.height / 2), scale: Float(min(size.width, size.height)) * k)
    }

    /// Round dots grouped by opacity, so a thousand dots cost a dozen fills.
    private struct Dots {
        var buckets = [Path](repeating: Path(), count: 12)
        mutating func add(_ at: CGPoint, size: Float, alpha: Float) {
            guard alpha > 0.01 else { return }
            let s = CGFloat(max(1.6, size * 1.35))
            buckets[min(11, Int(alpha * 12))].addEllipse(in: CGRect(x: at.x - s / 2, y: at.y - s / 2, width: s, height: s))
        }
        func draw(_ ctx: inout GraphicsContext, _ color: SIMD3<Float>) {
            for (i, path) in buckets.enumerated() where !path.isEmpty {
                ctx.fill(path, with: .color(VoicePalette.color(color, opacity: (Double(i) + 0.5) / 12)))
            }
        }
    }

    private func history(_ x: Float) -> Float {
        frame.history[min(VoiceFrame.historyCount - 1, max(0, Int(x * Float(VoiceFrame.historyCount - 1))))]
    }

    // MARK: Styles

    private func pills(_ ctx: inout GraphicsContext, _ size: CGSize, _ steps: Int) {
        let w = Float(min(size.width, size.height)) * 0.12, gap = w * 0.45, total = 4 * w + 3 * gap
        let groups = [(0, 6), (6, 13), (13, 21), (21, 32)]
        let c = color + (SIMD3<Float>(repeating: 1) - color) * 0.55
        for i in 0..<4 {
            let peak = frame.bands[groups[i].0..<groups[i].1].max() ?? 0
            let target = pow(peak, 1.4) * 2.2 + max(0, sin(t * 5 - Float(i) * 0.9)) * 0.45 * frame.thinking
            for _ in 0..<steps { motion.pills[i].step(to: target, stiffness: 0.24, damping: 0.7) }
            let h = w * (1 + max(0, motion.pills[i].x) * 2.6)
            let x = Float(size.width) / 2 - total / 2 + Float(i) * (w + gap)
            let rect = CGRect(x: CGFloat(x), y: size.height / 2 - CGFloat(h / 2), width: CGFloat(w), height: CGFloat(h))
            ctx.fill(Path(roundedRect: rect, cornerRadius: CGFloat(w / 2)), with: .color(VoicePalette.color(c, opacity: 0.95)))
        }
    }

    private func sphere(_ ctx: inout GraphicsContext, _ size: CGSize) {
        let project = projection(size, 0.3), s = 1 + frame.spring * 0.15
        var dots = Dots()
        for (point, band) in Self.fibonacci {
            let b = frame.bands[band]
            let r = s * (1 + b * 0.38 + sin(t * 3 + point.y * 6) * 0.04 * frame.thinking)
            let (q, f) = project(rotate(point * r, t * 0.35, 0.35 + sin(t * 0.2) * 0.15))
            dots.add(q, size: (1.3 + b * 2.4) * f, alpha: (0.22 + b * 0.78) * min(1, f))
        }
        dots.draw(&ctx, color)
    }

    private func tunnel(_ ctx: inout GraphicsContext, _ size: CGSize) {
        let project = projection(size, 0.24), rings = 14
        let dir: Float = frame.userLevel > frame.assistantLevel + 0.05 ? -1 : 1
        motion.tunnelOffset += dir * (0.004 + frame.level * 0.02)
        for i in 0..<rings {
            let raw = (Float(i) / Float(rings) + motion.tunnelOffset).truncatingRemainder(dividingBy: 1)
            let phase = raw < 0 ? raw + 1 : raw
            let z = phase * 6 - 1.6
            let hi = history(dir < 0 ? 1 - phase : phase)
            var path = Path()
            for j in 0...72 {
                let a = Float(j) / 72 * 2 * .pi
                let w = 1 + frame.bands[(j * 7 + i * 3) % 32] * hi * 0.35 + hi * 0.15
                let (q, _) = project(rotate(SIMD3(cos(a) * w, sin(a) * w, z), 0, 0.15))
                if j == 0 { path.move(to: q) } else { path.addLine(to: q) }
            }
            let fade = max(0, min(1, (4.4 - z) / 4)) * min(1, (z + 1.6) * 2)
            ctx.stroke(path, with: .color(VoicePalette.color(color, opacity: Double(fade * (0.18 + hi * 0.75)))),
                       lineWidth: CGFloat(1 + hi * 2))
        }
    }

    private func saturn(_ ctx: inout GraphicsContext, _ size: CGSize) {
        let project = projection(size, 0.23), s = 1 + frame.spring * 0.25, ax: Float = 0.45, ay = t * 0.3
        var dots = Dots()
        for (point, band) in Self.fibonacci {
            let b = frame.bands[band]
            let (q, f) = project(rotate(point * (s * (1 + b * 0.2)), ay, ax))
            dots.add(q, size: (1.4 + b * 2) * f, alpha: (0.25 + b * 0.75) * min(1, f))
        }
        for i in 0..<200 {
            let a = Float(i) / 200 * 2 * .pi, hi = history(Float(i) / 200)
            let wave = hi * 0.5 * sin(Float(i) * 0.9 + t * 4), r = 1.75 + hi * 0.25
            let (q, f) = project(rotate(SIMD3(cos(a) * r, wave * 0.5, sin(a) * r), ay * 0.5, ax))
            dots.add(q, size: (1.4 + hi * 1.6) * f, alpha: (0.25 + hi * 0.75) * min(1, f))
        }
        dots.draw(&ctx, color)
    }

    private func terrain(_ ctx: inout GraphicsContext, _ size: CGSize) {
        let project = projection(size, 0.42), grid = 32, lift = CGFloat(Float(min(size.width, size.height)) * 0.42 * 0.08)
        var dots = Dots()
        for zi in 0..<grid {
            for xi in 0..<grid {
                let x = Float(xi) / Float(grid - 1) * 2 - 1, z = Float(zi) / Float(grid - 1) * 2 - 1
                let d = (x * x + z * z).squareRoot()
                let hi = frame.history[min(VoiceFrame.historyCount - 1, Int(d * 80))]
                let angle = atan2(z, x)
                let b = frame.bands[min(31, Int((angle / .pi + 1) / 2 * 31.99))] * max(0, 1 - d * 1.3)
                let y = -(hi * 0.45 + b * 0.25) * cos(d * 1.6) + sin(x * 3 + t) * 0.02
                var (q, f) = project(rotate(SIMD3(x * 1.4, y + 0.2, z * 1.4), t * 0.1, 0.55))
                q.y += lift
                dots.add(q, size: (1.2 + hi * 1.8) * f, alpha: (0.15 + hi * 0.85) * f)
            }
        }
        dots.draw(&ctx, color)
    }

    private func torus(_ ctx: inout GraphicsContext, _ size: CGSize) {
        let project = projection(size, 0.3), around = 72, tube = 14
        var dots = Dots()
        for i in 0..<around {
            let u = Float(i) / Float(around) * 2 * .pi + t * 0.35, hi = history(Float(i) / Float(around))
            for j in 0..<tube {
                let v = Float(j) / Float(tube) * 2 * .pi - t * 0.8, r = 0.3 + hi * 0.28
                let p = SIMD3((1 + r * cos(v)) * cos(u), r * sin(v), (1 + r * cos(v)) * sin(u))
                let (q, f) = project(rotate(p, 0, 1.05 + sin(t * 0.3) * 0.08))
                dots.add(q, size: (1.1 + hi * 2.2) * f, alpha: (0.18 + hi * 0.82) * f)
            }
        }
        dots.draw(&ctx, color)
    }

    private func radial(_ ctx: inout GraphicsContext, _ size: CGSize, _ steps: Int) {
        let project = projection(size, 0.3), count = 64
        let lift = CGFloat(Float(min(size.width, size.height)) * 0.3 * 0.15)
        var bars: [(CGPoint, CGPoint, Float, Float)] = []
        for i in 0..<count {
            let a = Float(i) / Float(count) * 2 * .pi + t * 0.2
            let band = min(31, abs((i % 32) - 16) * 2 % 32)
            let target = frame.bands[band] * 1.3 + max(0, sin(t * 4 - Float(i) * 0.4)) * 0.25 * frame.thinking
            for _ in 0..<steps { motion.tips[i].step(to: target, stiffness: 0.22, damping: 0.74) }
            let h = 0.06 + max(0, motion.tips[i].x) * 0.9
            let base = rotate(SIMD3(cos(a) * 1.25, 0, sin(a) * 1.25), 0, 1.1)
            let tip = rotate(SIMD3(cos(a) * 1.25, -h, sin(a) * 1.25), 0, 1.1)
            let (q1, f) = project(base), (q2, _) = project(tip)
            bars.append((q1, q2, h, f))
        }
        bars.sort { $0.3 < $1.3 } // far bars first
        for (q1, q2, h, f) in bars {
            var path = Path()
            path.move(to: CGPoint(x: q1.x, y: q1.y + lift))
            path.addLine(to: CGPoint(x: q2.x, y: q2.y + lift))
            ctx.stroke(path, with: .color(VoicePalette.color(color, opacity: Double((0.3 + h * 0.7) * f))),
                       style: StrokeStyle(lineWidth: CGFloat(4.5 * f), lineCap: .round))
        }
    }
}

#Preview("Sky orb") {
    VoiceVisualizer(signal: .simulated()).frame(height: 320).background(.black)
}

#Preview("All styles") {
    let signal = VoiceSignal.simulated()
    return ScrollView {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 160))]) {
            ForEach(VoiceVisualizerStyle.allCases) { style in
                VoiceVisualizer(style: style, signal: signal).frame(height: 160)
            }
        }
    }
    .background(.black)
}
