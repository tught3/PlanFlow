import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/theme.dart';

/// PlanFlow 전용 모달/다이얼로그/바텀시트 액션 버튼바
///
/// **규칙:**
/// - 항상 가로(Row) 정렬 우선, 세로(Column) 스택 금지
/// - 버튼 너비는 라벨 글자 길이에 맞춰 계산한다 — 글자가 잘리거나 안 보이게
///   찌그러뜨리지 않는다.
/// - 한 줄에 모든 버튼의 자연 너비 합이 안 들어가면(글자가 길어 줄바꿈이
///   필요하면) 그때만 2줄로 나눈다.
/// - 남는 공간이 있으면 버튼들에 동일 비율로 분배해 가로를 꽉 채운다.
/// - 모든 버튼에 테두리 필수 (취소/보조 버튼 포함)
/// - 테마 토큰 강제 적용 (Material default 금지)
///
/// 기본 2버튼 패턴(취소/확인)이 대부분이며, 필요시 3버튼 이상도 지원.
class PlanFlowActionButtons extends StatelessWidget {
  const PlanFlowActionButtons({
    super.key,
    required this.buttons,
    this.spacing = 8.0,
    this.runSpacing = 8.0,
    this.alignment = WrapAlignment.end,
  });

  /// 버튼 목록. 왼쪽부터 오른쪽 순서로 배치.
  /// 예: `[취소버튼, 확인버튼]`
  final List<PlanFlowActionButton> buttons;

  /// 버튼 간 가로 간격
  final double spacing;

  /// 2줄로 나뉠 때 세로 간격
  final double runSpacing;

  /// 더 이상 레이아웃에 쓰이지 않음(하위 호환용으로만 유지).
  final WrapAlignment alignment;

  static const double _minButtonWidth = 88.0;
  // 버튼 내부 좌우 padding(OutlinedButton/FilledButton 기본치) 추정 여유값.
  // 실측보다 넉넉히 잡아야 글자가 눌려서 안 보이는 사고가 재발하지 않는다.
  static const double _buttonHorizontalPadding = 48.0;
  // 다이얼로그/바텀시트가 흔히 먹는 좌우 여백(insetPadding+contentPadding
  // 등)의 보수적 추정치. "한 줄에 다 들어가는지" 판단에만 쓰이며, 실제
  // 버튼 폭은 Expanded가 레이아웃 시점의 진짜 폭으로 계산하므로 이 값이
  // 다소 부정확해도 버튼이 잘리거나 넘치지 않는다.
  static const double _estimatedChromeWidth = 120.0;

  double _naturalWidth(BuildContext context, PlanFlowActionButton btn) {
    final painter = TextPainter(
      text: TextSpan(
        text: btn.label,
        style: TextStyle(fontSize: btn.fontSize, fontWeight: FontWeight.w600),
      ),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
    )..layout();
    final borderAllowance = btn.borderWidth * 2;
    return math.max(
      painter.width + _buttonHorizontalPadding + borderAllowance,
      _minButtonWidth,
    );
  }

  // 각 버튼에 자연 너비에 비례한 flex를 줘서 Row(Expanded)로 배치한다.
  // LayoutBuilder는 AlertDialog의 actions(OverflowBar)가 요구하는 intrinsic
  // 폭 계산과 충돌해 "LayoutBuilder does not support returning intrinsic
  // dimensions"로 크래시하므로 쓰지 않는다. Expanded/Row는 intrinsic 계산을
  // 정상 지원하고, 실제 레이아웃 시점의 진짜 폭을 비율대로 나눠 쓰므로
  // 남는 공간이 있으면 균등 확장되고, 폭이 모자라면 비율을 유지한 채
  // 축소된다(특정 버튼만 짓눌려 텍스트가 사라지는 사고를 원천 차단).
  Widget _buildRow(
    BuildContext context,
    List<PlanFlowActionButton> rowButtons,
    List<double> naturalWidths,
  ) {
    final children = <Widget>[];
    for (var i = 0; i < rowButtons.length; i += 1) {
      if (i > 0) {
        children.add(SizedBox(width: spacing));
      }
      final flexValue = math.max(naturalWidths[i].round(), 1);
      children.add(
        Expanded(flex: flexValue, child: rowButtons[i].build(context)),
      );
    }
    return Row(children: children);
  }

  @override
  Widget build(BuildContext context) {
    if (buttons.isEmpty) {
      return const SizedBox.shrink();
    }

    final naturalWidths =
        buttons.map((btn) => _naturalWidth(context, btn)).toList(growable: false);
    final singleRowTotal = naturalWidths.fold<double>(0, (a, b) => a + b) +
        spacing * (buttons.length - 1);
    final estimatedMaxWidth = math.max(
      MediaQuery.sizeOf(context).width - _estimatedChromeWidth,
      _minButtonWidth * 2,
    );

    if (buttons.length <= 1 || singleRowTotal <= estimatedMaxWidth) {
      return _buildRow(context, buttons, naturalWidths);
    }

    // 한 줄에 다 못 들어가면(글자가 길어 줄바꿈이 필요하면) 2줄로 나눈다.
    final splitIndex = (buttons.length / 2).ceil();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildRow(
          context,
          buttons.sublist(0, splitIndex),
          naturalWidths.sublist(0, splitIndex),
        ),
        SizedBox(height: runSpacing),
        _buildRow(
          context,
          buttons.sublist(splitIndex),
          naturalWidths.sublist(splitIndex),
        ),
      ],
    );
  }
}

/// 단일 액션 버튼 정의
class PlanFlowActionButton {
  const PlanFlowActionButton({
    required this.label,
    required this.onPressed,
    this.type = ActionButtonType.secondary,
    this.flex,
    this.buttonKey,
    this.foregroundColor,
    this.backgroundColor,
    this.borderColor,
    this.borderWidth = 1.0,
    this.fontSize = 13.0,
  });

  final String label;
  final VoidCallback? onPressed;
  final ActionButtonType type;

  /// 버튼 위젯에 부여할 key(테스트 식별·위젯 트리 안정화용).
  final Key? buttonKey;

  /// 더 이상 레이아웃에 쓰이지 않음(하위 호환용으로만 유지). 버튼 너비는
  /// [PlanFlowActionButtons]가 라벨 길이를 실측해 자동 계산한다.
  final int? flex;

  /// 커스텀 색상 (null이면 type에 따른 기본값 사용)
  final Color? foregroundColor;
  final Color? backgroundColor;
  final Color? borderColor;

  /// 테두리 두께. 여러 버튼 중 현재 선택된 것을 강조할 때 더 두껍게 준다.
  final double borderWidth;

  /// 라벨 글자 크기. 선택된 버튼을 강조할 때 더 크게 준다.
  final double fontSize;

  Widget build(BuildContext context) {
    // 너비는 항상 부모(PlanFlowActionButtons)가 SizedBox로 지정하므로 여기서
    // Expanded로 감싸지 않는다 — Expanded는 Flex 직계 자식에서만 유효한데
    // SizedBox 안에서 쓰면 크래시한다.
    switch (type) {
      case ActionButtonType.primary:
        return _buildPrimary(context);
      case ActionButtonType.secondary:
        return _buildSecondary(context);
      case ActionButtonType.destructive:
        return _buildDestructive(context);
    }
  }

  Widget _buildPrimary(BuildContext context) {
    // 확인/저장 등 주요 액션
    return FilledButton(
      key: buttonKey,
      onPressed: onPressed,
      style: FilledButton.styleFrom(
        foregroundColor: foregroundColor ?? Colors.white,
        backgroundColor: backgroundColor ?? PlanFlowColors.primary,
        minimumSize: const Size.fromHeight(44),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(
            color: borderColor ?? PlanFlowColors.primary,
            width: borderWidth,
          ),
        ),
        textStyle:
            TextStyle(fontSize: fontSize, fontWeight: FontWeight.w600),
      ),
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Text(label),
      ),
    );
  }

  Widget _buildSecondary(BuildContext context) {
    // 취소/닫기 등 보조 액션
    return OutlinedButton(
      key: buttonKey,
      onPressed: onPressed,
      style: OutlinedButton.styleFrom(
        foregroundColor: foregroundColor ?? PlanFlowColors.primary,
        backgroundColor: backgroundColor ?? PlanFlowColors.primaryFaint,
        side: BorderSide(
          color: borderColor ?? PlanFlowColors.primaryLight,
          width: borderWidth,
        ),
        minimumSize: const Size.fromHeight(44),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
        ),
        textStyle:
            TextStyle(fontSize: fontSize, fontWeight: FontWeight.w600),
      ),
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Text(label),
      ),
    );
  }

  Widget _buildDestructive(BuildContext context) {
    // 삭제/초기화 등 위험 액션
    final errorColor = Theme.of(context).colorScheme.error;
    return FilledButton(
      key: buttonKey,
      onPressed: onPressed,
      style: FilledButton.styleFrom(
        foregroundColor: foregroundColor ?? Colors.white,
        backgroundColor: backgroundColor ?? errorColor,
        minimumSize: const Size.fromHeight(44),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(
            color: borderColor ?? errorColor,
            width: borderWidth,
          ),
        ),
        textStyle:
            TextStyle(fontSize: fontSize, fontWeight: FontWeight.w600),
      ),
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Text(label),
      ),
    );
  }
}

/// 액션 버튼 타입
enum ActionButtonType {
  /// 주요 액션 (확인, 저장 등) - FilledButton, primary 색상
  primary,

  /// 보조 액션 (취소, 닫기 등) - OutlinedButton, 테두리 필수
  secondary,

  /// 위험 액션 (삭제, 초기화 등) - FilledButton, error 색상
  destructive,
}

/// 편의 헬퍼: 2버튼 패턴(취소/확인)
PlanFlowActionButtons planflowCancelConfirmButtons({
  required VoidCallback onCancel,
  required VoidCallback onConfirm,
  String cancelLabel = '취소',
  String confirmLabel = '확인',
  bool equalFlex = true,
}) {
  return PlanFlowActionButtons(
    buttons: [
      PlanFlowActionButton(
        label: cancelLabel,
        onPressed: onCancel,
        type: ActionButtonType.secondary,
        flex: equalFlex ? 1 : null,
      ),
      PlanFlowActionButton(
        label: confirmLabel,
        onPressed: onConfirm,
        type: ActionButtonType.primary,
        flex: equalFlex ? 1 : null,
      ),
    ],
  );
}
