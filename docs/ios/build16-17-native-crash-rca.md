# Build 16–17 native crash RCA inventory

This document records the bounded, non-PII facts extracted locally from the
historical `.ips` files. The raw reports remain outside the repository and
are not uploaded by the historical symbol reconstruction workflow.

## Historical facts

| Build | Incident inventory | Runner UUID | Frame offsets |
| --- | --- | --- | --- |
| 16 | Two unique incidents plus one duplicate | `96EB03A3-C4E7-3C3E-9C58-9E3F6DE896BC` | `7717012`, `7717392` |
| 17 | One incident | `D9B552C8-3F13-3217-B8B9-6886EE0926D0` | `7717068`, `7717448` |

The incidents were on the same `iPhone14,4` running `iOS 26.6.1`. Each was an
`EXC_CRASH` / `SIGABRT` with signal code `6`; the fault thread was
`default-qos`. Observed process lifetime was between `79 ms` and `506 ms`.
The second frame pair has a `+56` offset shift between the corresponding
historical observations. There is no explicit reason beyond `abort() called`.

These facts are inventory only. A UUID mismatch, build drift, failed
reconstruction, or unresolved `atos` frame is `NO_RESULT`, not root-cause
evidence. A successful workflow result means only
`RUNNER_FRAMES_SYMBOLICATED_FROM_UUID_MATCHED_RECONSTRUCTION`; it does not
mean `ROOT_CAUSE_CONFIRMED`.

## Reconstruction boundary

The audit-only workflow accepts only a dispatch from `main`, checks out the
exact dispatched `github.sha` as trusted tooling, checks out each fixed
historical source SHA, and reproduces a
no-code-sign release build with the canonical protected Firebase plist. The
secret is decoded only in a dedicated preparation step; build tooling receives
an owner-only temporary file path rather than the base64 secret environment,
and an `always()` cleanup step deletes that file. It
then repeats the production workflow's Xcode `archive` action in an ephemeral
directory with both `CODE_SIGNING_ALLOWED=NO` and
`CODE_SIGNING_REQUIRED=NO`. The reconstruction supplies no certificate, team,
identity, provisioning profile, or App Store Connect input. It
records the Flutter preparation build and unsigned archive as separate
variants, with explicit Runner/dSYM paths for each. The unsigned archive is
preferred because it mirrors the final release action; the preparation build
is eligible only as a fallback when its executable and its own dSYM both match
the historical crash UUID. If both variants match, their two sanitized frame
results must also be identical or the run fails as ambiguous. For the selected
variant, the workflow requires exactly one arm64 Runner executable UUID and
one arm64 Runner dSYM UUID, requires both to equal the expected crash UUID,
verifies the dSYM, derives
the actual `__TEXT` load address and size, range-checks both offsets, and only
then calls `atos` against the UUID-matched dSYM DWARF file. It emits only a
bounded sanitized JSON report and one bounded annotation per matrix result.

The original release workflow used the `macos-latest` runner label. The
reconstruction deliberately reuses that label, but the label is not an
immutable runner image: Xcode, Swift, CocoaPods, SDK, and dependency resolution
can still drift. Therefore only a three-way UUID match (historical crash,
reconstructed executable, reconstructed dSYM) authorizes symbolication.

The historical sources have no committed `ios/Podfile.lock`; the selected Pod
lock state is recorded in the sanitized report after `pod install`. Toolchain
versions (Xcode, Swift, Flutter, and CocoaPods) are recorded there as
provenance. The ephemeral unsigned archive is deleted by the cleanup trap and
is never uploaded. No IPA, export, App Store Connect, TestFlight, signing, or
  team/profile operation is part of reconstruction.

## Authenticated macOS reconstruction result

Run `34129859121` executed from `258de3348d0004af0bdd86d0a599454872ef24cd`.
Both matrix jobs completed their reconstruction step and produced sanitized
reports, then failed closed at the no-result gate:

| Build | Flutter preparation variant | Unsigned archive variant | Result |
| --- | --- | --- | --- |
| 16 | `MISSING_OUTPUT` | `EXECUTABLE_UUID_MISMATCH`; executable and dSYM UUID `9F77993B-BEEA-340B-8C44-C2728F6243F6` | `RECONSTRUCTION_OR_VERIFICATION_FAILED_NO_SYMBOLICATION` |
| 17 | `MISSING_OUTPUT` | `EXECUTABLE_UUID_MISMATCH`; executable and dSYM UUID `3889A669-E6BD-3660-ADEF-50BDBA232E5C` | `RECONSTRUCTION_OR_VERIFICATION_FAILED_NO_SYMBOLICATION` |

The sanitized reports were created as artifacts `10022039962` and
`10022135827`. Neither reconstructed UUID equals its historical crash UUID,
so no `atos` function/file/line result is authoritative. The run therefore
confirms environment/build drift or missing historical outputs, not a product
root cause. Build 18 remains blocked until an exact historical Runner/dSYM
pair is available.

## Android parity baseline and current iOS source state

This is a source/configuration inventory, not real-device proof. `IOS_ENABLED`
means the production source path is present and not deliberately gated off; it
does not claim that Build 16 or 17 reached that path before crashing.

| Feature | Android canonical behavior | Current iOS source state | Evidence | Release implication |
| --- | --- | --- | --- | --- |
| Firebase Core | Initialized at startup | `IOS_ENABLED` | `lib/main.dart`, `lib/firebase_options.dart` | Retain; verify on the fixed device build |
| Supabase/auth | Shared account/session flow | `IOS_ENABLED` | `lib/main.dart`, `lib/services/auth_service.dart` | Source parity present; OAuth/device QA remains |
| Google/Naver Maps | Configured map and routing surfaces | `IOS_ENABLED` | `lib/main.dart`, `google_maps_flutter`, `flutter_naver_map` registrants | Keep canonical iOS keys; device QA remains |
| Notifications | Android alarms/channels and scheduled notifications | `IOS_PLATFORM_DIFFERENT` | `lib/services/notification_service.dart`, `flutter_local_notifications` | Use iOS notification APIs; do not copy Android alarm behavior |
| Microphone | Voice input permission and capture | `IOS_ENABLED` | `speech_to_text`, `NSMicrophoneUsageDescription` | Physical permission/capture QA required |
| Speech recognition | Speech-to-text input | `IOS_ENABLED` | `lib/services/stt_service.dart`, `NSSpeechRecognitionUsageDescription` | Physical recognition QA required |
| Photo/file access | File/ICS import and audited photo surface | `IOS_ENABLED` | `file_picker`, Runner photo usage keys, privacy audit | Keep only evidenced privacy keys; device picker QA remains |
| Widget/App Group | Android home widgets | `IOS_PLATFORM_DIFFERENT` | `ios/PlanFlowWidget`, `home_widget`, `group.com.fluxstudio.planflow` | WidgetKit/App Group is the iOS equivalent |
| Deep links | `planflow://` navigation | `IOS_ENABLED` | `ios/Runner/Info.plist`, `lib/app.dart`, `app_links` | Device cold/warm-link QA remains |
| Secure storage | Protected auth/session storage | `IOS_ENABLED` | `flutter_secure_storage`, `lib/core/supabase_auth_options.dart` | Preserve platform keystore/keychain implementation |
| Ads | Android rewarded-ad product path | `IOS_TEMP_DISABLED` | `lib/services/ad_runtime_policy.dart` | Restore only with a real iOS AdMob app/unit configuration |
| Consent | Android UMP flow | `IOS_TEMP_DISABLED` | `lib/services/ad_consent_service.dart` | Restore with Ads; retain ATT/Apple privacy differences |
| Rewarded ads | Schedule/voice reward paths | `IOS_TEMP_DISABLED` | `lib/services/ad_service.dart`, ad gate services | Restore all callers together after RCA and configuration |
| Product analytics | Intentionally no external analytics SDK in first release | `IOS_ENABLED` | `lib/core/analytics_service.dart` is a shared no-op | Parity is intentional; do not invent telemetry |
| Crashlytics | Firebase nonfatal/fatal reporting | `IOS_ENABLED` | `lib/main.dart`, `firebase_crashlytics` registrant | Retain unless symbolication directly proves involvement |
| Remote Config | Firebase runtime feature configuration | `IOS_ENABLED` | `lib/services/remote_config_service.dart` | Retain; validate fetched/default states on device |
| Offline behavior | Shared caches and fail-open network handling | `IOS_ENABLED` | startup services, repositories, `runtime_error_filter.dart` | Offline/reconnect device QA remains |
| Background/foreground | Android alarm/background components plus shared lifecycle | `IOS_PLATFORM_DIFFERENT` | `lib/app.dart`, Android-only guards in alarm/scheduler services | Validate iOS lifecycle/notifications, not Android receivers |
| Sharing | Incoming ICS/share handling | `IOS_ENABLED` | `lib/app.dart`, `receive_sharing_intent` | Cold/warm share QA remains |
| Review flow | Native store review request | `IOS_ENABLED` | `lib/services/review_service.dart`, `in_app_review` registrant | Validate App Store review behavior on device |

## Diagnostic-disable inventory

| Guard | Current effect | Disposition | Gate |
| --- | --- | --- | --- |
| `isAdsRuntimeSupported` | Allows Ads SDK runtime only on Android | `RESTORE_AFTER_FIX` | Root cause excludes Ads path and canonical iOS AdMob configuration exists |
| UMP entry points | Skip consent initialization/options on iOS | `RESTORE_AFTER_FIX` | Restore with Ads and keep iOS ATT/privacy policy |
| `MobileAds.instance.initialize` caller | Skipped on iOS before SDK initialization | `RESTORE_AFTER_FIX` | Same RCA/configuration gate |
| Ad preload/retry paths | Return without loading on iOS | `RESTORE_AFTER_FIX` | Migrate every caller when Ads is restored |
| Schedule/voice rewarded paths | Return disabled on iOS | `RESTORE_AFTER_FIX` | Restore reward semantics with valid iOS unit IDs |
| Integration-test fakes, `E2E_MODE`, simulator seams | Prevent production backend/plugin access in tests | `KEEP_TEST_ONLY` | Must remain unreachable from ordinary production launch |
| Android alarm, calendar-provider, and permission guards | Exclude Android-only platform APIs from iOS | `KEEP_PLATFORM_REQUIREMENT` | Preserve; implement iOS equivalents where product behavior requires them |

No separate `REMOVE_DIAGNOSTIC_ONLY` production bypass was identified in this
bounded inventory. Ads/UMP containment is not accepted as final parity and no
placeholder AdMob ID is introduced. Build 18 remains blocked until the
historical symbolication yields an evidence-backed function or another
decisive diagnostic is approved.
