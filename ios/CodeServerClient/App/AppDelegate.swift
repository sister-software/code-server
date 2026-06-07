import UIKit
import WebKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        WKWebView.disableInputAccessoryViewGlobally()
        return true
    }

    // Scene configuration is declared in Info.plist (UIApplicationSceneManifest).
}
