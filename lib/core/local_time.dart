DateTime planflowLocal(DateTime value) => value.toLocal();

DateTime planflowLocalDay(DateTime value) {
  final local = value.toLocal();
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
  final localStart = startAt.toLocal();
  final localEnd = (endAt ?? startAt).toLocal();
  return localStart.isBefore(dayEnd) && !localEnd.isBefore(dayStart);
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
