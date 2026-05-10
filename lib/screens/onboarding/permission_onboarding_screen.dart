import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/constants.dart';
import '../../core/theme.dart';
import '../../data/models/user_settings_model.dart';
import '../../data/repositories/settings_repository.dart';
import '../../providers/auth_provider.dart';
import '../../services/app_permission_service.dart';

class PermissionOnboardingScreen extends StatefulWidget {
  const PermissionOnboardingScreen({
    super.key,
    AppPermissionService? permissionService,
  }) : _permissionService = permissionService;

  final AppPermissionService? _permissionService;

  @override
  State<PermissionOnboardingScreen> createState() =>
      _PermissionOnboardingScreenState();
}

class _PermissionOnboardingScreenState extends State<PermissionOnboardingScreen>
    with WidgetsBindingObserver {
  late final AppPermissionService _permissionService;

  AppPermissionSnapshot? _snapshot;
  bool _isLoading = true;
  bool _isRequestingAll = false;
  bool _resumeRequestAll = false;
  String? _activeRequestKey;
  String? _message;
  int _prepTimeMin = 30;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _permissionService = widget._permissionService ?? AppPermissionService();
    unawaited(_refresh());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed || !_resumeRequestAll) {
      return;
    }
    _resumeRequestAll = false;
    unawaited(_continueRequestAllAfterResume());
  }

  Future<void> _refresh({bool clearMessage = false}) async {
    setState(() {
      _isLoading = true;
      if (clearMessage) {
        _message = null;
      }
    });

    try {
      final snapshot = await _permissionService.checkAll();
      if (!mounted) {
        return;
      }
      setState(() {
        _snapshot = snapshot;
      });
      unawaited(_completeIfReady(snapshot));
    } catch (_) {
      if (mounted) {
        setState(() {
          _message = '권한 상태를 확인하지 못했습니다. 휴대폰 설정에서 PlanFlow 권한을 확인해 주세요.';
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _requestOne({
    required String key,
    required String grantedMessage,
    required String deniedMessage,
    required Future<bool> Function() request,
  }) async {
    if (_activeRequestKey != null || _isRequestingAll) {
      return;
    }

    setState(() {
      _activeRequestKey = key;
      _message = null;
    });

    try {
      final granted = await _withPermissionTimeout(request);
      await _refresh();

      if (!mounted) {
        return;
      }
      setState(() {
        _message = granted ? grantedMessage : deniedMessage;
      });
    } catch (_) {
      await _refresh();
      if (!mounted) {
        return;
      }
      setState(() {
        _message = '권한 요청이 완료되지 않았습니다. Android 앱 설정에서 PlanFlow 권한을 직접 확인해 주세요.';
      });
    } finally {
      if (mounted) {
        setState(() {
          _activeRequestKey = null;
        });
      }
    }
  }

  Future<void> _requestAll() async {
    if (_isRequestingAll || _activeRequestKey != null) {
      return;
    }

    setState(() {
      _isRequestingAll = true;
      _message = null;
    });

    try {
      await _requestAllSteps();
    } finally {
      if (mounted) {
        setState(() {
          _isRequestingAll = false;
        });
      }
    }
  }

  Future<void> _continueRequestAllAfterResume() async {
    if (!mounted || _isRequestingAll || _activeRequestKey != null) {
      return;
    }
    setState(() {
      _isRequestingAll = true;
      _message = '앱으로 돌아왔습니다. 남은 권한을 이어서 확인하고 요청할게요.';
    });
    try {
      await _requestAllSteps();
    } finally {
      if (mounted) {
        setState(() {
          _isRequestingAll = false;
        });
      }
    }
  }

  Future<void> _requestAllSteps() async {
    final failures = <String>[];

    await _runPermissionStep(
      key: 'microphone',
      label: '마이크',
      failures: failures,
      isGranted: (snapshot) => snapshot.microphoneGranted,
      request: _permissionService.requestMicrophonePermission,
    );
    await _runPermissionStep(
      key: 'notifications',
      label: '앱 알림',
      failures: failures,
      isGranted: (snapshot) => snapshot.notificationsGranted,
      request: () async {
        final status = await _permissionService
            .requestNotificationPermissions()
            .timeout(const Duration(seconds: 12));
        return status.notificationsEnabled == true &&
            status.exactAlarmsEnabled == true;
      },
      mayOpenSettings: true,
    );
    await _runPermissionStep(
      key: 'exactAlarm',
      label: '정확한 알람',
      failures: failures,
      isGranted: (snapshot) => snapshot.exactAlarmsGranted,
      request: _permissionService.requestExactAlarmPermission,
      mayOpenSettings: true,
    );
    await _runPermissionStep(
      key: 'location',
      label: '위치',
      failures: failures,
      isGranted: (snapshot) => snapshot.locationGranted,
      request: _permissionService.requestLocationPermission,
    );
    await _runPermissionStep(
      key: 'calendar',
      label: '기기 캘린더',
      failures: failures,
      isGranted: (snapshot) => snapshot.calendarGranted,
      request: _permissionService.requestCalendarPermission,
    );

    await _refresh();
    if (!mounted) {
      return;
    }
    final snapshot = _snapshot;
    final allGranted = snapshot?.requiredPermissionsGranted == true;
    setState(() {
      _message = allGranted
          ? '필요 권한이 모두 준비되었습니다.'
          : failures.isEmpty
              ? '권한 요청을 마쳤습니다. 허용되지 않은 항목은 아래 상태를 확인한 뒤 Android 설정에서 다시 켤 수 있어요.'
              : '일부 권한을 아직 확인하지 못했습니다: ${failures.join(', ')}. 설정 화면에서 허용 후 돌아오면 자동으로 이어서 확인합니다.';
    });
  }

  Future<void> _runPermissionStep({
    required String key,
    required String label,
    required List<String> failures,
    required bool Function(AppPermissionSnapshot snapshot) isGranted,
    required Future<bool> Function() request,
    bool mayOpenSettings = false,
  }) async {
    final before = await _safeCheckAll();
    if (before != null && isGranted(before)) {
      return;
    }

    if (mounted) {
      setState(() {
        _activeRequestKey = key;
        _message = '$label 권한을 요청하는 중입니다.';
      });
    }

    try {
      await _withPermissionTimeout(request,
          timeout: const Duration(seconds: 12));
    } catch (error) {
      debugPrint('Permission request step failed: $key $error');
      failures.add(label);
      if (mayOpenSettings) {
        _resumeRequestAll = true;
      }
    } finally {
      final after = await _safeCheckAll();
      if (mounted) {
        setState(() {
          _snapshot = after ?? _snapshot;
          _activeRequestKey = null;
        });
      }
      if (after != null && !isGranted(after) && mayOpenSettings) {
        _resumeRequestAll = true;
      }
    }
  }

  Future<AppPermissionSnapshot?> _safeCheckAll() async {
    try {
      return await _permissionService.checkAll();
    } catch (error) {
      debugPrint('Permission check skipped during all-request flow: $error');
      return null;
    }
  }

  Future<bool> _withPermissionTimeout(
    Future<bool> Function() request, {
    Duration timeout = const Duration(seconds: 8),
  }) {
    return request().timeout(timeout);
  }

  Future<void> _complete() async {
    final userId = authProvider.userId;
    if (userId != null && userId.isNotEmpty) {
      await _savePrepSetting(userId);
      await _permissionService.markOnboardingCompleted(userId);
    }
    if (mounted) {
      context.go(AppRoutes.voice);
    }
  }

  Future<void> _savePrepSetting(String userId) async {
    try {
      final repository = SettingsRepository.supabase();
      final existing = await repository.fetchSettings(userId);
      await repository.upsertSettings(
        (existing ?? UserSettingsModel.defaults(userId: userId)).copyWith(
          prepTimeMin: _prepTimeMin,
        ),
      );
    } catch (error) {
      debugPrint('Permission onboarding prep setting save skipped: $error');
    }
  }

  Future<void> _completeIfReady(AppPermissionSnapshot snapshot) async {
    if (!snapshot.requiredPermissionsGranted || !mounted) {
      return;
    }
    await _complete();
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = _snapshot;
    final theme = Theme.of(context);

    return Scaffold(
      backgroundColor: PlanFlowColors.background,
      appBar: AppBar(
        title: const Text('첫 일정 만들 준비'),
        automaticallyImplyLeading: false,
      ),
      bottomNavigationBar: SafeArea(
        minimum: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        child: FilledButton.icon(
          key: const ValueKey('permission-onboarding-request-all-button'),
          onPressed: (_isRequestingAll || _activeRequestKey != null)
              ? null
              : _requestAll,
          icon: _isRequestingAll
              ? const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.verified_user_outlined),
          label: Text(_isRequestingAll ? '권한 요청 중...' : '필요 권한 모두 요청'),
        ),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(14),
          children: [
            _IntroCard(theme: theme),
            const SizedBox(height: 12),
            if (_isLoading && snapshot == null)
              const Center(
                child: Padding(
                  padding: EdgeInsets.all(20),
                  child: CircularProgressIndicator(),
                ),
              )
            else ...[
              _PrepTimeCard(
                value: _prepTimeMin,
                onChanged: (value) {
                  setState(() {
                    _prepTimeMin = value;
                  });
                },
              ),
              const SizedBox(height: 9),
              _PermissionTile(
                icon: Icons.mic_none,
                title: '마이크',
                description: '음성 일정 입력과 수정에 필요합니다.',
                descriptionMaxLines: 1,
                granted: snapshot?.microphoneGranted == true,
                isRequesting: _activeRequestKey == 'microphone',
                onRequest: () => _requestOne(
                  key: 'microphone',
                  grantedMessage: '마이크 권한이 허용되었습니다.',
                  deniedMessage:
                      '마이크 권한이 아직 허용되지 않았습니다. 다시 요청하거나 Android 앱 설정에서 켜 주세요.',
                  request: _permissionService.requestMicrophonePermission,
                ),
              ),
              const SizedBox(height: 9),
              _PermissionTile(
                icon: Icons.notifications_active_outlined,
                title: '앱 알림',
                description: '일정 시작 전 알림과 브리핑 알림을 표시합니다.',
                descriptionMaxLines: 2,
                granted: snapshot?.notificationsGranted == true,
                isRequesting: _activeRequestKey == 'notification',
                onRequest: () => _requestOne(
                  key: 'notification',
                  grantedMessage: '앱 알림 권한 상태를 다시 확인했습니다.',
                  deniedMessage:
                      '앱 알림이 아직 꺼져 있습니다. Android 알림 설정에서 PlanFlow 알림을 허용해 주세요. 잠금화면과 겉화면 노출도 이 설정의 영향을 받습니다.',
                  request: () async {
                    final status = await _permissionService
                        .requestNotificationPermissions();
                    return status.notificationsEnabled == true;
                  },
                ),
              ),
              const SizedBox(height: 9),
              _PermissionTile(
                icon: Icons.alarm_on_outlined,
                title: '정확한 알람',
                description:
                    '중요 일정 알림을 지정한 시간에 맞춰 울리기 위해 필요합니다. Android에서는 설정 화면으로 이동할 수 있습니다.',
                descriptionMaxLines: 2,
                granted: snapshot?.exactAlarmsGranted == true,
                isRequesting: _activeRequestKey == 'exactAlarm',
                key: const ValueKey('permission-onboarding-exact-alarm-tile'),
                onRequest: () => _requestOne(
                  key: 'exactAlarm',
                  grantedMessage: '정확한 알람 권한 상태를 다시 확인했습니다.',
                  deniedMessage:
                      '정확한 알람 권한이 아직 꺼져 있습니다. Android 설정에서 PlanFlow의 알람 권한을 허용해 주세요. 중요 알람의 잠금화면 표시에도 영향을 줍니다.',
                  request: _permissionService.requestExactAlarmPermission,
                ),
              ),
              const SizedBox(height: 9),
              _PermissionTile(
                icon: Icons.my_location_outlined,
                title: '위치',
                description: '현재 위치를 출발지 후보로 사용해 이동시간과 출발 알림을 더 정확히 계산합니다.',
                descriptionMaxLines: 2,
                granted: snapshot?.locationGranted == true,
                isRequesting: _activeRequestKey == 'location',
                onRequest: () => _requestOne(
                  key: 'location',
                  grantedMessage: '위치 권한이 허용되었습니다.',
                  deniedMessage:
                      '위치 권한이 아직 허용되지 않았습니다. 다시 요청하거나 Android 앱 설정에서 켜 주세요.',
                  request: _permissionService.requestLocationPermission,
                ),
              ),
              const SizedBox(height: 9),
              _PermissionTile(
                icon: Icons.calendar_month_outlined,
                title: '기기 캘린더',
                description:
                    '네이버/삼성/구글 캘린더 앱이 휴대폰에 동기화한 일정을 PlanFlow에서 불러오기 위해 필요합니다.',
                descriptionMaxLines: 2,
                granted: snapshot?.calendarGranted == true,
                isRequesting: _activeRequestKey == 'calendar',
                onRequest: () => _requestOne(
                  key: 'calendar',
                  grantedMessage: '기기 캘린더 권한을 허용했습니다.',
                  deniedMessage:
                      '기기 캘린더 권한이 아직 허용되지 않았습니다. Android 앱 설정에서 PlanFlow 캘린더 권한을 켜 주세요.',
                  request: _permissionService.requestCalendarPermission,
                ),
              ),
            ],
            if (_message != null) ...[
              const SizedBox(height: 10),
              Text(
                _message!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: PlanFlowColors.textSecondary,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _IntroCard extends StatelessWidget {
  const _IntroCard({required this.theme});

  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 0,
      color: PlanFlowColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: const BorderSide(color: PlanFlowColors.primaryFaint, width: 0.5),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '"내일 오후 3시 강남역 미팅" — 말 한마디면 끝',
              style: theme.textTheme.titleMedium?.copyWith(
                color: PlanFlowColors.primary,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 7),
            Text(
              'AI가 날짜·시간·장소를 파악해 첫 일정을 빠르게 만들어 줍니다. '
              '아래 권한만 허용하면 바로 시작할 수 있어요.',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: PlanFlowColors.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PrepTimeCard extends StatelessWidget {
  const _PrepTimeCard({
    required this.value,
    required this.onChanged,
  });

  final int value;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      elevation: 0,
      color: PlanFlowColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: const BorderSide(color: PlanFlowColors.primaryFaint, width: 0.5),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  '평소 준비 시간',
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: PlanFlowColors.primary,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
                  decoration: BoxDecoration(
                    color: PlanFlowColors.primaryFaint,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    '선택 사항',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: PlanFlowColors.primaryMid,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              '첫 외부 일정 전에 씻고 챙기는 시간을 정해 주세요.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: PlanFlowColors.textSecondary,
              ),
            ),
            const SizedBox(height: 8),
            SegmentedButton<int>(
              showSelectedIcon: false,
              selected: <int>{value},
              segments: const <ButtonSegment<int>>[
                ButtonSegment<int>(value: 15, label: Text('15분')),
                ButtonSegment<int>(value: 30, label: Text('30분')),
                ButtonSegment<int>(value: 45, label: Text('45분')),
                ButtonSegment<int>(value: 60, label: Text('60분')),
              ],
              style: ButtonStyle(
                visualDensity: const VisualDensity(vertical: -2),
                padding: const WidgetStatePropertyAll(
                  EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                ),
                minimumSize: const WidgetStatePropertyAll(Size.fromHeight(40)),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              onSelectionChanged: (selected) => onChanged(selected.first),
            ),
          ],
        ),
      ),
    );
  }
}

class _PermissionTile extends StatelessWidget {
  const _PermissionTile({
    super.key,
    required this.icon,
    required this.title,
    required this.description,
    this.descriptionMaxLines,
    required this.granted,
    required this.onRequest,
    this.isRequesting = false,
  });

  final IconData icon;
  final String title;
  final String description;
  final int? descriptionMaxLines;
  final bool granted;
  final bool isRequesting;
  final Future<void> Function() onRequest;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = granted ? const Color(0xFF2E7D32) : PlanFlowColors.primaryMid;

    return Card(
      elevation: 0,
      color: PlanFlowColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(
          color:
              granted ? const Color(0xFF8BBF99) : PlanFlowColors.primaryFaint,
          width: 0.6,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, color: color),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: PlanFlowColors.primary,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    description,
                    maxLines: descriptionMaxLines,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: PlanFlowColors.textSecondary,
                    ),
                  ),
                ],
              ),
              ),
            const SizedBox(width: 8),
            if (granted)
              const Icon(Icons.check_circle_outline, color: Color(0xFF2E7D32))
            else if (isRequesting)
              const SizedBox.square(
                dimension: 22,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else
              TextButton(
                onPressed: onRequest,
                child: const Text('요청'),
              ),
          ],
        ),
      ),
    );
  }
}

