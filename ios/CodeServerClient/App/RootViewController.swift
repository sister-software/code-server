import UIKit

/// Owns the persistent web view controller and swaps in the connection editor
/// when there is no server configured (or the user asks to change it).
final class RootViewController: UIViewController {
    private var webVC: WebViewController?
    private var sshSession: SSHRemoteSession?

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

    /// The Remote-SSH dance, natively: SSH in, bootstrap the official
    /// vscode-server at our workbench's commit, tunnel it to loopback, then
    /// boot the local workbench attached to it as its remote.
    private func connectSSH(target: String, password: String) {
        guard let parsed = ConnectionStore.parseSSHTarget(target) else { return }
        guard let commit = WorkbenchServer.vscodeCommit else {
            showSSHError("Missing ios-commit.txt in the app bundle — re-run fetch-vscode-web.sh.")
            return
        }

        let progressAlert = UIAlertController(title: "SSH Remote", message: "Connecting…", preferredStyle: .alert)
        present(progressAlert, animated: true)

        sshSession?.stop()
        let session = SSHRemoteSession()
        sshSession = session

        Task { @MainActor in
            do {
                let ready = try await session.start(
                    config: .init(host: parsed.host, port: parsed.port, username: parsed.user, password: password),
                    vscodeCommit: commit,
                    progress: { message in
                        DispatchQueue.main.async { progressAlert.message = message }
                    }
                )
                WorkbenchServer.shared.remote = .init(
                    authority: "localhost:\(ready.localPort)",
                    connectionToken: ready.connectionToken
                )
                progressAlert.dismiss(animated: true) { [weak self] in
                    ConnectionStore.use(WorkbenchServer.localURL)
                    self?.showWeb(url: WorkbenchServer.localURL)
                }
            } catch {
                self.sshSession?.stop()
                self.sshSession = nil
                progressAlert.dismiss(animated: true) { [weak self] in
                    self?.showSSHError(String(describing: error))
                }
            }
        }
    }

    private func showSSHError(_ message: String) {
        let alert = UIAlertController(title: "SSH Connection Failed", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    private func presentConnection(animated: Bool) {
        guard presentedViewController == nil else { return }
        let vc = ConnectionViewController()
        vc.onConnect = { [weak self] url in
            guard let self else { return }
            // Plain (non-SSH) connections never use a remote authority; drop
            // any previous SSH session so the local workbench boots standalone.
            self.sshSession?.stop()
            self.sshSession = nil
            WorkbenchServer.shared.remote = nil
            ConnectionStore.use(url)
            self.dismiss(animated: true)
            self.showWeb(url: url)
        }
        vc.onConnectSSH = { [weak self] target, password in
            self?.dismiss(animated: true)
            self?.connectSSH(target: target, password: password)
        }
        let nav = UINavigationController(rootViewController: vc)
        nav.modalPresentationStyle = .formSheet
        present(nav, animated: animated)
    }
}
