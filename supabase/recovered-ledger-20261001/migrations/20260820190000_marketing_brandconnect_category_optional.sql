-- MARKETINGFLOW additive Category Optional contract; Phase A is immutable.
-- Shadow/replay validation artifact. Do not apply to production in this phase.
alter table marketing_brandconnect.catalog_items
  add column if not exists category_status text,
  add column if not exists category_status_reason text,
  add column if not exists catalog_source_fingerprint text,
  add column if not exists category_evidence_fingerprint text;
update marketing_brandconnect.catalog_items
set catalog_source_fingerprint = source_fingerprint
where catalog_source_fingerprint is null and source_fingerprint ~ '^[a-f0-9]{64}$';
do $$ begin
  if exists (select 1 from marketing_brandconnect.catalog_items where (category_id is null) <> (category_name is null)) then
    raise exception 'category_optional_partial_category_pair';
  end if;
end $$;
-- Existing Phase A rows have no category evidence contract.  Keep them fail-closed:
-- only rows carrying both verified fingerprints remain CONFIRMED; pair-only rows
-- lose the unverified category fields and remain explicitly UNRESOLVED.
update marketing_brandconnect.catalog_items
set category_status = case
      when category_id is not null and category_name is not null
       and catalog_source_fingerprint ~ '^[a-f0-9]{64}$'
       and category_evidence_fingerprint ~ '^[a-f0-9]{64}$' then 'CONFIRMED'
      else 'UNRESOLVED' end,
    category_status_reason = case
      when category_id is not null and category_name is not null
       and catalog_source_fingerprint ~ '^[a-f0-9]{64}$'
       and category_evidence_fingerprint ~ '^[a-f0-9]{64}$' then null
      else coalesce(category_status_reason,'OFFICIAL_CATEGORY_EVIDENCE_MISSING') end,
    category_id = case when category_id is not null and category_name is not null
       and catalog_source_fingerprint ~ '^[a-f0-9]{64}$'
       and category_evidence_fingerprint ~ '^[a-f0-9]{64}$' then category_id else null end,
    category_key = case when category_id is not null and category_name is not null
       and catalog_source_fingerprint ~ '^[a-f0-9]{64}$'
       and category_evidence_fingerprint ~ '^[a-f0-9]{64}$' then category_key else null end,
    category_name = case when category_id is not null and category_name is not null
       and catalog_source_fingerprint ~ '^[a-f0-9]{64}$'
       and category_evidence_fingerprint ~ '^[a-f0-9]{64}$' then category_name else null end,
    category_source = case when category_id is not null and category_name is not null
       and catalog_source_fingerprint ~ '^[a-f0-9]{64}$'
       and category_evidence_fingerprint ~ '^[a-f0-9]{64}$' then category_source else null end,
    category_observed_at = case when category_id is not null and category_name is not null
       and catalog_source_fingerprint ~ '^[a-f0-9]{64}$'
       and category_evidence_fingerprint ~ '^[a-f0-9]{64}$' then category_observed_at else null end,
    category_evidence_fingerprint = case when category_id is not null and category_name is not null
       and catalog_source_fingerprint ~ '^[a-f0-9]{64}$'
       and category_evidence_fingerprint ~ '^[a-f0-9]{64}$' then category_evidence_fingerprint else null end;
-- Pair-only legacy rows have no independently verified category evidence.
-- Keep them in the catalog as unresolved and clear the pair so the invariant
-- cannot be bypassed by a stale category_id/category_name.
update marketing_brandconnect.catalog_items
set category_id = null, category_key = null, category_name = null,
    category_source = null, category_observed_at = null
where category_status = 'UNRESOLVED'
  and (category_id is not null or category_name is not null);
alter table marketing_brandconnect.catalog_items alter column category_status set default 'UNRESOLVED', alter column category_status set not null;
alter table marketing_brandconnect.catalog_items drop constraint if exists marketing_brandconnect_category_status_check;
alter table marketing_brandconnect.catalog_items add constraint marketing_brandconnect_category_status_check check ((category_status='CONFIRMED' and category_id is not null and category_name is not null) or (category_status='UNRESOLVED' and category_id is null and category_name is null));
alter table marketing_brandconnect.catalog_items drop constraint if exists marketing_brandconnect_category_fingerprint_check;
alter table marketing_brandconnect.catalog_items add constraint marketing_brandconnect_category_fingerprint_check check ((catalog_source_fingerprint is null or catalog_source_fingerprint ~ '^[a-f0-9]{64}$') and (category_evidence_fingerprint is null or category_evidence_fingerprint ~ '^[a-f0-9]{64}$') and not (category_status='UNRESOLVED' and category_evidence_fingerprint is not null));
create index if not exists marketing_brandconnect_catalog_confirmed_category_idx on marketing_brandconnect.catalog_items(category_id,channel_product_no) where category_status='CONFIRMED';
alter table marketing_brandconnect.catalog_items drop constraint if exists marketing_brandconnect_catalog_category_source;
alter table marketing_brandconnect.catalog_items add constraint marketing_brandconnect_catalog_category_source check (category_source is null or category_source in ('brandconnect_live','preserved','manual_review','user_verified_ui_devtools_network','brandconnect_live_endpoint_only_id','official-api','smartstore_browser_xhr'));
create or replace function marketing_brandconnect._validate_optional_catalog_row(p_row jsonb)
returns text language plpgsql security definer set search_path=marketing_brandconnect,pg_catalog as $$
declare s text; id text; nm text; reason text; src text; endpoint text; registry_name text;
begin
  id:=nullif(btrim(p_row->>'category_id'),''); nm:=nullif(btrim(p_row->>'category_name'),'');
  s:=upper(coalesce(nullif(btrim(p_row->>'category_status'),''),case when id is not null or nm is not null then 'CONFIRMED' else 'UNRESOLVED' end));
  reason:=coalesce(nullif(btrim(p_row->>'category_status_reason'),''),'OFFICIAL_CATEGORY_EVIDENCE_MISSING');
  if s not in ('CONFIRMED','UNRESOLVED') then raise exception 'import_category_status_invalid'; end if;
  if s='CONFIRMED' and (id is null or nm is null) then raise exception 'import_category_pair_required'; end if;
  if s='UNRESOLVED' and (id is not null or nm is not null) then raise exception 'import_category_unresolved_values'; end if;
  if s='UNRESOLVED' and reason not in ('OFFICIAL_CATEGORY_EVIDENCE_MISSING','RATE_LIMIT_CHECKPOINT') then raise exception 'import_category_reason_invalid'; end if;
  if p_row->>'catalog_source_fingerprint' is null or p_row->>'catalog_source_fingerprint' !~ '^[a-f0-9]{64}$' then raise exception 'import_catalog_fingerprint_required'; end if;
  if s='CONFIRMED' then
    if p_row->>'category_evidence_fingerprint' is null or p_row->>'category_evidence_fingerprint' !~ '^[a-f0-9]{64}$' then raise exception 'import_category_evidence_fingerprint_required'; end if;
    src:=nullif(btrim(p_row->>'category_source'),''); endpoint:=nullif(btrim(p_row->>'category_endpoint'),'');
    if src not in ('brandconnect_live','official-api','smartstore_browser_xhr','user_verified_ui_devtools_network','preserved') then raise exception 'import_category_source_invalid'; end if;
    if endpoint is null or endpoint not like 'https://gw-brandconnect.naver.com/%' then raise exception 'import_category_endpoint_invalid'; end if;
    select category_name into registry_name from category_registry where category_id=id and active;
    if registry_name is null or registry_name is distinct from nm then raise exception 'import_category_registry_mismatch'; end if;
  end if;
  return s;
end $$;
create or replace function marketing_brandconnect.raise_pending_context() returns jsonb language plpgsql security definer set search_path=marketing_brandconnect,pg_catalog as $$ begin raise exception 'category_sync_context_required'; end $$;
-- Drop the dependent compatibility wrapper before replacing its callee.
drop function if exists marketing_brandconnect.pending_category(integer,text);
drop function if exists marketing_brandconnect.pending(integer,text);
create or replace function marketing_brandconnect.pending(p_limit integer,p_category_id text,p_sync_run_id uuid)
returns jsonb language sql security definer set search_path=marketing_brandconnect,pg_catalog as $$
select case when not exists(select 1 from category_sync_runs where run_id=p_sync_run_id and status='COMPLETE' and observed_at>=now()-interval '6 hours') then raise_pending_context() else coalesce(jsonb_agg(q.channel_product_no order by q.observed_at,q.channel_product_no),'[]'::jsonb) end from (select c.channel_product_no,c.observed_at from catalog_items c where c.category_status='CONFIRMED' and c.catalog_source_fingerprint ~ '^[a-f0-9]{64}$' and c.category_evidence_fingerprint ~ '^[a-f0-9]{64}$' and c.is_active and c.affiliate_url is null and (p_category_id is null or c.category_key=btrim(p_category_id)) and not exists(select 1 from issuance_reservation_items i join issuance_reservations r using(reservation_id) where i.channel_product_no=c.channel_product_no and i.status='RESERVED' and r.status='RESERVED') order by c.observed_at,c.channel_product_no limit greatest(1,least(coalesce(p_limit,1),200))) q
$$;
create or replace function marketing_brandconnect.pending_category(p_limit integer,p_category_id text,p_sync_run_id uuid) returns jsonb language sql security definer set search_path=marketing_brandconnect,pg_catalog as $$ select marketing_brandconnect.pending(p_limit,p_category_id,p_sync_run_id) $$;
create or replace function marketing_brandconnect.reserve_category(p_limit integer,p_sync_run_id uuid,p_category_id text default null)
returns jsonb language plpgsql security definer set search_path=marketing_brandconnect,pg_catalog as $$
declare lim integer:=greatest(30,least(coalesce(p_limit,30),50)); cat text; nm text; rid uuid; ids jsonb; before_count integer; candidate_count integer;
begin
  if not exists(select 1 from category_sync_runs where run_id=p_sync_run_id and status='COMPLETE' and observed_at>=now()-interval '6 hours') then raise exception 'category_sync_unavailable'; end if;
  if p_category_id is null then select r.category_id,r.category_name into cat,nm from category_registry r where r.active and r.last_observed_at>=now()-interval '6 hours' order by (select count(*) from catalog_items c where c.category_status='CONFIRMED' and c.category_key=r.category_id and c.affiliate_url is not null),coalesce(r.last_selected_at,'epoch'::timestamptz),r.category_id limit 1;
  else select r.category_id,r.category_name into cat,nm from category_registry r where r.category_id=btrim(p_category_id) and r.active and r.last_observed_at>=now()-interval '6 hours'; end if;
  if cat is null then raise exception 'category_unknown_or_inactive'; end if;
  perform pg_advisory_xact_lock(hashtextextended(cat,0));
  select count(*) into before_count from catalog_items c where c.category_status='CONFIRMED' and c.catalog_source_fingerprint ~ '^[a-f0-9]{64}$' and c.category_evidence_fingerprint ~ '^[a-f0-9]{64}$' and c.category_key=cat and c.affiliate_url is not null;
  select count(*) into candidate_count from catalog_items c where c.is_active and c.category_status='CONFIRMED' and c.catalog_source_fingerprint ~ '^[a-f0-9]{64}$' and c.category_evidence_fingerprint ~ '^[a-f0-9]{64}$' and c.category_key=cat and c.affiliate_url is null and not exists(select 1 from issuance_reservation_items i join issuance_reservations r using(reservation_id) where i.channel_product_no=c.channel_product_no and i.status='RESERVED' and r.status='RESERVED');
  insert into issuance_reservations(category_id,sync_run_id,requested_count,selected_at,last_selected_at) values(cat,p_sync_run_id,lim,now(),now()) returning reservation_id into rid;
  update category_registry set last_selected_at=now() where category_id=cat;
  insert into issuance_reservation_items(reservation_id,channel_product_no) select rid,c.channel_product_no from catalog_items c where c.is_active and c.category_status='CONFIRMED' and c.catalog_source_fingerprint ~ '^[a-f0-9]{64}$' and c.category_evidence_fingerprint ~ '^[a-f0-9]{64}$' and c.category_key=cat and c.affiliate_url is null and not exists(select 1 from issuance_reservation_items i join issuance_reservations r using(reservation_id) where i.channel_product_no=c.channel_product_no and i.status='RESERVED' and r.status='RESERVED') order by c.observed_at,c.channel_product_no limit lim for update skip locked;
  select coalesce(jsonb_agg(channel_product_no order by channel_product_no),'[]'::jsonb) into ids from issuance_reservation_items where reservation_id=rid;
  return jsonb_build_object('reservation_id',rid,'category_path',cat,'category_name',nm,'ids',ids,'count',jsonb_array_length(ids),'total_candidates',candidate_count,'category_link_count_before',before_count);
end $$;
create or replace function marketing_brandconnect.get_category_link_counts() returns jsonb language sql security definer set search_path=marketing_brandconnect,pg_catalog as $$
select coalesce(jsonb_object_agg(r.category_id,jsonb_build_object('category_name',r.category_name,'link_count',(select count(*) from catalog_items c where c.category_status='CONFIRMED' and c.catalog_source_fingerprint ~ '^[a-f0-9]{64}$' and c.category_evidence_fingerprint ~ '^[a-f0-9]{64}$' and c.category_key=r.category_id and c.affiliate_url is not null))),'{}'::jsonb)||jsonb_build_object('unresolved_count',(select count(*) from catalog_items c where c.category_status='UNRESOLVED' and c.is_active)) from category_registry r where r.active
$$;
create or replace function marketing_brandconnect.import_catalog(p_rows jsonb,p_strategy text default 'RECOLLECT',p_dry_run boolean default true)
returns jsonb language plpgsql security definer set search_path=marketing_brandconnect,pg_catalog as $$
declare x jsonb; id text; title text; url text; old_url text; old_status text; old_category_id text; old_category_name text; old_evidence text; status text; rows_count integer:=0; updated_count integer:=0; conflicts integer:=0;
begin
  if jsonb_typeof(p_rows)<>'array' or jsonb_array_length(p_rows)=0 then raise exception 'import_rows_required'; end if;
  for x in select value from jsonb_array_elements(p_rows) loop
    id:=nullif(btrim(x->>'channel_product_no'),''); title:=nullif(btrim(x->>'title'),''); url:=nullif(btrim(x->>'affiliate_url'),'');
    if id is null or title is null then raise exception 'import_identity_or_title_required'; end if;
    if url is not null and url !~ '^https://naver[.]me/[^/?#]+$' then raise exception 'import_affiliate_url_invalid'; end if;
    status:=marketing_brandconnect._validate_optional_catalog_row(x);
    select affiliate_url,category_status,category_id,category_name,category_evidence_fingerprint into old_url,old_status,old_category_id,old_category_name,old_evidence from catalog_items where channel_product_no=id;
    if old_url is not null and url is not null and old_url<>url then conflicts:=conflicts+1; end if;
    if old_status='CONFIRMED' and status='CONFIRMED' and (old_category_id is distinct from x->>'category_id' or old_category_name is distinct from x->>'category_name' or old_evidence is distinct from x->>'category_evidence_fingerprint') then raise exception 'import_category_evidence_conflict:%',id; end if;
    rows_count:=rows_count+1;
    if not p_dry_run then
      insert into catalog_items(channel_product_no,title,category_id,category_key,category_name,category_source,category_observed_at,category_status,category_status_reason,source_fingerprint,catalog_source_fingerprint,category_evidence_fingerprint,is_active,observed_at,affiliate_url,affiliate_source,affiliate_issued_at)
      values(id,title,nullif(x->>'category_id',''),nullif(coalesce(x->>'category_key',x->>'category_id'),''),nullif(x->>'category_name',''),nullif(x->>'category_source',''),nullif(x->>'category_observed_at','')::timestamptz,status,case when status='UNRESOLVED' then coalesce(nullif(x->>'category_status_reason',''),'OFFICIAL_CATEGORY_EVIDENCE_MISSING') else null end,x->>'catalog_source_fingerprint',x->>'catalog_source_fingerprint',x->>'category_evidence_fingerprint',coalesce((x->>'is_active')::boolean,true),coalesce(nullif(x->>'observed_at','')::timestamptz,now()),url,case when url is null then null else 'preserved' end,case when url is null then null else now() end)
      on conflict(channel_product_no) do update set title=excluded.title,is_active=excluded.is_active,observed_at=excluded.observed_at,category_id=case when catalog_items.category_status='CONFIRMED' and excluded.category_status='UNRESOLVED' then catalog_items.category_id else excluded.category_id end,category_key=case when catalog_items.category_status='CONFIRMED' and excluded.category_status='UNRESOLVED' then catalog_items.category_key else excluded.category_key end,category_name=case when catalog_items.category_status='CONFIRMED' and excluded.category_status='UNRESOLVED' then catalog_items.category_name else excluded.category_name end,category_source=case when catalog_items.category_status='CONFIRMED' and excluded.category_status='UNRESOLVED' then catalog_items.category_source else excluded.category_source end,category_observed_at=case when catalog_items.category_status='CONFIRMED' and excluded.category_status='UNRESOLVED' then catalog_items.category_observed_at else excluded.category_observed_at end,category_status=case when catalog_items.category_status='CONFIRMED' and excluded.category_status='UNRESOLVED' then catalog_items.category_status else excluded.category_status end,category_status_reason=case when catalog_items.category_status='CONFIRMED' and excluded.category_status='UNRESOLVED' then catalog_items.category_status_reason else excluded.category_status_reason end,source_fingerprint=excluded.source_fingerprint,catalog_source_fingerprint=excluded.catalog_source_fingerprint,category_evidence_fingerprint=case when excluded.category_status='CONFIRMED' then excluded.category_evidence_fingerprint else catalog_items.category_evidence_fingerprint end,updated_at=now();
      updated_count:=updated_count+1;
    end if;
  end loop;
  if conflicts>0 then raise exception 'import_affiliate_conflict:%',conflicts; end if;
  return jsonb_build_object('rows',rows_count,'updated',updated_count,'conflicts',conflicts,'dry_run',p_dry_run,'strategy',p_strategy,'identity_key','channel_product_no','overwrite_affiliate_url',false);
end $$;
create or replace function marketing_brandconnect.preserve_catalog(p_rows jsonb,p_dry_run boolean default true) returns jsonb language sql security definer set search_path=marketing_brandconnect,pg_catalog as $$ select marketing_brandconnect.import_catalog(p_rows,'PRESERVE_MERGE',p_dry_run) $$;
create or replace function marketing_brandconnect.recollect_merge_catalog(p_rows jsonb,p_dry_run boolean default true) returns jsonb language sql security definer set search_path=marketing_brandconnect,pg_catalog as $$ select marketing_brandconnect.import_catalog(p_rows,'RECOLLECT',p_dry_run) $$;
do $$ declare f record; begin for f in select * from (values ('_validate_optional_catalog_row(jsonb)'),('raise_pending_context()'),('pending(integer,text,uuid)'),('pending_category(integer,text,uuid)'),('reserve_category(integer,uuid,text)'),('get_category_link_counts()'),('import_catalog(jsonb,text,boolean)'),('preserve_catalog(jsonb,boolean)'),('recollect_merge_catalog(jsonb,boolean)')) as x(signature) loop execute format('revoke all on function marketing_brandconnect.%s from public,anon,authenticated',f.signature); execute format('grant execute on function marketing_brandconnect.%s to service_role',f.signature); end loop; end $$;
