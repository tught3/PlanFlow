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

  test('requests native review only after meaningful usage milestones',
      () async {
    final requests = <DateTime>[];
    final first = DateTime.now().subtract(const Duration(days: 150));

    await saveAt(first, requests: requests);
    await saveAt(first.add(const Duration(days: 1)), requests: requests);
    await saveAt(first.add(const Duration(days: 2)), requests: requests);
    await saveAt(first.add(const Duration(days: 3)), requests: requests);
    await saveAt(first.add(const Duration(days: 6)), requests: requests);
    expect(requests, isEmpty, reason: 'seven-day usage age is not reached');

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

  test('does not request before three distinct active days', () async {
    final requests = <DateTime>[];
    final first = DateTime.now().subtract(const Duration(days: 150));
    for (final day in <int>[0, 7, 7, 7, 7]) {
      await saveAt(first.add(Duration(days: day)), requests: requests);
    }
    expect(requests, isEmpty);
  });

  test('requests again after the cooldown window when usage continues', () async {
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
