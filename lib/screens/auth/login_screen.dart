import 'dart:async';

import 'package:flutter/material.dart';
import '../../core/constants.dart';
import '../../core/analytics_service.dart';
import '../../core/env.dart';
import '../../core/theme.dart';
import '../../providers/auth_provider.dart';
import '../../services/auth_service.dart';
import '../../services/oauth_callback_handler.dart';
import '../../l10n/app_l10n.dart';

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

class _LoginScreenState extends State<LoginScreen> with WidgetsBindingObserver {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();
  final _nameController = TextEditingController();
  final _nameFocusNode = FocusNode();
  final _emailFocusNode = FocusNode();
  final _passwordFocusNode = FocusNode();
  final _confirmPasswordFocusNode = FocusNode();
  final _scrollController = ScrollController();
  final _messageKey = GlobalKey();

  AuthService? _authService;
  Timer? _supabaseReadyPoller;

  _AuthMode _mode = _AuthMode.login;
  bool _isLoading = false;
  String? _message;
  bool _isError = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    OAuthCallbackHandler.latestUserMessage.addListener(_handleOAuthMessage);
    _startSupabaseReadyPoller();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    OAuthCallbackHandler.latestUserMessage.removeListener(_handleOAuthMessage);
    _emailController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    _nameController.dispose();
    _scrollController.dispose();
    _nameFocusNode.dispose();
    _emailFocusNode.dispose();
    _passwordFocusNode.dispose();
    _confirmPasswordFocusNode.dispose();
    _supabaseReadyPoller?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _isLoading) {
      unawaited(_resolvePendingOAuthOnResume());
    }
  }

  void _handleOAuthMessage() {
    final message = OAuthCallbackHandler.latestUserMessage.value;
    if (authProvider.isSignedIn) {
      OAuthCallbackHandler.clearLatestUserMessage();
      if (mounted) {
        setState(() {
          _isLoading = false;
          _message = null;
        });
      }
      return;
    }
    if (message != null && message.trim().isNotEmpty) {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
      _setMessage(message);
    }
  }

  Future<void> _submit() async {
    FocusScope.of(context).unfocus();
    // 이전에 중단된 소셜 로그인 pending이 남아있으면 이메일 로그인 시작 전에 제거한다.
    // signUp 흐름의 markPendingEmailConfirmation은 아래에서 별도로 설정하므로 영향 없음.
    OAuthCallbackHandler.clearPendingCallback();
    final authService = await _resolveAuthServiceWhenReady();
    if (!mounted) {
      return;
    }
    final l10n = appL10n(context);
    if (authService == null) {
      _setMessage(_supabaseUnavailableMessage(forSocialLogin: false));
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

    var keepLoadingForNavigation = false;
    try {
      if (_mode == _AuthMode.login) {
        await authService.signInWithEmail(
          email: _emailController.text,
          password: _passwordController.text,
        );
        final signedIn = await authProvider.syncCurrentSession();
        if (mounted && signedIn) {
          keepLoadingForNavigation = true;
          unawaited(AnalyticsService.logLogin(method: 'email'));
        } else if (mounted) {
          _setMessage(l10n.loginSessionFailed);
        }
      } else if (_mode == _AuthMode.signUp) {
        OAuthCallbackHandler.markPendingEmailConfirmation();
        final response = await authService.signUpWithEmail(
          email: _emailController.text,
          password: _passwordController.text,
          name: _nameController.text,
        );
        if (response.session == null) {
          _setMessage(
            l10n.signUpEmailSent,
            isError: false,
          );
          _setMode(_AuthMode.login, keepMessage: true);
        } else if (mounted) {
          OAuthCallbackHandler.clearPendingCallback();
          final signedIn = await authProvider.syncCurrentSession();
          if (mounted && signedIn) {
            keepLoadingForNavigation = true;
            unawaited(AnalyticsService.logSignUp(method: 'email'));
          } else if (mounted) {
            _setMessage(l10n.signUpSessionFailed);
          }
        }
      } else {
        await authService.sendPasswordResetEmail(_emailController.text);
        _setMessage(
          l10n.passwordResetSent,
          isError: false,
        );
      }
    } catch (error) {
      if (_mode == _AuthMode.signUp) {
        OAuthCallbackHandler.clearPendingCallback();
      }
      _setMessage(_friendlyAuthMessage(error));
    } finally {
      if (mounted && !keepLoadingForNavigation) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _socialLogin(PlanFlowOAuthProvider provider) async {
    // 이전에 중단된 다른 소셜 플로우의 stale pending을 먼저 제거한다.
    // Kakao/Naver는 아래에서 markPendingLogin으로 새로 설정한다.
    OAuthCallbackHandler.clearPendingCallback();

    final authService = await _resolveAuthServiceWhenReady();
    if (!mounted) {
      return;
    }
    final l10n = appL10n(context);
    if (authService == null) {
      _setMessage(_supabaseUnavailableMessage(forSocialLogin: true));
      return;
    }

    // 이미 로그인된 상태라면 새 소셜 로그인을 시작하지 않는다.
    if (authProvider.isSignedIn) {
      _setMessage('이미 로그인된 상태입니다.');
      return;
    }

    setState(() {
      _isLoading = true;
      _message = null;
    });

    var keepLoadingForCallback = false;
    try {
      if (provider == PlanFlowOAuthProvider.google) {
        await authService.signInWithGoogleNative();
        // Google 네이티브 성공 후에도 stale pending이 남지 않도록 제거한다.
        OAuthCallbackHandler.clearPendingCallback();
        final signedIn = await authProvider.syncCurrentSession();
        if (mounted && signedIn) {
          keepLoadingForCallback = true;
          unawaited(AnalyticsService.logLogin(method: 'google'));
        } else if (mounted) {
          _setMessage(l10n.loginSessionFailed);
        }
      } else {
        // clearPendingCallback은 메서드 시작 시 이미 호출했으므로
        // 여기서 바로 새 pending을 마킹한다.
        OAuthCallbackHandler.markPendingLogin(provider);
        final launched = await authService.signInWithOAuth(provider);
        if (!launched) {
          OAuthCallbackHandler.clearPendingCallback();
          _setMessage(l10n.oauthLaunchFailed);
        } else {
          keepLoadingForCallback = true;
        }
      }
    } catch (error) {
      OAuthCallbackHandler.clearPendingCallback();
      _setMessage(_friendlyAuthMessage(error, provider: provider));
    } finally {
      if (mounted && !keepLoadingForCallback) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _resolvePendingOAuthOnResume() async {
    if (!OAuthCallbackHandler.hasPendingLogin()) {
      return;
    }
    await Future<void>.delayed(const Duration(seconds: 4));
    if (!mounted || !_isLoading || !OAuthCallbackHandler.hasPendingLogin()) {
      return;
    }
    if (OAuthCallbackHandler.latestUserMessage.value != null) {
      return;
    }

    // 재개 시점의 pending 메서드를 읽어둔다 (clearPendingCallback 전에 확보).
    final method = switch (OAuthCallbackHandler.pendingLoginMethod) {
      'naver' => '네이버',
      'kakao' => '카카오',
      'google' => 'Google',
      _ => '소셜',
    };

    final signedIn = await authProvider.syncCurrentSession();
    if (!mounted) {
      return;
    }
    if (signedIn) {
      // 로그인 성공 — 콜백 핸들러가 이미 pending을 정리했을 수 있지만
      // 만약 남아있는 경우를 대비해 여기서도 명시적으로 제거한다.
      OAuthCallbackHandler.clearPendingCallback();
      setState(() {
        _isLoading = false;
      });
      return;
    }

    // 인증 미완료: pending을 정리하고 재시도 안내 메시지를 표시한다.
    OAuthCallbackHandler.clearPendingCallback();
    _setMessage(
      '$method 인증이 완료되지 않았어요. 브라우저에서 PlanFlow로 돌아오기 허용을 확인한 뒤 다시 시도해 주세요.',
    );
    setState(() {
      _isLoading = false;
    });
  }

  String? _validate() {
    final email = _emailController.text.trim();
    final password = _passwordController.text;

    if (email.isEmpty || !email.contains('@')) {
      return appL10n(context).invalidEmail;
    }
    if (_mode == _AuthMode.reset) {
      return null;
    }
    if (password.length < 6) {
      return appL10n(context).shortPassword;
    }
    if (_mode == _AuthMode.signUp &&
        password != _confirmPasswordController.text) {
      return appL10n(context).passwordMismatch;
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
    _ensureMessageVisible();
  }

  void _startSupabaseReadyPoller() {
    if (AppEnv.isSupabaseReady || AppEnv.isSupabaseInitializationFailed) {
      return;
    }
    _supabaseReadyPoller?.cancel();
    _supabaseReadyPoller = Timer.periodic(const Duration(milliseconds: 200), (
      timer,
    ) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      if (AppEnv.isSupabaseReady || AppEnv.isSupabaseInitializationFailed) {
        timer.cancel();
        setState(() {});
      }
    });
  }

  AuthService? _resolveAuthService() {
    if (widget._authService != null) {
      _authService = widget._authService;
      return _authService;
    }
    if (!AppEnv.isSupabaseReady) {
      return null;
    }
    return _authService ??= AuthService();
  }

  Future<AuthService?> _resolveAuthServiceWhenReady() async {
    if (widget._authService != null) {
      _authService = widget._authService;
      return _authService;
    }
    if (AppEnv.isSupabaseReady) {
      return _authService ??= AuthService();
    }

    final deadline = DateTime.now().add(const Duration(seconds: 6));
    while (!AppEnv.isSupabaseReady &&
        !AppEnv.isSupabaseInitializationFailed &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    return _resolveAuthService();
  }

  String _supabaseUnavailableMessage({required bool forSocialLogin}) {
    if (!AppEnv.hasValidSupabaseConfig) {
      return forSocialLogin
          ? appL10n(context).supabaseSocialMissing
          : appL10n(context).supabaseLoginMissing;
    }
    if (AppEnv.isSupabaseInitializationFailed) {
      return AppEnv.supabaseInitializationErrorMessage ??
          appL10n(context).authGenericError;
    }
    return 'Supabase 초기화가 아직 끝나지 않았습니다. 잠시 후 다시 시도해 주세요.';
  }

  void _ensureMessageVisible() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final messageContext = _messageKey.currentContext;
      if (!mounted || messageContext == null) {
        return;
      }
      Scrollable.ensureVisible(
        messageContext,
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOutCubic,
        alignment: 0.08,
        alignmentPolicy: ScrollPositionAlignmentPolicy.explicit,
      );
    });
  }

  String _friendlyAuthMessage(
    Object error, {
    PlanFlowOAuthProvider? provider,
  }) {
    final message = error.toString().trim();

    if (provider == PlanFlowOAuthProvider.google &&
        message.isNotEmpty &&
        !message.contains(appL10n(context).authGenericError)) {
      return message;
    }

    if (message.contains('Google 로그인 설정이 없습니다') ||
        message.contains('Google 로그인이 취소되었습니다') ||
        message.contains('Google ID 토큰을 받지 못했습니다') ||
        message.contains('Google access token을 받지 못했습니다')) {
      return message;
    }
    if (message.contains('AuthException') ||
        message.contains('AuthApiException') ||
        message.contains('PlatformException')) {
      return message;
    }
    if (message.contains('Invalid login credentials')) {
      return appL10n(context).authInvalidCredentials;
    }
    if (message.contains('Email not confirmed')) {
      return appL10n(context).authEmailNotConfirmed;
    }
    if (message.contains('User already registered')) {
      return appL10n(context).authAlreadyRegistered;
    }
    return appL10n(context).authGenericError;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = appL10n(context);
    final supabaseBannerMessage = !AppEnv.hasValidSupabaseConfig
        ? l10n.supabaseLoginMissing
        : AppEnv.isSupabaseInitializationFailed
            ? (AppEnv.supabaseInitializationErrorMessage ??
                l10n.authGenericError)
            : null;
    final title = switch (_mode) {
      _AuthMode.login => l10n.loginTitle,
      _AuthMode.signUp => l10n.signUpTitle,
      _AuthMode.reset => l10n.passwordResetTitle,
    };
    final subtitle = switch (_mode) {
      _AuthMode.login => l10n.loginSubtitle,
      _AuthMode.signUp => l10n.signUpSubtitle,
      _AuthMode.reset => l10n.passwordResetSubtitle,
    };

    return Scaffold(
      backgroundColor: PlanFlowColors.background,
      body: SafeArea(
        child: ListView(
          controller: _scrollController,
          padding: const EdgeInsets.all(AppConstants.defaultPadding),
          children: [
            const SizedBox(height: 10),
            const Center(
              child: Text(
                'PlanFlow',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 34,
                  fontWeight: FontWeight.w900,
                  color: PlanFlowColors.primaryMid,
                  letterSpacing: -1.2,
                ),
              ),
            ),
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
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
                      fontSize: 22,
                    ),
                  ),
                  const SizedBox(height: 4),
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
            const SizedBox(height: 12),
            if (supabaseBannerMessage != null)
              _MessageBox(
                message: supabaseBannerMessage,
                isError: true,
              ),
            if (_message != null) ...[
              _MessageBox(
                key: _messageKey,
                message: _message!,
                isError: _isError,
              ),
              const SizedBox(height: 10),
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
            if (_mode != _AuthMode.reset) ...[
              const SizedBox(height: 12),
              _SocialLoginCard(
                isLoading: _isLoading,
                onGoogle: () => _socialLogin(PlanFlowOAuthProvider.google),
                onKakao: () => _socialLogin(PlanFlowOAuthProvider.kakao),
                onNaver: () => _socialLogin(PlanFlowOAuthProvider.naver),
              ),
            ],
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
      _AuthMode.login => appL10n(context).emailLogin,
      _AuthMode.signUp => appL10n(context).signUpWithEmail,
      _AuthMode.reset => appL10n(context).sendPasswordReset,
    };
    final buttonLabel = switch (mode) {
      _AuthMode.login => appL10n(context).loginWithEmail,
      _AuthMode.signUp => appL10n(context).signUpWithEmail,
      _AuthMode.reset => appL10n(context).sendPasswordReset,
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
        padding: const EdgeInsets.all(12),
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
            const SizedBox(height: 10),
            SegmentedButton<_AuthMode>(
              segments: [
                ButtonSegment(
                  value: _AuthMode.login,
                  label: Text(appL10n(context).loginTitle),
                  icon: const Icon(Icons.login),
                ),
                ButtonSegment(
                  value: _AuthMode.signUp,
                  label: Text(appL10n(context).signUpTitle),
                  icon: const Icon(Icons.person_add_alt_1),
                ),
              ],
              selected: <_AuthMode>{
                mode == _AuthMode.reset ? _AuthMode.login : mode,
              },
              onSelectionChanged: isLoading
                  ? null
                  : (selected) => onModeChanged(selected.first),
            ),
            const SizedBox(height: 12),
            if (mode == _AuthMode.signUp) ...[
              TextField(
                controller: nameController,
                focusNode: nameFocusNode,
                decoration: InputDecoration(
                  labelText: appL10n(context).name,
                  border: const OutlineInputBorder(),
                ),
                textInputAction: TextInputAction.next,
                scrollPadding: const EdgeInsets.only(bottom: 180),
                onSubmitted: (_) =>
                    FocusScope.of(context).requestFocus(emailFocusNode),
              ),
              const SizedBox(height: 10),
            ],
            TextField(
              controller: emailController,
              focusNode: emailFocusNode,
              decoration: InputDecoration(
                labelText: appL10n(context).email,
                border: const OutlineInputBorder(),
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
              const SizedBox(height: 10),
              TextField(
                controller: passwordController,
                focusNode: passwordFocusNode,
                decoration: InputDecoration(
                  labelText: appL10n(context).password,
                  border: const OutlineInputBorder(),
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
              const SizedBox(height: 10),
              TextField(
                controller: confirmPasswordController,
                focusNode: confirmPasswordFocusNode,
                decoration: InputDecoration(
                  labelText: appL10n(context).confirmPassword,
                  border: const OutlineInputBorder(),
                ),
                obscureText: true,
                textInputAction: TextInputAction.done,
                scrollPadding: const EdgeInsets.only(bottom: 180),
                onSubmitted: (_) => onSubmit(),
              ),
            ],
            const SizedBox(height: 14),
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
            const SizedBox(height: 6),
            TextButton(
              onPressed: isLoading
                  ? null
                  : () => onModeChanged(
                        mode == _AuthMode.reset
                            ? _AuthMode.login
                            : _AuthMode.reset,
                      ),
              child: Text(
                mode == _AuthMode.reset
                    ? appL10n(context).backToLogin
                    : appL10n(context).forgotPassword,
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
    super.key,
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
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              appL10n(context).simpleLogin,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: PlanFlowColors.primary,
                    fontWeight: FontWeight.w700,
                  ),
            ),
            const SizedBox(height: 12),
            _BrandLoginButton(
              label: appL10n(context).googleContinue,
              mark: 'G',
              backgroundColor: Colors.white,
              foregroundColor: const Color(0xFF202124),
              borderColor: const Color(0xFFDADCE0),
              onPressed: isLoading ? null : onGoogle,
            ),
            const SizedBox(height: 8),
            _BrandLoginButton(
              label: appL10n(context).kakaoContinue,
              mark: 'TALK',
              backgroundColor: const Color(0xFFFEE500),
              foregroundColor: const Color(0xFF191919),
              borderColor: const Color(0xFFFEE500),
              onPressed: isLoading ? null : onKakao,
            ),
            const SizedBox(height: 6),
            _BrandLoginButton(
              label: appL10n(context).naverContinue,
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
      height: 44,
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
            fontSize: 13,
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
