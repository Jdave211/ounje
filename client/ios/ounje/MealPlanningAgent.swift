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
        options: PrepGenerationOptions = .standard,
        regenerationContext: PrepRegenerationContext? = nil,
        now: Date = Date(),
        recipeTitle: String? = nil,
        recipeImageURL: String? = nil,
        recipeID: String? = nil,
        userID: String? = nil,
        accessToken: String? = nil
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
        let candidates = await recipeCatalog.recipes(
            for: profile,
            historyRecipeIDs: recentHistoryRecipeIDs,
            regenerationContext: regenerationContext,
            savedRecipeIDs: Array(savedRecipeIDs)
        )
        let scored = rank(candidates: candidates, profile: profile, options: options)
        let targetRecipeCount = resolvedTargetRecipeCount(profile: profile)

        pipeline.append(
            PipelineDecision(
                stage: .curateRecipes,
                summary: "Scored \(scored.count) live recipe candidates, then built a \(targetRecipeCount)-meal prep bundle around allergy safety, breakfast-lunch-dinner coverage, onboarding taste signals, ingredient overlap, saved-meal inclusion, and total variety."
            )
        )

        let selected = selectRecipes(
            from: scored,
            profile: profile,
            history: history,
            savedRecipeIDs: savedRecipeIDs,
            options: options
        )
        let carriedCount = selected.filter(\.carriedFromPreviousPlan).count
        let savedSelectedCount = selected.filter { savedRecipeIDs.contains($0.recipe.id) }.count

        pipeline.append(
            PipelineDecision(
                stage: .handleRotation,
                summary: profile.rotationPreference == .dynamic
                    ? "Dynamic mode selected \(selected.count) recipes with only \(carriedCount) carry-over entries, while carrying \(savedSelectedCount) saved meal\(savedSelectedCount == 1 ? "" : "s") into the cycle when available."
                    : "Stable mode selected \(selected.count) recipes, preserved \(carriedCount) prior favorites, and still pulled in \(savedSelectedCount) saved meal\(savedSelectedCount == 1 ? "" : "s") when possible."
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
            recipeID: recipeID,
            userID: userID,
            accessToken: accessToken
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
            let storeLabel = top.selectedStore.map { " via \($0.storeName)" } ?? ""
            pipeline.append(
                PipelineDecision(
                    stage: .optimizeProvider,
                    summary: "Best provider: \(top.provider.title)\(storeLabel) (\(statusLabel)) at \(top.estimatedTotal.asCurrency) (\(budgetState)), ETA \(top.etaDays) day(s)."
                )
            )
        }

        return composePlan(
            profile: profile,
            selectedRecipes: selected,
            now: now,
            pipeline: pipeline,
            groceries: groceries,
            quotes: quotes
        )
    }

    func buildPlan(
        profile: UserProfile,
        recipes: [PlannedRecipe],
        history: [MealPlan] = [],
        now: Date = Date()
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
                    summary: "Best provider: \(top.provider.title)\(storeLabel) (\(statusLabel)) at \(top.estimatedTotal.asCurrency) (\(budgetState)), ETA \(top.etaDays) day(s)."
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
            history: history
        )
    }

    func rebuildPlan(
        profile: UserProfile,
        basePlan: MealPlan,
        recipes: [PlannedRecipe],
        history: [MealPlan] = [],
        now: Date = Date()
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
                    summary: "Best provider: \(top.provider.title)\(storeLabel) (\(statusLabel)) at \(top.estimatedTotal.asCurrency) (\(budgetState)), ETA \(top.etaDays) day(s)."
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
            pipeline: composedPipeline
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
        recipeID: String? = nil
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
            pipeline: pipeline
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
            score += profileAffinityScore(for: recipe, profile: profile) * 0.55
        case .moreVariety:
            if !profile.preferredCuisines.contains(recipe.cuisine) {
                score += 6
            }
            if inferredMealMoments(for: recipe).count > 1 {
                score += 3
            }
        case .lessPrepTime:
            score += prepTimeBiasScore(for: recipe)
        case .tighterOverlap:
            if recipe.tags.contains("budget") {
                score += 7
            }
            if recipe.tags.contains("meal-prep") {
                score += 4
            }
        case .savedRecipeRefresh:
            score += 2
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

    private func selectRecipes(
        from rankedRecipes: [Recipe],
        profile: UserProfile,
        history: [MealPlan],
        savedRecipeIDs: Set<String>,
        options: PrepGenerationOptions
    ) -> [PlannedRecipe] {
        let targetCount = resolvedTargetRecipeCount(profile: profile)
        let previousPlanRecipeIDs = Set(history.first?.recipes.map { $0.recipe.id } ?? [])
        let recentRecipeIDs = Set(history.prefix(4).flatMap(\.recipes).map { $0.recipe.id })
        let frequencyMap = recipeFrequency(from: history)

        let candidates = buildPlanningCandidates(
            from: rankedRecipes,
            profile: profile,
            recentRecipeIDs: recentRecipeIDs,
            frequencyMap: frequencyMap,
            savedRecipeIDs: savedRecipeIDs,
            targetCount: targetCount,
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
            options: options
        )
        selected = optimizeBundle(
            selected,
            using: candidates,
            profile: profile,
            targetCount: targetCount,
            requiredMoments: requiredMoments,
            savedRecipeIDs: savedRecipeIDs,
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

    private func resolvedTargetRecipeCount(profile: UserProfile) -> Int {
        let cycleWeeks = max(1.0, Double(profile.cadence.dayInterval) / 7.0)
        let cycleMealDemand = Double(profile.consumption.mealsPerWeek) * cycleWeeks
        let repeatFactor = profile.consumption.includeLeftovers ? 1.45 : 1.15
        var target = cycleMealDemand / repeatFactor

        switch profile.explorationLevel {
        case .comfort:
            target -= 0.35
        case .balanced:
            target += 0.15
        case .adventurous:
            target += 0.8
        }

        switch profile.budgetFlexibility {
        case .strict:
            target -= 0.35
        case .slightlyFlexible:
            break
        case .convenienceFirst:
            target += 0.25
        }

        if profile.consumption.kids > 0 || profile.cooksForOthers {
            target -= 0.15
        }

        return max(3, min(7, Int(target.rounded(.toNearestOrAwayFromZero))))
    }

    private func buildPlanningCandidates(
        from rankedRecipes: [Recipe],
        profile: UserProfile,
        recentRecipeIDs: Set<String>,
        frequencyMap: [String: Int],
        savedRecipeIDs: Set<String>,
        targetCount: Int,
        options: PrepGenerationOptions
    ) -> [PlanningCandidate] {
        let seeded = rankedRecipes.map { recipe in
            let isSaved = savedRecipeIDs.contains(recipe.id)
            let isRecent = recentRecipeIDs.contains(recipe.id)
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
                isNewSavedRecipe: isSaved && !isRecent
            )
            return candidate
        }

        let imageRichCandidates = seeded.filter { !$0.recipe.isImagePoor }
        let qualityPool: [PlanningCandidate]
        if imageRichCandidates.count >= max(targetCount + 2, 6) {
            qualityPool = imageRichCandidates
        } else {
            qualityPool = seeded
        }

        return qualityPool
            .filter { $0.baseScore > -1_000 }
            .sorted { lhs, rhs in
                let lhsScore = candidateSortScore(lhs, profile: profile)
                let rhsScore = candidateSortScore(rhs, profile: profile)
                if lhsScore == rhsScore {
                    return lhs.recipe.id < rhs.recipe.id
                }
                return lhsScore > rhsScore
            }
            .prefix(42)
            .map { $0 }
    }

    private func candidateSortScore(_ candidate: PlanningCandidate, profile: UserProfile) -> Double {
        var score = candidate.baseScore
        score += candidate.profileAffinity * 0.32
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
        options: PrepGenerationOptions
    ) -> [PlanningCandidate] {
        var selected: [PlanningCandidate] = []

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
                targetCount: targetCount,
                options: options
            ) < marginalBundleScore(
                adding: rhs,
                to: selected,
                profile: profile,
                requiredMoments: requiredMoments,
                savedRecipeIDs: savedRecipeIDs,
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
        targetCount: Int,
        options: PrepGenerationOptions
    ) -> Double {
        var score = candidateSortScore(candidate, profile: profile)
        let coveredMoments = Set(selected.flatMap(\.mealMoments))
        let uncoveredMoments = Set(requiredMoments).subtracting(coveredMoments)

        if !uncoveredMoments.isDisjoint(with: candidate.mealMoments) {
            score += 24
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
            score += candidate.profileAffinity * 0.55
        case .moreVariety:
            let distinctCuisinePenalty = selected.filter { $0.recipe.cuisine == candidate.recipe.cuisine }.count
            score -= Double(distinctCuisinePenalty) * 6.5
            if candidate.mealMoments.subtracting(Set(selected.flatMap(\.mealMoments))).isEmpty == false {
                score += 7
            }
        case .lessPrepTime:
            score += prepTimeBiasScore(for: candidate.recipe) * 1.15
        case .tighterOverlap:
            score += Double(min(exactOverlap, 6)) * 3.4
            score += Double(min(max(0, familyOverlap - exactOverlap), 4)) * 1.9
            if !selected.isEmpty && exactOverlap == 0 && familyOverlap == 0 {
                score -= 12
            }
        case .savedRecipeRefresh:
            if candidate.isNewSavedRecipe {
                score += 24
            } else if candidate.isSaved {
                score += 18
            }
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
        options: PrepGenerationOptions
    ) -> [PlanningCandidate] {
        var best = seed
        var bestScore = bundleScore(
            best,
            profile: profile,
            requiredMoments: requiredMoments,
            savedRecipeIDs: savedRecipeIDs,
            options: options
        )

        for _ in 0..<2 {
            var improved = false
            for index in best.indices {
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
        options: PrepGenerationOptions
    ) -> Double {
        guard !bundle.isEmpty else { return -.greatestFiniteMagnitude }

        var score = bundle.reduce(0) { $0 + candidateSortScore($1, profile: profile) }
        score += bundle.reduce(0) { $0 + min($1.profileAffinity, 28) * 0.3 }

        let coveredMoments = Set(bundle.flatMap(\.mealMoments))
        let missingMoments = requiredMoments.filter { !coveredMoments.contains($0) }
        score -= Double(missingMoments.count) * 40

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
            score += bundle.reduce(0) { $0 + $1.profileAffinity } * 0.35
            score -= cuisinePenaltyBase * 0.75
            score -= proteinPenaltyBase
            score -= formatPenaltyBase
        case .moreVariety:
            score += Double(cuisineCounts.keys.count) * 8
            score += Double(formatCounts.keys.count) * 5
            score -= cuisinePenaltyBase * 1.5
            score -= proteinPenaltyBase * 1.35
            score -= formatPenaltyBase * 1.4
        case .lessPrepTime:
            score += bundle.reduce(0) { $0 + prepTimeBiasScore(for: $1.recipe) } * 0.65
            score -= cuisinePenaltyBase * 0.9
            score -= proteinPenaltyBase * 0.85
            score -= formatPenaltyBase * 0.9
        case .tighterOverlap:
            score += overlapScore * 0.7
            score -= cuisinePenaltyBase * 0.8
            score -= proteinPenaltyBase * 0.8
            score -= formatPenaltyBase
        case .savedRecipeRefresh:
            let savedCount = bundle.filter(\.isSaved).count
            score += Double(savedCount) * 20
            score -= cuisinePenaltyBase
            score -= proteinPenaltyBase
            score -= formatPenaltyBase
        }

        return score
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
            return "favorites-first"
        case .moreVariety:
            return "variety-first"
        case .lessPrepTime:
            return "prep-light"
        case .tighterOverlap:
            return "grocery-overlap"
        case .savedRecipeRefresh:
            return "saved-recipes"
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
        var ingredientMap: [String: GroceryItem] = [:]

        for plannedRecipe in recipes {
            let scale = Double(plannedRecipe.servings) / Double(plannedRecipe.recipe.servings)
            for ingredient in plannedRecipe.recipe.ingredients {
                let canonicalName = canonicalIngredientName(ingredient.name)
                let canonicalUnit = canonicalUnitName(ingredient.unit)
                let key = "\(canonicalName)::\(canonicalUnit)"
                let amountToAdd = ingredient.amount * scale
                let priceToAdd = ingredient.estimatedUnitPrice * amountToAdd
                let source = GroceryItemSource(
                    recipeID: plannedRecipe.recipe.id,
                    ingredientName: ingredient.name,
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

        var inventoryMap: [String: Double] = [:]
        for item in inventory {
            let key = "\(canonicalIngredientName(item.name))::\(canonicalUnitName(item.unit))"
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
                estimatedPrice: item.estimatedPrice * ratio,
                sourceIngredients: item.sourceIngredients
            )
        }

        return adjusted.sorted { $0.estimatedPrice > $1.estimatedPrice }
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
