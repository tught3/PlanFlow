import 'package:flutter/foundation.dart';

/// True only for the native iOS runtime. Tests can scope
/// [debugDefaultTargetPlatformOverride] to exercise either platform.
bool get isNativeIOS => !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;
