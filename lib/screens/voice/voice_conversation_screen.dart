import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/constants.dart';
import '../../core/env.dart';
import '../../core/local_time.dart';
import '../../core/theme.dart';
import '../../data/models/event_model.dart';
import '../../data/repositories/event_repository.dart';
import '../../providers/auth_provider.dart';
import '../../services/app_permission_service.dart';
import '../../services/event_refresh_bus.dart';
import '../../services/location_lookup_service.dart';
import '../../services/remote_config_service.dart';
import '../../services/stt_service.dart';
import '../../services/voice_conversation_controller.dart';

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
    this.sttService = const SttService(),
    this.locationLookupService,
    this.permissionService,
    this.autoStart = false,
    this.initialText,
  });

  final EventRepository? repository;
  final SttService sttService;
  final LocationLookupService? locationLookupService;
  final AppPermissionService? permissionService;
  final bool autoStart;
  final String? initialText;

  @override
  State<VoiceConversationScreen> createState() =>
      _VoiceConversationScreenState();
}

class _VoiceConversationScreenState extends State<VoiceConversationScreen> {
  final TextEditingController _inputController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final List<_ConversationMessage> _messages = <_ConversationMessage>[
    const _ConversationMessage.assistant(
      '일정을 이어서 말해도 돼요. 예: “5월 7일 일정 보여줘” 다음에 “3번째 일정에 장소 추가해줘”, “오후 6시 일정 삭제해줘”처럼요.',
    ),
  ];

  late final EventRepository _repository =
      widget.repository ?? EventRepository.supabase();
  late final LocationLookupService _locations =
      widget.locationLookupService ?? LocationLookupService();
  late final AppPermissionService _permissionService =
      widget.permissionService ?? AppPermissionService();
  late final VoiceConversationController _conversation =
      VoiceConversationController(events: const <EventModel>[]);

  List<EventModel> _events = const <EventModel>[];
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
  // ignore: unused_field
  _VoiceConversationPhase _voicePhase = _VoiceConversationPhase.idle;
  Timer? _restartListenTimer;
  Timer? _conversationWatchdogTimer;
  String? _conversationStatus;

  @override
  void initState() {
    super.initState();
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
      _conversationStatus = '계속 대화를 이어서 할 수 있습니다. 그냥 편하게 말하세요.';
    });
    if (!_isListening && !_isSubmitting) {
      unawaited(_startConversationListen(resetRetryPolicy: true));
    }
  }

  @override
  void dispose() {
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
        _conversationStatus = !AppEnv.isSupabaseReady
            ? 'Supabase 설정을 확인하지 못했어요.'
            : '로그인 상태를 확인하지 못했어요.';
      });
      return;
    }
    setState(() => _isLoading = true);
    try {
      final userId = usesInjectedRepository ? null : authProvider.userId;
      final events = await _repository.listEvents(userId: userId);
      if (!mounted) return;
      debugPrint(
        'VoiceConversationScreen load events success: ${events.length}',
      );
      setState(() {
        _events = events;
        _conversation.replaceEvents(events);
        _isLoading = false;
        _conversationStatus = null;
      });
    } catch (error) {
      debugPrint('VoiceConversationScreen load events failed: $error');
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _conversationStatus = '일정을 불러오지 못했어요.';
        _messages.add(
          _ConversationMessage.assistant(
            '일정을 불러오지 못했어요. Supabase 연결과 로그인 상태를 확인해 주세요.',
          ),
        );
      });
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
        _conversationStatus = '음성 입력을 멈췄어요. 지금 입력한 내용만 저장할게요.';
      });
      unawaited(widget.sttService.stopActiveListen());
    } else if (_keepListening && !fromVoiceFinal) {
      _manualEditInterruptedListening = true;
      setState(() {
        _voicePhase = _VoiceConversationPhase.submitting;
        _keepListening = false;
        _voicePausedByUser = true;
        _conversationStatus = '음성 입력을 멈췄어요. 지금 입력한 내용만 저장할게요.';
      });
      unawaited(widget.sttService.stopActiveListen());
    }
    _setConversationInputText('');
    setState(() {
      _isSubmitting = true;
      _voicePhase = _VoiceConversationPhase.submitting;
      _conversationStatus = 'AI 문맥 분석중이에요...';
      _messages.add(_ConversationMessage.user(text));
    });
    _scrollToBottom();

    try {
      final canLoadEvents = widget.repository != null ||
          (AppEnv.isSupabaseReady && authProvider.isSignedIn);
      if (_events.isEmpty && canLoadEvents) {
        _events = await _repository.listEvents(
          userId: widget.repository == null ? authProvider.userId : null,
        );
      }
      _conversation.replaceEvents(_events);
      final result = _conversation.handle(text);
      debugPrint(
        'VoiceConversationScreen result: '
        'action=${result.action.name} visible=${result.visibleEvents.length}',
      );

      if (result.deleteConfirmed && result.targetEvent != null) {
        final deleted = await _deleteEvent(result.targetEvent!);
        if (!deleted) {
          return;
        }
      } else if (result.requiresEditScreenNavigation &&
          result.targetEvent != null &&
          result.locationText != null) {
        await _openEditWithLocation(result.targetEvent!, result.locationText!);
      }

      if (!mounted) return;
      setState(() {
        _conversationStatus = null;
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
        _conversationStatus = '처리 중 문제가 생겼어요.';
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
    final listenGeneration = ++_listenGeneration;
    final inputGeneration = _inputTurnGeneration;
    var shouldRetryEarlyFailure = false;
    debugPrint('VoiceConversationScreen STT start');
    setState(() {
      _isListening = true;
      _keepListening = true;
      _voicePausedByUser = false;
      _voicePhase = _VoiceConversationPhase.listening;
      _conversationStatus = '듣고 있어요...';
    });
    _setConversationInputText('');
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
          setState(() => _conversationStatus = '듣고 있어요...');
        },
        onRestart: (count) {
          if (!mounted || listenGeneration != _listenGeneration) {
            return;
          }
          debugPrint(
            'VoiceConversationScreen STT restarted: count=$count gen=$listenGeneration',
          );
          setState(() {
            _isRestartPending = true;
            _voicePhase = _VoiceConversationPhase.restartPending;
            _conversationStatus = '음성을 다시 듣고 있어요...';
          });
          _armConversationWatchdog(listenGeneration);
        },
        mode: SttListenMode.conversation,
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
            _conversationStatus = null;
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
            _conversationStatus = null;
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
            _conversationStatus = '음성 입력을 다시 준비하고 있어요...';
          });
        }
      } else if (mounted) {
        final message = result.message ?? '음성을 알아듣지 못했어요. 다시 말해 주세요.';
        setState(() {
          _conversationStatus = message;
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
        _conversationStatus = '음성 입력을 시작하지 못했어요.';
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
    final maxSeconds = RemoteConfigService.maxVoiceDurationSeconds <= 0
        ? 60
        : RemoteConfigService.maxVoiceDurationSeconds;
    _conversationWatchdogTimer = Timer(Duration(seconds: maxSeconds + 5), () {
      if (!mounted ||
          listenGeneration != _listenGeneration ||
          !_isListening ||
          _voicePausedByUser) {
        return;
      }
      debugPrint(
        'VoiceConversationScreen watchdog timeout: gen=$listenGeneration',
      );
      if (mounted && listenGeneration == _listenGeneration) {
        setState(() {
          _isRestartPending = true;
          _voicePhase = _VoiceConversationPhase.restartPending;
          _conversationStatus = '음성이 오래 이어져서 다시 듣는 중이에요...';
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
        _conversationStatus = '음성입력이 중지되었습니다. 다시 음성입력하실 때 마이크 버튼을 눌러 주세요.';
      });
    } else {
      _keepListening = false;
      _voicePausedByUser = true;
      _isListening = false;
    }
    await widget.sttService.stopActiveListen();
  }

  Future<void> _openEditWithLocation(
    EventModel event,
    String locationText,
  ) async {
    await _stopVoiceBeforeNavigation();
    var edited = _copyEventWithLocation(event, location: locationText);
    try {
      final origin = await _permissionService.getCurrentLocationWithPermission(
        requestIfMissing: false,
      );
      final results = await _locations.search(locationText, origin: origin);
      if (results.isNotEmpty) {
        final picked = results.first;
        final resolvedLabel = picked.bestPlaceLabel.trim();
        edited = _copyEventWithLocation(
          event,
          location: resolvedLabel.isNotEmpty ? resolvedLabel : picked.label,
          locationLat: picked.latitude,
          locationLng: picked.longitude,
        );
      }
    } catch (_) {
      edited = _copyEventWithLocation(event, location: locationText);
    }

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
        _conversationStatus = null;
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
        _conversationStatus = '삭제하지 못했어요.';
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
    context.pop(voiceConversationClosedResult);
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
        _conversationStatus = '음성 입력이 중지되었습니다. 다시 음성 입력하실 때 마이크 버튼을 눌러 주세요.';
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
        final location = result.locationText ?? '장소';
        return '$title 일정의 장소에 $location 입력 화면을 열게요. 저장은 편집 화면에서 직접 눌러 주세요.';
      case VoiceConversationAction.confirmDelete:
        final title = result.targetEvent?.title ?? '선택한 일정';
        return '$title 일정을 삭제할까요? 삭제하려면 “응 삭제해”라고 말하거나 삭제 확인을 눌러 주세요.';
      case VoiceConversationAction.deleteConfirmed:
        return '삭제를 진행했어요.';
      case VoiceConversationAction.deleteCanceled:
        return '삭제를 취소했어요.';
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
                child: ListView.separated(
                  controller: _scrollController,
                  padding: const EdgeInsets.all(AppConstants.defaultPadding),
                  itemBuilder: (context, index) {
                    if (index >= _messages.length) {
                      return const _ProcessingBubble();
                    }
                    final message = _messages[index];
                    return _MessageBubble(
                      message: message,
                      deletedEventIds: _deletedEventIds,
                      onEventTap: _showEventActionSheet,
                      onConfirmDelete: message.pendingDeleteEvent == null ||
                              _deletedEventIds
                                  .contains(message.pendingDeleteEvent!.id)
                          ? null
                          : () => _confirmPendingDelete(
                                message.pendingDeleteEvent!,
                              ),
                    );
                  },
                  separatorBuilder: (_, __) => const SizedBox(height: 10),
                  itemCount: _messages.length + (_isSubmitting ? 1 : 0),
                ),
              ),
            ],
          ),
        ),
        bottomNavigationBar: SafeArea(
          top: false,
          child: _ConversationInputBar(
            controller: _inputController,
            isSubmitting: _isSubmitting,
            isListening: _isListening,
            keepListening: _keepListening,
            voicePausedByUser: _voicePausedByUser,
            isRestartPending: _isRestartPending,
            statusText: _conversationStatus,
            onListen: () => _startConversationListen(resetRetryPolicy: true),
            onStopListening: _pauseVoiceInput,
            onSubmit: () => _submitText(null),
            onChanged: _handleInputChanged,
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
                backgroundColor: PlanFlowColors.primaryFaint,
                foregroundColor: PlanFlowColors.primary,
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
                            color: PlanFlowColors.primary,
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
    required this.statusText,
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
  final String? statusText;
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
              statusText: statusText,
              onListen: onListen,
              onStopListening: onStopListening,
            ),
            const SizedBox(height: 8),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: TextField(
                    controller: controller,
                    minLines: 1,
                    maxLines: 3,
                    textInputAction: TextInputAction.send,
                    decoration: const InputDecoration(
                      hintText: '예: 5월 7일 일정 보여줘',
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
    required this.statusText,
    required this.onListen,
    required this.onStopListening,
  });

  final bool isListening;
  final bool keepListening;
  final bool voicePausedByUser;
  final bool isRestartPending;
  final String? statusText;
  final VoidCallback onListen;
  final VoidCallback onStopListening;

  @override
  Widget build(BuildContext context) {
    final isVoiceActive = isListening || isRestartPending;
    final label = isListening
        ? '듣는 중...'
        : isRestartPending
            ? '곧 다시 듣기를 시작해요. 잠시만 기다려 주세요.'
            : (statusText?.trim().isNotEmpty ?? false)
                ? statusText!.trim()
                : '음성입력이 중지되었습니다. 다시 음성입력하실 때 마이크 버튼을 눌러 주세요.';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: isVoiceActive
            ? PlanFlowColors.tertiaryAccentFaint
            : PlanFlowColors.surfaceFaint,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isVoiceActive
              ? PlanFlowColors.activeLight
              : PlanFlowColors.primaryFaint,
        ),
      ),
      child: Row(
        children: [
          if (isListening)
            const Icon(
              Icons.hearing,
              color: PlanFlowColors.active,
              size: 22,
            )
          else if (isRestartPending)
            const Icon(
              Icons.sync,
              color: PlanFlowColors.active,
              size: 22,
            )
          else
            IconButton.filledTonal(
              tooltip: '음성 입력 다시 시작',
              onPressed: onListen,
              icon: const Icon(Icons.mic),
            ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              label,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: PlanFlowColors.primary,
                    fontWeight: FontWeight.w800,
                    height: 1.25,
                  ),
            ),
          ),
          if (isVoiceActive) ...[
            const SizedBox(width: 8),
            OutlinedButton.icon(
              onPressed: onStopListening,
              icon: const Icon(Icons.stop_circle_outlined, size: 18),
              label: const Text('정지'),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size(76, 40),
                padding: const EdgeInsets.symmetric(horizontal: 10),
              ),
            ),
          ],
        ],
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
              FilledButton.icon(
                onPressed: () =>
                    Navigator.of(context).pop(_EventCardAction.edit),
                icon: const Icon(Icons.edit_outlined),
                label: const Text('수정하기'),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: () =>
                    Navigator.of(context).pop(_EventCardAction.delete),
                icon: const Icon(Icons.delete_outline),
                label: const Text('삭제하기'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Theme.of(context).colorScheme.error,
                  side: BorderSide(
                    color: Theme.of(context)
                        .colorScheme
                        .error
                        .withValues(alpha: 0.35),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: () =>
                    Navigator.of(context).pop(_EventCardAction.close),
                child: const Text('닫기'),
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
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.of(context).pop(false),
                      child: const Text('취소'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: () => Navigator.of(context).pop(true),
                      icon: const Icon(Icons.delete_outline),
                      label: const Text('삭제'),
                      style: FilledButton.styleFrom(
                        backgroundColor: Theme.of(context).colorScheme.error,
                      ),
                    ),
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
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.of(context).pop(false),
                    child: const Text('계속 대화하기'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton(
                    onPressed: () => Navigator.of(context).pop(true),
                    child: const Text('나가기'),
                  ),
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

String _formatLocalTime(DateTime value) {
  final period = value.hour < 12 ? '오전' : '오후';
  final hour = value.hour % 12 == 0 ? 12 : value.hour % 12;
  final minute =
      value.minute == 0 ? '' : ' ${value.minute.toString().padLeft(2, '0')}분';
  return '${value.month}/${value.day} $period $hour시$minute';
}
