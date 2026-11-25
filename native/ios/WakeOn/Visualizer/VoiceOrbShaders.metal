// SwiftUI colorEffect shaders for the two orb visualizers. Ported from the browser
// prototype (prototypes/voice-visualizer/index.html) so both look the same.
#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

namespace voiceorb {

// 3D simplex noise (Ashima Arts / Stefan Gustavson, MIT).
float3 m289(float3 x) { return x - floor(x * (1.0 / 289.0)) * 289.0; }
float4 m289(float4 x) { return x - floor(x * (1.0 / 289.0)) * 289.0; }
float4 permute(float4 x) { return m289(((x * 34.0) + 1.0) * x); }

float snoise(float3 v) {
    const float2 C = float2(1.0 / 6.0, 1.0 / 3.0);
    const float4 D = float4(0.0, 0.5, 1.0, 2.0);
    float3 i = floor(v + dot(v, C.yyy));
    float3 x0 = v - i + dot(i, C.xxx);
    float3 g = step(x0.yzx, x0.xyz);
    float3 l = 1.0 - g;
    float3 i1 = min(g.xyz, l.zxy);
    float3 i2 = max(g.xyz, l.zxy);
    float3 x1 = x0 - i1 + C.xxx;
    float3 x2 = x0 - i2 + C.yyy;
    float3 x3 = x0 - D.yyy;
    i = m289(i);
    float4 p = permute(permute(permute(i.z + float4(0.0, i1.z, i2.z, 1.0))
                                + i.y + float4(0.0, i1.y, i2.y, 1.0))
                        + i.x + float4(0.0, i1.x, i2.x, 1.0));
    float3 ns = 0.142857142857 * D.wyz - D.xzx;
    float4 j = p - 49.0 * floor(p * ns.z * ns.z);
    float4 x_ = floor(j * ns.z);
    float4 y_ = floor(j - 7.0 * x_);
    float4 x = x_ * ns.x + ns.yyyy;
    float4 y = y_ * ns.x + ns.yyyy;
    float4 h = 1.0 - abs(x) - abs(y);
    float4 b0 = float4(x.xy, y.xy);
    float4 b1 = float4(x.zw, y.zw);
    float4 s0 = floor(b0) * 2.0 + 1.0;
    float4 s1 = floor(b1) * 2.0 + 1.0;
    float4 sh = -step(h, float4(0.0));
    float4 a0 = b0.xzyw + s0.xzyw * sh.xxyy;
    float4 a1 = b1.xzyw + s1.xzyw * sh.zzww;
    float3 p0 = float3(a0.xy, h.x);
    float3 p1 = float3(a0.zw, h.y);
    float3 p2 = float3(a1.xy, h.z);
    float3 p3 = float3(a1.zw, h.w);
    float4 nr = 1.79284291400159 - 0.85373472095314 * float4(dot(p0, p0), dot(p1, p1), dot(p2, p2), dot(p3, p3));
    p0 *= nr.x; p1 *= nr.y; p2 *= nr.z; p3 *= nr.w;
    float4 m = max(0.6 - float4(dot(x0, x0), dot(x1, x1), dot(x2, x2), dot(x3, x3)), 0.0);
    m = m * m;
    return 42.0 * dot(m * m, float4(dot(p0, x0), dot(p1, x1), dot(p2, x2), dot(p3, x3)));
}

float fbm(float3 p) {
    float a = 0.55, s = 0.0;
    for (int i = 0; i < 4; i++) {
        s += a * snoise(p);
        p = p * 1.9 + float3(1.7, 9.2, 3.1);
        a *= 0.42;
    }
    return s;
}

/// Unit-square coordinates with y up, centered, so the orb fits the shorter side.
float2 centered(float2 position, float2 size) {
    float side = min(size.x, size.y);
    float2 p = (position - size * 0.5) / (0.5 * side);
    return float2(p.x, -p.y);
}

/// The wave orb's spectrum history: 64 rows (newest first) of 32 × (band, speaker mix).
float2 historyCell(device const float *h, int count, int x, int y) {
    int i = (y * 32 + x) * 2;
    return i + 1 < count ? float2(h[i], h[i + 1]) : float2(0.0);
}

float2 sampleHistory(device const float *h, int count, float u, float v) {
    float x = clamp(u, 0.0, 1.0) * 31.0, y = clamp(v, 0.0, 1.0) * 63.0;
    int x0 = int(floor(x)), y0 = int(floor(y));
    int x1 = min(x0 + 1, 31), y1 = min(y0 + 1, 63);
    float fx = x - float(x0), fy = y - float(y0);
    float2 top = mix(historyCell(h, count, x0, y0), historyCell(h, count, x1, y0), fx);
    float2 bottom = mix(historyCell(h, count, x0, y1), historyCell(h, count, x1, y1), fx);
    return mix(top, bottom, fy);
}

float3 waveLines(float3 n, device const float *h, int count, float t, float3 user, float3 assistant) {
    float lat = asin(clamp(n.y, -1.0, 1.0)), lon = atan2(n.z, n.x);
    float3 acc = float3(0.0);
    const int lines = 13;
    for (int k = 0; k < lines; k++) {
        float latk = mix(-1.2, 1.2, (float(k) + 0.5) / float(lines));
        float age = abs(latk) / 1.2; // equator = now, poles = ~2 s ago
        float2 cell = sampleHistory(h, count, abs(lon) / M_PI_F, age * 0.96 + 0.02);
        float env = cell.x;
        float offset = env * 0.15 * sin(lon * 7.0 + t * 2.2 + float(k) * 1.3)
                     + env * 0.045 * sin(lon * 17.0 - t * 3.1 + float(k));
        float d = lat - latk - offset, w = 0.011 + env * 0.012;
        float intensity = (exp(-d * d / (w * w)) * (0.22 + env * 1.5)
                           + exp(-d * d / (w * w * 10.0)) * env * 0.22) * (1.0 - age * 0.5);
        acc += intensity * mix(user, assistant, cell.y);
    }
    return acc;
}

} // namespace voiceorb

using namespace voiceorb;

/// ChatGPT-style sky orb: warped noise clouds on a lit sphere. It only scales with the voice.
[[ stitchable ]] half4 voiceSkyOrb(float2 position, half4 color, float2 size, float t, float flow,
                                   float level, float spring, float think, float speakerMix) {
    float2 p = centered(position, size);
    float rr = length(p);
    float R = 0.6 * (1.0 + spring * 0.17 + sin(t * 1.1) * 0.008 + think * sin(t * 3.2) * 0.025);
    float aa = 2.0 / min(size.x, size.y);
    float mask = smoothstep(R + aa, R - aa, rr);
    float halo = exp(-max(rr - R, 0.0) * 11.0) * (0.10 + level * 0.28) * (1.0 - mask);
    float3 haloColor = mix(float3(0.30, 0.62, 1.0), float3(0.45, 0.55, 1.0), speakerMix);
    if (rr > R + aa) { return half4(half3(haloColor * halo), half(halo)); }

    float2 q = p / R;
    float z = sqrt(max(0.0, 1.0 - dot(q, q)));
    float3 n = float3(q, z);
    float cr = cos(flow * 0.12), sr = sin(flow * 0.12);
    float3 c = float3(n.x * cr + n.z * sr, n.y, -n.x * sr + n.z * cr);
    float3 w = float3(fbm(c * 0.8 + float3(0.0, 0.0, flow * 0.16)),
                      fbm(c * 0.8 + float3(5.2, 1.3, flow * 0.16)),
                      fbm(c * 0.8 + float3(2.1, 7.7, -flow * 0.1)));
    float d = fbm(c * 0.95 + w * (1.4 + level * 0.5) + float3(0.0, flow * 0.07, 0.0));
    float cl = smoothstep(-0.25, 0.75, d);
    cl = cl * cl * (3.0 - 2.0 * cl);

    float3 deep = float3(0.05, 0.27, 0.80), mid = float3(0.24, 0.57, 0.98), top = float3(0.68, 0.86, 1.0);
    float3 col = mix(deep, mid, smoothstep(-1.0, 0.55, q.y + w.y * 0.25));
    col = mix(col, top, smoothstep(0.15, 1.0, q.y) * 0.55);
    col = mix(col, deep * 0.85, smoothstep(0.25, 0.75, w.x) * 0.28);
    col = mix(col, float3(0.96, 0.985, 1.0), cl * 0.78);
    float3 L = normalize(float3(-0.45, 0.6, 0.68));
    col *= 0.70 + 0.30 * max(dot(n, L), 0.0);
    col += pow(max(dot(reflect(-L, n), float3(0.0, 0.0, 1.0)), 0.0), 28.0) * 0.28;
    float fresnel = pow(1.0 - z, 2.6);
    col = mix(col, float3(0.78, 0.92, 1.0), fresnel * 0.55);
    col += cl * level * 0.10;
    col += mix(float3(-0.02, 0.05, 0.0), float3(0.05, -0.02, 0.07), speakerMix) * min(1.0, level * 2.0);
    return half4(half3(col * mask + haloColor * halo), half(mask + halo));
}

/// Glass sphere with the live spectrum drawn as glowing waves around it.
/// The equator is the present; lines toward the poles show the last ~2 seconds.
[[ stitchable ]] half4 voiceWaveOrb(float2 position, half4 color, float2 size, float t, float rotation,
                                    float level, float spring, float think,
                                    float3 user, float3 assistant, float3 current,
                                    device const float *history, int historyCount) {
    float2 p = centered(position, size);
    float rr = length(p);
    float R = 0.6 * (1.0 + spring * 0.15 + think * sin(t * 3.2) * 0.025 + sin(t * 1.1) * 0.008);
    float aa = 2.0 / min(size.x, size.y);
    float mask = smoothstep(R + aa, R - aa, rr);
    float halo = exp(-max(rr - R, 0.0) * 10.0) * (0.07 + level * 0.28) * (1.0 - mask);
    if (rr > R + aa) { return half4(half3(current * halo), half(halo)); }

    float2 q = p / R;
    float z = sqrt(max(0.0, 1.0 - dot(q, q)));
    float cr = cos(rotation), sr = sin(rotation), ct = cos(0.32), st = sin(0.32);
    float3x3 ry = float3x3(float3(cr, 0.0, -sr), float3(0.0, 1.0, 0.0), float3(sr, 0.0, cr));
    float3x3 rx = float3x3(float3(1.0, 0.0, 0.0), float3(0.0, ct, st), float3(0.0, -st, ct));
    float3 nf = float3(q, z);
    float3 front = ry * (rx * nf), back = ry * (rx * float3(q, -z));
    float3 L = normalize(float3(-0.45, 0.6, 0.68));
    float fresnel = pow(1.0 - z, 2.4);
    float3 col = (float3(0.03, 0.035, 0.055) + current * 0.035) * (0.6 + 0.4 * max(dot(nf, L), 0.0));
    col += waveLines(back, history, historyCount, t, user, assistant) * 0.2;
    col += waveLines(front, history, historyCount, t, user, assistant);
    col += current * fresnel * (0.3 + level * 0.4);
    col += pow(max(dot(reflect(-L, nf), float3(0.0, 0.0, 1.0)), 0.0), 40.0) * 0.3;
    col += current * think * 0.3 * exp(-pow((front.y - sin(t * 2.0)) * 6.0, 2.0));
    return half4(half3(col * mask + current * halo), half(mask + halo));
}

namespace voiceorb {

float hash1(float n) { return fract(sin(n * 12.9898) * 43758.5453); }

/// Which of `count` petals around the circle a point is in, and where across it (-0.5…0.5).
float2 petalCell(float angle, float count) {
    float a = angle * count / (2.0 * M_PI_F) + 0.5;
    float id = fmod(floor(a) + count * 64.0, count);
    return float2(id, fract(a) - 0.5);
}

/// Coverage of a pointed petal from `inner` to `len`; `width` is its share of the cell at the widest.
float petalMask(float across, float r, float inner, float len, float width, float aa, thread float &along) {
    along = (r - inner) / max(len - inner, 1e-3);
    if (along <= 0.0 || along >= 1.0) { return 0.0; }
    float half_ = width * 0.5 * pow(sin(M_PI_F * pow(along, 0.62)), 0.85);
    float edge = aa / max(r, 0.05) * 0.5;
    return smoothstep(half_ + edge, half_ - edge, abs(across));
}

} // namespace voiceorb

/// A crimson bloom with a dark spiral seed head and pale rays behind it (inspired by the cover of
/// Protest the Hero's Kezia). Petals open with the voice; the pale rays brighten for the user and
/// the crimson for the assistant.
[[ stitchable ]] half4 voiceBloomOrb(float2 position, half4 color, float2 size, float t, float flow,
                                     float level, float spring, float think, float speakerMix) {
    float2 p = centered(position, size);
    float r = length(p);
    float th = atan2(p.y, p.x);
    float aa = 2.0 / min(size.x, size.y);
    float open = 1.0 + spring * 0.16 + sin(t * 0.9) * 0.01;
    float R = 0.66 * open;
    float rs = 0.25 * (1.0 + spring * 0.05 + think * sin(t * 3.0) * 0.04);
    float spin = flow * 0.05;
    float user = (1.0 - speakerMix) * level, lobby = speakerMix * level;
    float grain = 0.9 + 0.1 * hash1(dot(floor(position), float2(1.0, 157.0)));

    float3 col = float3(0.0);
    float alpha = 0.0;

    // Pale rays behind the bloom (the white daisies).
    {
        const float N = 26.0;
        float2 cell = petalCell(th - spin * 0.6 + 0.3, N);
        float h = hash1(cell.x + 3.0);
        float along;
        float len = R * (1.07 + 0.13 * h) + user * 0.06;
        float m = petalMask(cell.y, r, rs * 0.9, len, 0.62 + 0.25 * h, aa, along);
        float streak = 0.78 + 0.22 * snoise(float3(cell.y * 12.0, r * 5.0, cell.x * 1.7));
        float3 ray = mix(float3(0.55, 0.53, 0.53), float3(1.0, 0.98, 0.96), smoothstep(0.0, 0.6, along))
                   * streak * (0.8 + user * 0.4);
        col = mix(col, ray, m);
        alpha = max(alpha, m);
    }

    // Two layers of crimson petals, the back one darker and offset by half a petal.
    for (int layer = 0; layer < 2; layer++) {
        const float N = 19.0;
        float front = float(layer);
        float sway = sin(t * 0.7 + front * 2.0) * 0.015;
        float2 cell = petalCell(th - spin + front * (M_PI_F / N) + sway, N);
        float h = hash1(cell.x * 7.0 + front * 31.0);
        float len = R * (0.86 + 0.16 * h - front * 0.07) + lobby * 0.07;
        float along = (r - rs * 0.8) / max(len - rs * 0.8, 1e-3);
        float across = cell.y + (h - 0.5) * 0.35 * along * along; // a slight twist toward the tip
        float m = petalMask(across, r, rs * 0.8, len, 0.92, aa, along);
        if (m <= 0.0) { continue; }
        float3 base = float3(0.16, 0.0, 0.02), midc = float3(0.70, 0.03, 0.08), tip = float3(0.95, 0.24, 0.27);
        float3 pc = mix(base, midc, smoothstep(0.0, 0.35, along));
        pc = mix(pc, tip, smoothstep(0.55, 1.0, along) * 0.8);
        float w = max(0.46 * pow(sin(M_PI_F * pow(along, 0.62)), 0.85), 1e-3);
        float e = abs(across) / w;                                // 0 at the vein, 1 at the edge
        pc *= 1.0 - 0.45 * exp(-e * e * 60.0);                     // dark central vein
        pc = mix(pc, float3(1.0, 0.82, 0.82), smoothstep(0.78, 1.0, e) * 0.45 * along); // pale rim
        pc *= 0.72 + 0.28 * snoise(float3(across * 16.0, r * 5.0, cell.x * 2.3 + front * 11.0))
             * (0.85 + 0.15 * snoise(float3(across * 40.0, r * 60.0, cell.x)));
        pc *= mix(0.5, 1.0, front) * (0.85 + lobby * 0.6);
        col = mix(col, pc, m);
        alpha = max(alpha, m);
    }

    // Shadow the petals where they meet the seed head.
    col *= smoothstep(rs * 0.95, rs * 1.35, r) * 0.6 + 0.4;

    // Seed head: florets on the two Fibonacci spirals (21 one way, 34 the other).
    float seed = smoothstep(rs + aa, rs - aa, r);
    if (seed > 0.0) {
        float a = th + flow * 0.03;
        float lr = log(max(r, 1e-3));
        const float k = 26.72; // sqrt(21 × 34): keeps the florets square
        float u = 21.0 * a + k * lr, v = 34.0 * a - k * lr;
        float bump = (cos(u) * 0.5 + 0.5) * (cos(v) * 0.5 + 0.5);
        float floret = smoothstep(0.22, 0.75, bump) * (0.55 + 0.45 * snoise(float3(p * 18.0, 1.0)));
        float x = r / rs;
        float ripple = exp(-pow(x - fract(t * 0.45), 2.0) * 30.0) * (level * 1.2 + think * 0.6);
        float3 sc = mix(float3(0.03, 0.005, 0.01), float3(0.40, 0.05, 0.07) * (0.8 + ripple), floret);
        sc += float3(0.9, 0.35, 0.3) * pow(floret, 6.0) * (0.12 + ripple * 0.5) * smoothstep(0.1, 0.9, x);
        sc *= smoothstep(1.05, 0.55, x) * 0.5 + 0.5;               // darker toward the rim
        col = mix(col, sc, seed);
        alpha = max(alpha, seed);
    }

    col *= grain;
    float halo = exp(-max(r - R * 0.7, 0.0) * 5.0) * (0.05 + level * 0.22) * (1.0 - alpha);
    float3 haloColor = mix(float3(0.75, 0.72, 0.72), float3(0.75, 0.03, 0.08), speakerMix);
    return half4(half3(col * alpha + haloColor * halo), half(alpha + halo));
}
