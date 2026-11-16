import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  const migrationPath =
      'supabase/migrations/20261117000100_group_invites_server_timestamps.sql';

  test('client invite inserts use server time and cap the expiration', () {
    final schema = File('supabase/schema.sql').readAsStringSync();
    final function = RegExp(
      r'create or replace function public\.set_group_invite_insert_timestamps'
      r'\(\)[\s\S]*?\n\$\$;',
    );
    final schemaFunction = function.firstMatch(schema.replaceAll('\r\n', '\n'));
    expect(schemaFunction, isNotNull,
        reason: 'Invite timestamp guard is missing');
    final migration = File(migrationPath).readAsStringSync().replaceAll(
          '\r\n',
          '\n',
        );
    expect(function.firstMatch(migration)?.group(0), schemaFunction!.group(0));

    final definition = schemaFunction.group(0)!;
    expect(definition, contains('security invoker'));
    expect(
      definition,
      matches(
        r"if current_user in \('authenticated', 'anon'\) then\s+"
        r'new\.created_at := now\(\);\s+'
        r"if new\.expires_at > new\.created_at \+ interval '7 days' then\s+"
        r"new\.expires_at := new\.created_at \+ interval '7 days';\s+"
        r'end if;\s+end if;\s+'
        r'return new;',
      ),
    );
    for (final sql in [schema, migration]) {
      expect(
        sql,
        matches(
          r'drop trigger if exists group_invites_set_insert_timestamps '
          r'on public\.group_invites;\s+'
          r'create trigger group_invites_set_insert_timestamps\s+'
          r'before insert on public\.group_invites\s+for each row execute '
          r'function public\.set_group_invite_insert_timestamps\(\);',
        ),
      );
    }
  });
}
