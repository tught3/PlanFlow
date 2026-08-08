import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  // schema.sql/migration은 CRLF(\r\n)로 저장되어 있으므로, 여러 줄에 걸친
  // 리터럴 비교가 줄바꿈 문자 차이로 깨지지 않도록 LF로 정규화해서 읽는다.
  final schema = File('supabase/schema.sql')
      .readAsStringSync()
      .replaceAll('\r\n', '\n');
  final migration = File(
    'supabase/migrations/20260808000000_voice_conversation_entitlement.sql',
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

  test('entitlement peek RPC exists and is read-only (no update/insert)',
      () {
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

  test('consume RPC clamps caller-supplied limits with least()/greatest()',
      () {
    for (final sql in <String>[schema, migration]) {
      final block = _between(
        sql,
        'create or replace function public.consume_voice_conversation_free_usage(',
        'grant execute on function public.consume_voice_conversation_free_usage',
      );
      expect(
        block,
        contains(
          "v_initial_limit integer := least(greatest(coalesce(p_initial_limit, 3), 0), 10);",
        ),
      );
      expect(
        block,
        contains(
          "v_daily_limit integer := least(greatest(coalesce(p_daily_limit, 1), 0), 5);",
        ),
      );
    }
  });

  test('consume RPC free-trial/daily-free progression covers all sources',
      () {
    for (final sql in <String>[schema, migration]) {
      final block = _between(
        sql,
        'create or replace function public.consume_voice_conversation_free_usage(',
        'grant execute on function public.consume_voice_conversation_free_usage',
      );
      expect(block, contains("v_source := 'initial_free';"));
      expect(block, contains("v_source := 'daily_free';"));
      expect(block, contains("v_source := 'ad_required';"));
      expect(block, contains('Asia/Seoul'));
    }
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
}

String _between(String text, String start, String end) {
  final startIndex = text.indexOf(start);
  expect(startIndex, isNonNegative, reason: 'Missing start marker: $start');
  final endIndex = text.indexOf(end, startIndex);
  expect(endIndex, isNonNegative, reason: 'Missing end marker: $end');
  return text.substring(startIndex, endIndex);
}
