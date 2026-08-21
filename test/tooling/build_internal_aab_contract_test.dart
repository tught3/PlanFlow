import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final script = File('scripts/build-internal-aab.ps1');
  final gradleScript = File('android/app/build.gradle.kts');

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
      expect(source,
          contains(r'& $FlutterLocal build appbundle --release --no-pub'));
      expect(source, contains(r'$MapArtifactMarkerPath'));
      expect(
          source,
          contains(
              r'Get-FileHash -LiteralPath $resolvedAabPath -Algorithm SHA256'));
      expect(source, contains('aabPath='));
      expect(source, contains('sha256='));
      expect(source, isNot(contains('& flutter build appbundle')));
      expect(source, isNot(contains('powershell.exe flutter build appbundle')));
    },
    skip: !script.existsSync(),
  );

  test(
    'android release builds fail closed without map dart-defines and do not print values',
    () {
      expect(
        gradleScript.existsSync(),
        isTrue,
        reason: 'android/app/build.gradle.kts should exist in this repo.',
      );

      final source = gradleScript.readAsStringSync().replaceAll('\r\n', '\n');

      expect(
          source,
          contains(
              'val requestedTasks = gradle.startParameter.taskNames.map { it.lowercase() }'));
      expect(source,
          contains('val releaseArtifactRequested = requestedTasks.any'));
      expect(source, contains('taskName.contains("release")'));
      expect(source, contains('taskName.contains("assemble")'));
      expect(source, contains('taskName.contains("bundle")'));
      expect(source, contains('taskName.contains("package")'));
      expect(source, contains('val isPublishLikeTask = taskName.contains("publish")'));
      expect(source, contains('isRelease && isArtifactTask && !isPublishLikeTask'));
      expect(source,
          contains('val publishLikeTaskRequested = requestedTasks.any'));
      expect(source, contains('taskName.contains("publish")'));
      expect(source, contains('taskName.contains("upload")'));
      expect(source, contains('taskName.contains("promote")'));
      expect(source, contains('if (releaseArtifactRequested) {'));
      expect(source, contains('if (releasePublishRequested) {'));
      expect(source, contains('planflowMapArtifactMarker'));
      expect(source, contains('MessageDigest.getInstance("SHA-256")'));
      expect(source, contains('marker does not match the AAB'));
      expect(source, contains('GOOGLE_MAPS_API_KEY'));
      expect(source, contains('TMAP_API_KEY'));
      expect(source, contains('NAVER_MAP_CLIENT_ID'));
      expect(
          source,
          contains(
              'Release build blocked: missing or placeholder dart-defines'));
      expect(
          source,
          contains(
              'Run the build through scripts/flutter-local.ps1 so env/local.json is injected.'));
      expect(source, contains('manifestPlaceholders["googleMapsApiKey"] ='));
      expect(source, contains('readDartDefineValue("GOOGLE_MAPS_API_KEY")'));
      expect(source, isNot(contains('println(')));
      expect(source, isNot(contains('logger.lifecycle')));
    },
    skip: !gradleScript.existsSync(),
  );

  test(
    'Play deploy verifies and passes the non-secret map artifact marker',
    () {
      final deployScript = File('scripts/deploy-play-internal.ps1');
      expect(deployScript.existsSync(), isTrue);
      final source = deployScript.readAsStringSync().replaceAll('\r\n', '\n');

      expect(source, contains('Assert-MapArtifactMarker'));
      expect(
          source,
          contains(
              r'Get-FileHash -LiteralPath $resolvedExpected -Algorithm SHA256'));
      expect(
          source,
          contains(
              r'-PplanflowMapArtifactMarker=$resolvedMapArtifactMarkerPath'));
      expect(source, isNot(contains('GOOGLE_MAPS_API_KEY=')));
      expect(source, isNot(contains('TMAP_API_KEY=')));
      expect(source, isNot(contains('NAVER_MAP_CLIENT_ID=')));
    },
    skip: !File('scripts/deploy-play-internal.ps1').existsSync(),
  );
}
