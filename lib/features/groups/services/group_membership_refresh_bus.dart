import 'package:flutter/foundation.dart';

/// Process-wide signal for membership changes that affect mounted group views.
class GroupMembershipRefreshBus extends ValueNotifier<int> {
  GroupMembershipRefreshBus._() : super(0);

  static final GroupMembershipRefreshBus instance =
      GroupMembershipRefreshBus._();

  void notifyChanged() => value += 1;
}
