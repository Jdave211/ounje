import Foundation

struct OnboardingRecipeEditDemoRecipe: Identifiable {
    let card: DiscoverRecipeCardData
    let detail: RecipeDetailData
    let optionFixtures: [OnboardingRecipeEditDemoOptionFixture]

    var id: String { card.id }

    func resolvedOptionFixtures(
        selectedDietaryPatterns: Set<String>
    ) -> [OnboardingRecipeEditDemoOptionFixture] {
        let defaultFixtures = defaultResolvedFixtures
        let selectedDiets = Set(selectedDietaryPatterns.map(Self.normalizedDietName))
        guard !selectedDiets.isEmpty else {
            return Array(defaultFixtures.prefix(3))
        }

        let dietFixtures = dietFixturePriority.compactMap { entry -> OnboardingRecipeEditDemoOptionFixture? in
            let diet = entry.diet
            let intent = entry.intent
            guard selectedDiets.contains(diet) else { return nil }
            if let existingFixture = defaultFixtures.first(where: { $0.intent == intent }) {
                return existingFixture
            }
            if intent == .dairyFree {
                return .dairyFreeFixture(for: self)
            }
            return nil
        }

        var seenIntents = Set<String>()
        let prioritizedFixtures = (dietFixtures + defaultFixtures).filter { fixture in
            guard !seenIntents.contains(fixture.intent.rawValue) else { return false }
            seenIntents.insert(fixture.intent.rawValue)
            return true
        }

        return Array(prioritizedFixtures.prefix(3))
    }

    private var defaultResolvedFixtures: [OnboardingRecipeEditDemoOptionFixture] {
        guard let healthyFixture = OnboardingRecipeEditDemoOptionFixture.healthyFixture(for: self),
              !optionFixtures.contains(where: { $0.intent == healthyFixture.intent })
        else {
            return optionFixtures
        }

        var fixtures = optionFixtures
        fixtures.insert(healthyFixture, at: min(1, fixtures.count))
        return fixtures
    }

    private static func normalizedDietName(_ value: String) -> String {
        value
            .lowercased()
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: " ", with: "")
    }

    private var dietFixturePriority: [(diet: String, intent: RecipeAlterationIntent)] {
        [
            ("keto", .keto),
            ("dairyfree", .dairyFree),
            ("glutenfree", .glutenFree),
        ]
    }
}

struct OnboardingRecipeEditDemoOptionFixture: Decodable, Identifiable {
    let recipeID: String
    let intent: RecipeAlterationIntent
    let preplannedSummary: String
    let adaptedRecipe: RecipeAdaptationRecipe
    let changeSummary: String?
    let editSummary: RecipeAdaptationEditSummary?
    let validationStatus: String?
    let modelMode: String
    let model: String

    enum CodingKeys: String, CodingKey {
        case recipeID = "recipe_id"
        case intentKey = "intent_key"
        case preplannedSummary = "preplanned_summary"
        case adaptedRecipe = "adapted_recipe"
        case changeSummary = "change_summary"
        case editSummary = "edit_summary"
        case validationStatus = "validation_status"
        case modelMode = "model_mode"
        case model
    }

    init(
        recipeID: String,
        intent: RecipeAlterationIntent,
        preplannedSummary: String,
        adaptedRecipe: RecipeAdaptationRecipe,
        changeSummary: String? = nil,
        editSummary: RecipeAdaptationEditSummary? = nil,
        validationStatus: String? = "structural_passed",
        modelMode: String = "scripted_onboarding_demo",
        model: String = "onboarding-fixture"
    ) {
        self.recipeID = recipeID
        self.intent = intent
        self.preplannedSummary = preplannedSummary
        self.adaptedRecipe = adaptedRecipe
        self.changeSummary = changeSummary
        self.editSummary = editSummary
        self.validationStatus = validationStatus
        self.modelMode = modelMode
        self.model = model
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let intentKey = try container.decode(String.self, forKey: .intentKey)
        guard let intent = Self.intent(for: intentKey) else {
            throw DecodingError.dataCorruptedError(
                forKey: .intentKey,
                in: container,
                debugDescription: "Unsupported onboarding demo intent \(intentKey)"
            )
        }

        recipeID = try container.decode(String.self, forKey: .recipeID)
        self.intent = intent
        preplannedSummary = try container.decode(String.self, forKey: .preplannedSummary)
        adaptedRecipe = try container.decode(RecipeAdaptationRecipe.self, forKey: .adaptedRecipe)
        changeSummary = try container.decodeIfPresent(String.self, forKey: .changeSummary)
        editSummary = try container.decodeIfPresent(RecipeAdaptationEditSummary.self, forKey: .editSummary)
        validationStatus = try container.decodeIfPresent(String.self, forKey: .validationStatus)
        modelMode = try container.decode(String.self, forKey: .modelMode)
        model = try container.decode(String.self, forKey: .model)
    }

    var id: String { "\(recipeID)::\(intent.rawValue)" }

    var oneLineChangeSummary: String {
        switch (recipeID, intent) {
        case ("cdf56b03-71e8-4386-acb1-262837286a36", .moreProtein):
            return "Added Greek yogurt, added more eggs, removed powdered sugar."
        case ("cdf56b03-71e8-4386-acb1-262837286a36", .healthier):
            return "Added whole-grain bread, added Greek yogurt, removed added sugar."
        case ("cdf56b03-71e8-4386-acb1-262837286a36", .lessSugar):
            return "Removed powdered sugar, removed granulated sugar."
        case ("cdf56b03-71e8-4386-acb1-262837286a36", .quick):
            return "No overnight chill, shorter bake, simpler prep."
        case ("cdf56b03-71e8-4386-acb1-262837286a36", .dairyFree):
            return "Added coconut milk, added dairy-free cream cheese, removed dairy milk."
        case ("b1bd5a95-dab3-436e-89c8-fb4df52b8fb7", .moreProtein):
            return "Added black beans, adjusted chicken."
        case ("b1bd5a95-dab3-436e-89c8-fb4df52b8fb7", .spicy):
            return "Added cayenne, added lime, added more heat."
        case ("b1bd5a95-dab3-436e-89c8-fb4df52b8fb7", .mealPrep):
            return "Separate components, extra sauce, reheat-friendly steps."
        case ("eaa85ffd-1a66-44e9-84e7-2c7d4b950390", .moreProtein):
            return "Added shredded chicken, added Greek yogurt."
        case ("eaa85ffd-1a66-44e9-84e7-2c7d4b950390", .keto):
            return "Removed pasta, added spinach, added lemon."
        case ("eaa85ffd-1a66-44e9-84e7-2c7d4b950390", .lighter):
            return "Removed olive oil, removed Parmesan, added basil."
        case ("eaa85ffd-1a66-44e9-84e7-2c7d4b950390", .dairyFree):
            return "Added nutritional yeast, added pasta water, removed Parmesan."
        case ("4bcf072c-b95d-49fa-9997-d2749a118a15", .lessSugar):
            return "Removed powdered sugar, removed granulated sugar."
        case ("4bcf072c-b95d-49fa-9997-d2749a118a15", .glutenFree):
            return "Added gluten-free flour."
        case ("4bcf072c-b95d-49fa-9997-d2749a118a15", .lighter):
            return "Removed butter, removed sugar, added coconut oil."
        case ("4bcf072c-b95d-49fa-9997-d2749a118a15", .dairyFree):
            return "Added plant butter, added coconut oil, removed dairy butter."
        default:
            return changeSummary ?? preplannedSummary
        }
    }

    func makeResponse(from recipe: OnboardingRecipeEditDemoRecipe) -> RecipeAdaptationResponse {
        let adaptedRecipeID = "onboarding-demo-\(recipe.id)-\(intent.intentKey)"
        let adaptedDetail = makeAdaptedDetail(from: recipe.detail, adaptedRecipeID: adaptedRecipeID)
        let adaptedCard = DiscoverRecipeCardData(
            id: adaptedRecipeID,
            title: adaptedRecipe.title,
            description: adaptedRecipe.summary,
            authorName: recipe.card.authorName,
            authorHandle: recipe.card.authorHandle,
            category: recipe.card.category,
            recipeType: recipe.card.recipeType,
            cookTimeText: adaptedRecipe.cookTimeText,
            cookTimeMinutes: Self.extractCookTimeMinutes(from: adaptedRecipe.cookTimeText) ?? recipe.card.cookTimeMinutes,
            publishedDate: nil,
            imageURLString: recipe.card.imageURLString,
            heroImageURLString: recipe.card.heroImageURLString,
            recipeURLString: recipe.card.recipeURLString,
            source: recipe.card.source
        )

        return RecipeAdaptationResponse(
            adaptedRecipe: adaptedRecipe,
            recipeID: adaptedRecipeID,
            adaptedFromRecipeID: recipe.id,
            recipeCard: adaptedCard,
            recipeDetail: adaptedDetail,
            changeSummary: changeSummary ?? preplannedSummary,
            editSummary: editSummary,
            pairingTerms: [],
            styleExamplesUsed: [],
            modelMode: modelMode,
            model: model,
            validationStatus: validationStatus
        )
    }

    private func makeAdaptedDetail(
        from baseDetail: RecipeDetailData,
        adaptedRecipeID: String
    ) -> RecipeDetailData {
        let baseIngredients = baseDetail.ingredients

        let adaptedIngredients = adaptedRecipe.ingredients.enumerated().map { index, line in
            let parsed = Self.parseIngredientLine(line)
            let baseIngredient = Self.bestImageMatch(for: parsed.displayName, in: baseIngredients)

            return RecipeDetailIngredient(
                id: "onboarding-ingredient-\(index)",
                ingredientID: baseIngredient?.ingredientID,
                displayName: parsed.displayName,
                quantityText: parsed.quantityText,
                imageURLString: baseIngredient?.imageURLString ?? Self.commonIngredientImageURLString(for: parsed.displayName),
                sortOrder: index
            )
        }

        let adaptedSteps = adaptedRecipe.steps.enumerated().map { index, text in
            RecipeDetailStep(
                number: index + 1,
                text: text,
                tipText: nil,
                ingredientRefs: Self.matchingIngredientRefs(for: text, ingredients: adaptedIngredients),
                ingredients: []
            )
        }

        let displayServings = baseDetail.displayServings
        return RecipeDetailData(
            id: adaptedRecipeID,
            title: adaptedRecipe.title,
            description: adaptedRecipe.summary,
            authorName: baseDetail.authorName,
            authorHandle: baseDetail.authorHandle,
            authorURLString: baseDetail.authorURLString,
            source: baseDetail.source,
            sourcePlatform: baseDetail.sourcePlatform,
            category: baseDetail.category,
            subcategory: baseDetail.subcategory,
            recipeType: baseDetail.recipeType,
            skillLevel: baseDetail.skillLevel,
            cookTimeText: adaptedRecipe.cookTimeText,
            servingsText: baseDetail.servingsText ?? "\(displayServings) servings",
            servingSizeText: baseDetail.servingSizeText,
            dailyDietText: adaptedRecipe.dietaryFit.first,
            estCostText: baseDetail.estCostText,
            estCaloriesText: baseDetail.estCaloriesText,
            carbsText: baseDetail.carbsText,
            proteinText: baseDetail.proteinText,
            fatsText: baseDetail.fatsText,
            caloriesKcal: baseDetail.caloriesKcal,
            proteinG: baseDetail.proteinG,
            carbsG: baseDetail.carbsG,
            fatG: baseDetail.fatG,
            prepTimeMinutes: baseDetail.prepTimeMinutes,
            cookTimeMinutes: Self.extractCookTimeMinutes(from: adaptedRecipe.cookTimeText) ?? baseDetail.cookTimeMinutes,
            heroImageURLString: baseDetail.heroImageURLString,
            discoverCardImageURLString: baseDetail.discoverCardImageURLString,
            recipeURLString: baseDetail.recipeURLString,
            originalRecipeURLString: baseDetail.originalRecipeURLString,
            attachedVideoURLString: nil,
            detailFootnote: changeSummary ?? preplannedSummary,
            imageCaption: baseDetail.imageCaption,
            dietaryTags: adaptedRecipe.dietaryFit,
            flavorTags: baseDetail.flavorTags,
            cuisineTags: baseDetail.cuisineTags,
            occasionTags: baseDetail.occasionTags,
            mainProtein: baseDetail.mainProtein,
            cookMethod: baseDetail.cookMethod,
            ingredients: adaptedIngredients,
            steps: adaptedSteps,
            servingsCount: baseDetail.servingsCount ?? displayServings
        )
    }

    private static func parseIngredientLine(_ line: String) -> (displayName: String, quantityText: String?) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        let tokens = trimmed.split(separator: " ").map(String.init)
        guard tokens.count >= 2 else {
            return (displayName: trimmed, quantityText: nil)
        }

        let quantityPattern = #"^[0-9¼½¾⅐⅑⅒⅓⅔⅕⅖⅗⅘⅙⅚⅛⅜⅝⅞\/\.-]+$"#
        var quantityTokens: [String] = []
        var ingredientTokens: [String] = []

        for token in tokens {
            if ingredientTokens.isEmpty,
               token.range(of: quantityPattern, options: .regularExpression) != nil
                || [
                    "to", "taste", "cup", "cups", "tbsp", "tablespoon", "tablespoons",
                    "tsp", "teaspoon", "teaspoons", "oz", "ounce", "ounces", "lb", "lbs",
                    "pound", "pounds", "g", "grams", "kg", "whole", "medium", "large",
                    "small", "handful", "handfuls", "straps", "loaf", "loaves", "sticks",
                    "stick", "clove", "cloves", "can", "cans", "bunch", "bunches", "serve",
                    "serving"
                ].contains(token.lowercased()) {
                quantityTokens.append(token)
            } else {
                ingredientTokens.append(token)
            }
        }

        if ingredientTokens.isEmpty {
            return (displayName: trimmed, quantityText: nil)
        }

        let quantityText = quantityTokens.isEmpty ? nil : quantityTokens.joined(separator: " ")
        return (displayName: ingredientTokens.joined(separator: " "), quantityText: quantityText)
    }

    private static func bestImageMatch(
        for displayName: String,
        in ingredients: [RecipeDetailIngredient]
    ) -> RecipeDetailIngredient? {
        let targetName = normalizedName(displayName)
        guard !targetName.isEmpty else { return nil }

        if let exact = ingredients.first(where: { normalizedName($0.displayTitle) == targetName && $0.imageURLString != nil }) {
            return exact
        }

        if let contained = ingredients.first(where: { ingredient in
            guard ingredient.imageURLString != nil else { return false }
            let candidate = normalizedName(ingredient.displayTitle)
            return candidate.count > 3 && (targetName.contains(candidate) || candidate.contains(targetName))
        }) {
            return contained
        }

        let tokens = Set(targetName.split(separator: " ").map(String.init))
            .subtracting(imageMatchStopwords)
        guard !tokens.isEmpty else { return nil }

        return ingredients
            .filter { $0.imageURLString != nil }
            .max { lhs, rhs in
                tokenOverlapScore(tokens: tokens, candidate: lhs.displayTitle) < tokenOverlapScore(tokens: tokens, candidate: rhs.displayTitle)
            }
            .flatMap { candidate in
                tokenOverlapScore(tokens: tokens, candidate: candidate.displayTitle) > 0 ? candidate : nil
            }
    }

    private static let imageMatchStopwords: Set<String> = [
        "fresh", "dried", "ground", "grated", "shredded", "chopped", "sliced",
        "diced", "minced", "large", "small", "medium", "unsalted", "salted",
        "plain", "full", "fat", "low", "reduced", "optional"
    ]

    private static func tokenOverlapScore(tokens: Set<String>, candidate: String) -> Int {
        let candidateTokens = Set(normalizedName(candidate).split(separator: " ").map(String.init))
            .subtracting(imageMatchStopwords)
        return tokens.intersection(candidateTokens).count
    }

    private static func commonIngredientImageURLString(for displayName: String) -> String? {
        let normalized = normalizedName(displayName)
        let mappings: [(keywords: [String], url: String)] = [
            (["yogurt", "coconut milk", "almond milk"], "https://firebasestorage.googleapis.com/v0/b/julienne-3555a.appspot.com/o/ingredients%2Fmilk.jpg?alt=media&token=0dd8a299-f10b-4842-9999-ced50ef93c21?t=1774248091433"),
            (["almond flour", "gluten free flour", "oat flour"], "https://firebasestorage.googleapis.com/v0/b/julienne-3555a.appspot.com/o/ingredients%2Fflour.jpg?alt=media&token=0c58143c-815d-40bb-80cc-9a3b3c34b681?t=1774256493345"),
            (["coconut oil", "avocado oil"], "https://firebasestorage.googleapis.com/v0/b/julienne-3555a.appspot.com/o/ingredients%2Folive_oil.jpg?alt=media&token=c2d859ad-887e-422a-af1a-6d1c2b642fcb?t=1774330870925"),
            (["plant butter"], "https://firebasestorage.googleapis.com/v0/b/julienne-3555a.appspot.com/o/ingredients%2Fbutter.jpg?alt=media&token=0d3b0fec-a623-457d-80a8-3da7db42fdb3?t=1774256492999"),
            (["mozzarella", "ricotta", "cheese"], "https://firebasestorage.googleapis.com/v0/b/julienne-3555a.appspot.com/o/ingredients%2Fparmesan_cheese.jpg?alt=media&token=41595f2d-19cc-4781-ba5b-92c2e1e9a732?t=1774330872651"),
            (["cauliflower rice", "rice"], "https://firebasestorage.googleapis.com/v0/b/julienne-3555a.appspot.com/o/ingredients%2Fpasta.jpg?alt=media&token=909bf7b4-6857-4f70-8ed8-5c6fe087c6c0?t=1774330871011"),
            (["chile", "chili", "pepper", "habanero", "cayenne"], "https://firebasestorage.googleapis.com/v0/b/julienne-3555a.appspot.com/o/ingredients%2Fchili_flakes.jpg?alt=media&token=5e372122-e466-4fac-a826-56f4156b2ec4?t=1774331841546")
        ]
        return mappings.first { entry in
            entry.keywords.contains { normalized.contains($0) }
        }?.url
    }

    private static func matchingIngredientRefs(
        for stepText: String,
        ingredients: [RecipeDetailIngredient]
    ) -> [String] {
        let normalizedStep = normalizedName(stepText)
        return ingredients.compactMap { ingredient in
            let name = ingredient.displayTitle
            let normalizedIngredient = normalizedName(name)
            guard !normalizedIngredient.isEmpty else { return nil }
            return normalizedStep.contains(normalizedIngredient) ? name : nil
        }
    }

    private static func extractCookTimeMinutes(from text: String?) -> Int? {
        guard let text,
              let match = text.range(of: #"\d{1,3}"#, options: .regularExpression)
        else {
            return nil
        }
        return Int(text[match])
    }

    private static func normalizedName(_ value: String) -> String {
        value
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9\\s]", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func intent(for key: String) -> RecipeAlterationIntent? {
        let normalized = key.replacingOccurrences(of: "_", with: "")
        return RecipeAlterationIntent.allCases.first {
            $0.rawValue.lowercased() == normalized.lowercased()
                || $0.intentKey.replacingOccurrences(of: "_", with: "") == normalized.lowercased()
        }
    }

    static func dairyFreeFixture(
        for recipe: OnboardingRecipeEditDemoRecipe
    ) -> OnboardingRecipeEditDemoOptionFixture? {
        switch recipe.id {
        case "cdf56b03-71e8-4386-acb1-262837286a36":
            let summary = "Swapped the dairy base for coconut milk and dairy-free cream cheese while keeping the berry bake format."
            return OnboardingRecipeEditDemoOptionFixture(
                recipeID: recipe.id,
                intent: .dairyFree,
                preplannedSummary: summary,
                adaptedRecipe: RecipeAdaptationRecipe(
                    title: "Dairy-Free Berries & Cream French Toast Bake",
                    summary: "A creamy berry French toast bake built with coconut milk and dairy-free cream cheese, so it still feels custardy without using dairy.",
                    cookTimeText: "50 mins",
                    ingredients: [
                        "1 loaf dairy-free challah or thick white bread, cubed",
                        "1 1/2 cups full-fat coconut milk",
                        "1/2 cup dairy-free cream cheese",
                        "6 large eggs",
                        "2 cups mixed berries",
                        "2 tbsp maple syrup",
                        "1 tsp vanilla extract",
                        "1/2 tsp lemon zest",
                        "1/4 tsp kosher salt"
                    ],
                    steps: [
                        "Grease a baking dish and spread the cubed dairy-free bread across the bottom.",
                        "Whisk coconut milk, eggs, maple syrup, vanilla, lemon zest, and salt until smooth.",
                        "Dot the bread with dairy-free cream cheese, scatter the berries over top, and pour the custard evenly over everything.",
                        "Let the bake sit for 10 minutes so the bread absorbs the custard, then bake at 350 degrees F until puffed and set, about 35 to 40 minutes.",
                        "Rest for 5 minutes before serving so the dairy-free custard slices cleanly."
                    ],
                    substitutions: [
                        "Coconut milk replaces dairy milk or cream.",
                        "Dairy-free cream cheese replaces regular cream cheese."
                    ],
                    pairingNotes: [
                        "Serve with extra berries.",
                        "Add toasted coconut for crunch."
                    ],
                    dietaryFit: ["Dairy-Free", "Breakfast"]
                ),
                changeSummary: summary
            )
        case "eaa85ffd-1a66-44e9-84e7-2c7d4b950390":
            let summary = "Removed Parmesan and used nutritional yeast plus pasta water for a savory, dairy-free sauce."
            return OnboardingRecipeEditDemoOptionFixture(
                recipeID: recipe.id,
                intent: .dairyFree,
                preplannedSummary: summary,
                adaptedRecipe: RecipeAdaptationRecipe(
                    title: "Dairy-Free Spinach One-Pot Pasta",
                    summary: "A savory spinach pasta that keeps the one-pot flow and swaps Parmesan for nutritional yeast, lemon, and starchy pasta water.",
                    cookTimeText: "25 mins",
                    ingredients: [
                        "12 oz short pasta",
                        "5 oz spinach",
                        "2 tbsp olive oil",
                        "3 fillets anchovies",
                        "3 tbsp nutritional yeast",
                        "1 lemon, zested and juiced",
                        "1/2 tsp red-pepper flakes",
                        "Salt"
                    ],
                    steps: [
                        "Boil the pasta in salted water until just shy of al dente, reserving 1 cup of pasta water before draining.",
                        "Warm olive oil with anchovies and red-pepper flakes until the anchovies melt into the oil.",
                        "Add spinach and cook until wilted, then stir in the pasta.",
                        "Add nutritional yeast, lemon zest, lemon juice, and enough pasta water to make a glossy sauce.",
                        "Taste, season with salt, and serve while the sauce is loose and silky."
                    ],
                    substitutions: [
                        "Nutritional yeast replaces Parmesan.",
                        "Reserved pasta water builds the creamy texture without dairy."
                    ],
                    pairingNotes: [
                        "Serve with a crisp green salad.",
                        "Add grilled chicken if you want more protein."
                    ],
                    dietaryFit: ["Dairy-Free", "Dinner"]
                ),
                changeSummary: summary
            )
        case "4bcf072c-b95d-49fa-9997-d2749a118a15":
            let summary = "Replaced butter with plant butter and a little coconut oil while keeping the guava-lemon filling bright."
            return OnboardingRecipeEditDemoOptionFixture(
                recipeID: recipe.id,
                intent: .dairyFree,
                preplannedSummary: summary,
                adaptedRecipe: RecipeAdaptationRecipe(
                    title: "Dairy-Free Guava Lemon Bars",
                    summary: "Bright guava lemon bars with a tender dairy-free crust made from plant butter and coconut oil.",
                    cookTimeText: "55 mins",
                    ingredients: [
                        "1 1/2 cups all-purpose flour",
                        "1/2 cup plant butter, cold and cubed",
                        "2 tbsp coconut oil",
                        "3/4 cup granulated sugar",
                        "3 large eggs",
                        "1/2 cup lemon juice",
                        "1 tbsp lemon zest",
                        "3/4 cup guava paste, softened",
                        "1/4 tsp kosher salt"
                    ],
                    steps: [
                        "Pulse flour, plant butter, coconut oil, 1/4 cup sugar, and salt until crumbly, then press into a lined baking pan.",
                        "Bake the crust at 350 degrees F until lightly golden, about 18 minutes.",
                        "Whisk eggs, remaining sugar, lemon juice, lemon zest, and softened guava paste until smooth.",
                        "Pour the filling over the hot crust and bake until the center is just set, about 22 to 25 minutes.",
                        "Cool completely before slicing so the dairy-free crust holds clean edges."
                    ],
                    substitutions: [
                        "Plant butter and coconut oil replace dairy butter."
                    ],
                    pairingNotes: [
                        "Chill before slicing for the neatest bars.",
                        "Serve with fresh berries."
                    ],
                    dietaryFit: ["Dairy-Free", "Dessert"]
                ),
                changeSummary: summary
            )
        default:
            return nil
        }
    }

    static func healthyFixture(
        for recipe: OnboardingRecipeEditDemoRecipe
    ) -> OnboardingRecipeEditDemoOptionFixture? {
        guard recipe.id == "cdf56b03-71e8-4386-acb1-262837286a36" else {
            return nil
        }

        let summary = "Made the bake more balanced with whole-grain bread, Greek yogurt, extra berries, and less added sugar."
        return OnboardingRecipeEditDemoOptionFixture(
            recipeID: recipe.id,
            intent: .healthier,
            preplannedSummary: summary,
            adaptedRecipe: RecipeAdaptationRecipe(
                title: "Healthy Berries & Cream French Toast Bake",
                summary: "A lighter, higher-protein French toast bake with whole-grain bread, Greek yogurt, and extra berries for natural sweetness.",
                cookTimeText: "50 mins",
                ingredients: [
                    "1 loaf whole-grain bread, cubed",
                    "1 cup plain Greek yogurt",
                    "3/4 cup low-fat milk",
                    "6 large eggs",
                    "2 1/2 cups mixed berries",
                    "1 tbsp maple syrup",
                    "1 tsp vanilla extract",
                    "1/2 tsp cinnamon",
                    "1/4 tsp kosher salt"
                ],
                steps: [
                    "Grease a baking dish and spread the cubed whole-grain bread across the bottom.",
                    "Whisk Greek yogurt, milk, eggs, maple syrup, vanilla, cinnamon, and salt until smooth.",
                    "Fold most of the berries into the bread, then pour the custard evenly over the top.",
                    "Rest for 10 minutes so the bread absorbs the custard, then scatter the remaining berries over the surface.",
                    "Bake at 350 degrees F until puffed, golden, and set in the center, about 35 to 40 minutes."
                ],
                substitutions: [
                    "Whole-grain bread replaces richer white bread.",
                    "Greek yogurt adds protein and creaminess with less sugar.",
                    "Extra berries replace most of the added sugar."
                ],
                pairingNotes: [
                    "Serve with fresh berries.",
                    "Add chopped nuts for more crunch."
                ],
                dietaryFit: ["High-Protein", "Balanced", "Breakfast"]
            ),
            changeSummary: summary
        )
    }
}

actor OnboardingRecipeEditDemoService {
    static let shared = OnboardingRecipeEditDemoService()

    private var cachedRecipes: [OnboardingRecipeEditDemoRecipe]?

    func loadRecipes(forceRefresh: Bool = false) async -> [OnboardingRecipeEditDemoRecipe] {
        if !forceRefresh, let cachedRecipes {
            return cachedRecipes
        }

        guard let catalog = loadCatalog() else {
            return []
        }

        let fixturesByRecipeID = Dictionary(grouping: catalog.fixtures, by: \.recipeID)
        let resolvedRecipes = catalog.baseRecipes
            .map { baseRecipe in
                baseRecipe.makeRecipe(
                    fixtures: Self.orderedFixtures(
                        for: baseRecipe.id,
                        fixtures: fixturesByRecipeID[baseRecipe.id] ?? []
                    )
                )
            }
            .sorted { lhs, rhs in
                Self.recipeOrderIndex(for: lhs.id) < Self.recipeOrderIndex(for: rhs.id)
            }

        cachedRecipes = resolvedRecipes
        return resolvedRecipes
    }

    private func loadCatalog() -> OnboardingRecipeEditDemoCatalogResource? {
        guard let url = Bundle.main.url(forResource: "OnboardingRecipeEditDemoCatalog", withExtension: "json"),
              let data = try? Data(contentsOf: url)
        else {
            return nil
        }

        return try? JSONDecoder().decode(OnboardingRecipeEditDemoCatalogResource.self, from: data)
    }

    private static func orderedFixtures(
        for recipeID: String,
        fixtures: [OnboardingRecipeEditDemoOptionFixture]
    ) -> [OnboardingRecipeEditDemoOptionFixture] {
        let preferredOrder = fixtureIntentOrderByRecipeID[recipeID] ?? []
        let orderIndexByIntent = Dictionary(uniqueKeysWithValues: preferredOrder.enumerated().map { ($1, $0) })
        return fixtures.sorted { lhs, rhs in
            let lhsIndex = orderIndexByIntent[lhs.intent] ?? Int.max
            let rhsIndex = orderIndexByIntent[rhs.intent] ?? Int.max
            if lhsIndex != rhsIndex {
                return lhsIndex < rhsIndex
            }
            return lhs.intent.rawValue < rhs.intent.rawValue
        }
    }

    private static func recipeOrderIndex(for recipeID: String) -> Int {
        baseRecipeOrder.firstIndex(of: recipeID) ?? Int.max
    }

    private static let baseRecipeOrder = [
        "cdf56b03-71e8-4386-acb1-262837286a36",
        "b1bd5a95-dab3-436e-89c8-fb4df52b8fb7",
        "eaa85ffd-1a66-44e9-84e7-2c7d4b950390",
        "4bcf072c-b95d-49fa-9997-d2749a118a15",
    ]

    private static let fixtureIntentOrderByRecipeID: [String: [RecipeAlterationIntent]] = [
        "cdf56b03-71e8-4386-acb1-262837286a36": [.moreProtein, .lessSugar, .quick],
        "b1bd5a95-dab3-436e-89c8-fb4df52b8fb7": [.moreProtein, .spicy, .mealPrep],
        "eaa85ffd-1a66-44e9-84e7-2c7d4b950390": [.moreProtein, .keto, .lighter],
        "4bcf072c-b95d-49fa-9997-d2749a118a15": [.lessSugar, .glutenFree, .lighter],
    ]
}

private struct OnboardingRecipeEditDemoCatalogResource: Decodable {
    let baseRecipes: [OnboardingRecipeEditDemoBaseRecipePayload]
    let fixtures: [OnboardingRecipeEditDemoOptionFixture]

    enum CodingKeys: String, CodingKey {
        case baseRecipes = "base_recipes"
        case fixtures
    }
}

private struct OnboardingRecipeEditDemoBaseRecipePayload: Decodable {
    let id: String
    let title: String
    let description: String
    let authorName: String?
    let authorHandle: String?
    let source: String?
    let category: String?
    let recipeType: String?
    let cookTimeText: String?
    let cookTimeMinutes: Int?
    let heroImageURLString: String?
    let discoverCardImageURLString: String?
    let recipeURLString: String?
    let originalRecipeURLString: String?
    let dietaryTags: [String]
    let flavorTags: [String]
    let cuisineTags: [String]
    let occasionTags: [String]
    let ingredients: [OnboardingRecipeEditDemoIngredientPayload]
    let steps: [OnboardingRecipeEditDemoStepPayload]
    let servingsCount: Int?

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case description
        case authorName = "author_name"
        case authorHandle = "author_handle"
        case source
        case category
        case recipeType = "recipe_type"
        case cookTimeText = "cook_time_text"
        case cookTimeMinutes = "cook_time_minutes"
        case heroImageURLString = "hero_image_url"
        case discoverCardImageURLString = "discover_card_image_url"
        case recipeURLString = "recipe_url"
        case originalRecipeURLString = "original_recipe_url"
        case dietaryTags = "dietary_tags"
        case flavorTags = "flavor_tags"
        case cuisineTags = "cuisine_tags"
        case occasionTags = "occasion_tags"
        case ingredients
        case steps
        case servingsCount = "servings_count"
    }

    func makeRecipe(fixtures: [OnboardingRecipeEditDemoOptionFixture]) -> OnboardingRecipeEditDemoRecipe {
        let card = DiscoverRecipeCardData(
            id: id,
            title: title,
            description: description,
            authorName: authorName,
            authorHandle: authorHandle,
            category: category,
            recipeType: recipeType,
            cookTimeText: cookTimeText,
            cookTimeMinutes: cookTimeMinutes,
            publishedDate: nil,
            imageURLString: discoverCardImageURLString,
            heroImageURLString: heroImageURLString,
            recipeURLString: recipeURLString,
            source: source
        )

        let detailIngredients = ingredients.enumerated().map { index, ingredient in
            RecipeDetailIngredient(
                id: "fallback-ingredient-\(id)-\(index)",
                ingredientID: nil,
                displayName: ingredient.displayName,
                quantityText: ingredient.quantityText,
                imageURLString: ingredient.imageURLString,
                sortOrder: index
            )
        }
        let ingredientByName = Dictionary(uniqueKeysWithValues: detailIngredients.map {
            ($0.displayTitle.lowercased(), $0)
        })
        let detailSteps = steps.map { step in
            RecipeDetailStep(
                number: step.number,
                text: step.text,
                tipText: nil,
                ingredientRefs: step.ingredientRefs,
                ingredients: step.ingredientRefs.compactMap { ingredientByName[$0.lowercased()] }
            )
        }

        let detail = RecipeDetailData(
            id: id,
            title: title,
            description: description,
            authorName: authorName,
            authorHandle: authorHandle,
            authorURLString: nil,
            source: source,
            sourcePlatform: source,
            category: category,
            subcategory: nil,
            recipeType: recipeType,
            skillLevel: nil,
            cookTimeText: cookTimeText,
            servingsText: servingsCount.map { "\($0) servings" },
            servingSizeText: nil,
            dailyDietText: dietaryTags.first,
            estCostText: nil,
            estCaloriesText: nil,
            carbsText: nil,
            proteinText: nil,
            fatsText: nil,
            caloriesKcal: nil,
            proteinG: nil,
            carbsG: nil,
            fatG: nil,
            prepTimeMinutes: nil,
            cookTimeMinutes: cookTimeMinutes,
            heroImageURLString: heroImageURLString,
            discoverCardImageURLString: discoverCardImageURLString,
            recipeURLString: recipeURLString,
            originalRecipeURLString: originalRecipeURLString,
            attachedVideoURLString: nil,
            detailFootnote: nil,
            imageCaption: nil,
            dietaryTags: dietaryTags,
            flavorTags: flavorTags,
            cuisineTags: cuisineTags,
            occasionTags: occasionTags,
            mainProtein: nil,
            cookMethod: nil,
            ingredients: detailIngredients,
            steps: detailSteps,
            servingsCount: servingsCount
        )

        return OnboardingRecipeEditDemoRecipe(
            card: card,
            detail: detail,
            optionFixtures: fixtures
        )
    }

    func applyingDemoOverrides(to liveDetail: RecipeDetailData) -> RecipeDetailData {
        RecipeDetailData(
            id: liveDetail.id,
            title: liveDetail.title,
            description: liveDetail.description,
            authorName: liveDetail.authorName,
            authorHandle: liveDetail.authorHandle,
            authorURLString: liveDetail.authorURLString,
            source: source ?? liveDetail.source,
            sourcePlatform: liveDetail.sourcePlatform ?? source ?? liveDetail.source,
            category: category ?? liveDetail.category,
            subcategory: liveDetail.subcategory,
            recipeType: recipeType ?? liveDetail.recipeType,
            skillLevel: liveDetail.skillLevel,
            cookTimeText: cookTimeText ?? liveDetail.cookTimeText,
            servingsText: liveDetail.servingsText,
            servingSizeText: liveDetail.servingSizeText,
            dailyDietText: liveDetail.dailyDietText,
            estCostText: liveDetail.estCostText,
            estCaloriesText: liveDetail.estCaloriesText,
            carbsText: liveDetail.carbsText,
            proteinText: liveDetail.proteinText,
            fatsText: liveDetail.fatsText,
            caloriesKcal: liveDetail.caloriesKcal,
            proteinG: liveDetail.proteinG,
            carbsG: liveDetail.carbsG,
            fatG: liveDetail.fatG,
            prepTimeMinutes: liveDetail.prepTimeMinutes,
            cookTimeMinutes: cookTimeMinutes ?? liveDetail.cookTimeMinutes,
            heroImageURLString: heroImageURLString ?? liveDetail.heroImageURLString,
            discoverCardImageURLString: discoverCardImageURLString ?? liveDetail.discoverCardImageURLString,
            recipeURLString: recipeURLString ?? liveDetail.recipeURLString,
            originalRecipeURLString: originalRecipeURLString ?? liveDetail.originalRecipeURLString,
            attachedVideoURLString: liveDetail.attachedVideoURLString,
            detailFootnote: liveDetail.detailFootnote,
            imageCaption: liveDetail.imageCaption,
            dietaryTags: liveDetail.dietaryTags,
            flavorTags: liveDetail.flavorTags,
            cuisineTags: liveDetail.cuisineTags,
            occasionTags: liveDetail.occasionTags,
            mainProtein: liveDetail.mainProtein,
            cookMethod: liveDetail.cookMethod,
            ingredients: liveDetail.ingredients,
            steps: liveDetail.steps,
            servingsCount: liveDetail.servingsCount
        )
    }
}

private struct OnboardingRecipeEditDemoIngredientPayload: Decodable {
    let displayName: String
    let quantityText: String?
    let imageURLString: String?

    enum CodingKeys: String, CodingKey {
        case displayName = "display_name"
        case quantityText = "quantity_text"
        case imageURLString = "image_url"
    }
}

private struct OnboardingRecipeEditDemoStepPayload: Decodable {
    let number: Int
    let text: String
    let ingredientRefs: [String]

    enum CodingKeys: String, CodingKey {
        case number
        case text
        case ingredientRefs = "ingredient_refs"
    }
}
