import 'package:in_app_review/in_app_review.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Play Store 인앱 리뷰 요청 서비스.
///
/// 일정 저장 횟수를 누적해 일정 횟수 도달 시 리뷰를 요청한다.
class ReviewService {
  ReviewService._();

  static const String _kSaveCount = 'event_save_count_for_review';
  static const int _kReviewThreshold = 3;

  static Future<void> onEventSaved() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final count = (prefs.getInt(_kSaveCount) ?? 0) + 1;
      await prefs.setInt(_kSaveCount, count);

      if (count == _kReviewThreshold) {
        final inAppReview = InAppReview.instance;
        if (await inAppReview.isAvailable()) {
          await inAppReview.requestReview();
        }
      }
    } catch (_) {
      // 리뷰 요청 실패는 앱 동작에 영향을 주지 않는다.
    }
  }
}
