import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/env.dart';
import '../core/log_text.dart';
import '../core/supabase_auth_options.dart';
import 'activity_tracking_service.dart';
import 'oauth_callback_handler.dart';

/// iOS 네이티브 Apple 로그인에서 사용자가 시트를 취소한 경우.
/// UI에서는 일반 실패가 아니라 조용히 로딩만 해제해야 한다.
class AppleSignInCanceledException implements Exception {
  const AppleSignInCanceledException();
}

enum PlanFlowOAuthProvider {
  google,
  kakao,
  naver,
  apple,
}

abstract class AuthSessionClient {
  Session? get currentSession;
  User? get currentUser;
  Stream<AuthState> get authStateChanges;
  Future<void> refreshSession();
  Future<void> ensureProfile([User? user]);
  Future<void> signOut();
}

class AuthService implements AuthSessionClient {
  AuthService({SupabaseClient? client})
      : _client = client ?? Supabase.instance.client;

  static const String _naverCalendarLogTag = 'PlanFlowNaverCalendar';

  final SupabaseClient _client;

  ActivityTrackingService? _activityTrackingService;

  /// 로그인 성공 시 last_login_at / last_active_at을 갱신할 서비스를 주입한다.
  /// 외부에서 주입하지 않으면 ensureProfile 단계에서 lazy 생성한다.
  void attachActivityTracker(ActivityTrackingService service) {
    _activityTrackingService = service;
  }

  static void _logNaverCalendarAuth(String message) {
    debugPrint('[$_naverCalendarLogTag] auth ${logSafeText(message)}');
  }

  @override
  Session? get currentSession => _client.auth.currentSession;

  @override
  User? get currentUser => _client.auth.currentUser;

  @override
  Stream<AuthState> get authStateChanges => _client.auth.onAuthStateChange;

  @override
  Future<void> refreshSession() async {
    await _client.auth.refreshSession();
  }

  Future<AuthResponse> signInWithEmail({
    required String email,
    required String password,
  }) async {
    final response = await _client.auth.signInWithPassword(
      email: email.trim(),
      password: password,
    );
    unawaited(_tryEnsureProfile(response.user));
    return response;
  }

  Future<AuthResponse> signUpWithEmail({
    required String email,
    required String password,
    String? name,
  }) async {
    final response = await _client.auth.signUp(
      email: email.trim(),
      password: password,
      emailRedirectTo: AppEnv.authRedirectUrl,
      data: <String, dynamic>{
        if (name != null && name.trim().isNotEmpty) 'name': name.trim(),
      },
    );
    if (response.session != null) {
      unawaited(_tryEnsureProfile(response.user));
    }
    return response;
  }

  Future<void> sendPasswordResetEmail(String email) {
    return _client.auth.resetPasswordForEmail(
      email.trim(),
      redirectTo: AppEnv.authRedirectUrl,
    );
  }

  Future<void> updatePassword(String password) async {
    await _client.auth.updateUser(
      UserAttributes(password: password),
    );
  }

  Future<bool> signInWithOAuth(
    PlanFlowOAuthProvider provider, {
    bool forceConsent = false,
    bool forCalendar = false,
  }) async {
    if (provider == PlanFlowOAuthProvider.naver) {
      _logNaverCalendarAuth(
        'signInWithOAuth start forCalendar=$forCalendar '
        'forceConsent=$forceConsent '
        'sessionPresent=${_client.auth.currentSession != null}',
      );
    }
    // iOS Apple 로그인은 브라우저 리다이렉트 대신 네이티브 시트를 사용한다.
    // Supabase 브라우저 OAuth 경로는 Apple provider가 대시보드에서 비활성이면
    // 400("Unsupported provider")을 뱉고, 네이티브 경로는 Sign in with Apple
    // 자체(capability + entitlement)만 있으면 되므로 Supabase 설정과 무관하다.
    if (provider == PlanFlowOAuthProvider.apple && !kIsWeb && Platform.isIOS) {
      return _signInWithAppleNativeIos();
    }
    final uri = await buildOAuthSignInUri(
      provider,
      forceConsent: forceConsent,
      forCalendar: forCalendar,
    );
    final queryParams = oauthQueryParamsFor(
      provider,
      forceConsent: forceConsent,
    );
    if (provider == PlanFlowOAuthProvider.naver) {
      _logNaverCalendarAuth(
        'signInWithOAuth built uri host=${uri.host} path=${uri.path} '
        'queryKeys=${uri.queryParameters.keys.join(',')} '
        'scopes=${oauthScopesFor(provider, forCalendar: forCalendar) ?? 'default'} '
        'queryParamKeys=${queryParams?.keys.join(',') ?? 'none'}',
      );
    }
    return _launchOAuthUrl(
      uri: uri,
      appProvider: provider,
      supabaseProvider: _oauthProvider(provider),
      queryParams: queryParams,
      purpose: forCalendar ? 'calendar-link' : 'sign-in',
    );
  }

  /// iOS 네이티브 Apple 로그인: sign_in_with_apple 시트 → Supabase
  /// signInWithIdToken. 브라우저 launchUrl과 pending-callback 마킹을 우회한다.
  ///
  /// nonce 규약: 해시된 nonce를 Apple credential 요청에 넣고, **raw nonce**를
  /// Supabase signInWithIdToken에 전달한다(Supabase가 서버에서 sha256으로
  /// 대조한다).
  Future<bool> _signInWithAppleNativeIos() async {
    final rawNonce = generateRawNonce();
    final hashedNonce = sha256.convert(utf8.encode(rawNonce)).toString();
    try {
      final credential = await SignInWithApple.getAppleIDCredential(
        scopes: const [
          AppleIDAuthorizationScopes.fullName,
          AppleIDAuthorizationScopes.email,
        ],
        nonce: hashedNonce,
      );
      // banned-ok: runtime Apple credential token from sign_in_with_apple, not a hardcoded secret
      final idToken = credential.identityToken;
      if (idToken == null || idToken.isEmpty) {
        throw const AuthException('Apple identityToken is missing');
      }
      final response = await _client.auth.signInWithIdToken(
        provider: OAuthProvider.apple,
        idToken: idToken,
        nonce: rawNonce,
      );
      unawaited(_tryEnsureProfile(response.user));
      // Apple은 이름을 첫 로그인 1회만 전달하므로, 오는 즉시 프로필에 기록한다.
      unawaited(_captureAppleProfileName(credential, response.user));
      return true;
    } on SignInWithAppleAuthorizationException catch (error) {
      if (error.code == AuthorizationErrorCode.canceled) {
        debugPrint('Apple native sign-in canceled by user');
        // The login screen owns the attempt revision and performs a scoped
        // clear when it catches AppleSignInCanceledException.
        throw const AppleSignInCanceledException();
      }
      rethrow;
    }
  }

  /// Supabase signInWithIdToken용 raw nonce (32바이트 → base64).
  @visibleForTesting
  static String generateRawNonce([Random? random]) {
    final bytes = List<int>.generate(
      32,
      (_) => (random ?? Random.secure()).nextInt(256),
    );
    return base64.encode(bytes);
  }

  /// 첫 Apple 로그인 시 1회만 전달되는 이름을 users 프로필에 기록한다.
  /// 실패해도 로그인 흐름은 유지된다.
  Future<void> _captureAppleProfileName(
    AuthorizationCredentialAppleID credential,
    User? user,
  ) async {
    final givenName = credential.givenName?.trim() ?? '';
    final familyName = credential.familyName?.trim() ?? '';
    final displayName = [familyName, givenName]
        .where((part) => part.isNotEmpty)
        .join(' ')
        .trim();
    if (user == null || displayName.isEmpty) {
      return;
    }
    try {
      await _client.from('users').upsert(
        <String, dynamic>{
          'id': user.id,
          if (user.email != null) 'email': user.email,
          'name': displayName,
        },
        onConflict: 'id',
      );
    } catch (error) {
      debugPrint('Apple profile name capture skipped: ${logSafeText(error)}');
    }
  }

  Future<Uri> buildOAuthSignInUri(
    PlanFlowOAuthProvider provider, {
    bool forceConsent = false,
    bool forCalendar = false,
  }) async {
    final oauthProvider = _oauthProvider(provider);
    final scopes = oauthScopesFor(provider, forCalendar: forCalendar);
    final queryParams = oauthQueryParamsFor(
      provider,
      forceConsent: forceConsent,
    );
    if (provider == PlanFlowOAuthProvider.naver) {
      _logNaverCalendarAuth(
        'buildOAuthSignInUri request forCalendar=$forCalendar '
        'forceConsent=$forceConsent scopes=${scopes ?? 'default'} '
        'queryParamKeys=${queryParams?.keys.join(',') ?? 'none'}',
      );
    }
    final response = await _client.auth.getOAuthSignInUrl(
      provider: oauthProvider,
      redirectTo: AppEnv.authRedirectUrl,
      scopes: scopes,
      queryParams: queryParams,
    );
    return Uri.parse(response.url);
  }

  Future<bool> recheckNaverAccountConsent() {
    return signInWithOAuth(
      PlanFlowOAuthProvider.naver,
      forceConsent: true,
      forCalendar: true,
    );
  }

  Future<bool> connectCalendarProvider(PlanFlowOAuthProvider provider) async {
    final oauthProvider = _oauthProvider(provider);
    if (provider == PlanFlowOAuthProvider.naver) {
      _logNaverCalendarAuth(
        'connectCalendarProvider start sessionPresent=${_client.auth.currentSession != null} '
        'currentUserPresent=${_client.auth.currentUser != null}',
      );
    }
    if (_client.auth.currentSession == null) {
      if (provider == PlanFlowOAuthProvider.naver) {
        _logNaverCalendarAuth(
          'connectCalendarProvider no Supabase session -> signInWithOAuth for calendar',
        );
      }
      return signInWithOAuth(
        provider,
        forCalendar: provider == PlanFlowOAuthProvider.naver,
      );
    }

    // Naver 캘린더: getLinkIdentityUrl은 provider_token을 콜백 URL에 포함하지 않음.
    // full OAuth(signInWithOAuth)만 provider_token을 제공하므로 항상 이 경로 사용.
    if (provider == PlanFlowOAuthProvider.naver) {
      _logNaverCalendarAuth(
        'connectCalendarProvider naver -> signInWithOAuth forceConsent=true forCalendar=true',
      );
      return signInWithOAuth(provider, forceConsent: true, forCalendar: true);
    }

    final queryParams = oauthQueryParamsFor(provider);
    try {
      final response = await _client.auth.getLinkIdentityUrl(
        oauthProvider,
        redirectTo: AppEnv.authRedirectUrl,
        scopes: oauthScopesFor(provider, forCalendar: true),
        queryParams: queryParams,
      );
      return await _launchOAuthUrl(
        uri: Uri.parse(response.url),
        appProvider: provider,
        supabaseProvider: oauthProvider,
        queryParams: queryParams,
        purpose: 'calendar-link',
      );
    } catch (_) {
      rethrow;
    }
  }

  Future<bool> reconnectNaverCalendar() {
    return connectCalendarProvider(PlanFlowOAuthProvider.naver);
  }

  Future<bool> disconnectNaverCalendar() async {
    final currentUser = _client.auth.currentUser;
    if (currentUser == null) {
      return false;
    }

    try {
      final identities = await _client.auth.getUserIdentities();
      UserIdentity? naverIdentity;
      for (final identity in identities) {
        final provider = identity.provider.toLowerCase();
        if (provider.contains('naver')) {
          naverIdentity = identity;
          break;
        }
      }

      if (naverIdentity == null) {
        return false;
      }

      await _client.auth.unlinkIdentity(naverIdentity);
      return true;
    } catch (error, stackTrace) {
      debugPrint('Naver calendar disconnect failed: ${logSafeText(error)}');
      debugPrintStack(stackTrace: stackTrace);
      return false;
    }
  }

  Future<bool> _launchOAuthUrl({
    required Uri uri,
    required PlanFlowOAuthProvider appProvider,
    required OAuthProvider supabaseProvider,
    required Map<String, String>? queryParams,
    required String purpose,
  }) async {
    // externalApplication(구글)은 별도 Chrome 태스크를 띄우는데, 리다이렉트로
    // 앱이 포그라운드로 돌아온 뒤에도 그 Chrome 태스크가 백그라운드에 남아있어
    // 앱 루트에서 뒤로가기를 누르면 홈 화면 대신 그 방치된 Chrome 화면이
    // 드러나는 문제가 있었다. Custom Tab(inAppBrowserView)은 앱과 같은
    // 태스크 안에 머물러 이 문제가 없고, Google의 WebView 로그인 차단 정책도
    // Custom Tab은 허용 대상이라 카카오/네이버와 동일하게 통일한다.
    // iOS는 반대: inAppBrowserView(SFSafariViewController)는 planflow://
    // 리다이렉트를 감지해도 스스로 닫히지 않아 로그인 후 브라우저 시트가
    // 남는다. 외부 Safari는 커스텀 스킴 리다이렉트에서 자동으로 닫히므로
    // 브라우저 기반 provider(google/kakao/naver)는 iOS에서
    // externalApplication을 사용한다. Apple은 iOS에서 네이티브 시트 경로로
    // 우회되므로 여기까지 오지 않는다.
    final launchMode =
        !kIsWeb && Platform.isIOS && appProvider != PlanFlowOAuthProvider.apple
            ? LaunchMode.externalApplication
            : LaunchMode.inAppBrowserView;
    final forCalendar = purpose == 'calendar-link';
    final effectiveScopes =
        oauthScopesFor(appProvider, forCalendar: forCalendar) ?? 'default';
    debugPrint(
      'OAuth launch: purpose=$purpose appProvider=$appProvider '
      'supabaseProvider=$supabaseProvider host=${uri.host} path=${uri.path} '
      'scopes=$effectiveScopes '
      'queryParams=${queryParams?.keys.join(',') ?? 'none'}',
    );
    if (appProvider == PlanFlowOAuthProvider.naver) {
      _logNaverCalendarAuth(
        'launchOAuthUrl purpose=$purpose mode=$launchMode '
        'host=${uri.host} path=${uri.path} '
        'queryKeys=${uri.queryParameters.keys.join(',')} '
        'scopes=$effectiveScopes '
        'queryParamKeys=${queryParams?.keys.join(',') ?? 'none'}',
      );
    }
    final pendingRevision =
        _markPendingOAuthCallback(appProvider: appProvider, purpose: purpose);
    final callbackPurpose = forCalendar
        ? OAuthCallbackPurpose.calendarLink
        : OAuthCallbackPurpose.login;
    await OAuthCallbackHandler.persistCurrentPendingCallback();
    if (!OAuthCallbackHandler.isPendingCallbackAttempt(
      revision: pendingRevision,
      purpose: callbackPurpose,
    )) {
      // The user may have canceled/retried while preference persistence was
      // pending. Do not launch an obsolete provider chooser afterward.
      return false;
    }
    final launched = await launchUrl(
      uri,
      mode: launchMode,
      webOnlyWindowName: '_self',
    );
    if (!launched) {
      if (appProvider == PlanFlowOAuthProvider.naver) {
        _logNaverCalendarAuth('launchOAuthUrl failed launched=false');
      }
      OAuthCallbackHandler.clearPendingCallbackForAttempt(
        revision: pendingRevision,
        purpose: callbackPurpose,
      );
    }
    if (appProvider == PlanFlowOAuthProvider.naver) {
      _logNaverCalendarAuth('launchOAuthUrl result launched=$launched');
    }
    return launched;
  }

  int _markPendingOAuthCallback({
    required PlanFlowOAuthProvider appProvider,
    required String purpose,
  }) {
    switch (purpose) {
      case 'calendar-link':
        return OAuthCallbackHandler.markPendingCalendarLink(appProvider);
      case 'sign-in':
        return OAuthCallbackHandler.markPendingLogin(appProvider);
    }
    throw ArgumentError.value(purpose, 'purpose', 'Unsupported OAuth purpose');
  }

  @override
  Future<void> signOut() {
    return PlanFlowAuthLocalStorage.runWithSessionRemovalAllowed(
      _client.auth.signOut,
    );
  }

  /// Edge Function `delete-account`를 호출해 회원 탈퇴를 처리한다.
  ///
  /// 흐름:
  /// 1) 이메일/비밀번호 가입자라면 [password]로 재인증해 최신 JWT를 받는다
  ///    (Supabase Edge Function은 현재 세션의 access token을 자동으로 첨부한다).
  /// 2) Edge Function을 호출한다. 그룹 리더면 409 + `blockedReason: leader_groups`
  ///    와 소속 그룹 목록이 돌아온다. 그 외 실패는 status 본문으로 전달한다.
  /// 3) 성공 시 로컬 Supabase 세션을 정리한다(signOut 실패는 무시 — 서버에서
  ///    이미 유저가 삭제된 경우 정상).
  Future<DeleteAccountResult> deleteAccount({String? password}) async {
    try {
      final currentUser = _client.auth.currentUser;
      if (currentUser == null) {
        return const DeleteAccountResult(
          success: false,
          errorMessage: '로그인이 필요합니다.',
        );
      }

      if (password != null && password.trim().isNotEmpty) {
        final email = currentUser.email;
        if (email != null) {
          await _client.auth.signInWithPassword(
            email: email,
            password: password,
          );
        }
      }

      final response = await _client.functions.invoke(
        'delete-account',
        body: const <String, dynamic>{},
      );

      final data = response.data is Map<String, dynamic>
          ? response.data as Map<String, dynamic>
          : <String, dynamic>{};

      if (response.status != 200) {
        return DeleteAccountResult(
          success: false,
          blockedReason: data['blockedReason']?.toString(),
          errorMessage: data['message']?.toString() ??
              '탈퇴 처리 실패 (status: ${response.status})',
          leaderGroups: data['leaderGroups'] is List
              ? (data['leaderGroups'] as List)
                  .whereType<Map>()
                  .map(
                    (g) => LeaderGroupInfo(
                      id: g['id']?.toString() ?? '',
                      name: g['name']?.toString() ?? '',
                    ),
                  )
                  .toList()
              : const <LeaderGroupInfo>[],
        );
      }

      final result = DeleteAccountResult.fromJson(data);

      if (result.success) {
        try {
          await _client.auth.signOut();
        } catch (_) {
          // 서버에서 이미 삭제된 경우 signOut이 실패할 수 있다 — 무시한다.
        }
      }

      return result;
    } on FunctionException catch (e) {
      final data = e.details is Map<String, dynamic>
          ? e.details as Map<String, dynamic>
          : <String, dynamic>{};
      if (data['blockedReason'] == 'leader_groups') {
        return DeleteAccountResult.fromJson(data);
      }
      return DeleteAccountResult(
        success: false,
        errorMessage:
            data['message']?.toString() ?? e.details?.toString() ?? '탈퇴 요청 실패',
      );
    } catch (error) {
      return DeleteAccountResult(
        success: false,
        errorMessage: '네트워크 오류: ${error.toString()}',
      );
    }
  }

  @override
  Future<void> ensureProfile([User? user]) async {
    final resolvedUser = user ?? currentUser;
    if (resolvedUser == null || _client.auth.currentSession == null) {
      return;
    }

    final metadata = resolvedUser.userMetadata ?? const <String, dynamic>{};
    final displayName = metadata['name'] ??
        metadata['full_name'] ??
        metadata['user_name'] ??
        metadata['nickname'];

    await _client.from('users').upsert(
      <String, dynamic>{
        'id': resolvedUser.id,
        'email': resolvedUser.email,
        if (displayName != null && displayName.toString().trim().isNotEmpty)
          'name': displayName.toString().trim(),
      },
      onConflict: 'id',
    );

    // 로그인 성공 시점으로 간주해 last_login_at / last_active_at을 갱신한다.
    // activity 트래커가 없으면 lazy 생성. 실패해도 로그인 흐름은 유지된다.
    unawaited(_recordLoginActivity());
  }

  Future<void> _recordLoginActivity() async {
    try {
      final tracker = _activityTrackingService ??= ActivityTrackingService();
      await tracker.recordLogin();
    } catch (error) {
      debugPrint('Login activity record skipped: ${logSafeText(error)}');
    }
  }

  Future<void> _tryEnsureProfile([User? user]) async {
    try {
      await ensureProfile(user);
    } catch (error) {
      debugPrint('Profile sync skipped: ${logSafeText(error)}');
    }
  }

  OAuthProvider _oauthProvider(PlanFlowOAuthProvider provider) {
    return switch (provider) {
      PlanFlowOAuthProvider.google => OAuthProvider.google,
      PlanFlowOAuthProvider.kakao => OAuthProvider.kakao,
      PlanFlowOAuthProvider.naver =>
        const OAuthProvider('custom:planflow-naver'),
      PlanFlowOAuthProvider.apple => OAuthProvider.apple,
    };
  }

  @visibleForTesting
  static String? oauthScopesFor(
    PlanFlowOAuthProvider provider, {
    // forCalendar=true: connectCalendarProvider 경로에서만 사용.
    // 로그인 흐름에는 기본 email scope만 요청.
    bool forCalendar = false,
  }) {
    return switch (provider) {
      PlanFlowOAuthProvider.google => null,
      // Kakao returns KOE205 when the app asks for consent items that are not
      // enabled in Kakao Developers. Keep login on profile-only scopes; email
      // can be added later only after the Kakao consent item is approved.
      PlanFlowOAuthProvider.kakao => 'openid,profile_nickname,profile_image',
      // Login uses the base email scope. Calendar connection still requests
      // calendar consent, and the settings flow falls back to CalDAV if launch
      // or permission verification does not complete.
      PlanFlowOAuthProvider.naver when forCalendar => 'email,calendar',
      PlanFlowOAuthProvider.naver => 'email',
      PlanFlowOAuthProvider.apple => null,
    };
  }

  @visibleForTesting
  static Map<String, String>? oauthQueryParamsFor(
    PlanFlowOAuthProvider provider, {
    bool forceConsent = false,
  }) {
    if (provider == PlanFlowOAuthProvider.naver && forceConsent) {
      return const <String, String>{'auth_type': 'reprompt'};
    }
    return null;
  }
}

/// Edge Function `delete-account`가 그룹 차단 사유로 반환한 그룹 정보.
class LeaderGroupInfo {
  const LeaderGroupInfo({required this.id, required this.name});

  final String id;
  final String name;
}

/// `AuthService.deleteAccount` 결과 모델.
///
/// - 성공: [success] = true, 나머지 필드 null
/// - 그룹 리더 차단: [success] = false, [blockedReason] = `'leader_groups'`,
///   [leaderGroups]에 차단 사유가 된 그룹 목록
/// - 기타 실패: [success] = false, [errorMessage]에 사용자 안내 문구
class DeleteAccountResult {
  const DeleteAccountResult({
    required this.success,
    this.blockedReason,
    this.leaderGroups = const <LeaderGroupInfo>[],
    this.errorMessage,
  });

  final bool success;
  final String? blockedReason;
  final List<LeaderGroupInfo> leaderGroups;
  final String? errorMessage;

  factory DeleteAccountResult.fromJson(Map<String, dynamic> json) {
    final leaderGroupsRaw = json['leaderGroups'];
    return DeleteAccountResult(
      success: json['success'] == true,
      blockedReason: json['blockedReason']?.toString(),
      leaderGroups: leaderGroupsRaw is List
          ? leaderGroupsRaw
              .whereType<Map>()
              .map(
                (g) => LeaderGroupInfo(
                  id: g['id']?.toString() ?? '',
                  name: g['name']?.toString() ?? '',
                ),
              )
              .toList()
          : const <LeaderGroupInfo>[],
      errorMessage: json['message']?.toString() ?? json['error']?.toString(),
    );
  }
}
