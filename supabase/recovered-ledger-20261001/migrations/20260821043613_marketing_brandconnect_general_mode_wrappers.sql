-- Additive mode-specific apply wrappers.  They preserve the existing
-- apply_links implementation while preventing a reservation from crossing
-- GENERAL/BALANCED lanes.  This file is local/shadow-only until reviewed.
alter table marketing_brandconnect.category_registry drop constraint if exists marketing_brandconnect_category_source;
alter table marketing_brandconnect.category_registry add constraint marketing_brandconnect_category_source check (category_source in ('brandconnect_live','smartstore_browser_xhr','official-api','user_verified_ui_devtools_network','brandconnect_live_endpoint_only_id'));
create or replace function marketing_brandconnect.register_category_registry_v2(p_manifest jsonb, p_complete boolean, p_source_fingerprint text, p_expected_category_count integer)
returns jsonb language plpgsql security definer set search_path=marketing_brandconnect, pg_catalog as $$
declare v_run uuid := gen_random_uuid(); v_count integer; v_calculated_fingerprint text;
begin
  if p_complete is not true or jsonb_typeof(p_manifest) <> 'array' or jsonb_array_length(p_manifest) <> p_expected_category_count or p_expected_category_count <> 11 or p_source_fingerprint !~ '^[a-f0-9]{64}$' then raise exception 'category_registry_v2_manifest_invalid'; end if;
  select encode(extensions.digest(convert_to((select string_agg(
      encode(convert_to(coalesce(btrim(x->>'category_id'), ''), 'UTF8'), 'base64') || ',' ||
      encode(convert_to(coalesce(nullif(btrim(x->>'category_name'), ''), ''), 'UTF8'), 'base64') || ',' ||
      encode(convert_to(coalesce(x->>'observed_at', ''), 'UTF8'), 'base64') || ',' ||
      encode(convert_to(coalesce(nullif(btrim(x->>'category_source'), ''), ''), 'UTF8'), 'base64'),
      ';' order by encode(convert_to(coalesce(btrim(x->>'category_id'), ''), 'UTF8'), 'base64') collate "C")
      from jsonb_array_elements(p_manifest) x), 'UTF8'), 'sha256'), 'hex') into v_calculated_fingerprint;
  if lower(p_source_fingerprint) <> v_calculated_fingerprint then raise exception 'category_registry_v2_fingerprint_mismatch'; end if;
  if exists (select 1 from jsonb_to_recordset(p_manifest) x(category_id text, category_name text, category_source text, observed_at timestamptz) where category_id is null or category_name is null or category_source not in ('smartstore_browser_xhr','user_verified_ui_devtools_network','official-api','brandconnect_live') or observed_at is null) then raise exception 'category_registry_v2_evidence_invalid'; end if;
  if exists (select 1 from jsonb_to_recordset(p_manifest) x(category_id text) group by category_id having count(*) > 1) or exists (select 1 from jsonb_to_recordset(p_manifest) x(category_name text) group by category_name having count(*) > 1) then raise exception 'category_registry_v2_duplicate'; end if;
  if exists (select 1 from jsonb_to_recordset(p_manifest) x(category_id text) where x.category_id not in ('50000000','50000001','50000002','50000003','50000004','50000005','50000006','50000007','50000008','50000009','50005542')) then raise exception 'category_registry_v2_unknown_id'; end if;
  if exists (select 1 from jsonb_to_recordset(p_manifest) x(category_id text, category_name text) join (values ('50000000','패션의류'),('50000001','패션잡화'),('50000002','화장품/미용'),('50000003','디지털/가전'),('50000004','가구/인테리어'),('50000005','출산/육아'),('50000006','식품'),('50000007','스포츠/레저'),('50000008','생활/건강'),('50000009','여가/생활편의'),('50005542','도서')) e(category_id,category_name) using(category_id) where x.category_name <> e.category_name) then raise exception 'category_registry_v2_pair_mismatch'; end if;
  insert into category_registry(category_id,category_name,category_source,category_observed_at,active,first_observed_at,last_observed_at)
    select btrim(x.category_id),btrim(x.category_name),btrim(x.category_source),x.observed_at,true,now(),now() from jsonb_to_recordset(p_manifest) x(category_id text,category_name text,category_source text,observed_at timestamptz)
    on conflict(category_id) do update set category_name=excluded.category_name,category_source=excluded.category_source,category_observed_at=excluded.category_observed_at,active=true,last_observed_at=now();
  get diagnostics v_count=row_count;
  update category_registry set active=false where active and category_id not in(select category_id from jsonb_to_recordset(p_manifest) x(category_id text));
  return jsonb_build_object('run_id',v_run,'status','REGISTERED','registered',v_count);
end $$;
revoke all on function marketing_brandconnect.register_category_registry_v2(jsonb,boolean,text,integer) from public,anon,authenticated;
grant execute on function marketing_brandconnect.register_category_registry_v2(jsonb,boolean,text,integer) to service_role;
-- Legacy public write entrypoints are no longer callable directly. The
-- security-definer mode wrappers above may still invoke the internal function.
revoke all on function marketing_brandconnect.apply_links(jsonb, uuid) from public, anon, authenticated, service_role;
revoke all on function marketing_brandconnect.apply_brandconnect_affiliate_urls(jsonb, uuid) from public, anon, authenticated, service_role;
create or replace function marketing_brandconnect.apply_general_links(p_rows jsonb, p_reservation_id uuid)
returns jsonb
language plpgsql security definer
set search_path = marketing_brandconnect, pg_catalog
as $$
declare v_mode text;
begin
  if p_reservation_id is null then raise exception 'general_reservation_required'; end if;
  if exists (select 1 from jsonb_array_elements(coalesce(p_rows, '[]'::jsonb)) item where item ?| array['category_id','category_name','category_status']) then
    raise exception 'general_payload_category_forbidden';
  end if;
  select issuance_mode into v_mode from issuance_reservations where reservation_id = p_reservation_id;
  if v_mode is distinct from 'GENERAL' then raise exception 'general_reservation_mismatch'; end if;
  return apply_links(p_rows, p_reservation_id);
end
$$;
create or replace function marketing_brandconnect.apply_balanced_links(p_rows jsonb, p_reservation_id uuid)
returns jsonb
language plpgsql security definer
set search_path = marketing_brandconnect, pg_catalog
as $$
declare v_mode text;
begin
  if p_reservation_id is null then raise exception 'balanced_reservation_required'; end if;
  select issuance_mode into v_mode from issuance_reservations where reservation_id = p_reservation_id;
  if v_mode is distinct from 'BALANCED' then raise exception 'balanced_reservation_mismatch'; end if;
  return apply_links(p_rows, p_reservation_id);
end
$$;
do $$
begin
  revoke all on function marketing_brandconnect.apply_general_links(jsonb, uuid) from public, anon, authenticated;
  revoke all on function marketing_brandconnect.apply_balanced_links(jsonb, uuid) from public, anon, authenticated;
  grant execute on function marketing_brandconnect.apply_general_links(jsonb, uuid) to service_role;
  grant execute on function marketing_brandconnect.apply_balanced_links(jsonb, uuid) to service_role;
end
$$;
-- Read-only by default category evidence reconciliation.  Apply mode can only
-- promote an existing UNRESOLVED row and never receives affiliate_url.
create or replace function marketing_brandconnect.reconcile_category_evidence(p_rows jsonb, p_dry_run boolean default true)
returns jsonb
language plpgsql security definer
set search_path = marketing_brandconnect, pg_catalog
as $$
declare x jsonb; v_id text; v_category_id text; v_category_name text; v_count integer := 0; v_missing integer := 0; v_status text; v_existing_category_id text; v_existing_category_name text; v_existing_fp text; v_existing_source_fp text; v_expected_evidence text;
begin
  if jsonb_typeof(coalesce(p_rows, '[]'::jsonb)) <> 'array' then raise exception 'category_evidence_rows_array_required'; end if;
  for x in select value from jsonb_array_elements(p_rows) loop
    v_id := nullif(btrim(x->>'channel_product_no'), '');
    v_category_id := nullif(btrim(x->>'category_id'), '');
    v_category_name := nullif(btrim(x->>'category_name'), '');
    if x ? 'affiliate_url' then raise exception 'category_evidence_affiliate_url_forbidden:%', coalesce(v_id, '<missing>'); end if;
    if v_id is null or v_category_id is null or v_category_name is null
       or x->>'category_source' not in ('official-api','smartstore_browser_xhr','brandconnect_live')
       or not ((x->>'category_endpoint') like 'https://gw-brandconnect.naver.com/%'
               or x->>'category_endpoint' = 'https://brand.naver.com/n/v2/channels/{channel}/products/{productId}?withWindow=false')
       or x->>'category_evidence_fingerprint' !~ '^[a-f0-9]{64}$'
       or x->>'catalog_source_fingerprint' !~ '^[a-f0-9]{64}$'
       or x->>'category_observed_at' !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?Z$' then
      raise exception 'category_evidence_invalid:%', coalesce(v_id, '<missing>');
    end if;
    v_expected_evidence := encode(extensions.digest(convert_to(v_category_id||'|'||v_category_name||'|'||(x->>'category_source')||'|'||case when x->>'category_endpoint' like 'https://gw-brandconnect.naver.com/%' then 'brandconnect_gateway' else 'smartstore_v2' end||'|'||btrim(x->>'category_observed_at'),'UTF8'),'sha256'),'hex');
    if lower(x->>'category_evidence_fingerprint') <> v_expected_evidence then raise exception 'category_evidence_fingerprint_mismatch:%', v_id; end if;
    select c.category_status,c.category_id,c.category_name,c.category_evidence_fingerprint,c.catalog_source_fingerprint
      into v_status,v_existing_category_id,v_existing_category_name,v_existing_fp,v_existing_source_fp
      from catalog_items c where c.channel_product_no=v_id;
    if v_status is null then
      v_missing := v_missing + 1; continue;
    end if;
    if v_existing_source_fp is distinct from x->>'catalog_source_fingerprint' then raise exception 'catalog_source_fingerprint_mismatch:%', v_id; end if;
    if v_status = 'CONFIRMED' then
      if v_existing_category_id is distinct from v_category_id or v_existing_category_name is distinct from v_category_name or v_existing_fp is distinct from x->>'category_evidence_fingerprint' then raise exception 'category_evidence_conflict:%', v_id; end if;
      v_missing := v_missing + 1; continue;
    end if;
    if v_status is distinct from 'UNRESOLVED' then raise exception 'category_status_not_upgradeable:%', v_id; end if;
    if not exists (select 1 from category_registry r where r.category_id=v_category_id and r.category_name=v_category_name and r.active) then
      raise exception 'category_registry_mismatch:%', v_category_id;
    end if;
    if not p_dry_run then
      update catalog_items set category_id=v_category_id, category_key=v_category_id, category_name=v_category_name,
        category_source=x->>'category_source', category_observed_at=nullif(x->>'category_observed_at','')::timestamptz,
        category_status='CONFIRMED', category_status_reason=null, category_evidence_fingerprint=x->>'category_evidence_fingerprint', updated_at=now()
       where channel_product_no=v_id and category_status='UNRESOLVED';
    end if;
    v_count := v_count + 1;
  end loop;
  return jsonb_build_object('status',case when p_dry_run then 'DRY_RUN' else 'APPLIED' end,'eligible',v_count,'missing',v_missing,'affiliate_url_mutations',0);
end
$$;
do $$
begin
  revoke all on function marketing_brandconnect.reconcile_category_evidence(jsonb, boolean) from public, anon, authenticated;
  grant execute on function marketing_brandconnect.reconcile_category_evidence(jsonb, boolean) to service_role;
end
$$;
