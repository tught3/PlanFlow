# PlanFlow iOS privacy-surface audit

기준: Build 13/14에서 Apple BuildUpload가 `90683 Missing purpose string`
(affected bundle `Runner.app`)으로 실패했다. 따라서 패키지 이름만으로 권한을
추가하지 않고, 실제 Runner에 링크·사용되는 API와 최종 산출물의 plist를 함께
검사한다.

`PRIVACY_API_DEPENDENCY_MAP: COMPLETE_FOR_REPO_EVIDENCE / ROOT_CAUSE_CANDIDATE_CONFIRMED_AT_SOURCE` — Windows에서는
실제 Apple binary와 BuildUpload 진단을 확인할 수 없으므로, 아래 matrix는 저장소와
패키지 evidence에 기반한 현재 감사 결과이며 Build15 원인을 확정하지 않는다.

## Evidence matrix

| dependency/API | production evidence | sensitive surface | Runner key | current status | PlanFlow use |
| --- | --- | --- | --- | --- | --- |
| `speech_to_text` 7.4.0 / AVFoundation + Speech | `lib/services/stt_service.dart`, generated registrant, plugin README | microphone, speech recognition | `NSMicrophoneUsageDescription`, `NSSpeechRecognitionUsageDescription` | present | 음성 일정 입력 |
| `flutter_naver_map` 1.4.4 / CoreLocation | `LocationPickerScreen`, location picker flow, plugin iOS source | location while in use | `NSLocationWhenInUseUsageDescription` | present | 장소 선택·지도 위치 확인 |
| `google_maps_flutter_ios` 2.18.1 | registered plugin; map fallback; privacy manifest | CoreLocation-linked SDK surface | `NSLocationWhenInUseUsageDescription` | present | 지도 fallback |
| `google_mobile_ads` 5.3.1 | registered plugin and ad service; Google-Mobile-Ads-SDK pod | AdSupport/AppTrackingTransparency (IDFA/ATT) | `NSUserTrackingUsageDescription` | present | 관련 광고·측정 동의 |
| `file_picker` 11.0.2 (default `PICKER_MEDIA=1`) | `ios/file_picker.podspec` adds `DKImagePickerController/PhotoGallery` and compiles `PHPickerViewController`, `UIImagePickerController`, `#import <Photos/Photos.h>` into Runner | **photo library (linked, unused)** | `NSPhotoLibraryUsageDescription` | **absent — 90683 root-cause candidate** | media picker never called by PlanFlow |
| `file_picker` 11.0.2 (`Pod::PICKER_MEDIA = false`, applied) | `ios/Podfile`; every `PH*`/`UIImagePicker*`/`DKImagePicker*` reference in the plugin is inside `#ifdef PICKER_MEDIA` (verified by symbol/guard scan of the 11.0.2 sources) | none | no Photos key needed | surface removed | `FileType.custom` `.ics` import only |
| `webview_flutter_wkwebview` | no production camera/media capture call found | camera candidate only | camera key not added | no evidence | no direct production use |
| `NSCameraUsageDescription` / `AVCaptureDevice` | not found in PlanFlow production or linked-framework evidence | camera | `NSCameraUsageDescription` | absent | no |
| `NSPhotoLibraryUsageDescription` / `PHPhotoLibrary` | not found in PlanFlow production or linked-framework evidence | photos | `NSPhotoLibraryUsageDescription` | absent | no |
| `NSContactsUsageDescription` / `CNContactStore` | not found in PlanFlow production or linked-framework evidence | contacts | `NSContactsUsageDescription` | absent | no |
| `NSCalendarsUsageDescription` / `EKEventStore` | not found in PlanFlow production or linked-framework evidence | calendars | `NSCalendarsUsageDescription` | absent | no |
| `NSRemindersUsageDescription` / `EKEventStore` | not found in PlanFlow production or linked-framework evidence | reminders | `NSRemindersUsageDescription` | absent | no |
| `NSLocationAlwaysAndWhenInUseUsageDescription` | not found in PlanFlow production or linked-framework evidence | always location | `NSLocationAlwaysAndWhenInUseUsageDescription` | absent | no |
| `NSBluetoothAlwaysUsageDescription` / `CBCentralManager` | not found in PlanFlow production or linked-framework evidence | Bluetooth | `NSBluetoothAlwaysUsageDescription` | absent | no |
| `NSLocalNetworkUsageDescription` / `NWPathMonitor` | not found in PlanFlow production or linked-framework evidence | local network | `NSLocalNetworkUsageDescription` | absent | no |
| `NSMotionUsageDescription` / `CMMotionManager` | not found in PlanFlow production or linked-framework evidence | motion | `NSMotionUsageDescription` | absent | no |
| `NSFaceIDUsageDescription` / `LAContext` | not found in PlanFlow production or linked-framework evidence | Face ID | `NSFaceIDUsageDescription` | absent | no |
| `NSAppleMusicUsageDescription` / `MPMediaLibrary` | not found in PlanFlow production or linked-framework evidence | Apple Music | `NSAppleMusicUsageDescription` | absent | no |
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

## Root-cause classification (2026-09-04)

`ROOT_CAUSE_CLASS: LINKED_DEPENDENCY_SURFACE_WITHOUT_PURPOSE_STRING`

Evidence chain, all reproducible from the repository and the resolved package
sources (no macOS required):

1. `lib/screens/settings/naver_ics_import_screen.dart:72` is the only
   `file_picker` call site in production and uses `FileType.custom` (`.ics`).
2. `file_picker-11.0.2/ios/file_picker.podspec` defaults to `PICKER_MEDIA=1`
   whenever the Podfile does not set `Pod::PICKER_MEDIA=false`, and that branch
   adds `s.dependency 'DKImagePickerController/PhotoGallery'`.
3. With `PICKER_MEDIA=1` the plugin compiles `PHPickerViewController`,
   `PHPickerConfiguration`, `PHPickerResult`, and `UIImagePickerController`
   (`FilePickerPlugin.m`), and `FilePickerPlugin.h` imports `<PhotosUI/PHPicker.h>`.
4. `ios/Runner/Info.plist` declares only `NSMicrophoneUsageDescription`,
   `NSSpeechRecognitionUsageDescription`, `NSUserTrackingUsageDescription`,
   and `NSLocationWhenInUseUsageDescription` — no photo-library key.
5. Apple BuildUpload 90683 (`Missing purpose string in Info.plist`) named
   `Runner.app`, which is exactly the bundle those plugin objects link into.

Applied minimum fix: `Pod::PICKER_MEDIA = false` in `ios/Podfile`. This removes
the surface instead of declaring a purpose string for a capability PlanFlow does
not use, keeps document/audio picking intact, and touches no Android file.

`REMEDIATION_VERIFICATION: PENDING_MACOS_BINARY_GATE`. A guard/symbol scan of the
11.0.2 sources found no `PH*`, `UIImagePicker*`, `DKImagePicker*`, or
`AVCaptureDevice` reference outside `#ifdef PICKER_MEDIA`, so the change is
expected to remove the whole photo surface; only the archive/export binary gate
(`otool -L` on the built `Runner.app`) and Apple's own BuildUpload state can
confirm it. Neither is reachable from this Windows session.

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
runner. `.github/workflows/ios-privacy-audit.yml` (`audit_only=true`) is the
dispatch surface for that rerun; this session has no GitHub Actions
authentication and the Tool Gateway `github` tool exposes only read actions
(`repo_status`, `pr_list`, `pr_view`), so the audit was not dispatched and no
archive/IPA artifact was analysed here.

`BUILD_16_TESTFLIGHT: BLOCKED`. Build 16 must not be dispatched until the
audit-only workflow reruns on macOS with `Pod::PICKER_MEDIA = false` in place,
its archive and export privacy reports return exit 0 with the photo-library
frameworks absent from the `otool -L` evidence, and Apple's authoritative
BuildUpload state is clean.
