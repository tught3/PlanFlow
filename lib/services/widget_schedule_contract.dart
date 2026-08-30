import 'dart:convert';

import 'notification_route_contract.dart';

/// Versioned payload shared by the Flutter calendar and native widgets.
///
/// The Android renderer remains the source of current behaviour. This contract
/// is additive: an iOS WidgetKit target can consume the same JSON later.
class WidgetSchedulePayload {
  const WidgetSchedulePayload({
    required this.schemaVersion,
    required this.generatedAt,
    required this.events,
    required this.dayCounts,
    required this.holidays,
    this.holidayDates = const <String, String>{},
  });

  static const int currentSchemaVersion = 1;

  final int schemaVersion;
  final DateTime generatedAt;
  final List<WidgetScheduleEvent> events;
  final Map<String, int> dayCounts;
  final List<String> holidays;

  /// Date-qualified holiday labels for native widgets. The legacy `holidays`
  /// list remains for backward compatibility with existing consumers.
  final Map<String, String> holidayDates;

  /// Projects the legacy Android raw-event shape into the additive v1
  /// contract. The legacy keys remain untouched; this is a dual-write helper
  /// for future WidgetKit consumers.
  factory WidgetSchedulePayload.fromLegacyRawEvents({
    required List<Map<String, Object?>> rawEvents,
    required DateTime generatedAt,
    Map<String, int> dayCounts = const <String, int>{},
    List<String> holidays = const <String>[],
    Map<String, String> holidayDates = const <String, String>{},
  }) {
    return WidgetSchedulePayload(
      schemaVersion: currentSchemaVersion,
      generatedAt: generatedAt,
      events: rawEvents.map(WidgetScheduleEvent.fromLegacyJson).toList(),
      dayCounts: dayCounts,
      holidays: holidays,
      holidayDates: holidayDates,
    );
  }

  Map<String, Object?> toJson() => {
        'schemaVersion': schemaVersion,
        'generatedAt': generatedAt.toUtc().toIso8601String(),
        'events': events.map((event) => event.toJson()).toList(),
        'dayCounts': dayCounts,
        'holidays': holidays,
        'holidayDates': holidayDates,
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
    required this.displayColor,
    required this.route,
  });

  final String id;
  final String title;
  final DateTime start;
  final DateTime end;
  final bool important;
  final bool continuous;
  final bool recurring;
  final bool team;
  final String displayColor;
  final String route;

  Map<String, Object?> toJson() => {
        'id': id,
        'title': title,
        'start': start.toUtc().toIso8601String(),
        'end': end.toUtc().toIso8601String(),
        'important': important,
        'continuous': continuous,
        'recurring': recurring,
        'team': team,
        'displayColor': displayColor,
        'route': route,
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
      displayColor: requiredString('displayColor'),
      route: requiredString('route'),
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
      displayColor: displayColor,
      route: NotificationRouteContract.schedule(id).toString(),
    );
  }
}
