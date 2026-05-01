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

  final String id;
  final String eventId;
  final String userId;
  final String type;
  final DateTime notifyAt;
  final bool isSent;
  final DateTime? createdAt;
}
