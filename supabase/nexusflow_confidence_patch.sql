-- ai_extractions 항목별 confidence 컬럼 추가
ALTER TABLE nexusflow.ai_extractions
ADD COLUMN IF NOT EXISTS account_confidence FLOAT,
ADD COLUMN IF NOT EXISTS contact_confidence FLOAT,
ADD COLUMN IF NOT EXISTS product_confidence FLOAT,
ADD COLUMN IF NOT EXISTS schedule_confidence FLOAT,
ADD COLUMN IF NOT EXISTS action_confidence FLOAT,
ADD COLUMN IF NOT EXISTS signal_confidence FLOAT;

-- confidence 기준값 상수 테이블
CREATE TABLE IF NOT EXISTS nexusflow.confidence_thresholds (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  field_type TEXT NOT NULL UNIQUE,
  high_threshold FLOAT NOT NULL,
  mid_threshold FLOAT NOT NULL,
  weight FLOAT NOT NULL DEFAULT 1.0,
  description TEXT,
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
);

INSERT INTO nexusflow.confidence_thresholds
(field_type, high_threshold, mid_threshold, weight, description) VALUES
('overall',  0.80, 0.55, 1.0, '종합 점수 기준'),
('account',  0.85, 0.55, 2.0, '거래처명 - 핵심 식별자'),
('contact',  0.85, 0.55, 2.0, '담당자명 - 핵심 식별자'),
('product',  0.80, 0.55, 1.5, '제품명'),
('schedule', 0.75, 0.50, 1.5, '일정'),
('action',   0.70, 0.50, 1.0, '액션아이템'),
('signal',   0.65, 0.45, 0.8, '관계신호 - 애매해도 저장 우선');

ALTER TABLE nexusflow.confidence_thresholds
ENABLE ROW LEVEL SECURITY;
