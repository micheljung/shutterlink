"""Renders landscape JPEGs to stand in for real photos in screenshots."""

import math
import random
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

SCENES = [
    ((255, 160, 100), (120, 60, 110), (60, 30, 70)),
    ((120, 190, 240), (80, 110, 140), (40, 70, 100)),
    ((40, 45, 90), (70, 60, 120), (25, 20, 50)),
    ((250, 210, 150), (200, 120, 90), (90, 50, 60)),
    ((160, 220, 200), (70, 130, 120), (30, 70, 70)),
    ((230, 150, 170), (130, 80, 130), (50, 35, 70)),
]
SIZES = [(1600, 1067), (1067, 1600), (1600, 1067), (1600, 1067), (1067, 1600)]
RIDGES = 3
SUN_RADIUS = 0.06
BLUR = 2


def mix(a, b, t):
    return tuple(round(x + (y - x) * t) for x, y in zip(a, b))


def render(index, size):
    sky, mid, ground = SCENES[index % len(SCENES)]
    width, height = size
    rng = random.Random(index)
    image = Image.new("RGB", size)
    draw = ImageDraw.Draw(image)
    for y in range(height):
        draw.line([(0, y), (width, y)], fill=mix(sky, mid, y / height))
    sun = (rng.uniform(0.2, 0.8) * width, rng.uniform(0.15, 0.4) * height)
    radius = SUN_RADIUS * min(width, height)
    draw.ellipse(
        [sun[0] - radius, sun[1] - radius, sun[0] + radius, sun[1] + radius],
        fill=(255, 245, 220),
    )
    for ridge in range(RIDGES):
        t = (ridge + 1) / RIDGES
        base = height * (0.55 + 0.15 * ridge)
        phase = rng.uniform(0, math.tau)
        points = [(0, height)]
        for x in range(0, width + 1, 8):
            wave = math.sin(x / width * 9 + phase) + 0.5 * math.sin(x / width * 23)
            points.append((x, base - wave * height * 0.05))
        points.append((width, height))
        draw.polygon(points, fill=mix(mid, ground, t))
    return image.filter(ImageFilter.GaussianBlur(BLUR))


def main():
    out = Path(sys.argv[1])
    count = int(sys.argv[2])
    out.mkdir(parents=True, exist_ok=True)
    for index in range(count):
        size = SIZES[index % len(SIZES)]
        render(index, size).save(out / f"IMG_{4821 - index}.JPG", quality=88)


if __name__ == "__main__":
    main()
