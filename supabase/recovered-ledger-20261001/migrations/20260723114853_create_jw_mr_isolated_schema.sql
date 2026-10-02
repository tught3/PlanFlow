create schema if not exists jw_mr;

revoke all on schema jw_mr from anon, authenticated;
grant usage on schema jw_mr to postgres, service_role;

create table if not exists jw_mr.rules (
  id bigint generated always as identity primary key,
  rule_key text not null unique,
  category text not null,
  rule_text text not null,
  priority integer not null default 100,
  is_active boolean not null default true,
  source text not null default 'user',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists jw_mr.professors (
  id bigint generated always as identity primary key,
  hospital_code text not null check (hospital_code in ('wonju','gangneung')),
  hospital_label text not null,
  specialty text not null,
  professor_name text not null,
  source_type text not null default 'schedule' check (source_type in ('schedule','user_added','correction')),
  is_active boolean not null default true,
  excluded boolean not null default false,
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (hospital_code, specialty, professor_name)
);

create table if not exists jw_mr.schedule_slots (
  id bigint generated always as identity primary key,
  professor_id bigint not null references jw_mr.professors(id) on delete cascade,
  week_group smallint,
  weekday smallint not null check (weekday between 1 and 7),
  time_note text,
  source_asset text,
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);
create unique index if not exists schedule_slots_unique_idx on jw_mr.schedule_slots(professor_id, coalesce(week_group,0), weekday, coalesce(time_note,''));

create table if not exists jw_mr.detail_history (
  id bigint generated always as identity primary key,
  activity_date date not null,
  hospital_code text not null check (hospital_code in ('wonju','gangneung')),
  hospital_label text not null,
  specialty text not null,
  professor_name text,
  product text not null,
  detail_topic text not null,
  detail_text text not null,
  next_visit_topic text,
  source_kind text not null default 'generated' check (source_kind in ('generated','user_provided','edited')),
  created_at timestamptz not null default now()
);

create index if not exists detail_history_date_idx on jw_mr.detail_history(activity_date desc);
create index if not exists detail_history_professor_idx on jw_mr.detail_history(hospital_code, professor_name, activity_date desc);
create index if not exists detail_history_topic_idx on jw_mr.detail_history(hospital_code, specialty, detail_topic, activity_date desc);

create table if not exists jw_mr.reference_assets (
  id bigint generated always as identity primary key,
  asset_key text not null unique,
  asset_type text not null,
  description text not null,
  source_path text,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

revoke all on all tables in schema jw_mr from anon, authenticated;
grant all on all tables in schema jw_mr to postgres, service_role;
grant usage, select on all sequences in schema jw_mr to postgres, service_role;

insert into jw_mr.rules(rule_key, category, rule_text, priority) values
('hospital_explicit_priority','selection','병원이 지정되면 요일과 시간표보다 지정 병원을 우선한다. 시간표는 기본 자동 매칭용 참고자료다.',10),
('authoritative_names_only','selection','시간표 또는 사용자가 직접 제공하거나 정정한 근거 있는 교수명만 사용하고 임의 생성하지 않는다.',10),
('weekday_schedule_preferred','selection','병원만 지정된 경우 오늘 요일 시간표를 우선하고 부족하면 같은 병원의 다른 요일 명단에서 보충한다.',20),
('avoid_professor_5_days','selection','최근 5일 이내 등장한 교수는 원칙적으로 제외하며 시간표 일치보다 중복 회피를 우선한다.',15),
('one_specialty_per_day','selection','하루 일정에서 동일 진료과는 최대 1명만 배치한다.',10),
('exclude_plastic_surgery','selection','원주기독과 강릉아산 일정에서 성형외과는 항상 제외한다.',10),
('hospital_labels','format','병원 표기는 원주세브란스기독병원은 원주기독, 강릉아산병원은 강릉아산으로 축약한다.',20),
('plaju_restriction','product','플라주 오피는 사용자가 별도 요청하거나 진료과명이 정확히 응급의학과인 경우에만 자동 사용한다. 응급중환자의학과는 예외가 아니다.',10),
('next_visit_inline','format','오늘 디테일과 다음 방문 시 디테일 예정 내용을 한 문단으로 이어 쓴다.',10),
('next_visit_new_topic','content','다음 방문은 당일과 다른 제품 또는 같은 제품의 다른 특장점을 구체적으로 디테일 예정으로 작성한다. 의견 나눔, 함께 검토, 실제 사용 확인 표현은 사용하지 않는다.',10),
('diversity_six','content','6개 일정은 진료과, 제품, 디테일 포인트, 문장 스타일, 종결 표현을 최대한 다르게 구성한다.',10),
('avoid_topic_3_days','content','최근 최소 3일 동안 동일 또는 유사 진료과와 동일 또는 유사 디테일 주제 조합을 반복하지 않는다.',10),
('no_middle_dot','format','구분 기호로 가운데점 문자를 사용하지 않고 쉼표 또는 자연스러운 문장을 사용한다.',10),
('winnerf_654_sparse','product','위너프 654 SPN 포인트는 여러 디테일 중 하나로만 사용하며 하루 0~1개, 최근 5일 내 사용 시 특별한 사유 없으면 재사용하지 않는다.',20),
('pics_campaign','product','PICS 교육 기간에는 해당 기간 주제로 하루 최대 3명만 진료과에 맞게 서로 겹치지 않게 배정하고, 기간 종료 후에는 위너프 에이플러스 일반 디테일 포인트 풀에 포함한다.',15)
on conflict (rule_key) do update set rule_text=excluded.rule_text, category=excluded.category, priority=excluded.priority, is_active=true, updated_at=now();

insert into jw_mr.professors(hospital_code,hospital_label,specialty,professor_name,source_type,notes) values
('wonju','원주기독','대장항문외과','권혜연','correction','권해연 아님'),
('wonju','원주기독','산부인과','이산희','correction','이이산 아님'),
('gangneung','강릉아산','신경외과','장선우','correction','정선우 아님'),
('gangneung','강릉아산','응급의학과','정상구','user_added','요일 무관, 플라주 오피 기본'),
('gangneung','강릉아산','응급의학과','이유진','user_added','요일 무관, 플라주 오피 기본'),
('gangneung','강릉아산','심장흉부외과','이한필','correction','이하필 아님')
on conflict (hospital_code,specialty,professor_name) do update set source_type=excluded.source_type, notes=excluded.notes, is_active=true, excluded=false, updated_at=now();

insert into jw_mr.reference_assets(asset_key,asset_type,description,source_path,metadata) values
('professor_schedule_2026_07_23','image','원주기독, 강릉아산 교수 시간표 기준 이미지','/mnt/data/image(2).png','{"status":"authoritative_reference","uploaded_in_conversation":true}'::jsonb),
('pics_training_2026','image_set','위너프 에이플러스 PICS 1차~4차 교육자료',null,'{"topics":["Persistent Inflammation","Immuno-suppression","Catabolism","Beyond Survival"]}'::jsonb)
on conflict (asset_key) do update set description=excluded.description, source_path=excluded.source_path, metadata=excluded.metadata, updated_at=now();;
