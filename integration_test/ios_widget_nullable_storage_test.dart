// PlanFlow iOS native probe — HomeWidget nullable-storage regression.
//
// 배경 (App Review build195 (1.1.7)): 첫 설치 온보딩에서 네이티브 SIGABRT가 발생했고
// dSYM 심볼은 HomeWidgetPlugin의 `UserDefaults.setValue(...)`로 귀결됐다.
// Dart 측 `null`이 메서드 채널을 건너 NSNull로 직렬화되어 property-list
// 저장이 불가능했던 것이 원인. 프로덕션 어댑터
// `lib/services/home_widget_platform_io.dart`는 이제 iOS에서 null 클리어를
// ''로 (단 `next_event_travel_buffer_minutes`는 0으로) 강제 변환하고,
// Android는 기존대로 null을 유지한다.
//
// 이 파일이 '실제 iOS 시뮬레이터에서만' 증명하는 것:
//   1. 프로덕션 팩토리 `createHomeWidgetPlatformImpl()`가 실제 home_widget
//      SDK의 앱그룹 컨테이너를 초기화하고,
//   2. null 클리어 쓰기가 네이티브 UserDefaults에 '' / 0으로 저장되어
//      타입이 지정된 `HomeWidget.getWidgetData` 읽기로 왕복 검증되며,
//   3. 그 이후에도 러너가 살아 있다(모든 네이티브 호출 뒤에 PASS 마커를
//      출력) — 즉 이 정확한 브리지 경로에서 NSNull SIGABRT가 없다.
//
// 이 파일이 의도적으로 하지 '않는' 것:
//   - 프로덕션 App 기동/인증/Supabase/OAuth/HTTP 트래픽 없음. 최소
//     MaterialApp 스캐폴드만 pump 한다.
//   - mock 메서드 채널 핸들러, fake 플랫폼, fake preference 백엔드 없음.
//     아래의 모든 저장/읽기는 실제 네이티브 플러그인을 통과한다.
//     (기존 flow07_widget_appgroup_test.dart는 _CapturingHomeWidgetPlatform
//     인메모리 fake를 쓰므로 이 네이티브 크래시 경로를 증명할 수 없다.)
//   - 전체 온보딩 UI E2E를 주장하지 않는다. 크래시가 난 것과 동일한
//     네이티브 브리지만 검증한다.
//
// Fail-closed 게이트: `dart:io.Platform.isIOS` (디버그 오버라이드 없음).
// iOS가 아닌 호스트에서는 IOS_NATIVE_WIDGET_NULL_PROBE_SKIPPED 마커를
// 출력하고 skipped로 보고된다 — 네이티브 통과로 절대 초록색이 되지 않는다.
//
// CI: `.github/workflows/ios-widget-null-probe.yml`이 자체 소유 폰/태블릿
// 시뮬레이터에서 `scripts/ios/e2e_xctest_flow.sh`로 이 파일을 실행하고,
// XCTest 로그에 IOS_NATIVE_WIDGET_NULL_PROBE_PASS 마커와 실행된 테스트
// 증거가 모두 없으면 fail-closed로 실패한다.
//
// The storage probe has no accessibility assertions. Mute only the binding's
// automatic semantics callback for this probe, then restore the original after
// per-test framework verification so semantics-handle leak checks stay active.
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:home_widget/home_widget.dart';
import 'package:integration_test/integration_test.dart';

import 'package:planflow/services/home_widget_platform_io.dart';

/// `ios/Flutter/PlanFlow-Identity.xcconfig`의 `PLANFLOW_IOS_APP_GROUP`과 동기
/// 되어야 한다 (Runner/PlanFlowWidget 엔타이틀먼트가 이 값을 참조). 동기는 정
/// 적 컨트랙트 `scripts/ios/tests/ios_widget_null_probe_contract.sh`가 강제한다.
const String _probeAppGroup = 'group.com.fluxstudio.planflow';

/// 고유 성공 마커. 실제 네이티브 setAppGroupId, null 클리어 쓰기, 타입
/// 지정 읽기가 전부 성공한 '뒤에만' 출력된다. 프로브 워크플로는 이 문자열
/// 그대로를 grep한다. 네이티브 SIGABRT는 이 줄이 출력되기 전에 프로세스를
/// 종료시키므로, 마커 부재 = 네이티브 실패로 판정된다.
const String _probePassMarker = 'IOS_NATIVE_WIDGET_NULL_PROBE_PASS';

/// 플랫폼 게이트가 호스트를 거부했을 때 출력되는 안티-그린 마커.
/// 워크플로는 이 마커가 로그에 있으면 초록을 허용하지 않는다.
const String _probeSkipMarker = 'IOS_NATIVE_WIDGET_NULL_PROBE_SKIPPED';

/// 프로덕션이 실제로 쓰는 nullable 키들 (lib/services/home_widget_service.dart 참조):
///   - next_event_id                  심사 build195 (1.1.7) 첫 크래시 온보딩이
///                                    실제로 클리어한 nullable 이벤트 ID -> '' 클리어 (정확 키)
///   - next_event_start_at            nullable ISO-8601 날짜 문자열 -> '' 클리어
///   - gw_testname                    그룹 위젯 `gw_<id>_name` 네임스페이스 -> '' 클리어
///   - next_event_travel_buffer_minutes nullable 정수 버퍼 -> 0 클리어 (어댑터가
///                                    정확히 이 키만 특수 케이스로 0을 쓴다)
const String _eventIdKey = 'next_event_id';
const String _dateKey = 'next_event_start_at';
const String _groupKey = 'gw_testname';
const String _bufferKey = 'next_event_travel_buffer_minutes';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final originalSemanticsCallback =
      WidgetsBinding.instance.platformDispatcher.onSemanticsEnabledChanged;
  // Storage-only probe, not accessibility coverage. This isolate-scoped mute
  // does not affect app behavior; framework binding/leak verification remains
  // enabled. Restore only after per-test verification via tearDownAll.
  WidgetsBinding.instance.platformDispatcher.onSemanticsEnabledChanged = () {};
  tearDownAll(() {
    WidgetsBinding.instance.platformDispatcher.onSemanticsEnabledChanged =
        originalSemanticsCallback;
  });
  testWidgets(
    'native iOS UserDefaults stores null clears as empty/zero without NSNull SIGABRT',
    (WidgetTester tester) async {
      if (!Platform.isIOS) {
        // ignore: avoid_print
        print(
          '$_probeSkipMarker: dart:io.Platform.isIOS=false '
          '(host=${Platform.operatingSystem}); the native UserDefaults probe '
          'requires a real iOS simulator run and is reported as skipped, '
          'never as native green.',
        );
        markTestSkipped(
          'IOS_NATIVE_WIDGET_NULL_PROBE_SKIPPED: native UserDefaults probe '
          'requires dart:io.Platform.isIOS (got ${Platform.operatingSystem}); '
          'a Windows/default-host run cannot validate the iOS bridge.',
        );
        return;
      }

      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Center(child: Text('ios_widget_nullable_storage_probe')),
          ),
        ),
      );

      // 프로덕션 실IO 어댑터(패치된 코드 경로)를 공개 팩토리로 생성.
      final platform = createHomeWidgetPlatformImpl();

      expect(
        platform.isSupported,
        isTrue,
        reason: 'production HomeWidgetPlatform IO adapter must report '
            'supported on real iOS',
      );

      final bool groupReady = await platform.setAppGroupId(_probeAppGroup);
      expect(
        groupReady,
        isTrue,
        reason: 'HomeWidget.setAppGroupId must succeed for $_probeAppGroup '
            'on the real iOS runtime (empty/invalid group ids are rejected '
            'by the native plugin)',
      );

      // 클리어 전에 실제 값을 시드한다. 그래야 아래 null-클리어 검증이
      // "키가 없어서 null로 읽히는" 상태를 우연히 통과하지 못한다.
      expect(
        await HomeWidget.saveWidgetData<String>(_eventIdKey, 'probe-event-001'),
        isTrue,
        reason: 'seeding $_eventIdKey through the real SDK must succeed',
      );
      expect(
        await HomeWidget.saveWidgetData<String>(_dateKey, '2031-03-04T05:06:07Z'),
        isTrue,
        reason: 'seeding $_dateKey through the real SDK must succeed',
      );
      expect(
        await HomeWidget.saveWidgetData<String>(_groupKey, 'probe-group'),
        isTrue,
        reason: 'seeding $_groupKey through the real SDK must succeed',
      );
      expect(
        await HomeWidget.saveWidgetData<int>(_bufferKey, 35),
        isTrue,
        reason: 'seeding $_bufferKey through the real SDK must succeed',
      );

      // 시드 왕복 sanity: 스토리지가 실제로 읽힌다.
      expect(
        await HomeWidget.getWidgetData<String>(_eventIdKey),
        'probe-event-001',
        reason: 'seeded $_eventIdKey must read back through the native '
            'UserDefaults container before clearing',
      );
      expect(
        await HomeWidget.getWidgetData<String>(_dateKey),
        '2031-03-04T05:06:07Z',
        reason: 'seeded $_dateKey must read back through the native '
            'UserDefaults container before clearing',
      );
      expect(
        await HomeWidget.getWidgetData<num>(_bufferKey),
        35,
        reason: 'seeded $_bufferKey must read back through the native '
            'UserDefaults container before clearing',
      );

      // 패치된 프로덕션 어댑터 경로로 null 클리어 (원래 크래시가 난 호출 형태).
      expect(
        await platform.saveWidgetData(_eventIdKey, null),
        isTrue,
        reason: 'null clear for $_eventIdKey must be accepted by the adapter',
      );
      expect(
        await platform.saveWidgetData(_dateKey, null),
        isTrue,
        reason: 'null clear for $_dateKey must be accepted by the adapter',
      );
      expect(
        await platform.saveWidgetData(_groupKey, null),
        isTrue,
        reason: 'null clear for $_groupKey must be accepted by the adapter',
      );
      expect(
        await platform.saveWidgetData(_bufferKey, null),
        isTrue,
        reason: 'null clear for $_bufferKey must be accepted by the adapter',
      );

      // 타입 지정 네이티브 읽기: NSNull이 아니라 '' / 0이 저장됐다.
      // (과거 null 전달은 이 시점 이전에 setValue(NSNull)로 SIGABRT를 냈다.)
      expect(
        await HomeWidget.getWidgetData<String>(_eventIdKey),
        '',
        reason: '$_eventIdKey null clear must persist empty string in native '
            'UserDefaults, not NSNull and not key removal',
      );
      expect(
        await HomeWidget.getWidgetData<String>(_dateKey),
        '',
        reason: '$_dateKey null clear must persist empty string in native '
            'UserDefaults, not NSNull and not key removal',
      );
      expect(
        await HomeWidget.getWidgetData<String>(_groupKey),
        '',
        reason: '$_groupKey null clear must persist empty string in native '
            'UserDefaults, not NSNull and not key removal',
      );
      final num? bufferAfterClear = await HomeWidget.getWidgetData<num>(_bufferKey);
      expect(
        bufferAfterClear,
        isA<num>(),
        reason: '$_bufferKey must still hold a number after the null clear '
            '(exact production special case stores 0, not removal)',
      );
      expect(
        bufferAfterClear,
        0,
        reason: '$_bufferKey null clear must persist 0 in native UserDefaults '
            '(exact production special case)',
      );

      // 러너 생존 증명: 네이티브 SIGABRT였다면 이 줄들에 도달할 수 없다.
      await tester.pump();
      // ignore: avoid_print
      print(
        '$_probePassMarker group=$_probeAppGroup '
        'os=${Platform.operatingSystemVersion} event_id_clear=empty '
        'date_clear=empty gw_clear=empty buffer=0',
      );
    },
    // Storage-only native probe: no semantics assertions here, so the
    // framework's automatic AX SemanticsHandle is unnecessary and would
    // otherwise trip the end-of-test _verifySemanticsHandlesWereDisposed check.
    semanticsEnabled: false,
  );
}
