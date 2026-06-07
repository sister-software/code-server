import UIKit

/// Lists known code-server instances (tap to connect, swipe to delete) and lets
/// the user add a new one.
final class ConnectionViewController: UITableViewController {
    var onConnect: ((URL) -> Void)?

    private enum Section: Int, CaseIterable {
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
        case .add: return "Add a server"
        case .servers: return servers.isEmpty ? nil : "Saved"
        }
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        switch Section(rawValue: section)! {
        case .add: return "Reach your home lab over Tailscale. http and self-signed certificates are accepted."
        case .servers: return nil
        }
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch Section(rawValue: section)! {
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
        guard Section(rawValue: indexPath.section) == .servers else { return }
        onConnect?(servers[indexPath.row])
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
