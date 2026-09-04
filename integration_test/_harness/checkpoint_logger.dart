// PlanFlow iOS Simulator E2E hang investigation — Phase P5 계측 유틸.
//
// ## 조사 결과 요약 (근거 없이 print()/stdout 중 하나를 고르지 않기 위해
// Flutter/Dart SDK 소스를 직접 확인했다 — 아래는 그 실측 결과)
//
// ### 1) `flutter test -d <UDID>`(온-디바이스 통합 테스트)는 앱 프로세스의
//    stdout을 CI 로그로 전혀 forwarding하지 않는다 (버퍼링 문제가 아니라
//    채널 자체가 없다)
//
// `.github/workflows/ios-simulator-e2e.yml`의 실행 스텝은
// `flutter test ... 2>&1 | tee "$artifact_dir/flow-test-output.log"`로
// **`flutter test` CLI 프로세스 자신의 stdout/stderr**만 캡처한다. 이
// CLI가 시뮬레이터에서 실행 중인 앱 프로세스의 로그를 어떻게 회수하는지
// Flutter SDK 소스(`packages/flutter_tools/lib/src/test/
// integration_test_device.dart`)를 확인한 결과:
//
// - `IntegrationTestTestDevice.start()`는 VM Service의
//   `Flutter.IntegrationTest` extension 이벤트 스트림만 구독해
//   `package:integration_test`의 **테스트 결과 프로토콜(JSON pass/fail
//   메시지)**을 `package:test` 하네스로 중계한다. 소스 주석이 명시:
//   "No need to set up the log reader because the logs are captured and
//   streamed to the package:test_core runner." — 이 "logs"는 결과
//   프로토콜을 가리키는 것이지, 앱 코드의 임의 `print()`/`stdout` 출력이
//   아니다.
// - `flutter_tools/lib/src/test/` 디렉터리 전체와 `commands/test.dart`를
//   `getLogReader`/`DeviceLogReader`로 grep한 결과 **0건** — 이 실행
//   경로(`flutter test -d`)는 애초에 디바이스 로그 리더를 붙이지 않는다
//   (`flutter run`/`flutter attach`가 붙이는 것과 다른 코드 경로).
//
// 결론: 이 하네스가 `print()`를 쓰든 `stdout.writeln()`을 쓰든, 시뮬레이터
// 위에서 실행 중인 앱 프로세스 안에서 호출되는 한 **현재 CI 워크플로우로는
// 그 출력이 `flow-test-output.log`에 전혀 나타나지 않는다.** 이건 이번
// 파일이 고칠 수 있는 범위(하네스 유틸 1개 함수)를 넘어서는 CI 파이프라인
// 배선 문제이며(예: `xcrun simctl spawn <udid> log stream` 사이드카,
// 또는 flutter_tools 자체의 디바이스 로그 리더 연결), 별도 후속 작업으로
// 분리한다. 이 파일은 그 전제 위에서 "채널이 생기면 즉시 쓸모 있는 형태"로
// 정확하게 만드는 것을 목표로 한다.
//
// ### 2) `print()`와 `stdout.writeln()`의 flush/버퍼링 차이는 없다 —
//    둘 다 기본적으로 blocking `Stdout` sink를 거친다
//
// Dart SDK 소스(`bin/cache/dart-sdk/lib/core/print.dart`) 문서 주석:
// "native(non-Web) 플랫폼에서 `object`는 문자열로 변환되고 개행이 붙어
// `stdout`에 쓰여진다" — 즉 `print()`도 결국 `stdout`에 쓴다. 그리고
// `bin/cache/dart-sdk/lib/io/stdio.dart`의 `Stdout` 클래스 문서 주석은
// 명시적으로 "Provides a *blocking* `IOSink`, so using it to write will
// block until the output is written." — 기본 `stdout`은 **블로킹**이라
// 쓰기 호출이 완료될 때 이미 출력이 나간 상태다(별도로 `.nonBlocking`
// getter를 통해서만 비동기 sink를 얻을 수 있고, `print()`/`stdout.writeln()`
// 둘 다 이 non-blocking 변형을 쓰지 않는다). 따라서 행(hang) 조사에서
// 중요한 속성인 "행이 나기 직전까지의 체크포인트가 프로세스가 나중에
// 강제 종료되더라도 이미 출력돼 있는가"는 두 방식이 동일하다 — 버퍼링
// 손실 위험 차이는 없다.
//
// 유일한 실질적 차이는 `print()`가 `Zone.current.print`(`printToZone`)를
// 거친다는 것뿐이다(`bin/cache/dart-sdk/lib/internal/print.dart`).
// `flutter_test`의 `binding.dart`를 확인한 결과 이 하네스가 도는 동안
// `Zone.print`를 가로채는 코드는 없었으므로(에러 핸들링용
// `ZoneSpecification`만 있고 print 관련 특별 처리 없음), 이 인터셉션은
// 지금 당장은 아무 차이도 만들지 않는다. 다만 `print()`를 쓰면 향후
// 로컬 개발자가 `flutter test -d <UDID> -v`로 직접 붙어 보거나, 테스트
// 프레임워크가 향후 버전에서 per-test print 캡처/리포팅을 추가하더라도
// 자동으로 그 혜택을 받는다(반면 `stdout.writeln()`은 Zone을 완전히
// 우회해 항상 raw OS stdout으로만 간다). 이 이점이 있고 단점(버퍼링
// 손실 위험)은 없으므로 `print()`를 채택한다.
//
// (조사 시점 로컬 SDK: Flutter 3.41.9. 3-positional `pumpAndSettle`
// 시그니처와 마찬가지로, 위 `print()`/`Stdout` 소스는 `git show
// 3.47.2:...`로 CI가 실제 쓰는 3.47.2 태그에서도 동일 내용임을 직접
// 대조 확인했다 — Dart core/io SDK 소스 파일 자체가 Flutter 엔진
// 버전과 함께 번들되는 `bin/cache/dart-sdk`이므로, 이 부분은 3.47.2
// 태그의 프레임워크 저장소에는 존재하지 않고 별도의 Dart SDK 릴리스에
// 묶여 있어 프레임워크 태그로는 직접 대조할 수 없었다 — 다만 `print()`가
// "native 플랫폼에서 stdout에 쓴다"는 계약과 `Stdout`이 기본
// blocking이라는 계약은 Dart 언어/`dart:io` API의 안정된 공개 계약이라
// 상세 구현이 바뀌어도 이 결론이 뒤집힐 가능성은 낮다고 판단한다.)
//
// ## 사용 규칙
//
// `marker`는 반드시 **고정 열거형 문자열 리터럴**만 넘긴다. 변수 보간
// (`'$something'`)이나 사용자 입력, secret(토큰/URL/이메일 등)을 절대
// 넣지 않는다 — 이 로거는 "어느 체크포인트에 도달했는가"만 기록하는
// 용도이지, 값을 실어 나르는 용도가 아니다. 새 체크포인트가 필요하면
// 호출부에 새 리터럴 문자열을 그대로 적어라(예: `'flow02.beforeSave'`).
void logCheckpoint(String marker) {
  // `avoid_print`는 `lib/` 프로덕션 코드를 겨냥한 린트다. 이 파일은
  // E2E 테스트 전용 계측 유틸이고, 위 조사 결과에 따라 `print()`를
  // 의도적으로 선택했다(주석 상단 "### 2)" 참고) — `debugPrint`나
  // 별도 로깅 프레임워크로 바꾸는 것이 이 파일의 목적에 부합하지 않는다.
  // ignore: avoid_print
  print('[CHECKPOINT] $marker');
}
