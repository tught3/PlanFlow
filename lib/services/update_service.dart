import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:in_app_update/in_app_update.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'remote_config_service.dart';

/// Play Store 인앱 업데이트 서비스.
///
/// 앱 resume 시 호출해서 사용 가능한 업데이트가 있으면 유도한다.
class UpdateService {
  UpdateService._();

  static Future<void> checkAndPrompt() async {
    if (kDebugMode) {
      return;
    }

    try {
      final info = await InAppUpdate.checkForUpdate()
          .timeout(const Duration(seconds: 10));

      if (info.updateAvailability != UpdateAvailability.updateAvailable) {
        return;
      }

      final shouldForceUpdate = await _shouldForceUpdate();

      if (shouldForceUpdate && info.immediateUpdateAllowed) {
        await InAppUpdate.performImmediateUpdate();
        return;
      }

      if (info.flexibleUpdateAllowed) {
        await InAppUpdate.startFlexibleUpdate();
        await InAppUpdate.completeFlexibleUpdate();
        return;
      }

      if (shouldForceUpdate) {
        debugPrint('In-app update requires attention, but no update path is available.');
      }
    } catch (error) {
      debugPrint('In-app update check skipped: $error');
    }
  }

  /// Remote Config의 min_required_version과 현재 versionCode 비교
  static Future<bool> _shouldForceUpdate() async {
    try {
      final minRequired = RemoteConfigService.minRequiredVersion;
      if (minRequired <= 0) {
        return false;
      }

      final packageInfo = await PackageInfo.fromPlatform();
      final currentCode = int.tryParse(packageInfo.buildNumber) ?? 0;

      return currentCode < minRequired;
    } catch (_) {
      return false;
    }
  }
}
