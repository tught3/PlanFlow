import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:googleapis/calendar/v3.dart' as gcal;
import 'package:googleapis_auth/googleapis_auth.dart' as gauth;
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/local_time.dart';
import '../data/models/calendar_connection_model.dart';
import '../data/models/event_model.dart';
import '../data/repositories/calendar_connection_repository.dart';
import '../data/repositories/event_repository.dart';
import 'naver_calendar_permission_service.dart';

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
  reauthRequired,
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
      message: message ?? '캘린더 연동 설정이 아직 없습니다.',
    );
  }

  factory CalendarIntegrationResult.signedOut(
    CalendarProvider provider, {
    String? message,
  }) {
    return CalendarIntegrationResult(
      provider: provider,
      status: CalendarIntegrationStatus.signedOut,
      message: message ?? '캘린더 동기화를 실행하려면 로그인이 필요합니다.',
    );
  }

  factory CalendarIntegrationResult.ready(
    CalendarProvider provider, {
    String? message,
  }) {
    return CalendarIntegrationResult(
      provider: provider,
      status: CalendarIntegrationStatus.ready,
      message: message ?? '캘린더 연동을 사용할 수 있습니다.',
    );
  }

  factory CalendarIntegrationResult.syncing(
    CalendarProvider provider, {
    String? message,
  }) {
    return CalendarIntegrationResult(
      provider: provider,
      status: CalendarIntegrationStatus.syncing,
      message: message ?? '캘린더 동기화 중입니다.',
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
      message: message ??
          (syncedItems > 0
              ? '캘린더 동기화가 완료되었습니다. $syncedItems개 일정을 반영했습니다.'
              : '캘린더 동기화가 완료되었습니다. 새로 반영할 일정은 없습니다.'),
      syncedItems: syncedItems,
    );
  }

  factory CalendarIntegrationResult.reauthRequired(
    CalendarProvider provider, {
    String? message,
  }) {
    return CalendarIntegrationResult(
      provider: provider,
      status: CalendarIntegrationStatus.reauthRequired,
      message: message ?? '캘린더 연결은 유지되어 있지만 다시 로그인이 필요합니다.',
    );
  }

  factory CalendarIntegrationResult.unsupported(
    CalendarProvider provider, {
    String? message,
  }) {
    return CalendarIntegrationResult(
      provider: provider,
      status: CalendarIntegrationStatus.unsupported,
      message: message ?? '이 캘린더 연동은 아직 지원하지 않습니다.',
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
      message: message ?? '캘린더 동기화에 실패했습니다.',
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

typedef GoogleAccessTokenProvider = Future<String?> Function({
  required bool interactive,
});

class GoogleCalendarEventEntry {
  const GoogleCalendarEventEntry({
    required this.calendarId,
    required this.event,
    this.isPrimaryCalendar = false,
  });

  final String calendarId;
  final gcal.Event event;
  final bool isPrimaryCalendar;

  String get normalizedCalendarId => isPrimaryCalendar ? 'primary' : calendarId;

  String get externalCalendarId => 'google:$normalizedCalendarId';

  String get stableExternalId {
    final rawId = event.id?.trim() ?? '';
    if (normalizedCalendarId == 'primary') {
      return rawId;
    }
    return '$normalizedCalendarId:$rawId';
  }
}

typedef GoogleCalendarEventsFetcher = Future<List<GoogleCalendarEventEntry>>
    Function(
  gcal.CalendarApi api,
);

typedef NaverCalendarStatusProvider = Future<NaverCalendarPermissionResult>
    Function();

typedef NaverCalendarAccessTokenProvider = Future<String?> Function();

typedef NaverCalendarStatusSaver = Future<void> Function(
  NaverCalendarPermissionStatus status,
);

class CalendarSyncService {
  CalendarSyncService({
    String? googleClientId,
    String? googleServerClientId,
    List<String> googleScopes = const <String>[
      gcal.CalendarApi.calendarEventsScope,
      gcal.CalendarApi.calendarReadonlyScope,
    ],
    GoogleSignIn? googleSignIn,
    EventRepository? eventRepository,
    CalendarConnectionRepository? calendarConnectionRepository,
    GoogleAccessTokenProvider? googleAccessTokenProvider,
    GoogleCalendarEventsFetcher? googleCalendarEventsFetcher,
    NaverCalendarPermissionService? naverPermissionService,
    NaverCalendarStatusProvider? naverStatusProvider,
    NaverCalendarAccessTokenProvider? naverAccessTokenProvider,
    NaverCalendarStatusSaver? naverStatusSaver,
    Uri? naverCreateScheduleUri,
    int naverExportLimit = 50,
    String? currentUserId,
    bool? googlePlatformSupported,
    TargetPlatform? googleTargetPlatform,
    http.Client Function()? httpClientFactory,
  })  : _googleClientId = googleClientId,
        _googleServerClientId = googleServerClientId,
        _googleScopes = List<String>.unmodifiable(googleScopes),
        _googleSignIn = googleSignIn,
        _eventRepositoryOverride = eventRepository,
        _calendarConnectionRepositoryOverride = calendarConnectionRepository,
        _googleAccessTokenProvider = googleAccessTokenProvider,
        _googleCalendarEventsFetcher =
            googleCalendarEventsFetcher ?? _defaultGoogleCalendarEventsFetcher,
        _naverPermissionServiceOverride = naverPermissionService,
        _naverStatusProvider = naverStatusProvider,
        _naverAccessTokenProvider = naverAccessTokenProvider,
        _naverStatusSaver = naverStatusSaver,
        _naverCreateScheduleUri = naverCreateScheduleUri ??
            Uri.parse('https://openapi.naver.com/calendar/createSchedule.json'),
        _naverExportLimit = naverExportLimit,
        _currentUserIdOverride = currentUserId,
        _googlePlatformSupportedOverride = googlePlatformSupported,
        _googleTargetPlatformOverride = googleTargetPlatform,
        _httpClientFactory = httpClientFactory ?? http.Client.new;

  final String? _googleClientId;
  final String? _googleServerClientId;
  final List<String> _googleScopes;
  final bool? _googlePlatformSupportedOverride;
  final TargetPlatform? _googleTargetPlatformOverride;
  final http.Client Function() _httpClientFactory;
  final EventRepository? _eventRepositoryOverride;
  final CalendarConnectionRepository? _calendarConnectionRepositoryOverride;
  final GoogleAccessTokenProvider? _googleAccessTokenProvider;
  final GoogleCalendarEventsFetcher _googleCalendarEventsFetcher;
  final NaverCalendarPermissionService? _naverPermissionServiceOverride;
  final NaverCalendarStatusProvider? _naverStatusProvider;
  final NaverCalendarAccessTokenProvider? _naverAccessTokenProvider;
  final NaverCalendarStatusSaver? _naverStatusSaver;
  final Uri _naverCreateScheduleUri;
  final int _naverExportLimit;
  final String? _currentUserIdOverride;

  GoogleSignIn? _googleSignIn;
  NaverCalendarPermissionService? _naverPermissionService;
  String? _lastGoogleAccountEmail;

  GoogleSignIn get _googleSignInInstance {
    return _googleSignIn ??= GoogleSignIn(
      scopes: _googleScopes,
      clientId: _isAndroidGoogleSignIn ? null : _googleClientId,
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

  EventRepository get _eventRepository {
    return _eventRepositoryOverride ?? EventRepository.supabase();
  }

  CalendarConnectionRepository get _calendarConnectionRepository {
    return _calendarConnectionRepositoryOverride ??
        CalendarConnectionRepository.supabase();
  }

  NaverCalendarPermissionService get _naverPermissionServiceInstance {
    return _naverPermissionServiceOverride ??
        (_naverPermissionService ??= NaverCalendarPermissionService());
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

  Future<void> disconnectProvider(
    CalendarProvider provider, {
    required bool deleteProviderEvents,
  }) async {
    final userId = _currentUserId();
    if (deleteProviderEvents) {
      final providerKey = _providerKey(provider);
      final events = await _eventRepository.listEvents(userId: userId);
      for (final event in events) {
        final isImportedProviderEvent = event.source == providerKey;
        final isLinkedProviderEvent =
            (event.externalCalendarId ?? '').startsWith('$providerKey:');
        if (isImportedProviderEvent || isLinkedProviderEvent) {
          await _eventRepository.deleteEvent(event.id, userId: userId);
        }
      }
    }

    await _calendarConnectionRepository.deleteConnection(
      userId: userId,
      provider: _providerKey(provider),
    );

    if (provider == CalendarProvider.google) {
      await _googleSignInInstance.signOut();
    }
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
        message: '현재 기기에서는 Google Calendar 로그인을 아직 지원하지 않습니다.',
      );
    }

    try {
      final connection = await _fetchConnection(CalendarProvider.google);
      if (connection == null || !connection.isConnected) {
        return CalendarIntegrationResult.signedOut(
          CalendarProvider.google,
          message: connection?.status == CalendarConnectionStatus.reauthRequired
              ? 'Google Calendar 다시 로그인이 필요합니다. 동기화를 눌러 Google 권한을 다시 확인해 주세요.'
              : 'Google Calendar가 현재 PlanFlow 계정에 연결되어 있지 않습니다.',
        );
      }
      final account = await _googleSignInInstance.signInSilently(
        suppressErrors: true,
      );
      if (account == null) {
        return CalendarIntegrationResult.ready(
          CalendarProvider.google,
          message:
              'Google Calendar  연결은 유지되어 있습니다. 현재 기기에서 구글 계정 캐시를 바로 불러오지 못했어도 연결 정보는 남아 있습니다.',
        );
      }

      return CalendarIntegrationResult.ready(
        CalendarProvider.google,
        message: 'Google Calendar 연결이 정상입니다.',
      );
    } catch (error, stackTrace) {
      debugPrint('Google Calendar status check failed: $error');
      debugPrintStack(stackTrace: stackTrace);
      return CalendarIntegrationResult.failed(
        CalendarProvider.google,
        error: error,
        stackTrace: stackTrace,
        message: 'Google Calendar 상태를 확인하지 못했습니다. OAuth 설정과 권한을 확인해 주세요.',
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
        message: '현재 기기에서는 Google Calendar 동기화를 아직 지원하지 않습니다.',
      );
    }

    try {
      final existingConnection =
          await _fetchConnection(CalendarProvider.google);
      if (!interactive &&
          (existingConnection == null || !existingConnection.isConnected)) {
        return CalendarIntegrationResult.signedOut(
          CalendarProvider.google,
          message: '현재 PlanFlow 계정에 Google Calendar가 연결되어 있지 않아 자동 동기화를 건너뜁니다.',
        );
      }

      if (interactive &&
          _googleAccessTokenProvider == null &&
          (existingConnection == null || !existingConnection.isConnected)) {
        // GoogleSignIn may reuse a device-cached account. Force account
        // selection when this PlanFlow user has no Google connection yet.
        await _googleSignInInstance.signOut();
      }

      final accessToken = await _fetchGoogleAccessToken(
        interactive: interactive,
      );
      if (accessToken == null || accessToken.isEmpty) {
        if (!interactive && existingConnection?.isConnected == true) {
          return CalendarIntegrationResult.reauthRequired(
            CalendarProvider.google,
            message:
                'Google Calendar 연결은 유지되어 있지만 현재 기기에서 자동 로그인 토큰을 바로 확인하지 못해 자동 동기화를 건너뜁니다. 필요하면 다시 동기화를 눌러 주세요.',
          );
        }
        await _saveConnection(
          CalendarProvider.google,
          status: CalendarConnectionStatus.reauthRequired,
          lastError: 'Google access token missing',
        );
        return CalendarIntegrationResult.signedOut(
          CalendarProvider.google,
          message:
              'Google 로그인 또는 Calendar 권한 동의가 완료되지 않았습니다. 다시 동기화를 눌러 계정과 권한을 확인해 주세요.',
        );
      }

      await _ensureSupabaseSessionForCalendarWrite();

      if (existingConnection?.providerAccountEmail != null &&
          _lastGoogleAccountEmail != null &&
          existingConnection!.providerAccountEmail != _lastGoogleAccountEmail) {
        await _saveConnection(
          CalendarProvider.google,
          status: CalendarConnectionStatus.reauthRequired,
          lastError: 'Google account changed',
        );
        return CalendarIntegrationResult.signedOut(
          CalendarProvider.google,
          message:
              '현재 PlanFlow 계정에 연결된 Google 계정과 선택한 Google 계정이 다릅니다. 연동 해제 후 다시 연결해 주세요.',
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
        idToken: null,
      );

      final client = gauth.authenticatedClient(
        _httpClientFactory(),
        credentials,
      );

      try {
        final api = gcal.CalendarApi(client);
        final googleEvents = await _googleCalendarEventsFetcher(api);
        final importedItems = await _persistGoogleEvents(googleEvents);
        final exportedItems = await _exportPlanFlowEventsToGoogle(api);
        final syncedItems = importedItems + exportedItems;
        await _saveConnection(
          CalendarProvider.google,
          status: CalendarConnectionStatus.connected,
          providerAccountEmail: _lastGoogleAccountEmail ??
              existingConnection?.providerAccountEmail,
          accessToken: accessToken,
          lastSyncedAt: DateTime.now().toUtc(),
        );

        return CalendarIntegrationResult.synced(
          CalendarProvider.google,
          message: syncedItems > 0
              ? 'Google Calendar 동기화가 완료되었습니다. $syncedItems개 일정을 가져왔습니다.'
              : 'Google Calendar 동기화가 완료되었습니다. 새로 가져온 일정은 없습니다.',
          syncedItems: syncedItems,
        );
      } catch (error, stackTrace) {
        await _saveConnection(
          CalendarProvider.google,
          status: CalendarConnectionStatus.failed,
          lastError: error.toString(),
        );
        debugPrint('Google Calendar API sync failed: $error');
        debugPrintStack(stackTrace: stackTrace);
        return CalendarIntegrationResult.failed(
          CalendarProvider.google,
          error: error,
          stackTrace: stackTrace,
          message: _googleApiFailureMessage(error),
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
        message: _googleSignInFailureMessage(error),
      );
    }
  }

  Future<CalendarIntegrationResult> exportEventToGoogle(
    EventModel event, {
    bool interactive = false,
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
        message: '현재 기기에서는 Google Calendar 동기화를 아직 지원하지 않습니다.',
      );
    }

    try {
      final existingConnection =
          await _fetchConnection(CalendarProvider.google);
      if (existingConnection == null || !existingConnection.isConnected) {
        return CalendarIntegrationResult.signedOut(
          CalendarProvider.google,
          message: '현재 PlanFlow 계정에 Google Calendar가 연결되어 있지 않아 내보내기를 건너뜁니다.',
        );
      }

      final accessToken = await _fetchGoogleAccessToken(
        interactive: interactive,
      );
      if (accessToken == null || accessToken.isEmpty) {
        if (!interactive) {
          return CalendarIntegrationResult.reauthRequired(
            CalendarProvider.google,
            message:
                'Google Calendar 연결은 유지되어 있지만 현재 기기에서 자동 로그인 토큰을 바로 확인하지 못해 내보내기를 건너뜁니다.',
          );
        }
        await _saveConnection(
          CalendarProvider.google,
          status: CalendarConnectionStatus.reauthRequired,
          lastError: 'Google access token missing during export',
        );
        return CalendarIntegrationResult.signedOut(
          CalendarProvider.google,
          message: 'Google Calendar 토큰을 확인하지 못해 내보내기를 건너뜁니다.',
        );
      }

      await _ensureSupabaseSessionForCalendarWrite();

      final credentials = gauth.AccessCredentials(
        gauth.AccessToken(
          'Bearer',
          accessToken,
          DateTime.now().toUtc().add(const Duration(minutes: 45)),
        ),
        null,
        _googleScopes,
        idToken: null,
      );
      final client = gauth.authenticatedClient(
        _httpClientFactory(),
        credentials,
      );
      try {
        final api = gcal.CalendarApi(client);
        final exported = await _exportPlanFlowEventToGoogle(api, event);
        await _saveConnection(
          CalendarProvider.google,
          status: CalendarConnectionStatus.connected,
          providerAccountEmail: _lastGoogleAccountEmail ??
              existingConnection.providerAccountEmail,
          accessToken: accessToken,
          lastSyncedAt: DateTime.now().toUtc(),
        );
        return CalendarIntegrationResult.synced(
          CalendarProvider.google,
          message: exported > 0
              ? 'Google Calendar로 일정을 내보냈습니다.'
              : 'Google Calendar로 내보낼 새 변경사항이 없습니다.',
          syncedItems: exported,
        );
      } finally {
        client.close();
      }
    } catch (error, stackTrace) {
      debugPrint('Google Calendar event export failed: $error');
      debugPrintStack(stackTrace: stackTrace);
      return CalendarIntegrationResult.failed(
        CalendarProvider.google,
        error: error,
        stackTrace: stackTrace,
        message: _googleApiFailureMessage(error),
      );
    }
  }

  Future<CalendarIntegrationResult> getNaverStatus() async {
    final connection = await _fetchConnection(CalendarProvider.naver);
    if (connection != null && connection.isConnected) {
      return CalendarIntegrationResult.ready(
        CalendarProvider.naver,
        message: connection.providerAccountEmail == null
            ? 'Naver Calendar가 현재 PlanFlow 계정에 연결되어 있습니다.'
            : 'Naver Calendar 연결됨: ${connection.providerAccountEmail}',
      );
    }

    final permission = await _refreshNaverStatus();
    if (permission.isGranted) {
      final token = await _resolveNaverAccessToken();
      await _saveConnection(
        CalendarProvider.naver,
        status: token == null || token.trim().isEmpty
            ? CalendarConnectionStatus.reauthRequired
            : CalendarConnectionStatus.connected,
        accessToken: token,
        lastError: token == null || token.trim().isEmpty
            ? 'Naver provider token missing'
            : null,
      );
      if (token != null && token.trim().isNotEmpty) {
        return CalendarIntegrationResult.ready(
          CalendarProvider.naver,
          message: 'Naver Calendar가 현재 PlanFlow 계정에 연결되어 있습니다.',
        );
      }
    }
    return switch (permission.status) {
      NaverCalendarPermissionStatus.granted => CalendarIntegrationResult.ready(
          CalendarProvider.naver,
          message: 'Naver Calendar 권한을 사용할 수 있습니다.',
        ),
      NaverCalendarPermissionStatus.denied =>
        CalendarIntegrationResult.signedOut(
          CalendarProvider.naver,
          message: 'Naver Calendar 권한 동의가 필요합니다. 동의 화면에서 캘린더 일정담기를 체크해 주세요.',
        ),
      NaverCalendarPermissionStatus.networkError =>
        CalendarIntegrationResult.failed(
          CalendarProvider.naver,
          error: permission.error ?? permission.message,
          message: permission.message,
        ),
      NaverCalendarPermissionStatus.unknown =>
        CalendarIntegrationResult.signedOut(
          CalendarProvider.naver,
          message: 'Naver Calendar 연결 상태를 확인하려면 네이버 권한 동의가 필요합니다.',
        ),
    };
  }

  Future<CalendarIntegrationResult> syncNaverCalendar() async {
    try {
      final permission = await _refreshNaverStatus();
      if (!permission.isGranted) {
        if (permission.isNetworkError) {
          return CalendarIntegrationResult.failed(
            CalendarProvider.naver,
            error: permission.error ?? permission.message,
            message: permission.message,
          );
        }
        return CalendarIntegrationResult.signedOut(
          CalendarProvider.naver,
          message: 'Naver Calendar 권한이 필요합니다. 네이버 동의 화면에서 캘린더 일정담기를 체크해 주세요.',
        );
      }

      final accessToken = await _resolveNaverAccessToken();
      if (accessToken == null || accessToken.trim().isEmpty) {
        await _saveConnection(
          CalendarProvider.naver,
          status: CalendarConnectionStatus.reauthRequired,
          lastError: 'Naver provider token missing',
        );
        return CalendarIntegrationResult.signedOut(
          CalendarProvider.naver,
          message: 'Naver Calendar 토큰을 확인하지 못했습니다. 네이버 캘린더 권한 동의를 다시 진행해 주세요.',
        );
      }

      await _ensureSupabaseSessionForCalendarWrite();

      final events = await _eventsForNaverExport();
      if (events.isEmpty) {
        return CalendarIntegrationResult.synced(
          CalendarProvider.naver,
          message: 'Naver Calendar로 보낼 예정 일정이 없습니다.',
        );
      }

      final client = _httpClientFactory();
      var syncedItems = 0;
      try {
        for (final event in events) {
          final response = await client.post(
            _naverCreateScheduleUri,
            headers: <String, String>{
              HttpHeaders.authorizationHeader: 'Bearer $accessToken',
              HttpHeaders.contentTypeHeader:
                  'application/x-www-form-urlencoded; charset=utf-8',
            },
            body: <String, String>{
              'calendarId': 'defaultCalendarId',
              'scheduleIcalString': buildNaverScheduleIcal(event),
            },
          ).timeout(const Duration(seconds: 10));

          if (response.statusCode == 401 || response.statusCode == 403) {
            await _saveNaverStatus(NaverCalendarPermissionStatus.denied);
            throw _NaverCalendarSyncException(
              'Naver Calendar 권한이 만료되었거나 부족합니다. 다시 권한 동의를 진행해 주세요.',
              statusCode: response.statusCode,
              body: response.body,
            );
          }
          if (response.statusCode < 200 || response.statusCode >= 400) {
            throw _NaverCalendarSyncException(
              'Naver Calendar 일정 저장에 실패했습니다. 네이버 API 응답을 확인해 주세요.',
              statusCode: response.statusCode,
              body: response.body,
            );
          }
          await _markEventSyncedToNaver(event);
          syncedItems += 1;
        }
      } finally {
        client.close();
      }

      await _saveConnection(
        CalendarProvider.naver,
        status: CalendarConnectionStatus.connected,
        accessToken: accessToken,
        lastSyncedAt: DateTime.now().toUtc(),
      );

      return CalendarIntegrationResult.synced(
        CalendarProvider.naver,
        message: 'Naver Calendar에 $syncedItems개 일정을 반영했습니다.',
        syncedItems: syncedItems,
      );
    } catch (error, stackTrace) {
      debugPrint('Naver Calendar sync failed: $error');
      debugPrintStack(stackTrace: stackTrace);
      return CalendarIntegrationResult.failed(
        CalendarProvider.naver,
        error: error,
        stackTrace: stackTrace,
        message: error is _NaverCalendarSyncException
            ? error.message
            : 'Naver Calendar 동기화에 실패했습니다. 네이버 권한과 네트워크 상태를 확인해 주세요.',
      );
    }
  }

  Future<List<EventModel>> _eventsForNaverExport() async {
    final now = DateTime.now();
    final lowerBound = now.subtract(const Duration(days: 1));
    final events = await _eventRepository.listEvents(userId: _currentUserId());
    final filtered = events
        .where((event) => event.startAt != null)
        .where((event) => !event.startAt!.isBefore(lowerBound))
        .where((event) => !_isExternalCalendarSource(event.source))
        .where((event) {
      if (event.externalCalendarId != 'naver:default') {
        return true;
      }
      final lastSyncedAt = event.lastSyncedAt;
      final updatedAt = event.updatedAt;
      if (lastSyncedAt == null || updatedAt == null) {
        return true;
      }
      return updatedAt.toUtc().isAfter(lastSyncedAt.toUtc());
    }).toList()
      ..sort((a, b) => a.startAt!.compareTo(b.startAt!));
    return filtered.take(_naverExportLimit).toList(growable: false);
  }

  Future<CalendarConnectionModel?> _fetchConnection(
    CalendarProvider provider,
  ) async {
    try {
      return await _calendarConnectionRepository.fetchConnection(
        userId: _currentUserId(),
        provider: _providerKey(provider),
      );
    } catch (error, stackTrace) {
      debugPrint('Calendar connection fetch skipped: $error');
      debugPrintStack(stackTrace: stackTrace);
      return null;
    }
  }

  Future<void> _saveConnection(
    CalendarProvider provider, {
    required CalendarConnectionStatus status,
    String? providerAccountEmail,
    String? accessToken,
    String? refreshToken,
    DateTime? lastSyncedAt,
    String? lastError,
  }) async {
    try {
      final existing = await _fetchConnection(provider);
      await _calendarConnectionRepository.upsertConnection(
        CalendarConnectionModel(
          userId: _currentUserId(),
          provider: _providerKey(provider),
          providerAccountEmail:
              providerAccountEmail ?? existing?.providerAccountEmail,
          status: status,
          accessToken: accessToken ?? existing?.accessToken,
          refreshToken: refreshToken ?? existing?.refreshToken,
          lastSyncedAt: lastSyncedAt ?? existing?.lastSyncedAt,
          lastError: lastError,
        ),
      );
    } catch (error, stackTrace) {
      debugPrint('Calendar connection save skipped: $error');
      debugPrintStack(stackTrace: stackTrace);
    }
  }

  String _providerKey(CalendarProvider provider) {
    return switch (provider) {
      CalendarProvider.google => 'google',
      CalendarProvider.naver => 'naver',
    };
  }

  Future<int> _exportPlanFlowEventsToGoogle(gcal.CalendarApi api) async {
    final now = DateTime.now().toUtc();
    final lowerBound = now.subtract(const Duration(days: 1));
    final events = await _eventRepository.listEvents(userId: _currentUserId());
    var exportedItems = 0;

    for (final event in events) {
      final startAt = event.startAt;
      if (startAt == null || startAt.isBefore(lowerBound)) {
        continue;
      }
      if (_isExternalCalendarSource(event.source)) {
        continue;
      }

      final externalCalendarId = event.externalCalendarId ?? '';
      final externalId = event.externalId ?? '';
      if (externalId.isNotEmpty &&
          externalCalendarId.isNotEmpty &&
          externalCalendarId != 'google:primary') {
        continue;
      }
      if (externalId.isNotEmpty &&
          event.externalUpdatedAt != null &&
          event.updatedAt != null &&
          event.externalUpdatedAt!.toUtc().isAfter(event.updatedAt!.toUtc())) {
        debugPrint(
          'Google export skipped because external event is newer: ${event.id}',
        );
        continue;
      }

      exportedItems += await _exportPlanFlowEventToGoogle(api, event);
    }

    return exportedItems;
  }

  Future<int> _exportPlanFlowEventToGoogle(
    gcal.CalendarApi api,
    EventModel event,
  ) async {
    final now = DateTime.now().toUtc();
    final lowerBound = now.subtract(const Duration(days: 1));
    final startAt = event.startAt;
    if (startAt == null || startAt.isBefore(lowerBound)) {
      return 0;
    }
    if (_isExternalCalendarSource(event.source)) {
      return 0;
    }

    final externalCalendarId = event.externalCalendarId ?? '';
    final externalId = event.externalId ?? '';
    if (externalId.isNotEmpty &&
        externalCalendarId.isNotEmpty &&
        externalCalendarId != 'google:primary') {
      return 0;
    }
    if (externalId.isNotEmpty &&
        event.externalUpdatedAt != null &&
        event.updatedAt != null &&
        event.externalUpdatedAt!.toUtc().isAfter(event.updatedAt!.toUtc())) {
      debugPrint(
        'Google export skipped because external event is newer: ${event.id}',
      );
      return 0;
    }

    final googleEvent = _eventToGoogleEvent(event);
    final gcal.Event saved;
    if (externalId.isEmpty) {
      saved = await api.events.insert(googleEvent, 'primary');
    } else {
      saved = await api.events.update(googleEvent, 'primary', externalId);
    }

    final savedExternalId = saved.id?.trim();
    if (savedExternalId != null && savedExternalId.isNotEmpty) {
      await _eventRepository.updateEvent(
        EventModel(
          id: event.id,
          userId: event.userId,
          title: event.title,
          startAt: event.startAt,
          endAt: event.endAt,
          location: event.location,
          locationLat: event.locationLat,
          locationLng: event.locationLng,
          memo: event.memo,
          supplies: event.supplies,
          suppliesChecked: event.suppliesChecked,
          participants: event.participants,
          targets: event.targets,
          isCritical: event.isCritical,
          recurrenceRule: event.recurrenceRule,
          isAllDay: event.isAllDay,
          isMultiDay: event.isMultiDay,
          parentEventId: event.parentEventId,
          category: event.category,
          source: event.source,
          externalId: savedExternalId,
          externalCalendarId: 'google:primary',
          externalUpdatedAt: saved.updated?.toUtc() ?? now,
          lastSyncedAt: now,
          createdAt: event.createdAt,
          updatedAt: event.updatedAt,
        ),
      );
    }
    return 1;
  }

  Future<void> _markEventSyncedToNaver(EventModel event) async {
    final now = DateTime.now().toUtc();
    await _eventRepository.updateEvent(
      EventModel(
        id: event.id,
        userId: event.userId,
        title: event.title,
        startAt: event.startAt,
        endAt: event.endAt,
        location: event.location,
        locationLat: event.locationLat,
        locationLng: event.locationLng,
        memo: event.memo,
        supplies: event.supplies,
        suppliesChecked: event.suppliesChecked,
        participants: event.participants,
        targets: event.targets,
        isCritical: event.isCritical,
        recurrenceRule: event.recurrenceRule,
        isAllDay: event.isAllDay,
        isMultiDay: event.isMultiDay,
        parentEventId: event.parentEventId,
        category: event.category,
        source: event.source,
        externalId: _naverEventUid(event),
        externalCalendarId: 'naver:default',
        externalUpdatedAt: now,
        lastSyncedAt: now,
        createdAt: event.createdAt,
        updatedAt: event.updatedAt,
      ),
    );
  }

  String _naverEventUid(EventModel event) {
    final id = event.id.trim();
    if (id.isNotEmpty) {
      return 'planflow-$id@planflow';
    }
    final startAt = event.startAt?.toIso8601String() ?? 'no-start';
    return 'planflow-${event.userId}-${event.title}-$startAt@planflow';
  }

  @visibleForTesting
  static gcal.Event buildGoogleExportEventForTest(EventModel event) {
    final startAt = event.startAt!;
    final endAt = event.endAt ?? startAt.add(const Duration(minutes: 30));
    return gcal.Event(
      summary: event.title,
      description: event.memo,
      location: event.location,
      start: gcal.EventDateTime(dateTime: startAt.toUtc()),
      end: gcal.EventDateTime(dateTime: endAt.toUtc()),
      extendedProperties: gcal.EventExtendedProperties(
        private: <String, String>{
          'planflow_event_id': event.id,
        },
      ),
      reminders: gcal.EventReminders(
        useDefault: false,
        overrides: const <gcal.EventReminder>[],
      ),
    );
  }

  gcal.Event _eventToGoogleEvent(EventModel event) {
    return buildGoogleExportEventForTest(event);
  }

  Future<NaverCalendarPermissionResult> _refreshNaverStatus() {
    final provider = _naverStatusProvider;
    if (provider != null) {
      return provider();
    }
    return _naverPermissionServiceInstance.refreshStatus();
  }

  Future<String?> _resolveNaverAccessToken() {
    final provider = _naverAccessTokenProvider;
    if (provider != null) {
      return provider();
    }
    return _naverPermissionServiceInstance.resolveAccessTokenForCalendar();
  }

  Future<void> _saveNaverStatus(NaverCalendarPermissionStatus status) {
    final saver = _naverStatusSaver;
    if (saver != null) {
      return saver(status);
    }
    return _naverPermissionServiceInstance.saveStatus(status);
  }

  String _googleApiFailureMessage(Object error) {
    if (error is StateError) {
      return 'Google Calendar 일정을 저장하려면 PlanFlow 로그인이 필요합니다.';
    }

    final errorText = error.toString().toLowerCase();
    if (errorText.contains('row-level security') ||
        errorText.contains('42501')) {
      return 'Google Calendar 인증은 완료됐지만 Supabase 일정 저장 정책(RLS)에 막혔습니다. Supabase SQL 스키마와 events INSERT 정책을 적용해 주세요.';
    }

    if (errorText.contains('insufficient') ||
        errorText.contains('insufficientpermissions') ||
        errorText.contains('insufficient authentication scopes') ||
        errorText.contains('insufficient permission') ||
        errorText.contains('permission') ||
        errorText.contains('forbidden') ||
        errorText.contains('unauthorized') ||
        errorText.contains('401') ||
        errorText.contains('403')) {
      return 'Google Calendar 권한이 부족해 동기화하지 못했습니다. Google Calendar 연결을 다시 눌러 전체 캘린더 목록 읽기 권한을 다시 동의해 주세요.';
    }

    return 'Google Calendar API 호출에 실패했습니다. Google Cloud Calendar API 사용 설정과 네트워크 상태를 확인해 주세요.';
  }

  String _googleSignInFailureMessage(Object error) {
    if (error is PlatformException) {
      final code = error.code.toLowerCase();
      final message = (error.message ?? '').toLowerCase();
      final details = error.details?.toString().toLowerCase() ?? '';
      final combined = '$code $message $details';

      if (combined.contains('canceled') ||
          combined.contains('cancelled') ||
          combined.contains('12501')) {
        return 'Google 로그인이 취소되었습니다. 다시 동기화를 눌러 Google 계정과 Calendar 권한 동의를 완료해 주세요.';
      }

      if (combined.contains('network')) {
        return 'Google 로그인 네트워크 연결에 실패했습니다. 인터넷 연결을 확인한 뒤 다시 시도해 주세요.';
      }

      if (combined.contains('developer_error') ||
          combined.contains('api_exception: 10') ||
          combined.contains('12500') ||
          combined.contains('sign_in_failed')) {
        return 'Google OAuth 설정이 맞지 않아 로그인하지 못했습니다. Web OAuth Client ID, Android SHA 지문, Calendar API 사용 설정을 확인해 주세요.';
      }
    }

    final errorText = error.toString().toLowerCase();
    if (errorText.contains('token') || errorText.contains('authentication')) {
      return 'Google 인증 토큰을 받지 못했습니다. Google 계정과 Calendar 권한 동의를 다시 확인해 주세요.';
    }

    return 'Google OAuth 로그인 또는 권한 승인에 실패했습니다. Google 계정, Calendar 권한 동의, OAuth 설정을 확인해 주세요.';
  }

  Future<String?> _fetchGoogleAccessToken({
    required bool interactive,
  }) async {
    final provider = _googleAccessTokenProvider;
    if (provider != null) {
      return provider(interactive: interactive);
    }

    final account = interactive
        ? await _googleSignInInstance.signIn()
        : await _googleSignInInstance.signInSilently(
            suppressErrors: true,
          );

    if (account == null) {
      return null;
    }

    _lastGoogleAccountEmail = account.email;
    final authentication = await account.authentication;
    return authentication.accessToken;
  }

  Future<int> _persistGoogleEvents(
    List<GoogleCalendarEventEntry> googleEvents,
  ) async {
    var syncedItems = 0;
    for (final entry in googleEvents) {
      final googleEvent = entry.event;
      final externalId = googleEvent.id?.trim() ?? '';
      if (externalId.isEmpty) {
        continue;
      }

      final storedExternalId = entry.stableExternalId;
      final model = _mapGoogleEvent(
        googleEvent,
        externalId: storedExternalId,
        externalCalendarId: entry.externalCalendarId,
      );
      final existing = await _findExistingGoogleEvent(
        storedExternalId,
        externalCalendarId: entry.externalCalendarId,
      );
      if (existing != null && _shouldKeepLocalEvent(existing, model)) {
        continue;
      }
      if (existing != null) {
        await _eventRepository.updateEvent(
          EventModel(
            id: existing.id,
            userId: existing.userId,
            title: model.title,
            startAt: model.startAt,
            endAt: model.endAt,
            location: model.location,
            locationLat: existing.locationLat,
            locationLng: existing.locationLng,
            memo: model.memo,
            supplies: existing.supplies,
            suppliesChecked: existing.suppliesChecked,
            participants: existing.participants,
            targets: existing.targets,
            isCritical: existing.isCritical,
            recurrenceRule: existing.recurrenceRule,
            isAllDay: existing.isAllDay,
            isMultiDay: existing.isMultiDay,
            parentEventId: existing.parentEventId,
            category: existing.category,
            source: existing.source,
            externalId: storedExternalId,
            externalCalendarId: entry.externalCalendarId,
            externalUpdatedAt: model.externalUpdatedAt,
            lastSyncedAt: model.lastSyncedAt,
            createdAt: existing.createdAt,
            updatedAt: existing.updatedAt,
          ),
        );
      } else {
        final planFlowEventId = _planFlowEventIdFromGoogleEvent(googleEvent);
        final planFlowOrigin = planFlowEventId == null
            ? null
            : await _eventRepository.fetchEvent(
                planFlowEventId,
                userId: _currentUserId(),
              );
        if (planFlowOrigin != null) {
          final linked =
              await _eventRepository.attachExternalSyncMetadataIfCompatible(
            existing: planFlowOrigin,
            incoming: model,
          );
          debugPrint(
            'Google import reflected PlanFlow event handled: '
            'incoming="${model.title}" ${model.startAt} '
            'existing=${planFlowOrigin.id} linked=${linked != null}',
          );
          syncedItems += 1;
          continue;
        }

        final duplicate = await _findSameTitleStartDuplicate(
          model,
          excludedSources: const <String>{'google'},
        );
        if (duplicate != null) {
          final linked =
              await _eventRepository.attachExternalSyncMetadataIfCompatible(
            existing: duplicate,
            incoming: model,
          );
          debugPrint(
            'Google import duplicate handled by title/start: '
            'incoming="${model.title}" ${model.startAt} '
            'existing=${duplicate.id} source=${duplicate.source} '
            'linked=${linked != null}',
          );
          syncedItems += 1;
          continue;
        }
        await _eventRepository.upsertEventBySourceExternalId(model);
      }
      syncedItems += 1;
    }
    return syncedItems;
  }

  Future<EventModel?> _findExistingGoogleEvent(
    String externalId, {
    required String externalCalendarId,
  }) async {
    final imported = await _eventRepository.fetchEventBySourceExternalId(
      source: 'google',
      externalId: externalId,
      userId: _currentUserId(),
    );
    if (imported != null) {
      return imported;
    }

    final events = await _eventRepository.listEvents(userId: _currentUserId());
    for (final event in events) {
      if (event.externalId == externalId &&
          event.externalCalendarId == externalCalendarId) {
        return event;
      }
    }
    return null;
  }

  Future<EventModel?> _findSameTitleStartDuplicate(
    EventModel incoming, {
    Set<String> excludedSources = const <String>{},
  }) async {
    final startAt = incoming.startAt;
    if (startAt == null) {
      return null;
    }
    return _eventRepository.findEventByTitleAndStart(
      title: incoming.title,
      startAt: startAt,
      userId: _currentUserId(),
      excludedSources: excludedSources,
    );
  }

  bool _shouldKeepLocalEvent(EventModel local, EventModel external) {
    final localUpdatedAt = local.updatedAt ?? local.createdAt;
    final externalUpdatedAt = external.externalUpdatedAt;
    if (localUpdatedAt == null || externalUpdatedAt == null) {
      return false;
    }
    return localUpdatedAt.toUtc().isAfter(externalUpdatedAt.toUtc());
  }

  EventModel _mapGoogleEvent(
    gcal.Event event, {
    required String externalId,
    required String externalCalendarId,
  }) {
    return EventModel(
      id: '',
      userId: _currentUserId(),
      title: _googleEventTitle(event),
      startAt: _googleEventDateTime(event.start),
      endAt: _googleEventDateTime(event.end, isEnd: true),
      location: _googleStringValue(event.location),
      memo: _googleStringValue(event.description),
      supplies: const <String>[],
      isCritical: false,
      source: 'google',
      externalId: externalId,
      externalCalendarId: externalCalendarId,
      externalUpdatedAt: event.updated?.toUtc(),
      lastSyncedAt: DateTime.now().toUtc(),
    );
  }

  String _googleEventTitle(gcal.Event event) {
    final summary = _googleStringValue(event.summary);
    if (summary.isNotEmpty) {
      return summary;
    }

    final location = _googleStringValue(event.location);
    if (location.isNotEmpty) {
      return location;
    }

    return 'Google Calendar 일정';
  }

  DateTime? _googleEventDateTime(
    gcal.EventDateTime? value, {
    bool isEnd = false,
  }) {
    if (value == null) {
      return null;
    }

    final dateTime = value.dateTime;
    if (dateTime != null) {
      return dateTime.toUtc();
    }

    final date = value.date;
    if (date == null) {
      return null;
    }

    final dateOnly = DateTime.utc(date.year, date.month, date.day);
    if (isEnd) {
      return dateOnly.add(const Duration(days: 1));
    }
    return dateOnly;
  }

  String _googleStringValue(Object? value) {
    return value?.toString().trim() ?? '';
  }

  String? _planFlowEventIdFromGoogleEvent(gcal.Event event) {
    final id = event.extendedProperties?.private?['planflow_event_id']?.trim();
    if (id == null || id.isEmpty) {
      return null;
    }
    return id;
  }

  bool _isExternalCalendarSource(String source) {
    return source == 'google' ||
        source == 'naver' ||
        source == 'naver_caldav' ||
        source == 'naver_device' ||
        source == 'device_calendar';
  }

  String _currentUserId() {
    final override = _currentUserIdOverride;
    if (override != null && override.isNotEmpty) {
      return override;
    }

    String? userId;
    try {
      final auth = Supabase.instance.client.auth;
      userId = auth.currentSession?.user.id ?? auth.currentUser?.id;
    } catch (error) {
      debugPrint('Calendar current user lookup failed: $error');
    }

    if (userId == null || userId.isEmpty) {
      throw StateError('캘린더 일정을 동기화하려면 로그인된 사용자가 필요합니다.');
    }
    return userId;
  }

  Future<void> _ensureSupabaseSessionForCalendarWrite() async {
    if (_currentUserIdOverride != null) {
      return;
    }

    final auth = Supabase.instance.client.auth;
    if (auth.currentSession == null) {
      throw StateError('캘린더 일정을 저장하려면 PlanFlow 로그인이 필요합니다.');
    }

    try {
      await auth.getUser();
      return;
    } catch (error) {
      debugPrint('Calendar Supabase user check failed: $error');
    }

    try {
      await auth.refreshSession();
      await auth.getUser();
    } catch (error) {
      debugPrint('Calendar Supabase session refresh failed: $error');
      throw StateError(
        'PlanFlow 로그인 세션을 확인하지 못했습니다. 로그아웃 후 다시 로그인해 주세요.',
      );
    }
  }

  static Future<List<GoogleCalendarEventEntry>>
      _defaultGoogleCalendarEventsFetcher(
    gcal.CalendarApi api,
  ) async {
    final entries = <GoogleCalendarEventEntry>[];
    final calendars = await _fetchReadableGoogleCalendars(api);

    if (calendars.isEmpty) {
      calendars.add(
        gcal.CalendarListEntry()
          ..id = 'primary'
          ..summary = 'Primary'
          ..accessRole = 'owner',
      );
    }

    for (final calendar in calendars) {
      final calendarId = calendar.id?.trim();
      if (calendarId == null || calendarId.isEmpty) {
        continue;
      }

      entries.addAll(
        await _fetchGoogleEventsForCalendar(
          api,
          calendarId,
          isPrimaryCalendar: calendar.primary == true,
        ),
      );
    }

    return entries;
  }

  static Future<List<gcal.CalendarListEntry>> _fetchReadableGoogleCalendars(
    gcal.CalendarApi api,
  ) async {
    final calendars = <gcal.CalendarListEntry>[];
    String? pageToken;

    do {
      final response = await api.calendarList.list(
        pageToken: pageToken,
        maxResults: 250,
        showDeleted: false,
        showHidden: false,
      );

      for (final calendar
          in response.items ?? const <gcal.CalendarListEntry>[]) {
        final calendarId = calendar.id?.trim();
        final accessRole = calendar.accessRole?.trim();
        if (calendarId == null || calendarId.isEmpty) {
          continue;
        }
        if (accessRole == 'freeBusyReader') {
          continue;
        }
        calendars.add(calendar);
      }
      pageToken = response.nextPageToken;
    } while (pageToken != null && pageToken.isNotEmpty);

    calendars.sort((a, b) {
      final aPrimary = a.primary == true ? 0 : 1;
      final bPrimary = b.primary == true ? 0 : 1;
      if (aPrimary != bPrimary) {
        return aPrimary.compareTo(bPrimary);
      }
      return (a.summary ?? a.id ?? '').compareTo(b.summary ?? b.id ?? '');
    });

    return calendars;
  }

  static Future<List<GoogleCalendarEventEntry>> _fetchGoogleEventsForCalendar(
    gcal.CalendarApi api,
    String calendarId, {
    bool isPrimaryCalendar = false,
  }) async {
    final entries = <GoogleCalendarEventEntry>[];
    String? pageToken;

    do {
      final response = await api.events.list(
        calendarId,
        pageToken: pageToken,
        maxResults: 250,
        singleEvents: true,
        orderBy: 'startTime',
        showDeleted: false,
        timeMin: DateTime.now().toUtc().subtract(const Duration(days: 1)),
      );

      for (final event in response.items ?? const <gcal.Event>[]) {
        entries.add(
          GoogleCalendarEventEntry(
            calendarId: calendarId,
            isPrimaryCalendar: isPrimaryCalendar,
            event: event,
          ),
        );
      }
      pageToken = response.nextPageToken;
    } while (pageToken != null && pageToken.isNotEmpty);

    return entries;
  }

  @visibleForTesting
  static String buildNaverScheduleIcal(EventModel event) {
    final startAt = event.startAt;
    if (startAt == null) {
      throw ArgumentError.value(event.startAt, 'event.startAt');
    }
    final endAt = event.endAt ?? startAt.add(const Duration(minutes: 30));
    final now = DateTime.now().toUtc();
    final uid =
        'planflow-${event.id.trim().isNotEmpty ? event.id.trim() : '${event.userId}-${event.title}-${startAt.toIso8601String()}'}@planflow';

    return [
      'BEGIN:VCALENDAR',
      'VERSION:2.0',
      'PRODID:-//PlanFlow//PlanFlow Calendar//KO',
      'CALSCALE:GREGORIAN',
      'BEGIN:VEVENT',
      'UID:${_escapeIcalText(uid)}',
      'SEQUENCE:0',
      'CLASS:PUBLIC',
      'TRANSP:OPAQUE',
      'SUMMARY:${_escapeIcalText(event.title)}',
      'DTSTART;TZID=Asia/Seoul:${_formatNaverLocalDateTime(startAt)}',
      'DTEND;TZID=Asia/Seoul:${_formatNaverLocalDateTime(endAt)}',
      if ((event.memo ?? '').trim().isNotEmpty)
        'DESCRIPTION:${_escapeIcalText(event.memo!.trim())}',
      if ((event.location ?? '').trim().isNotEmpty)
        'LOCATION:${_escapeIcalText(event.location!.trim())}',
      'CREATED:${_formatNaverUtcDateTime(event.createdAt ?? now)}',
      'DTSTAMP:${_formatNaverUtcDateTime(now)}',
      'LAST-MODIFIED:${_formatNaverUtcDateTime(now)}',
      'PRIORITY:${event.isCritical ? 1 : 0}',
      'END:VEVENT',
      'END:VCALENDAR',
    ].join('\r\n');
  }

  static String _formatNaverLocalDateTime(DateTime value) {
    final local = planflowLocal(value);
    return '${local.year.toString().padLeft(4, '0')}'
        '${local.month.toString().padLeft(2, '0')}'
        '${local.day.toString().padLeft(2, '0')}T'
        '${local.hour.toString().padLeft(2, '0')}'
        '${local.minute.toString().padLeft(2, '0')}'
        '${local.second.toString().padLeft(2, '0')}';
  }

  static String _formatNaverUtcDateTime(DateTime value) {
    final utc = value.toUtc();
    return '${utc.year.toString().padLeft(4, '0')}'
        '${utc.month.toString().padLeft(2, '0')}'
        '${utc.day.toString().padLeft(2, '0')}T'
        '${utc.hour.toString().padLeft(2, '0')}'
        '${utc.minute.toString().padLeft(2, '0')}'
        '${utc.second.toString().padLeft(2, '0')}Z';
  }

  static String _escapeIcalText(String value) {
    return value
        .replaceAll(r'\', r'\\')
        .replaceAll('\n', r'\n')
        .replaceAll('\r', '')
        .replaceAll(';', r'\;')
        .replaceAll(',', r'\,');
  }
}

class _NaverCalendarSyncException implements Exception {
  const _NaverCalendarSyncException(
    this.message, {
    this.statusCode,
    this.body,
  });

  final String message;
  final int? statusCode;
  final String? body;

  @override
  String toString() {
    return 'NaverCalendarSyncException(statusCode: $statusCode, message: $message, body: $body)';
  }
}
