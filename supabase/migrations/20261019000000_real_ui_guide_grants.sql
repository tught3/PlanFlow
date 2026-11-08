-- Private, finite server-side authority for the real UI guide. Does not modify
-- existing entitlement tables or ordinary free-usage RPC/counter.
create table public.real_ui_guide_sessions (
 id uuid primary key default gen_random_uuid(), user_id uuid not null references auth.users(id) on delete cascade,
 version text not null check(version='real_ui_v1'), phase text not null check(phase in ('create','saved','query','edit','preview','updated','terminal')),
 revision bigint not null default 0 check(revision>=0), created_at timestamptz not null default now(), expires_at timestamptz not null,
 bound_event_id uuid references public.events(id) on delete set null, expected_start_at timestamptz,
 target_title text, target_location text, target_start_date date,
 saved_local_date date,
 bind_calendar_utc_offset_minutes integer check (bind_calendar_utc_offset_minutes between -840 and 840),
 preview_calendar_utc_offset_minutes integer check (preview_calendar_utc_offset_minutes between -840 and 840),
 terminal_reason text,
 check ((phase='terminal') = (terminal_reason is not null)),
 check (terminal_reason is null or terminal_reason in ('completed','skip','cancel'))
);
create unique index real_ui_guide_one_active_uid_version on public.real_ui_guide_sessions(user_id,version);
create table public.real_ui_guide_requests(user_id uuid not null references auth.users(id) on delete cascade,request_id text not null,session_id uuid not null references public.real_ui_guide_sessions(id) on delete cascade,request_hash text not null,response jsonb not null,created_at timestamptz not null default now(),primary key(user_id,request_id));
create table public.real_ui_guide_operations(user_id uuid not null references auth.users(id) on delete cascade,operation_id text not null,session_id uuid not null references public.real_ui_guide_sessions(id) on delete cascade,request_hash text not null,grant_id uuid not null default gen_random_uuid(),expires_at timestamptz not null,created_at timestamptz not null default now(),primary key(user_id,operation_id),unique(grant_id));
alter table public.real_ui_guide_sessions enable row level security;
alter table public.real_ui_guide_requests enable row level security;
alter table public.real_ui_guide_operations enable row level security;
revoke all on public.real_ui_guide_sessions,public.real_ui_guide_requests,public.real_ui_guide_operations from public,anon,authenticated;

create or replace function public.begin_real_ui_guide(p_version text,p_request_id text) returns jsonb language plpgsql security definer set search_path=pg_catalog,public,auth,pg_temp as $$
declare u uuid:=auth.uid(); s public.real_ui_guide_sessions%rowtype; r public.real_ui_guide_requests%rowtype; h text; out jsonb;
begin
 if u is null then raise exception 'authentication required' using errcode='42501'; end if;
 if p_version is distinct from 'real_ui_v1' or coalesce(length(trim(p_request_id)),0) not between 1 and 128 then return jsonb_build_object('status','denied','reason_code','invalid_request'); end if;
 -- Serialize before the first session exists; unique index remains the final invariant.
 perform pg_advisory_xact_lock(hashtextextended(u::text||':'||p_version,0));
 h:=encode(sha256(convert_to(jsonb_build_array('begin',p_version,p_request_id)::text,'UTF8')),'hex');
 select * into r from public.real_ui_guide_requests where user_id=u and request_id=p_request_id;
 if found and r.request_hash is distinct from h then return jsonb_build_object('status','denied','reason_code','request_replay_mismatch'); end if;
 select * into s from public.real_ui_guide_sessions where user_id=u and version=p_version for update;
 if not found then insert into public.real_ui_guide_sessions(user_id,version,phase,expires_at) values(u,p_version,'create',now()+interval '60 minutes') returning * into s; end if;
 if s.terminal_reason is not null then return jsonb_build_object('status','denied','reason_code','session_terminal'); end if;
 if s.created_at+interval '7 days'<=now() then return jsonb_build_object('status','expired','session_id',s.id,'phase',s.phase,'revision',s.revision,'expires_at',s.expires_at); end if;
 if s.expires_at<=now() then update public.real_ui_guide_sessions set expires_at=least(now()+interval '60 minutes',created_at+interval '7 days') where id=s.id returning * into s; end if;
 out:=jsonb_build_object('status','granted','session_id',s.id,'phase',s.phase,'revision',s.revision,'expires_at',s.expires_at,'event_id',s.bound_event_id,'saved_local_date',s.saved_local_date);
 insert into public.real_ui_guide_requests(user_id,request_id,session_id,request_hash,response) values(u,p_request_id,s.id,h,out) on conflict(user_id,request_id) do nothing; return out;
end $$;
revoke all on function public.begin_real_ui_guide(text,text) from public,anon; grant execute on function public.begin_real_ui_guide(text,text) to authenticated;

create or replace function public.authorize_real_ui_guide_operation(p_session_id uuid,p_phase text,p_revision bigint,p_kind text,p_operation text,p_operation_id text) returns jsonb language plpgsql security definer set search_path=pg_catalog,public,auth,pg_temp as $$
declare u uuid:=auth.uid(); s public.real_ui_guide_sessions%rowtype; o public.real_ui_guide_operations%rowtype; h text; ok boolean:=false;
begin
 if u is null then raise exception 'authentication required' using errcode='42501'; end if;
 if p_session_id is null or p_phase is null or p_revision is null or p_revision<0 or p_kind is null or p_operation is null then return jsonb_build_object('status','denied','reason_code','invalid_operation'); end if;
 if coalesce(length(trim(p_operation_id)),0) not between 1 and 128 then return jsonb_build_object('status','denied','reason_code','invalid_operation_id'); end if;
 select * into s from public.real_ui_guide_sessions where id=p_session_id and user_id=u for update;
 if not found or s.terminal_reason is not null then return jsonb_build_object('status','denied','reason_code','session_missing_or_terminal'); end if;
 if s.expires_at<=now() then return jsonb_build_object('status','expired','reason_code','session_expired'); end if;
 if s.revision<>p_revision then return jsonb_build_object('status','retryLater','reason_code','stale_revision'); end if;
 ok:=(p_kind='scheduleParse' and p_operation='createParse' and p_phase='create' and s.phase='create') or (p_kind='voiceConversation' and p_operation='query' and p_phase='query' and s.phase='query' and s.bound_event_id is not null) or (p_kind='voiceConversation' and p_operation='changeTime' and p_phase in ('edit','preview') and s.phase=p_phase and s.bound_event_id is not null);
 if ok is not true then return jsonb_build_object('status','denied','reason_code','phase_operation_mismatch'); end if;
 if p_operation in ('query','changeTime') and not exists(select 1 from public.events e where e.id=s.bound_event_id and e.user_id=u and e.group_event_id is null and e.parent_event_id is null and e.recurrence_rule is null and e.external_id is null and e.source in ('manual','voice')) then return jsonb_build_object('status','denied','reason_code','target_not_eligible'); end if;
 h:=encode(sha256(convert_to(jsonb_build_array('authorize',p_session_id,p_phase,p_revision,p_kind,p_operation)::text,'UTF8')),'hex'); select * into o from public.real_ui_guide_operations where user_id=u and operation_id=p_operation_id for update;
 if found then if o.request_hash<>h or o.session_id<>p_session_id then return jsonb_build_object('status','denied','reason_code','operation_replay_mismatch'); end if; if o.expires_at<=now() then return jsonb_build_object('status','expired','reason_code','grant_expired'); end if; return jsonb_build_object('status','granted','grant_id',o.grant_id,'expires_at',o.expires_at); end if;
 if (select count(*) from public.real_ui_guide_operations where user_id=u and session_id=s.id)>=12 then return jsonb_build_object('status','denied','reason_code','guide_operation_limit'); end if;
 insert into public.real_ui_guide_operations(user_id,operation_id,session_id,request_hash,expires_at) values(u,p_operation_id,p_session_id,h,least(now()+interval '2 minutes',s.expires_at)) returning * into o;
 return jsonb_build_object('status','granted','grant_id',o.grant_id,'expires_at',o.expires_at);
end $$;
revoke all on function public.authorize_real_ui_guide_operation(uuid,text,bigint,text,text,text) from public,anon; grant execute on function public.authorize_real_ui_guide_operation(uuid,text,bigint,text,text,text) to authenticated;

create or replace function public.advance_real_ui_guide(p_session_id uuid,p_expected_revision bigint,p_action text,p_request_id text,p_event_id text default null,p_payload jsonb default '{}'::jsonb) returns jsonb language plpgsql security definer set search_path=pg_catalog,public,auth,pg_temp as $$
declare u uuid:=auth.uid(); s public.real_ui_guide_sessions%rowtype; e public.events%rowtype; r public.real_ui_guide_requests%rowtype; h text; np text; target uuid;
 v_offset_text text; v_offset int; v_saved_local_date date; v_expected_text text; v_expected_ts timestamptz; v_declared_local_date date; v_actual_local_date date;
begin
 if u is null then raise exception 'authentication required' using errcode='42501'; end if;
 if p_session_id is null or p_expected_revision is null or p_expected_revision<0 or p_action is null or p_payload is null or jsonb_typeof(p_payload) is distinct from 'object' then return jsonb_build_object('status','denied','reason_code','invalid_request'); end if;
 if coalesce(length(trim(p_request_id)),0) not between 1 and 128 then return jsonb_build_object('status','denied','reason_code','invalid_request_id'); end if;
 select * into s from public.real_ui_guide_sessions where id=p_session_id and user_id=u for update;
 if not found then return jsonb_build_object('status','denied','reason_code','session_missing_or_terminal'); end if;
 h:=encode(sha256(convert_to(jsonb_build_array('advance',p_session_id,p_expected_revision,p_action,p_event_id,p_payload)::text,'UTF8')),'hex');
 select * into r from public.real_ui_guide_requests where user_id=u and request_id=p_request_id;
 if found then if r.request_hash<>h then return jsonb_build_object('status','denied','reason_code','request_replay_mismatch'); end if; return r.response; end if;
 if s.terminal_reason is not null then return jsonb_build_object('status','denied','reason_code','session_missing_or_terminal'); end if;
 if s.expires_at<=now() then return jsonb_build_object('status','expired','reason_code','session_expired'); end if;
 if s.revision is distinct from p_expected_revision then return jsonb_build_object('status','retryLater','reason_code','stale_revision'); end if;
 np:=case when p_action='bind_created' and s.phase='create' then 'saved' when p_action='detail_ack' and s.phase='saved' then 'query' when p_action='query_ready' and s.phase='query' then 'edit' when p_action='edit_preview' and s.phase='edit' then 'preview' when p_action='update_verified' and s.phase='preview' then 'updated' else null end;
 if np is null then return jsonb_build_object('status','denied','reason_code','invalid_transition'); end if;
 if p_event_id is not null and p_event_id !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then return jsonb_build_object('status','denied','reason_code','invalid_event_id'); end if;
 target:=coalesce(s.bound_event_id,nullif(p_event_id,'')::uuid);
 if p_action='bind_created' then
  if s.bound_event_id is not null or target is null then return jsonb_build_object('status','denied','reason_code','target_already_bound_or_missing'); end if;
  v_offset_text:=nullif(p_payload->>'calendar_utc_offset_minutes','');
  if v_offset_text is null then return jsonb_build_object('status','denied','reason_code','calendar_offset_required'); end if;
  if jsonb_typeof(p_payload->'calendar_utc_offset_minutes') is distinct from 'number' or v_offset_text !~ '^-?[0-9]+$' then return jsonb_build_object('status','denied','reason_code','calendar_offset_invalid'); end if;
  begin v_offset:=v_offset_text::int; exception when others then return jsonb_build_object('status','denied','reason_code','calendar_offset_invalid'); end;
  if v_offset<-840 or v_offset>840 then return jsonb_build_object('status','denied','reason_code','calendar_offset_out_of_range'); end if;
  select * into e from public.events where id=target and user_id=u for update;
  if not found or e.created_at<s.created_at or e.group_event_id is not null or e.parent_event_id is not null or e.recurrence_rule is not null or e.external_id is not null or e.source not in ('manual','voice') then return jsonb_build_object('status','denied','reason_code','target_not_eligible'); end if;
  v_saved_local_date:=((e.start_at AT TIME ZONE 'UTC')+make_interval(mins=>v_offset))::date;
 elsif p_action in ('detail_ack','query_ready','edit_preview','update_verified') then
  select * into e from public.events where id=target and user_id=u for update;
  if not found or target is distinct from s.bound_event_id or e.group_event_id is not null or e.parent_event_id is not null or e.recurrence_rule is not null or e.external_id is not null or e.source not in ('manual','voice') or e.title is distinct from s.target_title or e.location is distinct from s.target_location or (p_action<>'update_verified' and (s.bind_calendar_utc_offset_minutes is null or (((e.start_at AT TIME ZONE 'UTC')+make_interval(mins=>s.bind_calendar_utc_offset_minutes))::date is distinct from s.saved_local_date))) then return jsonb_build_object('status','denied','reason_code','target_not_eligible'); end if;
 end if;
 if p_action='edit_preview' then
  v_expected_text:=nullif(p_payload->>'expected_start_at','');
  if v_expected_text is null then return jsonb_build_object('status','denied','reason_code','expected_start_required'); end if;
  if jsonb_typeof(p_payload->'expected_start_at') is distinct from 'string' or v_expected_text !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?(Z|[+-][0-9]{2}:[0-9]{2})$' then return jsonb_build_object('status','denied','reason_code','expected_start_invalid'); end if;
  begin v_expected_ts:=v_expected_text::timestamptz; exception when others then return jsonb_build_object('status','denied','reason_code','expected_start_invalid'); end;
  v_offset_text:=nullif(p_payload->>'calendar_utc_offset_minutes','');
  if v_offset_text is null then return jsonb_build_object('status','denied','reason_code','calendar_offset_required'); end if;
  if jsonb_typeof(p_payload->'calendar_utc_offset_minutes') is distinct from 'number' or v_offset_text !~ '^-?[0-9]+$' then return jsonb_build_object('status','denied','reason_code','calendar_offset_invalid'); end if;
  begin v_offset:=v_offset_text::int; exception when others then return jsonb_build_object('status','denied','reason_code','calendar_offset_invalid'); end;
  if v_offset<-840 or v_offset>840 then return jsonb_build_object('status','denied','reason_code','calendar_offset_out_of_range'); end if;
  v_declared_local_date:=((v_expected_ts AT TIME ZONE 'UTC')+make_interval(mins=>v_offset))::date;
  if s.saved_local_date is null or v_declared_local_date is distinct from s.saved_local_date then return jsonb_build_object('status','denied','reason_code','declared_local_date_mismatch'); end if;
  s.expected_start_at:=v_expected_ts;
 end if;
 if p_action='update_verified' and (s.expected_start_at is null or e.start_at is distinct from s.expected_start_at or e.title is distinct from s.target_title or e.location is distinct from s.target_location or s.preview_calendar_utc_offset_minutes is null or (((e.start_at AT TIME ZONE 'UTC')+make_interval(mins=>s.preview_calendar_utc_offset_minutes))::date is distinct from s.saved_local_date)) then return jsonb_build_object('status','denied','reason_code','persisted_start_mismatch'); end if;
 update public.real_ui_guide_sessions set phase=np,revision=revision+1,bound_event_id=target,expected_start_at=s.expected_start_at,
 bind_calendar_utc_offset_minutes=case when p_action='bind_created' then v_offset else bind_calendar_utc_offset_minutes end,
 saved_local_date=case when p_action='bind_created' then v_saved_local_date else saved_local_date end,
 preview_calendar_utc_offset_minutes=case when p_action='edit_preview' then v_offset else preview_calendar_utc_offset_minutes end,
 target_title=case when p_action='bind_created' then e.title else target_title end,
 target_location=case when p_action='bind_created' then e.location else target_location end,
 target_start_date=case when p_action='bind_created' then v_saved_local_date else target_start_date end,
 expires_at=least(now()+interval '60 minutes',created_at+interval '7 days') where id=s.id returning * into s;
 insert into public.real_ui_guide_requests(user_id,request_id,session_id,request_hash,response) values(u,p_request_id,s.id,h,jsonb_build_object('status','ok','session_id',s.id,'phase',s.phase,'revision',s.revision,'expires_at',s.expires_at,'event_id',s.bound_event_id,'saved_local_date',s.saved_local_date));
 select * into r from public.real_ui_guide_requests where user_id=u and request_id=p_request_id; return r.response;
end $$;
revoke all on function public.advance_real_ui_guide(uuid,bigint,text,text,text,jsonb) from public,anon; grant execute on function public.advance_real_ui_guide(uuid,bigint,text,text,text,jsonb) to authenticated;

create or replace function public.finish_real_ui_guide(p_session_id uuid,p_request_id text,p_reason text) returns jsonb language plpgsql security definer set search_path=pg_catalog,public,auth,pg_temp as $$
declare u uuid:=auth.uid(); s public.real_ui_guide_sessions%rowtype; r public.real_ui_guide_requests%rowtype; h text; out jsonb;
begin
 if u is null then raise exception 'authentication required' using errcode='42501'; end if;
 if p_session_id is null or p_reason is null or p_reason not in ('completed','skip','cancel') then return jsonb_build_object('status','denied','reason_code','invalid_finish'); end if;
 if coalesce(length(trim(p_request_id)),0) not between 1 and 128 then return jsonb_build_object('status','denied','reason_code','invalid_request_id'); end if;
 select * into s from public.real_ui_guide_sessions where id=p_session_id and user_id=u for update;
 if not found then return jsonb_build_object('status','denied','reason_code','session_not_found'); end if;
 h:=encode(sha256(convert_to(jsonb_build_array('finish',p_session_id,p_reason)::text,'UTF8')),'hex');
 select * into r from public.real_ui_guide_requests where user_id=u and request_id=p_request_id;
 if found then if r.request_hash is distinct from h then return jsonb_build_object('status','denied','reason_code','request_replay_mismatch'); end if; return r.response; end if;
 if s.terminal_reason is not null and s.terminal_reason is distinct from p_reason then return jsonb_build_object('status','denied','reason_code','invalid_finish'); end if;
 if s.terminal_reason is null then
  if p_reason='completed' and s.phase<>'updated' then return jsonb_build_object('status','denied','reason_code','invalid_finish'); end if;
  update public.real_ui_guide_sessions set phase='terminal',terminal_reason=p_reason,revision=revision+1 where id=s.id returning * into s;
 end if;
 out:=jsonb_build_object('status','ok','revision',s.revision);
 insert into public.real_ui_guide_requests(user_id,request_id,session_id,request_hash,response) values(u,p_request_id,s.id,h,out); return out;
end $$;
revoke all on function public.finish_real_ui_guide(uuid,text,text) from public,anon; grant execute on function public.finish_real_ui_guide(uuid,text,text) to authenticated;
