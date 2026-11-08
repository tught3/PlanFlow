// emulator_voice_tour_display_probe.dart
//
// Voice-first feature tour UI simulator (mock voice + scripted native
// callbacks). NOT ASR. No microphone, no recognizer, no OS audio. The native
// QA clone of PlanFlowSttChannel exposes a deterministic callback-replay
// method (`qaAttemptIsolationReplay`) which this probe invokes BEFORE the
// tour UI pumps; the replay exercises the AttemptListener generation
// guards without touching a recognizer. After the replay, the probe pumps
// `FeatureTourScreen` with a typed-script fake `VoiceCapture` (copied from
// the existing unit-fake pattern in `test/screens/feature_tour_screen_test.dart`)
// so the entire UI workflow runs against:
//   * a clearly-visible "QA 모의 음성 UI · 콜백 재현 / NOT ASR" banner,
//   * a fake capture whose partials/finals are typed strings,
//   * the unchanged production parser pipeline in the screen,
//   * real tour keys (`voice-tour-mic-button`, `voice-tour-save-create`,
//     `voice-tour-create-preview`, `voice-tour-results`, the
//     `voice-tour-result-<id>` row group, `voice-tour-edit-preview`,
//     `voice-tour-save-edit`, `voice-tour-open-updated`,
//     `voice-tour-detail-event-<id>`, `voice-tour-detail-title`,
//     `voice-tour-detail-location`, `voice-tour-detail-date`,
//     `voice-tour-detail-event-time`, `voice-tour-detail-departure`,
//     `voice-tour-detail-preparation`).
//
// Same-id title/location/date equality + 09:00 → 13:00 time change +
// departure 12:30 + preparation 12:15 reuse the existing native probe
// assertions; nothing is canned or seeded.
//
// Opt-in only:
//   flutter test integration_test/emulator_voice_tour_display_probe.dart \
//     -d <android-device> --dart-define=VOICE_TOUR_UI_SIM_PROBE=true
//
// On success the harness prints ONE compact `VOICE_TOUR_UI_SIM_READY`
// JSON line carrying the native-replay descriptor + the actual stored
// detail fields, then BLOCKS on a unique-nonce close-marker file
// (250 ms poll, 2 h timeout) so the parent can capture the saved-detail
// UI without the test going idle. The IntegrationTestWidgetsFlutterBinding
// stays fully live; the tour screen is never finished.
//
// On failure the harness prints ONE compact `VOICE_TOUR_UI_SIM_FAIL`
// JSON line and rethrows. No false READY. No `markTestSkipped` is ever
// used to fabricate a passing run.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:planflow/l10n/app_localizations.dart';
import 'package:planflow/screens/onboarding/feature_tour_screen.dart';
import 'package:planflow/screens/onboarding/voice_first_tour_voice_capture.dart';
import 'package:planflow/services/feature_tour_service.dart';

// ---- opt-in flag --------------------------------------------------------

const bool _uiSimEnabled = bool.fromEnvironment(
  'VOICE_TOUR_UI_SIM_PROBE',
  defaultValue: false,
);

// ---- protocol markers (parent greps these) ----------------------------

const String _prefixReady = 'VOICE_TOUR_UI_SIM_READY';
const String _prefixFail = 'VOICE_TOUR_UI_SIM_FAIL';
const String _bannerText = 'QA 모의 음성 UI · 콜백 재현 / NOT ASR';

// ---- QA native self-test control strings ------------------------------
// The QA clone's `publishText` route always emits `"partial"` to the
// channel (it does not differentiate "final"), so both the scripted
// current-partial and the scripted current-final land in the Dart
// collector as `partial` events with these two control strings. The
// stale AttemptListener (epoch A) is invoked first with neutral QA
// bundles; its `active()` guard returns false so no event reaches the
// channel.
const String _controlPartialText = 'QA-CONTROL-PARTIAL';
const String _controlFinalText = 'QA-CONTROL-FINAL';

// ---- hold/close lease -------------------------------------------------

const Duration _closePollInterval = Duration(milliseconds: 250);
const Duration _closeTimeout = Duration(hours: 2);

// =========================================================================
// In-memory store (no SharedPreferences persistence required for the tour
// itself; SharedPreferences is mocked only for plugins that may probe it
// at pump time. No real DB, calendar, alarm, sync, route, network, paid
// API is touched.
// =========================================================================

class _MemoryFeatureTourStore implements FeatureTourStore {
  bool completed = false;

  @override
  Future<bool> shouldShow() async => !completed;

  @override
  Future<void> markCompleted() async {
    completed = true;
  }

  @override
  Future<bool> shouldShowTip(String tipId) async => true;

  @override
  Future<void> markTipShown(String tipId) async {}
}

// =========================================================================
// Typed-script fake VoiceCapture. Mirrors the existing
// `_ScriptedVoiceCapture` in `test/screens/feature_tour_screen_test.dart`:
// typed transcripts, scripted ready/partial/final, no engine, no ASR.
// =========================================================================

class _ScriptedVoiceCapture implements VoiceCapture {
  int listenCalls = 0;
  int stopCalls = 0;
  int cancelCalls = 0;

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
    _active = Completer<VoiceCaptureResult>();
    return _active!.future;
  }

  void emitReady() {
    _ready = true;
    _onReady?.call(true);
  }

  void emitPartial(String text) => _onPartial?.call(text);

  void emitFinal(String text) => _finish(VoiceCaptureResult(text: text));

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
  }

  @override
  Future<void> cancel() async {
    cancelCalls++;
    _finish(
      const VoiceCaptureResult(silence: true, message: '취소했어요.'),
    );
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'voice-tour UI simulator: scripted native callbacks + mock voice',
    (tester) async {
      if (!_uiSimEnabled) {
        markTestSkipped('VOICE_TOUR_UI_SIM_PROBE is not enabled.');
        return;
      }

      // -----------------------------------------------------------------
      // runId + cache directory + close marker (unique per run).
      // -----------------------------------------------------------------
      final now = DateTime.now();
      final runId =
          'sim-${now.microsecondsSinceEpoch}-${math.Random().nextInt(1 << 30)}';
      final cacheDir = Directory(
        '${Directory.systemTemp.path}/voice-tour-ui-sim-$runId',
      );
      await cacheDir.create(recursive: true);
      final closeMarker = File('${cacheDir.path}/close.done');

      Map<String, Object?> nativeReplay = const <String, Object?>{};
      String failureStage = 'boot';

      try {
        // ---------------------------------------------------------------
        // 1. QA self-test: scripted partial + final through the existing
        //    `planflow/native_stt` channel; no recognizer listening, no
        //    microphone. Result must be a compact JSON descriptor.
        // ---------------------------------------------------------------
        const channel = MethodChannel('planflow/native_stt');
        final events = <Map<String, Object?>>[];
        Future<dynamic> collector(MethodCall call) async {
          events.add(<String, Object?>{
            'method': call.method,
            'args': call.arguments,
          });
          return null;
        }

        channel.setMethodCallHandler(collector);
        Object? raw;
        try {
          raw = await channel.invokeMethod<Object>(
            'qaAttemptIsolationReplay',
            <String, Object?>{'runId': runId},
          );
          if (raw == null) {
            throw StateError(
              'qaAttemptIsolationReplay returned null on Android main.',
            );
          }
          // Brief settling window. The replay returns synchronously
          // (Result.success) before the channel handler queues any
          // additional events; 50 ms is enough for the two scripted
          // `invokeIfActive("partial", ...)` writes to flush.
          await Future<void>.delayed(const Duration(milliseconds: 50));
        } finally {
          channel.setMethodCallHandler(null);
        }

        nativeReplay = jsonDecode(raw as String) as Map<String, Object?>;

        failureStage = 'native-replay';
        // Exactly two current-generation partial events, control strings
        // in the order partial -> final. No ready/error/etc. — the OLD
        // listener's `active()` guard returns false, so no events for
        // the stale generation can reach the channel.
        if (events.length != 2) {
          throw StateError(
            'Expected exactly 2 current-generation partial events, got '
            '${events.length}: ${jsonEncode(events)}',
          );
        }
        for (final ev in events) {
          if (ev['method'] != 'partial') {
            throw StateError(
              'Unexpected method ${ev['method']} from QA self-test '
              '(only "partial" allowed). Got ${jsonEncode(ev)}.',
            );
          }
          final args = ev['args'];
          if (args is! Map) {
            throw StateError('partial event missing args map: $ev');
          }
          final text = args['text'];
          if (text != _controlPartialText && text != _controlFinalText) {
            throw StateError(
              'partial event text $text is not a QA control string '
              '($_controlPartialText / $_controlFinalText).',
            );
          }
        }
        final first = (events[0]['args'] as Map)['text'];
        final second = (events[1]['args'] as Map)['text'];
        if (first != _controlPartialText || second != _controlFinalText) {
          throw StateError(
            'Wrong event order. expected '
            '[$_controlPartialText, $_controlFinalText] got '
            '[$first, $second].',
          );
        }

        if (nativeReplay['type'] != 'scripted callbacks NOT ASR') {
          throw StateError(
            'nativeReplay.type mismatch: ${nativeReplay['type']}',
          );
        }
        for (final flag in <String>[
          'freshInstance',
          'staleCriticalCallbacksIgnored',
          'currentTextForwarded',
          'listeningFalse',
          'cleanup',
        ]) {
          if (nativeReplay[flag] != true) {
            throw StateError(
              'nativeReplay.$flag must be true; got '
              '${nativeReplay[flag]}.',
            );
          }
        }
        if (nativeReplay['realAsrPassed'] == true) {
          throw StateError(
            'nativeReplay.realAsrPassed must be false (no ASR).',
          );
        }

        // ---------------------------------------------------------------
        // 2. Pump the tour UI with the typed-script fake capture.
        //    No controller/data-store seeding, no direct mutation of the
        //    controller — only taps on real widgets.
        // ---------------------------------------------------------------
        SharedPreferences.setMockInitialValues(<String, Object>{});
        final store = _MemoryFeatureTourStore();
        final capture = _ScriptedVoiceCapture();
        var completedCalls = 0;

        await tester.pumpWidget(
          MaterialApp(
            locale: const Locale('ko'),
            theme: ThemeData(),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                alwaysUse24HourFormat: true,
                textScaler: TextScaler.linear(1.0),
              ),
              child: Stack(
                children: [
                  child!,
                  Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
                    child: SafeArea(
                      child: Container(
                        color: const Color(0xFFD32F2F),
                        padding: const EdgeInsets.symmetric(
                          vertical: 6,
                          horizontal: 12,
                        ),
                        child: const Text(
                          _bannerText,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 13,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            home: FeatureTourScreen(
              store: store,
              requireFinalConfirmation: true,
              nowProvider: () => now,
              onCompleted: () => completedCalls++,
              voiceCapture: capture,
            ),
          ),
        );

        // ---------- CREATE ----------
        failureStage = 'create';
        await _ensureVisible(
          tester,
          find.byKey(const ValueKey('voice-tour-mic-button')),
        );
        await tester.tap(find.byKey(const ValueKey('voice-tour-mic-button')));
        await tester.pump();
        capture.emitReady();
        await tester.pump();
        capture.emitPartial('내일 오전');
        await tester.pump();
        // Final transcript is the MOCK ASR text. Production parser
        // resolves the rest of the create-preview rows.
        capture.emitFinal('내일 오전 9시에 강남역에서 팀장님과 면담');
        await tester.pumpAndSettle();

        await _pumpUntil(
          tester,
          find.byKey(const ValueKey('voice-tour-create-preview')),
          'create preview',
        );
        final createPreview = _keyText(
          tester,
          'voice-tour-create-preview',
        );
        _requireContains(
          createPreview,
          '강남역 팀장님과 면담',
          'create preview title',
        );
        _requireContains(createPreview, '09:00', 'create preview time');
        _requireContains(createPreview, '강남역', 'create preview location');

        await _ensureVisible(
          tester,
          find.byKey(const ValueKey('voice-tour-save-create')),
        );
        await tester.tap(find.byKey(const ValueKey('voice-tour-save-create')));
        await tester.pumpAndSettle();

        // ---------- QUERY ----------
        failureStage = 'query';
        await _ensureVisible(
          tester,
          find.byKey(const ValueKey('voice-tour-mic-button')),
        );
        await tester.tap(find.byKey(const ValueKey('voice-tour-mic-button')));
        await tester.pump();
        capture.emitReady();
        await tester.pump();
        capture.emitPartial('내일 일정');
        await tester.pump();
        capture.emitFinal('내일 일정 보여줘');
        await tester.pumpAndSettle();

        await _pumpUntil(
          tester,
          find.byKey(const ValueKey('voice-tour-results')),
          'query results',
        );
        // Same row-selector pattern used in the native probe: pick the
        // outer row container, not the sub-keyed descendants.
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
        await _pumpUntil(tester, firstRow, 'first saved query row');
        final rowKey =
            firstRow.evaluate().first.widget.key! as ValueKey<String>;
        final queryEventId =
            rowKey.value.substring('voice-tour-result-'.length);

        final queryBefore = <String, String>{
          'id': queryEventId,
          'title': _keyText(
            tester,
            'voice-tour-result-title-$queryEventId',
          ),
          'location': _keyText(
            tester,
            'voice-tour-result-location-$queryEventId',
          ),
          'date': _keyText(
            tester,
            'voice-tour-result-date-$queryEventId',
          ),
          'time': _keyText(
            tester,
            'voice-tour-result-time-$queryEventId',
          ),
        };
        _requireNonEmpty(queryBefore['title']!, 'query result title');
        _requireNonEmpty(queryBefore['location']!, 'query result location');
        _requireNonEmpty(queryBefore['date']!, 'query result date');
        _requireNonEmpty(queryBefore['time']!, 'query result time');
        _requireContains(queryBefore['time']!, '09:00', 'query result time');
        _verifyTomorrowIfKnown(queryBefore['date']!, now, 'query date');

        // ---------- EDIT ----------
        failureStage = 'edit';
        await _ensureVisible(
          tester,
          find.byKey(const ValueKey('voice-tour-mic-button')),
        );
        await tester.tap(find.byKey(const ValueKey('voice-tour-mic-button')));
        await tester.pump();
        capture.emitReady();
        await tester.pump();
        capture.emitPartial('첫 번째');
        await tester.pump();
        capture.emitFinal('첫 번째 일정 오후 1시로 미뤄줘');
        await tester.pumpAndSettle();

        await _pumpUntil(
          tester,
          find.byKey(const ValueKey('voice-tour-edit-preview')),
          'edit preview',
        );
        final editPreview = _keyText(
          tester,
          'voice-tour-edit-preview',
        );
        _requireContains(editPreview, '13:00', 'edit preview new time');
        // Original 09:00 should still appear (the FROM-time row).
        _requireContains(editPreview, '09:00', 'edit preview old time');

        await _ensureVisible(
          tester,
          find.byKey(const ValueKey('voice-tour-save-edit')),
        );
        await tester.tap(find.byKey(const ValueKey('voice-tour-save-edit')));
        await tester.pumpAndSettle();

        // ---------- DETAIL ----------
        failureStage = 'detail';
        await _pumpUntil(
          tester,
          find.byKey(const ValueKey('voice-tour-open-updated')),
          'open-updated',
        );
        await _ensureVisible(
          tester,
          find.byKey(const ValueKey('voice-tour-open-updated')),
        );
        await tester.tap(
          find.byKey(const ValueKey('voice-tour-open-updated')),
        );
        await tester.pumpAndSettle();

        await _pumpUntil(
          tester,
          find.byKey(
            ValueKey<String>('voice-tour-detail-event-$queryEventId'),
          ),
          'same saved record detail',
        );

        final detailAfter = <String, String>{
          'id': queryEventId,
          'title': _keyText(tester, 'voice-tour-detail-title'),
          'location': _keyText(tester, 'voice-tour-detail-location'),
          'date': _keyText(tester, 'voice-tour-detail-date'),
          'eventTime': _keyText(tester, 'voice-tour-detail-event-time'),
          'departure': _keyText(tester, 'voice-tour-detail-departure'),
          'preparation': _keyText(tester, 'voice-tour-detail-preparation'),
        };
        _requireNonEmpty(detailAfter['title']!, 'detail title');
        _requireNonEmpty(detailAfter['location']!, 'detail location');
        _requireNonEmpty(detailAfter['date']!, 'detail date');
        _requireNonEmpty(detailAfter['eventTime']!, 'detail event time');
        _requireNonEmpty(detailAfter['departure']!, 'detail departure');
        _requireNonEmpty(detailAfter['preparation']!, 'detail preparation');

        // Same-id field equality (title/location/date preserved).
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

        // Time changed 09:00 -> 13:00; old value must be gone.
        _requireContains(detailAfter['eventTime']!, '13:00',
            'detail event time');
        if (detailAfter['eventTime']!.contains('09:00')) {
          throw StateError(
            'detail eventTime still contains old 09:00: '
            '${detailAfter['eventTime']}',
          );
        }
        // Derived: -30 departure, -45 preparation.
        _requireContains(
          detailAfter['departure']!,
          '12:30',
          'detail departure',
        );
        _requireContains(
          detailAfter['preparation']!,
          '12:15',
          'detail preparation',
        );

        // ---------------------------------------------------------------
        // 3. Print ONE compact READY JSON. Hold for close marker (NO
        //    Finish tap). The IntegrationTestWidgetsFlutterBinding stays
        //    live so the parent can grab a screenshot of the saved
        //    detail view at any time.
        // ---------------------------------------------------------------
        failureStage = 'saved-detail-hold';
        final ready = <String, Object?>{
          'runId': runId,
          'phase': 'saved-detail-hold',
          'inputMode': 'mock-voice-not-asr',
          'nativeReplay': nativeReplay,
          'detailId': detailAfter['id'],
          'detailTitle': detailAfter['title'],
          'detailLocation': detailAfter['location'],
          'detailDate': detailAfter['date'],
          'eventTime': detailAfter['eventTime'],
          'departure': detailAfter['departure'],
          'preparation': detailAfter['preparation'],
          'markerPath': closeMarker.path,
          'realAsrPassed': false,
          'completionCallbacks': completedCalls,
          'storeCompleted': store.completed,
          'bannerText': _bannerText,
        };
        // ignore: avoid_print
        print('$_prefixReady ${jsonEncode(ready)}');

        final end = DateTime.now().add(_closeTimeout);
        while (DateTime.now().isBefore(end)) {
          await tester.pump(_closePollInterval);
          if (await closeMarker.exists()) {
            try {
              await closeMarker.delete();
            } catch (_) {/* best-effort cleanup */}
            break;
          }
        }
        // Test stays visible. No Finish tap. Cache cleanup is best-effort.
        if (await cacheDir.exists()) {
          try {
            await cacheDir.delete(recursive: true);
          } catch (_) {/* best-effort cleanup */}
        }
      } catch (e, _) {
        final fail = <String, Object?>{
          'runId': runId,
          'phase': failureStage,
          'reason': '$e',
          'nativeReplay': nativeReplay,
          'realAsrPassed': false,
        };
        // ignore: avoid_print
        print('$_prefixFail ${jsonEncode(fail)}');
        rethrow;
      }
    },
  );
}

// =========================================================================
// helpers (no generic framework; thin re-use of native-probe patterns)
// =========================================================================

Future<void> _ensureVisible(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pump();
}

Future<void> _pumpUntil(
  WidgetTester tester,
  Finder finder,
  String label,
) async {
  final end = DateTime.now().add(const Duration(seconds: 30));
  while (DateTime.now().isBefore(end)) {
    await tester.pump(const Duration(milliseconds: 100));
    if (finder.evaluate().isNotEmpty) return;
  }
  throw TimeoutException(
    'Timed out waiting for $label',
    const Duration(seconds: 30),
  );
}

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

void _requireNonEmpty(String actual, String field) {
  if (actual.trim().isEmpty) {
    throw StateError(
      'No actual saved field rendered for $field (got: "$actual").',
    );
  }
}

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

void _verifyTomorrowIfKnown(
  String renderedDate,
  DateTime now,
  String field,
) {
  DateTime? parsed = DateTime.tryParse(renderedDate);
  if (parsed != null) {
    final tomorrow = DateTime(now.year, now.month, now.day)
        .add(const Duration(days: 1));
    if (parsed.year != tomorrow.year ||
        parsed.month != tomorrow.month ||
        parsed.day != tomorrow.day) {
      throw StateError(
        '$field "$renderedDate" is not tomorrow $tomorrow',
      );
    }
    return;
  }
  final mmdd = RegExp(r'^(\d{2})/(\d{2})$').firstMatch(renderedDate);
  if (mmdd != null) {
    final month = int.parse(mmdd.group(1)!);
    final day = int.parse(mmdd.group(2)!);
    final tomorrow = DateTime(now.year, now.month, now.day)
        .add(const Duration(days: 1));
    if (month != tomorrow.month || day != tomorrow.day) {
      throw StateError(
        '$field "$renderedDate" is not tomorrow '
        '${tomorrow.month.toString().padLeft(2, '0')}/'
        '${tomorrow.day.toString().padLeft(2, '0')}',
      );
    }
    return;
  }
  // MM/DD HH:MM stamp; the date is the MM/DD prefix.
  final stamp =
      RegExp(r'^(\d{2})/(\d{2})\s+\d{2}:\d{2}$').firstMatch(renderedDate);
  if (stamp != null) {
    final month = int.parse(stamp.group(1)!);
    final day = int.parse(stamp.group(2)!);
    final tomorrow = DateTime(now.year, now.month, now.day)
        .add(const Duration(days: 1));
    if (month != tomorrow.month || day != tomorrow.day) {
      throw StateError(
        '$field "$renderedDate" is not tomorrow '
        '${tomorrow.month.toString().padLeft(2, '0')}/'
        '${tomorrow.day.toString().padLeft(2, '0')}',
      );
    }
    return;
  }
  // Unknown format — rely on equality vs query before.
}