import SwiftUI
import Foundation
import AVKit
import UIKit

struct PresentedRecipeDetail: Identifiable {
    let recipeCard: DiscoverRecipeCardData
    let plannedRecipe: PlannedRecipe?
    let initialDetail: RecipeDetailData?
    let adaptedFromRecipeID: String?

    init(
        recipeCard: DiscoverRecipeCardData,
        plannedRecipe: PlannedRecipe? = nil,
        initialDetail: RecipeDetailData? = nil,
        adaptedFromRecipeID: String? = nil
    ) {
        self.recipeCard = recipeCard
        self.plannedRecipe = plannedRecipe
        self.initialDetail = initialDetail
        self.adaptedFromRecipeID = adaptedFromRecipeID
    }

    init(plannedRecipe: PlannedRecipe) {
        self.recipeCard = DiscoverRecipeCardData(preppedRecipe: plannedRecipe)
        self.plannedRecipe = plannedRecipe
        self.initialDetail = nil
        self.adaptedFromRecipeID = nil
    }

    var id: String { recipeCard.id }
}

struct RecipeDetailStep: Decodable, Hashable {
    let number: Int
    let text: String
    let tipText: String?
    let ingredientRefs: [String]
    let ingredients: [RecipeDetailIngredient]

    enum CodingKeys: String, CodingKey {
        case number
        case text
        case tipText = "tip_text"
        case ingredientRefs = "ingredient_refs"
        case ingredients
    }

    func replacingIngredients(_ ingredients: [RecipeDetailIngredient]) -> RecipeDetailStep {
        RecipeDetailStep(
            number: number,
            text: text,
            tipText: tipText,
            ingredientRefs: ingredientRefs,
            ingredients: ingredients
        )
    }
}

struct RecipeDetailIngredient: Decodable, Hashable, Identifiable {
    let id: String?
    let ingredientID: String?
    let displayName: String
    let quantityText: String?
    let imageURLString: String?
    let sortOrder: Int?

    enum CodingKeys: String, CodingKey {
        case id
        case ingredientID = "ingredient_id"
        case displayName = "display_name"
        case quantityText = "quantity_text"
        case imageURLString = "image_url"
        case sortOrder = "sort_order"
    }

    var stableID: String {
        if let id, !id.isEmpty { return id }
        if let ingredientID, !ingredientID.isEmpty { return ingredientID }
        return displayName
    }

    var imageURL: URL? {
        guard let imageURLString, !imageURLString.isEmpty else { return nil }
        let normalized = imageURLString
            .replacingOccurrences(of: "https://firebasestorage.googleapis.com:443/", with: "https://firebasestorage.googleapis.com/")
            .replacingOccurrences(of: " ", with: "%20")
        return URL(string: normalized)
    }

    var lineText: String {
        [displayQuantityText, displayTitle]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    var displayTitle: String {
        if shouldPromoteQuantityTextToTitle, let promotedTitle = normalizedQuantityText {
            return Self.cleanedIngredientName(from: promotedTitle)
        }
        return Self.cleanedIngredientName(from: displayName, quantityText: quantityText)
    }

    var displayQuantityText: String? {
        if shouldPromoteQuantityTextToTitle {
            return nil
        }
        return RecipeQuantityFormatter.normalize(quantityText)
    }

    private var normalizedQuantityText: String? {
        quantityText?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func cleanedIngredientName(from raw: String, quantityText: String? = nil) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return raw }

        let quantityWords: Set<String> = [
            "a", "an", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten",
            "half", "dozen", "couple", "few",
            "cup", "cups", "tablespoon", "tablespoons", "tbsp", "tbsps", "teaspoon", "teaspoons", "tsp", "tsps",
            "gram", "grams", "g", "kilogram", "kilograms", "kg", "milligram", "milligrams", "mg",
            "ounce", "ounces", "oz", "pound", "pounds", "lb", "lbs",
            "pinch", "pinches", "dash", "dashes",
            "clove", "cloves", "slice", "slices", "strip", "strips", "piece", "pieces",
            "bunch", "bunches", "sprig", "sprigs", "stalk", "stalks",
            "can", "cans", "jar", "jars", "bottle", "bottles", "package", "packages", "packet", "packets",
            "large", "small", "medium", "extra-large", "jumbo"
        ]

        var tokens = trimmed
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)

        while let first = tokens.first {
            let lowered = first.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let numericLike = lowered.rangeOfCharacter(from: .decimalDigits) != nil
                || lowered.rangeOfCharacter(from: CharacterSet(charactersIn: "¼½¾⅐⅑⅒⅓⅔⅕⅖⅗⅘⅙⅚⅛⅜⅝⅞")) != nil
            let fractionalLike = lowered.contains("/") || lowered.contains("-")
            let isQuantityWord = quantityWords.contains(lowered)

            if numericLike || fractionalLike || isQuantityWord {
                tokens.removeFirst()
                continue
            }

            break
        }

        let cleaned = tokens.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? trimmed : cleaned
    }

    private var promotedDisplayName: String? {
        guard shouldPromoteQuantityTextToTitle else { return nil }
        return normalizedQuantityText
    }

    private var shouldPromoteQuantityTextToTitle: Bool {
        guard isLikelyAbbreviation(displayName),
              let normalizedQuantityText,
              looksLikeIngredientName(normalizedQuantityText)
        else {
            return false
        }
        return true
    }

    private func isLikelyAbbreviation(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 4, !trimmed.contains(" ") else {
            return false
        }
        return trimmed == trimmed.uppercased()
    }

    private func looksLikeIngredientName(_ value: String) -> Bool {
        let trimmed = Self.cleanedIngredientName(from: value).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let lowered = trimmed.lowercased()
        let disallowed = [
            "to taste",
            "as needed",
            "for serving",
            "optional",
            "divided"
        ]
        if disallowed.contains(lowered) { return false }

        return trimmed.rangeOfCharacter(from: .letters) != nil
    }

    func scaled(by factor: Double) -> RecipeDetailIngredient {
        guard factor > 0, abs(factor - 1) > 0.001 else { return self }
        return RecipeDetailIngredient(
            id: id,
            ingredientID: ingredientID,
            displayName: displayName,
            quantityText: RecipeQuantityFormatter.scaled(quantityText, by: factor),
            imageURLString: imageURLString,
            sortOrder: sortOrder
        )
    }

    func normalizedForDisplay() -> RecipeDetailIngredient {
        guard let promotedDisplayName else { return self }
        return RecipeDetailIngredient(
            id: id,
            ingredientID: ingredientID,
            displayName: promotedDisplayName,
            quantityText: nil,
            imageURLString: imageURLString,
            sortOrder: sortOrder
        )
    }

    func replacingDisplayName(_ value: String) -> RecipeDetailIngredient {
        RecipeDetailIngredient(
            id: id,
            ingredientID: ingredientID,
            displayName: value,
            quantityText: quantityText,
            imageURLString: imageURLString,
            sortOrder: sortOrder
        )
    }

    func replacingImageURLString(_ value: String?) -> RecipeDetailIngredient {
        RecipeDetailIngredient(
            id: id,
            ingredientID: ingredientID,
            displayName: displayName,
            quantityText: quantityText,
            imageURLString: value,
            sortOrder: sortOrder
        )
    }

    func replacingQuantityText(_ value: String?) -> RecipeDetailIngredient {
        RecipeDetailIngredient(
            id: id,
            ingredientID: ingredientID,
            displayName: displayName,
            quantityText: value,
            imageURLString: imageURLString,
            sortOrder: sortOrder
        )
    }
}

enum RecipeQuantityFormatter {
    static func normalize(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let pounds = normalizedPounds(from: trimmed) {
            return pounds
        }

        return trimmed
            .replacingOccurrences(of: "  ", with: " ")
    }

    static func scaled(_ raw: String?, by factor: Double) -> String? {
        guard let normalized = normalize(raw) else { return nil }
        guard factor > 0, abs(factor - 1) > 0.001 else { return normalized }

        guard let measurement = parsedMeasurement(from: normalized) else {
            return normalized
        }

        let scaledAmount = measurement.amount * factor
        let amountText = formatAmount(scaledAmount)
        if measurement.unit.isEmpty {
            return amountText
        }
        return "\(amountText) \(measurement.unit)"
    }

    static func parsedMeasurement(from raw: String?) -> (amount: Double, unit: String)? {
        guard let normalized = normalize(raw) else { return nil }
        let pattern = #"^\s*((?:\d+\s+)?\d+/\d+|\d+(?:\.\d+)?)\s*(.*)$"#
        guard
            let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
            let match = regex.firstMatch(in: normalized, range: NSRange(normalized.startIndex..., in: normalized)),
            let amountRange = Range(match.range(at: 1), in: normalized)
        else {
            return nil
        }

        let amountText = String(normalized[amountRange])
        let amount = parseAmount(amountText)
        guard amount > 0 else { return nil }

        let unitRange = Range(match.range(at: 2), in: normalized)
        let unit = unitRange.map { String(normalized[$0]).trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
        return (amount: amount, unit: unit)
    }

    private static func parseAmount(_ text: String) -> Double {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains(" ") {
            let parts = trimmed.split(separator: " ", omittingEmptySubsequences: true)
            if parts.count == 2,
               let whole = Double(parts[0]),
               let fraction = parseFraction(String(parts[1])) {
                return whole + fraction
            }
        }

        if let fraction = parseFraction(trimmed) {
            return fraction
        }

        return Double(trimmed) ?? 0
    }

    private static func parseFraction(_ text: String) -> Double? {
        let parts = text.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count == 2,
              let numerator = Double(parts[0]),
              let denominator = Double(parts[1]),
              denominator != 0 else {
            return nil
        }
        return numerator / denominator
    }

    private static func formatAmount(_ amount: Double) -> String {
        let rounded = amount.rounded()
        if abs(amount - rounded) < 0.01 {
            return String(Int(rounded))
        }

        let whole = Int(floor(amount))
        let fraction = amount - Double(whole)
        let candidates = [2, 3, 4, 8, 16]
        var bestNumerator = 0
        var bestDenominator = 1
        var bestError = Double.greatestFiniteMagnitude

        for denominator in candidates {
            let numerator = Int((fraction * Double(denominator)).rounded())
            let candidate = Double(numerator) / Double(denominator)
            let error = abs(fraction - candidate)
            if error < bestError {
                bestError = error
                bestNumerator = numerator
                bestDenominator = denominator
            }
        }

        if bestNumerator > 0, bestError < 0.03 {
            if whole > 0 {
                return "\(whole) \(bestNumerator)/\(bestDenominator)"
            }
            return "\(bestNumerator)/\(bestDenominator)"
        }

        let formatter = NumberFormatter()
        formatter.maximumFractionDigits = 2
        formatter.minimumFractionDigits = 0
        formatter.minimumIntegerDigits = 1
        return formatter.string(from: NSNumber(value: amount)) ?? String(format: "%.2f", amount)
    }

    private static func normalizedPounds(from raw: String) -> String? {
        let pattern = #"^\s*(\d+(?:\.\d+)?)\s*(oz|ounce|ounces)\s*$"#
        guard
            let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
            let match = regex.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)),
            let amountRange = Range(match.range(at: 1), in: raw)
        else {
            return nil
        }

        guard let ounces = Double(raw[amountRange]), ounces >= 16 else { return nil }
        let pounds = ounces / 16
        let formatted =
            abs(pounds.rounded() - pounds) < 0.001
            ? String(Int(pounds.rounded()))
            : String(format: pounds.truncatingRemainder(dividingBy: 1) == 0.5 ? "%.1f" : "%.2f", pounds)
                .replacingOccurrences(of: ".00", with: "")

        return "\(formatted) lb"
    }
}

struct RecipeDetailData: Identifiable, Decodable, Hashable {
    let id: String
    let title: String
    let description: String
    let authorName: String?
    let authorHandle: String?
    let authorURLString: String?
    let source: String?
    let sourcePlatform: String?
    let category: String?
    let subcategory: String?
    let recipeType: String?
    let skillLevel: String?
    let cookTimeText: String?
    let servingsText: String?
    let servingSizeText: String?
    let dailyDietText: String?
    let estCostText: String?
    let estCaloriesText: String?
    let carbsText: String?
    let proteinText: String?
    let fatsText: String?
    let caloriesKcal: Double?
    let proteinG: Double?
    let carbsG: Double?
    let fatG: Double?
    let prepTimeMinutes: Int?
    let cookTimeMinutes: Int?
    let heroImageURLString: String?
    let discoverCardImageURLString: String?
    let recipeURLString: String?
    let originalRecipeURLString: String?
    let attachedVideoURLString: String?
    let detailFootnote: String?
    let imageCaption: String?
    let dietaryTags: [String]
    let flavorTags: [String]
    let cuisineTags: [String]
    let occasionTags: [String]
    let mainProtein: String?
    let cookMethod: String?
    let ingredients: [RecipeDetailIngredient]
    let steps: [RecipeDetailStep]
    let servingsCount: Int?

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case description
        case authorName = "author_name"
        case authorHandle = "author_handle"
        case authorURLString = "author_url"
        case source
        case sourcePlatform = "source_platform"
        case category
        case subcategory
        case recipeType = "recipe_type"
        case skillLevel = "skill_level"
        case cookTimeText = "cook_time_text"
        case servingsText = "servings_text"
        case servingSizeText = "serving_size_text"
        case dailyDietText = "daily_diet_text"
        case estCostText = "est_cost_text"
        case estCaloriesText = "est_calories_text"
        case carbsText = "carbs_text"
        case proteinText = "protein_text"
        case fatsText = "fats_text"
        case caloriesKcal = "calories_kcal"
        case proteinG = "protein_g"
        case carbsG = "carbs_g"
        case fatG = "fat_g"
        case prepTimeMinutes = "prep_time_minutes"
        case cookTimeMinutes = "cook_time_minutes"
        case heroImageURLString = "hero_image_url"
        case discoverCardImageURLString = "discover_card_image_url"
        case recipeURLString = "recipe_url"
        case originalRecipeURLString = "original_recipe_url"
        case attachedVideoURLString = "attached_video_url"
        case detailFootnote = "detail_footnote"
        case imageCaption = "image_caption"
        case dietaryTags = "dietary_tags"
        case flavorTags = "flavor_tags"
        case cuisineTags = "cuisine_tags"
        case occasionTags = "occasion_tags"
        case mainProtein = "main_protein"
        case cookMethod = "cook_method"
        case ingredients
        case steps
        case servingsCount = "servings_count"
    }

    var imageCandidates: [URL] {
        [heroImageURLString, discoverCardImageURLString].compactMap(Self.normalizedImageURL(from:))
    }

    var imageURL: URL? {
        imageCandidates.first
    }

    var originalURL: URL? {
        let raw = [originalRecipeURLString, authorURLString, recipeURLString]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        guard let raw, !raw.isEmpty else { return nil }
        return URL(string: raw)
    }

    var attachedVideoURL: URL? {
        guard let attachedVideoURLString, !attachedVideoURLString.isEmpty else { return nil }
        return URL(string: attachedVideoURLString)
    }

    var sourceDisplayLine: String? {
        if let authorHandle, !authorHandle.isEmpty { return authorHandle }
        if let authorName, !authorName.isEmpty { return authorName }
        if let source, !source.isEmpty, source.lowercased() != "withjulienne" { return source.capitalized }
        return nil
    }

    var authorLine: String {
        if let sourceDisplayLine { return sourceDisplayLine }
        if let sourcePlatform, !sourcePlatform.isEmpty { return sourcePlatform }
        if let source, !source.isEmpty { return source.capitalized }
        return "Ounje source"
    }

    var displayServings: Int {
        if let servingsCount, servingsCount > 0 { return servingsCount }
        if let parsed = RecipeDetailData.extractLeadingInteger(from: servingsText), parsed > 0 { return parsed }
        return 4
    }

    var detailsGrid: [RecipeDetailMetric] {
        let values: [RecipeDetailMetric?] = [
            skillLevel.map { RecipeDetailMetric(title: "Skill", value: $0) },
            RecipeDetailMetric(title: "Cook Time", value: compactCookTime),
            RecipeDetailMetric(title: "Servings", value: "\(displayServings)"),
            caloriesDisplayText.map { RecipeDetailMetric(title: "Calories", value: $0) },
            (proteinText ?? proteinG.map { "\($0.roundedString(0))g" }).map { RecipeDetailMetric(title: "Protein", value: $0) },
            (carbsText ?? carbsG.map { "\($0.roundedString(0))g" }).map { RecipeDetailMetric(title: "Carbs", value: $0) },
            (fatsText ?? fatG.map { "\($0.roundedString(0))g" }).map { RecipeDetailMetric(title: "Fats", value: $0) },
            (recipeType ?? category ?? subcategory).map { RecipeDetailMetric(title: "Type", value: $0.capitalized) },
            (cuisineTags.first ?? category ?? subcategory).map { RecipeDetailMetric(title: "Cuisine", value: $0) },
            (cookMethod ?? mainProtein).map { RecipeDetailMetric(title: "Method", value: $0) },
            (dailyDietText ?? dietaryTags.first).map { RecipeDetailMetric(title: "Diet", value: $0) },
            occasionTags.first.map { RecipeDetailMetric(title: "Occasion", value: $0) },
            estCostText.map { RecipeDetailMetric(title: "Est. Cost", value: $0) },
            sourceDisplayLine.map { RecipeDetailMetric(title: "Source", value: $0) }
        ]

        return values
            .compactMap { $0 }
            .filter { !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.value != "—" }
            .prefix(9)
            .map { $0 }
    }

    var compactTagSummary: String {
        let values = (dietaryTags + cuisineTags).prefix(2)
        return values.isEmpty ? "—" : values.joined(separator: " • ")
    }

    var combinedCookTimeText: String? {
        let total = resolvedRecipeDurationMinutes(from: self)
        return total > 0 ? "\(total) mins" : nil
    }

    var compactCookTime: String {
        if let combinedCookTimeText {
            return combinedCookTimeText
        }
        if let cookTimeMinutes, cookTimeMinutes > 0 {
            return "\(cookTimeMinutes) mins"
        }
        return cookTimeText ?? combinedCookTimeText ?? "—"
    }

    private var caloriesDisplayText: String? {
        if let caloriesKcal, caloriesKcal > 0 {
            return "\(Int(caloriesKcal.rounded())) kcal"
        }
        guard let estCaloriesText, let parsed = RecipeDetailData.extractFirstNumber(from: estCaloriesText) else {
            return nil
        }
        return "\(parsed) kcal"
    }

    private static func normalizedImageURL(from rawValue: String?) -> URL? {
        guard let rawValue, !rawValue.isEmpty else { return nil }
        let normalized = rawValue
            .replacingOccurrences(of: "https://firebasestorage.googleapis.com:443/", with: "https://firebasestorage.googleapis.com/")
            .replacingOccurrences(of: " ", with: "%20")
        return URL(string: normalized)
    }

    private static func extractLeadingInteger(from value: String?) -> Int? {
        guard let match = value?.range(of: #"\d{1,3}"#, options: .regularExpression) else { return nil }
        return Int(value?[match] ?? "")
    }

    private static func extractFirstNumber(from value: String?) -> Int? {
        guard let match = value?.range(of: #"\d{1,4}"#, options: .regularExpression) else { return nil }
        return Int(value?[match] ?? "")
    }

    func replacing(
        ingredients: [RecipeDetailIngredient],
        steps: [RecipeDetailStep]
    ) -> RecipeDetailData {
        RecipeDetailData(
            id: id,
            title: title,
            description: description,
            authorName: authorName,
            authorHandle: authorHandle,
            authorURLString: authorURLString,
            source: source,
            sourcePlatform: sourcePlatform,
            category: category,
            subcategory: subcategory,
            recipeType: recipeType,
            skillLevel: skillLevel,
            cookTimeText: cookTimeText,
            servingsText: servingsText,
            servingSizeText: servingSizeText,
            dailyDietText: dailyDietText,
            estCostText: estCostText,
            estCaloriesText: estCaloriesText,
            carbsText: carbsText,
            proteinText: proteinText,
            fatsText: fatsText,
            caloriesKcal: caloriesKcal,
            proteinG: proteinG,
            carbsG: carbsG,
            fatG: fatG,
            prepTimeMinutes: prepTimeMinutes,
            cookTimeMinutes: cookTimeMinutes,
            heroImageURLString: heroImageURLString,
            discoverCardImageURLString: discoverCardImageURLString,
            recipeURLString: recipeURLString,
            originalRecipeURLString: originalRecipeURLString,
            attachedVideoURLString: attachedVideoURLString,
            detailFootnote: detailFootnote,
            imageCaption: imageCaption,
            dietaryTags: dietaryTags,
            flavorTags: flavorTags,
            cuisineTags: cuisineTags,
            occasionTags: occasionTags,
            mainProtein: mainProtein,
            cookMethod: cookMethod,
            ingredients: ingredients,
            steps: steps,
            servingsCount: servingsCount
        )
    }

}

struct RecipeDetailMetric: Hashable {
    let title: String
    let value: String
}

struct RecipeDetailResponse: Decodable {
    let recipe: RecipeDetailData
}

struct RecipeDetailRelatedResponse: Decodable {
    let recipes: [DiscoverRecipeCardData]
}

struct RecipeResolvedVideoData: Decodable, Hashable {
    enum PlaybackMode: String {
        case native
        case iframe
        case embed
        case unavailable
    }

    let modeRawValue: String
    let provider: String?
    let sourceURLString: String
    let resolvedURLString: String?
    let posterURLString: String?
    let durationSeconds: Double?

    enum CodingKeys: String, CodingKey {
        case modeRawValue = "mode"
        case provider
        case sourceURLString = "source_url"
        case resolvedURLString = "resolved_url"
        case posterURLString = "poster_url"
        case durationSeconds = "duration_seconds"
    }

    var mode: PlaybackMode {
        PlaybackMode(rawValue: modeRawValue) ?? .unavailable
    }

    var url: URL? {
        guard let resolvedURLString, !resolvedURLString.isEmpty else { return nil }
        return URL(string: resolvedURLString)
    }

    var sourceURL: URL? {
        URL(string: sourceURLString)
    }

    var posterURL: URL? {
        guard let posterURLString, !posterURLString.isEmpty else { return nil }
        return URL(string: posterURLString)
    }

    var supportsNativePlayback: Bool {
        mode == .native
    }

    var usesHostedIframe: Bool {
        mode == .iframe
    }
}

struct RecipeVideoResolveResponse: Decodable {
    let video: RecipeResolvedVideoData
}

enum RecipeWebVideoActionKind: Equatable {
    case none
    case togglePlayback
    case seek(seconds: Double)
    case pause
}

struct RecipeWebVideoAction: Equatable {
    let id = UUID()
    let kind: RecipeWebVideoActionKind

    static let none = RecipeWebVideoAction(kind: .none)
}

@MainActor
final class RecipeDetailViewModel: ObservableObject {
    @Published private(set) var detail: RecipeDetailData?
    @Published private(set) var similarRecipes: [DiscoverRecipeCardData] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingSimilarRecipes = false
    @Published private(set) var errorMessage: String?
    private var similarLoadTask: Task<Void, Never>?

    init(initialDetail: RecipeDetailData? = nil) {
        self.detail = initialDetail
    }

    func load(for recipeID: String) async {
        if detail?.id == recipeID {
            scheduleSimilarRecipesLoad(for: recipeID)
            return
        }

        similarLoadTask?.cancel()
        similarRecipes = []
        isLoadingSimilarRecipes = false
        isLoading = true
        errorMessage = nil

        defer {
            isLoading = false
        }

        do {
            detail = try await RecipeDetailService.shared.fetchRecipeDetail(id: recipeID)
            scheduleSimilarRecipesLoad(for: recipeID)
        } catch {
            similarRecipes = []
            errorMessage = error.localizedDescription
        }
    }

    private func scheduleSimilarRecipesLoad(for recipeID: String) {
        guard detail?.id == recipeID, similarRecipes.isEmpty else { return }
        similarLoadTask?.cancel()
        isLoadingSimilarRecipes = true
        similarLoadTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            await self?.loadSimilarRecipes(for: recipeID)
        }
    }

    private func loadSimilarRecipes(for recipeID: String) async {
        guard detail?.id == recipeID, similarRecipes.isEmpty else { return }

        isLoadingSimilarRecipes = true
        defer { isLoadingSimilarRecipes = false }

        do {
            let recipes = try await RecipeDetailService.shared.fetchSimilarRecipes(id: recipeID)
            guard detail?.id == recipeID else { return }
            similarRecipes = recipes
        } catch {
            guard detail?.id == recipeID else { return }
            similarRecipes = []
        }
    }
}

actor RecipeDetailService {
    static let shared = RecipeDetailService()

    private var cache: [String: RecipeDetailData] = [:]
    private var similarCache: [String: [DiscoverRecipeCardData]] = [:]

    func fetchRecipeDetail(id: String, forceRefresh: Bool = false) async throws -> RecipeDetailData {
        if !forceRefresh, let cached = cache[id] {
            return cached
        }

        let baseDetail: RecipeDetailData
        do {
            baseDetail = try await fetchRecipeDetailFromSupabase(id: id)
        } catch {
            baseDetail = try await fetchRecipeDetailFromBackend(id: id)
        }

        let detail = await enrichCanonicalImages(in: baseDetail)
        cache[detail.id] = detail
        return detail
    }

    func fetchSimilarRecipes(id: String) async throws -> [DiscoverRecipeCardData] {
        if let cached = similarCache[id] {
            return cached
        }

        var lastError: Error?
        for baseURL in OunjeDevelopmentServer.candidateBaseURLs {
            do {
                return try await fetchSimilarRecipes(baseURL: baseURL, id: id)
            } catch {
                lastError = error
            }
        }

        throw lastError ?? SupabaseProfileStateError.invalidResponse
    }

    private func fetchSimilarRecipes(baseURL: String, id: String) async throws -> [DiscoverRecipeCardData] {
        guard let url = URL(string: "\(baseURL)/v1/recipe/detail/\(id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id)/similar?limit=5") else {
            throw SupabaseProfileStateError.invalidRequest
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SupabaseProfileStateError.invalidResponse
        }
        guard (200 ... 299).contains(httpResponse.statusCode) else {
            let errorPayload = try? JSONDecoder().decode(SupabaseRestErrorResponse.self, from: data)
            let fallback = "Failed to load similar recipes (\(httpResponse.statusCode))."
            throw SupabaseProfileStateError.requestFailed(errorPayload?.message ?? errorPayload?.error ?? fallback)
        }

        let decoded = try JSONDecoder().decode(RecipeDetailRelatedResponse.self, from: data)
        similarCache[id] = decoded.recipes
        return decoded.recipes
    }

    private func fetchRecipeDetailFromBackend(id: String) async throws -> RecipeDetailData {
        var lastError: Error?
        for baseURL in OunjeDevelopmentServer.candidateBaseURLs {
            do {
                return try await fetchRecipeDetailFromBackend(baseURL: baseURL, id: id)
            } catch {
                lastError = error
            }
        }

        throw lastError ?? SupabaseProfileStateError.invalidResponse
    }

    private func fetchRecipeDetailFromBackend(baseURL: String, id: String) async throws -> RecipeDetailData {
        guard let url = URL(string: "\(baseURL)/v1/recipe/detail/\(id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id)") else {
            throw SupabaseProfileStateError.invalidRequest
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SupabaseProfileStateError.invalidResponse
        }
        guard (200 ... 299).contains(httpResponse.statusCode) else {
            let errorPayload = try? JSONDecoder().decode(SupabaseRestErrorResponse.self, from: data)
            let fallback = "Failed to load recipe detail (\(httpResponse.statusCode))."
            throw SupabaseProfileStateError.requestFailed(errorPayload?.message ?? errorPayload?.error ?? fallback)
        }

        let decoded = try JSONDecoder().decode(RecipeDetailResponse.self, from: data)
        return decoded.recipe
    }

    private func fetchRecipeDetailFromSupabase(id: String) async throws -> RecipeDetailData {
        let encodedID = id.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? id
        let isUserImported = id.hasPrefix("uir_")
        let recipeTable = isUserImported ? "user_import_recipes" : "recipes"
        let ingredientTable = isUserImported ? "user_import_recipe_ingredients" : "recipe_ingredients"
        let stepTable = isUserImported ? "user_import_recipe_steps" : "recipe_steps"
        let stepIngredientTable = isUserImported ? "user_import_recipe_step_ingredients" : "recipe_step_ingredients"
        let recipeSelect = [
            "id",
            "title",
            "description",
            "author_name",
            "author_handle",
            "author_url",
            "source",
            "source_platform",
            "category",
            "subcategory",
            "recipe_type",
            "skill_level",
            "cook_time_text",
            "servings_text",
            "serving_size_text",
            "daily_diet_text",
            "est_cost_text",
            "est_calories_text",
            "carbs_text",
            "protein_text",
            "fats_text",
            "calories_kcal",
            "protein_g",
            "carbs_g",
            "fat_g",
            "prep_time_minutes",
            "cook_time_minutes",
            "hero_image_url",
            "discover_card_image_url",
            "recipe_url",
            "original_recipe_url",
            "attached_video_url",
            "detail_footnote",
            "image_caption",
            "dietary_tags",
            "flavor_tags",
            "cuisine_tags",
            "occasion_tags",
            "main_protein",
            "cook_method"
        ].joined(separator: ",")

        guard let recipeURL = URL(string: "\(SupabaseConfig.url)/rest/v1/\(recipeTable)?select=\(recipeSelect)&id=eq.\(encodedID)&limit=1") else {
            throw SupabaseProfileStateError.invalidRequest
        }

        let recipes: [SupabaseRecipeDetailRow] = try await performSupabaseGET(url: recipeURL, as: [SupabaseRecipeDetailRow].self)
        guard let recipe = recipes.first else {
            throw SupabaseProfileStateError.requestFailed("Recipe detail could not be found.")
        }

        guard let ingredientURL = URL(string: "\(SupabaseConfig.url)/rest/v1/\(ingredientTable)?select=id,ingredient_id,display_name,quantity_text,image_url,sort_order&recipe_id=eq.\(encodedID)&order=sort_order.asc") else {
            throw SupabaseProfileStateError.invalidRequest
        }
        let ingredients: [RecipeDetailIngredient] = try await performSupabaseGET(url: ingredientURL, as: [RecipeDetailIngredient].self)
            .map { $0.normalizedForDisplay() }

        guard let stepsURL = URL(string: "\(SupabaseConfig.url)/rest/v1/\(stepTable)?select=id,step_number,instruction_text,tip_text&recipe_id=eq.\(encodedID)&order=step_number.asc") else {
            throw SupabaseProfileStateError.invalidRequest
        }
        let stepRows: [SupabaseRecipeStepRow] = try await performSupabaseGET(url: stepsURL, as: [SupabaseRecipeStepRow].self)

        let stepIDs = stepRows.map(\.id)
        let stepIngredients: [SupabaseRecipeStepIngredientRow]
        if stepIDs.isEmpty {
            stepIngredients = []
        } else {
            let joined = stepIDs.joined(separator: ",")
            guard let stepIngredientsURL = URL(string: "\(SupabaseConfig.url)/rest/v1/\(stepIngredientTable)?select=id,recipe_step_id,ingredient_id,display_name,quantity_text,sort_order&recipe_step_id=in.(\(joined.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? joined))&order=recipe_step_id.asc,sort_order.asc") else {
                throw SupabaseProfileStateError.invalidRequest
            }
            stepIngredients = try await performSupabaseGET(url: stepIngredientsURL, as: [SupabaseRecipeStepIngredientRow].self)
        }

        let ingredientByID: [String: RecipeDetailIngredient] = ingredients.reduce(into: [:]) { lookup, ingredient in
            guard let ingredientID = ingredient.ingredientID?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !ingredientID.isEmpty
            else { return }
            if lookup[ingredientID] == nil {
                lookup[ingredientID] = ingredient
            }
        }
        let ingredientByName: [String: RecipeDetailIngredient] = ingredients.reduce(into: [:]) { lookup, ingredient in
            let normalizedName = SupabaseIngredientsCatalogService.normalizedName(ingredient.displayTitle)
            guard !normalizedName.isEmpty else { return }
            if lookup[normalizedName] == nil {
                lookup[normalizedName] = ingredient
            }
        }

        let stepIngredientMap = Dictionary(grouping: stepIngredients, by: \.recipeStepID)
        let steps = stepRows.map { stepRow in
            let mapped: [RecipeDetailIngredient] = (stepIngredientMap[stepRow.id] ?? []).map { (stepIngredient: SupabaseRecipeStepIngredientRow) -> RecipeDetailIngredient in
                if let ingredientID = stepIngredient.ingredientID,
                   let linked = ingredientByID[ingredientID] {
                    return RecipeDetailIngredient(
                        id: linked.id,
                        ingredientID: linked.ingredientID,
                        displayName: linked.displayTitle,
                        quantityText: stepIngredient.quantityText ?? linked.displayQuantityText,
                        imageURLString: linked.imageURLString,
                        sortOrder: stepIngredient.sortOrder ?? linked.sortOrder
                    )
                }

                if let linkedByName = ingredientByName[SupabaseIngredientsCatalogService.normalizedName(stepIngredient.displayName)] {
                    return RecipeDetailIngredient(
                        id: linkedByName.id,
                        ingredientID: linkedByName.ingredientID,
                        displayName: linkedByName.displayTitle,
                        quantityText: stepIngredient.quantityText ?? linkedByName.displayQuantityText,
                        imageURLString: linkedByName.imageURLString,
                        sortOrder: stepIngredient.sortOrder ?? linkedByName.sortOrder
                    )
                }

                return RecipeDetailIngredient(
                    id: stepIngredient.id,
                    ingredientID: stepIngredient.ingredientID,
                    displayName: stepIngredient.displayName,
                    quantityText: stepIngredient.quantityText,
                    imageURLString: nil,
                    sortOrder: stepIngredient.sortOrder
                )
            }

            return RecipeDetailStep(
                number: stepRow.stepNumber,
                text: stepRow.instructionText,
                tipText: stepRow.tipText,
                ingredientRefs: mapped.map(\.displayName),
                ingredients: mapped
            )
        }

        return RecipeDetailData(
            id: recipe.id,
            title: recipe.title,
            description: recipe.description ?? "",
            authorName: recipe.authorName,
            authorHandle: recipe.authorHandle,
            authorURLString: recipe.authorURLString,
            source: recipe.source,
            sourcePlatform: recipe.sourcePlatform,
            category: recipe.category,
            subcategory: recipe.subcategory,
            recipeType: recipe.recipeType,
            skillLevel: recipe.skillLevel,
            cookTimeText: recipe.cookTimeText,
            servingsText: recipe.servingsText,
            servingSizeText: recipe.servingSizeText,
            dailyDietText: recipe.dailyDietText,
            estCostText: recipe.estCostText,
            estCaloriesText: recipe.estCaloriesText,
            carbsText: recipe.carbsText,
            proteinText: recipe.proteinText,
            fatsText: recipe.fatsText,
            caloriesKcal: recipe.caloriesKcal,
            proteinG: recipe.proteinG,
            carbsG: recipe.carbsG,
            fatG: recipe.fatG,
            prepTimeMinutes: recipe.prepTimeMinutes,
            cookTimeMinutes: recipe.cookTimeMinutes,
            heroImageURLString: recipe.heroImageURLString,
            discoverCardImageURLString: recipe.discoverCardImageURLString,
            recipeURLString: recipe.recipeURLString,
            originalRecipeURLString: recipe.originalRecipeURLString,
            attachedVideoURLString: recipe.attachedVideoURLString,
            detailFootnote: recipe.detailFootnote,
            imageCaption: recipe.imageCaption,
            dietaryTags: recipe.dietaryTags ?? [],
            flavorTags: recipe.flavorTags ?? [],
            cuisineTags: recipe.cuisineTags ?? [],
            occasionTags: recipe.occasionTags ?? [],
            mainProtein: recipe.mainProtein,
            cookMethod: recipe.cookMethodValues.first,
            ingredients: ingredients,
            steps: steps,
            servingsCount: nil
        )
    }

    private func enrichCanonicalImages(in detail: RecipeDetailData) async -> RecipeDetailData {
        let rawIngredients = detail.ingredients
        let rawStepIngredients = detail.steps.flatMap(\.ingredients)
        let ingredientIDs = (rawIngredients + rawStepIngredients).compactMap(\.ingredientID)
        let names = (rawIngredients + rawStepIngredients).map(\.displayTitle)
        let quantityResolved = resolvedIngredientQuantities(
            ingredients: rawIngredients,
            steps: detail.steps
        )

        guard !ingredientIDs.isEmpty || !names.isEmpty else {
            return detail.replacing(
                ingredients: quantityResolved.ingredients,
                steps: quantityResolved.steps
            )
        }

        guard let canonicalRecords = try? await SupabaseIngredientsCatalogService.shared.fetchIngredients(
            ingredientIDs: ingredientIDs,
            normalizedNames: names
        ) else {
            return detail.replacing(
                ingredients: quantityResolved.ingredients,
                steps: quantityResolved.steps
            )
        }

        let canonicalIndex = CanonicalIngredientImageIndex(records: canonicalRecords)
        let ingredients = quantityResolved.ingredients.map(canonicalIndex.enrich(_:))
        let steps = quantityResolved.steps.map { step in
            step.replacingIngredients(step.ingredients.map(canonicalIndex.enrich(_:)))
        }

        return detail.replacing(ingredients: ingredients, steps: steps)
    }

    private func resolvedIngredientQuantities(
        ingredients: [RecipeDetailIngredient],
        steps: [RecipeDetailStep]
    ) -> (ingredients: [RecipeDetailIngredient], steps: [RecipeDetailStep]) {
        let candidates = ingredients + steps.flatMap(\.ingredients)
        var quantityByID: [String: String] = [:]
        var quantityByName: [String: String] = [:]

        for ingredient in candidates {
            guard let quantity = ingredient.displayQuantityText?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !quantity.isEmpty else {
                continue
            }

            if let ingredientID = ingredient.ingredientID?.trimmingCharacters(in: .whitespacesAndNewlines),
               !ingredientID.isEmpty,
               quantityByID[ingredientID.lowercased()] == nil {
                quantityByID[ingredientID.lowercased()] = quantity
            }

            let key = Self.normalizedIngredientKey(ingredient.displayTitle)
            if !key.isEmpty, quantityByName[key] == nil {
                quantityByName[key] = quantity
            }
        }

        let resolvedIngredients = ingredients.map { ingredient in
            resolveIngredientQuantity(for: ingredient, quantityByID: quantityByID, quantityByName: quantityByName)
        }

        let resolvedSteps = steps.map { step in
            step.replacingIngredients(
                step.ingredients.map { ingredient in
                    resolveIngredientQuantity(for: ingredient, quantityByID: quantityByID, quantityByName: quantityByName)
                }
            )
        }

        return (resolvedIngredients, resolvedSteps)
    }

    private func resolveIngredientQuantity(
        for ingredient: RecipeDetailIngredient,
        quantityByID: [String: String],
        quantityByName: [String: String]
    ) -> RecipeDetailIngredient {
        let existingQuantity = ingredient.displayQuantityText?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard existingQuantity?.isEmpty ?? true else {
            return ingredient
        }

        if let ingredientID = ingredient.ingredientID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !ingredientID.isEmpty,
           let quantity = quantityByID[ingredientID.lowercased()] {
            return ingredient.replacingQuantityText(quantity)
        }

        let key = Self.normalizedIngredientKey(ingredient.displayTitle)
        if let quantity = quantityByName[key] {
            return ingredient.replacingQuantityText(quantity)
        }

        return ingredient
    }

    private static func normalizedIngredientKey(_ value: String) -> String {
        value
            .lowercased()
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func performSupabaseGET<T: Decodable>(url: URL, as type: T.Type) async throws -> T {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue(SupabaseConfig.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(SupabaseConfig.anonKey)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SupabaseProfileStateError.invalidResponse
        }
        guard (200 ... 299).contains(httpResponse.statusCode) else {
            let errorPayload = try? JSONDecoder().decode(SupabaseRestErrorResponse.self, from: data)
            let fallback = "Failed to load recipe detail (\(httpResponse.statusCode))."
            throw SupabaseProfileStateError.requestFailed(errorPayload?.message ?? errorPayload?.error ?? fallback)
        }
        return try JSONDecoder().decode(type, from: data)
    }
}

actor PlannedRecipeRefreshService {
    static let shared = PlannedRecipeRefreshService()

    func refreshedPlannedRecipes(from plannedRecipes: [PlannedRecipe]) async -> [PlannedRecipe] {
        await withTaskGroup(of: (Int, PlannedRecipe).self) { group in
            for (index, plannedRecipe) in plannedRecipes.enumerated() {
                group.addTask {
                    let refreshed = await self.refreshedPlannedRecipe(from: plannedRecipe)
                    return (index, refreshed)
                }
            }

            var resolved = Array(repeating: Optional<PlannedRecipe>.none, count: plannedRecipes.count)
            for await (index, refreshed) in group {
                resolved[index] = refreshed
            }

            return resolved.enumerated().map { index, refreshed in
                refreshed ?? plannedRecipes[index]
            }
        }
    }

    private func refreshedPlannedRecipe(from plannedRecipe: PlannedRecipe) async -> PlannedRecipe {
        do {
            let detail = try await RecipeDetailService.shared.fetchRecipeDetail(id: plannedRecipe.recipe.id, forceRefresh: true)
            let refreshedRecipe = recipePlanModel(
                from: detail,
                targetServings: plannedRecipe.servings,
                fallbackRecipe: plannedRecipe.recipe
            )
            return PlannedRecipe(
                recipe: refreshedRecipe,
                servings: plannedRecipe.servings,
                carriedFromPreviousPlan: plannedRecipe.carriedFromPreviousPlan
            )
        } catch {
            return plannedRecipe
        }
    }
}

actor RecipeVideoResolveService {
    static let shared = RecipeVideoResolveService()

    private var cache: [String: RecipeResolvedVideoData] = [:]

    func resolveVideo(from sourceURL: URL) async throws -> RecipeResolvedVideoData {
        let cacheKey = sourceURL.absoluteString
        if let cached = cache[cacheKey] {
            return cached
        }

        let resolved = try await fetchResolvedVideoFromBackend(sourceURL: sourceURL)
        cache[cacheKey] = resolved
        return resolved
    }

    private func fetchResolvedVideoFromBackend(sourceURL: URL) async throws -> RecipeResolvedVideoData {
        var lastError: Error?
        for baseURL in OunjeDevelopmentServer.candidateBaseURLs {
            do {
                return try await fetchResolvedVideoFromBackend(baseURL: baseURL, sourceURL: sourceURL)
            } catch {
                lastError = error
            }
        }

        throw lastError ?? SupabaseProfileStateError.invalidResponse
    }

    private func fetchResolvedVideoFromBackend(baseURL: String, sourceURL: URL) async throws -> RecipeResolvedVideoData {
        guard
            var components = URLComponents(string: "\(baseURL)/v1/recipe/video/resolve")
        else {
            throw SupabaseProfileStateError.invalidRequest
        }

        components.queryItems = [URLQueryItem(name: "url", value: sourceURL.absoluteString)]
        guard let url = components.url else {
            throw SupabaseProfileStateError.invalidRequest
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 25

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SupabaseProfileStateError.invalidResponse
        }
        guard (200 ... 299).contains(httpResponse.statusCode) else {
            let errorPayload = try? JSONDecoder().decode(SupabaseRestErrorResponse.self, from: data)
            let fallback = "Failed to resolve video (\(httpResponse.statusCode))."
            throw SupabaseProfileStateError.requestFailed(errorPayload?.message ?? errorPayload?.error ?? fallback)
        }

        return try JSONDecoder().decode(RecipeVideoResolveResponse.self, from: data).video
    }
}

struct SupabaseRecipeDetailRow: Decodable {
    let id: String
    let title: String
    let description: String?
    let authorName: String?
    let authorHandle: String?
    let authorURLString: String?
    let source: String?
    let sourcePlatform: String?
    let category: String?
    let subcategory: String?
    let recipeType: String?
    let skillLevel: String?
    let cookTimeText: String?
    let servingsText: String?
    let servingSizeText: String?
    let dailyDietText: String?
    let estCostText: String?
    let estCaloriesText: String?
    let carbsText: String?
    let proteinText: String?
    let fatsText: String?
    let caloriesKcal: Double?
    let proteinG: Double?
    let carbsG: Double?
    let fatG: Double?
    let prepTimeMinutes: Int?
    let cookTimeMinutes: Int?
    let heroImageURLString: String?
    let discoverCardImageURLString: String?
    let recipeURLString: String?
    let originalRecipeURLString: String?
    let attachedVideoURLString: String?
    let detailFootnote: String?
    let imageCaption: String?
    let dietaryTags: [String]?
    let flavorTags: [String]?
    let cuisineTags: [String]?
    let occasionTags: [String]?
    let mainProtein: String?
    let cookMethodValues: [String]

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case description
        case authorName = "author_name"
        case authorHandle = "author_handle"
        case authorURLString = "author_url"
        case source
        case sourcePlatform = "source_platform"
        case category
        case subcategory
        case recipeType = "recipe_type"
        case skillLevel = "skill_level"
        case cookTimeText = "cook_time_text"
        case servingsText = "servings_text"
        case servingSizeText = "serving_size_text"
        case dailyDietText = "daily_diet_text"
        case estCostText = "est_cost_text"
        case estCaloriesText = "est_calories_text"
        case carbsText = "carbs_text"
        case proteinText = "protein_text"
        case fatsText = "fats_text"
        case caloriesKcal = "calories_kcal"
        case proteinG = "protein_g"
        case carbsG = "carbs_g"
        case fatG = "fat_g"
        case prepTimeMinutes = "prep_time_minutes"
        case cookTimeMinutes = "cook_time_minutes"
        case heroImageURLString = "hero_image_url"
        case discoverCardImageURLString = "discover_card_image_url"
        case recipeURLString = "recipe_url"
        case originalRecipeURLString = "original_recipe_url"
        case attachedVideoURLString = "attached_video_url"
        case detailFootnote = "detail_footnote"
        case imageCaption = "image_caption"
        case dietaryTags = "dietary_tags"
        case flavorTags = "flavor_tags"
        case cuisineTags = "cuisine_tags"
        case occasionTags = "occasion_tags"
        case mainProtein = "main_protein"
        case cookMethodValues = "cook_method"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        authorName = try container.decodeIfPresent(String.self, forKey: .authorName)
        authorHandle = try container.decodeIfPresent(String.self, forKey: .authorHandle)
        authorURLString = try container.decodeIfPresent(String.self, forKey: .authorURLString)
        source = try container.decodeIfPresent(String.self, forKey: .source)
        sourcePlatform = try container.decodeIfPresent(String.self, forKey: .sourcePlatform)
        category = try container.decodeIfPresent(String.self, forKey: .category)
        subcategory = try container.decodeIfPresent(String.self, forKey: .subcategory)
        recipeType = try container.decodeIfPresent(String.self, forKey: .recipeType)
        skillLevel = try container.decodeIfPresent(String.self, forKey: .skillLevel)
        cookTimeText = try container.decodeIfPresent(String.self, forKey: .cookTimeText)
        servingsText = try container.decodeIfPresent(String.self, forKey: .servingsText)
        servingSizeText = try container.decodeIfPresent(String.self, forKey: .servingSizeText)
        dailyDietText = try container.decodeIfPresent(String.self, forKey: .dailyDietText)
        estCostText = try container.decodeIfPresent(String.self, forKey: .estCostText)
        estCaloriesText = try container.decodeIfPresent(String.self, forKey: .estCaloriesText)
        carbsText = try container.decodeIfPresent(String.self, forKey: .carbsText)
        proteinText = try container.decodeIfPresent(String.self, forKey: .proteinText)
        fatsText = try container.decodeIfPresent(String.self, forKey: .fatsText)
        caloriesKcal = try container.decodeIfPresent(Double.self, forKey: .caloriesKcal)
        proteinG = try container.decodeIfPresent(Double.self, forKey: .proteinG)
        carbsG = try container.decodeIfPresent(Double.self, forKey: .carbsG)
        fatG = try container.decodeIfPresent(Double.self, forKey: .fatG)
        prepTimeMinutes = try container.decodeIfPresent(Int.self, forKey: .prepTimeMinutes)
        cookTimeMinutes = try container.decodeIfPresent(Int.self, forKey: .cookTimeMinutes)
        heroImageURLString = try container.decodeIfPresent(String.self, forKey: .heroImageURLString)
        discoverCardImageURLString = try container.decodeIfPresent(String.self, forKey: .discoverCardImageURLString)
        recipeURLString = try container.decodeIfPresent(String.self, forKey: .recipeURLString)
        originalRecipeURLString = try container.decodeIfPresent(String.self, forKey: .originalRecipeURLString)
        attachedVideoURLString = try container.decodeIfPresent(String.self, forKey: .attachedVideoURLString)
        detailFootnote = try container.decodeIfPresent(String.self, forKey: .detailFootnote)
        imageCaption = try container.decodeIfPresent(String.self, forKey: .imageCaption)
        dietaryTags = try container.decodeIfPresent([String].self, forKey: .dietaryTags)
        flavorTags = try container.decodeIfPresent([String].self, forKey: .flavorTags)
        cuisineTags = try container.decodeIfPresent([String].self, forKey: .cuisineTags)
        occasionTags = try container.decodeIfPresent([String].self, forKey: .occasionTags)
        mainProtein = try container.decodeIfPresent(String.self, forKey: .mainProtein)
        cookMethodValues = (try? container.decode([String].self, forKey: .cookMethodValues))
            ?? (try? container.decode(String.self, forKey: .cookMethodValues)).map { [$0] }
            ?? []
    }
}

struct SupabaseRecipeStepRow: Decodable {
    let id: String
    let stepNumber: Int
    let instructionText: String
    let tipText: String?

    enum CodingKeys: String, CodingKey {
        case id
        case stepNumber = "step_number"
        case instructionText = "instruction_text"
        case tipText = "tip_text"
    }
}

struct SupabaseRecipeStepIngredientRow: Decodable {
    let id: String
    let recipeStepID: String
    let ingredientID: String?
    let displayName: String
    let quantityText: String?
    let sortOrder: Int?

    enum CodingKeys: String, CodingKey {
        case id
        case recipeStepID = "recipe_step_id"
        case ingredientID = "ingredient_id"
        case displayName = "display_name"
        case quantityText = "quantity_text"
        case sortOrder = "sort_order"
    }
}

