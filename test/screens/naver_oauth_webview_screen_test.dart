import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/screens/auth/naver_oauth_webview_screen.dart';
import 'package:webview_flutter/webview_flutter.dart';

void main() {
  group('NaverOAuthWebViewFlow', () {
    test('detects PlanFlow auth callbacks inside the WebView', () {
      expect(
        NaverOAuthWebViewFlow.isAuthCallback(
          Uri.parse('planflow://auth-callback?code=sample'),
        ),
        isTrue,
      );
    });

    test('does not intercept normal Naver or Supabase web pages', () {
      expect(
        NaverOAuthWebViewFlow.isAuthCallback(
          Uri.parse('https://nid.naver.com/oauth2.0/authorize'),
        ),
        isFalse,
      );
      expect(
        NaverOAuthWebViewFlow.isAuthCallback(
          Uri.parse('https://example.supabase.co/auth/v1/callback'),
        ),
        isFalse,
      );
    });

    test('allows only web navigations apart from PlanFlow callbacks', () {
      expect(
        NaverOAuthWebViewFlow.isWebNavigation(
          Uri.parse('https://nid.naver.com/login'),
        ),
        isTrue,
      );
      expect(
        NaverOAuthWebViewFlow.isWebNavigation(
          Uri.parse('intent://nidlogin#Intent;scheme=naversearchapp;end'),
        ),
        isFalse,
      );
    });

    test('treats only main-frame resource errors as page load failures', () {
      const subResourceError = WebResourceError(
        errorCode: -2,
        description: 'sub resource failed',
        isForMainFrame: false,
      );
      const mainFrameError = WebResourceError(
        errorCode: -2,
        description: 'main frame failed',
        isForMainFrame: true,
      );
      const unknownFrameError = WebResourceError(
        errorCode: -2,
        description: 'unknown frame failed',
      );

      expect(NaverOAuthWebViewFlow.isMainFrameError(subResourceError), isFalse);
      expect(NaverOAuthWebViewFlow.isMainFrameError(mainFrameError), isTrue);
      expect(NaverOAuthWebViewFlow.isMainFrameError(unknownFrameError), isTrue);
    });

    test('hides stale user messages while signed in or handling callback', () {
      expect(
        NaverOAuthWebViewFlow.shouldShowUserMessage(
          '네이버 인증을 완료하지 않았어요.',
          isSignedIn: true,
          isHandlingCallback: false,
        ),
        isFalse,
      );
      expect(
        NaverOAuthWebViewFlow.shouldShowUserMessage(
          '네이버 인증을 완료하지 않았어요.',
          isSignedIn: false,
          isHandlingCallback: true,
        ),
        isFalse,
      );
      expect(
        NaverOAuthWebViewFlow.shouldShowUserMessage(
          '네이버 인증을 완료하지 않았어요.',
          isSignedIn: false,
          isHandlingCallback: false,
        ),
        isTrue,
      );
    });

    test('does not render callback progress as an error message', () {
      expect(
        NaverOAuthWebViewFlow.shouldRenderErrorMessage(
          isFailureMessage: false,
          isHandlingCallback: true,
        ),
        isFalse,
      );
      expect(
        NaverOAuthWebViewFlow.shouldRenderErrorMessage(
          isFailureMessage: true,
          isHandlingCallback: true,
        ),
        isFalse,
      );
      expect(
        NaverOAuthWebViewFlow.shouldRenderErrorMessage(
          isFailureMessage: true,
          isHandlingCallback: false,
        ),
        isTrue,
      );
    });
  });
}
