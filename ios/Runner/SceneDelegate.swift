import Flutter
import UIKit

class SceneDelegate: FlutterSceneDelegate {
  // As the user's default messaging app, message taps arrive as im: URLs —
  // both while running and in the cold-launch connection options.
  override func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    super.scene(scene, willConnectTo: session, options: connectionOptions)
    for context in connectionOptions.urlContexts where context.url.scheme == "im" {
      AppDelegate.deliverLink(context.url)
    }
  }

  override func scene(
    _ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>
  ) {
    super.scene(scene, openURLContexts: URLContexts)
    for context in URLContexts where context.url.scheme == "im" {
      AppDelegate.deliverLink(context.url)
    }
  }
}
