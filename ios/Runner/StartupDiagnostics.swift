import Foundation
import Flutter
import os

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

/// Bounded, local-only startup evidence for the Build 18 diagnostic release.
/// The next registrar request or PLUGIN_REGISTRATION_END proves only that the
/// previous registration call returned; it is not causal crash evidence.
final class StartupDiagnostics {
  static let shared = StartupDiagnostics()

  static let exceptionFrameInspectionLimit = 8

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
    "PLUGIN_REGISTRATION_BEGIN",
    "PLUGIN_REGISTRATION_END",
    "FLUTTER_ENGINE_READY",
    "DART_MAIN_ENTER",
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
    if ledger.count < 64 {
      ledger.append(value)
    }
    lock.unlock()
    logger.info("\(value, privacy: .public)")
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
