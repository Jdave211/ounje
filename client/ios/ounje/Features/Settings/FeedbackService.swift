import Foundation

struct AppFeedbackMessageAttachment: Codable, Hashable {
    let fileName: String?
    let mimeType: String?
    let kind: String?
    let storagePath: String?
    let signedURL: String?
    let width: Int?
    let height: Int?
    let sizeBytes: Int?

    init(
        fileName: String? = nil,
        mimeType: String? = nil,
        kind: String? = nil,
        storagePath: String? = nil,
        signedURL: String? = nil,
        width: Int? = nil,
        height: Int? = nil,
        sizeBytes: Int? = nil
    ) {
        self.fileName = fileName
        self.mimeType = mimeType
        self.kind = kind
        self.storagePath = storagePath
        self.signedURL = signedURL
        self.width = width
        self.height = height
        self.sizeBytes = sizeBytes
    }

    var isVideo: Bool {
        (kind?.lowercased() == "video") || (mimeType?.lowercased().hasPrefix("video") ?? false)
    }

    enum CodingKeys: String, CodingKey {
        case fileName = "file_name"
        case mimeType = "mime_type"
        case kind
        case storagePath = "storage_path"
        case signedURL = "signed_url"
        case width
        case height
        case sizeBytes = "size_bytes"
    }
}

struct AppFeedbackMessage: Identifiable, Codable, Hashable {
    let id: UUID
    let userID: String
    let authorRole: String
    let body: String
    let attachments: [AppFeedbackMessageAttachment]
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case userID = "user_id"
        case authorRole = "author_role"
        case body
        case attachments
        case createdAt = "created_at"
    }

    init(
        id: UUID,
        userID: String,
        authorRole: String,
        body: String,
        attachments: [AppFeedbackMessageAttachment],
        createdAt: Date
    ) {
        self.id = id
        self.userID = userID
        self.authorRole = authorRole
        self.body = body
        self.attachments = attachments
        self.createdAt = createdAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        userID = try container.decodeIfPresent(String.self, forKey: .userID) ?? ""
        authorRole = try container.decodeIfPresent(String.self, forKey: .authorRole) ?? "system"
        body = try container.decodeIfPresent(String.self, forKey: .body) ?? ""
        attachments = try container.decodeIfPresent([AppFeedbackMessageAttachment].self, forKey: .attachments) ?? []

        let rawCreatedAt = try container.decodeIfPresent(String.self, forKey: .createdAt)
        createdAt = FeedbackDateParser.parse(rawCreatedAt) ?? Date()
    }
}

enum FeedbackDateParser {
    private static let fractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let standardFormatter = ISO8601DateFormatter()

    static func parse(_ raw: String?) -> Date? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        return fractionalFormatter.date(from: raw) ?? standardFormatter.date(from: raw)
    }
}

enum FeedbackServiceError: LocalizedError {
    case invalidRequest
    case invalidResponse
    case requestFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidRequest:
            return "Feedback request was invalid."
        case .invalidResponse:
            return "Feedback response was invalid."
        case let .requestFailed(message):
            return message
        }
    }
}

struct FeedbackSubmissionResponse: Decodable {
    let items: [AppFeedbackMessage]
}

/// Closure that returns a fresh Supabase access token, refreshing the session
/// if the cached token is near expiry. The feedback service calls this when it
/// receives a 401 so it can retry once with a non-stale token rather than
/// surfacing a confusing "Authorization expired or invalid" error to the user.
typealias FreshAccessTokenProvider = () async -> String?

final class OunjeFeedbackService {
    static let shared = OunjeFeedbackService()

    private init() {}

    private var threadCache: [String: (messages: [AppFeedbackMessage], fetchedAt: Date)] = [:]
    private let threadCacheTTL: TimeInterval = 5 * 60

    func invalidateThreadCache(for userID: String) {
        threadCache.removeValue(forKey: userID)
    }

    func fetchMessages(
        userID: String,
        accessToken: String? = nil,
        forceRefresh: Bool = false,
        refreshAccessToken: FreshAccessTokenProvider? = nil
    ) async throws -> [AppFeedbackMessage] {
        if !forceRefresh,
           let cached = threadCache[userID],
           Date().timeIntervalSince(cached.fetchedAt) < threadCacheTTL {
            return cached.messages
        }

        guard var components = URLComponents(string: "\(OunjeDevelopmentServer.primaryBaseURL)/v1/feedback") else {
            throw FeedbackServiceError.invalidRequest
        }
        components.queryItems = [URLQueryItem(name: "user_id", value: userID)]
        guard let url = components.url else {
            throw FeedbackServiceError.invalidRequest
        }

        let (data, httpResponse) = try await performWithRefresh(
            url: url,
            method: "GET",
            body: nil,
            contentType: nil,
            initialToken: accessToken,
            refreshAccessToken: refreshAccessToken
        )

        guard (200 ... 299).contains(httpResponse.statusCode) else {
            let errorPayload = try? JSONDecoder().decode(SupabaseRestErrorResponse.self, from: data)
            if Self.isMissingFeedbackTable(errorPayload?.message ?? errorPayload?.error ?? "") {
                return []
            }
            throw FeedbackServiceError.requestFailed(errorPayload?.message ?? errorPayload?.error ?? "Feedback could not be loaded (\(httpResponse.statusCode)).")
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let payload = try decoder.decode(NotificationEventsResponse<AppFeedbackMessage>.self, from: data)
        threadCache[userID] = (messages: payload.items, fetchedAt: Date())
        return payload.items
    }

    func submitFeedback(
        userID: String,
        body: String,
        attachments: [AppFeedbackMessageAttachment],
        accessToken: String? = nil,
        refreshAccessToken: FreshAccessTokenProvider? = nil
    ) async throws -> FeedbackSubmissionResponse {
        guard let url = URL(string: "\(OunjeDevelopmentServer.primaryBaseURL)/v1/feedback") else {
            throw FeedbackServiceError.invalidRequest
        }

        struct Payload: Encodable {
            let userID: String
            let body: String
            let attachments: [AppFeedbackMessageAttachment]

            enum CodingKeys: String, CodingKey {
                case userID = "user_id"
                case body
                case attachments
            }
        }

        let bodyData = try JSONEncoder().encode(Payload(userID: userID, body: body, attachments: attachments))

        let (data, httpResponse) = try await performWithRefresh(
            url: url,
            method: "POST",
            body: bodyData,
            contentType: "application/json",
            initialToken: accessToken,
            refreshAccessToken: refreshAccessToken
        )

        guard (200 ... 299).contains(httpResponse.statusCode) else {
            let errorPayload = try? JSONDecoder().decode(SupabaseRestErrorResponse.self, from: data)
            let message = errorPayload?.message ?? errorPayload?.error ?? "Feedback could not be submitted (\(httpResponse.statusCode))."
            if Self.isMissingFeedbackTable(message) {
                return Self.localFallbackSubmission(body: body, attachments: attachments)
            }
            throw FeedbackServiceError.requestFailed(message)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let result = try decoder.decode(FeedbackSubmissionResponse.self, from: data)
        threadCache.removeValue(forKey: userID)
        return result
    }

    /// Performs the HTTP request with an automatic one-shot retry on 401.
    /// When the server responds with 401 ("Authorization expired or invalid"),
    /// we ask the caller for a freshly refreshed access token and retry the
    /// request once. This eliminates spurious auth errors that show up after
    /// the app has been backgrounded long enough for the cached JWT to expire.
    private func performWithRefresh(
        url: URL,
        method: String,
        body: Data?,
        contentType: String?,
        initialToken: String?,
        refreshAccessToken: FreshAccessTokenProvider?
    ) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 15
        if let contentType {
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        if let token = initialToken, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw FeedbackServiceError.invalidResponse
        }

        // Retry once on 401 with a freshly refreshed token. Skip retry if we
        // never had a token to begin with (refresh wouldn't help) or no
        // refresher was supplied.
        guard httpResponse.statusCode == 401,
              let refreshAccessToken,
              let refreshedToken = await refreshAccessToken(),
              !refreshedToken.isEmpty,
              refreshedToken != initialToken else {
            return (data, httpResponse)
        }

        var retryRequest = URLRequest(url: url)
        retryRequest.httpMethod = method
        retryRequest.timeoutInterval = 15
        if let contentType {
            retryRequest.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        retryRequest.setValue("Bearer \(refreshedToken)", forHTTPHeaderField: "Authorization")
        retryRequest.httpBody = body

        let (retryData, retryResponse) = try await URLSession.shared.data(for: retryRequest)
        guard let retryHTTP = retryResponse as? HTTPURLResponse else {
            throw FeedbackServiceError.invalidResponse
        }
        return (retryData, retryHTTP)
    }

    private struct NotificationEventsResponse<Item: Decodable>: Decodable {
        let items: [Item]
    }

    private static func isMissingFeedbackTable(_ message: String) -> Bool {
        let normalized = message.lowercased()
        return normalized.contains("app_feedback_messages")
            && (normalized.contains("schema cache") || normalized.contains("does not exist"))
    }

    private static func localFallbackSubmission(body: String, attachments: [AppFeedbackMessageAttachment]) -> FeedbackSubmissionResponse {
        let now = Date()
        let userMessage = AppFeedbackMessage(
            id: UUID(),
            userID: "",
            authorRole: "user",
            body: body,
            attachments: attachments,
            createdAt: now
        )

        return FeedbackSubmissionResponse(
            items: [userMessage]
        )
    }
}
