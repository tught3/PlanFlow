import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/core/env.dart';
import 'package:planflow/data/models/event_model.dart';
import 'package:planflow/data/repositories/event_repository.dart';
import 'package:planflow/onboarding/real_ui_guide/guide_contract.dart';
import 'package:planflow/onboarding/real_ui_guide/guide_scope.dart';
import 'package:planflow/screens/event/event_detail_screen.dart';
import 'package:planflow/widgets/guided_anchor.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

// H3 repro: guide anchors saved.summary / saved.departure are only registered
// when the detail readback (fetchEvent) succeeds. On readback failure the
// anchors stay unregistered. "documented" tests record current behaviour;
// "expected" tests assert the desired recovery and FAIL while H3 is unfixed.

Finder _anchor(String id) =>
    find.byWidgetPredicate((w) => w is GuidedAnchor && w.id == id);

EventModel _saved() => EventModel(
      id: 'saved-guide',
      userId: 'guide-owner',
      title: 'Saved title',
      // banned-ok: Fixed event fixture for the guide assertion.
      startAt: DateTime(2030, 1, 2, 10),
      location: 'North Station',
    );

Future<_Guide> _pump(WidgetTester tester, EventModel saved,
    {EventRepository? repo}) async {
  final guide = _Guide(savedEventId: saved.id, uid: saved.userId);
  await tester.pumpWidget(MaterialApp(
    home: GuideScope(
      coordinator: guide,
      child: EventDetailScreen(event: saved, eventRepository: repo),
    ),
  ));
  await tester.pumpAndSettle();
  return guide;
}

/// Any recovery path: registered anchor, visible notice, or retry control.
bool _hasVisibleRecovery() {
  return _anchor('saved.summary').evaluate().isNotEmpty ||
      find.text('최신 정보 확인').evaluate().isNotEmpty ||
      find.textContaining('다시').evaluate().isNotEmpty &&
          (find.byType(TextButton).evaluate().isNotEmpty ||
              find.byType(FilledButton).evaluate().isNotEmpty ||
              find.byType(OutlinedButton).evaluate().isNotEmpty) ||
      find.byIcon(Icons.refresh).evaluate().isNotEmpty;
}

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    try {
      Supabase.instance;
    } catch (_) {
      await Supabase.initialize(
        url: 'https://example.com',
        anonKey: 'public-anon-key',
        authOptions: const FlutterAuthClientOptions(
          detectSessionInUri: false,
          autoRefreshToken: false,
        ),
      );
    }
  });

  testWidgets('(a) readback success registers saved.summary and saved.departure',
      (tester) async {
    final saved = _saved();
    await _pump(tester, saved, repo: _Repo.value(saved));
    expect(_anchor('saved.summary'), findsOneWidget);
    expect(_anchor('saved.departure'), findsOneWidget);
    expect(find.text('최신 정보 확인'), findsNothing);
  });

  group('(b) fetchEvent throws', () {
    testWidgets('documented: anchors never registered, no visible feedback',
        (tester) async {
      final saved = _saved();
      await _pump(tester, saved, repo: _Repo.throwing());
      expect(find.text('Saved title'), findsWidgets); // route extra still shown
      expect(_anchor('saved.summary'), findsNothing);
      expect(_anchor('saved.departure'), findsNothing);
      expect(find.text('최신 정보 확인'), findsNothing); // swallowed silently
      expect(find.text('준비·출발 안내 확인'), findsNothing);
    });

    testWidgets('expected: some visible feedback or retry exists',
        (tester) async {
      final saved = _saved();
      await _pump(tester, saved, repo: _Repo.throwing());
      expect(_hasVisibleRecovery(), isTrue,
          reason: 'read failure leaves guide anchors unregistered with no '
              'feedback/retry (H3)');
    });
  });

  group('(c) fetchEvent returns null', () {
    testWidgets('documented: anchors absent; only a passive notice is shown',
        (tester) async {
      final saved = _saved();
      await _pump(tester, saved, repo: _Repo.value(null));
      expect(_anchor('saved.summary'), findsNothing);
      expect(_anchor('saved.departure'), findsNothing);
      expect(find.text('일정을 다시 찾지 못했습니다.'), findsOneWidget);
      expect(find.text('준비·출발 안내 확인'), findsNothing);
    });

    testWidgets('expected: a retry control exists (not only passive text)',
        (tester) async {
      final saved = _saved();
      await _pump(tester, saved, repo: _Repo.value(null));
      expect(find.byIcon(Icons.refresh), findsWidgets,
          reason: 'no retry/refresh control after null readback (H3)');
    });
  });

  group('(d) current user id is null (no injected repository)', () {
    setUp(AppEnv.markSupabaseInitialized);

    testWidgets('documented: early return, anchors absent, no feedback',
        (tester) async {
      final saved = _saved();
      await _pump(tester, saved);
      expect(_anchor('saved.summary'), findsNothing);
      expect(_anchor('saved.departure'), findsNothing);
      expect(find.text('준비·출발 안내 확인'), findsNothing);
      // _loadError is only set when _event == null, so with the route extra
      // present the login notice is NOT shown.
      expect(find.text('로그인 후 일정 정보를 다시 확인할 수 있습니다.'), findsNothing);
    });

    testWidgets('expected: some visible feedback or retry exists',
        (tester) async {
      final saved = _saved();
      await _pump(tester, saved);
      expect(_hasVisibleRecovery(), isTrue,
          reason: 'null uid early-return leaves anchors unregistered with no '
              'feedback (H3)');
    });
  });
}

class _Guide implements GuideCoordinator {
  _Guide({required String savedEventId, required String uid})
      : state = ValueNotifier(GuideSnapshot(
          uid: uid,
          revision: 1,
          serverRevision: 1,
          version: 'real_ui_v1',
          sessionId: 'detail-session',
          run: GuideRun.active,
          step: GuideStep.savedDetail,
          createdEventId: savedEventId,
        ));

  @override
  final ValueNotifier<GuideSnapshot> state;
  @override
  Future<GuideSnapshot> dispatch(GuideSignal signal) async => state.value;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Repo extends EventRepository {
  _Repo.value(this._value) : _throws = false;
  _Repo.throwing()
      : _value = null,
        _throws = true;
  final EventModel? _value;
  final bool _throws;

  @override
  Future<EventModel?> fetchEvent(String eventId, {String? userId}) async {
    if (_throws) throw StateError('readback failed');
    return _value;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
