import UIKit

/// Owns the persistent web view controller and swaps in the connection editor
/// when there is no server configured (or the user asks to change it).
final class RootViewController: UIViewController {
    private var webVC: WebViewController?
    private var sshSession: SSHRemoteSession?

    /// Last successful SSH connection, for silent (device-key) reconnects after
    /// the tunnel dies — iOS kills sockets whenever the app is suspended.
    private var sshReconnect: (target: String, localPort: Int)?
    private var sshReconnecting = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        if let url = ConnectionStore.serverURL {
            showWeb(url: url)
        }
        // iOS suspension kills the SSH tunnel; try a silent key-based
        // reconnect when the app returns, so the workbench's own reconnect
        // banner finds the same forwarded port alive again.
        NotificationCenter.default.addObserver(
            self, selector: #selector(reconnectSSHIfNeeded),
            name: UIApplication.willEnterForegroundNotification, object: nil
        )
    }

    @objc private func reconnectSSHIfNeeded() {
        guard let reconnect = sshReconnect, !sshReconnecting else { return }
        guard sshSession == nil || sshSession?.isClosed != false else { return }
        connectSSH(target: reconnect.target, password: "", silent: true, preferredLocalPort: reconnect.localPort)
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
    ///
    /// `silent` is the auto-reconnect mode: device-key auth only, no dialogs,
    /// reuse the previous forwarded port so the page's remoteAuthority stays
    /// valid and the workbench resumes without a reload.
    private func connectSSH(target: String, password: String, silent: Bool = false, preferredLocalPort: Int? = nil) {
        guard let parsed = ConnectionStore.parseSSHTarget(target) else { return }
        guard let commit = WorkbenchServer.vscodeCommit else {
            showSSHError("Missing ios-commit.txt in the app bundle — re-run fetch-vscode-web.sh.")
            return
        }

        var progressAlert: UIAlertController?
        if !silent {
            let alert = UIAlertController(title: "SSH Remote", message: "Connecting…", preferredStyle: .alert)
            present(alert, animated: true)
            progressAlert = alert
        }

        sshReconnecting = true
        sshSession?.stop()
        let session = SSHRemoteSession()
        sshSession = session

        Task { @MainActor in
            defer { sshReconnecting = false }
            do {
                let ready = try await session.start(
                    config: .init(host: parsed.host, port: parsed.port, username: parsed.user, password: password),
                    vscodeCommit: commit,
                    preferredLocalPort: preferredLocalPort,
                    progress: { message in
                        DispatchQueue.main.async { progressAlert?.message = message }
                    }
                )
                session.onUnexpectedClose = { [weak self] in
                    DispatchQueue.main.async { self?.reconnectSSHIfNeeded() }
                }
                WorkbenchServer.shared.remote = .init(
                    authority: "localhost:\(ready.localPort)",
                    connectionToken: ready.connectionToken
                )
                sshReconnect = (target, ready.localPort)

                if silent, ready.localPort == preferredLocalPort {
                    // Same authority, live tunnel: the page's own reconnect
                    // flow picks the session back up — nothing else to do.
                    return
                }
                let finish = { [weak self] in
                    ConnectionStore.use(WorkbenchServer.localURL)
                    self?.showWeb(url: WorkbenchServer.localURL)
                }
                if let progressAlert {
                    progressAlert.dismiss(animated: true, completion: finish)
                } else {
                    finish()
                }
            } catch {
                self.sshSession?.stop()
                self.sshSession = nil
                if let progressAlert {
                    progressAlert.dismiss(animated: true) { [weak self] in
                        self?.showSSHError(String(describing: error))
                    }
                }
                // Silent reconnect failures stay quiet: the workbench shows its
                // own disconnected banner, and Servers offers manual reconnect.
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
            self.sshReconnect = nil
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
