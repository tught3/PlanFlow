import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

typedef GoogleAccessTokenProvider = Future<String?> Function();

class GoogleCalendarPermissionService {
  GoogleCalendarPermissionService({
    SupabaseClient? supabaseClient,
    GoogleAccessTokenProvider? accessTokenProvider,
  })  : _supabaseClient = supabaseClient,
        _accessTokenProvider = accessTokenProvider;

  final SupabaseClient? _supabaseClient;
  final GoogleAccessTokenProvider? _accessTokenProvider;

  Future<void> clearStoredToken() async {
    final client = _clientOrNull;
    final userId = client?.auth.currentUser?.id;
    if (client == null || userId == null || userId.trim().isEmpty) {
      return;
    }

    try {
      await client.from('user_settings').upsert(
        <String, dynamic>{
          'user_id': userId,
          'google_calendar_token': null,
        },
        onConflict: 'user_id',
      );
    } catch (error, stackTrace) {
      debugPrint('Google calendar token clear skipped: $error');
      debugPrintStack(stackTrace: stackTrace);
    }
  }

  Future<void> clearConnectionState() async {
    await clearStoredToken();
  }

  Future<bool> captureCurrentProviderToken() {
    return _persistCurrentProviderToken();
  }

  Future<String?> resolveAccessTokenForCalendar() {
    return _resolveAccessToken();
  }

  bool isGoogleSignedIn() {
    final user = _clientOrNull?.auth.currentUser;
    final appProvider = user?.appMetadata['provider']?.toString() ?? '';
    if (appProvider.toLowerCase().contains('google')) {
      return true;
    }

    final identities = user?.identities ?? const <UserIdentity>[];
    return identities.any((identity) {
      final provider = identity.provider.toLowerCase();
      return provider == 'google';
    });
  }

  Future<String?> _resolveAccessToken() async {
    final provider = _accessTokenProvider;
    if (provider != null) {
      return provider();
    }

    final providerToken = _currentProviderToken();
    if (providerToken != null && providerToken.trim().isNotEmpty) {
      return providerToken;
    }

    return _storedGoogleCalendarToken();
  }

  String? _currentProviderToken() {
    return _clientOrNull?.auth.currentSession?.providerToken;
  }

  Future<String?> _storedGoogleCalendarToken() async {
    final client = _clientOrNull;
    final userId = client?.auth.currentUser?.id;
    if (client == null || userId == null || userId.trim().isEmpty) {
      return null;
    }

    try {
      final row = await client
          .from('user_settings')
          .select('google_calendar_token')
          .eq('user_id', userId)
          .maybeSingle();
      if (row == null) {
        return null;
      }
      return row['google_calendar_token']?.toString();
    } catch (error, stackTrace) {
      debugPrint('Stored Google calendar token lookup failed: $error');
      debugPrintStack(stackTrace: stackTrace);
      return null;
    }
  }

  Future<bool> _persistCurrentProviderToken() async {
    final token = _currentProviderToken();
    final client = _clientOrNull;
    final userId = client?.auth.currentUser?.id;
    if (client == null ||
        userId == null ||
        userId.trim().isEmpty ||
        !isGoogleSignedIn() ||
        token == null ||
        token.trim().isEmpty) {
      return false;
    }

    try {
      await client.from('user_settings').upsert(
        <String, dynamic>{
          'user_id': userId,
          'google_calendar_token': token,
        },
        onConflict: 'user_id',
      );
      debugPrint('Google calendar provider token captured.');
      return true;
    } catch (error, stackTrace) {
      debugPrint('Google calendar token persistence skipped: $error');
      debugPrintStack(stackTrace: stackTrace);
      return false;
    }
  }

  SupabaseClient? get _clientOrNull {
    if (_supabaseClient != null) {
      return _supabaseClient;
    }

    try {
      return Supabase.instance.client;
    } catch (_) {
      return null;
    }
  }
}
