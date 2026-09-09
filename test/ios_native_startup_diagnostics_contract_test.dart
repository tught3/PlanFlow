import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/core/native_startup_diagnostics.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final root = Directory.current;
  String read(String path) =>
      File('${root.path}${Platform.pathSeparator}$path').readAsStringSync();

  test('native and Dart startup markers are exact and ordered by surface', () {
    final native = read('ios/Runner/StartupDiagnostics.swift');
    final appDelegate = read('ios/Runner/AppDelegate.swift');
    final dart = read('lib/core/native_startup_diagnostics.dart');
    final main = read('lib/main.dart');
    const markers = <String>[
      'NATIVE_PROCESS_START',
      'APPDELEGATE_ENTER',
      'PLUGIN_REGISTRATION_BEGIN',
      'PLUGIN_REGISTRATION_END',
      'FLUTTER_ENGINE_READY',
      'DART_MAIN_ENTER',
      'RUNAPP_REACHED',
      'FIRST_FRAME',
    ];
    for (final marker in markers) {
      expect(native, contains(marker));
    }
    expect(main, contains('NativeStartupDiagnostics.dartMainEnter();'));
    expect(main, contains('NativeStartupDiagnostics.runAppReached();'));
    expect(main, contains('NativeStartupDiagnostics.firstFrame();'));
    expect(dart,
        contains('kIsWeb || defaultTargetPlatform != TargetPlatform.iOS'));
    expect(main.indexOf('WidgetsFlutterBinding.ensureInitialized();'),
        lessThan(main.indexOf('NativeStartupDiagnostics.dartMainEnter();')));
    expect(main.indexOf('NativeStartupDiagnostics.dartMainEnter();'),
        lessThan(main.indexOf('runApp(ProviderScope')));
    expect(appDelegate, contains('willFinishLaunchingWithOptions'));
    expect(appDelegate.indexOf('NATIVE_PROCESS_START'),
        lessThan(appDelegate.indexOf('didFinishLaunchingWithOptions')));
    final willFinish = appDelegate.substring(
      appDelegate.indexOf('willFinishLaunchingWithOptions'),
      appDelegate.indexOf('didFinishLaunchingWithOptions'),
    );
    expect(willFinish.indexOf('installExceptionHandler()'),
        lessThan(willFinish.indexOf('return super.application')));
    expect(appDelegate,
        contains('FlutterAppDelegate, FlutterImplicitEngineDelegate'));
    expect(
        appDelegate,
        contains(
            'didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge)'));
    final didFinish = appDelegate.substring(
      appDelegate.indexOf('didFinishLaunchingWithOptions'),
      appDelegate.indexOf('didInitializeImplicitFlutterEngine'),
    );
    expect(didFinish, isNot(contains('GeneratedPluginRegistrant.register')));
    final implicitCallback = appDelegate
        .substring(appDelegate.indexOf('didInitializeImplicitFlutterEngine'));
    expect(
      implicitCallback
          .indexOf('attach(to: engineBridge.applicationRegistrar.messenger())'),
      lessThan(implicitCallback.indexOf('PLUGIN_REGISTRATION_BEGIN')),
    );
    expect(implicitCallback.indexOf('PLUGIN_REGISTRATION_BEGIN'),
        lessThan(implicitCallback.indexOf('StartupDiagnosticsPluginRegistry')));
    expect(
        implicitCallback.indexOf('StartupDiagnosticsPluginRegistry'),
        lessThan(
            implicitCallback.indexOf('GeneratedPluginRegistrant.register')));
    expect(appDelegate.indexOf('PLUGIN_REGISTRATION_BEGIN'),
        lessThan(appDelegate.indexOf('GeneratedPluginRegistrant.register')));
    expect(appDelegate.indexOf('GeneratedPluginRegistrant.register'),
        lessThan(appDelegate.indexOf('PLUGIN_REGISTRATION_END')));
    expect(appDelegate.indexOf('PLUGIN_REGISTRATION_END'),
        lessThan(appDelegate.indexOf('FLUTTER_ENGINE_READY')));
    expect(native, contains('not causal crash evidence'));
  });

  test('Flutter 3.47.2 UIScene manifest is explicit and canonical', () {
    final plist = read('ios/Runner/Info.plist');
    for (final entry in <String>[
      '<key>UIApplicationSceneManifest</key>',
      '<key>UIApplicationSupportsMultipleScenes</key>',
      '<false/>',
      '<key>UISceneConfigurations</key>',
      '<key>UIWindowSceneSessionRoleApplication</key>',
      '<key>UISceneClassName</key>',
      '<string>UIWindowScene</string>',
      '<key>UISceneDelegateClassName</key>',
      '<string>FlutterSceneDelegate</string>',
      '<key>UISceneConfigurationName</key>',
      '<string>flutter</string>',
      '<key>UISceneStoryboardFile</key>',
      '<string>Main</string>',
    ]) {
      expect(plist, contains(entry), reason: entry);
    }
    expect(RegExp('UIApplicationSceneManifest').allMatches(plist).length, 1);
  });

  test('readiness docs keep native crash ahead of the separate R1 gate', () {
    for (final path in <String>[
      'docs/ios/release-readiness.md',
      'docs/ios/APP_STORE_READINESS.md',
    ]) {
      final doc = read(path);
      expect(doc, contains('NATIVE_STARTUP_CRASH_NOT_IDENTIFIED'),
          reason: path);
      expect(doc, contains('Build 18'), reason: path);
      expect(doc, isNot(contains('단일 차단 사유는 R1 하나')), reason: path);
      expect(doc, isNot(contains('유일한 차단 사유')), reason: path);
      expect(doc, isNot(contains('차단 사유 **1건**')), reason: path);
      expect(doc, isNot(contains('수동 워크플로 1회 실행')), reason: path);
      expect(doc, isNot(contains('R1_CLEARED`가 나오면 그 자리에서')), reason: path);
    }
  });

  test('registrar diagnostics match generated plugin keys and remain bounded',
      () {
    final native = read('ios/Runner/StartupDiagnostics.swift');
    final generated = read('ios/Runner/GeneratedPluginRegistrant.m');
    final generatedKeys = RegExp(r'registrarForPlugin:@"([^"]+)"')
        .allMatches(generated)
        .map((match) => match.group(1)!)
        .toSet();
    final allowlist = RegExp(r'"([A-Za-z][A-Za-z0-9]+Plugin)"')
        .allMatches(native)
        .map((match) => match.group(1)!)
        .toSet();
    expect(allowlist, generatedKeys);
    expect(native, contains('ledger.count < 64'));
    expect(native, contains('arguments.count == 1'));
    expect(
        native,
        contains(
            'final class StartupDiagnosticsPluginRegistry: NSObject, FlutterPluginRegistry'));
    expect(native,
        contains('return wrappedRegistry.registrar(forPlugin: pluginKey)'));
    expect(native, contains('return wrappedRegistry.hasPlugin(pluginKey)'));
    expect(native,
        contains('return wrappedRegistry.valuePublished(byPlugin: pluginKey)'));
    final proxyRegistrar = native.substring(
      native.indexOf('func registrar(forPlugin pluginKey: String)'),
      native.indexOf('func hasPlugin(_ pluginKey: String)'),
    );
    expect(proxyRegistrar.indexOf('registrarRequested(pluginKey)'),
        lessThan(proxyRegistrar.indexOf('wrappedRegistry.registrar')));
    expect(native, contains('guard diagnosticChannel == nil else'));
    expect(read('ios/Runner/AppDelegate.swift'),
        isNot(contains('override func registrar(forPlugin')));
    expect(native, isNot(contains('URLSession')));
    expect(native, isNot(contains('URLRequest')));
    expect(native, isNot(contains('UserDefaults')));
    expect(generated, isNot(contains('StartupDiagnostics')));
  });

  test('exception chain is preserve-and-forward-only when present', () {
    final native = read('ios/Runner/StartupDiagnostics.swift');
    expect(native, contains('NSGetUncaughtExceptionHandler()'));
    expect(native, contains('NSSetUncaughtExceptionHandler'));
    expect(native, contains('planFlowUncaughtExceptionHandler'));
    expect(native, isNot(contains('NSSetUncaughtExceptionHandler {')));
    expect(native, contains('previous?(exception)'));
    expect(native, contains('planFlowPreviousExceptionHandler = nil'));
    expect(native, contains('exception.reason'));
    expect(native, contains('exception.callStackSymbols'));
    expect(native, contains('exceptionFrameInspectionLimit = 8'));
    expect(native, contains('allowedExceptionNames'));
    expect(native, contains('allowedModuleTokens'));
    expect(native, contains('classifyReason(exception.reason)'));
    expect(native, contains('modulePresenceSummary(inspectedFrames)'));
    expect(native, contains('logger.fault('));
    expect(native, contains('reason_category='));
    expect(native, contains('module_presence='));
    expect(native, contains('ADMOB_CONFIGURATION'));
    expect(native, contains('GOOGLE_MAPS_CONFIGURATION'));
    expect(native, contains('NAVER_MAPS_CONFIGURATION'));
    expect(native, contains('FIREBASE_CONFIGURATION'));
    expect(native, contains('DUPLICATE_PLUGIN_REGISTRATION'));
    expect(native, contains('UISCENE_STORYBOARD_CONFIGURATION'));
    expect(native, contains('return "UNCLASSIFIED"'));
    final publicExceptionLog = native.substring(
      native.indexOf('logger.fault('),
      native.indexOf('  private func classifyReason'),
    );
    expect(publicExceptionLog, isNot(contains('exception.reason')));
    expect(publicExceptionLog, isNot(contains('callStackSymbols')));
    expect(publicExceptionLog, isNot(contains('backtrace')));
    expect(publicExceptionLog, isNot(contains('rawName')));
    expect(native, isNot(contains('redactAndBound')));
    expect(native, isNot(contains('NSRegularExpression')));
    expect(native, isNot(contains('reason=\\(')));
    expect(native, isNot(contains('backtrace=')));
    expect(native, isNot(contains('exception.userInfo')));
    expect(native, isNot(contains('private func recordStage')));
    expect(native, isNot(contains('signal')));
    expect(native, isNot(contains('method_exchangeImplementations')));
  });

  test('Android startup markers make zero native channel calls', () async {
    const channel = MethodChannel('planflow/native_startup_diagnostics');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    var calls = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls++;
      return null;
    });
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      NativeStartupDiagnostics.dartMainEnter();
      NativeStartupDiagnostics.runAppReached();
      NativeStartupDiagnostics.firstFrame();
      await pumpEventQueue();
      expect(calls, 0);
    } finally {
      debugDefaultTargetPlatformOverride = null;
      messenger.setMockMethodCallHandler(channel, null);
    }
  });

  test('iOS startup markers send only allowlisted stage calls', () async {
    const channel = MethodChannel('planflow/native_startup_diagnostics');
    const expectedStages = <String>[
      'DART_MAIN_ENTER',
      'RUNAPP_REACHED',
      'FIRST_FRAME',
    ];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return null;
    });
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    try {
      NativeStartupDiagnostics.dartMainEnter();
      NativeStartupDiagnostics.runAppReached();
      NativeStartupDiagnostics.firstFrame();
      await pumpEventQueue();
      expect(calls, hasLength(expectedStages.length));
      for (var index = 0; index < expectedStages.length; index++) {
        expect(calls[index].method, 'mark');
        expect(calls[index].arguments, <String, Object>{
          'stage': expectedStages[index],
        });
      }
    } finally {
      debugDefaultTargetPlatformOverride = null;
      messenger.setMockMethodCallHandler(channel, null);
    }
  });

  test('Build 19 symbols gate is fail-closed and artifact allowlisted', () {
    final workflow = read('.github/workflows/ios-release.yml');
    expect(workflow, contains('IOS_BUILD_NUMBER: 19'));
    expect(workflow, contains('GITHUB_REF:-'));
    expect(workflow, contains('workflow_run_number'));
    expect(workflow,
        isNot(contains(r'"${GITHUB_RUN_NUMBER:-}" != "18"')));
    expect(workflow, contains(r'"${IOS_BUILD_NUMBER:-}" != "19"'));
    expect(workflow, contains('workflow_run_id'));
    expect(workflow, contains('workflow_run_number'));
    expect(workflow, contains('workflow_run_attempt'));
    expect(workflow, contains('refs/heads/main'));
    expect(workflow, contains('dwarfdump --uuid'));
    expect(workflow, contains('BLOCKED_SYMBOL_UUID_MISMATCH'));
    expect(workflow, contains('executable_uuid_arm64'));
    expect(workflow, contains('dsym_uuid_arm64'));
    expect(workflow, contains('dsym_zip_sha256'));
    expect(workflow,
        contains(r'''xcode_version_output="$(xcodebuild -version)"'''));
    expect(workflow,
        contains(r'''flutter_version_output="$(flutter --version)"'''));
    expect(workflow,
        contains(r'''xcode_version="${xcode_version_output%%$'\n'*}"'''));
    expect(workflow,
        contains(r'''flutter_version="${flutter_version_output%%$'\n'*}"'''));
    expect(workflow, isNot(contains('xcodebuild -version | head -n 1')));
    expect(workflow, isNot(contains('flutter --version | head -n 1')));
    final uploadStart =
        workflow.indexOf('      - name: Upload retained Build 19 symbols');
    final exportStart =
        workflow.indexOf('      - name: Export signed IPA', uploadStart);
    expect(uploadStart, greaterThanOrEqualTo(0));
    expect(exportStart, greaterThan(uploadStart));
    final uploadBlock = workflow.substring(uploadStart, exportStart);
    expect(uploadBlock, contains('if-no-files-found: error'));
    expect(uploadBlock, contains('retention-days: 90'));
    expect(uploadBlock, contains('Runner.app.dSYM.zip'));
    expect(uploadBlock, contains('manifest.json'));
    expect(uploadBlock, isNot(contains('always()')));
    expect(uploadBlock, isNot(contains('/*')));
    for (final forbidden in <String>[
      'Runner.app/Runner',
      '.ipa',
      '.xcarchive',
      '.p12',
      '.mobileprovision',
      'keychain',
      'GoogleService-Info.plist',
      'API_KEY',
    ]) {
      expect(uploadBlock, isNot(contains(forbidden)), reason: forbidden);
    }
  });
}
