import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/constants.dart';
import '../../core/env.dart';
import '../../core/theme.dart';
import '../../services/auth_service.dart';

enum _AuthMode {
  login,
  signUp,
  reset,
}

class LoginScreen extends StatefulWidget {
  const LoginScreen({
    super.key,
    AuthService? authService,
  }) : _authService = authService;

  final AuthService? _authService;

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();
  final _nameController = TextEditingController();

  late final AuthService? _authService;

  _AuthMode _mode = _AuthMode.login;
  bool _isLoading = false;
  String? _message;
  bool _isError = false;

  @override
  void initState() {
    super.initState();
    _authService = AppEnv.isSupabaseReady
        ? widget._authService ?? AuthService()
        : widget._authService;
  }

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final authService = _authService;
    if (!AppEnv.isSupabaseReady || authService == null) {
      _setMessage('Supabase URL과 anon key를 먼저 설정해야 로그인할 수 있습니다.');
      return;
    }

    final validationMessage = _validate();
    if (validationMessage != null) {
      _setMessage(validationMessage);
      return;
    }

    setState(() {
      _isLoading = true;
      _message = null;
    });

    try {
      if (_mode == _AuthMode.login) {
        await authService.signInWithEmail(
          email: _emailController.text,
          password: _passwordController.text,
        );
        if (mounted) {
          context.go(AppRoutes.home);
        }
      } else if (_mode == _AuthMode.signUp) {
        final response = await authService.signUpWithEmail(
          email: _emailController.text,
          password: _passwordController.text,
          name: _nameController.text,
        );
        if (response.session == null) {
          _setMessage('회원가입 메일을 보냈습니다. 메일함에서 인증을 완료해주세요.', isError: false);
          _setMode(_AuthMode.login, keepMessage: true);
        } else if (mounted) {
          context.go(AppRoutes.home);
        }
      } else {
        await authService.sendPasswordResetEmail(_emailController.text);
        _setMessage('비밀번호 재설정 메일을 보냈습니다. 메일함을 확인해주세요.', isError: false);
      }
    } catch (error) {
      _setMessage(_friendlyAuthMessage(error));
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _socialLogin(PlanFlowOAuthProvider provider) async {
    final authService = _authService;
    if (!AppEnv.isSupabaseReady || authService == null) {
      _setMessage('Supabase 설정 후 소셜 로그인을 사용할 수 있습니다.');
      return;
    }

    setState(() {
      _isLoading = true;
      _message = null;
    });

    try {
      final launched = await authService.signInWithOAuth(provider);
      if (!launched) {
        _setMessage('로그인 창을 열지 못했습니다. 브라우저 설정을 확인해주세요.');
      }
    } catch (error) {
      _setMessage(_friendlyAuthMessage(error));
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  String? _validate() {
    final email = _emailController.text.trim();
    final password = _passwordController.text;

    if (email.isEmpty || !email.contains('@')) {
      return '올바른 이메일을 입력해주세요.';
    }
    if (_mode == _AuthMode.reset) {
      return null;
    }
    if (password.length < 6) {
      return '비밀번호는 최소 6자 이상이어야 합니다.';
    }
    if (_mode == _AuthMode.signUp &&
        password != _confirmPasswordController.text) {
      return '비밀번호 확인이 일치하지 않습니다.';
    }
    return null;
  }

  void _setMode(_AuthMode mode, {bool keepMessage = false}) {
    setState(() {
      _mode = mode;
      if (!keepMessage) {
        _message = null;
      }
      _isError = false;
    });
  }

  void _setMessage(String message, {bool isError = true}) {
    if (!mounted) {
      return;
    }
    setState(() {
      _message = message;
      _isError = isError;
    });
  }

  String _friendlyAuthMessage(Object error) {
    final message = error.toString();
    if (message.contains('Invalid login credentials')) {
      return '이메일 또는 비밀번호가 올바르지 않습니다.';
    }
    if (message.contains('Email not confirmed')) {
      return '이메일 인증이 아직 완료되지 않았습니다. 메일함을 확인해주세요.';
    }
    if (message.contains('User already registered')) {
      return '이미 가입된 이메일입니다. 로그인으로 진행해주세요.';
    }
    return '인증 처리 중 문제가 발생했습니다. 설정과 입력값을 확인해주세요.';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final title = switch (_mode) {
      _AuthMode.login => '로그인',
      _AuthMode.signUp => '회원가입',
      _AuthMode.reset => '비밀번호 찾기',
    };
    final subtitle = switch (_mode) {
      _AuthMode.login => '등록된 이메일과 비밀번호로 PlanFlow를 시작하세요.',
      _AuthMode.signUp => '새 계정을 만들면 일정 데이터가 계정별로 분리됩니다.',
      _AuthMode.reset => '가입한 이메일로 비밀번호 재설정 링크를 보내드립니다.',
    };

    return Scaffold(
      backgroundColor: PlanFlowColors.background,
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(AppConstants.defaultPadding),
          children: [
            const SizedBox(height: 20),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
              decoration: BoxDecoration(
                color: PlanFlowColors.primary,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    AppConstants.appName,
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: const Color(0xFFA8D4F0),
                      letterSpacing: 0.6,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    title,
                    style: theme.textTheme.headlineSmall?.copyWith(
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    subtitle,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: Colors.white.withValues(alpha: 0.82),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            if (!AppEnv.isSupabaseReady)
              _MessageBox(
                message:
                    'Supabase 환경값이 없어서 실제 로그인은 아직 사용할 수 없습니다. .env에 SUPABASE_URL, SUPABASE_ANON_KEY를 넣어주세요.',
                isError: true,
              ),
            if (_message != null) ...[
              _MessageBox(message: _message!, isError: _isError),
              const SizedBox(height: 12),
            ],
            Card(
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
                padding: const EdgeInsets.all(14),
                child: Column(
                  children: [
                    SegmentedButton<_AuthMode>(
                      segments: const [
                        ButtonSegment(
                          value: _AuthMode.login,
                          label: Text('로그인'),
                          icon: Icon(Icons.login),
                        ),
                        ButtonSegment(
                          value: _AuthMode.signUp,
                          label: Text('회원가입'),
                          icon: Icon(Icons.person_add_alt_1),
                        ),
                      ],
                      selected: <_AuthMode>{
                        _mode == _AuthMode.reset ? _AuthMode.login : _mode,
                      },
                      onSelectionChanged: _isLoading
                          ? null
                          : (selected) => _setMode(selected.first),
                    ),
                    const SizedBox(height: 16),
                    if (_mode == _AuthMode.signUp) ...[
                      TextField(
                        controller: _nameController,
                        decoration: const InputDecoration(
                          labelText: '이름 또는 닉네임',
                          border: OutlineInputBorder(),
                        ),
                        textInputAction: TextInputAction.next,
                      ),
                      const SizedBox(height: AppConstants.sectionSpacing),
                    ],
                    TextField(
                      controller: _emailController,
                      decoration: const InputDecoration(
                        labelText: '이메일',
                        border: OutlineInputBorder(),
                      ),
                      keyboardType: TextInputType.emailAddress,
                      autofillHints: const [AutofillHints.email],
                      textInputAction: TextInputAction.next,
                    ),
                    if (_mode != _AuthMode.reset) ...[
                      const SizedBox(height: AppConstants.sectionSpacing),
                      TextField(
                        controller: _passwordController,
                        decoration: const InputDecoration(
                          labelText: '비밀번호',
                          border: OutlineInputBorder(),
                        ),
                        obscureText: true,
                        autofillHints: const [AutofillHints.password],
                        onSubmitted: (_) => _submit(),
                      ),
                    ],
                    if (_mode == _AuthMode.signUp) ...[
                      const SizedBox(height: AppConstants.sectionSpacing),
                      TextField(
                        controller: _confirmPasswordController,
                        decoration: const InputDecoration(
                          labelText: '비밀번호 확인',
                          border: OutlineInputBorder(),
                        ),
                        obscureText: true,
                        onSubmitted: (_) => _submit(),
                      ),
                    ],
                    const SizedBox(height: 18),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: _isLoading ? null : _submit,
                        icon: _isLoading
                            ? const SizedBox.square(
                                dimension: 18,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2),
                              )
                            : Icon(_mode == _AuthMode.reset
                                ? Icons.mark_email_read_outlined
                                : Icons.lock_open_outlined),
                        label: Text(
                            _mode == _AuthMode.reset ? '재설정 메일 보내기' : title),
                      ),
                    ),
                    const SizedBox(height: 10),
                    TextButton(
                      onPressed: _isLoading
                          ? null
                          : () => _setMode(_mode == _AuthMode.reset
                              ? _AuthMode.login
                              : _AuthMode.reset),
                      child: Text(_mode == _AuthMode.reset
                          ? '로그인으로 돌아가기'
                          : '비밀번호를 잊으셨나요?'),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            _SocialLoginCard(
              isLoading: _isLoading,
              onGoogle: () => _socialLogin(PlanFlowOAuthProvider.google),
              onKakao: () => _socialLogin(PlanFlowOAuthProvider.kakao),
              onNaver: () => _socialLogin(PlanFlowOAuthProvider.naver),
            ),
          ],
        ),
      ),
    );
  }
}

class _MessageBox extends StatelessWidget {
  const _MessageBox({
    required this.message,
    required this.isError,
  });

  final String message;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    final color = isError ? Colors.red.shade700 : PlanFlowColors.primaryMid;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.25)),
      ),
      child: Row(
        children: [
          Icon(
            isError ? Icons.error_outline : Icons.check_circle_outline,
            color: color,
          ),
          const SizedBox(width: 10),
          Expanded(child: Text(message)),
        ],
      ),
    );
  }
}

class _SocialLoginCard extends StatelessWidget {
  const _SocialLoginCard({
    required this.isLoading,
    required this.onGoogle,
    required this.onKakao,
    required this.onNaver,
  });

  final bool isLoading;
  final VoidCallback onGoogle;
  final VoidCallback onKakao;
  final VoidCallback onNaver;

  @override
  Widget build(BuildContext context) {
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
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '소셜 로그인',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: PlanFlowColors.primary,
                    fontWeight: FontWeight.w600,
                  ),
            ),
            const SizedBox(height: 10),
            OutlinedButton.icon(
              onPressed: isLoading ? null : onGoogle,
              icon: const Icon(Icons.g_mobiledata),
              label: const Text('Google로 로그인'),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: isLoading ? null : onKakao,
              icon: const Icon(Icons.chat_bubble_outline),
              label: const Text('Kakao로 로그인'),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: isLoading ? null : onNaver,
              icon: const Icon(Icons.eco_outlined),
              label: const Text('Naver로 로그인'),
            ),
          ],
        ),
      ),
    );
  }
}
