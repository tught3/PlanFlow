// Manual native QA entry. Parent harness owns the device, runtime JSON and
// one-use app-private command files. This runner never synthesizes UI input.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/rendering.dart'
    show
        MatrixUtils,
        RenderAbstractViewport,
        RenderBox,
        RenderOffstage,
        RenderObject,
        SemanticsHandle;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:planflow/app.dart';
import 'package:planflow/core/env.dart';
import 'package:planflow/onboarding/real_ui_guide/guide_contract.dart';
import 'package:planflow/onboarding/real_ui_guide/guide_providers.dart';
import 'package:planflow/onboarding/real_ui_guide/guide_scope.dart';
import 'package:planflow/onboarding/real_ui_guide/guide_providers.dart';
import 'package:planflow/onboarding/real_ui_guide/guide_host.dart'
    show RealUiGuideCoachmark;

import 'support/real_ui_guide_manual_resume.dart';
import 'support/real_ui_guide_native_environment.dart';

const _phases = <String>{
  'bootstrap',
  'create',
  'save',
  'query',
  'change',
  'editSave',
  'done',
};
const _poll = Duration(milliseconds: 300);

/// Compile-time opt-in of the manual cold-relaunch resume path. When it is
/// on, the entry point never waits for the one-use runtime file.
const bool _forceManualResume =
    bool.fromEnvironment('PLANFLOW_GUIDE_QA_MANUAL_RESUME');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final env = await awaitManualGuideEnvironment(_openEnvironment);
  if (env == null) return; // Fail-closed startup screen is already up.
  SemanticsHandle? semantics;
  Timer? anchorDiagnostics;
  ProviderContainer? qaContainer;
  try {
    await env.run(() async {
      await env.bootstrap();
      semantics = WidgetsFlutterBinding.ensureInitialized().ensureSemantics();
      final container = ProviderContainer();
      qaContainer = container;
      env.manualGuideSnapshot =
          () => container.read(realUiGuideCoordinatorProvider).state.value;
      runApp(UncontrolledProviderScope(
          container: container, child: PlanFlowApp.forGuideQa()));
      final diagnostics = _AnchorDiagnostics(env.directory);
      anchorDiagnostics = Timer.periodic(_diagInterval, (_) {
        try {
          diagnostics.tick();
        } catch (error) {
          // Exception type only: no FlutterError text, widget trees or keys.
          debugPrint('ANCHOR_DIAG_ERROR ${error.runtimeType}');
        }
      });
      await env.journal('MANUAL_APP_READY');

      // A fresh run ends at min(30 min window, token expiry). A manual cold
      // resume reuses the deadline of the original run and never extends it.
      final expires = env.sessionDeadline;
      var sequence = 0;
      while (DateTime.now().isBefore(expires)) {
        final file = File(
            '${env.directory.path}/native-guide-${env.runId}-manual.control.json');
        if (!await file.exists()) {
          await Future<void>.delayed(_poll);
          continue;
        }
        if (await file.length() > 4096) env.deny();
        final raw = await file.readAsString();
        await file.delete(); // one-use command; never replay on parse/error
        final value = jsonDecode(raw);
        if (value is! Map<String, dynamic> ||
            value['runId'] != env.runId ||
            value.keys.any(
                (k) => !{'runId', 'command', 'phase', 'label'}.contains(k)) ||
            value.containsKey('transcript') ||
            value.containsKey('payload')) {
          env.deny();
        }
        final command = value['command'];
        if (command == 'SET_PHASE') {
          final phase = value['phase'];
          if (phase is! String || !_phases.contains(phase)) {
            env.deny();
          }
          env.ensureOperatorPhaseChangeAllowed();
          env.phase = phase;
          await env.journal('PHASE_SET');
        } else if (command == 'SNAPSHOT_QUOTA') {
          final label = value['label'];
          if (label is! String ||
              !RegExp(r'^[A-Za-z0-9_-]{1,32}$').hasMatch(label)) {
            env.deny();
          }
          final counts = await env.quotaSnapshot();
          await _writeReply(env, ++sequence, {
            'runId': env.runId,
            'command': 'SNAPSHOT_QUOTA',
            'label': label,
            'snapshot': counts,
          });
          await env.journal('QUOTA_SNAPSHOT');
        } else if (command == 'CLOSE') {
          final closeSequence = ++sequence;
          await runManualCloseSequence(
            latchEnvironment: () async {
              env.failed = true;
            },
            writeClosedReply: () => _writeReply(
                env, closeSequence, {'runId': env.runId, 'command': 'CLOSED'}),
            journalClosed: () => env.journal('CLOSED'),
            paintClosedScreen: () =>
                runApp(GuideQaRecoveryApp(reason: _closedReason)),
          );
          return;
        } else {
          env.deny();
        }
      }
      env.failed = true;
      await env.journal('MANUAL_SESSION_TIMEOUT');
      // Swap the write-enabled tree for the recovery screen before the fence
      // is closed.
      runApp(const GuideQaRecoveryApp(reason: _timeoutReason));
      return;
    });
  } catch (error) {
    env.failed = true;
    try {
      await env.journal('FAIL');
    } catch (_) {}
    // A fence or ledger failure must never escape as an unhandled main crash:
    // the write-enabled tree is swapped for the recovery screen instead.
    debugPrint('MANUAL_START_ERROR $error');
    _paintRecovery(error);
  } finally {
    env.failed = true;
    env.manualGuideSnapshot = null;
    qaContainer?.dispose();
    anchorDiagnostics?.cancel();
    anchorDiagnostics = null;
    semantics?.dispose();
    try {
      await env.close();
    } catch (_) {}
  }
}

const _timeoutReason = 'The 30-minute guide QA session window ended.';

/// Credential-free closed label for the commanded CLOSE path.
const _closedReason = 'The guide QA run is closed.';

/// Startup phase of the manual entry point, extracted as the seam the focused
/// contract test drives with an injected loader.
///
/// The credential-free, noninteractive waiting view is painted BEFORE the
/// loader is awaited, so neither the fresh one-use load wait (default 45 s,
/// semantics unchanged) nor a secure resume read can sit on the native
/// splash/logo. On loader failure the fail-closed recovery screen replaces it
/// and null is returned. No auth, no writes, and no endOfFrame await (the
/// engine may be running with background frames disabled).
Future<NativeGuideEnvironment?> awaitManualGuideEnvironment(
    Future<NativeGuideEnvironment> Function() openEnvironment) async {
  runApp(const GuideQaStartupApp());
  try {
    return await openEnvironment();
  } catch (error) {
    // Startup failures must paint an actionable fail-closed screen rather
    // than leave Android on the native splash. Never display details.
    debugPrint('MANUAL_START_ERROR $error');
    _paintRecovery(error);
    return null;
  }
}

/// CLOSE ordering of the manual run, fail-closed. Executed strictly in this
/// order and always inside the [NativeGuideEnvironment.run] fence:
///
/// 1. Latch the environment first. Every later client send checks `failed`
///    and is denied immediately, even while the recovery frame is still
///    pending and the old tree is briefly still mounted.
/// 2. One-use CLOSED reply and CLOSED journal entry (harness cleanup).
/// 3. Swap the write-enabled tree for the credential-free closed screen
///    BEFORE returning: `run()`'s finally restores HttpOverrides and releases
///    the exclusive lock, so the swap must happen while the fence is still up.
///
/// The steps are injected so the focused contract test can pin the exact
/// ordering without a device; the CLOSE branch passes the real operations.
Future<void> runManualCloseSequence({
  required Future<void> Function() latchEnvironment,
  required Future<void> Function() writeClosedReply,
  required Future<void> Function() journalClosed,
  required void Function() paintClosedScreen,
}) async {
  await latchEnvironment();
  await writeClosedReply();
  await journalClosed();
  paintClosedScreen();
}

/// Fresh-start open with the minimal missing-marker fallback, extracted as
/// the seam the focused contract test drives with injected loaders.
///
/// [loadFresh] is the unchanged default one-use
/// `NativeGuideEnvironment.load`: it still waits its full 45 s window for
/// the controller-provisioned runtime file, so a late fresh provisioning
/// is never skipped. Only when that wait ends with the exact
/// `Runtime missing` timeout - no runtime file ever appeared and no
/// consumed-marker hint was written (an older fresh run or a failed marker
/// write) - is the validated secure manual resume tried once as the last
/// authorized path. Every other failure is rethrown unchanged, and a
/// failing resume propagates its fail-closed [ManualResumeException] so
/// the credential-free recovery screen is painted.
Future<NativeGuideEnvironment> openFreshWithMissingMarkerFallback({
  required Future<NativeGuideEnvironment> Function() loadFresh,
  required Future<NativeGuideEnvironment> Function() loadManualResume,
}) async {
  try {
    return await loadFresh();
  } on StateError catch (error) {
    if (!isRuntimeMissingTimeout(error)) rethrow;
    return loadManualResume();
  }
}

const _recoveryBody =
    'Real UI guide QA is unavailable or its 30-minute session ended. '
    'The safety fence is closed. Return to the QA controller and start a '
    'newly authorized run in a fresh app context; do not retry this session.';

/// Opens the QA environment for this launch.
///
/// * A cold relaunch (a previous fresh start consumed the one-use runtime
///   file) restores the persisted session and never waits for that file.
/// * A fresh start keeps the default one-use behaviour of
///   [NativeGuideEnvironment.load] and stores the manual resume state.
/// * If that one-use wait ends with the exact `Runtime missing` timeout and
///   no consumed-marker hint exists (an older fresh run from before the
///   marker fix, or a failed marker write), the validated secure resume is
///   tried once as the last authorized path so usable persisted state does
///   not degrade into a wait-then-recovery loop. It fails closed when no
///   usable state exists, and every other load failure is unchanged.
///
/// The phase protocol is unchanged: a resumed run starts at `bootstrap` and
/// is never armed automatically. The durable budget ledger keeps its
/// consumption; nothing is reset and no AI permit is carried over.
Future<NativeGuideEnvironment> _openEnvironment() async {
  const runtimePath = String.fromEnvironment('PLANFLOW_GUIDE_QA_RUNTIME');
  final runtimeFile = runtimePath.isEmpty ? null : File(runtimePath);
  final marker = _consumedMarkerFile(runtimePath.isEmpty ? null : runtimePath);
  final runtimePresent = runtimeFile != null && await runtimeFile.exists();
  final markerPresent = marker != null && await marker.exists();
  final mode = decideManualStartupMode(
    forceResume: _forceManualResume,
    runtimeFilePresent: runtimePresent,
    consumedMarkerPresent: markerPresent,
  );
  if (mode == ManualStartupMode.manualResume) {
    return NativeGuideEnvironment.loadManualResume(
      store: FlutterSecureResumeStore(),
      now: DateTime.now(),
      expectedBackendHost: Uri.parse(AppEnv.supabaseUrl).host,
    );
  }
  final env = await openFreshWithMissingMarkerFallback(
    loadFresh: NativeGuideEnvironment.load,
    loadManualResume: () => NativeGuideEnvironment.loadManualResume(
      store: FlutterSecureResumeStore(),
      now: DateTime.now(),
      expectedBackendHost: Uri.parse(AppEnv.supabaseUrl).host,
    ),
  );
  await _persistResumeState(env, marker);
  return env;
}

/// Stores the secure resume state of a fresh run and marks the one-use
/// runtime file as consumed. Both writes are best effort: when they fail the
/// next cold relaunch fails closed with the recovery screen.
Future<void> _persistResumeState(
    NativeGuideEnvironment env, File? marker) async {
  try {
    await env.persistManualResumeRecord(store: FlutterSecureResumeStore());
  } catch (_) {
    // Secure storage unavailable: a later relaunch fails closed.
  }
  if (marker == null) return;
  try {
    await marker.writeAsString(
      jsonEncode({
        'runId': env.runId,
        'consumedAt': DateTime.now().toIso8601String(),
      }),
      flush: true,
    );
  } catch (_) {
    // The marker is only a hint for the next launch.
  }
}

File? _consumedMarkerFile(String? runtimePath) {
  if (runtimePath == null || runtimePath.isEmpty) return null;
  final markerPath = consumedMarkerPathForRuntime(runtimePath);
  return markerPath == null ? null : File(markerPath);
}

void _paintRecovery(Object error) {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(GuideQaRecoveryApp(reason: _recoveryReason(error)));
}

/// Credential-free reason label. Exception details are never shown.
String _recoveryReason(Object error) {
  if (error is ManualResumeException) {
    switch (error.failure) {
      case ManualResumeFailure.sessionExpired:
        return 'The saved guide QA session has expired.';
      case ManualResumeFailure.deadlineExpired:
        return 'The saved guide QA session deadline has passed.';
      case ManualResumeFailure.recordMissing:
        return 'No saved guide QA session is available for this relaunch.';
      case ManualResumeFailure.recordCorrupt:
        return 'The saved guide QA session is unreadable.';
      case ManualResumeFailure.secureStorageUnavailable:
        return 'Secure storage is unavailable on this device.';
      case ManualResumeFailure.sessionMissing:
        return 'The saved guide QA session has no usable session.';
      case ManualResumeFailure.uidMismatch:
      case ManualResumeFailure.sessionUidMismatch:
      case ManualResumeFailure.backendMismatch:
      case ManualResumeFailure.budgetMismatch:
      case ManualResumeFailure.maxRequestsMismatch:
      case ManualResumeFailure.dedicatedAccountMissing:
      case ManualResumeFailure.deadlineWidened:
        return 'The saved guide QA session does not match the approved QA scope.';
    }
  }
  return 'The guide QA session could not be restored.';
}

/// Credential-free, noninteractive waiting view shown while the QA
/// environment opens and while bootstrap connects. No input targets, no
/// auth, no writes.
class GuideQaStartupApp extends StatelessWidget {
  const GuideQaStartupApp({super.key});

  @override
  Widget build(BuildContext context) => Directionality(
        textDirection: TextDirection.ltr,
        child: ColoredBox(
          color: const Color(0xFF101820),
          child: Center(
            child: Text('QA 연결 확인 중',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Color(0xFFFFFFFF), fontSize: 18)),
          ),
        ),
      );
}

/// Credential-free QA screen for startup failure, session timeout and the
/// commanded CLOSE. Fully static: no input targets, no callbacks, no writes.
class GuideQaRecoveryApp extends StatelessWidget {
  const GuideQaRecoveryApp({super.key, required this.reason});

  /// Credential-free, actionable reason.
  final String reason;

  @override
  Widget build(BuildContext context) => Directionality(
        textDirection: TextDirection.ltr,
        child: ColoredBox(
          color: const Color(0xFF101820),
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                '$reason\n\n$_recoveryBody',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Color(0xFFFFFFFF), fontSize: 18),
              ),
            ),
          ),
        ),
      );
}

Future<void> _writeReply(
  NativeGuideEnvironment env,
  int sequence,
  Map<String, Object?> reply,
) async {
  final file = File(
      '${env.directory.path}/native-guide-${env.runId}-manual-reply-$sequence.json');
  if (await file.exists()) env.deny();
  await file.writeAsString(jsonEncode(reply), flush: true);
}

// Read-only guide anchor diagnostics.
//
// Observes `realUiGuideAnchorRegistry` only: registration, mount state, modal
// route currency, TickerMode, render box geometry, ancestor viewports, offstage
// and the live coordinator step. It never taps, dispatches a guide signal,
// issues a request, touches the control files or mutates production code.
// Each probe mirrors the same public calls `RealUiGuideCoachmark` uses, so a
// differing verdict here is the reason the coachmark renders its missing
// target fallback. Geometry is rounded to 0.1 logical px to suppress sub-pixel
// churn and a snapshot is printed only when its encoded form actually changes.
const _diagInterval = Duration(seconds: 2);
const _diagAnchorIds = <String>[
  'home.mic',
  'query.mic',
  'voice.review',
  'saved.summary',
  'saved.departure',
];
const _diagMaxViewports = 4;
const _diagMaxAncestors = 96;

class _AnchorDiagnostics {
  _AnchorDiagnostics(this.directory);
  final Directory directory;
  String? _lastSignature;
  var _sequence = 0;
  Element? _guideScope;

  void tick() {
    final anchors = <String, Object?>{};
    for (final id in _diagAnchorIds) {
      anchors[id] = _anchor(id);
    }
    final guide = _guide();
    final coachmark = _coachmarkGeometry();
    final signature = jsonEncode(
        {'anchors': anchors, 'guide': guide, 'coachmark': coachmark});
    if (signature == _lastSignature) return;
    _lastSignature = signature;
    _sequence++;
    final record = {
      'event': 'ANCHOR_DIAG',
      'seq': _sequence,
      'ts': DateTime.now().toIso8601String(),
      'anchors': anchors,
      'guide': guide,
      'coachmark': coachmark
    };
    // App debug logging truncates long lines. Preserve geometry without any
    // transcript/credential data in the app-private diagnostic file instead.
    File('${directory.path}/native-guide-anchor-diagnostics.json')
        .writeAsStringSync(jsonEncode(record), flush: true);
    debugPrint('ANCHOR_DIAG seq=$_sequence step=${guide['step']} '
        'root=${coachmark['self']}');
  }

  Map<String, Object?> _coachmarkGeometry() {
    final scope = _guideScope;
    if (scope == null || !scope.mounted) return {'present': false};
    Element? found;
    var visited = 0;
    void visit(Element element) {
      if (found != null || ++visited > 5000) return;
      if (element.widget is RealUiGuideCoachmark) {
        found = element;
        return;
      }
      element.visitChildElements(visit);
    }

    scope.visitChildElements(visit);
    final element = found;
    if (element == null) return {'present': false};
    Map<String, Object?> geometry(RenderBox? box) {
      if (box == null || !box.attached || !box.hasSize) return {'ready': false};
      final p = box.localToGlobal(Offset.zero);
      return {
        'type': box.runtimeType.toString(),
        'w': box.size.width,
        'h': box.size.height,
        'x': p.dx,
        'y': p.dy
      };
    }

    final object = element.findRenderObject();
    final self = object is RenderBox ? object : null;
    final parent = element.findAncestorRenderObjectOfType<RenderBox>();
    final report = <String, Object?>{
      'present': true,
      'self': geometry(self),
      'parent': geometry(parent)
    };
    final target = realUiGuideAnchorRegistry
        .keyFor('voice.review')
        ?.currentContext
        ?.findRenderObject();
    if (self != null && self.hasSize && target is RenderBox && target.hasSize) {
      try {
        final rect = MatrixUtils.transformRect(
            target.getTransformTo(self), Offset.zero & target.size);
        final visible = rect.intersect(Offset.zero & self.size);
        report['voiceInSelf'] = {
          'x': rect.left,
          'y': rect.top,
          'w': rect.width,
          'h': rect.height,
          'visibleW': visible.width,
          'visibleH': visible.height
        };
      } catch (error) {
        report['transformError'] = error.runtimeType.toString();
      }
    }
    return report;
  }

  Map<String, Object?> _anchor(String id) {
    final errors = <String>[];
    final report = <String, Object?>{
      'registered': false,
      'hasContext': false,
      'mounted': false,
      'routeCurrent': null,
      'routeType': null,
      'tickerEnabled': null,
      'isRenderBox': false,
      'attached': false,
      'hasSize': false,
      'size': null,
      'globalRect': null,
      'viewports': <Map<String, Object?>>[],
      'offstageWidget': false,
      'offstageRender': false,
    };
    final key = realUiGuideAnchorRegistry.keyFor(id);
    report['registered'] = key != null;
    final context = key?.currentContext;
    report['hasContext'] = context != null;
    if (context == null) return _seal(report, errors);

    var mounted = false;
    try {
      mounted = context.mounted;
    } catch (error) {
      errors.add('mounted:${error.runtimeType}');
    }
    report['mounted'] = mounted;
    if (!mounted) return _seal(report, errors);

    try {
      final route = ModalRoute.of(context);
      report['routeCurrent'] = route?.isCurrent;
      report['routeType'] = route.runtimeType.toString();
    } catch (error) {
      errors.add('route:${error.runtimeType}');
    }

    try {
      report['tickerEnabled'] = TickerMode.valuesOf(context).enabled;
    } catch (error) {
      errors.add('ticker:${error.runtimeType}');
    }

    var offstageWidget = false;
    try {
      context.visitAncestorElements((element) {
        final widget = element.widget;
        if (widget is Offstage && widget.offstage) {
          offstageWidget = true;
          return false;
        }
        return true;
      });
    } catch (error) {
      errors.add('visitAncestor:${error.runtimeType}');
    }
    report['offstageWidget'] = offstageWidget;

    RenderObject? object;
    try {
      object = context.findRenderObject();
    } catch (error) {
      errors.add('findRenderObject:${error.runtimeType}');
    }
    if (object is RenderBox) {
      report['isRenderBox'] = true;
      report['attached'] = object.attached;
      report['hasSize'] = object.hasSize;
      if (object.hasSize) {
        report['size'] = {
          'w': _round(object.size.width),
          'h': _round(object.size.height),
        };
        try {
          final rect = object.localToGlobal(Offset.zero) & object.size;
          report['globalRect'] = {
            'l': _round(rect.left),
            't': _round(rect.top),
            'w': _round(rect.width),
            'h': _round(rect.height),
          };
        } catch (error) {
          errors.add('globalRect:${error.runtimeType}');
        }
      }
    }

    final viewports = <Map<String, Object?>>[];
    var offstageRender = false;
    var node = object?.parent;
    var visited = 0;
    while (node != null && visited < _diagMaxAncestors) {
      visited++;
      if (node is RenderOffstage && node.offstage) offstageRender = true;
      if (node is RenderAbstractViewport &&
          viewports.length < _diagMaxViewports) {
        final viewport = node as RenderBox;
        viewports.add({
          'type': node.runtimeType.toString(),
          'attached': viewport.attached,
          'hasSize': viewport.hasSize,
          'w': viewport.hasSize ? _round(viewport.size.width) : null,
          'h': viewport.hasSize ? _round(viewport.size.height) : null,
        });
      }
      node = node.parent;
    }
    report['viewports'] = viewports;
    report['offstageRender'] = offstageRender;
    return _seal(report, errors);
  }

  Map<String, Object?> _guide() {
    final report = <String, Object?>{'probe': 'noAnchorContext'};
    // Public GuideScope lookup only: no coordinator dispatch, no private API.
    for (final id in _diagAnchorIds) {
      final context = realUiGuideAnchorRegistry.keyFor(id)?.currentContext;
      if (context == null) continue;
      Element? found;
      try {
        if (context.mounted) {
          found = context.getElementForInheritedWidgetOfExactType<GuideScope>();
        }
      } catch (error) {
        found = null;
      }
      if (found != null) {
        _guideScope = found;
        break;
      }
    }
    final scope = _guideScope;
    if (scope == null || !scope.mounted) {
      _guideScope = null;
      report['probe'] = 'guideScopeUnavailable';
      return report;
    }
    report['probe'] = 'guideScope';
    try {
      final coordinator = (scope.widget as GuideScope).coordinator;
      final GuideSnapshot snapshot = coordinator.state.value;
      report['step'] = snapshot.step.name;
      report['run'] = snapshot.run.name;
      report['revision'] = snapshot.revision;
      // Presence only: uid and sessionId are never printed.
      report['uidPresent'] = snapshot.uid.isNotEmpty;
      report['sessionPresent'] = snapshot.sessionId != null;
      report['errorCode'] = snapshot.errorCode;
    } catch (error) {
      report['error'] = error.runtimeType.toString();
    }
    return report;
  }

  Map<String, Object?> _seal(
          Map<String, Object?> report, List<String> errors) =>
      errors.isEmpty
          ? report
          : <String, Object?>{...report, 'probeErrors': errors};
}

double _round(double value) => (value * 10).roundToDouble() / 10;
