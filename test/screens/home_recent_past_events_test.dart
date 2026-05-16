import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/data/models/event_model.dart';
import 'package:planflow/screens/home/home_screen.dart';

void main() {
  test('homeRecentPastEvents returns only events ended within last 12 hours',
      () {
    final now = DateTime(2026, 5, 16, 14);
    final events = <EventModel>[
      EventModel(
        id: 'too-old',
        userId: 'user-1',
        title: '어제 늦은 일정',
        startAt: now.subtract(const Duration(hours: 13)),
      ),
      EventModel(
        id: 'recent-1',
        userId: 'user-1',
        title: '아침 일정',
        startAt: now.subtract(const Duration(hours: 5)),
      ),
      EventModel(
        id: 'ongoing',
        userId: 'user-1',
        title: '진행 중 일정',
        startAt: now.subtract(const Duration(hours: 1)),
        endAt: now.add(const Duration(minutes: 30)),
      ),
      EventModel(
        id: 'future',
        userId: 'user-1',
        title: '미래 일정',
        startAt: now.add(const Duration(hours: 1)),
      ),
      EventModel(
        id: 'recent-2',
        userId: 'user-1',
        title: '방금 끝난 일정',
        startAt: now.subtract(const Duration(hours: 2)),
        endAt: now.subtract(const Duration(minutes: 10)),
      ),
    ];

    final recentPastEvents = homeRecentPastEvents(events, now: now);

    expect(
      recentPastEvents.map((event) => event.id),
      <String>['recent-1', 'recent-2'],
    );
  });
}
