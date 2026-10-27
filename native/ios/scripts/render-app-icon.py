#!/usr/bin/env python3
"""Render the app icon: the sky orb visualizer, ported from WakeOn/Visualizer/VoiceOrbShaders.metal.

uv run --with numpy --with pillow python scripts/render-app-icon.py 0 2048 1.33 WakeOn/Assets.xcassets/AppIcon.appiconset/AppIcon.png
Arguments: cloud flow (picks the cloud pattern), render size, zoom, output path.
Options: --dark (navy background instead of white), --transparent (no background, for the Live Activity orbs), --level=0.15 (voice level:
brighter clouds and a stronger glow).
"""
import sys, numpy as np
from PIL import Image

def m289(x): return x - np.floor(x / 289.0) * 289.0
def permute(x): return m289((x * 34.0 + 1.0) * x)

def snoise(v):
    C = np.array([1/6, 1/3]); 
    i = np.floor(v + v.sum(-1, keepdims=True) * C[1])
    x0 = v - i + i.sum(-1, keepdims=True) * C[0]
    g = (x0 >= x0[..., [1, 2, 0]]).astype(float)
    l = 1 - g
    i1 = np.minimum(g, l[..., [2, 0, 1]])
    i2 = np.maximum(g, l[..., [2, 0, 1]])
    x1 = x0 - i1 + C[0]; x2 = x0 - i2 + C[1]; x3 = x0 - 0.5
    i = m289(i)
    def comp(k):
        return np.stack([np.zeros_like(i[..., k]), i1[..., k], i2[..., k], np.ones_like(i[..., k])], -1)
    p = permute(permute(permute(i[..., 2:3] + comp(2)) + i[..., 1:2] + comp(1)) + i[..., 0:1] + comp(0))
    ns = 0.142857142857 * np.array([2.0, 0.5, 1.0]) - np.array([0.0, 1.0, 0.0])
    j = p - 49.0 * np.floor(p * ns[2] * ns[2])
    x_ = np.floor(j * ns[2]); y_ = np.floor(j - 7.0 * x_)
    x = x_ * ns[0] + ns[1]; y = y_ * ns[0] + ns[1]
    h = 1.0 - np.abs(x) - np.abs(y)
    b0 = np.stack([x[..., 0], x[..., 1], y[..., 0], y[..., 1]], -1)
    b1 = np.stack([x[..., 2], x[..., 3], y[..., 2], y[..., 3]], -1)
    s0 = np.floor(b0) * 2 + 1; s1 = np.floor(b1) * 2 + 1
    sh = -(h <= 0).astype(float)
    a0 = b0[..., [0, 2, 1, 3]] + s0[..., [0, 2, 1, 3]] * sh[..., [0, 0, 1, 1]]
    a1 = b1[..., [0, 2, 1, 3]] + s1[..., [0, 2, 1, 3]] * sh[..., [2, 2, 3, 3]]
    p0 = np.stack([a0[..., 0], a0[..., 1], h[..., 0]], -1)
    p1 = np.stack([a0[..., 2], a0[..., 3], h[..., 1]], -1)
    p2 = np.stack([a1[..., 0], a1[..., 1], h[..., 2]], -1)
    p3 = np.stack([a1[..., 2], a1[..., 3], h[..., 3]], -1)
    ps = [p0, p1, p2, p3]; xs = [x0, x1, x2, x3]
    out = 0
    for pk, xk in zip(ps, xs):
        nr = 1.79284291400159 - 0.85373472095314 * (pk * pk).sum(-1)
        m = np.maximum(0.6 - (xk * xk).sum(-1), 0); m = m * m
        out = out + m * m * ((pk * nr[..., None]) * xk).sum(-1)
    return 42.0 * out

def fbm(p):
    a, s = 0.55, 0
    for _ in range(4):
        s = s + a * snoise(p); p = p * 1.9 + np.array([1.7, 9.2, 3.1]); a *= 0.42
    return s

def smoothstep(e0, e1, x):
    t = np.clip((x - e0) / (e1 - e0), 0, 1); return t * t * (3 - 2 * t)
def mix(a, b, t): return a + (b - a) * t

flags = [a for a in sys.argv[1:] if a.startswith('--')]
sys.argv = [sys.argv[0]] + [a for a in sys.argv[1:] if not a.startswith('--')]
transparent = '--transparent' in flags
level = next((float(f.split('=')[1]) for f in flags if f.startswith('--level=')), 0.15)
N = int(sys.argv[2]) if len(sys.argv) > 2 else 2048
flow = float(sys.argv[1]) if len(sys.argv) > 1 else 0.0
scale = float(sys.argv[3]) if len(sys.argv) > 3 else 1.33   # zoom: the orb is 80% of the icon's width, like Safari's compass
ys, xs = np.mgrid[0:N, 0:N] + 0.5
p = np.stack([(xs - N/2) / (N/2), -(ys - N/2) / (N/2)], -1) / scale
rr = np.linalg.norm(p, axis=-1)
R = 0.6; aa = 2.0 / N / scale
mask = smoothstep(R + aa, R - aa, rr)
halo = np.exp(-np.maximum(rr - R, 0) * 11.0) * (0.10 + level * 0.28) * (1 - mask)
haloColor = np.array([0.30, 0.62, 1.0])
q = p / R
z = np.sqrt(np.maximum(0, 1 - (q * q).sum(-1)))
n = np.concatenate([q, z[..., None]], -1)
cr, sr = np.cos(flow * 0.12), np.sin(flow * 0.12)
c = np.stack([n[..., 0] * cr + n[..., 2] * sr, n[..., 1], -n[..., 0] * sr + n[..., 2] * cr], -1)
inside = rr <= R + aa
ci = c[inside]
w = np.stack([fbm(ci * 0.8 + np.array([0, 0, flow * 0.16])),
              fbm(ci * 0.8 + np.array([5.2, 1.3, flow * 0.16])),
              fbm(ci * 0.8 + np.array([2.1, 7.7, -flow * 0.1]))], -1)
d = fbm(ci * 0.95 + w * (1.4 + level * 0.5) + np.array([0, flow * 0.07, 0]))
cl = smoothstep(-0.25, 0.75, d); cl = cl * cl * (3 - 2 * cl)
qi = q[inside]; ni = n[inside]; zi = z[inside]
deep = np.array([0.05, 0.27, 0.80]); mid = np.array([0.24, 0.57, 0.98]); top = np.array([0.68, 0.86, 1.0])
col = mix(deep, mid, smoothstep(-1.0, 0.55, qi[:, 1] + w[:, 1] * 0.25)[:, None])
col = mix(col, top, (smoothstep(0.15, 1.0, qi[:, 1]) * 0.55)[:, None])
col = mix(col, deep * 0.85, (smoothstep(0.25, 0.75, w[:, 0]) * 0.28)[:, None])
col = mix(col, np.array([0.96, 0.985, 1.0]), (cl * 0.78)[:, None])
L = np.array([-0.45, 0.6, 0.68]); L /= np.linalg.norm(L)
ndl = (ni * L).sum(-1)
col *= (0.70 + 0.30 * np.maximum(ndl, 0))[:, None]
refl = -L + 2 * ndl[:, None] * ni   # reflect(-L, n) = -L - 2*dot(n,-L)*n
col += (np.maximum(refl[:, 2], 0) ** 28 * 0.28)[:, None]
fres = (1 - zi) ** 2.6
col = mix(col, np.array([0.78, 0.92, 1.0]), (fres * 0.55)[:, None])
col += (cl * level * 0.10)[:, None]
img = np.zeros((N, N, 3))
img[inside] = col
# White by default (the app icon); --dark for the near-black navy of the call screen.
bg = np.array([0.02, 0.03, 0.07]) if '--dark' in flags else np.array([1.0, 1.0, 1.0])
m = mask[..., None]
out = img * m + (haloColor * halo[..., None] + bg * (1 - halo[..., None])) * (1 - m)
out = np.clip(out, 0, 1)
if transparent:
    alpha = np.clip(mask + halo, 0, 1)
    rgb = np.clip(img * m + haloColor * halo[..., None], 0, 1) / np.maximum(alpha, 1e-6)[..., None]
    out = np.concatenate([np.clip(rgb, 0, 1), alpha[..., None]], -1)
im = Image.fromarray((out * 255 + 0.5).astype(np.uint8), 'RGBA' if transparent else 'RGB')
im = im.resize((1024, 1024) if not transparent else (N // 2, N // 2), Image.LANCZOS)
im.save(sys.argv[4] if len(sys.argv) > 4 else f'orb-{flow}.png')
