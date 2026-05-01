import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/constants.dart';

class EventEditScreen extends StatefulWidget {
  const EventEditScreen({super.key});

  @override
  State<EventEditScreen> createState() => _EventEditScreenState();
}

class _EventEditScreenState extends State<EventEditScreen> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _titleController;
  late final TextEditingController _timeController;
  late final TextEditingController _locationController;
  late final TextEditingController _memoController;
  late final TextEditingController _suppliesController;
  bool _critical = true;

  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController(text: '주간 영업 미팅');
    _timeController = TextEditingController(text: '2026-05-01 14:00 - 15:00');
    _locationController = TextEditingController(text: '서울역 인근 회의실 A');
    _memoController = TextEditingController(
      text: '이번 주 우선순위 고객과 진행 상황을 정리하고, 다음 액션을 확정합니다.',
    );
    _suppliesController = TextEditingController(text: '노트북, 충전기, 명함, 회의 자료');
  }

  @override
  void dispose() {
    _titleController.dispose();
    _timeController.dispose();
    _locationController.dispose();
    _memoController.dispose();
    _suppliesController.dispose();
    super.dispose();
  }

  void _handleSave() {
    final isValid = _formKey.currentState?.validate() ?? false;
    if (!isValid) {
      return;
    }

    if (!mounted) {
      return;
    }

    context.go(AppRoutes.eventDetail);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('이벤트 편집')),
      body: SafeArea(
        child: Form(
          key: _formKey,
          child: ListView(
            padding: const EdgeInsets.all(AppConstants.defaultPadding),
            children: [
              Text(
                '필요한 정보만 수정하고 저장하세요.',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: AppConstants.sectionSpacing),
              TextFormField(
                controller: _titleController,
                decoration: const InputDecoration(
                  labelText: '제목',
                  border: OutlineInputBorder(),
                ),
                validator: (value) => (value == null || value.trim().isEmpty)
                    ? '제목을 입력하세요.'
                    : null,
              ),
              const SizedBox(height: AppConstants.sectionSpacing),
              TextFormField(
                controller: _timeController,
                decoration: const InputDecoration(
                  labelText: '시간',
                  border: OutlineInputBorder(),
                ),
                validator: (value) => (value == null || value.trim().isEmpty)
                    ? '시간을 입력하세요.'
                    : null,
              ),
              const SizedBox(height: AppConstants.sectionSpacing),
              TextFormField(
                controller: _locationController,
                decoration: const InputDecoration(
                  labelText: '장소',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: AppConstants.sectionSpacing),
              TextFormField(
                controller: _memoController,
                decoration: const InputDecoration(
                  labelText: '메모',
                  border: OutlineInputBorder(),
                  alignLabelWithHint: true,
                ),
                minLines: 3,
                maxLines: 5,
              ),
              const SizedBox(height: AppConstants.sectionSpacing),
              TextFormField(
                controller: _suppliesController,
                decoration: const InputDecoration(
                  labelText: '준비물',
                  helperText: '쉼표로 구분해서 입력하세요.',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: AppConstants.sectionSpacing),
              SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                title: const Text('중요 일정'),
                subtitle: const Text('핵심 일정 여부를 표시합니다.'),
                value: _critical,
                onChanged: (value) {
                  setState(() {
                    _critical = value;
                  });
                },
              ),
              const SizedBox(height: AppConstants.sectionSpacing),
              FilledButton.icon(
                onPressed: _handleSave,
                icon: const Icon(Icons.save_outlined),
                label: const Text('저장'),
              ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: () => context.go(AppRoutes.eventDetail),
                child: const Text('상세로 돌아가기'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
