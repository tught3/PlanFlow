import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/env.dart';

class OAuthCallbackHandler {
  OAuthCallbackHandler({AppLinks? appLinks})
      : _appLinks = appLinks ?? AppLinks();

  final AppLinks _appLinks;
  StreamSubscription<Uri>? _subscription;

  void start() {
    if (kIsWeb || !AppEnv.isSupabaseReady || _subscription != null) {
      return;
    }

    _subscription = _appLinks.uriLinkStream.listen(
      (uri) => unawaited(_handleUri(uri)),
      onError: (Object error, StackTrace stackTrace) {
        debugPrint('OAuth callback listener error: $error');
      },
    );
  }

  Future<void> _handleUri(Uri uri) async {
    if (!_isAuthCallback(uri)) {
      return;
    }

    debugPrint('OAuth callback observed: ${uri.replace(query: '<redacted>')}');

    final client = Supabase.instance.client;

    try {
      final response = await client.auth.getSessionFromUrl(uri);
      debugPrint(
        'OAuth callback exchange completed: user=${response.session.user.id} '
        'redirectType=${response.redirectType ?? '<none>'}',
      );
    } on AuthException catch (error) {
      debugPrint(
        'OAuth callback exchange failed: ${error.message} '
        'code=${error.code} status=${error.statusCode}',
      );
    } catch (error) {
      debugPrint('OAuth callback exchange failed: $error');
    }
  }

  bool _isAuthCallback(Uri uri) {
    return uri.scheme == 'planflow' &&
        uri.host == 'auth-callback' &&
        uri.queryParameters.containsKey('code');
  }

  Future<void> dispose() async {
    await _subscription?.cancel();
    _subscription = null;
  }
}
