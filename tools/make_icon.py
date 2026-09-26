#!/usr/bin/env python3
"""Draw the ReceiptVault app icon to
ReceiptVault/Assets.xcassets/AppIcon.appiconset/AppIcon.png.

Pure Python (zlib + struct, no PIL): a 1024x1024 RGB PNG (colour type 2, no
alpha, as App Store Connect requires). A white receipt with a zig-zag tear-off
edge, three grey lines and a small teal shield on a deep teal background.
Shapes are signed-distance fields, so every edge is anti-aliased.
Run once and commit the PNG. Usage: python3 tools/make_icon.py
"""
import math, struct, zlib
from pathlib import Path

SIZE = 1024
OUT = (Path(__file__).resolve().parent.parent / "ReceiptVault" / "Assets.xcassets"
       / "AppIcon.appiconset" / "AppIcon.png")

BG_TOP, BG_BOTTOM = (22, 114, 132), (7, 58, 72)
PAPER = (255, 255, 255)
INK = (198, 206, 211)
SHIELD = (27, 110, 133)          # AccentColor
TICK = (255, 255, 255)

# Receipt: rounded top corners, zig-zag bottom whose upper points sit on EDGE.
LEFT, RIGHT, TOP, CORNER = 292, 732, 150, 36
EDGE, TOOTH_DEPTH, TEETH = 830, 36, 7
PERIOD = (RIGHT - LEFT) / TEETH
SHADOW_DY, SHADOW_BLUR, SHADOW_ALPHA = 18, 40, 0.30

LINE_RADIUS = 15
LINES = [(356, 668, 290), (356, 600, 372), (356, 640, 454)]   # x0, x1, y

SHIELD_X, SHIELD_Y, SHIELD_W = 512, 648, 180
TICK_RADIUS = 0.058 * SHIELD_W


def clamp01(v):
    return 0.0 if v < 0 else 1.0 if v > 1 else v


def coverage(d):
    """Pixel coverage of a shape whose signed distance (negative inside) is d."""
    return clamp01(0.5 - d)


def mix(c, paint, a):
    return (c[0] + (paint[0] - c[0]) * a, c[1] + (paint[1] - c[1]) * a, c[2] + (paint[2] - c[2]) * a)


def segment_distance(px, py, ax, ay, bx, by):
    dx, dy = bx - ax, by - ay
    t = clamp01(((px - ax) * dx + (py - ay) * dy) / (dx * dx + dy * dy))
    return math.hypot(px - ax - t * dx, py - ay - t * dy)


def receipt_sdf(px, py):
    """Signed distance to the receipt outline."""
    # Box with rounded corners, extended below the zig-zag so only the top corners show.
    hx, hy = (RIGHT - LEFT) / 2, (EDGE + 200 - TOP) / 2
    qx = abs(px - (LEFT + hx)) - (hx - CORNER)
    qy = abs(py - (TOP + hy)) - (hy - CORNER)
    box = math.hypot(max(qx, 0.0), max(qy, 0.0)) + min(max(qx, qy), 0.0) - CORNER
    # Exact distance to the nearest zig-zag segments; vertex i is at x = LEFT + i * PERIOD / 2.
    half = PERIOD / 2
    j = min(max(int(math.floor((px - LEFT) / half)), 0), 2 * TEETH - 1)
    dz = float("inf")
    for i in range(max(0, j - 1), min(2 * TEETH, j + 2)):
        ax, bx = LEFT + i * half, LEFT + (i + 1) * half
        ay = EDGE + (TOOTH_DEPTH if i % 2 else 0)
        by = EDGE + (0 if i % 2 else TOOTH_DEPTH)
        dz = min(dz, segment_distance(px, py, ax, ay, bx, by))
    phase = ((px - LEFT) / PERIOD) % 1.0
    zig = EDGE + TOOTH_DEPTH * (1 - abs(2 * phase - 1))
    return max(box, dz if py > zig else -dz)


def shield_points():
    """Shield outline in pixels: domed top, straight sides, curved to a point."""
    right = [(0.0, -0.56), (0.25, -0.515), (0.5, -0.44), (0.5, 0.02)]
    (x0, y0), (cx, cy), (x1, y1) = (0.5, 0.02), (0.49, 0.42), (0.0, 0.66)
    for k in range(1, 21):
        t = k / 20
        u = 1 - t
        right.append((u * u * x0 + 2 * u * t * cx + t * t * x1, u * u * y0 + 2 * u * t * cy + t * t * y1))
    outline = right + [(-x, y) for x, y in reversed(right[1:-1])]
    return [(SHIELD_X + x * SHIELD_W, SHIELD_Y + y * SHIELD_W) for x, y in outline]


def polygon_sdf(px, py, pts):
    """Signed distance to a closed polygon (negative inside)."""
    d, inside = float("inf"), False
    ax, ay = pts[-1]
    for bx, by in pts:
        d = min(d, segment_distance(px, py, ax, ay, bx, by))
        if (by > py) != (ay > py) and px < (ax - bx) * (py - by) / (ay - by) + bx:
            inside = not inside
        ax, ay = bx, by
    return -d if inside else d


def tick_points():
    pts = [(-0.21, 0.04), (-0.05, 0.20), (0.23, -0.14)]
    return [(SHIELD_X + x * SHIELD_W, SHIELD_Y + y * SHIELD_W) for x, y in pts]


def render():
    shield = shield_points()
    tick = tick_points()
    sx0 = min(p[0] for p in shield) - 2
    sx1 = max(p[0] for p in shield) + 2
    sy0 = min(p[1] for p in shield) - 2
    sy1 = max(p[1] for p in shield) + 2
    rx0, rx1 = LEFT - SHADOW_BLUR, RIGHT + SHADOW_BLUR
    ry0, ry1 = TOP - SHADOW_BLUR, EDGE + TOOTH_DEPTH + SHADOW_DY + SHADOW_BLUR
    raw = bytearray()
    for y in range(SIZE):
        raw.append(0)                                   # filter: none
        py = y + 0.5
        for x in range(SIZE):
            px = x + 0.5
            c = mix(BG_TOP, BG_BOTTOM, clamp01((0.35 * px + py) / (1.35 * SIZE)))
            if rx0 <= px <= rx1 and ry0 <= py <= ry1:
                ds = receipt_sdf(px, py - SHADOW_DY)
                t = clamp01((ds + 8) / SHADOW_BLUR)
                c = mix(c, (0, 0, 0), SHADOW_ALPHA * (1 - t * t * (3 - 2 * t)))
                a = coverage(receipt_sdf(px, py))
                if a > 0:
                    c = mix(c, PAPER, a)
                    for x0, x1, ly in LINES:
                        if abs(py - ly) <= LINE_RADIUS + 1:
                            dl = segment_distance(px, py, x0, ly, x1, ly) - LINE_RADIUS
                            c = mix(c, INK, coverage(dl))
                    if sx0 <= px <= sx1 and sy0 <= py <= sy1:
                        a = coverage(polygon_sdf(px, py, shield))
                        if a > 0:
                            c = mix(c, SHIELD, a)
                            dt = min(segment_distance(px, py, *tick[0], *tick[1]),
                                     segment_distance(px, py, *tick[1], *tick[2])) - TICK_RADIUS
                            c = mix(c, TICK, coverage(dt))
            raw.extend(min(255, max(0, int(v + 0.5))) for v in c)
    return bytes(raw)


def chunk(kind, data):
    return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)


def write_png(path, raw):
    header = struct.pack(">IIBBBBB", SIZE, SIZE, 8, 2, 0, 0, 0)   # 8-bit RGB, no alpha
    png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header) + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b"")
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(png)


def main():
    write_png(OUT, render())
    print(f"Wrote {SIZE}x{SIZE} RGB icon to {OUT}")


if __name__ == "__main__":
    main()
