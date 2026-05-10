import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/constants.dart';
import '../../core/env.dart';
import '../../core/responsive.dart';
import '../../core/theme.dart';
import '../../data/repositories/settings_repository.dart';
import '../../core/analytics_service.dart';
import '../../services/gpt_service.dart';
import '../../services/stt_service.dart';

class VoiceInputScreen extends StatefulWidget {
  const VoiceInputScreen({
    super.key,
    this.sttService = const SttService(),
    this.autoStartOverride,
    this.settingsRepository,
  });

  final SttService sttService;
  final bool? autoStartOverride;
  final SettingsRepository? settingsRepository;

  @override
  State<VoiceInputScreen> createState() => _VoiceInputScreenState();
}

class _VoiceInputScreenState extends State<VoiceInputScreen> {
  final TextEditingController _rawTextController = TextEditingController();
  final FocusNode _rawTextFocusNode = FocusNode();
  final ScrollController _scrollController = ScrollController();

  bool _isListening = false;
  String? _recognizedText;
  String? _statusMessage;
  int _sttRestartCount = 0;
  bool _didResolveAutoStart = false;

  @override
  void initState() {
    super.initState();
    _rawTextController.addListener(_handleRawTextChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _maybeAutoStartVoiceInput();
    });
  }

  @override
  void dispose() {
    _rawTextController.removeListener(_handleRawTextChanged);
    _rawTextController.dispose();
    _rawTextFocusNode.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _handleRawTextChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _maybeAutoStartVoiceInput() async {
    if (!mounted || _didResolveAutoStart) {
      return;
    }
    _didResolveAutoStart = true;

    final shouldAutoStart = widget.autoStartOverride ??
        await _resolveAutoStartSetting(defaultValue: false);
    if (!mounted || !shouldAutoStart || _rawTextController.text.isNotEmpty) {
      return;
    }

    await _startVoiceFlow();
  }

  Future<bool> _resolveAutoStartSetting({required bool defaultValue}) async {
    if (!AppEnv.isSupabaseReady) {
      return defaultValue;
    }
    final userId = Supabase.instance.client.auth.currentUser?.id;
    if (userId == null || userId.trim().isEmpty) {
      return defaultValue;
    }

    try {
      final repository =
          widget.settingsRepository ?? SettingsRepository.supabase();
      final settings = await repository.fetchSettings(userId);
      return settings?.voiceAutoStart ?? defaultValue;
    } catch (error, stackTrace) {
      debugPrint('Voice auto-start setting lookup failed: $error');
      debugPrintStack(stackTrace: stackTrace);
      return defaultValue;
    }
  }

  Future<void> _startVoiceFlow() async {
    if (_isListening) {
      return;
    }

    unawaited(AnalyticsService.logVoiceInputStarted());

    setState(() {
      _isListening = true;
      _recognizedText = null;
      _sttRestartCount = 0;
      _statusMessage = null;
    });

    try {
      final result = await widget.sttService.listen(
        onPartialResult: _setTranscriptText,
        onRestart: (count) {
          if (!mounted) {
            return;
          }
          setState(() {
            _sttRestartCount = count;
            _statusMessage = '음성 인식이 자동으로 이어졌어요. 완료를 누를 때까지 계속 말해 주세요.';
          });
        },
      );
      if (!mounted) {
        return;
      }

      if (result.hasText) {
        _setTranscriptText(result.text ?? '');
      }

      if (result.isSuccess) {
        unawaited(AnalyticsService.logVoiceInputCompleted(
          textLength: (result.text ?? '').trim().length,
        ));
        await _continueWithRawText();
        return;
      }

      unawaited(AnalyticsService.logVoiceInputFailed(reason: 'stt_no_result'));
      setState(() {
        _statusMessage =
            result.message ?? '음성 인식 결과를 확인하지 못했어요. 직접 입력으로 이어가 주세요.';
      });
      _focusManualInput();
    } catch (_) {
      if (!mounted) {
        return;
      }
      unawaited(AnalyticsService.logVoiceInputFailed(reason: 'stt_exception'));
      setState(() {
        _statusMessage = '음성 인식을 처리하지 못했어요. 직접 입력으로 이어가 주세요.';
      });
      _focusManualInput();
    } finally {
      if (mounted) {
        setState(() {
          _isListening = false;
        });
      }
    }
  }

  Future<void> _finishVoiceFlow() async {
    if (_isListening) {
      await widget.sttService.stopActiveListen();
    }
  }

  Future<void> _cancelVoiceFlow() async {
    if (!_isListening) {
      return;
    }
    await widget.sttService.cancelActiveListen();
    if (!mounted) {
      return;
    }
    setState(() {
      _isListening = false;
      _statusMessage = '음성 입력을 취소했어요. 다시 시작할 수 있습니다.';
    });
  }

  Future<void> _undoLastSegment() async {
    final nextText = _isListening
        ? await widget.sttService.undoLastSpeechSegment()
        : _removeLastWord(_rawTextController.text);
    _setTranscriptText(nextText);
    if (!mounted) {
      return;
    }
    setState(() {
      _statusMessage =
          nextText.trim().isEmpty ? '입력 내용을 비웠어요.' : '마지막 단어를 지웠어요.';
    });
  }

  Future<void> _clearTranscript() async {
    if (_isListening) {
      await widget.sttService.clearActiveTranscript();
    }
    _setTranscriptText('');
    if (!mounted) {
      return;
    }
    setState(() {
      _statusMessage = '전체 입력을 지웠어요. 다시 말하거나 직접 입력해 주세요.';
    });
  }

  Future<void> _continueWithRawText() async {
    final rawText =
        SttService.normalizeVoiceTranscript(_rawTextController.text.trim());
    if (rawText.isEmpty) {
      context.push(AppRoutes.confirm, extra: const <String, dynamic>{});
      return;
    }

    final commandAction = _detectCommandAction(rawText);
    if (commandAction == _VoiceCommandAction.add) {
      final inferredStartAt = GptService().inferStartAtFromRawText(rawText);
      context.push(
        AppRoutes.confirm,
        extra: <String, dynamic>{
          'raw_text': rawText,
          'memo': rawText,
          if (inferredStartAt != null)
            'start_at': inferredStartAt.toIso8601String(),
          'parse_pending': true,
        },
      );
      return;
    }
    context.push(
      AppRoutes.voiceAction,
      extra: <String, dynamic>{
        'raw_text': rawText,
        'action': commandAction.name,
      },
    );
  }

  _VoiceCommandAction _detectCommandAction(String text) {
    final normalized = text.replaceAll(RegExp(r'\s+'), ' ');
    if (RegExp(r'(일정\s*관리|관리해|무엇을\s*할|뭘\s*할|어떻게\s*할|선택)')
        .hasMatch(normalized)) {
      return _VoiceCommandAction.choose;
    }
    if (RegExp(r'(삭제|지워|없애)').hasMatch(normalized)) {
      return _VoiceCommandAction.delete;
    }
    if (RegExp(r'(수정|바꿔|고쳐|변경)').hasMatch(normalized)) {
      return _VoiceCommandAction.edit;
    }
    if (RegExp(r'(조회|알려|보여|뭐야|몇 시|일정 있어|일정있어)').hasMatch(normalized)) {
      return _VoiceCommandAction.query;
    }
    if (RegExp(r'(추가|등록|만들|넣어|예약|기록)').hasMatch(normalized)) {
      return _VoiceCommandAction.add;
    }
    return _VoiceCommandAction.add;
  }

  void _setTranscriptText(String text) {
    if (!mounted) {
      return;
    }
    final nextText = text.trim();
    setState(() {
      _recognizedText = nextText.isEmpty ? null : nextText;
      _rawTextController.value = TextEditingValue(
        text: nextText,
        selection: TextSelection.collapsed(offset: nextText.length),
      );
    });
  }

  String _removeLastWord(String text) {
    final words = text.trim().split(RegExp(r'\s+'));
    if (words.isEmpty || words.first.isEmpty) {
      return '';
    }
    words.removeLast();
    return words.join(' ');
  }

  void _focusManualInput() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      _rawTextFocusNode.requestFocus();
      if (!_scrollController.hasClients) {
        return;
      }
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOutCubic,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('음성 입력')),
      bottomNavigationBar: _VoiceBottomNavigation(
        onHome: () => context.go(AppRoutes.home),
        onCalendar: () => context.go(AppRoutes.calendar),
        onSettings: () => context.go(AppRoutes.settings),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(AppConstants.defaultPadding),
          child: ResponsiveContent(
            maxWidth: 760,
            child: ListView(
              controller: _scrollController,
              children: [
              Text(
                '말한 내용을 먼저 확인하고, 필요하면 직접 고친 뒤 진행할 수 있어요.',
                style: theme.textTheme.titleMedium?.copyWith(
                  color: PlanFlowColors.primary,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '시작 방식은 설정에서 바꿀 수 있어요. 기본은 버튼을 눌러 말하기이고, 원하면 화면을 열자마자 바로 듣게 할 수 있습니다.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: PlanFlowColors.textSecondary,
                  height: 1.35,
                ),
              ),
              const SizedBox(height: AppConstants.sectionSpacing),
              _VoiceCommandGuide(theme: theme),
              const SizedBox(height: 12),
              _ListeningGuide(
                isListening: _isListening,
                restartCount: _sttRestartCount,
              ),
              const SizedBox(height: 16),
              _VoiceTranscriptSection(
                isListening: _isListening,
                recognizedText: _recognizedText,
                controller: _rawTextController,
                focusNode: _rawTextFocusNode,
                onManualSubmit: _continueWithRawText,
                onTapStart: _startVoiceFlow,
                onTapFinish: _finishVoiceFlow,
              ),
              const SizedBox(height: 12),
              _VoiceActionButtons(
                isListening: _isListening,
                hasText: _rawTextController.text.trim().isNotEmpty,
                onCancel: _cancelVoiceFlow,
                onUndo: _undoLastSegment,
                onClear: _clearTranscript,
                onManualSubmit: _continueWithRawText,
              ),
              const SizedBox(height: 12),
              if (_statusMessage != null)
                _StatusBanner(message: _statusMessage!),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

enum _VoiceCommandAction { add, edit, delete, query, choose }

class _VoiceCommandGuide extends StatelessWidget {
  const _VoiceCommandGuide({required this.theme});

  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    const bullets = <String>[
      '일반 일정: “내일 오전 10시 정장집 방문”처럼 말해보세요.',
      '종일/연속: “5월 10일 하루종일 휴가”, “5월 1일부터 3일까지 제주 여행”도 알아듣습니다.',
      '반복 일정: “매주 화요일 팀 미팅”, “격주 금요일 영업 미팅”처럼 말할 수 있어요.',
      '카테고리: 병원 진료는 건강, 세미나 참석은 교육으로 자동 분류돼요.',
      '“오늘 일정 알려줘”라고 말하면 오늘 일정을 시간순으로 정리해 보여줍니다.',
      '“내일 일정 보여줘”, “이번 주 일정 알려줘”처럼 조회할 수 있어요.',
      '잘못 말했으면 “아니”라고 말한 뒤 새 표현을 말하세요.',
      '“마지막 거 지워”라고 말하면 마지막 말 조각을 지웁니다.',
      '“다시”라고 말하면 전체 입력을 비웁니다.',
      '“취소”라고 말하면 음성 입력을 취소합니다.',
    ];

    return Card(
      elevation: 0,
      color: const Color(0xFFEAF4FF),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: const BorderSide(color: Color(0xFF92BEE8), width: 0.8),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '이렇게 말해보세요',
              style: theme.textTheme.titleSmall?.copyWith(
                color: PlanFlowColors.primary,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 8),
            ...bullets.map(
              (line) => Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(
                  '• $line',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: PlanFlowColors.textSecondary,
                    height: 1.35,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '시간, 장소, 반복 표현을 같이 말하면 더 정확해요. 인식 후 일정 확인 화면에서 날짜, 유형, 카테고리를 수정할 수 있습니다.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: PlanFlowColors.primary,
                height: 1.35,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ListeningGuide extends StatelessWidget {
  const _ListeningGuide({
    required this.isListening,
    required this.restartCount,
  });

  final bool isListening;
  final int restartCount;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      elevation: 0,
      color: PlanFlowColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: const BorderSide(color: PlanFlowColors.primaryFaint, width: 0.5),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Text(
          isListening
              ? restartCount == 0
                  ? '온디바이스 음성으로 듣는 중입니다. 완료를 누를 때까지 계속 이어서 말할 수 있어요.'
                  : '음성 인식이 $restartCount번 이어졌어요. 이전 말은 유지됩니다.'
              : '아래 버튼을 눌러 음성으로 말하거나, 직접 입력해 주세요.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: PlanFlowColors.textSecondary,
          ),
        ),
      ),
    );
  }
}

class _VoiceTranscriptSection extends StatelessWidget {
  const _VoiceTranscriptSection({
    required this.isListening,
    required this.recognizedText,
    required this.controller,
    required this.focusNode,
    required this.onManualSubmit,
    required this.onTapStart,
    required this.onTapFinish,
  });

  final bool isListening;
  final String? recognizedText;
  final TextEditingController controller;
  final FocusNode focusNode;
  final VoidCallback onManualSubmit;
  final VoidCallback onTapStart;
  final VoidCallback onTapFinish;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      elevation: 0,
      color: PlanFlowColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: const BorderSide(color: PlanFlowColors.primaryFaint, width: 0.5),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '음성 원문 / 직접 입력',
              style: theme.textTheme.titleSmall?.copyWith(
                color: PlanFlowColors.primary,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: controller,
              focusNode: focusNode,
              maxLines: 5,
              minLines: 2,
              decoration: const InputDecoration(hintText: '입력해주세요'),
              onSubmitted: (_) => onManualSubmit(),
            ),
            if (recognizedText != null) ...[
              const SizedBox(height: 8),
              Text(
                isListening ? '계속 듣는 중입니다.' : '인식된 내용을 확인해 주세요.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: PlanFlowColors.textSecondary,
                ),
              ),
            ],
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: isListening ? onTapFinish : onTapStart,
                icon: Icon(isListening ? Icons.check : Icons.mic),
                label: Text(isListening ? '완료' : '음성으로 일정 입력하기'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _VoiceActionButtons extends StatelessWidget {
  const _VoiceActionButtons({
    required this.isListening,
    required this.hasText,
    required this.onCancel,
    required this.onUndo,
    required this.onClear,
    required this.onManualSubmit,
  });

  final bool isListening;
  final bool hasText;
  final VoidCallback onCancel;
  final VoidCallback onUndo;
  final VoidCallback onClear;
  final VoidCallback onManualSubmit;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: OutlinedButton(
            onPressed: hasText ? onClear : null,
            child: const Text('전체 지우기', textAlign: TextAlign.center),
          ),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: OutlinedButton(
            onPressed: hasText ? onUndo : null,
            child: const Text('마지막 단어 삭제', textAlign: TextAlign.center),
          ),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: OutlinedButton(
            onPressed: hasText ? onManualSubmit : null,
            child: const Text('직접 입력', textAlign: TextAlign.center),
          ),
        ),
        if (isListening) ...[
          const SizedBox(width: 6),
          IconButton.outlined(
            tooltip: '음성 입력 취소',
            onPressed: onCancel,
            icon: const Icon(Icons.close),
          ),
        ],
      ],
    );
  }
}

class _StatusBanner extends StatelessWidget {
  const _StatusBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: PlanFlowColors.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: PlanFlowColors.primaryFaint, width: 0.5),
      ),
      child: Text(
        message,
        style: theme.textTheme.bodyMedium?.copyWith(
          color: PlanFlowColors.textSecondary,
        ),
      ),
    );
  }
}

class _VoiceBottomNavigation extends StatelessWidget {
  const _VoiceBottomNavigation({
    required this.onHome,
    required this.onCalendar,
    required this.onSettings,
  });

  final VoidCallback onHome;
  final VoidCallback onCalendar;
  final VoidCallback onSettings;

  @override
  Widget build(BuildContext context) {
    return NavigationBar(
      selectedIndex: 0,
      onDestinationSelected: (index) {
        switch (index) {
          case 0:
            onHome();
            break;
          case 1:
            onCalendar();
            break;
          case 2:
            onSettings();
            break;
        }
      },
      destinations: const [
        NavigationDestination(
          icon: Icon(Icons.home_outlined),
          selectedIcon: Icon(Icons.home),
          label: '홈',
        ),
        NavigationDestination(
          icon: Icon(Icons.calendar_month_outlined),
          selectedIcon: Icon(Icons.calendar_month),
          label: '일정',
        ),
        NavigationDestination(
          icon: Icon(Icons.settings_outlined),
          selectedIcon: Icon(Icons.settings),
          label: '설정',
        ),
      ],
    );
  }
}
