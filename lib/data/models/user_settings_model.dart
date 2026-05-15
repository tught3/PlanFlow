class UserSettingsModel {
  const UserSettingsModel({
    required this.id,
    required this.userId,
    this.morningBriefingAt = '07:30',
    this.eveningBriefingAt = '21:00',
    this.defaultReminderMin = 60,
    this.prepTimeMin = 30,
    this.prepPreAlarmOffset = 30,
    this.departPreAlarmOffset = 30,
    this.travelMode = 'car',
    this.voiceAutoStart = false,
    this.preferredMapProvider = 'naver',
    this.countryCode = 'KR',
    this.localeCode = 'ko-KR',
    this.timeZoneId = 'Asia/Seoul',
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
      prepTimeMin: 30,
      prepPreAlarmOffset: 30,
      departPreAlarmOffset: 30,
      voiceAutoStart: false,
      preferredMapProvider: 'naver',
      countryCode: 'KR',
      localeCode: 'ko-KR',
      timeZoneId: 'Asia/Seoul',
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
      prepTimeMin: _intValue(json['prep_time_min'], 30),
      prepPreAlarmOffset: _intValue(json['prep_pre_alarm_offset'], 30),
      departPreAlarmOffset: _intValue(json['depart_pre_alarm_offset'], 30),
      travelMode: _travelModeValue(json['travel_mode']),
      voiceAutoStart: _boolValue(json['voice_auto_start'], false),
      preferredMapProvider:
          _preferredMapProviderValue(json['preferred_map_provider']),
      countryCode: _countryCodeValue(json['country_code']),
      localeCode: _localeValue(
        json['locale_code'],
        _countryCodeValue(json['country_code']),
      ),
      timeZoneId: _timeZoneValue(
        json['time_zone_id'],
        _countryCodeValue(json['country_code']),
      ),
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
  final int prepTimeMin;
  final int prepPreAlarmOffset;
  final int departPreAlarmOffset;
  final String travelMode;
  final bool voiceAutoStart;
  final String preferredMapProvider;
  final String countryCode;
  final String localeCode;
  final String timeZoneId;
  final String? googleCalendarToken;
  final String? naverCalendarToken;
  final DateTime? createdAt;

  UserSettingsModel copyWith({
    String? id,
    String? userId,
    String? morningBriefingAt,
    String? eveningBriefingAt,
    int? defaultReminderMin,
    int? prepTimeMin,
    int? prepPreAlarmOffset,
    int? departPreAlarmOffset,
    String? travelMode,
    bool? voiceAutoStart,
    String? preferredMapProvider,
    String? countryCode,
    String? localeCode,
    String? timeZoneId,
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
      prepTimeMin: prepTimeMin ?? this.prepTimeMin,
      prepPreAlarmOffset: prepPreAlarmOffset ?? this.prepPreAlarmOffset,
      departPreAlarmOffset: departPreAlarmOffset ?? this.departPreAlarmOffset,
      travelMode: travelMode ?? this.travelMode,
      voiceAutoStart: voiceAutoStart ?? this.voiceAutoStart,
      preferredMapProvider: preferredMapProvider ?? this.preferredMapProvider,
      countryCode: countryCode ?? this.countryCode,
      localeCode: localeCode ?? this.localeCode,
      timeZoneId: timeZoneId ?? this.timeZoneId,
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
      'prep_time_min': prepTimeMin,
      'prep_pre_alarm_offset': prepPreAlarmOffset,
      'depart_pre_alarm_offset': departPreAlarmOffset,
      'travel_mode': _travelModeValue(travelMode),
      'voice_auto_start': voiceAutoStart,
      'preferred_map_provider':
          _preferredMapProviderValue(preferredMapProvider),
      'country_code': _countryCodeValue(countryCode),
      'locale_code': localeCode,
      'time_zone_id': timeZoneId,
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

  static bool _boolValue(Object? value, bool fallback) {
    if (value is bool) {
      return value;
    }
    final text = value?.toString().trim().toLowerCase();
    if (text == 'true' || text == '1' || text == 'yes') {
      return true;
    }
    if (text == 'false' || text == '0' || text == 'no') {
      return false;
    }
    return fallback;
  }

  static String _travelModeValue(Object? value) {
    final text = value?.toString().trim().toLowerCase() ?? '';
    return text == 'transit' ? 'transit' : 'car';
  }

  static String _preferredMapProviderValue(Object? value) {
    final text = value?.toString().trim().toLowerCase() ?? '';
    const supported = <String>{'naver', 'google', 'tmap'};
    return supported.contains(text) ? text : 'naver';
  }

  static String _countryCodeValue(Object? value) {
    final text = value?.toString().trim().toUpperCase() ?? '';
    const supported = <String>{'KR', 'US', 'JP', 'GB', 'DE', 'FR', 'AU'};
    return supported.contains(text) ? text : 'KR';
  }

  static String _localeValue(Object? value, String countryCode) {
    final text = _stringValue(value).trim();
    if (text.isNotEmpty) {
      return text;
    }
    return switch (countryCode) {
      'US' => 'en-US',
      'JP' => 'ja-JP',
      'GB' => 'en-GB',
      'DE' => 'de-DE',
      'FR' => 'fr-FR',
      'AU' => 'en-AU',
      _ => 'ko-KR',
    };
  }

  static String _timeZoneValue(Object? value, String countryCode) {
    final text = _stringValue(value).trim();
    if (text.isNotEmpty) {
      return text;
    }
    return switch (countryCode) {
      'US' => 'America/New_York',
      'JP' => 'Asia/Tokyo',
      'GB' => 'Europe/London',
      'DE' => 'Europe/Berlin',
      'FR' => 'Europe/Paris',
      'AU' => 'Australia/Sydney',
      _ => 'Asia/Seoul',
    };
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
