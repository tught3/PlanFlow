import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// iOS 강한알람(커스텀 사운드 + 확인(출발) 액션) 계약 테스트.
///
/// Android와 달리 iOS는 커스텀 사운드를 Runner 타겟 리소스로 번들링해야 하고,
/// 액션 버튼은 UNNotificationCategory로 등록해야 한다. entitlement 없이는
/// critical interruption level을 쓸 수 없으므로 timeSensitive를 요청한다.
void main() {
  final root = Directory.current;
  File file(String path) => File('${root.path}${Platform.pathSeparator}$path');

  test('critical alarm wav is bundled into the Runner target', () {
    final wav = file('ios/Runner/planflow_critical_alarm.wav');
    expect(wav.existsSync(), isTrue,
        reason: 'Runner target must ship the alarm sound for iOS');
    expect(wav.lengthSync(), greaterThan(0));

    final project =
        file('ios/Runner.xcodeproj/project.pbxproj').readAsStringSync();
    expect(project, contains('planflow_critical_alarm.wav in Resources'));
    expect(
      project,
      contains(
        'lastKnownFileType = audio.wav; path = planflow_critical_alarm.wav',
      ),
    );
    // Runner target의 Resources 빌드 페이즈에 포함되어야 번들에 들어간다.
    final resourcesPhase = project.indexOf(
      '97C146EC1CF9000F007C117D /* Resources */ = {',
    );
    expect(resourcesPhase, greaterThanOrEqualTo(0));
    final phaseBlock = project.substring(
      resourcesPhase,
      project.indexOf('};', resourcesPhase),
    );
    expect(phaseBlock, contains('planflow_critical_alarm.wav in Resources'));
  });

  test('strong alarm Darwin details request custom sound + timeSensitive', () {
    final service =
        file('lib/services/notification_service.dart').readAsStringSync();
    expect(service, contains("criticalAlarmIosSoundName = 'planflow_"
        'critical_alarm.wav\''));
    // 커스텀 사운드 없는 iOS 알림은 짧은 기본음만 울린다 → 사운드 지정 필수.
    expect(
      service,
      contains('sound: criticalAlarmIosSoundName'),
      reason: 'DarwinNotificationDetails must reference the bundled wav',
    );
    expect(
      service,
      contains('interruptionLevel: InterruptionLevel.timeSensitive'),
      reason:
          'Without the critical-alerts entitlement, timeSensitive is the '
          'highest reachable interruption level',
    );
  });

  test('strong alarm notification carries 확인(출발) action via category', () {
    final service =
        file('lib/services/notification_service.dart').readAsStringSync();
    expect(service, contains('categoryIdentifier: criticalAlarmCategoryId'));
    expect(
        service, contains('static const String criticalAlarmCategoryId'));
    expect(
      service,
      contains('DarwinNotificationCategory('),
      reason: 'iOS needs a UNNotificationCategory to show action buttons',
    );
    // Android와 동일한 action identifier를 재사용해 기존 ack 취소 로직을 태운다.
    expect(service, contains('DarwinNotificationAction.plain('));
    final categoryBlock = service.indexOf(
        'static final DarwinNotificationCategory '
        'criticalAlarmDarwinCategory');
    expect(categoryBlock, greaterThan(0));
    final block = service.substring(
      categoryBlock,
      service.indexOf('];', categoryBlock),
    );
    expect(block, contains('criticalAcknowledgedActionId'));
    expect(block, contains("'확인(출발)'"));
    // 카테고리는 앱 실행 시 1회 등록된다 → 초기화 설정에 포함되어야 한다.
    expect(
      service,
      contains('notificationCategories: <DarwinNotificationCategory>['),
    );
  });

  test('ack action identifier is shared between Android actions and Darwin',
      () {
    final service =
        file('lib/services/notification_service.dart').readAsStringSync();
    final ackDecl =
        service.indexOf("static const String criticalAcknowledgedActionId");
    expect(ackDecl, greaterThan(0));
    // 핸들러(handleNotificationResponseAction)는 identifier만 보고 판별하므로
    // iOS 액션 탭도 동일한 취소 경로를 탄다.
    expect(
      service,
      contains(
          'actionId == NotificationService.criticalAcknowledgedActionId'),
    );
  });
}
