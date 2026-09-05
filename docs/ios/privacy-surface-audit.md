# PlanFlow iOS privacy-surface audit

기준: Build 13/14에서 Apple BuildUpload가 `90683 Missing purpose string`
(affected bundle `Runner.app`)으로 실패했다. 따라서 패키지 이름만으로 권한을
추가하지 않고, 실제 Runner에 링크·사용되는 API와 최종 산출물의 plist를 함께
검사한다.

## Evidence matrix

| dependency/API | production evidence | sensitive surface | Runner key | current status | PlanFlow use |
| --- | --- | --- | --- | --- | --- |
| `speech_to_text` 7.4.0 / AVFoundation + Speech | `lib/services/stt_service.dart`, generated registrant, plugin README | microphone, speech recognition | `NSMicrophoneUsageDescription`, `NSSpeechRecognitionUsageDescription` | present | 음성 일정 입력 |
| `flutter_naver_map` 1.4.4 / CoreLocation | `LocationPickerScreen`, location picker flow, plugin iOS source | location while in use | `NSLocationWhenInUseUsageDescription` | present | 장소 선택·지도 위치 확인 |
| `google_maps_flutter_ios` 2.18.1 | registered plugin; map fallback; privacy manifest | CoreLocation-linked SDK surface | `NSLocationWhenInUseUsageDescription` | present | 지도 fallback |
| `google_mobile_ads` 5.3.1 | registered plugin and ad service; Google-Mobile-Ads-SDK pod | AdSupport/AppTrackingTransparency (IDFA/ATT) | `NSUserTrackingUsageDescription` | present | 관련 광고·측정 동의 |
| `file_picker` 11.0.2 | `NaverIcsImportScreen` calls `FileType.custom` for `.ics` | no media picker evidence | Photos key not added | no key required | ICS import |
| `webview_flutter_wkwebview` | no production camera/media capture call found | camera candidate only | camera key not added | no evidence | no direct production use |
| `AVCaptureDevice` / camera APIs | no PlanFlow camera call or linked-framework proof found | camera | `NSCameraUsageDescription` | not added; no evidence | not used; dependency-only candidate |
| `PHPhotoLibrary` / photo APIs | no photo picker, asset library, or linked-framework proof found | photo read | `NSPhotoLibraryUsageDescription` | not added; no evidence | not used |
| photo write APIs | no photo export/save feature or linked-framework proof found | photo write | `NSPhotoLibraryAddUsageDescription` | not added; no evidence | not used |
| `CNContactStore` / Contacts | no contacts API call or linked-framework proof found | contacts | `NSContactsUsageDescription` | not added; no evidence | not used |
| `EKEventStore` / EventKit calendars | no EventKit call; app calendar is Supabase/local data | calendars | `NSCalendarsUsageDescription` | not added; no evidence | not used |
| `EKEventStore` reminders | no reminders API call or linked-framework proof found | reminders | `NSRemindersUsageDescription` | not added; no evidence | not used |
| CoreLocation always authorization | plugin evidence is when-in-use only; no always authorization call found | location always | `NSLocationAlwaysAndWhenInUseUsageDescription` | not added; no evidence | not used |
| `CBCentralManager` / Bluetooth | no Bluetooth API call or linked-framework proof found | Bluetooth | `NSBluetoothAlwaysUsageDescription` | not added; no evidence | not used |
| `NWPathMonitor` / local network | no local-network browsing/listener or linked-framework proof found | local network | `NSLocalNetworkUsageDescription` | not added; no evidence | not used |
| `CMMotionManager` / motion | no motion API call or linked-framework proof found | motion | `NSMotionUsageDescription` | not added; no evidence | not used |
| `LAContext` / LocalAuthentication | no Face ID/biometric API call or linked-framework proof found | Face ID | `NSFaceIDUsageDescription` | not added; no evidence | not used |
| `MPMediaLibrary` / Apple Music | no media-library API call or linked-framework proof found | media library | `NSAppleMusicUsageDescription` | not added; no evidence | not used |

The location key is Runner-only. The Widget has an App Group entitlement but no
location, microphone, speech, tracking, camera, photos, contacts, calendar, or
other Runner usage descriptions.

## Fail-closed gates

`scripts/verify-ios-privacy-surface.py` validates source/archive/exported Runner
and Widget plists. The archive/export release gates require a macOS scan of the
built Runner bundle and embedded binaries with `otool -L`, `nm`, and `strings`,
and report mapped sensitive frameworks. Unknown symbols are not treated as
proof of a missing key. The optional JSON report records each Runner,
embedded-framework, appex, and dylib binary, each `otool`/`nm`/`strings`
return code, and only filtered framework/candidate-symbol evidence; it never
stores full binary output. A missing required key, failed binary scan, or a
Runner key copied into Widget fails the build.

Windows에서는 실제 macOS binary를 만들 수 없고 Xcode, `otool`, authoritative signed IPA를
실행할 수 없다;
the archive/export and binary gates must therefore run on the macOS GitHub
runner. The Build 15 upload remains blocked until those gates and Apple’s
authoritative BuildUpload state pass.

## Audit-only macOS workflow (no upload, no Build 16)

`.github/workflows/ios-privacy-audit.yml` audits the exact preserved Build 15
IPA on the macOS runner, captures the binary/plist privacy evidence Apple
error 90683 needs, and stops there. It never rebuilds the current checkout.
The manual dispatch requires the artifact run/name, the IPA SHA-256, and the
full source commit recorded in `provenance.json`. The job downloads exactly one
IPA and one provenance manifest, verifies the IPA hash, build number, bundle
ID, source commit, embedded `CFBundleVersion`, and the checked-out source
commit, then scans that preserved IPA. Missing or mismatched provenance fails
closed before the audit.

`audit_build_number` defaults to `15` and fails closed when empty, zero,
non-numeric, zero-padded, or `16` or higher. Zero is explicitly rejected, and
the comparison is forced to base 10 (`10#`). A contract test extracts this
gate from the workflow and executes it with real inputs, including `0`.
The job contains no `altool` transport, no `verify-app-store-build.py`
ingestion query, and no signing or App Store Connect credentials; it prints
`AUDIT_ONLY_NO_UPLOAD: PASS`, `REBUILD_PERFORMED: NO`,
`BUILD_16_DISPATCHED: NO`, and `APP_STORE_UPLOAD_PERFORMED: NO`.

The preserved exported IPA is scanned with
`--require-binary-scan --audit-report`, and the JSON report is uploaded as the
`planflow-ios-90683-audit-<run>` artifact for 14 days even when a step fails.
`--audit-report` adds an `audit` block that lists the Runner and Widget
usage-description keys actually present, the sensitive symbols observed in the
binaries, and the purpose-string gaps: `frameworkKeyGaps` (a linked mapped
framework whose key is absent) and `symbolKeyGaps` (a sensitive symbol whose
key is absent). Gaps are diagnostic evidence for review, not an instruction to
add a key, so they do not change the pass/fail result of the existing
fail-closed gates.

An authorized release process must first preserve an IPA plus `provenance.json`
in a readable Actions artifact. Until that exact Build 15 evidence exists, the
audit remains intentionally blocked; Build 16 stays undispatched and no App
Store Connect upload is performed.
