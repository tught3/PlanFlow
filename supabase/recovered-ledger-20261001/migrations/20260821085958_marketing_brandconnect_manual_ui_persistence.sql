-- Manual UI issuance recovery is a separate, service-role-only contract.
-- It must never relax the automated reservation/apply path.

create table if not exists marketing_brandconnect.manual_issuance_evidence (
  channel_product_no text primary key
    references marketing_brandconnect.catalog_items(channel_product_no)
    on delete restrict,
  affiliate_url_hash text not null
    check (affiliate_url_hash ~ '^[a-f0-9]{64}$'),
  issuance_source text not null default 'MANUAL_UI'
    check (issuance_source = 'MANUAL_UI'),
  evidence_source text not null default 'official_brandconnect_ui'
    check (evidence_source = 'official_brandconnect_ui'),
  issued_at timestamptz not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table marketing_brandconnect.manual_issuance_evidence enable row level security;
revoke all on table marketing_brandconnect.manual_issuance_evidence from public, anon, authenticated, service_role;
grant select on table marketing_brandconnect.manual_issuance_evidence to service_role;
create or replace function marketing_brandconnect.apply_manual_issued_link(
  p_channel_product_no text,
  p_affiliate_url text,
  p_affiliate_url_hash text,
  p_issued_at timestamptz default now()
)
returns jsonb
language plpgsql
security definer
set search_path = marketing_brandconnect, pg_catalog
as $$
declare
  v_id text := nullif(btrim(p_channel_product_no), '');
  v_url text := nullif(btrim(p_affiliate_url), '');
  v_hash text := lower(nullif(btrim(p_affiliate_url_hash), ''));
  v_expected_hash text;
  v_existing_url text;
  v_existing_hash text;
  v_existing_source text;
  v_row marketing_brandconnect.catalog_items%rowtype;
begin
  if v_id is null then raise exception 'manual_identity_required'; end if;
  if v_url is null or v_url !~ '^https://naver[.]me/[^/?#]+$' then
    raise exception 'manual_url_invalid';
  end if;
  if v_hash is null or v_hash !~ '^[a-f0-9]{64}$' then
    raise exception 'manual_url_hash_invalid';
  end if;
  if p_issued_at is null or p_issued_at > now() + interval '5 minutes' then
    raise exception 'manual_issued_at_invalid';
  end if;

  v_expected_hash := encode(extensions.digest(convert_to(v_url, 'UTF8'), 'sha256'), 'hex');
  if v_hash <> v_expected_hash then raise exception 'manual_url_hash_mismatch'; end if;

  select * into v_row
    from marketing_brandconnect.catalog_items
   where channel_product_no = v_id
   for update;
  if not found then raise exception 'manual_identity_not_found'; end if;

  if v_row.is_active is not true
     or v_row.source_active is not true
     or v_row.source_status is null
     or v_row.source_status in ('INACTIVE','DISABLED','DELETED')
     or v_row.source_contract_version is distinct from 'brandconnect_current_provenance_epoch_v2'
     or v_row.provenance_epoch is distinct from 'CURRENT_OFFICIAL_V1'
     or v_row.source_kind is distinct from 'brandconnect_official_store_xhr'
     or v_row.source_snapshot_hash is distinct from 'c7cd98dc95fed5565ea88bbc9f789c59d5da0a1f64482ce7cf6300050acc5740'
     or v_row.source_row_hash is null
     or v_row.source_row_hash !~ '^[a-f0-9]{64}$'
     or v_row.source_observed_at is null
     or v_row.current_provenance_fingerprint is null
     or v_row.current_provenance_fingerprint !~ '^[a-f0-9]{64}$'
     or v_row.current_provenance_fingerprint is distinct from compute_current_provenance_fingerprint(
       v_row.source_kind,
       v_row.source_snapshot_hash,
       v_row.source_row_hash,
       v_row.source_observed_at,
       v_row.source_contract_version,
       v_row.provenance_epoch,
       v_row.channel_product_no,
       v_row.source_active,
       v_row.source_status
     ) then
    raise exception 'manual_current_provenance_required';
  end if;

  if exists (
    select 1
      from marketing_brandconnect.issuance_reservation_items i
      join marketing_brandconnect.issuance_reservations r using (reservation_id)
     where i.channel_product_no = v_id
       and i.status = 'RESERVED'
       and r.status = 'RESERVED'
  ) then
    raise exception 'manual_reservation_conflict';
  end if;

  select affiliate_url into v_existing_url
    from marketing_brandconnect.catalog_items
   where channel_product_no = v_id;
  select affiliate_url_hash, issuance_source into v_existing_hash, v_existing_source
    from marketing_brandconnect.manual_issuance_evidence
   where channel_product_no = v_id;

  if v_existing_hash is not null and v_existing_hash <> v_hash then
    raise exception 'manual_evidence_conflict';
  end if;
  if v_existing_url is not null and v_existing_url <> v_url then
    raise exception 'manual_affiliate_conflict';
  end if;
  if v_existing_url is not null and v_row.affiliate_source is distinct from 'MANUAL_UI' then
    raise exception 'manual_source_conflict';
  end if;

  if v_existing_url is null then
    update marketing_brandconnect.catalog_items
       set affiliate_url = v_url,
           affiliate_source = 'MANUAL_UI',
           affiliate_issued_at = p_issued_at,
           updated_at = now()
     where channel_product_no = v_id;
    insert into marketing_brandconnect.affiliate_url_history(channel_product_no, affiliate_url, source)
      values (v_id, v_url, 'MANUAL_UI')
      on conflict do nothing;
    insert into marketing_brandconnect.issuance_ledger(channel_product_no, affiliate_url, source, issued_at)
      values (v_id, v_url, 'MANUAL_UI', p_issued_at)
      on conflict do nothing;
  end if;

  insert into marketing_brandconnect.manual_issuance_evidence(
    channel_product_no, affiliate_url_hash, issuance_source, evidence_source, issued_at
  ) values (v_id, v_hash, 'MANUAL_UI', 'official_brandconnect_ui', p_issued_at)
  on conflict (channel_product_no) do nothing;

  return jsonb_build_object(
    'status', case when v_existing_url is null then 'APPLIED' else 'IDEMPOTENT' end,
    'channel_product_no', v_id,
    'issuance_source', 'MANUAL_UI',
    'url_hash', v_hash,
    'reservation_required', false,
    'overwrite', false
  );
end;
$$;
revoke all on function marketing_brandconnect.apply_manual_issued_link(text,text,text,timestamptz)
  from public, anon, authenticated;
grant execute on function marketing_brandconnect.apply_manual_issued_link(text,text,text,timestamptz)
  to service_role;
