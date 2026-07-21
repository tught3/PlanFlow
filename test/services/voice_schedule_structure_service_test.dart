import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/services/voice_schedule_structure_service.dart';

void main() {
  group('VoiceScheduleStructureService', () {
    const service = VoiceScheduleStructureService();

    test('separates leading schedule time from follow-up call content', () {
      final result = service.analyze('오늘 4시에 팀장님 내일 오시는지 확인전화하기');

      expect(result.leadingTimeCue, '오늘 4시에');
      expect(result.contentText, '팀장님 내일 오시는지 확인전화하기');
      expect(result.titleCandidate, '팀장님 내일 오시는지 확인전화하기');
      expect(result.startAtCandidate, '오늘 4시에');
    });

    test('keeps later relative-day wording after an earlier cue', () {
      final result = service.analyze('오늘 오후 2시에 내일팀장님 동행방문하시는지 확인전화하기');

      expect(result.leadingTimeCue, '오늘 오후 2시에');
      expect(result.titleCandidate, '내일팀장님 동행방문하시는지 확인전화하기');
    });

    test('keeps ordinary words like 요미 while removing only schedule noise', () {
      const rawText = '오후3시에 요미 약받기';
      final structure = service.analyze(rawText);

      final localTitle = service.normalizeLocalVoiceTitle(
        rawText,
        referenceText: rawText,
        structured: structure,
      );
      final parsedTitle = service.normalizeParsedScheduleTitle(
        '요미 약받기',
        rawText: rawText,
        structured: structure,
      );

      expect(localTitle, '요미 약받기');
      expect(parsedTitle, '요미 약받기');
    });

    test('extracts explicit memo from content after the leading cue', () {
      final result = service.analyze('내일 오전 10시에 병원 방문 메모에 주차장 확인');

      expect(result.leadingTimeCue, '내일 오전 10시에');
      expect(result.titleCandidate, '병원 방문');
      expect(result.explicitFieldClauses['memo'], '주차장 확인');
    });

    test('keeps recurrence expressions discoverable after the leading cue', () {
      final result = service.analyze('오늘 4시에 매주 팀장님 확인전화');

      expect(result.leadingTimeCue, '오늘 4시에');
      expect(result.titleCandidate, '매주 팀장님 확인전화');
      expect(result.explicitFieldClauses['recurrence_rule'], '매주');
    });

    test('removes recurrence command words from title without dropping object',
        () {
      const rawText = '매주 월요일 오전 7시에 태블릿 계기판찍기 반복설정';
      final structure = service.analyze(rawText);
      final title = service.normalizeLocalVoiceTitle(
        rawText,
        referenceText: rawText,
        structured: structure,
      );

      expect(title, '태블릿 계기판 찍기');
      expect(structure.explicitFieldClauses['recurrence_rule'], '매주');
    });

    test('removes trailing repeat word from monthly recurrence title', () {
      const rawText = '매월 1일 톨비 작성 반복';
      final structure = service.analyze(rawText);

      final localTitle = service.normalizeLocalVoiceTitle(
        rawText,
        referenceText: rawText,
        structured: structure,
      );
      final parsedTitle = service.normalizeParsedScheduleTitle(
        '톨비 작성 반복',
        rawText: rawText,
        structured: structure,
      );

      expect(localTitle, '톨비 작성');
      expect(parsedTitle, '톨비 작성');
      expect(structure.explicitFieldClauses['recurrence_rule'], '매월');
    });

    test('keeps day-only date cues as this month or next month when needed', () {
      final currentMonth = service.extractDateRange(
        '28일 계룡으로 엄마 만나러 가기',
        now: DateTime(2026, 6, 10, 12),
      );
      final nextMonth = service.extractDateRange(
        '28일 계룡으로 엄마 만나러 가기',
        now: DateTime(2026, 6, 29, 12),
      );

      expect(currentMonth, isNotNull);
      expect(currentMonth!.startAt, DateTime(2026, 6, 28));
      expect(currentMonth.endAt, DateTime(2026, 6, 28, 23, 59, 59));

      expect(nextMonth, isNotNull);
      expect(nextMonth!.startAt, DateTime(2026, 7, 28));
      expect(nextMonth.endAt, DateTime(2026, 7, 28, 23, 59, 59));
    });

    test('removes ordinal monthly recurrence phrase from the title', () {
      const rawText = '매월 첫 번째 월요일 법인카드 정리 반복';
      final structure = service.analyze(rawText);

      final localTitle = service.normalizeLocalVoiceTitle(
        rawText,
        referenceText: rawText,
        structured: structure,
      );
      final parsedTitle = service.normalizeParsedScheduleTitle(
        '매월 첫 번째 월요일 법인카드 정리 반복',
        rawText: rawText,
        structured: structure,
      );

      expect(localTitle, '법인카드 정리');
      expect(parsedTitle, '법인카드 정리');
      expect(structure.explicitFieldClauses['recurrence_rule'], '매월');
    });

    test('keeps person words in title and extracts participants', () {
      const rawText = '내일 오전 11시 팀장님 원주세브란스방문';

      final people = service.extractPeopleFields(rawText);
      final title = service.normalizeParsedScheduleTitle(
        '원주세브란스 방문',
        rawText: rawText,
      );

      expect(people.participants, <String>['팀장님']);
      expect(people.targets, isEmpty);
      expect(title, '팀장님 원주세브란스 방문');
    });

    test('keeps 함께 가는 사람 in participants and separates targets', () {
      final participants = service.extractPeopleFields('내일 김대리랑 병원 방문');
      final target = service.extractPeopleFields('오늘 원장님께 보고 전화');

      expect(participants.participants, <String>['김대리']);
      expect(target.targets, <String>['원장님']);
      expect(target.participants, isEmpty);
    });

    test('extracts name-like action recipients without hardcoding names', () {
      const rawText = '내일 오후3시에 경탁이 전화해서 모래 강릉아산병원 혼자 올건지 물어보기';

      final people = service.extractPeopleFields(rawText);
      final title = service.normalizeParsedScheduleTitle(
        '강릉아산병원 혼자 올건지 물어보기',
        rawText: rawText,
      );

      expect(people.targets, <String>['경탁이']);
      expect(people.participants, isEmpty);
      expect(title, contains('경탁이'));
      expect(title, contains('모레'));
      expect(title, isNot(contains('모래')));
    });

    test('restores name when title only kept PM recipient marker', () {
      final title = service.normalizeParsedScheduleTitle(
        '피엠한테 날짜 괜찮냐고 물어보기',
        rawText: '김태형pm한테 날짜 괜찮냐고 물어보기',
      );

      expect(title, '김태형 PM한테 날짜 괜찮냐고 물어보기');
    });

    test('keeps plain person names in the title when raw text lost them', () {
      const rawText = '7월 17일 김창민 만나기';

      final parsedTitle = service.normalizeParsedScheduleTitle(
        '만나기',
        rawText: rawText,
      );
      final localTitle = service.normalizeLocalVoiceTitle(
        rawText,
        referenceText: rawText,
      );
      final people = service.extractPeopleFields(rawText);

      expect(parsedTitle, '김창민 만나기');
      expect(localTitle, '김창민 만나기');
      expect(people.participants, contains('김창민'));
    });

    test('keeps leading place in title AND fills location field', () {
      const rawText = '강릉 건도리횟집에서 결제 사전기안';

      final parsedTitle = service.normalizeParsedScheduleTitle(
        '강릉 건도리횟집에서 결제 사전기안',
        rawText: rawText,
      );
      final localTitle = service.normalizeLocalVoiceTitle(
        rawText,
        referenceText: rawText,
      );

      // 장소는 제목에도 그대로 유지
      expect(parsedTitle, '강릉 건도리횟집 결제 사전기안');
      expect(localTitle, '강릉 건도리횟집 결제 사전기안');

      // 동시에 location 필드에도 채워지는지 확인
      final location = service.normalizeScheduleLocation(
        location: null,
        rawText: rawText,
        title: parsedTitle,
      );
      expect(location, '강릉 건도리횟집');
    });

    test('does not include date in location (map coords)', () {
      const rawText = '7월1일 원주세브란스기독병원에서 장재균 그룹장님 동행방문';

      final location = service.normalizeScheduleLocation(
        location: null,
        rawText: rawText,
        title: rawText,
      );
      // 날짜(7월1일)가 장소에 포함되면 안 됨
      expect(location, '원주세브란스기독병원');

      // 제목에서도 날짜 제거 확인
      final title = service.normalizeParsedScheduleTitle(
        rawText,
        rawText: rawText,
      );
      expect(title.contains('7월'), isFalse);
      expect(title.contains('1일'), isFalse);
    });

    test('extracts location after a person name (drops person/title prefix)',
        () {
      const rawText = '장재균 그룹장님 원주 세브란스 기독병원에 와서 백순구 의료원장님 만남';

      // 사람 이름/직급(장재균 그룹장님)을 제외하고 장소만 추출
      expect(service.extractLeadingLocation(rawText), '원주 세브란스 기독병원');
      expect(service.extractMidLocation(rawText), '원주 세브란스 기독병원');

      final location = service.normalizeScheduleLocation(
        location: null,
        rawText: rawText,
        title: rawText,
      );
      expect(location, '원주 세브란스 기독병원');
    });

    // [PREVENT] "모란역으로"가 greedy 매칭으로 "모란역으"+"로"로 잘려, 장소·제목·
    // 지도 검색이 모두 "모란역으"로 깨지던 버그. "으로" 조사를 온전히 떼야 한다.
    test('extractLeadingLocation은 "으로" 조사를 온전히 떼어 장소를 추출한다', () {
      expect(service.extractLeadingLocation('모란역으로 가기'), '모란역');
      expect(service.extractLeadingLocation('강남역으로 가기'), '강남역');
      // 기존 조사("에서", "에")도 그대로 동작해야 한다.
      expect(service.extractLeadingLocation('모란역에서 만남'), '모란역');
      expect(service.extractLeadingLocation('병원에 가기'), '병원');
      // 제목에도 "모란역으"가 남지 않는다.
      final title = service.normalizeParsedScheduleTitle(
        '모란역으로 가기',
        rawText: '모란역으로 가기',
      );
      expect(title, isNot(contains('모란역으 ')));
    });

    test('keeps organization-like leading names in the title', () {
      const rawText = '우리회사에서 매월 월례 조회 메모에 주차장 B2 확인';

      final parsedTitle = service.normalizeParsedScheduleTitle(
        '우리회사 월례 조회',
        rawText: rawText,
      );
      final localTitle = service.normalizeLocalVoiceTitle(
        rawText,
        referenceText: rawText,
      );

      expect(parsedTitle, '우리회사 월례 조회');
      expect(localTitle, '우리회사 월례 조회');
    });

    test('strips trailing "일정 생성해줘" command phrase from the title', () {
      const rawText = '오늘 오후 9시에 모란역으로 가기 일정 생성해줘';

      final parsedTitle = service.normalizeParsedScheduleTitle(
        '모란역 가기 일정 생성해줘',
        rawText: rawText,
      );

      expect(parsedTitle, '모란역 가기');
    });

    test('classifies name-like particles into target and participants', () {
      final target = service.extractPeopleFields('민수한테 확인 전화');
      final participant = service.extractPeopleFields('수연이랑 병원 방문');

      expect(target.targets, <String>['민수']);
      expect(target.participants, isEmpty);
      expect(participant.participants, <String>['수연']);
      expect(participant.targets, isEmpty);
    });

    test('does not classify place and work words as people', () {
      final place = service.extractPeopleFields('내일 강릉아산병원 방문');
      final project = service.extractPeopleFields('프로젝트와 회의');
      final workCall = service.extractPeopleFields('업무 전화');
      final document = service.extractPeopleFields('문서 확인');

      expect(place.participants, isEmpty);
      expect(place.targets, isEmpty);
      expect(project.participants, isEmpty);
      expect(project.targets, isEmpty);
      expect(workCall.participants, isEmpty);
      expect(workCall.targets, isEmpty);
      expect(document.participants, isEmpty);
      expect(document.targets, isEmpty);
    });

    test('extracts all-day multi-day date ranges and strips title noise', () {
      final range = service.extractDateRange(
        '5월 26일부터 6월 1일까지 원주집 임대',
        now: DateTime(2026, 5, 23, 12),
      );

      expect(range, isNotNull);
      expect(range!.startAt, DateTime(2026, 5, 26));
      expect(range.endAt, DateTime(2026, 6, 1, 23, 59, 59));
      expect(range.isAllDay, isTrue);
      expect(range.isMultiDay, isTrue);
      expect(
        service.stripDateRangeExpression(
          '5월 26일부터 6월 1일까지 원주집 임대',
          now: DateTime(2026, 5, 23, 12),
        ),
        '원주집 임대',
      );
      expect(
        service.stripDateRangeExpression(
          '부터 까지 원주집 임대',
          now: DateTime(2026, 5, 23, 12),
        ),
        '원주집 임대',
      );
    });

    test('extracts relative duration ranges and strips title noise', () {
      final range = service.extractDateRange(
        '오늘부터 2주간 원주집 단기렌트하기',
        now: DateTime(2026, 6, 7, 12),
      );

      expect(range, isNotNull);
      expect(range!.startAt, DateTime(2026, 6, 7));
      expect(range.endAt, DateTime(2026, 6, 20, 23, 59, 59));
      expect(range.isAllDay, isTrue);
      expect(range.isMultiDay, isTrue);
      expect(
        service.stripDateRangeExpression(
          '오늘부터 2주간 원주집 단기렌트하기',
          now: DateTime(2026, 6, 7, 12),
        ),
        '원주집 단기렌트하기',
      );
    });

    test('clamps month duration ranges at the target month end', () {
      final range = service.extractDateRange(
        '오늘부터 1개월간 원주집 단기렌트하기',
        now: DateTime(2026, 1, 31, 12),
      );

      expect(range, isNotNull);
      expect(range!.startAt, DateTime(2026, 1, 31));
      expect(range.endAt, DateTime(2026, 2, 28, 23, 59, 59));
      expect(range.isAllDay, isTrue);
      expect(range.isMultiDay, isTrue);
    });

    test('does not treat same-day time ranges as all-day date ranges', () {
      final range = service.extractDateRange(
        '5월 26일 오전 9시부터 오후 3시까지 회의',
        now: DateTime(2026, 5, 23, 12),
      );

      expect(range, isNull);
    });

    test('keeps 경조사 and rejects time words as locations', () {
      final structure = service.analyze('내일 오전에 경조사 신청 4만원 하기');
      final title = service.normalizeLocalVoiceTitle(
        '내일 오전에 경조사 신청 4만원 하기',
        referenceText: '내일 오전에 경조사 신청 4만원 하기',
        structured: structure,
      );

      expect(title, '경조사 신청 4만원 하기');
      expect(
        service.normalizeScheduleLocation(
          location: '오전',
          rawText: '내일 오전에 경조사 신청 4만원 하기',
          title: title,
        ),
        isNull,
      );
      expect(
        service.extractLeadingLocation('오전에 경조사 신청 4만원 하기'),
        isNull,
      );
      expect(
        service.shouldPreferStructuredTitle(
          normalizedTitle: '조사 신청 4만원 하기',
          structuredTitle: '경조사 신청 4만원 하기',
          structure: structure,
        ),
        isTrue,
      );
    });

    test('normalizes noisy location text by removing time words', () {
      const rawText = '오늘 오후 5시 판교 대장동 해링턴플레이스 방문';

      final location = service.normalizeScheduleLocation(
        location: '오후 5시 판교 대장동 해링턴플레이스',
        rawText: rawText,
        title: '방문',
      );

      expect(location, '대장동 해링턴플레이스');
    });

    test('drops standalone particle left after location extraction (에서)', () {
      const rawText = '내일 오전 11시에 모란역에서 만남';
      final structure = service.analyze(rawText);

      // GPT/로컬이 장소 '모란역'을 떼고 조사 '에서'만 남긴 경우.
      final parsedTitle = service.normalizeParsedScheduleTitle(
        '에서 만남',
        rawText: rawText,
        structured: structure,
      );

      expect(parsedTitle.split(RegExp(r'\s+')), isNot(contains('에서')),
          reason: '단독 조사 "에서"는 제목 토큰으로 남으면 안 된다');
      expect(parsedTitle, contains('만남'));
    });

    test('keeps noun+particle compound (병원에서) as a single title token', () {
      // 명사와 결합된 조사는 단독 조사가 아니므로 그대로 유지.
      final title = service.ensurePeopleInTitle('병원에서', '병원에서 회의');
      expect(title, '병원에서');
    });

    test('strips only the standalone particle, keeps the rest', () {
      // 처소격 단독 토큰만 제거, 일반 단어는 보존.
      expect(service.ensurePeopleInTitle('에 회의', '회의'), '회의');
      expect(service.ensurePeopleInTitle('회의 준비', '회의 준비'), '회의 준비');
    });

    test('extracts trailing residential location (성원아파트에서)', () {
      final location = service.normalizeScheduleLocation(
        location: null,
        rawText: '엄마 만나러 가기 성원아파트에서',
        title: '엄마 만나러 가기',
      );
      expect(location, isNotNull);
      expect(location, contains('성원아파트'));
    });

    // ── 회귀 테스트: 시간 고아조사 제거 (GPT 경로) ──────────────────────────
    // 버그: "3분뒤에 확인 메세지출력 저장" → GPT 정리 후 제목에 "뒤에"가 남는 현상.
    // 두 경로(normalizeParsedScheduleTitle / normalizeLocalVoiceTitle) 모두 검증.
    test(
      'normalizeParsedScheduleTitle strips orphan time particle "뒤에" from GPT title',
      () {
        const rawText = '3분뒤에 확인 메세지출력 저장';
        // GPT 경로: GPT가 시간 파싱 후 "뒤에 확인 메시지 출력"처럼 반환한다고 가정.
        final parsedTitle = service.normalizeParsedScheduleTitle(
          '뒤에 확인 메시지 출력',
          rawText: rawText,
        );
        expect(parsedTitle, isNot(contains('뒤에')));
        expect(parsedTitle, contains('확인'));
      },
    );

    // 버그: rawText 자체가 "뒤에…"로 시작하면 extractPeopleFields가 "뒤에"를
    // 사람으로 오인 추출해, _stripOrphanTimeParticles로 제거한 "뒤에"를
    // ensurePeopleInTitle 마지막에 사람 이름으로 제목 앞에 다시 붙이던 현상.
    test(
      'ensurePeopleInTitle이 사람으로 오인된 시간조사("뒤에")를 제목에 복원하지 않는다',
      () {
        const text = '뒤에 확인 메세지 출력';
        final parsed = service.normalizeParsedScheduleTitle(text, rawText: text);
        expect(parsed, isNot(contains('뒤에')));
        expect(parsed, contains('확인'));
        // 진짜 사람 이름은 보존돼야 한다.
        expect(
          service.normalizeParsedScheduleTitle(
            '엄마 만나러 가기',
            rawText: '엄마 만나러 가기',
          ),
          contains('엄마'),
        );
      },
    );

    test(
      'normalizeLocalVoiceTitle strips orphan time particle "뒤에" from local title',
      () {
        const rawText = '3분뒤에 확인 메세지출력 저장';
        final localTitle = service.normalizeLocalVoiceTitle(
          rawText,
          referenceText: rawText,
        );
        expect(localTitle, isNot(contains('뒤에')));
        expect(localTitle, contains('확인'));
      },
    );

    test(
      'does NOT strip "뒤풀이" — ordinary word containing "뒤" must be preserved',
      () {
        const rawText = '뒤풀이 모임 저장';
        final parsedTitle = service.normalizeParsedScheduleTitle(
          '뒤풀이 모임',
          rawText: rawText,
        );
        expect(parsedTitle, contains('뒤풀이'));
      },
    );

    test(
      'strips orphan "후에" from GPT title (e.g. "1시간 후에 전화" → "전화")',
      () {
        // GPT가 "1시간 후에"를 날짜로 처리한 뒤 "후에 전화"를 반환하는 경우.
        // normalizeParsedScheduleTitle은 내부 경로(structuredTitle 선택 등)에 따라
        // 결과가 달라질 수 있으므로, 공통 출구인 ensurePeopleInTitle 직전에 실제로
        // stripOrphanTimeParticles가 작동하는지 확인하기 위해 rawText와 title을
        // "후에"가 단독 토큰으로만 남는 형태로 설정한다.
        const rawText = '5분 후에 물 마시기 저장';
        final parsedTitle = service.normalizeParsedScheduleTitle(
          '후에 물 마시기',
          rawText: rawText,
        );
        expect(parsedTitle, isNot(contains('후에')));
        expect(parsedTitle, contains('물 마시기'));
      },
    );

    // ── 회귀 테스트: "중요한일정으로 저장" 류 명령문구가 장소로 오인되는 버그 ──
    // (2026-07-17) "매주 목요일 오후 3시 태블릿계기판 중요한일정으로 저장"에서
    // stripScheduleNoise가 "중요한일정으로 저장"을 못 지워 extractLeadingLocation이
    // "태블릿계기판 중요한일정"을 장소로 잘못 채우던 버그.
    test(
      'normalizeScheduleLocation은 "중요한일정으로 저장" 발화에서 장소를 채우지 않는다',
      () {
        const rawText = '매주 목요일 오후 3시 태블릿계기판 중요한일정으로 저장';

        final location = service.normalizeScheduleLocation(
          location: null,
          rawText: rawText,
          title: '태블릿계기판',
        );
        expect(location, isNull);

        // 제목은 "태블릿계기판"만 남아야 한다(명령문구 제거, 일반명사는 보존).
        final title = service.normalizeParsedScheduleTitle(
          rawText,
          rawText: rawText,
        );
        expect(title, '태블릿계기판');
      },
    );

    test(
      '"중요" 단독/조사 변형도 stripScheduleNoise가 뒤쪽 명령문구로 제거한다',
      () {
        expect(
          service.stripScheduleNoise('태블릿계기판 중요일정으로 저장'),
          '태블릿계기판',
        );
        expect(
          service.stripScheduleNoise('회의자료 일정으로 기록'),
          '회의자료',
        );
        expect(
          service.stripScheduleNoise('법인카드 정리 일정 저장해줘'),
          '법인카드 정리',
        );
      },
    );

    // ── 회귀 금지선: 기존 장소 추출 동작은 그대로 유지돼야 한다 ──
    test('회귀 금지선: 모란역/원주세브란스병원/스타벅스 장소 추출은 그대로 유지된다', () {
      expect(service.extractLeadingLocation('모란역으로 가기'), '모란역');
      expect(
        service.extractLeadingLocation('원주세브란스병원에서 회의'),
        '원주세브란스병원',
      );
      // 명령어 토큰이 없는 일반 장소는 그대로 유지돼야 한다.
      expect(
        service.extractLeadingLocation('스타벅스에서 만나기'),
        '스타벅스',
      );
    });

    test('_isInvalidLocationCandidate는 명령/메타 토큰이 섞인 후보만 거부한다', () {
      // 명령/메타 토큰이 섞인 후보(간접 확인: normalizeScheduleLocation 경유)는
      // extractLeadingLocation에서 걸러져 null이 돼야 한다.
      expect(
        service.extractLeadingLocation('태블릿계기판 중요한일정으로 저장'),
        isNull,
      );
      // 순수 장소 후보는 그대로 통과해야 한다.
      expect(service.extractLeadingLocation('모란역으로 가기'), '모란역');
    });

    test('명령 동사가 장소명 안에 파묻힌 실제 장소는 거부하지 않는다(오탐 방지)', () {
      // 회귀: 명령 토큰을 부분문자열(contains)로 검사하면 실제 장소명이
      // 통째로 거부된다 — "국가기록원"은 '기록', "추가정형외과"는 '추가'에
      // 걸린다. 단독 명령 동사는 공백 분리 토큰 단위로만 판정해야 한다.
      expect(service.extractLeadingLocation('국가기록원에서 회의'), '국가기록원');
      expect(service.extractLeadingLocation('추가정형외과에서 진료'), '추가정형외과');
      // 반면 명령어가 독립 토큰으로 오면 여전히 거부돼야 한다.
      expect(service.extractLeadingLocation('태블릿계기판 저장으로 해줘'), isNull);
    });

    test('hasLocalPlaceEvidence는 장소 접미사/지역명 유무로 판정한다', () {
      expect(service.hasLocalPlaceEvidence('모란역'), isTrue);
      expect(service.hasLocalPlaceEvidence('원주세브란스병원'), isTrue);
      expect(service.hasLocalPlaceEvidence('강남'), isTrue);
      expect(service.hasLocalPlaceEvidence('태블릿계기판'), isFalse);
      expect(service.hasLocalPlaceEvidence('중요한일정'), isFalse);
      expect(service.hasLocalPlaceEvidence(''), isFalse);
    });

    // ── 회귀 테스트(HIGH#2, 2026-07-17): "일정" 단독 토큰으로 끝나는 후보 거부 ──
    // 실측 재현: stripScheduleNoise의 뒤쪽 명령문구 정규식이 "일정에 저장해놔"류
    // (particle "에"가 정규식의 허용 조사 목록에 없음)와 "일정으로 저장해놓을게"/
    // "일정으로 저장 좀 해줘요"류(공손 어미가 닫힌 목록에 없음)를 못 지워, 후보
    // "태블릿계기판 일정"이 장소로 잘못 채워지던 버그.
    test('"일정" 단독 토큰으로 끝나는 장소 후보는 거부된다(HIGH#2)', () {
      expect(
        service.normalizeScheduleLocation(
          location: null,
          rawText: '매주 목요일 오후 3시 태블릿계기판 일정에 저장해놔',
          title: '태블릿계기판',
        ),
        isNull,
      );
      expect(
        service.normalizeScheduleLocation(
          location: null,
          rawText: '매주 목요일 오후 3시 태블릿계기판 일정으로 저장해놓을게',
          title: '태블릿계기판',
        ),
        isNull,
      );
      expect(
        service.normalizeScheduleLocation(
          location: null,
          rawText: '매주 목요일 오후 3시 태블릿계기판 일정으로 저장 좀 해줘요',
          title: '태블릿계기판',
        ),
        isNull,
      );
    });

    // ── HIGH#2 동반 검증: 일반화된 stripScheduleNoise 뒤쪽 명령문구 어미가
    // 닫힌 목록에 없던 공손어미/구어체까지 제거하는지 직접 확인 ──
    test('stripScheduleNoise는 닫힌 목록에 없는 공손어미도 뒤쪽 명령문구로 제거한다', () {
      expect(
        service.stripScheduleNoise('태블릿계기판 일정으로 저장해놓을게'),
        '태블릿계기판',
      );
      expect(
        service.stripScheduleNoise('태블릿계기판 일정으로 저장 좀 해줘요'),
        '태블릿계기판',
      );
    });

    // ── 회귀 금지선: HIGH#2 수정 후에도 기존 장소 추출 동작은 그대로 유지된다 ──
    test('회귀 금지선(HIGH#2 이후): 모란역/원주세브란스병원/스타벅스/국가기록원/추가정형외과/'
        '태블릿계기판 중요한일정 동작은 그대로 유지된다', () {
      expect(service.extractLeadingLocation('모란역으로 가기'), '모란역');
      expect(
        service.extractLeadingLocation('원주세브란스병원에서 회의'),
        '원주세브란스병원',
      );
      expect(service.extractLeadingLocation('스타벅스에서 만나기'), '스타벅스');
      expect(service.extractLeadingLocation('국가기록원에서 회의'), '국가기록원');
      expect(service.extractLeadingLocation('추가정형외과에서 진료'), '추가정형외과');
      expect(
        service.normalizeScheduleLocation(
          location: null,
          rawText: '매주 목요일 오후 3시 태블릿계기판 중요한일정으로 저장',
          title: '태블릿계기판',
        ),
        isNull,
      );
    });

    // ── 신규(2026-07-21 리뷰 반영): 장소-후행 제목 재배치 휴리스틱 제거 ──
    // 과거 _relocateTrailingLocationToFront가 제목의 "마지막 토큰 1개"만
    // 재배치해 다단어 장소를 찢거나(HIGH#1), 1글자 장소 키워드("역"/"항")가
    // 일반 명사에 우연히 붙어 오탐하는 문제(HIGH#2)가 있어 함수를 통째로
    // 제거했다. 실제 어순 교정은 GPT 프롬프트("장소는 제목 맨 앞")가
    // 담당하고, 로컬 휴리스틱은 조사 없는 장소-후행 문구를 건드리지 않는다
    // (아래 회귀 금지선 테스트에서 원문 유지를 확인한다).
    test('이미 장소가 문두에 있는 제목은 중복 재배치하지 않는다', () {
      // 조사 없이 문두와 말미에 동일 장소가 겹치는 경우: 문두 토큰이 후보와
      // 같으면 다시 앞에 붙이지 않는다(중복 방지).
      expect(
        service.preserveLeadingLocationTitle(
          '원주세브란스병원 회의 원주세브란스병원',
        ),
        '원주세브란스병원 회의 원주세브란스병원',
      );
      // 마지막 토큰이 이벤트 명사라 애초에 재배치 대상이 되지 않는 경우도
      // 그대로 유지된다.
      expect(
        service.preserveLeadingLocationTitle('원주세브란스병원 회의'),
        '원주세브란스병원 회의',
      );
    });

    test('명령어 토큰이 장소로 오인되어 문두로 끌려오지 않는다', () {
      // 마지막 토큰이 명령 동사(_scheduleCommandTokens)면 재배치 자체를
      // 하지 않는다 — "저장"이 장소로 오인되어 앞으로 끌려오면 안 된다.
      expect(
        service.preserveLeadingLocationTitle('태블릿계기판 중요한일정으로 저장'),
        '태블릿계기판 중요한일정으로 저장',
      );
    });

    test('사람 직급 바로 뒤 장소는 사람보다 앞으로 밀리지 않는다', () {
      // 후보 앞 토큰이 사람 직급/호칭이면 재배치를 하지 않아, 장소가 사람
      // 언급을 추월하는 순서가 되는 것을 방지한다.
      expect(
        service.preserveLeadingLocationTitle('회의 팀장님 원주세브란스병원'),
        '회의 팀장님 원주세브란스병원',
      );
    });

    // ── 회귀 금지선: 사람/장소 prepend 충돌 방지 확인 ──
    test('회귀 금지선: 사람 이름이 뒤에 있는 장소-후행 발화 형태에서도 기존 순서가 유지된다', () {
      const rawText = '내일 오전 11시 팀장님 원주세브란스방문';
      final title = service.normalizeParsedScheduleTitle(
        '원주세브란스 방문',
        rawText: rawText,
      );
      expect(title, '팀장님 원주세브란스 방문');
    });

    // ── BLOCKER 회귀 테스트(2026-07-21): stripLeadingLocationPhrase의
    // 그리디 매칭이 "일정으로"를 "일정으"+"로"로 쪼개 _containsScheduleCommandToken의
    // "words.last == '일정'" 가드가 매치 실패하던 문제. 제목 내용이 유실되지
    // 않아야 한다(실측: 수정 전 '태블릿계기판 일정으로 잡아줘' -> '잡아줘').
    test('BLOCKER: stripLeadingLocationPhrase는 "일정으로/알림으로" 명령문구에서 제목을 유실하지 않는다', () {
      expect(
        service.stripLeadingLocationPhrase('태블릿계기판 일정으로 잡아줘'),
        '태블릿계기판 일정으로 잡아줘',
      );
      expect(
        service.stripLeadingLocationPhrase('태블릿계기판 알림으로 등록해줘'),
        '태블릿계기판 알림으로 등록해줘',
      );
      expect(
        service.stripLeadingLocationPhrase('태블릿계기판 중요한일정으로 저장'),
        '태블릿계기판 중요한일정으로 저장',
      );
      expect(
        service.stripLeadingLocationPhrase('태블릿계기판 일정에 저장해놔'),
        '태블릿계기판 일정에 저장해놔',
      );
    });

    test('BLOCKER: normalizeLocalVoiceTitle은 "일정으로/알림으로" 명령문구에서 제목 내용을 유실하지 않는다', () {
      expect(
        service.normalizeLocalVoiceTitle(
          '태블릿계기판 일정으로 잡아줘',
          referenceText: '태블릿계기판 일정으로 잡아줘',
        ),
        contains('태블릿계기판'),
      );
      expect(
        service.normalizeLocalVoiceTitle(
          '태블릿계기판 알림으로 등록해줘',
          referenceText: '태블릿계기판 알림으로 등록해줘',
        ),
        contains('태블릿계기판'),
      );
      expect(
        service.normalizeLocalVoiceTitle(
          '태블릿계기판 중요한일정으로 저장',
          referenceText: '태블릿계기판 중요한일정으로 저장',
        ),
        contains('태블릿계기판'),
      );
      expect(
        service.normalizeLocalVoiceTitle(
          '태블릿계기판 일정에 저장해놔',
          referenceText: '태블릿계기판 일정에 저장해놔',
        ),
        contains('태블릿계기판'),
      );
    });

    // ── HIGH#1/HIGH#2 오탐 회귀 테스트(2026-07-21): 제거된
    // _relocateTrailingLocationToFront가 다단어 장소를 찢거나(HIGH#1) 1글자
    // 장소 키워드("역"/"항")가 일반 명사에 우연히 걸리던(HIGH#2) 문제.
    // 함수 제거 후에는 아래 문구들이 변형 없이 원문 그대로 유지돼야 한다.
    test('HIGH 오탐 회귀: 일반 명사/다단어 장소 문구가 재배치로 변형되지 않는다', () {
      expect(
        service.preserveLeadingLocationTitle('회의 전 확인사항'),
        '회의 전 확인사항',
      );
      expect(
        service.preserveLeadingLocationTitle('내년도 예산 편성 지역'),
        '내년도 예산 편성 지역',
      );
      expect(
        service.preserveLeadingLocationTitle('회의 원주 세브란스 병원'),
        '회의 원주 세브란스 병원',
      );
      // GPT 제목 경로(normalizeParsedScheduleTitle)로도 동일하게 원문이
      // 유지돼야 한다(오탐 재현 경로가 로컬/GPT 양쪽에 있었음).
      expect(
        service.normalizeParsedScheduleTitle(
          '회의 전 확인사항',
          rawText: '회의 전 확인사항',
        ),
        contains('확인사항'),
      );
    });
  });
}
