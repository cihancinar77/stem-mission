#!/usr/bin/env python3
"""Renders the StemMission app icon (purple galactic nebula + waveform).

  python tools/make_icon.py <out.png>     # 1024x1024 master
build.sh does not run this; Resources/AppIcon.icns is built from the master with sips + iconutil.
"""
import sys

import numpy as np
from PIL import Image, ImageDraw, ImageFilter
from scipy.ndimage import gaussian_filter, map_coordinates

S = 1024
rng = np.random.default_rng(7)


def fbm(octaves, base_sigma):
    """Smooth fractal noise in 0..1."""
    out = np.zeros((S, S))
    amp, sigma, total = 1.0, base_sigma, 0.0
    for _ in range(octaves):
        n = gaussian_filter(rng.standard_normal((S, S)), sigma, mode="wrap")
        out += amp * n / (n.std() + 1e-9)
        total += amp
        amp *= 0.55
        sigma /= 2
    out /= total
    return (out - out.min()) / (out.max() - out.min())


def warp(img, strength):
    yy, xx = np.mgrid[0:S, 0:S].astype(float)
    dx = (fbm(3, 90) - 0.5) * strength
    dy = (fbm(3, 90) - 0.5) * strength
    return map_coordinates(img, [yy + dy, xx + dx], order=1, mode="wrap")


def ramp(t, stops):
    """Map 0..1 through colour stops [(pos, (r, g, b)), ...]."""
    pos = [p for p, _ in stops]
    return np.stack([np.interp(t, pos, [c[i] for _, c in stops]) for i in range(3)], -1)


yy, xx = np.mgrid[0:S, 0:S].astype(float)
cx = cy = S / 2
r = np.hypot(xx - cx, yy - cy) / (S / 2)

# --- nebula clouds
clouds = warp(fbm(6, 120), 260)
wisps = warp(fbm(6, 60), 180)
# diagonal dust lane so the cloud reads as a galaxy arm, not flat fog
band = np.exp(-(((xx - cx) * 0.62 + (yy - cy) * 0.78) / (S * 0.30)) ** 2)
density = np.clip(clouds * 0.75 + band * 0.45 - 0.22, 0, 1) ** 1.25

img = ramp(density, [
    (0.00, (6, 3, 20)),       # near-black indigo
    (0.25, (34, 12, 78)),     # deep violet
    (0.50, (92, 34, 168)),    # purple
    (0.72, (164, 72, 224)),   # orchid
    (0.90, (236, 130, 240)),  # pink-magenta
    (1.00, (255, 214, 250)),  # hot core
]) / 255.0

# cool blue and warm magenta pockets for depth
blue = np.clip(wisps - 0.55, 0, 1) * 2.2 * (1 - density * 0.6)
img += blue[..., None] * np.array([0.05, 0.22, 0.55])
pink = np.clip(warp(fbm(5, 80), 200) - 0.60, 0, 1) * 2.4 * density
img += pink[..., None] * np.array([0.55, 0.10, 0.38])

# bright core behind the glyph
core = np.exp(-(r / 0.55) ** 2)
img += core[..., None] * np.array([0.30, 0.14, 0.46]) * 0.9
# vignette
img *= (1 - 0.55 * np.clip(r - 0.35, 0, 1) ** 1.6)[..., None]

# --- stars
stars = np.zeros((S, S))
n = 900
sx, sy = rng.integers(0, S, n), rng.integers(0, S, n)
stars[sy, sx] = rng.random(n) ** 6 * 1.2 + 0.08
stars = gaussian_filter(stars, 0.8) * 9
big = np.zeros((S, S))
m = 26
bx, by = rng.integers(120, S - 120, m), rng.integers(120, S - 120, m)
big[by, bx] = rng.random(m) * 0.7 + 0.5
glow = gaussian_filter(big, 2.2) * 60 + gaussian_filter(big, 9) * 260
img += (stars + glow)[..., None] * np.array([1.0, 0.94, 1.0])

bg = Image.fromarray((np.clip(img, 0, 1) * 255).astype(np.uint8), "RGB").convert("RGBA")

# --- waveform glyph: one bar per stem-ish, tallest in the middle
heights = [0.26, 0.50, 0.78, 1.00, 0.66, 0.88, 0.42, 0.20]
bar_w, gap, max_h = 46, 34, 430
total_w = len(heights) * bar_w + (len(heights) - 1) * gap
x0 = (S - total_w) / 2
glyph = Image.new("L", (S, S), 0)
d = ImageDraw.Draw(glyph)
for i, h in enumerate(heights):
    x = x0 + i * (bar_w + gap)
    hh = max_h * h
    d.rounded_rectangle([x, cy - hh / 2, x + bar_w, cy + hh / 2], radius=bar_w / 2, fill=255)

# soft purple halo, then the white bars with a faint lilac tint at the ends
halo = Image.new("RGBA", (S, S), (190, 110, 255, 0))
halo.putalpha(glyph.filter(ImageFilter.GaussianBlur(34)).point(lambda v: min(255, int(v * 1.5))))
bg.alpha_composite(halo)
tight = Image.new("RGBA", (S, S), (255, 200, 255, 0))
tight.putalpha(glyph.filter(ImageFilter.GaussianBlur(9)))
bg.alpha_composite(tight)
tint = ramp(np.abs(yy - cy) / (max_h / 2), [(0, (255, 255, 255)), (1, (226, 196, 255))])
bars = Image.fromarray(np.clip(tint, 0, 255).astype(np.uint8), "RGB").convert("RGBA")
bars.putalpha(glyph)
bg.alpha_composite(bars)

# --- macOS icon shape: 824pt squircle on the 1024 canvas, with a soft drop shadow
half, n_exp = 412, 5.0
sq = (np.abs((xx - cx) / half) ** n_exp + np.abs((yy - cy) / half) ** n_exp)
# antialias via the gradient of the superellipse
edge = np.clip((1 - sq) * half / n_exp + 0.5, 0, 1)
mask = Image.fromarray((edge * 255).astype(np.uint8), "L")

# thin inner highlight along the top edge
rim = np.clip(1 - np.abs(1 - sq) * 60, 0, 1) * np.clip((cy - yy) / half, 0, 1) * 0.35
rim_img = Image.new("RGBA", (S, S), (255, 235, 255, 0))
rim_img.putalpha(Image.fromarray((rim * edge * 255).astype(np.uint8), "L"))
bg.alpha_composite(rim_img)

out = Image.new("RGBA", (S, S), (0, 0, 0, 0))
shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
shadow.putalpha(mask.filter(ImageFilter.GaussianBlur(14)).point(lambda v: int(v * 0.45)))
out.alpha_composite(shadow, (0, 10))
bg.putalpha(mask)
out.alpha_composite(bg)
out.save(sys.argv[1])
