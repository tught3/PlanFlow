import 'package:shared_preferences/shared_preferences.dart';

import '../core/safe_prefs.dart';

abstract class DepartureAcknowledgementStore {
  const DepartureAcknowledgementStore();

  Future<bool> isAcknowledged(String eventId);

  Future<void> markAcknowledged(String eventId);

  Future<void> clearAcknowledged(String eventId);

  Future<void> clearAcknowledgedForEvents(Iterable<String> eventIds) async {
    for (final eventId in eventIds) {
      await clearAcknowledged(eventId);
    }
  }
}

class SharedPreferencesDepartureAcknowledgementStore
    extends DepartureAcknowledgementStore {
  const SharedPreferencesDepartureAcknowledgementStore();

  static const String _prefix = 'departure_alarm:ack:';

  String _key(String eventId) => '$_prefix${eventId.trim()}';

  Future<SharedPreferences?> _prefs() async {
    return tryGetPrefs();
  }

  @override
  Future<bool> isAcknowledged(String eventId) async {
    final normalizedEventId = eventId.trim();
    if (normalizedEventId.isEmpty) {
      return false;
    }
    final prefs = await _prefs();
    if (prefs == null) {
      return false;
    }
    return prefs.getBool(_key(normalizedEventId)) ?? false;
  }

  @override
  Future<void> markAcknowledged(String eventId) async {
    final normalizedEventId = eventId.trim();
    if (normalizedEventId.isEmpty) {
      return;
    }
    final prefs = await _prefs();
    if (prefs == null) {
      return;
    }
    await prefs.setBool(_key(normalizedEventId), true);
  }

  @override
  Future<void> clearAcknowledged(String eventId) async {
    final normalizedEventId = eventId.trim();
    if (normalizedEventId.isEmpty) {
      return;
    }
    final prefs = await _prefs();
    if (prefs == null) {
      return;
    }
    await prefs.remove(_key(normalizedEventId));
  }
}
