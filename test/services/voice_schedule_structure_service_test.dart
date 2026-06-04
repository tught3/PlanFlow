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

    test('removes leading place from title (single source of truth: '
        'place goes to location field, not title)', () {
      const rawText = '강릉 건도리횟집에서 결제 사전기안';

      final parsedTitle = service.normalizeParsedScheduleTitle(
        '강릉 건도리횟집에서 결제 사전기안',
        rawText: rawText,
      );
      final localTitle = service.normalizeLocalVoiceTitle(
        rawText,
        referenceText: rawText,
      );

      // 장소(강릉 건도리횟집)는 location 필드로 추출되므로 제목에서 제거됨
      expect(parsedTitle, '결제 사전기안');
      expect(localTitle, '결제 사전기안');

      // 같은 장소가 location 필드에 채워지는지 확인 (제목 제거와 일치)
      final location = service.normalizeScheduleLocation(
        location: null,
        rawText: rawText,
        title: parsedTitle,
      );
      expect(location, '강릉 건도리횟집');
    });

    test('strips organization-like leading names from the title', () {
      const rawText = '우리회사에서 매월 월례 조회 메모에 주차장 B2 확인';

      final parsedTitle = service.normalizeParsedScheduleTitle(
        '우리회사 월례 조회',
        rawText: rawText,
      );
      final localTitle = service.normalizeLocalVoiceTitle(
        rawText,
        referenceText: rawText,
      );

      expect(parsedTitle, '월례 조회');
      expect(localTitle, '월례 조회');
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
  });
}
