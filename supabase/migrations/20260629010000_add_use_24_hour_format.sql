-- 시간 표시 형식 (24시간 여부) 컬럼 추가
ALTER TABLE user_settings
  ADD COLUMN IF NOT EXISTS use_24_hour_format BOOLEAN NOT NULL DEFAULT false;
