import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('feedback reports admin policy matches app admin emails', () {
    final schema = File('supabase/schema.sql').readAsStringSync();
    final patch = File(
      'supabase/feedback_reports_patch.sql',
    ).readAsStringSync();
    final migrations = Directory('supabase/migrations')
        .listSync()
        .whereType<File>()
        .where((file) => file.path.endsWith('feedback_reports_web_support.sql'))
        .toList(growable: false);

    for (final sql in <String>[schema, patch]) {
      expect(sql, contains('user_id uuid references public.users'));
      expect(sql, contains("product text not null default 'planflow'"));
      expect(sql, contains('feedback_reports_product_check'));
      expect(sql, contains("source text not null default 'app'"));
      expect(sql, contains('feedback_reports_source_check'));
      expect(sql, contains("'android-app'"));
      expect(sql, contains('email text'));
      expect(sql, contains('alter column user_id drop not null'));
      expect(sql, contains('feedback_reports_source_idx'));
      expect(sql, contains('tught3@naver.com'));
      expect(sql, contains('tught3@gmail.com'));
      expect(
        sql,
        contains(
          'grant update (status, updated_at) on table public.feedback_reports to authenticated;',
        ),
      );
    }

    expect(migrations, hasLength(1));
    final migration = migrations.single.readAsStringSync();
    expect(migration, contains('alter column user_id drop not null'));
    expect(migration, contains("alter column source set default 'app'"));
    expect(migration, contains('feedback_reports_source_idx'));
  });
}
