# PlanFlow v2 기획 문서

PlanFlow 2차 확장(팀 협업 기능) 설계 문서를 모아둔 폴더입니다.

## 핵심 문서 (읽기 순서)

1. [09-v2-final-master-design.md](./09-v2-final-master-design.md) - **Group Tree 기반 V2 최종 통합 설계** (기준 문서)
2. [10-v2-open-decisions-final.md](./10-v2-open-decisions-final.md) - 미결정사항 최종 확정
3. [14-v2-flutter-module-plan.md](./14-v2-flutter-module-plan.md) - Flutter feature module 구조 설계
4. [15-v2-erd-review.md](./15-v2-erd-review.md) - ERD와 SQL 초안 최종 검수
5. [16-v2-schema-sql-final-draft.md](./16-v2-schema-sql-final-draft.md) - **실제 적용 전 SQL 최종 초안**

## 초기 기획 문서

- [team-v2-plan.md](./team-v2-plan.md) - 팀 기능 도메인 설계, 데이터 모델 초안
- [01-team-erd-draft.md](./01-team-erd-draft.md) - 팀 모듈 DB/ERD 초안
- [02-team-screen-flow.md](./02-team-screen-flow.md) - 팀 기능 화면 흐름 초안
- [03-team-permission-policy.md](./03-team-permission-policy.md) - 팀 권한 정책 초안
- [13-v2-schema-sql-draft.md](./13-v2-schema-sql-draft.md) - SQL 초안 (15, 16번 문서로 대체됨)

## 설계 원칙

- **개인 MVP는 변경하지 않음** - 기존 1차 배포 코드 유지
- **팀 기능은 독립 모듈** - 개인/팀 분리 설계
- **DB/RLS 영향 최소화** - 1차 배포 스키마 보존
