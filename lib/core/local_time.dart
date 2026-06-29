import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import 'region_settings.dart';

const Duration planflowKstOffset = Duration(hours: 9);

bool _timeZonesInitialized = false;

void _ensureTimeZonesInitialized() {
  if (_timeZonesInitialized) {
    return;
  }
  tzdata.initializeTimeZones();
  _timeZonesInitialized = true;
}

tz.Location _planflowLocation([String? timeZoneId]) {
  _ensureTimeZonesInitialized();
  final id = timeZoneId ?? PlanFlowRegionController.instance.region.timeZoneId;
  try {
    return tz.getLocation(id);
  } catch (_) {
    return tz.getLocation(PlanFlowRegions.korea.timeZoneId);
  }
}

DateTime planflowLocal(DateTime value) {
  final local = tz.TZDateTime.from(value.toUtc(), _planflowLocation());
  return DateTime(
    local.year,
    local.month,
    local.day,
    local.hour,
    local.minute,
    local.second,
    local.millisecond,
    local.microsecond,
  );
}

DateTime planflowLocalDateTimeToUtc(DateTime localValue) {
  final location = _planflowLocation();
  final zoned = tz.TZDateTime(
    location,
    localValue.year,
    localValue.month,
    localValue.day,
    localValue.hour,
    localValue.minute,
    localValue.second,
    localValue.millisecond,
    localValue.microsecond,
  );
  return zoned.toUtc();
}

DateTime planflowNow() {
  return planflowLocal(DateTime.now().toUtc());
}

DateTime planflowLocalDay(DateTime value) {
  final local = planflowLocal(value);
  return DateTime(local.year, local.month, local.day);
}

bool planflowIsSameLocalDay(DateTime first, DateTime second) {
  final firstDay = planflowLocalDay(first);
  final secondDay = planflowLocalDay(second);
  return firstDay.year == secondDay.year &&
      firstDay.month == secondDay.month &&
      firstDay.day == secondDay.day;
}

bool planflowEventIntersectsLocalDay({
  required DateTime? startAt,
  required DateTime? endAt,
  required DateTime day,
}) {
  if (startAt == null) {
    return false;
  }
  final dayStart = DateTime(day.year, day.month, day.day);
  final dayEnd = dayStart.add(const Duration(days: 1));
  final localStart = planflowLocal(startAt);
  final localEnd = planflowLocal(endAt ?? startAt);
  if (localEnd.isAtSameMomentAs(localStart)) {
    return !localStart.isBefore(dayStart) && localStart.isBefore(dayEnd);
  }
  return localStart.isBefore(dayEnd) && localEnd.isAfter(dayStart);
}

DateTime planflowSeoulDateTimeToUtc(DateTime seoulTime) {
  final location = _planflowLocation(PlanFlowRegions.korea.timeZoneId);
  return tz
      .TZDateTime(
        location,
        seoulTime.year,
        seoulTime.month,
        seoulTime.day,
        seoulTime.hour,
        seoulTime.minute,
        seoulTime.second,
        seoulTime.millisecond,
        seoulTime.microsecond,
      )
      .toUtc();
}
