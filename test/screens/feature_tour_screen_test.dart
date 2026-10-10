import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/l10n/app_localizations.dart';
import 'package:planflow/screens/onboarding/feature_tour_screen.dart';
import 'package:planflow/services/feature_tour_service.dart';

class _MemoryFeatureTourStore extends FeatureTourStore {
  int markCalls = 0;
  int failuresLeft = 0;
  Completer<void>? pending;
  bool saved = false;

  /// When true, markCompleted returns normally without persisting anything,
  /// mirroring the production store swallowing unavailable-prefs/setBool
  /// errors.
  bool silentFail = false;

  /// When true, shouldShow throws, mirroring a probe read error.
  bool probeThrows = false;

  @override
  Future<bool> shouldShow() async {
    if (probeThrows) {
      throw StateError('probe failed');
    }
    return !saved;
  }

  @override
  Future<void> markCompleted() async {
    markCalls++;
    final gate = pending;
    if (gate != null) {
      await gate.future;
    }
    if (failuresLeft > 0) {
      failuresLeft--;
      throw StateError('write failed');
    }
    if (!silentFail) {
      saved = true;
    }
  }

  @override
  Future<bool> shouldShowTip(String tipId) async => true;

  @override
  Future<void> markTipShown(String tipId) async {}
}

/// Mirrors the in-widget stamp format: MM/dd HH:mm (24h).
String _stamp(DateTime time) {
  String two(int value) => value.toString().padLeft(2, '0');
  return '${two(time.month)}/${two(time.day)} ${two(time.hour)}:${two(time.minute)}';
}

Future<AppLocalizations> _pumpTour(
  WidgetTester tester, {
  required FeatureTourScreen screen,
  TargetPlatform platform = TargetPlatform.android,
  bool smallViewport = false,
  bool presentAsRoute = false,
}) async {
  if (smallViewport) {
    tester.view.physicalSize = const Size(320, 560);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('en'),
      theme: ThemeData(platform: platform),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(alwaysUse24HourFormat: true),
        child: child!,
      ),
      home: presentAsRoute ? const Scaffold() : screen,
    ),
  );
  if (presentAsRoute) {
    Navigator.of(tester.element(find.byType(Scaffold))).push(
      MaterialPageRoute<void>(builder: (_) => screen),
    );
    await tester.pumpAndSettle();
  }
  return AppLocalizations.of(tester.element(find.byType(FeatureTourScreen)));
}

MaterialLocalizations _materialL10n(WidgetTester tester) =>
    MaterialLocalizations.of(tester.element(find.byType(FeatureTourScreen)));

/// Scrolls [finder] into view (as a user would) before tapping it, so a tap
/// can never silently land on the footer or be clipped.
Future<void> _tapVisible(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
}

Future<void> _createSample(
  WidgetTester tester, {
  String title = 'Dentist',
}) async {
  await tester.enterText(
      find.byKey(const ValueKey('feature-tour-title-field')), title);
  await tester.pumpAndSettle();
  // Dismiss the keyboard like a user would, so layout is back to normal.
  FocusManager.instance.primaryFocus?.unfocus();
  await tester.pumpAndSettle();
  await _tapVisible(
      tester, find.byKey(const ValueKey('feature-tour-create-button')));
  await tester.pump();
}

void main() {
  testWidgets('steps flow: explicit create, quick edit, live preview, finish',
      (tester) async {
    final store = _MemoryFeatureTourStore();
    final base = DateTime.now();
    var done = false;
    final l10n = await _pumpTour(
      tester,
      screen: FeatureTourScreen(
        store: store,
        onCompleted: () => done = true,
        nowProvider: () => base,
      ),
    );

    // Step 1: next stays disabled until the sample is explicitly created.
    expect(find.text(l10n.featureTourCreateTitle), findsOneWidget);
    final next = find.byKey(const ValueKey('feature-tour-next-button'));
    expect(tester.widget<FilledButton>(next).onPressed, isNull);
    await _createSample(tester);
    expect(tester.widget<FilledButton>(next).onPressed, isNotNull);
    expect(find.text(l10n.featureTourSample), findsOneWidget);

    // Step 2: quick +30 minutes edit, then an explicit confirm.
    await tester.tap(next);
    await tester.pumpAndSettle();
    expect(find.text(l10n.featureTourEditTitle), findsOneWidget);
    final draft = DateTime(base.year, base.month, base.day, base.hour + 1);
    final afterThirty = draft.add(const Duration(minutes: 30));
    expect(find.text(_stamp(draft)), findsOneWidget);
    await _tapVisible(
        tester, find.byKey(const ValueKey('feature-tour-plus-30-button')));
    await tester.pump();
    expect(find.text(_stamp(draft)), findsNothing);
    expect(find.text(_stamp(afterThirty)), findsOneWidget);
    await _tapVisible(
        tester, find.byKey(const ValueKey('feature-tour-confirm-time-button')));
    await tester.pump();
    expect(find.byIcon(Icons.check_circle_outline), findsWidgets);

    // Step 3: live prep/departure preview of the example values.
    await tester.tap(next);
    await tester.pumpAndSettle();
    expect(find.text(l10n.featureTourPreviewTitle), findsOneWidget);
    expect(find.text(l10n.featureTourPrep), findsOneWidget);
    expect(find.text(l10n.featureTourDeparture), findsOneWidget);
    expect(
      find.text(
        _stamp(afterThirty.subtract(const Duration(minutes: 45))),
      ),
      findsOneWidget,
    );
    expect(
      find.text(
        _stamp(afterThirty.subtract(const Duration(minutes: 30))),
      ),
      findsOneWidget,
    );
    expect(find.text(l10n.featureTourSample), findsOneWidget);
    expect(store.saved, isFalse);

    // Finishing the last step persists exactly once.
    await tester.tap(next);
    await tester.pump();
    expect(store.saved, isTrue);
    expect(done, isTrue);
    expect(store.markCalls, 1);
  });

  testWidgets('preview crosses midnight for a sample right after 00:00',
      (tester) async {
    final store = _MemoryFeatureTourStore();
    final now = DateTime.now();
    // Late evening base (relative, no hardcoded calendar date): the default
    // draft (next full hour) lands exactly on midnight of the next day.
    final base = DateTime(now.year, now.month, now.day, 23, 40);
    final l10n = await _pumpTour(
      tester,
      screen: FeatureTourScreen(store: store, nowProvider: () => base),
    );
    await _createSample(tester);
    await tester.tap(find.byKey(const ValueKey('feature-tour-next-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('feature-tour-next-button')));
    await tester.pumpAndSettle();

    // Departure = sample - 30 min rolls back to 23:30 of the previous day;
    // prep = sample - 45 min rolls back to 23:15 of the previous day.
    expect(find.text(_stamp(DateTime(base.year, base.month, base.day, 23, 30))),
        findsOneWidget);
    expect(find.text(_stamp(DateTime(base.year, base.month, base.day, 23, 15))),
        findsOneWidget);
    expect(find.text(l10n.featureTourPrep), findsOneWidget);
    expect(find.text(l10n.featureTourDeparture), findsOneWidget);
  });

  testWidgets('time picker confirm applies and cancel preserves the value',
      (tester) async {
    final store = _MemoryFeatureTourStore();
    final base = DateTime.now();
    await _pumpTour(
      tester,
      screen: FeatureTourScreen(store: store, nowProvider: () => base),
    );
    await _createSample(tester);
    await tester.tap(find.byKey(const ValueKey('feature-tour-next-button')));
    await tester.pumpAndSettle();

    final draft = DateTime(base.year, base.month, base.day, base.hour + 1);
    final newHour = (draft.hour + 5) % 24; // never equals the shown hour
    final ml = _materialL10n(tester);

    // Apply path via the text-input mode (24h forced by the harness): type a
    // known relative hour/minute into the hour and minute fields.
    await _tapVisible(
        tester, find.byKey(const ValueKey('feature-tour-pick-time-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip(ml.inputTimeModeButtonLabel));
    await tester.pumpAndSettle();
    final fields = find.descendant(
        of: find.byType(Dialog), matching: find.byType(TextField));
    expect(fields, findsNWidgets(2));
    await tester.enterText(fields.at(0), newHour.toString().padLeft(2, '0'));
    await tester.pumpAndSettle();
    await tester.enterText(fields.at(1), '50');
    await tester.pumpAndSettle();
    await tester.tap(find.text(ml.okButtonLabel));
    await tester.pumpAndSettle();
    final picked = DateTime(draft.year, draft.month, draft.day, newHour, 50);
    expect(find.text(_stamp(picked)), findsOneWidget);

    // Cancel path preserves the confirmed value.
    await _tapVisible(
        tester, find.byKey(const ValueKey('feature-tour-pick-time-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.text(ml.cancelButtonLabel));
    await tester.pumpAndSettle();
    expect(find.text(_stamp(picked)), findsOneWidget);
  });

  testWidgets('date picker cancel preserves the draft on the create step',
      (tester) async {
    final store = _MemoryFeatureTourStore();
    final base = DateTime.now();
    final l10n = await _pumpTour(
      tester,
      screen: FeatureTourScreen(store: store, nowProvider: () => base),
    );
    final draft = DateTime(base.year, base.month, base.day, base.hour + 1);
    await _tapVisible(
        tester, find.byKey(const ValueKey('feature-tour-pick-date-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.text(_materialL10n(tester).cancelButtonLabel));
    await tester.pumpAndSettle();
    // Both sample rows on step 1 still show the untouched draft stamp.
    expect(find.text(_stamp(draft)), findsWidgets);
    expect(find.text(l10n.featureTourTitleRequired), findsNothing);
  });

  testWidgets('empty title blocks the explicit create', (tester) async {
    final store = _MemoryFeatureTourStore();
    final base = DateTime.now();
    final l10n = await _pumpTour(
      tester,
      screen: FeatureTourScreen(store: store, nowProvider: () => base),
    );
    await _tapVisible(
        tester, find.byKey(const ValueKey('feature-tour-create-button')));
    await tester.pump();
    expect(find.text(l10n.featureTourTitleRequired), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(
              find.byKey(const ValueKey('feature-tour-next-button')))
          .onPressed,
      isNull,
    );
    expect(store.markCalls, 0);
  });

  testWidgets('restart resets draft, step, and controllers without writes',
      (tester) async {
    final store = _MemoryFeatureTourStore();
    final base = DateTime.now();
    final l10n = await _pumpTour(
      tester,
      screen: FeatureTourScreen(store: store, nowProvider: () => base),
    );
    final draft = DateTime(base.year, base.month, base.day, base.hour + 1);
    await _createSample(tester);
    await tester.tap(find.byKey(const ValueKey('feature-tour-next-button')));
    await tester.pumpAndSettle();
    await _tapVisible(
        tester, find.byKey(const ValueKey('feature-tour-plus-30-button')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('feature-tour-next-button')));
    await tester.pumpAndSettle();
    expect(find.text(l10n.featureTourPreviewTitle), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('feature-tour-restart-button')));
    await tester.pumpAndSettle();

    expect(find.text(l10n.featureTourCreateTitle), findsOneWidget);
    expect(find.text(l10n.featureTourRestarted), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(
              find.byKey(const ValueKey('feature-tour-next-button')))
          .onPressed,
      isNull,
    );
    final field = tester.widget<TextField>(
        find.byKey(const ValueKey('feature-tour-title-field')));
    expect(field.controller!.text, isEmpty);
    // Draft fell back to the untouched default (the +30 edit is gone).
    expect(find.text(_stamp(draft)), findsWidgets);
    expect(find.text(_stamp(draft.add(const Duration(minutes: 30)))),
        findsNothing);
    expect(store.markCalls, 0);
    expect(store.saved, isFalse);
  });

  testWidgets(
      'required first launch keeps skip visible and back does not complete',
      (tester) async {
    final store = _MemoryFeatureTourStore();
    final base = DateTime.now();
    var done = false;
    await _pumpTour(
      tester,
      screen: FeatureTourScreen(
        store: store,
        onCompleted: () => done = true,
        requireFinalConfirmation: true,
        nowProvider: () => base,
      ),
    );
    expect(
        find.byKey(const ValueKey('feature-tour-skip-button')), findsOneWidget);
    expect(find.byKey(const ValueKey('feature-tour-restart-button')),
        findsOneWidget);

    // System back is a no-op: no implicit completion, no route pop.
    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(find.byType(FeatureTourScreen), findsOneWidget);
    expect(store.markCalls, 0);
    expect(store.saved, isFalse);

    // Explicit skip persists exactly once and hands over.
    await tester.tap(find.byKey(const ValueKey('feature-tour-skip-button')));
    await tester.pump();
    expect(store.markCalls, 1);
    expect(store.saved, isTrue);
    expect(done, isTrue);
  });

  testWidgets('optional tour ignores system back and pops after explicit skip',
      (tester) async {
    final store = _MemoryFeatureTourStore();
    final base = DateTime.now();
    await _pumpTour(
      tester,
      screen: FeatureTourScreen(store: store, nowProvider: () => base),
      presentAsRoute: true,
    );
    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(find.byType(FeatureTourScreen), findsOneWidget);
    expect(store.saved, isFalse);

    await tester.tap(find.byKey(const ValueKey('feature-tour-skip-button')));
    await tester.pumpAndSettle();
    expect(store.saved, isTrue);
    expect(find.byType(FeatureTourScreen), findsNothing);
  });

  testWidgets('save failure shows inline retry; retry persists once more',
      (tester) async {
    final store = _MemoryFeatureTourStore();
    store.failuresLeft = 1;
    final base = DateTime.now();
    var done = false;
    final l10n = await _pumpTour(
      tester,
      screen: FeatureTourScreen(
        store: store,
        onCompleted: () => done = true,
        nowProvider: () => base,
      ),
    );
    await tester.tap(find.byKey(const ValueKey('feature-tour-skip-button')));
    await tester.pump();
    expect(store.saved, isFalse);
    expect(done, isFalse);
    expect(find.text(l10n.featureTourSaveFailed), findsOneWidget);
    final retry = find.byKey(const ValueKey('feature-tour-save-retry-button'));
    expect(retry, findsOneWidget);

    await tester.tap(retry);
    await tester.pump();
    expect(store.markCalls, 2);
    expect(store.saved, isTrue);
    expect(done, isTrue);
    expect(find.text(l10n.featureTourSaveFailed), findsNothing);
  });

  testWidgets(
      'silent write failure reports no completion and retries until saved',
      (tester) async {
    final store = _MemoryFeatureTourStore();
    store.silentFail = true;
    final base = DateTime.now();
    var done = false;
    final l10n = await _pumpTour(
      tester,
      screen: FeatureTourScreen(
        store: store,
        onCompleted: () => done = true,
        nowProvider: () => base,
      ),
    );
    await tester.tap(find.byKey(const ValueKey('feature-tour-skip-button')));
    await tester.pump();
    // markCompleted returned normally, but nothing was persisted: the probe
    // still reports the tour as pending, so no completion and no dismissal.
    expect(store.markCalls, 1);
    expect(store.saved, isFalse);
    expect(done, isFalse);
    expect(find.byType(FeatureTourScreen), findsOneWidget);
    expect(find.text(l10n.featureTourSaveFailed), findsOneWidget);

    // Once a retry really persists, shouldShow reads back false and the
    // tour completes.
    store.silentFail = false;
    await _tapVisible(
        tester, find.byKey(const ValueKey('feature-tour-save-retry-button')));
    await tester.pump();
    expect(store.markCalls, 2);
    expect(store.saved, isTrue);
    expect(done, isTrue);
    expect(find.text(l10n.featureTourSaveFailed), findsNothing);
  });

  testWidgets('probe error withholds completion until a retry verifies',
      (tester) async {
    final store = _MemoryFeatureTourStore();
    store.probeThrows = true;
    final base = DateTime.now();
    var done = false;
    final l10n = await _pumpTour(
      tester,
      screen: FeatureTourScreen(
        store: store,
        onCompleted: () => done = true,
        nowProvider: () => base,
      ),
    );
    await tester.tap(find.byKey(const ValueKey('feature-tour-skip-button')));
    await tester.pump();
    // The write succeeded, but the verification probe threw: keep the
    // inline retry instead of reporting completion.
    expect(store.markCalls, 1);
    expect(store.saved, isTrue);
    expect(done, isFalse);
    expect(find.byType(FeatureTourScreen), findsOneWidget);
    expect(find.text(l10n.featureTourSaveFailed), findsOneWidget);

    store.probeThrows = false;
    await _tapVisible(
        tester, find.byKey(const ValueKey('feature-tour-save-retry-button')));
    await tester.pump();
    expect(store.markCalls, 2);
    expect(store.saved, isTrue);
    expect(done, isTrue);
    expect(find.text(l10n.featureTourSaveFailed), findsNothing);
  });

  testWidgets('duplicate skip while a save is in flight writes only once',
      (tester) async {
    final store = _MemoryFeatureTourStore();
    store.pending = Completer<void>();
    final base = DateTime.now();
    var done = false;
    await _pumpTour(
      tester,
      screen: FeatureTourScreen(
        store: store,
        onCompleted: () => done = true,
        nowProvider: () => base,
      ),
    );
    await tester.tap(find.byKey(const ValueKey('feature-tour-skip-button')));
    await tester.pump();
    expect(store.markCalls, 1);

    // Second tap is ignored while the first save is still running.
    await tester.tap(find.byKey(const ValueKey('feature-tour-skip-button')));
    await tester.pump();
    expect(
      tester
          .widget<TextButton>(
              find.byKey(const ValueKey('feature-tour-skip-button')))
          .onPressed,
      isNull,
    );
    expect(store.markCalls, 1);

    store.pending!.complete();
    await tester.pump();
    expect(store.saved, isTrue);
    expect(done, isTrue);
    expect(store.markCalls, 1);
  });

  testWidgets('android and ios themes render; small viewport stays usable',
      (tester) async {
    final base = DateTime.now();
    final l10nIos = await _pumpTour(
      tester,
      screen: FeatureTourScreen(
        store: _MemoryFeatureTourStore(),
        nowProvider: () => base,
      ),
      platform: TargetPlatform.iOS,
    );
    expect(find.text(l10nIos.featureTourCreateTitle), findsOneWidget);
    expect(
        find.byKey(const ValueKey('feature-tour-skip-button')), findsOneWidget);

    final store = _MemoryFeatureTourStore();
    final l10n = await _pumpTour(
      tester,
      screen: FeatureTourScreen(store: store, nowProvider: () => base),
      platform: TargetPlatform.android,
      smallViewport: true,
    );
    await _createSample(tester);
    final next = find.byKey(const ValueKey('feature-tour-next-button'));
    expect(tester.widget<FilledButton>(next).onPressed, isNotNull);
    await tester.tap(next);
    await tester.pumpAndSettle();
    expect(find.text(l10n.featureTourEditTitle), findsOneWidget);
  });
}
