import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/constants.dart';
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
          _error = 'No speech was recognized. Try again in a quieter place.';
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
      context.go(AppRoutes.confirm, extra: parsed);
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _error =
            'Voice parsing failed. You can try again or enter it manually.';
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
      appBar: AppBar(title: const Text('Voice Input')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(AppConstants.defaultPadding),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                width: _isListening ? 132 : 112,
                height: _isListening ? 132 : 112,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: _isListening
                      ? theme.colorScheme.primaryContainer
                      : theme.colorScheme.surfaceContainerHighest,
                ),
                child: Icon(
                  _isListening ? Icons.graphic_eq : Icons.mic,
                  size: 56,
                  color: theme.colorScheme.primary,
                ),
              ),
              const SizedBox(height: 24),
              Text(
                _isListening
                    ? 'Listening on device...'
                    : 'Tap the mic and speak your schedule.',
                style: theme.textTheme.titleMedium,
                textAlign: TextAlign.center,
              ),
              if (_recognizedText != null) ...[
                const SizedBox(height: 16),
                Text(
                  _recognizedText!,
                  textAlign: TextAlign.center,
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
                label: Text(_isListening ? 'Processing' : 'Start voice input'),
              ),
              const SizedBox(height: 12),
              TextButton(
                onPressed:
                    _isListening ? null : () => context.go(AppRoutes.confirm),
                child: const Text('Enter manually'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
