import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../core/local_time.dart';
import '../../../core/theme.dart';
import '../../../providers/auth_provider.dart';
import '../providers/group_event_provider.dart';
import '../providers/group_event_state.dart';

class GroupEventCreateScreen extends StatefulWidget {
  const GroupEventCreateScreen({
    super.key,
    GroupEventProvider? provider,
    String? currentUserIdOverride,
  })  : _provider = provider,
        _currentUserIdOverride = currentUserIdOverride;

  final GroupEventProvider? _provider;
  final String? _currentUserIdOverride;

  @override
  State<GroupEventCreateScreen> createState() => _GroupEventCreateScreenState();
}

class _GroupEventCreateScreenState extends State<GroupEventCreateScreen> {
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  late final TextEditingController _titleController;
  late final TextEditingController _descriptionController;
  late final TextEditingController _locationController;
  late final GroupEventProvider _provider;
  late final bool _ownsProvider;
  late DateTime _startAt;
  late DateTime _endAt;
  DateTime? _recurrenceUntil;
  String _recurrenceType = 'none';
  bool _allDay = false;
  bool _isSaving = false;
  String? _formError;

  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController();
    _descriptionController = TextEditingController();
    _locationController = TextEditingController();
    _ownsProvider = widget._provider == null;
    _provider = widget._provider ?? GroupEventProvider();
    final now = planflowNow().add(const Duration(hours: 1));
    _startAt = now;
    _endAt = now.add(const Duration(minutes: 30));
    unawaited(_load());
  }

  @override
  void dispose() {
    _titleController.dispose();
    _descriptionController.dispose();
    _locationController.dispose();
    if (_ownsProvider) {
      _provider.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    final userId = widget._currentUserIdOverride ?? authProvider.userId ?? '';
    await _provider.load(userId);
    final selectedGroup = _provider.selectedGroup;
    if (!mounted || selectedGroup == null) {
      return;
    }
  }

  Future<void> _submit() async {
    final valid = _formKey.currentState?.validate() ?? false;
    if (!valid) {
      return;
    }
    if (_endAt.isBefore(_startAt)) {
      setState(() {
        _formError = '종료 시각은 시작 시각보다 뒤여야 해요.';
      });
      return;
    }

    setState(() {
      _isSaving = true;
      _formError = null;
    });

    try {
      final created = await _provider.createGroupEvent(
        title: _titleController.text.trim(),
        description: _descriptionController.text.trim(),
        location: _locationController.text.trim(),
        startAt: _startAt,
        endAt: _endAt,
        allDay: _allDay,
        recurrenceType: _recurrenceType,
        recurrenceUntil: _recurrenceType == 'none' ? null : _recurrenceUntil,
      );
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('그룹 일정을 만들었어요.')),
      );
      await Future<void>.delayed(const Duration(milliseconds: 180));
      if (mounted) {
        context.pop(created.id);
      }
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _formError = error.toString();
      });
    } finally {
      if (mounted) {
        setState(() {
          _isSaving = false;
        });
      }
    }
  }

  Future<void> _pickStartDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _startAt,
      firstDate: DateTime.now().subtract(const Duration(days: 365)),
      lastDate: DateTime.now().add(const Duration(days: 365)),
    );
    if (picked == null || !mounted) {
      return;
    }
    setState(() {
      _startAt = DateTime(
        picked.year,
        picked.month,
        picked.day,
        _allDay ? 0 : _startAt.hour,
        _allDay ? 0 : _startAt.minute,
      );
      if (_endAt.isBefore(_startAt)) {
        _endAt = _startAt.add(const Duration(minutes: 30));
      }
    });
  }

  Future<void> _pickStartTime() async {
    if (_allDay) {
      return;
    }
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(_startAt),
    );
    if (picked == null || !mounted) {
      return;
    }
    setState(() {
      _startAt = DateTime(
        _startAt.year,
        _startAt.month,
        _startAt.day,
        picked.hour,
        picked.minute,
      );
      if (_endAt.isBefore(_startAt)) {
        _endAt = _startAt.add(const Duration(minutes: 30));
      }
    });
  }

  Future<void> _pickEndDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _endAt,
      firstDate: DateTime.now().subtract(const Duration(days: 365)),
      lastDate: DateTime.now().add(const Duration(days: 365)),
    );
    if (picked == null || !mounted) {
      return;
    }
    setState(() {
      _endAt = DateTime(
        picked.year,
        picked.month,
        picked.day,
        _allDay ? 23 : _endAt.hour,
        _allDay ? 59 : _endAt.minute,
      );
      if (_endAt.isBefore(_startAt)) {
        _startAt = _endAt.subtract(const Duration(minutes: 30));
      }
    });
  }

  Future<void> _pickEndTime() async {
    if (_allDay) {
      return;
    }
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(_endAt),
    );
    if (picked == null || !mounted) {
      return;
    }
    setState(() {
      _endAt = DateTime(
        _endAt.year,
        _endAt.month,
        _endAt.day,
        picked.hour,
        picked.minute,
      );
      if (_endAt.isBefore(_startAt)) {
        _startAt = _endAt.subtract(const Duration(minutes: 30));
      }
    });
  }

  Future<void> _pickRecurrenceUntil() async {
    final initial = _recurrenceUntil ?? _endAt;
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: _startAt,
      lastDate: DateTime.now().add(const Duration(days: 365 * 2)),
    );
    if (picked == null || !mounted) {
      return;
    }
    setState(() {
      _recurrenceUntil = picked;
    });
  }

  void _setAllDay(bool value) {
    setState(() {
      _allDay = value;
      if (value) {
        _startAt = DateTime(_startAt.year, _startAt.month, _startAt.day);
        _endAt = DateTime(
          _endAt.year,
          _endAt.month,
          _endAt.day,
          23,
          59,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _provider,
      builder: (context, _) {
        final state = _provider.state;
        final selectedGroup = state.selectedGroup;
        final canSubmit = selectedGroup != null &&
            state.canCreateEvent &&
            !_isSaving &&
            !_provider.isLoading;
        return Scaffold(
          appBar: AppBar(
            title: const Text('새 그룹 일정'),
          ),
          body: GestureDetector(
            onTap: () => FocusScope.of(context).unfocus(),
            child: RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                children: [
                  _buildSelectedGroupCard(context, state),
                  const SizedBox(height: 16),
                  if (state.error != null) ...[
                    _buildErrorCard(context, state.error!),
                    const SizedBox(height: 16),
                  ],
                  Form(
                    key: _formKey,
                    child: Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '그룹 일정 정보',
                              style: Theme.of(context)
                                  .textTheme
                                  .titleMedium
                                  ?.copyWith(fontWeight: FontWeight.w700),
                            ),
                            const SizedBox(height: 12),
                            TextFormField(
                              key: const ValueKey('group-event-title-field'),
                              controller: _titleController,
                              decoration: const InputDecoration(
                                labelText: '제목',
                                hintText: '예: 주간 팀 미팅',
                              ),
                              validator: (value) {
                                final text = value?.trim() ?? '';
                                if (text.isEmpty) {
                                  return '제목을 입력해 주세요.';
                                }
                                return null;
                              },
                            ),
                            const SizedBox(height: 12),
                            TextFormField(
                              key: const ValueKey(
                                  'group-event-description-field'),
                              controller: _descriptionController,
                              maxLines: 3,
                              decoration: const InputDecoration(
                                labelText: '설명',
                                hintText: '선택 입력',
                              ),
                            ),
                            const SizedBox(height: 12),
                            TextFormField(
                              key: const ValueKey('group-event-location-field'),
                              controller: _locationController,
                              decoration: const InputDecoration(
                                labelText: '장소',
                                hintText: '회의실, 온라인 링크 등',
                              ),
                            ),
                            const SizedBox(height: 12),
                            SwitchListTile.adaptive(
                              key: const ValueKey('group-event-all-day-switch'),
                              contentPadding: EdgeInsets.zero,
                              title: const Text('종일 일정'),
                              subtitle: const Text('하루 종일 표시할 일정이에요.'),
                              value: _allDay,
                              onChanged: _setAllDay,
                            ),
                            const SizedBox(height: 8),
                            _buildDateTimeRow(
                              context,
                              label: '시작',
                              dateText: _dateLabel(_startAt),
                              timeText: _allDay
                                  ? '종일'
                                  : _timeLabel(context, _startAt),
                              onDateTap: _pickStartDate,
                              onTimeTap: _pickStartTime,
                              timeEnabled: !_allDay,
                            ),
                            const SizedBox(height: 8),
                            _buildDateTimeRow(
                              context,
                              label: '종료',
                              dateText: _dateLabel(_endAt),
                              timeText:
                                  _allDay ? '종일' : _timeLabel(context, _endAt),
                              onDateTap: _pickEndDate,
                              onTimeTap: _pickEndTime,
                              timeEnabled: !_allDay,
                            ),
                            const SizedBox(height: 12),
                            DropdownButtonFormField<String>(
                              key: const ValueKey(
                                  'group-event-recurrence-field'),
                              initialValue: _recurrenceType,
                              decoration: const InputDecoration(
                                labelText: '반복',
                              ),
                              items: const [
                                DropdownMenuItem(
                                  value: 'none',
                                  child: Text('반복 없음'),
                                ),
                                DropdownMenuItem(
                                  value: 'daily',
                                  child: Text('매일'),
                                ),
                                DropdownMenuItem(
                                  value: 'weekly',
                                  child: Text('매주'),
                                ),
                                DropdownMenuItem(
                                  value: 'monthly',
                                  child: Text('매월'),
                                ),
                              ],
                              onChanged: (value) {
                                if (value == null) {
                                  return;
                                }
                                setState(() {
                                  _recurrenceType = value;
                                  if (value == 'none') {
                                    _recurrenceUntil = null;
                                  }
                                });
                              },
                            ),
                            if (_recurrenceType != 'none') ...[
                              const SizedBox(height: 12),
                              _buildDateTimeRow(
                                context,
                                label: '반복 종료',
                                dateText: _recurrenceUntil == null
                                    ? '미설정'
                                    : _dateLabel(_recurrenceUntil!),
                                timeText: '날짜만',
                                onDateTap: _pickRecurrenceUntil,
                                onTimeTap: null,
                                timeEnabled: false,
                              ),
                            ],
                            if (_formError != null) ...[
                              const SizedBox(height: 12),
                              _buildErrorCard(context, _formError!),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    key: const ValueKey('group-event-create-submit-button'),
                    onPressed: canSubmit ? _submit : null,
                    icon: _isSaving
                        ? const SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.event_available_outlined),
                    label: Text(_isSaving ? '생성 중...' : '그룹 일정 만들기'),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    selectedGroup == null
                        ? '먼저 그룹을 선택해야 일정을 만들 수 있어요.'
                        : state.canCreateEvent
                            ? '현재 선택된 그룹에 새 일정을 추가할 수 있어요.'
                            : '현재 그룹에서는 일정을 만들 수 없어요.',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: PlanFlowColors.textSecondary,
                        ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildSelectedGroupCard(BuildContext context, GroupEventState state) {
    final selectedGroup = state.selectedGroup;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.event_note_outlined),
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
                  : state.isLeaderOfSelectedGroup
                      ? '리더 권한으로 그룹 일정을 만들 수 있어요.'
                      : state.canCreateEvent
                          ? '위임 권한으로 그룹 일정을 만들 수 있어요.'
                          : '현재 그룹에서는 일정을 만들 수 없어요.',
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
                    label: state.selectedGroupRole == 'leader' ? '리더' : '멤버',
                  ),
                if (selectedGroup != null)
                  _InfoChip(label: _groupStatusLabel(selectedGroup.status)),
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

  Widget _buildDateTimeRow(
    BuildContext context, {
    required String label,
    required String dateText,
    required String timeText,
    required VoidCallback onDateTap,
    required VoidCallback? onTimeTap,
    required bool timeEnabled,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: Theme.of(context).textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: onDateTap,
                child: Text(dateText),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton(
                onPressed: timeEnabled ? onTimeTap : null,
                child: Text(timeText),
              ),
            ),
          ],
        ),
      ],
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

  String _groupStatusLabel(String status) {
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
