import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  // 회귀: 신규 atomic save 계약은 저장 직전, 링크된 그룹일정이 이미 있는
  // 상태에서 사용자가 "개인 일정만" 또는 "그룹 일정만"처럼 한쪽 범위만
  // 골라 저장(=개인 본만 갱신 / 그룹 본만 갱신 — 기존 공유본과 정면
  // 충돌)하면 즉시 차단하고 return으로 빠져야 한다. 가드를 제거하거나
  // _repository 호출 뒤로 옮기면 partial save(개인만 저장됐는데 기존
  // 그룹본이 stale 상태로 남는 사고)가 재발한다.
  //
  // 분기 로직과 helper의 두 케이스 거부는 behavioral 테스트가 검증하므로,
  // 여기서는 (1) 호출부가 4개 인자 키워드를 모두 받는지, (2) 차단 시
  // _showMessage + return으로 빠져나가는지, (3) _repository 호출보다
  // 앞에 위치하는지 — 소스 구조만으로 고정한다. 임의 400자 윈도우 대신
  // existingLinkedGroupEvents 선언부를 앵커로, 다음 EventModel? savedEvent
  // 선언을 종점으로 잡는다.
  test(
    'shouldBlockLinkedGroupSaveScope 호출부가 4인자·차단 return을 포함하고 '
    '모든 _repository 호출보다 앞에 있다',
    () {
      final source =
          File('lib/screens/event/event_edit_screen.dart').readAsStringSync();

      // existingLinkedGroupEvents 선언부를 앵커로 잡고, 그 뒤(save 메서드
      // 본문)에서만 호출부/저장 호출을 찾는다. 헬퍼 정의는 선언부 이전에
      // 있으므로 자연스럽게 제외된다.
      const anchor =
          'final existingLinkedGroupEvents = (!_isNewEvent && _loadedEvent != null)';
      final anchorIndex = source.indexOf(anchor);
      expect(anchorIndex, greaterThan(-1),
          reason: 'existingLinkedGroupEvents 선언부를 찾지 못함');
      final searchOrigin = anchorIndex + anchor.length;

      // "if (EventEditScreen.shouldBlockLinkedGroupSaveScope(" 형태만
      // 매치하므로 헬퍼 정의(static bool …)는 자동 제외.
      const guardInvocation =
          'if (EventEditScreen.shouldBlockLinkedGroupSaveScope(';
      final guardIndex = source.indexOf(guardInvocation, searchOrigin);
      expect(guardIndex, greaterThan(-1),
          reason: 'shouldBlockLinkedGroupSaveScope 호출부를 찾지 못함. 헬퍼 정의가 '
              '아닌 if 조건 안의 실제 호출부를 특정해야 한다.');

      // 호출부부터 다음 "EventModel? savedEvent;" 선언 직전까지를 윈도우로
      // 잡아 4인자·차단 return·사용자 안내를 한꺼번에 본다. recurrence 가드
      // 가 사이에 있어도 윈도우 안에 자연 포함된다.
      const savedEventDecl = 'EventModel? savedEvent;';
      final savedEventIndex = source.indexOf(savedEventDecl, guardIndex);
      expect(savedEventIndex, greaterThan(-1),
          reason: 'guard 호출부 뒤에 EventModel? savedEvent 선언이 없음');
      // Bound this assertion to the scope guard itself, not the later recurrence guard.
      final guardEnd = source.indexOf('\n      }', guardIndex);
      expect(guardEnd, greaterThan(guardIndex));
      expect(guardEnd, lessThan(savedEventIndex));
      final guardWindow = source.substring(guardIndex, guardEnd);

      expect(
          guardWindow,
          contains(
              'hasLinkedGroupCopies: existingLinkedGroupEvents.isNotEmpty'),
          reason: 'hasLinkedGroupCopies 인자가 빠짐');
      expect(guardWindow, contains('hasGroupEventId: hasGroupEventId'),
          reason: 'hasGroupEventId 인자가 빠짐');
      expect(guardWindow,
          contains('shouldSavePersonalEvent: _shouldSavePersonalEvent'),
          reason: 'shouldSavePersonalEvent 인자가 빠짐');
      expect(
          guardWindow, contains('shouldSaveGroupEvent: _shouldSaveGroupEvent'),
          reason: 'shouldSaveGroupEvent 인자가 빠짐');
      expect(guardWindow, contains('return;'),
          reason: '차단 시 return;으로 빠져야 함 (없으면 partial save)');
      expect(guardWindow, contains('_showMessage'),
          reason: '차단 시 사용자에게 안내를 띄워야 함');

      // 가드는 두 _repository 호출보다 무조건 앞에 와야 한다. 하나라도 뒤에
      // 있으면 가드가 무의미해진다. _repository.updateEventWithGroupShares(
      // 가 _repository.updateEvent( 의 접두사를 공유하므로, "With"로 이어지
      // 는 호출은 건너뛰고 진짜 updateEvent( 만 잡는다.
      final withSharesIndex = source.indexOf(
          '_repository.updateEventWithGroupShares(', searchOrigin);
      expect(withSharesIndex, greaterThan(-1),
          reason: '_repository.updateEventWithGroupShares 호출을 찾지 못함 (atomic '
              'save 경로가 사라졌거나 이름이 바뀜)');

      final updateEventIndex =
          source.indexOf('_repository.updateEvent(', searchOrigin);
      expect(updateEventIndex, greaterThan(-1),
          reason: '_repository.updateEvent 호출을 찾지 못음');

      expect(guardIndex, lessThan(withSharesIndex),
          reason: '가드가 updateEventWithGroupShares보다 뒤에 있어 partial save 가능');
      expect(guardIndex, lessThan(updateEventIndex),
          reason: '가드가 updateEvent보다 뒤에 있어 partial save 가능');
    },
  );
}
