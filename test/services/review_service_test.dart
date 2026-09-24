import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:planflow/services/review_service.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  Future<void> saveAt(
    DateTime value, {
    required List<DateTime> requests,
    bool available = true,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await ReviewService.onEventSaved(
      preferences: prefs,
      now: () => value,
      isAvailable: () async => available,
      requestReview: () async => requests.add(value),
    );
  }

  test('requests when save count alone reaches five', () async {
    final requests = <DateTime>[];
    final first = DateTime.now();

    await saveAt(first, requests: requests);
    await saveAt(first, requests: requests);
    await saveAt(first, requests: requests);
    await saveAt(first, requests: requests);
    expect(requests, isEmpty);

    await saveAt(first, requests: requests);
    expect(requests, hasLength(1));
  });

  test('requests when three active days alone are reached', () async {
    final requests = <DateTime>[];
    final first = DateTime.now();

    await saveAt(first, requests: requests);
    await saveAt(first.add(const Duration(days: 1)), requests: requests);
    expect(requests, isEmpty);

    await saveAt(first.add(const Duration(days: 2)), requests: requests);
    expect(requests, hasLength(1));
  });

  test('requests when seven-day usage age alone is reached', () async {
    final requests = <DateTime>[];
    final first = DateTime.now().subtract(const Duration(days: 8));

    await saveAt(first, requests: requests);
    expect(requests, isEmpty);

    await saveAt(first.add(const Duration(days: 7)), requests: requests);
    expect(requests, hasLength(1));
  });

  test('does not request again during the cooldown window', () async {
    final requests = <DateTime>[];
    final first = DateTime.now().subtract(const Duration(days: 150));
    for (final day in <int>[0, 1, 2, 3, 7]) {
      await saveAt(first.add(Duration(days: day)), requests: requests);
    }
    await saveAt(first.add(const Duration(days: 30)), requests: requests);
    expect(requests, hasLength(1));
  });

  test('does not request before any one threshold is reached', () async {
    final requests = <DateTime>[];
    final first = DateTime.now();
    for (final day in <int>[0, 0, 1, 1]) {
      await saveAt(first.add(Duration(days: day)), requests: requests);
    }
    expect(requests, isEmpty);
  });

  test('requests again after the cooldown window when usage continues',
      () async {
    final requests = <DateTime>[];
    final first = DateTime.now().subtract(const Duration(days: 150));
    for (final day in <int>[0, 1, 2, 3, 7]) {
      await saveAt(first.add(Duration(days: day)), requests: requests);
    }
    await saveAt(first.add(const Duration(days: 128)), requests: requests);
    await saveAt(first.add(const Duration(days: 129)), requests: requests);
    expect(requests, hasLength(2));
  });

  test('leaves prompt state unchanged when native review is unavailable',
      () async {
    final requests = <DateTime>[];
    final first = DateTime.now().subtract(const Duration(days: 150));
    for (final day in <int>[0, 1, 2, 3, 7]) {
      await saveAt(
        first.add(Duration(days: day)),
        requests: requests,
        available: false,
      );
    }
    expect(requests, isEmpty);

    await saveAt(first.add(const Duration(days: 8)), requests: requests);
    expect(requests, hasLength(1));
  });
}
