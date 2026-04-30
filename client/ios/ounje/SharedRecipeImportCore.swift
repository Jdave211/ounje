import Foundation

enum SharedRecipeImportConstants {
    static let appGroupID = "group.net.ounje.shared"
    static let handoffURLScheme = "net.ounje"
    static let handoffURLHost = "share-import"
    static let inboxDirectoryName = "SharedRecipeImports"
}

struct SharedRecipeImportAttachment: Codable, Identifiable, Hashable {
    let id: String
    let kind: String
    let fileName: String
    let relativePath: String
    let mimeType: String?
    let originalURLString: String?
}

struct SharedRecipeImportEnvelope: Codable, Identifiable, Hashable {
    let id: String
    let createdAt: Date
    let jobID: String?
    let targetState: String
    let sourceText: String?
    let sourceURLString: String?
    var canonicalSourceURLString: String?
    let sourceApp: String?
    let attachments: [SharedRecipeImportAttachment]
    let processingState: String?
    let attemptCount: Int?
    let lastAttemptAt: Date?
    let lastError: String?
    let updatedAt: Date?

    var resolvedSourceText: String {
        let sourceURLString = sourceURLString?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !sourceURLString.isEmpty { return sourceURLString }
        return sourceText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    var normalizedProcessingState: String {
        String(processingState ?? "queued").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    var queueStatusLabel: String {
        switch normalizedProcessingState {
        case "failed":
            return "Retry needed"
        case "queued":
            return (attemptCount ?? 0) > 0 ? "Queued on server" : "Queued"
        case "processing":
            return "Importing"
        case "fetching":
            return "Fetching"
        case "parsing":
            return "Parsing"
        case "normalized":
            return "Saving"
        case "saved":
            return "Saved"
        default:
            return "Queued"
        }
    }

    var isRetryNeeded: Bool {
        normalizedProcessingState == "failed"
    }

    var shouldAutoProcess: Bool {
        let state = normalizedProcessingState
        if state == "failed" || isTerminalLocalState {
            return false
        }

        if state == "queued" && (attemptCount ?? 0) == 0 && lastAttemptAt == nil {
            return true
        }

        let referenceDate = lastAttemptAt ?? updatedAt ?? createdAt
        return Date().timeIntervalSince(referenceDate) >= 3
    }

    var isTerminalLocalState: Bool {
        ["saved", "draft", "needs_review"].contains(normalizedProcessingState)
    }

    var isLiveQueueState: Bool {
        !isRetryNeeded && !isTerminalLocalState
    }

    var isPinnedTypedImport: Bool {
        let sourceURL = sourceURLString?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let sourceText = sourceText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return sourceURL.isEmpty
            && !sourceText.isEmpty
            && attachments.isEmpty
    }
}

enum SharedRecipeImportInbox {
    static func containerURL() throws -> URL {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: SharedRecipeImportConstants.appGroupID
        ) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let inboxURL = containerURL.appendingPathComponent(SharedRecipeImportConstants.inboxDirectoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: inboxURL, withIntermediateDirectories: true)
        return inboxURL
    }

    static func directoryURL(for envelopeID: String) throws -> URL {
        let url = try containerURL().appendingPathComponent(envelopeID, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func envelopeURL(for envelopeID: String) throws -> URL {
        try directoryURL(for: envelopeID).appendingPathComponent("payload.json")
    }

    static func relativeMediaPath(envelopeID: String, fileName: String) -> String {
        "\(envelopeID)/media/\(fileName)"
    }

    static func absoluteURL(forRelativePath relativePath: String) throws -> URL {
        try containerURL().appendingPathComponent(relativePath, isDirectory: false)
    }

    static func mediaDirectoryURL(for envelopeID: String) throws -> URL {
        let url = try directoryURL(for: envelopeID).appendingPathComponent("media", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func write(_ envelope: SharedRecipeImportEnvelope) throws {
        let url = try envelopeURL(for: envelope.id)
        let data = try JSONEncoder.sharedRecipeImport.encode(envelope)
        try data.write(to: url, options: .atomic)
    }

    static func update(_ envelope: SharedRecipeImportEnvelope) throws {
        try write(envelope)
    }

    /// Clears envelopes stuck in `processing` after a crash, background kill, or hung network (local inbox only).
    static func reconcileStaleProcessingEnvelopes(staleAfter seconds: TimeInterval = 15 * 60) throws {
        let all = try readAll()
        let now = Date()
        let staleStates: Set<String> = ["processing", "fetching", "parsing", "normalized"]
        for envelope in all where staleStates.contains(envelope.normalizedProcessingState) {
            let ref = envelope.lastAttemptAt ?? envelope.updatedAt ?? envelope.createdAt
            guard now.timeIntervalSince(ref) >= seconds else { continue }
            let failed = SharedRecipeImportEnvelope(
                id: envelope.id,
                createdAt: envelope.createdAt,
                jobID: envelope.jobID,
                targetState: envelope.targetState,
                sourceText: envelope.sourceText,
                sourceURLString: envelope.sourceURLString,
                canonicalSourceURLString: envelope.canonicalSourceURLString,
                sourceApp: envelope.sourceApp,
                attachments: envelope.attachments,
                processingState: "failed",
                attemptCount: envelope.attemptCount,
                lastAttemptAt: envelope.lastAttemptAt,
                lastError: "Import timed out. Tap Retry imports.",
                updatedAt: Date()
            )
            try update(failed)
        }
    }

    static func readAll() throws -> [SharedRecipeImportEnvelope] {
        let inboxURL = try containerURL()
        let directories = try FileManager.default.contentsOfDirectory(
            at: inboxURL,
            includingPropertiesForKeys: [.isDirectoryKey, .creationDateKey],
            options: [.skipsHiddenFiles]
        )

        return try directories.compactMap { directory in
            let payloadURL = directory.appendingPathComponent("payload.json")
            guard FileManager.default.fileExists(atPath: payloadURL.path) else { return nil }
            let data = try Data(contentsOf: payloadURL)
            return try JSONDecoder.sharedRecipeImport.decode(SharedRecipeImportEnvelope.self, from: data)
        }
        .filter { !$0.isTerminalLocalState }
        .sorted {
            let leftRank = queueSortRank(for: $0)
            let rightRank = queueSortRank(for: $1)
            if leftRank == rightRank {
                let leftDate = $0.updatedAt ?? $0.lastAttemptAt ?? $0.createdAt
                let rightDate = $1.updatedAt ?? $1.lastAttemptAt ?? $1.createdAt
                return leftDate > rightDate
            }
            return leftRank < rightRank
        }
    }

    static func delete(envelopeID: String) throws {
        let url = try directoryURL(for: envelopeID)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    static func handoffURL(for envelopeID: String? = nil) -> URL? {
        var components = URLComponents()
        components.scheme = SharedRecipeImportConstants.handoffURLScheme
        components.host = SharedRecipeImportConstants.handoffURLHost
        if let envelopeID, !envelopeID.isEmpty {
            components.queryItems = [URLQueryItem(name: "id", value: envelopeID)]
        }
        return components.url
    }

    static func isShareImportURL(_ url: URL) -> Bool {
        let scheme = url.scheme?.lowercased()
        return scheme == SharedRecipeImportConstants.handoffURLScheme
            && url.host?.lowercased() == SharedRecipeImportConstants.handoffURLHost
    }

    private static func queueSortRank(for envelope: SharedRecipeImportEnvelope) -> Int {
        switch envelope.normalizedProcessingState {
        case "failed":
            return 0
        case "processing":
            return 1
        case "queued":
            return (envelope.attemptCount ?? 0) > 0 ? 2 : 1
        default:
            return 2
        }
    }
}

private extension JSONEncoder {
    static var sharedRecipeImport: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

private extension JSONDecoder {
    static var sharedRecipeImport: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
