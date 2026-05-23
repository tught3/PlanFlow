import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('feedback reports admin policy matches app admin emails', () {
    final schema = File('supabase/schema.sql').readAsStringSync();
    final patch =
        File('supabase/feedback_reports_patch.sql').readAsStringSync();

    for (final sql in <String>[schema, patch]) {
      expect(sql, contains("product text not null default 'planflow'"));
      expect(sql, contains('feedback_reports_product_check'));
      expect(sql, contains('tught3@naver.com'));
      expect(sql, contains('tught3@gmail.com'));
      expect(
        sql,
        contains(
          'grant update (status, updated_at) on table public.feedback_reports to authenticated;',
        ),
      );
    }
  });
}
