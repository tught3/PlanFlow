// Real-engine PCM ASR preflight harness (QA build only).
//
// PURPOSE: ONE phrase of actual PCM audio (raw 16k/s16le/mono create.pcm
// pushed by the parent) is fed to the OS SpeechRecognizer via
// RecognizerIntent.EXTRA_AUDIO_SOURCE (native op 'qaPcmAsrPreflight').
// This is NOT a live microphone capture, NOT a mock/scripted ASR, and NOT
// the full FeatureTour flow. A nonempty transcript only proves the engine
// returned text for file audio; fullUiFlowPassed stays false and the
// parent decides whether to proceed to the full flow.
//
// Protocol (parent greps stdout):
//   PCM_ASR_PREFLIGHT_RESULT {json}  // exactly once, actual native data
//   PCM_ASR_PREFLIGHT_FAIL {reason}  // only on exceptions
// Hold: stays alive up to 2h; release early by writing the exact runId
// into the close marker path printed in the RESULT json.
// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

/// Entry flag. Default false: nothing runs until explicitly enabled for a
/// deliberate preflight run.
const bool PCM_ASR_PREFLIGHT = bool.fromEnvironment('PCM_ASR_PREFLIGHT',defaultValue:false); // ignore: constant_identifier_names
const bool PCM_ASR_DOWNLOAD_ON_UNKNOWN = bool.fromEnvironment('PCM_ASR_DOWNLOAD_ON_UNKNOWN',defaultValue:false); // ignore: constant_identifier_names
const bool PCM_ASR_USE_ON_DEVICE = bool.fromEnvironment('PCM_ASR_USE_ON_DEVICE',defaultValue:false); // ignore: constant_identifier_names
const bool PCM_ASR_PREFER_OFFLINE = bool.fromEnvironment('PCM_ASR_PREFER_OFFLINE', defaultValue: true); // ignore: constant_identifier_names

/// If the file-FD transcribe attempt returns no actual final text, retry
/// exactly once through a pipe (still file audio; no host audio involved).
const bool PIPE_FALLBACK_IF_NO_FINAL = true; // ignore: constant_identifier_names

const String _sttChannel = 'planflow/native_stt';
const String _resultPrefix = 'PCM_ASR_PREFLIGHT_RESULT';
const String _failPrefix = 'PCM_ASR_PREFLIGHT_FAIL';
const Duration _downloadGuard = Duration(seconds: 150);
const Duration _holdTimeout = Duration(hours: 2);
const Duration _holdPoll = Duration(milliseconds: 250);
const Duration _testTimeout = Duration(hours: 2, minutes: 10);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'real engine PCM ASR preflight (not live mic)',
    (tester) async {
      final lines = ValueNotifier<List<String>>(<String>[]);
      await tester.pumpWidget(PcmAsrPreflightApp(lines: lines));

      if (!PCM_ASR_PREFLIGHT) {
        fail('PCM_ASR_PREFLIGHT flag is false; flip it to true to run the '
            'real-engine PCM preflight.');
      }

      void say(String line) {
        print('[pcm-preflight] $line');
        lines.value = [...lines.value, line];
        tester.binding.scheduleFrame();
      }

      final runId = 'pcm-asr-preflight-${DateTime.now().millisecondsSinceEpoch}';
      final pcmDir = Directory('${Directory.systemTemp.path}/frm9-pcm-preflight');
      final pcmFile = File('${pcmDir.path}/create.pcm');
      final closeMarker = File('${pcmDir.path}/close-$runId.done');

      Map<String, dynamic>? support;
      Map<String, dynamic>? download;
      final attempts = <Map<String, dynamic>>[];

      try {
        // PCM input must exist and be nonempty before ANY ASR call.
        if (!await pcmFile.exists() || await pcmFile.length() == 0) {
          throw StateError('PCM input missing/empty: ${pcmFile.path}');
        }
        say('PCM input ok: ${pcmFile.path} (${await pcmFile.length()}B)');

        // 1) Support check: actual RecognitionSupport fields from the device.
        try {
          support = await callNative(const {'op': 'support'});
        } on PlatformException catch (e) {
          support = {'platformError': e.code, 'detail': e.message};
        }
        say('support: ${jsonEncode(support)}');

        // 2) Optional ONE free model download if ko is downloadable/pending
        //    but NOT installed, or explicitly requested on unknown support.
        final downloadOnUnknown = PCM_ASR_DOWNLOAD_ON_UNKNOWN && support?['engineErrorCode'] == 14;
        if (needsKoDownload(support) || downloadOnUnknown) {
          say(downloadOnUnknown
              ? 'one download requested on unknown support; availability unconfirmed'
              : 'ko not installed but downloadable/pending; one download');
          try {
            download = await callNative(const {'op': 'download'}).timeout(
              _downloadGuard,
              onTimeout: () => <String, dynamic>{
                'timeout': true,
                'guardMs': _downloadGuard.inMilliseconds,
              },
            );
          } on PlatformException catch (e) {
            download = {'platformError': e.code, 'detail': e.message};
          }
          say('download: ${jsonEncode(download)}');
        }

        // 3) Transcribe the file through the real engine: file FD first,
        //    optional single pipe retry; bounded to exactly <=2 attempts.
        final fileAttempt = await callNative(
          const {'op': 'transcribe', 'mode': 'file'},
        );
        attempts.add(fileAttempt);
        say('transcribe(file): ${jsonEncode(fileAttempt)}');
        if (hasActualFinalText(fileAttempt)) {
          // Actual engine output; language may be wrong, so labeled as raw.
          say('RAW 엔진 출력(언어 다를 수 있음): ${fileAttempt['finalText']}');
        }
        if (!hasActualFinalText(fileAttempt) && PIPE_FALLBACK_IF_NO_FINAL) {
          final pipeAttempt = await callNative(
            const {'op': 'transcribe', 'mode': 'pipe'},
          );
          attempts.add(pipeAttempt);
          say('transcribe(pipe): ${jsonEncode(pipeAttempt)}');
          if (hasActualFinalText(pipeAttempt)) {
            say('RAW 엔진 출력(언어 다를 수 있음): ${pipeAttempt['finalText']}');
          }
        }
      } catch (error) {
        say('preflight error: $error');
        print('$_failPrefix ${error.runtimeType}: $error');
      }

      // ONE compact result line built from actual native returns only.
      final payload = <String, dynamic>{
        'inputMode': 'raw-pcm-real-engine-not-live-mic',
        'support': support,
        if (download != null) 'download': download,
        'attempts': attempts,
        'fullUiFlowPassed': false,
        'actualLiveMicrophoneVerified': false,
        'phase': 'held-result',
        'runId': runId,
        'closeMarker': closeMarker.path,
      };
      print('$_resultPrefix ${jsonEncode(payload)}');
      say('RESULT printed; holding up to $_holdTimeout '
          '(write "$runId" into ${closeMarker.path} to release)');

      // 4) Hold alive with fully live pumps until the close marker carries
      //    the exact runId, or the 2h hold lease expires.
      final holdDeadline = DateTime.now().add(_holdTimeout);
      while (DateTime.now().isBefore(holdDeadline)) {
        await tester.pump(_holdPoll);
        if (await closeMarker.exists()) {
          final content = (await closeMarker.readAsString()).trim();
          if (content == runId) {
            say('close marker verified; releasing');
            break;
          }
        }
      }
    },
    timeout: const Timeout(_testTimeout),
  );
}

/// Invokes the hard-gated QA preflight method. Native returns a Map (JSON
/// string also accepted); never fabricates values itself.
Future<Map<String, dynamic>> callNative(Map<String, Object?> args) async {
  final withEngine = <String, Object?>{
    ...args,
    'engine': PCM_ASR_USE_ON_DEVICE ? 'on-device' : 'default',
    'preferOffline': PCM_ASR_PREFER_OFFLINE,
  };
  final raw = await const MethodChannel(_sttChannel)
      .invokeMethod<dynamic>('qaPcmAsrPreflight', withEngine);
  if (raw is Map) {
    return raw.map((key, value) => MapEntry('$key', value));
  }
  if (raw is String) {
    return (jsonDecode(raw) as Map).map((key, value) => MapEntry('$key', value));
  }
  throw StateError('unexpected native return: ${raw.runtimeType}');
}

bool hasActualFinalText(Map<String, dynamic> attempt) {
  final finals = attempt['finalResults'];
  if (finals is List && finals.any((e) => '$e'.trim().isNotEmpty)) {
    return true;
  }
  return '${attempt['finalText'] ?? ''}'.trim().isNotEmpty;
}

bool _langListHasKo(List<dynamic>? langs) =>
    langs?.any((l) => '$l' == 'ko-KR' || '$l'.startsWith('ko')) ?? false;

bool needsKoDownload(Map<String, dynamic>? support) {
  if (support == null || support['platformError'] != null) return false;
  final nestedSupport = support['support'];
  if (nestedSupport is! Map) return false;
  support = Map<String, dynamic>.from(nestedSupport);
  if (_langListHasKo(support['installedOnDeviceLanguages'] as List<dynamic>?)) {
    return false;
  }
  final pending = _langListHasKo(support['pendingOnDeviceLanguages'] as List<dynamic>?);
  final downloadable =
      _langListHasKo(support['supportedOnDeviceLanguages'] as List<dynamic>?);
  return pending || downloadable;
}

/// Minimal always-on QA surface: banner + actual status lines, selectable
/// and scrollable so the real support/download/result/error evidence stays
/// visible on the VM screen for the whole hold.
class PcmAsrPreflightApp extends StatelessWidget {
  const PcmAsrPreflightApp({super.key, required this.lines});

  final ValueNotifier<List<String>> lines;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        appBar: AppBar(
          title: const Text('PCM ASR Preflight'),
          backgroundColor: Colors.deepOrange,
        ),
        body: ValueListenableBuilder<List<String>>(
          valueListenable: lines,
          builder: (context, value, _) {
            return ListView(
              padding: const EdgeInsets.all(12),
              children: [
                Container(
                  color: Colors.deepOrange,
                  padding: const EdgeInsets.symmetric(
                    vertical: 10,
                    horizontal: 12,
                  ),
                  child: const SelectableText(
                    '실제 ASR 음원 입력 검사 · 라이브 마이크 아님',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                ...value.map(
                  (line) => Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: SelectableText(line),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
