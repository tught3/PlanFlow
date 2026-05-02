import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
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
  static const Duration _listenFor = Duration(minutes: 15);
  static const Duration _pauseFor = Duration(seconds: 20);
  static SpeechToText? _activeSpeech;
  static Completer<SttListenResult>? _activeCompleter;
  static String? _activeRecognizedText;
  static var _userRequestedStop = false;
  static var _activeNativeListen = false;
  static const MethodChannel _nativeSttChannel =
      MethodChannel('planflow/native_stt');

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

  Future<void> stopActiveListen() async {
    _userRequestedStop = true;
    if (_activeNativeListen) {
      try {
        await _nativeSttChannel.invokeMethod<String>('stop');
      } catch (_) {
        // The fallback completion below keeps the UI responsive if Android
        // does not send a final callback after stopListening.
      }
      await Future<void>.delayed(const Duration(milliseconds: 350));
      _completeActiveListenFromText();
      return;
    }
    final speech = _activeSpeech;
    if (speech == null) {
      return;
    }
    if (speech.isListening) {
      await speech.stop();
    }
    await Future<void>.delayed(const Duration(milliseconds: 250));
    final completer = _activeCompleter;
    if (completer != null && !completer.isCompleted) {
      _completeActiveListenFromText();
    }
  }

  Future<void> cancelActiveListen() async {
    _userRequestedStop = true;
    if (_activeNativeListen) {
      try {
        await _nativeSttChannel.invokeMethod<String>('cancel');
      } catch (_) {}
      final completer = _activeCompleter;
      if (completer != null && !completer.isCompleted) {
        completer.complete(
          SttListenResult.failure(
            failure: SttListenFailure.silence,
            message: '음성 입력을 취소했어요.',
            text: _activeRecognizedText,
          ),
        );
      }
      return;
    }
    final speech = _activeSpeech;
    if (speech == null) {
      return;
    }
    await speech.cancel();
    final completer = _activeCompleter;
    if (completer != null && !completer.isCompleted) {
      completer.complete(
        SttListenResult.failure(
          failure: SttListenFailure.silence,
          message: '음성 입력을 취소했어요.',
          text: _activeRecognizedText,
        ),
      );
    }
  }

  Future<SttListenResult> listen({
    ValueChanged<String>? onPartialResult,
    ValueChanged<int>? onRestart,
  }) async {
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      final nativeResult = await _listenWithNativeAndroid(
        onPartialResult: onPartialResult,
        onRestart: onRestart,
      );
      if (nativeResult.failure != SttListenFailure.unavailable) {
        return nativeResult;
      }
    }

    final speech = SpeechToText();
    final completer = Completer<SttListenResult>();
    String? latestRecognizedText;
    String? activeSessionText;
    var hasStartedListening = false;
    var restartCount = 0;
    Future<void> Function()? startListening;
    _activeSpeech = speech;
    _activeCompleter = completer;
    _activeRecognizedText = null;
    _userRequestedStop = false;

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

    String mergeRecognizedText(String current, String incoming) {
      final trimmedCurrent = current.trim();
      final trimmedIncoming = incoming.trim();
      if (trimmedCurrent.isEmpty) {
        return trimmedIncoming;
      }
      if (trimmedIncoming.isEmpty) {
        return trimmedCurrent;
      }
      if (trimmedIncoming == trimmedCurrent) {
        return trimmedCurrent;
      }
      if (trimmedIncoming.startsWith(trimmedCurrent)) {
        return trimmedIncoming;
      }
      if (trimmedCurrent.startsWith(trimmedIncoming)) {
        return trimmedCurrent;
      }
      if (trimmedCurrent.endsWith(trimmedIncoming)) {
        return trimmedCurrent;
      }
      return '$trimmedCurrent $trimmedIncoming'.trim();
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

    String replaceTrailingSegment(
      String baseText,
      String previousSegment,
      String nextSegment,
    ) {
      final trimmedBase = baseText.trim();
      final trimmedPrevious = previousSegment.trim();
      final trimmedNext = nextSegment.trim();
      if (trimmedBase.isEmpty) {
        return trimmedNext;
      }
      if (trimmedPrevious.isEmpty) {
        return trimmedNext;
      }
      if (trimmedBase.endsWith(trimmedPrevious)) {
        return trimmedBase
                .substring(0, trimmedBase.length - trimmedPrevious.length)
                .trimRight() +
            (trimmedBase.length > trimmedPrevious.length ? ' ' : '') +
            trimmedNext;
      }
      return mergeRecognizedText(trimmedBase, trimmedNext);
    }

    void scheduleRestart(String reason) {
      if (_userRequestedStop || completer.isCompleted) {
        return;
      }
      if (restartCount >= 20) {
        completeFailure(
          failure: SttListenFailure.unavailable,
          message: _genericMessage,
        );
        return;
      }

      restartCount += 1;
      debugPrint('PlanFlow STT restart #$restartCount: $reason');
      onRestart?.call(restartCount);
      activeSessionText = null;
      unawaited(
        Future<void>.delayed(const Duration(milliseconds: 350), () async {
          if (_userRequestedStop || completer.isCompleted) {
            return;
          }
          try {
            await startListening?.call();
          } catch (error) {
            debugPrint('PlanFlow STT restart failed: $error');
            completeFailure(
              failure: SttListenFailure.unavailable,
              message: _genericMessage,
            );
          }
        }),
      );
    }

    try {
      final available = await speech.initialize(
        debugLogging: kDebugMode,
        onStatus: (status) {
          debugPrint('PlanFlow STT status: $status');
          if (status == SpeechToText.listeningStatus) {
            hasStartedListening = true;
          } else if (hasStartedListening &&
              (status == SpeechToText.doneStatus ||
                  status == SpeechToText.notListeningStatus)) {
            if (_userRequestedStop) {
              completeSuccess();
            } else {
              scheduleRestart(status);
            }
          }
        },
        onError: (error) {
          debugPrint(
            'PlanFlow STT error: ${error.errorMsg}, permanent=${error.permanent}',
          );
          if (error.errorMsg == 'error_no_match' ||
              error.errorMsg == 'error_speech_timeout') {
            if (_userRequestedStop) {
              completeSuccess();
            } else {
              scheduleRestart(error.errorMsg);
            }
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
      debugPrint(
        'PlanFlow STT locale: ${localeId ?? 'none'} / ${locales.length} locales',
      );
      if (localeId == null) {
        return SttListenResult.failure(
          failure: SttListenFailure.unsupportedLocale,
          message: _unsupportedLocaleMessage,
        );
      }

      startListening = () {
        hasStartedListening = false;
        return speech.listen(
          localeId: localeId,
          listenFor: _listenFor,
          pauseFor: _pauseFor,
          listenOptions: buildListenOptions(),
          onResult: (result) {
            final recognizedWords = result.recognizedWords.trim();
            if (recognizedWords.isNotEmpty) {
              final mergedText = activeSessionText == null
                  ? mergeRecognizedText(
                      latestRecognizedText ?? '', recognizedWords)
                  : replaceTrailingSegment(
                      latestRecognizedText ?? '',
                      activeSessionText!,
                      recognizedWords,
                    );
              activeSessionText = recognizedWords;
              latestRecognizedText = mergedText;
              _activeRecognizedText = mergedText;
              onPartialResult?.call(mergedText);
            }
            if (result.finalResult && _userRequestedStop) {
              completeSuccess(recognizedWords);
            }
          },
        );
      };
      await startListening();

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
      if (!_userRequestedStop && speech.isListening) {
        await speech.cancel();
      }
      if (identical(_activeSpeech, speech)) {
        _activeSpeech = null;
        _activeCompleter = null;
        _activeRecognizedText = null;
      }
    }
  }

  static void _completeActiveListenFromText() {
    final completer = _activeCompleter;
    if (completer == null || completer.isCompleted) {
      return;
    }
    final normalized = _activeRecognizedText?.trim();
    if (normalized == null || normalized.isEmpty) {
      completer.complete(
        SttListenResult.failure(
          failure: SttListenFailure.silence,
          message: _silenceMessage,
        ),
      );
    } else {
      completer.complete(SttListenResult.success(normalized));
    }
  }

  Future<SttListenResult> _listenWithNativeAndroid({
    ValueChanged<String>? onPartialResult,
    ValueChanged<int>? onRestart,
  }) async {
    final completer = Completer<SttListenResult>();
    final committedSegments = <String>[];
    String activeSessionText = '';
    String latestRecognizedText = '';
    var restartCount = 0;
    _activeNativeListen = true;
    _activeCompleter = completer;
    _activeRecognizedText = null;
    _userRequestedStop = false;

    void updateRecognizedText(String incomingText) {
      final recognizedWords = incomingText.trim();
      if (recognizedWords.isEmpty) {
        return;
      }
      final mergedText =
          [...committedSegments, recognizedWords].join(' ').trim();
      activeSessionText = recognizedWords;
      latestRecognizedText = mergedText;
      _activeRecognizedText = mergedText;
      onPartialResult?.call(mergedText);
    }

    void commitActiveSession() {
      final text = activeSessionText.trim();
      if (text.isEmpty) {
        return;
      }
      if (committedSegments.isEmpty || committedSegments.last != text) {
        committedSegments.add(text);
      }
      activeSessionText = '';
      latestRecognizedText = committedSegments.join(' ').trim();
      _activeRecognizedText = latestRecognizedText;
    }

    _nativeSttChannel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'partial':
          updateRecognizedText(call.arguments?.toString() ?? '');
          break;
        case 'stopped':
          updateRecognizedText(call.arguments?.toString() ?? '');
          commitActiveSession();
          _completeActiveListenFromText();
          break;
        case 'cancelled':
          if (!completer.isCompleted) {
            completer.complete(
              SttListenResult.failure(
                failure: SttListenFailure.silence,
                message: '음성 입력을 취소했어요.',
                text: latestRecognizedText,
              ),
            );
          }
          break;
        case 'error':
          if (!completer.isCompleted) {
            completer.complete(
              SttListenResult.failure(
                failure: SttListenFailure.unavailable,
                message: _genericMessage,
                text: latestRecognizedText,
              ),
            );
          }
          break;
        case 'restarted':
          restartCount += 1;
          commitActiveSession();
          onRestart?.call(restartCount);
          break;
        case 'segmentEnded':
          commitActiveSession();
          break;
      }
    });

    try {
      final started = await _nativeSttChannel.invokeMethod<bool>('start');
      if (started != true) {
        return SttListenResult.failure(
          failure: SttListenFailure.unavailable,
          message: _genericMessage,
        );
      }
      return await completer.future.timeout(
        _listenFor + const Duration(seconds: 5),
        onTimeout: () async {
          await _nativeSttChannel.invokeMethod<String>('cancel');
          commitActiveSession();
          final normalized = latestRecognizedText.trim();
          if (normalized.isEmpty) {
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
      _activeNativeListen = false;
      _nativeSttChannel.setMethodCallHandler(null);
      if (_activeCompleter == completer) {
        _activeCompleter = null;
        _activeRecognizedText = null;
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
