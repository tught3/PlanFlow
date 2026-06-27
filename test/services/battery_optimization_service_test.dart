import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/services/app_permission_service.dart';
import 'package:planflow/services/battery_optimization_service.dart';
import 'package:planflow/services/notification_service.dart';

/// [BatteryOptimizationService] 단위 테스트.
///
/// 네이티브 MethodChannel 및 실제 PowerManager 는 기기 의존이므로
/// 직접 단위테스트 불가. 대신:
///  1. 비안드로이드 플랫폼(테스트 환경)에서 isIgnoringBatteryOptimizations()가
///     true를 반환해 흐름을 막지 않는지 확인.
///  2. AppPermissionSnapshot.alarmWillFire 로직(exactAlarm AND batteryIgnored)을
///     순수 Dart 로직으로 검증.
///  3. AppPermissionSnapshot.batteryOptimizationIgnored 기본값 true 확인.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('BatteryOptimizationService — 비안드로이드 플랫폼 fallback', () {
    test(
      'isIgnoringBatteryOptimizations() returns true on non-Android (no channel)',
      () async {
        // 테스트 환경은 Android 아니므로 MethodChannel 없이 바로 true 반환.
        const service = BatteryOptimizationService();
        final result = await service.isIgnoringBatteryOptimizations();
        expect(result, isTrue,
            reason: '비안드로이드 환경에서는 항상 true를 반환해 흐름을 막지 않아야 함');
      },
    );

    test(
      'requestIgnoreBatteryOptimizations() returns false on non-Android (no-op)',
      () async {
        const service = BatteryOptimizationService();
        final result = await service.requestIgnoreBatteryOptimizations();
        expect(result, isFalse,
            reason: '비안드로이드에서는 인텐트를 열 수 없으므로 false 반환');
      },
    );
  });

  group('AppPermissionSnapshot.alarmWillFire 로직', () {
    NotificationPermissionStatus _makeStatus({
      bool notifications = true,
      bool exactAlarms = true,
    }) {
      return NotificationPermissionStatus(
        notificationsEnabled: notifications,
        exactAlarmsEnabled: exactAlarms,
        fullScreenIntentStatus: PermissionCheckState.unsupported,
      );
    }

    test('exactAlarm=true AND batteryIgnored=true → alarmWillFire=true', () {
      final snapshot = AppPermissionSnapshot(
        microphoneGranted: true,
        locationGranted: true,
        calendarGranted: true,
        notificationStatus: _makeStatus(exactAlarms: true),
        batteryOptimizationIgnored: true,
      );
      expect(snapshot.alarmWillFire, isTrue);
    });

    test('exactAlarm=false AND batteryIgnored=true → alarmWillFire=false', () {
      final snapshot = AppPermissionSnapshot(
        microphoneGranted: true,
        locationGranted: true,
        calendarGranted: true,
        notificationStatus: _makeStatus(exactAlarms: false),
        batteryOptimizationIgnored: true,
      );
      expect(snapshot.alarmWillFire, isFalse,
          reason: '정확한 알람 권한이 없으면 alarmWillFire=false');
    });

    test('exactAlarm=true AND batteryIgnored=false → alarmWillFire=false', () {
      final snapshot = AppPermissionSnapshot(
        microphoneGranted: true,
        locationGranted: true,
        calendarGranted: true,
        notificationStatus: _makeStatus(exactAlarms: true),
        batteryOptimizationIgnored: false,
      );
      expect(snapshot.alarmWillFire, isFalse,
          reason: '배터리 최적화 예외 없으면 alarmWillFire=false');
    });

    test('exactAlarm=false AND batteryIgnored=false → alarmWillFire=false', () {
      final snapshot = AppPermissionSnapshot(
        microphoneGranted: true,
        locationGranted: true,
        calendarGranted: true,
        notificationStatus: _makeStatus(exactAlarms: false),
        batteryOptimizationIgnored: false,
      );
      expect(snapshot.alarmWillFire, isFalse);
    });

    test(
      'batteryOptimizationIgnored 기본값은 true — 명시 없이 생성해도 흐름 차단 없음',
      () {
        final snapshot = AppPermissionSnapshot(
          microphoneGranted: true,
          locationGranted: true,
          calendarGranted: true,
          notificationStatus: _makeStatus(exactAlarms: true),
          // batteryOptimizationIgnored 생략 → 기본값 true
        );
        expect(snapshot.batteryOptimizationIgnored, isTrue,
            reason: '기존 코드와의 하위 호환: 명시 없으면 true로 동작');
        expect(snapshot.alarmWillFire, isTrue);
      },
    );
  });
}
