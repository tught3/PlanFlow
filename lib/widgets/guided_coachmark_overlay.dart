import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'guided_anchor.dart';

class GuidedCoachmarkOverlay extends StatefulWidget {
  const GuidedCoachmarkOverlay(
      {super.key,
      required this.registry,
      required this.targetId,
      this.additionalTargetIds = const <String>[],
      required this.bubble,
      required this.progressLabel,
      required this.onSkip,
      this.padding = 8,
      this.blockOutsideTaps = true,
      this.showBubble = true,
      this.skipLabel = 'Skip'});
  final GuidedAnchorRegistry registry;
  final String targetId;
  final List<String> additionalTargetIds;
  final Widget bubble;
  final String progressLabel;
  final VoidCallback onSkip;
  final double padding;
  final bool blockOutsideTaps;

  /// false 면 구멍(밝은 영역)만 남기고 말풍선은 그리지 않는다.
  final bool showBubble;
  final String skipLabel;
  @override
  State<GuidedCoachmarkOverlay> createState() => _GuidedCoachmarkOverlayState();
}

class _GuidedCoachmarkOverlayState extends State<GuidedCoachmarkOverlay>
    with WidgetsBindingObserver {
  bool _refreshScheduled = false;
  int _refreshVersion = 0;
  Map<String, Rect?> _targetRects = <String, Rect?>{};
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeMetrics() => _scheduleTargetRefresh();

  @override
  void didUpdateWidget(covariant GuidedCoachmarkOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.targetId != widget.targetId ||
        oldWidget.additionalTargetIds != widget.additionalTargetIds ||
        oldWidget.registry != widget.registry) {
      _scheduleTargetRefresh();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  void _scheduleTargetRefresh() {
    if (!mounted || _refreshScheduled) return;
    _refreshScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _refreshScheduled = false;
      if (!mounted) return;
      final object = context.findRenderObject();
      if (object is! RenderBox || !object.attached || !object.hasSize) return;
      final ids = <String>{widget.targetId, ...widget.additionalTargetIds};
      final next = <String, Rect?>{
        for (final id in ids) id: _targetRect(id, object),
      };
      var changed = next.length != _targetRects.length;
      for (final entry in next.entries) {
        if (_targetRects[entry.key] != entry.value) changed = true;
      }
      if (changed) {
        setState(() {
          _targetRects = next;
          _refreshVersion++;
        });
      }
    });
  }

  Rect? _targetRect(String id, RenderBox layoutRoot) {
    final targetContext = widget.registry.keyFor(id)?.currentContext;
    if (targetContext == null || !targetContext.mounted) return null;
    final targetObject = targetContext.findRenderObject();
    if (targetObject is! RenderBox ||
        !targetObject.attached ||
        !targetObject.hasSize ||
        targetObject.size.isEmpty) return null;
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

  @override
  Widget build(BuildContext context) => LayoutBuilder(
      key: ValueKey(_refreshVersion),
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        final rect = _targetRects[widget.targetId];
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
        const gap = 12.0;
        Widget boundedBubble(double maxHeight) => ConstrainedBox(
            constraints: BoxConstraints(maxHeight: math.max(0.0, maxHeight)),
            child: _bubble(context));
        Widget bubblePositioned;
        if (hole == null) {
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
          final putBelow = below >= above;
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
                      alignment: Alignment.bottomCenter,
                      child: boundedBubble(above)));
        }
        return Stack(fit: StackFit.expand, children: [
          // 구멍이 아직 없으면(대상이 화면 밖/미측정) 덮지 않는다.
          // 덮으면 화면 전체가 어두워져 아무것도 할 수 없다.
          if (holes.isNotEmpty && widget.blockOutsideTaps)
            ClipPath(
                clipper: _HoleClipper(holes),
                child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () {},
                    child: const ColoredBox(color: Color(0x99000000))))
          else if (holes.isNotEmpty)
            IgnorePointer(
                child: ClipPath(
                    clipper: _HoleClipper(holes),
                    child: const ColoredBox(color: Color(0x55000000)))),
          if (widget.showBubble) bubblePositioned,
        ]);
      });

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
                const SizedBox(height: 8),
                Align(
                    alignment: Alignment.centerRight,
                    child: TextButton(
                        onPressed: widget.onSkip,
                        child: Text(widget.skipLabel)))
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
