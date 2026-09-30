import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('group sync forward migration contracts', () {
    final syncMigration = File(
      'supabase/migrations/20260928075255_planflow_group_event_sync_and_backup_fix.sql',
    ).readAsStringSync().toLowerCase();
    final inviteMigration = File(
      'supabase/migrations/20260928084034_reaccept_removed_group_members.sql',
    ).readAsStringSync().toLowerCase();
    final deletionNoticeMigration = File(
      'supabase/migrations/20260928161356_group_deletion_notices.sql',
    ).readAsStringSync().toLowerCase();
    final schema = File('supabase/schema.sql').readAsStringSync().toLowerCase();

    test('mirrors nullable personal end time with a non-null group fallback',
        () {
      expect(
        syncMigration,
        contains('end_at = coalesce(new.end_at, new.start_at)'),
      );
      expect(
        syncMigration,
        contains('end_at = coalesce(event_row.end_at, event_row.start_at)'),
      );
    });

    test('repairs historical backup output to use removed_at, not left_at', () {
      expect(syncMigration, contains("left_at'', group_members.left_at'"));
      expect(
          syncMigration, contains("removed_at'', group_members.removed_at'"));
    });

    test('invite reactivation is target-authorized and limited to removed rows',
        () {
      // The exact non-CASCADE drop handles both legacy schema result types.
      expect(
        inviteMigration,
        contains('drop function if exists public.accept_group_invite(uuid);'),
      );
      expect(inviteMigration, isNot(contains('drop function ... cascade')));
      expect(
        inviteMigration,
        contains('create function public.accept_group_invite'),
      );
      expect(inviteMigration, contains('returns uuid'));
      expect(inviteMigration, contains('security definer'));
      expect(inviteMigration, contains('set search_path = public, pg_temp'));
      expect(inviteMigration, contains('return member_id'));
      expect(
        schema,
        contains('create or replace function public.accept_group_invite'),
      );
      expect(schema, contains('returns uuid'));
      expect(schema, contains('security definer'));
      expect(inviteMigration, contains('auth.uid()'));
      expect(inviteMigration, contains('public.is_group_invite_target('));
      expect(inviteMigration, contains("and status = 'removed'"));
      expect(inviteMigration, contains("status = 'active'"));
      expect(inviteMigration, contains('removed_at = null'));
      expect(inviteMigration, contains('for update'));
    });

    test('validated acceptance RPC atomically reactivates membership', () {
      for (final source in [inviteMigration, schema]) {
        final normalizedSource = source.replaceAll('\r\n', '\n');
        var functionStart = normalizedSource.indexOf(
          'create function public.accept_group_invite',
        );
        if (functionStart < 0) {
          functionStart = normalizedSource.indexOf(
            'create or replace function public.accept_group_invite',
          );
        }
        final functionEnd = normalizedSource.indexOf('\n\$\$;', functionStart);
        expect(functionStart, isNonNegative);
        expect(functionEnd, greaterThan(functionStart));
        final functionBody =
            normalizedSource.substring(functionStart, functionEnd);
        expect(
          functionBody.indexOf('update public.group_invites'),
          lessThan(functionBody.indexOf('insert into public.group_members')),
        );
        expect(functionBody, contains("set status = 'accepted'"));
        expect(functionBody, contains('set search_path = public, pg_temp'));
        expect(functionBody, contains('security definer'));
        expect(functionBody, contains('public.is_group_invite_target('));
        final groupLock = functionBody.indexOf(
          'from public.groups\n   where id = invite_group_id\n   for update',
        );
        final inviteLock = functionBody.indexOf(
          'from public.group_invites\n   where id = invite_id_input\n   for update',
        );
        expect(groupLock, isNonNegative);
        expect(inviteLock, greaterThan(groupLock));
        expect(
          functionBody,
          contains('invite_row.group_id is distinct from invite_group_id'),
        );
        expect(functionBody, contains("if locked_group.status <> 'active'"));
        expect(functionBody, contains("status = 'removed'"));
        expect(functionBody, contains('removed_by = null'));
        expect(
            functionBody, isNot(contains('on conflict (group_id, user_id)')));
      }
    });

    test('archive and delete lock the group before mutating invitations', () {
      for (final rpcName in [
        'archive_group_with_backup',
        'delete_group_with_backup',
      ]) {
        final normalizedSchema = schema.replaceAll('\r\n', '\n');
        final rpcStart = normalizedSchema.indexOf('function public.$rpcName');
        final nextRpc = normalizedSchema.indexOf(
          '\ncreate or replace function ',
          rpcStart + 1,
        );
        expect(rpcStart, isNonNegative);
        final rpcBody = normalizedSchema.substring(
          rpcStart,
          nextRpc < 0 ? schema.length : nextRpc,
        );
        final groupLock = rpcBody.indexOf(
          'from public.groups\n   where id = group_id_input\n   for update',
        );
        expect(groupLock, isNonNegative, reason: rpcName);
        final inviteMutation = rpcBody.indexOf('update public.group_invites');
        if (inviteMutation >= 0) {
          expect(inviteMutation, greaterThan(groupLock), reason: rpcName);
        }
      }
    });

    test('group deletion notices are durable, recipient-only, and delete-only',
        () {
      for (final source in [deletionNoticeMigration, schema]) {
        final normalized = source.replaceAll('\r\n', '\n');
        final tableStart = normalized.indexOf(
          'create table if not exists public.group_deletion_notices',
        );
        final tableEnd = normalized.indexOf('\n);', tableStart);
        expect(tableStart, isNonNegative);
        expect(tableEnd, greaterThan(tableStart));
        final tableDefinition = normalized.substring(tableStart, tableEnd);
        expect(tableDefinition, contains('deleted_group_id uuid not null'));
        expect(tableDefinition, isNot(contains('references public.groups')));
        expect(tableDefinition, contains('acknowledged_at timestamptz'));

        expect(normalized, contains('enable row level security'));
        expect(
            normalized,
            contains(
                'grant select on table public.group_deletion_notices to authenticated'));
        expect(
            normalized,
            contains(
                'grant update (acknowledged_at) on table public.group_deletion_notices to authenticated'));
        expect(normalized, contains('recipient_user_id = auth.uid()'));
        expect(normalized, contains('acknowledged_at is null'));
        expect(normalized, contains('acknowledged_at is not null'));

        final triggerStart = normalized.indexOf(
          'create or replace function public.capture_group_deletion_notices',
        );
        final triggerEnd = normalized.indexOf('\n\$\$;', triggerStart);
        expect(triggerStart, isNonNegative);
        expect(triggerEnd, greaterThan(triggerStart));
        final triggerFunction = normalized.substring(triggerStart, triggerEnd);
        expect(triggerFunction, contains('security definer'));
        expect(triggerFunction, contains('set search_path = public, pg_temp'));
        expect(triggerFunction,
            contains('public.is_group_leader(old.id, auth.uid())'));
        expect(triggerFunction, contains("gm.status = 'active'"));
        expect(triggerFunction, contains('gm.removed_at is null'));
        expect(triggerFunction, contains('gm.user_id <> auth.uid()'));
        expect(triggerFunction,
            contains('insert into public.group_deletion_notices'));
        expect(
          normalized,
          contains('before delete on public.groups'),
          reason: 'archive is an UPDATE and must not create deletion notices',
        );
        expect(normalized, isNot(contains('after update on public.groups')));
      }
    });

    test('invitee reads only their own invite and group while pending', () {
      for (final source in [inviteMigration, schema]) {
        expect(
            source,
            contains(
                'drop policy if exists "group_members_update_self_invite_reactivation"'));
        expect(
            source, contains('drop policy if exists "groups_select_member"'));
        final normalizedSource = source.replaceAll('\r\n', '\n');
        final groupSelectStart = normalizedSource.indexOf(
          'create policy "groups_select_member"',
        );
        final groupSelectEnd = normalizedSource.indexOf(
          'create policy ',
          groupSelectStart + 1,
        );
        expect(groupSelectStart, isNonNegative);
        expect(groupSelectEnd, greaterThan(groupSelectStart));
        final groupSelectPolicy = normalizedSource.substring(
          groupSelectStart,
          groupSelectEnd,
        );
        expect(groupSelectPolicy, contains("status = 'active'"));
        expect(
            groupSelectPolicy, contains('select 1 from public.group_invites'));
        expect(groupSelectPolicy, contains("group_invites.status = 'pending'"));
        expect(groupSelectPolicy, contains('public.is_group_invite_target('));
        expect(
            source,
            contains(
                'public.is_group_leader(group_invites.group_id, auth.uid())'));
        expect(source, contains('user_id = auth.uid()'));
        expect(source, contains("status in ('pending', 'accepted')"));
        expect(source, contains('group_invites.acted_by = auth.uid()'));
        expect(source, contains('public.is_group_invite_target('));
      }
    });

    test('personal event and selected group copies share one atomic RPC path',
        () {
      for (final source in [syncMigration, schema]) {
        final functionStart = source.indexOf(
          'create or replace function public.create_personal_event_with_groups',
        );
        final functionEnd = source.indexOf('\n\$\$;', functionStart);
        expect(functionStart, isNonNegative);
        expect(functionEnd, greaterThan(functionStart));
        final functionBody = source.substring(functionStart, functionEnd);
        expect(functionBody, contains('security invoker'));
        expect(functionBody, contains('auth.uid()'));
        expect(functionBody, contains('event_row.user_id <> caller_id'));
        expect(functionBody, contains('insert into public.events'));
        expect(
            functionBody, contains('public.share_personal_event_with_groups'));
        expect(
          functionBody.indexOf('insert into public.events'),
          lessThan(
              functionBody.indexOf('public.share_personal_event_with_groups')),
        );
        expect(functionBody, contains('not all requested group copies'));
        expect(functionBody, contains('event id is owned by another user'));
      }

      final repository = File('lib/data/repositories/event_repository.dart')
          .readAsStringSync()
          .toLowerCase();
      expect(repository, contains("'create_personal_event_with_groups'"));
      final screen = File('lib/screens/event/event_edit_screen.dart')
          .readAsStringSync()
          .toLowerCase();
      expect(screen, contains('createeventwithgroupshares'));
      expect(screen, contains('_pendingatomiccreateeventid'),
          reason: 'the client keeps a stable event id for safe retries');
    });

    test(
        'existing event edit and group share are one owner-checked transaction',
        () {
      for (final source in [syncMigration, schema]) {
        final functionStart = source.indexOf(
          'create or replace function public.update_personal_event_with_groups',
        );
        final functionEnd = source.indexOf('\n\$\$;', functionStart);
        expect(functionStart, isNonNegative);
        expect(functionEnd, greaterThan(functionStart));
        final functionBody = source.substring(functionStart, functionEnd);
        expect(functionBody, contains('security invoker'));
        expect(functionBody, contains('auth.uid()'));
        expect(functionBody, contains('event_row.user_id <> caller_id'));
        expect(functionBody, contains('where id = event_row.id'));
        expect(functionBody, contains('where id = saved_event.id'));
        expect(
            functionBody, contains('public.share_personal_event_with_groups'));
        expect(
          functionBody.indexOf('update public.events'),
          lessThan(
              functionBody.indexOf('public.share_personal_event_with_groups')),
        );
        expect(functionBody, contains('not all requested group copies'));
      }

      final repository = File('lib/data/repositories/event_repository.dart')
          .readAsStringSync()
          .toLowerCase();
      expect(repository, contains("'update_personal_event_with_groups'"));
      final screen = File('lib/screens/event/event_edit_screen.dart')
          .readAsStringSync()
          .toLowerCase();
      expect(screen, contains('updateeventwithgroupshares'));
      expect(screen, contains('updateandshareatomically'));
    });

    test(
        'backup snapshots and restore preserve reports and removed membership history',
        () {
      for (final source in [syncMigration, schema]) {
        expect(source, contains("'removed_by', group_members.removed_by"));
        expect(source, contains("'event_reports'"));
        expect(source, contains('public.group_event_reports'));
        expect(source, contains("snapshot_payload->'all_members'"));
        expect(source, contains("snapshot_payload->'event_reports'"));
        expect(
            source,
            contains(
                'event_old_to_new->>(comment_record->>\'group_event_id\')'));
      }
    });

    test(
        'archiving cancels pending invitations after recording backup snapshot',
        () {
      expect(syncMigration, contains("set status = 'cancelled'"));
      expect(syncMigration, contains("set status = 'archived'"));
      expect(schema, contains("set status = 'cancelled'"));
      expect(schema, contains("set status = 'archived'"));
      expect(inviteMigration, contains("status = 'active'"));
    });
  });
}
