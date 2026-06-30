import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/constants.dart';
import '../../../core/theme.dart';
import '../../../data/repositories/event_repository.dart';
import '../models/group_model.dart';
import '../providers/group_context_provider.dart';
import '../repositories/group_event_repository.dart';
import '../repositories/group_repository.dart';
import '../services/group_event_share_service.dart';

class GroupDetailScreen extends StatefulWidget {
  const GroupDetailScreen({
    super.key,
    required this.groupId,
    this.contextProvider,
    this.repository,
    this.eventRepository,
    this.groupEventRepository,
    this.preferences,
    this.currentUserIdOverride,
  });

  final String groupId;
  final GroupContextProvider? contextProvider;
  final GroupRepository? repository;
  final EventRepository? eventRepository;
  final GroupEventRepository? groupEventRepository;
  final SharedPreferences? preferences;
  final String? currentUserIdOverride;

  @override
  State<GroupDetailScreen> createState() => _GroupDetailScreenState();
}

class _GroupDetailScreenState extends State<GroupDetailScreen> {
  late final GroupContextProvider _provider;
  late final GroupRepository _repository;
  bool _ownsProvider = false;

  GroupModel? _group;
  bool _isLoading = false;
  bool _isLeader = false;
  bool _sharePromptScheduled = false;
  bool _sharePromptShowing = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _repository = widget.repository ?? GroupRepository.supabase();
    _provider =
        widget.contextProvider ?? GroupContextProvider(repository: _repository);
    _ownsProvider = widget.contextProvider == null;
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
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final userId = _currentUserId();
      await _provider.load(userId, preferredGroupId: widget.groupId);
      if (_provider.selectedGroup?.id != widget.groupId) {
        throw StateError('선택할 수 없는 그룹입니다.');
      }
      final group = await _repository.fetchGroup(widget.groupId);
      if (!mounted) return;
      setState(() {
        _group = group;
        _isLeader = _provider.state.isLeaderOfSelectedGroup;
        _isLoading = false;
      });
      _scheduleSharePrompt(userId: userId, group: group);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _isLoading = false;
      });
    }
  }

  String _currentUserId() {
    final override = widget.currentUserIdOverride?.trim();
    if (override != null && override.isNotEmpty) {
      return override;
    }
    return Supabase.instance.client.auth.currentUser?.id ?? '';
  }

  void _scheduleSharePrompt({
    required String userId,
    required GroupModel? group,
  }) {
    if (_sharePromptScheduled ||
        _sharePromptShowing ||
        userId.trim().isEmpty ||
        group == null ||
        !group.isActive) {
      return;
    }
    _sharePromptScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      unawaited(_maybeShowExistingEventsSharePrompt(userId, group.id));
    });
  }

  Future<void> _maybeShowExistingEventsSharePrompt(
    String userId,
    String groupId,
  ) async {
    if (_sharePromptShowing) {
      return;
    }
    final preferences =
        widget.preferences ?? await SharedPreferences.getInstance();
    if (!mounted) {
      return;
    }
    final key = _sharePromptKey(userId, groupId);
    if (preferences.getBool(key) == true) {
      return;
    }
    _sharePromptShowing = true;
    final choice = await showDialog<_ExistingEventShareChoice>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('기존 일정을 공유할까요?'),
        content: const Text(
          '오늘 이후의 개인 일정 중 직접 만든 일정만 이 그룹 일정으로 복사할 수 있어요. 같은 제목과 시간이 이미 있으면 중복으로 만들지 않습니다.',
        ),
        actionsPadding:
            const EdgeInsets.fromLTRB(16, 0, 16, 12),
        actions: [
          // 한 줄에 모두 배치하되, 폭이 부족하면 각 버튼을 통째로 다음 줄로
          // 넘겨 2줄로 보기 좋게 정렬한다(버튼 안 텍스트는 줄바꿈하지 않음).
          Wrap(
            alignment: WrapAlignment.end,
            spacing: 8,
            runSpacing: 4,
            children: [
              TextButton(
                onPressed: () =>
                    Navigator.of(ctx).pop(_ExistingEventShareChoice.later),
                child: const Text('나중에'),
              ),
              TextButton(
                onPressed: () => Navigator.of(ctx)
                    .pop(_ExistingEventShareChoice.onlyNewEvents),
                child: const Text('새로 만드는 일정부터'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(ctx)
                    .pop(_ExistingEventShareChoice.shareUpcoming),
                child: const Text('오늘 이후 일정 공유'),
              ),
            ],
          ),
        ],
      ),
    );
    _sharePromptShowing = false;
    if (choice == null || !mounted) {
      return;
    }
    await preferences.setBool(key, true);
    if (choice != _ExistingEventShareChoice.shareUpcoming) {
      return;
    }
    await _shareUpcomingPersonalEvents(userId: userId, groupId: groupId);
  }

  Future<void> _shareUpcomingPersonalEvents({
    required String userId,
    required String groupId,
  }) async {
    try {
      final result = await GroupEventShareService(
        eventRepository: widget.eventRepository ?? EventRepository.supabase(),
        groupEventRepository:
            widget.groupEventRepository ?? GroupEventRepository.supabase(),
      ).shareUpcomingManualEvents(userId: userId, groupId: groupId);
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(result.summary)),
      );
      unawaited(_load());
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('기존 일정 공유에 실패했어요: $error')),
      );
    }
  }

  String _sharePromptKey(String userId, String groupId) =>
      'planflow:group_event_share_prompt:v1:$userId:$groupId';

  Future<void> _deleteGroup() async {
    final group = _group;
    if (group == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('그룹 삭제'),
        content: Text(
          '"${group.name}" 그룹을 삭제하면 모든 멤버, 초대, 일정이 함께 삭제됩니다. 계속할까요?',
        ),
        actionsAlignment: MainAxisAlignment.end,
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('취소'),
          ),
          const SizedBox(width: 8),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFB42318),
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('삭제'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await _repository.deleteGroup(group.id);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('"${group.name}" 그룹을 삭제했어요.')),
      );
      context.pop();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('삭제 실패: $e')),
      );
    }
  }

  Future<void> _editGroupName() async {
    final group = _group;
    if (group == null || !_isLeader) {
      return;
    }
    final controller = TextEditingController(text: group.name);
    final nextName = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('팀 이름 변경'),
        content: TextField(
          key: const ValueKey('group-name-dialog-field'),
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: '팀 이름',
            hintText: '새 팀 이름',
          ),
          textInputAction: TextInputAction.done,
          onSubmitted: (value) => Navigator.of(ctx).pop(value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text),
            child: const Text('저장'),
          ),
        ],
      ),
    );
    controller.dispose();
    final trimmed = nextName?.trim() ?? '';
    if (trimmed.isEmpty || trimmed == group.name) {
      return;
    }

    try {
      final updated = await _repository.updateGroup(group.copyWith(
        name: trimmed,
        updatedAt: DateTime.now().toUtc(),
      ));
      if (!mounted) return;
      setState(() {
        _group = updated;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('팀 이름을 저장했어요.')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('팀 이름 저장 실패: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final group = _group;
    return Scaffold(
      appBar: AppBar(
        title: Text(_isLoading ? '...' : (group?.name ?? '그룹 상세')),
        actions: [
          IconButton(
            tooltip: '새로고침',
            onPressed: _isLoading ? null : _load,
            icon: const Icon(Icons.refresh_outlined),
          ),
        ],
      ),
      body: _isLoading && group == null
          ? const Center(child: CircularProgressIndicator())
          : _error != null && group == null
              ? _buildErrorCard(context)
              : ListView(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
                  children: [
                    if (group != null) _buildHeaderCard(context, group),
                    const SizedBox(height: 20),
                    _buildActionGrid(context),
                    if (_isLeader) ...[
                      const SizedBox(height: 28),
                      const Divider(),
                      const SizedBox(height: 16),
                      OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: const Color(0xFFB42318),
                          side: const BorderSide(color: Color(0xFFB42318)),
                        ),
                        onPressed: _deleteGroup,
                        icon: const Icon(Icons.delete_outline),
                        label: const Text('그룹 삭제'),
                      ),
                    ],
                  ],
                ),
    );
  }

  Widget _buildHeaderCard(BuildContext context, GroupModel group) {
    final roleLabel = _isLeader ? '리더' : '멤버';
    final statusLabel = _statusLabel(group.status);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: PlanFlowColors.primaryFaint,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(
                    Icons.groups_2_outlined,
                    color: PlanFlowColors.primary,
                    size: 22,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        group.name,
                        style:
                            Theme.of(context).textTheme.titleMedium?.copyWith(
                                  fontWeight: FontWeight.w700,
                                ),
                      ),
                      if ((group.description ?? '').isNotEmpty)
                        Text(
                          group.description!,
                          style:
                              Theme.of(context).textTheme.bodySmall?.copyWith(
                                    color: PlanFlowColors.textSecondary,
                                  ),
                        ),
                    ],
                  ),
                ),
                if (_isLeader)
                  IconButton(
                    key: const ValueKey('group-name-edit-button'),
                    tooltip: '팀 이름 변경',
                    onPressed: _editGroupName,
                    icon: const Icon(Icons.edit_outlined),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _InfoChip(label: roleLabel),
                _InfoChip(label: statusLabel),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildActionGrid(BuildContext context) {
    final actions = [
      _ActionItem(
        icon: Icons.dashboard_outlined,
        label: '대시보드',
        route: AppRoutes.groupDashboardForId(widget.groupId),
      ),
      _ActionItem(
        icon: Icons.event_available_outlined,
        label: '그룹 일정',
        route: AppRoutes.groupEventsForId(widget.groupId),
      ),
      _ActionItem(
        icon: Icons.mail_outline,
        label: '초대 관리',
        route: AppRoutes.groupInvitesForId(widget.groupId),
        extra: _provider,
      ),
      _ActionItem(
        icon: Icons.groups_2_outlined,
        label: '멤버 관리',
        route: AppRoutes.groupMembersForId(widget.groupId),
      ),
    ];
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        crossAxisSpacing: 12,
        mainAxisSpacing: 12,
        childAspectRatio: 1.6,
      ),
      itemCount: actions.length,
      itemBuilder: (context, index) {
        final item = actions[index];
        return _ActionCard(
          icon: item.icon,
          label: item.label,
          onTap: () => context.push(item.route, extra: item.extra),
        );
      },
    );
  }

  Widget _buildErrorCard(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.error_outline, size: 40, color: Color(0xFFB42318)),
          const SizedBox(height: 12),
          Text(
            '그룹 정보를 불러오지 못했어요.',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          Text(
            _error ?? '',
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: PlanFlowColors.textSecondary),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          FilledButton(onPressed: _load, child: const Text('다시 시도')),
        ],
      ),
    );
  }

  String _statusLabel(String status) {
    switch (status) {
      case 'active':
        return '활성';
      case 'archived':
        return '보관됨';
      default:
        return status;
    }
  }
}

class _ActionItem {
  const _ActionItem({
    required this.icon,
    required this.label,
    required this.route,
    this.extra,
  });
  final IconData icon;
  final String label;
  final String route;
  final Object? extra;
}

enum _ExistingEventShareChoice {
  shareUpcoming,
  onlyNewEvents,
  later,
}

class _ActionCard extends StatelessWidget {
  const _ActionCard({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 28, color: PlanFlowColors.primary),
              const SizedBox(height: 8),
              Text(
                label,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _InfoChip extends StatelessWidget {
  const _InfoChip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: PlanFlowColors.tagNormalBg,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: PlanFlowColors.tagNormalText,
              fontWeight: FontWeight.w600,
            ),
      ),
    );
  }
}
