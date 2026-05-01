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

  final String id;
  final String userId;
  final String morningBriefingAt;
  final String eveningBriefingAt;
  final int defaultReminderMin;
  final String? googleCalendarToken;
  final String? naverCalendarToken;
  final DateTime? createdAt;
}
