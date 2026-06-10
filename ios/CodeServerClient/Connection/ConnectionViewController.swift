import UIKit

/// Lists known code-server instances (tap to connect, swipe to delete) and lets
/// the user add a new one.
final class ConnectionViewController: UITableViewController {
    var onConnect: ((URL) -> Void)?
    /// (target "user@host[:port]", password) — the shell does the Remote-SSH dance.
    var onConnectSSH: ((String, String) -> Void)?

    private enum Section: Int, CaseIterable {
        case local
        case ssh
        case add
        case servers
    }

    private var servers: [URL] = []
    private var current: URL?
    private weak var addField: UITextField?

    init() {
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Servers"
        servers = ConnectionStore.servers
        current = ConnectionStore.serverURL
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .done, target: self, action: #selector(done)
        )
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
        tableView.keyboardDismissMode = .interactive
    }

    @objc private func done() {
        dismiss(animated: true)
    }

    // MARK: - Actions

    @objc private func connectTyped() {
        guard let url = ConnectionStore.normalize(addField?.text ?? "") else {
            let alert = UIAlertController(
                title: "Invalid URL",
                message: "Enter a valid http(s) address, e.g. https://code.your-tailnet.ts.net",
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            present(alert, animated: true)
            return
        }
        onConnect?(url)
    }

    // MARK: - Table data

    override func numberOfSections(in tableView: UITableView) -> Int {
        Section.allCases.count
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch Section(rawValue: section)! {
        case .local: return "This iPad"
        case .ssh: return "SSH Remote"
        case .add: return "Add a server"
        case .servers: return servers.isEmpty ? nil : "Saved"
        }
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        switch Section(rawValue: section)! {
        case .local: return "VS Code running entirely on this iPad — works offline, edits local folders."
        case .ssh: return "Local workbench attached to your server over SSH: terminals, server-side extensions, the works. Long-press to reconfigure."
        case .add: return "Reach your home lab over Tailscale. http and self-signed certificates are accepted."
        case .servers: return nil
        }
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch Section(rawValue: section)! {
        case .local: return 1
        case .ssh: return 1
        case .add: return 1
        case .servers: return servers.count
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        cell.accessoryType = .none
        cell.accessoryView = nil
        cell.textLabel?.text = nil

        switch Section(rawValue: indexPath.section)! {
        case .local:
            cell.textLabel?.text = "Local Workbench"
            cell.accessoryType = (current == WorkbenchServer.localURL) ? .checkmark : .none
            cell.selectionStyle = .default
        case .ssh:
            if let target = ConnectionStore.sshTarget {
                cell.textLabel?.text = ConnectionStore.sshName ?? target
            } else {
                cell.textLabel?.text = "Set Up SSH Remote…"
            }
            cell.selectionStyle = .default
        case .add:
            let field = makeAddField()
            cell.contentView.addSubview(field)
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.leadingAnchor),
                field.trailingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.trailingAnchor),
                field.topAnchor.constraint(equalTo: cell.contentView.topAnchor, constant: 8),
                field.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor, constant: -8),
            ])
            cell.selectionStyle = .none
        case .servers:
            let url = servers[indexPath.row]
            cell.textLabel?.text = url.absoluteString
            cell.textLabel?.lineBreakMode = .byTruncatingMiddle
            cell.accessoryType = (url == current) ? .checkmark : .none
            cell.selectionStyle = .default
        }
        return cell
    }

    private func makeAddField() -> UITextField {
        if let existing = addField { existing.removeFromSuperview() }
        let field = UITextField()
        field.placeholder = "https://code.your-tailnet.ts.net"
        field.keyboardType = .URL
        field.textContentType = .URL
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.spellCheckingType = .no
        field.clearButtonMode = .whileEditing
        field.returnKeyType = .go
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false
        addField = field
        return field
    }

    // MARK: - Selection / deletion

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch Section(rawValue: indexPath.section)! {
        case .local:
            onConnect?(WorkbenchServer.localURL)
        case .ssh:
            if let target = ConnectionStore.sshTarget {
                promptPassword(target: target)
            } else {
                promptSSHTarget()
            }
        case .servers:
            onConnect?(servers[indexPath.row])
        case .add:
            break
        }
    }

    // MARK: - SSH prompts

    private func promptSSHTarget() {
        let alert = UIAlertController(
            title: "SSH Remote",
            message: "Address of your server, e.g. teffen@lab.your-tailnet.ts.net",
            preferredStyle: .alert
        )
        alert.addTextField { field in
            field.placeholder = "user@host[:port]"
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
            field.text = ConnectionStore.sshTarget
        }
        alert.addTextField { field in
            field.placeholder = "Display name (optional)"
            field.text = ConnectionStore.sshName
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Save", style: .default) { [weak self, weak alert] _ in
            guard let text = alert?.textFields?.first?.text,
                  let parsed = ConnectionStore.parseSSHTarget(text) else { return }
            // Re-saving doubles as "forget the pinned host key" (e.g. rekeyed server).
            HostKeyStore.forget(host: parsed.host, port: parsed.port)
            ConnectionStore.sshTarget = text.trimmingCharacters(in: .whitespacesAndNewlines)
            ConnectionStore.sshName = alert?.textFields?.dropFirst().first?.text
            self?.tableView.reloadData()
            self?.promptPassword(target: ConnectionStore.sshTarget!)
        })
        present(alert, animated: true)
    }

    private func promptPassword(target: String) {
        let alert = UIAlertController(
            title: "Connect to \(ConnectionStore.sshName ?? target)",
            message: "Uses this iPad's SSH key if the server knows it; otherwise enter a password. Copy Public Key → append to ~/.ssh/authorized_keys for passwordless logins.",
            preferredStyle: .alert
        )
        alert.addTextField { field in
            field.placeholder = "Password (optional with key)"
            field.isSecureTextEntry = true
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Copy Public Key", style: .default) { [weak self] _ in
            UIPasteboard.general.string = DeviceSSHKey.publicKeyOpenSSH()
            self?.promptPassword(target: target) // re-present; copying shouldn't end the flow
        })
        alert.addAction(UIAlertAction(title: "Change Address…", style: .default) { [weak self] _ in
            self?.promptSSHTarget()
        })
        alert.addAction(UIAlertAction(title: "Connect", style: .default) { [weak self, weak alert] _ in
            let password = alert?.textFields?.first?.text ?? ""
            self?.onConnectSSH?(target, password)
        })
        present(alert, animated: true)
    }

    override func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        Section(rawValue: indexPath.section) == .servers
    }

    override func tableView(
        _ tableView: UITableView,
        commit editingStyle: UITableViewCell.EditingStyle,
        forRowAt indexPath: IndexPath
    ) {
        guard editingStyle == .delete, Section(rawValue: indexPath.section) == .servers else { return }
        let url = servers.remove(at: indexPath.row)
        ConnectionStore.remove(url)
        servers = ConnectionStore.servers
        current = ConnectionStore.serverURL
        tableView.reloadData()
    }
}

extension ConnectionViewController: UITextFieldDelegate {
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        connectTyped()
        return true
    }
}
