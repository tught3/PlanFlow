import 'dart:async';

import 'package:flutter/foundation.dart';
import '../../core/diag_logger.dart';
import 'guide_contract.dart';

class RealUiGuideCoordinator
    implements GuideCoordinator, GuideReplayCoordinator {
  RealUiGuideCoordinator(
      {required GuideBackendPort backend,
      required GuideProgressStore progress,
      required this.version})
      : _backend = backend,
        _progress = progress,
        _state = ValueNotifier<GuideSnapshot>(GuideSnapshot(
            uid: '',
            version: version,
            revision: 0,
            serverRevision: 0,
            step: GuideStep.intro,
            run: GuideRun.blocked));
  final GuideBackendPort _backend;
  final GuideProgressStore _progress;
  final String version;
  final ValueNotifier<GuideSnapshot> _state;
  static const String _pendingCode = guideCreatedCheckpointPendingCode;
  static const String _conflictCode = 'created_binding_conflict';
  static const String _qaPendingBindingCode =
      guideQaSavedBindingUnconfirmedCode;
  static const bool _qaAdvanceEnabled = guideQaAdvanceEnabled;

  static DateTime _plainDateTime(DateTime value) =>
      value.runtimeType == DateTime
          ? value
          : DateTime.fromMicrosecondsSinceEpoch(
              value.microsecondsSinceEpoch,
              isUtc: value.isUtc,
            );

  int _epoch = 0;
  final Set<String> _inFlight = <String>{};
  @override
  ValueListenable<GuideSnapshot> get state => _state;
  bool get _live =>
      _state.value.uid.isNotEmpty && _state.value.run != GuideRun.terminal;
  void _set(GuideSnapshot s) => _state.value = s;
  @override
  Future<GuideSnapshot> start({
    required String uid,
    bool skipIncompleteOnColdStart = false,
  }) async {
    final epoch = ++_epoch;
    final initial = _state.value;
    final fresh = GuideSnapshot(
        uid: uid,
        version: version,
        revision: 0,
        serverRevision: 0,
        step: GuideStep.intro,
        run: GuideRun.active,
        calendarSyncHeld: true);
    GuideSnapshot? loaded;
    try {
      loaded = await _progress.load(uid: uid, version: version);
    } catch (_) {
      if (_current(initial, epoch)) {
        const failure =
            GuideFailureDiagnostic(GuideFailureKind.progressLoadFailed);
        final currentUser = initial.uid == uid && initial.version == version;
        // Never overwrite a checkpoint we could not read.
        _set(_withFailure(currentUser ? initial : fresh, failure));
        _logFailure(failure);
      }
      return _state.value;
    }
    if (!_current(initial, epoch)) return _state.value;
    // Storage is not an authority for another account or guide version.
    final local =
        loaded?.uid == uid && loaded?.version == version ? loaded : null;
    if (local != null && local.run == GuideRun.terminal) {
      // A finished local run must never open a session or be resurrected by
      // an unavailable backend. Retain its entire checkpoint without a write.
      _set(local.mayListenContinuously
          ? local.copyWith(mayListenContinuously: false)
          : local);
      return _state.value;
    }
    if (skipIncompleteOnColdStart && local != null) {
      return _skipIncompleteRun(local, initial, epoch);
    }
    final result = await _begin(uid: uid, requestId: 'begin:$uid:$version');
    if (!_current(initial, epoch)) return _state.value;
    final base = local ?? fresh;
    final snapshot = switch (result) {
      GuideBeginGranted(:final state) =>
        _reconcile(base, state, allowUnboundConflictRecovery: true),
      final GuideBeginFailed failed => _afterBeginFailure(base, failed),
    };
    final beginFailure = snapshot.failureDiagnostic;
    if (beginFailure != null) _logFailure(beginFailure);
    try {
      await _progress.save(snapshot);
      if (_current(initial, epoch)) _set(snapshot);
    } catch (_) {
      const storeFailure =
          GuideFailureDiagnostic(GuideFailureKind.progressSaveFailed);
      _logFailure(storeFailure);
      if (_current(initial, epoch)) {
        // Keep the pre-existing checkpoint if persistence failed and keep
        // the begin failure visible when logging that failure also failed.
        final failed = _withFailure(base, beginFailure ?? storeFailure);
        _set(failed);
        await _saveFailureCheckpoint(failed);
      }
    }
    return _state.value;
  }

  Future<GuideSnapshot> _skipIncompleteRun(
      GuideSnapshot local, GuideSnapshot initial, int epoch) async {
    var checkpoint = local;
    if (local.sessionId?.isNotEmpty != true) {
      // An intro marker can exist before begin has bound a session. Resolve
      // its real identity so Settings can restart it after the exit.
      final result = await _begin(
          uid: local.uid, requestId: 'begin:${local.uid}:$version');
      if (!_current(initial, epoch)) return _state.value;
      final remote = switch (result) {
        GuideBeginGranted(:final state) => state,
        GuideBeginFailed(:final failure, :final terminalPredecessor)
            when failure.kind == GuideFailureKind.terminal &&
                (terminalPredecessor?.step == GuideStep.completed ||
                    terminalPredecessor?.step == GuideStep.skipped) =>
          terminalPredecessor,
        _ => null,
      };
      if (remote != null && remote.sessionId.isNotEmpty) {
        checkpoint = local.copyWith(
          sessionId: remote.sessionId,
          serverRevision: remote.serverRevision,
          step: remote.step,
          isReplay: remote.isReplay,
          createdEventId: remote.createdEventId,
          savedLocalDate: remote.savedLocalDate,
          dateTimeZone: remote.dateTimeZone,
        );
      }
    }
    final alreadyTerminal = checkpoint.step == GuideStep.completed ||
        checkpoint.step == GuideStep.skipped;
    final skipped = checkpoint.copyWith(
      run: GuideRun.terminal,
      step: alreadyTerminal ? checkpoint.step : GuideStep.skipped,
      calendarSyncHeld: false,
      mayListenContinuously: false,
      clearErrorCode: true,
      clearFailureDiagnostic: true,
      revision: local.revision + 1,
    );
    // Closing the visible guide must work when persistence is unavailable.
    await _saveFailureCheckpoint(skipped);
    if (!_current(initial, epoch)) return _state.value;
    _set(skipped);
    if (!alreadyTerminal &&
        checkpoint.sessionId?.isNotEmpty == true &&
        _current(skipped, epoch)) {
      await _finishServerSession(checkpoint, GuideExit.skip);
    }
    return _state.value;
  }

  Future<GuideBeginResult> _begin(
      {required String uid, required String requestId}) async {
    try {
      return await _backend
          .begin(uid: uid, version: version, requestId: requestId)
          .timeout(guideBeginTimeout);
    } on TimeoutException {
      return const GuideBeginFailed(
          GuideFailureDiagnostic(GuideFailureKind.timeout));
    } catch (_) {
      return const GuideBeginFailed(
          GuideFailureDiagnostic(GuideFailureKind.backendUnavailable));
    }
  }

  static bool _isBindingCheckpoint(GuideSnapshot snapshot) =>
      snapshot.errorCode == _pendingCode ||
      snapshot.errorCode == _conflictCode ||
      snapshot.errorCode == _qaPendingBindingCode;

  static GuideSnapshot _withFailure(
    GuideSnapshot before,
    GuideFailureDiagnostic failure, {
    GuideRun run = GuideRun.blocked,
  }) =>
      before.copyWith(
          run: run,
          errorCode:
              _isBindingCheckpoint(before) ? before.errorCode : failure.code,
          failureDiagnostic: failure,
          mayListenContinuously: false);

  GuideSnapshot _afterBeginFailure(
      GuideSnapshot before, GuideBeginFailed failure,
      {bool retry = false}) {
    final predecessor = failure.terminalPredecessor;
    if (failure.failure.kind == GuideFailureKind.terminal &&
        predecessor != null &&
        (predecessor.step == GuideStep.completed ||
            predecessor.step == GuideStep.skipped) &&
        !_isBindingCheckpoint(before)) {
      // Modern wire can restore the real terminal checkpoint for Settings
      // replay. A legacy denial has no predecessor and remains blocked.
      final terminal = _reconcile(before, predecessor);
      return terminal.copyWith(failureDiagnostic: failure.failure);
    }
    final transient = switch (failure.failure.kind) {
      GuideFailureKind.timeout ||
      GuideFailureKind.network ||
      GuideFailureKind.backendUnavailable =>
        true,
      _ => false,
    };
    final bindingCheckpoint = _isBindingCheckpoint(before);
    final unboundCreate = !bindingCheckpoint &&
        before.createdEventId == null &&
        before.sessionId != null &&
        (before.step == GuideStep.createSpeech ||
            before.step == GuideStep.correctAndSave);
    if (retry &&
        transient &&
        !bindingCheckpoint &&
        !unboundCreate &&
        before.errorCode != null) {
      // A failed retry adds diagnostic evidence without replacing the
      // checkpoint that still requires a canonical response.
      return before.copyWith(
          failureDiagnostic: failure.failure, mayListenContinuously: false);
    }
    final normalized = transient && unboundCreate
        ? before.copyWith(step: GuideStep.homeMic)
        : before;
    return _withFailure(normalized, failure.failure,
        run: transient && !bindingCheckpoint && (!retry || unboundCreate)
            ? GuideRun.active
            : GuideRun.blocked);
  }

  static void _logFailure(GuideFailureDiagnostic failure) {
    final details = [
      'code=${failure.code}',
      if (failure.reasonCode case final reason?) 'reason_code=$reason',
      if (failure.phase case final phase?) 'phase=$phase',
      if (failure.statusCode case final status?) 'status=$status',
    ];
    DiagLogger.log('RealUiGuide', details.join(' '));
  }

  Future<void> _saveFailureCheckpoint(GuideSnapshot snapshot) async {
    try {
      await _progress.save(snapshot);
    } catch (_) {
      _logFailure(
          const GuideFailureDiagnostic(GuideFailureKind.progressSaveFailed));
    }
  }

  bool _current(GuideSnapshot before, int epoch) =>
      epoch == _epoch && identical(_state.value, before);

  @override
  Future<bool> restartCompletedGuide({required String uid}) async {
    final before = _state.value;
    final backend = _backend;
    final previous = before.sessionId;
    if (backend is! GuideReplayBackendPort ||
        uid.isEmpty ||
        before.uid != uid ||
        before.run != GuideRun.terminal ||
        (before.step != GuideStep.completed &&
            before.step != GuideStep.skipped) ||
        previous == null ||
        previous.isEmpty) {
      return false;
    }
    final epoch = _epoch;
    final key = 'restart:$previous';
    if (!_inFlight.add(key)) return false;
    try {
      final replayBackend = backend as GuideReplayBackendPort;
      Future<GuideBackendState?> currentServerSession() async {
        final outcome =
            await _begin(uid: uid, requestId: 'replay-check:$previous');
        return switch (outcome) {
          GuideBeginGranted(:final state) => state,
          GuideBeginFailed(:final terminalPredecessor) => terminalPredecessor,
        };
      }

      var remote = await currentServerSession();
      if (!_current(before, epoch) || remote == null) return false;

      final predecessor = remote.sessionId;
      if (predecessor != previous && !remote.isReplay) return false;
      if (remote.step == GuideStep.completed ||
          remote.step == GuideStep.skipped ||
          (predecessor == previous && remote.step == GuideStep.updatedDetail)) {
        // A legacy client may have completed locally while its server phase
        // remained updated. Only that exact cached session may use this path.
        remote = await replayBackend.restart(
            uid: uid,
            version: version,
            previousSessionId: predecessor,
            requestId: 'restart:$predecessor');
        if (!_current(before, epoch)) return false;
        // A concurrent device can win the restart after our read. Continue
        // its active successor without creating another session.
        remote ??= await currentServerSession();
      }
      if (!_current(before, epoch) ||
          remote == null ||
          !remote.isReplay ||
          remote.sessionId.isEmpty ||
          remote.sessionId == previous ||
          remote.step == GuideStep.completed ||
          remote.step == GuideStep.skipped) {
        return false;
      }
      final base = GuideSnapshot(
          uid: uid,
          version: version,
          revision: before.revision + 1,
          serverRevision: 0,
          step: GuideStep.homeMic,
          run: GuideRun.active,
          dateTimeZone: before.dateTimeZone,
          isReplay: true,
          calendarSyncHeld: true);
      final replay = _reconcile(base, remote);
      if (replay.run != GuideRun.active) return false;
      await _progress.save(replay);
      if (!_current(before, epoch)) return false;
      _set(replay);
      return true;
    } catch (_) {
      return false;
    } finally {
      _inFlight.remove(key);
    }
  }

  // Shared read-only reconciliation for cold start and explicit retry.
  // A pending checkpoint is not proof of a server binding. Keep its actual
  // event/operation/session fence rather than manufacture or replay a bind.
  GuideSnapshot _reconcile(GuideSnapshot local, GuideBackendState remote,
      {bool allowUnboundConflictRecovery = false}) {
    // The local backend projects its stored UI checkpoint in begin replies.
    // These UI-only phases have the same authority as the durable update.
    final serverStep = switch (remote.step) {
      GuideStep.syncChoice ||
      GuideStep.completionConfirm ||
      GuideStep.syncChoiceConfirmed =>
        GuideStep.updatedDetail,
      final step => step,
    };
    if ((remote.isReplay || local.isReplay) &&
        local.sessionId != null &&
        (local.sessionId != remote.sessionId ||
            local.isReplay != remote.isReplay)) {
      return local.copyWith(
          run: GuideRun.blocked,
          errorCode: 'guide_session_changed',
          failureDiagnostic:
              const GuideFailureDiagnostic(GuideFailureKind.sessionChanged),
          mayListenContinuously: false);
    }
    final localId = local.createdEventId;
    final differentIds = localId != null &&
        remote.createdEventId != null &&
        localId != remote.createdEventId;
    if (differentIds) {
      return local.copyWith(
          run: GuideRun.blocked,
          errorCode: _conflictCode,
          clearFailureDiagnostic: true,
          mayListenContinuously: false);
    }
    final boundPreview = serverStep == GuideStep.editPreview ||
        serverStep == GuideStep.updatedDetail;
    final sameBoundSession = local.sessionId == remote.sessionId &&
        localId != null &&
        localId.isNotEmpty &&
        localId == remote.createdEventId;
    if (boundPreview && remote.createdEventId?.isNotEmpty != true) {
      return _withFailure(
          local,
          GuideFailureDiagnostic.fromWire(GuideFailureKind.boundEventMissing,
              phase:
                  serverStep == GuideStep.editPreview ? 'preview' : 'updated'));
    }
    if (boundPreview &&
        ((local.sessionId != null && local.sessionId != remote.sessionId) ||
            (localId != null && !sameBoundSession) ||
            remote.serverRevision < local.serverRevision)) {
      return local.copyWith(
          run: GuideRun.blocked,
          errorCode: 'guide_operation_failed',
          clearFailureDiagnostic: true,
          mayListenContinuously: false);
    }
    if (local.step == GuideStep.editPreview &&
        serverStep == GuideStep.changeSpeech &&
        (local.expectedUpdatedStartLocal != null ||
            local.sessionId == null ||
            local.sessionId != remote.sessionId ||
            localId == null ||
            localId.isEmpty ||
            localId != remote.createdEventId ||
            remote.serverRevision < local.serverRevision)) {
      // Older clients persisted 'edit' as a preview without a start time.
      // Only the same bound session can identify that legacy checkpoint.
      final transientFailure = const {
            GuideFailureKind.timeout,
            GuideFailureKind.network,
            GuideFailureKind.backendUnavailable,
          }.contains(local.failureDiagnostic?.kind) ||
          const {'timeout', 'network', 'backend_unavailable'}
              .contains(local.errorCode);
      final protectedFailure = _isBindingCheckpoint(local) ||
          local.errorCode == 'guide_session_changed' ||
          local.errorCode == 'guide_bound_event_missing' ||
          local.failureDiagnostic?.kind == GuideFailureKind.sessionChanged ||
          local.failureDiagnostic?.kind == GuideFailureKind.boundEventMissing;
      final preserveFailure = protectedFailure ||
          (!transientFailure &&
              (local.errorCode != null || local.failureDiagnostic != null));
      return local.copyWith(
          run: GuideRun.blocked,
          errorCode: preserveFailure
              ? local.errorCode ?? local.failureDiagnostic!.code
              : 'guide_operation_failed',
          failureDiagnostic: preserveFailure
              ? local.failureDiagnostic
              : const GuideFailureDiagnostic(GuideFailureKind.operationFailed),
          mayListenContinuously: false);
    }
    if (allowUnboundConflictRecovery &&
        local.errorCode == _conflictCode &&
        localId != null &&
        remote.createdEventId == null) {
      // server-side session reset (QA revalidation): local binding is the only binding
      return local.copyWith(
          sessionId: remote.sessionId,
          serverRevision: remote.serverRevision,
          run: GuideRun.active,
          clearErrorCode: true,
          mayListenContinuously: false);
    }
    if (local.errorCode == _pendingCode || local.errorCode == _conflictCode) {
      return local.copyWith(
          run: GuideRun.blocked,
          clearFailureDiagnostic: true,
          mayListenContinuously: false);
    }
    // A saved binding from a known session cannot be grafted onto a new,
    // unbound create session. A matching canonical ID is binding evidence.
    if (localId != null &&
        local.sessionId != null &&
        local.sessionId != remote.sessionId &&
        remote.createdEventId == null) {
      return local.copyWith(
          run: GuideRun.blocked,
          errorCode: _conflictCode,
          clearFailureDiagnostic: true,
          mayListenContinuously: false);
    }
    // Preserve intro-seen markers, but discard unbound ephemeral create
    // substeps when the server still reports its coarse intro/home phase.
    // No parse/write/bind is replayed: the user can explicitly tap the home mic
    // again. Bound stages remain restorable only with their binding evidence.
    final sameSessionUnboundCreate = localId == null &&
        local.sessionId != null &&
        local.sessionId == remote.sessionId &&
        remote.createdEventId == null &&
        serverStep == GuideStep.intro &&
        (local.step == GuideStep.createSpeech ||
            local.step == GuideStep.correctAndSave);
    final localFinalStep = switch (local.step) {
      GuideStep.syncChoice ||
      GuideStep.completionConfirm =>
        GuideStep.completionConfirm,
      GuideStep.syncChoiceConfirmed => GuideStep.syncChoiceConfirmed,
      _ => null,
    };
    final awaitingFinalChoice = localFinalStep != null;
    final retainLocalStep = serverStep == GuideStep.intro &&
        !awaitingFinalChoice &&
        (local.step == GuideStep.homeMic ||
            (localId != null &&
                (local.sessionId == remote.sessionId ||
                    localId == remote.createdEventId)));
    final remoteStep = sameSessionUnboundCreate
        ? GuideStep.homeMic
        : retainLocalStep
            ? local.step
            : serverStep;
    // Older deployments omit the accepted start. Only a local checkpoint
    // from the exact same bound revision can fill that omission.
    final keepLocalPreview = !remote.expectedStartAtReported &&
        sameBoundSession &&
        remote.serverRevision == local.serverRevision &&
        (remoteStep == GuideStep.editPreview ||
            remoteStep == GuideStep.updatedDetail) &&
        (local.step == GuideStep.editPreview ||
            local.step == GuideStep.updatedDetail ||
            (awaitingFinalChoice && serverStep == GuideStep.updatedDetail));
    final expectedStart = boundPreview && remote.expectedStartAt != null
        ? _plainDateTime(remote.expectedStartAt!.toUtc())
        : keepLocalPreview
            ? local.expectedUpdatedStartLocal == null
                ? null
                : _plainDateTime(local.expectedUpdatedStartLocal!.toUtc())
            : null;
    // Final prompts are local stages of the verified server update. Restore a
    // prompt only if the server still confirms its exact update checkpoint.
    final retainFinalChoice = awaitingFinalChoice &&
        serverStep == GuideStep.updatedDetail &&
        sameBoundSession &&
        remote.serverRevision == local.serverRevision &&
        expectedStart != null &&
        local.expectedUpdatedStartLocal?.isAtSameMomentAs(expectedStart) ==
            true;
    final step = (retainFinalChoice ? localFinalStep : null) ?? remoteStep;
    final done = step == GuideStep.completed || step == GuideStep.skipped;
    return local.copyWith(
        sessionId: remote.sessionId,
        serverRevision: remote.serverRevision,
        step: step,
        run: done ? GuideRun.terminal : GuideRun.active,
        clearErrorCode: true,
        createdEventId: localId ?? remote.createdEventId,
        savedLocalDate: local.savedLocalDate ?? remote.savedLocalDate,
        expectedUpdatedStartLocal: expectedStart,
        clearExpectedUpdatedStartLocal: expectedStart == null,
        dateTimeZone: remote.dateTimeZone ?? local.dateTimeZone,
        isReplay: remote.isReplay,
        calendarSyncHeld: done ? false : local.calendarSyncHeld,
        mayListenContinuously: false);
  }

  @override
  Future<GuideSnapshot> dispatch(GuideSignal signal) async {
    final before = _state.value;
    if (signal.uid != before.uid ||
        signal.expectedRevision != before.revision ||
        (signal.sessionId != null && signal.sessionId != before.sessionId) ||
        before.run == GuideRun.terminal) {
      return before;
    }
    final key =
        '${signal.runtimeType}:${signal.expectedRevision}:${signal.sessionId}';
    if (!_inFlight.add(key)) {
      return before;
    }
    if (signal is SpeechObserved && before.step == GuideStep.createSpeech) {
      final updated = before.copyWith(speechCaptured: signal.present);
      _set(updated);
      return updated;
    }
    final epoch = _epoch;
    // Identity of the snapshot this dispatch itself published, so a failing
    // persist after publish still fails closed (never swallowed).
    GuideSnapshot? published;
    try {
      GuideSnapshot? next;
      switch (signal) {
        case IntroFinished():
          if (before.step == GuideStep.intro) {
            next =
                before.copyWith(step: GuideStep.homeMic, run: GuideRun.active);
          }
        case HomeMicTapped():
          if (before.step == GuideStep.homeMic) {
            next = before.copyWith(
                step: GuideStep.createSpeech,
                run: GuideRun.active,
                speechCaptured: false);
          }
        case CaptureStarted():
          // Native ready means the recognizer opened, not that speech exists.
          break;
        case SpeechObserved():
          // Handled above as local transient UI state only.
          break;
        case ParseConfirmed():
          if (before.step == GuideStep.createSpeech) {
            next = before.copyWith(
                step: GuideStep.correctAndSave, speechCaptured: false);
          }
        case CorrectionObserved():
          break;
        case SaveObserved(:final persistedEvent, :final operationId):
          if (before.step == GuideStep.correctAndSave &&
              persistedEvent.id.isNotEmpty &&
              (before.createdEventId == null ||
                  before.createdEventId == persistedEvent.id) &&
              (before.savedCreateOperationId == null ||
                  before.savedCreateOperationId == operationId) &&
              persistedEvent.userId == before.uid &&
              persistedEvent.groupEventId == null &&
              persistedEvent.externalId == null &&
              persistedEvent.recurrenceRule == null &&
              !persistedEvent.isMultiDay &&
              persistedEvent.startAt != null) {
            final remote = await _backend.advance(
                snapshot: before,
                action: GuideBackendAction.bindCreated,
                requestId: operationId,
                event: persistedEvent);
            if (epoch != _epoch ||
                _state.value.uid != signal.uid ||
                _state.value.revision != signal.expectedRevision) {
              return _state.value;
            }
            if (remote.createdEventId != null &&
                remote.createdEventId != persistedEvent.id) {
              // Canonical receipt names another record: keep local ID pending.
              throw StateError('created binding conflict');
            }
            next = before.copyWith(
                step: GuideStep.savedDetail,
                run: GuideRun.active,
                createdEventId: persistedEvent.id,
                savedCreateOperationId: operationId,
                originalStartLocal: _plainDateTime(persistedEvent.startAt!),
                savedLocalDate: _plainDateTime(persistedEvent.startAt!),
                dateTimeZone: remote.dateTimeZone,
                serverRevision: remote.serverRevision);
          }
        case SaveUnconfirmedObserved(:final persistedEvent, :final operationId):
          // QA 전용 로컬 전진: 서버 확인 없이도 실제 저장된 일정으로 다음
          // 안내 단계를 이어간다. 서버 바인딩이 아니므로 createdEventId 는
          // 로컬에만 기록된다. SaveObserved 가 실패해 체크포인트로 남은
          // 상태에서만, 같은 세션·같은 저장 ID·같은 연산으로만 허용된다.
          if (_qaAdvanceEnabled &&
              before.step == GuideStep.correctAndSave &&
              before.run == GuideRun.blocked &&
              before.errorCode == _pendingCode &&
              before.sessionId == signal.sessionId &&
              persistedEvent.id.isNotEmpty &&
              persistedEvent.id == before.createdEventId &&
              operationId.isNotEmpty &&
              operationId == before.savedCreateOperationId &&
              persistedEvent.userId == before.uid &&
              persistedEvent.groupEventId == null &&
              persistedEvent.externalId == null &&
              persistedEvent.recurrenceRule == null &&
              !persistedEvent.isMultiDay &&
              persistedEvent.startAt != null) {
            next = before.copyWith(
                step: GuideStep.savedDetail,
                run: GuideRun.active,
                createdEventId: persistedEvent.id,
                savedCreateOperationId: operationId,
                originalStartLocal: _plainDateTime(persistedEvent.startAt!),
                savedLocalDate: _plainDateTime(persistedEvent.startAt!),
                errorCode: _qaPendingBindingCode,
                mayListenContinuously: false);
          }
        case DetailObserved(
            :final persistedEvent,
            :final preparationResolved,
            :final departureResolved,
            :final setupHelpAcknowledged
          ):
          if (before.step == GuideStep.savedDetail &&
              persistedEvent.id == before.createdEventId &&
              persistedEvent.userId == before.uid &&
              ((preparationResolved && departureResolved) ||
                  setupHelpAcknowledged)) {
            var acknowledgedSnapshot = before;
            if (before.errorCode == _qaPendingBindingCode) {
              // 아직 서버 바인딩이 확인되지 않은 상태다. 같은 저장 ID/연산으로
              // idempotent 재연결을 한 번 시도하고, 서버가 같은 ID를 확인해 주면
              // 그때만 detailAck 로 넘어간다. 새 영수증이나 단계를 만들어내지 않는다.
              final recoveryOperationId = before.savedCreateOperationId;
              if (recoveryOperationId == null || recoveryOperationId.isEmpty) {
                throw StateError('created binding recovery was not confirmed');
              }
              final bound = await _backend.advance(
                  snapshot: before,
                  action: GuideBackendAction.bindCreated,
                  requestId: recoveryOperationId,
                  event: persistedEvent);
              if (bound.createdEventId != persistedEvent.id ||
                  epoch != _epoch ||
                  !identical(_state.value, before)) {
                throw StateError('created binding recovery was not confirmed');
              }
              acknowledgedSnapshot = before.copyWith(
                  serverRevision: bound.serverRevision, clearErrorCode: true);
            }
            final r = await _backend.advance(
                snapshot: acknowledgedSnapshot,
                action: GuideBackendAction.detailAck,
                requestId: 'detail:${before.sessionId}:${before.revision}');
            if (epoch == _epoch) {
              next = before.copyWith(
                  step: GuideStep.queryMic,
                  serverRevision: r.serverRevision,
                  clearErrorCode: true);
            }
          }
        case QueryMicTapped():
          if (before.step == GuideStep.queryMic) {
            next = before.copyWith(step: GuideStep.querySpeech);
          }
        case QueryObserved(:final binding, :final operationId):
          if ((before.step == GuideStep.querySpeech ||
                  before.step == GuideStep.queryResults) &&
              binding.guideRevision == before.revision &&
              binding.firstIsTarget &&
              !binding.missingTarget &&
              !binding.duplicateTarget &&
              !binding.identityIssue &&
              binding.targetEventId == before.createdEventId) {
            final r = await _backend.advance(
                snapshot: before,
                action: GuideBackendAction.queryReady,
                requestId: operationId);
            if (epoch == _epoch) {
              next = before.copyWith(
                  step: GuideStep.changeSpeech,
                  serverRevision: r.serverRevision,
                  mayListenContinuously: true);
            }
          }
        case EditPreviewObserved(
            :final targetEventId,
            :final requestedStartLocal
          ):
          final requestedStart = _plainDateTime(requestedStartLocal);
          if (before.step == GuideStep.changeSpeech &&
              targetEventId == before.createdEventId &&
              requestedStart != before.originalStartLocal) {
            final r = await _backend.advance(
                snapshot: before,
                action: GuideBackendAction.editPreview,
                requestId: 'preview:${before.sessionId}:${before.revision}',
                expectedStartLocal: requestedStart);
            if (epoch == _epoch) {
              next = before.copyWith(
                  step: GuideStep.editPreview,
                  expectedUpdatedStartLocal: requestedStart,
                  serverRevision: r.serverRevision,
                  mayListenContinuously: false);
            }
          }
        case EditConfirmed(:final confirmedStartLocal):
          if (before.step == GuideStep.editPreview &&
              confirmedStartLocal == before.expectedUpdatedStartLocal) {
            // EditPreviewObserved already moved the server to preview.
            // Save is confirmed locally; the server advances when the app
            // reads back the persisted update.
            next = before.copyWith();
          }
        case UpdateObserved(:final persistedEvent, :final operationId):
          if (before.step == GuideStep.editPreview &&
              persistedEvent.id == before.createdEventId &&
              persistedEvent.userId == before.uid &&
              persistedEvent.startAt == before.expectedUpdatedStartLocal) {
            final r = await _backend.advance(
                snapshot: before,
                action: GuideBackendAction.updateVerified,
                requestId: operationId,
                event: persistedEvent,
                expectedStartLocal: before.expectedUpdatedStartLocal);
            if (epoch == _epoch) {
              next = before.copyWith(
                  step: GuideStep.updatedDetail,
                  serverRevision: r.serverRevision);
            }
          }
        case UpdatedDetailAcknowledged():
          if (before.step == GuideStep.updatedDetail &&
              before.createdEventId?.isNotEmpty == true &&
              before.expectedUpdatedStartLocal != null) {
            next = before.copyWith(step: GuideStep.completionConfirm);
          }
        case GuideCompletionConfirmed():
          if (before.step == GuideStep.completionConfirm &&
              before.createdEventId?.isNotEmpty == true &&
              before.expectedUpdatedStartLocal != null) {
            next = before.copyWith(step: GuideStep.syncChoiceConfirmed);
          }
        case SyncChoiceClosed():
          if (before.step == GuideStep.syncChoiceConfirmed) {
            next = before.copyWith(
                step: GuideStep.completed,
                run: GuideRun.terminal,
                calendarSyncHeld: false);
          }
        case ResumeRequested():
          final refreshingPreview = before.expectedUpdatedStartLocal == null &&
              (before.step == GuideStep.editPreview ||
                  before.step == GuideStep.updatedDetail);
          if (before.run == GuideRun.blocked ||
              before.errorCode == 'backend_unavailable' ||
              before.errorCode == 'guide_operation_failed' ||
              before.errorCode == 'guide_session_changed' ||
              before.errorCode == _pendingCode ||
              before.errorCode == _conflictCode ||
              before.failureDiagnostic != null ||
              (before.run == GuideRun.active && refreshingPreview)) {
            final result = await _begin(
                uid: before.uid,
                requestId:
                    'resume:${before.uid}:${before.version}:${before.revision}');
            if (!_current(before, epoch)) return _state.value;
            switch (result) {
              case GuideBeginGranted(state: final remote):
                // The server may already have verified the update. A missing
                // preview must not restart an earlier tutorial operation.
                if (!refreshingPreview ||
                    remote.step == GuideStep.updatedDetail ||
                    (before.step == GuideStep.editPreview &&
                        remote.step == GuideStep.editPreview)) {
                  next = _reconcile(before, remote);
                } else if (refreshingPreview &&
                    (const {
                          GuideFailureKind.timeout,
                          GuideFailureKind.network,
                          GuideFailureKind.backendUnavailable,
                        }.contains(before.failureDiagnostic?.kind) ||
                        const {
                          'timeout',
                          'network',
                          'backend_unavailable',
                        }.contains(before.errorCode)) &&
                    !_isBindingCheckpoint(before) &&
                    before.errorCode != 'guide_session_changed' &&
                    before.errorCode != 'guide_bound_event_missing') {
                  // A legacy preview without an expected start is normally a
                  // read-only no-op when the server still reports changeSpeech.
                  // If a prior begin failed, however, do not leave that stale
                  // timeout/auth message on the retry screen indefinitely.
                  // Preserve the local binding and revision evidence while
                  // replacing only the failure state.
                  next = before.copyWith(
                      run: GuideRun.blocked,
                      errorCode: 'guide_operation_failed',
                      failureDiagnostic: const GuideFailureDiagnostic(
                          GuideFailureKind.operationFailed),
                      mayListenContinuously: false);
                }
              case final GuideBeginFailed failed:
                next = _afterBeginFailure(before, failed, retry: true);
            }
          } else if (before.run == GuideRun.paused) {
            next = before.copyWith(
                run: GuideRun.active, mayListenContinuously: false);
          }
      }
      if (!_current(before, epoch)) return _state.value;
      if (next != null) {
        next = next.copyWith(revision: before.revision + 1);
        final failure = next.failureDiagnostic;
        if (failure != null && !identical(failure, before.failureDiagnostic)) {
          _logFailure(failure);
        }
        published = next;
        if (signal is GuideCompletionConfirmed) {
          // Sync may open only after the completion confirmation is durable.
          await _progress.save(next);
          if (!_current(before, epoch)) return _state.value;
          _set(next);
        } else {
          _set(next);
          await _progress.save(next);
        }
        if (signal is SyncChoiceClosed && _current(next, epoch)) {
          unawaited(_finishServerSession(next, GuideExit.completed));
        }
      }
      return _state.value;
    } catch (_) {
      final ownPublished = published;
      final failure = GuideFailureDiagnostic(ownPublished != null
          ? GuideFailureKind.progressSaveFailed
          : GuideFailureKind.operationFailed);
      if (_current(before, epoch) ||
          (ownPublished != null && _current(ownPublished, epoch))) {
        final saved = signal is SaveObserved
            ? before.copyWith(
                createdEventId: signal.persistedEvent.id,
                savedCreateOperationId: signal.operationId,
                errorCode: _pendingCode)
            : before;
        final previousFailure = ownPublished?.failureDiagnostic;
        final primaryFailure =
            identical(previousFailure, before.failureDiagnostic)
                ? failure
                : previousFailure ?? failure;
        final failed = _withFailure(saved, primaryFailure)
            .copyWith(revision: before.revision + 1);
        _set(failed);
        _logFailure(failure);
        await _saveFailureCheckpoint(failed);
      }
      return _state.value;
    } finally {
      _inFlight.remove(key);
    }
  }

  @override
  void suspend(GuidePauseReason reason) {
    // A cold start can still be awaiting storage or begin with no live state.
    _epoch++;
    final s = _state.value;
    if (!_live ||
        (s.run == GuideRun.paused &&
            (s.pauseReason == reason ||
                reason == GuidePauseReason.background))) {
      return;
    }
    _set(s.copyWith(
        run: GuideRun.paused,
        pauseReason: reason,
        mayListenContinuously: false,
        revision: s.revision + 1));
    unawaited(_saveFailureCheckpoint(_state.value));
  }

  @override
  Future<void> terminate(GuideExit exit) async {
    final s = _state.value;
    final epoch = ++_epoch;
    final terminal = s.copyWith(
        run: GuideRun.terminal,
        step: exit == GuideExit.completed
            ? GuideStep.completed
            : GuideStep.skipped,
        calendarSyncHeld: false,
        mayListenContinuously: false,
        revision: s.revision + 1);
    _set(terminal);
    await _progress.save(terminal);
    if (_current(terminal, epoch)) await _finishServerSession(s, exit);
  }

  Future<void> _finishServerSession(
      GuideSnapshot snapshot, GuideExit exit) async {
    final sessionId = snapshot.sessionId;
    if (sessionId == null) return;
    try {
      await _backend.finish(
          snapshot: snapshot,
          exit: exit,
          requestId: 'finish:$sessionId:${exit.name}');
    } catch (_) {}
  }

  @override
  Future<GuideAccess> authorize(
      {required GuideChargeContext context,
      required String operationId}) async {
    final s = _state.value;
    if (s.run != GuideRun.active ||
        context.uid != s.uid ||
        context.version != s.version ||
        context.sessionId != s.sessionId ||
        context.revision != s.revision ||
        context.serverRevision != s.serverRevision ||
        context.phase != s.step ||
        context.createdEventId != s.createdEventId) {
      return const GuideAccess(
          status: GuideAccessStatus.denied, reasonCode: 'stale_context');
    }
    if (s.isReplay) {
      return const GuideAccess(
          status: GuideAccessStatus.denied,
          reasonCode: 'ordinary_quota_required');
    }
    final allowed = switch ((context.operation, context.kind)) {
      (GuideOperation.createParse, GuideChargeKind.scheduleParse) =>
        s.step == GuideStep.createSpeech || s.step == GuideStep.correctAndSave,
      (GuideOperation.query, GuideChargeKind.voiceConversation) =>
        s.step == GuideStep.querySpeech || s.step == GuideStep.queryResults,
      (GuideOperation.changeTime, GuideChargeKind.voiceConversation) =>
        s.step == GuideStep.changeSpeech || s.step == GuideStep.editPreview,
      _ => false,
    };
    if (!allowed) {
      return const GuideAccess(
          status: GuideAccessStatus.denied, reasonCode: 'wrong_phase');
    }
    final access =
        await _backend.authorize(context: context, operationId: operationId);
    if (_state.value.uid != context.uid ||
        _state.value.sessionId != context.sessionId ||
        _state.value.revision != context.revision) {
      return const GuideAccess(
          status: GuideAccessStatus.denied,
          reasonCode: 'stale_after_authorize');
    }
    return access;
  }
}
