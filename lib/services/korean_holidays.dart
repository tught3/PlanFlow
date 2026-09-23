/// Korean official days off as published by the Korea Astronomy and Space
/// Science Institute (KASI) special-days API.
///
/// This class deliberately does not calculate holidays. A calculated or
/// hard-coded date can be useful as a hint, but it is not an authoritative
/// public holiday declaration. Until KASI data for a year has been loaded,
/// that year has no known official days off (fail-closed).
class KoreanHolidays {
  KoreanHolidays._();

  /// KASI data keyed by year. An empty map is meaningful: it means a valid
  /// KASI response was received and that response contained no day-off rows.
  static final Map<int, Map<(int, int), String>> _liveData = {};

  /// Applies a parsed KASI response. The empty map is intentionally stored
  /// instead of being treated as "not loaded", so a valid empty response
  /// cannot fall back to a guessed calendar.
  static void applyLiveData(int year, Map<(int, int), String> dayOff) {
    _liveData[year] = Map.unmodifiable(dayOff);
  }

  /// Provider titles equivalent to the KASI title confirmed on [date].
  /// No date is considered a holiday unless KASI supplied that date first.
  static Set<String> holidayTitleAliases(DateTime date) {
    final name = holidayName(date);
    if (name == null) return const {};

    final aliases = <String>{name};
    if (name.startsWith('대체공휴일')) {
      aliases.add('대체공휴일');
    }
    if (name == '성탄절' || name == '기독탄신일' || name == '크리스마스') {
      aliases.addAll(const {'성탄절', '기독탄신일', '크리스마스'});
    }
    return aliases;
  }

  static Map<(int, int), String> _forYear(int year) {
    return _liveData[year] ?? const <(int, int), String>{};
  }

  /// True only when KASI has confirmed this exact date as a day off.
  static bool isDayOff(DateTime date) {
    return _forYear(date.year).containsKey((date.month, date.day));
  }

  /// Backwards-compatible name for [isDayOff].
  static bool isHoliday(DateTime date) => isDayOff(date);

  /// Returns the KASI-supplied title, or null when KASI has not confirmed the
  /// date (including when the API/cache is unavailable).
  static String? holidayName(DateTime date) {
    return _forYear(date.year)[(date.month, date.day)];
  }

  /// KASI holiday or ordinary weekend.
  static bool isHolidayOrWeekend(DateTime date) {
    return isHoliday(date) ||
        date.weekday == DateTime.saturday ||
        date.weekday == DateTime.sunday;
  }
}
