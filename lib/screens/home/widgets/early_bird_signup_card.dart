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
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  var _isSaving = false;

  @override
  void dispose() {
    _emailController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppConstants.defaultPadding),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 34,
                    height: 34,
                    decoration: BoxDecoration(
                      color: PlanFlowColors.primaryFaint,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(
                      Icons.workspace_premium_outlined,
                      color: PlanFlowColors.primary,
                      size: 18,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'PRO 얼리버드 신청',
                      style: theme.textTheme.titleMedium,
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 7,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: PlanFlowColors.tagNormalBg,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      '1차',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: PlanFlowColors.tagNormalText,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                '출시 알림과 초기 혜택을 받을 이메일을 남겨주세요.',
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _emailController,
                enabled: !_isSaving,
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
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _isSaving ? null : _submit,
                  child: _isSaving
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('신청하기'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) {
      return;
    }

    setState(() => _isSaving = true);
    try {
      final result = await widget.repository.saveEmail(_emailController.text);
      if (!mounted) {
        return;
      }
      _emailController.text = result.email;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('신청이 완료되었습니다. 출시 소식을 보내드릴게요.')),
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

class _LazyEarlyBirdEmailRepository extends EarlyBirdEmailRepository {
  const _LazyEarlyBirdEmailRepository();

  @override
  Future<EarlyBirdSignupResult> saveEmail(String email) {
    return EarlyBirdEmailRepository.supabase().saveEmail(email);
  }
}
