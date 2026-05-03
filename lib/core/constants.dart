class AppConstants {
  static const String appName = 'PlanFlow';

  static const double defaultPadding = 16.0;
  static const double sectionSpacing = 12.0;
}

class AppRoutes {
  static const String root = '/';
  static const String splash = root;
  static const String login = '/login';
  static const String resetPassword = '/reset-password';
  static const String home = '/home';
  static const String calendar = '/calendar';
  static const String planner = calendar;
  static const String voice = '/voice';
  static const String voiceAction = '/voice/action';
  static const String confirm = '/voice/confirm';
  static const String eventDetail = '/event/detail';
  static const String eventDetailWithId = '/event/detail/:eventId';
  static const String eventEdit = '/event/edit';
  static const String eventEditWithId = '/event/edit/:eventId';
  static const String settings = '/settings';
}
