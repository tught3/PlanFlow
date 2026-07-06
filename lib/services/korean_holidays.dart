class KoreanHolidays {
  KoreanHolidays._();

  /// (month, day) → 공휴일명
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

  /// 주어진 날짜가 양력 고정일 공휴일이면 true.
  static bool isHoliday(DateTime date) {
    return _fixed.containsKey((date.month, date.day));
  }

  /// 주어진 날짜의 공휴일명, 아니면 null.
  static String? holidayName(DateTime date) {
    return _fixed[(date.month, date.day)];
  }

  /// 주어진 날짜가 주말(토/일)인 경우를 포함해
  /// 공휴일이면 true.
  ///
  /// NOTE: 음력 공휴일(설날·추석·부처님오신날)과
  /// 대체공휴일은 별도 계산이 필요하므로 여기서 제외됨.
  /// 이벤트 제목 키워드 매칭(_holidayTitleKeywords)이
  /// Naver/기기 캘린더 임포트 건을 보완함.
  static bool isHolidayOrWeekend(DateTime date) {
    if (isHoliday(date)) return true;
    if (date.weekday == DateTime.saturday ||
        date.weekday == DateTime.sunday) {
      return true;
    }
    return false;
  }
}
