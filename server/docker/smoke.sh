#!/usr/bin/env bash
# End-to-end check of a built server image:
#
#   server/docker/smoke.sh <image>
#
# Starts the image on a fresh volume and checks auth, an upload, the gallery,
# previews, static assets, live updates, the secret file, the user, the health
# check, tips from the environment and a clean `docker stop`. Exits non-zero
# and prints the container log on the first failure.
set -euo pipefail

image=${1:?usage: smoke.sh <image>}
token=smoke-token
code=apple-banana-cherry-delta
uid=10001
name=shutterlink-smoke-$$
tips_name=$name-tips
volume=$name-data
current=$name
tmp=$(mktemp -d)
fixture=$(dirname "$0")/fixture.jpg
sse_pid=

cleanup() {
  [ -z "$sse_pid" ] || kill "$sse_pid" >/dev/null 2>&1 || true
  docker rm -fv "$name" "$tips_name" >/dev/null 2>&1 || true
  docker volume rm "$volume" >/dev/null 2>&1 || true
  rm -rf "$tmp"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  echo "--- docker logs $current" >&2
  docker logs "$current" >&2 || true
  exit 1
}

ok() { echo "ok: $*"; }

# start <name> [docker run options...] -- prints the published base URL.
start() {
  local container=$1
  shift
  current=$container
  # Runs inside $(...), where errexit does not apply: fail explicitly.
  docker run -d --name "$container" -p 127.0.0.1::8080 \
    -e SHUTTERLINK_UPLOAD_TOKEN="$token" "$@" "$image" >/dev/null ||
    fail "docker run $image failed"
  local port
  port=$(docker port "$container" 8080/tcp | head -n1 | sed 's/.*://')
  local url="http://127.0.0.1:$port"
  for _ in $(seq 1 40); do
    if [ "$(status "$url/api/auth" -H "Authorization: Bearer $token")" = 204 ]; then
      echo "$url"
      return 0
    fi
    sleep 0.5
  done
  fail "$container did not answer within 20 s"
}

# status <url> [curl options...] -- prints the HTTP status, 000 if none.
status() {
  local url=$1
  shift
  curl -s --max-time 5 -o /dev/null -w '%{http_code}' "$@" "$url" || true
}

expect_status() {
  local expected=$1 what=$2
  shift 2
  local actual
  actual=$(status "$@")
  [ "$actual" = "$expected" ] || fail "$what: expected $expected, got $actual"
  ok "$what -> $actual"
}

# upload <url> -- puts one photo into $code.
upload() {
  head -c 2048 /dev/urandom >"$tmp/photo.jpg"
  local key
  key=$(sha256sum "$tmp/photo.jpg" | cut -d' ' -f1)
  expect_status 201 "PUT photo" "$1/api/sessions/$code/photos/$key" \
    -X PUT -H "Authorization: Bearer $token" --data-binary "@$tmp/photo.jpg"
}

wait_for() {
  local tries=$(($1 * 10))
  for _ in $(seq 1 "$tries"); do
    grep -q "$3" "$2" 2>/dev/null && return 0
    sleep 0.1
  done
  return 1
}

docker volume create "$volume" >/dev/null
url=$(start "$name" -v "$volume:/data")
ok "started $image at $url"

expect_status 204 "auth with token" "$url/api/auth" -H "Authorization: Bearer $token"
expect_status 401 "auth without token" "$url/api/auth"
upload "$url"
expect_status 200 "gallery" "$url/s/$code"

fixture_key=$(sha256sum "$fixture" | cut -d' ' -f1)
expect_status 201 "PUT fixture" "$url/api/sessions/$code/photos/$fixture_key" \
  -X PUT -H "Authorization: Bearer $token" --data-binary "@$fixture"
preview_timeout_s=20
ready=
for _ in $(seq 1 "$preview_timeout_s"); do
  if curl -s --max-time 5 "$url/s/$code/photos.json" |
    grep -qF "\"key\":\"$fixture_key\",\"state\":\"ready\""; then
    ready=1
    break
  fi
  sleep 1
done
[ -n "$ready" ] || fail "fixture preview not ready within $preview_timeout_s s"
ok "fixture preview ready"

for kind in t v; do
  type=$(curl -s --max-time 5 -o /dev/null -w '%{http_code} %{content_type}' \
    "$url/s/$code/$kind/$fixture_key.jpg")
  [ "$type" = "200 image/jpeg" ] || fail "$kind/ preview: got '$type'"
  ok "$kind/ preview -> $type"
done
expect_status 200 "static gallery.js" "$url/static/gallery.js"
expect_status 200 "unversioned app.css" "$url/static/app.css"

curl -s --max-time 5 -D "$tmp/headers" -o /dev/null "$url/s/$code/photos.json"
grep -qi "^content-security-policy:.*script-src 'self'" "$tmp/headers" ||
  fail "CSP lacks script-src 'self'"
ok "CSP allows script-src 'self'"
etag=$(sed -n 's/^[Ee][Tt][Aa][Gg]: *//p' "$tmp/headers" | tr -d '\r')
[ -n "$etag" ] || fail "photos.json has no ETag"
expect_status 304 "repeated photos.json" "$url/s/$code/photos.json" \
  -H "If-None-Match: $etag"

events=$url/s/$code/events
curl -s -D - --max-time 2 -o /dev/null "$events" >"$tmp/sse-headers" || true
grep -qi '^content-type: text/event-stream' "$tmp/sse-headers" ||
  fail "events content-type is not text/event-stream"
ok "events content-type is text/event-stream"

curl -sN "$events" >"$tmp/sse" &
sse_pid=$!
wait_for 3 "$tmp/sse" '^: open' || fail "events stream did not open within 3 s"
upload "$url"
wait_for 3 "$tmp/sse" '^id:' || fail "no doorbell event within 3 s of an upload"
kill "$sse_pid" 2>/dev/null || true
wait "$sse_pid" 2>/dev/null || true
sse_pid=
ok "doorbell rang after an upload"

curl -sN --max-time 3 "$events?since=x" >"$tmp/catch-up" || true
grep -q '^retry: 3000' "$tmp/catch-up" || fail "catch-up stream lacks retry: 3000"
grep -q '^id:' "$tmp/catch-up" || fail "catch-up stream lacks an id: line"
ok "since=x catches up"

secret=$(docker exec "$name" stat -c '%a %u' /data/secret)
[ "$secret" = "600 $uid" ] || fail "/data/secret is '$secret', expected '600 $uid'"
ok "/data/secret is $secret"
user=$(docker exec "$name" id -u)
[ "$user" = "$uid" ] || fail "runs as uid $user, expected $uid"
ok "runs as uid $user"

health=
for _ in $(seq 1 40); do
  health=$(docker inspect -f '{{.State.Health.Status}}' "$name")
  [ "$health" = healthy ] && break
  sleep 1
done
[ "$health" = healthy ] || fail "health is '$health' after 40 s"
ok "health is $health"

current=$tips_name
tips_url=$(start "$tips_name" \
  -e SHUTTERLINK_TIPS=$'PayPal=https://example.com/paypal\nTWINT=https://example.com/twint')
upload "$tips_url"
page=$(curl -sf --max-time 5 "$tips_url/s/$code") || fail "tips gallery did not load"
for tip in https://example.com/paypal https://example.com/twint; do
  grep -qF "href=\"$tip\"" <<<"$page" || fail "gallery lacks tip $tip"
done
ok "tips from SHUTTERLINK_TIPS shown"
docker rm -fv "$tips_name" >/dev/null
current=$name

curl -sN "$events" >"$tmp/sse-stop" &
sse_pid=$!
wait_for 3 "$tmp/sse-stop" '^: open' || fail "events stream did not open within 3 s"
started=$(date +%s%N)
docker stop -t 10 "$name" >/dev/null
elapsed_ms=$((($(date +%s%N) - started) / 1000000))
exit_code=$(docker inspect -f '{{.State.ExitCode}}' "$name")
[ "$exit_code" = 0 ] || fail "exit code after docker stop is $exit_code"
[ "$elapsed_ms" -lt 3000 ] || fail "docker stop took ${elapsed_ms} ms"
ok "docker stop took ${elapsed_ms} ms with an event stream open, exit code $exit_code"

echo "smoke test passed"
