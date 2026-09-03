import 'package:planflow/data/models/event_model.dart';
import 'package:planflow/services/korean_holidays.dart';

/// E2E 시나리오가 공유하는 결정론적 일정 픽스처.
///
/// **절대 날짜를 하드코딩하지 않는다** — anti-patterns.md에 기록된
/// "시간의존 테스트에 절대 날짜 하드코딩 금지(클램프·만료 로직이 있는
/// 경우)" 방지책을 그대로 따른다. 클램프/만료 로직이 있는 화면(예:
/// ConfirmScreen의 "1일 이상 과거면 now()로 클램프")을 거치면 절대 과거
/// 날짜는 시한폭탄이 된다. 모든 날짜는 [DateTime.now] 기준 상대값으로
/// 계산한다.
class FixtureEvents {
  FixtureEvents._();

  static const String fixtureUserId = 'e2e-fixture-user';

  /// 오늘부터 [daysFromNow]일 뒤, 지정한 시/분에 열리는 단순 일정.
  static EventModel simple({
    String id = 'e2e-event-simple',
    String title = 'E2E 테스트 일정',
    int daysFromNow = 1,
    int hour = 10,
    int minute = 0,
    Duration duration = const Duration(hours: 1),
  }) {
    final now = DateTime.now();
    final startAt = DateTime(now.year, now.month, now.day, hour, minute)
        .add(Duration(days: daysFromNow));
    return EventModel(
      id: id,
      userId: fixtureUserId,
      title: title,
      startAt: startAt,
      endAt: startAt.add(duration),
    );
  }

  /// 중요 일정(강한 알람) 표시가 켜진 일정.
  static EventModel critical({
    String id = 'e2e-event-critical',
    String title = 'E2E 중요 일정',
    int daysFromNow = 1,
  }) {
    final base = simple(id: id, title: title, daysFromNow: daysFromNow);
    return EventModel(
      id: base.id,
      userId: base.userId,
      title: base.title,
      startAt: base.startAt,
      endAt: base.endAt,
      isCritical: true,
      useStrongAlarm: true,
    );
  }

  /// 매주 반복되는 일정(`FREQ=WEEKLY;BYDAY=...`). RRULE 형식은
  /// `test/core/recurrence_expansion_test.dart`의 실제 사용 패턴을 따른다.
  static EventModel recurringWeekly({
    String id = 'e2e-event-recurring-weekly',
    String title = 'E2E 반복 일정',
    int daysFromNow = 1,
  }) {
    final base = simple(id: id, title: title, daysFromNow: daysFromNow);
    final startAt = base.startAt!;
    return EventModel(
      id: base.id,
      userId: base.userId,
      title: base.title,
      startAt: startAt,
      endAt: base.endAt,
      recurrenceRule: 'FREQ=WEEKLY;BYDAY=${_weekdayCode(startAt)}',
    );
  }

  /// 다음 신정(1/1)에 열리는 일정.
  ///
  /// `(month, day)` 고정 공휴일이라 연도를 [DateTime.now]의 다음 해로
  /// 잡아도 항상 미래이면서 항상 공휴일이다(`KoreanHolidays._fixed`,
  /// `lib/services/korean_holidays.dart:8`의 `(1, 1): '신정'` 참고).
  /// [KoreanHolidays.isHoliday]로 그 전제를 실측 assert한다. 이 픽스처는
  /// 오프라인 klc 계산값만 사용하며, `kasi_holiday_service.dart`가
  /// 보강하는 실시간 데이터(네트워크)와는 무관하다.
  static EventModel nearHoliday({
    String id = 'e2e-event-near-holiday',
    String title = 'E2E 공휴일 인접 일정',
  }) {
    final now = DateTime.now();
    final nextNewYearsDay = DateTime(now.year + 1, 1, 1, 9, 0);
    assert(
      KoreanHolidays.isHoliday(nextNewYearsDay),
      'nextNewYearsDay(${nextNewYearsDay.toIso8601String()})가 '
      'KoreanHolidays 계산상 공휴일이 아닙니다 — 픽스처 전제가 깨졌습니다.',
    );
    return EventModel(
      id: id,
      userId: fixtureUserId,
      title: title,
      startAt: nextNewYearsDay,
      endAt: nextNewYearsDay.add(const Duration(hours: 1)),
    );
  }

  static String _weekdayCode(DateTime date) {
    const codes = <int, String>{
      DateTime.monday: 'MO',
      DateTime.tuesday: 'TU',
      DateTime.wednesday: 'WE',
      DateTime.thursday: 'TH',
      DateTime.friday: 'FR',
      DateTime.saturday: 'SA',
      DateTime.sunday: 'SU',
    };
    return codes[date.weekday]!;
  }

  /// 여러 시나리오가 공통으로 쓰는 기본 목록 픽스처.
  static List<EventModel> defaultSet() => <EventModel>[
        simple(),
        critical(id: 'e2e-event-critical-2', daysFromNow: 2),
        recurringWeekly(),
        nearHoliday(),
      ];
}
