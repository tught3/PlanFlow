import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../core/theme.dart';
import '../../providers/auth_provider.dart';
import '../../services/auth_service.dart';
import '../../services/oauth_callback_handler.dart';

class NaverOAuthWebViewScreen extends StatefulWidget {
  const NaverOAuthWebViewScreen({
    super.key,
    this.forceConsent = false,
    AuthService? authService,
    OAuthCallbackHandler? callbackHandler,
    WebViewController Function()? webViewControllerFactory,
  })  : _authService = authService,
        _callbackHandler = callbackHandler,
        _webViewControllerFactory = webViewControllerFactory;

  final bool forceConsent;
  final AuthService? _authService;
  final OAuthCallbackHandler? _callbackHandler;
  final WebViewController Function()? _webViewControllerFactory;

  @override
  State<NaverOAuthWebViewScreen> createState() =>
      _NaverOAuthWebViewScreenState();
}

class _NaverOAuthWebViewScreenState extends State<NaverOAuthWebViewScreen> {
  late final AuthService _authService;
  late final OAuthCallbackHandler _callbackHandler;
  late final WebViewController _webViewController;

  bool _isLoading = true;
  bool _isHandlingCallback = false;
  String? _message;

  @override
  void initState() {
    super.initState();
    _authService = widget._authService ?? AuthService();
    _callbackHandler = widget._callbackHandler ?? OAuthCallbackHandler();
    _webViewController =
        widget._webViewControllerFactory?.call() ?? WebViewController();
    OAuthCallbackHandler.latestUserMessage.addListener(_handleOAuthMessage);
    _configureWebView();
    unawaited(_loadNaverOAuth());
  }

  @override
  void dispose() {
    OAuthCallbackHandler.latestUserMessage.removeListener(_handleOAuthMessage);
    super.dispose();
  }

  void _configureWebView() {
    _webViewController
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.white)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (_) {
            if (mounted && !_isHandlingCallback) {
              setState(() {
                _isLoading = true;
              });
            }
          },
          onPageFinished: (_) {
            if (mounted && !_isHandlingCallback) {
              setState(() {
                _isLoading = false;
              });
            }
          },
          onWebResourceError: (error) {
            if (!mounted || _isHandlingCallback) {
              return;
            }
            setState(() {
              _isLoading = false;
              _message = '네이버 인증 화면을 불러오지 못했어요. 네트워크 상태를 확인한 뒤 다시 시도해 주세요.';
            });
          },
          onNavigationRequest: (request) {
            final uri = Uri.tryParse(request.url);
            if (uri != null && NaverOAuthWebViewFlow.isAuthCallback(uri)) {
              unawaited(_handleCallback(uri));
              return NavigationDecision.prevent;
            }
            if (uri != null && !NaverOAuthWebViewFlow.isWebNavigation(uri)) {
              setState(() {
                _isLoading = false;
                _message =
                    '네이버 앱 간편로그인은 기기 보안 설정에 막힐 수 있어요. 이 화면에서 네이버 아이디로 로그인해 주세요.';
              });
              return NavigationDecision.prevent;
            }
            return NavigationDecision.navigate;
          },
        ),
      );
  }

  Future<void> _loadNaverOAuth() async {
    setState(() {
      _isLoading = true;
      _message = null;
    });
    try {
      OAuthCallbackHandler.markPendingLogin(PlanFlowOAuthProvider.naver);
      final uri = await _authService.buildOAuthSignInUri(
        PlanFlowOAuthProvider.naver,
        forceConsent: widget.forceConsent,
      );
      debugPrint(
        'Naver OAuth WebView load: host=${uri.host} path=${uri.path} '
        'forceConsent=${widget.forceConsent}',
      );
      await _webViewController.loadRequest(uri);
    } catch (error, stackTrace) {
      debugPrint('Naver OAuth WebView load failed: $error');
      debugPrintStack(stackTrace: stackTrace);
      OAuthCallbackHandler.clearPendingCallback();
      if (!mounted) {
        return;
      }
      setState(() {
        _isLoading = false;
        _message = '네이버 인증 화면을 열지 못했어요. 잠시 후 다시 시도해 주세요.';
      });
    }
  }

  Future<void> _handleCallback(Uri uri) async {
    if (_isHandlingCallback) {
      return;
    }
    setState(() {
      _isHandlingCallback = true;
      _isLoading = true;
      _message = '네이버 인증을 확인하고 있어요.';
    });
    await _callbackHandler.handleAuthCallbackUri(uri);
    if (!mounted) {
      return;
    }
    if (OAuthCallbackHandler.latestUserMessage.value != null) {
      setState(() {
        _isHandlingCallback = false;
        _isLoading = false;
      });
      return;
    }
    if (!authProvider.isSignedIn) {
      setState(() {
        _isHandlingCallback = false;
        _isLoading = false;
        _message = '네이버 인증은 돌아왔지만 로그인 세션을 확인하지 못했어요. 다시 시도해 주세요.';
      });
    }
  }

  void _handleOAuthMessage() {
    final message = OAuthCallbackHandler.latestUserMessage.value;
    if (message == null || message.trim().isEmpty || !mounted) {
      return;
    }
    setState(() {
      _message = message;
      _isLoading = false;
      _isHandlingCallback = false;
    });
  }

  Future<bool> _onWillPop() async {
    if (_isHandlingCallback) {
      return false;
    }
    OAuthCallbackHandler.clearPendingCallback();
    context.pop(false);
    return false;
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) {
          unawaited(_onWillPop());
        }
      },
      child: Scaffold(
        backgroundColor: PlanFlowColors.background,
        appBar: AppBar(
          title: const Text('네이버 로그인'),
          leading: IconButton(
            icon: const Icon(Icons.close),
            onPressed: _isHandlingCallback ? null : () => _onWillPop(),
          ),
        ),
        body: Column(
          children: [
            if (_isLoading) const LinearProgressIndicator(minHeight: 3),
            if (_message != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                child: _OAuthMessage(
                  message: _message!,
                  onRetry: _loadNaverOAuth,
                ),
              ),
            Expanded(
              child: WebViewWidget(controller: _webViewController),
            ),
          ],
        ),
      ),
    );
  }
}

class _OAuthMessage extends StatelessWidget {
  const _OAuthMessage({
    required this.message,
    required this.onRetry,
  });

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.red.shade50,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.red.shade100),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Icon(Icons.error_outline, color: Colors.red.shade700),
            const SizedBox(width: 10),
            Expanded(child: Text(message)),
            TextButton(
              onPressed: onRetry,
              child: const Text('재시도'),
            ),
          ],
        ),
      ),
    );
  }
}

class NaverOAuthWebViewFlow {
  const NaverOAuthWebViewFlow._();

  static bool isAuthCallback(Uri uri) {
    return uri.scheme == 'planflow' && uri.host == 'auth-callback';
  }

  static bool isWebNavigation(Uri uri) {
    return uri.scheme == 'https' || uri.scheme == 'http';
  }
}
