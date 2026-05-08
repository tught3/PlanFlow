import 'package:flutter/foundation.dart';

import '../data/models/user_settings_model.dart';
import '../data/repositories/settings_repository.dart';

class SettingsProvider extends ChangeNotifier {
  SettingsProvider(this._repository);

  final SettingsRepository _repository;

  UserSettingsModel? _settings;
  bool _isLoading = false;
  bool _isSaving = false;

  UserSettingsModel? get settings => _settings;
  bool get isLoading => _isLoading;
  bool get isSaving => _isSaving;

  Future<UserSettingsModel?> load(String userId) async {
    _isLoading = true;
    notifyListeners();

    try {
      _settings = await _repository.fetchSettings(userId);
      return _settings;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<UserSettingsModel> save(UserSettingsModel settings) async {
    _isSaving = true;
    notifyListeners();

    try {
      _settings = await _repository.saveSettings(settings);
      return _settings!;
    } finally {
      _isSaving = false;
      notifyListeners();
    }
  }

  void clear() {
    _settings = null;
    notifyListeners();
  }
}
