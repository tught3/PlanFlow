import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Android WebView plugin registration', () {
    test('registers WebView in the Android plugin registrant', () {
      final registrant = File(
        'android/app/src/main/java/io/flutter/plugins/GeneratedPluginRegistrant.java',
      );

      expect(registrant.existsSync(), isTrue);
      expect(
        registrant.readAsStringSync(),
        contains('io.flutter.plugins.webviewflutter.WebViewFlutterPlugin'),
        reason:
            'PlanFlow keeps an Android source registrant. Naver login uses an '
            'in-app WebView, so this registrant must include '
            'webview_flutter_android.',
      );
    });

    test('includes webview_flutter_android in Flutter plugin metadata', () {
      final dependenciesFile = File('.flutter-plugins-dependencies');

      expect(
        dependenciesFile.existsSync(),
        isTrue,
        reason:
            'Run flutter pub get through scripts/flutter-local.ps1 before '
            'running Android builds or tests.',
      );

      final dependencies =
          jsonDecode(dependenciesFile.readAsStringSync()) as Map<String, Object?>;
      final plugins = dependencies['plugins'] as Map<String, Object?>;
      final androidPlugins = (plugins['android'] as List<Object?>)
          .cast<Map<String, Object?>>();

      expect(
        androidPlugins.any(
          (plugin) => plugin['name'] == 'webview_flutter_android',
        ),
        isTrue,
        reason:
            'Naver login uses an in-app WebView. Android must register '
            'webview_flutter_android so plugins.flutter.io/webview exists.',
      );
    });
  });
}
