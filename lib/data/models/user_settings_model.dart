class UserSettingsModel {
  const UserSettingsModel({
    required this.id,
    required this.userId,
    this.morningBriefingAt = '07:30',
    this.eveningBriefingAt = '21:00',
    this.defaultReminderMin = 60,
    this.googleCalendarToken,
    this.naverCalendarToken,
    this.createdAt,
  });

  factory UserSettingsModel.defaults({
    required String userId,
    String id = '',
    DateTime? createdAt,
  }) {
    return UserSettingsModel(
      id: id,
      userId: userId,
      morningBriefingAt: '07:30',
      eveningBriefingAt: '21:00',
      defaultReminderMin: 60,
      createdAt: createdAt,
    );
  }

  factory UserSettingsModel.fromJson(Map<String, dynamic> json) {
    return UserSettingsModel(
      id: _requiredStringValue(json['id'], 'id'),
      userId: _requiredStringValue(json['user_id'], 'user_id'),
      morningBriefingAt: _timeValue(json['morning_briefing_at']),
      eveningBriefingAt: _timeValue(json['evening_briefing_at']),
      defaultReminderMin: _intValue(json['default_reminder_min'], 60),
      googleCalendarToken: json['google_calendar_token'] as String?,
      naverCalendarToken: json['naver_calendar_token'] as String?,
      createdAt: _dateTimeValue(json['created_at']),
    );
  }

  final String id;
  final String userId;
  final String morningBriefingAt;
  final String eveningBriefingAt;
  final int defaultReminderMin;
  final String? googleCalendarToken;
  final String? naverCalendarToken;
  final DateTime? createdAt;

  UserSettingsModel copyWith({
    String? id,
    String? userId,
    String? morningBriefingAt,
    String? eveningBriefingAt,
    int? defaultReminderMin,
    String? googleCalendarToken,
    String? naverCalendarToken,
    DateTime? createdAt,
    bool clearGoogleCalendarToken = false,
    bool clearNaverCalendarToken = false,
    bool clearCreatedAt = false,
  }) {
    return UserSettingsModel(
      id: id ?? this.id,
      userId: userId ?? this.userId,
      morningBriefingAt: morningBriefingAt ?? this.morningBriefingAt,
      eveningBriefingAt: eveningBriefingAt ?? this.eveningBriefingAt,
      defaultReminderMin: defaultReminderMin ?? this.defaultReminderMin,
      googleCalendarToken: clearGoogleCalendarToken
          ? null
          : googleCalendarToken ?? this.googleCalendarToken,
      naverCalendarToken: clearNaverCalendarToken
          ? null
          : naverCalendarToken ?? this.naverCalendarToken,
      createdAt: clearCreatedAt ? null : createdAt ?? this.createdAt,
    );
  }

  Map<String, dynamic> toJson({bool includeId = true}) {
    return <String, dynamic>{
      if (includeId) 'id': id,
      'user_id': userId,
      'morning_briefing_at': morningBriefingAt,
      'evening_briefing_at': eveningBriefingAt,
      'default_reminder_min': defaultReminderMin,
      'google_calendar_token': googleCalendarToken,
      'naver_calendar_token': naverCalendarToken,
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

  static String _timeValue(Object? value) {
    final text = value?.toString();
    if (text == null || text.isEmpty) {
      return '';
    }
    final match = RegExp(r'^(\d{2}:\d{2})').firstMatch(text);
    return match?.group(1) ?? text;
  }

  static int _intValue(Object? value, int fallback) {
    if (value is int) {
      return value;
    }
    if (value is num) {
      return value.toInt();
    }
    return int.tryParse(value?.toString() ?? '') ?? fallback;
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
