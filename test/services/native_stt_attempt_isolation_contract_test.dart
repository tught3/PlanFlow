// A11 회귀 계약 테스트: 같은 세션 재시작(rearm/restart)에서 이전 청취 시도의
// 지연 콜백이 새 시도 이벤트로 처리되던 PlanFlowSttChannel(MainActivity.kt)
// native 결함의 소스 구조 계약.
//
// 주의(한계): 본 파일은 MainActivity.kt '소스 구조'를 검사하는 계약 테스트이며
// Android SpeechRecognizer 런타임 동작 증명이 아니다(가짜 ASR/모의 네이티브 없음).
// 실기기 네이티브 검증은 별도 QA 절차에서 수행한다.
//
// 수정 전 소스 증명: NATIVE_SOURCE_UNDER_TEST=<수정 전 MainActivity.kt>로 실행하면
// 'A11 attempt isolation' 그룹의 격리 회귀 5개가 실패해야 한다(신원 격리 도입 전 구조이므로).
// 저장소(수정 후) 소스로는 전부 통과해야 한다.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const List<String> _nativeRelativeSegments = <String>[
  'android',
  'app',
  'src',
  'main',
  'kotlin',
  'com',
  'fluxstudio',
  'planflow',
  'MainActivity.kt',
];

String loadNativeSource() {
  final overridePath = Platform.environment['NATIVE_SOURCE_UNDER_TEST'];
  if (overridePath != null && overridePath.isNotEmpty) {
    return File(overridePath).readAsStringSync();
  }
  final root = Directory.current.path;
  final sep = Platform.pathSeparator;
  final prefix = root.endsWith(sep) ? root : '$root$sep';
  return File(prefix + _nativeRelativeSegments.join(sep)).readAsStringSync();
}

/// [signatureRegExp] 함수 선언부 직후의 '{' 부터 짝이 맞는 '}' 까지 본문 반환.
String bodyOf(String source, String signatureRegExp) {
  final match = RegExp(signatureRegExp).firstMatch(source);
  if (match == null) return '';
  final open = source.indexOf('{', match.end);
  if (open < 0) return '';
  var depth = 0;
  for (var i = open; i < source.length; i++) {
    final ch = source[i];
    if (ch == '{') {
      depth++;
    } else if (ch == '}') {
      depth--;
      if (depth == 0) return source.substring(open + 1, i);
    }
  }
  return '';
}

int onlyIndex(String region, String needle, String label) {
  final index = region.indexOf(needle);
  expect(index, greaterThanOrEqualTo(0), reason: '$label 코드가 없음');
  return index;
}

void main() {
  late String src;

  setUpAll(() {
    final native = loadNativeSource().replaceAll('\r\n', '\n');
    src = bodyOf(native, r'private class PlanFlowSttChannel\(');
    expect(src, isNotEmpty, reason: '실제 STT 채널 클래스가 필요하다');
  });

  group('A11 attempt isolation (source contract)', () {
    test('채널(this)을 공유 RecognitionListener로 등록하지 않는다', () {
      expect(
        src.contains('setRecognitionListener(this)'),
        isFalse,
        reason: '공유 리스너 등록이 남으면 이전 시도 콜백이 새 시도에 유입된다',
      );
    });

    test('rearm은 매번 새 인스턴스 생성 후 epoch 묶음 어댑터를 등록한다', () {
      final rearm = bodyOf(src, r'private fun rearmFreshRecognizer\(\)');
      expect(rearm, isNotEmpty, reason: 'rearmFreshRecognizer 함수가 없음');
      final iInvalidate =
          onlyIndex(rearm, 'invalidateCurrentAttempt()', 'epoch 무효화');
      final iCreate = onlyIndex(
          rearm, 'SpeechRecognizer.createSpeechRecognizer(', '새 인스턴스 생성');
      final iAttach = onlyIndex(rearm, 'AttemptListener(', '가드 어댑터 등록');
      expect(iInvalidate, lessThan(iCreate), reason: '무효화가 새 인스턴스 생성보다 먼저');
      expect(iCreate, lessThan(iAttach), reason: '생성 직후 어댑터 등록');
      expect(rearm.contains('setRecognitionListener(this)'), isFalse);
    });

    test('epoch 무효화가 리스너 탈착/cancel/destroy보다 엄격히 선행한다', () {
      final teardown = bodyOf(src, r'private fun invalidateCurrentAttempt\(\)');
      expect(teardown, isNotEmpty, reason: 'invalidateCurrentAttempt 함수가 없음');
      final iBump = onlyIndex(teardown, 'activeAttemptEpoch += 1', 'epoch 무효화');
      final iDetach =
          onlyIndex(teardown, 'setRecognitionListener(null)', '리스너 탈착');
      final iCancel = onlyIndex(teardown, '.cancel()', 'cancel');
      final iDestroy = onlyIndex(teardown, '.destroy()', 'destroy');
      expect(iBump, lessThan(iDetach));
      expect(iDetach, lessThan(iCancel));
      expect(iCancel, lessThan(iDestroy));
    });

    test('재시작 경로는 SDK 인스턴스를 재사용하지 않는다', () {
      final restart = bodyOf(src, r'private fun restartSoon\(');
      expect(restart, isNotEmpty);
      expect(
        restart.contains('invalidateCurrentAttempt()'),
        isTrue,
        reason: '재시작 예약 시점에 즉시 이전 attempt 무효화 필요',
      );
      expect(
        restart.contains('recognizer?.cancel()'),
        isFalse,
        reason: '같은 인스턴스 cancel-only 재사용 경로가 남아 있음',
      );
      expect(
        restart.contains('rearmFreshRecognizer()'),
        isTrue,
        reason: '예약 실행 시 항상 새 인스턴스로 arm해야 함',
      );
      expect(restart.contains('startListening(attempt = reason)'), isTrue);
      expect(
        src.contains('ensureRecognizer'),
        isFalse,
        reason: '인스턴스 재사용 ensureRecognizer가 다시 등장하면 안 됨',
      );
    });

    test('모든 RecognitionListener 포워딩은 신원 가드를 최우선 통과해야 한다', () {
      final adapterStart = src.indexOf('private inner class AttemptListener');
      expect(adapterStart, greaterThanOrEqualTo(0), reason: '가드 어댑터 클래스 없음');
      final adapterRegion = bodyOf(
        src,
        r'private inner class AttemptListener\(',
      );
      expect(adapterRegion, isNotEmpty);
      expect(
        src.substring(adapterStart, src.indexOf('{', adapterStart)),
        contains('private val epoch: Long'),
      );
      expect(
        src.substring(adapterStart, src.indexOf('{', adapterStart)),
        contains('private val owningRecognizer: SpeechRecognizer'),
      );
      expect(
        adapterRegion,
        contains(
            'private fun active(): Boolean = isAttemptCurrent(epoch, owningRecognizer)'),
      );
      const methodNames = <String>[
        'onReadyForSpeech',
        'onBeginningOfSpeech',
        'onRmsChanged',
        'onBufferReceived',
        'onEndOfSpeech',
        'onError',
        'onResults',
        'onPartialResults',
        'onSegmentResults',
        'onEndOfSegmentedSession',
        'onEvent',
      ];
      final guardFirst =
          RegExp(r'^\s*if \(!active\(\)\) return\s+this@PlanFlowSttChannel\.');
      for (final name in methodNames) {
        final body = bodyOf(adapterRegion, 'override fun $name\\(');
        expect(body, isNotEmpty, reason: '어댑터에 $name 포워딩 없음');
        expect(guardFirst.hasMatch(body), isTrue,
            reason: '$name 가드가 본문 최상단이어야 한다');
        final guardAt = body.indexOf('if (!active()) return');
        final forwardAt = body.indexOf('this@PlanFlowSttChannel.');
        expect(forwardAt, greaterThan(guardAt), reason: '$name 포워딩 전 가드 필요');
        expect(body, contains('this@PlanFlowSttChannel.$name('));
        expect(body.contains('logPhase'), isFalse, reason: '$name 가드 전 로그 금지');
        expect(body.contains('invokeIfActive'), isFalse);
        expect(body.contains('restartSoon'), isFalse);
      }
      for (final signature in <String>[
        r'private fun start\(',
        r'private fun cancel\(',
        r'fun dispose\(',
      ]) {
        final lifecycle = bodyOf(src, signature);
        expect(lifecycle, contains('invalidateCurrentAttempt()'));
        expect(lifecycle, contains('startGeneration += 1'));
      }
      final restart = bodyOf(src, r'private fun restartSoon\(');
      expect(
          restart,
          contains(
              'if (listening && !userRequestedStop && generation == startGeneration) {\n'
              '                rearmFreshRecognizer()'));
      // 표현식 본문(= ...) 함수라 brace 매칭 대신 선언부 영역을 직접 검사한다.
      final identityStart = src.indexOf('private fun isAttemptCurrent(');
      expect(identityStart, greaterThanOrEqualTo(0),
          reason: 'isAttemptCurrent 함수 없음');
      final identityRegion = src.substring(identityStart, identityStart + 300);
      expect(identityRegion.contains('epoch == activeAttemptEpoch'), isTrue);
      expect(
          identityRegion.contains('owningRecognizer === recognizer'), isTrue);
    });
  });

  group('기존 콜백/스케줄러/정지 계약 보존 (source contract)', () {
    test('Dart 이벤트 페이로드/누적 텍스트/스냅샷/세대 가드/정지 게이트 유지', () {
      expect(
        src.contains(
            'invokeIfActive("partial", mapOf("text" to text, "sessionId" to sessionId))'),
        isTrue,
        reason: 'partial 페이로드 계약',
      );
      expect(
        src.contains(
            'invokeIfActive("restarted", mapOf("sessionId" to sessionId, "reason" to reason))'),
        isTrue,
        reason: 'restarted 페이로드 계약',
      );
      expect(
        src.contains(
            'invokeIfActive("stopped", mapOf("text" to stopSnapshotText, "sessionId" to sessionId))'),
        isTrue,
        reason: 'stopped 페이로드 계약',
      );
      expect(
        src.contains(
            'invokeIfActive("cancelled", mapOf("text" to latestPartialText, "sessionId" to sessionId))'),
        isTrue,
        reason: 'cancelled 페이로드 계약',
      );
      expect(src.contains('latestPartialText = text'), isTrue,
          reason: '유효 재시작 간 인식 텍스트 누적 유지');
      expect(src.contains('publishText(results, phase = "final")'), isTrue);
      expect(src.contains('stopSnapshotText = latestPartialText'), isTrue,
          reason: '스냅샷 폴백 유지');
      expect(src.contains('generation == startGeneration'), isTrue,
          reason: '예약 재시작 세대 가드 유지');
      expect(src.contains('if (!listening || userRequestedStop)'), isTrue,
          reason: '사용자 정지 시 자동 재시작 금지 게이트 유지');
      expect(src.contains('if (userRequestedStop) {'), isTrue);
      final stop = bodyOf(src, r'"stop" ->');
      expect(stop, contains('recognizer?.stopListening()'));
      expect(stop, isNot(contains('invalidateCurrentAttempt()')),
          reason: 'stop은 현재 listener를 유지하여 stopped ack를 받아야 한다');
    });

    test('금지된 P0 250ms 나이 휴리스틱이 없다(신원 해결만 허용)', () {
      expect(src.contains('stale_final_restart_skipped'), isFalse);
      expect(RegExp('lastStartListeningAtMs').hasMatch(src), isFalse);
    });
  });
}
