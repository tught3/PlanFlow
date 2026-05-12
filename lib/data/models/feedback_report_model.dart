enum FeedbackReportType {
  bug('bug', '버그'),
  voice('voice', '음성 인식 오류'),
  calendarSync('calendar_sync', '캘린더 동기화'),
  notification('notification', '알림'),
  mapLocation('map_location', '지도/위치'),
  featureRequest('feature_request', '기능 제안'),
  other('other', '기타');

  const FeedbackReportType(this.value, this.label);

  final String value;
  final String label;
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
