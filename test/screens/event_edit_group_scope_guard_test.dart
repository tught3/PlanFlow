import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  // 회귀: 저장 범위를 "개인 일정만"(personalOnly)으로 고른 경우엔 그룹을
  // 전혀 건드리지 않으므로 "수정 내용을 반영할 그룹" 바텀시트를 띄우면 안
  // 된다. 예전엔 _shouldSavePersonalEvent(=개인 저장 여부)만 봐서, 이미 다른
  // 그룹에 공유돼 있던 일정이면 personalOnly를 골라도 이 시트가 떴다.
  //
  // 전체 EventEditScreen을 마운트해 시트 등장 여부를 검증하려면 그룹 레포·
  // 인증·Supabase 목업 등 무거운 하네스가 필요해, 여기서는 _chooseLinked-
  // GroupsToUpdate 호출부가 personalOnly가 아닐 때만 실행되도록 게이트돼
  // 있는지 소스 구조로 고정한다(게이트를 실수로 제거하는 재발을 잡는다).
  test('반영할 그룹 시트 호출부가 personalOnly가 아닐 때로 게이트돼 있다', () {
    final source =
        File('lib/screens/event/event_edit_screen.dart').readAsStringSync();

    // 메서드 정의부가 아니라 실제 호출부(existingLinkedGroupEvents를 넘기는
    // 곳)를 특정한다.
    final callIndex =
        source.indexOf('_chooseLinkedGroupsToUpdate(existingLinkedGroupEvents');
    expect(callIndex, greaterThan(-1),
        reason: '_chooseLinkedGroupsToUpdate 호출부를 찾지 못함');

    // 호출부 바로 앞의 조건 블록에 personalOnly 제외 가드가 있어야 한다.
    // (호출 지점에서 앞쪽으로 400자 내에 조건이 있다.)
    final windowStart = (callIndex - 400).clamp(0, callIndex);
    final precedingBlock = source.substring(windowStart, callIndex);

    expect(
      precedingBlock,
      contains('ScheduleSaveTarget.personalOnly'),
      reason: '개인 일정만 저장 시 그룹 반영 시트를 건너뛰는 가드가 사라지면, '
          '개인만 수정하려는 사용자에게 불필요한 그룹 선택 시트가 다시 뜬다.',
    );
  });
}
