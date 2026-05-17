import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'notification_service.dart';

class AppPermissionService {
  AppPermissionService({
    NotificationService? notificationService,
    SharedPreferencesAsync? preferences,
  })  : _notificationService = notificationService ?? NotificationService(),
        _preferences = preferences ?? SharedPreferencesAsync();

  static const MethodChannel _androidPermissionsChannel =
      MethodChannel('planflow/android_permissions');
  static const String _onboardingPrefix = 'planflow_permissions_onboarded_v1';

  final NotificationService _notificationService;
  final SharedPreferencesAsync _preferences;

  Future<bool> isOnboardingCompleted(String userId) async {
    return await _preferences.getBool(_onboardingKey(userId)) ?? false;
  }

  Future<void> markOnboardingCompleted(String userId) {
    return _preferences.setBool(_onboardingKey(userId), true);
  }

  Future<AppPermissionSnapshot> checkAll() async {
    final notificationStatus =
        await _notificationService.checkPermissionStatus();
    return AppPermissionSnapshot(
      microphoneGranted: await checkMicrophonePermission(),
      locationGranted: await checkLocationPermission(),
      calendarGranted: await checkCalendarPermission(),
      notificationStatus: notificationStatus,
    );
  }

  Future<bool> requestMicrophonePermission() async {
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
        return getLastKnownLocation();
      }
      final latitude = _doubleValue(result['latitude']);
      final longitude = _doubleValue(result['longitude']);
      if (latitude == null || longitude == null) {
        return getLastKnownLocation();
      }
      return GeoPoint(latitude: latitude, longitude: longitude);
    } catch (error, stackTrace) {
      debugPrint('Current location read failed: $error');
      debugPrintStack(stackTrace: stackTrace);
      return getLastKnownLocation();
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

  Future<bool> openNotificationSettings() {
    return _notificationService.openAppNotificationSettings();
  }

  String _onboardingKey(String userId) => '$_onboardingPrefix:$userId';

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
    required this.locationGranted,
    required this.calendarGranted,
    required this.notificationStatus,
  });

  final bool microphoneGranted;
  final bool locationGranted;
  final bool calendarGranted;
  final NotificationPermissionStatus notificationStatus;

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
      fullScreenIntentGranted &&
      locationGranted &&
      calendarGranted;
}

class GeoPoint {
  const GeoPoint({
    required this.latitude,
    required this.longitude,
  });

  final double latitude;
  final double longitude;
}
