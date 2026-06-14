import AuthenticationServices
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
    private let fileBridge = FileBridgeSchemeHandler()
    private let fileBridgeMessages = FileBridgeMessageHandler()
    private let terminalBridge = TerminalBridgeHandler()
    /// Retains the in-flight OAuth session (real Safari, for autofill/Face ID).
    private var authSession: ASWebAuthenticationSession?

    /// Latest editor state captured before a likely jetsam, replayed after reload.
    private var pendingState: String?

    /// Auto-retry backoff state.
    private var retryAttempt = 0
    private var retryWorkItem: DispatchWorkItem?
    private let maxRetryDelay: TimeInterval = 30

    var onRequestSettings: (() -> Void)?
    /// Reports the live page URL after each committed navigation, so the owner
    /// can persist the open folder (the workbench encodes it as `?folder=`).
    var onNavigated: ((URL) -> Void)?

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

        // The local workbench opts into app-bound mode: that's what unlocks
        // service workers (required by VS Code webviews) in WKWebView. Remote
        // views must NOT opt in — app-bound navigation limits would block SSO
        // redirects (e.g. Cloudflare Access).
        if let host = url.host, host == "localhost" || host == "127.0.0.1" {
            config.limitsNavigationsToAppBoundDomains = true
        }

        let content = WKUserContentController()
        if let bridge = Self.loadBridgeScript() {
            // forMainFrameOnly: false so the shim also loads inside VS Code's
            // nested (cross-origin) webview iframes — previews, notebooks, etc.
            content.addUserScript(
                WKUserScript(source: bridge, injectionTime: .atDocumentStart, forMainFrameOnly: false)
            )
        }
        content.addScriptMessageHandler(self, contentWorld: .page, name: "clipboard")

        // Primary local-files transport: the ipad-files web extension (in a Web
        // Worker, no window.webkit) reaches native via a same-origin
        // BroadcastChannel relayed by bridge.js to this reply handler. Not CSP-
        // governed, so it needs no connect-src allowance.
        content.addScriptMessageHandler(fileBridgeMessages, contentWorld: .page, name: FileBridgeMessageHandler.name)
        // bridge.js routes window.open here: "authSession" for OAuth (Safari
        // autofill), "openExternal" for plain links (system browser). The
        // presence of "authSession" also tells workbench-main.js to use the
        // native URL-callback provider.
        content.add(self, name: "authSession")
        content.add(self, name: "openExternal")
        // Offline terminal: ipad-files Pseudoterminal ↔ BroadcastChannel ↔
        // bridge.js ↔ this handler ↔ ios_system.
        content.addScriptMessageHandler(terminalBridge, contentWorld: .page, name: TerminalBridgeHandler.name)
        config.userContentController = content

        // Fallback transport (unused while BroadcastChannel works): fetch() to
        // ipadbridge://. Requires connect-src to allow the scheme, so it's only
        // viable with a CSP change (nginx/patch).
        config.setURLSchemeHandler(fileBridge, forURLScheme: FileBridgeSchemeHandler.scheme)

        let webView = WKWebView(frame: container.bounds, configuration: config)
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = false
        webView.scrollView.bounces = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.delegate = self // pin the viewport; see UIScrollViewDelegate below
        webView.suppressesNativeInputBars = true // kill the iPad floating pill (workbench only)
        // The strip exposed when the keyboard resizes the viewport is painted
        // with underPageBackgroundColor (a system gray by default). Match the
        // app background so it blends instead of flashing gray.
        webView.underPageBackgroundColor = .systemBackground
        webView.backgroundColor = .systemBackground
        webView.scrollView.backgroundColor = .systemBackground
        if #available(iOS 16.4, *) {
            webView.isInspectable = true // debug the live page via Safari Web Inspector
        }
        container.addSubview(webView)
        self.webView = webView
        terminalBridge.webView = webView // push terminal output back to the page

        // Pin below the top safe area so VS Code's title bar doesn't render under
        // the status bar clock; full-bleed on the other edges.
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor),
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

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
        LocalFileStore.shared.presenter = self // present the folder picker from here
        load()

        // Keyboardless entry to the action menu: two-finger long press.
        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        longPress.numberOfTouchesRequired = 2
        webView.addGestureRecognizer(longPress)

        // Strip the iPad input-assistant bar whenever keyboard chrome appears.
        // willChangeFrame covers the hardware-keyboard assistant strip, which can
        // come up without a willShow (e.g. arrow-key focus with no prior touch).
        for name in [UIResponder.keyboardWillShowNotification, UIResponder.keyboardWillChangeFrameNotification] {
            NotificationCenter.default.addObserver(
                self, selector: #selector(clearInputAssistant), name: name, object: nil
            )
        }
    }

    @objc private func clearInputAssistant() {
        webView.clearInputAssistant()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        webView.becomeFirstResponder()
        webView.clearInputAssistant()
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

    /// Reload the LIVE URL (incl. the workbench's `?folder=…` etc.), falling
    /// back to the origin. Used for jetsam recovery and retries — reloading the
    /// bare origin instead would drop the open folder/session after iOS kills
    /// the backgrounded web content process.
    func hardReload() {
        var request = URLRequest(url: webView.url ?? url)
        request.attribution = .user
        webView.load(request)
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
        // Note: we deliberately do NOT bind Cmd-C/X/V here. VS Code's editor uses
        // the native DOM clipboard events (copy/cut/paste + clipboardData); letting
        // WebKit handle these keeps copy-with-selection and paste working. (Empty-
        // selection line-copy is a separate WebKit limitation — the copy event
        // doesn't fire without a selection.)
        [
            keyCommand(",", [.command, .alternate], #selector(openSettings), title: "Servers"),
            keyCommand("r", [.command, .alternate], #selector(reloadPage), title: "Reload"),
        ]
    }

    private func keyCommand(
        _ input: String,
        _ modifiers: UIKeyModifierFlags,
        _ action: Selector,
        title: String? = nil
    ) -> UIKeyCommand {
        let command = UIKeyCommand(input: input, modifierFlags: modifiers, action: action)
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
        sheet.addAction(UIAlertAction(title: "Diagnostics", style: .default) { [weak self] _ in self?.showDiagnostics() })
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        // iPad requires an anchor for action sheets.
        if let popover = sheet.popoverPresentationController {
            popover.sourceView = view
            popover.sourceRect = CGRect(origin: point, size: .zero)
            popover.permittedArrowDirections = .any
        }
        present(sheet, animated: true)
    }

    /// Page-state snapshot shown in an alert — our only "console" on device
    /// (os_log/NSLog don't reliably reach idevicesyslog, and Web Inspector
    /// needs a tethered Mac with Safari open).
    private func showDiagnostics() {
        let js = """
        const sw = navigator.serviceWorker
        const iframes = Array.from(document.querySelectorAll('iframe')).map(f => (f.src || f.name || '?').slice(0, 100))
        let extHostFetch = 'n/a'
        try {
          const probe = await fetch('/static/out/vs/workbench/services/extensions/worker/webWorkerExtensionHostIframe.html', { cache: 'no-store' })
          extHostFetch = probe.status
        } catch (e) { extHostFetch = String(e).slice(0, 80) }
        let swRegs = 'n/a'
        try { swRegs = sw ? (await sw.getRegistrations()).length : 'no sw' } catch (e) { swRegs = String(e).slice(0, 80) }
        return JSON.stringify({
          lastError: window.__lastError || 'none',
          url: location.href.slice(0, 100),
          secureContext: window.isSecureContext,
          cryptoSubtle: !!(crypto && crypto.subtle),
          serviceWorker: !!sw,
          swRegistrations: swRegs,
          extHostIframeFetch: extHostFetch,
          iframes: iframes,
          workbench: !!document.querySelector('.monaco-workbench'),
          bridgeInstalled: !!window.__codeServerBridgeInstalled,
          online: navigator.onLine,
        }, null, 1)
        """
        webView.callAsyncJavaScript(js, arguments: [:], in: nil, in: .page) { [weak self] result in
            let message: String
            switch result {
            case .success(let value): message = (value as? String) ?? String(describing: value)
            case .failure(let error): message = "error: \(error)"
            }
            let alert = UIAlertController(title: "Diagnostics", message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Copy", style: .default) { _ in
                UIPasteboard.general.string = message
            })
            alert.addAction(UIAlertAction(title: "OK", style: .cancel))
            self?.present(alert, animated: true)
        }
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
        loadSucceeded()
        restoreStateIfNeeded()
        webView.clearInputAssistant()
        if let live = webView.url { onNavigated?(live) }
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

// MARK: - Popups (OAuth: GitHub sign-in, Settings Sync, Cloudflare Access)

extension WebViewController: WKUIDelegate {
    // Right-click / two-finger tap: suppress WebKit's native element context
    // menu so only VS Code's own DOM context menu shows (no doubled-up iOS
    // menu). The editor handles `contextmenu` itself.
    func webView(
        _ webView: WKWebView,
        contextMenuConfigurationForElement elementInfo: WKContextMenuElementInfo,
        completionHandler: @escaping (UIContextMenuConfiguration?) -> Void
    ) {
        completionHandler(nil)
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        // window.open is intercepted in bridge.js and routed via message
        // handlers, so this fires only for popups that bypass it (e.g.
        // <a target="_blank"> / form targets). Treat those as external links.
        if let target = navigationAction.request.url {
            UIApplication.shared.open(target)
        }
        return nil
    }

    private func startAuthSession(url: URL) {
        let session = ASWebAuthenticationSession(url: url, callbackURLScheme: "codeipad") { [weak self] callbackURL, _ in
            self?.authSession = nil
            guard let self,
                  let callbackURL,
                  let query = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?.percentEncodedQuery
            else { return }
            // Deliver the (already percent-encoded) query to the workbench's
            // native URL-callback provider, which reconstructs the vscode: URI.
            let literal = Self.jsStringLiteral(query)
            self.webView.evaluateJavaScript(
                "window.__nativeAuthDeliver && window.__nativeAuthDeliver(\(literal));"
            )
        }
        session.presentationContextProvider = self
        // Share Safari's cookies + saved credentials (the whole point: autofill).
        session.prefersEphemeralWebBrowserSession = false
        authSession = session
        session.start()
    }
}

extension WebViewController: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        view.window ?? ASPresentationAnchor()
    }
}

// MARK: - window.open routing (auth session vs system browser)

extension WebViewController: WKScriptMessageHandler {
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let urlString = body["url"] as? String,
              let url = URL(string: urlString) else { return }
        switch message.name {
        case "authSession": startAuthSession(url: url)
        case "openExternal": UIApplication.shared.open(url)
        default: break
        }
    }
}

// MARK: - Viewport pinning
//
// VS Code is a fixed-layout app: its document never legitimately scrolls (all
// scrolling happens inside the page). WKWebView still auto-scrolls its outer
// scroll view to reveal the focused element when keyboard/input-assistant
// geometry changes (Monaco's hidden textarea follows the caret), which shows up
// as the whole viewport "jumping". Pinning the offset makes those adjustments
// no-ops. (WKWebView forwards scroll-view delegate callbacks alongside its
// internal handling, so setting the delegate is supported.)

extension WebViewController: UIScrollViewDelegate {
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        if scrollView.contentOffset != .zero {
            scrollView.contentOffset = .zero
        }
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
