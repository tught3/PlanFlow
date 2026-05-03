import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:googleapis/calendar/v3.dart' as gcal;
import 'package:googleapis_auth/googleapis_auth.dart' as gauth;
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../data/models/event_model.dart';
import '../data/repositories/event_repository.dart';

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
              ? '캘린더 동기화가 완료되었습니다. $syncedItems개 항목을 확인했습니다.'
              : '캘린더 동기화가 완료되었습니다. 새로 가져온 항목은 없습니다.'),
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

class CalendarSyncService {
  CalendarSyncService({
    String? googleClientId,
    String? googleServerClientId,
    List<String> googleScopes = const <String>[
      gcal.CalendarApi.calendarEventsScope
    ],
    GoogleSignIn? googleSignIn,
    EventRepository? eventRepository,
    GoogleAccessTokenProvider? googleAccessTokenProvider,
    GoogleCalendarEventsFetcher? googleCalendarEventsFetcher,
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
  final String? _currentUserIdOverride;

  GoogleSignIn? _googleSignIn;

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
              'Google 로그인을 완료하지 않았거나 Calendar 권한 동의가 끝나지 않았습니다. 다시 동기화를 눌러 계정과 권한을 확인해 주세요.',
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
              ? 'Google Calendar 동기화가 완료되었습니다. $syncedItems개 항목을 확인했습니다.'
              : 'Google Calendar 동기화가 완료되었습니다. 새로 가져온 항목은 없습니다.',
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
    return CalendarIntegrationResult.unsupported(
      CalendarProvider.naver,
      message: '네이버 캘린더는 1차 배포에서 지원하지 않습니다.',
    );
  }

  Future<CalendarIntegrationResult> syncNaverCalendar() async {
    return CalendarIntegrationResult.unsupported(
      CalendarProvider.naver,
      message: '네이버 캘린더 동기화는 현재 사용할 수 없습니다.',
    );
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

    return 'Google Calendar event';
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
    final text = value?.toString().trim() ?? '';
    return text;
  }

  String _currentUserId() {
    final userId =
        _currentUserIdOverride ?? Supabase.instance.client.auth.currentUser?.id;
    if (userId == null || userId.isEmpty) {
      throw StateError('A signed-in user is required to sync Google events.');
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
}
