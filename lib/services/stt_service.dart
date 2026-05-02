import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:speech_to_text/speech_to_text.dart';

enum SttListenFailure {
  unsupportedLocale,
  permissionDenied,
  silence,
  unavailable,
}

class SttListenResult {
  const SttListenResult._({
    this.text,
    this.failure,
    this.message,
  });

  factory SttListenResult.success(String text) {
    return SttListenResult._(text: text.trim());
  }

  factory SttListenResult.failure({
    required SttListenFailure failure,
    required String message,
    String? text,
  }) {
    return SttListenResult._(
      text: text?.trim(),
      failure: failure,
      message: message,
    );
  }

  final String? text;
  final SttListenFailure? failure;
  final String? message;

  bool get hasText => text != null && text!.trim().isNotEmpty;
  bool get isSuccess => failure == null && hasText;
}

class SttService {
  const SttService();

  static const String _koreanLocaleId = 'ko_KR';
  static const Duration _listenFor = Duration(seconds: 15);
  static const Duration _pauseFor = Duration(seconds: 2);

  static String? resolveKoreanLocaleId(Iterable<String> localeIds) {
    if (localeIds.contains(_koreanLocaleId)) {
      return _koreanLocaleId;
    }
    for (final localeId in localeIds) {
      if (localeId.toLowerCase().startsWith('ko')) {
        return localeId;
      }
    }
    return null;
  }

  @visibleForTesting
  static SpeechListenOptions buildListenOptions() {
    return SpeechListenOptions(
      onDevice: true,
      partialResults: true,
      cancelOnError: false,
      listenMode: ListenMode.dictation,
    );
  }

  Future<SttListenResult> listen() async {
    final speech = SpeechToText();
    final completer = Completer<SttListenResult>();
    String? latestRecognizedText;
    var hasStartedListening = false;

    void completeSuccess([String? text]) {
      if (completer.isCompleted) {
        return;
      }

      final normalized = (text ?? latestRecognizedText)?.trim();
      if (normalized == null || normalized.isEmpty) {
        completer.complete(
          SttListenResult.failure(
            failure: SttListenFailure.silence,
            message: _silenceMessage,
            text: latestRecognizedText,
          ),
        );
        return;
      }
      completer.complete(SttListenResult.success(normalized));
    }

    void completeFailure({
      required SttListenFailure failure,
      required String message,
    }) {
      if (!completer.isCompleted) {
        completer.complete(
          SttListenResult.failure(
            failure: failure,
            message: message,
            text: latestRecognizedText,
          ),
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
            completeSuccess();
          }
        },
        onError: (error) {
          if (error.errorMsg == 'error_no_match' ||
              error.errorMsg == 'error_speech_timeout') {
            completeSuccess();
            return;
          }

          if (error.errorMsg == 'error_permission' ||
              error.errorMsg == 'error_client') {
            completeFailure(
              failure: SttListenFailure.permissionDenied,
              message: _permissionMessage,
            );
            return;
          }

          if (error.errorMsg == 'error_language_not_supported' ||
              error.errorMsg == 'error_language_unavailable') {
            completeFailure(
              failure: SttListenFailure.unsupportedLocale,
              message: _unsupportedLocaleMessage,
            );
            return;
          }

          if (error.permanent) {
            completeFailure(
              failure: SttListenFailure.unavailable,
              message: _genericMessage,
            );
          }
        },
      );
      if (!available) {
        final hasPermission = await speech.hasPermission;
        return SttListenResult.failure(
          failure: hasPermission
              ? SttListenFailure.unavailable
              : SttListenFailure.permissionDenied,
          message: hasPermission ? _genericMessage : _permissionMessage,
        );
      }

      final locales = await speech.locales();
      final localeId = resolveKoreanLocaleId(
        locales.map((locale) => locale.localeId),
      );
      if (localeId == null) {
        return SttListenResult.failure(
          failure: SttListenFailure.unsupportedLocale,
          message: _unsupportedLocaleMessage,
        );
      }

      await speech.listen(
        localeId: localeId,
        listenFor: _listenFor,
        pauseFor: _pauseFor,
        listenOptions: buildListenOptions(),
        onResult: (result) {
          final recognizedWords = result.recognizedWords.trim();
          if (recognizedWords.isNotEmpty) {
            latestRecognizedText = recognizedWords;
          }
          if (result.finalResult) {
            completeSuccess(recognizedWords);
          }
        },
      );

      return await completer.future.timeout(
        _listenFor + const Duration(seconds: 5),
        onTimeout: () async {
          await speech.cancel();
          final normalized = latestRecognizedText?.trim();
          if (normalized == null || normalized.isEmpty) {
            return SttListenResult.failure(
              failure: SttListenFailure.silence,
              message: _silenceMessage,
            );
          }
          return SttListenResult.success(normalized);
        },
      );
    } catch (_) {
      return SttListenResult.failure(
        failure: SttListenFailure.unavailable,
        message: _genericMessage,
        text: latestRecognizedText,
      );
    } finally {
      if (speech.isListening) {
        await speech.stop();
      } else {
        await speech.cancel();
      }
    }
  }
}

const String _unsupportedLocaleMessage =
    '이 기기에서는 온디바이스 한국어 음성 인식을 사용할 수 없어요. 직접 입력으로 이어가 주세요.';
const String _permissionMessage =
    '마이크 권한이 없어요. 설정에서 권한을 허용한 뒤 다시 시도하거나 직접 입력으로 이어가 주세요.';
const String _silenceMessage = '음성이 인식되지 않았어요. 조금 더 크게 말하거나 직접 입력으로 이어가 주세요.';
const String _genericMessage = '음성 입력을 시작하지 못했어요. 직접 입력으로 이어가 주세요.';
