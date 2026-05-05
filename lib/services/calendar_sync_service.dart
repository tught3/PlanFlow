import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:googleapis/calendar/v3.dart' as gcal;
import 'package:googleapis_auth/googleapis_auth.dart' as gauth;
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../data/models/event_model.dart';
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

typedef GoogleCalendarEventsFetcher = Future<List<gcal.Event>> Function(
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
    ],
    GoogleSignIn? googleSignIn,
    EventRepository? eventRepository,
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
      final account = await _googleSignInInstance.signInSilently(
        suppressErrors: true,
      );
      if (account == null) {
        return CalendarIntegrationResult.signedOut(
          CalendarProvider.google,
          message: 'Google Calendar 설정은 있지만 Google 계정 로그인이 필요합니다.',
        );
      }

      return CalendarIntegrationResult.ready(
        CalendarProvider.google,
        message: 'Google Calendar 로그인을 사용할 수 있습니다.',
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
      final accessToken = await _fetchGoogleAccessToken(
        interactive: interactive,
      );
      if (accessToken == null || accessToken.isEmpty) {
        return CalendarIntegrationResult.signedOut(
          CalendarProvider.google,
          message:
              'Google 로그인 또는 Calendar 권한 동의가 완료되지 않았습니다. 다시 동기화를 눌러 계정과 권한을 확인해 주세요.',
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
        final syncedItems = await _persistGoogleEvents(googleEvents);

        return CalendarIntegrationResult.synced(
          CalendarProvider.google,
          message: syncedItems > 0
              ? 'Google Calendar 동기화가 완료되었습니다. $syncedItems개 일정을 가져왔습니다.'
              : 'Google Calendar 동기화가 완료되었습니다. 새로 가져온 일정은 없습니다.',
          syncedItems: syncedItems,
        );
      } catch (error, stackTrace) {
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

  Future<CalendarIntegrationResult> getNaverStatus() async {
    final permission = await _refreshNaverStatus();
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
        return CalendarIntegrationResult.signedOut(
          CalendarProvider.naver,
          message: 'Naver Calendar 토큰을 확인하지 못했습니다. 네이버 캘린더 권한 동의를 다시 진행해 주세요.',
        );
      }

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
          syncedItems += 1;
        }
      } finally {
        client.close();
      }

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
        .toList()
      ..sort((a, b) => a.startAt!.compareTo(b.startAt!));
    return filtered.take(_naverExportLimit).toList(growable: false);
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
    if (errorText.contains('insufficient') ||
        errorText.contains('permission') ||
        errorText.contains('forbidden') ||
        errorText.contains('unauthorized') ||
        errorText.contains('401') ||
        errorText.contains('403')) {
      return 'Google Calendar 권한이 부족해 동기화하지 못했습니다. Calendar 권한 동의를 다시 확인해 주세요.';
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

    final authentication = await account.authentication;
    return authentication.accessToken;
  }

  Future<int> _persistGoogleEvents(List<gcal.Event> googleEvents) async {
    var syncedItems = 0;
    for (final googleEvent in googleEvents) {
      final externalId = googleEvent.id?.trim() ?? '';
      if (externalId.isEmpty) {
        continue;
      }

      final model = _mapGoogleEvent(
        googleEvent,
        externalId: externalId,
      );
      await _eventRepository.upsertEventBySourceExternalId(model);
      syncedItems += 1;
    }
    return syncedItems;
  }

  EventModel _mapGoogleEvent(
    gcal.Event event, {
    required String externalId,
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

  String _currentUserId() {
    final userId =
        _currentUserIdOverride ?? Supabase.instance.client.auth.currentUser?.id;
    if (userId == null || userId.isEmpty) {
      throw StateError('캘린더 일정을 동기화하려면 로그인된 사용자가 필요합니다.');
    }
    return userId;
  }

  static Future<List<gcal.Event>> _defaultGoogleCalendarEventsFetcher(
    gcal.CalendarApi api,
  ) async {
    final events = <gcal.Event>[];
    String? pageToken;

    do {
      final response = await api.events.list(
        'primary',
        pageToken: pageToken,
        maxResults: 250,
        singleEvents: true,
        orderBy: 'startTime',
        showDeleted: false,
        timeMin: DateTime.now().toUtc().subtract(const Duration(days: 1)),
      );

      events.addAll(response.items ?? const <gcal.Event>[]);
      pageToken = response.nextPageToken;
    } while (pageToken != null && pageToken.isNotEmpty);

    return events;
  }

  @visibleForTesting
  static String buildNaverScheduleIcal(EventModel event) {
    final startAt = event.startAt;
    if (startAt == null) {
      throw ArgumentError.value(event.startAt, 'event.startAt');
    }
    final endAt = event.endAt ?? startAt.add(const Duration(minutes: 30));
    final now = DateTime.now().toUtc();
    final uidSource = event.id.trim().isNotEmpty
        ? event.id.trim()
        : '${event.userId}-${event.title}-${startAt.toIso8601String()}';
    final uid = 'planflow-$uidSource@planflow';

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
    final local = value.toLocal();
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
