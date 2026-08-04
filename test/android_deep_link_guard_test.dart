import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('MainActivity prevents planflow deep links from becoming initial route',
      () {
    final mainActivity = File(
      'android/app/src/main/kotlin/com/fluxstudio/planflow/MainActivity.kt',
    ).readAsStringSync();

    expect(mainActivity, contains('override fun getInitialRoute()'));
    expect(mainActivity, contains('data?.scheme == "planflow"'));
    expect(mainActivity, contains('return "/"'));
    expect(mainActivity, contains('super.getInitialRoute() ?: "/"'));
  });

  test('Flutter deep linking stays disabled for custom planflow scheme', () {
    final manifest =
        File('android/app/src/main/AndroidManifest.xml').readAsStringSync();

    expect(manifest, contains('flutter_deeplinking_enabled'));
    expect(manifest, contains('android:value="false"'));
    expect(manifest, contains('android:scheme="planflow"'));
  });

  test(
      'Group calendar widget deep link clears an existing singleTask '
      'MainActivity to avoid START_TASK_TO_FRONT dropping the intent',
      () {
    final provider = File(
      'android/app/src/main/kotlin/com/fluxstudio/planflow/'
      'PlanFlowGroupCalendarWidgetProvider.kt',
    ).readAsStringSync();

    // 2026-08-04 실기기 로그로 확정: MainActivity가 singleTask이면 프로세스가
    // 죽고 태스크만 Recents에 남은 상태에서 NEW_TASK/SINGLE_TOP만으로는
    // ActivityTaskManager가 START_TASK_TO_FRONT로 처리해 새 인텐트(선택한
    // 날짜)를 폐기한다. CLEAR_TOP이 있어야 대상 액티비티가 강제로 다시
    // 생성되어 onCreate로 새 인텐트가 정상 전달된다.
    expect(provider, contains('buildDeepLinkIntent'));
    expect(provider, contains('Intent.FLAG_ACTIVITY_NEW_TASK'));
    expect(provider, contains('Intent.FLAG_ACTIVITY_SINGLE_TOP'));
    expect(provider, contains('Intent.FLAG_ACTIVITY_CLEAR_TOP'));
  });
}
