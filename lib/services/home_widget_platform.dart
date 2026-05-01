import 'home_widget_platform_stub.dart'
    if (dart.library.io) 'home_widget_platform_io.dart';

abstract class HomeWidgetPlatform {
  const HomeWidgetPlatform();

  bool get isSupported;

  Future<bool> saveWidgetData(String id, Object? data);

  Future<bool> updateWidget({
    String? name,
    String? androidName,
    String? iOSName,
    String? qualifiedAndroidName,
  });

  Future<bool> setAppGroupId(String groupId);
}

HomeWidgetPlatform createHomeWidgetPlatform() => createHomeWidgetPlatformImpl();
