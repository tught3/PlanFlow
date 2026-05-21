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
import '../../l10n/app_l10n.dart';

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
  bool _manualEditInterruptedListening = false;
  bool _isSubmittingVoiceCommand = false;
  int _partialTranscriptToken = 0;
  int _draftPreparationToken = 0;
  Map<String, dynamic>? _preparedDraft;
  String? _preparedDraftSourceText;
  String? _lastSubmittedSignature;
  String _listenPrefixText = '';

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

  Future<void> _startVoiceFlow({bool continueExisting = false}) async {
    if (_isListening) {
      return;
    }

    unawaited(AnalyticsService.logVoiceInputStarted());
    _clearPreparedDraft();
    if (!continueExisting) {
      _voiceAnalysisService.resetSession();
      _listenPrefixText = '';
    } else {
      _listenPrefixText = _rawTextController.text.trim();
    }

    setState(() {
      _isListening = true;
      _manualEditInterruptedListening = false;
      _didEditTranscriptManually = false;
      _recognizedText = null;
      _sttRestartCount = 0;
      _statusMessage = null;
      _analysisStatusMessage = null;
    });

    try {
      final result = await widget.sttService.listen(
        onPartialResult: (text) {
          if (!_didEditTranscriptManually) {
            final token = ++_partialTranscriptToken;
            unawaited(_applyNormalizedPartialTranscript(text, token));
          }
        },
        onRestart: (count) {
          if (!mounted) {
            return;
          }
          setState(() {
            _sttRestartCount = count;
            _statusMessage = appL10n(context).voiceAutoRestarted;
          });
        },
      );
      if (!mounted) {
        return;
      }

      if (_manualEditInterruptedListening) {
        _focusManualInput();
        return;
      }

      if (result.failure == null &&
          result.hasText &&
          !_didEditTranscriptManually) {
        _setTranscriptText(
          _mergeVoiceTranscript(_listenPrefixText, result.text ?? ''),
        );
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
        _statusMessage = result.message ?? appL10n(context).voiceNoResult;
      });
      _focusManualInput();
    } catch (_) {
      if (!mounted) {
        return;
      }
      unawaited(AnalyticsService.logVoiceInputFailed(reason: 'stt_exception'));
      setState(() {
        _statusMessage = appL10n(context).voiceFailed;
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

  Future<void> _continueListeningFlow() async {
    if (_isListening || _rawTextController.text.trim().isEmpty) {
      return;
    }
    await _startVoiceFlow(continueExisting: true);
  }

  Future<void> _activateManualTranscriptEditing() async {
    if (_isListening) {
      _manualEditInterruptedListening = true;
      _didEditTranscriptManually = true;
      _partialTranscriptToken++;
      await widget.sttService.stopActiveListen();
      if (!mounted) {
        return;
      }
      setState(() {
        _isListening = false;
        _statusMessage = '음성 인식을 잠시 멈췄어요. 키보드로 수정해 주세요.';
      });
    }
    _focusManualInput();
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
      _statusMessage = appL10n(context).voiceCancelled;
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
      _statusMessage = nextText.trim().isEmpty
          ? appL10n(context).voiceClearedEmpty
          : appL10n(context).voiceDeletedLast;
    });
  }

  Future<void> _clearTranscript() async {
    if (_isListening) {
      await widget.sttService.clearActiveTranscript();
    }
    _listenPrefixText = '';
    _clearPreparedDraft();
    _setTranscriptText('');
    if (!mounted) {
      return;
    }
    setState(() {
      _statusMessage = appL10n(context).voiceClearedAll;
    });
  }

  Future<void> _applyNormalizedPartialTranscript(String text, int token) async {
    if (!_isListening || token != _partialTranscriptToken) {
      return;
    }

    var shouldClearAll = false;
    var shouldCancel = false;

    final normalizedText = SttService.normalizeVoiceTranscript(
      text,
      onCommand: (command) {
        if (command == SttVoiceCommand.clearAll) {
          shouldClearAll = true;
        } else if (command == SttVoiceCommand.cancel) {
          shouldCancel = true;
        }
      },
      includeCancelCommands: true,
    );

    if (!mounted || token != _partialTranscriptToken) {
      return;
    }

    if (shouldCancel) {
      await _cancelVoiceFlow();
      if (!mounted || token != _partialTranscriptToken) {
        return;
      }
      _listenPrefixText = '';
      _clearPreparedDraft();
      _setTranscriptText('');
      return;
    }

    if (shouldClearAll) {
      _listenPrefixText = '';
      await _clearTranscript();
      if (!mounted || token != _partialTranscriptToken) {
        return;
      }
      return;
    }

    if (!_isListening || token != _partialTranscriptToken) {
      return;
    }
    _setTranscriptText(
        _mergeVoiceTranscript(_listenPrefixText, normalizedText));
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
    if (!_beginVoiceCommandSubmit(rawText)) {
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
    if (commandAction == _VoiceCommandAction.choose &&
        _voiceCommandRouter.isAmbiguousFieldAddition(rawText)) {
      final choice = await _showAmbiguousFieldAdditionSheet(rawText);
      if (!mounted) {
        return;
      }
      switch (choice) {
        case _AmbiguousFieldAdditionChoice.updateExisting:
          await _openVoiceActionFromText(
            normalizedText,
            rawText,
            _VoiceCommandAction.edit,
          );
          return;
        case _AmbiguousFieldAdditionChoice.createNew:
          await _openAddConfirmFromText(normalizedText, preparedDraft);
          return;
        case _AmbiguousFieldAdditionChoice.editText:
        case null:
          _resetVoiceCommandSubmitGuard(clearSignature: choice != null);
          if (choice == _AmbiguousFieldAdditionChoice.editText) {
            _focusManualInput();
          }
          return;
      }
    }
    if (commandAction == _VoiceCommandAction.add) {
      await _openAddConfirmFromText(normalizedText, preparedDraft);
      return;
    }
    await _openVoiceActionFromText(normalizedText, rawText, commandAction);
  }

  bool _beginVoiceCommandSubmit(String rawText) {
    final signature = VoiceTextCleanupService.normalizeBasic(rawText);
    if (_isSubmittingVoiceCommand || _lastSubmittedSignature == signature) {
      return false;
    }
    setState(() {
      _isSubmittingVoiceCommand = true;
      _lastSubmittedSignature = signature;
    });
    return true;
  }

  void _resetVoiceCommandSubmitGuard({bool clearSignature = false}) {
    if (!mounted) {
      return;
    }
    setState(() {
      _isSubmittingVoiceCommand = false;
      if (clearSignature) {
        _lastSubmittedSignature = null;
      }
    });
  }

  Future<void> _pushVoiceRoute(String location, {Object? extra}) async {
    unawaited(
      context.push(location, extra: extra).whenComplete(() {
        _resetVoiceCommandSubmitGuard(clearSignature: true);
      }),
    );
  }

  Future<void> _openAddConfirmFromText(
    String normalizedText,
    Map<String, dynamic>? preparedDraft,
  ) async {
    if (preparedDraft != null) {
      await _pushVoiceRoute(AppRoutes.confirm, extra: preparedDraft);
      return;
    }

    final cleanup = await _cleanupVoiceTextForRouting(normalizedText);
    if (!mounted) {
      return;
    }
    final cleanedText = cleanup.cleanedText;
    if (cleanedText.isEmpty) {
      await _pushVoiceRoute(AppRoutes.confirm,
          extra: const <String, dynamic>{});
      return;
    }

    final inferredStartAt = GptService().inferStartAtFromRawText(cleanedText);
    await _pushVoiceRoute(
      AppRoutes.confirm,
      extra: <String, dynamic>{
        'raw_text': cleanedText,
        if (cleanup.changed) 'original_raw_text': cleanup.originalText,
        if (cleanup.changed) 'voice_cleanup_method': cleanup.method.name,
        if (cleanup.changed) 'voice_cleanup_reason': cleanup.reason,
        if (inferredStartAt != null)
          'start_at': inferredStartAt.toIso8601String(),
        'parse_pending': true,
        if (_didEditTranscriptManually) 'manual_text_confirmed': true,
      },
    );
  }

  Future<void> _openVoiceActionFromText(
    String normalizedText,
    String rawText,
    _VoiceCommandAction commandAction,
  ) async {
    final cleanup = await _cleanupVoiceTextForRouting(normalizedText);
    if (!mounted) {
      return;
    }
    await _pushVoiceRoute(
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

  Future<_AmbiguousFieldAdditionChoice?> _showAmbiguousFieldAdditionSheet(
    String rawText,
  ) {
    return showModalBottomSheet<_AmbiguousFieldAdditionChoice>(
      context: context,
      showDragHandle: true,
      builder: (context) {
        final theme = Theme.of(context);
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  '어떤 뜻인가요?',
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w800,
                    color: PlanFlowColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  rawText,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: PlanFlowColors.textSecondary,
                  ),
                ),
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: () => Navigator.of(context).pop(
                    _AmbiguousFieldAdditionChoice.updateExisting,
                  ),
                  icon: const Icon(Icons.event_available_outlined),
                  label: const Text('기존 일정에 내용 추가'),
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: () => Navigator.of(context).pop(
                    _AmbiguousFieldAdditionChoice.createNew,
                  ),
                  icon: const Icon(Icons.add_circle_outline),
                  label: const Text('새 일정으로 추가'),
                ),
                TextButton.icon(
                  onPressed: () => Navigator.of(context).pop(
                    _AmbiguousFieldAdditionChoice.editText,
                  ),
                  icon: const Icon(Icons.edit_outlined),
                  label: const Text('직접 편집'),
                ),
              ],
            ),
          ),
        );
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

  String _mergeVoiceTranscript(String prefix, String nextText) {
    final base = prefix.trim();
    final next = nextText.trim();
    if (base.isEmpty) {
      return next;
    }
    if (next.isEmpty || base == next) {
      return base;
    }
    if (next.startsWith(base)) {
      return next;
    }
    if (base.endsWith(next)) {
      return base;
    }
    final baseWords = base.split(RegExp(r'\s+'));
    final nextWords = next.split(RegExp(r'\s+'));
    final maxOverlap = baseWords.length < nextWords.length
        ? baseWords.length
        : nextWords.length;
    for (var count = maxOverlap; count > 0; count -= 1) {
      final left = baseWords.skip(baseWords.length - count).join(' ');
      final right = nextWords.take(count).join(' ');
      if (left == right) {
        return [
          ...baseWords,
          ...nextWords.skip(count),
        ].join(' ');
      }
    }
    return '$base $next';
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

  Future<void> _confirmManualText() async {
    await _continueWithRawText();
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
    final l10n = appL10n(context);

    return Scaffold(
      appBar: AppBar(title: Text(l10n.voiceInputTitle)),
      bottomNavigationBar: _VoiceBottomControls(
        isListening: _isListening,
        hasText: _rawTextController.text.trim().isNotEmpty,
        statusMessage: _statusMessage ?? _analysisStatusMessage,
        onCancel: _cancelVoiceFlow,
        onUndo: _undoLastSegment,
        onClear: _clearTranscript,
        onManualSubmit: _confirmManualText,
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
                  onTapTranscript: () =>
                      unawaited(_activateManualTranscriptEditing()),
                  onManualSubmit: _continueWithRawText,
                ),
                const SizedBox(height: 8),
                _VoicePrimaryButton(
                  isListening: _isListening,
                  hasText: _rawTextController.text.trim().isNotEmpty,
                  onTapStart: _startVoiceFlow,
                  onTapFinish: _finishVoiceFlow,
                  onManualSubmit: _confirmManualText,
                ),
                if (_rawTextController.text.trim().isNotEmpty) ...[
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    key: const ValueKey('voice-continue-listening-button'),
                    onPressed: _isListening ? null : _continueListeningFlow,
                    icon: Icon(
                      _isListening
                          ? Icons.hearing_outlined
                          : Icons.record_voice_over_outlined,
                    ),
                    label: Text(_isListening ? '듣는 중' : '계속 이어서 말하기'),
                  ),
                ],
                if (_rawTextController.text.trim().isEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      '현재 내용으로 입력하려면 텍스트를 먼저 입력해 주세요.',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: PlanFlowColors.textSecondary,
                          ),
                    ),
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

enum _AmbiguousFieldAdditionChoice { updateExisting, createNew, editText }

class _VoiceCommandGuide extends StatelessWidget {
  const _VoiceCommandGuide({required this.theme});

  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    final l10n = appL10n(context);
    final isKorean = l10n.localeName == 'ko';
    final bullets = isKorean
        ? const <String>[
            '일정: “오늘 4시에 팀장님 내일 오시는지 확인전화하기”',
            '기본: 앞 시간은 실행 시점, 그 뒤 말은 일정 내용',
            '기간/반복: “5월 10일 하루종일 휴가”, “매주 화요일 팀 미팅”',
            '장소: “내일 오후 3시 강남역 미팅”',
            '수정: “언제 일정을 다음주로 변경해”',
            '분류: 병원=건강, 세미나=교육',
            '조회: “오늘 일정 알려줘”, “이번 주 일정 알려줘”',
            '제어: 다시/처음부터/전체삭제/전체취소=전체삭제 · 아니/아니다=교정 · 마지막 삭제/방금 삭제=일부삭제 · 취소/중지 등=종료',
          ]
        : const <String>[
            'Event: “Visit the tailor tomorrow at 10 AM”',
            'All-day: “Vacation all day on May 10”',
            'Repeat: “Team meeting every Tuesday”',
            'Place: “Meeting at Gangnam Station tomorrow at 3 PM”',
            'Edit: “Move that appointment to next week”',
            'Category: hospital=health, seminar=education',
            'Query: “Tell me today’s schedule”, “Show this week”',
            'Control: start over=clear · no=correct · delete last=remove word · stop=end',
          ];
    final compactBullets = isKorean
        ? const <String>[
            '일정/수정/조회: “오늘 4시에 팀장님 내일 오시는지 확인전화하기”, “5월 10일 하루종일 휴가”, “매주 화요일 팀 미팅”, “오늘 일정 알려줘”',
            '제어: 다시/처음부터/전체삭제/전체취소=전체삭제 · 아니/아니다=교정 · 마지막 삭제/방금 삭제=일부삭제 · 취소/중지 등=종료',
          ]
        : const <String>[
            'Event/edit/query: “Visit tomorrow at 10 AM”, “Vacation on May 10”, “Team meeting every Tuesday”, “Show today”',
            'Control: start over=clear · no=correct · delete last=remove word · stop=end',
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
                            l10n.voiceGuideTitle,
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
                            l10n.voiceGuideFooter,
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
    final l10n = appL10n(context);
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
                  ? l10n.voiceListenActive
                  : l10n.voiceListenRestarted(restartCount)
              : l10n.voiceListenIdle,
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
    required this.onTapTranscript,
    required this.onManualSubmit,
  });

  final bool isListening;
  final String? recognizedText;
  final TextEditingController controller;
  final FocusNode focusNode;
  final VoidCallback onTapTranscript;
  final VoidCallback onManualSubmit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = appL10n(context);

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
              l10n.voiceTranscriptTitle,
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
              textInputAction: TextInputAction.done,
              decoration: InputDecoration(hintText: l10n.voiceInputHint),
              onTap: onTapTranscript,
              onSubmitted: (_) {
                FocusScope.of(context).unfocus();
                onManualSubmit();
              },
            ),
            if (recognizedText != null) ...[
              const SizedBox(height: 6),
              Text(
                isListening
                    ? l10n.voiceListeningContinue
                    : l10n.voiceCheckRecognized,
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
    required this.hasText,
    required this.onTapStart,
    required this.onTapFinish,
    required this.onManualSubmit,
  });

  final bool isListening;
  final bool hasText;
  final VoidCallback onTapStart;
  final VoidCallback onTapFinish;
  final VoidCallback onManualSubmit;

  @override
  Widget build(BuildContext context) {
    final l10n = appL10n(context);
    final voiceButton = FilledButton.icon(
      onPressed: isListening ? onTapFinish : onTapStart,
      icon: Icon(isListening ? Icons.check : Icons.mic),
      label: FittedBox(
        fit: BoxFit.scaleDown,
        child: Text(isListening ? l10n.voiceDone : l10n.voicePrimaryStart),
      ),
    );

    if (isListening) {
      return SizedBox(width: double.infinity, child: voiceButton);
    }

    return Row(
      children: [
        Expanded(child: voiceButton),
        const SizedBox(width: 8),
        Expanded(
          child: FilledButton.tonalIcon(
            key: const ValueKey('voice-input-confirm-current-text-button'),
            onPressed: hasText ? onManualSubmit : null,
            icon: const Icon(Icons.check_circle_outline),
            label: const FittedBox(
              fit: BoxFit.scaleDown,
              child: Text('현재 내용으로 입력'),
            ),
          ),
        ),
      ],
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
    final l10n = appL10n(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final compactLabels = constraints.maxWidth < 380 || isListening;
        return Row(
          children: [
            Expanded(
              child: _VoiceActionButton(
                label: compactLabels
                    ? l10n.voiceClearAllCompact
                    : l10n.voiceClearAll,
                onPressed: hasText ? onClear : null,
              ),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: _VoiceActionButton(
                label: compactLabels
                    ? l10n.voiceDeleteLastCompact
                    : l10n.voiceDeleteLast,
                onPressed: hasText ? onUndo : null,
              ),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: _VoiceActionButton(
                label: compactLabels
                    ? l10n.voiceManualInputCompact
                    : l10n.voiceManualInput,
                onPressed: hasText ? onManualSubmit : null,
              ),
            ),
            if (isListening) ...[
              const SizedBox(width: 6),
              SizedBox.square(
                dimension: 40,
                child: IconButton.outlined(
                  tooltip: l10n.voiceCancelTooltip,
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
    final l10n = appL10n(context);
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
      destinations: [
        NavigationDestination(
          icon: const Icon(Icons.home_outlined),
          selectedIcon: const Icon(Icons.home),
          label: l10n.homeTab,
        ),
        NavigationDestination(
          icon: const Icon(Icons.calendar_month_outlined),
          selectedIcon: const Icon(Icons.calendar_month),
          label: l10n.calendarTab,
        ),
        NavigationDestination(
          icon: const Icon(Icons.settings_outlined),
          selectedIcon: const Icon(Icons.settings),
          label: l10n.settingsTab,
        ),
      ],
    );
  }
}
