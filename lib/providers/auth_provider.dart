import 'package:flutter/foundation.dart';

class AuthProvider extends ChangeNotifier {
  AuthProvider();

  String? _userId;

  String? get userId => _userId;
  bool get isSignedIn => _userId != null;

  void setUser(String? userId) {
    _userId = userId;
    // TODO: Connect this to the real auth flow later.
    notifyListeners();
  }
}
