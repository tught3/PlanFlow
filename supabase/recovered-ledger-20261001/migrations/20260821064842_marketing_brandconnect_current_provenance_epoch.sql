-- Current official provenance epoch (additive, fail-closed).
-- This migration preserves the legacy source_fingerprint and
-- catalog_source_fingerprint contracts.  It does not change identity,
-- title, category, status, affiliate URLs, or delete rows.

alter table marketing_brandconnect.catalog_items
  add column if not exists source_kind text,
  add column if not exists source_snapshot_hash text,
  add column if not exists source_row_hash text,
  add column if not exists source_observed_at timestamptz,
  add column if not exists source_contract_version text,
  add column if not exists provenance_epoch text,
  add column if not exists source_active boolean,
  add column if not exists source_status text,
  add column if not exists current_provenance_fingerprint text;
alter table marketing_brandconnect.catalog_items
  drop constraint if exists marketing_brandconnect_current_provenance_hash_check;
alter table marketing_brandconnect.catalog_items
  add constraint marketing_brandconnect_current_provenance_hash_check
  check (
    (source_snapshot_hash is null or source_snapshot_hash ~ '^[a-f0-9]{64}$')
    and (source_row_hash is null or source_row_hash ~ '^[a-f0-9]{64}$')
    and (current_provenance_fingerprint is null or current_provenance_fingerprint ~ '^[a-f0-9]{64}$')
  );
create index if not exists marketing_brandconnect_catalog_current_provenance_idx
  on marketing_brandconnect.catalog_items(provenance_epoch, source_contract_version, observed_at)
  where current_provenance_fingerprint is not null;
drop function if exists marketing_brandconnect.compute_current_provenance_fingerprint(text,text,text,timestamptz,text,text,text);
create or replace function marketing_brandconnect.compute_current_provenance_fingerprint(
  p_source_kind text,
  p_source_snapshot_hash text,
  p_source_row_hash text,
  p_source_observed_at timestamptz,
  p_source_contract_version text,
  p_provenance_epoch text,
  p_channel_product_no text,
  p_source_active boolean,
  p_source_status text
)
returns text
language sql
immutable
strict
security invoker
set search_path = marketing_brandconnect, pg_catalog
as $$
  select encode(extensions.digest(convert_to(concat_ws('|',
    'brandconnect_current_provenance_epoch_v2',
    p_source_contract_version,
    p_provenance_epoch,
    p_source_kind,
    lower(p_source_snapshot_hash),
    lower(p_source_row_hash),
    p_channel_product_no,
    p_source_active::text,
    p_source_status
  ), 'UTF8'), 'sha256'), 'hex')
$$;
-- Only service_role may invoke this function.  It updates provenance columns
-- on existing identities and deliberately rejects payloads containing any
-- mutable business/data fields.
create or replace function marketing_brandconnect.backfill_current_provenance(
  p_rows jsonb,
  p_dry_run boolean default true
)
returns jsonb
language plpgsql
security definer
set search_path = marketing_brandconnect, pg_catalog
as $$
declare
  x jsonb;
  v_id text;
  v_expected text;
  v_existing text;
  v_seen text[] := array[]::text[];
  v_candidate integer := 0;
  v_missing integer := 0;
  v_updated integer := 0;
begin
  if jsonb_typeof(coalesce(p_rows, 'null'::jsonb)) <> 'array' then
    raise exception 'current_provenance_rows_array_required';
  end if;
  for x in select value from jsonb_array_elements(p_rows) loop
    if x ?| array[
      'title','is_active','active','status','category_id','category_key',
      'category_name','category_status','category_status_reason','affiliate_url',
      'affiliate_source','affiliate_issued_at','price_won','image_url','provider'
    ] then
      raise exception 'current_provenance_mutable_field_forbidden';
    end if;
    v_id := nullif(btrim(x->>'channel_product_no'), '');
    if v_id is null or v_id = any(v_seen) then
      raise exception 'current_provenance_identity_invalid';
    end if;
    v_seen := array_append(v_seen, v_id);
    if nullif(btrim(x->>'source_kind'), '') is null
       or (x->>'source_snapshot_hash') !~ '^[a-f0-9]{64}$'
       or (x->>'source_row_hash') !~ '^[a-f0-9]{64}$'
       or nullif(x->>'source_observed_at', '') is null
       or x->>'source_contract_version' <> 'brandconnect_current_provenance_epoch_v2'
       or x->>'provenance_epoch' <> 'CURRENT_OFFICIAL_V1'
       or x->>'source_kind' <> 'brandconnect_official_store_xhr'
       or lower(x->>'source_snapshot_hash') <> 'c7cd98dc95fed5565ea88bbc9f789c59d5da0a1f64482ce7cf6300050acc5740'
       or jsonb_typeof(x->'source_active') <> 'boolean'
       or nullif(btrim(x->>'source_status'), '') is null
       or (x->>'current_provenance_fingerprint') !~ '^[a-f0-9]{64}$' then
      raise exception 'current_provenance_payload_invalid:%', v_id;
    end if;
    begin
      v_expected := compute_current_provenance_fingerprint(
        x->>'source_kind', lower(x->>'source_snapshot_hash'), lower(x->>'source_row_hash'),
        (x->>'source_observed_at')::timestamptz,
        x->>'source_contract_version', x->>'provenance_epoch', v_id,
        (x->>'source_active')::boolean, x->>'source_status'
      );
    exception when others then
      raise exception 'current_provenance_timestamp_invalid:%', v_id;
    end;
    if lower(x->>'current_provenance_fingerprint') <> v_expected then
      raise exception 'current_provenance_fingerprint_mismatch:%', v_id;
    end if;
    select current_provenance_fingerprint into v_existing
      from catalog_items where channel_product_no = v_id;
    if not found then
      v_missing := v_missing + 1;
      continue;
    end if;
    v_candidate := v_candidate + 1;
    if not p_dry_run then
      update catalog_items
         set source_kind = x->>'source_kind',
             source_snapshot_hash = lower(x->>'source_snapshot_hash'),
             source_row_hash = lower(x->>'source_row_hash'),
             source_observed_at = (x->>'source_observed_at')::timestamptz,
             source_contract_version = x->>'source_contract_version',
             provenance_epoch = x->>'provenance_epoch',
             source_active = (x->>'source_active')::boolean,
             source_status = x->>'source_status',
             current_provenance_fingerprint = lower(x->>'current_provenance_fingerprint')
       where channel_product_no = v_id;
      v_updated := v_updated + 1;
    end if;
  end loop;
  return jsonb_build_object(
    'status', case when p_dry_run then 'DRY_RUN' else 'APPLIED' end,
    'candidate_count', v_candidate,
    'missing_identity_count', v_missing,
    'updated_count', v_updated,
    'mutable_business_field_updates', 0,
    'affiliate_url_mutations', 0,
    'category_mutations', 0,
    'identity_mutations', 0,
    'deleted_rows', 0
  );
end
$$;
-- General issuance is current-epoch-only. Balanced remains governed by its
-- existing category/evidence predicates in the preceding migration.
create or replace function marketing_brandconnect.pending_general(p_limit integer default 1)
returns jsonb
language sql
security definer
set search_path = marketing_brandconnect, pg_catalog
as $$
  select coalesce(jsonb_agg(q.channel_product_no order by q.observed_at, q.channel_product_no), '[]'::jsonb)
    from (
      select c.channel_product_no, c.observed_at
        from catalog_items c
       where c.provider = 'brandconnect'
         and c.is_active and c.affiliate_url is null
         and c.source_contract_version = 'brandconnect_current_provenance_epoch_v2'
         and c.provenance_epoch = 'CURRENT_OFFICIAL_V1'
         and c.source_kind is not null
         and c.source_snapshot_hash ~ '^[a-f0-9]{64}$'
         and c.source_row_hash ~ '^[a-f0-9]{64}$'
         and c.source_observed_at is not null
         and c.source_active = true
         and c.source_status not in ('INACTIVE','DISABLED','DELETED')
         and c.current_provenance_fingerprint = compute_current_provenance_fingerprint(c.source_kind,c.source_snapshot_hash,c.source_row_hash,c.source_observed_at,c.source_contract_version,c.provenance_epoch,c.channel_product_no,c.source_active,c.source_status)
         and not exists (select 1 from issuance_reservation_items i join issuance_reservations r using (reservation_id) where i.channel_product_no=c.channel_product_no and i.status='RESERVED' and r.status='RESERVED')
       order by c.observed_at, c.channel_product_no
       limit greatest(1, least(coalesce(p_limit,1),200))
    ) q
$$;
create or replace function marketing_brandconnect.reserve_general(p_limit integer default 30)
returns jsonb
language plpgsql
security definer
set search_path = marketing_brandconnect, pg_catalog
as $$
  declare v_limit integer := greatest(1, least(coalesce(p_limit,30),50)); v_reservation uuid; v_ids jsonb; v_candidates integer;
begin
  perform pg_advisory_xact_lock(hashtextextended('brandconnect:general',0));
  select count(*) into v_candidates from catalog_items c
   where c.provider='brandconnect' and c.is_active and c.affiliate_url is null
     and c.source_contract_version='brandconnect_current_provenance_epoch_v2' and c.provenance_epoch='CURRENT_OFFICIAL_V1'
     and c.source_kind is not null and c.source_snapshot_hash ~ '^[a-f0-9]{64}$' and c.source_row_hash ~ '^[a-f0-9]{64}$' and c.source_observed_at is not null
     and c.source_active = true and c.source_status not in ('INACTIVE','DISABLED','DELETED')
     and c.current_provenance_fingerprint=compute_current_provenance_fingerprint(c.source_kind,c.source_snapshot_hash,c.source_row_hash,c.source_observed_at,c.source_contract_version,c.provenance_epoch,c.channel_product_no,c.source_active,c.source_status)
     and not exists (select 1 from issuance_reservation_items i join issuance_reservations r using(reservation_id) where i.channel_product_no=c.channel_product_no and i.status='RESERVED' and r.status='RESERVED');
  -- The shared reservation table retains its historical 30..50 metadata
  -- contract; the General lane limit controls the actual selected IDs.
  insert into issuance_reservations(category_id,sync_run_id,requested_count,selected_at,last_selected_at,issuance_mode) values(null,null,greatest(30,v_limit),now(),now(),'GENERAL') returning reservation_id into v_reservation;
  insert into issuance_reservation_items(reservation_id,channel_product_no)
    select v_reservation,c.channel_product_no from catalog_items c
     where c.provider='brandconnect' and c.is_active and c.affiliate_url is null
        and c.source_contract_version='brandconnect_current_provenance_epoch_v2' and c.provenance_epoch='CURRENT_OFFICIAL_V1' and c.source_kind is not null
        and c.source_snapshot_hash ~ '^[a-f0-9]{64}$' and c.source_row_hash ~ '^[a-f0-9]{64}$' and c.source_observed_at is not null
        and c.source_active = true and c.source_status not in ('INACTIVE','DISABLED','DELETED')
        and c.current_provenance_fingerprint=compute_current_provenance_fingerprint(c.source_kind,c.source_snapshot_hash,c.source_row_hash,c.source_observed_at,c.source_contract_version,c.provenance_epoch,c.channel_product_no,c.source_active,c.source_status)
       and not exists (select 1 from issuance_reservation_items i join issuance_reservations r using(reservation_id) where i.channel_product_no=c.channel_product_no and i.status='RESERVED' and r.status='RESERVED')
     order by c.observed_at,c.channel_product_no limit v_limit for update skip locked;
  select coalesce(jsonb_agg(channel_product_no order by channel_product_no),'[]'::jsonb) into v_ids from issuance_reservation_items where reservation_id=v_reservation;
  return jsonb_build_object('mode','GENERAL','reservation_id',v_reservation,'ids',v_ids,'count',jsonb_array_length(v_ids),'total_candidates',v_candidates,'category_required',false);
end
$$;
-- Balanced selection also requires the same current official provenance. This
-- keeps production-only identities ineligible even if category evidence changes.
create or replace function marketing_brandconnect.pending(p_limit integer,p_category_id text,p_sync_run_id uuid)
returns jsonb language sql security definer set search_path=marketing_brandconnect,pg_catalog as $$
select case when not exists(select 1 from category_sync_runs where run_id=p_sync_run_id and status='COMPLETE' and observed_at>=now()-interval '6 hours') then raise_pending_context() else coalesce(jsonb_agg(q.channel_product_no order by q.observed_at,q.channel_product_no),'[]'::jsonb) end
from (select c.channel_product_no,c.observed_at from catalog_items c
 where c.category_status='CONFIRMED' and c.catalog_source_fingerprint ~ '^[a-f0-9]{64}$' and c.category_evidence_fingerprint ~ '^[a-f0-9]{64}$'
   and c.is_active and c.affiliate_url is null
   and c.source_contract_version='brandconnect_current_provenance_epoch_v2' and c.provenance_epoch='CURRENT_OFFICIAL_V1'
   and c.source_active=true and c.source_status not in ('INACTIVE','DISABLED','DELETED')
   and c.current_provenance_fingerprint=compute_current_provenance_fingerprint(c.source_kind,c.source_snapshot_hash,c.source_row_hash,c.source_observed_at,c.source_contract_version,c.provenance_epoch,c.channel_product_no,c.source_active,c.source_status)
   and (p_category_id is null or c.category_key=btrim(p_category_id))
   and not exists(select 1 from issuance_reservation_items i join issuance_reservations r using(reservation_id) where i.channel_product_no=c.channel_product_no and i.status='RESERVED' and r.status='RESERVED')
 order by c.observed_at,c.channel_product_no limit greatest(1,least(coalesce(p_limit,1),200))) q
$$;
create or replace function marketing_brandconnect.pending_category(p_limit integer,p_category_id text,p_sync_run_id uuid)
returns jsonb language sql security definer set search_path=marketing_brandconnect,pg_catalog as $$ select marketing_brandconnect.pending(p_limit,p_category_id,p_sync_run_id) $$;
create or replace function marketing_brandconnect.reserve_category(p_limit integer,p_sync_run_id uuid,p_category_id text default null)
returns jsonb language plpgsql security definer set search_path=marketing_brandconnect,pg_catalog as $$
declare lim integer:=greatest(1,least(coalesce(p_limit,30),50)); cat text; nm text; rid uuid; ids jsonb; before_count integer; candidate_count integer;
begin
  if not exists(select 1 from category_sync_runs where run_id=p_sync_run_id and status='COMPLETE' and observed_at>=now()-interval '6 hours') then raise exception 'category_sync_unavailable'; end if;
  if p_category_id is null then select r.category_id,r.category_name into cat,nm from category_registry r where r.active and r.last_observed_at>=now()-interval '6 hours' order by (select count(*) from catalog_items c where c.category_status='CONFIRMED' and c.category_key=r.category_id and c.affiliate_url is not null),coalesce(r.last_selected_at,'epoch'::timestamptz),r.category_id limit 1;
  else select r.category_id,r.category_name into cat,nm from category_registry r where r.category_id=btrim(p_category_id) and r.active and r.last_observed_at>=now()-interval '6 hours'; end if;
  if cat is null then raise exception 'category_unknown_or_inactive'; end if;
  perform pg_advisory_xact_lock(hashtextextended(cat,0));
  select count(*) into before_count from catalog_items c where c.category_status='CONFIRMED' and c.catalog_source_fingerprint ~ '^[a-f0-9]{64}$' and c.category_evidence_fingerprint ~ '^[a-f0-9]{64}$' and c.category_key=cat and c.affiliate_url is not null;
  select count(*) into candidate_count from catalog_items c where c.is_active and c.category_status='CONFIRMED' and c.catalog_source_fingerprint ~ '^[a-f0-9]{64}$' and c.category_evidence_fingerprint ~ '^[a-f0-9]{64}$' and c.category_key=cat and c.affiliate_url is null and c.source_contract_version='brandconnect_current_provenance_epoch_v2' and c.provenance_epoch='CURRENT_OFFICIAL_V1' and c.source_active=true and c.source_status not in ('INACTIVE','DISABLED','DELETED') and c.current_provenance_fingerprint=compute_current_provenance_fingerprint(c.source_kind,c.source_snapshot_hash,c.source_row_hash,c.source_observed_at,c.source_contract_version,c.provenance_epoch,c.channel_product_no,c.source_active,c.source_status) and not exists(select 1 from issuance_reservation_items i join issuance_reservations r using(reservation_id) where i.channel_product_no=c.channel_product_no and i.status='RESERVED' and r.status='RESERVED');
  insert into issuance_reservations(category_id,sync_run_id,requested_count,selected_at,last_selected_at) values(cat,p_sync_run_id,lim,now(),now()) returning reservation_id into rid;
  update category_registry set last_selected_at=now() where category_id=cat;
  insert into issuance_reservation_items(reservation_id,channel_product_no) select rid,c.channel_product_no from catalog_items c where c.is_active and c.category_status='CONFIRMED' and c.catalog_source_fingerprint ~ '^[a-f0-9]{64}$' and c.category_evidence_fingerprint ~ '^[a-f0-9]{64}$' and c.category_key=cat and c.affiliate_url is null and c.source_contract_version='brandconnect_current_provenance_epoch_v2' and c.provenance_epoch='CURRENT_OFFICIAL_V1' and c.source_active=true and c.source_status not in ('INACTIVE','DISABLED','DELETED') and c.current_provenance_fingerprint=compute_current_provenance_fingerprint(c.source_kind,c.source_snapshot_hash,c.source_row_hash,c.source_observed_at,c.source_contract_version,c.provenance_epoch,c.channel_product_no,c.source_active,c.source_status) and not exists(select 1 from issuance_reservation_items i join issuance_reservations r using(reservation_id) where i.channel_product_no=c.channel_product_no and i.status='RESERVED' and r.status='RESERVED') order by c.observed_at,c.channel_product_no limit lim for update skip locked;
  select coalesce(jsonb_agg(channel_product_no order by channel_product_no),'[]'::jsonb) into ids from issuance_reservation_items where reservation_id=rid;
  return jsonb_build_object('reservation_id',rid,'category_path',cat,'category_name',nm,'ids',ids,'count',jsonb_array_length(ids),'total_candidates',candidate_count,'category_link_count_before',before_count);
end $$;
do $$
begin
  revoke all on function marketing_brandconnect.compute_current_provenance_fingerprint(text,text,text,timestamptz,text,text,text,boolean,text) from public,anon,authenticated;
  grant execute on function marketing_brandconnect.compute_current_provenance_fingerprint(text,text,text,timestamptz,text,text,text,boolean,text) to service_role;
  revoke all on function marketing_brandconnect.backfill_current_provenance(jsonb,boolean) from public,anon,authenticated;
  grant execute on function marketing_brandconnect.backfill_current_provenance(jsonb,boolean) to service_role;
  revoke all on function marketing_brandconnect.pending_general(integer) from public,anon,authenticated;
  grant execute on function marketing_brandconnect.pending_general(integer) to service_role;
  revoke all on function marketing_brandconnect.reserve_general(integer) from public,anon,authenticated;
  grant execute on function marketing_brandconnect.reserve_general(integer) to service_role;
end
$$;
do $$
begin
  if not exists (select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='marketing_brandconnect' and p.proname='backfill_current_provenance' and p.pronargs=2 and p.proargtypes::text='3802 16') then
    raise exception 'current_provenance_backfill_signature_missing';
  end if;
  if has_function_privilege('public','marketing_brandconnect.backfill_current_provenance(jsonb,boolean)','execute') or has_function_privilege('anon','marketing_brandconnect.backfill_current_provenance(jsonb,boolean)','execute') or has_function_privilege('authenticated','marketing_brandconnect.backfill_current_provenance(jsonb,boolean)','execute') then
    raise exception 'current_provenance_backfill_public_grant';
  end if;
  if not has_function_privilege('service_role','marketing_brandconnect.backfill_current_provenance(jsonb,boolean)','execute') then
    raise exception 'current_provenance_backfill_service_role_grant_missing';
  end if;
end
$$;
