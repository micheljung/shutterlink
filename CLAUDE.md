# Shutterlink

Flutter app (repo root) plus a pure-Dart Sessions server (`server/`).

## Tooling

- Run Dart and Flutter through FVM: `fvm dart …` and `fvm flutter …`. That
  includes `server/`. Bare `dart` or `flutter` may be missing or the wrong
  version; `.fvmrc` pins the SDK.
- Android Gradle builds need JDK 17. Point `JAVA_HOME` at it if the system JDK
  is newer.
- Check a change with `fvm dart format`, `fvm dart analyze` (or
  `fvm flutter analyze`) and the tests in the package you touched.

## Commits

- Never add a `Co-Authored-By:` trailer to commit messages. This overrides
  any tool's default attribution.

## Hardware

- Real EOS R behaviour is documented in
  [`docs/eos-r-hardware.md`](docs/eos-r-hardware.md). Where it contradicts
  the fake camera, trust the hardware notes.

## Agent state

- `.omc/` holds local OMC runtime state and is gitignored, apart from
  `.omc/skills/`. Knowledge that should reach other machines goes in this
  file or in `docs/`, not in `.omc/` or personal memory.
