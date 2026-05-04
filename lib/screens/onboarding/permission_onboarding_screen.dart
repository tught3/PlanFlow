import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/constants.dart';
import '../../core/theme.dart';
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

class _PermissionOnboardingScreenState
    extends State<PermissionOnboardingScreen> {
  late final AppPermissionService _permissionService;

  AppPermissionSnapshot? _snapshot;
  bool _isLoading = true;
  bool _isRequestingAll = false;
  String? _activeRequestKey;
  String? _message;

  @override
  void initState() {
    super.initState();
    _permissionService = widget._permissionService ?? AppPermissionService();
    unawaited(_refresh());
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
      await _withPermissionTimeout(
        _permissionService.requestMicrophonePermission,
      );
      await _permissionService
          .requestNotificationPermissions()
          .timeout(const Duration(seconds: 8));
      await _withPermissionTimeout(
        _permissionService.requestLocationPermission,
      );
      await _refresh();
      if (mounted) {
        setState(() {
          _message =
              '권한 요청을 마쳤습니다. 허용되지 않은 항목은 아래 상태를 확인한 뒤 Android 설정에서 다시 켤 수 있어요.';
        });
      }
    } catch (_) {
      await _refresh();
      if (mounted) {
        setState(() {
          _message =
              '일부 권한 요청이 완료되지 않았습니다. 아래 상태를 확인하고 Android 앱 설정에서 직접 켜 주세요.';
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

  Future<bool> _withPermissionTimeout(Future<bool> Function() request) {
    return request().timeout(const Duration(seconds: 8));
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

  Future<void> _completeIfReady(AppPermissionSnapshot snapshot) async {
    if (!snapshot.requiredPermissionsGranted || !mounted) {
      return;
    }
    await _complete();
  }

  Future<void> _openAppSettings() async {
    final opened = await _permissionService.openAppSettings();
    if (!opened && mounted) {
      setState(() {
        _message = 'Android 앱 설정을 열지 못했습니다. 휴대폰 설정에서 PlanFlow 권한을 확인해 주세요.';
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
                description: '음성으로 일정을 추가, 수정, 삭제하려면 필요합니다.',
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
              const SizedBox(height: 10),
              _PermissionTile(
                icon: Icons.notifications_active_outlined,
                title: '앱 알림',
                description: '일정 시작 전 알림과 브리핑 알림을 표시합니다.',
                granted: snapshot?.notificationsGranted == true,
                isRequesting: _activeRequestKey == 'notification',
                onRequest: () => _requestOne(
                  key: 'notification',
                  grantedMessage: '앱 알림 권한 상태를 다시 확인했습니다.',
                  deniedMessage:
                      '앱 알림이 아직 꺼져 있습니다. Android 알림 설정에서 PlanFlow 알림을 허용해 주세요.',
                  request: () async {
                    final status = await _permissionService
                        .requestNotificationPermissions();
                    return status.notificationsEnabled == true;
                  },
                ),
              ),
              const SizedBox(height: 10),
              _PermissionTile(
                icon: Icons.alarm_on_outlined,
                title: '정확한 알람',
                description:
                    '중요 일정 알림을 지정한 시간에 맞춰 울리기 위해 필요합니다. Android에서는 설정 화면으로 이동할 수 있습니다.',
                granted: snapshot?.exactAlarmsGranted == true,
                isRequesting: _activeRequestKey == 'exactAlarm',
                onRequest: () => _requestOne(
                  key: 'exactAlarm',
                  grantedMessage: '정확한 알람 권한 상태를 다시 확인했습니다.',
                  deniedMessage:
                      '정확한 알람 권한이 아직 꺼져 있습니다. Android 설정에서 PlanFlow의 알람 권한을 허용해 주세요.',
                  request: () async {
                    final status = await _permissionService
                        .requestNotificationPermissions();
                    return status.exactAlarmsEnabled == true;
                  },
                ),
              ),
              const SizedBox(height: 10),
              _PermissionTile(
                icon: Icons.my_location_outlined,
                title: '위치',
                description: '현재 위치를 출발지 후보로 사용해 이동시간과 출발 알림을 더 정확히 계산합니다.',
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
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: _openAppSettings,
              icon: const Icon(Icons.settings_applications_outlined),
              label: const Text('Android 앱 설정 열기'),
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
    this.isRequesting = false,
  });

  final IconData icon;
  final String title;
  final String description;
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
