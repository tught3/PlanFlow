import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/calendar_connection_model.dart';

abstract class CalendarConnectionRepository {
  const CalendarConnectionRepository();

  factory CalendarConnectionRepository.supabase({SupabaseClient? client}) =
      SupabaseCalendarConnectionRepository;

  Future<CalendarConnectionModel?> fetchConnection({
    required String userId,
    required String provider,
  });

  Future<CalendarConnectionModel> upsertConnection(
    CalendarConnectionModel connection,
  );

  Future<void> markDisconnected({
    required String userId,
    required String provider,
    String? lastError,
  });

  Future<void> deleteConnection({
    required String userId,
    required String provider,
  });
}

class SupabaseCalendarConnectionRepository
    extends CalendarConnectionRepository {
  SupabaseCalendarConnectionRepository({SupabaseClient? client})
      : _client = client ?? Supabase.instance.client;

  static const String _tableName = 'calendar_connections';
  static const String _selectColumns =
      'id, user_id, provider, provider_account_email, status, access_token, '
      'refresh_token, last_synced_at, last_error, created_at, updated_at';

  final SupabaseClient _client;

  @override
  Future<CalendarConnectionModel?> fetchConnection({
    required String userId,
    required String provider,
  }) async {
    final response = await _client
        .from(_tableName)
        .select(_selectColumns)
        .eq('user_id', userId)
        .eq('provider', provider)
        .maybeSingle();

    if (response == null) {
      return null;
    }
    return CalendarConnectionModel.fromJson(
        Map<String, dynamic>.from(response));
  }

  @override
  Future<CalendarConnectionModel> upsertConnection(
    CalendarConnectionModel connection,
  ) async {
    _validateUser(connection.userId);
    final response = await _client
        .from(_tableName)
        .upsert(
          connection.toJson(includeId: connection.id != null),
          onConflict: 'user_id,provider',
        )
        .select(_selectColumns)
        .single();

    return CalendarConnectionModel.fromJson(
        Map<String, dynamic>.from(response));
  }

  @override
  Future<void> markDisconnected({
    required String userId,
    required String provider,
    String? lastError,
  }) async {
    _validateUser(userId);
    await upsertConnection(
      CalendarConnectionModel(
        userId: userId,
        provider: provider,
        status: CalendarConnectionStatus.disconnected,
        lastError: lastError,
      ),
    );
  }

  @override
  Future<void> deleteConnection({
    required String userId,
    required String provider,
  }) async {
    _validateUser(userId);
    await _client
        .from(_tableName)
        .delete()
        .eq('user_id', userId)
        .eq('provider', provider);
  }

  void _validateUser(String userId) {
    final currentUserId =
        _client.auth.currentSession?.user.id ?? _client.auth.currentUser?.id;
    if (currentUserId != null &&
        currentUserId.isNotEmpty &&
        currentUserId != userId) {
      throw StateError(
        'Calendar connection userId must match the signed-in user.',
      );
    }
  }
}
