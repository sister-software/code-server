import UIKit

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    private var root: RootViewController? { window?.rootViewController as? RootViewController }

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = RootViewController()
        window.makeKeyAndVisible()
        self.window = window
    }

    // Snapshot editor state at the moments iOS is most likely to jetsam the web
    // content process, so a kill becomes a flicker rather than a lost session.
    func sceneWillResignActive(_ scene: UIScene) {
        root?.snapshotState()
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        root?.snapshotState()
    }
}
