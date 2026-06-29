# PlanFlow V2 배포 상태 즉시 점검 (read-only)

이 문서는 **실기기 V2 그룹 기능이 동작하려면 반드시 먼저 확인해야 하는** 한 가지 — V2 스키마(테이블·RPC·트리거·RLS)가 실제 라이브 Supabase(`PlanFlow`, ref `xqvvfnvmytjlblcngipn`)에 배포돼 있는가 — 를 한 번에 점검하는 읽기 전용 SQL이다.

- 모두 `SELECT`만 하므로 **운영 DB에 안전하게 실행**할 수 있다(데이터 변경 없음).
- Supabase 대시보드 → SQL Editor에 붙여넣고 실행한다.
- 결과의 `status` 컬럼이 전부 `OK`면 배포 완료, 하나라도 `MISSING`이면 그 객체가 없어 실기기에서 해당 그룹 기능이 런타임 에러를 낸다.

## 1. V2 객체 존재 여부 (테이블·함수·트리거·컬럼)

```sql
with expected(kind, name) as (
  values
    ('table','groups'),
    ('table','group_members'),
    ('table','group_invites'),
    ('table','group_role_delegations'),
    ('table','group_events'),
    ('table','group_backups'),
    ('function','handle_new_group'),
    ('function','is_group_leader'),
    ('function','accept_group_invite'),
    ('function','remove_group_member'),
    ('function','archive_group_with_backup'),
    ('trigger','groups_handle_new_group'),
    ('column','users.invite_code')
)
select
  e.kind,
  e.name,
  case
    when e.kind = 'table' and to_regclass('public.'||e.name) is not null then 'OK'
    when e.kind = 'function' and exists (
      select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public' and p.proname = e.name
    ) then 'OK'
    when e.kind = 'trigger' and exists (
      select 1 from pg_trigger t where not t.tgisinternal and t.tgname = e.name
    ) then 'OK'
    when e.kind = 'column' and exists (
      select 1 from information_schema.columns
      where table_schema = 'public'
        and table_name = split_part(e.name,'.',1)
        and column_name = split_part(e.name,'.',2)
    ) then 'OK'
    else 'MISSING'
  end as status
from expected e
order by e.kind, e.name;
```

## 2. RLS 활성화 여부 (6개 그룹 테이블)

```sql
select c.relname as table_name,
       case when c.relrowsecurity then 'RLS_ON' else 'RLS_OFF' end as status,
       (select count(*) from pg_policies p
          where p.schemaname = 'public' and p.tablename = c.relname) as policy_count
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public'
  and c.relname in ('groups','group_members','group_invites',
                    'group_role_delegations','group_events','group_backups')
order by c.relname;
```

- 6개 행이 모두 `RLS_ON`이고 `policy_count > 0`이어야 한다. `RLS_OFF`거나 행 자체가 없으면 미배포.

## 3. 판정

- 1·2번 결과가 전부 `OK` / `RLS_ON`이면 → **배포 완료**. 실기기에서 그룹 생성/초대/일정이 정상 동작할 조건은 갖춰진 것이다(앱 빌드의 `SUPABASE_URL`이 이 프로젝트를 가리키는지도 함께 확인).
- 하나라도 `MISSING` / 행 없음 / `RLS_OFF`이면 → **미배포**. 이 경우 [16-v2-schema-sql-final-draft.md](./16-v2-schema-sql-final-draft.md) 또는 저장소의 `supabase/schema.sql`의 V2 구간을 [21-v2-existing-supabase-apply-plan.md](./21-v2-existing-supabase-apply-plan.md) 절차에 따라 적용해야 한다.

## 3.5. ⚠️ OAuth Redirect URL 허용목록 (카카오/네이버 로그인 필수)

V2는 딥링크 스킴을 `planflow-v2://`로 분리했으므로, **Supabase Auth의 Redirect URL 허용목록에
`planflow-v2://auth-callback`이 반드시 포함**돼야 한다. 이게 없으면 카카오/네이버 웹 OAuth가
인증 후 빈 Supabase 콜백 페이지에서 멈추고 앱으로 복귀하지 못한다(구글은 네이티브 로그인이라 무관).

- Supabase 대시보드 → **Authentication → URL Configuration → Redirect URLs**
- 다음 두 개가 모두 있어야 한다(메인 PlanFlow와 V2 공존):
  - `planflow://auth-callback`      (메인 PlanFlow)
  - `planflow-v2://auth-callback`   (V2 — 누락되기 쉬움)
- 증상 메모: 신규 로그인만 깨지고, 이미 세션이 있는 기기는 세션 복원이라 멀쩡해 보일 수 있다.

## 4. 앱이 보는 Supabase가 맞는지 확인

실기기 release APK가 위 프로젝트를 보는지 확인한다(`--dart-define` 또는 `env/local.json`의 `SUPABASE_URL`):

- 기대값 host: `xqvvfnvmytjlblcngipn.supabase.co`
- 불일치하면 스키마가 배포돼 있어도 앱은 다른 DB를 보게 되어 그룹 기능이 실패한다.
