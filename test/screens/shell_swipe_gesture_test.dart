import 'package:flutter/material.dart';
import 'package:flutter_local_notifications_platform_interface/flutter_local_notifications_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:planflow/core/constants.dart';
import 'package:planflow/core/env.dart';
import 'package:planflow/providers/auth_provider.dart';
import 'package:planflow/screens/shell_screen.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class _StubNotificationsPlatform extends FlutterLocalNotificationsPlatform {}

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    FlutterLocalNotificationsPlatform.instance = _StubNotificationsPlatform();
    SharedPreferences.setMockInitialValues({});
    try {
      Supabase.instance;
    } catch (_) {
      await Supabase.initialize(
        url: 'https://example.com',
        anonKey: 'public-anon-key',
        authOptions: const FlutterAuthClientOptions(
          detectSessionInUri: false,
          autoRefreshToken: false,
        ),
      );
    }
    AppEnv.markSupabaseInitialized();
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    authProvider.setUser(null);
  });

  tearDown(() {
    authProvider.setUser(null);
    SharedPreferencesAsyncPlatform.instance = null;
  });

  testWidgets('center vertical drag does not switch tabs', (tester) async {
    await _pumpShell(tester);

    await tester.dragFrom(const Offset(200, 360), const Offset(0, -260));
    await tester.pumpAndSettle();

    expect(_selectedTabIndex(tester), 0);
  });

  testWidgets('center horizontal fling is ignored', (tester) async {
    await _pumpShell(tester);

    await tester.flingFrom(
      const Offset(200, 360),
      const Offset(-280, 0),
      900,
    );
    await tester.pumpAndSettle();

    expect(_selectedTabIndex(tester), 0);
  });

  testWidgets('right edge left fling switches to next tab', (tester) async {
    await _pumpShell(tester);

    await tester.flingFrom(
      const Offset(388, 360),
      const Offset(-260, 0),
      900,
    );
    await tester.pumpAndSettle();

    expect(_selectedTabIndex(tester), 1);
  });

  testWidgets('edge swipes stay clamped at first and last tabs',
      (tester) async {
    await _pumpShell(tester);

    await tester.flingFrom(
      const Offset(12, 360),
      const Offset(260, 0),
      900,
    );
    await tester.pumpAndSettle();
    expect(_selectedTabIndex(tester), 0);

    final settingsFinder = find.text('설정').last;
    await tester.tap(settingsFinder);
    await tester.pumpAndSettle();
    expect(_selectedTabIndex(tester), 2);

    await tester.flingFrom(
      const Offset(388, 360),
      const Offset(-260, 0),
      900,
    );
    await tester.pumpAndSettle();
    expect(_selectedTabIndex(tester), 2);
  });
}

Future<void> _pumpShell(WidgetTester tester) async {
  await tester.binding.setSurfaceSize(const Size(400, 800));
  addTearDown(() => tester.binding.setSurfaceSize(null));

  final router = GoRouter(
    initialLocation: AppRoutes.home,
    routes: [
      GoRoute(
        path: AppRoutes.home,
        builder: (_, __) => const ShellScreen(initialIndex: 0),
      ),
      GoRoute(
        path: AppRoutes.calendar,
        builder: (_, __) => const ShellScreen(initialIndex: 1),
      ),
      GoRoute(
        path: AppRoutes.settings,
        builder: (_, __) => const ShellScreen(initialIndex: 2),
      ),
    ],
  );
  addTearDown(router.dispose);

  await tester.pumpWidget(MaterialApp.router(routerConfig: router));
  await tester.pumpAndSettle();
}

int _selectedTabIndex(WidgetTester tester) {
  return tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex;
}
