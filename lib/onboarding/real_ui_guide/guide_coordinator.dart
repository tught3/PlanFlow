import 'package:flutter/foundation.dart';
import 'guide_contract.dart';

class RealUiGuideCoordinator implements GuideCoordinator {
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
  static const String _qaPendingBindingCode = guideQaSavedBindingUnconfirmedCode;
  static const bool _qaAdvanceEnabled = guideQaAdvanceEnabled;
  int _epoch = 0;
  final Set<String> _inFlight = <String>{};
  @override
  ValueListenable<GuideSnapshot> get state => _state;
  bool get _live =>
      _state.value.uid.isNotEmpty && _state.value.run != GuideRun.terminal;
  void _set(GuideSnapshot s) => _state.value = s;
  @override
  Future<GuideSnapshot> start({required String uid}) async {
    final epoch = ++_epoch;
    final initial = _state.value;
    final loaded = await _progress.load(uid: uid, version: version);
    if (epoch != _epoch || !identical(_state.value, initial)) {
      return _state.value;
    }
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
    // Pending checkpoints and known-binding conflicts both fail closed.
    final checkpointPending =
        local?.errorCode == _pendingCode || local?.errorCode == _conflictCode;
    GuideBackendState? remote;
    try {
      remote = await _backend.begin(
          uid: uid, version: version, requestId: 'begin:$uid:$version');
    } catch (_) {
      remote = null;
    }
    if (epoch != _epoch || !identical(_state.value, initial)) {
      return _state.value;
    }
    if (remote == null) {
      final unboundCreate = local != null &&
          local.createdEventId == null &&
          local.sessionId != null &&
          (local.step == GuideStep.createSpeech ||
              local.step == GuideStep.correctAndSave);
      _set(local?.copyWith(
              step: unboundCreate ? GuideStep.homeMic : null,
              run: checkpointPending ? GuideRun.blocked : GuideRun.active,
              errorCode:
                  checkpointPending ? local.errorCode : 'backend_unavailable',
              mayListenContinuously: false) ??
          GuideSnapshot(
              uid: uid,
              version: version,
              revision: 0,
              serverRevision: 0,
              step: GuideStep.intro,
              run: GuideRun.active,
              errorCode: 'backend_unavailable',
              calendarSyncHeld: true));
    } else {
      final base = local ??
          GuideSnapshot(
              uid: uid,
              version: version,
              revision: 0,
              serverRevision: 0,
              step: GuideStep.intro,
              run: GuideRun.active,
              calendarSyncHeld: true);
      final s = _reconcile(base, remote, allowUnboundConflictRecovery: true);
      _set(s);
      await _progress.save(s);
    }
    return _state.value;
  }

  bool _current(GuideSnapshot before, int epoch) =>
      epoch == _epoch && identical(_state.value, before);

  // Shared read-only reconciliation for cold start and explicit retry.
  // A pending checkpoint is not proof of a server binding. Keep its actual
  // event/operation/session fence rather than manufacture or replay a bind.
  GuideSnapshot _reconcile(GuideSnapshot local, GuideBackendState remote,
      {bool allowUnboundConflictRecovery = false}) {
    final localId = local.createdEventId;
    final differentIds = localId != null &&
        remote.createdEventId != null &&
        localId != remote.createdEventId;
    if (differentIds) {
      return local.copyWith(
          run: GuideRun.blocked,
          errorCode: _conflictCode,
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
          run: GuideRun.blocked, mayListenContinuously: false);
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
        remote.step == GuideStep.intro &&
        (local.step == GuideStep.createSpeech ||
            local.step == GuideStep.correctAndSave);
    final retainLocalStep = remote.step == GuideStep.intro &&
        (local.step == GuideStep.homeMic ||
            (localId != null &&
                (local.sessionId == remote.sessionId ||
                    localId == remote.createdEventId)));
    final step = sameSessionUnboundCreate
        ? GuideStep.homeMic
        : retainLocalStep
            ? local.step
            : remote.step;
    final done = step == GuideStep.completed || step == GuideStep.skipped;
    return local.copyWith(
        sessionId: remote.sessionId,
        serverRevision: remote.serverRevision,
        step: step,
        run: done ? GuideRun.terminal : GuideRun.active,
        clearErrorCode: true,
        createdEventId: localId ?? remote.createdEventId,
        savedLocalDate: local.savedLocalDate ?? remote.savedLocalDate,
        dateTimeZone: remote.dateTimeZone ?? local.dateTimeZone,
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
                originalStartLocal: persistedEvent.startAt,
                savedLocalDate: persistedEvent.startAt,
                dateTimeZone: remote.dateTimeZone,
                serverRevision: remote.serverRevision);
          }
        case SaveUnconfirmedObserved(
            :final persistedEvent,
            :final operationId
          ):
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
                originalStartLocal: persistedEvent.startAt,
                savedLocalDate: persistedEvent.startAt,
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
                  serverRevision: bound.serverRevision,
                  clearErrorCode: true);
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
          if (before.step == GuideStep.querySpeech &&
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
          if (before.step == GuideStep.changeSpeech &&
              targetEventId == before.createdEventId &&
              requestedStartLocal != before.originalStartLocal) {
            final r = await _backend.advance(
                snapshot: before,
                action: GuideBackendAction.editPreview,
                requestId: 'preview:${before.sessionId}:${before.revision}',
                expectedStartLocal: requestedStartLocal);
            if (epoch == _epoch) {
              next = before.copyWith(
                  step: GuideStep.editPreview,
                  expectedUpdatedStartLocal: requestedStartLocal,
                  serverRevision: r.serverRevision,
                  mayListenContinuously: false);
            }
          }
        case EditConfirmed(:final confirmedStartLocal, :final operationId):
          if (before.step == GuideStep.editPreview &&
              confirmedStartLocal == before.expectedUpdatedStartLocal) {
            final r = await _backend.advance(
                snapshot: before,
                action: GuideBackendAction.editPreview,
                requestId: operationId,
                expectedStartLocal: confirmedStartLocal);
            if (epoch == _epoch) {
              next = before.copyWith(serverRevision: r.serverRevision);
            }
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
        case SyncChoicePresented():
          if (before.step == GuideStep.updatedDetail) {
            next = before.copyWith(step: GuideStep.syncChoice);
          }
        case SyncChoiceClosed():
          if (before.step == GuideStep.syncChoice) {
            next = before.copyWith(
                step: GuideStep.completed,
                run: GuideRun.terminal,
                calendarSyncHeld: false);
          }
        case ResumeRequested():
          if (before.run == GuideRun.blocked ||
              before.errorCode == 'backend_unavailable' ||
              before.errorCode == _pendingCode ||
              before.errorCode == _conflictCode) {
            GuideBackendState? remote;
            try {
              remote = await _backend.begin(
                  uid: before.uid,
                  version: before.version,
                  requestId:
                      'resume:${before.uid}:${before.version}:${before.revision}');
            } catch (_) {
              remote = null;
            }
            if (!_current(before, epoch)) return _state.value;
            if (remote != null) {
              next = _reconcile(before, remote);
            } else if (before.errorCode != _pendingCode &&
                before.errorCode != _conflictCode &&
                before.createdEventId == null &&
                before.sessionId != null &&
                (before.step == GuideStep.createSpeech ||
                    before.step == GuideStep.correctAndSave)) {
              // Offline normalization to homeMic is only safe for ephemeral
              // local substeps. A persisted pending or conflict checkpoint
              // is a fail-closed record; keep its run/errorCode until the
              // server binding is reconciled instead of substituting
              // backend_unavailable, which would silently drop the
              // evidence that kept the guide from advancing.
              next = before.copyWith(
                  step: GuideStep.homeMic,
                  run: GuideRun.active,
                  errorCode: 'backend_unavailable',
                  mayListenContinuously: false);
            }
          } else if (before.run == GuideRun.paused) {
            next = before.copyWith(
                run: GuideRun.active, mayListenContinuously: false);
          }
      }
      if (!_current(before, epoch)) return _state.value;
      if (next != null) {
        next = next.copyWith(revision: before.revision + 1);
        published = next;
        _set(next);
        await _progress.save(next);
      }
      return _state.value;
    } catch (e) {
      final ownPublished = published;
      if (epoch == _epoch &&
          (identical(_state.value, before) ||
              (ownPublished != null &&
                  identical(_state.value, ownPublished)))) {
        final failed = signal is SaveObserved
            ? before.copyWith(
                createdEventId: signal.persistedEvent.id,
                savedCreateOperationId: signal.operationId,
                run: GuideRun.blocked,
                errorCode: _pendingCode,
                revision: before.revision + 1)
            : before.copyWith(
                run: GuideRun.blocked,
                // 아직 서버 바인딩이 확인되지 않은 QA 상태는 그대로 유지한다.
                // 그래야 다음 DetailObserved 가 같은 저장 ID/연산으로 재연결을
                // 다시 시도할 수 있다. 확인 없이 단계만 넘기지 않는다.
                errorCode: before.errorCode == _qaPendingBindingCode
                    ? _qaPendingBindingCode
                    : 'guide_operation_failed',
                revision: before.revision + 1);
        _set(failed);
        await _progress.save(_state.value);
      }
      return _state.value;
    } finally {
      _inFlight.remove(key);
    }
  }

  @override
  void suspend(GuidePauseReason reason) {
    final s = _state.value;
    if (!_live) {
      return;
    }
    _epoch++;
    _set(s.copyWith(
        run: GuideRun.paused,
        mayListenContinuously: false,
        revision: s.revision + 1));
    _progress.save(_state.value);
  }

  @override
  Future<void> terminate(GuideExit exit) async {
    final s = _state.value;
    _epoch++;
    _set(s.copyWith(
        run: GuideRun.terminal,
        step: exit == GuideExit.completed
            ? GuideStep.completed
            : GuideStep.skipped,
        calendarSyncHeld: false,
        mayListenContinuously: false,
        revision: s.revision + 1));
    await _progress.save(_state.value);
    if (s.sessionId != null) {
      try {
        await _backend.finish(
            snapshot: s,
            exit: exit,
            requestId: 'finish:${s.sessionId}:${exit.name}');
      } catch (_) {}
    }
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
