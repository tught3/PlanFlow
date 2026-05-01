class ReminderModel {
  const ReminderModel({
    required this.id,
    required this.eventId,
    required this.userId,
    required this.type,
    required this.notifyAt,
    this.isSent = false,
    this.createdAt,
  });

  factory ReminderModel.fromJson(Map<String, dynamic> json) {
    return ReminderModel(
      id: _requiredStringValue(json['id'], 'id'),
      eventId: _requiredStringValue(json['event_id'], 'event_id'),
      userId: _requiredStringValue(json['user_id'], 'user_id'),
      type: _requiredStringValue(json['type'], 'type'),
      notifyAt: _requiredDateTimeValue(json['notify_at'], 'notify_at'),
      isSent: _boolValue(json['is_sent']),
      createdAt: _dateTimeValue(json['created_at']),
    );
  }

  final String id;
  final String eventId;
  final String userId;
  final String type;
  final DateTime notifyAt;
  final bool isSent;
  final DateTime? createdAt;

  Map<String, dynamic> toJson({bool includeId = true}) {
    return <String, dynamic>{
      if (includeId) 'id': id,
      'event_id': eventId,
      'user_id': userId,
      'type': type,
      'notify_at': notifyAt.toIso8601String(),
      'is_sent': isSent,
      if (createdAt != null) 'created_at': createdAt!.toIso8601String(),
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
}
