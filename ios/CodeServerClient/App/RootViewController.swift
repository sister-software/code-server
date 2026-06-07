import UIKit

/// Owns the persistent web view controller and swaps in the connection editor
/// when there is no server configured (or the user asks to change it).
final class RootViewController: UIViewController {
    private var webVC: WebViewController?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        if let url = ConnectionStore.serverURL {
            showWeb(url: url)
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // Present the connection editor only once the view is in the window
        // hierarchy (presenting from viewDidLoad fails). Reached only when no
        // server URL is configured.
        if webVC == nil && presentedViewController == nil {
            presentConnection(animated: animated)
        }
    }

    func snapshotState() {
        webVC?.snapshotState()
    }

    private func showWeb(url: URL) {
        if let existing = webVC {
            existing.willMove(toParent: nil)
            existing.view.removeFromSuperview()
            existing.removeFromParent()
            webVC = nil
        }

        let vc = WebViewController(url: url)
        vc.onRequestSettings = { [weak self] in self?.presentConnection(animated: true) }

        addChild(vc)
        vc.view.frame = view.bounds
        vc.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(vc.view)
        vc.didMove(toParent: self)
        webVC = vc
    }

    private func presentConnection(animated: Bool) {
        guard presentedViewController == nil else { return }
        let vc = ConnectionViewController()
        vc.onConnect = { [weak self] url in
            ConnectionStore.use(url)
            self?.dismiss(animated: true)
            self?.showWeb(url: url)
        }
        let nav = UINavigationController(rootViewController: vc)
        nav.modalPresentationStyle = .formSheet
        present(nav, animated: animated)
    }
}
