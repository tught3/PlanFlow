class EventModel {
  const EventModel({
    required this.id,
    required this.userId,
    required this.title,
    this.startAt,
    this.endAt,
    this.location,
    this.memo,
    this.supplies = const <String>[],
    this.isCritical = false,
    this.createdAt,
  });

  final String id;
  final String userId;
  final String title;
  final DateTime? startAt;
  final DateTime? endAt;
  final String? location;
  final String? memo;
  final List<String> supplies;
  final bool isCritical;
  final DateTime? createdAt;
}
