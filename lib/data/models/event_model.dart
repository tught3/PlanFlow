import '../../core/event_metadata.dart';

class EventModel {
  const EventModel({
    required this.id,
    required this.userId,
    required this.title,
    this.startAt,
    this.endAt,
    this.location,
    this.locationLat,
    this.locationLng,
    this.memo,
    this.supplies = const <String>[],
    this.suppliesChecked = const <String>[],
    this.participants = const <String>[],
    this.targets = const <String>[],
    this.isCritical = false,
    this.useStrongAlarm = false,
    this.recurrenceRule,
    this.isAllDay = false,
    this.isMultiDay = false,
    this.parentEventId,
    this.category = '기타',
    this.source = 'manual',
    this.externalId,
    this.externalCalendarId,
    this.externalEtag,
    this.externalUpdatedAt,
    this.lastSyncedAt,
    this.createdAt,
    this.updatedAt,
  });

  factory EventModel.fromJson(Map<String, dynamic> json) {
    return EventModel(
      id: _requiredStringValue(json['id'], 'id'),
      userId: _requiredStringValue(json['user_id'], 'user_id'),
      title: _requiredStringValue(json['title'], 'title'),
      startAt: _requiredDateTimeValue(json['start_at'], 'start_at'),
      endAt: _dateTimeValue(json['end_at']),
      location: json['location'] as String?,
      locationLat: _doubleValue(json['location_lat']),
      locationLng: _doubleValue(json['location_lng']),
      memo: json['memo'] as String?,
      supplies: _stringListValue(json['supplies']),
      suppliesChecked: _stringListValue(json['supplies_checked']),
      participants: _stringListValue(json['participants']),
      targets: _stringListValue(json['targets']),
      isCritical: _boolValue(json['is_critical']),
      useStrongAlarm: _boolValue(json['use_strong_alarm']),
      recurrenceRule: _optionalStringValue(json['recurrence_rule']),
      isAllDay: _boolValue(json['is_all_day']),
      isMultiDay: _boolValue(json['is_multi_day']),
      parentEventId: _optionalStringValue(json['parent_event_id']),
      category: _categoryValue(json['category']),
      source: _sourceValue(json['source']),
      externalId: _optionalStringValue(json['external_id']),
      externalCalendarId: _optionalStringValue(json['external_calendar_id']),
      externalEtag: _optionalStringValue(json['external_etag']),
      externalUpdatedAt: _dateTimeValue(json['external_updated_at']),
      lastSyncedAt: _dateTimeValue(json['last_synced_at']),
      createdAt: _dateTimeValue(json['created_at']),
      updatedAt: _dateTimeValue(json['updated_at']),
    );
  }

  final String id;
  final String userId;
  final String title;
  final DateTime? startAt;
  final DateTime? endAt;
  final String? location;
  final double? locationLat;
  final double? locationLng;
  final String? memo;
  final List<String> supplies;
  final List<String> suppliesChecked;
  final List<String> participants;
  final List<String> targets;
  final bool isCritical;
  final bool useStrongAlarm;
  final String? recurrenceRule;
  final bool isAllDay;
  final bool isMultiDay;
  final String? parentEventId;
  final String category;
  final String source;
  final String? externalId;
  final String? externalCalendarId;
  final String? externalEtag;
  final DateTime? externalUpdatedAt;
  final DateTime? lastSyncedAt;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  bool get hasLocationText => location?.trim().isNotEmpty == true;

  bool get hasResolvedLocation =>
      hasLocationText && locationLat != null && locationLng != null;

  bool get hasUnresolvedLocation => hasLocationText && !hasResolvedLocation;

  Map<String, dynamic> toJson({bool includeId = true}) {
    return <String, dynamic>{
      if (includeId) 'id': id,
      'user_id': userId,
      'title': title,
      'start_at': _utcIsoValue(startAt),
      'end_at': _utcIsoValue(endAt),
      'location': location,
      'location_lat': locationLat,
      'location_lng': locationLng,
      'memo': memo,
      'supplies': supplies,
      'supplies_checked': suppliesChecked,
      'participants': participants,
      'targets': targets,
      'is_critical': isCritical,
      'use_strong_alarm': useStrongAlarm,
      'recurrence_rule': _optionalStringValue(recurrenceRule),
      'is_all_day': isAllDay,
      'is_multi_day': isMultiDay,
      'parent_event_id': _optionalStringValue(parentEventId),
      'category': _categoryValue(category),
      'source': _sourceValue(source),
      'external_id': _optionalStringValue(externalId),
      'external_calendar_id': _optionalStringValue(externalCalendarId),
      'external_etag': _optionalStringValue(externalEtag),
      'external_updated_at': _utcIsoValue(externalUpdatedAt),
      'last_synced_at': _utcIsoValue(lastSyncedAt),
      if (createdAt != null) 'created_at': _utcIsoValue(createdAt),
      if (updatedAt != null) 'updated_at': _utcIsoValue(updatedAt),
    };
  }

  Map<String, dynamic> toUpdateJson() {
    return <String, dynamic>{
      'title': title,
      'start_at': _utcIsoValue(startAt),
      'end_at': _utcIsoValue(endAt),
      'location': location,
      'location_lat': locationLat,
      'location_lng': locationLng,
      'memo': memo,
      'supplies': supplies,
      'supplies_checked': suppliesChecked,
      'participants': participants,
      'targets': targets,
      'is_critical': isCritical,
      'use_strong_alarm': useStrongAlarm,
      'recurrence_rule': _optionalStringValue(recurrenceRule),
      'is_all_day': isAllDay,
      'is_multi_day': isMultiDay,
      'parent_event_id': _optionalStringValue(parentEventId),
      'category': _categoryValue(category),
      'source': _sourceValue(source),
      'external_id': _optionalStringValue(externalId),
      'external_calendar_id': _optionalStringValue(externalCalendarId),
      'external_etag': _optionalStringValue(externalEtag),
      'external_updated_at': _utcIsoValue(externalUpdatedAt),
      'last_synced_at': _utcIsoValue(lastSyncedAt),
    };
  }

  static String? _utcIsoValue(DateTime? value) {
    return value?.toUtc().toIso8601String();
  }

  static String _stringValue(Object? value) {
    final text = value?.toString();
    if (text == null || text.isEmpty) {
      return '';
    }
    return text;
  }

  static String _requiredStringValue(Object? value, String fieldName) {
    final text = _stringValue(value);
    if (text.isEmpty) {
      throw StateError('Missing required field: $fieldName');
    }
    return text;
  }

  static String _sourceValue(Object? value) {
    final text = _stringValue(value);
    return text.isEmpty ? 'manual' : text;
  }

  static String _categoryValue(Object? value) {
    return PlanFlowEventCategories.normalize(value);
  }

  static String? _optionalStringValue(Object? value) {
    final text = _stringValue(value);
    return text.isEmpty ? null : text;
  }

  static bool _boolValue(Object? value) {
    if (value is bool) {
      return value;
    }
    if (value is String) {
      return value.toLowerCase() == 'true';
    }
    if (value is num) {
      return value != 0;
    }
    return false;
  }

  static double? _doubleValue(Object? value) {
    if (value == null) {
      return null;
    }
    if (value is double) {
      return value;
    }
    if (value is num) {
      return value.toDouble();
    }
    return double.tryParse(value.toString());
  }

  static DateTime? _dateTimeValue(Object? value) {
    if (value == null) {
      return null;
    }
    if (value is DateTime) {
      return value;
    }
    final text = value.toString();
    if (text.isEmpty) {
      return null;
    }
    return DateTime.parse(text);
  }

  static DateTime _requiredDateTimeValue(Object? value, String fieldName) {
    final parsed = _dateTimeValue(value);
    if (parsed == null) {
      throw StateError('Missing required field: $fieldName');
    }
    return parsed;
  }

  static List<String> _stringListValue(Object? value) {
    if (value == null) {
      return const <String>[];
    }
    if (value is List) {
      return value
          .map((item) => item.toString())
          .where((item) => item.isNotEmpty)
          .toList(growable: false);
    }
    final text = value.toString();
    if (text.isEmpty) {
      return const <String>[];
    }
    return <String>[text];
  }
}
