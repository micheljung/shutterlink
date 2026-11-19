#!/usr/bin/env python3
"""Checks the Play listing: image sizes, text limits, wording rules."""
import re
import subprocess
import sys
from pathlib import Path

from PIL import Image

root = Path(__file__).resolve().parent.parent
listing = root / "fastlane/metadata/android/en-US"
screenshot_size = (1080, 1920)
screenshot_count = 6
feature_graphic_size = (1024, 500)
icon_size = (512, 512)
max_aspect = 2.0
limits = {
    "title.txt": 30,
    "short_description.txt": 80,
    "full_description.txt": 4000,
}
changelog_limit = 500
canon_files = ("title.txt", "short_description.txt", "full_description.txt")
canon_line = re.compile(r"\b(canon|eos)\b", re.IGNORECASE)
allowed_canon_lines = (
    "Tested with the Canon EOS R.",
    "Canon and EOS are trademarks of Canon Inc. Shutterlink is an independent "
    "open-source project, not affiliated with or endorsed by Canon.",
)
errors = []


def check_size(path, expected, limit_aspect=False):
    size = Image.open(path).size
    if size != expected:
        errors.append(f"{path.relative_to(root)}: {size}, expected {expected}")
    elif limit_aspect and max(size) / min(size) > max_aspect:
        errors.append(f"{path.relative_to(root)}: aspect above {max_aspect}:1")


shots = listing / "images/phoneScreenshots"
for number in range(1, screenshot_count + 1):
    shot = shots / f"{number}.png"
    if shot.exists():
        check_size(shot, screenshot_size, limit_aspect=True)
    else:
        errors.append(f"missing {shot.relative_to(root)}")
extra = sorted(p.name for p in shots.glob("*.png")) if shots.exists() else []
if len(extra) != screenshot_count:
    errors.append(f"phoneScreenshots holds {extra}")
check_size(listing / "images/featureGraphic.png", feature_graphic_size)
check_size(listing / "images/icon.png", icon_size)

for name, limit in limits.items():
    length = len((listing / name).read_text())
    if length > limit:
        errors.append(f"{name}: {length} > {limit}")
for changelog in (listing / "changelogs").glob("*.txt"):
    if len(changelog.read_text()) > changelog_limit:
        errors.append(f"{changelog.name}: over {changelog_limit}")

for name in canon_files:
    for line in (listing / name).read_text().splitlines():
        if canon_line.search(line) and line not in allowed_canon_lines:
            errors.append(f"{name}: unexpected Canon/EOS mention: {line!r}")
for name in canon_files:
    if re.search(r"qr session", (listing / name).read_text(), re.IGNORECASE):
        errors.append(f"{name}: mentions QR Session")
    if re.search(r"demo server", (listing / name).read_text(), re.IGNORECASE):
        errors.append(f"{name}: mentions the demo server")

if errors:
    print("\n".join(errors))
    sys.exit(1)
print("store assets OK")
