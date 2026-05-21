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
  WebViewController? _webViewController;

  bool _isLoading = true;
  bool _isHandlingCallback = false;
  bool _loadScheduled = false;
  String? _message;

  @override
  void initState() {
    super.initState();
    _authService = widget._authService ?? AuthService();
    _callbackHandler = widget._callbackHandler ?? OAuthCallbackHandler();
    OAuthCallbackHandler.latestUserMessage.addListener(_handleOAuthMessage);
    _prepareWebView();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_loadScheduled) {
        _loadScheduled = true;
        unawaited(_loadNaverOAuth());
      }
    });
  }

  @override
  void dispose() {
    OAuthCallbackHandler.latestUserMessage.removeListener(_handleOAuthMessage);
    super.dispose();
  }

  void _prepareWebView() {
    try {
      _logOAuthPhase('prepare_start');
      final controller =
          widget._webViewControllerFactory?.call() ?? WebViewController();
      _configureWebView(controller);
      _webViewController = controller;
      _logOAuthPhase('prepare_success');
    } catch (error, stackTrace) {
      _logOAuthPhase(
        'prepare_failed',
        error: error,
        stackTrace: stackTrace,
      );
      setState(() {
        _isLoading = false;
        _message = '앱 안 로그인 화면을 준비하지 못했어요. 잠시 후 다시 시도해 주세요.';
      });
    }
  }

  void _configureWebView(WebViewController controller) {
    controller
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
            final errorUri = error.url == null ? null : Uri.tryParse(error.url!);
            if (!NaverOAuthWebViewFlow.isMainFrameError(error)) {
              _logOAuthPhase(
                'web_resource_ignored',
                uri: errorUri,
                error: '${error.errorCode}:${error.description}',
                isForMainFrame: error.isForMainFrame,
              );
              return;
            }
            _logOAuthPhase(
              'web_resource_failed',
              uri: errorUri,
              error: '${error.errorCode}:${error.description}',
              isForMainFrame: error.isForMainFrame,
            );
            setState(() {
              _isLoading = false;
              _message = '네이버 로그인 페이지를 불러오지 못했어요. 네트워크 상태를 확인한 뒤 다시 시도해 주세요.';
            });
          },
          onNavigationRequest: (request) {
            final uri = Uri.tryParse(request.url);
            if (uri != null && NaverOAuthWebViewFlow.isAuthCallback(uri)) {
              unawaited(_handleCallback(uri));
              return NavigationDecision.prevent;
            }
            if (uri != null && !NaverOAuthWebViewFlow.isWebNavigation(uri)) {
              _logOAuthPhase(
                'blocked_non_web_navigation',
                uri: uri,
              );
              setState(() {
                _isLoading = false;
                _message =
                    '네이버 앱 버튼 대신 이 화면에서 네이버 아이디로 로그인해 주세요.';
              });
              return NavigationDecision.prevent;
            }
            return NavigationDecision.navigate;
          },
        ),
      );
  }

  Future<void> _loadNaverOAuth() async {
    final controller = _webViewController;
    if (controller == null) {
      _logOAuthPhase('load_skipped_no_controller');
      if (!mounted) {
        return;
      }
      setState(() {
        _isLoading = false;
        _message = '앱 안 로그인 화면을 준비하지 못했어요. 잠시 후 다시 시도해 주세요.';
      });
      return;
    }

    setState(() {
      _isLoading = true;
      _message = null;
    });
    late final Uri uri;
    try {
      _logOAuthPhase('url_start');
      OAuthCallbackHandler.markPendingLogin(PlanFlowOAuthProvider.naver);
      uri = await _authService.buildOAuthSignInUri(
        PlanFlowOAuthProvider.naver,
        forceConsent: widget.forceConsent,
      );
      _logOAuthPhase('url_success', uri: uri);
    } catch (error, stackTrace) {
      _logOAuthPhase(
        'url_failed',
        error: error,
        stackTrace: stackTrace,
      );
      OAuthCallbackHandler.clearPendingCallback();
      if (!mounted) {
        return;
      }
      setState(() {
        _isLoading = false;
        _message = '네이버 로그인 주소를 만들지 못했어요. 잠시 후 다시 시도해 주세요.';
      });
      return;
    }

    try {
      _logOAuthPhase('load_start', uri: uri);
      await controller.loadRequest(uri);
      _logOAuthPhase('load_requested', uri: uri);
    } catch (error, stackTrace) {
      _logOAuthPhase(
        'load_failed',
        uri: uri,
        error: error,
        stackTrace: stackTrace,
      );
      OAuthCallbackHandler.clearPendingCallback();
      if (!mounted) {
        return;
      }
      setState(() {
        _isLoading = false;
        _message = '네이버 로그인 페이지를 불러오지 못했어요. 잠시 후 다시 시도해 주세요.';
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
              child: _webViewController == null
                  ? const SizedBox.shrink()
                  : WebViewWidget(controller: _webViewController!),
            ),
          ],
        ),
      ),
    );
  }

  void _logOAuthPhase(
    String phase, {
    Uri? uri,
    Object? error,
    StackTrace? stackTrace,
    bool? isForMainFrame,
  }) {
    debugPrint(
      'Naver OAuth phase=$phase '
      'host=${uri?.host ?? 'none'} '
      'path=${uri?.path ?? 'none'} '
      'forceConsent=${widget.forceConsent} '
      'mainFrame=${isForMainFrame ?? 'unknown'} '
      'errorType=${error == null ? 'none' : error.runtimeType}',
    );
    if (error != null) {
      debugPrint('Naver OAuth phase=$phase error=$error');
    }
    if (stackTrace != null) {
      debugPrintStack(stackTrace: stackTrace);
    }
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

  static bool isMainFrameError(WebResourceError error) {
    return error.isForMainFrame ?? true;
  }
}
