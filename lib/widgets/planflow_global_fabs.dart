import 'package:flutter/material.dart';

import '../services/voice_conversation_launcher.dart';
import 'planflow_voice_fab.dart';

/// 여러 화면(홈/캘린더/설정 등)이 공유하는 세로 배치 공용 FAB 묶음.
///
/// 위에서부터 AI일정대화 → 음성으로 일정 관리 순서로 배치한다(사용자 요청
/// 순서). AI일정대화 FAB은 [VoiceConversationLauncher.shouldShowButton]이
/// false면(kill switch) 렌더하지 않는다.
class PlanFlowGlobalFabs extends StatelessWidget {
  const PlanFlowGlobalFabs({
    super.key,
    required this.onVoice,
    required this.onAiConversation,
    this.showVoicePulse = false,
  });

  final VoidCallback onVoice;
  final VoidCallback onAiConversation;
  final bool showVoicePulse;

  @override
  Widget build(BuildContext context) {
    final showAiConversation = VoiceConversationLauncher.shouldShowButton();

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        if (showAiConversation) ...[
          PlanFlowAiConversationFab(onPressed: onAiConversation),
          const SizedBox(height: 6),
        ],
        PlanFlowVoiceFab(onPressed: onVoice, showPulse: showVoicePulse),
      ],
    );
  }
}
