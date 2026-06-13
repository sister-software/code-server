import UIKit
import WebKit

/// Modal host for `window.open` / `target=_blank` popups — OAuth flows like
/// GitHub sign-in, Settings Sync, and marketplace auth.
///
/// The popup WKWebView MUST be created from the configuration WebKit hands to
/// `createWebViewWith` (it shares the opener's process pool + data store, so
/// cookies and the localStorage URL-callback both work across the two views).
/// Previously the opener navigated the MAIN workbench to the popup URL, which
/// dumped the editor to a white screen.
final class PopupWebViewController: UIViewController {
    let webView: WKWebView
    private let onClose: () -> Void
    private var closed = false

    init(configuration: WKWebViewConfiguration, onClose: @escaping () -> Void) {
        self.webView = WKWebView(frame: .zero, configuration: configuration)
        self.onClose = onClose
        super.init(nibName: nil, bundle: nil)
        // Set delegates now (not in viewDidLoad): WebKit starts loading the
        // popup as soon as we return the web view, before the view is on screen.
        webView.uiDelegate = self
        webView.navigationDelegate = self
        if #available(iOS 16.4, *) { webView.isInspectable = true }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        title = webView.url?.host
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .done, target: self, action: #selector(close)
        )
        webView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    @objc private func close() {
        guard !closed else { return }
        closed = true
        onClose()
    }
}

extension PopupWebViewController: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        title = webView.url?.host
        // OAuth redirects back to the workbench's callback route; once there the
        // main view's localStorage listener takes over, so close the popup.
        if webView.url?.path.contains("/callback") == true { close() }
    }

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

extension PopupWebViewController: WKUIDelegate {
    // The page called window.close() (typical at the end of an OAuth flow).
    func webViewDidClose(_ webView: WKWebView) { close() }
}
