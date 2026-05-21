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

class VoiceScheduleStructureService {
  const VoiceScheduleStructureService();

  static const String _personSuffixPattern =
      r'팀장님|팀장|원장님|원장|교수님|교수|과장님|과장|부장님|부장|차장님|차장|대표님|대표|선생님|대리님|대리|고객님|고객|님';

  static final List<RegExp> _cuePatterns = <RegExp>[
    RegExp(r'(?:(?:\d{4})\s*년\s*)?\d{1,2}\s*월\s*\d{1,2}\s*일'),
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
      RegExp(r'(?:지금으로부터\s*)?\d{1,2}\s*(?:개월|달|월)\s*(?:뒤|후)'),
      RegExp(r'(?:오전|오후|아침|점심|저녁|밤|새벽)'),
      RegExp(r'\d{1,2}\s*시(?:\s*(?:\d{1,2}\s*분?|반))?'),
      RegExp(r'\d{1,3}\s*(?:분|시간)\s*(?:뒤|후|있다가|이따)'),
      RegExp(r'\d{1,2}\s*(?:일|주|개월|달|월|년)\s*마다'),
      RegExp(r'(?:매주|매월|매년|격주|매일)'),
      RegExp(r'(?:반복|알림|리마인더|알람|reminder)'),
      RegExp(r'(?:부터|까지|동안|정각|정도|쯤|경|예정|예약)'),
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
    final titleWithoutLocation = stripLeadingLocationPhrase(cleaned);
    final structuredTitle = stripLeadingLocationPhrase(
      stripScheduleNoise(
        structure.titleCandidate,
        preserveRelativeDayWords: true,
      ),
    );
    if (shouldPreferStructuredTitle(
      normalizedTitle: titleWithoutLocation,
      structuredTitle: structuredTitle,
      structure: structure,
    )) {
      return ensurePeopleInTitle(
        normalizeSpacingForSchedule(structuredTitle),
        rawText,
      );
    }
    if (titleWithoutLocation.isNotEmpty) {
      return ensurePeopleInTitle(
        normalizeSpacingForSchedule(titleWithoutLocation),
        rawText,
      );
    }

    final fallback = stripLeadingLocationPhrase(
      stripScheduleNoise(
        rawText,
        preserveRelativeDayWords: preserveRelativeDayWords,
      ),
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
          RegExp(
            r'(?:(오전|오후|아침|낮|점심|저녁|밤|새벽)\s*)?[가-힣0-9]{1,8}\s*시(?:\s*[가-힣0-9]{1,8}\s*분?|\s*반)?',
          ),
          ' ',
        )
        .replaceAll(RegExp(r'\d{1,3}\s*(분|시간)\s*(뒤|후|있다가|이따)'), ' ')
        .replaceAll(
          (shouldPreserveRelativeDayWords(referenceText ?? title)
              ? RegExp(r'(이번주|다음주|격주|매주|매월|매년)')
              : RegExp(
                  r'(오늘|내일|모레|글피|이번주|다음주|격주|매주|매월|매년)',
                )),
          ' ',
        )
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    title = stripLeadingLocationPhrase(title);

    final structuredTitle = stripLeadingLocationPhrase(
      stripScheduleNoise(
        structure.titleCandidate,
        preserveRelativeDayWords: true,
      ),
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
    return ensurePeopleInTitle(resolvedTitle, referenceText ?? text);
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
    }.toList(growable: false);

    return VoiceSchedulePeopleFields(
      participants: participants,
      targets: targets,
    );
  }

  String ensurePeopleInTitle(String title, String rawText) {
    final normalizedTitle = normalizeSpacingForSchedule(title);
    final people = extractPeopleFields(rawText)
        .all
        .where((person) => !normalizedTitle.contains(person))
        .toList(growable: false);
    if (people.isEmpty) {
      return normalizedTitle;
    }
    return normalizeSpacingForSchedule('${people.join(' ')} $normalizedTitle');
  }

  String? normalizeScheduleLocation({
    String? location,
    required String rawText,
    required String title,
  }) {
    final trimmed = location?.trim();
    if (trimmed != null && trimmed.isNotEmpty) {
      return normalizeSpacingForSchedule(trimmed);
    }

    final source = normalizeText(rawText, '');
    final inferredFromLeadingLocation = extractLeadingLocation(source);
    if (inferredFromLeadingLocation != null &&
        inferredFromLeadingLocation.isNotEmpty) {
      return normalizeSpacingForSchedule(inferredFromLeadingLocation);
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
    return missingFromStructured.isEmpty && structuredHasMoreMeaning;
  }

  String normalizeSpacingForSchedule(String text) {
    final compact = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (compact.isEmpty) {
      return compact;
    }

    final spaced = compact.replaceAllMapped(
      RegExp(
        r'([가-힣A-Za-z0-9·.]{2,}?)(출발|도착|미팅|회의|방문|진료|검진|약속|모임|식사|수업|강의|운동|여행|병문안|상담|출근|퇴근|발표|면접|예약)$',
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
      r'^([가-힣A-Za-z0-9·.]{2,})\s*(?:에서|에|로|으로)\s+(.+)$',
    ).firstMatch(text.trim());
    if (match == null) {
      return null;
    }

    final location = match.group(1)?.trim();
    final remainder = match.group(2)?.trim();
    if (location == null ||
        location.isEmpty ||
        remainder == null ||
        remainder.isEmpty) {
      return null;
    }
    return location;
  }

  String stripLeadingLocationPhrase(String text) {
    final match = RegExp(
      r'^[가-힣A-Za-z0-9·.]{2,}\s*(?:에서|에|로|으로)\s+(.+)$',
    ).firstMatch(text.trim());
    if (match == null) {
      return text.trim();
    }
    final remainder = match.group(1)?.trim();
    if (remainder == null || remainder.isEmpty) {
      return text.trim();
    }
    return remainder;
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

  String _normalizeRelativeDayMisrecognition(String text) {
    if (!RegExp(
      r'(오늘|내일|오전|오후|아침|점심|저녁|밤|새벽|\d{1,2}\s*시|일정|방문|전화|연락|확인|문의|물어보|묻기|올건지|오는지|오시는지)',
    ).hasMatch(text)) {
      return text;
    }
    return text.replaceAllMapped(
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
