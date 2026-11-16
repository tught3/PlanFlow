import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('events use an isolated timestamp trigger for content changes', () {
    final migration = File(
      'supabase/migrations/20261112000200_events_updated_at_skip_sync_metadata.sql',
    );
    expect(migration.existsSync(), isTrue);
    final triggerSql = migration.readAsStringSync();
    final schema = File('supabase/schema.sql').readAsStringSync();
    expect(schema, contains(triggerSql.trim()));
    expect(triggerSql,
        contains('execute function public.events_set_updated_at()'));
    expect(triggerSql, isNot(contains('function public.set_updated_at()')));
    expect(triggerSql, contains('new.updated_at := old.updated_at'));
    expect(triggerSql, contains('new.updated_at := now()'));
    expect(triggerSql, contains('set search_path = public'));
    final exclusions = RegExp(r"-\s*'\{([^}]+)\}'::text\[\]")
        .allMatches(triggerSql)
        .map((match) => match.group(1)!.split(','))
        .toList();
    expect(exclusions, hasLength(2));
    for (final keys in exclusions) {
      expect(
          keys,
          unorderedEquals([
            'external_id',
            'external_calendar_id',
            'external_etag',
            'external_updated_at',
            'last_synced_at',
            'updated_at',
          ]));
    }
    expect(
        schema,
        contains(RegExp(
          r'function public\.set_updated_at\(\)\s*returns trigger'
          r'\s*language plpgsql\s*set search_path = public\s*as \$\$'
          r'\s*begin\s*new\.updated_at\s*=\s*now\(\);\s*return new;'
          r'\s*end;\s*\$\$;',
        )));
  });
}
