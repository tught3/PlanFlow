# PopScope 전역 안전망이 홈 화면 렌더링을 막던 회귀 원인 분석

## 문제 요약
MaterialApp.router의 builder에 PopScope를 추가하여 뒤로가기로 앱 종료되는 문제를 방지하려 했으나, 앱 실행 시 홈 화면이 렌더링되지 않고 빈 회색(흰) 화면만 나타나는 심각한 회귀가 발생했다.

## 타임라인

### 1단계: 원본 문제 (커밋 b2a49ec 이전)
- **증상**: GoRouter 스택이 1개뿐인 상태(canPop()==false)에서 뒤로가기를 누르면 앱 자체가 종료됨
- **원인**: Flutter 기본 동작으로, 네비게이션 스택이 비어있을 때 뒤로가기는 앱 종료를 의미함

### 2단계: 첫 수정 시도 (커밋 b2a49ec, 2026-07-08 08:01)
```dart
// lib/app.dart에 추가된 코드 (간략화)
MaterialApp.router(
  builder: (context, child) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        final currentRoute = GoRouter.of(context).routerDelegate.currentConfiguration.uri.toString();
        if (currentRoute != '/') {
          context.go('/');
        }
      },
      child: child ?? const SizedBox.shrink(),
    );
  },
  // ...
)
```

- **의도**: 홈 화면(`/`)이 아닌 경우 뒤로가기 시 홈으로 이동, 홈에서는 아무것도 안 함
- **결과**: **앱 실행 시 홈 화면이 아예 렌더링되지 않고 빈 회색 화면만 표시됨** (실기기 확인)

### 3단계: 원복 (커밋 d2ea143, 2026-07-08 08:19)
- PopScope 전역 안전망 제거
- 홈 시딩 로직(`_applyPendingHomeWidgetRoute`)은 유지
- flutter clean + 새 release 빌드로 정상 렌더링 재확인

## 근본 원인 (추정)

### 가설 1: PopScope의 canPop: false가 초기 렌더링을 블록
MaterialApp.router의 builder는 **모든 라우트 전환 시마다** 실행된다. 앱 시작 시 초기 라우트(`/`)가 렌더링될 때도 builder가 호출되는데, 이때 PopScope의 `canPop: false`가 Flutter 프레임워크 내부에서 다음과 같은 부작용을 일으켰을 가능성:

1. Flutter는 초기 라우트를 푸시하려 시도
2. PopScope가 "이 화면은 pop될 수 없다"고 선언
3. 프레임워크가 혼란스러워하며 렌더링을 중단하거나 대기 상태로 진입
4. 결과적으로 child 위젯(실제 홈 화면)이 빌드되지 않음

### 가설 2: onPopInvokedWithResult의 조건부 context.go('/')가 무한 루프 유발
초기 라우트가 `/`인 상태에서:
1. builder 실행 → PopScope 생성
2. 어떤 이유로 pop 이벤트가 발생 (초기화 과정 중?)
3. `onPopInvokedWithResult` 콜백 실행
4. `currentRoute != '/'` 검사는 통과하지만, 내부적으로 상태 불일치 발생
5. child가 렌더링되기 전에 라우팅 상태가 꼬임

### 가설 3: builder 내부에서 GoRouter.of(context) 접근이 타이밍 이슈 유발
MaterialApp.router의 builder context에서 `GoRouter.of(context)`를 즉시 접근하는 것이 안전하지 않을 수 있음:
- builder는 위젯 트리 구성 중에 실행됨
- 이 시점에 GoRouter 상태가 완전히 초기화되지 않았을 가능성
- 초기화 전에 currentConfiguration에 접근하면 null 또는 불완전한 상태 반환
- 이로 인해 렌더링 파이프라인이 중단됨

## 재현 조건
- Flutter 앱의 MaterialApp.router builder에 PopScope 추가
- canPop: false 설정
- onPopInvokedWithResult에서 GoRouter.of(context) 사용
- 앱을 새로 실행 (cold start)

## 해결 방법

### 현재 적용된 방법 (커밋 d2ea143)
- **PopScope 전역 안전망 완전 제거**
- 뒤로가기로 앱 종료되는 원본 문제는 미해결 상태로 남음
- 홈 화면 렌더링은 정상 복구됨

### 향후 대안 (추가 조사 필요 시)

#### 대안 1: 개별 화면에 PopScope 추가
```dart
// 각 화면마다 개별적으로 PopScope 래핑
// (MaterialApp.router builder가 아님)
PopScope(
  canPop: false,
  onPopInvokedWithResult: (didPop, result) async {
    if (didPop) return;
    context.go('/');
  },
  child: Scaffold(...),
)
```
- 장점: 전역 builder의 타이밍 이슈 회피
- 단점: 모든 화면에 보일러플레이트 코드 추가 필요

#### 대안 2: BackButtonListener 사용
```dart
BackButtonListener(
  onBackButtonPressed: () async {
    if (GoRouter.of(context).canPop()) {
      GoRouter.of(context).pop();
    } else {
      final currentRoute = GoRouter.of(context).routerDelegate.currentConfiguration.uri.toString();
      if (currentRoute != '/') {
        context.go('/');
        return true;
      }
    }
    return false;
  },
  child: child,
)
```
- 장점: PopScope보다 명시적인 뒤로가기 처리
- 단점: 여전히 builder 내부에서 GoRouter 접근 필요

#### 대안 3: 앱 종료 허용 + 사용자 교육
- 뒤로가기로 앱이 종료되는 것을 정상 동작으로 받아들임
- Android 표준 동작과 일치
- 추가 코드 불필요

## 교훈
1. **MaterialApp.router의 builder는 매우 민감한 영역** - 여기에 복잡한 로직을 추가하면 예상치 못한 부작용 발생 가능
2. **초기 렌더링 중 GoRouter 상태 접근은 위험** - 완전히 초기화되지 않은 상태일 수 있음
3. **PopScope의 canPop: false는 전역에서 사용 시 주의** - 특히 앱 시작 시점의 초기 라우트와 상호작용 가능
4. **실기기 테스트 필수** - 에뮬레이터에서는 재현되지 않을 수 있는 타이밍 이슈

## 관련 커밋
- b2a49ec: 전역 PopScope 안전망 추가 (회귀 발생)
- d2ea143: 전역 PopScope 안전망 제거 (회귀 수정)

## 참고 자료
- Flutter PopScope 공식 문서: https://api.flutter.dev/flutter/widgets/PopScope-class.html
- GoRouter 공식 문서: https://pub.dev/packages/go_router
