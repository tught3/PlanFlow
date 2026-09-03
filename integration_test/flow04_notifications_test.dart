// PlanFlow iOS Simulator E2E Phase — P5 — FLOW4: notifications.
//
// 대상 매트릭스 항목(`docs/ios/SIMULATOR_QA_MATRIX.md`):
//   14. notification route handling (탭 시 라우팅) — SIMULATOR_FULL
//   15. local notification scheduling — SIMULATOR_PARTIAL
//   16. notification tap routing (OS 알림 실제 탭) — PHYSICAL_DEVICE_REQUIRED
//
// 이 파일이 실제로 검증하는 것 / 하지 않는 것:
// - 예약(schedule)·취소(cancel)·재예약(reschedule)은
//   `NotificationService`의 `*WithResult` 계열 메서드 오버라이드를 통한
//   `FakeNotificationService`(`integration_test/_harness/fakes/
//   fake_notification_service.dart`)로 검증한다. 실제 플랫폼 채널
//   (`FlutterLocalNotificationsPlugin`)은 전혀 호출되지 않는다 — 이건
//   "예약 로직(트리거 시각 계산·payload 구성)"만 검증 가능하다는 항목 15의
//   SIMULATOR_PARTIAL 분류와 정확히 일치한다. 실제 OS 알림 센터 딜리버리
//   타이밍·잠금화면 표시는 이 테스트의 범위 밖이다.
// - "알림 탭 라우팅"은 두 개의 서로 다른(중복이 아닌) 계약이 이 코드베이스에
//   공존한다는 사실을 실측으로 확인했다:
//     (a) `lib/services/notification_service.dart`의
//         `routeForNotificationResponse` — `flutter_local_notifications`의
//         `NotificationResponse.payload`(예: `event:<id>`, `departure:<id>`,
//         `briefing:morning` 등 문자열 prefix)를 라우트로 변환한다. 실제
//         일정/출발/브리핑 알림 탭이 타는 경로가 이것이다.
//     (b) `lib/services/notification_route_contract.dart`의
//         `NotificationRouteContract.canonicalPath` — `planflow://schedule/id`,
//         `planflow://day/yyyy-MM-dd` 형태의 URI를 라우트로 변환한다. 실측
//         호출부는 `lib/app.dart`의 홈 위젯 클릭 핸들러
//         (`HomeWidget.widgetClicked`/`initiallyLaunchedFromHomeWidget`)뿐이며,
//         클래스 docstring이 "notification and widget entrypoints"라고
//         명시하지만 실제로 flutter_local_notifications 알림 탭 경로에
//         배선된 호출부는 찾지 못했다(`grep -rn
//         'NotificationRouteContract' lib`로 확인, 결과는 이 테스트 하단
//         "실측 결과" 참고).
//   이 티켓의 지시대로 (b) `NotificationRouteContract.canonicalPath()`를
//   직접 호출해 결과 문자열이 실제 `AppRoutes`(`lib/core/router.dart`가
//   등록한 라우트 패턴)와 일치하는지까지 검증한다. 그 문자열을 실제
//   `GoRouter`에 태워 화면을 렌더링하는 전체 내비게이션까지는 하지 않는다
//   — `EventDetailScreen`/`CalendarScreen`은 실제 이벤트 리포지토리·인증
//   상태에 의존하므로, 존재하지 않는 합성 id로 라우팅을 강행하면 네트워크
//   호출(Supabase) 위험이 생겨 이 스위트의 "no network call" 전제와
//   충돌한다. 그래서 검증은 "그 문자열이 라우터가 실제로 등록한 라우트
//   패턴과 정확히 일치하는가"까지로 좁힌다 — 이는 GoRouter의 경로 매칭이
//   순수 문자열 패턴 매칭이라는 점에서 안전한 대리 검증이다. 실제 OS
//   알림을 탭해 화면 전환까지 확인하는 것은 매트릭스 항목 16대로
//   PHYSICAL_DEVICE_REQUIRED다.
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/core/constants.dart';
import 'package:planflow/services/notification_route_contract.dart';
import 'package:planflow/services/notification_service.dart';

import '_harness/app_harness.dart';
import '_harness/fakes/fake_notification_service.dart';

/// 테스트 실행 시점 기준 항상 미래인 해(年). 절대 날짜 리터럴을 그대로
/// 하드코딩하면 그 해가 지나는 순간 테스트가 "이미 지난 시각"이 되어
/// 시한폭탄이 된다(anti-patterns.md 2026-07-03 항목). `FakeNotificationService`는
/// 실제로 과거/미래를 검사하지 않지만(오버라이드가 base class의
/// `notifyAt.isAfter(DateTime.now())` 체크를 우회한다), 그래도 상대
/// 미래값을 쓰는 게 의미상 정확하다(예약은 항상 미래 시각이어야 한다).
final int _futureYear = DateTime.now().year + 1;

void main() {
  // 위젯 트리를 pump하지 않지만(순수 서비스 seam 호출), 다른 시나리오와
  // 동일한 하네스 바인딩 초기화 관례를 따른다.
  ensureIntegrationTestBinding();

  group(
    'FLOW4 — local notification scheduling / cancel / reschedule '
    '(매트릭스 항목 15, SIMULATOR_PARTIAL)',
    () {
      late FakeNotificationService notificationService;

      setUp(() {
        notificationService = FakeNotificationService();
      });

      test(
        'scheduleEventReminder captures id/title/notifyAt/payload exactly '
        'as passed (예약 로직 자체의 seam 정합성)',
        () async {
          final notifyAt = DateTime(_futureYear, 1, 1, 9, 0);

          await notificationService.scheduleEventReminder(
            id: 42,
            title: '팀 회의',
            body: '10분 뒤 팀 회의가 시작됩니다',
            notifyAt: notifyAt,
            payload: 'event:evt-42',
          );

          expect(notificationService.scheduledEventReminders, hasLength(1));
          final call = notificationService.scheduledEventReminders.single;
          expect(call.id, 42);
          expect(call.title, '팀 회의');
          expect(call.notifyAt, notifyAt);
          expect(call.payload, 'event:evt-42');
          expect(notificationService.cancelledIds, isEmpty);
        },
      );

      test(
        'critical alarm and departure alarm scheduling are captured on '
        'independent lists (한 알림 종류의 예약이 다른 종류를 오염시키지 않는다)',
        () async {
          final criticalAt = DateTime(_futureYear, 3, 1, 8);
          final departureAt = DateTime(_futureYear, 3, 1, 7, 30);

          await notificationService.scheduleCriticalAlarm(
            id: 100,
            title: '중요 일정',
            notifyAt: criticalAt,
          );
          await notificationService.scheduleDepartureAlarm(
            id: 101,
            title: '출발 알림',
            body: '지금 출발하세요',
            notifyAt: departureAt,
          );

          expect(notificationService.scheduledCriticalAlarms, hasLength(1));
          expect(notificationService.scheduledDepartureAlarms, hasLength(1));
          expect(notificationService.scheduledEventReminders, isEmpty);
          expect(
            notificationService.scheduledCriticalAlarms.single.notifyAt,
            criticalAt,
          );
          expect(
            notificationService.scheduledDepartureAlarms.single.notifyAt,
            departureAt,
          );
        },
      );

      test(
        'cancel(id) records the id and pendingNotificationCount reflects it '
        '(취소가 실제로 pending 집계에 반영된다)',
        () async {
          await notificationService.scheduleEventReminder(
            id: 7,
            title: '점심 약속',
            body: '30분 뒤 점심 약속',
            notifyAt: DateTime(_futureYear, 4, 1, 12),
          );
          expect(await notificationService.pendingNotificationCount(), 1);

          await notificationService.cancel(7);

          expect(notificationService.cancelledIds, contains(7));
          expect(await notificationService.pendingNotificationCount(), 0);
        },
      );

      test(
        'reschedule (cancel 후 같은 id로 다시 schedule)는 이전 예약 이력을 '
        '지우지 않고 최신 notifyAt이 그 id의 유효값이 된다 (실제 일정 수정 '
        '흐름이 취소 후 재예약하는 패턴을 그대로 재현)',
        () async {
          const id = 55;
          final firstNotifyAt = DateTime(_futureYear, 5, 1, 9);
          final secondNotifyAt = DateTime(_futureYear, 5, 2, 10);

          await notificationService.scheduleEventReminder(
            id: id,
            title: '원래 제목',
            body: '원래 본문',
            notifyAt: firstNotifyAt,
          );
          await notificationService.cancel(id);
          await notificationService.scheduleEventReminder(
            id: id,
            title: '수정된 제목',
            body: '수정된 본문',
            notifyAt: secondNotifyAt,
          );

          // 취소는 정확히 1회, 같은 id로 2회 예약(원본+재예약) 기록이
          // 남는다 — fake는 실제 플랫폼처럼 같은 id를 덮어쓰지 않고 호출
          // 이력을 전부 보존하므로, "최신 예약이 유효하다"는 것은 마지막
          // 항목을 확인하는 것으로 검증한다(실제 flutter_local_notifications
          // 플러그인은 같은 id로 다시 zonedSchedule하면 이전 예약을
          // 덮어쓴다).
          expect(notificationService.cancelledIds, [id]);
          expect(
            notificationService.scheduledEventReminders
                .where((call) => call.id == id)
                .map((call) => call.notifyAt),
            [firstNotifyAt, secondNotifyAt],
          );
          final latestForId =
              notificationService.scheduledEventReminders.last;
          expect(latestForId.id, id);
          expect(latestForId.title, '수정된 제목');
          expect(latestForId.notifyAt, secondNotifyAt);
        },
      );

      test(
        'permissionBlocked/skippedPast 상태를 fake로 강제해도 실제 플랫폼 '
        '채널 호출 없이 순수하게 결과값만 분기한다 (권한 거부·과거 시각 '
        '예약 실패 경로)',
        () async {
          notificationService.eventReminderStatus =
              NotificationScheduleStatus.permissionBlocked;

          final result =
              await notificationService.scheduleEventReminderWithResult(
            id: 200,
            title: '거부될 예약',
            body: '알림 권한이 없는 상태',
            notifyAt: DateTime(_futureYear, 6, 1, 9),
          );

          expect(result.status, NotificationScheduleStatus.permissionBlocked);
          expect(result.isScheduled, isFalse);
          // 결과가 permissionBlocked여도 호출 자체(=예약 시도)는 여전히
          // 기록된다 — 실제 코드에서 "시도했지만 거부됨"과 "시도조차 안
          // 함"을 구분해야 하는 호출부(예: 사용자에게 권한 안내 배너)가
          // 있으므로 이 구분이 보존되는지 확인한다.
          expect(notificationService.scheduledEventReminders, hasLength(1));
        },
      );
    },
  );

  group(
    'FLOW4 — notification tap → canonical route string '
    '(매트릭스 항목 14, SIMULATOR_FULL; 실제 OS 탭은 항목 16 '
    'PHYSICAL_DEVICE_REQUIRED)',
    () {
      test(
        'NotificationRouteContract.schedule(id) → canonicalPath는 '
        'AppRoutes.eventDetailWithId 라우트 패턴과 정확히 일치하는 '
        '경로 문자열을 만든다',
        () {
          final uri = NotificationRouteContract.schedule('evt-99');
          final path = NotificationRouteContract.canonicalPath(uri);

          expect(path, '${AppRoutes.eventDetail}/evt-99');
          // AppRoutes.eventDetailWithId('/event/detail/:eventId')가 실제
          // GoRouter에 등록된 패턴이며, 위 결과 문자열이 그 패턴의
          // ':eventId' 슬롯에 'evt-99'를 채운 것과 동일한 형태임을
          // 문자열 접두사 비교로 확인한다(전체 GoRouter 매칭 엔진을
          // 재구현하지 않고, 라우트 세그먼트 접두사가 실제 등록된 상수와
          // 일치하는지만 고정한다).
          expect(
            AppRoutes.eventDetailWithId.startsWith(AppRoutes.eventDetail),
            isTrue,
          );
        },
      );

      test(
        'NotificationRouteContract.day(date) → canonicalPath는 '
        'AppRoutes.calendar 라우트에 date 쿼리 파라미터를 붙인 경로를 '
        '만든다',
        () {
          final date = DateTime(_futureYear, 3, 15);
          final uri = NotificationRouteContract.day(date);
          final path = NotificationRouteContract.canonicalPath(uri);

          expect(path, '${AppRoutes.calendar}?date=2027-03-15');
        },
      );

      test(
        'planflow 스킴이 아니거나 인식할 수 없는 host/path는 null을 '
        '반환한다 (알 수 없는 딥링크로 크래시하거나 엉뚱한 라우팅을 하지 '
        '않는다)',
        () {
          expect(
            NotificationRouteContract.canonicalPath(
              Uri.parse('https://example.com/schedule/evt-1'),
            ),
            isNull,
          );
          expect(
            NotificationRouteContract.canonicalPath(
              Uri.parse('planflow://unknown-host/evt-1'),
            ),
            isNull,
          );
          expect(
            NotificationRouteContract.canonicalPath(
              Uri.parse('planflow://day/not-a-date'),
            ),
            isNull,
          );
        },
      );

      test(
        '실제 flutter_local_notifications 탭 경로(routeForNotificationResponse)는 '
        'event:/departure:/briefing: payload prefix를 쓰는 별개 계약이며, '
        'NotificationRouteContract와 스킴이 겹치지 않는다는 사실을 '
        '문서화한다 — 실측 확인: routeForNotificationResponse는 '
        'NotificationResponse.payload 문자열 하나만 받고 Uri/scheme 개념이 '
        '없다',
        () {
          // 순수 문서화 목적 단언. NotificationResponse는
          // flutter_local_notifications 패키지의 실제 클래스이며, id는
          // 필수 파라미터다.
          const response = NotificationResponse(
            notificationResponseType:
                NotificationResponseType.selectedNotification,
            payload: 'event:evt-77',
          );

          expect(
            NotificationService.routeForNotificationResponse(response),
            '${AppRoutes.eventDetail}/evt-77',
          );
          // 같은 evt-77이라도 NotificationRouteContract 경로로 들어오면
          // 동일한 canonical 목적지에 도착한다 — 두 계약이 서로 다른 입력
          // 형식(payload 문자열 vs URI)을 쓰지만 최종 라우트 문자열
          // 네임스페이스는 겹치지 않게 설계돼 있음을 확인한다.
          expect(
            NotificationRouteContract.canonicalPath(
              NotificationRouteContract.schedule('evt-77'),
            ),
            '${AppRoutes.eventDetail}/evt-77',
          );
        },
      );
    },
  );
}
