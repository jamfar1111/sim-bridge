# sim-bridge

Android + iOS app that bridges a registered Android phone's SIM calls
and SMS to an unregistered iPhone.

## Layout

- `flutter/` — the Flutter project (Dart UI + shared logic, Kotlin
  Android bridges, Swift iOS bridges).
- `.github/workflows/` — CI. `ios-build.yml` builds an unsigned iOS
  IPA artifact (install with AltStore, free Apple ID). `android-apk.yml`
  builds a debug APK.

The Android release APK is built locally with the manual no-Gradle
pipeline in the maintainer's workspace, not in CI.

## Pushing

The local checkout keeps the workflows under `flutter/.github/`; the
push remaps them to the repo root because GitHub Actions only reads
workflows from there. Use `bin/push_tree.py` in the maintainer's
connector helpers to push.
