create or replace function marketing_brandconnect.apply_links(p_rows jsonb, p_reservation_id uuid default null::uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'marketing_brandconnect', 'pg_catalog'
as $function$
declare
  v_item jsonb;
  v_id text;
  v_url text;
  v_existing text;
  v_updated integer := 0;
  v_skipped integer := 0;
  v_not_found integer := 0;
begin
  if jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) = 0 then
    raise exception 'apply_rows_required';
  end if;

  for v_item in
    select source_item.value
      from jsonb_array_elements(p_rows) as source_item(value)
  loop
    v_id := nullif(btrim(v_item->>'channel_product_no'), '');
    v_url := nullif(btrim(v_item->>'affiliate_url'), '');

    if v_id is null or v_url is null or v_url !~ '^https://naver[.]me/[^/?#]+$' then
      raise exception 'apply_row_invalid';
    end if;

    if p_reservation_id is not null
       and not exists (
         select 1
           from issuance_reservations
          where reservation_id = p_reservation_id
            and status in ('RESERVED', 'APPLIED')
       )
    then
      raise exception 'reservation_unavailable';
    end if;

    if p_reservation_id is not null
       and exists (
         select 1
           from issuance_reservation_items
          where reservation_id = p_reservation_id
            and channel_product_no = v_id
            and status = 'APPLIED'
       )
    then
      if exists (
        select 1
          from catalog_items
         where channel_product_no = v_id
           and affiliate_url is distinct from v_url
      )
      then
        raise exception 'reservation_apply_conflict:%', v_id;
      end if;
      v_skipped := v_skipped + 1;
      continue;
    end if;

    if p_reservation_id is not null
       and not exists (
         select 1
           from issuance_reservation_items
          where reservation_id = p_reservation_id
            and channel_product_no = v_id
            and status = 'RESERVED'
       )
    then
      raise exception 'reservation_item_mismatch';
    end if;

    select affiliate_url
      into v_existing
      from catalog_items
     where channel_product_no = v_id
     for update;

    if not found then
      v_not_found := v_not_found + 1;
    elsif v_existing is null then
      update catalog_items
         set affiliate_url = v_url,
             affiliate_source = 'brandconnect_live',
             affiliate_issued_at = now(),
             updated_at = now()
       where channel_product_no = v_id;

      insert into affiliate_url_history(channel_product_no, affiliate_url, source)
      values (v_id, v_url, 'brandconnect_live')
      on conflict do nothing;

      insert into issuance_ledger(channel_product_no, affiliate_url, source)
      values (v_id, v_url, 'brandconnect_live')
      on conflict do nothing;

      v_updated := v_updated + 1;
    elsif v_existing = v_url then
      v_skipped := v_skipped + 1;
    else
      raise exception 'affiliate_conflict:%', v_id;
    end if;
  end loop;

  if p_reservation_id is not null then
    update issuance_reservation_items i
       set status = 'APPLIED',
           applied_at = coalesce(i.applied_at, now())
     where i.reservation_id = p_reservation_id
       and i.status = 'RESERVED'
       and exists (
         select 1
           from jsonb_array_elements(p_rows) as row_item(value)
           join catalog_items c
             on c.channel_product_no = row_item.value->>'channel_product_no'
          where row_item.value->>'channel_product_no' = i.channel_product_no
            and c.affiliate_url = row_item.value->>'affiliate_url'
       );

    if not exists (
      select 1
        from issuance_reservation_items
       where reservation_id = p_reservation_id
         and status = 'RESERVED'
    )
    then
      update issuance_reservations
         set status = 'APPLIED',
             applied_at = now()
       where reservation_id = p_reservation_id
         and status = 'RESERVED';
    end if;
  end if;

  return jsonb_build_object(
    'updated', v_updated,
    'skipped_existing', v_skipped,
    'not_found', v_not_found
  );
end
$function$;;
