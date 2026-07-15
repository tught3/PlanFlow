import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:planflow/services/pending_departure_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  group('SharedPreferencesPendingDepartureStore', () {
    late SharedPreferencesPendingDepartureStore store;

    setUp(() {
      store = const SharedPreferencesPendingDepartureStore();
    });

    test('write and read returns the same pending departure', () async {
      final pending = PendingDeparture(
        eventId: 'event-123',
        title: '회의실 방문',
        fireAt: DateTime(2026, 7, 15, 10, 30),
      );

      await store.write(pending);
      final loaded = await store.read();

      expect(loaded, isNotNull);
      expect(loaded!.eventId, 'event-123');
      expect(loaded.title, '회의실 방문');
      expect(loaded.fireAt.year, 2026);
      expect(loaded.fireAt.month, 7);
      expect(loaded.fireAt.day, 15);
      expect(loaded.fireAt.hour, 10);
      expect(loaded.fireAt.minute, 30);
    });

    test('read returns null when nothing is stored', () async {
      final loaded = await store.read();
      expect(loaded, isNull);
    });

    test('clear removes the stored pending departure', () async {
      final pending = PendingDeparture(
        eventId: 'event-456',
        title: '공항 출발',
        fireAt: DateTime.now().add(const Duration(hours: 1)),
      );

      await store.write(pending);
      var loaded = await store.read();
      expect(loaded, isNotNull);

      await store.clear();
      loaded = await store.read();
      expect(loaded, isNull);
    });

    test('write ignores empty eventId', () async {
      final pending = PendingDeparture(
        eventId: '',
        title: '테스트',
        fireAt: DateTime.now(),
      );

      await store.write(pending);
      final loaded = await store.read();

      expect(loaded, isNull);
    });

    test('write ignores whitespace-only eventId', () async {
      final pending = PendingDeparture(
        eventId: '   ',
        title: '테스트',
        fireAt: DateTime.now(),
      );

      await store.write(pending);
      final loaded = await store.read();

      expect(loaded, isNull);
    });

    test('read returns null when eventId key is missing', () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('departure_alarm:pending:title', '회의');
      await prefs.setString(
        'departure_alarm:pending:fire_at',
        DateTime.now().toIso8601String(),
      );

      final loaded = await store.read();
      expect(loaded, isNull);
    });

    test('read returns null when title key is missing', () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('departure_alarm:pending:event_id', 'event-789');
      await prefs.setString(
        'departure_alarm:pending:fire_at',
        DateTime.now().toIso8601String(),
      );

      final loaded = await store.read();
      expect(loaded, isNull);
    });

    test('read returns null when fireAt key is missing', () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('departure_alarm:pending:event_id', 'event-789');
      await prefs.setString('departure_alarm:pending:title', '회의');

      final loaded = await store.read();
      expect(loaded, isNull);
    });

    test('read returns null when fireAt is malformed', () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('departure_alarm:pending:event_id', 'event-999');
      await prefs.setString('departure_alarm:pending:title', '테스트');
      await prefs.setString('departure_alarm:pending:fire_at', 'invalid-date');

      final loaded = await store.read();
      expect(loaded, isNull);
    });

    test('trimmed eventId values are preserved', () async {
      final pending = PendingDeparture(
        eventId: '  event-with-spaces  ',
        title: '테스트',
        fireAt: DateTime.now(),
      );

      await store.write(pending);
      final loaded = await store.read();

      expect(loaded, isNotNull);
      expect(loaded!.eventId, 'event-with-spaces');
    });
  });
}
