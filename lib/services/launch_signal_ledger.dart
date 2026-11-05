import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/diag_logger.dart';
import '../core/safe_prefs.dart';

/// Small persistent history of launch signals. It never persists shared paths.
class LaunchSignalLedger {
  LaunchSignalLedger({
    Future<SharedPreferences?> Function()? prefsLoader,
    DateTime Function()? now,
  })  : _prefsLoader = prefsLoader ?? tryGetPrefs,
        _now = now ?? DateTime.now;

  // banned-ok: local SharedPreferences key name; it is not a credential or secret.
  static const _tokenKey = 'launch_ledger:naver_ics_reminder:last_token';
  static const _sharesKey = 'launch_ledger:ics_share:keys';
  static const _headLimit = 1024 * 1024;
  final Future<SharedPreferences?> Function() _prefsLoader;
  final DateTime Function() _now;

  Future<String?> lastNaverReminderToken() async {
    try {
      final prefs = await _prefsLoader();
      if (prefs == null) {
        _unavailable('read-token');
        return null;
      }
      return prefs.getString(_tokenKey);
    } catch (_) {
      _unavailable('read-token');
      return null;
    }
  }

  Future<void> markNaverReminderToken(String token) async {
    try {
      final prefs = await _prefsLoader();
      if (prefs == null || !await prefs.setString(_tokenKey, token)) {
        _unavailable('write-token');
      }
    } catch (_) {
      _unavailable('write-token');
    }
  }

  Future<bool> hasShareKey(String key) async {
    try {
      final prefs = await _prefsLoader();
      if (prefs == null) {
        _unavailable('read-share');
        return false;
      }
      return _readShares(prefs).any((entry) => entry.$1 == key);
    } catch (_) {
      _unavailable('read-share');
      return false;
    }
  }

  Future<void> recordShareKey(String key) async {
    if (key.isEmpty) return;
    try {
      final prefs = await _prefsLoader();
      if (prefs == null) {
        _unavailable('write-share');
        return;
      }
      final entries = _readShares(prefs)
        ..removeWhere((entry) => entry.$1 == key)
        ..add((key, _now().toUtc()));
      final recent =
          entries.skip(entries.length > 20 ? entries.length - 20 : 0);
      final saved = await prefs.setString(
        _sharesKey,
        jsonEncode([
          for (final entry in recent)
            {'k': entry.$1, 't': entry.$2.toIso8601String()},
        ]),
      );
      if (!saved) _unavailable('write-share');
    } catch (_) {
      _unavailable('write-share');
    }
  }

  List<(String, DateTime)> _readShares(SharedPreferences prefs) {
    final raw = prefs.getString(_sharesKey);
    if (raw == null) return [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return [];
      final entries = <(String, DateTime)>[];
      for (final entry in decoded) {
        if (entry is! Map || entry['k'] is! String || entry['t'] is! String) {
          continue;
        }
        final key = entry['k'] as String;
        final time = DateTime.tryParse(entry['t'] as String);
        if (key.isEmpty ||
            time == null ||
            _now().difference(time) > const Duration(days: 90)) {
          continue;
        }
        entries.removeWhere((value) => value.$1 == key);
        entries.add((key, time));
      }
      return entries
          .skip(entries.length > 20 ? entries.length - 20 : 0)
          .toList();
    } catch (_) {
      _unavailable('decode-share');
      return [];
    }
  }

  static Future<String?> computeShareKey(
    List<String> paths, {
    Future<Uint8List?> Function(String path, int maxBytes)? readHead,
    Future<int?> Function(String path)? length,
  }) async {
    final normalized = paths
        .map((path) => path.trim())
        .where((path) => path.isNotEmpty)
        .toSet();
    if (normalized.isEmpty) return null;
    try {
      final descriptions = <String>[];
      for (final path in normalized) {
        final size = await (length ?? _fileLength)(path);
        if (size == null || size < 0) return null;
        final head = await (readHead ?? _readFileHead)(path, _headLimit);
        if (head == null) return null;
        final bounded = head.length > _headLimit
            ? Uint8List.sublistView(head, 0, _headLimit)
            : head;
        descriptions.add('$size\n${sha256.convert(bounded)}');
      }
      descriptions.sort();
      return sha256.convert(utf8.encode(descriptions.join('\n'))).toString();
    } catch (_) {
      _unavailable('hash-share');
      return null;
    }
  }

  static Future<int?> _fileLength(String path) => File(path).length();

  static Future<Uint8List?> _readFileHead(String path, int maxBytes) async {
    final file = await File(path).open();
    try {
      return await file.read(maxBytes);
    } finally {
      await file.close();
    }
  }

  static void _unavailable(String operation) {
    DiagLogger.log('LaunchSignal', 'ledger operation=$operation unavailable');
  }
}
