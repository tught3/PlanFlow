import 'package:flutter/material.dart';

import '../../../core/constants.dart';
import '../../../core/theme.dart';
import '../../../data/models/early_bird_email_model.dart';
import '../../../data/repositories/early_bird_email_repository.dart';

class EarlyBirdSignupCard extends StatefulWidget {
  const EarlyBirdSignupCard({
    super.key,
    EarlyBirdEmailRepository? repository,
  }) : repository = repository ?? const _LazyEarlyBirdEmailRepository();

  final EarlyBirdEmailRepository repository;

  @override
  State<EarlyBirdSignupCard> createState() => _EarlyBirdSignupCardState();
}

class _EarlyBirdSignupCardState extends State<EarlyBirdSignupCard> {
  var _isSaving = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      color: PlanFlowColors.surface,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: const BorderSide(
          color: PlanFlowColors.primaryFaint,
          width: 0.5,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: PlanFlowColors.primaryFaint,
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(
                Icons.workspace_premium_outlined,
                color: PlanFlowColors.primary,
                size: 20,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'PRO 얼리버드 신청',
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: PlanFlowColors.primary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    '출시 알림과 초기 혜택 안내를 받을 이메일을 남겨주세요.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: PlanFlowColors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: _isSaving ? null : _openSignupDialog,
              child: const Text('신청'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _openSignupDialog() async {
    final email = await showDialog<String>(
      context: context,
      builder: (context) => _EarlyBirdSignupDialog(isSaving: _isSaving),
    );
    if (email == null || email.trim().isEmpty) {
      return;
    }

    setState(() => _isSaving = true);
    try {
      final result = await widget.repository.saveEmail(email);
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('${result.email}로 신청을 저장했습니다.'),
        ),
      );
    } catch (_) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('신청 저장에 실패했습니다. 잠시 후 다시 시도해 주세요.')),
      );
    } finally {
      if (mounted) {
        setState(() => _isSaving = false);
      }
    }
  }
}

class _EarlyBirdSignupDialog extends StatefulWidget {
  const _EarlyBirdSignupDialog({
    required this.isSaving,
  });

  final bool isSaving;

  @override
  State<_EarlyBirdSignupDialog> createState() => _EarlyBirdSignupDialogState();
}

class _EarlyBirdSignupDialogState extends State<_EarlyBirdSignupDialog> {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();

  @override
  void dispose() {
    _emailController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('PRO 얼리버드 신청'),
      content: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '현재는 이메일을 대기자 명단에 저장합니다. 자동 메일 발송은 이메일 서비스 연결 후 추가됩니다.',
            ),
            const SizedBox(height: AppConstants.sectionSpacing),
            TextFormField(
              controller: _emailController,
              enabled: !widget.isSaving,
              keyboardType: TextInputType.emailAddress,
              autofillHints: const [AutofillHints.email],
              decoration: const InputDecoration(
                labelText: '이메일',
                hintText: 'you@example.com',
                border: OutlineInputBorder(),
              ),
              validator: (value) {
                if (EarlyBirdEmailModel.isValidEmail(value ?? '')) {
                  return null;
                }
                return '올바른 이메일을 입력해 주세요.';
              },
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: widget.isSaving ? null : () => Navigator.of(context).pop(),
          child: const Text('취소'),
        ),
        FilledButton(
          onPressed: widget.isSaving
              ? null
              : () {
                  if (_formKey.currentState?.validate() ?? false) {
                    Navigator.of(context).pop(_emailController.text);
                  }
                },
          child: const Text('신청하기'),
        ),
      ],
    );
  }
}

class _LazyEarlyBirdEmailRepository extends EarlyBirdEmailRepository {
  const _LazyEarlyBirdEmailRepository();

  @override
  Future<EarlyBirdSignupResult> saveEmail(String email) {
    return EarlyBirdEmailRepository.supabase().saveEmail(email);
  }
}
