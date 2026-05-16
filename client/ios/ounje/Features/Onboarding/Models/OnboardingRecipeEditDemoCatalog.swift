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
            return Array(defaultFixtures.prefix(4))
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

        return Array(prioritizedFixtures.prefix(4))
    }

    private var defaultResolvedFixtures: [OnboardingRecipeEditDemoOptionFixture] {
        var fixtures = optionFixtures

        if let lowCaloriesFixture = OnboardingRecipeEditDemoOptionFixture.lowCaloriesFixture(for: self),
           !fixtures.contains(where: { $0.intent == lowCaloriesFixture.intent }) {
            fixtures.insert(lowCaloriesFixture, at: min(1, fixtures.count))
        }

        if let healthyFixture = OnboardingRecipeEditDemoOptionFixture.healthyFixture(for: self),
           !fixtures.contains(where: { $0.intent == healthyFixture.intent }) {
            fixtures.append(healthyFixture)
        }

        return fixtures
    }

    fileprivate var allDemoFixtures: [OnboardingRecipeEditDemoOptionFixture] {
        defaultResolvedFixtures
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
        case ("cdf56b03-71e8-4386-acb1-262837286a36", .lowCalories):
            return "Cut sugar and cream cheese, added Greek yogurt, kept the custard."
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
        case ("b1bd5a95-dab3-436e-89c8-fb4df52b8fb7", .lowCalories):
            return "Trimmed oil, used skinless chicken, steamed rice, air-fried plantain."
        case ("b1bd5a95-dab3-436e-89c8-fb4df52b8fb7", .spicy):
            return "Added cayenne, added lime, added more heat."
        case ("b1bd5a95-dab3-436e-89c8-fb4df52b8fb7", .mealPrep):
            return "Separate components, extra sauce, reheat-friendly steps."
        case ("eaa85ffd-1a66-44e9-84e7-2c7d4b950390", .moreProtein):
            return "Added shredded chicken, added Greek yogurt."
        case ("eaa85ffd-1a66-44e9-84e7-2c7d4b950390", .lowCalories):
            return "Reduced pasta and oil, added more spinach, kept anchovy-Parmesan flavor."
        case ("eaa85ffd-1a66-44e9-84e7-2c7d4b950390", .keto):
            return "Removed pasta, added spinach, added lemon."
        case ("eaa85ffd-1a66-44e9-84e7-2c7d4b950390", .lighter):
            return "Removed olive oil, removed Parmesan, added basil."
        case ("eaa85ffd-1a66-44e9-84e7-2c7d4b950390", .dairyFree):
            return "Added nutritional yeast, added pasta water, removed Parmesan."
        case ("4bcf072c-b95d-49fa-9997-d2749a118a15", .lessSugar):
            return "Removed powdered sugar, removed granulated sugar."
        case ("4bcf072c-b95d-49fa-9997-d2749a118a15", .lowCalories):
            return "Thinner shortbread, less butter and sugar, brighter guava-lemon filling."
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
            sourceProvenance: baseDetail.sourceProvenance,
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

    fileprivate static func commonIngredientImageURLString(for displayName: String) -> String? {
        let normalized = normalizedName(displayName)
        let mappings: [(keywords: [String], url: String)] = [
            (["chicken thigh", "chicken thighs"], "https://firebasestorage.googleapis.com/v0/b/julienne-3555a.appspot.com/o/ingredients%2Fchicken_thigh.jpg?alt=media&token=c66a2a2c-33cd-4d6d-9d99-58475be7c85a?t=1774248428264"),
            (["tomato", "tomatoes"], "https://firebasestorage.googleapis.com/v0/b/julienne-3555a.appspot.com/o/ingredients%2Ftomato.jpg?alt=media&token=526e27f3-043c-472b-9220-2929f93bb4e5?t=1774234594733"),
            (["red bell pepper", "bell pepper"], "https://firebasestorage.googleapis.com/v0/b/julienne-3555a.appspot.com/o/ingredients%2Fred_bell_pepper.jpg?alt=media&token=01e19356-1a36-49bb-b34f-5b68777f05bf?t=1774244049104"),
            (["habanero", "habanero pepper"], "https://firebasestorage.googleapis.com/v0/b/julienne-3555a.appspot.com/o/ingredients%2Fpeppers.jpg?alt=media&token=961e8efd-b228-4fa2-9606-272265b43eb3?t=1774257567466"),
            (["chicken stock", "chicken broth", "bouillon"], "https://firebasestorage.googleapis.com/v0/b/julienne-3555a.appspot.com/o/ingredients%2Fchicken_broth.jpg?alt=media&token=25dd3691-0b85-44a9-98b9-8aa562f6162b?t=1774249822040"),
            (["onion", "onions"], "https://firebasestorage.googleapis.com/v0/b/julienne-3555a.appspot.com/o/ingredients%2Fonion.jpg?alt=media&token=4d27c4bf-c973-4d6a-9b52-5f0a53fbd388?t=1774248318388"),
            (["thyme"], "https://firebasestorage.googleapis.com/v0/b/julienne-3555a.appspot.com/o/ingredients%2Fthyme.jpg?alt=media&token=8a29f820-749a-4420-87e8-ff90dbf01403?t=1774330873604"),
            (["black pepper"], "https://firebasestorage.googleapis.com/v0/b/julienne-3555a.appspot.com/o/ingredients%2Fblack_pepper.jpg?alt=media&token=965f8bc2-ada6-465f-a0fc-6b81bdc692a7?t=1774299971368"),
            (["curry powder"], "https://firebasestorage.googleapis.com/v0/b/julienne-3555a.appspot.com/o/ingredients%2Fyellow_curry.jpg?alt=media&token=6a659c8e-6375-4a7e-8d75-126c565a5cec?t=1774249108854"),
            (["salt"], "https://firebasestorage.googleapis.com/v0/b/julienne-3555a.appspot.com/o/ingredients%2Fsalt.jpg?alt=media&token=0140d2fd-6e8a-4b50-8a82-19b316ccc8d7?t=1774330872713"),
            (["white rice", "rice"], "https://firebasestorage.googleapis.com/v0/b/julienne-3555a.appspot.com/o/ingredients%2Frice.jpg?alt=media&token=5aa0fdcd-c942-4e76-9eed-c7e2dacc6ad7?t=1774248318327"),
            (["water"], "https://firebasestorage.googleapis.com/v0/b/julienne-3555a.appspot.com/o/ingredients%2Fwater.jpg?alt=media&token=ef1b81ea-f561-46ee-af79-dea3714ca564?t=1774234689901"),
            (["plantain", "plantains"], "https://firebasestorage.googleapis.com/v0/b/julienne-3555a.appspot.com/o/ingredients%2Fplantain.jpg?alt=media&token=2b145f14-d438-43e9-a9c2-c87237a8b44f?t=1774337486500"),
            (["black beans"], "https://firebasestorage.googleapis.com/v0/b/julienne-3555a.appspot.com/o/ingredients%2Fblack_beans.jpg?alt=media&token=b7be5a94-a7bd-4c20-8fee-989aee96f567?t=1774247130413"),
            (["lime juice", "lime"], "https://firebasestorage.googleapis.com/v0/b/julienne-3555a.appspot.com/o/ingredients%2Flime.jpg?alt=media&token=8baf258f-277b-4976-afdc-99229c41b136?t=1774250162863"),
            (["yogurt", "coconut milk", "almond milk"], "https://firebasestorage.googleapis.com/v0/b/julienne-3555a.appspot.com/o/ingredients%2Fmilk.jpg?alt=media&token=0dd8a299-f10b-4842-9999-ced50ef93c21?t=1774248091433"),
            (["almond flour", "gluten free flour", "oat flour"], "https://firebasestorage.googleapis.com/v0/b/julienne-3555a.appspot.com/o/ingredients%2Fflour.jpg?alt=media&token=0c58143c-815d-40bb-80cc-9a3b3c34b681?t=1774256493345"),
            (["coconut oil", "avocado oil", "olive oil", "frying oil", "neutral oil"], "https://firebasestorage.googleapis.com/v0/b/julienne-3555a.appspot.com/o/ingredients%2Folive_oil.jpg?alt=media&token=c2d859ad-887e-422a-af1a-6d1c2b642fcb?t=1774330870925"),
            (["plant butter"], "https://firebasestorage.googleapis.com/v0/b/julienne-3555a.appspot.com/o/ingredients%2Fbutter.jpg?alt=media&token=0d3b0fec-a623-457d-80a8-3da7db42fdb3?t=1774256492999"),
            (["mozzarella", "ricotta", "cheese"], "https://firebasestorage.googleapis.com/v0/b/julienne-3555a.appspot.com/o/ingredients%2Fparmesan_cheese.jpg?alt=media&token=41595f2d-19cc-4781-ba5b-92c2e1e9a732?t=1774330872651"),
            (["cauliflower rice"], "https://firebasestorage.googleapis.com/v0/b/julienne-3555a.appspot.com/o/ingredients%2Frice.jpg?alt=media&token=5aa0fdcd-c942-4e76-9eed-c7e2dacc6ad7?t=1774248318327"),
            (["chile", "chili", "pepper", "cayenne"], "https://firebasestorage.googleapis.com/v0/b/julienne-3555a.appspot.com/o/ingredients%2Fchili_flakes.jpg?alt=media&token=5e372122-e466-4fac-a826-56f4156b2ec4?t=1774331841546")
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

    func adaptedDetail(for recipeID: String) async -> RecipeDetailData? {
        guard recipeID.hasPrefix("onboarding-demo-") else { return nil }
        let recipes = await loadRecipes()

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
