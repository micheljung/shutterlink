# Public demo server

A public Sessions server for trying Live Share without hosting your own.
It is a separate instance with its own token, data and limits; private
galleries never live on it.

| | |
|---|---|
| URL | `https://demo.shutterlink.micheljung.ch` |
| Upload token | `643db5698319e126825cb18e35dea87c` |
| Contact, abuse reports | shutterlink@micheljung.ch |
| Host | mj-server, module `modules/shutterlink-demo.nix` (option `mj.shutterlinkDemo.enable`) |

In the app: Settings → Sessions → Connect Sessions, enter the URL and the
token above.

## What visitors must know

**Do not upload anything private.** The token is public, so:

- Anyone with a gallery link can add photos to that gallery, delete
  photos or the whole gallery, and download everything as a zip.
- Session Codes are chosen by the app, so anyone can create a gallery
  under any free code.
- Don't share a demo gallery link with anyone you wouldn't show every
  photo to, including photos someone else might add.

Every gallery page shows this notice, added by the proxy:

> Public demo: anyone with this link can add or delete photos. Everything
> here is deleted within about 25 hours. Report abuse:
> shutterlink@micheljung.ch

## Limits

| Limit | Value | Enforced by |
|---|---|---|
| Photo size | 50 MiB | server (and the proxy's 50 MiB body limit) |
| Session size | 2 GiB | server |
| Total store | **4 GiB** for all Sessions and their previews together, so at most about two full Sessions fit at once | fixed-size ext4 image |
| Uploads (`/api`) | 10 per minute per IP, after a burst of 20; 60 per minute for everyone together, after a burst of 60 | proxy |
| Gallery requests (`/s/…`: pages, photos, thumbnails, zips, deletes, live updates) | 30 per minute per IP, after a burst of 60 | proxy |
| Other requests (`/static/…` and anything else except `/healthz`) | 120 per minute per IP, after a burst of 120 | proxy |
| Concurrent requests | 10 per IP, 64 for everyone together; of them at most 3 live-update streams per IP (an open gallery holds one) | proxy |
| Download speed per request | the first 2 MiB of every response at full speed, then 512 KiB/s: thumbnails and previews load at once, a 50 MiB original takes about 100 s, a 2 GiB zip about 70 min | proxy |
| Total bandwidth | **50 Mbit/s** (about 6 MiB/s) for everything the proxy sends | `tc` on the proxy's edge interface |
| Retention | about 25 h (1 day after the first upload, cleanup runs hourly) | server |

Rejected requests get `429`. Limits are per client IP, and per /64 for
IPv6: everyone behind one NAT, carrier-grade NAT or event Wi-Fi shares
them. A gallery with more than about 60 photos may 429 some thumbnails on
the first load; they load on the next refresh. When 64 requests are open
at once, everyone gets `429` until some finish. The per-request speed,
the request-rate limits and the 64-request cap only bound how one
address or the crowd uses the bandwidth; the 50 Mbit/s shaping is the
aggregate bound on the uplink.

`429`s are not logged: the proxy logs only critical errors, by design.
To count them, use Caddy's metrics or an nginx `stub_status` endpoint;
neither is configured.

**Wipes.** The store is recreated empty whenever the server is restarted
explicitly (`systemctl restart`, a deploy that changes the module, a
reboot, the disk guard). Whether a crash restart also wipes it:
observed behaviour: TBD at AC7. Either way, data is deleted within about
25 h, possibly earlier on any restart. A wipe also replaces the server
secret, so old gallery links show "your photos are on their way".

**Logs.** Neither Caddy nor the proxy writes access logs. Caddy's error
log (journald) can still hold a client IP briefly, for example after a
failed TLS handshake; it rotates with journald.

## Setup on mj-server

| Piece | Name |
|---|---|
| Networks | `shutterlink-demo-networks.service` creates `sl-demo-int` (`10.89.10.0/24`, `--internal`) and `sl-demo-edge` (`10.89.11.0/24`), both `isolate=strict`, without DNS; it removes them when stopped |
| Server container | `shutterlink-demo` (unit `podman-shutterlink-demo`), only on `sl-demo-int` at `10.89.10.10`, no published port, `--retention-days=1` |
| Proxy container | `shutterlink-demo-proxy` (unit `podman-shutterlink-demo-proxy`), unprivileged nginx (uid 101, no capabilities) on `sl-demo-edge` (interface pinned to `eth0`) and `sl-demo-int`, published on `127.0.0.1:8790` |
| Bandwidth cap | `ExecStartPost` of `podman-shutterlink-demo-proxy` shapes the proxy's `eth0` with `tc … tbf rate 50mbit`, on every (re)start; if that fails it logs "could not shape the proxy's edge interface" and the demo runs uncapped |
| Store | `shutterlink-demo-store.service`: `/var/lib/shutterlink-demo.img` (4 GiB, ext4) loop-mounted on `/var/lib/shutterlink-demo`; not under `/persist`, so never backed up |
| Disk guard | `shutterlink-demo-disk-guard.timer`, every 15 min: at >= 90 % of space or of inodes used it restarts the server, which wipes the store |
| Caddy vhost | `demo.shutterlink.micheljung.ch`, SSO-exempt, access log discarded |
| Monitor | Uptime Kuma "Shutterlink public demo" on `/healthz` |

Neither container is on the default podman bridge, where the host's other
services run. The server's network is internal: no route out, and
the server needs none. `isolate=strict` blocks forwarding between the demo
networks and every other podman network. Caddy reaches the proxy through
the published port on the edge network, so nginx trusts
`X-Forwarded-For` only from `10.89.11.0/24` (and `127.0.0.1`) and keys its
limits on that client IP. nginx reaches the server at its fixed address,
with no DNS.

**Known residual risk.** The proxy container keeps NAT egress on the
edge network, so a compromised nginx could reach LAN and host services
through host addresses. Mitigations are follow-ups that need testing on
the host: an iptables mangle rule dropping new connections from the
edge bridge, or a unix socket between Caddy and nginx instead of the
edge network.

## Before enabling

The module merges disabled. Enable it only when every item holds:

1. DNS: `dig +short demo.shutterlink.micheljung.ch` shows the CNAME
   target and an address of mj-server. Without it Caddy's certificate
   requests fail and back off.
2. Digests: `serverImage` in the module points at the real
   `shutterlink-server:1.5.0@sha256:…` digest (from the `v1.5.0` Docker
   workflow run, or `crane digest ghcr.io/micheljung/shutterlink-server:1.5.0`).
   The build refuses to enable the module while it is the all-zero
   placeholder. The nginx digest is already real; refresh it if it is
   months old.
3. The demo subnets are free: `ip route | grep '10\.89\.1[01]\.'` prints
   nothing, and no podman network uses them (`sudo podman network ls -q |
   xargs sudo podman network inspect --format '{{.Name}} {{.Subnets}}'`).
4. The mailbox shutterlink@micheljung.ch receives mail.

Then set `mj.shutterlinkDemo.enable = true;` in
`hosts/mj-server/configuration.nix` and merge it as a merge request on
GitLab (`gitlab.com/michel.jung89/mj-server`). Deploys are manual:
nothing changes until you rebuild on mj-server:

```bash
sudo nixos-rebuild switch --refresh --flake git+ssh://git@gitlab.com/michel.jung89/mj-server.git#mj-server
```

## Acceptance test (AC7)

Run after enabling, before announcing the demo anywhere. Record the
results here. "IP A" is your machine; "IP B" is a second network (a phone
on mobile data, or a GitHub Actions runner).

```bash
D=https://demo.shutterlink.micheljung.ch
T=643db5698319e126825cb18e35dea87c
C=ac-seven-test-gallery
START=$(date '+%Y-%m-%d %H:%M:%S')

# Health, through the proxy: 204
curl -s -o /dev/null -w '%{http_code}\n' $D/healthz

put() {  # put <file>
  curl -s -o /dev/null -w '%{http_code}\n' -X PUT \
    -H "Authorization: Bearer $T" --data-binary @"$1" \
    "$D/api/sessions/$C/photos/$(sha256sum "$1" | cut -d' ' -f1)"
}

# One real upload, then open $D/s/$C in a browser: the notice is at the
# bottom of the page; photos, thumbnails and the zip are unchanged
put some-photo.jpg

# From IP A: 30 PUTs in under 6 s -> at most 21 non-429 (1 + burst 20;
# the shared upload burst of 60 does not bind here)
for i in $(seq 30); do head -c 1000 /dev/urandom > /tmp/p$i; done
for i in $(seq 30); do put /tmp/p$i; done | sort | uniq -c

# From IP A: 80 gallery-page GETs within about 1 s -> at most 61 non-429.
# Keep parallelism under 10, or limit_conn rejects some first.
seq 80 | xargs -P 8 -I{} curl -s -o /dev/null -w '%{http_code}\n' \
  $D/s/$C | sort | uniq -c
```

Wait two minutes (the budget refills at 1 request per 2 s), then repeat
the GET line against a thumbnail URL, which uses the `/s/` prefix
location instead of the gallery-page regex location; it must be bounded
the same way:

```bash
seq 80 | xargs -P 8 -I{} curl -s -o /dev/null -w '%{http_code}\n' \
  $D/s/$C/t/x.jpg | sort | uniq -c
```

Spread over 5 s instead of 1 s, the bound is 63.

Everything outside `/api` and `/s/` has its own budget; `/healthz` has
none. From IP A, 200 GETs within about 2 s -> at most 125 non-429
(1 + burst 120, plus 2 per second elapsed); 404s count as non-429. The
same 200 against `/healthz` -> no `429` at all:

```bash
seq 200 | xargs -P 8 -I{} curl -s -o /dev/null -w '%{http_code}\n' \
  $D/static/x | sort | uniq -c
seq 200 | xargs -P 8 -I{} curl -s -o /dev/null -w '%{http_code}\n' \
  $D/healthz | sort | uniq -c
```

Immediately afterwards, from IP B (set `D`, `T`, `C` and `put` there
too): the first PUT and the first GET succeed, which proves the limits
follow the real client IP. If they get `429`, Caddy's connections reach
nginx from an untrusted address and every client shares one budget; see
the network checks below.

```bash
head -c 1000 /dev/urandom > /tmp/b && put /tmp/b
curl -s -o /dev/null -w '%{http_code}\n' $D/s/$C
```

Connection limit, from IP A: 12 concurrent live-update streams, at most
3 get `200`, at least 9 get `429`:

```bash
for i in $(seq 12); do
  curl -s -o /dev/null -m 5 -w '%{http_code}\n' $D/s/$C/events &
done | sort | uniq -c; wait
```

On mj-server:

```bash
# Networks: sl-demo-int internal, the server only there at 10.89.10.10,
# the proxy on sl-demo-edge and sl-demo-int
sudo podman network ls
sudo podman network inspect --format '{{.Name}} internal={{.Internal}} {{.Subnets}} {{.Options}}' sl-demo-int sl-demo-edge
sudo podman inspect --format '{{.Name}}: {{range $n, $v := .NetworkSettings.Networks}}{{$n}}={{$v.IPAddress}} {{end}}' shutterlink-demo shutterlink-demo-proxy

# Isolation: each must time out or fail. OTHER_IP:PORT is a service of
# another container on the default bridge (sudo podman inspect <name>)
sudo podman run --rm --network sl-demo-int docker.io/library/alpine:3 wget -T 5 -qO- http://1.1.1.1
sudo podman run --rm --network sl-demo-edge docker.io/library/alpine:3 wget -T 5 -qO- http://OTHER_IP:PORT
sudo podman run --rm docker.io/library/alpine:3 wget -T 5 -qO- http://10.89.10.10:8080/healthz

# Self-healing: each must answer 204 again within 60 s, without help
sudo podman kill shutterlink-demo
sudo ls /var/lib/shutterlink-demo/sessions   # did the upload survive? record it under "Wipes"
sudo podman kill shutterlink-demo-proxy

# Store: loop-mounted ext4, 4 GiB, nothing under /persist
findmnt /var/lib/shutterlink-demo
ls /persist | grep -i demo                     # nothing

# Bandwidth cap: a tbf qdisc at 50Mbit on the proxy's eth0, which has
# an address in 10.89.11.0/24; no "could not shape" line in the journal
P=$(sudo podman inspect --format '{{.State.Pid}}' shutterlink-demo-proxy)
sudo nsenter -t "$P" -n ip -4 -o addr show dev eth0
sudo nsenter -t "$P" -n tc qdisc show dev eth0
sudo journalctl -u podman-shutterlink-demo-proxy --since "$START" | grep -c 'could not shape'   # 0

# Explicit restart wipes: only lost+found, secret and empty
# sessions/ tombstones/ tmp/ remain
sudo systemctl restart podman-shutterlink-demo
sudo ls -A /var/lib/shutterlink-demo /var/lib/shutterlink-demo/sessions

# Privacy: no access log, no client IP in the logs (replace IP_A)
ls /var/log/caddy | grep demo                  # nothing
sudo journalctl -u caddy --since "$START" | grep IP_A | grep -vi 'tls handshake'   # nothing
sudo journalctl -u podman-shutterlink-demo-proxy --since "$START" | grep -c IP_A   # 0
```

The backup covers only `/persist` and `/var/lib/vaultwarden`, so the
store is never in restic.

## Kill switch

Stop first, investigate after. For illegal content that the law requires
you to preserve, use the procedure under "Abuse and takedown" instead:
this one deletes the store.

1. On mj-server, immediately (the store unmounts and its image is
   deleted):

   ```bash
   sudo systemctl stop shutterlink-demo-disk-guard.timer podman-shutterlink-demo-proxy podman-shutterlink-demo shutterlink-demo-store
   ```

2. Merge `mj.shutterlinkDemo.enable = false;` (or a revert of the enable
   commit) on GitLab, then rebuild on mj-server:

   ```bash
   sudo nixos-rebuild switch --refresh --flake git+ssh://git@gitlab.com/michel.jung89/mj-server.git#mj-server
   ```

   Until then, a reboot (the containers start at boot) or any rebuild
   from the old `main` starts the demo again.

The Uptime Kuma monitor alerts while the demo is down; it disappears
with the disable commit.

## Abuse and takedown

1. Reports arrive at shutterlink@micheljung.ch. Reply within 24 h.
2. Urgent but not illegal: kill switch (above). Otherwise purge with
   `sudo systemctl restart podman-shutterlink-demo`, which wipes every
   gallery.
3. Illegal content: report it to the authorities as local law requires,
   and preserve nothing beyond what the law requires. The kill switch and
   any server restart delete the store, so take it offline without
   stopping the server unit first. Pause the server at once, so the
   hourly retention cleanup can't delete the reported gallery before the
   copy:

   ```bash
   # Offline: no public access, no disk-guard wipe, no cleanup
   sudo systemctl stop shutterlink-demo-disk-guard.timer podman-shutterlink-demo-proxy
   sudo podman pause shutterlink-demo
   ```

   Only if preservation is legally required, copy the store image to a
   root-only directory on `/` (outside `/persist`, so not in restic).
   The copy needs about 4 GiB free on `/root`; check first. Keep the
   store frozen until `cmp` prints `OK`:

   ```bash
   df -h /root
   F=/root/shutterlink-demo-evidence/"$(date +%F-%H%M)".img
   sudo fsfreeze -f /var/lib/shutterlink-demo
   sudo install -d -m 0700 /root/shutterlink-demo-evidence
   sudo cp --sparse=always /var/lib/shutterlink-demo.img "$F"
   sudo cmp /var/lib/shutterlink-demo.img "$F" && echo OK
   sudo fsfreeze -u /var/lib/shutterlink-demo
   ```

   Only after `OK`, stop the rest. This **deletes the store image**;
   then finish with step 2 of the kill switch:

   ```bash
   sudo systemctl stop podman-shutterlink-demo shutterlink-demo-store
   ```

   Don't stop `podman-shutterlink-demo` before the copy: the store unit
   is part of it and deletes its image when it stops.
4. Decide at the next review whether the demo stays (see shutdown
   criteria).

## Disk full

The disk guard wipes the store at 90 % of space or inodes. Count its
firings:

```bash
sudo journalctl -u shutterlink-demo-disk-guard --since today | grep -c 'wiping it'
```

If the store unit fails (for example the image can't be created because
`/` is full): `df -h /`, free space, then
`sudo systemctl restart podman-shutterlink-demo`. To recover by hand:

```bash
sudo systemctl stop podman-shutterlink-demo-proxy podman-shutterlink-demo shutterlink-demo-store
sudo umount /var/lib/shutterlink-demo 2>/dev/null; sudo rm -f /var/lib/shutterlink-demo.img
sudo systemctl start podman-shutterlink-demo podman-shutterlink-demo-proxy
```

## Rotating the token

Edit the token in `modules/shutterlink-demo.nix`, merge it on GitLab and
rebuild on mj-server (the command under "Before enabling"). The server
restarts, which also wipes the store. Update the token here and in the
README.

## Shutdown criteria

Disable the demo (kill switch) on any of:

- any report of illegal content (with the procedure under "Abuse and
  takedown" when the law requires preservation);
- the disk guard firing more than 3 times in a day;
- egress above **50 GB per day**. Every client byte passes the proxy, so
  read its counter once a day (it resets when the proxy restarts; the
  sent figure also counts uploads passed on to the server, so it
  overstates egress):

  ```bash
  sudo podman stats --no-stream --format '{{.NetIO}}' shutterlink-demo-proxy
  ```

- the home uplink saturating (Uptime Kuma latency alerts).

The 50 Mbit/s cap is built in: the proxy unit shapes its edge interface
(`eth0` in the container) on every start. To tighten it until the next
proxy restart, without a deploy, rerun it with a lower rate:

```bash
sudo nsenter -t "$(sudo podman inspect --format '{{.State.Pid}}' shutterlink-demo-proxy)" -n \
  tc qdisc replace dev eth0 root tbf rate 20mbit burst 1mb latency 50ms
```

## Review at L+14 (Tue 2026-12-22)

Decide from abuse reports, disk-guard firings and egress whether to keep
the writable demo, switch to a read-only sample gallery, or turn it off.
Per-Session upload tokens in the server would close gallery injection for
good and are the follow-up if the demo stays.
