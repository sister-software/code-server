import UIKit

/// Inline "can't connect" surface shown over the web view on load failure.
/// While visible the controller is auto-retrying with backoff; the spinner
/// reflects that, and the buttons offer an immediate retry or switching servers.
final class ErrorOverlayView: UIView {
    var onRetry: (() -> Void)?
    var onSettings: (() -> Void)?

    private let titleLabel = UILabel()
    private let messageLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let statusLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(host: String, message: String) {
        titleLabel.text = "Can’t reach \(host)"
        messageLabel.text = message
        isHidden = false
        spinner.startAnimating()
    }

    func hide() {
        isHidden = true
        spinner.stopAnimating()
    }

    private func setup() {
        backgroundColor = .systemBackground

        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 0

        messageLabel.font = .preferredFont(forTextStyle: .subheadline)
        messageLabel.textColor = .secondaryLabel
        messageLabel.textAlignment = .center
        messageLabel.numberOfLines = 0

        statusLabel.text = "Reconnecting…"
        statusLabel.font = .preferredFont(forTextStyle: .footnote)
        statusLabel.textColor = .tertiaryLabel

        let statusRow = UIStackView(arrangedSubviews: [spinner, statusLabel])
        statusRow.axis = .horizontal
        statusRow.spacing = 8
        statusRow.alignment = .center

        let retryButton = UIButton(configuration: .borderedProminent())
        retryButton.setTitle("Retry Now", for: .normal)
        retryButton.addTarget(self, action: #selector(retryTapped), for: .touchUpInside)

        let settingsButton = UIButton(configuration: .plain())
        settingsButton.setTitle("Servers…", for: .normal)
        settingsButton.addTarget(self, action: #selector(settingsTapped), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [
            titleLabel, messageLabel, statusRow, retryButton, settingsButton,
        ])
        stack.axis = .vertical
        stack.spacing = 12
        stack.alignment = .center
        stack.setCustomSpacing(20, after: statusRow)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -32),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
        ])
    }

    @objc private func retryTapped() { onRetry?() }
    @objc private func settingsTapped() { onSettings?() }
}
