import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:app_links/app_links.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/constants.dart';
import '../core/analytics_service.dart';
import '../core/diag_logger.dart';
import '../core/env.dart';
import '../core/log_text.dart';
import '../core/router.dart';
import '../providers/auth_provider.dart';
import 'auth_service.dart';
import 'naver_calendar_permission_service.dart';

enum OAuthCallbackPurpose {
  login,
  calendarLink,
  emailConfirmation,
}

/// Narrow external boundary for Supabase session exchange. Callback parsing,
/// revision checks and routing remain the production implementation.
abstract interface class OAuthCallbackSessionAdapter {
  bool get hasCurrentSession;
  Future<OAuthCallbackSession> completeCallback(Uri callbackUri);
}

class OAuthCallbackSession {
  const OAuthCallbackSession({required this.userId, this.providerToken});

  final String userId;
  final String? providerToken;
}

class OAuthCallbackHandler {
  OAuthCallbackHandler({
    AppLinks? appLinks,
    AuthProvider? authProviderOverride,
    OAuthCallbackSessionAdapter? sessionAdapter,
    bool? supabaseReadyOverride,
  })  : _appLinks = appLinks ?? AppLinks(),
        _authProvider = authProviderOverride ?? authProvider,
        _sessionAdapter = sessionAdapter,
        _supabaseReadyOverride = supabaseReadyOverride;

  static final ValueNotifier<String?> latestUserMessage =
      ValueNotifier<String?>(null);
  static int? _latestUserMessageRevision;
  static OAuthCallbackPurpose? _pendingPurpose;
  static String? _pendingMethod;
  static DateTime? _pendingStartedAt;
  static _NaverPkceAttempt? _pendingNaverAttempt;
  static int _pendingRevision = 0;
  static String? _handlingNaverChallenge;
  static Future<void> _pendingPersistenceQueue = Future<void>.value();
  static const _storedPendingPurposeKey = 'oauth_callback_pending_purpose';
  static const _storedPendingMethodKey = 'oauth_callback_pending_method';
  static const _storedPendingStartedAtKey = 'oauth_callback_pending_started_at';
  static const _storedPendingNaverChallengeKey =
      'oauth_callback_pending_naver_challenge';
  static const _storedNaverPkceKey = 'planflow_pending_naver_pkce_v1';
  static const _naverPkceStorage = FlutterSecureStorage();
  static const naverProviderId = 'custom:planflow-naver';
  static const _naverCalendarLogTag = 'PlanFlowNaverCalendar';

  final AppLinks _appLinks;
  final AuthProvider _authProvider;
  final OAuthCallbackSessionAdapter? _sessionAdapter;
  final bool? _supabaseReadyOverride;
  StreamSubscription<Uri>? _subscription;
  bool _initialLinkHandled = false;

  static void _logNaverCalendar(String message) {
    debugPrint('[$_naverCalendarLogTag] oauth ${logSafeText(message)}');
  }

  static String _safeUriSummary(Uri uri) {
    Map<String, String> fragmentParameters = const <String, String>{};
    if (uri.fragment.isNotEmpty) {
      try {
        fragmentParameters = Uri.splitQueryString(
          uri.fragment.startsWith('#')
              ? uri.fragment.substring(1)
              : uri.fragment,
        );
      } catch (_) {
        fragmentParameters = const <String, String>{};
      }
    }
    return 'scheme=${uri.scheme} host=${uri.host} path=${uri.path} '
        'queryKeys=${uri.queryParameters.keys.join(',')} '
        'fragmentPresent=${uri.fragment.isNotEmpty} '
        'fragmentKeys=${fragmentParameters.keys.join(',')}';
  }

  static int markPendingLogin(PlanFlowOAuthProvider provider) {
    clearLatestUserMessage();
    final method = _methodForProvider(provider);
    if (_pendingPurpose == OAuthCallbackPurpose.login &&
        _pendingMethod == method &&
        _pendingStartedAt != null &&
        DateTime.now().difference(_pendingStartedAt!) <=
            const Duration(minutes: 10)) {
      // LoginScreen and AuthService both mark the same launch boundary. Keep a
      // single revision so screen cancellation remains scoped to this attempt.
      return _pendingRevision;
    }
    final revision = ++_pendingRevision;
    _pendingPurpose = OAuthCallbackPurpose.login;
    _pendingNaverAttempt = null;
    _pendingMethod = method;
    _pendingStartedAt = DateTime.now();
    unawaited(persistCurrentPendingCallback());
    return revision;
  }

  static int markPendingCalendarLink(PlanFlowOAuthProvider provider) {
    clearLatestUserMessage();
    final revision = ++_pendingRevision;
    _pendingPurpose = OAuthCallbackPurpose.calendarLink;
    _pendingMethod = _methodForProvider(provider);
    _pendingStartedAt = DateTime.now();
    _pendingNaverAttempt = null;
    unawaited(persistCurrentPendingCallback());
    return revision;
  }

  static Future<({int revision, String challenge})?> prepareNaverOAuthAttempt({
    required bool forCalendar,
    required Session? initiatingSession,
  }) async {
    if (forCalendar && initiatingSession == null) return null;
    final purpose = forCalendar
        ? OAuthCallbackPurpose.calendarLink
        : OAuthCallbackPurpose.login;
    final revision = forCalendar
        ? markPendingCalendarLink(PlanFlowOAuthProvider.naver)
        : markPendingLogin(PlanFlowOAuthProvider.naver);
    final random = Random.secure();
    final attempt = _NaverPkceAttempt(
      owner: initiatingSession?.user.id,
      sessionFingerprint: _NaverPkceAttempt.fingerprint(initiatingSession),
      verifier: base64Url
          .encode(List<int>.generate(32, (_) => random.nextInt(256)))
          .replaceAll('=', ''),
    );
    _pendingNaverAttempt = attempt;
    await persistCurrentPendingCallback();
    if (!isCurrentNaverOAuthAttempt(revision, attempt.challenge)) return null;
    final stored = await _readStoredPendingCallback();
    if (!isCurrentNaverOAuthAttempt(revision, attempt.challenge) ||
        stored?.purpose != purpose ||
        stored?.naverAttempt?.challenge != attempt.challenge) {
      if (isCurrentNaverOAuthAttempt(revision, attempt.challenge)) {
        _clearPendingCallbackForRevision(revision);
      }
      return null;
    }
    return (revision: revision, challenge: attempt.challenge);
  }

  static bool isCurrentNaverOAuthAttempt(int revision, String challenge) =>
      revision == _pendingRevision &&
      _pendingNaverAttempt?.challenge == challenge;

  static void markPendingEmailConfirmation() {
    clearLatestUserMessage();
    _pendingRevision++;
    _pendingPurpose = OAuthCallbackPurpose.emailConfirmation;
    _pendingNaverAttempt = null;
    _pendingMethod = 'email';
    _pendingStartedAt = DateTime.now();
    unawaited(persistCurrentPendingCallback());
  }

  static String? consumePendingLoginMethod({int? expectedRevision}) {
    if (expectedRevision != null && expectedRevision != _pendingRevision) {
      return null;
    }
    final purpose = _pendingPurpose;
    final method = _pendingMethod;
    final startedAt = _pendingStartedAt;
    if (purpose != OAuthCallbackPurpose.login ||
        method == null ||
        startedAt == null ||
        DateTime.now().difference(startedAt) > const Duration(minutes: 10)) {
      return null;
    }
    clearPendingCallback();
    return method;
  }

  static void clearPendingCallback() {
    if (_pendingMethod == 'naver') {
      _logNaverCalendar(
        'clearPendingCallback purpose=$_pendingPurpose method=$_pendingMethod',
      );
    }
    _pendingPurpose = null;
    _pendingMethod = null;
    _pendingStartedAt = null;
    _pendingNaverAttempt = null;
    final revision = ++_pendingRevision;
    unawaited(_enqueuePendingPersistence(
      revision: revision,
      purpose: null,
      method: null,
      startedAt: null,
      naverAttempt: null,
    ));
  }

  static String _methodForProvider(PlanFlowOAuthProvider provider) =>
      switch (provider) {
        PlanFlowOAuthProvider.google => 'google',
        PlanFlowOAuthProvider.kakao => 'kakao',
        PlanFlowOAuthProvider.naver => 'naver',
        PlanFlowOAuthProvider.apple => 'apple',
      };

  /// Cancels only the login attempt that owns [revision]. A late lifecycle
  /// callback from an older provider chooser must not cancel a newer attempt,
  /// calendar link, or email confirmation.
  static bool clearPendingLogin(int revision) {
    if (revision != _pendingRevision ||
        _pendingPurpose != OAuthCallbackPurpose.login) {
      return false;
    }
    clearPendingCallback();
    return true;
  }

  static bool clearPendingCallbackForAttempt({
    required int revision,
    required OAuthCallbackPurpose purpose,
  }) {
    if (revision != _pendingRevision || _pendingPurpose != purpose) {
      return false;
    }
    clearPendingCallback();
    return true;
  }

  static bool clearPendingCalendarLink(int revision) =>
      clearPendingCallbackForAttempt(
        revision: revision,
        purpose: OAuthCallbackPurpose.calendarLink,
      );

  static bool isPendingCallbackAttempt({
    required int revision,
    required OAuthCallbackPurpose purpose,
  }) =>
      revision == _pendingRevision && _pendingPurpose == purpose;

  static bool _clearPendingCallbackForRevision(int revision) {
    if (revision != _pendingRevision) return false;
    clearPendingCallback();
    return true;
  }

  static int? get pendingLoginRevision =>
      hasPendingLogin() ? _pendingRevision : null;

  static void clearLatestUserMessage() {
    _latestUserMessageRevision = null;
    latestUserMessage.value = null;
  }

  static int? get latestUserMessageRevision => _latestUserMessageRevision;

  static void setLatestUserMessageForRevision(String message, int revision) {
    if (revision != _pendingRevision) return;
    _latestUserMessageRevision = revision;
    latestUserMessage.value = message;
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

  static bool hasPendingCalendarLink({
    Duration maxAge = const Duration(minutes: 10),
  }) {
    final startedAt = _pendingStartedAt;
    return _pendingPurpose == OAuthCallbackPurpose.calendarLink &&
        _pendingMethod != null &&
        startedAt != null &&
        DateTime.now().difference(startedAt) <= maxAge;
  }

  static bool hasPendingEmailConfirmation({
    Duration maxAge = const Duration(hours: 24),
  }) {
    final startedAt = _pendingStartedAt;
    return _pendingPurpose == OAuthCallbackPurpose.emailConfirmation &&
        _pendingMethod == 'email' &&
        startedAt != null &&
        DateTime.now().difference(startedAt) <= maxAge;
  }

  static String? get pendingLoginMethod {
    if (!hasPendingLogin()) {
      return null;
    }
    return _pendingMethod;
  }

  static Future<void> persistCurrentPendingCallback() async {
    final revision = _pendingRevision;
    final purpose = _pendingPurpose;
    final method = _pendingMethod;
    final startedAt = _pendingStartedAt;
    final naverAttempt = _pendingNaverAttempt;
    await _enqueuePendingPersistence(
      revision: revision,
      purpose: purpose,
      method: method,
      startedAt: startedAt,
      naverAttempt: naverAttempt,
    );
  }

  static Future<void> _enqueuePendingPersistence({
    required int revision,
    required OAuthCallbackPurpose? purpose,
    required String? method,
    required DateTime? startedAt,
    required _NaverPkceAttempt? naverAttempt,
  }) {
    final operation = _pendingPersistenceQueue.then((_) async {
      final prefs = await SharedPreferences.getInstance();
      if (revision != _pendingRevision ||
          (purpose != null &&
              !identical(naverAttempt, _pendingNaverAttempt))) {
        return;
      }
      // The challenge commits the same attempt whose verifier and owner were
      // sealed together. A partial write cannot reattach an older verifier.
      await prefs.remove(_storedPendingNaverChallengeKey);
      if (purpose == null || method == null || startedAt == null) {
        await prefs.remove(_storedPendingPurposeKey);
        await prefs.remove(_storedPendingMethodKey);
        await prefs.remove(_storedPendingStartedAtKey);
        await _naverPkceStorage.delete(key: _storedNaverPkceKey);
        _logNaverCalendar('clearStoredPendingCallback completed');
        return;
      }
      await prefs.setString(_storedPendingPurposeKey, purpose.name);
      await prefs.setString(_storedPendingMethodKey, method);
      await prefs.setInt(
        _storedPendingStartedAtKey,
        startedAt.millisecondsSinceEpoch,
      );
      if (naverAttempt != null) {
        await _naverPkceStorage.write(
          key: _storedNaverPkceKey,
          value: jsonEncode({
            'verifier': naverAttempt.verifier,
            'owner': naverAttempt.owner,
            'sessionFingerprint': naverAttempt.sessionFingerprint,
            'purpose': purpose.name,
            'startedAt': startedAt.millisecondsSinceEpoch,
          }),
        );
        await prefs.setString(
          _storedPendingNaverChallengeKey,
          naverAttempt.challenge,
        );
      } else {
        await _naverPkceStorage.delete(key: _storedNaverPkceKey);
      }
      if (method == 'naver') {
        _logNaverCalendar(
          'persistPendingCallback purpose=$purpose method=$method',
        );
      }
    });
    _pendingPersistenceQueue = operation.catchError((Object error) {
      debugPrint(
        'OAuth pending callback persistence skipped: ${error.runtimeType}',
      );
    });
    return _pendingPersistenceQueue;
  }

  static Future<void> _clearStoredPendingCallback(
      {int? expectedRevision}) async {
    final revision = expectedRevision ?? _pendingRevision;
    if (revision != _pendingRevision) return;
    await _enqueuePendingPersistence(
      revision: revision,
      purpose: null,
      method: null,
      startedAt: null,
      naverAttempt: null,
    );
  }

  static Future<_StoredOAuthPending?> _readStoredPendingCallback({
    Duration maxAge = const Duration(minutes: 10),
  }) async {
    final readRevision = _pendingRevision;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (readRevision != _pendingRevision) return null;
      final purposeName = prefs.getString(_storedPendingPurposeKey);
      final method = prefs.getString(_storedPendingMethodKey);
      final startedAtMillis = prefs.getInt(_storedPendingStartedAtKey);
      if (purposeName == null || method == null || startedAtMillis == null) {
        _logNaverCalendar('readStoredPendingCallback empty');
        return null;
      }

      OAuthCallbackPurpose? purpose;
      for (final value in OAuthCallbackPurpose.values) {
        if (value.name == purposeName) {
          purpose = value;
          break;
        }
      }
      final startedAt = DateTime.fromMillisecondsSinceEpoch(startedAtMillis);
      if (purpose == null || DateTime.now().difference(startedAt) > maxAge) {
        if (method == 'naver') {
          _logNaverCalendar(
            'readStoredPendingCallback expiredOrInvalid purpose=$purposeName',
          );
        }
        await _clearStoredPendingCallback(expectedRevision: readRevision);
        return null;
      }

      if (method == 'naver') {
        _logNaverCalendar(
          'readStoredPendingCallback restored purpose=$purpose method=$method',
        );
      }
      _NaverPkceAttempt? naverAttempt;
      final challenge = prefs.getString(_storedPendingNaverChallengeKey);
      if (method == 'naver' && challenge != null) {
        final sealed = await _naverPkceStorage.read(key: _storedNaverPkceKey);
        if (readRevision != _pendingRevision) return null;
        final record = sealed == null ? null : jsonDecode(sealed);
        if (record is Map<String, dynamic> &&
            record['purpose'] == purposeName &&
            record['startedAt'] == startedAtMillis &&
            record['verifier'] is String &&
            ((record['owner'] == null && record['sessionFingerprint'] == null) ||
                (record['owner'] is String &&
                    record['sessionFingerprint'] is String))) {
          final attempt = _NaverPkceAttempt(
            owner: record['owner'] as String?,
            sessionFingerprint: record['sessionFingerprint'] as String?,
            verifier: record['verifier'] as String,
          );
          if (attempt.challenge == challenge) naverAttempt = attempt;
        }
      }
      return _StoredOAuthPending(
        purpose: purpose,
        method: method,
        startedAt: startedAt,
        naverAttempt: naverAttempt,
      );
    } catch (error) {
      debugPrint(
        'OAuth pending callback restore skipped: ${error.runtimeType}',
      );
      return null;
    }
  }

  @visibleForTesting
  static void clearInMemoryPendingCallbackForTest() {
    _pendingRevision++;
    _pendingPurpose = null;
    _pendingMethod = null;
    _pendingStartedAt = null;
    _pendingNaverAttempt = null;
  }

  @visibleForTesting
  static Future<void> flushPendingCallbackPersistenceForTest() =>
      _pendingPersistenceQueue;

  @visibleForTesting
  static Future<bool> hasRecoverableNaverCalendarLinkCallbackForTest(
    Session? session,
  ) async {
    final pending = await _resolvePendingCallback();
    return pending?.naverAttempt?.ownsSession(session) == true &&
        shouldTrustProviderTokenForNaverCalendarLink(
      pendingPurpose: pending?.purpose,
      pendingMethod: pending?.method,
    );
  }

  static Future<_StoredOAuthPending?> _resolvePendingCallback() async {
    final inMemoryStartedAt = _pendingStartedAt;
    if (_pendingPurpose != null &&
        _pendingMethod != null &&
        inMemoryStartedAt != null &&
        DateTime.now().difference(inMemoryStartedAt) <=
            const Duration(minutes: 10)) {
      if (_pendingMethod == 'naver') {
        _logNaverCalendar(
          'resolvePendingCallback source=memory purpose=$_pendingPurpose',
        );
      }
      return _StoredOAuthPending(
        purpose: _pendingPurpose!,
        method: _pendingMethod!,
        startedAt: inMemoryStartedAt,
        naverAttempt: _pendingNaverAttempt,
      );
    }
    _logNaverCalendar('resolvePendingCallback source=stored');
    return _readStoredPendingCallback();
  }

  @visibleForTesting
  static bool shouldExchangeOAuthCallback({
    required bool currentSessionPresent,
    required bool isPasswordRecovery,
    required bool hasPendingCalendarLink,
  }) {
    if (isPasswordRecovery) {
      return true;
    }
    if (hasPendingCalendarLink) {
      return true;
    }
    return !currentSessionPresent;
  }

  void start() {
    if (kIsWeb || !AppEnv.hasValidSupabaseConfig || _subscription != null) {
      return;
    }

    debugPrint(
      'OAuth callback listener start: '
      'supabaseReady=${AppEnv.isSupabaseReady}',
    );
    unawaited(_handleInitialLinkOnce());

    _subscription = _appLinks.uriLinkStream.listen(
      (uri) => unawaited(_handleUri(uri)),
      onError: (Object error, StackTrace stackTrace) {
        debugPrint(
          'OAuth callback listener error: ${logSafeText(error)}',
        );
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
        _logNaverCalendar('initialLink observed ${_safeUriSummary(uri)}');
        await _handleUri(uri);
      }
    } catch (error, stackTrace) {
      debugPrint(
        'OAuth initial callback read failed: ${logSafeText(error)}',
      );
      debugPrintStack(stackTrace: stackTrace);
    }
  }

  Future<void> _handleUri(Uri uri) async {
    if (!_isAuthCallback(uri)) {
      return;
    }

    final callbackRevision = _pendingRevision;
    final resolvedPending = await _resolvePendingCallback();
    if (callbackRevision != _pendingRevision) {
      debugPrint(
          'OAuth callback ignored: superseded by a newer login attempt.');
      return;
    }
    clearLatestUserMessage();
    DiagLogger.log('DIAG',
        'resolvePending purpose=${resolvedPending?.purpose} method=${resolvedPending?.method}');
    final pendingPurpose = resolvedPending?.purpose;
    final pendingMethod = resolvedPending?.method;
    final naverAttempt = resolvedPending?.naverAttempt;
    bool isCurrent() =>
        callbackRevision == _pendingRevision &&
        (pendingMethod != 'naver' ||
            _pendingPurpose == null ||
            identical(_pendingNaverAttempt, naverAttempt));
    final isPendingNaverCalendarLink =
        shouldTrustProviderTokenForNaverCalendarLink(
      pendingPurpose: pendingPurpose,
      pendingMethod: pendingMethod,
    );
    final useIsolatedNaver = _sessionAdapter == null && pendingMethod == 'naver';
    DiagLogger.log(
        'DIAG', 'isPendingNaverCalendarLink=$isPendingNaverCalendarLink');
    final normalizedUri = _normalizeAuthCallbackUri(uri);
    final isPasswordRecovery =
        !useIsolatedNaver && isPasswordRecoveryCallback(normalizedUri);
    final isEmailConfirmation = !useIsolatedNaver &&
        (isEmailConfirmationCallback(normalizedUri) ||
            hasPendingEmailConfirmation());
    debugPrint(
      'OAuth callback observed: host=${uri.host} '
      'queryKeys=${normalizedUri.queryParameters.keys.join(',')} '
      'passwordRecovery=$isPasswordRecovery '
      'emailConfirmation=$isEmailConfirmation '
      'pendingPurpose=$pendingPurpose pendingMethod=$pendingMethod',
    );
    if (pendingMethod == 'naver') {
      _logNaverCalendar(
        'handleUri observed original=${_safeUriSummary(uri)} '
        'normalized=${_safeUriSummary(normalizedUri)} '
        'pendingPurpose=$pendingPurpose pendingMethod=$pendingMethod '
        'trustProviderToken=$isPendingNaverCalendarLink '
        'passwordRecovery=$isPasswordRecovery '
        'emailConfirmation=$isEmailConfirmation',
      );
    }

    final callbackErrorMessage = callbackErrorMessageFor(
      normalizedUri,
      isEmailConfirmation: isEmailConfirmation,
      pendingMethod: pendingMethod,
    );
    if (callbackErrorMessage != null) {
      debugPrint('OAuth callback reported error.');
      if (pendingMethod == 'naver') {
        _logNaverCalendar('provider callback error');
      }
      if (!isCurrent()) return;
      setLatestUserMessageForRevision(callbackErrorMessage, callbackRevision);
      _clearPendingCallbackForRevision(callbackRevision);
      return;
    }

    final ready = await _waitForSupabaseReady();
    if (!isCurrent()) return;
    if (pendingMethod == 'naver') {
      _logNaverCalendar('supabaseReady=$ready');
    }
    if (!ready) {
      debugPrint('OAuth callback skipped: Supabase was not ready in time.');
      setLatestUserMessageForRevision(
        '로그인 준비가 끝나기 전에 인증 콜백을 받았습니다. 앱을 다시 열고 로그인을 다시 시도해 주세요.',
        callbackRevision,
      );
      _clearPendingCallbackForRevision(callbackRevision);
      return;
    }

    final client = _sessionAdapter == null ? Supabase.instance.client : null;
    final hasCurrentSession = _sessionAdapter?.hasCurrentSession ??
        client!.auth.currentSession != null;
    final shouldExchangeCallback = shouldExchangeOAuthCallback(
      currentSessionPresent: hasCurrentSession,
      isPasswordRecovery: isPasswordRecovery,
      hasPendingCalendarLink:
          pendingPurpose == OAuthCallbackPurpose.calendarLink,
    );
    DiagLogger.log('DIAG',
        'shouldExchange=$shouldExchangeCallback currentSession=$hasCurrentSession');

    debugPrint(
      'OAuth callback routing: pendingPurpose=$pendingPurpose '
      'pendingMethod=$pendingMethod '
      'currentSessionPresent=$hasCurrentSession '
      'shouldExchange=$shouldExchangeCallback',
    );
    if (pendingMethod == 'naver') {
      debugPrint(
        '[PlanFlowNaverCalendar] oauth callback routing '
        'calendarLink=${pendingPurpose == OAuthCallbackPurpose.calendarLink} '
        'currentSessionPresent=$hasCurrentSession '
        'shouldExchange=$shouldExchangeCallback',
      );
    }

    if (!shouldExchangeCallback && !useIsolatedNaver) {
      debugPrint('OAuth callback already produced a Supabase session.');
      final signedIn = await _syncAndRouteHome();
      if (signedIn) {
        if (isEmailConfirmation) {
          await AnalyticsService.logSignUp(method: 'email');
          _clearPendingCallbackForRevision(callbackRevision);
        } else {
          await _logPendingLoginIfNeeded(callbackRevision: callbackRevision);
        }
      } else {
        _clearPendingCallbackForRevision(callbackRevision);
      }
      return;
    }

    if (useIsolatedNaver) {
      final auth = client!.auth;
      final attempt = naverAttempt;
      final codes = uri.queryParametersAll['code'];
      final authCode = codes?.length == 1 ? codes!.single.trim() : null;
      final failureMessage = isPendingNaverCalendarLink
          ? '네이버 캘린더 연결을 확인하지 못했습니다. 설정에서 다시 연결해 주세요.'
          : '네이버 로그인을 완료하지 못했습니다. 다시 시도해 주세요.';
      if (attempt == null ||
          authCode == null ||
          authCode.isEmpty ||
          !attempt.ownsSession(auth.currentSession)) {
        setLatestUserMessageForRevision(failureMessage, callbackRevision);
        _clearPendingCallbackForRevision(callbackRevision);
        return;
      }
      final challenge = attempt.challenge;
      if (_handlingNaverChallenge == challenge) return;
      _handlingNaverChallenge = challenge;
      try {
        final completed = await completeIsolatedNaverOAuth(
          owner: attempt.owner,
          readSession: () => auth.currentSession,
          sessionChanges: auth.onAuthStateChange
              .where((state) =>
                  state.session != null ||
                  state.event == AuthChangeEvent.signedOut)
              .map((state) => state.event == AuthChangeEvent.signedOut
                  ? null
                  : state.session),
          exchange: () => exchangeNaverPkce(
            projectUrl: AppEnv.supabaseUrl,
            apiKey: AppEnv.supabaseAnonKey,
            authCode: authCode,
            verifier: attempt.verifier,
          ),
          installLoginSession: isPendingNaverCalendarLink
              ? null
              : (session) async {
                  // This public SDK call installs synchronously before it
                  // yields. Only a verified normal login reaches it.
                  final installation =
                      auth.setInitialSession(jsonEncode(session.toJson()));
                  final installed = auth.currentSession;
                  await installation;
                  return installed;
                },
          onLoginCompleted: () async {
            final signedIn = await _syncAndRouteHome();
            if (signedIn && isCurrent()) {
              await _logPendingLoginIfNeeded(callbackRevision: callbackRevision);
            }
          },
          isPending: isCurrent,
          tokenStore: const NaverCalendarOAuthTokenStore(),
        );
        if (!isCurrent()) return;
        if (!completed) {
          setLatestUserMessageForRevision(failureMessage, callbackRevision);
        }
      } catch (error) {
        _logNaverCalendar('isolated exchange failed type=${error.runtimeType}');
        if (isCurrent()) {
          setLatestUserMessageForRevision(failureMessage, callbackRevision);
        }
      } finally {
        if (_handlingNaverChallenge == challenge) {
          _handlingNaverChallenge = null;
        }
        if (isCurrent()) _clearPendingCallbackForRevision(callbackRevision);
      }
      return;
    }

    try {
      if (pendingMethod == 'naver') {
        _logNaverCalendar('exchange start');
      }
      if (_sessionAdapter == null) {
        await client!.auth.getSessionFromUrl(normalizedUri);
      } else {
        await _sessionAdapter.completeCallback(normalizedUri);
      }
      if (callbackRevision != _pendingRevision) return;
      // OAuth callback completion must not open a second Google account picker.
      // Calendar linking is an explicit Settings action; callback paths only
      // establish the PlanFlow session and route the user home.
      if (isPasswordRecovery) {
        _authProvider.markPasswordRecovery();
        _clearPendingCallbackForRevision(callbackRevision);
        appRouter.go(AppRoutes.resetPassword);
        return;
      }
      final signedIn = await _syncAndRouteHome();
      if (signedIn) {
        if (isEmailConfirmation) {
          await AnalyticsService.logSignUp(method: 'email');
          _clearPendingCallbackForRevision(callbackRevision);
        } else {
          await _logPendingLoginIfNeeded(callbackRevision: callbackRevision);
        }
      } else {
        _clearPendingCallbackForRevision(callbackRevision);
      }
    } on AuthException catch (error) {
      if (callbackRevision != _pendingRevision) return;
      debugPrint(
        'OAuth callback exchange failed: ${logSafeText(error.message)} '
        'code=${error.code} status=${error.statusCode}',
      );
      setLatestUserMessageForRevision(
        isEmailConfirmation
            ? _messageForEmailConfirmationException(error)
            : _messageForAuthException(error),
        callbackRevision,
      );
      _clearPendingCallbackForRevision(callbackRevision);
      if (pendingMethod == 'naver') {
        _logNaverCalendar(
          'exchange authException message=${logSafeText(error.message)} '
          'code=${error.code} status=${error.statusCode}',
        );
      }
    } catch (error) {
      if (callbackRevision != _pendingRevision) return;
      debugPrint('OAuth callback exchange failed: ${logSafeText(error)}');
      if (pendingMethod == 'naver') {
        _logNaverCalendar(
          'exchange failed type=${error.runtimeType} '
          'error=${logSafeText(error)}',
        );
      }
      setLatestUserMessageForRevision(
        isEmailConfirmation
            ? '이메일 인증을 확인하지 못했습니다. 인증 링크가 만료되었거나 이미 사용되었습니다. 로그인으로 다시 시도해 주세요.'
            : '로그인 세션을 확인하지 못했습니다. 잠시 후 다시 시도해 주세요.',
        callbackRevision,
      );
      _clearPendingCallbackForRevision(callbackRevision);
    }
  }

  @visibleForTesting
  static String? callbackErrorMessageFor(
    Uri uri, {
    bool isEmailConfirmation = false,
    String? pendingMethod,
  }) {
    final error = uri.queryParameters['error']?.toLowerCase().trim() ?? '';
    final errorCode =
        uri.queryParameters['error_code']?.toLowerCase().trim() ?? '';
    final description =
        uri.queryParameters['error_description']?.toLowerCase().trim() ?? '';

    if (error.isEmpty && errorCode.isEmpty && description.isEmpty) {
      return null;
    }

    final combined = '$error $errorCode $description';
    if (isEmailConfirmation) {
      if (combined.contains('otp_expired') ||
          combined.contains('expired') ||
          combined.contains('invalid')) {
        return '이메일 인증 링크가 만료되었거나 이미 사용되었습니다. 로그인으로 다시 시도하거나 회원가입 메일을 다시 받아 주세요.';
      }
      if (combined.contains('access_denied')) {
        return '이메일 인증이 완료되지 않았습니다. 메일의 인증 링크를 다시 열어 주세요.';
      }
      return '이메일 인증을 완료하지 못했습니다. 인증 링크를 다시 확인해 주세요.';
    }

    if (combined.contains('access_denied')) {
      if (pendingMethod == null || pendingMethod == 'email') {
        return '인증이 완료되지 않았습니다. 이메일 인증 링크가 맞는지 확인하고, 기존 계정이면 로그인하거나 비밀번호 찾기를 이용해 주세요.';
      }
      final method = pendingMethod == 'kakao'
          ? '카카오'
          : pendingMethod == 'naver'
              ? '네이버'
              : pendingMethod == 'apple'
                  ? 'Apple'
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
    if (combined.contains('multiple accounts with the same email')) {
      return '네이버 계정 이메일이 기존 로그인 정보와 충돌합니다. '
          'Supabase SQL Editor에서 custom:naver identity를 '
          'custom:planflow-naver로 마이그레이션한 뒤 다시 시도해 주세요.';
    }

    final errDetail = [
      if (error.isNotEmpty) error,
      if (errorCode.isNotEmpty) errorCode,
      if (description.isNotEmpty) description,
    ].join(' / ');
    return '소셜 인증을 완료하지 못했습니다.'
        '${errDetail.isEmpty ? '' : ' [$errDetail]'}'
        ' Supabase와 provider 콜백 설정을 확인해 주세요.';
  }

  String _messageForEmailConfirmationException(AuthException error) {
    final message = error.message.toLowerCase();
    if (message.contains('expired') || message.contains('invalid')) {
      return '이메일 인증 링크가 만료되었거나 이미 사용되었습니다. 로그인으로 다시 시도하거나 회원가입 메일을 다시 받아 주세요.';
    }
    return '이메일 인증을 확인하지 못했습니다. 인증 링크를 다시 확인해 주세요.';
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
    return '소셜 인증을 완료하지 못했습니다.'
        ' [${error.message}]'
        ' Supabase와 provider 콜백 설정을 확인해 주세요.';
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

  Future<bool> _waitForSupabaseReady({
    Duration timeout = const Duration(seconds: 10),
  }) async {
    if (_supabaseReadyOverride ?? AppEnv.isSupabaseReady) {
      return true;
    }

    final deadline = DateTime.now().add(timeout);
    while (!(_supabaseReadyOverride ?? AppEnv.isSupabaseReady) &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    return _supabaseReadyOverride ?? AppEnv.isSupabaseReady;
  }

  @visibleForTesting
  static Future<Session> exchangeNaverPkce({
    required String projectUrl,
    required String apiKey,
    required String authCode,
    required String verifier,
    http.Client? client,
  }) async {
    final uri = Uri.parse(projectUrl).resolve('/auth/v1/token').replace(
      queryParameters: {'grant_type': 'pkce'},
    );
    final request = http.Request('POST', uri)
      ..followRedirects = false
      ..headers.addAll({'apikey': apiKey, 'content-type': 'application/json'})
      ..body = jsonEncode({'auth_code': authCode, 'code_verifier': verifier});
    final transport = client ?? http.Client();
    final http.Response response;
    try {
      response = await transport
          .send(request)
          .then(http.Response.fromStream)
          .timeout(const Duration(seconds: 15));
    } finally {
      if (client == null) transport.close();
    }
    if (response.statusCode != 200) {
      throw AuthException('Naver PKCE exchange failed.',
          statusCode: '${response.statusCode}');
    }
    final payload = jsonDecode(response.body);
    final session = payload is Map<String, dynamic>
        ? Session.fromJson(payload)
        : null;
    if (session == null || session.user.id.isEmpty) {
      throw const AuthException('Naver PKCE exchange did not return a session.');
    }
    return session;
  }

  @visibleForTesting
  static Future<bool> completeIsolatedNaverOAuth({
    required String? owner,
    required Session? Function() readSession,
    required Stream<Session?> sessionChanges,
    required Future<Session> Function() exchange,
    Future<Session?> Function(Session)? installLoginSession,
    Future<void> Function()? onLoginCompleted,
    required bool Function() isPending,
    required NaverCalendarOAuthTokenStore tokenStore,
  }) async {
    final original = readSession();
    if (!isPending() || original?.user.id != owner ||
        (installLoginSession == null && (owner == null || owner.isEmpty))) {
      return false;
    }
    final observed = <Session?>[];
    final subscription = sessionChanges.listen(observed.add,
        onError: (Object _) {});
    try {
      final exchanged = await exchange();
      bool stillOriginal() =>
          isPending() &&
          identical(readSession(), original) &&
          observed.every((session) => identical(session, original));
      if (!stillOriginal()) return false;

      if (installLoginSession == null) {
        // Linking a calendar must neither install nor refresh an app session.
        return await tokenStore.saveVerifiedCallbackToken(
          userId: owner!,
          token: exchanged.providerToken,
          stillCurrent: stillOriginal,
          replaceExisting: true,
        );
      }

      final installed = await installLoginSession(exchanged);
      bool stillInstalled() =>
          isPending() &&
          installed?.user.id == exchanged.user.id &&
          identical(readSession(), installed) &&
          observed.every((session) =>
              identical(session, original) || identical(session, installed));
      if (!stillInstalled()) return false;
      try {
        await tokenStore.saveVerifiedCallbackToken(
          userId: exchanged.user.id,
          token: exchanged.providerToken,
          stillCurrent: stillInstalled,
          replaceExisting: false,
        );
      } catch (error) {
        _logNaverCalendar('login token save skipped type=${error.runtimeType}');
      }
      if (!stillInstalled()) return false;
      await onLoginCompleted?.call();
      return true;
    } finally {
      await subscription.cancel();
    }
  }

  @visibleForTesting
  static bool shouldTrustProviderTokenForNaverCalendarLink({
    required OAuthCallbackPurpose? pendingPurpose,
    required String? pendingMethod,
  }) {
    return pendingPurpose == OAuthCallbackPurpose.calendarLink &&
        pendingMethod == 'naver';
  }

  @visibleForTesting
  static bool isPasswordRecoveryCallback(Uri uri) {
    final parameters = <String, String>{
      ...uri.queryParameters,
      if (uri.fragment.isNotEmpty)
        ...Uri.splitQueryString(
          uri.fragment.startsWith('#')
              ? uri.fragment.substring(1)
              : uri.fragment,
        ),
    };
    final normalizedType = parameters['type']?.toLowerCase().trim();
    if (normalizedType == 'recovery') {
      return true;
    }
    final normalizedEvent = parameters['event']?.toLowerCase().trim();
    return normalizedEvent == 'password_recovery' ||
        normalizedEvent == 'passwordrecovery';
  }

  @visibleForTesting
  static bool isEmailConfirmationCallback(Uri uri) {
    final parameters = <String, String>{
      ...uri.queryParameters,
      if (uri.fragment.isNotEmpty)
        ...Uri.splitQueryString(
          uri.fragment.startsWith('#')
              ? uri.fragment.substring(1)
              : uri.fragment,
        ),
    };
    final normalizedType = parameters['type']?.toLowerCase().trim();
    final normalizedEvent = parameters['event']?.toLowerCase().trim();
    return normalizedType == 'signup' ||
        normalizedType == 'email' ||
        normalizedType == 'email_change' ||
        normalizedEvent == 'signup' ||
        normalizedEvent == 'email_confirmed' ||
        normalizedEvent == 'emailconfirmation';
  }

  Future<bool> _syncAndRouteHome() async {
    // Session synchronization updates authProvider; router redirects decide
    // whether login, the required first-run tour, or the shell is next. Calling
    // go(home) here used to override the router's required tutorial route.
    return _authProvider.syncCurrentSession();
  }

  static Future<void> _logPendingLoginIfNeeded({int? callbackRevision}) async {
    final method =
        consumePendingLoginMethod(expectedRevision: callbackRevision);
    if (method != null) {
      await AnalyticsService.logLogin(method: method);
    }
  }

  Future<void> dispose() async {
    await _subscription?.cancel();
    _subscription = null;
  }
}

class _StoredOAuthPending {
  const _StoredOAuthPending({
    required this.purpose,
    required this.method,
    required this.startedAt,
    this.naverAttempt,
  });

  final OAuthCallbackPurpose purpose;
  final String method;
  final DateTime startedAt;
  final _NaverPkceAttempt? naverAttempt;
}

class _NaverPkceAttempt {
  const _NaverPkceAttempt({
    required this.owner,
    required this.sessionFingerprint,
    required this.verifier,
  });

  final String? owner;
  final String? sessionFingerprint;
  final String verifier;

  static String? fingerprint(Session? session) => session == null
      ? null
      : sha256.convert(utf8.encode(session.accessToken)).toString();

  bool ownsSession(Session? session) =>
      session?.user.id == owner && fingerprint(session) == sessionFingerprint;

  String get challenge => base64Url
      .encode(sha256.convert(utf8.encode(verifier)).bytes)
      .replaceAll('=', '');
}
