import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 광고 보상 상태(granted/pending/expired)를 SharedPreferences에 영속 보관한다.
///
/// - 같은 requestId로 중복 보상 누적을 막는다.
/// - 광고 완료 직후 앱이 죽어도 granted 상태가 남아 다음 실행 시 회복한다.
/// - 만료 시각(예: 1시간)을 두어 그 안에서만 보상을 인정한다.
class AdRewardState {
  AdRewardState._({SharedPreferences? preferences})
      : _prefsFuture = preferences != null
            ? Future<SharedPreferences>.value(preferences)
            : SharedPreferences.getInstance();

  AdRewardState.withPrefs(SharedPreferences prefs)
      : _prefsFuture = Future<SharedPreferences>.value(prefs);

  static AdRewardState? _instance;

  /// 'rewarded_ads' 네임스페이스의 SharedPreferences 키.
  static const String _kRequestId = 'rewarded.active_request_id';
  static const String _kGrantedAtMs = 'rewarded.granted_at_ms';
  static const String _kTtlMs = 'rewarded.ttl_ms';

  /// 보상 인정 유효 시간. 1시간(충분히 길고, 늘어나지 않도록 보수적으로).
  static const Duration defaultTtl = Duration(hours: 1);

  final Future<SharedPreferences> _prefsFuture;

  static AdRewardState? _instance;

  /// 사용하기 쉬운 단일 진입점. 첫 호출 시 lazy init.
  static AdRewardState get instance {
    return _instance ??= AdRewardState._();
  }

  static SharedPreferences? _processPrefCache;
  static void primeForTest(SharedPreferences prefs) {
    _processPrefCache = prefs;
  }

  Future<SharedPreferences> _prefs() async {
    if (_processPrefCache != null) {
      return _processPrefCache!;
    }
    return _prefsFuture;
  }

  /// 보상 부여 (requestId 중복 시 무시).
  /// [ttl]을 명시하지 않으면 [defaultTtl] 적용.
  Future<void> grant({
    required String requestId,
    Duration ttl = defaultTtl,
  }) async {
    if (requestId.trim().isEmpty) {
      return;
    }
    final prefs = await _prefs();
    final existing = prefs.getString(_kRequestId);
    if (existing != null && existing.isNotEmpty) {
      // 이미 다른 requestId가 살아있다면 grant하지 않는다 (가장 최근 시도 우선).
      if (existing != requestId) {
        // 새 요청이면 만료 체크 후 덮어쓰기 (이전 만료 시)
        final existingGrantedAt = prefs.getInt(_kGrantedAtMs);
        if (existingGrantedAt != null) {
          final expiredAt =
              DateTime.fromMillisecondsSinceEpoch(existingGrantedAt)
                  .add(Duration(milliseconds: prefs.getInt(_kTtlMs) ?? 0));
          if (DateTime.now().isBefore(expiredAt)) {
            // 유효한 기존 보상이 살아있어 새로 덮어쓰지 않는다.
            return;
          }
        }
      } else {
        // 같은 requestId: 시간만 연장 (멱등).
        await prefs.setInt(
          _kGrantedAtMs,
          DateTime.now().millisecondsSinceEpoch,
        );
        await prefs.setInt(_kTtlMs, ttl.inMilliseconds);
        return;
      }
    }
    await prefs.setString(_kRequestId, requestId);
    await prefs.setInt(
      _kGrantedAtMs,
      DateTime.now().millisecondsSinceEpoch,
    );
    await prefs.setInt(_kTtlMs, ttl.inMilliseconds);
  }

  /// 현재 유효한 보상 requestId가 있으면 반환, 없거나 만료 시 null.
  Future<String?> consumeActiveRequestId() async {
    final prefs = await _prefs();
    final requestId = prefs.getString(_kRequestId);
    if (requestId == null || requestId.isEmpty) {
      return null;
    }
    final grantedAt = prefs.getInt(_kGrantedAtMs);
    final ttlMs = prefs.getInt(_kTtlMs) ?? defaultTtl.inMilliseconds;
    if (grantedAt == null) {
      return null;
    }
    final expiresAt =
        DateTime.fromMillisecondsSinceEpoch(grantedAt)
            .add(Duration(milliseconds: ttlMs));
    if (DateTime.now().isAfter(expiresAt)) {
      // 만료 → 정리
      await prefs.remove(_kRequestId);
      await prefs.remove(_kGrantedAtMs);
      await prefs.remove(_kTtlMs);
      return null;
    }
    return requestId;
  }

  /// 보상 사용 완료(또는 만료/포기) 후 상태 정리.
  Future<void> clear() async {
    final prefs = await _prefs();
    await prefs.remove(_kRequestId);
    await prefs.remove(_kGrantedAtMs);
    await prefs.remove(_kTtlMs);
  }

  /// 진단/테스트용. 만료 여부만 파악.
  Future<bool> isExpired() async {
    final prefs = await _prefs();
    final grantedAt = prefs.getInt(_kGrantedAtMs);
    if (grantedAt == null) {
      return true;
    }
    final ttlMs = prefs.getInt(_kTtlMs) ?? defaultTtl.inMilliseconds;
    final expiresAt =
        DateTime.fromMillisecondsSinceEpoch(grantedAt)
            .add(Duration(milliseconds: ttlMs));
    return DateTime.now().isAfter(expiresAt);
  }

  /// 동일 requestId가 이미 활성 보상으로 등록돼 있는지 (중복 grant 방지).
  Future<bool> isActiveGrantFor(String requestId) async {
    final active = await consumeActiveRequestId();
    return active == requestId;
  }

  /// SharedPreferences에 grant 정보가 남아있지만 만료되었는지 진단용.
  @visibleForTesting
  Future<Duration?> remainingTtl() async {
    final prefs = await _prefs();
    final grantedAt = prefs.getInt(_kGrantedAtMs);
    if (grantedAt == null) {
      return null;
    }
    final ttlMs = prefs.getInt(_kTtlMs) ?? defaultTtl.inMilliseconds;
    final expiresAt =
        DateTime.fromMillisecondsSinceEpoch(grantedAt)
            .add(Duration(milliseconds: ttlMs));
    final remaining = expiresAt.difference(DateTime.now());
    if (remaining.isNegative) {
      return Duration.zero;
    }
    return remaining;
  }
}
