// QA transport only: no auth, app state, router, DB, speech or widget-tap claim.
import 'dart:async';
import 'dart:io';
import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';
import 'package:home_widget/home_widget.dart';

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
  final AppLinks links = AppLinks();
  StreamSubscription<Uri>? appSub;
  StreamSubscription<Uri?>? widgetSub;
  String last = 'Waiting for native URI';
  void record(String source, Uri? uri) {
    if (uri == null || uri.scheme != 'planflow') return;
    final qaNonce = uri.queryParameters['qaToken'];
    if (qaNonce == null || !RegExp(r'^[a-z0-9_]+$').hasMatch(qaNonce)) return;
    final validTarget = (uri.host == 'day' && uri.path == '/2026-10-14') ||
        (uri.host == 'voice-launcher' && uri.path.isEmpty);
    if (!validTarget) return;
    debugPrint(
        'WIDGET_TRANSPORT_RECEIVED source=$source token=$qaNonce uri=$uri');
    if (mounted) setState(() => last = '$source\n$uri');
  }

  @override
  void initState() {
    super.initState();
    appSub = links.uriLinkStream.listen((uri) => record('applinks_warm', uri));
    widgetSub = HomeWidget.widgetClicked
        .listen((uri) => record('homewidget_warm', uri));
    unawaited(initial());
    debugPrint('WIDGET_TRANSPORT_READY ios=true');
  }

  Future<void> initial() async {
    record('homewidget_initial',
        await HomeWidget.initiallyLaunchedFromHomeWidget());
    record('applinks_initial', await links.getInitialLink());
  }

  @override
  void dispose() {
    unawaited(appSub?.cancel() ?? Future<void>.value());
    unawaited(widgetSub?.cancel() ?? Future<void>.value());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      Scaffold(body: Center(child: Text(last)));
}
