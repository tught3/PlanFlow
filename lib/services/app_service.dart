import '../data/models/app_feature.dart';
import '../data/repositories/app_repository.dart';

class AppService {
  const AppService(this._repository);

  final AppRepository _repository;

  List<AppFeature> loadHomeFeatures() => _repository.getHomeFeatures();
}
