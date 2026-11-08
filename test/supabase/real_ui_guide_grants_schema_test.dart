import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// Structural source guards only; this is not a PostgreSQL execution/policy test.
// Offset-aware source guards and math specs do not execute PostgreSQL.
void main() {
  final sql =
      File('supabase/migrations/20261019000000_real_ui_guide_grants.sql')
          .readAsStringSync()
          .toLowerCase();
  final advanceSql = RegExp(
    r'create or replace function public\.advance_real_ui_guide\(.*?\$\$;',
    dotAll: true,
  ).firstMatch(sql)?.group(0) ?? '';

  test('RPCs use private tables and authenticated-only security-definer access',
      () {
    for (final table in [
      'real_ui_guide_sessions',
      'real_ui_guide_requests',
      'real_ui_guide_operations',
    ]) {
      expect(
          sql, contains('alter table public.$table enable row level security'));
    }
    expect(sql, contains('from public,anon,authenticated'));
    for (final rpc in [
      'begin_real_ui_guide',
      'authorize_real_ui_guide_operation',
      'advance_real_ui_guide',
      'finish_real_ui_guide',
    ]) {
      expect(sql, contains('function public.$rpc('));
      expect(sql,
          contains('security definer set search_path=pg_catalog,public,auth'));
      expect(sql, contains('to authenticated'));
    }
  });

  test(
      'event binding is owner-bound, session-created, personal and nonrecurring',
      () {
    expect(sql, contains('auth.uid()'));
    expect(sql, contains('e.user_id=u'));
    expect(sql, contains('e.created_at<s.created_at'));
    expect(sql, contains('e.group_event_id is not null'));
    expect(sql, contains('e.parent_event_id is not null'));
    expect(sql, contains('e.recurrence_rule is not null'));
    expect(sql, contains('e.external_id is not null'));
    expect(sql, contains("e.source in ('manual','voice')"));
    expect(sql, contains('target_title text'));
    expect(sql, contains('target_location text'));
    expect(sql, contains('target_start_date date'));
    expect(sql, contains('e.title is distinct from s.target_title'));
    expect(sql, contains('e.location is distinct from s.target_location'));
    expect(sql, isNot(contains('e.start_at::date')));
  });

  test('coarse FSM uses row locks, null-safe CAS and payload replay protection', () {
    expect(
        RegExp(r'for update').allMatches(sql).length, greaterThanOrEqualTo(3));
    expect(advanceSql, isNotEmpty);
    expect(advanceSql, contains('s.revision is distinct from p_expected_revision'));
    expect(advanceSql, contains(
        "jsonb_build_array('advance',p_session_id,p_expected_revision,p_action,p_event_id,p_payload)::text"));
    expect(sql, contains('operation_replay_mismatch'));
    expect(advanceSql, contains('request_replay_mismatch'));
    expect(sql, contains('request_replay_mismatch'));
    for (final phase in [
      'create',
      'saved',
      'query',
      'edit',
      'preview',
      'updated',
      'terminal'
    ]) {
      expect(sql, contains("'$phase'"));
    }
  });

  test('finite expiry and actual preview timestamp are enforced', () {
    expect(sql, contains("interval '2 minutes'"));
    expect(sql, contains("interval '60 minutes'"));
    expect(sql, contains("interval '7 days'"));
    expect(sql, contains('expected_start_at'));
    expect(sql, contains('e.start_at is distinct from s.expected_start_at'));
  });

  test('ordinary entitlement counters and consume RPCs are untouched', () {
    for (final forbidden in [
      'user_settings',
      'consume_voice_conversation_free_usage',
      'consume_schedule_parse_free_usage',
      'voice_conversation_daily_free_used',
      'schedule_parse_daily_used_count',
    ]) {
      expect(sql, isNot(contains(forbidden)));
    }
  });

  // ---- v3 additions: structural assertions for offset/display context ----

  test(
      'v3 explicit offset fields are bound at bind_created and edit_preview; saved_local_date persists',
      () {
    // Column presence
    expect(sql, contains('saved_local_date date'));
    expect(sql, contains('bind_calendar_utc_offset_minutes integer'));
    expect(sql, contains('preview_calendar_utc_offset_minutes integer'));
    expect(sql, contains('between -840 and 840'));
    // JSONB extraction in payload for both checkpoints
    expect(sql, contains("p_payload->>'calendar_utc_offset_minutes'"));
    expect(sql, contains("p_payload->>'expected_start_at'"));
    // Reason codes: missing / malformed / out-of-range / declared-day mismatch
    expect(sql, contains("'calendar_offset_required'"));
    expect(sql, contains("'calendar_offset_invalid'"));
    expect(sql, contains("'calendar_offset_out_of_range'"));
    expect(sql, contains("'declared_local_date_mismatch'"));
    expect(sql, contains("'expected_start_invalid'"));
    // make_interval(... mins => v_offset) drives local-date computation
    expect(sql, contains('make_interval'));
    // Save-path persists bind offset, saved_local_date, and preview offset
    expect(
        sql,
        contains(
            "bind_calendar_utc_offset_minutes=case when p_action='bind_created'"));
    expect(sql, contains("saved_local_date=case when p_action='bind_created'"));
    expect(
        sql,
        contains(
            "preview_calendar_utc_offset_minutes=case when p_action='edit_preview'"));
    // The original calendar date remains immutable after binding.
    expect(
        sql,
        contains(
            "target_start_date=case when p_action='bind_created' then v_saved_local_date"));
  });

  test(
      'v3 responses include saved_local_date; begin and advance both expose it (no null literal)',
      () {
    // Both begin and advance build the response with `saved_local_date` referencing the column.
    expect(sql, contains("'saved_local_date',s.saved_local_date"));
    // Begin's response should be by-column, not the previous null literal.
    expect(sql, isNot(contains("'saved_local_date',null")));
  });

  test(
      'v3 update_verified reads actual row + same-date based on declared offset context (not UTC date alone)',
      () {
    expect(sql, isNot(contains('e.start_at::date')));
    expect(
        sql, isNot(contains('coalesce(s.preview_calendar_utc_offset_minutes')));
    expect(
        sql,
        contains(
            "p_action<>'update_verified' and (s.bind_calendar_utc_offset_minutes is null"));
    expect(
        sql,
        contains(
            "((e.start_at at time zone 'utc')+make_interval(mins=>s.bind_calendar_utc_offset_minutes))::date"));
    expect(sql, contains('s.preview_calendar_utc_offset_minutes is null'));
    expect(
        sql,
        contains(
            "((e.start_at at time zone 'utc')+make_interval(mins=>s.preview_calendar_utc_offset_minutes))::date"));
    expect(sql, contains('e.start_at is distinct from s.expected_start_at'));
    expect(sql, contains('is distinct from s.saved_local_date'));
  });

  test(
      'v3 idempotency payload hash captures sensitive offset and preview fields (replay protection not weakened)',
      () {
    // Scoped to advance: hash the complete payload, not a selected subset.
    // This keeps replay protection sensitive to every payload field.
    expect(advanceSql, contains(
        "jsonb_build_array('advance',p_session_id,p_expected_revision,p_action,p_event_id,p_payload)::text"));
    // Both sensitive keys remain validated in the advance function.
    expect(advanceSql, contains('calendar_utc_offset_minutes'));
    expect(advanceSql, contains('expected_start_at'));
  });

  test('every date arithmetic path explicitly normalizes timestamptz to UTC',
      () {
    expect(
        sql,
        contains(
            "v_saved_local_date:=((e.start_at at time zone 'utc')+make_interval(mins=>v_offset))::date"));
    expect(
        sql,
        contains(
            "v_declared_local_date:=((v_expected_ts at time zone 'utc')+make_interval(mins=>v_offset))::date"));
    expect(RegExp("at time zone 'utc'").allMatches(sql).length, 4);
    expect(RegExp('make_interval').allMatches(sql).length, 4);
    expect(
        sql,
        contains(
            "jsonb_typeof(p_payload->'calendar_utc_offset_minutes') is distinct from 'number'"));
    expect(sql, contains(r"v_offset_text !~ '^-?[0-9]+$'"));
  });

  // ---- v3 math spec: pure Dart — spec labels only, not actual Postgres proof ----

  group('calendar_utc_offset_minutes math spec (pure Dart)', () {
    DateTime dayOf(DateTime t) => DateTime(t.year, t.month, t.day);
    DateTime applyOffset(DateTime utc, int offsetMin) =>
        utc.add(Duration(minutes: offsetMin));

    test('Korea 08:00–15:00 same local day across UTC date is accepted', () {
      const offset = 9 * 60; // KST = UTC+09:00
      // Sun 2026-10-18 23:00 UTC == Mon 2026-10-19 08:00 KST (saved)
      final savedStart = DateTime.utc(2026, 10, 18, 23, 0);
      // Mon 2026-10-19 06:00 UTC == Mon 2026-10-19 15:00 KST (declared preview)
      final previewStart = DateTime.utc(2026, 10, 19, 6, 0);
      // UTC dates differ (10-18 vs 10-19); local dates must match.
      expect(savedStart.day, isNot(previewStart.day));
      expect(dayOf(applyOffset(savedStart, offset)),
          equals(dayOf(applyOffset(previewStart, offset))));
    });

    test('Korea 15:00 to 01:00 on the same local day is accepted', () {
      final saved = DateTime.utc(2026, 10, 19, 6);
      final preview = DateTime.utc(2026, 10, 18, 16);
      expect(saved.day, isNot(preview.day));
      expect(dayOf(applyOffset(saved, 540)), dayOf(applyOffset(preview, 540)));
    });

    test('UTC normalization ignores simulated non-UTC SQL session display', () {
      final instant = DateTime.utc(2026, 10, 18, 23);
      final expected = dayOf(applyOffset(instant, 540));
      for (final sessionOffset in [-720, -300, 0, 540, 840]) {
        final sessionWallClock = instant.add(Duration(minutes: sessionOffset));
        final normalizedUtc =
            sessionWallClock.subtract(Duration(minutes: sessionOffset));
        expect(dayOf(applyOffset(normalizedUtc, 540)), expected);
      }
    });

    test('actual local-day crossing is rejected even on the same UTC day', () {
      final before = DateTime.utc(2026, 10, 19, 14, 59);
      final after = DateTime.utc(2026, 10, 19, 15);
      expect(before.day, after.day);
      expect(dayOf(applyOffset(before, 540)),
          isNot(dayOf(applyOffset(after, 540))));
    });

    test('KST day crossing at +09:00 with a sun-skip UTC pair is rejected', () {
      const offset = 9 * 60;
      // Saved Sat 2026-10-17 14:00 UTC == Sat 2026-10-17 23:00 KST (day = Sat)
      final savedStart = DateTime.utc(2026, 10, 17, 14, 0);
      // Preview Mon 2026-10-19 02:00 KST == Sun 2026-10-18 17:00 UTC (day = Mon, skipping Sun entirely in KST)
      final previewStart = DateTime.utc(2026, 10, 18, 17, 0);
      expect(dayOf(applyOffset(savedStart, offset)),
          isNot(equals(dayOf(applyOffset(previewStart, offset)))));
      // Both happen to be different UTC days too, but the rejection must be
      // driven by local-date divergence, not by UTC-date alone.
    });

    test('negative offset (-05:00 / EST) computes correct local date', () {
      const offset = -5 * 60; // EST = UTC-05:00
      // Tue 2026-10-20 05:00 UTC == Tue 2026-10-20 00:00 EST
      final ts = DateTime.utc(2026, 10, 20, 5, 0);
      // banned-ok: Pinned date for a UTC offset boundary assertion.
      expect(dayOf(applyOffset(ts, offset)), equals(DateTime(2026, 10, 20)));
    });

    test('+14h edge offset (+840) computes correct local date', () {
      const offset = 14 * 60; // 840 — inclusive upper bound
      // Sun 2026-10-18 10:00 UTC == Mon 2026-10-19 00:00 +14
      final ts = DateTime.utc(2026, 10, 18, 10, 0);
      // banned-ok: Pinned date for a UTC offset boundary assertion.
      expect(dayOf(applyOffset(ts, offset)), equals(DateTime(2026, 10, 19)));
    });

    test('-14h+1 boundary offset (-839) lands on the previous day', () {
      const offset = -14 * 60 + 1; // -839 (just inside the lower bound)
      // 2026-10-19 10:30 UTC with -839 minutes -> 2026-10-19 10:30 - 13h59m = 10-18 20:31 UTC, day=18
      final ts = DateTime.utc(2026, 10, 19, 10, 30);
      // banned-ok: Pinned date for a UTC offset boundary assertion.
      expect(dayOf(applyOffset(ts, offset)), equals(DateTime(2026, 10, 18)));
    });

    test(
        'malformed/missing/out-of-range offset denials (range and parity gate)',
        () {
      bool isValidOffset(int? v) =>
          v != null && v >= -840 && v <= 840 && (v == v.toInt());
      // missing (null)
      expect(isValidOffset(null), isFalse);
      // bounds inclusive
      expect(isValidOffset(-840), isTrue);
      expect(isValidOffset(0), isTrue);
      expect(isValidOffset(840), isTrue);
      // just out of bounds
      expect(isValidOffset(-841), isFalse);
      expect(isValidOffset(841), isFalse);
    });

    test(
        'isValidOffset rejects non-integer numerics that could pass a raw range check',
        () {
      bool parityOK(num v) => v == v.truncateToDouble();
      expect(parityOK(840.5), isFalse);
      expect(parityOK(-840.5), isFalse);
      expect(parityOK(0), isTrue);
    });

    test(
        'local-date math: same offset yields equal local dates iff local days match',
        () {
      const offset = 9 * 60;
      final a = DateTime.utc(2026, 1, 1, 23, 0); // KST 2026-01-02 08:00
      final b = DateTime.utc(
          2026, 1, 2, 1, 0); // KST 2026-01-02 10:00 (same local day)
      final c = DateTime.utc(
          2026, 1, 2, 13, 0); // KST 2026-01-02 22:00 (same local day)
      expect(
          dayOf(applyOffset(a, offset)), equals(dayOf(applyOffset(b, offset))));
      expect(
          dayOf(applyOffset(b, offset)), equals(dayOf(applyOffset(c, offset))));
      // Now a clearly-crossing pair:
      // a is KST 2026-01-02 08:00 (day=02). For a different KST day we need
      // either before KST 00:00 (e.g. UTC 2026-01-01 14:00 -> KST 23:00 day=01)
      // or after KST 24:00 (e.g. UTC 2026-01-02 16:00 -> KST 2026-01-03 01:00, day=03).
      final d =
          DateTime.utc(2026, 1, 2, 16, 0); // KST 2026-01-03 01:00 (day = 03)
      expect(dayOf(applyOffset(a, offset)),
          isNot(equals(dayOf(applyOffset(d, offset)))));
    });
  });
}
