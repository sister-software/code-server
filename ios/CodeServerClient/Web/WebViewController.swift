import UIKit
import WebKit

/// Hosts the single, long-lived WKWebView pointed at code-server.
///
/// v1 responsibilities:
///   - Persistent web view (cookies/login survive relaunch via the default data store).
///   - Clipboard bridge: round-trips navigator.clipboard through UIPasteboard so
///     copy/paste against the system clipboard actually works in WKWebView.
///   - Jetsam recovery: when iOS kills the web content process, reload and restore
///     state instead of leaving a dead white screen.
///   - Keyboard: the web view stays first responder so hardware keystrokes flow to
///     VS Code untouched (no Safari chrome to steal Cmd-W/T/N). The only native key
///     command is a non-conflicting shortcut to reopen connection settings.
final class WebViewController: UIViewController {
    private let url: URL
    private(set) var webView: WKWebView!

    /// Latest editor state captured before a likely jetsam, replayed after reload.
    private var pendingState: String?

    var onRequestSettings: (() -> Void)?

    init(url: URL) {
        self.url = url
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - View

    override func loadView() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default() // persist cookies + login session
        config.allowsInlineMediaPlayback = true
        config.defaultWebpagePreferences.allowsContentJavaScript = true

        let content = WKUserContentController()
        if let bridge = Self.loadBridgeScript() {
            // forMainFrameOnly: false so the shim also loads inside VS Code's
            // nested (cross-origin) webview iframes — previews, notebooks, etc.
            content.addUserScript(
                WKUserScript(source: bridge, injectionTime: .atDocumentStart, forMainFrameOnly: false)
            )
        }
        // Reply-capable handler lets navigator.clipboard.readText() await the
        // native UIPasteboard value as a Promise.
        content.addScriptMessageHandler(self, contentWorld: .page, name: "clipboard")
        config.userContentController = content

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = false
        webView.scrollView.bounces = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.keyboardDismissMode = .none
        if #available(iOS 16.4, *) {
            webView.isInspectable = true // debug the live page via Safari Web Inspector
        }
        self.webView = webView
        self.view = webView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        load()

        // Keyboardless fallback to reach settings: two-finger long press.
        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        longPress.numberOfTouchesRequired = 2
        webView.addGestureRecognizer(longPress)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        webView.becomeFirstResponder()
    }

    // MARK: - Loading

    private func load() {
        var request = URLRequest(url: url)
        request.attribution = .user
        webView.load(request)
    }

    func reloadFromOrigin() {
        load()
    }

    // MARK: - State snapshot / restore (jetsam recovery)

    func snapshotState() {
        guard isViewLoaded else { return }
        webView.evaluateJavaScript(
            "window.__codeServerBridge && window.__codeServerBridge.saveState ? window.__codeServerBridge.saveState() : '{}'"
        ) { [weak self] result, _ in
            if let state = result as? String { self?.pendingState = state }
        }
    }

    private func restoreStateIfNeeded() {
        guard let state = pendingState else { return }
        pendingState = nil
        let literal = Self.jsStringLiteral(state)
        webView.evaluateJavaScript(
            "window.__codeServerBridge && window.__codeServerBridge.restoreState && window.__codeServerBridge.restoreState(\(literal));"
        )
    }

    // MARK: - Settings entry points

    override var keyCommands: [UIKeyCommand]? {
        // Cmd+Opt+, avoids VS Code's own Cmd+, (Settings).
        let command = UIKeyCommand(
            input: ",",
            modifierFlags: [.command, .alternate],
            action: #selector(openSettings)
        )
        command.discoverabilityTitle = "Connection Settings"
        if #available(iOS 15.0, *) {
            command.wantsPriorityOverSystemBehavior = true
        }
        return [command]
    }

    @objc private func openSettings() {
        onRequestSettings?()
    }

    @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else { return }
        onRequestSettings?()
    }

    // MARK: - Helpers

    private static func loadBridgeScript() -> String? {
        guard let url = Bundle.main.url(forResource: "bridge", withExtension: "js") else {
            assertionFailure("bridge.js missing from bundle")
            return nil
        }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    /// Encode a Swift string as a safe JS string literal (including quotes).
    private static func jsStringLiteral(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [value]),
              let array = String(data: data, encoding: .utf8),
              array.count >= 2 else {
            return "\"\""
        }
        return String(array.dropFirst().dropLast()) // strip the surrounding [ ]
    }

    private func presentLoadError(_ error: Error) {
        guard presentedViewController == nil else { return }
        let alert = UIAlertController(
            title: "Couldn’t connect",
            message: error.localizedDescription,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Retry", style: .default) { [weak self] _ in
            self?.reloadFromOrigin()
        })
        alert.addAction(UIAlertAction(title: "Settings", style: .cancel) { [weak self] _ in
            self?.onRequestSettings?()
        })
        present(alert, animated: true)
    }
}

// MARK: - Navigation / process lifecycle

extension WebViewController: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webView.removeInputAccessoryView() // kill the floating prev/next + dictation bar
        restoreStateIfNeeded()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        presentLoadError(error)
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        // Ignore cancellations (e.g. redirects superseding a request).
        if (error as NSError).code == NSURLErrorCancelled { return }
        presentLoadError(error)
    }

    // iOS killed the web content process under memory pressure — auto-recover.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        reloadFromOrigin()
    }

    // Dev convenience: trust self-signed certs from your own lab.
    func webView(
        _ webView: WKWebView,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}

// MARK: - Popups (e.g. Cloudflare Access / SSO login windows)

extension WebViewController: WKUIDelegate {
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        // WKWebView drops target=_blank / window.open by default. Load such
        // requests in the main web view so auth popups don't silently vanish.
        if navigationAction.targetFrame == nil {
            webView.load(navigationAction.request)
        }
        return nil
    }
}

// MARK: - Clipboard bridge

extension WebViewController: WKScriptMessageHandlerWithReply {
    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage,
        replyHandler: @escaping (Any?, String?) -> Void
    ) {
        guard message.name == "clipboard",
              let body = message.body as? [String: Any],
              let action = body["action"] as? String else {
            replyHandler(nil, "malformed clipboard message")
            return
        }

        switch action {
        case "write":
            UIPasteboard.general.string = body["text"] as? String ?? ""
            replyHandler(nil, nil)
        case "read":
            replyHandler(UIPasteboard.general.string ?? "", nil)
        default:
            replyHandler(nil, "unknown clipboard action: \(action)")
        }
    }
}
