-- Additive General issuance lane.  This migration is local/shadow-only until
-- separately reviewed and approved for production.  Category selection stays
-- unchanged; the guarded release wrapper only adds lane isolation.

alter table marketing_brandconnect.issuance_reservations
  add column if not exists issuance_mode text not null default 'BALANCED';
alter table marketing_brandconnect.issuance_reservations
  drop constraint if exists marketing_brandconnect_issuance_mode_check;
alter table marketing_brandconnect.issuance_reservations
  add constraint marketing_brandconnect_issuance_mode_check
  check (issuance_mode in ('GENERAL', 'BALANCED'));
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
         and c.is_active
         and c.affiliate_url is null
         and c.catalog_source_fingerprint ~ '^[a-f0-9]{64}$'
         and c.source_fingerprint ~ '^[a-f0-9]{64}$'
         and c.catalog_source_fingerprint = c.source_fingerprint
         and not exists (
           select 1
             from issuance_reservation_items i
             join issuance_reservations r using (reservation_id)
            where i.channel_product_no = c.channel_product_no
              and i.status = 'RESERVED'
              and r.status = 'RESERVED'
         )
       order by c.observed_at, c.channel_product_no
       limit greatest(1, least(coalesce(p_limit, 1), 200))
    ) q
$$;
create or replace function marketing_brandconnect.reserve_general(p_limit integer default 30)
returns jsonb
language plpgsql
security definer
set search_path = marketing_brandconnect, pg_catalog
as $$
declare
  v_limit integer := greatest(30, least(coalesce(p_limit, 30), 50));
  v_reservation uuid;
  v_ids jsonb;
  v_candidates integer;
begin
  -- One advisory lock serializes all General reservations.  The row-level
  -- RESERVED check is repeated after the lock, so a released transaction can
  -- never hand the same identity to two General reservations.
  perform pg_advisory_xact_lock(hashtextextended('brandconnect:general', 0));

  select count(*) into v_candidates
    from catalog_items c
   where c.provider = 'brandconnect'
     and c.is_active
     and c.affiliate_url is null
     and c.catalog_source_fingerprint ~ '^[a-f0-9]{64}$'
     and c.source_fingerprint ~ '^[a-f0-9]{64}$'
     and c.catalog_source_fingerprint = c.source_fingerprint
     and not exists (
       select 1
         from issuance_reservation_items i
         join issuance_reservations r using (reservation_id)
        where i.channel_product_no = c.channel_product_no
          and i.status = 'RESERVED'
          and r.status = 'RESERVED'
     );

  insert into issuance_reservations(category_id, sync_run_id, requested_count, selected_at, last_selected_at, issuance_mode)
  values (null, null, v_limit, now(), now(), 'GENERAL')
  returning reservation_id into v_reservation;

  insert into issuance_reservation_items(reservation_id, channel_product_no)
    select v_reservation, c.channel_product_no
      from catalog_items c
     where c.provider = 'brandconnect'
       and c.is_active
       and c.affiliate_url is null
       and c.catalog_source_fingerprint ~ '^[a-f0-9]{64}$'
       and c.source_fingerprint ~ '^[a-f0-9]{64}$'
       and c.catalog_source_fingerprint = c.source_fingerprint
       and not exists (
         select 1
           from issuance_reservation_items i
           join issuance_reservations r using (reservation_id)
          where i.channel_product_no = c.channel_product_no
            and i.status = 'RESERVED'
            and r.status = 'RESERVED'
       )
     order by c.observed_at, c.channel_product_no
     limit v_limit
     for update skip locked;

  select coalesce(jsonb_agg(channel_product_no order by channel_product_no), '[]'::jsonb)
    into v_ids
    from issuance_reservation_items
   where reservation_id = v_reservation;

  return jsonb_build_object(
    'mode', 'GENERAL',
    'reservation_id', v_reservation,
    'ids', v_ids,
    'count', jsonb_array_length(v_ids),
    'total_candidates', v_candidates,
    'category_required', false
  );
end
$$;
create or replace function marketing_brandconnect.release_category(p_reservation_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = marketing_brandconnect, pg_catalog
as $$
declare v_mode text; v_released integer;
begin
  select issuance_mode into v_mode from issuance_reservations where reservation_id = p_reservation_id;
  if v_mode is distinct from 'BALANCED' then raise exception 'balanced_reservation_mismatch'; end if;
  update issuance_reservation_items
     set status='RELEASED', released_at=coalesce(released_at, now())
   where reservation_id=p_reservation_id and status='RESERVED';
  get diagnostics v_released = row_count;
  update issuance_reservations
     set status='RELEASED', released_at=now()
   where reservation_id=p_reservation_id and status='RESERVED';
  return jsonb_build_object('reservation_id', p_reservation_id, 'released', v_released, 'status', 'RELEASED');
end
$$;
create or replace function marketing_brandconnect.release_general(p_reservation_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = marketing_brandconnect, pg_catalog
as $$
declare v_mode text; v_released integer;
begin
  select issuance_mode into v_mode from issuance_reservations where reservation_id = p_reservation_id;
  if v_mode is distinct from 'GENERAL' then raise exception 'general_reservation_mismatch'; end if;
  update issuance_reservation_items
     set status='RELEASED', released_at=coalesce(released_at, now())
   where reservation_id=p_reservation_id and status='RESERVED';
  get diagnostics v_released = row_count;
  update issuance_reservations
     set status='RELEASED', released_at=now()
   where reservation_id=p_reservation_id and status='RESERVED';
  return jsonb_build_object('reservation_id', p_reservation_id, 'released', v_released, 'status', 'RELEASED');
end
$$;
do $$
declare f record;
begin
  for f in select * from (values
    ('pending_general(integer)'),
    ('reserve_general(integer)'),
    ('release_general(uuid)')
  ) as x(signature) loop
    execute format('revoke all on function marketing_brandconnect.%s from public, anon, authenticated', f.signature);
    execute format('grant execute on function marketing_brandconnect.%s to service_role', f.signature);
  end loop;
end
$$;
