import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../features/plans/screens/plan_detail_screen.dart';
import '../../providers/auth_provider.dart';
import '../../screens/auth/login_screen.dart';
import '../../screens/home/home_screen.dart';
import '../../screens/splash/splash_screen.dart';
import '../constants.dart';
import '../env.dart';

/// 전역 싱글톤 [AuthProvider]를 Riverpod [ChangeNotifierProvider]로 래핑한다.
///
/// 이 provider를 watch하면 auth 상태 변화(notifyListeners)를 감지하여
/// 의존 위젯/provider가 자동으로 갱신된다.
final authNotifierProvider = ChangeNotifierProvider<AuthProvider>((ref) {
  return authProvider;
});

/// 인증 여부를 [bool]으로 파생시키는 provider.
///
/// 보호 라우트 UI나 가드 조건에서 `ref.watch(isAuthenticatedProvider)`로
/// 반응형 소비가 가능하다.
final isAuthenticatedProvider = Provider<bool>((ref) {
  final auth = ref.watch(authNotifierProvider);
  return auth.isSignedIn;
});

/// GoRouter의 redirect 재평가를 트리거하는 [ChangeNotifier].
///
/// [AuthProvider]가 `notifyListeners()`를 호출하면 여기로 전파되어
/// GoRouter의 `refreshListenable` 콜백이 실행된다.
class RouterRefreshNotifier extends ChangeNotifier {
  /// 라우터 redirect를 재실행하도록 알린다.
  void notify() => notifyListeners();
}

/// 앱 전역 [GoRouter]를 Riverpod [Provider]로 노출한다.
///
/// [AuthProvider] 상태가 변하면 [RouterRefreshNotifier]가
/// `refreshListenable`을 통해 redirect 콜백을 재평가하여,
/// 미인증 시 `/login`, 인증 시 `/home`으로 자동 리다이렉트한다.
///
/// 사용법:
/// ```dart
/// ConsumerWidget 내부에서:
/// final router = ref.watch(goRouterProvider);
/// return MaterialApp.router(routerConfig: router);
/// ```
final goRouterProvider = Provider<GoRouter>((ref) {
  final refreshNotifier = RouterRefreshNotifier();

  // authProvider ChangeNotifier 구독 → 라우터 새로고침 트리거.
  // Riverpod provider가 dispose될 때 리스너도 함께 정리된다.
  void onAuthChange() => refreshNotifier.notify();
  authProvider.addListener(onAuthChange);
  ref.onDispose(authProvider.removeListener.bind(onAuthChange));

  return GoRouter(
    initialLocation: AppRoutes.root,
    debugLogDiagnostics: kDebugMode,
    refreshListenable: refreshNotifier,
    redirect: (context, state) => authGuardRedirect(state),
    routes: <RouteBase>[
      GoRoute(
        path: AppRoutes.root,
        name: 'splash',
        builder: (context, state) => const SplashScreen(),
      ),
      GoRoute(
        path: AppRoutes.login,
        name: 'login',
        builder: (context, state) => const LoginScreen(),
      ),
      GoRoute(
        path: AppRoutes.home,
        name: 'home',
        builder: (context, state) => const HomeScreen(),
      ),
      GoRoute(
        path: AppRoutes.planDetail,
        name: 'planDetail',
        builder: (context, state) {
          final planId = state.pathParameters['id'] ?? '';
          return PlanDetailScreen(planId: planId);
        },
      ),
    ],
  );
});

/// 인증 가드 redirect 로직.
///
/// 평가 순서 및 의도:
/// 1. **Supabase 미설정**: 모든 라우트를 `/login`으로 보낸다(개발/테스트 환경 대응).
/// 2. **스플래시(`/`)**: 초기 세션 확인 전이면 스플래시에 머문다.
///    확인 완료 후 인증 상태에 따라 `/home` 또는 `/login`으로 분기한다.
/// 3. **미인증 + 보호 라우트**: `/login`으로 리다이렉트한다.
///    `/login` 자체는 예외(로그인 페이지는 미인증 사용자도 접근 가능).
/// 4. **인증 + `/login`**: 이미 로그인된 사용자는 `/home`으로 이동한다.
/// 5. 그 외: 현재 경로를 유지(null 반환).
///
/// redirect는 동기적으로 평가되므로 `authProvider.isSignedIn` 등
/// 동기 getter만 참조한다.
String? authGuardRedirect(GoRouterState state) {
  final auth = authProvider;
  final path = state.uri.path;
  final isSignedIn = auth.isSignedIn;
  final isLoginRoute = path == AppRoutes.login;
  final isSplashRoute = path == AppRoutes.root;

  // 1. Supabase가 설정되지 않은 경우: 로그인 화면으로 강제 이동.
  if (!AppEnv.isSupabaseReady) {
    return isLoginRoute ? null : AppRoutes.login;
  }

  // 2. 스플래시: 초기 세션 확인 전에는 대기(빈 화면 플리커 방지).
  if (isSplashRoute) {
    if (!auth.hasResolvedInitialSession) {
      return null; // 스플래시 유지
    }
    return isSignedIn ? AppRoutes.home : AppRoutes.login;
  }

  // 3. 미인증 사용자가 보호 라우트에 접근 → 로그인으로.
  if (!isSignedIn && !isLoginRoute) {
    return AppRoutes.login;
  }

  // 4. 인증된 사용자가 로그인 페이지 접근 → 홈으로.
  if (isSignedIn && isLoginRoute) {
    return AppRoutes.home;
  }

  // 5. 그 외: 현재 경로 유지.
  return null;
}
