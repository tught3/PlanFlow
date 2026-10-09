import 'package:flutter/foundation.dart';
import 'package:home_widget/home_widget.dart';

import 'home_widget_platform.dart';

HomeWidgetPlatform createHomeWidgetPlatformImpl() =>
    const _IoHomeWidgetPlatform();

class _IoHomeWidgetPlatform extends HomeWidgetPlatform {
  const _IoHomeWidgetPlatform();

  @override
  bool get isSupported {
    if (kIsWeb) {
      return false;
    }

    return defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS;
  }

  @override
  Future<bool> saveWidgetData(String id, Object? data) async {
    if (!isSupported) {
      return false;
    }

    // UserDefaults cannot store NSNull. Preserve nullable-value clearing on
    // iOS with the existing native reader defaults instead of forwarding null
    // through home_widget's method channel. Android intentionally keeps null:
    // its SharedPreferences contract removes the existing key.
    final nativeValue =
        defaultTargetPlatform == TargetPlatform.iOS && data == null
            ? (id == 'next_event_travel_buffer_minutes' ? 0 : '')
            : data;

    try {
      return await HomeWidget.saveWidgetData<Object?>(id, nativeValue) ?? false;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> setAppGroupId(String groupId) async {
    if (!isSupported) {
      return false;
    }

    if (defaultTargetPlatform != TargetPlatform.iOS) {
      return true;
    }

    try {
      return await HomeWidget.setAppGroupId(groupId) ?? false;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> updateWidget({
    String? name,
    String? androidName,
    String? iOSName,
    String? qualifiedAndroidName,
  }) async {
    if (!isSupported) {
      return false;
    }

    try {
      return await HomeWidget.updateWidget(
            name: name,
            androidName: androidName,
            iOSName: iOSName,
            qualifiedAndroidName: qualifiedAndroidName,
          ) ??
          false;
    } catch (_) {
      return false;
    }
  }
}
