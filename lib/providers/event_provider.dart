import 'package:flutter/foundation.dart';

import '../data/models/event_model.dart';
import '../data/repositories/event_repository.dart';

class EventProvider extends ChangeNotifier {
  EventProvider(this._repository);

  final EventRepository _repository;

  bool _isLoading = false;
  List<EventModel> _events = const <EventModel>[];

  bool get isLoading => _isLoading;
  List<EventModel> get events => List.unmodifiable(_events);

  Future<void> load(String userId) async {
    _isLoading = true;
    notifyListeners();

    _events = await _repository.fetchEvents(userId);

    _isLoading = false;
    notifyListeners();
  }
}
