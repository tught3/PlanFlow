import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  // 회귀: 브리핑 알람은 "알람 콜백이 스스로 다음 날 것을 재예약"하는 체인
  // 하나에만 의존했다 — 그 체인이 조용히 끊기면(스케줄 실패·예외) 콜드
  // 스타트나 설정 재저장 전까지 영구히 재예약이 안 됐다(같은 증상 5회
  // 반복 신고). 출발 알람은 이미 resume마다 재예약을 갱신하는데
  // (_refreshDepartureAlarmsAndMonitor) 브리핑만 빠져 있던 게 근본 원인.
  //
  // 이 테스트는 전체 ShellScreen을 마운트해 실제 알람 재예약을 검증하는
  // 대신(AndroidAlarmManager 플랫폼 채널·인증된 사용자·Supabase 목업 등
  // 무거운 하네스가 필요), didChangeAppLifecycleState의 resumed 분기가
  // 실제로 _ensureBriefingsScheduled를 호출하는 소스 배선을 고정한다 —
  // "resume 훅에 브리핑 재예약 호출을 넣었다가 나중에 리팩토링하면서
  // 실수로 빠뜨리는" 재발을 잡기 위한 구조가드다.
  test('shell_screen.dart의 resumed 분기가 _ensureBriefingsScheduled를 호출한다', () {
    final source = File('lib/screens/shell_screen.dart').readAsStringSync();

    final resumedBlockStart = source.indexOf('AppLifecycleState.resumed');
    expect(resumedBlockStart, greaterThan(-1),
        reason: 'didChangeAppLifecycleState의 resumed 분기를 찾지 못함');

    final blockEnd = source.indexOf('\n  }', resumedBlockStart);
    expect(blockEnd, greaterThan(resumedBlockStart));

    final resumedBlock = source.substring(resumedBlockStart, blockEnd);

    expect(
      resumedBlock,
      contains('_ensureBriefingsScheduled'),
      reason: '앱 resume 시 브리핑 재예약 백스톱이 빠지면 알람 재예약 체인이 '
          '끊겼을 때 콜드스타트 전까지 영구 무음이 재발한다.',
    );
    expect(
      resumedBlock,
      contains('_refreshDepartureAlarmsAndMonitor'),
      reason: '출발 알람 재예약 백스톱도 함께 유지돼야 한다.',
    );
  });
}
