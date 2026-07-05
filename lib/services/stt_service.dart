import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:speech_to_text/speech_to_text.dart';

import '../core/region_settings.dart';
import 'remote_config_service.dart';
import 'voice_text_cleanup_service.dart';

enum SttListenFailure {
  unsupportedLocale,
  permissionDenied,
  silence,
  unavailable,
}

enum SttListenMode {
  dictation,
  conversation,
}

enum SttNativeStatus {
  ready,
  speechStart,
  speechEnd,
  segmentEnded,
  restarted,
  stalled,
  stopped,
  cancelled,
  error,
}

class SttNativeStatusEvent {
  const SttNativeStatusEvent({
    required this.status,
    this.restartCount = 0,
    this.reason,
  });

  final SttNativeStatus status;
  final int restartCount;
  final String? reason;
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
  static Duration get _listenFor {
    final seconds = RemoteConfigService.maxVoiceDurationSeconds;
    return Duration(seconds: seconds <= 0 ? 60 : seconds);
  }

  static const Duration _pauseFor = Duration(seconds: 20);
  static const Duration _conversationListenFor = Duration(minutes: 5);
  static const Duration _conversationPauseFor = Duration(minutes: 5);
  static const int _conversationSilenceMs = 300000;
  // 받아쓰기 침묵 허용 120초. 말하다 1분 이상 쉬어도 세션 유지 시도.
  static const int _dictationSilenceMs = 120000;
  static const MethodChannel _nativeSttChannel =
      MethodChannel('planflow/native_stt');
  static const MethodChannel _androidPermissionsChannel =
      MethodChannel('planflow/android_permissions');
  static const Duration _permissionStabilizationDelay =
      Duration(milliseconds: 300);
  static const Duration _nativeStartRetryDelay = Duration(milliseconds: 250);

  static SpeechToText? _activeSpeech;
  static Completer<SttListenResult>? _activeCompleter;
  static String? _activeRecognizedText;
  static var _userRequestedStop = false;
  static var _activeNativeListen = false;
  static List<String>? _activeCommittedSegments;
  static var _activeNativeSessionText = '';
  static int? _activeNativeSessionId;
  static int? _expelledNativeSessionId;
  static var _activeListenGeneration = 0;

  @visibleForTesting
  static bool get debugHasActiveListen {
    return _activeCompleter != null ||
        _activeSpeech != null ||
        _activeNativeListen ||
        _activeRecognizedText != null ||
        _activeCommittedSegments != null ||
        _activeNativeSessionText.isNotEmpty ||
        _activeNativeSessionId != null;
  }

  @visibleForTesting
  static int get debugActiveListenGeneration => _activeListenGeneration;

  @visibleForTesting
  static Duration debugListenForForMode(SttListenMode mode) {
    return _listenForForMode(mode);
  }

  @visibleForTesting
  static Duration debugPauseForForMode(SttListenMode mode) {
    return _pauseForForMode(mode);
  }

  @visibleForTesting
  static int get debugConversationSilenceMs => _conversationSilenceMs;

  static Duration _listenForForMode(SttListenMode mode) {
    return mode == SttListenMode.conversation
        ? _conversationListenFor
        : _listenFor;
  }

  static Duration _pauseForForMode(SttListenMode mode) {
    return mode == SttListenMode.conversation
        ? _conversationPauseFor
        : _pauseFor;
  }

  @visibleForTesting
  static void debugSeedNativeListenState({String recognizedText = ''}) {
    _activeCompleter = Completer<SttListenResult>();
    _activeNativeListen = true;
    _activeCommittedSegments = <String>[];
    _activeNativeSessionText = recognizedText;
    _activeRecognizedText = recognizedText;
    _activeNativeSessionId = 1;
  }

  @visibleForTesting
  static void debugResetActiveListenState() {
    _activeListenGeneration += 1;
    _clearActiveListenState(clearHandler: true);
  }

  static void _logPhase(
    String phase, {
    required SttListenMode mode,
    String attempt = 'normal',
    String? reason,
  }) {
    final session = _activeNativeSessionId ?? 0;
    final suffix = reason == null || reason.trim().isEmpty
        ? ''
        : ' reason=${reason.trim()}';
    debugPrint(
      '[STT] phase=$phase gen=$_activeListenGeneration session=$session '
      'mode=${mode.name} attempt=$attempt$suffix',
    );
  }

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

  static String? resolvePreferredLocaleId(Iterable<String> localeIds) {
    final locales = localeIds.toList(growable: false);
    final preferred = PlanFlowRegionController.instance.region.languageHint;
    if (locales.contains(preferred)) {
      return preferred;
    }
    final language = preferred.split('-').first.toLowerCase();
    for (final localeId in locales) {
      if (localeId.toLowerCase().startsWith(language)) {
        return localeId;
      }
    }
    return resolveKoreanLocaleId(locales);
  }

  @visibleForTesting
  static SttVoiceCommand detectVoiceCommand(
    String text, {
    bool includeCancel = true,
  }) {
    final normalized = _normalizeVoiceCommandText(text);
    return _resolveVoiceCommandFromNormalized(
      normalized,
      includeCancel: includeCancel,
    );
  }

  static String normalizeVoiceTranscript(
    String text, {
    ValueChanged<SttVoiceCommand>? onCommand,
    bool includeCancelCommands = false,
  }) {
    var tokens = text
        .trim()
        .split(RegExp(r'\s+'))
        .where((token) => token.isNotEmpty)
        .toList(growable: true);
    if (tokens.isEmpty) {
      return '';
    }

    tokens = _applyInlineCorrections(tokens);
    tokens = _collapseRepeatedSpeech(tokens);
    final output = <String>[];

    var index = 0;
    while (index < tokens.length) {
      final command = _matchVoiceCommand(
        tokens,
        index,
        includeCancel: includeCancelCommands,
      );
      if (command != null) {
        final isWholeTranscriptCommand =
            index == 0 && command.consumedTokens == tokens.length;
        final isTailTranscriptCommand =
            index + command.consumedTokens == tokens.length;
        if (command.command == SttVoiceCommand.cancel &&
            !isWholeTranscriptCommand &&
            !(includeCancelCommands &&
                isTailTranscriptCommand &&
                _isSafeTailCancelContext(tokens.take(index)))) {
          output.add(tokens[index]);
          index += 1;
          continue;
        }
        onCommand?.call(command.command);
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
      if (includeCancelCommands &&
          index == tokens.length - 1 &&
          _isStopCommandPrefix(cleanedToken) &&
          _isSafeTailCancelContext(tokens.take(index))) {
        index += 1;
        continue;
      }
      if (cleanedToken.isNotEmpty) {
        output.add(cleanedToken);
      }
      index += 1;
    }

    return _normalizeCommonKoreanSttPhrases(output.join(' ')).trim();
  }

  static bool _isStopCommandPrefix(String token) {
    if (token.isEmpty) {
      return false;
    }
    return _stopCommandTokens.any(
      (command) => command.startsWith(token) && command != token,
    );
  }

  static bool _isSafeTailCancelContext(Iterable<String> previousTokens) {
    final normalized = previousTokens
        .map(_normalizeTranscriptToken)
        .where((token) => token.isNotEmpty)
        .join(' ');
    if (normalized.isEmpty) {
      return true;
    }
    return RegExp(
      r'(오늘|내일|모레|글피|이번주|이번\s*주|다음주|다음\s*주|\d{1,2}월|\d{1,2}일|\d{1,2}시|오전|오후|아침|점심|저녁|밤)',
    ).hasMatch(normalized);
  }

  static String _normalizeCommonKoreanSttPhrases(String text) {
    return VoiceTextCleanupService.normalizeBasic(text);
  }

  static List<String> _collapseRepeatedSpeech(List<String> tokens) {
    final adjacentCollapsed = _collapseAdjacentRepeatedSpeech(tokens);
    return _collapseRepeatedSpeechPrefixes(adjacentCollapsed);
  }

  static List<String> _collapseAdjacentRepeatedSpeech(List<String> tokens) {
    final normalized = tokens
        .map(_normalizeTranscriptToken)
        .where((token) => token.isNotEmpty)
        .toList();
    if (normalized.length < 4) {
      return tokens;
    }

    for (var size = normalized.length ~/ 2; size >= 2; size -= 1) {
      for (var start = 0; start + size * 2 <= normalized.length; start += 1) {
        var repeated = true;
        for (var offset = 0; offset < size; offset += 1) {
          if (normalized[start + offset] != normalized[start + size + offset]) {
            repeated = false;
            break;
          }
        }
        if (repeated) {
          return <String>[
            ...tokens.take(start),
            ...tokens.skip(start + size),
          ];
        }
      }
    }

    return tokens;
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
      if ((normalized == '아니' ||
              normalized == '아니야' ||
              normalized == '아니요' ||
              normalized == '아니다') &&
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
    if (_timePrefixTokens.contains(correction.first)) {
      for (var index = base.length - 1; index >= 0; index -= 1) {
        if (_timePrefixTokens.contains(base[index])) {
          return <String>[
            ...base.take(index),
            ...correction,
          ];
        }
      }
    }
    // 날짜 정정: "6월 7일 아니 9일" → 교정값이 날짜 토큰이면
    // 직전 날짜 토큰 경계부터 교체해 월/일 일부만 자연스럽게 정정한다.
    if (_isDateToken(correction.first)) {
      for (var index = base.length - 1; index >= 0; index -= 1) {
        if (_isDateToken(base[index])) {
          return <String>[
            ...base.take(index),
            ...correction,
          ];
        }
      }
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
    int index, {
    bool includeCancel = false,
  }) {
    const maxCommandTokens = 3;
    final maxLength = index + maxCommandTokens <= tokens.length
        ? maxCommandTokens
        : tokens.length - index;
    for (var length = maxLength; length >= 1; length -= 1) {
      final normalized = List<String>.generate(
        length,
        (offset) => _normalizeTranscriptToken(tokens[index + offset]),
      ).join();
      final command = _resolveVoiceCommandFromNormalized(
        normalized,
        includeCancel: includeCancel,
      );
      if (command != SttVoiceCommand.none) {
        return _VoiceCommandMatch(command, length);
      }
    }
    return null;
  }

  static SttVoiceCommand _resolveVoiceCommandFromNormalized(
    String normalized, {
    bool includeCancel = false,
  }) {
    if (_undoLastWordCommandTokens.contains(normalized)) {
      return SttVoiceCommand.undoLastWord;
    }
    if (_undoLastSegmentCommandTokens.contains(normalized)) {
      return SttVoiceCommand.undoLastSegment;
    }
    if (_clearAllCommandTokens.contains(normalized)) {
      return SttVoiceCommand.clearAll;
    }
    if (includeCancel && _stopCommandTokens.contains(normalized)) {
      return SttVoiceCommand.cancel;
    }
    return SttVoiceCommand.none;
  }

  static bool _applyVoiceControlCommandForSpeechToText(
    SttVoiceCommand command,
    String currentText,
    ValueChanged<String> onTextUpdated,
    VoidCallback onCancelRequested,
  ) {
    switch (command) {
      case SttVoiceCommand.undoLastWord:
        onTextUpdated(_applyTextCommand(_removeLastWordFromText(currentText)));
        return true;
      case SttVoiceCommand.undoLastSegment:
        onTextUpdated(
            _applyTextCommand(_removeLastSegmentFromText(currentText)));
        return true;
      case SttVoiceCommand.clearAll:
        onTextUpdated('');
        return true;
      case SttVoiceCommand.cancel:
        onCancelRequested();
        return true;
      case SttVoiceCommand.none:
        return false;
    }
  }

  static String _applyTextCommand(String text) {
    if (text.isEmpty) {
      return '';
    }
    return text.trim();
  }

  static String _removeLastWordFromText(String text) {
    final output = text
        .trim()
        .split(RegExp(r'\s+'))
        .where((token) => token.isNotEmpty)
        .toList();
    _removeLastTranscriptWord(output);
    return output.join(' ');
  }

  static String _removeLastSegmentFromText(String text) {
    final output = text
        .trim()
        .split(RegExp(r'\s+'))
        .where((token) => token.isNotEmpty)
        .toList();
    _removeLastTranscriptSegment(output);
    return output.join(' ');
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
    final incomingWords = _dedupeTranscriptWords(incomingText);
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
      if (listEquals(
        committedTail.map(_transcriptOverlapKey).toList(growable: false),
        incomingHead.map(_transcriptOverlapKey).toList(growable: false),
      )) {
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

  static String _transcriptOverlapKey(String token) {
    return _normalizeTranscriptToken(token).replaceFirst(
      RegExp(r'(으로|에서|에게|한테|로|에|을|를|이|가)$'),
      '',
    );
  }

  static String mergeTranscriptSegment(String committedText, String segment) {
    final normalizedSegment = segment.trim();
    if (normalizedSegment.isEmpty) {
      return committedText.trim();
    }
    final incomingWords = _dedupeTranscriptWords(normalizedSegment);
    if (incomingWords.isEmpty) {
      return committedText.trim();
    }
    final committed = committedText.trim();
    if (committed.isEmpty) {
      return incomingWords.join(' ');
    }
    final committedWords = committed
        .split(RegExp(r'\s+'))
        .where((word) => word.isNotEmpty)
        .toList();
    final maxOverlap = committedWords.length < incomingWords.length
        ? committedWords.length
        : incomingWords.length;
    for (var overlap = maxOverlap; overlap > 0; overlap -= 1) {
      final committedTail = committedWords.sublist(
        committedWords.length - overlap,
      );
      final incomingHead = incomingWords.sublist(0, overlap);
      if (!listEquals(
        committedTail.map(_transcriptOverlapKey).toList(growable: false),
        incomingHead.map(_transcriptOverlapKey).toList(growable: false),
      )) {
        continue;
      }
      final mergedWords = List<String>.of(committedWords);
      for (var index = 0; index < overlap; index += 1) {
        final committedIndex = mergedWords.length - overlap + index;
        final incoming = incomingHead[index];
        if (_normalizeTranscriptToken(incoming).startsWith(
          _normalizeTranscriptToken(mergedWords[committedIndex]),
        )) {
          mergedWords[committedIndex] = incoming;
        }
      }
      mergedWords.addAll(incomingWords.sublist(overlap));
      return mergedWords.join(' ');
    }
    return '$committed ${incomingWords.join(' ')}'.trim();
  }

  static List<String> _dedupeTranscriptWords(String text) {
    final words = text
        .trim()
        .split(RegExp(r'\s+'))
        .where((word) => word.isNotEmpty)
        .toList(growable: false);
    if (words.length < 4) {
      return words;
    }
    return _collapseRepeatedSpeech(words);
  }

  @visibleForTesting
  static SpeechListenOptions buildListenOptions() {
    return buildListenOptionsForMode(SttListenMode.dictation);
  }

  static SpeechListenOptions buildListenOptionsForMode(
    SttListenMode mode,
  ) {
    return SpeechListenOptions(
      onDevice: true,
      partialResults: true,
      cancelOnError: false,
      listenMode: mode == SttListenMode.conversation
          ? ListenMode.confirmation
          : ListenMode.dictation,
    );
  }

  Future<void> stopActiveListen() async {
    _userRequestedStop = true;
    debugPrint('SttService phase=stop');
    if (_activeNativeListen) {
      try {
        await _nativeSttChannel.invokeMethod<String>('stop');
      } catch (e) { debugPrint('SttService 무시된 예외: $e'); }
      await Future<void>.delayed(const Duration(milliseconds: 350));
      _completeActiveListenFromText(detach: true);
      return;
    }
    final speech = _activeSpeech;
    if (speech == null && _activeCompleter == null) {
      return;
    }
    if (speech != null && speech.isListening) {
      await speech.stop();
    }
    await Future<void>.delayed(const Duration(milliseconds: 250));
    _completeActiveListenFromText(detach: true);
  }

  Future<void> cancelActiveListen() async {
    _userRequestedStop = true;
    _activeListenGeneration += 1;
    _logPhase('cancel', mode: SttListenMode.dictation);
    final hadActiveNativeListen = _activeNativeListen;
    final speech = _activeSpeech;
    if (hadActiveNativeListen) {
      try {
        await _nativeSttChannel.invokeMethod<String>('cancel');
      } catch (e) { debugPrint('SttService 무시된 예외: $e'); }
    }
    if (speech != null) {
      try {
        await speech.cancel();
      } catch (e) { debugPrint('SttService 무시된 예외: $e'); }
    }
    _completeActiveFailure(
      failure: SttListenFailure.silence,
      message: '음성 입력을 취소했어요.',
    );
    _clearActiveListenState(clearHandler: true);
  }

  static void _clearActiveListenState({required bool clearHandler}) {
    _expelledNativeSessionId = _activeNativeSessionId;
    _activeSpeech = null;
    _activeCompleter = null;
    _activeRecognizedText = null;
    _activeNativeListen = false;
    _activeCommittedSegments = null;
    _activeNativeSessionText = '';
    _activeNativeSessionId = null;
    if (clearHandler) {
      _nativeSttChannel.setMethodCallHandler(null);
    }
  }

  Future<void> _cleanupBeforeNewListen() async {
    if (_activeCompleter == null &&
        _activeSpeech == null &&
        !_activeNativeListen &&
        _activeRecognizedText == null &&
        _activeCommittedSegments == null &&
        _activeNativeSessionText.isEmpty) {
      return;
    }
    _logPhase('pre_listen_cleanup', mode: SttListenMode.dictation);
    if (_activeNativeListen) {
      try {
        await _nativeSttChannel.invokeMethod<String>('cancel');
      } catch (e) { debugPrint('SttService 무시된 예외: $e'); }
      _completeActiveFailure(
        failure: SttListenFailure.silence,
        message: '음성 입력을 취소했어요.',
      );
    }
    final speech = _activeSpeech;
    if (speech != null) {
      try {
        await speech.cancel();
      } catch (e) { debugPrint('SttService 무시된 예외: $e'); }
    }
    _completeActiveFailure(
      failure: SttListenFailure.silence,
      message: '음성 입력을 취소했어요.',
    );
    _activeListenGeneration += 1;
    _clearActiveListenState(clearHandler: true);
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

  /// 음성 입력 화면 진입/복귀 시 호출해 OS STT 엔진을 미리 깨워 둔다.
  /// 첫 listen의 SpeechToText.initialize 지연(재입력 시 2초가량 안 먹던 텀)을
  /// 줄이기 위함. listen 로직과 독립이며 실패는 조용히 무시한다.
  Future<void> warmUp() async {
    try {
      await SpeechToText().initialize(debugLogging: kDebugMode);
    } catch (_) {
      // 워밍업 실패는 listen 시 재시도되므로 무시한다.
    }
  }

  Future<SttListenResult> listen({
    ValueChanged<String>? onPartialResult,
    ValueChanged<int>? onRestart,
    ValueChanged<SttNativeStatusEvent>? onStatus,
    SttListenMode mode = SttListenMode.dictation,
  }) async {
    await _cleanupBeforeNewListen();
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      final hadPermissionBefore = await _hasAndroidMicrophonePermission();
      final permissionResult = await _ensureAndroidMicrophonePermission();
      if (permissionResult != null) {
        return permissionResult;
      }
      if (!hadPermissionBefore) {
        await Future<void>.delayed(_permissionStabilizationDelay);
      }
      final nativeResult = await _listenWithNativeAndroid(
        onPartialResult: onPartialResult,
        onRestart: onRestart,
        onStatus: onStatus,
        mode: mode,
        attempt: 'first',
      );
      if (nativeResult.failure != SttListenFailure.unavailable) {
        return nativeResult;
      }
      await Future<void>.delayed(_nativeStartRetryDelay);
      final retryResult = await _listenWithNativeAndroid(
        onPartialResult: onPartialResult,
        onRestart: onRestart,
        onStatus: onStatus,
        mode: mode,
        attempt: 'warmup-retry',
      );
      if (retryResult.failure != SttListenFailure.unavailable) {
        return retryResult;
      }
    }
    return _listenWithSpeechToText(
      onPartialResult: onPartialResult,
      onStatus: onStatus,
      mode: mode,
    );
  }

  Future<SttListenResult> _listenWithSpeechToText({
    ValueChanged<String>? onPartialResult,
    ValueChanged<SttNativeStatusEvent>? onStatus,
    SttListenMode mode = SttListenMode.dictation,
  }) async {
    final speech = SpeechToText();
    final completer = Completer<SttListenResult>();
    final listenGeneration = ++_activeListenGeneration;
    String? latestRecognizedText;
    String? latestSpeechError;
    _activeSpeech = speech;
    _activeCompleter = completer;
    _activeRecognizedText = null;
    _userRequestedStop = false;
    _logPhase('start', mode: mode);

    void completeSuccess([String? text]) {
      if (listenGeneration != _activeListenGeneration) {
        return;
      }
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
          if (listenGeneration != _activeListenGeneration) {
            return;
          }
          if (status == SpeechToText.listeningStatus) {
            onStatus?.call(
              const SttNativeStatusEvent(status: SttNativeStatus.ready),
            );
          } else if (status == SpeechToText.doneStatus ||
              status == SpeechToText.notListeningStatus) {
            onStatus?.call(
              const SttNativeStatusEvent(status: SttNativeStatus.stopped),
            );
          }
          if (_userRequestedStop &&
              (status == SpeechToText.doneStatus ||
                  status == SpeechToText.notListeningStatus)) {
            completeSuccess();
          }
        },
        onError: (error) {
          if (listenGeneration != _activeListenGeneration) {
            return;
          }
          latestSpeechError = error.errorMsg;
          debugPrint(
            'PlanFlow STT speech_to_text error: '
            'message=${error.errorMsg}, permanent=${error.permanent}',
          );
          onStatus?.call(
            SttNativeStatusEvent(
              status: SttNativeStatus.error,
              reason: error.errorMsg,
            ),
          );
          if (error.errorMsg == 'error_permission' ||
              error.errorMsg == 'error_client') {
            _completeActiveFailure(
              failure: SttListenFailure.permissionDenied,
              message: _permissionMessage,
            );
          } else if (_isEmptySpeechError(error.errorMsg) &&
              (latestRecognizedText == null ||
                  latestRecognizedText!.trim().isEmpty)) {
            _completeActiveFailure(
              failure: SttListenFailure.silence,
              message: _messageForSpeechError(error.errorMsg),
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
      final localeId = resolvePreferredLocaleId(
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
        listenFor: _listenForForMode(mode),
        pauseFor: _pauseForForMode(mode),
        listenOptions: buildListenOptionsForMode(mode),
        onResult: (result) {
          if (listenGeneration != _activeListenGeneration) {
            return;
          }
          final text = result.recognizedWords.trim();
          if (text.isEmpty) {
            return;
          }
          final command = detectVoiceCommand(text);
          if (command != SttVoiceCommand.none) {
            final didHandle = _applyVoiceControlCommandForSpeechToText(
              command,
              latestRecognizedText ?? '',
              (nextText) {
                latestRecognizedText = nextText;
                _activeRecognizedText = nextText;
                onPartialResult?.call(nextText);
              },
              () => _completeActiveFailure(
                failure: SttListenFailure.silence,
                message: '음성 입력을 취소했어요.',
              ),
            );
            if (didHandle) {
              return;
            }
          }
          latestRecognizedText = text;
          _activeRecognizedText = text;
          onStatus?.call(
            const SttNativeStatusEvent(status: SttNativeStatus.speechStart),
          );
          onPartialResult?.call(text);
          if (result.finalResult &&
              (mode == SttListenMode.conversation || _userRequestedStop)) {
            completeSuccess(text);
          }
        },
      );

      return await completer.future.timeout(
        _listenForForMode(mode) + const Duration(seconds: 5),
        onTimeout: () async {
          await speech.cancel();
          final normalized = latestRecognizedText?.trim();
          if (normalized == null || normalized.isEmpty) {
            return SttListenResult.failure(
              failure: SttListenFailure.silence,
              message: _messageForSpeechError(latestSpeechError),
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

  Future<bool> _hasAndroidMicrophonePermission() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return true;
    }
    try {
      return await _androidPermissionsChannel.invokeMethod<bool>(
            'checkMicrophonePermission',
          ) ??
          false;
    } catch (error) {
      debugPrint('PlanFlow STT permission pre-check failed: $error');
      return false;
    }
  }

  static void _completeActiveListenFromText({bool detach = false}) {
    final completer = _activeCompleter;
    if (completer == null || completer.isCompleted) {
      debugPrint(
        '[STT] phase=complete_skipped gen=$_activeListenGeneration '
        'session=${_activeNativeSessionId ?? 0} detach=$detach reason='
        '${completer == null ? "completer_null" : "completer_completed"}',
      );
      if (detach) {
        _activeListenGeneration += 1;
        _clearActiveListenState(clearHandler: true);
      }
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
    if (detach) {
      _activeListenGeneration += 1;
      _clearActiveListenState(clearHandler: true);
    }
  }

  static void _completeActiveFailure({
    required SttListenFailure failure,
    required String message,
  }) {
    final completer = _activeCompleter;
    if (completer == null || completer.isCompleted) {
      debugPrint(
        '[STT] phase=failure_skipped gen=$_activeListenGeneration '
        'session=${_activeNativeSessionId ?? 0} failure=$failure reason='
        '${completer == null ? "completer_null" : "completer_completed"}',
      );
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
    ValueChanged<SttNativeStatusEvent>? onStatus,
    SttListenMode mode = SttListenMode.dictation,
    String attempt = 'first',
  }) async {
    final completer = Completer<SttListenResult>();
    final listenGeneration = ++_activeListenGeneration;
    final committedSegments = <String>[];
    String latestRecognizedText = '';
    var restartCount = 0;
    _activeNativeListen = true;
    _activeCommittedSegments = committedSegments;
    _activeNativeSessionText = '';
    _activeNativeSessionId = null;
    _activeCompleter = completer;
    _activeRecognizedText = null;
    _userRequestedStop = false;
    _logPhase('start', mode: mode, attempt: attempt);

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

    String? eventReason(Object? arguments) {
      if (arguments is Map) {
        final value = arguments['reason']?.toString().trim();
        return value == null || value.isEmpty ? null : value;
      }
      return null;
    }

    void emitStatus(
      SttNativeStatus status, {
      int restartCount = 0,
      String? reason,
    }) {
      onStatus?.call(
        SttNativeStatusEvent(
          status: status,
          restartCount: restartCount,
          reason: reason,
        ),
      );
    }

    bool acceptsEvent(Object? arguments) {
      if (listenGeneration != _activeListenGeneration) {
        return false;
      }
      final eventSession = eventSessionId(arguments);
      if (eventSession == null) {
        return _activeNativeListen;
      }
      if (eventSession == _expelledNativeSessionId) {
        return false;
      }
      _activeNativeSessionId ??= eventSession;
      if (_activeNativeSessionId != null) {
        _expelledNativeSessionId = null;
      }
      return eventSession == _activeNativeSessionId;
    }

    void setCommittedTranscript(String nextText) {
      if (listenGeneration != _activeListenGeneration) {
        return;
      }
      final normalized = nextText.trim();
      committedSegments
        ..clear()
        ..addAll([
          if (normalized.isNotEmpty) normalized,
        ]);
      _activeNativeSessionText = '';
      latestRecognizedText = normalized;
      _activeRecognizedText = normalized;
      onPartialResult?.call(normalized);
    }

    bool handleNativeVoiceControlCommand(
      String text, {
      bool includeCancel = true,
    }) {
      if (listenGeneration != _activeListenGeneration) {
        return true;
      }
      final command = detectVoiceCommand(text, includeCancel: includeCancel);
      if (command == SttVoiceCommand.none) {
        return false;
      }
      final didHandle = _applyVoiceControlCommandForSpeechToText(
        command,
        committedSegments.join(' ').trim(),
        setCommittedTranscript,
        () {
          _activeNativeSessionText = '';
          latestRecognizedText = committedSegments.join(' ').trim();
          _activeRecognizedText = latestRecognizedText;
          _completeActiveFailure(
            failure: SttListenFailure.silence,
            message: '음성 입력을 취소했어요.',
          );
        },
      );
      if (didHandle && command == SttVoiceCommand.clearAll) {
        unawaited(_resetNativeTranscript().then((id) {
          _activeNativeSessionId = id;
        }));
      }
      return didHandle;
    }

    void finishConversationMode(String text) {
      if (listenGeneration != _activeListenGeneration) {
        return;
      }
      _activeNativeListen = false;
      latestRecognizedText = text.trim();
      _activeRecognizedText = latestRecognizedText;
      _activeNativeSessionText = '';
      _completeActiveListenFromText(detach: true);
    }

    void updateRecognizedText(String incomingText) {
      if (listenGeneration != _activeListenGeneration) {
        return;
      }
      final recognizedWords = incomingText.trim();
      if (recognizedWords.isEmpty) {
        return;
      }
      if (handleNativeVoiceControlCommand(recognizedWords)) {
        return;
      }
      final committedText = committedSegments.join(' ').trim();
      final newSpeech = appendOnlyNewSpeech(committedText, recognizedWords);
      if (handleNativeVoiceControlCommand(
        newSpeech,
        includeCancel: recognizedWords == newSpeech,
      )) {
        return;
      }
      final mergedText = [
        if (committedText.isNotEmpty) committedText,
        if (newSpeech.isNotEmpty) newSpeech,
      ].join(' ').trim();
      _activeNativeSessionText = newSpeech;
      latestRecognizedText = mergedText;
      _activeRecognizedText = mergedText;
      onPartialResult?.call(mergedText);
    }

    bool commitActiveSession() {
      if (listenGeneration != _activeListenGeneration) {
        return false;
      }
      final text = _activeNativeSessionText.trim();
      if (text.isEmpty) {
        return false;
      }
      if (handleNativeVoiceControlCommand(text)) {
        return false;
      }
      final committedText = committedSegments.join(' ').trim();
      final mergedText = mergeTranscriptSegment(committedText, text);
      if (mergedText == committedText) {
        _activeNativeSessionText = '';
        latestRecognizedText = committedText;
        _activeRecognizedText = latestRecognizedText;
        return false;
      }
      committedSegments
        ..clear()
        ..add(mergedText);
      _activeNativeSessionText = '';
      latestRecognizedText = mergedText;
      _activeRecognizedText = latestRecognizedText;
      onPartialResult?.call(latestRecognizedText);
      return true;
    }

    _nativeSttChannel.setMethodCallHandler((call) async {
      if (!acceptsEvent(call.arguments)) {
        return;
      }
      switch (call.method) {
        case 'ready':
          emitStatus(SttNativeStatus.ready);
          break;
        case 'speechStart':
          emitStatus(SttNativeStatus.speechStart);
          break;
        case 'speechEnd':
          emitStatus(SttNativeStatus.speechEnd);
          break;
        case 'partial':
          emitStatus(SttNativeStatus.speechStart);
          updateRecognizedText(eventText(call.arguments));
          break;
        case 'stopped':
          emitStatus(SttNativeStatus.stopped);
          updateRecognizedText(eventText(call.arguments));
          commitActiveSession();
          if (mode == SttListenMode.conversation) {
            finishConversationMode(latestRecognizedText);
            break;
          }
          _completeActiveListenFromText(detach: true);
          break;
        case 'cancelled':
          emitStatus(SttNativeStatus.cancelled);
          _completeActiveFailure(
            failure: SttListenFailure.silence,
            message: '음성 입력을 취소했어요.',
          );
          break;
        case 'error':
          emitStatus(
            SttNativeStatus.error,
            reason: eventReason(call.arguments),
          );
          _completeActiveFailure(
            failure: SttListenFailure.unavailable,
            message: _genericMessage,
          );
          break;
        case 'restarted':
          restartCount += 1;
          emitStatus(
            SttNativeStatus.restarted,
            restartCount: restartCount,
            reason: eventReason(call.arguments),
          );
          final committed = commitActiveSession();
          if (!committed && restartCount > 1) {
            break;
          }
          onRestart?.call(restartCount);
          break;
        case 'segmentEnded':
          emitStatus(SttNativeStatus.segmentEnded);
          commitActiveSession();
          break;
        case 'stalled':
          emitStatus(
            SttNativeStatus.stalled,
            reason: eventReason(call.arguments),
          );
          break;
      }
    });

    try {
      final started =
          await _nativeSttChannel.invokeMethod<bool>('start', <String, dynamic>{
        'mode': mode.name,
        'silenceMs': mode == SttListenMode.conversation
            ? _conversationSilenceMs
            : _dictationSilenceMs,
      });
      if (started != true) {
        return SttListenResult.failure(
          failure: SttListenFailure.unavailable,
          message: _genericMessage,
        );
      }
      return await completer.future.timeout(
        _listenForForMode(mode) + const Duration(seconds: 5),
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

  static bool _isEmptySpeechError(String? errorMsg) {
    return errorMsg == 'error_no_match' ||
        errorMsg == 'error_speech_timeout' ||
        errorMsg == 'error_no_speech';
  }

  static String _messageForSpeechError(String? errorMsg) {
    if (_isEmptySpeechError(errorMsg)) {
      return _emptySpeechResultMessage;
    }
    return _silenceMessage;
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
const String _emptySpeechResultMessage =
    '말이 제대로 감지되지 않았어요. 다시 말해 주세요.';

const Set<String> _timePrefixTokens = <String>{
  '오전',
  '오후',
  '저녁',
  '아침',
  '점심',
  '밤',
};

final RegExp _dateTokenPattern = RegExp(r'^\d+(?:월|일)$');

/// "6월", "7일" 같은 숫자형 날짜 토큰인지 판별한다.
bool _isDateToken(String token) => _dateTokenPattern.hasMatch(token);

const Set<String> _undoLastWordCommandTokens = <String>{
  '아니',
  '아니야',
  '아니요',
  '아니다',
};
const Set<String> _undoLastSegmentCommandTokens = <String>{
  '마지막거지워',
  '방금거지워',
  '마지막삭제',
  '방금삭제',
};
const Set<String> _clearAllCommandTokens = <String>{
  '다시',
  '처음부터',
  '다시말할게',
  '전체삭제',
  '전체취소',
};
const Set<String> _stopCommandTokens = <String>{
  '취소',
  '취소해',
  '취소해줘',
  '취소해주세요',
  '그만',
  '그만해',
  '그만해줘',
  '그만해주세요',
  '중단',
  '중단해',
  '중단해줘',
  '중단해주세요',
  '중지',
  '중지해',
  '중지해줘',
  '중지해주세요',
  '정지',
  '정지해',
  '정지해줘',
  '정지해주세요',
};

class _VoiceCommandMatch {
  const _VoiceCommandMatch(this.command, this.consumedTokens);

  final SttVoiceCommand command;
  final int consumedTokens;
}
