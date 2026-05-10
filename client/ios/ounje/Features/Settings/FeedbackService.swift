import Foundation

struct AppFeedbackMessageAttachment: Codable, Hashable {
    let fileName: String?
    let mimeType: String?
    let kind: String?

    enum CodingKeys: String, CodingKey {
        case fileName = "file_name"
        case mimeType = "mime_type"
        case kind
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

final class OunjeFeedbackService {
    static let shared = OunjeFeedbackService()

    private init() {}

    func fetchMessages(userID: String, accessToken: String? = nil) async throws -> [AppFeedbackMessage] {
        guard var components = URLComponents(string: "\(OunjeDevelopmentServer.primaryBaseURL)/v1/feedback") else {
            throw FeedbackServiceError.invalidRequest
        }
        components.queryItems = [URLQueryItem(name: "user_id", value: userID)]
        guard let url = components.url else {
            throw FeedbackServiceError.invalidRequest
        }

        var urlRequest = URLRequest(url: url)
        if let token = accessToken, !token.isEmpty {
            urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw FeedbackServiceError.invalidResponse
        }
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
        return payload.items
    }

    func submitFeedback(
        userID: String,
        body: String,
        attachments: [AppFeedbackMessageAttachment],
        accessToken: String? = nil
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

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = accessToken, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONEncoder().encode(Payload(userID: userID, body: body, attachments: attachments))

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw FeedbackServiceError.invalidResponse
        }
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
        return try decoder.decode(FeedbackSubmissionResponse.self, from: data)
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
