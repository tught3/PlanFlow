import Flutter
import UIKit

class SceneDelegate: FlutterSceneDelegate {
  override func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    StartupDiagnostics.shared.mark("SCENE_WILL_CONNECT")
    super.scene(scene, willConnectTo: session, options: connectionOptions)
    StartupDiagnostics.shared.captureSceneWindow(window)
  }
}
