# Shutterlink Sessions server

A small, self-hostable gallery server for Shutterlink Sessions. The app
uploads each Session's photos here, and the person you photographed opens
`https://<your-server>/s/<session-code>` to view and download them.

Pure Dart, no native dependencies, no database. MIT licensed, like the app
(see [`../LICENSE`](../LICENSE)).

## Running

```bash
echo 'a-long-random-token' > /etc/shutterlink/token
dart run bin/server.dart \
  --data-dir /var/lib/shutterlink \
  --upload-token-file /etc/shutterlink/token \
  --tip "PayPal=https://paypal.me/you" \
  --tip "TWINT=https://example.com/twint"
```

| Flag | Default | Meaning |
|---|---|---|
| `--data-dir` | required | Where Sessions, tombstones and the server secret live |
| `--upload-token-file` | `$SHUTTERLINK_UPLOAD_TOKEN` | File holding the operator token the app sends when uploading |
| `--upload-token` | `--upload-token-file`, then `$SHUTTERLINK_UPLOAD_TOKEN` | The operator token itself. It shows up in `ps` and shell history, so prefer the file or the environment variable in production. Can't be combined with `--upload-token-file` |
| `--tip "Label=URL"` | `$SHUTTERLINK_TIPS` | Tip button on every gallery; repeatable. Only `http`/`https` URLs are accepted, anything else exits with code 64. Without any `--tip`, `SHUTTERLINK_TIPS` is read instead: one `Label=URL` per line, blank lines ignored |
| `--retention-days` | 30 | Days a Session is kept after its first upload |
| `--port` | 8080 | Listening port |
| `--address` | 127.0.0.1 | Listening address |
| `--healthcheck` | off | Don't start a server; ask the one on `--address`/`--port` for `GET /healthz` and exit 0 if it answers, 1 otherwise. A wildcard address (`0.0.0.0`, `::`) is checked on `127.0.0.1` |

Enter the server URL and the same token in the app under
Settings → Sessions → Connect Sessions. The server stops cleanly on `SIGINT`/`SIGTERM`.

Tips never gate anything: every download works the same with or without
tip links.

## Docker

Images for `linux/amd64` and `linux/arm64` are published to
`ghcr.io/micheljung/shutterlink-server`:

| Tag | Contents |
|---|---|
| `latest`, `X.Y.Z`, `X.Y` | Releases, versioned like the app |
| `main`, `sha-<commit>` | The latest commit on `main` |

```bash
docker run -d --name shutterlink --restart unless-stopped \
  -p 127.0.0.1:8080:8080 \
  -v shutterlink-data:/data \
  -e SHUTTERLINK_UPLOAD_TOKEN='a-long-random-token' \
  ghcr.io/micheljung/shutterlink-server:latest \
  --tip "PayPal=https://paypal.me/you"
```

Or with Docker Compose, keeping the token in a file:

```yaml
services:
  shutterlink:
    image: ghcr.io/micheljung/shutterlink-server:latest
    restart: unless-stopped
    ports:
      - "127.0.0.1:8080:8080"
    volumes:
      - shutterlink-data:/data
    secrets:
      - shutterlink_token
    command: ["--upload-token-file=/run/secrets/shutterlink_token"]
    environment:
      SHUTTERLINK_TIPS: |
        PayPal=https://paypal.me/you
        TWINT=https://example.com/twint

secrets:
  shutterlink_token:
    file: ./token

volumes:
  shutterlink-data:
```

- The image starts the server with `--address=0.0.0.0 --data-dir=/data`.
  Arguments after the image name (or in `command:`) are appended and can
  override either, for example `--retention-days 14`.
- Inside the container the server listens on all interfaces. Publish the
  port on `127.0.0.1` as above and keep the reverse proxy below in front of
  it.
- All data lives in `/data`, including `secret`, without which existing
  galleries can't be found. Back up the volume.
- The server runs as UID 10001. A named volume gets the right owner
  automatically. For a bind mount, make the directory writable first:
  `chown 10001:10001 /srv/shutterlink`.
- Compose mounts the `./token` secret with its host owner and mode, so UID
  10001 must be able to read it: `chmod 600 token && sudo chown 10001 token`.
  Otherwise the server exits with "Cannot read --upload-token-file". To read
  the token back later, use `sudo cat token`.
- Run one container per data volume (see [Limits](#limits)).
- The health check runs `/app/server --healthcheck` against port 8080. If
  you change `--port`, override the check too:

  ```yaml
      healthcheck:
        test: ["CMD", "/app/server", "--healthcheck", "--port=9000"]
  ```

To build the image yourself, from the repository root:

```bash
docker build -f server/Dockerfile -t shutterlink-server .
```

## Gallery

Guests see a grid of thumbnails and open each photo in a full-screen viewer
with swipe and zoom. Every tile and the viewer's download button fetch the
untouched original. Without JavaScript the page is a plain grid of download
links.

- **Previews.** After each upload the server makes a thumbnail (short edge
  400 px) and a viewer image (long edge 2048 px), with EXIF removed and the
  orientation applied. They are generated in the background, newest upload
  first; photos uploaded before an upgrade are processed after the new
  ones. Until a preview is ready the tile shows "Preparing preview…". Photos
  over 70 MP (60 MP for progressive JPEGs) or that can't be decoded get no
  preview and are still downloadable. Small hosts such as a Raspberry Pi
  generate previews more slowly.
- **Disk use.** Previews typically add about 5 % to a Session's size. They
  don't count toward the 2 GiB Session limit, so in the worst case (photos
  that compress far better than their previews) they reach about 3× the
  originals. Only the upload token holder can cause that. Previews are
  deleted with their Session.
- **Live updates.** An open gallery adds new photos without a reload. The
  page listens on `/s/<code>/events`, a Server-Sent Events stream that only
  says "something changed", and then fetches `/s/<code>/photos.json`. It
  also checks every 10 s in case a proxy buffers the stream, and if the
  stream can't be opened it polls every 5 s instead. Streams are capped at 64 per Session and
  512 in total; over the cap, guests get the polling fallback.
- **Deleting.** Anyone with the link can delete a single photo, from its
  tile or the viewer, or the whole gallery. Deletion is permanent and
  affects everyone with the link; the page asks for confirmation first
  (without JavaScript it doesn't). Other open tabs update live. The app
  needs no change: a deleted photo is never stored again when the app
  re-uploads it, and uploads to a deleted gallery are treated like uploads
  to an expired one. Deleting a photo while someone downloads "Download
  all" can cut that zip short.

## Reverse proxy

The server speaks plain HTTP and is meant to sit behind a TLS-terminating
reverse proxy. Rate-limit `/s/` there: Session Codes have about 51 bits of
entropy, and the proxy is what keeps guessing slow. For example, with nginx:

```nginx
limit_req_zone $binary_remote_addr zone=gallery:10m rate=30r/m;

server {
    listen 443 ssl;
    server_name photos.example.com;
    client_max_body_size 50m;

    location /s {
        limit_req zone=gallery burst=60 nodelay;
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host $http_host;
    }

    location ~ ^/s/[^/]+/events$ {
        limit_req zone=gallery burst=60 nodelay;
        proxy_pass http://127.0.0.1:8080;
        proxy_buffering off;
        proxy_read_timeout 1h;
        proxy_http_version 1.1;
        proxy_set_header Connection "";
    }

    location / {
        proxy_pass http://127.0.0.1:8080;
    }
}
```

Keep `client_max_body_size` at or above the 50 MiB photo limit; otherwise
the proxy rejects large photos with a bare 413, which the app shows as a
server configuration problem instead of dropping the photo.

- `proxy_set_header Host $http_host` lets the server check that delete requests
  come from the gallery itself in browsers that don't send
  `Sec-Fetch-Site`.
- The `events` location keeps live updates from being buffered. Caddy needs
  no extra configuration: it flushes `text/event-stream` responses
  immediately.
- Enable HTTP/2 at the proxy (`listen 443 ssl; http2 on;` in nginx). Over
  HTTP/1.1 each open gallery tab holds one of the browser's 6 connections
  to your server.
- On bare metal, raise the open-file limit to at least 2048
  (`ulimit -n 2048`, or `LimitNOFILE=2048` in a systemd unit) to cover the
  512 event streams plus uploads and downloads. The Docker image inherits
  the daemon's limit, which is usually higher.

## Privacy and security

- The Session Code is the only credential for a gallery. Unknown, empty,
  expired and malformed codes all get the same "your photos are on their
  way" page, so existing codes cannot be discovered.
- Session directories are named by an HMAC of the code with a random secret
  (`<data-dir>/secret`, created on first run with mode 0600). Neither the code
  nor its plain hash is stored.
- Every response carries `Content-Security-Policy: default-src 'none';
  img-src 'self'; style-src 'self'; script-src 'self'; connect-src 'self';
  font-src 'self'; form-action 'self'; base-uri 'none'; frame-ancestors
  'none'` plus `Referrer-Policy: no-referrer`, `X-Robots-Tag: noindex` and
  `X-Content-Type-Options: nosniff`. Pages load only scripts, styles and
  fonts served by the server itself; nothing comes from third parties.
- Responses are `Cache-Control: no-store`, except previews (`private`,
  cached until the Session expires), `photos.json` (`no-cache`) and static
  assets (immutable when requested with their version).
- Unknown, empty, expired and purged codes get identical `photos.json` and
  event-stream responses, so live updates reveal nothing about other
  Sessions.
- Uploads require `Authorization: Bearer <token>`, compared in constant time.
- Deleting (`POST /s/<code>/p/<sha256>/delete`, `POST /s/<code>/delete`)
  needs only the code, like viewing. Cross-site requests get `403`: a
  `Sec-Fetch-Site` other than `same-origin`, or without it an `Origin` that
  doesn't match `Host`. Unknown codes and photos get the same answer as a
  real deletion (`204`, or `303` back to the gallery for a plain form).

## Retention

A Session expires `--retention-days` after its first upload; the gallery
shows the date. A cleanup job runs at startup and then hourly. It deletes
expired Sessions and leaves a tombstone for 60 days, so late uploads to an
expired Session get `410 Gone` and the app stops retrying them. A gallery
deleted by a guest leaves the same tombstone. A photo deleted by a guest
leaves a small marker inside its Session, which goes with the Session.

## Limits

- 50 MiB per photo, 2 GiB per Session.
- "Download all" streams an uncompressed zip. At most 2 zips are built at a
  time; further requests wait up to 30 s and then get `503` with
  `Retry-After`.
- Previews are skipped above 70 MP, or 60 MP for progressive JPEGs. Up to
  2 previews are generated at a time.
- Single process only: Sessions are locked in memory, so do not run several
  instances on one data directory.

## Upload API

`PUT /api/sessions/<code>/photos/<sha256-hex-of-body>` with the JPEG as the
body.

| Status | Body | Meaning |
|---|---|---|
| 201 / 200 | `{"expiresAt": "<UTC ISO-8601>"}` | Stored / already stored, or deleted by a guest and not stored again |
| 401 | `{"error": "unauthorized"}` | Missing or wrong token |
| 400 | `{"error": "sha_mismatch" \| "bad_code" \| "bad_key"}` | Rejected photo |
| 413 | `{"error": "too_large" \| "session_full"}` | Over a limit |
| 410 | `{"error": "expired"}` | The Session expired or a guest deleted it |

`GET /api/auth` checks the token without uploading: `204` when it is right,
`401 {"error": "unauthorized"}` when it is missing or wrong. The app uses it
to check the token during setup.

`GET /healthz` answers `204` without a token, for health checks.

## Rollback

Going back to an older image or release is safe. Older servers ignore the
`previews/` directory in each Session and delete it with the Session, and
browsers' cached previews expire with the Session. They also ignore the
`deleted/` markers, so a photo a guest deleted is stored again if the app
re-uploads it after the rollback.

## Demo server

The project runs a public demo instance for trying Live Share, with a
published token and much tighter limits than a normal deployment. Its
URL, limits, proxy setup and operator runbook (kill switch, abuse,
acceptance test) are in
[`../docs/launch/demo-server.md`](../docs/launch/demo-server.md).

## Development

```bash
dart test        # from server/
```

The gallery's scripts, styles, fonts and icon live in `web/` and are
embedded into `lib/src/web_assets.g.dart`, so the server needs no files at
runtime. After editing `web/`, regenerate it from `server/`:

```bash
dart run tool/embed_web.dart
```

A test fails if the embedded assets don't match `web/`.

`package:shutterlink_server/shutterlink_server.dart` exposes
`ShutterlinkServer.start(...)`, which the app's end-to-end test uses to run
the server in-process.

## Third-party assets

- [PhotoSwipe](https://photoswipe.com) 5.4.4, unmodified, MIT licensed:
  [`web/PHOTOSWIPE-LICENSE`](web/PHOTOSWIPE-LICENSE), version and checksums in
  [`web/PHOTOSWIPE-VERSION`](web/PHOTOSWIPE-VERSION).
- [Manrope](https://github.com/googlefonts/manrope) (weights 600 and 800),
  SIL Open Font License 1.1: [`web/OFL.txt`](web/OFL.txt).
