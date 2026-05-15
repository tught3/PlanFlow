import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/theme.dart';
import '../../data/models/feedback_report_model.dart';
import '../../data/repositories/feedback_repository.dart';

const String officialSupportEmail = 'officialfluxstudio.kr@gmail.com';
const String feedbackAdminEmail = 'tught3@naver.com';

class FeedbackReportSheet extends StatefulWidget {
  const FeedbackReportSheet({
    super.key,
    required this.repository,
    this.routeOrScreen = 'settings',
    this.launchUrlFn,
  });

  final FeedbackRepository repository;
  final String routeOrScreen;
  final Future<bool> Function(Uri uri)? launchUrlFn;

  @override
  State<FeedbackReportSheet> createState() => _FeedbackReportSheetState();
}

class _FeedbackReportSheetState extends State<FeedbackReportSheet> {
  final _formKey = GlobalKey<FormState>();
  final _messageController = TextEditingController();
  final _expectedController = TextEditingController();
  FeedbackReportType _type = FeedbackReportType.bug;
  bool _isSubmitting = false;
  String? _statusMessage;
  bool _isStatusError = false;

  @override
  void dispose() {
    _messageController.dispose();
    _expectedController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(bottom: bottomInset),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: PlanFlowColors.textSecondary.withValues(
                        alpha: 0.45,
                      ),
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                ),
                const SizedBox(height: 18),
                Text(
                  '문제 신고 / 의견 보내기',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        color: PlanFlowColors.primary,
                        fontWeight: FontWeight.w700,
                      ),
                ),
                const SizedBox(height: 6),
                Text(
                  '불편한 점을 보내주시면 수정 우선순위를 잡는 데 바로 참고할게요.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: PlanFlowColors.textSecondary,
                      ),
                ),
                const SizedBox(height: 10),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: PlanFlowColors.primaryFaint.withValues(alpha: 0.45),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: PlanFlowColors.primaryFaint),
                  ),
                  child: Text(
                    '음성 파일, 캘린더 전체 내용, 위치 이력은 자동 첨부하지 않아요.',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: PlanFlowColors.textPrimary,
                          height: 1.35,
                        ),
                  ),
                ),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: FeedbackReportType.values.map((type) {
                    return ChoiceChip(
                      label: Text(type.label),
                      selected: _type == type,
                      onSelected: _isSubmitting
                          ? null
                          : (_) => setState(() {
                                _type = type;
                              }),
                    );
                  }).toList(),
                ),
                const SizedBox(height: 16),
                TextFormField(
                  key: const ValueKey('feedback-message-field'),
                  controller: _messageController,
                  minLines: 4,
                  maxLines: 6,
                  textInputAction: TextInputAction.newline,
                  decoration: const InputDecoration(
                    labelText: '내용',
                    hintText: '어떤 화면에서 무엇이 불편했는지 적어 주세요.',
                    border: OutlineInputBorder(),
                  ),
                  validator: (value) {
                    if ((value ?? '').trim().length < 5) {
                      return '내용을 5자 이상 입력해 주세요.';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 12),
                TextFormField(
                  key: const ValueKey('feedback-expected-field'),
                  controller: _expectedController,
                  minLines: 2,
                  maxLines: 4,
                  textInputAction: TextInputAction.newline,
                  decoration: const InputDecoration(
                    labelText: '재현 단계 / 기대한 동작(선택)',
                    hintText: '예: 음성으로 수정 요청하면 기존 일정이 보여야 해요.',
                    border: OutlineInputBorder(),
                  ),
                ),
                if (_statusMessage != null) ...[
                  const SizedBox(height: 12),
                  _FeedbackStatusBanner(
                    message: _statusMessage!,
                    isError: _isStatusError,
                  ),
                ],
                const SizedBox(height: 16),
                FilledButton.icon(
                  key: const ValueKey('feedback-submit-button'),
                  onPressed: _isSubmitting ? null : _submit,
                  icon: _isSubmitting
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.send_outlined),
                  label: Text(_isSubmitting ? '보내는 중...' : '보내기'),
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  key: const ValueKey('feedback-email-button'),
                  onPressed: _isSubmitting ? null : _openEmail,
                  icon: const Icon(Icons.mail_outline),
                  label: const Text('이메일로 문의하기'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) {
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() {
      _isSubmitting = true;
      _statusMessage = null;
      _isStatusError = false;
    });
    try {
      await widget.repository.submitReport(
        type: _type,
        message: _messageController.text,
        expectedBehavior: _expectedController.text,
        routeOrScreen: widget.routeOrScreen,
      );
      if (mounted) {
        _messageController.clear();
        _expectedController.clear();
        Navigator.of(context).pop(true);
      }
    } on FeedbackSubmissionException catch (error) {
      _showError(error.message);
    } catch (_) {
      _showError('문제 신고를 보내지 못했어요. 잠시 후 다시 시도해 주세요.');
    } finally {
      if (mounted) {
        setState(() {
          _isSubmitting = false;
        });
      }
    }
  }

  Future<void> _openEmail() async {
    final uri = Uri(
      scheme: 'mailto',
      path: officialSupportEmail,
      queryParameters: <String, String>{
        'subject': 'PlanFlow 문의',
      },
    );
    final launcher = widget.launchUrlFn ??
        (Uri uri) => launchUrl(uri, mode: LaunchMode.externalApplication);
    final opened = await launcher(uri);
    if (!opened) {
      _showError('이메일 앱을 열 수 없어요. $officialSupportEmail 로 보내 주세요.');
    }
  }

  void _showError(String message) {
    if (!mounted) {
      return;
    }
    setState(() {
      _statusMessage = message;
      _isStatusError = true;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }
}

class _FeedbackStatusBanner extends StatelessWidget {
  const _FeedbackStatusBanner({
    required this.message,
    required this.isError,
  });

  final String message;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return Container(
      key: const ValueKey('feedback-status-banner'),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isError
            ? colorScheme.errorContainer
            : PlanFlowColors.primaryFaint.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isError ? colorScheme.error : PlanFlowColors.primaryFaint,
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            isError ? Icons.error_outline : Icons.check_circle_outline,
            size: 18,
            color: isError ? colorScheme.error : PlanFlowColors.primary,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: theme.textTheme.bodySmall?.copyWith(
                color: isError
                    ? colorScheme.onErrorContainer
                    : PlanFlowColors.textPrimary,
                height: 1.35,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class FeedbackReportSection extends StatelessWidget {
  const FeedbackReportSection({
    super.key,
    required this.onPressed,
    this.onOpenAdminInbox,
  });

  final VoidCallback onPressed;
  final VoidCallback? onOpenAdminInbox;

  @override
  Widget build(BuildContext context) {
    return Card(
      color: PlanFlowColors.surface,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: const BorderSide(color: PlanFlowColors.primaryFaint, width: 0.5),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '문제 신고 / 의견 보내기',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: PlanFlowColors.primary,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
            ),
            const SizedBox(height: 4),
            Text(
              '버그, 음성 인식 오류, 캘린더 동기화 문제, 알림 문제, 기능 제안을 보낼 수 있어요.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: PlanFlowColors.textSecondary,
                  ),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              key: const ValueKey('settings-feedback-report-button'),
              onPressed: onPressed,
              icon: const Icon(Icons.feedback_outlined),
              label: const Text('문제 신고하기'),
            ),
            if (onOpenAdminInbox != null) ...[
              const SizedBox(height: 8),
              OutlinedButton.icon(
                key: const ValueKey('settings-feedback-admin-inbox-button'),
                onPressed: onOpenAdminInbox,
                icon: const Icon(Icons.admin_panel_settings_outlined),
                label: const Text('신고함 열기'),
              ),
            ],
            const SizedBox(height: 8),
            Text(
              '공식 문의: $officialSupportEmail',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: PlanFlowColors.textSecondary,
                  ),
            ),
          ],
        ),
      ),
    );
  }
}

class FeedbackAdminReportsSheet extends StatefulWidget {
  const FeedbackAdminReportsSheet({
    super.key,
    required this.repository,
  });

  final FeedbackRepository repository;

  @override
  State<FeedbackAdminReportsSheet> createState() =>
      _FeedbackAdminReportsSheetState();
}

class _FeedbackAdminReportsSheetState extends State<FeedbackAdminReportsSheet> {
  static const List<FeedbackReportStatus> _statuses = <FeedbackReportStatus>[
    FeedbackReportStatus.newReport,
    FeedbackReportStatus.triaged,
    FeedbackReportStatus.fixed,
    FeedbackReportStatus.closed,
  ];

  late Future<List<FeedbackReport>> _reportsFuture;
  String? _updatingReportId;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _reportsFuture = _fetchReports();
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(bottom: bottomInset),
        child: DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.88,
          minChildSize: 0.45,
          maxChildSize: 0.95,
          builder: (context, scrollController) {
            return Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Center(
                    child: Container(
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(
                        color: PlanFlowColors.textSecondary.withValues(
                          alpha: 0.45,
                        ),
                        borderRadius: BorderRadius.circular(999),
                      ),
                    ),
                  ),
                  const SizedBox(height: 18),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          '문제 신고함',
                          style:
                              Theme.of(context).textTheme.titleMedium?.copyWith(
                                    color: PlanFlowColors.primary,
                                    fontWeight: FontWeight.w700,
                                  ),
                        ),
                      ),
                      IconButton(
                        key: const ValueKey('feedback-admin-refresh-button'),
                        tooltip: '새로고침',
                        onPressed: _refresh,
                        icon: const Icon(Icons.refresh),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '접수된 신고를 확인하고 처리 상태를 바꿀 수 있어요.',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: PlanFlowColors.textSecondary,
                        ),
                  ),
                  if (_errorMessage != null) ...[
                    const SizedBox(height: 12),
                    _FeedbackStatusBanner(
                      message: _errorMessage!,
                      isError: true,
                    ),
                  ],
                  const SizedBox(height: 12),
                  Expanded(
                    child: FutureBuilder<List<FeedbackReport>>(
                      future: _reportsFuture,
                      builder: (context, snapshot) {
                        if (snapshot.connectionState ==
                            ConnectionState.waiting) {
                          return const Center(
                            child: CircularProgressIndicator(),
                          );
                        }
                        if (snapshot.hasError) {
                          return _AdminReportsEmptyState(
                            icon: Icons.error_outline,
                            title: '신고함을 불러오지 못했어요.',
                            message: _adminErrorMessage(snapshot.error),
                            onRetry: _refresh,
                          );
                        }
                        final reports =
                            snapshot.data ?? const <FeedbackReport>[];
                        if (reports.isEmpty) {
                          return _AdminReportsEmptyState(
                            icon: Icons.inbox_outlined,
                            title: '접수된 신고가 없어요.',
                            message: '새 신고가 들어오면 이곳에 표시됩니다.',
                            onRetry: _refresh,
                          );
                        }
                        return ListView.separated(
                          controller: scrollController,
                          itemCount: reports.length,
                          separatorBuilder: (_, __) =>
                              const SizedBox(height: 10),
                          itemBuilder: (context, index) {
                            final report = reports[index];
                            return _AdminReportCard(
                              report: report,
                              statuses: _statuses,
                              isUpdating: _updatingReportId == report.id,
                              onStatusChanged: (status) =>
                                  _updateStatus(report, status),
                            );
                          },
                        );
                      },
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  Future<List<FeedbackReport>> _fetchReports() {
    return widget.repository.fetchAdminReports(limit: 100);
  }

  void _refresh() {
    setState(() {
      _errorMessage = null;
      _reportsFuture = _fetchReports();
    });
  }

  Future<void> _updateStatus(
    FeedbackReport report,
    FeedbackReportStatus status,
  ) async {
    if (_updatingReportId != null || report.status == status) {
      return;
    }
    setState(() {
      _updatingReportId = report.id;
      _errorMessage = null;
    });
    try {
      await widget.repository.updateReportStatus(
        reportId: report.id,
        status: status,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _reportsFuture = _fetchReports();
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${status.label} 상태로 바꿨어요.')),
      );
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _errorMessage = _adminErrorMessage(error);
      });
    } finally {
      if (mounted) {
        setState(() {
          _updatingReportId = null;
        });
      }
    }
  }

  static String _adminErrorMessage(Object? error) {
    final raw = error?.toString() ?? '';
    if (raw.isNotEmpty) {
      return '신고함 작업에 실패했어요. $raw';
    }
    return '신고함 작업에 실패했어요. 잠시 후 다시 시도해 주세요.';
  }
}

class _AdminReportCard extends StatelessWidget {
  const _AdminReportCard({
    required this.report,
    required this.statuses,
    required this.isUpdating,
    required this.onStatusChanged,
  });

  final FeedbackReport report;
  final List<FeedbackReportStatus> statuses;
  final bool isUpdating;
  final ValueChanged<FeedbackReportStatus> onStatusChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      key: ValueKey('feedback-admin-report-${report.id}'),
      color: PlanFlowColors.surface,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: const BorderSide(color: PlanFlowColors.primaryFaint, width: 0.5),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                _AdminReportPill(label: report.type.label),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _formatReportDate(report.createdAt),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.right,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: PlanFlowColors.textSecondary,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              report.message,
              style: theme.textTheme.bodyMedium?.copyWith(height: 1.4),
            ),
            if (report.expectedBehavior?.isNotEmpty ?? false) ...[
              const SizedBox(height: 8),
              Text(
                '기대한 동작: ${report.expectedBehavior}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: PlanFlowColors.textSecondary,
                  height: 1.35,
                ),
              ),
            ],
            const SizedBox(height: 8),
            Text(
              '${report.routeOrScreen ?? 'unknown'} · ${report.userId}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: PlanFlowColors.textSecondary,
              ),
            ),
            const SizedBox(height: 12),
            if (isUpdating)
              const LinearProgressIndicator(minHeight: 2)
            else
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: statuses.map((status) {
                  return ChoiceChip(
                    key: ValueKey(
                      'feedback-admin-status-${report.id}-${status.value}',
                    ),
                    label: Text(status.label),
                    selected: report.status == status,
                    onSelected: (_) => onStatusChanged(status),
                  );
                }).toList(),
              ),
          ],
        ),
      ),
    );
  }

  static String _formatReportDate(DateTime value) {
    final local = value.toLocal();
    return '${local.year}-${local.month.toString().padLeft(2, '0')}-${local.day.toString().padLeft(2, '0')} '
        '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
  }
}

class _AdminReportPill extends StatelessWidget {
  const _AdminReportPill({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: PlanFlowColors.primaryFaint.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        child: Text(
          label,
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: PlanFlowColors.primary,
                fontWeight: FontWeight.w700,
              ),
        ),
      ),
    );
  }
}

class _AdminReportsEmptyState extends StatelessWidget {
  const _AdminReportsEmptyState({
    required this.icon,
    required this.title,
    required this.message,
    required this.onRetry,
  });

  final IconData icon;
  final String title;
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 36, color: PlanFlowColors.textSecondary),
          const SizedBox(height: 12),
          Text(
            title,
            textAlign: TextAlign.center,
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            message,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(
              color: PlanFlowColors.textSecondary,
              height: 1.35,
            ),
          ),
          const SizedBox(height: 14),
          OutlinedButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh),
            label: const Text('다시 불러오기'),
          ),
        ],
      ),
    );
  }
}
