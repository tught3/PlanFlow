import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('group_event_reports schema', () {
    final schema = File('supabase/schema.sql').readAsStringSync();
    final migration = File(
      'supabase/migrations/20260919000000_group_event_reports.sql',
    ).readAsStringSync();

    for (final raw in <String>[schema, migration]) {
      // schema.sql은 CRLF로 저장되어 있어 줄바꿈을 정규화해서 단언한다.
      final sql = raw.replaceAll('\r\n', '\n');
      test('contains table, columns and checks', () {
        expect(sql, contains('create table if not exists public.group_event_reports'));
        expect(sql, contains('reporter_id uuid not null references public.users'));
        expect(
          sql,
          contains(
            'group_event_id uuid not null references public.group_events (id) on delete cascade',
          ),
        );
        expect(sql, contains('group_id uuid not null references public.groups'));
        expect(
          sql,
          contains(
            "reason text not null check (reason in ('inappropriate', 'spam', 'harassment', 'other'))",
          ),
        );
        expect(sql, contains('detail text'));
        expect(
          sql,
          contains(
            "status text not null default 'new' check (status in ('new', 'triaged', 'dismissed', 'actioned'))",
          ),
        );
        expect(sql, contains('content_owner_id uuid references public.users'));
        expect(sql, contains('created_at timestamptz not null default now()'));
      });

      test('enables RLS before policies', () {
        final enableIndex = sql.indexOf(
          'alter table public.group_event_reports enable row level security',
        );
        expect(enableIndex, greaterThanOrEqualTo(0));
        final firstPolicyIndex = sql.indexOf(
          'create policy "group_event_reports_insert_member"',
        );
        expect(firstPolicyIndex, greaterThan(enableIndex));
      });

      test('insert policy validates reporter, membership and active event', () {
        expect(
          sql,
          contains('reporter_id = auth.uid()'),
        );
        expect(
          sql,
          contains('public.is_group_member(group_id, auth.uid())'),
        );
        expect(
          sql,
          contains("ge.id = group_event_id\n        and ge.group_id = group_id\n        and ge.status = 'active'"),
        );
      });

      test('select/update are admin-email only (no user select)', () {
        expect(
          sql,
          contains('create policy "group_event_reports_select_admin"'),
        );
        expect(
          sql,
          contains('create policy "group_event_reports_update_status_admin"'),
        );
        expect(sql, contains("'tught3@naver.com'"));
        expect(sql, contains("'tught3@gmail.com'"));
        // 신고는 write-only: 신고자 본인 select 정책이 있으면 안 된다.
        expect(
          sql,
          isNot(contains('create policy "group_event_reports_select_own"')),
        );
        // 삭제 정책도 사용자에게는 없다.
        expect(
          sql,
          isNot(contains('create policy "group_event_reports_delete"')),
        );
      });

      test('has unique spam-guard index', () {
        expect(
          sql,
          contains(
            'create unique index if not exists group_event_reports_reporter_event_uniq',
          ),
        );
        expect(
          sql,
          contains('on public.group_event_reports (reporter_id, group_event_id)'),
        );
      });
    }
  });
}
