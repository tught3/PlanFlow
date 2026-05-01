import 'dart:async';

import 'package:speech_to_text/speech_to_text.dart';

class SttService {
  const SttService();

  static const String _koreanLocaleId = 'ko_KR';
  static const Duration _listenFor = Duration(seconds: 15);
  static const Duration _pauseFor = Duration(seconds: 2);

  Future<String?> listen() async {
    final speech = SpeechToText();
    final available = await speech.initialize(debugLogging: false);
    if (!available) {
      return null;
    }

    final completer = Completer<String?>();

    void complete(String? text) {
      if (!completer.isCompleted) {
        final normalized = text?.trim();
        completer.complete(
          normalized == null || normalized.isEmpty ? null : normalized,
        );
      }
    }

    try {
      await speech.listen(
        localeId: _koreanLocaleId,
        listenFor: _listenFor,
        pauseFor: _pauseFor,
        listenOptions: SpeechListenOptions(
          onDevice: true,
          partialResults: true,
          cancelOnError: true,
          listenMode: ListenMode.dictation,
        ),
        onResult: (result) {
          if (result.finalResult) {
            complete(result.recognizedWords);
          }
        },
      );

      return await completer.future.timeout(
        _listenFor + const Duration(seconds: 5),
        onTimeout: () async {
          await speech.cancel();
          return null;
        },
      );
    } catch (_) {
      return null;
    } finally {
      if (speech.isListening) {
        await speech.stop();
      } else {
        await speech.cancel();
      }
    }
  }
}
