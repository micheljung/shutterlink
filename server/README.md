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
| `--upload-token-file` | `$SHUTTERLINK_UPLOAD_TOKEN` | Operator token the app sends when uploading |
| `--tip "Label=URL"` | none | Tip button on every gallery; repeatable. Only `http`/`https` URLs are accepted, anything else exits with code 64 |
| `--retention-days` | 30 | Days a Session is kept after its first upload |
| `--port` | 8080 | Listening port |
| `--address` | 127.0.0.1 | Listening address |

Enter the server URL and the same token in the app under
Settings → Sessions. The server stops cleanly on `SIGINT`/`SIGTERM`.

Tips never gate anything: every download works the same with or without
tip links.

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

## Development

```bash
dart test        # from server/
```

`package:shutterlink_server/shutterlink_server.dart` exposes
`ShutterlinkServer.start(...)`, which the app's end-to-end test uses to run
the server in-process.
