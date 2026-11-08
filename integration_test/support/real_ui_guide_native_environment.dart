// Native QA only. Never install channel handlers or fake services.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:planflow/core/app_http.dart';
import 'package:planflow/core/env.dart';
import 'package:planflow/onboarding/real_ui_guide/guide_contract.dart';
import 'package:planflow/providers/auth_provider.dart';
import 'package:planflow/services/remote_config_service.dart';
import 'package:planflow/services/schedule_parse_entitlement.dart';
import 'package:planflow/services/voice_conversation_entitlement.dart';
import 'native_guide_budget_ledger.dart';
import 'real_ui_guide_manual_resume.dart';

class NativeGuideManualPhaseGate {
  /// Tag only the copied, owner-validated QA create wire payload. The user's
  /// editor text and parser input are never changed by this helper.
  static Map<String, dynamic>? markedCreatePayload(
      Map<String, dynamic>? payload,
      {required String expectedUid,
      required String marker}) {
    if (payload == null ||
        payload['user_id'] != expectedUid ||
        !RegExp(r'^\[QA:[A-Za-z0-9_-]+\]$').hasMatch(marker)) return null;
    final title = payload['title'];
    if (title is! String || title.trim().isEmpty) return null;
    return <String, dynamic>{
      ...payload,
      'title': title.contains(marker) ? title : '$title $marker',
    };
  }

  static bool operatorPhaseAllowed({required bool manualBindingEnabled}) =>
      !manualBindingEnabled;

  /// Fence stage of an authorization request. The server contract allows
  /// exactly one kind/operation pair per stage, so the request itself - not
  /// the on-screen guide step - decides the stage.
  static String? fenceStageForRequest(Map<String, Object?> payload) {
    final kind = payload['p_kind'];
    final operation = payload['p_operation'];
    if (kind == 'scheduleParse' && operation == 'createParse') return 'create';
    if (kind == 'voiceConversation' && operation == 'query') return 'query';
    if (kind == 'voiceConversation' && operation == 'changeTime') {
      return 'change';
    }
    return null;
  }

  /// Fence stage of the live wire phase. The server keeps the session in
  /// `create` until the event is bound, so a create-stage parse stays valid
  /// after the guide moved on to its review step.
  static String? fenceStageForWirePhase(String? wirePhase) =>
      switch (wirePhase) {
        'create' => 'create',
        'query' => 'query',
        'edit' || 'preview' => 'change',
        _ => null,
      };

  /// The on-screen guide step may legitimately sit one step ahead of the
  /// stage the request belongs to: the tour advances to its review step
  /// before the confirm screen runs the final parse.
  static bool tourStageAllows(String fenceStage, String tourStage) =>
      switch (fenceStage) {
        'create' => tourStage == 'create' || tourStage == 'save',
        'query' => tourStage == 'query',
        'change' => tourStage == 'change' || tourStage == 'editSave',
        _ => false,
      };

  static String? phaseFor(GuideStep step) => switch (step) {
        GuideStep.createSpeech => 'create',
        GuideStep.correctAndSave => 'save',
        GuideStep.querySpeech => 'query',
        GuideStep.changeSpeech => 'change',
        GuideStep.editPreview => 'editSave',
        _ => null,
      };

  static String? denial(
      {required GuideSnapshot? snapshot,
      required String expectedUid,
      required String? sessionId,
      required int? serverRevision,
      required DateTime? expiresAt,
      required String? createdId,
      required DateTime now}) {
    if (snapshot == null) return 'manual phase snapshot missing';
    if (snapshot.uid != expectedUid) return 'manual phase uid mismatch';
    if (snapshot.run != GuideRun.active)
      return 'manual guide run is not active';
    if (snapshot.errorCode != null) return 'manual guide snapshot has error';
    if (sessionId == null || snapshot.sessionId != sessionId)
      return 'manual guide session mismatch';
    if (serverRevision == null || snapshot.serverRevision != serverRevision)
      return 'manual guide server revision mismatch';
    if (expiresAt == null || !expiresAt.isAfter(now))
      return 'manual guide permit expired';
    final phase = phaseFor(snapshot.step);
    if (phase == null)
      return 'manual guide step does not authorize a sensitive send';
    if ((phase == 'query' || phase == 'change') &&
        (createdId == null || snapshot.createdEventId != createdId))
      return 'manual created event identity mismatch';
    return null;
  }
}

/// Thrown when an optional, unawaited background RPC (e.g. record_user_activity)
/// is rejected at the fence. The caller-supplied path swallows internally, so
/// the harness can let the exception bubble without latching the whole run.
/// All other denied requests use [StateError] via `deny()` and DO latch.
class NativeGuideOptionalBackgroundBlocked implements Exception {
  const NativeGuideOptionalBackgroundBlocked();
  @override
  String toString() => 'NativeGuideOptionalBackgroundBlocked';
}

class NativeGuideEnvironment {
  NativeGuideEnvironment._(this.config, this.directory,
      {this.deadlineOverride});
  final Map<String, dynamic> config;
  final Directory directory;

  /// Absolute deadline of the session. A manual cold resume reuses the
  /// deadline of the original run and never extends it. `null` means "derive
  /// it from the session start and the access token expiry".
  final DateTime? deadlineOverride;

  /// Wall clock start of this process run (fresh run only).
  late final DateTime sessionStartedAt;

  /// Access token expiry of the active session.
  late final DateTime tokenExpiry;

  /// In-memory copy of the recovered session. It is never written to the
  /// journal, to the logs or to a plain file; only the secure resume store
  /// may persist it.
  late final Map<String, dynamic> _sessionSnapshot;
  final records = <Map<String, Object?>>[];
  String? _lastJournalEvent;
  String phase = 'bootstrap';

  /// Stage of the last authorize request. The grant reply is judged by the
  /// stage of that request, not by the on-screen guide step.
  String? authorizeStageForObserve;
  GuideSnapshot Function()? manualGuideSnapshot;
  bool get manualPhaseBound => manualGuideSnapshot != null;

  String _phaseFromManualSnapshot(GuideSnapshot? s) {
    final reason = NativeGuideManualPhaseGate.denial(
        snapshot: s,
        expectedUid: uid,
        sessionId: permit.sessionId,
        serverRevision: permit.revision,
        expiresAt: permit.expires,
        createdId: createdId,
        now: DateTime.now());
    if (reason != null) deny(reason);
    final phase = NativeGuideManualPhaseGate.phaseFor(s!.step);
    if (phase == null)
      deny('manual guide step does not authorize a sensitive send');
    return phase;
  }

  String observeManualPhaseForSensitiveSend() {
    if (!manualPhaseBound) return phase;
    phase = _phaseFromManualSnapshot(manualGuideSnapshot!.call());
    return phase;
  }

  void validateManualSensitiveSend({required String expectedPhase}) {
    if (!manualPhaseBound) return;
    final actual = observeManualPhaseForSensitiveSend();
    if (actual != expectedPhase)
      deny('manual phase mismatch: expected $expectedPhase, observed $actual');
  }

  /// Stage of an authorization request in manual mode. The request decides
  /// the stage; the live guide snapshot only has to be compatible with it.
  String manualFenceStageForRequest(Map<String, Object?> payload) {
    final stage = NativeGuideManualPhaseGate.fenceStageForRequest(payload);
    if (stage == null) deny('manual authorize request stage unknown');
    if (!manualPhaseBound) return stage;
    final tour = observeManualPhaseForSensitiveSend();
    if (!NativeGuideManualPhaseGate.tourStageAllows(stage, tour)) {
      deny('manual phase mismatch: expected $stage, observed $tour');
    }
    return stage;
  }

  /// Stage of an AI proxy call in manual mode. The live wire phase decides
  /// the stage; the guide snapshot only has to be compatible with it.
  String manualFenceStageForAi() {
    if (!manualPhaseBound) return phase;
    final stage =
        NativeGuideManualPhaseGate.fenceStageForWirePhase(permit.phase);
    if (stage == null) deny('manual wire phase does not allow an AI request');
    final tour = observeManualPhaseForSensitiveSend();
    if (!NativeGuideManualPhaseGate.tourStageAllows(stage, tour)) {
      deny('manual phase mismatch: expected $stage, observed $tour');
    }
    return stage;
  }

  bool failed = false;
  late final http.Client transport;
  HttpOverrides? priorHttp;
  bool verifiedUid = false;

  /// Finite per-run counter for approved backend map-proxy GETs (R2).
  int mapProxyCalls = 0;
  bool _authProviderStarted = false;
  final NativeGuideSerialGate serial = NativeGuideSerialGate();

  /// Guards a second `Supabase.initialize` inside the same process.
  static bool _supabaseInitializedInProcess = false;
  late final NativeGuideWirePermit permit =
      NativeGuideWirePermit(expectedUid: uid, now: DateTime.now);
  RandomAccessFile? _runLock;
  // Durable ledger populated under the run lock; the in-memory mirror is
  // refreshed only by [_persistLedger]. The harness never derives its cap or
  // create guard from in-memory counters; it always re-reads from disk via
  // the loaded snapshot, and persistence precedes any forwarded request.
  late final File _ledgerFile;
  late BudgetLedgerSnapshot _ledgerSnapshot;
  void ensureOperatorPhaseChangeAllowed() {
    if (manualPhaseBound)
      deny('SET_PHASE cannot override manual snapshot binding');
  }

  String get uid => config['expectedUid'] as String;
  String get runId => config['runId'] as String;
  String get host => config['approvedBackendHost'] as String;
  String get budgetId => config['budgetId'] as String;
  String get marker => '[QA:$runId]';

  /// Read-only accessor for the loaded ledger snapshot. Callers must not
  /// mutate the returned value; reservations go through [_persistLedger].
  BudgetLedgerSnapshot get ledgerSnapshot => _ledgerSnapshot;
  // Mirror views off the ledger snapshot. Mutations go through
  // [_persistLedger] only.
  int get aiRequests => _ledgerSnapshot.aiRequests;
  Set<String> get usedPhases => _ledgerSnapshot.usedPhases.toSet();
  bool get createAttempted => _ledgerSnapshot.createAttempted;
  String? get createdId => _ledgerSnapshot.createdId;

  /// Effective session deadline: `min(start + window, token expiry)` for a
  /// fresh run, or the persisted deadline of the original run after a manual
  /// cold resume. A restart never extends it.
  DateTime get sessionDeadline =>
      deadlineOverride ??
      computeManualResumeDeadline(
          sessionStartedAt: sessionStartedAt, tokenExpiry: tokenExpiry);

  /// Atomic ledger write: temp file -> flush -> rename. Caller failures
  /// (missing parent dir, IO error) propagate as [StateError] which the
  /// reserve sites above translate into a fail-closed deny.
  Future<void> _persistLedger(BudgetLedgerSnapshot next) async {
    await writeBudgetLedgerAtomic(file: _ledgerFile, snapshot: next);
    _ledgerSnapshot = next;
  }

  /// Reserve an AI slot. Validates against current snapshot, then persists
  /// before returning. Persistence failure => fail closed.
  Future<void> _reserveAi(String phase) async {
    final reason = reasonForReserveAi(_ledgerSnapshot, phase);
    if (reason != null) deny();
    final next = nextAiReservationSnapshot(_ledgerSnapshot, phase);
    try {
      await _persistLedger(next);
    } on Object {
      failed = true;
      throw StateError('Native guide safety fence denied request');
    }
  }

  /// Reserve the event-create slot. Validates against current snapshot, then
  /// persists `createAttempted=true` before forwarding. Persistence failure
  /// => fail closed.
  Future<void> _reserveEventCreate() async {
    final reason = reasonForReserveEventCreate(_ledgerSnapshot);
    if (reason != null) deny();
    final next = _ledgerSnapshot.copyWith(createAttempted: true);
    try {
      await _persistLedger(next);
    } on Object {
      failed = true;
      throw StateError('Native guide safety fence denied request');
    }
  }

  /// Capture the freshly-created event id into the ledger. Persistence
  /// failure => fail closed; the reservation remains so retry is denied.
  Future<void> _captureCreatedId(String id) async {
    final next = _ledgerSnapshot.copyWith(createdId: id);
    try {
      await _persistLedger(next);
    } on Object {
      failed = true;
      throw StateError('Native guide safety fence denied request');
    }
  }

  static const peeks = [
    'schedule_parse_entitlement_peek',
    'voice_conversation_entitlement_peek'
  ];
  static const guideRpcs = [
    'begin_real_ui_guide',
    'authorize_real_ui_guide_operation',
    'advance_real_ui_guide',
    'finish_real_ui_guide'
  ];

  /// Optional background RPCs that the fence rejects without forwarding and
  /// without latching the entire run. Caller-side swallows must already exist
  /// (the AuthService.ensureProfile unawaited `_recordLoginActivity` path
  /// catches internally). Any other RPC falls through to a fatal deny.
  static const optionalBackgroundRpcs = ['record_user_activity'];

  /// QA limitation: background GETs are whitelisted only by exact path
  /// and method. This is an explicit, harmless feature omission; we do not
  /// synthesize any data, do not widen RLS, and we journal
  /// `DENIED_NOT_FORWARDED` so the parent can audit. Add any further path
  /// here only as a deliberate, code-reviewable act.
  /// group_event_comments is deliberately omitted; its caller catches errors.
  static const optionalBackgroundRestGetPaths = [
    '/rest/v1/groups',
    // Settings auto-loads the group-backup list. NoSync QA does not test
    // backups: reject this exact read WITHOUT forwarding, just like groups.
    '/rest/v1/group_backups',
    '/rest/v1/group_event_comments',
  ];

  /// Pure helper: returns true iff the (path, method) pair is the exact
  /// match for an optional-background REST rejection. Used by [_send] and
  /// exposed for unit tests so the allowlist surface is verifiable without
  /// instantiating the harness.
  static bool isOptionalBackgroundRestGet(String path, String method) {
    if (method != 'GET') return false;
    return optionalBackgroundRestGetPaths.contains(path);
  }

  /// The ONLY pre_actions scope this harness may forward: the detail
  /// screen lookup of the event THIS run created
  /// (SmartPreparationAlarmService.listForEvent).
  ///
  ///   GET /rest/v1/pre_actions
  ///       ?select=*
  ///       &event_id=eq.CREATED_ID
  ///       &user_id=eq.OWNER_UID
  ///       &source=eq.external_preparation
  ///       &order=notify_at.asc.nullslast
  ///
  /// The projection may also be the narrower `event_id` and the `order`
  /// parameter may be absent; the SCOPE (event id + owner uid + source) is
  /// what the fence binds to. Every other shape is rejected: other verbs,
  /// another event id, an empty/absent created id, `or`/`in` scopes,
  /// duplicated scope parameters, extra scope parameters, an unverified uid
  /// or a foreign owner uid.
  static const Set<String> kPreActionReadScopeKeys = <String>{
    'select',
    'event_id',
    'user_id',
    'source',
    'order',
  };

  /// Projections the real repository actually sends for this read.
  static const Set<String> kPreActionReadProjections = <String>{
    '*',
    'event_id',
  };

  /// Orderings the real repository actually sends for this read.
  static const Set<String> kPreActionReadOrders = <String>{
    'notify_at.asc',
    'notify_at.asc.nullslast',
  };

  /// Returns null when the pre_actions READ may be forwarded, otherwise a
  /// short, value-free rejection reason. The reason never embeds a query
  /// value, a header or a token.
  static String? preActionReadReason({
    required String method,
    required Uri uri,
    required String uid,
    required String? createdId,
    required bool verifiedUid,
  }) {
    if (method != 'GET') return 'pre_actions read fence allows GET only';
    if (!verifiedUid) return 'pre_actions read requires a verified owner uid';
    if (uid.isEmpty) return 'pre_actions read has no owner uid';
    if (createdId == null || createdId.isEmpty) {
      return 'pre_actions read requires the ledger created event id';
    }
    final all = uri.queryParametersAll;
    if (all.values.any((values) => values.length != 1)) {
      return 'pre_actions read forbids a duplicated scope parameter';
    }
    final query = uri.queryParameters;
    if (query.keys.any((key) => !kPreActionReadScopeKeys.contains(key))) {
      return 'pre_actions read forbids an unrecognized scope parameter';
    }
    if (!query.containsKey('select') ||
        !query.containsKey('event_id') ||
        !query.containsKey('user_id') ||
        !query.containsKey('source')) {
      return 'pre_actions read requires the full owned scope';
    }
    if (query['event_id'] != 'eq.$createdId') {
      return 'pre_actions read requires event_id=eq.<ledger created event id>';
    }
    if (query['user_id'] != 'eq.$uid') {
      return 'pre_actions read requires user_id=eq.<verified owner uid>';
    }
    if (query['source'] != 'eq.external_preparation') {
      return 'pre_actions read requires source=eq.external_preparation';
    }
    if (!kPreActionReadProjections.contains(query['select'])) {
      return 'pre_actions read projection is not allowed';
    }
    final order = query['order'];
    if (order != null && !kPreActionReadOrders.contains(order)) {
      return 'pre_actions read order is not allowed';
    }
    return null;
  }

  /// The home screen always issues a BATCH smart-preparation lookup
  /// (SmartPreparationAlarmService.listEventIdsWithSmartAlarms):
  ///
  ///   GET /rest/v1/pre_actions?select=event_id&user_id=eq.OWNER_UID
  ///       &source=eq.external_preparation&event_id=in.(ID_LIST)
  ///
  /// The REAL postgrest serializer (postgrest 2.7.0, _cleanFilterArray)
  /// wraps every non-numeric value in double quotes, so the actual wire is
  /// `event_id=in.("ID1","ID2")`; the bare `in.(ID1,ID2)` spelling stays
  /// accepted as the older equivalent. That read is NOT the detail read of
  /// the event this run created, so it is never forwarded. It is rejected
  /// exactly like the optional background reads (/rest/v1/groups,
  /// /rest/v1/group_backups) already are: without forwarding AND without
  /// latching the run, because the app itself degrades gracefully when that
  /// lookup fails. Any deviation from this exact shape (foreign uid, other
  /// source, extra or missing keys, another verb, a malformed, duplicated
  /// or over-long id list) stays a fatal deny.
  static bool isOptionalBackgroundPreActionRead({
    required String method,
    required Uri uri,
    required String uid,
  }) {
    if (method != 'GET') return false;
    if (uid.isEmpty) return false;
    final query = uri.queryParameters;
    if (query.length != 4) return false;
    if (query['select'] != 'event_id') return false;
    if (query['user_id'] != 'eq.$uid') return false;
    if (query['source'] != 'eq.external_preparation') return false;
    final scope = query['event_id'];
    if (scope == null || !scope.startsWith('in.(') || !scope.endsWith(')')) {
      return false;
    }
    final raw = scope.substring(4, scope.length - 1);
    if (raw.isEmpty) return false;
    final ids = raw.split(',');
    if (ids.length > 50) return false;
    final uuid = RegExp(r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-'
        r'[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$');
    final seen = <String>{};
    for (final token in ids) {
      final t = token.trim();
      // Quoted form: exactly ONE wrapping pair of double quotes around a
      // bare uuid. A uuid never contains a quote, so escaped-quote or
      // embedded-quote payloads fail the uuid match below.
      final value = (t.length >= 2 &&
              t.codeUnitAt(0) == 0x22 &&
              t.codeUnitAt(t.length - 1) == 0x22 &&
              !t.substring(1, t.length - 1).contains('"'))
          ? t.substring(1, t.length - 1)
          : t;
      if (!uuid.hasMatch(value)) return false;
      // The real service dedupes ids before the read
      // (listEventIdsWithSmartAlarms), so duplicates stay fatal.
      if (!seen.add(value)) return false;
    }
    return true;
  }

  /// Pure helper: the sanitized bracket-deny reason for the transport fence.
  /// A run that already failed with a well-formed bracket (https:443, no
  /// userinfo, approved backend host) must NOT be mislabeled 'host
  /// mismatch' — the actual bound-phone journal showed exactly that
  /// mislabeling for follow-up requests to the correct backend. The real
  /// bracket mismatch always wins; 'already failed' only describes the
  /// case the enclosing guard reached with a clean bracket.
  static String bracketDenyReason({
    required bool alreadyFailed,
    required Uri uri,
    required String approvedHost,
  }) {
    final mismatch = uri.scheme != 'https' ||
        uri.port != 443 ||
        uri.userInfo.isNotEmpty ||
        uri.host != approvedHost;
    return mismatch ? 'host mismatch' : 'already failed';
  }

  static Future<NativeGuideEnvironment> load() async {
    if (!kDebugMode || !const bool.fromEnvironment('PLANFLOW_GUIDE_QA')) {
      throw StateError('Debug guide QA opt-in required');
    }
    const name = String.fromEnvironment('PLANFLOW_GUIDE_QA_RUNTIME');
    if (!Platform.isAndroid ||
        !name.startsWith('/data/user/0/') ||
        !name.contains('/files/') ||
        name.contains('..')) {
      throw StateError('App-private Android runtime path required');
    }
    final file = File(name);
    final deadline = DateTime.now().add(const Duration(seconds: 45));
    while (!await file.exists()) {
      if (DateTime.now().isAfter(deadline)) throw StateError('Runtime missing');
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    Map<String, dynamic> c;
    try {
      if (await file.length() > 32768) throw StateError('Runtime too large');
      c = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    } finally {
      await file.delete();
    }
    if (!RegExp(r'^[a-zA-Z0-9_-]{8,64}$')
            .hasMatch(c['runId'] as String? ?? '') ||
        !RegExp(r'^[a-fA-F0-9-]{36}$')
            .hasMatch(c['expectedUid'] as String? ?? '') ||
        c['maxAiRequests'] is! int ||
        (c['maxAiRequests'] as int) < 1 ||
        c['dedicatedTestAccount'] != true ||
        Uri.parse(AppEnv.supabaseUrl).host != c['approvedBackendHost']) {
      throw StateError('Runtime scope rejected; AppEnv has no runtime setter');
    }
    final budgetId = c['budgetId'];
    if (budgetId is! String || !kBudgetIdRegex.hasMatch(budgetId)) {
      throw StateError('Runtime budgetId failed fixed-task regex');
    }
    final session = c['session'] as Map<String, dynamic>;
    final token = session['access_token'] as String;
    final claims = jsonDecode(utf8
            .decode(base64Url.decode(base64Url.normalize(token.split('.')[1]))))
        as Map<String, dynamic>;
    if (claims['sub'] != c['expectedUid'] ||
        (claims['exp'] as num) * 1000 <=
            DateTime.now().millisecondsSinceEpoch ||
        (session['user'] as Map)['id'] != c['expectedUid']) {
      throw StateError('Session scope rejected');
    }
    final e = NativeGuideEnvironment._(c, file.parent);
    e.sessionStartedAt = DateTime.now();
    // banned-ok: Converts runtime expiry metadata to a date.
    e.tokenExpiry = DateTime.fromMillisecondsSinceEpoch(
        (claims['exp'] as num).round() * 1000);
    e._sessionSnapshot = session;
    final journal = File('${e.directory.path}/native-guide-${e.runId}.json');
    if (await journal.exists()) throw StateError('Run identity already used');
    await journal.create();
    return e;
  }

  /// MANUAL ONLY: persist the secure resume state of this fresh run.
  ///
  /// The record holds the recovered session plus a bounded policy and the
  /// absolute deadline (`min(session start + 30 min, token expiry)`). It is
  /// written through flutter_secure_storage only. The default automated
  /// `load()` path never calls this.
  Future<void> persistManualResumeRecord({
    required SecureResumeStore store,
    DateTime? sessionStartedAtOverride,
  }) async {
    final session = _sessionSnapshot;
    final start = sessionStartedAtOverride ?? sessionStartedAt;
    final record = ManualResumeRecord(
      policy: ManualResumePolicy(
        uid: uid,
        backendHost: host,
        budgetId: budgetId,
        maxAiRequests: kManualResumeMaxAiRequests,
        dedicatedTestAccount: config['dedicatedTestAccount'] == true,
        originalRunId: runId,
        deadline: computeManualResumeDeadline(
            sessionStartedAt: start, tokenExpiry: tokenExpiry),
        tokenExpiry: tokenExpiry,
        directoryPath: directory.path,
      ),
      session: session,
      anonKey: config['anonKey'] as String? ?? '',
    );
    await ManualResumeService(store: store).save(record);
  }

  /// MANUAL ONLY: cold relaunch resume.
  ///
  /// Never waits for the one-use runtime file. The persisted deadline, uid,
  /// backend, budget id and session policy are reused as-is; the run gets a
  /// NEW unique journal run id and the durable budget ledger keeps its
  /// consumption (it is never reset and never auto-created here).
  ///
  /// Throws [ManualResumeException] with a credential-free code for every
  /// unusable, missing, expired, mismatching or corrupt state.
  static Future<NativeGuideEnvironment> loadManualResume({
    required SecureResumeStore store,
    required DateTime now,
    required String expectedBackendHost,
    String? expectedUid,
    bool requireAndroidDirectoryPath = true,
  }) async {
    final outcome = await ManualResumeService(store: store).load(
      now: now,
      expectedBackendHost: expectedBackendHost,
      expectedUid: expectedUid,
      requireAndroidDirectoryPath: requireAndroidDirectoryPath,
    );
    final record = outcome.record;
    if (record == null) {
      throw ManualResumeException(
          outcome.failure ?? ManualResumeFailure.recordCorrupt);
    }
    final policy = record.policy;
    final directory = Directory(policy.directoryPath);
    if (!await directory.exists()) {
      throw ManualResumeException(
          ManualResumeFailure.recordCorrupt, 'directory missing');
    }
    final resumedRunId = _manualResumeRunId(policy.originalRunId, now);
    final config = <String, dynamic>{
      'expectedUid': policy.uid,
      'runId': resumedRunId,
      'approvedBackendHost': policy.backendHost,
      'budgetId': policy.budgetId,
      'maxAiRequests': kManualResumeMaxAiRequests,
      'dedicatedTestAccount': policy.dedicatedTestAccount,
      'session': record.session,
      'anonKey':
          record.anonKey.isNotEmpty ? record.anonKey : AppEnv.supabaseAnonKey,
    };
    final e = NativeGuideEnvironment._(config, directory,
        deadlineOverride: policy.deadline);
    e.sessionStartedAt = now;
    // banned-ok: Copies the runtime policy expiry timestamp.
    e.tokenExpiry = policy.tokenExpiry;
    e._sessionSnapshot = record.session;
    final journal = File('${e.directory.path}/native-guide-${e.runId}.json');
    if (await journal.exists()) {
      throw ManualResumeException(
          ManualResumeFailure.recordCorrupt, 'run id reused');
    }
    await journal.create();
    return e;
  }

  /// A resume never reuses the original run id: the journal identity is
  /// fresh and unique, while still matching the run id contract (<=64 chars).
  static int _manualResumeCounter = 0;

  static String _manualResumeRunId(String originalRunId, DateTime now) {
    _manualResumeCounter++;
    final suffix = '-r${now.microsecondsSinceEpoch}-$_manualResumeCounter';
    final room = 64 - suffix.length;
    final prefix = originalRunId.length > room
        ? originalRunId.substring(0, room)
        : originalRunId;
    return '$prefix$suffix';
  }

  Future<T> run<T>(Future<T> Function() action) async {
    _runLock = await File('${directory.path}/native-guide-exclusive.lock')
        .open(mode: FileMode.append);
    await _runLock!.lock(FileLock.exclusive);
    // Load and validate the durable budget ledger under the same lock. The
    // helper never auto-creates the file; a missing or corrupt ledger here
    // fails closed. Any earlier state from previous runIds is honored.
    _ledgerFile = File(budgetLedgerPath(directory, budgetId));
    try {
      _ledgerSnapshot = await loadBudgetLedger(
        file: _ledgerFile,
        expectedBudgetId: budgetId,
        expectedUid: uid,
      );
    } on Object {
      failed = true;
      await _runLock?.unlock();
      await _runLock?.close();
      _runLock = null;
      rethrow;
    }
    priorHttp = HttpOverrides.current;
    final previousAppHttpFactory =
        AppHttp.overrideFactory(() => _BudgetClient(this));
    var transportReady = false;
    try {
      transport = IOClient(
          HttpClient()..connectionTimeout = const Duration(seconds: 15));
      transportReady = true;
      HttpOverrides.global = _DenyUnscopedIo();
      return await AppHttp.runWithFactory(
        () => _BudgetClient(this),
        () => http.runWithClient(() async {
          WidgetsFlutterBinding.ensureInitialized();
          return await action();
        }, () => _BudgetClient(this)),
      );
    } finally {
      AppHttp.overrideFactory(previousAppHttpFactory);
      if (transportReady) transport.close();
      HttpOverrides.global = priorHttp;
      await _runLock?.unlock();
      await _runLock?.close();
    }
  }

  Future<void> bootstrap() async {
    // A recovery screen may be shown and the session retried inside the same
    // process. Supabase must be initialized exactly once per process.
    if (!_supabaseInitializedInProcess) {
      await Supabase.initialize(
          url: AppEnv.supabaseUrl,
          anonKey: config['anonKey'] as String,
          httpClient: _BudgetClient(this),
          debug: false,
          authOptions: const FlutterAuthClientOptions(
              autoRefreshToken: false,
              detectSessionInUri: false,
              localStorage: EmptyLocalStorage()));
      _supabaseInitializedInProcess = true;
    }
    await Supabase.instance.client.auth
        .recoverSession(jsonEncode(config.remove('session')));
    final user = await Supabase.instance.client.auth.getUser();
    if (user.user?.id != uid)
      throw StateError('Server-authenticated UID mismatch');
    verifiedUid = true;
    config.remove('anonKey');
    AppEnv.markSupabaseInitialized();
    _authProviderStarted = true;
    authProvider.start();
  }

  /// Persisted consumed fields remain stable across time-varying peeks.
  Future<Map<String, Object?>> quotaSnapshot() async {
    if (!verifiedUid) deny();
    final client = Supabase.instance.client;
    await client.rpc(peeks[0],
        params: buildScheduleParsePeekParams(
            initialLimit: 0,
            dailyLimit: RemoteConfigService.scheduleParseDailyFreeCount));
    await client.rpc(peeks[1],
        params: buildVoiceConversationPeekParams(
            initialLimit: RemoteConfigService.voiceConversationInitialFreeCount,
            dailyLimit: RemoteConfigService.voiceConversationDailyFreeCount));
    const fields = [
      'schedule_parse_daily_used_count',
      'schedule_parse_last_reset_date',
      'schedule_parse_last_session_id',
      'voice_conversation_free_trial_used',
      'voice_conversation_daily_free_used',
      'voice_conversation_daily_free_date',
      'voice_conversation_last_session_id'
    ];
    final row = await client
        .from('user_settings')
        .select(fields.join(','))
        .eq('user_id', uid)
        .maybeSingle();
    return {for (final key in fields) key: row?[key]};
  }

  Future<void> journal(String event) async {
    await File('${directory.path}/native-guide-$runId.json').writeAsString(
        jsonEncode({
          'runId': runId,
          'event': event,
          'phase': phase,
          'createdId': createdId,
          'aiRequests': aiRequests,
          'failed': failed,
          'http': records
        }),
        flush: true);
    _lastJournalEvent = event;
  }

  Never deny([Object? diagnostic]) {
    failed = true;
    // QA-only: every latch leaves its reason so failures are diagnosable
    // without guessing. No secrets are stored.
    if (diagnostic != null) {
      records.add({'denyReason': diagnostic});
    }
    throw StateError('Native guide safety fence denied request');
  }

  /// The ONLY approved map/place network route: the public
  /// NAVER_MAP_PROXY_URL define (AppEnv.naverMapProxyUrl), pointing at the
  /// existing functions/v1/naver-geocode edge function on this run's backend
  /// host, which verifies the caller JWT and mints provider secrets itself.
  /// Null (define absent or unparseable) means every map request is denied.
  Uri? configuredMapProxy() {
    final raw = AppEnv.naverMapProxyUrl.trim();
    if (raw.isEmpty) return null;
    final uri = Uri.tryParse(raw);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) return null;
    return uri;
  }

  Future<Map<String, dynamic>> control(String name) async {
    phase = name;
    await journal('ARM');
    debugPrint('NATIVE_GUIDE_ARM $runId $name');
    final file =
        File('${directory.path}/native-guide-$runId-$name.control.json');
    final until = DateTime.now().add(const Duration(seconds: 90));
    while (!await file.exists()) {
      if (DateTime.now().isAfter(until)) throw StateError('Control timeout');
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    if (await file.length() > 8192) deny();
    final value = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    await file.delete();
    if (value['runId'] != runId ||
        value['phase'] != name ||
        value['command'] != 'CONTINUE') deny();
    return value;
  }

  Future<void> close() async {
    // `failed` also latches the network fence for intentional manual stops.
    // Preserve a successfully written terminal reason without unlatching it.
    final event = switch (_lastJournalEvent) {
      'CLOSED' => 'CLOSED',
      'MANUAL_SESSION_TIMEOUT' => 'MANUAL_SESSION_TIMEOUT',
      _ => failed ? 'FAIL' : 'CLOSED',
    };
    await journal(event);
    if (_authProviderStarted) {
      _authProviderStarted = false;
      authProvider.dispose();
    }
    try {
      await Supabase.instance.dispose();
    } catch (_) {
      // Supabase was never initialized in this process (startup failure).
    }
    _supabaseInitializedInProcess = false;
    AppEnv.resetSupabaseInitializationState();
    config.clear();
  }
}

class _DenyUnscopedIo extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) => throw StateError(
      'Unscoped IO denied; native network needs parent egress fence');
}

class _BudgetClient extends http.BaseClient {
  _BudgetClient(this.e);
  final NativeGuideEnvironment e;
  @override
  void close() {}
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      e.serial.run(() async {
        try {
          return await _send(request);
        } on NativeGuideOptionalBackgroundBlocked {
          // Optional background path already journaled DENIED_NOT_FORWARDED.
          // The run must not be latched, so do not write FAIL_CLOSED_NO_RETRY.
          rethrow;
        } catch (_) {
          e.failed = true;
          e.records.add({
            'denied': '${request.method} ${request.url.path}',
            'queryKeys': request.url.queryParameters.keys.toList()
          });
          try {
            await e.journal('FAIL_CLOSED_NO_RETRY');
          } catch (_) {}
          rethrow;
        }
      });

  Future<http.StreamedResponse> _send(http.BaseRequest request) async {
    // Free public weather/geocoding reads (no auth, no billing) used by the
    // real home screen. Allowlisted host:path:query only; the request is
    // rebuilt from scratch so no app headers or auth are forwarded and
    // redirects are not followed.
    if (!e.failed &&
        request.method == 'GET' &&
        weatherRequestReason(
                uri: request.url, forwardedHeaders: const <String, String>{}) ==
            null) {
      final r = await e.transport
          .send(http.Request('GET', request.url)..followRedirects = false)
          .timeout(const Duration(seconds: 20));
      final bytes = await r.stream.toBytes();
      e.records.add({
        'publicRead': request.url.host,
        'path': request.url.path,
        'status': r.statusCode
      });
      return http.StreamedResponse(Stream.value(bytes), r.statusCode,
          headers: r.headers, request: request);
    }
    // Bracket: only https:443, no userinfo, host = approved backend.
    final bracketMismatch = request.url.scheme != 'https' ||
        request.url.port != 443 ||
        request.url.userInfo.isNotEmpty ||
        request.url.host != e.host;
    if (e.failed || bracketMismatch) {
      // Split the sanitized diagnostics: an already-failed run with a
      // well-formed bracket must not be mislabeled as a host mismatch (the
      // real bound-phone journal showed the approved backend host labeled
      // 'host mismatch' after an earlier deny had already latched the run).
      final reason = NativeGuideEnvironment.bracketDenyReason(
          alreadyFailed: e.failed, uri: request.url, approvedHost: e.host);
      final diagnosticPath = request.url.path.startsWith('/rest/v1/') ||
              request.url.path.startsWith('/auth/v1/') ||
              request.url.path.startsWith('/functions/v1/')
          ? request.url.path
          : '<redacted>';
      e.records.add({
        'denyReason': reason,
        'host': request.url.host.replaceAll(RegExp(r'[^a-zA-Z0-9.-]'), ''),
        'path': diagnosticPath,
      });
      e.deny(reason);
    }
    request.followRedirects = false;
    final path = request.url.path;
    final method = request.method;
    var body = await request.finalize().toBytes();
    final authGet = path == '/auth/v1/user' && method == 'GET';
    if (!authGet &&
        (!e.verifiedUid ||
            Supabase.instance.client.auth.currentUser?.id != e.uid))
      e.deny('uid gate');
    final ai = path == '/functions/v1/openai-proxy';
    Map<String, dynamic>? payload;
    Object? decodedBody;
    if (body.isNotEmpty) {
      decodedBody = jsonDecode(utf8.decode(body));
      if (decodedBody is Map<String, dynamic>) payload = decodedBody;
    }
    if (ai) {
      final aiStage = e.manualFenceStageForAi();
      e.records.add({'aiStage': aiStage, 'aiPhase': e.phase});
      if (method != 'POST' ||
          !kAllowedAiPhases.contains(aiStage) ||
          !e.permit.consume(e.uid, aiStage)) e.deny('ai permit consume failed');
      // Durable reserve BEFORE forwarding. The local permit already
      // prevented identity issues; this is the cross-restart total cap.
      try {
        await e._reserveAi(aiStage);
      } catch (error) {
        e.records.add({
          'denyReason': 'ai reserve failed',
          'errorType': error.runtimeType.toString(),
        });
        rethrow;
      }
      await e.journal('AI_RESERVED');
    } else if (path == '/auth/v1/user' && method == 'GET') {
      // Real server verifies recovered session. Refresh and login are denied.
    } else if (path.startsWith('/rest/v1/rpc/')) {
      final rpc = path.split('/').last;
      if (payload == null || method != 'POST') e.deny('rpc payload/method');
      if (rpc == 'authorize_real_ui_guide_operation') {
        final authorizeStage = e.manualPhaseBound
            ? e.manualFenceStageForRequest(payload!)
            : e.phase;
        if (authorizeStage != 'create' &&
            authorizeStage != 'query' &&
            authorizeStage != 'change') {
          e.deny('manual authorize stage not allowed');
        }
        // The grant reply must be judged by the stage of the request, not by
        // the on-screen guide step: the guide advances to its review step
        // before the confirm screen asks for the parse grant.
        e.authorizeStageForObserve = authorizeStage;
        if (!e.permit.matchesParams(payload!, authorizeStage)) {
          e.deny('authorize params mismatch');
        }
      }
      if (['advance_real_ui_guide', 'finish_real_ui_guide'].contains(rpc) &&
          !e.permit.matchesSession(payload!)) e.deny('session params mismatch');
      // Optional-background RPCs: rejected without forwarding AND without
      // latching the whole run. The caller (AuthService._recordLoginActivity
      // path) swallows internally; a distinct exception lets the supervision
      // wrapper skip the fail-closed latch.
      if (NativeGuideEnvironment.optionalBackgroundRpcs.contains(rpc)) {
        e.records.add({
          'denied': rpc,
          'kind': 'optional_background',
          'path': path,
        });
        try {
          await e.journal('DENIED_NOT_FORWARDED');
        } catch (_) {
          // Journal must never widen the failure surface.
        }
        throw const NativeGuideOptionalBackgroundBlocked();
      }
      // Otherwise the call must be either an entitlement peek or a guide
      // guide-RPC; anything else (incl. ensure_current_user_profile and any
      // other activity/profile mutation) is fatal.
      if (!NativeGuideEnvironment.peeks.contains(rpc) &&
          !NativeGuideEnvironment.guideRpcs.contains(rpc))
        e.deny('rpc not allowlisted');
    } else if (path.startsWith('/rest/v1/')) {
      final table = path.split('/').last;
      final q = request.url.queryParameters;
      final scoped = q['user_id'] == 'eq.${e.uid}' ||
          (table == 'users' && q['id'] == 'eq.${e.uid}');
      // HEAD and other non-GET/POST/PATCH verbs are denied across the board.
      if (method != 'GET' && method != 'POST' && method != 'PATCH')
        e.deny('verb gate');
      if (method == 'GET') {
        if (NativeGuideEnvironment.isOptionalBackgroundRestGet(path, method)) {
          e.records.add({
            'denied': path,
            'kind': 'optional_background',
            'forwarded': false
          });
          await e.journal('DENIED_NOT_FORWARDED');
          throw const NativeGuideOptionalBackgroundBlocked();
        }
        // Strict allowlist: events/user_settings/users only with explicit
        // uid scope. groups and any other table => deny.
        // pre_actions has its own narrow contract: the owned detail read of
        // the event THIS run created is the only forwardable pre_actions
        // read; the home-screen batch read is rejected without forwarding
        // and without latching (same contract as /rest/v1/groups).
        if (table == 'pre_actions') {
          final preActionReason = NativeGuideEnvironment.preActionReadReason(
            method: method,
            uri: request.url,
            uid: e.uid,
            createdId: e.createdId,
            verifiedUid: e.verifiedUid,
          );
          if (preActionReason != null) {
            final optional = NativeGuideEnvironment
                .isOptionalBackgroundPreActionRead(
                    method: method, uri: request.url, uid: e.uid);
            if (optional) {
              e.records.add({
                'denied': path,
                'kind': 'optional_background',
                'forwarded': false,
                'reason': preActionReason,
              });
              await e.journal('DENIED_NOT_FORWARDED');
              throw const NativeGuideOptionalBackgroundBlocked();
            }
            // Sanitized metadata only: no query values, no headers, no
            // tokens. The reason string itself carries no request value.
            e.records.add({
              'denyReason': preActionReason,
              'table': table,
              'path': path,
              'host':
                  request.url.host.replaceAll(RegExp(r'[^a-zA-Z0-9.-]'), ''),
            });
            e.deny();
          }
          e.records.add({'read': table});
        } else {
          final reason = readTableReason(table: table, query: q, uid: e.uid);
          if (reason != null) {
            // QA-only diagnostic: keep the exact rejection reason and values
            // so a rule mismatch can be fixed without guessing. No secrets
            // are stored.
            e.records.add({
              'denyReason': reason,
              'q': {
                'select': q['select'],
                'enabled': q['enabled'],
                'order': q['order'],
                'limit': q['limit'],
                'scoped': q['user_id'] == 'eq.${e.uid}',
              }
            });
            e.deny();
          }
          e.records.add({'read': table});
        }
      } else if (table == 'events') {
        if (method == 'POST') {
          e.validateManualSensitiveSend(expectedPhase: 'save');
          if (e.manualPhaseBound) {
            final marked = NativeGuideManualPhaseGate.markedCreatePayload(
                payload,
                expectedUid: e.uid,
                marker: e.marker);
            if (marked == null) e.deny('manual create uid/title invalid');
            payload = marked;
            body = utf8.encode(jsonEncode(marked));
          }
          if (e.phase != 'save' ||
              payload?['user_id'] != e.uid ||
              !(payload?['title'] as String? ?? '').contains(e.marker))
            e.deny();
          // Durable reserve before forwarding. Once persisted as true,
          // retries are forbidden even if the response id is unknown.
          await e._reserveEventCreate();
          await e.journal('CREATE_RESERVED');
        } else if (method == 'PATCH') {
          e.validateManualSensitiveSend(expectedPhase: 'editSave');
          final cid = e.createdId;
          if (!scoped ||
              e.phase != 'editSave' ||
              cid == null ||
              q['id'] != 'eq.$cid' ||
              (payload?['user_id'] != null && payload?['user_id'] != e.uid))
            e.deny();
        } else {
          e.deny();
        }
      } else if (table == 'users' && method == 'POST') {
        // Narrow upsert for the dedicated QA account: id match, no extra
        // columns, on_conflict=id. PATCH and other verbs on users are denied.
        final row = decodedBody is List && decodedBody.length == 1
            ? decodedBody.single
            : payload;
        if (row is! Map ||
            row['id'] != e.uid ||
            row.keys.any((k) => !['id', 'email', 'name'].contains(k)) ||
            q['on_conflict'] != 'id') e.deny('users upsert shape');
      } else {
        // Strict allowlist for related-insert tables (pre_actions,
        // reminders, voice_logs, location_history). They are written by the
        // real _saveRelatedRecords path only as a POST batch tied to a
        // freshly created event id and to a save phase. PATCH/DELETE and
        // any other verb remain fatal; user_settings writes also fatal.
        if (method == 'POST' && kRelatedInsertTables.contains(table)) {
          final reason = relatedInsertReason(
            table: table,
            body: decodedBody,
            query: q,
            headers: request.headers,
            ledger: e.ledgerSnapshot,
            expectedUid: e.uid,
            phase: e.phase,
          );
          if (reason != null) e.deny();
          e.records.add({
            'relatedInsert': table,
            'rows': decodedBody is List ? decodedBody.length : 0,
          });
        } else {
          e.deny();
        }
      }
    } else if (method == 'GET' && path.startsWith('/functions/v1/')) {
      // R2 map/place contract. Only the configured backend proxy route
      // (public NAVER_MAP_PROXY_URL define → functions/v1/naver-geocode)
      // may serve place/geocode/travel lookups: exact bounded GET shape,
      // minted headers only (provider secrets live backend-side), finite
      // per-run calls. Any other functions/v1 GET stays fatal, and any
      // non-GET method here falls to the final deny below.
      final mapReason = mapProxyRequestReason(
        method: method,
        uri: request.url,
        headers: request.headers,
        configuredProxy: e.configuredMapProxy(),
        backendHost: e.host,
      );
      if (mapReason != null) e.deny();
      if (skipOptionalMapForQa(
        debug: kDebugMode,
        guideQa: const bool.fromEnvironment('PLANFLOW_GUIDE_QA'),
        isolatedQa: const bool.fromEnvironment('PLANFLOW_ISOLATED_GUIDE_QA'),
        skipMap: const bool.fromEnvironment('PLANFLOW_GUIDE_QA_SKIP_MAP'),
      )) {
        e.records.add({
          'denied': path,
          'kind': 'optional_map_excluded',
          'forwarded': false,
        });
        await e.journal('DENIED_NOT_FORWARDED');
        throw const NativeGuideOptionalBackgroundBlocked();
      }
      e.mapProxyCalls += 1;
      if (e.mapProxyCalls > kMaxMapProxyCallsPerRun) e.deny('map proxy cap');
      e.records.add({'mapProxy': path, 'calls': e.mapProxyCalls});
    } else {
      e.deny();
    }
    try {
      http.Request forwarded;
      try {
        forwarded = http.Request(method, request.url)
          ..followRedirects = false
          ..bodyBytes = body;
        // 금지된 헤더(content-length 등)를 그대로 넣으면 여기서 예외가 난다.
        request.headers.forEach((name, value) {
          final lower = name.toLowerCase();
          if (lower == 'content-length' ||
              lower == 'host' ||
              lower == 'transfer-encoding') {
            return;
          }
          forwarded.headers[name] = value;
        });
      } catch (error) {
        e.records.add({
          'denyReason': 'forward build error',
          'path': path,
          'errorType': error.runtimeType.toString(),
        });
        rethrow;
      }
      // AI 분류는 실제 응답이 30초를 넘기도 한다. 25초로 끊으면 첫 요청이
      // 실패로 랫치되어 이후 장소 조회까지 전부 막힌다.
      final sendTimeout =
          ai ? const Duration(seconds: 120) : const Duration(seconds: 25);
      final bodyTimeout =
          ai ? const Duration(seconds: 60) : const Duration(seconds: 15);
      http.StreamedResponse response;
      try {
        response = await e.transport.send(forwarded).timeout(sendTimeout);
      } catch (error) {
        e.records.add({
          'denyReason': 'transport error',
          'path': path,
          'errorType': error.runtimeType.toString(),
        });
        rethrow;
      }
      final bytes = await response.stream.toBytes().timeout(bodyTimeout);
      e.records.add({
        'method': method,
        'host': request.url.host,
        'path': path,
        'status': response.statusCode
      });
      if (!isNativeHttpResponseStatusAllowed(
        statusCode: response.statusCode,
        method: method,
        uri: request.url,
        headers: request.headers,
        configuredProxy: e.configuredMapProxy(),
        backendHost: e.host,
        bodyBytes: bytes,
      )) {
        e.deny();
      }
      if (response.statusCode == 501) {
        e.records.add({'expectedMapTransitUnsupported': true});
      }
      if (path.startsWith('/rest/v1/rpc/')) {
        final rpc = path.split('/').last;
        if (NativeGuideEnvironment.guideRpcs.contains(rpc)) {
          final observeStage = rpc == 'authorize_real_ui_guide_operation' &&
                  e.authorizeStageForObserve != null
              ? e.authorizeStageForObserve!
              : e.phase;
          final observed = e.permit.observe(rpc, payload!,
              jsonDecode(utf8.decode(bytes)), e.uid, observeStage);
          if (!observed) {
            // QA-only diagnostic: record the response shape so a rule
            // mismatch can be fixed without guessing. No secrets are stored.
            final reply = jsonDecode(utf8.decode(bytes));
            final row =
                reply is List && reply.length == 1 ? reply.single : reply;
            e.records.add({
              'rpcObserveFailed': rpc,
              'replyKeys':
                  row is Map ? row.keys.map((k) => '$k').toList() : <String>[],
              'replyStatus': row is Map ? row['status'] : null,
              'replyReasonCode': row is Map ? row['reason_code'] : null,
              'replyPhase': row is Map ? row['phase'] : null,
              'replyRevision': row is Map ? row['revision'] : null,
              'hasSessionId': row is Map && row['session_id'] is String,
              'hasExpiresAt': row is Map && row['expires_at'] is String,
            });
            e.deny();
          }
        }
      }
      if (path == '/rest/v1/events' && method == 'POST') {
        final decoded = jsonDecode(utf8.decode(bytes));
        final row =
            decoded is List && decoded.length == 1 ? decoded.single : decoded;
        final id = NativeGuideEventIdentity.capture(row, e.uid, e.marker);
        if (id == null) e.deny();
        await e._captureCreatedId(id);
        await e.journal('CREATED_ID_CAPTURED');
      }
      await e.journal('HTTP');
      return http.StreamedResponse(Stream.value(bytes), response.statusCode,
          headers: response.headers, request: request);
    } catch (err) {
      // Optional-background throws here are already journaled upstream; do
      // not latch the run for those.
      if (err is NativeGuideOptionalBackgroundBlocked) rethrow;
      e.failed = true;
      await e.journal('NETWORK_UNCERTAIN_NO_RETRY');
      rethrow;
    }
  }
}

/// Independent QA-only fence over the real coordinator authorization callback.
/// Caller supplies the actual context and actual RPC request/reply observed by
/// the guide backend adapter; no proxy headers or server binding are invented.
class NativeGuideGrantFence {
  NativeGuideGrantFence({required this.expectedUid, required this.now});
  final String expectedUid;
  final DateTime Function() now;
  final Set<String> _used = <String>{};
  Map<String, Object?>? _grant;

  bool capture(
      {required Map<String, Object?> params,
      required Map<String, Object?> reply,
      required String actualUid,
      required String actualSessionId,
      required String actualPhase,
      required int actualRevision,
      required String actualKind,
      required String actualOperation,
      required String actualOperationId}) {
    _grant = null;
    final exp = DateTime.tryParse(reply['expires_at'] as String? ?? '');
    final id = reply['grant_id'];
    if (actualUid != expectedUid ||
        reply['status'] != 'granted' ||
        id is! String ||
        id.isEmpty ||
        exp == null ||
        !exp.isAfter(now()) ||
        params['p_session_id'] != actualSessionId ||
        params['p_phase'] != actualPhase ||
        params['p_revision'] != actualRevision ||
        params['p_kind'] != actualKind ||
        params['p_operation'] != actualOperation ||
        params['p_operation_id'] != actualOperationId ||
        _used.contains(id)) return false;
    _grant = {
      'uid': actualUid,
      'session': actualSessionId,
      'phase': actualPhase,
      'revision': actualRevision,
      'kind': actualKind,
      'operation': actualOperation,
      'operationId': actualOperationId,
      'grantId': id,
      'expires': exp.toIso8601String()
    };
    return true;
  }

  bool permits(
      {required String uid,
      required String sessionId,
      required String phase,
      required int revision,
      required String kind,
      required String operation,
      required String operationId}) {
    final g = _grant;
    if (g == null ||
        uid != expectedUid ||
        g['uid'] != uid ||
        g['session'] != sessionId ||
        g['phase'] != phase ||
        g['revision'] != revision ||
        g['kind'] != kind ||
        g['operation'] != operation ||
        g['operationId'] != operationId ||
        !(DateTime.tryParse(g['expires'] as String) ?? DateTime(1970))
            .isAfter(now())) return false;
    _used.add(g['grantId'] as String);
    _grant = null;
    return true;
  }
}

class NativeGuideSerialGate {
  Future<void> _tail = Future<void>.value();
  Future<T> run<T>(Future<T> Function() action) {
    final result = _tail.then((_) => action());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }
}

/// QA-only cache of successful real RPC state. Does not mutate the app.
class NativeGuideWirePermit {
  NativeGuideWirePermit({required this.expectedUid, required this.now})
      : fence = NativeGuideGrantFence(expectedUid: expectedUid, now: now);
  final String expectedUid;
  final DateTime Function() now;
  final NativeGuideGrantFence fence;
  String? sessionId, phase, operationId;
  int? revision;
  DateTime? expires;
  int reservations = 0;
  final Set<String> stages = {};
  bool get current =>
      sessionId != null &&
      revision != null &&
      (expires?.isAfter(now()) ?? false);
  static (String, String, String)? expected(String stage) => switch (stage) {
        'create' => ('create', 'scheduleParse', 'createParse'),
        'query' => ('query', 'voiceConversation', 'query'),
        'change' => ('edit', 'voiceConversation', 'changeTime'),
        _ => null,
      };
  bool matchesSession(Map<String, Object?> p) =>
      current &&
      p['p_session_id'] == sessionId &&
      (p['p_expected_revision'] == null ||
          p['p_expected_revision'] == revision);
  bool matchesParams(Map<String, Object?> p, String stage) {
    final x = expected(stage);
    return current &&
        x != null &&
        (phase == x.$1 || (x.$1 == 'edit' && phase == 'preview')) &&
        p['p_session_id'] == sessionId &&
        p['p_phase'] == phase &&
        p['p_revision'] == revision &&
        p['p_kind'] == x.$2 &&
        p['p_operation'] == x.$3 &&
        p['p_operation_id'] is String &&
        (p['p_operation_id'] as String).isNotEmpty;
  }

  bool observe(String rpc, Map<String, Object?> p, Object? raw, String uid,
      String stage) {
    final row = raw is List && raw.length == 1 ? raw.single : raw;
    if (uid != expectedUid || row is! Map) return false;
    final r = Map<String, Object?>.from(row);
    if (rpc == 'authorize_real_ui_guide_operation') {
      operationId = null;
      _consumedOperationId = null;
      if (!matchesParams(p, stage)) return false;
      final x = expected(stage)!;
      final captured = fence.capture(
          params: p,
          reply: r,
          actualUid: uid,
          actualSessionId: sessionId!,
          actualPhase: phase!,
          actualRevision: revision!,
          actualKind: x.$2,
          actualOperation: x.$3,
          actualOperationId: p['p_operation_id'] as String);
      if (captured) operationId = p['p_operation_id'] as String;
      return captured;
    }
    if (rpc == 'finish_real_ui_guide') {
      sessionId = null;
      operationId = null;
      return r['status'] == 'ok';
    }
    final begin = rpc == 'begin_real_ui_guide';
    if ((!begin && rpc != 'advance_real_ui_guide') ||
        r['status'] != (begin ? 'granted' : 'ok') ||
        r['session_id'] is! String ||
        (r['session_id'] as String).isEmpty ||
        r['phase'] is! String ||
        r['revision'] is! int) return false;
    if (!begin &&
        (!matchesSession(p) ||
            r['session_id'] != sessionId ||
            (r['revision'] as int) < revision!)) return false;
    if (begin && sessionId != null) return false;
    final expiry = DateTime.tryParse(r['expires_at'] as String? ?? '');
    if (expiry == null || !expiry.isAfter(now())) return false;
    sessionId = r['session_id'] as String;
    phase = r['phase'] as String;
    revision = r['revision'] as int;
    expires = expiry;
    operationId = null;
    return true;
  }

  bool consume(String uid, String stage) {
    final x = expected(stage);
    // The server grant is single-use per logical operation, not per HTTP
    // request: one schedule parse may call OpenAI again to revalidate location.
    // First request consumes the grant identity; subsequent requests may share
    // that exact operation while the same live guide binding remains current.
    final opId = operationId;
    if (!current ||
        uid != expectedUid ||
        x == null ||
        opId == null ||
        (phase != x.$1 && !(x.$1 == 'edit' && phase == 'preview')))
      return false;
    if (_consumedOperationId != opId) {
      if (!fence.permits(
          uid: uid,
          sessionId: sessionId!,
          phase: phase!,
          revision: revision!,
          kind: x.$2,
          operation: x.$3,
          operationId: opId)) return false;
      _consumedOperationId = opId;
    }
    reservations++;
    stages.add(stage);
    return true;
  }

  String? _consumedOperationId;
}

/// A missing/ambiguous returned ID must never be guessed or retried.
class NativeGuideEventIdentity {
  static String? capture(Object? row, String uid, String marker) {
    if (row is! Map ||
        row['id'] is! String ||
        (row['id'] as String).isEmpty ||
        row['user_id'] != uid ||
        row['title'] is! String ||
        !(row['title'] as String).contains(marker)) return null;
    return row['id'] as String;
  }
}
