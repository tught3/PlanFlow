import 'package:flutter/foundation.dart';

class BackgroundTaskService {
  const BackgroundTaskService._();

  static Future<void> run(
    Future<void> Function() task, {
    required String owner,
    required String label,
  }) async {
    try {
      await task();
    } catch (error, stackTrace) {
      debugPrint('$owner background task failed ($label): $error');
      debugPrintStack(stackTrace: stackTrace);
    }
  }
}
