# PlanFlow 코드베이스 구조 및 의존성 분석

> 분석 일자: 자동 생성 (GLM Worker W02)
> 대상: planflow 프로젝트 — Flutter 앱 (Android/iOS)
> 출처: pubspec.yaml 및 lib/ 디렉터리 트리 실측

---

## 1. 프로젝트 개요

- 프로젝트명: planflow (패키지 com.fluxstudio.planflow)
- description: "PlanFlow Flutter app scaffold."
- 버전: 1.1.1+68
- SDK 제약: Dart >=3.3.0 <4.0.0
- 앱 카테고리: 일정 관리(캘린더) + 음성 입력 + 출발 알림 + 홈위젯 + 네이버/구글 캘린더 동기화
- 백엔드: Supabase(Auth