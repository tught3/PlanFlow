import 'package:flutter/foundation.dart';

/// Runtime policy for the Google Mobile Ads/UMP integration.
///
/// Production only supplies an Android rewarded unit and the iOS Runner
/// plist intentionally has no GADApplicationIdentifier. Keep this decision in
/// one testable policy so no caller can accidentally enable the iOS SDK.
bool isAdsRuntimeSupported({
  bool? isWeb,
  TargetPlatform? platform,
}) {
  return !(isWeb ?? kIsWeb) &&
      (platform ?? defaultTargetPlatform) == TargetPlatform.android;
}

/// Stable, non-secret marker for an unsupported ads runtime.
String unsupportedAdsRuntimeDiagnostic(String component) =>
    'phase=skip reason=unsupported_runtime component=$component';
