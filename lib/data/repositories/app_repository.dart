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
        description: 'Basic entry point for planning work.',
        route: '/planner',
      ),
      AppFeature(
        title: 'Settings',
        description: 'Space for reviewing and adjusting app state.',
        route: '/settings',
      ),
    ];
  }
}
