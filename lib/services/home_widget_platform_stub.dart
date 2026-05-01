import 'home_widget_platform.dart';

HomeWidgetPlatform createHomeWidgetPlatformImpl() =>
    const _StubHomeWidgetPlatform();

class _StubHomeWidgetPlatform extends HomeWidgetPlatform {
  const _StubHomeWidgetPlatform();

  @override
  bool get isSupported => false;

  @override
  Future<bool> saveWidgetData(String id, Object? data) async {
    return false;
  }

  @override
  Future<bool> setAppGroupId(String groupId) async {
    return false;
  }

  @override
  Future<bool> updateWidget({
    String? name,
    String? androidName,
    String? iOSName,
    String? qualifiedAndroidName,
  }) async {
    return false;
  }
}
