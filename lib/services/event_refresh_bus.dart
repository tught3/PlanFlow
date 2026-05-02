import 'package:flutter/foundation.dart';

class EventRefreshSignal {
  const EventRefreshSignal({
    required this.sequence,
    required this.reason,
    this.eventId,
    this.startAt,
  });

  final int sequence;
  final String reason;
  final String? eventId;
  final DateTime? startAt;
}

class EventRefreshBus {
  EventRefreshBus._();

  static final EventRefreshBus instance = EventRefreshBus._();

  final ValueNotifier<EventRefreshSignal?> latest =
      ValueNotifier<EventRefreshSignal?>(null);

  int _sequence = 0;

  void notifyChanged({
    required String reason,
    String? eventId,
    DateTime? startAt,
  }) {
    latest.value = EventRefreshSignal(
      sequence: ++_sequence,
      reason: reason,
      eventId: eventId,
      startAt: startAt,
    );
  }
}
