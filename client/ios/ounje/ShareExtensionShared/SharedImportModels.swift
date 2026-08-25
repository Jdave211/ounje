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
    private static let staleQueuedImportInterval: TimeInterval = 3 * 60
    private static let staleActiveImportInterval: TimeInterval = 15 * 60

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
    let serverSubmittedAt: Date?
    let lastError: String?
    let activeStage: String?
    let stageStartedAt: Date?
    let updatedAt: Date?

    init(
        id: String,
        createdAt: Date,
        jobID: String?,
        targetState: String,
        sourceText: String?,
        sourceURLString: String?,
        canonicalSourceURLString: String?,
        sourceApp: String?,
        attachments: [SharedRecipeImportAttachment],
        processingState: String?,
        attemptCount: Int?,
        lastAttemptAt: Date?,
        serverSubmittedAt: Date?,
        lastError: String?,
        activeStage: String? = nil,
        stageStartedAt: Date? = nil,
        updatedAt: Date?
    ) {
        self.id = id
        self.createdAt = createdAt
        self.jobID = jobID
        self.targetState = targetState
        self.sourceText = sourceText
        self.sourceURLString = sourceURLString
        self.canonicalSourceURLString = canonicalSourceURLString
        self.sourceApp = sourceApp
        self.attachments = attachments
        self.processingState = processingState
        self.attemptCount = attemptCount
        self.lastAttemptAt = lastAttemptAt
        self.serverSubmittedAt = serverSubmittedAt
        self.lastError = lastError
        self.activeStage = activeStage
        self.stageStartedAt = stageStartedAt
        self.updatedAt = updatedAt
    }

    var resolvedSourceText: String {
        let sourceURLString = sourceURLString?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !sourceURLString.isEmpty { return sourceURLString }
        return sourceText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    var normalizedProcessingState: String {
        String(processingState ?? "queued").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    var queueStatusLabel: String {
        if isStaleLiveImport {
            return "Retry needed"
        }

        let normalizedActiveStage = String(activeStage ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        switch normalizedProcessingState {
        case "failed":
            return "Retry needed"
        case "retryable":
            return "Retrying on server"
        case "queued":
            return (jobID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false) ? "Waiting for worker" : "Queued"
        case "submitted":
            return "Sending to server"
        case "processing":
            return "Importing"
        case "fetching":
            return "Pulling source"
        case "parsing":
            if normalizedActiveStage.contains("reference") || normalizedActiveStage.contains("search") {
                return "Finding references"
            }
            if normalizedActiveStage.contains("validation") {
                return "Checking recipe"
            }
            return "Building recipe"
        case "normalized":
            return "Saving"
        case "saved":
            return "Saved"
        default:
            return "Queued"
        }
    }

    var isRetryNeeded: Bool {
        normalizedProcessingState == "failed" || isStaleLiveImport
    }

    var shouldAutoProcess: Bool {
        let state = normalizedProcessingState
        if state == "failed" || isTerminalLocalState {
            return false
        }

        if jobID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            return isLiveQueueState
        }

        // A transport attempt is not a server acknowledgement. Background
        // URLSession uploads can be interrupted after the extension exits, so
        // any non-terminal envelope without a backend job remains eligible for
        // the containing app to submit. The API deduplicates repeated URLs.
        return ["queued", "submitted", "retryable"].contains(state)
    }

    var isTerminalLocalState: Bool {
        ["saved", "draft", "needs_review", "completed_applied"].contains(normalizedProcessingState)
    }

    var isLiveQueueState: Bool {
        !isRetryNeeded && !isTerminalLocalState
    }

    var isStaleLiveImport: Bool {
        let state = normalizedProcessingState
        let threshold: TimeInterval
        switch state {
        case "queued", "retryable":
            threshold = Self.staleQueuedImportInterval
        case "submitted", "processing", "fetching", "parsing", "normalized":
            threshold = Self.staleActiveImportInterval
        default:
            return false
        }
        return Date().timeIntervalSince(activityReferenceDate) >= threshold
    }

    var activityReferenceDate: Date {
        switch normalizedProcessingState {
        case "queued", "retryable", "submitted":
            return serverSubmittedAt
                ?? stageStartedAt
                ?? createdAt
        default:
            return stageStartedAt
                ?? updatedAt
                ?? lastAttemptAt
                ?? serverSubmittedAt
                ?? createdAt
        }
    }

    var isPinnedTypedImport: Bool {
        let sourceURL = sourceURLString?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let sourceText = sourceText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return sourceURL.isEmpty
            && !sourceText.isEmpty
            && attachments.isEmpty
    }
}
