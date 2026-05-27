import 'package:flutter/material.dart';

class AppFeedbackService {
  AppFeedbackService._();

  static final scaffoldMessengerKey = GlobalKey<ScaffoldMessengerState>();
  static OverlayEntry? _currentEntry;

  static void showSnackBar(String message, {BuildContext? context}) {
    final effectiveContext = context ?? scaffoldMessengerKey.currentContext;
    final overlay = effectiveContext == null
        ? null
        : Overlay.maybeOf(effectiveContext, rootOverlay: true);
    if (effectiveContext == null || overlay == null) {
      debugPrint('App feedback skipped: $message');
      return;
    }

    _currentEntry?.remove();
    _currentEntry = OverlayEntry(
      builder: (context) {
        final mediaQuery = MediaQuery.of(context);
        return Positioned(
          top: mediaQuery.padding.top + 12,
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
