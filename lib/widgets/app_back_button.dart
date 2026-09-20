import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../core/constants.dart';

/// Resolves the safest parent route for screens that may be opened directly.
///
/// A normal push keeps the existing navigation stack, so [context.canPop]
/// remains the preferred route. The fallback is only used for deep links or
/// restored routes that have no pop history.
String? resolveBackFallbackLocation(BuildContext context) {
  return resolveBackFallbackPath(GoRouterState.of(context).uri);
}

/// Pure route-path form used by navigation contract tests.
String? resolveBackFallbackPath(Uri uri) {
  final segments = uri.pathSegments;
  if (segments.isEmpty || segments.first != 'groups') {
    return AppRoutes.home;
  }

  if (segments.length >= 3 && segments[1].isNotEmpty) {
    // /groups/:groupId/<child> -> the group detail screen.
    return AppRoutes.groupDetailForId(segments[1]);
  }
  if (segments.length == 2 && segments[1].isNotEmpty) {
    // /groups/:groupId -> the group list screen.
    return AppRoutes.groups;
  }
  return AppRoutes.home;
}

/// Navigates back while remaining safe when the current route was opened by a
/// deep link and therefore has no navigator history.
void navigateBackSafely(BuildContext context, {String? fallbackLocation}) {
  if (context.canPop()) {
    context.pop();
    return;
  }

  final fallback = fallbackLocation ??
      resolveBackFallbackPath(GoRouterState.of(context).uri);
  if (fallback == null || fallback == GoRouterState.of(context).uri.path) {
    return;
  }
  context.go(fallback);
}

class AppBackButton extends StatelessWidget {
  const AppBackButton({super.key, this.fallbackLocation});

  final String? fallbackLocation;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      key: const ValueKey<String>('app-back-button'),
      tooltip: MaterialLocalizations.of(context).backButtonTooltip,
      icon: const Icon(Icons.arrow_back),
      onPressed: () => navigateBackSafely(
        context,
        fallbackLocation: fallbackLocation,
      ),
    );
  }
}
