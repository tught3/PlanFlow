import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final root = Directory.current;
  File file(String path) => File('${root.path}${Platform.pathSeparator}$path');

  test('iOS entry files are source controlled', () {
    expect(file('ios/Runner/AppDelegate.swift').existsSync(), isTrue);
    expect(file('ios/Runner/Info.plist').existsSync(), isTrue);
    expect(file('ios/Runner/GeneratedPluginRegistrant.m').existsSync(), isTrue);
  });

  test('deep link and voice permission contract remain present', () {
    final plist = file('ios/Runner/Info.plist').readAsStringSync();
    expect(plist, contains('<string>planflow</string>'));
    expect(plist, contains('NSMicrophoneUsageDescription'));
    expect(plist, contains('NSSpeechRecognitionUsageDescription'));
    final phoneOrientations =
        plist.split('<key>UISupportedInterfaceOrientations~ipad</key>').first;
    expect(phoneOrientations, contains('UIInterfaceOrientationPortrait'));
    expect(
        phoneOrientations, isNot(contains('UIInterfaceOrientationLandscape')));
    expect(plist, contains('UIInterfaceOrientationLandscapeLeft'));
  });

  test('readiness docs keep macOS/device gates explicit', () {
    final docs = file('docs/ios/release-readiness.md').readAsStringSync();
    expect(docs, contains('macOS 및 Apple 계정이 필요한 게이트'));
    expect(docs, contains('LIVE VALIDATED'));
    expect(docs, contains('Runner.xcodeproj'));
    expect(docs, contains('자동으로 합치거나 Firebase plist를 추정하지 않는다'));
  });

  test('macOS workflow fails closed when the native target is missing', () {
    final workflow =
        file('.github/workflows/ios-readiness.yml').readAsStringSync();
    expect(workflow, contains('runs-on: macos-latest'));
    expect(workflow, contains('Verify native iOS target contract'));
    expect(workflow, contains('ios/Runner.xcodeproj/project.pbxproj'));
  });
}
