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
    final fab = FloatingActionButton.extended(
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
    );

    if (!widget.showPulse) {
      return fab;
    }

    return Stack(
      alignment: Alignment.center,
      clipBehavior: Clip.none,
      children: [
        Positioned.fill(
          child: IgnorePointer(
            child: AnimatedBuilder(
              animation: _pulseController,
              builder: (context, child) {
                return Opacity(
                  opacity: _pulseOpacity.value,
                  child: Transform.scale(
                    scale: _pulseScale.value,
                    child: child,
                  ),
                );
              },
              child: Padding(
                padding: const EdgeInsets.all(6),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(
                      color: PlanFlowColors.fab.withValues(alpha: 0.32),
                      width: 2,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        fab,
      ],
    );
  }
}
