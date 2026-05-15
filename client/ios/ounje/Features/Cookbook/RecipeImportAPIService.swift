import Foundation
import UIKit

struct RecipeImportJobPayload: Decodable {
    let id: String
    let targetState: String
    let sourceType: String
    let sourceURL: String?
    let canonicalURL: String?
    let sourceText: String?
    let recipeID: String?
    let status: String
    let reviewState: String
    let confidenceScore: Double?
    let qualityFlags: [String]
    let reviewReason: String?
    let errorMessage: String?
    let attempts: Int?
    let maxAttempts: Int?
    let createdAt: String?
    let updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case targetState = "target_state"
        case sourceType = "source_type"
        case sourceURL = "source_url"
        case canonicalURL = "canonical_url"
        case sourceText = "source_text"
        case recipeID = "recipe_id"
        case status
        case reviewState = "review_state"
        case confidenceScore = "confidence_score"
        case qualityFlags = "quality_flags"
        case reviewReason = "review_reason"
        case errorMessage = "error_message"
        case attempts
        case maxAttempts = "max_attempts"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

struct RecipeImportCompletedItem: Identifiable, Decodable {
    let id: String
    let recipeID: String?
    let title: String
    let status: String
    let reviewState: String
    let sourceType: String?
    let sourceURL: String?
    let canonicalURL: String?
    let sourceText: String?
    let imageURL: String?
    let source: String?
    let cookTimeText: String?
    let completedAt: String?
    let createdAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case recipeID = "recipe_id"
        case title
        case status
        case reviewState = "review_state"
        case sourceType = "source_type"
        case sourceURL = "source_url"
        case canonicalURL = "canonical_url"
        case sourceText = "source_text"
        case imageURL = "image_url"
        case source
        case cookTimeText = "cook_time_text"
        case completedAt = "completed_at"
        case createdAt = "created_at"
    }
}

struct RecipeImportCompletedPage {
    let items: [RecipeImportCompletedItem]
    let totalCount: Int
}

struct RecipeImportQueuePage {
    let items: [RecipeImportJobPayload]
    let totalCount: Int
}

extension RecipeImportJobPayload {
    var sharedImportEnvelope: SharedRecipeImportEnvelope {
        SharedRecipeImportEnvelope(
            id: id,
            createdAt: Self.importDate(from: createdAt ?? updatedAt) ?? Date(),
            jobID: id,
            targetState: targetState,
            sourceText: sourceText,
            sourceURLString: sourceURL,
            canonicalSourceURLString: canonicalURL,
            sourceApp: sourceType,
            attachments: [],
            processingState: status,
            attemptCount: attempts,
            lastAttemptAt: Self.importDate(from: updatedAt),
            lastError: errorMessage ?? reviewReason,
            updatedAt: Self.importDate(from: updatedAt) ?? Date()
        )
    }

    private static func importDate(from raw: String?) -> Date? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractionalFormatter.date(from: raw) {
            return date
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: raw)
    }
}

extension SharedRecipeImportEnvelope {
    var reconciliationKeys: Set<String> {
        var keys: Set<String> = []
        if let normalizedURL = Self.normalizedImportKey(from: sourceURLString) {
            keys.insert(normalizedURL)
        }
        if let normalizedCanonicalURL = Self.normalizedImportKey(from: canonicalSourceURLString) {
            keys.insert(normalizedCanonicalURL)
        }
        if let normalizedText = Self.normalizedImportKey(from: resolvedSourceText) {
            keys.insert(normalizedText)
        }
        return keys
    }

    static func normalizedImportKey(from raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        if let url = URL(string: raw), let host = url.host?.lowercased(), !host.isEmpty {
            let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
            return ([host, path].filter { !$0.isEmpty }).joined(separator: "/")
        }

        return raw
            .lowercased()
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}

extension RecipeImportCompletedItem {
    var sourceKindLabel: String? {
        switch sourceType?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "" {
        case "recipe_search":
            return "Recipe search"
        case "concept_prompt", "direct_input", "text":
            return "Typed import"
        case "media_image", "media_video":
            return "Media import"
        case "tiktok", "instagram", "youtube":
            return "Shared import"
        default:
            return nil
        }
    }

    var reconciliationKeys: Set<String> {
        [
            SharedRecipeImportEnvelope.normalizedImportKey(from: sourceURL),
            SharedRecipeImportEnvelope.normalizedImportKey(from: canonicalURL),
            SharedRecipeImportEnvelope.normalizedImportKey(from: sourceText)
        ]
        .compactMap { $0 }
        .reduce(into: Set<String>()) { partialResult, key in
            partialResult.insert(key)
        }
    }

    func matches(envelope: SharedRecipeImportEnvelope) -> Bool {
        !reconciliationKeys.isDisjoint(with: envelope.reconciliationKeys)
    }

    var savedRecipeCard: DiscoverRecipeCardData? {
        let normalizedRecipeID = recipeID?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let normalizedRecipeID, !normalizedRecipeID.isEmpty else { return nil }

        let normalizedSource = source?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedImageURL = imageURL?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedRecipeURL = (canonicalURL ?? sourceURL)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let displaySource = (normalizedSource?.isEmpty == false ? normalizedSource : nil) ?? "Imported recipe"

        return DiscoverRecipeCardData(
            id: normalizedRecipeID,
            title: title,
            description: displaySource == "Imported recipe" ? "Imported recipe." : "Imported from \(displaySource).",
            authorName: nil,
            authorHandle: nil,
            category: displaySource,
            recipeType: displaySource,
            cookTimeText: cookTimeText,
            cookTimeMinutes: nil,
            publishedDate: completedAt ?? createdAt,
            imageURLString: normalizedImageURL?.isEmpty == true ? nil : normalizedImageURL,
            heroImageURLString: normalizedImageURL?.isEmpty == true ? nil : normalizedImageURL,
            recipeURLString: normalizedRecipeURL?.isEmpty == true ? nil : normalizedRecipeURL,
            source: displaySource
        )
    }
}

struct RecipeImportResponse: Decodable {
    let job: RecipeImportJobPayload
    let recipe: DiscoverRecipeCardData?
    let recipeDetail: RecipeDetailData?

    enum CodingKeys: String, CodingKey {
        case job
        case recipe
        case recipeDetail = "recipe_detail"
    }
}

enum RecipeImportServiceError: Error, LocalizedError {
    case invalidRequest
    case invalidResponse
    case requestFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidRequest:
            return "The request could not be prepared."
        case .invalidResponse:
            return "The server returned an invalid response."
        case let .requestFailed(message):
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "The request failed." : trimmed
        }
    }
}

struct RecipeImportAttachmentPayload: Encodable {
    let kind: String
    let sourceURL: String?
    let dataURL: String?
    let mimeType: String?
    let fileName: String?
    let previewFrameURLs: [String]
    let storageBucket: String?
    let storagePath: String?
    let publicHeroURL: String?
    let width: Int?
    let height: Int?

    init(
        kind: String,
        sourceURL: String? = nil,
        dataURL: String? = nil,
        mimeType: String? = nil,
        fileName: String? = nil,
        previewFrameURLs: [String] = [],
        storageBucket: String? = nil,
        storagePath: String? = nil,
        publicHeroURL: String? = nil,
        width: Int? = nil,
        height: Int? = nil
    ) {
        self.kind = kind
        self.sourceURL = sourceURL
        self.dataURL = dataURL
        self.mimeType = mimeType
        self.fileName = fileName
        self.previewFrameURLs = previewFrameURLs
        self.storageBucket = storageBucket
        self.storagePath = storagePath
        self.publicHeroURL = publicHeroURL
        self.width = width
        self.height = height
    }

    enum CodingKeys: String, CodingKey {
        case kind
        case sourceURL = "source_url"
        case dataURL = "data_url"
        case mimeType = "mime_type"
        case fileName = "file_name"
        case previewFrameURLs = "preview_frame_urls"
        case storageBucket = "storage_bucket"
        case storagePath = "storage_path"
        case publicHeroURL = "public_hero_url"
        case width
        case height
    }
}

struct RecipeImportPhotoContextPayload: Encodable {
    let dishHint: String?
    let coarsePlaceContext: String?
    let pipeline: String

    init(dishHint: String? = nil, coarsePlaceContext: String? = nil, pipeline: String = "photo_to_recipe") {
        self.dishHint = dishHint
        self.coarsePlaceContext = coarsePlaceContext
        self.pipeline = pipeline
    }

    enum CodingKeys: String, CodingKey {
        case dishHint = "dish_hint"
        case coarsePlaceContext = "coarse_place_context"
        case pipeline
    }
}

struct RecipeImportRequestPayload: Encodable {
    let userID: String?
    let sourceURL: String?
    let sourceText: String
    let accessToken: String?
    let targetState: String
    let attachments: [RecipeImportAttachmentPayload]
    let photoContext: RecipeImportPhotoContextPayload?
    let processInline: Bool = false

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case sourceURL = "source_url"
        case sourceText = "source_text"
        case accessToken = "access_token"
        case targetState = "target_state"
        case attachments
        case photoContext = "photo_context"
        case processInline = "process_inline"
    }
}

final class RecipeImportAPIService {
    static let shared = RecipeImportAPIService()

    private init() {}

    private func applyAuthHeaders(
        to request: inout URLRequest,
        userID: String?,
        accessToken: String?
    ) {
        let trimmedToken = accessToken?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedToken.isEmpty {
            request.setValue("Bearer \(trimmedToken)", forHTTPHeaderField: "Authorization")
        }

        let trimmedUserID = userID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedUserID.isEmpty {
            request.setValue(trimmedUserID, forHTTPHeaderField: "x-user-id")
        }
    }

    func importRecipe(
        userID: String?,
        accessToken: String? = nil,
        sourceURL: String? = nil,
        sourceText: String,
        targetState: String,
        attachments: [RecipeImportAttachmentPayload] = [],
        photoContext: RecipeImportPhotoContextPayload? = nil
    ) async throws -> RecipeImportResponse {
        var lastError: Error?
        for baseURL in OunjeDevelopmentServer.workerCandidateBaseURLs {
            do {
                return try await importRecipe(
                    baseURL: baseURL,
                    userID: userID,
                    accessToken: accessToken,
                    sourceURL: sourceURL,
                    sourceText: sourceText,
                    targetState: targetState,
                    attachments: attachments,
                    photoContext: photoContext
                )
            } catch {
                lastError = error
            }
        }

        throw lastError ?? RecipeImportServiceError.invalidRequest
    }

    func fetchCompletedImports(userID: String, accessToken: String?) async throws -> RecipeImportCompletedPage {
        var lastError: Error?
        for baseURL in OunjeDevelopmentServer.workerCandidateBaseURLs {
            do {
                return try await fetchCompletedImports(baseURL: baseURL, userID: userID, accessToken: accessToken)
            } catch {
                lastError = error
            }
        }

        throw lastError ?? RecipeImportServiceError.invalidRequest
    }

    func fetchImportQueue(userID: String, accessToken: String?) async throws -> RecipeImportQueuePage {
        var lastError: Error?
        for baseURL in OunjeDevelopmentServer.workerCandidateBaseURLs {
            do {
                return try await fetchImportQueue(baseURL: baseURL, userID: userID, accessToken: accessToken)
            } catch {
                lastError = error
            }
        }

        throw lastError ?? RecipeImportServiceError.invalidRequest
    }

    func fetchImportJob(jobID: String, accessToken: String?) async throws -> RecipeImportResponse {
        var lastError: Error?
        for baseURL in OunjeDevelopmentServer.workerCandidateBaseURLs {
            do {
                return try await fetchImportJob(baseURL: baseURL, jobID: jobID, accessToken: accessToken)
            } catch {
                lastError = error
            }
        }

        throw lastError ?? RecipeImportServiceError.invalidRequest
    }

    private func importRecipe(
        baseURL: String,
        userID: String?,
        accessToken: String?,
        sourceURL: String?,
        sourceText: String,
        targetState: String,
        attachments: [RecipeImportAttachmentPayload],
        photoContext: RecipeImportPhotoContextPayload?
    ) async throws -> RecipeImportResponse {
        guard let url = URL(string: "\(baseURL)/v1/recipe/imports") else {
            throw RecipeImportServiceError.invalidRequest
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 90
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyAuthHeaders(to: &request, userID: userID, accessToken: accessToken)
        request.httpBody = try JSONEncoder().encode(
            RecipeImportRequestPayload(
                userID: userID,
                sourceURL: sourceURL,
                sourceText: sourceText,
                accessToken: accessToken,
                targetState: targetState,
                attachments: attachments,
                photoContext: photoContext
            )
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw RecipeImportServiceError.invalidResponse
        }

        guard (200 ... 299).contains(httpResponse.statusCode) else {
            let errorPayload = try? JSONDecoder().decode(SupabaseRestErrorResponse.self, from: data)
            let fallback = "Recipe import failed (\(httpResponse.statusCode))."
            throw RecipeImportServiceError.requestFailed(errorPayload?.message ?? errorPayload?.error ?? fallback)
        }

        return try JSONDecoder().decode(RecipeImportResponse.self, from: data)
    }

    private func fetchCompletedImports(
        baseURL: String,
        userID: String,
        accessToken: String?
    ) async throws -> RecipeImportCompletedPage {
        var components = URLComponents(string: "\(baseURL)/v1/recipe/imports/completed") ?? URLComponents()
        components.queryItems = [
            URLQueryItem(name: "user_id", value: userID)
        ]
        guard let url = components.url else {
            throw RecipeImportServiceError.invalidRequest
        }

        var request = URLRequest(url: url)
        applyAuthHeaders(to: &request, userID: userID, accessToken: accessToken)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw RecipeImportServiceError.invalidResponse
        }

        guard (200 ... 299).contains(httpResponse.statusCode) else {
            let errorPayload = try? JSONDecoder().decode(SupabaseRestErrorResponse.self, from: data)
            let fallback = "Completed imports failed (\(httpResponse.statusCode))."
            throw RecipeImportServiceError.requestFailed(errorPayload?.message ?? errorPayload?.error ?? fallback)
        }

        struct Payload: Decodable {
            let items: [RecipeImportCompletedItem]
            let count: Int?
            let totalCount: Int?

            enum CodingKeys: String, CodingKey {
                case items
                case count
                case totalCount = "total_count"
            }
        }

        let payload = try JSONDecoder().decode(Payload.self, from: data)
        return RecipeImportCompletedPage(
            items: payload.items,
            totalCount: payload.totalCount ?? payload.count ?? payload.items.count
        )
    }

    private func fetchImportQueue(
        baseURL: String,
        userID: String,
        accessToken: String?
    ) async throws -> RecipeImportQueuePage {
        var components = URLComponents(string: "\(baseURL)/v1/recipe/imports") ?? URLComponents()
        components.queryItems = [
            URLQueryItem(name: "user_id", value: userID)
        ]
        guard let url = components.url else {
            throw RecipeImportServiceError.invalidRequest
        }

        var request = URLRequest(url: url)
        applyAuthHeaders(to: &request, userID: userID, accessToken: accessToken)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw RecipeImportServiceError.invalidResponse
        }

        guard (200 ... 299).contains(httpResponse.statusCode) else {
            let errorPayload = try? JSONDecoder().decode(SupabaseRestErrorResponse.self, from: data)
            let fallback = "Queued imports failed (\(httpResponse.statusCode))."
            throw RecipeImportServiceError.requestFailed(errorPayload?.message ?? errorPayload?.error ?? fallback)
        }

        struct Payload: Decodable {
            let items: [RecipeImportJobPayload]
            let count: Int?
            let totalCount: Int?

            enum CodingKeys: String, CodingKey {
                case items
                case count
                case totalCount = "total_count"
            }
        }

        let payload = try JSONDecoder().decode(Payload.self, from: data)
        return RecipeImportQueuePage(
            items: payload.items,
            totalCount: payload.totalCount ?? payload.count ?? payload.items.count
        )
    }

    private func fetchImportJob(
        baseURL: String,
        jobID: String,
        accessToken: String?
    ) async throws -> RecipeImportResponse {
        guard let url = URL(string: "\(baseURL)/v1/recipe/imports/\(jobID)") else {
            throw RecipeImportServiceError.invalidRequest
        }

        var request = URLRequest(url: url)
        applyAuthHeaders(to: &request, userID: nil, accessToken: accessToken)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw RecipeImportServiceError.invalidResponse
        }

        guard (200 ... 299).contains(httpResponse.statusCode) else {
            let errorPayload = try? JSONDecoder().decode(SupabaseRestErrorResponse.self, from: data)
            let fallback = "Recipe import status failed (\(httpResponse.statusCode))."
            throw RecipeImportServiceError.requestFailed(errorPayload?.message ?? errorPayload?.error ?? fallback)
        }

        return try JSONDecoder().decode(RecipeImportResponse.self, from: data)
    }
}
