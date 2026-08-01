import '../core/safe_prefs.dart';

/// Stores the completion state locally because the tour explains this device's UI.
abstract class FeatureTourStore {
  const FeatureTourStore();

  Future<bool> shouldShow();
  Future<void> markCompleted();
  Future<bool> shouldShowTip(String tipId);
  Future<void> markTipShown(String tipId);
}

class SharedPreferencesFeatureTourStore extends FeatureTourStore {
  const SharedPreferencesFeatureTourStore();

  static const completedKey = 'feature_tour_completed_v1';
  static const _tipKeyPrefix = 'feature_tour_tip_v1:';

  @override
  Future<bool> shouldShow() async {
    final prefs = await tryGetPrefs();
    if (prefs == null) return false;
    return prefs.getBool(completedKey) != true;
  }

  @override
  Future<void> markCompleted() async {
    final prefs = await tryGetPrefs();
    if (prefs == null) return;
    try {
      await prefs.setBool(completedKey, true);
    } catch (_) {
      // A one-time guide must never prevent the user from leaving the screen.
    }
  }

  @override
  Future<bool> shouldShowTip(String tipId) async {
    final prefs = await tryGetPrefs();
    if (prefs == null) return false;
    return prefs.getBool('$_tipKeyPrefix$tipId') != true;
  }

  @override
  Future<void> markTipShown(String tipId) async {
    final prefs = await tryGetPrefs();
    if (prefs == null) return;
    try {
      await prefs.setBool('$_tipKeyPrefix$tipId', true);
    } catch (_) {
      // Tips are optional; a transient preference failure is safe to ignore.
    }
  }
}
