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
  static List<String>? _activeCommittedSegments;
  static var _activeNativeSessionText = '';
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
  static SttVoiceCommand detectVoiceCommand(String text) {
    final normalized = _normalizeVoiceCommandText(text);
    if (normalized == '아니' || normalized == '아니야' || normalized == '아니요') {
      return SttVoiceCommand.undoLastWord;
    }
    if (normalized.contains('마지막거지워') || normalized.contains('방금거지워')) {
      return SttVoiceCommand.undoLastSegment;
    }
    if (normalized == '다시' ||
        normalized.contains('처음부터') ||
        normalized.contains('다시말할게')) {
      return SttVoiceCommand.clearAll;
    }
    if (normalized == '취소') {
      return SttVoiceCommand.cancel;
    }
    return SttVoiceCommand.none;
  }

  static String normalizeVoiceTranscript(String text) {
    final tokens = text
        .trim()
        .split(RegExp(r'\s+'))
        .where((token) => token.isNotEmpty)
        .toList();
    final output = <String>[];

    var index = 0;
    while (index < tokens.length) {
      final command = _matchVoiceCommand(tokens, index);
      if (command != null) {
        switch (command.command) {
          case SttVoiceCommand.undoLastWord:
            _removeLastTranscriptWord(output);
            break;
          case SttVoiceCommand.undoLastSegment:
            _removeLastTranscriptSegment(output);
            break;
          case SttVoiceCommand.clearAll:
            output.clear();
            break;
          case SttVoiceCommand.cancel:
            break;
          case SttVoiceCommand.none:
            break;
        }
        index += command.consumedTokens;
        continue;
      }

      final cleanedToken = _normalizeTranscriptToken(tokens[index]);
      if (cleanedToken.isNotEmpty) {
        output.add(cleanedToken);
      }
      index += 1;
    }

    return output.join(' ').trim();
  }

  static String _normalizeVoiceCommandText(String text) {
    return text
        .trim()
        .replaceAll(RegExp(r'[\s\p{P}\p{S}]', unicode: true), '')
        .toLowerCase();
  }

  static _VoiceCommandMatch? _matchVoiceCommand(
    List<String> tokens,
    int index,
  ) {
    const maxCommandTokens = 3;
    final maxLength = index + maxCommandTokens <= tokens.length
        ? maxCommandTokens
        : tokens.length - index;
    for (var length = maxLength; length >= 1; length -= 1) {
      final normalized = List<String>.generate(
        length,
        (offset) => _normalizeTranscriptToken(tokens[index + offset]),
      ).join();
      switch (normalized) {
        case '아니':
        case '아니야':
        case '아니요':
          return const _VoiceCommandMatch(SttVoiceCommand.undoLastWord, 1);
        case '마지막거지워':
        case '방금거지워':
          return _VoiceCommandMatch(SttVoiceCommand.undoLastSegment, length);
        case '다시':
        case '처음부터':
        case '다시말할게':
          return _VoiceCommandMatch(SttVoiceCommand.clearAll, length);
        case '취소':
          return _VoiceCommandMatch(SttVoiceCommand.cancel, length);
      }
    }
    return null;
  }

  static String _normalizeTranscriptToken(String token) {
    return token
        .trim()
        .replaceAll(RegExp(r'[\s\p{P}\p{S}]', unicode: true), '')
        .toLowerCase();
  }

  static void _removeLastTranscriptWord(List<String> output) {
    if (output.isEmpty) {
      return;
    }
    output.removeLast();
    if (output.isEmpty) {
      return;
    }
    final tail = _normalizeTranscriptToken(output.last);
    if (_timePrefixTokens.contains(tail) && output.isNotEmpty) {
      output.removeLast();
    }
  }

  static void _removeLastTranscriptSegment(List<String> output) {
    if (output.isEmpty) {
      return;
    }
    output.removeLast();
  }

  @visibleForTesting
  static String appendOnlyNewSpeech(String committedText, String incomingText) {
    final committedWords = committedText
        .trim()
        .split(RegExp(r'\s+'))
        .where((word) => word.isNotEmpty)
        .toList();
    final incomingWords = incomingText
        .trim()
        .split(RegExp(r'\s+'))
        .where((word) => word.isNotEmpty)
        .toList();
    if (incomingWords.isEmpty) {
      return '';
    }
    if (committedWords.isEmpty) {
      return incomingWords.join(' ');
    }

    final maxOverlap = committedWords.length < incomingWords.length
        ? committedWords.length
        : incomingWords.length;
    for (var overlap = maxOverlap; overlap > 0; overlap -= 1) {
      final committedTail = committedWords.sublist(
        committedWords.length - overlap,
      );
      final incomingHead = incomingWords.sublist(0, overlap);
      if (listEquals(committedTail, incomingHead)) {
        return incomingWords.sublist(overlap).join(' ');
      }
    }

    final incoming = incomingWords.join(' ');
    final committed = committedWords.join(' ');
    if (committed.endsWith(incoming)) {
      return '';
    }
    return incoming;
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

  Future<String> undoLastSpeechSegment() async {
    if (_activeNativeListen) {
      if (_activeNativeSessionText.trim().isNotEmpty) {
        _activeNativeSessionText = '';
        await _resetNativeTranscript();
      } else {
        final segments = _activeCommittedSegments;
        if (segments != null && segments.isNotEmpty) {
          segments.removeLast();
        }
      }
      return _syncNativeTranscript();
    }
    return _editActiveText((text) {
      final words = text.trim().split(RegExp(r'\s+'));
      if (words.isEmpty || words.first.isEmpty) {
        return '';
      }
      words.removeLast();
      return words.join(' ');
    });
  }

  Future<String> undoLastSpeechWord() async {
    if (_activeNativeListen) {
      final sessionWords =
          _activeNativeSessionText.trim().split(RegExp(r'\s+'));
      if (_activeNativeSessionText.trim().isNotEmpty &&
          sessionWords.isNotEmpty) {
        sessionWords.removeLast();
        _activeNativeSessionText = sessionWords.join(' ');
        await _resetNativeTranscript();
      } else {
        final segments = _activeCommittedSegments;
        if (segments != null && segments.isNotEmpty) {
          final lastWords = segments.last.trim().split(RegExp(r'\s+'));
          if (lastWords.length <= 1) {
            segments.removeLast();
          } else {
            lastWords.removeLast();
            segments[segments.length - 1] = lastWords.join(' ');
          }
        }
      }
      return _syncNativeTranscript();
    }
    return _editActiveText((text) {
      final words = text.trim().split(RegExp(r'\s+'));
      if (words.isEmpty || words.first.isEmpty) {
        return '';
      }
      words.removeLast();
      return words.join(' ');
    });
  }

  Future<String> clearActiveTranscript() async {
    if (_activeNativeListen) {
      _activeCommittedSegments?.clear();
      _activeNativeSessionText = '';
      _activeRecognizedText = '';
      await _resetNativeTranscript();
      return '';
    }
    _activeRecognizedText = '';
    return '';
  }

  Future<SttListenResult> listen({
    ValueChanged<String>? onPartialResult,
    ValueChanged<int>? onRestart,
  }) async {
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      final permissionResult = await _ensureAndroidMicrophonePermission();
      if (permissionResult != null) {
        return permissionResult;
      }
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

  Future<SttListenResult?> _ensureAndroidMicrophonePermission() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return null;
    }

    final speech = SpeechToText();
    try {
      final available = await speech.initialize(debugLogging: kDebugMode);
      if (!available) {
        final hasPermission = await speech.hasPermission;
        return SttListenResult.failure(
          failure: hasPermission
              ? SttListenFailure.unavailable
              : SttListenFailure.permissionDenied,
          message: hasPermission ? _genericMessage : _permissionMessage,
        );
      }

      final hasPermission = await speech.hasPermission;
      if (!hasPermission) {
        return SttListenResult.failure(
          failure: SttListenFailure.permissionDenied,
          message: _permissionMessage,
        );
      }
      return null;
    } catch (error) {
      debugPrint('PlanFlow STT permission check failed: $error');
      return SttListenResult.failure(
        failure: SttListenFailure.permissionDenied,
        message: _permissionMessage,
      );
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

  static String _syncNativeTranscript() {
    final segments = _activeCommittedSegments ?? const <String>[];
    final pieces = <String>[
      ...segments,
      if (_activeNativeSessionText.trim().isNotEmpty)
        _activeNativeSessionText.trim(),
    ];
    final transcript = pieces.join(' ').trim();
    _activeRecognizedText = transcript;
    return transcript;
  }

  static String _editActiveText(String Function(String text) edit) {
    final nextText = edit(_activeRecognizedText ?? '').trim();
    _activeRecognizedText = nextText;
    return nextText;
  }

  static Future<void> _resetNativeTranscript() async {
    try {
      await _nativeSttChannel.invokeMethod<bool>('resetTranscript');
    } catch (_) {}
  }

  Future<SttListenResult> _listenWithNativeAndroid({
    ValueChanged<String>? onPartialResult,
    ValueChanged<int>? onRestart,
  }) async {
    final completer = Completer<SttListenResult>();
    final committedSegments = <String>[];
    String latestRecognizedText = '';
    var restartCount = 0;
    _activeNativeListen = true;
    _activeCommittedSegments = committedSegments;
    _activeNativeSessionText = '';
    _activeCompleter = completer;
    _activeRecognizedText = null;
    _userRequestedStop = false;

    void updateRecognizedText(String incomingText) {
      final recognizedWords = incomingText.trim();
      if (recognizedWords.isEmpty) {
        return;
      }
      final committedText = committedSegments.join(' ').trim();
      final newSpeech = appendOnlyNewSpeech(committedText, recognizedWords);
      final mergedText = [
        if (committedText.isNotEmpty) committedText,
        if (newSpeech.isNotEmpty) newSpeech,
      ].join(' ').trim();
      _activeNativeSessionText = newSpeech;
      latestRecognizedText = mergedText;
      _activeRecognizedText = mergedText;
      onPartialResult?.call(mergedText);
    }

    void commitActiveSession() {
      final text = _activeNativeSessionText.trim();
      if (text.isEmpty) {
        return;
      }
      switch (detectVoiceCommand(text)) {
        case SttVoiceCommand.undoLastWord:
          if (committedSegments.isNotEmpty) {
            final lastWords =
                committedSegments.last.trim().split(RegExp(r'\s+'));
            if (lastWords.length <= 1) {
              committedSegments.removeLast();
            } else {
              lastWords.removeLast();
              committedSegments[committedSegments.length - 1] =
                  lastWords.join(' ');
            }
          }
          _activeNativeSessionText = '';
          latestRecognizedText = committedSegments.join(' ').trim();
          _activeRecognizedText = latestRecognizedText;
          onPartialResult?.call(latestRecognizedText);
          return;
        case SttVoiceCommand.undoLastSegment:
          if (committedSegments.isNotEmpty) {
            committedSegments.removeLast();
          }
          _activeNativeSessionText = '';
          latestRecognizedText = committedSegments.join(' ').trim();
          _activeRecognizedText = latestRecognizedText;
          onPartialResult?.call(latestRecognizedText);
          return;
        case SttVoiceCommand.clearAll:
          committedSegments.clear();
          _activeNativeSessionText = '';
          latestRecognizedText = '';
          _activeRecognizedText = '';
          onPartialResult?.call('');
          unawaited(_resetNativeTranscript());
          return;
        case SttVoiceCommand.cancel:
          _activeNativeSessionText = '';
          latestRecognizedText = committedSegments.join(' ').trim();
          _activeRecognizedText = latestRecognizedText;
          if (!completer.isCompleted) {
            completer.complete(
              SttListenResult.failure(
                failure: SttListenFailure.silence,
                message: '음성 입력을 취소했어요.',
                text: latestRecognizedText,
              ),
            );
          }
          return;
        case SttVoiceCommand.none:
          break;
      }
      if (committedSegments.isEmpty || committedSegments.last != text) {
        committedSegments.add(text);
      }
      _activeNativeSessionText = '';
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
      _activeCommittedSegments = null;
      _activeNativeSessionText = '';
      _nativeSttChannel.setMethodCallHandler(null);
      if (_activeCompleter == completer) {
        _activeCompleter = null;
        _activeRecognizedText = null;
      }
    }
  }
}

enum SttVoiceCommand {
  none,
  undoLastWord,
  undoLastSegment,
  clearAll,
  cancel,
}

const String _unsupportedLocaleMessage =
    '이 기기에서는 온디바이스 한국어 음성 인식을 사용할 수 없어요. 직접 입력으로 이어가 주세요.';
const String _permissionMessage =
    '마이크 권한이 없어요. 설정에서 권한을 허용한 뒤 다시 시도하거나 직접 입력으로 이어가 주세요.';

const Set<String> _timePrefixTokens = <String>{
  '오전',
  '오후',
  '새벽',
  '아침',
  '점심',
  '저녁',
  '밤',
};

class _VoiceCommandMatch {
  const _VoiceCommandMatch(this.command, this.consumedTokens);

  final SttVoiceCommand command;
  final int consumedTokens;
}

const String _silenceMessage = '음성이 인식되지 않았어요. 조금 더 크게 말하거나 직접 입력으로 이어가 주세요.';
const String _genericMessage = '음성 입력을 시작하지 못했어요. 직접 입력으로 이어가 주세요.';
