# Apple·Firebase Phase 4 계정 설정 기록

저장소의 canonical identity는 다음과 같다. 임의로 다른 값을 만들지 않는다.

| 항목 | 값 |
|---|---|
| Firebase project | `planflow-27fd8` |
| Runner Bundle ID | `com.fluxstudio.planflow` |
| Widget Bundle ID | `com.fluxstudio.planflow.PlanFlowWidget` |
| App Group | `group.com.fluxstudio.planflow` |
| URL scheme | `planflow` |

## Firebase 설정 확인

사용자 제공 설정 기준으로 Firebase 프로젝트 `planflow-27fd8`의 iOS 앱 Bundle ID는
`com.fluxstudio.planflow`로 확정됐다. 로컬 `GoogleService-Info.plist`는 검증용으로만 두고
Git에는 포함하지 않는다.

CI를 사용할 때는 plist 내용을 직접 커밋하지 말고, 로컬에서 base64로 인코딩한 값을
GitHub Actions repository secret `PLANFLOW_IOS_GOOGLE_SERVICE_INFO_PLIST_BASE64`에
저장한다. 워크플로가 실행 중 `ios/Runner/GoogleService-Info.plist`를 임시 생성하며,
검증 오류와 빌드 로그에는 plist 내용이나 API 키를 출력하지 않는다.

CI의 `scripts/verify-ios-firebase-config.sh`가 plist XML 형식, 프로젝트, Bundle ID,
iOS App ID 형식을 검사한다. 불일치하거나 파일이 없으면 `BLOCKED_FIREBASE_CONFIG`로
실패하며 키와 전체 plist 내용은 로그에 출력하지 않는다. 실제 plist는 Git에 커밋하지 않는다.

## Apple Developer 설정 확인

1. App ID `com.fluxstudio.planflow`이 등록됐다.
2. Extension App ID `com.fluxstudio.planflow.PlanFlowWidget`이 등록됐다.
3. App Group `group.com.fluxstudio.planflow`이 등록됐다.
4. Runner와 Widget Extension 양쪽에 해당 App Group이 연결됐다.
5. 현재 entitlements에 없는 Push Notifications, Background Modes, Sign in with Apple,
   Associated Domains는 기능·심사 요구가 확인되기 전까지 추가하지 않는다.

계정 설정은 완료 기준으로 기록했지만 macOS unsigned 빌드와 실제 iPhone 검증은 별도
게이트다.
