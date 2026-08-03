import Flutter
import UIKit

class SceneDelegate: FlutterSceneDelegate {
  // As the user's default messaging and calling app, message taps arrive as
  // im: URLs and call taps as tel: URLs — both while running and in the
  // cold-launch connection options. okaymsg: is the app's own QR payload,
  // handed over by the iPhone camera.
  private static let handledSchemes: Set<String> = ["im", "tel", "okaymsg"]

  private func deliver<S: Sequence>(_ contexts: S)
  where S.Element == UIOpenURLContext {
    for context in contexts
    where Self.handledSchemes.contains(context.url.scheme ?? "") {
      AppDelegate.deliverLink(context.url)
    }
  }

  override func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    super.scene(scene, willConnectTo: session, options: connectionOptions)
    deliver(connectionOptions.urlContexts)
  }

  override func scene(
    _ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>
  ) {
    super.scene(scene, openURLContexts: URLContexts)
    deliver(URLContexts)
  }
}
