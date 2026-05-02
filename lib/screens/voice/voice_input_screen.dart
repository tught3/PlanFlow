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
    final rawText = _rawTextController.text.trim();
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
              Center(
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 220),
                  width: _isListening ? 136 : 116,
                  height: _isListening ? 136 : 116,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _isListening ? PlanFlowColors.active : Colors.white,
                    border: Border.all(
                      color: _isListening
                          ? PlanFlowColors.activeLight
                          : PlanFlowColors.primaryFaint,
                      width: 0.5,
                    ),
                  ),
                  child: Icon(
                    _isListening ? Icons.graphic_eq : Icons.mic,
                    size: 56,
                    color: _isListening ? Colors.white : PlanFlowColors.fab,
                  ),
                ),
              ),
              const SizedBox(height: 20),
              Text(
                _isListening
                    ? '계속 듣는 중이에요. 중간에 소리가 나도 완료 전에는 확인 화면으로 넘어가지 않습니다.'
                    : '온디바이스 한국어 인식이 안 되면 아래에 직접 입력해도 됩니다.',
                style: theme.textTheme.titleMedium,
                textAlign: TextAlign.center,
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
                  textAlign: TextAlign.center,
                ),
              ],
              const SizedBox(height: 20),
              TextField(
                controller: _rawTextController,
                focusNode: _rawTextFocusNode,
                maxLines: 5,
                decoration: const InputDecoration(
                  labelText: '음성 원문 / 직접 입력',
                  hintText: '예: 내일 오후 3시 강남역 미팅 준비물 노트북, 충전기',
                  helperText: '음성이 끊겨도 여기서 바로 고쳐서 이어갈 수 있어요.',
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
                          ? '음성으로 받아쓰기'
                          : '다시 말하기',
                ),
              ),
              if (_isListening) ...[
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  alignment: WrapAlignment.center,
                  children: [
                    OutlinedButton.icon(
                      onPressed: _undoLastSegment,
                      icon: const Icon(Icons.undo),
                      label: const Text('마지막 말 지우기'),
                    ),
                    OutlinedButton.icon(
                      onPressed: _clearTranscript,
                      icon: const Icon(Icons.delete_outline),
                      label: const Text('전체 지우기'),
                    ),
                  ],
                ),
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
              if (!_isListening) ...[
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  alignment: WrapAlignment.center,
                  children: [
                    OutlinedButton.icon(
                      onPressed: _rawTextController.text.trim().isEmpty
                          ? null
                          : _clearTranscript,
                      icon: const Icon(Icons.delete_outline),
                      label: const Text('전체 지우기'),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
              ],
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
                label: Text(_isParsing ? '정리 중' : '직접 입력으로 확인 화면 열기'),
              ),
            ],
          ),
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
