import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:planflow/data/models/event_model.dart';
import 'package:planflow/data/repositories/event_repository.dart';
import 'package:planflow/screens/departure_alarm_screen.dart';
import 'package:planflow/services/departure_alarm_service.dart';
import 'package:planflow/services/pending_departure_store.dart';

// Fake implementations for testing
class FakeDepartureAlarmService extends Fake
    implements DepartureAlarmService {
  bool acknowledgeDepartureCalled = false;
  String? lastEventId;

  @override
  Future<void> acknowledgeDeparture(String eventId) async {
    acknowledgeDepartureCalled = true;
    lastEventId = eventId;
  }
}

class FakePendingDepartureStore extends Fake
    implements PendingDepartureStore {
  PendingDeparture? _stored;
  bool clearCalled = false;

  @override
  Future<void> write(PendingDeparture pending) async {
    _stored = pending;
  }

  @override
  Future<PendingDeparture?> read() async {
    return _stored;
  }

  @override
  Future<void> clear() async {
    _stored = null;
    clearCalled = true;
  }
}

class FakeEventRepository extends Fake implements EventRepository {
  final Map<String, EventModel> eventMap = <String, EventModel>{};

  @override
  Future<EventModel?> fetchEvent(
    String eventId, {
    String? userId,
  }) async {
    return eventMap[eventId];
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  group('DepartureAlarmScreen', () {
    testWidgets('renders with initial title from parameter',
        (WidgetTester tester) async {
      final store = FakePendingDepartureStore();
      final service = FakeDepartureAlarmService();

      await tester.pumpWidget(
        MaterialApp(
          home: DepartureAlarmScreen(
            eventId: 'event-1',
            initialTitle: '미팅',
            departureAlarmService: service,
            pendingStore: store,
          ),
        ),
      );

      expect(find.text('미팅'), findsOneWidget);
    });

    testWidgets('renders default title when initialTitle is null',
        (WidgetTester tester) async {
      final store = FakePendingDepartureStore();
      final service = FakeDepartureAlarmService();

      await tester.pumpWidget(
        MaterialApp(
          home: DepartureAlarmScreen(
            eventId: 'event-1',
            departureAlarmService: service,
            pendingStore: store,
          ),
        ),
      );

      expect(find.text('지금 출발하세요'), findsOneWidget);
    });

    testWidgets('renders travel minutes when provided',
        (WidgetTester tester) async {
      final store = FakePendingDepartureStore();
      final service = FakeDepartureAlarmService();

      await tester.pumpWidget(
        MaterialApp(
          home: DepartureAlarmScreen(
            eventId: 'event-1',
            initialTitle: '공항',
            travelMinutes: 30,
            departureAlarmService: service,
            pendingStore: store,
          ),
        ),
      );

      expect(find.text('약 30분'), findsOneWidget);
    });

    testWidgets('"출발" button calls acknowledgeDeparture and clears store',
        (WidgetTester tester) async {
      final store = FakePendingDepartureStore();
      final service = FakeDepartureAlarmService();

      await tester.pumpWidget(
        MaterialApp(
          home: DepartureAlarmScreen(
            eventId: 'event-123',
            initialTitle: '출발',
            departureAlarmService: service,
            pendingStore: store,
          ),
        ),
      );

      // "출발" 버튼 탭
      await tester.tap(find.byKey(const Key('departure_alarm_go_button')));
      await tester.pumpAndSettle();

      expect(service.acknowledgeDepartureCalled, isTrue);
      expect(service.lastEventId, 'event-123');
      expect(store.clearCalled, isTrue);
    });

    testWidgets('"닫기" button does not call acknowledgeDeparture',
        (WidgetTester tester) async {
      final store = FakePendingDepartureStore();
      final service = FakeDepartureAlarmService();

      await tester.pumpWidget(
        MaterialApp(
          home: DepartureAlarmScreen(
            eventId: 'event-456',
            initialTitle: '닫기 테스트',
            departureAlarmService: service,
            pendingStore: store,
          ),
        ),
      );

      // "닫기" 버튼 탭
      await tester.tap(find.byKey(const Key('departure_alarm_close_button')));
      await tester.pumpAndSettle();

      expect(service.acknowledgeDepartureCalled, isFalse);
      expect(store.clearCalled, isTrue);
    });

    testWidgets('renders car icon', (WidgetTester tester) async {
      final store = FakePendingDepartureStore();
      final service = FakeDepartureAlarmService();

      await tester.pumpWidget(
        MaterialApp(
          home: DepartureAlarmScreen(
            eventId: 'event-1',
            departureAlarmService: service,
            pendingStore: store,
          ),
        ),
      );

      expect(find.byIcon(Icons.directions_car), findsOneWidget);
    });

    testWidgets('renders both cancel and confirm buttons',
        (WidgetTester tester) async {
      final store = FakePendingDepartureStore();
      final service = FakeDepartureAlarmService();

      await tester.pumpWidget(
        MaterialApp(
          home: DepartureAlarmScreen(
            eventId: 'event-1',
            departureAlarmService: service,
            pendingStore: store,
          ),
        ),
      );

      expect(find.byKey(const Key('departure_alarm_close_button')),
          findsOneWidget);
      expect(find.byKey(const Key('departure_alarm_go_button')),
          findsOneWidget);
    });

    testWidgets('handles null eventRepository gracefully',
        (WidgetTester tester) async {
      final store = FakePendingDepartureStore();
      final service = FakeDepartureAlarmService();

      // eventRepository를 null로 전달
      await tester.pumpWidget(
        MaterialApp(
          home: DepartureAlarmScreen(
            eventId: 'event-1',
            initialTitle: 'Test',
            departureAlarmService: service,
            pendingStore: store,
            eventRepository: null,
          ),
        ),
      );

      expect(find.text('Test'), findsOneWidget);
    });

    testWidgets('does not render travel minutes when null',
        (WidgetTester tester) async {
      final store = FakePendingDepartureStore();
      final service = FakeDepartureAlarmService();

      await tester.pumpWidget(
        MaterialApp(
          home: DepartureAlarmScreen(
            eventId: 'event-1',
            initialTitle: 'Test',
            travelMinutes: null,
            departureAlarmService: service,
            pendingStore: store,
          ),
        ),
      );

      expect(find.byWidgetPredicate(
        (widget) => widget is Text && widget.data?.startsWith('약') == true,
      ), findsNothing);
    });
  });
}
