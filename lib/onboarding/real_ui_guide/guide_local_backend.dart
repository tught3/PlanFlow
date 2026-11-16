import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/safe_prefs.dart';
import '../../data/models/event_model.dart';
import 'guide_contract.dart';

/// Stores guide bookkeeping on this installation. The coordinator still owns
/// the actual schedule operations and checks the events they return.
class LocalGuideBackend implements GuideBackendPort, GuideReplayBackendPort {
  LocalGuideBackend({
    required GuideProgressStore progress,
    required Future<EventModel?> Function(String uid, String eventId)
        fetchBoundEvent,
    DateTime Function()? now,
  })  : _progress = progress,
        _fetchBoundEvent = fetchBoundEvent,
        _now = now ?? DateTime.now;

  final GuideProgressStore _progress;
  final Future<EventModel?> Function(String uid, String eventId)
      _fetchBoundEvent;
  final DateTime Function() _now;

  final _checkpoints = <(String, String), _LocalCheckpoint>{};

  // SharedPreferences caches writes. Serialize read/modify/write across
  // provider instances so overlapping permits cannot pass the same cap.
  static Future<void> _queue = Future<void>.value();
  static const _operationLimit = 12;
  static const _grantLease = Duration(minutes: 2);

  static Future<T> _serialize<T>(Future<T> Function() operation) {
    final next = _queue.then((_) => operation());
    _queue = next.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return next;
  }

  static bool _terminal(GuideStep step) =>
      step == GuideStep.completed || step == GuideStep.skipped;

  Future<GuideSnapshot?> _load(String uid, String version) async {
    final saved = await _progress.load(uid: uid, version: version);
    return saved?.uid == uid && saved?.version == version ? saved : null;
  }

  GuideBackendState _stateFor(
    String uid,
    String version,
    GuideSnapshot? saved,
  ) {
    final sessionId = saved?.sessionId;
    if (saved == null || sessionId == null || sessionId.isEmpty) {
      return GuideBackendState(
        sessionId: 'local-$uid-$version',
        serverRevision: 0,
        step: GuideStep.intro,
        expectedStartAtReported: true,
      );
    }

    final cached = _checkpoints[(uid, version)];
    if (cached != null) {
      final isUnpersistedRestart =
          cached.previousSessionId == sessionId && _terminal(saved.step);
      final isNewerAdvance = cached.state.sessionId == sessionId &&
          saved.run != GuideRun.terminal &&
          cached.state.serverRevision > saved.serverRevision;
      if (isUnpersistedRestart || isNewerAdvance) return cached.state;
    }

    final unboundCreate = saved.createdEventId == null &&
        (saved.step == GuideStep.createSpeech ||
            saved.step == GuideStep.correctAndSave);
    return GuideBackendState(
      sessionId: sessionId,
      serverRevision: saved.serverRevision,
      step: unboundCreate ? GuideStep.intro : saved.step,
      createdEventId: saved.createdEventId,
      savedLocalDate: saved.savedLocalDate,
      dateTimeZone: saved.dateTimeZone,
      expectedStartAt: saved.expectedUpdatedStartLocal,
      expectedStartAtReported: true,
      isReplay: saved.isReplay,
    );
  }

  @override
  Future<GuideBeginResult> begin({
    required String uid,
    required String version,
    required String requestId,
  }) =>
      _serialize(() async {
        if (uid.isEmpty || version.isEmpty) {
          return const GuideBeginFailed(
            GuideFailureDiagnostic(GuideFailureKind.localUidMismatch),
          );
        }
        final state = _stateFor(uid, version, await _load(uid, version));
        if (_terminal(state.step) || state.isReplay) {
          return GuideBeginGranted(state);
        }
        final prefs = await _preferences();
        final key = _ledgerKey(uid, version);
        final now = _now().toUtc();
        final existing = _readLedger(prefs, key);
        final ledger = existing ?? _LocalLedger.start(state.sessionId, now);
        if (ledger.sessionId != state.sessionId) {
          return const GuideBeginFailed(
            GuideFailureDiagnostic(GuideFailureKind.sessionChanged),
          );
        }
        if (!now.isBefore(ledger.hardDeadline)) {
          return const GuideBeginFailed(
            GuideFailureDiagnostic(GuideFailureKind.expired),
          );
        }
        if (existing == null || !now.isBefore(ledger.expiresAt)) {
          await _writeLedger(prefs, key, ledger.renew(now));
        }
        return GuideBeginGranted(state);
      });

  @override
  Future<GuideBackendState> advance({
    required GuideSnapshot snapshot,
    required GuideBackendAction action,
    required String requestId,
    EventModel? event,
    DateTime? expectedStartLocal,
  }) =>
      _serialize(() async {
        final uid = snapshot.uid;
        final version = snapshot.version;
        final key = (uid, version);
        final saved = await _load(uid, version);
        final current = _stateFor(uid, version, saved);
        if (uid.isEmpty ||
            snapshot.sessionId != current.sessionId ||
            snapshot.isReplay != current.isReplay ||
            saved == null ||
            saved.run == GuideRun.terminal) {
          throw StateError('Guide session changed');
        }

        final cached = _checkpoints[key];
        // A failed progress save leaves a real event and the original create
        // request. Let confirm rebind that exact event without a new advance.
        if (action == GuideBackendAction.bindCreated &&
            cached?.bindRequestId == requestId &&
            identical(cached?.state, current) &&
            current.createdEventId == event?.id &&
            event?.userId == uid) {
          return current;
        }
        if (snapshot.serverRevision != current.serverRevision) {
          throw StateError('Guide revision changed');
        }

        final step = switch (action) {
          GuideBackendAction.bindCreated => GuideStep.savedDetail,
          GuideBackendAction.detailAck => GuideStep.queryMic,
          GuideBackendAction.queryReady => GuideStep.changeSpeech,
          GuideBackendAction.editPreview => GuideStep.editPreview,
          GuideBackendAction.updateVerified => GuideStep.updatedDetail,
        };
        final binding = action == GuideBackendAction.bindCreated;
        if (binding &&
            (event == null ||
                event.id.isEmpty ||
                event.userId != uid ||
                event.startAt == null ||
                (current.createdEventId != null &&
                    current.createdEventId != event.id))) {
          throw StateError('Guide event binding changed');
        }
        final preview = action == GuideBackendAction.editPreview;
        final prefs = await _preferences();
        final ledgerKey = _ledgerKey(uid, version);
        var ledger = _readLedger(prefs, ledgerKey);
        final bound = ledger?.binding;
        if (!binding) {
          if (bound == null ||
              bound.sessionId != current.sessionId ||
              bound.eventId != current.createdEventId) {
            throw StateError('Guide event binding changed');
          }
          if (preview &&
              (expectedStartLocal == null ||
                  _calendarDay(expectedStartLocal.toLocal()) != bound.day)) {
            throw StateError('Guide edit preview must stay on the saved date');
          }
          final updated = action == GuideBackendAction.updateVerified;
          final verifiedStart = updated ? current.expectedStartAt : null;
          if (updated && verifiedStart == null) {
            throw StateError('Guide edit preview is missing');
          }
          final latestEvent = await _fetchBoundEvent(uid, bound.eventId);
          if (!_isEligibleTarget(latestEvent, uid, bound.eventId) ||
              !bound.matches(latestEvent!, expectedStart: verifiedStart)) {
            throw StateError('Guide event binding changed');
          }
          final latestProgress = await _load(uid, version);
          if (latestProgress == null ||
              latestProgress.sessionId != saved.sessionId ||
              latestProgress.revision != saved.revision ||
              latestProgress.run != saved.run) {
            throw StateError('Guide progress changed during event read');
          }
        }
        final now = _now().toUtc();
        if (!current.isReplay) {
          if (ledger == null ||
              ledger.sessionId != current.sessionId ||
              !now.isBefore(ledger.expiresAt)) {
            throw StateError('Guide session expired');
          }
          ledger = ledger.renew(now);
        }
        if (binding) {
          final persistedEvent = event!;
          if (bound != null && bound.sessionId == current.sessionId) {
            // A pending save retry must keep the first persisted baseline.
            if (bound.eventId != persistedEvent.id ||
                !bound.matches(persistedEvent)) {
              throw StateError('Guide event binding changed');
            }
          } else {
            final newBinding =
                _LocalBinding.fromEvent(current.sessionId, persistedEvent);
            ledger = (ledger ?? _LocalLedger.start(current.sessionId, now))
                .withBinding(newBinding);
          }
        }
        if (!current.isReplay || binding) {
          await _writeLedger(prefs, ledgerKey, ledger!);
        }

        final advanced = GuideBackendState(
          sessionId: current.sessionId,
          serverRevision: snapshot.serverRevision + 1,
          step: step,
          createdEventId: binding ? event!.id : snapshot.createdEventId,
          savedLocalDate: binding ? event!.startAt : snapshot.savedLocalDate,
          dateTimeZone: snapshot.dateTimeZone,
          expectedStartAt:
              preview ? expectedStartLocal : current.expectedStartAt,
          expectedStartAtReported: true,
          isReplay: current.isReplay,
        );
        _checkpoints[key] = _LocalCheckpoint(
          advanced,
          bindRequestId: binding ? requestId : null,
        );
        return advanced;
      });

  @override
  Future<GuideAccess> authorize({
    required GuideChargeContext context,
    required String operationId,
  }) =>
      _serialize(() async {
        if (operationId.trim().isEmpty || operationId.length > 128) {
          return const GuideAccess(
            status: GuideAccessStatus.denied,
            reasonCode: 'invalid_operation_id',
          );
        }
        try {
          final saved = await _load(context.uid, context.version);
          if (saved == null || !_matchesContext(saved, context)) {
            return const GuideAccess(
              status: GuideAccessStatus.denied,
              reasonCode: 'stale_context',
            );
          }
          if (saved.isReplay) {
            return const GuideAccess(
              status: GuideAccessStatus.denied,
              reasonCode: 'ordinary_quota_required',
            );
          }
          if (!_allowed(context)) {
            return const GuideAccess(
              status: GuideAccessStatus.denied,
              reasonCode: 'wrong_phase',
            );
          }

          final prefs = await _preferences();
          final key = _ledgerKey(context.uid, context.version);
          final ledger = _readLedger(prefs, key);
          if (ledger == null || ledger.sessionId != context.sessionId) {
            return const GuideAccess(
              status: GuideAccessStatus.denied,
              reasonCode: 'session_missing_or_terminal',
            );
          }
          var now = _now().toUtc();
          if (!now.isBefore(ledger.expiresAt)) {
            return const GuideAccess(
              status: GuideAccessStatus.expired,
              reasonCode: 'session_expired',
            );
          }
          if (context.operation != GuideOperation.createParse) {
            final eventId = context.createdEventId!;
            final EventModel? event;
            try {
              event = await _fetchBoundEvent(context.uid, eventId);
            } catch (_) {
              return const GuideAccess(
                status: GuideAccessStatus.unavailable,
                reasonCode: 'target_read_unavailable',
              );
            }
            if (!_isEligibleTarget(event, context.uid, eventId)) {
              return const GuideAccess(
                status: GuideAccessStatus.denied,
                reasonCode: 'target_not_eligible',
              );
            }
            // Progress can change while the normal event lookup is in flight.
            final latest = await _load(context.uid, context.version);
            if (latest == null ||
                latest.isReplay ||
                !_matchesContext(latest, context)) {
              return const GuideAccess(
                status: GuideAccessStatus.denied,
                reasonCode: 'stale_context',
              );
            }
            now = _now().toUtc();
          }
          if (!now.isBefore(ledger.expiresAt)) {
            return const GuideAccess(
              status: GuideAccessStatus.expired,
              reasonCode: 'session_expired',
            );
          }
          final existing = ledger.operations[operationId];
          if (existing != null) {
            if (existing.operation != context.operation ||
                existing.serverRevision != context.serverRevision) {
              return const GuideAccess(
                status: GuideAccessStatus.denied,
                reasonCode: 'operation_replay_mismatch',
              );
            }
            if (!now.isBefore(existing.expiresAt)) {
              return const GuideAccess(
                status: GuideAccessStatus.expired,
                reasonCode: 'grant_expired',
              );
            }
          } else if (ledger.operations.length >= _operationLimit) {
            return const GuideAccess(
              status: GuideAccessStatus.denied,
              reasonCode: 'guide_operation_limit',
            );
          }

          final grant = existing ??
              _LocalGrant(
                operation: context.operation,
                serverRevision: context.serverRevision,
                expiresAt: _earlier(now.add(_grantLease), ledger.expiresAt),
              );
          ledger.operations[operationId] = grant;
          // Legacy prefs can update their cache before acknowledging a disk
          // write. Require a successful write even on retry before granting.
          await _writeLedger(prefs, key, ledger);
          return GuideAccess(
            status: GuideAccessStatus.granted,
            permit: GuidePermit(
              grantId: 'local:$operationId',
              uid: context.uid,
              sessionId: context.sessionId,
              operationId: operationId,
              kind: context.kind,
              operation: context.operation,
              expiresAtUtc: grant.expiresAt,
            ),
          );
        } catch (_) {
          return const GuideAccess(
            status: GuideAccessStatus.unavailable,
            reasonCode: 'guide_storage_unavailable',
          );
        }
      });

  bool _matchesContext(GuideSnapshot saved, GuideChargeContext context) =>
      saved.run == GuideRun.active &&
      saved.sessionId == context.sessionId &&
      saved.revision == context.revision &&
      saved.serverRevision == context.serverRevision &&
      saved.step == context.phase &&
      saved.createdEventId == context.createdEventId &&
      _stateFor(context.uid, context.version, saved).serverRevision ==
          context.serverRevision;

  static bool _isEligibleTarget(EventModel? event, String uid, String id) =>
      event != null &&
      event.id == id &&
      event.userId == uid &&
      event.groupEventId == null &&
      event.parentEventId == null &&
      event.recurrenceRule == null &&
      event.externalId == null &&
      (event.source == 'manual' || event.source == 'voice');

  static bool _allowed(GuideChargeContext context) =>
      switch ((context.operation, context.kind)) {
        (GuideOperation.createParse, GuideChargeKind.scheduleParse) =>
          context.phase == GuideStep.createSpeech ||
              context.phase == GuideStep.correctAndSave,
        (GuideOperation.query, GuideChargeKind.voiceConversation) =>
          context.createdEventId?.isNotEmpty == true &&
              (context.phase == GuideStep.querySpeech ||
                  context.phase == GuideStep.queryResults),
        (GuideOperation.changeTime, GuideChargeKind.voiceConversation) =>
          context.createdEventId?.isNotEmpty == true &&
              (context.phase == GuideStep.changeSpeech ||
                  context.phase == GuideStep.editPreview),
        _ => false,
      };

  @override
  Future<void> finish({
    required GuideSnapshot snapshot,
    required GuideExit exit,
    required String requestId,
  }) async {}

  @override
  Future<GuideBackendState?> restart({
    required String uid,
    required String version,
    required String previousSessionId,
    required String requestId,
  }) =>
      _serialize(() async {
        final saved = await _load(uid, version);
        if (uid.isEmpty ||
            saved?.sessionId != previousSessionId ||
            saved?.run != GuideRun.terminal) {
          return null;
        }
        final current = _stateFor(uid, version, saved);
        if (current.sessionId != previousSessionId) return current;
        if (!_terminal(current.step)) return null;

        final random = Random.secure();
        final nonce = base64UrlEncode(
          List<int>.generate(16, (_) => random.nextInt(256)),
        );
        final replay = GuideBackendState(
          sessionId: 'local-replay-$nonce',
          serverRevision: 0,
          step: GuideStep.intro,
          expectedStartAtReported: true,
          isReplay: true,
        );
        _checkpoints[(uid, version)] =
            _LocalCheckpoint(replay, previousSessionId: previousSessionId);
        return replay;
      });

  static Future<SharedPreferences> _preferences() async =>
      await tryGetPrefs() ?? (throw StateError('Guide storage unavailable'));

  static String _ledgerKey(String uid, String version) =>
      'guide_operations:$version:$uid';

  static _LocalLedger? _readLedger(SharedPreferences prefs, String key) {
    final raw = prefs.getString(key);
    if (raw == null) return null;
    return _LocalLedger.fromJson(jsonDecode(raw) as Map<String, dynamic>);
  }

  static Future<void> _writeLedger(
    SharedPreferences prefs,
    String key,
    _LocalLedger ledger,
  ) async {
    final raw = jsonEncode(ledger.toJson());
    if (!await prefs.setString(key, raw) || prefs.getString(key) != raw) {
      throw StateError('Guide ledger write failed');
    }
  }
}

class _LocalCheckpoint {
  const _LocalCheckpoint(this.state,
      {this.bindRequestId, this.previousSessionId});

  final GuideBackendState state;
  final String? bindRequestId, previousSessionId;
}

class _LocalLedger {
  _LocalLedger(this.sessionId, this.startedAt, this.expiresAt, this.operations,
      {this.binding});

  // Matches the previous server contract: a renewable one-hour session is
  // capped at seven days from its original start, including across restarts.
  static const _window = Duration(minutes: 60);
  static const _lifetime = Duration(days: 7);

  factory _LocalLedger.start(String sessionId, DateTime now) =>
      _LocalLedger(sessionId, now, now.add(_window), {});

  factory _LocalLedger.fromJson(Map<String, dynamic> raw) {
    final operations = raw['operations'] as Map<String, dynamic>;
    final binding = raw['binding'];
    final ledger = _LocalLedger(
      raw['sessionId'] as String,
      DateTime.parse(raw['startedAt'] as String).toUtc(),
      DateTime.parse(raw['expiresAt'] as String).toUtc(),
      operations.map((id, value) =>
          MapEntry(id, _LocalGrant.fromJson(value as Map<String, dynamic>))),
      binding: binding == null
          ? null
          : _LocalBinding.fromJson(binding as Map<String, dynamic>),
    );
    if (ledger.sessionId.isEmpty ||
        ledger.expiresAt.isAfter(ledger.hardDeadline) ||
        !ledger.expiresAt.isAfter(ledger.startedAt)) {
      throw const FormatException('Invalid guide ledger');
    }
    return ledger;
  }

  final String sessionId;
  final DateTime startedAt, expiresAt;
  final Map<String, _LocalGrant> operations;
  final _LocalBinding? binding;

  DateTime get hardDeadline => startedAt.add(_lifetime);

  _LocalLedger renew(DateTime now) => _LocalLedger(
        sessionId,
        startedAt,
        _earlier(now.add(_window), hardDeadline),
        operations,
        binding: binding,
      );

  _LocalLedger withBinding(_LocalBinding binding) =>
      _LocalLedger(sessionId, startedAt, expiresAt, operations,
          binding: binding);

  Map<String, Object> toJson() => {
        'sessionId': sessionId,
        'startedAt': startedAt.toIso8601String(),
        'expiresAt': expiresAt.toIso8601String(),
        'operations':
            operations.map((id, grant) => MapEntry(id, grant.toJson())),
        if (binding != null) 'binding': binding!.toJson(),
      };
}

class _LocalBinding {
  const _LocalBinding(this.sessionId, this.eventId, this.detailsDigest,
      this.day, this.offsetMinutes);

  factory _LocalBinding.fromEvent(String sessionId, EventModel event) {
    final start = event.startAt!.toLocal();
    return _LocalBinding(sessionId, event.id, _detailsDigest(event),
        _calendarDay(start), start.timeZoneOffset.inMinutes);
  }

  factory _LocalBinding.fromJson(Map<String, dynamic> raw) => _LocalBinding(
        raw['sessionId'] as String,
        raw['eventId'] as String,
        raw['detailsDigest'] as String,
        DateTime.parse(raw['day'] as String).toUtc(),
        raw['offsetMinutes'] as int,
      );

  final String sessionId, eventId, detailsDigest;
  final DateTime day;
  final int offsetMinutes;

  bool matches(EventModel event, {DateTime? expectedStart}) {
    final start = event.startAt;
    if (start == null || _detailsDigest(event) != detailsDigest) return false;
    // The preview already checked the saved day using its calendar offset.
    if (expectedStart != null) return start.isAtSameMomentAs(expectedStart);
    // Before the update, interpret the row using the offset at binding time.
    return _calendarDay(start.toUtc().add(Duration(minutes: offsetMinutes))) ==
        day;
  }

  // Compare the bound title and location without storing a copy in prefs.
  static String _detailsDigest(EventModel event) => sha256
      .convert(utf8.encode(jsonEncode([event.title, event.location])))
      .toString();

  Map<String, Object?> toJson() => {
        'sessionId': sessionId,
        'eventId': eventId,
        'detailsDigest': detailsDigest,
        'day': day.toIso8601String(),
        'offsetMinutes': offsetMinutes,
      };
}

class _LocalGrant {
  const _LocalGrant({
    required this.operation,
    required this.serverRevision,
    required this.expiresAt,
  });

  factory _LocalGrant.fromJson(Map<String, dynamic> raw) => _LocalGrant(
        operation: GuideOperation.values.byName(raw['operation'] as String),
        serverRevision: raw['serverRevision'] as int,
        expiresAt: DateTime.parse(raw['expiresAt'] as String).toUtc(),
      );

  final GuideOperation operation;
  final int serverRevision;
  final DateTime expiresAt;

  Map<String, Object> toJson() => {
        'operation': operation.name,
        'serverRevision': serverRevision,
        'expiresAt': expiresAt.toIso8601String(),
      };
}

DateTime _earlier(DateTime first, DateTime second) =>
    first.isBefore(second) ? first : second;

DateTime _calendarDay(DateTime date) =>
    DateTime.utc(date.year, date.month, date.day);
