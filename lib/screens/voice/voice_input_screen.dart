import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/constants.dart';
import '../../core/theme.dart';
import '../../services/stt_service.dart';

class VoiceInputScreen extends StatefulWidget {
  const VoiceInputScreen({
    super.key,
    this.sttService = const SttService(),
  });

  final SttService sttService;

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

  @override
  void initState() {
    super.initState();
    _rawTextController.addListener(_handleRawTextChanged);
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
    if (!mounted) {
      return;
    }
    setState(() {});
  }

  Future<void> _startVoiceFlow() async {
    setState(() {
      _isListening = true;
      _recognizedText = null;
      _sttRestartCount = 0;
      _statusMessage = null;
    });

    try {
      final result = await widget.sttService.listen(
        onPartialResult: (text) {
          if (!mounted) {
            return;
          }
          _setTranscriptText(text);
        },
        onRestart: (count) {
          if (!mounted) {
            return;
          }
          setState(() {
            _sttRestartCount = count;
            _statusMessage =
                '음성 인식이 이어지는 중이에요. 완료 버튼을 누를 때까지 계속 이어서 말해도 됩니다.';
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
        await _continueWithRawText();
        return;
      }

      setState(() {
        _statusMessage = result.message ??
            '음성 인식 결과를 확인하지 못했어요. 직접 입력으로 이어가 주세요.';
      });
      _focusManualInput();
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _statusMessage = '음성 인식을 처리하지 못했어요. 아래 직접 입력으로 이어갈 수 있어요.';
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
    if (!_isListening) {
      return;
    }
    await widget.sttService.stopActiveListen();
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
      _statusMessage = '음성 입력을 취소했어요. 다시 시작할 수 있어요.';
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
          ? '입력 내용이 비었어요. 다시 말하거나 직접 입력해 주세요.'
          : '마지막 입력을 지웠어요.';
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
      _openConfirm(const <String, dynamic>{});
      return;
    }

    final commandAction = _detectCommandAction(rawText);
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
    final deletePattern = RegExp(r'(삭제|지워|지워줘|지워줘요|지우기|없애)');
    final editPattern = RegExp(r'(수정|바꿔|바꿔줘|고쳐|고쳐줘|변경|변경해줘|다시 말할게)');
    final queryPattern = RegExp(r'(조회|알려줘|보여줘|뭐야|몇 시|언제|일정 있어|일정있어)');
    final addPattern = RegExp(r'(추가|등록|만들어|잡아줘|예약|기록)');

    if (deletePattern.hasMatch(normalized)) {
      return _VoiceCommandAction.delete;
    }
    if (editPattern.hasMatch(normalized)) {
      return _VoiceCommandAction.edit;
    }
    if (queryPattern.hasMatch(normalized)) {
      return _VoiceCommandAction.query;
    }
    if (addPattern.hasMatch(normalized)) {
      return _VoiceCommandAction.add;
    }
    return _VoiceCommandAction.choose;
  }

  void _openConfirm(Map<String, dynamic> parsedSchedule) {
    context.push(AppRoutes.confirm, extra: parsedSchedule);
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
          child: ListView(
            controller: _scrollController,
            children: [
              Text(
                '말한 내용을 먼저 확인하고, 직접 입력으로도 바로 수정할 수 있어요.',
                style: theme.textTheme.titleMedium?.copyWith(
                  color: PlanFlowColors.primary,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: AppConstants.sectionSpacing),
              _VoiceCommandGuide(theme: theme),
              const SizedBox(height: 12),
              Card(
                elevation: 0,
                color: PlanFlowColors.surface,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                  side: const BorderSide(
                    color: PlanFlowColors.primaryFaint,
                    width: 0.5,
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _isListening
                            ? '온디바이스 음성으로 듣는 중이에요.'
                            : '음성 입력이 가능하면 아래 버튼으로 시작해 주세요.',
                        style: theme.textTheme.titleSmall?.copyWith(
                          color: PlanFlowColors.primary,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        _isListening
                            ? '완료 버튼을 누를 때까지 계속 이어서 말해도 됩니다.'
                            : '말하다가 틀리면 마지막 단어 삭제나 전체 지우기로 다시 정리할 수 있어요.',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: PlanFlowColors.textSecondary,
                        ),
                      ),
                      if (_isListening) ...[
                        const SizedBox(height: 8),
                        Text(
                          _sttRestartCount == 0
                              ? '음성 인식이 시작됐어요.'
                              : '음성 인식이 다시 이어졌어요 ($_sttRestartCount).',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: PlanFlowColors.textSecondary,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              _VoiceTranscriptSection(
                isListening: _isListening,
                recognizedText: _recognizedText,
                controller: _rawTextController,
                focusNode: _rawTextFocusNode,
                onManualSubmit: _continueWithRawText,
                onTapStart: _startVoiceFlow,
              ),
              const SizedBox(height: 16),
              _VoiceActionButtons(
                isListening: _isListening,
                hasText: _rawTextController.text.trim().isNotEmpty,
                onStart: _startVoiceFlow,
                onFinish: _finishVoiceFlow,
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
    );
  }
}

enum _VoiceCommandAction { add, edit, delete, query, choose }

class _VoiceCommandGuide extends StatelessWidget {
  const _VoiceCommandGuide({required this.theme});

  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    final bullets = <String>[
      '추가: "내일 오전 9시 미팅 추가"',
      '수정: "한강 피크닉 오전 10시로 수정해줘"',
      '삭제: "오후 3시 회의 삭제해줘"',
      '조회: "오늘 일정 보여줘"',
      '수정/삭제가 헷갈리면 먼저 선택 후 확인 화면이 열려요.',
    ];

    return Card(
      elevation: 0,
      color: PlanFlowColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: const BorderSide(
          color: PlanFlowColors.primaryFaint,
          width: 0.5,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '말로 수정하기 안내',
              style: theme.textTheme.titleSmall?.copyWith(
                color: PlanFlowColors.primary,
                fontWeight: FontWeight.w700,
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
          ],
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
  });

  final bool isListening;
  final String? recognizedText;
  final TextEditingController controller;
  final FocusNode focusNode;
  final VoidCallback onManualSubmit;
  final VoidCallback onTapStart;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      elevation: 0,
      color: PlanFlowColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: const BorderSide(
          color: PlanFlowColors.primaryFaint,
          width: 0.5,
        ),
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
              decoration: const InputDecoration(
                hintText: '입력해주세요',
              ),
              onSubmitted: (_) => onManualSubmit(),
            ),
            const SizedBox(height: 10),
            if (recognizedText != null)
              Text(
                isListening ? '계속 듣는 중이에요.' : '방금 인식한 내용이에요.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: PlanFlowColors.textSecondary,
                ),
              ),
            const SizedBox(height: 8),
            FilledButton.icon(
              onPressed: onTapStart,
              icon: const Icon(Icons.mic),
              label: const Text('음성으로 일정 입력하기'),
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
    required this.onStart,
    required this.onFinish,
    required this.onCancel,
    required this.onUndo,
    required this.onClear,
    required this.onManualSubmit,
  });

  final bool isListening;
  final bool hasText;
  final VoidCallback onStart;
  final VoidCallback onFinish;
  final VoidCallback onCancel;
  final VoidCallback onUndo;
  final VoidCallback onClear;
  final VoidCallback onManualSubmit;

  @override
  Widget build(BuildContext context) {
    final buttons = <Widget>[
      FilledButton(
        onPressed: isListening ? onFinish : onStart,
        child: Text(isListening ? '완료' : '음성 시작'),
      ),
      OutlinedButton(
        onPressed: hasText ? onClear : null,
        child: const Text('전체 지우기'),
      ),
      OutlinedButton(
        onPressed: hasText ? onUndo : null,
        child: const Text('마지막 단어 삭제'),
      ),
      OutlinedButton(
        onPressed: hasText ? onManualSubmit : null,
        child: const Text('직접 입력으로'),
      ),
    ];

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: buttons,
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
        border: Border.all(
          color: PlanFlowColors.primaryFaint,
          width: 0.5,
        ),
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
