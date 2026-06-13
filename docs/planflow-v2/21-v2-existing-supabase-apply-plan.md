# PlanFlow V2 Existing Supabase Apply Plan

이 문서는 PlanFlow V2의 `schema / RPC / RLS`를 **새 Supabase 프로젝트가 아니라 기존 PlanFlow Supabase 프로젝트**에 단계별로 적용하기 위한 준비 문서다.

이 문서는 **실제 DB 적용 명령서가 아니며**, 운영 데이터 훼손 위험을 낮추기 위한 사전 점검과 실행 순서만 정리한다.

## 1. 현재 확인된 Supabase 상태

- project ref: `xqvvfnvmytjlblcngipn`
- project name: `PlanFlow`
- region: `ap-northeast-1`
- release channel: `ga`
- status: `ACTIVE_HEALTHY`
- database version: PostgreSQL 17

### 1.1 현재 확인된 테이블 범위

기존 개인 PlanFlow 테이블은 아래처럼 존재한다.

- `public.users`
- `public.events`
- `public.reminders`
- `public.pre_actions`
- `public.voice_logs`
- `public.location_history`
- `public.user_settings`
- `planflow.events`
- `planflow.reminders`
- `planflow.pre_actions`
- `planflow.voice_logs`
- `planflow.location_history`
- `planflow.user_settings`
- `planflow.early_bird_emails`

### 1.2 public.users 구조

현재 `public.users`는 아래 컬럼을 가진다.

- `id uuid not null`
- `email text null`
- `name text null`
- `created_at timestamptz not null`

따라서 V2의 `invite_code`는 `public.users`에 추가하는 방향이 맞다.

## 2. 백업 / 복구 상태

확인 결과:

- `walg_enabled = true`
- `pitr_enabled = false`
- `supabase backups list --project-ref xqvvfnvmytjlblcngipn` 결과 backup 엔트리 없음

판단:

- 현재는 **백업 기능은 켜져 있지만 즉시 복구 가능한 restore point는 보이지 않는다.**
- 따라서 이 프로젝트는 **적용 위험 있음**으로 분류한다.
- 실제 적용 전에는 최소한 최근 스냅샷/별도 논리 백업 확보가 필요하다.

### 최소 안전 절차

1. 적용 직전 전체 스키마 백업을 남긴다.
2. 가능하면 DDL 적용 전에 `supabase db dump` 또는 동등 백업을 확보한다.
3. 단계별 적용 후마다 `information_schema`, `pg_indexes`, `pg_policies` 검증을 즉시 수행한다.
4. 한 단계라도 실패하면 다음 단계로 넘어가지 않는다.

## 3. 단계별 적용 순서

적용은 아래 순서로만 진행한다.

1. `public.users` invite code
2. `groups`
3. `group_members`
4. `group_invites`
5. `group_role_delegations`
6. `group_events`
7. `group_backups`
8. RPC
   - `accept_group_invite`
   - `archive_group_with_backup`
   - `remove_group_member`
9. RLS policies

## 4. 단계별 적용 / 검증 SQL

### STEP 1. `public.users invite_code`

#### 적용 전 확인 SQL

```sql
select column_name, data_type, is_nullable
from information_schema.columns
where table_schema = 'public'
  and table_name = 'users'
order by ordinal_position;
```

#### 적용 SQL

```sql
alter table public.users
  add column if not exists invite_code text;

create unique index if not exists users_invite_code_key
  on public.users (invite_code);
```

#### 적용 후 확인 SQL

```sql
select column_name, data_type, is_nullable
from information_schema.columns
where table_schema = 'public'
  and table_name = 'users'
  and column_name = 'invite_code';

select indexname, indexdef
from pg_indexes
where schemaname = 'public'
  and tablename = 'users'
  and indexname = 'users_invite_code_key';
```

#### 실패 시 중단 기준

- `public.users` 구조가 예상과 다를 때
- unique index 생성이 기존 데이터 충돌로 실패할 때
- 기존 사용자 데이터가 넓게 깨질 가능성이 보일 때

#### 롤백

```sql
drop index if exists public.users_invite_code_key;
alter table public.users drop column if exists invite_code;
```

---

### STEP 2. `groups`, `group_members`

#### 적용 전 확인 SQL

```sql
select table_name
from information_schema.tables
where table_schema = 'public'
  and table_name in ('groups', 'group_members');
```

#### 적용 SQL

```sql
create table if not exists public.groups (
  id uuid primary key default gen_random_uuid(),
  parent_group_id uuid null references public.groups(id) on delete set null,
  name text not null,
  description text null,
  status text not null default 'active',
  created_by uuid not null references public.users(id) on delete restrict,
  archived_at timestamptz null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint groups_status_check check (status in ('active', 'archived', 'deleted_pending'))
);

create index if not exists groups_parent_group_id_idx on public.groups (parent_group_id);
create index if not exists groups_status_idx on public.groups (status);
create index if not exists groups_created_by_idx on public.groups (created_by);

create table if not exists public.group_members (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null references public.groups(id) on delete cascade,
  user_id uuid not null references public.users(id) on delete cascade,
  role text not null default 'member',
  status text not null default 'active',
  joined_at timestamptz not null default now(),
  removed_at timestamptz null,
  removed_by uuid null references public.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint group_members_role_check check (role in ('leader', 'member')),
  constraint group_members_status_check check (status in ('active', 'removed')),
  constraint group_members_group_user_key unique (group_id, user_id)
);

create index if not exists group_members_group_id_idx on public.group_members (group_id);
create index if not exists group_members_user_id_idx on public.group_members (user_id);
create index if not exists group_members_group_role_idx on public.group_members (group_id, role);
```

#### 적용 후 확인 SQL

```sql
select table_name
from information_schema.tables
where table_schema = 'public'
  and table_name in ('groups', 'group_members')
order by table_name;

select constraint_name, constraint_type
from information_schema.table_constraints
where table_schema = 'public'
  and table_name in ('groups', 'group_members');
```

#### 실패 시 중단 기준

- self reference FK가 꼬일 때
- `group_members` unique 제약이 기존 데이터와 충돌할 때
- status/role check가 실제 운영 데이터와 충돌할 때

#### 롤백

```sql
drop table if exists public.group_members;
drop table if exists public.groups;
```

---

### STEP 3. `group_invites`, `group_role_delegations`

#### 적용 전 확인 SQL

```sql
select table_name
from information_schema.tables
where table_schema = 'public'
  and table_name in ('group_invites', 'group_role_delegations');
```

#### 적용 SQL

```sql
create table if not exists public.group_invites (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null references public.groups(id) on delete cascade,
  invited_user_id uuid null references public.users(id) on delete cascade,
  invited_email text null,
  invited_invite_code text null,
  invited_by uuid not null references public.users(id) on delete restrict,
  status text not null default 'pending',
  expires_at timestamptz not null,
  accepted_at timestamptz null,
  rejected_at timestamptz null,
  cancelled_at timestamptz null,
  expired_at timestamptz null,
  acted_by uuid null references public.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint group_invites_status_check check (status in ('pending', 'accepted', 'rejected', 'cancelled', 'expired'))
);

create index if not exists group_invites_group_id_idx on public.group_invites (group_id);
create index if not exists group_invites_invited_by_idx on public.group_invites (invited_by);
create index if not exists group_invites_invited_user_id_idx on public.group_invites (invited_user_id);
create index if not exists group_invites_invited_email_idx on public.group_invites (invited_email);
create index if not exists group_invites_invited_invite_code_idx on public.group_invites (invited_invite_code);
create index if not exists group_invites_status_idx on public.group_invites (status);
create index if not exists group_invites_expires_at_idx on public.group_invites (expires_at);

create unique index if not exists group_invites_pending_user_key
  on public.group_invites (group_id, invited_user_id)
  where status = 'pending' and invited_user_id is not null;

create unique index if not exists group_invites_pending_email_key
  on public.group_invites (group_id, invited_email)
  where status = 'pending' and invited_email is not null;

create unique index if not exists group_invites_pending_invite_code_key
  on public.group_invites (group_id, invited_invite_code)
  where status = 'pending' and invited_invite_code is not null;

create table if not exists public.group_role_delegations (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null references public.groups(id) on delete cascade,
  delegator_user_id uuid not null references public.users(id) on delete cascade,
  delegate_user_id uuid not null references public.users(id) on delete cascade,
  permissions jsonb not null default '[]'::jsonb,
  starts_at timestamptz not null,
  ends_at timestamptz not null,
  status text not null default 'active',
  cancelled_at timestamptz null,
  cancelled_by uuid null references public.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint group_role_delegations_status_check check (status in ('active', 'expired', 'cancelled')),
  constraint group_role_delegations_time_check check (ends_at > starts_at)
);

create index if not exists group_role_delegations_group_id_idx on public.group_role_delegations (group_id);
create index if not exists group_role_delegations_delegator_user_id_idx on public.group_role_delegations (delegator_user_id);
create index if not exists group_role_delegations_delegate_user_id_idx on public.group_role_delegations (delegate_user_id);
create index if not exists group_role_delegations_status_idx on public.group_role_delegations (status);
create index if not exists group_role_delegations_time_idx on public.group_role_delegations (starts_at, ends_at);
create index if not exists group_role_delegations_group_delegate_status_idx
  on public.group_role_delegations (group_id, delegate_user_id, status);

create unique index if not exists group_role_delegations_active_unique
  on public.group_role_delegations (group_id, delegate_user_id)
  where status = 'active';
```

#### 적용 후 확인 SQL

```sql
select table_name
from information_schema.tables
where table_schema = 'public'
  and table_name in ('group_invites', 'group_role_delegations')
order by table_name;
```

#### 실패 시 중단 기준

- pending partial unique index가 기존 데이터와 충돌할 때
- permissions JSON 정책이 더 엄격해야 하는 징후가 보일 때
- status/time 제약이 실제 요구와 충돌할 때

#### 롤백

```sql
drop table if exists public.group_role_delegations;
drop table if exists public.group_invites;
```

---

### STEP 4. `group_events`, `group_backups`

#### 적용 전 확인 SQL

```sql
select table_name
from information_schema.tables
where table_schema = 'public'
  and table_name in ('group_events', 'group_backups');
```

#### 적용 SQL

```sql
create table if not exists public.group_events (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null references public.groups(id) on delete cascade,
  title text not null,
  description text null,
  location text null,
  start_at timestamptz not null,
  end_at timestamptz not null,
  all_day boolean not null default false,
  recurrence_type text not null default 'none',
  recurrence_until timestamptz null,
  created_by uuid not null references public.users(id) on delete restrict,
  updated_by uuid null references public.users(id) on delete set null,
  cancelled_at timestamptz null,
  cancelled_by uuid null references public.users(id) on delete set null,
  status text not null default 'active',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint group_events_recurrence_check check (recurrence_type in ('none', 'daily', 'weekly', 'monthly')),
  constraint group_events_status_check check (status in ('active', 'cancelled', 'archived')),
  constraint group_events_time_check check (end_at >= start_at)
);

create index if not exists group_events_group_id_idx on public.group_events (group_id);
create index if not exists group_events_created_by_idx on public.group_events (created_by);
create index if not exists group_events_updated_by_idx on public.group_events (updated_by);
create index if not exists group_events_cancelled_by_idx on public.group_events (cancelled_by);
create index if not exists group_events_status_idx on public.group_events (status);
create index if not exists group_events_start_at_idx on public.group_events (start_at);
create index if not exists group_events_group_start_at_idx on public.group_events (group_id, start_at);
create index if not exists group_events_group_status_start_at_idx on public.group_events (group_id, status, start_at);

create table if not exists public.group_backups (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null references public.groups(id) on delete cascade,
  backup_type text not null,
  snapshot jsonb not null,
  created_by uuid not null references public.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  restored_at timestamptz null,
  restored_by uuid null references public.users(id) on delete set null,
  constraint group_backups_type_check check (backup_type in ('archive', 'delete'))
);

create index if not exists group_backups_group_id_idx on public.group_backups (group_id);
create index if not exists group_backups_created_by_idx on public.group_backups (created_by);
create index if not exists group_backups_restored_by_idx on public.group_backups (restored_by);
create index if not exists group_backups_created_at_idx on public.group_backups (created_at);
```

#### 적용 후 확인 SQL

```sql
select table_name
from information_schema.tables
where table_schema = 'public'
  and table_name in ('group_events', 'group_backups')
order by table_name;
```

#### 실패 시 중단 기준

- recurrence/status check가 기존 데이터 모델과 맞지 않을 때
- snapshot JSON 구조가 restore에 충분하지 않을 때
- group archive/restore 흐름과 충돌할 때

#### 롤백

```sql
drop table if exists public.group_backups;
drop table if exists public.group_events;
```

---

### STEP 5. RPC

대상:

- `accept_group_invite`
- `archive_group_with_backup`
- `remove_group_member`

#### 적용 전 확인 SQL

```sql
select routine_schema, routine_name
from information_schema.routines
where routine_schema = 'public'
  and routine_name in (
    'accept_group_invite',
    'archive_group_with_backup',
    'remove_group_member'
  );
```

#### 적용 SQL

이 단계는 실제 구현본의 함수 본문을 그대로 적용한다.
문서 기준 핵심은 아래다.

```sql
-- accept_group_invite:
-- 1) pending invite 검증
-- 2) 만료 검증
-- 3) membership 중복 검증
-- 4) group_members insert
-- 5) invite accepted 갱신

-- archive_group_with_backup:
-- 1) group row lock
-- 2) leader 검증
-- 3) backup snapshot insert
-- 4) groups archived 갱신
-- 5) archived_at 기록

-- remove_group_member:
-- 1) leader 검증
-- 2) 자기 자신 제거 금지
-- 3) 마지막 leader 제거 금지
-- 4) removed_at / removed_by 기록
```

#### 적용 후 확인 SQL

```sql
select routine_schema, routine_name
from information_schema.routines
where routine_schema = 'public'
  and routine_name in (
    'accept_group_invite',
    'archive_group_with_backup',
    'remove_group_member'
  )
order by routine_name;
```

#### 실패 시 중단 기준

- 원자성 보장이 안 되는 형태로 들어갈 때
- 권한 체크가 빠질 때
- 그룹/멤버/초대 테이블과 정합성이 어긋날 때

#### 롤백

```sql
drop function if exists public.accept_group_invite(uuid);
drop function if exists public.archive_group_with_backup(uuid);
drop function if exists public.remove_group_member(uuid, uuid);
```

---

### STEP 6. RLS policies

#### 적용 전 확인 SQL

```sql
select schemaname, tablename, policyname
from pg_policies
where schemaname = 'public'
  and tablename in (
    'users',
    'groups',
    'group_members',
    'group_invites',
    'group_role_delegations',
    'group_events',
    'group_backups'
  )
order by tablename, policyname;
```

#### 적용 방향

- `public.users`: 본인 조회/수정
- `groups`: member 조회, leader 생성/수정, archived 기본 제외
- `group_members`: member 조회, leader 관리
- `group_invites`: 초대 생성/조회/수락/거절/취소 분기
- `group_role_delegations`: leader 생성/조회/취소, delegate 조회
- `group_events`: member 조회, leader 또는 delegation 권한 생성/수정/취소
- `group_backups`: leader만 조회/복원

#### 적용 후 확인 SQL

```sql
select schemaname, tablename, policyname
from pg_policies
where schemaname = 'public'
  and tablename in (
    'users',
    'groups',
    'group_members',
    'group_invites',
    'group_role_delegations',
    'group_events',
    'group_backups'
  )
order by tablename, policyname;
```

#### 실패 시 중단 기준

- member가 leader보다 넓은 권한을 갖게 될 때
- sibling group 접근이 차단되지 않을 때
- archived group이 기본 조회에 남아 있을 때

#### 롤백

```sql
-- 테이블별 정책 이름 확정 후 drop policy 문으로 되돌린다.
```

## 5. 실패 시 중단 기준 총정리

- 백업/복구 가능한 restore point가 확보되지 않은 상태
- STEP 1부터 STEP 6 중 하나라도 schema check에서 실패
- 기존 개인 `events / reminders / pre_actions / voice_logs` 구조가 깨질 위험
- `RLS`가 기존 개인 기능을 막는 징후
- RPC가 원자성을 보장하지 못하는 징후

## 6. 롤백 계획

### 6.1 원칙

- 한 단계가 끝날 때마다 확인 SQL을 수행한다.
- 실패하면 그 단계에서 멈춘다.
- 다음 단계로 진행하지 않는다.

### 6.2 롤백 우선순위

1. 가장 최근에 추가한 테이블/함수/정책부터 제거
2. 데이터가 들어갔다면 먼저 테스트 데이터 삭제
3. 필요한 경우 스키마 변경을 역순으로 되돌림
4. 최종적으로 백업 복구가 가능하면 복구 검토

### 6.3 운영 DB 위험도

- 현재 백업 엔트리가 없으므로 위험도가 높다.
- `release_channel=ga` 이므로 운영 성격으로 보고 더 보수적으로 다룬다.
- 사용자 최종 승인 없이 실제 적용은 하지 않는다.

## 7. 사용자 최종 승인 필요 문구

아래가 명확히 확인되기 전에는 실제 적용을 시작하지 않는다.

- 현재 대상이 맞는지
- 최근 백업 / 복구 가능성이 있는지
- 단계별 적용 도중 즉시 중단할 책임자가 누구인지
- 기존 개인 PlanFlow 데이터 보호 조건이 충분한지

## 8. 최종 체크리스트

| 항목 | 완료 여부 | 비고 |
|---|---|---|
| 현재 project ref 확인 | 완료 | `xqvvfnvmytjlblcngipn` |
| 프로젝트 이름 확인 | 완료 | `PlanFlow` |
| 운영 성격 여부 | 완료 | `release_channel=ga` |
| 백업 엔트리 확인 | 완료 | 없음 |
| PITR 여부 확인 | 완료 | 비활성 |
| 기존 개인 테이블 존재 확인 | 완료 | `events / reminders / pre_actions / voice_logs` 등 |
| V2 테이블 적용 순서 정의 | 완료 | STEP 1~6 |
| 단계별 검증 SQL 정의 | 완료 | 준비용 |
| 실제 DB 적용 | 미완료 | 이번 문서 범위 밖 |

## 9. 결론

기존 PlanFlow Supabase에 V2 schema / RPC / RLS를 추가하는 계획은 수립할 수 있지만, 현재 확인된 상태만 보면 백업/복구 안전성이 충분하지 않다.

따라서 실제 적용은 단계별로만 진행하고, 각 단계마다 검증 SQL과 중단 기준을 충족해야 다음 단계로 넘어갈 수 있다.

사용자 최종 승인 없이 실제 DB 적용은 하지 않는다.

## 10. STEP 1 실제 적용 결과

### 적용 대상 확인

- project ref: `xqvvfnvmytjlblcngipn`
- project name: `PlanFlow`
- 운영 성격 경고 확인 여부: 확인함

### STEP 1 적용 전 상태

- users row count: `7`
- `invite_code` 컬럼 존재 여부: 없음
- 기존 `invite_code` null/중복 여부: null 검사 불가(컬럼 미존재), 중복 없음(컬럼 미존재)

### STEP 1 적용 결과

- 컬럼 추가 여부: 추가함
- `invite_code` 생성 여부: 기존 7개 사용자 모두 생성함
- unique/index 생성 여부: `users_invite_code_key` unique index 생성함

### STEP 1 검증 결과

- users row count 유지 여부: 유지됨(`7`)
- null 없음 여부: 없음(`null = 0`)
- 중복 없음 여부: 없음(`distinct = 7`)
- index 확인: 확인됨

### 실제 적용 범위

- STEP 1만 적용했는지 확인: 확인함

### 금지 범위 준수

- groups 미생성
- group_members 미생성
- RPC 미생성
- RLS 미변경
- Flutter 코드 미수정
- `schema.sql` 미수정

### 실패/보류 항목

- 없음

### 다음 단계 가능 여부

- STEP 2 `groups/group_members` 적용 가능: 보류
- 이유: 현재 프로젝트는 `release_channel=ga`이며, `walg_enabled=true`지만 실제 backup 엔트리가 보이지 않아 더 보수적인 승인 확인이 필요하다.

## 11. STEP 2 실제 적용 결과

### 적용 대상 확인

- project ref: `xqvvfnvmytjlblcngipn`
- project name: `PlanFlow`
- 운영 성격 경고 확인 여부: 확인함

### STEP 2 적용 전 상태

- users row count: `7`
- groups 존재 여부: 없음
- group_members 존재 여부: 없음
- 기존 개인 테이블 영향 확인:
  - `public.events`: `538`
  - `public.reminders`: `189`
  - `public.pre_actions`: `100`
  - `public.voice_logs`: `97`
  - `public.user_settings`: `6`

### STEP 2 적용 결과

- groups 생성 여부: 생성함
- group_members 생성 여부: 생성함
- constraints/indexes 생성 여부:
  - `groups_status_check`
  - `groups_parent_group_id_idx`
  - `groups_status_idx`
  - `groups_created_by_idx`
  - `group_members_role_check`
  - `group_members_status_check`
  - `group_members_group_user_key`
  - `group_members_group_id_idx`
  - `group_members_user_id_idx`
  - `group_members_group_role_idx`
- RLS 최소 정책 적용 여부: 적용함

### STEP 2 검증 결과

- users row count 유지 여부: 유지됨(`7`)
- groups/group_members 확인:
  - `public.groups`: 존재 확인
  - `public.group_members`: 존재 확인
- 테스트 group 생성 여부:
  - 트랜잭션 내부에서 생성 성공
  - 최종적으로 롤백하여 잔여 데이터 없음
- 테스트 membership 생성 여부:
  - 트랜잭션 내부에서 leader membership 생성 성공
  - 최종적으로 롤백하여 잔여 데이터 없음
- 기존 개인 데이터 영향 여부:
  - 변경 없음
  - counts 유지 확인

### 실제 적용 범위

- STEP 2만 적용했는지 확인: 확인함

### 금지 범위 준수

- group_invites 미생성
- group_role_delegations 미생성
- group_events 미생성
- group_backups 미생성
- RPC 미생성
- Flutter 코드 미수정
- `schema.sql` 미수정

### 실패/보류 항목

- 없음

### 다음 단계 가능 여부

- STEP 3 `group_invites/group_role_delegations` 적용 가능: 보류
- 이유: 기존 PlanFlow 프로젝트가 `ga` 채널이고, 현재는 단계별 보수적 적용만 확인한 상태라 다음 단계도 동일하게 승인/백업 상태를 다시 확인하는 편이 안전하다.

## 12. STEP 3 실제 적용 결과

### 적용 대상 확인

- project ref: `xqvvfnvmytjlblcngipn`
- project name: `PlanFlow`
- 운영 성격 경고 확인 여부: 확인함

### STEP 3 적용 결과

- `public.group_invites` 생성: 완료
- `public.group_role_delegations` 생성: 완료
- constraints/indexes 생성: 완료
  - `group_invites_status_check`
  - `group_invites_target_check`
  - `group_invites_group_id_idx`
  - `group_invites_invited_by_idx`
  - `group_invites_invited_user_id_idx`
  - `group_invites_invited_email_idx`
  - `group_invites_invited_invite_code_idx`
  - `group_invites_status_idx`
  - `group_invites_expires_at_idx`
  - `group_invites_pending_user_key`
  - `group_invites_pending_email_key`
  - `group_invites_pending_invite_code_key`
  - `group_role_delegations_status_check`
  - `group_role_delegations_time_check`
  - `group_role_delegations_permissions_check`
  - `group_role_delegations_group_id_idx`
  - `group_role_delegations_delegator_user_id_idx`
  - `group_role_delegations_delegate_user_id_idx`
  - `group_role_delegations_status_idx`
  - `group_role_delegations_time_idx`
  - `group_role_delegations_group_delegate_status_idx`
  - `group_role_delegations_active_unique`
- helper 생성: `group_delegation_permissions_valid(jsonb)` 완료
- 최소 권한/보안:
  - `RLS enabled` 확인
  - `authenticated` 대상 `GRANT` 확인

### STEP 3 검증 결과

- 테이블 존재 확인: 완료
- constraint/index 확인: 완료
- 테스트 invite 생성/롤백: 성공
- 테스트 delegation 생성/롤백: 성공
- 기존 개인 테이블 row count 유지:
  - `public.users`: `7`
  - `public.events`: `538`
  - `public.reminders`: `294`
  - `public.pre_actions`: `100`
  - `public.voice_logs`: `97`
  - `public.user_settings`: `6`
- PASS/FAIL: `PASS`

### 실제 적용 범위

- STEP 3만 적용했는지 확인: 확인함

### 실패/보류 항목

- 없음

## 13. STEP 4 실제 적용 결과

### 적용 대상 확인

- project ref: `xqvvfnvmytjlblcngipn`
- project name: `PlanFlow`
- 운영 성격 경고 확인 여부: 확인함

### STEP 4 적용 결과

- `public.group_events` 생성: 완료
- `public.group_backups` 생성: 완료
- constraints/indexes 생성: 완료
  - `group_events_recurrence_type_check`
  - `group_events_status_check`
  - `group_events_time_check`
  - `group_backups_backup_type_check`
  - `group_events_group_id_idx`
  - `group_events_created_by_idx`
  - `group_events_updated_by_idx`
  - `group_events_cancelled_by_idx`
  - `group_events_status_idx`
  - `group_events_start_at_idx`
  - `group_events_group_start_idx`
  - `group_events_group_status_start_idx`
  - `group_backups_group_id_idx`
  - `group_backups_created_by_idx`
  - `group_backups_restored_by_idx`
  - `group_backups_created_at_idx`
- trigger 생성: `group_events_set_updated_at` 완료

### STEP 4 검증 결과

- 테이블 존재 확인: 완료
- constraint/index 확인: 완료
- 테스트 group_event 생성/롤백: 성공
- 테스트 backup 생성/롤백: 성공
- 기존 개인 테이블 row count 유지:
  - `public.users`: `7`
  - `public.events`: `538`
  - `public.reminders`: `294`
  - `public.pre_actions`: `100`
  - `public.voice_logs`: `97`
  - `public.user_settings`: `6`
- PASS/FAIL: `PASS`

### 실제 적용 범위

- STEP 4만 적용했는지 확인: 확인함

### 실패/보류 항목

- 없음

## 14. STEP 5 실제 적용 결과

### 적용 대상 확인

- project ref: `xqvvfnvmytjlblcngipn`
- project name: `PlanFlow`
- 운영 성격 경고 확인 여부: 확인함

### STEP 5 적용 결과

- RPC/helper 생성: 완료
  - `public.is_group_member(uuid, uuid)`
  - `public.is_group_leader(uuid, uuid)`
  - `public.has_group_delegated_permission(uuid, uuid, text)`
  - `public.accept_group_invite(uuid)`
  - `public.archive_group_with_backup(uuid)`
  - `public.remove_group_member(uuid, uuid)`
- 원자성 처리:
  - `accept_group_invite`: invite 업데이트 + group_members upsert를 한 RPC에서 처리
  - `archive_group_with_backup`: backup insert + groups archive update를 한 RPC에서 처리
  - `remove_group_member`: self/leader guard + removed status update를 한 RPC에서 처리

### STEP 5 검증 결과

- `accept_group_invite` 성공:
  - `invite_status = accepted`
  - `member_status = active`
- `accept_group_invite` 실패:
  - expired invite 차단 확인
- `archive_group_with_backup` 성공:
  - `group_status = archived`
  - `archive_count = 1`
  - `archived_at_is_not_null = true`
- `archive_group_with_backup` 실패:
  - leader permission 없음 차단 확인
- `remove_group_member` 성공:
  - `member_status = removed`
  - `removed_by = leader id`
- `remove_group_member` 실패:
  - self removal 차단 확인
- `last leader removal`:
  - 직접적인 런타임 케이스는 현재 테스트 harness에서 self-removal guard가 먼저 발동하여 별도 분기 검증은 제한적이었음
- 기존 개인 테이블 row count 유지:
  - `public.users`: `7`
  - `public.events`: `538`
  - `public.reminders`: `294`
  - `public.pre_actions`: `100`
  - `public.voice_logs`: `97`
  - `public.user_settings`: `6`
- PASS/FAIL: `PASS`

### 실제 적용 범위

- STEP 5만 적용했는지 확인: 확인함

### 실패/보류 항목

- last leader 제거의 독립적인 런타임 분기 검증은 향후 수동 점검 권장

## 15. STEP 6 실제 적용 결과

### 적용 대상 확인

- project ref: `xqvvfnvmytjlblcngipn`
- project name: `PlanFlow`
- 운영 성격 경고 확인 여부: 확인함

### STEP 6 적용 결과

- 기존 owner-only 정책 교체: 완료
- 최종 RLS 정책 생성: 완료
  - `groups_select_active_members`
  - `groups_insert_owner`
  - `groups_update_leader`
  - `group_members_select_group_visible`
  - `group_members_insert_leader_or_invited_self`
  - `group_members_update_leader_or_invited_self`
  - `group_invites_select_related_users`
  - `group_invites_insert_leader_only`
  - `group_invites_update_leader_or_target`
  - `group_role_delegations_select_related`
  - `group_role_delegations_insert_leader_only`
  - `group_role_delegations_update_cancel`
  - `group_events_select_active_group_members`
  - `group_events_insert_leader_or_delegate`
  - `group_events_update_leader_or_delegate`
  - `group_events_delete_leader_or_delegate`
  - `group_backups_select_leader_only`
  - `group_backups_insert_leader_only`
  - `group_backups_update_leader_only`

### STEP 6 검증 결과

- policy 생성/조회: 완료
- leader/member/outsider 매트릭스: 정책 정의 확인 완료
- delegation permission 확인: 정책 정의 확인 완료
- group_backups member 차단: 정책 정의 확인 완료
- sibling group 접근 차단: 정책/함수 구조상 active member 기준으로 분리되도록 구성됨
- 주의:
  - 현재 검증 도구가 privileged SQL 연결이라 실제 unauthenticated/authenticated 경계의 최종 런타임 차단은 앱/anon smoke로 한 번 더 확인하는 편이 안전함
- 기존 개인 테이블 row count 유지:
  - `public.users`: `7`
  - `public.events`: `538`
  - `public.reminders`: `294`
  - `public.pre_actions`: `100`
  - `public.voice_logs`: `97`
  - `public.user_settings`: `6`
- PASS/FAIL: `PASS`  (정책 적용 기준)

### 실제 적용 범위

- STEP 6만 적용했는지 확인: 확인함

### 실패/보류 항목

- privileged MCP 연결 특성상 실제 authenticated/anon 경계의 최종 런타임 smoke는 별도 확인 권장
