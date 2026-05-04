import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/constants.dart';
import '../../core/env.dart';
import '../../core/theme.dart';
import '../../data/models/user_settings_model.dart';
import '../../data/repositories/settings_repository.dart';
import '../../providers/auth_provider.dart';
import '../../providers/settings_provider.dart';
import '../../services/auth_service.dart';
import '../../services/backup_service.dart';
import '../../services/briefing_scheduler_service.dart';
import '../../services/calendar_sync_service.dart';
import '../../services/daily_backup_scheduler_service.dart';
import '../../services/notification_service.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    SettingsRepository? settingsRepository,
    BriefingSchedulerService? briefingSchedulerService,
    CalendarSyncService? calendarSyncService,
    NotificationService? notificationService,
    BackupService? backupService,
    AuthService? authService,
    String? userId,
    bool? envConfigured,
  })  : _settingsRepository = settingsRepository,
        _briefingSchedulerService = briefingSchedulerService,
        _calendarSyncService = calendarSyncService,
        _notificationService = notificationService,
        _backupService = backupService,
        _authService = authService,
        _userId = userId,
        _envConfigured = envConfigured;

  final SettingsRepository? _settingsRepository;
  final BriefingSchedulerService? _briefingSchedulerService;
  final CalendarSyncService? _calendarSyncService;
  final NotificationService? _notificationService;
  final BackupService? _backupService;
  final AuthService? _authService;
  final String? _userId;
  final bool? _envConfigured;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final SettingsRepository _settingsRepository;
  late final SettingsProvider _settingsProvider;
  late final BriefingSchedulerService _briefingSchedulerService;
  late final CalendarSyncService _calendarSyncService;
  late final NotificationService _notificationService;
  late final DailyBackupSchedulerService _dailyBackupSchedulerService;

  BackupService? _backupService;
  AuthService? _authService;

  UserSettingsModel? _savedSettings;
  TimeOfDay _morningBriefingAt = const TimeOfDay(hour: 7, minute: 30);
  TimeOfDay _eveningBriefingAt = const TimeOfDay(hour: 21, minute: 0);
  int _defaultReminderMinutes = 60;
  String _travelMode = 'car';

  CalendarSyncSummary? _calendarSyncSummary;
  NotificationPermissionStatus? _notificationPermissionStatus;
  List<BackupSnapshot> _backups = const <BackupSnapshot>[];

  bool _isLoadingSettings = true;
  bool _isLoadingCalendarStatus = true;
  bool _isLoadingNotificationStatus = true;
  bool _isSyncingGoogleCalendar = false;
  bool _isRequestingNotificationPermissions = false;
  bool _isLoadingBackups = false;
  bool _isSavingSettings = false;
  bool _isBackupActionRunning = false;

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
    _notificationService = widget._notificationService ?? NotificationService();
    _dailyBackupSchedulerService = const DailyBackupSchedulerService();

    if (AppEnv.isSupabaseReady) {
      _backupService = widget._backupService ?? BackupService();
      _authService = widget._authService ?? AuthService();
      unawaited(_loadBackups());
      unawaited(_ensureAutomaticBackup());
    } else {
      _backupService = widget._backupService;
      _authService = widget._authService;
    }

    unawaited(_bootstrap());
  }

  Future<void> _bootstrap() async {
    await Future.wait<void>([
      _loadSettings(),
      _loadCalendarStatus(),
      _loadNotificationStatus(),
    ]);
  }

  String? get _userId => widget._userId ?? authProvider.userId;

  Future<void> _loadSettings() async {
    final userId = _userId;
    final hasUsableRepository =
        AppEnv.isSupabaseReady || widget._settingsRepository != null;
    if (!hasUsableRepository || userId == null || userId.isEmpty) {
      if (!mounted) {
        return;
      }

      setState(() {
        _savedSettings = null;
        _isLoadingSettings = false;
      });
      return;
    }

    setState(() {
      _isLoadingSettings = true;
    });

    final loaded = await _settingsProvider.load(userId);
    if (!mounted) {
      return;
    }

    final effective = loaded ?? UserSettingsModel.defaults(userId: userId);
    setState(() {
      _savedSettings = effective;
      _applySettings(effective);
      _isLoadingSettings = false;
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

  Future<void> _loadNotificationStatus() async {
    setState(() {
      _isLoadingNotificationStatus = true;
    });

    try {
      final status = await _notificationService.checkPermissionStatus();
      if (!mounted) {
        return;
      }
      setState(() {
        _notificationPermissionStatus = status;
      });
    } catch (_) {
      if (mounted) {
        _showSnack('알림 권한 상태를 확인하지 못했습니다.');
      }
    } finally {
      if (mounted) {
        setState(() {
          _isLoadingNotificationStatus = false;
        });
      }
    }
  }

  Future<void> _requestNotificationPermissions() async {
    if (_isRequestingNotificationPermissions) {
      return;
    }

    setState(() {
      _isRequestingNotificationPermissions = true;
    });

    try {
      final status = await _notificationService.requestAndCheckPermissions();
      if (!mounted) {
        return;
      }
      setState(() {
        _notificationPermissionStatus = status;
      });
      _showSnack(_notificationPermissionSnack(status));
    } catch (error, stackTrace) {
      debugPrint('Notification permission request failed: $error');
      debugPrintStack(stackTrace: stackTrace);
      try {
        final status = await _notificationService.checkPermissionStatus();
        if (!mounted) {
          return;
        }
        setState(() {
          _notificationPermissionStatus = status;
        });
        _showSnack(_notificationPermissionSnack(status));
      } catch (_) {
        if (mounted) {
          _showSnack('알림 권한 상태를 확인하지 못했습니다. Android 앱 설정에서 직접 확인해 주세요.');
        }
      }
    } finally {
      if (mounted) {
        setState(() {
          _isRequestingNotificationPermissions = false;
        });
      }
    }
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

  Future<void> _syncGoogleCalendar() async {
    if (_isSyncingGoogleCalendar) {
      return;
    }

    final previousSummary = _calendarSyncSummary;
    setState(() {
      _isSyncingGoogleCalendar = true;
      if (previousSummary != null) {
        _calendarSyncSummary = CalendarSyncSummary(
          google: CalendarIntegrationResult.syncing(
            CalendarProvider.google,
            message: '구글 캘린더 동기화 중입니다.',
          ),
          naver: previousSummary.naver,
        );
      }
    });

    final result = await _calendarSyncService.syncGoogleCalendar(
      interactive: true,
    );
    if (!mounted) {
      return;
    }

    setState(() {
      _calendarSyncSummary = CalendarSyncSummary(
        google: result,
        naver: previousSummary?.naver ??
            CalendarIntegrationResult.unsupported(CalendarProvider.naver),
      );
      _isSyncingGoogleCalendar = false;
    });
    _showSnack(_calendarSyncSnackMessage(result));
  }

  Future<void> _pickTime({
    required BuildContext context,
    required bool isMorning,
  }) async {
    final initialTime = isMorning ? _morningBriefingAt : _eveningBriefingAt;
    final picked = await showTimePicker(
      context: context,
      initialTime: initialTime,
      builder: (context, child) {
        return MediaQuery(
          data: MediaQuery.of(context).copyWith(alwaysUse24HourFormat: true),
          child: child ?? const SizedBox.shrink(),
        );
      },
    );

    if (!mounted || picked == null) {
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

  Future<void> _openNotificationSettings() async {
    final opened = await _notificationService.openAppNotificationSettings();
    _showSnack(
      opened
          ? 'Android 알림 설정을 열었습니다.'
          : 'Android 알림 설정을 열지 못했습니다. 휴대폰 설정에서 PlanFlow 알림을 확인해 주세요.',
    );
  }

  void _resetToDefaults() {
    setState(() {
      _morningBriefingAt = const TimeOfDay(hour: 7, minute: 30);
      _eveningBriefingAt = const TimeOfDay(hour: 21, minute: 0);
      _defaultReminderMinutes = 60;
      _travelMode = 'car';
    });

    unawaited(_persistSettings(successMessage: '설정을 기본값으로 되돌렸습니다.'));
  }

  Future<void> _persistSettings({String? successMessage}) async {
    final userId = _userId;
    if (userId == null || userId.isEmpty) {
      if (successMessage != null) {
        _showSnack('로그인한 뒤 설정을 저장할 수 있습니다.');
      }
      return;
    }

    if (_isSavingSettings) {
      return;
    }

    setState(() {
      _isSavingSettings = true;
    });

    try {
      final current =
          _savedSettings ?? UserSettingsModel.defaults(userId: userId);
      final draft = current.copyWith(
        userId: userId,
        morningBriefingAt: _formatTimeValue(_morningBriefingAt),
        eveningBriefingAt: _formatTimeValue(_eveningBriefingAt),
        defaultReminderMin: _defaultReminderMinutes,
        travelMode: _travelMode,
      );

      final saved = await _settingsProvider.save(draft);
      if (!mounted) {
        return;
      }

      setState(() {
        _savedSettings = saved;
        _applySettings(saved);
      });

      await _briefingSchedulerService.scheduleDaily(
        morningTime: saved.morningBriefingAt,
        eveningTime: saved.eveningBriefingAt,
        userId: userId,
      );
      if (successMessage != null) {
        _showSnack(successMessage);
      }
    } catch (_) {
      _showSnack('설정 저장에 실패했습니다. Supabase 연결을 확인하세요.');
    } finally {
      if (mounted) {
        setState(() {
          _isSavingSettings = false;
        });
      }
    }
  }

  Future<void> _createBackup() async {
    final backupService = _backupService;
    if (backupService == null || !authProvider.isSignedIn) {
      _showSnack('로그인 후에만 백업을 만들 수 있습니다.');
      return;
    }

    setState(() {
      _isBackupActionRunning = true;
    });

    try {
      final backup = await backupService.createBackup();
      await _loadBackups();
      _showSnack('백업 완료: ${backup.totalItems}개 항목을 저장했습니다.');
    } catch (_) {
      _showSnack('백업 생성에 실패했습니다. Supabase 스키마를 확인하세요.');
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
        content: Text(
          '${_formatDateTime(backup.createdAt)} 백업을 현재 계정으로 복원할까요?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('복원'),
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
    } catch (_) {
      _showSnack('백업 복원에 실패했습니다. Supabase 권한과 스키마를 확인하세요.');
    } finally {
      if (mounted) {
        setState(() {
          _isBackupActionRunning = false;
        });
      }
    }
  }

  void _applySettings(UserSettingsModel settings) {
    _morningBriefingAt = _parseTime(settings.morningBriefingAt);
    _eveningBriefingAt = _parseTime(settings.eveningBriefingAt);
    _defaultReminderMinutes = settings.defaultReminderMin;
    _travelMode = settings.travelMode;
  }

  void _showSnack(String message) {
    if (!mounted) {
      return;
    }

    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final morningLabel = _formatTime(context, _morningBriefingAt);
    final eveningLabel = _formatTime(context, _eveningBriefingAt);
    final envConfigured =
        widget._envConfigured ?? AppEnv.openAiApiKey.isNotEmpty;

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
            _HeaderCard(
              morningLabel: morningLabel,
              eveningLabel: eveningLabel,
              isLoading: _isLoadingSettings,
            ),
            const SizedBox(height: 16),
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
              subtitle: '변경하면 바로 저장되고 오전/저녁 브리핑 스케줄에 반영됩니다.',
              child: Column(
                children: [
                  _TimeSettingTile(
                    title: '오전 브리핑',
                    subtitle: '하루를 시작하는 브리핑 시간',
                    value: morningLabel,
                    icon: Icons.wb_sunny_outlined,
                    onTap: () => _pickTime(context: context, isMorning: true),
                  ),
                  const Divider(height: 1),
                  _TimeSettingTile(
                    title: '저녁 브리핑',
                    subtitle: '하루를 마감하는 브리핑 시간',
                    value: eveningLabel,
                    icon: Icons.nightlight_outlined,
                    onTap: () => _pickTime(context: context, isMorning: false),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            _SectionCard(
              title: '이동수단',
              subtitle: '선행행동 역산 알림에서 이동시간 버퍼를 계산할 때 우선 사용할 방식을 정합니다.',
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
              title: '캘린더 연동',
              subtitle: '구글 캘린더를 연결해 외부 일정을 PlanFlow로 가져옵니다.',
              child: Column(
                children: [
                  _StatusRow(
                    label: '구글 캘린더',
                    value: _calendarStatusLabel(_calendarSyncSummary?.google),
                    icon: Icons.cloud_sync_outlined,
                    isConfigured: _isCalendarConfigured(
                      _calendarSyncSummary?.google,
                    ),
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed:
                          _isLoadingCalendarStatus || _isSyncingGoogleCalendar
                              ? null
                              : _syncGoogleCalendar,
                      icon: _isSyncingGoogleCalendar
                          ? const SizedBox.square(
                              dimension: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.sync),
                      label: Text(_googleCalendarActionLabel()),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            _DiagnosticsSection(envConfigured: envConfigured),
            const SizedBox(height: 16),
            _SectionCard(
              title: '알림 권한',
              subtitle: '일정 알림, 정확한 알람, 전체 화면 알림 권한을 확인합니다.',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _StatusRow(
                    label: '앱 알림',
                    value: _notificationStatusLabel(
                      _notificationPermissionStatus?.notificationsEnabled,
                    ),
                    icon: Icons.notifications_active_outlined,
                    isConfigured:
                        _notificationPermissionStatus?.notificationsEnabled ??
                            false,
                  ),
                  const SizedBox(height: 12),
                  _StatusRow(
                    label: '정확한 알람',
                    value: _notificationStatusLabel(
                      _notificationPermissionStatus?.exactAlarmsEnabled,
                    ),
                    icon: Icons.alarm_on_outlined,
                    isConfigured:
                        _notificationPermissionStatus?.exactAlarmsEnabled ??
                            false,
                  ),
                  const SizedBox(height: 12),
                  _StatusRow(
                    label: '전체 화면 알림',
                    value: _fullScreenStatusLabel(
                      _notificationPermissionStatus?.fullScreenIntentStatus,
                    ),
                    icon: Icons.fullscreen_outlined,
                    isConfigured:
                        _notificationPermissionStatus?.fullScreenIntentStatus ==
                            PermissionCheckState.granted,
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: _isLoadingNotificationStatus ||
                            _isRequestingNotificationPermissions
                        ? null
                        : _requestNotificationPermissions,
                    icon: _isRequestingNotificationPermissions
                        ? const SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.verified_user_outlined),
                    label: Text(
                      _isRequestingNotificationPermissions
                          ? '권한 확인 중...'
                          : '알림 권한 요청/재확인',
                    ),
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: _openNotificationSettings,
                    icon: const Icon(Icons.settings_applications_outlined),
                    label: const Text('Android 알림 설정 열기'),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '요청이 실패하거나 계속 확인 필요로 보이면 Android 앱 알림 설정에서 직접 허용해 주세요.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: PlanFlowColors.textSecondary,
                      height: 1.35,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            if (authProvider.isSignedIn && _backupService != null)
              _SectionCard(
                title: '백업 및 복원',
                subtitle: '수동 백업과 매일 새벽 3시 자동 백업 스냅샷을 관리합니다.',
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
                        IconButton.outlined(
                          tooltip: '백업 목록 새로고침',
                          onPressed: _isLoadingBackups ? null : _loadBackups,
                          icon: const Icon(Icons.refresh),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    if (_isLoadingBackups)
                      const Center(child: CircularProgressIndicator())
                    else if (_backups.isEmpty)
                      const Text('아직 저장된 백업이 없습니다.')
                    else
                      ..._backups.take(5).map(
                            (backup) => _BackupTile(
                              backup: backup,
                              onRestore: _isBackupActionRunning
                                  ? null
                                  : () => _restoreBackup(backup),
                            ),
                          ),
                  ],
                ),
              ),
            if (authProvider.isSignedIn && _backupService != null)
              const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _settingsProvider.dispose();
    super.dispose();
  }

  String _formatTime(BuildContext context, TimeOfDay timeOfDay) {
    return MaterialLocalizations.of(
      context,
    ).formatTimeOfDay(timeOfDay, alwaysUse24HourFormat: true);
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
        '구글 캘린더 다시 동기화',
      _ => '구글 캘린더 연결',
    };
  }

  String _calendarSyncSnackMessage(CalendarIntegrationResult result) {
    return result.message;
  }

  bool _isCalendarConfigured(CalendarIntegrationResult? result) {
    if (result == null) {
      return false;
    }

    return switch (result.status) {
      CalendarIntegrationStatus.signedOut ||
      CalendarIntegrationStatus.ready ||
      CalendarIntegrationStatus.syncing ||
      CalendarIntegrationStatus.synced =>
        true,
      CalendarIntegrationStatus.notConfigured ||
      CalendarIntegrationStatus.unsupported ||
      CalendarIntegrationStatus.failed =>
        false,
    };
  }

  String _notificationStatusLabel(bool? enabled) {
    if (_isLoadingNotificationStatus) {
      return '확인 중...';
    }

    if (enabled == null) {
      return '지원 안 함';
    }

    return enabled ? '허용됨' : '확인 필요';
  }

  String _fullScreenStatusLabel(PermissionCheckState? status) {
    if (_isLoadingNotificationStatus || status == null) {
      return '확인 중...';
    }

    return switch (status) {
      PermissionCheckState.granted => '허용됨',
      PermissionCheckState.denied => '확인 필요',
      PermissionCheckState.unsupported => '지원 안 함',
      PermissionCheckState.needsManualCheck => 'Android 설정에서 확인',
    };
  }

  String _notificationPermissionSnack(NotificationPermissionStatus status) {
    final notificationsAllowed = status.notificationsEnabled == true;
    final exactAllowed = status.exactAlarmsEnabled == true;
    if (notificationsAllowed && exactAllowed) {
      return status.fullScreenIntentStatus ==
              PermissionCheckState.needsManualCheck
          ? '앱 알림과 정확한 알람은 허용됨입니다. 전체 화면 알림은 Android 설정에서 확인해 주세요.'
          : '알림 권한 상태를 다시 확인했습니다.';
    }

    if (notificationsAllowed) {
      return '앱 알림은 허용됨입니다. 정확한 알람 또는 전체 화면 알림은 Android 설정에서 확인해 주세요.';
    }

    return '일부 알림 권한은 Android 앱 설정에서 허용이 필요합니다.';
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

class _HeaderCard extends StatelessWidget {
  const _HeaderCard({
    required this.morningLabel,
    required this.eveningLabel,
    required this.isLoading,
  });

  final String morningLabel;
  final String eveningLabel;
  final bool isLoading;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: PlanFlowColors.primaryMid,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '설정',
            style: theme.textTheme.labelLarge?.copyWith(
              color: const Color(0xFFA8D4F0),
              fontSize: 9,
              letterSpacing: 0.05,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            isLoading ? '설정 불러오는 중' : '변경 즉시 적용',
            style: theme.textTheme.headlineSmall?.copyWith(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _HeaderPill(
                icon: Icons.wb_sunny_outlined,
                label: '오전 $morningLabel',
              ),
              _HeaderPill(
                icon: Icons.nightlight_outlined,
                label: '저녁 $eveningLabel',
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _AccountSection extends StatelessWidget {
  const _AccountSection({required this.authService, required this.onSignedOut});

  final AuthService? authService;
  final VoidCallback onSignedOut;

  @override
  Widget build(BuildContext context) {
    return _SectionCard(
      title: '계정',
      subtitle: '로그인 상태를 먼저 확인하고 필요하면 바로 로그아웃할 수 있습니다.',
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
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: signedIn
                          ? () async {
                              await authService?.signOut();
                              onSignedOut();
                            }
                          : () => context.go(AppRoutes.login),
                      child: Text(signedIn ? '로그아웃' : '로그인'),
                    ),
                  ),
                ],
              ),
            ],
          );
        },
      ),
    );
  }
}

class _DiagnosticsSection extends StatelessWidget {
  const _DiagnosticsSection({required this.envConfigured});

  final bool envConfigured;

  @override
  Widget build(BuildContext context) {
    return Card(
      color: PlanFlowColors.surface,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: const BorderSide(color: PlanFlowColors.primaryFaint, width: 0.5),
      ),
      child: ExpansionTile(
        tilePadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
        childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        title: const Text('개발/진단 상태'),
        subtitle: const Text('일반 사용 중에는 펼치지 않아도 됩니다.'),
        children: [
          _StatusRow(
            label: 'Supabase 초기화',
            value: AppEnv.isSupabaseReady ? '설정됨' : '미설정',
            icon: Icons.code_outlined,
            isConfigured: AppEnv.isSupabaseReady,
          ),
          const SizedBox(height: 12),
          _StatusRow(
            label: 'OpenAI API 키',
            value: envConfigured ? '설정됨' : '미설정',
            icon: Icons.storage_outlined,
            isConfigured: envConfigured,
          ),
          const SizedBox(height: 12),
          _StatusRow(
            label: 'T맵 API 키',
            value: AppEnv.tmapApiKey.isNotEmpty ? '설정됨' : '미설정',
            icon: Icons.map_outlined,
            isConfigured: AppEnv.tmapApiKey.isNotEmpty,
          ),
          const SizedBox(height: 12),
          _StatusRow(
            label: '네이버 지도 API 키',
            value: AppEnv.naverMapClientId.isNotEmpty &&
                    AppEnv.naverMapClientSecret.isNotEmpty
                ? '설정됨'
                : '미설정',
            icon: Icons.alt_route_outlined,
            isConfigured: AppEnv.naverMapClientId.isNotEmpty &&
                AppEnv.naverMapClientSecret.isNotEmpty,
          ),
        ],
      ),
    );
  }
}

class _HeaderPill extends StatelessWidget {
  const _HeaderPill({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.2),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: Colors.white),
          const SizedBox(width: 6),
          Text(
            label,
            style: theme.textTheme.labelMedium?.copyWith(
              color: Colors.white,
              fontSize: 9,
            ),
          ),
        ],
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
                fontWeight: FontWeight.w500,
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
  });

  final String title;
  final String subtitle;
  final String value;
  final IconData icon;
  final VoidCallback onTap;

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
          ],
        ),
      ),
    );
  }
}

class _BackupTile extends StatelessWidget {
  const _BackupTile({required this.backup, required this.onRestore});

  final BackupSnapshot backup;
  final VoidCallback? onRestore;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final createdAt =
        '${backup.createdAt.year}-${backup.createdAt.month.toString().padLeft(2, '0')}-${backup.createdAt.day.toString().padLeft(2, '0')} '
        '${backup.createdAt.hour.toString().padLeft(2, '0')}:${backup.createdAt.minute.toString().padLeft(2, '0')}';

    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: PlanFlowColors.background,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          children: [
            const Icon(
              Icons.cloud_done_outlined,
              color: PlanFlowColors.primaryMid,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    backup.label == 'Manual backup'
                        ? '수동 백업'
                        : backup.label ?? '수동 백업',
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: PlanFlowColors.primary,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '$createdAt · ${backup.totalItems}개 항목',
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            TextButton(onPressed: onRestore, child: const Text('복원')),
          ],
        ),
      ),
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
        isConfigured ? PlanFlowColors.primaryMid : PlanFlowColors.textSecondary;

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
