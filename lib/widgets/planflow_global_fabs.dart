import 'package:flutter/material.dart';

import '../services/voice_conversation_launcher.dart';
import 'planflow_voice_fab.dart';

/// 여러 화면(홈/캘린더/설정 등)이 공유하는 세로 배치 공용 FAB 묶음.
///
/// 위에서부터 AI일정대화 → 음성으로 일정 관리 순서로 배치한다(사용자 요청
/// 순서). AI일정대화 FAB은 [VoiceConversationLauncher.shouldShowButton]이
/// false면(kill switch) 렌더하지 않는다.
///
/// [voiceActionBuilder]는 음성 FAB만 감싸는 옵션 빌더다(기본 null).
/// 실제 음성 인식/저장 흐름에서 좌표 또는 안내 상태별 강조가 필요할 때
/// 부모가 [GuidedAnchor] 등으로 한 번 감싸 등록한다. null이면 음성 FAB는
/// 기존 [PlanFlowVoiceFab] 그대로 렌더되어 일반 UI 동작이 변하지 않는다.
typedef PlanFlowVoiceActionBuilder = Widget Function(
  Widget Function(VoidCallback onPressed) voiceFabBuilder,
);

class PlanFlowGlobalFabs extends StatelessWidget {
  const PlanFlowGlobalFabs({
    super.key,
    required this.onVoice,
    required this.onAiConversation,
    this.showVoicePulse = false,
    this.voiceActionBuilder,
  });

  final VoidCallback onVoice;
  final VoidCallback onAiConversation;
  final bool showVoicePulse;

  /// 음성 FAB만 감싸는 옵션 빌더. null이면 기존 렌더 경로를 그대로 사용.
  final PlanFlowVoiceActionBuilder? voiceActionBuilder;

  @override
  Widget build(BuildContext context) {
    final showAiConversation = VoiceConversationLauncher.shouldShowButton();

    Widget buildVoiceFab(VoidCallback onPressed) =>
        PlanFlowVoiceFab(onPressed: onPressed, showPulse: showVoicePulse);

    final voiceFab = voiceActionBuilder != null
        ? voiceActionBuilder!(buildVoiceFab)
        : buildVoiceFab(onVoice);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        if (showAiConversation) ...[
          PlanFlowAiConversationFab(onPressed: onAiConversation),
          const SizedBox(height: 6),
        ],
        voiceFab,
      ],
    );
  }
}
