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
        title: 'Planner',
        description: '일정과 작업을 모아보는 기본 진입점',
        route: '/planner',
      ),
      AppFeature(
        title: 'Settings',
        description: '앱 환경과 계정 상태를 정리하는 공간',
        route: '/settings',
      ),
    ];
  }
}
