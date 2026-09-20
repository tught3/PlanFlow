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
  static const String _generationKey = 'diag_logger:generation';
  static const String _generationEntriesPrefix =
      'diag_logger:entries:generation:';
  // SharedPreferences 쓰기를 한 isolate 안에서 직렬화한다. log()는
  // fire-and-forget API를 유지하되, clearPersisted()가 앞선 비동기 쓰기보다
  // 먼저 remove를 실행해 이전 로그가 되살아나는 순서 역전을 막는다.
  static Future<void> _storageOperations = Future<void>.value();

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
    _enqueueStorageOperation(() => _persist(entry));
  }

  static void _enqueueStorageOperation(Future<void> Function() operation) {
    _storageOperations = _storageOperations.then<void>((_) => operation());
  }

  static Future<void> _persist(String entry) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      // Each isolate has its own SharedPreferences cache. Reload before
      // selecting the generation so a clear performed by another isolate is
      // visible here. A late write to an older generation is then ignored by
      // dumpPersisted instead of resurrecting cleared logs.
      await prefs.reload();
      final generation = prefs.getInt(_generationKey) ?? 0;
      final entriesKey = _generationEntriesKey(generation);
      final stored = prefs.getStringList(entriesKey) ?? <String>[];
      stored.add(entry);
      final trimmed = stored.length > _maxEntries
          ? stored.sublist(stored.length - _maxEntries)
          : stored;
      await prefs.setStringList(entriesKey, trimmed);
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
      await prefs.reload();
      final generation = prefs.getInt(_generationKey);
      final stored = generation == null
          ? prefs.getStringList(_generationEntriesKey(0)) ?? <String>[]
          : prefs.getStringList(_generationEntriesKey(generation)) ??
              <String>[];
      // Before the first clear, generation 0 and the pre-generation key are
      // both valid. Once a marker exists, legacy writes are ignored so a late
      // pre-clear write cannot reappear after clearPersisted().
      final legacy = generation == null
          ? prefs.getStringList(_prefsKey) ?? <String>[]
          : <String>[];
      final combined = <String>[...legacy, ...stored];
      if (combined.isEmpty) {
        return dump();
      }
      return combined.join('\n');
    } catch (_) {
      return dump();
    }
  }

  static void clear() => _entries.clear();

  static Future<void> clearPersisted() async {
    _entries.clear();
    final completion =
        _storageOperations = _storageOperations.then<void>((_) async {
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.reload();
        final currentGeneration = prefs.getInt(_generationKey) ?? 0;
        final nextGeneration = currentGeneration + 1;
        // Advance the marker before removing old keys. Any late writer from
        // an older isolate may still finish, but dumpPersisted will never
        // select its generation again.
        await prefs.setInt(_generationKey, nextGeneration);
        for (final key in prefs.getKeys()) {
          if (key == _prefsKey || key.startsWith(_generationEntriesPrefix)) {
            await prefs.remove(key);
          }
        }
      } catch (_) {
        // 무시 — 다음 log() 호출에서 다시 시도된다.
      }
    });
    await completion;
  }

  static String _generationEntriesKey(int generation) =>
      '$_generationEntriesPrefix$generation';

  static Future<void> copyToClipboard() async {
    final text = await dumpPersisted();
    await Clipboard.setData(ClipboardData(text: text));
  }

  static int get entryCount => _entries.length;
}
