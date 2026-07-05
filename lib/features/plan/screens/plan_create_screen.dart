import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme.dart';
import '../../../providers/auth_provider.dart';
import '../models/plan_model.dart';
import '../providers/plan_provider.dart';

/// Plan 생성 화면. group_create_screen.dart 패턴을 따른다.
class PlanCreateScreen extends StatefulWidget {
  const PlanCreateScreen({
    super.key,
    PlanProvider? provider,
    String? currentUserIdOverride,
  })  : _provider = provider,
        _currentUserIdOverride = currentUserIdOverride;

  final PlanProvider? _provider;
  final String? _currentUserIdOverride;

  @override
  State<PlanCreateScreen> createState() => _PlanCreateScreenState();
}

class _PlanCreateScreenState extends State<PlanCreateScreen> {
  late final PlanProvider _provider;
  late final bool _ownsProvider;

  final _titleController = TextEditingController();
  final _descriptionController = TextEditingController();

  PlanPriority _priority = PlanPriority.medium;
  DateTime? _targetDate;
  bool _isSubmitting = false;

  String get _currentUserId =>
      widget._currentUserIdOverride ?? authProvider.userId ?? '';

  @override
  void initState() {
    super.initState();
    _ownsProvider = widget._provider == null;
    _provider = widget._provider ?? PlanProvider();
  }

  @override
  void dispose() {
    _titleController.dispose();
    _descriptionController.dispose();
    if (_ownsProvider) {
      _provider.dispose();
    }
    super.dispose();
  }

  bool get _canSubmit =>
      _titleController.text.trim().isNotEmpty && !_isSubmitting;

  Future<void> _pickTargetDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _targetDate ?? now,
      firstDate: DateTime(now.year - 5),
      lastDate: DateTime(now.year + 10),
    );
    if (picked != null) {
      setState(() => _targetDate = picked);
    }
  }

  Future<void> _submit() async {
    final title = _titleController.text.trim();
    if (title.isEmpty) return;
    setState(() => _isSubmitting = true);
    try {
      await _provider.createPlan(
        title: title,
        description: _descriptionController.text.trim(),
        priority: _priority,
        targetDate: _targetDate,
      );
      if (!mounted) return;
      Navigator.of(context).pop('created');
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('생성 실패: $error')),
      );
    } finally {
      if (mounted) {
        setState(() => _isSubmitting = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('새 계획'),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              key: const ValueKey('plan-create-title-field'),
              controller: _titleController,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: '제목',
                hintText: '무엇을 계획하고 있나요?',
              ),
              textInputAction: TextInputAction.next,
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 16),
            TextField(
              key: const ValueKey('plan-create-description-field'),
              controller: _descriptionController,
              maxLines: 3,
              decoration: const InputDecoration(
                labelText: '설명(선택)',
                hintText: '자세한 내용을 적어보세요.',
              ),
            ),
            const SizedBox(height: 20),
            Text(
              '우선순위',
              style: Theme.of(context).textTheme.labelLarge?.copyWith(
                    color: PlanFlowColors.textSecondary,
                  ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: PlanPriority.values.map((priority) {
                final selected = priority == _priority;
                return ChoiceChip(
                  label: Text(_priorityLabel(priority)),
                  selected: selected,
                  onSelected: (_) => setState(() => _priority = priority),
                );
              }).toList(),
            ),
            const SizedBox(height: 20),
            Text(
              '목표일(선택)',
              style: Theme.of(context).textTheme.labelLarge?.copyWith(
                    color: PlanFlowColors.textSecondary,
                  ),
            ),
            const SizedBox(height: 8),
            InkWell(
              onTap: _pickTargetDate,
              borderRadius: BorderRadius.circular(10),
              child: InputDecorator(
                decoration: const InputDecoration(
                  suffixIcon: Icon(Icons.calendar_today_outlined),
                ),
                child: Text(
                  _targetDate != null
                      ? _formatDate(_targetDate!)
                      : '날짜 선택 안 함',
                  style: TextStyle(
                    color: _targetDate != null
                        ? PlanFlowColors.textPrimary
                        : PlanFlowColors.primaryLight,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 28),
            SizedBox(
              width: double.maxFinite,
              child: FilledButton.icon(
                key: const ValueKey('plan-create-submit-button'),
                onPressed: _canSubmit ? _submit : null,
                icon: const Icon(Icons.check),
                label: const Text('계획 만들기'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _priorityLabel(PlanPriority priority) {
    return switch (priority) {
      PlanPriority.high => '높음 🔴',
      PlanPriority.medium => '보통 🔵',
      PlanPriority.low => '낮음 ⚪',
    };
  }

  String _formatDate(DateTime date) {
    return '${date.year}.${date.month.toString().padLeft(2, '0')}.'
        '${date.day.toString().padLeft(2, '0')}';
  }
}
