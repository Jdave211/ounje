import Foundation

protocol InventoryProvider {
    func currentInventory(for profile: UserProfile) -> [InventoryItem]
}

struct PantryInventoryProvider: InventoryProvider {
    func currentInventory(for profile: UserProfile) -> [InventoryItem] {
        let defaults: [InventoryItem] = [
            .init(name: "salt", amount: 1, unit: "cup"),
            .init(name: "black pepper", amount: 0.5, unit: "cup"),
            .init(name: "olive oil", amount: 1, unit: "cup"),
            .init(name: "garlic", amount: 1, unit: "cup")
        ]

        let custom = profile.pantryStaples
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { InventoryItem(name: $0.lowercased(), amount: 1, unit: "cup") }

        return defaults + custom
    }
}

final class MealPlanningAgent {
    private let recipeCatalog: RecipeCatalog
    private let inventoryProvider: InventoryProvider

    init(recipeCatalog: RecipeCatalog = LocalRecipeCatalog(), inventoryProvider: InventoryProvider = PantryInventoryProvider()) {
        self.recipeCatalog = recipeCatalog
        self.inventoryProvider = inventoryProvider
    }

    /// Generates a full meal plan with real provider cart URLs from GroceryService.
    /// Falls back to local URL building if the server is unreachable.
    func generatePlan(
        profile: UserProfile,
        history: [MealPlan],
        now: Date = Date(),
        recipeTitle: String? = nil,
        recipeImageURL: String? = nil,
        recipeID: String? = nil
    ) async -> MealPlan {
        var pipeline: [PipelineDecision] = []

        pipeline.append(
            PipelineDecision(
                stage: .interpretProfile,
                summary: "Targeting \(profile.cadence.title.lowercased()) with \(profile.userFacingCuisineTitles.joined(separator: ", "))\(profile.cuisineCountries.isEmpty ? "" : " plus country signals for \(profile.cuisineCountries.joined(separator: ", "))"), \(profile.budgetSummary), goals around \(profile.mealPrepGoals.isEmpty ? "balanced prep" : profile.mealPrepGoals.joined(separator: ", ")), and \(profile.orderingAutonomy.title.lowercased())."
            )
        )

        let candidates = await recipeCatalog.recipes(matching: profile.preferredCuisines)
        let scored = rank(candidates: candidates, profile: profile)

        pipeline.append(
            PipelineDecision(
                stage: .curateRecipes,
                summary: "Scored \(scored.count) recipes by restrictions, prep time, storage fit, and the selected meal-prep goals."
            )
        )

        let selected = selectRecipes(from: scored, profile: profile, history: history)
        let carriedCount = selected.filter(\.carriedFromPreviousPlan).count

        pipeline.append(
            PipelineDecision(
                stage: .handleRotation,
                summary: profile.rotationPreference == .dynamic
                    ? "Dynamic mode selected \(selected.count) recipes with only \(carriedCount) carry-over entries."
                    : "Stable mode selected \(selected.count) recipes and preserved \(carriedCount) prior favorites."
            )
        )

        let inventory = inventoryProvider.currentInventory(for: profile)
        let groceries = buildGroceryList(from: selected, profile: profile, inventory: inventory)

        pipeline.append(
            PipelineDecision(
                stage: .composeGroceries,
                summary: "Generated \(groceries.count) grocery lines after subtracting pantry staples."
            )
        )

        // Try real API quotes first; fall back to local estimate if server is down
        let quotes: [ProviderQuote]
        let apiQuotes = await GroceryService.shared.buildQuotes(
            for: groceries,
            profile: profile,
            recipeTitle: recipeTitle,
            recipeImageURL: recipeImageURL,
            recipeID: recipeID
        )
        if !apiQuotes.isEmpty {
            quotes = apiQuotes
        } else {
            quotes = optimizeProviders(for: groceries, profile: profile)
        }

        if let top = quotes.first {
            let budgetState = top.estimatedTotal <= profile.budgetPerCycle
                ? "within budget"
                : "over budget by \((top.estimatedTotal - profile.budgetPerCycle).asCurrency)"
            let statusLabel = top.providerStatus == .live ? "live cart" : "deep link"
            pipeline.append(
                PipelineDecision(
                    stage: .optimizeProvider,
                    summary: "Best provider: \(top.provider.title) (\(statusLabel)) at \(top.estimatedTotal.asCurrency) (\(budgetState)), ETA \(top.etaDays) day(s)."
                )
            )
        }

        return MealPlan(
            id: UUID(),
            generatedAt: now,
            periodStart: now,
            periodEnd: now.adding(days: profile.cadence.dayInterval),
            cadence: profile.cadence,
            recipes: selected,
            groceryItems: groceries,
            providerQuotes: quotes,
            pipeline: pipeline
        )
    }

    private func rank(candidates: [Recipe], profile: UserProfile) -> [Recipe] {
        candidates.sorted { lhs, rhs in
            score(for: lhs, profile: profile) > score(for: rhs, profile: profile)
        }
    }

    private func score(for recipe: Recipe, profile: UserProfile) -> Double {
        var score = 100.0

        if containsRestrictedIngredient(recipe, restrictions: profile.absoluteRestrictions) {
            return -1000
        }

        score -= Double(recipe.prepMinutes) * 0.7

        let freezerLimit = max(1, profile.storage.freezerCapacity / 4)
        if recipe.storageFootprint.freezer > freezerLimit {
            score -= Double(recipe.storageFootprint.freezer - freezerLimit) * 8
        }

        let fridgeLimit = max(2, profile.storage.fridgeCapacity / 5)
        if recipe.storageFootprint.fridge > fridgeLimit {
            score -= Double(recipe.storageFootprint.fridge - fridgeLimit) * 5
        }

        if profile.consumption.includeLeftovers && recipe.tags.contains("batch-friendly") {
            score += 8
        }

        if profile.consumption.mealsPerWeek >= 5 && recipe.tags.contains("meal-prep") {
            score += 6
        }

        if recipe.tags.contains("quick") {
            score += 3
        }

        let goals = Set(profile.mealPrepGoals.map { $0.lowercased() })
        if goals.contains("speed") && recipe.tags.contains("quick") {
            score += 12
        }
        if goals.contains("taste") && recipe.prepMinutes >= 25 {
            score += 5
        }
        if goals.contains("variety") && !recipe.tags.contains("comfort") {
            score += 7
        }
        if goals.contains("macros") && recipe.tags.contains("protein-forward") {
            score += 8
        }
        if goals.contains("family-friendly") && recipe.tags.contains("family-friendly") {
            score += 10
        }
        if goals.contains("minimal cleanup") && recipe.tags.contains("one-pan") {
            score += 10
        }
        if goals.contains("repeatability") && recipe.tags.contains("meal-prep") {
            score += 9
        }
        if goals.contains("cost") && recipe.tags.contains("budget") {
            score += 10
        }

        switch profile.explorationLevel {
        case .comfort:
            if recipe.tags.contains("quick") { score += 4 }
            if recipe.tags.contains("meal-prep") { score += 2 }
        case .balanced:
            score += 0
        case .adventurous:
            if recipe.prepMinutes > 30 { score += 4 }
            if recipe.tags.contains("batch-friendly") { score += 2 }
        }

        return score
    }

    private func containsRestrictedIngredient(_ recipe: Recipe, restrictions: [String]) -> Bool {
        let normalized = restrictions
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        guard !normalized.isEmpty else { return false }

        for ingredient in recipe.ingredients {
            let ingredientName = ingredient.name.lowercased()
            for allergen in normalized where ingredientName.contains(allergen) || allergen.contains(ingredientName) {
                return true
            }
        }
        return false
    }

    private func selectRecipes(from rankedRecipes: [Recipe], profile: UserProfile, history: [MealPlan]) -> [PlannedRecipe] {
        let targetCount = max(
            4,
            profile.cadence.baseRecipeCount + max(0, profile.consumption.adults - 2) + (profile.consumption.kids > 0 ? 1 : 0)
        )

        let previousPlanRecipeIDs = Set(history.first?.recipes.map { $0.recipe.id } ?? [])
        let frequencyMap = recipeFrequency(from: history)

        let primaryPool: [Recipe]
        let fallbackPool: [Recipe]

        switch profile.rotationPreference {
        case .dynamic:
            primaryPool = rankedRecipes.filter { !previousPlanRecipeIDs.contains($0.id) }
            fallbackPool = rankedRecipes.filter { previousPlanRecipeIDs.contains($0.id) }
        case .stable:
            let stableIDs = previousPlanRecipeIDs
            let carryPool = rankedRecipes
                .filter { stableIDs.contains($0.id) }
                .sorted { (frequencyMap[$0.id, default: 0], score(for: $0, profile: profile)) > (frequencyMap[$1.id, default: 0], score(for: $1, profile: profile)) }
            let freshPool = rankedRecipes.filter { !stableIDs.contains($0.id) }
            primaryPool = Array(carryPool.prefix(profile.maxRepeatsPerCycle)) + freshPool
            fallbackPool = rankedRecipes
        }

        var selected: [Recipe] = []
        for recipe in primaryPool where selected.count < targetCount {
            selected.append(recipe)
        }

        if selected.count < targetCount {
            for recipe in fallbackPool where selected.count < targetCount && !selected.contains(recipe) {
                selected.append(recipe)
            }
        }

        return selected.map { recipe in
            PlannedRecipe(
                recipe: recipe,
                servings: adjustedServings(baseServings: recipe.servings, profile: profile),
                carriedFromPreviousPlan: previousPlanRecipeIDs.contains(recipe.id)
            )
        }
    }

    private func recipeFrequency(from history: [MealPlan]) -> [String: Int] {
        var map: [String: Int] = [:]
        for plan in history.prefix(6) {
            for recipe in plan.recipes {
                map[recipe.recipe.id, default: 0] += 1
            }
        }
        return map
    }

    private func adjustedServings(baseServings: Int, profile: UserProfile) -> Int {
        let household = max(1.0, profile.consumption.householdMultiplier)
        let adjusted = Int((Double(baseServings) * (household / 2.0)).rounded())
        return max(2, adjusted)
    }

    private func buildGroceryList(from recipes: [PlannedRecipe], profile: UserProfile, inventory: [InventoryItem]) -> [GroceryItem] {
        var ingredientMap: [String: GroceryItem] = [:]

        for plannedRecipe in recipes {
            let scale = Double(plannedRecipe.servings) / Double(plannedRecipe.recipe.servings)
            for ingredient in plannedRecipe.recipe.ingredients {
                let key = "\(ingredient.name.lowercased())::\(ingredient.unit.lowercased())"
                let amountToAdd = ingredient.amount * scale
                let priceToAdd = ingredient.estimatedUnitPrice * amountToAdd

                if var existing = ingredientMap[key] {
                    existing.amount += amountToAdd
                    existing.estimatedPrice += priceToAdd
                    ingredientMap[key] = existing
                } else {
                    ingredientMap[key] = GroceryItem(
                        name: ingredient.name,
                        amount: amountToAdd,
                        unit: ingredient.unit,
                        estimatedPrice: max(priceToAdd, 0.25)
                    )
                }
            }
        }

        var inventoryMap: [String: Double] = [:]
        for item in inventory {
            let key = "\(item.name.lowercased())::\(item.unit.lowercased())"
            inventoryMap[key, default: 0] += item.amount
        }

        let adjusted = ingredientMap.values.compactMap { item -> GroceryItem? in
            let key = item.id
            let inStock = inventoryMap[key, default: 0]
            let needed = item.amount - inStock
            guard needed > 0.1 else { return nil }

            let ratio = needed / max(item.amount, 0.1)
            return GroceryItem(
                name: item.name,
                amount: needed,
                unit: item.unit,
                estimatedPrice: item.estimatedPrice * ratio
            )
        }

        return adjusted.sorted { $0.estimatedPrice > $1.estimatedPrice }
    }

    private func optimizeProviders(for groceries: [GroceryItem], profile: UserProfile) -> [ProviderQuote] {
        let candidates = profile.preferredProviders.isEmpty ? ShoppingProvider.allCases : profile.preferredProviders

        let ranked = candidates.enumerated().map { index, provider in
            let subtotal = groceries.reduce(0) { partialResult, item in
                partialResult + (item.estimatedPrice * provider.priceMultiplier)
            }

            let estimatedTotal = subtotal + provider.deliveryFee
            let preferencePenalty = Double(index) * 1.5
            let speedPenalty = Double(provider.etaDays) * 0.85
            let budgetOverrun = max(0, estimatedTotal - profile.budgetPerCycle)
            let budgetPenalty = budgetOverrun * 2.4
            let optimizationScore = estimatedTotal + preferencePenalty + speedPenalty + budgetPenalty

            return (
                quote: ProviderQuote(
                    provider: provider,
                    subtotal: subtotal,
                    deliveryFee: provider.deliveryFee,
                    estimatedTotal: estimatedTotal,
                    etaDays: provider.etaDays,
                    orderURL: provider.buildOrderURL(using: groceries, deliveryAddress: profile.deliveryAddress)
                ),
                optimizationScore: optimizationScore
            )
        }

        return ranked
            .sorted { $0.optimizationScore < $1.optimizationScore }
            .map(\.quote)
    }
}
