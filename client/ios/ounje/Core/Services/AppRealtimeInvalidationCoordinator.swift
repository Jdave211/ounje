import SwiftUI
import Foundation

struct AppRealtimeInvalidationEvent {
    let name: String
    let payload: [String: Any]

    func string(_ key: String) -> String? {
        let value = payload[key]
        let string = String(describing: value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !string.isEmpty, string != "nil", string != "<null>" else { return nil }
        return string
    }

    func uuid(_ key: String) -> UUID? {
        guard let raw = string(key) else { return nil }
        return UUID(uuidString: raw)
    }
}

@MainActor
final class AppRealtimeInvalidationCoordinator: ObservableObject {
    @Published private(set) var isRunning = false

    private var activeKey: String?
    private var activeSession: AuthSession?
    private var activeHandler: (@MainActor (AppRealtimeInvalidationEvent) async -> Void)?
    private var client: SupabaseRealtimeBroadcastClient?
    private var reconnectTask: Task<Void, Never>?
    private var debounceTasks: [String: Task<Void, Never>] = [:]

    func connect(
        session: AuthSession?,
        onEvent: @escaping @MainActor (AppRealtimeInvalidationEvent) async -> Void
    ) {
        guard let session else {
            disconnect()
            return
        }

        let userID = session.userID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !userID.isEmpty else {
            disconnect()
            return
        }

        let nextKey = "\(userID)::\(session.accessToken ?? "anon")"
        if activeKey == nextKey, client != nil {
            activeSession = session
            activeHandler = onEvent
            return
        }

        disconnect()
        activeKey = nextKey
        activeSession = session
        activeHandler = onEvent

        let nextClient = SupabaseRealtimeBroadcastClient(
            userID: userID,
            accessToken: session.accessToken
        ) { [weak self] event in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.schedule(event, onEvent: self.activeHandler ?? onEvent)
            }
        } onConnected: { [weak self] in
            Task { @MainActor [weak self] in
                self?.markRealtimeConnected(for: nextKey)
            }
        } onClose: { [weak self] in
            Task { @MainActor [weak self] in
                self?.handleRealtimeClose(for: nextKey)
            }
        }

        client = nextClient
        isRunning = false
        nextClient.start()
    }

    func disconnect() {
        activeKey = nil
        activeSession = nil
        activeHandler = nil
        isRunning = false
        reconnectTask?.cancel()
        reconnectTask = nil
        debounceTasks.values.forEach { $0.cancel() }
        debounceTasks.removeAll()
        client?.stop()
        client = nil
    }

    private func markRealtimeConnected(for key: String) {
        guard activeKey == key, client != nil else { return }
        isRunning = true
    }

    private func handleRealtimeClose(for key: String) {
        guard activeKey == key else { return }
        isRunning = false
        let closingClient = client
        client = nil
        closingClient?.stop()
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        guard activeKey != nil,
              let session = activeSession,
              let handler = activeHandler else {
            return
        }

        reconnectTask?.cancel()
        reconnectTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled, let self else { return }
            self.activeKey = nil
            self.connect(session: session, onEvent: handler)
        }
    }

    private func schedule(
        _ event: AppRealtimeInvalidationEvent,
        onEvent: @escaping @MainActor (AppRealtimeInvalidationEvent) async -> Void
    ) {
        let bucket = debounceBucket(for: event.name)
        debounceTasks[bucket]?.cancel()
        debounceTasks[bucket] = Task { @MainActor in
            try? await Task.sleep(nanoseconds: debounceDelay(for: event.name))
            guard !Task.isCancelled else { return }
            await onEvent(event)
            debounceTasks[bucket] = nil
        }
    }

    private func debounceBucket(for eventName: String) -> String {
        if eventName.hasPrefix("recipe_import.") { return "recipe_import" }
        if eventName == "instacart_run.updated" || eventName == "grocery_order.updated" { return "tracking" }
        if eventName == "notification.updated" { return "notification" }
        if eventName == "main_shop_snapshot.updated" || eventName == "meal_prep_cycle.updated" || eventName == "prep.updated" { return "prep" }
        return eventName
    }

    private func debounceDelay(for eventName: String) -> UInt64 {
        if eventName.hasPrefix("recipe_import.") { return 350_000_000 }
        if eventName == "instacart_run.updated" || eventName == "grocery_order.updated" { return 450_000_000 }
        return 250_000_000
    }
}

private final class SupabaseRealtimeBroadcastClient {
    private let userID: String
    private let accessToken: String?
    private let onEvent: (AppRealtimeInvalidationEvent) -> Void
    private let onConnected: () -> Void
    private let onClose: () -> Void
    private let session = URLSession(configuration: .ephemeral)
    private var webSocketTask: URLSessionWebSocketTask?
    private var heartbeatTask: Task<Void, Never>?
    private var refCounter = 0
    private var joinRef: String?
    private var isStopped = false

    private var channelName: String {
        "ounje:user:\(userID)"
    }

    private var topic: String {
        "realtime:\(channelName)"
    }

    init(
        userID: String,
        accessToken: String?,
        onEvent: @escaping (AppRealtimeInvalidationEvent) -> Void,
        onConnected: @escaping () -> Void,
        onClose: @escaping () -> Void
    ) {
        self.userID = userID
        self.accessToken = accessToken
        self.onEvent = onEvent
        self.onConnected = onConnected
        self.onClose = onClose
    }

    func start() {
        guard webSocketTask == nil else { return }
        guard let url = Self.websocketURL() else {
            onClose()
            return
        }

        let task = session.webSocketTask(with: url)
        webSocketTask = task
        isStopped = false
        task.resume()
        sendJoin()
        startHeartbeat()
        receiveNext()
    }

    func stop() {
        isStopped = true
        heartbeatTask?.cancel()
        heartbeatTask = nil
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
    }

    private static func websocketURL() -> URL? {
        guard var components = URLComponents(string: SupabaseConfig.url) else { return nil }
        components.scheme = components.scheme == "http" ? "ws" : "wss"
        components.path = "/realtime/v1/websocket"
        components.queryItems = [
            URLQueryItem(name: "apikey", value: SupabaseConfig.anonKey),
            URLQueryItem(name: "vsn", value: "2.0.0"),
            URLQueryItem(name: "log_level", value: "error"),
        ]
        return components.url
    }

    private func nextRef() -> String {
        refCounter += 1
        return "\(refCounter)"
    }

    private func sendJoin() {
        let ref = nextRef()
        joinRef = ref
        sendFrame(
            joinRef: ref,
            ref: ref,
            topic: topic,
            event: "phx_join",
            payload: [
                "config": [
                    "broadcast": [
                        "ack": false,
                        "self": false,
                    ],
                    "presence": [
                        "enabled": false,
                    ],
                    "postgres_changes": [],
                    "private": false,
                ],
                "access_token": accessToken ?? SupabaseConfig.anonKey,
            ]
        )
    }

    private func startHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 22_000_000_000)
                guard !Task.isCancelled else { return }
                self?.sendFrame(
                    joinRef: nil,
                    ref: self?.nextRef(),
                    topic: "phoenix",
                    event: "heartbeat",
                    payload: [:]
                )
            }
        }
    }

    private func sendFrame(joinRef: String?, ref: String?, topic: String, event: String, payload: [String: Any]) {
        let frame: [Any] = [
            joinRef ?? NSNull(),
            ref ?? NSNull(),
            topic,
            event,
            payload,
        ]

        guard JSONSerialization.isValidJSONObject(frame),
              let data = try? JSONSerialization.data(withJSONObject: frame),
              let string = String(data: data, encoding: .utf8) else {
            return
        }

        webSocketTask?.send(.string(string)) { _ in }
    }

    private func receiveNext() {
        webSocketTask?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case let .success(message):
                self.handle(message)
                if !self.isStopped {
                    self.receiveNext()
                }
            case .failure:
                if !self.isStopped {
                    self.onClose()
                }
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        switch message {
        case let .string(raw):
            handleTextFrame(raw)
        case let .data(data):
            handleBinaryFrame(data)
        @unknown default:
            break
        }
    }

    private func handleTextFrame(_ raw: String) {
        guard let data = raw.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [Any],
              array.count >= 5,
              let frameTopic = array[2] as? String,
              frameTopic == topic,
              let frameEvent = array[3] as? String,
              let payload = array[4] as? [String: Any] else {
            return
        }

        if frameEvent == "phx_reply",
           let frameRef = array[1] as? String,
           frameRef == joinRef,
           let status = payload["status"] as? String,
           status == "ok" {
            onConnected()
            return
        }

        guard frameEvent == "broadcast",
              let eventName = payload["event"] as? String else {
            return
        }

        let eventPayload = payload["payload"] as? [String: Any] ?? [:]
        onEvent(AppRealtimeInvalidationEvent(name: eventName, payload: eventPayload))
    }

    private func handleBinaryFrame(_ data: Data) {
        let bytes = [UInt8](data)
        guard bytes.count > 5, bytes[0] == 4 else { return }

        let topicSize = Int(bytes[1])
        let eventSize = Int(bytes[2])
        let metadataSize = Int(bytes[3])
        let payloadEncoding = bytes[4]
        guard payloadEncoding == 1 else { return }

        var offset = 5
        guard let frameTopic = readString(bytes: bytes, offset: &offset, count: topicSize),
              frameTopic == topic,
              let eventName = readString(bytes: bytes, offset: &offset, count: eventSize) else {
            return
        }

        _ = readString(bytes: bytes, offset: &offset, count: metadataSize)
        guard offset <= bytes.count else { return }
        let payloadData = Data(bytes[offset...])
        let payload = (try? JSONSerialization.jsonObject(with: payloadData)) as? [String: Any] ?? [:]
        onEvent(AppRealtimeInvalidationEvent(name: eventName, payload: payload))
    }

    private func readString(bytes: [UInt8], offset: inout Int, count: Int) -> String? {
        guard count >= 0, offset + count <= bytes.count else { return nil }
        let slice = bytes[offset..<(offset + count)]
        offset += count
        return String(bytes: slice, encoding: .utf8)
    }
}

func sanitizedInstacartStoreName(_ value: String?) -> String? {
    let trimmed = String(value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    let lower = trimmed.lowercased()
    let allowlistedHints = [
        "metro",
        "no frills",
        "freshco",
        "food basics",
        "sobeys",
        "loblaws",
        "walmart",
        "costco",
        "real canadian superstore",
        "shoppers drug mart",
        "giant tiger",
        "adonis",
        "save on foods",
        "whole foods market"
    ]
    if allowlistedHints.contains(lower) {
        return trimmed
    }

    let storeishTerms = [
        "store", "market", "mart", "grocery", "grocer", "grocers", "foods", "superstore",
        "supermarket", "drug", "pharmacy", "wholesale", "express", "centre", "center"
    ]
    if storeishTerms.contains(where: { lower.contains($0) }) {
        return trimmed
    }

    let productishTerms = [
        "all purpose flour", "flour", "garlic", "onion", "chicken", "beef", "pork", "shrimp",
        "salmon", "tuna", "bread", "oil", "sauce", "salt", "pepper", "sugar", "honey", "rice",
        "pasta", "miso", "juice", "stock", "broth", "butter", "milk", "cheese", "cream", "yogurt",
        "lettuce", "cilantro", "parsley", "basil", "ginger", "cucumber", "potato", "tomato",
        "jalapeno", "chili", "paprika", "seasoning", "spice", "vanilla", "cinnamon"
    ]
    if productishTerms.contains(where: { lower.contains($0) }) {
        return nil
    }

    if ["true", "false", "null", "none", "undefined"].contains(lower) {
        return nil
    }

    if lower.hasPrefix("delivery by") || lower.hasPrefix("pickup by") || lower.hasPrefix("current price") || lower.hasPrefix("add ") {
        return nil
    }

    if trimmed.rangeOfCharacter(from: .letters) == nil {
        return nil
    }

    return trimmed
}
