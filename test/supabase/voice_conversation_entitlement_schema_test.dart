import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  // schema.sql/migration은 CRLF(\r\n)로 저장되어 있으므로, 여러 줄에 걸친
  // 리터럴 비교가 줄바꿈 문자 차이로 깨지지 않도록 LF로 정규화해서 읽는다.
  final schema =
      File('supabase/schema.sql').readAsStringSync().replaceAll('\r\n', '\n');
  final migration = File(
    'supabase/migrations/20260808000000_voice_conversation_entitlement.sql',
  ).readAsStringSync().replaceAll('\r\n', '\n');
  final strictConsumeMigration = File(
    'supabase/migrations/20260810000000_voice_conversation_strict_consume.sql',
  ).readAsStringSync().replaceAll('\r\n', '\n');
  final strictPeekMigration = File(
    'supabase/migrations/20260809000000_voice_conversation_strict_initial_trial.sql',
  ).readAsStringSync().replaceAll('\r\n', '\n');

  test('user_settings gains daily-free and session columns', () {
    for (final sql in <String>[schema, migration]) {
      expect(sql, contains('voice_conversation_daily_free_date date'));
      expect(
        sql,
        contains(
          'voice_conversation_daily_free_used integer not null default 0',
        ),
      );
      expect(sql, contains('voice_conversation_last_session_id text'));
    }
  });

  test('entitlement peek RPC exists and is read-only (no update/insert)', () {
    for (final sql in <String>[schema, migration]) {
      final block = _between(
        sql,
        'create or replace function public.voice_conversation_entitlement_peek(',
        'grant execute on function public.voice_conversation_entitlement_peek',
      );
      expect(block, contains('security definer'));
      expect(block, contains('set search_path = public'));
      expect(block, contains('returns table'));
      expect(block, contains('initial_remaining'));
      expect(block, contains('daily_remaining'));
      expect(block, contains('requires_ad'));
      expect(block, isNot(contains('update public.user_settings')));
      expect(block, isNot(contains('insert into public.user_settings')));
    }
  });

  test('entitlement peek RPC is granted to authenticated only', () {
    for (final sql in <String>[schema, migration]) {
      expect(
        sql,
        contains(
          'grant execute on function public.voice_conversation_entitlement_peek(integer, integer)\n'
          '  to authenticated;',
        ),
      );
    }
  });

  test('source-of-truth peek RPC fixes initial=3 and daily=0', () {
    final block = _between(
      schema,
      'create or replace function public.voice_conversation_entitlement_peek(',
      'grant execute on function public.voice_conversation_entitlement_peek',
    );
    expect(block, contains('p_initial_limit integer default 3'));
    expect(block, contains('p_daily_limit integer default 0'));
    expect(block, contains('v_initial_limit integer := 3;'));
    expect(block, contains('v_daily_limit integer := 0;'));
  });

  test('consume RPC locks the row and is idempotent per session id', () {
    for (final sql in <String>[schema, migration]) {
      final block = _between(
        sql,
        'create or replace function public.consume_voice_conversation_free_usage(',
        'grant execute on function public.consume_voice_conversation_free_usage',
      );
      expect(block, contains('security definer'));
      expect(block, contains('set search_path = public'));
      expect(block, contains('for update'));
      expect(
        block,
        contains('v_row.voice_conversation_last_session_id = p_session_id'),
      );
      expect(block, contains('on conflict (user_id) do nothing'));
    }
  });

  test('source-of-truth consume RPC fixes initial=3 and daily=0', () {
    final block = _between(
      schema,
      'create or replace function public.consume_voice_conversation_free_usage(',
      'grant execute on function public.consume_voice_conversation_free_usage',
    );
    expect(
      block,
      contains(
        'p_initial_limit integer default 3',
      ),
    );
    expect(block, contains('p_daily_limit integer default 0'));
    expect(block, contains('v_initial_limit integer := 3;'));
    expect(block, contains('v_daily_limit integer := 0;'));
  });

  test('consume RPC has only initial-free then ad-required progression', () {
    final block = _between(
      schema,
      'create or replace function public.consume_voice_conversation_free_usage(',
      'grant execute on function public.consume_voice_conversation_free_usage',
    );
    expect(block, contains("v_source := 'initial_free';"));
    expect(block, contains("v_source := 'ad_required';"));
    expect(block, isNot(contains("v_source := 'daily_free';")));
  });

  test('consume RPC never contains a daily-free branch', () {
    final block = _between(
      schema,
      'create or replace function public.consume_voice_conversation_free_usage(',
      'grant execute on function public.consume_voice_conversation_free_usage',
    );
    expect(block, isNot(contains("v_source := 'daily_free';")));
    expect(block, isNot(contains('elsif v_daily_limit > 0')));
  });

  test('consume RPC is granted to authenticated only', () {
    for (final sql in <String>[schema, migration]) {
      expect(
        sql,
        contains(
          'grant execute on function public.consume_voice_conversation_free_usage(text, integer, integer)\n'
          '  to authenticated;',
        ),
      );
    }
  });

  test('strict consume wrapper fixes initial limit to 3 and daily limit to 0',
      () {
    expect(
      strictConsumeMigration,
      contains(
        'alter function public.consume_voice_conversation_free_usage(text, integer, integer)\n'
        '  rename to consume_voice_conversation_free_usage_legacy;',
      ),
    );
    expect(strictConsumeMigration, contains('p_session_id,\n    3,\n    0'));
    expect(
      strictConsumeMigration,
      contains(
        'grant execute on function public.consume_voice_conversation_free_usage(text, integer, integer)\n'
        '  to authenticated;',
      ),
    );
    expect(
      strictPeekMigration,
      contains('voice_conversation_entitlement_peek_legacy(3, 0)'),
    );
    expect(
      strictPeekMigration,
      contains(
        'revoke all on function public.voice_conversation_entitlement_peek(integer, integer)\n'
        '  from public, anon;',
      ),
    );
  });
}

String _between(String text, String start, String end) {
  final startIndex = text.indexOf(start);
  expect(startIndex, isNonNegative, reason: 'Missing start marker: $start');
  final endIndex = text.indexOf(end, startIndex);
  expect(endIndex, isNonNegative, reason: 'Missing end marker: $end');
  return text.substring(startIndex, endIndex);
}
