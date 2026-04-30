import Foundation

// MARK: - Request / Response types (legacy providers)

struct GroceryCartRequest: Encodable {
    let provider: String
    let items: [GroceryItemPayload]
    let recipeContext: RecipeContext?
    let deliveryAddress: DeliveryAddressPayload?

    struct GroceryItemPayload: Encodable {
        let name: String
        let amount: Double
        let unit: String
        let estimatedPrice: Double
        let sourceIngredients: [GroceryItemSourcePayload]
    }

    struct GroceryItemSourcePayload: Encodable {
        let recipeID: String
        let ingredientName: String
        let unit: String
    }

    struct RecipeContext: Encodable {
        let title: String
        let imageUrl: String?
        let recipeId: String?
    }

    struct DeliveryAddressPayload: Encodable {
        let line1: String
        let city: String
        let region: String
        let postalCode: String
        let country: String
    }
}

struct GroceryShoppingSpecRequest: Encodable {
    let items: [GroceryCartRequest.GroceryItemPayload]
    let plan: PlanPayload?
    let refreshToken: String?

    struct PlanPayload: Encodable {
        let recipes: [RecipePayload]

        struct RecipePayload: Encodable {
            let recipe: EmbeddedRecipePayload
        }

        struct EmbeddedRecipePayload: Encodable {
            let id: String
            let title: String
            let cuisine: String
            let tags: [String]
            let ingredients: [IngredientPayload]
            let cookMethod: String
            let recipeType: String
            let category: String
            let mainProtein: String

            struct IngredientPayload: Encodable {
                let name: String
                let amount: Double
                let unit: String
            }
        }
    }
}

struct GroceryShoppingSpecResponse: Decodable {
    let items: [ShoppingSpecItem]
    let coverageSummary: CoverageSummary

    struct ShoppingSpecItem: Decodable, Hashable {
        let name: String
        let originalName: String?
        let canonicalName: String?
        let canonicalKey: String?
        let amount: Double
        let unit: String
        let estimatedPrice: Double?
        let sourceIngredients: [GroceryItemSource]
        let sourceEdgeIDs: [String]?
        let alternativeNames: [String]?
        let coverageState: String?
        let sourceRecipes: [String]
        let shoppingContext: ShoppingContext?
        let confidence: Double?
        let reason: String?
    }

    struct ShoppingContext: Decodable, Hashable {
        let canonicalName: String?
        let canonicalKey: String?
        let role: String?
        let exactness: String?
        let preferredForms: [String]
        let avoidForms: [String]
        let alternateQueries: [String]
        let alternativeNames: [String]?
        let sourceEdgeIDs: [String]?
        let coverageState: String?
        let requiredDescriptors: [String]
        let substitutionPolicy: String?
        let isPantryStaple: Bool
        let isOptional: Bool
        let packageRule: PackageRule?
        let storeFitWeight: Double?
        let sourceIngredientNames: [String]
        let recipeTitles: [String]
        let cuisines: [String]
        let tags: [String]
        let recipeSignals: [String]
        let neighborIngredients: [String]

        struct PackageRule: Decodable, Hashable {
            let packageUnit: String
            let packageSize: Double
        }
    }

    struct CoverageSummary: Decodable, Hashable {
        let totalBaseUses: Int
        let accountedBaseUses: Int
        let uncoveredBaseLabels: [String]
    }
}

/// Used by Instacart / Kroger / Walmart — returns a single cart URL
struct GroceryCartURLResponse: Decodable {
    let provider: String
    let cartUrl: String
    let expiresAt: String?
    let itemCount: Int
    let providerStatus: String
    let note: String?
    let resolvedProducts: [ResolvedProduct]?
    let selectedStore: ProviderStoreSelection?
    let storeOptions: [ProviderStoreSelection]?
    let partialSuccess: Bool?
    let addedItems: [ProviderCartReviewItem]?
    let unresolvedItems: [ProviderCartReviewItem]?

    struct ResolvedProduct: Decodable {
        let requested: String
        let matched: String?
        let brand: String?
        let price: Double?
        let imageUrl: String?
        let upc: String?
    }

}

struct ProviderStatusResponse: Decodable {
    let providers: [ProviderInfo]

    struct ProviderInfo: Decodable {
        let id: String
        let name: String
        let status: String
        let coverage: [String]
        let note: String?
    }
}

// MARK: - GroceryService

/// Wraps all calls to the Ounje grocery pipeline server endpoints.
final class GroceryService {

    static let shared = GroceryService()

    private let session = URLSession.shared
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        return e
    }()

    private init() {}

    func fetchShoppingSpec(items: [GroceryItem], plan: MealPlan? = nil) async throws -> GroceryShoppingSpecResponse {
        try await fetchShoppingSpec(items: items, plan: plan, refreshToken: nil)
    }

    func fetchShoppingSpec(
        items: [GroceryItem],
        plan: MealPlan? = nil,
        refreshToken: String?
    ) async throws -> GroceryShoppingSpecResponse {
        if items.isEmpty {
            return GroceryShoppingSpecResponse(
                items: [],
                coverageSummary: GroceryShoppingSpecResponse.CoverageSummary(
                    totalBaseUses: 0,
                    accountedBaseUses: 0,
                    uncoveredBaseLabels: []
                )
            )
        }

        let planPayload: GroceryShoppingSpecRequest.PlanPayload?
        if let mealPlan = plan {
            planPayload = GroceryShoppingSpecRequest.PlanPayload(
                recipes: mealPlan.recipes.map { plannedRecipe in
                    GroceryShoppingSpecRequest.PlanPayload.RecipePayload(
                        recipe: GroceryShoppingSpecRequest.PlanPayload.EmbeddedRecipePayload(
                            id: plannedRecipe.recipe.id,
                            title: plannedRecipe.recipe.title,
                            cuisine: plannedRecipe.recipe.cuisine.rawValue,
                            tags: plannedRecipe.recipe.tags,
                            ingredients: plannedRecipe.recipe.ingredients.map { ingredient in
                                GroceryShoppingSpecRequest.PlanPayload.EmbeddedRecipePayload.IngredientPayload(
                                    name: ingredient.name,
                                    amount: ingredient.amount,
                                    unit: ingredient.unit
                                )
                            },
                            cookMethod: "",
                            recipeType: "",
                            category: "",
                            mainProtein: ""
                        )
                    )
                }
            )
        } else {
            planPayload = nil
        }

        let payload = GroceryShoppingSpecRequest(
            items: items.map {
                .init(
                    name: $0.name,
                    amount: $0.amount,
                    unit: $0.unit,
                    estimatedPrice: $0.estimatedPrice,
                    sourceIngredients: $0.sourceIngredients.map {
                        .init(recipeID: $0.recipeID, ingredientName: $0.ingredientName, unit: $0.unit)
                    }
                )
            },
            plan: planPayload,
            refreshToken: refreshToken
        )

        let data = try await post(path: "/v1/grocery/spec", body: payload, timeout: 45)
        return try decoder.decode(GroceryShoppingSpecResponse.self, from: data)
    }

    // MARK: - Build cart URL for supported providers

    /// Returns a ProviderQuote with a cart URL (opens in SFSafariViewController).
    func buildCartURL(
        provider: ShoppingProvider,
        items: [GroceryItem],
        recipeTitle: String? = nil,
        recipeImageURL: String? = nil,
        recipeID: String? = nil,
        deliveryAddress: DeliveryAddress? = nil,
        userID: String? = nil,
        accessToken: String? = nil
    ) async throws -> ProviderQuote {
        guard !items.isEmpty else {
            return ProviderQuote(
                provider: provider,
                subtotal: 0,
                deliveryFee: 0,
                estimatedTotal: 0,
                etaDays: 0,
                orderURL: URL(string: "about:blank")!,
                providerStatus: .deepLink,
                expiresAt: nil,
                selectedStore: nil,
                storeOptions: [],
                partialSuccess: false,
                reviewItems: []
            )
        }

        let addr = deliveryAddress?.isComplete == true ? deliveryAddress : nil
        let payload = GroceryCartRequest(
            provider: provider.rawValue,
            items: items.map {
                .init(
                    name: $0.name,
                    amount: $0.amount,
                    unit: $0.unit,
                    estimatedPrice: $0.estimatedPrice,
                    sourceIngredients: $0.sourceIngredients.map {
                        .init(recipeID: $0.recipeID, ingredientName: $0.ingredientName, unit: $0.unit)
                    }
                )
            },
            recipeContext: (recipeTitle != nil || recipeID != nil) ? .init(
                title: recipeTitle ?? "Recipe Ingredients",
                imageUrl: recipeImageURL,
                recipeId: recipeID
            ) : nil,
            deliveryAddress: addr.map {
                .init(line1: $0.line1, city: $0.city, region: $0.region, postalCode: $0.postalCode, country: "US")
            }
        )

        let data = try await post(
            path: "/v1/grocery/cart",
            body: payload,
            timeout: 15,
            userID: userID,
            accessToken: accessToken
        )
        let cartResponse = try decoder.decode(GroceryCartURLResponse.self, from: data)

        guard let cartURL = URL(string: cartResponse.cartUrl) else {
            throw GroceryServiceError.invalidCartURL(cartResponse.cartUrl)
        }

        let subtotal    = items.reduce(0) { $0 + $1.estimatedPrice }
        let deliveryFee = provider.deliveryFee
        let combinedReviewItems = deduplicatedReviewItems(
            (cartResponse.addedItems ?? []).filter { $0.status.caseInsensitiveCompare("exact") != .orderedSame || $0.needsReview }
            + (cartResponse.unresolvedItems ?? [])
        )

        return ProviderQuote(
            provider: provider,
            subtotal: subtotal,
            deliveryFee: deliveryFee,
            estimatedTotal: subtotal + deliveryFee,
            etaDays: provider.etaDays,
            orderURL: cartURL,
            providerStatus: cartResponse.providerStatus == "live" ? .live : .deepLink,
            expiresAt: cartResponse.expiresAt.flatMap { ISO8601DateFormatter().date(from: $0) },
            selectedStore: cartResponse.selectedStore,
            storeOptions: cartResponse.storeOptions ?? [],
            partialSuccess: cartResponse.partialSuccess ?? false,
            reviewItems: combinedReviewItems
        )
    }

    // MARK: - Build quotes for all preferred providers (parallel, legacy path)

    func buildQuotes(
        for items: [GroceryItem],
        profile: UserProfile,
        recipeTitle: String? = nil,
        recipeImageURL: String? = nil,
        recipeID: String? = nil,
        userID: String? = nil,
        accessToken: String? = nil
    ) async -> [ProviderQuote] {
        guard !items.isEmpty else { return [] }
        let address = profile.deliveryAddress.isComplete ? profile.deliveryAddress : nil

        return await withTaskGroup(of: ProviderQuote?.self) { group in
            for provider in profile.preferredProviders {
                group.addTask {
                    try? await self.buildCartURL(
                        provider: provider,
                        items: items,
                        recipeTitle: recipeTitle,
                        recipeImageURL: recipeImageURL,
                        recipeID: recipeID,
                        deliveryAddress: address,
                        userID: userID,
                        accessToken: accessToken
                    )
                }
            }
            var quotes: [ProviderQuote] = []
            for await quote in group {
                if let q = quote { quotes.append(q) }
            }
            return quotes.sorted { $0.estimatedTotal < $1.estimatedTotal }
        }
    }

    // MARK: - Provider statuses

    func fetchProviderStatuses() async throws -> [ProviderStatusResponse.ProviderInfo] {
        var lastError: Error?
        for baseURL in OunjeDevelopmentServer.candidateBaseURLs {
            do {
                return try await fetchProviderStatuses(baseURL: baseURL)
            } catch {
                lastError = error
            }
        }

        throw lastError ?? GroceryServiceError.invalidURL
    }

    // MARK: - Private helpers

    private func post<B: Encodable>(
        path: String,
        body: B,
        timeout: TimeInterval,
        userID: String? = nil,
        accessToken: String? = nil
    ) async throws -> Data {
        var lastError: Error?
        for baseURL in OunjeDevelopmentServer.candidateBaseURLs {
            do {
                return try await post(
                    baseURL: baseURL,
                    path: path,
                    body: body,
                    timeout: timeout,
                    userID: userID,
                    accessToken: accessToken
                )
            } catch {
                lastError = error
            }
        }

        throw lastError ?? GroceryServiceError.invalidURL
    }

    private func post<B: Encodable>(
        baseURL: String,
        path: String,
        body: B,
        timeout: TimeInterval,
        userID: String? = nil,
        accessToken: String? = nil
    ) async throws -> Data {
        guard let url = URL(string: "\(baseURL)\(path)") else {
            throw GroceryServiceError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let userID, !userID.isEmpty {
            request.setValue(userID, forHTTPHeaderField: "x-user-id")
        }
        if let accessToken, !accessToken.isEmpty {
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try encoder.encode(body)
        request.timeoutInterval = timeout

        let (data, response) = try await session.data(for: request)
        try validateHTTP(response, data: data)
        return data
    }

    private func fetchProviderStatuses(baseURL: String) async throws -> [ProviderStatusResponse.ProviderInfo] {
        guard let url = URL(string: "\(baseURL)/v1/grocery/providers") else {
            throw GroceryServiceError.invalidURL
        }
        let (data, _) = try await session.data(from: url)
        return try decoder.decode(ProviderStatusResponse.self, from: data).providers
    }

    private func validateHTTP(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw GroceryServiceError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw GroceryServiceError.serverError(http.statusCode, msg)
        }
    }

    private func deduplicatedReviewItems(_ items: [ProviderCartReviewItem]) -> [ProviderCartReviewItem] {
        var seen = Set<String>()
        return items.filter { item in
            seen.insert(item.id).inserted
        }
    }
}

// MARK: - Errors

enum GroceryServiceError: LocalizedError {
    case invalidURL
    case invalidResponse
    case serverError(Int, String)
    case invalidCartURL(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:                return "Invalid server URL"
        case .invalidResponse:           return "Invalid response from server"
        case .serverError(let c, let m): return "Server error \(c): \(m)"
        case .invalidCartURL(let u):     return "Invalid cart URL: \(u)"
        }
    }
}
