import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

class GuidedAnchorRegistry {
  GuidedAnchorRegistry();
  static final GuidedAnchorRegistry shared = GuidedAnchorRegistry();
  final Map<String, _Binding> _bindings = {};
  GlobalKey? keyFor(String id) => _bindings[id]?.key;

  Rect? rectFor(String id, {required RenderBox root}) {
    final context = _bindings[id]?.key.currentContext;
    if (context == null ||
        !context.mounted ||
        !root.attached ||
        !root.hasSize) {
      return null;
    }
    final object = context.findRenderObject();
    if (object is! RenderBox ||
        !object.attached ||
        !object.hasSize ||
        object.size.isEmpty) {
      return null;
    }
    for (RenderObject? node = object; node != null; node = node.parent) {
      if (node is RenderOffstage && node.offstage) {
        return null;
      }
      if (identical(node, root)) break;
    }
    try {
      final global = object.localToGlobal(Offset.zero) & object.size;
      final topLeft = root.globalToLocal(global.topLeft);
      final bottomRight = root.globalToLocal(global.bottomRight);
      final rect = Rect.fromPoints(topLeft, bottomRight);
      if (!rect.isFinite ||
          rect.isEmpty ||
          !rect.overlaps(Offset.zero & root.size)) {
        return null;
      }
      return rect;
    } on FlutterError {
      return null;
    }
  }

  Object _register(String id, GlobalKey key) {
    final owner = Object();
    _bindings[id] = _Binding(key, owner);
    return owner;
  }

  void _unregister(String id, Object owner) {
    if (identical(_bindings[id]?.owner, owner)) _bindings.remove(id);
  }
}

class _Binding {
  const _Binding(this.key, this.owner);
  final GlobalKey key;
  final Object owner;
}

class GuidedAnchor extends StatefulWidget {
  const GuidedAnchor(
      {super.key, required this.id, required this.child, this.registry});
  final String id;
  final Widget child;
  final GuidedAnchorRegistry? registry;
  @override
  State<GuidedAnchor> createState() => _GuidedAnchorState();
}

class _GuidedAnchorState extends State<GuidedAnchor> {
  final GlobalKey _key = GlobalKey(debugLabel: 'guided-anchor');
  Object? _owner;
  GuidedAnchorRegistry get _registry =>
      widget.registry ?? GuidedAnchorRegistry.shared;
  @override
  void initState() {
    super.initState();
    _owner = _registry._register(widget.id, _key);
  }

  @override
  void didUpdateWidget(covariant GuidedAnchor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.id != widget.id || oldWidget.registry != widget.registry) {
      (oldWidget.registry ?? GuidedAnchorRegistry.shared)
          ._unregister(oldWidget.id, _owner!);
      _owner = _registry._register(widget.id, _key);
    }
  }

  @override
  void dispose() {
    _registry._unregister(widget.id, _owner!);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      KeyedSubtree(key: _key, child: widget.child);
}
