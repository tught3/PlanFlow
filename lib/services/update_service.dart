import 'package:in_app_update/in_app_update.dart';

/// Play Store 인앱 업데이트 서비스.
///
/// 앱 resume 시 호출해서 사용 가능한 업데이트가 있으면 유도한다.
class UpdateService {
  UpdateService._();

  static Future<void> checkAndPrompt() async {
    try {
      final info = await InAppUpdate.checkForUpdate();

      if (info.updateAvailability != UpdateAvailability.updateAvailable) {
        return;
      }

      if (info.immediateUpdateAllowed) {
        await InAppUpdate.performImmediateUpdate();
      } else if (info.flexibleUpdateAllowed) {
        await InAppUpdate.startFlexibleUpdate();
        await InAppUpdate.completeFlexibleUpdate();
      }
    } catch (_) {
      // 업데이트 확인 실패는 앱 동작에 영향을 주지 않는다.
    }
  }
}
