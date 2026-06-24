import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../data/models/feedback_report_model.dart';
import '../../data/repositories/feedback_repository.dart';

class BetaSurveySheet extends StatefulWidget {
  const BetaSurveySheet({super.key, required this.repository});

  final FeedbackRepository repository;

  @override
  State<BetaSurveySheet> createState() => _BetaSurveySheetState();
}

class _BetaSurveySheetState extends State<BetaSurveySheet> {
  final _formKey = GlobalKey<FormState>();
  final _bestFeatureController = TextEditingController();
  final _triggerController = TextEditingController();
  final _improvementController = TextEditingController();
  int? _nps;
  bool _isSubmitting = false;
  String? _errorMessage;

  @override
  void dispose() {
    _bestFeatureController.dispose();
    _triggerController.dispose();
    _improvementController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(bottom: bottomInset),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
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
                      color: PlanFlowColors.textSecondary.withValues(alpha: 0.45),
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                ),
                const SizedBox(height: 18),
                Text(
                  '베타 사용 후기 남기기',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        color: PlanFlowColors.primary,
                        fontWeight: FontWeight.w700,
                      ),
                ),
                const SizedBox(height: 4),
                Text(
                  '솔직한 한 마디가 앱을 더 좋게 만드는 데 직접 쓰입니다.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: PlanFlowColors.textSecondary,
                      ),
                ),
                const SizedBox(height: 20),
                _QuestionLabel(label: '이 앱에서 가장 마음에 드는 점이 뭔가요?', required: true),
                const SizedBox(height: 8),
                TextFormField(
                  key: const ValueKey('beta-survey-best-feature'),
                  controller: _bestFeatureController,
                  minLines: 2,
                  maxLines: 4,
                  textInputAction: TextInputAction.newline,
                  decoration: const InputDecoration(
                    hintText: '예: 말만 하면 알아서 저장되는 게 너무 편해요',
                    border: OutlineInputBorder(),
                  ),
                  validator: (value) {
                    if ((value ?? '').trim().length < 2) {
                      return '2자 이상 입력해 주세요.';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 20),
                _QuestionLabel(label: '처음 이 앱을 쓰게 된 계기가 뭔가요?', required: false),
                const SizedBox(height: 8),
                TextFormField(
                  key: const ValueKey('beta-survey-trigger'),
                  controller: _triggerController,
                  minLines: 2,
                  maxLines: 4,
                  textInputAction: TextInputAction.newline,
                  decoration: const InputDecoration(
                    hintText: '예: 캘린더에 입력하기가 너무 귀찮아서요',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 20),
                _QuestionLabel(label: '개선됐으면 하는 점이 있나요?', required: false),
                const SizedBox(height: 8),
                TextFormField(
                  key: const ValueKey('beta-survey-improvement'),
                  controller: _improvementController,
                  minLines: 2,
                  maxLines: 4,
                  textInputAction: TextInputAction.newline,
                  decoration: const InputDecoration(
                    hintText: '예: 음성 인식이 가끔 틀려서 교정하기 불편해요',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 24),
                _QuestionLabel(label: '이 앱을 주변에 추천할 의향이 어느 정도인가요?', required: false),
                const SizedBox(height: 12),
                _NpsSelector(
                  value: _nps,
                  onChanged: _isSubmitting ? null : (v) => setState(() => _nps = v),
                ),
                if (_errorMessage != null) ...[
                  const SizedBox(height: 12),
                  _ErrorBanner(message: _errorMessage!),
                ],
                const SizedBox(height: 24),
                FilledButton.icon(
                  key: const ValueKey('beta-survey-submit-button'),
                  onPressed: _isSubmitting ? null : _submit,
                  icon: _isSubmitting
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.send_outlined),
                  label: Text(_isSubmitting ? '보내는 중...' : '후기 보내기'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    FocusScope.of(context).unfocus();

    final bestFeature = _bestFeatureController.text.trim();
    final trigger = _triggerController.text.trim();
    final improvement = _improvementController.text.trim();

    final messageParts = <String>[
      '★ 마음에 드는 점: $bestFeature',
      if (trigger.isNotEmpty) '★ 시작 계기: $trigger',
      if (improvement.isNotEmpty) '★ 개선할 점: $improvement',
    ];

    final npsLabel = _nps != null ? '추천 의향: $_nps/5' : null;

    setState(() {
      _isSubmitting = true;
      _errorMessage = null;
    });

    try {
      await widget.repository.submitReport(
        type: FeedbackReportType.betaSurvey,
        message: messageParts.join('\n'),
        routeOrScreen: 'beta_survey',
        expectedBehavior: npsLabel,
      );
      if (mounted) Navigator.of(context).pop(true);
    } on FeedbackSubmissionException catch (error) {
      if (mounted) setState(() => _errorMessage = error.message);
    } catch (_) {
      if (mounted) {
        setState(() => _errorMessage = '후기를 보내지 못했어요. 잠시 후 다시 시도해 주세요.');
      }
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }
}

class _QuestionLabel extends StatelessWidget {
  const _QuestionLabel({required this.label, required this.required});

  final String label;
  final bool required;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Text(
            label,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: PlanFlowColors.textPrimary,
                ),
          ),
        ),
        if (required)
          Container(
            margin: const EdgeInsets.only(left: 6),
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
            decoration: BoxDecoration(
              color: PlanFlowColors.primaryFaint,
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text(
              '필수',
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: PlanFlowColors.primary,
                    fontWeight: FontWeight.w700,
                  ),
            ),
          ),
      ],
    );
  }
}

class _NpsSelector extends StatelessWidget {
  const _NpsSelector({required this.value, required this.onChanged});

  final int? value;
  final ValueChanged<int>? onChanged;

  static const List<String> _labels = ['별로', '아쉬움', '보통', '좋음', '추천!'];

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: List.generate(5, (index) {
        final score = index + 1;
        final isSelected = value == score;
        return GestureDetector(
          onTap: onChanged != null ? () => onChanged!(score) : null,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: isSelected
                      ? PlanFlowColors.primary
                      : PlanFlowColors.primaryFaint.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: isSelected
                        ? PlanFlowColors.primary
                        : PlanFlowColors.primaryFaint,
                    width: 1.5,
                  ),
                ),
                child: Center(
                  child: Text(
                    '$score',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          color: isSelected
                              ? Colors.white
                              : PlanFlowColors.textSecondary,
                          fontWeight: FontWeight.w700,
                        ),
                  ),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                _labels[index],
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: isSelected
                          ? PlanFlowColors.primary
                          : PlanFlowColors.textSecondary,
                      fontWeight:
                          isSelected ? FontWeight.w700 : FontWeight.normal,
                    ),
              ),
            ],
          ),
        );
      }),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colorScheme.error),
      ),
      child: Row(
        children: [
          Icon(Icons.error_outline, size: 18, color: colorScheme.error),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: colorScheme.onErrorContainer,
                    height: 1.35,
                  ),
            ),
          ),
        ],
      ),
    );
  }
}
