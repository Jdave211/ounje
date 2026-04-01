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

/// Used by Instacart / Kroger / Walmart — returns a single cart URL
struct GroceryCartURLResponse: Decodable {
    let provider: String
    let cartUrl: String
    let expiresAt: String?
    let itemCount: Int
    let providerStatus: String
    let note: String?
    let resolvedProducts: [ResolvedProduct]?

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

    private let baseURL = OunjeDevelopmentServer.baseURL

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

    // MARK: - MealMe: search grocery cart

    /// Primary path — calls POST /v1/grocery/cart with provider=mealme.
    /// Returns store options ranked by match count + price.
    func searchMealMeCart(
        items: [GroceryItem],
        deliveryAddress: DeliveryAddress?,
        recipeTitle: String? = nil,
        recipeImageURL: String? = nil,
        recipeID: String? = nil
    ) async throws -> MealMeCartResponse {
        let addr = deliveryAddress?.isComplete == true ? deliveryAddress : nil

        let payload = GroceryCartRequest(
            provider: "mealme",
            items: items.map { .init(name: $0.name, amount: $0.amount, unit: $0.unit, estimatedPrice: $0.estimatedPrice) },
            recipeContext: (recipeTitle != nil || recipeID != nil) ? .init(
                title: recipeTitle ?? "Recipe Ingredients",
                imageUrl: recipeImageURL,
                recipeId: recipeID
            ) : nil,
            deliveryAddress: addr.map {
                .init(line1: $0.line1, city: $0.city, region: $0.region, postalCode: $0.postalCode, country: "US")
            }
        )

        let data = try await post(path: "/v1/grocery/cart", body: payload, timeout: 20)
        return try decoder.decode(MealMeCartResponse.self, from: data)
    }

    // MARK: - MealMe: fetch live quotes for a chosen store

    func fetchMealMeQuotes(
        storeId: String,
        address: DeliveryAddress?,
        location: MealMeLocation?
    ) async throws -> [MealMeQuote] {
        var components = URLComponents(string: "\(baseURL)/v1/grocery/quotes")!
        components.queryItems = [
            .init(name: "storeId", value: storeId),
            .init(name: "lat",     value: "\(location?.latitude  ?? 37.7786357)"),
            .init(name: "lng",     value: "\(location?.longitude ?? -122.3918135)"),
            .init(name: "line1",   value: address?.line1      ?? ""),
            .init(name: "city",    value: address?.city        ?? ""),
            .init(name: "region",  value: address?.region      ?? ""),
            .init(name: "postalCode", value: address?.postalCode ?? ""),
        ]
        guard let url = components.url else { throw GroceryServiceError.invalidURL }
        let (data, response) = try await session.data(from: url)
        try validateHTTP(response, data: data)
        return try decoder.decode(MealMeQuotesResponse.self, from: data).quotes
    }

    // MARK: - MealMe: create cart

    /// Finalises a MealMe cart for a chosen store + quote.
    /// Returns cart_id + real totals. Call this before showing the checkout CTA.
    func createMealMeCart(
        storeId: String,
        quoteId: String,
        products: [MealMeProduct],
        fulfillment: String = "delivery",
        deliveryAddress: DeliveryAddress?
    ) async throws -> MealMeCreateCartResponse {
        let request = MealMeCreateCartRequest(
            storeId: storeId,
            quoteId: quoteId,
            cartItems: products.map { .init(productId: $0.productId, quantity: $0.quantity) },
            fulfillment: fulfillment,
            customer: nil,
            deliveryAddress: deliveryAddress.map {
                .init(line1: $0.line1, city: $0.city, region: $0.region, postalCode: $0.postalCode)
            }
        )
        let data = try await post(path: "/v1/grocery/cart/create", body: request, timeout: 15)
        return try decoder.decode(MealMeCreateCartResponse.self, from: data)
    }

    // MARK: - Legacy: build cart URL for non-MealMe providers

    /// Returns a ProviderQuote with a cart URL (opens in SFSafariViewController).
    func buildCartURL(
        provider: ShoppingProvider,
        items: [GroceryItem],
        recipeTitle: String? = nil,
        recipeImageURL: String? = nil,
        recipeID: String? = nil,
        deliveryAddress: DeliveryAddress? = nil
    ) async throws -> ProviderQuote {
        guard provider != .mealme else {
            throw GroceryServiceError.useMealMeFlow
        }

        let addr = deliveryAddress?.isComplete == true ? deliveryAddress : nil
        let payload = GroceryCartRequest(
            provider: provider.rawValue,
            items: items.map { .init(name: $0.name, amount: $0.amount, unit: $0.unit, estimatedPrice: $0.estimatedPrice) },
            recipeContext: (recipeTitle != nil || recipeID != nil) ? .init(
                title: recipeTitle ?? "Recipe Ingredients",
                imageUrl: recipeImageURL,
                recipeId: recipeID
            ) : nil,
            deliveryAddress: addr.map {
                .init(line1: $0.line1, city: $0.city, region: $0.region, postalCode: $0.postalCode, country: "US")
            }
        )

        let data = try await post(path: "/v1/grocery/cart", body: payload, timeout: 15)
        let cartResponse = try decoder.decode(GroceryCartURLResponse.self, from: data)

        guard let cartURL = URL(string: cartResponse.cartUrl) else {
            throw GroceryServiceError.invalidCartURL(cartResponse.cartUrl)
        }

        let subtotal    = items.reduce(0) { $0 + $1.estimatedPrice }
        let deliveryFee = provider.deliveryFee

        return ProviderQuote(
            provider: provider,
            subtotal: subtotal,
            deliveryFee: deliveryFee,
            estimatedTotal: subtotal + deliveryFee,
            etaDays: provider.etaDays,
            orderURL: cartURL,
            providerStatus: cartResponse.providerStatus == "live" ? .live : .deepLink,
            expiresAt: cartResponse.expiresAt.flatMap { ISO8601DateFormatter().date(from: $0) }
        )
    }

    // MARK: - Build quotes for all preferred providers (parallel, legacy path)

    func buildQuotes(
        for items: [GroceryItem],
        profile: UserProfile,
        recipeTitle: String? = nil,
        recipeImageURL: String? = nil,
        recipeID: String? = nil
    ) async -> [ProviderQuote] {
        let legacyProviders = profile.preferredProviders.filter { $0 != .mealme }
        let address = profile.deliveryAddress.isComplete ? profile.deliveryAddress : nil

        return await withTaskGroup(of: ProviderQuote?.self) { group in
            for provider in legacyProviders {
                group.addTask {
                    try? await self.buildCartURL(
                        provider: provider,
                        items: items,
                        recipeTitle: recipeTitle,
                        recipeImageURL: recipeImageURL,
                        recipeID: recipeID,
                        deliveryAddress: address
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
        guard let url = URL(string: "\(baseURL)/v1/grocery/providers") else {
            throw GroceryServiceError.invalidURL
        }
        let (data, _) = try await session.data(from: url)
        return try decoder.decode(ProviderStatusResponse.self, from: data).providers
    }

    // MARK: - Private helpers

    private func post<B: Encodable>(path: String, body: B, timeout: TimeInterval) async throws -> Data {
        guard let url = URL(string: "\(baseURL)\(path)") else {
            throw GroceryServiceError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(body)
        request.timeoutInterval = timeout

        let (data, response) = try await session.data(for: request)
        try validateHTTP(response, data: data)
        return data
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
}

// MARK: - Errors

enum GroceryServiceError: LocalizedError {
    case invalidURL
    case invalidResponse
    case serverError(Int, String)
    case invalidCartURL(String)
    case useMealMeFlow

    var errorDescription: String? {
        switch self {
        case .invalidURL:                return "Invalid server URL"
        case .invalidResponse:           return "Invalid response from server"
        case .serverError(let c, let m): return "Server error \(c): \(m)"
        case .invalidCartURL(let u):     return "Invalid cart URL: \(u)"
        case .useMealMeFlow:             return "Use searchMealMeCart() for MealMe"
        }
    }
}
