import Foundation

/// Thrown when the server returns 409 because an Instacart run is already
/// queued or running for this user. The caller should refresh tracking state
/// instead of treating it as a real error.
struct InstacartRunAlreadyInProgressError: Error {}

struct InstacartRunLogsListResponse: Codable {
    let items: [InstacartRunLogSummary]
    let total: Int
    let offset: Int
    let limit: Int
    let hasMore: Bool
    let query: String?
    let status: String?
    let userID: String?

    enum CodingKeys: String, CodingKey {
        case items
        case total
        case offset
        case limit
        case hasMore
        case query
        case status
        case userID = "userID"
    }
}

struct InstacartRunLogSummaryResponse: Decodable {
    let summary: InstacartRunLogSummary
}

struct InstacartCurrentRunSummaryResponse: Decodable {
    let summary: InstacartRunLogSummary?
}

struct InstacartRunLogStorageRow: Decodable {
    let runID: String
    let userID: String?
    let statusKind: String?
    let summaryJSON: InstacartRunLogSummary?
    let startedAt: String?
    let completedAt: String?
    let progress: Double?

    enum CodingKeys: String, CodingKey {
        case runID = "run_id"
        case userID = "user_id"
        case statusKind = "status_kind"
        case summaryJSON = "summary_json"
        case startedAt = "started_at"
        case completedAt = "completed_at"
        case progress
    }

    var resolvedSummary: InstacartRunLogSummary {
        if let summaryJSON {
            return summaryJSON.merged(
                runID: runID,
                userID: userID,
                statusKind: statusKind,
                startedAt: startedAt,
                completedAt: completedAt,
                progress: progress
            )
        }

        return InstacartRunLogSummary(
            runId: runID,
            userId: userID,
            startedAt: startedAt,
            completedAt: completedAt,
            mealPlanID: nil,
            groceryOrderIDString: nil,
            selectedStore: nil,
            selectedStoreLogoURLString: nil,
            selectedStoreReason: nil,
            latestEventKind: nil,
            latestEventTitle: nil,
            latestEventBody: nil,
            latestEventAt: nil,
            preferredStore: nil,
            strictStore: nil,
            sessionSource: nil,
            runKind: nil,
            rootRunID: nil,
            retryAttempt: nil,
            retryState: nil,
            retryQueuedAt: nil,
            retryStartedAt: nil,
            retryCompletedAt: nil,
            retryRunID: nil,
            retryItemCount: nil,
            success: false,
            partialSuccess: false,
            statusKind: statusKind ?? "failed",
            itemCount: 0,
            resolvedCount: 0,
            unresolvedCount: 0,
            shortfallCount: 0,
            attemptCount: 0,
            durationSeconds: nil,
            progress: progress ?? 0,
            topIssue: nil,
            searchPreview: nil,
            matches: nil,
            shoppingPreview: nil,
            cartUrl: nil
        )
    }
}

struct InstacartRunTraceStorageRow: Decodable {
    let runID: String
    let userID: String?
    let traceJSON: InstacartRunTracePayload?

    enum CodingKeys: String, CodingKey {
        case runID = "run_id"
        case userID = "user_id"
        case traceJSON = "trace_json"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        runID = container.lossyString(forKey: .runID) ?? ""
        userID = container.lossyString(forKey: .userID)
        traceJSON = container.lossyDecodable(forKey: .traceJSON, as: InstacartRunTracePayload.self)
    }
}

struct InstacartRunLogSummary: Identifiable, Codable {
    let runId: String
    let userId: String?
    let startedAt: String?
    let completedAt: String?
    let mealPlanID: String?
    let groceryOrderIDString: String?
    let selectedStore: String?
    let selectedStoreLogoURLString: String?
    let selectedStoreReason: String?
    let latestEventKind: String?
    let latestEventTitle: String?
    let latestEventBody: String?
    let latestEventAt: String?
    let preferredStore: String?
    let strictStore: String?
    let sessionSource: String?
    let runKind: String?
    let rootRunID: String?
    let retryAttempt: Int?
    let retryState: String?
    let retryQueuedAt: String?
    let retryStartedAt: String?
    let retryCompletedAt: String?
    let retryRunID: String?
    let retryItemCount: Int?
    let success: Bool
    let partialSuccess: Bool
    let statusKind: String
    let itemCount: Int
    let resolvedCount: Int
    let unresolvedCount: Int
    let shortfallCount: Int
    let attemptCount: Int
    let durationSeconds: Int?
    let progress: Double
    let topIssue: String?
    let searchPreview: String?
    let matches: [String]?
    let shoppingPreview: [String]?
    let cartUrl: String?

    enum CodingKeys: String, CodingKey {
        case runId
        case userId
        case startedAt
        case completedAt
        case mealPlanID
        case groceryOrderIDString = "groceryOrderID"
        case selectedStore
        case selectedStoreLogoURLString = "selectedStoreLogoURL"
        case selectedStoreReason
        case latestEventKind
        case latestEventTitle
        case latestEventBody
        case latestEventAt
        case preferredStore
        case strictStore
        case sessionSource
        case runKind
        case rootRunID
        case retryAttempt
        case retryState
        case retryQueuedAt
        case retryStartedAt
        case retryCompletedAt
        case retryRunID
        case retryItemCount
        case success
        case partialSuccess
        case statusKind
        case itemCount
        case resolvedCount
        case unresolvedCount
        case shortfallCount
        case attemptCount
        case durationSeconds
        case progress
        case topIssue
        case searchPreview
        case matches
        case shoppingPreview
        case cartUrl
    }

    init(
        runId: String,
        userId: String?,
        startedAt: String?,
        completedAt: String?,
        mealPlanID: String?,
        groceryOrderIDString: String?,
        selectedStore: String?,
        selectedStoreLogoURLString: String?,
        selectedStoreReason: String?,
        latestEventKind: String?,
        latestEventTitle: String?,
        latestEventBody: String?,
        latestEventAt: String?,
        preferredStore: String?,
        strictStore: String?,
        sessionSource: String?,
        runKind: String?,
        rootRunID: String?,
        retryAttempt: Int?,
        retryState: String?,
        retryQueuedAt: String?,
        retryStartedAt: String?,
        retryCompletedAt: String?,
        retryRunID: String?,
        retryItemCount: Int?,
        success: Bool,
        partialSuccess: Bool,
        statusKind: String,
        itemCount: Int,
        resolvedCount: Int,
        unresolvedCount: Int,
        shortfallCount: Int,
        attemptCount: Int,
        durationSeconds: Int?,
        progress: Double,
        topIssue: String?,
        searchPreview: String?,
        matches: [String]?,
        shoppingPreview: [String]?,
        cartUrl: String?
    ) {
        self.runId = runId
        self.userId = userId
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.mealPlanID = mealPlanID
        self.groceryOrderIDString = groceryOrderIDString
        self.selectedStore = selectedStore
        self.selectedStoreLogoURLString = selectedStoreLogoURLString
        self.selectedStoreReason = selectedStoreReason
        self.latestEventKind = latestEventKind
        self.latestEventTitle = latestEventTitle
        self.latestEventBody = latestEventBody
        self.latestEventAt = latestEventAt
        self.preferredStore = preferredStore
        self.strictStore = strictStore
        self.sessionSource = sessionSource
        self.runKind = runKind
        self.rootRunID = rootRunID
        self.retryAttempt = retryAttempt
        self.retryState = retryState
        self.retryQueuedAt = retryQueuedAt
        self.retryStartedAt = retryStartedAt
        self.retryCompletedAt = retryCompletedAt
        self.retryRunID = retryRunID
        self.retryItemCount = retryItemCount
        self.success = success
        self.partialSuccess = partialSuccess
        self.statusKind = statusKind
        self.itemCount = itemCount
        self.resolvedCount = resolvedCount
        self.unresolvedCount = unresolvedCount
        self.shortfallCount = shortfallCount
        self.attemptCount = attemptCount
        self.durationSeconds = durationSeconds
        self.progress = progress
        self.topIssue = topIssue
        self.searchPreview = searchPreview
        self.matches = matches
        self.shoppingPreview = shoppingPreview
        self.cartUrl = cartUrl
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        runId = container.lossyString(forKey: .runId) ?? ""
        userId = container.lossyString(forKey: .userId)
        startedAt = container.lossyString(forKey: .startedAt)
        completedAt = container.lossyString(forKey: .completedAt)
        mealPlanID = container.lossyString(forKey: .mealPlanID)
        groceryOrderIDString = container.lossyString(forKey: .groceryOrderIDString)
        selectedStore = container.lossyString(forKey: .selectedStore)
        selectedStoreLogoURLString = container.lossyString(forKey: .selectedStoreLogoURLString)
        selectedStoreReason = container.lossyString(forKey: .selectedStoreReason)
        latestEventKind = container.lossyString(forKey: .latestEventKind)
        latestEventTitle = container.lossyString(forKey: .latestEventTitle)
        latestEventBody = container.lossyString(forKey: .latestEventBody)
        latestEventAt = container.lossyString(forKey: .latestEventAt)
        preferredStore = container.lossyString(forKey: .preferredStore)
        strictStore = container.lossyString(forKey: .strictStore)
        sessionSource = container.lossyString(forKey: .sessionSource)
        runKind = container.lossyString(forKey: .runKind)
        rootRunID = container.lossyString(forKey: .rootRunID)
        retryAttempt = container.lossyInt(forKey: .retryAttempt)
        retryState = container.lossyString(forKey: .retryState)
        retryQueuedAt = container.lossyString(forKey: .retryQueuedAt)
        retryStartedAt = container.lossyString(forKey: .retryStartedAt)
        retryCompletedAt = container.lossyString(forKey: .retryCompletedAt)
        retryRunID = container.lossyString(forKey: .retryRunID)
        retryItemCount = container.lossyInt(forKey: .retryItemCount)
        success = container.lossyBool(forKey: .success) ?? false
        partialSuccess = container.lossyBool(forKey: .partialSuccess) ?? false
        statusKind = container.lossyString(forKey: .statusKind) ?? "failed"
        itemCount = container.lossyInt(forKey: .itemCount) ?? 0
        resolvedCount = container.lossyInt(forKey: .resolvedCount) ?? 0
        unresolvedCount = container.lossyInt(forKey: .unresolvedCount) ?? 0
        shortfallCount = container.lossyInt(forKey: .shortfallCount) ?? 0
        attemptCount = container.lossyInt(forKey: .attemptCount) ?? 0
        durationSeconds = container.lossyInt(forKey: .durationSeconds)
        if let value = try? container.decodeIfPresent(Double.self, forKey: .progress) {
            progress = value
        } else if let value = try? container.decodeIfPresent(Int.self, forKey: .progress) {
            progress = Double(value)
        } else if let value = try? container.decodeIfPresent(String.self, forKey: .progress),
                  let parsed = Double(value.trimmingCharacters(in: .whitespacesAndNewlines)) {
            progress = parsed
        } else {
            progress = 0
        }
        topIssue = container.lossyString(forKey: .topIssue)
        searchPreview = container.lossyString(forKey: .searchPreview)
        if let values = try? container.decodeIfPresent([String].self, forKey: .matches) {
            matches = values
        } else if let single = container.lossyString(forKey: .matches) {
            matches = [single]
        } else {
            matches = nil
        }
        if let values = try? container.decodeIfPresent([String].self, forKey: .shoppingPreview) {
            shoppingPreview = values
        } else if let single = container.lossyString(forKey: .shoppingPreview) {
            shoppingPreview = [single]
        } else {
            shoppingPreview = nil
        }
        cartUrl = container.lossyString(forKey: .cartUrl)
    }

    var id: String { runId }

    var normalizedStatusKind: String {
        statusKind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    var normalizedRunKind: String {
        runKind?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "primary"
    }

    var normalizedRetryState: String {
        retryState?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
    }

    var linkedGroceryOrderID: UUID? {
        guard let raw = groceryOrderIDString?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return nil
        }
        return UUID(uuidString: raw)
    }

    var trackingURL: URL? {
        guard let cartUrl, !cartUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return URL(string: cartUrl)
    }

    var selectedStoreLogoURL: URL? {
        guard let raw = selectedStoreLogoURLString?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty
        else { return nil }
        return URL(string: raw)
    }

    fileprivate func merged(
        runID: String,
        userID: String?,
        statusKind: String?,
        startedAt: String?,
        completedAt: String?,
        progress: Double?
    ) -> InstacartRunLogSummary {
        InstacartRunLogSummary(
            runId: self.runId.isEmpty ? runID : self.runId,
            userId: self.userId ?? userID,
            startedAt: self.startedAt ?? startedAt,
            completedAt: self.completedAt ?? completedAt,
            mealPlanID: mealPlanID,
            groceryOrderIDString: groceryOrderIDString,
            selectedStore: selectedStore,
            selectedStoreLogoURLString: selectedStoreLogoURLString,
            selectedStoreReason: selectedStoreReason,
            latestEventKind: latestEventKind,
            latestEventTitle: latestEventTitle,
            latestEventBody: latestEventBody,
            latestEventAt: latestEventAt,
            preferredStore: preferredStore,
            strictStore: strictStore,
            sessionSource: sessionSource,
            runKind: runKind,
            rootRunID: rootRunID,
            retryAttempt: retryAttempt,
            retryState: retryState,
            retryQueuedAt: retryQueuedAt,
            retryStartedAt: retryStartedAt,
            retryCompletedAt: retryCompletedAt,
            retryRunID: retryRunID,
            retryItemCount: retryItemCount,
            success: success,
            partialSuccess: partialSuccess,
            statusKind: self.statusKind.isEmpty ? (statusKind ?? "failed") : self.statusKind,
            itemCount: itemCount,
            resolvedCount: resolvedCount,
            unresolvedCount: unresolvedCount,
            shortfallCount: shortfallCount,
            attemptCount: attemptCount,
            durationSeconds: durationSeconds,
            progress: self.progress > 0 ? self.progress : (progress ?? self.progress),
            topIssue: topIssue,
            searchPreview: searchPreview,
            matches: matches,
            shoppingPreview: shoppingPreview,
            cartUrl: cartUrl
        )
    }
}

struct GroceryOrderSummaryRecord: Identifiable, Decodable {
    let id: UUID
    let provider: String
    let status: String
    let statusMessage: String?
    let totalCents: Int?
    let createdAt: Date?
    let completedAt: Date?
    let providerTrackingURLString: String?
    let trackingStatus: String?
    let trackingTitle: String?
    let trackingDetail: String?
    let trackingEtaText: String?
    let trackingImageURLString: String?
    let lastTrackedAt: Date?
    let deliveredAt: Date?
    let stepLog: [GroceryOrderStepLogEntry]?
    let orderItems: [GroceryOrderItemRecord]?

    enum CodingKeys: String, CodingKey {
        case id
        case provider
        case status
        case statusMessage = "status_message"
        case totalCents = "total_cents"
        case createdAt = "created_at"
        case completedAt = "completed_at"
        case providerTrackingURLString = "provider_tracking_url"
        case trackingStatus = "tracking_status"
        case trackingTitle = "tracking_title"
        case trackingDetail = "tracking_detail"
        case trackingEtaText = "tracking_eta_text"
        case trackingImageURLString = "tracking_image_url"
        case lastTrackedAt = "last_tracked_at"
        case deliveredAt = "delivered_at"
        case stepLog = "step_log"
        case orderItems = "order_items"
    }

    var normalizedProvider: String {
        provider.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    var normalizedTrackingStatus: String {
        trackingStatus?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "unknown"
    }

    var needsTrackingRefresh: Bool {
        guard normalizedProvider == "instacart" else { return false }
        guard deliveredAt == nil else { return false }
        if normalizedTrackingStatus == "delivered" { return false }
        if let lastTrackedAt {
            return abs(lastTrackedAt.timeIntervalSinceNow) >= 15 * 60
        }
        return completedAt != nil || status.caseInsensitiveCompare("completed") == .orderedSame
    }

    var latestStepLogEntry: GroceryOrderStepLogEntry? {
        stepLog?.last
    }
}

struct GroceryOrderItemRecord: Identifiable, Decodable, Hashable {
    let id: UUID
    let orderID: UUID?
    let requestedName: String
    let requestedAmount: Double?
    let requestedUnit: String?
    let status: String
    let matchedName: String?
    let matchedProductID: String?
    let matchedBrand: String?
    let unitPriceCents: Int?
    let quantity: Int?
    let totalPriceCents: Int?
    let imageURLString: String?
    let matchConfidence: Double?
    let createdAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case orderID = "order_id"
        case requestedName = "requested_name"
        case requestedAmount = "requested_amount"
        case requestedUnit = "requested_unit"
        case status
        case matchedName = "matched_name"
        case matchedProductID = "matched_product_id"
        case matchedBrand = "matched_brand"
        case unitPriceCents = "unit_price_cents"
        case quantity
        case totalPriceCents = "total_price_cents"
        case imageURLString = "image_url"
        case matchConfidence = "match_confidence"
        case createdAt = "created_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        orderID = try container.decodeIfPresent(UUID.self, forKey: .orderID)
        requestedName = (try container.decodeIfPresent(String.self, forKey: .requestedName) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        requestedAmount = try container.decodeIfPresent(Double.self, forKey: .requestedAmount)
        requestedUnit = try container.decodeIfPresent(String.self, forKey: .requestedUnit)?.trimmingCharacters(in: .whitespacesAndNewlines)
        status = (try container.decodeIfPresent(String.self, forKey: .status) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        matchedName = try container.decodeIfPresent(String.self, forKey: .matchedName)?.trimmingCharacters(in: .whitespacesAndNewlines)
        matchedProductID = try container.decodeIfPresent(String.self, forKey: .matchedProductID)?.trimmingCharacters(in: .whitespacesAndNewlines)
        matchedBrand = try container.decodeIfPresent(String.self, forKey: .matchedBrand)?.trimmingCharacters(in: .whitespacesAndNewlines)
        unitPriceCents = try container.decodeIfPresent(Int.self, forKey: .unitPriceCents)
        quantity = try container.decodeIfPresent(Int.self, forKey: .quantity)
        totalPriceCents = try container.decodeIfPresent(Int.self, forKey: .totalPriceCents)
        imageURLString = try container.decodeIfPresent(String.self, forKey: .imageURLString)?.trimmingCharacters(in: .whitespacesAndNewlines)
        matchConfidence = try container.decodeIfPresent(Double.self, forKey: .matchConfidence)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt)
    }

    var imageURL: URL? {
        guard let imageURLString, !imageURLString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return URL(string: imageURLString)
    }
}

struct GroceryOrderStepLogEntry: Decodable, Hashable {
    let status: String?
    let kind: String?
    let title: String?
    let body: String?
    let at: String?

    enum CodingKeys: String, CodingKey {
        case status
        case kind
        case title
        case body
        case at
    }

    var displayTitle: String? {
        let value = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (value?.isEmpty == false) ? value : nil
    }

    var displayBody: String? {
        let value = body?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (value?.isEmpty == false) ? value : nil
    }
}

struct GroceryOrdersListResponse: Decodable {
    let orders: [GroceryOrderSummaryRecord]
}

struct InstacartRunTracePayload: Decodable {
    let runId: String
    let userId: String?
    let startedAt: String?
    let completedAt: String?
    let selectedStore: String?
    let preferredStore: String?
    let strictStore: String?
    let sessionSource: String?
    let success: Bool
    let partialSuccess: Bool
    let items: [InstacartRunLogItemPayload]
    let cartUrl: String?

    enum CodingKeys: String, CodingKey {
        case runId
        case userId
        case startedAt
        case completedAt
        case selectedStore
        case preferredStore
        case strictStore
        case sessionSource
        case success
        case partialSuccess
        case items
        case cartUrl
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        runId = container.lossyString(forKey: .runId) ?? ""
        userId = container.lossyString(forKey: .userId)
        startedAt = container.lossyString(forKey: .startedAt)
        completedAt = container.lossyString(forKey: .completedAt)
        selectedStore = container.lossyString(forKey: .selectedStore)
        preferredStore = container.lossyString(forKey: .preferredStore)
        strictStore = container.lossyString(forKey: .strictStore)
        sessionSource = container.lossyString(forKey: .sessionSource)
        success = container.lossyBool(forKey: .success) ?? false
        partialSuccess = container.lossyBool(forKey: .partialSuccess) ?? false
        items = container.lossyDecodableArray(forKey: .items, as: InstacartRunLogItemPayload.self) ?? []
        cartUrl = container.lossyString(forKey: .cartUrl)
    }
}

struct InstacartRunLogDetailPayload {
    let summary: InstacartRunLogSummary
    let trace: InstacartRunTracePayload
}

struct InstacartRunTraceResponse: Decodable {
    let trace: InstacartRunTracePayload
}

struct InstacartRunSelectionTracePayload: Decodable {
    let selectedCandidate: InstacartRunSelectionCandidatePayload?
    let fallbackCandidate: InstacartRunSelectionCandidatePayload?
    let topCandidates: [InstacartRunSelectionCandidatePayload]?
    let decision: String?
    let matchType: String?
    let confidence: Double?

    enum CodingKeys: String, CodingKey {
        case selectedCandidate
        case fallbackCandidate
        case topCandidates
        case decision
        case matchType
        case confidence
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        selectedCandidate = container.lossyDecodable(forKey: .selectedCandidate, as: InstacartRunSelectionCandidatePayload.self)
        fallbackCandidate = container.lossyDecodable(forKey: .fallbackCandidate, as: InstacartRunSelectionCandidatePayload.self)
        topCandidates = container.lossyDecodableArray(forKey: .topCandidates, as: InstacartRunSelectionCandidatePayload.self)
        decision = container.lossyString(forKey: .decision)
        matchType = container.lossyString(forKey: .matchType)
        if let value = try? container.decodeIfPresent(Double.self, forKey: .confidence) {
            confidence = value
        } else if let value = try? container.decodeIfPresent(String.self, forKey: .confidence),
                  let parsed = Double(value.trimmingCharacters(in: .whitespacesAndNewlines)) {
            confidence = parsed
        } else {
            confidence = nil
        }
    }
}

struct InstacartRunSelectionCandidatePayload: Decodable {
    let title: String?
    let rawLabel: String?
    let productHref: String?
    let cardText: String?
    let imageURLString: String?
    let priceText: String?

    enum CodingKeys: String, CodingKey {
        case title
        case rawLabel
        case productHref
        case cardText
        case imageURLString = "imageURL"
        case priceText
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = container.lossyString(forKey: .title)
        rawLabel = container.lossyString(forKey: .rawLabel)
        productHref = container.lossyString(forKey: .productHref)
        cardText = container.lossyString(forKey: .cardText)
        imageURLString = container.lossyString(forKey: .imageURLString)
        priceText = container.lossyString(forKey: .priceText)
    }
}

struct InstacartRunShoppingContextPayload: Decodable {
    let familyKey: String?

    enum CodingKeys: String, CodingKey {
        case familyKey
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        familyKey = container.lossyString(forKey: .familyKey)
    }
}

struct InstacartRunLogItemPayload: Identifiable, Decodable {
    let requested: String?
    let canonicalName: String?
    let normalizedQuery: String?
    let quantityRequested: Int?
    let shoppingContext: InstacartRunShoppingContextPayload?
    let attempts: [InstacartRunAttemptPayload]?
    let finalStatus: InstacartRunFinalStatusPayload?

    enum CodingKeys: String, CodingKey {
        case requested
        case canonicalName
        case normalizedQuery
        case quantityRequested
        case shoppingContext
        case attempts
        case finalStatus
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        requested = container.lossyString(forKey: .requested)
        canonicalName = container.lossyString(forKey: .canonicalName)
        normalizedQuery = container.lossyString(forKey: .normalizedQuery)
        quantityRequested = container.lossyInt(forKey: .quantityRequested)
        shoppingContext = container.lossyDecodable(forKey: .shoppingContext, as: InstacartRunShoppingContextPayload.self)
        attempts = container.lossyDecodableArray(forKey: .attempts, as: InstacartRunAttemptPayload.self)
        finalStatus = container.lossyDecodable(forKey: .finalStatus, as: InstacartRunFinalStatusPayload.self)
    }

    var id: String {
        [
            requested,
            canonicalName,
            normalizedQuery
        ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        .joined(separator: "::")
    }
}

struct InstacartRunAttemptPayload: Decodable {
    let at: String?
    let store: String?
    let query: String?
    let success: Bool?
    let matchedLabel: String?
    let decision: String?
    let matchType: String?
    let refinedQuery: String?
    let reason: String?
    let selectionTrace: InstacartRunSelectionTracePayload?

    enum CodingKeys: String, CodingKey {
        case at, store, query, success, matchedLabel, decision, matchType, refinedQuery, reason, selectionTrace
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        at = container.lossyString(forKey: .at)
        store = container.lossyString(forKey: .store)
        query = container.lossyString(forKey: .query)
        success = container.lossyBool(forKey: .success)
        matchedLabel = container.lossyString(forKey: .matchedLabel)
        decision = container.lossyString(forKey: .decision)
        matchType = container.lossyString(forKey: .matchType)
        refinedQuery = container.lossyString(forKey: .refinedQuery)
        reason = container.lossyString(forKey: .reason)
        selectionTrace = container.lossyDecodable(forKey: .selectionTrace, as: InstacartRunSelectionTracePayload.self)
    }
}

struct InstacartRunFinalStatusPayload: Decodable {
    let status: String?
    let matchedStore: String?
    let decision: String?
    let matchType: String?
    let quantityAdded: Int?
    let shortfall: Int?
    let failureVerdict: String?
    let failureSummary: String?
    let failureReasons: [String]?
    let approachChange: String?
    let failureReviewModel: String?

    enum CodingKeys: String, CodingKey {
        case status, matchedStore, decision, matchType, quantityAdded, shortfall
        case failureVerdict, failureSummary, failureReasons, approachChange, failureReviewModel
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = container.lossyString(forKey: .status)
        matchedStore = container.lossyString(forKey: .matchedStore)
        decision = container.lossyString(forKey: .decision)
        matchType = container.lossyString(forKey: .matchType)
        quantityAdded = container.lossyInt(forKey: .quantityAdded)
        shortfall = container.lossyInt(forKey: .shortfall)
        failureVerdict = container.lossyString(forKey: .failureVerdict)
        failureSummary = container.lossyString(forKey: .failureSummary)
        failureReasons = container.lossyStringArray(forKey: .failureReasons)
        approachChange = container.lossyString(forKey: .approachChange)
        failureReviewModel = container.lossyString(forKey: .failureReviewModel)
    }
}

extension KeyedDecodingContainer {
    func lossyString(forKey key: Key) -> String? {
        if let value = try? decodeIfPresent(String.self, forKey: key) {
            return value
        }
        if let value = try? decodeIfPresent(Int.self, forKey: key) {
            return String(value)
        }
        if let value = try? decodeIfPresent(Double.self, forKey: key) {
            return String(value)
        }
        if let value = try? decodeIfPresent(Bool.self, forKey: key) {
            return String(value)
        }
        return nil
    }

    func lossyInt(forKey key: Key) -> Int? {
        if let value = try? decodeIfPresent(Int.self, forKey: key) {
            return value
        }
        if let value = try? decodeIfPresent(Double.self, forKey: key) {
            return Int(value)
        }
        if let value = try? decodeIfPresent(String.self, forKey: key) {
            return Int(value.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    func lossyBool(forKey key: Key) -> Bool? {
        if let value = try? decodeIfPresent(Bool.self, forKey: key) {
            return value
        }
        if let value = try? decodeIfPresent(String.self, forKey: key) {
            switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "1", "yes":
                return true
            case "false", "0", "no":
                return false
            default:
                return nil
            }
        }
        if let value = try? decodeIfPresent(Int.self, forKey: key) {
            return value != 0
        }
        return nil
    }

    func lossyDate(forKey key: Key) -> Date? {
        if let value = try? decodeIfPresent(Date.self, forKey: key) {
            return value
        }
        if let value = try? decodeIfPresent(String.self, forKey: key) {
            return ISO8601DateFormatter().date(from: value)
        }
        return nil
    }

    func lossyStringArray(forKey key: Key) -> [String]? {
        if let values = try? decodeIfPresent([String].self, forKey: key) {
            return values
        }
        return nil
    }

    func lossyDecodable<T: Decodable>(forKey key: Key, as type: T.Type) -> T? {
        if let value = try? decodeIfPresent(T.self, forKey: key) {
            return value
        }
        return nil
    }

    func lossyDecodableArray<T: Decodable>(forKey key: Key, as type: T.Type) -> [T]? {
        guard let rawValue = try? decodeIfPresent([T].self, forKey: key) else {
            return nil
        }
        return rawValue
    }
}

struct InstacartAutomationRunRequestPayload: Encodable {
    let items: [GroceryItem]
    let plan: MealPlan?
    let mealPlanID: String?
    let preferredStore: String?
    let strictStore: Bool
    let deliveryAddress: InstacartAutomationDeliveryAddressPayload?
    let retryContext: InstacartAutomationRetryContextPayload?
    let manualIntent: Bool
    let trigger: String?

    enum CodingKeys: String, CodingKey {
        case items
        case plan
        case mealPlanID = "meal_plan_id"
        case preferredStore = "preferred_store"
        case strictStore = "strict_store"
        case deliveryAddress = "delivery_address"
        case retryContext = "retry_context"
        case manualIntent = "manual_intent"
        case trigger
    }
}

struct InstacartAutomationRetryContextPayload: Encodable {
    let kind: String
    let rootRunID: String?
    let attempt: Int

    enum CodingKeys: String, CodingKey {
        case kind
        case rootRunID = "root_run_id"
        case attempt
    }
}

struct InstacartAutomationDeliveryAddressPayload: Encodable {
    let line1: String
    let line2: String?
    let city: String
    let region: String
    let postalCode: String
    let country: String
    let deliveryNotes: String?

    enum CodingKeys: String, CodingKey {
        case line1
        case line2
        case city
        case region
        case postalCode = "postal_code"
        case country
        case deliveryNotes = "delivery_notes"
    }
}

struct InstacartAutomationRunResponse: Decodable {
    let runID: String
    let jobID: String?
    let status: String?
    let success: Bool
    let partialSuccess: Bool
    let cartURL: String?
    let groceryOrderID: UUID?
    let requestedItemCount: Int?
    let resolvedItemCount: Int?
    let retryQueued: Bool?

    enum CodingKeys: String, CodingKey {
        case runID = "runId"
        case jobID
        case status
        case success
        case partialSuccess
        case cartURL = "cartUrl"
        case groceryOrderID
        case requestedItemCount
        case resolvedItemCount
        case retryQueued
    }

    var normalizedStatus: String {
        let rawStatus = status?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if !rawStatus.isEmpty { return rawStatus }
        if success { return "completed" }
        if partialSuccess { return "partial" }
        return "failed"
    }
}

final class InstacartAutomationAPIService {
    static let shared = InstacartAutomationAPIService()

    private init() {}

    func startRun(
        items: [GroceryItem],
        mealPlan: MealPlan,
        userID: String?,
        accessToken: String?,
        deliveryAddress: DeliveryAddress?,
        retryContext: InstacartAutomationRetryContextPayload? = nil,
        manualIntent: Bool = false,
        trigger: String? = nil
    ) async throws -> InstacartAutomationRunResponse {
        var lastError: Error?
        for baseURL in OunjeDevelopmentServer.workerCandidateBaseURLs {
            do {
                return try await startRun(
                    baseURL: baseURL,
                    items: items,
                    mealPlan: mealPlan,
                    userID: userID,
                    accessToken: accessToken,
                    deliveryAddress: deliveryAddress,
                    retryContext: retryContext,
                    manualIntent: manualIntent,
                    trigger: trigger
                )
            } catch {
                lastError = error
            }
        }

        throw lastError ?? URLError(.cannotConnectToHost)
    }

    private func startRun(
        baseURL: String,
        items: [GroceryItem],
        mealPlan: MealPlan,
        userID: String?,
        accessToken: String?,
        deliveryAddress: DeliveryAddress?,
        retryContext: InstacartAutomationRetryContextPayload?,
        manualIntent: Bool,
        trigger: String?
    ) async throws -> InstacartAutomationRunResponse {
        guard let url = URL(string: "\(baseURL)/v1/instacart/runs") else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let accessToken, !accessToken.isEmpty {
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }
        if let userID, !userID.isEmpty {
            request.setValue(userID, forHTTPHeaderField: "X-User-ID")
        }
        request.httpBody = try JSONEncoder().encode(
            InstacartAutomationRunRequestPayload(
                items: items,
                plan: mealPlan,
                mealPlanID: mealPlan.id.uuidString,
                preferredStore: sanitizedInstacartStoreName(mealPlan.bestQuote?.selectedStore?.storeName),
                strictStore: false,
                deliveryAddress: deliveryAddress?.isComplete == true ? InstacartAutomationDeliveryAddressPayload(
                    line1: deliveryAddress?.line1 ?? "",
                    line2: deliveryAddress?.line2.isEmpty == false ? deliveryAddress?.line2 : nil,
                    city: deliveryAddress?.city ?? "",
                    region: deliveryAddress?.region ?? "",
                    postalCode: deliveryAddress?.postalCode ?? "",
                    country: "CA",
                    deliveryNotes: deliveryAddress?.deliveryNotes.isEmpty == false ? deliveryAddress?.deliveryNotes : nil
                ) : nil,
                retryContext: retryContext,
                manualIntent: manualIntent,
                trigger: trigger
            )
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            // 409 means a run is already in progress for this user's account —
            // not an error from the client's perspective, just a signal to reload.
            if httpResponse.statusCode == 409,
               let body = try? JSONDecoder().decode([String: String].self, from: data),
               body["code"] == "instacart_run_in_progress" {
                throw InstacartRunAlreadyInProgressError()
            }
            let errorPayload = try? JSONDecoder().decode(SupabaseRestErrorResponse.self, from: data)
            throw RecipeImportServiceError.requestFailed(
                errorPayload?.message ?? errorPayload?.error ?? "Instacart run failed (\(httpResponse.statusCode))."
            )
        }

        return try JSONDecoder().decode(InstacartAutomationRunResponse.self, from: data)
    }
}

final class InstacartRunLogAPIService {
    static let shared = InstacartRunLogAPIService()

    private init() {}

    func fetchRuns(
        userID: String?,
        accessToken: String?,
        query: String = "",
        status: String = "all",
        limit: Int = 20,
        offset: Int = 0,
        includeCount: Bool = false
    ) async throws -> InstacartRunLogsListResponse {
        let baseURL = OunjeDevelopmentServer.workerBaseURL
        do {
            return try await fetchRuns(
                baseURL: baseURL,
                userID: userID,
                accessToken: accessToken,
                query: query,
                status: status,
                limit: limit,
                offset: offset,
                includeCount: includeCount
            )
        } catch {
            return try await fetchRunsViaSupabase(
                userID: userID,
                accessToken: accessToken,
                query: query,
                status: status,
                limit: limit,
                offset: offset,
                includeCount: includeCount
            )
        }
    }

    func fetchCurrentRunSummary(
        userID: String?,
        accessToken: String?,
        mealPlanID: String?
    ) async throws -> InstacartRunLogSummary? {
        let baseURL = OunjeDevelopmentServer.workerBaseURL
        do {
            return try await fetchCurrentRunSummary(
                baseURL: baseURL,
                userID: userID,
                accessToken: accessToken,
                mealPlanID: mealPlanID
            )
        } catch {
            return try await fetchCurrentRunSummaryViaSupabase(
                userID: userID,
                accessToken: accessToken,
                mealPlanID: mealPlanID
            )
        }
    }

    func fetchRun(runID: String, userID: String? = nil, accessToken: String? = nil) async throws -> InstacartRunLogDetailPayload {
        async let summary = fetchRunSummary(runID: runID, userID: userID, accessToken: accessToken)
        async let trace = fetchRunTrace(runID: runID, userID: userID, accessToken: accessToken)
        return InstacartRunLogDetailPayload(summary: try await summary, trace: try await trace)
    }

    func fetchRunSummary(runID: String, userID: String? = nil, accessToken: String? = nil) async throws -> InstacartRunLogSummary {
        var lastError: Error?
        for baseURL in OunjeDevelopmentServer.workerCandidateBaseURLs {
            do {
                return try await fetchRunSummary(baseURL: baseURL, runID: runID, userID: userID, accessToken: accessToken)
            } catch {
                lastError = error
            }
        }

        do {
            return try await fetchRunSummaryViaSupabase(runID: runID, userID: userID, accessToken: accessToken)
        } catch {
            lastError = error
        }

        throw lastError ?? URLError(.cannotConnectToHost)
    }

    func fetchRunTrace(runID: String, userID: String? = nil, accessToken: String? = nil) async throws -> InstacartRunTracePayload {
        var lastError: Error?
        for baseURL in OunjeDevelopmentServer.workerCandidateBaseURLs {
            do {
                return try await fetchRunTrace(baseURL: baseURL, runID: runID, userID: userID, accessToken: accessToken)
            } catch {
                lastError = error
            }
        }

        do {
            return try await fetchRunTraceViaSupabase(runID: runID, userID: userID, accessToken: accessToken)
        } catch {
            lastError = error
        }

        throw lastError ?? URLError(.cannotConnectToHost)
    }

    private func fetchRuns(
        baseURL: String,
        userID: String?,
        accessToken: String?,
        query: String,
        status: String,
        limit: Int,
        offset: Int,
        includeCount: Bool
    ) async throws -> InstacartRunLogsListResponse {
        guard var components = URLComponents(string: "\(baseURL)/v1/instacart/runs") else {
            throw RecipeImportServiceError.invalidRequest
        }

        let trimmedUserID = userID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let trimmedStatus = status.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)

        components.queryItems = [
            URLQueryItem(name: "user_id", value: trimmedUserID.isEmpty ? nil : trimmedUserID),
            URLQueryItem(name: "status", value: trimmedStatus.isEmpty ? "all" : trimmedStatus),
            URLQueryItem(name: "query", value: trimmedQuery.isEmpty ? nil : trimmedQuery),
            URLQueryItem(name: "limit", value: "\(limit)"),
            URLQueryItem(name: "offset", value: "\(offset)"),
            URLQueryItem(name: "include_count", value: includeCount ? "true" : nil),
        ].compactMap { item in
            guard let value = item.value, !value.isEmpty else { return nil }
            return item
        }

        guard let url = components.url else {
            throw RecipeImportServiceError.invalidRequest
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        if let accessToken = accessToken?.trimmingCharacters(in: .whitespacesAndNewlines),
           !accessToken.isEmpty {
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }
        if !trimmedUserID.isEmpty {
            request.setValue(trimmedUserID, forHTTPHeaderField: "x-user-id")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw RecipeImportServiceError.invalidResponse
        }
        guard (200 ... 299).contains(httpResponse.statusCode) else {
            let errorPayload = try? JSONDecoder().decode(SupabaseRestErrorResponse.self, from: data)
            let fallback = "Instacart runs failed (\(httpResponse.statusCode))."
            throw RecipeImportServiceError.requestFailed(errorPayload?.message ?? errorPayload?.error ?? fallback)
        }

        return try JSONDecoder().decode(InstacartRunLogsListResponse.self, from: data)
    }

    private func fetchCurrentRunSummary(
        baseURL: String,
        userID: String?,
        accessToken: String?,
        mealPlanID: String?
    ) async throws -> InstacartRunLogSummary? {
        guard var components = URLComponents(string: "\(baseURL)/v1/instacart/runs/current") else {
            throw RecipeImportServiceError.invalidRequest
        }

        let trimmedUserID = userID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let trimmedMealPlanID = mealPlanID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        components.queryItems = [
            URLQueryItem(name: "user_id", value: trimmedUserID.isEmpty ? nil : trimmedUserID),
            URLQueryItem(name: "meal_plan_id", value: trimmedMealPlanID.isEmpty ? nil : trimmedMealPlanID),
        ].compactMap { item in
            guard let value = item.value, !value.isEmpty else { return nil }
            return item
        }

        guard let url = components.url else {
            throw RecipeImportServiceError.invalidRequest
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        if let accessToken = accessToken?.trimmingCharacters(in: .whitespacesAndNewlines),
           !accessToken.isEmpty {
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }
        if !trimmedUserID.isEmpty {
            request.setValue(trimmedUserID, forHTTPHeaderField: "x-user-id")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw RecipeImportServiceError.invalidResponse
        }
        guard (200 ... 299).contains(httpResponse.statusCode) else {
            let errorPayload = try? JSONDecoder().decode(SupabaseRestErrorResponse.self, from: data)
            let fallback = "Instacart current run failed (\(httpResponse.statusCode))."
            throw RecipeImportServiceError.requestFailed(errorPayload?.message ?? errorPayload?.error ?? fallback)
        }

        return try JSONDecoder().decode(InstacartCurrentRunSummaryResponse.self, from: data).summary
    }

    private func fetchRunsViaSupabase(
        userID: String?,
        accessToken: String?,
        query: String,
        status: String,
        limit: Int,
        offset: Int,
        includeCount: Bool
    ) async throws -> InstacartRunLogsListResponse {
        let trimmedUserID = userID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmedUserID.isEmpty else {
            throw RecipeImportServiceError.invalidRequest
        }

        guard var components = URLComponents(string: "\(SupabaseConfig.url)/rest/v1/instacart_run_logs") else {
            throw RecipeImportServiceError.invalidRequest
        }

        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedStatus = status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "select", value: "run_id,user_id,status_kind,summary_json,started_at,completed_at,progress,created_at"),
            URLQueryItem(name: "user_id", value: "eq.\(trimmedUserID)"),
            URLQueryItem(name: "order", value: "started_at.desc,created_at.desc"),
            URLQueryItem(name: "limit", value: "\(max(limit, 1))"),
            URLQueryItem(name: "offset", value: "\(max(offset, 0))")
        ]

        switch normalizedStatus {
        case "current":
            queryItems.append(URLQueryItem(name: "status_kind", value: "in.(running,queued,completed,partial)"))
        case "historic":
            queryItems.append(URLQueryItem(name: "status_kind", value: "in.(completed,partial,failed)"))
        default:
            break
        }

        if !normalizedQuery.isEmpty {
            let escaped = normalizedQuery.replacingOccurrences(of: ",", with: " ")
            queryItems.append(URLQueryItem(name: "search_text", value: "ilike.*\(escaped)*"))
        }

        components.queryItems = queryItems
        guard let url = components.url else {
            throw RecipeImportServiceError.invalidRequest
        }

        let decoder = JSONDecoder()
        var request = try SupabaseUserDataRequest.request(url: url, method: "GET", accessToken: accessToken)
        if includeCount {
            request.setValue("exact", forHTTPHeaderField: "Prefer")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw RecipeImportServiceError.invalidResponse
        }
        guard (200 ... 299).contains(httpResponse.statusCode) else {
            let fallback = "Instacart runs failed (\(httpResponse.statusCode))."
            throw RecipeImportServiceError.requestFailed(SupabaseUserDataRequest.message(from: data, statusCode: httpResponse.statusCode, fallback: fallback))
        }

        let rows = try decoder.decode([InstacartRunLogStorageRow].self, from: data)
        let items = rows.map(\.resolvedSummary)
        let parsedTotal = httpResponse.value(forHTTPHeaderField: "Content-Range")
            .flatMap(Self.parseSupabaseTotalCount(from:))
        let inferredHasMore = items.count >= max(limit, 1)
        let total = parsedTotal ?? (max(offset, 0) + items.count + (inferredHasMore ? 1 : 0))

        return InstacartRunLogsListResponse(
            items: items,
            total: total,
            offset: max(offset, 0),
            limit: max(limit, 1),
            hasMore: parsedTotal.map { max(offset, 0) + items.count < $0 } ?? inferredHasMore,
            query: query,
            status: status,
            userID: trimmedUserID
        )
    }

    private func fetchCurrentRunSummaryViaSupabase(
        userID: String?,
        accessToken: String?,
        mealPlanID: String?
    ) async throws -> InstacartRunLogSummary? {
        let trimmedUserID = userID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmedUserID.isEmpty else {
            throw RecipeImportServiceError.invalidRequest
        }

        guard var components = URLComponents(string: "\(SupabaseConfig.url)/rest/v1/instacart_run_logs") else {
            throw RecipeImportServiceError.invalidRequest
        }

        let normalizedPlanID = mealPlanID?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let queryItems: [URLQueryItem] = [
            URLQueryItem(name: "select", value: "run_id,user_id,status_kind,summary_json,started_at,completed_at,progress,created_at"),
            URLQueryItem(name: "user_id", value: "eq.\(trimmedUserID)"),
            URLQueryItem(name: "status_kind", value: "in.(running,queued,completed,partial)"),
            URLQueryItem(name: "order", value: "completed_at.desc.nullsfirst,started_at.desc.nullslast"),
            URLQueryItem(name: "limit", value: normalizedPlanID.isEmpty ? "6" : "10")
        ]

        components.queryItems = queryItems
        guard let url = components.url else {
            throw RecipeImportServiceError.invalidRequest
        }

        let request = try SupabaseUserDataRequest.request(url: url, method: "GET", accessToken: accessToken)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw RecipeImportServiceError.invalidResponse
        }
        guard (200 ... 299).contains(httpResponse.statusCode) else {
            let fallback = "Instacart current run failed (\(httpResponse.statusCode))."
            throw RecipeImportServiceError.requestFailed(SupabaseUserDataRequest.message(from: data, statusCode: httpResponse.statusCode, fallback: fallback))
        }

        let rows = try JSONDecoder().decode([InstacartRunLogStorageRow].self, from: data)
        let summaries = rows.map(\.resolvedSummary)
        if !normalizedPlanID.isEmpty,
           let planMatch = summaries.first(where: {
               ($0.mealPlanID ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalizedPlanID
           }) {
            return planMatch
        }
        return summaries.first
    }

    private static func parseSupabaseTotalCount(from contentRange: String) -> Int? {
        let parts = contentRange.split(separator: "/")
        guard let totalPart = parts.last else { return nil }
        return Int(totalPart)
    }

    private func fetchRunSummary(
        baseURL: String,
        runID: String,
        userID: String?,
        accessToken: String?
    ) async throws -> InstacartRunLogSummary {
        guard let encodedRunID = runID.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "\(baseURL)/v1/instacart/runs/\(encodedRunID)/summary") else {
            throw RecipeImportServiceError.invalidRequest
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        if let accessToken = accessToken?.trimmingCharacters(in: .whitespacesAndNewlines),
           !accessToken.isEmpty {
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }
        if let userID = userID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !userID.isEmpty {
            request.setValue(userID, forHTTPHeaderField: "x-user-id")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw RecipeImportServiceError.invalidResponse
        }
        guard (200 ... 299).contains(httpResponse.statusCode) else {
            let errorPayload = try? JSONDecoder().decode(SupabaseRestErrorResponse.self, from: data)
            let fallback = "Instacart run summary failed (\(httpResponse.statusCode))."
            throw RecipeImportServiceError.requestFailed(errorPayload?.message ?? errorPayload?.error ?? fallback)
        }

        return try JSONDecoder().decode(InstacartRunLogSummaryResponse.self, from: data).summary
    }

    private func fetchRunTrace(
        baseURL: String,
        runID: String,
        userID: String?,
        accessToken: String?
    ) async throws -> InstacartRunTracePayload {
        guard let encodedRunID = runID.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "\(baseURL)/v1/instacart/runs/\(encodedRunID)/trace") else {
            throw RecipeImportServiceError.invalidRequest
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        if let accessToken = accessToken?.trimmingCharacters(in: .whitespacesAndNewlines),
           !accessToken.isEmpty {
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }
        if let userID = userID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !userID.isEmpty {
            request.setValue(userID, forHTTPHeaderField: "x-user-id")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw RecipeImportServiceError.invalidResponse
        }
        guard (200 ... 299).contains(httpResponse.statusCode) else {
            let errorPayload = try? JSONDecoder().decode(SupabaseRestErrorResponse.self, from: data)
            let fallback = "Instacart run trace failed (\(httpResponse.statusCode))."
            throw RecipeImportServiceError.requestFailed(errorPayload?.message ?? errorPayload?.error ?? fallback)
        }

        return try JSONDecoder().decode(InstacartRunTraceResponse.self, from: data).trace
    }

    private func fetchRunSummaryViaSupabase(
        runID: String,
        userID: String?,
        accessToken: String?
    ) async throws -> InstacartRunLogSummary {
        guard let encodedRunID = runID.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "\(SupabaseConfig.url)/rest/v1/instacart_run_logs?select=run_id,user_id,summary_json&run_id=eq.\(encodedRunID)\(supabaseUserFilter(userID))&limit=1") else {
            throw RecipeImportServiceError.invalidRequest
        }

        var request = try SupabaseUserDataRequest.request(url: url, method: "GET", accessToken: accessToken)
        if let userID = userID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !userID.isEmpty {
            request.setValue(userID, forHTTPHeaderField: "x-user-id")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw RecipeImportServiceError.invalidResponse
        }
        guard (200 ... 299).contains(httpResponse.statusCode) else {
            let fallback = "Instacart run summary failed (\(httpResponse.statusCode))."
            throw RecipeImportServiceError.requestFailed(SupabaseUserDataRequest.message(from: data, statusCode: httpResponse.statusCode, fallback: fallback))
        }

        let rows = try JSONDecoder().decode([InstacartRunLogStorageRow].self, from: data)
        if let row = rows.first {
            return row.resolvedSummary
        }

        throw RecipeImportServiceError.requestFailed("Instacart run summary not found.")
    }

    private func fetchRunTraceViaSupabase(
        runID: String,
        userID: String?,
        accessToken: String?
    ) async throws -> InstacartRunTracePayload {
        guard let encodedRunID = runID.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            throw RecipeImportServiceError.invalidRequest
        }

        let traceTables = [
            "instacart_run_log_traces?select=run_id,user_id,trace_json&run_id=eq.\(encodedRunID)\(supabaseUserFilter(userID))&limit=1",
            "instacart_run_logs?select=run_id,user_id,trace_json&run_id=eq.\(encodedRunID)\(supabaseUserFilter(userID))&limit=1"
        ]

        var lastError: Error?
        for tableQuery in traceTables {
            guard let url = URL(string: "\(SupabaseConfig.url)/rest/v1/\(tableQuery)") else {
                continue
            }

            var request = try SupabaseUserDataRequest.request(url: url, method: "GET", accessToken: accessToken)
            if let userID = userID?.trimmingCharacters(in: .whitespacesAndNewlines),
               !userID.isEmpty {
                request.setValue(userID, forHTTPHeaderField: "x-user-id")
            }

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw RecipeImportServiceError.invalidResponse
            }
            guard (200 ... 299).contains(httpResponse.statusCode) else {
                let fallback = "Instacart run trace failed (\(httpResponse.statusCode))."
                lastError = RecipeImportServiceError.requestFailed(SupabaseUserDataRequest.message(from: data, statusCode: httpResponse.statusCode, fallback: fallback))
                continue
            }

            let rows = try JSONDecoder().decode([InstacartRunTraceStorageRow].self, from: data)
            if let row = rows.first, let trace = row.traceJSON {
                return trace
            }
            lastError = RecipeImportServiceError.requestFailed("Instacart run trace not found.")
        }

        throw lastError ?? RecipeImportServiceError.requestFailed("Instacart run trace not found.")
    }

    private func supabaseUserFilter(_ userID: String?) -> String {
        let trimmed = userID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return "" }
        return "&user_id=eq.\(trimmed)"
    }
}

final class GroceryOrderAPIService {
    static let shared = GroceryOrderAPIService()

    private init() {}

    func fetchLatestOrder(userID: String?, accessToken: String?) async throws -> GroceryOrderSummaryRecord? {
        do {
            var lastError: Error?
            for baseURL in OunjeDevelopmentServer.workerCandidateBaseURLs {
                do {
                    return try await fetchLatestOrder(baseURL: baseURL, userID: userID, accessToken: accessToken)
                } catch {
                    lastError = error
                }
            }

            throw lastError ?? URLError(.cannotConnectToHost)
        } catch {
            return try await fetchLatestOrderViaSupabase(userID: userID, accessToken: accessToken)
        }
    }

    func fetchOrder(orderID: UUID, userID: String?, accessToken: String?) async throws -> GroceryOrderSummaryRecord {
        var lastError: Error?
        for baseURL in OunjeDevelopmentServer.workerCandidateBaseURLs {
            do {
                return try await fetchOrder(baseURL: baseURL, orderID: orderID, userID: userID, accessToken: accessToken)
            } catch {
                lastError = error
            }
        }

        throw lastError ?? URLError(.cannotConnectToHost)
    }

    func trackOrder(orderID: UUID, userID: String?, accessToken: String?) async throws {
        guard let accessToken,
              !accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw URLError(.userAuthenticationRequired)
        }

        var lastError: Error?
        for baseURL in OunjeDevelopmentServer.workerCandidateBaseURLs {
            do {
                try await trackOrder(baseURL: baseURL, orderID: orderID, accessToken: accessToken)
                return
            } catch {
                lastError = error
            }
        }

        throw lastError ?? URLError(.cannotConnectToHost)
    }

    func approveOrder(orderID: UUID, tipCents: Int, userID: String?, accessToken: String?) async throws {
        guard let accessToken,
              !accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw URLError(.userAuthenticationRequired)
        }

        var lastError: Error?
        for baseURL in OunjeDevelopmentServer.workerCandidateBaseURLs {
            do {
                try await approveOrder(baseURL: baseURL, orderID: orderID, tipCents: tipCents, accessToken: accessToken)
                return
            } catch {
                lastError = error
            }
        }

        throw lastError ?? URLError(.cannotConnectToHost)
    }

    func completeOrder(orderID: UUID, providerOrderID: String?, userID: String?, accessToken: String?) async throws {
        guard let accessToken,
              !accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw URLError(.userAuthenticationRequired)
        }

        var lastError: Error?
        for baseURL in OunjeDevelopmentServer.workerCandidateBaseURLs {
            do {
                try await completeOrder(baseURL: baseURL, orderID: orderID, providerOrderID: providerOrderID, accessToken: accessToken)
                return
            } catch {
                lastError = error
            }
        }

        throw lastError ?? URLError(.cannotConnectToHost)
    }

    private func fetchLatestOrder(baseURL: String, userID: String?, accessToken: String?) async throws -> GroceryOrderSummaryRecord? {
        guard let url = URL(string: "\(baseURL)/v1/grocery/orders") else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        if let accessToken, !accessToken.isEmpty {
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }
        if let userID = userID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !userID.isEmpty {
            request.setValue(userID, forHTTPHeaderField: "x-user-id")
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard (200 ... 299).contains(httpResponse.statusCode) else {
            let errorPayload = try? JSONDecoder().decode(SupabaseRestErrorResponse.self, from: data)
            throw RecipeImportServiceError.requestFailed(
                errorPayload?.message ?? errorPayload?.error ?? "Latest grocery order failed (\(httpResponse.statusCode))."
            )
        }

        let payload = try decoder.decode(GroceryOrdersListResponse.self, from: data)
        return payload.orders.first
    }

    private func fetchLatestOrderViaSupabase(userID: String?, accessToken: String?) async throws -> GroceryOrderSummaryRecord? {
        let trimmedUserID = userID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmedUserID.isEmpty else {
            throw RecipeImportServiceError.invalidRequest
        }

        guard var components = URLComponents(string: "\(SupabaseConfig.url)/rest/v1/grocery_orders") else {
            throw RecipeImportServiceError.invalidRequest
        }
        components.queryItems = [
            URLQueryItem(name: "select", value: "id,provider,status,status_message,total_cents,created_at,completed_at,provider_tracking_url,tracking_status,tracking_title,tracking_detail,tracking_eta_text,tracking_image_url,last_tracked_at,delivered_at,step_log"),
            URLQueryItem(name: "user_id", value: "eq.\(trimmedUserID)"),
            URLQueryItem(name: "order", value: "created_at.desc"),
            URLQueryItem(name: "limit", value: "1")
        ]
        guard let url = components.url else {
            throw RecipeImportServiceError.invalidRequest
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let request = try SupabaseUserDataRequest.request(url: url, method: "GET", accessToken: accessToken, timeout: 20)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard (200 ... 299).contains(httpResponse.statusCode) else {
            let fallback = "Latest grocery order failed (\(httpResponse.statusCode))."
            throw RecipeImportServiceError.requestFailed(SupabaseUserDataRequest.message(from: data, statusCode: httpResponse.statusCode, fallback: fallback))
        }

        let orders = try decoder.decode([GroceryOrderSummaryRecord].self, from: data)
        return orders.first

    }

    private func fetchOrder(baseURL: String, orderID: UUID, userID: String?, accessToken: String?) async throws -> GroceryOrderSummaryRecord {
        guard let url = URL(string: "\(baseURL)/v1/grocery/orders/\(orderID.uuidString)") else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        if let accessToken, !accessToken.isEmpty {
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }
        if let userID = userID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !userID.isEmpty {
            request.setValue(userID, forHTTPHeaderField: "x-user-id")
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard (200 ... 299).contains(httpResponse.statusCode) else {
            let errorPayload = try? JSONDecoder().decode(SupabaseRestErrorResponse.self, from: data)
            throw RecipeImportServiceError.requestFailed(
                errorPayload?.message ?? errorPayload?.error ?? "Grocery order fetch failed (\(httpResponse.statusCode))."
            )
        }

        return try decoder.decode(GroceryOrderSummaryRecord.self, from: data)
    }

    private func trackOrder(baseURL: String, orderID: UUID, accessToken: String?) async throws {
        guard let url = URL(string: "\(baseURL)/v1/grocery/orders/\(orderID.uuidString)/track") else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let accessToken, !accessToken.isEmpty {
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONEncoder().encode([String: String]())

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard (200 ... 299).contains(httpResponse.statusCode) else {
            let errorPayload = try? JSONDecoder().decode(SupabaseRestErrorResponse.self, from: data)
            throw RecipeImportServiceError.requestFailed(
                errorPayload?.message ?? errorPayload?.error ?? "Order tracking refresh failed (\(httpResponse.statusCode))."
            )
        }
    }

    private func approveOrder(baseURL: String, orderID: UUID, tipCents: Int, accessToken: String?) async throws {
        guard let url = URL(string: "\(baseURL)/v1/grocery/orders/\(orderID.uuidString)/approve") else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let accessToken, !accessToken.isEmpty {
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONEncoder().encode(["tipCents": tipCents])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard (200 ... 299).contains(httpResponse.statusCode) else {
            let errorPayload = try? JSONDecoder().decode(SupabaseRestErrorResponse.self, from: data)
            throw RecipeImportServiceError.requestFailed(
                errorPayload?.message ?? errorPayload?.error ?? "Order approval failed (\(httpResponse.statusCode))."
            )
        }
    }

    private func completeOrder(baseURL: String, orderID: UUID, providerOrderID: String?, accessToken: String?) async throws {
        guard let url = URL(string: "\(baseURL)/v1/grocery/orders/\(orderID.uuidString)/complete") else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let accessToken, !accessToken.isEmpty {
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONEncoder().encode(["providerOrderId": providerOrderID])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard (200 ... 299).contains(httpResponse.statusCode) else {
            let errorPayload = try? JSONDecoder().decode(SupabaseRestErrorResponse.self, from: data)
            throw RecipeImportServiceError.requestFailed(
                errorPayload?.message ?? errorPayload?.error ?? "Order completion failed (\(httpResponse.statusCode))."
            )
        }
    }
}
