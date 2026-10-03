import AVFoundation
import UIKit
import UniformTypeIdentifiers
import UserNotifications

final class OunjeShareViewController: UIViewController {
    // Uploads are owned by iOS from the start, so closing the share sheet does
    // not cancel a handoff still waiting for the API or connectivity.
    private var backgroundSubmitSession: URLSession?
    private var backgroundSubmitDelegate: ShareImportUploadDelegate?
    private var pendingEnvelope: SharedRecipeImportEnvelope?
    private var retrySubmission = false
    private let modalCard = UIView()
    private let stateIconContainer = UIView()
    private let stateIcon = UIImageView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let previewLabel = UILabel()
    private let doneButton = UIButton(type: .system)
    private let activityIndicator = UIActivityIndicatorView(style: .medium)
    private var doneButtonHeightConstraint: NSLayoutConstraint?
    private var doneButtonTopConstraint: NSLayoutConstraint?

    private var shareDraftSummary = ""
    private var providerCount = 0
    private var loadSummaryTask: Task<Void, Never>?
    private var submitTask: Task<Void, Never>?
    private var didStartAutomaticSubmit = false

    override func viewDidLoad() {
        super.viewDidLoad()
        configureUI()
        loadSummary()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        beginAutomaticSubmitIfNeeded()
    }

    deinit {
        loadSummaryTask?.cancel()
        submitTask?.cancel()
    }

    private func configureUI() {
        preferredContentSize = CGSize(width: 360, height: 270)
        view.backgroundColor = UIColor.black.withAlphaComponent(0.58)

        modalCard.translatesAutoresizingMaskIntoConstraints = false
        modalCard.backgroundColor = UIColor(red: 0.075, green: 0.075, blue: 0.085, alpha: 1)
        modalCard.layer.cornerRadius = 26
        modalCard.layer.cornerCurve = .continuous
        modalCard.layer.borderWidth = 1
        modalCard.layer.borderColor = UIColor.white.withAlphaComponent(0.09).cgColor

        stateIconContainer.translatesAutoresizingMaskIntoConstraints = false
        stateIconContainer.backgroundColor = UIColor.white.withAlphaComponent(0.08)
        stateIconContainer.layer.cornerRadius = 24
        stateIconContainer.layer.cornerCurve = .continuous

        stateIcon.translatesAutoresizingMaskIntoConstraints = false
        stateIcon.image = UIImage(systemName: "paperplane.fill")
        stateIcon.tintColor = UIColor(white: 0.94, alpha: 1)
        stateIcon.contentMode = .scaleAspectFit

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.text = "Sharing recipe to Ounje"
        titleLabel.font = .systemFont(ofSize: 21, weight: .bold)
        titleLabel.textColor = UIColor(white: 0.97, alpha: 1)
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 2

        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.text = "Sending it securely in the background."
        subtitleLabel.font = .systemFont(ofSize: 14, weight: .medium)
        subtitleLabel.textColor = UIColor(white: 0.7, alpha: 1)
        subtitleLabel.textAlignment = .center
        subtitleLabel.numberOfLines = 0

        previewLabel.translatesAutoresizingMaskIntoConstraints = false
        previewLabel.font = .systemFont(ofSize: 13, weight: .medium)
        previewLabel.textColor = UIColor(white: 0.62, alpha: 1)
        previewLabel.textAlignment = .center
        previewLabel.numberOfLines = 3
        previewLabel.isHidden = true

        activityIndicator.translatesAutoresizingMaskIntoConstraints = false
        activityIndicator.hidesWhenStopped = true
        activityIndicator.color = UIColor(white: 0.94, alpha: 1)

        doneButton.translatesAutoresizingMaskIntoConstraints = false
        configurePrimaryButton(
            doneButton,
            title: "Done",
            tint: UIColor(white: 0.96, alpha: 1),
            background: UIColor.white.withAlphaComponent(0.1)
        )
        doneButton.isHidden = true
        doneButton.isEnabled = false
        doneButton.addTarget(self, action: #selector(handleDoneTap), for: .touchUpInside)

        view.addSubview(modalCard)
        modalCard.addSubview(stateIconContainer)
        stateIconContainer.addSubview(stateIcon)
        stateIconContainer.addSubview(activityIndicator)
        [titleLabel, subtitleLabel, previewLabel, doneButton].forEach(modalCard.addSubview)

        let cardWidthConstraint = modalCard.widthAnchor.constraint(equalTo: view.widthAnchor, constant: -48)
        cardWidthConstraint.priority = .defaultHigh
        let collapsedDoneButtonHeight = doneButton.heightAnchor.constraint(equalToConstant: 0)
        let collapsedDoneButtonTop = doneButton.topAnchor.constraint(equalTo: previewLabel.bottomAnchor)
        doneButtonHeightConstraint = collapsedDoneButtonHeight
        doneButtonTopConstraint = collapsedDoneButtonTop

        NSLayoutConstraint.activate([
            modalCard.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            modalCard.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            modalCard.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
            modalCard.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24),
            modalCard.widthAnchor.constraint(lessThanOrEqualToConstant: 340),
            cardWidthConstraint,

            stateIconContainer.topAnchor.constraint(equalTo: modalCard.topAnchor, constant: 24),
            stateIconContainer.centerXAnchor.constraint(equalTo: modalCard.centerXAnchor),
            stateIconContainer.widthAnchor.constraint(equalToConstant: 48),
            stateIconContainer.heightAnchor.constraint(equalToConstant: 48),

            stateIcon.centerXAnchor.constraint(equalTo: stateIconContainer.centerXAnchor),
            stateIcon.centerYAnchor.constraint(equalTo: stateIconContainer.centerYAnchor),
            stateIcon.widthAnchor.constraint(equalToConstant: 21),
            stateIcon.heightAnchor.constraint(equalToConstant: 21),

            activityIndicator.centerXAnchor.constraint(equalTo: stateIconContainer.centerXAnchor),
            activityIndicator.centerYAnchor.constraint(equalTo: stateIconContainer.centerYAnchor),

            titleLabel.leadingAnchor.constraint(equalTo: modalCard.leadingAnchor, constant: 22),
            titleLabel.trailingAnchor.constraint(equalTo: modalCard.trailingAnchor, constant: -22),
            titleLabel.topAnchor.constraint(equalTo: stateIconContainer.bottomAnchor, constant: 16),

            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 7),

            previewLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            previewLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            previewLabel.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 12),

            doneButton.leadingAnchor.constraint(equalTo: modalCard.leadingAnchor, constant: 20),
            doneButton.trailingAnchor.constraint(equalTo: modalCard.trailingAnchor, constant: -20),
            collapsedDoneButtonTop,
            doneButton.bottomAnchor.constraint(equalTo: modalCard.bottomAnchor, constant: -20),
            collapsedDoneButtonHeight,
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

    private func setDoneButtonVisible(_ visible: Bool) {
        doneButton.isHidden = !visible
        doneButtonHeightConstraint?.constant = visible ? 48 : 0
        doneButtonTopConstraint?.constant = visible ? 18 : 0
    }

    private func loadSummary() {
        loadSummaryTask = Task { [weak self] in
            guard let self else { return }
            let draft = await self.buildSummary()
            await MainActor.run {
                self.shareDraftSummary = draft.summary
                self.providerCount = draft.providerCount
                let currentTitle = self.titleLabel.text ?? ""
                if currentTitle != "Added" && currentTitle != "Couldn’t send to Ounje" {
                    self.previewLabel.text = draft.summary
                }
            }
        }
    }

    private func beginAutomaticSubmitIfNeeded() {
        guard !didStartAutomaticSubmit else { return }
        didStartAutomaticSubmit = true
        submit(targetState: "saved")
    }

    @objc private func handleDoneTap() {
        if retrySubmission {
            submit(targetState: pendingEnvelope?.targetState ?? "saved")
        } else {
            extensionContext?.completeRequest(returningItems: nil)
        }
    }

    private func submit(targetState: String) {
        setDoneButtonVisible(false)
        toggleBusy(true)
        titleLabel.text = "Sharing recipe to Ounje"
        subtitleLabel.text = "Sending it securely in the background."
        previewLabel.isHidden = true
        submitTask = Task { [weak self] in
            guard let self else { return }
            do {
                let envelope: SharedRecipeImportEnvelope
                if let pendingEnvelope = self.pendingEnvelope {
                    envelope = pendingEnvelope
                } else {
                    envelope = try await self.captureEnvelope(targetState: targetState)
                    self.pendingEnvelope = envelope
                }
                try SharedRecipeImportInbox.write(envelope)

                if let authSession = self.sharedAuthSession(), authSession.hasBackendAuthorization {
                    // A file-backed background task survives extension termination.
                    // Never report "Added" until its response includes a server job.
                    let submittingEnvelope = self.envelopeForSubmission(envelope)
                    try SharedRecipeImportInbox.update(submittingEnvelope)
                    self.pendingEnvelope = submittingEnvelope
                    try await self.scheduleBackgroundBackendSubmit(submittingEnvelope, authSession: authSession)
                    self.titleLabel.text = "Sharing recipe to Ounje"
                    self.subtitleLabel.text = "You can close this. Ounje will keep sending it in the background."
                    self.doneButton.setTitle("Done", for: .normal)
                    self.setDoneButtonVisible(true)
                    self.doneButton.isEnabled = true
                    self.retrySubmission = false
                    return
                }

                await MainActor.run {
                    self.showSetupRequiredState()
                }
            } catch {
                self.showSubmissionFailure(error)
            }
        }
    }

    private func scheduleBackgroundBackendSubmit(
        _ envelope: SharedRecipeImportEnvelope,
        authSession: SharedAuthSession
    ) async throws {
        let attachments = try await makeRecipeImportAttachmentPayloads(from: envelope.attachments)
        let sourceText = envelope.resolvedSourceText
        let body = try JSONEncoder().encode(
            RecipeImportRequestPayload(
                userID: authSession.userID,
                sourceURL: envelope.sourceURLString,
                sourceText: sourceText,
                accessToken: authSession.accessToken,
                targetState: envelope.targetState,
                attachments: attachments
            )
        )
        let bodyURL = try SharedRecipeImportInbox
            .directoryURL(for: envelope.id)
            .appendingPathComponent("background-submit.json", isDirectory: false)
        try body.write(to: bodyURL, options: .atomic)

        guard authSession.hasBackendAuthorization else {
            throw URLError(.userAuthenticationRequired)
        }

        for baseURL in ImportSubmissionServer.candidateBaseURLs {
            guard let url = URL(string: "\(baseURL)/v1/recipe/imports") else { continue }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            applyBackendAuthorization(authSession, to: &request)
            request.setValue(authSession.userID, forHTTPHeaderField: "x-user-id")
            request.setValue(envelope.id, forHTTPHeaderField: "x-ounje-import-envelope-id")
            request.setValue(String(body.count), forHTTPHeaderField: "Content-Length")

            let configuration = URLSessionConfiguration.background(
                withIdentifier: "net.ounje.share-import.\(envelope.id).\(baseURL.hashValue.magnitude)"
            )
            configuration.sharedContainerIdentifier = SharedRecipeImportConstants.appGroupID
            configuration.sessionSendsLaunchEvents = true
            configuration.isDiscretionary = false
            configuration.waitsForConnectivity = true
            configuration.timeoutIntervalForRequest = 90
            configuration.timeoutIntervalForResource = 10 * 60

            let delegate = ShareImportUploadDelegate { [weak self] result in
                guard let self else { return }
                switch result {
                case .success(let response):
                    do {
                        try SharedRecipeImportInbox.update(self.reconciledEnvelope(envelope, response: response))
                    } catch {
                        // The durable server job still exists; the app's server queue
                        // reconciliation can recover if the local inbox write fails.
                        print("[ShareImport] Could not save server acknowledgement:", error.localizedDescription)
                    }
                    Task { await Self.sendQueuedNotificationIfAllowed(for: envelope) }
                    self.showSentStateAndComplete()
                case .failure(let error):
                    self.showSubmissionFailure(error)
                }
            }
            let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: .main)
            self.backgroundSubmitDelegate = delegate
            self.backgroundSubmitSession = session
            let task = session.uploadTask(with: request, fromFile: bodyURL)
            task.taskDescription = envelope.id
            task.resume()
            return
        }

        throw URLError(.badURL)
    }

    private func showSubmissionFailure(_ error: Error) {
        toggleBusy(false)
        stateIcon.image = UIImage(systemName: "exclamationmark")
        titleLabel.text = "Couldn’t send to Ounje"
        subtitleLabel.text = "Your share is saved on this device. Retry here to send it to Ounje."
        previewLabel.text = error.localizedDescription
        previewLabel.isHidden = false
        retrySubmission = true
        doneButton.setTitle("Retry", for: .normal)
        setDoneButtonVisible(true)
        doneButton.isEnabled = true
    }

    private func toggleBusy(_ busy: Bool) {
        doneButton.isEnabled = !busy
        if busy {
            stateIcon.isHidden = true
            activityIndicator.startAnimating()
        } else {
            activityIndicator.stopAnimating()
            stateIcon.isHidden = false
        }
    }

    private func showSentStateAndComplete() {
        toggleBusy(false)
        stateIcon.image = UIImage(systemName: "checkmark")
        titleLabel.text = "Added"
        subtitleLabel.text = "Ounje is working in the background."
        previewLabel.isHidden = true
        setDoneButtonVisible(true)
        doneButton.isEnabled = true

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.extensionContext?.completeRequest(returningItems: nil)
        }
    }

    private func showSetupRequiredState() {
        toggleBusy(false)
        stateIcon.image = UIImage(systemName: "iphone.and.arrow.forward")
        titleLabel.text = "Open Ounje once"
        subtitleLabel.text = "Ounje needs to finish share setup before it can import in the background."
        previewLabel.text = "Open Ounje once, then share this recipe again."
        previewLabel.isHidden = false
        setDoneButtonVisible(true)
        doneButton.isEnabled = true
    }

    private static func sendQueuedNotificationIfAllowed(for envelope: SharedRecipeImportEnvelope) async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional
                || settings.authorizationStatus == .ephemeral
        else {
            return
        }

        let content = UNMutableNotificationContent()
        content.title = "Import started"
        content.body = "Ounje is importing this recipe into your cookbook."
        content.sound = .default
        content.categoryIdentifier = "OUNJE_RECIPE_IMPORT"
        content.threadIdentifier = "recipe-import"
        content.userInfo = [
            "kind": "recipe_import_queued",
            "actionURL": "ounje://import-status",
            "action_url": "ounje://import-status",
            "deep_link": "ounje://import-status",
        ]

        let request = UNNotificationRequest(
            identifier: "recipe-import-queued-\(envelope.id)",
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        )
        try? await center.add(request)
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
            jobID: nil,
            targetState: targetState,
            sourceText: sourceText,
            sourceURLString: sourceURLString,
            canonicalSourceURLString: nil,
            sourceApp: nil,
            attachments: attachments,
            processingState: "queued",
            attemptCount: 0,
            lastAttemptAt: nil,
            serverSubmittedAt: nil,
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

    private func sharedAuthSession() -> SharedAuthSession? {
        guard let defaults = UserDefaults(suiteName: SharedRecipeImportConstants.appGroupID) else {
            return nil
        }
        defaults.synchronize()

        let decoder = JSONDecoder()
        if let data = defaults.data(forKey: SharedAuthSession.compactStorageKey),
           let session = try? decoder.decode(SharedAuthSession.self, from: data) {
            return session
        }

        if let data = defaults.data(forKey: SharedAuthSession.storageKey),
           let session = try? decoder.decode(SharedAuthSession.self, from: data) {
            return session
        }

        return nil
    }

    private func applyBackendAuthorization(_ authSession: SharedAuthSession, to request: inout URLRequest) {
        let shareAuthorization = authSession.shareImportAuthorization?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !shareAuthorization.isEmpty,
           authSession.shareImportAuthorizationExpiresAt.map({ $0 > Date() }) ?? false {
            request.setValue(shareAuthorization, forHTTPHeaderField: "x-ounje-share-authorization")
            return
        }

        let accessToken = authSession.accessToken?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !accessToken.isEmpty {
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }
    }

    private func envelopeForSubmission(_ envelope: SharedRecipeImportEnvelope) -> SharedRecipeImportEnvelope {
        SharedRecipeImportEnvelope(
            id: envelope.id,
            createdAt: envelope.createdAt,
            jobID: envelope.jobID,
            targetState: envelope.targetState,
            sourceText: envelope.sourceText,
            sourceURLString: envelope.sourceURLString,
            canonicalSourceURLString: envelope.canonicalSourceURLString,
            sourceApp: envelope.sourceApp,
            attachments: envelope.attachments,
            processingState: "submitted",
            attemptCount: (envelope.attemptCount ?? 0) + 1,
            lastAttemptAt: Date(),
            serverSubmittedAt: Date(),
            lastError: nil,
            updatedAt: Date()
        )
    }

    private func reconciledEnvelope(
        _ envelope: SharedRecipeImportEnvelope,
        response: RecipeImportResponse
    ) -> SharedRecipeImportEnvelope {
        let backendState = response.job.status
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let liveBackendStates = ["queued", "submitted", "retryable", "processing", "fetching", "parsing", "normalized"]
        let localState = liveBackendStates.contains(backendState) ? backendState : (backendState.isEmpty ? "queued" : backendState)
        return SharedRecipeImportEnvelope(
            id: envelope.id,
            createdAt: envelope.createdAt,
            jobID: response.job.id,
            targetState: envelope.targetState,
            sourceText: envelope.sourceText,
            sourceURLString: envelope.sourceURLString,
            canonicalSourceURLString: response.job.canonicalURL ?? response.job.sourceURL ?? envelope.canonicalSourceURLString,
            sourceApp: envelope.sourceApp,
            attachments: envelope.attachments,
            processingState: localState,
            attemptCount: max(envelope.attemptCount ?? 0, 1),
            lastAttemptAt: Date(),
            serverSubmittedAt: envelope.serverSubmittedAt ?? Date(),
            lastError: nil,
            updatedAt: Date()
        )
    }

    private func makeRecipeImportAttachmentPayloads(from attachments: [SharedRecipeImportAttachment]) async throws -> [RecipeImportAttachmentPayload] {
        var payloads: [RecipeImportAttachmentPayload] = []

        for attachment in attachments {
            let fileURL = try SharedRecipeImportInbox.absoluteURL(forRelativePath: attachment.relativePath)
            switch attachment.kind.lowercased() {
            case "image":
                let data = try Data(contentsOf: fileURL)
                payloads.append(
                    try makeRecipeImportImageAttachment(
                        from: data,
                        mimeType: attachment.mimeType,
                        fileName: attachment.fileName
                    )
                )
            case "video":
                payloads.append(
                    try await makeRecipeImportVideoAttachment(
                        from: fileURL,
                        mimeType: attachment.mimeType,
                        fileName: attachment.fileName
                    )
                )
            default:
                continue
            }
        }

        return payloads
    }

    private func copyMediaAttachment(
        from provider: NSItemProvider,
        contentType: UTType,
        envelopeID: String,
        mediaDirectory: URL
    ) async throws -> SharedRecipeImportAttachment? {
        let extensionName = contentType.preferredFilenameExtension ?? "bin"
        let fileName = UUID().uuidString + "." + extensionName
        let destinationURL = mediaDirectory.appendingPathComponent(fileName)
        guard try await copyFileRepresentation(from: provider, contentType: contentType, to: destinationURL) else {
            return nil
        }

        return SharedRecipeImportAttachment(
            id: UUID().uuidString,
            kind: contentType.conforms(to: .image) ? "image" : "video",
            fileName: fileName,
            relativePath: SharedRecipeImportInbox.relativeMediaPath(envelopeID: envelopeID, fileName: fileName),
            mimeType: contentType.preferredMIMEType,
            originalURLString: nil
        )
    }

    private func copyFileRepresentation(from provider: NSItemProvider, contentType: UTType, to destinationURL: URL) async throws -> Bool {
        let identifier = provider.registeredTypeIdentifiers.first {
            UTType($0)?.conforms(to: contentType) == true
        } ?? contentType.identifier

        return try await withCheckedThrowingContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: identifier) { url, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let url {
                    do {
                        try FileManager.default.copyItem(at: url, to: destinationURL)
                        continuation.resume(returning: true)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                } else {
                    continuation.resume(returning: false)
                }
            }
        }
    }

}

/// Handles acknowledgements while the share sheet is alive. After termination,
/// OunjeAppDelegate reconnects to the same session and handles its remaining events.
private final class ShareImportUploadDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private var responseData = Data()
    private let completion: (Result<RecipeImportResponse, Error>) -> Void

    init(completion: @escaping (Result<RecipeImportResponse, Error>) -> Void) {
        self.completion = completion
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        responseData.append(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        defer { session.finishTasksAndInvalidate() }
        if let error {
            completion(.failure(error))
            return
        }
        guard let response = task.response as? HTTPURLResponse,
              (200 ... 299).contains(response.statusCode) else {
            completion(.failure(URLError(.badServerResponse)))
            return
        }
        do {
            let response = try JSONDecoder().decode(RecipeImportResponse.self, from: responseData)
            guard !response.job.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw URLError(.badServerResponse)
            }
            completion(.success(response))
        } catch {
            completion(.failure(error))
        }
    }
}

private struct SharedAuthSession: Codable {
    static let storageKey = "agentic-auth-session-v1"
    static let compactStorageKey = "agentic-share-auth-session-v1"

    let userID: String
    let accessToken: String?
    let shareImportAuthorization: String?
    let shareImportAuthorizationExpiresAt: Date?

    var hasBackendAuthorization: Bool {
        let shareAuthorization = shareImportAuthorization?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !shareAuthorization.isEmpty,
           shareImportAuthorizationExpiresAt.map({ $0 > Date() }) ?? false {
            return true
        }
        return !(accessToken?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "").isEmpty
    }
}

private struct RecipeImportAttachmentPayload: Encodable {
    let kind: String
    let sourceURL: String?
    let dataURL: String?
    let mimeType: String?
    let fileName: String?
    let previewFrameURLs: [String]

    enum CodingKeys: String, CodingKey {
        case kind
        case sourceURL = "source_url"
        case dataURL = "data_url"
        case mimeType = "mime_type"
        case fileName = "file_name"
        case previewFrameURLs = "preview_frame_urls"
    }
}

private struct RecipeImportRequestPayload: Encodable {
    let userID: String?
    let sourceURL: String?
    let sourceText: String
    let accessToken: String?
    let targetState: String
    let attachments: [RecipeImportAttachmentPayload]
    let processInline: Bool = false

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case sourceURL = "source_url"
        case sourceText = "source_text"
        case accessToken = "access_token"
        case targetState = "target_state"
        case attachments
        case processInline = "process_inline"
    }
}

private struct RecipeImportResponse: Decodable {
    let job: RecipeImportJobPayload
}

private struct RecipeImportJobPayload: Decodable {
    let id: String
    let status: String
    let sourceURL: String?
    let canonicalURL: String?

    enum CodingKeys: String, CodingKey {
        case id
        case status
        case sourceURL = "source_url"
        case canonicalURL = "canonical_url"
    }
}

private enum ImportSubmissionServer {
    static let productionBaseURL = "https://ounje-idbl.onrender.com"

    static var candidateBaseURLs: [String] {
        deduplicated(
            [
                productionBaseURL,
                explicitWorkerBaseURL,
                explicitPrimaryBaseURL
            ].compactMap { $0 }
        )
    }

    private static var explicitPrimaryBaseURL: String? {
#if DEBUG
        explicitBaseURL(hostKey: "OunjePrimaryServerHost", portKey: "OunjePrimaryServerPort", defaultPort: "8080")
#else
        nil
#endif
    }

    private static var explicitWorkerBaseURL: String? {
#if DEBUG
        explicitBaseURL(hostKey: "OunjeWorkerServerHost", portKey: "OunjeWorkerServerPort", defaultPort: "80")
            ?? explicitBaseURL(hostKey: "OunjeDevServerHost", portKey: "OunjeDevServerPort", defaultPort: "80")
#else
        nil
#endif
    }

    private static func explicitBaseURL(hostKey: String, portKey: String, defaultPort: String) -> String? {
        guard
            let rawHost = Bundle.main.object(forInfoDictionaryKey: hostKey) as? String
        else {
            return nil
        }

        let host = rawHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { return nil }

        let configuredPort = (Bundle.main.object(forInfoDictionaryKey: portKey) as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let port = (configuredPort?.isEmpty == false ? configuredPort! : defaultPort)

        if host.contains("://") {
            guard var components = URLComponents(string: host) else {
                return host
            }
            if components.port == nil, !port.isEmpty {
                components.port = Int(port)
            }
            return components.string ?? host
        }

        return "http://\(host):\(port)"
    }

    private static func deduplicated(_ baseURLs: [String]) -> [String] {
        var uniqueBaseURLs: [String] = []
        for baseURL in baseURLs where !uniqueBaseURLs.contains(baseURL) {
            uniqueBaseURLs.append(baseURL)
        }
        return uniqueBaseURLs
    }
}

private func makeRecipeImportImageAttachment(
    from data: Data,
    mimeType: String?,
    fileName: String
) throws -> RecipeImportAttachmentPayload {
    guard let image = UIImage(data: data) else {
        throw NSError(domain: "OunjeShareExtension", code: 1)
    }

    let prepared = image.ounjeResized(maxDimension: 1600)
    let jpegData = prepared.jpegData(compressionQuality: 0.82) ?? data
    return RecipeImportAttachmentPayload(
        kind: "image",
        sourceURL: nil,
        dataURL: "data:image/jpeg;base64,\(jpegData.base64EncodedString())",
        mimeType: mimeType ?? "image/jpeg",
        fileName: fileName,
        previewFrameURLs: []
    )
}

private func makeRecipeImportVideoAttachment(
    from fileURL: URL,
    mimeType: String?,
    fileName: String
) async throws -> RecipeImportAttachmentPayload {
    let byteLimit = 25 * 1024 * 1024
    let data = try Data(contentsOf: fileURL)
    guard data.count <= byteLimit else {
        throw NSError(domain: "OunjeShareExtension", code: 2)
    }

    let asset = AVAsset(url: fileURL)
    let duration = try await asset.load(.duration)
    let durationSeconds = max(CMTimeGetSeconds(duration), 0.6)
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    generator.maximumSize = CGSize(width: 1200, height: 1200)

    let fractions: [Double] = durationSeconds < 1.2 ? [0.3, 0.7] : [0.18, 0.5, 0.82]
    var frameDataURLs: [String] = []
    for fraction in fractions {
        let second = max(0.05, min(durationSeconds * fraction, max(durationSeconds - 0.05, 0.05)))
        let time = CMTime(seconds: second, preferredTimescale: 600)
        guard let cgImage = try? generator.copyCGImage(at: time, actualTime: nil) else {
            continue
        }
        let image = UIImage(cgImage: cgImage).ounjeResized(maxDimension: 1200)
        guard let frameData = image.jpegData(compressionQuality: 0.78) else {
            continue
        }
        frameDataURLs.append("data:image/jpeg;base64,\(frameData.base64EncodedString())")
    }

    return RecipeImportAttachmentPayload(
        kind: "video",
        sourceURL: nil,
        dataURL: nil,
        mimeType: mimeType ?? "video/quicktime",
        fileName: fileName,
        previewFrameURLs: frameDataURLs
    )
}

private extension UIImage {
    func ounjeResized(maxDimension: CGFloat) -> UIImage {
        let largestDimension = max(size.width, size.height)
        guard largestDimension > maxDimension, largestDimension > 0 else {
            return self
        }

        let scaleRatio = maxDimension / largestDimension
        let targetSize = CGSize(
            width: floor(size.width * scaleRatio),
            height: floor(size.height * scaleRatio)
        )

        let renderer = UIGraphicsImageRenderer(size: targetSize)
        return renderer.image { _ in
            draw(in: CGRect(origin: .zero, size: targetSize))
        }
    }
}
