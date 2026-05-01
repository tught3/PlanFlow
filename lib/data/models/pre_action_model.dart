class PreActionModel {
  const PreActionModel({
    required this.id,
    required this.eventId,
    required this.userId,
    required this.title,
    this.notifyAt,
    this.isDone = false,
    this.offsetHours,
    this.createdAt,
  });

  factory PreActionModel.fromJson(Map<String, dynamic> json) {
    return PreActionModel(
      id: _requiredStringValue(json['id'], 'id'),
      eventId: _requiredStringValue(json['event_id'], 'event_id'),
      userId: _requiredStringValue(json['user_id'], 'user_id'),
      title: _requiredStringValue(json['title'], 'title'),
      notifyAt: _dateTimeValue(json['notify_at']),
      isDone: _boolValue(json['is_done']),
      offsetHours: _intValue(json['offset_hours']),
      createdAt: _dateTimeValue(json['created_at']),
    );
  }

  final String id;
  final String eventId;
  final String userId;
  final String title;
  final DateTime? notifyAt;
  final bool isDone;
  final int? offsetHours;
  final DateTime? createdAt;

  Map<String, dynamic> toJson({bool includeId = true}) {
    return <String, dynamic>{
      if (includeId) 'id': id,
      'event_id': eventId,
      'user_id': userId,
      'title': title,
      if (notifyAt != null) 'notify_at': notifyAt!.toIso8601String(),
      'is_done': isDone,
      if (offsetHours != null) 'offset_hours': offsetHours,
      if (createdAt != null) 'created_at': createdAt!.toIso8601String(),
    };
  }

  DateTime? resolveNotifyAt(DateTime eventStartAt) {
    final existingNotifyAt = notifyAt;
    if (existingNotifyAt != null) {
      return existingNotifyAt;
    }
    return calculateNotifyAt(
      eventStartAt: eventStartAt,
      offsetHours: offsetHours,
    );
  }

  static DateTime? calculateNotifyAt({
    required DateTime eventStartAt,
    int? offsetHours,
  }) {
    if (offsetHours == null) {
      return null;
    }
    return eventStartAt.subtract(Duration(hours: offsetHours));
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

  static int? _intValue(Object? value) {
    if (value == null) {
      return null;
    }
    if (value is int) {
      return value;
    }
    if (value is num) {
      return value.toInt();
    }
    return int.tryParse(value.toString());
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
}
