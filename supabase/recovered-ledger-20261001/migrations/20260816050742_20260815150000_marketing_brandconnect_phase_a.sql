-- BrandConnect ownership migration package, Phase A only.
-- Target: Supabase project xqvvfnvmytjlblcngipn (MarketingFlow boundary).
-- This migration is prepared for review and is intentionally not applied in Phase A.

-- Fingerprint verification depends on pgcrypto's SHA-256 digest. Keep the
-- dependency explicit; the RPC uses extensions.digest below and will fail at
-- migration time rather than silently accepting an unverifiable manifest.
create extension if not exists pgcrypto with schema extensions;

create schema if not exists marketing_brandconnect;

create table if not exists marketing_brandconnect.catalog_items (
  channel_product_no text primary key,
  provider text not null default 'brandconnect',
  title text not null,
  price_won bigint,
  store_name text,
  brand text,
  image_url text,
  category_id text,
  category_name text,
  category_source text,
  category_observed_at timestamptz,
  is_active boolean not null default true,
  observed_at timestamptz not null default now(),
  affiliate_url text,
  affiliate_source text,
  affiliate_issued_at timestamptz,
  source_fingerprint text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint marketing_brandconnect_catalog_provider check (provider = 'brandconnect'),
  constraint marketing_brandconnect_catalog_affiliate_url check (affiliate_url is null or affiliate_url ~ '^https://naver[.]me/[^/?#]+$'),
  constraint marketing_brandconnect_catalog_category_source check (category_source is null or category_source in ('brandconnect_live','preserved','manual_review','user_verified_ui_devtools_network','brandconnect_live_endpoint_only_id'))
);

-- Keep an already-created Phase A table compatible with the complete
-- provenance allowlist as well as a fresh install.
alter table marketing_brandconnect.catalog_items
  drop constraint if exists marketing_brandconnect_catalog_category_source;
alter table marketing_brandconnect.catalog_items
  add constraint marketing_brandconnect_catalog_category_source
  check (category_source is null or category_source in ('brandconnect_live','preserved','manual_review','user_verified_ui_devtools_network','brandconnect_live_endpoint_only_id'));

-- Stable category identity used by the balancing RPCs.  category_id remains
-- the public Phase A field for compatibility; category_key is the canonical
-- reservation/count key and is populated only from an official observation.
alter table marketing_brandconnect.catalog_items
  add column if not exists category_key text;

create index if not exists marketing_brandconnect_catalog_category_idx
  on marketing_brandconnect.catalog_items(category_id, is_active);
create index if not exists marketing_brandconnect_catalog_pending_idx
  on marketing_brandconnect.catalog_items(category_id, observed_at)
  where affiliate_url is null and is_active;

create table if not exists marketing_brandconnect.category_registry (
  category_id text primary key,
  category_name text,
  category_source text not null,
  category_observed_at timestamptz not null,
  active boolean not null default true,
  first_observed_at timestamptz not null default now(),
  last_observed_at timestamptz not null default now(),
  last_selected_at timestamptz,
  constraint marketing_brandconnect_category_source check (category_source in ('user_verified_ui_devtools_network','brandconnect_live_endpoint_only_id'))
);

alter table marketing_brandconnect.category_registry
  add column if not exists category_observed_at timestamptz;
alter table marketing_brandconnect.category_registry
  alter column category_source drop default;
alter table marketing_brandconnect.category_registry
  drop constraint if exists marketing_brandconnect_category_source;
alter table marketing_brandconnect.category_registry
  add constraint marketing_brandconnect_category_source check (category_source in ('brandconnect_live','user_verified_ui_devtools_network','brandconnect_live_endpoint_only_id'));

create table if not exists marketing_brandconnect.category_sync_runs (
  run_id uuid primary key default gen_random_uuid(),
  observed_at timestamptz not null default now(),
  status text not null check (status in ('OBSERVED','REJECTED','COMPLETE')),
  categories_seen integer not null default 0,
  source_fingerprint text,
  rejection_reason text
);

alter table marketing_brandconnect.category_sync_runs
  add column if not exists source text not null default 'brandconnect_live';
alter table marketing_brandconnect.category_sync_runs
  add column if not exists registered_count integer not null default 0;
alter table marketing_brandconnect.category_sync_runs
  add column if not exists rejected_count integer not null default 0;

create table if not exists marketing_brandconnect.issuance_reservations (
  reservation_id uuid primary key default gen_random_uuid(),
  category_id text references marketing_brandconnect.category_registry(category_id),
  requested_count integer not null check (requested_count between 30 and 50),
  status text not null default 'RESERVED' check (status in ('RESERVED','APPLIED','RELEASED')),
  created_at timestamptz not null default now(),
  applied_at timestamptz,
  released_at timestamptz
);

alter table marketing_brandconnect.issuance_reservations
  add column if not exists sync_run_id uuid references marketing_brandconnect.category_sync_runs(run_id);
alter table marketing_brandconnect.issuance_reservations
  add column if not exists selected_at timestamptz not null default now();
alter table marketing_brandconnect.issuance_reservations
  add column if not exists last_selected_at timestamptz;

create table if not exists marketing_brandconnect.issuance_reservation_items (
  reservation_id uuid not null references marketing_brandconnect.issuance_reservations(reservation_id) on delete cascade,
  channel_product_no text not null references marketing_brandconnect.catalog_items(channel_product_no),
  status text not null default 'RESERVED' check (status in ('RESERVED','APPLIED','RELEASED')),
  applied_at timestamptz,
  released_at timestamptz,
  primary key (reservation_id, channel_product_no)
);
alter table marketing_brandconnect.issuance_reservation_items add column if not exists applied_at timestamptz;
alter table marketing_brandconnect.issuance_reservation_items add column if not exists released_at timestamptz;

create table if not exists marketing_brandconnect.issuance_ledger (
  ledger_id bigint generated always as identity primary key,
  channel_product_no text not null references marketing_brandconnect.catalog_items(channel_product_no),
  affiliate_url text not null check (affiliate_url ~ '^https://naver[.]me/[^/?#]+$'),
  source text not null default 'brandconnect_live',
  issued_at timestamptz not null default now(),
  unique (channel_product_no, affiliate_url)
);

create table if not exists marketing_brandconnect.affiliate_url_history (
  history_id bigint generated always as identity primary key,
  channel_product_no text not null,
  affiliate_url text not null check (affiliate_url ~ '^https://naver[.]me/[^/?#]+$'),
  source text not null,
  observed_at timestamptz not null default now(),
  source_fingerprint text,
  unique (channel_product_no, affiliate_url)
);

create table if not exists marketing_brandconnect.snapshot_runs (
  run_id uuid primary key default gen_random_uuid(),
  strategy text not null check (strategy in ('RECOLLECT','PRESERVE_MERGE')),
  status text not null check (status in ('DRY_RUN','STAGED','APPLIED','REJECTED')),
  row_count integer not null default 0,
  conflict_count integer not null default 0,
  source_fingerprint text,
  created_at timestamptz not null default now()
);

-- Staging is append-only and can be discarded before a reviewed cutover.
create table if not exists marketing_brandconnect.snapshot_staging (
  run_id uuid not null references marketing_brandconnect.snapshot_runs(run_id) on delete cascade,
  channel_product_no text not null,
  payload jsonb not null,
  primary key (run_id, channel_product_no)
);

create or replace function marketing_brandconnect.preserve_affiliate_urls(p_rows jsonb, p_dry_run boolean default true)
returns jsonb language plpgsql security definer set search_path = marketing_brandconnect, pg_catalog as $$
declare row_item jsonb; existing_url text; incoming_id text; incoming_url text; seen_ids text[] := ARRAY[]::text[]; preserved integer := 0; idempotent integer := 0; conflicts integer := 0;
begin
  if jsonb_typeof(p_rows) <> 'array' then raise exception 'preserve_rows_must_be_array'; end if;
  for row_item in select value from jsonb_array_elements(p_rows) loop
    incoming_id := nullif(trim(row_item->>'channel_product_no'), '');
    incoming_url := nullif(trim(row_item->>'affiliate_url'), '');
    if incoming_id is null or incoming_url is null or incoming_url !~ '^https://naver[.]me/[^/?#]+$' then raise exception 'preserve_row_invalid'; end if;
    if incoming_id = any(seen_ids) then raise exception 'preserve_duplicate_identity:%', incoming_id; end if;
    seen_ids := array_append(seen_ids, incoming_id);
    select affiliate_url into existing_url from catalog_items where channel_product_no = incoming_id;
    if existing_url is not null and existing_url <> incoming_url then conflicts := conflicts + 1;
    elsif existing_url = incoming_url then idempotent := idempotent + 1;
    else preserved := preserved + 1; end if;
    if not p_dry_run and existing_url is null then
      update catalog_items set affiliate_url = incoming_url, affiliate_source = coalesce(row_item->>'source','preserved'), affiliate_issued_at = coalesce((row_item->>'issued_at')::timestamptz, now()), updated_at = now() where channel_product_no = incoming_id;
      insert into affiliate_url_history(channel_product_no, affiliate_url, source, source_fingerprint) values (incoming_id, incoming_url, coalesce(row_item->>'source','preserved'), row_item->>'source_fingerprint') on conflict do nothing;
    end if;
  end loop;
  if conflicts > 0 then raise exception 'preserve_conflict:%', conflicts; end if;
  return jsonb_build_object('preserved', preserved, 'idempotent', idempotent, 'conflicts', conflicts, 'dry_run', p_dry_run);
end $$;

create or replace function marketing_brandconnect.recollect_merge(p_rows jsonb, p_dry_run boolean default true)
returns jsonb language plpgsql security definer set search_path = marketing_brandconnect, pg_catalog as $$
declare row_item jsonb; incoming_id text; existing_url text; merged integer := 0; preserved integer := 0; conflicts integer := 0;
begin
  if jsonb_typeof(p_rows) <> 'array' then raise exception 'recollect_rows_must_be_array'; end if;
  for row_item in select value from jsonb_array_elements(p_rows) loop
    incoming_id := nullif(trim(row_item->>'channel_product_no'), '');
    if incoming_id is null then raise exception 'recollect_row_identity_required'; end if;
    select affiliate_url into existing_url from catalog_items where channel_product_no = incoming_id;
    if existing_url is not null and nullif(trim(row_item->>'affiliate_url'),'') is not null and existing_url <> trim(row_item->>'affiliate_url') then conflicts := conflicts + 1;
    elsif existing_url is not null then preserved := preserved + 1;
    else merged := merged + 1; end if;
    if not p_dry_run and existing_url is not null then
      update catalog_items set title = coalesce(nullif(row_item->>'title',''), title), price_won = coalesce((row_item->>'price_won')::bigint, price_won), image_url = coalesce(nullif(row_item->>'image_url',''), image_url), updated_at = now() where channel_product_no = incoming_id;
    end if;
  end loop;
  if conflicts > 0 then raise exception 'recollect_affiliate_conflict:%', conflicts; end if;
  return jsonb_build_object('merged', merged, 'preserved', preserved, 'conflicts', conflicts, 'dry_run', p_dry_run, 'identity_key', 'channel_product_no');
end $$;

alter table marketing_brandconnect.catalog_items enable row level security;
alter table marketing_brandconnect.category_registry enable row level security;
alter table marketing_brandconnect.category_sync_runs enable row level security;
alter table marketing_brandconnect.issuance_reservations enable row level security;
alter table marketing_brandconnect.issuance_reservation_items enable row level security;
alter table marketing_brandconnect.issuance_ledger enable row level security;
alter table marketing_brandconnect.affiliate_url_history enable row level security;
alter table marketing_brandconnect.snapshot_runs enable row level security;
alter table marketing_brandconnect.snapshot_staging enable row level security;

revoke all on schema marketing_brandconnect from anon, authenticated;
grant usage on schema marketing_brandconnect to service_role;
grant all on all tables in schema marketing_brandconnect to service_role;
grant execute on all functions in schema marketing_brandconnect to service_role;

-- ============================================================================
-- Canonical Phase A category/issuance RPC contract.
-- These functions are intentionally prepared only.  The Edge functions use
-- dependency injection in Phase A and fail closed when no DB adapter is
-- supplied, so this migration does not enable a production writer by itself.

create or replace function marketing_brandconnect.sync_categories(p_manifest jsonb, p_complete boolean default false, p_source_fingerprint text default null, p_expected_category_count integer default null)
returns jsonb language plpgsql security definer set search_path = marketing_brandconnect, pg_catalog as $$
declare
  v_run uuid := gen_random_uuid();
  v_observed timestamptz;
  v_count integer := 0;
  v_source text := 'brandconnect_live';
  v_calculated_fingerprint text;
begin
  if p_complete is not true or p_source_fingerprint is null or p_source_fingerprint !~ '^[a-f0-9]{64}$' or p_expected_category_count is null then
    insert into category_sync_runs(run_id, status, source, categories_seen, rejection_reason, rejected_count, source_fingerprint)
      values (v_run, 'REJECTED', v_source, 0, 'category_manifest_incomplete', 1, nullif(lower(p_source_fingerprint), ''));
    return jsonb_build_object('run_id', v_run, 'status', 'REJECTED', 'reason', 'category_manifest_incomplete');
  end if;
  if jsonb_typeof(p_manifest) <> 'array' or jsonb_array_length(p_manifest) = 0 or p_expected_category_count <> jsonb_array_length(p_manifest) then
    insert into category_sync_runs(run_id, status, source, categories_seen, rejection_reason, rejected_count, source_fingerprint)
      values (v_run, 'REJECTED', v_source, 0, 'category_manifest_required', 1, nullif(lower(p_source_fingerprint), ''));
    return jsonb_build_object('run_id', v_run, 'status', 'REJECTED', 'reason', 'category_manifest_required');
  end if;
  -- Must match serializeCategoryManifest(): UTF-8 base64 fields in the
  -- category_id order, comma-separated fields and semicolon-separated rows.
  select encode(extensions.digest(convert_to((select string_agg(
      encode(convert_to(coalesce(btrim(x->>'category_id'), ''), 'UTF8'), 'base64') || ',' ||
      encode(convert_to(coalesce(nullif(btrim(x->>'category_name'), ''), ''), 'UTF8'), 'base64') || ',' ||
      encode(convert_to(coalesce(x->>'category_observed_at', ''), 'UTF8'), 'base64') || ',' ||
      encode(convert_to(coalesce(nullif(btrim(x->>'category_source'), ''), ''), 'UTF8'), 'base64'),
      ';' order by encode(convert_to(coalesce(btrim(x->>'category_id'), ''), 'UTF8'), 'base64') collate "C") from jsonb_array_elements(p_manifest) x), 'UTF8'), 'sha256'), 'hex')
    into v_calculated_fingerprint;
  if lower(p_source_fingerprint) <> v_calculated_fingerprint then
    insert into category_sync_runs(run_id, status, source, categories_seen, rejection_reason, rejected_count, source_fingerprint)
      values (v_run, 'REJECTED', v_source, jsonb_array_length(p_manifest), 'category_manifest_fingerprint_mismatch', jsonb_array_length(p_manifest), lower(p_source_fingerprint));
    return jsonb_build_object('run_id', v_run, 'status', 'REJECTED', 'reason', 'category_manifest_fingerprint_mismatch', 'calculated_fingerprint', v_calculated_fingerprint);
  end if;
  select min(x.category_observed_at) into v_observed
    from jsonb_to_recordset(p_manifest) x(category_id text, category_name text, category_observed_at timestamptz, category_source text);
  if v_observed is null or v_observed < now() - interval '6 hours' or v_observed > now() + interval '5 minutes' then
    insert into category_sync_runs(run_id, status, source, categories_seen, rejection_reason, rejected_count, source_fingerprint)
      values (v_run, 'REJECTED', v_source, jsonb_array_length(p_manifest), 'category_observation_stale_or_future', jsonb_array_length(p_manifest), lower(p_source_fingerprint));
    return jsonb_build_object('run_id', v_run, 'status', 'REJECTED', 'reason', 'category_observation_stale_or_future');
  end if;
  if exists (select 1 from jsonb_to_recordset(p_manifest) x(category_id text, category_name text, category_observed_at timestamptz, category_source text)
             where nullif(btrim(x.category_id), '') is null) then
    insert into category_sync_runs(run_id, status, source, categories_seen, rejection_reason, rejected_count, source_fingerprint)
      values (v_run, 'REJECTED', v_source, jsonb_array_length(p_manifest), 'category_id_required', jsonb_array_length(p_manifest), lower(p_source_fingerprint));
    return jsonb_build_object('run_id', v_run, 'status', 'REJECTED', 'reason', 'category_id_required');
  end if;
  if exists (select 1 from jsonb_to_recordset(p_manifest) x(category_id text, category_name text, category_observed_at timestamptz, category_source text)
             group by btrim(x.category_id) having count(*) > 1) then
    insert into category_sync_runs(run_id, status, source, categories_seen, rejection_reason, rejected_count, source_fingerprint)
      values (v_run, 'REJECTED', v_source, jsonb_array_length(p_manifest), 'category_duplicate', jsonb_array_length(p_manifest), lower(p_source_fingerprint));
    return jsonb_build_object('run_id', v_run, 'status', 'REJECTED', 'reason', 'category_duplicate');
  end if;
  if exists (select 1 from jsonb_to_recordset(p_manifest) x(category_id text, category_name text, category_observed_at timestamptz, category_source text)
             where x.category_observed_at is null or x.category_source not in ('user_verified_ui_devtools_network','brandconnect_live_endpoint_only_id')) then
    insert into category_sync_runs(run_id, status, source, categories_seen, rejection_reason, rejected_count, source_fingerprint)
      values (v_run, 'REJECTED', v_source, jsonb_array_length(p_manifest), 'category_source_or_observation_invalid', jsonb_array_length(p_manifest), lower(p_source_fingerprint));
    return jsonb_build_object('run_id', v_run, 'status', 'REJECTED', 'reason', 'category_source_or_observation_invalid');
  end if;
  insert into category_registry(category_id, category_name, category_source, category_observed_at, active, first_observed_at, last_observed_at)
    select btrim(x.category_id), nullif(btrim(x.category_name), ''), btrim(x.category_source), x.category_observed_at, true, v_observed, v_observed
      from jsonb_to_recordset(p_manifest) x(category_id text, category_name text, category_observed_at timestamptz, category_source text)
    on conflict (category_id) do update set
      category_name = coalesce(excluded.category_name, category_registry.category_name),
      category_source = excluded.category_source, category_observed_at = excluded.category_observed_at, active = true,
      last_observed_at = excluded.last_observed_at;
  get diagnostics v_count = row_count;
  update category_registry
     set active = false
   where active
     and category_id not in (
       select btrim(x.category_id)
         from jsonb_to_recordset(p_manifest) x(category_id text, category_name text, category_observed_at timestamptz, category_source text)
     );
  insert into category_sync_runs(run_id, status, source, categories_seen, registered_count, source_fingerprint)
    values (v_run, 'COMPLETE', v_source, jsonb_array_length(p_manifest), v_count, lower(p_source_fingerprint));
  return jsonb_build_object('run_id', v_run, 'status', 'COMPLETE', 'registered', v_count,
                            'active_category_count', (select count(*) from category_registry where active));
end $$;

-- Compatibility name used by the first Phase A client draft.
create or replace function marketing_brandconnect.register_categories(p_manifest jsonb, p_complete boolean default false, p_source_fingerprint text default null, p_expected_category_count integer default null)
returns jsonb language sql security definer set search_path = marketing_brandconnect, pg_catalog as $$
  select marketing_brandconnect.sync_categories(p_manifest, p_complete, p_source_fingerprint, p_expected_category_count)
$$;

create or replace function marketing_brandconnect.reserve_category(
  p_limit integer, p_sync_run_id uuid, p_category_id text default null
) returns jsonb language plpgsql security definer set search_path = marketing_brandconnect, pg_catalog as $$
declare
  v_limit integer := greatest(30, least(coalesce(p_limit, 30), 50));
  v_category text; v_name text; v_res uuid; v_ids jsonb; v_before integer; v_candidates integer;
begin
  if not exists (select 1 from category_sync_runs where run_id = p_sync_run_id and status = 'COMPLETE'
                 and observed_at >= now() - interval '6 hours') then
    raise exception 'category_sync_unavailable';
  end if;
  if p_category_id is null then
    select r.category_id, r.category_name into v_category, v_name
      from category_registry r where r.active and r.last_observed_at >= now() - interval '6 hours'
      order by (select count(*) from catalog_items c where c.category_key = r.category_id and c.affiliate_url is not null),
               coalesce(r.last_selected_at, 'epoch'::timestamptz), r.category_id limit 1;
  else
    select r.category_id, r.category_name into v_category, v_name from category_registry r
      where r.category_id = btrim(p_category_id) and r.active and r.last_observed_at >= now() - interval '6 hours';
  end if;
  if v_category is null then raise exception 'category_unknown_or_inactive'; end if;
  perform pg_advisory_xact_lock(hashtextextended(v_category, 0));
  select count(*) into v_before from catalog_items c where c.category_key = v_category and c.affiliate_url is not null;
  select count(*) into v_candidates from catalog_items c where c.is_active and c.category_key = v_category and c.affiliate_url is null
    and not exists (select 1 from issuance_reservation_items i join issuance_reservations r using (reservation_id)
                    where i.channel_product_no = c.channel_product_no and i.status = 'RESERVED' and r.status = 'RESERVED');
  insert into issuance_reservations(category_id, sync_run_id, requested_count, selected_at, last_selected_at)
    values (v_category, p_sync_run_id, v_limit, now(), now()) returning reservation_id into v_res;
  update category_registry set last_selected_at = now() where category_id = v_category;
  insert into issuance_reservation_items(reservation_id, channel_product_no)
    select v_res, c.channel_product_no from catalog_items c
      where c.is_active and c.category_key = v_category and c.affiliate_url is null
        and not exists (select 1 from issuance_reservation_items i join issuance_reservations r using (reservation_id)
                        where i.channel_product_no = c.channel_product_no and i.status = 'RESERVED' and r.status = 'RESERVED')
      order by c.observed_at, c.channel_product_no limit v_limit for update skip locked;
  select coalesce(jsonb_agg(channel_product_no order by channel_product_no), '[]'::jsonb) into v_ids
    from issuance_reservation_items where reservation_id = v_res;
  return jsonb_build_object('reservation_id', v_res, 'category_path', v_category, 'category_name', v_name,
    'ids', v_ids, 'count', jsonb_array_length(v_ids), 'total_candidates', v_candidates, 'category_link_count_before', v_before);
end $$;

create or replace function marketing_brandconnect.pending(p_limit integer, p_category_id text default null)
returns jsonb language sql security definer set search_path = marketing_brandconnect, pg_catalog as $$
  select coalesce(jsonb_agg(q.channel_product_no order by q.observed_at, q.channel_product_no), '[]'::jsonb)
    from (select c.channel_product_no, c.observed_at from catalog_items c
      where c.is_active and c.affiliate_url is null
        and (p_category_id is null or c.category_key = btrim(p_category_id))
        and not exists (select 1 from issuance_reservation_items i join issuance_reservations r using (reservation_id)
                        where i.channel_product_no = c.channel_product_no and i.status = 'RESERVED' and r.status = 'RESERVED')
      order by c.observed_at, c.channel_product_no
      limit greatest(1, least(coalesce(p_limit, 1), 200))) q
$$;

create or replace function marketing_brandconnect.apply_links(p_rows jsonb, p_reservation_id uuid default null)
returns jsonb language plpgsql security definer set search_path = marketing_brandconnect, pg_catalog as $$
declare x jsonb; v_id text; v_url text; v_existing text; v_updated integer := 0; v_skipped integer := 0; v_not_found integer := 0;
begin
  if jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) = 0 then raise exception 'apply_rows_required'; end if;
  for x in select value from jsonb_array_elements(p_rows) loop
    v_id := nullif(btrim(x->>'channel_product_no'), ''); v_url := nullif(btrim(x->>'affiliate_url'), '');
    if v_id is null or v_url is null or v_url !~ '^https://naver[.]me/[^/?#]+$' then raise exception 'apply_row_invalid'; end if;
    if p_reservation_id is not null and not exists (select 1 from issuance_reservations where reservation_id=p_reservation_id and status in ('RESERVED','APPLIED')) then raise exception 'reservation_unavailable'; end if;
    if p_reservation_id is not null and exists (select 1 from issuance_reservation_items where reservation_id=p_reservation_id and channel_product_no=v_id and status='APPLIED') then
      if exists (select 1 from catalog_items where channel_product_no=v_id and affiliate_url is distinct from v_url) then raise exception 'reservation_apply_conflict:%', v_id; end if;
      v_skipped := v_skipped + 1;
      continue;
    end if;
    if p_reservation_id is not null and not exists (select 1 from issuance_reservation_items where reservation_id=p_reservation_id and channel_product_no=v_id and status='RESERVED') then raise exception 'reservation_item_mismatch'; end if;
    select affiliate_url into v_existing from catalog_items where channel_product_no=v_id for update;
    if not found then v_not_found := v_not_found + 1;
    elsif v_existing is null then
      update catalog_items set affiliate_url=v_url, affiliate_source='brandconnect_live', affiliate_issued_at=now(), updated_at=now() where channel_product_no=v_id;
      insert into affiliate_url_history(channel_product_no, affiliate_url, source) values (v_id, v_url, 'brandconnect_live') on conflict do nothing;
      insert into issuance_ledger(channel_product_no, affiliate_url, source) values (v_id, v_url, 'brandconnect_live') on conflict do nothing;
      v_updated := v_updated + 1;
    elsif v_existing = v_url then v_skipped := v_skipped + 1;
    else raise exception 'affiliate_conflict:%', v_id;
    end if;
  end loop;
  if p_reservation_id is not null then
    update issuance_reservation_items i
       set status='APPLIED', applied_at=coalesce(applied_at, now())
     where i.reservation_id=p_reservation_id and i.status='RESERVED'
       and exists (
         select 1
           from jsonb_array_elements(p_rows) x
           join catalog_items c on c.channel_product_no = x->>'channel_product_no'
          where x->>'channel_product_no' = i.channel_product_no
            and c.affiliate_url = x->>'affiliate_url'
       );
    if not exists (select 1 from issuance_reservation_items where reservation_id=p_reservation_id and status='RESERVED') then
      update issuance_reservations set status='APPLIED', applied_at=now() where reservation_id=p_reservation_id and status='RESERVED';
    end if;
  end if;
  return jsonb_build_object('updated',v_updated,'skipped_existing',v_skipped,'not_found',v_not_found);
end $$;

create or replace function marketing_brandconnect.release_category(p_reservation_id uuid)
returns jsonb language sql security definer set search_path = marketing_brandconnect, pg_catalog as $$
  with items as (update issuance_reservation_items set status='RELEASED', released_at=coalesce(released_at, now()) where reservation_id=p_reservation_id and status='RESERVED' returning 1),
  reservation as (update issuance_reservations set status='RELEASED', released_at=now() where reservation_id=p_reservation_id and status='RESERVED' returning 1)
  select jsonb_build_object('reservation_id', p_reservation_id, 'released', (select count(*) from items), 'status', 'RELEASED')
$$;

create or replace function marketing_brandconnect.get_category_link_counts()
returns jsonb language sql security definer set search_path = marketing_brandconnect, pg_catalog as $$
  select coalesce(jsonb_object_agg(r.category_id, jsonb_build_object('category_name',r.category_name,'link_count',
    (select count(*) from catalog_items c where c.category_key=r.category_id and c.affiliate_url is not null))), '{}'::jsonb)
    || jsonb_build_object('legacy_uncategorized', jsonb_build_object('category_name',null,'link_count',
      (select count(*) from catalog_items c where c.category_key is null and c.affiliate_url is not null)))
    from category_registry r where r.active
$$;

-- Writer-safe import/merge: existing affiliate URLs are never overwritten.
create or replace function marketing_brandconnect.import_catalog(p_rows jsonb, p_strategy text default 'RECOLLECT', p_dry_run boolean default true)
returns jsonb language plpgsql security definer set search_path = marketing_brandconnect, pg_catalog as $$
declare x jsonb; v_id text; v_url text; v_existing text; v_rows integer := 0; v_conflicts integer := 0; v_updated integer := 0;
begin
  if jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows)=0 then raise exception 'import_rows_required'; end if;
  for x in select value from jsonb_array_elements(p_rows) loop
    v_id := nullif(btrim(x->>'channel_product_no'),''); v_url := nullif(btrim(x->>'affiliate_url'),'');
    if v_id is null or nullif(btrim(x->>'title'),'') is null then raise exception 'import_identity_or_title_required'; end if;
    if v_url is not null and v_url !~ '^https://naver[.]me/[^/?#]+$' then raise exception 'import_affiliate_url_invalid'; end if;
    select affiliate_url into v_existing from catalog_items where channel_product_no=v_id;
    if v_existing is not null and v_url is not null and v_existing <> v_url then v_conflicts := v_conflicts + 1; end if;
    v_rows := v_rows + 1;
    if not p_dry_run and v_existing is null then
      insert into catalog_items(channel_product_no,title,price_won,store_name,brand,image_url,category_id,category_key,category_name,category_source,category_observed_at,is_active,observed_at,affiliate_url,affiliate_source,affiliate_issued_at,source_fingerprint)
      values(v_id,btrim(x->>'title'),nullif(x->>'price_won','')::bigint,x->>'store_name',x->>'brand',x->>'image_url',x->>'category_id',coalesce(x->>'category_key',x->>'category_id'),x->>'category_name',nullif(x->>'category_source',''),nullif(x->>'category_observed_at','')::timestamptz,coalesce((x->>'is_active')::boolean,true),coalesce((x->>'observed_at')::timestamptz,now()),v_url,case when v_url is null then null else 'preserved' end,case when v_url is null then null else now() end,x->>'source_fingerprint')
      on conflict(channel_product_no) do update set title=excluded.title, price_won=coalesce(excluded.price_won,catalog_items.price_won), store_name=coalesce(excluded.store_name,catalog_items.store_name), brand=coalesce(excluded.brand,catalog_items.brand), image_url=coalesce(excluded.image_url,catalog_items.image_url), category_id=coalesce(excluded.category_id,catalog_items.category_id), category_key=coalesce(excluded.category_key,catalog_items.category_key), category_name=coalesce(excluded.category_name,catalog_items.category_name), category_source=coalesce(excluded.category_source,catalog_items.category_source), is_active=excluded.is_active, observed_at=excluded.observed_at, updated_at=now();
      v_updated := v_updated + 1;
    elsif not p_dry_run then
      -- Refresh metadata for previously issued rows while leaving their
      -- affiliate URL and provenance untouched.
      update catalog_items set
        title = btrim(x->>'title'),
        price_won = coalesce(nullif(x->>'price_won','')::bigint, price_won),
        store_name = coalesce(x->>'store_name', store_name),
        brand = coalesce(x->>'brand', brand),
        image_url = coalesce(x->>'image_url', image_url),
        category_id = coalesce(x->>'category_id', category_id),
        category_key = coalesce(x->>'category_key', x->>'category_id', category_key),
        category_name = coalesce(x->>'category_name', category_name),
        category_source = coalesce(x->>'category_source', category_source),
        category_observed_at = coalesce(nullif(x->>'category_observed_at','')::timestamptz, category_observed_at),
        is_active = coalesce((x->>'is_active')::boolean, is_active),
        observed_at = coalesce((x->>'observed_at')::timestamptz, observed_at),
        updated_at = now()
        where channel_product_no = v_id;
      v_updated := v_updated + 1;
    end if;
  end loop;
  if v_conflicts > 0 then raise exception 'import_affiliate_conflict:%', v_conflicts; end if;
  return jsonb_build_object('rows',v_rows,'updated',v_updated,'conflicts',v_conflicts,'dry_run',p_dry_run,'strategy',p_strategy,'identity_key','channel_product_no','overwrite_affiliate_url',false);
end $$;

-- Stable aliases consumed by the Edge adapter contract.
create or replace function marketing_brandconnect.pending_category(p_limit integer, p_category_id text default null)
returns jsonb language sql security definer set search_path=marketing_brandconnect, pg_catalog as $$ select marketing_brandconnect.pending(p_limit, p_category_id) $$;
create or replace function marketing_brandconnect.apply_brandconnect_affiliate_urls(p_rows jsonb, p_reservation_id uuid default null)
returns jsonb language sql security definer set search_path=marketing_brandconnect, pg_catalog as $$ select marketing_brandconnect.apply_links(p_rows, p_reservation_id) $$;
create or replace function marketing_brandconnect.release_brandconnect_category_reservation(p_reservation_id uuid)
returns jsonb language sql security definer set search_path=marketing_brandconnect, pg_catalog as $$ select marketing_brandconnect.release_category(p_reservation_id) $$;
create or replace function marketing_brandconnect.get_brandconnect_category_link_counts()
returns jsonb language sql security definer set search_path=marketing_brandconnect, pg_catalog as $$ select marketing_brandconnect.get_category_link_counts() $$;
create or replace function marketing_brandconnect.preserve_catalog(p_rows jsonb, p_dry_run boolean default true)
returns jsonb language sql security definer set search_path=marketing_brandconnect, pg_catalog as $$ select marketing_brandconnect.import_catalog(p_rows, 'PRESERVE_MERGE', p_dry_run) $$;
create or replace function marketing_brandconnect.recollect_merge_catalog(p_rows jsonb, p_dry_run boolean default true)
returns jsonb language sql security definer set search_path=marketing_brandconnect, pg_catalog as $$ select marketing_brandconnect.import_catalog(p_rows, 'RECOLLECT', p_dry_run) $$;

do $$
declare f record;
begin
  for f in select * from (values
    ('sync_categories(jsonb,boolean,text,integer)'), ('register_categories(jsonb,boolean,text,integer)'),
    ('reserve_category(integer,uuid,text)'), ('pending(integer,text)'), ('pending_category(integer,text)'),
    ('apply_links(jsonb,uuid)'), ('apply_brandconnect_affiliate_urls(jsonb,uuid)'),
    ('release_category(uuid)'), ('release_brandconnect_category_reservation(uuid)'),
    ('get_category_link_counts()'), ('get_brandconnect_category_link_counts()'),
    ('import_catalog(jsonb,text,boolean)'), ('preserve_catalog(jsonb,boolean)'), ('recollect_merge_catalog(jsonb,boolean)')
  ) as x(signature) loop
    execute format('revoke all on function marketing_brandconnect.%s from public, anon, authenticated', f.signature);
    execute format('grant execute on function marketing_brandconnect.%s to service_role', f.signature);
  end loop;
end $$;

-- Never leave these migration/copy writers callable by client roles.  The
-- Phase A package is dry-run by default and future apply requires service_role.
revoke all on function marketing_brandconnect.preserve_affiliate_urls(jsonb, boolean) from public, anon, authenticated;
revoke all on function marketing_brandconnect.recollect_merge(jsonb, boolean) from public, anon, authenticated;
revoke all on function marketing_brandconnect.import_catalog(jsonb, text, boolean) from public, anon, authenticated;
revoke all on function marketing_brandconnect.preserve_catalog(jsonb, boolean) from public, anon, authenticated;
revoke all on function marketing_brandconnect.recollect_merge_catalog(jsonb, boolean) from public, anon, authenticated;
grant execute on function marketing_brandconnect.preserve_affiliate_urls(jsonb, boolean) to service_role;
grant execute on function marketing_brandconnect.recollect_merge(jsonb, boolean) to service_role;
grant execute on function marketing_brandconnect.import_catalog(jsonb, text, boolean) to service_role;
grant execute on function marketing_brandconnect.preserve_catalog(jsonb, boolean) to service_role;
grant execute on function marketing_brandconnect.recollect_merge_catalog(jsonb, boolean) to service_role;

;
