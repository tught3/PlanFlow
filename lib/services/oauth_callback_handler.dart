import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/constants.dart';
import '../core/analytics_service.dart';
import '../core/env.dart';
import '../core/router.dart';
import '../providers/auth_provider.dart';
import 'auth_service.dart';
import 'naver_calendar_permission_service.dart';

enum OAuthCallbackPurpose {
  login,
  calendarLink,
}

class OAuthCallbackHandler {
  OAuthCallbackHandler({AppLinks? appLinks})
      : _appLinks = appLinks ?? AppLinks();

  static final ValueNotifier<String?> latestUserMessage =
      ValueNotifier<String?>(null);
  static OAuthCallbackPurpose? _pendingPurpose;
  static String? _pendingMethod;
  static DateTime? _pendingStartedAt;

  final AppLinks _appLinks;
  StreamSubscription<Uri>? _subscription;
  bool _initialLinkHandled = false;

  static void markPendingLogin(PlanFlowOAuthProvider provider) {
    clearLatestUserMessage();
    _pendingPurpose = OAuthCallbackPurpose.login;
    _pendingMethod = switch (provider) {
      PlanFlowOAuthProvider.google => 'google',
      PlanFlowOAuthProvider.kakao => 'kakao',
      PlanFlowOAuthProvider.naver => 'naver',
    };
    _pendingStartedAt = DateTime.now();
  }

  static void markPendingCalendarLink(PlanFlowOAuthProvider provider) {
    clearLatestUserMessage();
    _pendingPurpose = OAuthCallbackPurpose.calendarLink;
    _pendingMethod = switch (provider) {
      PlanFlowOAuthProvider.google => 'google',
      PlanFlowOAuthProvider.kakao => 'kakao',
      PlanFlowOAuthProvider.naver => 'naver',
    };
    _pendingStartedAt = DateTime.now();
  }

  static String? consumePendingLoginMethod() {
    final purpose = _pendingPurpose;
    final method = _pendingMethod;
    final startedAt = _pendingStartedAt;
    clearPendingCallback();
    if (purpose != OAuthCallbackPurpose.login ||
        method == null ||
        startedAt == null ||
        DateTime.now().difference(startedAt) > const Duration(minutes: 10)) {
      return null;
    }
    return method;
  }

  static void clearPendingCallback() {
    _pendingPurpose = null;
    _pendingMethod = null;
    _pendingStartedAt = null;
  }

  static void clearLatestUserMessage() {
    latestUserMessage.value = null;
  }

  static bool hasPendingLogin({
    Duration maxAge = const Duration(minutes: 10),
  }) {
    final startedAt = _pendingStartedAt;
    return _pendingPurpose == OAuthCallbackPurpose.login &&
        _pendingMethod != null &&
        startedAt != null &&
        DateTime.now().difference(startedAt) <= maxAge;
  }

  static String? get pendingLoginMethod {
    if (!hasPendingLogin()) {
      return null;
    }
    return _pendingMethod;
  }

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

  Future<void> handleAuthCallbackUri(Uri uri) {
    return _handleUri(uri);
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

    final callbackErrorMessage = _messageForCallbackError(normalizedUri);
    if (callbackErrorMessage != null) {
      debugPrint(
        'OAuth callback reported error: '
        'error=${normalizedUri.queryParameters['error']} '
        'errorCode=${normalizedUri.queryParameters['error_code']} '
        'description=${normalizedUri.queryParameters['error_description']}',
      );
      clearPendingCallback();
      latestUserMessage.value = callbackErrorMessage;
      return;
    }

    final client = Supabase.instance.client;

    if (client.auth.currentSession != null) {
      debugPrint('OAuth callback already produced a Supabase session.');
      final signedIn = await _syncAndRouteHome();
      if (signedIn) {
        await _logPendingLoginIfNeeded();
      } else {
        clearPendingCallback();
      }
      return;
    }

    try {
      final response = await client.auth.getSessionFromUrl(normalizedUri);
      debugPrint(
        'OAuth callback exchange completed: user=${response.session.user.id}',
      );
      unawaited(
        NaverCalendarPermissionService().captureCurrentProviderToken(),
      );
      final signedIn = await _syncAndRouteHome();
      if (signedIn) {
        await _logPendingLoginIfNeeded();
      } else {
        clearPendingCallback();
      }
    } on AuthException catch (error) {
      debugPrint(
        'OAuth callback exchange failed: ${error.message} '
        'code=${error.code} status=${error.statusCode}',
      );
      clearPendingCallback();
      latestUserMessage.value = _messageForAuthException(error);
    } catch (error) {
      debugPrint('OAuth callback exchange failed: $error');
      clearPendingCallback();
      latestUserMessage.value = '로그인 세션을 확인하지 못했습니다. 잠시 후 다시 시도해 주세요.';
    }
  }

  String? _messageForCallbackError(Uri uri) {
    final error = uri.queryParameters['error']?.toLowerCase().trim() ?? '';
    final errorCode =
        uri.queryParameters['error_code']?.toLowerCase().trim() ?? '';
    final description =
        uri.queryParameters['error_description']?.toLowerCase().trim() ?? '';

    if (error.isEmpty && errorCode.isEmpty && description.isEmpty) {
      return null;
    }

    final combined = '$error $errorCode $description';
    if (combined.contains('access_denied')) {
      final method = _pendingMethod == 'kakao'
          ? '카카오'
          : _pendingMethod == 'naver'
              ? '네이버'
              : '소셜';
      return '$method 동의 화면에서 권한을 취소했거나 필수 동의가 완료되지 않았습니다. 다시 시도해 주세요.';
    }
    if (combined.contains('manual_linking_disabled')) {
      return 'Supabase에서 Allow manual linking을 켜야 기존 계정에 소셜 로그인을 연결할 수 있습니다.';
    }
    if (combined.contains('bad_oauth_callback') || combined.contains('state')) {
      return '인증 콜백이 올바르지 않아 로그인을 완료하지 못했습니다. Supabase Redirect URL 설정을 확인해 주세요.';
    }
    if (combined.contains('identity_already_exists')) {
      return '이 소셜 계정은 이미 다른 PlanFlow 계정에 연결되어 있습니다. 해당 계정으로 로그인하거나 기존 연결을 정리한 뒤 다시 시도해 주세요.';
    }
    if (combined.contains('provider_email_needs_verification') ||
        combined.contains('getting user email')) {
      return '소셜 로그인에서 이메일 정보를 확인하지 못했습니다. Kakao/Naver 동의항목과 Supabase provider 설정을 확인해 주세요.';
    }

    return '소셜 인증을 완료하지 못했습니다. Supabase와 provider 콜백 설정을 확인해 주세요.';
  }

  String _messageForAuthException(AuthException error) {
    final message = error.message.toLowerCase();
    if (message.contains('identity_already_exists')) {
      return '이 소셜 계정은 이미 다른 PlanFlow 계정에 연결되어 있습니다. 기존 연결을 정리하거나 같은 소셜 계정으로 로그인해 주세요.';
    }
    if (message.contains('getting user email')) {
      return '소셜 인증은 되었지만 이메일 정보를 받지 못해 로그인을 완료하지 못했습니다. Kakao/Naver 동의항목과 Supabase provider 설정을 확인해 주세요.';
    }
    if (message.contains('missing provider id') ||
        message.contains('missing_provider_id')) {
      return '네이버 인증은 됐지만 Supabase가 네이버 사용자 ID를 읽지 못했습니다. '
          'Supabase Naver provider의 Userinfo URL을 naver-userinfo-proxy Edge Function으로 바꿔 주세요.';
    }
    if (error.code == 'server_error' ||
        error.statusCode == 'unexpected_failure') {
      return '소셜 인증 처리 중 Supabase 오류가 발생했습니다. Provider 콜백과 동의항목 설정을 확인해 주세요.';
    }
    return '소셜 인증을 완료하지 못했습니다. Supabase와 provider 콜백 설정을 확인해 주세요.';
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

  Future<bool> _syncAndRouteHome() async {
    final signedIn = await authProvider.syncCurrentSession();
    if (signedIn && !authProvider.isPasswordRecovery) {
      appRouter.go(AppRoutes.home);
    }
    return signedIn;
  }

  static Future<void> _logPendingLoginIfNeeded() async {
    final method = consumePendingLoginMethod();
    if (method != null) {
      await AnalyticsService.logLogin(method: method);
    }
  }

  Future<void> dispose() async {
    await _subscription?.cancel();
    _subscription = null;
  }
}
