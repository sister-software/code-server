import UIKit
import WebKit

/// Hosts the single, long-lived WKWebView pointed at code-server.
///
/// Responsibilities:
///   - Persistent web view (cookies/login survive relaunch via the default data store).
///   - Clipboard bridge: round-trips navigator.clipboard through UIPasteboard so
///     copy/paste against the system clipboard works in WKWebView.
///   - Jetsam recovery: when iOS kills the web content process, reload + restore.
///   - Resilient loading: an inline error surface with automatic backoff retry,
///     instead of a dead white screen or a disruptive modal alert.
///   - Native action menu (Reload / Hard Reload / Servers) + keyboard shortcuts.
final class WebViewController: UIViewController {
    private let url: URL
    private(set) var webView: WKWebView!
    private let errorOverlay = ErrorOverlayView()

    /// Latest editor state captured before a likely jetsam, replayed after reload.
    private var pendingState: String?

    /// Auto-retry backoff state.
    private var retryAttempt = 0
    private var retryWorkItem: DispatchWorkItem?
    private let maxRetryDelay: TimeInterval = 30

    var onRequestSettings: (() -> Void)?

    init(url: URL) {
        self.url = url
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        retryWorkItem?.cancel()
    }

    // MARK: - View

    override func loadView() {
        let container = UIView()
        container.backgroundColor = .systemBackground

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
        content.addScriptMessageHandler(self, contentWorld: .page, name: "clipboard")
        config.userContentController = content

        let webView = WKWebView(frame: container.bounds, configuration: config)
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = false
        webView.scrollView.bounces = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        if #available(iOS 16.4, *) {
            webView.isInspectable = true // debug the live page via Safari Web Inspector
        }
        container.addSubview(webView)
        self.webView = webView

        errorOverlay.translatesAutoresizingMaskIntoConstraints = false
        errorOverlay.isHidden = true
        errorOverlay.onRetry = { [weak self] in self?.manualRetry() }
        errorOverlay.onSettings = { [weak self] in self?.onRequestSettings?() }
        container.addSubview(errorOverlay)
        NSLayoutConstraint.activate([
            errorOverlay.topAnchor.constraint(equalTo: container.topAnchor),
            errorOverlay.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            errorOverlay.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            errorOverlay.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])

        self.view = container
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        load()

        // Keyboardless entry to the action menu: two-finger long press.
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

    @objc func reloadPage() {
        webView.reload()
    }

    /// Full reload from the origin URL (bypasses cache; also used for recovery).
    func hardReload() {
        load()
    }

    // MARK: - Resilient loading (inline error + backoff)

    private func showError(_ error: Error) {
        let host = url.host ?? url.absoluteString
        errorOverlay.show(host: host, message: error.localizedDescription)
        view.bringSubviewToFront(errorOverlay)
        scheduleAutoRetry()
    }

    private func scheduleAutoRetry() {
        retryWorkItem?.cancel()
        let delay = min(maxRetryDelay, pow(2.0, Double(retryAttempt)))
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.retryAttempt += 1
            self.hardReload()
        }
        retryWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    @objc private func manualRetry() {
        retryWorkItem?.cancel()
        retryAttempt = 0
        hardReload()
    }

    private func loadSucceeded() {
        retryWorkItem?.cancel()
        retryAttempt = 0
        errorOverlay.hide()
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

    // MARK: - Action menu / settings

    override var keyCommands: [UIKeyCommand]? {
        [
            keyCommand(",", #selector(openSettings), title: "Servers"),
            keyCommand("r", #selector(reloadPage), title: "Reload"),
        ]
    }

    private func keyCommand(_ input: String, _ action: Selector, title: String) -> UIKeyCommand {
        // Cmd+Opt+<key> avoids VS Code's own Cmd shortcuts (e.g. Cmd+, / Cmd+R).
        let command = UIKeyCommand(input: input, modifierFlags: [.command, .alternate], action: action)
        command.discoverabilityTitle = title
        if #available(iOS 15.0, *) {
            command.wantsPriorityOverSystemBehavior = true
        }
        return command
    }

    @objc private func openSettings() {
        onRequestSettings?()
    }

    @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else { return }
        showActionMenu(at: gesture.location(in: view))
    }

    private func showActionMenu(at point: CGPoint) {
        guard presentedViewController == nil else { return }
        let sheet = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: "Reload", style: .default) { [weak self] _ in self?.reloadPage() })
        sheet.addAction(UIAlertAction(title: "Hard Reload", style: .default) { [weak self] _ in self?.hardReload() })
        sheet.addAction(UIAlertAction(title: "Servers…", style: .default) { [weak self] _ in self?.onRequestSettings?() })
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        // iPad requires an anchor for action sheets.
        if let popover = sheet.popoverPresentationController {
            popover.sourceView = view
            popover.sourceRect = CGRect(origin: point, size: .zero)
            popover.permittedArrowDirections = .any
        }
        present(sheet, animated: true)
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
}

// MARK: - Navigation / process lifecycle

extension WebViewController: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webView.removeInputAccessoryView() // kill the floating prev/next + dictation bar
        loadSucceeded()
        restoreStateIfNeeded()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code == NSURLErrorCancelled { return }
        showError(error)
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        if (error as NSError).code == NSURLErrorCancelled { return }
        showError(error)
    }

    // iOS killed the web content process under memory pressure — auto-recover.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        hardReload()
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
