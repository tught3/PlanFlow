import 'package:flutter/material.dart';

import 'guide_instruction_text.dart';

/// The exact spoken-correction practice shown during the create-speech step.
class VoiceCorrectionExample extends StatelessWidget {
  const VoiceCorrectionExample(
      {super.key, this.compact = false, this.showHeading = true});

  /// 말하는 중 상단에 띄울 때는 제목만 줄여 높이를 줄인다.
  final bool compact;

  /// The surrounding coachmark can provide this heading itself.
  final bool showHeading;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (showHeading) ...[
            Text('말하기 교정 연습',
                style: (compact
                        ? Theme.of(context).textTheme.titleLarge
                        : Theme.of(context).textTheme.headlineSmall)
                    ?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
          ],
          GuideInstructionText(
            '음성으로 일정 입력하기 버튼을 누르고\n'
            '“내일 오후 1시에”\n'
            '→ “아니”\n'
            '→ “오후 2시에 강남역에서 일정”\n'
            '순서로 말해보세요.',
            key: const ValueKey('voice-correction-practice-sequence'),
            fontWeight: FontWeight.w600,
          ),
          const SizedBox(height: 8),
          const GuideInstructionText(
            '말을 다 한 뒤 ‘완료’ 버튼을 눌러 주세요.',
            fontWeight: FontWeight.w700,
          ),
          const SizedBox(height: 8),
          GuideInstructionText.rich(
            TextSpan(children: [
              const TextSpan(
                text: '“오후 1시에”가 입력됐다가 “아니”라고 말하면 지워집니다.',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
              const TextSpan(
                text: ' 이어서 “오후 2시에 강남역에서 일정”이라고 말하면 '
                    '“내일 오후 2시에 강남역에서 일정”으로 입력됩니다. '
                    '(“아니” 대신 “다시”라고 말하면 전체 삭제)',
              ),
            ]),
            key: const ValueKey('voice-correction-practice-explanation'),
          ),
        ],
      );
}
