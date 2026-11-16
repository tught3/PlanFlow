class KoreanClockTime {
  const KoreanClockTime({
    required this.hour,
    required this.minute,
    this.isEndOfDay = false,
  });

  final int hour;
  final int minute;

  /// Only 12 at night or in the evening belongs to the following day.
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

  final isEndOfDay = hour == 12 && (period == '밤' || period == '저녁');
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

typedef KoreanClockTimeParts = ({String? period, int? hour, int? minute});

const _koreanNumber = r'(?:(?:열|스물)\s*(?:하나|둘|셋|넷|한|두|세|네)|'
    r'다섯|여섯|일곱|여덟|아홉|하나|둘|셋|넷|한|두|세|네|열|스물|'
    r'[영공일이삼사오육륙칠팔구십](?:\s*[일이삼사오육륙칠팔구십]){0,2})';

final _clockPattern = RegExp(
  r'(?<![0-9])(?:(오전|오후|아침|낮|점심|저녁|밤|새벽)\s*|(?<![가-힣])|(?=[0-9]))'
  '([0-9]+|$_koreanNumber)'
  r'\s*시(?!간)'
  '(?:\\s*([0-9]+|$_koreanNumber)\\s*분'
  r'|\s*(반)(?=$|[^가-힣]|에|으로|로|부터|까지|쯤|경)'
  r'|\s*([0-9]+)(?![0-9]|\s*[시일월년주]))?'
  r'|(자정|정오)(?=$|[^가-힣]|에|으로|로|부터|까지|쯤|경)',
);

Iterable<KoreanClockTimeParts> koreanClockTimeParts(String text) sync* {
  for (final match in _clockPattern.allMatches(text)) {
    final fixedTime = match.group(6);
    if (fixedTime != null) {
      yield (period: fixedTime, hour: fixedTime == '자정' ? 0 : 12, minute: 0);
      continue;
    }
    final minuteText = match.group(3) ?? match.group(5);
    yield (
      period: match.group(1),
      hour: parseKoreanClockNumber(match.group(2)),
      minute: match.group(4) != null
          ? 30
          : minuteText == null
              ? 0
              : parseKoreanClockNumber(minuteText),
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
