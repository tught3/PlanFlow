# CLAUDE.md — C:\PlanFlow
> **이 파일은 모든 Claude 세션의 0순위 규칙이다. AGENTS.md보다 우선한다.**
> 응답은 항상 **한국어**로 한다. 영어 응답 금지.

---

## 🔥 0순위 — 모델·에이전트 분업 (예외 없이 항상 적용)

**사용자가 매번 다시 말하게 만들지 않는다. 이 규칙은 모든 작업에 자동 적용된다.**

| 역할 | 모델 | 설명 |
|------|------|------|
| 계획 · 진단 · 검토 결정 | `claude-opus-4-5` | 구조 해석, 이슈 분해, 계획 수립 |
| 고위험 실행 · 검토 | `claude-sonnet-4-5` | 음성파싱, 캘린더동기화, auth, Supabase, 타임존, 알림, 광범위 리팩터링 |
| 일반 실행 · 검토 | `claude-sonnet-4-5` | UI 변경, 버그픽스, 테스트, 문서 |
| 단순·기계적 작업 | `claude-haiku-3-5` | 파일명 변경, 포맷, 상수 수정, 1~2줄 오타 수정 |

**고위험 영역** (반드시 `claude-sonnet-4-5` 사용):
- `voice_command_router.dart`, `voice_text_cleanup_service.dart`, `voice_action_screen.dart`
- `calendar_auto_sync_service.dart`, `event_repository.dart`
- 인증 관련 서비스 전체
- `supabase/schema.sql`, `supabase/migrations/`
- `local_time.dart`, 이벤트 파싱 로직 (타임존·날짜 계산)
- 알림 스케줄링
- 릴리스·서명 설정
- 5개 이상 파일을 동시에 수정하는 광범위 리팩터링

---

## 🔴 핵심 워크플로우 (이슈 2개 이상 또는 멀티 서브시스템 작업 시 필수)

```
사용자 지시
  ↓
[1] 컨텍스트 압축 (작업 진입 전 필수)
    → .planning/STATE.md 확인
    → .planning/context/ACTIVE_SUMMARY.md 확인
    → node scripts/gsd-context-hygiene.mjs 실행 (없으면 없다고 기록하고 계속)

  ↓
[2] claude-opus-4-5 가 계획 수립
    → 이슈 분해 + 파일 스코프 매핑 + 테스트 전략
    → 수정 방향 확정 후 실행 진입

  ↓
[3] 워커 서브에이전트 병렬 실행
    → 파일 스코프가 겹치지 않으면 동시에 실행
    → 각 워커는 세션 기억 없는 자립적 프롬프트로 실행
    → 결과 보고 → 오케스트레이터가 통합

  ↓
[4] 리뷰어 에이전트 (claude-sonnet-4-5) 독립 검증
    → 계획 대비 실행 결과 100% 검토
    → NEEDS-FIX → 구현 측에 재의뢰 후 재검증 (같은 리뷰어에 반복 질문 금지)
    → PASS 날 때까지 [3]→[4] 루프

  ↓
[5] 완료 기준 전체 충족 후에만 완료 보고
```

- 이슈 1개, 단순 수정 → 위 절차 생략하고 바로 진행 가능
- **리뷰어 PASS 전 "완료" 표현 절대 금지**
- 사용자 질문이 코드 작업과 함께 있으면 **두 가지 모두 답변** (질문 무시 금지)

---

## ✅ 완료 기준 (모두 충족해야 완료 보고 가능)

1. **리뷰어 에이전트 승인**
2. **빌드 통과** → `scripts/flutter-local.ps1 build apk --debug` (래퍼 없으면 `flutter build apk --debug`)
3. **설치** → `adb install -r build/app/outputs/flutter-apk/app-debug.apk`
4. **실행 확인** → `adb shell am start -n com.planflow.app/.MainActivity` + `adb shell pidof com.planflow.app`
5. **커밋** → 설명적인 커밋 메시지
6. **푸시** → 원격 저장소 반영
7. 기기 미연결 시: 사유 명시 후 빌드·푸시까지만 완료

> 순서: **리뷰어 승인 → 빌드 → 설치 → 실행 → 테스트 → 커밋 → 푸시**

---

## 🟡 세션 시작 필수 (컨텍스트 압축)

모든 작업 시작 전, 긴 작업 진입 전, 최종 보고 직전에 실행:

```bash
# 1. 상태 파일 확인
cat .planning/STATE.md
cat .planning/context/ACTIVE_SUMMARY.md

# 2. 컨텍스트 위생 스크립트 실행
node scripts/gsd-context-hygiene.mjs
# 없으면 → "스크립트 없음, 계속 진행" 기록하고 진행
```

작업 완료 후 `.planning/context/ACTIVE_SUMMARY.md`에 간단한 체크포인트 기록.

---

## 🔀 워커 병렬 실행 규칙

- **파일 스코프가 겹치지 않으면** 워커를 동시에 실행
- 각 워커 프롬프트에 반드시 포함:
  1. 수정 목적과 배경 (세션 기억 없으므로 자립적으로 작성)
  2. 정확한 파일 경로와 변경할 코드 위치
  3. 원하는 결과물의 구체적 명세
  4. "이 파일 외에는 절대 수정하지 말 것" 스코프 제한
- 결과 보고 → 오케스트레이터(메인) 통합 → 리뷰어 전달

---

## 📋 리뷰어 체크리스트

리뷰어 에이전트는 다음을 **전부** 확인해야 PASS 가능:

- [ ] 변경된 모든 파일이 오류 없이 컴파일되는가
- [ ] 구현 로직이 원래 계획의 의도와 100% 일치하는가
- [ ] 관련 없는 파일이 수정되지 않았는가
- [ ] 알려진 갭·잔여 이슈가 명시적으로 보고되었는가
- [ ] 빌드 통과 (`scripts/flutter-local.ps1 build apk --debug`)
- [ ] 고위험 영역 수정 시 로직 정확성 이중 확인
- [ ] 테스트 코드 임의 수정·삭제 없음

---

## 📁 저장소 특이사항

- **작업 기준 디렉터리**: `C:\PlanFlow`
- `E:\Project\PlanFlow` — 읽기 전용 참조 소스 (수정 금지)
- `G:\AI-automatic-expense-tracker` — 참조 전용 (수정 금지)
- `lite-app/` — 읽기 전용 (수정 금지)
- Flutter 빌드·실행 → **항상 `scripts/flutter-local.ps1` 래퍼 사용** (`env/local.json` + `--dart-define` 자동 주입)
- ADB 명령어는 **`com.planflow.app`만 대상**으로 한다 (다른 앱 패키지 건드리지 말 것)
- 음성 파일은 외부 서버로 전송 금지. STT 텍스트만 저장·전송
- `speech_to_text`는 `SpeechListenOptions(onDevice: true)` 필수
- ADB 화면이 검은 경우 → 기기 화면 켜달라고 요청 후 진행

---

## 🔒 변경 금지 사항

- 사용자가 명시적으로 요청하지 않은 한 테스트 코드 수정·삭제 금지
- 요청 스코프 밖의 추가 변경 금지 (알고 있으면 "Known Gaps"로 보고)
- `--no-verify`, `--no-gpg-sign` 등 훅 우회 금지
- `git push --force` to main/master 금지
- ADB 와일드카드·광범위 패키지 삭제 명령 금지

---

## 🗂 상세 규칙 참조

- `AGENTS.md` — 저장소 전체 운영 규칙 (배포 구조, 제품 스코프 등)
- `docs/agent-rules-workflow.md` — 워크플로우 세부
- `docs/agent-rules-validation.md` — 검증 세부
- `docs/agent-rules-operations.md` — 운영 세부
