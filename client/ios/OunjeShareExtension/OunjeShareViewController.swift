import AVFoundation
import UIKit
import UniformTypeIdentifiers
import UserNotifications

final class OunjeShareViewController: UIViewController {
    // The extension stays alive through this await, so the FOREGROUND POST reliably creates
    // the job on the server before the share sheet closes — that's what makes imports land
    // without ever opening the app. The API responds in ~1-4s; this generous ceiling only
    // bounds the rare slow-network tail. (Was 6s, which the tail tripped — and the fallback
    // is a fire-and-forget background upload that iOS drops when it kills the extension, so
    // a tripped timeout silently lost the import.)
    private static let foregroundBackendSubmitTimeout: TimeInterval = 20
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let previewLabel = UILabel()
    private let doneButton = UIButton(type: .system)
    private let activityIndicator = UIActivityIndicatorView(style: .medium)

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
        view.backgroundColor = UIColor(red: 0.06, green: 0.06, blue: 0.07, alpha: 1)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.text = "Adding to Ounje"
        titleLabel.font = .systemFont(ofSize: 26, weight: .bold)
        titleLabel.textColor = UIColor(white: 0.97, alpha: 1)

        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.text = "Ounje is sending this to your cookbook."
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

        doneButton.translatesAutoresizingMaskIntoConstraints = false
        configurePrimaryButton(doneButton, title: "Done", tint: .white, background: UIColor(red: 0.15, green: 0.46, blue: 0.31, alpha: 1))
        doneButton.alpha = 0
        doneButton.isEnabled = false
        doneButton.addTarget(self, action: #selector(handleDoneTap), for: .touchUpInside)

        let buttonStack = UIStackView(arrangedSubviews: [doneButton])
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

            doneButton.heightAnchor.constraint(equalToConstant: 54),
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
        loadSummaryTask = Task { [weak self] in
            guard let self else { return }
            let draft = await self.buildSummary()
            await MainActor.run {
                self.shareDraftSummary = draft.summary
                self.providerCount = draft.providerCount
                let currentTitle = self.titleLabel.text ?? ""
                if currentTitle != "Added" && currentTitle != "Couldn’t send" {
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
        extensionContext?.completeRequest(returningItems: nil)
    }

    private func submit(targetState: String) {
        toggleBusy(true)
        titleLabel.text = "Sending to Ounje"
        subtitleLabel.text = "Ounje is adding this to your cookbook."
        submitTask = Task { [weak self] in
            guard let self else { return }
            do {
                let envelope = try await self.captureEnvelope(targetState: targetState)
                try SharedRecipeImportInbox.write(envelope)
                await Self.sendQueuedNotificationIfAllowed(for: envelope)

                if let authSession = self.sharedAuthSession() {
                    var backendJobCreated = false

                    if envelope.attachments.isEmpty {
                        do {
                            let response = try await self.submitEnvelopeToBackend(
                                envelope,
                                authSession: authSession,
                                timeoutInterval: Self.foregroundBackendSubmitTimeout
                            )
                            try? SharedRecipeImportInbox.update(
                                self.reconciledEnvelope(envelope, response: response)
                            )
                            backendJobCreated = true
                        } catch {
                            backendJobCreated = false
                        }
                    }

                    if !backendJobCreated {
                        // Foreground submit failed (slow network, expired token, or a
                        // media-only share we can't POST synchronously). Fire the background
                        // upload as a best effort, but LEAVE the envelope "queued" (don't mark
                        // it "submitted"): the durable local copy then gets cleanly re-driven
                        // the next time the app opens, instead of the stale watchdog stranding
                        // it as "could not be matched to a server job". The server dedupes by
                        // source URL, so a later re-send can never create a duplicate.
                        try? await self.scheduleBackgroundBackendSubmit(envelope, authSession: authSession)
                    }

                    await MainActor.run {
                        self.showSentStateAndComplete()
                    }
                    return
                }

                await MainActor.run {
                    self.showSetupRequiredState()
                }
            } catch {
                await MainActor.run {
                    self.toggleBusy(false)
                    self.titleLabel.text = "Couldn’t send"
                    self.subtitleLabel.text = "Try sharing the link itself or a shorter clip."
                    self.previewLabel.text = "We couldn’t pull that share cleanly. Try sharing the link itself or a shorter clip."
                    self.doneButton.alpha = 1
                    self.doneButton.isEnabled = true
                }
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
            configuration.timeoutIntervalForRequest = 30
            configuration.timeoutIntervalForResource = 10 * 60

            let session = URLSession(configuration: configuration)
            let task = session.uploadTask(with: request, fromFile: bodyURL)
            task.taskDescription = envelope.id
            task.resume()
            session.finishTasksAndInvalidate()
            return
        }

        throw URLError(.badURL)
    }

    private func toggleBusy(_ busy: Bool) {
        doneButton.isEnabled = !busy
        if busy {
            activityIndicator.startAnimating()
        } else {
            activityIndicator.stopAnimating()
        }
    }

    private func showSentStateAndComplete() {
        toggleBusy(false)
        titleLabel.text = "Added"
        subtitleLabel.text = "Ounje is working in the background."
        previewLabel.text = "Added. Ounje is working."
        doneButton.alpha = 1
        doneButton.isEnabled = true

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.extensionContext?.completeRequest(returningItems: nil)
        }
    }

    private func showSetupRequiredState() {
        toggleBusy(false)
        titleLabel.text = "Open Ounje once"
        subtitleLabel.text = "Ounje needs to finish share setup before it can import in the background."
        previewLabel.text = "Open Ounje once, then share this recipe again."
        doneButton.alpha = 1
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

    private func submitEnvelopeToBackend(
        _ envelope: SharedRecipeImportEnvelope,
        authSession: SharedAuthSession,
        timeoutInterval: TimeInterval = 90
    ) async throws -> RecipeImportResponse {
        guard authSession.hasBackendAuthorization else {
            throw URLError(.userAuthenticationRequired)
        }

        let attachments = try await makeRecipeImportAttachmentPayloads(from: envelope.attachments)
        let sourceText = envelope.resolvedSourceText

        var lastError: Error?
        for baseURL in ImportSubmissionServer.candidateBaseURLs {
            do {
                return try await submitEnvelopeToBackend(
                    baseURL: baseURL,
                    envelope: envelope,
                    authSession: authSession,
                    sourceText: sourceText,
                    attachments: attachments,
                    timeoutInterval: timeoutInterval
                )
            } catch {
                lastError = error
            }
        }

        throw lastError ?? URLError(.badServerResponse)
    }

    private func submitEnvelopeToBackend(
        baseURL: String,
        envelope: SharedRecipeImportEnvelope,
        authSession: SharedAuthSession,
        sourceText: String,
        attachments: [RecipeImportAttachmentPayload],
        timeoutInterval: TimeInterval = 90
    ) async throws -> RecipeImportResponse {
        guard let url = URL(string: "\(baseURL)/v1/recipe/imports") else {
            throw URLError(.badURL)
        }
        guard authSession.hasBackendAuthorization else {
            throw URLError(.userAuthenticationRequired)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeoutInterval
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyBackendAuthorization(authSession, to: &request)
        request.setValue(authSession.userID, forHTTPHeaderField: "x-user-id")
        request.setValue(envelope.id, forHTTPHeaderField: "x-ounje-import-envelope-id")
        request.httpBody = try JSONEncoder().encode(
            RecipeImportRequestPayload(
                userID: authSession.userID,
                sourceURL: envelope.sourceURLString,
                sourceText: sourceText,
                accessToken: authSession.accessToken,
                targetState: envelope.targetState,
                attachments: attachments
            )
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        guard (200 ... 299).contains(httpResponse.statusCode) else {
            throw URLError(.badServerResponse)
        }

        return try JSONDecoder().decode(RecipeImportResponse.self, from: data)
    }

    private func reconciledEnvelope(
        _ envelope: SharedRecipeImportEnvelope,
        response: RecipeImportResponse
    ) -> SharedRecipeImportEnvelope {
        let backendState = response.job.status
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let liveBackendStates = ["queued", "submitted", "retryable", "processing", "fetching", "parsing", "normalized"]
        let localState = liveBackendStates.contains(backendState) ? backendState : "queued"
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
