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
        case "retryable":
            return "Retrying on server"
        case "queued":
            return (jobID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false) ? "Waiting for worker" : "Queued"
        case "submitted":
            return "Sending to server"
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

        if jobID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            return isLiveQueueState
        }

        if serverSubmittedAt != nil {
            return false
        }

        if state == "queued" {
            return true
        }

        return false
    }

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
