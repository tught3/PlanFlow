import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/constants.dart';
import '../../core/env.dart';
import '../../core/log_text.dart';
import '../../core/region_settings.dart';
import '../../core/time_format_controller.dart';
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
import '../../services/notification_service.dart';
import '../../core/diag_logger.dart';
import '../../widgets/planflow_logo.dart';
import '../../widgets/planflow_voice_fab.dart';
import '../../l10n/app_l10n.dart';
import 'beta_survey_sheet.dart';
import 'feedback_report_sheet.dart';
part 'settings_widgets.dart';

enum SettingsInitialAction { calendarSync, naverCalDav, openBetaSurvey }

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
  final DeviceCalendarService? _deviceCalendarService;
  final NaverCalDavService? _naverCalDavService;
  final String? _userId;
  final SettingsInitialAction? _initialAction;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen>
    with WidgetsBindingObserver {
  static const String _deviceCalendarSyncedPrefsKey =
      'settings:device_calendar_synced';

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

  UserSettingsModel? _savedSettings;
  TimeOfDay _morningBriefingAt = const TimeOfDay(hour: 7, minute: 30);
  TimeOfDay _eveningBriefingAt = const TimeOfDay(hour: 21, minute: 0);
  int _defaultReminderMinutes = 60;
  int _prepTimeMin = 30;
  int _prepPreAlarmOffset = 30;
  int _departPreAlarmOffset = 30;
  int _departureSafetyMarginMin = 20;
  int _departureRepeatIntervalMin =
      DepartureAlarmService.defaultRepeatIntervalMin;
  String _travelMode = 'car';
  bool _briefingEnabled = true;
  bool _use24HourFormat = false;
  bool _voiceAutoStart = false;
  bool _voiceCorrectionLearningEnabled = true;
  bool _voiceCommonLearningOptIn = false;
  bool _hideWidgetWeekends = false;
  String _preferredMapProvider = 'naver';
  String _countryCode = PlanFlowRegions.korea.countryCode;
  String _localeCode = PlanFlowRegions.korea.localeCode;
  String _timeZoneId = PlanFlowRegions.korea.timeZoneId;
  String _appVersionLabel = '버전 확인 중...';

  CalendarSyncSummary? _calendarSyncSummary;
  CalendarAutoSyncSnapshot? _calendarAutoSyncSnapshot;
  List<BackupSnapshot> _backups = const <BackupSnapshot>[];

  bool _isLoadingCalendarStatus = true;
  bool _isSyncingGoogleCalendar = false;
  bool _isDisconnectingGoogleCalendar = false;
  bool _isDisconnectingNaverCalendar = false;
  bool _isImportingDeviceNaverCalendar = false;
  bool _deviceCalendarImportLongRunning = false;
  bool _isDeviceCalendarImportProgressDialogOpen = false;
  bool _isDisconnectingDeviceCalendar = false;
  bool _hasDeviceCalendarSynced = false;
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
  Timer? _deviceCalendarImportTimer;
  Timer? _autoSyncReloadDebounce;
  bool _isRetryingCalendarAutoSync = false;
  int? _lastHandledCalendarRefreshSequence;
  bool _isNaverCalDavProgressDialogOpen = false;
  late final ScrollController _settingsScrollController;
  bool _calendarDeferredLoadsStarted = false;
  bool _backupDeferredLoadsStarted = false;
  int? _newFeedbackReportCount;
  bool _isLoadingNewFeedbackReportCount = false;
  String? _lastFeedbackAdminEmail;
  final GlobalKey _calendarSyncSectionKey = GlobalKey();
  NotificationPermissionStatus? _notificationPermissionStatus;

  String? get _userId => widget._userId ?? authProvider.userId;
  bool get _isFeedbackAdmin {
    if (!AppEnv.isSupabaseReady) {
      return false;
    }
    final email = authProvider.email?.trim().toLowerCase();
    return email != null && feedbackAdminEmails.contains(email);
  }

  void _logSettingsGoogleCalendar(String message) {
    debugPrint('[PlanFlowGoogleAuth] settings ${logSafeText(message)}');
  }

  void _logSettingsNaverCalendar(String message) {
    debugPrint('[PlanFlowNaverCalendar] settings ${logSafeText(message)}');
  }

  @override
  void initState() {
    super.initState();
    _settingsScrollController = ScrollController();
    _settingsScrollController.addListener(_handleSettingsScroll);
    WidgetsBinding.instance.addObserver(this);
    EventRefreshBus.instance.latest.addListener(_handleCalendarRefreshSignal);
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

    unawaited(_loadSettings());
    unawaited(_loadAppVersionInfo());
    unawaited(_loadWidgetDisplaySettings());
    final naverCalDavStateLoaded = _loadNaverCalDavState();
    unawaited(naverCalDavStateLoaded);
    if (widget._initialAction != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        unawaited(_runInitialAction(naverCalDavStateLoaded));
      });
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      _handleSettingsScroll();
    });
    if (AppEnv.isSupabaseReady) {
      authProvider.addListener(_handleFeedbackAdminAuthChanged);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _handleFeedbackAdminAuthChanged();
      });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    EventRefreshBus.instance.latest.removeListener(
      _handleCalendarRefreshSignal,
    );
    if (AppEnv.isSupabaseReady) {
      authProvider.removeListener(_handleFeedbackAdminAuthChanged);
    }
    _settingsProvider.dispose();
    if (_ownsNaverCalDavService) {
      unawaited(_naverCalDavService.dispose());
    }
    _deviceCalendarImportTimer?.cancel();
    _autoSyncReloadDebounce?.cancel();
    _settingsScrollController.removeListener(_handleSettingsScroll);
    _settingsScrollController.dispose();
    _naverCalDavProgress.dispose();
    super.dispose();
  }

  void _handleSettingsScroll() {
    if (!_settingsScrollController.hasClients) {
      return;
    }
    final position = _settingsScrollController.position;
    final maxExtent = position.maxScrollExtent;
    if (maxExtent <= 0) {
      _startCalendarDeferredLoads();
      _startBackupDeferredLoads();
      return;
    }

    if (position.pixels >= maxExtent * 0.25) {
      _startCalendarDeferredLoads();
    }
    if (position.pixels >= maxExtent * 0.65) {
      _startBackupDeferredLoads();
    }
  }

  void _startCalendarDeferredLoads() {
    if (_calendarDeferredLoadsStarted) {
      return;
    }
    _calendarDeferredLoadsStarted = true;
    unawaited(_loadCalendarStatus());
    unawaited(_loadAutoSyncSnapshot());
    unawaited(_loadDeviceCalendarSyncedState());
  }

  void _startBackupDeferredLoads() {
    if (_backupDeferredLoadsStarted) {
      return;
    }
    _backupDeferredLoadsStarted = true;
    unawaited(_ensureAutomaticBackup());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_refreshCalendarConnectionState(runAutoRetry: true));
    }
  }

  void _handleCalendarRefreshSignal() {
    final signal = EventRefreshBus.instance.latest.value;
    if (signal == null ||
        signal.sequence == _lastHandledCalendarRefreshSequence) {
      return;
    }
    _lastHandledCalendarRefreshSequence = signal.sequence;
    if (!_isCalendarAutoSyncRefreshReason(signal.reason)) {
      return;
    }
    _autoSyncReloadDebounce?.cancel();
    _autoSyncReloadDebounce = Timer(
      const Duration(milliseconds: 600),
      () {
        if (mounted) {
          unawaited(_refreshCalendarConnectionState());
        }
      },
    );
  }

  bool _isCalendarAutoSyncRefreshReason(String reason) {
    return reason == 'google_auto_sync' ||
        reason == 'naver_caldav_auto_import' ||
        reason == 'device_naver_import' ||
        reason.startsWith('calendar_auto_sync:') ||
        reason.startsWith('google_calendar_auto_sync:') ||
        reason == 'naver_caldav_import';
  }

  Future<void> _refreshCalendarConnectionState({
    bool runAutoRetry = false,
  }) async {
    _logSettingsGoogleCalendar('refreshConnectionState start');
    _logSettingsNaverCalendar(
      'refreshConnectionState start testing=$_isTestingNaverCalDav '
      'importing=$_isImportingNaverCalDav',
    );
    await Future.wait<void>([
      _loadCalendarStatus().catchError((error, stackTrace) {
        debugPrint('Calendar status refresh skipped: ${logSafeText(error)}');
        debugPrintStack(stackTrace: stackTrace);
      }),
      _loadAutoSyncSnapshot().catchError((error, stackTrace) {
        debugPrint(
          'Calendar auto-sync snapshot refresh skipped: ${logSafeText(error)}',
        );
        debugPrintStack(stackTrace: stackTrace);
      }),
      _loadNaverCalDavState().catchError((error, stackTrace) {
        debugPrint('Naver CalDAV state refresh skipped: ${logSafeText(error)}');
        debugPrintStack(stackTrace: stackTrace);
      }),
    ]);
    _logSettingsGoogleCalendar(
      'refreshConnectionState status loaders completed',
    );
    _logSettingsNaverCalendar(
      'refreshConnectionState status loaders completed',
    );
    if (runAutoRetry) {
      await _maybeRetryFailedCalendarAutoSync();
    }
  }

  Future<void> _maybeRetryFailedCalendarAutoSync() async {
    if (!mounted ||
        _isRetryingCalendarAutoSync ||
        _isSyncingGoogleCalendar ||
        _isTestingNaverCalDav ||
        _isImportingNaverCalDav ||
        _isImportingDeviceNaverCalendar) {
      return;
    }
    final snapshot = _calendarAutoSyncSnapshot;
    if (snapshot == null || !_hasFailedCalendarAutoSyncSnapshot(snapshot)) {
      return;
    }
    _isRetryingCalendarAutoSync = true;
    try {
      final result = await _calendarAutoSyncService.syncConnectedCalendars(
        reason: 'settings_auto_retry',
        force: true,
      );
      _logSettingsGoogleCalendar(
        'autoRetry result didRun=${result.didRun} failed=${result.failed.join(',')}',
      );
      _logSettingsNaverCalendar(
        'autoRetry result didRun=${result.didRun} failed=${result.failed.join(',')}',
      );
      if (!mounted) {
        return;
      }
      await Future.wait<void>([
        _loadCalendarStatus().catchError((error, stackTrace) {
          debugPrint(
            'Calendar status refresh after retry skipped: ${logSafeText(error)}',
          );
          debugPrintStack(stackTrace: stackTrace);
        }),
        _loadAutoSyncSnapshot().catchError((error, stackTrace) {
          debugPrint(
            'Calendar snapshot refresh after retry skipped: ${logSafeText(error)}',
          );
          debugPrintStack(stackTrace: stackTrace);
        }),
        _loadNaverCalDavState().catchError((error, stackTrace) {
          debugPrint(
            'Naver CalDAV state refresh after retry skipped: ${logSafeText(error)}',
          );
          debugPrintStack(stackTrace: stackTrace);
        }),
      ]);
    } catch (error, stackTrace) {
      debugPrint('Calendar auto retry failed: ${logSafeText(error)}');
      debugPrintStack(stackTrace: stackTrace);
    } finally {
      _isRetryingCalendarAutoSync = false;
    }
  }

  bool _hasFailedCalendarAutoSyncSnapshot(CalendarAutoSyncSnapshot snapshot) {
    return snapshot.failed.isNotEmpty ||
        snapshot.providers.any((provider) {
          return provider.status == 'attention' || provider.status == 'failed';
        });
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
      debugPrint(
        'Feedback admin badge unavailable: ${logSafeText(error.message)}',
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _newFeedbackReportCount = null;
        _isLoadingNewFeedbackReportCount = false;
      });
    } catch (error) {
      debugPrint('Feedback admin badge unavailable: ${logSafeText(error)}');
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
    unawaited(
      _scheduleBriefingsFromSettings(effective, reason: 'settings_loaded'),
    );
  }

  Future<void> _loadWidgetDisplaySettings() async {
    final hideWeekends = await _homeWidgetService.areWeekendsHidden();
    final departureRepeatInterval =
        await DepartureAlarmService.loadRepeatIntervalMinutes();
    if (!mounted) {
      return;
    }
    setState(() {
      _hideWidgetWeekends = hideWeekends;
      _departureRepeatIntervalMin = departureRepeatInterval;
    });
  }

  Future<void> _loadAppVersionInfo() async {
    try {
      final packageInfo = await PackageInfo.fromPlatform();
      final version = packageInfo.version.trim();
      final buildNumber = packageInfo.buildNumber.trim();
      final label = version.isEmpty
          ? '버전 정보를 불러오지 못했습니다.'
          : buildNumber.isEmpty
              ? '버전 $version'
              : '버전 $version (빌드 $buildNumber)';
      if (!mounted) {
        return;
      }
      setState(() {
        _appVersionLabel = label;
      });
    } catch (error) {
      debugPrint('Settings app version load failed: ${logSafeText(error)}');
      if (!mounted) {
        return;
      }
      setState(() {
        _appVersionLabel = '버전 정보를 불러오지 못했습니다.';
      });
    }
  }

  Future<void> _loadCalendarStatus() async {
    _logSettingsGoogleCalendar('loadCalendarStatus start');
    _logSettingsNaverCalendar('loadCalendarStatus start');
    setState(() {
      _isLoadingCalendarStatus = true;
    });
    // prefs와 summary를 병렬 조회: summary만으로 덮어쓰면 레이스 조건에서
    // _loadDeviceCalendarSyncedState가 세운 true를 false로 되돌린다.
    final results = await Future.wait<Object?>([
      _calendarSyncService.fetchStatus(),
      SharedPreferences.getInstance().then(
        (prefs) => prefs.getBool(_deviceCalendarSyncedPrefsKey) ?? false,
      ),
    ]);
    final summary = results[0]! as CalendarSyncSummary;
    final storedDeviceSynced = results[1]! as bool;
    _logSettingsGoogleCalendar(
      'loadCalendarStatus google status=${summary.google.status.name} '
      'success=${summary.google.isSuccess} '
      'syncedItems=${summary.google.syncedItems} '
      'errorType=${summary.google.error?.runtimeType}',
    );
    _logSettingsNaverCalendar(
      'loadCalendarStatus naver status=${summary.naver.status.name} '
      'success=${summary.naver.isSuccess} '
      'syncedItems=${summary.naver.syncedItems} '
      'errorType=${summary.naver.error?.runtimeType}',
    );
    if (!mounted) {
      return;
    }
    setState(() {
      _calendarSyncSummary = summary;
      _isLoadingCalendarStatus = false;
      // storedDeviceSynced(prefs) OR snapshot OR summary 중 하나라도 true면 true 유지.
      // 단순 대입 대신 OR로 기존 true를 보존한다.
      _hasDeviceCalendarSynced = _hasDeviceCalendarSynced ||
          storedDeviceSynced ||
          _hasSyncedDeviceCalendar(summary);
    });
  }

  Future<void> _loadAutoSyncSnapshot() async {
    final snapshot = await _calendarAutoSyncService.loadSnapshot();
    if (!mounted) {
      return;
    }
    setState(() {
      _calendarAutoSyncSnapshot = snapshot;
      _hasDeviceCalendarSynced = _hasDeviceCalendarSynced ||
          _deviceCalendarAutoSyncSnapshot?.lastSuccessAt != null;
    });
  }

  Future<void> _loadDeviceCalendarSyncedState() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getBool(_deviceCalendarSyncedPrefsKey) ?? false;
    if (!mounted) {
      return;
    }
    setState(() {
      _hasDeviceCalendarSynced = _hasDeviceCalendarSynced || stored;
    });
  }

  Future<void> _loadNotificationPermissionStatus() async {
    final status = await _notificationService.checkPermissionStatus();
    if (!mounted) return;
    setState(() {
      _notificationPermissionStatus = status;
    });
  }

  Future<void> _openCriticalAlarmSoundSettings() async {
    final opened =
        await _notificationService.openCriticalAlarmChannelSettings();
    if (!mounted) {
      return;
    }
    if (!opened) {
      _showSnack('휴대폰 설정에서 PlanFlow의 중요 일정 알람 소리를 확인해 주세요.');
    }
  }

  Future<void> _loadNaverCalDavState() async {
    _logSettingsNaverCalendar('loadNaverCalDavState start');
    bool hasCalDavCredentials = false;
    try {
      hasCalDavCredentials = await _naverCalDavService.hasCredentials();
    } catch (error, stackTrace) {
      _logSettingsNaverCalendar(
        'CalDAV credential check skipped error=${logSafeText(error)}',
      );
      debugPrintStack(stackTrace: stackTrace);
    }
    _logSettingsNaverCalendar(
      'loadNaverCalDavState result hasCalDavCredentials=$hasCalDavCredentials',
    );
    if (!mounted) {
      return;
    }
    setState(() {
      _hasNaverCalDavCredentials = hasCalDavCredentials;
      if (!hasCalDavCredentials) {
        _lastNaverCalDavResult = null;
      }
    });

    // 자격증명이 있으면 백그라운드에서 캘린더 목록을 미리 불러 캐시를 데운다.
    // 실패해도 사용자에게 노출하지 않는다. 정식 동기화 때 다시 정상 호출된다.
    if (hasCalDavCredentials) {
      unawaited(
        _naverCalDavService.getCalendars().catchError((_) => <NaverCalDavCalendar>[]),
      );
    }
  }

  Future<void> _syncGoogleCalendar() async {
    if (_isSyncingGoogleCalendar) {
      _logSettingsGoogleCalendar('syncGoogleCalendar ignored: already syncing');
      return;
    }
    _logSettingsGoogleCalendar('syncGoogleCalendar start interactive=true');
    setState(() {
      _isSyncingGoogleCalendar = true;
    });
    final result = await _calendarSyncService.syncGoogleCalendar(
      interactive: true,
    );
    _logSettingsGoogleCalendar(
      'syncGoogleCalendar result status=${result.status.name} '
      'success=${result.isSuccess} syncedItems=${result.syncedItems} '
      'errorType=${result.error?.runtimeType}',
    );
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
      if (!mounted) {
        return;
      }
      await _loadAutoSyncSnapshot();
      _showSnack('Google Calendar 연동을 해제했습니다.');
    } catch (error, stackTrace) {
      debugPrint('Google calendar disconnect failed: ${logSafeText(error)}');
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
          titlePadding: const EdgeInsets.fromLTRB(24, 20, 24, 12),
          contentPadding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
          actionsPadding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
          title: Row(
            children: [
              Expanded(child: Text('$providerName 연동 해제')),
              IconButton(
                tooltip: '닫기',
                onPressed: () => Navigator.of(context).pop(null),
                icon: const Icon(Icons.close),
              ),
            ],
          ),
          content: const Text(
            '연동만 해제하고 가져온 일정은 유지할지, 공급자에서 가져온 일정도 함께 삭제할지 선택해 주세요.',
          ),
          actions: [
            SizedBox(
              width: double.infinity,
              child: Row(
                children: [
                  Expanded(
                    child: SizedBox(
                      height: 44,
                      child: OutlinedButton(
                        onPressed: () => Navigator.of(context).pop(false),
                        style: OutlinedButton.styleFrom(
                          side: const BorderSide(color: Color(0xFF3B82F6)),
                          foregroundColor: const Color(0xFF2563EB),
                        ),
                        child: const Text('일정 유지'),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: SizedBox(
                      height: 44,
                      child: FilledButton(
                        onPressed: () => Navigator.of(context).pop(true),
                        style: FilledButton.styleFrom(
                          backgroundColor: const Color(0xFFB91C1C),
                          foregroundColor: Colors.white,
                        ),
                        child: const FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text('일정 삭제'),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
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
      _deviceCalendarImportLongRunning = false;
    });
    DeviceCalendarImportResult result;
    try {
      _deviceCalendarImportTimer?.cancel();
      final importFuture = _deviceCalendarService.importNaverEvents(
        userId: userId,
      );
      _deviceCalendarImportTimer = Timer(const Duration(seconds: 3), () {
        if (!mounted || !_isImportingDeviceNaverCalendar) {
          return;
        }
        setState(() {
          _deviceCalendarImportLongRunning = true;
        });
        unawaited(_showDeviceCalendarImportProgressDialog());
      });
      result = await importFuture;
    } catch (error, stackTrace) {
      debugPrint('Device calendar import UI failed: $error');
      debugPrintStack(stackTrace: stackTrace);
      result = DeviceCalendarImportResult(
        status: DeviceCalendarImportStatus.failed,
        message: '휴대폰 내부 캘린더 일정 가져오기에 실패했습니다. 권한과 캘린더 동기화 상태를 확인해 주세요.',
        error: error,
      );
    } finally {
      _deviceCalendarImportTimer?.cancel();
      _deviceCalendarImportTimer = null;
      if (mounted) {
        if (_isDeviceCalendarImportProgressDialogOpen &&
            Navigator.of(context, rootNavigator: true).canPop()) {
          Navigator.of(context, rootNavigator: true).pop();
        }
        setState(() {
          _isImportingDeviceNaverCalendar = false;
          _deviceCalendarImportLongRunning = false;
        });
      }
    }
    if (!mounted) {
      return;
    }
    if (result.status == DeviceCalendarImportStatus.imported) {
      setState(() {
        _hasDeviceCalendarSynced = true;
      });
    }
    if (result.status == DeviceCalendarImportStatus.imported) {
      await _saveDeviceCalendarSyncedState(true);
    }
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
      _showSnack('휴대폰 내부 캘린더 연동 정보를 초기화했습니다. 다음 가져오기 때 다시 권한과 저장소를 확인합니다.');
    } catch (error, stackTrace) {
      debugPrint('Device calendar disconnect failed: ${logSafeText(error)}');
      debugPrintStack(stackTrace: stackTrace);
      _showSnack('휴대폰 내부 캘린더 연동 해제에 실패했습니다. 다시 시도해 주세요.');
    } finally {
      if (mounted) {
        setState(() {
          _isDisconnectingDeviceCalendar = false;
          _hasDeviceCalendarSynced = false;
        });
      }
      await _saveDeviceCalendarSyncedState(false);
    }
  }

  Future<void> _saveDeviceCalendarSyncedState(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_deviceCalendarSyncedPrefsKey, value);
  }

  Future<bool> _connectNaverCalDavAndImport() async {
    if (_isTestingNaverCalDav || _isImportingNaverCalDav) {
      _logSettingsNaverCalendar(
        'connectAndImport ignored testing=$_isTestingNaverCalDav '
        'importing=$_isImportingNaverCalDav',
      );
      return false;
    }

    _logSettingsNaverCalendar('connectAndImport start -> CalDAV direct');
    // CalDAV 자격증명이 있으면 바로 동기화
    final hasCalDavCredentials = await _naverCalDavService.hasCredentials();
    _logSettingsNaverCalendar(
      'connectAndImport hasCalDavCredentials=$hasCalDavCredentials',
    );
    if (hasCalDavCredentials) {
      if (!mounted) return false;
      _showSnack('네이버 캘린더 동기화를 시작합니다.');
      if (!mounted) return false;
      final imported = await _importNaverCalDavEvents(skipIntro: true);
      return imported?.success ?? false;
    }

    // 자격증명 없으면 CalDAV 앱 비밀번호 다이얼로그로 직접 연결
    return _connectNaverCalDavFallbackAndImport();
  }

  Future<bool> _connectNaverCalDavFallbackAndImport() async {
    if (!mounted) {
      return false;
    }

    // Naver OAuth identity에서 ID 추출해 다이얼로그에 pre-fill
    String? naverIdentityId;
    final currentUser = Supabase.instance.client.auth.currentUser;
    for (final identity in currentUser?.identities ?? const <UserIdentity>[]) {
      if (identity.provider.toLowerCase().contains('naver')) {
        final data = identity.identityData ?? const <String, dynamic>{};
        final dataId = (data['id'] as String?)?.trim();
        naverIdentityId = (dataId?.isNotEmpty == true)
            ? dataId
            : identity.identityId.trim().isNotEmpty
                ? identity.identityId.trim()
                : null;
        break;
      }
    }
    DiagLogger.log(
      'DIAG',
      'caldavFallback naverIdFound=${naverIdentityId != null}',
    );

    final credentials = await _showNaverCalDavDialog(
      initialNaverId: naverIdentityId,
    );
    if (credentials == null) {
      return false;
    }
    if (!mounted) {
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
      DiagLogger.log(
        'DIAG',
        'caldav testConnection status=${result.status.name} '
            'isSuccess=${result.isSuccess} statusCode=${result.statusCode}',
      );
    } catch (error, stackTrace) {
      DiagLogger.log(
        'DIAG',
        'caldav testConnection exception ${logSafeText(error.runtimeType)}',
      );
      debugPrint('Naver CalDAV connect failed: ${logSafeText(error)}');
      debugPrintStack(stackTrace: stackTrace);
      if (mounted) {
        setState(() {
          _isTestingNaverCalDav = false;
          _hasNaverCalDavCredentials = false;
        });
        _showSnack('네이버 CalDAV 연결 테스트에 실패했습니다. ID와 앱 비밀번호를 확인해 주세요.');
      }
      return false;
    }

    if (!mounted) {
      return false;
    }
    setState(() {
      _isTestingNaverCalDav = false;
      _hasNaverCalDavCredentials = result.isSuccess;
      _lastNaverCalDavResult = result;
    });
    _showSnack(result.message);
    if (!result.isSuccess) {
      return false;
    }

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
    _logSettingsNaverCalendar(
      'runImport start userPresent=${userId.isNotEmpty} mode=$mode '
      'diagnosticImport=$diagnosticImport '
      'from=${from?.toIso8601String() ?? "(null)"} '
      'to=${to?.toIso8601String() ?? "(null)"}',
    );
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
    _logSettingsNaverCalendar(
      'runImport result success=${result.success} events=${result.events} '
      'createdOrUpdated=${result.createdOrUpdated} skipped=${result.skipped} '
      'failed=${result.failed} errorType=${result.error?.runtimeType}',
    );
    if (!mounted) {
      return result;
    }
    // 진행바가 100%까지 차오르는 모습을 잠깐 보여준 뒤 다이얼로그를 닫는다.
    await Future.delayed(const Duration(milliseconds: 650));
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
      _logSettingsNaverCalendar('runImport success -> mark connected');
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
      _logSettingsNaverCalendar('runImport failed -> mark failed');
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

  Future<void> _showNaverCalDavDiagnosticResult(NaverCalDavSyncResult result) {
    final diagnostics = result.diagnostics;
    final reasonText = _naverCalDavDiagnosticReasonText(diagnostics);
    return showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Row(
          children: [
            const Expanded(child: Text('네이버 동기화 진단 결과')),
            IconButton(
              tooltip: '상세 진단',
              onPressed: () => _showNaverCalDavDiagnosticDetails(diagnostics),
              icon: const Icon(Icons.info_outline),
            ),
          ],
        ),
        content: Text(
          reasonText,
          style: Theme.of(context).textTheme.bodyMedium,
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

  Future<void> _showNaverCalDavDiagnosticDetails(
    NaverCalDavSyncDiagnostics diagnostics,
  ) {
    final samples = diagnostics.samples;
    final invalidSamples = diagnostics.invalidSamples;
    var query = '';
    return showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('상세 진단'),
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
                  TextField(
                    decoration: const InputDecoration(
                      labelText: '찾는 일정 제목 검색',
                      hintText: '예: 태블릿계, 공임나라',
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
                    Text(
                      '저장 범위 안 샘플 일정',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
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
                    Text(
                      '파싱 실패 샘플',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
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
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('닫기'),
          ),
        ],
      ),
    );
  }

  Future<void> _showDeviceCalendarImportProgressDialog() {
    _isDeviceCalendarImportProgressDialogOpen = true;
    return showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (context) => const AlertDialog(
        title: Text('휴대폰 내부 캘린더 가져오기'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('일정이 많아 조금 걸리고 있습니다. 앱을 전환해도 가져오기는 계속됩니다.'),
          ],
        ),
      ),
    ).whenComplete(() {
      _isDeviceCalendarImportProgressDialogOpen = false;
    });
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
      debugPrint(
        'Naver CalDAV connection state save skipped: ${logSafeText(error)}',
      );
      debugPrintStack(stackTrace: stackTrace);
    }
  }

  Future<bool?> _showNaverCalDavImportIntroDialog() {
    return showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('네이버 캘린더 동기화'),
        content: const Text(
          '가져오는 데 시간이 걸릴 수 있습니다. 앱을 백그라운드로 보내도 계속 진행됩니다. 먼저 최근 3개월과 앞으로 6개월을 빠르게 가져옵니다.',
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

  Future<void> _showNaverCalDavProgressDialog({bool dismissible = true}) {
    _isNaverCalDavProgressDialogOpen = true;
    return showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (context) => PopScope(
        canPop: true,
        child: AlertDialog(
          title: const Text('네이버 일정 가져오기'),
          content: _NaverCalDavProgressView(
            progressListenable: _naverCalDavProgress,
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
                child: Text(confirmLabel, maxLines: 1),
              ),
            ),
          ),
        ],
      ),
    );
  }

  ButtonStyle _settingsSkyButtonStyle() {
    return FilledButton.styleFrom(
      backgroundColor: PlanFlowColors.primaryMid,
      foregroundColor: Colors.white,
    );
  }

  ButtonStyle _settingsBriefingButtonStyle() {
    return FilledButton.styleFrom(
      backgroundColor: PlanFlowColors.fab,
      foregroundColor: Colors.white,
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
            child: Text(label, maxLines: 1, textAlign: TextAlign.center),
          ),
        ),
      );
    }

    return showDialog<_NaverCalDavImportRange>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('추가 기록 가져오기'),
        content: const Text('최근 3개월과 앞으로 6개월 일정을 저장했습니다. 더 과거 기록을 얼마나 불러올까요?'),
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
                        onPressed: () => Navigator.of(
                          context,
                        ).pop(_NaverCalDavImportRange.months(6)),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: buildRangeButton(
                        label: '1년',
                        onPressed: () => Navigator.of(
                          context,
                        ).pop(_NaverCalDavImportRange.years(1)),
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
                        onPressed: () => Navigator.of(
                          context,
                        ).pop(_NaverCalDavImportRange.years(2)),
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
                            Navigator.of(
                              context,
                            ).pop(_NaverCalDavImportRange.all());
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
        content: const Text('전체 기록은 일정 수에 따라 오래 걸릴 수 있습니다. 그래도 진행할까요?'),
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

  // Legacy CalDAV 앱 비밀번호 다이얼로그 — Open API 전환 후 미사용.
  // OAuth 연결이 열리지 않거나 권한 확인이 끝나지 않을 때 CalDAV 직접 연결로 전환한다.
  Future<_NaverCalDavCredentials?> _showNaverCalDavDialog({
    String? initialNaverId,
  }) {
    final idController = TextEditingController(text: initialNaverId ?? '');
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
          insetPadding: const EdgeInsets.symmetric(
            horizontal: 20,
            vertical: 24,
          ),
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
                    style: theme.textTheme.bodyMedium?.copyWith(height: 1.45),
                  ),
                  const SizedBox(height: 12),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: PlanFlowColors.primaryFaint.withValues(
                        alpha: 0.38,
                      ),
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
                          const Text('ID는 로그인 전용 ID가 아니라 원본 네이버 ID를 입력해 주세요.'),
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

    if (widget._initialAction == SettingsInitialAction.openBetaSurvey) {
      await _openBetaSurveySheet();
      return;
    }

    _startCalendarDeferredLoads();
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
      case SettingsInitialAction.openBetaSurvey:
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

  Future<void> _disconnectNaverCalendar() async {
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
      await _calendarSyncService.disconnectProvider(
        CalendarProvider.naver,
        deleteProviderEvents: deleteProviderEvents,
      );
      await _naverCalDavService.clearCredentials();
      if (!mounted) {
        return;
      }
      await _loadCalendarStatus();
      if (!mounted) {
        return;
      }
      await _loadAutoSyncSnapshot();
      if (!mounted) {
        return;
      }
      setState(() {
        _hasNaverCalDavCredentials = false;
        _lastNaverCalDavResult = null;
      });
      _showSnack(
        deleteProviderEvents
            ? '네이버 CalDAV 연동과 가져온 일정을 정리했습니다.'
            : '네이버 CalDAV 연동을 해제했습니다. 기존 일정은 유지됩니다.',
      );
    } catch (error, stackTrace) {
      debugPrint('Naver calendar disconnect failed: ${logSafeText(error)}');
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
          data: MediaQuery.of(context)
              .copyWith(alwaysUse24HourFormat: _use24HourFormat),
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
        briefingEnabled: _briefingEnabled,
        use24HourFormat: _use24HourFormat,
        morningBriefingAt: _formatTimeValue(_morningBriefingAt),
        eveningBriefingAt: _formatTimeValue(_eveningBriefingAt),
        defaultReminderMin: _defaultReminderMinutes,
        prepTimeMin: _prepTimeMin,
        prepPreAlarmOffset: _prepPreAlarmOffset,
        departPreAlarmOffset: _departPreAlarmOffset,
        departureSafetyMarginMin: _departureSafetyMarginMin,
        travelMode: _travelMode,
        voiceAutoStart: _voiceAutoStart,
        voiceCorrectionLearningEnabled: _voiceCorrectionLearningEnabled,
        voiceCommonLearningOptIn: _voiceCommonLearningOptIn,
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
        briefingEnabled: draft.briefingEnabled,
        morningBriefingAt: draft.morningBriefingAt,
        eveningBriefingAt: draft.eveningBriefingAt,
        defaultReminderMin: draft.defaultReminderMin,
        prepTimeMin: draft.prepTimeMin,
        prepPreAlarmOffset: draft.prepPreAlarmOffset,
        departPreAlarmOffset: draft.departPreAlarmOffset,
        departureSafetyMarginMin: draft.departureSafetyMarginMin,
        travelMode: draft.travelMode,
        voiceAutoStart: draft.voiceAutoStart,
        voiceCorrectionLearningEnabled: draft.voiceCorrectionLearningEnabled,
        voiceCommonLearningOptIn: draft.voiceCommonLearningOptIn,
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
      debugPrint('Settings save failed: ${logSafeText(error)}');
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
        briefingEnabled: settings.briefingEnabled,
      );
      debugPrint(
        'Briefing schedule updated ($reason): '
        'morning=${result.morning.scheduledAt.toIso8601String()} '
        'scheduled=${result.morning.scheduled}, '
        'evening=${result.evening.scheduledAt.toIso8601String()} '
        'scheduled=${result.evening.scheduled}, userId=$userId',
      );
      return result;
    } catch (error, stackTrace) {
      debugPrint('Briefing schedule failed ($reason): ${logSafeText(error)}');
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
      unawaited(AnalyticsService.logBriefingTestPlayed(isMorning: isMorning));
      final result = await _briefingSchedulerService.executeBriefing(
        isMorning: isMorning,
        userId: userId,
      );
      _showSnack(result.message);
    } catch (error, stackTrace) {
      debugPrint('Briefing test failed: ${logSafeText(error)}');
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
      debugPrint(
        'Settings token refresh before save failed: ${logSafeText(error)}',
      );
      debugPrintStack(stackTrace: stackTrace);
    }
    return current;
  }

  String _backupAuthRequiredMessage({bool list = false, bool restore = false}) {
    if (authProvider.needsReauthentication || authProvider.hasAccountSnapshot) {
      if (list) {
        return '로그인 세션을 다시 확인해야 백업 목록을 불러올 수 있습니다. 다시 로그인해 주세요.';
      }
      if (restore) {
        return '로그인 세션을 다시 확인해야 백업을 복원할 수 있습니다. 다시 로그인해 주세요.';
      }
      return '로그인 세션을 다시 확인해야 백업할 수 있습니다. 다시 로그인해 주세요.';
    }
    if (list) {
      return '로그인 후 백업 목록을 불러올 수 있습니다.';
    }
    if (restore) {
      return '로그인 후 백업을 복원할 수 있습니다.';
    }
    return '로그인 후 백업할 수 있습니다.';
  }

  Future<bool> _loadBackups({bool showSignedOutMessage = true}) async {
    final backupService = _backupService;
    if (backupService == null || !authProvider.isSignedIn) {
      if (showSignedOutMessage && mounted) {
        _showSnack(_backupAuthRequiredMessage(list: true));
      }
      return false;
    }
    setState(() {
      _isLoadingBackups = true;
    });
    try {
      final backups = await backupService.listBackups();
      if (!mounted) {
        return false;
      }
      setState(() {
        _backups = backups;
      });
      return true;
    } on BackupAuthRequiredException {
      if (mounted) {
        _showSnack(_backupAuthRequiredMessage(list: true));
      }
      return false;
    } on BackupSchemaException catch (error) {
      if (mounted) {
        _showSnack(error.message);
      }
      return false;
    } catch (error, stackTrace) {
      debugPrint('Backup list failed: ${logSafeText(error)}');
      debugPrintStack(stackTrace: stackTrace);
      if (mounted) {
        _showSnack('백업 목록을 불러오지 못했습니다. 네트워크와 Supabase 설정을 확인해 주세요.');
      }
      return false;
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
      debugPrint('Automatic backup setup skipped: ${logSafeText(error)}');
      debugPrintStack(stackTrace: stackTrace);
    }
  }

  Future<void> _createBackup() async {
    final backupService = _backupService;
    if (backupService == null || !authProvider.isSignedIn) {
      _showSnack(_backupAuthRequiredMessage());
      return;
    }
    setState(() {
      _isBackupActionRunning = true;
    });
    try {
      final backup = await backupService.createBackup();
      await _loadBackups();
      _showSnack('백업 완료: ${backup.totalItems}개 항목을 저장했습니다.');
    } on BackupAuthRequiredException {
      _showSnack(_backupAuthRequiredMessage());
    } on BackupSchemaException catch (error) {
      _showSnack(error.message);
    } catch (error, stackTrace) {
      debugPrint('Backup create failed: ${logSafeText(error)}');
      debugPrintStack(stackTrace: stackTrace);
      _showSnack('백업 생성에 실패했습니다. 네트워크와 Supabase 설정을 확인해 주세요.');
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
    } on BackupAuthRequiredException {
      _showSnack(_backupAuthRequiredMessage(restore: true));
    } on BackupSchemaException catch (error) {
      _showSnack(error.message);
    } catch (error, stackTrace) {
      debugPrint('Backup restore failed: ${logSafeText(error)}');
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
      _showSnack(_backupAuthRequiredMessage(restore: true));
      return;
    }
    if (!_isLoadingBackups && _backups.isEmpty) {
      final loaded = await _loadBackups();
      if (!loaded) {
        return;
      }
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
      _briefingEnabled = true;
      _use24HourFormat = false;
      _morningBriefingAt = const TimeOfDay(hour: 7, minute: 30);
      _eveningBriefingAt = const TimeOfDay(hour: 21, minute: 0);
      _defaultReminderMinutes = 60;
      _prepTimeMin = 30;
      _prepPreAlarmOffset = 30;
      _departPreAlarmOffset = 30;
      _departureSafetyMarginMin = 20;
      _departureRepeatIntervalMin =
          DepartureAlarmService.defaultRepeatIntervalMin;
      _travelMode = 'car';
      _voiceAutoStart = false;
      _voiceCorrectionLearningEnabled = true;
      _voiceCommonLearningOptIn = false;
      _hideWidgetWeekends = false;
      _preferredMapProvider = 'naver';
      _countryCode = PlanFlowRegions.korea.countryCode;
      _localeCode = PlanFlowRegions.korea.localeCode;
      _timeZoneId = PlanFlowRegions.korea.timeZoneId;
      PlanFlowRegionController.instance.reset();
      TimeFormatController.instance.reset();
    });
    unawaited(_homeWidgetService.setHideWeekends(false));
    unawaited(
      DepartureAlarmService.saveRepeatIntervalMinutes(
        DepartureAlarmService.defaultRepeatIntervalMin,
      ),
    );
    unawaited(_persistSettings(successMessage: '설정을 기본값으로 되돌렸습니다.'));
  }

  void _applySettings(UserSettingsModel settings) {
    _briefingEnabled = settings.briefingEnabled;
    _use24HourFormat = settings.use24HourFormat;
    TimeFormatController.instance.setUse24HourFormat(settings.use24HourFormat);
    _morningBriefingAt = _parseTime(settings.morningBriefingAt);
    _eveningBriefingAt = _parseTime(settings.eveningBriefingAt);
    _defaultReminderMinutes = settings.defaultReminderMin;
    _prepTimeMin = settings.prepTimeMin;
    _prepPreAlarmOffset = settings.prepPreAlarmOffset;
    _departPreAlarmOffset = settings.departPreAlarmOffset;
    _departureSafetyMarginMin = settings.departureSafetyMarginMin;
    _travelMode = settings.travelMode;
    _voiceAutoStart = settings.voiceAutoStart;
    _voiceCorrectionLearningEnabled = settings.voiceCorrectionLearningEnabled;
    _voiceCommonLearningOptIn = settings.voiceCommonLearningOptIn;
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
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  void _setUse24HourFormat(bool value) {
    if (_use24HourFormat == value) {
      return;
    }
    setState(() {
      _use24HourFormat = value;
    });
    TimeFormatController.instance.setUse24HourFormat(value);
    unawaited(_persistSettings());
  }

  Future<void> _showDiagnosticLogDialog() async {
    String preflightHeader;
    try {
      final prefs = await SharedPreferences.getInstance();
      final last = prefs.getString(departurePreflightLastRunKey);
      preflightHeader = last != null
          ? '[출발 preflight 마지막 실행]\n$last\n\n'
          : '[출발 preflight 마지막 실행] 기록 없음\n\n';
    } catch (error) {
      preflightHeader = '[출발 preflight] 읽기 실패: $error\n\n';
    }
    final log = preflightHeader + DiagLogger.dump();
    if (!mounted) {
      return;
    }
    _presentDiagnosticLogDialog(log);
  }

  void _presentDiagnosticLogDialog(String log) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('진단 로그'),
        content: SingleChildScrollView(
          child: SelectableText(
            log,
            style: const TextStyle(
              fontFamily: 'monospace',
              fontSize: 11,
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('닫기'),
          ),
        ],
      ),
    );
  }

  Widget _buildRegionSettings() {
    final selectedRegion = PlanFlowRegions.byCountryCode(_countryCode);
    final l10n = appL10n(context);
    final theme = Theme.of(context);
    return _SectionCard(
      title: l10n.regionSettingsTitle,
      subtitle: l10n.regionSettingsSubtitle,
      child: Column(
        children: [
          DropdownButtonFormField<String>(
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
          const Divider(height: 24),
          Material(
            color: Colors.transparent,
            child: InkWell(
              key: const ValueKey('settings-time-format-toggle'),
              borderRadius: BorderRadius.circular(10),
              onTap: () => _setUse24HourFormat(!_use24HourFormat),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            _use24HourFormat
                                ? '24시간제(15:30)'
                                : '12시간제(오후 3:30)',
                            style: theme.textTheme.titleSmall?.copyWith(
                              color: PlanFlowColors.primary,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        Switch(
                          value: _use24HourFormat,
                          onChanged: _setUse24HourFormat,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
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

  Widget _buildNotificationPermissionBanner() {
    final status = _notificationPermissionStatus;
    if (status == null || status.notificationsEnabled != false) {
      return const SizedBox.shrink();
    }
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF3E0),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFFFB74D)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(
            Icons.notifications_off_outlined,
            color: Color(0xFFE65100),
            size: 22,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '앱 알림이 꺼져 있어요',
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: Color(0xFFE65100),
                    fontSize: 14,
                  ),
                ),
                const SizedBox(height: 4),
                const Text(
                  '일정 알람, 출발 알람, 브리핑이 울리지 않습니다.\n기기 설정에서 PlanFlow 알림을 허용해 주세요.',
                  style: TextStyle(
                    color: Color(0xFF8D4000),
                    fontSize: 13,
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    GestureDetector(
                      onTap: () async {
                        await _notificationService
                            .openAppNotificationSettings();
                        if (mounted) {
                          unawaited(_loadNotificationPermissionStatus());
                        }
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xFFE65100),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: const Text(
                          '알림 설정 열기',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
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

  Widget _buildPlanFlowNotificationNotice() {
    return Container(
      key: const ValueKey('settings-planflow-notification-notice'),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: PlanFlowColors.primaryFaint.withValues(alpha: 0.42),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: PlanFlowColors.primaryFaint),
      ),
      child: Text(
        '알림은 PlanFlow 기준으로 울립니다. 외부 캘린더 앱의 기본 알림이 켜져 있으면 해당 앱에서도 알림이 울릴 수 있어요.',
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: PlanFlowColors.textPrimary,
              fontWeight: FontWeight.w600,
            ),
      ),
    );
  }

  Widget _buildSmartAlarmSettings() {
    return _SectionCard(
      title: '스마트 출발 알림 설정',
      subtitle: '외부 일정마다 현재 위치와 이동시간을 다시 계산해 출발 시각을 알려줍니다.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildPlanFlowNotificationNotice(),
          const SizedBox(height: 16),
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
          const SizedBox(height: 16),
          _SmartAlarmControl(
            title: '출발 알림 반복 주기',
            helperText: '출발 확인 전 같은 출발 알림을 다시 울릴 최소 간격입니다.',
            child: _buildDepartureRepeatIntervalSelector(
              key: const ValueKey('settings-departure-repeat-selector'),
              value: _departureRepeatIntervalMin,
              onChanged: (value) {
                setState(() {
                  _departureRepeatIntervalMin = value;
                });
                unawaited(
                  DepartureAlarmService.saveRepeatIntervalMinutes(value),
                );
              },
            ),
          ),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              key: const ValueKey('settings-critical-alarm-sound-button'),
              onPressed: _openCriticalAlarmSoundSettings,
              icon: const Icon(Icons.notifications_active_outlined),
              label: const Text('중요 알림 소리 바꾸기'),
              style: FilledButton.styleFrom(
                backgroundColor: PlanFlowColors.tertiaryAccent,
                foregroundColor: Colors.white,
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
            'Android 알림 채널 설정에서 중요 일정 알람의 소리를 직접 듣고 바꿀 수 있어요.',
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

  Widget _buildDepartureRepeatIntervalSelector({
    required Key key,
    required int value,
    required ValueChanged<int> onChanged,
  }) {
    final selected =
        DepartureAlarmService.allowedRepeatIntervalMinutes.contains(value)
            ? value
            : DepartureAlarmService.defaultRepeatIntervalMin;
    const options = <(int, String)>[
      (0, '없음'),
      (5, '5분'),
      (10, '10분'),
      (15, '15분'),
      (30, '30분'),
      (60, '60분'),
    ];
    return Wrap(
      key: key,
      spacing: 6,
      runSpacing: 6,
      children: options.map((item) {
        final isSelected = selected == item.$1;
        return ChoiceChip(
          label: Text(item.$2),
          selected: isSelected,
          onSelected: (_) => onChanged(item.$1),
        );
      }).toList(growable: false),
    );
  }

  @override
  Widget build(BuildContext context) {
    final contentMaxWidth = context.planflowWindowInfo.contentMaxWidth;
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
            controller: _settingsScrollController,
            padding: EdgeInsets.fromLTRB(
              AppConstants.defaultPadding,
              AppConstants.defaultPadding,
              AppConstants.defaultPadding,
              AppConstants.defaultPadding + 80,
            ),
            children: [
              _AccountSection(
                authService: _authService,
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
                    SwitchListTile(
                      key: const ValueKey('settings-briefing-enabled-toggle'),
                      title: const Text('브리핑 알람 사용'),
                      subtitle: Text(
                        _briefingEnabled
                            ? '브리핑 알람이 활성화되어 있습니다.'
                            : '브리핑 알람이 꺼져 있습니다.',
                        style: TextStyle(
                          fontSize: 12,
                          color: _briefingEnabled
                              ? PlanFlowColors.textSecondary
                              : PlanFlowColors.textSecondary
                                  .withValues(alpha: 0.6),
                        ),
                      ),
                      value: _briefingEnabled,
                      onChanged: (value) {
                        setState(() {
                          _briefingEnabled = value;
                        });
                        unawaited(_persistSettings());
                      },
                    ),
                    if (_briefingEnabled) ...[
                      const Divider(height: 1),
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
                    ],
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
                    'settings-preferred-map-provider-selector',
                  ),
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
                title: '내 교정 학습 관리',
                subtitle: '내가 고친 표현을 바탕으로 PlanFlow의 AI 학습 능력을 높입니다.',
                child: Column(
                  children: [
                    SwitchListTile.adaptive(
                      key: const ValueKey(
                        'settings-voice-correction-learning-enabled',
                      ),
                      contentPadding: EdgeInsets.zero,
                      value: _voiceCorrectionLearningEnabled,
                      activeThumbColor: PlanFlowColors.primary,
                      activeTrackColor: PlanFlowColors.primaryFaint,
                      title: const Text('내 교정 패턴 사용'),
                      subtitle: const Text(
                        '내가 직접 고친 표현만 내 계정에 저장해 다음 음성 입력과 일정 정리, AI 학습에 참고합니다.',
                      ),
                      onChanged: (value) {
                        setState(() {
                          _voiceCorrectionLearningEnabled = value;
                          if (!value) {
                            _voiceCommonLearningOptIn = false;
                          }
                        });
                        unawaited(_persistSettings());
                      },
                    ),
                    const Divider(height: 1),
                    SwitchListTile.adaptive(
                      key: const ValueKey(
                        'settings-voice-common-learning-opt-in',
                      ),
                      contentPadding: EdgeInsets.zero,
                      value: _voiceCommonLearningOptIn,
                      activeThumbColor: PlanFlowColors.primary,
                      activeTrackColor: PlanFlowColors.primaryFaint,
                      title: const Text('검증된 공통 교정 사용'),
                      subtitle: const Text(
                        '켜면 관리자가 검증한 공통 교정 패턴을 내 음성 입력과 일정 정리에 함께 참고합니다. 내 교정 패턴은 내 계정에만 저장됩니다.',
                      ),
                      onChanged: _voiceCorrectionLearningEnabled
                          ? (value) {
                              setState(() {
                                _voiceCommonLearningOptIn = value;
                              });
                              unawaited(_persistSettings());
                            }
                          : null,
                    ),
                  ],
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
              _buildNotificationPermissionBanner(),
              _buildSmartAlarmSettings(),
              const SizedBox(height: 16),
              KeyedSubtree(
                key: _calendarSyncSectionKey,
                child: _SectionCard(
                  title: appL10n(context).calendarSyncTitle,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _StatusRow(
                        label: 'Google Calendar',
                        value: _googleCalendarSimpleStatusLabel(),
                        icon: Icons.cloud_sync_outlined,
                        isConfigured: _isCalendarConfigured(
                          _calendarSyncSummary?.google,
                        ),
                        onInfo: _showGoogleCalendarStatusDetailDialog,
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
                                        strokeWidth: 2,
                                      ),
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
                              style: _settingsSkyButtonStyle(),
                              icon: _isSyncingGoogleCalendar
                                  ? const SizedBox.square(
                                      dimension: 16,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: Colors.white,
                                      ),
                                    )
                                  : const Icon(Icons.sync),
                              label: Text(
                                _isSyncingGoogleCalendar
                                    ? '동기화 중...'
                                    : _googleCalendarActionLabel(),
                              ),
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
                                value: _naverCalendarSimpleStatusLabel(),
                                icon: Icons.event_available_outlined,
                                isConfigured: _isNaverCalendarConfigured(),
                                onInfo: _isNaverCalendarConfigured()
                                    ? _showNaverCalendarStatusDetailDialog
                                    : null,
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
                                      style: _settingsSkyButtonStyle(),
                                      icon: const Icon(Icons.sync),
                                      label: Text('네이버 일정 동기화'),
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
                                      _isImportingDeviceNaverCalendar ||
                                      !_hasDeviceCalendarSynced
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
                              style: _settingsSkyButtonStyle(),
                              icon: const Icon(Icons.phone_android_outlined),
                              label: Text('휴대폰 내부 캘린더 일정 가져오기'),
                            ),
                          ),
                        ],
                      ),
                      if (_deviceCalendarImportLongRunning) ...[
                        const SizedBox(height: 8),
                        Text(
                          '일정이 많아 조금 걸리고 있습니다. 가져오기는 계속 진행 중입니다.',
                          style: Theme.of(context)
                              .textTheme
                              .bodySmall
                              ?.copyWith(color: PlanFlowColors.textSecondary),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              FeedbackReportSection(
                onPressed: _openFeedbackReportSheet,
                onOpenBetaSurvey: _openBetaSurveySheet,
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
                              key: const ValueKey(
                                'settings-create-backup-button',
                              ),
                              onPressed:
                                  _isBackupActionRunning ? null : _createBackup,
                              style: _settingsSkyButtonStyle(),
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
                            child: FilledButton.icon(
                              key: const ValueKey(
                                'settings-restore-backup-button',
                              ),
                              onPressed: _isBackupActionRunning
                                  ? null
                                  : _showBackupRestoreDialog,
                              style: _settingsBriefingButtonStyle(),
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
              _SectionCard(
                title: '앱 정보',
                subtitle: '설치된 PlanFlow의 현재 버전입니다.',
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(
                      Icons.info_outline,
                      color: PlanFlowColors.primary,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        _appVersionLabel,
                        key: const ValueKey('settings-app-version-label'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                              color: PlanFlowColors.textPrimary,
                              fontWeight: FontWeight.w700,
                            ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    OutlinedButton.icon(
                      key: const ValueKey('settings-diagnostic-log-button'),
                      onPressed: _showDiagnosticLogDialog,
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 10,
                        ),
                        visualDensity: VisualDensity.compact,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      icon: const Icon(Icons.bug_report_outlined, size: 18),
                      label: const Text('진단 로그 보기'),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              _buildRegionSettings(),
            ],
          ),
        ),
      ),
      floatingActionButton: PlanFlowVoiceFab(
        onPressed: () => context.push(AppRoutes.voice),
      ),
    );
  }

  Future<void> _openBetaSurveySheet() async {
    FeedbackRepository repository;
    try {
      repository = FeedbackRepository.supabase();
    } on FeedbackSubmissionException catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(error.message)));
      return;
    }

    final submitted = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => BetaSurveySheet(repository: repository),
    );
    if (!mounted || submitted != true) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('후기를 보내주셔서 감사해요! 앱 개선에 바로 반영할게요. 🙏')),
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
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.message)));
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
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('문제 신고를 보냈어요. 확인하고 반영할게요.')));
  }

  Future<void> _openFeedbackAdminReportsSheet() async {
    if (!_isFeedbackAdmin) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('관리자 계정에서만 신고함을 열 수 있어요.')));
      return;
    }

    FeedbackRepository repository;
    try {
      repository = FeedbackRepository.supabase();
    } on FeedbackSubmissionException catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.message)));
      return;
    }

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => FeedbackAdminReportsSheet(repository: repository),
    );
    await _refreshNewFeedbackReportCount();
  }

  String _formatTime(BuildContext context, TimeOfDay timeOfDay) {
    return MaterialLocalizations.of(
      context,
    ).formatTimeOfDay(timeOfDay, alwaysUse24HourFormat: _use24HourFormat);
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

  String _googleCalendarSimpleStatusLabel() {
    if (_isLoadingCalendarStatus) return '확인 중...';
    final result = _calendarSyncSummary?.google;
    if (result == null) return '연결 안 됨';
    if (_isCalendarConfigured(result)) return '정상적으로 연결되었습니다.';
    return '연결 안 됨';
  }

  void _showGoogleCalendarStatusDetailDialog() {
    final detail = _calendarStatusLabel(_calendarSyncSummary?.google);
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Google Calendar 상태'),
        content: Text(detail),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('확인'),
          ),
        ],
      ),
    );
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
    final autoSyncSnapshot = _naverCalendarAutoSyncSnapshot;
    if (autoSyncSnapshot != null) {
      return autoSyncSnapshot.message;
    }
    final summary = _calendarSyncSummary?.naver;
    if (summary != null) {
      return summary.message;
    }
    if (_hasNaverCalDavCredentials) {
      return _lastNaverCalDavResult?.message ??
          '네이버 CalDAV 자격증명이 저장되어 있습니다. 동기화를 눌러 확인해 주세요.';
    }
    return '네이버 캘린더 연결 안 됨';
  }

  String _naverCalendarSimpleStatusLabel() {
    if (!_isNaverCalendarConfigured()) {
      return '연결 안 됨';
    }
    final autoSyncSnapshot = _naverCalendarAutoSyncSnapshot;
    if (autoSyncSnapshot != null) {
      return '자동 동기화 중';
    }
    final result = _lastNaverCalDavResult;
    if (result != null && result.isSuccess) {
      return '정상적으로 연결되었습니다.';
    }
    if (_hasNaverCalDavCredentials) {
      return '정상적으로 연결되었습니다. 네이버 일정 동기화를 시작하세요.';
    }
    return '연결 안 됨';
  }

  void _showNaverCalendarStatusDetailDialog() {
    final detail = _naverCalendarStatusLabel();
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('네이버 캘린더 상태'),
        content: Text(detail),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('닫기'),
          ),
        ],
      ),
    );
  }

  CalendarAutoSyncProviderSnapshot? _autoSyncProviderSnapshot(
    Iterable<String> providerKeys,
  ) {
    final snapshot = _calendarAutoSyncSnapshot;
    if (snapshot == null) {
      return null;
    }
    final keys = providerKeys.toSet();
    final providers = snapshot.providers.where((provider) {
      return keys.contains(provider.key);
    }).toList(growable: false);
    if (providers.isEmpty) {
      return null;
    }
    providers.sort((a, b) {
      final aStamp = a.checkedAt ??
          a.lastSuccessAt ??
          DateTime.fromMillisecondsSinceEpoch(0);
      final bStamp = b.checkedAt ??
          b.lastSuccessAt ??
          DateTime.fromMillisecondsSinceEpoch(0);
      return bStamp.compareTo(aStamp);
    });
    return providers.first;
  }

  CalendarAutoSyncProviderSnapshot? get _googleCalendarAutoSyncSnapshot {
    return _autoSyncProviderSnapshot(const ['google_auto_sync']);
  }

  CalendarAutoSyncProviderSnapshot? get _naverCalendarAutoSyncSnapshot {
    return _autoSyncProviderSnapshot(const ['naver_caldav_auto_import']);
  }

  CalendarAutoSyncProviderSnapshot? get _deviceCalendarAutoSyncSnapshot {
    return _autoSyncProviderSnapshot(const ['device_calendar_auto_import']);
  }

  bool _isNaverCalendarConfigured() {
    // 로컬 CalDAV 자격증명이 없으면 DB 상태와 무관하게 미연결
    if (!_hasNaverCalDavCredentials) return false;
    final summary = _calendarSyncSummary?.naver;
    if (summary != null) {
      if (summary.status == CalendarIntegrationStatus.synced ||
          summary.status == CalendarIntegrationStatus.ready) {
        return true;
      }
    }
    final snapshot = _naverCalendarAutoSyncSnapshot;
    if (snapshot?.lastSuccessAt != null) {
      return true;
    }
    return false;
  }

  bool _hasSyncedDeviceCalendar(CalendarSyncSummary summary) {
    final snapshot = _deviceCalendarAutoSyncSnapshot;
    if (snapshot?.lastSuccessAt != null) {
      return true;
    }
    return summary.naver.isSuccess &&
        summary.naver.syncedItems > 0 &&
        _hasDeviceCalendarSynced;
  }

  bool _isCalendarConfigured(CalendarIntegrationResult? result) {
    if (result == null) return false;
    // signedOut/notConfigured 상태에서는 과거 성공 스냅샷으로 연결된 것처럼 표시하지 않음
    if (result.status == CalendarIntegrationStatus.signedOut ||
        result.status == CalendarIntegrationStatus.notConfigured) {
      return false;
    }
    if (result.status == CalendarIntegrationStatus.synced) {
      return true;
    }
    final snapshot = _googleCalendarAutoSyncSnapshot;
    return snapshot?.lastSuccessAt != null;
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

/// 네이버 동기화 진행 표시. 단계 점프는 TweenAnimationBuilder로 보간하고,
/// 표시값이 3초 이상 멈추면 완료(97%) 전까지 1%씩 크리프해 "멈춤"으로 보이지 않게 한다.
class _NaverCalDavProgressView extends StatefulWidget {
  const _NaverCalDavProgressView({required this.progressListenable});

  final ValueListenable<NaverCalDavSyncProgress?> progressListenable;

  @override
  State<_NaverCalDavProgressView> createState() =>
      _NaverCalDavProgressViewState();
}

class _NaverCalDavProgressViewState extends State<_NaverCalDavProgressView> {
  double _displayValue = 0;
  double _lastTarget = -1;
  DateTime _lastTargetChange = DateTime.now();
  Timer? _creepTimer;

  @override
  void initState() {
    super.initState();
    widget.progressListenable.addListener(_onProgress);
    _onProgress();
    _creepTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => _tickCreep(),
    );
  }

  @override
  void dispose() {
    widget.progressListenable.removeListener(_onProgress);
    _creepTimer?.cancel();
    super.dispose();
  }

  void _onProgress() {
    final target = _progressValue(widget.progressListenable.value);
    if (target != _lastTarget) {
      _lastTarget = target;
      _lastTargetChange = DateTime.now();
    }
    // 단조 증가: 실제 진행이 표시값을 추월하면 그 값으로 끌어올린다.
    if (target > _displayValue && mounted) {
      setState(() => _displayValue = target);
    }
  }

  void _tickCreep() {
    if (!mounted) {
      return;
    }
    final progress = widget.progressListenable.value;
    if (progress?.stage == NaverCalDavSyncStage.completed) {
      return;
    }
    // 표시값이 3초 이상 멈춰 있으면 완료(97%) 전까지 1%씩 천천히 올린다.
    final idle = DateTime.now().difference(_lastTargetChange);
    if (idle.inSeconds >= 3 && _displayValue < 0.97) {
      setState(() {
        _displayValue = (_displayValue + 0.01).clamp(0.0, 0.97);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final progress = widget.progressListenable.value;
    final stage = progress?.stage;
    final showBackgroundHint = stage == NaverCalDavSyncStage.querying ||
        stage == NaverCalDavSyncStage.saving;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TweenAnimationBuilder<double>(
          tween: Tween<double>(begin: 0, end: _displayValue),
          duration: const Duration(milliseconds: 450),
          curve: Curves.easeOut,
          builder: (context, animatedValue, _) {
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                LinearProgressIndicator(
                  value: animatedValue,
                  minHeight: 8,
                  backgroundColor: PlanFlowColors.primaryFaint,
                  valueColor: AlwaysStoppedAnimation<Color>(
                    PlanFlowColors.primary,
                  ),
                ),
                const SizedBox(height: 12),
                Center(
                  child: Text(
                    '${(animatedValue * 100).round()}%',
                    style: Theme.of(context).textTheme.labelLarge?.copyWith(
                          color: PlanFlowColors.primary,
                          fontWeight: FontWeight.w700,
                        ),
                  ),
                ),
              ],
            );
          },
        ),
        const SizedBox(height: 16),
        Text(_statusText(progress)),
        if (showBackgroundHint) ...[
          const SizedBox(height: 12),
          Text(
            '앱을 전환해도 동기화는 계속됩니다.',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: PlanFlowColors.textSecondary,
                ),
          ),
        ],
      ],
    );
  }

  static double _progressValue(NaverCalDavSyncProgress? progress) {
    if (progress == null) {
      return 0.05;
    }
    switch (progress.stage) {
      case NaverCalDavSyncStage.preparing:
        return 0.05;
      case NaverCalDavSyncStage.calendars:
        return 0.12;
      case NaverCalDavSyncStage.querying:
        final total = progress.totalCalendars;
        final done = progress.currentCalendarIndex;
        if (total <= 0) {
          return 0.15;
        }
        final fraction = (done / total).clamp(0.0, 1.0);
        return (0.15 + 0.45 * fraction).clamp(0.0, 1.0);
      case NaverCalDavSyncStage.saving:
        final done = progress.savedEvents +
            progress.skippedEvents +
            progress.failedEvents;
        final total = progress.totalEvents;
        if (total <= 0) {
          return 0.60;
        }
        final fraction = (done / total).clamp(0.0, 1.0);
        return (0.60 + 0.40 * fraction).clamp(0.0, 1.0);
      case NaverCalDavSyncStage.completed:
        return 1.0;
    }
  }

  static String _statusText(NaverCalDavSyncProgress? progress) {
    final totalCalendars = progress?.totalCalendars ?? 0;
    final savedEvents = progress?.savedEvents ?? 0;
    final skippedEvents = progress?.skippedEvents ?? 0;
    final failedEvents = progress?.failedEvents ?? 0;
    final totalEvents = progress?.totalEvents ?? 0;
    final done = savedEvents + skippedEvents + failedEvents;
    switch (progress?.stage) {
      case NaverCalDavSyncStage.preparing:
        return '네이버 연결 확인 중';
      case NaverCalDavSyncStage.calendars:
        return '캘린더 확인 중';
      case NaverCalDavSyncStage.querying:
        if (totalCalendars > 0) {
          return '일정 가져오는 중 (캘린더 $totalCalendars개)';
        }
        return '일정 가져오는 중';
      case NaverCalDavSyncStage.saving:
        if (totalEvents > 0) {
          return 'PlanFlow에 저장 중 ($done/$totalEvents개)';
        }
        return 'PlanFlow에 저장 중';
      case NaverCalDavSyncStage.completed:
        return '마무리 중';
      case null:
        return '네이버 연결 확인 중';
    }
  }
}
