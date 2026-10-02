import 'package:shared_preferences/shared_preferences.dart';

import '../core/safe_prefs.dart';

/// 알림 payload에는 시작 시각이 들어 있지 않다. `_persistCriticalAcknowledge`
/// 가 DB 조회에 실패한 경우 [unknownStartSentinel]을 저장해 "eventId 단위로만
/// acknowledged" 상태를 표현한다. [isAcknowledged]는 sentinel과 real startAt을
/// 비교하므로 sentinel 케이스에서는 false를 반환한다(real startAt ≠ sentinel).
/// 호출측은 [hasAcknowledgement]로 sentinel 존재를 확인해 재예약 여부를 결정한다.
final DateTime unknownStartSentinel = DateTime.utc(1969, 1, 1);

abstract class CriticalAlarmAcknowledgementStore {
  const CriticalAlarmAcknowledgementStore();

  Future<bool> isAcknowledged(String eventId, DateTime startAt);

  /// Sentinel(=[unknownStartSentinel])이 저장돼 있으면 true. "startAt을
  /// 모른 채로" ack된 일정의 재예약을 막기 위해 호출측에서 사용한다.
  /// 일반 [markAcknowledged]로 저장된 값은 여기서 false를 반환한다.
  Future<bool> hasUnknownStartAcknowledgement(String eventId);

  /// Sentinel을 포함한 어떤 값이라도 저장돼 있으면 true. 진단/캐시 정리 용도.
  Future<bool> hasAcknowledgement(String eventId);

  Future<void> markAcknowledged(String eventId, DateTime startAt);

  Future<void> clearAcknowledgement(String eventId);

  /// Sentinel(시작 시각 불명) ack를 이번에 확인된 실제 시작 시각으로 교체한다.
  /// 이후 시작 시각이 바뀌면 exact 매칭이 풀려 알람이 다시 예약된다.
  Future<void> adoptUnknownStart(String eventId, DateTime startAt) async {
    if (!await hasUnknownStartAcknowledgement(eventId)) return;
    await markAcknowledged(eventId, startAt);
  }
}

class SharedPreferencesCriticalAlarmAcknowledgementStore
    extends CriticalAlarmAcknowledgementStore {
  const SharedPreferencesCriticalAlarmAcknowledgementStore();

  static const String _prefix = 'critical_alarm:ack:';
  String _key(String id) => '$_prefix${id.trim()}';

  /// Local/UTC DateTime of the same instant must compare equal.
  /// `DateTime.toIso8601String()` keeps the timezone flag, so a UTC
  /// DateTime serializes with `Z` while a local DateTime omits it. Round-
  /// tripping any DateTime through `toUtc().toIso8601String()` guarantees a
  /// canonical form that compares equal across isolates / timezones.
  static String _normalize(DateTime startAt) =>
      startAt.toUtc().toIso8601String();

  /// Sentinel ISO used when ack 시점에 event의 startAt을 모를 때.
  /// 어떤 실제 startAt과도 매칭되지 않으므로 "아직 startAt을 모르는 상태"를
  /// 나타낸다.
  static String get sentinelIso => _normalize(unknownStartSentinel);

  Future<SharedPreferences?> _prefs() => tryGetPrefs();

  @override
  Future<bool> isAcknowledged(String eventId, DateTime startAt) async {
    if (eventId.trim().isEmpty) return false;
    final prefs = await _prefs();
    if (prefs == null) return false;
    final stored = prefs.getString(_key(eventId));
    if (stored == null) return false;
    return stored == _normalize(startAt);
  }

  @override
  Future<bool> hasUnknownStartAcknowledgement(String eventId) async {
    if (eventId.trim().isEmpty) return false;
    final prefs = await _prefs();
    if (prefs == null) return false;
    return prefs.getString(_key(eventId)) == sentinelIso;
  }

  @override
  Future<bool> hasAcknowledgement(String eventId) async {
    if (eventId.trim().isEmpty) return false;
    final prefs = await _prefs();
    if (prefs == null) return false;
    return prefs.getString(_key(eventId)) != null;
  }

  @override
  Future<void> markAcknowledged(String eventId, DateTime startAt) async {
    if (eventId.trim().isEmpty) return;
    final prefs = await _prefs();
    if (prefs == null) throw StateError('SharedPreferences unavailable');
    if (!await prefs.setString(_key(eventId), _normalize(startAt))) {
      throw StateError('Critical acknowledgement write failed');
    }
  }

  @override
  Future<void> clearAcknowledgement(String eventId) async {
    if (eventId.trim().isEmpty) return;
    final prefs = await _prefs();
    if (prefs == null) return;
    await prefs.remove(_key(eventId));
  }
}
