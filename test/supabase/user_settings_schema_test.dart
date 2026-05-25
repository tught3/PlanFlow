import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('user settings schema includes departure safety margin setting', () {
    final schema = File('supabase/schema.sql').readAsStringSync();
    final patch = File('supabase/user_settings_patch.sql').readAsStringSync();

    for (final sql in <String>[schema, patch]) {
      expect(sql, contains('departure_safety_margin_min'));
      expect(
        sql,
        contains(
          'add column if not exists departure_safety_margin_min integer not null default 20',
        ),
      );
    }
  });

  test('user settings schema includes Naver CalDAV mirror columns', () {
    final schema = File('supabase/schema.sql').readAsStringSync();
    final migration = File(
      'supabase/migrations/20260525000000_naver_caldav_mirror.sql',
    ).readAsStringSync();

    for (final sql in <String>[schema, migration]) {
      expect(sql, contains('naver_caldav_id'));
      expect(sql, contains('naver_caldav_app_password'));
    }
  });
}
