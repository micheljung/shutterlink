# Announcement drafts

Launch day L = **Tue 2026-12-08**. Post from your own accounts, say you are
the developer, answer comments for 2-3 hours, never cross-post the same
text on the same day, and log every URL at the bottom.

Rule summaries below were checked on 2026-11-19 where marked **verified**.
Reddit blocks automated fetching, so Reddit rules are **unverified**: read
each subreddit's sidebar and rules page before posting.

## Facts to reuse

- MIT license, no account, no cloud, no analytics. Wi-Fi and USB.
- Tested with the Canon EOS R. Other cameras: untested or basic PTP.
- Auto Upload to Immich, WebDAV/Nextcloud, S3-compatible, SFTP.
- Live Share: guests scan a QR code and get their photos in a web gallery.
  Self-hostable Sessions server (`ghcr.io/micheljung/shutterlink-server`).
- Android APK on GitHub Releases (Obtainium works). Play: only mention it
  once it is live. iPhone builds from source, untested with a camera.
- Try it without a camera: **Try without a camera** on the start screen.
- Try Live Share without hosting anything: public demo server
  `https://demo.shutterlink.micheljung.ch`, upload token
  `643db5698319e126825cb18e35dea87c`. It is public and writable: anyone
  with a gallery link can view and add photos, galleries are deleted after
  about 25 hours, please do not upload private photos.
- Honest limitations: only the EOS R is tested; other Canon bodies are
  untested; generic PTP cameras get JPEG only; iPhone untested with a real
  camera; two update streams (GitHub/Obtainium vs store builds) need an
  uninstall to switch.
- Disclaimer for Canon communities: Shutterlink is not affiliated with or
  endorsed by Canon Inc. Canon and EOS are trademarks of Canon Inc.
- Attach the GIF (`docs/media/demo.gif`) first. Ask for camera-model reports.
- Use "Live Share" everywhere; never name the production Sessions server.

## Schedule

| Day | Where | Time (UTC) |
|---|---|---|
| Tue 12-08 | Show HN | 14:00-15:00 |
| Wed 12-09 | r/immich, Immich Discussions | 14:00-16:00 |
| Thu 12-10 | r/EOSR, r/canon | 14:00-16:00 |
| Fri 12-11 | r/selfhosted (new-projects thread) | any |
| 12-12 to 12-15 | Nextcloud forum, DPReview | any |
| on/after 2027-03-11 | awesome-selfhosted PR | - |

## Show HN

Rules (**verified**, news.ycombinator.com/showhn.html): title starts with
"Show HN"; something people can try (no sign-up friction); personal,
non-trivial project; no landing pages; no upvote campaigns; be present to
answer. Best days Tue-Thu, 14:00-16:00 UTC. Link to the GitHub repo, not
the landing page.

**Title:** Show HN: Shutterlink - open-source PTP/IP client to get photos off your camera

**First comment:**

> I'm the developer. Shutterlink is a Flutter app that talks PTP/IP (Wi-Fi)
> or PTP over USB directly to a Canon EOS R, with no vendor app and no
> account. It browses the card, downloads (JPEG and CR3), and can upload
> every new shot to your own Immich, WebDAV, S3 or SFTP while you shoot.
>
> The part I enjoy most is Live Share: you start a Session, the person you
> are photographing scans a QR code, and each photo you take of them shows
> up in their own web gallery a few seconds later, no app needed. It needs a
> small Sessions server (Dart, Docker image on GHCR). To try it without
> hosting one, there is a public demo server: https://demo.shutterlink.micheljung.ch
> with upload token `643db5698319e126825cb18e35dea87c`. It is public and writable:
> anyone with a gallery link can view and add photos, and galleries are
> deleted after about 25 hours, so please don't upload private photos.
>
> Honest limits: only tested on an EOS R; other Canon bodies are untested,
> generic PTP cameras get JPEG only, the iPhone build has never met a real
> camera. Without a camera, "Try without a camera" on the start screen turns
> the phone into a demo camera.
>
> Android APK: https://github.com/micheljung/shutterlink/releases/latest
> (Obtainium works). Source, MIT: https://github.com/micheljung/shutterlink
> Reports from other camera models would help a lot. Shutterlink is not
> affiliated with Canon Inc.

## r/selfhosted

Rules (**partly verified** via search results, re-read the sidebar): new
projects younger than about three months go only in the weekly Friday "new
projects" megathread (standalone posts get removed); at most roughly 10 %
of your activity may be self-promotion; check whether the sidebar asks for
disclosure of AI assistance and follow it. Flair per sidebar. So: post in the
megathread on **Fri 2026-12-11**, not on Tuesday.

**Text:**

> **Shutterlink: Live Share, a tiny self-hostable gallery server for event
> and portrait photographers (+ camera auto-upload to Immich/WebDAV/S3/SFTP)**
>
> I'm the developer. The server side is a single small Dart container
> (`ghcr.io/micheljung/shutterlink-server`, amd64 and arm64) with
> file-based storage, no database, no accounts. The Android app copies
> photos off a Canon EOS R over Wi-Fi or USB and pushes them to the server.
> Guests scan a QR code and watch their photos arrive in a web gallery;
> galleries are deleted after 30 days by default.
>
> The app also uploads each new shot to Immich, Nextcloud/WebDAV, S3 or
> SFTP while you keep shooting.
>
> Try before hosting: https://demo.shutterlink.micheljung.ch, upload token
> `643db5698319e126825cb18e35dea87c` (public and writable: anyone with a
> gallery link can see and add photos, deleted after ~25 h, please upload
> nothing private).
>
> Limits: only the EOS R is tested. MIT, no telemetry.
> https://github.com/micheljung/shutterlink

## r/immich

Rules (**unverified**): check the sidebar for self-promotion limits and
required flair; keep it about Immich. Wed 12-09.

> **Camera to phone to Immich while you shoot (Shutterlink, open source)**
>
> I'm the developer. Shutterlink connects to a Canon EOS R over Wi-Fi or
> USB and uploads every new photo to your Immich server through its API as
> you take it, in the background on Android. You can opt to remove the
> phone copy once Immich has it, restrict mobile data to JPEG only, and
> choose whether photos already on the card go along. Passwords/API keys
> stay in the phone's secure storage; self-signed certificates ask for
> fingerprint confirmation.
>
> Tested only with the EOS R. Feedback on large libraries, albums and RAW
> handling is welcome. APK: https://github.com/micheljung/shutterlink/releases/latest
> The GIF shows the flow.

## Immich Discussions

GitHub Discussions on immich-app/immich, category for showing projects
(name **unverified**, look for "Show and tell"). Same text as r/immich with
more detail on how the Immich upload is done (see docs and
`lib` for the exact API calls; do not claim more than the code does) and an
ask for edge cases. Wed 12-09.

## r/EOSR and r/canon

Rules (**unverified**): both usually limit self-promotion (about 10 %
ratio, often a flair or a mod message is required); r/canon may restrict
app promotion, so send modmail first and wait for approval. Thu 12-10.

> **Open-source replacement for Canon Camera Connect on the EOS R (Wi-Fi
> and USB, RAW and JPEG)**
>
> I'm the developer. I got tired of the vendor app, so I wrote one that
> talks to the camera directly: browse the card by day, select a range,
> download JPEG and CR3 exactly as written, resume after the Wi-Fi drops,
> delete from the card. Over USB it works with a cable. It can also upload
> every new shot to your own server while you shoot, and hand portrait
> subjects a web gallery via QR code (Live Share).
>
> Tested only on the EOS R. If you have an R5, R6, RP or older EOS body,
> I'd love to hear whether it connects. Free, MIT, no account, no ads.
> https://github.com/micheljung/shutterlink
>
> Shutterlink is not affiliated with or endorsed by Canon Inc. Canon and
> EOS are trademarks of Canon Inc.

## Nextcloud forum

help.nextcloud.com, a showcase or "Apps"/community category (**unverified**,
pick the category for community projects and read its pinned rules). 12-12.

> Shutterlink: camera auto-upload straight to Nextcloud over WebDAV.
> I'm the developer. [Focus: WebDAV auth with app passwords, which folder
> layout, behaviour with self-signed certificates, background upload on
> Android.] Tested with a Canon EOS R. Feedback on server setups welcome.
> Link, GIF, limitations as above.

## DPReview (Canon EOS R forum)

DPReview is winding down or changing; **verify the forums are still open
and accepting posts** before drafting more (**unverified**). Tone:
user-focused, short, no marketing, mention the trademark disclaimer,
point to the GIF, ask for camera reports. 12-14.

## awesome-selfhosted PR

**Submit on/after 2027-03-11.** Rule (**verified** via CONTRIBUTING.md
snippets): software must be first released more than 4 months ago, counted
from its first release, and actively maintained. First release is 1.5.0 or
earlier; check the earliest tag date before submitting, and re-count if the
first public release is later than planned. Entries are added through the
awesome-selfhosted-data repository (YAML file under `software/`), not by
editing the README.

Draft `software/shutterlink.yml` (check field names against the current
template):

```yaml
name: Shutterlink
website_url: https://shutterlink.micheljung.ch
source_code_url: https://github.com/micheljung/shutterlink
description: Sessions server for sharing photos taken with the Shutterlink camera app as live web galleries; the app also auto-uploads to WebDAV, S3, SFTP and Immich.
licenses:
  - MIT
platforms:
  - Dart
  - Docker
tags:
  - Photo and Video Galleries
```

## Posted URLs

| Date | Where | URL |
|---|---|---|
