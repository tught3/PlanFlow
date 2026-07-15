import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:planflow/core/diag_logger.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    DiagLogger.clear();
  });

  group('DiagLogger persistence', () {
    // 회귀: 브리핑/출발 알람의 백그라운드 콜백은 android_alarm_manager_plus가
    // 만드는 별도 isolate(별도 FlutterEngine)에서 실행되는데, DiagLogger가
    // in-memory 리스트만 썼을 때는 그 isolate가 남긴 로그가 포그라운드 UI의
    // "진단 로그 보기"(dump())에서 절대 보이지 않아 "왜 알람이 안 울렸는지"를
    // 진단할 방법이 없었다. 이제는 log()가 SharedPreferences에도 fire-and-
    // forget으로 남기므로, dumpPersisted()로 다른 isolate의 로그까지 읽을 수
    // 있어야 한다.
    test('log()가 남긴 항목을 dumpPersisted()로 실제 SharedPreferences에서 읽어온다',
        () async {
      DiagLogger.log('BriefingAlarm', 'callback failed type=morning');
      // log()의 영속화는 fire-and-forget이라 마이크로태스크가 flush될 시간을
      // 준다(실제 프로덕션에서도 동일 지연이 있으며, 짧은 지연 뒤엔 항상
      // 저장이 끝나 있어야 한다).
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      final persisted = await DiagLogger.dumpPersisted();

      expect(persisted, contains('BriefingAlarm'));
      expect(persisted, contains('callback failed type=morning'));
    });

    test('다른 isolate가 남긴 것처럼 SharedPreferences에만 있는 로그도 dumpPersisted가 읽는다',
        () async {
      // 실제 in-memory에는 아무것도 add하지 않고(다른 isolate 흉내), prefs에
      // 직접 써서 "이 프로세스의 dump()로는 안 보이지만 dumpPersisted()로는
      // 보여야 한다"를 검증한다 — 이게 바로 이번에 고친 버그의 핵심 계약이다.
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(
        'diag_logger:entries',
        <String>['[09:00:00][BriefingAlarm] reschedule failed type=evening'],
      );

      expect(DiagLogger.dump(), '(진단 로그 없음)');

      final persisted = await DiagLogger.dumpPersisted();
      expect(persisted, contains('reschedule failed type=evening'));
    });

    test('clearPersisted()는 in-memory와 저장된 로그를 모두 지운다', () async {
      DiagLogger.log('AlarmService', 'test entry');
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      await DiagLogger.clearPersisted();

      expect(DiagLogger.dump(), '(진단 로그 없음)');
      final persisted = await DiagLogger.dumpPersisted();
      expect(persisted, '(진단 로그 없음)');
    });
  });
}
