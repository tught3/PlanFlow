import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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
  })  : _contextProvider = contextProvider,
        _inviteProvider = inviteProvider,
        _currentUserIdOverride = currentUserIdOverride;

  final GroupContextProvider? _contextProvider;
  final GroupInviteProvider? _inviteProvider;
  final String? _currentUserIdOverride;

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
  bool _copyingCode = false;

  @override
  void initState() {
    super.initState();
    _ownsContextProvider = widget._contextProvider == null;
    _ownsInviteProvider = widget._inviteProvider == null;
    _contextProvider = widget._contextProvider ?? GroupContextProvider();
    _inviteProvider = widget._inviteProvider ?? GroupInviteProvider();
    _inviteCodeController = TextEditingController();
    _emailController = TextEditingController();
    unawaited(_load());
  }

  @override
  void dispose() {
    _inviteCodeController.dispose();
    _emailController.dispose();
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
    await Future.wait(<Future<void>>[
      _contextProvider.load(userId),
      _inviteProvider.load(userId),
    ]);
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
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
              children: [
                _buildInviteCodeCard(context, inviteState),
                const SizedBox(height: 16),
                _buildSelectedGroupCard(context, contextState),
                const SizedBox(height: 16),
                if (canInvite) ...[
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
            Row(
              children: [
                const Icon(Icons.badge_outlined),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '내 초대 코드',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                  ),
                ),
                if (_copyingCode)
                  const SizedBox.square(
                    dimension: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
              ],
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
