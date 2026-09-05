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
    expect(plist, contains('NSLocationWhenInUseUsageDescription'));
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

  test('iOS privacy audit and reusable privacy gate are source controlled', () {
    final audit = file('docs/ios/privacy-surface-audit.md').readAsStringSync();
    final helper =
        file('scripts/verify-ios-privacy-surface.py').readAsStringSync();
    expect(audit, contains('NSLocationWhenInUseUsageDescription'));
    expect(audit, contains('실제 macOS binary'));
    expect(audit, contains('archive/export release gates require'));
    for (final candidate in <String>[
      'NSCameraUsageDescription',
      'NSPhotoLibraryUsageDescription',
      'NSPhotoLibraryAddUsageDescription',
      'NSContactsUsageDescription',
      'NSCalendarsUsageDescription',
      'NSRemindersUsageDescription',
      'NSLocationAlwaysAndWhenInUseUsageDescription',
      'NSBluetoothAlwaysUsageDescription',
      'NSLocalNetworkUsageDescription',
      'NSMotionUsageDescription',
      'NSFaceIDUsageDescription',
      'NSAppleMusicUsageDescription',
    ]) {
      expect(audit, contains(candidate));
    }
    expect(helper, contains('BLOCKED_RUNNER_PRIVACY'));
    expect(helper, contains('BLOCKED_WIDGET_PRIVACY'));
    expect(helper, contains('NSLocationWhenInUseUsageDescription'));
    expect(helper, contains('--require-binary-scan'));
    expect(helper, contains('--report-json'));
    expect(helper, contains('CNContactStore'));
    expect(helper, contains('EKEventStore'));
    expect(helper, contains('PHPhotoLibrary'));
    expect(helper, contains('AVCaptureDevice'));
    expect(helper, contains('CBCentralManager'));
    expect(helper, contains('NWPathMonitor'));
    expect(helper, contains('CMMotionManager'));
    expect(helper, contains('LAContext'));
    expect(helper, contains('MPMediaLibrary'));
  });

  test('privacy helper rejects missing Runner keys and Widget leakage', () {
    final temp = Directory.systemTemp.createTempSync('planflow-privacy-test-');
    try {
      final runner = File('${temp.path}${Platform.pathSeparator}runner.plist');
      final widget = File('${temp.path}${Platform.pathSeparator}widget.plist');
      String plist(Map<String, String> values) =>
          '''<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>${values.entries.map((entry) => '<key>${entry.key}</key><string>${entry.value}</string>').join()}</dict></plist>''';
      final keys = <String, String>{
        'NSMicrophoneUsageDescription': 'mic',
        'NSSpeechRecognitionUsageDescription': 'speech',
        'NSUserTrackingUsageDescription': 'tracking',
        'NSLocationWhenInUseUsageDescription': 'location',
      };
      runner.writeAsStringSync(
          plist({...keys}..remove('NSLocationWhenInUseUsageDescription')));
      widget.writeAsStringSync(plist(const <String, String>{}));
      final helper =
          '${root.path}${Platform.pathSeparator}scripts${Platform.pathSeparator}verify-ios-privacy-surface.py';
      ProcessResult run() => Process.runSync(
            Platform.isWindows ? 'python' : 'python3',
            [
              helper,
              '--runner-plist',
              runner.path,
              '--widget-plist',
              widget.path
            ],
          );
      expect(run().exitCode, isNot(0));
      runner.writeAsStringSync(plist(keys));
      widget.writeAsStringSync(plist(<String, String>{
        'NSLocationWhenInUseUsageDescription': 'wrong target',
      }));
      final report = File('${temp.path}${Platform.pathSeparator}report.json');
      final leakage = Process.runSync(
        Platform.isWindows ? 'python' : 'python3',
        [
          helper,
          '--runner-plist',
          runner.path,
          '--widget-plist',
          widget.path,
          '--report-json',
          report.path,
        ],
      );
      expect(leakage.exitCode, isNot(0));
      expect(report.readAsStringSync(), contains('widgetForbiddenKeys'));
    } finally {
      temp.deleteSync(recursive: true);
    }
  });

  test('privacy helper fails closed when required binary scan is unavailable',
      () {
    final temp =
        Directory.systemTemp.createTempSync('planflow-privacy-binary-');
    try {
      final runner = File('${temp.path}${Platform.pathSeparator}runner.plist');
      final widget = File('${temp.path}${Platform.pathSeparator}widget.plist');
      String plist(Map<String, String> values) =>
          '''<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>${values.entries.map((entry) => '<key>${entry.key}</key><string>${entry.value}</string>').join()}</dict></plist>''';
      final keys = <String, String>{
        'NSMicrophoneUsageDescription': 'mic',
        'NSSpeechRecognitionUsageDescription': 'speech',
        'NSUserTrackingUsageDescription': 'tracking',
        'NSLocationWhenInUseUsageDescription': 'location',
      };
      runner.writeAsStringSync(plist(keys));
      widget.writeAsStringSync(plist(const <String, String>{}));
      final helper =
          '${root.path}${Platform.pathSeparator}scripts${Platform.pathSeparator}verify-ios-privacy-surface.py';
      final result = Process.runSync(
        Platform.isWindows ? 'python' : 'python3',
        [
          helper,
          '--runner-plist',
          runner.path,
          '--widget-plist',
          widget.path,
          '--runner-bundle',
          temp.path,
          '--require-binary-scan'
        ],
      );
      expect(result.exitCode, isNot(0));
    } finally {
      temp.deleteSync(recursive: true);
    }
  });

  test('privacy helper requires a bundle for required scans and writes pass reports', () {
    final temp = Directory.systemTemp.createTempSync('planflow-privacy-report-');
    try {
      final runner = File('${temp.path}${Platform.pathSeparator}runner.plist');
      final widget = File('${temp.path}${Platform.pathSeparator}widget.plist');
      String plist(Map<String, String> values) =>
          '''<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>${values.entries.map((entry) => '<key>${entry.key}</key><string>${entry.value}</string>').join()}</dict></plist>''';
      final keys = <String, String>{
        'NSMicrophoneUsageDescription': 'mic',
        'NSSpeechRecognitionUsageDescription': 'speech',
        'NSUserTrackingUsageDescription': 'tracking',
        'NSLocationWhenInUseUsageDescription': 'location',
      };
      runner.writeAsStringSync(plist(keys));
      widget.writeAsStringSync(plist(const <String, String>{}));
      final helper =
          '${root.path}${Platform.pathSeparator}scripts${Platform.pathSeparator}verify-ios-privacy-surface.py';
      final missingBundle = Process.runSync(
        Platform.isWindows ? 'python' : 'python3',
        [
          helper,
          '--runner-plist',
          runner.path,
          '--widget-plist',
          widget.path,
          '--require-binary-scan'
        ],
      );
      expect(missingBundle.exitCode, isNot(0));
      final report = File('${temp.path}${Platform.pathSeparator}pass.json');
      final pass = Process.runSync(
        Platform.isWindows ? 'python' : 'python3',
        [
          helper,
          '--runner-plist',
          runner.path,
          '--widget-plist',
          widget.path,
          '--report-json',
          report.path,
        ],
      );
      expect(pass.exitCode, 0);
      expect(report.readAsStringSync(), contains('"status": "PASS"'));
      expect(report.readAsStringSync(), contains('runnerKeys'));
    } finally {
      temp.deleteSync(recursive: true);
    }
  });

  test('privacy helper report stores only filtered evidence from binary tools',
      () {
    final temp =
        Directory.systemTemp.createTempSync('planflow-privacy-filtered-');
    try {
      final bundle = Directory(
          '${temp.path}${Platform.pathSeparator}Runner.app');
      bundle.createSync(recursive: true);
      final runnerPlist = File(
          '${bundle.path}${Platform.pathSeparator}Info.plist');
      runnerPlist.writeAsStringSync(
        '''<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>CFBundleExecutable</key><string>Runner</string><key>NSMicrophoneUsageDescription</key><string>mic</string><key>NSSpeechRecognitionUsageDescription</key><string>speech</string><key>NSUserTrackingUsageDescription</key><string>tracking</string><key>NSLocationWhenInUseUsageDescription</key><string>location</string></dict></plist>''',
      );
      final widgetPlist = File(
          '${temp.path}${Platform.pathSeparator}widget.plist');
      widgetPlist.writeAsStringSync(
        '''<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict></dict></plist>''',
      );
      final runnerBinary = File('${bundle.path}${Platform.pathSeparator}Runner');
      runnerBinary.writeAsStringSync('fake runner binary');
      final toolDir =
          Directory('${temp.path}${Platform.pathSeparator}tools')
            ..createSync(recursive: true);
      final otool = File('${toolDir.path}${Platform.pathSeparator}otool.cmd');
      final nm = File('${toolDir.path}${Platform.pathSeparator}nm.cmd');
      final strings = File(
          '${toolDir.path}${Platform.pathSeparator}strings.cmd');
      otool.writeAsStringSync('''@echo off
echo SENTINEL_RAW_OTOOL
echo /System/Library/Frameworks/CoreLocation.framework/CoreLocation
''');
      nm.writeAsStringSync('''@echo off
echo SENTINEL_RAW_NM
echo _CLLocationManager
''');
      strings.writeAsStringSync('''@echo off
echo SENTINEL_RAW_STRINGS
echo AVFoundation.framework
''');
      final report = File('${temp.path}${Platform.pathSeparator}report.json');
      final helper =
          '${root.path}${Platform.pathSeparator}scripts${Platform.pathSeparator}verify-ios-privacy-surface.py';
      final env = Map<String, String>.from(Platform.environment);
      final existingPath = env['PATH'] ?? env['Path'] ?? '';
      final toolPath =
          '${toolDir.path}${Platform.pathSeparator}$existingPath';
      env['PATH'] = toolPath;
      env['Path'] = toolPath;
      final result = Process.runSync(
        Platform.isWindows ? 'python' : 'python3',
        [
          helper,
          '--runner-plist',
          runnerPlist.path,
          '--widget-plist',
          widgetPlist.path,
          '--runner-bundle',
          bundle.path,
          '--tool-dir',
          toolDir.path,
          '--report-json',
          report.path,
        ],
        environment: env,
      );
      expect(result.exitCode, 0);
      final reportText = report.readAsStringSync();
      expect(reportText, contains('"status": "PASS"'));
      expect(reportText, contains('"filteredEvidence"'));
      expect(reportText, isNot(contains('SENTINEL_RAW_OTOOL')));
      expect(reportText, isNot(contains('SENTINEL_RAW_NM')));
      expect(reportText, isNot(contains('SENTINEL_RAW_STRINGS')));
      expect(reportText, contains('CoreLocation.framework'));
      expect(reportText, contains('AVFoundation.framework'));
    } finally {
      temp.deleteSync(recursive: true);
    }
  });

  test('signed release workflow has explicit Apple signing and cleanup gates',
      () {
    final workflow =
        file('.github/workflows/ios-release.yml').readAsStringSync();
    expect(workflow, contains('runs-on: macos-latest'));
    expect(workflow, contains('BLOCKED_APPLE_SIGNING'));
    expect(workflow, contains('RUNNER_PRIVACY_SOURCE_PASS: PASS'));
    expect(workflow, contains('BLOCKED_RUNNER_PRIVACY_SOURCE'));
    expect(workflow, contains('NSLocationWhenInUseUsageDescription'));
    expect(workflow, contains('verify-ios-privacy-surface.py'));
    expect(workflow, contains('actions/upload-artifact@v4'));
    expect(workflow, contains('planflow-ios-privacy-audit-'));
    final requiredPrivacyKeys = <String>{
      'NSMicrophoneUsageDescription',
      'NSSpeechRecognitionUsageDescription',
      'NSUserTrackingUsageDescription',
      'NSLocationWhenInUseUsageDescription',
    };
    final privacyLoops = RegExp(r'for privacy_key in ([^;]+); do')
        .allMatches(workflow)
        .map((match) => match.group(1)!.split(RegExp(r'\s+')).toSet())
        .toList(growable: false);
    expect(privacyLoops, isNotEmpty);
    for (final loop in privacyLoops) {
      expect(loop, requiredPrivacyKeys);
    }
    final helper =
        file('scripts/verify-ios-privacy-surface.py').readAsStringSync();
    final helperRequired =
        RegExp(r'REQUIRED = \{([\s\S]*?)\}').firstMatch(helper)!.group(1)!;
    final helperPrivacyKeys = RegExp(r'"([^"]+)"')
        .allMatches(helperRequired)
        .map((match) => match.group(1)!)
        .toSet();
    expect(helperPrivacyKeys, requiredPrivacyKeys);
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

  test('macOS audit-only workflow never uploads and never dispatches Build 16',
      () {
    final workflow =
        file('.github/workflows/ios-privacy-audit.yml').readAsStringSync();
    expect(workflow, contains('runs-on: macos-latest'));
    expect(workflow, contains('workflow_dispatch'));
    expect(workflow, contains('audit_build_number'));
    expect(workflow, contains('audit_artifact_run_id'));
    expect(workflow, contains('audit_artifact_name'));
    expect(workflow, contains('audit_artifact_sha256'));
    expect(workflow, contains('audit_source_commit'));
    expect(workflow, contains('AUDIT_ONLY_NO_UPLOAD: PASS'));
    expect(workflow, contains('BUILD_16_DISPATCHED: NO'));
    expect(workflow, contains('REBUILD_PERFORMED: NO'));
    expect(workflow, contains('this 90683 workflow audits Build 15 only'));
    expect(workflow, contains('APP_STORE_UPLOAD_PERFORMED: NO'));
    expect(workflow, contains('verify-ios-privacy-surface.py'));
    expect(workflow, contains('--audit-report'));
    expect(workflow, contains('--require-binary-scan'));
    expect(workflow, contains('audit-export-privacy-report.json'));
    expect(workflow, contains('actions/upload-artifact@v4'));
    expect(workflow, contains('planflow-ios-90683-audit-'));
    expect(workflow, contains('BLOCKED_AUDIT_PROVENANCE'));
    expect(workflow, contains('CFBundleIdentifier'));
    expect(workflow, contains('PlanFlowWidgetExtension.appex/Info.plist'));
    expect(workflow, contains('widget_bundle_id'));
    expect(workflow, contains('com.fluxstudio.planflow.PlanFlowWidget'));
    expect(workflow, contains('EXACT_BUILD15_ARTIFACT_PROVENANCE: PASS'));
    expect(workflow,
        contains('BLOCKED_AUDIT_METADATA: widget bundle identifier mismatch'));
    expect(workflow,
        contains('BLOCKED_AUDIT_METADATA: widget CFBundleVersion mismatch'));
    expect(workflow, contains('EXACT_BUILD15_ARTIFACT_PROVENANCE: PASS'));
    expect(workflow, contains('actions/download-artifact@v4'));
    expect(workflow, contains('Secret cleanup gate executed.'));
    // Audit-only: no Apple transport and no App Store Connect API surface.
    expect(workflow, isNot(contains('altool')));
    expect(workflow, isNot(contains('--upload-app')));
    expect(workflow, isNot(contains('verify-app-store-build.py')));
    expect(workflow, isNot(contains('APP_STORE_CONNECT_')));
    expect(workflow, isNot(contains('flutter build ios')));
    expect(workflow, isNot(contains('xcodebuild archive')));
    // The release workflow keeps the upload path; the audit workflow must not.
    final release =
        file('.github/workflows/ios-release.yml').readAsStringSync();
    expect(release, contains('xcrun altool --upload-app'));
  });

  // On Windows a bare `bash` resolves to WSL, which has no distro on this
  // host; the Git for Windows shell is the POSIX interpreter that matches the
  // GitHub runner semantics closely enough for this gate.
  String? resolveBash() {
    if (!Platform.isWindows) return 'bash';
    for (final candidate in <String>[
      r'C:\Program Files\Git\bin\bash.exe',
      r'C:\Program Files\Git\usr\bin\bash.exe',
    ]) {
      if (File(candidate).existsSync()) return candidate;
    }
    return null;
  }

  test('audit-only build-number gate accepts only Build 15', () {
    final bash = resolveBash()!;
    final workflow =
        file('.github/workflows/ios-privacy-audit.yml').readAsStringSync();
    // Extract the real gate script from the workflow and execute it, so a
    // broken gate cannot pass on string matching alone.
    final start =
        workflow.indexOf('      - name: Validate immutable Build 15 audit inputs');
    expect(start, isNot(-1));
    final runMarker = workflow.indexOf('run: |', start);
    expect(runMarker, isNot(-1));
    final body = workflow.substring(workflow.indexOf('\n', runMarker) + 1);
    final lines = <String>[];
    for (final line in body.split('\n')) {
      if (line.trim().isNotEmpty && !line.startsWith('          ')) break;
      lines.add(line.length >= 10 ? line.substring(10) : line);
    }
    final script = File(
        '${Directory.systemTemp.createTempSync('planflow-audit-gate-').path}${Platform.pathSeparator}gate.sh');
    script.writeAsStringSync(lines.join('\n'));
    expect(script.readAsStringSync(), contains('this 90683 workflow audits Build 15 only'));
    int runGate(String value) => Process.runSync(
          bash,
          [script.path.replaceAll(r'\', '/')],
          environment: <String, String>{
            'IOS_AUDIT_BUILD_NUMBER': value,
            'IOS_AUDIT_ARTIFACT_RUN_ID': '123',
            'IOS_AUDIT_ARTIFACT_NAME': 'build15',
            'IOS_AUDIT_ARTIFACT_SHA256':
                '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
            'IOS_AUDIT_SOURCE_COMMIT':
                '0123456789abcdef0123456789abcdef01234567',
          },
        ).exitCode;
    expect(runGate('15'), 0);
    for (final blocked in <String>['0', '16', '0016', '017', '99', 'abc', '', '1a']) {
      expect(runGate(blocked), isNot(0), reason: 'must block "$blocked"');
    }
    script.parent.deleteSync(recursive: true);
  }, skip: resolveBash() == null ? 'POSIX bash is unavailable on this host' : null);

  test('privacy helper audit report records 90683 purpose-string gaps', () {
    final temp = Directory.systemTemp.createTempSync('planflow-privacy-audit-');
    try {
      final bundle =
          Directory('${temp.path}${Platform.pathSeparator}Runner.app');
      bundle.createSync(recursive: true);
      final runnerPlist =
          File('${bundle.path}${Platform.pathSeparator}Info.plist');
      runnerPlist.writeAsStringSync(
        '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>'
        '<key>CFBundleExecutable</key><string>Runner</string>'
        '<key>NSMicrophoneUsageDescription</key><string>mic</string>'
        '<key>NSSpeechRecognitionUsageDescription</key><string>speech</string>'
        '<key>NSUserTrackingUsageDescription</key><string>tracking</string>'
        '<key>NSLocationWhenInUseUsageDescription</key><string>location</string>'
        '</dict></plist>',
      );
      final widgetPlist =
          File('${temp.path}${Platform.pathSeparator}widget.plist');
      widgetPlist.writeAsStringSync(
        '<?xml version="1.0" encoding="UTF-8"?>'
        '<plist version="1.0"><dict></dict></plist>',
      );
      File('${bundle.path}${Platform.pathSeparator}Runner')
          .writeAsStringSync('fake runner binary');
      final toolDir = Directory('${temp.path}${Platform.pathSeparator}tools')
        ..createSync(recursive: true);
      File('${toolDir.path}${Platform.pathSeparator}otool.cmd')
          .writeAsStringSync('@echo off\n'
              'echo /System/Library/Frameworks/CoreLocation.framework/CoreLocation\n');
      File('${toolDir.path}${Platform.pathSeparator}nm.cmd')
          .writeAsStringSync('@echo off\necho _AVCaptureDevice\n');
      File('${toolDir.path}${Platform.pathSeparator}strings.cmd')
          .writeAsStringSync('@echo off\necho AVCaptureDevice\n');
      final report = File('${temp.path}${Platform.pathSeparator}audit.json');
      final helper =
          '${root.path}${Platform.pathSeparator}scripts${Platform.pathSeparator}verify-ios-privacy-surface.py';
      final result = Process.runSync(
        Platform.isWindows ? 'python' : 'python3',
        [
          helper,
          '--runner-plist',
          runnerPlist.path,
          '--widget-plist',
          widgetPlist.path,
          '--runner-bundle',
          bundle.path,
          '--tool-dir',
          toolDir.path,
          '--audit-report',
          '--report-json',
          report.path,
        ],
      );
      expect(result.exitCode, 0);
      final reportText = report.readAsStringSync();
      expect(reportText, contains('"appleErrorCode": "90683"'));
      expect(reportText, contains('"uploadPerformed": false'));
      expect(reportText, contains('runnerUsageDescriptionKeys'));
      expect(reportText, contains('AVCaptureDevice'));
      expect(reportText, contains('NSCameraUsageDescription'));
      // CoreLocation is linked and its key is present, so it is not a gap.
      expect(reportText, contains('"frameworkKeyGaps": []'));
      expect(result.stdout.toString(), contains('IOS_PRIVACY_KEY_GAP:'));
    } finally {
      temp.deleteSync(recursive: true);
    }
  });
}
