import '../core/local_time.dart';

class VoiceDateRangeParseResult {
  const VoiceDateRangeParseResult({
    required this.start,
    required this.end,
    required this.label,
  });

  final DateTime start;
  final DateTime end;
  final String label;
}

class VoiceDateRangeParser {
  const VoiceDateRangeParser._();

  static VoiceDateRangeParseResult? parse(
    String rawText, {
    DateTime? now,
  }) {
    final text = rawText.trim();
    if (text.isEmpty) {
      return null;
    }

    final localNow = planflowLocal(now ?? planflowNow());
    final today = DateTime(localNow.year, localNow.month, localNow.day);
    final normalized = text.replaceAll(RegExp(r'\s+'), ' ');
    final compact = normalized.replaceAll(' ', '');

    final absolute = _parseAbsoluteDate(normalized, today.year);
    if (absolute != null) {
      return _singleDay(absolute, '${absolute.month}월 ${absolute.day}일');
    }

    // "7월", "7월 일정", "7월 전체" 등 월 단독 패턴 ("7월 15일"은 위에서 이미 처리됨)
    final monthMatch =
        RegExp(r'(\d{1,2})\s*월(?!\s*\d+\s*일)').firstMatch(compact);
    if (monthMatch != null) {
      final month = int.tryParse(monthMatch.group(1)!);
      if (month != null && month >= 1 && month <= 12) {
        var year = today.year;
        if (month < today.month) year++; // 이미 지난 달 → 내년
        final start = DateTime(year, month, 1);
        final end = DateTime(year, month + 1, 1);
        return VoiceDateRangeParseResult(
          start: start,
          end: end,
          label: '$month월',
        );
      }
    }

    final dayOnly = _parseDayOnlyDate(normalized, today);
    if (dayOnly != null) {
      return _singleDay(dayOnly, '${dayOnly.month}월 ${dayOnly.day}일');
    }

    if (compact.contains('글피')) {
      final start = today.add(const Duration(days: 3));
      return _singleDay(start, '글피');
    }
    // '내일모레'/'내일모래'(STT 오인식)는 2일 뒤. '내일' 단독 검사보다 먼저 둔다.
    if (compact.contains('모레') || compact.contains('내일모래')) {
      final start = today.add(const Duration(days: 2));
      return _singleDay(start, '모레');
    }
    if (compact.contains('내일')) {
      final start = today.add(const Duration(days: 1));
      return _singleDay(start, '내일');
    }
    if (compact.contains('오늘')) {
      return _singleDay(today, '오늘');
    }

    final weekday = _parseWeekdayDate(compact, today);
    if (weekday != null) {
      return weekday;
    }

    if (compact.contains('다음주')) {
      final start = today
          .subtract(Duration(days: today.weekday - 1))
          .add(const Duration(days: 7));
      return VoiceDateRangeParseResult(
        start: start,
        end: start.add(const Duration(days: 7)),
        label: '다음 주',
      );
    }
    if (compact.contains('이번주') || compact.contains('주간')) {
      final start = today.subtract(Duration(days: today.weekday - 1));
      return VoiceDateRangeParseResult(
        start: start,
        end: start.add(const Duration(days: 7)),
        label: '이번 주',
      );
    }

    return null;
  }

  static DateTime? _parseAbsoluteDate(String normalized, int defaultYear) {
    final match = RegExp(
      r'(?:(\d{4})\s*년\s*)?(\d{1,2})\s*월\s*(\d{1,2})\s*일',
    ).firstMatch(normalized);
    if (match == null) {
      return null;
    }
    final year = int.tryParse(match.group(1) ?? '') ?? defaultYear;
    final month = int.tryParse(match.group(2) ?? '');
    final day = int.tryParse(match.group(3) ?? '');
    if (month == null || day == null) {
      return null;
    }
    final start = DateTime(year, month, day);
    if (start.year != year || start.month != month || start.day != day) {
      return null;
    }
    return start;
  }

  static DateTime? _parseDayOnlyDate(String normalized, DateTime today) {
    final match = RegExp(
      r'(^|\s)(\d{1,2})\s*일(?=\s|$)',
    ).firstMatch(normalized);
    if (match == null) {
      return null;
    }
    final day = int.tryParse(match.group(2) ?? '');
    if (day == null) {
      return null;
    }
    final start = DateTime(today.year, today.month, day);
    if (start.year != today.year || start.month != today.month || start.day != day) {
      return null;
    }
    return start;
  }

  static VoiceDateRangeParseResult? _parseWeekdayDate(
    String compact,
    DateTime today,
  ) {
    final match = RegExp(
      r'(?:(이번|다음)주)?([월화수목금토일])요일',
    ).firstMatch(compact);
    if (match == null) {
      return null;
    }
    final modifier = match.group(1);
    if (modifier == null) {
      return null;
    }
    final weekday = _weekdayValue(match.group(2)!);
    if (weekday == null) {
      return null;
    }
    final currentWeekStart = today.subtract(Duration(days: today.weekday - 1));
    final weekStart = modifier == '다음'
        ? currentWeekStart.add(const Duration(days: 7))
        : currentWeekStart;
    final start = weekStart.add(Duration(days: weekday - 1));
    return _singleDay(start, '$modifier 주 ${_weekdayLabel(weekday)}');
  }

  static VoiceDateRangeParseResult _singleDay(DateTime start, String label) {
    return VoiceDateRangeParseResult(
      start: start,
      end: start.add(const Duration(days: 1)),
      label: label,
    );
  }

  static int? _weekdayValue(String value) {
    return switch (value) {
      '월' => DateTime.monday,
      '화' => DateTime.tuesday,
      '수' => DateTime.wednesday,
      '목' => DateTime.thursday,
      '금' => DateTime.friday,
      '토' => DateTime.saturday,
      '일' => DateTime.sunday,
      _ => null,
    };
  }

  static String _weekdayLabel(int value) {
    return switch (value) {
      DateTime.monday => '월요일',
      DateTime.tuesday => '화요일',
      DateTime.wednesday => '수요일',
      DateTime.thursday => '목요일',
      DateTime.friday => '금요일',
      DateTime.saturday => '토요일',
      DateTime.sunday => '일요일',
      _ => '요일',
    };
  }
}
