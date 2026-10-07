import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/analytics_service.dart';
import '../../core/constants.dart';
import '../../core/env.dart';
import '../../core/event_edit_route_payload.dart';
import '../../core/local_time.dart';
import '../../core/theme.dart';
import '../../data/models/event_model.dart';
import '../../data/repositories/event_repository.dart';
import '../../data/repositories/settings_repository.dart';
import '../../features/groups/models/group_event_model.dart';
import '../../features/groups/repositories/group_event_repository.dart';
import '../../features/groups/repositories/group_repository.dart';
import '../../features/groups/services/group_event_share_service.dart';
import '../../providers/auth_provider.dart';
import '../../services/app_permission_service.dart';
import '../../services/event_refresh_bus.dart';
import '../../services/gpt_service.dart';
import '../../services/location_lookup_service.dart';
import '../../services/manual_event_side_effect_service.dart';
import '../../services/stt_service.dart';
import '../../services/voice_conversation_ad_gate.dart';
import '../../services/voice_conversation_controller.dart';
import '../../services/voice_conversation_entitlement.dart';
import '../../widgets/overlap_warning_dialog.dart';
import '../../widgets/planflow_action_buttons.dart';
import '../location/location_pick_flow.dart';

const String voiceConversationClosedResult = 'voiceConversationClosed';

enum _VoiceConversationPhase {
  idle,
  listening,
  finalizing,
  submitting,
  stopping,
  exiting,
  restartPending,
}

class VoiceConversationScreen extends StatefulWidget {
  const VoiceConversationScreen({
    super.key,
    this.repository,
    this.groupRepository,
    this.groupEventRepository,
    this.sttService = const SttService(),
    this.locationLookupService,
    this.permissionService,
    this.settingsRepository,
    this.reminderNotifyAtReader,
    this.locationPicker = pickLocationFromQuery,
    this.autoStart = false,
    this.initialText,
    this.entryGrant,
    this.sideEffectService,
  });

  final EventRepository? repository;
  final GroupRepository? groupRepository;
  final GroupEventRepository? groupEventRepository;
  final SttService sttService;
  final LocationLookupService? locationLookupService;
  final AppPermissionService? permissionService;
  final SettingsRepository? settingsRepository;

  /// 저장 직전 기존 push 리마인더의 notify_at을 읽어 오는 함수(선택 주입).
  /// 기본 구현은 Supabase reminders 테이블을 조회한다(편집 화면
  /// _loadReminderOffsetIfNeeded와 동일한 쿼리). 날짜 자동 저장 시 이 값에서
  /// 역산한 '개별' 오프셋을 그대로 유지한다. 테스트에서 주입해 검증한다.
  /// null 반환 = 리마인더 행 없음, 예외 = 조회 실패(fail-closed).
  final Future<DateTime?> Function(String userId, String eventId)?
      reminderNotifyAtReader;
  final ManualEventSideEffectService? sideEffectService;
  final Future<LocationLookupResult?> Function({
    required BuildContext context,
    required String query,
    LocationLookupService? locationLookupService,
    AppPermissionService? appPermissionService,
    String? preferredMapProvider,
    bool? canUseInAppMapOverride,
  }) locationPicker;
  final bool autoStart;
  final String? initialText;

  /// 진입 게이트(광고/무료횟수 결정)를 이미 통과한 시점의 승인 스냅샷.
  ///
  /// 정상 진입 경로(홈 버튼 등)는 [VoiceConversationLauncher]가
  /// [VoiceConversationAdGate]를 먼저 통과시킨 뒤 이 값을 넘겨준다. 딥링크 등
  /// 게이트를 거치지 않고 이 화면이 직접 열린 경우에는 null이며, 이 경우 화면이
  /// 스스로 게이트를 호출한다(initState의 self-gate 참조).
  final VoiceConversationEntryGrant? entryGrant;

  @override
  State<VoiceConversationScreen> createState() =>
      VoiceConversationScreenState();
}

class VoiceConversationScreenState extends State<VoiceConversationScreen>
    with WidgetsBindingObserver {
  final TextEditingController _inputController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final List<_ConversationMessage> _messages = <_ConversationMessage>[
    const _ConversationMessage.assistant(
      '일정을 이어서 말해도 돼요. 예: “5월 7일 일정 보여줘” 다음에 “3번째 일정에 장소 추가해줘”, “오후 6시 일정 삭제해줘”처럼요.',
    ),
  ];

  late final EventRepository _repository =
      widget.repository ?? EventRepository.supabase();
  late final GroupRepository _groupRepository =
      widget.groupRepository ?? GroupRepository.supabase();
  late final GroupEventRepository _groupEventRepository =
      widget.groupEventRepository ?? GroupEventRepository.supabase();
  late final VoiceConversationController _conversation =
      VoiceConversationController(events: const <EventModel>[]);
  // 개인 일정 일간 motion에서 알림/외부 캘린더/위젯 재동기화를 위해 사용하는
  // 사이드 이펙트 서비스. 테스트에서는 [sideEffectService] 주입으로 가짜
  // 구현을 넣어 호출 횟수와 인자를 검증한다. 이벤트 편집 화면과 동일한
  // 기본 구현([ManualEventSideEffectService])을 쓴다.
  late final ManualEventSideEffectService _sideEffectService =
      widget.sideEffectService ?? const ManualEventSideEffectService();

  List<EventModel> _events = const <EventModel>[];
  // 그룹 일정을 개인 EventModel로 변환해 음성 후보 목록에 병합할 때, id로
  // 원본 GroupEventModel을 역참조하기 위한 레지스트리. 수정 라우팅 분기에서
  // "이 id가 그룹 일정인가"를 판정하는 데 쓴다.
  Map<String, GroupEventModel> _groupEventById = <String, GroupEventModel>{};
  final Set<String> _deletedEventIds = <String>{};
  bool _isLoading = true;
  bool _isSubmitting = false;
  bool _isListening = false;
  bool _keepListening = false;
  bool _voicePausedByUser = false;
  bool _isRestartPending = false;
  bool _manualEditInterruptedListening = false;
  bool _didSubmitInitialText = false;
  bool _isExitingConversation = false;
  bool _didRetryConversationEarlyFailure = false;
  // _stopVoiceBeforeNavigation() 호출 직전에 듣고 있었는지(또는 듣기 대기
  // 상태였는지) 캡처해, 다녀온 화면에서 복귀했을 때 마이크를 자동으로 다시
  // 켜야 하는지 판정하는 데 쓴다.
  bool _wasListeningBeforeNavigation = false;
  int _listenGeneration = 0;
  int _inputTurnGeneration = 0;
  bool _isApplyingVoiceTranscript = false;
  bool _isApplyingInputReset = false;
  bool _nativeVoiceReady = false;
  bool _didRetrySilentNativeStart = false;
  // 이번 듣기 턴에서 한 번이라도 native ready에 도달했는지. 조용한 재연결 중에는
  // 이미 도달했던 상태를 유지해 상태 문구가 계속 바뀌며 깜빡이지 않게 한다.
  bool _hasVoiceBeenReadyThisTurn = false;
  // 재시도 후에도 계속 응답이 없는 '진짜' 연결 문제일 때만 true.
  bool _voiceUnstable = false;
  // ignore: unused_field
  _VoiceConversationPhase _voicePhase = _VoiceConversationPhase.idle;
  Timer? _restartListenTimer;
  Timer? _conversationWatchdogTimer;
  String? _suppressedVoiceEcho;
  DateTime? _suppressedVoiceEchoUntil;

  // ── 엔타이틀먼트 소비/세션 게이트 ─────────────────────────────────
  // 이 화면 인스턴스(세션) 안에서 실제 사용자 명령이 한 번이라도 처리되기
  // 시작했는지. 세션당 정확히 1회만 소비하기 위한 로컬 가드.
  bool _usageConsumedForSession = false;
  // widget.entryGrant가 null(딥링크 등 게이트 미경유 진입)일 때, 화면이
  // 스스로 게이트를 호출해 얻은 승인 스냅샷.
  VoiceConversationEntryGrant? _resolvedEntryGrant;
  // self-gate(필요한 경우) 판정이 끝났음을 알리는 신호. widget.entryGrant가
  // 이미 있으면 initState에서 즉시 완료된다. 초기 자동 제출/자동 리스닝
  // 시작은 이 신호가 완료된 뒤에만 진행한다.
  final Completer<void> _entryGrantReadyCompleter = Completer<void>();
  // self-gate가 '진짜 거부'로 끝났는지(광고 실패 등 정책상 거부, 화면이
  // 닫히는 중). null인 grant라도 (a) userId 미확인 (b) self-gate 시작 시점에
  // 이미 unmounted 였던 fail-open 경로는 이 플래그를 세우지 않는다 —
  // 그 경로들은 소비만 건너뛸 뿐 명령 처리 자체는 허용해야 하기 때문이다.
  // Completer.complete()는 대기 중이던 코드를 동기적으로 깨우지 않고
  // microtask로 재개하므로, _submitText/_startConversationListen가 completer
  // await에서 재개될 때 mounted는 아직 true일 수 있다(context.go()로 인한
  // dispose는 다음 프레임에야 일어남) — 그래서 mounted 체크만으로는 거부를
  // 감지할 수 없고, 이 플래그로 명시적으로 판정한다.
  bool _entryGateDenied = false;

  /// 현재 유효한 진입 승인. widget.entryGrant(정상 경로)가 우선이고, 없으면
  /// self-gate로 얻은 값을 쓴다.
  VoiceConversationEntryGrant? get _effectiveEntryGrant =>
      widget.entryGrant ?? _resolvedEntryGrant;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final providedGrant = widget.entryGrant;
    if (providedGrant != null) {
      _resolvedEntryGrant = providedGrant;
      _entryGrantReadyCompleter.complete();
    } else {
      // 딥링크 등 게이트를 거치지 않고 이 화면이 직접 열린 경우의 방어:
      // 화면이 스스로 게이트를 호출해 진입 승인을 얻는다. 첫 프레임이 그려진
      // 뒤(BuildContext 사용 가능 시점)에 실행한다.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        unawaited(_resolveEntryGrantViaSelfGate());
      });
    }
    unawaited(_loadEvents().then((_) => _submitInitialTextIfNeeded()));
    if (widget.autoStart && (widget.initialText ?? '').trim().isEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        unawaited(_autoStartListeningAfterEntryGrantReady());
      });
    }
  }

  /// self-gate가 완료될 때까지 자동 마이크 시작을 보류한 뒤 진행한다.
  /// widget.entryGrant가 이미 있는 정상 경로에서는 완료된 Future를 즉시
  /// 통과하므로 기존 동작과 체감상 동일하다.
  Future<void> _autoStartListeningAfterEntryGrantReady() async {
    await _entryGrantReadyCompleter.future;
    if (!mounted || _isListening) {
      return;
    }
    setState(() => _keepListening = true);
    unawaited(_startConversationListen(resetRetryPolicy: true));
  }

  /// widget.entryGrant 없이 이 화면이 직접 열린 경우, 화면 스스로
  /// [VoiceConversationAdGate]를 호출해 진입 승인을 얻는다.
  ///
  /// - 로그인 사용자 정보를 확인할 수 없으면(비로그인/세션 미확인) 게이트
  ///   시도 자체를 생략하고 fail-open으로 진행한다(엔타이틀먼트 소비는
  ///   되지 않지만 사용자의 명령 처리 자체를 막지 않는다 — 이 화면은 이미
  ///   비로그인 상태를 [_loadEvents]에서 별도로 안내한다).
  /// - 게이트가 실제로 진입을 거부한 경우(광고 실패 등 정책상 거부)에는
  ///   화면을 닫고 안내 스낵바를 보여준다.
  Future<void> _resolveEntryGrantViaSelfGate() async {
    if (!mounted) {
      _completeEntryGrantReadyIfNeeded();
      return;
    }
    final userId = authProvider.userId;
    if (userId == null || userId.isEmpty) {
      _completeEntryGrantReadyIfNeeded();
      return;
    }
    await VoiceConversationAdGate.instance.tryEnterVoiceConversation(
      context: context,
      userId: userId,
      onDenied: (reason) {
        if (mounted) {
          _closeAfterEntryGateDenied(
            voiceConversationGateDenialMessage(reason),
          );
        }
      },
      onEnterAllowed: (grant) {
        _resolvedEntryGrant = grant;
      },
    );
    _completeEntryGrantReadyIfNeeded();
    if (_resolvedEntryGrant == null && !_entryGateDenied) {
      final lastReason =
          // ignore: invalid_use_of_visible_for_testing_member
          VoiceConversationAdGate.instance.lastDenialReason;
      final fallbackMessage = lastReason != null
          ? voiceConversationGateDenialMessage(lastReason)
          : 'AI일정대화 진입 상태를 확인하지 못했어요. 잠시 후 다시 시도해 주세요. (E-GATE1)';
      _closeAfterEntryGateDenied(fallbackMessage);
    }
  }

  void _completeEntryGrantReadyIfNeeded() {
    if (!_entryGrantReadyCompleter.isCompleted) {
      _entryGrantReadyCompleter.complete();
    }
  }

  void _closeAfterEntryGateDenied(String message) {
    // 플래그는 mounted 여부와 무관하게 세운다. completer await에서 재개되는
    // _submitText/_startConversationListen이 이 시점 이후 실행될 수 있고,
    // 그때는 이미 이 화면이 dispose됐거나(mounted=false, 자체 가드로 걸러짐)
    // 아직 dispose 전(mounted=true, 이 플래그로 걸러짐)일 수 있기 때문이다.
    _entryGateDenied = true;
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
    context.go(AppRoutes.home);
  }

  /// [sessionId]에 대해 실제 엔타이틀먼트를 소비하고, 소비 출처에 맞는
  /// 분석 이벤트를 남긴다. 소비 자체가 실패해도(fail-open) 세션 시작
  /// 이벤트는 항상 남긴다.
  Future<void> _consumeEntitlement(VoiceConversationEntryGrant grant) async {
    // adFailedFreePass는 광고도 무료횟수도 소진된 상태에서의 예외 통과다
    // (VoiceConversationAdGate.maybeFreePassGrant 참조). 이 경로는 정상적인
    // 무료소진이 아니므로 consume()을 호출하지 않는다.
    if (grant.source != EntitlementSource.adFailedFreePass) {
      final result = await VoiceConversationEntitlementService.instance
          .consume(grant.sessionId);
      if (result != null) {
        if (result.source == 'initial_free') {
          await AnalyticsService.logVoiceConvInitialFreeUsed(
            remainingAfter: result.initialRemaining,
          );
        }
        // 'ad_required' 등 그 외 값은 별도 소비 이벤트가 없다.
      }
    }
    await AnalyticsService.logVoiceConvSessionStarted(
      source: _mapEntitlementSourceToSessionSource(grant.source),
    );
  }

  /// [EntitlementSource]를 분석 이벤트 파라미터로 쓸 수 있는 제한된
  /// [VoiceConvSessionSource]로 매핑한다. 무료 횟수를 소비하지 않은 진입
  /// 근거(광고 시청/광고 실패 무료패스/원격 비활성/광고 불가 무료패스)는
  /// 모두 가장 가까운 값인 adRewarded로 묶는다.
  VoiceConvSessionSource _mapEntitlementSourceToSessionSource(
    EntitlementSource source,
  ) {
    switch (source) {
      case EntitlementSource.initialFree:
        return VoiceConvSessionSource.initialFree;
      case EntitlementSource.dailyFree:
        // 이전 앱/서버 응답 호환용 값이다. 새 RPC는 일일 무료를 반환하거나
        // 소비하지 않으므로 일일 무료 분석 이벤트로 분기하지 않는다.
        return VoiceConvSessionSource.initialFree;
      case EntitlementSource.adRewarded:
      case EntitlementSource.adFailedFreePass:
      case EntitlementSource.remoteDisabled:
      case EntitlementSource.adsUnavailableFreePass:
        return VoiceConvSessionSource.adRewarded;
    }
  }

  Future<void> _submitInitialTextIfNeeded() async {
    if (!mounted || _didSubmitInitialText) {
      return;
    }
    final text = widget.initialText?.trim();
    if (text == null || text.isEmpty) {
      return;
    }
    // self-gate가 진행 중이면(딥링크 진입 등) 판정이 끝날 때까지 초기 자동
    // 제출을 보류한다. widget.entryGrant가 이미 있는 정상 경로에서는 이미
    // 완료된 Future라 사실상 대기가 없다.
    await _entryGrantReadyCompleter.future;
    if (!mounted || _didSubmitInitialText) {
      return;
    }
    debugPrint('VoiceConversationScreen initialText submit: $text');
    _didSubmitInitialText = true;
    await _submitText(text);
    if (!mounted || !widget.autoStart) {
      return;
    }
    setState(() {
      _keepListening = true;
      _voicePausedByUser = false;
      _isRestartPending = false;
      _voicePhase = _VoiceConversationPhase.restartPending;
    });
    if (!_isListening && !_isSubmitting) {
      unawaited(_startConversationListen(resetRetryPolicy: true));
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 백그라운드/전화/화면잠금 시 음성인식 즉시 종료 (좀비 세션·띠링 방지)
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.detached) {
      _keepListening = false;
      _voicePausedByUser = true;
      _restartListenTimer?.cancel();
      _conversationWatchdogTimer?.cancel();
      if (_isListening) {
        unawaited(widget.sttService.cancelActiveListen());
      }
    }
  }

  @override
  void deactivate() {
    // 페이지를 벗어나는 즉시(pop 직전) STT 무조건 종료
    _keepListening = false;
    _restartListenTimer?.cancel();
    _conversationWatchdogTimer?.cancel();
    if (_isListening) {
      unawaited(widget.sttService.cancelActiveListen());
    }
    super.deactivate();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.of(context).viewInsets.bottom > 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
    }
  }

  @override
  void dispose() {
    // 세션 안에서 한 번도 명령이 처리되지 않은 채(말없이) 이탈한 경우를
    // 남긴다. AnalyticsService는 static/부작용 없는 no-op 래퍼라 mounted
    // 여부와 무관하게 안전하게 호출할 수 있다.
    if (!_usageConsumedForSession) {
      unawaited(AnalyticsService.logVoiceConvSessionAbandonedBeforeUse());
    }
    WidgetsBinding.instance.removeObserver(this);
    _keepListening = false;
    _restartListenTimer?.cancel();
    _conversationWatchdogTimer?.cancel();
    unawaited(widget.sttService.cancelActiveListen());
    _inputController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _loadEvents() async {
    debugPrint('VoiceConversationScreen load events start');
    final usesInjectedRepository = widget.repository != null;
    if (!usesInjectedRepository &&
        (!AppEnv.isSupabaseReady || !authProvider.isSignedIn)) {
      debugPrint(
        'VoiceConversationScreen load skipped: '
        'supabaseReady=${AppEnv.isSupabaseReady} '
        'signedIn=${authProvider.isSignedIn}',
      );
      setState(() {
        _isLoading = false;
        final message = !AppEnv.isSupabaseReady
            ? 'Supabase 설정을 확인하지 못했어요.'
            : '로그인 상태를 확인하지 못했어요.';
        // 상태 표시를 대화 버블로 옮겼으므로, 듣는 중이 아닌 진입 시점의 안내도
        // 대화 메시지로 남겨 사용자가 '왜 안 되는지'를 볼 수 있게 한다.
        _messages.add(_ConversationMessage.assistant(message));
      });
      return;
    }
    setState(() => _isLoading = true);
    try {
      final userId = usesInjectedRepository ? null : authProvider.userId;
      final events = await _fetchAndRegisterMergedEvents(userId: userId);
      if (!mounted) return;
      debugPrint(
        'VoiceConversationScreen load events success: ${events.length} '
        '(group=${_groupEventById.length})',
      );
      setState(() {
        _events = events;
        _conversation.replaceEvents(events);
        _isLoading = false;
      });
    } catch (error) {
      debugPrint('VoiceConversationScreen load events failed: $error');
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _messages.add(
          _ConversationMessage.assistant(
            '일정을 불러오지 못했어요. Supabase 연결과 로그인 상태를 확인해 주세요.',
          ),
        );
      });
    }
  }

  /// 개인 일정과 사용자가 속한 그룹의 그룹 일정을 함께 불러와 시간순으로
  /// 병합한다. 그룹 일정은 [_eventModelFromGroupEvent]로 개인 EventModel
  /// 형태로 변환해 컨트롤러의 순번/시간 매칭 로직을 그대로 재사용하되,
  /// 원본은 [_groupEventById]에 등록해 나중에 수정 라우팅에서 역참조한다.
  Future<List<EventModel>> _fetchAndRegisterMergedEvents({
    String? userId,
  }) async {
    final personalEvents = await _repository.listEvents(userId: userId);
    final groupCandidates = await _loadGroupEventCandidates();
    _groupEventById = groupCandidates.byId;
    final merged = <EventModel>[...personalEvents, ...groupCandidates.events];
    merged.sort((a, b) {
      final left = a.startAt ?? DateTime.fromMillisecondsSinceEpoch(0);
      final right = b.startAt ?? DateTime.fromMillisecondsSinceEpoch(0);
      return left.compareTo(right);
    });
    return merged;
  }

  /// 사용자가 속한 모든 그룹의 그룹 일정을 조회해 개인 EventModel 형태로
  /// 변환한다. 그룹 기능을 쓰지 않는 사용자이거나 조회가 실패해도(권한 없음,
  /// 네트워크 오류 등) 개인 일정 음성 흐름 자체는 깨지지 않도록 여기서
  /// 예외를 흡수하고 빈 결과를 반환한다.
  Future<
      ({
        List<EventModel> events,
        Map<String, GroupEventModel> byId,
      })> _loadGroupEventCandidates() async {
    try {
      final groups = await _groupRepository.listGroups();
      if (groups.isEmpty) {
        return (
          events: const <EventModel>[],
          byId: const <String, GroupEventModel>{},
        );
      }
      final from = DateTime.utc(2000);
      final to = DateTime.utc(2100);
      final converted = <EventModel>[];
      final byId = <String, GroupEventModel>{};
      for (final group in groups) {
        final groupEvents = await _groupEventRepository.getEventsForGroup(
          group.id,
          from,
          to,
        );
        for (final groupEvent in groupEvents) {
          if (!groupEvent.isActive) {
            continue;
          }
          final eventModel = _eventModelFromGroupEvent(groupEvent);
          converted.add(eventModel);
          byId[eventModel.id] = groupEvent;
        }
      }
      return (events: converted, byId: byId);
    } catch (error) {
      debugPrint('VoiceConversationScreen group events load failed: $error');
      return (
        events: const <EventModel>[],
        byId: const <String, GroupEventModel>{},
      );
    }
  }

  Future<void> _submitText(
    String? overrideText, {
    bool fromVoiceFinal = false,
    bool inputGenerationAlreadyInvalidated = false,
  }) async {
    // self-gate(딥링크 등 entryGrant 미보유 진입)가 아직 끝나지 않았는데
    // 사용자가 입력창의 전송 버튼을 직접 눌러 이 함수가 먼저 호출될 수
    // 있다. self-gate 완료 전에 진행하면 아래의 _usageConsumedForSession
    // 선점 로직이 유효한 grant 없이 소비 플래그만 먼저 태워버려, self-gate가
    // 나중에 grant를 받아와도 이 세션은 다시는 소비되지 않는다(누락).
    // entryGrant가 이미 있는 정상 경로에서는 completer가 즉시 완료 상태라
    // 체감 지연이 없다.
    if (!_entryGrantReadyCompleter.isCompleted) {
      await _entryGrantReadyCompleter.future;
    }
    if (!mounted) {
      return;
    }
    if (_entryGateDenied) {
      // self-gate가 거부로 끝난 경우 — 명령을 처리하지 않고 조용히 반환한다.
      // (화면은 _closeAfterEntryGateDenied가 이미 닫는 중이므로 여기서 추가
      // 안내는 불필요.)
      return;
    }
    final rawText = (overrideText ?? _inputController.text).trim();
    final text = _normalizeSubmitTextForPendingDelete(rawText);
    if (text.isEmpty || _isSubmitting) {
      debugPrint(
        'VoiceConversationScreen submit ignored: '
        'empty=${text.isEmpty} submitting=$_isSubmitting',
      );
      return;
    }
    // 실제 사용자 명령이 처리되기 시작하는 이 지점이 엔타이틀먼트 소비
    // 시점이다(화면진입/버튼탭/STT준비 등은 소비하지 않는다). 세션당
    // 정확히 1회만 소비하도록 동기적으로 먼저 플래그를 선점한 뒤, 실제
    // RPC 소비는 블로킹 없이 fire-and-forget으로 진행한다(소비 실패해도
    // 사용자 명령 처리 자체는 막지 않음 — fail-open).
    if (!_usageConsumedForSession) {
      _usageConsumedForSession = true;
      final grant = _effectiveEntryGrant;
      if (grant != null) {
        unawaited(_consumeEntitlement(grant));
      }
    }
    _restartListenTimer?.cancel();
    _conversationWatchdogTimer?.cancel();
    // final 음성 한 턴이 제출된 뒤에도 사용자가 '계속 듣기'를 켜 둔
    // 세션이면 음성 입력 상태 자체는 유지한다. 실제 native listen은 현재
    // 명령 처리가 끝난 직후 재시작하지만, UI가 매 턴마다 꺼졌다 켜지는
    // 것처럼 보이지 않게 restart-pending 상태를 즉시 유지한다.
    _isRestartPending = fromVoiceFinal && _keepListening && !_voicePausedByUser;
    final keepVoiceInputActive =
        !fromVoiceFinal && (_isListening || _keepListening);
    if (keepVoiceInputActive) {
      // 사용자가 연속 음성 입력 중 전송 버튼을 누른 경우, 현재 STT 세션의
      // 늦은 partial/final 콜백이 방금 비운 입력창을 다시 채우지 못하도록
      // 현재 입력/리스닝 generation을 즉시 폐기한다. 음성 모드 자체
      // (_keepListening)는 유지하고 명령 처리가 끝난 뒤 새 세션으로 재시작한다.
      _inputTurnGeneration += 1;
      _listenGeneration += 1;
      _isListening = false;
      _isRestartPending = true;
      _armSubmittedVoiceEchoSuppression(text);
      // 화면은 먼저 즉시 비우고, iOS SpeechToText cancel 완료까지 실제로
      // 기다린다. 이전 구현은 cancel을 fire-and-forget으로 보내 새 listen이
      // 옛 recognizer와 겹칠 수 있었고, 그 결과 방금 보낸 문장이 다시
      // partial로 돌아와 입력창을 채우는 실기기 회귀가 남았다.
      _setConversationInputText('');
      await widget.sttService.cancelActiveListen();
    } else {
      if (!inputGenerationAlreadyInvalidated) {
        _inputTurnGeneration += 1;
      }
      if (!fromVoiceFinal) {
        _listenGeneration += 1;
      }
    }
    // 리스닝을 끊지 않고 계속 듣게 두는 경우뿐 아니라, 최종 결과(fromVoiceFinal)
    // 처리 후 자동 재시작되는 경로에서도 화면 입력창만 비우는 것으로는
    // 부족하다 — STT 서비스 내부에 남아있는 이번 발화의 누적 트랜스크립트를
    // 지우지 않으면, 재시작된 리스닝 세션이 옛 문구를 partial/final로 다시
    // 내보내(_applyVoiceTranscriptToInput 경유) 입력창에 되살아나고, 다음
    // 발화 앞에 이어붙거나(committed 텍스트 병합), 침묵 타임아웃으로 옛
    // 텍스트가 그대로 재제출될 수 있다. 자매 화면(voice_input_screen.dart의
    // _clearTranscript)이 동일 상황에서 쓰는 것과 같은 API로 모든 제출
    // 경로에서 리셋한다. 제출 직후 재시작 타이머(700ms)보다 먼저 실행되므로
    // 새 발화의 트랜스크립트를 지울 위험은 없다.
    if (fromVoiceFinal && _keepListening && !_voicePausedByUser) {
      _armSubmittedVoiceEchoSuppression(text);
    }
    await widget.sttService.clearActiveTranscript();
    _setConversationInputText('');
    setState(() {
      _isSubmitting = true;
      _voicePhase = _VoiceConversationPhase.submitting;
      _messages.add(_ConversationMessage.user(text));
    });
    _scrollToBottom();

    try {
      final canLoadEvents = widget.repository != null ||
          (AppEnv.isSupabaseReady && authProvider.isSignedIn);
      if (_events.isEmpty && canLoadEvents) {
        _events = await _fetchAndRegisterMergedEvents(
          userId: widget.repository == null ? authProvider.userId : null,
        );
      }
      _conversation.replaceEvents(_events);
      final result = _conversation.handle(text);
      debugPrint(
        'VoiceConversationScreen result: '
        'action=${result.action.name} visible=${result.visibleEvents.length}',
      );

      // 대상이 그룹 일정으로 병합된 후보라면(음성으로 순번/시간 매칭돼
      // 들어온 경우), 개인 이벤트 화면/저장 경로 대신 그룹 전용 경로로
      // 라우팅한다.
      final targetGroupEvent = result.targetEvent == null
          ? null
          : _groupEventById[result.targetEvent!.id];

      // 후속 안내 메시지를 지면에서 교체해야 할 때 세팅한다. null 이면
      // 기본 _messageForResult(result)을 그대로 쓰고, null 이 아니면 그
      // 문자열을 그대로 쓴다(특히 '저장됨' 표현을 말하지 않아야 하는 폴백
      // 경로에서 사용한다).
      String? messageOverride;
      // 폴백 시 메시지 카드에 실어 보낼 일정 목록. null 이면 result 의
      // visibleEvents 를 그대로 쓴다. 자동 저장 실패 시 원본이 아니라
      // 제안된 드래프트(새 날짜)를 실어서, 편집 버튼으로 다시 열 때 요청한
      // 날짜가 유지되도록 한다.
      List<EventModel>? eventsOverride;

      if (result.action == VoiceConversationAction.convertToPersonalConfirmed &&
          result.targetEvent != null) {
        if (targetGroupEvent == null) {
          if (mounted) {
            setState(() {
              _messages.add(
                const _ConversationMessage.assistant('이미 개인 일정이에요.'),
              );
            });
          }
          return;
        }
        final converted = await _convertGroupEventToPersonal(targetGroupEvent);
        if (!converted) {
          return;
        }
      } else if (result.deleteConfirmed && result.targetEvent != null) {
        if (targetGroupEvent != null) {
          final canceled = await _cancelGroupEvent(targetGroupEvent);
          if (!canceled) {
            return;
          }
        } else {
          // 반복 일정 + 회차가 확정된 pendingDelete면 시리즈 전체가 아니라
          // 그 회차만 삭제한다(pendingDelete.occurrenceDate 보존).
          final occurrenceDate = result.pendingDelete?.occurrenceDate;
          final rule = result.targetEvent!.recurrenceRule;
          final isRecurring = rule != null && rule.trim().isNotEmpty;
          final deleted = isRecurring && occurrenceDate != null
              ? await _deleteEventOccurrence(
                  result.targetEvent!,
                  occurrenceDate,
                )
              : await _deleteEvent(result.targetEvent!);
          if (!deleted) {
            return;
          }
        }
      } else if (targetGroupEvent != null &&
          (result.action == VoiceConversationAction.confirmedEdit ||
              result.requiresEditScreenNavigation)) {
        final updated =
            await _applyGroupEventVoiceUpdate(result, targetGroupEvent);
        if (!updated) {
          return;
        }
      } else if (result.action == VoiceConversationAction.confirmedEdit &&
          result.targetEvent != null) {
        // 단독 날짜/시간 변경이면 편집 화면 없이 곧바로 저장한다.
        // 컨트롤러가 canAutoApplyDateChange를 true 로 둔 결과만 자동 저장
        // 경로에 들어오며, 점검이 실패하거나 저장 실패하면 편집 화면으로
        // 드래프트를 그대로 넘겨 사용자가 명시적으로 저장하도록 한다(자동
        // 저장 경로가 '저장됨' 안내를 먼저 보내지 않도록 폴업은 저장
        // 경로 밖에서 처리).
        if (_canApplyDateChangeAuto(
          result: result,
          targetEvent: result.targetEvent!,
        )) {
          final dateSaved = await _applyConversationDateAutoSave(
            result: result,
            targetEvent: result.targetEvent!,
          );
          if (dateSaved) {
            // 성공. 기본 안내는 아래 _messageForResult 로 처리한다.
          } else {
            // 자동 저장 불가/실패(중복 경고 취소, 저장소 오류 포함): 저장은
            // 일어나지 않았으므로 '저장됨' 표현을 쓰지 않고, 제안된 드래프트
            // (요청한 새 날짜)를 편집 화면과 메시지 카드에 그대로 넘겨
            // 사용자가 확정하도록 한다.
            final fallbackDraft = result.draftEvent ?? result.targetEvent!;
            await _openGeneralEditScreen(
              fallbackDraft,
              originalEvent: _canonicalOriginalFor(fallbackDraft.id),
              originalOccurrenceStartAt: result.targetEvent?.startAt,
            );
            messageOverride = '저장하지 않았어요. 편집 화면에서 내용을 확인하고 저장해 주세요.';
            eventsOverride = <EventModel>[fallbackDraft];
          }
        } else {
          final updated = await _applyConversationEventUpdate(result);
          if (!updated) {
            return;
          }
        }
      } else if (result.action == VoiceConversationAction.createEvent &&
          result.draftEvent != null) {
        await _openCreateEventScreen(result.inputText, result.draftEvent);
      } else if (result.requiresEditScreenNavigation &&
          result.targetEvent != null &&
          result.locationText != null) {
        // 복합 변경은 장소 선택 지도를 먼저 열지 않는다. 시간 등 함께
        // 인식한 필드를 하나의 초안으로 보여 주고 사용자가 저장에서 확정한다.
        final draft = result.draftEvent;
        if (draft != null) {
          await _openGeneralEditScreen(draft);
        } else {
          final validatedLocation =
              await GptService().validateLocation(result.locationText!);
          if (validatedLocation != null) {
            await _openEditWithLocation(result.targetEvent!, validatedLocation);
          } else {
            await _openGeneralEditScreen(result.targetEvent!);
          }
        }
      } else if (result.requiresEditScreenNavigation &&
          result.targetEvent != null &&
          result.locationText == null) {
        // location 변경 외 수정(날짜·시간 이동 등): 일반 편집 화면으로 이동.
        // 날짜 이동 제안은 캐논컬 원본과 선택된 회차(변경 전) 시작 시각을
        // 함께 넘겨 편집 화면의 source 스코프로 삼게 한다. 반복 일정은
        // 회차 시작 시각을 별도 필드로만 전달하고 원본 치환은 하지 않는다.
        final draftForEdit = result.draftEvent ?? result.targetEvent!;
        await _openGeneralEditScreen(
          draftForEdit,
          originalEvent: _canonicalOriginalFor(draftForEdit.id),
          originalOccurrenceStartAt: result.targetEvent?.startAt,
        );
      }

      if (!mounted) return;
      setState(() {
        _messages.add(
          _ConversationMessage.assistant(
            messageOverride ?? _messageForResult(result),
            events: eventsOverride ?? result.visibleEvents,
            pendingDeleteEvent:
                result.requiresDeleteConfirmation ? result.targetEvent : null,
            deleteOccurrenceDate: result.requiresDeleteConfirmation
                ? result.pendingDelete?.occurrenceDate
                : null,
          ),
        );
      });
    } catch (error) {
      debugPrint('VoiceConversationScreen submit failed: $error');
      if (!mounted) return;
      setState(() {
        _messages.add(
          const _ConversationMessage.assistant(
            '처리 중 문제가 생겼어요. 잠시 후 다시 말해 주세요.',
          ),
        );
      });
    } finally {
      if (mounted) {
        setState(() => _isSubmitting = false);
        _scrollToBottom();
        if (keepVoiceInputActive &&
            _keepListening &&
            !_voicePausedByUser &&
            !_isListening) {
          _scheduleAutoRestartListen(
            delay: const Duration(milliseconds: 120),
          );
        }
      }
    }
  }

  Future<void> _listenOnce() async {
    if (_isListening) {
      debugPrint('VoiceConversationScreen listen ignored: already listening');
      return;
    }
    _restartListenTimer?.cancel();
    _conversationWatchdogTimer?.cancel();
    _isRestartPending = false;
    _manualEditInterruptedListening = false;
    _nativeVoiceReady = false;
    final listenGeneration = ++_listenGeneration;
    final inputGeneration = _inputTurnGeneration;
    var shouldRetryEarlyFailure = false;
    debugPrint('VoiceConversationScreen STT start');
    setState(() {
      _isListening = true;
      _keepListening = true;
      _voicePausedByUser = false;
      _voicePhase = _VoiceConversationPhase.restartPending;
    });
    _setConversationInputText('');
    // 대화 꼬리에 붙는 음성 상태 버블이 바로 시야에 들어오게 맨 아래로 스크롤.
    _scrollToBottom();
    _armConversationWatchdog(listenGeneration);
    try {
      final result = await widget.sttService.listen(
        onPartialResult: (text) {
          final normalized = SttService.normalizeVoiceTranscript(text);
          debugPrint('VoiceConversationScreen STT partial: $normalized');
          if (!mounted || normalized.isEmpty) {
            return;
          }
          _applyVoiceTranscriptToInput(
            normalized,
            listenGeneration: listenGeneration,
            inputGeneration: inputGeneration,
          );
          _armConversationWatchdog(listenGeneration);
          if (!mounted || listenGeneration != _listenGeneration) {
            return;
          }
          setState(() {
            _nativeVoiceReady = true;
            _voicePhase = _VoiceConversationPhase.listening;
          });
        },
        onRestart: (count) {
          if (!mounted || listenGeneration != _listenGeneration) {
            return;
          }
          debugPrint(
            'VoiceConversationScreen STT restarted: count=$count gen=$listenGeneration',
          );
          setState(() {
            _nativeVoiceReady = false;
            _isRestartPending = true;
            _voicePhase = _VoiceConversationPhase.restartPending;
          });
          _armConversationWatchdog(listenGeneration);
        },
        onStatus: (event) {
          _handleNativeVoiceStatus(
            event,
            listenGeneration: listenGeneration,
          );
        },
        mode: SttListenMode.dictation,
      );
      if (!mounted) {
        return;
      }
      if (listenGeneration != _listenGeneration) {
        return;
      }
      _conversationWatchdogTimer?.cancel();
      final finalText = SttService.normalizeVoiceTranscript(result.text ?? '');
      final submitText = _normalizeSubmitTextForPendingDelete(finalText);
      debugPrint(
        'VoiceConversationScreen STT final: '
        'success=${result.isSuccess} hasText=${result.hasText} text=$submitText',
      );
      if (_manualEditInterruptedListening) {
        if (mounted && listenGeneration == _listenGeneration) {
          setState(() {
            _isListening = false;
            _voicePhase = _VoiceConversationPhase.idle;
          });
        }
        return;
      }
      if (result.isSuccess &&
          submitText.isNotEmpty &&
          _shouldSuppressSubmittedVoiceEcho(submitText)) {
        debugPrint(
          'VoiceConversationScreen STT final suppressed as submitted echo: '
          '$submitText',
        );
        shouldRetryEarlyFailure = true;
        if (mounted && listenGeneration == _listenGeneration) {
          setState(() {
            _isListening = false;
            _isRestartPending = true;
            _voicePhase = _VoiceConversationPhase.restartPending;
          });
        }
      } else if (result.isSuccess && submitText.isNotEmpty) {
        if (mounted && listenGeneration == _listenGeneration) {
          setState(() {
            _isListening = false;
            _voicePhase = _VoiceConversationPhase.finalizing;
          });
        }
        // 최종 음성 결과가 확정된 순간 입력창을 즉시 비운다. 이전에는
        // final 텍스트를 한 번 더 입력창에 넣은 뒤 _submitText 내부에서
        // 비워서, iOS에서 다음 STT partial이 겹칠 때 이전 문장이 잠깐
        // 남거나 몇 글자씩 섞여 보였다. 여기서 generation을 먼저 넘겨
        // 현재 listen의 늦은 partial도 동시에 무효화한다.
        _inputTurnGeneration += 1;
        _setConversationInputText('');
        await _submitText(
          submitText,
          fromVoiceFinal: true,
          inputGenerationAlreadyInvalidated: true,
        );
      } else if (_shouldRetryEarlyListen(result) &&
          !_didRetryConversationEarlyFailure &&
          !_manualEditInterruptedListening &&
          !_voicePausedByUser) {
        shouldRetryEarlyFailure = true;
        _didRetryConversationEarlyFailure = true;
        if (mounted && listenGeneration == _listenGeneration) {
          setState(() {
            _isListening = false;
            _isRestartPending = true;
            _voicePhase = _VoiceConversationPhase.restartPending;
          });
        }
      } else if (mounted) {
        final message = result.message ?? '음성을 알아듣지 못했어요. 다시 말해 주세요.';
        setState(() {
          _messages.add(
            _ConversationMessage.assistant(
              message,
            ),
          );
        });
      }
    } catch (error) {
      debugPrint('VoiceConversationScreen STT failed: $error');
      if (!mounted) return;
      if (listenGeneration != _listenGeneration) {
        return;
      }
      setState(() {
        _messages.add(
          const _ConversationMessage.assistant(
            '음성 입력을 시작하지 못했어요. 잠시 후 다시 시도해 주세요.',
          ),
        );
      });
    } finally {
      _conversationWatchdogTimer?.cancel();
      if (mounted && listenGeneration == _listenGeneration) {
        setState(() {
          _isListening = false;
          _nativeVoiceReady = false;
          if (!_keepListening) {
            _voicePhase = _VoiceConversationPhase.idle;
          }
        });
      }
    }

    if (shouldRetryEarlyFailure &&
        listenGeneration == _listenGeneration &&
        _keepListening &&
        !_voicePausedByUser &&
        mounted) {
      _scheduleAutoRestartListen(
        delay: const Duration(milliseconds: 650),
      );
      return;
    }

    if (listenGeneration == _listenGeneration &&
        _keepListening &&
        !_voicePausedByUser &&
        mounted) {
      _isRestartPending = true;
      if (mounted) {
        setState(() => _voicePhase = _VoiceConversationPhase.restartPending);
      }
      _scheduleAutoRestartListen();
    }
  }

  void _handleNativeVoiceStatus(
    SttNativeStatusEvent event, {
    required int listenGeneration,
  }) {
    if (!mounted || listenGeneration != _listenGeneration) {
      return;
    }
    switch (event.status) {
      case SttNativeStatus.ready:
      case SttNativeStatus.speechStart:
        setState(() {
          _nativeVoiceReady = true;
          _isRestartPending = false;
          _hasVoiceBeenReadyThisTurn = true;
          _voiceUnstable = false;
          _voicePhase = _VoiceConversationPhase.listening;
        });
        _armConversationWatchdog(listenGeneration);
        break;
      case SttNativeStatus.speechEnd:
      case SttNativeStatus.segmentEnded:
        setState(() {
          _nativeVoiceReady = true;
        });
        _armConversationWatchdog(listenGeneration);
        break;
      case SttNativeStatus.restarted:
        setState(() {
          _nativeVoiceReady = false;
          _isRestartPending = true;
          _voicePhase = _VoiceConversationPhase.restartPending;
        });
        _armConversationWatchdog(listenGeneration);
        break;
      case SttNativeStatus.stalled:
        if (_didRetrySilentNativeStart) {
          setState(() {
            _nativeVoiceReady = false;
            _voiceUnstable = true;
          });
          return;
        }
        _didRetrySilentNativeStart = true;
        setState(() {
          _nativeVoiceReady = false;
          _isRestartPending = true;
          _voicePhase = _VoiceConversationPhase.restartPending;
        });
        unawaited(widget.sttService.cancelActiveListen());
        break;
      case SttNativeStatus.stopped:
      case SttNativeStatus.cancelled:
      case SttNativeStatus.error:
        setState(() {
          _nativeVoiceReady = false;
          if (!_keepListening || _voicePausedByUser) {
            _isListening = false;
          }
        });
        break;
    }
  }

  void _scheduleAutoRestartListen({
    Duration delay = const Duration(milliseconds: 700),
  }) {
    if (!_keepListening || _voicePausedByUser || !mounted) {
      return;
    }
    _isRestartPending = true;
    _restartListenTimer?.cancel();
    _restartListenTimer = Timer(delay, () {
      if (_keepListening && !_voicePausedByUser && mounted && !_isListening) {
        _isRestartPending = false;
        unawaited(_listenOnce());
      }
    });
  }

  void _armConversationWatchdog(int listenGeneration) {
    _conversationWatchdogTimer?.cancel();
    _conversationWatchdogTimer = Timer(const Duration(seconds: 8), () {
      if (!mounted ||
          listenGeneration != _listenGeneration ||
          !_isListening ||
          _voicePausedByUser) {
        return;
      }
      if (_nativeVoiceReady) {
        _armConversationWatchdog(listenGeneration);
        return;
      }
      if (_didRetrySilentNativeStart) {
        setState(() {
          _nativeVoiceReady = false;
          _isRestartPending = true;
          _voiceUnstable = true;
          _voicePhase = _VoiceConversationPhase.restartPending;
        });
        _armConversationWatchdog(listenGeneration);
        return;
      }
      _didRetrySilentNativeStart = true;
      debugPrint(
        'VoiceConversationScreen native ready watchdog timeout: gen=$listenGeneration',
      );
      if (mounted && listenGeneration == _listenGeneration) {
        setState(() {
          _nativeVoiceReady = false;
          _isRestartPending = true;
          _voicePhase = _VoiceConversationPhase.restartPending;
        });
      }
      unawaited(widget.sttService.cancelActiveListen());
    });
  }

  bool _shouldRetryEarlyListen(SttListenResult result) {
    if (result.hasText) {
      return false;
    }
    return result.failure == SttListenFailure.silence ||
        result.failure == SttListenFailure.unavailable;
  }

  Future<void> _startConversationListen(
      {required bool resetRetryPolicy}) async {
    // 사용자가 마이크 버튼을 직접 눌러 self-gate 완료 전에 이 함수가 먼저
    // 호출될 수 있다(위 _submitText와 동일한 레이스). entryGrant가 이미
    // 있는 정상 경로에서는 completer가 즉시 완료 상태라 체감 지연이 없다.
    if (!_entryGrantReadyCompleter.isCompleted) {
      await _entryGrantReadyCompleter.future;
    }
    if (!mounted) {
      return;
    }
    if (_entryGateDenied) {
      // self-gate가 거부로 끝난 경우 — 마이크를 시작하지 않고 조용히
      // 반환한다. (화면은 _closeAfterEntryGateDenied가 이미 닫는 중이므로
      // 여기서 추가 안내는 불필요.)
      return;
    }
    if (resetRetryPolicy) {
      _didRetryConversationEarlyFailure = false;
      _didRetrySilentNativeStart = false;
      // 사용자가 직접 마이크를 다시 누른 새 시작이므로 상태 문구를 초기화한다.
      // (계속 듣기 중 조용히 재시작하는 경우는 _listenOnce에서 유지된다.)
      _hasVoiceBeenReadyThisTurn = false;
      _voiceUnstable = false;
    }
    await _listenOnce();
  }

  Future<void> _pauseVoiceInput() async {
    _restartListenTimer?.cancel();
    _conversationWatchdogTimer?.cancel();
    _isRestartPending = false;
    _listenGeneration += 1;
    _manualEditInterruptedListening = true;
    _didRetryConversationEarlyFailure = false;
    if (mounted) {
      setState(() {
        _voicePhase = _VoiceConversationPhase.stopping;
        _keepListening = false;
        _voicePausedByUser = true;
        _isListening = false;
        _hasVoiceBeenReadyThisTurn = false;
        _voiceUnstable = false;
      });
    } else {
      _keepListening = false;
      _voicePausedByUser = true;
      _isListening = false;
      _hasVoiceBeenReadyThisTurn = false;
      _voiceUnstable = false;
    }
    await widget.sttService.stopActiveListen();
  }

  Future<void> _openCreateEventScreen(
    String rawInput,
    EventModel? fallbackDraft,
  ) async {
    await _stopVoiceBeforeNavigation();
    if (!mounted) return;

    EventModel draft;
    try {
      final parsed = await GptService().parseSchedule(rawInput);
      final title = (parsed['title'] as String?)?.trim();
      final startAtRaw = parsed['start_at']?.toString();
      DateTime? startAt;
      if (startAtRaw != null) {
        final dt = DateTime.tryParse(startAtRaw);
        startAt = dt?.isUtc == true ? dt!.toLocal() : dt;
      }
      final endAtRaw = parsed['end_at']?.toString();
      DateTime? endAt;
      if (endAtRaw != null) {
        final dt = DateTime.tryParse(endAtRaw);
        endAt = dt?.isUtc == true ? dt!.toLocal() : dt;
      }
      final now = planflowNow();
      final resolvedStart = startAt ?? now;
      final resolvedEnd = endAt ?? resolvedStart.add(const Duration(hours: 1));
      draft = EventModel(
        id: '',
        userId: '',
        title: (title?.isNotEmpty == true) ? title! : rawInput,
        startAt: resolvedStart,
        endAt: resolvedEnd,
        isCritical: parsed['is_critical'] == true,
        useStrongAlarm: parsed['use_strong_alarm'] == true,
        recurrenceRule: (parsed['recurrence_rule'] as String?)?.trim(),
        location: (parsed['location'] as String?)?.trim(),
        locationLat: parsed['location_lat'] as double?,
        locationLng: parsed['location_lng'] as double?,
        createdAt: now,
      );
    } catch (_) {
      draft = fallbackDraft ??
          EventModel(
            id: '',
            userId: '',
            title: rawInput,
            createdAt: planflowNow(),
          );
    }

    if (!mounted) return;
    await context.push('${AppRoutes.eventEdit}/${draft.id}', extra: draft);
    await _loadEvents();
    _resumeListeningAfterNavigation();
  }

  Future<void> _openEditWithLocation(
    EventModel event,
    String locationText,
  ) async {
    await _stopVoiceBeforeNavigation();
    final picked = await widget.locationPicker(
      // ignore: use_build_context_synchronously
      context: context,
      query: locationText,
      locationLookupService: widget.locationLookupService,
      appPermissionService: widget.permissionService,
    );
    if (!mounted || picked == null) {
      _resumeListeningAfterNavigation();
      return;
    }

    final resolvedLabel = picked.bestPlaceLabel.trim();
    final edited = _copyEventWithLocation(
      event,
      location: resolvedLabel.isNotEmpty ? resolvedLabel : picked.label,
      locationLat: picked.latitude,
      locationLng: picked.longitude,
    );

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          edited.locationLat != null
              ? '장소가 입력되었습니다. 지도 위치를 확인하고 저장해 주세요.'
              : '장소 이름을 입력했습니다. 지도 위치를 확인하고 저장해 주세요.',
        ),
      ),
    );
    await context.push('${AppRoutes.eventEdit}/${edited.id}', extra: edited);
    await _loadEvents();
    _resumeListeningAfterNavigation();
  }

  /// 날짜·시간 이동 등 일반 수정: 편집 화면으로 바로 이동해 GPT 파이프라인이 처리한다.
  /// 편집 화면으로 이동한다. [originalEvent]에 캐논컬 원본(같은 id의 저장된
  /// 일정 스냅샷)을 주면 라우트 extra로 [EventEditRoutePayload]를 전달한다.
  /// 편집 화면은 요청한 날짜(draft)를 그대로 보여 주면서도 리마인더/반복
  /// 스코프/previousStart는 원본 기준으로 읽는다. 원본을 모르면 기존처럼
  /// EventModel만 전달한다(하위 호환).
  Future<void> _openGeneralEditScreen(
    EventModel event, {
    EventModel? originalEvent,
    DateTime? originalOccurrenceStartAt,
  }) async {
    await _stopVoiceBeforeNavigation();
    if (!mounted) return;
    await context.push(
      '${AppRoutes.eventEdit}/${event.id}',
      extra: _eventEditRouteExtra(
        draft: event,
        originalEvent: originalEvent,
        originalOccurrenceStartAt: originalOccurrenceStartAt,
      ),
    );
    await _loadEvents();
    _resumeListeningAfterNavigation();
  }

  /// 편집 라우트 extra를 만든다. 원본을 알 수 없거나 드래프트와 같은
  /// 인스턴스면 기존 호환을 위해 EventModel 그대로 전달한다.
  Object _eventEditRouteExtra({
    required EventModel draft,
    EventModel? originalEvent,
    DateTime? originalOccurrenceStartAt,
  }) {
    if (originalEvent == null || identical(originalEvent, draft)) {
      return draft;
    }
    return EventEditRoutePayload(
      draft: draft,
      original: originalEvent,
      originalOccurrenceStartAt: originalOccurrenceStartAt,
    );
  }

  /// 화면이 보유한 목록(_events)에서 같은 id의 캐논컬 원본을 찾는다.
  EventModel? _canonicalOriginalFor(String eventId) {
    for (final event in _events) {
      if (event.id == eventId) {
        return event;
      }
    }
    return null;
  }

  /// 음성 명력으로 일간/시간을 옮길 때 편집 화면 없이 곧바로 저장해도 안전한
  /// 대상인지 판정한다. 다음 조건을 모두 통과해야 자동 저장 경로로 분기한다.
  ///
  /// 1) 컨트롤러가 명시적으로 `canAutoApplyDateChange=true`를 둔 결과(단독
  ///    날짜/시간 변경, 장소·중요도·강한 알람 등 다른 필드 변경 없음).
  /// 2) 대상 일정이 개인 소유다(현재 사용자 본인이 만들거나, 그룹 공유본이
  ///    개인 사본을 가진 일정). 본 적 목록(_events)에 없는 id이거나
  ///    [_groupEventById] 레지스트리에 존재하는 그룹 일정이면 false.
  /// 3) 반복 일정(rrule)이 아니고 그룹 일정 연결(groupEventId)도 없는 일정.
  /// 4) 드래프트가 시작 시각을 가지고 있고 원본과 실제 다른 값을 가지고 있다.
  /// 5) 결과에 다른 필드 변경(locationText, criticalValue)이 함께 실려
  ///    있지 않다(동시 변경은 컨트롤러 쪽에서 requiresEditScreenNavigation을
  ///    세우지만, 방어 차원에서 한 번 더 검사한다).
  @visibleForTesting
  bool debugCanApplyDateChangeAuto({
    required VoiceConversationResult result,
    required EventModel targetEvent,
  }) =>
      _canApplyDateChangeAuto(result: result, targetEvent: targetEvent);

  bool _canApplyDateChangeAuto({
    required VoiceConversationResult result,
    required EventModel targetEvent,
  }) {
    if (!result.canAutoApplyDateChange) {
      return false;
    }
    if (result.locationText != null && result.locationText!.trim().isNotEmpty) {
      return false;
    }
    if (result.criticalValue != null) {
      return false;
    }
    final draft = result.draftEvent;
    if (draft == null || draft.startAt == null) {
      return false;
    }
    if (targetEvent.startAt == draft.startAt) {
      return false;
    }
    final rule = targetEvent.recurrenceRule?.trim();
    if (rule != null && rule.isNotEmpty) {
      return false;
    }
    if (targetEvent.groupEventId != null &&
        targetEvent.groupEventId!.trim().isNotEmpty) {
      return false;
    }
    // 외부 캘린더 연동 일정(externalId/externalCalendarId)은 단독 자동 저장
    // 대상에서 제외한다. 외부 동기화 충돌을 피하고, 편집 화면 경로에서 기존
    // 동기화 흐름을 그대로 태우기 위함이다.
    final externalId = targetEvent.externalId?.trim();
    if (externalId != null && externalId.isNotEmpty) {
      return false;
    }
    final externalCalendarId = targetEvent.externalCalendarId?.trim();
    if (externalCalendarId != null && externalCalendarId.isNotEmpty) {
      return false;
    }
    if (_groupEventById.containsKey(targetEvent.id)) {
      return false;
    }
    // 본 후보 목록에 실제로 존재하고 id가 일치하는 일정만 자동 저장 대상으로
    // 인정한다. 이렇게 하면 새 id, 이미 삭제된 id, 다른 사용자의 일정 등
    // 모르는 대상을 자동으로 경로로 저장하지 않는다(요청에 따라 다시 편집 화면
    // 안내로 폴백).
    final currentIndex =
        _events.indexWhere((candidate) => candidate.id == targetEvent.id);
    if (currentIndex < 0) {
      return false;
    }
    // 대상 신선도 검증: 결과에 실린 대상이 화면이 알던 최신본과 다르면
    // (예: 저장 직후 다른 경로에서 갱신된 경우) fail-closed 로 편집 화면
    // 경로로 되돌린다.
    final current = _events[currentIndex];
    final targetUpdatedAt = targetEvent.updatedAt;
    final currentUpdatedAt = current.updatedAt;
    if (targetUpdatedAt != null &&
        currentUpdatedAt != null &&
        !targetUpdatedAt.isAtSameMomentAs(currentUpdatedAt)) {
      return false;
    }
    return true;
  }

  /// 날짜 자동 저장에서 기존 push 리마인더의 '개별' 오프셋을 보존한다.
  ///
  /// 편집 화면(_loadReminderOffsetIfNeeded)과 동일하게 reminders 테이블의
  /// notify_at을 [originalEvent](변경 전 원본)의 시작 시각 기준으로 역산한다:
  /// - 조회 타입은 저장 서비스(manual_event_side_effect_service)와 동일하게
  ///   크리티컬 일정은 'system_alarm', 일반 일정은 'push'다. 타입을 잘못
  ///   고르면 실제 행이 있는데도 '없음'으로 오판해 오프셋이 리셋된다.
  /// - 일반 일정은 push 행이 없으면 null을 반환해 '알림 끔' 상태를 유지한다
  ///   (꺼진 알림이 자동 저장으로 켜지지 않는다).
  /// - 크리티컬 일정은 system_alarm 행이 없으면 상태를 확정할 수 없어
  ///   예외를 던진다(저장 전 fail-closed).
  /// - 유효 범위는 편집 화면과 같은 0~1440분이고 0분(정시)도 유효하다.
  /// - 읽기 실패/값 비정상/범위 이탈은 예외를 던진다. 호출부는 저장 전에
  ///   fail-closed 해야 하며, 사용자 설정 기본값이나 60분 폴백으로 대체한
  ///   채 '저장됨'을 보고하면 안 된다(잘못된 알림 재발급 금지).
  Future<Duration?> _resolveOriginalReminderOffset({
    required String userId,
    required EventModel originalEvent,
  }) async {
    final originalStart = originalEvent.startAt;
    if (originalStart == null) {
      throw StateError(
        '원본 일정에 시작 시각이 없어 리마인더 오프셋을 복원할 수 없어요',
      );
    }
    final reader = widget.reminderNotifyAtReader;
    DateTime? notifyAt;
    if (reader != null) {
      // 주입된 reader: null = 리마인더 행 없음(끔 보존), 예외 = 조회 실패.
      notifyAt = await reader(userId, originalEvent.id);
    } else {
      if (!AppEnv.isSupabaseReady) {
        throw StateError(
          '리마인더 조회 환경이 준비되지 않아 오프셋을 복원할 수 없어요',
        );
      }
      // 저장 서비스와 동일한 타입 선택: 크리티컬은 system_alarm, 일반은 push.
      final reminderType = originalEvent.isCritical ? 'system_alarm' : 'push';
      final row = await Supabase.instance.client
          .from('reminders')
          .select('notify_at')
          .eq('event_id', originalEvent.id)
          .eq('user_id', userId)
          .eq('type', reminderType)
          .maybeSingle();
      final rawNotifyAt = row == null ? null : row['notify_at'];
      if (rawNotifyAt != null) {
        notifyAt = DateTime.tryParse(rawNotifyAt.toString());
        if (notifyAt == null) {
          throw FormatException('리마인더 notify_at 해석 실패: $rawNotifyAt');
        }
      }
    }
    if (notifyAt == null) {
      if (originalEvent.isCritical) {
        // 크리티컬 일정의 알람 행이 없으면 상태를 확정할 수 없다. 전역
        // 기본값(60분)으로 대체하지 않고 저장 전에 실패시킨다.
        throw StateError(
          '중요 일정의 알람 행을 찾을 수 없어 오프셋을 복원할 수 없어요',
        );
      }
      return null;
    }
    final minutes = originalStart.difference(notifyAt).inMinutes;
    if (minutes < 0 || minutes > 1440) {
      throw FormatException('리마인더 오프셋 범위 이탈: $minutes분');
    }
    return Duration(minutes: minutes);
  }

  /// 음성 명력으로 일간/시간을 곧바로 옮겨 저장한다. 호출 전
  /// [_canApplyDateChangeAuto] 검증을 통과한 경우에만 호출한다.
  ///
  /// 테스트가 직접 인스턴스화해 호출할 수 있도록 같은 본문을
  /// [debugApplyConversationDateAutoSave]에 공개한다. 이 메서드는
  /// [_applyConversationDateAutoSave]를 그대로 위임만 한다.
  ///
  /// 실패 흐름:
  /// - 반복 일정 검출: 편집 화면으로 드래프트를 그대로 넘긴다.
  /// - 기존 리마인더 오프셋 복원 실패(조회 오류/값 비정상): 저장 전에
  ///   실패 처리해 편집 화면 폴백으로 넘긴다(거짓 저장 성공 금지).
  /// - 저장소 오류: 저장 전으로 돌아가고 편집 화면으로 드래프트를 넘긴다
  ///   (false 이거나 throw를 잡아 호출자가 폴백을 선택하게 한다).
  /// - 중복 알림 경고 다이얼로그에서 취소: 저장 없이 false 반환.
  /// - 저장 후 사이드 이벤트(syncAfterSave) 실패: 저장은 이미 성공했으므로
  ///   '일부 알림/위젯 동기화에 실패했어요'라는 제한 안내만 추가하고 true
  ///   반환로 처리한다.
  @visibleForTesting
  Future<bool> debugApplyConversationDateAutoSave({
    required VoiceConversationResult result,
    required EventModel targetEvent,
  }) =>
      _applyConversationDateAutoSave(
        result: result,
        targetEvent: targetEvent,
      );

  /// 안내 문구 규칙을 위젯 경로 밖에서 검증하기 위한 위임자. 실제 저장
  /// 날짜를 문구에 말하는지, '편집 화면' 표현을 쓰지 않는지 확인한다.
  @visibleForTesting
  String debugMessageForResult(VoiceConversationResult result) =>
      _messageForResult(result);

  Future<bool> _applyConversationDateAutoSave({
    required VoiceConversationResult result,
    required EventModel targetEvent,
  }) async {
    // 위젯 경로를 거치지 않고 직접 호출되는 경우에도 가드를 다시 통과시킨다.
    // 가드가 거부하면 저장 없이 false 로 fail-closed 한다.
    if (!_canApplyDateChangeAuto(result: result, targetEvent: targetEvent)) {
      return false;
    }
    final draft = result.draftEvent!;
    final newStart = draft.startAt!;
    final originalStart = targetEvent.startAt;
    final originalEnd = targetEvent.endAt;
    final originalDuration = (originalStart != null && originalEnd != null)
        ? originalEnd.difference(originalStart)
        : const Duration(hours: 1);
    final fallbackEnd = newStart.add(
      originalDuration.isNegative || originalDuration == Duration.zero
          ? const Duration(hours: 1)
          : originalDuration,
    );
    // 드래프트 종료가 없거나 새 시작보다 과거(원본 날짜의 오래된 endAt 이
    // 남은 경우)면, 원본 시각/길이를 보존해 새 시작 기준으로 재계산한다.
    final draftEnd = draft.endAt;
    final newEnd = (draftEnd != null && draftEnd.isAfter(newStart))
        ? draftEnd
        : fallbackEnd;

    try {
      final overlappingEvents = await _repository.findOverlappingEvents(
        rangeStart: newStart,
        rangeEnd: newEnd,
        userId: widget.repository == null ? authProvider.userId : null,
        excludedEventId: targetEvent.id,
      );
      if (!mounted) {
        return false;
      }
      final candidateDraft = targetEvent.copyWith(
        startAt: newStart,
        endAt: newEnd,
      );
      final duplicateWarningEvents = filterDuplicateWarningEvents(
        draft: candidateDraft,
        candidates: overlappingEvents,
      );
      if (duplicateWarningEvents.isNotEmpty) {
        final shouldContinue = await showOverlapWarningDialog(
          context: context,
          overlappingEvents: duplicateWarningEvents,
        );
        if (!mounted) {
          return false;
        }
        if (!shouldContinue) {
          return false;
        }
      }

      final updated = targetEvent.copyWith(startAt: newStart, endAt: newEnd);

      // 기존 push 리마인더의 개별 오프셋은 '저장 이전'에 복원한다. 복원이
      // 실패하면 예외가 던져져 아래 updateEvent에 도달하지 못하고 fail-closed
      // 한다. 저장이 끝난 뒤에는 알림 상태를 되돌릴 수 없기 때문이다. 오프셋은
      // 드래프트/저장본이 아니라 '원본(변경 전) 시작 시각' 기준으로 역산한다.
      final userIdForSideEffects = widget.repository == null
          ? (authProvider.userId ?? '')
          : updated.userId;
      Duration? originalReminderOffset;
      if (userIdForSideEffects.isNotEmpty) {
        originalReminderOffset = await _resolveOriginalReminderOffset(
          userId: userIdForSideEffects,
          originalEvent: targetEvent,
        );
      }
      if (!mounted) {
        return false;
      }

      final saved = await _repository.updateEvent(updated);

      // 저장 성공 이후에만 내부 상태와 EventRefreshBus를 갱신한다. 부분
      // 성공 시 false 로컬 변경/사이드 메시지가 나오지 않도록 한다.
      _events = _events
          .map((candidate) => candidate.id == saved.id ? saved : candidate)
          .toList(growable: false);
      _conversation.replaceEvents(_events);
      EventRefreshBus.instance.notifyChanged(
        reason: 'voice_conversation_date_update',
        eventId: saved.id,
        startAt: saved.startAt,
      );

      // 알림/외부/위젯/예비 액션 재동기화. 실패해도 사용자 의도는 이미
      // 영구 저장이 완료된 상태이므로 '일부 동기화 실패' 안내만 추가한다.
      if (userIdForSideEffects.isNotEmpty) {
        // 저장 전 복원한 개별 오프셋(리마인더 행이 없으면 null)을 그대로
        // 전달한다. null은 편집 화면과 동일하게 '알림 끔' 유지를 뜻한다.
        try {
          await _sideEffectService.syncAfterSave(
            event: saved,
            userId: userIdForSideEffects,
            reminderOffset: originalReminderOffset,
            criticalAlarmOffset: originalReminderOffset,
          );
        } catch (sideEffectError, sideEffectStack) {
          debugPrint(
            'VoiceConversationScreen date side-effect sync failed: $sideEffectError',
          );
          debugPrintStack(stackTrace: sideEffectStack);
          if (mounted) {
            setState(() {
              _messages.add(
                const _ConversationMessage.assistant(
                  '저장은 했지만 알림/위젯 동기화에 일부 실패했어요. 잠시 후 다시 시도해 주세요.',
                ),
              );
            });
          }
        }
      }

      await _loadEvents();
      return true;
    } catch (error, stackTrace) {
      debugPrint('VoiceConversationScreen date auto-save failed: $error');
      debugPrintStack(stackTrace: stackTrace);
      return false;
    }
  }

  Future<bool> _applyConversationEventUpdate(
    VoiceConversationResult result,
  ) async {
    final event = result.targetEvent;
    if (event == null) {
      return false;
    }
    var edited = event;
    final locationText = result.locationText?.trim();
    if (locationText != null && locationText.isNotEmpty) {
      final picked = await widget.locationPicker(
        // ignore: use_build_context_synchronously
        context: context,
        query: locationText,
        locationLookupService: widget.locationLookupService,
        appPermissionService: widget.permissionService,
      );
      if (!mounted || picked == null) {
        return false;
      }
      final resolvedLabel = picked.bestPlaceLabel.trim();
      edited = _copyEventWithLocation(
        edited,
        location: resolvedLabel.isNotEmpty ? resolvedLabel : picked.label,
        locationLat: picked.latitude,
        locationLng: picked.longitude,
      );
    }
    final criticalValue = result.criticalValue;
    if (criticalValue != null) {
      edited = _copyEventWithCritical(edited, isCritical: criticalValue);
    }
    final strongAlarmRequested = RegExp(
      r'강한\\s*(알림|알람)|강한알림|강한알람',
    ).hasMatch(result.inputText);
    if (strongAlarmRequested) {
      edited = edited.copyWith(isCritical: true, useStrongAlarm: true);
      // 음성 명령으로 강한 알람을 켠 경우에도 편집 화면과 같은 권한 요청을
      // 즉시 수행한다. 사용자가 거부하면 저장은 유지하고 OS 설정에서 재허용할 수 있다.
      final permissionService =
          widget.permissionService ?? AppPermissionService();
      await permissionService.requestNotificationPermissions();
      await permissionService.requestExactAlarmPermission();
      await permissionService.requestFullScreenIntentPermission();
    }

    try {
      final saved = await _repository.updateEvent(edited);
      _events = _events
          .map((candidate) => candidate.id == saved.id ? saved : candidate)
          .toList(growable: false);
      _conversation.replaceEvents(_events);
      EventRefreshBus.instance.notifyChanged(
        reason: 'voice_conversation_update',
        eventId: saved.id,
        startAt: saved.startAt,
      );
      await _loadEvents();
      return true;
    } catch (error, stackTrace) {
      debugPrint('VoiceConversationScreen update failed: $error');
      debugPrintStack(stackTrace: stackTrace);
      if (mounted) {
        setState(() {
          _messages.add(
            const _ConversationMessage.assistant(
              '일정 변경 저장에 실패했어요. 잠시 후 다시 시도해 주세요.',
            ),
          );
        });
      }
      return false;
    }
  }

  /// 그룹 일정 대상 음성 수정 라우팅. 개인 [_repository.updateEvent] 대신
  /// [GroupEventRepository.updateGroupEvent]로 저장한다. 그룹 일정
  /// 편집 화면이 따로 없고 개인 전용 event_edit_screen을 재사용할 수 없으므로,
  /// 편집 화면 이동 없이 이 함수에서 바로 저장까지 마친다.
  /// 지원 범위: 제목·장소·시간·주/일/월 반복을 반영한다. 반복은 그룹 스키마가
  /// 요일(BYDAY)을 지원하지 않아 FREQ 단위(daily/weekly/monthly)로 다운그레이드한다.
  Future<bool> _applyGroupEventVoiceUpdate(
    VoiceConversationResult result,
    GroupEventModel groupEvent,
  ) async {
    var updated = groupEvent;
    var changed = false;

    final locationText = result.locationText?.trim();
    if (locationText != null && locationText.isNotEmpty) {
      updated = updated.copyWith(location: locationText);
      changed = true;
    }

    final newTitle = _extractGroupTitleChange(result.inputText);
    if (newTitle != null && newTitle.isNotEmpty && newTitle != updated.title) {
      updated = updated.copyWith(title: newTitle);
      changed = true;
    }

    final draft = result.draftEvent;
    if (draft != null) {
      if (draft.startAt != null) {
        final newStart = draft.startAt!;
        final originalDuration = updated.endAt.difference(updated.startAt);
        final newEnd = draft.endAt ??
            newStart.add(
              originalDuration.isNegative || originalDuration == Duration.zero
                  ? const Duration(hours: 1)
                  : originalDuration,
            );
        updated = updated.copyWith(startAt: newStart, endAt: newEnd);
        changed = true;
      }
      final requestedRule = draft.recurrenceRule?.trim();
      if (requestedRule != null && requestedRule.isNotEmpty) {
        final nextRecurrenceType = _groupRecurrenceTypeFromRule(requestedRule);
        if (nextRecurrenceType != updated.recurrenceType) {
          updated = updated.copyWith(recurrenceType: nextRecurrenceType);
          changed = true;
        }
      }
    }

    if (!changed) {
      if (mounted) {
        setState(() {
          _messages.add(
            const _ConversationMessage.assistant(
              '그룹 일정에는 아직 지원하지 않는 변경이에요. 장소·시간·주/일/월 반복만 바꿀 수 있어요.',
            ),
          );
        });
      }
      return false;
    }

    try {
      final saved = await _groupEventRepository.updateGroupEvent(updated);
      _groupEventById[saved.id] = saved;
      _events = _events
          .map(
            (candidate) => candidate.id == saved.id
                ? _eventModelFromGroupEvent(saved)
                : candidate,
          )
          .toList(growable: false);
      _conversation.replaceEvents(_events);
      EventRefreshBus.instance.notifyChanged(
        reason: 'voice_conversation_group_update',
        eventId: saved.id,
        startAt: saved.startAt,
      );
      await _loadEvents();
      return true;
    } catch (error, stackTrace) {
      debugPrint('VoiceConversationScreen group update failed: $error');
      debugPrintStack(stackTrace: stackTrace);
      if (mounted) {
        setState(() {
          _messages.add(
            const _ConversationMessage.assistant(
              '그룹 일정 변경 저장에 실패했어요. 잠시 후 다시 시도해 주세요.',
            ),
          );
        });
      }
      return false;
    }
  }

  /// 그룹 일정 음성 삭제. 그룹 일정은 하드 삭제 API가 없으므로
  /// [GroupEventRepository.cancelGroupEvent]로 소프트 취소한다.
  Future<bool> _cancelGroupEvent(GroupEventModel groupEvent) async {
    try {
      await _groupEventRepository.cancelGroupEvent(groupEvent.id);
      _groupEventById.remove(groupEvent.id);
      _events = _events
          .where((event) => event.id != groupEvent.id)
          .toList(growable: false);
      _conversation.replaceEvents(_events);
      EventRefreshBus.instance.notifyChanged(
        reason: 'voice_conversation_group_cancel',
        eventId: groupEvent.id,
        startAt: groupEvent.startAt,
      );
      await _loadEvents();
      if (mounted) {
        setState(() {
          _messages.add(
            const _ConversationMessage.assistant(
              '팀 일정을 삭제했어요. 팀원들 화면에서도 사라져요.',
            ),
          );
        });
      }
      return true;
    } catch (error, stackTrace) {
      debugPrint('VoiceConversationScreen group cancel failed: $error');
      debugPrintStack(stackTrace: stackTrace);
      if (mounted) {
        setState(() {
          _messages.add(
            const _ConversationMessage.assistant(
              '이 팀 일정은 만든 사람이나 팀 리더만 삭제할 수 있어요.',
            ),
          );
        });
      }
      return false;
    }
  }

  /// 그룹 일정을 개인 일정으로 옮긴다(취소-우선 + 보상 롤백). 먼저 그룹
  /// 일정을 취소(cancelGroupEvent)하고, 그 다음 개인 일정을 생성한다.
  /// 개인 일정 생성이 실패하면 방금 취소한 그룹 일정을 다시 active로
  /// 되돌려(보상 롤백) 데이터가 양쪽 모두에서 사라지지 않게 한다.
  Future<bool> _convertGroupEventToPersonal(GroupEventModel g) async {
    GroupEventModel cancelled;
    try {
      cancelled = await _groupEventRepository.cancelGroupEvent(g.id);
    } catch (error, stackTrace) {
      debugPrint(
        'VoiceConversationScreen group cancel for convert failed: $error',
      );
      debugPrintStack(stackTrace: stackTrace);
      if (mounted) {
        setState(() {
          _messages.add(
            const _ConversationMessage.assistant(
              '이 팀 일정은 만든 사람이나 팀 리더만 개인 일정으로 옮길 수 있어요.',
            ),
          );
        });
      }
      return false;
    }

    try {
      final userId = authProvider.userId ?? '';
      final draft = _personalEventFromGroupEvent(g, userId);
      await _repository.createEvent(draft);
    } catch (error, stackTrace) {
      debugPrint(
        'VoiceConversationScreen personal create for convert failed: $error',
      );
      debugPrintStack(stackTrace: stackTrace);
      try {
        await _groupEventRepository.updateGroupEvent(
          cancelled.copyWith(
            status: 'active',
            clearCancelledAt: true,
            clearCancelledBy: true,
          ),
        );
      } catch (_) {
        // 복구 실패는 조용히 무시(그룹 일정은 취소 상태로 남되, 개인 일정도
        // 안 생겼으므로 데이터 유실은 아님 — 사용자가 그룹 화면에서 직접
        // 복구해야 함).
      }
      if (mounted) {
        setState(() {
          _messages.add(
            const _ConversationMessage.assistant(
              '개인 일정으로 옮기지 못했어요. 팀 일정은 그대로 두었어요.',
            ),
          );
        });
      }
      return false;
    }

    _groupEventById.remove(g.id);
    _events =
        _events.where((event) => event.id != g.id).toList(growable: false);
    _conversation.replaceEvents(_events);
    EventRefreshBus.instance.notifyChanged(
      reason: 'voice_conversation_group_to_personal',
      eventId: g.id,
      startAt: g.startAt,
    );
    await _loadEvents();
    if (mounted) {
      setState(() {
        _messages.add(
          _ConversationMessage.assistant(_convertSuccessMessage(g)),
        );
      });
    }
    return true;
  }

  Future<void> _stopVoiceBeforeNavigation() async {
    _restartListenTimer?.cancel();
    _conversationWatchdogTimer?.cancel();
    _isRestartPending = false;
    _listenGeneration += 1;
    _didRetryConversationEarlyFailure = false;
    _wasListeningBeforeNavigation = _keepListening || _isListening;
    if (mounted) {
      setState(() {
        _voicePhase = _VoiceConversationPhase.stopping;
        _keepListening = false;
        _voicePausedByUser = false;
        _isListening = false;
      });
    } else {
      _keepListening = false;
      _voicePausedByUser = false;
      _isListening = false;
    }
    try {
      await widget.sttService.cancelActiveListen().timeout(
        const Duration(seconds: 4),
        onTimeout: () {
          debugPrint(
            'VoiceConversationScreen: cancelActiveListen timed out, '
            'continuing navigation anyway.',
          );
        },
      );
    } catch (error) {
      debugPrint(
        'VoiceConversationScreen: cancelActiveListen failed: $error',
      );
    }
  }

  /// [_stopVoiceBeforeNavigation] 이후 다른 화면(편집 등)을 다녀와 이
  /// 대화 화면으로 복귀했을 때, 나가기 전에 듣고 있었다면 마이크를 자동으로
  /// 다시 켠다. 사용자가 직접 정지했거나(_voicePausedByUser) 대화 세션을
  /// 나가는 중이면(_isExitingConversation) 재개하지 않는다.
  void _resumeListeningAfterNavigation() {
    if (!mounted ||
        _voicePausedByUser ||
        _isExitingConversation ||
        !_wasListeningBeforeNavigation ||
        _isListening) {
      return;
    }
    _keepListening = true;
    _scheduleAutoRestartListen();
  }

  Future<bool> _deleteEvent(EventModel event) async {
    try {
      await _repository.deleteEvent(event.id, userId: authProvider.userId);
      _deletedEventIds.add(event.id);
      _setConversationInputText('');
      _restartListenTimer?.cancel();
      _isRestartPending = false;
      _listenGeneration += 1;
      EventRefreshBus.instance.notifyChanged(
        reason: 'voice_conversation_delete',
        eventId: event.id,
        startAt: event.startAt,
      );
      await _loadEvents();
      if (mounted) {
        setState(() {
          _isListening = false;
          _voicePhase = _VoiceConversationPhase.idle;
        });
      } else {
        _isListening = false;
      }
      if (_keepListening && !_voicePausedByUser) {
        _scheduleAutoRestartListen();
      }
      if (!mounted) return true;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('일정을 삭제했어요.')),
      );
      return true;
    } catch (error) {
      debugPrint('VoiceConversationScreen delete failed: $error');
      if (!mounted) return false;
      setState(() {
        _messages.add(
          const _ConversationMessage.assistant(
            '삭제하지 못했어요. 잠시 후 다시 시도해 주세요.',
          ),
        );
      });
      return false;
    }
  }

  /// 반복 일정의 단일 회차만 삭제한다(시리즈는 유지). anchor의
  /// `deletedOccurrenceDates`에 해당 local-day를 추가해 updateEvent로
  /// 저장하며, 이후 후속 처리(목록 갱신/EventRefreshBus/음성 재개 등)는
  /// [_deleteEvent]와 동일하게 진행한다.
  Future<bool> _deleteEventOccurrence(
    EventModel event,
    DateTime occurrenceDate,
  ) async {
    try {
      final anchor = await _repository.fetchEvent(
        event.id,
        userId: authProvider.userId,
      );
      if (anchor == null) {
        // anchor를 못 찾으면 전체 삭제 경로로 폴백하지 않고 실패 처리.
        debugPrint(
          'VoiceConversationScreen occurrence delete: anchor not found',
        );
        if (!mounted) return false;
        setState(() {
          _messages.add(
            const _ConversationMessage.assistant(
              '삭제하지 못했어요. 잠시 후 다시 시도해 주세요.',
            ),
          );
        });
        return false;
      }
      final localDay = DateTime(
        occurrenceDate.year,
        occurrenceDate.month,
        occurrenceDate.day,
      );
      final updated = anchor.copyWith(
        deletedOccurrenceDates: <DateTime>[
          ...(anchor.deletedOccurrenceDates ?? const <DateTime>[]),
          localDay,
        ],
      );
      await _repository.updateEvent(updated);
      _deletedEventIds.add(event.id);
      _setConversationInputText('');
      _restartListenTimer?.cancel();
      _isRestartPending = false;
      _listenGeneration += 1;
      EventRefreshBus.instance.notifyChanged(
        reason: 'voice_conversation_delete',
        eventId: event.id,
        startAt: event.startAt,
      );
      await _loadEvents();
      if (mounted) {
        setState(() {
          _isListening = false;
          _voicePhase = _VoiceConversationPhase.idle;
        });
      } else {
        _isListening = false;
      }
      if (_keepListening && !_voicePausedByUser) {
        _scheduleAutoRestartListen();
      }
      if (!mounted) return true;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '${localDay.month}월 ${localDay.day}일 회차만 삭제했어요.',
          ),
        ),
      );
      return true;
    } catch (error) {
      debugPrint(
        'VoiceConversationScreen occurrence delete failed: $error',
      );
      if (!mounted) return false;
      setState(() {
        _messages.add(
          const _ConversationMessage.assistant(
            '삭제하지 못했어요. 잠시 후 다시 시도해 주세요.',
          ),
        );
      });
      return false;
    }
  }

  Future<void> _confirmPendingDelete(EventModel event) async {
    _conversation.handle('응 삭제해');
    await _deleteEvent(event);
  }

  /// "이 회차만 삭제" 버튼: 반복 일정에서 지정된 회차 하나만 삭제하고
  /// assistant 메시지로 결과를 알린다.
  Future<void> _confirmPendingDeleteOccurrence(
    EventModel event,
    DateTime occurrenceDate,
  ) async {
    final deleted = await _deleteEventOccurrence(event, occurrenceDate);
    if (!deleted || !mounted) return;
    setState(() {
      _messages.add(
        _ConversationMessage.assistant(
          '${occurrenceDate.month}월 ${occurrenceDate.day}일 회차만 삭제했어요.',
        ),
      );
    });
    _scrollToBottom();
  }

  // 이 함수의 유일한 호출자 _showEventActionSheet()는 진입 시 항상
  // _pauseVoiceInput()을 먼저 불러 _voicePausedByUser=true를 세운다.
  // _resumeListeningAfterNavigation()의 가드가 그 플래그를 보고 재개를
  // 걸러내므로, 액션시트를 거쳐 온 편집 경로는 의도적으로 마이크를
  // 자동 재개하지 않는다(사용자가 카드 액션시트를 눌러 명시적으로 음성을
  // 멈춘 흐름이기 때문). 여기 별도 분기를 추가하지 말 것.
  Future<void> _openEditEvent(EventModel event) async {
    await _stopVoiceBeforeNavigation();
    if (!mounted) return;
    // 반복 일정이 아닐 때만 로컬 캐논컬 원본을 회복해 함께 넘긴다(날짜 자동
    // 저장 가드가 반복 일정을 자동 저장하지 않으므로 실패 카드의 드래프트는
    // 개인 단발 일정이다). 반복 일정은 기준 회차 치환이 일어나면 안 되므로
    // 기존처럼 EventModel만 전달한다.
    final rule = event.recurrenceRule?.trim();
    final isRecurring = rule != null && rule.isNotEmpty;
    await context.push(
      '${AppRoutes.eventEdit}/${Uri.encodeComponent(event.id)}',
      extra: isRecurring
          ? event
          : _eventEditRouteExtra(
              draft: event,
              originalEvent: _canonicalOriginalFor(event.id),
            ),
    );
    await _loadEvents();
    _resumeListeningAfterNavigation();
  }

  Future<void> _showEventActionSheet(EventModel event) async {
    await _pauseVoiceInput();
    if (!mounted) return;
    final action = await showModalBottomSheet<_EventCardAction>(
      context: context,
      showDragHandle: true,
      builder: (context) => _EventActionSheet(event: event),
    );
    if (!mounted || action == null || action == _EventCardAction.close) {
      return;
    }
    switch (action) {
      case _EventCardAction.edit:
        await _openEditEvent(event);
      case _EventCardAction.delete:
        await _showDeleteConfirmationSheet(event);
      case _EventCardAction.close:
        break;
    }
  }

  Future<void> _showDeleteConfirmationSheet(EventModel event) async {
    final confirmed = await showModalBottomSheet<bool>(
      context: context,
      showDragHandle: true,
      builder: (context) => _DeleteEventSheet(event: event),
    );
    if (confirmed != true || !mounted) {
      return;
    }
    final deleted = await _deleteEvent(event);
    if (!deleted) {
      return;
    }
    if (!mounted) return;
    setState(() {
      _messages.add(
        _ConversationMessage.assistant('${event.title} 일정을 삭제했어요.'),
      );
    });
    _scrollToBottom();
  }

  String _normalizeSubmitTextForPendingDelete(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty || _conversation.pendingDelete == null) {
      return trimmed;
    }
    final pendingRequest = _conversation.pendingDelete!.requestText;
    final withoutPendingRequest =
        _removeCompactPrefix(trimmed, pendingRequest).trim();
    if (withoutPendingRequest.isNotEmpty &&
        _isDeleteConfirmationPhrase(withoutPendingRequest)) {
      return withoutPendingRequest;
    }
    if (_isDeleteConfirmationPhrase(trimmed)) {
      return trimmed;
    }
    return trimmed;
  }

  String _removeCompactPrefix(String text, String prefix) {
    final compactPrefix = _compact(prefix);
    if (compactPrefix.isEmpty) {
      return text;
    }
    final compact = StringBuffer();
    final sourceIndexes = <int>[];
    for (var index = 0; index < text.length; index += 1) {
      final char = text[index];
      if (char.trim().isEmpty) {
        continue;
      }
      compact.write(char);
      sourceIndexes.add(index);
    }
    final compactText = compact.toString();
    if (!compactText.startsWith(compactPrefix) ||
        sourceIndexes.length < compactPrefix.length) {
      return text;
    }
    final endIndex = sourceIndexes[compactPrefix.length - 1] + 1;
    return text.substring(endIndex);
  }

  bool _isDeleteConfirmationPhrase(String text) {
    final normalized = _compact(text);
    if (normalized.contains('아니') ||
        normalized.contains('취소') ||
        normalized.contains('하지마')) {
      return false;
    }
    final hasDelete = normalized.contains('삭제') ||
        normalized.contains('지워') ||
        normalized.contains('없애');
    final hasConfirm = normalized.contains('응') ||
        normalized.contains('그래') ||
        normalized.contains('확인') ||
        normalized.contains('해줘') ||
        normalized.contains('삭제해') ||
        normalized.contains('지워');
    return hasDelete && hasConfirm;
  }

  String _compact(String text) => text.replaceAll(RegExp(r'\s+'), '');

  Future<void> _handleConversationBack() async {
    if (_isExitingConversation) {
      return;
    }
    final shouldExit = await showModalBottomSheet<bool>(
      context: context,
      showDragHandle: true,
      builder: (context) => const _ExitConversationSheet(),
    );
    if (shouldExit == true) {
      await _exitConversation();
    }
  }

  Future<void> _exitConversation() async {
    if (_isExitingConversation) {
      return;
    }
    _isExitingConversation = true;
    var navigated = false;
    try {
      _voicePhase = _VoiceConversationPhase.exiting;
      await _stopVoiceBeforeNavigation();
      _setConversationInputText('');
      _inputTurnGeneration += 1;
      _conversation.clearSession();
      _isRestartPending = false;
      _manualEditInterruptedListening = false;
      _didRetryConversationEarlyFailure = false;
      if (!mounted) return;
      context.go(AppRoutes.home);
      navigated = true;
    } finally {
      // 실제 이동(context.go)까지 도달하지 못했다면(예외/미완료) 다음
      // 뒤로가기 시도가 다시 가능하도록 플래그를 복구한다. 이동이
      // 성공한 경우 위젯이 곧 dispose되므로 이 복구는 무해하다.
      if (!navigated && mounted) {
        _isExitingConversation = false;
      }
    }
  }

  void _handleInputChanged(String value) {
    if (_isApplyingInputReset || _isApplyingVoiceTranscript) {
      return;
    }
    _inputTurnGeneration += 1;
    _interruptVoiceForManualEntry();
  }

  void _handleInputFocus() {
    _interruptVoiceForManualEntry();
  }

  void _interruptVoiceForManualEntry() {
    if (!_isListening &&
        !_keepListening &&
        !_isRestartPending &&
        !_voiceUnstable) {
      return;
    }
    _restartListenTimer?.cancel();
    _isRestartPending = false;
    _listenGeneration += 1;
    _manualEditInterruptedListening = true;
    unawaited(widget.sttService.stopActiveListen());
    if (mounted) {
      setState(() {
        _voicePhase = _VoiceConversationPhase.submitting;
        _keepListening = false;
        _voicePausedByUser = true;
        _isListening = false;
      });
    } else {
      _keepListening = false;
      _voicePausedByUser = true;
      _isListening = false;
    }
  }

  void _armSubmittedVoiceEchoSuppression(String text) {
    final normalized = SttService.normalizeVoiceTranscript(text).trim();
    if (normalized.isEmpty) {
      return;
    }
    _suppressedVoiceEcho = normalized;
    _suppressedVoiceEchoUntil = DateTime.now().add(const Duration(seconds: 3));
  }

  bool _shouldSuppressSubmittedVoiceEcho(String text) {
    final expected = _suppressedVoiceEcho;
    final until = _suppressedVoiceEchoUntil;
    if (expected == null || until == null) {
      return false;
    }
    if (DateTime.now().isAfter(until)) {
      _suppressedVoiceEcho = null;
      _suppressedVoiceEchoUntil = null;
      return false;
    }
    final normalized = SttService.normalizeVoiceTranscript(text).trim();
    if (normalized.isEmpty) {
      return false;
    }
    // 새 iOS listen 직후 이전 발화가 다시 partial/final로 replay될 수 있다.
    // 동일 문장 또는 그 문장의 progressive partial만 억제한다. 실제 새 발화가
    // 달라지는 순간 suppression을 해제해 연속 대화는 즉시 정상 반영한다.
    final isEcho = normalized == expected ||
        expected.startsWith(normalized) ||
        (normalized.startsWith(expected) &&
            normalized.length <= expected.length + 2);
    if (!isEcho) {
      _suppressedVoiceEcho = null;
      _suppressedVoiceEchoUntil = null;
    }
    return isEcho;
  }

  void _applyVoiceTranscriptToInput(
    String text, {
    required int listenGeneration,
    required int inputGeneration,
  }) {
    if (!mounted ||
        text.isEmpty ||
        listenGeneration != _listenGeneration ||
        inputGeneration != _inputTurnGeneration ||
        _shouldSuppressSubmittedVoiceEcho(text)) {
      return;
    }
    _isApplyingVoiceTranscript = true;
    try {
      _inputController.value = TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
      );
    } finally {
      _isApplyingVoiceTranscript = false;
    }
  }

  void _setConversationInputText(String text) {
    if (!mounted) {
      return;
    }
    final nextText = text;
    _isApplyingInputReset = true;
    try {
      _inputController.value = TextEditingValue(
        text: nextText,
        selection: TextSelection.collapsed(offset: nextText.length),
      );
    } finally {
      _isApplyingInputReset = false;
    }
  }

  String _messageForResult(VoiceConversationResult result) {
    switch (result.action) {
      case VoiceConversationAction.showEvents:
        if (result.isAvailabilityCheck) {
          if (result.visibleEvents.isEmpty) {
            return '해당 날짜는 비어 있어요.';
          }
          return '해당 날짜에는 ${result.visibleEvents.length}개의 일정이 있어요.';
        }
        if (result.visibleEvents.isEmpty) {
          return '해당 날짜의 일정은 없어요.';
        }
        return '일정 ${result.visibleEvents.length}개를 찾았어요. 이어서 “3번째 일정에 장소 추가”, “오후 6시 일정 삭제”처럼 말할 수 있어요.';
      case VoiceConversationAction.openEditScreen:
        final title = result.targetEvent?.title ?? '선택한 일정';
        if (result.draftEvent != null &&
            result.draftEvent!.startAt != null &&
            result.targetEvent?.startAt != result.draftEvent!.startAt) {
          return '$title 일정을 옮겨서 편집 화면을 열게요. 저장은 편집 화면에서 직접 눌러 주세요.';
        }
        final location = result.locationText ?? '장소';
        return '$title 일정의 장소에 $location 입력 화면을 열게요. 저장은 편집 화면에서 직접 눌러 주세요.';
      case VoiceConversationAction.confirmedEdit:
        final title = result.targetEvent?.title ?? '선택한 일정';
        // 음성으로 일간/시간만 옮긴 경우(컨트롤러가 canAutoApplyDateChange를
        // true 로 둔 단독 변경). 컨트롤러가 보낸 안내 메시지가 있으면 그대로
        // 쓴다(예: 'OO 일정을 다음 주로 옮겼어요'). 없으면 안전한 기본
        // 안내를 출력한다.
        if (result.canAutoApplyDateChange) {
          final controllerMessage = result.assistantMessage.trim();
          if (controllerMessage.isNotEmpty) {
            return controllerMessage;
          }
          // 컨트롤러 안내가 비어 있으면 실제 저장된(드래프트 확정) 날짜를
          // 직접 말한다. '편집 화면' 표현은 쓰지 않는다.
          final savedStart =
              result.draftEvent?.startAt ?? result.targetEvent?.startAt;
          if (savedStart != null) {
            final local = planflowLocal(savedStart);
            final hasTime = local.hour != 0 || local.minute != 0;
            final String dateLabel;
            if (hasTime) {
              final hh = local.hour.toString().padLeft(2, '0');
              final mm = local.minute.toString().padLeft(2, '0');
              dateLabel = '${local.month}월 ${local.day}일 $hh:$mm';
            } else {
              dateLabel = '${local.month}월 ${local.day}일';
            }
            final particle = dateLabel.endsWith('일') ? '으로' : '로';
            return '$title 일정을 $dateLabel$particle 옮겼어요.';
          }
          return '$title 일정의 날짜를 옮겼어요.';
        }
        if (result.criticalValue != null) {
          return result.criticalValue!
              ? '$title 일정을 중요한 일정으로 표시했어요.'
              : '$title 일정을 중요한 일정으로 표시하지 않을게요.';
        }
        if (result.locationText != null) {
          return '$title 일정의 장소를 ${result.locationText}로 변경했어요.';
        }
        return '$title 일정을 변경했어요.';
      case VoiceConversationAction.confirmDelete:
        final title = result.targetEvent?.title ?? '선택한 일정';
        return '$title 일정을 삭제할까요? 삭제하려면 아래 삭제 확인 버튼을 눌러 주세요.';
      case VoiceConversationAction.deleteConfirmed:
        return '삭제를 진행했어요.';
      case VoiceConversationAction.deleteCanceled:
        return '삭제를 취소했어요.';
      case VoiceConversationAction.confirmConvertToPersonal:
        final title = result.targetEvent?.title ?? '선택한 일정';
        return '$title 일정을 개인 일정으로 옮길까요? 옮기려면 아래에서 응답해 주세요.';
      case VoiceConversationAction.convertToPersonalConfirmed:
        return '개인 일정으로 옮기는 중이에요.';
      case VoiceConversationAction.createEvent:
        if (result.draftEvent == null) {
          return '일정 정보를 파악하지 못했어요. 날짜와 제목을 포함해서 다시 말해 주세요.';
        }
        return '일정 편집 화면을 열게요. 내용 확인 후 저장해 주세요.';
      case VoiceConversationAction.none:
        if (result.selectedEvents.length > 1) {
          return '${result.selectedEvents.length}개의 일정을 선택했어요. 무엇을 바꿀지 이어서 말해 주세요.';
        }
        if (result.targetEvent != null) {
          return '${result.targetEvent!.title} 일정을 보고 있어요. 무엇을 바꿀지 이어서 말해 주세요.';
        }
        return '일정을 먼저 조회하거나, 몇 번째 일정인지 말해 주세요. 예: 오늘 일정 보여줘.';
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) {
        return;
      }
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) {
          unawaited(_handleConversationBack());
        }
      },
      child: Scaffold(
        resizeToAvoidBottomInset: true,
        appBar: AppBar(
          title: const Text('AI 일정 대화'),
          leading: IconButton(
            tooltip: '뒤로가기',
            icon: const Icon(Icons.arrow_back),
            onPressed: _handleConversationBack,
          ),
          actions: [
            TextButton(
              onPressed: _handleConversationBack,
              style: TextButton.styleFrom(
                foregroundColor: PlanFlowColors.primary,
                textStyle: const TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 15,
                ),
              ),
              child: const Text('종료'),
            ),
          ],
        ),
        body: SafeArea(
          bottom: false,
          child: Column(
            children: [
              if (_isLoading) const LinearProgressIndicator(minHeight: 2),
              Expanded(
                child: Builder(
                  builder: (context) {
                    // 대화 리스트 꼬리에 붙는 상태 버블 순서: 분석중 → 음성상태.
                    final showProcessing = _isSubmitting;
                    final showVoiceStatus = _isListening || _isRestartPending;
                    return ListView.separated(
                      controller: _scrollController,
                      padding:
                          const EdgeInsets.all(AppConstants.defaultPadding),
                      itemBuilder: (context, index) {
                        if (index < _messages.length) {
                          final message = _messages[index];
                          return _MessageBubble(
                            message: message,
                            deletedEventIds: _deletedEventIds,
                            onEventTap: _showEventActionSheet,
                            onConfirmDelete:
                                message.pendingDeleteEvent == null ||
                                        _deletedEventIds.contains(
                                          message.pendingDeleteEvent!.id,
                                        )
                                    ? null
                                    : () => _confirmPendingDelete(
                                          message.pendingDeleteEvent!,
                                        ),
                            onDeleteOccurrence:
                                message.pendingDeleteEvent == null ||
                                        message.deleteOccurrenceDate == null ||
                                        _deletedEventIds.contains(
                                          message.pendingDeleteEvent!.id,
                                        )
                                    ? null
                                    : () => _confirmPendingDeleteOccurrence(
                                          message.pendingDeleteEvent!,
                                          message.deleteOccurrenceDate!,
                                        ),
                          );
                        }
                        final tail = index - _messages.length;
                        if (showProcessing && tail == 0) {
                          return const _ProcessingBubble();
                        }
                        return _VoiceStatusBubble(
                          hasBeenReady: _hasVoiceBeenReadyThisTurn,
                          isUnstable: _voiceUnstable,
                        );
                      },
                      separatorBuilder: (_, __) => const SizedBox(height: 10),
                      itemCount: _messages.length +
                          (showProcessing ? 1 : 0) +
                          (showVoiceStatus ? 1 : 0),
                    );
                  },
                ),
              ),
              SafeArea(
                top: false,
                child: _ConversationInputBar(
                  controller: _inputController,
                  isSubmitting: _isSubmitting,
                  isListening: _isListening,
                  keepListening: _keepListening,
                  voicePausedByUser: _voicePausedByUser,
                  isRestartPending: _isRestartPending,
                  onListen: () =>
                      _startConversationListen(resetRetryPolicy: true),
                  onStopListening: _pauseVoiceInput,
                  onSubmit: () => _submitText(null),
                  onChanged: _handleInputChanged,
                  onInputFocus: _handleInputFocus,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ProcessingBubble extends StatelessWidget {
  const _ProcessingBubble();

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 520),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: PlanFlowColors.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: PlanFlowColors.primaryFaint),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2.4),
            ),
            const SizedBox(width: 10),
            Text(
              'AI 문맥 분석중이에요...',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: PlanFlowColors.primary,
                    fontWeight: FontWeight.w800,
                  ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 대화 리스트 맨 아래에 붙는 음성 인식 상태 버블.
/// 조용한 내부 재연결 시도(수 초마다 반복될 수 있음)는 사용자에게 굳이
/// 알리지 않고 '음성 인식 중'으로 계속 보여준다. 재시도해도 응답이 없는
/// 진짜 연결 문제일 때만 '되고 있지 않다'는 문구로 전환한다.
class _VoiceStatusBubble extends StatelessWidget {
  const _VoiceStatusBubble({
    required this.hasBeenReady,
    required this.isUnstable,
  });

  final bool hasBeenReady;
  final bool isUnstable;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final IconData icon;
    final String label;
    final Color background;
    final Color border;
    final Color iconColor;
    if (isUnstable) {
      icon = Icons.mic_off_outlined;
      label = '현재 음성 인식이 되고 있지 않아요. 정지 후 다시 눌러 주세요.';
      background = colorScheme.errorContainer;
      border = colorScheme.error;
      iconColor = colorScheme.error;
    } else if (hasBeenReady) {
      icon = Icons.hearing;
      label = '음성 인식 중이에요 · 다음 명령을 말해 주세요';
      background = PlanFlowColors.tertiaryAccentFaint;
      border = PlanFlowColors.activeLight;
      iconColor = PlanFlowColors.active;
    } else {
      icon = Icons.mic;
      label = '마이크를 준비하고 있어요...';
      background = PlanFlowColors.tertiaryAccentFaint;
      border = PlanFlowColors.activeLight;
      iconColor = PlanFlowColors.active;
    }
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 520),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: border),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: iconColor, size: 20),
            const SizedBox(width: 10),
            Flexible(
              child: Text(
                label,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: isUnstable
                          ? colorScheme.error
                          : PlanFlowColors.primary,
                      fontWeight: FontWeight.w800,
                    ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ConversationMessage {
  const _ConversationMessage._({
    required this.text,
    required this.isUser,
    this.events = const <EventModel>[],
    this.pendingDeleteEvent,
    this.deleteOccurrenceDate,
  });

  const _ConversationMessage.user(String text)
      : this._(text: text, isUser: true);

  const _ConversationMessage.assistant(
    String text, {
    List<EventModel> events = const <EventModel>[],
    EventModel? pendingDeleteEvent,
    DateTime? deleteOccurrenceDate,
  }) : this._(
          text: text,
          isUser: false,
          events: events,
          pendingDeleteEvent: pendingDeleteEvent,
          deleteOccurrenceDate: deleteOccurrenceDate,
        );

  final String text;
  final bool isUser;
  final List<EventModel> events;
  final EventModel? pendingDeleteEvent;

  /// pendingDelete가 반복 일정일 때 삭제 대상 회차의 local-day
  /// (null이면 버튼이 "전체 삭제" 하나로 폴백).
  final DateTime? deleteOccurrenceDate;
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({
    required this.message,
    required this.deletedEventIds,
    required this.onEventTap,
    this.onConfirmDelete,
    this.onDeleteOccurrence,
  });

  final _ConversationMessage message;
  final Set<String> deletedEventIds;
  final ValueChanged<EventModel> onEventTap;
  final VoidCallback? onConfirmDelete;
  final VoidCallback? onDeleteOccurrence;

  static bool _isRecurringEvent(EventModel event) {
    final rule = event.recurrenceRule;
    return rule != null && rule.trim().isNotEmpty;
  }

  @override
  Widget build(BuildContext context) {
    final alignment =
        message.isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start;
    final bubbleColor =
        message.isUser ? PlanFlowColors.primary : PlanFlowColors.surface;
    final textColor = message.isUser ? Colors.white : PlanFlowColors.primary;
    return Column(
      crossAxisAlignment: alignment,
      children: [
        Container(
          constraints: const BoxConstraints(maxWidth: 520),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: bubbleColor,
            borderRadius: BorderRadius.circular(14),
            border: message.isUser
                ? null
                : Border.all(color: PlanFlowColors.primaryFaint),
          ),
          child: Text(
            message.text,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: textColor,
                  height: 1.35,
                ),
          ),
        ),
        if (message.events
            .where((event) => !deletedEventIds.contains(event.id))
            .isNotEmpty) ...[
          const SizedBox(height: 8),
          ...message.events
              .where((event) => !deletedEventIds.contains(event.id))
              .toList()
              .asMap()
              .entries
              .map(
                (entry) => Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: _ConversationEventCard(
                    index: entry.key + 1,
                    event: entry.value,
                    onTap: () => onEventTap(entry.value),
                  ),
                ),
              ),
        ],
        if (message.pendingDeleteEvent != null && onConfirmDelete != null) ...[
          const SizedBox(height: 8),
          // 반복 일정 + 회차가 확정된 경우에만 "이 회차만 삭제"를 노출한다.
          // 반복 일정이지만 회차 추론 실패(deleteOccurrenceDate == null)면
          // 기존처럼 단일 버튼(전체 삭제)으로 폴백한다.
          if (_isRecurringEvent(message.pendingDeleteEvent!) &&
              message.deleteOccurrenceDate != null &&
              onDeleteOccurrence != null)
            FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.error,
              ),
              onPressed: onDeleteOccurrence,
              icon: const Icon(Icons.delete_outline),
              label: const Text('이 회차만 삭제'),
            ),
          FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: onConfirmDelete,
            icon: const Icon(Icons.delete_sweep_outlined),
            label: Text(
              _isRecurringEvent(message.pendingDeleteEvent!)
                  ? '전체 삭제'
                  : '삭제 확인',
            ),
          ),
        ],
      ],
    );
  }
}

class _ConversationEventCard extends StatelessWidget {
  const _ConversationEventCard({
    required this.index,
    required this.event,
    required this.onTap,
  });

  final int index;
  final EventModel event;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final local = event.startAt == null ? null : planflowLocal(event.startAt!);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              CircleAvatar(
                radius: 15,
                backgroundColor: event.isCritical
                    ? const Color(0xFFFFE3DD)
                    : PlanFlowColors.primaryFaint,
                foregroundColor: event.isCritical
                    ? const Color(0xFFB42318)
                    : PlanFlowColors.primary,
                child: Text('$index'),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      event.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                            color: event.isCritical
                                ? const Color(0xFFB42318)
                                : PlanFlowColors.primary,
                            fontWeight: FontWeight.w800,
                          ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      [
                        if (local != null) _formatLocalTime(local),
                        if ((event.location ?? '').trim().isNotEmpty)
                          event.location!.trim(),
                      ].join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: PlanFlowColors.textSecondary,
                          ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              const Icon(
                Icons.touch_app_outlined,
                color: PlanFlowColors.primaryLight,
                size: 18,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ConversationInputBar extends StatefulWidget {
  const _ConversationInputBar({
    required this.controller,
    required this.isSubmitting,
    required this.isListening,
    required this.keepListening,
    required this.voicePausedByUser,
    required this.isRestartPending,
    required this.onListen,
    required this.onStopListening,
    required this.onSubmit,
    required this.onChanged,
    required this.onInputFocus,
  });

  final TextEditingController controller;
  final bool isSubmitting;
  final bool isListening;
  final bool keepListening;
  final bool voicePausedByUser;
  final bool isRestartPending;
  final VoidCallback onListen;
  final VoidCallback onStopListening;
  final VoidCallback onSubmit;
  final ValueChanged<String> onChanged;
  final VoidCallback onInputFocus;

  @override
  State<_ConversationInputBar> createState() => _ConversationInputBarState();
}

class _ConversationInputBarState extends State<_ConversationInputBar> {
  late final FocusNode _inputFocusNode;
  bool _hasInputFocus = false;

  @override
  void initState() {
    super.initState();
    _inputFocusNode = FocusNode()..addListener(_handleFocusChanged);
  }

  @override
  void dispose() {
    _inputFocusNode
      ..removeListener(_handleFocusChanged)
      ..dispose();
    super.dispose();
  }

  void _handleFocusChanged() {
    if (!mounted || _hasInputFocus == _inputFocusNode.hasFocus) {
      return;
    }
    setState(() => _hasInputFocus = _inputFocusNode.hasFocus);
  }

  void _dismissKeyboard() {
    _inputFocusNode.unfocus();
  }

  void _submitAndDismissKeyboard() {
    _dismissKeyboard();
    widget.onSubmit();
  }

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        color: PlanFlowColors.surface,
        border: Border(top: BorderSide(color: PlanFlowColors.primaryFaint)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _VoiceConversationControl(
              isListening: widget.isListening,
              keepListening: widget.keepListening,
              voicePausedByUser: widget.voicePausedByUser,
              isRestartPending: widget.isRestartPending,
              onListen: widget.onListen,
              onStopListening: widget.onStopListening,
            ),
            const SizedBox(height: 8),
            // 인식된 텍스트는 입력창에 실시간으로 채워지므로 입력창 하나가
            // 곧 미리보기다(별도 미리보기 카드 없음). 여러 줄 문장도 잘 보이도록
            // 줄 수를 넉넉히 두고, 전송 버튼은 입력창 높이에 맞춰 함께 늘어난다.
            // IntrinsicHeight로 Row 높이를 입력창 높이에 묶어 stretch가 작동하게 한다.
            IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    child: TextField(
                      controller: widget.controller,
                      focusNode: _inputFocusNode,
                      minLines: 1,
                      maxLines: 5,
                      style: const TextStyle(fontSize: 17, height: 1.4),
                      textInputAction: TextInputAction.send,
                      decoration: InputDecoration(
                        hintText: '예: 5월 7일 일정 보여줘',
                        suffixIcon: _hasInputFocus
                            ? IconButton(
                                onPressed: _dismissKeyboard,
                                tooltip: '키보드 닫기',
                                icon: Semantics(
                                  label: '키보드 닫기',
                                  button: true,
                                  child: const Icon(Icons.keyboard_hide),
                                ),
                              )
                            : null,
                        filled: widget.isListening,
                        fillColor: widget.isListening
                            ? PlanFlowColors.primaryFaint
                            : null,
                      ),
                      onTap: widget.onInputFocus,
                      onChanged: widget.onChanged,
                      onSubmitted: (_) => _submitAndDismissKeyboard(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed:
                        widget.isSubmitting ? null : _submitAndDismissKeyboard,
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(64, 48),
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                    ),
                    child: const Text('전송'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _VoiceConversationControl extends StatelessWidget {
  const _VoiceConversationControl({
    required this.isListening,
    required this.keepListening,
    required this.voicePausedByUser,
    required this.isRestartPending,
    required this.onListen,
    required this.onStopListening,
  });

  final bool isListening;
  final bool keepListening;
  final bool voicePausedByUser;
  final bool isRestartPending;
  final VoidCallback onListen;
  final VoidCallback onStopListening;

  @override
  Widget build(BuildContext context) {
    final isVoiceActive = isListening ||
        isRestartPending ||
        (keepListening && !voicePausedByUser);
    // 실제 인식 상태(듣는 중/준비 중/재시작)는 대화 영역의 음성 상태 버블이
    // 보여주므로, 여기는 시작/정지 동작 하나만 하는 단일 버튼으로 둔다.
    // (이전엔 상태 아이콘·문구 + 별도 정지 버튼이 버블과 중복 표시됐음.)
    if (isVoiceActive) {
      return SizedBox(
        width: double.infinity,
        child: OutlinedButton.icon(
          onPressed: onStopListening,
          icon: const Icon(Icons.stop_circle_outlined),
          label: const Text('음성 입력 정지'),
          style: OutlinedButton.styleFrom(
            minimumSize: const Size.fromHeight(48),
            foregroundColor: PlanFlowColors.active,
            side: const BorderSide(color: PlanFlowColors.activeLight),
          ),
        ),
      );
    }
    return SizedBox(
      width: double.infinity,
      child: FilledButton.tonalIcon(
        onPressed: onListen,
        icon: const Icon(Icons.mic),
        label: const Text('음성으로 명령하기'),
        style: FilledButton.styleFrom(
          minimumSize: const Size.fromHeight(48),
        ),
      ),
    );
  }
}

enum _EventCardAction { edit, delete, close }

class _EventActionSheet extends StatelessWidget {
  const _EventActionSheet({required this.event});

  final EventModel event;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '이 일정으로 무엇을 할까요?',
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      color: PlanFlowColors.primary,
                      fontWeight: FontWeight.w900,
                    ),
              ),
              const SizedBox(height: 10),
              _EventSheetSummary(event: event),
              const SizedBox(height: 14),
              PlanFlowActionButtons(
                alignment: WrapAlignment.start,
                buttons: [
                  PlanFlowActionButton(
                    label: '수정하기',
                    onPressed: () =>
                        Navigator.of(context).pop(_EventCardAction.edit),
                    type: ActionButtonType.primary,
                  ),
                  PlanFlowActionButton(
                    label: '삭제하기',
                    onPressed: () =>
                        Navigator.of(context).pop(_EventCardAction.delete),
                    type: ActionButtonType.secondary,
                    foregroundColor: Theme.of(context).colorScheme.error,
                    borderColor: Theme.of(context)
                        .colorScheme
                        .error
                        .withValues(alpha: 0.35),
                  ),
                  PlanFlowActionButton(
                    label: '닫기',
                    onPressed: () =>
                        Navigator.of(context).pop(_EventCardAction.close),
                    type: ActionButtonType.secondary,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DeleteEventSheet extends StatelessWidget {
  const _DeleteEventSheet({required this.event});

  final EventModel event;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '이 일정을 삭제할까요?',
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      color: PlanFlowColors.primary,
                      fontWeight: FontWeight.w900,
                    ),
              ),
              const SizedBox(height: 10),
              _EventSheetSummary(event: event),
              const SizedBox(height: 14),
              PlanFlowActionButtons(
                buttons: [
                  PlanFlowActionButton(
                    label: '취소',
                    onPressed: () => Navigator.of(context).pop(false),
                    type: ActionButtonType.secondary,
                    flex: 1,
                  ),
                  PlanFlowActionButton(
                    label: '삭제',
                    onPressed: () => Navigator.of(context).pop(true),
                    type: ActionButtonType.primary,
                    backgroundColor: Theme.of(context).colorScheme.error,
                    flex: 1,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ExitConversationSheet extends StatelessWidget {
  const _ExitConversationSheet();

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'AI 일정 대화 페이지를 나가겠습니까?',
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    color: PlanFlowColors.primary,
                    fontWeight: FontWeight.w900,
                  ),
            ),
            const SizedBox(height: 8),
            Text(
              '나가면 현재 듣기와 이어지는 명령을 모두 종료합니다.',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: PlanFlowColors.textSecondary,
                    height: 1.35,
                  ),
            ),
            const SizedBox(height: 16),
            PlanFlowActionButtons(
              buttons: [
                PlanFlowActionButton(
                  label: '계속 대화하기',
                  onPressed: () => Navigator.of(context).pop(false),
                  type: ActionButtonType.secondary,
                  flex: 1,
                ),
                PlanFlowActionButton(
                  label: '나가기',
                  onPressed: () => Navigator.of(context).pop(true),
                  type: ActionButtonType.primary,
                  flex: 1,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _EventSheetSummary extends StatelessWidget {
  const _EventSheetSummary({required this.event});

  final EventModel event;

  @override
  Widget build(BuildContext context) {
    final local = event.startAt == null ? null : planflowLocal(event.startAt!);
    final location = (event.location ?? '').trim();
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: PlanFlowColors.surfaceFaint,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: PlanFlowColors.primaryFaint),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            event.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  color: PlanFlowColors.primary,
                  fontWeight: FontWeight.w900,
                ),
          ),
          if (local != null || location.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              [
                if (local != null) _formatLocalTime(local),
                if (location.isNotEmpty) location,
              ].join(' · '),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: PlanFlowColors.textSecondary,
                    fontWeight: FontWeight.w700,
                  ),
            ),
          ],
        ],
      ),
    );
  }
}

EventModel _copyEventWithLocation(
  EventModel event, {
  required String location,
  double? locationLat,
  double? locationLng,
}) {
  return EventModel(
    id: event.id,
    userId: event.userId,
    title: event.title,
    startAt: event.startAt,
    endAt: event.endAt,
    location: location,
    locationLat: locationLat,
    locationLng: locationLng,
    memo: event.memo,
    supplies: event.supplies,
    suppliesChecked: event.suppliesChecked,
    participants: event.participants,
    targets: event.targets,
    isCritical: event.isCritical,
    recurrenceRule: event.recurrenceRule,
    isAllDay: event.isAllDay,
    isMultiDay: event.isMultiDay,
    parentEventId: event.parentEventId,
    category: event.category,
    source: event.source,
    externalId: event.externalId,
    externalCalendarId: event.externalCalendarId,
    externalEtag: event.externalEtag,
    externalUpdatedAt: event.externalUpdatedAt,
    lastSyncedAt: event.lastSyncedAt,
    createdAt: event.createdAt,
    updatedAt: event.updatedAt,
  );
}

EventModel _copyEventWithCritical(
  EventModel event, {
  required bool isCritical,
}) {
  return EventModel(
    id: event.id,
    userId: event.userId,
    title: event.title,
    startAt: event.startAt,
    endAt: event.endAt,
    location: event.location,
    locationLat: event.locationLat,
    locationLng: event.locationLng,
    memo: event.memo,
    supplies: event.supplies,
    suppliesChecked: event.suppliesChecked,
    participants: event.participants,
    targets: event.targets,
    isCritical: isCritical,
    recurrenceRule: event.recurrenceRule,
    isAllDay: event.isAllDay,
    isMultiDay: event.isMultiDay,
    parentEventId: event.parentEventId,
    category: event.category,
    source: event.source,
    externalId: event.externalId,
    externalCalendarId: event.externalCalendarId,
    externalEtag: event.externalEtag,
    externalUpdatedAt: event.externalUpdatedAt,
    lastSyncedAt: event.lastSyncedAt,
    createdAt: event.createdAt,
    updatedAt: event.updatedAt,
  );
}

/// 그룹 일정(GroupEventModel)을 음성 대화 컨트롤러가 다루는 개인 EventModel
/// 형태로 변환한다. 원본과 동일한 id를 유지해야 [_groupEventById] 레지스트리로
/// 역참조할 수 있다. GroupEventModel엔 좌표(location_lat/lng)·참석자 등
/// 개인 일정 전용 필드가 없으므로 해당 필드는 비워둔다.
EventModel _eventModelFromGroupEvent(GroupEventModel groupEvent) {
  return EventModel(
    id: groupEvent.id,
    userId: groupEvent.createdBy ?? '',
    title: groupEvent.title,
    startAt: groupEvent.startAt,
    endAt: groupEvent.endAt,
    location: groupEvent.location,
    memo: groupEvent.description,
    isAllDay: groupEvent.allDay,
    recurrenceRule: _recurrenceRuleFromGroupRecurrenceType(
      groupEvent.recurrenceType,
    ),
    category: '기타',
    source: 'group',
    createdAt: groupEvent.createdAt,
    updatedAt: groupEvent.updatedAt,
  );
}

/// 그룹 일정의 recurrenceType(none/daily/weekly/monthly)을 개인 EventModel이
/// 쓰는 RRULE 근사치로 변환한다. 요일(BYDAY) 지정은 그룹 스키마가 지원하지
/// 않으므로 FREQ 단위까지만 표현한다.
String? _recurrenceRuleFromGroupRecurrenceType(String recurrenceType) {
  switch (recurrenceType) {
    case 'daily':
      return 'FREQ=DAILY';
    case 'weekly':
      return 'FREQ=WEEKLY';
    case 'monthly':
      return 'FREQ=MONTHLY';
    default:
      return null;
  }
}

/// 음성 파이프라인이 만든 RRULE(요일 등 세부 포함 가능)을 그룹 일정 스키마가
/// 지원하는 recurrenceType(none/daily/weekly/monthly)으로 다운그레이드한다.
/// 예: "FREQ=WEEKLY;BYDAY=FR" -> "weekly" (요일 정보는 그룹 스키마에 저장할
/// 곳이 없어 버려진다 — 의도된 동작, PlanFlow_CLAUDE 작업 지시 참조).
String _groupRecurrenceTypeFromRule(String rrule) {
  final upper = rrule.toUpperCase();
  if (upper.contains('FREQ=DAILY')) {
    return 'daily';
  }
  if (upper.contains('FREQ=WEEKLY')) {
    return 'weekly';
  }
  if (upper.contains('FREQ=MONTHLY')) {
    return 'monthly';
  }
  return 'none';
}

/// "제목을 '주간 회의'로 바꿔줘", "이름을 팀 워크숍으로 변경해줘"처럼
/// 그룹 일정 제목 변경 발화에서 새 제목만 뽑아낸다. 매치되지 않으면 null.
String? _extractGroupTitleChange(String text) {
  final match = RegExp(
    '(?:제목|이름|명칭)\\s*(?:을|를|은|는)?\\s*[\'"]?(.+?)[\'"]?\\s*(?:으로|로)\\s*(?:변경|바꿔|수정|고쳐)',
  ).firstMatch(text);
  if (match == null) {
    return null;
  }
  final extracted = match.group(1)?.trim();
  if (extracted == null || extracted.isEmpty) {
    return null;
  }
  return extracted;
}

/// 그룹 일정을 개인 일정으로 옮길 때 만들 개인 EventModel 초안.
/// id는 빈 문자열로 두어 [EventRepository.createEvent]가 신규 생성으로
/// 처리하게 한다.
EventModel _personalEventFromGroupEvent(GroupEventModel g, String userId) {
  return EventModel(
    id: '',
    userId: userId,
    title: g.title,
    startAt: g.startAt,
    endAt: g.endAt,
    location: g.location,
    memo: g.description,
    isAllDay: g.allDay,
    recurrenceRule: recurrenceRuleFromGroupRecurrence(
      g.recurrenceType,
      g.startAt,
      g.recurrenceUntil,
    ),
    category: '기타',
    source: 'manual',
    createdAt: DateTime.now().toUtc(),
  );
}

String _convertSuccessMessage(GroupEventModel g) {
  const base = '팀 일정을 개인 일정으로 옮겼어요.';
  if (g.recurrenceType == 'weekly') {
    return '$base 매주 반복은 시작 요일 기준으로 옮겼어요. 여러 요일이었다면 다시 확인해 주세요.';
  }
  return base;
}

String _formatLocalTime(DateTime value) {
  final period = value.hour < 12 ? '오전' : '오후';
  final hour = value.hour % 12 == 0 ? 12 : value.hour % 12;
  final minute =
      value.minute == 0 ? '' : ' ${value.minute.toString().padLeft(2, '0')}분';
  return '${value.month}/${value.day} $period $hour시$minute';
}
