import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/constants.dart';
import '../../core/theme.dart';
import '../../services/event_refresh_bus.dart';
import '../../services/naver_calendar_launch_service.dart';
import '../../services/naver_ics_import_service.dart';

class NaverIcsImportScreen extends StatefulWidget {
  const NaverIcsImportScreen({
    super.key,
    this.initialPaths = const <String>[],
    NaverIcsImportService? importService,
    NaverCalendarLaunchService? launchService,
  })  : _importService = importService,
        _launchService = launchService;

  final List<String> initialPaths;
  final NaverIcsImportService? _importService;
  final NaverCalendarLaunchService? _launchService;

  @override
  State<NaverIcsImportScreen> createState() => _NaverIcsImportScreenState();
}

class _NaverIcsImportScreenState extends State<NaverIcsImportScreen> {
  late final NaverIcsImportService _importService;
  late final NaverCalendarLaunchService _launchService;
  final PageController _pageController = PageController();

  bool _isImporting = false;
  bool _isPickingFile = false;
  NaverIcsImportResult? _lastResult;

  @override
  void initState() {
    super.initState();
    _importService = widget._importService ?? NaverIcsImportService();
    _launchService =
        widget._launchService ?? const NaverCalendarLaunchService();
    if (widget.initialPaths.isNotEmpty) {
      unawaited(_importPaths(widget.initialPaths));
    }
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  Future<void> _openNaverCalendar() async {
    final result = await _launchService.openNaverCalendar();
    if (!mounted) {
      return;
    }
    _showSnack(result.message);
  }

  Future<void> _pickIcsFile() async {
    if (_isPickingFile || _isImporting) {
      return;
    }
    setState(() {
      _isPickingFile = true;
    });
    try {
      final picked = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: const <String>['ics'],
        allowMultiple: true,
      );
      final paths = picked?.files
              .map((file) => file.path)
              .whereType<String>()
              .where((path) => path.trim().isNotEmpty)
              .toList(growable: false) ??
          const <String>[];
      if (paths.isEmpty) {
        return;
      }
      await _importPaths(paths);
    } finally {
      if (mounted) {
        setState(() {
          _isPickingFile = false;
        });
      }
    }
  }

  Future<void> _importPaths(List<String> paths) async {
    if (_isImporting) {
      return;
    }
    setState(() {
      _isImporting = true;
      _lastResult = null;
    });

    var merged = const NaverIcsImportResult(
      success: false,
      message: '아직 가져온 일정이 없습니다.',
    );
    for (final path in paths) {
      final result = await _importService.importFile(path);
      merged = merged.merge(result);
    }

    if (!mounted) {
      return;
    }
    setState(() {
      _lastResult = merged;
      _isImporting = false;
    });
    _showSnack(merged.message);
    if (merged.imported > 0 || merged.skipped > 0) {
      EventRefreshBus.instance.notifyChanged(reason: 'naver_ics_import');
    }
  }

  void _showSnack(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('네이버 캘린더 가져오기'),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          children: [
            _IntroCard(theme: theme),
            const SizedBox(height: 16),
            _GuidePager(controller: _pageController),
            const SizedBox(height: 16),
            _ImportActions(
              isImporting: _isImporting,
              isPickingFile: _isPickingFile,
              onOpenNaver: _openNaverCalendar,
              onPickFile: _pickIcsFile,
            ),
            const SizedBox(height: 16),
            if (_isImporting)
              const _ProgressCard()
            else if (_lastResult != null)
              _ResultCard(result: _lastResult!),
            const SizedBox(height: 24),
            TextButton.icon(
              onPressed: () {
                // 공유/알람으로 go 진입한 경우 스택이 없어 pop이 안 먹으므로
                // 그때는 설정 화면으로 명시 이동한다.
                if (context.canPop()) {
                  context.pop();
                } else {
                  context.go(AppRoutes.settings);
                }
              },
              icon: const Icon(Icons.arrow_back),
              label: const Text('설정으로 돌아가기'),
            ),
          ],
        ),
      ),
    );
  }
}

class _IntroCard extends StatelessWidget {
  const _IntroCard({required this.theme});

  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    return Card(
      color: const Color(0xFFFFF4E8),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: const BorderSide(color: Color(0xFFEAB992)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.75),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(
                    Icons.ios_share_outlined,
                    color: Color(0xFFB85F3B),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    '네이버에서 공유하면 PlanFlow가 자동으로 저장해요',
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: PlanFlowColors.primary,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            const Text(
              '수동으로 해야 하는 일은 딱 두 번입니다. 네이버 캘린더에서 내보내기 화면을 열고, 공유 대상에서 PlanFlow를 선택해 주세요.',
            ),
          ],
        ),
      ),
    );
  }
}

class _GuidePager extends StatelessWidget {
  const _GuidePager({required this.controller});

  final PageController controller;

  @override
  Widget build(BuildContext context) {
    final steps = const <_GuideStep>[
      _GuideStep(
        icon: Icons.open_in_new,
        title: '1. 네이버 캘린더 앱 열기',
        body: '아래 버튼으로 네이버 캘린더 앱을 열고, 메뉴에서 내보내기 화면으로 이동합니다.',
      ),
      _GuideStep(
        icon: Icons.ios_share,
        title: '2. 공유 탭 선택',
        body: '내보내기에서 파일 저장이 아니라 공유 탭을 선택합니다.',
      ),
      _GuideStep(
        icon: Icons.check_circle_outline,
        title: '3. PlanFlow 선택',
        body: '공유 대상에서 PlanFlow를 선택하면 ICS 파일을 자동으로 읽고 중복 없이 저장합니다.',
      ),
    ];
    return SizedBox(
      height: 188,
      child: PageView.builder(
        controller: controller,
        itemCount: steps.length,
        itemBuilder: (context, index) {
          final step = steps[index];
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2),
            child: Card(
              elevation: 0,
              color: PlanFlowColors.surface,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
                side: const BorderSide(color: PlanFlowColors.primaryFaint),
              ),
              child: Padding(
                padding: const EdgeInsets.all(18),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(step.icon, color: PlanFlowColors.primaryMid),
                    const SizedBox(height: 12),
                    Text(
                      step.title,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            color: PlanFlowColors.primary,
                            fontWeight: FontWeight.w800,
                          ),
                    ),
                    const SizedBox(height: 8),
                    Text(step.body),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _ImportActions extends StatelessWidget {
  const _ImportActions({
    required this.isImporting,
    required this.isPickingFile,
    required this.onOpenNaver,
    required this.onPickFile,
  });

  final bool isImporting;
  final bool isPickingFile;
  final VoidCallback onOpenNaver;
  final VoidCallback onPickFile;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FilledButton.icon(
          onPressed: isImporting ? null : onOpenNaver,
          icon: const Icon(Icons.calendar_month_outlined),
          label: const Text('네이버 캘린더 열기'),
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: isImporting || isPickingFile ? null : onPickFile,
          icon: isPickingFile
              ? const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.upload_file_outlined),
          label: Text(isPickingFile ? '파일 선택 중...' : 'ICS 파일 직접 선택'),
        ),
      ],
    );
  }
}

class _ProgressCard extends StatelessWidget {
  const _ProgressCard();

  @override
  Widget build(BuildContext context) {
    return const Card(
      elevation: 0,
      child: Padding(
        padding: EdgeInsets.all(16),
        child: Row(
          children: [
            SizedBox.square(
              dimension: 22,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            SizedBox(width: 12),
            Expanded(
              child: Text('ICS 파일을 읽고 일정을 저장하는 중입니다.'),
            ),
          ],
        ),
      ),
    );
  }
}

class _ResultCard extends StatelessWidget {
  const _ResultCard({required this.result});

  final NaverIcsImportResult result;

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 0,
      color: result.success ? const Color(0xFFEAF7EF) : const Color(0xFFFFEEF0),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(
          color: result.success
              ? const Color(0xFF9AD3AD)
              : const Color(0xFFE6A0A6),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              result.success ? '가져오기 완료' : '가져오기 확인 필요',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: PlanFlowColors.primary,
                    fontWeight: FontWeight.w800,
                  ),
            ),
            const SizedBox(height: 8),
            Text(result.message),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _ResultPill(label: '가져옴 ${result.imported}개'),
                _ResultPill(label: '중복 스킵 ${result.skipped}개'),
                _ResultPill(label: '실패 ${result.failed}개'),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ResultPill extends StatelessWidget {
  const _ResultPill({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Chip(
      label: Text(label),
      backgroundColor: Colors.white.withValues(alpha: 0.75),
      side: const BorderSide(color: PlanFlowColors.primaryFaint),
    );
  }
}

class _GuideStep {
  const _GuideStep({
    required this.icon,
    required this.title,
    required this.body,
  });

  final IconData icon;
  final String title;
  final String body;
}
