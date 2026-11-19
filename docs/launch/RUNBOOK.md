# Launch runbook

Launch day **L = Tue 2026-12-08**. Written 2026-11-19 (L-19). Every step is
labelled **AUTO** (an agent or CI does it) or **MANUAL** (you do it).

Decisions this runbook assumes:

- Domain: `shutterlink.micheljung.ch` (GitHub Pages: landing page and
  privacy policy). No registrar step; you add DNS records yourself.
- Demo server host: `demo.shutterlink.micheljung.ch`, CNAME to
  `s1.micheljung.ch`. Mentioned only in the README and in the community
  posts; never in the app, the Play listing, the changelog or the landing
  page. The privacy policy still describes it.
- Contact and abuse address: `shutterlink@micheljung.ch` (check that the
  mailbox or alias exists and forwards).
- Play: Data safety "No data collected"; reviewers use **Try without a
  camera** (no demo-server dependency); Canon variant N (one "Tested with
  the Canon EOS R." line plus the not-affiliated disclaimer in the full
  description); `shutterlink-release.jks` doubles as the Play upload key;
  Play generates the app-signing key.
- You merge every mj-server pull request yourself.

Related documents: [`demo-server.md`](demo-server.md),
[`play-console-answers.md`](play-console-answers.md),
[`announcements.md`](announcements.md),
[`fdroid-followup.md`](fdroid-followup.md), [`../../RELEASING.md`](../../RELEASING.md).

## Timeline

Status as of 2026-11-19: nothing is late yet. Rows that fall on today or
tomorrow are tight, so start M2 and M3/M4 first.

| When | Step | Kind |
|---|---|---|
| L-19 Thu 11-19 (today) | Plan approved; M2 DNS can already be added | MANUAL |
| L-18 Fri 11-20 | M2 DNS + Pages custom domain, M3 Play account and developer verification, M4 service account | MANUAL |
| L-18 to L-15 (11-20 to 11-23) | A6 record the foreground-service video, upload to YouTube as Unlisted. Prerequisite of M8 | MANUAL |
| L-18 to L-16 | Pull requests for distribution, assets and the mj-server demo module; reviews | AUTO |
| L-18 to L-16 | Merge the mj-server PR while the demo module is **disabled** (inert) as soon as it is reviewed | MANUAL |
| L-15 Mon 11-23 | Merge the shutterlink PRs; check the site (AC1); agent tags `v1.5.0`; M10 enable PR; M5 create app | AUTO + MANUAL |
| L-15 Mon 11-23 | M6 first AAB to Internal testing, set `PLAY_ENABLED=true`; M7 forms; M8 FGS declaration | MANUAL |
| L-14 Tue 11-24 | Metadata dry run, then real metadata upload (agent dispatch); M9 production submission. Slip at most to Wed 11-25, still before US Thanksgiving (Thu 11-26) | AUTO + MANUAL |
| L-14 to L-10 | Full demo-server test suite (see `demo-server.md`); install test of 1.5.0 from the internal track; F-Droid recipe bump | AUTO + MANUAL |
| After production approval (by L-2 at the latest, else after launch) | Agent tags `v1.5.1`; end-to-end internal draft upload; you roll it out | AUTO + MANUAL |
| L-2 Sun 12-06 | Is Play live? If not, launch with GitHub/Obtainium and add the Play badge later | MANUAL |
| **L Tue 12-08** 14:00-15:00 UTC | Show HN | MANUAL |
| L+1 Wed 12-09 | r/immich, Immich Discussions | MANUAL |
| L+2 Thu 12-10 | r/EOSR, r/canon | MANUAL |
| L+3 Fri 12-11 | r/selfhosted new-projects thread | MANUAL |
| L+4 to L+7 | Nextcloud forum, DPReview | MANUAL |
| L+14 Tue 12-22 | Demo-server review: keep writable, switch to read-only sample gallery, or disable | MANUAL |
| L+30 | Review installs and issues | MANUAL |
| 2027-02-11 | F-Droid submission ([`fdroid-followup.md`](fdroid-followup.md)) | MANUAL |
| 2027-03-11 | awesome-selfhosted PR (4-month rule) | MANUAL |

## Steps

### M2 DNS and GitHub Pages (MANUAL, L-18 Fri 11-20)

Lead time: DNS 5 minutes to 48 hours, the Pages HTTPS certificate up to
24 hours, so do it first.

1. At your DNS provider for `micheljung.ch` add:

   | Name | Type | Value |
   |---|---|---|
   | `shutterlink` | CNAME | `micheljung.github.io.` |
   | `demo.shutterlink` | CNAME | `s1.micheljung.ch.` (demo server; add it now so the M10 probe can resolve it) |

   No A/AAAA records and no TXT challenge are needed for a subdomain
   CNAME. `www.shutterlink` is not needed.
2. GitHub: repository `micheljung/shutterlink` -> **Settings** ->
   **Pages** -> **Build and deployment** -> Source **GitHub Actions**.
3. Same page -> **Custom domain** -> enter `shutterlink.micheljung.ch` ->
   **Save**. Wait for "DNS check successful".
4. Tick **Enforce HTTPS** as soon as it becomes available (up to 24 h).
5. The site itself is deployed by `.github/workflows/pages.yml` after the
   launch-site pull request is merged to `main` (**AUTO**). To redeploy:
   Actions -> **Pages** -> **Run workflow**.
6. Check: `dig +short shutterlink.micheljung.ch` shows
   `micheljung.github.io.`; `curl -sI https://shutterlink.micheljung.ch/`
   and `.../privacy/` both return 200 with a valid certificate (AC1).

If the certificate is late, use the fallback privacy URL
`https://github.com/micheljung/shutterlink/blob/main/PRIVACY.md` in Play
Console and switch later.

### M3 Play account and developer verification (MANUAL, L-18)

1. play.google.com/console -> **Settings** (gear, left) -> **Developer
   account** -> **Account details**. Note the type (Personal or
   Organization) and, for a personal account, the creation date; complete
   any identity banner shown on the home page.
2. Android developer verification (*from memory, unverified*: enforcement
   for sideloaded apps begins in a few countries in 2026 and widens in
   2027): follow the Play Console banner or the Android Developer Console
   and register package `ch.micheljung.shutterlink` together with the
   GitHub release certificate SHA-256 (the value of the repository variable
   `SHUTTERLINK_CERT_SHA256`). It can take days; do it now.

### M4 Service account (MANUAL, L-18)

Starts the up-to-24-hour permission propagation.

1. console.cloud.google.com -> project picker (top bar) -> **New
   project** -> name `shutterlink-play` -> **Create**; select it.
2. Menu -> **APIs & Services** -> **Library** -> search "Google Play
   Android Developer API" -> **Enable**.
3. Menu -> **IAM & Admin** -> **Service Accounts** -> **Create service
   account** -> name `play-publisher` -> **Create and continue** -> grant no
   role -> **Done**. Copy its e-mail address
   (`play-publisher@shutterlink-play.iam.gserviceaccount.com`).
4. Open the service account -> **Keys** -> **Add key** -> **Create new
   key** -> **JSON** -> **Create**. A JSON file downloads.
5. Play Console -> **Users and permissions** (left menu, or Home) ->
   **Invite new users** -> paste the service account e-mail. Under
   **Account permissions** tick: *Release apps to testing tracks*, *Release
   to production, exclude devices, and use Play App Signing*, *Manage store
   presence*. **Invite user**. Account-level permissions are used because
   the app does not exist yet.
6. GitHub: repository -> **Settings** -> **Secrets and variables** ->
   **Actions** -> **Secrets** -> **New repository secret** ->
   Name `PLAY_SERVICE_ACCOUNT_JSON`, Secret: the full contents of the JSON
   file -> **Add secret**. It is a plain repository secret (no protected
   Environment). Keep a copy in Vaultwarden and delete the local file.
7. Do **not** set `PLAY_ENABLED` yet.

Existing secrets and variables are reused unchanged:
`SHUTTERLINK_KEYSTORE_BASE64`, `SHUTTERLINK_KEYSTORE_PASSWORD`,
`SHUTTERLINK_KEY_ALIAS`, `SHUTTERLINK_KEY_PASSWORD` (secrets) and
`SHUTTERLINK_CERT_SHA256`, `NEXUS_USERNAME` (variables). New Play-related
settings:

| Name | Kind | Value and when |
|---|---|---|
| `PLAY_SERVICE_ACCOUNT_JSON` | secret | M4 step 6 |
| `PLAY_ENABLED` | variable | `true`, after M6 |
| `PLAY_RELEASE_STATUS` | variable | unset or `draft` until production is approved, then `completed` |

### A6 Foreground-service video (MANUAL, L-18 to L-15)

30-60 s on a real phone with the camera: start Live transfer, lock the
screen, show the notification with progress, show a photo arriving. Upload
to YouTube as **Unlisted**, keep the link for M8.

### Distribution and assets pull requests (AUTO then MANUAL)

Agents prepare the shutterlink pull requests (`launch-distribution`,
`launch-assets`, `launch-site`) and the mj-server one. **MANUAL:** review
and merge them. For mj-server: merge the module PR while it is disabled;
the enable PR is M10.

### D6 Tag v1.5.0 (AUTO, L-15 Mon 11-23)

The agent pushes tag `v1.5.0` after the pull requests are merged and
`pubspec.yaml` says `1.5.0+6`. Expected: GitHub Release with
`shutterlink-1.5.0+6.apk`, no `.aab` asset, workflow artifact `aab`,
Nexus APK, image `ghcr.io/micheljung/shutterlink-server:1.5.0`; the
`play` job is skipped because `PLAY_ENABLED` is unset. **MANUAL once:**
make the GHCR package public (GitHub -> Packages -> `shutterlink-server`
-> Package settings -> Change visibility -> Public).

### M5 Create the app (MANUAL, L-15)

Play Console -> **Home** -> **Create app**: name `Shutterlink`, default
language English (United States) - en-US, **App**, **Free**, accept the
declarations -> **Create app**.

- **Grow users** -> **Store presence** -> **Main store listing**: category
  **Photography**; contact e-mail `shutterlink@micheljung.ch`; website
  `https://shutterlink.micheljung.ch`. (Category may be under
  **Store settings**.)
- **Policy and programs** -> **App content** -> **Privacy policy**:
  `https://shutterlink.micheljung.ch/privacy/`.
- The listing text and graphics are uploaded later by the metadata
  dispatch; you may also paste them from `fastlane/metadata/android/en-US/`.

### M6 First release by hand (MANUAL, L-15)

The Play API cannot create the first release.

1. GitHub -> **Actions** -> workflow **Release** -> the run for `v1.5.0` ->
   **Artifacts** -> download `aab` and unzip it.
2. Play Console -> **Test and release** -> **Testing** -> **Internal
   testing** -> **Create new release**.
3. **Play App Signing**: choose **Use Google-generated key** (never upload
   the `.jks`). Upload `shutterlink-1.5.0+6.aab`. Release notes: the text
   of `fastlane/metadata/android/en-US/changelogs/6.txt`.
4. **Next** -> **Save** -> **Review release** -> **Start rollout to
   Internal testing**.
5. **Testers** tab -> create an e-mail list with your address, tick it, and
   open the opt-in link on your phone.
6. **Test and release** -> **App integrity** -> **App signing** -> copy the
   app-signing certificate SHA-256 and give it to the agent for
   `RELEASING.md`.
7. GitHub -> **Settings** -> **Secrets and variables** -> **Actions** ->
   **Variables** -> **New repository variable**: `PLAY_ENABLED` = `true`.
   Wait at least ~24 h after M4 before the first API run.

### M7 App content (MANUAL, L-15)

Play Console -> **Policy and programs** -> **App content**. Answers come
from [`play-console-answers.md`](play-console-answers.md): Privacy policy,
Ads (No), **App access** (all functionality available; tap **Try without a
camera** on the start screen), Content rating questionnaire, Target
audience (18+), **Data safety** ("No data collected"), Government apps
(No), Financial features (None), Health (No), Advertising ID (No).

Accepted risk: Play may decide that uploads to a developer-run server are
data collection. If a review flags it, switch Data safety to "collected,
optional" and mention the demo server in the policy only (it already is).

### M8 Foreground-service declaration (MANUAL, L-15)

**App content** -> **Foreground service permissions** -> **Connected
device** -> paste the description from `play-console-answers.md` and the A6
YouTube link -> **Save**.

### Metadata upload (AUTO, L-14 Tue 11-24)

After M6, `PLAY_ENABLED=true` and about 24 h after M4, the agent
dispatches the Release workflow with `tag=v1.5.0 mode=metadata
dry_run=true` (validate only), then `dry_run=false`. The `apk` job must be
skipped and the Release assets unchanged. Console then shows the new
listing, screenshots and feature graphic. If this fails, paste the listing
by hand; launch does not wait for it.

### M9 Production submission (MANUAL, L-14, slip max. to L-13)

Because reviewers use the in-app camera-less mode, this does not depend on
the demo server.

1. **Test and release** -> **Production** -> **Countries / regions** ->
   **Add countries / regions** -> select all -> **Add**.
2. **Create new release** -> **Add from library** -> pick versionCode 6 ->
   **Next** -> **Save**.
3. **Publishing overview** -> **Send changes for review**.
4. After approval: GitHub -> **Variables** -> set `PLAY_RELEASE_STATUS` =
   `completed`. Later releases: Internal testing -> **Promote release** ->
   Production, or dispatch with `track=production`.
5. Then the agent tags `v1.5.1` for the end-to-end internal draft upload
   (rolled out by you). If production approval has not arrived by L-2, this
   moves after launch.

### M10 Demo server on mj-server (MANUAL + AUTO, L-15)

Full details, limits and kill switch: [`demo-server.md`](demo-server.md).
mj-server auto-upgrade is disabled, so merging the enable change does not
deploy anything: the rebuild in step 2 is mandatory.

Facts you gave: 27 GiB RAM (17 GiB available), swap 14 GiB; `/` is 931 GB
with 112 GB free (88 % used). The root disk is nearly full, so the store is
**4 GiB** (module `storeSize = "4G"`), not 8 GiB.

1. **MANUAL:** check that `demo.shutterlink.micheljung.ch` resolves:
   `dig +short demo.shutterlink.micheljung.ch` shows `s1.micheljung.ch`
   and its address.
2. **MANUAL:** merge the one-line enable change
   (`mj.shutterlinkDemo.enable = true`) as a merge request on GitLab
   (`gitlab.com/michel.jung89/mj-server`, private repo), then on mj-server:
   `sudo nixos-rebuild switch --refresh --flake git+ssh://git@gitlab.com/michel.jung89/mj-server.git#mj-server`.
3. **MANUAL:** the demo has its own podman networks. Check that
   `sl-demo-int` and `sl-demo-edge` exist (`sudo podman network ls`) and
   run the acceptance test AC7 from [`demo-server.md`](demo-server.md).
4. **MANUAL:** `curl -s -o /dev/null -w '%{http_code}\n' https://demo.shutterlink.micheljung.ch/healthz`
   returns `204`. Uptime Kuma is configured by AutoKuma from Nix.
5. **AUTO:** the agent runs the full test suite (source IP A) in
   L-14 to L-10. **MANUAL:** you run the source-IP-B check from your phone
   on mobile data (first upload and first gallery request succeed).
6. Kill switch: on mj-server stop the units
   (`sudo systemctl stop shutterlink-demo-disk-guard.timer podman-shutterlink-demo-proxy podman-shutterlink-demo shutterlink-demo-store`),
   then merge `mj.shutterlinkDemo.enable = false;` on GitLab and rebuild as
   in step 2. Until then a reboot or any rebuild from the old `main`
   restarts the demo.

All of this must be green before any post (L).

### D5 F-Droid recipe bump (AUTO, L-14 to L-10)

After the `v1.5.0` tag exists, the agent bumps
`docs/fdroid/ch.micheljung.shutterlink.yml` to 1.5.0: `versionName`, the tag
`commit`, versionCodes 1006/2006/4006 (pubspec code 6 plus 1000/2000/4000,
see [`../../RELEASING.md`](../../RELEASING.md)) and
`CurrentVersion`/`CurrentVersionCode`. Submission is a follow-up, see
[`fdroid-followup.md`](fdroid-followup.md).

### M11 Posting (MANUAL, L to L+7)

Use [`announcements.md`](announcements.md). From your own accounts, say you
are the developer, answer for 2-3 hours, no same-day cross-posts, log URLs
at the bottom of that file. Before posting, re-read each community's rules
(the Reddit ones are unverified in the draft).

## Rollback and recovery

| Problem | Action |
|---|---|
| Bad internal or production Play release | Production: **Test and release** -> **Production** -> **Halt rollout** (staged rollouts only). Internal: create a replacement release. Version codes cannot be reused: bump `+1`, fix, agent re-tags. GitHub: edit the release to pre-release or remove the asset, ship the next patch. |
| Upload key leak (`shutterlink-release.jks`) | Play Console -> **App integrity** -> **Request upload key reset**; rotate the `SHUTTERLINK_*` secrets and `SHUTTERLINK_CERT_SHA256`. Sideload stream: rotate with an APK Signature Scheme v3 key rotation lineage (`apksigner rotate`) and announce it. |
| Service-account JSON leak | Cloud Console -> **IAM & Admin** -> **Service Accounts** -> `play-publisher` -> **Keys** -> delete the key, create a new one, update `PLAY_SERVICE_ACCOUNT_JSON`, review the Play Console activity log. |
| Demo server abuse | Kill switch in M10; abuse mail arrives at `shutterlink@micheljung.ch`. |
| Play review rejects FGS or listing | Fix the declaration or screenshots; the posts do not depend on Play. |
| Pages certificate late | Use the GitHub `PRIVACY.md` URL as the privacy policy until HTTPS works. |
