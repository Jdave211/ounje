import Foundation

enum FirstRunGuidePhase: String, Codable, CaseIterable {
    case recipeSuggestion
    case planReady
    case planOpened
    case planShoppingList
    case cartOverview
    case cartSelect
    case cartAlreadyHaveIntro
    case cartIngredient
    case cartAlreadyHave
    case cartScope
    case cartRestoreInfo
    case cartShopNow
    case cartChecklistOption
    case cartChecklistInfo
    case cartChecklistDone
    case discover
    case discoverRecipe
    case recipeSave
    case recipeSavedInfo
    case recipeCommunity
    case recipeShare
    case recipeRemix
    case recipeBack
    case addRecipe
    case completed
    case dismissed
}

enum FirstRunGuideTargetID: String, Hashable {
    case suggestedRecipeOne
    case suggestedRecipeTwo
    case suggestedRecipeThree
    case suggestedRecipeFour
    case firstPlan
    case planRecipes
    case shoppingListButton
    case cartListItemOne
    case cartListItemTwo
    case cartListItemThree
    case cartListItemFour
    case cartListItemFive
    case cartSelect
    case cartAlreadyHaveIntro
    case cartIngredient
    case cartAlreadyHave
    case cartScope
    case cartRestoreSelect
    case shopNow
    case checklistOption
    case checklistDone
    case discoverTab
    case discoverRecipe
    case recipeSave
    case recipeSavedInfo
    case recipeCommunity
    case recipeShare
    case recipeRemix
    case recipeBack
    case addRecipe

    static let suggestedRecipeTargets: [FirstRunGuideTargetID] = [
        .suggestedRecipeOne,
        .suggestedRecipeTwo,
        .suggestedRecipeThree,
        .suggestedRecipeFour
    ]

    static func suggestedRecipeTarget(at index: Int) -> FirstRunGuideTargetID? {
        suggestedRecipeTargets.indices.contains(index) ? suggestedRecipeTargets[index] : nil
    }

    static let cartListItemTargets: [FirstRunGuideTargetID] = [
        .cartListItemOne,
        .cartListItemTwo,
        .cartListItemThree,
        .cartListItemFour,
        .cartListItemFive
    ]

    static func cartListItemTarget(at index: Int?) -> FirstRunGuideTargetID? {
        guard let index, cartListItemTargets.indices.contains(index) else { return nil }
        return cartListItemTargets[index]
    }

    var isSuggestedRecipeTarget: Bool {
        Self.suggestedRecipeTargets.contains(self)
    }

    var isCartListItemTarget: Bool {
        Self.cartListItemTargets.contains(self)
    }
}

struct FirstRunGuideCatalog: Decodable {
    static let profileSeedSignalPrefix = "First guide recipe:"
    static let currentVersion = 1

    let version: Int
    let templates: [Template]
    let planPresets: [PlanPreset]
    let safeSuggestionIDsByDiet: [String: [String]]

    struct Template: Decodable {
        let seedRecipeID: String
        let presetPlanIDs: [String]
        let displayCopy: DisplayCopy

        enum CodingKeys: String, CodingKey {
            case seedRecipeID = "seed_recipe_id"
            case presetPlanIDs = "preset_plan_ids"
            case legacyPresetPlanID = "preset_plan_id"
            case displayCopy = "display_copy"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            seedRecipeID = try container.decode(String.self, forKey: .seedRecipeID)
            displayCopy = try container.decode(DisplayCopy.self, forKey: .displayCopy)
            if let planIDs = try container.decodeIfPresent([String].self, forKey: .presetPlanIDs),
               !planIDs.isEmpty {
                presetPlanIDs = planIDs
            } else {
                presetPlanIDs = [try container.decode(String.self, forKey: .legacyPresetPlanID)]
            }
        }
    }

    /// A complete, editorially-defined plan. The guide only fetches these
    /// fixed recipe IDs; it never searches for recipes related to the saved pick.
    struct PlanPreset: Decodable {
        let id: String
        let title: String
        let recipeIDs: [String]
        let dietaryCompatibilityTags: [String]
        let allergenExclusions: [String]
        let selectionTags: [String]

        enum CodingKeys: String, CodingKey {
            case id
            case title
            case recipeIDs = "recipe_ids"
            case dietaryCompatibilityTags = "dietary_compatibility_tags"
            case allergenExclusions = "allergen_exclusions"
            case selectionTags = "selection_tags"
        }
    }

    struct DisplayCopy: Decodable {
        let suggestionTitle: String
        let planTitle: String

        enum CodingKeys: String, CodingKey {
            case suggestionTitle = "suggestion_title"
            case planTitle = "plan_title"
        }
    }

    enum CodingKeys: String, CodingKey {
        case version
        case templates
        case planPresets = "plan_presets"
        case safeSuggestionIDsByDiet = "safe_suggestion_ids_by_diet"
    }

    func planPreset(id: String) -> PlanPreset? {
        planPresets.first(where: { $0.id == id })
    }

    static func load() -> FirstRunGuideCatalog? {
        guard
            let url = Bundle.main.url(forResource: "FirstRunGuideCatalog.v1", withExtension: "json"),
            let data = try? Data(contentsOf: url)
        else { return nil }
        return try? JSONDecoder().decode(FirstRunGuideCatalog.self, from: data)
    }

    static func seedRecipeID(in profile: UserProfile?) -> String? {
        profile?.mealPrepGoals
            .first(where: { $0.hasPrefix(profileSeedSignalPrefix) })?
            .dropFirst(profileSeedSignalPrefix.count)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct FirstRunGuideProgress: Codable, Equatable {
    let userID: String
    var catalogVersion: Int
    var phase: FirstRunGuidePhase
    var seedRecipeID: String
    var presetPlanID: String?
    var planID: UUID
    var isReplay: Bool
    var updatedAt: Date
    var completedAt: Date?
    var dismissedAt: Date?
}

extension RecipeDetailData {
    var firstRunGuideCard: DiscoverRecipeCardData {
        DiscoverRecipeCardData(
            id: id,
            title: title,
            description: description,
            authorName: authorName,
            authorHandle: authorHandle,
            category: category,
            recipeType: recipeType,
            cookTimeText: combinedCookTimeText,
            cookTimeMinutes: cookTimeMinutes ?? prepTimeMinutes,
            publishedDate: nil,
            imageURLString: discoverCardImageURLString,
            heroImageURLString: heroImageURLString,
            recipeURLString: recipeURLString ?? originalRecipeURLString,
            source: source ?? sourcePlatform
        )
    }
}
