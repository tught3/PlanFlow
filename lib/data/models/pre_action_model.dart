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

  final String id;
  final String eventId;
  final String userId;
  final String title;
  final DateTime? notifyAt;
  final bool isDone;
  final int? offsetHours;
  final DateTime? createdAt;
}
