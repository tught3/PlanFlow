-- FluxOS Cloud Watchdog — 클라우드 안전망 테이블 + 스케줄 헬퍼
--
-- 목적: PC가 꺼지거나 로컬 데몬이 죽어도, 항상 켜진 Supabase(pg_cron + Edge Function)가
--       FluxOS 생존(heartbeat)/정체를 감지해 Telegram 알림을 보낼 수 있게 한다.
-- 테이블은 PostgREST 기본 노출 스키마(public)에 fluxos_ 접두로 둔다(전용 스키마는
-- "Exposed schemas" 설정이 추가로 필요해 설정 마찰이 큼). 운영 테이블이므로 RLS로 anon 차단.

create extension if not exists pg_cron;
create extension if not exists pg_net;

-- 1) heartbeat: 로컬 데몬 생존 신호. 로컬 supervisor가 tick(60s)마다 upsert.
create table if not exists public.fluxos_heartbeat (
    host          text not null,
    daemon        text not null,
    last_seen_at  timestamptz not null default now(),
    summary       jsonb not null default '{}'::jsonb,
    primary key (host, daemon)
);

-- 2) task_mirror: 비종료 작업 스냅샷. mirrored_at으로 신선도를 판단(오래된 행=더 이상 활성 아님).
create table if not exists public.fluxos_task_mirror (
    task_id        text primary key,
    project        text,
    pipeline_state text,
    status         text,
    stage          text,
    updated_at     timestamptz,
    stall_since    timestamptz,
    mirrored_at    timestamptz not null default now()
);
create index if not exists fluxos_task_mirror_mirrored_at_idx on public.fluxos_task_mirror (mirrored_at);
create index if not exists fluxos_task_mirror_stall_since_idx  on public.fluxos_task_mirror (stall_since);

-- 3) alerts: 클라우드 알림 중복 발송 방지 로그(쿨다운 내 같은 alert_key 재발송 차단).
create table if not exists public.fluxos_alerts (
    id         bigserial primary key,
    alert_key  text not null,
    kind       text,
    created_at timestamptz not null default now()
);
create index if not exists fluxos_alerts_key_created_idx on public.fluxos_alerts (alert_key, created_at desc);
-- C2(성능): index.ts latestAlertAt이 kind=eq.*&order=created_at.desc로 조회하므로 (kind, created_at desc) 인덱스 추가.
create index if not exists idx_fluxos_alerts_kind_created on public.fluxos_alerts (kind, created_at desc);

-- RLS: anon/authenticated 전면 차단. service_role은 RLS를 우회하므로 정책이 없어도 접근 가능.
alter table public.fluxos_heartbeat   enable row level security;
alter table public.fluxos_task_mirror enable row level security;
alter table public.fluxos_alerts      enable row level security;
revoke all on public.fluxos_heartbeat   from anon, authenticated;
revoke all on public.fluxos_task_mirror from anon, authenticated;
revoke all on public.fluxos_alerts      from anon, authenticated;

-- 4) 스케줄 헬퍼: cron이 Edge Function을 호출하도록 등록한다. 서비스키를 git에 남기지
--    않으려고, 이 함수를 SQL 에디터에서 1회 호출해 등록한다(키는 호출 인자로만 전달).
--    예) select public.fluxos_schedule_watchdog(
--            'https://<project-ref>.supabase.co/functions/v1/fluxos-watchdog',
--            '<SERVICE_ROLE_KEY>');
create or replace function public.fluxos_schedule_watchdog(
    fn_url text,
    service_key text,
    schedule text default '*/2 * * * *'
)
returns void
language plpgsql
security definer
as $fn$
begin
    if exists (select 1 from cron.job where jobname = 'fluxos-watchdog') then
        perform cron.unschedule('fluxos-watchdog');
    end if;

    perform cron.schedule(
        'fluxos-watchdog',
        schedule,
        format(
            $cmd$select net.http_post(
                url := %L,
                headers := jsonb_build_object(
                    'Content-Type', 'application/json',
                    'Authorization', 'Bearer ' || %L
                ),
                body := '{}'::jsonb
            );$cmd$,
            fn_url, service_key
        )
    );
end;
$fn$;

-- 5) C2(클라우드): alerts/task_mirror 독립 purge cron.
--    기존 purge는 Edge Function cleanup()에만 있어, watchdog cron이 멈추면 두 테이블이 무한 증가한다.
--    watchdog cron(Edge Function 호출)과는 별개의 안전망으로, 매시 정각 DB 내부에서 직접 정리한다.
--    (Edge Function이 죽어도 이 cron만 살아있으면 테이블 폭증을 막는다.)
do $purge$
begin
    if exists (select 1 from cron.job where jobname = 'fluxos-purge') then
        perform cron.unschedule('fluxos-purge');
    end if;
    perform cron.schedule(
        'fluxos-purge',
        '0 * * * *',
        $$
        delete from public.fluxos_alerts where created_at < now() - interval '7 days';
        delete from public.fluxos_task_mirror where mirrored_at < now() - interval '24 hours';
        $$
    );
end;
$purge$;
