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

        if state == "queued" && (attemptCount ?? 0) == 0 && lastAttemptAt == nil {
            return true
        }

        if state == "submitted" {
            let referenceDate = lastAttemptAt ?? updatedAt ?? createdAt
            return Date().timeIntervalSince(referenceDate) >= 5 * 60
        }

        let referenceDate = lastAttemptAt ?? updatedAt ?? createdAt
        return Date().timeIntervalSince(referenceDate) >= 3
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
