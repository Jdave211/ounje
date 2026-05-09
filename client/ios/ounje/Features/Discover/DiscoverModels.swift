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

struct DiscoverRecipeCardData: Identifiable, Codable, Hashable {
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
        if let authorHandle, !authorHandle.isEmpty {
            return authorHandle.hasPrefix("@") ? authorHandle : "@\(authorHandle)"
        }
        if let authorName, !authorName.isEmpty { return authorName }
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

    var compactCookTime: String? {
        if let cookTimeMinutes, cookTimeMinutes > 0 {
            return cookTimeMinutes == 1 ? "1 min" : "\(cookTimeMinutes) mins"
        }
        guard let cookTimeText, !cookTimeText.isEmpty else { return nil }
        return cookTimeText
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
        [
            windowKey,
            weekday,
            daypart,
            isWeekend ? "weekend" : "weekday",
            locationLabel ?? "",
            regionCode ?? "",
            weatherSummary ?? "",
            weatherMood ?? "",
            temperatureBand ?? "",
            seasonCue ?? "",
            String(format: "%.2f", sweetTreatBias)
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
