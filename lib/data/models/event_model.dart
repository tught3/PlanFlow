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
    this.isCritical = false,
    this.source = 'manual',
    this.externalId,
    this.externalCalendarId,
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
      isCritical: _boolValue(json['is_critical']),
      source: _sourceValue(json['source']),
      externalId: _optionalStringValue(json['external_id']),
      externalCalendarId: _optionalStringValue(json['external_calendar_id']),
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
  final bool isCritical;
  final String source;
  final String? externalId;
  final String? externalCalendarId;
  final DateTime? externalUpdatedAt;
  final DateTime? lastSyncedAt;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  Map<String, dynamic> toJson({bool includeId = true}) {
    return <String, dynamic>{
      if (includeId) 'id': id,
      'user_id': userId,
      'title': title,
      'start_at': startAt?.toIso8601String(),
      'end_at': endAt?.toIso8601String(),
      'location': location,
      'location_lat': locationLat,
      'location_lng': locationLng,
      'memo': memo,
      'supplies': supplies,
      'supplies_checked': suppliesChecked,
      'is_critical': isCritical,
      'source': _sourceValue(source),
      'external_id': _optionalStringValue(externalId),
      'external_calendar_id': _optionalStringValue(externalCalendarId),
      'external_updated_at': externalUpdatedAt?.toIso8601String(),
      'last_synced_at': lastSyncedAt?.toIso8601String(),
      if (createdAt != null) 'created_at': createdAt!.toIso8601String(),
      if (updatedAt != null) 'updated_at': updatedAt!.toIso8601String(),
    };
  }

  Map<String, dynamic> toUpdateJson() {
    return <String, dynamic>{
      'title': title,
      'start_at': startAt?.toIso8601String(),
      'end_at': endAt?.toIso8601String(),
      'location': location,
      'location_lat': locationLat,
      'location_lng': locationLng,
      'memo': memo,
      'supplies': supplies,
      'supplies_checked': suppliesChecked,
      'is_critical': isCritical,
      'source': _sourceValue(source),
      'external_id': _optionalStringValue(externalId),
      'external_calendar_id': _optionalStringValue(externalCalendarId),
      'external_updated_at': externalUpdatedAt?.toIso8601String(),
      'last_synced_at': lastSyncedAt?.toIso8601String(),
    };
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
