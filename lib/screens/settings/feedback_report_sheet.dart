import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/theme.dart';
import '../../data/models/feedback_report_model.dart';
import '../../data/repositories/feedback_repository.dart';

const String officialSupportEmail = 'officialfluxstudio.kr@gmail.com';

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
  });

  final VoidCallback onPressed;

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
