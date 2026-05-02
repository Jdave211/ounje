import Foundation

struct RecipeIngredient: Codable, Hashable {
    var name: String
    var amount: Double
    var unit: String
    var estimatedUnitPrice: Double
}

struct StorageFootprint: Codable, Hashable {
    var pantry: Int
    var fridge: Int
    var freezer: Int

    static let low = StorageFootprint(pantry: 1, fridge: 1, freezer: 0)
    static let medium = StorageFootprint(pantry: 2, fridge: 2, freezer: 1)
    static let high = StorageFootprint(pantry: 2, fridge: 3, freezer: 3)
}

struct Recipe: Identifiable, Codable, Hashable {
    var id: String
    var title: String
    var cuisine: CuisinePreference
    var prepMinutes: Int
    var servings: Int
    var storageFootprint: StorageFootprint
    var tags: [String]
    var ingredients: [RecipeIngredient]
    var cardImageURLString: String? = nil
    var heroImageURLString: String? = nil
    var source: String? = nil
}

enum PrepRegenerationFocus: String, CaseIterable, Hashable, Identifiable {
    case balanced
    case closerToFavorites
    case moreVariety
    case lessPrepTime
    case tighterOverlap
    case savedRecipeRefresh

    var id: String { rawValue }

    static var allCases: [PrepRegenerationFocus] {
        [
            .balanced,
            .closerToFavorites,
            .moreVariety,
            .lessPrepTime,
            .tighterOverlap
        ]
    }
}

struct PrepGenerationOptions: Hashable {
    var focus: PrepRegenerationFocus = .balanced
    var targetRecipeCount: Int? = nil
    var userPrompt: String? = nil
    var rerollNonce: String? = nil

    static let standard = PrepGenerationOptions()
}

struct PrepRegenerationContext: Hashable {
    var focus: PrepRegenerationFocus
    var targetRecipeCount: Int? = nil
    var currentRecipes: [Recipe]
    var userPrompt: String? = nil
    var rerollNonce: String? = nil
}

extension Recipe {
    var isLegacySeedRecipe: Bool {
        let looksLikeSeedID = id.range(of: #"^[a-z]{2}-\d{3}$"#, options: .regularExpression) != nil
        return looksLikeSeedID && cardImageURLString == nil && heroImageURLString == nil
    }

    var isKnownSampleRecipe: Bool {
        let normalizedTitle = title
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9\\s]", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let exactSamples: Set<String> = [
            "chipotle chicken burrito bowls",
            "bbq chicken sweet potato skillet",
            "sheet pan lemon chicken"
        ]

        if exactSamples.contains(normalizedTitle) {
            return true
        }

        if normalizedTitle.contains("roasted")
            && normalizedTitle.contains("quinoa")
            && normalizedTitle.contains("chicken")
        {
            return true
        }

        return false
    }

    var isImagePoor: Bool {
        let card = cardImageURLString?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let hero = heroImageURLString?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return card.isEmpty && hero.isEmpty
    }
}
