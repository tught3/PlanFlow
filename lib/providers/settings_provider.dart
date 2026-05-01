import 'package:flutter/foundation.dart';

import '../data/models/user_settings_model.dart';
import '../data/repositories/settings_repository.dart';

class SettingsProvider extends ChangeNotifier {
  SettingsProvider(this._repository);

  final SettingsRepository _repository;

  UserSettingsModel? _settings;
  bool _isLoading = false;

  UserSettingsModel? get settings => _settings;
  bool get isLoading => _isLoading;

  Future<void> load(String userId) async {
    _isLoading = true;
    notifyListeners();

    // TODO: Fill in cache/update behavior in a later checklist item.
    _settings = await _repository.fetchSettings(userId);

    _isLoading = false;
    notifyListeners();
  }
}
