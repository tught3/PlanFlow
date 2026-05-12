import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/analytics_service.dart';
import '../../core/env.dart';
import '../models/feedback_report_model.dart';

abstract class FeedbackReportGateway {
  Future<void> insert(Map<String, Object?> payload);
}

class SupabaseFeedbackReportGateway implements FeedbackReportGateway {
  SupabaseFeedbackReportGateway(this._client);

  final SupabaseClient _client;

  @override
  Future<void> insert(Map<String, Object?> payload) {
    return _client.from('feedback_reports').insert(payload);
  }
}

class FeedbackRepository {
  FeedbackRepository({
    required FeedbackReportGateway gateway,
    required String? Function() currentUserId,
    Future<FeedbackDiagnostics> Function(String routeOrScreen)?
        diagnosticsProvider,
    Future<void> Function(FeedbackReportType type)? analyticsLogger,
    Future<void> Function(FeedbackReportType type, String userId)?
        crashlyticsLogger,
  })  : _gateway = gateway,
        _currentUserId = currentUserId,
        _diagnosticsProvider = diagnosticsProvider ?? _defaultDiagnostics,
        _analyticsLogger = analyticsLogger ??
            ((type) => AnalyticsService.logFeedbackSubmitted(type: type.value)),
        _crashlyticsLogger = crashlyticsLogger ?? _logFeedbackToCrashlytics;

  factory FeedbackRepository.supabase() {
    if (!AppEnv.isSupabaseReady) {
      throw const FeedbackSubmissionException('Supabase 설정이 필요합니다.');
    }
    final client = Supabase.instance.client;
    return FeedbackRepository(
      gateway: SupabaseFeedbackReportGateway(client),
      currentUserId: () => client.auth.currentUser?.id,
    );
  }

  final FeedbackReportGateway _gateway;
  final String? Function() _currentUserId;
  final Future<FeedbackDiagnostics> Function(String routeOrScreen)
      _diagnosticsProvider;
  final Future<void> Function(FeedbackReportType type) _analyticsLogger;
  final Future<void> Function(FeedbackReportType type, String userId)
      _crashlyticsLogger;

  Future<void> submitReport({
    required FeedbackReportType type,
    required String message,
    required String routeOrScreen,
    String? expectedBehavior,
  }) async {
    final trimmedMessage = message.trim();
    if (trimmedMessage.length < 5) {
      throw const FeedbackSubmissionException('내용을 5자 이상 입력해 주세요.');
    }

    final userId = _currentUserId();
    if (userId == null || userId.trim().isEmpty) {
      throw const FeedbackSubmissionException('로그인 후 문제를 보낼 수 있어요.');
    }

    final diagnostics = await _diagnosticsProvider(routeOrScreen);
    final payload = <String, Object?>{
      'user_id': userId,
      'type': type.value,
      'message': trimmedMessage,
      'expected_behavior': expectedBehavior?.trim().isEmpty ?? true
          ? null
          : expectedBehavior!.trim(),
      'app_version': diagnostics.appVersion,
      'platform': diagnostics.platform,
      'device_summary': diagnostics.deviceSummary,
      'route_or_screen': routeOrScreen,
      'diagnostics': diagnostics.diagnostics,
      'status': 'new',
    };

    await _gateway.insert(payload);
    await _analyticsLogger(type);
    await _crashlyticsLogger(type, userId);
  }

  static Future<FeedbackDiagnostics> _defaultDiagnostics(
    String routeOrScreen,
  ) async {
    final packageInfo = await PackageInfo.fromPlatform();
    final prefs = await SharedPreferences.getInstance();
    final platform = kIsWeb ? 'web' : Platform.operatingSystem;
    final osVersion = kIsWeb ? 'web' : Platform.operatingSystemVersion;
    final appVersion = '${packageInfo.version}+${packageInfo.buildNumber}';

    return FeedbackDiagnostics(
      appVersion: appVersion,
      platform: platform,
      deviceSummary: osVersion,
      diagnostics: <String, Object?>{
        'app_name': packageInfo.appName,
        'package_name': packageInfo.packageName,
        'version': packageInfo.version,
        'build_number': packageInfo.buildNumber,
        'route_or_screen': routeOrScreen,
        'calendar_sync_last_reason':
            prefs.getString('calendar_sync:last_reason'),
        'calendar_sync_last_attempt_at':
            prefs.getString('calendar_sync:last_attempt_at'),
        'calendar_sync_last_completed':
            prefs.getStringList('calendar_sync:last_completed'),
        'calendar_sync_last_failed':
            prefs.getStringList('calendar_sync:last_failed'),
        'client_created_at': DateTime.now().toUtc().toIso8601String(),
      },
    );
  }

  static Future<void> _logFeedbackToCrashlytics(
    FeedbackReportType type,
    String userId,
  ) async {
    if (Firebase.apps.isEmpty) {
      return;
    }
    final crashlytics = FirebaseCrashlytics.instance;
    await crashlytics.setCustomKey('feedback_type', type.value);
    await crashlytics.setCustomKey('feedback_user_id', userId);
    crashlytics.log('feedback_submitted type=${type.value}');
  }
}
