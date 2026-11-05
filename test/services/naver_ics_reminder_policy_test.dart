import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/services/naver_ics_reminder_policy.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  group('nextNaverIcsReminderAt', () {
    test('no successful import means no reminder', () {
      // banned-ok: deterministic calendar fixture; no system clock dependency.
      expect(nextNaverIcsReminderAt(now: DateTime(2026, 11, 4)), isNull);
    });

    test('an earlier import schedules the next local first at nine', () {
      expect(
        nextNaverIcsReminderAt(
          // banned-ok: deterministic calendar fixture; no system clock dependency.
          now: DateTime(2026, 11, 4),
          // banned-ok: deterministic calendar fixture; no system clock dependency.
          lastImportAt: DateTime(2026, 10, 20),
        ),
        // banned-ok: deterministic calendar fixture; no system clock dependency.
        DateTime(2026, 12, 1, 9),
      );
    });

    test('skips a candidate less than twenty-five days after import', () {
      expect(
        nextNaverIcsReminderAt(
          // banned-ok: deterministic calendar fixture; no system clock dependency.
          now: DateTime(2026, 11, 30, 10),
          // banned-ok: deterministic calendar fixture; no system clock dependency.
          lastImportAt: DateTime(2026, 11, 20),
        ),
        // banned-ok: deterministic calendar fixture; no system clock dependency.
        DateTime(2027, 1, 1, 9),
      );
    });

    test('December rolls over into January', () {
      expect(
        nextNaverIcsReminderAt(
          // banned-ok: deterministic calendar fixture; no system clock dependency.
          now: DateTime(2026, 12, 31),
          // banned-ok: deterministic calendar fixture; no system clock dependency.
          lastImportAt: DateTime(2026, 11, 1),
        ),
        // banned-ok: deterministic calendar fixture; no system clock dependency.
        DateTime(2027, 1, 1, 9),
      );
    });

    test('a future import is treated as now', () {
      expect(
        nextNaverIcsReminderAt(
          // banned-ok: deterministic calendar fixture; no system clock dependency.
          now: DateTime(2026, 11, 30, 10),
          // banned-ok: deterministic calendar fixture; no system clock dependency.
          lastImportAt: DateTime(2030, 1, 1),
        ),
        // banned-ok: deterministic calendar fixture; no system clock dependency.
        DateTime(2027, 1, 1, 9),
      );
    });

    test('exactly twenty-five days is allowed', () {
      expect(
        nextNaverIcsReminderAt(
          // banned-ok: deterministic calendar fixture; no system clock dependency.
          now: DateTime(2026, 11, 6, 9),
          // banned-ok: deterministic calendar fixture; no system clock dependency.
          lastImportAt: DateTime(2026, 11, 6, 9),
        ),
        // banned-ok: deterministic calendar fixture; no system clock dependency.
        DateTime(2026, 12, 1, 9),
      );
    });

    test('a reminder exactly at now moves to the next month', () {
      expect(
        nextNaverIcsReminderAt(
          // banned-ok: deterministic calendar fixture; no system clock dependency.
          now: DateTime(2026, 12, 1, 9),
          // banned-ok: deterministic calendar fixture; no system clock dependency.
          lastImportAt: DateTime(2026, 10, 1),
        ),
        // banned-ok: deterministic calendar fixture; no system clock dependency.
        DateTime(2027, 1, 1, 9),
      );
    });
  });

  group('Naver reminder payload', () {
    test('local date round trip', () {
      // banned-ok: deterministic calendar fixture; no system clock dependency.
      final payload = naverIcsReminderPayload(DateTime(2026, 2, 3, 9));
      expect(payload, 'naver_ics_monthly_reminder:2026-02-03');
      expect(classifyNaverIcsReminderPayload(payload),
          NaverIcsReminderPayloadKind.tokened);
      // banned-ok: deterministic calendar fixture; no system clock dependency.
      expect(naverIcsReminderDateFromPayload(payload), DateTime(2026, 2, 3));
    });

    test('legacy is only the exact old payload', () {
      expect(classifyNaverIcsReminderPayload('naver_ics_monthly_reminder'),
          NaverIcsReminderPayloadKind.legacy);
    });

    for (final payload in <String>[
      'naver_ics_monthly_reminderX',
      'naver_ics_monthly_reminder:',
      'naver_ics_monthly_reminder:2026-02-31',
      'naver_ics_monthly_reminder:2026-13-01',
      'naver_ics_monthly_reminder:2026-2-01',
      'naver_ics_monthly_reminder:2026-02-01:extra',
      'naver_ics_monthly_reminder:2026-02-01\n',
    ]) {
      test('rejects malformed token $payload', () {
        expect(classifyNaverIcsReminderPayload(payload),
            NaverIcsReminderPayloadKind.malformed);
        expect(naverIcsReminderDateFromPayload(payload), isNull);
      });
    }

    test('null and unrelated payloads are not Naver reminders', () {
      for (final payload in <String?>[
        null,
        '',
        'briefing:morning',
        'event:a'
      ]) {
        expect(classifyNaverIcsReminderPayload(payload),
            NaverIcsReminderPayloadKind.notNaver);
      }
    });
  });

  group('NaverIcsImportHistoryStore', () {
    test('records injected clock as UTC and reads it after recreation',
        () async {
      // banned-ok: deterministic calendar fixture; no system clock dependency.
      final now = DateTime(2026, 11, 4, 13, 25);
      final prefs = await SharedPreferences.getInstance();
      final store = NaverIcsImportHistoryStore(
        prefsLoader: () async => prefs,
        now: () => now,
      );
      expect(await store.lastImportAt(), isNull);
      await store.recordImportNow();
      expect(prefs.getString(naverIcsLastImportAtKey),
          now.toUtc().toIso8601String());
      expect(await NaverIcsImportHistoryStore().lastImportAt(), now.toUtc());
    });

    test('malformed history and unavailable prefs are safe', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        naverIcsLastImportAtKey: 'not a date',
      });
      expect(await NaverIcsImportHistoryStore().lastImportAt(), isNull);
      final unavailable =
          NaverIcsImportHistoryStore(prefsLoader: () async => null);
      expect(await unavailable.lastImportAt(), isNull);
      await expectLater(unavailable.recordImportNow(), completes);
      final failing = NaverIcsImportHistoryStore(
        prefsLoader: () async => throw StateError('private preference error'),
      );
      expect(await failing.lastImportAt(), isNull);
      await expectLater(failing.recordImportNow(), completes);
    });
  });
}
