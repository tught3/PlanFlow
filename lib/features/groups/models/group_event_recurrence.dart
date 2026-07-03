import '../../../core/local_time.dart';
import 'group_event_model.dart';

/// 그룹 일정 반복(recurrence) 전개 유틸.
///
/// `group_events`는 `recurrence_type`(none/daily/weekly/monthly)과 선택적
/// `recurrence_until`을 갖지만, DB에는 시리즈의 원본 1건만 저장된다.
/// 화면/오버레이는 이 유틸로 개별 발생(occurrence)을 만들어 표시한다.
///
/// MVP 범위: 단일일(하루 안에 끝나는) 반복 일정 기준으로 전개한다.
/// 다중일에 걸치는 반복은 원본 시작일 기준 발생만 처리한다.

const int _maxOccurrenceIterations = 400;

/// [event]가 로컬 기준 [day]에 발생하는지 여부.
/// 목록 화면의 오늘/이번주 버킷팅에 사용한다.
bool groupEventOccursOnLocalDay(GroupEventModel event, DateTime day) {
  final target = DateTime(day.year, day.month, day.day);
  if (!_isRecurring(event)) {
    return planflowEventIntersectsLocalDay(
      startAt: event.startAt,
      endAt: event.endAt,
      day: target,
    );
  }

  final startDay = planflowLocalDay(event.startAt);
  if (target.isBefore(startDay)) {
    return false;
  }
  final until = event.recurrenceUntil;
  if (until != null && target.isAfter(planflowLocalDay(until))) {
    return false;
  }

  return switch (event.recurrenceType) {
    'daily' => true,
    'weekly' => target.weekday == startDay.weekday,
    'monthly' => target.day == startDay.day,
    _ => planflowEventIntersectsLocalDay(
        startAt: event.startAt,
        endAt: event.endAt,
        day: target,
      ),
  };
}

/// [event]를 UTC 구간 [rangeStartUtc, rangeEndUtc) 안의 개별 발생들로 전개한다.
/// 비반복 일정은 구간과 겹치면 자기 자신 1건, 아니면 빈 리스트.
/// 반복 일정은 원본의 로컬 시각·길이를 유지한 복제본을 발생일마다 만든다.
List<GroupEventModel> expandGroupEventOccurrences(
  GroupEventModel event,
  DateTime rangeStartUtc,
  DateTime rangeEndUtc,
) {
  final rangeStart = rangeStartUtc.toUtc();
  final rangeEnd = rangeEndUtc.toUtc();

  if (!_isRecurring(event)) {
    if (event.startAt.toUtc().isBefore(rangeEnd) &&
        event.endAt.toUtc().isAfter(rangeStart)) {
      return <GroupEventModel>[event];
    }
    return const <GroupEventModel>[];
  }

  final duration = event.endAt.difference(event.startAt);
  final startLocal = planflowLocal(event.startAt);
  final startDay = DateTime(startLocal.year, startLocal.month, startLocal.day);
  final untilDay =
      event.recurrenceUntil != null ? planflowLocalDay(event.recurrenceUntil!) : null;
  final rangeStartDay = planflowLocalDay(rangeStart);
  final rangeEndDay = planflowLocalDay(rangeEnd);

  final occurrences = <GroupEventModel>[];
  var iterations = 0;
  for (DateTime? occDay = _firstOccurrenceDay(
        event.recurrenceType,
        startDay: startDay,
        rangeStartDay: rangeStartDay,
      );
      occDay != null && !occDay.isAfter(rangeEndDay);
      occDay = _nextOccurrenceDay(event.recurrenceType, startDay, occDay)) {
    if (iterations++ > _maxOccurrenceIterations) {
      break;
    }
    if (occDay.isBefore(startDay)) {
      continue;
    }
    if (untilDay != null && occDay.isAfter(untilDay)) {
      break;
    }

    final occStartLocal = DateTime(
      occDay.year,
      occDay.month,
      occDay.day,
      startLocal.hour,
      startLocal.minute,
      startLocal.second,
    );
    final occStartUtc = planflowLocalDateTimeToUtc(occStartLocal);
    final occEndUtc = occStartUtc.add(duration);
    if (occStartUtc.isBefore(rangeEnd) && occEndUtc.isAfter(rangeStart)) {
      occurrences.add(_withSchedule(event, occStartUtc, occEndUtc));
    }
  }
  return occurrences;
}

bool _isRecurring(GroupEventModel event) {
  final type = event.recurrenceType;
  return type == 'daily' || type == 'weekly' || type == 'monthly';
}

DateTime? _firstOccurrenceDay(
  String type, {
  required DateTime startDay,
  required DateTime rangeStartDay,
}) {
  final base = startDay.isAfter(rangeStartDay) ? startDay : rangeStartDay;
  switch (type) {
    case 'daily':
      return base;
    case 'weekly':
      var delta = (startDay.weekday - base.weekday) % 7;
      if (delta < 0) {
        delta += 7;
      }
      return base.add(Duration(days: delta));
    case 'monthly':
      var year = base.year;
      var month = base.month;
      for (var i = 0; i <= _maxOccurrenceIterations; i++) {
        final candidate = _monthlyCandidate(year, month, startDay.day);
        if (candidate != null && !candidate.isBefore(base)) {
          return candidate;
        }
        month += 1;
        if (month > 12) {
          month = 1;
          year += 1;
        }
      }
      return null;
    default:
      return null;
  }
}

DateTime? _nextOccurrenceDay(String type, DateTime startDay, DateTime current) {
  switch (type) {
    case 'daily':
      return current.add(const Duration(days: 1));
    case 'weekly':
      return current.add(const Duration(days: 7));
    case 'monthly':
      var year = current.year;
      var month = current.month + 1;
      if (month > 12) {
        month = 1;
        year += 1;
      }
      for (var i = 0; i <= 24; i++) {
        final candidate = _monthlyCandidate(year, month, startDay.day);
        if (candidate != null) {
          return candidate;
        }
        month += 1;
        if (month > 12) {
          month = 1;
          year += 1;
        }
      }
      return null;
    default:
      return null;
  }
}

/// 해당 연·월에 [day]가 존재하면 그 날짜, 없으면(예: 2월 30일) null.
DateTime? _monthlyCandidate(int year, int month, int day) {
  final lastDay = DateTime(year, month + 1, 0).day;
  if (day > lastDay) {
    return null;
  }
  return DateTime(year, month, day);
}

GroupEventModel _withSchedule(
  GroupEventModel event,
  DateTime startUtc,
  DateTime endUtc,
) {
  return GroupEventModel(
    id: event.id,
    groupId: event.groupId,
    title: event.title,
    description: event.description,
    location: event.location,
    startAt: startUtc,
    endAt: endUtc,
    allDay: event.allDay,
    recurrenceType: event.recurrenceType,
    recurrenceUntil: event.recurrenceUntil,
    createdBy: event.createdBy,
    updatedBy: event.updatedBy,
    cancelledAt: event.cancelledAt,
    cancelledBy: event.cancelledBy,
    status: event.status,
    createdAt: event.createdAt,
    updatedAt: event.updatedAt,
  );
}
