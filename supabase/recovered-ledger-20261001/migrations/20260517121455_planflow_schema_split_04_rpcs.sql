create or replace function public.restore_user_backup(backup_id_input uuid)
returns void
language plpgsql
security invoker
set search_path = planflow, public
as $$
declare
  uid uuid := auth.uid();
  snapshot jsonb;
  item jsonb;
  event_id_value uuid;
  supplies_value text[];
  supplies_checked_value text[];
begin
  if uid is null then
    raise exception 'A signed-in user is required.' using errcode = '28000';
  end if;

  select payload
    into snapshot
  from planflow.user_backups
  where id = backup_id_input
    and user_id = uid;

  if snapshot is null then
    raise exception 'Backup not found for the current user.' using errcode = '02000';
  end if;

  for item in
    select value from jsonb_array_elements(coalesce(snapshot -> 'events', '[]'::jsonb))
  loop
    if nullif(item ->> 'title', '') is null
      or nullif(item ->> 'start_at', '') is null then
      continue;
    end if;

    supplies_value := array(
      select jsonb_array_elements_text(coalesce(item -> 'supplies', '[]'::jsonb))
    );
    supplies_checked_value := array(
      select jsonb_array_elements_text(coalesce(item -> 'supplies_checked', '[]'::jsonb))
    );

    insert into planflow.events (
      id, user_id, title, start_at, end_at, location, location_lat,
      location_lng, memo, supplies, supplies_checked, is_critical, source,
      recurrence_rule, is_all_day, is_multi_day, parent_event_id, category,
      external_id, external_calendar_id, external_etag, external_updated_at, last_synced_at,
      created_at, updated_at
    )
    values (
      coalesce(nullif(item ->> 'id', '')::uuid, gen_random_uuid()),
      uid,
      item ->> 'title',
      nullif(item ->> 'start_at', '')::timestamptz,
      nullif(item ->> 'end_at', '')::timestamptz,
      nullif(item ->> 'location', ''),
      nullif(item ->> 'location_lat', '')::double precision,
      nullif(item ->> 'location_lng', '')::double precision,
      nullif(item ->> 'memo', ''),
      coalesce(supplies_value, '{}'::text[]),
      coalesce(supplies_checked_value, '{}'::text[]),
      coalesce(nullif(item ->> 'is_critical', '')::boolean, false),
      coalesce(nullif(item ->> 'source', ''), 'manual'),
      nullif(item ->> 'recurrence_rule', ''),
      coalesce(nullif(item ->> 'is_all_day', '')::boolean, false),
      coalesce(nullif(item ->> 'is_multi_day', '')::boolean, false),
      nullif(item ->> 'parent_event_id', '')::uuid,
      case nullif(item ->> 'category', '')
        when '가족' then '건강'
        when '업무' then '업무'
        when '개인' then '개인'
        when '건강' then '건강'
        when '교육' then '교육'
        when '기타' then '기타'
        else '기타'
      end,
      nullif(item ->> 'external_id', ''),
      nullif(item ->> 'external_calendar_id', ''),
      nullif(item ->> 'external_etag', ''),
      nullif(item ->> 'external_updated_at', '')::timestamptz,
      nullif(item ->> 'last_synced_at', '')::timestamptz,
      coalesce(nullif(item ->> 'created_at', '')::timestamptz, now()),
      coalesce(nullif(item ->> 'updated_at', '')::timestamptz, now())
    )
    on conflict (id) do update
      set title = excluded.title,
          start_at = excluded.start_at,
          end_at = excluded.end_at,
          location = excluded.location,
          location_lat = excluded.location_lat,
          location_lng = excluded.location_lng,
          memo = excluded.memo,
          supplies = excluded.supplies,
          supplies_checked = excluded.supplies_checked,
          is_critical = excluded.is_critical,
          source = excluded.source,
          recurrence_rule = excluded.recurrence_rule,
          is_all_day = excluded.is_all_day,
          is_multi_day = excluded.is_multi_day,
          parent_event_id = excluded.parent_event_id,
          category = excluded.category,
          external_id = excluded.external_id,
          external_calendar_id = excluded.external_calendar_id,
          external_etag = excluded.external_etag,
          external_updated_at = excluded.external_updated_at,
          last_synced_at = excluded.last_synced_at,
          updated_at = excluded.updated_at
      where planflow.events.user_id = uid;
  end loop;

  for item in
    select value from jsonb_array_elements(coalesce(snapshot -> 'user_settings', '[]'::jsonb))
  loop
    insert into planflow.user_settings (
      id, user_id, morning_briefing_at, evening_briefing_at,
      default_reminder_min, prep_time_min, prep_pre_alarm_offset,
      depart_pre_alarm_offset, travel_mode, voice_auto_start,
      preferred_map_provider,
      country_code, locale_code, time_zone_id, created_at
    )
    values (
      coalesce(nullif(item ->> 'id', '')::uuid, gen_random_uuid()),
      uid,
      coalesce(nullif(item ->> 'morning_briefing_at', '')::time, '07:30'::time),
      coalesce(nullif(item ->> 'evening_briefing_at', '')::time, '21:00'::time),
      coalesce(nullif(item ->> 'default_reminder_min', '')::integer, 60),
      coalesce(nullif(item ->> 'prep_time_min', '')::integer, 30),
      coalesce(nullif(item ->> 'prep_pre_alarm_offset', '')::integer, 30),
      coalesce(nullif(item ->> 'depart_pre_alarm_offset', '')::integer, 30),
      case
        when lower(coalesce(item ->> 'travel_mode', '')) = 'transit'
          then 'transit'
        else 'car'
      end,
      coalesce(nullif(item ->> 'voice_auto_start', '')::boolean, false),
      case
        when lower(coalesce(item ->> 'preferred_map_provider', '')) in ('google', 'tmap', 'naver')
          then lower(item ->> 'preferred_map_provider')
        else 'naver'
      end,
      coalesce(nullif(item ->> 'country_code', ''), 'KR'),
      coalesce(nullif(item ->> 'locale_code', ''), 'ko-KR'),
      coalesce(nullif(item ->> 'time_zone_id', ''), 'Asia/Seoul'),
      coalesce(nullif(item ->> 'created_at', '')::timestamptz, now())
    )
    on conflict (user_id) do update
      set morning_briefing_at = excluded.morning_briefing_at,
          evening_briefing_at = excluded.evening_briefing_at,
          default_reminder_min = excluded.default_reminder_min,
          prep_time_min = excluded.prep_time_min,
          prep_pre_alarm_offset = excluded.prep_pre_alarm_offset,
          depart_pre_alarm_offset = excluded.depart_pre_alarm_offset,
          travel_mode = excluded.travel_mode,
          voice_auto_start = excluded.voice_auto_start,
          preferred_map_provider = excluded.preferred_map_provider,
          country_code = excluded.country_code,
          locale_code = excluded.locale_code,
          time_zone_id = excluded.time_zone_id;
  end loop;

  for item in
    select value from jsonb_array_elements(coalesce(snapshot -> 'pre_actions', '[]'::jsonb))
  loop
    event_id_value := nullif(item ->> 'event_id', '')::uuid;
    if nullif(item ->> 'event_id', '') is null
      or nullif(item ->> 'title', '') is null
      or nullif(item ->> 'notify_at', '') is null then
      continue;
    end if;
    if not exists (
      select 1 from planflow.events
      where id = event_id_value
        and user_id = uid
    ) then
      continue;
    end if;

    insert into planflow.pre_actions (
      id, event_id, user_id, title, notify_at, is_done, source, created_at
    )
    values (
      coalesce(nullif(item ->> 'id', '')::uuid, gen_random_uuid()),
      event_id_value,
      uid,
      item ->> 'title',
      nullif(item ->> 'notify_at', '')::timestamptz,
      coalesce(nullif(item ->> 'is_done', '')::boolean, false),
      coalesce(nullif(item ->> 'source', ''), null),
      coalesce(nullif(item ->> 'created_at', '')::timestamptz, now())
    )
    on conflict (id) do update
      set title = excluded.title,
          notify_at = excluded.notify_at,
          is_done = excluded.is_done,
          source = excluded.source
      where planflow.pre_actions.user_id = uid;
  end loop;

  for item in
    select value from jsonb_array_elements(coalesce(snapshot -> 'reminders', '[]'::jsonb))
  loop
    event_id_value := nullif(item ->> 'event_id', '')::uuid;
    if nullif(item ->> 'event_id', '') is null
      or nullif(item ->> 'type', '') is null
      or nullif(item ->> 'notify_at', '') is null then
      continue;
    end if;
    if not exists (
      select 1 from planflow.events
      where id = event_id_value
        and user_id = uid
    ) then
      continue;
    end if;

    insert into planflow.reminders (
      id, event_id, user_id, type, notify_at, is_sent, created_at
    )
    values (
      coalesce(nullif(item ->> 'id', '')::uuid, gen_random_uuid()),
      event_id_value,
      uid,
      item ->> 'type',
      nullif(item ->> 'notify_at', '')::timestamptz,
      coalesce(nullif(item ->> 'is_sent', '')::boolean, false),
      coalesce(nullif(item ->> 'created_at', '')::timestamptz, now())
    )
    on conflict (id) do update
      set type = excluded.type,
          notify_at = excluded.notify_at,
          is_sent = excluded.is_sent
      where planflow.reminders.user_id = uid;
  end loop;

  for item in
    select value from jsonb_array_elements(coalesce(snapshot -> 'location_history', '[]'::jsonb))
  loop
    event_id_value := nullif(item ->> 'event_id', '')::uuid;
    if event_id_value is not null and not exists (
      select 1 from planflow.events
      where id = event_id_value
        and user_id = uid
    ) then
      event_id_value := null;
    end if;
    supplies_value := array(
      select jsonb_array_elements_text(coalesce(item -> 'supplies', '[]'::jsonb))
    );

    insert into planflow.location_history (
      id, user_id, location, supplies, event_id, visited_at
    )
    values (
      coalesce(nullif(item ->> 'id', '')::uuid, gen_random_uuid()),
      uid,
      nullif(item ->> 'location', ''),
      coalesce(supplies_value, '{}'::text[]),
      event_id_value,
      coalesce(nullif(item ->> 'visited_at', '')::timestamptz, now())
    )
    on conflict (id) do update
      set location = excluded.location,
          supplies = excluded.supplies,
          event_id = excluded.event_id,
          visited_at = excluded.visited_at
      where planflow.location_history.user_id = uid;
  end loop;

  for item in
    select value from jsonb_array_elements(coalesce(snapshot -> 'voice_logs', '[]'::jsonb))
  loop
    event_id_value := nullif(item ->> 'event_id', '')::uuid;
    if event_id_value is not null and not exists (
      select 1 from planflow.events
      where id = event_id_value
        and user_id = uid
    ) then
      event_id_value := null;
    end if;

    insert into planflow.voice_logs (
      id, user_id, raw_text, parsed_json, event_id, created_at
    )
    values (
      coalesce(nullif(item ->> 'id', '')::uuid, gen_random_uuid()),
      uid,
      nullif(item ->> 'raw_text', ''),
      item -> 'parsed_json',
      event_id_value,
      coalesce(nullif(item ->> 'created_at', '')::timestamptz, now())
    )
    on conflict (id) do update
      set raw_text = excluded.raw_text,
          parsed_json = excluded.parsed_json,
          event_id = excluded.event_id
      where planflow.voice_logs.user_id = uid;
  end loop;
end;
$$;

revoke all on function public.restore_user_backup(uuid) from public;
grant execute on function public.restore_user_backup(uuid) to authenticated;

create or replace function public.upsert_naver_caldav_credentials(
  naver_caldav_id text,
  naver_caldav_app_password text,
  provider_account_email_input text default null
)
returns table (
  connection_id uuid,
  provider text,
  provider_account_email text,
  has_credentials boolean,
  credentials_updated_at timestamptz,
  updated_at timestamptz
)
language plpgsql
security invoker
set search_path = planflow, public, extensions, pg_temp
as $$
declare
  uid uuid := auth.uid();
  credential_secret text;
begin
  if uid is null then
    raise exception 'A signed-in user is required.' using errcode = '28000';
  end if;

  if nullif(trim(naver_caldav_id), '') is null then
    raise exception 'Naver CalDAV ID is required.' using errcode = '22023';
  end if;

  if nullif(naver_caldav_app_password, '') is null then
    raise exception 'Naver CalDAV app password is required.' using errcode = '22023';
  end if;

  credential_secret := coalesce(
    nullif(current_setting('planflow.naver_caldav_secret', true), ''),
    encode(digest(uid::text || ':planflow:naver-caldav:v1', 'sha256'), 'hex')
  );

  return query
    insert into planflow.calendar_connections (
      user_id,
      provider,
      provider_account_email,
      status,
      naver_caldav_credentials_encrypted,
      naver_caldav_credentials_updated_at,
      last_error
    )
    values (
      uid,
      'naver',
      nullif(trim(provider_account_email_input), ''),
      'connected',
      pgp_sym_encrypt(
        jsonb_build_object(
          'version', 1,
          'naver_caldav_id', trim(naver_caldav_id),
          'naver_caldav_app_password', naver_caldav_app_password,
          'saved_at', now()
        )::text,
        credential_secret,
        'cipher-algo=aes256, compress-algo=0'
      ),
      now(),
      null
    )
    on conflict (user_id, provider) do update
      set provider_account_email = coalesce(
            excluded.provider_account_email,
            planflow.calendar_connections.provider_account_email
          ),
          status = 'connected',
          naver_caldav_credentials_encrypted = excluded.naver_caldav_credentials_encrypted,
          naver_caldav_credentials_updated_at = excluded.naver_caldav_credentials_updated_at,
          last_error = null
    returning
      id,
      provider,
      provider_account_email,
      naver_caldav_credentials_encrypted is not null,
      naver_caldav_credentials_updated_at,
      updated_at;
end;
$$;

create or replace function public.fetch_naver_caldav_credentials()
returns table (
  connection_id uuid,
  provider_account_email text,
  naver_caldav_id text,
  naver_caldav_app_password text,
  credentials_updated_at timestamptz,
  updated_at timestamptz
)
language plpgsql
security invoker
set search_path = planflow, public, extensions, pg_temp
as $$
declare
  uid uuid := auth.uid();
  credential_secret text;
begin
  if uid is null then
    raise exception 'A signed-in user is required.' using errcode = '28000';
  end if;

  credential_secret := coalesce(
    nullif(current_setting('planflow.naver_caldav_secret', true), ''),
    encode(digest(uid::text || ':planflow:naver-caldav:v1', 'sha256'), 'hex')
  );

  return query
    select
      c.id,
      c.provider_account_email,
      decrypted.payload ->> 'naver_caldav_id',
      decrypted.payload ->> 'naver_caldav_app_password',
      c.naver_caldav_credentials_updated_at,
      c.updated_at
    from planflow.calendar_connections c
    cross join lateral (
      select pgp_sym_decrypt(c.naver_caldav_credentials_encrypted, credential_secret)::jsonb as payload
    ) decrypted
    where c.user_id = uid
      and c.provider = 'naver'
      and c.naver_caldav_credentials_encrypted is not null;
end;
$$;

create or replace function public.clear_naver_caldav_credentials()
returns void
language plpgsql
security invoker
set search_path = planflow, public, pg_temp
as $$
declare
  uid uuid := auth.uid();
begin
  if uid is null then
    raise exception 'A signed-in user is required.' using errcode = '28000';
  end if;

  update planflow.calendar_connections
  set naver_caldav_credentials_encrypted = null,
      naver_caldav_credentials_updated_at = null,
      last_error = null,
      status = case
        when access_token is null and refresh_token is null then 'disconnected'
        else status
      end
  where user_id = uid
    and provider = 'naver';
end;
$$;

create or replace function public.submit_early_bird_email(input_email text)
returns void
language plpgsql
security definer
set search_path = planflow, public
as $$
declare
  normalized_email text := lower(trim(input_email));
begin
  if normalized_email is null
    or char_length(normalized_email) > 254
    or normalized_email !~* '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$'
  then
    raise exception 'A valid email is required.'
      using errcode = '22023';
  end if;

  insert into planflow.early_bird_emails (email)
  values (normalized_email)
  on conflict (email) do nothing;
end;
$$;

revoke all on function public.upsert_naver_caldav_credentials(text, text, text)
  from public, anon, authenticated, service_role;
grant execute on function public.upsert_naver_caldav_credentials(text, text, text)
  to authenticated;
revoke all on function public.fetch_naver_caldav_credentials()
  from public, anon, authenticated, service_role;
grant execute on function public.fetch_naver_caldav_credentials()
  to authenticated;
revoke all on function public.clear_naver_caldav_credentials()
  from public, anon, authenticated, service_role;
grant execute on function public.clear_naver_caldav_credentials()
  to authenticated;
revoke all on function public.submit_early_bird_email(text) from public;
grant execute on function public.submit_early_bird_email(text)
  to anon, authenticated;

notify pgrst, 'reload schema';;
