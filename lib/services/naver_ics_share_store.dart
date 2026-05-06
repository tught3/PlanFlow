import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

class NaverIcsShareStore {
  const NaverIcsShareStore();

  static const String _pendingPathsKey = 'naver_ics_pending_paths';

  Future<void> savePendingPaths(List<String> paths) async {
    final normalized = paths
        .map((path) => path.trim())
        .where((path) => path.isNotEmpty)
        .toSet()
        .toList(growable: false);
    if (normalized.isEmpty) {
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_pendingPathsKey, jsonEncode(normalized));
  }

  Future<List<String>> takePendingPaths() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_pendingPathsKey);
    if (raw == null || raw.isEmpty) {
      return const <String>[];
    }
    await prefs.remove(_pendingPathsKey);
    final decoded = jsonDecode(raw);
    if (decoded is! List) {
      return const <String>[];
    }
    return decoded
        .map((item) => item.toString())
        .where((path) => path.trim().isNotEmpty)
        .toList(growable: false);
  }
}
