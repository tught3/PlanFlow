# PlanFlow v2 기획 문서

PlanFlow의 2차 확장 기능인 **팀 협업 모드** 기획 및 설계 문서를 관리합니다.

## 📌 핵심 문서

다음 문서들이 V2 설계의 최신 기준입니다:

- **[16-v2-schema-sql-final-draft.md](./16-v2-schema-sql-final-draft.md)** - V2 실제 적용 전 SQL 최종 초안
- **[15-v2-erd-review.md](./15-v2-erd-review.md)** - V2 ERD와 SQL 초안 최종 검수
- **[14-v2-flutter-module-plan.md](./14-v2-flutter-module-plan.md)** - V2 Flutter feature module 구조 설계
- **[13-v2-schema-sql-draft.md](./13-v2-schema-sql-draft.md)** - V2 SQL 초안
- **[10-v2-open-decisions-final.md](./10-v2-open-decisions-final.md)** - ERD 전 미결정사항 최종 확정
- **[09-v2-final-master-design.md](./09-v2-final-master-design.md)** - Group Tree 기반 V2 최종 통합 설계

## 📂 전체 문서 목록

### 설계 문서
- [09-v2-final-master-design.md](./09-v2-final-master-design.md) - Group Tree 기반 최종 통합 설계
- [team-v2-plan.md](./team-v2-plan.md) - 팀 기능 도메인 설계 및 개인/팀 분리 전략

### 데이터베이스 설계
- [16-v2-schema-sql-final-draft.md](./16-v2-schema-sql-final-draft.md) - SQL 최종 초안
- [15-v2-erd-review.md](./15-v2-erd-review.md) - ERD와 SQL 초안 검수
- [13-v2-schema-sql-draft.md](./13-v2-schema-sql-draft.md) - SQL 초안
- [01-team-erd-draft.md](./01-team-erd-draft.md) - 팀 모듈 DB/ERD 초안

### UI/UX 설계
- [14-v2-flutter-module-plan.md](./14-v2-flutter-module-plan.md) - Flutter feature module 구조
- [02-team-screen-flow.md](./02-team-screen-flow.md) - 팀 기능 화면 흐름

### 정책 문서
- [10-v2-open-decisions-final.md](./10-v2-open-decisions-final.md) - 미결정사항 최종 확정
- [03-team-permission-policy.md](./03-team-permission-policy.md) - 팀 권한 정책

## 🎯 설계 원칙

1. **개인 MVP 안정성 보장** - 기존 1차 배포 기능에 영향 없음
2. **모듈 분리** - 팀 기능은 독립된 feature module로 설계
3. **점진적 확장** - 기존 코드와 DB/RLS 구조를 보존하며 확장
