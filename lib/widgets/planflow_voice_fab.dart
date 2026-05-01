import 'package:flutter/material.dart';

import '../core/theme.dart';

class PlanFlowVoiceFab extends StatelessWidget {
  const PlanFlowVoiceFab({
    super.key,
    required this.onPressed,
  });

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return FloatingActionButton.extended(
      onPressed: onPressed,
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
          color: PlanFlowColors.fab,
        ),
      ),
      label: const Text('말하기'),
    );
  }
}
