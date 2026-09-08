import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
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
    expect(appDelegate, contains('if result {'));
    expect(appDelegate, contains('return super.registrar(forPlugin: plugin)'));
    expect(appDelegate.indexOf('PLUGIN_REGISTRATION_BEGIN'),
        lessThan(appDelegate.indexOf('GeneratedPluginRegistrant.register')));
    expect(appDelegate.indexOf('GeneratedPluginRegistrant.register'),
        lessThan(appDelegate.indexOf('PLUGIN_REGISTRATION_END')));
    expect(native, contains('not causal crash evidence'));
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
    expect(read('ios/Runner/AppDelegate.swift'),
        contains('return super.registrar(forPlugin: plugin)'));
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
    expect(native, isNot(contains('private func recordStage')));
    expect(native, isNot(contains('signal')));
    expect(native, isNot(contains('method_exchangeImplementations')));
  });

  test('Build 18 symbols gate is fail-closed and artifact allowlisted', () {
    final workflow = read('.github/workflows/ios-release.yml');
    expect(workflow, contains('IOS_BUILD_NUMBER: 18'));
    expect(workflow, contains('GITHUB_REF:-'));
    expect(workflow, contains('GITHUB_RUN_NUMBER:-'));
    expect(workflow, contains('workflow_run_id'));
    expect(workflow, contains('workflow_run_number'));
    expect(workflow, contains('workflow_run_attempt'));
    expect(workflow, contains('refs/heads/main'));
    expect(workflow, contains('dwarfdump --uuid'));
    expect(workflow, contains('BLOCKED_SYMBOL_UUID_MISMATCH'));
    expect(workflow, contains('executable_uuid_arm64'));
    expect(workflow, contains('dsym_uuid_arm64'));
    expect(workflow, contains('dsym_zip_sha256'));
    final uploadStart =
        workflow.indexOf('      - name: Upload retained Build 18 symbols');
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
