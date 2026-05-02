import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../core/constants.dart';
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

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.initialIndex;
    _homeScrollController = ScrollController(keepScrollOffset: false);
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
