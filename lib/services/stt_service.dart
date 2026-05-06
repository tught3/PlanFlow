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
  static const MethodChannel _nativeSttChannel =
      MethodChannel('planflow/native_stt');
  static const MethodChannel _androidPermissionsChannel =
      MethodChannel('planflow/android_permissions');

  static SpeechToText? _activeSpeech;
  static Completer<SttListenResult>? _activeCompleter;
  static String? _activeRecognizedText;
  static var _userRequestedStop = false;
  static var _activeNativeListen = false;
  static List<String>? _activeCommittedSegments;
  static var _activeNativeSessionText = '';
  static int? _activeNativeSessionId;

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
    var tokens = text
        .trim()
        .split(RegExp(r'\s+'))
        .where((token) => token.isNotEmpty)
        .toList(growable: true);
    if (tokens.isEmpty) {
      return '';
    }

    tokens = _applyInlineCorrections(tokens);
    tokens = _collapseRepeatedSpeechPrefixes(tokens);
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

  static List<String> _collapseRepeatedSpeechPrefixes(List<String> tokens) {
    final normalized = tokens
        .map(_normalizeTranscriptToken)
        .where((token) => token.isNotEmpty)
        .toList();
    if (normalized.length < 4) {
      return tokens;
    }

    var bestStart = -1;
    var bestOverlap = 0;
    final firstToken = normalized.first;
    for (var index = 1; index < normalized.length; index += 1) {
      if (normalized[index] != firstToken) {
        continue;
      }
      final suffixLength = normalized.length - index;
      final prefixLimit = suffixLength < index ? suffixLength : index;
      var overlap = 0;
      while (overlap < prefixLimit &&
          normalized[overlap] == normalized[index + overlap]) {
        overlap += 1;
      }
      if (overlap >= 2 && (index > bestStart || overlap >= bestOverlap)) {
        bestStart = index;
        bestOverlap = overlap;
      }
    }

    if (bestStart <= 0) {
      return tokens;
    }
    return tokens.sublist(bestStart);
  }

  static List<String> _applyInlineCorrections(List<String> tokens) {
    var result = List<String>.from(tokens);
    var index = 0;
    while (index < result.length) {
      final normalized = _normalizeTranscriptToken(result[index]);
      if ((normalized == '아니' || normalized == '아니야' || normalized == '아니요') &&
          index > 0 &&
          index < result.length - 1) {
        final before = result.sublist(0, index);
        final correction = result.sublist(index + 1);
        result = _replaceTailWords(before, correction);
        index = 0;
        continue;
      }
      index += 1;
    }
    return result;
  }

  static List<String> _replaceTailWords(
    List<String> baseWords,
    List<String> correctionWords,
  ) {
    final base = baseWords
        .map(_normalizeTranscriptToken)
        .where((word) => word.isNotEmpty)
        .toList();
    final correction = correctionWords
        .map(_normalizeTranscriptToken)
        .where((word) => word.isNotEmpty)
        .toList();
    if (base.isEmpty) {
      return correction;
    }
    if (correction.isEmpty) {
      return base;
    }
    for (var index = base.length - 1; index >= 0; index -= 1) {
      if (base[index] == correction.first ||
          correction.first.startsWith(base[index]) ||
          base[index].startsWith(correction.first)) {
        return <String>[
          ...base.take(index),
          ...correction,
        ];
      }
    }
    final replaceCount =
        correction.length <= base.length ? correction.length : base.length;
    return <String>[
      ...base.take(base.length - replaceCount),
      ...correction,
    ];
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
    if (output.isNotEmpty) {
      output.removeLast();
    }
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
      } catch (_) {}
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
    _completeActiveListenFromText();
  }

  Future<void> cancelActiveListen() async {
    _userRequestedStop = true;
    if (_activeNativeListen) {
      try {
        await _nativeSttChannel.invokeMethod<String>('cancel');
      } catch (_) {}
      _completeActiveFailure(
        failure: SttListenFailure.silence,
        message: '음성 입력을 취소했어요.',
      );
      return;
    }
    final speech = _activeSpeech;
    if (speech == null) {
      return;
    }
    await speech.cancel();
    _completeActiveFailure(
      failure: SttListenFailure.silence,
      message: '음성 입력을 취소했어요.',
    );
  }

  Future<String> undoLastSpeechSegment() async {
    if (_activeNativeListen) {
      if (_activeNativeSessionText.trim().isNotEmpty) {
        _activeNativeSessionText = '';
        _activeNativeSessionId = await _resetNativeTranscript();
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
        _activeNativeSessionId = await _resetNativeTranscript();
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
      _activeNativeSessionId = await _resetNativeTranscript();
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
    return _listenWithSpeechToText(onPartialResult: onPartialResult);
  }

  Future<SttListenResult> _listenWithSpeechToText({
    ValueChanged<String>? onPartialResult,
  }) async {
    final speech = SpeechToText();
    final completer = Completer<SttListenResult>();
    String? latestRecognizedText;
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

    try {
      final available = await speech.initialize(
        debugLogging: kDebugMode,
        onStatus: (status) {
          if (_userRequestedStop &&
              (status == SpeechToText.doneStatus ||
                  status == SpeechToText.notListeningStatus)) {
            completeSuccess();
          }
        },
        onError: (error) {
          if (error.errorMsg == 'error_permission' ||
              error.errorMsg == 'error_client') {
            _completeActiveFailure(
              failure: SttListenFailure.permissionDenied,
              message: _permissionMessage,
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
          final text = result.recognizedWords.trim();
          if (text.isEmpty) {
            return;
          }
          latestRecognizedText = text;
          _activeRecognizedText = text;
          onPartialResult?.call(text);
          if (result.finalResult && _userRequestedStop) {
            completeSuccess(text);
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

    try {
      final granted = await _androidPermissionsChannel.invokeMethod<bool>(
            'requestMicrophonePermission',
          ) ??
          false;
      if (!granted) {
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

  static void _completeActiveFailure({
    required SttListenFailure failure,
    required String message,
  }) {
    final completer = _activeCompleter;
    if (completer == null || completer.isCompleted) {
      return;
    }
    completer.complete(
      SttListenResult.failure(
        failure: failure,
        message: message,
        text: _activeRecognizedText,
      ),
    );
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

  static Future<int?> _resetNativeTranscript() async {
    try {
      return await _nativeSttChannel.invokeMethod<int>('resetTranscript');
    } catch (_) {
      return null;
    }
  }

  Future<SttListenResult> _listenWithNativeAndroid({
    ValueChanged<String>? onPartialResult,
    ValueChanged<int>? onRestart,
  }) async {
    final completer = Completer<SttListenResult>();
    final committedSegments = <String>[];
    String latestRecognizedText = '';
    var restartCount = 0;
    var pendingReplacement = false;
    _activeNativeListen = true;
    _activeCommittedSegments = committedSegments;
    _activeNativeSessionText = '';
    _activeNativeSessionId = null;
    _activeCompleter = completer;
    _activeRecognizedText = null;
    _userRequestedStop = false;

    String eventText(Object? arguments) {
      if (arguments is Map) {
        return arguments['text']?.toString() ?? '';
      }
      return arguments?.toString() ?? '';
    }

    int? eventSessionId(Object? arguments) {
      if (arguments is Map) {
        final value = arguments['sessionId'];
        if (value is int) {
          return value;
        }
        return int.tryParse(value?.toString() ?? '');
      }
      return null;
    }

    bool acceptsEvent(Object? arguments) {
      final eventSession = eventSessionId(arguments);
      if (eventSession == null) {
        return true;
      }
      _activeNativeSessionId ??= eventSession;
      return eventSession == _activeNativeSessionId;
    }

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

    void replaceCommittedTail(String correction) {
      final correctionWords = correction
          .trim()
          .split(RegExp(r'\s+'))
          .where((word) => word.isNotEmpty)
          .toList();
      final baseWords = committedSegments
          .join(' ')
          .trim()
          .split(RegExp(r'\s+'))
          .where((word) => word.isNotEmpty)
          .toList();
      committedSegments
        ..clear()
        ..add(_replaceTailWords(baseWords, correctionWords).join(' '));
    }

    void commitActiveSession() {
      final text = _activeNativeSessionText.trim();
      if (text.isEmpty) {
        return;
      }
      switch (detectVoiceCommand(text)) {
        case SttVoiceCommand.undoLastWord:
          pendingReplacement = true;
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
          unawaited(_resetNativeTranscript().then((id) {
            _activeNativeSessionId = id;
          }));
          return;
        case SttVoiceCommand.cancel:
          _activeNativeSessionText = '';
          latestRecognizedText = committedSegments.join(' ').trim();
          _activeRecognizedText = latestRecognizedText;
          _completeActiveFailure(
            failure: SttListenFailure.silence,
            message: '음성 입력을 취소했어요.',
          );
          return;
        case SttVoiceCommand.none:
          break;
      }
      if (pendingReplacement) {
        replaceCommittedTail(text);
        pendingReplacement = false;
      } else if (committedSegments.isEmpty || committedSegments.last != text) {
        committedSegments.add(text);
      }
      _activeNativeSessionText = '';
      latestRecognizedText = committedSegments.join(' ').trim();
      _activeRecognizedText = latestRecognizedText;
      onPartialResult?.call(latestRecognizedText);
    }

    _nativeSttChannel.setMethodCallHandler((call) async {
      if (!acceptsEvent(call.arguments)) {
        return;
      }
      switch (call.method) {
        case 'partial':
          updateRecognizedText(eventText(call.arguments));
          break;
        case 'stopped':
          updateRecognizedText(eventText(call.arguments));
          commitActiveSession();
          _completeActiveListenFromText();
          break;
        case 'cancelled':
          _completeActiveFailure(
            failure: SttListenFailure.silence,
            message: '음성 입력을 취소했어요.',
          );
          break;
        case 'error':
          _completeActiveFailure(
            failure: SttListenFailure.unavailable,
            message: _genericMessage,
          );
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
      _activeNativeSessionId = null;
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
const String _silenceMessage = '음성이 인식되지 않았어요. 조금 더 크게 말하거나 직접 입력으로 이어가 주세요.';
const String _genericMessage = '음성 입력을 시작하지 못했어요. 직접 입력으로 이어가 주세요.';

const Set<String> _timePrefixTokens = <String>{
  '오전',
  '오후',
  '저녁',
  '아침',
  '점심',
  '밤',
};

class _VoiceCommandMatch {
  const _VoiceCommandMatch(this.command, this.consumedTokens);

  final SttVoiceCommand command;
  final int consumedTokens;
}
