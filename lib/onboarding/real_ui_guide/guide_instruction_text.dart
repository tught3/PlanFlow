import 'package:flutter/material.dart';

import '../../widgets/guided_anchor.dart';
import '../../widgets/guided_coachmark_overlay.dart';

const savedDetailGuideTitle = '3/7 · 저장된 일정 확인';
const savedDetailGuideBody =
    '‘저장된 일정 확인’에서 제목, 날짜·시간과 장소를 확인한 뒤, 화면 아래의 ‘준비·출발 안내 확인’ 버튼을 눌러 주세요.';
const editPreviewGuideTitle = '6/7 · 변경 내용 확인·저장';
const editPreviewGuideBody = '밝게 표시된 시작 시간과 종료 시간을 확인하고 저장 버튼을 눌러 주세요.';
const updatedDetailGuideTitle = '7/7 · 변경 완료';
const updatedDetailGuideBody =
    '변경된 시작 시간과 종료 시간을 확인하고 화면 아래의 ‘변경된 시간 확인’ 버튼을 눌러 주세요. 마지막으로 동기화를 선택해요.';

/// Shared typography for the guide's instructional body copy.
class GuideInstructionText extends StatelessWidget {
  const GuideInstructionText(this.text, {super.key, this.fontWeight})
      : span = null;

  const GuideInstructionText.rich(this.span, {super.key, this.fontWeight})
      : text = null;

  final String? text;
  final InlineSpan? span;
  final FontWeight? fontWeight;

  @override
  Widget build(BuildContext context) {
    final style = (Theme.of(context).textTheme.bodyLarge ?? const TextStyle())
        .copyWith(fontSize: 14, fontWeight: fontWeight, height: 1.5);
    return span == null
        ? Text(text!, style: style)
        : Text.rich(span!, style: style);
  }
}

class GuideEditPreviewCoachmark extends StatelessWidget {
  const GuideEditPreviewCoachmark({
    super.key,
    required this.registry,
    this.protectBeforeTargetReady = false,
  });

  final GuidedAnchorRegistry registry;
  final bool protectBeforeTargetReady;

  @override
  Widget build(BuildContext context) => GuidedCoachmarkOverlay(
        registry: registry,
        targetId: 'edit.save',
        additionalTargetIds: const [
          'edit.title',
          'edit.dateTime',
          'edit.location',
          'edit.save.footer',
        ],
        pulseTargetIds: const [
          'edit.dateTime',
          'edit.save',
          'edit.save.footer'
        ],
        preferBubbleBetweenTargets: true,
        preferLowerBubbleSlot: true,
        blockOutsideTaps: false,
        protectBeforeTargetReady: protectBeforeTargetReady,
        bubble: const GuideInstructionText(editPreviewGuideBody),
        progressLabel: editPreviewGuideTitle,
        onSkip: null,
      );
}
