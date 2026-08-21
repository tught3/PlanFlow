import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final script = File('scripts/build-internal-aab.ps1');

  test(
    'internal AAB builder keeps map preflight and delegates through flutter-local.ps1',
    () {
      expect(
        script.existsSync(),
        isTrue,
        reason: 'scripts/build-internal-aab.ps1 should exist in this repo.',
      );

      final source = script.readAsStringSync().replaceAll('\r\n', '\n');

      expect(source, contains('Assert-ReleaseMapDefines'));
      expect(source, contains('GOOGLE_MAPS_API_KEY'));
      expect(source, contains('TMAP_API_KEY'));
      expect(source, contains('NAVER_MAP_CLIENT_ID'));
      expect(source, contains("Join-Path \$PSScriptRoot 'flutter-local.ps1'"));
      expect(source, contains(r'& $FlutterLocal build appbundle --release --no-pub'));
      expect(source, isNot(contains('& flutter build appbundle')));
      expect(source, isNot(contains('powershell.exe flutter build appbundle')));
    },
    skip: !script.existsSync(),
  );
}
