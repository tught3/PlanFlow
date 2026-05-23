enum VoiceTextCleanupContext {
  add,
  edit,
  delete,
  query,
}

enum VoiceTextCleanupMethod {
  none,
  local,
  ai,
}

class VoiceTextCleanupCandidate {
  const VoiceTextCleanupCandidate({
    required this.title,
    this.location,
    this.startAt,
  });

  final String title;
  final String? location;
  final DateTime? startAt;

  String get searchableText => [title, location ?? '']
      .join(' ')
      .replaceAll(RegExp(r'[^0-9a-zA-Z가-힣\s]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}

class VoiceTextCleanupResult {
  const VoiceTextCleanupResult({
    required this.originalText,
    required this.cleanedText,
    required this.changed,
    required this.method,
    required this.reason,
    required this.confidence,
  });

  factory VoiceTextCleanupResult.unchanged(String text) {
    final normalized = VoiceTextCleanupService.normalizeBasic(text);
    return VoiceTextCleanupResult(
      originalText: text,
      cleanedText: normalized,
      changed: normalized != text.trim(),
      method: normalized == text.trim()
          ? VoiceTextCleanupMethod.none
          : VoiceTextCleanupMethod.local,
      reason: normalized == text.trim() ? 'no_cleanup_needed' : 'basic_cleanup',
      confidence: 1,
    );
  }

  final String originalText;
  final String cleanedText;
  final bool changed;
  final VoiceTextCleanupMethod method;
  final String reason;
  final double confidence;
}

class VoiceTextCleanupService {
  const VoiceTextCleanupService._();

  static VoiceTextCleanupResult cleanLocally(
    String rawText, {
    VoiceTextCleanupContext context = VoiceTextCleanupContext.add,
    Iterable<VoiceTextCleanupCandidate> candidates = const [],
  }) {
    final original = rawText.trim();
    var cleaned = normalizeBasic(original);
    var reason = cleaned == original ? 'no_cleanup_needed' : 'basic_cleanup';

    final candidateCleaned = _mergeCandidateSplitParticles(
      cleaned,
      candidates,
    );
    if (candidateCleaned != cleaned) {
      cleaned = candidateCleaned;
      reason = 'candidate_particle_repair';
    }

    return VoiceTextCleanupResult(
      originalText: original,
      cleanedText: cleaned,
      changed: cleaned != original,
      method: cleaned == original
          ? VoiceTextCleanupMethod.none
          : VoiceTextCleanupMethod.local,
      reason: reason,
      confidence: 1,
    );
  }

  static bool shouldAskAi(String text) {
    final normalized = normalizeBasic(text);
    if (normalized.isEmpty) {
      return false;
    }
    if (RegExp(r'([가-힣0-9a-zA-Z]{2,})\s*(에서|에)\s+([가-힣0-9a-zA-Z]{2,})\s*(에서|에)')
        .hasMatch(normalized)) {
      return true;
    }
    if (RegExp(r'([가-힣]{2,})\s+\1').hasMatch(normalized)) {
      return true;
    }
    return false;
  }

  static String normalizeBasic(String text) {
    final normalized = text
        .replaceAll(RegExp(r'[,\.\!\?\(\)\[\]\{\}]+'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return normalizeKoreanSttRepetitions(normalized);
  }

  static String normalizeKoreanSttRepetitions(String text) {
    final words = text
        .trim()
        .split(RegExp(r'\s+'))
        .where((word) => word.isNotEmpty)
        .toList(growable: false);
    if (words.length < 2) {
      return text.trim();
    }

    final output = <String>[];
    var index = 0;
    while (index < words.length) {
      if (index < words.length - 1) {
        final merged = _mergeKoreanSttPair(words[index], words[index + 1]);
        if (merged != null) {
          output.add(merged);
          index += 2;
          continue;
        }
      }
      output.add(words[index]);
      index += 1;
    }

    var changed = output.join(' ');
    // A single pass fixes adjacent pairs; a second pass catches chained cases
    // such as "경탁이 탁이한테 전화 전화해서".
    if (changed != text.trim()) {
      final secondPass = normalizeKoreanSttRepetitions(changed);
      changed = secondPass;
    }
    return changed.trim();
  }

  static String normalizeForSearch(String text) {
    return normalizeBasic(text)
        .toLowerCase()
        .replaceAll(RegExp(r'[^0-9a-z가-힣\s]'), ' ')
        .split(RegExp(r'\s+'))
        .map(_stripKoreanParticles)
        .where((token) => token.isNotEmpty)
        .join('');
  }

  static String _mergeCandidateSplitParticles(
    String text,
    Iterable<VoiceTextCleanupCandidate> candidates,
  ) {
    if (candidates.isEmpty) {
      return text;
    }
    final candidateSearch = candidates
        .map((candidate) => normalizeForSearch(candidate.searchableText))
        .where((value) => value.isNotEmpty)
        .join(' ');
    if (candidateSearch.isEmpty) {
      return text;
    }

    return text.replaceAllMapped(
      RegExp(
        r'([가-힣0-9a-zA-Z]{2,})\s*(에서|에)\s+([가-힣0-9a-zA-Z]{2,})\s*(에서|에)',
      ),
      (match) {
        final first = match.group(1) ?? '';
        final lastParticle = match.group(4) ?? '';
        final second = match.group(3) ?? '';
        final joined = '$first$second';
        if (candidateSearch.contains(normalizeForSearch(joined))) {
          return '$joined$lastParticle';
        }
        return match.group(0) ?? '';
      },
    );
  }

  static String _stripKoreanParticles(String token) {
    var value = token.toLowerCase().trim();
    for (final suffix in const <String>[
      '에서',
      '으로',
      '부터',
      '까지',
      '에게',
      '한테',
      '로',
      '에',
      '을',
      '를',
      '은',
      '는',
      '이',
      '가',
      '와',
      '과',
      '도',
    ]) {
      if (value.length > suffix.length + 1 && value.endsWith(suffix)) {
        value = value.substring(0, value.length - suffix.length);
        break;
      }
    }
    return value;
  }

  static String? _mergeKoreanSttPair(String left, String right) {
    final normalizedLeft = _normalizeKoreanSttToken(left);
    final normalizedRight = _normalizeKoreanSttToken(right);
    if (normalizedLeft.isEmpty || normalizedRight.isEmpty) {
      return null;
    }
    if (!_containsHangul(normalizedLeft) || !_containsHangul(normalizedRight)) {
      return null;
    }

    if (normalizedLeft == normalizedRight) {
      return left;
    }

    if (normalizedRight.startsWith(normalizedLeft) &&
        normalizedRight.length > normalizedLeft.length &&
        _hasKoreanSttJoinSuffix(normalizedRight)) {
      return right;
    }

    final overlap = _koreanSuffixPrefixOverlap(normalizedLeft, normalizedRight);
    if (overlap <= 0) {
      return null;
    }
    final shouldMerge = overlap >= 2 ||
        (overlap == 1 &&
            normalizedLeft.length <= 4 &&
            _hasKoreanSttJoinSuffix(normalizedRight));
    if (!shouldMerge) {
      return null;
    }
    return '$left${right.substring(overlap)}';
  }

  static String _normalizeKoreanSttToken(String token) {
    return token
        .trim()
        .replaceAll(RegExp(r'[\s\p{P}\p{S}]', unicode: true), '')
        .toLowerCase();
  }

  static int _koreanSuffixPrefixOverlap(String left, String right) {
    final max = left.length < right.length ? left.length : right.length;
    for (var size = max; size >= 1; size -= 1) {
      if (left.substring(left.length - size) == right.substring(0, size)) {
        return size;
      }
    }
    return 0;
  }

  static bool _hasKoreanSttJoinSuffix(String token) {
    const suffixes = <String>[
      '한테',
      '에게',
      '께',
      '랑',
      '와',
      '과',
      '하고',
      '이',
      '가',
      '은',
      '는',
      '을',
      '를',
      '로',
      '으로',
      '에서',
      '해서',
      '하기',
      '해줘',
      '해주기',
      '하는지',
      '할지',
      '했는지',
      '물어보기',
      '확인하기',
      '전화하기',
    ];
    return suffixes.any(token.endsWith);
  }

  static bool _containsHangul(String text) {
    return RegExp(r'[가-힣]').hasMatch(text);
  }
}
