import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/local_time.dart';
import '../../../core/theme.dart';
import '../../../providers/auth_provider.dart';
import '../models/group_event_model.dart';
import '../providers/group_event_provider.dart';

class GroupEventDetailScreen extends StatefulWidget {
  const GroupEventDetailScreen({
    super.key,
    required this.eventId,
    this.event,
    GroupEventProvider? provider,
    String? currentUserIdOverride,
  })  : _provider = provider,
        _currentUserIdOverride = currentUserIdOverride;

  final String eventId;
  final GroupEventModel? event;
  final GroupEventProvider? _provider;
  final String? _currentUserIdOverride;

  @override
  State<GroupEventDetailScreen> createState() => _GroupEventDetailScreenState();
}

class _GroupEventDetailScreenState extends State<GroupEventDetailScreen> {
  late final GroupEventProvider _provider;
  late final bool _ownsProvider;
  GroupEventModel? _event;
  bool _isLoading = false;
  bool _isBusy = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _ownsProvider = widget._provider == null;
    _provider = widget._provider ?? GroupEventProvider();
    _event = widget.event;
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
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });
    try {
      await _provider.load(userId);
      if (!mounted) {
        return;
      }
      if (_event == null) {
        if (widget.eventId.trim().isEmpty) {
          setState(() {
            _errorMessage = '이벤트 정보를 찾지 못했어요.';
          });
        } else {
          final loaded = await _provider.fetchGroupEvent(widget.eventId);
          if (!mounted) {
            return;
          }
          setState(() {
            _event = loaded;
          });
        }
      }
    } catch (error) {
      if (!mounted) {
        return;
      }
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

  Future<void> _cancelEvent() async {
    final event = _event;
    if (event == null) {
      return;
    }
    setState(() {
      _isBusy = true;
    });
    try {
      final cancelled = await _provider.cancelGroupEvent(event.id);
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('그룹 일정을 취소했어요.')),
      );
      await Future<void>.delayed(const Duration(milliseconds: 180));
      if (mounted) {
        Navigator.of(context).pop(true);
      }
      _event = cancelled;
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _errorMessage = error.toString();
      });
    } finally {
      if (mounted) {
        setState(() {
          _isBusy = false;
        });
      }
    }
  }

  Future<void> _archiveEvent() async {
    final event = _event;
    if (event == null) {
      return;
    }
    setState(() {
      _isBusy = true;
    });
    try {
      final archived = await _provider.archiveGroupEvent(event.id);
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('그룹 일정을 보관했어요.')),
      );
      await Future<void>.delayed(const Duration(milliseconds: 180));
      if (mounted) {
        Navigator.of(context).pop(true);
      }
      _event = archived;
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _errorMessage = error.toString();
      });
    } finally {
      if (mounted) {
        setState(() {
          _isBusy = false;
        });
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
                _StatusChip(status: event.status),
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
            _DetailRow(label: '작성자', value: event.createdBy),
            if (event.updatedBy != null)
              _DetailRow(label: '수정자', value: event.updatedBy!),
            if (event.cancelledBy != null)
              _DetailRow(label: '취소자', value: event.cancelledBy!),
          ],
        ),
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
