import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/constants.dart';
import '../models/user_settings_model.dart';

abstract class SettingsRepository {
  const SettingsRepository();

  factory SettingsRepository.supabase({SupabaseClient? client}) =
      SupabaseSettingsRepository;

  Future<UserSettingsModel?> fetchSettings(String userId);

  Future<UserSettingsModel> upsertSettings(UserSettingsModel settings);

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

  static const String tableName = DbTable.userSettings;
  static const String selectColumns =
      'id, user_id, morning_briefing_at, evening_briefing_at, default_reminder_min, '
      'prep_time_min, prep_pre_alarm_offset, depart_pre_alarm_offset, '
      'travel_mode, voice_auto_start, preferred_map_provider, country_code, locale_code, time_zone_id, '
      'google_calendar_token, naver_calendar_token, created_at';
  static const String legacySelectColumns =
      'id, user_id, morning_briefing_at, evening_briefing_at, default_reminder_min, '
      'prep_time_min, prep_pre_alarm_offset, depart_pre_alarm_offset, '
      'travel_mode, voice_auto_start, google_calendar_token, naver_calendar_token, created_at';

  final SupabaseClient _client;

  @override
  Future<Map<String, dynamic>?> fetchSettings(String userId) async {
    try {
      final response = await _client
          .schema(DbSchema.planflow)
          .from(tableName)
          .select(selectColumns)
          .eq('user_id', userId)
          .maybeSingle();

      if (response == null) {
        return null;
      }

      return Map<String, dynamic>.from(response as Map);
    } on PostgrestException catch (error) {
      if (_isMissingRegionColumnError(error)) {
        return _fetchSettingsLegacy(userId);
      }
      if (_isMissingSmartSettingsColumnError(error)) {
        throw StateError(
          'Supabase user_settings 스키마에 스마트 준비 알람 설정 컬럼이 없습니다. '
          'supabase/schema.sql을 적용해 주세요.',
        );
      }
      rethrow;
    }
  }

  @override
  Future<Map<String, dynamic>> upsertSettings(
    Map<String, dynamic> payload,
  ) async {
    try {
      final response = await _client
          .schema(DbSchema.planflow)
          .from(tableName)
          .upsert(
            payload,
            onConflict: 'user_id',
          )
          .select(selectColumns)
          .single();
      return Map<String, dynamic>.from(response as Map);
    } on PostgrestException catch (error) {
      if (_isMissingRegionColumnError(error)) {
        return _upsertSettingsLegacy(payload);
      }
      if (_isMissingSmartSettingsColumnError(error)) {
        throw StateError(
          'Supabase user_settings 스키마에 스마트 준비 알람 설정 컬럼이 없습니다. '
          'supabase/schema.sql을 적용해 주세요.',
        );
      }
      rethrow;
    }
  }

  Future<Map<String, dynamic>?> _fetchSettingsLegacy(String userId) async {
    final response = await _client
        .schema(DbSchema.planflow)
        .from(tableName)
        .select(legacySelectColumns)
        .eq('user_id', userId)
        .maybeSingle();
    if (response == null) {
      return null;
    }
    return Map<String, dynamic>.from(response as Map);
  }

  Future<Map<String, dynamic>> _upsertSettingsLegacy(
    Map<String, dynamic> payload,
  ) async {
    final legacyPayload = Map<String, dynamic>.from(payload)
      ..remove('country_code')
      ..remove('locale_code')
      ..remove('time_zone_id');
    legacyPayload.remove('preferred_map_provider');
    final response = await _client
        .schema(DbSchema.planflow)
        .from(tableName)
        .upsert(
          legacyPayload,
          onConflict: 'user_id',
        )
        .select(legacySelectColumns)
        .single();
    return <String, dynamic>{
      ...Map<String, dynamic>.from(response as Map),
      'country_code': payload['country_code'],
      'locale_code': payload['locale_code'],
      'time_zone_id': payload['time_zone_id'],
      'preferred_map_provider': payload['preferred_map_provider'],
    };
  }

  bool _isMissingRegionColumnError(PostgrestException error) {
    final text =
        '${error.code} ${error.message} ${error.details}'.toLowerCase();
    return text.contains('country_code') ||
        text.contains('locale_code') ||
        text.contains('time_zone_id') ||
        text.contains('preferred_map_provider');
  }

  bool _isMissingSmartSettingsColumnError(PostgrestException error) {
    final text =
        '${error.code} ${error.message} ${error.details}'.toLowerCase();
    return text.contains('voice_auto_start') ||
        text.contains('prep_time_min') ||
        text.contains('prep_pre_alarm_offset') ||
        text.contains('depart_pre_alarm_offset') ||
        text.contains('schema cache') && text.contains('user_settings');
  }
}
