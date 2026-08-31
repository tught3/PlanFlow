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
    expect(plist, contains('NSUserTrackingUsageDescription'));
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
    expect(docs, contains('Firebase plist는 저장소에 포함하지 않고'));
  });

  test('macOS workflow fails closed when the native target is missing', () {
    final workflow =
        file('.github/workflows/ios-readiness.yml').readAsStringSync();
    expect(workflow, contains('runs-on: macos-latest'));
    expect(workflow, contains('Verify native iOS target contract'));
    expect(workflow, contains('ios/Runner.xcodeproj/project.pbxproj'));
  });

  test('signed release workflow has explicit Apple signing and cleanup gates',
      () {
    final workflow =
        file('.github/workflows/ios-release.yml').readAsStringSync();
    expect(workflow, contains('runs-on: macos-latest'));
    expect(workflow, contains('BLOCKED_APPLE_SIGNING'));
    expect(workflow, contains('RUNNER_PRIVACY_SOURCE_PASS: PASS'));
    expect(workflow, contains('BLOCKED_RUNNER_PRIVACY_SOURCE'));
    expect(workflow, contains('PLANFLOW_IOS_DISTRIBUTION_CERTIFICATE_BASE64'));
    expect(
        workflow, contains('PLANFLOW_IOS_RUNNER_PROVISIONING_PROFILE_BASE64'));
    expect(
        workflow, contains('PLANFLOW_IOS_WIDGET_PROVISIONING_PROFILE_BASE64'));
    expect(workflow, contains('PlanFlowWidgetExtension.appex'));
    expect(workflow, contains('pod install --project-directory=ios'));
    expect(workflow, contains('xcodebuild -exportArchive'));
    expect(workflow, contains('xcrun altool --upload-app'));
    expect(workflow, contains('APP_STORE_CONNECT_KEY_ID'));
    expect(workflow, contains('APP_STORE_CONNECT_ISSUER_ID'));
    expect(workflow, contains('APP_STORE_CONNECT_API_KEY_P8'));
    expect(workflow, contains(r'FLUTTER_BUILD_NAME="$IOS_BUILD_NAME"'));
    expect(workflow, contains(r'FLUTTER_BUILD_NUMBER="$IOS_BUILD_NUMBER"'));
    expect(workflow, contains(r'MARKETING_VERSION="$IOS_BUILD_NAME"'));
    expect(workflow, contains(r'CURRENT_PROJECT_VERSION="$IOS_BUILD_NUMBER"'));
    expect(workflow, contains('Exported IPA filename:'));
    expect(workflow, contains('Exported IPA path:'));
    expect(workflow, contains('IPA metadata: bundleId='));
    expect(workflow, contains('IPA Widget metadata: bundleId='));
    expect(workflow, contains('IPA gate: signed IPA exported.'));
    expect(workflow, contains('BLOCKED_IPA_METADATA'));
    expect(workflow, contains('BLOCKED_IPA_METADATA_MISMATCH'));
    expect(workflow, contains('ARCHIVE_PRIVACY_PREFLIGHT_PASS: PASS'));
    expect(workflow, contains('BLOCKED_ARCHIVE_PRIVACY'));
    expect(workflow, contains('BLOCKED_WIDGET_PRIVACY'));
    expect(workflow, contains('EXPORTED_IPA_PRIVACY_PREFLIGHT_PASS: PASS'));
    expect(workflow, contains('BLOCKED_IPA_PRIVACY'));
    expect(
        workflow,
        contains(
            'TestFlight transport gate: upload accepted by App Store Connect.'));
    expect(workflow, contains('TESTFLIGHT_TRANSPORT_UPLOAD_PASS: PASS'));
    expect(workflow, contains('python3 scripts/verify-app-store-build.py'));
    expect(workflow, contains('--timeout-seconds 900'));
    expect(workflow, contains('--poll-interval-seconds 30'));
    expect(workflow,
        contains('App Store build ingestion gate: build resource found for'));
    expect(workflow, contains('never share a profile'));
    expect(workflow, contains(r'if: ${{ always() }}'));
    expect(workflow, contains('rm -f ios/Runner/GoogleService-Info.plist'));
    expect(workflow, contains('Secret cleanup gate executed.'));
  });

  test(
      'App Store Connect ingestion verifier keeps transport and processing separate',
      () {
    final verifier =
        file('scripts/verify-app-store-build.py').readAsStringSync();
    expect(verifier, contains('App Store Connect target verified:'));
    expect(verifier, contains('Build lookup request ID'));
    expect(verifier, contains('/buildUploads'));
    expect(verifier, contains('BUILD_UPLOAD_ACCEPTED_OR_PROCESSING'));
    expect(verifier, contains('PENDING_APPLE_PROCESSING'));
    expect(verifier, contains('BLOCKED_APP_STORE_UPLOAD_FAILED'));
    expect(verifier, contains('BLOCKED_BUILD_ASSOCIATION_PENDING'));
    expect(verifier, contains('print_state_details'));
    expect(verifier, contains('processingState'));
    expect(verifier, contains('BUILD_STATES = {"PROCESSING", "VALID"}'));
    expect(verifier, contains('App Store Connect build resource found:'));
    expect(verifier, contains('APP_STORE_BUILD_INGESTED: PASS'));
    expect(verifier, contains('TESTFLIGHT_BUILD_VISIBLE_OR_PROCESSING: PASS'));
    expect(verifier, contains('TESTFLIGHT_BUILD_AVAILABLE: PASS'));
    expect(verifier, contains('TESTFLIGHT_BUILD_AVAILABLE: NOT_YET_AVAILABLE'));
    expect(verifier, contains('BLOCKED_ASC_APP_LOOKUP'));
    expect(verifier, contains('BLOCKED_ASC_APP_TARGET'));
    expect(verifier, contains('BLOCKED_ASC_BUILD_LOOKUP'));
    expect(verifier, contains('BLOCKED_APP_STORE_VERSION'));
    expect(verifier, contains('BLOCKED_APP_STORE_BUILD_NUMBER'));
    expect(verifier, contains('BLOCKED_APP_STORE_PROCESSING'));
    expect(verifier, contains('BLOCKED_APP_STORE_INGESTION_TIMEOUT'));
    expect(verifier,
        contains('App Store Connect build not visible yet; uploadState='));
    expect(verifier, contains('--timeout-seconds'));
    expect(verifier, contains('--poll-interval-seconds'));
  });

  test('existing TestFlight ingestion inspection never uploads a new build',
      () {
    final workflow = file('.github/workflows/ios-testflight-ingestion.yml')
        .readAsStringSync();
    expect(workflow,
        contains('Existing App Store Connect build number to inspect'));
    expect(workflow, contains('default: "13"'));
    expect(workflow, contains('delivery_uuid:'));
    expect(workflow, contains('--delivery-uuid'));
    expect(workflow, contains('verify-app-store-build.py'));
    expect(workflow, contains('--pending-exit-zero'));
    expect(workflow, isNot(contains('xcrun altool')));
    expect(workflow, isNot(contains('xcodebuild archive')));
    expect(workflow, isNot(contains('build 14')));
  });
}
