import 'package:flutter/material.dart';

import '../screens/shell_screen.dart';
import '../screens/placeholder_screen.dart';
import 'constants.dart';

class AppRouter {
  static Route<dynamic> onGenerateRoute(RouteSettings settings) {
    switch (settings.name) {
      case AppRoutes.root:
      case AppRoutes.home:
        return MaterialPageRoute<void>(
          builder: (_) => const ShellScreen(initialIndex: 0),
          settings: settings,
        );
      case AppRoutes.planner:
        return MaterialPageRoute<void>(
          builder: (_) => const PlaceholderScreen(
            title: 'Planner',
            message: '일정과 할 일을 담는 화면입니다.',
          ),
          settings: settings,
        );
      case AppRoutes.settings:
        return MaterialPageRoute<void>(
          builder: (_) => const PlaceholderScreen(
            title: 'Settings',
            message: '앱 설정과 환경 정보를 담는 화면입니다.',
          ),
          settings: settings,
        );
      default:
        return MaterialPageRoute<void>(
          builder: (_) => const PlaceholderScreen(
            title: 'Not Found',
            message: '요청한 경로를 찾지 못했습니다.',
          ),
          settings: settings,
        );
    }
  }
}
