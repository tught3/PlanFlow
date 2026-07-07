import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../core/constants.dart';
import '../../../core/local_time.dart';
import '../../../core/theme.dart';
import '../../../providers/auth_provider.dart';
import '../models/group_event_model.dart';
import '../models/group_member_model.dart';
import '../providers/group_member_provider.dart';
import '../providers/group_member_state.dart';
import '../repositories/group_event_repository.dart';
import 'group_event_list_screen.dart';

class GroupMemberScreen extends StatefulWidget {
  const GroupMemberScreen({
    super.key,
    GroupMemberProvider? provider,
    String? currentUserIdOverride,
    String? initialGroupId,
    GroupEventRepository? eventRepository,
  })  : _provider = provider,
        _currentUserIdOverride = currentUserIdOverride,
        _initialGroupId = initialGroupId,
        _eventRepository = eventRepository;

  final GroupMemberProvider? _provider;
  final String? _currentUserIdOverride;
  final String? _initialGroupId;
  final GroupEventRepository? _eventRepository;

  @override
  State<GroupMemberScreen> createState() => _GroupMemberScreenState();
}

class _GroupMemberScreenState extends State<GroupMemberScreen> {
  late final GroupMemberProvider _provider;
  late final bool _ownsProvider;
  late final GroupEventRepository _eventRepository;

  /// userId -> 해당 멤버가 만든(공유한) 일정 통계.
  Map<String, _MemberShareStats> _shareStatsByUserId =
      const <String, _MemberShareStats>{};

  @override
  void initState() {
    super.initState();
    _ownsProvider = widget._provider == null;
    _provider = widget._provider ?? GroupMemberProvider();
    _eventRepository =
        widget._eventRepository ?? GroupEventRepository.supabase();
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
    await _loadShareStats();
  }

  /// 현재 선택된 그룹의 일정을 불러와 멤버별 공유 건수/최근 활동일을 집계한다.
  /// 그룹이 없으면 통계를 비운다. 실패해도 멤버 목록 자체는 이미 로드됐으므로
  /// 화면 전체 에러로 확산시키지 않고 조용히 통계만 비운다.
  Future<void> _loadShareStats() async {
    final groupId = _provider.state.selectedGroup?.id;
    if (groupId == null) {
      if (mounted && _shareStatsByUserId.isNotEmpty) {
        setState(() {
          _shareStatsByUserId = const <String, _MemberShareStats>{};
        });
      }
      return;
    }

    try {
      final from = DateTime.utc(2000);
      final to = DateTime.utc(2100);
      final events = await _eventRepository.getEventsForGroup(
        groupId,
        from,
        to,
      );
      final stats = _aggregateShareStats(events);
      if (!mounted) {
        return;
      }
      setState(() {
        _shareStatsByUserId = stats;
      });
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _shareStatsByUserId = const <String, _MemberShareStats>{};
      });
    }
  }

  Map<String, _MemberShareStats> _aggregateShareStats(
    List<GroupEventModel> events,
  ) {
    final result = <String, _MemberShareStats>{};
    for (final event in events) {
      final activityAt = event.startAt;
      final existing = result[event.createdBy];
      if (existing == null) {
        result[event.createdBy] = _MemberShareStats(
          sharedCount: 1,
          lastActivityAt: activityAt,
        );
        continue;
      }
      final nextActivityAt = _laterOf(existing.lastActivityAt, activityAt);
      result[event.createdBy] = _MemberShareStats(
        sharedCount: existing.sharedCount + 1,
        lastActivityAt: nextActivityAt,
      );
    }
    return result;
  }

  DateTime? _laterOf(DateTime? a, DateTime? b) {
    if (a == null) {
      return b;
    }
    if (b == null) {
      return a;
    }
    return a.isAfter(b) ? a : b;
  }

  Future<void> _openGroupList() async {
    await context.push<String>(AppRoutes.groups);
    if (!mounted) {
      return;
    }
    await _load();
  }

  /// 멤버 타일을 탭하면 해당 멤버로 미리 필터링된 그룹 일정 목록을 연다.
  Future<void> _openMemberSchedule(GroupMemberModel member) async {
    final groupId = _provider.state.selectedGroup?.id;
    if (groupId == null) {
      return;
    }
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (context) => GroupEventListScreen(
          initialGroupId: groupId,
          initialMemberFilterUserId: member.userId,
        ),
      ),
    );
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
          actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          actions: [
            SizedBox(
              width: double.maxFinite,
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.of(context).pop(false),
                      child: const Text('취소'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: FilledButton(
                      onPressed: () => Navigator.of(context).pop(true),
                      child: const Text('제거'),
                    ),
                  ),
                ],
              ),
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

  /// 입력된 이름이 그룹 내 다른 멤버와 중복되는지 검사.
  /// 실제 화면/위젯에 보이는 이름(effectiveDisplayName: displayName이 없으면
  /// 프로필 이름/이메일/초대코드로 대체)을 기준으로 비교해야, displayName을
  /// 아직 설정하지 않은 멤버(프로필 이름만으로 표시 중)도 중복 검사에서 빠지지 않는다.
  /// 본인 기존 이름과 같으면 false(통과, 중복 아님).
  bool _isDuplicateDisplayName(String newName, GroupMemberModel member) {
    final normalized = newName.trim().toLowerCase();

    // 본인 기존(현재 화면에 보이는) 이름과 같으면 통과
    if (normalized == member.effectiveDisplayName.trim().toLowerCase()) {
      return false;
    }

    // 같은 그룹의 다른 멤버 중 같은 이름이 있으면 중복
    for (final otherMember in _provider.state.members) {
      if (otherMember.userId == member.userId) {
        continue;
      }
      if (normalized == otherMember.effectiveDisplayName.trim().toLowerCase()) {
        return true;
      }
    }
    return false;
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
            SizedBox(
              width: double.maxFinite,
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('취소'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: FilledButton(
                      onPressed: () =>
                          Navigator.of(context).pop(controller.text),
                      child: const Text('저장'),
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
    // 다이얼로그 pop 트랜지션(페이드/스케일 아웃)이 아직 진행 중일 수 있으므로
    // 여기서 즉시 dispose하지 않는다 — 트랜지션 중인 위젯이 여전히 이
    // controller를 참조하는 상태에서 dispose하면 "used after being disposed"
    // 예외가 날 수 있다. 현재 프레임이 끝난 뒤(다음 프레임 콜백)로 미룬다.
    WidgetsBinding.instance.addPostFrameCallback((_) => controller.dispose());
    if (displayName == null) {
      return;
    }

    // 중복 이름 검사
    if (_isDuplicateDisplayName(displayName, member)) {
      // 방금 닫힌 이름 변경 다이얼로그의 pop 트랜지션이 끝난 뒤 다음 다이얼로그를
      // 띄운다. 같은 프레임에서 바로 이어 showDialog를 호출하면 라우트 전환
      // 애니메이션이 겹쳐 불안정해질 수 있다.
      await Future<void>.delayed(Duration.zero);
      if (!mounted) {
        return;
      }
      await showDialog<void>(
        context: context,
        builder: (context) {
          return AlertDialog(
            title: const Text('이름이 중복되었습니다'),
            content: const Text('이미 있는 이름입니다. 다른 이름으로 변경해 주세요.'),
            actions: [
              SizedBox(
                width: double.maxFinite,
                child: OutlinedButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('확인'),
                ),
              ),
            ],
          );
        },
      );
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
                  shareStats: _shareStatsByUserId[member.userId],
                  onTap: () => _openMemberSchedule(member),
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
    required this.onTap,
    required this.onEditDisplayNamePressed,
    required this.onRemovePressed,
    this.shareStats,
  });

  final GroupMemberModel member;
  final bool canRemove;
  final bool canEditDisplayName;
  final VoidCallback onTap;
  final VoidCallback onEditDisplayNamePressed;
  final VoidCallback onRemovePressed;

  /// 이 멤버가 공유한 그룹 일정 집계. 아직 로드되지 않았거나 실패하면 null.
  final _MemberShareStats? shareStats;

  @override
  Widget build(BuildContext context) {
    final isRemoved = member.status == 'removed';
    return Material(
      color: isRemoved ? const Color(0xFFF8FAFC) : PlanFlowColors.surface,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        key: ValueKey<String>('group-member-tile-tap-${member.id}'),
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          decoration: BoxDecoration(
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
              const SizedBox(height: 6),
              Text(
                key: ValueKey<String>('group-member-share-stats-${member.id}'),
                _shareStatsLabel(shareStats),
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: PlanFlowColors.textSecondary,
                    ),
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
        ),
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

  /// 참여 가시성 요약 문구. 아직 로드 전(null)이거나 공유 이력이 없으면
  /// 리더가 비참여 멤버를 한눈에 알아볼 수 있게 안내 문구를 보여준다.
  String _shareStatsLabel(_MemberShareStats? stats) {
    if (stats == null || stats.sharedCount == 0) {
      return '아직 공유한 일정이 없어요';
    }
    final lastActivityAt = stats.lastActivityAt;
    if (lastActivityAt == null) {
      return '전체 공유 ${stats.sharedCount}건';
    }
    final local = planflowLocal(lastActivityAt);
    return '전체 공유 ${stats.sharedCount}건 · 최근 일정 ${local.month}월 ${local.day}일';
  }
}

/// 멤버별 그룹 일정 공유 집계(공유 건수 + 최근 활동 시각).
class _MemberShareStats {
  const _MemberShareStats({
    required this.sharedCount,
    this.lastActivityAt,
  });

  final int sharedCount;
  final DateTime? lastActivityAt;
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
