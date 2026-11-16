import 'package:flutter/foundation.dart';
import '../../data/models/event_model.dart';

enum GuideStep {
  intro,
  homeMic,
  createSpeech,
  correctAndSave,
  savedDetail,
  queryMic,
  querySpeech,
  queryResults,
  changeSpeech,
  editPreview,
  updatedDetail,
  syncChoice,
  completed,
  skipped
}

enum GuideRun { active, paused, blocked, terminal }

enum GuidePauseReason { background, routeLost, userStop, interrupted }

enum GuideExit { skip, cancel, authChanged, completed }

enum GuideChargeKind { scheduleParse, voiceConversation }

enum GuideOperation { createParse, query, changeTime }

enum GuideAccessStatus { granted, unavailable, expired, denied, retryLater }

enum GuideWriteKind { createPersonal, changeTime }

enum GuideBackendAction {
  bindCreated,
  detailAck,
  queryReady,
  editPreview,
  updateVerified
}

/// SaveObserved 의 서버 바인딩이 실패했을 때 남는 체크포인트 코드.
/// 이 상태는 "일정은 저장됐지만 서버 바인딩 확인이 아직 없다"는 사실만
/// 담고 있으며, 재시도 근거로만 쓰인다.
const String guideCreatedCheckpointPendingCode =
    'created_checkpoint_pending';

/// QA 격리 빌드 전용: 실제 저장 응답은 확인됐지만 서버 바인딩 확인은
/// 아직 없는 상태. 서버 영수증을 만들지 않으며, 이후 DetailObserved 에서
/// 같은 저장 ID/연산으로 idempotent 재연결을 시도할 때만 해소된다.
const String guideQaSavedBindingUnconfirmedCode =
    'qa_saved_binding_unconfirmed';

/// 서버 바인딩 확인 없이 "실제로 저장된 일정"으로만 안내를 이어갈 수 있는
/// 격리 QA 빌드에서만 참. 본앱 빌드에서는 항상 거짓이다.
const bool guideQaAdvanceEnabled = kDebugMode &&
    bool.fromEnvironment('PLANFLOW_GUIDE_QA') &&
    bool.fromEnvironment('PLANFLOW_ISOLATED_GUIDE_QA');

@immutable
class GuideSnapshot {
  const GuideSnapshot(
      {required this.uid,
      required this.version,
      required this.revision,
      required this.serverRevision,
      required this.step,
      required this.run,
      this.sessionId,
      this.createdEventId,
      this.savedCreateOperationId,
      this.dateTimeZone,
      this.errorCode,
      this.failureDiagnostic,
      this.savedLocalDate,
      this.originalStartLocal,
      this.expectedUpdatedStartLocal,
      this.pauseReason,
      this.isReplay = false,
      this.calendarSyncHeld = false,
      this.mayListenContinuously = false,
      this.speechCaptured = false});
  final String uid, version;
  final String? sessionId,
      createdEventId,
      savedCreateOperationId,
      dateTimeZone,
      errorCode;
  final GuideFailureDiagnostic? failureDiagnostic;
  final int revision, serverRevision;
  final GuideStep step;
  final GuideRun run;
  final GuidePauseReason? pauseReason;
  final DateTime? savedLocalDate, originalStartLocal, expectedUpdatedStartLocal;
  final bool isReplay, calendarSyncHeld, mayListenContinuously, speechCaptured;
  bool get isInProgress => run != GuideRun.terminal;
  GuideSnapshot copyWith(
          {String? uid,
          String? version,
          String? sessionId,
          bool clearSessionId = false,
          String? createdEventId,
          bool clearCreatedEventId = false,
          String? savedCreateOperationId,
          String? dateTimeZone,
          int? revision,
          int? serverRevision,
          GuideStep? step,
          GuideRun? run,
          GuidePauseReason? pauseReason,
          String? errorCode,
          bool clearErrorCode = false,
          GuideFailureDiagnostic? failureDiagnostic,
          bool clearFailureDiagnostic = false,
          DateTime? savedLocalDate,
          bool clearSavedLocalDate = false,
          DateTime? originalStartLocal,
          bool clearOriginalStartLocal = false,
          DateTime? expectedUpdatedStartLocal,
          bool clearExpectedUpdatedStartLocal = false,
          bool? isReplay,
          bool? calendarSyncHeld,
          bool? mayListenContinuously,
          bool? speechCaptured}) =>
      GuideSnapshot(
          uid: uid ?? this.uid,
          version: version ?? this.version,
          sessionId: clearSessionId ? null : sessionId ?? this.sessionId,
          createdEventId: clearCreatedEventId
              ? null
              : createdEventId ?? this.createdEventId,
          savedCreateOperationId:
              savedCreateOperationId ?? this.savedCreateOperationId,
          dateTimeZone: dateTimeZone ?? this.dateTimeZone,
          revision: revision ?? this.revision,
          serverRevision: serverRevision ?? this.serverRevision,
          step: step ?? this.step,
          run: run ?? this.run,
          pauseReason: (run ?? this.run) == GuideRun.paused
              ? pauseReason ?? this.pauseReason
              : null,
          errorCode: clearErrorCode ? null : errorCode ?? this.errorCode,
          failureDiagnostic: failureDiagnostic ??
              (clearErrorCode || clearFailureDiagnostic
                  ? null
                  : this.failureDiagnostic),
          savedLocalDate: clearSavedLocalDate
              ? null
              : savedLocalDate ?? this.savedLocalDate,
          originalStartLocal: clearOriginalStartLocal
              ? null
              : originalStartLocal ?? this.originalStartLocal,
          expectedUpdatedStartLocal: clearExpectedUpdatedStartLocal
              ? null
              : expectedUpdatedStartLocal ?? this.expectedUpdatedStartLocal,
          isReplay: isReplay ?? this.isReplay,
          calendarSyncHeld: calendarSyncHeld ?? this.calendarSyncHeld,
          mayListenContinuously:
              mayListenContinuously ?? this.mayListenContinuously,
          speechCaptured: speechCaptured ?? this.speechCaptured);
}

@immutable
class GuideChargeContext {
  const GuideChargeContext(
      {required this.uid,
      required this.version,
      required this.sessionId,
      required this.kind,
      required this.operation,
      required this.phase,
      required this.revision,
      required this.serverRevision,
      this.createdEventId});
  final String uid, version, sessionId;
  final GuideChargeKind kind;
  final GuideOperation operation;
  final GuideStep phase;
  final int revision, serverRevision;
  final String? createdEventId;
}

@immutable
class GuidePermit {
  const GuidePermit(
      {required this.grantId,
      required this.uid,
      required this.sessionId,
      required this.operationId,
      required this.kind,
      required this.operation,
      required this.expiresAtUtc});
  final String grantId, uid, sessionId, operationId;
  final GuideChargeKind kind;
  final GuideOperation operation;
  final DateTime expiresAtUtc;
}

@immutable
class GuideAccess {
  const GuideAccess({required this.status, this.permit, this.reasonCode});
  final GuideAccessStatus status;
  final GuidePermit? permit;
  final String? reasonCode;
}

@immutable
class GuideMutationIntent {
  const GuideMutationIntent(
      {required this.kind,
      required this.operationId,
      this.eventId,
      required this.isPersonal,
      required this.isRecurrence,
      required this.changedFields,
      this.requestedStartLocal,
      required this.userConfirmed});
  final GuideWriteKind kind;
  final String operationId;
  final String? eventId;
  final bool isPersonal, isRecurrence, userConfirmed;
  final Set<String> changedFields;
  final DateTime? requestedStartLocal;
}

@immutable
class GuideWriteDecision {
  const GuideWriteDecision({required this.allowed, this.reasonCode});
  final bool allowed;
  final String? reasonCode;
}

@immutable
class GuideVisibleBinding {
  GuideVisibleBinding(
      {required List<EventModel> ordered,
      required this.targetEventId,
      required this.firstIsTarget,
      required this.guideRevision,
      required this.missingTarget,
      required this.duplicateTarget,
      required this.identityIssue})
      : ordered = List<EventModel>.unmodifiable(ordered);
  final List<EventModel> ordered;
  final String? targetEventId;
  final bool firstIsTarget;
  final int guideRevision;
  final bool missingTarget, duplicateTarget, identityIssue;
}

@immutable
class GuideBackendState {
  const GuideBackendState(
      {required this.sessionId,
      required this.serverRevision,
      required this.step,
      this.createdEventId,
      this.savedLocalDate,
      this.dateTimeZone,
      this.expectedStartAt,
      this.isReplay = false,
      this.expectedStartAtReported = false});
  final String sessionId;
  final int serverRevision;
  final GuideStep step;
  final String? createdEventId;
  final DateTime? savedLocalDate;
  final String? dateTimeZone;
  final DateTime? expectedStartAt;
  final bool isReplay;

  /// Distinguishes older begin responses from a response that explicitly
  /// reports an unavailable or invalid timestamp.
  final bool expectedStartAtReported;
}

enum GuideFailureKind {
  localUidMismatch('local_uid_mismatch'),
  authError('auth_error'),
  timeout('timeout'),
  network('network'),
  terminal('terminal'),
  expired('expired'),
  denied('denied'),
  malformed('malformed'),
  wireExpired('wire_expired'),
  backendUnavailable('backend_unavailable'),
  sessionChanged('guide_session_changed'),
  boundEventMissing('guide_bound_event_missing'),
  progressLoadFailed('guide_progress_load_failed'),
  progressSaveFailed('guide_progress_save_failed'),
  operationFailed('guide_operation_failed');

  const GuideFailureKind(this.code);
  final String code;
}

/// Diagnostic for the latest failed guide operation. errorCode is separate
/// because it can carry a binding checkpoint needed for recovery.
@immutable
class GuideFailureDiagnostic {
  const GuideFailureDiagnostic(this.kind)
      : reasonCode = null,
        phase = null,
        statusCode = null;

  const GuideFailureDiagnostic._(
      this.kind, this.reasonCode, this.phase, this.statusCode);

  factory GuideFailureDiagnostic.fromWire(GuideFailureKind kind,
      {Object? reasonCode, Object? phase, int? statusCode}) {
    // Store only defined wire labels. Pattern checks alone could allow a
    // future backend to place an identifier or credential in a reason field.
    const reasons = {
      'invalid_request',
      'request_replay_mismatch',
      'session_expired',
      'session_terminal',
    };
    const phases = {
      'intro',
      'create',
      'saved',
      'query',
      'edit',
      'preview',
      'updated',
      'syncChoice',
      'terminal',
    };
    return GuideFailureDiagnostic._(
        kind,
        reasons.contains(reasonCode) ? reasonCode as String : null,
        phases.contains(phase) ? phase as String : null,
        statusCode != null && statusCode >= 400 && statusCode <= 599
            ? statusCode
            : null);
  }

  final GuideFailureKind kind;
  final String? reasonCode, phase;
  final int? statusCode;

  String get code => kind == GuideFailureKind.denied && reasonCode != null
      ? 'denied:$reasonCode'
      : kind.code;

  Map<String, Object> toJson() => {
        'kind': kind.name,
        if (reasonCode != null) 'reasonCode': reasonCode!,
        if (phase != null) 'phase': phase!,
        if (statusCode != null) 'statusCode': statusCode!,
      };

  static GuideFailureDiagnostic? fromJson(Object? raw) {
    if (raw is! Map<String, dynamic>) return null;
    for (final kind in GuideFailureKind.values) {
      if (raw['kind'] == kind.name) {
        final status = raw['statusCode'];
        return GuideFailureDiagnostic.fromWire(kind,
            reasonCode: raw['reasonCode'],
            phase: raw['phase'],
            statusCode: status is int ? status : null);
      }
    }
    return null;
  }
}

sealed class GuideBeginResult {
  const GuideBeginResult();
}

final class GuideBeginGranted extends GuideBeginResult {
  const GuideBeginGranted(this.state);
  final GuideBackendState state;
}

final class GuideBeginFailed extends GuideBeginResult {
  const GuideBeginFailed(this.failure, {this.terminalPredecessor});
  final GuideFailureDiagnostic failure;

  /// Present only for a validated, terminal response. This is a checkpoint
  /// for Settings replay and never authorizes a guide operation.
  final GuideBackendState? terminalPredecessor;
}

abstract interface class GuideQuotaBoundary {
  Future<GuideAccess> authorize(
      {required GuideChargeContext context, required String operationId});
}

abstract interface class GuideBackendPort {
  Future<GuideBeginResult> begin(
      {required String uid,
      required String version,
      required String requestId});
  Future<GuideBackendState> advance(
      {required GuideSnapshot snapshot,
      required GuideBackendAction action,
      required String requestId,
      EventModel? event,
      DateTime? expectedStartLocal});
  Future<GuideAccess> authorize(
      {required GuideChargeContext context, required String operationId});
  Future<void> finish(
      {required GuideSnapshot snapshot,
      required GuideExit exit,
      required String requestId});
}

abstract interface class GuideProgressStore {
  Future<GuideSnapshot?> load({required String uid, required String version});
  Future<void> save(GuideSnapshot snapshot);
}

abstract interface class GuideReplayBackendPort {
  Future<GuideBackendState?> restart(
      {required String uid,
      required String version,
      required String previousSessionId,
      required String requestId});
}

abstract interface class GuideReplayCoordinator {
  Future<bool> restartCompletedGuide({required String uid});
}

abstract interface class GuideCoordinator implements GuideQuotaBoundary {
  ValueListenable<GuideSnapshot> get state;
  Future<GuideSnapshot> start({required String uid});
  Future<GuideSnapshot> dispatch(GuideSignal signal);
  void suspend(GuidePauseReason reason);
  Future<void> terminate(GuideExit exit);
}

sealed class GuideSignal {
  const GuideSignal(
      {required this.uid, required this.expectedRevision, this.sessionId});
  final String uid;
  final int expectedRevision;
  final String? sessionId;
}

class IntroFinished extends GuideSignal {
  const IntroFinished({required super.uid, required super.expectedRevision});
}

class HomeMicTapped extends GuideSignal {
  const HomeMicTapped(
      {required super.uid,
      required super.sessionId,
      required super.expectedRevision});
}

class CaptureStarted extends GuideSignal {
  const CaptureStarted(
      {required super.uid,
      required super.sessionId,
      required super.expectedRevision});
}

class SpeechObserved extends GuideSignal {
  const SpeechObserved(
      {required super.uid,
      required super.sessionId,
      required super.expectedRevision,
      required this.present});
  final bool present;
}

class ParseConfirmed extends GuideSignal {
  const ParseConfirmed(
      {required super.uid,
      required super.sessionId,
      required super.expectedRevision,
      required this.operationId});
  final String operationId;
}

class CorrectionObserved extends GuideSignal {
  const CorrectionObserved(
      {required super.uid,
      required super.sessionId,
      required super.expectedRevision});
}

class SaveObserved extends GuideSignal {
  const SaveObserved(
      {required super.uid,
      required super.sessionId,
      required super.expectedRevision,
      required this.persistedEvent,
      required this.operationId});
  final EventModel persistedEvent;
  final String operationId;
}

/// QA 전용: 일정은 실제로 저장됐지만 서버의 저장 확인(bindCreated) 응답을
/// 받지 못했을 때, 안내 단계만 다음(저장된 일정 확인)으로 넘긴다.
/// 본앱에서는 발행되지 않는다(호출부가 격리된 QA 플래그로 제한).
class SaveUnconfirmedObserved extends GuideSignal {
  const SaveUnconfirmedObserved(
      {required super.uid,
      required super.sessionId,
      required super.expectedRevision,
      required this.persistedEvent,
      required this.operationId});
  final EventModel persistedEvent;
  final String operationId;
}

class DetailObserved extends GuideSignal {
  const DetailObserved(
      {required super.uid,
      required super.sessionId,
      required super.expectedRevision,
      required this.persistedEvent,
      required this.preparationResolved,
      required this.departureResolved,
      required this.setupHelpAcknowledged});
  final EventModel persistedEvent;
  final bool preparationResolved, departureResolved, setupHelpAcknowledged;
}

class QueryMicTapped extends GuideSignal {
  const QueryMicTapped(
      {required super.uid,
      required super.sessionId,
      required super.expectedRevision});
}

class QueryObserved extends GuideSignal {
  const QueryObserved(
      {required super.uid,
      required super.sessionId,
      required super.expectedRevision,
      required this.binding,
      required this.operationId});
  final GuideVisibleBinding binding;
  final String operationId;
}

class EditPreviewObserved extends GuideSignal {
  const EditPreviewObserved(
      {required super.uid,
      required super.sessionId,
      required super.expectedRevision,
      required this.targetEventId,
      required this.requestedStartLocal});
  final String targetEventId;
  final DateTime requestedStartLocal;
}

class EditConfirmed extends GuideSignal {
  const EditConfirmed(
      {required super.uid,
      required super.sessionId,
      required super.expectedRevision,
      required this.operationId,
      required this.confirmedStartLocal});
  final String operationId;
  final DateTime confirmedStartLocal;
}

class UpdateObserved extends GuideSignal {
  const UpdateObserved(
      {required super.uid,
      required super.sessionId,
      required super.expectedRevision,
      required this.persistedEvent,
      required this.operationId});
  final EventModel persistedEvent;
  final String operationId;
}

class SyncChoicePresented extends GuideSignal {
  const SyncChoicePresented(
      {required super.uid,
      required super.sessionId,
      required super.expectedRevision});
}

class SyncChoiceClosed extends GuideSignal {
  const SyncChoiceClosed(
      {required super.uid,
      required super.sessionId,
      required super.expectedRevision});
}

class ResumeRequested extends GuideSignal {
  const ResumeRequested(
      {required super.uid,
      required super.sessionId,
      required super.expectedRevision});
}

/// Bounds a begin request so the guide can release an interrupted retry.
const Duration guideBeginTimeout = Duration(seconds: 15);
