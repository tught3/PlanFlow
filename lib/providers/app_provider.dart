import 'package:flutter/foundation.dart';

import '../data/models/app_feature.dart';
import '../services/app_service.dart';

class AppProvider extends ChangeNotifier {
  AppProvider(this._service);

  final AppService _service;

  bool _isReady = false;
  List<AppFeature> _features = const [];

  bool get isReady => _isReady;
  List<AppFeature> get features => List.unmodifiable(_features);

  void bootstrap() {
    if (_isReady) {
      return;
    }

    _features = _service.loadHomeFeatures();
    _isReady = true;
    notifyListeners();
  }
}
