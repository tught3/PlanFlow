import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:planflow/services/critical_alarm_acknowledgement_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  group('SharedPreferencesCriticalAlarmAcknowledgementStore', () {
    const store = SharedPreferencesCriticalAlarmAcknowledgementStore();

    test('markAcknowledged stores UTC ISO; exact isAcknowledged matches',
        () async {
      final startAt = DateTime.utc(2026, 7, 16, 9);
      await store.markAcknowledged('event-1', startAt);

      expect(await store.isAcknowledged('event-1', startAt), isTrue);
      expect(await store.hasAcknowledgement('event-1'), isTrue);
      expect(
        await store.hasUnknownStartAcknowledgement('event-1'),
        isFalse,
      );
    });

    test('isAcknowledged is false for mismatched startAt', () async {
      final startAt = DateTime.utc(2026, 7, 16, 9);
      await store.markAcknowledged('event-1', startAt);

      expect(await store.isAcknowledged('event-1', DateTime.utc(2026, 7, 16, 10)),
          isFalse);
      expect(
        await store.isAcknowledged(
          'event-1',
          DateTime.utc(2026, 7, 17, 9),
        ),
        isFalse,
      );
    });

    test('UTC and local DateTime of the same instant compare equal', () async {
      final utcStart = DateTime.utc(2026, 7, 16, 9);
      // 동등한 현지 시각(KST 가정은 OS 타임존에 의존). 시스템 타임존이 UTC
      // 와 같으면 변환이 identity가 되므로 테스트가 자명해진다. 시스템
      // 타임존이 UTC가 아니면 변환이 실제 변환을 거치므로 의미 있는
      // 정규화 회귀를 검증한다.
      final localStart = utcStart.toLocal();
      await store.markAcknowledged('event-tz', utcStart);

      expect(await store.isAcknowledged('event-tz', localStart), isTrue,
          reason:
              'UTC와 local DateTime이 동일 instant면 toUtc().toIso8601String() '
              '으로 정규화돼 일치해야 한다.');
    });

    test('round-trip through DateTime.parse preserves ack', () async {
      final original = DateTime.utc(2026, 7, 16, 9, 30, 45);
      await store.markAcknowledged('event-rt', original);

      final stored = await store.isAcknowledged('event-rt', original);
      expect(stored, isTrue);

      // 다른 코드 경로(예: SharedPreferences에서 직접 읽어 parse)에서도
      // 일치해야 한다.
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('critical_alarm:ack:event-rt');
      expect(raw, isNotNull);
      final parsed = DateTime.parse(raw!);
      expect(
        await store.isAcknowledged('event-rt', parsed),
        isTrue,
        reason: 'SharedPreferences에 저장된 ISO를 parse한 DateTime도 '
            'isAcknowledged에서 매칭돼야 한다.',
      );
    });

    test('markAcknowledged with unknownStartSentinel sets sentinel', () async {
      await store.markAcknowledged('event-sentinel', unknownStartSentinel);

      expect(await store.hasAcknowledgement('event-sentinel'), isTrue);
      expect(
        await store.hasUnknownStartAcknowledgement('event-sentinel'),
        isTrue,
      );
      expect(
        await store.isAcknowledged('event-sentinel', DateTime.utc(2030, 1, 1)),
        isFalse,
        reason: 'sentinel은 어떤 real startAt과도 매칭되면 안 된다.',
      );
    });

    test('clearAcknowledgement removes stored ack', () async {
      final startAt = DateTime.utc(2026, 7, 16, 9);
      await store.markAcknowledged('event-1', startAt);
      await store.clearAcknowledgement('event-1');

      expect(await store.isAcknowledged('event-1', startAt), isFalse);
      expect(await store.hasAcknowledgement('event-1'), isFalse);
    });

    test('empty eventId is treated as no-op', () async {
      final startAt = DateTime.utc(2026, 7, 16, 9);
      await store.markAcknowledged('', startAt);

      expect(await store.isAcknowledged('', startAt), isFalse);
      expect(await store.hasAcknowledgement(''), isFalse);
    });

    test('markAcknowledged overwrites previous value', () async {
      final first = DateTime.utc(2026, 7, 16, 9);
      final second = DateTime.utc(2026, 7, 16, 10);
      await store.markAcknowledged('event-1', first);
      await store.markAcknowledged('event-1', second);

      expect(await store.isAcknowledged('event-1', first), isFalse);
      expect(await store.isAcknowledged('event-1', second), isTrue);
    });

    test('different eventIds do not collide', () async {
      final startAt = DateTime.utc(2026, 7, 16, 9);
      await store.markAcknowledged('event-A', startAt);

      expect(await store.isAcknowledged('event-B', startAt), isFalse);
    });

    test('sentinelIso is the normalized UTC form of unknownStartSentinel',
        () async {
      expect(
        SharedPreferencesCriticalAlarmAcknowledgementStore.sentinelIso,
        unknownStartSentinel.toUtc().toIso8601String(),
      );
    });
  });
}