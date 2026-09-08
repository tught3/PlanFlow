import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    willFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
  ) -> Bool {
    StartupDiagnostics.shared.installExceptionHandler()
    StartupDiagnostics.shared.mark("NATIVE_PROCESS_START")
    return super.application(application, willFinishLaunchingWithOptions: launchOptions)
  }

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    StartupDiagnostics.shared.mark("APPDELEGATE_ENTER")
    let result = super.application(application, didFinishLaunchingWithOptions: launchOptions)
    if let controller = window?.rootViewController as? FlutterViewController {
      StartupDiagnostics.shared.attach(to: controller.binaryMessenger)
    }
    return result
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    let diagnostics = StartupDiagnostics.shared
    diagnostics.attach(to: engineBridge.applicationRegistrar.messenger())
    StartupDiagnostics.shared.mark("PLUGIN_REGISTRATION_BEGIN")
    let registry = StartupDiagnosticsPluginRegistry(wrapping: engineBridge.pluginRegistry)
    GeneratedPluginRegistrant.register(with: registry)
    StartupDiagnostics.shared.mark("PLUGIN_REGISTRATION_END")
    StartupDiagnostics.shared.mark("FLUTTER_ENGINE_READY")
  }
}
