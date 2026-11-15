import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

String _function(String sql, String name) {
  final definition = RegExp(
    'create or replace function public\\.$name' r'\([\s\S]*?\r?\n\$\$;',
    caseSensitive: false,
  ).firstMatch(sql);
  expect(definition, isNotNull, reason: '$name definition missing');
  return definition!.group(0)!.replaceAll('\r\n', '\n');
}

void main() {
  const migrations = 'supabase/migrations';
  late String schema;
  late String backups;
  late String users;
  late String deletion;
  late String links;

  setUpAll(() {
    schema = _read('supabase/schema.sql');
    backups = _read(
      '$migrations/20261112000300_group_backups_lockdown.sql',
    );
    users = _read('$migrations/20261112000400_users_protected_columns.sql');
    deletion = _read('$migrations/20261112000500_fix_delete_user_account.sql');
    links = _read(
      '$migrations/20261112000600_invite_link_removed_member_guard.sql',
    );
  });

  test('B1 backups are read-only directly and restored through validated RPC',
      () {
    for (final sql in [backups, schema]) {
      expect(
        sql,
        matches(
          r'revoke insert, update, delete on table public\.group_backups'
          r'\s+from authenticated',
        ),
      );
      expect(
        sql,
        matches(
            r'grant select on table public\.group_backups to authenticated'),
      );
      expect(
        sql,
        isNot(
          matches(
            r'create policy "?group_backups_(insert_leader|update_owner|'
            r'update_restore_leader|delete_owner|delete_leader)\b',
          ),
        ),
      );
    }
    final restore = _function(backups, 'restore_group_from_backup');
    expect(_function(schema, 'restore_group_from_backup'), restore);
    expect(restore, contains('security definer'));
    expect(
      restore,
      isNot(matches(r"values\s*\([^;]*\(group_record\s*->>\s*'created_by'\)")),
    );
    expect(restore, contains('public.users'));
    expect(restore, matches(r"\bin\s*\(\s*'leader'\s*,\s*'member'\s*\)"));
    expect(
      restore,
      matches(
          r'update public\.events[\s\S]*?group_members[\s\S]*?events\.user_id'),
    );
    for (final name in [
      'archive_group_with_backup',
      'delete_group_with_backup',
      'permanently_delete_backup',
    ]) {
      expect(_function(schema, name), contains('security definer'));
    }
  });

  test('B1 only the backup RPCs mark snapshots as restorable', () {
    for (final sql in [backups, schema]) {
      expect(
        sql,
        matches(
          r'alter table public\.group_backups\s+add column if not exists '
          r'created_by_backup_rpc boolean not null default false;',
        ),
      );
      expect(
        sql,
        isNot(matches(
            r'update public\.group_backups\s+set created_by_backup_rpc')),
      );
      final restore = _function(sql, 'restore_group_from_backup');
      expect(
        restore,
        matches(
          r'if not backup_row\.created_by_backup_rpc then\s+'
          r"raise exception [^;]+;\s+end if;\s+"
          r'snapshot_payload := backup_row\.snapshot;',
        ),
      );
    }
    for (final name in [
      'archive_group_with_backup',
      'delete_group_with_backup'
    ]) {
      final createBackup = _function(backups, name);
      expect(_function(schema, name), createBackup);
      expect(
        createBackup,
        matches(
          r'insert into public\.group_backups \([^;]+created_by_backup_rpc\s*'
          r'\)\s+values \([^;]+\btrue\s*\)',
        ),
      );
    }
  });

  test('B1 owners are checked and FK detachments preserve backup contents', () {
    for (final name in [
      'restore_group_from_backup',
      'permanently_delete_backup'
    ]) {
      final rpc = _function(backups, name);
      expect(_function(schema, name), rpc);
      expect(
        rpc,
        contains('backup_row.created_by is distinct from current_user_id'),
      );
    }
    final guard = _function(backups, 'prevent_group_backup_immutable_changes');
    expect(_function(schema, 'prevent_group_backup_immutable_changes'), guard);
    expect(
      guard,
      matches(
        r'new\.group_id is null\s+and pg_trigger_depth\(\) > 1\s+'
        r'and not exists \(select 1 from public\.groups where id = old\.group_id\)',
      ),
    );
    expect(
      guard,
      matches(
        r'new\.created_by is null\s+and pg_trigger_depth\(\) > 1\s+'
        r'and not exists \(select 1 from public\.users where id = old\.created_by\)',
      ),
    );
    expect(guard, contains('new.snapshot is distinct from old.snapshot'));
    expect(
      guard,
      contains(
          'new.created_by_backup_rpc is distinct from old.created_by_backup_rpc'),
    );
  });

  test(
      'B2 client profile writes protect invite identity and allow Auth email sync',
      () {
    for (final sql in [users, schema]) {
      expect(
        sql,
        matches(r'create trigger users_protect_identity_columns\s+'
            r'before insert or update on public\.users'),
      );
      expect(
        sql,
        matches(
          r'create unique index if not exists users_invite_code_lower_uidx'
          r'\s+on public\.users\s*\(lower\(invite_code\)\)',
        ),
      );
    }
    final trigger = _function(users, 'protect_users_identity_columns');
    expect(_function(schema, 'protect_users_identity_columns'), trigger);
    for (final column in ['email', 'invite_code', 'id']) {
      expect(trigger, contains('new.$column is distinct from old.$column'));
    }
    expect(trigger, contains('new.id is distinct from auth.uid()'));
    expect(
      trigger,
      matches(
        r"if tg_op = 'INSERT' then\s+"
        r'if not public\.matches_current_auth_email\(new\.email\)[\s\S]+?'
        r'new\.invite_code := .+gen_random_uuid\(\)',
      ),
    );
    expect(
      trigger,
      matches(
        r'new\.email is distinct from old\.email\s+'
        r'and not public\.matches_current_auth_email\(new\.email\)',
      ),
    );
    final matchesEmail = _function(users, 'matches_current_auth_email');
    expect(_function(schema, 'matches_current_auth_email'), matchesEmail);
    expect(matchesEmail, contains('from auth.users'));
    expect(matchesEmail, contains('where id = auth.uid()'));
    expect(matchesEmail, contains('email is not distinct from profile_email'));
    for (final sql in [users, schema]) {
      expect(
        sql,
        contains(
          'revoke delete, truncate on table public.users from public, anon, authenticated;',
        ),
      );
      expect(sql, isNot(contains('create policy "users_delete_own"')));
      expect(
        sql,
        matches(
          r'create policy "users_insert_own"\s+on public\.users\s+'
          r'for insert\s+to authenticated\s+with check \(auth\.uid\(\) = id\)',
        ),
      );
    }
    final inviteTarget = _function(users, 'is_group_invite_target');
    expect(_function(schema, 'is_group_invite_target'), inviteTarget);
    expect(inviteTarget, matches(r"auth\.jwt\(\)\s*->>\s*'email'"));
    expect(inviteTarget, isNot(matches(r'lower\((?:\w+\.)?email\)')));
  });

  test('B3 account cleanup respects all owned groups and delegation columns',
      () {
    final cleanup = _function(deletion, 'delete_user_account');
    expect(_function(schema, 'delete_user_account'), cleanup);
    expect(cleanup, contains('delegator_user_id'));
    expect(cleanup, contains('delegate_user_id'));
    expect(cleanup, isNot(matches(r'\b(?:delegated_by|delegated_to)\b')));
    expect(cleanup, matches(r'created_by\s*=\s*target_user_id'));
    expect(cleanup, isNot(matches(r"\bstatus\s*=\s*'active'")));
    expect(cleanup, matches(r"'status'\s*,\s*(?:\w+\.)?status"));
    expect(cleanup, contains("'leader_groups'"));
  });

  test('B3 cleanup leaves email-only early-bird rows without account proof',
      () {
    for (final sql in [deletion, schema]) {
      final cleanup = _function(sql, 'delete_user_account');
      expect(cleanup, isNot(matches(r'\bselect\s+email\b')));
      expect(
        cleanup,
        isNot(matches(r'\bdelete\s+from\s+planflow\.early_bird_emails\b')),
      );
    }
  });

  test('B3 account deletion keeps backup records and shared schedules', () {
    for (final sql in [deletion, schema]) {
      final cleanup = _function(sql, 'delete_user_account');
      expect(cleanup, isNot(matches(r'delete from public\.group_backups')));
      expect(
        cleanup,
        contains(
            "current_setting('role', true) is distinct from 'service_role'"),
      );
    }
    expect(
      schema,
      matches(
        r'create table if not exists public\.user_backups[^;]*'
        r'user_id uuid references public\.users \(id\) on delete set null',
      ),
    );
    expect(
      deletion,
      contains('foreign key (user_id) references public.users (id) on delete set null'),
    );
    expect(
      deletion,
      contains('alter column user_id drop not null'),
    );
    expect(
      schema,
      matches(
        r'create policy "user_backups_select_own"\s+'
        r'on public\.user_backups\s+for select\s+'
        r'using \(auth\.uid\(\) = user_id\)',
      ),
    );
    expect(
      _function(schema, 'restore_user_backup'),
      contains('and user_id = uid'),
    );
    for (final sql in [deletion, schema]) {
      final cleanup = _function(sql, 'delete_user_account');
      expect(cleanup, isNot(matches(r'delete from public\.user_backups')));
    }
    expect(
      schema,
      matches(
        r'create table if not exists public\.group_backups[^;]*'
        r'created_by uuid references public\.users \(id\) on delete set null',
      ),
    );
    final guard = _function(deletion, 'prevent_group_event_immutable_changes');
    expect(_function(schema, 'prevent_group_event_immutable_changes'), guard);
    expect(
      guard,
      matches(
        r'new\.created_by is null\s+and pg_trigger_depth\(\) > 1\s+'
        r'and not exists \(select 1 from public\.users where id = old\.created_by\)',
      ),
    );
  });

  test(
      'B3 received invite history survives without a target and stays terminal',
      () {
    final guard = _function(deletion, 'prevent_group_invite_immutable_changes');
    expect(_function(schema, 'prevent_group_invite_immutable_changes'), guard);
    for (final sql in [deletion, schema]) {
      expect(
        sql,
        matches(
          r'constraint group_invites_target_check\s+check \(\s*'
          r'num_nonnulls\(invited_user_id, invited_email, invited_invite_code\) = 1'
          r'[\s\S]*?num_nonnulls\(invited_user_id, invited_email, invited_invite_code\) = 0'
          r"\s+and status <> 'pending'",
        ),
      );
    }
    expect(
      guard,
      matches(
        r"if tg_op = 'INSERT' then\s+if num_nonnulls\(new\.invited_user_id, "
        r'new\.invited_email, new\.invited_invite_code\) <> 1 then',
      ),
    );
    expect(
      guard,
      matches(
        r'new\.invited_user_id is not null\s+or pg_trigger_depth\(\) <= 1\s+'
        r'or exists \(select 1 from public\.users where id = old\.invited_user_id\)',
      ),
    );
    expect(
      guard,
      matches(
        r"if old\.status = 'pending' then\s+new\.status := 'expired';"
        r'\s+new\.expired_at := now\(\);\s+else\s+new\.status := old\.status;',
      ),
    );
    expect(guard, contains('detached group_invites cannot change status'));
    final restore = _function(backups, 'restore_group_from_backup');
    expect(
      restore,
      matches(
        r'or num_nonnulls\(\s*'
        r"nullif\(invite_record->>'invited_user_id', ''\),\s*"
        r"invite_record->>'invited_email',\s*"
        r"invite_record->>'invited_invite_code'\s*\) <> 1",
      ),
    );
  });

  test('B4 link joins distinguish removals and leaders rotate the link', () {
    final join = _function(links, 'accept_group_invite_link');
    expect(_function(schema, 'accept_group_invite_link'), join);
    expect(join, contains("'removed'"));
    expect(join, contains('removed_by'));
    expect(join, contains('리더의 초대가 필요합니다.'));

    final remove = _function(links, 'remove_group_member');
    expect(_function(schema, 'remove_group_member'), remove);
    expect(remove, matches(r'\binvite_token\s*=\s*default\b'));
  });

  test('B4 removal remains recorded when the remover reference is cleared', () {
    final keepRemoval = _function(links, 'protect_member_reinvite_requirement');
    expect(
        _function(schema, 'protect_member_reinvite_requirement'), keepRemoval);
    for (final sql in [backups, schema]) {
      expect(
        sql,
        matches(
          r'alter table public\.group_members\s+add column if not exists '
          r'requires_explicit_reinvite boolean not null default false',
        ),
      );
    }
    for (final sql in [links, schema]) {
      expect(
        sql,
        matches(
          r'create trigger group_members_protect_reinvite_requirement\s+'
          r'before insert or update on public\.group_members',
        ),
      );
    }
    expect(keepRemoval, contains('new.requires_explicit_reinvite := false'));
    expect(
      keepRemoval,
      matches(r'old\.requires_explicit_reinvite\s+or\s+'
          r'coalesce\(old\.removed_by <> old\.user_id, false\)'),
    );
    expect(
      _function(links, 'accept_group_invite_link'),
      matches(r"status = 'removed'\s+and "
          r'\(\s*requires_explicit_reinvite\s+or\s+'
          r'\(removed_by is not null and removed_by <> auth\.uid\(\)\)'),
    );
    expect(
      _function(links, 'remove_group_member'),
      contains('requires_explicit_reinvite = true'),
    );
  });

  test('B4 backup restores the server-derived reinvite requirement', () {
    final capture = _function(links, 'capture_backup_reinvite_requirements');
    expect(_function(schema, 'capture_backup_reinvite_requirements'), capture);
    for (final sql in [backups, schema]) {
      expect(
        sql,
        matches(
          r'alter table public\.group_backups\s+add column if not exists '
          r'reinvite_required_user_ids uuid\[\] not null',
        ),
      );
    }
    for (final sql in [links, schema]) {
      expect(
        sql,
        matches(
          r'create trigger group_backups_capture_reinvite_requirements\s+'
          r'before insert or update of reinvite_required_user_ids '
          r'on public\.group_backups',
        ),
      );
    }
    expect(capture, contains('old.reinvite_required_user_ids'));
    expect(capture, contains('from public.group_members as member'));
    expect(capture, contains('member.group_id = new.group_id'));
    expect(capture, contains("member.status = 'removed'"));
    expect(capture, contains('member.requires_explicit_reinvite'));
    final restore = _function(backups, 'restore_group_from_backup');
    expect(
      restore,
      contains(
          'restored_member_id = any(backup_row.reinvite_required_user_ids)'),
    );
    expect(
      restore,
      isNot(matches(r"member_record\s*->+?\s*'requires_explicit_reinvite'")),
    );
  });

  test('Flutter has no direct group backup write methods', () {
    final names = RegExp(r'\b(createArchiveBackup|markBackupRestored)\b');
    final offenders = Directory('lib')
        .listSync(recursive: true, followLinks: false)
        .whereType<File>()
        .where((file) => file.path.endsWith('.dart'))
        .where((file) => names.hasMatch(file.readAsStringSync()))
        .map((file) => file.path)
        .toList();
    expect(offenders, isEmpty);
  });

  test('account cleanup failure does not expose provider error details', () {
    final source = _read('supabase/functions/delete-account/index.ts');
    expect(
      source,
      isNot(matches(r'\b(?:rpcResponse\.error|deleteAuthError)\??\.'
          r'(?:message|details|hint|stack)\b')),
    );
    expect(
      source,
      isNot(matches(r'\bconsole\.error\([^;]*(?:rpcResponse\.error|'
          r'deleteAuthError)\s*[,)]')),
    );
    expect(source, contains('const requestId = crypto.randomUUID()'));
    expect(
      source,
      matches(r'error: "data_delete_failed",\s*'
          r'message: dataDeleteFailureMessage,\s*requestId,'),
    );
  });
}
