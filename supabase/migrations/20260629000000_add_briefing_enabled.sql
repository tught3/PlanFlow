-- 브리핑 알람 활성화 여부 컬럼 추가
ALTER TABLE user_settings
  ADD COLUMN IF NOT EXISTS briefing_enabled BOOLEAN NOT NULL DEFAULT true;
