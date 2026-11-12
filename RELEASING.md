# Releasing

Shutterlink is distributed through [F-Droid](https://f-droid.org), a store
for free and open-source Android apps.

## How F-Droid works

- F-Droid never takes an APK from us. Its build server checks out a git tag of
  this repository and builds the app itself, following a build recipe.
- The recipe lives in F-Droid's own repository,
  [fdroiddata](https://gitlab.com/fdroid/fdroiddata), as
  `metadata/ch.micheljung.shutterlink.yml`. Our draft is
  [`docs/fdroid/ch.micheljung.shutterlink.yml`](docs/fdroid/ch.micheljung.shutterlink.yml).
- F-Droid signs the APK with its own key. We hold no signing secrets.
- The store listing (title, descriptions, changelogs, screenshots) is read
  from [`fastlane/metadata/android/en-US/`](fastlane/metadata/android/en-US).

## First submission (once)

1. Merge the pull request that adds the recipe.
2. Tag the merged commit and push the tag **before** opening the F-Droid
   merge request, because the recipe builds `commit: v1.1.0`:

   ```bash
   git tag v1.1.0
   git push origin v1.1.0
   ```

3. Fork [fdroiddata](https://gitlab.com/fdroid/fdroiddata) on GitLab.
4. Copy `docs/fdroid/ch.micheljung.shutterlink.yml` to
   `metadata/ch.micheljung.shutterlink.yml` in the fork, commit and push.
5. Open a merge request against fdroiddata. Its pipeline runs `fdroid lint`,
   `fdroid build` and `fdroid checkupdates`. Check in the `checkupdates`
   output that `UpdateCheckData` finds version `1.1.0` and code `2`.
6. Answer the reviewers' questions. After the merge, the app usually shows up
   in F-Droid within a few days.

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

F-Droid's update bot finds the new tag, reads the version from
`pubspec.yaml` and adds a build to the recipe. Building, signing and
publishing take a few days. Nothing else to do.

## Signing

F-Droid signs with its own key. Switching to our own key later is possible,
but every existing F-Droid user has to uninstall and reinstall the app once.

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
