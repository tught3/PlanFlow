-- NexusFlow Schema 생성
CREATE SCHEMA IF NOT EXISTS nexusflow;

-- 업종 모드
CREATE TABLE nexusflow.industry_modes (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID REFERENCES auth.users(id) ON DELETE CASCADE,
  mode_type TEXT NOT NULL, -- pharma / insurance / general / custom
  is_active BOOLEAN DEFAULT true,
  custom_name TEXT,
  created_at TIMESTAMPTZ DEFAULT now()
);

-- 거래처
CREATE TABLE nexusflow.accounts (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID REFERENCES auth.users(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  industry_mode TEXT,
  address TEXT,
  region TEXT,
  priority INTEGER DEFAULT 3, -- 1=최고 5=최저
  relationship_score INTEGER DEFAULT 50, -- 0~100
  last_contacted_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
);

-- 담당자
CREATE TABLE nexusflow.contacts (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID REFERENCES auth.users(id) ON DELETE CASCADE,
  account_id UUID REFERENCES nexusflow.accounts(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  role TEXT,
  department TEXT,
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
);

-- 담당자 별칭 (STT 오인식 보정용)
CREATE TABLE nexusflow.contact_aliases (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  contact_id UUID REFERENCES nexusflow.contacts(id) ON DELETE CASCADE,
  alias TEXT NOT NULL,
  created_at TIMESTAMPTZ DEFAULT now()
);

-- 담당자 민감정보 (암호화 저장)
CREATE TABLE nexusflow.contact_secure_vault (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  contact_id UUID REFERENCES nexusflow.contacts(id) ON DELETE CASCADE,
  data_type TEXT NOT NULL, -- phone / address / birthday / family / insurance
  encrypted_value TEXT NOT NULL,
  encryption_key_hint TEXT,
  data_source_consent_type TEXT,
  created_at TIMESTAMPTZ DEFAULT now()
);

-- 담당자 방문 가능 시간 (제약영업)
CREATE TABLE nexusflow.contact_availability_slots (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  contact_id UUID REFERENCES nexusflow.contacts(id) ON DELETE CASCADE,
  day_of_week INTEGER NOT NULL, -- 0=일 1=월 ... 6=토
  time_slot TEXT NOT NULL, -- morning / afternoon / evening
  is_available BOOLEAN DEFAULT true,
  note TEXT,
  created_at TIMESTAMPTZ DEFAULT now()
);

-- 원본 입력 소스
CREATE TABLE nexusflow.raw_sources (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID REFERENCES auth.users(id) ON DELETE CASCADE,
  source_type TEXT NOT NULL, -- voice_memo / screenshot_ocr / sms / call_transcript / file_upload / manual / kakao_notification
  raw_text TEXT,
  original_file_deleted_at TIMESTAMPTZ,
  user_consented_at TIMESTAMPTZ,
  processed BOOLEAN DEFAULT false,
  created_at TIMESTAMPTZ DEFAULT now()
);

-- AI 추출 결과
CREATE TABLE nexusflow.ai_extractions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  raw_source_id UUID REFERENCES nexusflow.raw_sources(id) ON DELETE CASCADE,
  user_id UUID REFERENCES auth.users(id) ON DELETE CASCADE,
  extracted_data JSONB,
  confidence_score FLOAT,
  confidence_level TEXT, -- high / mid / low
  status TEXT DEFAULT 'pending', -- pending / confirmed / rejected
  created_at TIMESTAMPTZ DEFAULT now()
);

-- 검수 대기열
CREATE TABLE nexusflow.validation_queue (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID REFERENCES auth.users(id) ON DELETE CASCADE,
  extraction_id UUID REFERENCES nexusflow.ai_extractions(id) ON DELETE CASCADE,
  queue_status TEXT DEFAULT 'pending', -- pending / resolved / dismissed
  created_at TIMESTAMPTZ DEFAULT now(),
  resolved_at TIMESTAMPTZ
);

-- 관계 메모리
CREATE TABLE nexusflow.confirmed_memories (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID REFERENCES auth.users(id) ON DELETE CASCADE,
  contact_id UUID REFERENCES nexusflow.contacts(id) ON DELETE SET NULL,
  account_id UUID REFERENCES nexusflow.accounts(id) ON DELETE SET NULL,
  memory_type TEXT NOT NULL, -- permanent / temporal / action
  content TEXT NOT NULL,
  created_at TIMESTAMPTZ DEFAULT now(),
  expires_at TIMESTAMPTZ
);

-- 활성 신호 (기회/리스크)
CREATE TABLE nexusflow.active_signals (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID REFERENCES auth.users(id) ON DELETE CASCADE,
  account_id UUID REFERENCES nexusflow.accounts(id) ON DELETE CASCADE,
  signal_type TEXT NOT NULL, -- opportunity / risk / followup / data_quality
  signal_content TEXT,
  is_active BOOLEAN DEFAULT true,
  created_at TIMESTAMPTZ DEFAULT now(),
  expires_at TIMESTAMPTZ
);

-- 인터랙션 이벤트 (타임라인)
CREATE TABLE nexusflow.interaction_events (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID REFERENCES auth.users(id) ON DELETE CASCADE,
  account_id UUID REFERENCES nexusflow.accounts(id) ON DELETE SET NULL,
  contact_id UUID REFERENCES nexusflow.contacts(id) ON DELETE SET NULL,
  event_type TEXT NOT NULL, -- visit / call / message / note
  summary TEXT,
  raw_source_id UUID REFERENCES nexusflow.raw_sources(id) ON DELETE SET NULL,
  occurred_at TIMESTAMPTZ DEFAULT now(),
  created_at TIMESTAMPTZ DEFAULT now()
);

-- 액션 아이템
CREATE TABLE nexusflow.action_items (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID REFERENCES auth.users(id) ON DELETE CASCADE,
  account_id UUID REFERENCES nexusflow.accounts(id) ON DELETE SET NULL,
  contact_id UUID REFERENCES nexusflow.contacts(id) ON DELETE SET NULL,
  content TEXT NOT NULL,
  due_date TIMESTAMPTZ,
  status TEXT DEFAULT 'pending', -- pending / done / snoozed
  planflow_event_id UUID, -- PlanFlow events 테이블 연동용
  created_at TIMESTAMPTZ DEFAULT now()
);

-- 업종별 용어 사전
CREATE TABLE nexusflow.term_dictionary (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID REFERENCES auth.users(id) ON DELETE CASCADE,
  industry_mode TEXT,
  term TEXT NOT NULL,
  meaning TEXT,
  dict_scope TEXT DEFAULT 'user', -- user / system
  created_at TIMESTAMPTZ DEFAULT now()
);

-- 용어 별칭
CREATE TABLE nexusflow.term_aliases (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  term_id UUID REFERENCES nexusflow.term_dictionary(id) ON DELETE CASCADE,
  alias TEXT NOT NULL,
  created_at TIMESTAMPTZ DEFAULT now()
);

-- Quick Action 정의
CREATE TABLE nexusflow.quick_actions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  industry_mode TEXT,
  label TEXT NOT NULL,
  action_type TEXT,
  dict_scope TEXT DEFAULT 'system', -- system / user
  created_at TIMESTAMPTZ DEFAULT now()
);

-- 인사이트
CREATE TABLE nexusflow.insights (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID REFERENCES auth.users(id) ON DELETE CASCADE,
  account_id UUID REFERENCES nexusflow.accounts(id) ON DELETE SET NULL,
  insight_type TEXT NOT NULL, -- today_action / visit_timing / opportunity / risk / data_quality
  content TEXT NOT NULL,
  status TEXT DEFAULT 'new', -- new / seen / acted / dismissed / expired
  created_at TIMESTAMPTZ DEFAULT now(),
  expires_at TIMESTAMPTZ
);

-- 인사이트 피드백
CREATE TABLE nexusflow.insight_feedback (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  insight_id UUID REFERENCES nexusflow.insights(id) ON DELETE CASCADE,
  user_id UUID REFERENCES auth.users(id) ON DELETE CASCADE,
  feedback_type TEXT NOT NULL, -- helpful / wrong / already_done
  created_at TIMESTAMPTZ DEFAULT now()
);

-- 학습 패턴 (인사이트 개선용)
CREATE TABLE nexusflow.shared_learning_patterns (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID REFERENCES auth.users(id) ON DELETE CASCADE,
  pattern_type TEXT,
  pattern_data JSONB,
  created_at TIMESTAMPTZ DEFAULT now()
);

-- RLS 활성화
ALTER TABLE nexusflow.industry_modes ENABLE ROW LEVEL SECURITY;
ALTER TABLE nexusflow.accounts ENABLE ROW LEVEL SECURITY;
ALTER TABLE nexusflow.contacts ENABLE ROW LEVEL SECURITY;
ALTER TABLE nexusflow.contact_aliases ENABLE ROW LEVEL SECURITY;
ALTER TABLE nexusflow.contact_secure_vault ENABLE ROW LEVEL SECURITY;
ALTER TABLE nexusflow.contact_availability_slots ENABLE ROW LEVEL SECURITY;
ALTER TABLE nexusflow.raw_sources ENABLE ROW LEVEL SECURITY;
ALTER TABLE nexusflow.ai_extractions ENABLE ROW LEVEL SECURITY;
ALTER TABLE nexusflow.validation_queue ENABLE ROW LEVEL SECURITY;
ALTER TABLE nexusflow.confirmed_memories ENABLE ROW LEVEL SECURITY;
ALTER TABLE nexusflow.active_signals ENABLE ROW LEVEL SECURITY;
ALTER TABLE nexusflow.interaction_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE nexusflow.action_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE nexusflow.term_dictionary ENABLE ROW LEVEL SECURITY;
ALTER TABLE nexusflow.term_aliases ENABLE ROW LEVEL SECURITY;
ALTER TABLE nexusflow.quick_actions ENABLE ROW LEVEL SECURITY;
ALTER TABLE nexusflow.insights ENABLE ROW LEVEL SECURITY;
ALTER TABLE nexusflow.insight_feedback ENABLE ROW LEVEL SECURITY;
ALTER TABLE nexusflow.shared_learning_patterns ENABLE ROW LEVEL SECURITY;

-- RLS 정책 (user_id 기준 본인 데이터만)
CREATE POLICY "nexusflow_user_isolation" ON nexusflow.accounts
  FOR ALL USING (auth.uid() = user_id);
CREATE POLICY "nexusflow_user_isolation" ON nexusflow.contacts
  FOR ALL USING (auth.uid() = user_id);
CREATE POLICY "nexusflow_user_isolation" ON nexusflow.raw_sources
  FOR ALL USING (auth.uid() = user_id);
CREATE POLICY "nexusflow_user_isolation" ON nexusflow.ai_extractions
  FOR ALL USING (auth.uid() = user_id);
CREATE POLICY "nexusflow_user_isolation" ON nexusflow.validation_queue
  FOR ALL USING (auth.uid() = user_id);
CREATE POLICY "nexusflow_user_isolation" ON nexusflow.confirmed_memories
  FOR ALL USING (auth.uid() = user_id);
CREATE POLICY "nexusflow_user_isolation" ON nexusflow.active_signals
  FOR ALL USING (auth.uid() = user_id);
CREATE POLICY "nexusflow_user_isolation" ON nexusflow.interaction_events
  FOR ALL USING (auth.uid() = user_id);
CREATE POLICY "nexusflow_user_isolation" ON nexusflow.action_items
  FOR ALL USING (auth.uid() = user_id);
CREATE POLICY "nexusflow_user_isolation" ON nexusflow.insights
  FOR ALL USING (auth.uid() = user_id);
CREATE POLICY "nexusflow_user_isolation" ON nexusflow.insight_feedback
  FOR ALL USING (auth.uid() = user_id);
CREATE POLICY "nexusflow_user_isolation" ON nexusflow.shared_learning_patterns
  FOR ALL USING (auth.uid() = user_id);
