# PlanFlow Android Signing

PlanFlow must use the same release/upload keystore on every PC. If a build is signed with a different key, Android treats it as a different app update and login, permissions, and local Naver sync state can appear to reset after reinstall attempts.

## Local Files

- `android/app/planflow-release.jks`: PlanFlow release/upload keystore.
- `android/key.properties`: Gradle signing properties that point to the keystore.
- `android/signing/PlanFlow-signing-keys.zip.aes`: encrypted backup for moving the same key to another PC.
- `android/signing/PlanFlow-signing-archive-password.txt`: local password note for the encrypted backup.

All files above are intentionally ignored by Git. Never commit them or paste their contents into chat, tickets, logs, or screenshots.

## New PC Bootstrap

The easiest one-command flow is:

```powershell
.\scripts\planflow-release-bootstrap.ps1
```

That script does the whole repeatable setup in one run:

1. Restores signing files if they are missing locally, using the encrypted archive from OneDrive first and then the repo-local fallback path.
2. Builds the debug APK and release appbundle with `scripts/flutter-local.ps1`.
3. Verifies the APK signer fingerprint is the PlanFlow release certificate:
   `b3f2289851b78881263ca939fc09181efc310152828dd700fab7c552bef9a231`
4. Updates the connected device with `scripts/adb-install-update.ps1`.
5. Launches the app and prints the PID unless `-SkipLaunch` is used.

If the archive lives somewhere else, pass it explicitly:

```powershell
.\scripts\planflow-release-bootstrap.ps1 -ArchivePath "D:\custom\PlanFlow-signing-keys.zip.aes"
```

If you want the password to come from a file instead of an interactive prompt:

```powershell
.\scripts\planflow-release-bootstrap.ps1 -PasswordFile "C:\secure\planflow-signing-pass.txt"
```

If the connected device still has the old Android Debug-signed PlanFlow installed and you want a one-time transition, use:

```powershell
.\scripts\planflow-release-bootstrap.ps1 -AllowOneTimeTransition
```

Do not use `adb uninstall com.planflow.app`, `pm clear`, or any broad cleanup script as a normal update check. If Android reports `INSTALL_FAILED_UPDATE_INCOMPATIBLE`, compare the installed app signature and the APK/AAB signature, then decide manually how to migrate the device.

## One-Time Debug To Release Transition

If a development device already has `com.planflow.app` installed with the Android Debug certificate, Android cannot update it to the PlanFlow release certificate. This is expected Android signature protection, not a build bug.

Use this one time only, and only for `com.planflow.app`:

```powershell
adb uninstall com.planflow.app
.\scripts\adb-install-update.ps1
```

After this transition, repeat `.\scripts\adb-install-update.ps1` for normal update checks. It should succeed without clearing app data as long as every PC restores the same `planflow-release.jks`.
