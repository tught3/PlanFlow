import 'package:flutter/material.dart';

class PlanFlowColors {
  static const background = Color(0xFFEEF5FB);
  static const surface = Color(0xFFFFFFFF);
  static const surfaceFaint = Color(0xFFF5F8FB);

  static const primary = Color(0xFF1E3A5F);
  static const primaryMid = Color(0xFF2E6DA4);
  static const primaryLight = Color(0xFF7AB3D4);
  static const primaryFaint = Color(0xFFD0E4F0);

  static const tertiaryAccent = Color(0xFF2D5CA8);
  static const tertiaryAccentFaint = Color(0xFFE7EEF9);

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

/// 다크 모드용 색상 팔레트. 라이트 모드의 시각적 위계(Primary 중심 차분한 파랑)를
/// 어두운 배경에서도 유지하되 가독성을 위해 채도/명도를 조정했다.
/// 기존 `PlanFlowColors.*` 정적 참조는 라이트 테마 전용으로 남겨두고, 다크 모드는
/// `context.planflowColorScheme` 접근자로 분기한다.
class PlanFlowDarkColors {
  const PlanFlowDarkColors._();

  static const background = Color(0xFF0F1724);
  static const surface = Color(0xFF1A2436);
  static const surfaceFaint = Color(0xFF22304A);

  static const primary = Color(0xFF7AB3D4);
  static const primaryMid = Color(0xFF9CC5E0);
  static const primaryLight = Color(0xFF5A8AB0);
  static const primaryFaint = Color(0xFF2A3B57);

  static const tertiaryAccent = Color(0xFF8FB0E0);
  static const tertiaryAccentFaint = Color(0xFF22304A);

  static const active = Color(0xFFA8C8FF);
  static const activeLight = Color(0xFF2A3B57);

  static const briefing = Color(0xFF7AB3D4);
  static const briefingLabel = Color(0xFF3A5470);

  static const fab = Color(0xFF8E92D0);

  static const textPrimary = Color(0xFFE6EEF8);
  static const textSecondary = Color(0xFFB0BCD0);
  static const textDisabled = Color(0xFF6A7A90);

  static const tagNormalBg = Color(0xFF22304A);
  static const tagNormalText = Color(0xFF9CC5E0);
  static const tagActiveBg = Color(0x33FFFFFF);
  static const tagActiveText = Color(0xFFFFFFFF);
  static const tagDoneBg = Color(0xFF22304A);
  static const tagDoneText = Color(0xFF6A7A90);
}

/// brightness에 따라 라이트/다크 색상을 자동 분기하는 런타임 팔레트.
/// 화면 위젯에서 하드코딩된 정적 색상을 대체할 때 사용한다.
class PlanFlowColorTokens {
  const PlanFlowColorTokens({
    required this.brightness,
    required this.background,
    required this.surface,
    required this.surfaceFaint,
    required this.primary,
    required this.primaryMid,
    required this.primaryLight,
    required this.primaryFaint,
    required this.active,
    required this.activeLight,
    required this.fab,
    required this.textPrimary,
    required this.textSecondary,
    required this.textDisabled,
    required this.tagNormalBg,
    required this.tagNormalText,
    required this.tagDoneBg,
    required this.tagDoneText,
  });

  factory PlanFlowColorTokens.forBrightness(Brightness brightness) {
    return brightness == Brightness.dark
        ? const PlanFlowColorTokens._dark()
        : const PlanFlowColorTokens._light();
  }

  const PlanFlowColorTokens._({
    required this.brightness,
    required this.background,
    required this.surface,
    required this.surfaceFaint,
    required this.primary,
    required this.primaryMid,
    required this.primaryLight,
    required this.primaryFaint,
    required this.active,
    required this.activeLight,
    required this.fab,
    required this.textPrimary,
    required this.textSecondary,
    required this.textDisabled,
    required this.tagNormalBg,
    required this.tagNormalText,
    required this.tagDoneBg,
    required this.tagDoneText,
  });

  const PlanFlowColorTokens._light()
      : this._(
          brightness: Brightness.light,
          background: PlanFlowColors.background,
          surface: PlanFlowColors.surface,
          surfaceFaint: PlanFlowColors.surfaceFaint,
          primary: PlanFlowColors.primary,
          primaryMid: PlanFlowColors.primaryMid,
          primaryLight: PlanFlowColors.primaryLight,
          primaryFaint: PlanFlowColors.primaryFaint,
          active: PlanFlowColors.active,
          activeLight: PlanFlowColors.activeLight,
          fab: PlanFlowColors.fab,
          textPrimary: PlanFlowColors.textPrimary,
          textSecondary: PlanFlowColors.textSecondary,
          textDisabled: PlanFlowColors.textDisabled,
          tagNormalBg: PlanFlowColors.tagNormalBg,
          tagNormalText: PlanFlowColors.tagNormalText,
          tagDoneBg: PlanFlowColors.tagDoneBg,
          tagDoneText: PlanFlowColors.tagDoneText,
        );

  const PlanFlowColorTokens._dark()
      : this._(
          brightness: Brightness.dark,
          background: PlanFlowDarkColors.background,
          surface: PlanFlowDarkColors.surface,
          surfaceFaint: PlanFlowDarkColors.surfaceFaint,
          primary: PlanFlowDarkColors.primary,
          primaryMid: PlanFlowDarkColors.primaryMid,
          primaryLight: PlanFlowDarkColors.primaryLight,
          primaryFaint: PlanFlowDarkColors.primaryFaint,
          active: PlanFlowDarkColors.active,
          activeLight: PlanFlowDarkColors.activeLight,
          fab: PlanFlowDarkColors.fab,
          textPrimary: PlanFlowDarkColors.textPrimary,
          textSecondary: PlanFlowDarkColors.textSecondary,
          textDisabled: PlanFlowDarkColors.textDisabled,
          tagNormalBg: PlanFlowDarkColors.tagNormalBg,
          tagNormalText: PlanFlowDarkColors.tagNormalText,
          tagDoneBg: PlanFlowDarkColors.tagDoneBg,
          tagDoneText: PlanFlowDarkColors.tagDoneText,
        );

  final Brightness brightness;
  final Color background;
  final Color surface;
  final Color surfaceFaint;
  final Color primary;
  final Color primaryMid;
  final Color primaryLight;
  final Color primaryFaint;
  final Color active;
  final Color activeLight;
  final Color fab;
  final Color textPrimary;
  final Color textSecondary;
  final Color textDisabled;
  final Color tagNormalBg;
  final Color tagNormalText;
  final Color tagDoneBg;
  final Color tagDoneText;

  bool get isDark => brightness == Brightness.dark;
}

extension PlanFlowColorContext on BuildContext {
  /// 현재 brightness에 맞춘 색상 토큰을 반환한다.
  PlanFlowColorTokens get planflowColors =>
      PlanFlowColorTokens.forBrightness(Theme.of(this).brightness);
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
      // 화면 가운데 아래 위치 (기본 최하단 → 중앙 아래)
      insetPadding: EdgeInsets.fromLTRB(24, 0, 24, 80),
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

/// 다크 모드용 ThemeData. 라이트 테마와 구조를 맞추되 ColorScheme·배경·카드
/// 보더 등을 어두운 톤으로 교체했다. 시스템 다크 모드 진입 시 자동 적용된다.
ThemeData buildPlanFlowDarkTheme() {
  const colorScheme = ColorScheme.dark(
    primary: PlanFlowDarkColors.primary,
    onPrimary: Color(0xFF0F1724),
    primaryContainer: PlanFlowDarkColors.primaryFaint,
    onPrimaryContainer: PlanFlowDarkColors.primary,
    secondary: PlanFlowDarkColors.active,
    onSecondary: Color(0xFF0F1724),
    secondaryContainer: PlanFlowDarkColors.activeLight,
    onSecondaryContainer: PlanFlowDarkColors.primary,
    tertiary: PlanFlowDarkColors.fab,
    surface: PlanFlowDarkColors.surface,
    onSurface: PlanFlowDarkColors.textPrimary,
    surfaceContainerHighest: PlanFlowDarkColors.surfaceFaint,
    onSurfaceVariant: PlanFlowDarkColors.textSecondary,
    outline: PlanFlowDarkColors.primaryLight,
    outlineVariant: PlanFlowDarkColors.primaryFaint,
    error: Color(0xFFFFB4AB),
    errorContainer: Color(0xFF5C1A14),
    onErrorContainer: Color(0xFFFFDAD6),
  );

  final border = OutlineInputBorder(
    borderRadius: BorderRadius.circular(10),
    borderSide: const BorderSide(
      color: PlanFlowDarkColors.primaryFaint,
      width: 0.5,
    ),
  );

  return ThemeData(
    colorScheme: colorScheme,
    useMaterial3: true,
    scaffoldBackgroundColor: PlanFlowDarkColors.background,
    fontFamily: 'Noto Sans KR',
    fontFamilyFallback: const ['Malgun Gothic', 'Roboto'],
    appBarTheme: const AppBarTheme(
      centerTitle: false,
      elevation: 0,
      scrolledUnderElevation: 0,
      backgroundColor: PlanFlowDarkColors.background,
      foregroundColor: PlanFlowDarkColors.primary,
      titleTextStyle: TextStyle(
        color: PlanFlowDarkColors.primary,
        fontSize: 18,
        fontWeight: FontWeight.w600,
        letterSpacing: -0.2,
      ),
    ),
    cardTheme: CardThemeData(
      color: PlanFlowDarkColors.surface,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: const BorderSide(
          color: PlanFlowDarkColors.primaryFaint,
          width: 0.5,
        ),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: PlanFlowDarkColors.surface,
      border: border,
      enabledBorder: border,
      focusedBorder: border.copyWith(
        borderSide: const BorderSide(
          color: PlanFlowDarkColors.primaryMid,
          width: 1,
        ),
      ),
      errorBorder: border.copyWith(
        borderSide: const BorderSide(color: Color(0xFFFFB4AB)),
      ),
      focusedErrorBorder: border.copyWith(
        borderSide: const BorderSide(color: Color(0xFFFFB4AB), width: 1),
      ),
      labelStyle: const TextStyle(color: PlanFlowDarkColors.textSecondary),
      helperStyle: const TextStyle(color: PlanFlowDarkColors.textSecondary),
      hintStyle: const TextStyle(color: PlanFlowDarkColors.primaryLight),
      contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 12),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: PlanFlowDarkColors.primary,
        foregroundColor: const Color(0xFF0F1724),
        minimumSize: const Size.fromHeight(48),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: PlanFlowDarkColors.primary,
        side: const BorderSide(color: PlanFlowDarkColors.primaryFaint),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: PlanFlowDarkColors.primaryMid,
        textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
      ),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: PlanFlowDarkColors.tagNormalBg,
      selectedColor: PlanFlowDarkColors.primaryFaint,
      disabledColor: PlanFlowDarkColors.surfaceFaint,
      side: BorderSide.none,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      labelStyle: const TextStyle(
        color: PlanFlowDarkColors.tagNormalText,
        fontSize: 9,
        fontWeight: FontWeight.w600,
      ),
      secondaryLabelStyle: const TextStyle(
        color: PlanFlowDarkColors.primary,
        fontSize: 9,
        fontWeight: FontWeight.w600,
      ),
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
    ),
    floatingActionButtonTheme: const FloatingActionButtonThemeData(
      backgroundColor: PlanFlowDarkColors.fab,
      foregroundColor: Color(0xFF0F1724),
      elevation: 0,
      extendedTextStyle: TextStyle(
        color: Color(0xFF0F1724),
        fontSize: 13,
        fontWeight: FontWeight.w600,
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: PlanFlowDarkColors.surface,
      indicatorColor: PlanFlowDarkColors.primaryFaint,
      elevation: 0,
      iconTheme: WidgetStateProperty.resolveWith((states) {
        final selected = states.contains(WidgetState.selected);
        return IconThemeData(
          color: selected
              ? PlanFlowDarkColors.primary
              : PlanFlowDarkColors.textSecondary,
        );
      }),
      labelTextStyle: WidgetStateProperty.resolveWith((states) {
        final selected = states.contains(WidgetState.selected);
        return TextStyle(
          color: selected
              ? PlanFlowDarkColors.primary
              : PlanFlowDarkColors.textSecondary,
          fontSize: 11,
          fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
        );
      }),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((states) {
        return states.contains(WidgetState.selected)
            ? PlanFlowDarkColors.active
            : PlanFlowDarkColors.primaryLight;
      }),
      trackColor: WidgetStateProperty.resolveWith((states) {
        return states.contains(WidgetState.selected)
            ? PlanFlowDarkColors.activeLight
            : PlanFlowDarkColors.primaryFaint;
      }),
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: PlanFlowDarkColors.primaryMid,
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: PlanFlowDarkColors.surface,
      contentTextStyle: const TextStyle(
        color: PlanFlowDarkColors.textPrimary,
        fontSize: 13,
      ),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      insetPadding: EdgeInsets.fromLTRB(24, 0, 24, 80),
    ),
    textTheme: const TextTheme(
      headlineSmall: TextStyle(
        fontSize: 20,
        fontWeight: FontWeight.w600,
        color: PlanFlowDarkColors.textPrimary,
        letterSpacing: -0.3,
      ),
      titleLarge: TextStyle(
        fontSize: 18,
        fontWeight: FontWeight.w500,
        color: PlanFlowDarkColors.textPrimary,
        letterSpacing: -0.2,
      ),
      titleMedium: TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w500,
        color: PlanFlowDarkColors.textPrimary,
      ),
      titleSmall: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w500,
        color: PlanFlowDarkColors.textPrimary,
      ),
      bodyLarge: TextStyle(
        fontSize: 13,
        height: 1.5,
        color: PlanFlowDarkColors.textPrimary,
      ),
      bodyMedium: TextStyle(
        fontSize: 11,
        height: 1.5,
        color: PlanFlowDarkColors.textSecondary,
      ),
      bodySmall: TextStyle(
        fontSize: 10,
        height: 1.45,
        color: PlanFlowDarkColors.textSecondary,
      ),
      labelLarge: TextStyle(
        fontSize: 10,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.6,
        color: PlanFlowDarkColors.textSecondary,
      ),
      labelMedium: TextStyle(
        fontSize: 10,
        fontWeight: FontWeight.w600,
        color: PlanFlowDarkColors.textSecondary,
      ),
      labelSmall: TextStyle(
        fontSize: 9,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.45,
        color: PlanFlowDarkColors.textSecondary,
      ),
    ),
  );
}
