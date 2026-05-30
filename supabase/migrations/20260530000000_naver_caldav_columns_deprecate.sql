-- Migration: Naver CalDAV → Open API(OAuth) 전환
-- 앱 비밀번호 평문 보안 정리 및 컬럼 deprecated 표시.
-- 컬럼 DROP은 다음 릴리스에서 별도 마이그레이션으로 진행.

DO $$
BEGIN
  -- 앱 비밀번호 평문 NULL 처리 (보안)
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name = 'user_settings'
      AND column_name = 'naver_caldav_app_password'
  ) THEN
    UPDATE user_settings SET naver_caldav_app_password = NULL
    WHERE naver_caldav_app_password IS NOT NULL;

    COMMENT ON COLUMN user_settings.naver_caldav_app_password IS
      'DEPRECATED 2026-05-30: replaced by Naver Open API OAuth. Safe to DROP after one release.';
    COMMENT ON COLUMN user_settings.naver_caldav_id IS
      'DEPRECATED 2026-05-30: replaced by Naver Open API OAuth. Safe to DROP after one release.';
  END IF;
END $$;
