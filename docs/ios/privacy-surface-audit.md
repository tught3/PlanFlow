# PlanFlow iOS privacy-surface audit

기준: Build 13/14/15에서 Apple BuildUpload가 `90683 Missing purpose string`
(affected bundle `Runner.app`)으로 실패했다. production release #15 transport는
PASS였지만 BuildUpload `90683`은 historical failure로 남아 있다. 따라서 패키지
이름만으로 권한을 추가하지 않고, 실제 Runner에 링크·사용되는 API와 최종 산출물의
plist를 함께 검사한다.

`PRIVACY_API_DEPENDENCY_MAP: ROOT_CAUSE_STRONGLY_NARROWED` — Run #3의
archive/export binary evidence가 Photos API와 Google Maps photo-service 문자열을
확인했으며, Apple의 authoritative `stateDetails`가 제공되기 전까지 최종 원인은
확정하지 않는다.

Run #4 authenticated evidence (`33608563745` on head `22364b0f`, artifact
`9838418791`, digest `sha256:5d030ffc79c827c329655095ea9a8e98d1001d75bc2392804e86f6a5971d216a`)
confirms `source/archive/export` reports `PASS`, `archive_privacy_exit=0`,
`export_exit=0`, `unzip_exit=0`, and `export_privacy_exit=0`. Six Runner keys are
`true`, Widget forbidden keys are empty, and the filtered report captures
`Photos.framework`, `PHPhotoLibrary`, `UIImageWriteToSavedPhotosAlbum`,
`AVFoundation`, `Speech`, `AdSupport`, `CoreLocation`, and Google Maps
photo-service evidence. `DKPhotoGallery`, `DKImagePickerController`, and
`file_picker` are not found in the filtered report. Candidate-only keys remain
unadded, and no additional `UsageDescription` key or source fix is required.
`ROOT_CAUSE_STRONGLY_NARROWED` remains correct because Apple `stateDetails` is
still unavailable.

## Run #3 archive/export evidence

Artifact Run `33568134813` (artifact `9824161474`, digest
`sha256:d3477c890b9174c52bea5dda208d064dcbec3308e84ee72923cbc7e78fc23a70`)의
`archive-privacy-report.json`과 `export-privacy-report.json`은 모두 `PASS`이고,
`archive_privacy_exit=0`, `export_exit=0`, `unzip_exit=0`,
`export_privacy_exit=0`이다. `Runner`가 Photos/PhotosUI를 링크하고
`PHPhotoLibrary`, `PHChange`/`PHFetchResultChangeDetails`,
`UIImageWriteToSavedPhotosAlbum`를 포함하는 것이 확인되었다. 문자열에는
`GMSMobileMapsPhotoService`와 `GMS photo service`가 포함되었다. 저장소에서도
`lib/screens/location/location_picker_screen.dart`가 `google_maps_flutter`를
사용하므로, Runner에는 사진 보관함 읽기와 추가 목적 문자열을 함께 선언한다.

## Evidence matrix

| dependency/API | production evidence | sensitive surface | Runner key | current status | PlanFlow use |
| --- | --- | --- | --- | --- | --- |
| `speech_to_text` 7.4.0 / AVFoundation + Speech | `lib/services/stt_service.dart`, generated registrant, plugin README | microphone, speech recognition | `NSMicrophoneUsageDescription`, `NSSpeechRecognitionUsageDescription` | present | 음성 일정 입력 |
| `flutter_naver_map` 1.4.4 / CoreLocation | `LocationPickerScreen`, location picker flow, plugin iOS source | location while in use | `NSLocationWhenInUseUsageDescription` | present | 장소 선택·지도 위치 확인 |
| `google_maps_flutter_ios` 2.18.1 | registered plugin; map fallback; privacy manifest | CoreLocation-linked SDK surface | `NSLocationWhenInUseUsageDescription` | present | 지도 fallback |
| `google_mobile_ads` 5.3.1 | registered plugin and ad service; Google-Mobile-Ads-SDK pod | AdSupport/AppTrackingTransparency (IDFA/ATT) | `NSUserTrackingUsageDescription` | present | 관련 광고·측정 동의 |
| `file_picker` 11.0.2 | `NaverIcsImportScreen` calls `FileType.custom` for `.ics` | no additional media-picker evidence | covered by the Run #3 map SDK photo surface | no separate key | ICS import |
| `webview_flutter_wkwebview` | no production camera/media capture call found | camera candidate only | camera key not added | no evidence | no direct production use |
| `NSCameraUsageDescription` / `AVCaptureDevice` | not found in PlanFlow production or linked-framework evidence | camera | `NSCameraUsageDescription` | absent | no |
| `NSPhotoLibraryUsageDescription` / `PHPhotoLibrary` | Run #3 archive/export PASS: Photos/PhotosUI, `PHPhotoLibrary`, `PHChange`/`PHFetchResultChangeDetails`; `google_maps_flutter` location picker | photos | `NSPhotoLibraryUsageDescription` | present | 지도 SDK 장소 사진 표시 |
| `NSContactsUsageDescription` / `CNContactStore` | Run #3: Contacts.framework linked, but no `CNContactStore` symbol; no direct PlanFlow call | contacts | `NSContactsUsageDescription` | absent | no; SDK candidate only |
| `NSCalendarsUsageDescription` / `EKEventStore` | not found in PlanFlow production or linked-framework evidence | calendars | `NSCalendarsUsageDescription` | absent | no |
| `NSRemindersUsageDescription` / `EKEventStore` | not found in PlanFlow production or linked-framework evidence | reminders | `NSRemindersUsageDescription` | absent | no |
| `NSLocationAlwaysAndWhenInUseUsageDescription` | not found in PlanFlow production or linked-framework evidence | always location | `NSLocationAlwaysAndWhenInUseUsageDescription` | absent | no |
| `NSBluetoothAlwaysUsageDescription` / `CBCentralManager` | not found in PlanFlow production or linked-framework evidence | Bluetooth | `NSBluetoothAlwaysUsageDescription` | absent | no |
| `NSLocalNetworkUsageDescription` / `NWPathMonitor` | Run #3: Network.framework linked, but no `NWPathMonitor` symbol; no direct PlanFlow call | local network | `NSLocalNetworkUsageDescription` | absent | no; SDK candidate only |
| `NSMotionUsageDescription` / `CMMotionManager` | Run #3: `CMMotionManager` symbol in Runner; no direct PlanFlow call | motion | `NSMotionUsageDescription` | absent | no; SDK candidate only |
| `NSFaceIDUsageDescription` / `LAContext` | Run #3: `LAContext` symbol in Runner; no direct PlanFlow call | Face ID | `NSFaceIDUsageDescription` | absent | no; SDK candidate only |
| `NSAppleMusicUsageDescription` / `MPMediaLibrary` | Run #3: MediaPlayer.framework linked, but no `MPMediaLibrary` symbol; no direct PlanFlow call | Apple Music | `NSAppleMusicUsageDescription` | absent | no; SDK candidate only |
| `AVCaptureDevice` / camera APIs | no PlanFlow camera call or linked-framework proof found | camera | `NSCameraUsageDescription` | not added; no evidence | not used; dependency-only candidate |
| `PHPhotoLibrary` / photo APIs | Run #3 archive/export PASS: `PHPhotoLibrary`, `PHChange`/`PHFetchResultChangeDetails`; `GMSMobileMapsPhotoService`, `GMS photo service` | photo read | `NSPhotoLibraryUsageDescription` | present | 지도 SDK 장소 사진 표시 |
| photo write APIs | Run #3 archive/export PASS: `UIImageWriteToSavedPhotosAlbum`; `google_maps_flutter` is used by the location picker | photo write | `NSPhotoLibraryAddUsageDescription` | present | 지도 SDK 이미지 저장 |
| `CNContactStore` / Contacts | no contacts API call or linked-framework proof found | contacts | `NSContactsUsageDescription` | not added; no evidence | not used |
| `EKEventStore` / EventKit calendars | no EventKit call; app calendar is Supabase/local data | calendars | `NSCalendarsUsageDescription` | not added; no evidence | not used |
| `EKEventStore` reminders | no reminders API call or linked-framework proof found | reminders | `NSRemindersUsageDescription` | not added; no evidence | not used |
| CoreLocation always authorization | plugin evidence is when-in-use only; no always authorization call found | location always | `NSLocationAlwaysAndWhenInUseUsageDescription` | not added; no evidence | not used |
| `CBCentralManager` / Bluetooth | no Bluetooth API call or linked-framework proof found | Bluetooth | `NSBluetoothAlwaysUsageDescription` | not added; no evidence | not used |
| `NWPathMonitor` / local network | no local-network browsing/listener or linked-framework proof found | local network | `NSLocalNetworkUsageDescription` | not added; no evidence | not used |
| `CMMotionManager` / motion | Run #3 Runner symbol only; no direct PlanFlow API call | motion | `NSMotionUsageDescription` | not added; SDK-only candidate | not used |
| `LAContext` / LocalAuthentication | Run #3 Runner symbol only; no direct PlanFlow API call | Face ID | `NSFaceIDUsageDescription` | not added; SDK-only candidate | not used |
| `MPMediaLibrary` / Apple Music | Run #3 MediaPlayer link only; no `MPMediaLibrary` symbol or direct PlanFlow call | media library | `NSAppleMusicUsageDescription` | not added; SDK-only candidate | not used |

The location key is Runner-only. The Widget has an App Group entitlement but no
location, microphone, speech, tracking, camera, photos, contacts, calendar, or
other Runner usage descriptions.

Build 16 and TestFlight have not been run yet, and Android remains unchanged.

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
runner. Run #4 satisfies those audit gates, but Build 16 remains pending the
production release workflow run-number check and Apple transport, BuildUpload,
ingestion, and TestFlight evidence.

The Run #4 dependency map update does not change the signing/release workflow:
the existing gates stay fail-closed, and the required source/archive/export
evidence remains the source of truth.
