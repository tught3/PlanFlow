import '../models/app_feature.dart';

abstract class AppRepository {
  List<AppFeature> getHomeFeatures();
}

class InMemoryAppRepository implements AppRepository {
  const InMemoryAppRepository();

  @override
  List<AppFeature> getHomeFeatures() {
    return const [
      AppFeature(
        title: '일정 관리',
        description: '오늘의 일정과 준비할 일을 확인합니다.',
        route: '/planner',
      ),
      AppFeature(
        title: '설정',
        description: '앱 상태와 계정 설정을 확인합니다.',
        route: '/settings',
      ),
    ];
  }
}
