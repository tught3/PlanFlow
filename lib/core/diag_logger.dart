import 'dart:async';

import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 릴리즈 빌드에서 앱 내부에 진단 로그를 저장하는 싱글톤.
/// LogCat/ADB 없이 클립보드로 로그를 추출할 수 있게 한다.
///
/// [_entries]는 프로세스 로컬 in-memory 리스트라 브리핑/출발 알람처럼
/// 별도 isolate(android_alarm_manager_plus의 백그라운드 콜백)에서 남긴
/// 로그가 포그라운드 UI의 "진단 로그 보기"에서 보이지 않는 문제가 있었다
/// (알람이 안 울려도 실패 원인을 로그로 확인할 방법이 없었음). [log]가
/// SharedPreferences에도 fire-and-forget으로 영속화하므로, 어느 isolate가
/// 남긴 로그든 [dumpPersisted]로 합쳐서 확인할 수 있다.
class DiagLogger {
  DiagLogger._();

  static final List<String> _entries = [];
  static const int _maxEntries = 200;
  static const String _prefsKey = 'diag_logger:entries';

  static void log(String tag, String message) {
    final now = DateTime.now();
    final ts =
        '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}';
    final entry = '[$ts][$tag] $message';
    _entries.add(entry);
    if (_entries.length > _maxEntries) {
      _entries.removeAt(0);
    }
    // ignore: avoid_print — 진단 로그는 릴리즈 logcat에도 출력
    print(entry);
    unawaited(_persist(entry));
  }

  static Future<void> _persist(String entry) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final stored = prefs.getStringList(_prefsKey) ?? <String>[];
      stored.add(entry);
      final trimmed = stored.length > _maxEntries
          ? stored.sublist(stored.length - _maxEntries)
          : stored;
      await prefs.setStringList(_prefsKey, trimmed);
    } catch (error) {
      // 진단 로그 자체의 저장 실패는 조용히 넘어간다(로그를 위한 로그 금지).
      // ignore: avoid_print
      print('[DiagLogger] persist 실패: $error');
    }
  }

  /// 현재 프로세스(isolate)의 in-memory 로그만 반환한다. 백그라운드 알람
  /// 콜백처럼 다른 isolate가 남긴 로그는 포함되지 않는다 — 그게 필요하면
  /// [dumpPersisted]를 쓴다.
  static String dump() {
    if (_entries.isEmpty) {
      return '(진단 로그 없음)';
    }
    return _entries.join('\n');
  }

  /// SharedPreferences에 영속화된 로그를 반환한다. 백그라운드 알람 콜백 등
  /// 다른 isolate가 남긴 로그까지 포함하므로, "왜 알람이 안 울렸는지" 같은
  /// 진단에는 이 메서드를 써야 한다.
  static Future<String> dumpPersisted() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final stored = prefs.getStringList(_prefsKey) ?? <String>[];
      if (stored.isEmpty) {
        return dump();
      }
      return stored.join('\n');
    } catch (_) {
      return dump();
    }
  }

  static void clear() => _entries.clear();

  static Future<void> clearPersisted() async {
    _entries.clear();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_prefsKey);
    } catch (_) {
      // 무시 — 다음 log() 호출에서 다시 시도된다.
    }
  }

  static Future<void> copyToClipboard() async {
    final text = await dumpPersisted();
    await Clipboard.setData(ClipboardData(text: text));
  }

  static int get entryCount => _entries.length;
}
