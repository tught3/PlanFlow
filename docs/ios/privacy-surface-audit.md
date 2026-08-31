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
| contacts/calendar/reminders/Bluetooth/motion/Face ID | no production call or linked-framework proof found | candidate | none | not added | not used |

The location key is Runner-only. The Widget has an App Group entitlement but no
location, microphone, speech, tracking, camera, photos, contacts, calendar, or
other Runner usage descriptions.

## Fail-closed gates

`scripts/verify-ios-privacy-surface.py` validates source/archive/exported Runner
and Widget plists. The archive/export release gates require a macOS scan of the
built Runner bundle and embedded binaries with `otool -L`, `nm`, and `strings`,
and report mapped sensitive frameworks. Unknown symbols are not treated as
proof of a missing key. A missing required key, failed binary scan, or a Runner
key copied into Widget fails the build.

Windows에서는 실제 macOS binary를 만들 수 없고 Xcode, `otool`, authoritative signed IPA를
실행할 수 없다;
the archive/export and binary gates must therefore run on the macOS GitHub
runner. The Build 15 upload remains blocked until those gates and Apple’s
authoritative BuildUpload state pass.
