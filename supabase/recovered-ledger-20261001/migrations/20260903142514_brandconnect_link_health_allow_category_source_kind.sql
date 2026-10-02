create or replace function marketing_brandconnect.revalidate_link_health(
  p_rows jsonb,
  p_dry_run boolean default true,
  p_max_delist_ratio numeric default 0.30
)
returns jsonb
language plpgsql
security definer
set search_path to 'marketing_brandconnect', 'pg_catalog'
as $$
declare
  v_allowed text[] := array[
    'channel_product_no',
    'source_kind',
    'source_snapshot_hash',
    'source_row_hash',
    'source_observed_at',
    'source_contract_version',
    'provenance_epoch',
    'source_active',
    'source_status',
    'current_provenance_fingerprint'
  ];
  v_forbidden text[] := array[
    'title',
    'is_active',
    'active',
    'status',
    'category_id',
    'category_name',
    'category_status',
    'affiliate_url',
    'affiliate_source',
    'affiliate_issued_at',
    'price_won',
    'image_url',
    'provider'
  ];
  v_allowed_source_kinds text[] := array[
    'brandconnect_official_store_search_xhr',
    'brandconnect_official_display_category_authenticated_get'
  ];

  v_row jsonb;
  v_ids text[] := array[]::text[];
  v_id text;
  v_kind text;
  v_snapshot text;
  v_row_hash text;
  v_contract text;
  v_epoch text;
  v_status text;
  v_active boolean;
  v_observed timestamptz;
  v_fingerprint text;
  v_expected_fingerprint text;

  v_candidate_count integer := 0;
  v_batch_delisted integer := 0;
  v_updated_count integer := 0;
  v_not_found_count integer := 0;
  v_skipped_stale_count integer := 0;
  v_delisted_count integer := 0;
  v_relisted_count integer := 0;

  v_prev_active boolean;
  v_prev_status text;
  v_prev_epoch text;
  v_prev_fingerprint text;
  v_prev_observed timestamptz;
  v_found boolean;
begin
  if p_dry_run is null then
    raise exception 'link_health_dry_run_required';
  end if;
  if p_max_delist_ratio is null or p_max_delist_ratio < 0 or p_max_delist_ratio > 1 then
    raise exception 'link_health_delist_ratio_invalid';
  end if;

  if p_rows is null or jsonb_typeof(p_rows) <> 'array' then
    raise exception 'link_health_rows_array_required';
  end if;

  v_candidate_count := jsonb_array_length(p_rows);
  if v_candidate_count > 500 then
    raise exception 'link_health_batch_too_large';
  end if;

  for v_row in select value from jsonb_array_elements(p_rows) as t(value) loop
    if jsonb_typeof(v_row) <> 'object' then
      raise exception 'link_health_row_object_required';
    end if;

    if exists (
      select 1 from jsonb_object_keys(v_row) as k(key) where k.key = any (v_forbidden)
    ) then
      raise exception 'link_health_mutable_field_forbidden';
    end if;

    if exists (
      select 1 from jsonb_object_keys(v_row) as k(key) where not (k.key = any (v_allowed))
    ) then
      raise exception 'link_health_unknown_field';
    end if;

    v_id := nullif(btrim(coalesce(v_row->>'channel_product_no', '')), '');
    if v_id is null or v_id = any (v_ids) then
      raise exception 'link_health_identity_invalid';
    end if;
    v_ids := array_append(v_ids, v_id);

    v_kind := v_row->>'source_kind';
    v_contract := v_row->>'source_contract_version';
    v_epoch := v_row->>'provenance_epoch';
    if v_contract is distinct from 'brandconnect_link_health_revalidation_v1'
       or v_epoch is distinct from 'LINK_HEALTH_V1'
       or coalesce(v_kind, '') <> all (v_allowed_source_kinds) then
      raise exception 'link_health_contract_mismatch';
    end if;

    v_snapshot := lower(btrim(coalesce(v_row->>'source_snapshot_hash', '')));
    v_row_hash := lower(btrim(coalesce(v_row->>'source_row_hash', '')));
    if v_snapshot !~ '^[a-f0-9]{64}$' or v_row_hash !~ '^[a-f0-9]{64}$' then
      raise exception 'link_health_hash_invalid';
    end if;

    begin
      v_observed := (v_row->>'source_observed_at')::timestamptz;
    exception when others then
      raise exception 'link_health_observation_invalid';
    end;
    if v_observed is null then
      raise exception 'link_health_observation_invalid';
    end if;
    if v_observed > now() + interval '5 minutes'
       or v_observed < now() - interval '7 days' then
      raise exception 'link_health_observation_stale';
    end if;

    v_status := v_row->>'source_status';
    if v_status is null or v_status not in ('LISTED', 'DELISTED') then
      raise exception 'link_health_status_invalid';
    end if;

    if jsonb_typeof(v_row->'source_active') <> 'boolean' then
      raise exception 'link_health_active_invalid';
    end if;
    v_active := (v_row->>'source_active')::boolean;

    v_fingerprint := lower(btrim(coalesce(v_row->>'current_provenance_fingerprint', '')));
    v_expected_fingerprint := lower(
      marketing_brandconnect.compute_current_provenance_fingerprint(
        v_kind,
        v_snapshot,
        v_row_hash,
        v_observed,
        v_contract,
        v_epoch,
        v_id,
        v_active,
        v_status
      )
    );
    if v_fingerprint !~ '^[a-f0-9]{64}$'
       or v_expected_fingerprint is null
       or v_fingerprint is distinct from v_expected_fingerprint then
      raise exception 'link_health_fingerprint_mismatch';
    end if;

    if v_status = 'DELISTED' then
      v_batch_delisted := v_batch_delisted + 1;
    end if;
  end loop;

  if v_candidate_count > 0
     and (v_batch_delisted::numeric / v_candidate_count::numeric) > p_max_delist_ratio then
    raise exception 'link_health_mass_delist_guard';
  end if;

  for v_row in select value from jsonb_array_elements(p_rows) as t(value) loop
    v_id := btrim(v_row->>'channel_product_no');
    v_kind := v_row->>'source_kind';
    v_contract := v_row->>'source_contract_version';
    v_epoch := v_row->>'provenance_epoch';
    v_snapshot := lower(btrim(v_row->>'source_snapshot_hash'));
    v_row_hash := lower(btrim(v_row->>'source_row_hash'));
    v_observed := (v_row->>'source_observed_at')::timestamptz;
    v_status := v_row->>'source_status';
    v_active := (v_row->>'source_active')::boolean;
    v_fingerprint := lower(btrim(v_row->>'current_provenance_fingerprint'));

    v_found := false;
    if p_dry_run then
      select true,
             c.source_active,
             c.source_status,
             c.provenance_epoch,
             c.current_provenance_fingerprint,
             c.source_observed_at
        into v_found, v_prev_active, v_prev_status, v_prev_epoch,
             v_prev_fingerprint, v_prev_observed
        from marketing_brandconnect.catalog_items c
       where c.channel_product_no = v_id;
    else
      select true,
             c.source_active,
             c.source_status,
             c.provenance_epoch,
             c.current_provenance_fingerprint,
             c.source_observed_at
        into v_found, v_prev_active, v_prev_status, v_prev_epoch,
             v_prev_fingerprint, v_prev_observed
        from marketing_brandconnect.catalog_items c
       where c.channel_product_no = v_id
         for update;
    end if;

    if not coalesce(v_found, false) then
      v_not_found_count := v_not_found_count + 1;
      continue;
    end if;

    if v_prev_observed is not null and v_prev_observed > v_observed then
      v_skipped_stale_count := v_skipped_stale_count + 1;
      continue;
    end if;

    v_updated_count := v_updated_count + 1;
    if v_status = 'DELISTED' and v_prev_status is distinct from 'DELISTED' then
      v_delisted_count := v_delisted_count + 1;
    elsif v_status = 'LISTED' and v_prev_status = 'DELISTED' then
      v_relisted_count := v_relisted_count + 1;
    end if;

    if not p_dry_run then
      insert into marketing_brandconnect.catalog_link_health_events (
        channel_product_no,
        observed_at,
        prev_source_active,
        prev_source_status,
        prev_provenance_epoch,
        prev_current_provenance_fingerprint,
        new_source_active,
        new_source_status,
        snapshot_hash
      ) values (
        v_id,
        v_observed,
        v_prev_active,
        v_prev_status,
        v_prev_epoch,
        v_prev_fingerprint,
        v_active,
        v_status,
        v_snapshot
      );

      update marketing_brandconnect.catalog_items
         set source_kind = v_kind,
             source_snapshot_hash = v_snapshot,
             source_row_hash = v_row_hash,
             source_observed_at = v_observed,
             source_contract_version = v_contract,
             provenance_epoch = v_epoch,
             source_active = v_active,
             source_status = v_status,
             current_provenance_fingerprint = v_fingerprint
       where channel_product_no = v_id;
    end if;
  end loop;

  return jsonb_build_object(
    'status', case when p_dry_run then 'DRY_RUN' else 'APPLIED' end,
    'candidate_count', v_candidate_count,
    'updated_count', v_updated_count,
    'not_found_count', v_not_found_count,
    'skipped_stale_count', v_skipped_stale_count,
    'delisted_count', v_delisted_count,
    'relisted_count', v_relisted_count
  );
end;
$$;

revoke all on function marketing_brandconnect.revalidate_link_health(jsonb, boolean, numeric)
  from public, anon, authenticated;
grant execute on function marketing_brandconnect.revalidate_link_health(jsonb, boolean, numeric)
  to service_role;
;
