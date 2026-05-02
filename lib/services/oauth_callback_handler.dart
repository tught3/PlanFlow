import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/constants.dart';
import '../core/env.dart';
import '../providers/auth_provider.dart';
import '../core/router.dart';

class OAuthCallbackHandler {
  OAuthCallbackHandler({AppLinks? appLinks})
      : _appLinks = appLinks ?? AppLinks();

  final AppLinks _appLinks;
  StreamSubscription<Uri>? _subscription;
  bool _initialLinkHandled = false;

  void start() {
    if (kIsWeb || !AppEnv.isSupabaseReady || _subscription != null) {
      return;
    }

    unawaited(_handleInitialLinkOnce());

    _subscription = _appLinks.uriLinkStream.listen(
      (uri) => unawaited(_handleUri(uri)),
      onError: (Object error, StackTrace stackTrace) {
        debugPrint('OAuth callback listener error: $error');
      },
    );
  }

  Future<void> _handleInitialLinkOnce() async {
    if (_initialLinkHandled) {
      return;
    }
    _initialLinkHandled = true;

    try {
      final uri = await _appLinks.getInitialLink();
      if (uri != null) {
        await _handleUri(uri);
      }
    } catch (error, stackTrace) {
      debugPrint('OAuth initial callback read failed: $error');
      debugPrintStack(stackTrace: stackTrace);
    }
  }

  Future<void> _handleUri(Uri uri) async {
    if (!_isAuthCallback(uri)) {
      return;
    }

    debugPrint('OAuth callback observed: ${uri.replace(query: '<redacted>')}');

    final client = Supabase.instance.client;

    if (client.auth.currentSession != null) {
      debugPrint('OAuth callback already produced a Supabase session.');
      await _syncAndRouteHome();
      return;
    }

    try {
      final response = await client.auth.getSessionFromUrl(uri);
      debugPrint(
        'OAuth callback exchange completed: user=${response.session.user.id}',
      );
      await _syncAndRouteHome();
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

  Future<void> _syncAndRouteHome() async {
    final signedIn = await authProvider.syncCurrentSession();
    if (signedIn && !authProvider.isPasswordRecovery) {
      appRouter.go(AppRoutes.home);
    }
  }

  Future<void> dispose() async {
    await _subscription?.cancel();
    _subscription = null;
  }
}
