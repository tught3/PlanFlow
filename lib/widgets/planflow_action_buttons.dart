import 'package:flutter/material.dart';

import '../core/theme.dart';

/// PlanFlow 전용 모달/다이얼로그/바텀시트 액션 버튼바
///
/// **규칙:**
/// - 항상 가로(Row) 정렬, 세로(Column) 스택 금지
/// - 글자가 길어 한 줄에 못 들어오면 Wrap로 2줄 흐름
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

  /// 2줄로 wrap될 때 세로 간격
  final double runSpacing;

  /// 버튼들의 정렬 (기본 오른쪽 정렬)
  final WrapAlignment alignment;

  @override
  Widget build(BuildContext context) {
    // flex 버튼이 하나라도 있으면 Row로 배치한다. Expanded는 Flex(Row/Column)
    // 안에서만 유효하며 Wrap 안에 넣으면 ParentDataWidget 오류로 크래시한다.
    final hasFlex = buttons.any((btn) => btn.flex != null && btn.flex! > 0);
    if (hasFlex) {
      final children = <Widget>[];
      for (var i = 0; i < buttons.length; i += 1) {
        if (i > 0) {
          children.add(SizedBox(width: spacing));
        }
        children.add(buttons[i].build(context));
      }
      return Row(children: children);
    }

    // flex가 없으면 내용 크기대로 두고, 길어지면 2줄로 흐르게 Wrap을 쓴다.
    return SizedBox(
      width: double.infinity,
      child: Wrap(
        spacing: spacing,
        runSpacing: runSpacing,
        alignment: alignment,
        children: buttons
            .map((btn) => ConstrainedBox(
                  constraints: const BoxConstraints(
                    minWidth: 88,
                    minHeight: 44,
                  ),
                  child: btn.build(context),
                ))
            .toList(growable: false),
      ),
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
  });

  final String label;
  final VoidCallback? onPressed;
  final ActionButtonType type;

  /// 버튼 위젯에 부여할 key(테스트 식별·위젯 트리 안정화용).
  final Key? buttonKey;

  /// flex > 0이면 Expanded로 감싸서 남은 공간을 채움
  /// null이면 내용물 크기만큼만 차지
  final int? flex;

  /// 커스텀 색상 (null이면 type에 따른 기본값 사용)
  final Color? foregroundColor;
  final Color? backgroundColor;
  final Color? borderColor;

  Widget build(BuildContext context) {
    final Widget button;
    switch (type) {
      case ActionButtonType.primary:
        button = _buildPrimary(context);
        break;
      case ActionButtonType.secondary:
        button = _buildSecondary(context);
        break;
      case ActionButtonType.destructive:
        button = _buildDestructive(context);
        break;
    }

    if (flex != null && flex! > 0) {
      return Expanded(flex: flex!, child: button);
    }
    return button;
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
            width: 1,
          ),
        ),
        textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
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
          width: 1,
        ),
        minimumSize: const Size.fromHeight(44),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
        ),
        textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
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
            width: 1,
          ),
        ),
        textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
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
