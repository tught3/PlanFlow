import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/constants.dart';
import '../../core/theme.dart';
import '../../services/gpt_service.dart';
import '../../services/stt_service.dart';

class VoiceInputScreen extends StatefulWidget {
  VoiceInputScreen({
    super.key,
    this.sttService = const SttService(),
    GptService? gptService,
  }) : gptService = gptService ?? GptService();

  final SttService sttService;
  final GptService gptService;

  @override
  State<VoiceInputScreen> createState() => _VoiceInputScreenState();
}

class _VoiceInputScreenState extends State<VoiceInputScreen> {
  final TextEditingController _rawTextController = TextEditingController();
  final FocusNode _rawTextFocusNode = FocusNode();
  final ScrollController _scrollController = ScrollController();
  bool _isListening = false;
  bool _isParsing = false;
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
                '기기 음성 엔진이 잠깐 멈췄지만 계속 듣는 중이에요. 완료 버튼을 누르면 그때 일정 확인으로 넘어갑니다.';
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
        _statusMessage =
            result.message ?? '음성 인식 결과를 확인할 수 없어요. 직접 입력으로 계속해 주세요.';
      });
      _focusManualInput();
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _statusMessage = '음성 인식을 처리하지 못했어요. 아래에 직접 입력해도 바로 이어갈 수 있어요.';
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
      _statusMessage = '음성 입력을 취소했어요. 다시 받아쓰거나 직접 입력으로 이어갈 수 있어요.';
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
          ? '입력 내용을 비웠어요. 다시 말하거나 직접 입력해 주세요.'
          : '마지막 말을 지웠어요.';
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

    if (mounted) {
      setState(() {
        _isParsing = true;
        _statusMessage = null;
      });
    }

    try {
      final parsed = await widget.gptService.parseSchedule(rawText);
      if (!mounted) {
        return;
      }
      _openConfirm(<String, dynamic>{
        ...parsed,
        'raw_text': parsed['raw_text'] ?? rawText,
      });
    } catch (_) {
      if (!mounted) {
        return;
      }
      _openConfirm(<String, dynamic>{
        'title': '',
        'memo': rawText,
        'raw_text': rawText,
        'parse_failed': true,
      });
    } finally {
      if (mounted) {
        setState(() {
          _isParsing = false;
        });
      }
    }
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
                '말한 내용을 바로 저장해도 되고, 직접 입력해서 확인 화면으로 이어가도 돼요.',
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
                            ? '온디바이스 한국어 인식으로 듣는 중이에요.'
                            : '온디바이스 한국어 인식이 가능하면 음성으로 바로 받아쓸 수 있어요.',
                        style: theme.textTheme.titleSmall?.copyWith(
                          color: PlanFlowColors.primary,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        _isListening
                            ? '중간에 잠깐 멈춰도 완료 버튼을 누르기 전까지는 아래 원문이 계속 유지돼요.'
                            : '안 되면 아래 직접 입력 칸에 바로 적어서 이어가면 됩니다.',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: PlanFlowColors.textSecondary,
                        ),
                      ),
                      if (_isListening) ...[
                        const SizedBox(height: 8),
                        Text(
                          _sttRestartCount == 0
                              ? '말을 마친 뒤 아래 완료 버튼을 눌러 확정해 주세요.'
                              : '음성 엔진 재연결 $_sttRestartCount회. 인식된 문장은 아래 입력칸에 계속 유지됩니다.',
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
              Text(
                '음성 원문 / 직접 입력',
                style: theme.textTheme.titleSmall?.copyWith(
                  color: PlanFlowColors.primary,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _rawTextController,
                focusNode: _rawTextFocusNode,
                maxLines: 5,
                decoration: const InputDecoration(
                  hintText: '입력해주세요',
                  border: OutlineInputBorder(),
                ),
              ),
              if (_recognizedText != null) ...[
                const SizedBox(height: 12),
                Text(
                  '인식 결과: $_recognizedText',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: PlanFlowColors.textSecondary,
                  ),
                ),
              ],
              if (_statusMessage != null) ...[
                const SizedBox(height: 12),
                Card(
                  color: theme.colorScheme.errorContainer,
                  elevation: 0,
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(
                      _statusMessage!,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onErrorContainer,
                      ),
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 20),
              FilledButton.icon(
                onPressed: _isListening ? null : _startVoiceFlow,
                icon: _isListening
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.mic),
                label: Text(
                  _isListening
                      ? '받아쓰는 중'
                      : _rawTextController.text.trim().isEmpty
                          ? '음성으로 일정 입력하기'
                          : '다시 말하기',
                ),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                alignment: WrapAlignment.center,
                children: [
                  OutlinedButton.icon(
                    onPressed: _undoLastSegment,
                    icon: const Icon(Icons.undo),
                    label: const Text('마지막 단어 삭제'),
                  ),
                  OutlinedButton.icon(
                    onPressed:
                        _rawTextController.text.trim().isEmpty && !_isListening
                            ? null
                            : _clearTranscript,
                    icon: const Icon(Icons.delete_outline),
                    label: const Text('전체 지우기'),
                  ),
                ],
              ),
              if (_isListening) ...[
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: _finishVoiceFlow,
                  icon: const Icon(Icons.check_circle_outline),
                  label: const Text('완료하고 일정 확인'),
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: _cancelVoiceFlow,
                  icon: const Icon(Icons.close),
                  label: const Text('취소'),
                ),
              ],
              const SizedBox(height: 12),
              FilledButton.tonalIcon(
                onPressed: (_isListening || _isParsing)
                    ? null
                    : () => _continueWithRawText(),
                icon: _isParsing
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.edit_note),
                label: Text(_isParsing ? '정리 중' : '직접 입력으로 확인'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _VoiceCommandGuide extends StatelessWidget {
  const _VoiceCommandGuide({required this.theme});

  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 0,
      color: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: const BorderSide(
          color: Color.fromRGBO(61, 72, 143, 0.22),
          width: 1,
        ),
      ),
      child: Theme(
        data: theme.copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding: const EdgeInsets.symmetric(horizontal: 14),
          childrenPadding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
          leading: const Icon(
            Icons.record_voice_over_outlined,
            color: PlanFlowColors.primary,
          ),
          title: Text(
            '말로 수정하기',
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w800,
              color: PlanFlowColors.textPrimary,
            ),
          ),
          subtitle: Text(
            '잘못 말했을 때 아래처럼 말하면 바로 정리돼요.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: PlanFlowColors.textSecondary,
            ),
          ),
          children: const [
            _VoiceCommandRow(
              command: '아니, 아니야, 아니요',
              description: '마지막 단어 지우기',
            ),
            _VoiceCommandRow(
              command: '마지막 거 지워, 방금 거 지워',
              description: '마지막 말 조각 지우기',
            ),
            _VoiceCommandRow(
              command: '다시, 처음부터, 다시 말할게',
              description: '전체 입력 지우기',
            ),
            _VoiceCommandRow(
              command: '취소',
              description: '음성 입력 취소',
            ),
          ],
        ),
      ),
    );
  }
}

class _VoiceCommandRow extends StatelessWidget {
  const _VoiceCommandRow({
    required this.command,
    required this.description,
  });

  final String command;
  final String description;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(
            Icons.check_circle_outline,
            size: 18,
            color: PlanFlowColors.active,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  command,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: PlanFlowColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  description,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: PlanFlowColors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
        ],
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
      selectedIndex: 1,
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
          icon: Icon(Icons.event_note_outlined),
          selectedIcon: Icon(Icons.event_note),
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
