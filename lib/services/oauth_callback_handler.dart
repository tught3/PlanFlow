import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/constants.dart';
import '../core/env.dart';
import '../core/router.dart';
import '../providers/auth_provider.dart';

class OAuthCallbackHandler {
  OAuthCallbackHandler({AppLinks? appLinks})
      : _appLinks = appLinks ?? AppLinks();

  static final ValueNotifier<String?> latestUserMessage =
      ValueNotifier<String?>(null);

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

    latestUserMessage.value = null;
    final normalizedUri = _normalizeAuthCallbackUri(uri);
    debugPrint(
      'OAuth callback observed: host=${uri.host} '
      'queryKeys=${normalizedUri.queryParameters.keys.join(',')}',
    );

    final client = Supabase.instance.client;

    if (client.auth.currentSession != null) {
      debugPrint('OAuth callback already produced a Supabase session.');
      await _syncAndRouteHome();
      return;
    }

    try {
      final response = await client.auth.getSessionFromUrl(normalizedUri);
      debugPrint(
        'OAuth callback exchange completed: user=${response.session.user.id}',
      );
      await _syncAndRouteHome();
    } on AuthException catch (error) {
      debugPrint(
        'OAuth callback exchange failed: ${error.message} '
        'code=${error.code} status=${error.statusCode}',
      );
      latestUserMessage.value = _messageForAuthException(error);
    } catch (error) {
      debugPrint('OAuth callback exchange failed: $error');
      latestUserMessage.value = '소셜 로그인 세션을 확인하지 못했습니다. 잠시 후 다시 시도해 주세요.';
    }
  }

  String _messageForAuthException(AuthException error) {
    final message = error.message.toLowerCase();
    if (message.contains('getting user email')) {
      return '네이버 인증은 됐지만 이메일 정보를 받지 못해 로그인을 완료하지 못했습니다. '
          'Naver Developers에서 이메일 제공 항목을 필수로 켜거나, Supabase custom provider의 email_optional 설정을 켜 주세요.';
    }
    if (error.code == 'server_error' ||
        error.statusCode == 'unexpected_failure') {
      return '네이버 인증 처리 중 Supabase 오류가 발생했습니다. '
          'Naver Developers와 Supabase의 콜백/Provider 설정을 확인해 주세요.';
    }
    return '네이버 인증을 완료하지 못했습니다. Supabase/Naver 콜백 설정을 확인해 주세요.';
  }

  bool _isAuthCallback(Uri uri) {
    return uri.scheme == 'planflow' && uri.host == 'auth-callback';
  }

  Uri _normalizeAuthCallbackUri(Uri uri) {
    final fragmentParameters = Uri.splitQueryString(
      uri.fragment.startsWith('#') ? uri.fragment.substring(1) : uri.fragment,
    );
    if (fragmentParameters.isEmpty) {
      return uri;
    }

    return uri.replace(
      queryParameters: <String, String>{
        ...uri.queryParameters,
        ...fragmentParameters,
      },
      fragment: '',
    );
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
