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
    private let overlapNoiseTerms: Set<String> = [
        "salt", "black pepper", "pepper", "olive oil", "water", "ice", "oil"
    ]
    private let ingredientAliasMap: [String: String] = [
        "red onion": "onion",
        "yellow onion": "onion",
        "white onion": "onion",
        "sweet onion": "onion",
        "baby spinach": "spinach",
        "baby potato": "potato",
        "baby potatoes": "potato",
        "bell peppers": "bell pepper",
        "bell pepper": "bell pepper",
        "spring onion": "green onion",
        "scallion": "green onion",
        "scallions": "green onion",
        "green onions": "green onion",
        "cherry tomatoes": "tomato",
        "roma tomatoes": "tomato",
        "tomatoes": "tomato",
        "garbanzo bean": "chickpea",
        "garbanzo beans": "chickpea",
        "chickpeas": "chickpea",
        "black beans": "black bean",
        "kidney beans": "kidney bean",
        "pinto beans": "pinto bean"
    ]
    private let unitAliasMap: [String: String] = [
        "lbs": "lb",
        "pound": "lb",
        "pounds": "lb",
        "ounces": "oz",
        "ounce": "oz",
        "ozs": "oz",
        "cups": "cup",
        "tablespoon": "tbsp",
        "tablespoons": "tbsp",
        "tbsp.": "tbsp",
        "teaspoon": "tsp",
        "teaspoons": "tsp",
        "tsp.": "tsp",
        "count": "ct",
        "each": "ct",
        "piece": "ct",
        "pieces": "ct",
        "clove": "ct",
        "cloves": "ct",
        "can": "can",
        "cans": "can",
        "bunches": "bunch",
        "bunch": "bunch"
    ]
    private let genericIngredientBucketTerms: Set<String> = [
        "spice",
        "spices",
        "seasoning",
        "seasonings",
        "herb",
        "herbs",
        "sauce",
        "sauces",
        "dressing",
        "dressings",
        "marinade",
        "marinades",
        "glaze",
        "glazes",
        "topping",
        "toppings",
        "garnish",
        "garnishes",
    ]
    private let concreteSpiceHints: [String] = [
        "paprika",
        "chili",
        "cumin",
        "coriander",
        "turmeric",
        "garlic powder",
        "onion powder",
        "black pepper",
        "white pepper",
        "red pepper",
        "cayenne",
        "oregano",
        "basil",
        "thyme",
        "rosemary",
        "sage",
        "mint",
        "parsley",
        "cilantro",
        "dill",
        "chive",
        "ginger",
        "cinnamon",
        "nutmeg",
        "clove",
        "allspice",
        "cardamom",
        "fennel",
        "sumac",
        "zaatar",
        "honey",
        "sriracha",
        "soy sauce",
        "hot sauce",
        "vinegar",
        "mustard",
        "mayo",
        "yogurt",
        "bbq",
        "worcestershire",
        "sesame oil",
        "fish sauce",
        "oyster sauce",
        "hoisin",
        "teriyaki",
        "chipotle",
        "tomato sauce"
    ]

    private enum MealMoment: String, CaseIterable, Hashable {
        case breakfast
        case lunch
        case dinner
    }

    private struct PlanningCandidate: Hashable {
        let recipe: Recipe
        let baseScore: Double
        let profileAffinity: Double
        let ingredientKeys: Set<String>
        let ingredientFamilies: Set<String>
        let mealMoments: Set<MealMoment>
        let dominantProtein: String?
        let formatKey: String
        let recentFrequency: Int
        let isSaved: Bool
        let isNewSavedRecipe: Bool
        let isRecurring: Bool
        let isCurrentCycle: Bool
    }

    init(recipeCatalog: RecipeCatalog = RemoteRecipeCatalog(), inventoryProvider: InventoryProvider = PantryInventoryProvider()) {
        self.recipeCatalog = recipeCatalog
        self.inventoryProvider = inventoryProvider
    }

    /// Generates a full meal plan with real provider cart URLs from GroceryService.
    /// Falls back to local URL building if the server is unreachable.
    func generatePlan(
        profile: UserProfile,
        history: [MealPlan],
        savedRecipeIDs: Set<String> = [],
        recurringRecipes: [RecurringPrepRecipe] = [],
        savedRecipeTitles: [String] = [],
        options: PrepGenerationOptions = .standard,
        regenerationContext: PrepRegenerationContext? = nil,
        now: Date = Date(),
        recipeTitle: String? = nil,
        recipeImageURL: String? = nil,
        recipeID: String? = nil,
        userID: String? = nil,
        accessToken: String? = nil,
        includeRemoteQuotes: Bool = true
    ) async -> MealPlan {
        var pipeline: [PipelineDecision] = []

        pipeline.append(
            PipelineDecision(
                stage: .interpretProfile,
                summary: "Planning for \(profile.cadence.title.lowercased()) with allergies treated as hard exclusions, while cuisines, country cues, favorite meals, and goals stay as weighted guidance. Current signals emphasize \(profile.userFacingCuisineTitles.joined(separator: ", "))\(profile.favoriteFoods.isEmpty ? "" : ", plus \(profile.favoriteFoods.prefix(3).joined(separator: ", "))"), \(profile.budgetSummary), and a \(planningFocusSummary(options.focus)) reroll lens."
            )
        )

        let recentHistoryRecipeIDs = history
            .prefix(4)
            .flatMap(\.recipes)
            .map { $0.recipe.id }
        let fetchedCandidates = await recipeCatalog.recipes(
            for: profile,
            historyRecipeIDs: recentHistoryRecipeIDs,
            regenerationContext: regenerationContext,
            savedRecipeIDs: Array(savedRecipeIDs),
            recurringRecipes: recurringRecipes,
            savedRecipeTitles: savedRecipeTitles
        )
        let recurringSeedRecipes = recurringRecipes
            .filter(\.isEnabled)
            .map(\.recipe)
        let candidates = dedupeRecipesByID(recurringSeedRecipes + fetchedCandidates)
        let scored = rank(candidates: candidates, profile: profile, options: options)
        let recurringRecipeIDs = recurringRecipes.filter(\.isEnabled).map(\.recipeID)
        let targetRecipeCount = resolvedTargetRecipeCount(
            profile: profile,
            requestedTargetRecipeCount: options.targetRecipeCount,
            recurringRecipeCount: recurringRecipeIDs.count
        )

        pipeline.append(
            PipelineDecision(
                stage: .curateRecipes,
                summary: "Scored \(scored.count) live recipe candidates, then built a \(targetRecipeCount)-meal prep bundle around allergy safety, breakfast-lunch-dinner coverage, onboarding taste signals, ingredient overlap, saved-meal inclusion, and total variety."
            )
        )

        let currentRecipeIDs = Set(regenerationContext?.currentRecipes.map(\.id) ?? [])
        let currentRecipeTitleKeys = Set(
            regenerationContext?.currentRecipes
                .map { normalizedRecipeTitleKey($0.title) }
                .filter { !$0.isEmpty } ?? []
        )
        let isExplicitReroll = options.rerollNonce?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        let selected = selectRecipes(
            from: scored,
            profile: profile,
            history: history,
            savedRecipeIDs: savedRecipeIDs,
            recurringRecipeIDs: Set(recurringRecipeIDs),
            currentRecipeIDs: currentRecipeIDs,
            currentRecipeTitleKeys: currentRecipeTitleKeys,
            isExplicitReroll: isExplicitReroll,
            options: options
        )
        let carriedCount = selected.filter(\.carriedFromPreviousPlan).count
        let savedSelectedCount = selected.filter { savedRecipeIDs.contains($0.recipe.id) }.count
        let recurringRecipeIDSet = Set(recurringRecipeIDs)
        let recurringSelectedCount = selected.filter { recurringRecipeIDSet.contains($0.recipe.id) }.count

        pipeline.append(
            PipelineDecision(
                stage: .handleRotation,
                summary: profile.rotationPreference == .dynamic
                    ? "Dynamic mode selected \(selected.count) recipes with only \(carriedCount) carry-over entries, while carrying \(savedSelectedCount) saved meal\(savedSelectedCount == 1 ? "" : "s") into the cycle when available."
                    : "Stable mode selected \(selected.count) recipes, preserved \(carriedCount) prior favorites, and still pulled in \(savedSelectedCount) saved meal\(savedSelectedCount == 1 ? "" : "s") when possible."
            )
        )
        if recurringSelectedCount > 0 {
            pipeline.append(
                PipelineDecision(
                    stage: .handleRotation,
                    summary: "Recurring anchors locked in \(recurringSelectedCount) recipe\(recurringSelectedCount == 1 ? "" : "s") from the user's repeat list before filling the rest of the cycle."
                )
            )
        }

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
        let apiQuotes: [ProviderQuote]
        if includeRemoteQuotes {
            apiQuotes = await GroceryService.shared.buildQuotes(
                for: groceries,
                profile: profile,
                recipeTitle: recipeTitle,
                recipeImageURL: recipeImageURL,
                recipeID: recipeID,
                userID: userID,
                accessToken: accessToken
            )
        } else {
            apiQuotes = []
        }
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
            let storeLabel = top.selectedStore.map { " via \($0.storeName)" } ?? ""
            pipeline.append(
                PipelineDecision(
                    stage: .optimizeProvider,
                    summary: "Best provider: \(top.provider.marketingTitle)\(storeLabel) (\(statusLabel)) at \(top.estimatedTotal.asCurrency) (\(budgetState)), ETA \(top.etaDays) day(s)."
                )
            )
        }

        return composePlan(
            profile: profile,
            selectedRecipes: selected,
            now: now,
            pipeline: pipeline,
            groceries: groceries,
            quotes: quotes,
            recurringRecipeIDs: recurringRecipeIDs
        )
    }

    func buildPlan(
        profile: UserProfile,
        recipes: [PlannedRecipe],
        history: [MealPlan] = [],
        now: Date = Date(),
        recurringRecipeIDs: [String] = []
    ) async -> MealPlan {
        let pipeline: [PipelineDecision] = [
            PipelineDecision(
                stage: .interpretProfile,
                summary: "Rebuilt the next prep from your manual recipe edits while keeping the same pantry and budget guardrails."
            ),
            PipelineDecision(
                stage: .curateRecipes,
                summary: "Kept \(recipes.count) recipe(s) in the next prep."
            ),
            PipelineDecision(
                stage: .handleRotation,
                summary: "Applied direct prep changes instead of generating a fresh rotation."
            )
        ]

        let inventory = inventoryProvider.currentInventory(for: profile)
        let groceries = buildGroceryList(from: recipes, profile: profile, inventory: inventory)
        let quotes = await resolvedQuotes(
            for: groceries,
            profile: profile,
            recipeTitle: nil,
            recipeImageURL: nil,
            recipeID: nil
        )

        var composedPipeline = pipeline
        composedPipeline.append(
            PipelineDecision(
                stage: .composeGroceries,
                summary: "Generated \(groceries.count) grocery lines after subtracting pantry staples."
            )
        )

        if let top = quotes.first {
            let budgetState = top.estimatedTotal <= profile.budgetPerCycle
                ? "within budget"
                : "over budget by \((top.estimatedTotal - profile.budgetPerCycle).asCurrency)"
            let statusLabel = top.providerStatus == .live ? "live cart" : "deep link"
            let storeLabel = top.selectedStore.map { " via \($0.storeName)" } ?? ""
            composedPipeline.append(
                PipelineDecision(
                    stage: .optimizeProvider,
                    summary: "Best provider: \(top.provider.marketingTitle)\(storeLabel) (\(statusLabel)) at \(top.estimatedTotal.asCurrency) (\(budgetState)), ETA \(top.etaDays) day(s)."
                )
            )
        }

        return composePlan(
            profile: profile,
            selectedRecipes: recipes,
            now: now,
            pipeline: composedPipeline,
            groceries: groceries,
            quotes: quotes,
            history: history,
            recurringRecipeIDs: recurringRecipeIDs
        )
    }

    func rebuildPlan(
        profile: UserProfile,
        basePlan: MealPlan,
        recipes: [PlannedRecipe],
        history: [MealPlan] = [],
        now: Date = Date(),
        recurringRecipeIDs: [String] = []
    ) async -> MealPlan {
        let pipeline: [PipelineDecision] = [
            PipelineDecision(
                stage: .interpretProfile,
                summary: "Applied your saved prep overrides on top of the base meal while keeping the same pantry and budget guardrails."
            ),
            PipelineDecision(
                stage: .curateRecipes,
                summary: "Kept \(recipes.count) recipe(s) in the current prep after merging user-specific edits."
            ),
            PipelineDecision(
                stage: .handleRotation,
                summary: "Preserved the existing prep cycle and layered in your changes."
            )
        ]

        let inventory = inventoryProvider.currentInventory(for: profile)
        let groceries = buildGroceryList(from: recipes, profile: profile, inventory: inventory)
        let quotes = await resolvedQuotes(
            for: groceries,
            profile: profile,
            recipeTitle: nil,
            recipeImageURL: nil,
            recipeID: nil
        )

        var composedPipeline = pipeline
        composedPipeline.append(
            PipelineDecision(
                stage: .composeGroceries,
                summary: "Generated \(groceries.count) grocery lines after subtracting pantry staples."
            )
        )

        if let top = quotes.first {
            let budgetState = top.estimatedTotal <= profile.budgetPerCycle
                ? "within budget"
                : "over budget by \((top.estimatedTotal - profile.budgetPerCycle).asCurrency)"
            let statusLabel = top.providerStatus == .live ? "live cart" : "deep link"
            let storeLabel = top.selectedStore.map { " via \($0.storeName)" } ?? ""
            composedPipeline.append(
                PipelineDecision(
                    stage: .optimizeProvider,
                    summary: "Best provider: \(top.provider.marketingTitle)\(storeLabel) (\(statusLabel)) at \(top.estimatedTotal.asCurrency) (\(budgetState)), ETA \(top.etaDays) day(s)."
                )
            )
        }

        return MealPlan(
            id: basePlan.id,
            generatedAt: basePlan.generatedAt,
            periodStart: basePlan.periodStart,
            periodEnd: basePlan.periodEnd,
            cadence: basePlan.cadence,
            recipes: recipes,
            groceryItems: groceries,
            providerQuotes: quotes,
            pipeline: composedPipeline,
            recurringRecipeIDs: recurringRecipeIDs.isEmpty ? basePlan.recurringRecipeIDs : recurringRecipeIDs
        )
    }

    func rebuildPlanCartOnly(
        profile: UserProfile,
        basePlan: MealPlan,
        recipes: [PlannedRecipe],
        history: [MealPlan] = [],
        now: Date = Date(),
        recurringRecipeIDs: [String] = []
    ) -> MealPlan {
        let pipeline: [PipelineDecision] = [
            PipelineDecision(
                stage: .interpretProfile,
                summary: "Applied your prep edits immediately without rerunning the full planning flow."
            ),
            PipelineDecision(
                stage: .curateRecipes,
                summary: "Updated \(recipes.count) recipe(s) in the active prep."
            ),
            PipelineDecision(
                stage: .handleRotation,
                summary: "Kept the current prep cycle intact and refreshed groceries right away."
            ),
            PipelineDecision(
                stage: .composeGroceries,
                summary: "Rebuilt grocery coverage now and left slower provider quote refresh for background sync."
            )
        ]

        let inventory = inventoryProvider.currentInventory(for: profile)
        let groceries = buildGroceryList(from: recipes, profile: profile, inventory: inventory)

        return MealPlan(
            id: basePlan.id,
            generatedAt: basePlan.generatedAt,
            periodStart: basePlan.periodStart,
            periodEnd: basePlan.periodEnd,
            cadence: basePlan.cadence,
            recipes: recipes,
            groceryItems: groceries,
            providerQuotes: basePlan.providerQuotes,
            pipeline: pipeline,
            recurringRecipeIDs: recurringRecipeIDs.isEmpty ? basePlan.recurringRecipeIDs : recurringRecipeIDs
        )
    }

    func mergedGroceryItems(
        existing groceries: [GroceryItem],
        previousRecipes: [PlannedRecipe],
        updatedRecipes: [PlannedRecipe]
    ) -> [GroceryItem] {
        let previousByID = Dictionary(uniqueKeysWithValues: previousRecipes.map { ($0.recipe.id, $0) })
        let updatedByID = Dictionary(uniqueKeysWithValues: updatedRecipes.map { ($0.recipe.id, $0) })
        let removedRecipes = previousRecipes.filter { updatedByID[$0.recipe.id] == nil || updatedByID[$0.recipe.id] != $0 }
        let addedRecipes = updatedRecipes.filter { previousByID[$0.recipe.id] == nil || previousByID[$0.recipe.id] != $0 }

        var merged = groceries
        applyGroceryContributions(from: removedRecipes, into: &merged, subtracting: true)
        applyGroceryContributions(from: addedRecipes, into: &merged, subtracting: false)
        return merged
    }

    func optimizedProviderQuotes(for groceries: [GroceryItem], profile: UserProfile) -> [ProviderQuote] {
        optimizeProviders(for: groceries, profile: profile)
    }

    func buildPlanCartOnly(
        profile: UserProfile,
        recipes: [PlannedRecipe],
        history: [MealPlan] = [],
        now: Date = Date(),
        recurringRecipeIDs: [String] = []
    ) -> MealPlan {
        let pipeline: [PipelineDecision] = [
            PipelineDecision(
                stage: .interpretProfile,
                summary: "Built a prep shell from your direct recipe edits."
            ),
            PipelineDecision(
                stage: .curateRecipes,
                summary: "Started the prep with \(recipes.count) recipe(s)."
            ),
            PipelineDecision(
                stage: .handleRotation,
                summary: "Skipped a fresh rotation and focused on immediate grocery rebuild."
            ),
            PipelineDecision(
                stage: .composeGroceries,
                summary: "Generated groceries now and deferred provider quote refresh."
            )
        ]

        let inventory = inventoryProvider.currentInventory(for: profile)
        let groceries = buildGroceryList(from: recipes, profile: profile, inventory: inventory)

        return composePlan(
            profile: profile,
            selectedRecipes: recipes,
            now: now,
            pipeline: pipeline,
            groceries: groceries,
            quotes: [],
            history: history,
            recurringRecipeIDs: recurringRecipeIDs
        )
    }

    private func composePlan(
        profile: UserProfile,
        selectedRecipes: [PlannedRecipe],
        now: Date,
        pipeline: [PipelineDecision],
        groceries: [GroceryItem],
        quotes: [ProviderQuote],
        history: [MealPlan] = [],
        recipeTitle: String? = nil,
        recipeImageURL: String? = nil,
        recipeID: String? = nil,
        recurringRecipeIDs: [String] = []
    ) -> MealPlan {
        MealPlan(
            id: UUID(),
            generatedAt: now,
            periodStart: now,
            periodEnd: now.adding(days: profile.cadence.dayInterval),
            cadence: profile.cadence,
            recipes: selectedRecipes,
            groceryItems: groceries,
            providerQuotes: quotes,
            pipeline: pipeline,
            recurringRecipeIDs: recurringRecipeIDs.isEmpty ? nil : recurringRecipeIDs
        )
    }

    private func resolvedQuotes(
        for groceries: [GroceryItem],
        profile: UserProfile,
        recipeTitle: String?,
        recipeImageURL: String?,
        recipeID: String?
    ) async -> [ProviderQuote] {
        let apiQuotes = await GroceryService.shared.buildQuotes(
            for: groceries,
            profile: profile,
            recipeTitle: recipeTitle,
            recipeImageURL: recipeImageURL,
            recipeID: recipeID
        )
        if !apiQuotes.isEmpty {
            return apiQuotes
        }
        return optimizeProviders(for: groceries, profile: profile)
    }

    private func rank(candidates: [Recipe], profile: UserProfile, options: PrepGenerationOptions) -> [Recipe] {
        candidates.sorted { lhs, rhs in
            let lhsScore = score(for: lhs, profile: profile, options: options)
            let rhsScore = score(for: rhs, profile: profile, options: options)
            if lhsScore == rhsScore {
                return lhs.id < rhs.id
            }
            return lhsScore > rhsScore
        }
    }

    private func score(for recipe: Recipe, profile: UserProfile, options: PrepGenerationOptions) -> Double {
        var score = 100.0

        if containsRestrictedIngredient(recipe, restrictions: profile.absoluteRestrictions) {
            return -10_000
        }

        score += profileAffinityScore(for: recipe, profile: profile)

        if recipe.isImagePoor {
            score -= 18
        } else {
            score += 4
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

        if let rerollNonce = options.rerollNonce?.trimmingCharacters(in: .whitespacesAndNewlines),
           !rerollNonce.isEmpty {
            score += deterministicRerollJitter(seed: "\(rerollNonce)|\(recipe.id)") * 9.0
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

        switch options.focus {
        case .balanced:
            score += fullnessBiasScore(for: recipe)
        case .closerToFavorites:
            score += profileAffinityScore(for: recipe, profile: profile) * 0.82
            if recipe.tags.contains("meal-prep") {
                score += 4
            }
        case .moreVariety:
            if !profile.preferredCuisines.contains(recipe.cuisine) {
                score += 10
            }
            if inferredMealMoments(for: recipe).count > 1 {
                score += 2
            }
            score -= profileAffinityScore(for: recipe, profile: profile) * 0.12
        case .lessPrepTime:
            score += prepTimeBiasScore(for: recipe)
            if recipe.prepMinutes <= 25 {
                score += 18
            } else if recipe.prepMinutes <= 35 {
                score += 8
            } else {
                score -= 10
            }
        case .tighterOverlap:
            if recipe.tags.contains("budget") {
                score += 9
            }
            if recipe.tags.contains("meal-prep") {
                score += 6
            }
            if recipe.tags.contains("protein-forward") {
                score += 2
            }
        case .savedRecipeRefresh:
            score += profileAffinityScore(for: recipe, profile: profile) * 0.82
            if recipe.tags.contains("meal-prep") {
                score += 4
            }
        }

        return score
    }

    private func deterministicRerollJitter(seed: String) -> Double {
        guard !seed.isEmpty else { return 0 }
        var hash: UInt64 = 1469598103934665603
        for byte in seed.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1099511628211
        }
        return Double(hash % 10_000) / 10_000.0
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

    private func selectRecipes(
        from rankedRecipes: [Recipe],
        profile: UserProfile,
        history: [MealPlan],
        savedRecipeIDs: Set<String>,
        recurringRecipeIDs: Set<String>,
        currentRecipeIDs: Set<String>,
        currentRecipeTitleKeys: Set<String>,
        isExplicitReroll: Bool,
        options: PrepGenerationOptions
    ) -> [PlannedRecipe] {
        let targetCount = resolvedTargetRecipeCount(
            profile: profile,
            requestedTargetRecipeCount: options.targetRecipeCount,
            recurringRecipeCount: recurringRecipeIDs.count
        )
        let previousPlanRecipeIDs = Set(history.first?.recipes.map { $0.recipe.id } ?? [])
        let recentRecipeIDs = Set(history.prefix(4).flatMap(\.recipes).map { $0.recipe.id })
        let frequencyMap = recipeFrequency(from: history)

        let candidates = buildPlanningCandidates(
            from: rankedRecipes,
            profile: profile,
            recentRecipeIDs: recentRecipeIDs,
            frequencyMap: frequencyMap,
            savedRecipeIDs: savedRecipeIDs,
            recurringRecipeIDs: recurringRecipeIDs,
            currentRecipeIDs: currentRecipeIDs,
            currentRecipeTitleKeys: currentRecipeTitleKeys,
            targetCount: targetCount,
            isExplicitReroll: isExplicitReroll,
            options: options
        )

        guard !candidates.isEmpty else { return [] }

        let requiredMoments = requiredMealMoments(for: candidates, targetCount: targetCount)
        var selected = seedBundle(
            from: candidates,
            profile: profile,
            targetCount: targetCount,
            requiredMoments: requiredMoments,
            savedRecipeIDs: savedRecipeIDs,
            recurringRecipeIDs: recurringRecipeIDs,
            options: options
        )
        let lockedRecipeIDs = Set(selected.filter(\.isRecurring).map(\.recipe.id))
        selected = optimizeBundle(
            selected,
            using: candidates,
            profile: profile,
            targetCount: targetCount,
            requiredMoments: requiredMoments,
            savedRecipeIDs: savedRecipeIDs,
            recurringRecipeIDs: recurringRecipeIDs,
            lockedRecipeIDs: lockedRecipeIDs,
            options: options
        )

        return selected.map { candidate in
            PlannedRecipe(
                recipe: candidate.recipe,
                servings: adjustedServings(baseServings: candidate.recipe.servings, profile: profile),
                carriedFromPreviousPlan: previousPlanRecipeIDs.contains(candidate.recipe.id)
            )
        }
    }

    private func resolvedTargetRecipeCount(
        profile: UserProfile,
        requestedTargetRecipeCount: Int? = nil,
        recurringRecipeCount: Int = 0
    ) -> Int {
        let minimumRecipeCount = max(recurringRecipeCount, 1)
        let maximumRecipeCount = max(10, minimumRecipeCount)

        if let requestedTargetRecipeCount {
            return min(max(requestedTargetRecipeCount, minimumRecipeCount), maximumRecipeCount)
        }

        let cycleWeeks = max(1.0, Double(profile.cadence.dayInterval) / 7.0)
        let cycleMealDemand = Double(profile.consumption.mealsPerWeek) * cycleWeeks

        // Distinct-recipe planning is based on how often each recipe is reused in a cycle.
        // Biweekly should generally land around 3-4 recipes unless the user explicitly
        // prefers higher novelty or has a very loose budget.
        let cadenceMinMax: ClosedRange<Int>
        let baseReusePerRecipe: Double
        switch profile.cadence {
        case .daily:
            cadenceMinMax = 2...3
            baseReusePerRecipe = 1.8
        case .everyFewDays:
            cadenceMinMax = 2...4
            baseReusePerRecipe = 2.0
        case .twiceWeekly:
            cadenceMinMax = 3...4
            baseReusePerRecipe = 2.2
        case .weekly:
            cadenceMinMax = 3...5
            baseReusePerRecipe = 2.4
        case .biweekly:
            cadenceMinMax = 3...4
            baseReusePerRecipe = 2.9
        case .monthly:
            cadenceMinMax = 5...8
            baseReusePerRecipe = 3.25
        }

        var reusePerRecipe = baseReusePerRecipe

        if !profile.consumption.includeLeftovers {
            reusePerRecipe -= 0.45
        }

        switch profile.explorationLevel {
        case .comfort:
            reusePerRecipe += 0.30
        case .balanced:
            break
        case .adventurous:
            reusePerRecipe -= 0.35
        }

        switch profile.budgetFlexibility {
        case .strict:
            reusePerRecipe += 0.30
        case .slightlyFlexible:
            break
        case .convenienceFirst:
            reusePerRecipe -= 0.25
        }

        let mealsInCycle = max(1.0, cycleMealDemand)
        let budgetPerMeal = profile.budgetPerCycle / mealsInCycle
        if budgetPerMeal < 6 {
            reusePerRecipe += 0.45
        } else if budgetPerMeal < 9 {
            reusePerRecipe += 0.20
        } else if budgetPerMeal > 16 {
            reusePerRecipe -= 0.20
        }

        if profile.consumption.kids > 0 || profile.cooksForOthers {
            reusePerRecipe += 0.15
        }

        if profile.consumption.adults + profile.consumption.kids >= 4 {
            reusePerRecipe += 0.10
        }

        let demandDrivenDistinct = cycleMealDemand / max(1.5, reusePerRecipe)
        var target = Int(demandDrivenDistinct.rounded(.toNearestOrAwayFromZero))

        if profile.cadence == .biweekly && profile.explorationLevel == .adventurous && profile.budgetFlexibility == .convenienceFirst {
            target = max(target, 5)
        }

        if profile.cadence == .monthly && profile.explorationLevel == .adventurous {
            target = max(target, 7)
        }

        let defaultTarget = min(cadenceMinMax.upperBound, max(cadenceMinMax.lowerBound, target))
        return min(max(defaultTarget, minimumRecipeCount), maximumRecipeCount)
    }

    private func buildPlanningCandidates(
        from rankedRecipes: [Recipe],
        profile: UserProfile,
        recentRecipeIDs: Set<String>,
        frequencyMap: [String: Int],
        savedRecipeIDs: Set<String>,
        recurringRecipeIDs: Set<String>,
        currentRecipeIDs: Set<String>,
        currentRecipeTitleKeys: Set<String>,
        targetCount: Int,
        isExplicitReroll: Bool,
        options: PrepGenerationOptions
    ) -> [PlanningCandidate] {
        let seeded = rankedRecipes.map { recipe in
            let isSaved = savedRecipeIDs.contains(recipe.id)
            let isRecurring = recurringRecipeIDs.contains(recipe.id)
            let isRecent = recentRecipeIDs.contains(recipe.id)
            let titleKey = normalizedRecipeTitleKey(recipe.title)
            let isCurrentCycle = currentRecipeIDs.contains(recipe.id)
                || (!titleKey.isEmpty && currentRecipeTitleKeys.contains(titleKey))
            let candidate = PlanningCandidate(
                recipe: recipe,
                baseScore: score(for: recipe, profile: profile, options: options),
                profileAffinity: profileAffinityScore(for: recipe, profile: profile),
                ingredientKeys: ingredientKeys(for: recipe),
                ingredientFamilies: ingredientFamilyKeys(for: recipe),
                mealMoments: inferredMealMoments(for: recipe),
                dominantProtein: dominantProtein(for: recipe),
                formatKey: recipeFormatKey(for: recipe),
                recentFrequency: frequencyMap[recipe.id, default: 0],
                isSaved: isSaved,
                isNewSavedRecipe: isSaved && !isRecent,
                isRecurring: isRecurring,
                isCurrentCycle: isCurrentCycle
            )
            return candidate
        }

        let imageRichCandidates = seeded.filter { !$0.recipe.isImagePoor }
        let recurringSeedIDs = Set(recurringRecipeIDs)
        let qualityPool: [PlanningCandidate]
        if isExplicitReroll {
            qualityPool = seeded
        } else if imageRichCandidates.count >= max(targetCount + 2, 6) {
            let imageRichIDs = Set(imageRichCandidates.map(\.recipe.id))
            var mergedPool = imageRichCandidates
            mergedPool.append(contentsOf: seeded.filter {
                recurringSeedIDs.contains($0.recipe.id) && !imageRichIDs.contains($0.recipe.id)
            })
            qualityPool = mergedPool
        } else {
            qualityPool = seeded
        }

        let baseCandidates = qualityPool.filter { $0.baseScore > -1_000 }
        let freshRerollCandidates = baseCandidates.filter { !$0.isCurrentCycle || $0.isRecurring }
        let rotationPool: [PlanningCandidate]
        if isExplicitReroll, freshRerollCandidates.count >= targetCount {
            rotationPool = freshRerollCandidates
        } else {
            rotationPool = baseCandidates
        }

        let sortedCandidates = rotationPool
            .sorted { lhs, rhs in
                let lhsScore = candidateSortScore(lhs, profile: profile, isExplicitReroll: isExplicitReroll)
                let rhsScore = candidateSortScore(rhs, profile: profile, isExplicitReroll: isExplicitReroll)
                if lhsScore == rhsScore {
                    return lhs.recipe.id < rhs.recipe.id
                }
                return lhsScore > rhsScore
            }

        let recurringLocked = sortedCandidates.filter(\.isRecurring)
        let remainingCapacity = max(0, 42 - recurringLocked.count)
        let remainder = sortedCandidates
            .filter { !$0.isRecurring }
            .prefix(remainingCapacity)

        return recurringLocked + remainder
    }

    private func candidateSortScore(_ candidate: PlanningCandidate, profile: UserProfile, isExplicitReroll: Bool = false) -> Double {
        var score = candidate.baseScore
        score += candidate.profileAffinity * 0.32
        if candidate.isRecurring {
            score += 32
        }
        if isExplicitReroll, candidate.isCurrentCycle, !candidate.isRecurring {
            score -= 120
        }
        if candidate.isNewSavedRecipe {
            score += 24
        } else if candidate.isSaved {
            score += 16
        }

        if candidate.recentFrequency > 0 {
            switch profile.rotationPreference {
            case .dynamic:
                score -= Double(candidate.recentFrequency) * 11
            case .stable:
                score -= Double(candidate.recentFrequency) * 3.5
            }
        }

        return score
    }

    private func requiredMealMoments(for candidates: [PlanningCandidate], targetCount: Int) -> [MealMoment] {
        var required: [MealMoment] = []
        if targetCount >= 3 {
            for moment in MealMoment.allCases where candidates.contains(where: { $0.mealMoments.contains(moment) }) {
                required.append(moment)
            }
        }

        if required.isEmpty {
            if candidates.contains(where: { $0.mealMoments.contains(.dinner) }) {
                required = [.dinner]
            } else if let fallbackMoment = MealMoment.allCases.first(where: { moment in
                candidates.contains(where: { $0.mealMoments.contains(moment) })
            }) {
                required = [fallbackMoment]
            }
        }

        return Array(required.prefix(targetCount))
    }

    private func seedBundle(
        from candidates: [PlanningCandidate],
        profile: UserProfile,
        targetCount: Int,
        requiredMoments: [MealMoment],
        savedRecipeIDs: Set<String>,
        recurringRecipeIDs: Set<String>,
        options: PrepGenerationOptions
    ) -> [PlanningCandidate] {
        var selected: [PlanningCandidate] = []
        if !recurringRecipeIDs.isEmpty {
            let recurringPool = candidates.filter { $0.isRecurring && !selected.contains($0) }
            for candidate in recurringPool {
                selected.append(candidate)
            }
        }

        for moment in requiredMoments {
            let pool = candidates.filter {
                $0.mealMoments.contains(moment) &&
                !selected.contains($0)
            }
            if let candidate = bestIncrementalCandidate(
                from: pool,
                selected: selected,
                profile: profile,
                requiredMoments: requiredMoments,
                savedRecipeIDs: savedRecipeIDs,
                recurringRecipeIDs: recurringRecipeIDs,
                targetCount: targetCount,
                options: options
            ) {
                selected.append(candidate)
            }
        }

        if !savedRecipeIDs.isEmpty && !selected.contains(where: \.isSaved),
           let savedCandidate = bestIncrementalCandidate(
            from: candidates.filter { $0.isSaved && !selected.contains($0) },
            selected: selected,
            profile: profile,
            requiredMoments: requiredMoments,
            savedRecipeIDs: savedRecipeIDs,
            recurringRecipeIDs: recurringRecipeIDs,
            targetCount: targetCount,
            options: options
           ) {
            selected.append(savedCandidate)
        }

        while selected.count < targetCount,
              let candidate = bestIncrementalCandidate(
                from: candidates.filter { !selected.contains($0) },
                selected: selected,
                profile: profile,
                requiredMoments: requiredMoments,
                savedRecipeIDs: savedRecipeIDs,
                recurringRecipeIDs: recurringRecipeIDs,
                targetCount: targetCount,
                options: options
              ) {
            selected.append(candidate)
        }

        return Array(selected.prefix(targetCount))
    }

    private func bestIncrementalCandidate(
        from candidates: [PlanningCandidate],
        selected: [PlanningCandidate],
        profile: UserProfile,
        requiredMoments: [MealMoment],
        savedRecipeIDs: Set<String>,
        recurringRecipeIDs: Set<String>,
        targetCount: Int,
        options: PrepGenerationOptions
    ) -> PlanningCandidate? {
        candidates.max { lhs, rhs in
            marginalBundleScore(
                adding: lhs,
                to: selected,
                profile: profile,
                requiredMoments: requiredMoments,
                savedRecipeIDs: savedRecipeIDs,
                recurringRecipeIDs: recurringRecipeIDs,
                targetCount: targetCount,
                options: options
            ) < marginalBundleScore(
                adding: rhs,
                to: selected,
                profile: profile,
                requiredMoments: requiredMoments,
                savedRecipeIDs: savedRecipeIDs,
                recurringRecipeIDs: recurringRecipeIDs,
                targetCount: targetCount,
                options: options
            )
        }
    }

    private func marginalBundleScore(
        adding candidate: PlanningCandidate,
        to selected: [PlanningCandidate],
        profile: UserProfile,
        requiredMoments: [MealMoment],
        savedRecipeIDs: Set<String>,
        recurringRecipeIDs: Set<String>,
        targetCount: Int,
        options: PrepGenerationOptions
    ) -> Double {
        var score = candidateSortScore(candidate, profile: profile)
        let coveredMoments = Set(selected.flatMap(\.mealMoments))
        let uncoveredMoments = Set(requiredMoments).subtracting(coveredMoments)

        if isExplicitReroll(options), candidate.isCurrentCycle, !candidate.isRecurring {
            score -= 180
        }

        if !uncoveredMoments.isDisjoint(with: candidate.mealMoments) {
            score += 24
        }

        if candidate.isRecurring && !selected.contains(where: \.isRecurring) {
            score += 18
        }

        if candidate.isNewSavedRecipe {
            score += 14
        } else if candidate.isSaved && !selected.contains(where: \.isSaved) {
            score += 8
        }

        let exactOverlap = selected.reduce(0) { partial, selectedCandidate in
            partial + candidate.ingredientKeys.intersection(selectedCandidate.ingredientKeys).count
        }
        let familyOverlap = selected.reduce(0) { partial, selectedCandidate in
            partial + candidate.ingredientFamilies.intersection(selectedCandidate.ingredientFamilies).count
        }

        score += Double(min(exactOverlap, 6)) * 4.6
        score += Double(min(max(0, familyOverlap - exactOverlap), 4)) * 2.3

        if !selected.isEmpty && exactOverlap == 0 && familyOverlap == 0 {
            score -= 6
        }

        score += candidate.profileAffinity * 0.24

        switch options.focus {
        case .balanced:
            score += fullnessBiasScore(for: candidate.recipe) * 0.8
        case .closerToFavorites:
            score += candidate.profileAffinity * 0.82
            if candidate.isNewSavedRecipe {
                score += 28
            } else if candidate.isSaved {
                score += 18
            }
            score += Double(min(exactOverlap, 4)) * 1.8
        case .moreVariety:
            let distinctCuisinePenalty = selected.filter { $0.recipe.cuisine == candidate.recipe.cuisine }.count
            score -= Double(distinctCuisinePenalty) * 9.0
            if candidate.mealMoments.subtracting(Set(selected.flatMap(\.mealMoments))).isEmpty == false {
                score += 7
            }
            if candidate.isSaved && !candidate.isRecurring {
                score -= 12
            }
            score -= candidate.profileAffinity * 0.18
        case .lessPrepTime:
            score += prepTimeBiasScore(for: candidate.recipe) * 1.15
            if candidate.recipe.prepMinutes > 32 {
                score -= 18
            }
        case .tighterOverlap:
            score += Double(min(exactOverlap, 6)) * 5.1
            score += Double(min(max(0, familyOverlap - exactOverlap), 4)) * 2.8
            if !selected.isEmpty && exactOverlap == 0 && familyOverlap == 0 {
                score -= 18
            }
        case .savedRecipeRefresh:
            score += candidate.profileAffinity * 0.82
            if candidate.isNewSavedRecipe {
                score += 28
            } else if candidate.isSaved {
                score += 18
            }
            score += Double(min(exactOverlap, 4)) * 1.8
        }

        score -= redundancyPenalty(
            for: candidate,
            against: selected,
            targetCount: targetCount,
            options: options
        )

        return score
    }

    private func optimizeBundle(
        _ seed: [PlanningCandidate],
        using candidates: [PlanningCandidate],
        profile: UserProfile,
        targetCount: Int,
        requiredMoments: [MealMoment],
        savedRecipeIDs: Set<String>,
        recurringRecipeIDs: Set<String>,
        lockedRecipeIDs: Set<String>,
        options: PrepGenerationOptions
    ) -> [PlanningCandidate] {
        var best = seed
        var bestScore = bundleScore(
            best,
            profile: profile,
            requiredMoments: requiredMoments,
            savedRecipeIDs: savedRecipeIDs,
            recurringRecipeIDs: recurringRecipeIDs,
            options: options
        )

        for _ in 0..<2 {
            var improved = false
            for index in best.indices {
                guard !lockedRecipeIDs.contains(best[index].recipe.id) else { continue }
                for candidate in candidates where !best.contains(candidate) {
                    var trial = best
                    trial[index] = candidate
                    let uniqueTrial = Array(Set(trial))
                    guard uniqueTrial.count == trial.count else { continue }

                    let trialScore = bundleScore(
                        trial,
                        profile: profile,
                        requiredMoments: requiredMoments,
                        savedRecipeIDs: savedRecipeIDs,
                        recurringRecipeIDs: recurringRecipeIDs,
                        options: options
                    )
                    if trialScore > bestScore + 0.5 {
                        best = trial
                        bestScore = trialScore
                        improved = true
                    }
                }
            }

            if !improved { break }
        }

        return Array(best.prefix(targetCount))
    }

    private func bundleScore(
        _ bundle: [PlanningCandidate],
        profile: UserProfile,
        requiredMoments: [MealMoment],
        savedRecipeIDs: Set<String>,
        recurringRecipeIDs: Set<String>,
        options: PrepGenerationOptions
    ) -> Double {
        guard !bundle.isEmpty else { return -.greatestFiniteMagnitude }

        var score = bundle.reduce(0) { $0 + candidateSortScore($1, profile: profile) }
        score += bundle.reduce(0) { $0 + min($1.profileAffinity, 28) * 0.3 }

        if isExplicitReroll(options) {
            let repeatedNonRecurringCount = bundle.filter { $0.isCurrentCycle && !$0.isRecurring }.count
            score -= Double(repeatedNonRecurringCount) * 220
        }

        let coveredMoments = Set(bundle.flatMap(\.mealMoments))
        let missingMoments = requiredMoments.filter { !coveredMoments.contains($0) }
        score -= Double(missingMoments.count) * 40

        if !recurringRecipeIDs.isEmpty && !bundle.contains(where: \.isRecurring) {
            score -= 46
        }

        if !savedRecipeIDs.isEmpty && !bundle.contains(where: \.isSaved) {
            score -= 32
        }

        var overlapScore = 0.0
        var cuisineCounts: [CuisinePreference: Int] = [:]
        var proteinCounts: [String: Int] = [:]
        var formatCounts: [String: Int] = [:]

        for index in bundle.indices {
            let candidate = bundle[index]
            cuisineCounts[candidate.recipe.cuisine, default: 0] += 1
            if let dominantProtein = candidate.dominantProtein {
                proteinCounts[dominantProtein, default: 0] += 1
            }
            formatCounts[candidate.formatKey, default: 0] += 1

            guard index < bundle.index(before: bundle.endIndex) else { continue }
            for other in bundle[(index + 1)...] {
                let exact = candidate.ingredientKeys.intersection(other.ingredientKeys).count
                let family = candidate.ingredientFamilies.intersection(other.ingredientFamilies).count
                overlapScore += Double(min(exact, 5)) * 3.2
                overlapScore += Double(min(max(0, family - exact), 3)) * 1.4
            }
        }

        score += overlapScore
        let cuisinePenaltyBase = Double(cuisineCounts.values.filter { $0 > 2 }.map { ($0 - 2) * 10 }.reduce(0, +))
        let proteinPenaltyBase = Double(proteinCounts.values.filter { $0 > 2 }.map { ($0 - 2) * 12 }.reduce(0, +))
        let formatPenaltyBase = Double(formatCounts.values.filter { $0 > 2 }.map { ($0 - 2) * 8 }.reduce(0, +))

        switch options.focus {
        case .balanced:
            score += bundle.reduce(0) { $0 + fullnessBiasScore(for: $1.recipe) } * 0.45
            score -= cuisinePenaltyBase
            score -= proteinPenaltyBase
            score -= formatPenaltyBase
        case .closerToFavorites:
            let savedCount = bundle.filter(\.isSaved).count
            score += bundle.reduce(0) { $0 + $1.profileAffinity } * 0.5
            score += Double(savedCount) * 24
            score -= cuisinePenaltyBase * 0.55
            score -= proteinPenaltyBase
            score -= formatPenaltyBase
        case .moreVariety:
            score += Double(cuisineCounts.keys.count) * 8
            score += Double(formatCounts.keys.count) * 5
            let nonRecurringSavedCount = bundle.filter { $0.isSaved && !$0.isRecurring }.count
            score -= Double(max(0, nonRecurringSavedCount - 1)) * 10
            score -= cuisinePenaltyBase * 1.5
            score -= proteinPenaltyBase * 1.35
            score -= formatPenaltyBase * 1.4
        case .lessPrepTime:
            score += bundle.reduce(0) { $0 + prepTimeBiasScore(for: $1.recipe) } * 0.65
            score -= Double(bundle.filter { $0.recipe.prepMinutes > 32 }.count) * 14
            score -= cuisinePenaltyBase * 0.9
            score -= proteinPenaltyBase * 0.85
            score -= formatPenaltyBase * 0.9
        case .tighterOverlap:
            score += overlapScore
            score -= cuisinePenaltyBase * 0.8
            score -= proteinPenaltyBase * 0.8
            score -= formatPenaltyBase
        case .savedRecipeRefresh:
            let savedCount = bundle.filter(\.isSaved).count
            score += bundle.reduce(0) { $0 + $1.profileAffinity } * 0.5
            score += Double(savedCount) * 24
            score -= cuisinePenaltyBase * 0.55
            score -= proteinPenaltyBase
            score -= formatPenaltyBase
        }

        return score
    }

    private func isExplicitReroll(_ options: PrepGenerationOptions) -> Bool {
        options.rerollNonce?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    private func redundancyPenalty(
        for candidate: PlanningCandidate,
        against selected: [PlanningCandidate],
        targetCount: Int,
        options: PrepGenerationOptions
    ) -> Double {
        var penalty = 0.0

        let sameCuisineCount = selected.filter { $0.recipe.cuisine == candidate.recipe.cuisine }.count
        if sameCuisineCount >= max(1, Int(ceil(Double(targetCount) * 0.34))) {
            penalty += Double((sameCuisineCount + 1) * 7)
        }

        if let dominantProtein = candidate.dominantProtein {
            let sameProteinCount = selected.filter { $0.dominantProtein == dominantProtein }.count
            if sameProteinCount >= 2 {
                penalty += Double((sameProteinCount - 1) * 9)
            }
        }

        let sameFormatCount = selected.filter { $0.formatKey == candidate.formatKey }.count
        if sameFormatCount >= 1 {
            penalty += Double(sameFormatCount) * 5
        }

        if sameCuisineCount >= max(1, profileDrivenCuisineRepeatThreshold(for: options)) {
            penalty += 4
        }

        return penalty
    }

    private func profileAffinityScore(for recipe: Recipe, profile: UserProfile) -> Double {
        let descriptor = recipeDescriptor(for: recipe)
        let descriptorTokens = Set(tokenizePreferencePhrase(descriptor))
        var score = 0.0

        if profile.preferredCuisines.contains(recipe.cuisine) {
            score += 14
        } else if profile.explorationLevel == .adventurous {
            score += 4
        }

        for country in profile.cuisineCountries.map({ $0.lowercased() }) where !country.isEmpty {
            if descriptor.contains(country) {
                score += 8
            }
        }

        for favoriteFood in profile.favoriteFoods.map({ $0.lowercased() }) where !favoriteFood.isEmpty {
            let phraseTokens = Set(tokenizePreferencePhrase(favoriteFood))
            if descriptor.contains(favoriteFood) {
                score += 10
            } else if phraseTokens.count >= 2 {
                let overlap = descriptorTokens.intersection(phraseTokens).count
                score += Double(overlap) * 3.5
            } else if let token = phraseTokens.first, descriptorTokens.contains(token) {
                score += 3
            }
        }

        for favoriteFlavor in profile.favoriteFlavors.map({ $0.lowercased() }) where !favoriteFlavor.isEmpty {
            if descriptor.contains(favoriteFlavor) {
                score += 6
            }
        }

        return score
    }

    private func recipeDescriptor(for recipe: Recipe) -> String {
        ([recipe.title] + (recipe.source.map { [$0] } ?? []) + recipe.ingredients.map(\.name) + recipe.tags)
            .joined(separator: " ")
            .lowercased()
    }

    private func tokenizePreferencePhrase(_ phrase: String) -> [String] {
        phrase
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count > 2 }
    }

    private func planningFocusSummary(_ focus: PrepRegenerationFocus) -> String {
        switch focus {
        case .balanced:
            return "filling-first"
        case .closerToFavorites:
            return "taste-first"
        case .moreVariety:
            return "variety-first"
        case .lessPrepTime:
            return "prep-light"
        case .tighterOverlap:
            return "grocery-overlap"
        case .savedRecipeRefresh:
            return "taste-first"
        }
    }

    private func profileDrivenCuisineRepeatThreshold(for options: PrepGenerationOptions) -> Int {
        switch options.focus {
        case .moreVariety:
            return 1
        case .balanced, .closerToFavorites, .lessPrepTime, .tighterOverlap, .savedRecipeRefresh:
            return 2
        }
    }

    private func fullnessBiasScore(for recipe: Recipe) -> Double {
        let descriptor = recipeDescriptor(for: recipe)
        var score = 0.0

        if descriptor.contains("stew") || descriptor.contains("curry") || descriptor.contains("bake") || descriptor.contains("roast") || descriptor.contains("bowl") {
            score += 4
        }
        if descriptor.contains("rice") || descriptor.contains("potato") || descriptor.contains("pasta") || descriptor.contains("bean") || descriptor.contains("lentil") {
            score += 3.5
        }
        if descriptor.contains("chicken") || descriptor.contains("beef") || descriptor.contains("salmon") || descriptor.contains("tofu") || descriptor.contains("egg") {
            score += 2.5
        }
        if recipe.tags.contains("protein-forward") {
            score += 4
        }
        if recipe.tags.contains("comfort") || recipe.tags.contains("meal-prep") {
            score += 2
        }
        if inferredMealMoments(for: recipe).contains(.dinner) {
            score += 2
        } else if inferredMealMoments(for: recipe).contains(.lunch) {
            score += 1
        }

        return score
    }

    private func prepTimeBiasScore(for recipe: Recipe) -> Double {
        var score = 0.0

        if recipe.prepMinutes <= 20 {
            score += 16
        } else if recipe.prepMinutes <= 30 {
            score += 10
        } else if recipe.prepMinutes <= 40 {
            score += 4
        } else {
            score -= min(Double(recipe.prepMinutes - 40) * 0.45, 12)
        }

        if recipe.tags.contains("quick") {
            score += 6
        }
        if recipe.tags.contains("one-pan") || recipe.tags.contains("minimal cleanup") {
            score += 5
        }
        if recipe.tags.contains("batch-friendly") {
            score += 2
        }

        return score
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

    private func inferredMealMoments(for recipe: Recipe) -> Set<MealMoment> {
        let descriptor = ([recipe.title] + recipe.tags).joined(separator: " ").lowercased()
        var moments: Set<MealMoment> = []

        if descriptor.contains("breakfast") || descriptor.contains("brunch") || descriptor.contains("oat") || descriptor.contains("yogurt") || descriptor.contains("egg bite") {
            moments.insert(.breakfast)
        }
        if descriptor.contains("lunch") || descriptor.contains("salad") || descriptor.contains("sandwich") || descriptor.contains("wrap") || descriptor.contains("bowl") || descriptor.contains("soup") {
            moments.insert(.lunch)
        }
        if descriptor.contains("dinner") || descriptor.contains("curry") || descriptor.contains("pasta") || descriptor.contains("tray bake") || descriptor.contains("sheet pan") || descriptor.contains("stew") || descriptor.contains("skillet") || descriptor.contains("salmon") || descriptor.contains("chicken") || descriptor.contains("beef") || descriptor.contains("shrimp") {
            moments.insert(.dinner)
        }

        if moments.isEmpty {
            moments.insert(.dinner)
        }

        return moments
    }

    private func ingredientKeys(for recipe: Recipe) -> Set<String> {
        Set(recipe.ingredients.compactMap { ingredient in
            let normalized = normalizedIngredientName(ingredient.name)
            guard !normalized.isEmpty, !overlapNoiseTerms.contains(normalized) else { return nil }
            return normalized
        })
    }

    private func ingredientFamilyKeys(for recipe: Recipe) -> Set<String> {
        Set(recipe.ingredients.compactMap { ingredient in
            let family = ingredientFamily(for: ingredient.name)
            guard !family.isEmpty, !overlapNoiseTerms.contains(family) else { return nil }
            return family
        })
    }

    private func dominantProtein(for recipe: Recipe) -> String? {
        for ingredient in recipe.ingredients {
            let family = ingredientFamily(for: ingredient.name)
            if [
                "chicken", "turkey", "beef", "steak", "salmon", "shrimp", "fish",
                "pork", "egg", "tofu", "lentil", "bean"
            ].contains(family) {
                return family
            }
        }
        return nil
    }

    private func recipeFormatKey(for recipe: Recipe) -> String {
        let descriptor = ([recipe.title] + recipe.tags).joined(separator: " ").lowercased()
        if descriptor.contains("bowl") { return "bowl" }
        if descriptor.contains("pasta") || descriptor.contains("orzo") || descriptor.contains("noodle") { return "pasta" }
        if descriptor.contains("salad") { return "salad" }
        if descriptor.contains("soup") || descriptor.contains("stew") || descriptor.contains("chili") { return "soup" }
        if descriptor.contains("tray bake") || descriptor.contains("sheet pan") || descriptor.contains("skillet") { return "tray" }
        if descriptor.contains("sandwich") || descriptor.contains("wrap") || descriptor.contains("taco") { return "handheld" }
        return "plate"
    }

    private func normalizedRecipeTitleKey(_ value: String) -> String {
        value
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9\\s]", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\b(the|a|an)\\b", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func normalizedIngredientName(_ value: String) -> String {
        var normalized = value
            .lowercased()
            .replacingOccurrences(of: "[^a-z\\s]", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let descriptorTerms: Set<String> = [
            "fresh", "dried", "ground", "boneless", "skinless", "large", "small", "baby",
            "red", "yellow", "green", "white", "extra", "virgin", "low", "reduced"
        ]

        normalized = normalized
            .split(separator: " ")
            .map(String.init)
            .filter { !descriptorTerms.contains($0) }
            .joined(separator: " ")

        return normalized.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func ingredientFamily(for value: String) -> String {
        let normalized = normalizedIngredientName(value)
        guard !normalized.isEmpty else { return "" }

        let families: [(String, [String])] = [
            ("chicken", ["chicken"]),
            ("turkey", ["turkey"]),
            ("beef", ["beef", "steak"]),
            ("salmon", ["salmon"]),
            ("shrimp", ["shrimp", "prawn"]),
            ("fish", ["fish", "cod", "tilapia", "trout"]),
            ("egg", ["egg"]),
            ("tofu", ["tofu"]),
            ("lentil", ["lentil"]),
            ("bean", ["bean", "chickpea"]),
            ("rice", ["rice"]),
            ("pasta", ["pasta", "orzo", "noodle"]),
            ("potato", ["potato"]),
            ("onion", ["onion", "shallot"]),
            ("garlic", ["garlic"]),
            ("tomato", ["tomato"]),
            ("pepper", ["pepper"]),
            ("yogurt", ["yogurt"]),
            ("lemon", ["lemon"]),
            ("lime", ["lime"]),
            ("herb", ["cilantro", "parsley", "basil", "mint", "thyme", "oregano"])
        ]

        for (family, aliases) in families where aliases.contains(where: { normalized.contains($0) }) {
            return family
        }

        return normalized
    }

    private func buildGroceryList(from recipes: [PlannedRecipe], profile: UserProfile, inventory: [InventoryItem]) -> [GroceryItem] {
        let ingredientItems = buildIngredientContributions(from: recipes)

        var inventoryMap: [String: Double] = [:]
        for item in inventory {
            let key = "\(canonicalIngredientName(item.name))::\(canonicalUnitName(item.unit))"
            inventoryMap[key, default: 0] += item.amount
        }

        let adjusted = ingredientItems.compactMap { item -> GroceryItem? in
            let key = item.id
            let inStock = inventoryMap[key, default: 0]
            let needed = item.amount - inStock
            guard needed > 0.1 else { return nil }

            let ratio = needed / max(item.amount, 0.1)
            return GroceryItem(
                name: item.name,
                amount: needed,
                unit: item.unit,
                estimatedPrice: item.estimatedPrice * ratio,
                sourceIngredients: item.sourceIngredients
            )
        }

        return adjusted.sorted { $0.estimatedPrice > $1.estimatedPrice }
    }

    private func buildIngredientContributions(from recipes: [PlannedRecipe]) -> [GroceryItem] {
        var ingredientMap: [String: GroceryItem] = [:]

        for plannedRecipe in recipes {
            let scale = Double(plannedRecipe.servings) / Double(plannedRecipe.recipe.servings)
            for ingredient in plannedRecipe.recipe.ingredients {
                if shouldSuppressGenericIngredient(ingredient, in: plannedRecipe.recipe) {
                    continue
                }

                let sourceDisplayName = recoveredIngredientNameIfNeeded(from: ingredient) ?? ingredient.name
                let displayName = genericBucketDisplayName(for: sourceDisplayName)
                let canonicalName = canonicalIngredientName(displayName)
                let canonicalUnit = canonicalUnitName(ingredient.unit)
                let key = "\(canonicalName)::\(canonicalUnit)"
                let amountToAdd = ingredient.amount * scale
                let priceToAdd = ingredient.estimatedUnitPrice * amountToAdd
                let source = GroceryItemSource(
                    recipeID: plannedRecipe.recipe.id,
                    ingredientName: displayName,
                    unit: canonicalUnit
                )

                if var existing = ingredientMap[key] {
                    existing.amount += amountToAdd
                    existing.estimatedPrice += priceToAdd
                    if !existing.sourceIngredients.contains(source) {
                        existing.sourceIngredients.append(source)
                    }
                    ingredientMap[key] = existing
                } else {
                    ingredientMap[key] = GroceryItem(
                        name: canonicalName,
                        amount: amountToAdd,
                        unit: canonicalUnit,
                        estimatedPrice: max(priceToAdd, 0.25),
                        sourceIngredients: [source]
                    )
                }
            }
        }

        return Array(ingredientMap.values)
    }

    func expectedGrocerySourceKeys(from recipes: [PlannedRecipe]) -> Set<String> {
        Set(
            buildIngredientContributions(from: recipes)
                .flatMap(\.sourceIngredients)
                .map(Self.grocerySourceCoverageKey)
                .filter { !$0.isEmpty }
        )
    }

    func coveredGrocerySourceKeys(from groceries: [GroceryItem]) -> Set<String> {
        Set(
            groceries
                .flatMap(\.sourceIngredients)
                .map(Self.grocerySourceCoverageKey)
                .filter { !$0.isEmpty }
        )
    }

    func hasCompleteGrocerySourceCoverage(recipes: [PlannedRecipe], groceries: [GroceryItem]) -> Bool {
        let expected = expectedGrocerySourceKeys(from: recipes)
        guard !expected.isEmpty else { return true }
        let covered = coveredGrocerySourceKeys(from: groceries)
        return expected.isSubset(of: covered)
    }

    private static func grocerySourceCoverageKey(_ source: GroceryItemSource) -> String {
        let recipeID = source.recipeID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let ingredientName = normalizedSourceIngredientKey(source.ingredientName)
        let unit = source.unit.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !recipeID.isEmpty, !ingredientName.isEmpty else { return "" }
        return "\(recipeID)::\(ingredientName)::\(unit)"
    }

    private static func normalizedSourceIngredientKey(_ value: String) -> String {
        value
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func applyGroceryContributions(
        from recipes: [PlannedRecipe],
        into groceries: inout [GroceryItem],
        subtracting: Bool
    ) {
        let contributions = buildIngredientContributions(from: recipes)

        for contribution in contributions {
            if let index = groceries.firstIndex(where: { $0.id == contribution.id }) {
                var item = groceries[index]
                let sourceSet = Set(contribution.sourceIngredients)

                if subtracting {
                    item.amount -= contribution.amount
                    item.estimatedPrice -= contribution.estimatedPrice
                    item.sourceIngredients.removeAll { sourceSet.contains($0) }
                    if item.amount <= 0.1 {
                        groceries.remove(at: index)
                        continue
                    }
                } else {
                    item.amount += contribution.amount
                    item.estimatedPrice += contribution.estimatedPrice
                    for source in contribution.sourceIngredients where !item.sourceIngredients.contains(source) {
                        item.sourceIngredients.append(source)
                    }
                }

                groceries[index] = item
            } else if !subtracting {
                groceries.append(contribution)
            }
        }
    }

    private func dedupeRecipesByID(_ recipes: [Recipe]) -> [Recipe] {
        var seen = Set<String>()
        var deduped: [Recipe] = []

        for recipe in recipes {
            if seen.insert(recipe.id).inserted {
                deduped.append(recipe)
            }
        }

        return deduped
    }

    private func canonicalIngredientName(_ value: String) -> String {
        let normalized = normalizedIngredientName(value)
        if normalized.isEmpty {
            return String(value).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }

        if let aliased = ingredientAliasMap[normalized] {
            return aliased
        }

        let singularized = normalized
            .split(separator: " ")
            .map { singularizeToken(String($0)) }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if let aliased = ingredientAliasMap[singularized] {
            return aliased
        }

        return singularized.isEmpty ? normalized : singularized
    }

    private func genericBucketKind(for value: String) -> String? {
        let normalized = normalizedIngredientName(value)
        guard !normalized.isEmpty else { return nil }
        switch normalized {
        case "spice", "spices", "seasoning", "seasonings":
            return "spice"
        case "herb", "herbs":
            return "herb"
        case "sauce", "sauces", "dressing", "dressings", "marinade", "marinades", "glaze", "glazes":
            return "sauce"
        case "topping", "toppings", "garnish", "garnishes":
            return "topping"
        default:
            return nil
        }
    }

    private func isConcreteIngredientForBucket(_ value: String, bucketKind: String) -> Bool {
        let normalized = normalizedIngredientName(value)
        guard !normalized.isEmpty else { return false }
        if genericIngredientBucketTerms.contains(normalized) {
            return false
        }

        switch bucketKind {
        case "spice":
            return concreteSpiceHints.contains(where: { normalized.contains($0) })
        case "herb":
            return ["cilantro", "parsley", "basil", "mint", "thyme", "oregano", "rosemary", "sage", "dill", "chive"].contains(where: { normalized.contains($0) })
        case "sauce":
            return ["honey", "sriracha", "soy sauce", "hot sauce", "vinegar", "mustard", "mayo", "yogurt", "bbq", "worcestershire", "sesame oil", "fish sauce", "oyster sauce", "hoisin", "teriyaki", "chipotle", "tomato sauce"].contains(where: { normalized.contains($0) })
        case "topping":
            return ["cheese", "onion", "scallion", "cilantro", "parsley", "lime", "avocado", "crisp", "seed", "nut"].contains(where: { normalized.contains($0) })
        default:
            return false
        }
    }

    private func shouldSuppressGenericIngredient(_ ingredient: RecipeIngredient, in recipe: Recipe) -> Bool {
        guard let bucketKind = genericBucketKind(for: ingredient.name) else { return false }
        let supportingCount = recipe.ingredients.filter { isConcreteIngredientForBucket($0.name, bucketKind: bucketKind) }.count
        return supportingCount >= 1
    }

    private func genericBucketDisplayName(for value: String) -> String {
        let normalized = normalizedIngredientName(value)
        switch normalized {
        case "spice", "spices", "seasoning", "seasonings":
            return "seasoning blend"
        case "herb", "herbs":
            return "herb blend"
        case "sauce", "sauces", "dressing", "dressings", "marinade", "marinades", "glaze", "glazes":
            return "sauce mix"
        case "topping", "toppings", "garnish", "garnishes":
            return "topping mix"
        default:
            return value
        }
    }

    private func recoveredIngredientNameIfNeeded(from ingredient: RecipeIngredient) -> String? {
        let normalizedName = normalizedIngredientName(ingredient.name)
        guard normalizedName.count <= 2 else { return nil }

        let unitTokens = ingredient.unit
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        guard unitTokens.count > 1,
              let first = unitTokens.first
        else { return nil }

        let knownUnits: Set<String> = [
            "cup", "cups", "tbsp", "tbsps", "tablespoon", "tablespoons",
            "tsp", "tsps", "teaspoon", "teaspoons",
            "lb", "lbs", "pound", "pounds", "oz", "ounce", "ounces",
            "g", "gram", "grams", "kg", "kilogram", "kilograms",
            "ml", "milliliter", "milliliters", "l", "liter", "liters",
            "clove", "cloves", "slice", "slices", "can", "cans",
            "jar", "jars", "package", "packages", "medium", "large", "small"
        ]
        let normalizedUnit = first.trimmingCharacters(in: .punctuationCharacters).lowercased()
        guard knownUnits.contains(normalizedUnit) else { return nil }

        let recovered = unitTokens.dropFirst().joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return recovered.isEmpty ? nil : recovered
    }

    private func isGenericIngredientBucketLabel(_ value: String) -> Bool {
        guard let bucketKind = genericBucketKind(for: value) else { return false }
        return bucketKind == "spice" || bucketKind == "herb" || bucketKind == "sauce" || bucketKind == "topping"
    }

    private func singularizeToken(_ token: String) -> String {
        let value = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count > 2 else { return value }

        if value.hasSuffix("ies"), value.count > 4 {
            return String(value.dropLast(3)) + "y"
        }
        if value.hasSuffix("oes"), value.count > 4 {
            return String(value.dropLast(2))
        }
        if value.hasSuffix("s"), !value.hasSuffix("ss"), value.count > 3 {
            return String(value.dropLast(1))
        }
        return value
    }

    private func canonicalUnitName(_ value: String) -> String {
        let normalized = String(value)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if normalized.isEmpty {
            return "ct"
        }
        return unitAliasMap[normalized] ?? normalized
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
