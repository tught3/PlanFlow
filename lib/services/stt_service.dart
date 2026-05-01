import 'dart:async';

import 'package:speech_to_text/speech_to_text.dart';

class SttService {
  const SttService();

  static const String _koreanLocaleId = 'ko_KR';
  static const Duration _listenFor = Duration(seconds: 15);
  static const Duration _pauseFor = Duration(seconds: 2);

  Future<String?> listen() async {
    final speech = SpeechToText();
    final completer = Completer<String?>();
    String? latestRecognizedText;
    var hasStartedListening = false;

    void complete([String? text]) {
      if (!completer.isCompleted) {
        final normalized = (text ?? latestRecognizedText)?.trim();
        completer.complete(
          normalized == null || normalized.isEmpty ? null : normalized,
        );
      }
    }

    try {
      final available = await speech.initialize(
        debugLogging: false,
        onStatus: (status) {
          if (status == SpeechToText.listeningStatus) {
            hasStartedListening = true;
          } else if (hasStartedListening &&
              (status == SpeechToText.doneStatus ||
                  status == SpeechToText.notListeningStatus)) {
            complete();
          }
        },
        onError: (error) {
          if (error.permanent || error.errorMsg == 'error_no_match') {
            complete();
          }
        },
      );
      if (!available) {
        return null;
      }

      final locales = await speech.locales();
      final localeId =
          locales.any((locale) => locale.localeId == _koreanLocaleId)
              ? _koreanLocaleId
              : null;

      await speech.listen(
        localeId: localeId,
        listenFor: _listenFor,
        pauseFor: _pauseFor,
        listenOptions: SpeechListenOptions(
          onDevice: false,
          partialResults: true,
          cancelOnError: false,
          listenMode: ListenMode.dictation,
        ),
        onResult: (result) {
          final recognizedWords = result.recognizedWords.trim();
          if (recognizedWords.isNotEmpty) {
            latestRecognizedText = recognizedWords;
          }
          if (result.finalResult) {
            complete(recognizedWords);
          }
        },
      );

      return await completer.future.timeout(
        _listenFor + const Duration(seconds: 5),
        onTimeout: () async {
          await speech.cancel();
          final normalized = latestRecognizedText?.trim();
          return normalized == null || normalized.isEmpty ? null : normalized;
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
