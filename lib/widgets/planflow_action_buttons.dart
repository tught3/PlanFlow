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

// ---------------------------------------------------------------------------
// 공용 모달 액션 버튼바 (PlanflowDialogActions)
// ---------------------------------------------------------------------------

/// 공용 모달/다이얼로그 액션 버튼 1건 정의.
///
/// [PlanflowDialogActions]에 전달되며, 모든 버튼은 테두리가 있는
/// [OutlinedButton]으로 렌더링된다. [isDefault]를 true로 주면 주요 액션
/// 강조(primary 테두리 + primaryFaint 배경), [isDestructive]를 true로 주면
/// 위험 액션(error 테두리)으로 표현한다.
class PlanflowDialogAction {
  const PlanflowDialogAction({
    required this.label,
    this.onPressed,
    this.isDefault = false,
    this.isDestructive = false,
    this.buttonKey,
  });

  /// 버튼 라벨
  final String label;

  /// 콜백. null이면 비활성(disabled) 상태로 렌더링.
  final VoidCallback? onPressed;

  /// 주요 액션 강조 여부. true면 primary 테두리 + primaryFaint 배경.
  /// 여전히 [OutlinedButton](테두리 있음)으로 렌더링된다.
  final bool isDefault;

  /// 위험 액션 여부. true면 error 색 테두리/전경색.
  final bool isDestructive;

  /// 버튼 위젯 식별용 key(테스트/위젯 트리 안정화).
  final Key? buttonKey;
}

/// 공용 모달/다이얼로그/바텀시트 액션 버튼바.
///
/// [actions]를 받아 가로 [Row]로 배치하며, [LayoutBuilder]로 가용 폭을
/// 측정해 [compactBreakpoint] 이하면 자동으로 [Wrap](2줄 흐름)으로 전환한다.
///
/// **규칙:**
/// - 모든 버튼은 테두리가 있는 [OutlinedButton] 스타일.
/// - 폭이 넓으면 [Row](오른쪽 정렬 기본), 폭이 좁으면 [Wrap].
/// - 치수/색상은 [PlanFlowMetrics]/[PlanFlowColors] 토큰 사용.
class PlanflowDialogActions extends StatelessWidget {
  const PlanflowDialogActions({
    super.key,
    required this.actions,
    this.spacing = PlanFlowMetrics.dialogActionSpacing,
    this.runSpacing = PlanFlowMetrics.dialogActionRunSpacing,
    this.compactBreakpoint = PlanFlowMetrics.dialogActionCompactWidth,
    this.mainAxisAlignment = MainAxisAlignment.end,
    this.alignment = WrapAlignment.end,
  });

  /// 액션 목록. 왼쪽부터 오른쪽 순서로 배치.
  final List<PlanflowDialogAction> actions;

  /// 버튼 간 가로 간격(Row 배치 시)
  final double spacing;

  /// Wrap 2줄 흐름 시 세로 간격
  final double runSpacing;

  /// 이 가용 폭 이하면 Wrap으로 전환
  final double compactBreakpoint;

  /// Row 배치 시 주축 정렬(기본 오른쪽)
  final MainAxisAlignment mainAxisAlignment;

  /// Wrap 배치 시 정렬(기본 오른쪽)
  final WrapAlignment alignment;

  @override
  Widget build(BuildContext context) {
    final buttons = actions
        .map((action) => _DialogActionButton(action: action))
        .toList(growable: false);

    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth <= compactBreakpoint) {
          return SizedBox(
            width: double.infinity,
            child: Wrap(
              spacing: spacing,
              runSpacing: runSpacing,
              alignment: alignment,
              children: buttons,
            ),
          );
        }
        // Row 배치: 버튼 사이에 간격을 넣되 Expanded는 사용하지 않는다.
        final rowChildren = <Widget>[];
        for (var i = 0; i < buttons.length; i += 1) {
          if (i > 0) {
            rowChildren.add(SizedBox(width: spacing));
          }
          rowChildren.add(buttons[i]);
        }
        return Row(
          mainAxisAlignment: mainAxisAlignment,
          mainAxisSize: MainAxisSize.max,
          children: rowChildren,
        );
      },
    );
  }
}

/// [PlanflowDialogAction] 1건을 테두리 있는 [OutlinedButton]으로 렌더링.
class _DialogActionButton extends StatelessWidget {
  const _DialogActionButton({required this.action});

  final PlanflowDialogAction action;

  @override
  Widget build(BuildContext context) {
    final errorColor = Theme.of(context).colorScheme.error;

    final Color borderColor;
    final Color foregroundColor;
    final Color? backgroundColor;
    if (action.isDestructive) {
      borderColor = errorColor;
      foregroundColor = errorColor;
      backgroundColor = null;
    } else if (action.isDefault) {
      borderColor = PlanFlowColors.primary;
      foregroundColor = PlanFlowColors.primary;
      backgroundColor = PlanFlowColors.primaryFaint;
    } else {
      borderColor = PlanFlowColors.primaryLight;
      foregroundColor = PlanFlowColors.primary;
      backgroundColor = null;
    }

    return ConstrainedBox(
      constraints: const BoxConstraints(
        minHeight: PlanFlowMetrics.dialogActionMinHeight,
      ),
      child: OutlinedButton(
        key: action.buttonKey,
        onPressed: action.onPressed,
        style: OutlinedButton.styleFrom(
          foregroundColor: foregroundColor,
          backgroundColor: backgroundColor,
          side: BorderSide(
            color: borderColor,
            width: PlanFlowMetrics.dialogActionBorderWidth,
          ),
          minimumSize:
              const Size.fromHeight(PlanFlowMetrics.dialogActionMinHeight),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          shape: RoundedRectangleBorder(
            borderRadius:
                BorderRadius.circular(PlanFlowMetrics.dialogActionRadius),
          ),
          textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
        ),
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(action.label),
        ),
      ),
    );
  }
}
