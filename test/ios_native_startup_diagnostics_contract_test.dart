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

  test('Build 21 native contract is bounded and categorical', () {
    final native = read('ios/Runner/StartupDiagnostics.swift');
    final appDelegate = read('ios/Runner/AppDelegate.swift');
    final sceneDelegate = read('ios/Runner/SceneDelegate.swift');
    const markers = <String>[
      'NATIVE_PROCESS_START',
      'APPDELEGATE_ENTER',
      'SCENE_WILL_CONNECT',
      'SCENE_CONNECTED',
      'IMPLICIT_ENGINE_CALLBACK',
      'PLUGIN_REGISTRATION_BEGIN',
      'PLUGIN_REGISTRATION_END',
      'FLUTTER_ENGINE_READY',
      'DART_MAIN_ENTER',
      'SYSTEM_UI_MODE_BEGIN',
      'SYSTEM_UI_MODE_COMPLETE',
      'RUNAPP_REACHED',
      'FIRST_FRAME',
    ];
    for (final marker in markers) {
      expect(native, contains(marker), reason: marker);
    }
    expect(native, contains('build21DiagnosticBuildNumber = "21"'));
    expect(native, contains('build21DiagnosticDelay: TimeInterval = 12'));
    expect(native, contains('build21DiagnosticMaximumAttempts = 2'));
    expect(native, contains('DispatchQueue.main.asyncAfter'));
    expect(native, contains('overlay.removeFromSuperview()'));
    expect(native, contains('firstFrameReceived ||'));
    for (final field in <String>[
      'ROOT_CLASS=',
      'FLUTTER_VIEW=',
      'ENGINE=',
      'IMPLICIT_ENGINE=',
      'PLUGIN_REGISTRATION=',
      'DART_MAIN=',
      'SYSTEM_UI=',
      'RUNAPP=',
      'FIRST_FRAME=',
      'LAST_EVENT=',
    ]) {
      expect(native, contains(field), reason: field);
    }
    for (final value in <String>[
      'FLUTTER_VIEW_CONTROLLER',
      'NAVIGATION_CONTROLLER',
      'TAB_BAR_CONTROLLER',
      'SPLIT_VIEW_CONTROLLER',
      'PAGE_VIEW_CONTROLLER',
      'UI_VIEW_CONTROLLER',
      'OTHER',
      'MISSING',
      'ROOT',
      'CHILD',
      'PRESENTED',
      'ABSENT',
      'READY',
      'NOT_SEEN',
      'BEGIN',
      'COMPLETE',
      'YES',
      'NO',
    ]) {
      expect(native, contains(value), reason: value);
    }
    for (final forbidden in <String>[
      'UserDefaults',
      'URLSession',
      'URLRequest',
      'Crashlytics.sharedInstance',
      'recordError',
      'setCustomValue',
    ]) {
      expect(native, isNot(contains(forbidden)), reason: forbidden);
    }
    expect(native, isNot(contains('BUILD20')));
    expect(native, contains('topologyTraversalDepthLimit = 12'));
    expect(native, contains('Set<ObjectIdentifier>()'));
    expect(native, contains('rootClassCategory'));
    expect(native, contains('flutterViewLocation'));
    expect(
        native,
        contains(
            'guard !firstFrameReceived && !diagnosticOverlayPresented else'));
    expect(native, isNot(contains('String(describing:')));
    expect(native, isNot(contains('NSClassFromString')));
    expect(appDelegate, contains('armBuild21FirstFrameDiagnostic()'));
    final callback = appDelegate.substring(
      appDelegate.indexOf('didInitializeImplicitFlutterEngine'),
    );
    expect(callback.indexOf('IMPLICIT_ENGINE_CALLBACK'),
        lessThan(callback.indexOf('attach(')));
    expect(callback.indexOf('attach('),
        lessThan(callback.indexOf('PLUGIN_REGISTRATION_BEGIN')));
    expect(callback.indexOf('PLUGIN_REGISTRATION_BEGIN'),
        lessThan(callback.indexOf('GeneratedPluginRegistrant.register')));
    expect(callback.indexOf('GeneratedPluginRegistrant.register'),
        lessThan(callback.indexOf('PLUGIN_REGISTRATION_END')));
    expect(
        sceneDelegate,
        contains(
            'super.scene(scene, willConnectTo: session, options: connectionOptions)'));
    expect(sceneDelegate.indexOf('captureSceneWindow(window)'),
        greaterThan(sceneDelegate.indexOf('super.scene(')));
  });

  test('canonical storyboard has no module overrides', () {
    final storyboard = read('ios/Runner/Base.lproj/Main.storyboard');
    expect(storyboard, contains('FlutterViewController'));
    expect(storyboard, isNot(contains('customModule=')));
    expect(storyboard, isNot(contains('customModuleProvider=')));
  });

  test('Flutter 3.47.2 UIScene and implicit-engine boundaries remain canonical',
      () {
    final plist = read('ios/Runner/Info.plist');
    final appDelegate = read('ios/Runner/AppDelegate.swift');
    final main = read('lib/main.dart');
    for (final entry in <String>[
      '<key>UIApplicationSceneManifest</key>',
      '<key>UIApplicationSupportsMultipleScenes</key>',
      '<key>UISceneConfigurations</key>',
      '<key>UIWindowSceneSessionRoleApplication</key>',
      '<key>UISceneClassName</key>',
      '<string>UIWindowScene</string>',
      '<key>UISceneDelegateClassName</key>',
      r'<string>$(PRODUCT_MODULE_NAME).SceneDelegate</string>',
      '<key>UISceneConfigurationName</key>',
      '<string>flutter</string>',
      '<key>UISceneStoryboardFile</key>',
      '<string>Main</string>',
    ]) {
      expect(plist, contains(entry), reason: entry);
    }
    expect(RegExp('UIApplicationSceneManifest').allMatches(plist).length, 1);
    expect(appDelegate,
        contains('FlutterAppDelegate, FlutterImplicitEngineDelegate'));
    expect(
      appDelegate,
      contains(
        'didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge)',
      ),
    );
    final callback = appDelegate.substring(
      appDelegate.indexOf('didInitializeImplicitFlutterEngine'),
    );
    expect(callback.indexOf('IMPLICIT_ENGINE_CALLBACK'),
        lessThan(callback.indexOf('attach(')));
    expect(callback.indexOf('attach('),
        lessThan(callback.indexOf('PLUGIN_REGISTRATION_BEGIN')));
    expect(callback.indexOf('PLUGIN_REGISTRATION_BEGIN'),
        lessThan(callback.indexOf('StartupDiagnosticsPluginRegistry')));
    expect(callback.indexOf('StartupDiagnosticsPluginRegistry'),
        lessThan(callback.indexOf('GeneratedPluginRegistrant.register')));
    expect(callback.indexOf('GeneratedPluginRegistrant.register'),
        lessThan(callback.indexOf('PLUGIN_REGISTRATION_END')));
    expect(main, contains('NativeStartupDiagnostics.dartMainEnter();'));
    expect(main, contains('NativeStartupDiagnostics.runAppReached();'));
    expect(main, contains('NativeStartupDiagnostics.firstFrame();'));
    expect(main.indexOf('WidgetsFlutterBinding.ensureInitialized();'),
        lessThan(main.indexOf('NativeStartupDiagnostics.dartMainEnter();')));
    expect(main.indexOf('NativeStartupDiagnostics.dartMainEnter();'),
        lessThan(main.indexOf('runApp(ProviderScope')));
  });

  test('plugin registry observation remains bounded and forwarded', () {
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
    expect(
        native,
        contains(
            'final class StartupDiagnosticsPluginRegistry: NSObject, FlutterPluginRegistry'));
    expect(native,
        contains('return wrappedRegistry.registrar(forPlugin: pluginKey)'));
    expect(native, contains('return wrappedRegistry.hasPlugin(pluginKey)'));
    expect(native,
        contains('return wrappedRegistry.valuePublished(byPlugin: pluginKey)'));
    expect(native, contains('ledger.count < 64'));
    expect(native, contains('arguments.count == 1'));
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
  });

  test('exception diagnostics preserve forwarding and redact raw details', () {
    final native = read('ios/Runner/StartupDiagnostics.swift');
    expect(native, contains('NSGetUncaughtExceptionHandler()'));
    expect(
        native,
        contains(
            'NSSetUncaughtExceptionHandler(planFlowUncaughtExceptionHandler)'));
    expect(native, contains('previous?(exception)'));
    expect(native, contains('planFlowPreviousExceptionHandler = nil'));
    expect(native, contains('exception.reason'));
    expect(native, contains('exception.callStackSymbols'));
    expect(native, contains('exceptionFrameInspectionLimit = 8'));
    expect(native, contains('allowedExceptionNames'));
    expect(native, contains('allowedModuleTokens'));
    expect(native, contains('classifyReason(exception.reason)'));
    expect(native, contains('modulePresenceSummary(inspectedFrames)'));
    expect(native, contains('ADMOB_CONFIGURATION'));
    expect(native, contains('GOOGLE_MAPS_CONFIGURATION'));
    expect(native, contains('NAVER_MAPS_CONFIGURATION'));
    expect(native, contains('FIREBASE_CONFIGURATION'));
    expect(native, contains('DUPLICATE_PLUGIN_REGISTRATION'));
    expect(native, contains('UISCENE_STORYBOARD_CONFIGURATION'));
    final publicExceptionLog = native.substring(
      native.indexOf('logger.fault('),
      native.indexOf('  private func classifyReason'),
    );
    expect(publicExceptionLog, isNot(contains('exception.reason')));
    expect(publicExceptionLog, isNot(contains('callStackSymbols')));
    expect(publicExceptionLog, isNot(contains('backtrace=')));
    expect(publicExceptionLog, isNot(contains('rawName')));
    expect(native, isNot(contains('exception.userInfo')));
    expect(native, isNot(contains('method_exchangeImplementations')));
  });

  test('Dart markers are iOS-only and bracket startup boundaries', () {
    final dart = read('lib/core/native_startup_diagnostics.dart');
    final main = read('lib/main.dart');
    expect(dart,
        contains('kIsWeb || defaultTargetPlatform != TargetPlatform.iOS'));
    expect(main, contains('NativeStartupDiagnostics.dartMainEnter();'));
    expect(main, contains('NativeStartupDiagnostics.runAppReached();'));
    expect(main, contains('NativeStartupDiagnostics.firstFrame();'));
    final begin = main.indexOf('NativeStartupDiagnostics.systemUiModeBegin();');
    final awaitCall = main.indexOf(
        'await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);');
    final complete =
        main.indexOf('NativeStartupDiagnostics.systemUiModeComplete();');
    final runApp = main.indexOf('runApp(ProviderScope');
    expect(begin, greaterThanOrEqualTo(0));
    expect(awaitCall, greaterThan(begin));
    expect(complete, greaterThan(awaitCall));
    expect(runApp, greaterThan(complete));
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
      NativeStartupDiagnostics.systemUiModeBegin();
      NativeStartupDiagnostics.systemUiModeComplete();
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
      'SYSTEM_UI_MODE_BEGIN',
      'SYSTEM_UI_MODE_COMPLETE',
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
      NativeStartupDiagnostics.systemUiModeBegin();
      NativeStartupDiagnostics.systemUiModeComplete();
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
}
