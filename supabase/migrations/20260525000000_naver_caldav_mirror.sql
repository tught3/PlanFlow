DO $$
DECLARE
  target_table regclass;
  found_table boolean := false;
BEGIN
  FOREACH target_table IN ARRAY ARRAY[
    to_regclass('public.user_settings'),
    to_regclass('planflow.user_settings')
  ]
  LOOP
    IF target_table IS NULL THEN
      CONTINUE;
    END IF;

    found_table := true;
    EXECUTE format(
      'ALTER TABLE %s ADD COLUMN IF NOT EXISTS naver_caldav_id TEXT',
      target_table
    );
    EXECUTE format(
      'ALTER TABLE %s ADD COLUMN IF NOT EXISTS naver_caldav_app_password TEXT',
      target_table
    );
  END LOOP;

  IF NOT found_table THEN
    RAISE EXCEPTION 'user_settings table not found in public or planflow schema';
  END IF;
END
$$;

-- RLS는 기존 user_settings 정책을 그대로 상속합니다.
-- 별도 정책 추가는 필요하지 않습니다. 기존 user_id = auth.uid() 정책이 신규 컬럼까지 보호합니다.
