import 'dart:convert';

import 'notification_route_contract.dart';

/// Versioned payload shared by the Flutter calendar and native widgets.
///
/// The Android renderer remains the source of current behaviour. This contract
/// is additive: an iOS WidgetKit target can consume the same JSON later.
///
/// v2 adds the `month` / `week` projections so the iOS monthly, weekly and
/// vertical widgets can mirror the Android cell-by-cell layout without
/// re-deriving a schedule source natively. All v1 keys are unchanged and the
/// iOS decoder falls back to v1 behaviour when these keys are absent.
class WidgetSchedulePayload {
  const WidgetSchedulePayload({
    required this.schemaVersion,
    required this.generatedAt,
    required this.events,
    required this.dayCounts,
    required this.holidays,
    this.holidayDates = const <String, String>{},
    this.month,
    this.week,
  });

  static const int currentSchemaVersion = 2;

  final int schemaVersion;
  final DateTime generatedAt;
  final List<WidgetScheduleEvent> events;
  final Map<String, int> dayCounts;
  final List<String> holidays;

  /// Date-qualified holiday labels for native widgets. The legacy `holidays`
  /// list remains for backward compatibility with existing consumers.
  final Map<String, String> holidayDates;

  /// Current-month projection (v2, optional). Same truth as the Android
  /// `month_cell_*` keys.
  final WidgetMonthPayload? month;

  /// Current-week projection (v2, optional). Same truth as the Android
  /// `week_day_*` keys.
  final WidgetWeekPayload? week;

  /// Projects the legacy Android raw-event shape into the additive
  /// contract. The legacy keys remain untouched; this is a dual-write helper
  /// for WidgetKit consumers.
  factory WidgetSchedulePayload.fromLegacyRawEvents({
    required List<Map<String, Object?>> rawEvents,
    required DateTime generatedAt,
    Map<String, int> dayCounts = const <String, int>{},
    List<String> holidays = const <String>[],
    Map<String, String> holidayDates = const <String, String>{},
    WidgetMonthPayload? month,
    WidgetWeekPayload? week,
  }) {
    return WidgetSchedulePayload(
      schemaVersion: currentSchemaVersion,
      generatedAt: generatedAt,
      events: rawEvents.map(WidgetScheduleEvent.fromLegacyJson).toList(),
      dayCounts: dayCounts,
      holidays: holidays,
      holidayDates: holidayDates,
      month: month,
      week: week,
    );
  }

  Map<String, Object?> toJson() => {
        'schemaVersion': schemaVersion,
        'generatedAt': generatedAt.toUtc().toIso8601String(),
        'events': events.map((event) => event.toJson()).toList(),
        'dayCounts': dayCounts,
        'holidays': holidays,
        'holidayDates': holidayDates,
        if (month != null) 'month': month!.toJson(),
        if (week != null) 'week': week!.toJson(),
      };

  String encode() => jsonEncode(toJson());

  factory WidgetSchedulePayload.fromJson(Map<String, Object?> json) {
    final version = json['schemaVersion'];
    if (version is! int || version < 1) {
      throw const FormatException('Unsupported widget schedule schema');
    }
    final generatedAt = DateTime.tryParse(json['generatedAt'] as String? ?? '');
    if (generatedAt == null) {
      throw const FormatException('Invalid widget schedule generatedAt');
    }
    final rawEvents = json['events'];
    if (rawEvents is! List) {
      throw const FormatException('Widget schedule events must be a list');
    }
    final rawCounts = json['dayCounts'];
    final counts = <String, int>{};
    if (rawCounts is Map) {
      for (final entry in rawCounts.entries) {
        if (entry.key is String && entry.value is int) {
          counts[entry.key as String] = entry.value as int;
        }
      }
    }
    final rawHolidays = json['holidays'];
    final holidays = rawHolidays is List
        ? rawHolidays.whereType<String>().toList(growable: false)
        : const <String>[];
    final rawHolidayDates = json['holidayDates'];
    final holidayDates = <String, String>{};
    if (rawHolidayDates is Map) {
      for (final entry in rawHolidayDates.entries) {
        if (entry.key is String && entry.value is String) {
          holidayDates[entry.key as String] = entry.value as String;
        }
      }
    }
    final rawMonth = json['month'];
    final month = rawMonth is Map
        ? WidgetMonthPayload.fromJson(Map<String, Object?>.from(rawMonth))
        : null;
    final rawWeek = json['week'];
    final week = rawWeek is Map
        ? WidgetWeekPayload.fromJson(Map<String, Object?>.from(rawWeek))
        : null;
    return WidgetSchedulePayload(
      schemaVersion: version,
      generatedAt: generatedAt,
      events: rawEvents
          .whereType<Map>()
          .map((event) => WidgetScheduleEvent.fromJson(
                Map<String, Object?>.from(event),
              ))
          .toList(growable: false),
      dayCounts: Map.unmodifiable(counts),
      holidays: List.unmodifiable(holidays),
      holidayDates: Map.unmodifiable(holidayDates),
      month: month,
      week: week,
    );
  }

  factory WidgetSchedulePayload.decode(String value) =>
      WidgetSchedulePayload.fromJson(
        Map<String, Object?>.from(jsonDecode(value) as Map),
      );
}

class WidgetScheduleEvent {
  const WidgetScheduleEvent({
    required this.id,
    required this.title,
    required this.start,
    required this.end,
    required this.important,
    required this.continuous,
    required this.recurring,
    required this.team,
    this.strongAlarm = false,
    required this.displayColor,
    required this.route,
    this.segment,
    this.showTitle,
  });

  final String id;
  final String title;
  final DateTime start;
  final DateTime end;
  final bool important;
  final bool continuous;
  final bool recurring;
  final bool team;
  final bool strongAlarm;
  final String displayColor;
  final String route;

  /// 월간 달력 셀 segment 타입: 'single' | 'start' | 'middle' | 'end'.
  /// v2 월간 셀 이벤트에서만 의미가 있다.
  final String? segment;

  /// 월간 달력에서 제목 표시 여부 (start/single=true, middle/end=false).
  final bool? showTitle;

  Map<String, Object?> toJson() => {
        'id': id,
        'title': title,
        'start': start.toUtc().toIso8601String(),
        'end': end.toUtc().toIso8601String(),
        'important': important,
        'continuous': continuous,
        'recurring': recurring,
        'team': team,
        'strongAlarm': strongAlarm,
        'displayColor': displayColor,
        'route': route,
        if (segment != null) 'segment': segment,
        if (showTitle != null) 'showTitle': showTitle,
      };

  factory WidgetScheduleEvent.fromJson(Map<String, Object?> json) {
    String requiredString(String key) {
      final value = json[key];
      if (value is! String || value.isEmpty) {
        throw FormatException('Missing widget event $key');
      }
      return value;
    }

    DateTime requiredDate(String key) {
      final date = DateTime.tryParse(requiredString(key));
      if (date == null) throw FormatException('Invalid widget event $key');
      return date;
    }

    bool flag(String key) => json[key] == true;

    return WidgetScheduleEvent(
      id: requiredString('id'),
      title: requiredString('title'),
      start: requiredDate('start'),
      end: requiredDate('end'),
      important: flag('important'),
      continuous: flag('continuous'),
      recurring: flag('recurring'),
      team: flag('team'),
      strongAlarm: flag('strongAlarm'),
      displayColor: requiredString('displayColor'),
      route: requiredString('route'),
      segment: json['segment'] is String ? json['segment'] as String : null,
      showTitle: json['showTitle'] is bool ? json['showTitle'] as bool : null,
    );
  }

  factory WidgetScheduleEvent.fromLegacyJson(Map<String, Object?> json) {
    String requiredString(String key) {
      final value = json[key];
      if (value is! String || value.isEmpty) {
        throw FormatException('Missing widget event $key');
      }
      return value;
    }

    DateTime requiredDate(String key) {
      final date = DateTime.tryParse(requiredString(key));
      if (date == null) throw FormatException('Invalid widget event $key');
      return date;
    }

    final id = requiredString('id');
    final important = json['is_critical'] == true;
    final recurring = json['is_recurring'] == true;
    final team = json['is_team'] == true;
    final continuous = json['is_multi_day'] == true;
    final displayColor = important
        ? '#633B8E'
        : team
            ? '#7B560B'
            : recurring
                ? '#126E68'
                : continuous
                    ? '#4B6336'
                    : '#435A70';
    return WidgetScheduleEvent(
      id: id,
      title: requiredString('title'),
      start: requiredDate('start_at'),
      end: DateTime.tryParse(json['end_at'] as String? ?? '') ??
          requiredDate('start_at'),
      important: important,
      continuous: continuous,
      recurring: recurring,
      team: team,
      strongAlarm: json['use_strong_alarm'] == true,
      displayColor: displayColor,
      route: NotificationRouteContract.schedule(id).toString(),
    );
  }
}

/// v2 월간 투영. Android `month_cell_*` 키와 동일한 Dart 진실에서 직렬화된다.
class WidgetMonthPayload {
  const WidgetMonthPayload({
    required this.title,
    required this.year,
    required this.month,
    required this.cells,
  });

  final String title;
  final int year;
  final int month;
  final List<WidgetMonthCellPayload> cells;

  Map<String, Object?> toJson() => {
        'title': title,
        'year': year,
        'month': month,
        'cells': cells.map((cell) => cell.toJson()).toList(),
      };

  factory WidgetMonthPayload.fromJson(Map<String, Object?> json) {
    final rawCells = json['cells'];
    return WidgetMonthPayload(
      title: json['title'] is String ? json['title'] as String : '',
      year: json['year'] is int ? json['year'] as int : 0,
      month: json['month'] is int ? json['month'] as int : 0,
      cells: rawCells is List
          ? rawCells
              .whereType<Map>()
              .map((cell) => WidgetMonthCellPayload.fromJson(
                    Map<String, Object?>.from(cell),
                  ))
              .toList(growable: false)
          : const <WidgetMonthCellPayload>[],
    );
  }
}

class WidgetMonthCellPayload {
  const WidgetMonthCellPayload({
    required this.date,
    required this.day,
    required this.inMonth,
    this.holidayName,
    this.isDayOff = false,
    this.overflowCount = 0,
    this.events = const <WidgetScheduleEvent>[],
  });

  /// yyyy-MM-dd (로컬 날짜)
  final String date;
  final int day;
  final bool inMonth;
  final String? holidayName;
  final bool isDayOff;
  final int overflowCount;
  final List<WidgetScheduleEvent> events;

  Map<String, Object?> toJson() => {
        'date': date,
        'day': day,
        'inMonth': inMonth,
        if (holidayName != null) 'holidayName': holidayName,
        'isDayOff': isDayOff,
        'overflowCount': overflowCount,
        'events': events.map((event) => event.toJson()).toList(),
      };

  factory WidgetMonthCellPayload.fromJson(Map<String, Object?> json) {
    final rawEvents = json['events'];
    return WidgetMonthCellPayload(
      date: json['date'] is String ? json['date'] as String : '',
      day: json['day'] is int ? json['day'] as int : 0,
      inMonth: json['inMonth'] == true,
      holidayName:
          json['holidayName'] is String ? json['holidayName'] as String : null,
      isDayOff: json['isDayOff'] == true,
      overflowCount:
          json['overflowCount'] is int ? json['overflowCount'] as int : 0,
      events: rawEvents is List
          ? rawEvents
              .whereType<Map>()
              .map((event) => WidgetScheduleEvent.fromJson(
                    Map<String, Object?>.from(event),
                  ))
              .toList(growable: false)
          : const <WidgetScheduleEvent>[],
    );
  }
}

/// v2 주간 투영. Android `week_day_*` 키와 동일한 Dart 진실에서 직렬화된다.
class WidgetWeekPayload {
  const WidgetWeekPayload({
    required this.title,
    required this.days,
  });

  final String title;
  final List<WidgetWeekDayPayload> days;

  Map<String, Object?> toJson() => {
        'title': title,
        'days': days.map((day) => day.toJson()).toList(),
      };

  factory WidgetWeekPayload.fromJson(Map<String, Object?> json) {
    final rawDays = json['days'];
    return WidgetWeekPayload(
      title: json['title'] is String ? json['title'] as String : '',
      days: rawDays is List
          ? rawDays
              .whereType<Map>()
              .map((day) => WidgetWeekDayPayload.fromJson(
                    Map<String, Object?>.from(day),
                  ))
              .toList(growable: false)
          : const <WidgetWeekDayPayload>[],
    );
  }
}

class WidgetWeekDayPayload {
  const WidgetWeekDayPayload({
    required this.date,
    required this.label,
    this.events = const <WidgetScheduleEvent>[],
    this.overflowCount = 0,
  });

  /// yyyy-MM-dd (로컬 날짜)
  final String date;

  /// 요일 라벨 (예: '월')
  final String label;
  final List<WidgetScheduleEvent> events;
  final int overflowCount;

  Map<String, Object?> toJson() => {
        'date': date,
        'label': label,
        'events': events.map((event) => event.toJson()).toList(),
        'overflowCount': overflowCount,
      };

  factory WidgetWeekDayPayload.fromJson(Map<String, Object?> json) {
    final rawEvents = json['events'];
    return WidgetWeekDayPayload(
      date: json['date'] is String ? json['date'] as String : '',
      label: json['label'] is String ? json['label'] as String : '',
      events: rawEvents is List
          ? rawEvents
              .whereType<Map>()
              .map((event) => WidgetScheduleEvent.fromJson(
                    Map<String, Object?>.from(event),
                  ))
              .toList(growable: false)
          : const <WidgetScheduleEvent>[],
      overflowCount:
          json['overflowCount'] is int ? json['overflowCount'] as int : 0,
    );
  }
}
