ALTER TABLE public.events
ADD COLUMN IF NOT EXISTS overridden_occurrence_date timestamptz NULL;

COMMENT ON COLUMN public.events.overridden_occurrence_date IS
'반복 일정에서 특정 회차만 분리해 수정한(단일 예외) 이벤트가, 원래 어느 날짜의 회차를 대체하는지 기록한다. 이 값으로 캘린더/위젯 확장 로직이 원본 회차를 화면에서 숨긴다. NULL이면 예외 이벤트가 아니다.';;
