class KoreanHolidays {
  KoreanHolidays._();

  /// 양력 고정일 공휴일: (month, day) → 이름
  static const Map<(int, int), String> _fixed = {
    (1, 1): '신정',
    (3, 1): '삼일절',
    (5, 5): '어린이날',
    (6, 6): '현충일',
    (7, 17): '제헌절',
    (8, 15): '광복절',
    (10, 3): '개천절',
    (10, 9): '한글날',
    (12, 25): '성탄절',
  };

  /// 음력 기반 공휴일 (연도별 양력 환산 lookup).
  /// 설날·추석은 전날/당일/다음날(3일) 포함.
  static Map<(int, int), String> _lunarForYear(int year) {
    switch (year) {
      case 2026:
        return {
          (2, 16): '설날연휴',
          (2, 17): '설날',
          (2, 18): '설날연휴',
          (5, 24): '부처님오신날',
          (9, 24): '추석연휴',
          (9, 25): '추석',
          (9, 26): '추석연휴',
        };
      case 2027:
        return {
          (2, 6): '설날연휴',
          (2, 7): '설날',
          (2, 8): '설날연휴',
          (5, 13): '부처님오신날',
          (9, 14): '추석연휴',
          (9, 15): '추석',
          (9, 16): '추석연휴',
        };
      case 2028:
        return {
          (1, 26): '설날연휴',
          (1, 27): '설날',
          (1, 28): '설날연휴',
          (5, 2): '부처님오신날',
          (10, 2): '추석연휴',
          (10, 3): '추석',
          (10, 4): '추석연휴',
        };
      case 2029:
        return {
          (2, 12): '설날연휴',
          (2, 13): '설날',
          (2, 14): '설날연휴',
          (5, 20): '부처님오신날',
          (9, 21): '추석연휴',
          (9, 22): '추석',
          (9, 23): '추석연휴',
        };
      case 2030:
        return {
          (2, 2): '설날연휴',
          (2, 3): '설날',
          (2, 4): '설날연휴',
          (5, 9): '부처님오신날',
          (9, 11): '추석연휴',
          (9, 12): '추석',
          (9, 13): '추석연휴',
        };
      case 2031:
        return {
          (1, 22): '설날연휴',
          (1, 23): '설날',
          (1, 24): '설날연휴',
          (5, 28): '부처님오신날',
          (9, 30): '추석연휴',
          (10, 1): '추석',
          (10, 2): '추석연휴',
        };
      case 2032:
        return {
          (2, 10): '설날연휴',
          (2, 11): '설날',
          (2, 12): '설날연휴',
          (5, 16): '부처님오신날',
          (9, 18): '추석연휴',
          (9, 19): '추석',
          (9, 20): '추석연휴',
        };
      case 2033:
        return {
          (1, 30): '설날연휴',
          (1, 31): '설날',
          (2, 1): '설날연휴',
          (5, 6): '부처님오신날',
          (9, 7): '추석연휴',
          (9, 8): '추석',
          (9, 9): '추석연휴',
        };
      case 2034:
        return {
          (2, 18): '설날연휴',
          (2, 19): '설날',
          (2, 20): '설날연휴',
          (5, 25): '부처님오신날',
          (9, 26): '추석연휴',
          (9, 27): '추석',
          (9, 28): '추석연휴',
        };
      case 2035:
        return {
          (2, 7): '설날연휴',
          (2, 8): '설날',
          (2, 9): '설날연휴',
          (5, 15): '부처님오신날',
          (9, 15): '추석연휴',
          (9, 16): '추석',
          (9, 17): '추석연휴',
        };
      default:
        return const <(int, int), String>{};
    }
  }

  /// 대체공휴일 대상 + 예외 발생 조건.
  ///
  /// 규칙 (2021~):
  /// - 설날·추석 연휴(3일) 중 1일이라도 일요일/공휴일이면
  ///   → 연휴 종료 후 첫 비공휴일 평일
  /// - 어린이날이 토/일이면 → 다음 첫 평일
  /// - 삼일절·광복절·개천절·한글날·부처님오신날이 일요일이면
  ///   → 다음 첫 평일
  static Set<(int, int)> _substituteDays(int year) {
    final allDays = <(int, int), String>{};
    allDays.addAll(_fixed);
    allDays.addAll(_lunarForYear(year));

    final subs = <(int, int)>{};

    /// 3일 연휴(설날·추석) 검사: 셋 중 하나가 일요일이면 대체 추가
    for (final prefix in ['설날', '추석']) {
      final periodKeys = allDays.entries
          .where((e) => e.value.startsWith(prefix))
          .map((e) => e.key)
          .toList()
        ..sort((a, b) {
          if (a.$1 != b.$1) return a.$1.compareTo(b.$1);
          return a.$2.compareTo(b.$2);
        });
      if (periodKeys.length != 3) continue;
      final overlapsSunday = periodKeys.any((k) {
        final d = DateTime(year, k.$1, k.$2);
        return d.weekday == DateTime.sunday;
      });
      if (!overlapsSunday) continue;
      var candidate = _nextWeekday(year, periodKeys.last.$1, periodKeys.last.$2);
      while (allDays.containsKey(candidate) || subs.contains(candidate)) {
        candidate = _nextWeekday(year, candidate.$1, candidate.$2);
      }
      subs.add(candidate);
    }

    /// 단일 공휴일 검사
    final singleHolidays = <(int, int), String>{
      (3, 1): '삼일절',
      (5, 5): '어린이날',
      (6, 6): '현충일',
      (8, 15): '광복절',
      (10, 3): '개천절',
      (10, 9): '한글날',
    };
    final lunarKeys = _lunarForYear(year).entries
        .where((e) => e.value == '부처님오신날')
        .map((e) => e.key)
        .toList();
    if (lunarKeys.isNotEmpty) {
      singleHolidays[lunarKeys.first] = '부처님오신날';
    }

    for (final entry in singleHolidays.entries) {
      final (m, d) = entry.key;
      final name = entry.value;
      final date = DateTime(year, m, d);
      final isWeekend = name == '어린이날'
          ? (date.weekday == DateTime.saturday ||
              date.weekday == DateTime.sunday)
          : date.weekday == DateTime.sunday;
      if (!isWeekend) continue;
      var candidate = _nextWeekday(year, m, d);
      while (allDays.containsKey(candidate) || subs.contains(candidate)) {
        candidate = _nextWeekday(year, candidate.$1, candidate.$2);
      }
      subs.add(candidate);
    }

    return subs;
  }

  /// date(m,d) 다음 첫 평일
  static (int, int) _nextWeekday(int year, int month, int day) {
    var m = month;
    var d = day + 1;
    final daysInMonth = DateTime(year, m + 1, 0).day;
    if (d > daysInMonth) {
      d = 1;
      m += 1;
      if (m > 12) {
        m = 1;
      }
    }
    var dt = DateTime(year, m, d);
    while (dt.weekday == DateTime.saturday ||
        dt.weekday == DateTime.sunday) {
      d += 1;
      if (d > DateTime(year, m + 1, 0).day) {
        d = 1;
        m += 1;
        if (m > 12) {
          m = 1;
        }
      }
      dt = DateTime(year, m, d);
    }
    return (m, d);
  }

  /// 모든 공휴일(고정일 + 음력 + 대체)을 한 Map으로 반환.
  static Map<(int, int), String> _allForYear(int year) {
    final result = <(int, int), String>{};
    result.addAll(_fixed);
    result.addAll(_lunarForYear(year));
    for (final key in _substituteDays(year)) {
      result[key] = '대체공휴일';
    }
    return result;
  }

  /// 주어진 날짜가 한국 공휴일이면 true.
  static bool isHoliday(DateTime date) {
    return _allForYear(date.year).containsKey((date.month, date.day));
  }

  /// 주어진 날짜의 공휴일명, 아니면 null.
  static String? holidayName(DateTime date) {
    return _allForYear(date.year)[(date.month, date.day)];
  }

  /// 주어진 날짜가 공휴일이거나 주말(토/일)이면 true.
  static bool isHolidayOrWeekend(DateTime date) {
    if (isHoliday(date)) return true;
    if (date.weekday == DateTime.saturday ||
        date.weekday == DateTime.sunday) {
      return true;
    }
    return false;
  }
}
