import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'battery_optimization_service.dart';
import 'notification_service.dart';

class AppPermissionService {
  AppPermissionService({
    NotificationService? notificationService,
    SharedPreferencesAsync? preferences,
    BatteryOptimizationService? batteryOptimizationService,
  })  : _notificationService = notificationService ?? NotificationService(),
        _preferences = preferences,
        _batteryOptimizationService =
            batteryOptimizationService ?? const BatteryOptimizationService();

  static const MethodChannel _androidPermissionsChannel =
      MethodChannel('planflow/android_permissions');
  static const MethodChannel _iosPermissionsChannel =
      MethodChannel('planflow/ios_permissions');
  static const String _onboardingPrefix = 'planflow_permissions_onboarded_v1';

  final NotificationService _notificationService;
  final SharedPreferencesAsync? _preferences;
  final BatteryOptimizationService _batteryOptimizationService;
  Future<AppPermissionSnapshot>? _checkAllInFlight;

  SharedPreferencesAsync get _resolvedPreferences =>
      _preferences ?? SharedPreferencesAsync();

  Future<bool> isOnboardingCompleted(String userId) async {
    return await _resolvedPreferences.getBool(_onboardingKey(userId)) ?? false;
  }

  Future<void> markOnboardingCompleted(String userId) {
    return _resolvedPreferences.setBool(_onboardingKey(userId), true);
  }

  Future<AppPermissionSnapshot> checkAll() async {
    final existing = _checkAllInFlight;
    if (existing != null) return existing;
    final future = _checkAllInternal();
    _checkAllInFlight = future;
    try {
      return await future;
    } finally {
      if (identical(_checkAllInFlight, future)) _checkAllInFlight = null;
    }
  }

  Future<AppPermissionSnapshot> _checkAllInternal() async {
    final notificationFuture = _notificationService.checkPermissionStatus();
    final microphoneStatusFuture = defaultTargetPlatform == TargetPlatform.iOS
        ? checkMicrophonePermissionStatus()
        : checkMicrophonePermission().then(
            (granted) => granted
                ? AppPermissionStatus.granted
                : AppPermissionStatus.denied,
          );
    final speechStatusFuture = defaultTargetPlatform == TargetPlatform.iOS
        ? checkSpeechRecognitionPermissionStatus()
        : Future<AppPermissionStatus>.value(AppPermissionStatus.granted);
    final locationStatusFuture = defaultTargetPlatform == TargetPlatform.iOS
        ? checkLocationPermissionStatus()
        : checkLocationPermission().then(
            (granted) => granted
                ? AppPermissionStatus.granted
                : AppPermissionStatus.denied,
          );
    final calendarStatusFuture = defaultTargetPlatform == TargetPlatform.iOS
        ? checkCalendarPermissionStatus()
        : checkCalendarPermission().then(
            (granted) => granted
                ? AppPermissionStatus.granted
                : AppPermissionStatus.denied,
          );
    final batteryFuture =
        _batteryOptimizationService.isIgnoringBatteryOptimizations();
    final notificationStatus = await notificationFuture;
    final microphoneStatus = await microphoneStatusFuture;
    final speechStatus = await speechStatusFuture;
    final locationStatus = await locationStatusFuture;
    final calendarStatus = await calendarStatusFuture;
    return AppPermissionSnapshot(
      microphoneGranted: microphoneStatus == AppPermissionStatus.granted,
      microphoneStatus: microphoneStatus,
      speechRecognitionGranted: speechStatus == AppPermissionStatus.granted,
      speechRecognitionStatus: speechStatus,
      locationGranted: locationStatus == AppPermissionStatus.granted,
      locationStatus: locationStatus,
      calendarGranted: calendarStatus == AppPermissionStatus.granted,
      calendarStatus: calendarStatus,
      notificationStatus: notificationStatus,
      batteryOptimizationIgnored: await batteryFuture,
    );
  }

  /// 배터리 최적화 예외 적용 여부 확인.
  Future<bool> isBatteryOptimizationIgnored() {
    return _batteryOptimizationService.isIgnoringBatteryOptimizations();
  }

  /// 배터리 최적화 예외 요청 화면을 연다.
  Future<bool> requestIgnoreBatteryOptimizations() {
    return _batteryOptimizationService.requestIgnoreBatteryOptimizations();
  }

  Future<bool> requestMicrophonePermission() async {
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      return await requestMicrophonePermissionStatus() ==
          AppPermissionStatus.granted;
    }
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return true;
    }
    try {
      return await _androidPermissionsChannel.invokeMethod<bool>(
            'requestMicrophonePermission',
          ) ??
          false;
    } catch (error, stackTrace) {
      debugPrint('Microphone permission request failed: $error');
      debugPrintStack(stackTrace: stackTrace);
      return false;
    }
  }

  Future<bool> checkMicrophonePermission() async {
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      return await checkMicrophonePermissionStatus() ==
          AppPermissionStatus.granted;
    }
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return true;
    }
    try {
      return await _androidPermissionsChannel.invokeMethod<bool>(
            'checkMicrophonePermission',
          ) ??
          false;
    } catch (error, stackTrace) {
      debugPrint('Microphone permission check failed: $error');
      debugPrintStack(stackTrace: stackTrace);
      return false;
    }
  }

  Future<bool> requestLocationPermission() async {
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      return await requestLocationPermissionStatus() ==
          AppPermissionStatus.granted;
    }
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return true;
    }
    try {
      return await _androidPermissionsChannel.invokeMethod<bool>(
            'requestLocationPermission',
          ) ??
          false;
    } catch (error, stackTrace) {
      debugPrint('Location permission request failed: $error');
      debugPrintStack(stackTrace: stackTrace);
      return false;
    }
  }

  Future<bool> checkLocationPermission() async {
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      return await checkLocationPermissionStatus() ==
          AppPermissionStatus.granted;
    }
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return false;
    }
    try {
      return await _androidPermissionsChannel.invokeMethod<bool>(
            'checkLocationPermission',
          ) ??
          false;
    } catch (error, stackTrace) {
      debugPrint('Location permission check failed: $error');
      debugPrintStack(stackTrace: stackTrace);
      return false;
    }
  }

  Future<bool> requestCalendarPermission() async {
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      return await requestCalendarPermissionStatus() ==
          AppPermissionStatus.granted;
    }
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return true;
    }
    try {
      return await _androidPermissionsChannel.invokeMethod<bool>(
            'requestCalendarPermission',
          ) ??
          false;
    } catch (error, stackTrace) {
      debugPrint('Calendar permission request failed: $error');
      debugPrintStack(stackTrace: stackTrace);
      return false;
    }
  }

  Future<bool> checkCalendarPermission() async {
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      return await checkCalendarPermissionStatus() ==
          AppPermissionStatus.granted;
    }
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return false;
    }
    try {
      return await _androidPermissionsChannel.invokeMethod<bool>(
            'checkCalendarPermission',
          ) ??
          false;
    } catch (error, stackTrace) {
      debugPrint('Calendar permission check failed: $error');
      debugPrintStack(stackTrace: stackTrace);
      return false;
    }
  }

  Future<GeoPoint?> getLastKnownLocation() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return null;
    }
    try {
      final result = await _androidPermissionsChannel.invokeMethod<Object?>(
        'getLastKnownLocation',
      );
      if (result is! Map) {
        return null;
      }
      final latitude = _doubleValue(result['latitude']);
      final longitude = _doubleValue(result['longitude']);
      if (latitude == null || longitude == null) {
        return null;
      }
      return GeoPoint(latitude: latitude, longitude: longitude);
    } catch (error, stackTrace) {
      debugPrint('Last known location read failed: $error');
      debugPrintStack(stackTrace: stackTrace);
      return null;
    }
  }

  Future<GeoPoint?> getCurrentLocation() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return null;
    }
    try {
      final result = await _androidPermissionsChannel
          .invokeMethod<Object?>('getCurrentLocation')
          .timeout(const Duration(seconds: 12));
      if (result is! Map) {
        return await getLastKnownLocation();
      }
      final latitude = _doubleValue(result['latitude']);
      final longitude = _doubleValue(result['longitude']);
      if (latitude == null || longitude == null) {
        return await getLastKnownLocation();
      }
      return GeoPoint(latitude: latitude, longitude: longitude);
    } catch (error, stackTrace) {
      debugPrint('Current location read failed: $error');
      debugPrintStack(stackTrace: stackTrace);
      return await getLastKnownLocation();
    }
  }

  Future<GeoPoint?> getCurrentLocationWithPermission({
    bool requestIfMissing = true,
  }) async {
    try {
      var granted = await checkLocationPermission();
      if (!granted && requestIfMissing) {
        granted = await requestLocationPermission();
      }
      if (!granted) {
        return null;
      }
      return await getCurrentLocation() ?? await getLastKnownLocation();
    } catch (error, stackTrace) {
      debugPrint('Current location with permission failed: $error');
      debugPrintStack(stackTrace: stackTrace);
      return null;
    }
  }

  Future<NotificationPermissionStatus> requestNotificationPermissions() {
    return _notificationService.requestAndCheckPermissions();
  }

  Future<bool> requestNotificationPermission() {
    return _notificationService.requestNotificationPermission();
  }

  Future<bool> requestExactAlarmPermission() {
    return _notificationService.requestExactAlarmPermission();
  }

  Future<bool> requestFullScreenIntentPermission() async {
    final granted =
        await _notificationService.requestFullScreenIntentPermission();
    if (granted == true) {
      return true;
    }
    final status = await _notificationService.checkPermissionStatus();
    return status.fullScreenIntentStatus == PermissionCheckState.granted ||
        status.fullScreenIntentStatus == PermissionCheckState.unsupported;
  }

  Future<bool> openAppSettings() async {
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      try {
        return await _iosPermissionsChannel.invokeMethod<bool>(
              'openAppSettings',
            ) ??
            false;
      } catch (error, stackTrace) {
        debugPrint('Open iOS app settings failed: $error');
        debugPrintStack(stackTrace: stackTrace);
        return false;
      }
    }
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return false;
    }
    try {
      return await _androidPermissionsChannel.invokeMethod<bool>(
            'openAppSettings',
          ) ??
          false;
    } catch (error, stackTrace) {
      debugPrint('Open app settings failed: $error');
      debugPrintStack(stackTrace: stackTrace);
      return false;
    }
  }

  Future<bool> openAlarmSettings() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return false;
    }
    try {
      return await _androidPermissionsChannel.invokeMethod<bool>(
            'openAlarmSettings',
          ) ??
          false;
    } catch (error, stackTrace) {
      debugPrint('Open alarm settings failed: $error');
      debugPrintStack(stackTrace: stackTrace);
      return openAppSettings();
    }
  }

  Future<bool> openNotificationSettings() {
    return _notificationService.openAppNotificationSettings();
  }

  String _onboardingKey(String userId) => '$_onboardingPrefix:$userId';

  Future<AppPermissionStatus> checkMicrophonePermissionStatus() =>
      _iosStatus('checkMicrophonePermission');

  Future<AppPermissionStatus> requestMicrophonePermissionStatus() =>
      _iosStatus('requestMicrophonePermission');

  Future<AppPermissionStatus> checkSpeechRecognitionPermissionStatus() =>
      _iosStatus('checkSpeechRecognitionPermission');

  Future<AppPermissionStatus> requestSpeechRecognitionPermissionStatus() =>
      _iosStatus('requestSpeechRecognitionPermission');

  Future<AppPermissionStatus> checkLocationPermissionStatus() =>
      _iosStatus('checkLocationPermission');

  Future<AppPermissionStatus> requestLocationPermissionStatus() =>
      _iosStatus('requestLocationPermission');

  Future<AppPermissionStatus> checkCalendarPermissionStatus() =>
      _iosStatus('checkCalendarPermission');

  Future<AppPermissionStatus> requestCalendarPermissionStatus() =>
      _iosStatus('requestCalendarPermission');

  Future<AppPermissionStatus> _iosStatus(String method) async {
    if (defaultTargetPlatform != TargetPlatform.iOS) {
      return AppPermissionStatus.unavailable;
    }
    try {
      final value = await _iosPermissionsChannel
          .invokeMethod<String>(method)
          .timeout(const Duration(seconds: 12));
      return AppPermissionStatus.fromNative(value);
    } on TimeoutException {
      return AppPermissionStatus.timeout;
    } catch (error, stackTrace) {
      debugPrint('iOS permission operation failed ($method): $error');
      debugPrintStack(stackTrace: stackTrace);
      return AppPermissionStatus.error;
    }
  }

  double? _doubleValue(Object? value) {
    if (value is double) {
      return value;
    }
    if (value is num) {
      return value.toDouble();
    }
    return double.tryParse(value?.toString() ?? '');
  }
}

class AppPermissionSnapshot {
  const AppPermissionSnapshot({
    required this.microphoneGranted,
    this.microphoneStatus = AppPermissionStatus.granted,
    this.speechRecognitionGranted = true,
    this.speechRecognitionStatus = AppPermissionStatus.granted,
    required this.locationGranted,
    this.locationStatus = AppPermissionStatus.granted,
    required this.calendarGranted,
    this.calendarStatus = AppPermissionStatus.granted,
    required this.notificationStatus,
    this.batteryOptimizationIgnored = true,
  });

  final bool microphoneGranted;
  final AppPermissionStatus microphoneStatus;
  final bool speechRecognitionGranted;
  final AppPermissionStatus speechRecognitionStatus;
  final bool locationGranted;
  final AppPermissionStatus locationStatus;
  final bool calendarGranted;
  final AppPermissionStatus calendarStatus;
  final NotificationPermissionStatus notificationStatus;

  /// true이면 배터리 최적화 예외가 적용된 것(절전이 알람을 막지 않음).
  /// 기본값 true — 비안드로이드나 확인 실패 시 흐름을 막지 않는다.
  final bool batteryOptimizationIgnored;

  bool get notificationsGranted =>
      notificationStatus.notificationsEnabled == true;

  bool get exactAlarmsGranted => notificationStatus.exactAlarmsEnabled == true;

  bool get fullScreenIntentGranted =>
      notificationStatus.fullScreenIntentStatus ==
          PermissionCheckState.granted ||
      notificationStatus.fullScreenIntentStatus ==
          PermissionCheckState.unsupported;

  bool get requiredPermissionsGranted =>
      microphoneGranted &&
      notificationsGranted &&
      exactAlarmsGranted &&
      locationGranted &&
      calendarGranted;

  /// 알람이 정시에 울리기 위한 최소 조건 (알람 예약 가드에서 사용).
  bool get alarmWillFire => exactAlarmsGranted && batteryOptimizationIgnored;
}

enum AppPermissionStatus {
  granted,
  denied,
  settingsRequired,
  restricted,
  unavailable,
  error,
  timeout;

  static AppPermissionStatus fromNative(String? value) {
    switch (value) {
      case 'granted':
        return AppPermissionStatus.granted;
      case 'denied':
        return AppPermissionStatus.denied;
      case 'settingsRequired':
        return AppPermissionStatus.settingsRequired;
      case 'restricted':
        return AppPermissionStatus.restricted;
      case 'unavailable':
        return AppPermissionStatus.unavailable;
      case 'timeout':
        return AppPermissionStatus.timeout;
      default:
        return AppPermissionStatus.error;
    }
  }
}

class GeoPoint {
  const GeoPoint({
    required this.latitude,
    required this.longitude,
  });

  final double latitude;
  final double longitude;
}
