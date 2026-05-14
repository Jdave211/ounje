import Foundation

enum UserRuntimeSnapshotSource {
    case disk
    case remote
}

struct UserRuntimeProfileState: Codable, Hashable {
    var onboarded: Bool
    var lastOnboardingStep: Int
    var accountStatus: String?
    var deactivatedAt: String?
    var profileUpdatedAt: String?
    var email: String?
    var displayName: String?
    var authProvider: AuthProvider?

    var isDeactivated: Bool {
        accountStatus?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "deactivated"
            || deactivatedAt?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }
}

struct UserRuntimePrepSummary: Codable, Hashable {
    var historyCount: Int?
    var overrideCount: Int?
    var hasLatestPlan: Bool
}

struct UserRuntimeImportStatus: Codable, Hashable, Identifiable {
    var id: String
    var status: String
    var sourceURL: String?
    var canonicalURL: String?
    var recipeID: String?
    var errorMessage: String?
    var completedAt: String?
    var updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case status
        case sourceURL = "source_url"
        case canonicalURL = "canonical_url"
        case recipeID = "recipe_id"
        case errorMessage = "error_message"
        case completedAt = "completed_at"
        case updatedAt = "updated_at"
    }
}

struct UserRuntimeImportCounts: Codable, Hashable {
    var completedCount: Int?
    var recentStatuses: [UserRuntimeImportStatus]
}

struct UserRuntimeCartSummary: Codable {
    var mainShopCount: Int?
    var baseCartCount: Int?
    var latestGroceryOrderStatus: String?
    var latestInstacartRunStatus: String?
    var latestGroceryOrder: GroceryOrderSummaryRecord?
    var latestInstacartRun: InstacartRunLogSummary?
}

struct UserRuntimeSnapshot: Codable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var userID: String
    var profileState: UserRuntimeProfileState?
    var profile: UserProfile?
    var entitlement: AppUserEntitlement?
    var latestPlan: MealPlan?
    var savedRecipes: [DiscoverRecipeCardData]
    var savedRecipeIDs: Set<String>
    var importCounts: UserRuntimeImportCounts
    var prepSummary: UserRuntimePrepSummary
    var cartSummary: UserRuntimeCartSummary
    var providerConnections: [ProviderConnectionRecord]?
    var selectedRecipeTypographyStyle: RecipeTypographyStyle?
    var updatedAt: Date

    init(
        schemaVersion: Int = Self.currentSchemaVersion,
        userID: String,
        profileState: UserRuntimeProfileState? = nil,
        profile: UserProfile? = nil,
        entitlement: AppUserEntitlement? = nil,
        latestPlan: MealPlan? = nil,
        savedRecipes: [DiscoverRecipeCardData] = [],
        savedRecipeIDs: Set<String> = [],
        importCounts: UserRuntimeImportCounts = .init(completedCount: nil, recentStatuses: []),
        prepSummary: UserRuntimePrepSummary = .init(historyCount: nil, overrideCount: nil, hasLatestPlan: false),
        cartSummary: UserRuntimeCartSummary = .init(
            mainShopCount: nil,
            baseCartCount: nil,
            latestGroceryOrderStatus: nil,
            latestInstacartRunStatus: nil,
            latestGroceryOrder: nil,
            latestInstacartRun: nil
        ),
        providerConnections: [ProviderConnectionRecord]? = nil,
        selectedRecipeTypographyStyle: RecipeTypographyStyle? = nil,
        updatedAt: Date = .now
    ) {
        self.schemaVersion = schemaVersion
        self.userID = userID
        self.profileState = profileState
        self.profile = profile
        self.entitlement = entitlement
        self.latestPlan = latestPlan
        self.savedRecipes = savedRecipes
        self.savedRecipeIDs = savedRecipeIDs.isEmpty ? Set(savedRecipes.map(\.id)) : savedRecipeIDs
        self.importCounts = importCounts
        self.prepSummary = prepSummary
        self.cartSummary = cartSummary
        self.providerConnections = providerConnections
        self.selectedRecipeTypographyStyle = selectedRecipeTypographyStyle ?? RecipeTypographyPreferenceStore.style(in: profile)
        self.updatedAt = updatedAt
    }

    var isOnboarded: Bool {
        profileState?.onboarded == true && profile != nil
    }

    mutating func updateSavedRecipes(_ recipes: [DiscoverRecipeCardData]) {
        savedRecipes = recipes
        savedRecipeIDs = Set(recipes.map(\.id))
        updatedAt = .now
    }
}

private enum UserRuntimeSnapshotDiskStore {
    private static let directoryName = "UserRuntime"

    static func load(userID: String) -> UserRuntimeSnapshot? {
        guard let url = fileURL(userID: userID),
              let data = try? Data(contentsOf: url) else {
            return nil
        }
        guard let snapshot = try? decoder.decode(UserRuntimeSnapshot.self, from: data),
              snapshot.schemaVersion == UserRuntimeSnapshot.currentSchemaVersion,
              snapshot.userID == userID else {
            return nil
        }
        return snapshot
    }

    static func save(_ snapshot: UserRuntimeSnapshot) {
        guard let url = fileURL(userID: snapshot.userID, createDirectory: true),
              let data = try? encoder.encode(snapshot) else {
            return
        }
        try? data.write(to: url, options: [.atomic])
    }

    private static func fileURL(userID: String, createDirectory: Bool = false) -> URL? {
        let trimmedUserID = userID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedUserID.isEmpty else { return nil }

        guard let supportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let directoryURL = supportURL
            .appendingPathComponent("Ounje", isDirectory: true)
            .appendingPathComponent(directoryName, isDirectory: true)
        if createDirectory {
            try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        }
        let filename = "runtime-v\(UserRuntimeSnapshot.currentSchemaVersion)-\(safeFilename(trimmedUserID)).json"
        return directoryURL.appendingPathComponent(filename, isDirectory: false)
    }

    private static func safeFilename(_ value: String) -> String {
        value
            .unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) ? String($0) : "-" }
            .joined()
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static var decoder: JSONDecoder {
        SupabaseUserBootstrapService.makeDecoder()
    }
}

@MainActor
final class UserRuntimeStore: ObservableObject {
    @Published private(set) var snapshot: UserRuntimeSnapshot?
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastRefreshError: String?

    private var refreshTask: Task<UserRuntimeSnapshot?, Never>?

    @discardableResult
    func loadCachedSnapshot(userID: String?) -> UserRuntimeSnapshot? {
        guard let userID = normalizedUserID(userID) else { return nil }
        guard let cached = UserRuntimeSnapshotDiskStore.load(userID: userID) else { return nil }
        snapshot = cached
        persistVisualStyle(from: cached)
        return cached
    }

    @discardableResult
    func refresh(session: AuthSession) async -> UserRuntimeSnapshot? {
        if let refreshTask {
            return await refreshTask.value
        }

        isRefreshing = true
        lastRefreshError = nil

        let task = Task<UserRuntimeSnapshot?, Never> {
            do {
                return try await SupabaseUserBootstrapService.shared.fetchSnapshot(session: session)
            } catch {
                return nil
            }
        }
        refreshTask = task
        let refreshed = await task.value
        refreshTask = nil
        isRefreshing = false

        guard let refreshed else {
            lastRefreshError = "User bootstrap failed."
            return nil
        }
        snapshot = refreshed
        UserRuntimeSnapshotDiskStore.save(refreshed)
        persistVisualStyle(from: refreshed)
        return refreshed
    }

    func updateSavedRecipes(userID: String?, recipes: [DiscoverRecipeCardData]) {
        guard let userID = normalizedUserID(userID) else { return }
        var nextSnapshot = snapshot?.userID == userID
            ? snapshot
            : UserRuntimeSnapshotDiskStore.load(userID: userID)
        if nextSnapshot == nil {
            nextSnapshot = UserRuntimeSnapshot(userID: userID)
        }
        nextSnapshot?.updateSavedRecipes(recipes)
        if let nextSnapshot {
            snapshot = nextSnapshot
            UserRuntimeSnapshotDiskStore.save(nextSnapshot)
        }
    }

    func updateProfileState(
        userID: String?,
        profile: UserProfile?,
        onboarded: Bool,
        lastOnboardingStep: Int,
        entitlement: AppUserEntitlement?
    ) {
        guard let userID = normalizedUserID(userID) else { return }
        var nextSnapshot = snapshot?.userID == userID
            ? snapshot
            : UserRuntimeSnapshotDiskStore.load(userID: userID)
        if nextSnapshot == nil {
            nextSnapshot = UserRuntimeSnapshot(userID: userID)
        }
        guard var nextSnapshot else { return }

        let previousState = nextSnapshot.profileState
        nextSnapshot.profile = profile
        nextSnapshot.profileState = UserRuntimeProfileState(
            onboarded: onboarded,
            lastOnboardingStep: lastOnboardingStep,
            accountStatus: previousState?.accountStatus ?? "active",
            deactivatedAt: previousState?.deactivatedAt,
            profileUpdatedAt: ISO8601DateFormatter().string(from: Date()),
            email: previousState?.email,
            displayName: profile?.trimmedPreferredName ?? previousState?.displayName,
            authProvider: previousState?.authProvider
        )
        if let entitlement {
            nextSnapshot.entitlement = entitlement
        }
        if let profileStyle = RecipeTypographyPreferenceStore.style(in: profile) {
            nextSnapshot.selectedRecipeTypographyStyle = profileStyle
        } else if let rawStyle = UserDefaults.standard.string(forKey: RecipeTypographyStyle.storageKey) {
            nextSnapshot.selectedRecipeTypographyStyle = RecipeTypographyStyle.resolved(from: rawStyle)
        }
        nextSnapshot.updatedAt = Date()

        snapshot = nextSnapshot
        persistVisualStyle(from: nextSnapshot)
        UserRuntimeSnapshotDiskStore.save(nextSnapshot)
    }

    func persistCurrentSnapshot() {
        guard let snapshot else { return }
        UserRuntimeSnapshotDiskStore.save(snapshot)
    }

    private func normalizedUserID(_ userID: String?) -> String? {
        let value = userID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }

    private func persistVisualStyle(from snapshot: UserRuntimeSnapshot) {
        if let selectedRecipeTypographyStyle = snapshot.selectedRecipeTypographyStyle {
            RecipeTypographyPreferenceStore.persist(selectedRecipeTypographyStyle)
        } else {
            RecipeTypographyPreferenceStore.persistFromProfile(snapshot.profile)
        }
    }
}

enum SupabaseUserBootstrapServiceError: LocalizedError {
    case invalidRequest
    case invalidResponse
    case requestFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidRequest:
            return "Could not create user bootstrap request."
        case .invalidResponse:
            return "User bootstrap response was invalid."
        case .requestFailed(let message):
            return message
        }
    }
}

final class SupabaseUserBootstrapService {
    static let shared = SupabaseUserBootstrapService()

    private init() {}

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            if let numericValue = try? container.decode(Double.self) {
                // Swift's default Date Codable representation is seconds since
                // 2001-01-01. Older persisted meal plans use that numeric form.
                if numericValue > 1_500_000_000 {
                    return Date(timeIntervalSince1970: numericValue)
                }
                return Date(timeIntervalSinceReferenceDate: numericValue)
            }
            let rawValue = try container.decode(String.self)
            if let date = iso8601FractionalFormatter.date(from: rawValue)
                ?? iso8601Formatter.date(from: rawValue) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid ISO-8601 date: \(rawValue)"
            )
        }
        return decoder
    }

    func fetchSnapshot(session: AuthSession) async throws -> UserRuntimeSnapshot {
        let token = session.accessToken?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !token.isEmpty else {
            throw SupabaseUserBootstrapServiceError.requestFailed("User bootstrap session is missing.")
        }

        var lastError: Error?
        for baseURL in OunjeDevelopmentServer.workerCandidateBaseURLs {
            do {
                guard let url = URL(string: "\(baseURL)/v1/bootstrap/user") else {
                    throw SupabaseUserBootstrapServiceError.invalidRequest
                }
                var request = URLRequest(url: url)
                request.httpMethod = "GET"
                request.timeoutInterval = 12
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                request.setValue(session.userID, forHTTPHeaderField: "x-user-id")

                let (data, response) = try await URLSession.shared.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse else {
                    throw SupabaseUserBootstrapServiceError.invalidResponse
                }
                guard (200 ... 299).contains(httpResponse.statusCode) else {
                    let errorPayload = try? JSONDecoder().decode(SupabaseRestErrorResponse.self, from: data)
                    let fallback = "User bootstrap failed (\(httpResponse.statusCode))."
                    throw SupabaseUserBootstrapServiceError.requestFailed(errorPayload?.message ?? errorPayload?.error ?? fallback)
                }

                let envelope = try Self.makeDecoder().decode(UserBootstrapEnvelope.self, from: data)
                return envelope.snapshot
            } catch {
                lastError = error
            }
        }

        throw lastError ?? SupabaseUserBootstrapServiceError.invalidResponse
    }

    func invalidateServerCache(userID: String, accessToken: String?) async {
        let token = accessToken?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !userID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !token.isEmpty else {
            return
        }

        for baseURL in OunjeDevelopmentServer.workerCandidateBaseURLs {
            guard let url = URL(string: "\(baseURL)/v1/bootstrap/invalidate") else { continue }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 5
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue(userID, forHTTPHeaderField: "x-user-id")
            if let (_, response) = try? await URLSession.shared.data(for: request),
               let httpResponse = response as? HTTPURLResponse,
               (200 ... 299).contains(httpResponse.statusCode) {
                return
            }
        }
    }

    private static let iso8601FractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let iso8601Formatter = ISO8601DateFormatter()
}

private struct UserBootstrapEnvelope: Decodable {
    let version: Int
    let userID: String
    let profileState: UserBootstrapProfileState?
    let entitlement: UserBootstrapEntitlementEnvelope
    let prep: UserBootstrapPrepEnvelope
    let saved: UserBootstrapSavedEnvelope
    let imports: UserBootstrapImportsEnvelope
    let cart: UserBootstrapCartEnvelope
    let providers: [ProviderConnectionRecord]?
    let cachedAt: Date?

    enum CodingKeys: String, CodingKey {
        case version
        case userID = "user_id"
        case profileState = "profile_state"
        case entitlement
        case prep
        case saved
        case imports
        case cart
        case providers
        case cachedAt = "cached_at"
    }

    var snapshot: UserRuntimeSnapshot {
        let profile = profileState?.decodedProfile
        let savedCards = saved.latestCards.map(\.recipe)
        let savedIDs = Set(saved.ids.isEmpty ? savedCards.map(\.id) : saved.ids)
        let profileRuntimeState = profileState.map {
            UserRuntimeProfileState(
                onboarded: $0.onboarded,
                lastOnboardingStep: $0.lastOnboardingStep,
                accountStatus: $0.accountStatus,
                deactivatedAt: $0.deactivatedAt,
                profileUpdatedAt: $0.profileUpdatedAt,
                email: $0.email,
                displayName: $0.displayName,
                authProvider: $0.authProvider
            )
        }
        return UserRuntimeSnapshot(
            userID: userID,
            profileState: profileRuntimeState,
            profile: profile,
            entitlement: entitlement.entitlement,
            latestPlan: prep.latestPlan,
            savedRecipes: savedCards,
            savedRecipeIDs: savedIDs,
            importCounts: UserRuntimeImportCounts(
                completedCount: imports.completedCount,
                recentStatuses: imports.recentStatuses
            ),
            prepSummary: UserRuntimePrepSummary(
                historyCount: prep.historyCount,
                overrideCount: prep.overrideCount,
                hasLatestPlan: prep.latestPlan != nil
            ),
            cartSummary: UserRuntimeCartSummary(
                mainShopCount: cart.mainShopCount,
                baseCartCount: cart.baseCartCount,
                latestGroceryOrderStatus: cart.latestGroceryOrder?.status,
                latestInstacartRunStatus: cart.latestInstacartRun?.statusKind,
                latestGroceryOrder: cart.latestGroceryOrder,
                latestInstacartRun: cart.latestInstacartRun
            ),
            providerConnections: providers,
            selectedRecipeTypographyStyle: RecipeTypographyPreferenceStore.style(in: profile),
            updatedAt: cachedAt ?? .now
        )
    }
}

private struct UserBootstrapProfileState: Decodable {
    let onboarded: Bool
    let lastOnboardingStep: Int
    let accountStatus: String?
    let deactivatedAt: String?
    let profileUpdatedAt: String?
    let profileJSON: UserProfile?
    let preferredName: String?
    let dietaryPatterns: [String]?
    let hardRestrictions: [String]?
    let cadence: String?
    let deliveryAnchorDay: String?
    let adults: Int?
    let kids: Int?
    let cooksForOthers: Bool?
    let mealsPerWeek: Int?
    let budgetPerCycle: Double?
    let budgetWindow: String?
    let orderingAutonomy: String?
    let addressLine1: String?
    let addressLine2: String?
    let city: String?
    let region: String?
    let postalCode: String?
    let deliveryNotes: String?
    let foodPersona: String?
    let foodGoals: [String]?
    let email: String?
    let displayName: String?
    let authProvider: AuthProvider?

    enum CodingKeys: String, CodingKey {
        case onboarded
        case lastOnboardingStep = "last_onboarding_step"
        case accountStatus = "account_status"
        case deactivatedAt = "deactivated_at"
        case profileUpdatedAt = "profile_updated_at"
        case profileJSON = "profile_json"
        case preferredName = "preferred_name"
        case dietaryPatterns = "dietary_patterns"
        case hardRestrictions = "hard_restrictions"
        case cadence
        case deliveryAnchorDay = "delivery_anchor_day"
        case adults
        case kids
        case cooksForOthers = "cooks_for_others"
        case mealsPerWeek = "meals_per_week"
        case budgetPerCycle = "budget_per_cycle"
        case budgetWindow = "budget_window"
        case orderingAutonomy = "ordering_autonomy"
        case addressLine1 = "address_line1"
        case addressLine2 = "address_line2"
        case city
        case region
        case postalCode = "postal_code"
        case deliveryNotes = "delivery_notes"
        case foodPersona = "food_persona"
        case foodGoals = "food_goals"
        case email
        case displayName = "display_name"
        case authProvider = "auth_provider"
    }

    var decodedProfile: UserProfile? {
        let resolvedProfile = profileJSON ?? SupabaseProfileRow(
            id: nil,
            email: email,
            displayName: displayName,
            authProvider: authProvider?.rawValue,
            accountStatus: accountStatus,
            deactivatedAt: deactivatedAt,
            onboarded: onboarded,
            lastOnboardingStep: lastOnboardingStep,
            profileJSON: nil,
            preferredName: preferredName,
            dietaryPatterns: dietaryPatterns,
            hardRestrictions: hardRestrictions,
            cadence: cadence,
            deliveryAnchorDay: deliveryAnchorDay,
            adults: adults,
            kids: kids,
            cooksForOthers: cooksForOthers,
            mealsPerWeek: mealsPerWeek,
            budgetPerCycle: budgetPerCycle,
            budgetWindow: budgetWindow,
            orderingAutonomy: orderingAutonomy,
            addressLine1: addressLine1,
            addressLine2: addressLine2,
            city: city,
            region: region,
            postalCode: postalCode,
            deliveryNotes: deliveryNotes,
            foodPersona: foodPersona,
            foodGoals: foodGoals
        ).decodedProfile

        guard var profile = resolvedProfile else {
            return nil
        }

        if let preferredName = nonEmpty(preferredName) {
            profile.preferredName = preferredName
        } else if profile.trimmedPreferredName == nil, let displayName = nonEmpty(displayName) {
            profile.preferredName = displayName
        }
        if let cadenceValue = cadence.flatMap(MealCadence.init(rawValue:)) {
            profile.cadence = cadenceValue
        }
        if let deliveryAnchorDayValue = deliveryAnchorDay.flatMap(DeliveryAnchorDay.init(rawValue:)) {
            profile.deliveryAnchorDay = deliveryAnchorDayValue
        }
        if let adults {
            profile.consumption.adults = adults
        }
        if let kids {
            profile.consumption.kids = kids
        }
        if let mealsPerWeek {
            profile.consumption.mealsPerWeek = mealsPerWeek
        }
        if let cooksForOthers {
            profile.cooksForOthers = cooksForOthers
        }
        if let budgetPerCycle {
            profile.budgetPerCycle = budgetPerCycle
        }
        if let budgetWindowValue = budgetWindow.flatMap(BudgetWindow.init(rawValue:)) {
            profile.budgetWindow = budgetWindowValue
        }
        if let orderingAutonomyValue = orderingAutonomy.flatMap(OrderingAutonomyLevel.init(rawValue:)) {
            profile.orderingAutonomy = orderingAutonomyValue
        }
        if let dietaryPatterns {
            profile.dietaryPatterns = dietaryPatterns
        }
        if let hardRestrictions {
            profile.hardRestrictions = hardRestrictions
            if profile.allergies.isEmpty {
                profile.allergies = hardRestrictions
            }
        }
        if let line1 = nonEmpty(addressLine1) {
            profile.deliveryAddress.line1 = line1
        }
        if let line2 = nonEmpty(addressLine2) {
            profile.deliveryAddress.line2 = line2
        }
        if let city = nonEmpty(city) {
            profile.deliveryAddress.city = city
        }
        if let region = nonEmpty(region) {
            profile.deliveryAddress.region = region
        }
        if let postalCode = nonEmpty(postalCode) {
            profile.deliveryAddress.postalCode = postalCode
        }
        if let deliveryNotes = nonEmpty(deliveryNotes) {
            profile.deliveryAddress.deliveryNotes = deliveryNotes
        }
        if let foodPersona = nonEmpty(foodPersona) {
            profile.foodPersona = foodPersona
        }
        if let foodGoals {
            profile.foodGoals = foodGoals
        }

        return profile
    }

    private func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

private struct UserBootstrapEntitlementEnvelope: Decodable {
    let entitlement: AppUserEntitlement?
    let effectiveTier: OunjePricingTier
}

private struct UserBootstrapPrepEnvelope: Decodable {
    let latestPlan: MealPlan?
    let historyCount: Int?
    let overrideCount: Int?

    enum CodingKeys: String, CodingKey {
        case latestPlan = "latest_plan"
        case historyCount = "history_count"
        case overrideCount = "override_count"
    }
}

private struct UserBootstrapSavedEnvelope: Decodable {
    let count: Int?
    let ids: [String]
    let latestCards: [SupabaseSavedRecipeRow]

    enum CodingKeys: String, CodingKey {
        case count
        case ids
        case latestCards = "latest_cards"
    }
}

private struct UserBootstrapImportsEnvelope: Decodable {
    let completedCount: Int?
    let recentStatuses: [UserRuntimeImportStatus]

    enum CodingKeys: String, CodingKey {
        case completedCount = "completed_count"
        case recentStatuses = "recent_statuses"
    }
}

private struct UserBootstrapCartEnvelope: Decodable {
    let mainShopCount: Int?
    let baseCartCount: Int?
    let latestGroceryOrder: GroceryOrderSummaryRecord?
    let latestInstacartRun: InstacartRunLogSummary?

    enum CodingKeys: String, CodingKey {
        case mainShopCount = "main_shop_count"
        case baseCartCount = "base_cart_count"
        case latestGroceryOrder = "latest_grocery_order"
        case latestInstacartRun = "latest_instacart_run"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mainShopCount = try container.decodeIfPresent(Int.self, forKey: .mainShopCount)
        baseCartCount = try container.decodeIfPresent(Int.self, forKey: .baseCartCount)
        latestGroceryOrder = try? container.decodeIfPresent(GroceryOrderSummaryRecord.self, forKey: .latestGroceryOrder)
        latestInstacartRun = try? container.decodeIfPresent(InstacartRunLogSummary.self, forKey: .latestInstacartRun)
    }
}
