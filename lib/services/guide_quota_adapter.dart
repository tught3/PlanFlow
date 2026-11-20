// ignore_for_file: unused_import - GuideCoordinator is required by the
// Map<GuideCoordinator, _Binding> signature below.
import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';

import '../onboarding/real_ui_guide/guide_contract.dart';
import '../onboarding/real_ui_guide/guide_coordinator.dart';

/// Runtime bridge between the bound real-UI guide coordinator and the
/// ordinary quota ad gates.
///
/// Contract (see `real-ui-guided-onboarding-20261019/integration-handoff.md`):
///
/// - `bind(coordinator, uid)` associates a coordinator with the current
///   authenticated UID; returns an identity-typed [GuideBindingToken].
/// - `unbind(token)` only removes the binding if the token matches the
///   active one — stale tokens and stale UIDs are no-ops.
/// - `current(authUidProvider)` returns the bound coordinator iff its
///   snapshot is non-terminal AND the UID still matches the supplied
///   auth UID. Outside guide = `null`.
/// - The ad gates consult `GuideQuotaRuntime.current(...)` BEFORE
///   running their own grant. When the returned coordinator is
///   active/paused/blocked, the gate MUST route through
///   [guideAuthorize] and MUST NOT invoke the legacy
///   `onEnterAllowed` callback. When unavailable or terminal, the
///   legacy ad-gate behaviour is preserved unchanged.
class GuideQuotaRuntime {
  GuideQuotaRuntime._();

  static final Map<GuideCoordinator, _Binding> _bindings =
      <GuideCoordinator, _Binding>{};

  /// Identity-bound by coordinator identity (`==`). Re-binding the
  /// same coordinator with a different UID returns a no-op token and
  /// leaves the existing binding in place (caller is expected to
  /// unbind first).
  static Object bind(GuideCoordinator coordinator, {required String uid}) {
    if (uid.isEmpty) {
      throw ArgumentError('GuideQuotaRuntime.bind requires a non-empty uid');
    }
    final existing = _bindings[coordinator];
    if (existing != null && existing.uid != uid) {
      return _NoopBindingToken();
    }
    // Re-bind same UID: replace the existing token with a fresh one.
    final _Binding binding = _Binding(
      coordinator: coordinator,
      uid: uid,
      token: GuideBindingToken._create(),
    );
    binding.token._owner = coordinator;
    _bindings[coordinator] = binding;
    return binding.token;
  }

  /// Identity-safe unbind: only the matching token may remove the
  /// binding. Stale tokens, terminal coordinators, and UID mismatches
  /// are no-ops; the call never throws.
  static void unbind(Object token) {
    if (token is! GuideBindingToken) return;
    final coordinator = token._owner;
    if (coordinator is! GuideCoordinator) return;
    final live = _bindings[coordinator];
    if (live == null || !identical(live.token, token)) return;
    _bindings.remove(coordinator);
  }

  /// Current bound coordinator iff its snapshot is non-terminal AND the
  /// supplied auth UID matches the binding. Outside guide = null.
  static GuideCoordinator? current(String Function() authUidProvider) {
    final raw = authUidProvider();
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return null;
    final entries = UnmodifiableMapView(_bindings).entries;
    for (final entry in entries) {
      final binding = entry.value;
      if (binding.uid != trimmed) continue;
      final snapshot = entry.key.state.value;
      if (snapshot.run == GuideRun.terminal) continue;
      return entry.key;
    }
    return null;
  }

  /// A visible guide or the current account's bound guide owns admission.
  /// An out-of-date visible guide must not fall back to ordinary quota.
  static bool blocksOrdinaryUse({
    required String? uid,
    GuideCoordinator? scoped,
  }) =>
      (scoped?.state.value.isInProgress ?? false) ||
      current(() => uid ?? '') != null;

  /// Isolated guide QA has no ad display path, even between guide sessions.
  static bool blocksAdDisplay({
    required String? uid,
    GuideCoordinator? scoped,
  }) =>
      guideQaAdvanceEnabled || blocksOrdinaryUse(uid: uid, scoped: scoped);

  /// Test-only reset. Drops every binding.
  static void reset() {
    _bindings.clear();
  }
}

/// In-memory admission for a practice replay. It never represents payment,
/// an ordinary quota grant, or a first-run guide permit.
class GuideReplayEntry {
  GuideReplayEntry._(this._coordinator, this._origin, this.kind, this.id);

  final GuideCoordinator _coordinator;
  final GuideSnapshot _origin;
  final GuideChargeKind kind;
  final String id;

  static GuideReplayEntry? issue({
    required GuideCoordinator coordinator,
    required String uid,
    required GuideChargeKind kind,
    required GuideOperation operation,
    required String id,
  }) {
    final snapshot = coordinator.state.value;
    if (id.isEmpty ||
        uid.isEmpty ||
        uid != snapshot.uid ||
        snapshot.sessionId?.isNotEmpty != true ||
        snapshot.version.isEmpty ||
        !snapshot.isReplay ||
        snapshot.run != GuideRun.active ||
        !identical(GuideQuotaRuntime.current(() => uid), coordinator) ||
        !_allows(snapshot, kind, operation)) {
      return null;
    }
    return GuideReplayEntry._(coordinator, snapshot, kind, id);
  }

  bool allows({
    required GuideCoordinator? coordinator,
    required String? uid,
    required GuideChargeKind kind,
    required GuideOperation operation,
  }) {
    final current = _coordinator.state.value;
    return kind == this.kind &&
        identical(coordinator, _coordinator) &&
        uid == _origin.uid &&
        identical(GuideQuotaRuntime.current(() => _origin.uid), _coordinator) &&
        current.uid == _origin.uid &&
        current.version == _origin.version &&
        current.sessionId == _origin.sessionId &&
        current.createdEventId == _origin.createdEventId &&
        current.isReplay &&
        current.run == GuideRun.active &&
        (kind == GuideChargeKind.scheduleParse
            ? identical(current, _origin)
            : current.revision >= _origin.revision &&
                current.step.index >= _origin.step.index) &&
        _allows(current, kind, operation);
  }

  static bool _allows(
    GuideSnapshot snapshot,
    GuideChargeKind kind,
    GuideOperation operation,
  ) =>
      switch ((kind, operation)) {
        (GuideChargeKind.scheduleParse, GuideOperation.createParse) =>
          snapshot.step == GuideStep.createSpeech ||
              snapshot.step == GuideStep.correctAndSave,
        (GuideChargeKind.voiceConversation, GuideOperation.query) =>
          snapshot.createdEventId?.isNotEmpty == true &&
              (snapshot.step == GuideStep.querySpeech ||
                  snapshot.step == GuideStep.queryResults),
        (GuideChargeKind.voiceConversation, GuideOperation.changeTime) =>
          snapshot.createdEventId?.isNotEmpty == true &&
              snapshot.step == GuideStep.changeSpeech,
        _ => false,
      };
}

/// Opaque identity token returned by [GuideQuotaRuntime.bind]. The
/// runtime never inspects the contents; identity (`==`) is the only
/// discriminator.
class GuideBindingToken {
  GuideBindingToken._internal();

  factory GuideBindingToken._create() => GuideBindingToken._internal();

  GuideCoordinator? _owner;
  @override
  String toString() => 'GuideBindingToken(owner: $_owner)';
}

class _NoopBindingToken extends GuideBindingToken {
  _NoopBindingToken() : super._internal();
}

class _Binding {
  _Binding({
    required this.coordinator,
    required this.uid,
    required this.token,
  });

  final GuideCoordinator coordinator;
  final String uid;
  final GuideBindingToken token;
}

/// Carries a coordinator and the kind/operation/phase the caller
/// observed at the moment of requesting a permit.
@immutable
class GuideAdapterContext {
  const GuideAdapterContext({
    required this.coordinator,
    required this.kind,
    required this.operation,
    required this.phase,
    required this.uid,
    required this.version,
    required this.sessionId,
    required this.revision,
    required this.serverRevision,
    this.createdEventId,
  });

  final GuideCoordinator coordinator;
  final GuideChargeKind kind;
  final GuideOperation operation;
  final GuideStep phase;
  final String uid;
  final String version;
  final String sessionId;
  final int revision;
  final int serverRevision;
  final String? createdEventId;

  GuideChargeContext toChargeContext(String operationId) {
    return GuideChargeContext(
      uid: uid,
      version: version,
      sessionId: sessionId,
      kind: kind,
      operation: operation,
      phase: phase,
      revision: revision,
      serverRevision: serverRevision,
      createdEventId: createdEventId,
    );
  }
}

/// Pure authorize helper. Fail-closed on missing/empty context, stale
/// UID, non-active run, denied status, or malformed server payload.
Future<GuideAccess> guideAuthorize({
  required GuideAdapterContext context,
  required String operationId,
  required String Function() authUidProvider,
}) async {
  if (context.uid.isEmpty ||
      context.sessionId.isEmpty ||
      context.version.isEmpty ||
      operationId.isEmpty) {
    return const GuideAccess(
        status: GuideAccessStatus.denied, reasonCode: 'empty_context');
  }
  final liveUid = authUidProvider();
  if (liveUid != context.uid) {
    return const GuideAccess(
        status: GuideAccessStatus.denied, reasonCode: 'uid_mismatch');
  }
  final snapshot = context.coordinator.state.value;
  if (snapshot.uid != context.uid ||
      snapshot.sessionId != context.sessionId ||
      snapshot.revision != context.revision ||
      snapshot.serverRevision != context.serverRevision ||
      snapshot.step != context.phase ||
      snapshot.run != GuideRun.active) {
    return const GuideAccess(
        status: GuideAccessStatus.denied, reasonCode: 'stale_or_blocked');
  }
  return context.coordinator.authorize(
    context: context.toChargeContext(operationId),
    operationId: operationId,
  );
}
