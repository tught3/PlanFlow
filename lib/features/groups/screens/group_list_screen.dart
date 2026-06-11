import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../core/constants.dart';
import '../../../core/theme.dart';
import '../../../providers/auth_provider.dart';
import '../models/group_model.dart';
import '../providers/group_context_provider.dart';
import '../providers/group_context_state.dart';

class GroupListScreen extends StatefulWidget {
  const GroupListScreen({
    super.key,
    GroupContextProvider? provider,
    String? currentUserIdOverride,
  })  : _provider = provider,
        _currentUserIdOverride = currentUserIdOverride;

  final GroupContextProvider? _provider;
  final String? _currentUserIdOverride;

  @override
  State<GroupListScreen> createState() => _GroupListScreenState();
}

class _GroupListScreenState extends State<GroupListScreen> {
  late final GroupContextProvider _provider;
  late final bool _ownsProvider;

  @override
  void initState() {
    super.initState();
    _ownsProvider = widget._provider == null;
    _provider = widget._provider ?? GroupContextProvider();
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
    await _provider.load(
      widget._currentUserIdOverride ?? authProvider.userId ?? '',
    );
  }

  Future<void> _openCreateGroup() async {
    final result = await context.push<String>(AppRoutes.groupCreate);
    if (!mounted) {
      return;
    }
    if (result != null) {
      await _load();
    }
  }

  Future<void> _selectGroup(GroupModel group) async {
    await _provider.selectGroup(group.id);
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _provider,
      builder: (context, _) {
        final state = _provider.state;
        return Scaffold(
          appBar: AppBar(
            title: const Text('그룹 관리'),
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
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
              physics: const AlwaysScrollableScrollPhysics(),
              children: [
                _buildSelectedGroupCard(context, state),
                const SizedBox(height: 16),
                if (state.isLoading && !state.hasGroups) ...[
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 56),
                    child: Center(child: CircularProgressIndicator()),
                  ),
                ] else if (state.error != null && state.groups.isEmpty) ...[
                  _buildErrorCard(context, state.error!),
                ] else ...[
                  _buildSectionHeader(context, '내 그룹 목록'),
                  const SizedBox(height: 12),
                  if (!state.hasGroups)
                    _buildEmptyState(context)
                  else
                    ...state.groups.map(
                      (group) => Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: _GroupListTile(
                          key: ValueKey<String>('group-list-item-${group.id}'),
                          group: group,
                          roleLabel: _roleLabelForGroup(state, group),
                          isSelected: state.selectedGroup?.id == group.id,
                          onTap: () => _selectGroup(group),
                        ),
                      ),
                    ),
                ],
                const SizedBox(height: 8),
                FilledButton.icon(
                  key: const ValueKey('group-list-create-button'),
                  onPressed: _openCreateGroup,
                  icon: const Icon(Icons.add_circle_outline),
                  label: const Text('새 그룹 만들기'),
                ),
                const SizedBox(height: 12),
                Text(
                  '팀 기능은 현재 그룹 목록과 생성부터 시작합니다.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: PlanFlowColors.textSecondary,
                      ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildSelectedGroupCard(
    BuildContext context,
    GroupContextState state,
  ) {
    final selectedGroup = state.selectedGroup;
    final isPersonalMode = state.isPersonalMode;
    final title = isPersonalMode ? '개인 모드' : selectedGroup?.name ?? '선택된 그룹 없음';
    final subtitle =
        isPersonalMode ? '현재는 그룹을 선택하지 않은 상태예요.' : '현재 선택된 그룹을 기준으로 화면이 이어집니다.';

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.view_quilt_outlined),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '현재 그룹 컨텍스트',
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
                  label: isPersonalMode ? '개인 모드' : '팀 모드',
                  backgroundColor: isPersonalMode
                      ? PlanFlowColors.tagDoneBg
                      : PlanFlowColors.primaryFaint,
                  textColor: isPersonalMode
                      ? PlanFlowColors.tagDoneText
                      : PlanFlowColors.primary,
                ),
                if (selectedGroup != null)
                  _InfoChip(
                    label: _roleLabelForGroup(state, selectedGroup),
                  ),
                if (selectedGroup != null)
                  _InfoChip(label: _statusLabel(selectedGroup.status)),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyState(BuildContext context) {
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
              '아직 속한 그룹이 없어요',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
            ),
            const SizedBox(height: 8),
            Text(
              '새 그룹을 만들면 팀 일정과 선택 컨텍스트를 바로 이어서 사용할 수 있어요.',
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
                    '그룹 정보를 불러오지 못했어요',
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

  Widget _buildSectionHeader(BuildContext context, String title) {
    return Row(
      children: [
        Expanded(
          child: Text(
            title,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
          ),
        ),
        Text(
          '선택해서 전환',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: PlanFlowColors.textSecondary,
              ),
        ),
      ],
    );
  }

  String _roleLabelForGroup(GroupContextState state, GroupModel group) {
    if (state.selectedGroup?.id == group.id &&
        state.selectedGroupRole != null) {
      return state.selectedGroupRole == 'leader' ? '리더' : '멤버';
    }
    return '멤버';
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

class _GroupListTile extends StatelessWidget {
  const _GroupListTile({
    super.key,
    required this.group,
    required this.roleLabel,
    required this.isSelected,
    required this.onTap,
  });

  final GroupModel group;
  final String roleLabel;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 0,
      color: isSelected ? PlanFlowColors.primaryFaint : null,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: isSelected
                      ? PlanFlowColors.primary
                      : PlanFlowColors.primaryFaint,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  isSelected ? Icons.check_circle : Icons.groups_outlined,
                  color: isSelected ? Colors.white : PlanFlowColors.primary,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            group.name,
                            style: Theme.of(context)
                                .textTheme
                                .titleMedium
                                ?.copyWith(fontWeight: FontWeight.w700),
                          ),
                        ),
                        if (isSelected) const _InfoChip(label: '선택됨'),
                      ],
                    ),
                    if ((group.description ?? '').trim().isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        group.description!.trim(),
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                              color: PlanFlowColors.textSecondary,
                            ),
                      ),
                    ],
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        _InfoChip(label: roleLabel),
                        _InfoChip(label: _statusLabel(group.status)),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
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
