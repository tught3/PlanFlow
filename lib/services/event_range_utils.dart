DateTime? shiftEventEndWhenStartChanges({
  required DateTime previousStart,
  required DateTime newStart,
  required DateTime? currentEnd,
  required bool endEditedByUser,
}) {
  if (endEditedByUser) {
    return currentEnd;
  }
  // An ordinary start-time edit resets the default event length to one hour.
  // Do not carry a stale end date (or a missing/invalid end) into the new range.
  if (newStart == previousStart) {
    return currentEnd;
  }
  return newStart.add(const Duration(hours: 1));
}

/// Returns true when a raw utterance expresses an explicit end time, time
/// range, duration, all-day or overnight-stay intent. Start-only auto-apply
/// must fail closed on these so the edit screen handles the user's end.
/// Relative offsets ("한 시간 뒤로 미뤄", "30분 늦춰") are NOT end cues.
bool utteranceHasExplicitEndOrDurationCue(String? text) {
  if (text == null) return false;
  final t = text.replaceAll(RegExp(r'\s+'), '');
  if (t.isEmpty) return false;
  return RegExp(r'부터.*까지|까지|[~～–]|시-\d|분-\d').hasMatch(t) ||
      RegExp(r'종료|끝나|끝내|끝시간|끝으로|마감|마치|마쳐').hasMatch(t) ||
      RegExp(r'동안|길이|소요|시간짜리|분짜리|시간으로').hasMatch(t) ||
      RegExp(r'종일|온종일|\d+박|[일이삼사오육칠팔구십]박').hasMatch(t);
}
