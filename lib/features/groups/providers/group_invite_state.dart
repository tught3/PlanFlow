import '../models/group_invite_model.dart';

class GroupInviteState {
  const GroupInviteState({
    required this.pendingInvites,
    required this.isLoading,
    required this.isSubmitting,
    this.currentInviteCode,
    this.currentDisplayName,
    this.error,
    this.message,
  });

  const GroupInviteState.initial()
      : pendingInvites = const <GroupInviteModel>[],
        currentInviteCode = null,
        currentDisplayName = null,
        isLoading = false,
        isSubmitting = false,
        error = null,
        message = null;

  final List<GroupInviteModel> pendingInvites;
  final String? currentInviteCode;
  final String? currentDisplayName;
  final bool isLoading;
  final bool isSubmitting;
  final String? error;
  final String? message;

  bool get hasPendingInvites => pendingInvites.isNotEmpty;

  bool get hasInviteCode => (currentInviteCode?.trim().isNotEmpty ?? false);

  GroupInviteState copyWith({
    List<GroupInviteModel>? pendingInvites,
    String? currentInviteCode,
    bool clearCurrentInviteCode = false,
    String? currentDisplayName,
    bool clearCurrentDisplayName = false,
    bool? isLoading,
    bool? isSubmitting,
    String? error,
    bool clearError = false,
    String? message,
    bool clearMessage = false,
  }) {
    return GroupInviteState(
      pendingInvites: pendingInvites ?? this.pendingInvites,
      currentInviteCode: clearCurrentInviteCode
          ? null
          : currentInviteCode ?? this.currentInviteCode,
      currentDisplayName: clearCurrentDisplayName
          ? null
          : currentDisplayName ?? this.currentDisplayName,
      isLoading: isLoading ?? this.isLoading,
      isSubmitting: isSubmitting ?? this.isSubmitting,
      error: clearError ? null : error ?? this.error,
      message: clearMessage ? null : message ?? this.message,
    );
  }
}
