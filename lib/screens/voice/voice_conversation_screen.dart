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
import '../../services/event_refresh_bus.dart';
import '../../services/location_lookup_service.dart';
import '../../services/stt_service.dart';
import '../../services/voice_conversation_controller.dart';

class VoiceConversationScreen extends StatefulWidget {
  const VoiceConversationScreen({
    super.key,
    this.repository,
    this.sttService = const SttService(),
    this.locationLookupService,
    this.autoStart = false,
    this.initialText,
  });

  final EventRepository? repository;
  final SttService sttService;
  final LocationLookupService? locationLookupService;
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
  late final VoiceConversationController _conversation =
      VoiceConversationController(events: const <EventModel>[]);

  List<EventModel> _events = const <EventModel>[];
  final Set<String> _deletedEventIds = <String>{};
  bool _isLoading = true;
  bool _isSubmitting = false;
  bool _isListening = false;
  bool _keepListening = false;
  bool _didSubmitInitialText = false;
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
        unawaited(_listenOnce());
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
  }

  @override
  void dispose() {
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

  Future<void> _submitText([String? overrideText]) async {
    final text = (overrideText ?? _inputController.text).trim();
    if (text.isEmpty || _isSubmitting) {
      debugPrint(
        'VoiceConversationScreen submit ignored: '
        'empty=${text.isEmpty} submitting=$_isSubmitting',
      );
      return;
    }
    _inputController.clear();
    setState(() {
      _isSubmitting = true;
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
        await _deleteEvent(result.targetEvent!);
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
    debugPrint('VoiceConversationScreen STT start');
    setState(() {
      _isListening = true;
      _conversationStatus = '듣고 있어요...';
      _inputController.clear();
    });
    try {
      final result = await widget.sttService.listen(
        onPartialResult: (text) {
          final normalized = SttService.normalizeVoiceTranscript(text);
          debugPrint('VoiceConversationScreen STT partial: $normalized');
          if (!mounted || normalized.isEmpty) {
            return;
          }
          setState(() {
            _inputController.value = TextEditingValue(
              text: normalized,
              selection: TextSelection.collapsed(offset: normalized.length),
            );
            _conversationStatus = '듣고 있어요...';
          });
        },
      );
      if (!mounted) {
        return;
      }
      final finalText = SttService.normalizeVoiceTranscript(result.text ?? '');
      debugPrint(
        'VoiceConversationScreen STT final: '
        'success=${result.isSuccess} hasText=${result.hasText} text=$finalText',
      );
      if (result.isSuccess && finalText.isNotEmpty) {
        _inputController.value = TextEditingValue(
          text: finalText,
          selection: TextSelection.collapsed(offset: finalText.length),
        );
        await _submitText(finalText);
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
      setState(() {
        _conversationStatus = '음성 입력을 시작하지 못했어요.';
        _messages.add(
          const _ConversationMessage.assistant(
            '음성 입력을 시작하지 못했어요. 잠시 후 다시 시도해 주세요.',
          ),
        );
      });
    } finally {
      if (mounted) {
        setState(() => _isListening = false);
      }
    }

    if (_keepListening && mounted) {
      await Future<void>.delayed(const Duration(milliseconds: 700));
      if (_keepListening && mounted) {
        unawaited(_listenOnce());
      }
    }
  }

  Future<void> _openEditWithLocation(
    EventModel event,
    String locationText,
  ) async {
    var edited = _copyEventWithLocation(event, location: locationText);
    try {
      final results = await _locations.search(locationText);
      if (results.isNotEmpty) {
        final picked = results.first;
        edited = _copyEventWithLocation(
          event,
          location: picked.label,
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

  Future<void> _deleteEvent(EventModel event) async {
    await _repository.deleteEvent(event.id, userId: authProvider.userId);
    _deletedEventIds.add(event.id);
    EventRefreshBus.instance.notifyChanged(
      reason: 'voice_conversation_delete',
      eventId: event.id,
      startAt: event.startAt,
    );
    await _loadEvents();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('일정을 삭제했어요.')),
    );
  }

  Future<void> _confirmPendingDelete(EventModel event) async {
    _conversation.handle('응 삭제해');
    await _deleteEvent(event);
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
    return Scaffold(
      appBar: AppBar(
        title: const Text('AI 일정 대화'),
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
          statusText: _conversationStatus,
          onKeepListeningChanged: (value) {
            setState(() => _keepListening = value);
            if (value) {
              unawaited(_listenOnce());
            }
          },
          onListen: _listenOnce,
          onSubmit: _submitText,
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
    this.onConfirmDelete,
  });

  final _ConversationMessage message;
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
        if (message.events.isNotEmpty) ...[
          const SizedBox(height: 8),
          ...message.events.asMap().entries.map(
                (entry) => Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: _ConversationEventCard(
                    index: entry.key + 1,
                    event: entry.value,
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
  });

  final int index;
  final EventModel event;

  @override
  Widget build(BuildContext context) {
    final local = event.startAt == null ? null : planflowLocal(event.startAt!);
    return Card(
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
          ],
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
    required this.statusText,
    required this.onKeepListeningChanged,
    required this.onListen,
    required this.onSubmit,
  });

  final TextEditingController controller;
  final bool isSubmitting;
  final bool isListening;
  final bool keepListening;
  final String? statusText;
  final ValueChanged<bool> onKeepListeningChanged;
  final VoidCallback onListen;
  final VoidCallback onSubmit;

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
            Row(
              children: [
                Switch(
                  value: keepListening,
                  onChanged: onKeepListeningChanged,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '계속 듣기',
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                              color: PlanFlowColors.primary,
                              fontWeight: FontWeight.w800,
                            ),
                      ),
                      Text(
                        '답변 후에도 다음 말을 이어서 받을게요.',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if ((statusText ?? '').trim().isNotEmpty) ...[
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  statusText!.trim(),
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: PlanFlowColors.textSecondary,
                        fontWeight: FontWeight.w700,
                      ),
                ),
              ),
              const SizedBox(height: 8),
            ],
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                IconButton.filledTonal(
                  tooltip: '음성으로 말하기',
                  onPressed: isListening ? null : onListen,
                  icon: Icon(isListening ? Icons.hearing : Icons.mic),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: controller,
                    minLines: 1,
                    maxLines: 3,
                    textInputAction: TextInputAction.send,
                    decoration: const InputDecoration(
                      hintText: '예: 5월 7일 일정 보여줘',
                    ),
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
