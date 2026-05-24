import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../../core/constants.dart';
import '../../core/env.dart';
import '../../core/region_settings.dart';
import '../../core/responsive.dart';
import '../../core/theme.dart';
import '../../data/models/calendar_connection_model.dart';
import '../../data/models/feedback_report_model.dart';
import '../../data/models/user_settings_model.dart';
import '../../data/repositories/calendar_connection_repository.dart';
import '../../data/repositories/feedback_repository.dart';
import '../../data/repositories/settings_repository.dart';
import '../../providers/auth_provider.dart';
import '../../providers/settings_provider.dart';
import '../../core/analytics_service.dart';
import '../../services/remote_config_service.dart';
import '../../services/auth_service.dart';
import '../../services/backup_service.dart';
import '../../services/briefing_scheduler_service.dart';
import '../../services/calendar_auto_sync_service.dart';
import '../../services/calendar_sync_service.dart';
import '../../services/daily_backup_scheduler_service.dart';
import '../../services/departure_alarm_service.dart';
import '../../services/device_calendar_service.dart';
import '../../services/event_refresh_bus.dart';
import '../../services/home_widget_service.dart';
import '../../services/naver_caldav_service.dart';
import '../../services/naver_calendar_permission_service.dart';
import '../../services/notification_service.dart';
import '../../services/oauth_callback_handler.dart';
import '../../widgets/planflow_logo.dart';
import '../../l10n/app_l10n.dart';
import 'feedback_report_sheet.dart';

enum SettingsInitialAction {
  calendarSync,
  naverCalDav,
}

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    SettingsRepository? settingsRepository,
    BriefingSchedulerService? briefingSchedulerService,
    CalendarSyncService? calendarSyncService,
    CalendarAutoSyncService? calendarAutoSyncService,
    NotificationService? notificationService,
    BackupService? backupService,
    AuthService? authService,
    NaverCalendarPermissionService? naverCalendarPermissionService,
    DeviceCalendarService? deviceCalendarService,
    NaverCalDavService? naverCalDavService,
    String? userId,
    SettingsInitialAction? initialAction,
  })  : _settingsRepository = settingsRepository,
        _briefingSchedulerService = briefingSchedulerService,
        _calendarSyncService = calendarSyncService,
        _calendarAutoSyncService = calendarAutoSyncService,
        _notificationService = notificationService,
        _backupService = backupService,
        _authService = authService,
        _naverCalendarPermissionService = naverCalendarPermissionService,
        _deviceCalendarService = deviceCalendarService,
        _naverCalDavService = naverCalDavService,
        _userId = userId,
        _initialAction = initialAction;

  final SettingsRepository? _settingsRepository;
  final BriefingSchedulerService? _briefingSchedulerService;
  final CalendarSyncService? _calendarSyncService;
  final CalendarAutoSyncService? _calendarAutoSyncService;
  final NotificationService? _notificationService;
  final BackupService? _backupService;
  final AuthService? _authService;
  final NaverCalendarPermissionService? _naverCalendarPermissionService;
  final DeviceCalendarService? _deviceCalendarService;
  final NaverCalDavService? _naverCalDavService;
  final String? _userId;
  final SettingsInitialAction? _initialAction;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final SettingsRepository _settingsRepository;
  late final SettingsProvider _settingsProvider;
  late final BriefingSchedulerService _briefingSchedulerService;
  late final CalendarSyncService _calendarSyncService;
  late final CalendarAutoSyncService _calendarAutoSyncService;
  late final DailyBackupSchedulerService _dailyBackupSchedulerService;
  late final DeviceCalendarService _deviceCalendarService;
  late final NaverCalDavService _naverCalDavService;
  late final HomeWidgetService _homeWidgetService;
  late final NotificationService _notificationService;

  BackupService? _backupService;
  AuthService? _authService;
  NaverCalendarPermissionService? _naverCalendarPermissionService;

  UserSettingsModel? _savedSettings;
  TimeOfDay _morningBriefingAt = const TimeOfDay(hour: 7, minute: 30);
  TimeOfDay _eveningBriefingAt = const TimeOfDay(hour: 21, minute: 0);
  int _defaultReminderMinutes = 60;
  int _prepTimeMin = 30;
  int _prepPreAlarmOffset = 30;
  int _departPreAlarmOffset = 30;
  int _departureSafetyMarginMin = 20;
  String _travelMode = 'car';
  bool _voiceAutoStart = false;
  bool _hideWidgetWeekends = false;
  String _preferredMapProvider = 'naver';
  String _countryCode = PlanFlowRegions.korea.countryCode;
  String _localeCode = PlanFlowRegions.korea.localeCode;
  String _timeZoneId = PlanFlowRegions.korea.timeZoneId;

  CalendarSyncSummary? _calendarSyncSummary;
  BriefingRuntimeStatus? _briefingRuntimeStatus;
  DepartureAlarmRuntimeStatus? _departureAlarmRuntimeStatus;
  List<BackupSnapshot> _backups = const <BackupSnapshot>[];

  bool _isLoadingCalendarStatus = true;
  bool _isLoadingAlarmRuntimeStatus = true;
  bool _isTestingCriticalAlarm = false;
  bool _isSyncingGoogleCalendar = false;
  bool _isDisconnectingGoogleCalendar = false;
  bool _isDisconnectingNaverCalendar = false;
  bool _isImportingDeviceNaverCalendar = false;
  bool _isDisconnectingDeviceCalendar = false;
  bool _isTestingNaverCalDav = false;
  bool _isImportingNaverCalDav = false;
  bool _hasNaverCalDavCredentials = false;
  bool _isLoadingBackups = false;
  bool _isSavingSettings = false;
  bool _settingsSaveQueued = false;
  String? _queuedSettingsSuccessMessage;
  int _settingsSaveVersion = 0;
  bool _isTestingMorningBriefing = false;
  bool _isTestingEveningBriefing = false;
  bool _isBackupActionRunning = false;
  bool _ownsNaverCalDavService = false;
  NaverCalDavConnectionResult? _lastNaverCalDavResult;
  final ValueNotifier<NaverCalDavSyncProgress?> _naverCalDavProgress =
      ValueNotifier<NaverCalDavSyncProgress?>(null);
  final ValueNotifier<bool> _naverCalDavLongRunning =
      ValueNotifier<bool>(false);
  Timer? _naverCalDavLongRunningTimer;
  bool _isNaverCalDavProgressDialogOpen = false;
  int? _newFeedbackReportCount;
  bool _isLoadingNewFeedbackReportCount = false;
  String? _lastFeedbackAdminEmail;
  final GlobalKey _calendarSyncSectionKey = GlobalKey();

  String? get _userId => widget._userId ?? authProvider.userId;
  bool get _isFeedbackAdmin {
    if (!AppEnv.isSupabaseReady) {
      return false;
    }
    final email = authProvider.email?.trim().toLowerCase();
    return email != null && feedbackAdminEmails.contains(email);
  }

  @override
  void initState() {
    super.initState();
    _settingsRepository = widget._settingsRepository ??
        (AppEnv.isSupabaseReady
            ? SettingsRepository.supabase()
            : _UnavailableSettingsRepository());
    _settingsProvider = SettingsProvider(_settingsRepository);
    _briefingSchedulerService =
        widget._briefingSchedulerService ?? BriefingSchedulerService();
    _calendarSyncService = widget._calendarSyncService ??
        CalendarSyncService(
          googleClientId: _googleCalendarClientId,
          googleServerClientId: _googleCalendarServerClientId,
        );
    _calendarAutoSyncService =
        widget._calendarAutoSyncService ?? CalendarAutoSyncService();
    _notificationService = widget._notificationService ?? NotificationService();
    _dailyBackupSchedulerService = const DailyBackupSchedulerService();
    _deviceCalendarService =
        widget._deviceCalendarService ?? DeviceCalendarService();
    _homeWidgetService = HomeWidgetService();
    _ownsNaverCalDavService = widget._naverCalDavService == null;
    _naverCalDavService = widget._naverCalDavService ?? NaverCalDavService();
    _backupService = widget._backupService ??
        (AppEnv.isSupabaseReady ? BackupService() : null);
    _authService =
        widget._authService ?? (AppEnv.isSupabaseReady ? AuthService() : null);
    _naverCalendarPermissionService = widget._naverCalendarPermissionService;

    unawaited(_loadSettings());
    unawaited(_loadWidgetDisplaySettings());
    unawaited(_loadCalendarStatus());
    unawaited(_loadAutoSyncSnapshot());
    unawaited(_loadAlarmRuntimeStatus());
    final naverCalDavStateLoaded = _loadNaverCalDavState();
    unawaited(naverCalDavStateLoaded);
    if (widget._initialAction != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        unawaited(_runInitialAction(naverCalDavStateLoaded));
      });
    }
    if (AppEnv.isSupabaseReady) {
      unawaited(_loadBackups());
      unawaited(_ensureAutomaticBackup());
    }
    if (AppEnv.isSupabaseReady) {
      authProvider.addListener(_handleFeedbackAdminAuthChanged);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _handleFeedbackAdminAuthChanged();
      });
    }
  }

  @override
  void dispose() {
    if (AppEnv.isSupabaseReady) {
      authProvider.removeListener(_handleFeedbackAdminAuthChanged);
    }
    _settingsProvider.dispose();
    if (_ownsNaverCalDavService) {
      unawaited(_naverCalDavService.dispose());
    }
    _naverCalDavLongRunningTimer?.cancel();
    _naverCalDavProgress.dispose();
    _naverCalDavLongRunning.dispose();
    super.dispose();
  }

  void _handleFeedbackAdminAuthChanged() {
    final email = authProvider.email?.trim().toLowerCase();
    if (email == _lastFeedbackAdminEmail &&
        (_newFeedbackReportCount != null || !_isFeedbackAdmin)) {
      return;
    }
    _lastFeedbackAdminEmail = email;
    unawaited(_refreshNewFeedbackReportCount());
  }

  Future<void> _refreshNewFeedbackReportCount() async {
    if (!mounted) {
      return;
    }
    if (!_isFeedbackAdmin) {
      setState(() {
        _newFeedbackReportCount = null;
        _isLoadingNewFeedbackReportCount = false;
      });
      return;
    }
    setState(() => _isLoadingNewFeedbackReportCount = true);
    try {
      final count = await FeedbackRepository.supabase().countNewAdminReports();
      if (!mounted) {
        return;
      }
      setState(() {
        _newFeedbackReportCount = count;
        _isLoadingNewFeedbackReportCount = false;
      });
    } on FeedbackSubmissionException catch (error) {
      debugPrint('Feedback admin badge unavailable: ${error.message}');
      if (!mounted) {
        return;
      }
      setState(() {
        _newFeedbackReportCount = null;
        _isLoadingNewFeedbackReportCount = false;
      });
    } catch (error) {
      debugPrint('Feedback admin badge unavailable: $error');
      if (!mounted) {
        return;
      }
      setState(() {
        _newFeedbackReportCount = null;
        _isLoadingNewFeedbackReportCount = false;
      });
    }
  }

  Future<void> _loadSettings() async {
    final userId = _userId;
    if (userId == null || userId.isEmpty) {
      setState(() {
        _savedSettings = null;
      });
      return;
    }
    final loaded = await _settingsProvider.load(userId);
    if (!mounted) {
      return;
    }
    final effective = loaded ?? UserSettingsModel.defaults(userId: userId);
    setState(() {
      _savedSettings = effective;
      _applySettings(effective);
    });
    unawaited(_scheduleBriefingsFromSettings(
      effective,
      reason: 'settings_loaded',
    ));
  }

  Future<void> _loadWidgetDisplaySettings() async {
    final hideWeekends = await _homeWidgetService.areWeekendsHidden();
    if (!mounted) {
      return;
    }
    setState(() {
      _hideWidgetWeekends = hideWeekends;
    });
  }

  Future<void> _loadCalendarStatus() async {
    setState(() {
      _isLoadingCalendarStatus = true;
    });
    final summary = await _calendarSyncService.fetchStatus();
    if (!mounted) {
      return;
    }
    setState(() {
      _calendarSyncSummary = summary;
      _isLoadingCalendarStatus = false;
    });
  }

  Future<void> _loadAutoSyncSnapshot() async {
    await _calendarAutoSyncService.loadSnapshot();
  }

  Future<void> _loadAlarmRuntimeStatus() async {
    setState(() {
      _isLoadingAlarmRuntimeStatus = true;
    });
    final briefing = await _briefingSchedulerService.loadRuntimeStatus();
    final departure = await const DepartureAlarmService().loadRuntimeStatus();
    if (!mounted) {
      return;
    }
    setState(() {
      _briefingRuntimeStatus = briefing;
      _departureAlarmRuntimeStatus = departure;
      _isLoadingAlarmRuntimeStatus = false;
    });
  }

  Future<void> _runCriticalAlarmDifferenceTest() async {
    if (_isTestingCriticalAlarm) {
      return;
    }
    setState(() {
      _isTestingCriticalAlarm = true;
    });

    final now = DateTime.now();
    final normalAt = now.add(const Duration(seconds: 5));
    final criticalAt = now.add(const Duration(seconds: 12));
    try {
      final normal = await _notificationService.scheduleEventReminderWithResult(
        id: _notificationService.notificationIdFor(
          'settings:normal_alarm_test:${now.millisecondsSinceEpoch}',
        ),
        title: '일반 알림 테스트',
        body: '이건 일반 일정 알림입니다.',
        notifyAt: normalAt,
      );
      final critical =
          await _notificationService.scheduleCriticalAlarmWithResult(
        id: _notificationService.notificationIdFor(
          'settings:critical_alarm_test:${now.millisecondsSinceEpoch}',
        ),
        title: '중요 알림 테스트',
        body: '이건 중요 일정 알림입니다. 소리, 진동, 잠금화면 표시 차이를 확인해 주세요.',
        notifyAt: criticalAt,
      );

      if (!mounted) {
        return;
      }
      if (normal.isScheduled && critical.isScheduled) {
        _showSnack('5초 뒤 일반 알림, 12초 뒤 중요 알림을 울립니다. 잠금화면 차이는 화면을 꺼두면 더 잘 보여요.');
      } else {
        final message =
            critical.message ?? normal.message ?? '알림 권한 상태를 확인해 주세요.';
        _showSnack(message);
      }
    } catch (error, stackTrace) {
      debugPrint('Critical alarm difference test failed: $error');
      debugPrintStack(stackTrace: stackTrace);
      if (mounted) {
        _showSnack('중요 알림 테스트를 예약하지 못했습니다. 알림 권한을 확인해 주세요.');
      }
    } finally {
      if (mounted) {
        setState(() {
          _isTestingCriticalAlarm = false;
        });
      }
    }
  }

  Future<void> _loadNaverCalDavState() async {
    final hasCredentials = await _naverCalDavService.hasCredentials();
    if (!mounted) {
      return;
    }
    setState(() {
      _hasNaverCalDavCredentials = hasCredentials;
      if (!hasCredentials) {
        _lastNaverCalDavResult = null;
      }
    });
  }

  Future<void> _syncGoogleCalendar() async {
    if (_isSyncingGoogleCalendar) {
      return;
    }
    setState(() {
      _isSyncingGoogleCalendar = true;
    });
    final result =
        await _calendarSyncService.syncGoogleCalendar(interactive: true);
    if (!mounted) {
      return;
    }
    setState(() {
      _calendarSyncSummary = CalendarSyncSummary(
        google: result,
        naver: _calendarSyncSummary?.naver ??
            CalendarIntegrationResult.signedOut(CalendarProvider.naver),
      );
      _isSyncingGoogleCalendar = false;
    });
    _showSnack(result.message);
  }

  Future<void> _disconnectGoogleCalendar() async {
    if (_isDisconnectingGoogleCalendar) {
      return;
    }
    final deleteProviderEvents = await _askDisconnectPolicy('Google Calendar');
    if (deleteProviderEvents == null) {
      return;
    }

    setState(() {
      _isDisconnectingGoogleCalendar = true;
    });
    try {
      await _calendarSyncService.disconnectProvider(
        CalendarProvider.google,
        deleteProviderEvents: deleteProviderEvents,
      );
      if (!mounted) {
        return;
      }
      await _loadCalendarStatus();
      _showSnack('Google Calendar 연동을 해제했습니다.');
    } catch (error, stackTrace) {
      debugPrint('Google calendar disconnect failed: $error');
      debugPrintStack(stackTrace: stackTrace);
      _showSnack('Google Calendar 연동 해제에 실패했습니다. 잠시 후 다시 시도해 주세요.');
    } finally {
      if (mounted) {
        setState(() {
          _isDisconnectingGoogleCalendar = false;
        });
      }
    }
  }

  Future<bool?> _askDisconnectPolicy(String providerName) {
    return showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text('$providerName 연동 해제'),
          content: const Text(
            '가져온 일정을 PlanFlow에 남겨둘지, 해당 공급자 일정과 함께 정리할지 선택해 주세요.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(null),
              child: const Text('취소'),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('일정 유지'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('공급자 일정 삭제'),
            ),
          ],
        );
      },
    );
  }

  NaverCalendarPermissionService get _naverCalendarPermissionServiceInstance {
    return _naverCalendarPermissionService ??= NaverCalendarPermissionService();
  }

  Future<void> _importDeviceNaverCalendar() async {
    if (_isImportingDeviceNaverCalendar || _isDisconnectingDeviceCalendar) {
      return;
    }
    final userId = _userId;
    if (userId == null || userId.isEmpty) {
      _showSnack('먼저 PlanFlow에 로그인해 주세요.');
      return;
    }

    setState(() {
      _isImportingDeviceNaverCalendar = true;
    });
    final result = await _deviceCalendarService.importNaverEvents(
      userId: userId,
    );
    if (!mounted) {
      return;
    }
    setState(() {
      _isImportingDeviceNaverCalendar = false;
    });
    _showSnack(result.message);
    if (result.isSuccess) {
      EventRefreshBus.instance.notifyChanged(reason: 'device_naver_import');
    } else if (result.status == DeviceCalendarImportStatus.noNaverCalendars) {
      _showSnack(
        '휴대폰 내부 캘린더 저장소에서 네이버 후보를 찾지 못했습니다. 삼성/구글/휴대폰 캘린더 동기화를 확인해 주세요.',
      );
    }
  }

  Future<void> _disconnectDeviceCalendarImport() async {
    if (_isDisconnectingDeviceCalendar || _isImportingDeviceNaverCalendar) {
      return;
    }
    setState(() {
      _isDisconnectingDeviceCalendar = true;
    });
    try {
      _showSnack(
        '휴대폰 내부 캘린더 연동 정보를 초기화했습니다. 다음 가져오기 때 다시 권한과 저장소를 확인합니다.',
      );
    } catch (error, stackTrace) {
      debugPrint('Device calendar disconnect failed: $error');
      debugPrintStack(stackTrace: stackTrace);
      _showSnack('휴대폰 내부 캘린더 연동 해제에 실패했습니다. 다시 시도해 주세요.');
    } finally {
      if (mounted) {
        setState(() {
          _isDisconnectingDeviceCalendar = false;
        });
      }
    }
  }

  Future<bool> _connectNaverCalDavAndImport() async {
    if (_isTestingNaverCalDav || _isImportingNaverCalDav) {
      return false;
    }

    final credentials = await _showNaverCalDavDialog();
    if (credentials == null) {
      return false;
    }

    setState(() {
      _isTestingNaverCalDav = true;
      _lastNaverCalDavResult = null;
    });

    NaverCalDavConnectionResult result;
    try {
      result = await _naverCalDavService.testConnection(
        naverId: credentials.naverId,
        appPassword: credentials.appPassword,
        saveOnSuccess: true,
      );
    } catch (error, stackTrace) {
      debugPrint('Naver CalDAV connect failed: $error');
      debugPrintStack(stackTrace: stackTrace);
      if (mounted) {
        setState(() {
          _isTestingNaverCalDav = false;
          _hasNaverCalDavCredentials = false;
        });
        _showSnack('네이버 CalDAV 연결에 실패했습니다. ID와 앱 비밀번호를 확인해 주세요.');
      }
      return false;
    }
    if (!mounted) {
      return false;
    }
    setState(() {
      _lastNaverCalDavResult = result;
      _isTestingNaverCalDav = false;
      _hasNaverCalDavCredentials = result.isSuccess;
    });
    if (!result.isSuccess) {
      _showSnack(result.message);
      return false;
    }

    _showSnack('네이버 CalDAV 연결에 성공했습니다. 이제 일정을 가져옵니다.');
    await _markNaverCalDavConnection(
      status: CalendarConnectionStatus.connected,
      lastError: null,
    );
    await _loadCalendarStatus();
    if (!mounted) {
      return false;
    }
    final imported = await _importNaverCalDavEvents(skipIntro: true);
    return imported?.success ?? false;
  }

  Future<NaverCalDavSyncResult?> _importNaverCalDavEvents({
    bool skipIntro = false,
  }) async {
    if (_isImportingNaverCalDav) {
      return null;
    }
    final userId = _userId;
    if (userId == null || userId.isEmpty) {
      _showSnack('먼저 PlanFlow에 로그인해 주세요.');
      return null;
    }
    if (!skipIntro) {
      final shouldStart = await _showNaverCalDavImportIntroDialog();
      if (shouldStart != true) {
        return null;
      }
    }
    final quickResult = await _runNaverCalDavImport(
      userId: userId,
      mode: NaverCalDavSyncMode.quick,
    );
    if (!mounted || quickResult == null || !quickResult.success) {
      return quickResult;
    }

    final range = await _showNaverCalDavMoreRangeDialog();
    if (!mounted || range == null) {
      return quickResult;
    }
    return _runNaverCalDavImport(
      userId: userId,
      mode: range.mode,
      from: range.from,
      to: range.to,
      additionalLabel: range.label,
    );
  }

  Future<NaverCalDavSyncResult?> _runNaverCalDavImport({
    required String userId,
    required NaverCalDavSyncMode mode,
    DateTime? from,
    DateTime? to,
    String? additionalLabel,
    bool diagnosticImport = false,
  }) async {
    setState(() {
      _isImportingNaverCalDav = true;
    });
    _naverCalDavProgress.value = NaverCalDavSyncProgress(
      mode: mode,
      stage: NaverCalDavSyncStage.preparing,
      message: additionalLabel == null
          ? '네이버 캘린더에 연결 중입니다. 데이터가 많으면 1~2분 정도 걸릴 수 있어요.'
          : '$additionalLabel 범위의 일정을 추가로 가져옵니다.',
    );
    _naverCalDavLongRunning.value = false;
    _naverCalDavLongRunningTimer?.cancel();
    _naverCalDavLongRunningTimer = Timer(const Duration(seconds: 10), () {
      _naverCalDavLongRunning.value = true;
    });
    if (!_isNaverCalDavProgressDialogOpen) {
      unawaited(_showNaverCalDavProgressDialog(dismissible: true));
    }
    final result = await _naverCalDavService.syncAll(
      userId: userId,
      from: from,
      to: to,
      mode: mode,
      skipUnchanged: true,
      diagnosticImport: diagnosticImport,
      onProgress: (progress) {
        if (!mounted) {
          return;
        }
        _naverCalDavProgress.value = progress;
      },
    );
    _naverCalDavLongRunningTimer?.cancel();
    _naverCalDavLongRunning.value = false;
    if (!mounted) {
      return result;
    }
    if (_isNaverCalDavProgressDialogOpen &&
        Navigator.of(context, rootNavigator: true).canPop()) {
      Navigator.of(context, rootNavigator: true).pop();
    }
    setState(() {
      _isImportingNaverCalDav = false;
    });
    _showSnack(result.message);
    if (diagnosticImport) {
      await _showNaverCalDavDiagnosticResult(result);
    }
    if (result.success) {
      await _markNaverCalDavConnection(
        status: CalendarConnectionStatus.connected,
        lastError: result.createdOrUpdated == 0 && result.skipped == 0
            ? result.message
            : null,
      );
      if (mounted) {
        await _loadCalendarStatus();
      }
      EventRefreshBus.instance.notifyChanged(reason: 'naver_caldav_import');
    } else {
      await _markNaverCalDavConnection(
        status: CalendarConnectionStatus.failed,
        lastError: result.message,
      );
    }
    return result;
  }

  // ignore: unused_element
  Future<void> _runNaverCalDavDiagnosticImport() async {
    if (_isImportingNaverCalDav || _isTestingNaverCalDav) {
      return;
    }
    final userId = _userId;
    if (userId == null || userId.isEmpty) {
      _showSnack('먼저 PlanFlow에 로그인해 주세요.');
      return;
    }
    if (!_hasNaverCalDavCredentials) {
      final connected = await _connectNaverCalDavAndImport();
      if (!connected || !mounted) {
        return;
      }
    }
    await _runNaverCalDavImport(
      userId: userId,
      mode: NaverCalDavSyncMode.quick,
      additionalLabel: '진단',
      diagnosticImport: true,
    );
  }

  Future<void> _showNaverCalDavDiagnosticResult(
    NaverCalDavSyncResult result,
  ) {
    final diagnostics = result.diagnostics;
    final samples = diagnostics.samples;
    final invalidSamples = diagnostics.invalidSamples;
    final reasonText = _naverCalDavDiagnosticReasonText(diagnostics);
    var query = '';
    return showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('네이버 동기화 진단 결과'),
        content: StatefulBuilder(
          builder: (context, setDialogState) {
            bool sampleMatches(Object sample) {
              if (query.trim().isEmpty) {
                return true;
              }
              final text = switch (sample) {
                NaverCalDavDebugSample s =>
                  '${s.title} ${s.rawStart} ${s.rawEnd} ${s.calendarPath}',
                NaverCalDavInvalidSample s =>
                  '${s.title ?? ''} ${s.reason} ${s.rawStart ?? ''} ${s.calendarPath}',
                _ => sample.toString(),
              }
                  .toLowerCase();
              return text.contains(query.trim().toLowerCase());
            }

            final visibleSamples =
                samples.where(sampleMatches).toList(growable: false);
            final visibleInvalidSamples =
                invalidSamples.where(sampleMatches).toList(growable: false);

            return SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    diagnostics.toSummaryMessage(),
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                  ),
                  const SizedBox(height: 12),
                  Text(reasonText,
                      style: Theme.of(context).textTheme.bodySmall),
                  const SizedBox(height: 10),
                  TextField(
                    decoration: const InputDecoration(
                      labelText: '찾는 일정 제목 검색',
                      hintText: '예: 태불릿계, 공임나라',
                      prefixIcon: Icon(Icons.search),
                    ),
                    onChanged: (value) {
                      setDialogState(() {
                        query = value;
                      });
                    },
                  ),
                  const SizedBox(height: 12),
                  _NaverDiagnosticCountTable(diagnostics: diagnostics),
                  const SizedBox(height: 12),
                  Text(
                    '읽음/파싱 수는 네이버 서버가 반환한 원본 후보입니다. 검색한 제목이 샘플에 없으면 CalDAV 응답 자체에 없거나 샘플 5개 밖에 있을 수 있어요.',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: PlanFlowColors.textSecondary,
                        ),
                  ),
                  if (visibleSamples.isNotEmpty) ...[
                    const SizedBox(height: 16),
                    Text('저장 범위 안 샘플 일정',
                        style: Theme.of(context).textTheme.titleSmall),
                    const SizedBox(height: 8),
                    ...visibleSamples.map(
                      (sample) => Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Text(
                          '${sample.title.isEmpty ? '제목 없음' : sample.title}\n'
                          '원본 시작: ${sample.rawStart}\n'
                          '저장 시작: ${_formatDateTime(sample.startAt.toLocal())}',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                    ),
                  ],
                  if (visibleInvalidSamples.isNotEmpty) ...[
                    const SizedBox(height: 16),
                    Text('파싱 실패 샘플',
                        style: Theme.of(context).textTheme.titleSmall),
                    const SizedBox(height: 8),
                    ...visibleInvalidSamples.map(
                      (sample) => Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Text(
                          '${sample.title?.isNotEmpty == true ? sample.title : '제목 확인 불가'}\n'
                          '사유: ${sample.reason}\n'
                          '구성: ${sample.component ?? '확인 불가'}\n'
                          '원본 시작: ${sample.rawStart ?? '없음'}',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            );
          },
        ),
        actionsPadding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
        actions: [
          _buildDialogButtonBar(
            onCancel: () => Navigator.of(context).pop(),
            onConfirm: () => Navigator.of(context).pop(),
            cancelLabel: '닫기',
            confirmLabel: '확인',
          ),
        ],
      ),
    );
  }

  String _naverCalDavDiagnosticReasonText(
    NaverCalDavSyncDiagnostics diagnostics,
  ) {
    if (diagnostics.saved > 0) {
      return '저장까지 성공했습니다. 홈/일정 탭에 보이지 않으면 날짜 범위나 선택된 날짜를 확인해 주세요.';
    }
    if (diagnostics.failed > 0) {
      return '저장 실패가 있습니다. Supabase 스키마/RLS 또는 네트워크 오류가 원인일 수 있습니다.';
    }
    if (diagnostics.duplicateSkipped > 0) {
      return '같은 제목과 시간이 이미 있는 일정으로 판단되어 저장하지 않았습니다. 이 판단이 너무 넓은지 확인하려면 이 진단 결과를 기준으로 중복 규칙을 조정해야 합니다.';
    }
    if (diagnostics.unchangedSkipped > 0) {
      return '이미 가져온 일정과 etag/수정 시간이 같아서 변경 없음으로 건너뛰었습니다.';
    }
    if (diagnostics.invalidEvents > 0 && diagnostics.saveCandidates == 0) {
      return '날짜 파싱 실패가 있어 저장 대상이 만들어지지 않았습니다. DTSTART/DTEND 원본 형식을 추가로 확인해야 합니다.';
    }
    if (diagnostics.parsedEvents > 0 && diagnostics.saveCandidates == 0) {
      return '네이버에서 일정은 읽었지만 현재 빠른 동기화 범위 안에 저장할 일정이 없었습니다.';
    }
    return '저장 0개라면 중복 스킵, 변경 없음, 저장 실패, 날짜 파싱 실패 중 어디에 해당하는지 위 숫자로 확인할 수 있습니다.';
  }

  Future<void> _markNaverCalDavConnection({
    required CalendarConnectionStatus status,
    String? lastError,
  }) async {
    final userId = _userId;
    if (!AppEnv.isSupabaseReady || userId == null || userId.isEmpty) {
      return;
    }
    try {
      await CalendarConnectionRepository.supabase().upsertConnection(
        CalendarConnectionModel(
          userId: userId,
          provider: 'naver',
          status: status,
          lastSyncedAt: status == CalendarConnectionStatus.connected
              ? DateTime.now().toUtc()
              : null,
          lastError: lastError,
        ),
      );
    } catch (error, stackTrace) {
      debugPrint('Naver CalDAV connection state save skipped: $error');
      debugPrintStack(stackTrace: stackTrace);
    }
  }

  Future<bool?> _showNaverCalDavImportIntroDialog() {
    return showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('네이버 캘린더 동기화'),
        content: const Text(
          '데이터가 많은 경우 오래 걸릴 수 있습니다. 보통 1~2분 사이에 완료됩니다. 먼저 최근 3개월과 앞으로 6개월 일정만 빠르게 가져옵니다.',
        ),
        actions: [
          _buildDialogButtonBar(
            onCancel: () => Navigator.of(context).pop(false),
            onConfirm: () => Navigator.of(context).pop(true),
            cancelLabel: '취소',
            confirmLabel: '가져오기',
          ),
        ],
      ),
    );
  }

  Future<void> _showNaverCalDavProgressDialog({
    required bool dismissible,
  }) {
    _isNaverCalDavProgressDialogOpen = true;
    return showDialog<void>(
      context: context,
      barrierDismissible: dismissible,
      builder: (context) => PopScope(
        canPop: dismissible,
        child: AlertDialog(
          title: const Text('네이버 일정 가져오는 중'),
          content: ValueListenableBuilder<bool>(
            valueListenable: _naverCalDavLongRunning,
            builder: (context, isLongRunning, _) {
              return ValueListenableBuilder<NaverCalDavSyncProgress?>(
                valueListenable: _naverCalDavProgress,
                builder: (context, progress, _) {
                  final processed = progress?.processedEvents ?? 0;
                  final total = progress?.totalEvents ?? 0;
                  final isSaving =
                      progress?.stage == NaverCalDavSyncStage.saving;
                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Center(child: CircularProgressIndicator()),
                      const SizedBox(height: 16),
                      Text(
                        isLongRunning
                            ? '데이터가 많아 오래 걸릴 수 있습니다. 보통 1~2분 사이에 완료됩니다. 잠시만 기다려 주세요.'
                            : '데이터가 많은 경우 오래 걸릴 수 있습니다.',
                      ),
                      const SizedBox(height: 12),
                      Text(progress?.message ?? '캘린더 확인 중입니다.'),
                      Text(
                        '앱을 백그라운드로 보내도 동기화는 계속됩니다. '
                        '완료되면 다시 알려드릴게요.',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: PlanFlowColors.textSecondary,
                            ),
                      ),
                      if (progress?.currentCalendar != null) ...[
                        const SizedBox(height: 8),
                        Text('현재 캘린더: ${progress!.currentCalendar}'),
                      ],
                      const SizedBox(height: 8),
                      Text(
                        isSaving
                            ? '$processed / $total개 처리 중'
                            : '저장이 시작되면 00/00개 처리 중으로 표시됩니다.',
                      ),
                      if (total > 0 && !isSaving) ...[
                        const SizedBox(height: 8),
                        Text('조회된 일정 $total개'),
                      ],
                      const SizedBox(height: 8),
                      Text(
                        '저장 ${progress?.savedEvents ?? 0}개 · '
                        '건너뜀 ${progress?.skippedEvents ?? 0}개 · '
                        '실패 ${progress?.failedEvents ?? 0}개',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      if (dismissible) ...[
                        const SizedBox(height: 12),
                        Text(
                          '창을 닫아도 동기화는 계속됩니다.',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ],
                  );
                },
              );
            },
          ),
        ),
      ),
    ).whenComplete(() {
      _isNaverCalDavProgressDialogOpen = false;
    });
  }

  Widget _buildDialogButtonBar({
    required VoidCallback onCancel,
    required VoidCallback onConfirm,
    required String cancelLabel,
    required String confirmLabel,
    int cancelFlex = 1,
    int confirmFlex = 1,
    Color? cancelForegroundColor,
    Color? cancelBackgroundColor,
    Color? confirmForegroundColor,
    Color? confirmBackgroundColor,
  }) {
    return SizedBox(
      width: double.infinity,
      child: Row(
        children: [
          Expanded(
            flex: cancelFlex,
            child: FilledButton.tonal(
              onPressed: onCancel,
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(48),
                foregroundColor:
                    cancelForegroundColor ?? PlanFlowColors.primary,
                backgroundColor:
                    cancelBackgroundColor ?? PlanFlowColors.primaryFaint,
              ),
              child: Text(cancelLabel),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            flex: confirmFlex,
            child: FilledButton(
              onPressed: onConfirm,
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(48),
                foregroundColor: confirmForegroundColor ?? Colors.white,
                backgroundColor:
                    confirmBackgroundColor ?? PlanFlowColors.primary,
              ),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  confirmLabel,
                  maxLines: 1,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<_NaverCalDavImportRange?> _showNaverCalDavMoreRangeDialog() {
    Widget buildRangeButton({
      required String label,
      required VoidCallback onPressed,
    }) {
      return SizedBox(
        width: 100,
        height: 42,
        child: FilledButton(
          onPressed: onPressed,
          style: FilledButton.styleFrom(
            backgroundColor: PlanFlowColors.primary,
            foregroundColor: Colors.white,
            padding: EdgeInsets.zero,
            minimumSize: Size.zero,
          ),
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              label,
              maxLines: 1,
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
    }

    return showDialog<_NaverCalDavImportRange>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('추가 기록 가져오기'),
        content: const Text(
          '최근 3개월과 앞으로 6개월 일정을 저장했습니다. 더 과거 기록을 얼마나 불러올까요?',
        ),
        actions: [
          SizedBox(
            width: double.maxFinite,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: buildRangeButton(
                        label: '나중에',
                        onPressed: () => Navigator.of(context).pop(),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: buildRangeButton(
                        label: '6개월',
                        onPressed: () => Navigator.of(context).pop(
                          _NaverCalDavImportRange.months(6),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: buildRangeButton(
                        label: '1년',
                        onPressed: () => Navigator.of(context).pop(
                          _NaverCalDavImportRange.years(1),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: buildRangeButton(
                        label: '2년',
                        onPressed: () => Navigator.of(context).pop(
                          _NaverCalDavImportRange.years(2),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: buildRangeButton(
                        label: '직접입력',
                        onPressed: () async {
                          final range =
                              await _showNaverCalDavCustomRangeDialog();
                          if (context.mounted && range != null) {
                            Navigator.of(context).pop(range);
                          }
                        },
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: buildRangeButton(
                        label: '전체',
                        onPressed: () async {
                          final confirmed = await _confirmNaverCalDavAllRange();
                          if (context.mounted && confirmed) {
                            Navigator.of(context).pop(
                              _NaverCalDavImportRange.all(),
                            );
                          }
                        },
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<_NaverCalDavImportRange?> _showNaverCalDavCustomRangeDialog() {
    final controller = TextEditingController(text: '12');
    var unit = '개월';
    return showDialog<_NaverCalDavImportRange>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('기간 직접 입력'),
          content: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: controller,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: '숫자'),
                ),
              ),
              const SizedBox(width: 12),
              DropdownButton<String>(
                value: unit,
                items: const [
                  DropdownMenuItem(value: '개월', child: Text('개월')),
                  DropdownMenuItem(value: '년', child: Text('년')),
                ],
                onChanged: (value) {
                  if (value != null) {
                    setDialogState(() => unit = value);
                  }
                },
              ),
            ],
          ),
          actions: [
            _buildDialogButtonBar(
              onCancel: () => Navigator.of(context).pop(),
              onConfirm: () {
                final value = int.tryParse(controller.text.trim());
                if (value == null || value <= 0) {
                  return;
                }
                Navigator.of(context).pop(
                  unit == '개월'
                      ? _NaverCalDavImportRange.months(value)
                      : _NaverCalDavImportRange.years(value),
                );
              },
              cancelLabel: '취소',
              confirmLabel: '확인',
            ),
          ],
        ),
      ),
    );
  }

  Future<bool> _confirmNaverCalDavAllRange() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('전체 기록 가져오기'),
        content: const Text(
          '전체 기록은 일정 수에 따라 오래 걸릴 수 있습니다. 그래도 진행할까요?',
        ),
        actions: [
          _buildDialogButtonBar(
            onCancel: () => Navigator.of(context).pop(false),
            onConfirm: () => Navigator.of(context).pop(true),
            cancelLabel: '취소',
            confirmLabel: '전체 가져오기',
          ),
        ],
      ),
    );
    return confirmed == true;
  }

  Future<_NaverCalDavCredentials?> _showNaverCalDavDialog() {
    final idController = TextEditingController();
    final passwordController = TextEditingController();
    final idFocusNode = FocusNode();
    final passwordFocusNode = FocusNode();
    final idKey = GlobalKey();
    final passwordKey = GlobalKey();

    void ensureVisible(GlobalKey key) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final context = key.currentContext;
        if (context == null) {
          return;
        }
        Scrollable.ensureVisible(
          context,
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          alignment: 0.42,
          alignmentPolicy: ScrollPositionAlignmentPolicy.explicit,
        );
      });
    }

    return showDialog<_NaverCalDavCredentials>(
      context: context,
      builder: (context) {
        final theme = Theme.of(context);
        final bodyStyle = theme.textTheme.bodyMedium?.copyWith(
              fontSize: (theme.textTheme.bodyMedium?.fontSize ?? 14) + 2,
              height: 1.45,
            ) ??
            const TextStyle(fontSize: 16, height: 1.45);
        final screenHeight = MediaQuery.sizeOf(context).height;

        return AlertDialog(
          insetPadding:
              const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
          title: const Text('네이버 캘린더 연결'),
          content: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: 460,
              maxHeight: screenHeight * 0.58,
            ),
            child: SingleChildScrollView(
              padding: const EdgeInsets.only(bottom: 12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'PlanFlow가 네이버 CalDAV 서버에 직접 연결해 기존 일정을 가져옵니다.',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      height: 1.45,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color:
                          PlanFlowColors.primaryFaint.withValues(alpha: 0.38),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: PlanFlowColors.primary.withValues(alpha: 0.16),
                      ),
                    ),
                    child: DefaultTextStyle(
                      style: bodyStyle.copyWith(
                        color: PlanFlowColors.textPrimary,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'ID는 로그인 전용 ID가 아니라 원본 네이버 ID를 입력해 주세요.',
                          ),
                          const SizedBox(height: 10),
                          Text.rich(
                            TextSpan(
                              text:
                                  '앱 비밀번호는 네이버 앱/웹에서 ID 관리 → 2단계 인증 관리 → 애플리케이션 비밀번호 생성 → Android 선택 후 발급받은 값을 입력해 주세요.',
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            '네이버 일반 비밀번호가 아닙니다.',
                            style: bodyStyle.copyWith(
                              fontWeight: FontWeight.w900,
                              color: theme.colorScheme.error,
                            ),
                          ),
                          const SizedBox(height: 14),
                          Row(
                            children: const [
                              Expanded(
                                child: _NaverGuideThumbnail(
                                  title: '웹에서 찾기',
                                  assetPath:
                                      'assets/naver_app_password/naver_web_id_entry.png',
                                ),
                              ),
                              SizedBox(width: 10),
                              Expanded(
                                child: _NaverGuideThumbnail(
                                  title: '앱에서 찾기',
                                  assetPath:
                                      'assets/naver_app_password/naver_app_id_entry.png',
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  KeyedSubtree(
                    key: idKey,
                    child: TextField(
                      controller: idController,
                      focusNode: idFocusNode,
                      decoration: const InputDecoration(
                        labelText: '네이버 ID',
                        hintText: '예: myname123',
                      ),
                      textInputAction: TextInputAction.next,
                      scrollPadding: const EdgeInsets.only(bottom: 80),
                      onTap: () => ensureVisible(idKey),
                      onSubmitted: (_) {
                        passwordFocusNode.requestFocus();
                        ensureVisible(passwordKey);
                      },
                    ),
                  ),
                  const SizedBox(height: 12),
                  KeyedSubtree(
                    key: passwordKey,
                    child: TextField(
                      controller: passwordController,
                      focusNode: passwordFocusNode,
                      decoration: const InputDecoration(
                        labelText: '앱 비밀번호',
                        hintText: '네이버 보안설정에서 발급한 비밀번호',
                      ),
                      obscureText: false,
                      textInputAction: TextInputAction.done,
                      scrollPadding: const EdgeInsets.only(bottom: 96),
                      onTap: () => ensureVisible(passwordKey),
                      onSubmitted: (_) {
                        Navigator.of(context).pop(
                          _NaverCalDavCredentials(
                            naverId: idController.text,
                            appPassword: passwordController.text,
                          ),
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    '연결에 성공하면 PlanFlow 계정에 저장되고 이 기기에는 보조 캐시가 남습니다. '
                    '같은 계정으로 다시 로그인하면 자동으로 복원됩니다.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: PlanFlowColors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            _buildDialogButtonBar(
              onCancel: () => Navigator.of(context).pop(),
              onConfirm: () {
                Navigator.of(context).pop(
                  _NaverCalDavCredentials(
                    naverId: idController.text,
                    appPassword: passwordController.text,
                  ),
                );
              },
              cancelLabel: '취소',
              confirmLabel: '연결하고 가져오기',
              cancelFlex: 3,
              confirmFlex: 7,
            ),
          ],
        );
      },
    ).whenComplete(() {
      idFocusNode.dispose();
      passwordFocusNode.dispose();
    });
  }

  Future<void> _syncOrReconnectNaverCalendar() async {
    if (_isTestingNaverCalDav ||
        _isImportingNaverCalDav ||
        _isDisconnectingNaverCalendar) {
      return;
    }

    if (_hasNaverCalDavCredentials) {
      await _importNaverCalDavEvents(skipIntro: true);
    } else {
      await _connectNaverCalDavAndImport();
    }
  }

  Future<void> _runInitialAction(Future<void> naverCalDavStateLoaded) async {
    await naverCalDavStateLoaded;
    if (!mounted) {
      return;
    }

    await _scrollToCalendarSyncSection();
    if (!mounted) {
      return;
    }

    switch (widget._initialAction) {
      case SettingsInitialAction.calendarSync:
        return;
      case SettingsInitialAction.naverCalDav:
        if (_hasNaverCalDavCredentials) {
          _showSnack('네이버 캘린더가 이미 연결되어 있어 동기화를 시작합니다.');
        }
        await _syncOrReconnectNaverCalendar();
        return;
      case null:
        return;
    }
  }

  Future<void> _scrollToCalendarSyncSection() async {
    await Future<void>.delayed(const Duration(milliseconds: 120));
    if (!mounted) {
      return;
    }
    final sectionContext = _calendarSyncSectionKey.currentContext;
    if (sectionContext == null || !sectionContext.mounted) {
      return;
    }
    await Scrollable.ensureVisible(
      sectionContext,
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOutCubic,
      alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
    );
  }

  Future<void> _recheckNaverAccountConsent() async {
    if (_authService == null) {
      _showSnack('Supabase 설정 후 네이버 계정 정보를 다시 확인할 수 있습니다.');
      return;
    }
    if (!authProvider.isSignedIn) {
      _showSnack('먼저 PlanFlow에 로그인해 주세요.');
      return;
    }
    try {
      final completed = await context.push<bool>(
        '${AppRoutes.naverOAuth}?forceConsent=1',
      );
      if (mounted && completed != true && !authProvider.isSignedIn) {
        _showSnack('네이버 계정 정보 확인을 완료하지 않았습니다.');
      }
    } catch (error, stackTrace) {
      OAuthCallbackHandler.clearPendingCallback();
      debugPrint('Naver account recheck failed: $error');
      debugPrintStack(stackTrace: stackTrace);
      _showSnack('네이버 계정 정보 확인을 시작하지 못했습니다. 잠시 후 다시 시도해 주세요.');
    }
  }

  Future<void> _disconnectNaverCalendar() async {
    final authService = _authService;
    if (authService == null) {
      _showSnack('Supabase 설정 후 네이버 연동을 해제할 수 있습니다.');
      return;
    }
    if (!authProvider.isSignedIn) {
      _showSnack('먼저 PlanFlow에 로그인해 주세요.');
      return;
    }
    if (_isDisconnectingNaverCalendar) {
      return;
    }

    final deleteProviderEvents = await _askDisconnectPolicy('Naver Calendar');
    if (deleteProviderEvents == null) {
      return;
    }

    setState(() {
      _isDisconnectingNaverCalendar = true;
    });
    try {
      final unlinked = await authService.disconnectNaverCalendar();
      await _calendarSyncService.disconnectProvider(
        CalendarProvider.naver,
        deleteProviderEvents: deleteProviderEvents,
      );
      await _naverCalendarPermissionServiceInstance.clearConnectionState();
      await _naverCalDavService.clearCredentials();
      if (!mounted) {
        return;
      }
      await _loadCalendarStatus();
      if (!mounted) {
        return;
      }
      setState(() {
        _hasNaverCalDavCredentials = false;
        _lastNaverCalDavResult = null;
      });
      _showSnack(
        unlinked ? '네이버 연동을 해제했습니다.' : '네이버 연동 정보를 정리했습니다. 다시 동기화하면 새로 연결됩니다.',
      );
    } catch (error, stackTrace) {
      debugPrint('Naver calendar disconnect failed: $error');
      debugPrintStack(stackTrace: stackTrace);
      _showSnack('네이버 연동 해제에 실패했습니다. 잠시 후 다시 시도해 주세요.');
    } finally {
      if (mounted) {
        setState(() {
          _isDisconnectingNaverCalendar = false;
        });
      }
    }
  }

  Future<void> _pickTime({required bool isMorning}) async {
    final picked = await showTimePicker(
      context: context,
      initialTime: isMorning ? _morningBriefingAt : _eveningBriefingAt,
      builder: (context, child) {
        return MediaQuery(
          data: MediaQuery.of(context).copyWith(alwaysUse24HourFormat: true),
          child: child ?? const SizedBox.shrink(),
        );
      },
    );
    if (picked == null || !mounted) {
      return;
    }
    setState(() {
      if (isMorning) {
        _morningBriefingAt = picked;
      } else {
        _eveningBriefingAt = picked;
      }
    });
    unawaited(_persistSettings());
  }

  Future<void> _persistSettings({String? successMessage}) async {
    final userId = _userId;
    if (userId == null || userId.isEmpty) {
      return;
    }
    final saveVersion = ++_settingsSaveVersion;
    if (_isSavingSettings) {
      _settingsSaveQueued = true;
      _queuedSettingsSuccessMessage =
          successMessage ?? _queuedSettingsSuccessMessage;
      return;
    }

    setState(() {
      _isSavingSettings = true;
    });
    try {
      final current = await _settingsForSave(userId);
      final draft = current.copyWith(
        userId: userId,
        morningBriefingAt: _formatTimeValue(_morningBriefingAt),
        eveningBriefingAt: _formatTimeValue(_eveningBriefingAt),
        defaultReminderMin: _defaultReminderMinutes,
        prepTimeMin: _prepTimeMin,
        prepPreAlarmOffset: _prepPreAlarmOffset,
        departPreAlarmOffset: _departPreAlarmOffset,
        departureSafetyMarginMin: _departureSafetyMarginMin,
        travelMode: _travelMode,
        voiceAutoStart: _voiceAutoStart,
        preferredMapProvider: _preferredMapProvider,
        countryCode: _countryCode,
        localeCode: _localeCode,
        timeZoneId: _timeZoneId,
      );
      final saved = await _settingsProvider.save(draft);
      if (!mounted) {
        return;
      }
      final currentUiSettings = saved.copyWith(
        morningBriefingAt: draft.morningBriefingAt,
        eveningBriefingAt: draft.eveningBriefingAt,
        defaultReminderMin: draft.defaultReminderMin,
        prepTimeMin: draft.prepTimeMin,
        prepPreAlarmOffset: draft.prepPreAlarmOffset,
        departPreAlarmOffset: draft.departPreAlarmOffset,
        departureSafetyMarginMin: draft.departureSafetyMarginMin,
        travelMode: draft.travelMode,
        voiceAutoStart: draft.voiceAutoStart,
        preferredMapProvider: draft.preferredMapProvider,
        countryCode: draft.countryCode,
        localeCode: draft.localeCode,
        timeZoneId: draft.timeZoneId,
      );
      final isLatestSave =
          !_settingsSaveQueued && saveVersion == _settingsSaveVersion;
      if (isLatestSave) {
        setState(() {
          _savedSettings = currentUiSettings;
          _applySettings(currentUiSettings);
        });
      }
      if (isLatestSave) {
        final scheduleResult = await _scheduleBriefingsFromSettings(
          currentUiSettings,
          reason: 'settings_saved',
        );
        if (successMessage != null) {
          final suffix = scheduleResult?.allScheduled == false
              ? ' 브리핑 예약은 Android 알람 설정을 확인해 주세요.'
              : '';
          _showSnack('$successMessage$suffix');
        }
      }
    } catch (error, stackTrace) {
      debugPrint('Settings save failed: $error');
      debugPrintStack(stackTrace: stackTrace);
      _showSnack('설정 저장에 실패했습니다. Supabase 연결을 확인해 주세요.');
    } finally {
      if (mounted) {
        setState(() {
          _isSavingSettings = false;
        });
        if (_settingsSaveQueued) {
          final queuedMessage = _queuedSettingsSuccessMessage;
          _settingsSaveQueued = false;
          _queuedSettingsSuccessMessage = null;
          unawaited(_persistSettings(successMessage: queuedMessage));
        }
      }
    }
  }

  Future<BriefingDailyScheduleResult?> _scheduleBriefingsFromSettings(
    UserSettingsModel settings, {
    required String reason,
  }) async {
    final userId = _userId;
    if (userId == null || userId.isEmpty) {
      debugPrint('Briefing schedule skipped ($reason): signed out');
      return null;
    }

    try {
      final result = await _briefingSchedulerService.scheduleDaily(
        morningTime: settings.morningBriefingAt,
        eveningTime: settings.eveningBriefingAt,
        userId: userId,
      );
      debugPrint(
        'Briefing schedule updated ($reason): '
        'morning=${result.morning.scheduledAt.toIso8601String()} '
        'scheduled=${result.morning.scheduled}, '
        'evening=${result.evening.scheduledAt.toIso8601String()} '
        'scheduled=${result.evening.scheduled}, userId=$userId',
      );
      if (mounted) {
        unawaited(_loadAlarmRuntimeStatus());
      }
      return result;
    } catch (error, stackTrace) {
      debugPrint('Briefing schedule failed ($reason): $error');
      debugPrintStack(stackTrace: stackTrace);
      if (mounted && reason == 'settings_saved') {
        _showSnack('설정은 저장했지만 브리핑 예약에 실패했습니다. Android 알람 설정을 확인해 주세요.');
      }
      return null;
    }
  }

  Future<void> _testBriefing({required bool isMorning}) async {
    if (!RemoteConfigService.briefingEnabled) {
      _showSnack('브리핑 기능이 현재 비활성화되어 있습니다.');
      return;
    }

    final userId = _userId;
    if (userId == null || userId.isEmpty) {
      _showSnack('로그인 후 브리핑을 테스트할 수 있습니다.');
      return;
    }
    if (_isTestingMorningBriefing || _isTestingEveningBriefing) {
      return;
    }

    setState(() {
      if (isMorning) {
        _isTestingMorningBriefing = true;
      } else {
        _isTestingEveningBriefing = true;
      }
    });

    try {
      unawaited(
        AnalyticsService.logBriefingTestPlayed(isMorning: isMorning),
      );
      final result = await _briefingSchedulerService.executeBriefing(
        isMorning: isMorning,
        userId: userId,
      );
      _showSnack(result.message);
      if (mounted) {
        unawaited(_loadAlarmRuntimeStatus());
      }
    } catch (error, stackTrace) {
      debugPrint('Briefing test failed: $error');
      debugPrintStack(stackTrace: stackTrace);
      _showSnack('브리핑 테스트 재생에 실패했습니다. 알림/TTS 설정을 확인해 주세요.');
    } finally {
      if (mounted) {
        setState(() {
          if (isMorning) {
            _isTestingMorningBriefing = false;
          } else {
            _isTestingEveningBriefing = false;
          }
        });
      }
    }
  }

  Future<UserSettingsModel> _settingsForSave(String userId) async {
    var current = _savedSettings ?? UserSettingsModel.defaults(userId: userId);
    if (current.googleCalendarToken != null &&
        current.naverCalendarToken != null) {
      return current;
    }

    try {
      final latest = await _settingsRepository.fetchSettings(userId);
      if (latest == null) {
        return current;
      }
      current = current.copyWith(
        googleCalendarToken:
            current.googleCalendarToken ?? latest.googleCalendarToken,
        naverCalendarToken:
            current.naverCalendarToken ?? latest.naverCalendarToken,
      );
    } catch (error, stackTrace) {
      debugPrint('Settings token refresh before save failed: $error');
      debugPrintStack(stackTrace: stackTrace);
    }
    return current;
  }

  Future<void> _loadBackups() async {
    final backupService = _backupService;
    if (backupService == null || !authProvider.isSignedIn) {
      return;
    }
    setState(() {
      _isLoadingBackups = true;
    });
    try {
      final backups = await backupService.listBackups();
      if (!mounted) {
        return;
      }
      setState(() {
        _backups = backups;
      });
    } catch (_) {
      if (mounted) {
        _showSnack('백업 목록을 불러오지 못했습니다.');
      }
    } finally {
      if (mounted) {
        setState(() {
          _isLoadingBackups = false;
        });
      }
    }
  }

  Future<void> _ensureAutomaticBackup() async {
    final backupService = _backupService;
    if (backupService == null || !authProvider.isSignedIn) {
      return;
    }
    try {
      await _dailyBackupSchedulerService.scheduleDaily();
      final created = await _dailyBackupSchedulerService.runCatchUpIfDue(
        backupService,
      );
      if (created != null) {
        await _loadBackups();
      }
    } catch (error, stackTrace) {
      debugPrint('Automatic backup setup skipped: $error');
      debugPrintStack(stackTrace: stackTrace);
    }
  }

  Future<void> _createBackup() async {
    final backupService = _backupService;
    if (backupService == null || !authProvider.isSignedIn) {
      _showSnack('로그인 후 백업할 수 있습니다.');
      return;
    }
    setState(() {
      _isBackupActionRunning = true;
    });
    try {
      final backup = await backupService.createBackup();
      await _loadBackups();
      _showSnack('백업 완료: ${backup.totalItems}개 항목을 저장했습니다.');
    } catch (error, stackTrace) {
      debugPrint('Backup create failed: $error');
      debugPrintStack(stackTrace: stackTrace);
      _showSnack('백업 생성에 실패했습니다. Supabase 스키마를 확인해 주세요.');
    } finally {
      if (mounted) {
        setState(() {
          _isBackupActionRunning = false;
        });
      }
    }
  }

  Future<void> _restoreBackup(BackupSnapshot backup) async {
    final backupService = _backupService;
    if (backupService == null) {
      return;
    }
    final shouldRestore = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('백업 복원'),
        content: Text('${_formatDateTime(backup.createdAt)} 백업을 복원할까요?'),
        actionsPadding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
        actions: [
          _buildDialogButtonBar(
            onCancel: () => Navigator.of(context).pop(false),
            onConfirm: () => Navigator.of(context).pop(true),
            cancelLabel: '취소',
            confirmLabel: '복원',
          ),
        ],
      ),
    );
    if (shouldRestore != true) {
      return;
    }
    setState(() {
      _isBackupActionRunning = true;
    });
    try {
      await backupService.restoreBackup(backup.id);
      _showSnack('백업을 복원했습니다.');
    } catch (error, stackTrace) {
      debugPrint('Backup restore failed: $error');
      debugPrintStack(stackTrace: stackTrace);
      _showSnack('백업 복원에 실패했습니다. Supabase 권한과 스키마를 확인해 주세요.');
    } finally {
      if (mounted) {
        setState(() {
          _isBackupActionRunning = false;
        });
      }
    }
  }

  Future<void> _showBackupRestoreDialog() async {
    final backupService = _backupService;
    if (backupService == null || !authProvider.isSignedIn) {
      return;
    }
    if (!_isLoadingBackups && _backups.isEmpty) {
      await _loadBackups();
    }
    if (!mounted) {
      return;
    }
    if (_backups.isEmpty) {
      _showSnack('백업된 항목이 없습니다. 먼저 백업을 만들어 주세요.');
      return;
    }
    final selected = await showDialog<BackupSnapshot>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('복원할 백업 선택'),
        content: SizedBox(
          width: double.maxFinite,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 420),
            child: ListView.separated(
              shrinkWrap: true,
              itemCount: _backups.length,
              separatorBuilder: (_, __) => const SizedBox(height: 8),
              itemBuilder: (context, index) {
                final backup = _backups[index];
                return ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.backup_outlined),
                  title: Text(_formatDateTime(backup.createdAt)),
                  subtitle: Text('총 ${backup.totalItems}개 항목'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).pop(backup),
                );
              },
            ),
          ),
        ),
        actionsPadding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
        actions: [
          _buildDialogButtonBar(
            onCancel: () => Navigator.of(context).pop(),
            onConfirm: () => Navigator.of(context).pop(_backups.first),
            cancelLabel: '취소',
            confirmLabel: '가장 최근 복원',
          ),
        ],
      ),
    );
    if (selected == null) {
      return;
    }
    await _restoreBackup(selected);
  }

  void _resetToDefaults() {
    setState(() {
      _morningBriefingAt = const TimeOfDay(hour: 7, minute: 30);
      _eveningBriefingAt = const TimeOfDay(hour: 21, minute: 0);
      _defaultReminderMinutes = 60;
      _prepTimeMin = 30;
      _prepPreAlarmOffset = 30;
      _departPreAlarmOffset = 30;
      _departureSafetyMarginMin = 20;
      _travelMode = 'car';
      _voiceAutoStart = false;
      _hideWidgetWeekends = false;
      _preferredMapProvider = 'naver';
      _countryCode = PlanFlowRegions.korea.countryCode;
      _localeCode = PlanFlowRegions.korea.localeCode;
      _timeZoneId = PlanFlowRegions.korea.timeZoneId;
      PlanFlowRegionController.instance.reset();
    });
    unawaited(_homeWidgetService.setHideWeekends(false));
    unawaited(_persistSettings(successMessage: '설정을 기본값으로 되돌렸습니다.'));
  }

  void _applySettings(UserSettingsModel settings) {
    _morningBriefingAt = _parseTime(settings.morningBriefingAt);
    _eveningBriefingAt = _parseTime(settings.eveningBriefingAt);
    _defaultReminderMinutes = settings.defaultReminderMin;
    _prepTimeMin = settings.prepTimeMin;
    _prepPreAlarmOffset = settings.prepPreAlarmOffset;
    _departPreAlarmOffset = settings.departPreAlarmOffset;
    _departureSafetyMarginMin = settings.departureSafetyMarginMin;
    _travelMode = settings.travelMode;
    _voiceAutoStart = settings.voiceAutoStart;
    _preferredMapProvider = settings.preferredMapProvider;
    final region = PlanFlowRegions.byLocaleAndTimeZone(
      countryCode: settings.countryCode,
      localeCode: settings.localeCode,
      timeZoneId: settings.timeZoneId,
    );
    _countryCode = region.countryCode;
    _localeCode = region.localeCode;
    _timeZoneId = region.timeZoneId;
    PlanFlowRegionController.instance.setRegion(region);
  }

  void _showSnack(String message) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  Widget _buildRegionSettings() {
    final selectedRegion = PlanFlowRegions.byCountryCode(_countryCode);
    final l10n = appL10n(context);
    return _SectionCard(
      title: l10n.regionSettingsTitle,
      subtitle: l10n.regionSettingsSubtitle,
      child: DropdownButtonFormField<String>(
        key: const ValueKey('settings-region-country-selector'),
        initialValue: selectedRegion.countryCode,
        decoration: InputDecoration(
          labelText: l10n.countryLabel,
          isDense: true,
          prefixIcon: const Icon(Icons.public_outlined),
        ),
        items: PlanFlowRegions.supported
            .map(
              (region) => DropdownMenuItem<String>(
                value: region.countryCode,
                child: Text(
                  '${_localizedRegionName(context, region)} · ${region.timeZoneId}',
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            )
            .toList(growable: false),
        onChanged: (value) {
          if (value == null) {
            return;
          }
          final region = PlanFlowRegions.byCountryCode(value);
          setState(() {
            _countryCode = region.countryCode;
            _localeCode = region.localeCode;
            _timeZoneId = region.timeZoneId;
          });
          PlanFlowRegionController.instance.setRegion(region);
          unawaited(_persistSettings());
        },
      ),
    );
  }

  String _localizedRegionName(BuildContext context, PlanFlowRegion region) {
    final l10n = appL10n(context);
    return switch (region.countryCode) {
      'KR' => l10n.korea,
      'US' => l10n.unitedStates,
      'JP' => l10n.japan,
      'GB' => l10n.unitedKingdom,
      'DE' => l10n.germany,
      'FR' => l10n.france,
      'AU' => l10n.australia,
      _ => region.countryName,
    };
  }

  Widget _buildSmartAlarmSettings() {
    return _SectionCard(
      title: '스마트 출발 알림 설정',
      subtitle: '외부 일정마다 현재 위치와 이동시간을 다시 계산해 출발 시각을 알려줍니다.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SmartAlarmControl(
            title: '출발 여유 시간',
            helperText: '이동시간에 더해 늦지 않도록 미리 출발할 여유를 둡니다.',
            child: _buildSafetyMarginSelector(
              key: const ValueKey('settings-departure-safety-margin-selector'),
              value: _departureSafetyMarginMin,
              onChanged: (value) {
                setState(() {
                  _departureSafetyMarginMin = value;
                });
                unawaited(_persistSettings());
              },
            ),
          ),
          const SizedBox(height: 16),
          _SmartAlarmControl(
            title: '출발 사전 알림',
            helperText: '0분이면 사전 알림 없이 출발 알림만 받아요.',
            child: _buildOffsetSelector(
              key: const ValueKey('settings-depart-pre-alarm-selector'),
              value: _departPreAlarmOffset,
              onChanged: (value) {
                setState(() {
                  _departPreAlarmOffset = value;
                });
                unawaited(_persistSettings());
              },
            ),
          ),
          const SizedBox(height: 12),
          Text(
            '앱은 24시간 이내 일정을 백그라운드로 다시 확인하고, 6시간 이내 일정은 더 자주 갱신해요.',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: PlanFlowColors.textSecondary,
                  fontWeight: FontWeight.w600,
                ),
          ),
          const SizedBox(height: 12),
          _DepartureAlarmRuntimeStatusCard(
            isLoading: _isLoadingAlarmRuntimeStatus,
            status: _departureAlarmRuntimeStatus,
            formatDateTime: _formatDateTime,
            onRefresh: _loadAlarmRuntimeStatus,
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              key: const ValueKey('settings-critical-alarm-test-button'),
              onPressed: _isTestingCriticalAlarm
                  ? null
                  : _runCriticalAlarmDifferenceTest,
              icon: _isTestingCriticalAlarm
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.priority_high_rounded),
              label: Text(
                _isTestingCriticalAlarm ? '테스트 예약 중...' : '일반/중요 알림 차이 테스트',
              ),
              style: OutlinedButton.styleFrom(
                foregroundColor: const Color(0xFFB42318),
                side: const BorderSide(
                  color: Color(0xFFB42318),
                  width: 1.4,
                ),
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 12,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '일반 알림을 먼저 울리고, 잠시 뒤 중요 알림을 울려 소리·진동·잠금화면 차이를 확인합니다.',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: PlanFlowColors.textSecondary,
                  fontWeight: FontWeight.w600,
                ),
          ),
        ],
      ),
    );
  }

  Widget _buildOffsetSelector({
    required Key key,
    required int value,
    required ValueChanged<int> onChanged,
  }) {
    final selected =
        value == 0 || value == 10 || value == 30 || value == 31 ? value : 30;
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: SegmentedButton<int>(
        key: key,
        showSelectedIcon: false,
        segments: const <ButtonSegment<int>>[
          ButtonSegment<int>(value: 0, label: Text('안 받기')),
          ButtonSegment<int>(value: 10, label: Text('10분 전')),
          ButtonSegment<int>(value: 30, label: Text('30분 전')),
          ButtonSegment<int>(value: 31, label: Text('둘 다')),
        ],
        selected: <int>{selected},
        onSelectionChanged: (selected) => onChanged(selected.first),
      ),
    );
  }

  Widget _buildSafetyMarginSelector({
    required Key key,
    required int value,
    required ValueChanged<int> onChanged,
  }) {
    final selected = value == 10 || value == 20 || value == 30 ? value : 20;
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: SegmentedButton<int>(
        key: key,
        showSelectedIcon: false,
        segments: const <ButtonSegment<int>>[
          ButtonSegment<int>(value: 10, label: Text('10분')),
          ButtonSegment<int>(value: 20, label: Text('20분')),
          ButtonSegment<int>(value: 30, label: Text('30분')),
        ],
        selected: <int>{selected},
        onSelectionChanged: (selected) => onChanged(selected.first),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final responsiveSize = context.planflowResponsiveSize;
    final contentMaxWidth = responsiveSize.isCompact ? 920.0 : 980.0;
    final morningLabel = _formatTime(context, _morningBriefingAt);
    final eveningLabel = _formatTime(context, _eveningBriefingAt);
    final nextBriefings = _briefingSchedulerService.nextDailyTimes(
      morningTime: _formatTimeValue(_morningBriefingAt),
      eveningTime: _formatTimeValue(_eveningBriefingAt),
    );

    return Scaffold(
      backgroundColor: PlanFlowColors.background,
      appBar: AppBar(
        title: const PlanFlowLogo(),
        actions: [
          IconButton(
            tooltip: appL10n(context).resetDefaultsTooltip,
            onPressed: _resetToDefaults,
            icon: const Icon(Icons.restart_alt),
          ),
        ],
      ),
      body: SafeArea(
        child: ResponsiveContent(
          maxWidth: contentMaxWidth,
          child: ListView(
            padding: const EdgeInsets.all(AppConstants.defaultPadding),
            children: [
              _AccountSection(
                authService: _authService,
                onRecheckNaverAccount: _recheckNaverAccountConsent,
                onSignedOut: () {
                  if (mounted) {
                    context.go(AppRoutes.login);
                  }
                },
              ),
              const SizedBox(height: 16),
              _SectionCard(
                title: '브리핑 시간',
                subtitle: '모닝/이브닝 브리핑이 울릴 시간을 정합니다.',
                child: Column(
                  children: [
                    _TimeSettingTile(
                      title: '모닝 브리핑',
                      subtitle:
                          '다음 예약 ${_formatDateTime(nextBriefings.morning)}',
                      value: morningLabel,
                      icon: Icons.wb_sunny_outlined,
                      onTap: () => _pickTime(isMorning: true),
                      trailingAction: _BriefingTestButton(
                        isLoading: _isTestingMorningBriefing,
                        tooltip: '모닝 브리핑 테스트 재생',
                        onPressed: () => _testBriefing(isMorning: true),
                      ),
                    ),
                    const Divider(height: 1),
                    _TimeSettingTile(
                      title: '이브닝 브리핑',
                      subtitle:
                          '다음 예약 ${_formatDateTime(nextBriefings.evening)}',
                      value: eveningLabel,
                      icon: Icons.nightlight_outlined,
                      onTap: () => _pickTime(isMorning: false),
                      trailingAction: _BriefingTestButton(
                        isLoading: _isTestingEveningBriefing,
                        tooltip: '이브닝 브리핑 테스트 재생',
                        onPressed: () => _testBriefing(isMorning: false),
                      ),
                    ),
                    const SizedBox(height: 12),
                    _BriefingRuntimeStatusCard(
                      isLoading: _isLoadingAlarmRuntimeStatus,
                      status: _briefingRuntimeStatus,
                      formatDateTime: _formatDateTime,
                      onRefresh: _loadAlarmRuntimeStatus,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              _SectionCard(
                title: '이동수단',
                subtitle: '위치 기반 이동시간 계산과 스마트 준비 알람에 우선 적용할 방식을 정합니다.',
                child: SegmentedButton<String>(
                  key: const ValueKey('settings-travel-mode-selector'),
                  segments: const <ButtonSegment<String>>[
                    ButtonSegment<String>(
                      value: 'car',
                      icon: Icon(Icons.directions_car_outlined),
                      label: Text('자동차'),
                    ),
                    ButtonSegment<String>(
                      value: 'transit',
                      icon: Icon(Icons.directions_transit_outlined),
                      label: Text('대중교통'),
                    ),
                  ],
                  selected: <String>{_travelMode},
                  onSelectionChanged: (selected) {
                    setState(() {
                      _travelMode = selected.first;
                    });
                    unawaited(_persistSettings());
                  },
                ),
              ),
              const SizedBox(height: 16),
              _SectionCard(
                title: '기본 지도',
                subtitle: '위치 검색과 외부 지도 열기에서 먼저 사용할 지도를 정합니다.',
                child: SegmentedButton<String>(
                  key: const ValueKey(
                      'settings-preferred-map-provider-selector'),
                  segments: const <ButtonSegment<String>>[
                    ButtonSegment<String>(
                      value: 'naver',
                      icon: Icon(Icons.map_outlined),
                      label: Text('네이버 지도'),
                    ),
                    ButtonSegment<String>(
                      value: 'google',
                      icon: Icon(Icons.public_outlined),
                      label: Text('Google 지도'),
                    ),
                    ButtonSegment<String>(
                      value: 'tmap',
                      icon: Icon(Icons.route_outlined),
                      label: Text('TMAP'),
                    ),
                  ],
                  selected: <String>{_preferredMapProvider},
                  onSelectionChanged: (selected) {
                    setState(() {
                      _preferredMapProvider = selected.first;
                    });
                    unawaited(_persistSettings());
                  },
                ),
              ),
              const SizedBox(height: 16),
              _SectionCard(
                title: '음성 입력 방식',
                subtitle: '홈이나 위젯의 마이크 버튼을 눌렀을 때 바로 듣기 시작할지 정합니다.',
                child: SwitchListTile.adaptive(
                  key: const ValueKey('settings-voice-auto-start-selector'),
                  contentPadding: EdgeInsets.zero,
                  value: _voiceAutoStart,
                  activeThumbColor: PlanFlowColors.primary,
                  activeTrackColor: PlanFlowColors.primaryFaint,
                  title: const Text('화면 열면 바로 시작'),
                  subtitle: Text(
                    _voiceAutoStart ? '화면을 열자마자 듣기 시작' : '버튼 눌러 시작(기본)',
                  ),
                  onChanged: (value) {
                    setState(() {
                      _voiceAutoStart = value;
                    });
                    unawaited(_persistSettings());
                  },
                ),
              ),
              const SizedBox(height: 16),
              _SectionCard(
                title: '홈 위젯 표시',
                subtitle: '업무용으로 볼 때 위젯에서 주말 칸과 주말 일정을 숨길 수 있습니다.',
                child: SwitchListTile.adaptive(
                  key: const ValueKey('settings-widget-hide-weekends'),
                  contentPadding: EdgeInsets.zero,
                  value: _hideWidgetWeekends,
                  activeThumbColor: PlanFlowColors.primary,
                  activeTrackColor: PlanFlowColors.primaryFaint,
                  title: const Text('주말 숨기기'),
                  subtitle: Text(
                    _hideWidgetWeekends
                        ? '토·일 칸을 숨겨 평일 정보를 더 넓게 표시'
                        : '토·일 일정도 위젯에 함께 표시',
                  ),
                  onChanged: (value) {
                    setState(() {
                      _hideWidgetWeekends = value;
                    });
                    unawaited(_homeWidgetService.setHideWeekends(value));
                  },
                ),
              ),
              const SizedBox(height: 16),
              _buildSmartAlarmSettings(),
              const SizedBox(height: 16),
              KeyedSubtree(
                key: _calendarSyncSectionKey,
                child: _SectionCard(
                  title: appL10n(context).calendarSyncTitle,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: PlanFlowColors.primaryFaint
                              .withValues(alpha: 0.42),
                          borderRadius: BorderRadius.circular(12),
                          border:
                              Border.all(color: PlanFlowColors.primaryFaint),
                        ),
                        child: Text(
                          '알림은 PlanFlow 기준으로 울립니다. 외부 캘린더 앱의 기본 알림이 켜져 있으면 해당 앱에서도 알림이 울릴 수 있어요.',
                          style:
                              Theme.of(context).textTheme.bodySmall?.copyWith(
                                    color: PlanFlowColors.textPrimary,
                                    fontWeight: FontWeight.w600,
                                  ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      _StatusRow(
                        label: 'Google Calendar',
                        value:
                            _calendarStatusLabel(_calendarSyncSummary?.google),
                        icon: Icons.cloud_sync_outlined,
                        isConfigured: _isCalendarConfigured(
                          _calendarSyncSummary?.google,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: _isDisconnectingGoogleCalendar ||
                                      !_canDisconnectCalendar(
                                        _calendarSyncSummary?.google,
                                      )
                                  ? null
                                  : _disconnectGoogleCalendar,
                              icon: _isDisconnectingGoogleCalendar
                                  ? const SizedBox.square(
                                      dimension: 18,
                                      child: CircularProgressIndicator(
                                          strokeWidth: 2),
                                    )
                                  : const Icon(Icons.link_off),
                              label: Text(
                                _isDisconnectingGoogleCalendar
                                    ? '해제 중...'
                                    : '연동 해제',
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: FilledButton.icon(
                              key: const ValueKey(
                                'settings-google-calendar-sync-button',
                              ),
                              onPressed: _isLoadingCalendarStatus ||
                                      _isSyncingGoogleCalendar ||
                                      _isDisconnectingGoogleCalendar
                                  ? null
                                  : _syncGoogleCalendar,
                              icon: const Icon(Icons.sync),
                              label: Text(_googleCalendarActionLabel()),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      const Divider(height: 1),
                      const SizedBox(height: 16),
                      InkWell(
                        borderRadius: BorderRadius.circular(12),
                        onTap: _isLoadingCalendarStatus ||
                                _isTestingNaverCalDav ||
                                _isImportingNaverCalDav ||
                                _isDisconnectingNaverCalendar
                            ? null
                            : _syncOrReconnectNaverCalendar,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 2),
                          child: Column(
                            children: [
                              _StatusRow(
                                label: '네이버 캘린더',
                                value: _naverCalendarStatusLabel(),
                                icon: Icons.event_available_outlined,
                                isConfigured: _hasNaverCalDavCredentials,
                              ),
                              const SizedBox(height: 12),
                              Row(
                                children: [
                                  Expanded(
                                    child: OutlinedButton.icon(
                                      onPressed: _isDisconnectingNaverCalendar ||
                                              !(_hasNaverCalDavCredentials ||
                                                  _canDisconnectCalendar(
                                                    _calendarSyncSummary?.naver,
                                                  ))
                                          ? null
                                          : _disconnectNaverCalendar,
                                      icon: _isDisconnectingNaverCalendar
                                          ? const SizedBox.square(
                                              dimension: 18,
                                              child: CircularProgressIndicator(
                                                strokeWidth: 2,
                                              ),
                                            )
                                          : const Icon(Icons.link_off),
                                      label: Text(
                                        _isDisconnectingNaverCalendar
                                            ? '해제 중...'
                                            : '연동 해제',
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: FilledButton.icon(
                                      key: const ValueKey(
                                        'settings-naver-calendar-sync-button',
                                      ),
                                      onPressed: _isLoadingCalendarStatus ||
                                              _isTestingNaverCalDav ||
                                              _isImportingNaverCalDav ||
                                              _isDisconnectingNaverCalendar
                                          ? null
                                          : _syncOrReconnectNaverCalendar,
                                      icon: const Icon(Icons.sync),
                                      label: Text(
                                        '네이버 일정 동기화',
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 12),
                              Align(
                                alignment: Alignment.centerLeft,
                                child: Text(
                                  '보조 기능: 삼성/구글/기타 휴대폰 캘린더 저장소에 이미 동기화된 일정을 가져올 수 있습니다.',
                                  style: Theme.of(context)
                                      .textTheme
                                      .bodySmall
                                      ?.copyWith(
                                        color: PlanFlowColors.textSecondary,
                                      ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton.icon(
                              key: const ValueKey(
                                'settings-device-calendar-disconnect-button',
                              ),
                              onPressed: _isDisconnectingDeviceCalendar ||
                                      _isImportingDeviceNaverCalendar
                                  ? null
                                  : _disconnectDeviceCalendarImport,
                              icon: _isDisconnectingDeviceCalendar
                                  ? const SizedBox.square(
                                      dimension: 18,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : const Icon(Icons.link_off),
                              label: Text(
                                _isDisconnectingDeviceCalendar
                                    ? '해제 중...'
                                    : '연동 해제',
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: FilledButton.icon(
                              key: const ValueKey(
                                'settings-device-calendar-import-button',
                              ),
                              onPressed: _isImportingDeviceNaverCalendar ||
                                      _isDisconnectingDeviceCalendar
                                  ? null
                                  : _importDeviceNaverCalendar,
                              icon: const Icon(Icons.phone_android_outlined),
                              label: Text(
                                '휴대폰 내부 캘린더 일정 가져오기',
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              FeedbackReportSection(
                onPressed: _openFeedbackReportSheet,
                onOpenAdminInbox:
                    _isFeedbackAdmin ? _openFeedbackAdminReportsSheet : null,
                newAdminReportCount: _newFeedbackReportCount,
                isLoadingAdminReportCount: _isLoadingNewFeedbackReportCount,
              ),
              const SizedBox(height: 16),
              if (AppEnv.isSupabaseReady &&
                  authProvider.isSignedIn &&
                  _backupService != null) ...[
                _SectionCard(
                  title: appL10n(context).backupRestoreTitle,
                  subtitle: '수동 백업과 매일 새벽 3시 자동 백업 기록을 관리합니다.',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: FilledButton.icon(
                              onPressed:
                                  _isBackupActionRunning ? null : _createBackup,
                              icon: _isBackupActionRunning
                                  ? const SizedBox.square(
                                      dimension: 18,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : const Icon(Icons.cloud_upload_outlined),
                              label: const Text('백업 만들기'),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: _isBackupActionRunning
                                  ? null
                                  : _showBackupRestoreDialog,
                              icon: const Icon(Icons.restore_outlined),
                              label: const Text('복원'),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      const Text('복원 버튼을 누르면 백업 목록이 열립니다.'),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
              ],
              _buildRegionSettings(),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _openFeedbackReportSheet() async {
    FeedbackRepository repository;
    try {
      repository = FeedbackRepository.supabase();
    } on FeedbackSubmissionException catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error.message)),
      );
      return;
    }

    final submitted = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => FeedbackReportSheet(
        repository: repository,
        routeOrScreen: 'settings',
      ),
    );
    if (!mounted || submitted != true) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('문제 신고를 보냈어요. 확인하고 반영할게요.')),
    );
  }

  Future<void> _openFeedbackAdminReportsSheet() async {
    if (!_isFeedbackAdmin) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('관리자 계정에서만 신고함을 열 수 있어요.')),
      );
      return;
    }

    FeedbackRepository repository;
    try {
      repository = FeedbackRepository.supabase();
    } on FeedbackSubmissionException catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error.message)),
      );
      return;
    }

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => FeedbackAdminReportsSheet(
        repository: repository,
      ),
    );
    await _refreshNewFeedbackReportCount();
  }

  String _formatTime(BuildContext context, TimeOfDay timeOfDay) {
    return MaterialLocalizations.of(context).formatTimeOfDay(
      timeOfDay,
      alwaysUse24HourFormat: true,
    );
  }

  String _formatTimeValue(TimeOfDay timeOfDay) {
    return '${timeOfDay.hour.toString().padLeft(2, '0')}:${timeOfDay.minute.toString().padLeft(2, '0')}';
  }

  TimeOfDay _parseTime(String value) {
    final match = RegExp(r'^(\d{2}):(\d{2})').firstMatch(value);
    if (match == null) {
      return const TimeOfDay(hour: 7, minute: 30);
    }
    return TimeOfDay(
      hour: int.tryParse(match.group(1) ?? '') ?? 7,
      minute: int.tryParse(match.group(2) ?? '') ?? 30,
    );
  }

  String _formatDateTime(DateTime value) {
    return '${value.year}-${value.month.toString().padLeft(2, '0')}-${value.day.toString().padLeft(2, '0')} '
        '${value.hour.toString().padLeft(2, '0')}:${value.minute.toString().padLeft(2, '0')}';
  }

  String _calendarStatusLabel(CalendarIntegrationResult? result) {
    if (_isLoadingCalendarStatus || result == null) {
      return '확인 중...';
    }
    return result.message;
  }

  String _googleCalendarActionLabel() {
    final status = _calendarSyncSummary?.google.status;
    return switch (status) {
      CalendarIntegrationStatus.ready ||
      CalendarIntegrationStatus.synced ||
      CalendarIntegrationStatus.reauthRequired ||
      CalendarIntegrationStatus.failed =>
        'Google Calendar 다시 동기화',
      _ => 'Google Calendar 연결',
    };
  }

  String _naverCalendarStatusLabel() {
    if (_hasNaverCalDavCredentials) {
      return _lastNaverCalDavResult?.message ?? 'CalDAV 연결됨';
    }
    return 'CalDAV 연결 안 됨';
  }

  bool _isCalendarConfigured(CalendarIntegrationResult? result) {
    if (result == null) {
      return false;
    }
    return switch (result.status) {
      CalendarIntegrationStatus.ready ||
      CalendarIntegrationStatus.syncing ||
      CalendarIntegrationStatus.synced ||
      CalendarIntegrationStatus.reauthRequired =>
        true,
      CalendarIntegrationStatus.signedOut ||
      CalendarIntegrationStatus.notConfigured ||
      CalendarIntegrationStatus.unsupported ||
      CalendarIntegrationStatus.failed =>
        false,
    };
  }

  bool _canDisconnectCalendar(CalendarIntegrationResult? result) {
    return switch (result?.status) {
      CalendarIntegrationStatus.ready ||
      CalendarIntegrationStatus.syncing ||
      CalendarIntegrationStatus.synced ||
      CalendarIntegrationStatus.reauthRequired ||
      CalendarIntegrationStatus.failed =>
        true,
      _ => false,
    };
  }

  String? get _googleCalendarClientId {
    if (kIsWeb) {
      return AppEnv.googleWebClientId;
    }
    return switch (defaultTargetPlatform) {
      TargetPlatform.android => null,
      TargetPlatform.iOS ||
      TargetPlatform.macOS =>
        AppEnv.googleAndroidClientId,
      TargetPlatform.fuchsia ||
      TargetPlatform.linux ||
      TargetPlatform.windows =>
        null,
    };
  }

  String? get _googleCalendarServerClientId {
    if (kIsWeb) {
      return null;
    }
    return switch (defaultTargetPlatform) {
      TargetPlatform.android => AppEnv.googleServerClientId,
      TargetPlatform.iOS ||
      TargetPlatform.macOS ||
      TargetPlatform.fuchsia ||
      TargetPlatform.linux ||
      TargetPlatform.windows =>
        null,
    };
  }
}

class _UnavailableSettingsRepository extends SettingsRepository {
  @override
  Future<UserSettingsModel?> fetchSettings(String userId) async => null;

  @override
  Future<UserSettingsModel> upsertSettings(UserSettingsModel settings) async {
    return settings;
  }
}

class _NaverCalDavCredentials {
  const _NaverCalDavCredentials({
    required this.naverId,
    required this.appPassword,
  });

  final String naverId;
  final String appPassword;
}

class _NaverCalDavImportRange {
  _NaverCalDavImportRange({
    required this.mode,
    required this.from,
    required this.to,
    required this.label,
  });

  factory _NaverCalDavImportRange.months(int months) {
    final now = DateTime.now().toUtc();
    return _NaverCalDavImportRange(
      mode: NaverCalDavSyncMode.custom,
      from: DateTime.utc(now.year, now.month - months, now.day),
      to: DateTime.utc(now.year, now.month + 6, now.day),
      label: '과거 $months개월',
    );
  }

  factory _NaverCalDavImportRange.years(int years) {
    final now = DateTime.now().toUtc();
    return _NaverCalDavImportRange(
      mode: NaverCalDavSyncMode.custom,
      from: DateTime.utc(now.year - years, now.month, now.day),
      to: DateTime.utc(now.year, now.month + 6, now.day),
      label: '과거 $years년',
    );
  }

  factory _NaverCalDavImportRange.all() {
    return _NaverCalDavImportRange(
      mode: NaverCalDavSyncMode.all,
      from: null,
      to: null,
      label: '전체',
    );
  }

  final NaverCalDavSyncMode mode;
  final DateTime? from;
  final DateTime? to;
  final String label;
}

class _AccountSection extends StatelessWidget {
  const _AccountSection({
    required this.authService,
    required this.onRecheckNaverAccount,
    required this.onSignedOut,
  });

  final AuthService? authService;
  final Future<void> Function() onRecheckNaverAccount;
  final VoidCallback onSignedOut;

  @override
  Widget build(BuildContext context) {
    if (!AppEnv.isSupabaseReady) {
      return _SectionCard(
        title: '계정',
        subtitle: '현재 로그인 상태를 확인하고 필요하면 로그아웃할 수 있습니다.',
        child: Column(
          children: [
            const _StatusRow(
              label: '로그인 상태',
              value: '로그아웃됨',
              icon: Icons.account_circle_outlined,
              isConfigured: false,
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton(
                onPressed: () => context.go(AppRoutes.login),
                child: const Text('로그인'),
              ),
            ),
          ],
        ),
      );
    }

    return _SectionCard(
      title: '계정',
      subtitle: '현재 로그인 상태를 확인하고 필요하면 로그아웃할 수 있습니다.',
      child: AnimatedBuilder(
        animation: authProvider,
        builder: (context, _) {
          final signedIn = authProvider.isSignedIn;
          final showNaverRecheck = signedIn && authProvider.isNaverAccount;
          return Column(
            children: [
              _StatusRow(
                label: '로그인 상태',
                value: signedIn ? authProvider.accountDisplayName : '로그아웃됨',
                icon: Icons.account_circle_outlined,
                isConfigured: signedIn,
              ),
              if (signedIn && authProvider.provider != null) ...[
                const SizedBox(height: 6),
                _AccountDetailText('로그인 방식: ${authProvider.providerLabel}'),
              ],
              if (authProvider.socialAccountInfoIncomplete) ...[
                const SizedBox(height: 8),
                const _InlineNotice(
                  icon: Icons.info_outline,
                  text:
                      '소셜 로그인은 되었지만 계정 이메일/이름을 확인하지 못했습니다. 제공 항목 동의나 provider 설정을 다시 확인해 주세요.',
                ),
              ],
              if (showNaverRecheck) ...[
                const SizedBox(height: 10),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: onRecheckNaverAccount,
                    icon: const Icon(Icons.refresh_outlined),
                    label: const Text('네이버 계정 정보 다시 확인'),
                  ),
                ),
              ],
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: signedIn
                    ? FilledButton(
                        onPressed: () async {
                          await authService?.signOut();
                          onSignedOut();
                        },
                        style: FilledButton.styleFrom(
                          backgroundColor: PlanFlowColors.primaryMid,
                          foregroundColor: Colors.white,
                          minimumSize: const Size.fromHeight(48),
                        ),
                        child: const Text('로그아웃'),
                      )
                    : OutlinedButton(
                        onPressed: () => context.go(AppRoutes.login),
                        child: const Text('로그인'),
                      ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _NaverGuideThumbnail extends StatelessWidget {
  const _NaverGuideThumbnail({
    required this.title,
    required this.assetPath,
  });

  final String title;
  final String assetPath;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: () => _showNaverGuideImage(
        context,
        title: title,
        assetPath: assetPath,
      ),
      borderRadius: BorderRadius.circular(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: theme.textTheme.labelLarge?.copyWith(
              color: PlanFlowColors.primary,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: AspectRatio(
              aspectRatio: 1.55,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Colors.white,
                  border: Border.all(
                    color: PlanFlowColors.primaryFaint,
                  ),
                ),
                child: Image.asset(
                  assetPath,
                  fit: BoxFit.cover,
                  errorBuilder: (context, error, stackTrace) {
                    return const Center(
                      child: Icon(
                        Icons.image_not_supported_outlined,
                        color: PlanFlowColors.textSecondary,
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

Future<void> _showNaverGuideImage(
  BuildContext context, {
  required String title,
  required String assetPath,
}) async {
  await showDialog<void>(
    context: context,
    builder: (context) {
      return Dialog.fullscreen(
        backgroundColor: const Color(0xFF101820),
        child: SafeArea(
          child: Column(
            children: [
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        title,
                        style:
                            Theme.of(context).textTheme.titleMedium?.copyWith(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w900,
                                ),
                      ),
                    ),
                    IconButton(
                      tooltip: '닫기',
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.close, color: Colors.white),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: InteractiveViewer(
                  minScale: 0.7,
                  maxScale: 4,
                  child: Center(
                    child: Image.asset(
                      assetPath,
                      fit: BoxFit.contain,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({
    required this.title,
    required this.child,
    this.subtitle,
  });

  final String title;
  final String? subtitle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      color: PlanFlowColors.surface,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: const BorderSide(color: PlanFlowColors.primaryFaint, width: 0.5),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: theme.textTheme.titleMedium?.copyWith(
                color: PlanFlowColors.primary,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
            if (subtitle != null && subtitle!.trim().isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                subtitle!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: PlanFlowColors.textSecondary,
                ),
              ),
            ],
            const SizedBox(height: 16),
            child,
          ],
        ),
      ),
    );
  }
}

class _PrepTimeInputDialog extends StatefulWidget {
  const _PrepTimeInputDialog({required this.initialValue});

  final int initialValue;

  @override
  State<_PrepTimeInputDialog> createState() => _PrepTimeInputDialogState();
}

class _PrepTimeInputDialogState extends State<_PrepTimeInputDialog> {
  late final TextEditingController _controller;
  late final FocusNode _focusNode;
  String? _errorText;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialValue.toString());
    _focusNode = FocusNode();
  }

  @override
  void dispose() {
    _focusNode.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final parsed = int.tryParse(_controller.text.trim());
    if (parsed == null) {
      setState(() {
        _errorText = '준비 시간을 숫자로 입력해 주세요.';
      });
      return;
    }
    if (parsed < 5 || parsed > 240) {
      setState(() {
        _errorText = '5분부터 240분 사이로 입력해 주세요.';
      });
      return;
    }
    Navigator.of(context).pop(parsed);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('준비 시간 직접 입력'),
      content: SingleChildScrollView(
        child: TextField(
          controller: _controller,
          focusNode: _focusNode,
          keyboardType: TextInputType.number,
          autofocus: true,
          inputFormatters: [
            FilteringTextInputFormatter.digitsOnly,
          ],
          decoration: InputDecoration(
            labelText: '분 단위',
            hintText: '예: 50',
            errorText: _errorText,
          ),
          onChanged: (_) {
            if (_errorText != null) {
              setState(() {
                _errorText = null;
              });
            }
          },
          onSubmitted: (_) => _submit(),
        ),
      ),
      actionsPadding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
      actions: [
        Row(
          children: [
            Expanded(
              child: FilledButton.tonal(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('취소'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: FilledButton(
                onPressed: _submit,
                child: const Text('저장'),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _SmartAlarmControl extends StatelessWidget {
  const _SmartAlarmControl({
    required this.title,
    required this.helperText,
    required this.child,
  });

  final String title;
  final String helperText;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: theme.textTheme.titleSmall?.copyWith(
            color: PlanFlowColors.primary,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          helperText,
          style: theme.textTheme.bodySmall?.copyWith(
            color: PlanFlowColors.textSecondary,
          ),
        ),
        const SizedBox(height: 8),
        child,
      ],
    );
  }
}

class _TimeSettingTile extends StatelessWidget {
  const _TimeSettingTile({
    required this.title,
    required this.subtitle,
    required this.value,
    required this.icon,
    required this.onTap,
    this.trailingAction,
  });

  final String title;
  final String subtitle;
  final String value;
  final IconData icon;
  final VoidCallback onTap;
  final Widget? trailingAction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: PlanFlowColors.background,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, color: PlanFlowColors.primaryMid),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: PlanFlowColors.primary,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(subtitle, style: theme.textTheme.bodySmall),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Text(
              value,
              style: theme.textTheme.titleSmall?.copyWith(
                color: PlanFlowColors.primaryMid,
              ),
            ),
            const SizedBox(width: 4),
            const Icon(Icons.chevron_right, color: PlanFlowColors.primaryMid),
            if (trailingAction != null) ...[
              const SizedBox(width: 4),
              trailingAction!,
            ],
          ],
        ),
      ),
    );
  }
}

class _BriefingTestButton extends StatelessWidget {
  const _BriefingTestButton({
    required this.isLoading,
    required this.tooltip,
    required this.onPressed,
  });

  final bool isLoading;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      onPressed: isLoading ? null : onPressed,
      icon: isLoading
          ? const SizedBox.square(
              dimension: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.play_arrow_outlined),
    );
  }
}

class _NaverDiagnosticCountTable extends StatelessWidget {
  const _NaverDiagnosticCountTable({required this.diagnostics});

  final NaverCalDavSyncDiagnostics diagnostics;

  @override
  Widget build(BuildContext context) {
    final rows = <(String, int)>[
      ('읽음', diagnostics.rawEvents),
      ('파싱 성공', diagnostics.parsedEvents),
      ('파싱 실패', diagnostics.invalidEvents),
      ('저장 대상', diagnostics.saveCandidates),
      ('저장', diagnostics.saved),
      ('중복 스킵', diagnostics.duplicateSkipped),
      ('변경 없음', diagnostics.unchangedSkipped),
      ('실패', diagnostics.failed),
    ];
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: PlanFlowColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: PlanFlowColors.primaryFaint),
      ),
      child: Wrap(
        children: rows.map((row) {
          return SizedBox(
            width: 132,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    row.$1,
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: PlanFlowColors.textSecondary,
                        ),
                  ),
                  Text(
                    '${row.$2}개',
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          color: PlanFlowColors.primary,
                          fontWeight: FontWeight.w800,
                        ),
                  ),
                ],
              ),
            ),
          );
        }).toList(growable: false),
      ),
    );
  }
}

class _BriefingRuntimeStatusCard extends StatelessWidget {
  const _BriefingRuntimeStatusCard({
    required this.isLoading,
    required this.status,
    required this.formatDateTime,
    required this.onRefresh,
  });

  final bool isLoading;
  final BriefingRuntimeStatus? status;
  final String Function(DateTime value) formatDateTime;
  final Future<void> Function() onRefresh;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final current = status;
    final lastExecutedAt = current?.lastExecutedAt;
    final lastType = switch (current?.lastExecutedType) {
      'morning' => '모닝',
      'evening' => '이브닝',
      _ => '브리핑',
    };
    final delivered = current?.lastExecutionDelivered;
    final lastExecutionText = lastExecutedAt == null
        ? '최근 재생 기록이 아직 없습니다.'
        : '최근 재생: $lastType · ${formatDateTime(lastExecutedAt)} · '
            '${delivered == true ? '성공' : '실패'}'
            '${current?.lastExecutionFailureReason == null ? '' : ' · ${current!.lastExecutionFailureReason}'}';

    return _RuntimeStatusContainer(
      key: const ValueKey('settings-briefing-runtime-status-card'),
      title: '브리핑 예약 상태',
      icon: Icons.record_voice_over_outlined,
      isLoading: isLoading,
      onRefresh: onRefresh,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _RuntimeStatusLine(
            label: '모닝',
            value: _briefingScheduleLabel(
              scheduled: current?.morningScheduled,
              scheduledAt: current?.nextMorningAt,
            ),
          ),
          const SizedBox(height: 6),
          _RuntimeStatusLine(
            label: '이브닝',
            value: _briefingScheduleLabel(
              scheduled: current?.eveningScheduled,
              scheduledAt: current?.nextEveningAt,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            lastExecutionText,
            style: theme.textTheme.bodySmall?.copyWith(
              color: PlanFlowColors.textSecondary,
            ),
          ),
          if (current?.lastExecutionMessage?.isNotEmpty == true) ...[
            const SizedBox(height: 4),
            Text(
              current!.lastExecutionMessage!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: PlanFlowColors.textSecondary,
              ),
            ),
          ],
        ],
      ),
    );
  }

  String _briefingScheduleLabel({
    required bool? scheduled,
    required DateTime? scheduledAt,
  }) {
    final state = switch (scheduled) {
      true => '예약됨',
      false => '예약 실패',
      null => '기록 없음',
    };
    final time = scheduledAt == null ? '' : ' · ${formatDateTime(scheduledAt)}';
    return '$state$time';
  }
}

class _DepartureAlarmRuntimeStatusCard extends StatelessWidget {
  const _DepartureAlarmRuntimeStatusCard({
    required this.isLoading,
    required this.status,
    required this.formatDateTime,
    required this.onRefresh,
  });

  final bool isLoading;
  final DepartureAlarmRuntimeStatus? status;
  final String Function(DateTime value) formatDateTime;
  final Future<void> Function() onRefresh;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final current = status;
    final eventTitle = current?.lastEventTitle;
    final hasScheduleRecord =
        current?.lastStatus != null || current?.lastCheckedAt != null;
    final scheduleText = !hasScheduleRecord
        ? '아직 출발 알림 예약 기록이 없습니다.'
        : _scheduleSummary(current!);
    final monitorText = _monitorSummary(current);

    return _RuntimeStatusContainer(
      key: const ValueKey('settings-departure-alarm-runtime-status-card'),
      title: '출발 알림 상태',
      icon: Icons.directions_run_outlined,
      isLoading: isLoading,
      onRefresh: onRefresh,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (eventTitle?.isNotEmpty == true) ...[
            Text(
              eventTitle!,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: PlanFlowColors.textPrimary,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 4),
          ],
          Text(
            scheduleText,
            style: theme.textTheme.bodySmall?.copyWith(
              color: PlanFlowColors.textSecondary,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            monitorText,
            style: theme.textTheme.bodySmall?.copyWith(
              color: PlanFlowColors.textSecondary,
            ),
          ),
        ],
      ),
    );
  }

  String _scheduleSummary(DepartureAlarmRuntimeStatus current) {
    final status = current.lastStatus == 'scheduled' ? '예약됨' : '건너뜀';
    final checkedAt = current.lastCheckedAt == null
        ? null
        : formatDateTime(current.lastCheckedAt!);
    final notifyAt = current.lastNotifyAt == null
        ? null
        : formatDateTime(current.lastNotifyAt!);
    final travel = current.lastTravelMinutes == null
        ? null
        : '이동 ${current.lastTravelMinutes}분';
    final reason = current.lastSkippedReason == null
        ? null
        : _skipReasonLabel(current.lastSkippedReason!);
    return [
      status,
      if (checkedAt != null) '확인 $checkedAt',
      if (notifyAt != null) '알림 $notifyAt',
      if (travel != null) travel,
      if (reason != null) reason,
    ].join(' · ');
  }

  String _monitorSummary(DepartureAlarmRuntimeStatus? current) {
    if (current == null || current.lastMonitorAt == null) {
      return '모니터링 실행 기록이 아직 없습니다.';
    }
    final last = formatDateTime(current.lastMonitorAt!);
    final next = current.nextMonitorAt == null
        ? null
        : formatDateTime(current.nextMonitorAt!);
    final monitorState = switch (current.monitorScheduled) {
      true => '다음 모니터 예약됨',
      false => '다음 모니터 예약 실패',
      null => '다음 모니터 기록 없음',
    };
    final skippedReason = current.lastMonitorSkippedReason == null
        ? null
        : _skipReasonLabel(current.lastMonitorSkippedReason!);
    return [
      '최근 모니터 $last',
      '예약 ${current.lastMonitorScheduled ?? 0}개',
      '건너뜀 ${current.lastMonitorSkipped ?? 0}개',
      monitorState,
      if (next != null) next,
      if (skippedReason != null) skippedReason,
    ].join(' · ');
  }

  String _skipReasonLabel(String reason) {
    return switch (reason) {
      'past_or_no_time' => '시간 없음/지난 일정',
      'missing_destination' => '장소 좌표 없음',
      'missing_origin' => '현재 위치 확인 필요',
      'departure_time_passed' => '출발 기준 시간이 이미 지남',
      'signed_out' => '로그인 필요',
      'supabase' => '서버 설정 필요',
      _ => reason,
    };
  }
}

class _RuntimeStatusContainer extends StatelessWidget {
  const _RuntimeStatusContainer({
    super.key,
    required this.title,
    required this.icon,
    required this.isLoading,
    required this.onRefresh,
    required this.child,
  });

  final String title;
  final IconData icon;
  final bool isLoading;
  final Future<void> Function() onRefresh;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: PlanFlowColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: PlanFlowColors.primaryFaint),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(icon, size: 18, color: PlanFlowColors.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: PlanFlowColors.primary,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              IconButton(
                tooltip: '상태 새로고침',
                onPressed: isLoading ? null : onRefresh,
                icon: isLoading
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.refresh),
              ),
            ],
          ),
          child,
        ],
      ),
    );
  }
}

class _RuntimeStatusLine extends StatelessWidget {
  const _RuntimeStatusLine({
    required this.label,
    required this.value,
  });

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 48,
          child: Text(
            label,
            style: theme.textTheme.bodySmall?.copyWith(
              color: PlanFlowColors.textPrimary,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: theme.textTheme.bodySmall?.copyWith(
              color: PlanFlowColors.textSecondary,
            ),
          ),
        ),
      ],
    );
  }
}

class _StatusRow extends StatelessWidget {
  const _StatusRow({
    required this.label,
    required this.value,
    required this.icon,
    required this.isConfigured,
  });

  final String label;
  final String value;
  final IconData icon;
  final bool isConfigured;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color =
        isConfigured ? const Color(0xFF1F8A4C) : PlanFlowColors.textSecondary;
    return Row(
      children: [
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(icon, color: color, size: 20),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: theme.textTheme.titleSmall?.copyWith(
                  color: PlanFlowColors.primary,
                ),
              ),
              const SizedBox(height: 2),
              Text(value, style: theme.textTheme.bodySmall),
            ],
          ),
        ),
        const SizedBox(width: 8),
        Icon(
          isConfigured
              ? Icons.check_circle_outline
              : Icons.remove_circle_outline,
          color: color,
        ),
      ],
    );
  }
}

class _InlineNotice extends StatelessWidget {
  const _InlineNotice({
    required this.icon,
    required this.text,
  });

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFEAF4FF),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFBFDDF7)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: PlanFlowColors.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.bodySmall?.copyWith(
                color: PlanFlowColors.textSecondary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _AccountDetailText extends StatelessWidget {
  const _AccountDetailText(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Align(
      alignment: Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsets.only(left: 52),
        child: Text(
          text,
          style: theme.textTheme.bodySmall?.copyWith(
            color: PlanFlowColors.textSecondary,
          ),
        ),
      ),
    );
  }
}
