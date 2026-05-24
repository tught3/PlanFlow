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
      backgroundColor: PlanFlowColors.primary,
      foregroundColor: Colors.white,
      icon: Container(
        width: 22,
        height: 22,
        decoration: const BoxDecoration(
          color: Colors.white,
          shape: BoxShape.circle,
        ),
        child: const Icon(
          Icons.mic,
          size: 15,
          color: PlanFlowColors.primary,
        ),
      ),
      label: const Text('음성으로 일정 관리'),
    );
  }
}
