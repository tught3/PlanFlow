import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/user_settings_model.dart';

abstract class SettingsRepository {
  const SettingsRepository();

  factory SettingsRepository.supabase({SupabaseClient? client}) =
      SupabaseSettingsRepository;

  Future<UserSettingsModel?> fetchSettings(String userId);

  Future<UserSettingsModel> upsertSettings(UserSettingsModel settings);

  @Deprecated('Use upsertSettings instead.')
  Future<UserSettingsModel> saveSettings(UserSettingsModel settings) {
    return upsertSettings(settings);
  }
}

abstract class SettingsGateway {
  Future<Map<String, dynamic>?> fetchSettings(String userId);

  Future<Map<String, dynamic>> upsertSettings(Map<String, dynamic> payload);
}

class SupabaseSettingsRepository extends SettingsRepository {
  SupabaseSettingsRepository({
    SupabaseClient? client,
    SettingsGateway? gateway,
  }) : _gateway = gateway ??
            SupabaseSettingsGateway(client: client ?? Supabase.instance.client);

  final SettingsGateway _gateway;

  @override
  Future<UserSettingsModel?> fetchSettings(String userId) async {
    final normalizedUserId = _normalizeUserId(userId);
    final row = await _gateway.fetchSettings(normalizedUserId);
    if (row == null) {
      return null;
    }

    return UserSettingsModel.fromJson(row);
  }

  @override
  Future<UserSettingsModel> upsertSettings(UserSettingsModel settings) async {
    final normalizedUserId = _normalizeUserId(settings.userId);
    if (settings.userId != normalizedUserId) {
      throw StateError('Settings userId must match the signed-in user.');
    }

    final savedRow = await _gateway.upsertSettings(
      settings.toJson(includeId: settings.id.trim().isNotEmpty),
    );
    return UserSettingsModel.fromJson(savedRow);
  }

  String _normalizeUserId(String userId) {
    final normalized = userId.trim();
    if (normalized.isEmpty) {
      throw StateError('A signed-in user is required for settings access.');
    }
    return normalized;
  }
}

class SupabaseSettingsGateway implements SettingsGateway {
  SupabaseSettingsGateway({required SupabaseClient client}) : _client = client;

  static const String tableName = 'user_settings';
  static const String selectColumns =
      'id, user_id, morning_briefing_at, evening_briefing_at, default_reminder_min, google_calendar_token, naver_calendar_token, created_at';

  final SupabaseClient _client;

  @override
  Future<Map<String, dynamic>?> fetchSettings(String userId) async {
    final response = await _client
        .from(tableName)
        .select(selectColumns)
        .eq('user_id', userId)
        .maybeSingle();

    if (response == null) {
      return null;
    }

    return Map<String, dynamic>.from(response as Map);
  }

  @override
  Future<Map<String, dynamic>> upsertSettings(
    Map<String, dynamic> payload,
  ) async {
    final response = await _client
        .from(tableName)
        .upsert(
          payload,
          onConflict: 'user_id',
        )
        .select(selectColumns)
        .single();

    return Map<String, dynamic>.from(response as Map);
  }
}
