import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/env.dart';

class NaverCalDavRemoteStore {
  const NaverCalDavRemoteStore({SupabaseClient? client}) : _client = client;

  final SupabaseClient? _client;

  SupabaseClient? get _resolvedClient {
    final client = _client;
    if (client != null) {
      return client;
    }
    if (!AppEnv.isSupabaseReady) {
      return null;
    }
    try {
      return Supabase.instance.client;
    } catch (error, stackTrace) {
      debugPrint('Naver CalDAV remote store unavailable: $error');
      debugPrintStack(stackTrace: stackTrace);
      return null;
    }
  }

  String? get _userId {
    final user = _resolvedClient?.auth.currentUser;
    final userId = user?.id.trim();
    return userId == null || userId.isEmpty ? null : userId;
  }

  Future<void> save({
    required String naverId,
    required String appPassword,
  }) async {
    final client = _resolvedClient;
    final userId = _userId;
    if (client == null || userId == null) {
      return;
    }

    await client.from('user_settings').upsert(
      <String, dynamic>{
        'user_id': userId,
        'naver_caldav_id': naverId,
        'naver_caldav_app_password': appPassword,
      },
      onConflict: 'user_id',
    );
  }

  Future<({String naverId, String appPassword})?> read() async {
    final client = _resolvedClient;
    final userId = _userId;
    if (client == null || userId == null) {
      return null;
    }

    final row = await client
        .from('user_settings')
        .select('naver_caldav_id, naver_caldav_app_password')
        .eq('user_id', userId)
        .maybeSingle();
    if (row == null) {
      return null;
    }

    final naverId = row['naver_caldav_id']?.toString().trim() ?? '';
    final appPassword =
        row['naver_caldav_app_password']?.toString().trim() ?? '';
    if (naverId.isEmpty || appPassword.isEmpty) {
      return null;
    }
    return (naverId: naverId, appPassword: appPassword);
  }

  Future<void> clear() async {
    final client = _resolvedClient;
    final userId = _userId;
    if (client == null || userId == null) {
      return;
    }

    await client.from('user_settings').update(
      <String, dynamic>{
        'naver_caldav_id': null,
        'naver_caldav_app_password': null,
      },
    ).eq('user_id', userId);
  }
}
