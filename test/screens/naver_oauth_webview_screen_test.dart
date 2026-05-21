import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/screens/auth/naver_oauth_webview_screen.dart';

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
  });
}
