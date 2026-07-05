# PlanFlow V2 Supabase Verification SQL

이 문서는 PlanFlow V2를 staging/dev Supabase DB에 적용하기 전에 사용하는 검증 SQL과 수동 검증 시나리오 문서다.

이 문서는 운영 DB 적용용이 아니며, 실제 운영 Supabase에는 절대 적용하지 않는다.

## 1. 목적

- V2 schema / RPC / RLS가 staging/dev Supabase에서 정상 동작하는지 검증한다.
- 운영 적용 전에 실패 지점을 미리 찾는다.
- 실제 운영 DB에는 적용하지 않는다는 안전 경계를 분명히 한다.

## 2. 검증 전 준비사항

- staging/dev Supabase 프로젝트를 사용한다.
- 운영 DB 백업을 먼저 확보한다.
- 테스트용 사용자 3명을 준비한다.
  - `leader_user`
  - `member_user`
  - `outsider_user`
- 각 사용자의 `public.users.id`, `email`, `invite_code`를 확인한다.
- SQL Editor 또는 `psql` 사용 가능 여부를 먼저 확인한다.

### 준비용 확인 SQL 예시

```sql
select id, email, invite_code
from public.users
where email in (
  'leader@example.com',
  'member@example.com',
  'outsider@example.com'
)
order by email;
```

```sql
select current_database(), current_user, session_user;
```

## 3. Schema 존재 확인 SQL

검증 대상:

- `users.invite_code`
- `groups`
- `group_members`
- `group_invites`
- `group_role_delegations`
- `group_events`
- `group_backups`

### 3.1 public.users / invite_code

```sql
select
  table_schema,
  table_name,
  column_name,
  data_type,
  is_nullable
from information_schema.columns
where table_schema = 'public'
  and table_name = 'users'
  and column_name = 'invite_code';
```

### 3.2 groups

```sql
select column_name, data_type, is_nullable
from information_schema.columns
where table_schema = 'public'
  and table_name = 'groups'
order by ordinal_position;
```

### 3.3 group_members

```sql
select column_name, data_type, is_nullable
from information_schema.columns
where table_schema = 'public'
  and table_name = 'group_members'
order by ordinal_position;
```

### 3.4 group_invites

```sql
select column_name, data_type, is_nullable
from information_schema.columns
where table_schema = 'public'
  and table_name = 'group_invites'
order by ordinal_position;
```

### 3.5 group_role_delegations

```sql
select column_name, data_type, is_nullable
from information_schema.columns
where table_schema = 'public'
  and table_name = 'group_role_delegations'
order by ordinal_position;
```

### 3.6 group_events

```sql
select column_name, data_type, is_nullable
from information_schema.columns
where table_schema = 'public'
  and table_name = 'group_events'
order by ordinal_position;
```

### 3.7 group_backups

```sql
select column_name, data_type, is_nullable
from information_schema.columns
where table_schema = 'public'
  and table_name = 'group_backups'
order by ordinal_position;
```

## 4. Index / Constraint 확인 SQL

### 4.1 unique / check / FK / partial index 확인

```sql
select
  c.conname as constraint_name,
  c.contype as constraint_type,
  t.relname as table_name,
  pg_get_constraintdef(c.oid) as definition
from pg_constraint c
join pg_class t on t.oid = c.conrelid
join pg_namespace n on n.oid = t.relnamespace
where n.nspname = 'public'
  and t.relname in (
    'users',
    'groups',
    'group_members',
    'group_invites',
    'group_role_delegations',
    'group_events',
    'group_backups'
  )
order by t.relname, c.conname;
```

### 4.2 index 확인

```sql
select
  schemaname,
  tablename,
  indexname,
  indexdef
from pg_indexes
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
order by tablename, indexname;
```

### 4.3 확인해야 할 핵심 체크 항목

- `invite_code` unique
- `group_members unique(group_id, user_id)`
- `group_invites` pending partial unique indexes
- role/status check constraints
- `recurrence_type` check
- `backup_type` check

### 4.4 partial unique index 존재 확인 예시

```sql
select
  indexname,
  indexdef
from pg_indexes
where schemaname = 'public'
  and tablename = 'group_invites'
  and indexdef ilike '%where status = ''pending''%';
```

## 5. 테스트 데이터 생성 시나리오

주의:

- 실제 SQL은 staging/dev 전용이다.
- 운영 사용 금지다.
- 아래 예시는 `psql` 또는 SQL Editor에서 순차 실행하는 형태다.

### 5.1 사용자 확인

```sql
select id, email, invite_code
from public.users
where email in (
  'leader@example.com',
  'member@example.com',
  'outsider@example.com'
);
```

### 5.2 leader가 group 생성

```sql
insert into public.groups (
  id,
  name,
  description,
  status,
  created_by,
  created_at,
  updated_at
)
values (
  gen_random_uuid(),
  'QA 테스트 팀',
  'staging/dev 검증용 그룹',
  'active',
  'LEADER_USER_ID',
  now(),
  now()
)
returning id;
```

### 5.3 leader를 group_members leader로 추가

```sql
insert into public.group_members (
  id,
  group_id,
  user_id,
  role,
  status,
  joined_at,
  created_at,
  updated_at
)
values (
  gen_random_uuid(),
  'GROUP_ID',
  'LEADER_USER_ID',
  'leader',
  'active',
  now(),
  now(),
  now()
);
```

### 5.4 member 초대 생성

```sql
insert into public.group_invites (
  id,
  group_id,
  invited_email,
  invited_by,
  status,
  expires_at,
  created_at,
  updated_at
)
values (
  gen_random_uuid(),
  'GROUP_ID',
  'member@example.com',
  'LEADER_USER_ID',
  'pending',
  now() + interval '7 days',
  now(),
  now()
)
returning id;
```

### 5.5 accept_group_invite 호출

```sql
select public.accept_group_invite('INVITE_ID');
```

### 5.6 group_events 생성

```sql
insert into public.group_events (
  id,
  group_id,
  title,
  description,
  location,
  start_at,
  end_at,
  all_day,
  recurrence_type,
  recurrence_until,
  created_by,
  status,
  created_at,
  updated_at
)
values (
  gen_random_uuid(),
  'GROUP_ID',
  'QA 그룹 회의',
  'staging/dev 검증용 회의',
  '회의실 A',
  now() + interval '1 day',
  now() + interval '1 day 1 hour',
  false,
  'none',
  null,
  'LEADER_USER_ID',
  'active',
  now(),
  now()
)
returning id;
```

### 5.7 delegation 생성

```sql
insert into public.group_role_delegations (
  id,
  group_id,
  delegator_user_id,
  delegate_user_id,
  permissions,
  starts_at,
  ends_at,
  status,
  created_at,
  updated_at
)
values (
  gen_random_uuid(),
  'GROUP_ID',
  'LEADER_USER_ID',
  'MEMBER_USER_ID',
  '["create_group_event","update_group_event","cancel_group_event","view_group_dashboard"]'::jsonb,
  now(),
  now() + interval '7 days',
  'active',
  now(),
  now()
)
returning id;
```

### 5.8 backup / archive 테스트

```sql
select public.archive_group_with_backup('GROUP_ID');
```

## 6. RPC 검증 SQL

### 6.1 accept_group_invite

#### 성공 케이스

```sql
select public.accept_group_invite('INVITE_ID');
```

#### 권한 없음 케이스

```sql
select public.accept_group_invite('OTHER_USERS_INVITE_ID');
```

#### 중복 호출 케이스

```sql
select public.accept_group_invite('INVITE_ID');
select public.accept_group_invite('INVITE_ID');
```

#### 만료 / 이미 처리된 상태

```sql
update public.group_invites
set status = 'expired', expired_at = now()
where id = 'INVITE_ID';

select public.accept_group_invite('INVITE_ID');
```

### 6.2 archive_group_with_backup

#### 성공 케이스

```sql
select public.archive_group_with_backup('GROUP_ID');
```

#### 권한 없음 케이스

```sql
select public.archive_group_with_backup('OTHER_GROUP_ID');
```

#### 중복 호출 케이스

```sql
select public.archive_group_with_backup('GROUP_ID');
select public.archive_group_with_backup('GROUP_ID');
```

#### 이미 archived group 방지

```sql
update public.groups
set status = 'archived', archived_at = now()
where id = 'GROUP_ID';

select public.archive_group_with_backup('GROUP_ID');
```

### 6.3 remove_group_member

#### 성공 케이스

```sql
select public.remove_group_member('GROUP_ID', 'MEMBER_USER_ID');
```

#### 권한 없음 케이스

```sql
select public.remove_group_member('GROUP_ID', 'OUTSIDER_USER_ID');
```

#### 중복 호출 케이스

```sql
select public.remove_group_member('GROUP_ID', 'MEMBER_USER_ID');
select public.remove_group_member('GROUP_ID', 'MEMBER_USER_ID');
```

#### 자기 자신 제거 방지

```sql
select public.remove_group_member('GROUP_ID', 'LEADER_USER_ID');
```

#### 마지막 leader 제거 방지

```sql
select public.remove_group_member('GROUP_ID', 'LEADER_USER_ID');
```

## 7. RLS 검증 매트릭스

| 사용자 | 대상 | 작업 | 기대 결과 |
|---|---|---|---|
| leader_user | own group | view group | 허용 |
| member_user | joined group | view group | 허용 |
| outsider_user | other group | view group | 차단 |
| leader_user | own group | create invite | 허용 |
| member_user | own group | create invite | 차단 |
| invited_user | own invite | accept invite | 허용 |
| outsider_user | other invite | accept invite | 차단 |
| leader_user | own group | create group_event | 허용 |
| member_user | own group | create group_event without delegation | 차단 |
| member_user | own group | create group_event with delegation | 허용 |
| member_user | own group | view group_backups | 차단 |
| leader_user | own group | view group_backups | 허용 |
| outsider_user | sibling group | view group | 차단 |

### 검증 메모

- leader can view group
- member can view group
- outsider cannot view group
- leader can create invite
- member cannot create invite
- invited user can accept invite
- outsider cannot accept invite
- leader can create group_event
- member without delegation cannot create group_event
- member with delegation can create group_event
- member cannot view group_backups
- leader can view group_backups
- sibling group access blocked

## 8. Calendar Overlay 수동 확인

앱에서 아래를 확인한다.

- 개인 일정만 표시
- 그룹 일정만 표시
- 둘 다 표시
- 그룹 일정 클릭 시 `GroupEventDetail`
- 개인 일정 클릭 시 기존 상세
- `selectedGroup` 변경 시 overlay refresh

### 수동 확인 방법

1. personal mode 상태로 캘린더를 연다.
2. 그룹을 선택한 뒤 overlay가 나타나는지 확인한다.
3. day sheet에서 personal / group 섹션이 구분되는지 확인한다.
4. 그룹 일정 항목을 눌러 `GroupEventDetail`로 이동하는지 확인한다.
5. 개인 일정 항목을 눌러 기존 개인 상세로 이동하는지 확인한다.
6. selected group을 바꾼 뒤 overlay가 즉시 갱신되는지 확인한다.

## 9. 실패 시 롤백 확인

### schema 실패 시

- 마지막 적용 DDL부터 역순으로 되돌린다.
- FK / index / trigger / policy 순서로 제거한다.

### RPC 실패 시

- 함수 정의만 롤백한다.
- RPC가 사용하던 helper가 있으면 함께 점검한다.

### RLS 실패 시

- 잘못된 table policy만 되돌린다.
- 다른 테이블 정책은 유지한다.

### 테스트 데이터 제거 순서

1. `group_events`
2. `group_role_delegations`
3. `group_invites`
4. `group_members`
5. `groups`

### 백업 복구 기준

- 실제 적용 전 스냅샷이 있으면 그 시점으로 복구한다.
- 복구 전에는 의존 테이블 순서를 확인한다.

## 10. 최종 PASS 기준

- schema 존재 확인 PASS
- index / constraint PASS
- RPC 성공 / 실패 케이스 PASS
- RLS 허용 / 차단 PASS
- Flutter analyze PASS
- group tests PASS
- calendar overlay 수동 PASS

## 11. 실제 적용 전 체크리스트

| 항목 | 완료 여부 | 비고 |
|---|---|---|
| staging/dev 프로젝트 선택 | TBD | 운영 DB 아님 |
| 운영 DB 백업 | TBD | 필수 |
| leader_user / member_user / outsider_user 준비 | TBD | 최소 3명 |
| public.users id/email/invite_code 확인 | TBD | 초대 검증용 |
| schema 존재 확인 SQL 실행 | TBD | 스키마 검증 |
| index / constraint 확인 SQL 실행 | TBD | 중복 방지 |
| RPC 검증 SQL 실행 | TBD | 원자성 확인 |
| RLS 매트릭스 실행 | TBD | 허용/차단 확인 |
| 캘린더 overlay 수동 확인 | TBD | 실제 앱 |
| 롤백 기준 확인 | TBD | 실패 대비 |

## 12. 다음 단계 추천

- staging/dev DB에 먼저 적용한다.
- 이 문서의 SQL을 순서대로 실행하고 결과를 기록한다.
- schema / RPC / RLS 각각의 PASS / FAIL를 남긴다.
- 문제가 없으면 운영 반영 여부를 다시 판단한다.

