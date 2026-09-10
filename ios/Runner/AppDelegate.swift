import AVFoundation
import CoreLocation
import EventKit
import Flutter
import Speech
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    willFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
  ) -> Bool {
    StartupDiagnostics.shared.installExceptionHandler()
    StartupDiagnostics.shared.mark("NATIVE_PROCESS_START")
    StartupDiagnostics.shared.armBuild21FirstFrameDiagnostic()
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
    diagnostics.mark("IMPLICIT_ENGINE_CALLBACK")
    diagnostics.attach(to: engineBridge.applicationRegistrar.messenger())
    PlanFlowPermissionChannel.register(with: engineBridge.applicationRegistrar.messenger())
    StartupDiagnostics.shared.mark("PLUGIN_REGISTRATION_BEGIN")
    let registry = StartupDiagnosticsPluginRegistry(wrapping: engineBridge.pluginRegistry)
    GeneratedPluginRegistrant.register(with: registry)
    StartupDiagnostics.shared.mark("PLUGIN_REGISTRATION_END")
    StartupDiagnostics.shared.mark("FLUTTER_ENGINE_READY")
  }
}

/// The native authority for the iOS permissions requested by onboarding.
///
/// Status values deliberately distinguish denied, settings-required,
/// restricted and unavailable states so the Dart UI never treats a missing
/// system prompt as a successful grant.
final class PlanFlowPermissionChannel: NSObject, CLLocationManagerDelegate {
  private static let channelName = "planflow/ios_permissions"
  private static var instances: [PlanFlowPermissionChannel] = []
  private let channel: FlutterMethodChannel
  private var locationManager: CLLocationManager?
  private var locationCompletion: ((String) -> Void)?

  private init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: Self.channelName, binaryMessenger: messenger)
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call: call, result: result)
    }
  }

  static func register(with messenger: FlutterBinaryMessenger) {
    instances.append(PlanFlowPermissionChannel(messenger: messenger))
  }

  private func handle(call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "checkMicrophonePermission":
      result(microphoneStatus())
    case "requestMicrophonePermission":
      AVAudioSession.sharedInstance().requestRecordPermission { [weak self] _ in
        DispatchQueue.main.async {
          result(self?.microphoneStatus() ?? "error")
        }
      }
    case "checkSpeechRecognitionPermission":
      result(speechStatus())
    case "requestSpeechRecognitionPermission":
      SFSpeechRecognizer.requestAuthorization { [weak self] _ in
        DispatchQueue.main.async {
          result(self?.speechStatus() ?? "error")
        }
      }
    case "checkLocationPermission":
      result(locationStatus())
    case "requestLocationPermission":
      requestLocation { status in result(status) }
    case "checkCalendarPermission":
      result(calendarStatus())
    case "requestCalendarPermission":
      requestCalendar { status in result(status) }
    case "openAppSettings":
      openSettings(result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func microphoneStatus() -> String {
    switch AVAudioSession.sharedInstance().recordPermission {
    case .granted: return "granted"
    case .denied: return "settingsRequired"
    case .undetermined: return "denied"
    @unknown default: return "unavailable"
    }
  }

  private func speechStatus() -> String {
    switch SFSpeechRecognizer.authorizationStatus() {
    case .authorized: return "granted"
    case .denied: return "settingsRequired"
    case .restricted: return "restricted"
    case .notDetermined: return "denied"
    @unknown default: return "unavailable"
    }
  }

  private func locationStatus() -> String {
    switch CLLocationManager.authorizationStatus() {
    case .authorizedAlways, .authorizedWhenInUse: return "granted"
    case .denied: return "settingsRequired"
    case .restricted: return "restricted"
    case .notDetermined: return "denied"
    @unknown default: return "unavailable"
    }
  }

  private func calendarStatus() -> String {
    let status = EKEventStore.authorizationStatus(for: .event)
    if #available(iOS 17.0, *) {
      switch status {
      case .fullAccess: return "granted"
      case .writeOnly, .denied: return "settingsRequired"
      case .restricted: return "restricted"
      case .notDetermined: return "denied"
      @unknown default: return "unavailable"
      }
    }
    switch status {
    case .authorized: return "granted"
    case .denied: return "settingsRequired"
    case .restricted: return "restricted"
    case .notDetermined: return "denied"
    @unknown default: return "unavailable"
    }
  }

  private func requestLocation(completion: @escaping (String) -> Void) {
    DispatchQueue.main.async { [weak self] in
      guard let self else {
        completion("error")
        return
      }
      guard CLLocationManager.authorizationStatus() == .notDetermined else {
        completion(self.locationStatus())
        return
      }
      guard self.locationCompletion == nil else {
        completion("timeout")
        return
      }
      let manager = CLLocationManager()
      manager.delegate = self
      self.locationManager = manager
      self.locationCompletion = completion
      manager.requestWhenInUseAuthorization()
    }
  }

  func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
    resolveLocationIfReady()
  }

  func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
    resolveLocationIfReady()
  }

  private func resolveLocationIfReady() {
    guard CLLocationManager.authorizationStatus() != .notDetermined else { return }
    let status = locationStatus()
    let completion = locationCompletion
    locationCompletion = nil
    locationManager = nil
    completion?(status)
  }

  private func requestCalendar(completion: @escaping (String) -> Void) {
    let current = calendarStatus()
    guard current == "denied" else {
      completion(current)
      return
    }
    let store = EKEventStore()
    if #available(iOS 17.0, *) {
      // requestFullAccessToEvents completion is (Bool, Error?) -> Void; both are
      // discarded because calendarStatus() re-queries EKEventStore's live
      // authorizationStatus right after, which reflects denied/restricted
      // correctly even when granted==false or an error fired (matches the
      // mic/speech/legacy-calendar completion pattern above).
      store.requestFullAccessToEvents { [weak self] _, _ in
        DispatchQueue.main.async { completion(self?.calendarStatus() ?? "error") }
      }
    } else {
      store.requestAccess(to: .event) { [weak self] _, _ in
        DispatchQueue.main.async { completion(self?.calendarStatus() ?? "error") }
      }
    }
  }

  private func openSettings(result: @escaping FlutterResult) {
    guard let url = URL(string: UIApplication.openSettingsURLString),
          UIApplication.shared.canOpenURL(url) else {
      result(false)
      return
    }
    UIApplication.shared.open(url, options: [:]) { opened in result(opened) }
  }
}
