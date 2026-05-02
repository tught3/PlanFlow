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
  bool _isListening = false;
  String? _recognizedText;
  String? _error;

  Future<void> _startVoiceFlow() async {
    setState(() {
      _isListening = true;
      _recognizedText = null;
      _error = null;
    });

    try {
      final text = await widget.sttService.listen();
      if (!mounted) {
        return;
      }
      if (text == null || text.trim().isEmpty) {
        setState(() {
          _error = '음성이 인식되지 않았어요. 조금 더 조용한 곳에서 다시 시도해 주세요.';
          _isListening = false;
        });
        return;
      }

      setState(() {
        _recognizedText = text;
      });
      final parsed = await widget.gptService.parseSchedule(text);
      if (!mounted) {
        return;
      }
      context.push(AppRoutes.confirm, extra: parsed);
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _error = '음성 내용을 일정으로 바꾸지 못했어요. 다시 시도하거나 직접 입력해 주세요.';
      });
    } finally {
      if (mounted) {
        setState(() {
          _isListening = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('음성 입력')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(AppConstants.defaultPadding),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                '일정 음성 입력',
                style: theme.textTheme.labelLarge,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 10),
              AnimatedContainer(
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
              const SizedBox(height: 24),
              Text(
                _isListening ? '기기에서 음성을 듣고 있어요.' : '마이크를 누르고 일정을 말해주세요.',
                style: theme.textTheme.titleMedium,
                textAlign: TextAlign.center,
              ),
              if (_recognizedText != null) ...[
                const SizedBox(height: 16),
                Text(
                  _recognizedText!,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyLarge,
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: 16),
                Text(
                  _error!,
                  style: TextStyle(color: theme.colorScheme.error),
                  textAlign: TextAlign.center,
                ),
              ],
              const SizedBox(height: 32),
              FilledButton.icon(
                onPressed: _isListening ? null : _startVoiceFlow,
                icon: _isListening
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.mic),
                label: Text(_isListening ? '처리 중' : '음성 입력 시작'),
              ),
              const SizedBox(height: 12),
              TextButton(
                onPressed:
                    _isListening ? null : () => context.push(AppRoutes.confirm),
                child: const Text('직접 입력하기'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
