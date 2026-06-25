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
        '${now.year.toString().padLeft(4, '0')}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')} '
        '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}';
    final safeTag = maskTokens(tag);
    final safeMessage = maskTokens(message);
    final entry = '[$ts][$safeTag] $safeMessage';
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

  static String maskTokens(String value) {
    var masked = value;
    for (final pattern in _tokenPatterns) {
      masked = masked.replaceAllMapped(pattern, (match) {
        final prefix = match.group(1) ?? '';
        final token = match.group(2) ?? '';
        if (token.trim().isEmpty) {
          return match.group(0) ?? '';
        }
        return '$prefix[MASKED_TOKEN]';
      });
    }
    return masked;
  }

  static String describeToken(String? token) {
    final trimmed = token?.trim();
    if (trimmed == null) {
      return 'tokenPresent=false tokenState=null maskedToken=none';
    }
    if (trimmed.isEmpty) {
      return 'tokenPresent=false tokenState=empty maskedToken=none';
    }
    return 'tokenPresent=true tokenLength=${trimmed.length} '
        'maskedToken=${_maskSingleToken(trimmed)}';
  }

  static int get entryCount => _entries.length;

  static String _maskSingleToken(String token) {
    if (token.length <= 8) {
      return '${token[0]}***${token[token.length - 1]}';
    }
    return '${token.substring(0, 4)}...${token.substring(token.length - 4)}';
  }

  static final List<RegExp> _tokenPatterns = [
    RegExp(
      r'\b(bearer\s+)([A-Za-z0-9._~+/=-]{8,})',
      caseSensitive: false,
    ),
    RegExp(
      r'\b((?:(?:access|refresh|id|provider|calendar|auth)[_-]?)?token\s*[:=]\s*)([A-Za-z0-9._~+/=-]{8,})',
      caseSensitive: false,
    ),
    RegExp(
      r'''(["']?(?:access_token|refresh_token|id_token|provider_token|token)["']?\s*:\s*["']?)([^"',&\s]{8,})''',
      caseSensitive: false,
    ),
    RegExp(
      r'\b((?:auth[-_]?code|authCode|code|session|app[-_]?password|appPassword|password)\s*[:=]\s*)([A-Za-z0-9._~+/=-]{8,})',
      caseSensitive: false,
    ),
    RegExp(
      r'''(["']?(?:authCode|auth_code|code|session|appPassword|app_password|password)["']?\s*:\s*["']?)([^"',&\s]{8,})''',
      caseSensitive: false,
    ),
  ];
}
