import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/constants.dart';
import '../../core/env.dart';
import '../../core/theme.dart';
import '../../data/models/calendar_connection_model.dart';
import '../../data/models/user_settings_model.dart';
import '../../data/repositories/calendar_connection_repository.dart';
import '../../data/repositories/settings_repository.dart';
import '../../providers/auth_provider.dart';
import '../../providers/settings_provider.dart';
import '../../services/auth_service.dart';
import '../../services/backup_service.dart';
import '../../services/briefing_scheduler_service.dart';
import '../../services/calendar_sync_service.dart';
import '../../services/daily_backup_scheduler_service.dart';
import '../../services/device_calendar_service.dart';
import '../../services/event_refresh_bus.dart';
import '../../services/naver_caldav_service.dart';
import '../../services/naver_calendar_permission_service.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    SettingsRepository? settingsRepository,
    BriefingSchedulerService? briefingSchedulerService,
    CalendarSyncService? calendarSyncService,
    Object? notificationService,
    BackupService? backupService,
    AuthService? authService,
    NaverCalendarPermissionService? naverCalendarPermissionService,
    DeviceCalendarService? deviceCalendarService,
    NaverCalDavService? naverCalDavService,
    String? userId,
  })  : _settingsRepository = settingsRepository,
        _briefingSchedulerService = briefingSchedulerService,
        _calendarSyncService = calendarSyncService,
        _backupService = backupService,
        _authService = authService,
        _naverCalendarPermissionService = naverCalendarPermissionService,
        _deviceCalendarService = deviceCalendarService,
        _naverCalDavService = naverCalDavService,
        _userId = userId;

  final SettingsRepository? _settingsRepository;
  final BriefingSchedulerService? _briefingSchedulerService;
  final CalendarSyncService? _calendarSyncService;
  final BackupService? _backupService;
  final AuthService? _authService;
  final NaverCalendarPermissionService? _naverCalendarPermissionService;
  final DeviceCalendarService? _deviceCalendarService;
  final NaverCalDavService? _naverCalDavService;
  final String? _userId;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final SettingsRepository _settingsRepository;
  late final SettingsProvider _settingsProvider;
  late final BriefingSchedulerService _briefingSchedulerService;
  late final CalendarSyncService _calendarSyncService;
  late final DailyBackupSchedulerService _dailyBackupSchedulerService;
  late final DeviceCalendarService _deviceCalendarService;
  late final NaverCalDavService _naverCalDavService;

  BackupService? _backupService;
  AuthService? _authService;
  NaverCalendarPermissionService? _naverCalendarPermissionService;

  UserSettingsModel? _savedSettings;
  TimeOfDay _morningBriefingAt = const TimeOfDay(hour: 7, minute: 30);
  TimeOfDay _eveningBriefingAt = const TimeOfDay(hour: 21, minute: 0);
  int _defaultReminderMinutes = 60;
  String _travelMode = 'car';
  bool _voiceAutoStart = true;

  CalendarSyncSummary? _calendarSyncSummary;
  List<BackupSnapshot> _backups = const <BackupSnapshot>[];

  bool _isLoadingCalendarStatus = true;
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

  String? get _userId => widget._userId ?? authProvider.userId;

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
    _dailyBackupSchedulerService = const DailyBackupSchedulerService();
    _deviceCalendarService =
        widget._deviceCalendarService ?? DeviceCalendarService();
    _ownsNaverCalDavService = widget._naverCalDavService == null;
    _naverCalDavService = widget._naverCalDavService ?? NaverCalDavService();
    _backupService = widget._backupService ??
        (AppEnv.isSupabaseReady ? BackupService() : null);
    _authService =
        widget._authService ?? (AppEnv.isSupabaseReady ? AuthService() : null);
    _naverCalendarPermissionService = widget._naverCalendarPermissionService;

    unawaited(_loadSettings());
    unawaited(_loadCalendarStatus());
    unawaited(_loadNaverCalDavState());
    if (AppEnv.isSupabaseReady) {
      unawaited(_loadBackups());
      unawaited(_ensureAutomaticBackup());
    }
  }

  @override
  void dispose() {
    _settingsProvider.dispose();
    if (_ownsNaverCalDavService) {
      unawaited(_naverCalDavService.dispose());
    }
    _naverCalDavLongRunningTimer?.cancel();
    _naverCalDavProgress.dispose();
    _naverCalDavLongRunning.dispose();
    super.dispose();
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
      dismissibleProgress: false,
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
      dismissibleProgress: true,
      additionalLabel: range.label,
    );
  }

  Future<NaverCalDavSyncResult?> _runNaverCalDavImport({
    required String userId,
    required NaverCalDavSyncMode mode,
    DateTime? from,
    DateTime? to,
    required bool dismissibleProgress,
    String? additionalLabel,
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
    unawaited(_showNaverCalDavProgressDialog(
      dismissible: dismissibleProgress,
    ));
    final result = await _naverCalDavService.syncAll(
      userId: userId,
      from: from,
      to: to,
      mode: mode,
      skipUnchanged: true,
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
            child: FilledButton(
              onPressed: onConfirm,
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(48),
                foregroundColor: confirmForegroundColor ?? Colors.white,
                backgroundColor:
                    confirmBackgroundColor ?? PlanFlowColors.primary,
              ),
              child: Text(confirmLabel),
            ),
          ),
        ],
      ),
    );
  }

  Future<_NaverCalDavImportRange?> _showNaverCalDavMoreRangeDialog() {
    return showDialog<_NaverCalDavImportRange>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('추가 기록 가져오기'),
        content: const Text(
          '최근 3개월과 앞으로 6개월 일정을 저장했습니다. 더 과거 기록을 얼마나 불러올까요?',
        ),
        actions: [
          SizedBox(
            width: double.infinity,
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.center,
              children: [
                SizedBox(
                  width: 80,
                  child: OutlinedButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('나중에'),
                  ),
                ),
                SizedBox(
                  width: 80,
                  child: FilledButton.tonal(
                    onPressed: () => Navigator.of(context).pop(
                      _NaverCalDavImportRange.months(6),
                    ),
                    child: const Text('6개월'),
                  ),
                ),
                SizedBox(
                  width: 80,
                  child: FilledButton.tonal(
                    onPressed: () => Navigator.of(context).pop(
                      _NaverCalDavImportRange.years(1),
                    ),
                    child: const Text('1년'),
                  ),
                ),
                SizedBox(
                  width: 80,
                  child: FilledButton.tonal(
                    onPressed: () => Navigator.of(context).pop(
                      _NaverCalDavImportRange.years(2),
                    ),
                    child: const Text('2년'),
                  ),
                ),
                SizedBox(
                  width: 80,
                  child: OutlinedButton(
                    onPressed: () async {
                      final range = await _showNaverCalDavCustomRangeDialog();
                      if (context.mounted && range != null) {
                        Navigator.of(context).pop(range);
                      }
                    },
                    child: const Text('직접 입력'),
                  ),
                ),
                SizedBox(
                  width: 80,
                  child: FilledButton(
                    onPressed: () async {
                      final confirmed = await _confirmNaverCalDavAllRange();
                      if (context.mounted && confirmed) {
                        Navigator.of(context).pop(
                          _NaverCalDavImportRange.all(),
                        );
                      }
                    },
                    child: const Text('전체'),
                  ),
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

    return showDialog<_NaverCalDavCredentials>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('네이버 캘린더 연결'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'PlanFlow가 네이버 CalDAV 서버에 직접 연결해 기존 일정을 가져옵니다.\n\n'
                'ID는 로그인 전용 ID가 아니라 원본 네이버 ID를 입력해 주세요.\n\n'
                '앱 비밀번호는 네이버 앱/웹에서 2단계 인증 관리 → 애플리케이션 비밀번호 생성 → Android 선택 후 발급받은 값을 입력해 주세요. 네이버 일반 비밀번호가 아닙니다.',
              ),
              const SizedBox(height: 16),
              TextField(
                controller: idController,
                decoration: const InputDecoration(
                  labelText: '네이버 ID',
                  hintText: '예: tught3',
                ),
                textInputAction: TextInputAction.next,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: passwordController,
                decoration: const InputDecoration(
                  labelText: '앱 비밀번호',
                  hintText: '네이버 보안설정에서 발급한 비밀번호',
                ),
                obscureText: true,
                textInputAction: TextInputAction.done,
                onSubmitted: (_) {
                  Navigator.of(context).pop(
                    _NaverCalDavCredentials(
                      naverId: idController.text,
                      appPassword: passwordController.text,
                    ),
                  );
                },
              ),
              const SizedBox(height: 12),
              Text(
                '연결에 성공한 경우에만 이 기기의 보안 저장소에 저장되며, Supabase에는 저장하지 않습니다.',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: PlanFlowColors.textSecondary,
                    ),
              ),
            ],
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
            ),
          ],
        );
      },
    );
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
    if (userId == null || userId.isEmpty || _isSavingSettings) {
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
        travelMode: _travelMode,
        voiceAutoStart: _voiceAutoStart,
      );
      final saved = await _settingsProvider.save(draft);
      if (!mounted) {
        return;
      }
      setState(() {
        _savedSettings = saved;
        _applySettings(saved);
      });
      final scheduleResult = await _scheduleBriefingsFromSettings(
        saved,
        reason: 'settings_saved',
      );
      if (successMessage != null) {
        final suffix = scheduleResult?.allScheduled == false
            ? ' 브리핑 예약은 Android 알람 설정을 확인해 주세요.'
            : '';
        _showSnack('$successMessage$suffix');
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
      await _briefingSchedulerService.executeBriefing(
        isMorning: isMorning,
        userId: userId,
      );
      _showSnack(isMorning ? '모닝 브리핑을 테스트 재생했습니다.' : '이브닝 브리핑을 테스트 재생했습니다.');
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
      _travelMode = 'car';
      _voiceAutoStart = true;
    });
    unawaited(_persistSettings(successMessage: '설정을 기본값으로 되돌렸습니다.'));
  }

  void _applySettings(UserSettingsModel settings) {
    _morningBriefingAt = _parseTime(settings.morningBriefingAt);
    _eveningBriefingAt = _parseTime(settings.eveningBriefingAt);
    _defaultReminderMinutes = settings.defaultReminderMin;
    _travelMode = settings.travelMode;
    _voiceAutoStart = settings.voiceAutoStart;
  }

  void _showSnack(String message) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final morningLabel = _formatTime(context, _morningBriefingAt);
    final eveningLabel = _formatTime(context, _eveningBriefingAt);
    final nextBriefings = _briefingSchedulerService.nextDailyTimes(
      morningTime: _formatTimeValue(_morningBriefingAt),
      eveningTime: _formatTimeValue(_eveningBriefingAt),
    );

    return Scaffold(
      backgroundColor: PlanFlowColors.background,
      appBar: AppBar(
        title: const Text('설정'),
        actions: [
          IconButton(
            tooltip: '기본값으로 되돌리기',
            onPressed: _resetToDefaults,
            icon: const Icon(Icons.restart_alt),
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(AppConstants.defaultPadding),
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
                  _TimeSettingTile(
                    title: '모닝 브리핑',
                    subtitle: '다음 예약 ${_formatDateTime(nextBriefings.morning)}',
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
                    subtitle: '다음 예약 ${_formatDateTime(nextBriefings.evening)}',
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
              ),
            ),
            const SizedBox(height: 16),
            _SectionCard(
              title: '이동수단',
              subtitle: '위치 기반 이동시간 계산과 스마트 준비 알람에 우선 적용할 방식을 정합니다.',
              child: SegmentedButton<String>(
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
              title: '음성 입력 방식',
              subtitle: '홈이나 위젯의 마이크 버튼을 눌렀을 때 바로 듣기 시작할지 정합니다.',
              child: SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                value: _voiceAutoStart,
                activeThumbColor: PlanFlowColors.primary,
                activeTrackColor: PlanFlowColors.primaryFaint,
                title: const Text('마이크 버튼을 누르면 바로 듣기 시작'),
                subtitle: Text(
                  _voiceAutoStart ? '바로 음성입력' : '버튼 눌러서 입력',
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
              title: '캘린더 연동',
              subtitle:
                  'Google과 Naver 일정을 PlanFlow와 동기화합니다. Naver는 CalDAV로 연결합니다.',
              child: Column(
                children: [
                  _StatusRow(
                    label: 'Google Calendar',
                    value: _calendarStatusLabel(_calendarSyncSummary?.google),
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
                                  child:
                                      CircularProgressIndicator(strokeWidth: 2),
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
                          onPressed: _isLoadingCalendarStatus ||
                                  _isSyncingGoogleCalendar ||
                                  _isDisconnectingGoogleCalendar
                              ? null
                              : _syncGoogleCalendar,
                          icon: _isSyncingGoogleCalendar
                              ? const SizedBox.square(
                                  dimension: 18,
                                  child:
                                      CircularProgressIndicator(strokeWidth: 2),
                                )
                              : const Icon(Icons.sync),
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
                                  onPressed: _isLoadingCalendarStatus ||
                                          _isTestingNaverCalDav ||
                                          _isImportingNaverCalDav ||
                                          _isDisconnectingNaverCalendar
                                      ? null
                                      : _syncOrReconnectNaverCalendar,
                                  icon: _isTestingNaverCalDav ||
                                          _isImportingNaverCalDav
                                      ? const SizedBox.square(
                                          dimension: 18,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                          ),
                                        )
                                      : const Icon(Icons.sync),
                                  label: Text(
                                    _isImportingNaverCalDav
                                        ? '동기화 중...'
                                        : _isTestingNaverCalDav
                                            ? '연결 확인 중...'
                                            : '네이버 일정 동기화',
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
                          icon: _isImportingDeviceNaverCalendar
                              ? const SizedBox.square(
                                  dimension: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.phone_android_outlined),
                          label: Text(
                            _isImportingDeviceNaverCalendar
                                ? '가져오는 중...'
                                : '휴대폰 내부 캘린더 일정 가져오기',
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            if (authProvider.isSignedIn && _backupService != null) ...[
              const SizedBox(height: 16),
              _SectionCard(
                title: '백업 및 복원',
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
            ],
          ],
        ),
      ),
    );
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
    if (_isSyncingGoogleCalendar) {
      return '동기화 중...';
    }
    final status = _calendarSyncSummary?.google.status;
    return switch (status) {
      CalendarIntegrationStatus.ready ||
      CalendarIntegrationStatus.synced ||
      CalendarIntegrationStatus.failed =>
        'Google Calendar 다시 동기화',
      _ => 'Google Calendar 연결',
    };
  }

  String _naverCalendarStatusLabel() {
    if (_isTestingNaverCalDav) {
      return 'CalDAV 연결을 확인하는 중입니다.';
    }
    if (_isImportingNaverCalDav) {
      return '네이버 일정을 가져오는 중입니다.';
    }
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
      CalendarIntegrationStatus.synced =>
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
    required this.onSignedOut,
  });

  final AuthService? authService;
  final VoidCallback onSignedOut;

  @override
  Widget build(BuildContext context) {
    return _SectionCard(
      title: '계정',
      subtitle: '현재 로그인 상태를 확인하고 필요하면 로그아웃할 수 있습니다.',
      child: AnimatedBuilder(
        animation: authProvider,
        builder: (context, _) {
          final signedIn = authProvider.isSignedIn;
          return Column(
            children: [
              _StatusRow(
                label: '로그인 상태',
                value: signedIn ? authProvider.email ?? '로그인됨' : '로그아웃됨',
                icon: Icons.account_circle_outlined,
                isConfigured: signedIn,
              ),
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

class _SectionCard extends StatelessWidget {
  const _SectionCard({
    required this.title,
    required this.subtitle,
    required this.child,
  });

  final String title;
  final String subtitle;
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
            const SizedBox(height: 4),
            Text(
              subtitle,
              style: theme.textTheme.bodySmall?.copyWith(
                color: PlanFlowColors.textSecondary,
              ),
            ),
            const SizedBox(height: 16),
            child,
          ],
        ),
      ),
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
