import 'package:flutter/material.dart';

class PlanFlowColors {
  static const background = Color(0xFFEEF5FB);
  static const surface = Color(0xFFFFFFFF);
  static const surfaceFaint = Color(0xFFF5F8FB);

  static const primary = Color(0xFF1E3A5F);
  static const primaryMid = Color(0xFF2E6DA4);
  static const primaryLight = Color(0xFF7AB3D4);
  static const primaryFaint = Color(0xFFD0E4F0);

  static const tertiaryAccent = Color(0xFFD08C60);
  static const tertiaryAccentFaint = Color(0xFFFFE8DA);

  static const active = Color(0xFF1A4FD6);
  static const activeLight = Color(0xFFA8C8FF);

  static const briefing = Color(0xFF2E6DA4);
  static const briefingLabel = Color(0xFFA8D4F0);

  static const fab = Color(0xFF5D61A8);

  static const textPrimary = Color(0xFF1E3A5F);
  static const textSecondary = Color(0xFF4A6080);
  static const textDisabled = Color(0xFF7AB3D4);

  static const tagNormalBg = Color(0xFFEEF5FB);
  static const tagNormalText = Color(0xFF2E6DA4);
  static const tagActiveBg = Color(0x33FFFFFF);
  static const tagActiveText = Color(0xFFFFFFFF);
  static const tagDoneBg = Color(0xFFF5F8FB);
  static const tagDoneText = Color(0xFF7AB3D4);
}

ThemeData buildPlanFlowTheme() {
  const colorScheme = ColorScheme.light(
    primary: PlanFlowColors.primary,
    onPrimary: Colors.white,
    primaryContainer: PlanFlowColors.primaryFaint,
    onPrimaryContainer: PlanFlowColors.primary,
    secondary: PlanFlowColors.active,
    onSecondary: Colors.white,
    secondaryContainer: PlanFlowColors.activeLight,
    onSecondaryContainer: PlanFlowColors.primary,
    tertiary: PlanFlowColors.fab,
    surface: PlanFlowColors.surface,
    onSurface: PlanFlowColors.textPrimary,
    surfaceContainerHighest: PlanFlowColors.surfaceFaint,
    onSurfaceVariant: PlanFlowColors.textSecondary,
    outline: PlanFlowColors.primaryLight,
    outlineVariant: PlanFlowColors.primaryFaint,
    error: Color(0xFFB42318),
    errorContainer: Color(0xFFFFE3DD),
    onErrorContainer: Color(0xFF7A271A),
  );

  final border = OutlineInputBorder(
    borderRadius: BorderRadius.circular(10),
    borderSide: const BorderSide(
      color: PlanFlowColors.primaryFaint,
      width: 0.5,
    ),
  );

  return ThemeData(
    colorScheme: colorScheme,
    useMaterial3: true,
    scaffoldBackgroundColor: PlanFlowColors.background,
    fontFamily: 'Noto Sans KR',
    fontFamilyFallback: const ['Malgun Gothic', 'Roboto'],
    appBarTheme: const AppBarTheme(
      centerTitle: false,
      elevation: 0,
      scrolledUnderElevation: 0,
      backgroundColor: PlanFlowColors.background,
      foregroundColor: PlanFlowColors.primary,
      titleTextStyle: TextStyle(
        color: PlanFlowColors.primary,
        fontSize: 18,
        fontWeight: FontWeight.w600,
        letterSpacing: -0.2,
      ),
    ),
    cardTheme: CardThemeData(
      color: PlanFlowColors.surface,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: const BorderSide(
          color: PlanFlowColors.primaryFaint,
          width: 0.5,
        ),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: PlanFlowColors.surface,
      border: border,
      enabledBorder: border,
      focusedBorder: border.copyWith(
        borderSide: const BorderSide(
          color: PlanFlowColors.primaryMid,
          width: 1,
        ),
      ),
      errorBorder: border.copyWith(
        borderSide: const BorderSide(color: Color(0xFFB42318)),
      ),
      focusedErrorBorder: border.copyWith(
        borderSide: const BorderSide(color: Color(0xFFB42318), width: 1),
      ),
      labelStyle: const TextStyle(color: PlanFlowColors.textSecondary),
      helperStyle: const TextStyle(color: PlanFlowColors.textSecondary),
      hintStyle: const TextStyle(color: PlanFlowColors.primaryLight),
      contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 12),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: PlanFlowColors.primary,
        foregroundColor: Colors.white,
        minimumSize: const Size.fromHeight(48),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: PlanFlowColors.primary,
        side: const BorderSide(color: PlanFlowColors.primaryFaint),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: PlanFlowColors.primaryMid,
        textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
      ),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: PlanFlowColors.tagNormalBg,
      selectedColor: PlanFlowColors.primaryFaint,
      disabledColor: PlanFlowColors.surfaceFaint,
      side: BorderSide.none,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      labelStyle: const TextStyle(
        color: PlanFlowColors.tagNormalText,
        fontSize: 9,
        fontWeight: FontWeight.w600,
      ),
      secondaryLabelStyle: const TextStyle(
        color: PlanFlowColors.primary,
        fontSize: 9,
        fontWeight: FontWeight.w600,
      ),
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
    ),
    floatingActionButtonTheme: const FloatingActionButtonThemeData(
      backgroundColor: PlanFlowColors.fab,
      foregroundColor: Colors.white,
      elevation: 0,
      extendedTextStyle: TextStyle(
        color: Colors.white,
        fontSize: 13,
        fontWeight: FontWeight.w600,
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: PlanFlowColors.surface,
      indicatorColor: PlanFlowColors.primaryFaint,
      elevation: 0,
      iconTheme: WidgetStateProperty.resolveWith((states) {
        final selected = states.contains(WidgetState.selected);
        return IconThemeData(
          color:
              selected ? PlanFlowColors.primary : PlanFlowColors.textSecondary,
        );
      }),
      labelTextStyle: WidgetStateProperty.resolveWith((states) {
        final selected = states.contains(WidgetState.selected);
        return TextStyle(
          color:
              selected ? PlanFlowColors.primary : PlanFlowColors.textSecondary,
          fontSize: 11,
          fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
        );
      }),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((states) {
        return states.contains(WidgetState.selected)
            ? PlanFlowColors.active
            : PlanFlowColors.primaryLight;
      }),
      trackColor: WidgetStateProperty.resolveWith((states) {
        return states.contains(WidgetState.selected)
            ? PlanFlowColors.activeLight
            : PlanFlowColors.primaryFaint;
      }),
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: PlanFlowColors.primaryMid,
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: PlanFlowColors.primary,
      contentTextStyle: const TextStyle(color: Colors.white, fontSize: 13),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
    textTheme: const TextTheme(
      headlineSmall: TextStyle(
        fontSize: 20,
        fontWeight: FontWeight.w600,
        color: PlanFlowColors.textPrimary,
        letterSpacing: -0.3,
      ),
      titleLarge: TextStyle(
        fontSize: 18,
        fontWeight: FontWeight.w500,
        color: PlanFlowColors.textPrimary,
        letterSpacing: -0.2,
      ),
      titleMedium: TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w500,
        color: PlanFlowColors.textPrimary,
      ),
      titleSmall: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w500,
        color: PlanFlowColors.textPrimary,
      ),
      bodyLarge: TextStyle(
        fontSize: 13,
        height: 1.5,
        color: PlanFlowColors.textPrimary,
      ),
      bodyMedium: TextStyle(
        fontSize: 11,
        height: 1.5,
        color: PlanFlowColors.textSecondary,
      ),
      bodySmall: TextStyle(
        fontSize: 10,
        height: 1.45,
        color: PlanFlowColors.textSecondary,
      ),
      labelLarge: TextStyle(
        fontSize: 10,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.6,
        color: PlanFlowColors.textSecondary,
      ),
      labelMedium: TextStyle(
        fontSize: 10,
        fontWeight: FontWeight.w600,
        color: PlanFlowColors.textSecondary,
      ),
      labelSmall: TextStyle(
        fontSize: 9,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.45,
        color: PlanFlowColors.textSecondary,
      ),
    ),
  );
}
