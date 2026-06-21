import 'package:flutter/services.dart';

/// 릴리즈 빌드에서 앱 내부에 진단 로그를 저장하는 싱글톤.
/// LogCat/ADB 없이 클립보드로 로그를 추출할 수 있게 한다.
class DiagLogger {
  DiagLogger._();

  static final List<String> _entries = [];
  static const int _maxEntries = 200;

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
  }

  static String dump() {
    if (_entries.isEmpty) {
      return '(진단 로그 없음)';
    }
    return _entries.join('\n');
  }

  static void clear() => _entries.clear();

  static Future<void> copyToClipboard() async {
    await Clipboard.setData(ClipboardData(text: dump()));
  }

  static int get entryCount => _entries.length;
}
