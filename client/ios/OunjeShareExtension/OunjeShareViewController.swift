import UIKit
import UniformTypeIdentifiers

final class OunjeShareViewController: UIViewController {
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let previewLabel = UILabel()
    private let saveButton = UIButton(type: .system)
    private let prepButton = UIButton(type: .system)
    private let cancelButton = UIButton(type: .system)
    private let activityIndicator = UIActivityIndicatorView(style: .medium)

    private var shareDraftSummary = ""
    private var providerCount = 0
    private var currentTask: Task<Void, Never>?

    override func viewDidLoad() {
        super.viewDidLoad()
        configureUI()
        loadSummary()
    }

    deinit {
        currentTask?.cancel()
    }

    private func configureUI() {
        view.backgroundColor = UIColor(red: 0.06, green: 0.06, blue: 0.07, alpha: 1)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.text = "Send to Ounje"
        titleLabel.font = .systemFont(ofSize: 26, weight: .bold)
        titleLabel.textColor = UIColor(white: 0.97, alpha: 1)

        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.text = "We’ll pull the recipe in, normalize it, and drop it into your cookbook or next prep."
        subtitleLabel.font = .systemFont(ofSize: 14, weight: .medium)
        subtitleLabel.textColor = UIColor(white: 0.7, alpha: 1)
        subtitleLabel.numberOfLines = 0

        previewLabel.translatesAutoresizingMaskIntoConstraints = false
        previewLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        previewLabel.textColor = UIColor(white: 0.92, alpha: 1)
        previewLabel.numberOfLines = 3

        activityIndicator.translatesAutoresizingMaskIntoConstraints = false
        activityIndicator.hidesWhenStopped = true
        activityIndicator.color = UIColor(red: 0.3, green: 0.74, blue: 0.53, alpha: 1)

        let card = UIView()
        card.translatesAutoresizingMaskIntoConstraints = false
        card.backgroundColor = UIColor(white: 0.13, alpha: 1)
        card.layer.cornerRadius = 24
        card.layer.cornerCurve = .continuous

        [titleLabel, subtitleLabel, previewLabel, activityIndicator].forEach(card.addSubview)

        saveButton.translatesAutoresizingMaskIntoConstraints = false
        prepButton.translatesAutoresizingMaskIntoConstraints = false
        cancelButton.translatesAutoresizingMaskIntoConstraints = false

        configurePrimaryButton(saveButton, title: "Save to Cookbook", tint: UIColor(red: 0.94, green: 0.9, blue: 0.82, alpha: 1), background: UIColor(red: 0.18, green: 0.18, blue: 0.2, alpha: 1))
        configurePrimaryButton(prepButton, title: "Add to Next Prep", tint: .white, background: UIColor(red: 0.15, green: 0.46, blue: 0.31, alpha: 1))

        cancelButton.setTitle("Cancel", for: .normal)
        cancelButton.setTitleColor(UIColor(white: 0.7, alpha: 1), for: .normal)
        cancelButton.titleLabel?.font = .systemFont(ofSize: 15, weight: .medium)

        saveButton.addTarget(self, action: #selector(handleSaveTap), for: .touchUpInside)
        prepButton.addTarget(self, action: #selector(handlePrepTap), for: .touchUpInside)
        cancelButton.addTarget(self, action: #selector(handleCancelTap), for: .touchUpInside)

        let buttonStack = UIStackView(arrangedSubviews: [saveButton, prepButton, cancelButton])
        buttonStack.translatesAutoresizingMaskIntoConstraints = false
        buttonStack.axis = .vertical
        buttonStack.spacing = 12

        view.addSubview(card)
        view.addSubview(buttonStack)

        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            card.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            card.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 18),

            titleLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 18),
            titleLabel.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -18),
            titleLabel.topAnchor.constraint(equalTo: card.topAnchor, constant: 18),

            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),

            previewLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            previewLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            previewLabel.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 18),
            previewLabel.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -18),

            activityIndicator.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            activityIndicator.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),

            buttonStack.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            buttonStack.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            buttonStack.topAnchor.constraint(equalTo: card.bottomAnchor, constant: 18),
            buttonStack.bottomAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -18),

            saveButton.heightAnchor.constraint(equalToConstant: 54),
            prepButton.heightAnchor.constraint(equalToConstant: 54),
            cancelButton.heightAnchor.constraint(equalToConstant: 44),
        ])
    }

    private func configurePrimaryButton(_ button: UIButton, title: String, tint: UIColor, background: UIColor) {
        button.setTitle(title, for: .normal)
        button.setTitleColor(tint, for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
        button.backgroundColor = background
        button.layer.cornerRadius = 20
        button.layer.cornerCurve = .continuous
    }

    private func loadSummary() {
        currentTask = Task { [weak self] in
            guard let self else { return }
            let draft = await self.buildSummary()
            await MainActor.run {
                self.shareDraftSummary = draft.summary
                self.providerCount = draft.providerCount
                self.previewLabel.text = draft.summary
            }
        }
    }

    @objc private func handleSaveTap() {
        submit(targetState: "saved")
    }

    @objc private func handlePrepTap() {
        submit(targetState: "prepped")
    }

    @objc private func handleCancelTap() {
        extensionContext?.completeRequest(returningItems: nil)
    }

    private func submit(targetState: String) {
        toggleBusy(true)
        currentTask = Task { [weak self] in
            guard let self else { return }
            do {
                let envelope = try await self.captureEnvelope(targetState: targetState)
                try SharedRecipeImportInbox.write(envelope)
                await MainActor.run {
                    self.openContainingApp(for: envelope.id)
                    self.extensionContext?.completeRequest(returningItems: nil)
                }
            } catch {
                await MainActor.run {
                    self.toggleBusy(false)
                    self.previewLabel.text = "We couldn’t pull that share cleanly. Try sharing the link itself or a shorter clip."
                }
            }
        }
    }

    private func toggleBusy(_ busy: Bool) {
        saveButton.isEnabled = !busy
        prepButton.isEnabled = !busy
        cancelButton.isEnabled = !busy
        if busy {
            activityIndicator.startAnimating()
        } else {
            activityIndicator.stopAnimating()
        }
    }

    private func buildSummary() async -> (summary: String, providerCount: Int) {
        let providers = itemProviders()
        var bits: [String] = []

        for provider in providers {
            if let url = try? await loadSharedURL(from: provider) {
                bits.append(url.absoluteString)
                break
            }
            if let text = try? await loadSharedText(from: provider), !text.isEmpty {
                bits.append(text)
                break
            }
        }

        let imageCount = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.image.identifier) }.count
        let videoCount = providers.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.movie.identifier)
                || $0.hasItemConformingToTypeIdentifier(UTType.video.identifier)
        }.count

        if imageCount > 0 {
            bits.append(imageCount == 1 ? "1 image attached" : "\(imageCount) images attached")
        }
        if videoCount > 0 {
            bits.append(videoCount == 1 ? "1 short video attached" : "\(videoCount) short videos attached")
        }

        if bits.isEmpty {
            bits = ["We’ll grab the shared recipe and finish the import once Ounje opens."]
        }

        return (bits.joined(separator: "\n"), providers.count)
    }

    private func captureEnvelope(targetState: String) async throws -> SharedRecipeImportEnvelope {
        let envelopeID = UUID().uuidString
        let mediaDirectory = try SharedRecipeImportInbox.mediaDirectoryURL(for: envelopeID)
        let providers = itemProviders()

        var sourceText: String?
        var sourceURLString: String?
        var attachments: [SharedRecipeImportAttachment] = []

        for provider in providers {
            if sourceURLString == nil, let url = try? await loadSharedURL(from: provider) {
                sourceURLString = url.absoluteString
                continue
            }

            if sourceText == nil, let text = try? await loadSharedText(from: provider), !text.isEmpty {
                sourceText = text
            }

            if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier),
               let attachment = try? await copyMediaAttachment(
                from: provider,
                contentType: .image,
                envelopeID: envelopeID,
                mediaDirectory: mediaDirectory
               ) {
                attachments.append(attachment)
                continue
            }

            if provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) || provider.hasItemConformingToTypeIdentifier(UTType.video.identifier),
               let attachment = try? await copyMediaAttachment(
                from: provider,
                contentType: .movie,
                envelopeID: envelopeID,
                mediaDirectory: mediaDirectory
               ) {
                attachments.append(attachment)
            }
        }

        return SharedRecipeImportEnvelope(
            id: envelopeID,
            createdAt: Date(),
            targetState: targetState,
            sourceText: sourceText,
            sourceURLString: sourceURLString,
            sourceApp: nil,
            attachments: attachments,
            processingState: "queued",
            attemptCount: 0,
            lastAttemptAt: nil,
            lastError: nil,
            updatedAt: Date()
        )
    }

    private func itemProviders() -> [NSItemProvider] {
        (extensionContext?.inputItems as? [NSExtensionItem] ?? [])
            .flatMap { $0.attachments ?? [] }
    }

    private func loadSharedURL(from provider: NSItemProvider) async throws -> URL? {
        guard provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) else { return nil }
        return try await withCheckedThrowingContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { item, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                if let url = item as? URL {
                    continuation.resume(returning: url)
                } else if let string = item as? String, let url = URL(string: string) {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    private func loadSharedText(from provider: NSItemProvider) async throws -> String? {
        guard provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) else { return nil }
        return try await withCheckedThrowingContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { item, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                if let text = item as? String {
                    continuation.resume(returning: text.trimmingCharacters(in: .whitespacesAndNewlines))
                } else if let attributed = item as? NSAttributedString {
                    continuation.resume(returning: attributed.string.trimmingCharacters(in: .whitespacesAndNewlines))
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    private func copyMediaAttachment(
        from provider: NSItemProvider,
        contentType: UTType,
        envelopeID: String,
        mediaDirectory: URL
    ) async throws -> SharedRecipeImportAttachment? {
        let fileURL = try await loadFileRepresentation(from: provider, contentType: contentType)
        guard let fileURL else { return nil }

        let extensionName = fileURL.pathExtension.isEmpty
            ? (contentType.preferredFilenameExtension ?? "bin")
            : fileURL.pathExtension
        let fileName = UUID().uuidString + "." + extensionName
        let destinationURL = mediaDirectory.appendingPathComponent(fileName)

        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }
        try FileManager.default.copyItem(at: fileURL, to: destinationURL)

        return SharedRecipeImportAttachment(
            id: UUID().uuidString,
            kind: contentType.conforms(to: .image) ? "image" : "video",
            fileName: fileName,
            relativePath: SharedRecipeImportInbox.relativeMediaPath(envelopeID: envelopeID, fileName: fileName),
            mimeType: contentType.preferredMIMEType,
            originalURLString: nil
        )
    }

    private func loadFileRepresentation(from provider: NSItemProvider, contentType: UTType) async throws -> URL? {
        let identifier = provider.registeredTypeIdentifiers.first {
            UTType($0)?.conforms(to: contentType) == true
        } ?? contentType.identifier

        return try await withCheckedThrowingContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: identifier) { url, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: url)
                }
            }
        }
    }

    private func openContainingApp(for envelopeID: String) {
        guard let url = SharedRecipeImportInbox.handoffURL(for: envelopeID) else { return }
        let selector = NSSelectorFromString("openURL:")
        var responder: UIResponder? = self
        while let current = responder {
            if current.responds(to: selector) {
                _ = current.perform(selector, with: url)
                break
            }
            responder = current.next
        }
    }
}
