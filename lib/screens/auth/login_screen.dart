import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/constants.dart';
import '../../core/env.dart';
import '../../core/theme.dart';
import '../../providers/auth_provider.dart';
import '../../services/auth_service.dart';
import '../../services/oauth_callback_handler.dart';

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
  final _nameFocusNode = FocusNode();
  final _emailFocusNode = FocusNode();
  final _passwordFocusNode = FocusNode();
  final _confirmPasswordFocusNode = FocusNode();

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
    OAuthCallbackHandler.latestUserMessage.addListener(_handleOAuthMessage);
  }

  @override
  void dispose() {
    OAuthCallbackHandler.latestUserMessage.removeListener(_handleOAuthMessage);
    _emailController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    _nameController.dispose();
    _nameFocusNode.dispose();
    _emailFocusNode.dispose();
    _passwordFocusNode.dispose();
    _confirmPasswordFocusNode.dispose();
    super.dispose();
  }

  void _handleOAuthMessage() {
    final message = OAuthCallbackHandler.latestUserMessage.value;
    if (message != null && message.trim().isNotEmpty) {
      _setMessage(message);
    }
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
        final signedIn = await authProvider.syncCurrentSession();
        if (mounted && signedIn) {
          context.go(AppRoutes.home);
        } else if (mounted) {
          _setMessage('로그인 세션을 확인하지 못했습니다. 잠시 후 다시 시도해 주세요.');
        }
      } else if (_mode == _AuthMode.signUp) {
        final response = await authService.signUpWithEmail(
          email: _emailController.text,
          password: _passwordController.text,
          name: _nameController.text,
        );
        if (response.session == null) {
          _setMessage(
            '회원가입 메일을 보냈습니다. 메일함에서 인증을 완료해 주세요.',
            isError: false,
          );
          _setMode(_AuthMode.login, keepMessage: true);
        } else if (mounted) {
          final signedIn = await authProvider.syncCurrentSession();
          if (mounted && signedIn) {
            context.go(AppRoutes.home);
          } else if (mounted) {
            _setMessage('회원가입 세션을 확인하지 못했습니다. 로그인으로 다시 시도해 주세요.');
          }
        }
      } else {
        await authService.sendPasswordResetEmail(_emailController.text);
        _setMessage(
          '비밀번호 재설정 메일을 보냈습니다. 메일함을 확인해 주세요.',
          isError: false,
        );
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
        _setMessage('로그인 창을 열지 못했습니다. 브라우저 설정을 확인해 주세요.');
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
      return '올바른 이메일을 입력해 주세요.';
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
      return '이메일 인증이 아직 완료되지 않았습니다. 메일함을 확인해 주세요.';
    }
    if (message.contains('User already registered')) {
      return '이미 가입된 이메일입니다. 로그인으로 진행해 주세요.';
    }
    return '인증 처리 중 문제가 발생했습니다. 설정과 입력값을 확인해 주세요.';
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
      _AuthMode.login => '이메일과 비밀번호로 먼저 로그인하거나, 아래 소셜 계정으로 바로 시작하세요.',
      _AuthMode.signUp => '계정을 만들면 일정 데이터가 사용자별로 분리되어 안전하게 저장됩니다.',
      _AuthMode.reset => '가입한 이메일로 비밀번호 재설정 링크를 보내드립니다.',
    };

    return Scaffold(
      backgroundColor: PlanFlowColors.background,
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(AppConstants.defaultPadding),
          children: [
            const SizedBox(height: 20),
            const Center(
              child: Text(
                'PlanFlow',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 38,
                  fontWeight: FontWeight.w900,
                  color: PlanFlowColors.primaryMid,
                  letterSpacing: -1.2,
                ),
              ),
            ),
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 18),
              decoration: BoxDecoration(
                color: PlanFlowColors.primaryMid,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Text(
                    title,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.headlineSmall?.copyWith(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                      fontSize: 24,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    subtitle,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: Colors.white.withValues(alpha: 0.82),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            if (!AppEnv.isSupabaseReady)
              const _MessageBox(
                message:
                    'Supabase 환경값이 없어 실제 로그인은 아직 사용할 수 없습니다. .env에 SUPABASE_URL, SUPABASE_ANON_KEY를 넣어 주세요.',
                isError: true,
              ),
            if (_message != null) ...[
              _MessageBox(message: _message!, isError: _isError),
              const SizedBox(height: 12),
            ],
            _EmailLoginCard(
              mode: _mode,
              isLoading: _isLoading,
              emailController: _emailController,
              passwordController: _passwordController,
              confirmPasswordController: _confirmPasswordController,
              nameController: _nameController,
              nameFocusNode: _nameFocusNode,
              emailFocusNode: _emailFocusNode,
              passwordFocusNode: _passwordFocusNode,
              confirmPasswordFocusNode: _confirmPasswordFocusNode,
              onModeChanged: _setMode,
              onSubmit: _submit,
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

class _EmailLoginCard extends StatelessWidget {
  const _EmailLoginCard({
    required this.mode,
    required this.isLoading,
    required this.emailController,
    required this.passwordController,
    required this.confirmPasswordController,
    required this.nameController,
    required this.nameFocusNode,
    required this.emailFocusNode,
    required this.passwordFocusNode,
    required this.confirmPasswordFocusNode,
    required this.onModeChanged,
    required this.onSubmit,
  });

  final _AuthMode mode;
  final bool isLoading;
  final TextEditingController emailController;
  final TextEditingController passwordController;
  final TextEditingController confirmPasswordController;
  final TextEditingController nameController;
  final FocusNode nameFocusNode;
  final FocusNode emailFocusNode;
  final FocusNode passwordFocusNode;
  final FocusNode confirmPasswordFocusNode;
  final ValueChanged<_AuthMode> onModeChanged;
  final VoidCallback onSubmit;

  @override
  Widget build(BuildContext context) {
    final title = switch (mode) {
      _AuthMode.login => '이메일 로그인',
      _AuthMode.signUp => '이메일 회원가입',
      _AuthMode.reset => '비밀번호 재설정',
    };
    final buttonLabel = switch (mode) {
      _AuthMode.login => '이메일로 로그인',
      _AuthMode.signUp => '이메일로 회원가입',
      _AuthMode.reset => '재설정 메일 보내기',
    };

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
              title,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: PlanFlowColors.primary,
                    fontWeight: FontWeight.w700,
                  ),
            ),
            const SizedBox(height: 12),
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
                mode == _AuthMode.reset ? _AuthMode.login : mode,
              },
              onSelectionChanged: isLoading
                  ? null
                  : (selected) => onModeChanged(selected.first),
            ),
            const SizedBox(height: 16),
            if (mode == _AuthMode.signUp) ...[
              TextField(
                controller: nameController,
                focusNode: nameFocusNode,
                decoration: const InputDecoration(
                  labelText: '이름 또는 닉네임',
                  border: OutlineInputBorder(),
                ),
                textInputAction: TextInputAction.next,
                scrollPadding: const EdgeInsets.only(bottom: 180),
                onSubmitted: (_) =>
                    FocusScope.of(context).requestFocus(emailFocusNode),
              ),
              const SizedBox(height: AppConstants.sectionSpacing),
            ],
            TextField(
              controller: emailController,
              focusNode: emailFocusNode,
              decoration: const InputDecoration(
                labelText: '이메일',
                border: OutlineInputBorder(),
              ),
              keyboardType: TextInputType.emailAddress,
              autofillHints: const [AutofillHints.email],
              textInputAction: TextInputAction.next,
              scrollPadding: const EdgeInsets.only(bottom: 180),
              onSubmitted: (_) {
                if (mode == _AuthMode.reset) {
                  onSubmit();
                  return;
                }
                FocusScope.of(context).requestFocus(passwordFocusNode);
              },
            ),
            if (mode != _AuthMode.reset) ...[
              const SizedBox(height: AppConstants.sectionSpacing),
              TextField(
                controller: passwordController,
                focusNode: passwordFocusNode,
                decoration: const InputDecoration(
                  labelText: '비밀번호',
                  border: OutlineInputBorder(),
                ),
                obscureText: true,
                autofillHints: const [AutofillHints.password],
                textInputAction: mode == _AuthMode.signUp
                    ? TextInputAction.next
                    : TextInputAction.done,
                scrollPadding: const EdgeInsets.only(bottom: 180),
                onSubmitted: (_) {
                  if (mode == _AuthMode.signUp) {
                    FocusScope.of(context)
                        .requestFocus(confirmPasswordFocusNode);
                  } else {
                    onSubmit();
                  }
                },
              ),
            ],
            if (mode == _AuthMode.signUp) ...[
              const SizedBox(height: AppConstants.sectionSpacing),
              TextField(
                controller: confirmPasswordController,
                focusNode: confirmPasswordFocusNode,
                decoration: const InputDecoration(
                  labelText: '비밀번호 확인',
                  border: OutlineInputBorder(),
                ),
                obscureText: true,
                textInputAction: TextInputAction.done,
                scrollPadding: const EdgeInsets.only(bottom: 180),
                onSubmitted: (_) => onSubmit(),
              ),
            ],
            const SizedBox(height: 18),
            FilledButton.icon(
              onPressed: isLoading ? null : onSubmit,
              icon: isLoading
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Icon(
                      mode == _AuthMode.reset
                          ? Icons.mark_email_read_outlined
                          : Icons.lock_open_outlined,
                    ),
              label: Text(buttonLabel),
            ),
            const SizedBox(height: 10),
            TextButton(
              onPressed: isLoading
                  ? null
                  : () => onModeChanged(
                        mode == _AuthMode.reset
                            ? _AuthMode.login
                            : _AuthMode.reset,
                      ),
              child: Text(
                mode == _AuthMode.reset ? '로그인으로 돌아가기' : '비밀번호를 잊으셨나요?',
              ),
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
              '간편 로그인',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: PlanFlowColors.primary,
                    fontWeight: FontWeight.w700,
                  ),
            ),
            const SizedBox(height: 12),
            _BrandLoginButton(
              label: 'Google로 계속하기',
              mark: 'G',
              backgroundColor: Colors.white,
              foregroundColor: const Color(0xFF202124),
              borderColor: const Color(0xFFDADCE0),
              onPressed: isLoading ? null : onGoogle,
            ),
            const SizedBox(height: 8),
            _BrandLoginButton(
              label: '카카오로 계속하기',
              mark: 'TALK',
              backgroundColor: const Color(0xFFFEE500),
              foregroundColor: const Color(0xFF191919),
              borderColor: const Color(0xFFFEE500),
              onPressed: isLoading ? null : onKakao,
            ),
            const SizedBox(height: 8),
            _BrandLoginButton(
              label: '네이버로 계속하기',
              mark: 'N',
              backgroundColor: const Color(0xFF03C75A),
              foregroundColor: Colors.white,
              borderColor: const Color(0xFF03C75A),
              onPressed: isLoading ? null : onNaver,
            ),
          ],
        ),
      ),
    );
  }
}

class _BrandLoginButton extends StatelessWidget {
  const _BrandLoginButton({
    required this.label,
    required this.mark,
    required this.backgroundColor,
    required this.foregroundColor,
    required this.borderColor,
    required this.onPressed,
  });

  final String label;
  final String mark;
  final Color backgroundColor;
  final Color foregroundColor;
  final Color borderColor;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final disabled = onPressed == null;
    return SizedBox(
      height: 48,
      child: OutlinedButton(
        onPressed: onPressed,
        style: OutlinedButton.styleFrom(
          backgroundColor: disabled
              ? backgroundColor.withValues(alpha: 0.45)
              : backgroundColor,
          foregroundColor: disabled
              ? foregroundColor.withValues(alpha: 0.45)
              : foregroundColor,
          side: BorderSide(
            color: disabled ? borderColor.withValues(alpha: 0.35) : borderColor,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          textStyle: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w700,
          ),
        ),
        child: Stack(
          alignment: Alignment.center,
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: _BrandMark(
                mark: mark,
                color: foregroundColor,
                isGoogle: mark == 'G',
              ),
            ),
            Text(label),
          ],
        ),
      ),
    );
  }
}

class _BrandMark extends StatelessWidget {
  const _BrandMark({
    required this.mark,
    required this.color,
    required this.isGoogle,
  });

  final String mark;
  final Color color;
  final bool isGoogle;

  @override
  Widget build(BuildContext context) {
    if (isGoogle) {
      return const Text(
        'G',
        style: TextStyle(
          color: Color(0xFF4285F4),
          fontSize: 20,
          fontWeight: FontWeight.w800,
        ),
      );
    }

    return Text(
      mark,
      style: TextStyle(
        color: color,
        fontSize: mark.length > 1 ? 11 : 20,
        fontWeight: FontWeight.w900,
        letterSpacing: mark.length > 1 ? -0.4 : 0,
      ),
    );
  }
}
