-- "단일 회차만 삭제" 지원: 반복 일정에서 삭제된 회차의 날짜 목록을
-- jsonb(ISO 8601 문자열 배열)로 저장한다. 클라이언트(EventModel)가
-- deleted_occurrence_dates 키로 읽고 쓴다.
alter table public.events
  add column if not exists deleted_occurrence_dates jsonb;

-- create_personal_event_with_groups는 jsonb_populate_record + 전체 행
-- insert라 새 컬럼이 자동으로 반영되므로 수정 불필요. 반면
-- update_personal_event_with_groups는 컬럼을 명시하므로 함수를 갱신한다.
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
         deleted_occurrence_dates = event_row.deleted_occurrence_dates,
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
