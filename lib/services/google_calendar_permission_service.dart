import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/diag_logger.dart';

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
      _logTokenDiag(
        'clearStoredToken skipped reason=${_skipReason(client, userId)}',
      );
      return;
    }

    try {
      _logTokenDiag('clearStoredToken upsert before token=null');
      await client.from('user_settings').upsert(
        <String, dynamic>{
          'user_id': userId,
          'google_calendar_token': null,
        },
        onConflict: 'user_id',
      );
      _logTokenDiag('clearStoredToken upsert after success');
    } catch (error, stackTrace) {
      _logTokenDiag('clearStoredToken exception ${_safeErrorText(error)}');
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
      _logTokenDiag('resolve source=injected before');
      try {
        final token = await provider();
        _logTokenDiag(
          'resolve source=injected result=${_tokenPresence(token)}',
        );
        return token;
      } catch (error) {
        _logTokenDiag(
            'resolve source=injected exception ${_safeErrorText(error)}');
        rethrow;
      }
    }

    final providerToken = _currentProviderToken();
    _logTokenDiag(
        'resolve source=current result=${_tokenPresence(providerToken)}');
    if (providerToken != null && providerToken.trim().isNotEmpty) {
      _logTokenDiag('resolve decision=use_current');
      return providerToken;
    }

    _logTokenDiag('resolve decision=load_stored');
    final storedToken = await _storedGoogleCalendarToken();
    _logTokenDiag(
        'resolve source=stored result=${_tokenPresence(storedToken)}');
    return storedToken;
  }

  String? _currentProviderToken() {
    return _clientOrNull?.auth.currentSession?.providerToken;
  }

  Future<String?> _storedGoogleCalendarToken() async {
    final client = _clientOrNull;
    final userId = client?.auth.currentUser?.id;
    if (client == null || userId == null || userId.trim().isEmpty) {
      _logTokenDiag(
        'loadStored skipped reason=${_skipReason(client, userId)}',
      );
      return null;
    }

    try {
      _logTokenDiag('loadStored select before');
      final row = await client
          .from('user_settings')
          .select('google_calendar_token')
          .eq('user_id', userId)
          .maybeSingle();
      if (row == null) {
        _logTokenDiag('loadStored row=null token=null');
        return null;
      }
      final token = row['google_calendar_token']?.toString();
      _logTokenDiag(
        'loadStored row=present token=${_tokenPresence(token)}',
      );
      return token;
    } catch (error, stackTrace) {
      _logTokenDiag('loadStored exception ${_safeErrorText(error)}');
      debugPrint('Stored Google calendar token lookup failed: $error');
      debugPrintStack(stackTrace: stackTrace);
      return null;
    }
  }

  Future<bool> _persistCurrentProviderToken() async {
    final token = _currentProviderToken();
    final client = _clientOrNull;
    final userId = client?.auth.currentUser?.id;
    final signedInWithGoogle = isGoogleSignedIn();
    _logTokenDiag(
      'capture current token=${_tokenPresence(token)} google=$signedInWithGoogle',
    );
    if (client == null ||
        userId == null ||
        userId.trim().isEmpty ||
        !signedInWithGoogle ||
        token == null ||
        token.trim().isEmpty) {
      _logTokenDiag(
        'persist skipped reason=${_persistSkipReason(
          client: client,
          userId: userId,
          signedInWithGoogle: signedInWithGoogle,
          token: token,
        )}',
      );
      return false;
    }

    try {
      _logTokenDiag('persist upsert before token=present');
      await client.from('user_settings').upsert(
        <String, dynamic>{
          'user_id': userId,
          'google_calendar_token': token,
        },
        onConflict: 'user_id',
      );
      _logTokenDiag('persist upsert after success');
      debugPrint('Google calendar provider token captured.');
      return true;
    } catch (error, stackTrace) {
      _logTokenDiag('persist exception ${_safeErrorText(error)}');
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

  static void _logTokenDiag(String message) {
    DiagLogger.log('GOOGLE_TOKEN', message);
  }

  static String _tokenPresence(String? token) {
    if (token == null) {
      return 'null';
    }
    if (token.trim().isEmpty) {
      return 'empty';
    }
    return 'present';
  }

  static String _skipReason(SupabaseClient? client, String? userId) {
    if (client == null) {
      return 'client_null';
    }
    if (userId == null) {
      return 'user_null';
    }
    if (userId.trim().isEmpty) {
      return 'user_empty';
    }
    return 'none';
  }

  static String _persistSkipReason({
    required SupabaseClient? client,
    required String? userId,
    required bool signedInWithGoogle,
    required String? token,
  }) {
    final baseReason = _skipReason(client, userId);
    if (baseReason != 'none') {
      return baseReason;
    }
    if (!signedInWithGoogle) {
      return 'not_google';
    }
    if (token == null) {
      return 'token_null';
    }
    if (token.trim().isEmpty) {
      return 'token_empty';
    }
    return 'none';
  }

  static String _safeErrorText(Object error) {
    final rawText = error.toString();
    final redacted = rawText
        .replaceAll(
          RegExp(r'eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+'),
          '[redacted-jwt]',
        )
        .replaceAllMapped(
          RegExp(
            r'(bearer|token|access_token)=?[ :]+[A-Za-z0-9._~+/=\-]{12,}',
            caseSensitive: false,
          ),
          (match) => '${match.group(1)}=[redacted]',
        )
        .replaceAll(
          RegExp(r'[A-Za-z0-9._~+/=\-]{48,}'),
          '[redacted-long-value]',
        );
    final compact = redacted.replaceAll(RegExp(r'\s+'), ' ').trim();
    final text =
        compact.length > 160 ? '${compact.substring(0, 160)}...' : compact;
    return 'type=${error.runtimeType} text=$text';
  }
}
