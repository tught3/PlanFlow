import 'dart:async';
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
  Future<void> insert(Map<String, Object?> payload) async {
    await _client
        .from('feedback_reports')
        .insert(payload)
        .select('id')
        .single();
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

    try {
      await _gateway.insert(payload).timeout(const Duration(seconds: 12));
    } on PostgrestException catch (error) {
      throw FeedbackSubmissionException(_messageForPostgrest(error));
    } on SocketException {
      throw const FeedbackSubmissionException(
        '네트워크 연결을 확인한 뒤 다시 보내 주세요.',
      );
    } on TimeoutException {
      throw const FeedbackSubmissionException(
        '요청 시간이 초과됐어요. 잠시 후 다시 보내 주세요.',
      );
    }
    await _analyticsLogger(type);
    await _crashlyticsLogger(type, userId);
  }

  static String _messageForPostgrest(PostgrestException error) {
    final message = error.message.toLowerCase();
    final code = error.code;
    if (code == '42P01' ||
        code == 'PGRST205' ||
        message.contains('feedback_reports') &&
            message.contains('does not exist')) {
      return '문제 신고 저장소가 아직 준비되지 않았어요. Supabase SQL 패치를 적용해 주세요.';
    }
    if (code == '42501' ||
        message.contains('row-level security') ||
        message.contains('permission denied')) {
      return '문제 신고 권한 설정을 확인해야 해요. 로그인 상태와 Supabase RLS를 확인해 주세요.';
    }
    if (code == '23514') {
      return '입력값이 저장 규칙과 맞지 않아요. 내용을 확인한 뒤 다시 보내 주세요.';
    }
    return '문제 신고를 저장하지 못했어요. 잠시 후 다시 시도해 주세요.';
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
