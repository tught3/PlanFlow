import 'package:shared_preferences/shared_preferences.dart';

import '../core/safe_prefs.dart';

/// 출발 전용 알람으로 설정한 대기 중인 일정 정보
class PendingDeparture {
  const PendingDeparture({
    required this.eventId,
    required this.title,
    required this.fireAt,
  });

  final String eventId;
  final String title;
  final DateTime fireAt;
}

/// 출발 전용 알람이 활성화된 동안 보류 중인 일정 정보를 저장/로드하는 저장소.
///
/// 앱이 알람 화면 밖으로 나갔을 때 상태를 보존해 알람 서비스가 배경에서
/// 나중에 실행할 수 있도록 한다. 단일 슬롯(최근 1건만 저장).
abstract class PendingDepartureStore {
  const PendingDepartureStore();

  /// 보류 중인 출발 일정을 저장한다.
  /// eventId가 공백이면 무시한다.
  Future<void> write(PendingDeparture pending);

  /// 저장된 보류 일정을 읽는다. 저장된 것이 없거나 손상되었으면 null.
  Future<PendingDeparture?> read();

  /// 저장된 보류 일정을 삭제한다.
  Future<void> clear();
}

class SharedPreferencesPendingDepartureStore extends PendingDepartureStore {
  const SharedPreferencesPendingDepartureStore();

  static const String _keyEventId = 'departure_alarm:pending:event_id';
  static const String _keyTitle = 'departure_alarm:pending:title';
  static const String _keyFireAt = 'departure_alarm:pending:fire_at';

  Future<SharedPreferences?> _prefs() async {
    return tryGetPrefs();
  }

  @override
  Future<void> write(PendingDeparture pending) async {
    final normalizedEventId = pending.eventId.trim();
    if (normalizedEventId.isEmpty) {
      return;
    }
    final prefs = await _prefs();
    if (prefs == null) {
      return;
    }
    await prefs.setString(_keyEventId, normalizedEventId);
    await prefs.setString(_keyTitle, pending.title);
    await prefs.setString(
      _keyFireAt,
      pending.fireAt.toIso8601String(),
    );
  }

  @override
  Future<PendingDeparture?> read() async {
    final prefs = await _prefs();
    if (prefs == null) {
      return null;
    }

    final eventId = prefs.getString(_keyEventId)?.trim();
    final title = prefs.getString(_keyTitle);
    final fireAtStr = prefs.getString(_keyFireAt);

    if (eventId == null || eventId.isEmpty || title == null || fireAtStr == null) {
      return null;
    }

    try {
      final fireAt = DateTime.parse(fireAtStr);
      return PendingDeparture(
        eventId: eventId,
        title: title,
        fireAt: fireAt,
      );
    } catch (_) {
      // 파싱 실패면 null
      return null;
    }
  }

  @override
  Future<void> clear() async {
    final prefs = await _prefs();
    if (prefs == null) {
      return;
    }
    await prefs.remove(_keyEventId);
    await prefs.remove(_keyTitle);
    await prefs.remove(_keyFireAt);
  }
}
