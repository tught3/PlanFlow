import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../data/models/event_model.dart';
import '../onboarding/real_ui_guide/guide_contract.dart';

/// Production backend adapter for the real-UI guide.
///
/// Implements [GuideBackendPort] (see
/// `real-ui-guided-onboarding-20261019/core-impl/PUBLICAPI.md`).
/// All four RPCs from `server-grants-impl/backendAPI.md` are wired
/// camelCase, with the V3 calendar-offset refinement from
/// `architecture/protocol-addendum-v3.md` enforced for `bind_created`
/// and `edit_preview`. JSON-shape failures and stale UID race results
/// fail closed (deny / null) without ever crossing the legacy
/// ordinary-quota path.
///
/// The runtime bridge is [GuideQuotaRuntime] (see `guide_quota_adapter.dart`).
/// This file contains only the remote boundary — never the quota gate.
typedef GuideRpcInvoker = Future<Object?> Function(
  String rpcName,
  Map<String, Object?> params,
);

@visibleForTesting
const String kRpcBegin = 'begin_real_ui_guide';

@visibleForTesting
const String kRpcAuthorize = 'authorize_real_ui_guide_operation';

@visibleForTesting
const String kRpcAdvance = 'advance_real_ui_guide';

@visibleForTesting
const String kRpcFinish = 'finish_real_ui_guide';

@visibleForTesting
const Duration kDefaultGrantLease = Duration(minutes: 2);

@visibleForTesting
const int kMinCalendarOffsetMinutes = -14 * 60;

@visibleForTesting
const int kMaxCalendarOffsetMinutes = 14 * 60;

class SupabaseRealUiGuideGrantService implements GuideBackendPort {
  SupabaseRealUiGuideGrantService({required SupabaseClient client})
      : _invoker = _supabaseInvokerFor(client),
        _uidProvider = (() => client.auth.currentUser?.id),
        _now = _systemUtcNow;

  SupabaseRealUiGuideGrantService._forTesting({
    required GuideRpcInvoker rpc,
    required String? Function() currentUid,
    required DateTime Function() now,
  })  : _invoker = rpc,
        _uidProvider = currentUid,
        _now = now;

  /// Test factory that swaps in a fake RPC invoker, UID getter and
  /// clock so tests never touch the live Supabase client.
  factory SupabaseRealUiGuideGrantService.forTesting({
    required GuideRpcInvoker rpc,
    required String? Function() currentUid,
    DateTime Function()? now,
  }) {
    return SupabaseRealUiGuideGrantService._forTesting(
      rpc: rpc,
      currentUid: currentUid,
      now: now ?? DateTime.now,
    );
  }

  final GuideRpcInvoker _invoker;
  final String? Function() _uidProvider;
  final DateTime Function() _now;

  // Coarse server phase is not recoverable from the UI step (edit/preview).
  // Retain only validated, current-session wire state; never infer a grant.
  ({
    String uid,
    String version,
    String sessionId,
    String phase,
    int revision,
    DateTime expiresAt
  })? _wireState;
  String? _lastUid;

  bool _rememberWire(
      Object? raw, GuideBackendState state, String uid, String version) {
    final row = GuideBackendJson._rowOrNull(raw);
    final expiry = GuideBackendJson._readDate(row?['expires_at']);
    if (expiry == null || !expiry.isAfter(_now())) return false;
    final previous = _wireState;
    if (previous != null &&
        previous.uid == uid &&
        previous.sessionId == state.sessionId &&
        previous.revision > state.serverRevision) {
      return false;
    }
    _wireState = (
      uid: uid,
      version: version,
      sessionId: state.sessionId,
      phase: GuideBackendJson._readString(row!, 'phase'),
      revision: state.serverRevision,
      expiresAt: expiry
    );
    return true;
  }

  // ── GuideBackendPort ──────────────────────────────────────────

  @override
  Future<GuideBackendState?> begin({
    required String uid,
    required String version,
    required String requestId,
  }) async {
    if (uid.isEmpty || version.isEmpty || requestId.isEmpty) return null;
    final uidBefore = _readUid();
    if (uidBefore == null || uidBefore != uid) return null;
    final Object? raw;
    try {
      raw = await _invoker(
        kRpcBegin,
        buildBeginParams(version: version, requestId: requestId),
      );
    } catch (_) {
      return null;
    }
    final uidAfter = _readUid();
    if (uidAfter == null || uidAfter != uid) return null;
    final decoded = GuideBackendJson.decodeBeginOrDeny(raw);
    if (decoded == null || !_rememberWire(raw, decoded, uid, version)) {
      _wireState = null;
      return null;
    }
    return decoded;
  }

  @override
  Future<GuideBackendState> advance({
    required GuideSnapshot snapshot,
    required GuideBackendAction action,
    required String requestId,
    EventModel? event,
    DateTime? expectedStartLocal,
  }) async {
    final uid = snapshot.uid;
    if (uid.isEmpty) {
      throw StateError('advance() requires a non-empty snapshot.uid');
    }
    if (snapshot.sessionId == null || snapshot.sessionId!.isEmpty) {
      throw StateError('advance() requires a non-empty sessionId');
    }
    if (requestId.isEmpty) {
      throw StateError('advance() requires a non-empty requestId');
    }
    final serverRevision = snapshot.serverRevision;
    final params = buildAdvanceParams(
      snapshot: snapshot,
      action: action,
      requestId: requestId,
      event: event,
      expectedStartLocal: expectedStartLocal,
    );
    final uidBefore = _readUid();
    if (uidBefore == null || uidBefore != uid) {
      throw StateError('advance() lost its authenticated UID');
    }
    final Object? raw;
    try {
      raw = await _invoker(kRpcAdvance, params);
    } catch (_) {
      throw StateError('advance_real_ui_guide RPC failed');
    }
    final uidAfter = _readUid();
    if (uidAfter == null || uidAfter != uid) {
      throw StateError('advance() lost its authenticated UID mid-call');
    }
    final decoded = GuideBackendJson.decodeAdvanceOrDeny(raw);
    if (decoded == null) {
      _wireState = null;
      final row = GuideBackendJson._rowOrNull(raw);
      final status =
          row == null ? '' : GuideBackendJson._readString(row, 'status');
      if (status == 'expired' || status == 'denied' || status == 'retryLater') {
        throw StateError('advance_real_ui_guide: $status '
            '${GuideBackendJson._readOptionalString(row!, 'reason_code') ?? ''}');
      }
      throw StateError('advance_real_ui_guide returned malformed JSON');
    }
    if (decoded.sessionId != snapshot.sessionId) {
      _wireState = null;
      throw StateError('advance_real_ui_guide returned a different session');
    }
    if (decoded.serverRevision != serverRevision &&
        decoded.serverRevision < serverRevision) {
      throw StateError('advance_real_ui_guide decreased serverRevision');
    }
    if (!_rememberWire(raw, decoded, uid, snapshot.version)) {
      _wireState = null;
      throw StateError('advance_real_ui_guide expired or stale wire state');
    }
    return decoded;
  }

  @override
  Future<GuideAccess> authorize({
    required GuideChargeContext context,
    required String operationId,
  }) async {
    final uid = context.uid;
    if (uid.isEmpty ||
        context.sessionId.isEmpty ||
        context.version.isEmpty ||
        operationId.isEmpty) {
      return const GuideAccess(
          status: GuideAccessStatus.denied, reasonCode: 'invalid_context');
    }
    final uidBefore = _readUid();
    if (uidBefore == null || uidBefore != uid) {
      return const GuideAccess(
          status: GuideAccessStatus.denied, reasonCode: 'stale_uid');
    }
    final wire = _wireState;
    if (wire == null ||
        wire.uid != uid ||
        wire.version != context.version ||
        wire.sessionId != context.sessionId ||
        wire.revision != context.serverRevision ||
        (wire.phase == 'preview' ? 'edit' : wire.phase) !=
            wirePhase(context.phase)) {
      return const GuideAccess(
          status: GuideAccessStatus.denied, reasonCode: 'unknown_server_state');
    }
    if (!wire.expiresAt.isAfter(_now())) {
      _wireState = null;
      return const GuideAccess(
          status: GuideAccessStatus.expired, reasonCode: 'session_expired');
    }
    final Object? raw;
    try {
      raw = await _invoker(
        kRpcAuthorize,
        buildAuthorizeParams(
          sessionId: context.sessionId,
          phase: context.phase,
          revision: context.serverRevision,
          kind: context.kind,
          operation: context.operation,
          operationId: operationId,
        )..['p_phase'] = wire.phase,
      );
    } catch (_) {
      return const GuideAccess(
          status: GuideAccessStatus.unavailable, reasonCode: 'rpc_failed');
    }
    final uidAfter = _readUid();
    if (uidAfter == null || uidAfter != uid) {
      return const GuideAccess(
          status: GuideAccessStatus.denied, reasonCode: 'stale_uid_after');
    }
    return GuideBackendJson.decodeAuthorizeOrDeny(
      raw,
      context: context,
      now: _now(),
      operationId: operationId,
    );
  }

  @override
  Future<void> finish({
    required GuideSnapshot snapshot,
    required GuideExit exit,
    required String requestId,
  }) async {
    if (snapshot.uid.isEmpty ||
        snapshot.sessionId == null ||
        snapshot.sessionId!.isEmpty ||
        requestId.isEmpty) {
      return;
    }
    final params = buildFinishParams(
      snapshot: snapshot,
      exit: exit,
      requestId: requestId,
    );
    final uidBefore = _readUid();
    if (uidBefore == null || uidBefore != snapshot.uid) return;
    Object? raw;
    try {
      raw = await _invoker(kRpcFinish, params);
    } catch (_) {
      return;
    }
    final uidAfter = _readUid();
    if (uidAfter == null || uidAfter != snapshot.uid) return;
    // Local termination is best effort. A denied/malformed finish is not an ack.
    _wireState = null;
    GuideBackendJson.decodeFinishOrDeny(raw);
  }

  String? _readUid() {
    final uid = _uidProvider();
    if (_lastUid != uid) {
      _wireState = null;
      _lastUid = uid;
    }
    if (uid == null) return null;
    final trimmed = uid.trim();
    if (trimmed.isEmpty) return null;
    return trimmed;
  }
}

// ── Wire construction (pure, @visibleForTesting) ─────────────────

@visibleForTesting
Map<String, Object?> buildBeginParams({
  required String version,
  required String requestId,
}) {
  return <String, Object?>{
    'p_version': version,
    'p_request_id': requestId,
  };
}

@visibleForTesting
Map<String, Object?> buildAuthorizeParams({
  required String sessionId,
  required GuideStep phase,
  required int revision,
  required GuideChargeKind kind,
  required GuideOperation operation,
  required String operationId,
}) {
  return <String, Object?>{
    'p_session_id': sessionId,
    'p_phase': wirePhase(phase),
    'p_revision': revision,
    'p_kind': wireKind(kind),
    'p_operation': wireOperation(operation),
    'p_operation_id': operationId,
  };
}

@visibleForTesting
Map<String, Object?> buildAdvanceParams({
  required GuideSnapshot snapshot,
  required GuideBackendAction action,
  required String requestId,
  EventModel? event,
  DateTime? expectedStartLocal,
}) {
  final sessionId = snapshot.sessionId;
  if (sessionId == null || sessionId.isEmpty) {
    throw StateError('advance requires a session id');
  }
  final params = <String, Object?>{
    'p_session_id': sessionId,
    'p_expected_revision': snapshot.serverRevision,
    'p_action': wireAction(action),
    'p_request_id': requestId,
  };
  final Map<String, Object?> payload = <String, Object?>{};
  String? eventId;
  switch (action) {
    case GuideBackendAction.bindCreated:
      if (event == null || event.startAt == null) {
        throw StateError('bind_created requires an event with startAt');
      }
      eventId = event.id;
      final offset = localCalendarOffsetMinutes(event.startAt!.toLocal());
      payload['calendar_utc_offset_minutes'] = offset;
      break;
    case GuideBackendAction.updateVerified:
      eventId = event?.id ?? snapshot.createdEventId;
      if (expectedStartLocal != null) {
        payload['expected_start_at'] = utcIso(expectedStartLocal.toUtc());
      } else if (snapshot.expectedUpdatedStartLocal != null) {
        payload['expected_start_at'] =
            utcIso(snapshot.expectedUpdatedStartLocal!.toUtc());
      }
      if (event?.startAt != null) {
        payload['calendar_utc_offset_minutes'] =
            localCalendarOffsetMinutes(event!.startAt!.toLocal());
      }
      break;
    case GuideBackendAction.editPreview:
      if (expectedStartLocal == null) {
        throw StateError('edit_preview requires expectedStartLocal');
      }
      payload['expected_start_at'] = utcIso(expectedStartLocal.toUtc());
      payload['calendar_utc_offset_minutes'] =
          localCalendarOffsetMinutes(expectedStartLocal.toLocal());
      break;
    case GuideBackendAction.detailAck:
    case GuideBackendAction.queryReady:
      break;
  }
  if (eventId != null && eventId.isNotEmpty) {
    params['p_event_id'] = eventId;
  }
  params['p_payload'] = payload;
  return params;
}

@visibleForTesting
Map<String, Object?> buildFinishParams({
  required GuideSnapshot snapshot,
  required GuideExit exit,
  required String requestId,
}) {
  final sessionId = snapshot.sessionId;
  if (sessionId == null || sessionId.isEmpty) {
    throw StateError('finish requires a session id');
  }
  return <String, Object?>{
    'p_session_id': sessionId,
    'p_request_id': requestId,
    'p_reason': wireExit(exit),
  };
}

@visibleForTesting
int localCalendarOffsetMinutes(DateTime local) {
  final minutes = local.timeZoneOffset.inMinutes;
  if (minutes < kMinCalendarOffsetMinutes ||
      minutes > kMaxCalendarOffsetMinutes) {
    throw StateError('calendar_utc_offset_minutes out of range: $minutes');
  }
  return minutes;
}

@visibleForTesting
String utcIso(DateTime dt) => dt.toUtc().toIso8601String();

@visibleForTesting
String wirePhase(GuideStep step) {
  switch (step) {
    case GuideStep.intro:
      return 'intro';
    case GuideStep.homeMic:
    case GuideStep.createSpeech:
      return 'create';
    case GuideStep.correctAndSave:
      // Authorize wire: see `protocol-addendum-v3.md` matrix; the
      // charge context still uses GuideStep while the wire is
      // coarse `create`.
      return 'create';
    case GuideStep.savedDetail:
      return 'saved';
    case GuideStep.queryMic:
    case GuideStep.querySpeech:
    case GuideStep.queryResults:
      return 'query';
    case GuideStep.changeSpeech:
    case GuideStep.editPreview:
      return 'edit';
    case GuideStep.updatedDetail:
    case GuideStep.syncChoice:
      return 'updated';
    case GuideStep.completed:
      return 'terminal';
    case GuideStep.skipped:
      return 'terminal';
  }
}

@visibleForTesting
String wireKind(GuideChargeKind kind) {
  switch (kind) {
    case GuideChargeKind.scheduleParse:
      return 'scheduleParse';
    case GuideChargeKind.voiceConversation:
      return 'voiceConversation';
  }
}

@visibleForTesting
String wireOperation(GuideOperation operation) {
  switch (operation) {
    case GuideOperation.createParse:
      return 'createParse';
    case GuideOperation.query:
      return 'query';
    case GuideOperation.changeTime:
      return 'changeTime';
  }
}

@visibleForTesting
String wireAction(GuideBackendAction action) {
  switch (action) {
    case GuideBackendAction.bindCreated:
      return 'bind_created';
    case GuideBackendAction.detailAck:
      return 'detail_ack';
    case GuideBackendAction.queryReady:
      return 'query_ready';
    case GuideBackendAction.editPreview:
      return 'edit_preview';
    case GuideBackendAction.updateVerified:
      return 'update_verified';
  }
}

@visibleForTesting
String wireExit(GuideExit exit) {
  switch (exit) {
    case GuideExit.completed:
      return 'completed';
    case GuideExit.skip:
      return 'skip';
    case GuideExit.cancel:
      return 'cancel';
    case GuideExit.authChanged:
      // The server accepts only completed/skip/cancel. Owner guards still apply.
      return 'cancel';
  }
}

// ── JSON parsing (fail-closed, no logging) ────────────────────────

@visibleForTesting
class GuideBackendJson {
  GuideBackendJson._();

  static GuideBackendState? decodeBeginOrDeny(Object? raw) {
    final row = _rowOrNull(raw);
    if (row == null) return null;
    final status = _readString(row, 'status');
    if (status == 'denied' || status == 'expired') {
      return null;
    }
    if (status != 'granted') return null;
    final sessionId = _readString(row, 'session_id');
    if (sessionId.isEmpty) return null;
    final phase = _wirePhaseToStep(_readString(row, 'phase'));
    if (phase == null) return null;
    final revision = _readInt(row['revision']);
    if (revision == null) return null;
    final eventId = _readOptionalString(row, 'event_id');
    final savedLocalDate = _readOptionalDate(row, 'saved_local_date');
    return GuideBackendState(
      sessionId: sessionId,
      serverRevision: revision,
      step: phase,
      createdEventId: eventId,
      savedLocalDate: savedLocalDate,
      dateTimeZone: _readOptionalString(row, 'date_time_zone'),
    );
  }

  static GuideBackendState? decodeAdvanceOrDeny(Object? raw) {
    final row = _rowOrNull(raw);
    if (row == null) return null;
    final status = _readString(row, 'status');
    if (status != 'ok') return null;
    final sessionId = _readString(row, 'session_id');
    if (sessionId.isEmpty) return null;
    final phase = _wirePhaseToStep(_readString(row, 'phase'));
    if (phase == null) return null;
    final revision = _readInt(row['revision']);
    if (revision == null) return null;
    final eventId = _readOptionalString(row, 'event_id');
    final savedLocalDate = _readOptionalDate(row, 'saved_local_date');
    return GuideBackendState(
      sessionId: sessionId,
      serverRevision: revision,
      step: phase,
      createdEventId: eventId,
      savedLocalDate: savedLocalDate,
      dateTimeZone: _readOptionalString(row, 'date_time_zone'),
    );
  }

  static GuideAccess decodeAuthorizeOrDeny(
    Object? raw, {
    required GuideChargeContext context,
    required DateTime now,
    required String operationId,
  }) {
    final row = _rowOrNull(raw);
    if (row == null) {
      return const GuideAccess(
          status: GuideAccessStatus.unavailable,
          reasonCode: 'malformed_payload');
    }
    final status = _readString(row, 'status');
    final reasonCode = _readOptionalString(row, 'reason_code');
    switch (status) {
      case 'granted':
        final grantId = _readString(row, 'grant_id');
        final expiresRaw = row['expires_at'];
        final expires = _readDate(expiresRaw);
        if (grantId.isEmpty || expires == null) {
          return const GuideAccess(
              status: GuideAccessStatus.denied, reasonCode: 'malformed_grant');
        }
        if (!expires.isAfter(now)) {
          return GuideAccess(
              status: GuideAccessStatus.expired, reasonCode: reasonCode);
        }
        final lease = expires.difference(now);
        if (lease > kDefaultGrantLease * 2) {
          return const GuideAccess(
              status: GuideAccessStatus.denied,
              reasonCode: 'lease_out_of_bounds');
        }
        return GuideAccess(
          status: GuideAccessStatus.granted,
          reasonCode: reasonCode,
          permit: GuidePermit(
            grantId: grantId,
            uid: context.uid,
            sessionId: context.sessionId,
            operationId: operationId,
            kind: context.kind,
            operation: context.operation,
            expiresAtUtc: expires.toUtc(),
          ),
        );
      case 'expired':
        return GuideAccess(
            status: GuideAccessStatus.expired, reasonCode: reasonCode);
      case 'denied':
        return GuideAccess(
            status: GuideAccessStatus.denied, reasonCode: reasonCode);
      case 'retryLater':
        return GuideAccess(
            status: GuideAccessStatus.retryLater, reasonCode: reasonCode);
      default:
        return const GuideAccess(
            status: GuideAccessStatus.denied, reasonCode: 'unknown_status');
    }
  }

  static void decodeFinishOrDeny(Object? raw) {
    final row = _rowOrNull(raw);
    if (row == null) return;
    final status = _readString(row, 'status');
    if (status != 'ok' && status != 'denied') return;
  }

  static Map<String, dynamic>? _rowOrNull(Object? raw) {
    if (raw is Map) {
      return Map<String, dynamic>.from(raw);
    }
    if (raw is List && raw.isNotEmpty) {
      final first = raw.first;
      if (first is Map) {
        return Map<String, dynamic>.from(first);
      }
    }
    return null;
  }

  static String _readString(Map<String, dynamic> row, String key) {
    final value = row[key];
    if (value is String) return value;
    return '';
  }

  static String? _readOptionalString(Map<String, dynamic> row, String key) {
    final value = row[key];
    if (value is String && value.isNotEmpty) return value;
    return null;
  }

  static int? _readInt(Object? raw) {
    if (raw is int) return raw;
    if (raw is num) return raw.toInt();
    if (raw is String) return int.tryParse(raw);
    return null;
  }

  static DateTime? _readOptionalDate(Map<String, dynamic> row, String key) {
    return _readDate(row[key]);
  }

  static DateTime? _readDate(Object? raw) {
    if (raw is String && raw.isNotEmpty) {
      return DateTime.tryParse(raw);
    }
    return null;
  }

  static GuideStep? _wirePhaseToStep(String phase) {
    switch (phase) {
      // The server's coarse `create` phase represents the whole first-run
      // create flow. The real-UI tour still requires its local intro and mic
      // acknowledgement before entering createSpeech. Keep _wireState.phase
      // as `create` for authorization fencing; only the UI checkpoint maps
      // this phase to intro.
      case 'create':
        return GuideStep.intro;
      case 'saved':
        return GuideStep.savedDetail;
      case 'query':
        return GuideStep.querySpeech;
      case 'edit':
        return GuideStep.editPreview;
      case 'preview':
        return GuideStep.editPreview;
      case 'updated':
        return GuideStep.updatedDetail;
      case 'syncChoice':
        return GuideStep.syncChoice;
      case 'terminal':
        return GuideStep.completed;
      case 'intro':
        return GuideStep.intro;
      default:
        return null;
    }
  }
}

// ── Production invoker / auth getter / clock ────────────────────

GuideRpcInvoker _supabaseInvokerFor(SupabaseClient client) {
  return (String name, Map<String, Object?> params) async {
    return client.rpc(name, params: params);
  };
}

DateTime _systemUtcNow() => DateTime.now().toUtc();

/// Tiny abstraction around `Supabase.instance.client.auth.currentUser?.id`
/// so tests can swap in a fake auth getter without ever initialising
/// `Supabase.instance`. Production code reads the real auth from
/// Supabase; tests construct the adapter via `forTesting(...)` and
/// only the override path is exercised.
class SupabaseClientAccess {
  SupabaseClientAccess._();

  static String? Function()? _override;

  /// Active authenticated UID for the given adapter context. Returns
  /// null when no override is registered AND the global Supabase
  /// client has not been initialised (e.g. inside test runners).
  static String? authCurrentId() {
    final override = _override;
    if (override != null) return override();
    try {
      return Supabase.instance.client.auth.currentUser?.id;
    } catch (_) {
      return null;
    }
  }

  /// Test/QA injection point. Pass a closure that returns the fake
  /// UID. Pass `null` to deactivate. Pair with [clearOverride] in
  /// tearDown to keep state isolated.
  static void overrideForRun(String? Function()? getter) {
    _override = getter;
  }

  static void clearOverride() {
    _override = null;
  }
}
