// Voice-first feature tour screen tests.
//
// SIMULATED VOICE: a scripted fake `VoiceCapture` replaces the microphone
// and the native STT engine. Transcripts are typed test data, never
// acoustic ASR output; the fake's readiness signal models the engine's
// native-ready status. The parser pipeline behind the screen is the REAL
// production one (deterministic parsers), calibrated by a probe run:
//   '내일 오전 9시에 강남역에서 팀장님과 면담' -> 강남역 팀장님과 면담,
//   2026-10-18 09:00 (frozen base 2026-10-17 10:00), departure 08:30,
//   preparation 08:15; '내일 일정 보여줘' -> saved list;
//   '첫 번째 일정 오후 1시로 미뤄줘' -> ordinal 1 -> 13:00, stored
//   departure 12:30 / preparation 12:15, date/title/location preserved.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/l10n/app_localizations.dart';
import 'package:planflow/screens/onboarding/feature_tour_screen.dart';
import 'package:planflow/screens/onboarding/voice_first_tour_voice_capture.dart';
import 'package:planflow/services/feature_tour_service.dart';

/// SIMULATED capture seam (typed transcripts + simulated readiness).
class _ScriptedVoiceCapture implements VoiceCapture {
  int listenCalls = 0;
  int stopCalls = 0;
  int cancelCalls = 0;

  /// When set, the next listen() resolves immediately with this result
  /// (mic permission / silence / unavailable simulation).
  VoiceCaptureResult? immediateResult;

  /// SIMULATED contract violation: cancel does NOT resolve the listen
  /// future, so a late final can still be delivered afterwards. The screen
  /// must drop it via its session token.
  bool leakyCancel = false;

  Completer<VoiceCaptureResult>? _active;
  ValueChanged<String>? _onPartial;
  ValueChanged<bool>? _onReady;
  bool _ready = false;

  bool get hasPendingSession => _active != null && !_active!.isCompleted;

  @override
  bool get isListening => _ready && hasPendingSession;

  @override
  Future<VoiceCaptureResult> listen({
    required ValueChanged<String> onPartial,
    ValueChanged<bool>? onReady,
  }) {
    listenCalls++;
    _onPartial = onPartial;
    _onReady = onReady;
    _ready = false;
    if (immediateResult != null) {
      final result = immediateResult!;
      immediateResult = null;
      return Future<VoiceCaptureResult>.value(result);
    }
    _active = Completer<VoiceCaptureResult>();
    return _active!.future;
  }

  /// Simulates the engine's native-ready status event.
  void emitReady() {
    _ready = true;
    _onReady?.call(true);
  }

  void emitPartial(String text) => _onPartial?.call(text);

  void emitFinal(String text) => _finish(VoiceCaptureResult(text: text));

  /// Delivers a final even though the session was never resolved (leak).
  void leakLateFinal(String text) => _finish(VoiceCaptureResult(text: text));

  void _finish(VoiceCaptureResult result) {
    final completer = _active;
    _active = null;
    _ready = false;
    if (completer != null && !completer.isCompleted) {
      completer.complete(result);
    }
  }

  @override
  Future<void> stop() async {
    stopCalls++;
    // SIMULATED dictation engine: the final arrives through the listen
    // future by itself; tests drive emitFinal for the stop path.
  }

  @override
  Future<void> cancel() async {
    cancelCalls++;
    if (!leakyCancel) {
      _finish(const VoiceCaptureResult(silence: true, message: '취소했어요.'));
    }
  }
}

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

/// Frozen session reference for deterministic relative dates.
// banned-ok: Fixed event fixture for the guide assertion.
final DateTime _base = DateTime(2026, 10, 17, 10, 0);

Future<AppLocalizations> _pumpTour(
  WidgetTester tester, {
  required FeatureTourScreen screen,
  Locale locale = const Locale('en'),
  TargetPlatform platform = TargetPlatform.android,
  bool smallViewport = false,
  double textScale = 1.0,
  bool dark = false,
  bool presentAsRoute = false,
}) async {
  if (smallViewport) {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }
  await tester.pumpWidget(
    // UniqueKey forces a fresh element subtree per pump so a second pump in
    // the same test never reuses the previous screen's State (and its
    // capture seam from initState).
    KeyedSubtree(
      key: UniqueKey(),
      child: MaterialApp(
      locale: locale,
      theme: dark
          ? ThemeData(brightness: Brightness.dark, platform: platform)
          : ThemeData(platform: platform),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          alwaysUse24HourFormat: true,
          textScaler: TextScaler.linear(textScale),
        ),
        child: child!,
      ),
      home: presentAsRoute ? const Scaffold() : screen,
    ),
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

Future<void> _tapVisible(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
}

/// Starts the mic, waits for engine-ready, speaks partial + final
/// (SIMULATED transcripts).
Future<void> _speak(
  WidgetTester tester,
  _ScriptedVoiceCapture capture,
  String finalText, {
  String? partial,
}) async {
  await _tapVisible(tester, find.byKey(const ValueKey('voice-tour-mic-button')));
  await tester.pump();
  capture.emitReady();
  await tester.pump();
  if (partial != null) {
    capture.emitPartial(partial);
    await tester.pump();
  }
  capture.emitFinal(finalText);
  await tester.pumpAndSettle();
}

Finder _finishButton() => find.byKey(const ValueKey('voice-tour-finish'));

void expectFinishEnabled(WidgetTester tester, bool enabled) {
  expect(
    tester.widget<FilledButton>(_finishButton()).onPressed,
    enabled ? isNotNull : isNull,
  );
}

void main() {
  testWidgets(
      'voice-first flow: create -> save -> query -> edit -> save -> open saved '
      'record -> finish persists once',
      (tester) async {
    final store = _MemoryFeatureTourStore();
    final capture = _ScriptedVoiceCapture();
    var done = false;
    final l10n = await _pumpTour(
      tester,
      screen: FeatureTourScreen(
        store: store,
        onCompleted: () => done = true,
        nowProvider: () => _base,
        voiceCapture: capture,
      ),
    );

    // Phase 1: create. Nothing claimed to be listening before engine-ready.
    expect(find.text(l10n.voiceTourPhaseCreateTitle), findsOneWidget);
    expectFinishEnabled(tester, false);
    expect(find.byKey(const ValueKey('voice-tour-text-input')), findsNothing);
    expect(capture.listenCalls, 0);

    await _tapVisible(
        tester, find.byKey(const ValueKey('voice-tour-mic-button')));
    await tester.pump();
    expect(capture.listenCalls, 1);
    expect(find.byKey(const ValueKey('voice-tour-ready')), findsNothing);
    expect(find.text(l10n.voiceTourPreparing), findsOneWidget);

    capture.emitReady();
    await tester.pump();
    expect(find.byKey(const ValueKey('voice-tour-ready')), findsOneWidget);

    // Partial caption is display-only: never parsed, never saved.
    capture.emitPartial('내일 오전');
    await tester.pump();
    expect(find.byKey(const ValueKey('voice-tour-transcript')),
        findsOneWidget);
    expect(find.text('내일 오전'), findsOneWidget);
    expect(find.byKey(const ValueKey('voice-tour-create-preview')),
        findsNothing);
    expect(find.byKey(const ValueKey('voice-tour-save-create')), findsNothing);

    // Final transcript -> structured preview (still unsaved).
    capture.emitFinal('내일 오전 9시에 강남역에서 팀장님과 면담');
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('voice-tour-create-preview')),
        findsOneWidget);
    expect(find.text('강남역 팀장님과 면담'), findsOneWidget);
    expect(find.text('10/18'), findsOneWidget);
    expect(find.text('09:00'), findsOneWidget);
    expect(find.text('강남역'), findsOneWidget);
    expect(store.saved, isFalse);

    // Explicit save commits exactly once and advances to the query phase.
    await _tapVisible(
        tester, find.byKey(const ValueKey('voice-tour-save-create')));
    await tester.pumpAndSettle();
    expect(find.text(l10n.voiceTourPhaseQueryTitle), findsOneWidget);
    expect(find.byKey(const ValueKey('voice-tour-results')), findsNothing);
    expectFinishEnabled(tester, false);

    // Phase 2: query returns the actually saved record, visibly ordered.
    await _speak(
      tester,
      capture,
      '내일 일정 보여줘',
      partial: '내일 일정',
    );
    expect(find.byKey(const ValueKey('voice-tour-results')), findsOneWidget);
    expect(find.byKey(const ValueKey('voice-tour-result-1')), findsOneWidget);
    expect(find.text('1. '), findsOneWidget);
    expect(
      tester.widget<Text>(
          find.byKey(const ValueKey('voice-tour-result-title-1'))).data,
      '강남역 팀장님과 면담',
    );
    expect(
      tester.widget<Text>(
          find.byKey(const ValueKey('voice-tour-result-date-1'))).data,
      '10/18',
    );
    expect(
      tester.widget<Text>(
          find.byKey(const ValueKey('voice-tour-result-time-1'))).data,
      '09:00',
    );
    expect(
      tester.widget<Text>(
          find.byKey(const ValueKey('voice-tour-result-location-1'))).data,
      '강남역',
    );
    // Guided advance to the edit phase with the list still rendered.
    expect(find.text(l10n.voiceTourPhaseEditTitle), findsOneWidget);

    // Phase 3: spoken ordinal edit previews old 09:00 -> new 13:00.
    await _speak(
      tester,
      capture,
      '첫 번째 일정 오후 1시로 미뤄줘',
      partial: '첫 번째',
    );
    expect(find.byKey(const ValueKey('voice-tour-edit-preview')), findsOneWidget);
    expect(find.text('10/18 09:00'), findsOneWidget);
    expect(find.text('13:00'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('voice-tour-edit-preview')),
        matching: find.text('강남역 팀장님과 면담'),
      ),
      findsOneWidget,
    );
    expectFinishEnabled(tester, false);

    // Explicit edit save: title/date/place preserved, list invalidated.
    await _tapVisible(
        tester, find.byKey(const ValueKey('voice-tour-save-edit')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('voice-tour-results')), findsNothing);
    expect(find.byKey(const ValueKey('voice-tour-open-updated')),
        findsOneWidget);
    expectFinishEnabled(tester, false); // saved detail not viewed yet

    // Phase 4: open the SAME saved record and read the stored values.
    await _tapVisible(
        tester, find.byKey(const ValueKey('voice-tour-open-updated')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('voice-tour-detail')), findsOneWidget);
    expect(find.byKey(const ValueKey('voice-tour-detail-event-1')),
        findsOneWidget);
    expect(
        find.byKey(const ValueKey('voice-tour-detail-title')),
        findsNWidgets(1));
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('voice-tour-detail-event-1')),
        matching: find.text('강남역 팀장님과 면담'),
      ),
      findsOneWidget,
    );
    expect(
      tester.widget<Text>(
          find.byKey(const ValueKey('voice-tour-detail-date'))).data,
      '10/18',
    );
    expect(
      tester.widget<Text>(
          find.byKey(const ValueKey('voice-tour-detail-event-time'))).data,
      '13:00',
    );
    expect(
      tester.widget<Text>(
          find.byKey(const ValueKey('voice-tour-detail-location'))).data,
      '강남역',
    );
    expect(
      tester.widget<Text>(
          find.byKey(const ValueKey('voice-tour-detail-departure'))).data,
      '10/18 12:30',
    );
    expect(
      tester.widget<Text>(
          find.byKey(const ValueKey('voice-tour-detail-preparation'))).data,
      '10/18 12:15',
    );
    expect(find.text(l10n.voiceTourExampleNote), findsOneWidget);
    expectFinishEnabled(tester, true);

    // Finish persists exactly once and hands over.
    await _tapVisible(tester, _finishButton());
    await tester.pumpAndSettle();
    expect(store.markCalls, 1);
    expect(store.saved, isTrue);
    expect(done, isTrue);
  });

  testWidgets('typed fallback only after explicit selection; same pipeline',
      (tester) async {
    final store = _MemoryFeatureTourStore();
    final capture = _ScriptedVoiceCapture();
    final l10n = await _pumpTour(
      tester,
      screen: FeatureTourScreen(
        store: store,
        nowProvider: () => _base,
        voiceCapture: capture,
      ),
    );

    // Text input hidden until the user explicitly selects text mode.
    expect(find.byKey(const ValueKey('voice-tour-text-input')), findsNothing);
    await _tapVisible(tester, find.byKey(const ValueKey('voice-tour-text-mode')));
    await tester.pumpAndSettle();

    final field = find.byKey(const ValueKey('voice-tour-text-input'));
    expect(field, findsOneWidget);
    expect(
      tester.widget<TextField>(field).controller!.text,
      isEmpty, // never prefilled
    );
    expect(find.text(l10n.voiceTourTextLabel), findsOneWidget);

    await tester.enterText(field, '내일 오전 9시에 강남역에서 팀장님과 면담');
    await tester.pump();
    await _tapVisible(
        tester, find.byKey(const ValueKey('voice-tour-text-submit')));
    await tester.pumpAndSettle();

    // Identical parser pipeline: same preview as the voice path, and the
    // microphone was never started.
    expect(capture.listenCalls, 0);
    expect(find.byKey(const ValueKey('voice-tour-create-preview')),
        findsOneWidget);
    expect(find.text('강남역 팀장님과 면담'), findsOneWidget);
    expect(find.text('09:00'), findsOneWidget);

    await _tapVisible(
        tester, find.byKey(const ValueKey('voice-tour-save-create')));
    await tester.pumpAndSettle();
    expect(find.text(l10n.voiceTourPhaseQueryTitle), findsOneWidget);
    expect(store.saved, isFalse);
  });

  testWidgets('cancel clears the caption; a late final never mutates state',
      (tester) async {
    final store = _MemoryFeatureTourStore();
    final capture = _ScriptedVoiceCapture();
    capture.leakyCancel = true; // SIMULATED late delivery after cancel
    final l10n = await _pumpTour(
      tester,
      screen: FeatureTourScreen(
        store: store,
        nowProvider: () => _base,
        voiceCapture: capture,
      ),
    );

    await _tapVisible(
        tester, find.byKey(const ValueKey('voice-tour-mic-button')));
    await tester.pump();
    capture.emitReady();
    await tester.pump();
    capture.emitPartial('내일 오전 9시에');
    await tester.pump();
    expect(find.text('내일 오전 9시에'), findsOneWidget);

    await _tapVisible(
        tester, find.byKey(const ValueKey('voice-tour-cancel-mic')));
    await tester.pumpAndSettle();
    expect(capture.cancelCalls, 1);
    expect(find.text('내일 오전 9시에'), findsNothing); // caption cleared
    expect(find.text(l10n.voiceTourTranscriptHint), findsOneWidget);

    // Late final from the canceled session: dropped, no preview, no save.
    capture.leakLateFinal('내일 오전 9시에 강남역에서 팀장님과 면담');
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('voice-tour-create-preview')),
        findsNothing);
    expect(find.byKey(const ValueKey('voice-tour-save-create')), findsNothing);
    expect(store.saved, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'mic stop (toggle) finalizes the current session through the seam',
      (tester) async {
    final store = _MemoryFeatureTourStore();
    final capture = _ScriptedVoiceCapture();
    await _pumpTour(
      tester,
      screen: FeatureTourScreen(
        store: store,
        nowProvider: () => _base,
        voiceCapture: capture,
      ),
    );

    await _tapVisible(
        tester, find.byKey(const ValueKey('voice-tour-mic-button')));
    await tester.pump();
    capture.emitReady();
    await tester.pump();
    capture.emitPartial('내일 오전 9시에 강남역에서');
    await tester.pump();

    // Toggle to stop: the engine finalizes; final arrives via the listen
    // future and is applied.
    await _tapVisible(
        tester, find.byKey(const ValueKey('voice-tour-mic-button')));
    await tester.pump();
    expect(capture.stopCalls, 1);
    capture.emitFinal('내일 오전 9시에 강남역에서 팀장님과 면담');
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('voice-tour-create-preview')),
        findsOneWidget);
  });

  testWidgets('mic failures map to localized safe messages, not raw text',
      (tester) async {
    final store = _MemoryFeatureTourStore();
    final capture = _ScriptedVoiceCapture();
    final l10n = await _pumpTour(
      tester,
      screen: FeatureTourScreen(
        store: store,
        nowProvider: () => _base,
        voiceCapture: capture,
      ),
    );

    // Permission denial.
    capture.immediateResult = const VoiceCaptureResult(
      deniedPermission: true,
      message: 'RAW-PLATFORM-SECRET',
    );
    await _tapVisible(
        tester, find.byKey(const ValueKey('voice-tour-mic-button')));
    await tester.pumpAndSettle();
    expect(find.text(l10n.voiceTourErrorPermission), findsOneWidget);
    expect(find.textContaining('RAW-PLATFORM-SECRET'), findsNothing);

    // Silence.
    capture.immediateResult =
        const VoiceCaptureResult(silence: true, message: 'x');
    await _tapVisible(
        tester, find.byKey(const ValueKey('voice-tour-mic-button')));
    await tester.pumpAndSettle();
    expect(find.text(l10n.voiceTourErrorSilence), findsOneWidget);

    // Unavailable.
    capture.immediateResult =
        const VoiceCaptureResult(unavailable: true, message: 'x');
    await _tapVisible(
        tester, find.byKey(const ValueKey('voice-tour-mic-button')));
    await tester.pumpAndSettle();
    expect(find.text(l10n.voiceTourErrorUnavailable), findsOneWidget);
    expect(store.saved, isFalse);
  });

  testWidgets('unsupported utterance shows localized guidance, saves nothing',
      (tester) async {
    final store = _MemoryFeatureTourStore();
    final capture = _ScriptedVoiceCapture();
    final l10n = await _pumpTour(
      tester,
      screen: FeatureTourScreen(
        store: store,
        nowProvider: () => _base,
        voiceCapture: capture,
      ),
    );

    await _speak(tester, capture, '안녕하세요');
    expect(find.text(l10n.voiceTourUnsupported), findsOneWidget);
    expect(find.byKey(const ValueKey('voice-tour-create-preview')),
        findsNothing);
    expect(store.saved, isFalse);
    expectFinishEnabled(tester, false);
  });

  testWidgets('restart clears memory and caption, cancels own mic, no writes',
      (tester) async {
    final store = _MemoryFeatureTourStore();
    final capture = _ScriptedVoiceCapture();
    final l10n = await _pumpTour(
      tester,
      screen: FeatureTourScreen(
        store: store,
        nowProvider: () => _base,
        voiceCapture: capture,
      ),
    );

    await _speak(tester, capture, '내일 오전 9시에 강남역에서 팀장님과 면담');
    await _tapVisible(
        tester, find.byKey(const ValueKey('voice-tour-save-create')));
    await tester.pumpAndSettle();

    // Mid-query mic session with a live caption.
    await _tapVisible(
        tester, find.byKey(const ValueKey('voice-tour-mic-button')));
    await tester.pump();
    capture.emitReady();
    await tester.pump();
    capture.emitPartial('내일 일정');
    await tester.pump();

    await _tapVisible(tester, find.byKey(const ValueKey('voice-tour-restart')));
    await tester.pumpAndSettle();

    expect(capture.cancelCalls, 1); // own session canceled
    expect(find.text(l10n.voiceTourPhaseCreateTitle), findsOneWidget);
    expect(find.text(l10n.featureTourRestarted), findsOneWidget);
    expect(find.text('내일 일정'), findsNothing); // caption cleared
    expect(find.byKey(const ValueKey('voice-tour-create-preview')),
        findsNothing);
    expect(find.byKey(const ValueKey('voice-tour-text-input')), findsNothing);
    expectFinishEnabled(tester, false);
    expect(store.markCalls, 0); // completion marker untouched
    expect(store.saved, isFalse);
    expect(capture.listenCalls, 2); // only the two sessions actually started
  });

  testWidgets('screen dispose cancels its own capture; late data is inert',
      (tester) async {
    final store = _MemoryFeatureTourStore();
    final capture = _ScriptedVoiceCapture();
    capture.leakyCancel = true;
    await _pumpTour(
      tester,
      screen: FeatureTourScreen(
        store: store,
        nowProvider: () => _base,
        voiceCapture: capture,
      ),
    );

    await _tapVisible(
        tester, find.byKey(const ValueKey('voice-tour-mic-button')));
    await tester.pump();
    capture.emitReady();
    await tester.pump();
    capture.emitPartial('내일 오전 9시에');
    await tester.pump();

    // Pop the screen out of the tree: dispose runs synchronously.
    await tester.pumpWidget(const MaterialApp(home: Scaffold()));
    expect(capture.cancelCalls, 1);

    capture.leakLateFinal('내일 오전 9시에 강남역에서 팀장님과 면담');
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull); // no unhandled async errors
    expect(store.markCalls, 0);
  });

  testWidgets(
      'required first launch hides skip; system back never completes; '
      'explicit Finish after viewing the saved record hands over once',
      (tester) async {
    final store = _MemoryFeatureTourStore();
    final capture = _ScriptedVoiceCapture();
    var done = false;
    final l10n = await _pumpTour(
      tester,
      presentAsRoute: true,
      screen: FeatureTourScreen(
        store: store,
        onCompleted: () => done = true,
        requireFinalConfirmation: true,
        nowProvider: () => _base,
        voiceCapture: capture,
      ),
    );
    expect(find.byKey(const ValueKey('voice-tour-skip')), findsNothing);
    expect(find.byKey(const ValueKey('voice-tour-restart')), findsOneWidget);

    // System back is a no-op: no implicit completion, no route pop.
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(FeatureTourScreen), findsOneWidget);
    expect(store.markCalls, 0);
    expect(done, isFalse);

    // Full practice flow.
    await _speak(tester, capture, '내일 오전 9시에 강남역에서 팀장님과 면담');
    await _tapVisible(
        tester, find.byKey(const ValueKey('voice-tour-save-create')));
    await tester.pumpAndSettle();
    await _speak(tester, capture, '내일 일정 보여줘');
    await _speak(tester, capture, '첫 번째 일정 오후 1시로 미뤄줘');
    await _tapVisible(
        tester, find.byKey(const ValueKey('voice-tour-save-edit')));
    await tester.pumpAndSettle();
    expect(store.markCalls, 0);
    expect(store.saved, isFalse);

    await _tapVisible(
        tester, find.byKey(const ValueKey('voice-tour-open-updated')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('voice-tour-detail-event-1')),
        findsOneWidget);

    await _tapVisible(tester, _finishButton());
    await tester.pumpAndSettle();
    expect(store.markCalls, 1);
    expect(store.saved, isTrue);
    expect(done, isTrue);
    expect(find.text(l10n.featureTourSaveFailed), findsNothing);
  });

  testWidgets('optional tour ignores system back and pops after explicit skip',
      (tester) async {
    final store = _MemoryFeatureTourStore();
    final capture = _ScriptedVoiceCapture();
    await _pumpTour(
      tester,
      presentAsRoute: true,
      screen: FeatureTourScreen(
        store: store,
        nowProvider: () => _base,
        voiceCapture: capture,
      ),
    );
    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(find.byType(FeatureTourScreen), findsOneWidget);
    expect(store.saved, isFalse);

    await _tapVisible(tester, find.byKey(const ValueKey('voice-tour-skip')));
    await tester.pumpAndSettle();
    expect(store.saved, isTrue);
    expect(find.byType(FeatureTourScreen), findsNothing);
  });

  testWidgets('save failure shows inline retry; retry persists once more',
      (tester) async {
    final store = _MemoryFeatureTourStore();
    store.failuresLeft = 1;
    final capture = _ScriptedVoiceCapture();
    var done = false;
    final l10n = await _pumpTour(
      tester,
      screen: FeatureTourScreen(
        store: store,
        onCompleted: () => done = true,
        nowProvider: () => _base,
        voiceCapture: capture,
      ),
    );
    await _tapVisible(tester, find.byKey(const ValueKey('voice-tour-skip')));
    await tester.pump();
    expect(store.saved, isFalse);
    expect(done, isFalse);
    expect(find.text(l10n.featureTourSaveFailed), findsOneWidget);
    final retry = find.byKey(const ValueKey('feature-tour-save-retry-button'));
    expect(retry, findsOneWidget);

    await _tapVisible(tester, retry);
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
    final capture = _ScriptedVoiceCapture();
    var done = false;
    final l10n = await _pumpTour(
      tester,
      screen: FeatureTourScreen(
        store: store,
        onCompleted: () => done = true,
        nowProvider: () => _base,
        voiceCapture: capture,
      ),
    );
    await _tapVisible(tester, find.byKey(const ValueKey('voice-tour-skip')));
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
    final capture = _ScriptedVoiceCapture();
    var done = false;
    final l10n = await _pumpTour(
      tester,
      screen: FeatureTourScreen(
        store: store,
        onCompleted: () => done = true,
        nowProvider: () => _base,
        voiceCapture: capture,
      ),
    );
    await _tapVisible(tester, find.byKey(const ValueKey('voice-tour-skip')));
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
    final capture = _ScriptedVoiceCapture();
    var done = false;
    await _pumpTour(
      tester,
      screen: FeatureTourScreen(
        store: store,
        onCompleted: () => done = true,
        nowProvider: () => _base,
        voiceCapture: capture,
      ),
    );
    await _tapVisible(tester, find.byKey(const ValueKey('voice-tour-skip')));
    await tester.pump();
    expect(store.markCalls, 1);

    // Second tap and restart are ignored while the first save is running.
    await tester.tap(find.byKey(const ValueKey('voice-tour-skip')));
    await tester.pump();
    expect(
      tester
          .widget<TextButton>(find.byKey(const ValueKey('voice-tour-skip')))
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<TextButton>(
              find.byKey(const ValueKey('voice-tour-restart')))
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

  testWidgets('Korean locale renders the guided voice flow', (tester) async {
    final store = _MemoryFeatureTourStore();
    final capture = _ScriptedVoiceCapture();
    final l10n = await _pumpTour(
      tester,
      locale: const Locale('ko'),
      screen: FeatureTourScreen(
        store: store,
        nowProvider: () => _base,
        voiceCapture: capture,
      ),
    );
    expect(find.text(l10n.voiceTourPhaseCreateTitle), findsOneWidget);
    expect(find.text(l10n.voiceTourExampleCreate), findsOneWidget);
    expect(find.text(l10n.voiceTourMicStart), findsOneWidget);

    await _speak(tester, capture, '내일 오전 9시에 강남역에서 팀장님과 면담');
    expect(find.byKey(const ValueKey('voice-tour-create-preview')),
        findsOneWidget);
    await _tapVisible(
        tester, find.byKey(const ValueKey('voice-tour-save-create')));
    await tester.pumpAndSettle();
    expect(find.text(l10n.voiceTourPhaseQueryTitle), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'iOS theme and small 360x640 viewport with 2.0 text scale and dark '
      'mode stay overflow-free through the whole flow',
      (tester) async {
    final store = _MemoryFeatureTourStore();
    final capture = _ScriptedVoiceCapture();
    final l10nIos = await _pumpTour(
      tester,
      platform: TargetPlatform.iOS,
      screen: FeatureTourScreen(
        store: store,
        nowProvider: () => _base,
        voiceCapture: capture,
      ),
    );
    expect(find.text(l10nIos.voiceTourPhaseCreateTitle), findsOneWidget);

    final store2 = _MemoryFeatureTourStore();
    final capture2 = _ScriptedVoiceCapture();
    final l10n = await _pumpTour(
      tester,
      smallViewport: true,
      textScale: 2.0,
      dark: true,
      screen: FeatureTourScreen(
        store: store2,
        nowProvider: () => _base,
        voiceCapture: capture2,
      ),
    );
    expect(find.text(l10n.voiceTourPhaseCreateTitle), findsOneWidget);

    await _speak(tester, capture2, '내일 오전 9시에 강남역에서 팀장님과 면담');
    expect(find.byKey(const ValueKey('voice-tour-create-preview')),
        findsOneWidget);
    await _tapVisible(
        tester, find.byKey(const ValueKey('voice-tour-save-create')));
    await tester.pumpAndSettle();
    await _speak(tester, capture2, '내일 일정 보여줘');
    await _speak(tester, capture2, '첫 번째 일정 오후 1시로 미뤄줘');
    expect(find.byKey(const ValueKey('voice-tour-edit-preview')),
        findsOneWidget);
    await _tapVisible(
        tester, find.byKey(const ValueKey('voice-tour-save-edit')));
    await tester.pumpAndSettle();
    await _tapVisible(
        tester, find.byKey(const ValueKey('voice-tour-open-updated')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('voice-tour-detail-event-1')),
        findsOneWidget);
    expectFinishEnabled(tester, true);
    expect(tester.takeException(), isNull); // no RenderFlex overflow
  });
}
