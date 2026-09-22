import AVFoundation
import CoreLocation
import EventKit
import Flutter
import GoogleMaps
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
    // Build30: google_maps_flutter on iOS requires the native API key before
    // any map view is created. The key is injected into Runner Info.plist at
    // build time (ios-release.yml, mirroring the Firebase plist pattern) and
    // is only forwarded here when present, so debug/local builds without the
    // plist entry keep working.
    if let googleMapsApiKey = Bundle.main.object(forInfoDictionaryKey: "GoogleMapsApiKey") as? String,
       !googleMapsApiKey.isEmpty {
      GMSServices.provideAPIKey(googleMapsApiKey)
      StartupDiagnostics.shared.mark("GOOGLE_MAPS_API_KEY_PROVIDED")
    }
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
    PlanFlowDeviceCalendarChannel.register(with: engineBridge.applicationRegistrar.messenger())
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
    case "isTestFlight":
      result(isTestFlightBuild())
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

  private func isTestFlightBuild() -> Bool {
    guard let receiptURL = Bundle.main.appStoreReceiptURL else { return false }
    return receiptURL.lastPathComponent == "sandboxReceipt"
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

/// EventKit bridge for the device-calendar import/export contract used by
/// Flutter. Permission prompting remains owned by PlanFlowPermissionChannel;
/// this channel only reads/writes after authorization has been granted.
final class PlanFlowDeviceCalendarChannel: NSObject {
  private static let channelName = "planflow/device_calendar"
  private static var instances: [PlanFlowDeviceCalendarChannel] = []
  private let channel: FlutterMethodChannel
  private let store = EKEventStore()

  private init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: Self.channelName, binaryMessenger: messenger)
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call: call, result: result)
    }
  }

  static func register(with messenger: FlutterBinaryMessenger) {
    instances.append(PlanFlowDeviceCalendarChannel(messenger: messenger))
  }

  private func handle(call: FlutterMethodCall, result: @escaping FlutterResult) {
    DispatchQueue.main.async { [weak self] in
      guard let self else { result(false); return }
      guard self.hasFullAccess else {
        result(["error": "calendar_permission_required"])
        return
      }
      switch call.method {
      case "listDeviceCalendars": result(self.listCalendars())
      case "listDeviceCalendarEvents":
        result(self.listEvents(arguments: call.arguments))
      case "upsertDeviceCalendarEvent":
        result(self.upsertEvent(arguments: call.arguments))
      default: result(FlutterMethodNotImplemented)
      }
    }
  }

  private var hasFullAccess: Bool {
    let status = EKEventStore.authorizationStatus(for: .event)
    if #available(iOS 17.0, *) { return status == .fullAccess }
    return status == .authorized
  }

  private func listCalendars() -> [[String: Any]] {
    store.calendars(for: .event).map { calendar in
      [
        "id": calendar.calendarIdentifier,
        "name": calendar.title,
        "displayName": calendar.title,
        "accountName": calendar.source.title,
        "accountType": String(calendar.source.sourceType.rawValue),
        "ownerAccount": calendar.source.title,
        "isPrimary": calendar.isSubscribed == false && calendar.calendarIdentifier == store.defaultCalendarForNewEvents?.calendarIdentifier,
        "visible": !calendar.isSubscribed,
        "syncEvents": true,
      ]
    }
  }

  private func listEvents(arguments: Any?) -> [[String: Any]] {
    guard let args = arguments as? [String: Any],
          let ids = args["calendarIds"] as? [String],
          let startMillis = args["startMillis"] as? NSNumber,
          let endMillis = args["endMillis"] as? NSNumber else { return [] }
    let calendars = store.calendars(for: .event).filter { ids.contains($0.calendarIdentifier) }
    guard !calendars.isEmpty else { return [] }
    let start = Date(timeIntervalSince1970: startMillis.doubleValue / 1000)
    let end = Date(timeIntervalSince1970: endMillis.doubleValue / 1000)
    return store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: calendars)).map { event in
      let parsedNotes = self.parsePlanFlowMarker(event.notes)
      var row: [String: Any] = [
        "eventId": event.eventIdentifier ?? "",
        "calendarId": event.calendar.calendarIdentifier,
        "title": event.title ?? "",
        "description": parsedNotes.description,
        "location": event.location ?? "",
        "beginMillis": Int(event.startDate.timeIntervalSince1970 * 1000),
        "endMillis": Int(event.endDate.timeIntervalSince1970 * 1000),
        "allDay": event.isAllDay,
      ]
      if let modified = event.lastModifiedDate {
        row["lastDateMillis"] = Int(modified.timeIntervalSince1970 * 1000)
      }
      if let eventKey = parsedNotes.eventKey {
        row["eventKey"] = eventKey
      }
      return row
    }
  }

  private func upsertEvent(arguments: Any?) -> Bool {
    guard let args = arguments as? [String: Any],
          let title = args["title"] as? String,
          let startMillis = args["startMillis"] as? NSNumber,
          let endMillis = args["endMillis"] as? NSNumber else { return false }
    let eventKey = args["eventKey"] as? String ?? ""
    let start = Date(timeIntervalSince1970: startMillis.doubleValue / 1000)
    let end = Date(timeIntervalSince1970: endMillis.doubleValue / 1000)
    let calendars = store.calendars(for: .event).filter { $0.allowsContentModifications }
    guard let calendar = (store.defaultCalendarForNewEvents.flatMap { $0.allowsContentModifications ? $0 : nil } ?? calendars.first) else { return false }
    let predicate = store.predicateForEvents(withStart: start.addingTimeInterval(-86400), end: end.addingTimeInterval(86400), calendars: calendars)
    let event = store.events(matching: predicate).first {
      self.parsePlanFlowMarker($0.notes).eventKey == eventKey
    } ?? EKEvent(eventStore: store)
    event.calendar = calendar
    event.title = title
    event.notes = self.notesWithPlanFlowMarker(
      description: args["description"] as? String,
      eventKey: eventKey
    )
    event.location = args["location"] as? String
    event.startDate = start
    event.endDate = end > start ? end : start.addingTimeInterval(1800)
    event.isAllDay = (args["allDay"] as? Bool) ?? false
    do { try store.save(event, span: .thisEvent); return true } catch { return false }
  }

  private func parsePlanFlowMarker(_ notes: String?) -> (description: String, eventKey: String?) {
    let lines = (notes ?? "").components(separatedBy: .newlines)
    let marker = lines.first { $0.hasPrefix("planflow:") && $0.count > "planflow:".count }
    let description = lines.filter { line in
      !(line.hasPrefix("planflow:") && line.count > "planflow:".count)
    }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    return (description, marker)
  }

  private func notesWithPlanFlowMarker(description: String?, eventKey: String) -> String? {
    let cleanDescription = (description ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    guard !eventKey.isEmpty else { return cleanDescription.isEmpty ? nil : cleanDescription }
    let marker = eventKey.hasPrefix("planflow:") ? eventKey : "planflow:\(eventKey)"
    if cleanDescription.isEmpty { return marker }
    return "\(cleanDescription)\n\(marker)"
  }
}
