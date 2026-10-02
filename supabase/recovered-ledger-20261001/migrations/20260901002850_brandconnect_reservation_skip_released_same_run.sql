-- Do not re-reserve products already released in the same issuance run.
-- Sale-stop candidates otherwise become immediately eligible again and can
-- consume the whole run without making progress. A new registered run may
-- retry them later; this is not a permanent catalog exclusion.
create or replace function marketing_brandconnect.reserve_category(
  p_limit integer,
  p_sync_run_id uuid,
  p_category_id text default null
) returns jsonb
language plpgsql
security definer
set search_path = marketing_brandconnect, pg_catalog
as $$
declare
  v_limit integer := greatest(1, least(coalesce(p_limit, 30), 50));
  v_category text;
  v_name text;
  v_res uuid;
  v_ids jsonb;
  v_before integer;
  v_candidates integer;
begin
  if not exists (
    select 1 from category_sync_runs
     where run_id = p_sync_run_id
       and status = 'COMPLETE'
       and observed_at >= now() - interval '6 hours'
  ) then
    raise exception 'category_sync_unavailable';
  end if;

  if p_category_id is null then
    select r.category_id, r.category_name into v_category, v_name
      from category_registry r
     where r.active
       and r.last_observed_at >= now() - interval '6 hours'
       and exists (
         select 1 from catalog_items c
          where c.is_active
            and c.category_status = 'CONFIRMED'
            and c.category_evidence_fingerprint ~ '^[a-f0-9]{64}$'
            and c.category_key = r.category_id
            and c.affiliate_url is null
            and (
              (c.catalog_source_fingerprint ~ '^[a-f0-9]{64}$'
               and c.source_contract_version = 'brandconnect_current_provenance_epoch_v2'
               and c.provenance_epoch = 'CURRENT_OFFICIAL_V1'
               and c.source_active = true
               and c.source_status not in ('INACTIVE', 'DISABLED', 'DELETED')
               and c.current_provenance_fingerprint = compute_current_provenance_fingerprint(c.source_kind, c.source_snapshot_hash, c.source_row_hash, c.source_observed_at, c.source_contract_version, c.provenance_epoch, c.channel_product_no, c.source_active, c.source_status))
              or
              (c.source_kind = 'brandconnect_official_display_category_authenticated_get'
               and c.catalog_source_fingerprint is null
               and c.current_provenance_fingerprint is null
               and c.source_contract_version is null
               and c.provenance_epoch is null
               and c.source_snapshot_hash ~ '^[a-f0-9]{64}$'
               and c.source_row_hash ~ '^[a-f0-9]{64}$'
               and c.source_active = true
               and c.source_status = 'SALE')
            )
            and not exists (
              select 1 from issuance_reservation_items i join issuance_reservations ir using (reservation_id)
               where i.channel_product_no = c.channel_product_no
                 and i.status = 'RESERVED' and ir.status = 'RESERVED')
            and not exists (
              select 1 from issuance_reservation_items i join issuance_reservations ir using (reservation_id)
               where i.channel_product_no = c.channel_product_no
                 and i.status = 'RELEASED' and ir.sync_run_id = p_sync_run_id)
       )
     order by
       (select count(*) from catalog_items c
         where c.category_status = 'CONFIRMED'
           and c.category_evidence_fingerprint ~ '^[a-f0-9]{64}$'
           and c.category_key = r.category_id
           and c.affiliate_url is not null
           and (
             (c.catalog_source_fingerprint ~ '^[a-f0-9]{64}$'
              and c.source_contract_version = 'brandconnect_current_provenance_epoch_v2'
              and c.provenance_epoch = 'CURRENT_OFFICIAL_V1'
              and c.source_active = true
              and c.source_status not in ('INACTIVE', 'DISABLED', 'DELETED')
              and c.current_provenance_fingerprint = compute_current_provenance_fingerprint(c.source_kind, c.source_snapshot_hash, c.source_row_hash, c.source_observed_at, c.source_contract_version, c.provenance_epoch, c.channel_product_no, c.source_active, c.source_status))
             or
             (c.source_kind = 'brandconnect_official_display_category_authenticated_get'
              and c.catalog_source_fingerprint is null
              and c.current_provenance_fingerprint is null
              and c.source_contract_version is null
              and c.provenance_epoch is null
              and c.source_snapshot_hash ~ '^[a-f0-9]{64}$'
              and c.source_row_hash ~ '^[a-f0-9]{64}$'
              and c.source_active = true
              and c.source_status = 'SALE')
           )) desc,
       coalesce(r.last_selected_at, 'epoch'::timestamptz), r.category_id
     limit 1;
    if v_category is null then
      return jsonb_build_object('reservation_id', null, 'category_path', null, 'category_name', null, 'ids', '[]'::jsonb, 'count', 0, 'total_candidates', 0, 'category_link_count_before', 0);
    end if;
  else
    select r.category_id, r.category_name into v_category, v_name
      from category_registry r
     where r.category_id = btrim(p_category_id)
       and r.active and r.last_observed_at >= now() - interval '6 hours';
    if v_category is null then raise exception 'category_unknown_or_inactive'; end if;
  end if;

  perform pg_advisory_xact_lock(hashtextextended(v_category, 0));

  select count(*) into v_before from catalog_items c
   where c.category_status = 'CONFIRMED'
     and c.category_evidence_fingerprint ~ '^[a-f0-9]{64}$'
     and c.category_key = v_category and c.affiliate_url is not null
     and (
       (c.catalog_source_fingerprint ~ '^[a-f0-9]{64}$'
        and c.source_contract_version = 'brandconnect_current_provenance_epoch_v2'
        and c.provenance_epoch = 'CURRENT_OFFICIAL_V1'
        and c.source_active = true
        and c.source_status not in ('INACTIVE', 'DISABLED', 'DELETED')
        and c.current_provenance_fingerprint = compute_current_provenance_fingerprint(c.source_kind, c.source_snapshot_hash, c.source_row_hash, c.source_observed_at, c.source_contract_version, c.provenance_epoch, c.channel_product_no, c.source_active, c.source_status))
       or
       (c.source_kind = 'brandconnect_official_display_category_authenticated_get'
        and c.catalog_source_fingerprint is null
        and c.current_provenance_fingerprint is null
        and c.source_contract_version is null and c.provenance_epoch is null
        and c.source_snapshot_hash ~ '^[a-f0-9]{64}$' and c.source_row_hash ~ '^[a-f0-9]{64}$'
        and c.source_active = true and c.source_status = 'SALE')
     );

  select count(*) into v_candidates from catalog_items c
   where c.is_active and c.category_status = 'CONFIRMED'
     and c.category_evidence_fingerprint ~ '^[a-f0-9]{64}$'
     and c.category_key = v_category and c.affiliate_url is null
     and (
       (c.catalog_source_fingerprint ~ '^[a-f0-9]{64}$'
        and c.source_contract_version = 'brandconnect_current_provenance_epoch_v2'
        and c.provenance_epoch = 'CURRENT_OFFICIAL_V1'
        and c.source_active = true
        and c.source_status not in ('INACTIVE', 'DISABLED', 'DELETED')
        and c.current_provenance_fingerprint = compute_current_provenance_fingerprint(c.source_kind, c.source_snapshot_hash, c.source_row_hash, c.source_observed_at, c.source_contract_version, c.provenance_epoch, c.provenance_epoch, c.channel_product_no, c.source_active, c.source_status))
       or
       (c.source_kind = 'brandconnect_official_display_category_authenticated_get'
        and c.catalog_source_fingerprint is null
        and c.current_provenance_fingerprint is null
        and c.source_contract_version is null and c.provenance_epoch is null
        and c.source_snapshot_hash ~ '^[a-f0-9]{64}$' and c.source_row_hash ~ '^[a-f0-9]{64}$'
        and c.source_active = true and c.source_status = 'SALE')
     )
     and not exists (select 1 from issuance_reservation_items i join issuance_reservations ir using (reservation_id) where i.channel_product_no = c.channel_product_no and i.status = 'RESERVED' and ir.status = 'RESERVED')
     and not exists (select 1 from issuance_reservation_items i join issuance_reservations ir using (reservation_id) where i.channel_product_no = c.channel_product_no and i.status = 'RELEASED' and ir.sync_run_id = p_sync_run_id);

  insert into issuance_reservations(category_id, sync_run_id, requested_count, selected_at, last_selected_at)
  values (v_category, p_sync_run_id, v_limit, now(), now()) returning reservation_id into v_res;
  update category_registry set last_selected_at = now() where category_id = v_category;

  insert into issuance_reservation_items(reservation_id, channel_product_no)
  select v_res, c.channel_product_no from catalog_items c
   where c.is_active and c.category_status = 'CONFIRMED'
     and c.category_evidence_fingerprint ~ '^[a-f0-9]{64}$'
     and c.category_key = v_category and c.affiliate_url is null
     and (
       (c.catalog_source_fingerprint ~ '^[a-f0-9]{64}$'
        and c.source_contract_version = 'brandconnect_current_provenance_epoch_v2'
        and c.provenance_epoch = 'CURRENT_OFFICIAL_V1'
        and c.source_active = true
        and c.source_status not in ('INACTIVE', 'DISABLED', 'DELETED')
        and c.current_provenance_fingerprint = compute_current_provenance_fingerprint(c.source_kind, c.source_snapshot_hash, c.source_row_hash, c.source_observed_at, c.source_contract_version, c.provenance_epoch, c.channel_product_no, c.source_active, c.source_status))
       or
       (c.source_kind = 'brandconnect_official_display_category_authenticated_get'
        and c.catalog_source_fingerprint is null
        and c.current_provenance_fingerprint is null
        and c.source_contract_version is null and c.provenance_epoch is null
        and c.source_snapshot_hash ~ '^[a-f0-9]{64}$' and c.source_row_hash ~ '^[a-f0-9]{64}$'
        and c.source_active = true and c.source_status = 'SALE')
     )
     and not exists (select 1 from issuance_reservation_items i join issuance_reservations ir using (reservation_id) where i.channel_product_no = c.channel_product_no and i.status = 'RESERVED' and ir.status = 'RESERVED')
     and not exists (select 1 from issuance_reservation_items i join issuance_reservations ir using (reservation_id) where i.channel_product_no = c.channel_product_no and i.status = 'RELEASED' and ir.sync_run_id = p_sync_run_id)
   order by c.observed_at, c.channel_product_no limit v_limit for update skip locked;

  select coalesce(jsonb_agg(channel_product_no order by channel_product_no), '[]'::jsonb) into v_ids
    from issuance_reservation_items where reservation_id = v_res;
  return jsonb_build_object('reservation_id', v_res, 'category_path', v_category, 'category_name', v_name, 'ids', v_ids, 'count', jsonb_array_length(v_ids), 'total_candidates', v_candidates, 'category_link_count_before', v_before);
end
$$;;
