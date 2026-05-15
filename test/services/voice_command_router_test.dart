import 'package:flutter_test/flutter_test.dart';

import 'package:planflow/services/voice_command_router.dart';
import 'package:planflow/services/voice_text_cleanup_service.dart';

void main() {
  group('VoiceCommandRouter', () {
    test('add, query, edit, delete 판정을 한 서비스에서 일관되게 만든다', () {
      const router = VoiceCommandRouter();

      final addRoute = router.route(
        '오늘 오후 3시에서 4시 사이에 팀장님한테 내일 오는 시간 확인하기',
      );
      expect(addRoute.intent, VoiceCommandRouteIntent.add);
      expect(addRoute.targetQuery, isNotEmpty);

      final queryRoute = router.route('내일 일정 확인해줘');
      expect(queryRoute.intent, VoiceCommandRouteIntent.query);
      expect(queryRoute.targetQuery, isNotEmpty);

      final todayQuery = router.route('오늘 일정 알려줘');
      expect(todayQuery.intent, VoiceCommandRouteIntent.query);

      final savedSearchQuery = router.route('저장된 일정 찾아줘');
      expect(savedSearchQuery.intent, VoiceCommandRouteIntent.query);

      final plainConfirmQuery = router.route('내일 일정 확인하기');
      expect(plainConfirmQuery.intent, VoiceCommandRouteIntent.query);

      final memoQuery = router.route('메모 보여줘');
      expect(memoQuery.intent, VoiceCommandRouteIntent.query);

      final recurringLookupAdd = router.route('매월 월례 조회');
      expect(recurringLookupAdd.intent, VoiceCommandRouteIntent.add);

      final regularLookupAdd = router.route('정기 조회');
      expect(regularLookupAdd.intent, VoiceCommandRouteIntent.add);

      final companyLookupAdd = router.route('회사 조회');
      expect(companyLookupAdd.intent, VoiceCommandRouteIntent.add);

      final memoAdd = router.route('내일 병원 준비물 메모해줘');
      expect(memoAdd.intent, VoiceCommandRouteIntent.add);

      final ambiguousQuery = router.route('조회');
      expect(ambiguousQuery.intent, VoiceCommandRouteIntent.choose);

      final scheduledAmbiguousQuery = router.route('일정 조회');
      expect(scheduledAmbiguousQuery.intent, VoiceCommandRouteIntent.choose);

      final editRoute = router.route(
        '내일 팀장님 동행방문 다음 주 수요일로 연기',
        context: VoiceTextCleanupContext.edit,
      );
      expect(editRoute.intent, VoiceCommandRouteIntent.edit);
      expect(editRoute.targetQuery, contains('팀장님'));
      expect(editRoute.targetQuery, contains('동행방문'));
      expect(editRoute.targetQuery, isNot(contains('연기')));
      expect(editRoute.requestedChanges, contains('start_at'));

      final moveRoute = router.route(
        '내일 팀장님 동행방문 다음 주 수요일로 이동',
        context: VoiceTextCleanupContext.edit,
      );
      expect(moveRoute.intent, VoiceCommandRouteIntent.edit);
      expect(moveRoute.targetQuery, contains('팀장님'));
      expect(moveRoute.targetQuery, isNot(contains('이동')));
      expect(moveRoute.requestedChanges, contains('start_at'));

      final deleteRoute = router.route(
        '오늘 아이스크림 전달 일정 삭제해 줘',
        context: VoiceTextCleanupContext.delete,
      );
      expect(deleteRoute.intent, VoiceCommandRouteIntent.delete);
      expect(deleteRoute.targetQuery, contains('아이스크림'));
      expect(deleteRoute.targetQuery, contains('전달'));
      expect(deleteRoute.targetQuery, isNot(contains('삭제')));
    });

    test('후보 힌트와 검색 토큰도 공용 라우터가 만든다', () {
      const router = VoiceCommandRouter();
      final hint = router.buildTargetEventHint(
        '내일 팀장님 동행방문 다음 주 수요일로 연기',
        const <VoiceTextCleanupCandidate>[
          VoiceTextCleanupCandidate(title: '팀장님 동행방문'),
          VoiceTextCleanupCandidate(title: '아이스크림 전달'),
        ],
        context: VoiceTextCleanupContext.edit,
      );

      expect(hint?['title'], '팀장님 동행방문');
      expect(hint?['score'], greaterThan(0));

      final tokens = router.searchTokens('오늘 아이스크림 전달 일정 삭제해 줘');
      expect(tokens, contains('아이스크림'));
      expect(tokens, contains('전달'));
      expect(tokens, isNot(contains('삭제')));
    });

    test('화면 후보 선택 표현은 전역 음성 choose intent로 라우팅하지 않는다', () {
      const router = VoiceCommandRouter();

      for (final phrase in const [
        '첫번째',
        '이걸로',
        '선택',
        '이거',
        '그걸로',
        '골라',
      ]) {
        final route = router.route(
          phrase,
          context: VoiceTextCleanupContext.edit,
        );

        expect(route.intent, isNot(VoiceCommandRouteIntent.choose));
      }
    });

    test('긴 조사 토큰은 앞부분 일치도 후보 매칭에 사용할 수 있다', () {
      const router = VoiceCommandRouter();

      expect(
        router.hasPrefixMatch('방문하여', const ['약재과', '방문', '문의']),
        isTrue,
      );
      expect(
        router.hasPrefixMatch('삭제해줘', const ['약재과', '방문', '문의']),
        isFalse,
      );
      expect(
        router.hasPrefixMatch('아', const ['약재과', '방문', '문의']),
        isFalse,
      );
    });
  });
}
