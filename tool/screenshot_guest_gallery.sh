#!/usr/bin/env bash
# Renders docs/screenshots/guest_gallery.png: starts the Sessions server on a
# scratch directory, uploads demo photos and captures the gallery headless.
# Needs fvm, curl, Python 3 with Pillow, and Chromium (set CHROME to its
# binary if it isn't on PATH as chromium).
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
port=${PORT:-8787}
url="http://127.0.0.1:$port"
code=sunset-harbor-maple-lantern
token=screenshot-token
photo_count=9
preview_timeout_s=30
startup_timeout_s=60
tmp=$(mktemp -d)
trap 'pkill -f -- "--data-dir $tmp/data" || true; rm -rf "$tmp"' EXIT INT TERM

python3 "$root/tool/demo_photos.py" "$tmp/photos" "$photo_count"

(cd "$root/server" && fvm dart pub get >/dev/null)
fvm dart run "$root/server/bin/server.dart" \
  --data-dir "$tmp/data" --upload-token "$token" --port "$port" \
  --tip "TWINT=https://example.com/twint" >"$tmp/server.log" 2>&1 &
for _ in $(seq 1 "$startup_timeout_s"); do
  curl -sf "$url/healthz" >/dev/null && break
  sleep 1
done
curl -sf "$url/healthz" >/dev/null || { cat "$tmp/server.log"; exit 1; }

for photo in "$tmp"/photos/*.JPG; do
  key=$(sha256sum "$photo" | cut -d' ' -f1)
  curl -sf -X PUT -H "Authorization: Bearer $token" --data-binary "@$photo" \
    "$url/api/sessions/$code/photos/$key" >/dev/null
done
for _ in $(seq 1 "$preview_timeout_s"); do
  ready=$(curl -s "$url/s/$code/photos.json" | grep -o '"state":"ready"' | wc -l || true)
  [ "$ready" -ge "$photo_count" ] && break
  sleep 1
done

"${CHROME:-chromium}" --headless --no-sandbox --disable-gpu --hide-scrollbars \
  --window-size=390,844 --force-device-scale-factor=3 \
  --timeout=6000 \
  --screenshot="$root/docs/screenshots/guest_gallery.png" "$url/s/$code"
