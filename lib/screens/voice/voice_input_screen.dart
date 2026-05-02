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
  bool _isListening = false;
  bool _isParsing = false;
  String? _recognizedText;
  String? _statusMessage;

  @override
  void dispose() {
    _rawTextController.dispose();
    super.dispose();
  }

  Future<void> _startVoiceFlow() async {
    setState(() {
      _isListening = true;
      _recognizedText = null;
      _statusMessage = null;
    });

    try {
      final result = await widget.sttService.listen();
      if (!mounted) {
        return;
      }

      if (result.hasText) {
        setState(() {
          _recognizedText = result.text;
          _rawTextController.text = result.text ?? '';
        });
      }

      if (result.isSuccess) {
        await _continueWithRawText();
        return;
      }

      setState(() {
        _statusMessage =
            result.message ?? '음성 인식 결과를 확인할 수 없어요. 직접 입력으로 계속해 주세요.';
      });
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _statusMessage = '음성 인식을 처리하지 못했어요. 아래에 직접 입력해도 바로 이어갈 수 있어요.';
      });
    } finally {
      if (mounted) {
        setState(() {
          _isListening = false;
        });
      }
    }
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('음성 입력')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(AppConstants.defaultPadding),
          child: ListView(
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
                    ? '지금 말하는 내용을 받아쓰는 중이에요.'
                    : '온디바이스 한국어 인식이 안 되면 아래에 직접 입력해도 됩니다.',
                style: theme.textTheme.titleMedium,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 20),
              TextField(
                controller: _rawTextController,
                maxLines: 5,
                decoration: const InputDecoration(
                  labelText: '음성 원문 / 직접 입력',
                  hintText: '예: 내일 오후 3시 강남역 미팅 준비물 노트북, 충전기',
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
                label: Text(_isListening ? '받아쓰는 중' : '음성으로 받아쓰기'),
              ),
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
                label: Text(_isParsing ? '정리 중' : '직접 입력으로 확인 화면 열기'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
