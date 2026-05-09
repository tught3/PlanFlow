const Duration planflowKstOffset = Duration(hours: 9);

DateTime planflowLocal(DateTime value) {
  final utc = value.toUtc();
  final kst = utc.add(planflowKstOffset);
  return DateTime(
    kst.year,
    kst.month,
    kst.day,
    kst.hour,
    kst.minute,
    kst.second,
    kst.millisecond,
    kst.microsecond,
  );
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
  return DateTime.utc(
    seoulTime.year,
    seoulTime.month,
    seoulTime.day,
    seoulTime.hour - 9,
    seoulTime.minute,
    seoulTime.second,
    seoulTime.millisecond,
    seoulTime.microsecond,
  );
}
