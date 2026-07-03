import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/theme.dart';
import '../../../providers/auth_provider.dart';
import '../models/group_model.dart';
import '../providers/group_context_provider.dart';
import '../repositories/group_repository.dart';

class GroupCreateScreen extends StatefulWidget {
  const GroupCreateScreen({
    super.key,
    GroupRepository? repository,
    GroupContextProvider? provider,
    String? currentUserIdOverride,
    Future<void> Function(String groupId)? onCreated,
  })  : _repository = repository,
        _provider = provider,
        _currentUserIdOverride = currentUserIdOverride,
        _onCreated = onCreated;

  final GroupRepository? _repository;
  final GroupContextProvider? _provider;
  final String? _currentUserIdOverride;
  final Future<void> Function(String groupId)? _onCreated;

  @override
  State<GroupCreateScreen> createState() => _GroupCreateScreenState();
}

class _GroupCreateScreenState extends State<GroupCreateScreen> {
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameController;
  late final TextEditingController _descriptionController;
  late final GroupRepository _repository;
  late final GroupContextProvider _provider;
  late final bool _ownsProvider;
  bool _isSubmitting = false;
  String? _errorMessage;
  String? _successMessage;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController();
    _descriptionController = TextEditingController();
    _repository = widget._repository ?? GroupRepository.supabase();
    _ownsProvider = widget._provider == null;
    _provider =
        widget._provider ?? GroupContextProvider(repository: _repository);
  }

  @override
  void dispose() {
    _nameController.dispose();
    _descriptionController.dispose();
    if (_ownsProvider) {
      _provider.dispose();
    }
    super.dispose();
  }

  // Supabase가 초기화되지 않은 환경(위젯 테스트 등)에서는 null을 돌려준다.
  // 프로덕션에서는 항상 초기화돼 있으므로 동작이 달라지지 않는다.
  SupabaseClient? get _safeSupabaseClient {
    try {
      return Supabase.instance.client;
    } catch (_) {
      return null;
    }
  }

  Future<void> _createGroup() async {
    if (!_formKey.currentState!.validate()) {
      return;
    }
    // 실제 Supabase 세션 user ID를 우선한다.
    // authProvider.userId는 캐시라 세션이 다른 계정으로 교체된 경우(OAuth 오염 등)
    // created_by != auth.uid()가 되어 42501 RLS 에러가 발생할 수 있다.
    final sessionUserId = _safeSupabaseClient?.auth.currentUser?.id;
    final userId =
        widget._currentUserIdOverride ?? sessionUserId ?? authProvider.userId;
    if (userId == null || userId.trim().isEmpty) {
      setState(() {
        _errorMessage = '로그인 후 그룹을 만들 수 있어요.';
        _successMessage = null;
      });
      return;
    }

    setState(() {
      _isSubmitting = true;
      _errorMessage = null;
      _successMessage = null;
    });

    // Supabase 세션이 만료됐거나 없으면 그룹 INSERT가 42501 RLS 에러로 실패한다.
    // authProvider.userId는 캐시라 비-null이어도 실제 JWT가 없을 수 있으므로 직접 확인.
    final supabaseClient = _safeSupabaseClient;
    if (supabaseClient != null &&
        (supabaseClient.auth.currentSession == null ||
            supabaseClient.auth.currentSession!.isExpired)) {
      try {
        await supabaseClient.auth.refreshSession();
      } catch (_) {
        if (mounted) {
          setState(() {
            _isSubmitting = false;
            _errorMessage = '세션이 만료됐어요. 다시 로그인해 주세요.';
          });
        }
        return;
      }
    }

    try {
      final created = await _repository.createGroup(
        GroupModel(
          id: '',
          createdBy: userId,
          name: _nameController.text.trim(),
          description: _descriptionController.text.trim().isEmpty
              ? null
              : _descriptionController.text.trim(),
          status: 'active',
          createdAt: DateTime.now().toUtc(),
        ),
      );
      await _provider.load(userId);
      await _provider.selectGroup(created.id);

      if (!mounted) {
        return;
      }

      setState(() {
        _isSubmitting = false;
        _successMessage = '${created.name} 그룹을 만들었어요.';
      });

      if (widget._onCreated != null) {
        await widget._onCreated!(created.id);
        return;
      }

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_successMessage!)),
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
        _isSubmitting = false;
        _errorMessage = error.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('새 그룹 만들기')),
      body: GestureDetector(
        onTap: () => FocusScope.of(context).unfocus(),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Icon(Icons.groups_outlined),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                '그룹 기본 정보',
                                style: Theme.of(context)
                                    .textTheme
                                    .titleMedium
                                    ?.copyWith(fontWeight: FontWeight.w700),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        TextFormField(
                          key: const ValueKey('group-create-name-field'),
                          controller: _nameController,
                          textInputAction: TextInputAction.next,
                          decoration: const InputDecoration(
                            labelText: '그룹 이름',
                            hintText: '예: 제품팀',
                          ),
                          validator: (value) {
                            final text = value?.trim() ?? '';
                            if (text.isEmpty) {
                              return '그룹 이름을 입력해 주세요.';
                            }
                            if (text.length > 80) {
                              return '그룹 이름은 80자 이내로 입력해 주세요.';
                            }
                            return null;
                          },
                        ),
                        const SizedBox(height: 12),
                        TextFormField(
                          key: const ValueKey('group-create-description-field'),
                          controller: _descriptionController,
                          maxLines: 3,
                          decoration: const InputDecoration(
                            labelText: '설명',
                            hintText: '선택 입력',
                          ),
                          validator: (value) {
                            final text = value?.trim() ?? '';
                            if (text.length > 240) {
                              return '설명은 240자 이내로 입력해 주세요.';
                            }
                            return null;
                          },
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Card(
                  color: PlanFlowColors.surfaceFaint,
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '상위 그룹',
                          style:
                              Theme.of(context).textTheme.titleSmall?.copyWith(
                                    fontWeight: FontWeight.w700,
                                  ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'V2 첫 화면에서는 최상위 그룹 생성만 지원합니다. 하위 그룹 선택은 다음 단계에서 추가할게요.',
                          style:
                              Theme.of(context).textTheme.bodyMedium?.copyWith(
                                    color: PlanFlowColors.textSecondary,
                                  ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                if (_errorMessage != null) ...[
                  _FeedbackBanner(
                    color: const Color(0xFFFFF3F0),
                    icon: Icons.error_outline,
                    iconColor: const Color(0xFFB42318),
                    textColor: const Color(0xFF7A271A),
                    title: '그룹을 만들지 못했어요',
                    message: _errorMessage!,
                  ),
                  const SizedBox(height: 12),
                ],
                if (_successMessage != null) ...[
                  _FeedbackBanner(
                    color: const Color(0xFFF0F9EE),
                    icon: Icons.check_circle_outline,
                    iconColor: const Color(0xFF067647),
                    textColor: const Color(0xFF067647),
                    title: '생성 완료',
                    message: _successMessage!,
                  ),
                  const SizedBox(height: 12),
                ],
                FilledButton.icon(
                  key: const ValueKey('group-create-submit-button'),
                  onPressed: _isSubmitting ? null : _createGroup,
                  icon: _isSubmitting
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.add_circle_outline),
                  label: Text(_isSubmitting ? '생성 중...' : '그룹 만들기'),
                ),
                const SizedBox(height: 8),
                Text(
                  '생성하면 내가 리더로 자동 등록되고, 바로 선택 그룹으로 저장됩니다.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: PlanFlowColors.textSecondary,
                      ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _FeedbackBanner extends StatelessWidget {
  const _FeedbackBanner({
    required this.color,
    required this.icon,
    required this.iconColor,
    required this.textColor,
    required this.title,
    required this.message,
  });

  final Color color;
  final IconData icon;
  final Color iconColor;
  final Color textColor;
  final String title;
  final String message;

  @override
  Widget build(BuildContext context) {
    return Card(
      color: color,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: iconColor),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          color: textColor,
                          fontWeight: FontWeight.w700,
                        ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    message,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: textColor,
                        ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
