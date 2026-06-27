import 'dart:async';
import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/analytics_service.dart';
import '../../core/diag_logger.dart';
import '../../core/env.dart';
import '../../services/departure_alarm_service.dart';
import '../models/feedback_report_model.dart';

abstract class FeedbackReportGateway {
  Future<void> insert(Map<String, Object?> payload);
}

abstract class FeedbackReportAdminGateway implements FeedbackReportGateway {
  Future<List<Map<String, Object?>>> fetchAdminReports({
    FeedbackReportStatus? status,
    int limit = 100,
  });

  Future<void> updateReportStatus({
    required String reportId,
    required FeedbackReportStatus status,
  });
}

class SupabaseFeedbackReportGateway implements FeedbackReportAdminGateway {
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

  @override
  Future<List<Map<String, Object?>>> fetchAdminReports({
    FeedbackReportStatus? status,
    int limit = 100,
  }) async {
    final query = _client.from('feedback_reports').select();
    final List<dynamic> response = status == null
        ? await query.order('created_at', ascending: false).limit(limit)
        : await query
            .eq('status', status.value)
            .order('created_at', ascending: false)
            .limit(limit);
    return response
        .map((row) => Map<String, Object?>.from(row as Map))
        .toList(growable: false);
  }

  @override
  Future<void> updateReportStatus({
    required String reportId,
    required FeedbackReportStatus status,
  }) async {
    await _client
        .from('feedback_reports')
        .update(<String, Object?>{'status': status.value})
        .eq('id', reportId)
        .select('id')
        .single();
  }
}

class FeedbackRepository {
  FeedbackRepository({
    required FeedbackReportGateway gateway,
    required String? Function() currentUserId,
    Future<FeedbackDiagnostics> Function(
      String routeOrScreen, {
      bool attachDiagLog,
    })? diagnosticsProvider,
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

  /// 진단 로그 첨부 시 8000자를 넘지 않도록 자른다.
  static const int _diagLogMaxChars = 8000;

  final FeedbackReportGateway _gateway;
  final String? Function() _currentUserId;
  final Future<FeedbackDiagnostics> Function(
    String routeOrScreen, {
    bool attachDiagLog,
  }) _diagnosticsProvider;
  final Future<void> Function(FeedbackReportType type) _analyticsLogger;
  final Future<void> Function(FeedbackReportType type, String userId)
      _crashlyticsLogger;

  Future<void> submitReport({
    required FeedbackReportType type,
    required String message,
    required String routeOrScreen,
    String? expectedBehavior,
    bool attachDiagLog = true,
  }) async {
    final trimmedMessage = message.trim();
    if (trimmedMessage.length < 5) {
      throw const FeedbackSubmissionException('내용을 5자 이상 입력해 주세요.');
    }

    final userId = _currentUserId();
    if (userId == null || userId.trim().isEmpty) {
      throw const FeedbackSubmissionException('로그인 후 문제를 보낼 수 있어요.');
    }

    final diagnostics = await _diagnosticsProvider(
      routeOrScreen,
      attachDiagLog: attachDiagLog,
    );
    final payload = <String, Object?>{
      'user_id': userId,
      'product': 'planflow',
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

  Future<List<FeedbackReport>> fetchAdminReports({
    FeedbackReportStatus? status,
    int limit = 100,
  }) async {
    if (limit < 1 || limit > 500) {
      throw const FeedbackSubmissionException('조회 개수는 1~500개로 요청해 주세요.');
    }

    final gateway = _adminGateway();
    try {
      final rows = await gateway
          .fetchAdminReports(status: status, limit: limit)
          .timeout(const Duration(seconds: 12));
      return rows.map(FeedbackReport.fromMap).toList(growable: false);
    } on PostgrestException catch (error) {
      throw FeedbackSubmissionException(_messageForPostgrest(error));
    } on SocketException {
      throw const FeedbackSubmissionException(
        '네트워크 연결을 확인한 뒤 다시 조회해 주세요.',
      );
    } on TimeoutException {
      throw const FeedbackSubmissionException(
        '요청 시간이 초과됐어요. 잠시 후 다시 조회해 주세요.',
      );
    }
  }

  Future<int> countNewAdminReports({int limit = 100}) async {
    final reports = await fetchAdminReports(
      status: FeedbackReportStatus.newReport,
      limit: limit,
    );
    return reports.length;
  }

  Future<void> updateReportStatus({
    required String reportId,
    required FeedbackReportStatus status,
  }) async {
    if (reportId.trim().isEmpty) {
      throw const FeedbackSubmissionException('문제 신고 ID가 필요합니다.');
    }

    final gateway = _adminGateway();
    try {
      await gateway
          .updateReportStatus(reportId: reportId, status: status)
          .timeout(const Duration(seconds: 12));
    } on PostgrestException catch (error) {
      throw FeedbackSubmissionException(_messageForPostgrest(error));
    } on SocketException {
      throw const FeedbackSubmissionException(
        '네트워크 연결을 확인한 뒤 다시 저장해 주세요.',
      );
    } on TimeoutException {
      throw const FeedbackSubmissionException(
        '요청 시간이 초과됐어요. 잠시 후 다시 저장해 주세요.',
      );
    }
  }

  FeedbackReportAdminGateway _adminGateway() {
    final gateway = _gateway;
    if (gateway is FeedbackReportAdminGateway) {
      return gateway;
    }
    throw const FeedbackSubmissionException('관리자 문제 신고 기능을 사용할 수 없어요.');
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
    String routeOrScreen, {
    bool attachDiagLog = true,
  }) async {
    final packageInfo = await PackageInfo.fromPlatform();
    final prefs = await SharedPreferences.getInstance();
    final platform = kIsWeb ? 'web' : Platform.operatingSystem;
    final osVersion = kIsWeb ? 'web' : Platform.operatingSystemVersion;
    final appVersion = '${packageInfo.version}+${packageInfo.buildNumber}';

    // 진단 로그 스냅샷 (사용자가 동의한 경우에만 첨부)
    String? diagLog;
    String? preflightLastRun;
    if (attachDiagLog) {
      final rawLog = DiagLogger.dump();
      diagLog = rawLog.length > _diagLogMaxChars
          ? rawLog.substring(rawLog.length - _diagLogMaxChars)
          : rawLog;
      preflightLastRun =
          prefs.getString(departurePreflightLastRunKey);
    }

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
        if (attachDiagLog) ...{
          'diag_log': diagLog,
          'departure_preflight_last_run': preflightLastRun,
        },
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
