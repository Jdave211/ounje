import Foundation

struct InventoryItem: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var amount: Double
    var unit: String
}

struct PlannedRecipe: Identifiable, Codable, Hashable {
    var id: String { recipe.id }
    var recipe: Recipe
    var servings: Int
    var carriedFromPreviousPlan: Bool
}

struct GroceryItemSource: Codable, Hashable {
    var recipeID: String
    var ingredientName: String
    var unit: String
}

struct GroceryItem: Identifiable, Codable, Hashable {
    var id: String {
        "\(name.lowercased())::\(unit.lowercased())"
    }

    var name: String
    var amount: Double
    var unit: String
    var estimatedPrice: Double
    var sourceIngredients: [GroceryItemSource]

    init(
        name: String,
        amount: Double,
        unit: String,
        estimatedPrice: Double,
        sourceIngredients: [GroceryItemSource] = []
    ) {
        self.name = name
        self.amount = amount
        self.unit = unit
        self.estimatedPrice = estimatedPrice
        self.sourceIngredients = sourceIngredients
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case amount
        case unit
        case estimatedPrice
        case sourceIngredients
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        amount = try container.decode(Double.self, forKey: .amount)
        unit = try container.decode(String.self, forKey: .unit)
        estimatedPrice = try container.decode(Double.self, forKey: .estimatedPrice)
        sourceIngredients = try container.decodeIfPresent([GroceryItemSource].self, forKey: .sourceIngredients) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(amount, forKey: .amount)
        try container.encode(unit, forKey: .unit)
        try container.encode(estimatedPrice, forKey: .estimatedPrice)
        try container.encode(sourceIngredients, forKey: .sourceIngredients)
    }
}

struct ProviderCartReviewItem: Identifiable, Codable, Hashable {
    var id: String {
        [
            requested.lowercased(),
            status.lowercased(),
            matched?.lowercased() ?? "",
            matchedStore?.lowercased() ?? ""
        ].joined(separator: "::")
    }

    var requested: String
    var normalizedQuery: String?
    var matched: String?
    var quantityRequested: Int?
    var quantityAdded: Int?
    var quantity: Double?
    var status: String
    var matchedStore: String?
    var decision: String?
    var matchType: String?
    var needsReview: Bool
    var reason: String?
    var substituteReason: String?
    var refinedQuery: String?
}

struct ProviderQuote: Identifiable, Codable, Hashable {
    var id: String { provider.rawValue }
    var provider: ShoppingProvider
    var subtotal: Double
    var deliveryFee: Double
    var estimatedTotal: Double
    var etaDays: Int
    var orderURL: URL
    /// "live" = real API cart page, "deep_link" = browser search fallback
    var providerStatus: ProviderQuoteStatus
    /// Instacart shoppable links expire after ~24 hrs
    var expiresAt: Date?
    var selectedStore: ProviderStoreSelection?
    var storeOptions: [ProviderStoreSelection]
    var partialSuccess: Bool
    var reviewItems: [ProviderCartReviewItem]

    init(
        provider: ShoppingProvider,
        subtotal: Double,
        deliveryFee: Double,
        estimatedTotal: Double,
        etaDays: Int,
        orderURL: URL,
        providerStatus: ProviderQuoteStatus = .deepLink,
        expiresAt: Date? = nil,
        selectedStore: ProviderStoreSelection? = nil,
        storeOptions: [ProviderStoreSelection] = [],
        partialSuccess: Bool = false,
        reviewItems: [ProviderCartReviewItem] = []
    ) {
        self.provider = provider
        self.subtotal = subtotal
        self.deliveryFee = deliveryFee
        self.estimatedTotal = estimatedTotal
        self.etaDays = etaDays
        self.orderURL = orderURL
        self.providerStatus = providerStatus
        self.expiresAt = expiresAt
        self.selectedStore = selectedStore
        self.storeOptions = storeOptions
        self.partialSuccess = partialSuccess
        self.reviewItems = reviewItems
    }
}

struct ProviderStoreSelection: Codable, Hashable {
    let storeName: String
    let score: Double
    let matchedCount: Int
    let totalProbes: Int
    let distanceKm: Double?
    let deliveryText: String?
    let sourceUrl: String?
    let coverageRatio: Double?
}

enum ProviderQuoteStatus: String, Codable, Hashable {
    case live       // real API — pre-filled cart
    case deepLink   // browser search fallback
}

enum AgentStage: String, Codable, CaseIterable, Identifiable {
    case interpretProfile
    case curateRecipes
    case handleRotation
    case composeGroceries
    case optimizeProvider

    var id: String { rawValue }

    var title: String {
        switch self {
        case .interpretProfile: return "Interpreted profile"
        case .curateRecipes: return "Curated recipes"
        case .handleRotation: return "Applied rotation strategy"
        case .composeGroceries: return "Built grocery list"
        case .optimizeProvider: return "Optimized provider"
        }
    }
}

struct PipelineDecision: Identifiable, Codable, Hashable {
    var id: String {
        "\(stage.rawValue)::\(summary)"
    }

    var stage: AgentStage
    var summary: String
}

struct MealPlan: Identifiable, Codable, Hashable {
    var id: UUID
    var generatedAt: Date
    var periodStart: Date
    var periodEnd: Date
    var cadence: MealCadence
    var recipes: [PlannedRecipe]
    var groceryItems: [GroceryItem]
    var providerQuotes: [ProviderQuote]
    var pipeline: [PipelineDecision]
    var mainShopSnapshot: MainShopSnapshot? = nil
    var recurringRecipeIDs: [String]? = nil

    var bestQuote: ProviderQuote? {
        providerQuotes.first
    }
}

struct MainShopSnapshot: Codable, Hashable {
    var signature: String
    var generatedAt: Date
    var items: [MainShopSnapshotItem]
    var coverageSummary: MainShopCoverageSummary?
}

struct MainShopSnapshotItem: Identifiable, Codable, Hashable {
    var id: String {
        "\(name.lowercased())::\(quantityText.lowercased())::\(supportingText?.lowercased() ?? "")"
    }

    var name: String
    var quantityText: String
    var supportingText: String?
    var imageURLString: String?
    var estimatedPriceText: String?
    var estimatedPriceValue: Double
    var sectionKindRawValue: Int?
    var removalKey: String?
    var canonicalKey: String? = nil
    var sourceIngredients: [GroceryItemSource]? = nil
    var sourceEdgeIDs: [String]? = nil
    var alternativeNames: [String]? = nil
    var coverageState: String? = nil
}

struct MainShopCoverageSummary: Codable, Hashable {
    var totalBaseUses: Int
    var accountedBaseUses: Int
    var uncoveredBaseLabels: [String]
}

struct MealPrepCompletedCycle: Identifiable, Codable, Hashable {
    var id: UUID
    var userID: String
    var planID: UUID
    var plan: MealPlan
    var completedAt: String

    var completedAtDate: Date? {
        ISO8601DateFormatter().date(from: completedAt)
    }

    var sortDate: Date {
        completedAtDate ?? plan.periodEnd
    }
}

struct RecurringPrepRecipe: Identifiable, Codable, Hashable {
    var userID: String
    var recipeID: String
    var recipe: Recipe
    var isEnabled: Bool
    var createdAt: String?
    var updatedAt: String?

    var id: String { recipeID }

    var sortDate: Date {
        let formatter = ISO8601DateFormatter()
        return updatedAt.flatMap(formatter.date(from:))
            ?? createdAt.flatMap(formatter.date(from:))
            ?? .distantPast
    }
}

struct MealPrepAutomationState: Codable, Hashable {
    var userID: String
    var lastEvaluatedAt: String?
    var nextPlanningWindowAt: String?
    var lastGeneratedForDeliveryAt: String?
    var lastGeneratedPlanID: UUID?
    var lastGeneratedReason: String?
    var lastCartSyncForDeliveryAt: String?
    var lastCartSyncPlanID: UUID?
    var lastCartSignature: String?
    var lastInstacartRunID: String?
    var lastInstacartRunStatus: String?
    var lastInstacartRetryQueuedForRunID: String?
    var lastInstacartRetryQueuedAt: String?
}

struct PrepRecipeOverride: Identifiable, Codable, Hashable {
    var id: String { recipe.id }
    var recipe: Recipe
    var servings: Int
    var isIncludedInPrep: Bool

    init(recipe: Recipe, servings: Int, isIncludedInPrep: Bool = true) {
        self.recipe = recipe
        self.servings = max(1, servings)
        self.isIncludedInPrep = isIncludedInPrep
    }
}

extension Date {
    func adding(days: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: days, to: self) ?? self
    }
}

extension Double {
    func roundedString(_ decimals: Int = 1) -> String {
        String(format: "%.\(decimals)f", self)
    }

    var asCurrency: String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.maximumFractionDigits = 2
        formatter.minimumFractionDigits = 2
        return formatter.string(from: NSNumber(value: self)) ?? "$0.00"
    }
}
