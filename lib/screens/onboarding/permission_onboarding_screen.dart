import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/constants.dart';
import '../../core/theme.dart';
import '../../providers/auth_provider.dart';
import '../../services/app_permission_service.dart';
import '../../services/notification_service.dart';

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

class _PermissionOnboardingScreenState
    extends State<PermissionOnboardingScreen> {
  late final AppPermissionService _permissionService;

  AppPermissionSnapshot? _snapshot;
  bool _isLoading = true;
  bool _isRequestingAll = false;
  String? _message;

  @override
  void initState() {
    super.initState();
    _permissionService = widget._permissionService ?? AppPermissionService();
    unawaited(_refresh());
  }

  Future<void> _refresh() async {
    setState(() {
      _isLoading = true;
      _message = null;
    });

    try {
      final snapshot = await _permissionService.checkAll();
      if (!mounted) {
        return;
      }
      setState(() {
        _snapshot = snapshot;
      });
    } catch (error) {
      if (mounted) {
        setState(() {
          _message = '권한 상태를 확인하지 못했습니다. 휴대폰 설정을 확인해 주세요.';
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

  Future<void> _requestAll() async {
    if (_isRequestingAll) {
      return;
    }

    setState(() {
      _isRequestingAll = true;
      _message = null;
    });

    try {
      await _permissionService.requestMicrophonePermission();
      await _permissionService.requestNotificationPermissions();
      await _permissionService.requestLocationPermission();
      await _refresh();
      if (mounted) {
        setState(() {
          _message = '권한 요청을 마쳤습니다. 허용되지 않은 항목은 휴대폰 설정에서 다시 켤 수 있어요.';
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _isRequestingAll = false;
        });
      }
    }
  }

  Future<void> _complete() async {
    final userId = authProvider.userId;
    if (userId != null && userId.isNotEmpty) {
      await _permissionService.markOnboardingCompleted(userId);
    }
    if (mounted) {
      context.go(AppRoutes.home);
    }
  }

  Future<void> _openAppSettings() async {
    final opened = await _permissionService.openAppSettings();
    if (!opened && mounted) {
      setState(() {
        _message = 'Android 앱 설정을 열지 못했습니다. 휴대폰 설정에서 PlanFlow 권한을 확인해 주세요.';
      });
    }
  }

  Future<void> _openNotificationSettings() async {
    final opened = await _permissionService.openNotificationSettings();
    if (!opened && mounted) {
      setState(() {
        _message = 'Android 알림 설정을 열지 못했습니다. 휴대폰 설정에서 PlanFlow 알림을 확인해 주세요.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = _snapshot;
    final theme = Theme.of(context);

    return Scaffold(
      backgroundColor: PlanFlowColors.background,
      appBar: AppBar(
        title: const Text('권한 설정'),
        automaticallyImplyLeading: false,
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(AppConstants.defaultPadding),
          children: [
            _IntroCard(theme: theme),
            const SizedBox(height: 16),
            if (_isLoading && snapshot == null)
              const Center(
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: CircularProgressIndicator(),
                ),
              )
            else ...[
              _PermissionTile(
                icon: Icons.mic_none,
                title: '마이크',
                description: '음성으로 일정을 입력하고 수정하려면 필요합니다.',
                granted: snapshot?.microphoneGranted == true,
                onRequest: () async {
                  await _permissionService.requestMicrophonePermission();
                  await _refresh();
                },
              ),
              const SizedBox(height: 10),
              _PermissionTile(
                icon: Icons.notifications_active_outlined,
                title: '앱 알림',
                description: '일정 시작 전 알림과 중요 알림을 표시합니다.',
                granted: snapshot?.notificationsGranted == true,
                onRequest: () async {
                  await _permissionService.requestNotificationPermissions();
                  await _refresh();
                },
              ),
              const SizedBox(height: 10),
              _PermissionTile(
                icon: Icons.alarm_on_outlined,
                title: '정확한 알람',
                description: '중요 일정 알림을 늦지 않게 예약하기 위해 필요합니다.',
                granted: snapshot?.exactAlarmsGranted == true,
                onRequest: () async {
                  await _permissionService.requestNotificationPermissions();
                  await _refresh();
                },
              ),
              const SizedBox(height: 10),
              _PermissionTile(
                icon: Icons.fullscreen_outlined,
                title: '전체 화면 알림',
                description: '중요 알림을 화면에 크게 띄울 때 Android 설정 확인이 필요할 수 있습니다.',
                granted: snapshot?.notificationStatus.fullScreenIntentStatus ==
                    PermissionCheckState.granted,
                onRequest: _openNotificationSettings,
              ),
              const SizedBox(height: 10),
              _PermissionTile(
                icon: Icons.my_location_outlined,
                title: '위치',
                description: '현재 위치를 출발지로 사용해 이동시간과 출발 알림을 더 정확하게 계산합니다.',
                granted: snapshot?.locationGranted == true,
                onRequest: () async {
                  await _permissionService.requestLocationPermission();
                  await _refresh();
                },
              ),
            ],
            if (_message != null) ...[
              const SizedBox(height: 12),
              Text(
                _message!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: PlanFlowColors.textSecondary,
                ),
              ),
            ],
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: _isRequestingAll ? null : _requestAll,
              icon: _isRequestingAll
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.verified_user_outlined),
              label: Text(_isRequestingAll ? '권한 요청 중...' : '필요 권한 모두 요청'),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: _openAppSettings,
              icon: const Icon(Icons.settings_applications_outlined),
              label: const Text('Android 앱 설정 열기'),
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: _complete,
              child: const Text('완료하고 시작하기'),
            ),
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
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'PlanFlow를 제대로 쓰기 위한 준비',
              style: theme.textTheme.titleMedium?.copyWith(
                color: PlanFlowColors.primary,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '음성 입력, 일정 알림, 현재 위치 기반 이동시간 계산에 필요한 권한만 요청합니다. '
              '백그라운드 위치 추적은 하지 않습니다.',
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

class _PermissionTile extends StatelessWidget {
  const _PermissionTile({
    required this.icon,
    required this.title,
    required this.description,
    required this.granted,
    required this.onRequest,
  });

  final IconData icon;
  final String title;
  final String description;
  final bool granted;
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
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, color: color),
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
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    description,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: PlanFlowColors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            granted
                ? const Icon(Icons.check_circle_outline,
                    color: Color(0xFF2E7D32))
                : TextButton(
                    onPressed: onRequest,
                    child: const Text('요청'),
                  ),
          ],
        ),
      ),
    );
  }
}
