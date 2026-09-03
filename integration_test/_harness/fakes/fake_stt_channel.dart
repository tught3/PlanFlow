import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/services/stt_service.dart';

/// `SttService`의 네이티브 STT MethodChannel(`planflow/native_stt`)을
/// 가로채는 E2E fake.
///
/// **실측 확인(중요 — iOS E2E 범위 한계)**: `lib/services/stt_service.dart:905`
/// (`listen()`)를 보면 `planflow/native_stt` 채널은
/// `defaultTargetPlatform == TargetPlatform.android`일 때만 사용된다.
/// iOS는 `speech_to_text` 패키지의 `SpeechToText` 인스턴스(`_activeSpeech`,
/// 실제 실행 시 iOS 네이티브 프레임워크와 통신)를 직접 쓰며, `SttService`에는
/// 이 엔진을 교체할 수 있는 생성자 파라미터나 delegate가 전혀 없다
/// (`const SttService()` — 필드 없는 상수 생성자, 순수 static 상태).
/// 그래서 이 채널을 목킹해도 **실제 iOS 음성 인식 흐름 자체는 커버되지
/// 않는다** — 이건 이번 P3 범위 밖의 seam 부족이며, 완료 보고에 별도
/// 기재한다.
///
/// 이 fake가 실제로 유효한 것은 `SttService.debugSeedNativeListenState`/
/// `debugResetActiveListenState`(`@visibleForTesting static`,
/// `lib/services/stt_service.dart:151,161`)로 플랫폼 무관하게 "네이티브
/// 리슨이 진행 중"인 상태를 인위적으로 만든 뒤 `cancelActiveListen()`/
/// `stopActiveListen()`의 정리(cleanup) 로직을 검증하는 경로다
/// (`test/services/stt_service_test.dart:100-146`의 실제 사용 패턴을
/// 그대로 재사용).
class FakeSttNativeChannel {
  FakeSttNativeChannel();

  static const MethodChannel channel = MethodChannel('planflow/native_stt');

  final List<MethodCall> calls = <MethodCall>[];

  /// 채널 호출 시 반환할 값. 메서드 이름별로 지정한다(예: `{'start': true}`).
  final Map<String, Object?> responses = <String, Object?>{};

  /// [TestDefaultBinaryMessengerBinding]에 mock 핸들러를 설치한다.
  /// `addTearDown(fake.uninstall)`로 반드시 해제해야 한다(설치된 채로
  /// 남으면 이후 테스트에 영향을 준다).
  void install() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return responses[call.method];
    });
  }

  void uninstall() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  }

  /// 편의 래퍼: [SttService.debugSeedNativeListenState]로 네이티브 리슨이
  /// 진행 중인 상태를 만든다.
  void seedActiveListen({String recognizedText = ''}) {
    SttService.debugSeedNativeListenState(recognizedText: recognizedText);
  }

  /// 편의 래퍼: [SttService.debugResetActiveListenState]로 리슨 상태를
  /// 초기화한다.
  void resetActiveListen() {
    SttService.debugResetActiveListenState();
  }
}
