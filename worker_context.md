# PlanFlow Worker Context - W01

생성: GLM Worker W01
목적: Claude 분석 스킵 상태에서 GLM 구현 조직이 자체 확보한 프로젝트 context
용도: W02+ 서브태스크 입력 컨텍스트

---

## 1. 프로젝트 개요

이름: PlanFlow
버전: 1.1.0+45
SDK: Dart 3.3.0+ Flutter
플랫폼: Android 우선, iOS 미지원
DB: Supabase PostgreSQL
배포: Supabase
개발자: 엄대용, Flux Studio 1인 개발
도메인: 제약영업 15년 출신, 앱 개발 전향
연락처: 010-2422-3224
경로: E:\FluxStudio\planflow

---

## 2. 코딩 컨벤션

### 공통
- 변수/함수명: 영어 camelCase
- 주석: 한국어 허용
- 인코딩: UTF-8
- 커밋: feat/fix/refactor/docs/chore: 한국어 설명

### Flutter Dart
- 상태관리: Riverpod 전용, Provider 금지
- 네비게이션: GoRouter
- STT: onDevice true 필수, 음성데이터 서버 전송 금지
- 비동기: async/await Future, callback hell 금지
- 위젯: 200줄 초과시 분리

### Supabase
- RLS 항상 활성화
- 직접 SQL 수정 금지, Migration 파일로 관리
- 민감데이터 암호화
- 스키마 변경시 대용님 확인 필수

### UI 디자인
- 기존 스타일/토큰/컴포넌트 우선 재사용
- 색상: PlanFlowColors, primary 1E3A5F
- 폰트: Noto Sans KR
- Material 3
