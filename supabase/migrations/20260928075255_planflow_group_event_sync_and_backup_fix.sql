-- Forward-only repair for group backups and linked personal/group schedules.
-- This migration is intentionally source-only until separately authorized and
-- reviewed against the target database schema.

alter table public.group_events
  add column if not exists is_critical boolean not null default false,
  add column if not exists use_strong_alarm boolean not null default false,
  add column if not exists recurrence_rule text,
  add column if not exists is_multi_day boolean not null default false;

-- The event model already writes this field; keep fresh schemas and upgraded
-- deployments aligned before the link trigger/RPC references it.
alter table public.events
  add column if not exists use_strong_alarm boolean not null default false;

-- Replace only the stale field reference in the already-deployed backup RPCs.
-- CREATE OR REPLACE preserves each function's ACL and security attributes.
do $$
declare
  function_oid oid;
  function_definition text;
  repaired_definition text;
  history_definition text;
  reports_definition text;
  archive_definition text;
  function_signature regprocedure;
  history_source text := $source$            'removed_at', group_members.removed_at,
            'created_at', group_members.created_at$source$;
  history_target text := $target$            'removed_at', group_members.removed_at,
            'removed_by', group_members.removed_by,
            'created_at', group_members.created_at$target$;
  reports_source text := $source$    'event_comments',$source$;
  reports_target text := $target$    'event_reports',
    coalesce(
      (
        select jsonb_agg(to_jsonb(group_event_reports))
        from public.group_event_reports
        where group_event_reports.group_id = group_row.id
      ),
      '[]'::jsonb
    ),
    'event_comments',$target$;
  archive_invites_source text := $source$  update public.groups
     set status = 'archived',$source$;
  archive_invites_target text := $target$  update public.group_invites
     set status = 'cancelled',
         cancelled_at = now(),
         acted_by = current_user_id
   where group_id = group_row.id
     and status = 'pending';

  update public.groups
     set status = 'archived',$target$;
begin
  foreach function_signature in array array[
    'public.archive_group_with_backup(uuid)'::regprocedure,
    'public.delete_group_with_backup(uuid)'::regprocedure
  ] loop
    function_oid := function_signature::oid;
    -- pg_get_functiondef may preserve CRLF from a function installed through
    -- a Windows/client migration. Normalize before matching multiline blocks.
    function_definition := replace(
      pg_get_functiondef(function_oid),
      E'\r\n',
      E'\n'
    );
    if position('group_members.left_at' in function_definition) = 0 then
      raise exception 'Expected stale group_members.left_at reference in %',
        function_signature;
    end if;
    repaired_definition := replace(
      function_definition,
      '''left_at'', group_members.left_at',
      '''removed_at'', group_members.removed_at'
    );
    if repaired_definition = function_definition then
      raise exception 'Could not repair backup function %', function_signature;
    end if;
    history_definition := replace(repaired_definition, history_source, history_target);
    if history_definition = repaired_definition then
      raise exception 'Could not add removed_by to backup function %', function_signature;
    end if;
    reports_definition := replace(history_definition, reports_source, reports_target);
    if reports_definition = history_definition then
      raise exception 'Could not add event_reports snapshot to %', function_signature;
    end if;
    if function_signature = 'public.archive_group_with_backup(uuid)'::regprocedure then
      archive_definition := replace(
        reports_definition,
        archive_invites_source,
        archive_invites_target
      );
      if archive_definition = reports_definition then
        raise exception 'Could not cancel pending invitations while archiving %',
          function_signature;
      end if;
      reports_definition := archive_definition;
    end if;
    execute reports_definition;
  end loop;
end;
$$;

-- Keep restore compatible with both pre-change snapshots (missing keys become
-- the existing defaults) and new snapshots. The personal_event_id is the
-- canonical N-to-1 link; events.group_event_id remains a legacy single-link.
do $$
declare
  restore_oid oid := 'public.restore_group_from_backup(uuid)'::regprocedure::oid;
  definition text := replace(
    pg_get_functiondef(restore_oid),
    E'\r\n',
    E'\n'
  );
  old_insert text := $old$
      recurrence_until,
      created_by,
      updated_by,
      cancelled_at,
      cancelled_by,
      personal_event_id,
      status,$old$;
  new_insert text := $new$
      recurrence_until,
      is_critical,
      use_strong_alarm,
      recurrence_rule,
      is_multi_day,
      created_by,
      updated_by,
      cancelled_at,
      cancelled_by,
      personal_event_id,
      status,$new$;
  old_values text := $old$
      (event_record->>'recurrence_until')::timestamptz,
      (event_record->>'created_by')::uuid,$old$;
  new_values text := $new$
      (event_record->>'recurrence_until')::timestamptz,
      coalesce((event_record->>'is_critical')::boolean, false),
      coalesce((event_record->>'use_strong_alarm')::boolean, false),
      event_record->>'recurrence_rule',
      coalesce((event_record->>'is_multi_day')::boolean, false),
      (event_record->>'created_by')::uuid,$new$;
  old_personal_id text := $old$      null,
      coalesce(event_record->>'status', 'active'),$old$;
  new_personal_id text := $new$      nullif(event_record->>'personal_event_id', '')::uuid,
      coalesce(event_record->>'status', 'active'),$new$;
  old_restore_link text := $old$       set personal_event_id = (
         select id from public.events
         where group_event_id = new_event_id
         limit 1
       )$old$;
  new_restore_link text := $new$       set personal_event_id = coalesce(
         ge.personal_event_id,
         (
           select id from public.events
           where group_event_id = new_event_id
           limit 1
         )
       )$new$;
  old_member_array text := $old$select jsonb_array_elements(snapshot_payload->'active_members')$old$;
  new_member_array text := $new$select jsonb_array_elements(
      coalesce(snapshot_payload->'all_members', snapshot_payload->'active_members')
    )$new$;
  old_member_columns text := $old$      joined_at,
      created_at,
      updated_at
    )$old$;
  new_member_columns text := $new$      joined_at,
      removed_at,
      removed_by,
      created_at,
      updated_at
    )$new$;
  old_member_values text := $old$      'active',
      coalesce((member_record->>'joined_at')::timestamptz, now()),
      coalesce((member_record->>'created_at')::timestamptz, now()),$old$;
  new_member_values text := $new$      coalesce(member_record->>'status', 'active'),
      coalesce((member_record->>'joined_at')::timestamptz, now()),
      (member_record->>'removed_at')::timestamptz,
      nullif(member_record->>'removed_by', '')::uuid,
      coalesce((member_record->>'created_at')::timestamptz, now()),$new$;
  old_comment_loop text := $old$  for comment_record in
    select jsonb_array_elements(snapshot_payload->'event_comments')$old$;
  new_comment_loop text := $new$  for comment_record in
    select jsonb_array_elements(snapshot_payload->'event_reports')
  loop
    if (event_old_to_new ? (comment_record->>'group_event_id')) then
      insert into public.group_event_reports (
        id, reporter_id, group_event_id, group_id, reason, detail,
        status, content_owner_id, created_at
      )
      values (
        gen_random_uuid(),
        (comment_record->>'reporter_id')::uuid,
        (event_old_to_new->>(comment_record->>'group_event_id'))::uuid,
        new_group_id,
        comment_record->>'reason',
        comment_record->>'detail',
        coalesce(comment_record->>'status', 'new'),
        nullif(comment_record->>'content_owner_id', '')::uuid,
        coalesce((comment_record->>'created_at')::timestamptz, now())
      )
      on conflict do nothing;
    end if;
  end loop;

  for comment_record in
    select jsonb_array_elements(snapshot_payload->'event_comments')$new$;
begin
  if position(old_insert in definition) = 0
    or position(old_values in definition) = 0
    or position(old_personal_id in definition) = 0
    or position(old_restore_link in definition) = 0 then
    raise exception 'restore_group_from_backup contract changed; refusing unsafe rewrite';
  end if;
  definition := replace(definition, old_insert, new_insert);
  definition := replace(definition, old_values, new_values);
  definition := replace(definition, old_personal_id, new_personal_id);
  definition := replace(definition, old_restore_link, new_restore_link);
  if position(old_member_array in definition) = 0
    or position(old_member_columns in definition) = 0
    or position(old_member_values in definition) = 0
    or position(old_comment_loop in definition) = 0 then
    raise exception 'restore_group_from_backup membership/report contract changed; refusing unsafe rewrite';
  end if;
  definition := replace(definition, old_member_array, new_member_array);
  definition := replace(definition, old_member_columns, new_member_columns);
  definition := replace(definition, old_member_values, new_member_values);
  definition := replace(definition, old_comment_loop, new_comment_loop);
  execute definition;
end;
$$;

-- Create a selected set of group copies atomically and idempotently. This RPC
-- intentionally requires caller-owned personal events and active memberships.
create or replace function public.share_personal_event_with_groups(
  p_personal_event_id uuid,
  p_group_ids uuid[]
)
returns setof public.group_events
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  caller_id uuid := auth.uid();
  event_row public.events%rowtype;
  requested_count integer;
  allowed_count integer;
begin
  if caller_id is null then
    raise exception 'authentication required';
  end if;
  if p_group_ids is null or cardinality(p_group_ids) = 0 then
    raise exception 'at least one group is required';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(p_personal_event_id::text, 0));
  select * into event_row
    from public.events
   where id = p_personal_event_id and user_id = caller_id
   for update;
  if not found then
    raise exception 'owned personal event not found';
  end if;

  select count(distinct requested.group_id), count(distinct eligible.group_id)
    into requested_count, allowed_count
    from unnest(p_group_ids) as requested(group_id)
    left join lateral (
      select g.id as group_id
        from public.groups g
        join public.group_members gm on gm.group_id = g.id
       where g.id = requested.group_id
         and g.status = 'active'
         and gm.user_id = caller_id
         and gm.status = 'active'
    ) eligible on true;
  if requested_count = 0 or allowed_count <> requested_count then
    raise exception 'caller must be an active member of every target group';
  end if;

  if exists (
    select 1 from public.group_events ge
     where ge.personal_event_id = p_personal_event_id
       and ge.group_id = any(p_group_ids)
       and ge.status = 'active'
       and ge.created_by <> caller_id
  ) then
    raise exception 'linked group event is owned by another user';
  end if;

  update public.group_events ge
     set title = event_row.title,
         description = event_row.memo,
         location = event_row.location,
         start_at = event_row.start_at,
         end_at = coalesce(event_row.end_at, event_row.start_at),
         all_day = event_row.is_all_day,
         is_multi_day = event_row.is_multi_day,
         is_critical = event_row.is_critical,
         use_strong_alarm = event_row.use_strong_alarm,
         recurrence_rule = event_row.recurrence_rule,
         recurrence_type = case
           when coalesce(event_row.recurrence_rule, '') = '' then 'none'
           when upper(event_row.recurrence_rule) like '%FREQ=DAILY%' then 'daily'
           when upper(event_row.recurrence_rule) like '%FREQ=WEEKLY%' then 'weekly'
           when upper(event_row.recurrence_rule) like '%FREQ=MONTHLY%' then 'monthly'
           else 'none'
         end,
         recurrence_until = null,
         updated_by = caller_id
   where ge.personal_event_id = p_personal_event_id
     and ge.group_id = any(p_group_ids)
     and ge.status = 'active'
     and ge.created_by = caller_id;

  insert into public.group_events (
    group_id, title, description, location, start_at, end_at, all_day,
    is_multi_day, is_critical, use_strong_alarm, recurrence_rule,
    recurrence_type, recurrence_until, created_by, updated_by,
    personal_event_id, status
  )
  select requested.group_id, event_row.title, event_row.memo,
         event_row.location, event_row.start_at,
         coalesce(event_row.end_at, event_row.start_at), event_row.is_all_day,
         event_row.is_multi_day, event_row.is_critical,
         event_row.use_strong_alarm, event_row.recurrence_rule,
         case
           when coalesce(event_row.recurrence_rule, '') = '' then 'none'
           when upper(event_row.recurrence_rule) like '%FREQ=DAILY%' then 'daily'
           when upper(event_row.recurrence_rule) like '%FREQ=WEEKLY%' then 'weekly'
           when upper(event_row.recurrence_rule) like '%FREQ=MONTHLY%' then 'monthly'
           else 'none'
         end,
         null, caller_id, caller_id, p_personal_event_id, 'active'
    from (select distinct unnest(p_group_ids) as group_id) requested
   where not exists (
     select 1 from public.group_events ge
      where ge.personal_event_id = p_personal_event_id
        and ge.group_id = requested.group_id
        and ge.status = 'active'
   );

  return query
    select ge.* from public.group_events ge
     where ge.personal_event_id = p_personal_event_id
       and ge.group_id = any(p_group_ids)
       and ge.status = 'active'
       and ge.created_by = caller_id
     order by ge.created_at, ge.id;
end;
$$;
revoke all on function public.share_personal_event_with_groups(uuid, uuid[]) from public;
grant execute on function public.share_personal_event_with_groups(uuid, uuid[]) to authenticated;
-- Insert a personal event and all selected group copies in one PostgREST
-- transaction. The wrapper is SECURITY INVOKER: the personal INSERT remains
-- subject to events RLS, while the existing owner-checked share RPC performs
-- the group writes. Any share error aborts the whole function transaction.
create or replace function public.create_personal_event_with_groups(
  p_event jsonb,
  p_group_ids uuid[]
)
returns public.events
language plpgsql
security invoker
set search_path = public, pg_temp
as $$
declare
  caller_id uuid := auth.uid();
  event_row public.events%rowtype;
  saved_event public.events%rowtype;
  shared_ids uuid[];
  requested_group_count integer;
begin
  if caller_id is null then
    raise exception 'authentication required';
  end if;
  if jsonb_typeof(p_event) <> 'object' then
    raise exception 'event payload must be a JSON object';
  end if;
  if p_group_ids is null or cardinality(p_group_ids) = 0 then
    raise exception 'at least one group is required';
  end if;

  event_row := jsonb_populate_record(null::public.events, p_event);
  if event_row.id is null or event_row.title is null or event_row.start_at is null then
    raise exception 'stable event id, title, and start time are required';
  end if;
  if event_row.user_id is not null and event_row.user_id <> caller_id then
    raise exception 'event owner must match the signed-in user';
  end if;
  event_row.user_id := caller_id;
  event_row.group_event_id := null;
  event_row.supplies := coalesce(event_row.supplies, '{}'::text[]);
  event_row.supplies_checked := coalesce(event_row.supplies_checked, '{}'::text[]);
  event_row.participants := coalesce(event_row.participants, '{}'::text[]);
  event_row.targets := coalesce(event_row.targets, '{}'::text[]);
  event_row.is_critical := coalesce(event_row.is_critical, false);
  event_row.use_strong_alarm := coalesce(event_row.use_strong_alarm, false);
  event_row.is_all_day := coalesce(event_row.is_all_day, false);
  event_row.is_multi_day := coalesce(event_row.is_multi_day, false);
  event_row.category := coalesce(event_row.category, '기타');
  event_row.source := coalesce(event_row.source, 'manual');
  event_row.created_at := coalesce(event_row.created_at, now());
  event_row.updated_at := coalesce(event_row.updated_at, now());

  select count(distinct requested.group_id)
    into requested_group_count
    from unnest(p_group_ids) as requested(group_id);
  if requested_group_count = 0 then
    raise exception 'at least one group is required';
  end if;

  -- Stable client UUID makes an uncertain network retry idempotent. If the
  -- prior transaction committed, reuse its row and the share RPC's idempotent
  -- links instead of creating a second personal event.
  select * into saved_event
    from public.events
   where id = event_row.id
   for update;
  if found then
    if saved_event.user_id <> caller_id then
      raise exception 'event id is owned by another user';
    end if;
  else
    insert into public.events
      select (event_row).*
      returning * into saved_event;
  end if;

  select array_agg(shared.id order by shared.created_at, shared.id)
    into shared_ids
    from public.share_personal_event_with_groups(
      saved_event.id,
      p_group_ids
    ) as shared;

  if coalesce(cardinality(shared_ids), 0) <> requested_group_count then
    raise exception 'not all requested group copies were created';
  end if;

  update public.events
     set group_event_id = shared_ids[1]
   where id = saved_event.id
     and user_id = caller_id
   returning * into saved_event;

  if not found then
    raise exception 'created event could not be read back';
  end if;
  return saved_event;
end;
$$;

revoke all on function public.create_personal_event_with_groups(jsonb, uuid[]) from public;
grant execute on function public.create_personal_event_with_groups(jsonb, uuid[]) to authenticated;

-- Update an owned personal event and share it with all selected groups in the
-- same PostgREST transaction. Existing linked copies are synchronized by the
-- owner-checked update trigger; this RPC covers newly selected group links.
create or replace function public.update_personal_event_with_groups(
  p_event jsonb,
  p_group_ids uuid[]
)
returns public.events
language plpgsql
security invoker
set search_path = public, pg_temp
as $$
declare
  caller_id uuid := auth.uid();
  event_row public.events%rowtype;
  saved_event public.events%rowtype;
  shared_ids uuid[];
  requested_group_count integer;
begin
  if caller_id is null then
    raise exception 'authentication required';
  end if;
  if jsonb_typeof(p_event) <> 'object' then
    raise exception 'event payload must be a JSON object';
  end if;
  if p_group_ids is null or cardinality(p_group_ids) = 0 then
    raise exception 'at least one group is required';
  end if;

  event_row := jsonb_populate_record(null::public.events, p_event);
  if event_row.id is null or event_row.title is null or event_row.start_at is null then
    raise exception 'event id, title, and start time are required';
  end if;
  if event_row.user_id is not null and event_row.user_id <> caller_id then
    raise exception 'event owner must match the signed-in user';
  end if;

  select * into saved_event
    from public.events
   where id = event_row.id
     and user_id = caller_id
   for update;
  if not found then
    raise exception 'owned personal event not found';
  end if;

  update public.events
     set title = event_row.title,
         start_at = event_row.start_at,
         end_at = event_row.end_at,
         location = event_row.location,
         location_lat = event_row.location_lat,
         location_lng = event_row.location_lng,
         memo = event_row.memo,
         supplies = coalesce(event_row.supplies, '{}'::text[]),
         supplies_checked = coalesce(event_row.supplies_checked, '{}'::text[]),
         participants = coalesce(event_row.participants, '{}'::text[]),
         targets = coalesce(event_row.targets, '{}'::text[]),
         is_critical = coalesce(event_row.is_critical, false),
         use_strong_alarm = coalesce(event_row.use_strong_alarm, false),
         recurrence_rule = event_row.recurrence_rule,
         is_all_day = coalesce(event_row.is_all_day, false),
         is_multi_day = coalesce(event_row.is_multi_day, false),
         parent_event_id = event_row.parent_event_id,
         category = coalesce(event_row.category, '기타'),
         source = coalesce(event_row.source, 'manual'),
         external_id = event_row.external_id,
         external_calendar_id = event_row.external_calendar_id,
         external_etag = event_row.external_etag,
         external_updated_at = event_row.external_updated_at,
         last_synced_at = event_row.last_synced_at,
         updated_at = now()
   where id = saved_event.id
     and user_id = caller_id
   returning * into saved_event;
  if not found then
    raise exception 'owned personal event update failed';
  end if;

  select count(distinct requested.group_id)
    into requested_group_count
    from unnest(p_group_ids) as requested(group_id);
  if requested_group_count = 0 then
    raise exception 'at least one group is required';
  end if;

  select array_agg(shared.id order by shared.created_at, shared.id)
    into shared_ids
    from public.share_personal_event_with_groups(saved_event.id, p_group_ids)
      as shared;
  if coalesce(cardinality(shared_ids), 0) <> requested_group_count then
    raise exception 'not all requested group copies were created';
  end if;

  update public.events
     set group_event_id = shared_ids[1]
   where id = saved_event.id
     and user_id = caller_id
   returning * into saved_event;
  if not found then
    raise exception 'updated event could not be read back';
  end if;
  return saved_event;
end;
$$;

revoke all on function public.update_personal_event_with_groups(jsonb, uuid[]) from public;
grant execute on function public.update_personal_event_with_groups(jsonb, uuid[]) to authenticated;


create or replace function public.sync_personal_event_to_linked_group_events()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  -- The invoker may only propagate its own personal event. The matching
  -- group rows must also have been created by that same owner; no leader or
  -- group-member privilege can be used to rewrite another member's event.
  if not exists (
    select 1 from public.group_events linked
     where linked.personal_event_id = old.id
       and linked.created_by = old.user_id
       and linked.status = 'active'
  ) then
    return new;
  end if;

  if auth.uid() is null or auth.uid() <> old.user_id or new.user_id <> old.user_id then
    raise exception 'personal event owner authorization required';
  end if;

  update public.group_events as linked
     set title = new.title,
         description = new.memo,
         location = new.location,
         start_at = new.start_at,
         end_at = coalesce(new.end_at, new.start_at),
         all_day = new.is_all_day,
         is_multi_day = new.is_multi_day,
         is_critical = new.is_critical,
         use_strong_alarm = new.use_strong_alarm,
         recurrence_rule = new.recurrence_rule,
         recurrence_type = case
           when coalesce(new.recurrence_rule, '') = '' then 'none'
           when upper(new.recurrence_rule) like '%FREQ=DAILY%' then 'daily'
           when upper(new.recurrence_rule) like '%FREQ=WEEKLY%' then 'weekly'
           when upper(new.recurrence_rule) like '%FREQ=MONTHLY%' then 'monthly'
           else 'none'
         end,
         -- The canonical RRULE is preserved verbatim and expanded client-side.
         -- Avoid a lossy/ambiguous conversion of UNTIL timezone variants.
         recurrence_until = null,
         updated_by = auth.uid()
   where linked.personal_event_id = old.id
     and linked.created_by = old.user_id
     and linked.status = 'active'
     and exists (
       select 1 from public.group_members as gm
        where gm.group_id = linked.group_id
          and gm.user_id = old.user_id
          and gm.status = 'active'
     )
     and exists (
       select 1 from public.groups as g
        where g.id = linked.group_id and g.status = 'active'
     );

  return new;
end;
$$;

revoke all on function public.sync_personal_event_to_linked_group_events() from public;
drop trigger if exists events_sync_linked_group_events on public.events;
create trigger events_sync_linked_group_events
  after update of title, memo, location, start_at, end_at, is_all_day,
    is_multi_day, is_critical, use_strong_alarm, recurrence_rule
  on public.events
  for each row
  when (
    old.title is distinct from new.title
    or old.memo is distinct from new.memo
    or old.location is distinct from new.location
    or old.start_at is distinct from new.start_at
    or old.end_at is distinct from new.end_at
    or old.is_all_day is distinct from new.is_all_day
    or old.is_multi_day is distinct from new.is_multi_day
    or old.is_critical is distinct from new.is_critical
    or old.use_strong_alarm is distinct from new.use_strong_alarm
    or old.recurrence_rule is distinct from new.recurrence_rule
  )
  execute function public.sync_personal_event_to_linked_group_events();
