import 'package:flutter/material.dart';

import '../core/theme.dart';

class PlanFlowVoiceFab extends StatefulWidget {
  const PlanFlowVoiceFab({
    super.key,
    required this.onPressed,
    this.showPulse = false,
  });

  final VoidCallback onPressed;
  final bool showPulse;

  @override
  State<PlanFlowVoiceFab> createState() => _PlanFlowVoiceFabState();
}

class _PlanFlowVoiceFabState extends State<PlanFlowVoiceFab>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulseController;
  late final Animation<double> _pulseScale;
  late final Animation<double> _pulseOpacity;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    );
    final curve = CurvedAnimation(
      parent: _pulseController,
      curve: Curves.easeOutCubic,
    );
    _pulseScale = Tween<double>(begin: 1.0, end: 1.22).animate(curve);
    _pulseOpacity = Tween<double>(begin: 0.28, end: 0.0).animate(curve);
    if (widget.showPulse) {
      _pulseController.repeat();
    }
  }

  @override
  void didUpdateWidget(covariant PlanFlowVoiceFab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.showPulse && !_pulseController.isAnimating) {
      _pulseController.repeat();
    } else if (!widget.showPulse && _pulseController.isAnimating) {
      _pulseController.stop();
      _pulseController.value = 0.0;
    }
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final fab = DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: const Color(0xFF0B74B8),
          width: 2.6,
        ),
        boxShadow: const [
          BoxShadow(
            color: Color(0x332A8FC9),
            blurRadius: 14,
            spreadRadius: 1,
            offset: Offset(0, 3),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(2.5),
        child: FloatingActionButton.extended(
          heroTag: null,
          onPressed: widget.onPressed,
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
          label: const Text('음성으로 일정 관리'),
        ),
      ),
    );

    final ring = IgnorePointer(
      child: AnimatedBuilder(
        animation: _pulseController,
        builder: (context, child) {
          final pulseOpacity = widget.showPulse ? _pulseOpacity.value : 0.16;
          final pulseScale = widget.showPulse ? _pulseScale.value : 1.0;
          return Opacity(
            opacity: pulseOpacity,
            child: Transform.scale(
              scale: pulseScale,
              child: child,
            ),
          );
        },
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: const Color(0xFF38A8E8).withValues(alpha: 0.95),
              width: 2.8,
            ),
            boxShadow: const [
              BoxShadow(
                color: Color(0x4438A8E8),
                blurRadius: 22,
                spreadRadius: 2,
              ),
            ],
          ),
        ),
      ),
    );

    return Stack(
      alignment: Alignment.center,
      clipBehavior: Clip.none,
      children: [
        Positioned.fill(
          child: Padding(
            padding: const EdgeInsets.all(4),
            child: ring,
          ),
        ),
        fab,
      ],
    );
  }
}
