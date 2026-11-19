# F-Droid follow-up

F-Droid wants an app to be at least three months old. Submit **on or after
2027-02-11**, not before.

The earlier submission,
[fdroiddata!57043](https://gitlab.com/fdroid/fdroiddata/-/merge_requests/57043)
(version 1.1.0), was closed without being merged; see the note in
[`../../RELEASING.md`](../../RELEASING.md). Treat the new one as a fresh
submission.

## Checklist

- [ ] 2027-02-11 or later: check the app's age against F-Droid's current
      inclusion rules (<https://f-droid.org/docs/Inclusion_Policy/>) and that
      the latest tag is still the one you want to ship.
- [ ] Bump `docs/fdroid/ch.micheljung.shutterlink.yml` to the newest tag:
      `versionName`, `versionCode` (pubspec code + 1000/2000/4000 per
      architecture), `commit` of the tag, and `CurrentVersion` /
      `CurrentVersionCode`. The 1.5.0 bump is done right after that tag;
      later releases need it again.
- [ ] Keep `flutter@<version>` in `srclibs` equal to `.fvmrc` and make sure
      that tag exists in fdroiddata's `srclibs/flutter.yml` repository.
- [ ] Fork <https://gitlab.com/fdroid/fdroiddata>, create a branch, copy the
      recipe to `metadata/ch.micheljung.shutterlink.yml`.
- [ ] In the fdroiddata checkout run `fdroid lint ch.micheljung.shutterlink`
      and `fdroid build -l ch.micheljung.shutterlink` (or the `fdroid build`
      CI job on the MR); fix what they report.
- [ ] Check the listing under `fastlane/metadata/android/en-US/` (title,
      descriptions, `changelogs/<code>.txt`, screenshots) and that it still
      uses "Live Share".
- [ ] Open the merge request against fdroid/fdroiddata with the project's MR
      template; wait for the pipeline and for reviewer questions.
- [ ] After the merge, the app usually appears in F-Droid within a few days;
      update `RELEASING.md` (replace the closed-MR note), the README badge
      and the landing page ("Google Play and F-Droid: planned").
- [ ] Remember the signing split: F-Droid builds are signed with F-Droid's
      key, so people switching from GitHub or Play builds must uninstall once.
