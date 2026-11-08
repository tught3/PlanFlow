import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:planflow/onboarding/real_ui_guide/guide_contract.dart';
import 'package:planflow/onboarding/real_ui_guide/guide_host.dart';
import 'package:planflow/onboarding/real_ui_guide/guide_providers.dart';
import 'package:planflow/providers/auth_provider.dart';
import 'package:planflow/widgets/guided_anchor.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Reproduces hypothesis H2: tapping the home "guide-bound-resume" button
/// (GuideStep.savedDetail) gives no visible feedback / can stay disabled when
/// the bound-event read does not produce a usable recovery.
///
/// The real widget is driven end to end. The only fake is the HTTP transport
/// under the real Supabase client (the host builds EventRepository.supabase()
/// itself, so the read cannot be injected any other way).

class _Coordinator implements GuideCoordinator {
  _Coordinator(GuideSnapshot s) : state = ValueNotifier(s);
  @override
  final ValueNotifier<GuideSnapshot> state;
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('no guide actions during recovery');
}

GuideSnapshot _snapshot() => GuideSnapshot(
    uid: 'u',
    version: 'v',
    revision: 9,
    serverRevision: 5,
    sessionId: 'session',
    createdEventId: 'bound',
    step: GuideStep.savedDetail,
    run: GuideRun.active,
    // banned-ok: Fixed event fixture for the guide assertion.
    savedLocalDate: DateTime(2026, 10, 20),
    // banned-ok: Fixed event fixture for the guide assertion.
    expectedUpdatedStartLocal: DateTime(2026, 10, 20, 16));

const _baseTexts = <String>{
  '안내할 실제 화면을 기다리고 있어요. 화면을 확인하거나 안내를 건너뛸 수 있어요.',
  '안내 계속',
  '안내 건너뛰기',
  'home microphone off',
};

// Words a user must never see in a guide message.
const _techTerms = <String>[
  'revision', 'uid', 'session', 'StateError', 'Exception', 'null', 'fence',
  'bound_event', 'QA', 'coordinator', 'recovery',
];

Future<http.Response> Function(http.Request)? _handler;

Map<String, dynamic> _row() => {
      'id': 'bound',
      'user_id': 'u',
      'title': 'saved',
      'start_at': '2026-10-20T07:00:00.000Z',
      'end_at': '2026-10-20T08:00:00.000Z',
    };

http.Response _ok() => http.Response(jsonEncode(_row()), 200, headers: {
      'content-type': 'application/json; charset=utf-8',
    });

Set<String> _texts(WidgetTester tester) => {
      for (final w in tester.widgetList<Text>(find.byType(Text)))
        if (w.data != null) w.data!,
    };

Set<String> _newTexts(WidgetTester tester) =>
    _texts(tester).difference(_baseTexts);

bool _resumeEnabled(WidgetTester tester) {
  final f = find.byKey(const ValueKey('guide-bound-resume'));
  if (f.evaluate().isEmpty) return false;
  final b = tester.widget<TextButton>(f);
  return b.onPressed != null;
}

/// Notifier that flips the guide revision on the Nth `value` read after being
/// armed. Used to hit the narrow gap between GuideRouteRecovery.load() final
/// check and the host's recovery.isCurrent() check.
class _FlipNotifier extends ValueNotifier<GuideSnapshot> {
  _FlipNotifier(super.v);
  int? flipOnRead;
  int reads = 0;
  bool flipped = false;
  @override
  GuideSnapshot get value {
    final v = super.value;
    if (flipOnRead != null && !flipped) {
      reads++;
      if (reads >= flipOnRead!) {
        flipped = true;
        return v.copyWith(revision: v.revision + 1);
      }
    }
    return v;
  }
}

class _FlipCoordinator implements GuideCoordinator {
  _FlipCoordinator(GuideSnapshot s) : state = _FlipNotifier(s);
  @override
  final _FlipNotifier state;
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('no guide actions during recovery');
}

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await Supabase.initialize(
      url: 'https://qa.example',
      anonKey: 'qa-anon-key',
      httpClient: MockClient((req) async {
        final h = _handler;
        if (h == null) return http.Response('{}', 500);
        final r = await h(req);
        // postgrest dereferences response.request; MockClient responses
        // built without it crash the parser (harness-only concern).
        return http.Response(r.body, r.statusCode,
            request: req, headers: r.headers);
      }),
      authOptions: const FlutterAuthClientOptions(
        detectSessionInUri: false,
        autoRefreshToken: false,
      ),
    );
  });

  setUp(() {
    authProvider.setUser('u');
    _handler = null;
  });
  tearDown(() => authProvider.setUser(null));

  late GoRouter router;

  Future<void> pumpHome(WidgetTester tester, GuideCoordinator c) async {
    router = GoRouter(routes: [
      GoRoute(
          path: '/',
          builder: (_, __) => Scaffold(
                  body: Stack(children: [
                GuidedAnchor(
                    id: 'home.mic',
                    registry: realUiGuideAnchorRegistry,
                    child: const Text('home microphone off')),
                RealUiGuideCoachmark(coordinator: c),
              ]))),
      GoRoute(
          path: '/calendar',
          builder: (_, __) => const Scaffold(body: Text('calendar page'))),
    ]);
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const ValueKey('guide-bound-resume')), findsOneWidget,
        reason: 'harness: fallback panel with resume button must be shown');
    expect(_resumeEnabled(tester), isTrue, reason: 'harness: starts enabled');
  }

  void expectUserFacingFeedback(WidgetTester tester) {
    final fresh = _newTexts(tester);
    final snack = find.byType(SnackBar).evaluate().isNotEmpty;
    expect(fresh.isNotEmpty || snack, isTrue,
        reason: 'no visible feedback after tapping resume; texts=${_texts(tester)}');
    for (final t in fresh) {
      for (final term in _techTerms) {
        expect(t.contains(term), isFalse,
            reason: 'feedback "$t" contains technical term "$term"');
      }
    }
  }

  testWidgets('(a) normal path navigates to /calendar?date=2026-10-20',
      (tester) async {
    final c = _Coordinator(_snapshot());
    addTearDown(c.state.dispose);
    _handler = (_) async => _ok();
    await pumpHome(tester, c);
    await tester.tap(find.byKey(const ValueKey('guide-bound-resume')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
    expect(router.routeInformationProvider.value.uri.toString(),
        '/calendar?date=2026-10-20');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      '(b) load returns null (state changes during read): visible feedback and retry',
      (tester) async {
    final c = _Coordinator(_snapshot());
    addTearDown(c.state.dispose);
    _handler = (_) async {
      // Guide state moves on while the read is in flight.
      c.state.value = c.state.value.copyWith(revision: 10);
      return _ok();
    };
    await pumpHome(tester, c);
    await tester.tap(find.byKey(const ValueKey('guide-bound-resume')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
    // Harness sanity: the read really happened and we stayed on home.
    expect(router.routeInformationProvider.value.uri.toString(), '/');
    expect(_resumeEnabled(tester), isTrue,
        reason: 'button must be tappable again');
    expectUserFacingFeedback(tester);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      '(b2) load returns null (account differs from guide owner): visible feedback',
      (tester) async {
    final c = _Coordinator(_snapshot());
    addTearDown(c.state.dispose);
    var reads = 0;
    _handler = (_) async {
      reads++;
      return _ok();
    };
    await pumpHome(tester, c);
    authProvider.setUser('someone-else');
    await tester.tap(find.byKey(const ValueKey('guide-bound-resume')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
    expect(router.routeInformationProvider.value.uri.toString(), '/');
    expect(reads, 0, reason: 'uid mismatch is rejected before any read');
    expect(_resumeEnabled(tester), isTrue);
    expectUserFacingFeedback(tester);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('(c) read never completes: button not stuck, feedback shown',
      (tester) async {
    final c = _Coordinator(_snapshot());
    addTearDown(c.state.dispose);
    final never = Completer<http.Response>();
    _handler = (_) => never.future;
    await pumpHome(tester, c);
    await tester.tap(find.byKey(const ValueKey('guide-bound-resume')));
    await tester.pump();
    // Disabled while in flight is fine; but after a generous wait it must not
    // remain disabled forever.
    for (var i = 0; i < 60; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    final enabled = _resumeEnabled(tester);
    final fresh = _newTexts(tester);
    // Release the pending request so nothing leaks past the test.
    never.complete(http.Response('{}', 500));
    expect(enabled, isTrue,
        reason: 'resume button still disabled 60s after tap (read has no timeout)');
    expect(fresh.isNotEmpty, isTrue,
        reason: 'no visible feedback 60s after tap; texts=$fresh');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      '(d) isCurrent false after load: visible feedback and retry',
      (tester) async {
    final c = _FlipCoordinator(_snapshot());
    addTearDown(c.state.dispose);
    _handler = (_) async {
      // Arm: reads 1,2 are load()'s two current() checks; read 3 is the
      // host's recovery.isCurrent().
      c.state.flipOnRead = 3;
      return _ok();
    };
    await pumpHome(tester, c);
    await tester.tap(find.byKey(const ValueKey('guide-bound-resume')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
    // Harness sanity: the flip must have happened, and it must have happened
    // at the isCurrent read (3rd), otherwise this is really case (b).
    expect(c.state.flipped, isTrue, reason: 'harness: flip did not trigger');
    expect(c.state.reads, 3,
        reason: 'harness: unexpected extra reads (${c.state.reads})');
    expect(router.routeInformationProvider.value.uri.toString(), '/');
    expect(_resumeEnabled(tester), isTrue);
    expectUserFacingFeedback(tester);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
