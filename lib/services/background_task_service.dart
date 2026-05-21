import 'package:flutter/foundation.dart';

import 'app_feedback_service.dart';

class BackgroundTaskService {
  const BackgroundTaskService._();

  static Future<void> run(
    Future<void> Function() task, {
    required String owner,
    required String label,
    String? failureMessage,
  }) async {
    try {
      await task();
    } catch (error, stackTrace) {
      debugPrint('$owner background task failed ($label): $error');
      debugPrintStack(stackTrace: stackTrace);
      if (failureMessage != null && failureMessage.trim().isNotEmpty) {
        AppFeedbackService.showSnackBar(failureMessage);
      }
    }
  }
}
