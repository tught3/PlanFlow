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
  bool _autoShareEnabled = false;
  bool _isSharingExistingEvents = false;

  @override
  void initState() {
    super.initState();
    _repository = widget.repository ?? GroupRepository.supabase();
    _provider =
        widget.contextProvider ?? GroupContextProvider(repository: _repository);
    _ownsProvider = widget.contextProvider == null;
    unawaited(_load());
    unawaited(_loadAutoSharePref());
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
        actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        actions: [
          // 1행: 보조 선택지 2개를 테두리 버튼으로 절반씩 나란히 배치.
          // 2행: 주 선택지(오늘 이후 일정 공유)를 강조 버튼으로 전체 너비에 배치.
          SizedBox(
            width: double.maxFinite,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    // '나중에'는 글자수가 적어 콘텐츠 크기로 왼쪽에 붙이고,
                    // 남는 공간 전부를 '새로 만드는 일정부터'에 줘 1줄에 줄바꿈 없이 배치.
                    OutlinedButton(
                      onPressed: () => Navigator.of(ctx)
                          .pop(_ExistingEventShareChoice.later),
                      child: const Text('나중에'),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => Navigator.of(ctx)
                            .pop(_ExistingEventShareChoice.onlyNewEvents),
                        child: const Text('새로 만드는 일정부터'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: () => Navigator.of(ctx)
                        .pop(_ExistingEventShareChoice.shareUpcoming),
                    child: const Text('오늘 이후 일정 공유'),
                  ),
                ),
              ],
            ),
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

  // 처음 그룹에 들어왔을 때 뜨는 자동 안내(_maybeShowExistingEventsSharePrompt)는
  // 어떤 선택을 하든(나중에 포함) 다시 뜨지 않는다. '나중에'를 고른 뒤 다시
  // 공유하고 싶어질 때를 위해 언제든 수동으로 같은 동작을 실행할 수 있는
  // 진입점을 별도로 둔다.
  Future<void> _shareExistingEventsManually() async {
    if (_isSharingExistingEvents) {
      return;
    }
    final userId = _currentUserId();
    if (userId.trim().isEmpty) {
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('기존 일정을 공유할까요?'),
        content: const Text(
          '오늘 이후의 개인 일정 중 직접 만든 일정만 이 그룹 일정으로 복사할 수 있어요. 같은 제목과 시간이 이미 있으면 중복으로 만들지 않습니다.',
        ),
        actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        actions: [
          SizedBox(
            width: double.maxFinite,
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.of(ctx).pop(false),
                    child: const Text('취소'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton(
                    onPressed: () => Navigator.of(ctx).pop(true),
                    child: const Text('오늘 이후 일정 공유'),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) {
      return;
    }
    setState(() {
      _isSharingExistingEvents = true;
    });
    try {
      await _shareUpcomingPersonalEvents(
          userId: userId, groupId: widget.groupId);
    } finally {
      if (mounted) {
        setState(() {
          _isSharingExistingEvents = false;
        });
      }
    }
  }

  String _sharePromptKey(String userId, String groupId) =>
      'planflow:group_event_share_prompt:v1:$userId:$groupId';

  String _autoSharePrefKey(String userId, String groupId) =>
      'planflow:group_auto_share:v1:$userId:$groupId';

  Future<void> _loadAutoSharePref() async {
    final userId = _currentUserId();
    if (userId.trim().isEmpty) {
      return;
    }
    final preferences =
        widget.preferences ?? await SharedPreferences.getInstance();
    if (!mounted) {
      return;
    }
    final key = _autoSharePrefKey(userId, widget.groupId);
    final enabled = preferences.getBool(key) ?? false;
    setState(() {
      _autoShareEnabled = enabled;
    });
  }

  Future<void> _toggleAutoShare(bool value) async {
    final userId = _currentUserId();
    if (userId.trim().isEmpty) {
      return;
    }
    final preferences =
        widget.preferences ?? await SharedPreferences.getInstance();
    final key = _autoSharePrefKey(userId, widget.groupId);
    await preferences.setBool(key, value);
    if (mounted) {
      setState(() {
        _autoShareEnabled = value;
      });
    }
  }

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
        actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        actions: [
          SizedBox(
            width: double.maxFinite,
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.of(ctx).pop(false),
                    child: const Text('취소'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFFB42318),
                    ),
                    onPressed: () => Navigator.of(ctx).pop(true),
                    child: const Text('삭제'),
                  ),
                ),
              ],
            ),
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
        SnackBar(content: Text('삭제 실패: ${_friendlyErrorMessage(e)}')),
      );
    }
  }

  /// PostgrestException(DB 함수 raise exception 등)은 사용자에게 필요한
  /// message만 보여주고, code/details/hint 같은 내부 정보는 노출하지 않는다.
  String _friendlyErrorMessage(Object error) {
    if (error is PostgrestException) {
      return error.message;
    }
    return error.toString();
  }

  Future<void> _leaveGroup() async {
    final group = _group;
    if (group == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('팀 나가기'),
        content: Text(
          '"${group.name}" 그룹에서 나가시겠어요? 다시 참여하려면 새 초대가 필요해요.',
        ),
        actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        actions: [
          SizedBox(
            width: double.maxFinite,
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.of(ctx).pop(false),
                    child: const Text('취소'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFFB42318),
                    ),
                    onPressed: () => Navigator.of(ctx).pop(true),
                    child: const Text('나가기'),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await _repository.leaveGroup(group.id);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('"${group.name}" 그룹에서 나갔어요.')),
      );
      context.pop();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('나가기 실패: ${_friendlyErrorMessage(e)}')),
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
          SizedBox(
            width: double.maxFinite,
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.of(ctx).pop(),
                    child: const Text('취소'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton(
                    onPressed: () => Navigator.of(ctx).pop(controller.text),
                    child: const Text('저장'),
                  ),
                ),
              ],
            ),
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
                    const SizedBox(height: 12),
                    _buildActionGrid(context),
                    const SizedBox(height: 12),
                    _buildAutoShareCard(context),
                    const SizedBox(height: 16),
                    const Divider(height: 1),
                    const SizedBox(height: 10),
                    // 팀 나가기: 모든 멤버에게 노출. 마지막 리더는 DB(leave_group)에서
                    // 차단되며 그 사유가 스낵바로 안내된다.
                    // 한 스크롤 안에 그룹삭제까지 보이도록 버튼은 압축(dense) 스타일.
                    OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: const Color(0xFFB42318),
                        side: const BorderSide(color: Color(0xFFB42318)),
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        visualDensity: VisualDensity.compact,
                      ),
                      onPressed: _leaveGroup,
                      icon: const Icon(Icons.logout, size: 20),
                      label: const Text('팀 나가기'),
                    ),
                    if (_isLeader) ...[
                      const SizedBox(height: 8),
                      OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: const Color(0xFFB42318),
                          side: const BorderSide(color: Color(0xFFB42318)),
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          visualDensity: VisualDensity.compact,
                        ),
                        onPressed: _deleteGroup,
                        icon: const Icon(Icons.delete_outline, size: 20),
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
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    color: PlanFlowColors.primaryFaint,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(
                    Icons.groups_2_outlined,
                    color: PlanFlowColors.primary,
                    size: 18,
                  ),
                ),
                const SizedBox(width: 10),
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
                    visualDensity: VisualDensity.compact,
                  ),
              ],
            ),
            const SizedBox(height: 8),
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
        crossAxisSpacing: 8,
        mainAxisSpacing: 8,
        // 값을 키울수록 카드가 납작해짐: 4개 버튼 세로길이를 줄여 한 화면에
        // 팀 나가기/그룹 삭제까지 스크롤 없이 보이게 한다.
        childAspectRatio: 2.4,
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

  Widget _buildAutoShareCard(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    color: PlanFlowColors.primaryFaint,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(
                    Icons.publish_outlined,
                    color: PlanFlowColors.primary,
                    size: 18,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '이 그룹에 새 일정 자동 공유',
                        style:
                            Theme.of(context).textTheme.titleSmall?.copyWith(
                                  fontWeight: FontWeight.w700,
                                ),
                      ),
                      Text(
                        '켜면 새로 만드는 개인 일정이 기본으로 이 그룹에도 공유돼요.',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: PlanFlowColors.textSecondary,
                            ),
                      ),
                    ],
                  ),
                ),
                Switch(
                  value: _autoShareEnabled,
                  onChanged: _toggleAutoShare,
                ),
              ],
            ),
            const Divider(height: 16),
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '기존 일정 공유하기',
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                      ),
                      Text(
                        '오늘 이후의 내 개인 일정을 이 그룹에 지금 공유해요.',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: PlanFlowColors.textSecondary,
                            ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                OutlinedButton(
                  key: const ValueKey(
                      'group-detail-share-existing-events-button'),
                  style: OutlinedButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                  ),
                  onPressed: _isSharingExistingEvents
                      ? null
                      : _shareExistingEventsManually,
                  child: _isSharingExistingEvents
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('공유'),
                ),
              ],
            ),
          ],
        ),
      ),
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
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 22, color: PlanFlowColors.primary),
              const SizedBox(height: 4),
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
