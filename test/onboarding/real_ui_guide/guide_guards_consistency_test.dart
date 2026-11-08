import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/data/models/event_model.dart';
import 'package:planflow/data/repositories/event_repository.dart';
import 'package:planflow/onboarding/real_ui_guide/guide_contract.dart';
import 'package:planflow/onboarding/real_ui_guide/guide_route_recovery.dart';
import 'package:planflow/onboarding/real_ui_guide/guide_scope.dart';
import 'package:planflow/onboarding/real_ui_guide/guide_host.dart';
import 'package:planflow/screens/calendar/calendar_screen.dart';
import 'package:planflow/services/event_prefetch_service.dart';
import 'package:planflow/widgets/guided_anchor.dart';
import 'package:shared_preferences/shared_preferences.dart';

// H4/H5 reproduction tests. Assertions state the EXPECTED (consistent)
// behaviour; a failing assertion means the hypothesis is reproduced.

class _ReadOnlyCoordinator implements GuideCoordinator {
  _ReadOnlyCoordinator(GuideSnapshot s) : state = ValueNotifier(s);
  @override
  final ValueNotifier<GuideSnapshot> state;
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('no guide actions during recovery');
}

GuideSnapshot _snap(GuideStep step, {DateTime? savedLocalDate}) =>
    GuideSnapshot(
        uid: 'u',
        version: 'v',
        revision: 9,
        serverRevision: 5,
        sessionId: 'session',
        createdEventId: 'saved',
        step: step,
        run: GuideRun.active,
        savedLocalDate: savedLocalDate,
        // banned-ok: Pinned date for a calendar boundary assertion.
        expectedUpdatedStartLocal: DateTime(2030, 1, 2, 16));

// --- calendar harness (same as real_ui_guide_calendar_anchor_test.dart) ---
class _Guide implements GuideCoordinator {
  @override
  final state = ValueNotifier(GuideSnapshot(
      uid: 'u',
      revision: 1,
      serverRevision: 1,
      version: 'v',
      sessionId: 's',
      run: GuideRun.active,
      step: GuideStep.savedDetail,
      createdEventId: 'saved',
      // banned-ok: Pinned date for a calendar boundary assertion.
      savedLocalDate: DateTime(2030, 1, 2)));
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Repo extends EventRepository {
  List<EventModel> rows = [];
  @override
  Future<List<EventModel>> listEvents({String? userId}) async => rows;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

String _ymd(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// Calendar date of [instant] in KST (UTC+9), independent of host timezone.
String _kstYmd(DateTime instant) =>
    _ymd(instant.toUtc().add(const Duration(hours: 9)));

Future<GuideRouteRecovery?> _load(GuideSnapshot s, List<EventModel> events) {
  final c = _ReadOnlyCoordinator(s);
  return GuideRouteRecovery.load(
      coordinator: c,
      currentUid: () => 'u',
      attachedToRoute: () => true,
      read: (_, __) async => events);
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    EventPrefetchService().invalidate();
  });

  group('H4 multi-day identity: recovery vs calendar anchor', () {
    final multiDay = EventModel(
        id: 'saved',
        userId: 'u',
        title: 'Late saved row',
        isMultiDay: true,
        // banned-ok: Pinned date for a calendar boundary assertion.
        startAt: DateTime(2030, 1, 2, 23, 30),
        // banned-ok: Pinned date for a calendar boundary assertion.
        endAt: DateTime(2030, 1, 3, 0, 30));

    testWidgets('calendar side: multi-day saved row receives the anchor',
        (tester) async {
      final repo = _Repo()..rows = [multiDay];
      await tester.pumpWidget(GuideScope(
          coordinator: _Guide(),
          child: MaterialApp(
              home: CalendarScreen(
                  eventRepository: repo,
                  userId: 'u',
                  suppressInitialDaySheet: true))));
      await tester.pumpAndSettle();
      expect(
          find.byWidgetPredicate(
              (w) => w is GuidedAnchor && w.id == 'calendar.saved',
              skipOffstage: false),
          findsOneWidget);
    });

    test('recovery side: same multi-day row must not be rejected as identity '
        'issue (calendar accepts it)', () async {
      // Expected: consistent with calendar -> recovery request is produced.
      // Actual (H4): StateError bound_event_missing_duplicate_or_foreign.
      Object? error;
      GuideRouteRecovery? r;
      try {
        r = await _load(_snap(GuideStep.savedDetail,
            // banned-ok: Pinned date for a calendar boundary assertion.
            savedLocalDate: DateTime(2030, 1, 2)), [multiDay]);
      } catch (e) {
        error = e;
      }
      expect(error, isNull,
          reason: 'H4: calendar anchors multi-day saved row but recovery '
              'rejects it: $error');
      expect(r, isNotNull);
    });
  });

  group('H5 savedLocalDate timezone in recovery location', () {
    // Both strings describe the same instant across the UTC date boundary.
    const kstIso = '2030-01-02T01:30:00+09:00';
    const utcIso = '2030-01-01T16:30:00Z';
    final eventInstant = DateTime.parse(kstIso);
    final expectedDate = '2030-01-02';

    test('sanity: KST local date of the instant is 2030-01-02', () {
      expect(_kstYmd(eventInstant), expectedDate);
    });

    test('local-saved path: savedLocalDate = EventModel.startAt parsed from '
        'offset string (guide_coordinator.dart:255 uses persistedEvent.startAt)',
        () async {
      final persisted = EventModel.fromJson({
        'id': 'saved',
        'user_id': 'u',
        'title': 't',
        'start_at': kstIso,
      });
      final r = GuideRouteRecovery(
          _ReadOnlyCoordinator(_snap(GuideStep.savedDetail,
              savedLocalDate: persisted.startAt)),
          _snap(GuideStep.savedDetail, savedLocalDate: persisted.startAt),
          persisted);
      expect(r.location, '/calendar?date=$expectedDate',
          reason: 'H5(local): startAt isUtc=${persisted.startAt?.isUtc} '
              'value=${persisted.startAt}');
    });

    test('server path: saved_local_date offset and UTC strings via '
        'DateTime.tryParse (grant service _readDate)', () {
      for (final input in [kstIso, utcIso]) {
        final parsed = DateTime.tryParse(input)!;
        final s = _snap(GuideStep.savedDetail, savedLocalDate: parsed);
        final r = GuideRouteRecovery(
          _ReadOnlyCoordinator(s),
          s,
          const EventModel(id: 'saved', userId: 'u', title: 't'),
        );
        expect(r.location, '/calendar?date=$expectedDate',
            reason: 'H5(server): input=$input');
      }
    });

    test('server path: date-only saved_local_date string stays on that date',
        () {
      final parsed = DateTime.tryParse(expectedDate)!;
      final s = _snap(GuideStep.savedDetail, savedLocalDate: parsed);
      final r = GuideRouteRecovery(
          _ReadOnlyCoordinator(s), s, const EventModel(id: 'saved', userId: 'u', title: 't'));
      expect(r.location, '/calendar?date=$expectedDate');
    });
  });
}
