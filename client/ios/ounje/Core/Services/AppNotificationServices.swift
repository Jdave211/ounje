import SwiftUI
import Foundation
import UserNotifications

extension Notification.Name {
    static let recipeImportHistoryNeedsRefresh = Notification.Name("recipeImportHistoryNeedsRefresh")
    static let instacartRunSummaryDidUpdate = Notification.Name("instacartRunSummaryDidUpdate")
}

struct AppNotificationEvent: Identifiable, Codable, Hashable {
    let id: UUID
    let userID: String
    let kind: String
    let dedupeKey: String
    let title: String
    let body: String
    let subtitle: String?
    let imageURLString: String?
    let actionURLString: String?
    let actionLabel: String?
    let orderID: UUID?
    let planID: UUID?
    let recipeID: String?
    let metadata: [String: String]?
    let scheduledFor: Date
    let deliveredAt: Date?
    let seenAt: Date?
    let openedAt: Date?
    let createdAt: Date
    let updatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case userID = "user_id"
        case kind
        case dedupeKey = "dedupe_key"
        case title
        case body
        case subtitle
        case imageURLString = "image_url"
        case actionURLString = "action_url"
        case actionLabel = "action_label"
        case orderID = "order_id"
        case planID = "plan_id"
        case recipeID = "recipe_id"
        case metadata
        case scheduledFor = "scheduled_for"
        case deliveredAt = "delivered_at"
        case seenAt = "seen_at"
        case openedAt = "opened_at"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        userID = try container.decode(String.self, forKey: .userID)
        kind = try container.decode(String.self, forKey: .kind)
        dedupeKey = try container.decode(String.self, forKey: .dedupeKey)
        title = try container.decode(String.self, forKey: .title)
        body = try container.decode(String.self, forKey: .body)
        subtitle = try container.decodeIfPresent(String.self, forKey: .subtitle)
        imageURLString = try container.decodeIfPresent(String.self, forKey: .imageURLString)
        actionURLString = try container.decodeIfPresent(String.self, forKey: .actionURLString)
        actionLabel = try container.decodeIfPresent(String.self, forKey: .actionLabel)
        orderID = try container.decodeIfPresent(UUID.self, forKey: .orderID)
        planID = try container.decodeIfPresent(UUID.self, forKey: .planID)
        recipeID = try container.decodeIfPresent(String.self, forKey: .recipeID)
        if let stringMetadata = try? container.decode([String: String].self, forKey: .metadata) {
            metadata = stringMetadata
        } else if let jsonMetadata = try? container.decode([String: AppNotificationMetadataScalar].self, forKey: .metadata) {
            metadata = jsonMetadata.reduce(into: [:]) { partialResult, pair in
                partialResult[pair.key] = pair.value.stringValue
            }
        } else {
            metadata = nil
        }
        scheduledFor = try container.decode(Date.self, forKey: .scheduledFor)
        deliveredAt = try container.decodeIfPresent(Date.self, forKey: .deliveredAt)
        seenAt = try container.decodeIfPresent(Date.self, forKey: .seenAt)
        openedAt = try container.decodeIfPresent(Date.self, forKey: .openedAt)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt)
    }
}

private enum AppNotificationMetadataScalar: Codable, Hashable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else {
            self = .string(try container.decode(String.self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(value):
            try container.encode(value)
        case let .number(value):
            try container.encode(value)
        case let .bool(value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }

    var stringValue: String {
        switch self {
        case let .string(value):
            return value
        case let .number(value):
            if value.rounded() == value {
                return String(Int(value))
            }
            return String(value)
        case let .bool(value):
            return value ? "true" : "false"
        case .null:
            return ""
        }
    }
}

private struct AppNotificationEventWritePayload: Encodable {
    let userID: String
    let kind: String
    let dedupeKey: String
    let title: String
    let body: String
    let subtitle: String?
    let imageURLString: String?
    let actionURLString: String?
    let actionLabel: String?
    let orderID: String?
    let planID: String?
    let recipeID: String?
    let metadata: [String: String]
    let scheduledFor: String

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case kind
        case dedupeKey = "dedupe_key"
        case title
        case body
        case subtitle
        case imageURLString = "image_url"
        case actionURLString = "action_url"
        case actionLabel = "action_label"
        case orderID = "order_id"
        case planID = "plan_id"
        case recipeID = "recipe_id"
        case metadata
        case scheduledFor = "scheduled_for"
    }
}

private enum AppNotificationEventServiceError: LocalizedError {
    case invalidRequest
    case invalidResponse
    case unauthorized
    case requestFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidRequest:
            return "Notification request was invalid."
        case .invalidResponse:
            return "Notification response was invalid."
        case .unauthorized:
            return "Notification session expired."
        case let .requestFailed(message):
            return message
        }
    }
}

final class SupabaseAppNotificationEventService {
    static let shared = SupabaseAppNotificationEventService()

    private init() {}

    func fetchPendingEvents(
        userID: String,
        accessToken: String? = nil,
        limit: Int = 40
    ) async throws -> [AppNotificationEvent] {
        if let backendEvents = try? await fetchEventsViaBackend(
            path: "/v1/notifications/pending",
            userID: userID,
            limit: limit
        ) {
            return backendEvents.filter { !$0.isHiddenFromNotifications }
        }
        return try await fetchEventsViaSupabase(
            userID: userID,
            accessToken: accessToken,
            deliveredOnly: true,
            limit: limit
        ).filter { !$0.isHiddenFromNotifications }
    }

    func fetchRecentEvents(
        userID: String,
        accessToken: String? = nil,
        limit: Int = 60
    ) async throws -> [AppNotificationEvent] {
        if let backendEvents = try? await fetchEventsViaBackend(
            path: "/v1/notifications/recent",
            userID: userID,
            limit: limit
        ) {
            return backendEvents.filter { !$0.isHiddenFromNotifications }
        }
        return try await fetchEventsViaSupabase(
            userID: userID,
            accessToken: accessToken,
            deliveredOnly: false,
            limit: limit
        ).filter { !$0.isHiddenFromNotifications }
    }

    func markDelivered(eventIDs: [UUID], userID: String, accessToken: String? = nil) async throws {
        if (try? await updateEventsViaBackend(eventIDs: eventIDs, userID: userID, path: "/v1/notifications/mark-delivered", bodyKey: "event_ids")) == true {
            return
        }
        try await updateViaSupabase(eventIDs: eventIDs, accessToken: accessToken, bodyKey: "delivered_at")
    }

    func markSeen(eventID: UUID, userID: String, accessToken: String? = nil) async throws {
        try await markSeen(eventIDs: [eventID], userID: userID, accessToken: accessToken)
    }

    func markSeen(eventIDs: [UUID], userID: String, accessToken: String? = nil) async throws {
        if (try? await updateEventsViaBackend(eventIDs: eventIDs, userID: userID, path: "/v1/notifications/mark-seen", bodyKey: "event_ids")) == true {
            return
        }
        try await updateViaSupabase(eventIDs: eventIDs, accessToken: accessToken, bodyKey: "seen_at")
    }

    func createEvent(
        userID: String,
        accessToken: String? = nil,
        kind: String,
        dedupeKey: String,
        title: String,
        body: String,
        subtitle: String? = nil,
        imageURLString: String? = nil,
        actionURLString: String? = nil,
        actionLabel: String? = nil,
        orderID: UUID? = nil,
        planID: UUID? = nil,
        recipeID: String? = nil,
        metadata: [String: String] = [:],
        scheduledFor: Date = .now
    ) async throws {
        if (try? await createEventViaBackend(
            userID: userID,
            kind: kind,
            dedupeKey: dedupeKey,
            title: title,
            body: body,
            subtitle: subtitle,
            imageURLString: imageURLString,
            actionURLString: actionURLString,
            actionLabel: actionLabel,
            orderID: orderID,
            planID: planID,
            recipeID: recipeID,
            metadata: metadata,
            scheduledFor: scheduledFor
        )) == true {
            return
        }

        guard let accessToken,
              !accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AppNotificationEventServiceError.unauthorized
        }

        try await createEventViaSupabase(
            userID: userID,
            accessToken: accessToken,
            kind: kind,
            dedupeKey: dedupeKey,
            title: title,
            body: body,
            subtitle: subtitle,
            imageURLString: imageURLString,
            actionURLString: actionURLString,
            actionLabel: actionLabel,
            orderID: orderID,
            planID: planID,
            recipeID: recipeID,
            metadata: metadata,
            scheduledFor: scheduledFor
        )
    }

    private func backendURL(path: String, queryItems: [URLQueryItem] = []) -> URL? {
        guard var components = URLComponents(string: "\(OunjeDevelopmentServer.primaryBaseURL)\(path)") else {
            return nil
        }
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        return components.url
    }

    private func fetchEventsViaBackend(path: String, userID: String, limit: Int) async throws -> [AppNotificationEvent] {
        guard let url = backendURL(path: path, queryItems: [URLQueryItem(name: "user_id", value: userID), URLQueryItem(name: "limit", value: "\(limit)")]) else {
            throw AppNotificationEventServiceError.invalidRequest
        }

        let (data, response) = try await URLSession.shared.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AppNotificationEventServiceError.invalidResponse
        }
        guard (200 ... 299).contains(httpResponse.statusCode) else {
            throw AppNotificationEventServiceError.requestFailed("Notification backend request failed (\(httpResponse.statusCode)).")
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let payload = try decoder.decode(NotificationEventsResponse.self, from: data)
        return payload.items
    }

    private func updateEventsViaBackend(eventIDs: [UUID], userID: String, path: String, bodyKey: String) async throws -> Bool {
        let ids = eventIDs.map(\.uuidString)
        guard !ids.isEmpty else { return true }
        guard let url = backendURL(path: path) else {
            throw AppNotificationEventServiceError.invalidRequest
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "user_id": userID,
            bodyKey: ids,
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AppNotificationEventServiceError.invalidResponse
        }
        guard (200 ... 299).contains(httpResponse.statusCode) else {
            throw AppNotificationEventServiceError.requestFailed("Notification backend request failed (\(httpResponse.statusCode)).")
        }
        _ = data
        return true
    }

    private func fetchEventsViaSupabase(
        userID: String,
        accessToken: String?,
        deliveredOnly: Bool,
        limit: Int
    ) async throws -> [AppNotificationEvent] {
        guard let encodedUserID = userID.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            throw AppNotificationEventServiceError.invalidRequest
        }
        let filter = deliveredOnly ? "&delivered_at=is.null" : ""
        guard let url = URL(
            string: "\(SupabaseConfig.url)/rest/v1/app_notification_events?select=*&user_id=eq.\(encodedUserID)\(filter)&order=created_at.desc,scheduled_for.desc&limit=\(limit)"
        ) else {
            throw AppNotificationEventServiceError.invalidRequest
        }

        guard let accessToken = accessToken?.trimmingCharacters(in: .whitespacesAndNewlines), !accessToken.isEmpty else {
            throw AppNotificationEventServiceError.unauthorized
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(SupabaseConfig.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AppNotificationEventServiceError.invalidResponse
        }
        if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
            throw AppNotificationEventServiceError.unauthorized
        }
        guard (200 ... 299).contains(httpResponse.statusCode) else {
            let errorPayload = try? JSONDecoder().decode(SupabaseRestErrorResponse.self, from: data)
            let fallback = deliveredOnly ? "Failed to load app notifications (\(httpResponse.statusCode))." : "Failed to load recent app notifications (\(httpResponse.statusCode))."
            throw AppNotificationEventServiceError.requestFailed(errorPayload?.message ?? errorPayload?.error ?? fallback)
        }
        return try decoder.decode([AppNotificationEvent].self, from: data)
    }

    private func updateViaSupabase(eventIDs: [UUID], accessToken: String?, bodyKey: String) async throws {
        let ids = eventIDs.map(\.uuidString)
        guard !ids.isEmpty else { return }
        guard let accessToken = accessToken?.trimmingCharacters(in: .whitespacesAndNewlines), !accessToken.isEmpty else {
            throw AppNotificationEventServiceError.unauthorized
        }
        let joined = ids.map { "\"\($0)\"" }.joined(separator: ",")
        let clause = "(\(joined))"
        let encodedClause = clause.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? clause
        guard let url = URL(string: "\(SupabaseConfig.url)/rest/v1/app_notification_events?id=in.\(encodedClause)") else {
            throw AppNotificationEventServiceError.invalidRequest
        }

        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(SupabaseConfig.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let now = ISO8601DateFormatter().string(from: .now)
        request.httpBody = try JSONEncoder().encode([bodyKey: now])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AppNotificationEventServiceError.invalidResponse
        }

        guard (200 ... 299).contains(httpResponse.statusCode) else {
            let errorPayload = try? JSONDecoder().decode(SupabaseRestErrorResponse.self, from: data)
            let fallback = "Failed to update app notifications (\(httpResponse.statusCode))."
            throw AppNotificationEventServiceError.requestFailed(errorPayload?.message ?? errorPayload?.error ?? fallback)
        }
    }

    private func createEventViaBackend(
        userID: String,
        kind: String,
        dedupeKey: String,
        title: String,
        body: String,
        subtitle: String?,
        imageURLString: String?,
        actionURLString: String?,
        actionLabel: String?,
        orderID: UUID?,
        planID: UUID?,
        recipeID: String?,
        metadata: [String: String],
        scheduledFor: Date
    ) async throws -> Bool {
        guard let url = backendURL(path: "/v1/notifications") else {
            throw AppNotificationEventServiceError.invalidRequest
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let formatter = ISO8601DateFormatter()
        let payload = AppNotificationEventWritePayload(
            userID: userID,
            kind: kind,
            dedupeKey: dedupeKey,
            title: title,
            body: body,
            subtitle: subtitle,
            imageURLString: imageURLString,
            actionURLString: actionURLString,
            actionLabel: actionLabel,
            orderID: orderID?.uuidString,
            planID: planID?.uuidString,
            recipeID: recipeID,
            metadata: metadata,
            scheduledFor: formatter.string(from: scheduledFor)
        )
        request.httpBody = try JSONEncoder().encode(["event": payload])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AppNotificationEventServiceError.invalidResponse
        }
        guard (200 ... 299).contains(httpResponse.statusCode) else {
            let errorPayload = try? JSONDecoder().decode(SupabaseRestErrorResponse.self, from: data)
            throw AppNotificationEventServiceError.requestFailed(errorPayload?.message ?? errorPayload?.error ?? "Failed to write app notification (\(httpResponse.statusCode)).")
        }
        return true
    }

    private func createEventViaSupabase(
        userID: String,
        accessToken: String,
        kind: String,
        dedupeKey: String,
        title: String,
        body: String,
        subtitle: String? = nil,
        imageURLString: String? = nil,
        actionURLString: String? = nil,
        actionLabel: String? = nil,
        orderID: UUID? = nil,
        planID: UUID? = nil,
        recipeID: String? = nil,
        metadata: [String: String] = [:],
        scheduledFor: Date = .now
    ) async throws {
        guard let url = URL(string: "\(SupabaseConfig.url)/rest/v1/app_notification_events?on_conflict=user_id,dedupe_key") else {
            throw AppNotificationEventServiceError.invalidRequest
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("resolution=merge-duplicates", forHTTPHeaderField: "Prefer")
        request.setValue(SupabaseConfig.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let formatter = ISO8601DateFormatter()
        request.httpBody = try JSONEncoder().encode([
            AppNotificationEventWritePayload(
                userID: userID,
                kind: kind,
                dedupeKey: dedupeKey,
                title: title,
                body: body,
                subtitle: subtitle,
                imageURLString: imageURLString,
                actionURLString: actionURLString,
                actionLabel: actionLabel,
                orderID: orderID?.uuidString,
                planID: planID?.uuidString,
                recipeID: recipeID,
                metadata: metadata,
                scheduledFor: formatter.string(from: scheduledFor)
            )
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AppNotificationEventServiceError.invalidResponse
        }
        guard (200 ... 299).contains(httpResponse.statusCode) else {
            let errorPayload = try? JSONDecoder().decode(SupabaseRestErrorResponse.self, from: data)
            let fallback = "Failed to write app notification (\(httpResponse.statusCode))."
            throw AppNotificationEventServiceError.requestFailed(errorPayload?.message ?? errorPayload?.error ?? fallback)
        }
    }

    private struct NotificationEventsResponse: Decodable {
        let items: [AppNotificationEvent]
    }
}

private extension AppNotificationEvent {
    var isHiddenFromNotifications: Bool {
        metadata?["hidden_from_notifications"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "true"
    }
}
