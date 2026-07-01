import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:planflow/core/constants.dart';
import 'package:planflow/core/router.dart';

void main() {
  // 회귀: `/groups/invites` 같은 2세그먼트 정적 경로가 파라미터 경로
  // `/groups/:groupId`(그룹 상세)보다 먼저 선언되어야 GoRouter가 정적 경로로
  // 매칭한다. 순서가 뒤바뀌면 그룹 목록의 '초대 관리' 버튼이 groupId="invites"인
  // 그룹 상세로 잘못 열려 빈/깨진 화면이 된다(사용자 보고: "아무것도 안 됨").
  test('정적 /groups/* 경로는 /groups/:groupId 보다 먼저 선언되어야 한다', () {
    final paths = appRouter.configuration.routes
        .whereType<GoRoute>()
        .map((route) => route.path)
        .toList();

    final detailIndex = paths.indexOf(AppRoutes.groupDetail);
    expect(detailIndex, isNonNegative,
        reason: '${AppRoutes.groupDetail} 라우트가 등록되어 있어야 한다');

    for (final staticPath in <String>[
      AppRoutes.groupInvites,
      AppRoutes.groupMembers,
      AppRoutes.groupEvents,
      AppRoutes.groupDashboard,
    ]) {
      final index = paths.indexOf(staticPath);
      expect(index, isNonNegative, reason: '$staticPath 라우트가 등록되어 있어야 한다');
      expect(
        index,
        lessThan(detailIndex),
        reason: '$staticPath 는 ${AppRoutes.groupDetail} 보다 먼저 선언되어야 '
            'GoRouter가 정적 경로로 매칭한다',
      );
    }
  });
}
