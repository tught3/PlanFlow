import 'package:shared_preferences/shared_preferences.dart';

import '../core/diag_logger.dart';
import '../core/safe_prefs.dart';

const naverIcsReminderPayloadPrefix = 'naver_ics_monthly_reminder';
const naverIcsLastImportAtKey = 'naver_ics:last_import_at';

DateTime? nextNaverIcsReminderAt({
  required DateTime now,
  DateTime? lastImportAt,
}) {
  if (lastImportAt == null) return null;
  final localNow = now.toLocal();
  final lastImport = lastImportAt.isAfter(now) ? now : lastImportAt;
  var candidate = DateTime(localNow.year, localNow.month, 1, 9);
  if (!candidate.isAfter(now)) {
    candidate = DateTime(localNow.year, localNow.month + 1, 1, 9);
  }
  while (candidate.difference(lastImport) < const Duration(days: 25)) {
    candidate = DateTime(candidate.year, candidate.month + 1, 1, 9);
  }
  return candidate;
}

String naverIcsReminderPayload(DateTime reminderAt) {
  final date = reminderAt.toLocal();
  final year = date.year.toString().padLeft(4, '0');
  final month = date.month.toString().padLeft(2, '0');
  final day = date.day.toString().padLeft(2, '0');
  return '$naverIcsReminderPayloadPrefix:$year-$month-$day';
}

enum NaverIcsReminderPayloadKind { notNaver, legacy, tokened, malformed }

NaverIcsReminderPayloadKind classifyNaverIcsReminderPayload(String? payload) {
  if (payload == naverIcsReminderPayloadPrefix) {
    return NaverIcsReminderPayloadKind.legacy;
  }
  if (payload == null || !payload.startsWith(naverIcsReminderPayloadPrefix)) {
    return NaverIcsReminderPayloadKind.notNaver;
  }
  return naverIcsReminderDateFromPayload(payload) == null
      ? NaverIcsReminderPayloadKind.malformed
      : NaverIcsReminderPayloadKind.tokened;
}

DateTime? naverIcsReminderDateFromPayload(String? payload) {
  if (payload == null) return null;
  final match = RegExp(
    '^$naverIcsReminderPayloadPrefix:([0-9]{4})-([0-9]{2})-([0-9]{2})\$',
  ).firstMatch(payload);
  if (match == null || match.end != payload.length) return null;
  final year = int.parse(match[1]!);
  final month = int.parse(match[2]!);
  final day = int.parse(match[3]!);
  final date = DateTime(year, month, day);
  return date.year == year && date.month == month && date.day == day
      ? date
      : null;
}

class NaverIcsImportHistoryStore {
  NaverIcsImportHistoryStore({
    Future<SharedPreferences?> Function()? prefsLoader,
    DateTime Function()? now,
  })  : _prefsLoader = prefsLoader ?? tryGetPrefs,
        _now = now ?? DateTime.now;

  final Future<SharedPreferences?> Function() _prefsLoader;
  final DateTime Function() _now;

  Future<DateTime?> lastImportAt() async {
    try {
      final prefs = await _prefsLoader();
      if (prefs == null) {
        DiagLogger.log(
            'LaunchSignal', 'ics-history operation=read unavailable');
        return null;
      }
      final value = prefs.getString(naverIcsLastImportAtKey);
      return value == null ? null : DateTime.tryParse(value);
    } catch (_) {
      DiagLogger.log('LaunchSignal', 'ics-history operation=read unavailable');
      return null;
    }
  }

  Future<void> recordImportNow() async {
    try {
      final prefs = await _prefsLoader();
      if (prefs == null ||
          !await prefs.setString(
            naverIcsLastImportAtKey,
            _now().toUtc().toIso8601String(),
          )) {
        DiagLogger.log(
            'LaunchSignal', 'ics-history operation=write unavailable');
      }
    } catch (_) {
      DiagLogger.log('LaunchSignal', 'ics-history operation=write unavailable');
    }
  }
}
