import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/core/analytics_service.dart';

/// AnalyticsService의 음성 대화 진입/소비 퍼널 이벤트(9개) 회귀 테스트.
///
/// 목적:
/// 1. 신규 9개 메서드가 실제로 존재하고 컴파일 타임에 호출 가능한지 확인.
/// 2. [PREVENT] 개인정보 보호 회귀 방지 — 각 메서드 시그니처에 자유텍스트
///    `String` 파라미터가 섞여 들어가지 않았는지 소스코드 정적 검사로
///    기계적으로 검증한다. 향후 누군가 실수로 발화 원문/일정 제목 등을
///    자유형 String 파라미터로 추가하면 이 테스트가 즉시 실패해야 한다.
void main() {
  group('VoiceConv 진입/소비 퍼널 이벤트 - 호출 가능성', () {
    test('9개 신규 메서드가 모두 존재하고 정상 호출된다', () async {
      // 컴파일이 되는 것 자체가 존재 증명이지만, 런타임 no-op 동작도 확인.
      await AnalyticsService.logVoiceConvEntryDirect();
      await AnalyticsService.logVoiceConvEntryQuery();
      await AnalyticsService.logVoiceConvEntryDeeplink();
      await AnalyticsService.logVoiceConvInitialFreeUsed(remainingAfter: 3);
      await AnalyticsService.logVoiceConvDailyFreeUsed(remainingAfter: 1);
      await AnalyticsService.logVoiceConvAdRequired();
      await AnalyticsService.logVoiceConvAdCompleted();
      await AnalyticsService.logVoiceConvSessionStarted(
        source: VoiceConvSessionSource.initialFree,
      );
      await AnalyticsService.logVoiceConvSessionStarted(
        source: VoiceConvSessionSource.dailyFree,
      );
      await AnalyticsService.logVoiceConvSessionStarted(
        source: VoiceConvSessionSource.adRewarded,
      );
      await AnalyticsService.logVoiceConvSessionAbandonedBeforeUse();

      // 예외 없이 도달하면 전부 정상 호출된 것.
      expect(true, isTrue);
    });

    test('VoiceConvSessionSource enum 값이 고정된 wireValue를 갖는다', () {
      expect(
        VoiceConvSessionSource.initialFree.wireValue,
        'initial_free',
      );
      expect(VoiceConvSessionSource.dailyFree.wireValue, 'daily_free');
      expect(VoiceConvSessionSource.adRewarded.wireValue, 'ad_rewarded');
    });
  });

  group('VoiceConv 진입/소비 퍼널 이벤트 - 개인정보 미포함 정적 검증', () {
    // 검증 대상 9개 메서드명.
    const methodNames = <String>[
      'logVoiceConvEntryDirect',
      'logVoiceConvEntryQuery',
      'logVoiceConvEntryDeeplink',
      'logVoiceConvInitialFreeUsed',
      'logVoiceConvDailyFreeUsed',
      'logVoiceConvAdRequired',
      'logVoiceConvAdCompleted',
      'logVoiceConvSessionStarted',
      'logVoiceConvSessionAbandonedBeforeUse',
    ];

    late String source;

    setUpAll(() {
      final file = File('lib/core/analytics_service.dart');
      expect(
        file.existsSync(),
        isTrue,
        reason: 'lib/core/analytics_service.dart 파일을 찾을 수 없음',
      );
      source = file.readAsStringSync();
    });

    for (final methodName in methodNames) {
      test('$methodName 시그니처에 자유형 String 파라미터가 없다', () {
        // "static Future<void> <methodName>(" 부터 그 메서드의 파라미터
        // 목록이 끝나는 지점(=> 또는 { 직전 닫는 괄호)까지를 추출한다.
        final declPattern = RegExp(
          r'static\s+Future<void>\s+' + methodName + r'\s*\(',
        );
        final match = declPattern.firstMatch(source);
        expect(
          match,
          isNotNull,
          reason: '$methodName 선언을 소스에서 찾을 수 없음 (메서드가 삭제/이름변경됐을 수 있음)',
        );

        // 괄호 depth를 세어 파라미터 목록의 닫는 괄호 위치를 정확히 찾는다.
        final startIdx = match!.end; // '(' 바로 다음 인덱스
        var depth = 1;
        var idx = startIdx;
        while (depth > 0 && idx < source.length) {
          final ch = source[idx];
          if (ch == '(') depth++;
          if (ch == ')') depth--;
          idx++;
        }
        expect(
          depth,
          0,
          reason: '$methodName 파라미터 목록의 닫는 괄호를 찾지 못함(괄호 불균형)',
        );
        final paramList = source.substring(startIdx, idx - 1);

        // 자유형 String 파라미터 금지: 파라미터 목록 안에 'String' 타입
        // 토큰이 등장하면 안 된다(허용 타입: int, VoiceConvSessionSource 등
        // 제한된 enum). 단순 substring 검사로 충분 — 이 파일에서 String이
        // 등장한다면 그 자체가 자유형 문자열 파라미터를 의미한다.
        expect(
          paramList.contains('String'),
          isFalse,
          reason:
              '$methodName 파라미터 목록에 String 타입이 발견됨: "$paramList" '
              '— 자유텍스트 파라미터는 금지되어 있다. int 또는 제한된 enum만 허용.',
        );
      });
    }

    test('9개 이벤트 이름 문자열이 모두 소스에 실제로 존재한다', () {
      const expectedEventNames = <String>[
        'voice_conversation_entry_direct',
        'voice_conversation_entry_query',
        'voice_conversation_entry_deeplink',
        'voice_conversation_initial_free_used',
        'voice_conversation_daily_free_used',
        'voice_conversation_ad_required',
        'voice_conversation_ad_completed',
        'voice_conversation_session_started',
        'voice_conversation_session_abandoned_before_use',
      ];
      for (final eventName in expectedEventNames) {
        expect(
          source.contains("'$eventName'"),
          isTrue,
          reason: '이벤트명 $eventName 이 소스에서 발견되지 않음',
        );
      }
    });
  });
}
