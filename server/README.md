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
    }

    location / {
        proxy_pass http://127.0.0.1:8080;
    }
}
```

Keep `client_max_body_size` at or above the 50 MiB photo limit; otherwise
the proxy rejects large photos with a bare 413, which the app shows as a
server configuration problem instead of dropping the photo.

## Privacy and security

- The Session Code is the only credential for a gallery. Unknown, empty,
  expired and malformed codes all get the same "your photos are on their
  way" page, so existing codes cannot be discovered.
- Session directories are named by an HMAC of the code with a random secret
  (`<data-dir>/secret`, created on first run with mode 0600). Neither the code
  nor its plain hash is stored.
- Every response carries `Content-Security-Policy: default-src 'none';
  img-src 'self'; style-src 'self'; form-action 'self'; base-uri 'none';
  frame-ancestors 'none'` plus `Cache-Control: no-store`,
  `Referrer-Policy: no-referrer`, `X-Robots-Tag: noindex` and
  `X-Content-Type-Options: nosniff`. Pages contain no scripts.
- Uploads require `Authorization: Bearer <token>`, compared in constant time.

## Retention

A Session expires `--retention-days` after its first upload; the gallery
shows the date. A cleanup job runs at startup and then hourly. It deletes
expired Sessions and leaves a tombstone for 60 days, so late uploads to an
expired Session get `410 Gone` and the app stops retrying them.

## Limits

- 50 MiB per photo, 2 GiB per Session.
- "Download all" streams an uncompressed zip. At most 2 zips are built at a
  time; further requests wait up to 30 s and then get `503` with
  `Retry-After`.
- Single process only: Sessions are locked in memory, so do not run several
  instances on one data directory.

## Upload API

`PUT /api/sessions/<code>/photos/<sha256-hex-of-body>` with the JPEG as the
body.

| Status | Body | Meaning |
|---|---|---|
| 201 / 200 | `{"expiresAt": "<UTC ISO-8601>"}` | Stored / already stored |
| 401 | `{"error": "unauthorized"}` | Missing or wrong token |
| 400 | `{"error": "sha_mismatch" \| "bad_code" \| "bad_key"}` | Rejected photo |
| 413 | `{"error": "too_large" \| "session_full"}` | Over a limit |
| 410 | `{"error": "expired"}` | The Session was already deleted |

`GET /api/auth` checks the token without uploading: `204` when it is right,
`401 {"error": "unauthorized"}` when it is missing or wrong. The app uses it
to check the token during setup.

`GET /healthz` answers `204` without a token, for health checks.

## Development

```bash
dart test        # from server/
```

`package:shutterlink_server/shutterlink_server.dart` exposes
`ShutterlinkServer.start(...)`, which the app's end-to-end test uses to run
the server in-process.
