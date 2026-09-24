import 'package:in_app_review/in_app_review.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Google Play / App Store 네이티브 리뷰 요청 서비스.
///
/// 사용자가 실제로 일정을 저장해 앱을 충분히 사용한 뒤에만 OS 리뷰
/// 프롬프트를 요청한다. 프롬프트 표시 여부 자체는 Android/iOS가 결정한다.
class ReviewService {
  ReviewService._();

  static const String _kSaveCount = 'event_save_count_for_review';
  static const String _kFirstSaveAt = 'review_first_save_at';
  static const String _kActiveDays = 'review_active_days';
  static const String _kLastPromptAt = 'review_last_prompt_at';
  static const int _kReviewThreshold = 5;
  static const int _kMinimumActiveDays = 3;
  static const Duration _kMinimumUsageAge = Duration(days: 7);
  static const Duration _kPromptCooldown = Duration(days: 120);

  static Future<void> _serial = Future<void>.value();

  static Future<void> onEventSaved({
    SharedPreferences? preferences,
    DateTime Function()? now,
    Future<bool> Function()? isAvailable,
    Future<void> Function()? requestReview,
  }) {
    final operation = _serial.then((_) => _recordSave(
          preferences: preferences,
          now: now,
          isAvailable: isAvailable,
          requestReview: requestReview,
        ));
    _serial = operation.catchError((_) {});
    return operation;
  }

  static Future<void> _recordSave({
    required SharedPreferences? preferences,
    required DateTime Function()? now,
    required Future<bool> Function()? isAvailable,
    required Future<void> Function()? requestReview,
  }) async {
    try {
      final prefs = preferences ?? await SharedPreferences.getInstance();
      final current = now?.call() ?? DateTime.now();
      final today = _dateKey(current);
      final activeDays = <String>{
        ...?prefs.getStringList(_kActiveDays),
        today,
      };
      final firstSaveAt =
          prefs.getInt(_kFirstSaveAt) ?? current.millisecondsSinceEpoch;
      final count = (prefs.getInt(_kSaveCount) ?? 0) + 1;
      await prefs.setInt(_kSaveCount, count);
      await prefs.setInt(_kFirstSaveAt, firstSaveAt);
      await prefs.setStringList(_kActiveDays, activeDays.toList()..sort());

      final hasEnoughSaves = count >= _kReviewThreshold;
      final hasEnoughActiveDays = activeDays.length >= _kMinimumActiveDays;
      final hasEnoughUsageAge = current
              .difference(DateTime.fromMillisecondsSinceEpoch(firstSaveAt)) >=
          _kMinimumUsageAge;
      if (!hasEnoughSaves && !hasEnoughActiveDays && !hasEnoughUsageAge) {
        return;
      }
      final lastPromptAt = prefs.getInt(_kLastPromptAt);
      if (lastPromptAt != null &&
          current.difference(
                  DateTime.fromMillisecondsSinceEpoch(lastPromptAt)) <
              _kPromptCooldown) {
        return;
      }

      final available = isAvailable ?? InAppReview.instance.isAvailable;
      final request = requestReview ?? InAppReview.instance.requestReview;
      if (!await available()) {
        return;
      }
      await request();
      await prefs.setInt(_kLastPromptAt, current.millisecondsSinceEpoch);
    } catch (_) {
      // 리뷰 요청 실패는 앱 동작에 영향을 주지 않는다.
    }
  }

  static String _dateKey(DateTime value) =>
      '${value.year.toString().padLeft(4, '0')}-'
      '${value.month.toString().padLeft(2, '0')}-'
      '${value.day.toString().padLeft(2, '0')}';
}
