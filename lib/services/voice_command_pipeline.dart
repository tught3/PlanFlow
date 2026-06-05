import 'package:flutter/foundation.dart';

import 'voice_text_cleanup_service.dart';

enum VoiceCommandPipelineIntent {
  add,
  edit,
  delete,
  query,
  choose,
}

class VoiceCommandPlan {
  const VoiceCommandPlan({
    required this.rawText,
    required this.cleanedText,
    required this.normalizedText,
    required this.intent,
    required this.targetText,
    required this.changeText,
    required this.targetQuery,
    required this.requestedChanges,
    required this.requestedFieldValues,
    required this.confidence,
    required this.requiresUserChoice,
    required this.safeDirectApply,
  });

  final String rawText;
  final String cleanedText;
  final String normalizedText;
  final VoiceCommandPipelineIntent intent;
  final String targetText;
  final String changeText;
  final String targetQuery;
  final List<String> requestedChanges;
  final Map<String, String> requestedFieldValues;
  final double confidence;
  final bool requiresUserChoice;
  final bool safeDirectApply;
}

class VoiceCommandPipeline {
  const VoiceCommandPipeline();

  void _logStage(
    String stage, {
    String? intent,
    String? reason,
  }) {
    final parts = <String>[
      '[PIPE] stage=$stage',
      if (intent != null && intent.isNotEmpty) 'intent=$intent',
      if (reason != null && reason.isNotEmpty) 'reason=$reason',
    ];
    debugPrint(parts.join(' '));
  }

  VoiceCommandPlan analyze(
    String rawText, {
    VoiceCommandPipelineIntent? intent,
    VoiceTextCleanupContext context = VoiceTextCleanupContext.add,
    Iterable<VoiceTextCleanupCandidate> candidates = const [],
  }) {
    _logStage('analyze_start');
    final cleanup = VoiceTextCleanupService.cleanLocally(
      rawText,
      context: context,
      candidates: candidates,
    );
    final cleanedText = cleanup.cleanedText;
    final normalizedText = normalizeManagementText(cleanedText);
    final resolvedIntent =
        intent ?? resolveIntent(cleanedText, context: context);
    final requestedChanges = extractRequestedChanges(cleanedText);
    final split = splitCommand(
      normalizedText,
      intent: resolvedIntent,
      requestedChanges: requestedChanges,
    );
    _logStage(
      'split',
      intent: resolvedIntent.name,
      reason: split.targetText.trim().isEmpty ? 'no_target' : 'target_ok',
    );
    final fieldValues = extractRequestedFieldValues(
      split,
      requestedChanges: requestedChanges,
    );
    final targetQuery = buildTargetQuery(
      split.targetText,
      fallbackText: normalizedText,
      intent: resolvedIntent,
    );
    final requiresUserChoice =
        resolvedIntent == VoiceCommandPipelineIntent.choose ||
            resolvedIntent == VoiceCommandPipelineIntent.delete;
    final safeDirectApply = resolvedIntent == VoiceCommandPipelineIntent.edit &&
        !requiresUserChoice &&
        requestedChanges.isNotEmpty &&
        !requestedChanges.contains('location') &&
        !requestedChanges.contains('title') &&
        !requestedChanges.contains('memo');
    _logStage(
      'analyze_done',
      intent: resolvedIntent.name,
      reason: safeDirectApply ? 'safe_direct_apply' : 'standard',
    );

    return VoiceCommandPlan(
      rawText: cleanup.originalText,
      cleanedText: cleanedText,
      normalizedText: normalizedText,
      intent: resolvedIntent,
      targetText: split.targetText,
      changeText: split.changeText,
      targetQuery: targetQuery,
      requestedChanges: List<String>.unmodifiable(requestedChanges),
      requestedFieldValues: Map<String, String>.unmodifiable(fieldValues),
      confidence: _confidenceFor(
        intent: resolvedIntent,
        split: split,
        requestedChanges: requestedChanges,
      ),
      requiresUserChoice: requiresUserChoice,
      safeDirectApply: safeDirectApply,
    );
  }

  VoiceCommandPipelineIntent resolveIntent(
    String text, {
    VoiceTextCleanupContext context = VoiceTextCleanupContext.add,
  }) {
    final normalized = normalizeManagementText(text);
    final strongScheduleAdd = _hasStrongScheduleCreationCue(normalized);
    if (strongScheduleAdd && !_hasExplicitManagementDeleteCue(normalized)) {
      return VoiceCommandPipelineIntent.add;
    }
    if (_hasDeleteIntentCue(normalized)) {
      return VoiceCommandPipelineIntent.delete;
    }
    if (RegExp(r'(수정|변경|바꿔|미뤄|밀어|앞당겨|옮겨|이동|고쳐|편집|연기|늦춰|당겨)')
        .hasMatch(normalized)) {
      return VoiceCommandPipelineIntent.edit;
    }
    if (_isClearLocationFieldAddition(normalized)) {
      return VoiceCommandPipelineIntent.edit;
    }
    if (isAmbiguousFieldAddition(normalized)) {
      return VoiceCommandPipelineIntent.choose;
    }
    if (_hasAddIntentCue(normalized) || strongScheduleAdd) {
      return VoiceCommandPipelineIntent.add;
    }
    if (_hasAmbiguousQueryIntentCue(normalized)) {
      return VoiceCommandPipelineIntent.choose;
    }
    if (_hasQueryIntentCue(normalized)) {
      return VoiceCommandPipelineIntent.query;
    }
    return switch (context) {
      VoiceTextCleanupContext.delete => VoiceCommandPipelineIntent.delete,
      VoiceTextCleanupContext.edit => VoiceCommandPipelineIntent.edit,
      VoiceTextCleanupContext.query => VoiceCommandPipelineIntent.query,
      VoiceTextCleanupContext.add => VoiceCommandPipelineIntent.add,
    };
  }

  VoiceCommandSplit splitCommand(
    String normalizedText, {
    required VoiceCommandPipelineIntent intent,
    required List<String> requestedChanges,
  }) {
    if (intent == VoiceCommandPipelineIntent.delete) {
      final target = normalizedText
          .replaceAll(
            RegExp(
              r'(?:일정|스케줄|약속)?\s*(?:삭제|지워|없애|취소|제거)(?:해주세요|해\s*줘|해줘|시켜\s*줘|시켜줘|해)?',
            ),
            ' ',
          )
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
      return VoiceCommandSplit(
        targetText: target,
        changeText: '',
      );
    }

    if (intent == VoiceCommandPipelineIntent.edit) {
      if (requestedChanges.contains('location')) {
        final split = _splitLocationChange(normalizedText);
        if (split != null) {
          return split;
        }
        _logStage('split_location', intent: intent.name, reason: 'no_split');
      }
      if (requestedChanges.contains('start_at')) {
        final split = _splitDateTimeChange(normalizedText);
        if (split != null) {
          return split;
        }
        _logStage('split_datetime', intent: intent.name, reason: 'no_split');
      }
    }

    return VoiceCommandSplit(targetText: normalizedText, changeText: '');
  }

  String buildTargetQuery(
    String targetText, {
    required String fallbackText,
    required VoiceCommandPipelineIntent intent,
  }) {
    final normalized = targetText.trim().isEmpty ? fallbackText : targetText;
    if (targetText.trim().isEmpty &&
        intent == VoiceCommandPipelineIntent.delete) {
      return '';
    }
    final tokens = searchTokens(normalized);
    if (tokens.isNotEmpty) {
      return tokens.join(' ');
    }
    return normalized;
  }

  List<String> extractRequestedChanges(String text) {
    final normalized = normalizeManagementText(text);
    final changes = <String>{};
    if (RegExp(
      r'(시간|시각|언제|몇\s*시|오전|오후|아침|점심|저녁|밤|오늘|내일|모레|글피|이번\s*주|다음\s*주|이번주|다음주|[월화수목금토일]요일|(?:그\s*)?다음\s*날|(?:하루|이틀|삼일|\d+\s*일)\s*(?:뒤|후|전|앞)|연기|미뤄|밀어|옮겨|이동|앞당겨|늦춰|당겨|바꿔|변경|수정)',
    ).hasMatch(normalized)) {
      changes.add('start_at');
    }
    if (RegExp(r'(장소|위치|어디|주소|가는\s*길|오시는\s*길)').hasMatch(normalized)) {
      changes.add('location');
    }
    if (RegExp(r'(제목|이름|명칭|무슨\s*일|내용|텍스트)').hasMatch(normalized)) {
      changes.add('title');
    }
    if (RegExp(r'(메모|설명|노트|비고)').hasMatch(normalized)) {
      changes.add('memo');
    }
    if (RegExp(r'(반복|매주|매월|매년|격주)').hasMatch(normalized)) {
      changes.add('recurrence_rule');
    }
    if (RegExp(r'(하루\s*종일|하루종일|종일|온종일)').hasMatch(normalized)) {
      changes.add('is_all_day');
    }
    if (RegExp(
      r'(중요하게\s*표시|중요\s*표시|중요|긴급|급한|critical|중요한)\s*(알람|알림|경보|표시)?',
    ).hasMatch(normalized)) {
      changes.add('is_critical_true');
    }
    if (RegExp(
      r'(보통(?:으로)?|일반(?:으로)?|normal)\s*(알람|알림|경보|표시)?',
    ).hasMatch(normalized)) {
      changes.add('is_critical_false');
    }
    return changes.toList(growable: false);
  }

  Map<String, String> extractRequestedFieldValues(
    VoiceCommandSplit split, {
    required List<String> requestedChanges,
  }) {
    final values = <String, String>{};
    if (requestedChanges.contains('location')) {
      final location = _extractRequestedLocation(split.changeText);
      if (location != null) {
        values['location'] = location;
      }
    }
    if (requestedChanges.contains('is_critical_true')) {
      values['is_critical'] = 'true';
    } else if (requestedChanges.contains('is_critical_false')) {
      values['is_critical'] = 'false';
    }
    return values;
  }

  List<String> searchTokens(String text) {
    final normalized = normalizeManagementText(text);
    if (normalized.isEmpty) {
      return <String>[];
    }

    final seen = <String>{};
    final baseTokens = normalized
        .replaceAll(RegExp(r'[^0-9a-z가-힣\s]'), ' ')
        .split(RegExp(r'\s+'))
        .expand(tokenVariants)
        .map(stripKoreanParticles)
        .where(
          (token) =>
              token.length >= 2 &&
              !stopWords.contains(token) &&
              seen.add(token),
        )
        .toList(growable: false);

    if (baseTokens.isNotEmpty) {
      return baseTokens;
    }

    return normalized
        .split(RegExp(r'\s+'))
        .map(stripKoreanParticles)
        .where((token) => token.length >= 2)
        .toList(growable: false);
  }

  bool isAmbiguousFieldAddition(String text) {
    final normalized = normalizeManagementText(text);
    if (!RegExp(
      r'(장소|위치|주소)\s*(?:를|을|으로|로)?\s*(?:추가|넣어|입력|설정|등록)',
    ).hasMatch(normalized)) {
      return false;
    }
    if (_isClearLocationFieldAddition(normalized)) {
      return false;
    }
    return true;
  }

  String normalizeManagementText(String text) {
    return VoiceTextCleanupService.normalizeBasic(text).toLowerCase();
  }

  List<String> analysisTokens(String text) {
    final normalized = normalizeManagementText(text);
    if (normalized.isEmpty) {
      return <String>[];
    }
    return normalized
        .replaceAll(RegExp(r'[^0-9a-z가-힣\s]'), ' ')
        .split(RegExp(r'\s+'))
        .map(stripKoreanParticles)
        .where((token) => token.isNotEmpty)
        .toList(growable: false);
  }

  List<String> tokenVariants(String rawToken) {
    final token = stripKoreanParticles(rawToken.trim());
    if (token.isEmpty) {
      return const <String>[];
    }
    final variants = <String>{token};
    final withoutSchedule = token.replaceAll(RegExp(r'(일정|스케줄)$'), '');
    if (withoutSchedule.length >= 2) {
      variants.add(withoutSchedule);
    }
    if (token.endsWith('전달일정')) {
      variants.add(token.replaceFirst(RegExp(r'일정$'), ''));
    }
    final withoutQuoteEnding =
        token.replaceAll(RegExp(r'(이라고|라고|이라는|라는)$'), '');
    if (withoutQuoteEnding.length >= 2) {
      variants.add(withoutQuoteEnding);
    }
    return variants.toList(growable: false);
  }

  String stripKoreanParticles(String token) {
    var value = token.toLowerCase().trim();
    for (final suffix in const <String>[
      '으로써',
      '으로서',
      '에서',
      '에게',
      '께',
      '까지',
      '부터',
      '처럼',
      '보다',
      '만',
      '도',
      '은',
      '는',
      '이',
      '가',
      '을',
      '를',
      '와',
      '과',
      '에',
      '로',
      '의',
      '라고',
      '이라고',
    ]) {
      if (value.length > suffix.length && value.endsWith(suffix)) {
        value = value.substring(0, value.length - suffix.length);
        break;
      }
    }
    return value;
  }

  VoiceCommandSplit? _splitLocationChange(String normalizedText) {
    final operation = RegExp(
      r'(?:장소|위치|주소)\s*(?:를|을|으로|로)?\s*(?:추가|넣어|입력|설정|등록|변경|바꿔|수정).*?$',
    ).firstMatch(normalizedText);
    if (operation == null) {
      return null;
    }

    final beforeOperation = normalizedText.substring(0, operation.start).trim();
    final operationText = normalizedText.substring(operation.start).trim();
    var targetText = beforeOperation;
    var changePrefix = beforeOperation;

    final boundaries =
        RegExp(r'(?:일정|스케줄|약속)에\s+').allMatches(beforeOperation).toList();
    if (boundaries.isNotEmpty) {
      final boundary = boundaries.last;
      targetText = beforeOperation.substring(0, boundary.start + 2).trim();
      changePrefix = beforeOperation.substring(boundary.end).trim();
    }

    final changeText = [changePrefix, operationText]
        .where((part) => part.trim().isNotEmpty)
        .join(' ')
        .trim();
    if (targetText.isEmpty || changeText.isEmpty) {
      return null;
    }
    return VoiceCommandSplit(targetText: targetText, changeText: changeText);
  }

  VoiceCommandSplit? _splitDateTimeChange(String normalizedText) {
    final verbMatches = RegExp(
      r'(?:로|으로)?\s*(?:변경|바꿔|수정|옮겨|이동|미뤄|밀어|연기|앞당겨|늦춰|당겨).*?$',
    ).allMatches(normalizedText).toList(growable: false);
    if (verbMatches.isEmpty) {
      return null;
    }
    final verb = verbMatches.last;
    final beforeVerb = normalizedText.substring(0, verb.start).trim();
    final valueMatch = _lastDateTimeValueMatch(beforeVerb);
    if (valueMatch == null) {
      return null;
    }
    final targetText = beforeVerb.substring(0, valueMatch.start).trim();
    final changeText = normalizedText.substring(valueMatch.start).trim();
    if (targetText.isEmpty || changeText.isEmpty) {
      return null;
    }
    return VoiceCommandSplit(targetText: targetText, changeText: changeText);
  }

  RegExpMatch? _lastDateTimeValueMatch(String text) {
    final patterns = <RegExp>[
      RegExp(
        r'((?:그\s*)?다음\s*날(?:로|에|으로)?|(?:하루|이틀|삼일|\d+\s*일)\s*(?:뒤|후)(?:로|에|으로)?|(?:하루|이틀|삼일|\d+\s*일)\s*(?:전|앞)(?:으로|로|에)?)',
      ),
      RegExp(
        r'((?:이번|다음)\s*주\s*)?[월화수목금토일]요일(?:\s*(?:오전|오후|아침|낮|점심|저녁|밤|새벽)?\s*(?:[0-9]{1,2}|[가-힣]{1,8})\s*시(?:\s*(?:[0-9]{1,2}|[가-힣]{1,8})\s*분?|\s*반)?)?',
      ),
      RegExp(
        r'(오늘|내일|모레|글피)(?:\s*(?:오전|오후|아침|낮|점심|저녁|밤|새벽)?\s*(?:[0-9]{1,2}|[가-힣]{1,8})\s*시(?:\s*(?:[0-9]{1,2}|[가-힣]{1,8})\s*분?|\s*반)?)?',
      ),
      RegExp(
        r'(?:\d{4}\s*년\s*)?\d{1,2}\s*월\s*\d{1,2}\s*일(?:\s*(?:오전|오후|아침|낮|점심|저녁|밤|새벽)?\s*(?:[0-9]{1,2}|[가-힣]{1,8})\s*시(?:\s*(?:[0-9]{1,2}|[가-힣]{1,8})\s*분?|\s*반)?)?',
      ),
      RegExp(
        r'(?:오전|오후|아침|낮|점심|저녁|밤|새벽)?\s*(?:[0-9]{1,2}|[가-힣]{1,8})\s*시(?:\s*(?:[0-9]{1,2}|[가-힣]{1,8})\s*분?|\s*반)?',
      ),
    ];

    RegExpMatch? latest;
    for (final pattern in patterns) {
      for (final match in pattern.allMatches(text)) {
        final value = match.group(0)?.trim() ?? '';
        if (value.isEmpty) {
          continue;
        }
        if (latest == null ||
            match.end > latest.end ||
            (match.end == latest.end && match.start < latest.start)) {
          latest = match;
        }
      }
    }
    return latest;
  }

  String? _extractRequestedLocation(String changeText) {
    final text = changeText.trim();
    if (text.isEmpty) {
      return null;
    }
    final match = RegExp(
      r'(?:장소|위치|주소)\s*(?:를|을)?\s*(.+?)(?:로|으로)\s*(?:변경|바꿔|수정)|(.+?)(?:로|으로)?\s*(?:장소|위치|주소)\s*(?:추가|넣어|입력|설정|등록)',
    ).firstMatch(text);
    final prefixLocation = match?.group(1)?.trim();
    final suffixLocation = match?.group(2)?.trim();
    final location = prefixLocation == null || prefixLocation.isEmpty
        ? suffixLocation
        : prefixLocation;
    if (location == null || location.isEmpty) {
      return null;
    }
    return location
        .replaceAll(RegExp(r'\s+'), ' ')
        .replaceAll(RegExp(r'^(?:에|로|으로)\s+'), '')
        .trim();
  }

  double _confidenceFor({
    required VoiceCommandPipelineIntent intent,
    required VoiceCommandSplit split,
    required List<String> requestedChanges,
  }) {
    var confidence = 0.45;
    if (intent != VoiceCommandPipelineIntent.choose) {
      confidence += 0.15;
    }
    if (split.targetText.trim().isNotEmpty) {
      confidence += 0.15;
    }
    if (split.changeText.trim().isNotEmpty || requestedChanges.isNotEmpty) {
      confidence += 0.15;
    }
    return confidence.clamp(0.05, 0.95).toDouble();
  }

  bool _hasAddIntentCue(String text) {
    final normalized = normalizeManagementText(text);
    return _hasExplicitAddIntentCue(normalized) ||
        _hasRecurringLookupAddCue(normalized) ||
        (_looksLikeScheduleContentToConfirm(normalized) &&
            _hasScheduleCue(normalized));
  }

  bool _hasStrongScheduleCreationCue(String text) {
    final normalized = normalizeManagementText(text);
    if (!_hasScheduleCue(normalized)) {
      return false;
    }
    if (_hasQueryIntentCueRaw(normalized)) {
      return false;
    }
    if (_hasRecurringLookupAddCue(normalized)) {
      return true;
    }
    final hasActionOrObject = RegExp(
      r'(전화|방문|참석|작성|제출|예약|결제|회의|미팅|조회|취소\s*하기|취소하기|가기|만나|물어|확인|하기|하기로)',
    ).hasMatch(normalized);
    final hasTime = RegExp(
      r'(오전|오후|아침|낮|점심|저녁|밤|새벽)?\s*[0-9가-힣]{1,8}\s*시',
    ).hasMatch(normalized);
    return hasTime && hasActionOrObject;
  }

  bool _hasDeleteIntentCue(String text) {
    final normalized = normalizeManagementText(text);
    if (!RegExp(r'(삭제|지워|없애|취소|제거)').hasMatch(normalized)) {
      return false;
    }
    if (_hasStrongScheduleCreationCue(normalized) &&
        !_hasExplicitManagementDeleteCue(normalized)) {
      return false;
    }
    return _hasExplicitManagementDeleteCue(normalized) ||
        RegExp(r'(\d+\s*번|첫\s*번째|두\s*번째|세\s*번째|네\s*번째|이\s*일정|그\s*일정|해당\s*일정).*(삭제|지워|없애|취소|제거)')
            .hasMatch(normalized);
  }

  bool _hasExplicitManagementDeleteCue(String text) {
    final normalized = normalizeManagementText(text);
    return RegExp(
      r'((일정|스케줄|약속)\s*(삭제|지워|없애|취소|제거)|(삭제|지워|없애|제거)\s*(해|해줘|해주세요)|(취소)\s*(해|해줘|해주세요))',
    ).hasMatch(normalized);
  }

  bool _hasExplicitAddIntentCue(String text) {
    final normalized = normalizeManagementText(text);
    return RegExp(
      r'(추가|등록|저장(?!된|한|되어|돼)|기록|예약|만들어|일정으로|하기로\s*저장|로\s*저장|메모\s*(?:해|해줘|남겨|기록|저장|추가))',
    ).hasMatch(normalized);
  }

  bool _hasRecurringLookupAddCue(String text) {
    final normalized = normalizeManagementText(text);
    return RegExp(
      r'((?:매월\s*)?(?:월례|정기|회사)\s*조회)',
    ).hasMatch(normalized);
  }

  bool _hasAmbiguousQueryIntentCue(String text) {
    final normalized = normalizeManagementText(text);
    return RegExp(r'^조회$').hasMatch(normalized);
  }

  bool _looksLikeScheduleContentToConfirm(String text) {
    final normalized = normalizeManagementText(text);
    if (!normalized.endsWith('확인하기')) {
      return false;
    }
    if (RegExp(r'^(오늘|내일|모레|글피)?\s*일정\s*확인하기$').hasMatch(normalized)) {
      return false;
    }
    return true;
  }

  bool _hasQueryIntentCue(String text) {
    final normalized = normalizeManagementText(text);
    if (_hasStrongScheduleCreationCue(normalized) ||
        _hasRecurringLookupAddCue(normalized)) {
      return false;
    }
    return _hasQueryIntentCueRaw(normalized);
  }

  bool _hasQueryIntentCueRaw(String text) {
    final normalized = normalizeManagementText(text);
    return RegExp(
      r'(찾아\s*줘|찾아\s*주세요|검색'
      r'|알려\s*줘|알려\s*주세요'
      r'|언제|언제야|언제인지|언제예요'
      r'|어디|뭐야|뭐예요|뭐가|무슨'
      r'|몇\s*시|몇시야|몇시에|몇\s*시야|몇\s*시에'
      r'|있어|있어요|있나|있나요|있는지|있을까'
      r'|보여\s*줘|보여\s*주세요|일정\s*확인|확인해\s*줘|확인해\s*주세요'
      r'|어떻게\s*돼|어떻게\s*됐|어떻게\s*되'
      r'|어떤\s*일정|뭐\s*있어)',
    ).hasMatch(normalized);
  }

  bool _hasScheduleCue(String text) {
    final normalized = normalizeManagementText(text);
    return _parseDateTimeHint(normalized) != null ||
        RegExp(
          r'(오늘|내일|모레|글피|이번주|다음주|이번\s*주|다음\s*주|[월화수목금토일]요일)',
        ).hasMatch(normalized);
  }

  bool _isClearLocationFieldAddition(String text) {
    final normalized = normalizeManagementText(text);
    final operation = RegExp(
      r'(?:장소|위치|주소)\s*(?:를|을|으로|로)?\s*(?:추가|넣어|입력|설정|등록).*?$',
    ).firstMatch(normalized);
    if (operation == null) {
      return false;
    }

    final beforeOperation = normalized.substring(0, operation.start).trim();
    final boundaries =
        RegExp(r'(?:일정|스케줄|약속)에\s+').allMatches(beforeOperation).toList();
    if (boundaries.isEmpty) {
      return false;
    }

    final boundary = boundaries.last;
    final target = beforeOperation.substring(0, boundary.start + 2).trim();
    final locationPrefix = beforeOperation.substring(boundary.end).trim();
    if (target.isEmpty || locationPrefix.isEmpty) {
      return false;
    }

    final split = _splitLocationChange(normalized);
    if (split == null) {
      return false;
    }
    final location = _extractRequestedLocation(split.changeText);
    return location != null && location.trim().isNotEmpty;
  }

  DateTime? _parseDateTimeHint(String text) {
    final dayMatch = RegExp(r'(오늘|내일|모레|글피)').firstMatch(text);
    if (dayMatch != null) {
      return DateTime.now();
    }
    if (RegExp(r'(오전|오후|아침|낮|점심|저녁|밤|새벽)?\s*[0-9가-힣]{1,8}\s*시')
        .hasMatch(text)) {
      return DateTime.now();
    }
    return null;
  }

  static const Set<String> stopWords = {
    '일정',
    '수정',
    '수정해',
    '변경',
    '변경해',
    '바꿔',
    '고쳐',
    '고치',
    '삭제',
    '삭제해',
    '추가',
    '등록',
    '보여',
    '찾아',
    '조회',
    '바꾸',
    '옮겨',
    '이동',
    '옮기',
    '미뤄',
    '미루',
    '밀어',
    '연기',
    '앞당겨',
    '당겨',
    '늦춰',
    '늦추',
    '선택',
    '이걸로',
    '이거',
    '그걸로',
    '골라',
    '첫번째',
    '두번째',
    '셋째',
    '시간',
    '날짜',
    '장소',
    '위치',
    '오늘',
    '내일',
    '모레',
    '글피',
    '이번',
    '이번주',
    '이번 주',
    '다음주',
    '다음 주',
    '월요일',
    '화요일',
    '수요일',
    '목요일',
    '금요일',
    '토요일',
    '일요일',
    '오전',
    '오후',
    '아침',
    '점심',
    '저녁',
    '밤',
    '무엇',
    '뭐',
    '되어',
    '있는',
    '이라고',
    '라고',
    '이름',
    '제목',
    '확인',
    '확인해',
    '확인하기',
    '확인하기로',
    '확인해줘',
    '확인해주세요',
    '해줘',
    '주세요',
    '해주세요',
    '좀',
    '하자',
    '하자고',
    '해야',
    '할까',
    '하는',
    '사이',
  };
}

class VoiceCommandSplit {
  const VoiceCommandSplit({
    required this.targetText,
    required this.changeText,
  });

  final String targetText;
  final String changeText;
}
