import '../data/models/event_model.dart';

/// Route-only context for editing a draft while retaining its persisted source.
/// This value is never persisted.
class EventEditRoutePayload {
  const EventEditRoutePayload({
    required this.draft,
    required this.original,
    this.originalOccurrenceStartAt,
  });

  final EventModel draft;
  final EventModel original;
  final DateTime? originalOccurrenceStartAt;
}
