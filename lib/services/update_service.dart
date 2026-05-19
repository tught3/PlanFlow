import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:in_app_update/in_app_update.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import 'notification_service.dart';
import 'remote_config_service.dart';

/// Play Store 인앱 업데이트 서비스.
///
/// 앱 시작/복귀 시 체크하고, 필수 업데이트는 Play in-app update를 우선 시도합니다.
class UpdateService {
  UpdateService._({
    required UpdateFlowGateway updateFlow,
    required AppVersionMetadataProvider versionMetadataProvider,
    required UpdateVersionTracker versionTracker,
    required PlayStoreLauncher playStoreLauncher,
    required UpdatePostUpdateHook postUpdateHook,
    required int Function() minRequiredVersionProvider,
    required Duration checkTimeout,
    required bool skipInDebug,
  })  : _updateFlow = updateFlow,
        _versionMetadataProvider = versionMetadataProvider,
        _versionTracker = versionTracker,
        _playStoreLauncher = playStoreLauncher,
        _postUpdateHook = postUpdateHook,
        _minRequiredVersionProvider = minRequiredVersionProvider,
        _checkTimeout = checkTimeout,
        _skipInDebug = skipInDebug;

  UpdateService({
    UpdateFlowGateway? updateFlow,
    AppVersionMetadataProvider? versionMetadataProvider,
    UpdateVersionTracker? versionTracker,
    PlayStoreLauncher? playStoreLauncher,
    UpdatePostUpdateHook? postUpdateHook,
    int Function()? minRequiredVersionProvider,
    Duration checkTimeout = const Duration(seconds: 10),
    bool skipInDebug = true,
  }) : this._(
          updateFlow: updateFlow ?? const InAppUpdateFlowGateway(),
          versionMetadataProvider:
              versionMetadataProvider ?? const PackageInfoMetadataProvider(),
          versionTracker:
              versionTracker ?? const SharedPreferencesUpdateVersionTracker(),
          playStoreLauncher:
              playStoreLauncher ?? const PlayStoreFallbackLauncher(),
          postUpdateHook: postUpdateHook ?? NotificationPostUpdateHook(),
          minRequiredVersionProvider:
              minRequiredVersionProvider ?? _defaultMinRequiredVersion,
          checkTimeout: checkTimeout,
          skipInDebug: skipInDebug,
        );

  static final UpdateService _defaultInstance = UpdateService();
  static UpdateService _instance = _defaultInstance;

  static UpdateService get instance => _instance;

  @visibleForTesting
  static set instance(UpdateService service) {
    _instance = service;
  }

  @visibleForTesting
  static void resetForTest() {
    _instance = _defaultInstance;
  }

  static Future<void> checkAndPrompt() async {
    await _instance._checkAndPrompt();
  }

  Future<void> _checkAndPrompt() async {
    if (_inFlightCheck != null) {
      return _inFlightCheck;
    }
    final check = _checkAndPromptLocked();
    _inFlightCheck = check;
    try {
      await check;
    } finally {
      if (identical(_inFlightCheck, check)) {
        _inFlightCheck = null;
      }
    }
  }

  Future<void> _checkAndPromptLocked() async {
    if (_skipInDebug && kDebugMode) {
      return;
    }

    final metadata = await _versionMetadataProvider.load();
    if (metadata == null) {
      debugPrint('UpdateService skipped: version metadata unavailable.');
      return;
    }

    await _runPostUpdateHook(metadata);

    final shouldForceUpdate = await _shouldForceUpdate(
      currentCode: metadata.buildNumber,
      minRequired: _minRequiredVersionProvider(),
    );

    try {
      final info = await _updateFlow.checkForUpdate().timeout(_checkTimeout);

      if (info.updateAvailability != UpdateAvailabilityState.available) {
        if (shouldForceUpdate) {
          await _fallbackToPlayStore(metadata.packageName);
        }
        return;
      }

      if (shouldForceUpdate && info.immediateUpdateAllowed) {
        await _updateFlow.performImmediateUpdate();
        return;
      }

      if (info.flexibleUpdateAllowed) {
        await _updateFlow.startFlexibleUpdate();
        await _updateFlow.completeFlexibleUpdate();
        return;
      }

      if (shouldForceUpdate) {
        await _fallbackToPlayStore(metadata.packageName);
      } else {
        debugPrint(
          'Update available but no update path is currently available.',
        );
      }
    } catch (error) {
      debugPrint('In-app update check skipped: $error');
      if (shouldForceUpdate) {
        await _fallbackToPlayStore(metadata.packageName);
      }
    }
  }

  Future<void> _runPostUpdateHook(AppVersionMetadata metadata) async {
    try {
      final previous = await _versionTracker.loadLastSeenVersionCode();
      if (previous != null && previous >= metadata.buildNumber) {
        return;
      }
      await _postUpdateHook.run();
      await _versionTracker.saveLastSeenVersionCode(metadata.buildNumber);
    } catch (error, stackTrace) {
      debugPrint('Post-update hook skipped: $error');
      debugPrintStack(stackTrace: stackTrace);
    }
  }

  Future<bool> _fallbackToPlayStore(String packageName) async {
    try {
      return await _playStoreLauncher.openPlayStoreDetails(packageName);
    } catch (error, stackTrace) {
      debugPrint('Play store fallback failed: $error');
      debugPrintStack(stackTrace: stackTrace);
      return false;
    }
  }

  Future<bool> _shouldForceUpdate({
    required int currentCode,
    required int minRequired,
  }) async {
    if (minRequired <= 0) {
      return false;
    }
    return currentCode < minRequired;
  }

  static int _defaultMinRequiredVersion() {
    return RemoteConfigService.minRequiredVersion;
  }

  final UpdateFlowGateway _updateFlow;
  final AppVersionMetadataProvider _versionMetadataProvider;
  final UpdateVersionTracker _versionTracker;
  final PlayStoreLauncher _playStoreLauncher;
  final UpdatePostUpdateHook _postUpdateHook;
  final int Function() _minRequiredVersionProvider;
  final Duration _checkTimeout;
  final bool _skipInDebug;
  Future<void>? _inFlightCheck;
}

class AppVersionMetadata {
  const AppVersionMetadata({
    required this.buildNumber,
    required this.packageName,
  });

  final int buildNumber;
  final String packageName;
}

enum UpdateAvailabilityState {
  available,
  unavailable,
  unknown,
}

class UpdateCheckResult {
  const UpdateCheckResult({
    required this.updateAvailability,
    required this.immediateUpdateAllowed,
    required this.flexibleUpdateAllowed,
  });

  final UpdateAvailabilityState updateAvailability;
  final bool immediateUpdateAllowed;
  final bool flexibleUpdateAllowed;
}

abstract class UpdateFlowGateway {
  Future<UpdateCheckResult> checkForUpdate();
  Future<void> performImmediateUpdate();
  Future<void> startFlexibleUpdate();
  Future<void> completeFlexibleUpdate();
}

class InAppUpdateFlowGateway implements UpdateFlowGateway {
  const InAppUpdateFlowGateway();

  @override
  Future<UpdateCheckResult> checkForUpdate() async {
    final info = await InAppUpdate.checkForUpdate();
    final availability = switch (info.updateAvailability) {
      UpdateAvailability.updateAvailable => UpdateAvailabilityState.available,
      UpdateAvailability.updateNotAvailable =>
        UpdateAvailabilityState.unavailable,
      _ => UpdateAvailabilityState.unknown,
    };

    return UpdateCheckResult(
      updateAvailability: availability,
      immediateUpdateAllowed: info.immediateUpdateAllowed,
      flexibleUpdateAllowed: info.flexibleUpdateAllowed,
    );
  }

  @override
  Future<void> performImmediateUpdate() {
    return InAppUpdate.performImmediateUpdate();
  }

  @override
  Future<void> startFlexibleUpdate() {
    return InAppUpdate.startFlexibleUpdate();
  }

  @override
  Future<void> completeFlexibleUpdate() {
    return InAppUpdate.completeFlexibleUpdate();
  }
}

abstract class AppVersionMetadataProvider {
  Future<AppVersionMetadata?> load();
}

class PackageInfoMetadataProvider implements AppVersionMetadataProvider {
  const PackageInfoMetadataProvider();

  @override
  Future<AppVersionMetadata?> load() async {
    try {
      final packageInfo = await PackageInfo.fromPlatform();
      final buildNumber = int.tryParse(packageInfo.buildNumber);
      final packageName = packageInfo.packageName.trim();
      if (buildNumber == null || packageName.isEmpty) {
        return null;
      }
      return AppVersionMetadata(
        buildNumber: buildNumber,
        packageName: packageName,
      );
    } catch (error, stackTrace) {
      debugPrint('Failed to read app version metadata: $error');
      debugPrintStack(stackTrace: stackTrace);
      return null;
    }
  }
}

abstract class UpdateVersionTracker {
  Future<int?> loadLastSeenVersionCode();
  Future<void> saveLastSeenVersionCode(int code);
}

class SharedPreferencesUpdateVersionTracker implements UpdateVersionTracker {
  const SharedPreferencesUpdateVersionTracker();

  static const String _lastSeenVersionCodeKey = 'update:last_seen_version_code';

  @override
  Future<int?> loadLastSeenVersionCode() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_lastSeenVersionCodeKey);
  }

  @override
  Future<void> saveLastSeenVersionCode(int code) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_lastSeenVersionCodeKey, code);
  }
}

abstract class PlayStoreLauncher {
  Future<bool> openPlayStoreDetails(String packageName);
}

class PlayStoreFallbackLauncher implements PlayStoreLauncher {
  const PlayStoreFallbackLauncher();

  @override
  Future<bool> openPlayStoreDetails(String packageName) async {
    final marketUri = Uri.parse('market://details?id=$packageName');
    final marketOpened = await launchUrl(
      marketUri,
      mode: LaunchMode.externalApplication,
    );
    if (marketOpened) {
      return true;
    }

    final webUri = Uri.parse(
      'https://play.google.com/store/apps/details?id=$packageName',
    );
    return launchUrl(webUri, mode: LaunchMode.externalApplication);
  }
}

abstract class UpdatePostUpdateHook {
  Future<void> run();
}

class NotificationPostUpdateHook implements UpdatePostUpdateHook {
  NotificationPostUpdateHook({NotificationService? notificationService})
      : _notificationService = notificationService ?? NotificationService();

  final NotificationService _notificationService;

  @override
  Future<void> run() async {
    await _notificationService.reinitializeForAppUpdate();
  }
}
