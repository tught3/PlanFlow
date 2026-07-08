# PlanFlow V2 기획 문서

> PlanFlow 2차 확장(팀 기능)의 설계 및 기획 문서 모음

## 📌 핵심 문서 (읽는 순서)

최신 설계 기준부터 순서대로 읽으세요:

1. **[09-v2-final-master-design.md](./09-v2-final-master-design.md)** - Group Tree 기반 V2 최종 통합 설계 (전체 구조의 출발점)
2. **[10-v2-open-decisions-final.md](./10-v2-open-decisions-final.md)** - ERD 설계 전 미결정사항 최종 확정
3. **[15-v2-erd-review.md](./15-v2-erd-review.md)** - V2 ERD 및 SQL 초안 최종 검수
4. **[16-v2-schema-sql-final-draft.md](./16-v2-schema-sql-final-draft.md)** - 실제 적용 전 SQL 최종 초안 (구현 기준)
5. **[14-v2-flutter-module-plan.md](./14-v2-flutter-module-plan.md)** - Flutter feature module 구조 설계

## 📂 전체 문서 목록

### 설계 기준 문서
- [09-v2-final-master-design.md](./09-v2-final-master-design.md) - 최종 통합 설계 기준
- [10-v2-open-decisions-final.md](./10-v2-open-decisions-final.md) - 미결정사항 확정
- [15-v2-erd-review.md](./15-v2-erd-review.md) - ERD 및 SQL 검수
- [16-v2-schema-sql-final-draft.md](./16-v2-schema-sql-final-draft.md) - SQL 최종 초안 (⭐ 구현 기준)

### 구현 계획 문서
- [14-v2-flutter-module-plan.md](./14-v2-flutter-module-plan.md) - Flutter 모듈 구조
- [13-v2-schema-sql-draft.md](./13-v2-schema-sql-draft.md) - SQL 초안 (참고용)

### 초기 기획 문서
- [team-v2-plan.md](./team-v2-plan.md) - 팀 기능 도메인 설계 및 데이터 모델 초안
- [01-team-erd-draft.md](./01-team-erd-draft.md) - 팀 모듈 DB/ERD 초안
- [02-team-screen-flow.md](./02-team-screen-flow.md) - 팀 기능 화면 흐름 초안
- [03-team-permission-policy.md](./03-team-permission-policy.md) - 팀 권한 정책 초안

## 🎯 설계 원칙

- ✅ **개인 MVP 무영향**: 1차 배포 코드 및 DB/RLS 구조는 변경하지 않음
- ✅ **모듈 독립성**: 팀 기능은 별도 feature module로 분리 설계
- ✅ **점진적 확장**: 개인 기능 안정화를 유지하면서 팀 기능 추가
