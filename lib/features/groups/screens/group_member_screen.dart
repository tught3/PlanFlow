import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../core/constants.dart';
import '../../../core/local_time.dart';
import '../../../core/theme.dart';
import '../../../providers/auth_provider.dart';
import '../models/group_member_model.dart';
import '../providers/group_member_provider.dart';
import '../providers/group_member_state.dart';

class GroupMemberScreen extends StatefulWidget {
  const GroupMemberScreen({
    super.key,
    GroupMemberProvider? provider,
    String? currentUserIdOverride,
    String? initialGroupId,
  })  : _provider = provider,
        _currentUserIdOverride = currentUserIdOverride,
        _initialGroupId = initialGroupId;

  final GroupMemberProvider? _provider;
  final String? _currentUserIdOverride;
  final String? _initialGroupId;

  @override
  State<GroupMemberScreen> createState() => _GroupMemberScreenState();
}

class _GroupMemberScreenState extends State<GroupMemberScreen> {
  late final GroupMemberProvider _provider;
  late final bool _ownsProvider;

  @override
  void initState() {
    super.initState();
    _ownsProvider = widget._provider == null;
    _provider = widget._provider ?? GroupMemberProvider();
    unawaited(_load());
  }

  @override
  void dispose() {
    if (_ownsProvider) {
      _provider.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    final userId = widget._currentUserIdOverride ?? authProvider.userId ?? '';
    await _provider.load(userId, preferredGroupId: widget._initialGroupId);
  }

  Future<void> _openGroupList() async {
    await context.push<String>(AppRoutes.groups);
    if (!mounted) {
      return;
    }
    await _load();
  }

  Future<void> _confirmRemoveMember(GroupMemberModel member) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('멤버 제거'),
          content: Text(
            '${member.effectiveDisplayName} 멤버를 그룹에서 제거할까요?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('취소'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('제거'),
            ),
          ],
        );
      },
    );
    if (confirmed != true) {
      return;
    }

    try {
      await _provider.removeMember(member);
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${member.userId} 멤버를 제거했어요.')),
      );
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error.toString())),
      );
    }
  }

  Future<void> _editMemberDisplayName(GroupMemberModel member) async {
    final controller = TextEditingController(text: member.effectiveDisplayName);
    final displayName = await showDialog<String>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('멤버 이름 변경'),
          content: TextField(
            key: const ValueKey('group-member-display-name-dialog-field'),
            controller: controller,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: '표시 이름',
              hintText: '예: 민수, 엄마, 디자인팀장',
            ),
            textInputAction: TextInputAction.done,
            onSubmitted: (value) => Navigator.of(context).pop(value),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('취소'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(controller.text),
              child: const Text('저장'),
            ),
          ],
        );
      },
    );
    controller.dispose();
    if (displayName == null) {
      return;
    }

    try {
      await _provider.updateMemberDisplayName(member, displayName);
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('멤버 이름을 저장했어요.')),
      );
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error.toString())),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _provider,
      builder: (context, _) {
        final state = _provider.state;
        return Scaffold(
          appBar: AppBar(
            title: const Text('멤버 관리'),
            actions: [
              IconButton(
                tooltip: '새로고침',
                onPressed: state.isLoading ? null : _load,
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
                _buildSelectedGroupCard(context, state),
                const SizedBox(height: 16),
                OutlinedButton.icon(
                  key: const ValueKey('group-member-list-button'),
                  onPressed: _openGroupList,
                  icon: const Icon(Icons.groups_2_outlined),
                  label: const Text('그룹 선택'),
                ),
                if (state.error != null) ...[
                  const SizedBox(height: 16),
                  _buildErrorCard(context, state.error!),
                ],
                const SizedBox(height: 16),
                if (state.isLoading && !state.hasSelectedGroup) ...[
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 56),
                    child: Center(child: CircularProgressIndicator()),
                  ),
                ] else if (!state.hasSelectedGroup) ...[
                  _buildNoGroupState(context),
                ] else if (!state.hasMembers) ...[
                  _buildEmptyMembersState(context),
                ] else ...[
                  _buildMembersSection(context, state),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildSelectedGroupCard(
    BuildContext context,
    GroupMemberState state,
  ) {
    final selectedGroup = state.selectedGroup;
    final title = selectedGroup?.name ?? '선택된 그룹이 없어요';
    final subtitle = selectedGroup == null
        ? '그룹을 선택하면 멤버 목록을 볼 수 있어요.'
        : state.isLeaderOfSelectedGroup
            ? '리더 권한으로 멤버를 관리할 수 있어요.'
            : '멤버 목록을 조회할 수 있어요.';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.groups_2_outlined),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '현재 그룹',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                  ),
                ),
                if (state.isLoading)
                  const SizedBox.square(
                    dimension: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              title,
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
            ),
            const SizedBox(height: 4),
            Text(
              subtitle,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: PlanFlowColors.textSecondary,
                  ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _InfoChip(
                  label: state.isPersonalMode ? '개인 모드' : '팀 모드',
                  backgroundColor: state.isPersonalMode
                      ? PlanFlowColors.tagDoneBg
                      : PlanFlowColors.primaryFaint,
                  textColor: state.isPersonalMode
                      ? PlanFlowColors.tagDoneText
                      : PlanFlowColors.primary,
                ),
                if (selectedGroup != null)
                  _InfoChip(
                    label: state.isLeaderOfSelectedGroup ? '리더' : '멤버',
                  ),
                if (selectedGroup != null)
                  _InfoChip(label: _statusLabel(selectedGroup.status)),
                _InfoChip(label: '멤버 ${state.members.length}명'),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMembersSection(
    BuildContext context,
    GroupMemberState state,
  ) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '멤버 목록',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                  ),
                ),
                Text(
                  state.members.length.toString(),
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: PlanFlowColors.textSecondary,
                      ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (state.isSubmitting) ...[
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: LinearProgressIndicator(minHeight: 2),
              ),
              const SizedBox(height: 12),
            ],
            for (final member in state.members)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: _MemberTile(
                  key: ValueKey<String>('group-member-item-${member.id}'),
                  member: member,
                  canRemove: _provider.canRemoveMember(member),
                  canEditDisplayName:
                      _provider.canEditMemberDisplayName(member),
                  onEditDisplayNamePressed: () =>
                      _editMemberDisplayName(member),
                  onRemovePressed: () => _confirmRemoveMember(member),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildNoGroupState(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            Icon(
              Icons.groups_2_outlined,
              size: 40,
              color: PlanFlowColors.primaryLight,
            ),
            const SizedBox(height: 12),
            Text(
              '선택된 그룹이 없어요',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
            ),
            const SizedBox(height: 8),
            Text(
              '그룹을 선택해야 멤버 목록을 볼 수 있어요.',
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

  Widget _buildEmptyMembersState(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            Icon(
              Icons.person_off_outlined,
              size: 40,
              color: PlanFlowColors.primaryLight,
            ),
            const SizedBox(height: 12),
            Text(
              '등록된 멤버가 없어요',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
            ),
            const SizedBox(height: 8),
            Text(
              '현재 선택된 그룹에서 활성 멤버를 찾지 못했어요.',
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

  Widget _buildErrorCard(BuildContext context, String error) {
    return Card(
      color: const Color(0xFFFFF3F0),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.error_outline, color: Color(0xFFB42318)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '멤버 정보를 불러오지 못했어요',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                          color: const Color(0xFF7A271A),
                        ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              error,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: const Color(0xFF7A271A),
                  ),
            ),
            const SizedBox(height: 12),
            OutlinedButton(
              onPressed: _load,
              child: const Text('다시 시도'),
            ),
          ],
        ),
      ),
    );
  }

  String _statusLabel(String status) {
    return switch (status) {
      'active' => '활성',
      'archived' => '보관됨',
      'deleted_pending' => '삭제 대기',
      _ => status,
    };
  }
}

class _MemberTile extends StatelessWidget {
  const _MemberTile({
    super.key,
    required this.member,
    required this.canRemove,
    required this.canEditDisplayName,
    required this.onEditDisplayNamePressed,
    required this.onRemovePressed,
  });

  final GroupMemberModel member;
  final bool canRemove;
  final bool canEditDisplayName;
  final VoidCallback onEditDisplayNamePressed;
  final VoidCallback onRemovePressed;

  @override
  Widget build(BuildContext context) {
    final isRemoved = member.status == 'removed';
    return Container(
      decoration: BoxDecoration(
        color: isRemoved ? const Color(0xFFF8FAFC) : PlanFlowColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: PlanFlowColors.primaryFaint),
      ),
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  member.effectiveDisplayName,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (canEditDisplayName) ...[
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  key: ValueKey<String>('group-member-rename-${member.id}'),
                  onPressed: onEditDisplayNamePressed,
                  icon: const Icon(Icons.edit_outlined, size: 18),
                  label: const Text('이름 변경'),
                  style: OutlinedButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 8,
                    ),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              _InfoChip(label: _roleLabel(member.role)),
              _InfoChip(label: _statusLabel(member.status)),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 12,
            runSpacing: 6,
            children: [
              Text(
                member.secondaryLabel,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: PlanFlowColors.textSecondary,
                    ),
              ),
              Text(
                _dateLabel('가입', member.joinedAt),
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: PlanFlowColors.textSecondary,
                    ),
              ),
              Text(
                _dateLabel('제거', member.removedAt),
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: PlanFlowColors.textSecondary,
                    ),
              ),
              if ((member.removedBy ?? '').trim().isNotEmpty)
                Text(
                  '제거자 ${member.removedBy}',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: PlanFlowColors.textSecondary,
                      ),
                ),
            ],
          ),
          if (canRemove) ...[
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                FilledButton.tonalIcon(
                  key: ValueKey<String>('group-member-remove-${member.id}'),
                  onPressed: onRemovePressed,
                  icon: const Icon(Icons.remove_circle_outline),
                  label: const Text('제거'),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  String _roleLabel(String role) {
    return switch (role) {
      'leader' => '리더',
      'member' => '멤버',
      _ => role,
    };
  }

  String _statusLabel(String status) {
    return switch (status) {
      'active' => '활성',
      'removed' => '제거됨',
      _ => status,
    };
  }

  String _dateLabel(String prefix, DateTime? value) {
    if (value == null) {
      return '$prefix: -';
    }
    final local = planflowLocal(value);
    return '$prefix: ${local.year}.${local.month.toString().padLeft(2, '0')}.${local.day.toString().padLeft(2, '0')}';
  }
}

class _InfoChip extends StatelessWidget {
  const _InfoChip({
    required this.label,
    this.backgroundColor = PlanFlowColors.tagNormalBg,
    this.textColor = PlanFlowColors.tagNormalText,
  });

  final String label;
  final Color backgroundColor;
  final Color textColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: textColor,
              fontWeight: FontWeight.w700,
            ),
      ),
    );
  }
}
