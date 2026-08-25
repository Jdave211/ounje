import Foundation

struct OnboardingRecipeEditDemoRecipe: Identifiable {
    let card: DiscoverRecipeCardData
    let detail: RecipeDetailData
    let optionFixtures: [OnboardingRecipeEditDemoOptionFixture]

    var id: String { card.id }

    func resolvedOptionFixtures(
        selectedDietaryPatterns: Set<String>
    ) -> [OnboardingRecipeEditDemoOptionFixture] {
        let preferredFixtures = preferredIntentOrder.compactMap { preferredIntent in
            optionFixtures.first(where: { $0.intent == preferredIntent })
        }
        let orderedFixtures = preferredFixtures + optionFixtures.filter { fixture in
            !preferredIntentOrder.contains(fixture.intent)
        }
        let selectedDiets = Set(selectedDietaryPatterns.map(Self.normalizedDietName))
        guard !selectedDiets.isEmpty else {
            return Array(orderedFixtures.prefix(4))
        }

        let dietFixtures = dietFixturePriority.compactMap { entry -> OnboardingRecipeEditDemoOptionFixture? in
            let diet = entry.diet
            let intent = entry.intent
            guard selectedDiets.contains(diet) else { return nil }
            return optionFixtures.first(where: { $0.intent == intent })
        }

        var seenIntents = Set<String>()
        let prioritizedFixtures = (dietFixtures + orderedFixtures).filter { fixture in
            guard !seenIntents.contains(fixture.intent.rawValue) else { return false }
            seenIntents.insert(fixture.intent.rawValue)
            return true
        }

        return Array(prioritizedFixtures.prefix(4))
    }

    fileprivate var allDemoFixtures: [OnboardingRecipeEditDemoOptionFixture] {
        optionFixtures
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

    private var preferredIntentOrder: [RecipeAlterationIntent] {
        switch card.id {
        case "c3a7bd77-6894-4069-9113-149c0adf71d4":
            return [.lessSugar, .lowCalories, .moreProtein, .dairyFree]
        case "e2c0da0d-047c-440b-b96d-a5730f403072":
            return [.lessSugar, .lowCalories, .moreProtein, .spicy]
        default:
            return [.healthier, .moreProtein, .lowCalories, .mealPrep]
        }
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
        changeSummary ?? preplannedSummary
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
                imageURLString: Self.commonIngredientImageURLString(for: parsed.displayName) ?? baseIngredient?.imageURLString,
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
            // Macros follow the selected inspiration: an explicit per-variant macro wins
            // (curated fixtures), otherwise the intent transforms the base macro so e.g.
            // "More protein" raises protein and "Lighter"/"Low calories" lowers kcal.
            caloriesKcal: adaptedRecipe.caloriesKcal ?? intent.adaptedMacro(baseDetail.caloriesKcal, \.calories, minimum: 1),
            proteinG: adaptedRecipe.proteinG ?? intent.adaptedMacro(baseDetail.proteinG, \.protein),
            carbsG: adaptedRecipe.carbsG ?? intent.adaptedMacro(baseDetail.carbsG, \.carbs),
            fatG: adaptedRecipe.fatG ?? intent.adaptedMacro(baseDetail.fatG, \.fat),
            prepTimeMinutes: baseDetail.prepTimeMinutes,
            cookTimeMinutes: Self.extractCookTimeMinutes(from: adaptedRecipe.cookTimeText) ?? baseDetail.cookTimeMinutes,
            heroImageURLString: baseDetail.heroImageURLString,
            discoverCardImageURLString: baseDetail.discoverCardImageURLString,
            recipeURLString: baseDetail.recipeURLString,
            originalRecipeURLString: baseDetail.originalRecipeURLString,
            attachedVideoURLString: nil,
            sourceProvenance: baseDetail.sourceProvenance,
            detailFootnote: nil,
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

    fileprivate static func commonIngredientImageURLString(for displayName: String) -> String? {
        let normalized = normalizedName(displayName)
        let mappings: [(keywords: [String], imageName: String)] = [
            (["boneless skinless chicken breast", "skinless chicken breast", "chicken breast"], "chicken_breast"),
            (["boneless skinless chicken thigh", "boneless chicken thigh"], "boneless_skinless_chicken_thigh"),
            (["skinless chicken thigh", "chicken thigh", "chicken leg"], "chicken_thigh"),
            (["chicken stock", "chicken broth", "bouillon"], "chicken_broth"),
            (["jollof tomato base", "tomato base", "tomato sauce"], "tomato_sauce"),
            (["peri peri sauce", "peri-peri sauce", "hot sauce"], "hot_sauce"),
            (["biscoff cookies", "biscoff cookie"], "biscuits"),
            (["biscoff spread"], "caramel_sauce"),
            (["all purpose flour", "all-purpose flour", "gluten free flour", "almond flour", "oat flour", "protein powder", "flour"], "flour"),
            (["baking powder"], "baking_powder"),
            (["baking soda"], "baking_soda"),
            (["brown sugar", "light brown sugar"], "brown_sugar"),
            (["powdered sugar"], "powdered_sugar"),
            (["egg white", "egg yolk", "hard boiled egg", "egg", "eggs"], "egg"),
            (["greek yogurt", "nonfat greek yogurt", "plain yogurt", "yogurt"], "greek_yogurt"),
            (["condensed milk"], "condensed_milk"),
            (["half and half", "half-and-half", "heavy cream", "whipping cream"], "heavy_cream"),
            (["buttermilk"], "buttermilk"),
            (["oat milk", "almond milk", "low fat milk", "milk"], "milk"),
            (["unsalted butter", "plant butter", "butter"], "butter"),
            (["vegetable oil"], "vegetable_oil"),
            (["coconut oil"], "coconut_oil"),
            (["avocado oil"], "avocado_oil"),
            (["extra virgin olive oil", "olive oil", "frying oil", "neutral oil", "oil"], "olive_oil"),
            (["lemon juice", "lemon zest", "lemon"], "lemon"),
            (["lime juice", "lime"], "lime"),
            (["watermelon"], "watermelon"),
            (["banana", "bananas"], "bananas"),
            (["potato chips", "oven chips", "potato", "potatoes"], "potatoes"),
            (["cauliflower rice"], "cauliflower"),
            (["white rice", "cooked rice", "rice"], "rice"),
            (["red bell pepper"], "red_bell_pepper"),
            (["green bell pepper"], "green_bell_pepper"),
            (["bell pepper"], "red_bell_pepper"),
            (["habanero pepper", "habanero", "red chilies", "red chilis", "chili pepper"], "chili_peppers"),
            (["chili powder", "chilli powder"], "chilli_powder"),
            (["chili flakes", "chilli flakes", "red pepper flakes"], "chili_flakes"),
            (["cayenne"], "cayenne"),
            (["smoked paprika", "paprika"], "paprika"),
            (["white pepper", "black pepper", "pepper"], "black_pepper"),
            (["garlic powder", "garlic granules"], "garlic_powder"),
            (["garlic paste", "garlic cloves", "garlic clove", "garlic"], "garlic"),
            (["red onion"], "red_onion"),
            (["white onion", "onion", "onions"], "onion"),
            (["courgette", "courgettes", "zucchini"], "courgettes"),
            (["carrot", "carrots"], "carrot"),
            (["frozen peas", "peas"], "peas"),
            (["baby spinach", "spinach"], "spinach"),
            (["fresh ginger", "ginger"], "ginger"),
            (["fresh mint", "mint"], "mint"),
            (["chia seeds", "chia"], "chia_seeds"),
            (["dried oregano", "oregano"], "oregano"),
            (["ground cumin", "cumin"], "cumin"),
            (["curry powder"], "yellow_curry"),
            (["bay leaves", "bay leaf"], "bay_leaf"),
            (["thyme"], "thyme"),
            (["cinnamon"], "cinnamon"),
            (["vanilla extract", "vanilla"], "vanilla_extract"),
            (["sugar"], "sugar"),
            (["salt"], "salt"),
            (["ice"], "ice"),
            (["water"], "water"),
            (["tomato", "tomatoes"], "tomato"),
            (["plantain", "plantains"], "plantain"),
            (["black beans"], "black_beans"),
            (["mozzarella"], "mozzarella"),
            (["ricotta"], "ricotta_cheese"),
            (["cheese"], "parmesan_cheese")
        ]
        guard let imageName = mappings.first(where: { entry in
            entry.keywords.contains { normalized.contains($0) }
        })?.imageName else {
            return nil
        }

        return "https://firebasestorage.googleapis.com/v0/b/julienne-3555a.appspot.com/o/ingredients%2F\(imageName).jpg?alt=media"
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

    static func lowCaloriesFixture(
        for recipe: OnboardingRecipeEditDemoRecipe
    ) -> OnboardingRecipeEditDemoOptionFixture? {
        switch recipe.id {
        case "cdf56b03-71e8-4386-acb1-262837286a36":
            let summary = "Kept the berry French toast bake custardy, but reduced the sweetened cream-cheese layer, used Greek yogurt for body, and cut the added sugar."
            return OnboardingRecipeEditDemoOptionFixture(
                recipeID: recipe.id,
                intent: .lowCalories,
                preplannedSummary: summary,
                adaptedRecipe: RecipeAdaptationRecipe(
                    title: "Lower-Calorie Berries & Cream French Toast Bake",
                    summary: "A lighter berry French toast bake that still has a creamy custard center, using Greek yogurt, light cream cheese, more berries, and less added sugar.",
                    cookTimeText: "50 mins",
                    ingredients: [
                        "12 oz French bread, cubed",
                        "1/2 cup light cream cheese",
                        "1/2 cup plain nonfat Greek yogurt",
                        "2 tbsp powdered sugar",
                        "2 1/2 cups mixed berries",
                        "6 large eggs",
                        "1 1/2 cups low-fat milk",
                        "1 tsp vanilla extract",
                        "1 1/2 tsp cinnamon",
                        "1/2 tsp kosher salt",
                        "1 tbsp maple syrup, optional for serving"
                    ],
                    steps: [
                        "Grease a baking dish and spread the cubed French bread across the bottom.",
                        "Beat the light cream cheese, Greek yogurt, and powdered sugar until creamy but still tangy.",
                        "Dollop the yogurt-cream cheese mixture over the bread, then scatter the mixed berries through the dish.",
                        "Whisk eggs, low-fat milk, vanilla, cinnamon, and salt until smooth, then pour the custard evenly over the bread.",
                        "Rest for 15 minutes so the bread absorbs the custard.",
                        "Bake at 375 degrees F until puffed, golden, and set in the center, about 35 to 40 minutes.",
                        "Serve warm with a light drizzle of maple syrup if you want extra sweetness."
                    ],
                    substitutions: [
                        "Light cream cheese and Greek yogurt replace most of the full-fat cream cheese.",
                        "Extra berries and cinnamon carry sweetness so the sugar can come down.",
                        "Low-fat milk keeps the custard texture with fewer calories."
                    ],
                    pairingNotes: [
                        "Serve with extra fresh berries instead of syrup.",
                        "Add lemon zest if you want more brightness without more sugar."
                    ],
                    dietaryFit: ["Lower-Calorie", "Breakfast", "Balanced"]
                ),
                changeSummary: summary
            )
        case "b1bd5a95-dab3-436e-89c8-fb4df52b8fb7":
            let summary = "Kept the tomato-pepper stew, rice, and plantain, but trimmed the oil, used skinless chicken, reduced the rice portion, and air-fried the plantain."
            return OnboardingRecipeEditDemoOptionFixture(
                recipeID: recipe.id,
                intent: .lowCalories,
                preplannedSummary: summary,
                adaptedRecipe: RecipeAdaptationRecipe(
                    title: "Lower-Calorie Nigerian Rice & Chicken Stew",
                    summary: "The same peppery chicken stew plate, made lighter with skinless chicken, less oil, a smaller rice base, and sweet plantain crisped without deep frying.",
                    cookTimeText: "60 mins",
                    ingredients: [
                        "1 1/2 lbs skinless chicken thighs",
                        "3 tomatoes",
                        "1 red bell pepper",
                        "1 habanero pepper",
                        "1 large onion, divided",
                        "2 tbsp olive oil",
                        "1 cup low-sodium chicken stock",
                        "1 tsp bouillon powder",
                        "1/2 tsp thyme",
                        "1/2 tsp curry powder",
                        "1/2 tsp black pepper, plus more to taste",
                        "1/2 tsp kosher salt, plus more to taste",
                        "2 cups uncooked white rice",
                        "4 cups water",
                        "1 ripe plantain, sliced",
                        "1 tsp neutral oil or oil spray"
                    ],
                    steps: [
                        "Season the skinless chicken thighs with salt and black pepper.",
                        "Blend tomatoes, red bell pepper, habanero, and half the onion until smooth.",
                        "Heat olive oil in a wide pot, brown the chicken lightly on both sides, then set it aside.",
                        "Saute the remaining chopped onion in the same pot until softened.",
                        "Pour in the blended pepper mixture and cook it down for 8 to 10 minutes so the stew tastes concentrated without needing extra oil.",
                        "Add chicken stock, bouillon powder, thyme, curry powder, and black pepper, then return the chicken to the sauce.",
                        "Simmer until the chicken is cooked through and the stew thickens, about 20 minutes; adjust salt to taste.",
                        "Cook the rice in water until tender, then fluff and portion it as a smaller base for the stew.",
                        "Toss plantain slices with 1 tsp oil or spray lightly, then air-fry or bake at 400 degrees F until golden, about 10 to 14 minutes.",
                        "Serve the stew over rice with the crisp plantain on the side."
                    ],
                    substitutions: [
                        "Skinless chicken thighs keep the stew juicy with less fat.",
                        "Two tablespoons of oil replace the heavier stew oil base.",
                        "Air-fried plantain keeps the sweet side without deep frying.",
                        "A smaller rice base keeps the full plate recognizable while lowering calories."
                    ],
                    pairingNotes: [
                        "Add steamed cabbage or cucumber salad if you want more volume.",
                        "Keep extra stew sauce for reheating instead of adding more oil."
                    ],
                    dietaryFit: ["Lower-Calorie", "Dinner", "West African"]
                ),
                changeSummary: summary
            )
        case "eaa85ffd-1a66-44e9-84e7-2c7d4b950390":
            let summary = "Kept the one-pot anchovy, lemon, spinach, and Parmesan profile, but used less pasta and oil, more spinach, and pasta water for body."
            return OnboardingRecipeEditDemoOptionFixture(
                recipeID: recipe.id,
                intent: .lowCalories,
                preplannedSummary: summary,
                adaptedRecipe: RecipeAdaptationRecipe(
                    title: "Lower-Calorie Spinach One-Pot Pasta",
                    summary: "A lighter version of the same salty, lemony spinach pasta, with more greens, less pasta, less oil, and just enough Parmesan to keep the sauce savory.",
                    cookTimeText: "25 mins",
                    ingredients: [
                        "8 oz short-shaped pasta",
                        "20 oz mature spinach",
                        "1 tbsp olive oil",
                        "4 anchovy fillets",
                        "5 tbsp grated Parmesan",
                        "1/4 tsp red-pepper flakes",
                        "1 lemon, zested and juiced",
                        "Salt",
                        "3/4 cup reserved pasta water"
                    ],
                    steps: [
                        "Bring a large pot of salted water to a boil and cook the pasta until just shy of al dente.",
                        "Reserve 3/4 cup pasta water, then drain the pasta over the spinach in a colander so the greens start to wilt.",
                        "Return the pot to medium heat and warm 1 tbsp olive oil with the anchovies and red-pepper flakes until the anchovies melt into the oil.",
                        "Add the pasta and spinach back to the pot with 1/2 cup reserved pasta water.",
                        "Stir in Parmesan, lemon zest, and lemon juice until the sauce turns glossy, adding more pasta water as needed.",
                        "Taste and adjust with salt, lemon, or red-pepper flakes before serving."
                    ],
                    substitutions: [
                        "Eight ounces of pasta replaces twelve ounces while extra spinach keeps the bowl full.",
                        "One tablespoon of oil replaces two because anchovies, lemon, and pasta water carry the sauce.",
                        "A smaller amount of Parmesan keeps the savory finish without making the dish heavy."
                    ],
                    pairingNotes: [
                        "Serve with a tomato-cucumber salad for freshness.",
                        "Add grilled shrimp if you want more protein without making it heavy."
                    ],
                    dietaryFit: ["Lower-Calorie", "Dinner", "Quick"]
                ),
                changeSummary: summary
            )
        case "4bcf072c-b95d-49fa-9997-d2749a118a15":
            let summary = "Preserved the buttery bar format and guava-lemon flavor, but made a thinner crust, cut sugar, and boosted lemon so the filling still tastes bright."
            return OnboardingRecipeEditDemoOptionFixture(
                recipeID: recipe.id,
                intent: .lowCalories,
                preplannedSummary: summary,
                adaptedRecipe: RecipeAdaptationRecipe(
                    title: "Lower-Calorie Guava Lemon Bars",
                    summary: "A brighter, lighter guava lemon bar with a thinner shortbread crust, less butter and sugar, and enough guava to keep the tropical flavor.",
                    cookTimeText: "55 mins",
                    ingredients: [
                        "1 1/2 cups all-purpose flour",
                        "6 tbsp powdered sugar, divided",
                        "1/4 tsp kosher salt",
                        "6 tbsp cold unsalted butter, cubed",
                        "1 tbsp cold water, if needed",
                        "4 large eggs",
                        "2/3 cup granulated sugar",
                        "1 tbsp lemon zest",
                        "1/2 cup lemon juice",
                        "1/2 cup guava puree",
                        "1 tbsp all-purpose flour"
                    ],
                    steps: [
                        "Preheat the oven to 350 degrees F and line a 9x13-inch baking dish with parchment.",
                        "Whisk 1 1/2 cups flour, 3 tbsp powdered sugar, and salt in a bowl.",
                        "Cut in the cold butter until the mixture looks sandy, adding 1 tbsp cold water only if needed to help it hold together.",
                        "Press the thinner crust evenly into the pan and bake until lightly golden, about 18 to 20 minutes.",
                        "Whisk eggs, granulated sugar, lemon zest, lemon juice, guava puree, and 1 tbsp flour until smooth.",
                        "Pour the filling over the hot crust and bake until just set, about 22 to 25 minutes.",
                        "Cool completely, chill for clean slices, then dust with the remaining powdered sugar only if desired."
                    ],
                    substitutions: [
                        "A thinner crust uses less flour and butter while keeping the shortbread bite.",
                        "Less granulated sugar is balanced with more lemon juice and zest.",
                        "Guava puree stays in the filling so the dessert still tastes like guava lemon bars."
                    ],
                    pairingNotes: [
                        "Cut into smaller squares for a brighter sweet bite.",
                        "Serve chilled so the lighter filling sets cleanly."
                    ],
                    dietaryFit: ["Lower-Calorie", "Dessert", "Citrus"]
                ),
                changeSummary: summary
            )
        default:
            return nil
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

    static let preloadedRecipes: [OnboardingRecipeEditDemoRecipe] = importedRecipeCards.map { card in
        OnboardingRecipeEditDemoRecipe(
            card: card,
            detail: preloadedDetail(for: card),
            optionFixtures: importedRecipeFixtures(for: card.id)
        )
    }

    func adaptedDetail(for recipeID: String) async -> RecipeDetailData? {
        guard recipeID.hasPrefix("onboarding-demo-") else { return nil }
        let recipes = Self.preloadedRecipes

        for recipe in recipes {
            for fixture in recipe.optionFixtures {
                let response = fixture.makeResponse(from: recipe)
                if response.recipeID == recipeID {
                    return response.recipeDetail
                }
            }

            for fixture in recipe.allDemoFixtures {
                let response = fixture.makeResponse(from: recipe)
                if response.recipeID == recipeID {
                    return response.recipeDetail
                }
            }
        }

        return nil
    }

    private struct PreloadedRecipeContent {
        let servings: Int
        let caloriesKcal: Double
        let proteinG: Double
        let carbsG: Double
        let fatG: Double
        let ingredients: [(name: String, quantity: String?)]
        let steps: [String]
    }

    private static func preloadedDetail(for card: DiscoverRecipeCardData) -> RecipeDetailData {
        let content = preloadedContent(for: card.id)
        let ingredients = content.ingredients.enumerated().map { index, ingredient in
            RecipeDetailIngredient(
                id: "onboarding-base-ingredient-\(card.id)-\(index)",
                ingredientID: nil,
                displayName: ingredient.name,
                quantityText: ingredient.quantity,
                imageURLString: OnboardingRecipeEditDemoOptionFixture.commonIngredientImageURLString(for: ingredient.name),
                sortOrder: index
            )
        }
        let steps = content.steps.enumerated().map { index, text in
            RecipeDetailStep(
                number: index + 1,
                text: text,
                tipText: nil,
                ingredientRefs: [],
                ingredients: []
            )
        }

        return RecipeDetailData(
            id: card.id,
            title: card.title,
            description: card.description ?? "",
            authorName: card.authorName,
            authorHandle: card.authorHandle,
            authorURLString: card.recipeURLString,
            source: card.source,
            sourcePlatform: card.source,
            category: card.category,
            subcategory: nil,
            recipeType: card.recipeType,
            skillLevel: nil,
            cookTimeText: card.cookTimeText,
            servingsText: "\(content.servings) servings",
            servingSizeText: nil,
            dailyDietText: nil,
            estCostText: nil,
            estCaloriesText: "~\(Int(content.caloriesKcal.rounded())) kcal per serving",
            carbsText: nil,
            proteinText: nil,
            fatsText: nil,
            caloriesKcal: content.caloriesKcal,
            proteinG: content.proteinG,
            carbsG: content.carbsG,
            fatG: content.fatG,
            prepTimeMinutes: nil,
            cookTimeMinutes: card.cookTimeMinutes,
            heroImageURLString: card.heroImageURLString,
            discoverCardImageURLString: card.imageURLString,
            recipeURLString: card.recipeURLString,
            originalRecipeURLString: card.recipeURLString,
            attachedVideoURLString: nil,
            sourceProvenance: nil,
            detailFootnote: nil,
            imageCaption: nil,
            dietaryTags: [],
            flavorTags: [],
            cuisineTags: card.id == "c51e1c2d-57e5-4623-9af8-7b91adc86470" ? ["Nigerian"] : [],
            occasionTags: [],
            mainProtein: [
                "5e72d6d2-e8c2-46c8-a2cb-50043b392842",
                "c51e1c2d-57e5-4623-9af8-7b91adc86470"
            ].contains(card.id) ? "Chicken" : nil,
            cookMethod: nil,
            ingredients: ingredients,
            steps: steps,
            servingsCount: content.servings
        )
    }

    private static func preloadedContent(for recipeID: String) -> PreloadedRecipeContent {
        switch recipeID {
        case "5e72d6d2-e8c2-46c8-a2cb-50043b392842":
            return PreloadedRecipeContent(
                servings: 4,
                caloriesKcal: 720,
                proteinG: 44,
                carbsG: 67,
                fatG: 30,
                ingredients: [
                    ("Chicken legs", "1.25 kg or 6"),
                    ("Oil", "1 tbsp"),
                    ("Salt", "1 tsp"),
                    ("Black pepper", "2 tsp"),
                    ("Garlic powder", "2 tsp"),
                    ("Paprika", "2 tsp"),
                    ("Peri-peri sauce", "4 tbsp"),
                    ("Lemon juice", "Juice of 1 lemon"),
                    ("Potatoes", "800-900 g"),
                    ("White pepper", "1 tbsp"),
                    ("Chili powder", "1 tsp"),
                    ("Sugar", "1 tsp")
                ],
                steps: [
                    "Blend garlic powder, paprika, and some of the peri-peri sauce.",
                    "Add the lemon juice, salt, pepper, paprika, garlic powder, and sugar.",
                    "Drizzle in the oil while blending to emulsify the sauce.",
                    "Coat the chicken legs with the peri-peri mixture.",
                    "Marinate for at least 1 hour, then place the chicken skin-side down on a tray.",
                    "Bake at 200 degrees C for 40 to 45 minutes.",
                    "Peel and slice the potatoes, then wash off the excess starch.",
                    "Boil the potatoes in salted water for 8 minutes.",
                    "Flip the chicken after 25 minutes, brush with more sauce, and return it to the oven.",
                    "Drain and dry the potatoes, then fry for 6 minutes.",
                    "Raise the oil temperature and fry the chips again for 4 minutes.",
                    "Mix salt, white pepper, paprika, chili powder, garlic powder, and sugar into peri-salt.",
                    "Toss the hot chips with the peri-salt.",
                    "Serve the chicken with the chips and extra peri-peri sauce."
                ]
            )
        case "c3a7bd77-6894-4069-9113-149c0adf71d4":
            return PreloadedRecipeContent(
                servings: 10,
                caloriesKcal: 360,
                proteinG: 5,
                carbsG: 52,
                fatG: 15,
                ingredients: [
                    ("Brown sugar", "1/4 cup (50 g)"),
                    ("Butter", "1/4 cup (57 g), melted"),
                    ("Bananas", "3 medium, mashed"),
                    ("Lemon juice", "1 tbsp"),
                    ("Unsalted butter", "1/4 cup (57 g)"),
                    ("Sugar", "1/2 cup (100 g)"),
                    ("Vegetable oil", "1/4 cup (60 g)"),
                    ("Egg", "1"),
                    ("Egg white", "1"),
                    ("All-purpose flour", "1 3/4 cups (220 g)"),
                    ("Baking powder", "1 1/2 tsp"),
                    ("Baking soda", "1/2 tsp"),
                    ("Salt", "1/2 tsp"),
                    ("Buttermilk", "1/2 cup (120 g)"),
                    ("Biscoff cookies", "10, chopped")
                ],
                steps: [
                    "Whisk flour, chopped Biscoff cookies, brown sugar, cinnamon, and salt for the topping.",
                    "Pour over the melted butter, mix with a fork, and set aside.",
                    "Mash the bananas with the lemon juice.",
                    "Mix in the butter and sugar.",
                    "Mix in the vegetable oil, egg, and egg white.",
                    "Whisk flour, baking powder, baking soda, and salt in a separate bowl.",
                    "Fold half of the dry mixture into the banana mixture.",
                    "Mix in the buttermilk, then fold in the remaining dry mixture.",
                    "Fold in the chopped Biscoff cookies.",
                    "Pour the batter into a 9-by-5-inch loaf pan.",
                    "Cover the batter with the prepared topping.",
                    "Bake at 350 degrees F for 60 to 65 minutes.",
                    "Cool before slicing and optionally drizzle with melted Biscoff spread."
                ]
            )
        case "e2c0da0d-047c-440b-b96d-a5730f403072":
            return PreloadedRecipeContent(
                servings: 2,
                caloriesKcal: 260,
                proteinG: 5,
                carbsG: 46,
                fatG: 8,
                ingredients: [
                    ("Watermelon", "4 cups"),
                    ("Condensed milk", "3 tbsp"),
                    ("Half-and-half", "1/4 cup"),
                    ("Lime juice", "Juice of 1/2 lime"),
                    ("Salt", "Pinch")
                ],
                steps: [
                    "Cut the watermelon into chunks.",
                    "Add the watermelon to a blender.",
                    "Add the condensed milk.",
                    "Add the half-and-half.",
                    "Add the lime juice.",
                    "Add a pinch of salt.",
                    "Blend until completely smooth.",
                    "Serve immediately."
                ]
            )
        case "c51e1c2d-57e5-4623-9af8-7b91adc86470":
            return PreloadedRecipeContent(
                servings: 4,
                caloriesKcal: 760,
                proteinG: 47,
                carbsG: 78,
                fatG: 28,
                ingredients: [
                    ("Chicken thighs", "7"),
                    ("Olive oil", "2 tbsp"),
                    ("Jollof tomato base", "1/4 cup"),
                    ("Garlic paste", "1 tsp"),
                    ("Oregano", "1 tsp"),
                    ("Paprika", "1 tsp"),
                    ("Cumin", "1/2 tsp"),
                    ("Garlic granules", "1 tsp"),
                    ("Black pepper", "1/2 tsp"),
                    ("Salt", "To taste"),
                    ("Chili flakes", "To taste"),
                    ("Rice", "2 cups, washed"),
                    ("Onion", "1, chopped"),
                    ("Garlic", "2 cloves, minced"),
                    ("Ground white pepper", "1 tsp"),
                    ("Bay leaves", "2"),
                    ("Curry powder", "1 tsp"),
                    ("Thyme", "1 tsp"),
                    ("Chicken stock", "2-3 cups")
                ],
                steps: [
                    "Combine the oil, garlic paste, oregano, paprika, cumin, garlic granules, pepper, salt, and chili flakes.",
                    "Coat the chicken thighs in the marinade.",
                    "Preheat the air fryer to 180 degrees C.",
                    "Arrange the chicken in a single layer.",
                    "Air-fry for 20 to 25 minutes, turning halfway, until golden and cooked through.",
                    "Heat oil in a pot and soften the onion and garlic.",
                    "Add the jollof tomato base and fry briefly.",
                    "Add white pepper, bay leaves, curry powder, and thyme.",
                    "Stir in the washed rice and coat it in the sauce.",
                    "Pour in the chicken stock and bring to a boil.",
                    "Cover and cook on low until the rice is tender and the liquid is absorbed.",
                    "Rest the rice for 5 minutes.",
                    "Fluff the rice with a fork.",
                    "Serve the air-fried chicken over the jollof rice."
                ]
            )
        default:
            return PreloadedRecipeContent(
                servings: 4,
                caloriesKcal: 0,
                proteinG: 0,
                carbsG: 0,
                fatG: 0,
                ingredients: [],
                steps: []
            )
        }
    }

    private static let importedRecipeCards: [DiscoverRecipeCardData] = [
        DiscoverRecipeCardData(
            id: "5e72d6d2-e8c2-46c8-a2cb-50043b392842",
            title: "Peri-Peri Chicken with Peri-Salted Chips",
            description: "Spicy grilled peri-peri chicken with seasoned chips.",
            authorName: "dishesandbeats",
            authorHandle: "@dishesandbeats",
            category: "Dinner",
            recipeType: "Main course",
            cookTimeText: "40-45 minutes",
            cookTimeMinutes: 61,
            publishedDate: nil,
            imageURLString: "https://ztqptjimmcdoriefkqcx.supabase.co/storage/v1/object/public/recipe-images/peri-peri-chicken-with-peri-salted-chips/card/7e53e064f923d9822ed08823.jpg",
            heroImageURLString: "https://ztqptjimmcdoriefkqcx.supabase.co/storage/v1/object/public/recipe-images/peri-peri-chicken-with-peri-salted-chips/hero/7e53e064f923d9822ed08823.jpg",
            recipeURLString: "https://www.tiktok.com/@dishesandbeats/video/7639147193617681686",
            source: "TikTok"
        ),
        DiscoverRecipeCardData(
            id: "c3a7bd77-6894-4069-9113-149c0adf71d4",
            title: "Biscoff Banana Bread",
            description: "Banana bread finished with Biscoff spread and cookies.",
            authorName: "emijuju",
            authorHandle: "@emijuju",
            category: "Dessert",
            recipeType: "Baking",
            cookTimeText: "60-65 minutes",
            cookTimeMinutes: 65,
            publishedDate: nil,
            imageURLString: "https://ztqptjimmcdoriefkqcx.supabase.co/storage/v1/object/public/recipe-images/biscoff-banana-bread/hero/90780d141f292102b4e4b928.jpg",
            heroImageURLString: "https://ztqptjimmcdoriefkqcx.supabase.co/storage/v1/object/public/recipe-images/biscoff-banana-bread/hero/90780d141f292102b4e4b928.jpg",
            recipeURLString: "https://ztqptjimmcdoriefkqcx.supabase.co/storage/v1/object/public/recipe-videos/a11310fd870947a2ca94.mp4",
            source: "TikTok"
        ),
        DiscoverRecipeCardData(
            id: "e2c0da0d-047c-440b-b96d-a5730f403072",
            title: "Watermelon Drink",
            description: "A refreshing watermelon drink with a creamy twist.",
            authorName: "Chef Fatty",
            authorHandle: "@itscheffatty",
            category: "Beverage",
            recipeType: "Drink",
            cookTimeText: nil,
            cookTimeMinutes: 0,
            publishedDate: nil,
            imageURLString: "https://ztqptjimmcdoriefkqcx.supabase.co/storage/v1/object/public/recipe-images/watermelon-drink/hero/7d8b8c8b4b7e6440d005ef5b.jpg",
            heroImageURLString: "https://ztqptjimmcdoriefkqcx.supabase.co/storage/v1/object/public/recipe-images/watermelon-drink/hero/7d8b8c8b4b7e6440d005ef5b.jpg",
            recipeURLString: "https://ztqptjimmcdoriefkqcx.supabase.co/storage/v1/object/public/recipe-videos/dc6e92ead77f84efc255.mp4",
            source: "TikTok"
        ),
        DiscoverRecipeCardData(
            id: "c51e1c2d-57e5-4623-9af8-7b91adc86470",
            title: "Airfryer Chicken Thighs with Jollof Rice",
            description: "Air-fried seasoned chicken thighs served with Nigerian jollof rice.",
            authorName: "on_todays_bake",
            authorHandle: "@on_todays_bake",
            category: "Dinner",
            recipeType: "Main course",
            cookTimeText: "20-25 minutes",
            cookTimeMinutes: 25,
            publishedDate: nil,
            imageURLString: "https://ztqptjimmcdoriefkqcx.supabase.co/storage/v1/object/public/recipe-images/airfryer-chicken-thighs-with-jollof-rice/card/bc601b7b5f48bb642c76a94e.jpg",
            heroImageURLString: "https://ztqptjimmcdoriefkqcx.supabase.co/storage/v1/object/public/recipe-images/airfryer-chicken-thighs-with-jollof-rice/hero/bc601b7b5f48bb642c76a94e.jpg",
            recipeURLString: "https://www.tiktok.com/@on_todays_bake/video/7613740233862958358",
            source: "TikTok"
        ),
    ]

    private static func importedRecipeFixtures(for recipeID: String) -> [OnboardingRecipeEditDemoOptionFixture] {
        switch recipeID {
        case "5e72d6d2-e8c2-46c8-a2cb-50043b392842":
            return [
                fixture(
                    recipeID: recipeID,
                    intent: .healthier,
                    summary: "Kept the peri-peri flavor, used skinless chicken, reduced the oil, and added roasted peppers alongside the chips.",
                    title: "Healthier Peri-Peri Chicken & Chips",
                    cookTime: "45 minutes",
                    ingredients: [
                        "4 skinless chicken thighs",
                        "3 red chilies",
                        "1 red bell pepper",
                        "4 garlic cloves",
                        "1 lemon, juiced",
                        "1 tbsp olive oil",
                        "1 tsp smoked paprika",
                        "1 tsp dried oregano",
                        "600 g potatoes, cut into chips",
                        "Salt"
                    ],
                    steps: [
                        "Blend chilies, bell pepper, garlic, lemon, olive oil, paprika, oregano, and salt into a peri-peri sauce.",
                        "Coat the chicken with most of the sauce and marinate for at least 20 minutes.",
                        "Toss the potato chips with a small spoonful of sauce and spread them on a lined tray.",
                        "Bake the chips at 425 degrees F until crisp, turning once, about 30 to 35 minutes.",
                        "Grill or air-fry the chicken until browned and cooked through, then serve with the remaining sauce and chips."
                    ],
                    substitutions: ["Skinless chicken reduces excess fat.", "Oven-crisped chips replace deep-fried chips."],
                    dietaryFit: ["Healthy", "High-Protein", "Dinner"]
                ),
                fixture(
                    recipeID: recipeID,
                    intent: .mealPrep,
                    summary: "Turned the same peri-peri chicken into a reheat-friendly meal-prep bowl.",
                    title: "Peri-Peri Chicken Meal-Prep Bowls",
                    cookTime: "45 minutes",
                    ingredients: [
                        "4 boneless chicken thighs",
                        "1 cup peri-peri sauce",
                        "2 cups cooked rice",
                        "2 bell peppers, sliced",
                        "1 red onion, sliced",
                        "1 tbsp olive oil",
                        "1 lemon"
                    ],
                    steps: [
                        "Marinate the chicken in half of the peri-peri sauce for 20 minutes.",
                        "Roast the peppers and onion with olive oil until tender.",
                        "Grill or air-fry the chicken until cooked through, then rest and slice it.",
                        "Divide rice, vegetables, and chicken between containers.",
                        "Pack the remaining sauce and lemon separately, then chill once cool."
                    ],
                    substitutions: ["Rice and roasted vegetables replace chips for easier reheating."],
                    dietaryFit: ["Meal Prep", "High-Protein", "Dinner"]
                ),
                fixture(
                    recipeID: recipeID,
                    intent: .moreProtein,
                    summary: "Raised the chicken portion and added a Greek-yogurt peri sauce for more protein without losing the original flavor.",
                    title: "High-Protein Peri-Peri Chicken & Chips",
                    cookTime: "30 minutes",
                    ingredients: [
                        "6 boneless skinless chicken thighs",
                        "1/2 cup peri-peri sauce",
                        "3/4 cup plain Greek yogurt",
                        "1 lemon, juiced",
                        "1 tbsp olive oil",
                        "600 g frozen oven chips",
                        "1 tsp paprika",
                        "1/2 tsp garlic powder",
                        "1/2 tsp white pepper",
                        "Salt"
                    ],
                    steps: [
                        "Heat the oven and spread the chips on a tray so they can crisp while the chicken cooks.",
                        "Coat the chicken with peri-peri sauce, lemon juice, and half of the olive oil.",
                        "Air-fry or pan-sear the chicken until browned and cooked through, about 16 to 20 minutes.",
                        "Mix the Greek yogurt with two spoonfuls of peri-peri sauce for a high-protein dip.",
                        "Mix paprika, garlic powder, white pepper, and salt into a quick peri-salt.",
                        "Toss the hot chips with the peri-salt and serve with the chicken and remaining sauce."
                    ],
                    substitutions: ["A larger lean-chicken portion raises protein.", "Greek yogurt replaces a mayonnaise-based dip."],
                    dietaryFit: ["High-Protein", "Dinner"]
                ),
                fixture(
                    recipeID: recipeID,
                    intent: .lowCalories,
                    summary: "Reduced the chips and oil, then filled out the plate with peppers, onion, and courgette roasted in peri-peri juices.",
                    title: "Lower-Calorie Peri-Peri Chicken & Chips",
                    cookTime: "45 minutes",
                    ingredients: [
                        "4 skinless chicken breasts",
                        "3/4 cup peri-peri sauce",
                        "1 lemon, juiced",
                        "300 g potatoes, cut into wedges",
                        "2 bell peppers, sliced",
                        "1 red onion, cut into wedges",
                        "1 courgette, sliced",
                        "1 tbsp olive oil",
                        "1 tsp paprika",
                        "Salt"
                    ],
                    steps: [
                        "Coat the chicken with peri-peri sauce, lemon juice, paprika, and salt.",
                        "Spread the potatoes on a tray with half of the olive oil and roast for 15 minutes.",
                        "Add the peppers, onion, courgette, and chicken to the tray.",
                        "Roast until the vegetables caramelize and the chicken is cooked through, turning once.",
                        "Finish with the remaining peri-peri sauce and serve directly from the tray."
                    ],
                    substitutions: ["Lean chicken and a smaller chip portion lower calories.", "Roasted vegetables add volume with the same seasoning."],
                    dietaryFit: ["Lower Calorie", "High-Protein", "Dinner"]
                ),
            ]
        case "c3a7bd77-6894-4069-9113-149c0adf71d4":
            return [
                fixture(
                    recipeID: recipeID,
                    intent: .lessSugar,
                    summary: "Reduced the added sugar and Biscoff topping while keeping the caramelized biscuit flavor.",
                    title: "Less-Sugar Biscoff Banana Bread",
                    cookTime: "60 minutes",
                    ingredients: [
                        "3 very ripe bananas",
                        "2 large eggs",
                        "1/3 cup Greek yogurt",
                        "1/3 cup Biscoff spread",
                        "1/4 cup brown sugar",
                        "1 1/2 cups all-purpose flour",
                        "1 tsp baking soda",
                        "1 tsp cinnamon",
                        "1/4 tsp salt",
                        "3 Biscoff cookies, chopped"
                    ],
                    steps: [
                        "Mash the bananas, then whisk in eggs, Greek yogurt, Biscoff spread, and brown sugar.",
                        "Fold in flour, baking soda, cinnamon, and salt just until combined.",
                        "Pour into a lined loaf pan and scatter the chopped cookies over the top.",
                        "Bake at 350 degrees F until a tester comes out mostly clean, about 50 to 60 minutes.",
                        "Cool before slicing so the loaf sets cleanly."
                    ],
                    substitutions: ["Ripe banana supplies more of the sweetness.", "Greek yogurt replaces part of the butter or oil."],
                    dietaryFit: ["Less Sugar", "Dessert", "Baking"]
                ),
                fixture(
                    recipeID: recipeID,
                    intent: .moreProtein,
                    summary: "Added Greek yogurt and protein powder without losing the Biscoff banana-bread texture.",
                    title: "Protein Biscoff Banana Bread",
                    cookTime: "60 minutes",
                    ingredients: [
                        "3 ripe bananas",
                        "2 large eggs",
                        "3/4 cup Greek yogurt",
                        "1/3 cup Biscoff spread",
                        "1 cup all-purpose flour",
                        "1/2 cup vanilla protein powder",
                        "1 tsp baking soda",
                        "1/2 tsp cinnamon",
                        "1/4 tsp salt",
                        "4 Biscoff cookies, chopped"
                    ],
                    steps: [
                        "Whisk mashed bananas, eggs, Greek yogurt, and Biscoff spread until smooth.",
                        "Fold in flour, protein powder, baking soda, cinnamon, and salt.",
                        "Transfer to a lined loaf pan and finish with chopped Biscoff cookies.",
                        "Bake at 350 degrees F for 50 to 60 minutes, tenting the top if it browns early.",
                        "Cool fully before slicing."
                    ],
                    substitutions: ["Greek yogurt and protein powder raise the protein content."],
                    dietaryFit: ["High-Protein", "Dessert", "Baking"]
                ),
                fixture(
                    recipeID: recipeID,
                    intent: .dairyFree,
                    summary: "Replaced butter and buttermilk with plant-based alternatives while retaining the soft banana crumb and Biscoff topping.",
                    title: "Dairy-Free Biscoff Banana Bread",
                    cookTime: "60 minutes",
                    ingredients: [
                        "3 ripe bananas",
                        "1/3 cup light brown sugar",
                        "1/3 cup neutral oil",
                        "2 large eggs",
                        "1/2 cup oat milk",
                        "1 tsp lemon juice",
                        "1 3/4 cups all-purpose flour",
                        "1 1/2 tsp baking powder",
                        "1/2 tsp baking soda",
                        "1/2 tsp salt",
                        "8 Biscoff cookies, chopped"
                    ],
                    steps: [
                        "Stir the oat milk and lemon juice together and leave for 5 minutes.",
                        "Whisk mashed banana, brown sugar, oil, and eggs until smooth.",
                        "Fold in flour, baking powder, baking soda, salt, and the oat-milk mixture.",
                        "Fold in most of the chopped cookies, then pour the batter into a lined loaf pan.",
                        "Top with the remaining cookies and bake at 350 degrees F for 55 to 65 minutes."
                    ],
                    substitutions: ["Neutral oil replaces butter.", "Acidified oat milk replaces buttermilk."],
                    dietaryFit: ["Dairy-Free", "Dessert", "Baking"]
                ),
                fixture(
                    recipeID: recipeID,
                    intent: .lowCalories,
                    summary: "Reduced the spread, cookies, sugar, and fat while keeping ripe banana and warm spice at the center of the loaf.",
                    title: "Lower-Calorie Biscoff Banana Bread",
                    cookTime: "60 minutes",
                    ingredients: [
                        "3 ripe bananas",
                        "2 tbsp brown sugar",
                        "1/3 cup Biscoff spread",
                        "2 large eggs",
                        "3/4 cup nonfat Greek yogurt",
                        "1 1/2 cups all-purpose flour",
                        "1 tsp baking soda",
                        "1/2 tsp salt",
                        "1 tsp cinnamon",
                        "3 Biscoff cookies, chopped"
                    ],
                    steps: [
                        "Whisk mashed banana, brown sugar, Biscoff spread, eggs, and Greek yogurt until combined.",
                        "Whisk the flour, baking soda, salt, and cinnamon separately.",
                        "Fold the dry mixture into the banana mixture just until no flour streaks remain.",
                        "Transfer to a lined loaf pan and scatter the chopped cookies over the top.",
                        "Bake at 350 degrees F until the center is set, about 50 to 60 minutes, then cool fully."
                    ],
                    substitutions: ["Nonfat Greek yogurt replaces butter or oil.", "A thinner Biscoff layer and fewer cookies lower calories."],
                    dietaryFit: ["Lower Calorie", "Dessert", "Baking"]
                ),
            ]
        case "e2c0da0d-047c-440b-b96d-a5730f403072":
            return [
                fixture(
                    recipeID: recipeID,
                    intent: .lowCalories,
                    summary: "Kept the creamy watermelon finish with nonfat yogurt, lime, and no added sweetener.",
                    title: "Lower-Calorie Watermelon Drink",
                    cookTime: "10 minutes",
                    ingredients: [
                        "4 cups seedless watermelon",
                        "1/2 cup nonfat Greek yogurt",
                        "1 lime, juiced",
                        "1 cup ice",
                        "Pinch of salt"
                    ],
                    steps: [
                        "Blend watermelon, Greek yogurt, lime juice, salt, and ice until smooth.",
                        "Taste and add more lime if needed.",
                        "Pour into cold glasses and serve immediately."
                    ],
                    substitutions: ["Nonfat Greek yogurt replaces a heavier cream base.", "Ripe watermelon provides all of the sweetness."],
                    dietaryFit: ["Lower Calorie", "Drink", "Quick"]
                ),
                fixture(
                    recipeID: recipeID,
                    intent: .spicy,
                    summary: "Added lime, ginger, and a touch of chili for a sharper watermelon cooler.",
                    title: "Spicy Watermelon Lime Cooler",
                    cookTime: "10 minutes",
                    ingredients: [
                        "4 cups seedless watermelon",
                        "1 lime, juiced",
                        "1 tsp fresh ginger",
                        "1 small pinch cayenne",
                        "1 cup ice",
                        "Pinch of salt"
                    ],
                    steps: [
                        "Blend watermelon, lime juice, ginger, cayenne, salt, and ice until smooth.",
                        "Taste and adjust the chili carefully.",
                        "Serve immediately over fresh ice."
                    ],
                    substitutions: ["Lime and ginger sharpen the drink without extra sweetness."],
                    dietaryFit: ["Spicy", "Drink", "Quick"]
                ),
                fixture(
                    recipeID: recipeID,
                    intent: .lessSugar,
                    summary: "Removed condensed milk and let ripe watermelon provide the sweetness, balanced with lime and a pinch of salt.",
                    title: "No-Added-Sugar Watermelon Cooler",
                    cookTime: "5 minutes",
                    ingredients: [
                        "4 cups very ripe seedless watermelon",
                        "1/2 lime, juiced",
                        "1 cup ice",
                        "Pinch of salt",
                        "Fresh mint"
                    ],
                    steps: [
                        "Blend watermelon, lime juice, ice, and salt until smooth.",
                        "Taste and add another squeeze of lime only if the watermelon is very sweet.",
                        "Pour into cold glasses and finish with mint."
                    ],
                    substitutions: ["Ripe watermelon replaces condensed milk as the sweetener.", "Ice keeps the drink full-bodied without cream."],
                    dietaryFit: ["Less Sugar", "Dairy-Free", "Drink"]
                ),
                fixture(
                    recipeID: recipeID,
                    intent: .moreProtein,
                    summary: "Added strained yogurt for a creamy watermelon smoothie with substantially more protein than the original drink.",
                    title: "Protein Watermelon Yogurt Smoothie",
                    cookTime: "5 minutes",
                    ingredients: [
                        "4 cups seedless watermelon",
                        "1 cup plain Greek yogurt",
                        "1/2 lime, juiced",
                        "1 tbsp chia seeds",
                        "1 cup ice",
                        "Pinch of salt"
                    ],
                    steps: [
                        "Blend watermelon, Greek yogurt, lime juice, chia seeds, ice, and salt until smooth.",
                        "Rest for 2 minutes so the chia begins to thicken the drink.",
                        "Blend once more, then serve immediately."
                    ],
                    substitutions: ["Greek yogurt replaces condensed milk and half-and-half while adding protein.", "Chia adds body and a smaller protein boost."],
                    dietaryFit: ["High-Protein", "Drink", "Quick"]
                ),
            ]
        case "c51e1c2d-57e5-4623-9af8-7b91adc86470":
            return [
                fixture(
                    recipeID: recipeID,
                    intent: .healthier,
                    summary: "Kept the jollof flavor and crisp chicken while reducing the oil, using skinless thighs, and balancing the plate with vegetables.",
                    title: "Healthier Airfryer Chicken & Jollof Rice",
                    cookTime: "35 minutes",
                    ingredients: [
                        "6 skinless chicken thighs",
                        "1 tbsp olive oil",
                        "1 tsp paprika",
                        "1 tsp garlic granules",
                        "1/2 tsp cumin",
                        "2 cups rice, washed",
                        "1 onion, chopped",
                        "2 garlic cloves, minced",
                        "1/4 cup jollof tomato base",
                        "2 cups chicken stock",
                        "1 tsp curry powder",
                        "1 tsp thyme",
                        "Salt"
                    ],
                    steps: [
                        "Coat the chicken with olive oil, paprika, garlic, cumin, and salt.",
                        "Air-fry at 180 degrees C until browned and cooked through, turning halfway.",
                        "Soften the onion and garlic, then fry the jollof tomato base with curry powder and thyme.",
                        "Stir in the rice and stock, cover, and cook on low until tender.",
                        "Fluff the rice and serve with the air-fried chicken."
                    ],
                    substitutions: ["Skinless thighs and less oil lighten the dish without removing the jollof seasoning."],
                    dietaryFit: ["Healthy", "Nigerian", "High-Protein"]
                ),
                fixture(
                    recipeID: recipeID,
                    intent: .mealPrep,
                    summary: "Turned the chicken and jollof rice into portions that chill and reheat cleanly.",
                    title: "Chicken & Jollof Rice Meal Prep",
                    cookTime: "40 minutes",
                    ingredients: [
                        "7 chicken thighs",
                        "2 tbsp olive oil",
                        "1 tsp paprika",
                        "1 tsp garlic granules",
                        "2 cups rice, washed",
                        "1 onion, chopped",
                        "2 garlic cloves, minced",
                        "1/4 cup jollof tomato base",
                        "2 cups chicken stock",
                        "1 tsp curry powder",
                        "1 tsp thyme"
                    ],
                    steps: [
                        "Season and air-fry the chicken until cooked through.",
                        "Fry the onion, garlic, tomato base, curry powder, and thyme until fragrant.",
                        "Add rice and stock, then cover and cook on low until tender.",
                        "Rest and fluff the rice while the chicken cools slightly.",
                        "Portion the chicken and rice into containers, then chill once cool."
                    ],
                    substitutions: ["Portioned chicken and rice make the TikTok dinner suitable for reheating."],
                    dietaryFit: ["Meal Prep", "Nigerian", "High-Protein"]
                ),
                fixture(
                    recipeID: recipeID,
                    intent: .moreProtein,
                    summary: "Raised the lean chicken portion and slightly reduced the rice so each serving carries more protein while staying recognizably jollof.",
                    title: "High-Protein Chicken & Jollof Rice",
                    cookTime: "40 minutes",
                    ingredients: [
                        "8 skinless chicken thighs",
                        "1 tbsp olive oil",
                        "1 tsp paprika",
                        "1 tsp garlic granules",
                        "1 lime, juiced",
                        "1 1/2 cups rice, washed",
                        "1 onion, chopped",
                        "2 garlic cloves, minced",
                        "1/3 cup jollof tomato base",
                        "2 cups chicken stock",
                        "1 tsp curry powder",
                        "1 tsp thyme",
                        "Salt"
                    ],
                    steps: [
                        "Mix olive oil, paprika, garlic, lime juice, and salt into a marinade.",
                        "Coat the chicken in the marinade and air-fry at 180 degrees C until cooked through.",
                        "Soften the onion and garlic, then fry the jollof tomato base until concentrated.",
                        "Add curry powder, thyme, rice, and stock, then cover and cook on low until tender.",
                        "Fluff the rice and serve with the chicken, keeping extra lime nearby to balance the heat."
                    ],
                    substitutions: ["More skinless chicken and a slightly smaller rice portion increase protein per serving."],
                    dietaryFit: ["High-Protein", "Nigerian", "Dinner"]
                ),
                fixture(
                    recipeID: recipeID,
                    intent: .lowCalories,
                    summary: "Reduced the rice and oil, then added peppers, carrots, peas, and spinach for a filling lower-calorie plate.",
                    title: "Lower-Calorie Chicken & Jollof Rice",
                    cookTime: "45 minutes",
                    ingredients: [
                        "6 chicken thighs",
                        "1 tbsp olive oil",
                        "1 tsp paprika",
                        "1 1/4 cups rice, washed",
                        "1 onion, chopped",
                        "1 red bell pepper, diced",
                        "2 carrots, diced",
                        "1 cup frozen peas",
                        "2 cups baby spinach",
                        "1/3 cup jollof tomato base",
                        "2 cups chicken stock",
                        "1 tsp curry powder",
                        "1 tsp thyme",
                        "Salt"
                    ],
                    steps: [
                        "Season the chicken with paprika, salt, and half of the olive oil, then air-fry until cooked through.",
                        "Soften the onion, bell pepper, and carrots in the remaining oil.",
                        "Fry the jollof tomato base with curry powder and thyme until concentrated.",
                        "Stir in the rice and stock, cover, and cook on low until nearly tender.",
                        "Fold in peas and spinach for the final 5 minutes, then fluff and serve with the chicken."
                    ],
                    substitutions: ["A smaller rice portion and more vegetables lower calories without changing the jollof base."],
                    dietaryFit: ["Lower Calorie", "Nigerian", "High-Protein"]
                ),
            ]
        default:
            return []
        }
    }

    private static func fixture(
        recipeID: String,
        intent: RecipeAlterationIntent,
        summary: String,
        title: String,
        cookTime: String,
        ingredients: [String],
        steps: [String],
        substitutions: [String],
        dietaryFit: [String]
    ) -> OnboardingRecipeEditDemoOptionFixture {
        OnboardingRecipeEditDemoOptionFixture(
            recipeID: recipeID,
            intent: intent,
            preplannedSummary: summary,
            adaptedRecipe: RecipeAdaptationRecipe(
                title: title,
                summary: summary,
                cookTimeText: cookTime,
                ingredients: ingredients,
                steps: steps,
                substitutions: substitutions,
                pairingNotes: [],
                dietaryFit: dietaryFit
            ),
            changeSummary: summary
        )
    }
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
    let caloriesKcal: Double?
    let proteinG: Double?
    let carbsG: Double?
    let fatG: Double?

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
        case caloriesKcal = "calories_kcal"
        case proteinG = "protein_g"
        case carbsG = "carbs_g"
        case fatG = "fat_g"
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
                imageURLString: ingredient.imageURLString ?? OnboardingRecipeEditDemoOptionFixture.commonIngredientImageURLString(for: ingredient.displayName),
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
            estCaloriesText: caloriesKcal.map { "\(Int($0.rounded())) kcal per serving" },
            carbsText: nil,
            proteinText: nil,
            fatsText: nil,
            caloriesKcal: caloriesKcal,
            proteinG: proteinG,
            carbsG: carbsG,
            fatG: fatG,
            prepTimeMinutes: nil,
            cookTimeMinutes: cookTimeMinutes,
            heroImageURLString: heroImageURLString,
            discoverCardImageURLString: discoverCardImageURLString,
            recipeURLString: recipeURLString,
            originalRecipeURLString: originalRecipeURLString,
            attachedVideoURLString: nil,
            sourceProvenance: nil,
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
            sourceProvenance: liveDetail.sourceProvenance,
            detailFootnote: liveDetail.detailFootnote,
            imageCaption: liveDetail.imageCaption,
            dietaryTags: liveDetail.dietaryTags,
            flavorTags: liveDetail.flavorTags,
            cuisineTags: liveDetail.cuisineTags,
            occasionTags: liveDetail.occasionTags,
            mainProtein: liveDetail.mainProtein,
            cookMethod: liveDetail.cookMethod,
            ingredients: demoEnrichedIngredients(from: liveDetail.ingredients),
            steps: liveDetail.steps,
            servingsCount: liveDetail.servingsCount
        )
    }

    private func demoEnrichedIngredients(from liveIngredients: [RecipeDetailIngredient]) -> [RecipeDetailIngredient] {
        let fallbackImageByName = Dictionary(uniqueKeysWithValues: ingredients.compactMap { ingredient -> (String, String)? in
            let imageURLString = ingredient.imageURLString
                ?? OnboardingRecipeEditDemoOptionFixture.commonIngredientImageURLString(for: ingredient.displayName)
            guard let imageURLString, !imageURLString.isEmpty else { return nil }
            return (ingredient.displayName.lowercased(), imageURLString)
        })

        return liveIngredients.map { ingredient in
            let fallbackImageURLString = fallbackImageByName[ingredient.displayTitle.lowercased()]
                ?? fallbackImageByName[ingredient.displayName.lowercased()]
                ?? OnboardingRecipeEditDemoOptionFixture.commonIngredientImageURLString(for: ingredient.displayTitle)
                ?? OnboardingRecipeEditDemoOptionFixture.commonIngredientImageURLString(for: ingredient.displayName)

            guard (ingredient.imageURLString ?? "").isEmpty,
                  let fallbackImageURLString
            else {
                return ingredient
            }

            return RecipeDetailIngredient(
                id: ingredient.id,
                ingredientID: ingredient.ingredientID,
                displayName: ingredient.displayName,
                quantityText: ingredient.quantityText,
                imageURLString: fallbackImageURLString,
                sortOrder: ingredient.sortOrder
            )
        }
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
