// PlanFlow iOS Simulator E2E Phase — P5 — FLOW7: App Group / widget payload
// contract.
//
// 대상 매트릭스 항목(`docs/ios/SIMULATOR_QA_MATRIX.md`):
//   21. App Group shared data (Runner↔Widget UserDefaults 공유) — SIMULATOR_FULL
//   22. Widget payload generation — SIMULATOR_FULL
//   23. Widget rendering contract (실제 홈화면 WidgetKit 렌더링) —
//       PHYSICAL_DEVICE_REQUIRED
//
// ── 실측 결과: 홈 위젯 payload를 만드는 9개 지점의 스키마 ──────────────
// 티켓이 지정한 9개 파일을 전부 grep한 실측 결과, `home_widget` 패키지에
// 실제로 값을 쓰는 지점은 **두 개의 서로 다른, 각자 내부적으로는 일관된
// 스키마**로 나뉜다(하나로 합쳐지지 않는다). 아래 두 그룹 중 어느 쪽에도
// 속하지 않고 `HomeWidget.saveWidgetData`를 직접 호출하는 파일은 0개였다.
//
// [Contract A: 개인 일정 위젯 — `HomeWidgetService`(home_widget_service.dart)
//  경유, 앱그룹 `group.com.fluxstudio.planflow`]
//   - lib/screens/event/event_detail_screen.dart
//       → `homeWidgetService.updateSchedulePayload(
//          HomeWidgetSchedulePayloadBuilder.fromEvents(...))`
//   - lib/screens/event/event_edit_screen.dart      → 위와 동일 호출 패턴
//   - lib/screens/voice/confirm_screen.dart          → 위와 동일 호출 패턴
//   - lib/screens/voice/voice_action_screen.dart     → 위와 동일 호출 패턴
//   - lib/screens/home/home_screen.dart
//       → `_homeWidgetService.refreshScheduleFromEvents(...)` (내부적으로
//         동일한 `HomeWidgetSchedulePayloadBuilder.fromEvents` +
//         `updateSchedulePayload`를 호출하므로 스키마는 동일)
//   - lib/screens/settings/settings_screen.dart
//       → `_homeWidgetService.setHideWeekends(...)`/`.areWeekendsHidden()`만
//         호출한다. 전체 schedule payload는 쓰지 않고 `widget_hide_weekends`
//         단일 boolean 키만 건드리는 **더 좁은 하위 계약**이지만, 같은
//         `HomeWidgetService`/같은 플랫폼 seam을 거치므로 스키마 충돌은
//         없다.
//   - lib/features/groups/services/group_cleanup_service.dart
//       → `_homeWidgetService.refreshAfterGroupArchive(groupId, ...)`가
//         내부적으로 `refreshScheduleFromEvents`를 호출한다(간접 경유,
//         동일 스키마).
//   → 5개 화면이 전부 동일한 정적 빌더(`HomeWidgetSchedulePayloadBuilder
//     .fromEvents`)와 동일한 서비스 메서드(`updateSchedulePayload`)를
//     쓰므로, 이 5곳이 쓰는 SharedPreferences 키 이름은 코드 구조상
//     자동으로 일치한다(빌더/서비스가 하나뿐이라 드리프트가 물리적으로
//     불가능하다) — 아래 테스트가 이 사실을 소스 레벨로 고정한다.
//
// [Contract B: 그룹 캘린더 위젯 — `home_widget_platform.dart` 직접 사용,
//  별도 키 네임스페이스(`gw_*`), **Android 전용**]
//   - lib/features/groups/services/group_calendar_widget_service.dart
//       → `HomeWidgetPlatform.saveWidgetData`를 직접 호출한다(문서화된
//         키: `gw_groups_json`, `gw_<gid>_name`, `gw_<gid>_title`,
//         `gw_<gid>_occurrences_json`). **`if (!Platform.isAndroid) return;`
//         하드 게이트가 있어 iOS에서는 이 경로 전체가 no-op이다** — iOS
//         E2E 범위에서 그룹 캘린더 위젯 데이터는 애초에 기록되지
//         않는다는 뜻이며, 이는 버그가 아니라 실측으로 확인된 현재
//         동작이다(아래 테스트로 고정, 향후 iOS 그룹 위젯을 실제로
//         만들면 이 테스트를 의도적으로 갱신해야 한다).
//
// [읽기 전용 지점]
//   - lib/app.dart는 `HomeWidget.widgetClicked`/
//     `HomeWidget.initiallyLaunchedFromHomeWidget()`만 호출한다(수신 측).
//     `HomeWidget.saveWidgetData` 호출은 0건 — 쓰기 지점이 아니다.
//   - lib/screens/calendar/calendar_style_contract.dart는 스스로 쓰지
//     않고, Contract A(home_widget_service.dart)와 Contract B
//     (group_calendar_widget_service.dart) 양쪽에서 `calendarStyleContractPayload()`
//     를 호출해 같은 스타일 키를 두 위젯 모두에 동일하게 기록한다 —
//     날짜/요일/색상 팔레트 표기가 개인 위젯과 그룹 위젯 사이에서
//     어긋나지 않는다는 유일한 교차 계약 지점이다.
//
// ── App Group UserDefaults 왕복 검증의 한계 (정직 고백) ────────────────
// `HomeWidgetService`가 `HomeWidgetPlatform`(DI seam,
// `lib/services/home_widget_platform.dart`)을 주입받는 구조이므로, 이
// 파일은 그 seam에 인메모리 fake를 꽂아 "무엇을 어떤 키로 쓰려고
// 하는가"까지는 순수 Dart로 완전히 검증한다(아래 테스트). 하지만 그
// 값이 실제 iOS App Group 공유 컨테이너(`UserDefaults(suiteName:)`)에
// 물리적으로 저장되고, WidgetKit extension 프로세스가 같은가 값을
// 읽어내는 것까지는 네이티브 iOS 런타임이 필요해 이 Windows
// `dart analyze` 전용 환경에서는 시뮬레이션할 수 없다. 매트릭스는 항목
// 21(App Group 공유)을 SIMULATOR_FULL로 분류하지만, 그건 실제 iOS
// 시뮬레이터가 Runner + Widget extension 두 프로세스를 함께 띄운
// 상태를 전제한다 — 그 조건이 없는 이 검증 범위에서는 "쓰기 payload
// 구성까지만 SIMULATOR_FULL 수준, App Group 왕복 자체는 CI의 실제 iOS
// 시뮬레이터 실행에서만 실측 가능"으로 좁혀 다룬다. 항목 23(WidgetKit
// 실제 렌더링)은 매트릭스가 이미 PHYSICAL_DEVICE_REQUIRED로 분류했다.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/data/models/event_model.dart';
import 'package:planflow/services/home_widget_platform.dart';
import 'package:planflow/services/home_widget_service.dart';

import '_harness/app_harness.dart';

/// 테스트 실행 시점 기준 항상 미래인 해(年). 절대 날짜 리터럴을 그대로
/// 하드코딩하면 시간이 지나 과거가 되는 순간 테스트가 시한폭탄이 된다
/// (anti-patterns.md 2026-07-03 항목). 이 파일의 payload 빌더 로직 자체는
/// 어느 해든 상관없이 동작하므로, 상대 미래값으로만 바꿔도 테스트 의미는
/// 그대로 보존된다.
final int _futureYear = DateTime.now().year + 1;

/// [HomeWidgetPlatform]의 인메모리 fake. 실제 `MethodChannel`
/// (`home_widget` 패키지의 네이티브 브리지)을 전혀 건드리지 않고, 어떤
/// 키로 어떤 값이 쓰였는지·앱그룹 id가 무엇으로 설정됐는지·어떤 위젯
/// 이름으로 refresh가 호출됐는지를 그대로 기록한다.
class _CapturingHomeWidgetPlatform implements HomeWidgetPlatform {
  final Map<String, Object?> savedValues = <String, Object?>{};
  final List<String> setAppGroupIdCalls = <String>[];
  final List<String?> updateWidgetNameCalls = <String?>[];
  final List<String?> updateWidgetIOSNameCalls = <String?>[];

  @override
  bool get isSupported => true;

  @override
  Future<bool> saveWidgetData(String id, Object? data) async {
    savedValues[id] = data;
    return true;
  }

  @override
  Future<bool> setAppGroupId(String groupId) async {
    setAppGroupIdCalls.add(groupId);
    return true;
  }

  @override
  Future<bool> updateWidget({
    String? name,
    String? androidName,
    String? iOSName,
    String? qualifiedAndroidName,
  }) async {
    updateWidgetNameCalls.add(name);
    updateWidgetIOSNameCalls.add(iOSName);
    return true;
  }
}

/// 티켓이 지정한 9개 지점의 소스를 실제로 읽어 위 "실측 결과" 주석의
/// 주장을 코드로 고정한다. 사람이 쓴 주석이 소스와 어긋나게 낡아버리는
/// 것을 막기 위해, 이 테스트는 grep 결과를 하드코딩하지 않고 매 실행마다
/// 다시 읽어 검사한다.
class _WriteSiteContract {
  const _WriteSiteContract(this.relativePath);

  final String relativePath;

  String read() {
    // integration_test/에서 두 단계 위가 리포지토리 루트다.
    final file = File.fromUri(
      Directory.current.uri.resolve(relativePath),
    );
    return file.readAsStringSync();
  }
}

void main() {
  ensureIntegrationTestBinding();

  group(
    'FLOW7 — 9개 write-site의 payload 스키마 실측 (grep 기반 소스 계약)',
    () {
      const contractASites = <String>[
        'lib/screens/event/event_detail_screen.dart',
        'lib/screens/event/event_edit_screen.dart',
        'lib/screens/home/home_screen.dart',
        'lib/screens/settings/settings_screen.dart',
        'lib/screens/voice/confirm_screen.dart',
        'lib/screens/voice/voice_action_screen.dart',
        'lib/features/groups/services/group_cleanup_service.dart',
      ];

      for (final path in contractASites) {
        test(
          '$path는 raw HomeWidget.saveWidgetData를 직접 호출하지 않고 '
          'HomeWidgetService(Contract A)를 통해서만 홈 위젯을 건드린다',
          () {
            final source = _WriteSiteContract(path).read();

            expect(
              source.contains("home_widget_service.dart'"),
              isTrue,
              reason: '$path가 home_widget_service.dart를 import하지 않음 — '
                  '실측 근거가 되는 소스가 바뀌었을 수 있다',
            );
            expect(
              source.contains('HomeWidget.saveWidgetData'),
              isFalse,
              reason: '$path가 HomeWidgetService를 우회해 raw '
                  'HomeWidget.saveWidgetData를 직접 호출하면 Contract A의 '
                  '단일 빌더 보장이 깨진다',
            );
          },
        );
      }

      test(
        'lib/app.dart는 HomeWidget.widgetClicked/'
        'initiallyLaunchedFromHomeWidget()만 호출하는 읽기 전용 지점이며, '
        'HomeWidget.saveWidgetData 호출은 없다 (쓰기 스키마와 무관)',
        () {
          final source = _WriteSiteContract('lib/app.dart').read();

          expect(source.contains('HomeWidget.widgetClicked'), isTrue);
          expect(
            source.contains('HomeWidget.initiallyLaunchedFromHomeWidget'),
            isTrue,
          );
          expect(source.contains('HomeWidget.saveWidgetData'), isFalse);
        },
      );

      test(
        'lib/features/groups/services/group_calendar_widget_service.dart '
        '(Contract B)는 home_widget_platform.dart를 직접 사용하고, '
        'Platform.isAndroid 하드 게이트로 iOS에서는 no-op이다 — 개인 위젯 '
        '(Contract A)과 물리적으로 다른 스키마임을 소스로 고정한다',
        () {
          final source = _WriteSiteContract(
            'lib/features/groups/services/group_calendar_widget_service.dart',
          ).read();

          expect(source.contains("home_widget_platform.dart'"), isTrue);
          // Contract A와 섞여 쓰이면 안 된다 — 섞이면 두 위젯이 서로 다른
          // App Group 배선(개인 위젯의 HomeWidgetService 인스턴스)을
          // 공유하게 되어 refresh 타이밍/디바운스가 꼬일 수 있다.
          expect(source.contains("home_widget_service.dart'"), isFalse);
          expect(
            source.contains('Platform.isAndroid'),
            isTrue,
            reason: 'iOS no-op 게이트가 제거됐다면 이 테스트가 실패해 '
                '의도적인 변경인지 되짚어보게 만든다',
          );
          // 문서화된 gw_* 키 네임스페이스가 여전히 유효한지 최소 하나는
          // 실측 확인한다.
          expect(source.contains('gw_groups_json'), isTrue);
        },
      );

      test(
        'calendarStyleContractPayload()는 Contract A(home_widget_service.dart)와 '
        'Contract B(group_calendar_widget_service.dart) 양쪽에서 호출돼 '
        '두 위젯의 날짜/요일/색상 표기 키가 어긋나지 않게 공유된다',
        () {
          final contractASource =
              _WriteSiteContract('lib/services/home_widget_service.dart')
                  .read();
          final contractBSource = _WriteSiteContract(
            'lib/features/groups/services/group_calendar_widget_service.dart',
          ).read();

          expect(
            contractASource.contains('calendarStyleContractPayload()'),
            isTrue,
          );
          expect(
            contractBSource.contains('calendarStyleContractPayload()'),
            isTrue,
          );
        },
      );
    },
  );

  group(
    'FLOW7 — HomeWidgetSchedulePayloadBuilder (매트릭스 항목 22, '
    'widget payload generation, SIMULATOR_FULL — 순수 함수 로직)',
    () {
      test(
        'fromEvents는 다가오는 이벤트를 nextEvent로, 지난 이벤트는 '
        'lastPastEvent 후보로 분리한다',
        () {
          final now = DateTime(_futureYear, 6, 15, 12);
          final events = <EventModel>[
            EventModel(
              id: 'past-1',
              userId: 'user-1',
              title: '지난 회의',
              startAt: now.subtract(const Duration(hours: 2)),
              endAt: now.subtract(const Duration(hours: 1)),
            ),
            EventModel(
              id: 'future-1',
              userId: 'user-1',
              title: '다음 회의',
              startAt: now.add(const Duration(hours: 3)),
            ),
          ];

          final payload = HomeWidgetSchedulePayloadBuilder.fromEvents(
            events: events,
            now: now,
          );

          expect(payload.nextEvent.title, '다음 회의');
          expect(payload.nextEvent.eventId, 'future-1');
          expect(payload.lastPastEvent?.eventId, 'past-1');
          // monthCells는 항상 6주(42칸) 그리드로 생성된다.
          expect(payload.monthCells, hasLength(42));
        },
      );

      test(
        '이벤트가 하나도 없으면 emptyTitle이 nextEvent 제목으로 쓰이고 '
        'eventId는 null이다 (빈 상태 위젯이 크래시 대신 안내 문구를 '
        '보여준다)',
        () {
          final payload = HomeWidgetSchedulePayloadBuilder.fromEvents(
            events: const <EventModel>[],
            now: DateTime(_futureYear, 6, 15, 12),
            emptyTitle: '예정된 일정이 없어요',
          );

          expect(payload.nextEvent.title, '예정된 일정이 없어요');
          expect(payload.nextEvent.eventId, isNull);
        },
      );
    },
  );

  group(
    'FLOW7 — HomeWidgetService 쓰기 경로 (매트릭스 항목 21, App Group 공유 '
    '— HomeWidgetPlatform DI seam으로 "무엇을 쓰려는가"만 검증, App Group '
    '왕복 자체는 iOS 런타임 필요)',
    () {
      test(
        'iOSAppGroupId는 WidgetKit 타깃과 공유하는 '
        'group.com.fluxstudio.planflow로 기본 설정돼 있다',
        () {
          final service = HomeWidgetService();
          expect(service.iOSAppGroupId, 'group.com.fluxstudio.planflow');
        },
      );

      test(
        'updateSchedulePayload 호출 시 setAppGroupId가 먼저 호출되고, '
        '핵심 스케줄 키(next_event_title/widget_schedule_payload_v1/'
        'schedule_events_json)가 캡처 플랫폼에 기록되며, 완료 시점을 '
        '표시하는 generation 키가 pending→complete 순서로 기록된다. '
        '`refreshScheduleFromEvents`가 아니라 `updateSchedulePayload`를 '
        '직접 호출하는 이유: `refreshScheduleFromEvents`는 내부에서 '
        '`KasiHolidayService.instance.primeYears(...)`(실제 공공데이터 '
        'API로 HTTP 요청)를 무조건 먼저 호출하는데, 4/5 화면(이벤트 상세/'
        '수정, 음성 확인, 음성 액션)은 애초에 `updateSchedulePayload`를 '
        '직접 호출하지 `refreshScheduleFromEvents`를 거치지 않는다 — 더 '
        '흔한 호출 경로를 재현하면서 `NetworkCallRecorder` 전제(실제 '
        '네트워크 호출 0건)를 지킨다',
        () async {
          final platform = _CapturingHomeWidgetPlatform();
          final service = HomeWidgetService(platform: platform);
          final now = DateTime(_futureYear, 7, 1, 9);
          final events = <EventModel>[
            EventModel(
              id: 'e1',
              userId: 'user-1',
              title: '이번 달 일정',
              startAt: now.add(const Duration(days: 1)),
            ),
          ];

          final success = await service.updateSchedulePayload(
            HomeWidgetSchedulePayloadBuilder.fromEvents(
              events: events,
              now: now,
            ),
          );

          expect(success, isTrue);
          expect(
            platform.setAppGroupIdCalls,
            contains('group.com.fluxstudio.planflow'),
          );
          expect(platform.savedValues['next_event_title'], '이번 달 일정');
          expect(
            platform.savedValues.containsKey('widget_schedule_payload_v1'),
            isTrue,
          );
          expect(
            platform.savedValues.containsKey('schedule_events_json'),
            isTrue,
          );
          expect(
            platform.savedValues.containsKey(
              'widget_payload_generation_pending',
            ),
            isTrue,
          );
          expect(
            platform.savedValues.containsKey(
              'widget_payload_generation_complete',
            ),
            isTrue,
          );
          // pending과 complete는 같은 generation 값을 공유한다 — 네이티브
          // 위젯이 이 값으로 "이 payload가 끝까지 다 쓰였는가"를 판별한다.
          expect(
            platform.savedValues['widget_payload_generation_pending'],
            platform.savedValues['widget_payload_generation_complete'],
          );
        },
      );

      test(
        '기본 widgetName으로 refresh하면 안드로이드 위젯 provider 이름 '
        '목록(defaultAndroidWidgetNames)으로만 updateWidget이 호출되고, '
        'iOSName은 이 기본 경로에서 전달되지 않는다 — 실측으로 확인한 '
        '현재 동작을 계약으로 고정한다(문서화 목적, 옳고 그름을 판단하지 '
        '않는다: home_widget 0.9.3 패키지가 iOSName 미지정 시 name으로 '
        '폴백하는지는 네이티브 코드까지 확인하지 못해 이 테스트 범위 밖)',
        () async {
          final platform = _CapturingHomeWidgetPlatform();
          final service = HomeWidgetService(platform: platform);

          await service.updateSchedulePayload(
            HomeWidgetSchedulePayloadBuilder.fromEvents(
              events: const <EventModel>[],
              now: DateTime(_futureYear, 7, 1, 9),
            ),
          );

          expect(
            platform.updateWidgetNameCalls,
            containsAll(HomeWidgetService.defaultAndroidWidgetNames),
          );
          expect(
            platform.updateWidgetIOSNameCalls.every((name) => name == null),
            isTrue,
            reason: '기본 경로가 iOSName을 전달하기 시작했다면(예: 이 '
                '틈을 메우는 수정이 들어갔다면) 이 테스트가 실패해 그 '
                '변경을 명시적으로 인지하게 만든다',
          );
        },
      );

      test(
        'isSupported=false인 플랫폼(fake로 강제)에서는 아무 값도 쓰지 '
        '않고 즉시 실패를 반환한다 (App Group 미지원 환경에서 조용히 '
        '부분 쓰기가 남는 것을 방지)',
        () async {
          final platform = _UnsupportedHomeWidgetPlatform();
          final service = HomeWidgetService(platform: platform);

          final success = await service.updateSchedulePayload(
            HomeWidgetSchedulePayloadBuilder.fromEvents(
              events: const <EventModel>[],
              now: DateTime(_futureYear, 7, 1, 9),
            ),
          );

          expect(success, isFalse);
          expect(platform.saveWidgetDataCallCount, 0);
        },
      );
    },
  );
}

class _UnsupportedHomeWidgetPlatform implements HomeWidgetPlatform {
  int saveWidgetDataCallCount = 0;

  @override
  bool get isSupported => false;

  @override
  Future<bool> saveWidgetData(String id, Object? data) async {
    saveWidgetDataCallCount += 1;
    return false;
  }

  @override
  Future<bool> setAppGroupId(String groupId) async => false;

  @override
  Future<bool> updateWidget({
    String? name,
    String? androidName,
    String? iOSName,
    String? qualifiedAndroidName,
  }) async =>
      false;
}
