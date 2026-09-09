import Foundation
import Flutter
import os
import UIKit

private let planFlowExceptionHandlerLock = NSLock()
private var planFlowPreviousExceptionHandler: NSUncaughtExceptionHandler?

private func planFlowUncaughtExceptionHandler(_ exception: NSException) {
  StartupDiagnostics.shared.recordException(exception)

  planFlowExceptionHandlerLock.lock()
  let previous = planFlowPreviousExceptionHandler
  planFlowPreviousExceptionHandler = nil
  planFlowExceptionHandlerLock.unlock()
  previous?(exception)
}

/// Transparent registry wrapper used only to observe generated registrar
/// requests. Every protocol call is forwarded with its original argument and
/// return value so plugin registration behavior remains unchanged.
final class StartupDiagnosticsPluginRegistry: NSObject, FlutterPluginRegistry {
  private let wrappedRegistry: FlutterPluginRegistry

  init(wrapping wrappedRegistry: FlutterPluginRegistry) {
    self.wrappedRegistry = wrappedRegistry
  }

  func registrar(forPlugin pluginKey: String) -> FlutterPluginRegistrar? {
    StartupDiagnostics.shared.registrarRequested(pluginKey)
    return wrappedRegistry.registrar(forPlugin: pluginKey)
  }

  func hasPlugin(_ pluginKey: String) -> Bool {
    return wrappedRegistry.hasPlugin(pluginKey)
  }

  func valuePublished(byPlugin pluginKey: String) -> NSObject? {
    return wrappedRegistry.valuePublished(byPlugin: pluginKey)
  }
}

/// Bounded, local-only startup evidence for the Build 20 diagnostic release.
/// The next registrar request or PLUGIN_REGISTRATION_END proves only that the
/// previous registration call returned; it is not causal crash evidence.
final class StartupDiagnostics {
  static let shared = StartupDiagnostics()

  static let exceptionFrameInspectionLimit = 8
  static let build20DiagnosticBuildNumber = "20"
  static let build20DiagnosticDelay: TimeInterval = 12
  static let build20DiagnosticMaximumAttempts = 2

  private static let allowedExceptionNames: Set<String> = [
    "NSGenericException",
    "NSInternalInconsistencyException",
    "NSInvalidArgumentException",
    "NSRangeException",
    "NSUnknownKeyException",
  ]

  private static let allowedModuleTokens: [(token: String, label: String)] = [
    ("Runner", "RUNNER"),
    ("Flutter", "FLUTTER"),
    ("GoogleMobileAds", "GOOGLE_MOBILE_ADS"),
    ("GoogleMaps", "GOOGLE_MAPS"),
    ("NMaps", "NAVER_MAPS"),
    ("Firebase", "FIREBASE"),
    ("UIKitCore", "UIKIT"),
    ("Foundation", "FOUNDATION"),
  ]

  static let channelName = "planflow/native_startup_diagnostics"
  static let stageNames: Set<String> = [
    "NATIVE_PROCESS_START",
    "APPDELEGATE_ENTER",
    "SCENE_WILL_CONNECT",
    "PLUGIN_REGISTRATION_BEGIN",
    "PLUGIN_REGISTRATION_END",
    "FLUTTER_ENGINE_READY",
    "DART_MAIN_ENTER",
    "SYSTEM_UI_MODE_BEGIN",
    "SYSTEM_UI_MODE_COMPLETE",
    "RUNAPP_REACHED",
    "FIRST_FRAME",
  ]

  static let pluginNames: Set<String> = [
    "AppLinksIosPlugin",
    "FilePickerPlugin",
    "FLTFirebaseCorePlugin",
    "FLTFirebaseCrashlyticsPlugin",
    "FirebaseRemoteConfigPlugin",
    "FlutterLocalNotificationsPlugin",
    "SwiftFlutterNaverMapPlugin",
    "FlutterSecureStoragePlugin",
    "FlutterTtsPlugin",
    "FGMGoogleMapsPlugin",
    "FLTGoogleMobileAdsPlugin",
    "FLTGoogleSignInPlugin",
    "HomeWidgetPlugin",
    "InAppReviewPlugin",
    "IntegrationTestPlugin",
    "FPPPackageInfoPlusPlugin",
    "ReceiveSharingIntentPlugin",
    "SharedPreferencesPlugin",
    "SpeechToTextPlugin",
    "URLLauncherPlugin",
    "WebViewFlutterPlugin",
  ]

  private let logger = Logger(subsystem: "com.fluxstudio.planflow", category: "startup")
  private let lock = NSLock()
  private var ledger: [String] = []
  private var exceptionHandlerInstalled = false
  private var diagnosticChannel: FlutterMethodChannel?
  private weak var sceneWindow: UIWindow?
  private var firstFrameReceived = false
  private var diagnosticPresentationAttempt = 0
  private var diagnosticOverlayPresented = false

  private init() {}

  func mark(_ stage: String) {
    guard Self.stageNames.contains(stage) else { return }
    record(stage)
  }

  func registrarRequested(_ plugin: String) {
    let safePlugin = Self.pluginNames.contains(plugin) ? plugin : "unknown"
    record("PLUGIN_REGISTRAR_REQUESTED plugin=\(safePlugin)")
  }

  func attach(to messenger: FlutterBinaryMessenger) {
    lock.lock()
    guard diagnosticChannel == nil else {
      lock.unlock()
      return
    }
    let channel = FlutterMethodChannel(name: Self.channelName, binaryMessenger: messenger)
    diagnosticChannel = channel
    lock.unlock()

    channel.setMethodCallHandler { [weak self] call, result in
      guard call.method == "mark", let arguments = call.arguments as? [String: Any],
            let stage = arguments["stage"] as? String,
            Self.stageNames.contains(stage),
            arguments.count == 1 else {
        result(FlutterMethodNotImplemented)
        return
      }
      self?.mark(stage)
      result(nil)
    }
  }

  /// The Flutter 3.47.2 template routes UIScene through this app-owned
  /// delegate. Capture only the existence and type of the UI boundary so a
  /// TestFlight black-screen report can distinguish scene/window failure from
  /// a later engine or Dart boundary without storing user data.
  func captureSceneWindow(_ window: UIWindow?) {
    let windowState = window == nil ? "MISSING" : "PRESENT"
    let rootType: String
    if let root = window?.rootViewController {
      rootType = root is FlutterViewController ? "FLUTTER_VIEW_CONTROLLER" : "OTHER"
    } else {
      rootType = "MISSING"
    }
    lock.lock()
    sceneWindow = window
    lock.unlock()
    record("SCENE_CONNECTED window=\(windowState) root=\(rootType)")
  }

  /// Build 20 is a bounded diagnostic release, not a product behavior change.
  /// It presents one local, no-PII overlay after the normal launch window so a
  /// Windows plus TestFlight iPhone user can report the last known boundary
  /// even when Flutter paints no usable pixels. Later builds do not arm it.
  func armBuild20FirstFrameDiagnostic() {
    guard Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ==
        Self.build20DiagnosticBuildNumber else {
      return
    }
    scheduleBuild20DiagnosticPresentation(after: Self.build20DiagnosticDelay)
  }

  func installExceptionHandler() {
    lock.lock()
    guard !exceptionHandlerInstalled else {
      lock.unlock()
      return
    }
    exceptionHandlerInstalled = true
    planFlowExceptionHandlerLock.lock()
    planFlowPreviousExceptionHandler = NSGetUncaughtExceptionHandler()
    planFlowExceptionHandlerLock.unlock()
    NSSetUncaughtExceptionHandler(planFlowUncaughtExceptionHandler)
    lock.unlock()
  }

  private func record(_ value: String) {
    lock.lock()
    if value == "FIRST_FRAME" {
      firstFrameReceived = true
    }
    if ledger.count < 64 {
      ledger.append(value)
    }
    lock.unlock()
    logger.info("\(value, privacy: .public)")
  }

  private func scheduleBuild20DiagnosticPresentation(after delay: TimeInterval) {
    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
      self?.presentBuild20DiagnosticOverlay()
    }
  }

  private func presentBuild20DiagnosticOverlay() {
    let snapshot: (window: UIWindow?, firstFrameReceived: Bool, lastEvent: String, attempt: Int)?
    lock.lock()
    if diagnosticOverlayPresented ||
        diagnosticPresentationAttempt >= Self.build20DiagnosticMaximumAttempts {
      snapshot = nil
    } else {
      diagnosticPresentationAttempt += 1
      snapshot = (
        sceneWindow,
        firstFrameReceived,
        ledger.last ?? "NONE",
        diagnosticPresentationAttempt
      )
    }
    lock.unlock()

    guard let snapshot else { return }
    guard let window = snapshot.window ?? activeWindow(), !window.bounds.isEmpty else {
      logger.info(
        "BUILD20_DIAGNOSTIC_WINDOW_UNAVAILABLE attempt=\(snapshot.attempt, privacy: .public)"
      )
      if snapshot.attempt < Self.build20DiagnosticMaximumAttempts {
        scheduleBuild20DiagnosticPresentation(after: 3)
      }
      return
    }

    lock.lock()
    diagnosticOverlayPresented = true
    lock.unlock()

    let overlay = UIView(frame: window.bounds)
    overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    overlay.backgroundColor = UIColor.black.withAlphaComponent(0.82)

    let horizontalInset: CGFloat = 24
    let cardHeight: CGFloat = 154
    let cardY = max(window.safeAreaInsets.top + 24, (window.bounds.height - cardHeight) / 2)
    let card = UIView(
      frame: CGRect(
        x: horizontalInset,
        y: cardY,
        width: max(0, window.bounds.width - horizontalInset * 2),
        height: cardHeight
      )
    )
    card.backgroundColor = .white
    card.layer.cornerRadius = 14

    let label = UILabel(frame: card.bounds.insetBy(dx: 18, dy: 16))
    label.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    label.numberOfLines = 0
    label.textColor = .black
    label.font = UIFont.monospacedSystemFont(ofSize: 14, weight: .medium)
    let firstFrame = snapshot.firstFrameReceived ? "YES" : "NO"
    label.text = "BUILD20_STARTUP_DIAGNOSTIC\nfirst_frame_received=\(firstFrame)\nlast_event=\(snapshot.lastEvent)\nRecord this screen, then wait for dismissal."

    card.addSubview(label)
    overlay.addSubview(card)
    window.addSubview(overlay)
    logger.info(
      "BUILD20_DIAGNOSTIC_PRESENTED first_frame=\(firstFrame, privacy: .public) last_event=\(snapshot.lastEvent, privacy: .public)"
    )
    DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
      overlay.removeFromSuperview()
    }
  }

  private func activeWindow() -> UIWindow? {
    for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
      if let window = scene.windows.first(where: { $0.isKeyWindow }) {
        return window
      }
    }
    return nil
  }

  fileprivate func recordException(_ exception: NSException) {
    let rawName = exception.name.rawValue
    let name = Self.allowedExceptionNames.contains(rawName) ? rawName : "UNKNOWN"
    let reasonCategory = classifyReason(exception.reason)
    let inspectedFrames = Array(
      exception.callStackSymbols.prefix(Self.exceptionFrameInspectionLimit)
    )
    let modulePresence = modulePresenceSummary(inspectedFrames)
    logger.fault(
      "UNCAUGHT_EXCEPTION name=\(name, privacy: .public) reason_category=\(reasonCategory, privacy: .public) frame_count=\(inspectedFrames.count, privacy: .public) module_presence=\(modulePresence, privacy: .public)"
    )
  }

  private func classifyReason(_ reason: String?) -> String {
    guard let reason, !reason.isEmpty else { return "NONE" }
    let normalized = reason.lowercased()
    let categories: [(category: String, tokens: [String])] = [
      ("ADMOB_CONFIGURATION", ["gadapplicationidentifier", "google mobile ads", "admob"]),
      ("GOOGLE_MAPS_CONFIGURATION", ["gmsservices", "google maps"]),
      ("NAVER_MAPS_CONFIGURATION", ["naver map", "ncpkeyid", "nmf"]),
      ("FIREBASE_CONFIGURATION", ["firebaseapp", "google-service-info.plist", "firebase"]),
      ("DUPLICATE_PLUGIN_REGISTRATION", ["duplicate plugin", "already registered", "plugin key"]),
      ("UISCENE_STORYBOARD_CONFIGURATION", ["uiscene", "flutterscenedelegate", "storyboard", "scene configuration"]),
    ]
    for entry in categories
      where entry.tokens.contains(where: { token in normalized.contains(token) }) {
      return entry.category
    }
    return "UNCLASSIFIED"
  }

  private func modulePresenceSummary(_ frames: [String]) -> String {
    let presentModules = Self.allowedModuleTokens.compactMap { entry -> String? in
      let isPresent = frames.contains { frame in
        frame.localizedCaseInsensitiveContains(entry.token)
      }
      return isPresent ? entry.label : nil
    }
    return presentModules.isEmpty ? "NONE" : presentModules.joined(separator: ",")
  }
}
