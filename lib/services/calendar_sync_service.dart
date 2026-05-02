import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:googleapis/calendar/v3.dart' as gcal;
import 'package:googleapis_auth/googleapis_auth.dart' as gauth;
import 'package:http/http.dart' as http;

enum CalendarProvider {
  google,
  naver,
}

enum CalendarIntegrationStatus {
  notConfigured,
  signedOut,
  ready,
  syncing,
  synced,
  unsupported,
  failed,
}

class CalendarIntegrationResult {
  const CalendarIntegrationResult({
    required this.provider,
    required this.status,
    required this.message,
    this.syncedItems = 0,
    this.error,
    this.stackTrace,
  });

  final CalendarProvider provider;
  final CalendarIntegrationStatus status;
  final String message;
  final int syncedItems;
  final Object? error;
  final StackTrace? stackTrace;

  bool get isReady => status == CalendarIntegrationStatus.ready;

  bool get isSuccess =>
      status == CalendarIntegrationStatus.ready ||
      status == CalendarIntegrationStatus.synced;

  bool get needsSetup => status == CalendarIntegrationStatus.notConfigured;

  factory CalendarIntegrationResult.notConfigured(
    CalendarProvider provider, {
    String? message,
  }) {
    return CalendarIntegrationResult(
      provider: provider,
      status: CalendarIntegrationStatus.notConfigured,
      message:
          message ?? 'This calendar integration has not been configured yet.',
    );
  }

  factory CalendarIntegrationResult.signedOut(
    CalendarProvider provider, {
    String? message,
  }) {
    return CalendarIntegrationResult(
      provider: provider,
      status: CalendarIntegrationStatus.signedOut,
      message:
          message ?? 'A user sign-in is required before calendar sync can run.',
    );
  }

  factory CalendarIntegrationResult.ready(
    CalendarProvider provider, {
    String? message,
  }) {
    return CalendarIntegrationResult(
      provider: provider,
      status: CalendarIntegrationStatus.ready,
      message: message ?? 'Calendar integration is ready.',
    );
  }

  factory CalendarIntegrationResult.syncing(
    CalendarProvider provider, {
    String? message,
  }) {
    return CalendarIntegrationResult(
      provider: provider,
      status: CalendarIntegrationStatus.syncing,
      message: message ?? 'Calendar sync is in progress.',
    );
  }

  factory CalendarIntegrationResult.synced(
    CalendarProvider provider, {
    String? message,
    int syncedItems = 0,
  }) {
    return CalendarIntegrationResult(
      provider: provider,
      status: CalendarIntegrationStatus.synced,
      message: message ?? 'Calendar sync completed.',
      syncedItems: syncedItems,
    );
  }

  factory CalendarIntegrationResult.unsupported(
    CalendarProvider provider, {
    String? message,
  }) {
    return CalendarIntegrationResult(
      provider: provider,
      status: CalendarIntegrationStatus.unsupported,
      message: message ?? 'This integration is not supported yet.',
    );
  }

  factory CalendarIntegrationResult.failed(
    CalendarProvider provider, {
    required Object error,
    StackTrace? stackTrace,
    String? message,
  }) {
    return CalendarIntegrationResult(
      provider: provider,
      status: CalendarIntegrationStatus.failed,
      message: message ?? 'Calendar sync failed.',
      error: error,
      stackTrace: stackTrace,
    );
  }
}

class CalendarSyncSummary {
  const CalendarSyncSummary({
    required this.google,
    required this.naver,
  });

  final CalendarIntegrationResult google;
  final CalendarIntegrationResult naver;

  bool get hasAnySuccess => google.isSuccess || naver.isSuccess;
}

class CalendarSyncService {
  CalendarSyncService({
    String? googleClientId,
    String? googleServerClientId,
    List<String> googleScopes = const <String>[
      gcal.CalendarApi.calendarEventsScope
    ],
    GoogleSignIn? googleSignIn,
    bool? googlePlatformSupported,
    TargetPlatform? googleTargetPlatform,
    http.Client Function()? httpClientFactory,
  })  : _googleClientId = googleClientId,
        _googleServerClientId = googleServerClientId,
        _googleScopes = List<String>.unmodifiable(googleScopes),
        _googleSignIn = googleSignIn,
        _googlePlatformSupportedOverride = googlePlatformSupported,
        _googleTargetPlatformOverride = googleTargetPlatform,
        _httpClientFactory = httpClientFactory ?? http.Client.new;

  final String? _googleClientId;
  final String? _googleServerClientId;
  final List<String> _googleScopes;
  final bool? _googlePlatformSupportedOverride;
  final TargetPlatform? _googleTargetPlatformOverride;
  final http.Client Function() _httpClientFactory;

  GoogleSignIn? _googleSignIn;

  GoogleSignIn get _googleSignInInstance {
    return _googleSignIn ??= GoogleSignIn(
      scopes: _googleScopes,
      clientId: _googleClientId,
      serverClientId: _googleServerClientId,
    );
  }

  bool _hasText(String? value) => value != null && value.trim().isNotEmpty;

  TargetPlatform get _googleTargetPlatform {
    return _googleTargetPlatformOverride ?? defaultTargetPlatform;
  }

  bool get _isAndroidGoogleSignIn {
    return !kIsWeb && _googleTargetPlatform == TargetPlatform.android;
  }

  String? get _googleConfigurationIssue {
    if (_isAndroidGoogleSignIn && !_hasText(_googleServerClientId)) {
      return 'Android에서 Google Calendar를 연결하려면 Web OAuth Client ID를 serverClientId로 설정해야 합니다.';
    }

    if (!_hasText(_googleClientId) && !_hasText(_googleServerClientId)) {
      return 'Google Calendar 연결에 필요한 OAuth Client ID가 설정되지 않았습니다.';
    }

    return null;
  }

  bool get _isGooglePlatformSupported {
    if (_googlePlatformSupportedOverride != null) {
      return _googlePlatformSupportedOverride;
    }

    if (kIsWeb) {
      return true;
    }

    return switch (_googleTargetPlatform) {
      TargetPlatform.android ||
      TargetPlatform.iOS ||
      TargetPlatform.macOS =>
        true,
      TargetPlatform.fuchsia ||
      TargetPlatform.linux ||
      TargetPlatform.windows =>
        false,
    };
  }

  Future<CalendarSyncSummary> fetchStatus() async {
    return CalendarSyncSummary(
      google: await getGoogleStatus(),
      naver: await getNaverStatus(),
    );
  }

  Future<CalendarSyncSummary> syncAll({
    bool interactiveGoogleSignIn = true,
  }) async {
    return CalendarSyncSummary(
      google: await syncGoogleCalendar(
        interactive: interactiveGoogleSignIn,
      ),
      naver: await syncNaverCalendar(),
    );
  }

  Future<CalendarIntegrationResult> getGoogleStatus() async {
    final configurationIssue = _googleConfigurationIssue;
    if (configurationIssue != null) {
      return CalendarIntegrationResult.notConfigured(
        CalendarProvider.google,
        message: configurationIssue,
      );
    }

    if (!_isGooglePlatformSupported) {
      return CalendarIntegrationResult.unsupported(
        CalendarProvider.google,
        message:
            'Google Calendar sign-in is not supported on this platform yet.',
      );
    }

    try {
      final account = await _googleSignInInstance.signInSilently(
        suppressErrors: true,
      );
      if (account == null) {
        return CalendarIntegrationResult.signedOut(
          CalendarProvider.google,
          message:
              'Google Calendar is configured, but the user has not signed in yet.',
        );
      }

      return CalendarIntegrationResult.ready(
        CalendarProvider.google,
        message: 'Google Calendar sign-in is available.',
      );
    } catch (error, stackTrace) {
      debugPrint('Google Calendar status check failed: $error');
      debugPrintStack(stackTrace: stackTrace);
      return CalendarIntegrationResult.failed(
        CalendarProvider.google,
        error: error,
        stackTrace: stackTrace,
        message: 'Google Calendar status could not be checked.',
      );
    }
  }

  Future<CalendarIntegrationResult> syncGoogleCalendar({
    bool interactive = true,
  }) async {
    final configurationIssue = _googleConfigurationIssue;
    if (configurationIssue != null) {
      return CalendarIntegrationResult.notConfigured(
        CalendarProvider.google,
        message: configurationIssue,
      );
    }

    if (!_isGooglePlatformSupported) {
      return CalendarIntegrationResult.unsupported(
        CalendarProvider.google,
        message: 'Google Calendar sync is not supported on this platform yet.',
      );
    }

    try {
      final account = interactive
          ? await _googleSignInInstance.signIn()
          : await _googleSignInInstance.signInSilently(
              suppressErrors: true,
            );

      if (account == null) {
        return CalendarIntegrationResult.signedOut(
          CalendarProvider.google,
          message:
              'Google Calendar sync needs a signed-in account before it can run.',
        );
      }

      final authentication = await account.authentication;
      final accessToken = authentication.accessToken;
      if (accessToken == null || accessToken.isEmpty) {
        return CalendarIntegrationResult.failed(
          CalendarProvider.google,
          error: StateError('Missing Google access token.'),
          message: 'Google Calendar access token was not available.',
        );
      }

      final credentials = gauth.AccessCredentials(
        gauth.AccessToken(
          'Bearer',
          accessToken,
          DateTime.now().toUtc().add(const Duration(minutes: 45)),
        ),
        null,
        _googleScopes,
        idToken: authentication.idToken,
      );

      final client = gauth.authenticatedClient(
        _httpClientFactory(),
        credentials,
      );

      try {
        final api = gcal.CalendarApi(client);
        final events = await api.events.list('primary', maxResults: 1);
        final syncedItems = events.items?.length ?? 0;

        return CalendarIntegrationResult.synced(
          CalendarProvider.google,
          message: 'Google Calendar scaffold request completed.',
          syncedItems: syncedItems,
        );
      } catch (error, stackTrace) {
        debugPrint('Google Calendar API sync failed: $error');
        debugPrintStack(stackTrace: stackTrace);
        return CalendarIntegrationResult.failed(
          CalendarProvider.google,
          error: error,
          stackTrace: stackTrace,
          message: 'Google Calendar sync scaffold could not complete.',
        );
      } finally {
        client.close();
      }
    } catch (error, stackTrace) {
      debugPrint('Google Calendar sign-in or sync failed: $error');
      debugPrintStack(stackTrace: stackTrace);
      return CalendarIntegrationResult.failed(
        CalendarProvider.google,
        error: error,
        stackTrace: stackTrace,
        message: 'Google Calendar sign-in or sync failed.',
      );
    }
  }

  Future<CalendarIntegrationResult> getNaverStatus() async {
    return CalendarIntegrationResult.unsupported(
      CalendarProvider.naver,
      message: 'Naver Calendar sync is not configured yet.',
    );
  }

  Future<CalendarIntegrationResult> syncNaverCalendar() async {
    return CalendarIntegrationResult.unsupported(
      CalendarProvider.naver,
      message:
          'Naver Calendar sync is currently a placeholder and is not available yet.',
    );
  }
}
