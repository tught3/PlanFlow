// QA transport only: no auth, state, router, DB, speech or widget-tap claim.
import 'dart:async';
import 'dart:io';
import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';
import 'package:home_widget/home_widget.dart';
import 'transport_receipt_store.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  if (!Platform.isIOS) {
    debugPrint('WIDGET_TRANSPORT_SKIPPED non_ios');
    return;
  }
  runApp(const MaterialApp(home: TransportProbe()));
}

class TransportProbe extends StatefulWidget {
  const TransportProbe({super.key});
  @override
  State<TransportProbe> createState() => _TransportProbeState();
}

class _TransportProbeState extends State<TransportProbe> {
  final TransportSourceContext lifecycle = TransportSourceContext();
  final AppLinks links = AppLinks();
  final TransportReceiptStore store = TransportReceiptStore();
  StreamSubscription<Uri>? appSub;
  StreamSubscription<Uri?>? widgetSub;
  String last = 'Waiting for native receipt';
  Future<void> safe(Future<void> operation, String label) async {
    try {
      await operation;
      if (mounted) setState(() => last = label);
    } catch (_) {
      debugPrint('WIDGET_TRANSPORT_SINK_ERROR');
      if (mounted) setState(() => last = 'Sink error');
    }
  }

  void record(String source, Uri? uri) {
    final epoch = lifecycle.epoch;
    unawaited(safe(
        lifecycle.dispatch(
            epoch,
            () => store.record(source, uri,
                active: () => lifecycle.valid(epoch))),
        'Receipt checked: $source'));
  }

  void streamError(String source) {
    final epoch = lifecycle.epoch;
    unawaited(safe(
        lifecycle.dispatch(
            epoch,
            () => store.outcome(source, 'ERROR',
                reason: 'stream', active: () => lifecycle.valid(epoch))),
        'Stream error: $source'));
  }

  @override
  void initState() {
    super.initState();
    unawaited(start());
  }

  Future<void> start() async {
    final epoch = lifecycle.epoch;
    try {
      await store.boot();
    } catch (_) {
      debugPrint('WIDGET_TRANSPORT_SINK_ERROR');
      return;
    }
    if (!lifecycle.valid(epoch)) return;
    appSub = links.uriLinkStream.listen((uri) => record('applinks_warm', uri),
        onError: (Object _) => streamError('applinks_warm'));
    widgetSub = HomeWidget.widgetClicked.listen(
        (uri) => record('homewidget_warm', uri),
        onError: (Object _) => streamError('homewidget_warm'));
    await safe(store.ready(), 'Ready');
    await lifecycle.ready(epoch);
    if (!mounted) return;
    await Future.wait([
      initial('homewidget_initial',
          () => HomeWidget.initiallyLaunchedFromHomeWidget()),
      initial('applinks_initial', () => links.getInitialLink()),
    ]);
  }

  Future<void> initial(String source, Future<Uri?> Function() getter) async {
    final epoch = lifecycle.epoch;
    if (!lifecycle.valid(epoch)) return;
    try {
      final uri = await getter().timeout(const Duration(seconds: 10));
      if (!lifecycle.valid(epoch)) return;
      await safe(
          store.record(source, uri, active: () => lifecycle.valid(epoch)),
          'Initial checked: $source');
    } on TimeoutException {
      await safe(
          store.outcome(source, 'ERROR',
              reason: 'timeout', active: () => lifecycle.valid(epoch)),
          'Initial timeout: $source');
    } catch (_) {
      await safe(
          store.outcome(source, 'ERROR',
              reason: 'plugin', active: () => lifecycle.valid(epoch)),
          'Initial error: $source');
    }
  }

  Future<void> shutdown() async {
    await Future.wait([
      appSub?.cancel() ?? Future<void>.value(),
      widgetSub?.cancel() ?? Future<void>.value()
    ]);
    await store.drain();
  }

  @override
  void dispose() {
    lifecycle.dispose();
    unawaited(shutdown());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      Scaffold(body: Center(child: Text(last)));
}
