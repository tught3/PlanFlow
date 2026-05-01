import '../models/event_model.dart';

abstract class EventRepository {
  const EventRepository();

  Future<List<EventModel>> fetchEvents(String userId);

  Future<void> saveEvent(EventModel event);

  Future<void> deleteEvent(String eventId);
}
