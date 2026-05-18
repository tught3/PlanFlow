class AppConstants {
  static const String appName = 'PlanFlow';

  static const double defaultPadding = 16.0;
  static const double sectionSpacing = 12.0;
}

class DbSchema {
  static const String shared = 'shared';
  static const String planflow = 'planflow';
  static const String nexusflow = 'nexusflow';
}

class DbTable {
  static const String userProfiles = 'user_profiles';
  static const String events = 'events';
  static const String preActions = 'pre_actions';
  static const String reminders = 'reminders';
  static const String voiceLogs = 'voice_logs';
  static const String locationHistory = 'location_history';
  static const String userSettings = 'user_settings';
  static const String calendarConnections = 'calendar_connections';
  static const String earlyBirdEmails = 'early_bird_emails';
  static const String userBackups = 'user_backups';
  static const String feedbackReports = 'feedback_reports';
}

class DbFunction {
  static const String restoreUserBackup = 'restore_user_backup';
  static const String submitEarlyBirdEmail = 'submit_early_bird_email';
  static const String upsertNaverCalDavCredentials =
      'upsert_naver_caldav_credentials';
  static const String fetchNaverCalDavCredentials =
      'fetch_naver_caldav_credentials';
  static const String clearNaverCalDavCredentials =
      'clear_naver_caldav_credentials';
}

class AppRoutes {
  static const String root = '/';
  static const String splash = root;
  static const String login = '/login';
  static const String permissionOnboarding = '/permission-onboarding';
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
  static const String briefing = '/briefing';
  static const String naverIcsImport = '/settings/naver-ics-import';
}
