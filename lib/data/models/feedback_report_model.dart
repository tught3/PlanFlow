enum FeedbackReportType {
  bug('bug', '버그'),
  voice('voice', '음성 인식 오류'),
  calendarSync('calendar_sync', '캘린더 동기화'),
  notification('notification', '알림'),
  mapLocation('map_location', '지도/위치'),
  featureRequest('feature_request', '기능 제안'),
  betaSurvey('beta_survey', '베타 후기'),
  other('other', '기타');

  const FeedbackReportType(this.value, this.label);

  final String value;
  final String label;

  static FeedbackReportType fromValue(String? value) {
    return FeedbackReportType.values.firstWhere(
      (type) => type.value == value,
      orElse: () => FeedbackReportType.other,
    );
  }
}

enum FeedbackReportStatus {
  newReport('new', '신규'),
  triaged('triaged', '확인 중'),
  fixed('fixed', '수정됨'),
  closed('closed', '종료');

  const FeedbackReportStatus(this.value, this.label);

  final String value;
  final String label;

  static FeedbackReportStatus fromValue(String? value) {
    return FeedbackReportStatus.values.firstWhere(
      (status) => status.value == value,
      orElse: () => FeedbackReportStatus.newReport,
    );
  }
}

class FeedbackReport {
  const FeedbackReport({
    required this.id,
    required this.userId,
    required this.product,
    required this.type,
    required this.message,
    required this.expectedBehavior,
    required this.appVersion,
    required this.platform,
    required this.deviceSummary,
    required this.routeOrScreen,
    required this.diagnostics,
    required this.status,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String userId;
  final String product;
  final FeedbackReportType type;
  final String message;
  final String? expectedBehavior;
  final String? appVersion;
  final String? platform;
  final String? deviceSummary;
  final String? routeOrScreen;
  final Map<String, Object?> diagnostics;
  final FeedbackReportStatus status;
  final DateTime createdAt;
  final DateTime updatedAt;

  factory FeedbackReport.fromMap(Map<String, Object?> map) {
    return FeedbackReport(
      id: map['id'] as String,
      userId: map['user_id'] as String,
      product: map['product'] as String? ?? 'planflow',
      type: FeedbackReportType.fromValue(map['type'] as String?),
      message: map['message'] as String? ?? '',
      expectedBehavior: map['expected_behavior'] as String?,
      appVersion: map['app_version'] as String?,
      platform: map['platform'] as String?,
      deviceSummary: map['device_summary'] as String?,
      routeOrScreen: map['route_or_screen'] as String?,
      diagnostics: _mapFromJsonb(map['diagnostics']),
      status: FeedbackReportStatus.fromValue(map['status'] as String?),
      createdAt: _dateTimeFromValue(map['created_at']),
      updatedAt: _dateTimeFromValue(map['updated_at']),
    );
  }

  FeedbackReport copyWith({
    FeedbackReportStatus? status,
  }) {
    return FeedbackReport(
      id: id,
      userId: userId,
      product: product,
      type: type,
      message: message,
      expectedBehavior: expectedBehavior,
      appVersion: appVersion,
      platform: platform,
      deviceSummary: deviceSummary,
      routeOrScreen: routeOrScreen,
      diagnostics: diagnostics,
      status: status ?? this.status,
      createdAt: createdAt,
      updatedAt: updatedAt,
    );
  }

  static Map<String, Object?> _mapFromJsonb(Object? value) {
    if (value is Map<String, Object?>) {
      return value;
    }
    if (value is Map) {
      return Map<String, Object?>.from(value);
    }
    return const <String, Object?>{};
  }

  static DateTime _dateTimeFromValue(Object? value) {
    if (value is DateTime) {
      return value;
    }
    if (value is String && value.isNotEmpty) {
      return DateTime.parse(value);
    }
    return DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
  }
}

class FeedbackDiagnostics {
  const FeedbackDiagnostics({
    required this.appVersion,
    required this.platform,
    required this.deviceSummary,
    required this.diagnostics,
  });

  final String appVersion;
  final String platform;
  final String deviceSummary;
  final Map<String, Object?> diagnostics;
}

class FeedbackSubmissionException implements Exception {
  const FeedbackSubmissionException(this.message);

  final String message;

  @override
  String toString() => message;
}
