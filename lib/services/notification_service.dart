class NotificationService {
  const NotificationService();

  // TODO: Schedule local notifications for events and reminders.
  Future<void> schedule({
    required String id,
    required String title,
    required DateTime scheduledAt,
    String? body,
  }) =>
      throw UnimplementedError('NotificationService.schedule');
}
