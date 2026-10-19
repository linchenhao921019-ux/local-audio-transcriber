#!/usr/bin/env python3
import argparse
import math
import shutil
import struct
import subprocess
import tempfile
import zlib
from pathlib import Path


SIZE = 1024


def blend(dst, src):
    sr, sg, sb, sa = src
    dr, dg, db, da = dst
    src_a = sa / 255.0
    dst_a = da / 255.0
    out_a = src_a + dst_a * (1 - src_a)
    if out_a == 0:
        return (0, 0, 0, 0)
    return (
        int((sr * src_a + dr * dst_a * (1 - src_a)) / out_a),
        int((sg * src_a + dg * dst_a * (1 - src_a)) / out_a),
        int((sb * src_a + db * dst_a * (1 - src_a)) / out_a),
        int(out_a * 255),
    )


def write_png(path: Path, pixels):
    raw = bytearray()
    for row in pixels:
        raw.append(0)
        for r, g, b, a in row:
            raw.extend((r, g, b, a))
    png = bytearray(b"\x89PNG\r\n\x1a\n")

    def chunk(name, data):
        png.extend(struct.pack(">I", len(data)))
        png.extend(name)
        png.extend(data)
        png.extend(struct.pack(">I", zlib.crc32(name + data) & 0xFFFFFFFF))

    chunk(b"IHDR", struct.pack(">IIBBBBB", SIZE, SIZE, 8, 6, 0, 0, 0))
    chunk(b"IDAT", zlib.compress(bytes(raw), level=9))
    chunk(b"IEND", b"")
    path.write_bytes(bytes(png))


def rounded_rect_mask(x, y, left, top, right, bottom, radius):
    if x < left or x >= right or y < top or y >= bottom:
        return False
    cx = left + radius if x < left + radius else right - radius - 1 if x >= right - radius else x
    cy = top + radius if y < top + radius else bottom - radius - 1 if y >= bottom - radius else y
    return (x - cx) * (x - cx) + (y - cy) * (y - cy) <= radius * radius


def draw_rounded_rect(pixels, box, radius, color):
    left, top, right, bottom = box
    for y in range(max(0, top), min(SIZE, bottom)):
        for x in range(max(0, left), min(SIZE, right)):
            if rounded_rect_mask(x, y, left, top, right, bottom, radius):
                pixels[y][x] = blend(pixels[y][x], color)


def draw_line(pixels, x1, y1, x2, y2, color, width):
    dx = x2 - x1
    dy = y2 - y1
    steps = max(abs(dx), abs(dy), 1)
    radius = width / 2
    for i in range(steps + 1):
        x = x1 + dx * i / steps
        y = y1 + dy * i / steps
        min_x = max(0, int(x - radius - 1))
        max_x = min(SIZE - 1, int(x + radius + 1))
        min_y = max(0, int(y - radius - 1))
        max_y = min(SIZE - 1, int(y + radius + 1))
        for yy in range(min_y, max_y + 1):
            for xx in range(min_x, max_x + 1):
                if (xx - x) ** 2 + (yy - y) ** 2 <= radius * radius:
                    pixels[yy][xx] = blend(pixels[yy][xx], color)


def draw_wave(pixels, left, right, center_y, amp, color, width):
    points = []
    for x in range(left, right + 1, 6):
        t = (x - left) / (right - left)
        y = center_y + math.sin(t * math.tau * 3.2) * amp * (0.4 + 0.6 * math.sin(math.pi * t))
        points.append((x, int(y)))
    for (x1, y1), (x2, y2) in zip(points, points[1:]):
        draw_line(pixels, x1, y1, x2, y2, color, width)


def generate_png(path: Path):
    pixels = [[(0, 0, 0, 0) for _ in range(SIZE)] for _ in range(SIZE)]

    base_box = (82, 82, 942, 942)
    base_radius = 188

    draw_rounded_rect(pixels, (72, 92, 952, 962), 198, (0, 22, 68, 42))
    draw_rounded_rect(pixels, (76, 86, 948, 950), 194, (0, 34, 91, 30))

    left, top, right, bottom = base_box
    for y in range(top, bottom):
        for x in range(left, right):
            if rounded_rect_mask(x, y, left, top, right, bottom, base_radius):
                t = ((x - left) * 0.62 + (y - top) * 0.38) / (right - left)
                r = int(21 + 27 * t)
                g = int(92 + 73 * t)
                b = int(194 + 37 * t)
                pixels[y][x] = (r, g, b, 255)

    # Keep the blue base as a single visual layer; the document sits directly on it.
    draw_rounded_rect(pixels, (236, 164, 754, 836), 42, (255, 255, 255, 245))
    draw_rounded_rect(pixels, (630, 164, 754, 288), 34, (215, 232, 255, 255))
    draw_line(pixels, 630, 164, 754, 288, (28, 95, 209, 90), 6)

    for yy in [372, 438, 504]:
        draw_rounded_rect(pixels, (310, yy, 676, yy + 22), 11, (47, 99, 161, 150))

    draw_wave(pixels, 278, 718, 640, 70, (29, 95, 209, 255), 28)
    draw_wave(pixels, 304, 692, 640, 42, (70, 157, 255, 220), 16)
    draw_line(pixels, 238, 640, 274, 640, (29, 95, 209, 255), 28)
    draw_line(pixels, 724, 640, 760, 640, (29, 95, 209, 255), 28)

    write_png(path, pixels)


def build_icns(png_path: Path, icns_path: Path):
    if not shutil.which("iconutil") or not shutil.which("sips"):
        raise RuntimeError("需要 macOS 的 iconutil 和 sips 才能生成 .icns")
    with tempfile.TemporaryDirectory() as tmp:
        iconset = Path(tmp) / "AppIcon.iconset"
        iconset.mkdir()
        sizes = [16, 32, 128, 256, 512]
        for size in sizes:
            subprocess.run(["sips", "-z", str(size), str(size), str(png_path), "--out", str(iconset / f"icon_{size}x{size}.png")], check=True, stdout=subprocess.DEVNULL)
            subprocess.run(["sips", "-z", str(size * 2), str(size * 2), str(png_path), "--out", str(iconset / f"icon_{size}x{size}@2x.png")], check=True, stdout=subprocess.DEVNULL)
        subprocess.run(["iconutil", "-c", "icns", str(iconset), "-o", str(icns_path)], check=True)


def main():
    parser = argparse.ArgumentParser(description="Generate the Mac app icon.")
    parser.add_argument("--png", default="AppIcon.png")
    parser.add_argument("--icns", default="AppIcon.icns")
    args = parser.parse_args()
    png_path = Path(args.png).resolve()
    icns_path = Path(args.icns).resolve()
    png_path.parent.mkdir(parents=True, exist_ok=True)
    icns_path.parent.mkdir(parents=True, exist_ok=True)
    generate_png(png_path)
    build_icns(png_path, icns_path)
    print(f"Generated {png_path}")
    print(f"Generated {icns_path}")


if __name__ == "__main__":
    main()
