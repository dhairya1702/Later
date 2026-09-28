import UIKit
import UniformTypeIdentifiers
/// Saves the screenshot locally, hands its upload to iOS, and dismisses. The
/// analysis service sends an APNs notification when understanding is complete.
final class ShareViewController: UIViewController {
    private enum Phase {
        case reading
        case analyzing
        case saved(String)
        case failed(String)

        var headline: String {
            switch self {
            case .reading: "Saving to Later…"
            case .analyzing: "Sending to Later…"
            case .saved: "Saved to Later"
            case .failed: "Couldn’t save to Later"
            }
        }

        var detail: String {
            switch self {
            case .reading: "Reading the screenshot"
            case .analyzing: "This will continue in the background"
            case .saved(let title): title
            case .failed(let message): message
            }
        }

        var isTerminal: Bool {
            switch self {
            case .reading, .analyzing: false
            case .saved, .failed: true
            }
        }
    }

    private let card = UIView()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let glyph = UIImageView()
    private let headlineLabel = UILabel()
    private let detailLabel = UILabel()
    private var hasStarted = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        preferredContentSize = CGSize(width: 320, height: 180)
        configureCard()
        apply(.reading)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !hasStarted else { return }
        hasStarted = true
        Task { await run() }
    }

    // MARK: - Flow

    @MainActor
    private func run() async {
        let store = ShareInboxStore()
        var record: ShareInboxRecord?

        do {
            let (data, image) = try await loadSharedImage()
            let fingerprint = ImageFingerprintGenerator().fingerprint(image)
            record = try store.enqueue(
                image,
                originalData: data,
                fingerprint: fingerprint
            )
            guard var saved = record else { throw ShareExtensionError.invalidImage }

            apply(.analyzing)
            saved.lastError = nil
            try store.save(saved)
            try ShareAnalysisUploadManager.shared.upload(saved)

            apply(.saved("We’ll notify you when it’s ready"))
            try? await Task.sleep(for: .milliseconds(350))
            finish()
        } catch {
            // Once the image is on disk the screenshot is never lost: the app retries
            // the analysis the next time it runs. Only the immediacy is given up.
            let isQueued = record != nil
            if var queued = record {
                queued.lastError = error.localizedDescription
                try? store.save(queued)
            }
            apply(.failed(isQueued ? "Queued—Later will retry when opened." : error.localizedDescription))
            try? await Task.sleep(for: .milliseconds(isQueued ? 900 : 1400))
            if isQueued {
                finish()
            } else {
                cancel(with: error)
            }
        }
    }

    private func loadSharedImage() async throws -> (Data, UIImage) {
        let attachments = (extensionContext?.inputItems ?? [])
            .compactMap { $0 as? NSExtensionItem }
            .flatMap { $0.attachments ?? [] }
        guard let provider = attachments.first(where: {
                  $0.hasItemConformingToTypeIdentifier(UTType.image.identifier)
              }) else {
            throw ShareExtensionError.missingImage
        }

        let data: Data = try await withCheckedThrowingContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, error in
                if let data {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: error ?? ShareExtensionError.invalidImage)
                }
            }
        }
        guard let image = UIImage(data: data) else { throw ShareExtensionError.invalidImage }
        return (data, image)
    }

    private func finish() {
        extensionContext?.completeRequest(returningItems: nil)
    }

    private func cancel(with error: Error) {
        extensionContext?.cancelRequest(withError: error)
    }

    // MARK: - Presentation

    private func configureCard() {
        card.backgroundColor = .clear
        card.layer.cornerRadius = 22
        card.layer.cornerCurve = .continuous
        card.clipsToBounds = true
        card.translatesAutoresizingMaskIntoConstraints = false

        let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemThickMaterial))
        blur.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(blur)

        glyph.contentMode = .scaleAspectFit
        glyph.tintColor = .systemGreen
        glyph.isHidden = true
        glyph.setContentHuggingPriority(.required, for: .horizontal)

        spinner.startAnimating()
        spinner.setContentHuggingPriority(.required, for: .horizontal)

        headlineLabel.font = .preferredFont(forTextStyle: .headline)
        headlineLabel.adjustsFontForContentSizeCategory = true
        headlineLabel.numberOfLines = 1

        detailLabel.font = .preferredFont(forTextStyle: .subheadline)
        detailLabel.adjustsFontForContentSizeCategory = true
        detailLabel.textColor = .secondaryLabel
        detailLabel.numberOfLines = 2

        let text = UIStackView(arrangedSubviews: [headlineLabel, detailLabel])
        text.axis = .vertical
        text.spacing = 3

        let indicator = UIView()
        indicator.translatesAutoresizingMaskIntoConstraints = false
        indicator.addSubview(spinner)
        indicator.addSubview(glyph)
        spinner.translatesAutoresizingMaskIntoConstraints = false
        glyph.translatesAutoresizingMaskIntoConstraints = false

        let row = UIStackView(arrangedSubviews: [indicator, text])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 14
        row.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(row)

        view.addSubview(card)
        NSLayoutConstraint.activate([
            blur.topAnchor.constraint(equalTo: card.topAnchor),
            blur.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            blur.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            blur.trailingAnchor.constraint(equalTo: card.trailingAnchor),

            indicator.widthAnchor.constraint(equalToConstant: 26),
            indicator.heightAnchor.constraint(equalToConstant: 26),
            spinner.centerXAnchor.constraint(equalTo: indicator.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: indicator.centerYAnchor),
            glyph.centerXAnchor.constraint(equalTo: indicator.centerXAnchor),
            glyph.centerYAnchor.constraint(equalTo: indicator.centerYAnchor),
            glyph.widthAnchor.constraint(equalToConstant: 26),
            glyph.heightAnchor.constraint(equalToConstant: 26),

            row.topAnchor.constraint(equalTo: card.topAnchor, constant: 20),
            row.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -20),
            row.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 20),
            row.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -20),

            card.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            card.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            card.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
            card.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24),
            card.widthAnchor.constraint(lessThanOrEqualToConstant: 360)
        ])
    }

    private func apply(_ phase: Phase) {
        headlineLabel.text = phase.headline
        detailLabel.text = phase.detail

        guard phase.isTerminal else { return }
        spinner.stopAnimating()
        spinner.isHidden = true
        glyph.isHidden = false

        switch phase {
        case .saved:
            glyph.image = UIImage(systemName: "checkmark.circle.fill")
            glyph.tintColor = .systemGreen
        case .failed:
            glyph.image = UIImage(systemName: "exclamationmark.circle.fill")
            glyph.tintColor = .systemOrange
        case .reading, .analyzing:
            break
        }

        UIView.transition(with: card, duration: 0.2, options: .transitionCrossDissolve) {}
    }
}

private enum ShareExtensionError: LocalizedError {
    case missingImage
    case invalidImage

    var errorDescription: String? {
        switch self {
        case .missingImage: "Choose a screenshot or image to send to Later."
        case .invalidImage: "Later couldn’t read that image."
        }
    }
}
