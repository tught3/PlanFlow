class KoreanClockTime {
  const KoreanClockTime({
    required this.hour,
    required this.minute,
    this.isEndOfDay = false,
  });

  final int hour;
  final int minute;

  /// Midnight and 12 at night or in the evening belong to the following day.
  final bool isEndOfDay;
}

KoreanClockTime? resolveKoreanClockTime({
  required String? period,
  required int? hour,
  required int? minute,
  required bool unmarkedPmDefault,
}) {
  if (hour == null ||
      hour < 0 ||
      hour > 23 ||
      minute == null ||
      minute < 0 ||
      minute > 59) {
    return null;
  }

  final isEndOfDay =
      period == '자정' || (hour == 12 && (period == '밤' || period == '저녁'));
  final resolvedHour = switch (period) {
    '오전' || '아침' || '새벽' || '밤' || '저녁' when hour == 12 => 0,
    '낮' || '점심' when hour >= 1 && hour <= 6 => hour + 12,
    '오후' || '저녁' when hour >= 1 && hour <= 11 => hour + 12,
    '밤' when hour >= 6 && hour <= 11 => hour + 12,
    null when unmarkedPmDefault && hour >= 1 && hour <= 11 => hour + 12,
    _ => hour,
  };
  return KoreanClockTime(
    hour: resolvedHour,
    minute: minute,
    isEndOfDay: isEndOfDay,
  );
}

typedef KoreanClockTimeParts = ({
  String? period,
  int? hour,
  int? minute,
  bool hasExplicitMinute,
});

const _koreanNumber = r'(?:(?:열|스물)\s*(?:하나|둘|셋|넷|한|두|세|네)|'
    r'다섯|여섯|일곱|여덟|아홉|하나|둘|셋|넷|한|두|세|네|열|스물|'
    r'[영공일이삼사오육륙칠팔구십](?:\s*[일이삼사오육륙칠팔구십]){0,2})';

const _calendarDateQualifier = r'(?:오늘|내일\s*모레|내일|모레|글피|'
    r'(?:(?:이번|다음|다다음)\s*주\s*)?[월화수목금토일]요일|'
    r'(?:\d{4}\s*년\s*)?\d{1,2}\s*월\s*\d{1,2}\s*일|'
    r'\d{1,2}\s*일(?!\s*(?:뒤|후|전|앞)))';

final _calendarDateCue = RegExp(
  r'(?<![가-힣0-9])'
  '$_calendarDateQualifier'
  r'(?=$|\s|자정|정오|에|로|으로)',
);

bool hasKoreanCalendarDateCue(String text) => _calendarDateCue.hasMatch(text);

const _clockPeriod = r'오전|오후|아침|낮|점심|저녁|밤|새벽';
const _clockPatternSource =
    '(?<![0-9])(?:($_clockPeriod)'
    r'\s*|(?<![가-힣])|(?=[0-9]))'
    '([0-9]+|$_koreanNumber)'
    r'\s*시(?!간)'
    '(?:\\s*([0-9]+|$_koreanNumber)\\s*분'
    // Allow ordinary endings (반이야, 반인데, 반도), and exclude words such as 반려.
    r'|\s*(반)(?!려|대|드|응|찬|말|복|장|죽|지|품|납|영|면|짝|상|환|차|나|바|팔|성)'
    r'|\s*([0-9]+)(?![0-9]|\s*[시일월년주]))?'
    // A known calendar date can join a fixed time even without a space.
    r'|(?<![가-힣0-9])(?:'
    '$_calendarDateQualifier'
    r'\s*)?(자정|정오)';

const _clockLink = r'(?:이나|나|또는|아니면|혹은|이랑|랑|하고|와|과)';
const _clockEnding = r'$|[^가-힣]|에|으로|로|부터|까지|쯤|경|이나(?=$|\s)|나(?=$|\s)';
const _displayMidnight = r'(?<![\d:])24:00(?![\d:])';
final koreanMidnightDisplayPattern = RegExp(_displayMidnight);
final _colonClock = RegExp(r'(?<![\d:])\d{1,2}:\d{2}(?![\d:])');
final _compactClock = RegExp(r'(?<![\d:])(\d{1,2})(\d{2})(?![\d:])');
final _clockPeriodAtEnd = RegExp('(?:$_clockPeriod)\\s*\$');
// The final lookahead applies to the fixed-time branch (자정 or 정오).
// The edit pattern also accepts conjunctions there and has a separate 24:00 branch.
final _clockPattern = RegExp('$_clockPatternSource(?=$_clockEnding)');
final _editClockPattern = RegExp(
    '$_clockPatternSource(?=$_clockEnding|$_clockLink)|$_displayMidnight');

// An unmarked hour written in Korean needs a word boundary or a time particle.
// Otherwise words such as "오시는", "한시라도", and "세시풍속" look like hours.
final _unmarkedKoreanHourEnding =
    RegExp('$_clockEnding|정도|(?:엔|이|가|요)(?![가-힣])');
final _editClockLinkEnding = RegExp(_clockLink);
const _editModifier = r'(?:좀|조금|잠시|잠깐|꼭|다시|그냥|바로|제발|한\s*번)';
final _editDestinationEnding = RegExp(
  r'\s*(?:으로|로|에)?'
  '(?:\\s*$_editModifier)*'
  r'\s*'
  r'(?:변경|바꿔|바꾸고|수정|옮겨|이동|미뤄|밀어|연기|앞당겨|늦춰|당겨|고쳐|편집|맞춰|조정)',
);
final _startTimeFieldBeforeClock = RegExp(r'(?:^|\s)시작\s*시간\s*(?:을|를)?\s*$');
final _startTimeRequestEnding = RegExp(r'^\s*(?:으로|로)\s*해\s*(?:주세요|줘)\s*$');
final _implicitDestinationEnding = RegExp(
  r'^\s*(?:으로|로|에)'
  '(?:\\s*$_editModifier)*'
  r'\s*$',
);
final _dateBeforeClock = RegExp(
  r'(?<![가-힣0-9])(?:'
  '$_calendarDateQualifier'
  r'|(?:하루|이틀|삼일|사흘|나흘|닷새|엿새|이레|여드레|아흐레|열흘|\d+\s*일)\s*(?:뒤|후|전|앞)'
  r'|(?:일주일|한\s*주(?:일)?|\d+\s*주(?:일)?|한\s*달|\d+\s*(?:개월|달|월))\s*(?:뒤|후))(?:에|으로|로)?\s*$',
);

bool _hasExplicitClockEditEnding(String text, int end, String prefix) {
  return _editDestinationEnding.matchAsPrefix(text, end) != null ||
      (_startTimeFieldBeforeClock.hasMatch(prefix) &&
          _startTimeRequestEnding.hasMatch(text.substring(end)));
}

List<int> _clockEditDestinationStarts(String text,
    {bool allowImplicit = false}) {
  final candidates = <int>[];
  for (final match in _validClockMatches(text, _editClockPattern)) {
    final prefix = text.substring(0, match.start);
    final dateMatch = _dateBeforeClock.firstMatch(prefix);
    final start = dateMatch?.start ?? match.start;
    final explicit = _hasExplicitClockEditEnding(text, match.end, prefix);
    final implicit = allowImplicit &&
        text.substring(0, start).trim().isEmpty &&
        _implicitDestinationEnding.hasMatch(text.substring(match.end));
    if (explicit || implicit) candidates.add(start);
  }
  return candidates;
}

/// Returns the proven destination, including an immediately preceding date.
String? koreanClockEditDestinationText(String text,
    {bool allowImplicit = false}) {
  final starts =
      _clockEditDestinationStarts(text, allowImplicit: allowImplicit);
  if (starts.length != 1) return null;
  final destination = text.substring(starts.single);
  return koreanClockTimeParts(destination).length == 1 ? destination : null;
}

/// Identifies a time lookup with no title in the remainder of the source.
bool isGenericKoreanClockEditSource(String text) {
  final matches = _validClockMatches(text, _editClockPattern).toList();
  if (matches.length != 1) return false;
  final clock = matches.single;
  final prefix = text.substring(0, clock.start).trim();
  final date = _dateBeforeClock.firstMatch(prefix);
  if (prefix.isNotEmpty && date?.start != 0) return false;
  return RegExp(
    r'^\s*(?:에|의|쯤|경)?\s*(?:일정|약속|스케줄)?'
    r'(?:을|를|은|는|이|가)?\s*$',
  ).hasMatch(text.substring(clock.end));
}

/// Checks syntax and then the requested clock value before a date-only
/// fallback can apply part of an edit. 24:00 is a display reference only.
bool hasInvalidKoreanClockEditDestination(
  String text, {
  String? routedChangeText,
  bool allowImplicit = false,
}) {
  // The clock parser cannot apply colon times as destinations. Detect them
  // only with an edit ending so display 24:00 remains a source reference.
  for (final match in _colonClock.allMatches(text)) {
    if (_hasExplicitClockEditEnding(
        text, match.end, text.substring(0, match.start))) {
      return true;
    }
  }
  // Voice input can strip the colon. For an out-of-range compact clock,
  // require a date before the optional period and an edit verb after it.
  for (final match in _compactClock.allMatches(text)) {
    final hour = int.parse(match.group(1)!);
    final minute = int.parse(match.group(2)!);
    if ((hour < 24 && minute < 60) ||
        _editDestinationEnding.matchAsPrefix(text, match.end) == null) {
      continue;
    }
    final prefix = text.substring(0, match.start);
    final period = _clockPeriodAtEnd.firstMatch(prefix);
    final datePrefix = period == null ? prefix : prefix.substring(0, period.start);
    if (_dateBeforeClock.hasMatch(datePrefix)) return true;
  }
  final starts =
      _clockEditDestinationStarts(text, allowImplicit: allowImplicit);
  final destination =
      starts.length == 1 ? text.substring(starts.single) : routedChangeText;
  if (destination == null) return false;
  if (koreanMidnightDisplayPattern.hasMatch(destination)) return true;
  return koreanClockTimeParts(destination).any(
    (parts) =>
        resolveKoreanClockTime(
          period: parts.period,
          hour: parts.hour,
          minute: parts.minute,
          unmarkedPmDefault: false,
        ) ==
        null,
  );
}

final _editAlternativeBetween = RegExp(
  r'^\s*(?:(?:에|으로|로)\s*)?(?:[,，]\s*)?'
  '$_clockLink(?:\\s*$_editModifier)*',
);

bool hasAmbiguousKoreanClockEditDestination(String text,
    {bool allowImplicit = false}) {
  bool isAlternative(String between, {bool allowDate = false}) {
    final link = _editAlternativeBetween.firstMatch(between);
    if (link == null) return false;
    final remaining = between.substring(link.end).trim();
    if (remaining.isEmpty) return true;
    if (!allowDate) return false;
    final date = _dateBeforeClock.firstMatch(remaining);
    return date != null && date.start == 0;
  }

  final clocks =
      _validClockMatches(text, _editClockPattern).toList(growable: false);
  for (var i = 1; i < clocks.length; i++) {
    final between = text.substring(clocks[i - 1].end, clocks[i].start);
    if (isAlternative(between, allowDate: true)) return true;
  }
  final dateCandidates = RegExp(
    r'(?<![가-힣0-9])(?:'
    r'(?:하루|이틀|삼일|사흘|나흘|닷새|엿새|이레|여드레|아흐레|열흘|\d+\s*일|일주일|한\s*주(?:일)?|\d+\s*주(?:일)?|한\s*달|\d+\s*(?:개월|달|월))\s*(?:뒤|후|전|앞)'
    '|$_calendarDateQualifier'
    r')(?=$|[^가-힣0-9]|에|으로|로|자정|정오|'
    '$_clockLink)',
  ).allMatches(text).toList(growable: false);
  for (var i = 1; i < dateCandidates.length; i++) {
    final between =
        text.substring(dateCandidates[i - 1].end, dateCandidates[i].start);
    if (isAlternative(between)) return true;
  }
  final starts =
      _clockEditDestinationStarts(text, allowImplicit: allowImplicit);
  return starts.length > 1 ||
      (starts.length == 1 &&
          koreanClockTimeParts(text.substring(starts.single)).length > 1);
}

/// Explicit day shifts are relative to the event being edited.
int? koreanExplicitRelativeDayOffset(String text) {
  final matches = RegExp(
    r'(?<![가-힣0-9])(하루|이틀|삼일|사흘|나흘|닷새|엿새|이레|여드레|아흐레|열흘|\d+\s*일)\s*(뒤|후|전|앞)',
  ).allMatches(text).toList(growable: false);
  if (matches.length != 1) return null;
  final value = matches.single.group(1)!;
  final days = switch (value) {
    '하루' => 1,
    '이틀' => 2,
    '삼일' => 3,
    '사흘' => 3,
    '나흘' => 4,
    '닷새' => 5,
    '엿새' => 6,
    '이레' => 7,
    '여드레' => 8,
    '아흐레' => 9,
    '열흘' => 10,
    _ => int.tryParse(value.replaceAll(RegExp(r'\s*일$'), '')),
  };
  if (days == null) return null;
  return matches.single.group(2) == '전' || matches.single.group(2) == '앞'
      ? -days
      : days;
}

/// Week and month shifts retain the event's day, clamped to the target month.
DateTime? koreanRelativeWeekMonthDate(String text, DateTime reference) {
  final matches = RegExp(
    r'(?<![가-힣0-9])(일주일|한\s*주(?:일)?|\d+\s*주(?:일)?|한\s*달|\d+\s*(?:개월|달|월))\s*(?:뒤|후)',
  ).allMatches(text).toList(growable: false);
  if (matches.length != 1) return null;
  final value = matches.single.group(1)!.replaceAll(RegExp(r'\s+'), '');
  final count =
      int.tryParse(RegExp(r'^\d+').firstMatch(value)?.group(0) ?? '') ?? 1;
  if (value.contains('주')) return reference.add(Duration(days: count * 7));
  final monthStart = DateTime(reference.year, reference.month + count);
  final lastDay = DateTime(monthStart.year, monthStart.month + 1, 0).day;
  return DateTime(
      monthStart.year,
      monthStart.month,
      reference.day < lastDay ? reference.day : lastDay,
      reference.hour,
      reference.minute);
}

String koreanClockEditTargetText(String text, {String? routedTargetText}) {
  final starts = _clockEditDestinationStarts(text);
  return starts.length != 1
      ? (routedTargetText ?? text)
      : text.substring(0, starts.single).trimRight();
}

Iterable<RegExpMatch> _validClockMatches(String text, RegExp pattern) sync* {
  for (final match in pattern.allMatches(text)) {
    final hourText = match.group(2);
    if (hourText != null &&
        match.group(1) == null &&
        match.group(3) == null &&
        match.group(4) == null &&
        match.group(5) == null &&
        int.tryParse(hourText) == null &&
        (match.group(0) == '일시' ||
            (_unmarkedKoreanHourEnding.matchAsPrefix(text, match.end) == null &&
                (pattern != _editClockPattern ||
                    _editClockLinkEnding.matchAsPrefix(text, match.end) ==
                        null)))) {
      // "일시" is a common noun. A period or minutes can disambiguate it.
      continue;
    }
    yield match;
  }
}

Iterable<KoreanClockTimeParts> koreanClockTimeParts(String text) sync* {
  for (final match in _validClockMatches(text, _clockPattern)) {
    final fixedTime = match.group(6);
    if (fixedTime != null) {
      yield (
        period: fixedTime,
        hour: fixedTime == '자정' ? 0 : 12,
        minute: 0,
        hasExplicitMinute: false,
      );
      continue;
    }
    final minuteText = match.group(3) ?? match.group(5);
    final hasHalfHour = match.group(4) != null;
    yield (
      period: match.group(1),
      hour: parseKoreanClockNumber(match.group(2)!),
      minute: hasHalfHour
          ? 30
          : minuteText == null
              ? 0
              : parseKoreanClockNumber(minuteText),
      hasExplicitMinute: hasHalfHour || minuteText != null,
    );
  }
}

int? parseKoreanClockNumber(String? rawText) {
  if (rawText == null) {
    return null;
  }
  final text = rawText
      .replaceAll(RegExp(r'\s+'), '')
      .replaceFirst(RegExp(r'분$'), '')
      .trim();
  if (text.isEmpty) {
    return null;
  }
  final numeric = int.tryParse(text);
  if (numeric != null) {
    return numeric;
  }

  const nativeNumbers = <String, int>{
    '영': 0,
    '공': 0,
    '한': 1,
    '하나': 1,
    '한시': 1,
    '두': 2,
    '둘': 2,
    '세': 3,
    '셋': 3,
    '네': 4,
    '넷': 4,
    '다섯': 5,
    '여섯': 6,
    '일곱': 7,
    '여덟': 8,
    '아홉': 9,
    '열': 10,
    '열한': 11,
    '열하나': 11,
    '열두': 12,
    '열둘': 12,
    '스물': 20,
    '스물한': 21,
    '스물하나': 21,
    '스물두': 22,
    '스물둘': 22,
    '스물세': 23,
    '스물셋': 23,
    '스물네': 24,
    '스물넷': 24,
    '반': 30,
  };
  final native = nativeNumbers[text];
  if (native != null) {
    return native;
  }

  const sinoDigits = <String, int>{
    '일': 1,
    '이': 2,
    '삼': 3,
    '사': 4,
    '오': 5,
    '육': 6,
    '륙': 6,
    '칠': 7,
    '팔': 8,
    '구': 9,
  };
  if (text == '십') {
    return 10;
  }
  final tenMatch =
      RegExp(r'^(?:(일|이|삼|사|오|육|륙|칠|팔|구)?십)?(일|이|삼|사|오|육|륙|칠|팔|구)?$')
          .firstMatch(text);
  if (tenMatch != null && tenMatch.group(0)!.isNotEmpty) {
    final tens = tenMatch.group(1);
    final ones = tenMatch.group(2);
    var value = text.contains('십') ? (sinoDigits[tens] ?? 1) * 10 : 0;
    value += sinoDigits[ones] ?? 0;
    return value == 0 ? null : value;
  }
  return null;
}
