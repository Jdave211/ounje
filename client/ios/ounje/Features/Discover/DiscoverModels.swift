import SwiftUI
import Foundation

enum DiscoverPreset: CaseIterable {
    case all
    case breakfast
    case lunch
    case dinner
    case dessert
    case drinks
    case vegetarian
    case vegan
    case pasta
    case chicken
    case steak
    case fish
    case salad
    case sandwich
    case beans
    case potatoes
    case salmon
    case nigerian
    case beginner
    case under500Cal

    var title: String {
        switch self {
        case .all: return "Feed"
        case .breakfast: return "Breakfast"
        case .lunch: return "Lunch"
        case .dinner: return "Dinner"
        case .dessert: return "Dessert"
        case .drinks: return "Drinks"
        case .vegetarian: return "Vegetarian"
        case .vegan: return "Vegan"
        case .pasta: return "Pasta"
        case .chicken: return "Chicken"
        case .steak: return "Steak"
        case .fish: return "Fish"
        case .salad: return "Salad"
        case .sandwich: return "Sandwich"
        case .beans: return "Beans"
        case .potatoes: return "Potatoes"
        case .salmon: return "Salmon"
        case .nigerian: return "Nigerian"
        case .beginner: return "Beginner"
        case .under500Cal: return "Under 500 Cal"
        }
    }

    static var allTitles: [String] {
        DiscoverPreset.allCases.map(\.title)
    }

    static func shuffledTitles(seed: String) -> [String] {
        shuffledTitles(DiscoverPreset.allCases.map(\.title), seed: seed)
    }

    static func shuffledTitles(_ titles: [String], seed: String) -> [String] {
        guard let allTitle = titles.first else { return [] }

        let remainingTitles = Array(titles.dropFirst())
        guard !remainingTitles.isEmpty else { return [allTitle] }

        var generator = SeededTitleGenerator(seed: stableSeed(from: seed))
        var shuffled = remainingTitles

        if shuffled.count > 1 {
            for index in stride(from: shuffled.count - 1, through: 1, by: -1) {
                let swapIndex = Int(generator.next() % UInt64(index + 1))
                if swapIndex != index {
                    shuffled.swapAt(index, swapIndex)
                }
            }
        }

        return [allTitle] + shuffled
    }

    private static func stableSeed(from rawValue: String) -> UInt64 {
        rawValue.utf8.reduce(1469598103934665603) { partial, byte in
            (partial ^ UInt64(byte)) &* 1099511628211
        }
    }

    private struct SeededTitleGenerator {
        private var state: UInt64

        init(seed: UInt64) {
            self.state = seed == 0 ? 0x9E3779B97F4A7C15 : seed
        }

        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1
            return state
        }
    }

    static func normalizedKey(for title: String) -> String {
        let lowered = title
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "calories", with: "cal")
            .replacingOccurrences(of: "calorie", with: "cal")
            .replacingOccurrences(of: " ", with: "")

        switch lowered {
        case "", "all", "feed":
            return "all"
        case "breakfast":
            return "breakfast"
        case "lunch":
            return "lunch"
        case "dinner":
            return "dinner"
        case "dessert", "desserts":
            return "dessert"
        case "drinks", "drink":
            return "drinks"
        case "vegetarian":
            return "vegetarian"
        case "vegan":
            return "vegan"
        case "pasta":
            return "pasta"
        case "chicken":
            return "chicken"
        case "steak", "beef":
            return "steak"
        case "fish":
            return "fish"
        case "nigerian", "westafrican", "west african":
            return "nigerian"
        case "salad":
            return "salad"
        case "sandwich", "sandwiches":
            return "sandwich"
        case "beans", "bean", "legumes", "legume":
            return "beans"
        case "potatoes", "potato":
            return "potatoes"
        case "salmon":
            return "salmon"
        case "beginner":
            return "beginner"
        case "under500", "under500cal", "under500cals":
            return "under500"
        default:
            return lowered
        }
    }
}

struct DiscoverRecipeCardData: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let title: String
    let description: String?
    let authorName: String?
    let authorHandle: String?
    let category: String?
    let recipeType: String?
    let discoverBrackets: [String]?
    let cookTimeText: String?
    let cookTimeMinutes: Int?
    let publishedDate: String?
    let imageURLString: String?
    let heroImageURLString: String?
    let recipeURLString: String?
    let source: String?

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case description
        case authorName = "author_name"
        case authorHandle = "author_handle"
        case category
        case recipeType = "recipe_type"
        case discoverBrackets = "discover_brackets"
        case cookTimeText = "cook_time_text"
        case cookTimeMinutes = "cook_time_minutes"
        case publishedDate = "published_date"
        case imageURLString = "discover_card_image_url"
        case heroImageURLString = "hero_image_url"
        case recipeURLString = "recipe_url"
        case source
    }

    var imageURL: URL? {
        imageCandidates.first
    }

    var imageCandidates: [URL] {
        [imageURLString, heroImageURLString]
            .compactMap(Self.normalizedImageURL(from:))
    }

    private static func normalizedImageURL(from rawValue: String?) -> URL? {
        guard let rawValue, !rawValue.isEmpty else { return nil }
        let normalized = rawValue
            .replacingOccurrences(of: "https://firebasestorage.googleapis.com:443/", with: "https://firebasestorage.googleapis.com/")
            .replacingOccurrences(of: " ", with: "%20")
        return URL(string: normalized)
    }

    var destinationURL: URL? {
        guard let recipeURLString, !recipeURLString.isEmpty else { return nil }
        return URL(string: recipeURLString)
    }

    var authorLabel: String {
        if let authorHandle = Self.displayableCreatorHandle(authorHandle) {
            return authorHandle
        }
        if let authorName, !authorName.isEmpty, !Self.isOpaqueNumericCreator(authorName) { return authorName }
        return "Source pending"
    }

    var filterLabel: String {
        if let discoverBracketLabel = discoverBracketLabel {
            return discoverBracketLabel
        }
        if let normalizedRecipeType = Self.normalizedFilterLabel(from: recipeType) {
            return normalizedRecipeType
        }
        if let category, !category.isEmpty {
            if let normalizedCategory = Self.normalizedFilterLabel(
                from: category.replacingOccurrences(of: " Recipes", with: "")
            ) {
                return normalizedCategory
            }
        }
        return "Recipes"
    }

    private var discoverBracketLabel: String? {
        guard let discoverBrackets else { return nil }
        return discoverBrackets.compactMap { Self.normalizedFilterLabel(from: $0) }.first
    }

    var filterChipLabel: String? {
        let value = filterLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { return nil }
        if value.caseInsensitiveCompare("Recipes") == .orderedSame { return nil }
        if value.caseInsensitiveCompare("Other") == .orderedSame { return nil }
        return value
    }

    var compactFilterLabel: String? {
        let value = filterLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func normalizedFilterLabel(from rawValue: String?) -> String? {
        guard let rawValue else { return nil }
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let lowered = trimmed.lowercased()
        switch lowered {
        case "concept_prompt", "direct_input", "text", "media_image", "media_video", "tiktok", "instagram", "youtube", "ounje":
            return nil
        case "breakfast":
            return "Breakfast"
        case "lunch":
            return "Lunch"
        case "dinner":
            return "Dinner"
        case "dessert":
            return "Dessert"
        case "vegetarian":
            return "Vegetarian"
        case "vegan":
            return "Vegan"
        case "nigerian", "westafrican", "west african":
            return "Nigerian"
        case "other", "recipes":
            return "Other"
        default:
            return lowered
                .split(separator: " ")
                .map { word in
                    word.prefix(1).uppercased() + word.dropFirst()
                }
                .joined(separator: " ")
        }
    }

    private static func displayableCreatorHandle(_ value: String?) -> String? {
        guard let raw = value?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        let withoutAt = raw
            .trimmingCharacters(in: CharacterSet(charactersIn: "@"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !withoutAt.isEmpty, !isOpaqueNumericCreator(withoutAt) else {
            return nil
        }
        return "@\(withoutAt)"
    }

    private static func isOpaqueNumericCreator(_ value: String) -> Bool {
        let compact = value
            .trimmingCharacters(in: CharacterSet(charactersIn: "@"))
            .replacingOccurrences(of: #"[^A-Za-z0-9]"#, with: "", options: .regularExpression)
        let digits = compact.replacingOccurrences(of: #"[^0-9]"#, with: "", options: .regularExpression)
        return !compact.isEmpty && compact == digits && digits.count >= 8
    }

    var compactCookTime: String? {
        let minutes = recipeDisplayCookMinutes(
            cookTimeText: cookTimeText,
            cookTimeMinutes: cookTimeMinutes
        )
        return minutes > 0 ? formattedRecipeCookTime(minutes: minutes) : nil
    }

    var displayTitle: String {
        let withDigitSpacing = title.replacingOccurrences(
            of: #"(?<=\d)(?=[A-Za-z])"#,
            with: " ",
            options: .regularExpression
        )
        return withDigitSpacing.replacingOccurrences(
            of: #"(?<=[a-z])(?=[A-Z])"#,
            with: " ",
            options: .regularExpression
        )
    }

    var footerLine: String {
        let parts: [String] = [
            source?.capitalized,
            publishedDate?.replacingOccurrences(of: "_", with: "/")
        ].compactMap { value in
            guard let value, !value.isEmpty else { return nil }
            return value
        }

        if !parts.isEmpty {
            return parts.joined(separator: " • ")
        }

        if let description, !description.isEmpty {
            return description
        }

        return "Freshly scraped into your live recipe feed."
    }

    var emoji: String {
        switch filterLabel.lowercased() {
        case "breakfast":
            return "🍳"
        case "lunch":
            return "🥗"
        case "dinner":
            return "🍽️"
        case "dessert":
            return "🍰"
        case "nigerian":
            return "🍛"
        default:
            return "🍴"
        }
    }

    var accentColor: Color {
        switch filterLabel.lowercased() {
        case "breakfast":
            return Color(hex: "F4B15E")
        case "lunch":
            return Color(hex: "56D7C8")
        case "dinner":
            return Color(hex: "52C67A")
        case "dessert":
            return Color(hex: "FF8AAE")
        case "nigerian":
            return Color(hex: "F1A24A")
        default:
            return OunjePalette.accent
        }
    }

    init(
        id: String,
        title: String,
        description: String?,
        authorName: String?,
        authorHandle: String?,
        category: String?,
        recipeType: String?,
        discoverBrackets: [String]? = nil,
        cookTimeText: String?,
        cookTimeMinutes: Int? = nil,
        publishedDate: String?,
        imageURLString: String?,
        heroImageURLString: String?,
        recipeURLString: String?,
        source: String?
    ) {
        self.id = id
        self.title = title
        self.description = description
        self.authorName = authorName
        self.authorHandle = authorHandle
        self.category = category
        self.recipeType = recipeType
        self.discoverBrackets = discoverBrackets
        self.cookTimeText = cookTimeText
        self.cookTimeMinutes = cookTimeMinutes
        self.publishedDate = publishedDate
        self.imageURLString = imageURLString
        self.heroImageURLString = heroImageURLString
        self.recipeURLString = recipeURLString
        self.source = source
    }

    init(preppedRecipe: PlannedRecipe) {
        let tags = preppedRecipe.recipe.tags.map { $0.lowercased() }
        let mealType = tags.first { ["breakfast", "lunch", "dinner", "dessert"].contains($0) }

        self.init(
            id: preppedRecipe.recipe.id,
            title: preppedRecipe.recipe.title,
            description: preppedRecipe.carriedFromPreviousPlan ? "Carried over from your last cycle." : "Scheduled for this prep cycle.",
            authorName: nil,
            authorHandle: nil,
            category: mealType,
            recipeType: mealType,
            cookTimeText: "\(preppedRecipe.recipe.prepMinutes) mins",
            cookTimeMinutes: preppedRecipe.recipe.prepMinutes,
            publishedDate: nil,
            imageURLString: preppedRecipe.recipe.cardImageURLString,
            heroImageURLString: preppedRecipe.recipe.heroImageURLString,
            recipeURLString: nil,
            source: preppedRecipe.recipe.source ?? preppedRecipe.recipe.cuisine.title
        )
    }

    func matchesDiscoverFilter(_ filter: String) -> Bool {
        let normalizedFilter = DiscoverPreset.normalizedKey(for: filter)
        guard normalizedFilter != "all" else { return true }

        switch normalizedFilter {
        case "under500":
            if let cookTimeMinutes, cookTimeMinutes > 0 {
                return cookTimeMinutes <= 500
            }
            return false
        case "beginner":
            let haystack = [category, recipeType, description, title]
                .compactMap { $0?.lowercased() }
                .joined(separator: " ")
            return haystack.contains("beginner") || haystack.contains("easy")
        default:
            let filterTokens = Set(discoverFilterTokens)
            return filterTokens.contains(normalizedFilter)
        }
    }

    func matchesDiscoverSearchTerms(_ terms: [String]) -> Bool {
        guard !terms.isEmpty else { return true }

        let haystack = [
            title,
            description,
            authorName,
            authorHandle,
            category,
            recipeType,
            source
        ]
        .compactMap { $0?.lowercased() }
        .joined(separator: " ")

        return terms.allSatisfy { haystack.contains($0) }
    }

    private var discoverFilterTokens: [String] {
        let rawValues = [category, recipeType, filterLabel].compactMap { $0 } + (discoverBrackets ?? [])

        return rawValues.compactMap { value in
            let normalized = DiscoverPreset.normalizedKey(for: value)
            return normalized.isEmpty ? nil : normalized
        }
    }
}

struct DiscoverRankedRecipesResponse: Decodable {
    let recipes: [DiscoverRecipeCardData]
    let filters: [String]
    let rankingMode: String?
    let totalAvailable: Int?
    let hasMore: Bool?
    let nextOffset: Int?
}

struct DiscoverOnboardingFeedMixer {
    private struct ScoredRecipe {
        let recipe: DiscoverRecipeCardData
        let originalIndex: Int
        let onboardingScore: Double
        let qualityScore: Double
        let diversityScore: Double
        let activationScore: Double
        let hardPenalty: Double
        let deterministicNoise: Double
    }

    fileprivate struct TasteProfile {
        let persona: String?
        let goals: [String]
        let dietaryPatterns: [String]
        let restrictions: [String]
        let favoriteTerms: [String]
        let cuisineTerms: [String]
        let behaviorTerms: [String]
        let cooksForOthers: Bool
        let householdSize: Int
        let budgetPerServing: Double
        let budgetFlexibility: BudgetFlexibility
        let purchasingBehavior: PurchasingBehavior
    }

    static func mixedFeed(
        recipes: [DiscoverRecipeCardData],
        profile: UserProfile?,
        behaviorSeeds: [DiscoverRecipeCardData],
        requestSeed: String,
        filter: String,
        query: String
    ) -> [DiscoverRecipeCardData] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedQuery.isEmpty,
              DiscoverPreset.normalizedKey(for: filter) == "all",
              !recipes.isEmpty
        else {
            return recipes
        }

        let tasteProfile = TasteProfile(profile: profile, behaviorSeeds: behaviorSeeds)
        let scored = recipes.enumerated().map { index, recipe in
            ScoredRecipe(
                recipe: recipe,
                originalIndex: index,
                onboardingScore: onboardingScore(for: recipe, tasteProfile: tasteProfile),
                qualityScore: qualityScore(for: recipe),
                diversityScore: diversityScore(for: recipe, tasteProfile: tasteProfile),
                activationScore: activationScore(for: recipe),
                hardPenalty: hardPenalty(for: recipe, tasteProfile: tasteProfile),
                deterministicNoise: deterministicNoise(for: recipe.id, seed: requestSeed)
            )
        }

        let safeRecipes = scored.filter { $0.hardPenalty < 100 }
        let candidates = safeRecipes.isEmpty ? scored : safeRecipes
        let targetCount = candidates.count
        let onboardingTarget = max(1, Int((Double(targetCount) * 0.40).rounded()))
        let qualityTarget = max(1, Int((Double(targetCount) * 0.25).rounded()))
        let diversityTarget = max(1, Int((Double(targetCount) * 0.20).rounded()))
        let activationTarget = max(1, targetCount - onboardingTarget - qualityTarget - diversityTarget)

        var selectedIDs = Set<String>()
        var sections: [[ScoredRecipe]] = []
        sections.append(takeTop(candidates, count: onboardingTarget, selectedIDs: &selectedIDs) {
            weightedScore($0, onboarding: 1.0, quality: 0.18, diversity: 0.12, activation: 0.08)
        })
        sections.append(takeTop(candidates, count: qualityTarget, selectedIDs: &selectedIDs) {
            weightedScore($0, onboarding: 0.18, quality: 1.0, diversity: 0.16, activation: 0.12)
        })
        sections.append(takeDiverse(candidates, count: diversityTarget, selectedIDs: &selectedIDs))
        sections.append(takeTop(candidates, count: activationTarget, selectedIDs: &selectedIDs) {
            weightedScore($0, onboarding: 0.22, quality: 0.18, diversity: 0.12, activation: 1.0)
        })

        let remaining = candidates
            .filter { !selectedIDs.contains($0.recipe.id) }
            .sorted { lhs, rhs in
                weightedScore(lhs, onboarding: 0.36, quality: 0.30, diversity: 0.20, activation: 0.14)
                    > weightedScore(rhs, onboarding: 0.36, quality: 0.30, diversity: 0.20, activation: 0.14)
            }

        let interleaved = interleave(sections) + remaining
        return interleaved.map { $0.recipe }
    }

    static func behaviorSignature(_ behaviorSeeds: [DiscoverRecipeCardData]) -> String {
        behaviorSeeds
            .prefix(8)
            .flatMap { recipe in
                [recipe.id, recipe.filterLabel, recipe.category, recipe.recipeType]
                    .compactMap { $0 }
            }
            .map(normalizedToken)
            .filter { !$0.isEmpty }
            .joined(separator: ",")
    }

    private static func onboardingScore(for recipe: DiscoverRecipeCardData, tasteProfile: TasteProfile) -> Double {
        let haystack = recipe.searchableText
        var score = 0.0

        for term in tasteProfile.favoriteTerms where haystack.contains(term) {
            score += 2.2
        }
        for term in tasteProfile.cuisineTerms where haystack.contains(term) {
            score += 1.7
        }
        for term in tasteProfile.behaviorTerms where haystack.contains(term) {
            score += 2.8
        }
        for pattern in tasteProfile.dietaryPatterns where dietMatches(pattern, haystack: haystack) {
            score += 2.0
        }

        let goals = tasteProfile.goals.joined(separator: " ")
        if goals.contains("spend less") || goals.contains("save money") || goals.contains("budget") {
            score += matchesAny(haystack, ["budget", "cheap", "pantry", "beans", "potato", "rice", "chicken", "one pot"]) ? 2.4 : 0
        }
        if goals.contains("eat less takeout") || goals.contains("find good eats") {
            score += matchesAny(haystack, ["nigerian", "curry", "stew", "spicy", "bowl", "dinner", "lunch"]) ? 2.0 : 0
        }
        if goals.contains("learn to cook") || goals.contains("cook new things") {
            score += matchesAny(haystack, ["beginner", "easy", "simple", "guide", "classic"]) ? 1.8 : 0
            score += tasteProfile.cuisineTerms.contains(where: { haystack.contains($0) }) ? 1.0 : 0
        }
        if goals.contains("stick to a diet") || goals.contains("diet") {
            score += tasteProfile.dietaryPatterns.contains(where: { dietMatches($0, haystack: haystack) }) ? 2.0 : 0
        }
        if goals.contains("time") || goals.contains("energy") {
            score += quickRecipeScore(recipe)
        }

        if let persona = tasteProfile.persona {
            score += personaScore(persona, recipe: recipe, haystack: haystack, tasteProfile: tasteProfile)
        }

        if tasteProfile.cooksForOthers || tasteProfile.householdSize >= 3 {
            score += matchesAny(haystack, ["family", "tray", "bake", "one pot", "pasta", "chicken", "rice", "dinner"]) ? 1.3 : 0
        }

        if tasteProfile.budgetPerServing < 9 || tasteProfile.budgetFlexibility != .convenienceFirst {
            score += matchesAny(haystack, ["beans", "rice", "potato", "chicken", "pasta", "pantry", "budget"]) ? 1.2 : 0
        }

        if tasteProfile.purchasingBehavior == .healthier {
            score += matchesAny(haystack, ["healthy", "lighter", "salad", "vegetable", "protein", "grilled", "baked"]) ? 1.0 : 0
        }

        return score
    }

    private static func qualityScore(for recipe: DiscoverRecipeCardData) -> Double {
        var score = 0.0
        score += recipe.imageURL == nil ? 0 : 2.0
        score += recipe.description?.isEmpty == false ? 1.0 : 0
        score += recipe.cookTimeMinutes == nil ? 0 : 0.8
        score += recipe.source?.isEmpty == false ? 0.5 : 0
        score += recipe.filterChipLabel == nil ? 0 : 0.5

        if let minutes = recipe.cookTimeMinutes {
            switch minutes {
            case 1...35:
                score += 1.2
            case 36...60:
                score += 0.7
            default:
                score += 0.2
            }
        }

        return score
    }

    private static func diversityScore(for recipe: DiscoverRecipeCardData, tasteProfile: TasteProfile) -> Double {
        let haystack = recipe.searchableText
        var score = 1.0

        if matchesAny(haystack, ["nigerian", "west african", "thai", "korean", "mexican", "indian", "caribbean", "mediterranean"]) {
            score += 1.4
        }
        if tasteProfile.explorationBias > 0 {
            score += tasteProfile.explorationBias
        }
        if recipe.filterChipLabel != nil {
            score += 0.6
        }

        return score
    }

    private static func activationScore(for recipe: DiscoverRecipeCardData) -> Double {
        let haystack = recipe.searchableText
        var score = 0.0
        score += quickRecipeScore(recipe)
        score += matchesAny(haystack, ["easy", "beginner", "one pot", "sheet pan", "bowl", "meal prep", "make ahead"]) ? 2.0 : 0
        score += recipe.imageURL == nil ? 0 : 1.0
        score += matchesAny(haystack, ["breakfast", "lunch", "dinner", "dessert", "nigerian", "pasta", "chicken"]) ? 0.8 : 0
        return score
    }

    private static func hardPenalty(for recipe: DiscoverRecipeCardData, tasteProfile: TasteProfile) -> Double {
        let haystack = recipe.searchableText
        var penalty = 0.0

        for restriction in tasteProfile.restrictions {
            let terms = restrictionTerms(for: restriction)
            if !terms.isEmpty, matchesAny(haystack, terms) {
                penalty += 120
            }
        }

        for pattern in tasteProfile.dietaryPatterns {
            let normalized = normalizedToken(pattern)
            if normalized.contains("vegan"), !dietMatches(pattern, haystack: haystack), matchesAny(haystack, meatAndAnimalTerms) {
                penalty += 120
            }
            if normalized.contains("vegetarian"), !dietMatches(pattern, haystack: haystack), matchesAny(haystack, meatTerms) {
                penalty += 120
            }
            if normalized.contains("dairyfree") || normalized.contains("dairy free"), matchesAny(haystack, dairyTerms) {
                penalty += 120
            }
            if normalized.contains("glutenfree") || normalized.contains("gluten free"), matchesAny(haystack, glutenTerms) {
                penalty += 80
            }
            if normalized.contains("keto"), !dietMatches(pattern, haystack: haystack), matchesAny(haystack, ["pasta", "rice", "bread", "potato", "noodle", "toast", "bar", "cake"]) {
                penalty += 28
            }
        }

        return penalty
    }

    private static func takeTop(
        _ recipes: [ScoredRecipe],
        count: Int,
        selectedIDs: inout Set<String>,
        score: (ScoredRecipe) -> Double
    ) -> [ScoredRecipe] {
        guard count > 0 else { return [] }
        let chosen = recipes
            .filter { !selectedIDs.contains($0.recipe.id) }
            .sorted { lhs, rhs in
                let lhsScore = score(lhs)
                let rhsScore = score(rhs)
                if lhsScore == rhsScore {
                    return lhs.originalIndex < rhs.originalIndex
                }
                return lhsScore > rhsScore
            }
            .prefix(count)
        chosen.forEach { selectedIDs.insert($0.recipe.id) }
        return Array(chosen)
    }

    private static func takeDiverse(
        _ recipes: [ScoredRecipe],
        count: Int,
        selectedIDs: inout Set<String>
    ) -> [ScoredRecipe] {
        guard count > 0 else { return [] }
        var usedBuckets = Set<String>()
        var selected: [ScoredRecipe] = []
        let sorted = recipes
            .filter { !selectedIDs.contains($0.recipe.id) }
            .sorted {
                weightedScore($0, onboarding: 0.14, quality: 0.18, diversity: 1.0, activation: 0.12)
                    > weightedScore($1, onboarding: 0.14, quality: 0.18, diversity: 1.0, activation: 0.12)
            }

        for recipe in sorted {
            let bucket = diversityBucket(for: recipe.recipe)
            guard !usedBuckets.contains(bucket) || selected.count >= max(1, count / 2) else {
                continue
            }
            selected.append(recipe)
            selectedIDs.insert(recipe.recipe.id)
            usedBuckets.insert(bucket)
            if selected.count == count { return selected }
        }

        for recipe in sorted where !selectedIDs.contains(recipe.recipe.id) {
            selected.append(recipe)
            selectedIDs.insert(recipe.recipe.id)
            if selected.count == count { return selected }
        }

        return selected
    }

    private static func interleave(_ sections: [[ScoredRecipe]]) -> [ScoredRecipe] {
        var result: [ScoredRecipe] = []
        let maxCount = sections.map(\.count).max() ?? 0
        guard maxCount > 0 else { return [] }

        for index in 0..<maxCount {
            for section in sections where index < section.count {
                result.append(section[index])
            }
        }
        return result
    }

    private static func weightedScore(
        _ recipe: ScoredRecipe,
        onboarding: Double,
        quality: Double,
        diversity: Double,
        activation: Double
    ) -> Double {
        (recipe.onboardingScore * onboarding)
            + (recipe.qualityScore * quality)
            + (recipe.diversityScore * diversity)
            + (recipe.activationScore * activation)
            + recipe.deterministicNoise
            - recipe.hardPenalty
    }

    private static func personaScore(
        _ persona: String,
        recipe: DiscoverRecipeCardData,
        haystack: String,
        tasteProfile: TasteProfile
    ) -> Double {
        let normalized = persona.lowercased()
        if normalized.contains("student") {
            return (quickRecipeScore(recipe) * 0.8)
                + (matchesAny(haystack, ["budget", "cheap", "rice", "pasta", "bowl", "sandwich", "beans"]) ? 2.0 : 0)
        }
        if normalized.contains("professional") {
            return (quickRecipeScore(recipe) * 0.9)
                + (matchesAny(haystack, ["meal prep", "make ahead", "lunch", "bowl", "one pot"]) ? 2.0 : 0)
        }
        if normalized.contains("parent") {
            return matchesAny(haystack, ["family", "kid", "chicken", "pasta", "rice", "bake", "one pot", "dinner"]) ? 2.4 : 0
        }
        if normalized.contains("home cook") {
            return matchesAny(haystack, ["classic", "from scratch", "stew", "curry", "roast", "bake"]) ? 1.8 : 0
        }
        if normalized.contains("fitness") {
            return matchesAny(haystack, ["protein", "salmon", "chicken", "turkey", "salad", "healthy", "grilled"]) ? 2.2 : 0
        }
        return tasteProfile.cooksForOthers ? 0.4 : 0
    }

    private static func quickRecipeScore(_ recipe: DiscoverRecipeCardData) -> Double {
        guard let minutes = recipe.cookTimeMinutes, minutes > 0 else {
            return recipe.searchableText.contains("quick") || recipe.searchableText.contains("easy") ? 1.0 : 0
        }

        switch minutes {
        case 1...20:
            return 2.2
        case 21...35:
            return 1.4
        case 36...50:
            return 0.5
        default:
            return 0
        }
    }

    private static func dietMatches(_ pattern: String, haystack: String) -> Bool {
        let normalized = normalizedToken(pattern)
        if normalized.contains("omnivore") { return true }
        if normalized.contains("vegetarian") { return haystack.contains("vegetarian") || haystack.contains("veggie") }
        if normalized.contains("vegan") { return haystack.contains("vegan") }
        if normalized.contains("keto") { return haystack.contains("keto") || haystack.contains("low carb") || haystack.contains("low-carb") }
        if normalized.contains("dairyfree") || normalized.contains("dairy free") { return haystack.contains("dairy free") || haystack.contains("dairy-free") }
        if normalized.contains("glutenfree") || normalized.contains("gluten free") { return haystack.contains("gluten free") || haystack.contains("gluten-free") }
        if normalized.contains("protein") { return haystack.contains("protein") || haystack.contains("chicken") || haystack.contains("salmon") }
        return haystack.contains(normalized)
    }

    private static func restrictionTerms(for rawValue: String) -> [String] {
        let normalized = normalizedToken(rawValue)
        switch normalized {
        case let value where value.contains("peanut"):
            return ["peanut", "peanuts", "groundnut", "groundnuts"]
        case let value where value.contains("dairy") || value.contains("milk") || value.contains("lactose"):
            return dairyTerms
        case let value where value.contains("shellfish") || value.contains("shrimp") || value.contains("prawn") || value.contains("crab"):
            return ["shellfish", "shrimp", "prawn", "crab", "lobster", "scallop", "oyster", "clam"]
        case let value where value.contains("gluten") || value.contains("wheat"):
            return glutenTerms
        case let value where value.contains("egg"):
            return ["egg", "eggs", "omelet", "omelette", "frittata"]
        case let value where value.contains("soy"):
            return ["soy", "tofu", "tempeh", "edamame", "soy sauce"]
        default:
            return normalized.isEmpty ? [] : [normalized]
        }
    }

    private static func diversityBucket(for recipe: DiscoverRecipeCardData) -> String {
        [recipe.filterChipLabel, recipe.category, recipe.recipeType, recipe.discoverBrackets?.first, recipe.source]
            .compactMap { $0 }
            .map(normalizedToken)
            .first { !$0.isEmpty } ?? "general"
    }

    private static func matchesAny(_ haystack: String, _ needles: [String]) -> Bool {
        needles.contains { haystack.contains($0) }
    }

    private static func normalizedToken(_ rawValue: String) -> String {
        rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func deterministicNoise(for id: String, seed: String) -> Double {
        let hash = "\(seed)|\(id)".utf8.reduce(UInt64(1469598103934665603)) { partial, byte in
            (partial ^ UInt64(byte)) &* 1099511628211
        }
        return Double(hash % 10_000) / 1_000_000
    }

    private static let meatTerms = [
        "chicken", "beef", "steak", "pork", "bacon", "ham", "turkey", "lamb", "goat", "fish", "salmon", "tuna", "cod", "shrimp"
    ]

    private static let meatAndAnimalTerms = meatTerms + [
        "egg", "eggs", "cheese", "milk", "cream", "butter", "yogurt", "honey"
    ]

    private static let dairyTerms = [
        "milk", "cheese", "cream", "butter", "yogurt", "yoghurt", "parmesan", "cheddar", "mozzarella", "feta", "ricotta"
    ]

    private static let glutenTerms = [
        "wheat", "flour", "bread", "pasta", "noodle", "noodles", "toast", "cake", "bar", "bars", "cookie", "cookies"
    ]
}

private extension DiscoverOnboardingFeedMixer.TasteProfile {
    init(profile: UserProfile?, behaviorSeeds: [DiscoverRecipeCardData]) {
        let goalSignals = profile?.mealPrepGoals ?? []
        persona = Self.prefixedSignal(in: goalSignals, prefix: "Describes me:")
        goals = Self.splitGoals(Self.prefixedSignal(in: goalSignals, prefix: "Food goals:") ?? "")
            + goalSignals.map { $0.lowercased() }
        dietaryPatterns = profile?.dietaryPatterns.map { $0.lowercased() } ?? []
        restrictions = profile?.absoluteRestrictions.map { $0.lowercased() } ?? []
        favoriteTerms = [
            profile?.favoriteFoods ?? [],
            profile?.favoriteFlavors ?? [],
            profile?.pantryStaples ?? []
        ].flatMap { $0 }.map(Self.normalizedTerm).filter { !$0.isEmpty }
        cuisineTerms = [
            profile?.preferredCuisines.map(\.title) ?? [],
            profile?.cuisineCountries ?? []
        ].flatMap { $0 }.map(Self.normalizedTerm).filter { !$0.isEmpty }
        behaviorTerms = behaviorSeeds
            .prefix(6)
            .flatMap { recipe in
                [recipe.title, recipe.filterLabel, recipe.category, recipe.recipeType, recipe.description]
                    .compactMap { $0 }
            }
            .flatMap(Self.keyTerms)
        cooksForOthers = profile?.cooksForOthers ?? false
        householdSize = max(1, (profile?.consumption.adults ?? 1) + (profile?.consumption.kids ?? 0))
        let mealsPerWeek = max(1, profile?.consumption.mealsPerWeek ?? 4)
        let servings = max(1, householdSize)
        budgetPerServing = (profile?.budgetPerCycle ?? UserProfile.starter.budgetPerCycle) / Double(max(1, mealsPerWeek * servings))
        budgetFlexibility = profile?.budgetFlexibility ?? .slightlyFlexible
        purchasingBehavior = profile?.purchasingBehavior ?? .healthier
    }

    var explorationBias: Double {
        if favoriteTerms.isEmpty && cuisineTerms.isEmpty && behaviorTerms.isEmpty {
            return 0.8
        }
        return 0.25
    }

    private static func prefixedSignal(in values: [String], prefix: String) -> String? {
        values.first { $0.localizedCaseInsensitiveContains(prefix) }?
            .replacingOccurrences(of: prefix, with: "", options: [.caseInsensitive])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func splitGoals(_ rawValue: String) -> [String] {
        rawValue
            .split(separator: ";")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
    }

    private static func normalizedTerm(_ rawValue: String) -> String {
        rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
    }

    private static func keyTerms(from rawValue: String) -> [String] {
        let normalized = normalizedTerm(rawValue)
        let stopwords: Set<String> = [
            "the", "and", "with", "for", "recipe", "recipes", "easy", "simple", "fresh",
            "best", "homemade", "style", "style:", "food", "foods"
        ]

        return normalized
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count > 2 && !stopwords.contains($0) }
    }
}

private extension DiscoverRecipeCardData {
    var searchableText: String {
        [
            title,
            description,
            authorName,
            authorHandle,
            category,
            recipeType,
            filterLabel,
            source,
            cookTimeText
        ]
        .compactMap { $0 }
        .joined(separator: " ")
        .appending(" ")
        .appending((discoverBrackets ?? []).joined(separator: " "))
        .lowercased()
    }
}

struct DiscoverRankedRecipesRequest: Encodable {
    let profile: UserProfile?
    let filter: String
    let query: String?
    let limit: Int
    let offset: Int
    let feedContext: DiscoverFeedContext
    let forceRefresh: Bool
}

struct DiscoverFeedContext: Encodable {
    let sessionSeed: String
    let windowKey: String
    let weekday: String
    let daypart: String
    let isWeekend: Bool
    let locationLabel: String?
    let regionCode: String?
    let weatherSummary: String?
    let weatherMood: String?
    let temperatureBand: String?
    let seasonCue: String?
    let sweetTreatBias: Double

    static var current: DiscoverFeedContext {
        let calendar = Calendar.current
        let now = Date()
        let hour = calendar.component(.hour, from: now)
        let minute = calendar.component(.minute, from: now)
        let tenMinuteBucket = (minute / 10) * 10
        let weekdayIndex = calendar.component(.weekday, from: now)
        let weekdaySymbols = calendar.weekdaySymbols
        let weekday = weekdaySymbols[max(0, min(weekdaySymbols.count - 1, weekdayIndex - 1))].lowercased()

        let daypart: String
        switch hour {
        case 5..<11:
            daypart = "morning"
        case 11..<15:
            daypart = "midday"
        case 15..<18:
            daypart = "afternoon"
        case 18..<22:
            daypart = "evening"
        default:
            daypart = "late-night"
        }

        return DiscoverFeedContext(
            sessionSeed: "",
            windowKey: "\(calendar.component(.year, from: now))-\(calendar.ordinality(of: .day, in: .year, for: now) ?? 0)-\(hour)-\(tenMinuteBucket)",
            weekday: weekday,
            daypart: daypart,
            isWeekend: calendar.isDateInWeekend(now),
            locationLabel: nil,
            regionCode: Locale.current.region?.identifier,
            weatherSummary: nil,
            weatherMood: nil,
            temperatureBand: nil,
            seasonCue: Self.seasonCue(for: now),
            sweetTreatBias: Self.baseSweetTreatBias(daypart: daypart, isWeekend: calendar.isDateInWeekend(now))
        )
    }

    func withSessionSeed(_ seed: String) -> DiscoverFeedContext {
        DiscoverFeedContext(
            sessionSeed: seed,
            windowKey: windowKey,
            weekday: weekday,
            daypart: daypart,
            isWeekend: isWeekend,
            locationLabel: locationLabel,
            regionCode: regionCode,
            weatherSummary: weatherSummary,
            weatherMood: weatherMood,
            temperatureBand: temperatureBand,
            seasonCue: seasonCue,
            sweetTreatBias: sweetTreatBias
        )
    }

    func withLocation(locationLabel: String?, regionCode: String?) -> DiscoverFeedContext {
        DiscoverFeedContext(
            sessionSeed: sessionSeed,
            windowKey: windowKey,
            weekday: weekday,
            daypart: daypart,
            isWeekend: isWeekend,
            locationLabel: locationLabel,
            regionCode: regionCode,
            weatherSummary: weatherSummary,
            weatherMood: weatherMood,
            temperatureBand: temperatureBand,
            seasonCue: seasonCue,
            sweetTreatBias: sweetTreatBias
        )
    }

    func withWeather(summary: String?, mood: String?, temperatureBand: String?, sweetTreatBias: Double) -> DiscoverFeedContext {
        DiscoverFeedContext(
            sessionSeed: sessionSeed,
            windowKey: windowKey,
            weekday: weekday,
            daypart: daypart,
            isWeekend: isWeekend,
            locationLabel: locationLabel,
            regionCode: regionCode,
            weatherSummary: summary,
            weatherMood: mood,
            temperatureBand: temperatureBand,
            seasonCue: seasonCue,
            sweetTreatBias: sweetTreatBias
        )
    }

    var cacheKey: String {
        // Deliberately excludes weather fields (weatherSummary, weatherMood, temperatureBand,
        // sweetTreatBias) — weather is sent in the server request body for ranking but should
        // not bust the client-side cache, which would cause a redundant second fetch every time
        // the weather resolves after the initial prewarm.
        [
            windowKey,
            weekday,
            daypart,
            isWeekend ? "weekend" : "weekday",
            locationLabel ?? "",
            regionCode ?? "",
            seasonCue ?? "",
        ].joined(separator: "|")
    }

    private static func seasonCue(for date: Date) -> String {
        switch Calendar.current.component(.month, from: date) {
        case 12, 1, 2:
            return "winter"
        case 3, 4, 5:
            return "spring"
        case 6, 7, 8:
            return "summer"
        default:
            return "autumn"
        }
    }

    private static func baseSweetTreatBias(daypart: String, isWeekend: Bool) -> Double {
        var bias = 0.18
        if daypart == "evening" { bias += 0.12 }
        if daypart == "late-night" { bias += 0.18 }
        if isWeekend { bias += 0.1 }
        return min(max(bias, 0), 1)
    }
}
