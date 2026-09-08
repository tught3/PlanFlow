import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/screens/shell_screen.dart';

/// 로딩 게이트 해제는 "소스에 어떤 문자열이 있는가"가 아니라 "실제로 풀리는가"로
/// 검증한다. 기존 shell_screen_onboarding_order_test.dart는 소스 grep이라
/// 게이트가 안 풀리는 회귀를 못 잡는다.
void main() {
  group('presentInteractiveOnboardingScreen', () {
    test('상호작용 화면이 닫히기 전에 게이트를 내린다', () async {
      final presentation = Completer<Object?>();
      var released = false;

      final result = presentInteractiveOnboardingScreen<Object?>(
        () => presentation.future,
        () => released = true,
      );

      // push가 렌더되지 않은 채 Future를 영영 돌려주지 않는 실패 경로를 모사한다.
      // 이 시점(await 이전)에 이미 게이트가 풀려 있어야 한다 — 안 그러면
      // 사용자는 presentation timeout(분 단위) 동안 "로딩 중"만 본다.
      expect(released, isTrue);

      presentation.complete(null);
      await result;
      expect(released, isTrue);
    });

    test('화면 표시가 동기적으로 던져도 게이트를 내린다', () {
      var released = false;

      expect(
        () => presentInteractiveOnboardingScreen<Object?>(
          () => throw StateError('router refused push'),
          () => released = true,
        ),
        throwsStateError,
      );
      expect(released, isTrue);
    });

    test('정상 경로에서는 화면 결과를 그대로 돌려준다', () async {
      var released = false;

      final value = await presentInteractiveOnboardingScreen<bool?>(
        () async => true,
        () => released = true,
      );

      expect(value, isTrue);
      expect(released, isTrue);
    });
  });

  group('runOnboardingStageChain', () {
    test('단계가 hang하면 타임아웃 후 게이트가 풀리고 다음 단계로 넘어간다', () async {
      final hung = Completer<void>();
      var released = false;
      final ran = <String>[];

      final completed = await runOnboardingStageChain(
        stages: [
          OnboardingStage('hang', () {
            ran.add('hang');
            return hung.future;
          }),
          OnboardingStage('next', () async => ran.add('next')),
        ],
        shouldContinue: () => true,
        releaseGate: () => released = true,
        presentationTimeout: const Duration(milliseconds: 50),
        log: (_) {},
      );

      expect(released, isTrue);
      expect(ran, ['hang', 'next']);
      expect(completed, isTrue);
      hung.complete();
    });

    test('단계가 예외를 던져도 게이트가 풀리고 다음 단계로 넘어간다', () async {
      var released = false;
      final ran = <String>[];

      final completed = await runOnboardingStageChain(
        stages: [
          OnboardingStage('boom', () async {
            ran.add('boom');
            throw StateError('stage failed');
          }),
          OnboardingStage('next', () async => ran.add('next')),
        ],
        shouldContinue: () => true,
        releaseGate: () => released = true,
        presentationTimeout: const Duration(seconds: 5),
        log: (_) {},
      );

      expect(released, isTrue);
      expect(ran, ['boom', 'next']);
      expect(completed, isTrue);
    });

    test('shouldContinue가 false여도 게이트는 풀리고 완료 표시는 하지 않는다', () async {
      var released = false;
      final ran = <String>[];

      final completed = await runOnboardingStageChain(
        stages: [
          OnboardingStage('first', () async => ran.add('first')),
          OnboardingStage('second', () async => ran.add('second')),
        ],
        shouldContinue: () => ran.isEmpty,
        releaseGate: () => released = true,
        presentationTimeout: const Duration(seconds: 5),
        log: (_) {},
      );

      expect(released, isTrue);
      expect(ran, ['first']);
      expect(completed, isFalse);
    });

    test('shouldContinue가 던져도 게이트는 풀린다', () async {
      var released = false;

      final completed = await runOnboardingStageChain(
        stages: [
          OnboardingStage('first', () async {}),
        ],
        shouldContinue: () => throw StateError('mounted check exploded'),
        releaseGate: () => released = true,
        presentationTimeout: const Duration(seconds: 5),
        log: (_) {},
      );

      expect(released, isTrue);
      expect(completed, isFalse);
    });

    test('단계는 순차 실행된다(앞 단계가 끝나야 다음 단계 시작)', () async {
      final first = Completer<void>();
      final events = <String>[];

      final chain = runOnboardingStageChain(
        stages: [
          OnboardingStage('first', () {
            events.add('first-start');
            return first.future;
          }),
          OnboardingStage('second', () async {
            events.add('second-start');
          }),
          OnboardingStage('third', () async {
            events.add('third-start');
          }),
        ],
        shouldContinue: () => true,
        releaseGate: () {},
        presentationTimeout: const Duration(seconds: 30),
        log: (_) {},
      );

      await Future<void>.delayed(Duration.zero);
      expect(events, ['first-start']);

      first.complete();
      await chain;
      expect(events, ['first-start', 'second-start', 'third-start']);
    });
  });
}
