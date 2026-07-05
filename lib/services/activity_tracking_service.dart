import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/env.dart';
import '../core/safe_prefs.dart';

/// 로그인/포그라운드 시점에 users 테이블의 활동 컬럼을 갱신한다.
/// 불필요한 DB 호출을 막기 위해 last_active_at 갱신은 최소 10분 간격으로 쓰로틀한다.
///
/// - 로그인 성공 시: [recordLogin] → last_login_at + last_active_at 갱신
/// - 앱 실행/포그라운드 복귀 시: [recordActive] → 10분 쓰로틀에 걸리면 스킵
class ActivityTrackingService {
  ActivityTrackingService({
    SupabaseClient? client,
    Future<SharedPreferences>? prefs,
    Future<PackageInfo> Function()? packageInfoProvider,
    Duration minActiveInterval = const Duration(minutes: 10),
  })  : _client = client ?? Supabase.instance.client,
        _prefsFuture = prefs ?? tryGetPrefs(),
        _packageInfoProvider =
            packageInfoProvider ?? PackageInfo.fromPlatform,
        _minActiveInterval = minActiveInterval;

  static const String _lastActiveKey = 'activity:last_active_recorded_at';
  static const String _lastLoginKey = 'activity:last_login_recorded_at';

  final SupabaseClient _client;
  final Future<SharedPreferences?> _prefsFuture;
  final Future<PackageInfo> Function() _packageInfoProvider;
  final Duration _minActiveInterval;

  PackageInfo? _cachedPackageInfo;
  bool _isInFlight = false;

  /// 앱 실행 / 포그라운드 복귀 시 호출.
  /// 마지막 갱신으로부터 [_minActiveInterval] 이내면 스킵한다.
  Future<bool> recordActive({bool force = false}) async {
    if (!AppEnv.isSupabaseReady) {
      return false;
    }
    final prefs = await _prefsFuture;
    if (prefs == null) return false;

    final now = DateTime.now();
    if (!force) {
      final last = _readLast(prefs, _lastActiveKey);
      if (last != null && now.difference(last) < _minActiveInterval) {
        return false;
      }
    }

    // 로그아웃 상태면 갱신하지 않는다.
    final userId = _client.auth.currentUser?.id;
    if (userId == null || userId.isEmpty) {
      return false;
    }

    await _invokeRecord(prefs: prefs, markLogin: false);
    return true;
  }

  /// 로그인 성공 시 호출. last_login_at과 last_active_at을 동시에 갱신.
  Future<bool> recordLogin({bool force = false}) async {
    if (!AppEnv.isSupabaseReady) {
      return false;
    }
    final prefs = await _prefsFuture;
    if (prefs == null) return false;

    final userId = _client.auth.currentUser?.id;
    if (userId == null || userId.isEmpty) {
      return false;
    }

    final now = DateTime.now();
    if (!force) {
      final last = _readLast(prefs, _lastLoginKey);
      // 동일 세션에서 반복 호출되는 것을 방지(5분 쿨다운).
      if (last != null && now.difference(last) < const Duration(minutes: 5)) {
        return false;
      }
    }

    await _invokeRecord(prefs: prefs, markLogin: true);
    return true;
  }

  Future<void> _invokeRecord({
    required SharedPreferences? prefs,
    required bool markLogin,
  }) async {
    if (_isInFlight) {
      return;
    }
    _isInFlight = true;
    try {
      final packageInfo = await _ensurePackageInfo();
      final platform = _detectPlatform();

      await _client.rpc('record_user_activity', params: <String, dynamic>{
        'p_app_version': packageInfo.version,
        'p_build_number': packageInfo.buildNumber,
        'p_platform': platform,
        'p_mark_login': markLogin,
      }).timeout(const Duration(seconds: 12));

      final now = DateTime.now();
      await prefs?.setString(
        _lastActiveKey,
        now.toUtc().toIso8601String(),
      );
      if (markLogin) {
        await prefs?.setString(
          _lastLoginKey,
          now.toUtc().toIso8601String(),
        );
      }
    } catch (error) {
      debugPrint('ActivityTracking record failed: $error');
    } finally {
      _isInFlight = false;
    }
  }

  Future<PackageInfo> _ensurePackageInfo() async {
    final cached = _cachedPackageInfo;
    if (cached != null) {
      return cached;
    }
    final info = await _packageInfoProvider();
    _cachedPackageInfo = info;
    return info;
  }

  String _detectPlatform() {
    if (kIsWeb) return 'web';
    try {
      return Platform.operatingSystem.toLowerCase();
    } catch (_) {
      return 'android';
    }
  }

  DateTime? _readLast(SharedPreferences prefs, String key) {
    final raw = prefs.getString(key);
    if (raw == null || raw.trim().isEmpty) return null;
    return DateTime.tryParse(raw)?.toLocal();
  }
}
