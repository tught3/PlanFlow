import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../core/constants.dart';
import '../providers/auth_provider.dart';
import '../services/app_permission_service.dart';
import '../services/auth_service.dart';
import '../services/naver_calendar_permission_service.dart';
import 'calendar/calendar_screen.dart';
import 'home_screen.dart';
import 'settings/settings_screen.dart';

class ShellScreen extends StatefulWidget {
  const ShellScreen({super.key, this.initialIndex = 0});

  final int initialIndex;

  @override
  State<ShellScreen> createState() => _ShellScreenState();
}

class _ShellScreenState extends State<ShellScreen> {
  late int _currentIndex;
  late final ScrollController _homeScrollController;
  final AppPermissionService _permissionService = AppPermissionService();
  final NaverCalendarPermissionService _naverCalendarPermissionService =
      NaverCalendarPermissionService();
  final AuthService _authService = AuthService();
  bool _checkedPermissionOnboarding = false;
  bool _checkedNaverCalendarPermission = false;
  bool _showedNaverCalendarDialog = false;

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.initialIndex;
    _homeScrollController = ScrollController(keepScrollOffset: false);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _maybeOpenPermissionOnboarding();
    });
  }

  @override
  void dispose() {
    _homeScrollController.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant ShellScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initialIndex != widget.initialIndex &&
        _currentIndex != widget.initialIndex) {
      setState(() {
        _currentIndex = widget.initialIndex;
      });
    }
  }

  void _showHomeAtTop() {
    if (!_homeScrollController.hasClients) {
      return;
    }

    _homeScrollController.jumpTo(0);
  }

  Future<void> _maybeOpenPermissionOnboarding() async {
    if (_checkedPermissionOnboarding || !mounted) {
      return;
    }
    _checkedPermissionOnboarding = true;

    final userId = authProvider.userId;
    if (userId == null || userId.isEmpty) {
      return;
    }

    final completed = await _permissionService.isOnboardingCompleted(userId);
    if (!mounted) {
      return;
    }

    if (!completed) {
      final snapshot = await _permissionService.checkAll();
      if (!mounted) {
        return;
      }
      if (snapshot.requiredPermissionsGranted) {
        await _permissionService.markOnboardingCompleted(userId);
      } else {
        await context.push(AppRoutes.permissionOnboarding);
      }
    }

    if (mounted) {
      await _maybeCheckNaverCalendarPermission();
    }
  }

  Future<void> _maybeCheckNaverCalendarPermission() async {
    if (_checkedNaverCalendarPermission ||
        !mounted ||
        !_naverCalendarPermissionService.isNaverSignedIn()) {
      return;
    }
    _checkedNaverCalendarPermission = true;

    final result = await _naverCalendarPermissionService.refreshStatus();
    if (!mounted) {
      return;
    }

    switch (result.status) {
      case NaverCalendarPermissionStatus.granted:
        return;
      case NaverCalendarPermissionStatus.denied:
        await _showNaverCalendarPermissionRequiredDialog(result.message);
        return;
      case NaverCalendarPermissionStatus.networkError:
        _logNaverCalendarStatus(
          result,
          fallback: '네이버 캘린더 연결 확인 중 일시적인 문제가 발생했습니다.',
        );
        return;
      case NaverCalendarPermissionStatus.unknown:
        if (result.message.contains('토큰')) {
          await _showNaverCalendarPermissionRequiredDialog(
            '네이버 캘린더 연결을 완료하려면 네이버 권한 동의가 한 번 더 필요합니다.',
          );
          return;
        }
        _logNaverCalendarStatus(result);
        return;
    }
  }

  Future<void> _showNaverCalendarPermissionRequiredDialog(
    String reason,
  ) async {
    if (_showedNaverCalendarDialog || !mounted) {
      return;
    }
    _showedNaverCalendarDialog = true;

    final reconnect = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('네이버 캘린더 연결이 필요합니다'),
          content: Text(
            '$reason\n\n'
            '네이버 로그인 동의 화면에서 선택 권한인 “캘린더 일정담기”를 체크해야 '
            'PlanFlow 일정을 네이버 캘린더에 담을 수 있습니다.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('나중에 하기'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('네이버 권한 다시 동의하기'),
            ),
          ],
        );
      },
    );

    if (reconnect == true) {
      await _naverCalendarPermissionService.clearStatus();
      if (!mounted) {
        return;
      }
      _showSnack('네이버 동의 화면에서 “캘린더 일정담기”를 체크해 주세요.');
      await _authService.signInWithOAuth(PlanFlowOAuthProvider.naver);
    }
  }

  void _showSnack(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  void _logNaverCalendarStatus(
    NaverCalendarPermissionResult result, {
    String? fallback,
  }) {
    debugPrint(
      'Naver calendar connection skipped: status=${result.status.name} '
      'message=${fallback ?? result.message}',
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) {
          return;
        }
        if (_currentIndex != 0) {
          setState(() {
            _currentIndex = 0;
          });
          context.go(AppRoutes.home);
          return;
        }
        SystemNavigator.pop();
      },
      child: Scaffold(
        body: IndexedStack(
          index: _currentIndex,
          children: [
            HomeScreen(scrollController: _homeScrollController),
            const CalendarScreen(),
            const SettingsScreen(),
          ],
        ),
        bottomNavigationBar: NavigationBar(
          selectedIndex: _currentIndex,
          onDestinationSelected: (index) {
            setState(() {
              _currentIndex = index;
            });
            switch (index) {
              case 0:
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (mounted) {
                    _showHomeAtTop();
                  }
                });
                context.go(AppRoutes.home);
                break;
              case 1:
                context.go(AppRoutes.calendar);
                break;
              case 2:
                context.go(AppRoutes.settings);
                break;
            }
          },
          destinations: const [
            NavigationDestination(
              icon: Icon(Icons.home_outlined),
              selectedIcon: Icon(Icons.home),
              label: '홈',
            ),
            NavigationDestination(
              icon: Icon(Icons.event_note_outlined),
              selectedIcon: Icon(Icons.event_note),
              label: '일정',
            ),
            NavigationDestination(
              icon: Icon(Icons.settings_outlined),
              selectedIcon: Icon(Icons.settings),
              label: '설정',
            ),
          ],
        ),
      ),
    );
  }
}
