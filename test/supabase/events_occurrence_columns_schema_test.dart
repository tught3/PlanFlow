import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('event occurrence columns match the historical migration types', () {
    final migration = File(
      'supabase/migrations/20261112000100_events_occurrence_columns.sql',
    );
    expect(migration.existsSync(), isTrue);
    final migrationSql = migration.readAsStringSync().toLowerCase();
    expect(migrationSql, contains('alter table public.events'));
    expect(
      migrationSql,
      contains(
          'add column if not exists overridden_occurrence_date timestamptz'),
    );
    expect(
      migrationSql,
      contains('add column if not exists deleted_occurrence_dates jsonb'),
    );
    final schema = File('supabase/schema.sql').readAsStringSync().toLowerCase();
    final events = RegExp(
      r'create table if not exists public\.events \((.*?)\r?\n\);',
      dotAll: true,
    ).firstMatch(schema)!.group(1)!;
    expect(events, contains('overridden_occurrence_date timestamptz,'));
    expect(events, contains('deleted_occurrence_dates jsonb,'));
  });
}
