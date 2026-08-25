import Foundation

enum ShoppingIngredientCanonicalizer {
    struct Match {
        let key: String
        let displayName: String
    }

    private static let aliasFamilies: [(displayName: String, aliases: [String])] = [
        ("Eggs", [
            "egg", "eggs", "large egg", "large eggs", "medium egg", "medium eggs",
            "small egg", "small eggs", "whole egg", "whole eggs", "egg yolk", "egg yolks",
            "large egg yolk", "large egg yolks"
        ]),
        ("Heavy Cream", [
            "cream", "fresh cream", "heavy cream", "heavy whipping cream", "whipping cream",
            "double cream"
        ]),
        ("Smoked Paprika", ["smoked paprika", "smoked paprika powder"]),
        ("Paprika", ["paprika", "paprika powder"]),
        ("Black Pepper", [
            "pepper", "black pepper", "ground black pepper", "black pepper ground", "black pepper powder",
            "fresh ground black pepper", "freshly ground black pepper", "cracked black pepper",
            "freshly cracked black pepper", "coarse ground black pepper", "fresh black pepper"
        ]),
        ("Garlic Powder", ["garlic powder", "garlic granules", "granulated garlic"]),
        ("Onion Powder", ["onion powder", "onion granules", "granulated onion"]),
        ("Cinnamon", ["cinnamon", "ground cinnamon", "cinnamon powder"]),
        ("Cumin", ["cumin", "ground cumin", "cumin powder"]),
        ("Ground Coriander", ["ground coriander", "coriander powder"]),
        ("Nutmeg", ["nutmeg", "ground nutmeg", "nutmeg powder", "grated nutmeg", "grated whole nutmeg"]),
        ("Turmeric", ["turmeric", "ground turmeric", "turmeric powder"]),
        ("Cayenne Pepper", ["cayenne", "cayenne pepper", "cayenne powder"]),
        ("Chili Flakes", [
            "chili flakes", "chilli flakes", "red chili flakes", "red chilli flakes",
            "red pepper flakes", "crushed red pepper flakes", "crushed chili flakes",
            "crushed chilli flakes"
        ]),
        ("Parmesan", [
            "parmesan", "parmesan cheese", "grated parmesan", "grated parmesan cheese",
            "shredded parmesan", "shredded parmesan cheese", "parmesan grated",
            "parmesan cheese grated", "fresh parmesan cheese", "fresh grated parmesan",
            "fresh grated parmesan cheese", "finely grated parmesan"
        ]),
        ("Mozzarella", [
            "mozzarella", "mozzarella cheese", "shredded mozzarella",
            "shredded mozzarella cheese", "grated mozzarella", "grated mozzarella cheese"
        ]),
        ("Cheddar Cheese", [
            "cheddar", "cheddar cheese", "shredded cheddar", "shredded cheddar cheese",
            "grated cheddar", "grated cheddar cheese"
        ]),
        ("Green Onions", [
            "green onion", "green onions", "scallion", "scallions",
            "spring onion", "spring onions"
        ]),
        ("Cilantro", [
            "cilantro", "fresh cilantro", "cilantro leaves", "fresh cilantro leaves",
            "chopped cilantro", "coriander leaves", "fresh coriander",
            "fresh coriander leaves", "chopped coriander"
        ]),
        ("Parsley", [
            "parsley", "fresh parsley", "parsley fresh", "parsley chopped",
            "chopped parsley", "italian parsley", "flat leaf parsley"
        ]),
        ("Fresh Basil", ["basil", "fresh basil", "basil leaves", "fresh basil leaves"]),
        ("Fresh Dill", ["dill", "fresh dill", "dill leaves", "fresh dill leaves"]),
        ("Fresh Thyme", ["thyme", "fresh thyme", "thyme leaves", "fresh thyme leaves", "thyme sprigs", "fresh thyme sprigs"]),
        ("Fresh Rosemary", ["rosemary", "fresh rosemary", "rosemary sprig", "rosemary sprigs"]),
        ("Fresh Mint", ["mint", "fresh mint", "mint leaves", "fresh mint leaves"]),
        ("Red Onion", ["red onion", "red onions"]),
        ("Yellow Onion", ["yellow onion", "yellow onions"]),
        ("White Onion", ["white onion", "white onions"]),
        ("Cherry Tomatoes", ["cherry tomato", "cherry tomatoes"]),
        ("Jalapenos", ["jalapeno", "jalapenos", "jalapeño", "jalapeños", "jalapeno pepper", "jalapeño pepper"]),
        ("Celery", ["celery", "celery stalk", "celery stalks", "celery rib", "celery ribs", "diced celery"]),
        ("Broccoli", ["broccoli", "broccoli florets", "broccoli crown"]),
        ("Garlic", [
            "garlic", "fresh garlic", "garlic clove", "garlic cloves", "minced garlic",
            "garlic minced", "chopped garlic", "crushed garlic", "grated garlic",
            "minced garlic clove", "minced garlic cloves"
        ]),
        ("Granulated Sugar", ["sugar", "granulated sugar", "white sugar"]),
        ("Powdered Sugar", ["powdered sugar", "icing sugar", "confectioners sugar", "confectioner sugar"]),
        ("All-Purpose Flour", ["flour", "all purpose flour", "plain flour"]),
        ("Cornstarch", ["cornstarch", "corn starch", "cornflour", "corn flour"]),
        ("Panko Breadcrumbs", ["panko", "panko breadcrumbs", "panko bread crumbs"]),
        ("Breadcrumbs", ["breadcrumbs", "bread crumbs"]),
        ("Vanilla Extract", ["vanilla extract", "pure vanilla extract"]),
        ("Greek Yogurt", ["greek yogurt", "plain greek yogurt"]),
        ("Cream Cheese", ["cream cheese", "softened cream cheese", "cream cheese softened"]),
        ("Lemon Juice", ["lemon juice", "fresh lemon juice"]),
        ("Lime Juice", ["lime juice", "fresh lime juice"]),
        ("Unsalted Butter", ["unsalted butter"]),
        ("Salted Butter", ["salted butter"]),
        ("Butter", ["butter"]),
        ("Chicken Breast", [
            "chicken breast", "chicken breasts", "boneless chicken breast", "boneless chicken breasts",
            "boneless skinless chicken breast", "boneless skinless chicken breasts",
            "skinless chicken breast", "skinless chicken breasts", "diced chicken breast",
            "chicken breast fillet", "chicken breast fillets"
        ]),
        ("Chicken Thighs", [
            "chicken thigh", "chicken thighs", "boneless chicken thigh", "boneless chicken thighs",
            "boneless skinless chicken thigh", "boneless skinless chicken thighs",
            "skinless chicken thigh", "skinless chicken thighs", "chicken thigh fillet",
            "chicken thigh fillets"
        ]),
        ("Ground Chicken", ["ground chicken", "chicken mince", "minced chicken"]),
        ("Ground Beef", ["ground beef", "lean ground beef", "beef mince", "lean beef mince", "minced beef"]),
        ("Salmon Fillets", ["salmon", "salmon fillet", "salmon fillets", "salmon filet", "salmon filets"]),
        ("Shrimp", ["shrimp", "raw shrimp", "prawn", "prawns", "raw prawns"]),
        ("Chickpeas", ["chickpea", "chickpeas", "garbanzo bean", "garbanzo beans"]),
        ("Feta", ["feta", "feta cheese"]),
        ("Ricotta", ["ricotta", "ricotta cheese"]),
        ("Mascarpone", ["mascarpone", "mascarpone cheese"]),
        ("Halloumi", ["halloumi", "halloumi cheese"]),
        ("Burrata", ["burrata", "burrata cheese"]),
        ("Brie", ["brie", "brie cheese"]),
        ("Pecorino Romano", ["pecorino romano", "pecorino romano cheese"]),
        ("Chicken Broth", ["chicken broth", "chicken stock", "low sodium chicken broth", "low sodium chicken stock"]),
        ("Vegetable Broth", ["vegetable broth", "vegetable stock"]),
        ("Beef Broth", ["beef broth", "beef stock"]),
        ("Mayonnaise", ["mayonnaise", "mayo"]),
        ("BBQ Sauce", ["bbq sauce", "barbecue sauce"]),
        ("Rice Vinegar", ["rice vinegar", "rice wine vinegar"]),
        ("White Vinegar", ["white vinegar", "distilled white vinegar"]),
        ("Olive Oil", ["olive oil", "extra virgin olive oil"]),
        ("Sesame Seeds", ["sesame seed", "sesame seeds", "toasted sesame seed", "toasted sesame seeds", "roasted sesame seeds"]),
        ("Bay Leaves", ["bay leaf", "bay leaves"]),
        ("Sweet Potatoes", ["sweet potato", "sweet potatoes"]),
        ("Shallots", ["shallot", "shallots"]),
        ("Tomatoes", ["tomato", "tomatoes"]),
        ("Carrots", ["carrot", "carrots"]),
        ("Avocados", ["avocado", "avocados"])
    ]

    private static let aliases: [String: Match] = {
        var values: [String: Match] = [:]
        for family in aliasFamilies {
            let key = normalize(family.displayName)
            let match = Match(key: key, displayName: family.displayName)
            for alias in family.aliases {
                values[normalize(alias)] = match
            }
        }
        return values
    }()

    static func match(for value: String) -> Match {
        let normalized = normalize(value)
        if let exact = aliases[normalized] {
            return exact
        }

        let preparationWords: Set<String> = [
            "beaten", "boneless", "chopped", "coarsely", "cracked", "crushed", "diced",
            "divided", "finely", "fresh", "freshly", "grated", "large", "mashed",
            "medium", "melted", "minced", "optional", "packed", "peeled", "ripe",
            "roughly", "shredded", "skinless", "sliced", "small", "softened",
            "thickly", "thinly"
        ]
        let simplified = normalized
            .split(separator: " ")
            .map(String.init)
            .filter { !preparationWords.contains($0) }
            .joined(separator: " ")
        if let simplifiedMatch = aliases[simplified],
           !["tomatoes", "cherry tomatoes"].contains(simplifiedMatch.key) {
            return simplifiedMatch
        }

        let singularized = normalized
            .split(separator: " ")
            .map { singularize(String($0)) }
            .joined(separator: " ")
        if let exact = aliases[singularized] {
            return exact
        }

        let displayName = prettyName(singularized.isEmpty ? normalized : singularized)
        return Match(
            key: singularized.isEmpty ? normalized : singularized,
            displayName: displayName
        )
    }

    static func normalize(_ value: String) -> String {
        value
            .lowercased()
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func isNonShoppingWater(_ value: String) -> Bool {
        let tokens = normalize(value).split(separator: " ").map(String.init)
        guard tokens.contains("water") else { return false }

        let shoppableWaterWords: Set<String> = [
            "aloe", "blossom", "coconut", "mineral", "orange", "rose", "soda",
            "sparkling", "tonic", "vitamin"
        ]
        return tokens.allSatisfy { !shoppableWaterWords.contains($0) }
    }

    static func normalizedUnitKey(_ value: String) -> String {
        let normalized = normalize(value)
        switch normalized {
        case "tablespoon", "tablespoons", "tbsp": return "tbsp"
        case "teaspoon", "teaspoons", "tsp": return "tsp"
        case "cup", "cups": return "cup"
        case "ounce", "ounces": return "oz"
        case "pound", "pounds", "lb", "lbs": return "lb"
        case "gram", "grams": return "g"
        case "kilogram", "kilograms": return "kg"
        case "milliliter", "milliliters", "millilitre", "millilitres": return "ml"
        case "liter", "liters", "litre", "litres": return "l"
        case "fluid ounce", "fluid ounces", "fl oz": return "fl oz"
        case "count", "ct", "each", "item", "items", "unit", "units", "piece", "pieces",
             "clove", "cloves", "egg", "eggs", "breast", "breasts", "thigh", "thighs",
             "fillet", "fillets":
            return "item"
        default:
            // Imported recipes sometimes preserve an alternate measurement in
            // the unit, for example "g (2 cups)". The leading unit is the
            // authoritative denomination for the numeric amount.
            guard let leading = normalized.split(separator: " ").first.map(String.init) else {
                return normalized
            }
            switch leading {
            case "g", "gram", "grams": return "g"
            case "kg", "kilogram", "kilograms": return "kg"
            case "oz", "ounce", "ounces": return "oz"
            case "lb", "lbs", "pound", "pounds": return "lb"
            case "ml", "milliliter", "milliliters", "millilitre", "millilitres": return "ml"
            case "l", "liter", "liters", "litre", "litres": return "l"
            case "cup", "cups": return "cup"
            case "tbsp", "tablespoon", "tablespoons": return "tbsp"
            case "tsp", "teaspoon", "teaspoons": return "tsp"
            default: return normalized
            }
        }
    }

    static func measurementFamilyKey(_ unit: String) -> String {
        guard let conversion = unitConversion(for: unit) else {
            return "unit:\(normalizedUnitKey(unit))"
        }
        return conversion.family
    }

    static func convertedAmount(_ amount: Double, from sourceUnit: String, to targetUnit: String) -> Double? {
        guard let source = unitConversion(for: sourceUnit),
              let target = unitConversion(for: targetUnit),
              source.family == target.family
        else {
            return nil
        }
        return (amount * source.factor) / target.factor
    }

    static func resolvedMeasurement(amount: Double, unit: String) -> (amount: Double, unit: String) {
        guard let opening = unit.firstIndex(of: "("),
              let closing = unit[opening...].firstIndex(of: ")"),
              opening < closing
        else {
            return (amount, unit)
        }

        let alternateText = String(unit[unit.index(after: opening)..<closing])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let tokens = alternateText.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard let firstToken = tokens.first,
              let firstAmount = parseMeasurementNumber(firstToken)
        else {
            return (amount, unit)
        }

        var alternateAmount = firstAmount
        var unitStartIndex = 1
        if tokens.count > 2,
           let fractionalAmount = parseMeasurementNumber(tokens[1]),
           tokens[1].contains("/") {
            alternateAmount += fractionalAmount
            unitStartIndex = 2
        }
        guard unitStartIndex < tokens.count else {
            return (amount, unit)
        }

        let alternateUnit = tokens[unitStartIndex...].joined(separator: " ")
        guard let primary = unitConversion(for: unit),
              let alternate = unitConversion(for: alternateUnit),
              primary.family != alternate.family
        else {
            return (amount, unit)
        }
        return (alternateAmount, alternateUnit)
    }

    static func mergedMeasurement(
        amount existingAmount: Double,
        unit existingUnit: String,
        adding newAmount: Double,
        unit newUnit: String
    ) -> (amount: Double, unit: String) {
        let preferredUnit = measurementUnitPreference(newUnit) > measurementUnitPreference(existingUnit)
            ? newUnit
            : existingUnit

        if let convertedExisting = convertedAmount(existingAmount, from: existingUnit, to: preferredUnit),
           let convertedNew = convertedAmount(newAmount, from: newUnit, to: preferredUnit) {
            return (convertedExisting + convertedNew, preferredUnit)
        }

        // A unitless parser fallback such as "2 items" must never create a
        // second row or inflate a real recipe measurement such as "1 tsp".
        if measurementUnitPreference(newUnit) > measurementUnitPreference(existingUnit) {
            return (newAmount, newUnit)
        }
        return (existingAmount, existingUnit)
    }

    private static func measurementUnitPreference(_ value: String) -> Int {
        let normalized = normalize(value)
        if normalized.isEmpty || [
            "count", "ct", "each", "item", "items", "unit", "units", "piece", "pieces"
        ].contains(normalized) {
            return 0
        }
        if [
            "bottle", "bottles", "jar", "jars", "can", "cans", "bag", "bags",
            "pack", "packs", "carton", "cartons", "tub", "tubs"
        ].contains(normalized) {
            return 1
        }
        switch unitConversion(for: value)?.family {
        case "count": return 2
        case "volume": return 3
        case "mass": return 4
        default: return 2
        }
    }

    private static func unitConversion(for value: String) -> (family: String, factor: Double)? {
        switch normalizedUnitKey(value) {
        case "tsp": return ("volume", 1)
        case "tbsp": return ("volume", 3)
        case "fl oz": return ("volume", 6)
        case "cup": return ("volume", 48)
        case "ml": return ("volume", 0.202884)
        case "l": return ("volume", 202.884)
        case "g": return ("mass", 1)
        case "kg": return ("mass", 1_000)
        case "oz": return ("mass", 28.3495)
        case "lb": return ("mass", 453.592)
        case "item": return ("count", 1)
        default: return nil
        }
    }

    private static func parseMeasurementNumber(_ value: String) -> Double? {
        let cleaned = value.trimmingCharacters(in: CharacterSet(charactersIn: ",;"))
        if cleaned.contains("/") {
            let parts = cleaned.split(separator: "/")
            guard parts.count == 2,
                  let numerator = Double(parts[0]),
                  let denominator = Double(parts[1]),
                  denominator != 0
            else {
                return nil
            }
            return numerator / denominator
        }
        return Double(cleaned)
    }

    private static func singularize(_ token: String) -> String {
        if token == "tomatoes" { return "tomato" }
        if token == "potatoes" { return "potato" }
        if token == "avocados" { return "avocado" }
        if token == "onions" { return "onion" }
        if token == "thighs" { return "thigh" }
        if token == "breasts" { return "breast" }
        if token.hasSuffix("ies"), token.count > 4 {
            return String(token.dropLast(3)) + "y"
        }
        if token.hasSuffix("s"), token.count > 3, !token.hasSuffix("ss") {
            return String(token.dropLast())
        }
        return token
    }

    private static func prettyName(_ value: String) -> String {
        value
            .split(separator: " ")
            .map { token in
                let lowered = token.lowercased()
                return ["bbq", "caesar"].contains(lowered) ? lowered.uppercased() : lowered.capitalized
            }
            .joined(separator: " ")
    }
}

enum MainShopSnapshotBuilder {
    static func signature(for groceryItems: [GroceryItem]) -> String {
        let itemSignature = groceryItems
            .map { item in
                let normalizedName = normalizedIngredientKey(item.name)
                let normalizedUnit = item.unit.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let normalizedAmount = String(format: "%.4f", item.amount)
                let sources = item.sourceIngredients
                    .map {
                        [
                            normalizedIngredientKey($0.recipeID),
                            normalizedIngredientKey($0.ingredientName),
                            $0.unit.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                        ]
                        .joined(separator: "::")
                    }
                    .sorted()
                    .joined(separator: "|")
                return "\(normalizedName)::\(normalizedAmount)::\(normalizedUnit)::\(sources)"
            }
            .sorted()
            .joined(separator: "||")
        return "canonical-cart-v7::\(itemSignature)"
    }

    static func buildLocalSnapshot(
        for groceryItems: [GroceryItem],
        imageLookup: [String: String] = [:]
    ) -> MainShopSnapshot {
        let items = sortedSnapshotItems(
            mergeLexicallyIdenticalSnapshotItems(
                ensuringCoverage(
                    snapshotItems: [],
                    groceryItems: groceryItems,
                    imageLookup: imageLookup,
                    ownedItemKeys: []
                )
            )
        )
        return MainShopSnapshot(
            signature: signature(for: groceryItems),
            generatedAt: .now,
            items: items,
            coverageSummary: nil
        )
    }

    static func buildSnapshot(
        for plan: MealPlan,
        profile: UserProfile? = nil,
        refreshToken: String? = nil,
        accessToken: String? = nil
    ) async throws -> MainShopSnapshot {
        guard !plan.groceryItems.isEmpty else {
            return MainShopSnapshot(
                signature: signature(for: plan.groceryItems),
                generatedAt: .now,
                items: [],
                coverageSummary: nil
            )
        }

        // "Already have" is scoped to the current cart in CartTabView. A fresh
        // reconciliation must always start from the plan's complete demand.
        let ownedItemKeys = Set<String>()
        let shoppingSpec = try await GroceryService.shared.fetchShoppingSpec(
            items: plan.groceryItems,
            plan: plan,
            refreshToken: refreshToken,
            accessToken: accessToken
        )
        let normalizedNames = Array(
            Set(
                candidateImageNames(for: shoppingSpec.items)
                + plan.groceryItems.flatMap { item in
                    [item.name] + item.sourceIngredients.map(\.ingredientName)
                }
                .map(normalizedIngredientKey)
                .filter { !$0.isEmpty }
            )
        ).sorted()
        let imageLookup = try await SupabaseIngredientsCatalogService.shared.fetchImageLookup(
            normalizedNames: normalizedNames
        )

        let derivedItems = shoppingSpec.items.compactMap { item in
            snapshotItem(for: item, imageLookup: imageLookup, ownedItemKeys: ownedItemKeys)
        }
        let recipeDemandItems = ensuringCoverage(
            snapshotItems: [],
            groceryItems: plan.groceryItems,
            imageLookup: imageLookup,
            ownedItemKeys: ownedItemKeys
        )
        let items = sortedSnapshotItems(
            mergeLexicallyIdenticalSnapshotItems(
                applyingShoppingMetadata(
                    to: recipeDemandItems,
                    from: derivedItems
                )
            )
        )

        return MainShopSnapshot(
            signature: signature(for: plan.groceryItems),
            generatedAt: .now,
            items: items,
            coverageSummary: MainShopCoverageSummary(
                totalBaseUses: shoppingSpec.coverageSummary.totalBaseUses,
                accountedBaseUses: shoppingSpec.coverageSummary.accountedBaseUses,
                uncoveredBaseLabels: shoppingSpec.coverageSummary.uncoveredBaseLabels
            )
        )
    }

    private static func candidateImageNames(for items: [GroceryShoppingSpecResponse.ShoppingSpecItem]) -> [String] {
        var names: [String] = []
        for item in items {
            names.append(contentsOf: [
                item.shoppingContext?.canonicalName,
                item.shoppingContext?.canonicalKey,
                item.canonicalName,
                item.canonicalKey,
                item.originalName,
                item.name,
            ].compactMap { $0 })
            names.append(contentsOf: item.sourceIngredients.map(\.ingredientName))
            names.append(contentsOf: item.shoppingContext?.sourceIngredientNames ?? [])
        }
        return Array(
            Set(
                names
                    .map { normalizedIngredientKey($0) }
                    .filter { !$0.isEmpty }
            )
        ).sorted()
    }

    private static func snapshotItem(
        for item: GroceryShoppingSpecResponse.ShoppingSpecItem,
        imageLookup: [String: String],
        ownedItemKeys: Set<String>
    ) -> MainShopSnapshotItem? {
        let rawName = item.shoppingContext?.canonicalName ?? item.canonicalName ?? item.name
        let displayName = canonicalMainShopDisplayName(rawName)
        let localCanonicalKey = semanticMainShopMergeKey(rawName)
        let canonicalKey = localCanonicalKey.isEmpty
            ? item.canonicalKey ?? item.shoppingContext?.canonicalKey ?? ""
            : localCanonicalKey
        guard !isExcludedMainShopIngredient(displayName),
              !isOwnedMainShopIngredient(displayName, canonicalKey: canonicalKey, ownedItemKeys: ownedItemKeys)
        else { return nil }

        let quantityText = formattedQuantity(amount: item.amount, unit: item.unit)
        let sourceUseCount = max(1, Set(item.sourceIngredients.map {
            "\(normalizedIngredientKey($0.recipeID))::\(normalizedIngredientKey($0.ingredientName))::\($0.unit.lowercased())"
        }).count)
        let recipeCount = Set((item.shoppingContext?.recipeTitles ?? []) + item.sourceRecipes).count
        let supportingParts = coverageSupportingParts(sourceUseCount: sourceUseCount, recipeCount: recipeCount)
        let isPantryStaple = item.shoppingContext?.isPantryStaple ?? false
        let isOptional = item.shoppingContext?.isOptional ?? false
        let sectionKindRawValue = sectionKindRawValue(
            displayName: displayName,
            role: item.shoppingContext?.role ?? "ingredient",
            isPantryStaple: isPantryStaple,
            isOptional: isOptional,
            combinedContext: [
                item.shoppingContext?.canonicalName,
                item.name,
                item.shoppingContext?.sourceIngredientNames.joined(separator: " "),
                item.sourceIngredients.map(\.ingredientName).joined(separator: " ")
            ]
            .compactMap { $0 }
            .joined(separator: " ")
        )

        let imageURLString = imageLookup[
            normalizedIngredientKey(rawName)
        ] ?? imageLookup[
            normalizedIngredientKey(displayName)
        ] ?? imageLookup[
            normalizedIngredientKey(item.name)
        ]

        return MainShopSnapshotItem(
            name: displayName,
            quantityText: quantityText,
            supportingText: supportingParts.isEmpty ? nil : supportingParts.joined(separator: " • "),
            imageURLString: imageURLString,
            estimatedPriceText: nil,
            estimatedPriceValue: 0,
            sectionKindRawValue: sectionKindRawValue,
            removalKey: normalizedIngredientKey(displayName),
            canonicalKey: canonicalKey.isEmpty ? nil : canonicalKey,
            sourceIngredients: item.sourceIngredients,
            sourceEdgeIDs: item.sourceEdgeIDs ?? item.shoppingContext?.sourceEdgeIDs,
            alternativeNames: item.alternativeNames ?? item.shoppingContext?.alternativeNames,
            coverageState: item.coverageState ?? item.shoppingContext?.coverageState
        )
    }

    private static func ensuringCoverage(
        snapshotItems: [MainShopSnapshotItem],
        groceryItems: [GroceryItem],
        imageLookup: [String: String],
        ownedItemKeys: Set<String>
    ) -> [MainShopSnapshotItem] {
        var resolvedItems = snapshotItems

        for groceryItem in groceryItems {
            let displayName = canonicalMainShopDisplayName(groceryItem.name)
            let canonicalKey = semanticMainShopMergeKey(groceryItem.name)
            guard !canonicalKey.isEmpty else { continue }
            guard !isExcludedMainShopIngredient(displayName),
                  !isOwnedMainShopIngredient(displayName, canonicalKey: canonicalKey, ownedItemKeys: ownedItemKeys)
            else { continue }

            var coverageKeys = Set<String>()
            let sourceEdgeIDs = Set(groceryItem.sourceIngredients.map(sourceEdgeID).filter { !$0.isEmpty })
            coverageKeys.insert(canonicalKey)
            coverageKeys.insert(semanticMainShopMergeKey(groceryItem.name))
            for source in groceryItem.sourceIngredients {
                let normalizedSource = normalizedIngredientKey(source.ingredientName)
                if !normalizedSource.isEmpty {
                    coverageKeys.insert(normalizedSource)
                }
                let semanticSource = semanticMainShopMergeKey(source.ingredientName)
                if !semanticSource.isEmpty {
                    coverageKeys.insert(semanticSource)
                }
            }

            let isRepresented = resolvedItems.contains { item in
                let snapshotSourceEdgeIDs = Set(item.sourceEdgeIDs ?? [])
                if !sourceEdgeIDs.isEmpty, !snapshotSourceEdgeIDs.isDisjoint(with: sourceEdgeIDs) {
                    return true
                }
                var itemKeys = Set<String>()
                let normalizedName = normalizedIngredientKey(item.name)
                if !normalizedName.isEmpty {
                    itemKeys.insert(normalizedName)
                }
                let semanticName = semanticMainShopMergeKey(item.name)
                if !semanticName.isEmpty {
                    itemKeys.insert(semanticName)
                }
                let normalizedCanonical = normalizedIngredientKey(item.canonicalKey ?? "")
                if !normalizedCanonical.isEmpty {
                    itemKeys.insert(normalizedCanonical)
                }
                let semanticCanonical = semanticMainShopMergeKey(item.canonicalKey ?? "")
                if !semanticCanonical.isEmpty {
                    itemKeys.insert(semanticCanonical)
                }
                for source in item.sourceIngredients ?? [] {
                    let normalizedSource = normalizedIngredientKey(source.ingredientName)
                    if !normalizedSource.isEmpty {
                        itemKeys.insert(normalizedSource)
                    }
                    let semanticSource = semanticMainShopMergeKey(source.ingredientName)
                    if !semanticSource.isEmpty {
                        itemKeys.insert(semanticSource)
                    }
                }
                return !itemKeys.isDisjoint(with: coverageKeys)
            }

            guard !isRepresented else { continue }

            let sourceUseCount = max(
                1,
                Set(groceryItem.sourceIngredients.map {
                    "\(normalizedIngredientKey($0.recipeID))::\(normalizedIngredientKey($0.ingredientName))::\($0.unit.lowercased())"
                })
                .count
            )
            let recipeCount = Set(
                groceryItem.sourceIngredients
                    .map(\.recipeID)
                    .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            ).count
            let supportingParts = coverageSupportingParts(sourceUseCount: sourceUseCount, recipeCount: recipeCount)
            let sectionKind = sectionKindRawValue(
                displayName: displayName,
                role: "ingredient",
                isPantryStaple: false,
                isOptional: false,
                combinedContext: (
                    [groceryItem.name] + groceryItem.sourceIngredients.map(\.ingredientName)
                )
                .joined(separator: " ")
            )
            let imageURLString = imageLookup[canonicalKey]
                ?? imageLookup[normalizedIngredientKey(displayName)]
            let quantityText = formattedQuantity(amount: groceryItem.amount, unit: groceryItem.unit)

            resolvedItems.append(
                MainShopSnapshotItem(
                    name: displayName,
                    quantityText: quantityText,
                    supportingText: supportingParts.isEmpty ? nil : supportingParts.joined(separator: " • "),
                    imageURLString: imageURLString,
                    estimatedPriceText: nil,
                    estimatedPriceValue: groceryItem.estimatedPrice,
                    sectionKindRawValue: sectionKind,
                    removalKey: canonicalKey,
                    canonicalKey: canonicalKey,
                    sourceIngredients: groceryItem.sourceIngredients,
                    sourceEdgeIDs: Array(sourceEdgeIDs).sorted(),
                    alternativeNames: nil,
                    coverageState: sourceEdgeIDs.isEmpty ? "fallback" : "covered"
                )
            )
        }

        return resolvedItems
    }

    private static func applyingShoppingMetadata(
        to demandItems: [MainShopSnapshotItem],
        from metadataItems: [MainShopSnapshotItem]
    ) -> [MainShopSnapshotItem] {
        let metadataByKey = Dictionary(grouping: metadataItems) { item in
            semanticMainShopMergeKey(item.canonicalKey ?? item.name)
        }

        return demandItems.map { demandItem in
            let key = semanticMainShopMergeKey(demandItem.canonicalKey ?? demandItem.name)
            guard let candidates = metadataByKey[key],
                  let metadata = candidates.max(by: {
                      $0.name.count < $1.name.count
                  })
            else {
                return demandItem
            }

            return MainShopSnapshotItem(
                name: canonicalMainShopDisplayName(demandItem.name),
                quantityText: demandItem.quantityText,
                supportingText: demandItem.supportingText ?? metadata.supportingText,
                imageURLString: demandItem.imageURLString ?? metadata.imageURLString,
                estimatedPriceText: metadata.estimatedPriceText ?? demandItem.estimatedPriceText,
                estimatedPriceValue: max(demandItem.estimatedPriceValue, metadata.estimatedPriceValue),
                sectionKindRawValue: metadata.sectionKindRawValue ?? demandItem.sectionKindRawValue,
                removalKey: key,
                canonicalKey: key,
                sourceIngredients: demandItem.sourceIngredients,
                sourceEdgeIDs: demandItem.sourceEdgeIDs ?? metadata.sourceEdgeIDs,
                alternativeNames: Array(
                    Set((demandItem.alternativeNames ?? []) + (metadata.alternativeNames ?? []))
                ).sorted(),
                coverageState: demandItem.coverageState ?? metadata.coverageState
            )
        }
    }

    private static func ownedMainShopItemKeys(from profile: UserProfile?) -> Set<String> {
        Set(
            (profile?.ownedMainShopItems ?? [])
                .map(normalizedIngredientKey)
                .filter { !$0.isEmpty }
        )
    }

    private static func isOwnedMainShopIngredient(
        _ value: String,
        canonicalKey: String,
        ownedItemKeys: Set<String>
    ) -> Bool {
        guard !ownedItemKeys.isEmpty else { return false }

        let normalized = normalizedIngredientKey(value)
        let semanticKey = semanticMainShopMergeKey(value)
        let candidateKeys = Set([normalized, canonicalKey, semanticKey].filter { !$0.isEmpty })
        guard !candidateKeys.isEmpty else { return false }

        return ownedItemKeys.contains { ownedKey in
            candidateKeys.contains(where: { candidateKey in
                ownedKey == candidateKey
                    || ownedKey.contains(candidateKey)
                    || candidateKey.contains(ownedKey)
            })
        }
    }

    private static func sortedSnapshotItems(_ items: [MainShopSnapshotItem]) -> [MainShopSnapshotItem] {
        items.sorted { lhs, rhs in
            let lhsSection = lhs.sectionKindRawValue ?? Int.max
            let rhsSection = rhs.sectionKindRawValue ?? Int.max
            if lhsSection != rhsSection {
                return lhsSection < rhsSection
            }

            let lhsName = lhs.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let rhsName = rhs.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let nameComparison = lhsName.localizedCaseInsensitiveCompare(rhsName)
            if nameComparison != .orderedSame {
                return nameComparison == .orderedAscending
            }

            let lhsQuantity = lhs.quantityText.trimmingCharacters(in: .whitespacesAndNewlines)
            let rhsQuantity = rhs.quantityText.trimmingCharacters(in: .whitespacesAndNewlines)
            return lhsQuantity.localizedCaseInsensitiveCompare(rhsQuantity) == .orderedAscending
        }
    }

    private static func mergeLexicallyIdenticalSnapshotItems(_ items: [MainShopSnapshotItem]) -> [MainShopSnapshotItem] {
        struct Aggregate {
            var item: MainShopSnapshotItem
            var amount: Double
            var unitLabel: String
            var supportingParts: Set<String>
        }

        var aggregates: [String: Aggregate] = [:]
        var order: [String] = []

        for item in items {
            guard !isExcludedMainShopIngredient(item.name) else { continue }
            let parsed = parsedDisplayQuantity(item.quantityText)
            let resolvedMeasurement = ShoppingIngredientCanonicalizer.resolvedMeasurement(
                amount: parsed?.amount ?? 1,
                unit: parsed?.unitLabel ?? "items"
            )
            let rawUnit = resolvedMeasurement.unit
            let ingredientKey = semanticMainShopMergeKey(item.canonicalKey ?? item.name)
            guard !ingredientKey.isEmpty else { continue }
            let key = ingredientKey

            let amount = max(0, resolvedMeasurement.amount)
            if var existing = aggregates[key] {
                let mergedMeasurement = ShoppingIngredientCanonicalizer.mergedMeasurement(
                    amount: existing.amount,
                    unit: existing.unitLabel,
                    adding: amount,
                    unit: rawUnit
                )
                existing.amount = mergedMeasurement.amount
                existing.unitLabel = normalizedMainShopUnitLabel(
                    mergedMeasurement.unit,
                    count: max(1, Int(ceil(mergedMeasurement.amount)))
                )
                existing.supportingParts.formUnion(splitSupportingText(item.supportingText))
                let preferredItem = preferredMergedSnapshotItem(existing.item, item)
                let combinedSources = mergedSourceIngredients(
                    existing.item.sourceIngredients ?? [],
                    item.sourceIngredients ?? []
                )
                let combinedSourceEdgeIDs = Array(Set((existing.item.sourceEdgeIDs ?? []) + (item.sourceEdgeIDs ?? []))).sorted()
                let combinedAlternativeNames = Array(Set((existing.item.alternativeNames ?? []) + (item.alternativeNames ?? []))).sorted()
                let resolvedName = canonicalMainShopDisplayName(preferredItem.name)
                existing.item = MainShopSnapshotItem(
                    name: resolvedName,
                    quantityText: formattedQuantity(amount: existing.amount, unit: existing.unitLabel),
                    supportingText: combinedSupportingText(from: existing.supportingParts),
                    imageURLString: preferredItem.imageURLString ?? existing.item.imageURLString ?? item.imageURLString,
                    estimatedPriceText: preferredItem.estimatedPriceText ?? existing.item.estimatedPriceText ?? item.estimatedPriceText,
                    estimatedPriceValue: existing.item.estimatedPriceValue + item.estimatedPriceValue,
                    sectionKindRawValue: min(preferredItem.sectionKindRawValue ?? Int.max, existing.item.sectionKindRawValue ?? Int.max),
                    removalKey: ingredientKey,
                    canonicalKey: ingredientKey,
                    sourceIngredients: combinedSources,
                    sourceEdgeIDs: combinedSourceEdgeIDs.isEmpty ? nil : combinedSourceEdgeIDs,
                    alternativeNames: combinedAlternativeNames.isEmpty ? nil : combinedAlternativeNames,
                    coverageState: combinedSourceEdgeIDs.isEmpty ? existing.item.coverageState ?? item.coverageState : "covered"
                )
                aggregates[key] = existing
            } else {
                let unitLabel = normalizedMainShopUnitLabel(rawUnit, count: max(1, Int(ceil(amount))))
                let resolvedName = canonicalMainShopDisplayName(item.name)
                aggregates[key] = Aggregate(
                    item: MainShopSnapshotItem(
                        name: resolvedName,
                        quantityText: formattedQuantity(amount: amount, unit: unitLabel),
                        supportingText: item.supportingText,
                        imageURLString: item.imageURLString,
                        estimatedPriceText: item.estimatedPriceText,
                        estimatedPriceValue: item.estimatedPriceValue,
                        sectionKindRawValue: item.sectionKindRawValue,
                        removalKey: ingredientKey,
                        canonicalKey: ingredientKey,
                        sourceIngredients: item.sourceIngredients,
                        sourceEdgeIDs: item.sourceEdgeIDs,
                        alternativeNames: item.alternativeNames,
                        coverageState: item.coverageState
                    ),
                    amount: amount,
                    unitLabel: unitLabel,
                    supportingParts: splitSupportingText(item.supportingText)
                )
                order.append(key)
            }
        }

        return order.compactMap { aggregates[$0]?.item }
    }

    private static func splitSupportingText(_ value: String?) -> Set<String> {
        guard let value else { return [] }
        return Set(
            value
                .split(separator: "•")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter {
                    !$0.isEmpty
                    && $0.caseInsensitiveCompare("Pantry check") != .orderedSame
                }
        )
    }

    private static func combinedSupportingText(from parts: Set<String>) -> String? {
        guard !parts.isEmpty else { return nil }
        return parts.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }.joined(separator: " • ")
    }

    private static func coverageSupportingParts(sourceUseCount: Int, recipeCount: Int) -> [String] {
        switch (sourceUseCount > 1, recipeCount > 1) {
        case (_, true):
            return ["Used in \(recipeCount) recipes"]
        case (true, false):
            return ["Used \(sourceUseCount)x in this prep"]
        case (false, false):
            return []
        }
    }

    private static func formattedQuantity(amount: Double, unit: String) -> String {
        let normalizedUnit = unit.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let roundedAmount = normalizedAmount(amount)

        if ["oz", "ounce", "ounces"].contains(normalizedUnit),
           amount >= 16,
           amount.truncatingRemainder(dividingBy: 16) == 0 {
            let pounds = amount / 16
            return "\(normalizedAmount(pounds)) lb"
        }

        if normalizedUnit == "ct" || normalizedUnit == "count" {
            let label = amount == 1 ? "item" : "items"
            return "\(roundedAmount) \(label)"
        }

        if normalizedUnit.isEmpty {
            return roundedAmount
        }

        return "\(roundedAmount) \(unit)"
    }

    private static func parsedDisplayQuantity(_ quantityText: String) -> (amount: Double, roundedCount: Int, unitLabel: String)? {
        let trimmed = quantityText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let tokens = trimmed.split(separator: " ").map(String.init)
        guard let first = tokens.first else { return nil }

        let numericParts = first
            .split(separator: "-")
            .compactMap { parseNumericToken(String($0)) }
        guard !numericParts.isEmpty else { return nil }

        let baseAmount = numericParts.max() ?? 1
        let roundedCount = max(1, Int(ceil(baseAmount)))
        let unitTokens = Array(tokens.dropFirst())
        let unitLabel = unitTokens.isEmpty ? "units" : unitTokens.joined(separator: " ")
        return (baseAmount, roundedCount, unitLabel)
    }

    private static func parseNumericToken(_ token: String) -> Double? {
        let cleaned = token.trimmingCharacters(in: CharacterSet(charactersIn: ",()"))
        guard !cleaned.isEmpty else { return nil }

        if cleaned.contains("/") {
            let parts = cleaned.split(separator: "/")
            guard parts.count == 2,
                  let numerator = Double(parts[0]),
                  let denominator = Double(parts[1]),
                  denominator != 0
            else {
                return nil
            }
            return numerator / denominator
        }

        return Double(cleaned)
    }

    private static func normalizedAmount(_ value: Double) -> String {
        if abs(value.rounded() - value) < 0.001 {
            return String(Int(value.rounded()))
        }
        return value.roundedString(1)
    }

    private static func normalizedMainShopUnitLabel(_ rawLabel: String, count: Int) -> String {
        let normalized = rawLabel.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else {
            return count == 1 ? "item" : "items"
        }

        let singularToPlural: [String: String] = [
            "item": "items",
            "bottle": "bottles",
            "jar": "jars",
            "can": "cans",
            "bag": "bags",
            "pack": "packs",
            "head": "heads",
            "bunch": "bunches",
            "carton": "cartons",
            "tub": "tubs",
            "clove": "cloves"
        ]
        let pluralToSingular = Dictionary(uniqueKeysWithValues: singularToPlural.map { ($1, $0) })

        if count == 1 {
            return pluralToSingular[normalized] ?? normalized
        }
        return singularToPlural[normalized] ?? normalized
    }

    private static func normalizedIngredientKey(_ value: String) -> String {
        value
            .lowercased()
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func canonicalMainShopDisplayName(_ rawName: String) -> String {
        ShoppingIngredientCanonicalizer.match(for: rawName).displayName
    }

    private static func semanticMainShopMergeKey(_ value: String) -> String {
        ShoppingIngredientCanonicalizer.match(for: value).key
    }

    private static func normalizedMainShopToken(_ value: String) -> String {
        let token = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !token.isEmpty else { return "" }
        if token == "tomatoes" { return "tomato" }
        if token == "potatoes" { return "potato" }
        if token == "avocados" { return "avocado" }
        if token == "onions" { return "onion" }
        if token == "thighs" { return "thigh" }
        if token == "breasts" { return "breast" }
        if token.hasSuffix("ies"), token.count > 4 {
            return String(token.dropLast(3)) + "y"
        }
        if token.hasSuffix("s"), token.count > 3, !token.hasSuffix("ss") {
            return String(token.dropLast())
        }
        return token
    }

    private static func isExcludedMainShopIngredient(_ value: String) -> Bool {
        ShoppingIngredientCanonicalizer.isNonShoppingWater(value)
    }

    private static func mergedSourceIngredients(
        _ lhs: [GroceryItemSource],
        _ rhs: [GroceryItemSource]
    ) -> [GroceryItemSource] {
        var seen = Set<String>()
        var merged: [GroceryItemSource] = []
        for source in lhs + rhs {
            let key = [
                normalizedIngredientKey(source.recipeID),
                normalizedIngredientKey(source.ingredientName),
                normalizedIngredientKey(source.unit)
            ].joined(separator: "::")
            guard seen.insert(key).inserted else { continue }
            merged.append(source)
        }
        return merged
    }

    private static func sourceEdgeID(_ source: GroceryItemSource) -> String {
        let recipeID = normalizedIngredientKey(source.recipeID)
        let ingredientName = normalizedIngredientKey(source.ingredientName)
        let unit = normalizedIngredientKey(source.unit)
        guard !recipeID.isEmpty, !ingredientName.isEmpty else { return "" }
        return "\(recipeID)::\(ingredientName)::\(unit)"
    }

    private static func preferredMergedSnapshotItem(_ lhs: MainShopSnapshotItem, _ rhs: MainShopSnapshotItem) -> MainShopSnapshotItem {
        let lhsScore = displaySpecificityScore(lhs.name)
        let rhsScore = displaySpecificityScore(rhs.name)
        if lhsScore == rhsScore {
            return lhs.name.count >= rhs.name.count ? lhs : rhs
        }
        return lhsScore >= rhsScore ? lhs : rhs
    }

    private static func displaySpecificityScore(_ value: String) -> Int {
        let normalized = normalizedIngredientKey(value)
        guard !normalized.isEmpty else { return 0 }
        let tokenCount = normalized.split(separator: " ").count
        let abbreviationPenalty = normalized.count <= 3 ? 50 : 0
        return tokenCount * 20 + normalized.count - abbreviationPenalty
    }

    private static func prettyShoppingName(_ rawName: String) -> String {
        rawName
            .split(separator: " ")
            .map { token in
                let lowered = token.lowercased()
                return ["bbq", "caesar"].contains(lowered) ? lowered.uppercased() : lowered.capitalized
            }
            .joined(separator: " ")
    }

    private static func sectionKindRawValue(
        displayName: String,
        role: String,
        isPantryStaple: Bool,
        isOptional: Bool,
        combinedContext: String
    ) -> Int {
        if isOptional { return 4 }
        if isPantryStaple { return 3 }

        switch role.lowercased() {
        case "protein":
            return 0
        case "dairy":
            return 0
        case "sauce":
            return 2
        case "wrapper", "pantry":
            return 1
        case "fresh garnish", "salad base":
            return 0
        case "cooking tool":
            return 5
        default:
            break
        }

        let normalizedName = normalizedIngredientKey(displayName)
        if combinedContext.contains("sauce")
            || combinedContext.contains("dressing")
            || combinedContext.contains("marinade")
            || combinedContext.contains("dip") {
            return 2
        }
        if normalizedName.contains("skewer") || normalizedName.contains("toothpick") {
            return 5
        }
        if normalizedName.contains("rice")
            || normalizedName.contains("flour")
            || normalizedName.contains("sugar")
            || normalizedName.contains("chips")
            || normalizedName.contains("beans")
            || normalizedName.contains("stock")
            || normalizedName.contains("broth")
            || normalizedName.contains("powder")
            || normalizedName.contains("granules")
            || normalizedName.contains("seasoning")
            || normalizedName.contains("paprika")
            || normalizedName.contains("cayenne")
            || normalizedName.contains("black pepper")
            || normalizedName.contains("peppercorn")
            || normalizedName.contains("chili flakes")
            || normalizedName.contains("red pepper flakes")
            || normalizedName.contains("cumin")
            || normalizedName.contains("turmeric")
            || normalizedName.contains("cinnamon") {
            return 1
        }
        if normalizedName.contains("romaine")
            || normalizedName.contains("greens")
            || normalizedName.contains("lettuce")
            || normalizedName.contains("cilantro")
            || normalizedName.contains("green onions")
            || normalizedName.contains("scallions")
            || normalizedName.contains("jalape")
            || normalizedName.contains("garlic")
            || normalizedName.contains("carrot")
            || normalizedName.contains("cucumber")
            || normalizedName.contains("apple")
            || normalizedName.contains("avocado")
            || normalizedName.contains("blueberr")
            || normalizedName.contains("broccoli")
            || normalizedName.contains("tomato") {
            return 0
        }
        if normalizedName.contains("chicken")
            || normalizedName.contains("shrimp")
            || normalizedName.contains("salmon")
            || normalizedName.contains("steak")
            || normalizedName.contains("egg") {
            return 0
        }
        if normalizedName.contains("cheese")
            || normalizedName.contains("yogurt")
            || normalizedName.contains("milk")
            || normalizedName.contains("cream") {
            return 0
        }
        return 0
    }
}
