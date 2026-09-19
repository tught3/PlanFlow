import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/theme.dart';
import '../../../l10n/app_l10n.dart';
import '../repositories/group_event_report_repository.dart';

/// 공유 그룹 일정 신고용 정책/약관 링크. 저장소에 존재하는 실제 URL만 사용한다.
/// (config/store/store-profile.json privacyPolicyUrl = https://fluxstudio.co.kr/privacy)
const String groupEventReportPolicyUrl = 'https://fluxstudio.co.kr/privacy';

class GroupEventReportSheet extends StatefulWidget {
  const GroupEventReportSheet({
    super.key,
    required this.groupEventId,
    required this.groupId,
    this.contentOwnerId,
    GroupEventReportRepository? repository,
    this.launchUrlFn,
  }) : _repository = repository;

  final String groupEventId;
  final String groupId;
  final String? contentOwnerId;
  final GroupEventReportRepository? _repository;
  final Future<bool> Function(Uri uri)? launchUrlFn;

  @override
  State<GroupEventReportSheet> createState() => _GroupEventReportSheetState();
}

class _GroupEventReportSheetState extends State<GroupEventReportSheet> {
  GroupEventReportRepository get _repository =>
      widget._repository ?? GroupEventReportRepository.supabase();

  String _reason = GroupEventReportReason.inappropriate;
  final _detailController = TextEditingController();
  bool _isSubmitting = false;
  String? _statusMessage;
  bool _isStatusError = false;

  @override
  void dispose() {
    _detailController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = appL10n(context);
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;
    final reasons = <(String, String)>[
      (GroupEventReportReason.inappropriate, l10n.reportReasonInappropriate),
      (GroupEventReportReason.spam, l10n.reportReasonSpam),
      (GroupEventReportReason.harassment, l10n.reportReasonHarassment),
      (GroupEventReportReason.other, l10n.reportReasonOther),
    ];
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(bottom: bottomInset),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: PlanFlowColors.textSecondary.withValues(alpha: 0.45),
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
              ),
              const SizedBox(height: 18),
              Text(
                l10n.groupEventReportSheetTitle,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      color: PlanFlowColors.primary,
                      fontWeight: FontWeight.w700,
                    ),
              ),
              const SizedBox(height: 6),
              Text(
                l10n.groupEventReportSheetSubtitle,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: PlanFlowColors.textSecondary,
                    ),
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final (value, label) in reasons)
                    ChoiceChip(
                      key: ValueKey('group-event-report-reason-$value'),
                      label: Text(label),
                      selected: _reason == value,
                      onSelected: _isSubmitting
                          ? null
                          : (_) => setState(() => _reason = value),
                    ),
                ],
              ),
              if (_reason == GroupEventReportReason.other) ...[
                const SizedBox(height: 16),
                TextField(
                  key: const ValueKey('group-event-report-detail-field'),
                  controller: _detailController,
                  maxLength: 500,
                  minLines: 2,
                  maxLines: 4,
                  decoration: InputDecoration(
                    labelText: l10n.groupEventReportDetailLabel,
                    hintText: l10n.groupEventReportDetailHint,
                    border: const OutlineInputBorder(),
                  ),
                ),
              ],
              if (_statusMessage != null) ...[
                const SizedBox(height: 12),
                Text(
                  key: const ValueKey('group-event-report-status'),
                  _statusMessage!,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: _isStatusError
                            ? Theme.of(context).colorScheme.error
                            : PlanFlowColors.primary,
                      ),
                ),
              ],
              const SizedBox(height: 16),
              FilledButton(
                key: const ValueKey('group-event-report-submit-button'),
                onPressed: _isSubmitting ? null : _submit,
                child: Text(
                  _isSubmitting
                      ? l10n.groupEventReportSubmitting
                      : l10n.groupEventReportSubmit,
                ),
              ),
              const SizedBox(height: 8),
              TextButton(
                key: const ValueKey('group-event-report-policy-link'),
                onPressed: _isSubmitting ? null : _openPolicy,
                child: Text(
                  l10n.groupEventReportPolicyLink,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _submit() async {
    setState(() {
      _isSubmitting = true;
      _statusMessage = null;
      _isStatusError = false;
    });
    try {
      await _repository.submitReport(
        groupEventId: widget.groupEventId,
        groupId: widget.groupId,
        reason: _reason,
        detail: _detailController.text,
        contentOwnerId: widget.contentOwnerId,
      );
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          key: const ValueKey('group-event-report-success-snackbar'),
          content: Text(appL10n(context).groupEventReportSuccess),
        ),
      );
      Navigator.of(context).pop(true);
    } on AlreadyReportedException {
      _showError(appL10n(context).groupEventReportAlreadyReported);
    } catch (_) {
      _showError(appL10n(context).groupEventReportFailed);
    } finally {
      if (mounted) {
        setState(() {
          _isSubmitting = false;
        });
      }
    }
  }

  Future<void> _openPolicy() async {
    final uri = Uri.parse(groupEventReportPolicyUrl);
    final launcher = widget.launchUrlFn ??
        (Uri uri) => launchUrl(uri, mode: LaunchMode.externalApplication);
    await launcher(uri);
  }

  void _showError(String message) {
    if (!mounted) {
      return;
    }
    setState(() {
      _statusMessage = message;
      _isStatusError = true;
    });
  }
}
