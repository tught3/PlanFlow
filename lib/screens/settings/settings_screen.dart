import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/constants.dart';
import '../../core/env.dart';
import '../../core/theme.dart';
import '../../providers/auth_provider.dart';
import '../../services/auth_service.dart';
import '../../services/backup_service.dart';
import '../../services/calendar_sync_service.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    CalendarSyncService? calendarSyncService,
    BackupService? backupService,
    AuthService? authService,
    bool? envConfigured,
  })  : _calendarSyncService = calendarSyncService,
        _backupService = backupService,
        _authService = authService,
        _envConfigured = envConfigured;

  final CalendarSyncService? _calendarSyncService;
  final BackupService? _backupService;
  final AuthService? _authService;
  final bool? _envConfigured;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  static const List<int> _reminderOptions = <int>[15, 30, 60, 120];

  TimeOfDay _morningBriefingAt = const TimeOfDay(hour: 7, minute: 30);
  TimeOfDay _eveningBriefingAt = const TimeOfDay(hour: 21, minute: 0);
  int _defaultReminderMinutes = 60;

  late final CalendarSyncService _calendarSyncService;
  BackupService? _backupService;
  AuthService? _authService;

  CalendarSyncSummary? _calendarSyncSummary;
  List<BackupSnapshot> _backups = const <BackupSnapshot>[];
  bool _isLoadingCalendarStatus = true;
  bool _isSyncingGoogleCalendar = false;
  bool _isLoadingBackups = false;
  bool _isBackupActionRunning = false;

  @override
  void initState() {
    super.initState();
    _calendarSyncService = widget._calendarSyncService ??
        CalendarSyncService(
          googleClientId: _googleCalendarClientId,
          googleServerClientId: _googleCalendarServerClientId,
        );
    if (AppEnv.isSupabaseReady) {
      _backupService = widget._backupService ?? BackupService();
      _authService = widget._authService ?? AuthService();
      _loadBackups();
    } else {
      _backupService = widget._backupService;
      _authService = widget._authService;
    }
    _loadCalendarStatus();
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
            message: 'Google Calendar sync is in progress.',
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
          data: MediaQuery.of(context).copyWith(
            alwaysUse24HourFormat: true,
          ),
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
  }

  void _resetToDefaults() {
    setState(() {
      _morningBriefingAt = const TimeOfDay(hour: 7, minute: 30);
      _eveningBriefingAt = const TimeOfDay(hour: 21, minute: 0);
      _defaultReminderMinutes = 60;
    });

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('설정을 기본값으로 되돌렸습니다.'),
      ),
    );
  }

  void _saveLocalChanges() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('현재 세션에 저장했습니다. 서버 저장은 추후 설정 저장소와 연결됩니다.'),
      ),
    );
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

  Future<void> _createBackup() async {
    final backupService = _backupService;
    if (backupService == null || !authProvider.isSignedIn) {
      _showSnack('로그인 후 백업을 만들 수 있습니다.');
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
      _showSnack('백업 생성에 실패했습니다. Supabase schema 적용 여부를 확인해주세요.');
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
          '${_formatDateTime(backup.createdAt)} 백업을 현재 계정으로 복원할까요? 같은 ID의 데이터는 백업 내용으로 갱신됩니다.',
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
      _showSnack('백업 복원에 실패했습니다. Supabase 권한과 schema를 확인해주세요.');
    } finally {
      if (mounted) {
        setState(() {
          _isBackupActionRunning = false;
        });
      }
    }
  }

  Future<void> _signOut() async {
    final authService = _authService;
    if (authService == null) {
      return;
    }
    await authService.signOut();
    if (mounted) {
      context.go(AppRoutes.login);
    }
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
    final theme = Theme.of(context);
    final morningLabel = _formatTime(context, _morningBriefingAt);
    final eveningLabel = _formatTime(context, _eveningBriefingAt);
    final envConfigured = widget._envConfigured ?? AppEnv.isConfigured;

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
              reminderMinutes: _defaultReminderMinutes,
            ),
            const SizedBox(height: 16),
            _SectionCard(
              title: '계정',
              subtitle: '로그인한 계정 기준으로 일정, 알림, 백업 데이터가 분리됩니다.',
              child: AnimatedBuilder(
                animation: authProvider,
                builder: (context, _) {
                  final signedIn = authProvider.isSignedIn;
                  return Column(
                    children: [
                      _StatusRow(
                        label: '로그인 상태',
                        value:
                            signedIn ? authProvider.email ?? '로그인됨' : '로그아웃됨',
                        icon: Icons.account_circle_outlined,
                        isConfigured: signedIn,
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton(
                              onPressed: signedIn
                                  ? _signOut
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
            ),
            const SizedBox(height: 16),
            _SectionCard(
              title: '백업 및 복원',
              subtitle: '현재 로그인한 계정의 Supabase 데이터를 하나의 snapshot으로 저장하고 복원합니다.',
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
                                  child:
                                      CircularProgressIndicator(strokeWidth: 2),
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
                  if (!authProvider.isSignedIn)
                    const Text('로그인 후 백업/복원을 사용할 수 있습니다.')
                  else if (_isLoadingBackups)
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
            const SizedBox(height: 16),
            _SectionCard(
              title: '브리핑 시간',
              subtitle: '이 기기에서 아침/저녁 브리핑을 받을 시간을 정합니다.',
              child: Column(
                children: [
                  _TimeSettingTile(
                    title: '아침 브리핑',
                    subtitle: '하루 계획을 시작하는 시간',
                    value: morningLabel,
                    icon: Icons.wb_sunny_outlined,
                    onTap: () => _pickTime(context: context, isMorning: true),
                  ),
                  const Divider(height: 1),
                  _TimeSettingTile(
                    title: '저녁 브리핑',
                    subtitle: '하루 정리와 내일 준비',
                    value: eveningLabel,
                    icon: Icons.nightlight_outlined,
                    onTap: () => _pickTime(context: context, isMorning: false),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            _SectionCard(
              title: '기본 알림 시간',
              subtitle: '새 일정에 기본으로 적용할 사전 알림 시간을 정합니다.',
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: _reminderOptions
                    .map(
                      (minutes) => FilterChip(
                        label: Text('$minutes분'),
                        selected: _defaultReminderMinutes == minutes,
                        onSelected: (_) {
                          setState(() {
                            _defaultReminderMinutes = minutes;
                          });
                        },
                      ),
                    )
                    .toList(),
              ),
            ),
            const SizedBox(height: 16),
            _SectionCard(
              title: '캘린더 연동 상태',
              subtitle: '비밀키는 표시하지 않고 설정 여부만 보여줍니다.',
              child: Column(
                children: [
                  _StatusRow(
                    label: '구글 캘린더',
                    value: _calendarStatusLabel(_calendarSyncSummary?.google),
                    icon: Icons.cloud_sync_outlined,
                    isConfigured:
                        _isCalendarConfigured(_calendarSyncSummary?.google),
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
                  const SizedBox(height: 12),
                  _StatusRow(
                    label: '네이버 캘린더',
                    value: _calendarStatusLabel(_calendarSyncSummary?.naver),
                    icon: Icons.sync_alt_outlined,
                    isConfigured:
                        _isCalendarConfigured(_calendarSyncSummary?.naver),
                  ),
                  const SizedBox(height: 12),
                  _StatusRow(
                    label: '로컬 동기화 모드',
                    value: '기기 안에서만 사용',
                    icon: Icons.device_hub_outlined,
                    isConfigured: false,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            _SectionCard(
              title: '환경값 설정 상태',
              subtitle: '필수 환경값이 들어왔는지만 확인하고 실제 값은 숨깁니다.',
              child: Column(
                children: [
                  _StatusRow(
                    label: 'Supabase 인증/데이터',
                    value: AppEnv.isSupabaseReady ? '설정됨' : '미설정',
                    icon: Icons.code_outlined,
                    isConfigured: AppEnv.isSupabaseReady,
                  ),
                  const SizedBox(height: 12),
                  _StatusRow(
                    label: 'OpenAI 일정 파싱',
                    value: envConfigured ? '설정됨' : '미설정',
                    icon: Icons.storage_outlined,
                    isConfigured: envConfigured,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Card(
              color: PlanFlowColors.surface,
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
                side: const BorderSide(
                  color: PlanFlowColors.primaryFaint,
                  width: 0.5,
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '현재 화면 저장 안내',
                      style: theme.textTheme.titleMedium?.copyWith(
                        color: PlanFlowColors.primary,
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '브리핑/알림 설정은 지금 화면에서 바로 조정할 수 있지만, 서버 저장소 연결 전까지는 앱 세션 안에서만 유지됩니다.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: PlanFlowColors.textSecondary,
                      ),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(
                            onPressed: _resetToDefaults,
                            child: const Text('초기화'),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: FilledButton(
                            onPressed: _saveLocalChanges,
                            child: const Text('이 기기에 저장'),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
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

  String _formatDateTime(DateTime value) {
    return '${value.year}-${value.month.toString().padLeft(2, '0')}-${value.day.toString().padLeft(2, '0')} '
        '${value.hour.toString().padLeft(2, '0')}:${value.minute.toString().padLeft(2, '0')}';
  }

  String _calendarStatusLabel(CalendarIntegrationResult? result) {
    if (_isLoadingCalendarStatus || result == null) {
      return '확인 중...';
    }

    return switch (result.status) {
      CalendarIntegrationStatus.notConfigured => '미설정',
      CalendarIntegrationStatus.signedOut => '설정됨, 로그인 필요',
      CalendarIntegrationStatus.ready => '사용 가능',
      CalendarIntegrationStatus.syncing => '동기화 중',
      CalendarIntegrationStatus.synced => '동기화 완료',
      CalendarIntegrationStatus.unsupported => '지원 전',
      CalendarIntegrationStatus.failed => '상태 확인 실패',
    };
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
        '동기화',
      _ => '구글 캘린더 연결',
    };
  }

  String _calendarSyncSnackMessage(CalendarIntegrationResult result) {
    return switch (result.status) {
      CalendarIntegrationStatus.notConfigured =>
        '구글 캘린더 설정이 아직 없습니다. Google Client ID 설정을 확인해 주세요.',
      CalendarIntegrationStatus.signedOut =>
        '구글 계정 로그인이 완료되지 않았습니다. 연결을 다시 시도해 주세요.',
      CalendarIntegrationStatus.failed =>
        '구글 캘린더 동기화에 실패했습니다. 네트워크와 권한을 확인해 주세요.',
      CalendarIntegrationStatus.synced when result.syncedItems > 0 =>
        '구글 캘린더 동기화가 완료되었습니다. ${result.syncedItems}개 항목을 확인했습니다.',
      CalendarIntegrationStatus.synced =>
        '구글 캘린더 연결을 확인했습니다. 가져올 새 일정은 아직 없습니다.',
      CalendarIntegrationStatus.ready => '구글 캘린더를 사용할 준비가 되었습니다.',
      CalendarIntegrationStatus.syncing => '구글 캘린더 동기화를 진행 중입니다.',
      CalendarIntegrationStatus.unsupported =>
        '현재 기기에서는 구글 캘린더 동기화를 지원하지 않습니다.',
    };
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

class _HeaderCard extends StatelessWidget {
  const _HeaderCard({
    required this.morningLabel,
    required this.eveningLabel,
    required this.reminderMinutes,
  });

  final String morningLabel;
  final String eveningLabel;
  final int reminderMinutes;

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
            '브리핑과 알림',
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
                label: '아침 $morningLabel',
              ),
              _HeaderPill(
                icon: Icons.nightlight_outlined,
                label: '저녁 $eveningLabel',
              ),
              _HeaderPill(
                icon: Icons.notifications_none,
                label: '$reminderMinutes분 전 알림',
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _HeaderPill extends StatelessWidget {
  const _HeaderPill({
    required this.icon,
    required this.label,
  });

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
        side: const BorderSide(
          color: PlanFlowColors.primaryFaint,
          width: 0.5,
        ),
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
              child: Icon(
                icon,
                color: PlanFlowColors.primaryMid,
              ),
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
  const _BackupTile({
    required this.backup,
    required this.onRestore,
  });

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
            const Icon(Icons.cloud_done_outlined,
                color: PlanFlowColors.primaryMid),
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
            TextButton(
              onPressed: onRestore,
              child: const Text('복원'),
            ),
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
