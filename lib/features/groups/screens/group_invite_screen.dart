import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../../core/theme.dart';
import '../../../providers/auth_provider.dart';
import '../models/group_invite_model.dart';
import '../models/group_model.dart';
import '../providers/group_context_provider.dart';
import '../providers/group_context_state.dart';
import '../providers/group_invite_provider.dart';
import '../providers/group_invite_state.dart';

class GroupInviteScreen extends StatefulWidget {
  const GroupInviteScreen({
    super.key,
    GroupContextProvider? contextProvider,
    GroupInviteProvider? inviteProvider,
    String? currentUserIdOverride,
    String? initialGroupId,
  })  : _contextProvider = contextProvider,
        _inviteProvider = inviteProvider,
        _currentUserIdOverride = currentUserIdOverride,
        _initialGroupId = initialGroupId;

  final GroupContextProvider? _contextProvider;
  final GroupInviteProvider? _inviteProvider;
  final String? _currentUserIdOverride;
  final String? _initialGroupId;

  @override
  State<GroupInviteScreen> createState() => _GroupInviteScreenState();
}

class _GroupInviteScreenState extends State<GroupInviteScreen> {
  late final GroupContextProvider _contextProvider;
  late final GroupInviteProvider _inviteProvider;
  late final bool _ownsContextProvider;
  late final bool _ownsInviteProvider;
  late final TextEditingController _inviteCodeController;
  late final TextEditingController _emailController;
  late final TextEditingController _displayNameController;
  bool _copyingCode = false;
  bool _copyingInviteLink = false;

  @override
  void initState() {
    super.initState();
    _ownsContextProvider = widget._contextProvider == null;
    _ownsInviteProvider = widget._inviteProvider == null;
    _contextProvider = widget._contextProvider ?? GroupContextProvider();
    _inviteProvider = widget._inviteProvider ?? GroupInviteProvider();
    _inviteCodeController = TextEditingController();
    _emailController = TextEditingController();
    _displayNameController = TextEditingController();
    unawaited(_load());
  }

  @override
  void dispose() {
    _inviteCodeController.dispose();
    _emailController.dispose();
    _displayNameController.dispose();
    if (_ownsInviteProvider) {
      _inviteProvider.dispose();
    }
    if (_ownsContextProvider) {
      _contextProvider.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    final userId = widget._currentUserIdOverride ?? authProvider.userId ?? '';
    await _contextProvider.load(
      userId,
      preferredGroupId: widget._initialGroupId,
    );
    await _inviteProvider.load(userId);
    if (mounted) {
      _displayNameController.text =
          _inviteProvider.currentDisplayName?.trim() ?? '';
    }
  }

  Future<void> _copyInviteCode(String code) async {
    setState(() {
      _copyingCode = true;
    });
    try {
      await Clipboard.setData(ClipboardData(text: code));
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('내 초대 코드를 복사했어요.')),
      );
    } finally {
      if (mounted) {
        setState(() {
          _copyingCode = false;
        });
      }
    }
  }

  Future<void> _copyGroupInviteLink(GroupModel group) async {
    final token = group.inviteToken?.trim() ?? '';
    if (token.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('초대 링크를 만들 수 없어요.')),
      );
      return;
    }
    setState(() {
      _copyingInviteLink = true;
    });
    try {
      final link = _groupInviteDeepLink(group);
      await Clipboard.setData(
        ClipboardData(
          text: 'PlanFlow V2 그룹 초대\n${group.name}\n$link',
        ),
      );
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('초대 링크를 복사했어요.')),
      );
    } finally {
      if (mounted) {
        setState(() {
          _copyingInviteLink = false;
        });
      }
    }
  }

  Future<void> _sendInviteByCode(GroupModel group) async {
    final code = _inviteCodeController.text.trim();
    if (code.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('초대 코드를 입력해 주세요.')),
      );
      return;
    }
    try {
      await _inviteProvider.createInviteByInviteCode(
        groupId: group.id,
        inviteCode: code,
      );
      if (!mounted) {
        return;
      }
      _inviteCodeController.clear();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('초대 코드를 보냈어요.')),
      );
    } catch (_) {}
  }

  Future<void> _sendInviteByEmail(GroupModel group) async {
    final email = _emailController.text.trim();
    if (email.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('이메일을 입력해 주세요.')),
      );
      return;
    }
    try {
      await _inviteProvider.createInviteByEmail(
        groupId: group.id,
        email: email,
      );
      if (!mounted) {
        return;
      }
      _emailController.clear();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('이메일 초대를 보냈어요.')),
      );
    } catch (_) {}
  }

  Future<void> _saveMyDisplayName() async {
    try {
      await _inviteProvider.updateMyDisplayName(_displayNameController.text);
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('내 표시 이름을 저장했어요.')),
      );
    } catch (_) {}
  }

  Future<void> _acceptInvite(GroupInviteModel invite) async {
    try {
      await _inviteProvider.acceptInvite(invite.id);
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('초대를 수락했어요.')),
      );
    } catch (_) {}
  }

  Future<void> _rejectInvite(GroupInviteModel invite) async {
    try {
      await _inviteProvider.rejectInvite(invite.id);
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('초대를 거절했어요.')),
      );
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation:
          Listenable.merge(<Listenable>[_contextProvider, _inviteProvider]),
      builder: (context, _) {
        final contextState = _contextProvider.state;
        final inviteState = _inviteProvider.state;
        final selectedGroup = contextState.selectedGroup;
        final canInvite = selectedGroup != null &&
            contextState.selectedGroupRole == 'leader' &&
            !contextState.isPersonalMode;
        return Scaffold(
          appBar: AppBar(
            title: const Text('초대 관리'),
            actions: [
              IconButton(
                tooltip: '새로고침',
                onPressed: inviteState.isLoading ? null : _load,
                icon: const Icon(Icons.refresh_outlined),
              ),
            ],
          ),
          body: RefreshIndicator(
            onRefresh: _load,
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              cacheExtent: 5000,
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
              children: [
                _buildInviteCodeCard(context, inviteState),
                const SizedBox(height: 16),
                _buildGroupSwitcher(context, contextState),
                const SizedBox(height: 16),
                _buildSelectedGroupCard(context, contextState),
                const SizedBox(height: 16),
                if (canInvite) ...[
                  _buildInviteLinkCard(context, selectedGroup),
                  const SizedBox(height: 16),
                  _buildInviteFormCard(context, selectedGroup),
                  const SizedBox(height: 16),
                ] else ...[
                  _buildInviteDisabledCard(context, contextState),
                  const SizedBox(height: 16),
                ],
                if (inviteState.error != null) ...[
                  _buildErrorCard(context, inviteState.error!),
                  const SizedBox(height: 16),
                ],
                _buildPendingInviteSection(context, inviteState),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildInviteCodeCard(BuildContext context, GroupInviteState state) {
    final code = state.currentInviteCode?.trim() ?? '';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            LayoutBuilder(
              builder: (context, constraints) {
                final title = Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.badge_outlined),
                    const SizedBox(width: 8),
                    Text(
                      '내 초대 코드',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                    ),
                  ],
                );
                final nameControls = Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Expanded(
                      child: TextField(
                        key: const ValueKey('my-display-name-field'),
                        controller: _displayNameController,
                        decoration: const InputDecoration(
                          isDense: true,
                          labelText: '내 표시 이름',
                          hintText: '멤버 목록에 보일 이름',
                        ),
                        textInputAction: TextInputAction.done,
                        onSubmitted: (_) => _saveMyDisplayName(),
                      ),
                    ),
                    const SizedBox(width: 8),
                    OutlinedButton.icon(
                      key: const ValueKey('my-display-name-save-button'),
                      onPressed: state.isSubmitting
                          ? null
                          : () => _saveMyDisplayName(),
                      icon: const Icon(Icons.save_outlined, size: 18),
                      label: const Text('이름 저장'),
                    ),
                    if (_copyingCode) ...[
                      const SizedBox(width: 8),
                      const SizedBox.square(
                        dimension: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ],
                  ],
                );

                if (constraints.maxWidth < 560) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      title,
                      const SizedBox(height: 12),
                      nameControls,
                    ],
                  );
                }

                return Row(
                  children: [
                    title,
                    const SizedBox(width: 16),
                    Expanded(child: nameControls),
                  ],
                );
              },
            ),
            const SizedBox(height: 12),
            Text(
              code.isEmpty ? '초대 코드가 아직 없어요.' : code,
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: code.isEmpty
                        ? PlanFlowColors.textSecondary
                        : PlanFlowColors.primary,
                  ),
            ),
            const SizedBox(height: 4),
            Text(
              code.isEmpty
                  ? '프로필에 초대 코드가 아직 준비되지 않았어요.'
                  : '이 코드를 복사해서 팀원을 빠르게 초대할 수 있어요.',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: PlanFlowColors.textSecondary,
                  ),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              key: const ValueKey('my-invite-code-copy-button'),
              onPressed: code.isEmpty || _copyingCode
                  ? null
                  : () => _copyInviteCode(code),
              icon: const Icon(Icons.copy_outlined),
              label: const Text('복사'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildGroupSwitcher(
    BuildContext context,
    GroupContextState state,
  ) {
    if (state.groups.length <= 1) {
      return const SizedBox.shrink();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Text(
            '그룹 선택',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
          ),
        ),
        SizedBox(
          height: 48,
          child: ListView(
            scrollDirection: Axis.horizontal,
            children: [
              for (final group in state.groups)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    key: ValueKey<String>('group-switcher-${group.id}'),
                    label: Text(group.name),
                    selected: group.id == state.selectedGroup?.id,
                    onSelected: (selected) {
                      if (selected && group.id != state.selectedGroup?.id) {
                        _selectGroup(group.id);
                      }
                    },
                    selectedColor: PlanFlowColors.primaryFaint,
                    labelStyle: TextStyle(
                      fontSize: 15,
                      color: group.id == state.selectedGroup?.id
                          ? PlanFlowColors.primary
                          : PlanFlowColors.textSecondary,
                      fontWeight: FontWeight.w700,
                    ),
                    side: BorderSide(
                      color: group.id == state.selectedGroup?.id
                          ? PlanFlowColors.primary
                          : PlanFlowColors.primaryLight,
                    ),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _selectGroup(String groupId) async {
    try {
      await _contextProvider.selectGroup(groupId);
    } catch (_) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('그룹을 선택하지 못했어요.')),
      );
    }
  }

  Widget _buildSelectedGroupCard(
    BuildContext context,
    GroupContextState state,
  ) {
    final selectedGroup = state.selectedGroup;
    final isLeader = state.selectedGroupRole == 'leader';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '현재 그룹',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
            ),
            const SizedBox(height: 10),
            Text(
              selectedGroup?.name ?? '선택된 그룹이 없어요',
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
            ),
            const SizedBox(height: 4),
            Text(
              selectedGroup == null
                  ? '그룹을 먼저 선택해야 초대할 수 있어요.'
                  : isLeader
                      ? '현재 그룹의 리더 권한이 있어요.'
                      : '현재 그룹에서는 초대를 보낼 수 없어요.',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: PlanFlowColors.textSecondary,
                  ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildInviteDisabledCard(
    BuildContext context,
    GroupContextState state,
  ) {
    final selectedGroup = state.selectedGroup;
    final personalMode = state.isPersonalMode;
    final message = personalMode
        ? '개인 모드에서는 초대를 보낼 수 없어요.'
        : selectedGroup == null
            ? '선택된 그룹이 없어요.'
            : '현재 그룹의 리더만 초대를 보낼 수 있어요.';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Text(
          message,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: PlanFlowColors.textSecondary,
              ),
        ),
      ),
    );
  }

  Widget _buildInviteLinkCard(BuildContext context, GroupModel group) {
    final hasToken = group.inviteToken?.trim().isNotEmpty == true;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.link_outlined),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '초대 링크',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                  ),
                ),
                if (_copyingInviteLink)
                  const SizedBox.square(
                    dimension: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              hasToken
                  ? '카톡이나 문자에 붙여넣으면 팀원이 링크를 눌러 바로 참여할 수 있어요.'
                  : '이 그룹에는 아직 초대 링크 토큰이 없어요.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: PlanFlowColors.textSecondary,
                  ),
            ),
            if (hasToken) ...[
              const SizedBox(height: 14),
              Center(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Colors.white,
                    border: Border.all(color: const Color(0xFFE4E7EC)),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: QrImageView(
                      key: const ValueKey('group-invite-link-qr-code'),
                      data: _groupInviteDeepLink(group),
                      version: QrVersions.auto,
                      size: 168,
                      backgroundColor: Colors.white,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Center(
                child: Text(
                  '카메라로 QR을 스캔해도 참여할 수 있어요.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: PlanFlowColors.textSecondary,
                      ),
                  textAlign: TextAlign.center,
                ),
              ),
            ],
            const SizedBox(height: 12),
            FilledButton.icon(
              key: const ValueKey('group-invite-link-copy-button'),
              onPressed: hasToken && !_copyingInviteLink
                  ? () => _copyGroupInviteLink(group)
                  : null,
              icon: const Icon(Icons.copy_outlined),
              label: const Text('초대 링크 복사'),
            ),
          ],
        ),
      ),
    );
  }

  String _groupInviteDeepLink(GroupModel group) {
    return 'planflow-v2://group-invite?'
        'groupId=${Uri.encodeQueryComponent(group.id)}'
        '&token=${Uri.encodeQueryComponent(group.inviteToken?.trim() ?? '')}';
  }

  Widget _buildInviteFormCard(BuildContext context, GroupModel group) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.mail_outline),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '멤버 초대',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('group-invite-code-field'),
              controller: _inviteCodeController,
              decoration: const InputDecoration(
                labelText: '초대 ID / 코드',
                hintText: 'invite_code',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('group-invite-email-field'),
              controller: _emailController,
              decoration: const InputDecoration(
                labelText: '이메일',
                hintText: 'name@example.com',
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: FilledButton(
                    key: const ValueKey('group-invite-code-submit-button'),
                    onPressed: _inviteProvider.isSubmitting
                        ? null
                        : () => _sendInviteByCode(group),
                    child: _inviteProvider.isSubmitting
                        ? const SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('코드로 초대'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton(
                    key: const ValueKey('group-invite-email-submit-button'),
                    onPressed: _inviteProvider.isSubmitting
                        ? null
                        : () => _sendInviteByEmail(group),
                    child: const Text('이메일 초대'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPendingInviteSection(
    BuildContext context,
    GroupInviteState state,
  ) {
    if (state.isLoading && !state.hasPendingInvites) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 56),
        child: Center(child: CircularProgressIndicator()),
      );
    }

    if (!state.hasPendingInvites) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            children: [
              Icon(
                Icons.inbox_outlined,
                size: 40,
                color: PlanFlowColors.primaryLight,
              ),
              const SizedBox(height: 12),
              Text(
                '받은 초대가 없어요',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
              ),
              const SizedBox(height: 8),
              Text(
                '팀 리더가 초대를 보내면 이곳에 표시돼요.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: PlanFlowColors.textSecondary,
                    ),
              ),
            ],
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '받은 초대',
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
        ),
        const SizedBox(height: 12),
        ...state.pendingInvites.map(
          (invite) => Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: _PendingInviteCard(
              invite: invite,
              onAccept: () => _acceptInvite(invite),
              onReject: () => _rejectInvite(invite),
              isBusy: state.isSubmitting,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildErrorCard(BuildContext context, String error) {
    return Card(
      color: const Color(0xFFFFF3F0),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Text(
          error,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: const Color(0xFF7A271A),
              ),
        ),
      ),
    );
  }
}

class _PendingInviteCard extends StatelessWidget {
  const _PendingInviteCard({
    required this.invite,
    required this.onAccept,
    required this.onReject,
    required this.isBusy,
  });

  final GroupInviteModel invite;
  final VoidCallback onAccept;
  final VoidCallback onReject;
  final bool isBusy;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.mail_outline),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    invite.invitedEmail?.trim().isNotEmpty == true
                        ? invite.invitedEmail!.trim()
                        : '초대 코드 ${invite.invitedInviteCode ?? '-'}',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                  ),
                ),
                _StatusChip(status: invite.status),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              '그룹 ID: ${invite.groupId}',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: PlanFlowColors.textSecondary,
                  ),
            ),
            const SizedBox(height: 4),
            Text(
              '만료: ${invite.expiresAt.toLocal()}',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: PlanFlowColors.textSecondary,
                  ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: FilledButton(
                    key: ValueKey<String>('invite-accept-${invite.id}'),
                    onPressed: isBusy ? null : onAccept,
                    child: const Text('수락'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton(
                    key: ValueKey<String>('invite-reject-${invite.id}'),
                    onPressed: isBusy ? null : onReject,
                    child: const Text('거절'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.status});

  final String status;

  @override
  Widget build(BuildContext context) {
    final label = switch (status) {
      'pending' => '대기',
      'accepted' => '수락됨',
      'rejected' => '거절됨',
      'cancelled' => '취소됨',
      'expired' => '만료됨',
      _ => status,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: PlanFlowColors.tagNormalBg,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: PlanFlowColors.tagNormalText,
              fontWeight: FontWeight.w700,
            ),
      ),
    );
  }
}
