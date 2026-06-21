import UIKit
import WebKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        WKWebView.disableInputAccessoryViewGlobally()
        WKWebView.disableInputAssistantGlobally()
        WKWebView.trimEditMenuGlobally()
        WorkbenchServer.shared.startIfNeeded()
        sideLoading = true       // load the full command set (extraCommandsDictionary)
        initializeEnvironment()  // ios_system env (commandDictionary.plist is in app resources)
        IshTerminal.runHeadlessTestIfRequested()  // USB-driven guest automation (CODE_ISH_TEST_CMD)
        return true
    }

    // Scene configuration is declared in Info.plist (UIApplicationSceneManifest).
}
