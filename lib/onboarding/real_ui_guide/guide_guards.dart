import '../../data/models/event_model.dart';
import 'guide_contract.dart';
import '../../services/feature_tour_service.dart';

abstract final class GuideMutationPolicy {
  static GuideWriteDecision check(
      {required GuideSnapshot guide, required GuideMutationIntent intent}) {
    if (guide.run != GuideRun.active) {
      return const GuideWriteDecision(
          allowed: false, reasonCode: 'guide_not_active');
    }
    if (!intent.userConfirmed) {
      return const GuideWriteDecision(
          allowed: false, reasonCode: 'confirmation_required');
    }
    if (!intent.isPersonal || intent.isRecurrence) {
      return const GuideWriteDecision(
          allowed: false, reasonCode: 'not_personal_single_event');
    }
    if (intent.kind == GuideWriteKind.createPersonal) {
      if (guide.step != GuideStep.correctAndSave ||
          guide.createdEventId != null) {
        return const GuideWriteDecision(
            allowed: false, reasonCode: 'create_not_allowed');
      }
      return const GuideWriteDecision(allowed: true);
    }
    if (intent.eventId == null ||
        guide.step != GuideStep.editPreview ||
        intent.eventId != guide.createdEventId) {
      return const GuideWriteDecision(
          allowed: false, reasonCode: 'wrong_target');
    }
    if (intent.changedFields.any((f) => f != 'startAt' && f != 'endAt')) {
      return const GuideWriteDecision(
          allowed: false, reasonCode: 'unsupported_fields');
    }
    if (intent.requestedStartLocal == null ||
        intent.requestedStartLocal != guide.expectedUpdatedStartLocal) {
      return const GuideWriteDecision(
          allowed: false, reasonCode: 'preview_mismatch');
    }
    return const GuideWriteDecision(allowed: true);
  }
}

abstract final class GuideResultOrder {
  static GuideVisibleBinding bind(
      {required GuideSnapshot guide, required List<EventModel> results}) {
    final id = guide.createdEventId;
    if (id == null) {
      return GuideVisibleBinding(
          ordered: results,
          targetEventId: null,
          firstIsTarget: false,
          guideRevision: guide.revision,
          missingTarget: true,
          duplicateTarget: false,
          identityIssue: true);
    }
    final matches = results.where((e) => e.id == id).toList(growable: false);
    final duplicate = matches.length > 1;
    final missing = matches.isEmpty;
    final target = missing ? null : matches.first;
    final identity = target == null ||
        target.userId != guide.uid ||
        target.groupEventId != null ||
        target.externalId != null ||
        target.recurrenceRule != null;
    final ordered = target == null || duplicate || identity
        ? List<EventModel>.of(results)
        : <EventModel>[target, ...results.where((e) => e.id != id)];
    return GuideVisibleBinding(
        ordered: ordered,
        targetEventId: id,
        firstIsTarget: ordered.isNotEmpty && ordered.first.id == id,
        guideRevision: guide.revision,
        missingTarget: missing,
        duplicateTarget: duplicate,
        identityIssue: identity);
  }

  static bool validForOrdinalEdit(
          {required GuideSnapshot guide,
          required GuideVisibleBinding binding,
          required int expectedRevision}) =>
      guide.revision == expectedRevision &&
      binding.guideRevision == expectedRevision &&
      binding.firstIsTarget &&
      binding.targetEventId == guide.createdEventId &&
      !binding.missingTarget &&
      !binding.duplicateTarget &&
      !binding.identityIssue;
}

/// Adapter for `LegacyIntroScreen`. Records only that the original three-slide
/// intro has been shown for the authenticated UID/version. It does NOT mark the
/// whole real guide completed or skipped, does NOT claim a backend session,
/// does NOT reset quota counters, and does NOT touch the real guide FSM.
///
/// The marker advances `step` from `intro` to `homeMic` purely as a local
/// "intro seen" indicator. Subsequent real guide progress (when the coordinator
/// actually starts and binds a backend session) will overwrite this snapshot
/// via the normal `GuideProgressStore.save` path.
class GuideAccountFeatureTourStore extends FeatureTourStore {
  GuideAccountFeatureTourStore(
      {required this.uidProvider, required this.progress});

  static const String _introVersion = 'real_ui_v1';

  final String? Function() uidProvider;
  final GuideProgressStore progress;

  @override
  Future<bool> shouldShow() async {
    final uid = uidProvider();
    // Fail-closed: with no auth context we cannot claim the intro was seen.
    if (uid == null || uid.isEmpty) {
      return true;
    }
    final s = await progress.load(uid: uid, version: _introVersion);
    if (s == null) {
      return true;
    }
    // Intro is considered "seen" once `step` has moved past `GuideStep.intro`.
    return s.step == GuideStep.intro;
  }

  @override
  Future<void> markCompleted() async {
    final initialUid = uidProvider();
    if (initialUid == null || initialUid.isEmpty) {
      throw StateError('No authenticated account');
    }
    final capturedUid = initialUid;
    final existing =
        await progress.load(uid: capturedUid, version: _introVersion);
    // Async load completed; ensure the auth context did not switch.
    if (uidProvider() != capturedUid) {
      throw StateError('UID changed during intro persistence');
    }
    // If progress is already past intro, do not regress. Later real guide
    // steps are owned by `RealUiGuideCoordinator` and must not be overwritten.
    if (existing != null && existing.step != GuideStep.intro) {
      return;
    }
    // Build the intro-only marker preserving UID/version/holds from any
    // pre-existing snapshot, and advance only the `step` from intro to
    // homeMic. We never set the whole guide to completed/skipped and never
    // claim a real backend session.
    final next = existing == null
        ? GuideSnapshot(
            uid: capturedUid,
            version: _introVersion,
            revision: 0,
            serverRevision: 0,
            step: GuideStep.homeMic,
            run: GuideRun.active,
          )
        : existing.copyWith(step: GuideStep.homeMic, run: GuideRun.active);
    await progress.save(next);
    // Async save completed; ensure the auth context did not switch.
    if (uidProvider() != capturedUid) {
      throw StateError('UID changed during intro persistence');
    }
  }

  @override
  Future<bool> shouldShowTip(String tipId) async => false;

  @override
  Future<void> markTipShown(String tipId) async {}
}
