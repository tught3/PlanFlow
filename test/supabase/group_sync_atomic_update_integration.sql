-- Database integration regression for existing A plus newly selected B.
-- Run with psql against an isolated database with the committed schema snapshot
-- and the group-sync migrations applied. Every fixture is rolled back.
BEGIN;

DO $$
DECLARE
  actor_id uuid := gen_random_uuid();
  group_a_id uuid := gen_random_uuid();
  group_b_id uuid := gen_random_uuid();
  missing_group_id uuid := gen_random_uuid();
  event_id uuid := gen_random_uuid();
  group_event_a_id uuid := gen_random_uuid();
  event_payload jsonb;
  actual_title text;
  active_copy_count integer;
  failure_seen boolean := false;
BEGIN
  INSERT INTO auth.users (id, email, raw_user_meta_data)
  VALUES (actor_id, 'group-sync-test@example.invalid', '{"name":"Group Sync Test"}'::jsonb);

  INSERT INTO public.groups (id, name, created_by)
  VALUES
    (group_a_id, 'Group Sync Test A', actor_id),
    (group_b_id, 'Group Sync Test B', actor_id);

  INSERT INTO public.group_members (group_id, user_id, role, status)
  VALUES
    (group_a_id, actor_id, 'leader', 'active'),
    (group_b_id, actor_id, 'member', 'active')
  ON CONFLICT (group_id, user_id) DO NOTHING;

  INSERT INTO public.events (
    id, user_id, title, start_at, end_at, memo,
    is_critical, use_strong_alarm, is_all_day, is_multi_day, category, source
  ) VALUES (
    event_id, actor_id, 'Before', '2026-09-30 09:00:00+09',
    '2026-09-30 10:00:00+09', 'before memo',
    false, false, false, false, '기타', 'manual'
  );

  INSERT INTO public.group_events (
    id, group_id, title, description, start_at, end_at,
    created_by, updated_by, personal_event_id, status
  ) VALUES (
    group_event_a_id, group_a_id, 'Before', 'before memo',
    '2026-09-30 09:00:00+09', '2026-09-30 10:00:00+09',
    actor_id, actor_id, event_id, 'active'
  );

  PERFORM set_config('request.jwt.claim.sub', actor_id::text, true);
  event_payload := jsonb_build_object(
    'id', event_id,
    'user_id', actor_id,
    'title', 'Updated A+B',
    'start_at', '2026-09-30T10:00:00+09:00',
    'end_at', '2026-09-30T11:00:00+09:00',
    'location', 'Gangnam',
    'memo', 'updated memo',
    'is_critical', true,
    'use_strong_alarm', true,
    'is_all_day', false,
    'is_multi_day', false,
    'recurrence_rule', null,
    'category', '기타',
    'source', 'manual'
  );

  PERFORM public.update_personal_event_with_groups(
    event_payload, ARRAY[group_a_id, group_b_id]
  );

  SELECT title INTO actual_title FROM public.events WHERE id = event_id;
  IF actual_title <> 'Updated A+B' THEN
    RAISE EXCEPTION 'personal event did not update: %', actual_title;
  END IF;

  SELECT count(*) INTO active_copy_count
  FROM public.group_events
  WHERE personal_event_id = event_id AND status = 'active';
  IF active_copy_count <> 2 THEN
    RAISE EXCEPTION 'expected two active linked copies, got %', active_copy_count;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.group_events
    WHERE personal_event_id = event_id
      AND group_id IN (group_a_id, group_b_id)
      AND (title <> 'Updated A+B' OR NOT is_critical OR NOT use_strong_alarm)
  ) THEN
    RAISE EXCEPTION 'existing or newly selected group copy did not synchronize';
  END IF;

  -- Repeating the share must update existing copies, not insert duplicates.
  PERFORM public.update_personal_event_with_groups(
    event_payload, ARRAY[group_a_id, group_b_id]
  );
  SELECT count(*) INTO active_copy_count
  FROM public.group_events
  WHERE personal_event_id = event_id AND status = 'active';
  IF active_copy_count <> 2 THEN
    RAISE EXCEPTION 'idempotent repeat created a duplicate group copy';
  END IF;

  -- An unauthorized target fails after the personal update has started. The
  -- whole RPC statement must roll back the personal row and existing copy.
  event_payload := jsonb_set(event_payload, '{title}', '"Must Roll Back"'::jsonb);
  BEGIN
    PERFORM public.update_personal_event_with_groups(
      event_payload, ARRAY[group_a_id, missing_group_id]
    );
    RAISE EXCEPTION 'expected an unauthorized group target to fail';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM = 'expected an unauthorized group target to fail' THEN
      RAISE;
    END IF;
    failure_seen := true;
  END;

  IF NOT failure_seen THEN
    RAISE EXCEPTION 'invalid group target did not fail';
  END IF;
  IF EXISTS (
    SELECT 1 FROM public.events
    WHERE id = event_id AND title <> 'Updated A+B'
  ) THEN
    RAISE EXCEPTION 'personal event update was not rolled back';
  END IF;
  IF EXISTS (
    SELECT 1 FROM public.group_events
    WHERE personal_event_id = event_id
      AND status = 'active'
      AND title <> 'Updated A+B'
  ) THEN
    RAISE EXCEPTION 'group copy update was not rolled back';
  END IF;
END;
$$;

ROLLBACK;
