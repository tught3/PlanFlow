import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

class AppFeedbackService {
  AppFeedbackService._();

  static final scaffoldMessengerKey = GlobalKey<ScaffoldMessengerState>();
  static OverlayEntry? _currentEntry;

  /// A guide save notice must be above the coachmark, which itself sits above
  /// the Navigator overlay used by [showSnackBar].
  static VoidCallback? showGuideSaveBlocked({
    required BuildContext context,
    required String reasonCode,
    required String message,
  }) {
    return context.findAncestorStateOfType<_GuideSaveFeedbackHostState>()?.show(
          reasonCode: reasonCode,
          message: message,
        );
  }

  static void showSnackBar(String message, {BuildContext? context}) {
    final effectiveContext = context ?? scaffoldMessengerKey.currentContext;
    final overlay = effectiveContext == null
        ? null
        : Overlay.maybeOf(effectiveContext, rootOverlay: true);
    if (effectiveContext == null || overlay == null) {
      final messenger = scaffoldMessengerKey.currentState;
      if (messenger != null) {
        messenger
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(content: Text(message)));
        return;
      }
      if (effectiveContext != null) {
        final scopedMessenger = ScaffoldMessenger.maybeOf(effectiveContext);
        if (scopedMessenger != null) {
          scopedMessenger
            ..hideCurrentSnackBar()
            ..showSnackBar(SnackBar(content: Text(message)));
          return;
        }
      }
      debugPrint('App feedback skipped: $message');
      return;
    }

    _currentEntry?.remove();
    _currentEntry = OverlayEntry(
      builder: (context) {
        final mediaQuery = MediaQuery.of(context);
        return Positioned(
          top: mediaQuery.padding.top + kToolbarHeight + 8,
          left: 16,
          right: 16,
          child: IgnorePointer(
            child: Material(
              color: Colors.transparent,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: const Color(0xFF132847),
                  borderRadius: BorderRadius.circular(14),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x33000000),
                      blurRadius: 18,
                      offset: Offset(0, 8),
                    ),
                  ],
                ),
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  child: Text(
                    message,
                    style: const TextStyle(color: Colors.white, fontSize: 13),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
    final entry = _currentEntry!;
    overlay.insert(entry);
    if (_isRunningWidgetTest) {
      return;
    }
    Future<void>.delayed(const Duration(seconds: 3), () {
      if (_currentEntry == entry) {
        entry.remove();
        _currentEntry = null;
      }
    });
  }

  static bool get _isRunningWidgetTest {
    final bindingType = WidgetsBinding.instance.runtimeType.toString();
    return bindingType.contains('TestWidgetsFlutterBinding');
  }
}

/// Paints save feedback above both the Navigator and the guide's coachmark.
class GuideSaveFeedbackHost extends StatefulWidget {
  const GuideSaveFeedbackHost({super.key, required this.child});

  final Widget child;

  @override
  State<GuideSaveFeedbackHost> createState() => _GuideSaveFeedbackHostState();
}

class _GuideSaveFeedbackHostState extends State<GuideSaveFeedbackHost> {
  static const _showReasonCode =
      kDebugMode && bool.fromEnvironment('PLANFLOW_ISOLATED_GUIDE_QA');

  ({Object id, String reasonCode, String message})? _notice;
  Timer? _dismissTimer;

  VoidCallback show({required String reasonCode, required String message}) {
    _dismissTimer?.cancel();
    final id = Object();
    setState(() => _notice = (id: id, reasonCode: reasonCode, message: message));

    void dismiss() {
      if (!mounted || !identical(_notice?.id, id)) return;
      _dismissTimer?.cancel();
      setState(() => _notice = null);
    }

    _dismissTimer = Timer(const Duration(seconds: 5), dismiss);
    return dismiss;
  }

  @override
  void dispose() {
    _dismissTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final notice = _notice;
    return Stack(
      fit: StackFit.expand,
      children: [
        widget.child,
        if (notice != null)
          Positioned(
            top: MediaQuery.paddingOf(context).top + kToolbarHeight + 8,
            left: 16,
            right: 16,
            child: IgnorePointer(
              child: Semantics(
                key: const ValueKey('guide-step2-save-feedback'),
                liveRegion: true,
                child: Material(
                  color: const Color(0xFF132847),
                  elevation: 8,
                  borderRadius: BorderRadius.circular(14),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 12),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(notice.message,
                            style: const TextStyle(color: Colors.white)),
                        if (_showReasonCode)
                          Text(notice.reasonCode,
                              style: const TextStyle(
                                  color: Colors.white70, fontSize: 12)),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
