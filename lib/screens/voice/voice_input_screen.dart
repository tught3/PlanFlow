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
import '../../services/voice_command_router.dart';
import '../../services/voice_command_analysis_service.dart';
import '../../services/voice_text_cleanup_service.dart';

class VoiceInputScreen extends StatefulWidget {
  const VoiceInputScreen({
    super.key,
    this.sttService = const SttService(),
    this.gptService,
    this.voiceAnalysisService,
    this.autoStartOverride,
    this.settingsRepository,
  });

  final SttService sttService;
  final GptService? gptService;
  final VoiceCommandAnalysisService? voiceAnalysisService;
  final bool? autoStartOverride;
  final SettingsRepository? settingsRepository;

  @override
  State<VoiceInputScreen> createState() => _VoiceInputScreenState();
}

class _VoiceInputScreenState extends State<VoiceInputScreen> {
  final TextEditingController _rawTextController = TextEditingController();
  final FocusNode _rawTextFocusNode = FocusNode();
  final ScrollController _scrollController = ScrollController();
  Timer? _draftPreparationDebounce;
  late final VoiceCommandAnalysisService _voiceAnalysisService;
  late final VoiceCommandRouter _voiceCommandRouter;

  bool _isListening = false;
  String? _recognizedText;
  String? _statusMessage;
  String? _analysisStatusMessage;
  int _sttRestartCount = 0;
  bool _didResolveAutoStart = false;
  bool _isApplyingTranscriptProgrammatically = false;
  bool _didEditTranscriptManually = false;
  int _draftPreparationToken = 0;
  Map<String, dynamic>? _preparedDraft;
  String? _preparedDraftSourceText;

  @override
  void initState() {
    super.initState();
    _voiceAnalysisService =
        widget.voiceAnalysisService ?? VoiceCommandAnalysisService();
    _voiceCommandRouter = const VoiceCommandRouter();
    _rawTextController.addListener(_handleRawTextChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _maybeAutoStartVoiceInput();
    });
  }

  @override
  void dispose() {
    _draftPreparationDebounce?.cancel();
    _rawTextController.removeListener(_handleRawTextChanged);
    _rawTextController.dispose();
    _rawTextFocusNode.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _handleRawTextChanged() {
    if (!_isApplyingTranscriptProgrammatically &&
        _rawTextController.text.trim().isNotEmpty) {
      _didEditTranscriptManually = true;
      _clearPreparedDraft();
    }
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
    _clearPreparedDraft();
    _voiceAnalysisService.resetSession();

    setState(() {
      _isListening = true;
      _recognizedText = null;
      _sttRestartCount = 0;
      _statusMessage = null;
      _analysisStatusMessage = null;
    });

    try {
      final result = await widget.sttService.listen(
        onPartialResult: (text) {
          if (!_didEditTranscriptManually) {
            _setTranscriptText(text);
          }
        },
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

      if (result.hasText && !_didEditTranscriptManually) {
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
    _clearPreparedDraft();
    _setTranscriptText('');
    if (!mounted) {
      return;
    }
    setState(() {
      _statusMessage = '전체 입력을 지웠어요. 다시 말하거나 직접 입력해 주세요.';
    });
  }

  Future<void> _continueWithRawText() async {
    final normalizedText =
        SttService.normalizeVoiceTranscript(_rawTextController.text.trim());
    if (!mounted) {
      return;
    }
    final rawText =
        VoiceTextCleanupService.cleanLocally(normalizedText).cleanedText;
    if (rawText.isEmpty) {
      context.push(AppRoutes.confirm, extra: const <String, dynamic>{});
      return;
    }

    final preparedDraft = _preparedDraftForCurrentText(rawText);
    final preparedAction = _resolvePreparedActionForText(
      preparedDraft,
      rawText,
    );
    final commandAction =
        preparedAction ?? await _detectCommandActionForSubmit(rawText);
    if (!mounted) {
      return;
    }
    if (commandAction == _VoiceCommandAction.add) {
      if (preparedDraft != null) {
        context.push(AppRoutes.confirm, extra: preparedDraft);
        return;
      }

      final cleanup = await _cleanupVoiceTextForRouting(normalizedText);
      if (!mounted) {
        return;
      }
      final cleanedText = cleanup.cleanedText;
      if (cleanedText.isEmpty) {
        context.push(AppRoutes.confirm, extra: const <String, dynamic>{});
        return;
      }

      final inferredStartAt = GptService().inferStartAtFromRawText(cleanedText);
      final shouldParseWithAi = !_didEditTranscriptManually;
      context.push(
        AppRoutes.confirm,
        extra: <String, dynamic>{
          if (_didEditTranscriptManually) 'title': cleanedText,
          'raw_text': cleanedText,
          if (cleanup.changed) 'original_raw_text': cleanup.originalText,
          if (cleanup.changed) 'voice_cleanup_method': cleanup.method.name,
          if (cleanup.changed) 'voice_cleanup_reason': cleanup.reason,
          'memo': cleanedText,
          if (inferredStartAt != null)
            'start_at': inferredStartAt.toIso8601String(),
          if (shouldParseWithAi) 'parse_pending': true,
          if (_didEditTranscriptManually) 'manual_text_confirmed': true,
        },
      );
      return;
    }
    final cleanup = await _cleanupVoiceTextForRouting(normalizedText);
    if (!mounted) {
      return;
    }
    context.push(
      AppRoutes.voiceAction,
      extra: <String, dynamic>{
        'raw_text': rawText,
        if (cleanup.changed) 'original_raw_text': cleanup.originalText,
        if (cleanup.changed) 'voice_cleanup_method': cleanup.method.name,
        if (cleanup.changed) 'voice_cleanup_reason': cleanup.reason,
        'action': commandAction.name,
      },
    );
  }

  Future<VoiceTextCleanupResult> _cleanupVoiceTextForRouting(
    String normalizedText,
  ) async {
    final local = VoiceTextCleanupService.cleanLocally(normalizedText);
    if (_didEditTranscriptManually ||
        !VoiceTextCleanupService.shouldAskAi(local.cleanedText)) {
      return local;
    }
    try {
      return await (widget.gptService ?? GptService()).cleanupVoiceText(
        local.cleanedText,
        context: VoiceTextCleanupContext.add,
      );
    } catch (error) {
      debugPrint('VoiceInputScreen text cleanup failed: $error');
      return local;
    }
  }

  _VoiceCommandAction _detectCommandAction(String text) {
    return _actionFromRouteIntent(_voiceCommandRouter.resolveIntent(text));
  }

  Future<_VoiceCommandAction> _detectCommandActionForSubmit(
    String text,
  ) async {
    final localAction = _detectCommandAction(text);
    if (_didEditTranscriptManually || localAction != _VoiceCommandAction.add) {
      return localAction;
    }

    try {
      final analysis = await _voiceAnalysisService.analyze(
        text,
        stage: VoiceCommandAnalysisStage.complete,
      );
      final analyzedAction = _actionFromAnalysisIntent(analysis.intent);
      if (localAction == _VoiceCommandAction.add &&
          analyzedAction == _VoiceCommandAction.query &&
          _voiceCommandRouter.resolveIntent(text) ==
              VoiceCommandRouteIntent.add) {
        return _VoiceCommandAction.add;
      }
      return analyzedAction;
    } catch (error) {
      debugPrint('VoiceInputScreen submit analysis failed: $error');
      return localAction;
    }
  }

  _VoiceCommandAction _actionFromAnalysisIntent(VoiceCommandIntent intent) {
    return switch (intent) {
      VoiceCommandIntent.add => _VoiceCommandAction.add,
      VoiceCommandIntent.edit => _VoiceCommandAction.edit,
      VoiceCommandIntent.delete => _VoiceCommandAction.delete,
      VoiceCommandIntent.query => _VoiceCommandAction.query,
      VoiceCommandIntent.choose => _VoiceCommandAction.choose,
    };
  }

  _VoiceCommandAction _actionFromRouteIntent(VoiceCommandRouteIntent intent) {
    return switch (intent) {
      VoiceCommandRouteIntent.add => _VoiceCommandAction.add,
      VoiceCommandRouteIntent.edit => _VoiceCommandAction.edit,
      VoiceCommandRouteIntent.delete => _VoiceCommandAction.delete,
      VoiceCommandRouteIntent.query => _VoiceCommandAction.query,
      VoiceCommandRouteIntent.choose => _VoiceCommandAction.choose,
    };
  }

  _VoiceCommandAction? _actionFromPreparedDraft(Map<String, dynamic>? draft) {
    final intent = draft?['voice_intent']?.toString().trim();
    return switch (intent) {
      'add' => _VoiceCommandAction.add,
      'edit' => _VoiceCommandAction.edit,
      'delete' => _VoiceCommandAction.delete,
      'query' => _VoiceCommandAction.query,
      'choose' => _VoiceCommandAction.choose,
      _ => null,
    };
  }

  _VoiceCommandAction? _resolvePreparedActionForText(
    Map<String, dynamic>? draft,
    String text,
  ) {
    final action = _actionFromPreparedDraft(draft);
    if (action == _VoiceCommandAction.query &&
        _voiceCommandRouter.resolveIntent(text) ==
            VoiceCommandRouteIntent.add) {
      return _VoiceCommandAction.add;
    }
    return action;
  }

  void _setTranscriptText(String text) {
    if (!mounted) {
      return;
    }
    final nextText = text.trim();
    _isApplyingTranscriptProgrammatically = true;
    setState(() {
      _recognizedText = nextText.isEmpty ? null : nextText;
      _rawTextController.value = TextEditingValue(
        text: nextText,
        selection: TextSelection.collapsed(offset: nextText.length),
      );
    });
    _isApplyingTranscriptProgrammatically = false;
    _scheduleDraftPreparation(nextText);
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

  void _scheduleDraftPreparation(String text) {
    final normalizedText = VoiceTextCleanupService.cleanLocally(
      SttService.normalizeVoiceTranscript(text),
    ).cleanedText;

    if (!_isListening ||
        _didEditTranscriptManually ||
        normalizedText.isEmpty ||
        _detectCommandAction(normalizedText) != _VoiceCommandAction.add) {
      _clearPreparedDraft();
      return;
    }

    if (_preparedDraft != null && _preparedDraftSourceText == normalizedText) {
      return;
    }

    _draftPreparationDebounce?.cancel();
    final token = ++_draftPreparationToken;

    if (mounted) {
      setState(() {
        _analysisStatusMessage = '일정 분석 중';
      });
    }

    _draftPreparationDebounce = Timer(
      const Duration(milliseconds: 500),
      () {
        unawaited(_prepareDraft(normalizedText, token));
      },
    );
  }

  Future<void> _prepareDraft(String text, int token) async {
    if (!mounted || token != _draftPreparationToken) {
      return;
    }

    try {
      final analysis = await _voiceAnalysisService.analyze(
        text,
        stage: VoiceCommandAnalysisStage.partial,
      );
      if (!mounted || token != _draftPreparationToken) {
        return;
      }
      final draft = analysis.toParsedScheduleMap();
      setState(() {
        _preparedDraft = <String, dynamic>{
          ...draft,
          'raw_text': draft['raw_text'] ?? text,
          if (analysis.confidence < 0.7) 'parse_pending': true,
        };
        _preparedDraftSourceText = text;
        _analysisStatusMessage = '준비됨';
      });
    } catch (error) {
      debugPrint('VoiceInputScreen draft preparation failed: $error');
      if (!mounted || token != _draftPreparationToken) {
        return;
      }
      setState(() {
        _preparedDraft = null;
        _preparedDraftSourceText = null;
        _analysisStatusMessage = null;
      });
    }
  }

  Map<String, dynamic>? _preparedDraftForCurrentText(String currentText) {
    if (_didEditTranscriptManually) {
      return null;
    }
    if (_preparedDraft == null || _preparedDraftSourceText != currentText) {
      return null;
    }
    return Map<String, dynamic>.from(_preparedDraft!);
  }

  void _clearPreparedDraft() {
    _draftPreparationDebounce?.cancel();
    _draftPreparationDebounce = null;
    _draftPreparationToken += 1;
    if (!mounted) {
      return;
    }
    setState(() {
      _preparedDraft = null;
      _preparedDraftSourceText = null;
      _analysisStatusMessage = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('음성 입력')),
      bottomNavigationBar: _VoiceBottomControls(
        isListening: _isListening,
        hasText: _rawTextController.text.trim().isNotEmpty,
        statusMessage: _statusMessage ?? _analysisStatusMessage,
        onCancel: _cancelVoiceFlow,
        onUndo: _undoLastSegment,
        onClear: _clearTranscript,
        onManualSubmit: _continueWithRawText,
        onHome: () => context.go(AppRoutes.home),
        onCalendar: () => context.go(AppRoutes.calendar),
        onSettings: () => context.go(AppRoutes.settings),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(AppConstants.defaultPadding),
          child: ResponsiveContent(
            maxWidth: 760,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  '말하거나 직접 입력한 뒤 바로 확인하세요.',
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: PlanFlowColors.primary,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 10),
                Expanded(child: _VoiceCommandGuide(theme: theme)),
                const SizedBox(height: 8),
                _ListeningGuide(
                  isListening: _isListening,
                  restartCount: _sttRestartCount,
                ),
                const SizedBox(height: 10),
                _VoiceTranscriptSection(
                  isListening: _isListening,
                  recognizedText: _recognizedText,
                  controller: _rawTextController,
                  focusNode: _rawTextFocusNode,
                  onManualSubmit: _continueWithRawText,
                ),
                const SizedBox(height: 8),
                _VoicePrimaryButton(
                  isListening: _isListening,
                  onTapStart: _startVoiceFlow,
                  onTapFinish: _finishVoiceFlow,
                ),
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
      '일정: “내일 오전 10시 정장집 방문”',
      '기간: “5월 10일 하루종일 휴가”',
      '반복: “매주 화요일 팀 미팅”',
      '장소: “내일 오후 3시 강남역 미팅”',
      '분류: 병원=건강, 세미나=교육',
      '조회: “오늘 일정 알려줘”, “이번 주 일정 알려줘”',
      '수정/삭제: “마지막 거 지워”, “다시”, “취소”라고 말할 수 있어요.',
    ];
    const compactBullets = <String>[
      '일정: “내일 오전 10시 정장집 방문”, “5월 10일 하루종일 휴가”, “매주 화요일 팀 미팅”',
      '분류/조회: 병원 진료는 건강, “오늘 일정 알려줘”, “마지막 거 지워”',
    ];

    return LayoutBuilder(
      builder: (context, constraints) {
        return Card(
          elevation: 0,
          color: const Color(0xFFEAF4FF),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
            side: const BorderSide(color: Color(0xFF92BEE8), width: 0.8),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: LayoutBuilder(
              builder: (context, innerConstraints) {
                final visibleBullets =
                    innerConstraints.maxHeight < 112 ? compactBullets : bullets;

                return SingleChildScrollView(
                  physics: const NeverScrollableScrollPhysics(),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      minHeight: innerConstraints.maxHeight,
                    ),
                    child: SizedBox(
                      width: innerConstraints.maxWidth,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            '이렇게 말해보세요',
                            style: theme.textTheme.titleSmall?.copyWith(
                              color: PlanFlowColors.primary,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          ...visibleBullets.map(
                            (line) => Text(
                              '• $line',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: PlanFlowColors.textSecondary,
                                height: 1.22,
                              ),
                            ),
                          ),
                          Text(
                            '시간, 장소, 반복 표현을 같이 말하면 더 정확해요.',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: PlanFlowColors.primary,
                              height: 1.15,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        );
      },
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
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
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
  });

  final bool isListening;
  final String? recognizedText;
  final TextEditingController controller;
  final FocusNode focusNode;
  final VoidCallback onManualSubmit;

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
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
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
            const SizedBox(height: 6),
            TextField(
              controller: controller,
              focusNode: focusNode,
              maxLines: 4,
              minLines: 2,
              decoration: const InputDecoration(hintText: '입력해주세요'),
              onSubmitted: (_) => onManualSubmit(),
            ),
            if (recognizedText != null) ...[
              const SizedBox(height: 6),
              Text(
                isListening ? '계속 듣는 중입니다.' : '인식된 내용을 확인해 주세요.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: PlanFlowColors.textSecondary,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _VoicePrimaryButton extends StatelessWidget {
  const _VoicePrimaryButton({
    required this.isListening,
    required this.onTapStart,
    required this.onTapFinish,
  });

  final bool isListening;
  final VoidCallback onTapStart;
  final VoidCallback onTapFinish;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: FilledButton.icon(
        onPressed: isListening ? onTapFinish : onTapStart,
        icon: Icon(isListening ? Icons.check : Icons.mic),
        label: Text(isListening ? '완료' : '음성으로 일정 입력하기'),
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
    return LayoutBuilder(
      builder: (context, constraints) {
        final compactLabels = constraints.maxWidth < 380 || isListening;
        return Row(
          children: [
            Expanded(
              child: _VoiceActionButton(
                label: compactLabels ? '전체삭제' : '전체 지우기',
                onPressed: hasText ? onClear : null,
              ),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: _VoiceActionButton(
                label: compactLabels ? '마지막삭제' : '마지막 단어 삭제',
                onPressed: hasText ? onUndo : null,
              ),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: _VoiceActionButton(
                label: compactLabels ? '직접입력' : '직접 입력',
                onPressed: hasText ? onManualSubmit : null,
              ),
            ),
            if (isListening) ...[
              const SizedBox(width: 6),
              SizedBox.square(
                dimension: 40,
                child: IconButton.outlined(
                  tooltip: '음성 입력 취소',
                  onPressed: onCancel,
                  icon: const Icon(Icons.close, size: 20),
                  padding: EdgeInsets.zero,
                ),
              ),
            ],
          ],
        );
      },
    );
  }
}

class _VoiceActionButton extends StatelessWidget {
  const _VoiceActionButton({
    required this.label,
    required this.onPressed,
  });

  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton(
      onPressed: onPressed,
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(0, 40),
        padding: const EdgeInsets.symmetric(horizontal: 6),
        textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
      ),
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Text(
          label,
          maxLines: 1,
          softWrap: false,
          textAlign: TextAlign.center,
        ),
      ),
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

class _VoiceBottomControls extends StatelessWidget {
  const _VoiceBottomControls({
    required this.isListening,
    required this.hasText,
    required this.statusMessage,
    required this.onCancel,
    required this.onUndo,
    required this.onClear,
    required this.onManualSubmit,
    required this.onHome,
    required this.onCalendar,
    required this.onSettings,
  });

  final bool isListening;
  final bool hasText;
  final String? statusMessage;
  final VoidCallback onCancel;
  final VoidCallback onUndo;
  final VoidCallback onClear;
  final VoidCallback onManualSubmit;
  final VoidCallback onHome;
  final VoidCallback onCalendar;
  final VoidCallback onSettings;

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.viewPaddingOf(context).bottom;
    return Material(
      color: Theme.of(context).colorScheme.surface,
      elevation: 3,
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppConstants.defaultPadding,
                8,
                AppConstants.defaultPadding,
                6,
              ),
              child: _VoiceActionButtons(
                isListening: isListening,
                hasText: hasText,
                onCancel: onCancel,
                onUndo: onUndo,
                onClear: onClear,
                onManualSubmit: onManualSubmit,
              ),
            ),
            if (statusMessage != null)
              Padding(
                padding: EdgeInsets.fromLTRB(
                  AppConstants.defaultPadding,
                  0,
                  AppConstants.defaultPadding,
                  bottomInset > 0 ? 2 : 8,
                ),
                child: _StatusBanner(message: statusMessage!),
              ),
            _VoiceBottomNavigation(
              onHome: onHome,
              onCalendar: onCalendar,
              onSettings: onSettings,
            ),
          ],
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
