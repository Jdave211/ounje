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
        normalizedProcessingState == "failed"
    }

    var shouldAutoProcess: Bool {
        let state = normalizedProcessingState
        if state == "failed" || isTerminalLocalState {
            return false
        }

        if jobID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            return isLiveQueueState
        }

        // No server job ID yet — this import never finished handoff. Cap re-submits so a
        // persistently failing envelope ends up failed (via the catch path or the stale
        // watchdog) instead of retrying forever.
        guard (attemptCount ?? 0) < Self.maxHandoffSubmitAttempts else { return false }

        // If a submit was already started, only suppress re-sending while that POST could
        // still be in flight (it times out at 90s). Past that window the submit clearly never
        // landed (no job was created — e.g. the app was suspended mid-request during a share
        // handoff), so re-drive it instead of stranding the import in "submitted" until the
        // stale watchdog. The server dedupes by source, so a re-send can't create a duplicate
        // even if the original request eventually arrives.
        if let serverSubmittedAt {
            let lastActivity = [serverSubmittedAt, lastAttemptAt].compactMap { $0 }.max() ?? serverSubmittedAt
            return Date().timeIntervalSince(lastActivity) >= 100
        }

        return state == "queued"
    }

    /// Max client-side submit attempts for an envelope that has no server job yet.
    static let maxHandoffSubmitAttempts = 3

    var isTerminalLocalState: Bool {
        ["saved", "draft", "needs_review", "completed_applied"].contains(normalizedProcessingState)
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
