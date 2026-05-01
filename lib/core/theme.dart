import 'package:flutter/material.dart';

ThemeData buildPlanFlowTheme() {
  final colorScheme = ColorScheme.fromSeed(
    seedColor: const Color(0xFF1B5E20),
    brightness: Brightness.light,
  );

  return ThemeData(
    colorScheme: colorScheme,
    useMaterial3: true,
    scaffoldBackgroundColor: colorScheme.surface,
    appBarTheme: const AppBarTheme(centerTitle: false),
    navigationBarTheme: NavigationBarThemeData(
      indicatorColor: colorScheme.primaryContainer,
    ),
  );
}
