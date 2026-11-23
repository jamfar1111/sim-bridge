# Permission-fix build failure — diagnosis (2026-11-23 ~10:50 UTC)

## What happened
Commit `1b03532` (10:46:58) added the first-launch setup flow with
`permission_handler: ^13.0.2`. The manual build started 10:46, passed
kotlinc (10:49, only a language-version warning) and **died in javac
(10:50, before D8)** — no new APK, `flutter/build/app/outputs/flutter-apk/app-release.apk`
still the 10:28 pre-fix build, `.build-success` not updated.

## Root cause (from `.downloads/manual-build/javac.log`)
`permission_handler_android-14.1.1` references Android 17 (API 37,
"Cinnamon Bun") symbols that the installed API-36 platform does not have:

- `Manifest.permission.ACCESS_LOCAL_NETWORK` (PermissionUtils.java:97, 616, 618)
- `Build.VERSION_CODES.CINNAMON_BUN` (PermissionUtils.java:612)

Verified with `javap` against
`.android-sdk/platforms/android-36/android.jar` (API 36, Android 16
Baklava, rev 2): neither symbol exists. The build script already uses
android-36, so there is no SDK level to raise to — API 37 is not installed
and is a preview.

## Fix (already applied in the working tree, uncommitted)
- `pubspec.yaml`: `permission_handler: ^13.0.2` → `^12.0.0`
- `pubspec.lock` re-resolved: `permission_handler 12.0.3`,
  `permission_handler_android 13.0.1` (both already in the pub cache)
- Verified: `permission_handler_android-13.0.1` has **zero** references to
  `ACCESS_LOCAL_NETWORK` / `CINNAMON_BUN`, and every permission the setup
  flow uses (`bluetoothAdvertise/Connect/Scan`, `sms`, `contacts`, `phone`,
  `notification`, `camera`, `ignoreBatteryOptimizations`) exists in
  `permission_handler_platform_interface 4.4.1` used by 12.0.3.

## Still pending (owned by the live chat)
`flutter analyze && flutter test` was running at 10:50; then the manual
build must be re-run (audit_dex should pass), the APK re-verified and
uploaded to Drive replacing the same file, and Farhad told the new APK
is ready. Do not install the 10:28 APK — it has no permission flow.
