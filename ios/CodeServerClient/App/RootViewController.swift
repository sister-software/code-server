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

    /// Identity of the active connection ("local", "ssh:<target>", or a remote
    /// URL) and its remote authority, so we can persist/restore the open folder.
    private var connectionKey = "local"
    private var remoteAuthority: String?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        if let url = ConnectionStore.serverURL {
            showWeb(base: url, connectionKey: Self.key(for: url))
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

    /// Connection identity used to key the persisted open folder.
    private static func key(for url: URL) -> String {
        url == WorkbenchServer.localURL ? "local" : url.absoluteString
    }

    private func showWeb(base: URL, connectionKey: String, remoteAuthority: String? = nil) {
        self.connectionKey = connectionKey
        self.remoteAuthority = remoteAuthority

        if let existing = webVC {
            existing.willMove(toParent: nil)
            existing.view.removeFromSuperview()
            existing.removeFromParent()
            webVC = nil
        }

        let vc = WebViewController(url: urlWithSavedFolder(base: base, connectionKey: connectionKey))
        vc.onRequestSettings = { [weak self] in self?.presentConnection(animated: true) }
        vc.onNavigated = { [weak self] live in self?.persistFolder(from: live) }

        addChild(vc)
        vc.view.frame = view.bounds
        vc.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(vc.view)
        vc.didMove(toParent: self)
        webVC = vc
    }

    // MARK: - Open-folder persistence

    /// Appends the saved `?folder=` for this connection, rewriting a remote
    /// authority to the current tunnel's (the forward port changes per connect).
    private func urlWithSavedFolder(base: URL, connectionKey: String) -> URL {
        guard let saved = ConnectionStore.lastFolder(connectionKey) else { return base }
        let folder = rewriteRemoteAuthority(saved)
        guard var comps = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return base }
        comps.queryItems = [URLQueryItem(name: "folder", value: folder)]
        return comps.url ?? base
    }

    private func persistFolder(from live: URL) {
        let folder = URLComponents(url: live, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "folder" })?.value
        ConnectionStore.setLastFolder(folder, connectionKey)
    }

    /// `vscode-remote://<old authority>/path` → `vscode-remote://<current>/path`.
    /// Remote folder URIs embed the loopback forward port, which differs each
    /// connection; the path is the stable part.
    private func rewriteRemoteAuthority(_ folder: String) -> String {
        let scheme = "vscode-remote://"
        guard folder.hasPrefix(scheme), let authority = remoteAuthority else { return folder }
        let rest = folder.dropFirst(scheme.count)
        if let slash = rest.firstIndex(of: "/") {
            return scheme + authority + String(rest[slash...])
        }
        return scheme + authority
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

        sshReconnecting = true
        sshSession?.stop()
        let session = SSHRemoteSession()
        sshSession = session

        var progressAlert: UIAlertController?
        var cancelled = false
        var stage = "Connecting…"
        let startedAt = Date()
        var timer: Timer?
        if !silent {
            let alert = UIAlertController(
                title: ConnectionStore.sshName ?? "SSH Remote",
                message: stage,
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in
                cancelled = true
                session.stop() // fails the pending NIO promises; the task unwinds
            })
            present(alert, animated: true)
            progressAlert = alert
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak alert] _ in
                alert?.message = "\(stage)\n\(Int(Date().timeIntervalSince(startedAt)))s elapsed"
            }
        }

        // UI-level watchdog: whatever layer stalls (NIO, VPN, exec), the user
        // gets a loud failure if no progress arrives for 60s. Progress messages
        // (e.g. a slow first server download) keep kicking it.
        final class ActivityBox: @unchecked Sendable {
            private let lock = NSLock()
            private var last = Date()
            func kick() { lock.lock(); last = Date(); lock.unlock() }
            var idle: TimeInterval { lock.lock(); defer { lock.unlock() }; return Date().timeIntervalSince(last) }
        }
        let activity = ActivityBox()

        Task { @MainActor in
            defer { sshReconnecting = false }
            do {
                let ready = try await withThrowingTaskGroup(of: SSHRemoteSession.Ready.self) { group in
                    group.addTask {
                        try await session.start(
                            config: .init(host: parsed.host, port: parsed.port, username: parsed.user, password: password),
                            vscodeCommit: commit,
                            preferredLocalPort: preferredLocalPort,
                            progress: { message in
                                activity.kick()
                                DispatchQueue.main.async {
                                    stage = message
                                    progressAlert?.message = message
                                }
                            }
                        )
                    }
                    group.addTask {
                        while true {
                            try await Task.sleep(nanoseconds: 5_000_000_000)
                            if activity.idle > 60 {
                                throw SSHRemoteSession.SSHError.authenticationFailed(
                                    "watchdog: no progress for 60s — the stage shown in the dialog is where it stalled"
                                )
                            }
                        }
                    }
                    let ready = try await group.next()!
                    group.cancelAll()
                    return ready
                }
                session.onUnexpectedClose = { [weak self] in
                    DispatchQueue.main.async { self?.reconnectSSHIfNeeded() }
                }
                WorkbenchServer.shared.remote = .init(
                    authority: "localhost:\(ready.localPort)",
                    connectionToken: ready.connectionToken
                )
                sshReconnect = (target, ready.localPort)

                timer?.invalidate()
                if silent, ready.localPort == preferredLocalPort {
                    // Same authority, live tunnel: the page's own reconnect
                    // flow picks the session back up — nothing else to do.
                    return
                }
                let finish = { [weak self] in
                    ConnectionStore.use(WorkbenchServer.localURL)
                    self?.showWeb(
                        base: WorkbenchServer.localURL,
                        connectionKey: "ssh:\(target)",
                        remoteAuthority: "localhost:\(ready.localPort)"
                    )
                }
                if let progressAlert {
                    progressAlert.dismiss(animated: true, completion: finish)
                } else {
                    finish()
                }
            } catch {
                timer?.invalidate()
                self.sshSession?.stop()
                self.sshSession = nil
                if let progressAlert {
                    progressAlert.dismiss(animated: true) { [weak self] in
                        // User-cancelled: no error theater.
                        if !cancelled { self?.showSSHError(String(describing: error)) }
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
            self.showWeb(base: url, connectionKey: Self.key(for: url))
        }
        vc.onConnectSSH = { [weak self] target, password in
            // Sequence strictly: presenting the progress alert while the sheet
            // is still dismissing makes UIKit silently drop the alert.
            self?.dismiss(animated: true) {
                self?.connectSSH(target: target, password: password)
            }
        }
        let nav = UINavigationController(rootViewController: vc)
        nav.modalPresentationStyle = .formSheet
        present(nav, animated: animated)
    }
}
