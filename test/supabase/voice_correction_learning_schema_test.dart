import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('voice correction learning schema stores minimal rules only', () {
    final schema = File('supabase/schema.sql').readAsStringSync();
    final migration = File(
      'supabase/migrations/20260528000000_voice_correction_learning.sql',
    ).readAsStringSync();
    final schemaBlock = _between(
      schema,
      'create table if not exists public.voice_correction_rules',
      '-- 8. calendar_connections',
    );
    final migrationBlock = _between(
      migration,
      'create table if not exists public.voice_correction_rules',
      'alter table public.voice_correction_rules enable row level security',
    );

    for (final sql in <String>[schemaBlock, migrationBlock]) {
      expect(sql, contains('voice_correction_rules'));
      expect(sql, contains('voice_common_correction_rules'));
      expect(sql, contains('from_text text not null'));
      expect(sql, contains('to_text text not null'));
      expect(sql, contains('context_before text not null default'));
      expect(sql, contains('context_after text not null default'));
      expect(sql, isNot(contains('raw_text text')));
      expect(sql, isNot(contains('memo text')));
    }
  });

  test('voice correction learning RLS limits personal rules to owner', () {
    final schema = File('supabase/schema.sql').readAsStringSync();
    final migration = File(
      'supabase/migrations/20260528000000_voice_correction_learning.sql',
    ).readAsStringSync();

    for (final sql in <String>[schema, migration]) {
      expect(
          sql,
          contains(
              'alter table public.voice_correction_rules enable row level security'));
      expect(
        sql,
        matches(
          RegExp(
              r'using \((user_id = auth\.uid\(\)|auth\.uid\(\) = user_id)\)'),
        ),
      );
      expect(
        sql,
        matches(
          RegExp(
            r'with check \((user_id = auth\.uid\(\)|auth\.uid\(\) = user_id)\)',
          ),
        ),
      );
      expect(sql, contains('grant select, insert, update, delete'));
    }
  });

  test('common correction rules are authenticated read only', () {
    final schema = File('supabase/schema.sql').readAsStringSync();
    final migration = File(
      'supabase/migrations/20260528000000_voice_correction_learning.sql',
    ).readAsStringSync();

    for (final sql in <String>[schema, migration]) {
      expect(
          sql,
          contains(
              'grant select on table public.voice_common_correction_rules to authenticated'));
      expect(sql, contains('for select'));
      expect(sql, contains('to authenticated'));
      expect(
          sql,
          isNot(contains(
              'grant insert on table public.voice_common_correction_rules')));
      expect(
          sql,
          isNot(contains(
              'grant update on table public.voice_common_correction_rules')));
    }
  });

  test('user settings includes correction learning toggles', () {
    final schema = File('supabase/schema.sql').readAsStringSync();
    final migration = File(
      'supabase/migrations/20260528000000_voice_correction_learning.sql',
    ).readAsStringSync();

    for (final sql in <String>[schema, migration]) {
      expect(
          sql,
          contains(
              'voice_correction_learning_enabled boolean not null default true'));
      expect(
          sql,
          contains(
              'voice_common_learning_opt_in boolean not null default false'));
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
