import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/constants.dart';
import '../../core/env.dart';
import '../../core/responsive.dart';
import '../../core/theme.dart';
import '../../data/models/voice_correction_rule.dart';
import '../../data/repositories/settings_repository.dart';
import '../../data/repositories/voice_correction_rule_repository.dart';
import '../../core/analytics_service.dart';
import '../../services/gpt_service.dart';
import '../../services/stt_service.dart';
import '../../services/voice_correction_learning_service.dart';
import '../../services/voice_command_router.dart';
import '../../services/voice_command_analysis_service.dart';
import 'voice_conversation_screen.dart';
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

class _VoiceInputScreenState extends State<VoiceInputScreen>
    with WidgetsBindingObserver {
  static const String _voiceConversationClosedMessage =
      'AI 일정 대화를 종료했어요. 새로 말하려면 음성 입력을 다시 시작해 주세요.';

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
  bool _hasSubmittedVoiceCommand = false;
  bool _isDisposing = false;
  bool _isExitingVoiceInput = false;
  bool _isFinishingVoiceFlow = false;
  int _partialTranscriptToken = 0;
  int _listenSessionGeneration = 0;
  int _draftPreparationToken = 0;
  Map<String, dynamic>? _preparedDraft;
  String? _preparedDraftSourceText;
  String? _lastSubmittedSignature;
  String _listenPrefixText = '';
  String? _lastProgrammaticTranscript;
  String? _manualEditOriginalTranscript;
  final VoiceCorrectionLearningService _voiceCorrectionLearningService =
      const VoiceCorrectionLearningService();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _voiceAnalysisService =
        widget.voiceAnalysisService ?? VoiceCommandAnalysisService();
    _voiceCommandRouter = const VoiceCommandRouter();
    _rawTextController.addListener(_handleRawTextChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _maybeAutoStartVoiceInput();
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 전화·화면잠금·앱전환 시 STT 즉시 취소
    if (state == AppLifecycleState.paused && _isListening) {
      unawaited(widget.sttService.cancelActiveListen());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _isDisposing = true;
    _partialTranscriptToken++;
    _listenSessionGeneration++;
    _draftPreparationDebounce?.cancel();
    _resetVoiceSessionState();
    if (!_isExitingVoiceInput) {
      unawaited(widget.sttService.cancelActiveListen());
    }
    _rawTextController.removeListener(_handleRawTextChanged);
    _rawTextController.dispose();
    _rawTextFocusNode.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _handleRawTextChanged() {
    if (!_isApplyingTranscriptProgrammatically &&
        _rawTextController.text.trim().isNotEmpty) {
      _manualEditOriginalTranscript ??= _lastProgrammaticTranscript;
      _didEditTranscriptManually = true;
      _hasSubmittedVoiceCommand = false;
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

    if (widget.autoStartOverride == true) {
      await Future<void>.delayed(const Duration(milliseconds: 600));
    }
    if (!mounted ||
        !shouldAutoStart ||
        _rawTextController.text.isNotEmpty ||
        _isListening) {
      return;
    }

    await _startVoiceFlow(
      autoRetryOnEarlyFailure: widget.autoStartOverride == true,
    );
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

  Future<void> _startVoiceFlow({
    bool continueExisting = false,
    bool autoRetryOnEarlyFailure = false,
  }) async {
    if (_isListening) {
      return;
    }

    final listenGeneration = ++_listenSessionGeneration;
    unawaited(AnalyticsService.logVoiceInputStarted());
    _clearPreparedDraft();
    if (!continueExisting) {
      _voiceAnalysisService.resetSession();
      _listenPrefixText = '';
    } else if (!_hasSubmittedVoiceCommand) {
      _listenPrefixText = _rawTextController.text.trim();
    } else {
      _listenPrefixText = '';
    }

    setState(() {
      _isListening = true;
      _isFinishingVoiceFlow = false;
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
          if (_isCurrentListenSession(listenGeneration) &&
              !_isFinishingVoiceFlow &&
              !_didEditTranscriptManually) {
            final token = ++_partialTranscriptToken;
            unawaited(_applyNormalizedPartialTranscript(
              text,
              token,
              listenGeneration,
            ));
          }
        },
        onRestart: (count) {
          if (!mounted || !_isCurrentListenSession(listenGeneration)) {
            return;
          }
          setState(() {
            _sttRestartCount = count;
            _statusMessage = appL10n(context).voiceAutoRestarted;
          });
        },
        mode: SttListenMode.dictation,
      );
      if (!mounted || _isDisposing) {
        return;
      }
      if (!_isCurrentListenSession(listenGeneration)) {
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

      if (autoRetryOnEarlyFailure &&
          _shouldRetryAutoStartedListen(result) &&
          !_didEditTranscriptManually &&
          !_manualEditInterruptedListening) {
        setState(() {
          _isListening = false;
          _statusMessage = '음성 입력을 다시 준비하고 있어요.';
        });
        await Future<void>.delayed(const Duration(milliseconds: 650));
        if (!mounted ||
            !_isCurrentListenSession(listenGeneration) ||
            _rawTextController.text.trim().isNotEmpty ||
            _isListening) {
          return;
        }
        await _startVoiceFlow();
        return;
      }

      unawaited(AnalyticsService.logVoiceInputFailed(reason: 'stt_no_result'));
      setState(() {
        _statusMessage = result.message ?? appL10n(context).voiceNoResult;
      });
      _focusManualInput();
    } catch (_) {
      if (!mounted || !_isCurrentListenSession(listenGeneration)) {
        return;
      }
      unawaited(AnalyticsService.logVoiceInputFailed(reason: 'stt_exception'));
      setState(() {
        _statusMessage = appL10n(context).voiceFailed;
      });
      _focusManualInput();
    } finally {
      if (mounted && _isCurrentListenSession(listenGeneration)) {
        setState(() {
          _isListening = false;
          _isFinishingVoiceFlow = false;
        });
      }
    }
  }

  bool _isCurrentListenSession(int generation) {
    return !_isDisposing && generation == _listenSessionGeneration;
  }

  bool _shouldRetryAutoStartedListen(SttListenResult result) {
    if (result.hasText) {
      return false;
    }
    return result.failure == SttListenFailure.silence ||
        result.failure == SttListenFailure.unavailable;
  }

  Future<void> _handleVoiceStartPressed() async {
    if (_isListening) {
      await _finishVoiceFlow();
      return;
    }

    if (_rawTextController.text.trim().isEmpty) {
      await _startVoiceFlow();
      return;
    }

    final choice = await _showVoiceTextExistsSheet();
    if (!mounted) {
      return;
    }
    switch (choice) {
      case _ExistingVoiceTextChoice.append:
        await _startVoiceFlow(continueExisting: true);
        return;
      case _ExistingVoiceTextChoice.restart:
        _resetTranscriptForFreshVoiceInput();
        await _startVoiceFlow();
        return;
      case _ExistingVoiceTextChoice.cancel:
      case null:
        _focusManualInput();
        return;
    }
  }

  Future<void> _finishVoiceFlow() async {
    if (_isListening) {
      _isFinishingVoiceFlow = true;
      _partialTranscriptToken++;
      await widget.sttService.stopActiveListen();
    }
  }

  Future<void> _activateManualTranscriptEditing() async {
    if (_isListening) {
      _manualEditInterruptedListening = true;
      _didEditTranscriptManually = true;
      _partialTranscriptToken++;
      _listenSessionGeneration++;
      _isFinishingVoiceFlow = false;
      // 타이핑 시작 시 STT를 확정 종료한다. 상태와 종료 신호를 같이 맞춘다.
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
    _partialTranscriptToken++;
    _listenSessionGeneration++;
    _isFinishingVoiceFlow = false;
    await widget.sttService.cancelActiveListen();
    if (!mounted) {
      return;
    }
    setState(() {
      _isListening = false;
      _statusMessage = appL10n(context).voiceCancelled;
    });
  }

  void _resetVoiceSessionState() {
    _listenPrefixText = '';
    _manualEditInterruptedListening = false;
    _didEditTranscriptManually = false;
    _isFinishingVoiceFlow = false;
    _isSubmittingVoiceCommand = false;
    _hasSubmittedVoiceCommand = false;
    _lastSubmittedSignature = null;
    _recognizedText = null;
    _lastProgrammaticTranscript = null;
    _manualEditOriginalTranscript = null;
    _isListening = false;
  }

  Future<void> _exitVoiceInput(VoidCallback navigate) async {
    if (_isExitingVoiceInput || _isDisposing) {
      return;
    }
    _isExitingVoiceInput = true;
    debugPrint('VoiceInput lifecycle=exit');
    _partialTranscriptToken++;
    _listenSessionGeneration++;
    _draftPreparationDebounce?.cancel();
    if (mounted) {
      _clearPreparedDraft();
    } else {
      _draftPreparationToken += 1;
      _preparedDraft = null;
      _preparedDraftSourceText = null;
      _analysisStatusMessage = null;
    }
    setState(() {
      _statusMessage = null;
      _resetVoiceSessionState();
    });
    await widget.sttService.cancelActiveListen();
    if (!mounted) {
      return;
    }
    navigate();
  }

  Future<void> _handleBackNavigation() async {
    await _exitVoiceInput(() => context.go(AppRoutes.home));
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
    _resetTranscriptForFreshVoiceInput();
    if (!mounted) {
      return;
    }
    setState(() {
      _statusMessage = appL10n(context).voiceClearedAll;
    });
  }

  void _resetTranscriptForFreshVoiceInput() {
    _listenPrefixText = '';
    _partialTranscriptToken++;
    _listenSessionGeneration++;
    _lastSubmittedSignature = null;
    _hasSubmittedVoiceCommand = false;
    _isSubmittingVoiceCommand = false;
    _didEditTranscriptManually = false;
    _manualEditInterruptedListening = false;
    _lastProgrammaticTranscript = null;
    _manualEditOriginalTranscript = null;
    _clearPreparedDraft();
    _setTranscriptText('');
  }

  Future<void> _applyNormalizedPartialTranscript(
    String text,
    int token,
    int listenGeneration,
  ) async {
    if (!_isCurrentListenSession(listenGeneration) ||
        !_isListening ||
        _isFinishingVoiceFlow ||
        token != _partialTranscriptToken) {
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

    if (!mounted ||
        !_isCurrentListenSession(listenGeneration) ||
        _isFinishingVoiceFlow ||
        token != _partialTranscriptToken) {
      return;
    }

    if (shouldCancel) {
      await _cancelVoiceFlow();
      if (!mounted) {
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
      if (!mounted ||
          !_isCurrentListenSession(listenGeneration) ||
          _isFinishingVoiceFlow ||
          token != _partialTranscriptToken) {
        return;
      }
      return;
    }

    if (!_isCurrentListenSession(listenGeneration) ||
        !_isListening ||
        _isFinishingVoiceFlow ||
        token != _partialTranscriptToken) {
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
    var rawText =
        VoiceTextCleanupService.cleanLocally(normalizedText).cleanedText;
    rawText = await _applyTranscriptCorrectionRules(rawText);
    if (!mounted) {
      return;
    }
    if (rawText.isEmpty) {
      await _pushVoiceRoute(AppRoutes.confirm,
          extra: const <String, dynamic>{});
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

  Future<String> _applyTranscriptCorrectionRules(String rawText) async {
    if (!AppEnv.isSupabaseReady || rawText.trim().isEmpty) {
      return rawText;
    }
    final userId = Supabase.instance.client.auth.currentUser?.id;
    if (userId == null || userId.trim().isEmpty) {
      return rawText;
    }
    try {
      final settingsRepository =
          widget.settingsRepository ?? SettingsRepository.supabase();
      final settings = await settingsRepository.fetchSettings(userId);
      if (settings?.voiceCorrectionLearningEnabled == false) {
        return rawText;
      }
      final repository = VoiceCorrectionRuleRepository.supabase();
      final rules = <VoiceCorrectionRule>[
        ...await repository.fetchPersonalRules(userId),
        if (settings?.voiceCommonLearningOptIn == true)
          ...await repository.fetchTrustedCommonRules(),
      ];
      return _voiceCorrectionLearningService
          .applyRules(
            rawText,
            rules: rules,
            stage: VoiceCorrectionStage.stt,
            field: VoiceCorrectionField.transcript,
          )
          .text;
    } catch (error, stackTrace) {
      debugPrint('VoiceInputScreen correction apply skipped: $error');
      debugPrintStack(stackTrace: stackTrace);
      return rawText;
    }
  }

  bool _beginVoiceCommandSubmit(String rawText) {
    final signature = VoiceTextCleanupService.normalizeBasic(rawText);
    if (_isSubmittingVoiceCommand || _lastSubmittedSignature == signature) {
      return false;
    }
    setState(() {
      _isSubmittingVoiceCommand = true;
      _hasSubmittedVoiceCommand = true;
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
    await _finishVoiceFlow();
    if (!mounted) {
      return;
    }
    unawaited(
      context.push<Object?>(location, extra: extra).then((result) {
        if (!mounted) {
          return;
        }
        final shouldResetTranscript =
            location == AppRoutes.confirm ||
            location == AppRoutes.voiceAction ||
            (_isVoiceConversationRoute(location) &&
                result == voiceConversationClosedResult);
        if (shouldResetTranscript) {
          _resetTranscriptForFreshVoiceInput();
          if (_isVoiceConversationRoute(location) &&
              result == voiceConversationClosedResult) {
            setState(() {
              _statusMessage = _voiceConversationClosedMessage;
            });
          } else {
            setState(() {
              _statusMessage = null;
            });
          }
        }
        _resetVoiceCommandSubmitGuard(clearSignature: true);
      }),
    );
  }

  bool _isVoiceConversationRoute(String location) {
    return location == AppRoutes.voiceConversation ||
        location.startsWith('${AppRoutes.voiceConversation}?');
  }

  Future<void> _openAddConfirmFromText(
    String normalizedText,
    Map<String, dynamic>? preparedDraft,
  ) async {
    if (preparedDraft != null) {
      await _pushVoiceRoute(
        AppRoutes.confirm,
        extra: <String, dynamic>{
          ...preparedDraft,
          if (_manualEditOriginalTranscript?.trim().isNotEmpty == true)
            'stt_original_text': _manualEditOriginalTranscript!.trim(),
          if (_didEditTranscriptManually) 'manual_text_confirmed': true,
        },
      );
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
        if (_manualEditOriginalTranscript?.trim().isNotEmpty == true)
          'stt_original_text': _manualEditOriginalTranscript!.trim(),
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
    if (commandAction == _VoiceCommandAction.query) {
      await _pushVoiceRoute(
        '${AppRoutes.voiceConversation}?autoStart=1',
        extra: <String, dynamic>{
          'initial_text':
              cleanup.cleanedText.isEmpty ? rawText : cleanup.cleanedText,
        },
      );
      return;
    }
    await _pushVoiceRoute(
      AppRoutes.voiceAction,
      extra: <String, dynamic>{
        'raw_text': rawText,
        if (_manualEditOriginalTranscript?.trim().isNotEmpty == true)
          'stt_original_text': _manualEditOriginalTranscript!.trim(),
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

  Future<_ExistingVoiceTextChoice?> _showVoiceTextExistsSheet() {
    return showModalBottomSheet<_ExistingVoiceTextChoice>(
      context: context,
      showDragHandle: true,
      backgroundColor: PlanFlowColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
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
                  '현재 입력된 내용이 있어요',
                  style: theme.textTheme.titleLarge?.copyWith(
                    color: PlanFlowColors.textPrimary,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  '기존 문장 뒤에 이어서 말하거나, 내용을 지우고 처음부터 다시 입력할 수 있어요.',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: PlanFlowColors.textSecondary,
                    height: 1.35,
                  ),
                ),
                const SizedBox(height: 16),
                FilledButton.icon(
                  key: const ValueKey('voice-append-existing-text-button'),
                  onPressed: () => Navigator.of(context).pop(
                    _ExistingVoiceTextChoice.append,
                  ),
                  icon: const Icon(Icons.record_voice_over_outlined),
                  label: const Text('이어서 말하기'),
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  key: const ValueKey('voice-restart-with-empty-text-button'),
                  onPressed: () => Navigator.of(context).pop(
                    _ExistingVoiceTextChoice.restart,
                  ),
                  icon: const Icon(Icons.refresh_outlined),
                  label: const Text('지우고 다시 입력'),
                ),
                const SizedBox(height: 4),
                TextButton(
                  key: const ValueKey('voice-keep-existing-text-button'),
                  onPressed: () => Navigator.of(context).pop(
                    _ExistingVoiceTextChoice.cancel,
                  ),
                  child: const Text('취소하고 현재 내용 유지'),
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
    _lastProgrammaticTranscript = nextText.isEmpty ? null : nextText;
    _isApplyingTranscriptProgrammatically = false;
    _scheduleDraftPreparation(nextText);
  }

  String _mergeVoiceTranscript(String prefix, String nextText) {
    final base = prefix.trim();
    final next = SttService.normalizeVoiceTranscript(nextText).trim();
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
    return SttService.mergeTranscriptSegment(base, next);
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

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) {
          unawaited(_handleBackNavigation());
        }
      },
      child: Scaffold(
        resizeToAvoidBottomInset: true,
        appBar: AppBar(
          title: Text(l10n.voiceInputTitle),
          leading: IconButton(
            tooltip: '뒤로가기',
            icon: const Icon(Icons.arrow_back),
            onPressed: () => unawaited(_handleBackNavigation()),
          ),
        ),
        bottomNavigationBar: _VoiceBottomControls(
          isListening: _isListening,
          hasText: _rawTextController.text.trim().isNotEmpty,
          statusMessage: _statusMessage ?? _analysisStatusMessage,
          onCancel: _cancelVoiceFlow,
          onUndo: _undoLastSegment,
          onClear: _clearTranscript,
          onManualSubmit: _confirmManualText,
          onHome: () => unawaited(
            _exitVoiceInput(() => context.go(AppRoutes.home)),
          ),
          onCalendar: () => unawaited(
            _exitVoiceInput(() => context.go(AppRoutes.calendar)),
          ),
          onSettings: () => unawaited(
            _exitVoiceInput(() => context.go(AppRoutes.settings)),
          ),
        ),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(AppConstants.defaultPadding),
            child: ResponsiveContent(
              maxWidth: context.planflowWindowInfo.contentMaxWidth,
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
                    onTapStart: _handleVoiceStartPressed,
                    onTapFinish: _finishVoiceFlow,
                    onManualSubmit: _confirmManualText,
                  ),
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
      ),
    );
  }
}

enum _VoiceCommandAction { add, edit, delete, query, choose }

enum _AmbiguousFieldAdditionChoice { updateExisting, createNew, editText }

enum _ExistingVoiceTextChoice { append, restart, cancel }

class _VoiceCommandGuide extends StatelessWidget {
  const _VoiceCommandGuide({required this.theme});

  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    final l10n = appL10n(context);
    final isKorean = l10n.localeName == 'ko';
    final bullets = isKorean
        ? const <String>[
            '예) "매주 화요일 오전 10시 강남역에서 팀장님 면접 준비"',
            '기본: 앞 시간=일정 시각 · 나머지=제목 · 장소·반복도 함께',
            '일정: "5월 10일 하루종일 휴가" / "매주 화요일 팀 미팅"',
            '수정/조회: "그 일정 다음주로 변경해" / "오늘 일정 알려줘"',
            '제어: 다시=전체삭제 · 아니=교정 · 마지막삭제=일부삭제 · 취소=종료',
          ]
        : const <String>[
            'e.g. "Team meeting at Gangnam Station every Tuesday at 10 AM"',
            'Basic: leading time=when · rest=title · add place & repeat freely',
            'Event: "Vacation all day May 10" / "Team meeting every Tuesday"',
            'Edit/Query: "Move that to next week" / "Show today\'s schedule"',
            'Control: start over=clear · no=correct · delete last=undo · stop=exit',
          ];
    final compactBullets = isKorean
        ? const <String>[
            '예) "매주 화요일 오전 10시 강남역에서 팀장님 면접 준비"',
            '제어: 다시=전체삭제 · 아니=교정 · 마지막삭제=일부삭제 · 취소=종료',
          ]
        : const <String>[
            'e.g. "Team meeting at Gangnam Station every Tuesday at 10 AM"',
            'Control: start over=clear · no=correct · delete last=undo · stop=exit',
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
    final voiceLabel = isListening
        ? l10n.voiceDone
        : hasText
            ? '음성으로 다시 입력하기'
            : l10n.voicePrimaryStart;
    final voiceButton = FilledButton.icon(
      key: const ValueKey('voice-primary-button'),
      onPressed: isListening ? onTapFinish : onTapStart,
      icon: Icon(isListening ? Icons.check : Icons.mic),
      label: FittedBox(
        fit: BoxFit.scaleDown,
        child: Text(voiceLabel),
      ),
      style: isListening ? null : _tertiaryAccentButtonStyle(),
    );

    if (isListening) {
      return SizedBox(width: double.infinity, child: voiceButton);
    }

    return Row(
      children: [
        Expanded(child: voiceButton),
        const SizedBox(width: 8),
        Expanded(
          child: FilledButton.icon(
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

  ButtonStyle _tertiaryAccentButtonStyle() {
    return FilledButton.styleFrom(
      backgroundColor: PlanFlowColors.tertiaryAccent,
      foregroundColor: Colors.white,
      disabledBackgroundColor:
          PlanFlowColors.tertiaryAccent.withValues(alpha: 0.42),
      disabledForegroundColor: Colors.white.withValues(alpha: 0.88),
      side: const BorderSide(color: PlanFlowColors.tertiaryAccent),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
      textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w800),
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
    final mediaQuery = MediaQuery.of(context);
    final bottomInset =
        mediaQuery.viewInsets.bottom > 0 ? 8.0 : mediaQuery.viewPadding.bottom;
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
          key: const ValueKey('voice-bottom-home-tab'),
          icon: const Icon(Icons.home_outlined),
          selectedIcon: const Icon(Icons.home),
          label: l10n.homeTab,
        ),
        NavigationDestination(
          key: const ValueKey('voice-bottom-calendar-tab'),
          icon: const Icon(Icons.calendar_month_outlined),
          selectedIcon: const Icon(Icons.calendar_month),
          label: l10n.calendarTab,
        ),
        NavigationDestination(
          key: const ValueKey('voice-bottom-settings-tab'),
          icon: const Icon(Icons.settings_outlined),
          selectedIcon: const Icon(Icons.settings),
          label: l10n.settingsTab,
        ),
      ],
    );
  }
}
