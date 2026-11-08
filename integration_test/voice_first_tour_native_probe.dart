// Explicitly registered only by a native host harness; not default-discovered.
// Exercises host-provided audio through real platform ASR, never text input.
// The host records provenance separately: acoustic PC-speaker -> physical mic
// is distinct from emulator PCM injection and neither is a human utterance.
//
// This M3 revision fixes four logic/coverage holes identified after Luna's
// first attempt was rejected by the parent:
//
//   1. After Save/Create, the harness used to wait on `voice-tour-results`
//      BEFORE the query utterance had actually been spoken. That pre-emptively
//      assumed Save == query success. Now the harness only waits on
//      `voice-tour-mic-button` (post-save / available-mic phase) and then
//      proceeds to actually say the query through the host-injected stage.
//
//   2. The harness used to tap the first queried result row before edit. That
//      premature tap opens a detail modal and can block the mic. The row tap
//      has been removed entirely.
//
//   3. After the host marker arrived, the harness used to tap `voice-tour-mic-
//      button` whenever it existed. The mic button is also rendered after
//      auto-finalization, so the previous behaviour started a NEW listening
//      session and clobbered the caption / draft. Now the harness gates the
//      stop on `voice-tour-cancel-mic` (active-session indicator) and never
//      taps it after auto-final. It also waits for actual
//      `voice-tour-ready` (SttNativeStatus.ready) BEFORE injection and never
//      starts Stop on the first partial.
//
//   4. The harness did not compare the unchanged TITLE / LOCATION / DATE
//      fields between the result row (before edit) and the detail view (after
//      edit), and did not verify same id + exact fields. Now the harness
//      reads every actualText key the UI actor was asked to bind, captures
//      a full before/after snapshot, and asserts equality on
//      title/location/date (preservation), the 09:00 -> 13:00 time change,
//      and stored departure 12:30 / preparation 12:15.
//
// This GLM revision fixes two runtime-blocking bugs found by parent review
// of the M3 revision:
//
//   1. The localized transcript placeholder was resolved via
//      AppLocalizations.of(tester.element(find.byType(MaterialApp))). The
//      MaterialApp element sits ABOVE the Localizations scope, so the `!`
//      inside AppLocalizations.of null-threw at runtime. It now resolves
//      against the FeatureTourScreen element, a descendant of that scope.
//
//   2. After the host PCM marker, the stop gate tapped
//      voice-tour-cancel-mic, whose _cancelMicSession DISCARDS the
//      transcript. The gate still keys on cancel-mic presence (the
//      active-session indicator) but now taps voice-tour-mic-button:
//      while capturing its _toggleMic acts as Stop and finalizes the
//      transcript. When cancel-mic is absent (auto-final already done)
//      neither button is tapped.
//
// Compile/analyze only proves imports compile. Runtime was NOT RUN by this
// worker. The parent exclusively performs native execution, PCM host
// injection, screenshot capture, and lease cleanup.
//
// This revision (final-recorder-m3) routes stage-by-stage transcript
// assertions through a transparent `NativeCaptureRecorder` injected into
// `FeatureTourScreen`. The recorder wraps the unchanged
// `SttServiceVoiceCapture()` lazily (no mock, no seed, no expected
// transcript) and saves the EXACT final `VoiceCaptureResult` for each
// stage BEFORE returning it to the screen. This fixes the previous
// false-fail mode where `_applyFinalTranscript` clears `_caption = null`
// and the UI caption box falls back to the localized placeholder
// ("인식된 문장이 여기에 보여요" / "Recognized speech appears here") AFTER
// ASR produced a perfectly good transcript, which made the probe claim
// ASR never produced text. The placeholder-vs-text equality check in the
// previous revision was based on the wrong assumption that the caption
// retained ASR text after apply; it does not, so the recorder is the
// only sound source of truth. The probe still reads every per-field
// actualText key the UI binds (강남, 09:00, 13:00, 12:30, 12:15, same id
// before/after, host markers+proof handshake unchanged).
//
// This revision (placeholder-guard-glm) closes the review BLOCK: the
// stage guard must ALSO reject a successful, non-empty recorded final
// whose text equals the REAL localized caption placeholder
// (`voiceTourTranscriptHint`). The guard now lives in
// integration_test/support/native_capture_recorder.dart as
// `requireRecordedResult`; the probe resolves the hint once from a
// FeatureTourScreen-descendant element (NOT the MaterialApp context,
// which null-threw in a prior revision) and passes it as the forbidden
// comparison for ALL 3 stages (create/query/edit). No placeholder string
// is hardcoded and no seeded/expected text exists in this compiled probe.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:planflow/l10n/app_localizations.dart';
import 'package:planflow/screens/onboarding/feature_tour_screen.dart';
import 'package:planflow/services/feature_tour_service.dart';

import 'support/native_capture_recorder.dart';
import 'support/native_report_chunks.dart';

const bool _enabled = bool.fromEnvironment('VOICE_TOUR_NATIVE_AUDIO_PROBE');
// Opt-in only. Default false so production and other host tests do not pause.
const bool _proofPause = bool.fromEnvironment('VOICE_TOUR_NATIVE_PROOF_PAUSE');
// ARM = Adb-driven Real Mic. Default false so old consumers see no change.
// When enabled, startStage blocks on a per-stage host `.arm` marker BEFORE
// any recorder assignment or mic tap, so the parent can pre-load WAVs and
// confirm the app is foreground BEFORE arming the mic. ARM is NOT ready
// and MUST NOT claim ASR/listening: it only signals that mic arming may
// proceed. No fake-ready fallback: if the host does not write runId to
// `.arm`, waitHostMarker() throws and the test fails.
const bool _hostArm = bool.fromEnvironment('VOICE_TOUR_NATIVE_HOST_ARM');
const bool _pcmFileInput =
    bool.fromEnvironment('VOICE_TOUR_NATIVE_PCM_FILE_INPUT');
const MethodChannel _nativeStt = MethodChannel('planflow/native_stt');
const String _inputMode = _pcmFileInput
    ? 'raw-pcm-real-engine-not-live-mic'
    : 'host-audio-native-asr';
const Duration _timeout = Duration(seconds: 60);
const String _prefixReady = 'VOICE_TOUR_NATIVE';
const String _prefixArm = 'VOICE_TOUR_NATIVE_ARM';
const String _prefixProof = 'VOICE_TOUR_NATIVE_PROOF';
const String _prefixReport = 'VOICE_TOUR_NATIVE_REPORT';

class _MemoryTourStore extends FeatureTourStore {
  bool completed = false;
  @override
  Future<bool> shouldShow() async => !completed;
  @override
  Future<void> markCompleted() {
    completed = true;
    return Future<void>.value();
  }

  @override
  Future<bool> shouldShowTip(String tipId) async => true;
  @override
  Future<void> markTipShown(String tipId) async {}
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'real native ASR create, query, edit, finish with full data equality',
    (tester) async {
      if (!_enabled) {
        // Explicit opt-in required. Skipping is not a passing fake-ASR run.
        markTestSkipped('VOICE_TOUR_NATIVE_AUDIO_PROBE is not enabled.');
        return;
      }
      if (_pcmFileInput && !_hostArm) {
        throw StateError('PCM file input requires VOICE_TOUR_NATIVE_HOST_ARM');
      }
      // Freeze Date.now once per harness so the same controller-clock is used
      // for every stage (date drift checks and tomorrow verification).
      final now = DateTime.now();
      final runId = '${now.microsecondsSinceEpoch}-$pid';
      final cache = Directory(
        '${Directory.systemTemp.path}/voice-tour-probe-$runId',
      );
      await cache.create(recursive: true);
      final store = _MemoryTourStore();
      var completedCalls = 0;
      final report = <String, Object?>{
        'runId': runId,
        'now': now.toIso8601String(),
        'inputMode': _inputMode,
        'micAcousticVerified': false,
        'stages': <String, Object?>{},
      };
      var currentStage = 'boot';
      var markerPath = '';
      var queryEventId = '';
      Map<String, String> queryBefore = const <String, String>{};
      Map<String, String> detailAfter = const <String, String>{};
      final cleanupReceipts = <Map<String, Object?>>[];

      Future<void> pumpUntil(Finder finder, String label) async {
        final end = DateTime.now().add(_timeout);
        while (DateTime.now().isBefore(end)) {
          await tester.pump(const Duration(milliseconds: 100));
          if (finder.evaluate().isNotEmpty) return;
        }
        throw TimeoutException('Timed out waiting for $label', _timeout);
      }

      Future<void> waitHostMarker() async {
        final end = DateTime.now().add(_timeout);
        final marker = File(markerPath);
        while (DateTime.now().isBefore(end)) {
          await tester.pump(const Duration(milliseconds: 100));
          if (await marker.exists()) {
            final text = await marker.readAsString();
            await marker.delete();
            if (text.trim() != runId) {
              throw StateError(
                'Host marker runId mismatch (expected $runId, got ${text.trim()})',
              );
            }
            return;
          }
        }
        throw TimeoutException(
          'Host PCM marker timed out for $currentStage at $markerPath',
          _timeout,
        );
      }

      Future<void> ensureTap(String keyName) async {
        final finder = find.byKey(ValueKey<String>(keyName));
        if (finder.evaluate().isEmpty) {
          throw StateError('Cannot tap; missing key: $keyName');
        }
        await tester.ensureVisible(finder);
        await tester.pump();
        await tester.tap(finder);
      }

      // Inject the transparent recorder so the screen owns a real
      // `SttServiceVoiceCapture()` lazily (constructed by the recorder
      // itself, never mocked), and keys every final result by the
      // active stage. Because we injected, the screen will NOT call
      // cancel/dispose on the capture (its `_ownsCapture` is false), so
      // the probe owns the finally cancel/dispose for this run.
      // Declared BEFORE `startStage` so the local function can reach it
      // without an analyzer forward-reference warning.
      final recorder = NativeCaptureRecorder();

      Future<void> releasePreviousPcmClient(String stage) async {
        if (recorder.isListening) {
          throw StateError('Previous capture is still listening');
        }
        final previousStage = stage == 'query' ? 'create' : 'query';
        final previousResult = recorder.results[previousStage];
        if (previousResult == null || !previousResult.isSuccess) {
          throw StateError('Previous capture did not succeed');
        }

        final cancelled = Completer<Map<String, Object?>>();
        // Install before cancel: Android can emit and buffer the terminal
        // callback before the method-channel invocation itself is acknowledged.
        _nativeStt.setMethodCallHandler((call) async {
          final args = call.arguments;
          if (call.method == 'cancelled' && args is Map) {
            final sessionId = args['sessionId'];
            if (sessionId is num &&
                sessionId > 0 &&
                sessionId == sessionId.roundToDouble() &&
                !cancelled.isCompleted) {
              final receipt = <String, Object?>{
                'stage': stage,
                'method': call.method,
                'nativeSessionId': sessionId.toInt(),
              };
              cancelled.complete(receipt);
            }
          }
          return null;
        });
        try {
          await Future.wait<void>([
            _nativeStt.invokeMethod<String>('cancel').then<void>((_) {}),
            cancelled.future.then<void>((_) {}),
          ]).timeout(const Duration(seconds: 2));
          // Both the native method acknowledgement and its real terminal
          // callback are required before PCM reconfiguration can proceed.
          // The value is fetched from the callback, never synthesized.
          cleanupReceipts.add(await cancelled.future);
          report['pcmStagePreparation'] =
              'release-previous-owned-client-and-drain-native-cancelled';
        } finally {
          _nativeStt.setMethodCallHandler(null);
        }
      }

      // Starts a stage by tapping the mic, waiting for ready, asking the
      // host to inject the matching WAV, then gating the stop on the
      // active-session indicator (voice-tour-cancel-mic) so we never
      // re-enter listening after auto-final.
      Future<void> startStage(String name) async {
        currentStage = name;
        // ARM gate (opt-in, default off). Runs BEFORE any recorder
        // assignment or mic tap, using the EXISTING mutable `markerPath`
        // helper so the `.arm` write/clear cycle reuses waitHostMarker().
        // The parent pre-loads every stage's WAV and confirms the app is
        // foreground, then writes runId to `$name.arm`. ARM is NOT ready:
        // it does not emit the ready prefix, does not claim ASR, and does
        // not open a listening session. Old consumers (flag false) skip
        // this block entirely; existing `.done` and `detail-proof.done`
        // markers remain unchanged. The host-marker timeout, runId
        // equality check, and delete-after-read behavior all come from
        // waitHostMarker() unchanged, so no new framework, no new timeouts,
        // no new helpers.
        if (_hostArm) {
          markerPath = '${cache.path}/$name.arm';
          // ignore: avoid_print
          print('$_prefixArm ${jsonEncode({
                'stage': name,
                'runId': runId,
                'markerPath': markerPath,
                if (_pcmFileInput) 'pcmPath': '${cache.path}/$name.pcm',
                if (_pcmFileInput) 'nativeInputMode': _inputMode,
              })}');
          await waitHostMarker();
        }
        if (_pcmFileInput) {
          if (name != 'create') {
            await releasePreviousPcmClient(name);
          }
          final pcm = File('${cache.path}/$name.pcm');
          if (!await pcm.exists()) throw StateError('Host PCM is missing');
          // Canonicalize so /data/user/0/... and /data/data/... aliases agree
          // with the native STRICT exact/canonical/no-symlink/UID/size checks
          // (helper F7606504...). Native gate remains unchanged.
          await _nativeStt.invokeMethod<bool>(
            'qaConfigurePcmCaptureSource',
            {
              'runId': runId,
              'stage': name,
              'path': await pcm.resolveSymbolicLinks()
            },
          );
        }
        // Set the recorder's stage BEFORE the existing mic tap so
        // `listen()` captures an immutable local copy at call time. The
        // recorded result will be keyed by this stage for the assertions
        // that follow.
        recorder.currentStage = name;
        final micFinder = find.byKey(
          const ValueKey<String>('voice-tour-mic-button'),
        );
        await pumpUntil(micFinder, '$name mic available');
        await tester.ensureVisible(micFinder);
        await tester.pump();
        await tester.tap(micFinder);
        // Wait for actual SttNativeStatus.ready BEFORE injecting. We never
        // start Stop on a first partial; the host marker is the single
        // signal that the full WAV has been delivered.
        await pumpUntil(
          find.byKey(const ValueKey<String>('voice-tour-ready')),
          '$name native ready',
        );
        markerPath = '${cache.path}/$name.done';
        // One-line host protocol. Parent injects the complete WAV only after
        // this line and writes the runId to markerPath via run-as.
        // ignore: avoid_print
        print('$_prefixReady ${jsonEncode({
              'stage': name,
              'ready': true,
              'markerPath': markerPath,
              'runId': runId,
            })}');
        await waitHostMarker();
        // Gate on the active-session indicator, NOT mere mic-button
        // presence. If auto-final already happened, cancel-mic is absent and
        // tapping voice-tour-mic-button would start a NEW listen and
        // clobber the caption / draft.
        // Gate on the active-session indicator (voice-tour-cancel-mic is
        // only rendered while a session is active), but STOP by tapping
        // the mic button itself: while capturing its onPressed _toggleMic
        // calls _capture.stop(), which finalizes and KEEPS the transcript.
        // NEVER tap voice-tour-cancel-mic: its _cancelMicSession sets
        // _caption = null and discards the utterance. If auto-final
        // already completed, cancel-mic is absent and the mic button must
        // NOT be tapped either, because that would start a NEW listen and
        // clobber the caption / draft.
        final cancelFinder = find.byKey(
          const ValueKey<String>('voice-tour-cancel-mic'),
        );
        if (cancelFinder.evaluate().isNotEmpty) {
          await tester.ensureVisible(micFinder);
          await tester.pump();
          await tester.tap(micFinder);
          await tester.pump(const Duration(milliseconds: 300));
        }
      }

      try {
        await tester.pumpWidget(
          MaterialApp(
            locale: const Locale('ko'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            theme: ThemeData(),
            builder: _pcmFileInput
                ? (context, child) => Column(
                      children: [
                        const SafeArea(
                          bottom: false,
                          child: Material(
                            color: Colors.amber,
                            child: Padding(
                              padding: EdgeInsets.all(4),
                              child: Text('실제 ASR · 합성음원 입력 · 라이브 마이크 아님',
                                  style: TextStyle(
                                      fontSize: 12, color: Colors.black)),
                            ),
                          ),
                        ),
                        Expanded(child: child ?? const SizedBox.shrink()),
                      ],
                    )
                : null,
            home: FeatureTourScreen(
              store: store,
              requireFinalConfirmation: true,
              nowProvider: () => now,
              onCompleted: () => completedCalls++,
              voiceCapture: recorder,
            ),
          ),
        );

        // The screen binds voiceTourTranscriptHint to the caption box
        // whenever no ASR result has been rendered yet, and `_applyFinal-
        // Transcript` deliberately clears `_caption = null` after each
        // successful apply, so reading `voice-tour-transcript` after
        // apply cannot prove ASR ever produced text (it returns the
        // localized placeholder). The recorder is the source of truth.
        // Field asserts (강남/09:00/13:00/12:30/12:15, id-scoped equality,
        // host markers+proof handshake) remain unchanged.

        // Resolve the REAL localized caption placeholder ONCE, from a
        // FeatureTourScreen-descendant element. FeatureTourScreen sits
        // BELOW MaterialApp's Localizations scope; resolving from the
        // MaterialApp element itself null-threw in a prior revision. The
        // hint is a forbidden comparison ONLY (inside
        // requireRecordedResult); it is never injected as input, expected
        // text, or result, and no placeholder string is hardcoded here.
        final transcriptPlaceholderHint = AppLocalizations.of(
          tester.element(find.byType(FeatureTourScreen)),
        ).voiceTourTranscriptHint;

        // ---------------- CREATE ----------------
        await startStage('create');
        await pumpUntil(
          find.byKey(const ValueKey<String>('voice-tour-create-preview')),
          'create preview',
        );
        // Read the actual final ASR result from the recorder BEFORE any
        // asserts run, so a failing run still reports the stage evidence
        // (otherwise `report['stages']` would be an empty map on failure).
        final createPreview = _keyText(tester, 'voice-tour-create-preview');
        final createRecorded = recorder.results['create'];
        final createTranscript =
            createRecorded == null ? '' : (createRecorded.text ?? '');
        report['stages'] = <String, Object?>{
          ...(report['stages'] as Map<String, Object?>),
          'create': {
            'transcript': createTranscript,
            'preview': createPreview,
            'recordedSuccess': createRecorded?.isSuccess ?? false,
            'recordedMessage': createRecorded?.message,
          },
        };
        requireRecordedResult(
          createRecorded,
          'create',
          forbiddenPlaceholderHint: transcriptPlaceholderHint,
        );
        _requireContains(createPreview, '강남', 'create preview location');
        _requireContains(createPreview, '09:00', 'create preview time');
        await ensureTap('voice-tour-save-create');
        // Post-save: wait only for the next available-mic phase. We do NOT
        // pre-emptively wait on voice-tour-results here, because results are
        // only populated when the user actually says the query.
        await pumpUntil(
          find.byKey(const ValueKey<String>('voice-tour-mic-button')),
          'post-save mic ready',
        );

        // ---------------- QUERY ----------------
        await startStage('query');
        // After the host injects the query utterance, wait for actual
        // queried results to render.
        await pumpUntil(
          find.byKey(const ValueKey<String>('voice-tour-results')),
          'query results after query stage',
        );
        // Find the first keyed saved row widget. Exclude the per-field
        // sub-keys so the row container itself is selected, not its children.
        final firstRow = find.byWidgetPredicate((widget) {
          final key = widget.key;
          if (key is! ValueKey<String>) return false;
          if (!key.value.startsWith('voice-tour-result-')) return false;
          const subPrefixes = <String>[
            'voice-tour-result-title-',
            'voice-tour-result-location-',
            'voice-tour-result-date-',
            'voice-tour-result-time-',
          ];
          for (final p in subPrefixes) {
            if (key.value.startsWith(p)) return false;
          }
          return true;
        });
        await pumpUntil(firstRow, 'actual saved query result row');
        final rowKey =
            firstRow.evaluate().first.widget.key! as ValueKey<String>;
        queryEventId = rowKey.value.substring('voice-tour-result-'.length);
        // Read every actualText key the UI actor was asked to bind for the
        // queried row. Each key is scoped to this specific event id so we
        // never pick up global example / hint Text widgets.
        queryBefore = <String, String>{
          'id': queryEventId,
          'title': _keyText(tester, 'voice-tour-result-title-$queryEventId'),
          'location': _keyText(
            tester,
            'voice-tour-result-location-$queryEventId',
          ),
          'date': _keyText(tester, 'voice-tour-result-date-$queryEventId'),
          'time': _keyText(tester, 'voice-tour-result-time-$queryEventId'),
        };
        _requireTranscript(queryBefore['title']!, 'query result title');
        _requireTranscript(queryBefore['location']!, 'query result location');
        _requireTranscript(queryBefore['date']!, 'query result date');
        _requireTranscript(queryBefore['time']!, 'query result time');
        _requireContains(queryBefore['time']!, '09:00', 'query result time');
        _verifyTomorrowIfKnown(
          queryBefore['date']!,
          now,
          'query result date',
        );
        // The query stage ALSO produced real ASR text; read it from the
        // recorder (not from the UI caption) so we never silently accept
        // a query that didn't actually produce final text.
        final queryRecorded = recorder.results['query'];
        requireRecordedResult(
          queryRecorded,
          'query',
          forbiddenPlaceholderHint: transcriptPlaceholderHint,
        );
        report['stages'] = <String, Object?>{
          ...(report['stages'] as Map<String, Object?>),
          'query': {
            'transcript': queryRecorded?.text ?? '',
            'recordedSuccess': queryRecorded?.isSuccess ?? false,
            'recordedMessage': queryRecorded?.message,
          },
        };
        report['query_before_edit'] = queryBefore;
        // NO tap on the first row. Tapping it can open a detail modal and
        // block the next mic tap. We go directly to the edit stage.

        // ---------------- EDIT ----------------
        await startStage('edit');
        await pumpUntil(
          find.byKey(const ValueKey<String>('voice-tour-edit-preview')),
          'edit preview',
        );
        final editPreview = _keyText(tester, 'voice-tour-edit-preview');
        final editRecorded = recorder.results['edit'];
        final editTranscript =
            editRecorded == null ? '' : (editRecorded.text ?? '');
        report['stages'] = <String, Object?>{
          ...(report['stages'] as Map<String, Object?>),
          'edit': {
            'transcript': editTranscript,
            'preview': editPreview,
            'recordedSuccess': editRecorded?.isSuccess ?? false,
            'recordedMessage': editRecorded?.message,
          },
        };
        requireRecordedResult(
          editRecorded,
          'edit',
          forbiddenPlaceholderHint: transcriptPlaceholderHint,
        );
        _requireContains(editPreview, '13:00', 'edit preview time');
        await ensureTap('voice-tour-save-edit');
        await pumpUntil(
          find.byKey(const ValueKey<String>('voice-tour-open-updated')),
          'updated saved record action',
        );
        await ensureTap('voice-tour-open-updated');
        await pumpUntil(
          find.byKey(
            ValueKey<String>('voice-tour-detail-event-$queryEventId'),
          ),
          'same saved record detail',
        );
        // Read every detail actualText key the UI actor was asked to bind.
        detailAfter = <String, String>{
          'id': queryEventId,
          'title': _keyText(tester, 'voice-tour-detail-title'),
          'location': _keyText(tester, 'voice-tour-detail-location'),
          'date': _keyText(tester, 'voice-tour-detail-date'),
          'eventTime': _keyText(tester, 'voice-tour-detail-event-time'),
          'departure': _keyText(tester, 'voice-tour-detail-departure'),
          'preparation': _keyText(tester, 'voice-tour-detail-preparation'),
        };
        _requireTranscript(detailAfter['title']!, 'detail title');
        _requireTranscript(detailAfter['location']!, 'detail location');
        _requireTranscript(detailAfter['date']!, 'detail date');
        _requireTranscript(detailAfter['eventTime']!, 'detail event time');
        _requireTranscript(detailAfter['departure']!, 'detail departure');
        _requireTranscript(detailAfter['preparation']!, 'detail preparation');

        // Unchanged-field equality between the queried row and the detail
        // view, for the SAME event id. Title, location, and date must
        // round-trip. Korean ASR spellings may vary, so we compare the
        // rendered strings exactly as they appear; any whitespace drift
        // here means the UI lost the actual stored field.
        _requireEqual(
          detailAfter['title']!,
          queryBefore['title']!,
          'detail title unchanged vs query',
        );
        _requireEqual(
          detailAfter['location']!,
          queryBefore['location']!,
          'detail location unchanged vs query',
        );
        _requireEqual(
          detailAfter['date']!,
          queryBefore['date']!,
          'detail date unchanged vs query',
        );
        _verifyTomorrowIfKnown(detailAfter['date']!, now, 'detail date');

        // Time changed from 09:00 to 13:00, and the old value must be gone.
        _requireContains(
          detailAfter['eventTime']!,
          '13:00',
          'stored event time',
        );
        if (detailAfter['eventTime']!.contains('09:00')) {
          throw StateError(
            'detail eventTime still contains old 09:00: ${detailAfter['eventTime']}',
          );
        }

        // Derived times: 30 minute departure lead, 15 minute preparation.
        _requireContains(
          detailAfter['departure']!,
          '12:30',
          'stored departure',
        );
        _requireContains(
          detailAfter['preparation']!,
          '12:15',
          'stored preparation',
        );

        report['detail_after_edit'] = detailAfter;

        // HOST PROOF HANDSHAKE (opt-in). Default off so production and other
        // host tests do not pause. When on, the harness emits a one-line
        // VOICE_TOUR_NATIVE_PROOF marker carrying the same detail fields
        // and waits for the host to write runId to detail-proof.done after
        // capturing an adb screenshot of the actual stored record. NO audio
        // injection at this stage; this is a screenshot/visual proof only,
        // and it is distinct from VOICE_TOUR_NATIVE ready. The harness does
        // NOT produce screenshots or appdata fakes; the parent owns capture.
        if (_proofPause) {
          currentStage = 'saved-detail-proof';
          final proofMarker = '${cache.path}/detail-proof.done';
          // ignore: avoid_print
          print('$_prefixProof ${jsonEncode({
                'stage': 'saved-detail',
                'markerPath': proofMarker,
                'runId': runId,
                'detailId': detailAfter['id'],
                'detailTitle': detailAfter['title'],
                'detailLocation': detailAfter['location'],
                'detailDate': detailAfter['date'],
                'detailEventTime': detailAfter['eventTime'],
                'detailDeparture': detailAfter['departure'],
                'detailPreparation': detailAfter['preparation'],
              })}');
          final proofEnd = DateTime.now().add(_timeout);
          final markerFile = File(proofMarker);
          var proofAck = false;
          while (DateTime.now().isBefore(proofEnd)) {
            await tester.pump(const Duration(milliseconds: 100));
            if (await markerFile.exists()) {
              final text = await markerFile.readAsString();
              await markerFile.delete();
              if (text.trim() != runId) {
                throw StateError(
                  'Proof marker runId mismatch (expected $runId, got ${text.trim()})',
                );
              }
              proofAck = true;
              break;
            }
          }
          if (!proofAck) {
            throw TimeoutException(
              'Host proof marker timed out at $proofMarker',
              _timeout,
            );
          }
          report['proof_handshake'] = 'acked';
        }

        // Close the detail modal if voice-tour-detail-close is present.
        // The UI actor was asked to bind this only when the detail opens in a
        // modal; if it is rendered inline, Finish is the next step directly.
        final closeFinder = find.byKey(
          const ValueKey<String>('voice-tour-detail-close'),
        );
        if (closeFinder.evaluate().isNotEmpty) {
          await tester.ensureVisible(closeFinder);
          await tester.pump();
          await tester.tap(closeFinder);
          await tester.pump(const Duration(milliseconds: 300));
        }

        // Final Finish: store.completed and onCompleted exactly once, and
        // only after an explicit Finish. Skipping Finish is not a passing run.
        await pumpUntil(
          find.byKey(const ValueKey<String>('voice-tour-finish')),
          'finish action available',
        );
        await ensureTap('voice-tour-finish');
        await tester.pump(const Duration(milliseconds: 500));
        expect(
          store.completed,
          isTrue,
          reason: 'only explicit Finish marks the in-memory tour complete',
        );
        expect(
          completedCalls,
          1,
          reason: 'completion callback must run exactly once',
        );
        report['outcome'] = 'PASS';
      } catch (error, stack) {
        report['outcome'] = 'FAIL';
        report['failure'] = <String, Object?>{
          'stage': currentStage,
          'reason': '$error',
          'queryBefore': queryBefore,
          'detailAfter': detailAfter,
          'stack': '$stack',
        };
        rethrow;
      } finally {
        // Probe owns the recorder's lifecycle because injection flipped
        // `_ownsCapture` to false. Cancel any in-flight listen first so
        // the underlying engine is released, then dispose the lazy
        // delegate. Best-effort: a leaked listen does not affect the
        // report.
        try {
          await recorder.cancel();
        } catch (_) {/* best-effort cleanup */}
        // Diagnostic snapshot of the ACTUAL recorded captures BEFORE the
        // recorder is disposed. Map ONLY existing recorder.results entries
        // (create/query/edit) to a JSON-safe shape with the six real
        // fields, so the report never serializes the VoiceCaptureResult
        // object directly (non-JSON). Stages with no captured final are
        // simply absent. No expected words, no placeholder fallback, no
        // missing fakes. Memory/logs only; nothing is written to app disk.
        final recordedCaptures = <String, Object?>{};
        for (final entry in recorder.results.entries) {
          final r = entry.value;
          recordedCaptures[entry.key] = <String, Object?>{
            'text': r.text,
            'success': r.isSuccess,
            'deniedPermission': r.deniedPermission,
            'unsupportedLocale': r.unsupportedLocale,
            'silence': r.silence,
            'unavailable': r.unavailable,
          };
        }
        report['recordedCaptures'] = recordedCaptures;
        report['nativeCleanupReceipts'] = cleanupReceipts;
        await recorder.disposeRecorder();
        // Chunked emit runs AFTER the snapshot so the captured results
        // are visible to the parent regardless of pass/fail. The legacy
        // single-line print follows for older hosts.
        emitVoiceTourReportChunks(report);
        // Keep the legacy line for older hosts; the complete chunked report
        // avoids Android log-entry truncation and does not write tour data.
        // ignore: avoid_print
        print('$_prefixReport ${jsonEncode(report)}');
        if (await cache.exists()) await cache.delete(recursive: true);
      }
    },
  );
}

// Walks every Text widget rendered under the given actualText key. The keys
// the UI actor binds are scoped to a single field, so this returns the field
// text. If the key is missing the harness throws an actionable error rather
// than silently falling back to a global hint or example Text.
String _keyText(WidgetTester tester, String keyName) {
  final finder = find.byKey(ValueKey<String>(keyName));
  if (finder.evaluate().isEmpty) {
    throw StateError('Missing actualText key: $keyName');
  }
  final element = finder.evaluate().first;
  final texts = <Text>[];
  void visit(Element e) {
    if (e.widget is Text) {
      texts.add(e.widget as Text);
    }
    e.visitChildren(visit);
  }

  visit(element);
  if (texts.isEmpty) {
    throw StateError('No rendered Text under actualText key: $keyName');
  }
  return texts
      .map((e) => (e.data ?? e.textSpan?.toPlainText() ?? '').trim())
      .join(' ');
}

void _requireTranscript(String actual, String stage) {
  if (actual.trim().isEmpty) {
    throw StateError(
      'No actual saved field rendered for $stage (got: "$actual")',
    );
  }
}

// The stage-final guard (non-null entry + success + non-blank text + NOT
// equal to the localized caption placeholder) lives in
// integration_test/support/native_capture_recorder.dart as
// `requireRecordedResult`. This probe resolves the REAL localized
// voiceTourTranscriptHint from a FeatureTourScreen-descendant element and
// passes it as the forbidden comparison at all 3 stages (create/query/edit).

void _requireContains(String actual, String expected, String field) {
  if (!actual.contains(expected)) {
    throw StateError(
      '$field missing "$expected". Actual: "$actual"',
    );
  }
}

void _requireEqual(String actual, String expected, String field) {
  if (actual.trim() != expected.trim()) {
    throw StateError(
      '$field equality failed. Expected: "$expected" Got: "$actual"',
    );
  }
}

void _verifyTomorrowIfKnown(String renderedDate, DateTime now, String field) {
  // ISO 8601 first.
  DateTime? parsed = DateTime.tryParse(renderedDate);
  if (parsed != null) {
    final tomorrow = DateTime(
      now.year,
      now.month,
      now.day,
    ).add(const Duration(days: 1));
    if (parsed.year != tomorrow.year ||
        parsed.month != tomorrow.month ||
        parsed.day != tomorrow.day) {
      throw StateError(
        '$field "$renderedDate" is not tomorrow $tomorrow',
      );
    }
    return;
  }
  // MM/DD like "10/18" (the screen's _fmtDate format). Year-less; rely on
  // the frozen now for the year context.
  final mmdd = RegExp(r'^(\d{2})/(\d{2})$').firstMatch(renderedDate);
  if (mmdd != null) {
    final month = int.parse(mmdd.group(1)!);
    final day = int.parse(mmdd.group(2)!);
    final tomorrow = DateTime(
      now.year,
      now.month,
      now.day,
    ).add(const Duration(days: 1));
    if (month != tomorrow.month || day != tomorrow.day) {
      throw StateError(
        '$field "$renderedDate" is not tomorrow '
        '${tomorrow.month.toString().padLeft(2, '0')}/'
        '${tomorrow.day.toString().padLeft(2, '0')}',
      );
    }
    return;
  }
  // Korean "M월 D일" with optional weekday suffix.
  final match = RegExp(r'(\d{1,2})\s*월\s*(\d{1,2})\s*일').firstMatch(
    renderedDate,
  );
  if (match != null) {
    final month = int.parse(match.group(1)!);
    final day = int.parse(match.group(2)!);
    final tomorrow = DateTime(
      now.year,
      now.month,
      now.day,
    ).add(const Duration(days: 1));
    if (month != tomorrow.month || day != tomorrow.day) {
      throw StateError(
        '$field "$renderedDate" is not tomorrow '
        '${tomorrow.month}월 ${tomorrow.day}일',
      );
    }
    return;
  }
  // Unknown format. Rely on the exact equality check between before/after so
  // the date cannot silently drift.
}
