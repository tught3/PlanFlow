import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:flutter/widgets.dart';

/// 말하기 연습 중에는 안내 말풍선이 음성 원문을 가리지 않도록 잠시 숨긴다.
///
/// 사용자가 실제로 말하는 동안 무엇이 인식되고 지워지는지 확인할 수 있어야
/// 하므로, 인식이 진행되는 동안에만 true 가 된다.
final ValueNotifier<bool> guideListeningBubbleHidden =
    ValueNotifier<bool>(false);

/// 저장 화면(일정 생성) 안내 단계.
///
/// 사용자는 실제 화면에서 `중요한 일정` → `강한 알림` → `일정 저장` 순서로
/// 눌러야 하므로, 단계마다 강조(구멍) 대상이 달라져야 한다.
enum GuideSaveStage {
  /// '중요한 일정으로 표시' 체크박스.
  important,

  /// '강한 알람' 스위치.
  strong,

  /// '일정 저장' 버튼.
  save,
}

/// 현재 저장 화면 안내 단계.
///
/// 실제 편집기의 토글을 누를 때마다 다음 단계로 이동한다.
final ValueNotifier<GuideSaveStage> guideSaveStage =
    ValueNotifier<GuideSaveStage>(GuideSaveStage.important);

/// 저장 화면 안내가 실제로 화면에 떠 있는지 여부.
///
/// 편집기는 이 값이 true인 동안에만 안내 단계를 직접 진행시킨다.
/// 안내 밖에서 일반 편집기를 조작해도 단계가 넘어가면 안 된다.
final ValueNotifier<bool> guideSaveStageActive = ValueNotifier<bool>(false);

/// ConfirmScreen guide remains hidden until parsing is complete and the user
/// scrolls.
///
/// [guideConfirmReady] 는 AI 파싱과 하이드레이션이 끝났을 때만 true 다.
/// 그전에는 편집기 화면이 흐려진 상태라 안내(배너·구멍·어두운 영역)이
/// 화면을 가리면 안 된다.
///
/// [guideConfirmUserScrolled] 는 사용자가 저장 화면 목록을 직접 스크롤했을
/// 때만 true 다. 프로그램이 대신 스크롤해서는 안 되므로, 스크롤 알림은
/// 사용자의 드래그에서만 발생한다.
final ValueNotifier<bool> guideConfirmUserScrolled = ValueNotifier<bool>(false);
final ValueNotifier<bool> guideConfirmReady = ValueNotifier<bool>(false);

/// 저장 단계 스포트라이트(배너·구멍·어두운 영역)를 화면에 띄워도 되는 상태인가.
///
/// 1) 파싱과 하이드레이션이 끝났고,
/// 2) 사용자가 직접 스크롤했을 때만 true 다.
///
/// 안내가 대신 화면을 스크롤하지 않으므로, 두 조건을 모두 만족해야 실제
/// 대상이 화면에 보이는 스포트라이트가 그려진다.
bool guideConfirmSpotlightEligible({
  required bool ready,
  required bool userScrolled,
}) =>
    ready && userScrolled;

/// 스크롤 알림을 확인해 '사용자가 직접 스크롤했다'는 사실을 기록한다.
///
/// `UserScrollNotification` 은 사용자가 화면을 끌 때만 발생한다. 프로그램이
/// `ensureVisible`/`animateTo` 로 대신 스크롤해도 이 값은 바뀌지 않는다.
///
/// 반환값은 항상 false 다. 이 리스너는 스크롤을 소비하지 않는다.
bool guideHandleUserScrollNotification(ScrollNotification notification) {
  if (guideConfirmReady.value &&
      notification.depth == 0 &&
      notification.metrics.axis == Axis.vertical &&
      notification is UserScrollNotification &&
      notification.direction == ScrollDirection.reverse) {
    if (!guideConfirmUserScrolled.value) {
      guideConfirmUserScrolled.value = true;
    }
  }
  return false;
}
