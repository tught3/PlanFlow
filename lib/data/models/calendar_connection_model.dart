enum CalendarConnectionStatus {
  disconnected('disconnected'),
  connected('connected'),
  reauthRequired('reauth_required'),
  failed('failed');

  const CalendarConnectionStatus(this.value);

  final String value;

  static CalendarConnectionStatus fromValue(Object? value) {
    final text = value?.toString().trim();
    return CalendarConnectionStatus.values.firstWhere(
      (status) => status.value == text,
      orElse: () => CalendarConnectionStatus.disconnected,
    );
  }
}

class CalendarConnectionModel {
  const CalendarConnectionModel({
    this.id,
    required this.userId,
    required this.provider,
    this.providerAccountEmail,
    this.status = CalendarConnectionStatus.disconnected,
    this.accessToken,
    this.refreshToken,
    this.lastSyncedAt,
    this.lastError,
    this.createdAt,
    this.updatedAt,
  });

  factory CalendarConnectionModel.fromJson(Map<String, dynamic> json) {
    return CalendarConnectionModel(
      id: _optionalString(json['id']),
      userId: _requiredString(json['user_id'], 'user_id'),
      provider: _requiredString(json['provider'], 'provider'),
      providerAccountEmail: _optionalString(json['provider_account_email']),
      status: CalendarConnectionStatus.fromValue(json['status']),
      accessToken: _optionalString(json['access_token']),
      refreshToken: _optionalString(json['refresh_token']),
      lastSyncedAt: _dateTime(json['last_synced_at']),
      lastError: _optionalString(json['last_error']),
      createdAt: _dateTime(json['created_at']),
      updatedAt: _dateTime(json['updated_at']),
    );
  }

  final String? id;
  final String userId;
  final String provider;
  final String? providerAccountEmail;
  final CalendarConnectionStatus status;
  final String? accessToken;
  final String? refreshToken;
  final DateTime? lastSyncedAt;
  final String? lastError;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  bool get isConnected => status == CalendarConnectionStatus.connected;

  CalendarConnectionModel copyWith({
    String? id,
    String? userId,
    String? provider,
    String? providerAccountEmail,
    CalendarConnectionStatus? status,
    String? accessToken,
    String? refreshToken,
    DateTime? lastSyncedAt,
    String? lastError,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return CalendarConnectionModel(
      id: id ?? this.id,
      userId: userId ?? this.userId,
      provider: provider ?? this.provider,
      providerAccountEmail:
          providerAccountEmail ?? this.providerAccountEmail,
      status: status ?? this.status,
      accessToken: accessToken ?? this.accessToken,
      refreshToken: refreshToken ?? this.refreshToken,
      lastSyncedAt: lastSyncedAt ?? this.lastSyncedAt,
      lastError: lastError ?? this.lastError,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, dynamic> toJson({bool includeId = true}) {
    return <String, dynamic>{
      if (includeId && id != null && id!.trim().isNotEmpty) 'id': id,
      'user_id': userId,
      'provider': provider,
      'provider_account_email': providerAccountEmail,
      'status': status.value,
      'access_token': accessToken,
      'refresh_token': refreshToken,
      'last_synced_at': lastSyncedAt?.toIso8601String(),
      'last_error': lastError,
      if (createdAt != null) 'created_at': createdAt!.toIso8601String(),
      if (updatedAt != null) 'updated_at': updatedAt!.toIso8601String(),
    };
  }

  static String _requiredString(Object? value, String fieldName) {
    final text = value?.toString().trim() ?? '';
    if (text.isEmpty) {
      throw StateError('Missing required field: $fieldName');
    }
    return text;
  }

  static String? _optionalString(Object? value) {
    final text = value?.toString().trim() ?? '';
    return text.isEmpty ? null : text;
  }

  static DateTime? _dateTime(Object? value) {
    if (value == null) {
      return null;
    }
    if (value is DateTime) {
      return value;
    }
    final text = value.toString().trim();
    if (text.isEmpty) {
      return null;
    }
    return DateTime.parse(text);
  }
}
