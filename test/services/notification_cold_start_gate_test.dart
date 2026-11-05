import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/core/constants.dart';
import 'package:planflow/core/diag_logger.dart';
import 'package:planflow/services/launch_signal_ledger.dart';
import 'package:planflow/services/notification_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _prefix = 'naver_ics_monthly_reminder';

String _token(DateTime date) =>
    '$_prefix:${date.year.toString().padLeft(4, '0')}-'
    '${date.month.toString().padLeft(2, '0')}-'
    '${date.day.toString().padLeft(2, '0')}';

NotificationResponse _response(String? payload) => NotificationResponse(
      id: 42,
      notificationResponseType: NotificationResponseType.selectedNotification,
      payload: payload,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  test('tokened cold start routes once across fresh service instances',
      () async {
    final payload = _token(DateTime.now());
    final first = _TestNotificationService(_FakePlugin(payload));
    final second = _TestNotificationService(_FakePlugin(payload));
    expect(await first.resolveColdStartLaunchRoute(), AppRoutes.naverIcsImport);
    expect(await second.resolveColdStartLaunchRoute(), isNull);
  });

  test('legacy cold start does not route', () async {
    final service = _TestNotificationService(_FakePlugin(_prefix));
    expect(await service.resolveColdStartLaunchRoute(), isNull);
  });

  test('malformed Naver cold start does not route', () async {
    for (final payload in <String>[
      '${_prefix}X',
      '$_prefix:2026-02-31',
      '$_prefix:bad',
    ]) {
      final service = _TestNotificationService(_FakePlugin(payload));
      expect(await service.resolveColdStartLaunchRoute(), isNull);
    }
  });

  test('eight-day-old token does not route', () async {
    final payload = _token(DateTime.now().subtract(const Duration(days: 8)));
    final service = _TestNotificationService(_FakePlugin(payload));
    expect(await service.resolveColdStartLaunchRoute(), isNull);
  });

  test('token over one day in the future does not route', () async {
    final payload = _token(DateTime.now().add(const Duration(days: 2)));
    final service = _TestNotificationService(_FakePlugin(payload));
    expect(await service.resolveColdStartLaunchRoute(), isNull);
  });

  test('ordinary app launch does not route', () async {
    final service = _TestNotificationService(
        _FakePlugin(_token(DateTime.now()), didLaunch: false));
    expect(await service.resolveColdStartLaunchRoute(), isNull);
  });

  for (final sample in <(String, DateTime, DateTime)>[
    // banned-ok: deterministic calendar fixture; no system clock dependency.
    ('exactly seven days old', DateTime(2026, 11, 1), DateTime(2026, 11, 8, 9)),
    // banned-ok: deterministic calendar fixture; no system clock dependency.
    ('exactly one day ahead', DateTime(2026, 11, 2), DateTime(2026, 11, 1, 9)),
  ]) {
    test('${sample.$1} remains eligible', () async {
      final service = _TestNotificationService(
        _FakePlugin(_token(sample.$2)),
        now: () => sample.$3,
      );
      expect(await service.resolveColdStartLaunchRoute(),
          AppRoutes.naverIcsImport);
    });
  }

  test('preference failures allow routing without private diagnostics',
      () async {
    DiagLogger.clear();
    // banned-ok: deterministic calendar fixture; no system clock dependency.
    final token = _token(DateTime(2026, 11, 1));
    final service = _TestNotificationService(
      _FakePlugin(token),
      // banned-ok: deterministic calendar fixture; no system clock dependency.
      now: () => DateTime(2026, 11, 1, 9),
      ledger: LaunchSignalLedger(
        prefsLoader: () async => throw StateError('PRIVATE_PREFERENCE_ERROR'),
      ),
    );
    expect(
        await service.resolveColdStartLaunchRoute(), AppRoutes.naverIcsImport);
    final log = DiagLogger.dump();
    expect(log, contains('kind=naver_ics_tokened decision=route'));
    expect(log, isNot(contains(token)));
    expect(log, isNot(contains('PRIVATE_PREFERENCE_ERROR')));
  });

  for (final sample in <(String, String)>[
    ('briefing:morning', '${AppRoutes.briefing}?type=morning'),
    ('event:regression-event', '${AppRoutes.eventDetail}/regression-event'),
    (
      'departure:regression-event',
      '${AppRoutes.departureAlarm}?eventId=regression-event'
    ),
  ]) {
    test('${sample.$1} remains repeatable on cold start', () async {
      for (var i = 0; i < 2; i++) {
        final service = _TestNotificationService(_FakePlugin(sample.$1));
        expect(await service.resolveColdStartLaunchRoute(), sample.$2);
      }
    });
  }

  test('warm taps route both legacy and valid tokened reminders', () {
    expect(NotificationService.routeForNotificationResponse(_response(_prefix)),
        AppRoutes.naverIcsImport);
    expect(
        NotificationService.routeForNotificationResponse(
            _response(_token(DateTime.now()))),
        AppRoutes.naverIcsImport);
    expect(
        NotificationService.routeForNotificationResponse(
            _response('${_prefix}X')),
        isNull);
  });

  test('no import history cancels the existing reminder without scheduling',
      () async {
    final plugin = _FakePlugin(null);
    final service = _TestNotificationService(plugin);
    // banned-ok: deterministic calendar fixture; no system clock dependency.
    await service.scheduleMonthlyNaverIcsReminder(now: DateTime(2026, 11, 4));
    expect(plugin.cancelled, <int>[service.notificationIdFor(_prefix)]);
    expect(service.scheduled, isEmpty);
  });

  test('import history schedules one reminder with dated payload', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'naver_ics:last_import_at':
          // banned-ok: deterministic calendar fixture; no system clock dependency.
          DateTime(2026, 10, 20).toUtc().toIso8601String(),
    });
    final plugin = _FakePlugin(null);
    final service = _TestNotificationService(plugin);
    // banned-ok: deterministic calendar fixture; no system clock dependency.
    await service.scheduleMonthlyNaverIcsReminder(now: DateTime(2026, 11, 4));
    expect(plugin.cancelled, isEmpty);
    expect(service.scheduled, hasLength(1));
    // banned-ok: deterministic calendar fixture; no system clock dependency.
    expect(service.scheduled.single.$1, DateTime(2026, 12, 1, 9));
    expect(service.scheduled.single.$2, '$_prefix:2026-12-01');
  });
}

class _FakePlugin extends Fake implements FlutterLocalNotificationsPlugin {
  _FakePlugin(this.payload, {this.didLaunch = true});

  final String? payload;
  final bool didLaunch;
  final List<int> cancelled = <int>[];

  @override
  Future<NotificationAppLaunchDetails?>
      getNotificationAppLaunchDetails() async =>
          NotificationAppLaunchDetails(didLaunch,
              notificationResponse: _response(payload));

  @override
  Future<void> cancel({required int id, String? tag}) async {
    cancelled.add(id);
  }
}

class _TestNotificationService extends NotificationService {
  _TestNotificationService(
    _FakePlugin plugin, {
    super.now,
    LaunchSignalLedger? ledger,
  }) : super(
          plugin: plugin,
          allowPermissionRequests: false,
          launchSignalLedger: ledger,
        );

  final List<(DateTime, String?)> scheduled = <(DateTime, String?)>[];

  @override
  Future<void> initialize() async {}

  @override
  Future<void> cancelEventReminderNotifications(String eventId) async {}

  @override
  Future<void> cancelEventNotifications(String eventId) async {}

  @override
  Future<void> scheduleEventReminder({
    required int id,
    required String title,
    required String body,
    required DateTime notifyAt,
    String? payload,
    bool includeDepartureAction = false,
  }) async {
    scheduled.add((notifyAt, payload));
  }
}
