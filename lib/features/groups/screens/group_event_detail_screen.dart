import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/env.dart';
import '../../../core/local_time.dart';
import '../../../core/theme.dart';
import '../../../providers/auth_provider.dart';
import '../models/group_event_comment_model.dart';
import '../models/group_event_model.dart';
import '../providers/group_event_provider.dart';
import '../repositories/group_event_comment_repository.dart';
import '../repositories/group_repository.dart';

class GroupEventDetailScreen extends StatefulWidget {
  const GroupEventDetailScreen({
    super.key,
    required this.eventId,
    this.event,
    GroupEventProvider? provider,
    String? currentUserIdOverride,
    GroupRepository? groupRepository,
    GroupEventCommentRepository? commentRepository,
  })  : _provider = provider,
        _currentUserIdOverride = currentUserIdOverride,
        _groupRepository = groupRepository,
        _commentRepository = commentRepository;

  final String eventId;
  final GroupEventModel? event;
  final GroupEventProvider? _provider;
  final String? _currentUserIdOverride;
  final GroupRepository? _groupRepository;
  final GroupEventCommentRepository? _commentRepository;

  @override
  State<GroupEventDetailScreen> createState() => _GroupEventDetailScreenState();
}

class _GroupEventDetailScreenState extends State<GroupEventDetailScreen> {
  late final GroupEventProvider _provider;
  late final bool _ownsProvider;
  // Supabase 레포는 실제 로드 시점에만 생성한다(테스트 등 미초기화 환경에서
  // initState가 Supabase.instance를 만지지 않도록).
  GroupRepository? _groupRepositoryCache;
  GroupRepository get _groupRepository => _groupRepositoryCache ??=
      widget._groupRepository ?? GroupRepository.supabase();
  GroupEventCommentRepository? _commentRepositoryCache;
  GroupEventCommentRepository get _commentRepository => _commentRepositoryCache ??=
      widget._commentRepository ?? GroupEventCommentRepository.supabase();

  GroupEventModel? _event;
  bool _isLoading = false;
  bool _isBusy = false;
  String? _errorMessage;

  /// userId -> 표시 이름 맵
  Map<String, String> _memberNames = const {};
  String? _loadedGroupId;

  /// 리더 지시 댓글 목록
  List<GroupEventCommentModel> _comments = const [];
  bool _commentsLoading = false;
  String? _commentsError;

  /// 지시 입력 컨트롤러 (리더용)
  late final TextEditingController _commentController;
  bool _isSubmittingComment = false;

  String get _currentUserId =>
      widget._currentUserIdOverride ?? authProvider.userId ?? '';

  @override
  void initState() {
    super.initState();
    _ownsProvider = widget._provider == null;
    _provider = widget._provider ?? GroupEventProvider();
    _commentController = TextEditingController();
    _event = widget.event;
    unawaited(_load());
  }

  @override
  void dispose() {
    _commentController.dispose();
    if (_ownsProvider) {
      _provider.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    final userId = _currentUserId;
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });
    try {
      await _provider.load(userId);
      if (!mounted) return;
      if (_event == null) {
        if (widget.eventId.trim().isEmpty) {
          setState(() {
            _errorMessage = '이벤트 정보를 찾지 못했어요.';
          });
        } else {
          final loaded = await _provider.fetchGroupEvent(widget.eventId);
          if (!mounted) return;
          setState(() {
            _event = loaded;
          });
        }
      }
      // 멤버 이름 맵 / 댓글은 화면 렌더를 막지 않도록 배경 로드한다.
      unawaited(_maybeLoadMemberNames());
      unawaited(_loadComments());
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _errorMessage = error.toString();
      });
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  /// 그룹 멤버 이름 맵 로드 (group_event_list_screen.dart 패턴과 동일)
  Future<void> _maybeLoadMemberNames() async {
    // 테스트 등 Supabase 미초기화 환경(주입된 fake 없음)에서는 스킵.
    if (!AppEnv.isSupabaseReady && widget._groupRepository == null) return;
    final event = _event;
    if (event == null) return;
    final groupId = event.groupId;
    if (groupId == _loadedGroupId) return;
    _loadedGroupId = groupId;
    try {
      final members = await _groupRepository.listMembers(groupId);
      final map = {for (final m in members) m.userId: m.effectiveDisplayName};
      if (mounted) {
        setState(() => _memberNames = map);
      }
    } catch (_) {
      if (mounted) {
        setState(() => _memberNames = const {});
      }
    }
  }

  /// 공유자 표시 이름: 멤버 맵 우선, 없으면 userId 앞 8자
  String _resolveDisplayName(String userId) {
    final name = _memberNames[userId];
    if (name != null && name.isNotEmpty) return name;
    return userId.length > 8 ? userId.substring(0, 8) : userId;
  }

  /// 리더 지시 댓글 로드
  Future<void> _loadComments() async {
    // 테스트 등 Supabase 미초기화 환경(주입된 fake 없음)에서는 스킵.
    if (!AppEnv.isSupabaseReady && widget._commentRepository == null) return;
    final event = _event;
    if (event == null) return;
    setState(() {
      _commentsLoading = true;
      _commentsError = null;
    });
    try {
      final comments =
          await _commentRepository.getCommentsForEvent(event.id);
      if (!mounted) return;
      setState(() {
        _comments = comments;
        _commentsLoading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _commentsError = error.toString();
        _commentsLoading = false;
      });
    }
  }

  /// 리더: 지시 추가
  Future<void> _submitComment() async {
    final event = _event;
    if (event == null) return;
    final text = _commentController.text.trim();
    if (text.isEmpty) return;
    setState(() => _isSubmittingComment = true);
    try {
      final model = GroupEventCommentModel(
        id: '',
        groupEventId: event.id,
        groupId: event.groupId,
        authorUserId: _currentUserId,
        targetUserId: event.createdBy,
        content: text,
        createdAt: DateTime.now(),
      );
      await _commentRepository.createComment(model);
      if (!mounted) return;
      _commentController.clear();
      await _loadComments();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('지시 추가 실패: $error')),
      );
    } finally {
      if (mounted) {
        setState(() => _isSubmittingComment = false);
      }
    }
  }

  /// 공유자(target): 댓글 확인 처리
  Future<void> _confirmComment(GroupEventCommentModel comment) async {
    try {
      await _commentRepository.confirmComment(comment.id);
      if (!mounted) return;
      await _loadComments();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('확인 처리 실패: $error')),
      );
    }
  }

  Future<void> _cancelEvent() async {
    final event = _event;
    if (event == null) return;
    setState(() => _isBusy = true);
    try {
      final cancelled = await _provider.cancelGroupEvent(event.id);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('그룹 일정을 취소했어요.')),
      );
      await Future<void>.delayed(const Duration(milliseconds: 180));
      if (mounted) Navigator.of(context).pop('cancelled');
      _event = cancelled;
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _errorMessage = error.toString();
      });
    } finally {
      if (mounted) {
        setState(() => _isBusy = false);
      }
    }
  }

  Future<void> _archiveEvent() async {
    final event = _event;
    if (event == null) return;
    setState(() => _isBusy = true);
    try {
      final archived = await _provider.archiveGroupEvent(event.id);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('그룹 일정을 보관했어요.')),
      );
      await Future<void>.delayed(const Duration(milliseconds: 180));
      if (mounted) Navigator.of(context).pop('archived');
      _event = archived;
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _errorMessage = error.toString();
      });
    } finally {
      if (mounted) {
        setState(() => _isBusy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _provider,
      builder: (context, _) {
        final event = _event;
        final canCancel = event != null && _provider.canCancelGroupEvent(event);
        final canArchive =
            event != null && _provider.canArchiveGroupEvent(event);
        return Scaffold(
          appBar: AppBar(
            title: const Text('그룹 일정 상세'),
            actions: [
              IconButton(
                tooltip: '새로고침',
                onPressed: _isLoading ? null : _load,
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
                _buildSelectedGroupCard(context),
                const SizedBox(height: 16),
                if (_isLoading && event == null) ...[
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 56),
                    child: Center(child: CircularProgressIndicator()),
                  ),
                ] else if (_errorMessage != null) ...[
                  _buildErrorCard(context, _errorMessage!),
                ] else if (event != null) ...[
                  _buildEventCard(context, event),
                  const SizedBox(height: 16),
                  if (event.isActive && (canCancel || canArchive))
                    _buildActionCard(
                      context,
                      canCancel: canCancel,
                      canArchive: canArchive,
                    )
                  else if (event.isActive)
                    _buildInfoCard(
                      context,
                      '현재 그룹에서 이 일정에 대한 수정 권한이 없어요.',
                    )
                  else
                    _buildInfoCard(
                      context,
                      '취소되거나 보관된 일정은 추가 액션을 할 수 없어요.',
                    ),
                  const SizedBox(height: 16),
                  _buildCommentSection(context, event),
                ] else ...[
                  _buildInfoCard(
                    context,
                    '선택한 그룹 일정 정보를 찾지 못했어요.',
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildSelectedGroupCard(BuildContext context) {
    final selectedGroup = _provider.selectedGroup;
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
              ],
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
                  ? '그룹을 먼저 선택해 주세요.'
                  : _provider.isLeaderOfSelectedGroup
                      ? '리더 권한으로 그룹 일정을 보고 있어요.'
                      : '멤버 권한으로 그룹 일정을 보고 있어요.',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: PlanFlowColors.textSecondary,
                  ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEventCard(BuildContext context, GroupEventModel event) {
    final localStart = planflowLocal(event.startAt);
    final localEnd = planflowLocal(event.endAt);
    // 공유자 이름 resolve
    final sharerName = _resolveDisplayName(event.createdBy);
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
                    event.title,
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                  ),
                ),
                // TASK 1: 'active' 상태일 때는 칩 숨김 (group_event_tile.dart 패턴 동일)
                if (event.status != 'active') _StatusChip(status: event.status),
              ],
            ),
            const SizedBox(height: 12),
            _DetailRow(
              label: '시간',
              value: event.allDay
                  ? '종일'
                  : localStart.year == localEnd.year &&
                          localStart.month == localEnd.month &&
                          localStart.day == localEnd.day
                      ? '${_timeLabel(context, localStart)} - ${_timeLabel(context, localEnd)}'
                      : '${_dateLabel(localStart)} ${_timeLabel(context, localStart)} - ${_dateLabel(localEnd)} ${_timeLabel(context, localEnd)}',
            ),
            if ((event.description ?? '').trim().isNotEmpty)
              _DetailRow(label: '설명', value: event.description!.trim()),
            if ((event.location ?? '').trim().isNotEmpty)
              _DetailRow(label: '장소', value: event.location!.trim()),
            _DetailRow(
              label: '반복',
              value: switch (event.recurrenceType) {
                'none' => '반복 없음',
                'daily' => '매일',
                'weekly' => '매주',
                'monthly' => '매월',
                _ => event.recurrenceType,
              },
            ),
            if (event.recurrenceUntil != null)
              _DetailRow(
                label: '반복 종료',
                value: _dateLabel(planflowLocal(event.recurrenceUntil!)),
              ),
            _DetailRow(label: '종일', value: event.allDay ? '예' : '아니오'),
            // TASK 2: '작성자' -> '공유자', raw id -> resolved 이름
            _DetailRow(label: '공유자', value: sharerName),
            if (event.updatedBy != null)
              _DetailRow(
                label: '수정자',
                value: _resolveDisplayName(event.updatedBy!),
              ),
            if (event.cancelledBy != null)
              _DetailRow(
                label: '취소자',
                value: _resolveDisplayName(event.cancelledBy!),
              ),
          ],
        ),
      ),
    );
  }

  // TASK 3: 리더 지시 섹션
  Widget _buildCommentSection(BuildContext context, GroupEventModel event) {
    final isLeader = _provider.isLeaderOfSelectedGroup;
    final isSharer = _currentUserId == event.createdBy;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.assignment_outlined),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '리더 지시',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                  ),
                ),
                if (_commentsLoading)
                  const SizedBox.square(
                    dimension: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            // 댓글 에러
            if (_commentsError != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  _commentsError!,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: const Color(0xFF7A271A),
                      ),
                ),
              ),
            // 댓글 목록
            if (_comments.isEmpty && !_commentsLoading)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Center(
                  child: Text(
                    '아직 리더 지시가 없어요.',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: PlanFlowColors.textSecondary,
                        ),
                  ),
                ),
              )
            else
              ListView.separated(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: _comments.length,
                separatorBuilder: (_, __) => const SizedBox(height: 8),
                itemBuilder: (context, index) {
                  final comment = _comments[index];
                  return _buildCommentItem(
                    context,
                    comment: comment,
                    isSharer: isSharer,
                  );
                },
              ),
            // 리더: 지시 입력 폼 (단, 자신이 만든 일정에는 지시 불가)
            if (isLeader && !isSharer) ...[
              const SizedBox(height: 12),
              const Divider(),
              const SizedBox(height: 8),
              Text(
                '지시 추가',
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
              ),
              const SizedBox(height: 8),
              TextField(
                key: const ValueKey('group-event-comment-input'),
                controller: _commentController,
                maxLines: 3,
                decoration: const InputDecoration(
                  hintText: '지시 내용을 입력하세요.',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  key: const ValueKey('group-event-comment-submit-button'),
                  onPressed: _isSubmittingComment ? null : _submitComment,
                  icon: _isSubmittingComment
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.send_outlined),
                  label: Text(_isSubmittingComment ? '전송 중...' : '지시 추가'),
                ),
              ),
            ] else if (isLeader && isSharer) ...[
              const SizedBox(height: 12),
              const Divider(),
              const SizedBox(height: 8),
              Text(
                '내가 만든 일정에는 지시를 남길 수 없어요.',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: PlanFlowColors.textSecondary,
                    ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildCommentItem(
    BuildContext context, {
    required GroupEventCommentModel comment,
    required bool isSharer,
  }) {
    final authorName = _resolveDisplayName(comment.authorUserId);
    final timeLabel = _commentTimeLabel(comment.createdAt ?? DateTime.now());
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: PlanFlowColors.tagNormalBg,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.person_outline,
                size: 14,
                color: PlanFlowColors.textSecondary,
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  '$authorName · $timeLabel',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: PlanFlowColors.textSecondary,
                        fontWeight: FontWeight.w600,
                      ),
                ),
              ),
              // 확인 상태 표시
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: comment.isConfirmed
                      ? PlanFlowColors.tagDoneBg
                      : PlanFlowColors.tagNormalBg,
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(
                    color: comment.isConfirmed
                        ? PlanFlowColors.tagDoneText
                        : PlanFlowColors.textSecondary,
                    width: 0.8,
                  ),
                ),
                child: Text(
                  comment.isConfirmed ? '확인함' : '미확인',
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: comment.isConfirmed
                            ? PlanFlowColors.tagDoneText
                            : PlanFlowColors.textSecondary,
                        fontWeight: FontWeight.w700,
                      ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            comment.content,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          // 공유자이고 미확인 댓글이면 확인 버튼 표시
          if (isSharer && !comment.isConfirmed) ...[
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: OutlinedButton.icon(
                key: ValueKey('confirm-comment-${comment.id}'),
                onPressed: () => _confirmComment(comment),
                icon: const Icon(Icons.check_circle_outline, size: 16),
                label: const Text('확인'),
                style: OutlinedButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildActionCard(
    BuildContext context, {
    required bool canCancel,
    required bool canArchive,
  }) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '일정 관리',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                if (canCancel)
                  Expanded(
                    child: FilledButton(
                      key: const ValueKey('group-event-detail-cancel-button'),
                      onPressed: _isBusy ? null : _cancelEvent,
                      child: _isBusy
                          ? const SizedBox.square(
                              dimension: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Text('취소'),
                    ),
                  ),
                if (canCancel && canArchive) const SizedBox(width: 8),
                if (canArchive)
                  Expanded(
                    child: OutlinedButton(
                      key: const ValueKey('group-event-detail-archive-button'),
                      onPressed: _isBusy ? null : _archiveEvent,
                      child: const Text('보관'),
                    ),
                  ),
              ],
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
        child: Text(
          error,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: const Color(0xFF7A271A),
              ),
        ),
      ),
    );
  }

  Widget _buildInfoCard(BuildContext context, String message) {
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

  String _dateLabel(DateTime value) {
    return '${value.year}.${value.month.toString().padLeft(2, '0')}.${value.day.toString().padLeft(2, '0')} (${_weekdayLabel(value.weekday)})';
  }

  String _timeLabel(BuildContext context, DateTime value) {
    return MaterialLocalizations.of(context).formatTimeOfDay(
      TimeOfDay.fromDateTime(value),
      alwaysUse24HourFormat: false,
    );
  }

  String _weekdayLabel(int weekday) {
    return switch (weekday) {
      DateTime.monday => '월',
      DateTime.tuesday => '화',
      DateTime.wednesday => '수',
      DateTime.thursday => '목',
      DateTime.friday => '금',
      DateTime.saturday => '토',
      _ => '일',
    };
  }

  String _commentTimeLabel(DateTime dt) {
    final local = dt.toLocal();
    return '${local.year}.${local.month.toString().padLeft(2, '0')}.${local.day.toString().padLeft(2, '0')} '
        '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
  }
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({
    required this.label,
    required this.value,
  });

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 86,
            child: Text(
              label,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: PlanFlowColors.textSecondary,
                    fontWeight: FontWeight.w700,
                  ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
        ],
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
      'active' => '활성',
      'cancelled' => '취소됨',
      'archived' => '보관됨',
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
