import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/constants.dart';
import '../../core/env.dart';
import '../../core/local_time.dart';
import '../../core/theme.dart';
import '../../data/models/event_model.dart';
import '../../data/repositories/event_repository.dart';
import '../../features/groups/models/group_event_model.dart';
import '../../features/groups/repositories/group_event_repository.dart';
import '../../features/groups/repositories/group_repository.dart';
import '../../providers/auth_provider.dart';
import '../../services/app_permission_service.dart';
import '../../services/event_refresh_bus.dart';
import '../../services/gpt_service.dart';
import '../../services/location_lookup_service.dart';
import '../../services/stt_service.dart';
import '../../services/voice_conversation_controller.dart';
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
    this.locationPicker = pickLocationFromQuery,
    this.autoStart = false,
    this.initialText,
  });

  final EventRepository? repository;
  final GroupRepository? groupRepository;
  final GroupEventRepository? groupEventRepository;
  final SttService sttService;
  final LocationLookupService? locationLookupService;
  final AppPermissionService? permissionService;
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

  @override
  State<VoiceConversationScreen> createState() =>
      _VoiceConversationScreenState();
}

class _VoiceConversationScreenState extends State<VoiceConversationScreen>
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

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_loadEvents().then((_) => _submitInitialTextIfNeeded()));
    if (widget.autoStart && (widget.initialText ?? '').trim().isEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _isListening) {
          return;
        }
        setState(() => _keepListening = true);
        unawaited(_startConversationListen(resetRetryPolicy: true));
      });
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
  }) async {
    final rawText = (overrideText ?? _inputController.text).trim();
    final text = _normalizeSubmitTextForPendingDelete(rawText);
    if (text.isEmpty || _isSubmitting) {
      debugPrint(
        'VoiceConversationScreen submit ignored: '
        'empty=${text.isEmpty} submitting=$_isSubmitting',
      );
      return;
    }
    _restartListenTimer?.cancel();
    _conversationWatchdogTimer?.cancel();
    _isRestartPending = false;
    _inputTurnGeneration += 1;
    if (!fromVoiceFinal) {
      _listenGeneration += 1;
    }
    if (_isListening && !fromVoiceFinal) {
      _manualEditInterruptedListening = true;
      setState(() {
        _voicePhase = _VoiceConversationPhase.submitting;
        _isListening = false;
        _keepListening = false;
        _voicePausedByUser = true;
      });
      unawaited(widget.sttService.stopActiveListen());
    } else if (_keepListening && !fromVoiceFinal) {
      _manualEditInterruptedListening = true;
      setState(() {
        _voicePhase = _VoiceConversationPhase.submitting;
        _keepListening = false;
        _voicePausedByUser = true;
      });
      unawaited(widget.sttService.stopActiveListen());
    }
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
      // 라우팅한다. 삭제는 이번 범위 밖이라 안내만 하고 개인 삭제로
      // 넘어가지 않게 막는다.
      final targetGroupEvent = result.targetEvent == null
          ? null
          : _groupEventById[result.targetEvent!.id];

      if (result.deleteConfirmed && result.targetEvent != null) {
        if (targetGroupEvent != null) {
          if (mounted) {
            setState(() {
              _messages.add(
                const _ConversationMessage.assistant(
                  '그룹 일정은 아직 음성으로 삭제할 수 없어요. 그룹 화면에서 삭제해 주세요.',
                ),
              );
            });
          }
          return;
        }
        final deleted = await _deleteEvent(result.targetEvent!);
        if (!deleted) {
          return;
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
        final updated = await _applyConversationEventUpdate(result);
        if (!updated) {
          return;
        }
      } else if (result.action == VoiceConversationAction.createEvent &&
          result.draftEvent != null) {
        await _openCreateEventScreen(result.inputText, result.draftEvent);
      } else if (result.requiresEditScreenNavigation &&
          result.targetEvent != null &&
          result.locationText != null) {
        final validatedLocation = await GptService().validateLocation(result.locationText!);
        if (validatedLocation != null) {
          await _openEditWithLocation(result.targetEvent!, validatedLocation);
        } else {
          await _openGeneralEditScreen(result.targetEvent!);
        }
      } else if (result.requiresEditScreenNavigation &&
          result.targetEvent != null &&
          result.locationText == null) {
        // location 변경 외 수정(날짜·시간 이동 등): 일반 편집 화면으로 이동
        await _openGeneralEditScreen(result.draftEvent ?? result.targetEvent!);
      }

      if (!mounted) return;
      setState(() {
        _messages.add(
          _ConversationMessage.assistant(
            _messageForResult(result),
            events: result.visibleEvents,
            pendingDeleteEvent:
                result.requiresDeleteConfirmation ? result.targetEvent : null,
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
      if (result.isSuccess && submitText.isNotEmpty) {
        if (mounted && listenGeneration == _listenGeneration) {
          setState(() {
            _isListening = false;
            _voicePhase = _VoiceConversationPhase.finalizing;
          });
        }
        _applyVoiceTranscriptToInput(
          submitText,
          listenGeneration: listenGeneration,
          inputGeneration: inputGeneration,
        );
        await _submitText(submitText, fromVoiceFinal: true);
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
  }

  /// 날짜·시간 이동 등 일반 수정: 편집 화면으로 바로 이동해 GPT 파이프라인이 처리한다.
  Future<void> _openGeneralEditScreen(EventModel event) async {
    await _stopVoiceBeforeNavigation();
    if (!mounted) return;
    await context.push('${AppRoutes.eventEdit}/${event.id}', extra: event);
    await _loadEvents();
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
  /// 지원 범위: 제목은 변경하지 않음(음성 흐름에 제목 변경 의도가 없음),
  /// 장소·시간·주/일/월 반복만 반영한다. 반복은 그룹 스키마가 요일(BYDAY)을
  /// 지원하지 않아 FREQ 단위(daily/weekly/monthly)로 다운그레이드한다.
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

    final draft = result.draftEvent;
    if (draft != null) {
      if (draft.startAt != null) {
        final newStart = draft.startAt!;
        final originalDuration = updated.endAt.difference(updated.startAt);
        final newEnd = draft.endAt ??
            newStart.add(
              originalDuration.isNegative ||
                      originalDuration == Duration.zero
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

  Future<void> _stopVoiceBeforeNavigation() async {
    _restartListenTimer?.cancel();
    _conversationWatchdogTimer?.cancel();
    _isRestartPending = false;
    _listenGeneration += 1;
    _didRetryConversationEarlyFailure = false;
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
    await widget.sttService.cancelActiveListen();
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

  Future<void> _confirmPendingDelete(EventModel event) async {
    _conversation.handle('응 삭제해');
    await _deleteEvent(event);
  }

  Future<void> _openEditEvent(EventModel event) async {
    await _stopVoiceBeforeNavigation();
    if (!mounted) return;
    await context.push(
      '${AppRoutes.eventEdit}/${Uri.encodeComponent(event.id)}',
      extra: event,
    );
    await _loadEvents();
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
  }

  void _handleInputChanged(String value) {
    if (_isApplyingInputReset || _isApplyingVoiceTranscript) {
      return;
    }
    _inputTurnGeneration += 1;
    if (!_isListening && !_keepListening && !_isRestartPending) {
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

  void _applyVoiceTranscriptToInput(
    String text, {
    required int listenGeneration,
    required int inputGeneration,
  }) {
    if (!mounted ||
        text.isEmpty ||
        listenGeneration != _listenGeneration ||
        inputGeneration != _inputTurnGeneration) {
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
      case VoiceConversationAction.createEvent:
        if (result.draftEvent == null) return '일정 정보를 파악하지 못했어요. 날짜와 제목을 포함해서 다시 말해 주세요.';
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
            IconButton(
              tooltip: '일정 새로고침',
              onPressed: _isLoading ? null : _loadEvents,
              icon: const Icon(Icons.refresh),
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
                  onListen: () => _startConversationListen(resetRetryPolicy: true),
                  onStopListening: _pauseVoiceInput,
                  onSubmit: () => _submitText(null),
                  onChanged: _handleInputChanged,
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
                      color: isUnstable ? colorScheme.error : PlanFlowColors.primary,
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
  });

  const _ConversationMessage.user(String text)
      : this._(text: text, isUser: true);

  const _ConversationMessage.assistant(
    String text, {
    List<EventModel> events = const <EventModel>[],
    EventModel? pendingDeleteEvent,
  }) : this._(
          text: text,
          isUser: false,
          events: events,
          pendingDeleteEvent: pendingDeleteEvent,
        );

  final String text;
  final bool isUser;
  final List<EventModel> events;
  final EventModel? pendingDeleteEvent;
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({
    required this.message,
    required this.deletedEventIds,
    required this.onEventTap,
    this.onConfirmDelete,
  });

  final _ConversationMessage message;
  final Set<String> deletedEventIds;
  final ValueChanged<EventModel> onEventTap;
  final VoidCallback? onConfirmDelete;

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
          FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: onConfirmDelete,
            icon: const Icon(Icons.delete_outline),
            label: const Text('삭제 확인'),
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

class _ConversationInputBar extends StatelessWidget {
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
              isListening: isListening,
              keepListening: keepListening,
              voicePausedByUser: voicePausedByUser,
              isRestartPending: isRestartPending,
              onListen: onListen,
              onStopListening: onStopListening,
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
                      controller: controller,
                      minLines: 1,
                      maxLines: 5,
                      style: const TextStyle(fontSize: 17, height: 1.4),
                      textInputAction: TextInputAction.send,
                      decoration: InputDecoration(
                        hintText: '예: 5월 7일 일정 보여줘',
                        filled: isListening,
                        fillColor:
                            isListening ? PlanFlowColors.primaryFaint : null,
                      ),
                      onChanged: onChanged,
                      onSubmitted: (_) => onSubmit(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: isSubmitting ? null : onSubmit,
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
    final isVoiceActive = isListening || isRestartPending;
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
    userId: groupEvent.createdBy,
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

String _formatLocalTime(DateTime value) {
  final period = value.hour < 12 ? '오전' : '오후';
  final hour = value.hour % 12 == 0 ? 12 : value.hour % 12;
  final minute =
      value.minute == 0 ? '' : ' ${value.minute.toString().padLeft(2, '0')}분';
  return '${value.month}/${value.day} $period $hour시$minute';
}
