# Releasing

Shutterlink is distributed as a signed APK on
[GitHub Releases](https://github.com/micheljung/shutterlink/releases) and,
once enabled, as an app bundle on Google Play. An
[F-Droid](https://f-droid.org) build recipe is kept ready for a submission,
which is deferred until 2027-02-11 or later.

## How F-Droid works

- F-Droid never takes an APK from us. Its build server checks out a tagged commit of
  this repository and builds the app itself, following a build recipe.
- The recipe lives in F-Droid's own repository,
  [fdroiddata](https://gitlab.com/fdroid/fdroiddata), as
  `metadata/ch.micheljung.shutterlink.yml`.
  [`docs/fdroid/ch.micheljung.shutterlink.yml`](docs/fdroid/ch.micheljung.shutterlink.yml)
  is a copy of the submitted version.
- It builds one APK per CPU architecture. Their version codes are the
  `pubspec.yaml` version code plus 1000 (armeabi-v7a), 2000 (arm64-v8a) and
  4000 (x86_64), as Flutter assigns them.
- F-Droid signs the APK with its own key. We hold no signing secrets.
- The store listing (title, descriptions, changelogs, screenshots) is read
  from [`fastlane/metadata/android/en-US/`](fastlane/metadata/android/en-US).

## Release APKs on GitHub and Nexus

Pushing a `v*` tag runs [`.github/workflows/release.yml`](.github/workflows/release.yml).
To build an existing tag, run the workflow manually ("Run workflow") with the
tag, for example `v1.1.0`. A manual run is a dry run by default (`dry_run`
is on): it builds and signs but skips Nexus, the GitHub release and the
Google Play upload, which is only validated. Untick `dry_run` to publish.

It checks that the tag matches the `pubspec.yaml` version, builds the APK,
signs it with the release key and uploads it to
`https://repo.micheljung.ch/repository/shutterlink-release/shutterlink-<version>.apk`,
for example `shutterlink-1.1.0+2.apk`. It then creates the GitHub release
for the tag, titled `Shutterlink <version name>`, with the APK attached and
`fastlane/metadata/android/en-US/changelogs/<version code>.txt` as its notes
(generated notes if that file is missing). If the release already exists,
the APK on it is replaced.

Pushing to any branch builds and signs a preview APK the same way and uploads
it to
`https://repo.micheljung.ch/repository/shutterlink-preview/shutterlink-<version>-<branch>-<commit>.apk`,
for example `shutterlink-1.1.0+2-main-7a2a7b2.apk`. Slashes and other
special characters in the branch name become `-`.

It needs these GitHub Actions settings:

| Name | Kind |
|---|---|
| `NEXUS_USERNAME` | variable |
| `NEXUS_PASSWORD` | secret |
| `SHUTTERLINK_CERT_SHA256` | variable: the release certificate's SHA-256, checked after signing |
| `SHUTTERLINK_KEYSTORE_BASE64`, `SHUTTERLINK_KEYSTORE_PASSWORD`, `SHUTTERLINK_KEY_ALIAS`, `SHUTTERLINK_KEY_PASSWORD` | secrets |

Keep a backup of the release keystore. Android only installs updates signed
with the same key, so losing it means every user has to uninstall first.

The signing secrets are scoped to the single "Sign" step. The build runs
before it with Gradle's daemon disabled, daemons are stopped before signing,
and the checkout does not persist the job token. This narrows the exposure
but does not isolate the key from build code: every step runs on the same
runner as the same user. Full isolation needs separate build, sign and
publish jobs (unsigned artifact in between); this is a follow-up. The
keystore is decoded into the runner's temp directory and deleted when the
Sign step exits. Manual runs only accept tags: the checkout uses
`refs/tags/<tag>`, so a branch or SHA cannot be released.

Recommended hardening: move the signing secrets, `NEXUS_PASSWORD` and
`SHUTTERLINK_CERT_SHA256` into a GitHub Environment named `release` with a
deployment rule limited to `v*` tags, and set `environment: release` on the
`apk` job. Branch pushes would then no longer see the secrets; this
conflicts with the preview builds below until the known risk is resolved.

Known risk: every branch push signs a preview APK with the release key and
uploads it to Nexus `shutterlink-preview`. Preview APKs therefore share the
release signing key, and anyone who can push a branch can get code signed
with it, and can read the signing key, because a branch push runs that
branch's own copy of this workflow with the secrets. Recommended: a separate preview key, or signing only on tags. This
is undecided and the behaviour is unchanged.

## Google Play

Play automation is optional and not launch-critical. If it misbehaves,
upload the AAB in the Play Console by hand.

The app bundle is built and signed with the same key as the APK in the
release workflow, and checked against `SHUTTERLINK_CERT_SHA256`. It is saved
as the workflow artifact `aab` (30 days) and is never attached to the GitHub
release, so Obtainium keeps picking up the APK. The `play` job then uploads
it with `fastlane supply`. It needs these settings, and only runs when
`PLAY_ENABLED` is `true`:

| Name | Kind |
|---|---|
| `PLAY_SERVICE_ACCOUNT_JSON` | secret: the Play API service account key |
| `PLAY_ENABLED` | variable: `true` once the app, the service account and its permissions exist in the Play Console |
| `PLAY_RELEASE_STATUS` | variable, optional: `draft` (default) or `completed`; only tag pushes read it |

Behaviour:

- A `v*` tag push uploads the AAB to the `internal` track as a `draft`,
  with the changelog but without touching the store listing, images or
  screenshots. It then waits in the Play Console until you roll it out.
- Manual runs take `track` (internal, alpha, beta, production),
  `release_status` (draft, completed; on a manual run it always beats
  `PLAY_RELEASE_STATUS`), `dry_run` (default on) and `mode`.
- `mode=metadata` does not build anything: job `apk` is skipped, so Nexus and
  the GitHub release stay untouched. It only uploads the store listing (text,
  images, screenshots) with `dry_run` off, or validates it with `dry_run` on.
- `mode=aab` with `dry_run` on builds and signs only. There is no AAB
  validation against Play: Play rejects a version code that was already
  used, so `validate_only` cannot pass for an existing tag.
- Re-dispatching `mode=aab` with `dry_run` off for an existing tag is not
  supported: Play rejects reused version codes and Nexus may reject a
  redeploy.
- Do not push a new tag while the production review of the previous
  version code is still pending. Committing another Play edit then can add
  to that review or fail with "changes cannot be sent for review".

The first release of the app is uploaded manually in the Play Console. After
that, a draft stays invisible to users until you publish or roll it out
there. Promote a tested release from internal to a higher track in the
Console.

An optional GitHub Environment named `play` can hold
`PLAY_SERVICE_ACCOUNT_JSON` with a deployment rule for tags `v*`. Manual
runs must then be started with "Use workflow from: Tags".

Google has announced developer verification for sideloaded Android apps.
The details and dates are unverified here: check the current rules
before each release.

### Rollback and recovery

- **Bad Play release.** Production: Play Console, Release, Production,
  "Halt rollout" (for a staged rollout). Internal and other tracks: create a
  replacement release. Version codes cannot be reused: bump the version
  code by one, fix, and tag again. GitHub and Nexus: mark the release as
  a pre-release or delete its APK asset in the GitHub release, then ship the
  next patch release.
- **Upload or signing key leaked** (`SHUTTERLINK_KEYSTORE_BASE64` and the
  keystore backup). Play: Play Console, App integrity, "Request upload key
  reset" and register a new upload key; the Play app signing key is not
  affected. Replace the four `SHUTTERLINK_KEY*` secrets and
  `SHUTTERLINK_CERT_SHA256`. For the sideloaded APK stream, rotate to a new key
  with an APK Signature Scheme v3 lineage (`apksigner rotate`), and announce
  it in the README and the release notes.
- **Service account key leaked.** Google Cloud Console, IAM, Service
  accounts, the account's Keys: delete the leaked key, create a new one, update
  `PLAY_SERVICE_ACCOUNT_JSON`, and review the Play Console activity log.
- **Lost signing key.** Restore it from the offline backup. If it is gone,
  Play can reset the upload key; sideloaded installs have to uninstall and
  reinstall.
- **Sessions server abuse.** Stop the optional community Sessions server as
  described in `docs/launch/demo-server.md`, which also lists the limits and
  recovery steps.

## Server image on GHCR

[`.github/workflows/docker.yml`](.github/workflows/docker.yml) builds the
Sessions server image from [`server/Dockerfile`](server/Dockerfile) for
`linux/amd64` and `linux/arm64`, runs
[`server/docker/smoke.sh`](server/docker/smoke.sh) on both, and pushes to
`ghcr.io/micheljung/shutterlink-server`:

| Event | Tags pushed |
|---|---|
| `v*` tag, e.g. `v1.2.0` | `1.2.0`, `1.2`, `latest` |
| Push to `main` | `main`, `sha-<commit>` |
| Pull request | none, build and smoke test only |

The server has no version of its own: the image is versioned by the tag,
which must match the version name in `pubspec.yaml`, or the workflow fails
before pushing. It logs in with
the built-in `GITHUB_TOKEN`; no secrets to set up.

The first push creates the package as **private**. Make it public once, or
nobody can pull it: GitHub → the repository's Packages →
`shutterlink-server` → Package settings → Change visibility → Public.

## Submission

The F-Droid submission is deferred until 2027-02-11 or later. The 1.1.0
submission,
[fdroiddata!57043](https://gitlab.com/fdroid/fdroiddata/-/merge_requests/57043),
was closed without being merged, so the app is not on F-Droid. A new
submission opens a merge request in fdroiddata with the recipe. After the
merge, the app usually shows up in F-Droid within a few days.

## Every later release

1. Bump `version:` in `pubspec.yaml`, for example `1.1.0+2` → `1.2.0+3`. The
   part before `+` is the version name. The number after `+` is the version
   code and must always increase.
2. Add `fastlane/metadata/android/en-US/changelogs/<versionCode>.txt`
   (at most 500 characters).
3. Merge to `main`.
4. Tag the merge commit `v<versionName>` and push the tag:

   ```bash
   git tag v1.2.0
   git push origin v1.2.0
   ```

The tag runs the release workflow, which publishes the signed APK on GitHub
Releases and Nexus and, with `PLAY_ENABLED`, an internal draft on Google Play. Once the app is on F-Droid, F-Droid's update bot also
finds the new tag, reads the version from `pubspec.yaml` and adds a build to
the recipe.

## Signing

GitHub and Nexus APKs are signed with our release key, F-Droid builds with
F-Droid's own key, and Google Play re-signs with its own app signing key
(our release key is only the upload key). Android refuses to update one
with the other, so moving between streams means uninstalling and
reinstalling the app once.

## Troubleshooting

- **Flutter version not found:** the recipe pins `flutter@3.47.5`, which must
  be a tag in fdroiddata's `srclibs/flutter.yml` repository. Keep it in sync
  with `.fvmrc` and CI.
- **Build fails because of the JDK:** add to the build entry:

  ```yaml
  sudo:
    - apt-get install -y openjdk-17-jdk-headless
  ```

- **F-Droid rejects a signed APK:** the recipe removes local debug signing
  with `sed -i -e '/signingConfig = /d'`. Keep the line in
  `android/app/build.gradle.kts` on one line, starting with
  `signingConfig = `.
