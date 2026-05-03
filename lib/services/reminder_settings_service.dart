import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/env.dart';

class ReminderSettingsService {
  const ReminderSettingsService({SupabaseClient? client})
      : _client = client;

  static const int fallbackMinutes = 60;

  final SupabaseClient? _client;

  SupabaseClient get _resolvedClient =>
      _client ?? Supabase.instance.client;

  Future<int> resolveDefaultReminderMinutes({String? userId}) async {
    final resolvedUserId = userId?.trim();
    if (!AppEnv.isSupabaseReady ||
        resolvedUserId == null ||
        resolvedUserId.isEmpty) {
      return fallbackMinutes;
    }

    try {
      final response = await _resolvedClient
          .from('user_settings')
          .select('default_reminder_min')
          .eq('user_id', resolvedUserId)
          .maybeSingle();
      final value = response?['default_reminder_min'];
      final parsed = value is int ? value : int.tryParse(value?.toString() ?? '');
      if (parsed == null || parsed <= 0) {
        return fallbackMinutes;
      }
      return parsed;
    } catch (_) {
      return fallbackMinutes;
    }
  }

  Future<Duration> resolveDefaultReminderOffset({String? userId}) async {
    final minutes = await resolveDefaultReminderMinutes(userId: userId);
    return Duration(minutes: minutes);
  }
}
