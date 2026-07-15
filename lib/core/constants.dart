class AppConstants {
  static const String appName = 'PlanFlow';

  static const double defaultPadding = 16.0;
  static const double sectionSpacing = 12.0;
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
  static const String voiceLauncher = '/voice/launcher';
  static const String voiceConversation = '/voice/conversation';
  static const String voiceAction = '/voice/action';
  static const String confirm = '/voice/confirm';
  static const String eventDetail = '/event/detail';
  static const String eventDetailWithId = '/event/detail/:eventId';
  static const String eventEdit = '/event/edit';
  static const String eventEditWithId = '/event/edit/:eventId';
  static const String groups = '/groups';
  static const String groupCreate = '/groups/create';
  static const String groupInvites = '/groups/invites';
  static const String groupInviteLink = '/groups/invite-link';
  static const String groupMembers = '/groups/members';
  static const String groupEvents = '/groups/events';
  static const String groupDashboard = '/groups/dashboard';
  static const String groupDetail = '/groups/:groupId';
  static String groupDetailForId(String id) => '/groups/$id';
  static const String groupEventCreate = '/groups/events/create';
  static const String groupInvitesForGroup = '/groups/:groupId/invites';
  static const String groupMembersForGroup = '/groups/:groupId/members';
  static const String groupEventsForGroup = '/groups/:groupId/events';
  static const String groupDashboardForGroup = '/groups/:groupId/dashboard';
  static const String groupEventCreateForGroup =
      '/groups/:groupId/events/create';
  static String groupInvitesForId(String id) => '/groups/$id/invites';
  static String groupMembersForId(String id) => '/groups/$id/members';
  static String groupEventsForId(String id) => '/groups/$id/events';
  static String groupDashboardForId(String id) => '/groups/$id/dashboard';
  static String groupEventCreateForId(String id) => '/groups/$id/events/create';
  static String groupInviteLinkFor({
    required String groupId,
    required String token,
  }) =>
      '$groupInviteLink?groupId=${Uri.encodeQueryComponent(groupId)}'
      '&token=${Uri.encodeQueryComponent(token)}';
  static const String groupEventDetail = '/groups/events/:eventId';
  static const String settings = '/settings';
  static const String briefing = '/briefing';
  static const String naverIcsImport = '/settings/naver-ics-import';
  static const String adminTesters = '/admin/testers';
  static const String departureAlarm = '/departure-alarm';
}
