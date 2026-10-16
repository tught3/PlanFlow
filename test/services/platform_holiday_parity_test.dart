import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/data/models/event_model.dart';
import 'package:planflow/services/korean_holidays.dart';
import 'package:planflow/services/synced_public_holiday_visibility.dart';

void main() {
  const year = 2098;

  Future<void> onPlatform(
      TargetPlatform platform, Future<void> Function() body) async {
    final previous = debugDefaultTargetPlatformOverride;
    debugDefaultTargetPlatformOverride = platform;
    try {
      await body();
    } finally {
      debugDefaultTargetPlatformOverride = previous;
    }
  }

  EventModel event(
    String title, {
    bool allDay = true,
    String? externalId = 'provider-event',
    String? externalCalendarId = 'google:holidays',
    DateTime? startAt,
  }) =>
      EventModel(
        id: 'provider-event-${title.hashCode}',
        userId: 'user',
        title: title,
        startAt: startAt ?? DateTime(year, 1, 1, 9),
        externalId: externalId,
        externalCalendarId: externalCalendarId,
        isAllDay: allDay,
      );

  // Differential matrix: canonical / generic / prefixed-alias / prefixed-
  // generic × allDay / timed × present / missing externalID × holiday /
  // non-holiday date. Run once per platform with fixed expectations so the
  // Android (f26 baseline) and iOS (84cb strict all-day) predicates can be
  // diffed side-by-side.
  void runMatrix(TargetPlatform platform) {
    final canonicalAllDay = isSyncedPublicHolidayDuplicate(
      event('신정', allDay: true),
    );
    final canonicalTimed = isSyncedPublicHolidayDuplicate(
      event('신정', allDay: false),
    );
    final prefixedCanonicalAllDay = isSyncedPublicHolidayDuplicate(
      event('종일 신정', allDay: true),
    );
    final prefixedCanonicalTimed = isSyncedPublicHolidayDuplicate(
      event('종일 신정', allDay: false),
    );
    final genericAllDay = isSyncedPublicHolidayDuplicate(
      event('공휴일', allDay: true),
    );
    final genericTimed = isSyncedPublicHolidayDuplicate(
      event('공휴일', allDay: false),
    );
    final prefixedGenericAllDay = isSyncedPublicHolidayDuplicate(
      event('종일 공휴일', allDay: true),
    );
    final prefixedGenericTimed = isSyncedPublicHolidayDuplicate(
      event('종일 공휴일', allDay: false),
    );
    final missingExternalIdAllDay = isSyncedPublicHolidayDuplicate(
      event(
        '신정',
        allDay: true,
        externalId: null,
        externalCalendarId: null,
      ),
    );
    final missingExternalIdGeneric = isSyncedPublicHolidayDuplicate(
      event(
        '공휴일',
        allDay: true,
        externalId: null,
        externalCalendarId: null,
      ),
    );
    final nonHolidayDateCanonical = isSyncedPublicHolidayDuplicate(
      event(
        '신정',
        allDay: true,
        startAt: DateTime(year, 6, 15, 9),
      ),
    );
    final nonHolidayDateGeneric = isSyncedPublicHolidayDuplicate(
      event(
        '공휴일',
        allDay: true,
        startAt: DateTime(year, 6, 15, 9),
      ),
    );

    if (platform == TargetPlatform.android) {
      // f26 baseline: no isAllDay gate, no prefix removal.
      expect(canonicalAllDay, isTrue,
          reason: 'Android canonical all-day must dedup');
      expect(canonicalTimed, isTrue,
          reason: 'Android canonical timed must dedup (f26 has no allDay gate)');
      expect(prefixedCanonicalAllDay, isFalse,
          reason: 'Android prefixed canonical all-day must NOT dedup');
      expect(prefixedCanonicalTimed, isFalse,
          reason: 'Android prefixed canonical timed must NOT dedup');
      expect(genericAllDay, isTrue,
          reason: 'Android generic all-day must dedup');
      expect(genericTimed, isTrue,
          reason: 'Android generic timed must dedup (f26 has no allDay gate)');
      expect(prefixedGenericAllDay, isFalse,
          reason: 'Android prefixed generic all-day must NOT dedup');
      expect(prefixedGenericTimed, isFalse,
          reason: 'Android prefixed generic timed must NOT dedup');
      expect(missingExternalIdAllDay, isFalse,
          reason: 'Android without external id must NOT dedup');
      expect(missingExternalIdGeneric, isFalse,
          reason: 'Android without external id must NOT dedup even for generic');
      expect(nonHolidayDateCanonical, isFalse,
          reason: 'Android canonical on a non-holiday date must NOT dedup');
      expect(nonHolidayDateGeneric, isFalse,
          reason: 'Android generic on a non-holiday date must NOT dedup');
    } else {
      expect(platform, TargetPlatform.iOS);
      // 84cb baseline: strict isAllDay gate, prefix-stripped aliases,
      // generic branch disabled when a "종일 " prefix is present.
      expect(canonicalAllDay, isTrue,
          reason: 'iOS canonical all-day must dedup');
      expect(canonicalTimed, isFalse,
          reason: 'iOS canonical timed must NOT dedup (strict allDay gate)');
      expect(prefixedCanonicalAllDay, isTrue,
          reason: 'iOS prefixed canonical all-day must dedup after stripping');
      expect(prefixedCanonicalTimed, isFalse,
          reason: 'iOS prefixed canonical timed must NOT dedup (allDay gate)');
      expect(genericAllDay, isTrue,
          reason: 'iOS generic all-day must dedup');
      expect(genericTimed, isFalse,
          reason: 'iOS generic timed must NOT dedup (strict allDay gate)');
      expect(prefixedGenericAllDay, isFalse,
          reason: 'iOS prefixed generic all-day must NOT dedup '
              '(generic branch is disabled when "종일 " prefix is present)');
      expect(prefixedGenericTimed, isFalse,
          reason: 'iOS prefixed generic timed must NOT dedup (allDay gate)');
      expect(missingExternalIdAllDay, isFalse,
          reason: 'iOS without external id must NOT dedup');
      expect(missingExternalIdGeneric, isFalse,
          reason: 'iOS without external id must NOT dedup even for generic');
      expect(nonHolidayDateCanonical, isFalse,
          reason: 'iOS canonical on a non-holiday date must NOT dedup');
      expect(nonHolidayDateGeneric, isFalse,
          reason: 'iOS generic on a non-holiday date must NOT dedup');
    }
  }

  setUp(() {
    // KASI primes a throwaway alias so each test can re-prime with the
    // matrix alias '신정' and observe a real iOS revision notification.
    KoreanHolidays.applyLiveData(year, {(1, 1): 'prime'});
  });
  tearDown(() {
    // Reset the KASI live data so a subsequent test starts from a clean
    // dataset. The KoreanHolidays cache is shared across the test process.
    KoreanHolidays.applyLiveData(year, const <(int, int), String>{});
  });

  test(
      'Android predicate matches f26 baseline (no prefix removal, no allDay gate) and is revision-silent',
      () async {
    await onPlatform(TargetPlatform.android, () async {
      var notices = 0;
      void listener() => notices += 1;
      KoreanHolidays.revision.addListener(listener);
      try {
        // Re-prime so the Android cache holds the matrix alias. The
        // non-iOS branch must NOT fire a revision notification.
        KoreanHolidays.applyLiveData(year, {(1, 1): '신정'});
        expect(notices, 0,
            reason: 'Android applyLiveData must not fire revision notifications');
        runMatrix(TargetPlatform.android);
      } finally {
        KoreanHolidays.revision.removeListener(listener);
      }
    });
  });

  test('iOS predicate matches 84cb strict all-day + alias-strip semantics',
      () async {
    await onPlatform(TargetPlatform.iOS, () async {
      var notices = 0;
      void listener() => notices += 1;
      KoreanHolidays.revision.addListener(listener);
      try {
        // iOS fires a revision only when the data actually changes. The
        // setUp applyLiveData already ran for the previous test target, so
        // re-prime here to observe a single notification on a fresh
        // dataset and then assert the matrix expectations.
        KoreanHolidays.applyLiveData(year, {(1, 1): '신정'});
        expect(notices, 1,
            reason: 'iOS applyLiveData fires one revision for a fresh dataset');
        runMatrix(TargetPlatform.iOS);
      } finally {
        KoreanHolidays.revision.removeListener(listener);
      }
    });
  });
}
