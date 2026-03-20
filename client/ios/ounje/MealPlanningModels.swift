import Foundation

enum CuisinePreference: String, CaseIterable, Codable, Identifiable {
    case italian
    case mexican
    case mediterranean
    case asian
    case indian
    case american
    case middleEastern
    case japanese
    case thai
    case korean
    case chinese
    case greek
    case french
    case spanish
    case caribbean
    case westAfrican
    case ethiopian
    case brazilian
    case vegan

    var id: String { rawValue }

    var title: String {
        switch self {
        case .italian: return "Italian"
        case .mexican: return "Mexican"
        case .mediterranean: return "Mediterranean"
        case .asian: return "Asian"
        case .indian: return "Indian"
        case .american: return "American"
        case .middleEastern: return "Middle Eastern"
        case .japanese: return "Japanese"
        case .thai: return "Thai"
        case .korean: return "Korean"
        case .chinese: return "Chinese"
        case .greek: return "Greek"
        case .french: return "French"
        case .spanish: return "Spanish"
        case .caribbean: return "Caribbean"
        case .westAfrican: return "Nigerian"
        case .ethiopian: return "Ethiopian"
        case .brazilian: return "Brazilian"
        case .vegan: return "Vegan"
        }
    }
}

enum MealCadence: String, CaseIterable, Codable, Identifiable {
    case daily
    case everyFewDays
    case twiceWeekly
    case weekly
    case biweekly
    case monthly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .daily: return "Daily"
        case .everyFewDays: return "Every few days"
        case .twiceWeekly: return "Twice weekly"
        case .weekly: return "Every week"
        case .biweekly: return "Every 2 weeks"
        case .monthly: return "Every month"
        }
    }

    var dayInterval: Int {
        switch self {
        case .daily: return 1
        case .everyFewDays: return 3
        case .twiceWeekly: return 4
        case .weekly: return 7
        case .biweekly: return 14
        case .monthly: return 30
        }
    }

    var baseRecipeCount: Int {
        switch self {
        case .daily: return 2
        case .everyFewDays: return 3
        case .twiceWeekly: return 4
        case .weekly: return 5
        case .biweekly: return 9
        case .monthly: return 16
        }
    }
}

enum RecipeRotationPreference: String, CaseIterable, Codable, Identifiable {
    case dynamic
    case stable

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dynamic: return "Dynamic"
        case .stable: return "Stable"
        }
    }

    var subtitle: String {
        switch self {
        case .dynamic: return "Prefer variety and avoid last cycle repeats."
        case .stable: return "Keep favorites and rotate only a small subset."
        }
    }
}

enum MealExplorationLevel: String, CaseIterable, Codable, Identifiable {
    case comfort
    case balanced
    case adventurous

    var id: String { rawValue }

    var title: String {
        switch self {
        case .comfort: return "Comfort"
        case .balanced: return "Balanced"
        case .adventurous: return "Adventurous"
        }
    }

    var subtitle: String {
        switch self {
        case .comfort: return "Mostly familiar recipes."
        case .balanced: return "Some familiar, some new."
        case .adventurous: return "Frequent variety and surprises."
        }
    }
}

enum ShoppingProvider: String, CaseIterable, Codable, Identifiable {
    case walmart
    case instacart
    case amazonFresh

    var id: String { rawValue }

    var title: String {
        switch self {
        case .walmart: return "Walmart"
        case .instacart: return "Instacart"
        case .amazonFresh: return "Amazon Fresh"
        }
    }

    var priceMultiplier: Double {
        switch self {
        case .walmart: return 0.96
        case .instacart: return 1.08
        case .amazonFresh: return 1.02
        }
    }

    var deliveryFee: Double {
        switch self {
        case .walmart: return 8.95
        case .instacart: return 9.99
        case .amazonFresh: return 7.99
        }
    }

    var etaDays: Int {
        switch self {
        case .walmart: return 2
        case .instacart: return 1
        case .amazonFresh: return 2
        }
    }

    func buildOrderURL(using items: [GroceryItem], deliveryAddress: DeliveryAddress? = nil) -> URL {
        let groceryQuery = items
            .prefix(10)
            .map { $0.name }
            .joined(separator: ", ")
        let locationQuery = [deliveryAddress?.city, deliveryAddress?.postalCode]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let query = [groceryQuery, locationQuery]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "groceries"

        let rawURL: String
        switch self {
        case .walmart:
            rawURL = "https://www.walmart.com/search?q=\(query)"
        case .instacart:
            rawURL = "https://www.instacart.com/store/s?k=\(query)"
        case .amazonFresh:
            rawURL = "https://www.amazon.com/s?k=\(query)&i=amazonfresh"
        }

        return URL(string: rawURL) ?? URL(string: "https://www.google.com/search?q=groceries")!
    }
}

struct StorageProfile: Codable, Hashable {
    var pantryCapacity: Int
    var fridgeCapacity: Int
    var freezerCapacity: Int

    static let starter = StorageProfile(pantryCapacity: 18, fridgeCapacity: 14, freezerCapacity: 10)
}

struct ConsumptionProfile: Codable, Hashable {
    var adults: Int
    var kids: Int
    var mealsPerWeek: Int
    var includeLeftovers: Bool

    static let starter = ConsumptionProfile(adults: 2, kids: 0, mealsPerWeek: 5, includeLeftovers: true)

    var householdMultiplier: Double {
        Double(adults) + (Double(kids) * 0.6)
    }
}

struct DeliveryAddress: Codable, Hashable {
    var line1: String
    var line2: String
    var city: String
    var region: String
    var postalCode: String
    var deliveryNotes: String

    static let empty = DeliveryAddress(
        line1: "",
        line2: "",
        city: "",
        region: "",
        postalCode: "",
        deliveryNotes: ""
    )

    var isComplete: Bool {
        !line1.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !city.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !region.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !postalCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

enum BudgetWindow: String, CaseIterable, Codable, Identifiable {
    case weekly
    case monthly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .weekly: return "Per week"
        case .monthly: return "Per month"
        }
    }
}

enum BudgetFlexibility: String, CaseIterable, Codable, Identifiable {
    case strict
    case slightlyFlexible
    case convenienceFirst

    var id: String { rawValue }

    var title: String {
        switch self {
        case .strict: return "Hold the line"
        case .slightlyFlexible: return "Some flexibility"
        case .convenienceFirst: return "Pay more for convenience"
        }
    }

    var subtitle: String {
        switch self {
        case .strict: return "Stay close to the target budget."
        case .slightlyFlexible: return "Stretch a bit for noticeably better meals."
        case .convenienceFirst: return "Spend more when it saves time or improves quality."
        }
    }
}

enum PurchasingBehavior: String, CaseIterable, Codable, Identifiable {
    case cheapest
    case healthier
    case premium
    case largerPacks
    case lowLeftovers

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cheapest: return "Cheapest options"
        case .healthier: return "Healthier picks"
        case .premium: return "Premium ingredients"
        case .largerPacks: return "Larger packs"
        case .lowLeftovers: return "Fewer leftovers"
        }
    }
}

enum OrderingAutonomyLevel: String, CaseIterable, Codable, Identifiable {
    case suggestOnly
    case approvalRequired
    case autoOrderWithinBudget
    case fullyAutonomousGuardrails

    var id: String { rawValue }

    var title: String {
        switch self {
        case .suggestOnly: return "Suggest only"
        case .approvalRequired: return "Approve before checkout"
        case .autoOrderWithinBudget: return "Auto-order within budget"
        case .fullyAutonomousGuardrails: return "Fully autonomous with guardrails"
        }
    }
}

struct MealPrepSummarySection: Identifiable, Codable, Hashable {
    var id: String { title }
    var title: String
    var detail: String
}

struct UserProfile: Codable, Hashable {
    var preferredCuisines: [CuisinePreference]
    var cadence: MealCadence
    var rotationPreference: RecipeRotationPreference
    var maxRepeatsPerCycle: Int
    var storage: StorageProfile
    var consumption: ConsumptionProfile
    var preferredProviders: [ShoppingProvider]
    var pantryStaples: [String]
    var allergies: [String]
    var budgetPerCycle: Double
    var explorationLevel: MealExplorationLevel
    var deliveryAddress: DeliveryAddress
    var dietaryPatterns: [String]
    var cuisineCountries: [String]
    var hardRestrictions: [String]
    var favoriteFoods: [String]
    var favoriteFlavors: [String]
    var neverIncludeFoods: [String]
    var mealPrepGoals: [String]
    var cooksForOthers: Bool
    var kitchenEquipment: [String]
    var budgetWindow: BudgetWindow
    var budgetFlexibility: BudgetFlexibility
    var purchasingBehavior: PurchasingBehavior
    var orderingAutonomy: OrderingAutonomyLevel

    init(
        preferredCuisines: [CuisinePreference],
        cadence: MealCadence,
        rotationPreference: RecipeRotationPreference,
        maxRepeatsPerCycle: Int,
        storage: StorageProfile,
        consumption: ConsumptionProfile,
        preferredProviders: [ShoppingProvider],
        pantryStaples: [String],
        allergies: [String],
        budgetPerCycle: Double,
        explorationLevel: MealExplorationLevel,
        deliveryAddress: DeliveryAddress,
        dietaryPatterns: [String] = [],
        cuisineCountries: [String] = [],
        hardRestrictions: [String] = [],
        favoriteFoods: [String] = [],
        favoriteFlavors: [String] = [],
        neverIncludeFoods: [String] = [],
        mealPrepGoals: [String] = [],
        cooksForOthers: Bool = false,
        kitchenEquipment: [String] = [],
        budgetWindow: BudgetWindow = .weekly,
        budgetFlexibility: BudgetFlexibility = .strict,
        purchasingBehavior: PurchasingBehavior = .healthier,
        orderingAutonomy: OrderingAutonomyLevel = .autoOrderWithinBudget
    ) {
        self.preferredCuisines = preferredCuisines
        self.cadence = cadence
        self.rotationPreference = rotationPreference
        self.maxRepeatsPerCycle = maxRepeatsPerCycle
        self.storage = storage
        self.consumption = consumption
        self.preferredProviders = preferredProviders
        self.pantryStaples = pantryStaples
        self.allergies = allergies
        self.budgetPerCycle = budgetPerCycle
        self.explorationLevel = explorationLevel
        self.deliveryAddress = deliveryAddress
        self.dietaryPatterns = dietaryPatterns
        self.cuisineCountries = cuisineCountries
        self.hardRestrictions = hardRestrictions
        self.favoriteFoods = favoriteFoods
        self.favoriteFlavors = favoriteFlavors
        self.neverIncludeFoods = neverIncludeFoods
        self.mealPrepGoals = mealPrepGoals
        self.cooksForOthers = cooksForOthers
        self.kitchenEquipment = kitchenEquipment
        self.budgetWindow = budgetWindow
        self.budgetFlexibility = budgetFlexibility
        self.purchasingBehavior = purchasingBehavior
        self.orderingAutonomy = orderingAutonomy
    }

    static let starter = UserProfile(
        preferredCuisines: [.american, .chinese, .westAfrican],
        cadence: .weekly,
        rotationPreference: .dynamic,
        maxRepeatsPerCycle: 2,
        storage: .starter,
        consumption: .starter,
        preferredProviders: [.walmart, .instacart],
        pantryStaples: ["olive oil", "salt", "black pepper", "garlic"],
        allergies: [],
        budgetPerCycle: 140,
        explorationLevel: .balanced,
        deliveryAddress: .empty,
        dietaryPatterns: ["Omnivore"],
        cuisineCountries: [],
        favoriteFoods: ["Chicken bowls", "Pasta", "Rice bowls"],
        favoriteFlavors: ["Savory", "Spicy"],
        mealPrepGoals: ["Speed", "Taste", "Variety"],
        kitchenEquipment: ["Oven", "Stovetop", "Microwave"],
        budgetWindow: .weekly,
        budgetFlexibility: .strict,
        purchasingBehavior: .healthier,
        orderingAutonomy: .autoOrderWithinBudget
    )

    var isAutomationReady: Bool {
        !preferredCuisines.isEmpty && deliveryAddress.isComplete && budgetPerCycle >= 25
    }

    var absoluteRestrictions: [String] {
        normalizedUnique(allergies + hardRestrictions + neverIncludeFoods)
    }

    var budgetSummary: String {
        "\(budgetPerCycle.asCurrency) \(budgetWindow == .weekly ? "per week" : "per month")"
    }

    var userFacingCuisineTitles: [String] {
        preferredCuisines
            .filter { $0 != .vegan }
            .map(\.title)
    }

    var householdSummary: String {
        let peopleCount = consumption.adults + consumption.kids
        let peopleText = peopleCount == 1 ? "1 person" : "\(peopleCount) people"
        if cooksForOthers {
            return "\(peopleText), cooking for others too"
        }
        return "\(peopleText), primarily self-serve"
    }

    var profileHeadline: String {
        "\(primaryGoalDescriptor) \(cadenceDescriptor) prep profile"
    }

    var profileNarrative: String {
        var fragments: [String] = []
        fragments.append("Built around \(joinedOrFallback(userFacingCuisineTitles, fallback: "flexible comfort meals"))")
        fragments.append("for \(householdSummary)")
        fragments.append("at \(budgetSummary.lowercased())")

        if !absoluteRestrictions.isEmpty {
            fragments.append("while locking out \(joinedOrFallback(Array(absoluteRestrictions.prefix(3)), fallback: "hard restrictions").lowercased())")
        }

        return fragments.joined(separator: ", ") + "."
    }

    var profileSignals: [String] {
        var signals: [String] = [
            cadence.title,
            budgetFlexibility.title,
            orderingAutonomy.title
        ]

        if let firstGoal = mealPrepGoals.first {
            signals.insert(firstGoal, at: 1)
        }

        if let firstCuisine = userFacingCuisineTitles.first {
            signals.append(firstCuisine)
        }

        return normalizedUnique(signals)
    }

    var profileReadinessNotes: [String] {
        var notes: [String] = []

        if !absoluteRestrictions.isEmpty {
            notes.append("Hard guardrails are active for \(joinedOrFallback(Array(absoluteRestrictions.prefix(3)), fallback: "restricted ingredients").lowercased()).")
        }

        if !favoriteFoods.isEmpty {
            notes.append("The planner will lean into \(joinedOrFallback(Array(favoriteFoods.prefix(3)), fallback: "your go-to meals").lowercased()) first.")
        }

        notes.append("Meal cadence is set to \(cadence.title.lowercased()) with \(consumption.mealsPerWeek) planned meals per week.")
        notes.append("Budget guardrails are set to \(budgetSummary.lowercased()) with \(budgetFlexibility.title.lowercased()).")

        return notes
    }

    var structuredSummarySections: [MealPrepSummarySection] {
        var tasteLines: [String] = [
            "Cuisines: \(joinedOrFallback(userFacingCuisineTitles, fallback: "Open"))",
            "Country cuisines: \(joinedOrFallback(cuisineCountries, fallback: "None added"))",
            "Likes: \(joinedOrFallback(favoriteFoods, fallback: "Not specified"))"
        ]

        if !neverIncludeFoods.isEmpty {
            tasteLines.append("Never include: \(joinedOrFallback(neverIncludeFoods, fallback: "None listed"))")
        }

        return [
            MealPrepSummarySection(
                title: "Dietary identity",
                detail: joinedOrFallback(dietaryPatterns, fallback: "No dietary pattern set")
            ),
            MealPrepSummarySection(
                title: "Hard restrictions",
                detail: joinedOrFallback(absoluteRestrictions, fallback: "No hard restrictions recorded")
            ),
            MealPrepSummarySection(
                title: "Taste profile",
                detail: tasteLines.joined(separator: "\n")
            ),
            MealPrepSummarySection(
                title: "Meal-prep intent",
                detail: joinedOrFallback(mealPrepGoals, fallback: "Balanced planning")
            ),
            MealPrepSummarySection(
                title: "Household",
                detail: [
                    householdSummary,
                    "\(consumption.adults) adult(s), \(consumption.kids) kid(s)",
                    "\(consumption.mealsPerWeek) planned meals per week",
                    consumption.includeLeftovers ? "Leftovers encouraged" : "Minimal leftovers"
                ].joined(separator: "\n")
            ),
            MealPrepSummarySection(
                title: "Cadence and budget",
                detail: [
                    cadence.title,
                    budgetSummary,
                    budgetFlexibility.subtitle
                ].joined(separator: "\n")
            ),
            MealPrepSummarySection(
                title: "Kitchen setup",
                detail: joinedOrFallback(kitchenEquipment, fallback: "Basic kitchen only")
            ),
            MealPrepSummarySection(
                title: "Ordering",
                detail: "Autonomy: \(orderingAutonomy.title)"
            )
        ]
    }

    private var primaryGoalDescriptor: String {
        let loweredGoals = mealPrepGoals.map { $0.lowercased() }

        if loweredGoals.contains(where: { $0.contains("speed") }) {
            return "Fast-lane"
        }
        if loweredGoals.contains(where: { $0.contains("cost") }) {
            return "Budget-locked"
        }
        if loweredGoals.contains(where: { $0.contains("variety") }) {
            return "Variety-first"
        }
        if loweredGoals.contains(where: { $0.contains("macro") || $0.contains("protein") }) {
            return "Macro-minded"
        }
        if loweredGoals.contains(where: { $0.contains("family") }) {
            return "Household-ready"
        }
        if loweredGoals.contains(where: { $0.contains("cleanup") }) {
            return "Low-mess"
        }
        if loweredGoals.contains(where: { $0.contains("taste") }) {
            return "Flavor-first"
        }

        return "Adaptive"
    }

    private var cadenceDescriptor: String {
        switch cadence {
        case .daily:
            return "daily"
        case .everyFewDays:
            return "steady-cycle"
        case .twiceWeekly:
            return "twice-weekly"
        case .weekly:
            return "weekly"
        case .biweekly:
            return "biweekly"
        case .monthly:
            return "monthly"
        }
    }

    private enum CodingKeys: String, CodingKey {
        case preferredCuisines
        case cadence
        case rotationPreference
        case maxRepeatsPerCycle
        case storage
        case consumption
        case preferredProviders
        case pantryStaples
        case allergies
        case budgetPerCycle
        case explorationLevel
        case deliveryAddress
        case dietaryPatterns
        case cuisineCountries
        case hardRestrictions
        case favoriteFoods
        case favoriteFlavors
        case neverIncludeFoods
        case mealPrepGoals
        case cooksForOthers
        case kitchenEquipment
        case budgetWindow
        case budgetFlexibility
        case purchasingBehavior
        case orderingAutonomy
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        preferredCuisines = try container.decode([CuisinePreference].self, forKey: .preferredCuisines)
        cadence = try container.decode(MealCadence.self, forKey: .cadence)
        rotationPreference = try container.decode(RecipeRotationPreference.self, forKey: .rotationPreference)
        maxRepeatsPerCycle = try container.decode(Int.self, forKey: .maxRepeatsPerCycle)
        storage = try container.decode(StorageProfile.self, forKey: .storage)
        consumption = try container.decode(ConsumptionProfile.self, forKey: .consumption)
        preferredProviders = try container.decode([ShoppingProvider].self, forKey: .preferredProviders)
        pantryStaples = try container.decode([String].self, forKey: .pantryStaples)
        allergies = try container.decodeIfPresent([String].self, forKey: .allergies) ?? []
        budgetPerCycle = try container.decodeIfPresent(Double.self, forKey: .budgetPerCycle) ?? UserProfile.starter.budgetPerCycle
        explorationLevel = try container.decodeIfPresent(MealExplorationLevel.self, forKey: .explorationLevel) ?? .balanced
        deliveryAddress = try container.decodeIfPresent(DeliveryAddress.self, forKey: .deliveryAddress) ?? .empty
        dietaryPatterns = try container.decodeIfPresent([String].self, forKey: .dietaryPatterns) ?? UserProfile.starter.dietaryPatterns
        cuisineCountries = try container.decodeIfPresent([String].self, forKey: .cuisineCountries) ?? []
        hardRestrictions = try container.decodeIfPresent([String].self, forKey: .hardRestrictions) ?? []
        favoriteFoods = try container.decodeIfPresent([String].self, forKey: .favoriteFoods) ?? []
        favoriteFlavors = try container.decodeIfPresent([String].self, forKey: .favoriteFlavors) ?? []
        neverIncludeFoods = try container.decodeIfPresent([String].self, forKey: .neverIncludeFoods) ?? []
        mealPrepGoals = try container.decodeIfPresent([String].self, forKey: .mealPrepGoals) ?? UserProfile.starter.mealPrepGoals
        cooksForOthers = try container.decodeIfPresent(Bool.self, forKey: .cooksForOthers) ?? false
        kitchenEquipment = try container.decodeIfPresent([String].self, forKey: .kitchenEquipment) ?? UserProfile.starter.kitchenEquipment
        budgetWindow = try container.decodeIfPresent(BudgetWindow.self, forKey: .budgetWindow) ?? .weekly
        budgetFlexibility = try container.decodeIfPresent(BudgetFlexibility.self, forKey: .budgetFlexibility) ?? .strict
        purchasingBehavior = try container.decodeIfPresent(PurchasingBehavior.self, forKey: .purchasingBehavior) ?? .healthier
        orderingAutonomy = try container.decodeIfPresent(OrderingAutonomyLevel.self, forKey: .orderingAutonomy) ?? .autoOrderWithinBudget
    }

    private func joinedOrFallback(_ values: [String], fallback: String) -> String {
        let filtered = normalizedUnique(values)
        return filtered.isEmpty ? fallback : filtered.joined(separator: ", ")
    }

    private func normalizedUnique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.compactMap { raw in
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let key = trimmed.lowercased()
            guard seen.insert(key).inserted else { return nil }
            return trimmed
        }
    }
}

enum AuthProvider: String, Codable, Hashable, Identifiable {
    case apple
    case google

    var id: String { rawValue }

    var title: String {
        switch self {
        case .apple: return "Apple"
        case .google: return "Google"
        }
    }
}

struct AuthSession: Codable, Hashable {
    var provider: AuthProvider
    var userID: String
    var email: String?
    var displayName: String?
    var signedInAt: Date
}

struct RecipeIngredient: Codable, Hashable {
    var name: String
    var amount: Double
    var unit: String
    var estimatedUnitPrice: Double
}

struct StorageFootprint: Codable, Hashable {
    var pantry: Int
    var fridge: Int
    var freezer: Int

    static let low = StorageFootprint(pantry: 1, fridge: 1, freezer: 0)
    static let medium = StorageFootprint(pantry: 2, fridge: 2, freezer: 1)
    static let high = StorageFootprint(pantry: 2, fridge: 3, freezer: 3)
}

struct Recipe: Identifiable, Codable, Hashable {
    var id: String
    var title: String
    var cuisine: CuisinePreference
    var prepMinutes: Int
    var servings: Int
    var storageFootprint: StorageFootprint
    var tags: [String]
    var ingredients: [RecipeIngredient]
}

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

struct GroceryItem: Identifiable, Codable, Hashable {
    var id: String {
        "\(name.lowercased())::\(unit.lowercased())"
    }

    var name: String
    var amount: Double
    var unit: String
    var estimatedPrice: Double
}

struct ProviderQuote: Identifiable, Codable, Hashable {
    var id: String { provider.rawValue }
    var provider: ShoppingProvider
    var subtotal: Double
    var deliveryFee: Double
    var estimatedTotal: Double
    var etaDays: Int
    var orderURL: URL
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

    var bestQuote: ProviderQuote? {
        providerQuotes.first
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
