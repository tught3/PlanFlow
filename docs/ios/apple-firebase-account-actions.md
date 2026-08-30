# Apple·Firebase Phase 4 계정 작업

저장소의 canonical identity는 다음과 같다. 임의로 다른 값을 만들지 않는다.

| 항목 | 값 |
|---|---|
| Firebase project | `planflow-27fd8` |
| Runner Bundle ID | `com.planflow.app` |
| Widget Bundle ID | `com.planflow.app.PlanFlowWidget` |
| App Group | `group.com.planflow.app` |
| URL scheme | `planflow` |

## Firebase에서 할 일

1. Firebase Console의 `planflow-27fd8` 프로젝트에서 iOS 앱을 추가한다.
2. Bundle ID에 `com.planflow.app`을 입력한다.
3. `GoogleService-Info.plist`를 다운로드한다.
4. 파일을 `ios/Runner/GoogleService-Info.plist`에 둔다. 기존 Android 설정이나 Dart 옵션을 덮어쓰지 않는다.

CI를 사용할 때는 plist 내용을 직접 커밋하지 말고, 로컬에서 base64로 인코딩한 값을
GitHub Actions repository secret `PLANFLOW_IOS_GOOGLE_SERVICE_INFO_PLIST_BASE64`에
저장한다. 워크플로가 실행 중 `ios/Runner/GoogleService-Info.plist`를 임시 생성하며,
검증 오류와 빌드 로그에는 plist 내용이나 API 키를 출력하지 않는다.

CI의 `scripts/verify-ios-firebase-config.sh`가 plist XML 형식, 프로젝트, Bundle ID,
iOS App ID 형식을 검사한다. 불일치하거나 파일이 없으면 `BLOCKED_FIREBASE_CONFIG`로
실패하며 키와 전체 plist 내용은 로그에 출력하지 않는다. 실제 plist는 Git에 커밋하지 않는다.

## Apple Developer에서 할 일

1. App ID `com.planflow.app`을 확인하거나 등록한다.
2. Extension App ID `com.planflow.app.PlanFlowWidget`을 확인하거나 등록한다.
3. App Group `group.com.planflow.app`을 확인하거나 등록한다.
4. Runner와 Widget Extension 양쪽에 해당 App Group을 연결한다.
5. 현재 entitlements에 없는 Push Notifications, Background Modes, Sign in with Apple,
   Associated Domains는 기능·심사 요구가 확인되기 전까지 추가하지 않는다.

이 작업은 Apple 계정 권한이 필요하므로 `ACCOUNT_ACTION_REQUIRED_APPLE`이다. 계정 설정이
끝나도 macOS unsigned 빌드와 실제 iPhone 검증은 별도 게이트다.
