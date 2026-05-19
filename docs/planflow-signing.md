# PlanFlow Android Signing

PlanFlow must use the same release/upload keystore on every PC. If a build is signed with a different key, Android treats it as a different app update and login, permissions, and local Naver sync state can appear to reset after reinstall attempts.

## Local Files

- `android/app/planflow-release.jks`: PlanFlow release/upload keystore.
- `android/key.properties`: Gradle signing properties that point to the keystore.
- `android/signing/PlanFlow-signing-keys.zip.aes`: encrypted backup for moving the same key to another PC.
- `android/signing/PlanFlow-signing-archive-password.txt`: local password note for the encrypted backup.

All files above are intentionally ignored by Git. Never commit them or paste their contents into chat, tickets, logs, or screenshots.

## New PC Restore

1. Copy `PlanFlow-signing-keys.zip.aes` to `android/signing/` through a private channel.
2. Get the archive password through a separate private channel.
3. Run:

```powershell
.\scripts\restore-planflow-signing.ps1
```

4. Build with the repo wrapper:

```powershell
.\scripts\flutter-local.ps1 build appbundle --release --no-pub
```

5. For device verification, update-install only:

```powershell
.\scripts\adb-install-update.ps1
```

Do not use `adb uninstall com.planflow.app`, `pm clear`, or any broad cleanup script as a normal update check. If Android reports `INSTALL_FAILED_UPDATE_INCOMPATIBLE`, compare the installed app signature and the APK/AAB signature, then decide manually how to migrate the device.
