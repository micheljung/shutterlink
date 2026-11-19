#!/usr/bin/env bash
# Regenerates every launch asset from the fake-camera widget-test harness:
# Play screenshots, feature graphic, README screenshots and the demo reel
# (GIF, MP4, WebM). Needs fvm, ffmpeg and Python 3 with Pillow. The guest
# gallery screenshot has its own script, tool/screenshot_guest_gallery.sh.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
listing=fastlane/metadata/android/en-US/images
media=docs/media
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT INT TERM
# Play screenshot number -> harness capture name.
play_screens=(modes gallery preview live_share auto_upload download)
reel_seconds_per_frame=1.4
reel_gif_width=360
reel_video_width=720
gif_max_bytes=5000000

screenshots() {
  fvm flutter test -t screenshots --run-skipped "$@" test/screenshots/screenshots_test.dart
}

screenshots --dart-define=SCREENSHOTS_PROFILE=play \
  --dart-define=SCREENSHOTS_DIR="$tmp/play"
rm -f "$listing"/phoneScreenshots/*.png
mkdir -p "$listing/phoneScreenshots"
number=0
for name in "${play_screens[@]}"; do
  number=$((number + 1))
  cp "$tmp/play/$name.png" "$listing/phoneScreenshots/$number.png"
done

screenshots --dart-define=SCREENSHOTS_DIR="$root/docs/screenshots"

fvm flutter test -t brand-assets --run-skipped test/brand/feature_graphic_test.dart

fvm flutter test -t screenshots --run-skipped \
  --dart-define=SCREENSHOTS_PROFILE=play \
  --dart-define=SCREENSHOTS_DIR="$tmp/reel" test/screenshots/demo_reel_test.dart

mkdir -p "$media"
framerate=$(python3 -c "print(1 / $reel_seconds_per_frame)")
ffmpeg_in=(-y -loglevel error -framerate "$framerate" -i "$tmp/reel/frame_%02d.png")
bitexact=(-map_metadata -1 -fflags +bitexact -flags:v +bitexact)
ffmpeg "${ffmpeg_in[@]}" "${bitexact[@]}" -filter_complex \
  "scale=$reel_gif_width:-1:flags=lanczos,split[a][b];[a]palettegen=max_colors=128[p];[b][p]paletteuse=dither=bayer" \
  "$media/demo.gif"
ffmpeg "${ffmpeg_in[@]}" "${bitexact[@]}" -vf \
  "scale=$reel_video_width:-2:flags=lanczos,fps=30,format=yuv420p" \
  -c:v libx264 -crf 22 -movflags +faststart "$media/demo.mp4"
ffmpeg "${ffmpeg_in[@]}" "${bitexact[@]}" -vf \
  "scale=$reel_video_width:-2:flags=lanczos,fps=30" \
  -c:v libvpx-vp9 -crf 34 -b:v 0 "$media/demo.webm"
[ "$(stat -c %s "$media/demo.gif")" -le "$gif_max_bytes" ] ||
  { echo "demo.gif exceeds $gif_max_bytes bytes"; exit 1; }

python3 tool/check_store_assets.py
