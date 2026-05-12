import 'voice_text_cleanup_service.dart';

enum VoiceCommandRouteIntent {
  add,
  edit,
  delete,
  query,
  choose,
}

class VoiceCommandRouteResult {
  const VoiceCommandRouteResult({
    required this.rawText,
    required this.cleanedText,
    required this.normalizedText,
    required this.intent,
    required this.targetQuery,
    required this.requestedChanges,
  });

  final String rawText;
  final String cleanedText;
  final String normalizedText;
  final VoiceCommandRouteIntent intent;
  final String targetQuery;
  final List<String> requestedChanges;
}

class VoiceCommandRouter {
  const VoiceCommandRouter();

  VoiceCommandRouteIntent resolveIntent(
    String text, {
    VoiceTextCleanupContext context = VoiceTextCleanupContext.add,
  }) {
    final normalized = normalizeManagementText(text);
    if (RegExp(r'(삭제|지워|없애|취소|제거)').hasMatch(normalized)) {
      return VoiceCommandRouteIntent.delete;
    }
    if (RegExp(r'(수정|변경|바꿔|미뤄|앞당겨|옮겨|고쳐|편집|연기|늦춰|당겨)').hasMatch(normalized)) {
      return VoiceCommandRouteIntent.edit;
    }
    if (_hasAddIntentCue(normalized)) {
      return VoiceCommandRouteIntent.add;
    }
    if (_hasQueryIntentCue(normalized)) {
      return VoiceCommandRouteIntent.query;
    }
    if (RegExp(r'(선택|이걸로|이거|그걸로|골라|첫번째|두번째|셋째)').hasMatch(normalized)) {
      return VoiceCommandRouteIntent.choose;
    }
    return switch (context) {
      VoiceTextCleanupContext.delete => VoiceCommandRouteIntent.delete,
      VoiceTextCleanupContext.edit => VoiceCommandRouteIntent.edit,
      VoiceTextCleanupContext.query => VoiceCommandRouteIntent.query,
      VoiceTextCleanupContext.add => VoiceCommandRouteIntent.add,
    };
  }

  VoiceCommandRouteResult route(
    String rawText, {
    VoiceCommandRouteIntent? intent,
    VoiceTextCleanupContext context = VoiceTextCleanupContext.add,
    Iterable<VoiceTextCleanupCandidate> candidates = const [],
  }) {
    final cleanup = VoiceTextCleanupService.cleanLocally(
      rawText,
      context: context,
      candidates: candidates,
    );
    final resolvedIntent =
        intent ?? resolveIntent(cleanup.cleanedText, context: context);
    final requestedChanges = extractRequestedChanges(cleanup.cleanedText);
    final targetQuery = buildTargetQuery(
      cleanup.cleanedText,
      intent: resolvedIntent,
      requestedChanges: requestedChanges,
      candidates: candidates,
      context: context,
    );
    return VoiceCommandRouteResult(
      rawText: cleanup.originalText,
      cleanedText: cleanup.cleanedText,
      normalizedText: normalizeManagementText(cleanup.cleanedText),
      intent: resolvedIntent,
      targetQuery: targetQuery,
      requestedChanges: List<String>.unmodifiable(requestedChanges),
    );
  }

  String buildTargetQuery(
    String text, {
    required VoiceCommandRouteIntent intent,
    Iterable<VoiceTextCleanupCandidate> candidates = const [],
    List<String> requestedChanges = const [],
    VoiceTextCleanupContext context = VoiceTextCleanupContext.add,
  }) {
    final normalized = normalizeManagementText(text);
    final tokens = searchTokens(
      normalized,
      intent: intent,
      requestedChanges: requestedChanges,
      candidates: candidates,
      context: context,
    );
    if (tokens.isNotEmpty) {
      return tokens.join(' ');
    }
    return normalized;
  }

  List<String> extractRequestedChanges(String text) {
    final normalized = normalizeManagementText(text);
    final changes = <String>{};
    if (RegExp(
      r'(시간|시각|언제|몇\s*시|오전|오후|아침|점심|저녁|밤|오늘|내일|모레|글피|이번\s*주|다음\s*주|이번주|다음주|[월화수목금토일]요일|연기|미뤄|옮겨|앞당겨|늦춰|당겨|바꿔|변경|수정)',
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
    return changes.toList(growable: false);
  }

  Map<String, dynamic>? buildTargetEventHint(
    String text,
    Iterable<VoiceTextCleanupCandidate> candidates, {
    VoiceTextCleanupContext context = VoiceTextCleanupContext.add,
  }) {
    if (context == VoiceTextCleanupContext.add || candidates.isEmpty) {
      return null;
    }

    final queryTokens = analysisTokens(text);
    if (queryTokens.isEmpty) {
      return null;
    }

    VoiceTextCleanupCandidate? bestCandidate;
    var bestScore = 0;
    for (final candidate in candidates) {
      final candidateTokens = analysisTokens(candidate.searchableText);
      if (candidateTokens.isEmpty) {
        continue;
      }
      final score =
          queryTokens.toSet().intersection(candidateTokens.toSet()).length;
      if (score > bestScore) {
        bestScore = score;
        bestCandidate = candidate;
      }
    }

    if (bestCandidate == null || bestScore == 0) {
      return null;
    }

    return <String, dynamic>{
      'title': bestCandidate.title,
      if (bestCandidate.location != null &&
          bestCandidate.location!.trim().isNotEmpty)
        'location': bestCandidate.location!.trim(),
      if (bestCandidate.startAt != null)
        'start_at': bestCandidate.startAt!.toIso8601String(),
      'score': bestScore,
    };
  }

  List<String> searchTokens(
    String text, {
    VoiceCommandRouteIntent? intent,
    List<String> requestedChanges = const [],
    Iterable<VoiceTextCleanupCandidate> candidates = const [],
    VoiceTextCleanupContext context = VoiceTextCleanupContext.add,
  }) {
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

    return normalizeManagementText(text)
        .split(RegExp(r'\s+'))
        .map(stripKoreanParticles)
        .where((token) => token.length >= 2)
        .toList(growable: false);
  }

  bool hasFuzzyTokenMatch(String token, List<String> searchableTokens) {
    if (token.length < 3) {
      return false;
    }
    for (final candidate in searchableTokens) {
      if (candidate.length < 3) {
        continue;
      }
      if ((candidate.length - token.length).abs() > 1) {
        continue;
      }
      if (editDistanceAtMostOne(token, candidate)) {
        return true;
      }
    }
    return false;
  }

  bool editDistanceAtMostOne(String left, String right) {
    if (left == right) {
      return true;
    }
    if ((left.length - right.length).abs() > 1) {
      return false;
    }
    var leftIndex = 0;
    var rightIndex = 0;
    var edits = 0;
    while (leftIndex < left.length && rightIndex < right.length) {
      if (left.codeUnitAt(leftIndex) == right.codeUnitAt(rightIndex)) {
        leftIndex += 1;
        rightIndex += 1;
        continue;
      }
      edits += 1;
      if (edits > 1) {
        return false;
      }
      if (left.length > right.length) {
        leftIndex += 1;
      } else if (right.length > left.length) {
        rightIndex += 1;
      } else {
        leftIndex += 1;
        rightIndex += 1;
      }
    }
    if (leftIndex < left.length || rightIndex < right.length) {
      edits += 1;
    }
    return edits <= 1;
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

  bool _hasAddIntentCue(String text) {
    final normalized = normalizeManagementText(text);
    return RegExp(
          r'(추가|등록|저장(?!된|한|되어|돼)|기록|메모|예약|만들어|일정으로|하기로\s*저장|로\s*저장)',
        ).hasMatch(normalized) ||
        (normalized.endsWith('확인하기') && _hasScheduleCue(normalized));
  }

  bool _hasQueryIntentCue(String text) {
    final normalized = normalizeManagementText(text);
    return RegExp(
      r'(찾아\s*줘|찾아\s*주세요|검색|알려\s*줘|알려\s*주세요|언제|어디|뭐야|조회|보여\s*줘|보여\s*주세요|일정\s*확인|확인해\s*줘|확인해\s*주세요)',
    ).hasMatch(normalized);
  }

  bool _hasScheduleCue(String text) {
    final normalized = normalizeManagementText(text);
    return _parseDateTimeHint(normalized) != null ||
        RegExp(r'(오늘|내일|모레|글피|이번주|다음주|이번\s*주|다음\s*주)').hasMatch(normalized);
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
    '옮기',
    '미뤄',
    '미루',
    '연기',
    '앞당겨',
    '당겨',
    '늦춰',
    '늦추',
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
