# PlanFlow UI 업데이트 지시

> ⚠️ 작업 전 반드시 agents.md 먼저 읽고 그대로 따를 것.

---

## 1. 일정 유형 네이밍 변경

일정 확인/등록 화면의 일정 유형 토글 텍스트 변경:

```
변경 전: [단일] [종일] [다일]
변경 후: [하루] [종일] [연속]
```

앱 내 모든 곳에서 동일하게 적용:
- ConfirmScreen
- EventEditScreen
- 달력 뷰
- 홈 탭

---

## 2. 카테고리 변경

### 변경 내용
```
변경 전: 업무 / 개인 / 가족 / 기타
변경 후: 업무 / 개인 / 건강 / 교육 / 기타
```

### 카테고리별 색상
```dart
const categoryColors = {
  '업무': Color(0xFF1A4FD6), // 코발트
  '개인': Color(0xFF1D9E75), // 민트
  '건강': Color(0xFFE07B30), // 오렌지
  '교육': Color(0xFF6B2D8B), // 퍼플
  '기타': Color(0xFF7AB3D4), // 스틸블루
};
```

### 카테고리별 예시 (GPT 파싱 힌트용)
```
업무: 미팅, 영업, 보고, 출장, 거래처 방문
개인: 약속, 취미, 여가, 친구, 가족 모임
건강: 병원, 운동, 검진, 시술, 헬스
교육: 강의, 세미나, 워크샵, 교육, 연수
기타: 분류 안 되는 모든 것
```

### DB 변경
```sql
-- 기존 'family' 카테고리를 'health'로 마이그레이션
update events set category = 'health' where category = 'family';

-- category 컬럼 체크 제약 업데이트
alter table events drop constraint if exists events_category_check;
alter table events add constraint events_category_check
  check (category in ('work', 'personal', 'health', 'education', 'etc'));
```

### GPT 파싱 프롬프트 업데이트
일정 파싱 시 카테고리 자동 추론:
```
"병원 진료" → category: "health"
"JW제약 미팅" → category: "work"
"헬스장" → category: "health"
"세미나 참석" → category: "education"
"친구 약속" → category: "personal"
카테고리 불분명 → category: "etc"
```

---

## 3. 반복 일정 세분화

### 반복 옵션 구조

```
반복 안 함

매일

매주
└── 요일 선택 (복수 선택 가능)
    ☑ 월  ☐ 화  ☑ 수  ☐ 목  ☑ 금  ☐ 토  ☐ 일
    예) 매주 월, 수, 금

매월
└── 방식 선택:
    ① 날짜 기준: 매월 N일
       예) 매월 3일, 매월 15일
    ② 요일 기준: 매월 N번째 X요일
       예) 매월 첫 번째 월요일
           매월 마지막 금요일
           매월 두 번째 목요일

매년
└── N월 N일마다
    예) 매년 5월 1일

사용자 지정
└── N [일/주/월/년] 마다
    예) 2주마다, 3개월마다, 격주
```

### 종료 조건
```
종료: [없음 (계속)] [N회 반복] [종료일 지정]
```

### DB 변경
```sql
-- events 테이블에 반복 관련 컬럼 추가
alter table events
  add column recurrence_rule text,        -- iCal RRULE 형식
  add column recurrence_end_date date,    -- 종료일
  add column recurrence_count integer,    -- 반복 횟수
  add column recurrence_parent_id uuid references events(id);
  -- recurrence_parent_id: 반복 시리즈의 원본 일정 ID
```

### RRULE 예시
```
매주 월, 수, 금: FREQ=WEEKLY;BYDAY=MO,WE,FR
매월 3일: FREQ=MONTHLY;BYMONTHDAY=3
매월 첫 번째 월요일: FREQ=MONTHLY;BYDAY=1MO
매월 마지막 금요일: FREQ=MONTHLY;BYDAY=-1FR
매년 5월 1일: FREQ=YEARLY;BYMONTH=5;BYMONTHDAY=1
2주마다: FREQ=WEEKLY;INTERVAL=2
3개월마다: FREQ=MONTHLY;INTERVAL=3
10회 반복: RRULE:FREQ=WEEKLY;COUNT=10
2027년 12월 31일까지: RRULE:FREQ=WEEKLY;UNTIL=20271231
```

### 반복 일정 수정 UI
반복 일정 수정/삭제 시 선택 모달:
```
┌─────────────────────────────┐
│ 반복 일정을 수정할까요?       │
│                             │
│ [이 일정만]                  │
│ [이 일정 및 이후 일정]        │
│ [모든 반복 일정]             │
└─────────────────────────────┘
```

### 음성 파싱 지원
GPT 프롬프트에 반복 표현 추가:
```
"매주 화요일 오전 10시 팀 미팅"
→ recurrence_rule: "FREQ=WEEKLY;BYDAY=TU"

"매월 첫 번째 월요일 월간 보고"
→ recurrence_rule: "FREQ=MONTHLY;BYDAY=1MO"

"격주 금요일 영업 미팅"
→ recurrence_rule: "FREQ=WEEKLY;INTERVAL=2;BYDAY=FR"

"매월 15일 급여일"
→ recurrence_rule: "FREQ=MONTHLY;BYMONTHDAY=15"
```

### ConfirmScreen UI
반복 설정 섹션:
```
반복
[반복 안 함 ▼]  ← 탭하면 바텀시트로 선택

반복 선택 후:
[매주 ▼]  [월, 수, 금 ▼]  종료: [없음 ▼]
```

---

## ✅ 테스트 케이스

```
[ ] 1. 일정 유형 토글 "하루/종일/연속" 표시 확인
[ ] 2. 카테고리 "업무/개인/건강/교육/기타" 표시 확인
[ ] 3. 각 카테고리 색상 달력/홈에서 올바르게 표시 확인
[ ] 4. "병원 진료" → 카테고리 자동으로 "건강" 추론 확인
[ ] 5. "매주 화요일 팀 미팅" 음성 입력 → 반복 일정 생성 확인
[ ] 6. "매월 첫 번째 월요일" 반복 설정 UI 동작 확인
[ ] 7. 반복 일정 수정 시 "이 일정만/이후/전체" 선택 모달 확인
[ ] 8. 반복 종료일 설정 후 해당 날짜 이후 일정 생성 안 됨 확인
[ ] 9. 격주 반복 일정 달력에 올바르게 표시 확인
[ ] 10. 기존 "가족" 카테고리 → "건강"으로 마이그레이션 확인
```
