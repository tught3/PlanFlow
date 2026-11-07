import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/screens/settings/settings_screen.dart';

void main() {
  const existingMessage = '가져온 일정을 PlanFlow에 남겨둘지, 해당 공급자 일정과 함께 정리할지 선택해 주세요.';
  const naverMessage = '가져온 일정을 PlanFlow에 남겨둘지, 해당 공급자 일정과 함께 정리할지 선택해 주세요.\n\n'
      'ICS 파일로 직접 가져온 일정은 어느 쪽을 골라도 삭제되지 않고 PlanFlow에 남아요.\n'
      '네이버 CalDAV 일정 중 강한 알림, 참석자, 그룹, 중요 표시 등이 있는 일정은 삭제를 골라도 남을 수 있어요.';

  test('keeps the existing disconnect policy message when ICS is not mentioned',
      () {
    expect(
      disconnectPolicyMessage(mentionsIcsKept: false),
      existingMessage,
    );
  });

  test('adds the ICS preservation message when it is mentioned', () {
    expect(
      disconnectPolicyMessage(mentionsIcsKept: true),
      naverMessage,
    );
  });

  test('keeps the existing message as the prefix when ICS is mentioned', () {
    expect(
      disconnectPolicyMessage(mentionsIcsKept: true),
      startsWith('$existingMessage\n\n'),
    );
  });
}
