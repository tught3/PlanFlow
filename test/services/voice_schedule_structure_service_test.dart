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

    test('keeps person words in title and extracts participants', () {
      const rawText = '내일 오전 11시 팀장님 원주세브란스방문';

      final people = service.extractPeopleFields(rawText);
      final title = service.normalizeParsedScheduleTitle(
        '원주세브란스 방문',
        rawText: rawText,
      );

      expect(people.participants, <String>['팀장님']);
      expect(people.companions, isEmpty);
      expect(people.targets, isEmpty);
      expect(title, '팀장님 원주세브란스 방문');
    });

    test('classifies companions and targets separately', () {
      final companion = service.extractPeopleFields('내일 김대리랑 병원 방문');
      final target = service.extractPeopleFields('오늘 원장님께 보고 전화');

      expect(companion.companions, <String>['김대리']);
      expect(companion.participants, isEmpty);
      expect(target.targets, <String>['원장님']);
      expect(target.participants, isEmpty);
    });
  });
}
