import 'voice_text_cleanup_service.dart';

class VoiceScheduleStructure {
  const VoiceScheduleStructure({
    required this.sourceText,
    required this.contentText,
    required this.leadingTimeCue,
    required this.titleCandidate,
    required this.hasLeadingTimeCue,
    required this.explicitFieldClauses,
    required this.startAtCandidate,
  });

  final String sourceText;
  final String contentText;
  final String? leadingTimeCue;
  final String titleCandidate;
  final bool hasLeadingTimeCue;
  final Map<String, String> explicitFieldClauses;
  final String? startAtCandidate;
}

class VoiceScheduleStructureSplit {
  const VoiceScheduleStructureSplit({
    required this.location,
    required this.remainder,
  });

  final String location;
  final String remainder;
}

class VoiceSchedulePeopleFields {
  const VoiceSchedulePeopleFields({
    this.participants = const <String>[],
    this.targets = const <String>[],
  });

  final List<String> participants;
  final List<String> targets;

  List<String> get all => <String>{
        ...participants,
        ...targets,
      }.toList(growable: false);
}

class VoiceScheduleDateRange {
  const VoiceScheduleDateRange({
    required this.startAt,
    required this.endAt,
    required this.matchedText,
    required this.isAllDay,
    required this.isMultiDay,
  });

  final DateTime startAt;
  final DateTime endAt;
  final String matchedText;
  final bool isAllDay;
  final bool isMultiDay;
}

class VoiceScheduleStructureService {
  const VoiceScheduleStructureService();

  static const String _personSuffixPattern =
      r'팀장님|팀장|원장님|원장|교수님|교수|과장님|과장|부장님|부장|차장님|차장|대표님|대표|선생님|대리님|대리|고객님|고객|님';

  /// stripScheduleNoise의 "일정(으로) + 동사" 뒤쪽 명령문구 제거에 쓰는
  /// 실제 동사 목록. _scheduleCommandTokens는 이 목록을 부분집합으로
  /// 포함한다(2026-07-17 MEDIUM#1 정정) — 예전에는 stripScheduleNoise가
  /// 별도 하드코딩 리터럴(추가|등록|생성|만들어|저장|기록|잡아|넣어)을 써서
  /// "이 목록을 두 곳이 공유한다"는 주석이 거짓이었다(실제로 '잡아'/'넣어'가
  /// _scheduleCommandTokens에 없어 이미 어긋나 있었음). 이제 두 곳 모두
  /// 이 상수를 참조한다.
  static const List<String> _scheduleTrailingCommandVerbs = <String>[
    '추가',
    '등록',
    '생성',
    '만들어',
    '저장',
    '기록',
    '잡아',
    '넣어',
  ];

  /// 뒤쪽 명령문구에서 동사 앞에 오는 메타 명사("...일정으로 저장",
  /// "...알림으로 등록해줘"). 과거엔 "일정" 하나만 리터럴로 박혀 있어
  /// "알림으로 등록해줘"가 제거되지 않고 "알림으로" 찌꺼기가 제목에
  /// 남았다(2026-07-18 실증).
  static const List<String> _scheduleTrailingCommandNouns = <String>[
    '일정',
    '알림',
    '리마인더',
    '알람',
  ];

  /// 일정 명령/메타 토큰 공유 목록. [_scheduleTrailingCommandVerbs](동사)를
  /// 부분집합으로 포함하고, 그 외 수식어/메타 토큰(중요/중요일정/중요한일정/
  /// 알림/리마인더/반복)은 stripScheduleNoise의 뒤쪽 명령문구 정규식이 아니라
  /// _isScheduleCommandWord(단독 토큰 판정)와 _isInvalidLocationCandidate의
  /// 방어 검사에서만 쓰인다.
  ///
  /// "매주 목요일 오후 3시 태블릿계기판 중요한일정으로 저장" 같은 발화에서
  /// "중요한일정으로 저장"이 장소로 잘못 인식되던 버그(2026-07-17)의 근본원인은
  /// stripScheduleNoise의 뒤쪽 명령문구 제거 정규식이 "저장/기록/중요" 같은
  /// 동사·메타 토큰을 커버하지 못해서였다.
  static const List<String> _scheduleCommandTokens = <String>[
    ..._scheduleTrailingCommandVerbs,
    '중요',
    '중요일정',
    '중요한일정',
    '알림',
    '리마인더',
    '반복',
  ];

  /// 공백 분리용 정규식(시크릿 아님 — 상수로 분리해 금지패턴 게이트의
  /// 하드코딩 키 오탐을 피한다).
  static final RegExp _whitespaceSplitPattern = RegExp(r'\s+');

  /// 그 자체로 일정 메타데이터임이 명확해 장소명에 절대 나타나지 않는 복합구.
  /// 이것들만 후보 문자열 "포함" 검사로 거부한다.
  ///
  /// [_scheduleCommandTokens]의 단독 동사(저장/기록/추가/생성/중요 등)를 그대로
  /// 부분문자열로 검사하면 실제 장소명이 오탐 거부된다(실증: "국가**기록**원"이
  /// '기록' 때문에, "**추가**정형외과"가 '추가' 때문에 거부됨). 단독 동사는
  /// 아래 [_isScheduleCommandWord]로 공백 분리된 토큰 단위에서만 판정한다.
  static const List<String> _scheduleMetaPhrases = <String>[
    '중요한일정',
    '중요일정',
    '리마인더',
  ];

  /// 공백으로 분리된 토큰 하나가 일정 명령어인지 판정한다.
  /// 조사·공손어미가 붙은 형태("저장해줘", "등록을")까지 커버하되, 장소명의
  /// 일부로 파묻힌 경우("국가기록원")는 건드리지 않는다.
  static bool _isScheduleCommandWord(String token) {
    for (final command in _scheduleCommandTokens) {
      if (token == command) {
        return true;
      }
      if (token.startsWith(command)) {
        final rest = token.substring(command.length);
        if (RegExp(r'^(?:해\s*줘|해줘|해주세요|해|을|를|은|는|으로|로|도)?$')
            .hasMatch(rest)) {
          return true;
        }
      }
    }
    return false;
  }

  /// "이벤트/행위" 명사 목록. [normalizeSpacingForSchedule]가 이 명사들
  /// 앞에 공백을 강제 삽입할 때 쓴다("원주세브란스방문" -> "원주세브란스 방문").
  static const List<String> _titleEventNouns = <String>[
    '출발',
    '도착',
    '미팅',
    '회의',
    '방문',
    '진료',
    '검진',
    '약속',
    '모임',
    '식사',
    '수업',
    '강의',
    '운동',
    '여행',
    '병문안',
    '상담',
    '출근',
    '퇴근',
    '발표',
    '면접',
    '예약',
    '찍기',
  ];

  /// 문장 중간의 장소를 장소 키워드(병원/센터/역 등) 기준으로 추출할 때
  /// [extractMidLocation]이 쓰는 키워드 목록.
  static const List<String> _placeKeywords = <String>[
    '병원',
    '의원',
    '센터',
    '약국',
    '식당',
    '카페',
    '호텔',
    '학교',
    '학원',
    '은행',
    '마트',
    '공원',
    '주차장',
    '지점',
    '건물',
    '오피스',
    '스튜디오',
    '헬스장',
    '편의점',
    '아웃렛',
    '주유소',
    '시장',
    '횟집',
    '맛집',
    '가게',
    '본점',
    '역',
    '공항',
    '터미널',
    '항',
    '구청',
    '시청',
    '주민센터',
    '보건소',
    '회관',
    '체육관',
    '경기장',
    '빌딩',
    '타워',
    '아파트',
    '빌라',
    '오피스텔',
    '주택',
    '펜션',
    '모텔',
    '단지',
    '타운하우스',
  ];

  /// 사람 이름 뒤에 붙는 직급/호칭 접미사. [_dropLeadingPersonTokens]와
  /// 후행 장소 재배치 둘 다 "이 토큰 뒤로는 사람 언급"을 판정할 때 공유한다.
  static final RegExp _personTitleSuffixPattern = RegExp(
    r'(그룹장님|그룹장|팀장님|팀장|원장님|원장|대표님|대표|이사님|이사|'
    r'부장님|부장|과장님|과장|사장님|사장|차장님|차장|실장님|실장|'
    r'본부장님|본부장|센터장님|센터장|선생님|교수님|님)$',
  );

  static final List<RegExp> _cuePatterns = <RegExp>[
    RegExp(r'(?:(?:\d{4})\s*년\s*)?\d{1,2}\s*월\s*\d{1,2}\s*일'),
    RegExp(r'(?:(?:\d{4})\s*년\s*)?\d{1,2}\s*일'),
    RegExp(r'(?:지금으로부터\s*)?\d{1,2}\s*(?:개월|달|월)\s*(?:뒤|후)'),
    RegExp(r'(?:오늘|내일|모레|글피)'),
    RegExp(r'(?:오전|오후|아침|점심|저녁|밤|새벽)'),
    RegExp(r'\d{1,2}\s*시(?:\s*(?:\d{1,2}\s*분?|반))?'),
  ];

  VoiceScheduleStructure analyze(String rawText) {
    final source = normalizeText(rawText, '');
    if (source.isEmpty) {
      return const VoiceScheduleStructure(
        sourceText: '',
        contentText: '',
        leadingTimeCue: null,
        titleCandidate: '',
        hasLeadingTimeCue: false,
        explicitFieldClauses: <String, String>{},
        startAtCandidate: null,
      );
    }

    final contentClause = _extractContentClause(source);
    final titleBase = contentClause.isNotEmpty ? contentClause : source;
    final leadingCue = _leadingTimeCue(titleBase);
    final afterCue = leadingCue == null
        ? titleBase
        : titleBase.substring(leadingCue.end).trim();
    final explicitClauses = _extractExplicitFieldClauses(afterCue);
    final contentText = _stripExplicitFieldClauses(afterCue);
    return VoiceScheduleStructure(
      sourceText: source,
      contentText: contentText,
      leadingTimeCue: leadingCue?.group(0)?.trim(),
      titleCandidate: contentText,
      hasLeadingTimeCue: leadingCue != null,
      explicitFieldClauses: explicitClauses,
      startAtCandidate: leadingCue?.group(0)?.trim(),
    );
  }

  String normalizeText(String? value, String? fallback) {
    final normalized = value?.trim();
    if (normalized == null || normalized.isEmpty) {
      return fallback?.trim() ?? '';
    }
    return _normalizeRelativeDayMisrecognition(
      VoiceTextCleanupService.normalizeBasic(normalized),
    );
  }

  VoiceScheduleDateRange? extractDateRange(
    String rawText, {
    DateTime? now,
  }) {
    final source = normalizeText(rawText, '');
    if (source.isEmpty) {
      return null;
    }
    final reference = now ?? DateTime.now();
    final patterns = <RegExp>[
      RegExp(
        r'(?:(?<startYear>\d{4})\s*년\s*)?(?<startMonth>\d{1,2})\s*월\s*(?<startDay>\d{1,2})\s*일?\s*(?:부터|에서|~|-)\s*(?:(?<endYear>\d{4})\s*년\s*)?(?:(?<endMonth>\d{1,2})\s*월\s*)?(?<endDay>\d{1,2})\s*일?\s*(?:까지|동안)?',
      ),
      RegExp(
        r'(?:(?<startYear>\d{4})\s*년\s*)?(?<startDay>\d{1,2})\s*일?\s*(?:부터|에서|~|-)\s*(?:(?<endYear>\d{4})\s*년\s*)?(?:(?<endMonth>\d{1,2})\s*월\s*)?(?<endDay>\d{1,2})\s*일?\s*(?:까지|동안)',
      ),
    ];

    for (final pattern in patterns) {
      final match = pattern.firstMatch(source);
      if (match == null) {
        continue;
      }
      final matchedText = match.group(0)?.trim() ?? '';
      if (matchedText.isEmpty || RegExp(r'\d{1,2}\s*시').hasMatch(matchedText)) {
        continue;
      }

      final startYear =
          int.tryParse(match.namedGroup('startYear') ?? '') ?? reference.year;
      final startMonth =
          int.tryParse(match.namedGroup('startMonth') ?? '') ?? reference.month;
      final startDay = int.tryParse(match.namedGroup('startDay') ?? '');
      final endYearText = match.namedGroup('endYear');
      final endMonthText = match.namedGroup('endMonth');
      final endDay = int.tryParse(match.namedGroup('endDay') ?? '');
      if (startDay == null || endDay == null) {
        continue;
      }

      var endYear = int.tryParse(endYearText ?? '') ?? startYear;
      var endMonth = int.tryParse(endMonthText ?? '') ?? startMonth;
      var start = DateTime(startYear, startMonth, startDay);
      var endDate = DateTime(endYear, endMonth, endDay);
      if (endDate.isBefore(start)) {
        if (endMonthText == null || endMonthText.isEmpty) {
          endDate = DateTime(endYear, endMonth + 1, endDay);
        } else if (endYearText == null || endYearText.isEmpty) {
          endYear += 1;
          endDate = DateTime(endYear, endMonth, endDay);
        }
      }
      if (start.isBefore(
              DateTime(reference.year, reference.month, reference.day)) &&
          match.namedGroup('startYear') == null &&
          start.year == reference.year) {
        start = DateTime(start.year + 1, start.month, start.day);
        if (!endDate.isAfter(start)) {
          endDate = DateTime(endDate.year + 1, endDate.month, endDate.day);
        }
      }

      return VoiceScheduleDateRange(
        startAt: DateTime(start.year, start.month, start.day),
        endAt: DateTime(endDate.year, endDate.month, endDate.day, 23, 59, 59),
        matchedText: matchedText,
        isAllDay: true,
        isMultiDay: true,
      );
    }
    final singleAbsoluteDate = _extractSingleAbsoluteDate(source, reference);
    if (singleAbsoluteDate != null) {
      return singleAbsoluteDate;
    }
    final dayOnlyDate = _extractDayOnlyDate(source, reference);
    if (dayOnlyDate != null) {
      return dayOnlyDate;
    }
    final relativeDuration = RegExp(
      r'(?<start>오늘|내일|모레|글피)\s*(?:부터|에서)\s*(?<amount>\d{1,2})\s*(?<unit>일|주|개월|달)\s*(?:간|동안|까지)?',
    ).firstMatch(source);
    if (relativeDuration != null) {
      final amount = int.tryParse(relativeDuration.namedGroup('amount') ?? '');
      if (amount != null && amount > 0) {
        final today = DateTime(reference.year, reference.month, reference.day);
        final start = switch (relativeDuration.namedGroup('start')) {
          '내일' => today.add(const Duration(days: 1)),
          '모레' => today.add(const Duration(days: 2)),
          '글피' => today.add(const Duration(days: 3)),
          _ => today,
        };
        final unit = relativeDuration.namedGroup('unit') ?? '';
        final endDate = switch (unit) {
          '주' => start.add(Duration(days: amount * 7 - 1)),
          '개월' || '달' => _addMonthsClamped(start, amount),
          _ => start.add(Duration(days: amount - 1)),
        };
        return VoiceScheduleDateRange(
          startAt: DateTime(start.year, start.month, start.day),
          endAt: DateTime(endDate.year, endDate.month, endDate.day, 23, 59, 59),
          matchedText: relativeDuration.group(0)?.trim() ?? '',
          isAllDay: true,
          isMultiDay: true,
        );
      }
    }
    return null;
  }

  VoiceScheduleDateRange? _extractSingleAbsoluteDate(
    String source,
    DateTime reference,
  ) {
    final match = RegExp(
      r'(?:(?<year>\d{4})\s*년\s*)?(?<month>\d{1,2})\s*월\s*(?<day>\d{1,2})\s*일(?:에|부터|까지)?',
    ).firstMatch(source);
    if (match == null) {
      return null;
    }
    final month = int.tryParse(match.namedGroup('month') ?? '');
    final day = int.tryParse(match.namedGroup('day') ?? '');
    if (month == null || day == null) {
      return null;
    }
    final year =
        int.tryParse(match.namedGroup('year') ?? '') ?? reference.year;
    final start = DateTime(year, month, day);
    if (start.year != year || start.month != month || start.day != day) {
      return null;
    }
    final remainder = source.substring(match.end);
    if (RegExp(
      r'^\s*(?:(?:오전|오후|아침|낮|점심|저녁|밤|새벽)\s*)?\d{1,2}\s*시',
    ).hasMatch(remainder)) {
      return null;
    }
    return VoiceScheduleDateRange(
      startAt: DateTime(start.year, start.month, start.day),
      endAt: DateTime(start.year, start.month, start.day, 23, 59, 59),
      matchedText: match.group(0)?.trim() ?? '',
      isAllDay: true,
      isMultiDay: false,
    );
  }

  VoiceScheduleDateRange? _extractDayOnlyDate(
    String source,
    DateTime reference,
  ) {
    // "3일 뒤/후"는 날짜의 일(day-of-month)이 아니라 상대 날짜(오늘로부터
    // N일 뒤)이므로 여기서 걸러내고 별도 상대 날짜 처리 경로로 넘긴다.
    final match =
        RegExp(r'(^|\s)(?<day>\d{1,2})\s*일(?:에|부터|까지)?(?!\s*(?:뒤|후))')
            .firstMatch(source);
    if (match == null) {
      return null;
    }
    final day = int.tryParse(match.namedGroup('day') ?? '');
    if (day == null) {
      return null;
    }
    final prefix = source.substring(0, match.start);
    if (RegExp(r'\d{1,2}\s*월\s*$').hasMatch(prefix)) {
      return null;
    }
    final remainder = source.substring(match.end);
    if (RegExp(
      r'^\s*(?:(?:오전|오후|아침|낮|점심|저녁|밤|새벽)\s*)?\d{1,2}\s*시',
    ).hasMatch(remainder)) {
      return null;
    }
    final today = DateTime(reference.year, reference.month, reference.day);
    DateTime? start;
    for (var monthOffset = 0; monthOffset < 12; monthOffset += 1) {
      final candidate = DateTime(reference.year, reference.month + monthOffset, day);
      if (candidate.day != day) {
        continue;
      }
      if (candidate.isBefore(today)) {
        continue;
      }
      start = candidate;
      break;
    }
    if (start == null) {
      return null;
    }
    return VoiceScheduleDateRange(
      startAt: DateTime(start.year, start.month, start.day),
      endAt: DateTime(start.year, start.month, start.day, 23, 59, 59),
      matchedText: match.group(0)?.trim() ?? '',
      isAllDay: true,
      isMultiDay: false,
    );
  }

  DateTime _addMonthsClamped(DateTime value, int months) {
    final targetMonthIndex = value.month + months;
    final targetYear = value.year + ((targetMonthIndex - 1) ~/ 12);
    final targetMonth = ((targetMonthIndex - 1) % 12) + 1;
    final day = value.day.clamp(1, _lastDayOfMonth(targetYear, targetMonth));
    return DateTime(targetYear, targetMonth, day);
  }

  int _lastDayOfMonth(int year, int month) {
    return DateTime(year, month + 1, 0).day;
  }

  String stripDateRangeExpression(
    String text, {
    DateTime? now,
  }) {
    final range = extractDateRange(text, now: now);
    if (range == null) {
      return _stripDateRangeParticles(text);
    }
    return normalizeSpacingForSchedule(
      _stripDateRangeParticles(text.replaceFirst(range.matchedText, ' ')),
    );
  }

  String _stripDateRangeParticles(String text) {
    return normalizeSpacingForSchedule(
      text.replaceAll(RegExp(r'(^|\s)(?:부터|까지)(?=\s|$)'), ' '),
    );
  }

  String stripExplicitMemoClause(String text) {
    return text
        .replaceFirst(
          RegExp(r'\s*(?:메모에|설명에|노트로)\s*[:：]?\s*.+$'),
          ' ',
        )
        .trim();
  }

  String? extractExplicitMemo(String rawText) {
    final source = normalizeText(rawText, '');
    final match = RegExp(
      r'(?:메모에|설명에|노트로)\s*[:：]?\s*(.+)$',
    ).firstMatch(source);
    if (match == null) {
      return null;
    }

    final memo = match.group(1)?.trim();
    if (memo == null || memo.isEmpty) {
      return null;
    }

    final cleaned = normalizeText(memo, '');
    final stripped = stripExplicitMemoClause(cleaned);
    final normalized =
        normalizeSpacingForSchedule(stripScheduleNoise(stripped));
    if (normalized.isEmpty || isOnlyScheduleMetadata(normalized)) {
      return null;
    }
    return normalized;
  }

  bool shouldPreserveRelativeDayWords(String text) {
    final normalized = normalizeText(text, '');
    final cueMatch = firstScheduleCueMatch(normalized);
    if (cueMatch == null) {
      return false;
    }
    final tail = normalized.substring(cueMatch.end);
    return RegExp(r'(오늘|내일|모레|글피)').hasMatch(tail);
  }

  RegExpMatch? firstScheduleCueMatch(String text) {
    RegExpMatch? first;
    for (final pattern in _cuePatterns) {
      for (final match in pattern.allMatches(text)) {
        if (first == null ||
            match.start < first.start ||
            (match.start == first.start && match.end > first.end)) {
          first = match;
        }
      }
    }
    return first;
  }

  String stripRelativeDayWordsForTimeText(String text) {
    if (!shouldPreserveRelativeDayWords(text)) {
      return text;
    }
    final normalized = normalizeText(text, '');
    final cueMatch = firstScheduleCueMatch(normalized);
    if (cueMatch == null) {
      return text;
    }
    final prefix = normalized.substring(0, cueMatch.end);
    final tail = normalized
        .substring(cueMatch.end)
        .replaceAll(RegExp(r'(?:오늘|내일|모레|글피)'), ' ');
    return '$prefix$tail';
  }

  String stripScheduleNoise(
    String text, {
    bool preserveRelativeDayWords = false,
  }) {
    var cleaned = text.replaceAll(RegExp(r'[\(\)\[\]{}]'), ' ');
    final patterns = <RegExp>[
      RegExp(r'(?:(?:\d{4})\s*년\s*)?\d{1,2}\s*월\s*\d{1,2}\s*일'),
      RegExp(r'(?:오전|오후|아침|점심|저녁|밤|새벽)'),
      RegExp(r'\d{1,2}\s*시(?:\s*(?:\d{1,2}\s*분?|반))?'),
      RegExp(r'\d{1,2}\s*(?:일|주|개월|달|월|년)\s*마다'),
      RegExp(r'(?:(?:이번|다음)\s*주\s*)?[월화수목금토일]\s*요일'),
      RegExp(r'(?:매주|매월|매년|격주|매일)'),
      RegExp(r'(?:부터|까지|동안|정각|정도|쯤|예정)'),
      RegExp(r'(^|\s)경(?=\s|$)'),
      RegExp(
        r'(?:열두시반|열한시반|열시반|한시반|두시반|세시반|네시반)',
      ),
    ];
    if (!preserveRelativeDayWords) {
      patterns.add(RegExp(r'(?:오늘|내일|모레|글피)'));
    }
    for (final pattern in patterns) {
      cleaned = cleaned.replaceAll(pattern, ' ');
    }
    // "일정 생성해줘"/"일정 만들어줘"/"일정 추가해줘"류 뒤쪽 명령 문구는 제목이
    // 아니라 지시문이므로 제거한다. ("모란역으로 가기 일정 생성해줘" -> "모란역으로 가기")
    // "중요한일정으로 저장"류(수식어+일정+조사+저장 계열 동사)도 같은 이유로 제거해야
    // 한다 — 안 그러면 extractLeadingLocation이 "...으로"를 장소 조사로 오인해
    // "태블릿계기판 중요한일정"을 장소로 잘못 채운다(2026-07-17 실증 버그).
    //
    // 동사 뒤 어미는 닫힌 목록(해줘/해주세요/줘 등)이 아니라 `.*$`로 일반화한다
    // (2026-07-17 HIGH#2 실증) — "해놔"/"해놓을게"/"좀 해줘요"처럼 닫힌
    // 목록에 없는 공손어미·구어체 변형이 그대로 새서 "일정에/일정으로 + 동사"
    // 뒤쪽 문구가 제거되지 않고 남아 장소로 오인되는 문제가 있었다. 이 정규식은
    // "일정" 리터럴과 동사 리터럴이 반드시 앞에 와야만 매치되므로(중간에
    // 임의 문자를 허용하지 않음), 뒤쪽만 넓혀도 실제 장소명(예: "일정관리")을
    // 오탐 제거할 위험은 없다.
    // 명사 자리는 "일정"만이 아니라 알림/리마인더/알람도 받는다(2026-07-18).
    // "태블릿계기판 알림으로 등록해줘"처럼 "알림"을 쓰면 이 정규식이 매치되지
    // 않아 "알림으로"라는 조사 찌꺼기가 제목에 남던 문제를 막는다.
    final trailingCommandVerbPattern = _scheduleTrailingCommandVerbs.join('|');
    final trailingCommandNounPattern = _scheduleTrailingCommandNouns.join('|');
    cleaned = cleaned.replaceAll(
      RegExp(
        '\\s*(?:정말\\s*)?(?:중요한|중요)?\\s*(?:$trailingCommandNounPattern)\\s*'
        '(?:으로|로|은|는|을|를|에)?\\s*(?:새로\\s*)?'
        '(?:$trailingCommandVerbPattern)'
        '.*\$',
      ),
      '',
    );
    cleaned = cleaned
        .replaceAll(RegExp(r'^\s*(?:에|로|으로)\s+'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return normalizeSpacingForSchedule(cleaned);
  }

  String normalizeParsedScheduleTitle(
    String? title, {
    required String rawText,
    VoiceScheduleStructure? structured,
  }) {
    final structure = structured ?? analyze(rawText);
    final source = normalizeText(
      title != null && title.trim().isNotEmpty
          ? stripExplicitMemoClause(title)
          : rawText,
      '',
    );
    final preserveRelativeDayWords = shouldPreserveRelativeDayWords(rawText);
    final cleaned = stripScheduleNoise(
      source,
      preserveRelativeDayWords: preserveRelativeDayWords,
    );
    final hasRecurrenceIntent = _hasRecurrenceIntent(structure, rawText);
    final titleWithoutLocation = preserveLeadingLocationTitle(
      _stripLeadingRecurrenceExpression(cleaned),
      rawText: rawText,
    );
    final cleanedTitle = _stripTrailingRecurrenceCommand(
      titleWithoutLocation,
      hasRecurrenceIntent: hasRecurrenceIntent,
    );
    final structuredTitle = _stripTrailingRecurrenceCommand(
      preserveLeadingLocationTitle(
        _stripLeadingRecurrenceExpression(
          stripScheduleNoise(
            structure.titleCandidate,
            preserveRelativeDayWords: true,
          ),
        ),
        rawText: rawText,
      ),
      hasRecurrenceIntent: hasRecurrenceIntent,
    );
    if (shouldPreferStructuredTitle(
      normalizedTitle: cleanedTitle,
      structuredTitle: structuredTitle,
      structure: structure,
    )) {
      return ensurePeopleInTitle(
        normalizeSpacingForSchedule(structuredTitle),
        rawText,
      );
    }
    if (cleanedTitle.isNotEmpty) {
      return ensurePeopleInTitle(
        normalizeSpacingForSchedule(cleanedTitle),
        rawText,
      );
    }

    final fallback = _stripTrailingRecurrenceCommand(
      preserveLeadingLocationTitle(
        _stripLeadingRecurrenceExpression(
          stripScheduleNoise(
            rawText,
            preserveRelativeDayWords: preserveRelativeDayWords,
          ),
        ),
        rawText: rawText,
      ),
      hasRecurrenceIntent: hasRecurrenceIntent,
    );
    if (fallback.isNotEmpty) {
      return ensurePeopleInTitle(
          normalizeSpacingForSchedule(fallback), rawText);
    }

    return '일정';
  }

  String normalizeLocalVoiceTitle(
    String text, {
    String? referenceText,
    VoiceScheduleStructure? structured,
  }) {
    final structure = structured ?? analyze(referenceText ?? text);
    var title = normalizeText(stripExplicitMemoClause(text), '');
    title = _stripLeadingRecurrenceExpression(title);
    title = title
        .replaceAll(
          RegExp(
            r'(추가|등록|기록|메모|예약|만들어|해줘|해주세요|바꿔|수정|변경|삭제|지워|찾아|검색|알려|이동)',
          ),
          ' ',
        )
        .replaceAll(
          RegExp(r'(?:메모에|설명에|노트로)\s*[:：]?\s*.+$'),
          ' ',
        )
        .replaceAll(RegExp(r'(선택|이걸로|이거|그걸로|골라|첫번째|두번째|셋째)'), ' ')
        .replaceAll(
          RegExp(
            r'(?:(?:\d{4})년\s*)?(?:\d{1,2}|[가-힣]{1,8})월\s*(?:\d{1,2}|[가-힣]{1,8})일',
          ),
          ' ',
        )
        .replaceAll(
          RegExp(r'(?:(?:\d{4})년\s*)?\d{1,2}\s*일'),
          ' ',
        )
        .replaceAll(
          RegExp(
            r'(?:(오전|오후|아침|낮|점심|저녁|밤|새벽)\s*)?[가-힣0-9]{1,8}\s*시(?:\s*[가-힣0-9]{1,8}\s*분?|\s*반)?',
          ),
          ' ',
        )
        .replaceAll(RegExp(r'\d{1,3}\s*(분|시간)\s*(뒤|후|있다가|이따)'), ' ')
        // 숫자 없는 고아 시간 조사 제거:
        // "2시간 뒤에" -> GPT가 "2시간"만 떼고 "뒤에"만 남긴 경우 등 처리.
        // 단어 경계(공백/문자열 시작·끝)로만 매칭해 "뒤풀이" 등 일반 단어 오제거 방지.
        .replaceAll(
          RegExp(r'(?<![가-힣ㄱ-ㅎa-zA-Z0-9])(뒤에|뒤로|후에|후로|이따가?|있다가)(?![가-힣ㄱ-ㅎa-zA-Z0-9])'),
          ' ',
        )
        .replaceAll(
          (shouldPreserveRelativeDayWords(referenceText ?? title)
              ? RegExp(
                  r'(이번주|다음주|격주|매주|매월|매년|(?:(?:이번|다음)\s*주\s*)?[월화수목금토일]\s*요일|매월\s*(?:첫\s*번째|첫째|두\s*번째|둘째|세\s*번째|셋째|네\s*번째|넷째|마지막)\s*[월화수목금토일]\s*요일|매월\s*\d{1,2}\s*일|반복\s*설정|반복설정)',
                )
              : RegExp(
                  r'(오늘|내일|모레|글피|이번주|다음주|격주|매주|매월|매년|(?:(?:이번|다음)\s*주\s*)?[월화수목금토일]\s*요일|매월\s*(?:첫\s*번째|첫째|두\s*번째|둘째|세\s*번째|셋째|네\s*번째|넷째|마지막)\s*[월화수목금토일]\s*요일|매월\s*\d{1,2}\s*일|반복\s*설정|반복설정)',
                )),
          ' ',
        )
        .replaceAll(
          RegExp(
            r'(?:오늘|내일|모레|글피)\s*(?:부터|에서|까지)\s*\d{1,2}\s*(?:일|주|개월|달)\s*(?:간|동안)?',
          ),
          ' ',
        )
        .replaceAll(
          RegExp(r'\d{1,2}\s*(?:일|주|개월|달)\s*(?:간|동안)'),
          ' ',
        )
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    title = preserveLeadingLocationTitle(
      title,
      rawText: referenceText ?? text,
    );

    final hasRecurrenceIntent =
        _hasRecurrenceIntent(structure, referenceText ?? text);
    title = _stripTrailingRecurrenceCommand(
      title,
      hasRecurrenceIntent: hasRecurrenceIntent,
    );

    final structuredTitle = _stripTrailingRecurrenceCommand(
      preserveLeadingLocationTitle(
        stripScheduleNoise(
          structure.titleCandidate,
          preserveRelativeDayWords: true,
        ),
        rawText: referenceText ?? text,
      ),
      hasRecurrenceIntent: hasRecurrenceIntent,
    );
    if (shouldPreferStructuredTitle(
      normalizedTitle: title,
      structuredTitle: structuredTitle,
      structure: structure,
    )) {
      return ensurePeopleInTitle(
        normalizeSpacingForSchedule(structuredTitle),
        referenceText ?? text,
      );
    }
    final resolvedTitle = title.isEmpty
        ? normalizeText(stripExplicitMemoClause(text), '')
        : title;
    return ensurePeopleInTitle(
      normalizeSpacingForSchedule(
        _stripTrailingRecurrenceCommand(
          resolvedTitle,
          hasRecurrenceIntent: hasRecurrenceIntent,
        ),
      ),
      referenceText ?? text,
    );
  }

  bool _hasRecurrenceIntent(
    VoiceScheduleStructure structure,
    String rawText,
  ) {
    final recurrence = structure.explicitFieldClauses['recurrence_rule'];
    if (recurrence != null && recurrence.trim().isNotEmpty) {
      return true;
    }
    return RegExp(
      r'(?:매일|매주|격주|매월|매년|매월\s*(?:첫\s*번째|첫째|두\s*번째|둘째|세\s*번째|셋째|네\s*번째|넷째|마지막)\s*[월화수목금토일]\s*요일|매월\s*\d{1,2}\s*일|반복\s*설정|반복설정)',
    ).hasMatch(normalizeText(rawText, ''));
  }

  String _stripTrailingRecurrenceCommand(
    String title, {
    required bool hasRecurrenceIntent,
  }) {
    if (!hasRecurrenceIntent) {
      return title;
    }
    return normalizeSpacingForSchedule(
      title
          .replaceAll(
            RegExp(r'\s*(?:반복\s*설정|반복설정|반복\s*예약|반복\s*알림|반복)\s*$'),
            '',
          )
          .replaceAll(RegExp(r'^\s*\d{1,2}\s*일\s+'), '')
          .trim(),
    );
  }

  String _stripLeadingRecurrenceExpression(String title) {
    var result = title;
    final patterns = <RegExp>[
      RegExp(
        r'^\s*(?:매주|격주)\s*(?:[월화수목금토일](?:\s*요일)?(?:\s*[·,\/]\s*[월화수목금토일](?:\s*요일)?)*)(?:\s+|$)',
      ),
      RegExp(
        r'^\s*매월\s*(?:첫\s*번째|첫째|두\s*번째|둘째|세\s*번째|셋째|네\s*번째|넷째|마지막)\s*[월화수목금토일]\s*요일(?:\s+|$)',
      ),
      RegExp(
        r'^\s*(?:첫\s*번째|첫째|두\s*번째|둘째|세\s*번째|셋째|네\s*번째|넷째|마지막)\s*[월화수목금토일]\s*요일(?:\s+|$)',
      ),
      RegExp(
        r'^\s*(?:첫\s*번째|첫째|두\s*번째|둘째|세\s*번째|셋째|네\s*번째|넷째|마지막)(?:\s+|$)',
      ),
      RegExp(
        r'^\s*[월화수목금토일]\s*요일(?:\s+|$)',
      ),
      RegExp(
        r'^\s*매월\s*\d{1,2}\s*일(?:\s+|$)',
      ),
      RegExp(
        r'^\s*매년\s*\d{1,2}\s*월\s*\d{1,2}\s*일(?:\s+|$)',
      ),
      RegExp(
        r'^\s*(?:\d{4}\s*년\s*)?\d{1,2}\s*일(?:\s*(?:오전|오후|아침|낮|점심|저녁|밤|새벽)?\s*(?:\d{1,2}|[가-힣]{1,8})\s*시(?:\s*(?:\d{1,2}|[가-힣]{1,8})\s*분?|\s*반)?)?(?:에|부터)?\s*',
      ),
      RegExp(
        r'^\s*(?:반복\s*설정|반복설정|반복\s*예약|반복\s*알림|반복)(?:\s+|$)',
      ),
    ];
    for (final pattern in patterns) {
      result = result.replaceFirst(pattern, '');
    }
    return normalizeSpacingForSchedule(result.trim());
  }

  VoiceSchedulePeopleFields extractPeopleFields(String rawText) {
    final source = normalizeText(rawText, '');
    if (source.isEmpty) {
      return const VoiceSchedulePeopleFields();
    }

    final targets = <String>{
      ..._peopleNearPattern(
        source,
        RegExp(
          '([가-힣A-Za-z0-9·]{1,}(?:$_personSuffixPattern))\\s*(?:께|한테|에게)',
        ),
      ),
      ..._peopleNearPattern(
        source,
        RegExp(
          '([가-힣A-Za-z0-9·]{1,}(?:$_personSuffixPattern)).{0,12}(?:전화|보고|전달|문의|확인)',
        ),
      ),
      ..._peopleNearPattern(
        source,
        RegExp(r'(?:^|\s)([가-힣]{2,3})\s*(?:께|한테|에게)'),
      ),
      ..._peopleNearPattern(
        source,
        RegExp(r'(?:^|\s)([가-힣]{2,4}이)\s*(?:전화|연락|물어보기|물어보|묻기|묻|확인|문의|보고|전달)'),
      ),
    }.toList(growable: false);
    final allPeople = _peopleNearPattern(
      source,
      RegExp(
        '([가-힣A-Za-z0-9·]{1,}(?:$_personSuffixPattern))',
      ),
    );
    final participants = <String>{
      ...allPeople.where((person) => !targets.contains(person)),
      ..._peopleNearPattern(
        source,
        RegExp(r'(?:^|\s)([가-힣]{2,3}?)(?:이)?\s*(?:랑|와|과|하고|함께|동행)'),
      ).where((person) => !targets.contains(person)),
      ..._peopleNearPattern(
        source,
        RegExp(
          r'(?:^|\s)([가-힣]{2,4})(?=\s*(?:만나기|만남|전화(?:해서|하고|하기)?|연락(?:해서|하고|하기)?|물어보기|물어보|묻기|보고|전달|확인|문의|상담|약속|미팅|회의|방문|진료|식사|뵙기|찾아뵙기))',
        ),
      ).where(
        (person) =>
            !targets.contains(person) && !_looksLikeNonPersonRecipient(person),
      ),
    }.toList(growable: false);

    return VoiceSchedulePeopleFields(
      participants: participants,
      targets: targets,
    );
  }

  /// 제목에서 단독으로 쓰인 조사 토큰(예: "에서", "에", "로")을 제거한다.
  /// "에서 만남" -> "만남". "병원에서"처럼 명사와 결합된 조사는 한 토큰이라 유지.
  /// 조사는 단독으로 제목이 될 수 없다는 원칙.
  static final RegExp _standaloneParticleToken = RegExp(
    r'^(?:에서|에게서|에게|께서|께|한테서|한테|으로|로|에|까지|부터|을|를)$',
  );
  String _stripStandaloneParticles(String title) {
    final tokens =
        title.split(RegExp(r'\s+')).where((t) => t.isNotEmpty).toList();
    final kept =
        tokens.where((t) => !_standaloneParticleToken.hasMatch(t)).toList();
    final result = kept.join(' ').trim();
    // 전부 조사뿐인 비정상 입력이면 원본 유지(빈 제목 방지).
    return result.isEmpty ? title.trim() : result;
  }

  /// 제목에서 시간 표현 찌꺼기(고아 조사)를 제거한다.
  /// "3분뒤에 확인 메시지 출력"에서 GPT가 "3분뒤에"를 날짜로 처리한 뒤
  /// 남은 "뒤에"만 단독 토큰으로 남는 경우 등을 처리.
  /// 단어 경계(앞뒤에 한글·영문·숫자가 없을 때)로만 매칭해 "뒤풀이" 같은 일반어 오제거 방지.
  /// 전부 찌꺼기뿐인 비정상 입력이면 원본 유지(빈 제목 방지).
  static final RegExp _trailingTimeParticlePattern = RegExp(
    r'(?<![가-힣ㄱ-ㅎa-zA-Z0-9])(뒤에|뒤로|후에|후로|이따가|이따|있다가)(?![가-힣ㄱ-ㅎa-zA-Z0-9])',
  );
  String _stripOrphanTimeParticles(String title) {
    final result = title
        .replaceAll(_trailingTimeParticlePattern, ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return result.isEmpty ? title.trim() : result;
  }

  String ensurePeopleInTitle(String title, String rawText) {
    final normalizedTitle = _stripOrphanTimeParticles(
      _stripStandaloneParticles(
        _preserveRoleRecipientInTitle(
          normalizeSpacingForSchedule(title),
          rawText,
        ),
      ),
    );
    final compactTitle =
        normalizedTitle.replaceAll(RegExp(r'\s+'), '').toLowerCase();
    final people = extractPeopleFields(rawText).all.where((person) {
      final compactPerson = person.replaceAll(RegExp(r'\s+'), '').toLowerCase();
      // "뒤에"·"후에" 같은 시간 조사가 사람으로 오인 추출되어, 위에서 제거한
      // 시간 찌꺼기를 사람 이름으로 제목 앞에 다시 붙이는 것을 방지한다.
      if (_trailingTimeParticlePattern.hasMatch(person.trim())) {
        return false;
      }
      return !normalizedTitle.contains(person) &&
          !compactTitle.contains(compactPerson);
    }).toList(growable: false);
    if (people.isEmpty) {
      return normalizedTitle;
    }
    return normalizeSpacingForSchedule('${people.join(' ')} $normalizedTitle');
  }

  String _preserveRoleRecipientInTitle(String title, String rawText) {
    var resolved = title;
    final source = normalizeText(rawText, '');
    final matches = RegExp(
      r'([가-힣]{2,5})\s*(?:p\.?\s*m|피엠)\s*(한테|에게|께)',
      caseSensitive: false,
    ).allMatches(source);
    for (final match in matches) {
      final name = match.group(1)?.trim();
      final particle = match.group(2)?.trim();
      if (name == null ||
          name.isEmpty ||
          particle == null ||
          particle.isEmpty ||
          _isProbablyNonPerson(name)) {
        continue;
      }
      final phrase = '$name PM$particle';
      final orphan = RegExp(
        r'(^|\s)(?:p\.?\s*m|피엠)\s*' + RegExp.escape(particle),
        caseSensitive: false,
      );
      if (orphan.hasMatch(resolved)) {
        final replacement = resolved.contains(name) ? 'PM$particle' : phrase;
        resolved = resolved.replaceFirstMapped(
          orphan,
          (orphanMatch) => '${orphanMatch.group(1) ?? ''}$replacement',
        );
        continue;
      }
      if (!resolved.contains(name)) {
        resolved = '$phrase $resolved';
      }
    }
    return normalizeSpacingForSchedule(resolved);
  }

  String? normalizeScheduleLocation({
    String? location,
    required String rawText,
    required String title,
  }) {
    final trimmed = location?.trim();
    if (trimmed != null && trimmed.isNotEmpty) {
      final normalizedLocation = _normalizeLocationCandidate(trimmed);
      if (normalizedLocation != null) {
        return normalizedLocation;
      }
    }

    // 장소 추출 전 날짜/시간/반복 표현 제거 (조사 에/에서는 보존).
    // "7월1일 원주세브란스병원에서..."가 장소에 날짜를 포함시켜
    // 지도 좌표가 안 잡히던 문제 방지.
    final source = stripScheduleNoise(
      normalizeText(rawText, ''),
      preserveRelativeDayWords: false,
    );
    final leadingMemoPlace = RegExp(
      r'^(.{2,40}?)에서\s+.+?\s+메모(?:에|에는|로|으로|를|은|는)?\s+',
    ).firstMatch(source);
    final leadingMemoLocation = leadingMemoPlace?.group(1)?.trim();
    if (leadingMemoLocation != null &&
        leadingMemoLocation.isNotEmpty &&
        !_isInvalidLocationCandidate(leadingMemoLocation)) {
      return normalizeSpacingForSchedule(leadingMemoLocation);
    }
    final inferredFromLeadingLocation = extractLeadingLocation(source);
    if (inferredFromLeadingLocation != null &&
        inferredFromLeadingLocation.isNotEmpty) {
      return normalizeSpacingForSchedule(inferredFromLeadingLocation);
    }

    // 문장 중간 장소 추출: "...원주 세브란스 기독병원에 와서..."처럼
    // 사람 이름 뒤(문장 중간)에 장소 키워드가 오는 경우.
    final inferredFromMid = extractMidLocation(source);
    if (inferredFromMid != null && inferredFromMid.isNotEmpty) {
      return normalizeSpacingForSchedule(inferredFromMid);
    }

    final inferredFromDeparture = RegExp(
      r'([가-힣A-Za-z0-9·.]{2,})\s*(?:에서\s*)?출발',
    ).firstMatch(source);
    if (inferredFromDeparture != null) {
      final inferred = inferredFromDeparture.group(1)?.trim();
      if (inferred != null && inferred.isNotEmpty) {
        return normalizeSpacingForSchedule(inferred);
      }
    }

    final inferredFromTitle = RegExp(
      r'([가-힣A-Za-z0-9·.]{2,})\s*(?:출발|도착)$',
    ).firstMatch(title);
    if (inferredFromTitle != null) {
      final inferred = inferredFromTitle.group(1)?.trim();
      if (inferred != null && inferred.isNotEmpty) {
        return normalizeSpacingForSchedule(inferred);
      }
    }

    return null;
  }

  String? _normalizeLocationCandidate(String text) {
    final normalized = normalizeSpacingForSchedule(text);
    if (normalized.isEmpty) {
      return null;
    }

    final withoutLeadingTime = _stripLeadingTimePrefix(normalized);
    final strippedNoise = stripScheduleNoise(withoutLeadingTime);
    final cleaned =
        strippedNoise.isNotEmpty ? strippedNoise : withoutLeadingTime;
    if (cleaned.isEmpty || _isInvalidLocationCandidate(cleaned)) {
      return null;
    }
    return normalizeSpacingForSchedule(cleaned);
  }

  String _stripLeadingTimePrefix(String text) {
    final normalized = normalizeSpacingForSchedule(text);
    if (normalized.isEmpty) {
      return normalized;
    }

    final leadingCue = _leadingTimeCue(normalized);
    if (leadingCue == null) {
      return normalized;
    }

    final stripped = normalized.substring(leadingCue.end).trim();
    return stripped.isEmpty ? normalized : stripped;
  }

  void preserveDeliveryContent(
    Map<String, dynamic> scheduleFields,
    String contentText,
  ) {
    final split = splitLeadingMedicalLocation(contentText);
    if (split == null ||
        !RegExp(r'(갖다\s*주|가져다\s*주|전달|배송|납품)').hasMatch(split.remainder)) {
      return;
    }

    final currentLocation = scheduleFields['location']?.toString().trim();
    final firstRemainderToken = split.remainder.split(RegExp(r'\s+')).first;
    if (currentLocation == null ||
        currentLocation.isEmpty ||
        currentLocation.contains(firstRemainderToken)) {
      scheduleFields['location'] = normalizeSpacingForSchedule(split.location);
      scheduleFields['location_lat'] = null;
      scheduleFields['location_lng'] = null;
    }

    final currentTitle = scheduleFields['title']?.toString().trim() ?? '';
    if (currentTitle.isEmpty || !currentTitle.contains(firstRemainderToken)) {
      scheduleFields['title'] = normalizeSpacingForSchedule(split.remainder);
    }

    final supplies = scheduleFields['supplies'];
    if (supplies is Iterable && supplies.isEmpty) {
      final supplyMatch = RegExp(
        r'(?:^|\s)([가-힣A-Za-z0-9]+)\s*(?:갖다\s*주|가져다\s*주|전달|배송|납품)',
      ).firstMatch(split.remainder);
      final supply = supplyMatch?.group(1)?.trim();
      if (supply != null &&
          supply.isNotEmpty &&
          supply != firstRemainderToken) {
        scheduleFields['supplies'] = <String>[supply];
      }
    }
  }

  VoiceScheduleStructureSplit? splitLeadingMedicalLocation(String text) {
    final normalized = normalizeText(text, '');
    final match = RegExp(
      r'^(.+?(?:정형외과|이비인후과|피부과|성형외과|신경외과|내과|외과|안과|치과|한의원|의원|병원|클리닉|약국))\s+(.+)$',
    ).firstMatch(normalized);
    final location = match?.group(1)?.trim();
    final remainder = match?.group(2)?.trim();
    if (location == null ||
        location.isEmpty ||
        _isInvalidLocationCandidate(location) ||
        remainder == null ||
        remainder.isEmpty) {
      return null;
    }

    return VoiceScheduleStructureSplit(
      location: location,
      remainder: remainder,
    );
  }

  bool shouldPreferStructuredTitle({
    required String normalizedTitle,
    required String structuredTitle,
    required VoiceScheduleStructure structure,
  }) {
    if (!structure.hasLeadingTimeCue || structuredTitle.isEmpty) {
      return false;
    }
    if (normalizedTitle.isEmpty) {
      return true;
    }
    final leadingDay =
        RegExp(r'(오늘|내일|모레|글피)').firstMatch(structure.leadingTimeCue ?? '');
    if (leadingDay != null &&
        normalizedTitle.startsWith(leadingDay.group(1)!)) {
      return true;
    }
    final normalizedTokens = _meaningfulTitleTokens(normalizedTitle);
    final structuredTokens = _meaningfulTitleTokens(structuredTitle);
    if (normalizedTokens.isEmpty || structuredTokens.isEmpty) {
      return false;
    }
    final missingFromStructured =
        normalizedTokens.where((token) => !structuredTokens.contains(token));
    final structuredHasMoreMeaning =
        structuredTokens.length > normalizedTokens.length;
    if (missingFromStructured.isEmpty && structuredHasMoreMeaning) {
      return true;
    }
    final compactTitle = normalizedTitle.replaceAll(RegExp(r'\s+'), '');
    final compactStructured = structuredTitle.replaceAll(RegExp(r'\s+'), '');
    return compactTitle.length >= 2 &&
        compactStructured.length > compactTitle.length &&
        compactStructured.contains(compactTitle);
  }

  String normalizeSpacingForSchedule(String text) {
    final compact = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (compact.isEmpty) {
      return compact;
    }

    final spaced = compact.replaceAllMapped(
      RegExp(
        '([가-힣A-Za-z0-9·.]{2,}?)(${_titleEventNouns.join('|')})\$',
      ),
      (match) {
        final head = match.group(1);
        final tail = match.group(2);
        if (head == null || tail == null) {
          return match.group(0) ?? '';
        }
        return '$head $tail';
      },
    );
    return spaced.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  String? extractLeadingLocation(String text) {
    final match = RegExp(
      r'^([가-힣A-Za-z0-9·.]+(?:\s+[가-힣A-Za-z0-9·.]+){0,4})\s*(에서|에|으로|로)\s+(.+)$',
    ).firstMatch(text.trim());
    if (match == null) {
      return null;
    }

    var rawLocation = match.group(1)?.trim();
    final particle = match.group(2);
    final remainder = match.group(3)?.trim();
    // group1이 greedy 매칭으로 "모란역으로"를 "모란역으" + 조사 "로"로 잘라낸 경우
    // (조사 "으로"의 "으"가 장소 끝에 붙음) → 끝의 "으"를 떼어 "모란역"으로 복원한다.
    if (rawLocation != null && particle == '로' && rawLocation.endsWith('으')) {
      rawLocation = rawLocation.substring(0, rawLocation.length - 1);
    }
    if (rawLocation == null ||
        rawLocation.isEmpty ||
        remainder == null ||
        remainder.isEmpty) {
      return null;
    }
    // 앞에 사람 이름/직급이 섞여 있으면 직급 경계 이후만 장소로 사용
    // ("장재균 그룹장님 원주 세브란스 기독병원" → "원주 세브란스 기독병원")
    final location = _dropLeadingPersonTokens(rawLocation);
    if (location.isEmpty || _isInvalidLocationCandidate(location)) {
      return null;
    }
    return location;
  }

  /// 장소 후보 앞쪽의 사람 이름/직급 토큰을 제거한다.
  /// "장재균 그룹장님 원주 세브란스 기독병원" → "원주 세브란스 기독병원".
  String _dropLeadingPersonTokens(String candidate) {
    final tokens = candidate.trim().split(RegExp(r'\s+'));
    var startIdx = 0;
    for (var i = 0; i < tokens.length; i++) {
      if (_personTitleSuffixPattern.hasMatch(tokens[i])) {
        startIdx = i + 1;
      }
    }
    return tokens.sublist(startIdx).join(' ').trim();
  }

  /// 문장 중간의 장소를 장소 키워드(병원/센터/역 등) 기준으로 추출한다.
  /// "장재균 그룹장님 원주 세브란스 기독병원에 와서..." → "원주 세브란스 기독병원".
  /// 키워드 앞에 사람 이름/직급이 있으면 직급 경계 이후만 장소로 본다.
  String? extractMidLocation(String text) {
    final source = text.trim();
    if (source.isEmpty) {
      return null;
    }
    final keywordPattern = _placeKeywords.join('|');
    // 장소 키워드로 끝나는 구 + 조사(에/에서/로/으로)
    final match = RegExp(
      '([가-힣A-Za-z0-9·.]+(?:\\s+[가-힣A-Za-z0-9·.]+){0,5}'
      '(?:$keywordPattern))\\s*(?:에서|에|로|으로)',
    ).firstMatch(source);
    if (match == null) {
      return null;
    }
    final candidate = match.group(1)?.trim();
    if (candidate == null || candidate.isEmpty) {
      return null;
    }
    // 사람 직급/호칭 경계 이후만 장소로 사용
    final location = _dropLeadingPersonTokens(candidate);
    if (location.isEmpty || _isInvalidLocationCandidate(location)) {
      return null;
    }
    return location;
  }

  /// 후보 문자열에 실제 장소임을 뒷받침하는 근거(장소 접미사/지역명)가
  /// 있는지 확인한다. 다른 워커가 장소 후보를 추가로 검증할 때 쓰는
  /// 얕고 단순한 공개 헬퍼다 — `location_lookup_service.dart`는 무거운
  /// 테스트가 고정돼 있어 수정하지 않고, 필요한 어휘를 여기 자체 정의한다.
  bool hasLocalPlaceEvidence(String candidate) {
    final normalized = candidate.trim();
    if (normalized.isEmpty) {
      return false;
    }
    const placeSuffixes = <String>[
      '역',
      '병원',
      '점',
      '센터',
      '공항',
      '터미널',
      '학교',
      '호텔',
      '사무실',
      '로',
      '길',
      '동',
      '구',
      '시',
    ];
    if (placeSuffixes.any((suffix) => normalized.endsWith(suffix))) {
      return true;
    }
    const regionNames = <String>[
      '서울',
      '부산',
      '대구',
      '인천',
      '광주',
      '대전',
      '울산',
      '세종',
      '경기',
      '강원',
      '충북',
      '충남',
      '전북',
      '전남',
      '경북',
      '경남',
      '제주',
      '강남',
      '강북',
      '원주',
    ];
    return regionNames.any((region) => normalized.contains(region));
  }

  String preserveLeadingLocationTitle(
    String text, {
    String? rawText,
  }) {
    final normalized = text.trim();
    if (normalized.isEmpty) {
      return normalized;
    }
    // 장소 추출 소스에서 날짜/시간을 먼저 제거 (조사 보존).
    // rawText 원본을 그대로 쓰면 "7월1일 원주세브란스병원"처럼 날짜가
    // 장소로 잡혀 제목 앞에 붙던 문제 방지.
    final sourceText = rawText?.trim().isNotEmpty == true
        ? stripScheduleNoise(rawText!.trim(), preserveRelativeDayWords: false)
        : normalized;
    final extractedLocation = extractLeadingLocation(sourceText);
    if (extractedLocation == null || extractedLocation.isEmpty) {
      return stripLeadingLocationPhrase(normalized);
    }
    // 장소는 location 필드에 넣되 어떤 종류든 제목에도 그대로 유지한다
    // (사용자 요구 — 회사/사무실/아파트 등 예외 없이 전부 유지).
    // 후보 순서: 추출된 장소 전체 -> 첫 토큰만(조사 제거) 루트.
    // extractLeadingLocation이 뒤 문장까지 과매칭할 때를 대비한 방어이며,
    // 이미 알고 있는 후보를 문장 맨 앞에서만 정확히 잘라낸다.
    // stripLeadingLocationPhrase의 느슨한 정규식은 "리바로"처럼 조사가 아닌
    // 단어 끝 글자를 조사로 오인해 잘라내는 부작용이 있어 여기서는 쓰지 않는다.
    final candidates = <String>{
      extractedLocation.trim(),
      _leadingLocationRoot(extractedLocation),
    }..removeWhere((candidate) => candidate.isEmpty);

    for (final candidate in candidates) {
      final stripped = _stripKnownLeadingLocationPrefix(normalized, candidate);
      if (stripped != normalized && stripped.isNotEmpty) {
        return normalizeSpacingForSchedule('$candidate $stripped');
      }
    }
    return normalizeSpacingForSchedule(normalized);
  }

  /// 구절에 일정 명령/메타 토큰이 섞여 있는지 판정한다.
  /// [_isInvalidLocationCandidate]의 2단 거부(복합 메타구 contains + 단독
  /// 명령 동사 토큰 단위) 중 **명령/메타 부분만** 떼어낸 것 — 시간부사·조사
  /// 조각 같은 다른 거부 사유는 포함하지 않는다(그것들은 제목에서 잘라내는
  /// 게 맞는 동작이라 자르기를 막으면 안 된다).
  bool _containsScheduleCommandToken(String phrase) {
    final normalized = phrase.trim();
    if (normalized.isEmpty) {
      return false;
    }
    final compact = normalized.replaceAll(_whitespaceSplitPattern, '');
    for (final metaPhrase in _scheduleMetaPhrases) {
      if (compact.contains(metaPhrase)) {
        return true;
      }
    }
    final words = normalized.split(_whitespaceSplitPattern);
    for (final word in words) {
      if (word.isNotEmpty && _isScheduleCommandWord(word)) {
        return true;
      }
    }
    // 구절이 단독 "일정"으로 끝나면 메타 구절로 본다("태블릿계기판 일정에
    // 저장해놔"에서 앞부분을 잘라 "저장해놔"만 남는 것을 막는다). 위치 기반
    // 판정이라 "일정"이 중간에 낀 실제 장소명은 건드리지 않는다.
    if (words.isNotEmpty && words.last == '일정') {
      return true;
    }
    return false;
  }

  String _leadingLocationRoot(String location) {
    final normalized = normalizeText(location, '').trim();
    if (normalized.isEmpty) {
      return '';
    }
    final firstToken = normalized.split(RegExp(r'\s+')).first.trim();
    if (firstToken.isEmpty) {
      return '';
    }
    final stripped = firstToken.replaceFirst(
      RegExp(r'(?:에서|에|로|으로)$'),
      '',
    );
    if (stripped.isEmpty) {
      return '';
    }
    return normalizeSpacingForSchedule(stripped);
  }

  String _stripKnownLeadingLocationPrefix(String text, String location) {
    final normalizedText = text.trim();
    final normalizedLocation = location.trim();
    if (normalizedText.isEmpty || normalizedLocation.isEmpty) {
      return normalizedText;
    }
    if (normalizedText == normalizedLocation) {
      return '';
    }
    final prefixPattern = RegExp(
      '^${RegExp.escape(normalizedLocation)}(?:\\s*(?:에서|에|로|으로)\\s*)?',
    );
    if (!prefixPattern.hasMatch(normalizedText)) {
      return normalizedText;
    }
    final remainder = normalizedText.replaceFirst(prefixPattern, '').trim();
    if (remainder.isEmpty) {
      return normalizedText;
    }
    return normalizeSpacingForSchedule(remainder);
  }

  String stripLeadingLocationPhrase(String text) {
    final match = RegExp(
      r'^([가-힣A-Za-z0-9·.]+(?:\s+[가-힣A-Za-z0-9·.]+){0,4})\s*(에서|에|로|으로)\s+(.+)$',
    ).firstMatch(text.trim());
    if (match == null) {
      return text.trim();
    }
    // 조사 앞의 "장소 구절 전체"에 명령/메타 토큰이 섞였으면 자르지 않는다.
    // 과거엔 구절의 첫 토큰만 검사해서, "태블릿계기판 중요한일정으로 저장"처럼
    // 첫 토큰("태블릿계기판")은 멀쩡하고 뒤에 명령 구절이 붙은 경우를 못 걸러
    // 앞부분을 통째로 잘라 제목이 "저장"만 남는 버그가 있었다(2026-07-18 실증).
    //
    // 여기서 _isInvalidLocationCandidate 전체를 쓰면 안 된다 — 그 함수는
    // 시간부사("오전")도 invalid로 판정하는데, 시간 접두어는 제목에서
    // 제거되는 게 맞는 동작이라("오전에 경조사 신청" -> "경조사 신청")
    // 자르기를 막으면 회귀한다. 명령/메타 토큰일 때만 좁게 막는다.
    //
    // BLOCKER 수정(2026-07-21 실증): group1은 위 정규식에서 greedy `+`로
    // 매칭되므로 "...일정으로"가 "...일정으" + 조사 "로"로 쪼개질 수 있다
    // (참고: 이 분할은 조사 대체 알파벳 순서와 무관하다 — group1의 문자
    // 단위 백트래킹이 항상 "으"를 group1 쪽에 먼저 남기고 "로"만으로 매치를
    // 완성하기 때문에, 알파벳 순서를 바꿔도 동일하게 재현된다. 실측:
    // dart로 두 순서 모두 테스트해 동일한 분할 결과를 확인함). 그 결과
    // locationPhrase가 "일정으"로 남아 _containsScheduleCommandToken의
    // "words.last == '일정'" 가드가 매치하지 못하고, 명령문구가 그대로
    // 통과해 제목 내용이 유실됐다("태블릿계기판 일정으로 잡아줘" ->
    // "잡아줘"). [extractLeadingLocation]이 이미 쓰고 있는 것과 동일한
    // 보정("로" 조사 앞에서 group1이 "으"로 끝나면 그 "으"를 group1에서
    // 떼어낸다)을 여기서도 적용해 가드가 정상 작동하게 한다.
    var locationPhrase = match.group(1)?.trim();
    final particle = match.group(2);
    if (locationPhrase != null &&
        particle == '로' &&
        locationPhrase.endsWith('으')) {
      locationPhrase = locationPhrase.substring(0, locationPhrase.length - 1);
    }
    if (locationPhrase == null ||
        locationPhrase.isEmpty ||
        _containsScheduleCommandToken(locationPhrase)) {
      return text.trim();
    }
    // locationHead는 조사가 붙은 원문 형태에서 뽑는다("오전에"). 조사를 뗀
    // 형태("오전")로 뽑으면 시간부사 거부 정규식(^오전$)에 걸려, 제목에서
    // 시간 접두어를 잘라내는 정상 동작까지 막힌다.
    final locationHead = RegExp(r'^([가-힣A-Za-z0-9·.]{2,})')
        .firstMatch(match.group(0)?.trim() ?? '')
        ?.group(1)
        ?.trim();
    if (locationHead == null || _isInvalidLocationCandidate(locationHead)) {
      return text.trim();
    }
    final remainder = match.group(3)?.trim();
    if (remainder == null || remainder.isEmpty) {
      return text.trim();
    }
    return remainder;
  }

  bool _isInvalidLocationCandidate(String text) {
    final normalized = normalizeText(text, '');
    if (normalized.isEmpty) {
      return true;
    }
    if (isOnlyScheduleMetadata(normalized)) {
      return true;
    }
    // 방어 심층: 정규식이 놓친 변형까지 차단한다. isOnlyScheduleMetadata는
    // 문자열 전체가 메타 토큰일 때만 걸러내므로 "태블릿계기판 중요한일정"처럼
    // 일반명사와 섞이면 통과시키던 문제(2026-07-17 실증 버그)의 2차 방어선.
    //
    // 검사는 두 단계로 나눈다 — 단독 동사를 부분문자열로 검사하면 실제
    // 장소명이 오탐 거부되기 때문이다(실증: "국가기록원"이 '기록'으로,
    // "추가정형외과"가 '추가'로 거부됨).
    //  ① 장소명에 절대 안 나타나는 복합 메타구는 "포함"으로 거부.
    //  ② 단독 명령 동사는 공백 분리 토큰 단위로만 거부.
    final compact = normalized.replaceAll(RegExp(r'\s+'), '');
    for (final phrase in _scheduleMetaPhrases) {
      if (compact.contains(phrase)) {
        return true;
      }
    }
    final words = normalized.split(_whitespaceSplitPattern);
    for (final word in words) {
      if (word.isNotEmpty && _isScheduleCommandWord(word)) {
        return true;
      }
    }
    // 후보의 마지막 토큰이 단독 "일정"이면 거부한다(2026-07-17 HIGH#2 실증:
    // "태블릿계기판 일정"/"태블릿계기판 일정으로"류 변형이 extractLeadingLocation의
    // 조사 매칭에서 particle로 "에"가 쓰이면 stripScheduleNoise의 뒤쪽 명령문구
    // 정규식(위)이 매치하지 못해 후보에 "일정"이 그대로 남는다). 단독 "일정"을
    // _scheduleCommandTokens에 그냥 추가하면 "일정"을 포함한 실제 장소명 전체가
    // (토큰 위치와 무관하게) 오탐 거부될 위험이 있으므로, 여기서는 후보의
    // **마지막 토큰**일 때만 판정한다 — "일정" 자체가 문장 중간에 낀 실제
    // 장소명은 건드리지 않는다.
    if (words.isNotEmpty && words.last == '일정') {
      return true;
    }
    if (RegExp(
      r'^(?:오늘|내일|모레|글피|오전|오후|아침|낮|점심|저녁|밤|새벽|오전중|오후중|오전쯤|오후쯤)$',
    ).hasMatch(normalized.replaceAll(RegExp(r'\s+'), ''))) {
      return true;
    }
    // 동사 어간 + 조사 조각("간 뒤", "한 뒤", "온 뒤" 등)을 비명사로 거부.
    // 한국어 동사 어간(한 글자 이상) + 공백 + 후치(뒤/후/에/으로/까지 등) 패턴.
    if (RegExp(
      r'^[가-힣]{1,4}\s+(?:뒤|후|에|으로|까지|서|부터)(?:에|로|서)?$',
    ).hasMatch(normalized)) {
      return true;
    }
    // 조사/연결어미로만 구성된 조각을 비명사로 거부.
    if (RegExp(
      r'^(?:뒤|후|에|으로|까지|서|부터|이후|그후|그뒤|뒤에|후에|뒤로|후로)+$',
    ).hasMatch(normalized.replaceAll(RegExp(r'\s+'), ''))) {
      return true;
    }
    // 순수 동사형(어미 "-ㄴ/은/는/고/서" 등으로 끝나는 짧은 조각)을 비명사로 거부.
    // 단, 3글자 이상의 명사 후보는 통과시켜 "강남역" 등을 보호.
    if (normalized.length <= 4 &&
        RegExp(
          r'[가-힣](?:간|온|한|된|된다|하고|해서|이고|이며)$',
        ).hasMatch(normalized)) {
      return true;
    }
    return false;
  }

  bool isOnlyScheduleMetadata(String text) {
    return RegExp(
      r'^(?:오늘|내일|모레|글피|오전|오후|아침|점심|저녁|밤|새벽|매주|매월|매년|격주|반복|알림|리마인더|알람|\d{1,2}\s*시|\d{1,3}\s*(?:분|시간)\s*(?:뒤|후|있다가|이따))*$',
    ).hasMatch(text.replaceAll(RegExp(r'\s+'), ''));
  }

  Set<String> _meaningfulTitleTokens(String text) {
    return VoiceTextCleanupService.normalizeBasic(text)
        .split(RegExp(r'\s+'))
        .map((token) => token.trim())
        .where((token) => token.length >= 2)
        .toSet();
  }

  List<String> _peopleNearPattern(String source, RegExp pattern) {
    final people = <String>[];
    for (final match in pattern.allMatches(source)) {
      final person = _normalizePersonCandidate(match.group(1));
      if (person == null ||
          person.isEmpty ||
          _isProbablyNonPerson(person) ||
          people.contains(person)) {
        continue;
      }
      people.add(person);
    }
    return people;
  }

  String? _normalizePersonCandidate(String? value) {
    final rawPerson = value?.trim();
    if (rawPerson == null || rawPerson.isEmpty) {
      return null;
    }
    var person = rawPerson;
    for (final suffix in const <String>['한테', '에게', '께']) {
      if (person.length > suffix.length + 1 && person.endsWith(suffix)) {
        person = person.substring(0, person.length - suffix.length);
        break;
      }
    }
    return person;
  }

  bool _isProbablyNonPerson(String text) {
    const nonPersonTerms = <String>{
      '강릉',
      '병원',
      '세브란스',
      '회의',
      '방문',
      '시험',
      '일정',
      '장소',
      '시간',
      '전화',
      '연락',
      '확인',
      '문의',
      '보고',
      '전달',
      '물어보기',
      '업무',
      '문서',
      '자료',
      '프로젝트',
      '리포트',
      '계약',
      '견적',
      '메일',
      '문자',
      '정형외',
      '신경외',
      '성형외',
      '흉부외',
      '일반외',
      '혼자',
      '같이',
      '오늘',
      '내일',
      '모레',
      '모래',
      '주차장',
      '매장',
      '출장',
      '공장',
      '시장',
      '현장',
      '식장',
    };
    if (nonPersonTerms.contains(text)) {
      return true;
    }
    return text.endsWith('건지') ||
        text.endsWith('는지') ||
        text.endsWith('런지') ||
        text.endsWith('인지') ||
        text.endsWith('할지') ||
        text.endsWith('올지');
  }

  bool _looksLikeNonPersonRecipient(String text) {
    if (_isProbablyNonPerson(text)) {
      return true;
    }
    return RegExp(
      r'(?:동|로|길|읍|면|리|시|군|구|역|점|센터|병원|대학교|대학|공원|터미널|사무소|본사|지점|매장|공장)$',
    ).hasMatch(text);
  }

  String _normalizeRelativeDayMisrecognition(String text) {
    if (!RegExp(
      r'(오늘|내일|오전|오후|아침|점심|저녁|밤|새벽|\d{1,2}\s*시|일정|방문|전화|연락|확인|문의|물어보|묻기|올건지|오는지|오시는지)',
    ).hasMatch(text)) {
      return text;
    }
    // STT가 '내일모레'를 '내일모래'(붙은 형태)로 인식한 경우 먼저 교정한 뒤,
    // 단독 '모래'(=모레)도 교정한다.
    return text
        .replaceAll('내일모래', '내일모레')
        .replaceAllMapped(
          RegExp(r'(^|\s)모래(?=\s|$)'),
          (match) => '${match.group(1) ?? ''}모레',
        );
  }

  String _extractContentClause(String text) {
    final match = RegExp(
      r'(?:내용은|내용\s*[:：]|할\s*일은|일정\s*내용은)\s*(.+)$',
    ).firstMatch(text);
    final content = match?.group(1)?.trim();
    if (content == null || content.isEmpty) {
      return '';
    }
    return content.replaceFirst(RegExp(r'^[.。,\s]+'), '').trim();
  }

  RegExpMatch? _leadingTimeCue(String text) {
    final patterns = <RegExp>[
      RegExp(
        r'^\s*(?:(?:오늘|내일|모레|글피)\s*)?(?:오전|오후|아침|낮|점심|저녁|밤|새벽)\s*(?:\d{1,2}|[가-힣]{1,8})\s*시(?:\s*(?:\d{1,2}|[가-힣]{1,8})\s*분?|\s*반)?(?:에|부터)?\s*',
      ),
      RegExp(
        r'^\s*(?:오늘|내일|모레|글피)\s*(?:\d{1,2}|[가-힣]{1,8})\s*시(?:\s*(?:\d{1,2}|[가-힣]{1,8})\s*분?|\s*반)?(?:에|부터)?\s*',
      ),
      RegExp(
        r'^\s*(?:(?:\d{4})\s*년\s*)?\d{1,2}\s*월\s*\d{1,2}\s*일(?:\s*(?:오전|오후|아침|낮|점심|저녁|밤|새벽)?\s*(?:\d{1,2}|[가-힣]{1,8})\s*시(?:\s*(?:\d{1,2}|[가-힣]{1,8})\s*분?|\s*반)?)?(?:에|부터)?\s*',
      ),
      RegExp(
        r'^\s*(?:지금으로부터\s*)?\d{1,2}\s*(?:개월|달|월)\s*(?:뒤|후)(?:부터)?\s*',
      ),
      RegExp(r'^\s*(?:오늘|내일|모레|글피)(?:에|부터)?\s+'),
    ];

    for (final pattern in patterns) {
      final match = pattern.firstMatch(text);
      if (match != null && (match.group(0)?.trim().isNotEmpty ?? false)) {
        return match;
      }
    }
    return null;
  }

  Map<String, String> _extractExplicitFieldClauses(String text) {
    final clauses = <String, String>{};
    final memo = RegExp(r'(?:메모에|설명에|노트로)\s*[:：]?\s*(.+)$')
        .firstMatch(text)
        ?.group(1)
        ?.trim();
    if (memo != null && memo.isNotEmpty) {
      clauses['memo'] = memo;
    }

    final recurrence = RegExp(
      r'(매일|매주|매월|매년|격주|\d{1,2}\s*(?:일|주|개월|달|월|년)\s*마다)',
    ).firstMatch(text)?.group(0)?.trim();
    if (recurrence != null && recurrence.isNotEmpty) {
      clauses['recurrence_rule'] = recurrence;
    }

    final allDay =
        RegExp(r'(하루\s*종일|하루종일|종일|온종일)').firstMatch(text)?.group(0)?.trim();
    if (allDay != null && allDay.isNotEmpty) {
      clauses['is_all_day'] = allDay;
    }
    return clauses;
  }

  String _stripExplicitFieldClauses(String text) {
    return normalizeSpacingForSchedule(
      text.replaceFirst(
        RegExp(r'\s*(?:메모에|설명에|노트로)\s*[:：]?\s*.+$'),
        ' ',
      ),
    );
  }
}
