import 'package:flutter/foundation.dart';

import 'remote_config_service.dart';

/// Runtime policy for the Google Mobile Ads/UMP integration.
///
final RegExp _rewardedAdUnitIdPattern = RegExp(r'^ca-app-pub-\d{16}/\d{1,20}$');
bool? _useTestUnitOverride;

@visibleForTesting
set adsUseTestUnitForTesting(bool? value) => _useTestUnitOverride = value;

/// Returns whether the ads runtime is eligible for the current platform.
/// Android remains enabled independently of its Remote Config unit. iOS is
/// eligible only when its platform-specific unit is present and valid.
bool isAdsRuntimeSupported({
  bool? isWeb,
  TargetPlatform? platform,
  String? iosRewardedAdUnitId,
  bool? useTestUnit,
}) {
  if (isWeb ?? kIsWeb) return false;
  final resolvedPlatform = platform ?? defaultTargetPlatform;
  if (resolvedPlatform == TargetPlatform.android) return true;
  if (resolvedPlatform != TargetPlatform.iOS) return false;
  if (useTestUnit ?? _useTestUnitOverride ?? (kDebugMode || kProfileMode)) {
    return true;
  }
  final configured =
      (iosRewardedAdUnitId ?? RemoteConfigService.rewardedAdUnitIdIos).trim();
  return _rewardedAdUnitIdPattern.hasMatch(configured);
}

/// Stable, non-secret marker for an unsupported ads runtime.
String unsupportedAdsRuntimeDiagnostic(String component) =>
    'phase=skip reason=unsupported_runtime component=$component';
