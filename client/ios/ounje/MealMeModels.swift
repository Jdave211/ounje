import Foundation

// MARK: - MealMe cart search response

/// Top-level response from POST /v1/grocery/cart when provider = "mealme"
struct MealMeCartResponse: Decodable {
    let provider: String
    let providerStatus: String
    let storeOptions: [MealMeStoreOption]
    let itemCount: Int
    let location: MealMeLocation?
}

struct MealMeLocation: Decodable {
    let latitude: Double
    let longitude: Double
}

/// A nearby store with matched products and estimated totals
struct MealMeStoreOption: Identifiable, Decodable, Hashable {
    let storeId: String
    let storeName: String
    let logoUrl: String?
    let address: String?
    let miles: Double?
    let rating: Double?
    let isOpen: Bool
    let deliveryEnabled: Bool
    let pickupEnabled: Bool
    let matchedCount: Int
    let totalItems: Int
    let products: [MealMeProduct]
    let subtotalEstimate: Double
    let quoteIds: [String]

    var id: String { storeId }

    var matchRatio: Double {
        totalItems > 0 ? Double(matchedCount) / Double(totalItems) : 0
    }

    var matchLabel: String {
        "\(matchedCount)/\(totalItems) items found"
    }

    var distanceLabel: String? {
        guard let miles else { return nil }
        return String(format: "%.1f mi", miles)
    }

    var ratingLabel: String? {
        guard let rating else { return nil }
        return String(format: "%.1f", rating)
    }
}

/// A matched grocery product inside a store
struct MealMeProduct: Identifiable, Decodable, Hashable {
    let productId: String
    let name: String
    let brand: String?
    let imageUrl: String?
    let price: Double?
    let unit: String?
    let quantity: Int
    let queryMatch: String?
    let inStock: Bool

    var id: String { productId }

    var priceLabel: String {
        guard let price else { return "—" }
        return String(format: "$%.2f", price)
    }

    var displayName: String {
        if let brand, !brand.isEmpty {
            return "\(brand) \(name)"
        }
        return name
    }
}

// MARK: - Live quote for a store

struct MealMeQuote: Identifiable, Decodable {
    let quoteId: String
    let deliveryFeeCents: Int?
    let estimatedDeliveryMinutes: Int?
    let fulfillment: String?  // "delivery" | "pickup"

    var id: String { quoteId }
    var deliveryFee: Double { Double(deliveryFeeCents ?? 0) / 100 }

    var etaLabel: String {
        guard let mins = estimatedDeliveryMinutes else { return "—" }
        if mins < 60 { return "\(mins) min" }
        return "\(mins / 60)h \(mins % 60)m"
    }
}

struct MealMeQuotesResponse: Decodable {
    let quotes: [MealMeQuote]
}

// MARK: - Cart creation result

struct MealMeCreateCartRequest: Encodable {
    let storeId: String
    let quoteId: String
    let cartItems: [CartItem]
    let fulfillment: String
    let customer: CustomerInfo?
    let deliveryAddress: DeliveryAddressPayload?

    struct CartItem: Encodable {
        let productId: String
        let quantity: Int
    }

    struct CustomerInfo: Encodable {
        let firstName: String
        let lastName: String
        let email: String
        let phone: String
    }

    struct DeliveryAddressPayload: Encodable {
        let line1: String
        let city: String
        let region: String
        let postalCode: String
    }
}

struct MealMeCreateCartResponse: Decodable {
    let cartId: String
    let subtotal: Double?
    let deliveryFee: Double?
    let total: Double?
    let etaMinutes: Int?
}

// MARK: - View state

enum MealMeFlowState {
    case idle
    case searching
    case storeSelection([MealMeStoreOption])
    case loadingQuote(MealMeStoreOption)
    case readyToOrder(MealMeStoreOption, MealMeQuote?)
    case creatingCart
    case cartReady(cartId: String, total: Double?)
    case fallback(url: URL)
    case error(String)

    var isCreatingCart: Bool {
        if case .creatingCart = self { return true }
        return false
    }
}
