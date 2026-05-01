import '../models/user_settings_model.dart';

abstract class SettingsRepository {
  const SettingsRepository();

  Future<UserSettingsModel?> fetchSettings(String userId);

  Future<void> saveSettings(UserSettingsModel settings);
}
