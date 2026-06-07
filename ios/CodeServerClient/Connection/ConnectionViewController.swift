import UIKit

/// Simple form to point the app at a code-server instance.
final class ConnectionViewController: UIViewController {
    var onSave: ((URL) -> Void)?

    private let urlField = UITextField()

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Connect"
        view.backgroundColor = .systemBackground

        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "Connect", style: .done, target: self, action: #selector(connect)
        )
        if ConnectionStore.serverURL != nil {
            navigationItem.leftBarButtonItem = UIBarButtonItem(
                barButtonSystemItem: .cancel, target: self, action: #selector(cancel)
            )
        }

        let label = UILabel()
        label.text = "code-server URL"
        label.font = .preferredFont(forTextStyle: .footnote)
        label.textColor = .secondaryLabel

        urlField.placeholder = "https://code.your-tailnet.ts.net"
        urlField.text = ConnectionStore.serverURL?.absoluteString
        urlField.keyboardType = .URL
        urlField.textContentType = .URL
        urlField.autocapitalizationType = .none
        urlField.autocorrectionType = .no
        urlField.spellCheckingType = .no
        urlField.clearButtonMode = .whileEditing
        urlField.borderStyle = .roundedRect
        urlField.returnKeyType = .go
        urlField.delegate = self

        let hint = UILabel()
        hint.text = "Tip: reach your home lab over Tailscale. http and self-signed certificates are accepted."
        hint.font = .preferredFont(forTextStyle: .caption1)
        hint.textColor = .tertiaryLabel
        hint.numberOfLines = 0

        let stack = UIStackView(arrangedSubviews: [label, urlField, hint])
        stack.axis = .vertical
        stack.spacing = 8
        stack.setCustomSpacing(16, after: urlField)
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 24),
        ])
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        urlField.becomeFirstResponder()
    }

    @objc private func cancel() {
        dismiss(animated: true)
    }

    @objc private func connect() {
        guard
            let text = urlField.text?.trimmingCharacters(in: .whitespacesAndNewlines),
            !text.isEmpty,
            let url = Self.normalize(text)
        else {
            let alert = UIAlertController(
                title: "Invalid URL",
                message: "Enter a valid http(s) address, e.g. https://code.your-tailnet.ts.net",
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            present(alert, animated: true)
            return
        }
        onSave?(url)
    }

    /// Accept bare hosts ("code.lab") by defaulting to https.
    private static func normalize(_ input: String) -> URL? {
        var string = input
        if !string.contains("://") {
            string = "https://" + string
        }
        guard let url = URL(string: string), url.host != nil,
              url.scheme == "http" || url.scheme == "https" else {
            return nil
        }
        return url
    }
}

extension ConnectionViewController: UITextFieldDelegate {
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        connect()
        return true
    }
}
