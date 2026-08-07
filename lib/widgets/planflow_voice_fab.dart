import 'package:flutter/material.dart';

import '../core/theme.dart';

class PlanFlowVoiceFab extends StatelessWidget {
  const PlanFlowVoiceFab({
    super.key,
    required this.onPressed,
    this.showPulse = false,
  });

  final VoidCallback onPressed;

  // Kept for call-site compatibility. The visual highlight was removed because
  // the shared voice action should feel like a normal global action.
  final bool showPulse;

  @override
  Widget build(BuildContext context) {
    return FloatingActionButton.extended(
      heroTag: null,
      onPressed: onPressed,
      backgroundColor: PlanFlowColors.voiceFab,
      foregroundColor: Colors.white,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      extendedPadding: const EdgeInsets.symmetric(horizontal: 10),
      icon: Container(
        width: 16,
        height: 16,
        decoration: const BoxDecoration(
          color: Colors.white,
          shape: BoxShape.circle,
        ),
        child: const Icon(
          Icons.mic,
          size: 11,
          color: PlanFlowColors.voiceFab,
        ),
      ),
      label: const Text(
        '음성으로 일정 관리',
        style: TextStyle(fontSize: 12),
      ),
    );
  }
}

class PlanFlowAiConversationFab extends StatelessWidget {
  const PlanFlowAiConversationFab({super.key, required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return FloatingActionButton.extended(
      heroTag: null,
      onPressed: onPressed,
      backgroundColor: PlanFlowColors.active,
      foregroundColor: Colors.white,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      extendedPadding: const EdgeInsets.symmetric(horizontal: 10),
      icon: Container(
        width: 16,
        height: 16,
        decoration: const BoxDecoration(
          color: Colors.white,
          shape: BoxShape.circle,
        ),
        child: const Icon(
          Icons.chat_bubble_outline,
          size: 11,
          color: PlanFlowColors.active,
        ),
      ),
      label: const Text(
        'AI일정대화',
        style: TextStyle(fontSize: 12),
      ),
    );
  }
}
