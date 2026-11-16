import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/safe_prefs.dart';
import '../../data/repositories/event_repository.dart';
import '../../providers/auth_provider.dart';
import '../../widgets/guided_anchor.dart';
import 'guide_contract.dart';
import 'guide_coordinator.dart';
import 'guide_guards.dart';
import 'guide_local_backend.dart';

final realUiGuideAnchorRegistry = GuidedAnchorRegistry();
final realUiGuideProgressStoreProvider =
    Provider<GuideProgressStore>((ref) => LocalGuideProgressStore());
final realUiGuideBackendProvider =
    Provider<GuideBackendPort>((ref) => LocalGuideBackend(
          progress: ref.watch(realUiGuideProgressStoreProvider),
          fetchBoundEvent: (uid, id) async {
            if (!authProvider.hasActiveSession || authProvider.userId != uid) {
              return null;
            }
            final event = await SupabaseEventRepository()
                .fetchEvent(id, userId: uid, requireGuideEligibility: true)
                .timeout(const Duration(seconds: 15));
            return authProvider.hasActiveSession && authProvider.userId == uid
                ? event
                : null;
          },
        ));
final realUiGuideCoordinatorProvider = Provider<GuideCoordinator>((ref) =>
    RealUiGuideCoordinator(
        backend: ref.watch(realUiGuideBackendProvider),
        progress: ref.watch(realUiGuideProgressStoreProvider),
        version: realUiGuideVersion));

class LocalGuideProgressStore implements GuideProgressStore {
  Future<void> _saveQueue = Future<void>.value();

  String key(String uid, String version) => 'guide_progress:$version:$uid';
  @override
  Future<GuideSnapshot?> load(
      {required String uid, required String version}) async {
    final prefs = await tryGetPrefs();
    if (prefs == null) throw StateError('Guide storage unavailable');
    final raw = prefs.getString(key(uid, version));
    if (raw == null) return null;
    final m = jsonDecode(raw) as Map<String, dynamic>;
    DateTime? date(String k) => DateTime.tryParse(m[k] as String? ?? '');
    return GuideSnapshot(
        uid: uid,
        version: version,
        revision: m['revision'] as int,
        serverRevision: m['serverRevision'] as int,
        step: GuideStep.values.byName(m['step'] as String),
        run: GuideRun.values.byName(m['run'] as String),
        sessionId: m['sessionId'] as String?,
        createdEventId: m['createdEventId'] as String?,
        savedCreateOperationId: m['savedCreateOperationId'] as String?,
        dateTimeZone: m['dateTimeZone'] as String?,
        errorCode: m['errorCode'] as String?,
        failureDiagnostic:
            GuideFailureDiagnostic.fromJson(m['failureDiagnostic']),
        savedLocalDate: date('savedLocalDate'),
        originalStartLocal: date('originalStartLocal'),
        expectedUpdatedStartLocal: date('expectedUpdatedStartLocal'),
        isReplay: m['isReplay'] == true,
        calendarSyncHeld: m['calendarSyncHeld'] == true);
  }

  @override
  Future<void> save(GuideSnapshot s) {
    final operation = _saveQueue.then((_) => _save(s));
    // Keep the queue moving while the caller still receives the save error.
    _saveQueue = operation.catchError((Object _) {});
    return operation;
  }

  Future<void> _save(GuideSnapshot s) async {
    final prefs = await tryGetPrefs();
    if (prefs == null) throw StateError('Guide storage unavailable');
    final storageKey = key(s.uid, s.version);
    final raw = jsonEncode({
      'revision': s.revision,
      'serverRevision': s.serverRevision,
      'step': s.step.name,
      'run': s.run.name,
      'sessionId': s.sessionId,
      'createdEventId': s.createdEventId,
      'savedCreateOperationId': s.savedCreateOperationId,
      'dateTimeZone': s.dateTimeZone,
      'errorCode': s.errorCode,
      if (s.failureDiagnostic != null)
        'failureDiagnostic': s.failureDiagnostic!.toJson(),
      'savedLocalDate': s.savedLocalDate?.toIso8601String(),
      'originalStartLocal': s.originalStartLocal?.toIso8601String(),
      'expectedUpdatedStartLocal':
          s.expectedUpdatedStartLocal?.toIso8601String(),
      'isReplay': s.isReplay,
      'calendarSyncHeld': s.calendarSyncHeld
    });
    if (!await prefs.setString(storageKey, raw)) {
      throw StateError('Guide write readback failed');
    }
    if (prefs.getString(storageKey) == raw) return;

    await Future<void>.delayed(const Duration(milliseconds: 20));
    if (!await prefs.setString(storageKey, raw) ||
        prefs.getString(storageKey) != raw) {
      throw StateError('Guide write readback failed');
    }
  }
}
