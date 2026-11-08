import '../../core/constants.dart';
import '../../data/models/event_model.dart';
import 'guide_contract.dart';
import 'guide_guards.dart';

/// A read-only route request. It is not guide evidence or an operation permit.
class GuideRouteRecovery {
  const GuideRouteRecovery(this.coordinator, this.snapshot, this.event);
  final GuideCoordinator coordinator;
  final GuideSnapshot snapshot;
  final EventModel event;

  bool isCurrent(GuideCoordinator? current, String? uid) {
    if (!identical(current, coordinator) || uid != snapshot.uid) return false;
    final s = current!.state.value;
    return s.uid == snapshot.uid && s.version == snapshot.version &&
        s.sessionId == snapshot.sessionId && s.revision == snapshot.revision &&
        s.serverRevision == snapshot.serverRevision &&
        s.createdEventId == snapshot.createdEventId &&
        s.step == snapshot.step && s.run == GuideRun.active;
  }

  static bool supports(GuideSnapshot s) => s.run == GuideRun.active &&
      s.sessionId != null && (s.createdEventId?.isNotEmpty ?? false) &&
      const {GuideStep.savedDetail, GuideStep.queryMic, GuideStep.querySpeech,
        GuideStep.queryResults, GuideStep.changeSpeech, GuideStep.editPreview,
        GuideStep.updatedDetail}.contains(s.step);

  bool get restoresResults => snapshot.step == GuideStep.queryResults ||
      snapshot.step == GuideStep.changeSpeech;

  String get location {
    switch (snapshot.step) {
      case GuideStep.savedDetail:
        final savedLocalDate = snapshot.savedLocalDate;
        if (savedLocalDate == null) throw StateError('missing_saved_date');
        final localDate =
            savedLocalDate.isUtc ? savedLocalDate.toLocal() : savedLocalDate;
        return '${AppRoutes.calendar}?date=${localDate.year.toString().padLeft(4, '0')}-${localDate.month.toString().padLeft(2, '0')}-${localDate.day.toString().padLeft(2, '0')}';
      case GuideStep.queryMic:
      case GuideStep.querySpeech:
        return AppRoutes.voice;
      case GuideStep.queryResults:
      case GuideStep.changeSpeech:
        return AppRoutes.voiceConversation;
      case GuideStep.editPreview:
        if (snapshot.expectedUpdatedStartLocal == null) {
          throw StateError('missing_preview_requires_same_phase_refresh');
        }
        return '${AppRoutes.eventEdit}/${Uri.encodeComponent(event.id)}';
      case GuideStep.updatedDetail:
        return '${AppRoutes.eventDetail}/${Uri.encodeComponent(event.id)}';
      default:
        throw StateError('unsupported_recovery_step');
    }
  }

  /// Capture before the read; recheck after it and immediately before navigation.
  static Future<GuideRouteRecovery?> load({
    required GuideCoordinator coordinator,
    required String? Function() currentUid,
    required bool Function() attachedToRoute,
    required Future<List<EventModel>> Function(String uid, String id) read,
  }) async {
    final s = coordinator.state.value;
    if (!supports(s) || currentUid() != s.uid || !attachedToRoute()) return null;
    // A temporary fence uses no fabricated event identity.
    bool current() {
      final now = coordinator.state.value;
      return attachedToRoute() && currentUid() == s.uid &&
          now.uid == s.uid && now.version == s.version &&
          now.sessionId == s.sessionId && now.revision == s.revision &&
          now.serverRevision == s.serverRevision && now.step == s.step &&
          now.createdEventId == s.createdEventId && now.run == GuideRun.active;
    }
    final events = await read(s.uid, s.createdEventId!);
    if (!current()) return null;
    final binding = GuideResultOrder.bind(guide: s, results: events);
    if (!GuideResultOrder.validForOrdinalEdit(
        guide: s, binding: binding, expectedRevision: s.revision)) {
      throw StateError('bound_event_missing_duplicate_or_foreign');
    }
    final event = binding.ordered.first;
    if (event.parentEventId != null || event.externalCalendarId != null) {
      throw StateError('bound_event_not_canonical_personal');
    }
    final request = GuideRouteRecovery(coordinator, s, event);
    request.location; // Validate the route before returning any request.
    return current() ? request : null;
  }
}
