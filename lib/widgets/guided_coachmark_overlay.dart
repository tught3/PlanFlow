import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'guided_anchor.dart';

class GuidedCoachmarkOverlay extends StatefulWidget {
  const GuidedCoachmarkOverlay(
      {super.key,
      required this.registry,
      required this.targetId,
      this.additionalTargetIds = const <String>[],
      this.passThroughTargetIds = const <String>[],
      this.pulseTargetIds = const <String>[],
      required this.bubble,
      required this.progressLabel,
      required this.onSkip,
      this.padding = 8,
      this.blockOutsideTaps = true,
      this.showBubble = true,
      this.preferBubbleBetweenTargets = false,
      this.preferLowerBubbleSlot = false,
      this.alignBubbleAboveTarget = false,
      this.protectBeforeTargetReady = false,
      this.skipLabel = 'Skip'});
  final GuidedAnchorRegistry registry;
  final String targetId;
  final List<String> additionalTargetIds;

  /// Tap targets that remain dimmed while allowing interaction.
  final List<String> passThroughTargetIds;

  /// Actionable targets to emphasize without intercepting their taps.
  final List<String> pulseTargetIds;
  final Widget bubble;
  final String progressLabel;
  final VoidCallback? onSkip;
  final double padding;
  final bool blockOutsideTaps;

  /// false 면 구멍(밝은 영역)만 남기고 말풍선은 그리지 않는다.
  final bool showBubble;

  /// Place the bubble between two separate spotlights when there is room.
  final bool preferBubbleBetweenTargets;

  /// Use the lowest readable slot and align the card with its lower edge.
  final bool preferLowerBubbleSlot;

  /// Align the bubble immediately above the target, within the safe area.
  final bool alignBubbleAboveTarget;

  /// Show the instruction and block background taps before layout measures the CTA.
  final bool protectBeforeTargetReady;
  final String skipLabel;
  @override
  State<GuidedCoachmarkOverlay> createState() => _GuidedCoachmarkOverlayState();
}

class _GuidedCoachmarkOverlayState extends State<GuidedCoachmarkOverlay>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 1200));
  Timer? _pulseTargetPoll;
  bool _pulsePlayed = false;
  bool _returningPulse = false;
  bool _reduceMotion = false;
  Set<String> _enabledPulseTargets = <String>{};
  bool _refreshScheduled = false;
  int _refreshVersion = 0;
  Map<String, Rect?> _targetRects = <String, Rect?>{};
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _pulse.addStatusListener(_onPulseStatus);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduceMotion = MediaQuery.disableAnimationsOf(context);
    _configurePulseWatch();
    _scheduleTargetRefresh();
  }

  @override
  void didChangeMetrics() => _scheduleTargetRefresh();

  @override
  void didUpdateWidget(covariant GuidedCoachmarkOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.targetId != widget.targetId ||
        !listEquals(
            oldWidget.additionalTargetIds, widget.additionalTargetIds) ||
        !listEquals(
            oldWidget.passThroughTargetIds, widget.passThroughTargetIds) ||
        !listEquals(oldWidget.pulseTargetIds, widget.pulseTargetIds) ||
        oldWidget.progressLabel != widget.progressLabel ||
        oldWidget.registry != widget.registry) {
      _pulsePlayed = false;
      _configurePulseWatch();
      _scheduleTargetRefresh();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _pulseTargetPoll?.cancel();
    _pulse.dispose();
    super.dispose();
  }

  void _configurePulseWatch() {
    if (widget.pulseTargetIds.isEmpty) {
      _pulseTargetPoll?.cancel();
      _pulseTargetPoll = null;
      _pulsePlayed = false;
      _returningPulse = false;
      _pulse.stop();
      _enabledPulseTargets = <String>{};
      return;
    }
    // A button can become enabled without its anchor moving or this overlay
    // rebuilding. Polling does not request frames unless something changes.
    _pulseTargetPoll ??= Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (mounted) _refreshTargets();
    });
  }

  void _scheduleTargetRefresh() {
    if (!mounted || _refreshScheduled) return;
    _refreshScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _refreshScheduled = false;
      if (mounted) _refreshTargets();
    });
  }

  void _refreshTargets() {
    final object = context.findRenderObject();
    if (object is! RenderBox || !object.attached || !object.hasSize) return;
    final ids = <String>{
      widget.targetId,
      ...widget.additionalTargetIds,
      ...widget.passThroughTargetIds,
      ...widget.pulseTargetIds,
    };
    final next = <String, Rect?>{
      for (final id in ids) id: _targetRect(id, object),
    };
    final enabled = <String>{
      for (final id in widget.pulseTargetIds)
        if (next[id] != null && _pulseTargetEnabled(id)) id,
    };
    final enabledChanged = enabled.length != _enabledPulseTargets.length ||
        !enabled.containsAll(_enabledPulseTargets);
    if (enabledChanged) _pulsePlayed = false;
    var changed = next.length != _targetRects.length || enabledChanged;
    for (final entry in next.entries) {
      if (_targetRects[entry.key] != entry.value) changed = true;
    }
    if (changed) {
      setState(() {
        _targetRects = next;
        _enabledPulseTargets = enabled;
        _refreshVersion++;
      });
    }
    if (enabled.isEmpty || _reduceMotion) {
      _pulsePlayed = false;
      _returningPulse = false;
      _pulse.stop();
      if (_pulse.value != 0.5) _pulse.value = 0.5;
    } else if (!_pulse.isAnimating && !_pulsePlayed) {
      _pulsePlayed = true;
      _returningPulse = false;
      _pulse.forward(from: 0);
    }
  }

  void _onPulseStatus(AnimationStatus status) {
    if (!mounted || _reduceMotion || _enabledPulseTargets.isEmpty) return;
    if (status == AnimationStatus.completed) {
      _returningPulse = true;
      _pulse.reverse();
    } else if (status == AnimationStatus.dismissed && _returningPulse) {
      _returningPulse = false;
      // Keep a visible static outline after the short pulse has finished.
      _pulse.value = 0.5;
    }
  }

  Rect? _targetRect(String id, RenderBox layoutRoot) {
    final targetContext = widget.registry.keyFor(id)?.currentContext;
    if (targetContext == null || !targetContext.mounted) return null;
    final targetObject = targetContext.findRenderObject();
    if (targetObject is! RenderBox ||
        !targetObject.attached ||
        !targetObject.hasSize ||
        targetObject.size.isEmpty) {
      return null;
    }
    for (RenderObject? node = targetObject; node != null; node = node.parent) {
      if (node is RenderOffstage && node.offstage) return null;
    }
    try {
      final global =
          targetObject.localToGlobal(Offset.zero) & targetObject.size;
      final rect = Rect.fromPoints(
        layoutRoot.globalToLocal(global.topLeft),
        layoutRoot.globalToLocal(global.bottomRight),
      );
      var visible = rect.intersect(Offset.zero & layoutRoot.size);
      // Scrollable ancestors clip their children. Keep the spotlight to the
      // actually painted/hit-testable portion of a partially visible target.
      for (RenderObject? node = targetObject.parent;
          node != null;
          node = node.parent) {
        if (node is RenderAbstractViewport) {
          final viewport = node as RenderBox;
          if (!viewport.attached || !viewport.hasSize) return null;
          final viewportRect = MatrixUtils.transformRect(
              viewport.getTransformTo(layoutRoot), Offset.zero & viewport.size);
          visible = visible.intersect(viewportRect);
        }
        if (identical(node, layoutRoot)) break;
      }
      if (!visible.isFinite || visible.isEmpty) return null;
      return visible;
    } on FlutterError {
      return null;
    }
  }

  bool _pulseTargetEnabled(String id) {
    // These buttons can become disabled while recording or sending. The
    // surrounding anchor remains mounted, so inspect the live button state.
    if (!const <String>{
      'voice.start',
      'voice.submit',
      'query.retryMic',
      'query.send'
    }.contains(id)) {
      return true;
    }
    final target = widget.registry.keyFor(id)?.currentContext;
    if (target is! Element || !target.mounted) return false;
    var enabled = false;
    void visit(Element element) {
      if (enabled) return;
      final button = element.widget;
      if (button is ButtonStyleButton && button.onPressed != null) {
        enabled = true;
        return;
      }
      element.visitChildren(visit);
    }

    visit(target);
    return enabled;
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
      key: ValueKey(_refreshVersion),
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        final rect = _targetRects[widget.targetId];
        final awaitingTarget = widget.protectBeforeTargetReady && rect == null;
        // Anchors can move after an implicit scroll or an ancestor rebuild
        // without changing the target ID (for example critical -> save).
        // Refresh after each layout; setState is only issued when geometry
        // actually differs, so this settles after at most one extra frame.
        _scheduleTargetRefresh();
        final safe = MediaQuery.paddingOf(context);
        // The cutout must follow the actual tappable target, including any
        // part inside system padding. Safe-area bounds constrain the bubble,
        // not the target's hit-test opening.
        final holes = <Rect>[
          if (rect != null) rect,
          for (final id in widget.additionalTargetIds)
            if (_targetRects[id] case final Rect target) target,
        ]
            .map((target) =>
                target.inflate(widget.padding).intersect(Offset.zero & size))
            .where((target) => !target.isEmpty)
            .toList();
        final hole =
            holes.isEmpty ? null : holes.reduce((a, b) => a.expandToInclude(b));
        final tapHoles = <Rect>[
          ...holes,
          for (final id in widget.passThroughTargetIds)
            if (_targetRects[id] case final Rect target) target,
        ];
        const gap = 12.0;
        Rect? guideRegion;
        if (widget.preferBubbleBetweenTargets && rect != null) {
          final safeTop = (safe.top + gap).clamp(0.0, size.height).toDouble();
          final safeBottom = (size.height - safe.bottom - gap)
              .clamp(safeTop, size.height)
              .toDouble();
          final bottom = widget.alignBubbleAboveTarget
              ? (rect.top - widget.padding - gap)
                  .clamp(safeTop, safeBottom)
                  .toDouble()
              : safeBottom;
          final sorted = [...holes]..sort((a, b) => a.top.compareTo(b.top));
          var cursor = safeTop;
          final regions = <Rect>[];
          for (final target in sorted) {
            final end = (target.top - gap).clamp(safeTop, bottom).toDouble();
            if (end > cursor) {
              regions.add(Rect.fromLTRB(0, cursor, size.width, end));
            }
            cursor = math.max(cursor,
                (target.bottom + gap).clamp(safeTop, bottom).toDouble());
          }
          if (bottom > cursor) {
            regions.add(Rect.fromLTRB(0, cursor, size.width, bottom));
          }
          // Follow the preferred edge when the card fits. On small viewports,
          // use the largest remaining slot and let the whole card scroll.
          final readableHeight =
              180.0 * MediaQuery.textScalerOf(context).scale(1);
          final preferredRegions =
              widget.preferLowerBubbleSlot ? regions.reversed : regions;
          for (final region in preferredRegions) {
            if (region.height >= readableHeight) {
              guideRegion = region;
              break;
            }
          }
          if (guideRegion == null) {
            for (final region in preferredRegions) {
              if (guideRegion == null || region.height > guideRegion.height) {
                guideRegion = region;
              }
            }
          }
        }
        Widget boundedBubble(double maxHeight) => ConstrainedBox(
            constraints: BoxConstraints(maxHeight: math.max(0.0, maxHeight)),
            child: _bubble(context));
        Widget bubblePositioned;
        if (guideRegion != null && guideRegion.height > 0) {
          bubblePositioned = Positioned(
              left: safe.left + 12,
              right: safe.right + 12,
              top: guideRegion.top,
              bottom: math.max(0.0, size.height - guideRegion.bottom),
              child: Align(
                  alignment: widget.preferLowerBubbleSlot
                      ? Alignment.bottomCenter
                      : Alignment.topCenter,
                  child: ConstrainedBox(
                      constraints:
                          BoxConstraints(maxHeight: guideRegion.height),
                      child: _scrollableGuideBubble(context))));
        } else if (!awaitingTarget && widget.preferBubbleBetweenTargets) {
          // No safe vertical space exists outside the visible targets yet.
          bubblePositioned = const SizedBox.shrink();
        } else if (!awaitingTarget && widget.alignBubbleAboveTarget) {
          final top = safe.top + gap;
          final bottom = hole == null ? top : hole.top - gap;
          bubblePositioned = bottom <= top
              ? const SizedBox.shrink()
              : Positioned(
                  left: safe.left + 12,
                  right: safe.right + 12,
                  top: top,
                  bottom: size.height - bottom,
                  child: Align(
                      alignment: Alignment.bottomCenter,
                      child: ConstrainedBox(
                          constraints: BoxConstraints(maxHeight: bottom - top),
                          child: _scrollableGuideBubble(context))));
        } else if (hole == null || awaitingTarget) {
          // No rect yet (or offstage): place the bubble near the top of the
          // safe area using only `top` so the Positioned always has a
          // non-negative intrinsic height even before the target is laid out.
          bubblePositioned = Positioned(
              left: safe.left + 12,
              right: safe.right + 12,
              top: safe.top + 16,
              bottom: safe.bottom + 16,
              child: Align(
                  alignment: Alignment.topCenter,
                  child: boundedBubble(
                      size.height - safe.top - safe.bottom - 32)));
        } else {
          // Pick a side so the bubble never collides with the hole. Use
          // either `top` or `bottom` exclusively (never both) so the
          // Positioned's resolved height remains bubble-intrinsic instead of
          // `parent.height - top - bottom`, which can be negative when the
          // bottom anchor equals the parent's full height.
          final below = size.height - safe.bottom - hole.bottom - gap;
          final above = hole.top - safe.top - gap;
          final readableHeight =
              180.0 * MediaQuery.textScalerOf(context).scale(1);
          final putBelow = above < readableHeight && below > above;
          bubblePositioned = putBelow
              ? Positioned(
                  left: safe.left + 12,
                  right: safe.right + 12,
                  top: hole.bottom + gap,
                  bottom: safe.bottom + 12,
                  child: Align(
                      alignment: Alignment.topCenter,
                      child: boundedBubble(below)))
              : Positioned(
                  left: safe.left + 12,
                  right: safe.right + 12,
                  top: safe.top + 12,
                  bottom: size.height - hole.top + gap,
                  child: Align(
                      alignment: Alignment.topCenter,
                      child: boundedBubble(above)));
        }
        return Stack(fit: StackFit.expand, children: [
          // 구멍이 아직 없으면(대상이 화면 밖/미측정) 덮지 않는다.
          // 덮으면 화면 전체가 어두워져 아무것도 할 수 없다.
          if (awaitingTarget)
            const AbsorbPointer(child: ColoredBox(color: Color(0x99000000)))
          else if (holes.isNotEmpty && widget.blockOutsideTaps) ...[
            IgnorePointer(
                child: ClipPath(
                    clipper: _HoleClipper(holes),
                    child: const ColoredBox(color: Color(0x99000000)))),
            ClipPath(
                clipper: _HoleClipper(tapHoles),
                child: GestureDetector(
                    behavior: HitTestBehavior.opaque, onTap: () {})),
          ] else if (holes.isNotEmpty)
            IgnorePointer(
                child: ClipPath(
                    clipper: _HoleClipper(holes),
                    child: const ColoredBox(color: Color(0x55000000)))),
          for (final id in widget.pulseTargetIds)
            if (_targetRects[id] case final Rect target)
              Positioned.fromRect(
                  rect: target.inflate(3).intersect(Offset.zero & size),
                  child: IgnorePointer(
                      child: AnimatedBuilder(
                          animation: _pulse,
                          builder: (context, _) => !_enabledPulseTargets
                                  .contains(id)
                              ? const SizedBox.shrink()
                              : DecoratedBox(
                                  decoration: BoxDecoration(
                                      borderRadius: BorderRadius.circular(14),
                                      border: Border.all(
                                          color: Theme.of(context)
                                              .colorScheme
                                              .primary
                                              .withValues(
                                                  alpha: 0.55 +
                                                      _pulse.value * 0.4),
                                          width: 2 + _pulse.value)))))),
          if (widget.showBubble) bubblePositioned,
        ]);
      });

  // For the two-target detail guide, scroll the entire card so its fixed
  // heading and skip control cannot overflow a short available region.
  Widget _scrollableGuideBubble(BuildContext context) => Material(
      elevation: 8,
      borderRadius: BorderRadius.circular(16),
      color: Theme.of(context).colorScheme.surface,
      child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Semantics(
                    liveRegion: true,
                    label: widget.progressLabel,
                    child: Text(widget.progressLabel,
                        style: Theme.of(context)
                            .textTheme
                            .titleSmall
                            ?.copyWith(fontWeight: FontWeight.w700))),
                const SizedBox(height: 8),
                widget.bubble,
                if (widget.onSkip != null) ...[
                  const SizedBox(height: 8),
                  Align(
                      alignment: Alignment.centerRight,
                      child: TextButton(
                          onPressed: widget.onSkip,
                          child: Text(widget.skipLabel))),
                ]
              ])));

  Widget _bubble(BuildContext context) => Material(
      elevation: 8,
      borderRadius: BorderRadius.circular(16),
      color: Theme.of(context).colorScheme.surface,
      child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Semantics(
                    liveRegion: true,
                    label: widget.progressLabel,
                    child: Text(widget.progressLabel,
                        style: Theme.of(context)
                            .textTheme
                            .titleSmall
                            ?.copyWith(fontWeight: FontWeight.w700))),
                const SizedBox(height: 8),
                Flexible(
                    fit: FlexFit.loose,
                    child: SingleChildScrollView(child: widget.bubble)),
                if (widget.onSkip != null) ...[
                  const SizedBox(height: 8),
                  Align(
                      alignment: Alignment.centerRight,
                      child: TextButton(
                          onPressed: widget.onSkip,
                          child: Text(widget.skipLabel))),
                ]
              ])));
}

class _HoleClipper extends CustomClipper<Path> {
  const _HoleClipper(this.holes);
  final List<Rect> holes;
  @override
  Path getClip(Size size) {
    final whole = Path()..addRect(Offset.zero & size);
    if (holes.isEmpty) return whole;
    final cutout = Path();
    for (final hole in holes) {
      cutout.addRRect(RRect.fromRectAndRadius(hole, const Radius.circular(12)));
    }
    return Path.combine(PathOperation.difference, whole, cutout);
  }

  @override
  bool shouldReclip(covariant _HoleClipper oldClipper) =>
      oldClipper.holes != holes;
}
