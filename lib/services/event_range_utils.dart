DateTime? shiftEventEndWhenStartChanges({
  required DateTime previousStart,
  required DateTime newStart,
  required DateTime? currentEnd,
  required bool endEditedByUser,
}) {
  if (currentEnd == null || endEditedByUser) {
    return currentEnd;
  }
  final delta = newStart.difference(previousStart);
  return currentEnd.add(delta);
}
