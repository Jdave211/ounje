import Foundation
import Combine

@MainActor
final class FirstRunGuideCoordinator: ObservableObject {
    @Published private(set) var progress: FirstRunGuideProgress?
    @Published private(set) var suggestedRecipes: [DiscoverRecipeCardData] = []
    @Published private(set) var presetPlanRecipeDetails: [RecipeDetailData] = []
    @Published private(set) var presetPlanTitle: String?
    @Published private(set) var isLoadingCatalog = false
    @Published private(set) var isSpotlightSuspended = false

    private let defaults: UserDefaults
    private var accessToken: String?
    private var catalog: FirstRunGuideCatalog?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var phase: FirstRunGuidePhase? { progress?.phase }
    var isActive: Bool {
        guard let phase else { return false }
        return phase != .completed && phase != .dismissed
    }
    var isReplay: Bool { progress?.isReplay == true }
    var planID: UUID? { progress?.planID }

    var currentTargets: [FirstRunGuideTargetID] {
        guard !isSpotlightSuspended else { return [] }
        switch phase {
        case .recipeSuggestion: return FirstRunGuideTargetID.suggestedRecipeTargets
        case .planReady: return [.firstPlan]
        case .planOpened: return [.planRecipes]
        case .planShoppingList: return [.shoppingListButton]
        case .cartOverview, .cartChecklistInfo: return FirstRunGuideTargetID.cartListItemTargets
        case .cartSelect: return [.cartSelect]
        case .cartAlreadyHaveIntro: return [.cartAlreadyHaveIntro]
        case .cartIngredient: return [.cartIngredient]
        case .cartAlreadyHave: return [.cartAlreadyHave]
        case .cartScope: return [.cartScope]
        case .cartRestoreInfo: return [.cartRestoreSelect]
        case .cartShopNow: return [.shopNow]
        case .cartChecklistOption: return [.checklistOption]
        case .cartChecklistDone: return [.checklistDone]
        case .discover: return [.discoverTab]
        case .discoverRecipe: return [.discoverRecipe]
        case .recipeSave: return [.recipeSave]
        case .recipeSavedInfo: return [.recipeSavedInfo]
        case .recipeCommunity: return [.recipeCommunity]
        case .recipeShare: return [.recipeShare]
        case .recipeRemix: return [.recipeRemix]
        case .recipeBack: return [.recipeBack]
        case .addRecipe: return [.addRecipe]
        case .completed, .dismissed, .none: return []
        }
    }

    var coachmark: String {
        switch phase {
        case .recipeSuggestion: return "Choose a recipe to save and start your plan."
        case .planReady: return "Your Starter plan is ready. Tap it to open."
        case .planOpened: return "We’ve built a plan you might like."
        case .planShoppingList: return "You can shop for every recipe at once."
        case .cartOverview: return "Everything in your plan comes together in one shopping list."
        case .cartSelect: return "Tap Select to organize your list."
        case .cartAlreadyHaveIntro: return "Hopefully your kitchen isn’t empty. Set aside what you already have here."
        case .cartIngredient: return "Choose an ingredient you already have."
        case .cartAlreadyHave: return "Move the selected ingredient to Already have."
        case .cartScope: return "Open Already have to see what you set aside."
        case .cartRestoreInfo: return "Ran out of something? Use Select to move it back to To buy."
        case .cartShopNow: return "Shop now shows the ways Ounje can help with this list."
        case .cartChecklistOption: return "Use your cart as a checklist while you shop."
        case .cartChecklistInfo: return "Tap items as you shop to cross them off."
        case .cartChecklistDone: return "Tap Done when you’re finished shopping."
        case .discover: return "Next: Discover what’s popping."
        case .discoverRecipe: return "See what people are cooking."
        case .recipeSave: return "Save this recipe for later."
        case .recipeSavedInfo: return "Saved to your recipes."
        case .recipeCommunity: return "What do you think of this one? Tap a star to rate it."
        case .recipeShare: return "Share this recipe with your friends."
        case .recipeRemix: return "Make it yours with Remix."
        case .recipeBack: return "Head back to Discover."
        case .addRecipe: return "Let’s get started: add a recipe here, or share one to Ounje from anywhere."
        case .completed, .dismissed, .none: return ""
        }
    }

    func bootstrap(userID: String?, profile: UserProfile?, accessToken: String?) async {
        guard let userID, !userID.isEmpty else {
            resetInMemory()
            return
        }
        self.accessToken = accessToken
        isSpotlightSuspended = false
        catalog = FirstRunGuideCatalog.load()

        let local = loadLocal(userID: userID)
        let remote = await FirstRunGuideProgressService.shared.fetch(userID: userID, accessToken: accessToken)
        let newest = [local, remote]
            .compactMap { $0 }
            .filter { !$0.isReplay }
            .max(by: { $0.updatedAt < $1.updatedAt })

        if var newest {
            if newest.phase == .recipeSuggestion,
               let profileSeedID = FirstRunGuideCatalog.seedRecipeID(in: profile),
               catalog?.templates.contains(where: { $0.seedRecipeID == profileSeedID }) == true {
                newest.seedRecipeID = profileSeedID
                newest.presetPlanID = nil
                newest.updatedAt = .now
            }
            if newest.presetPlanID == nil,
               let catalog,
               let template = catalog.templates.first(where: { $0.seedRecipeID == newest.seedRecipeID }),
               let mappedPresetID = choosePresetPlanID(
                    for: template,
                    in: catalog,
                    profile: profile,
                    userID: userID
               ) {
                newest.presetPlanID = mappedPresetID
                newest.updatedAt = .now
            }
            // Temporary surfaces are not restored across launches. Resume from
            // the nearest real screen where the next target can be reached.
            if newest.phase == .planOpened || newest.phase == .planShoppingList {
                newest.phase = .planReady
                newest.updatedAt = .now
            } else if newest.phase == .cartChecklistOption {
                newest.phase = .cartShopNow
                newest.updatedAt = .now
            } else if [
                FirstRunGuidePhase.recipeCommunity,
                .recipeSave,
                .recipeSavedInfo,
                .recipeShare,
                .recipeRemix,
                .recipeBack
            ].contains(newest.phase) {
                newest.phase = .discoverRecipe
                newest.updatedAt = .now
            }
            progress = newest
            persist(newest)
            if isActive { await loadGuideRecipes(profile: profile) }
            return
        }

        guard let seedRecipeID = FirstRunGuideCatalog.seedRecipeID(in: profile),
              let catalog,
              let selectedTemplate = catalog.templates.first(where: { $0.seedRecipeID == seedRecipeID }),
              let presetPlanID = choosePresetPlanID(
                for: selectedTemplate,
                in: catalog,
                profile: profile,
                userID: userID
              )
        else {
            resetInMemory()
            return
        }

        let initial = FirstRunGuideProgress(
            userID: userID,
            catalogVersion: catalog.version,
            phase: .recipeSuggestion,
            seedRecipeID: selectedTemplate.seedRecipeID,
            presetPlanID: presetPlanID,
            planID: UUID(),
            isReplay: false,
            updatedAt: .now,
            completedAt: nil,
            dismissedAt: nil
        )
        progress = initial
        persist(initial)
        await loadGuideRecipes(profile: profile)
    }

    func replay(userID: String?, profile: UserProfile?, accessToken: String?) async {
        guard let userID, !userID.isEmpty, let catalog = FirstRunGuideCatalog.load() else { return }
        self.catalog = catalog
        self.accessToken = accessToken
        isSpotlightSuspended = false
        let profileSeedID = FirstRunGuideCatalog.seedRecipeID(in: profile)
        let seedID = profileSeedID.flatMap { candidate in
            catalog.templates.first(where: { $0.seedRecipeID == candidate })?.seedRecipeID
        } ?? catalog.templates.first?.seedRecipeID ?? ""
        guard
            !seedID.isEmpty,
            let selectedTemplate = catalog.templates.first(where: { $0.seedRecipeID == seedID }),
            let presetPlanID = choosePresetPlanID(
                for: selectedTemplate,
                in: catalog,
                profile: profile,
                userID: userID
            )
        else { return }
        let replay = FirstRunGuideProgress(
            userID: userID,
            catalogVersion: catalog.version,
            phase: .recipeSuggestion,
            seedRecipeID: seedID,
            presetPlanID: presetPlanID,
            planID: UUID(),
            isReplay: true,
            updatedAt: .now,
            completedAt: nil,
            dismissedAt: nil
        )
        progress = replay
        await loadGuideRecipes(profile: profile)
    }

    func advance(to nextPhase: FirstRunGuidePhase) {
        guard var next = progress, next.phase != .completed, next.phase != .dismissed else { return }
        next.phase = nextPhase
        next.updatedAt = .now
        if nextPhase == .completed { next.completedAt = .now }
        progress = next
        persist(next)
    }

    /// Records the one recipe the person selected, then loads its complete
    /// editorial preset. No recipes are searched for or assembled at runtime.
    func selectStarterRecipe(_ recipeID: String, profile: UserProfile?) async -> Bool {
        guard var next = progress,
              next.phase == .recipeSuggestion,
              let catalog,
              let selectedTemplate = catalog.templates.first(where: { $0.seedRecipeID == recipeID }),
              let presetPlanID = choosePresetPlanID(
                for: selectedTemplate,
                in: catalog,
                profile: profile,
                userID: next.userID
              )
        else { return false }

        if next.seedRecipeID == selectedTemplate.seedRecipeID,
           next.presetPlanID == presetPlanID,
           !presetPlanRecipeDetails.isEmpty {
            return true
        }

        next.seedRecipeID = selectedTemplate.seedRecipeID
        next.presetPlanID = presetPlanID
        next.updatedAt = .now
        progress = next
        persist(next)
        await loadGuideRecipes(profile: profile)
        return !presetPlanRecipeDetails.isEmpty
    }

    func setSpotlightSuspended(_ suspended: Bool) {
        isSpotlightSuspended = suspended
    }

    func advanceCoachmark() {
        switch phase {
        case .planOpened:
            advance(to: .planShoppingList)
        case .cartOverview:
            advance(to: .cartAlreadyHaveIntro)
        case .cartAlreadyHaveIntro:
            advance(to: .cartSelect)
        case .cartRestoreInfo:
            advance(to: .cartShopNow)
        case .recipeSavedInfo:
            advance(to: .recipeCommunity)
        case .recipeShare:
            advance(to: .recipeRemix)
        case .recipeRemix:
            advance(to: .recipeBack)
        default:
            return
        }
    }

    var showsCoachmarkAdvance: Bool {
        phase == .planOpened
            || phase == .cartOverview
            || phase == .cartAlreadyHaveIntro
            || phase == .cartRestoreInfo
            || phase == .recipeSavedInfo
            || phase == .recipeShare
            || phase == .recipeRemix
    }

    func dismiss() {
        guard var next = progress else { return }
        isSpotlightSuspended = false
        next.phase = .dismissed
        next.dismissedAt = .now
        next.updatedAt = .now
        progress = next
        persist(next)
    }

    private func loadGuideRecipes(profile: UserProfile?) async {
        guard let catalog, let progress else { return }
        isLoadingCatalog = true
        defer { isLoadingCatalog = false }

        let presetPlanID = progress.presetPlanID
        let presetPlan = presetPlanID.flatMap { catalog.planPreset(id: $0) }
        let selectedTemplate = catalog.templates.first { $0.seedRecipeID == progress.seedRecipeID }
        let planIDs = presetPlan?.recipeIDs ?? []
        let starterRecipeIDs = stableUnique(
            [progress.seedRecipeID]
                + catalog.templates.map(\.seedRecipeID).filter { $0 != progress.seedRecipeID }
        )

        let details = await fetchDetails(ids: stableUnique(planIDs + starterRecipeIDs), accessToken: accessToken)
        let byID = Dictionary(uniqueKeysWithValues: details.map { ($0.id, $0) })
        suggestedRecipes = starterRecipeIDs.compactMap { byID[$0]?.firstRunGuideCard }
        let fetchedPresetDetails = planIDs.compactMap { byID[$0] }
        if !planIDs.isEmpty, fetchedPresetDetails.count == planIDs.count {
            presetPlanRecipeDetails = fetchedPresetDetails
            presetPlanTitle = selectedTemplate?.displayCopy.planTitle ?? "Starter"
        } else {
            presetPlanRecipeDetails = []
            presetPlanTitle = nil
        }
    }

    private func fetchDetails(ids: [String], accessToken: String?) async -> [RecipeDetailData] {
        await withTaskGroup(of: RecipeDetailData?.self) { group in
            for id in ids {
                group.addTask {
                    try? await RecipeDetailService.shared.fetchRecipeDetail(id: id, accessToken: accessToken)
                }
            }
            var values: [RecipeDetailData] = []
            for await detail in group {
                if let detail, detail.hasCoreRecipeContent, detail.imageURL != nil { values.append(detail) }
            }
            return values
        }
    }

    /// Chooses one complete editorial preset and persists its ID with guide
    /// progress. Recipe IDs always come from the preset; this never performs a
    /// recipe search or constructs a plan dynamically.
    private func choosePresetPlanID(
        for template: FirstRunGuideCatalog.Template,
        in catalog: FirstRunGuideCatalog,
        profile: UserProfile?,
        userID: String
    ) -> String? {
        let mappedPresets = template.presetPlanIDs.compactMap { catalog.planPreset(id: $0) }
        guard !mappedPresets.isEmpty else { return nil }

        let compatiblePresets = mappedPresets.filter { presetIsCompatible($0, profile: profile) }
        let candidates = compatiblePresets.isEmpty ? mappedPresets : compatiblePresets
        let profileSignals = presetSelectionSignals(profile)
        let scored = candidates.map { preset in
            let presetSignals = normalizedSelectionSignals(preset.selectionTags)
            return (preset: preset, score: presetSignals.intersection(profileSignals).count)
        }
        let highestScore = scored.map(\.score).max() ?? 0
        let finalists = scored
            .filter { $0.score == highestScore }
            .map(\.preset)
            .sorted { $0.id < $1.id }
        guard !finalists.isEmpty else { return nil }

        let stableInput = ([userID, template.seedRecipeID] + profileSignals.sorted())
            .joined(separator: "|")
        return finalists[stableBucket(for: stableInput, count: finalists.count)].id
    }

    private func presetSelectionSignals(_ profile: UserProfile?) -> Set<String> {
        guard let profile else { return [] }
        var values = profile.preferredCuisines.flatMap { [$0.rawValue, $0.title] }
        values.append(contentsOf: profile.cuisineCountries)
        values.append(contentsOf: profile.favoriteFoods)
        values.append(contentsOf: profile.favoriteFlavors)
        values.append(contentsOf: profile.foodGoals)
        values.append(contentsOf: profile.mealPrepGoals.filter {
            !$0.hasPrefix(FirstRunGuideCatalog.profileSeedSignalPrefix)
        })
        values.append(profile.foodPersona)
        return normalizedSelectionSignals(values)
    }

    private func normalizedSelectionSignals(_ values: [String]) -> Set<String> {
        var signals = Set<String>()
        for value in values {
            let normalized = value
                .lowercased()
                .replacingOccurrences(of: "_", with: " ")
                .replacingOccurrences(of: "-", with: " ")
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .map(String.init)
            if !normalized.isEmpty {
                signals.insert(normalized.joined(separator: " "))
            }
            signals.formUnion(normalized.filter { $0.count > 2 })
        }
        return signals
    }

    private func stableBucket(for value: String, count: Int) -> Int {
        guard count > 1 else { return 0 }
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return Int(hash % UInt64(count))
    }

    private func presetIsCompatible(_ preset: FirstRunGuideCatalog.PlanPreset, profile: UserProfile?) -> Bool {
        guard let profile else { return true }
        let diets = Set(profile.dietaryPatterns.map { $0.lowercased() })
        let compatible = Set(preset.dietaryCompatibilityTags.map { $0.lowercased() })
        if !diets.isEmpty, !diets.isSubset(of: compatible) { return false }
        let allergens = normalizedRestrictions(profile)
        let excluded = Set(preset.allergenExclusions.map { $0.lowercased() })
        return allergens.isSubset(of: excluded)
    }

    private func detailIsSafe(_ detail: RecipeDetailData, profile: UserProfile?) -> Bool {
        guard let profile else { return true }
        let tags = Set(detail.dietaryTags.map { $0.lowercased() })
        for diet in profile.dietaryPatterns.map({ $0.lowercased() }) {
            let compatible: Bool
            switch diet {
            case "omnivore":
                // Omnivore is the absence of a dietary restriction, and the
                // public recipe catalog does not require a matching tag for it.
                compatible = true
            case "keto":
                compatible = tags.contains("keto") || tags.contains("low-carb")
            case "vegetarian":
                compatible = tags.contains("vegetarian") || tags.contains("vegan")
            case "dairy-free":
                compatible = tags.contains("dairy-free") || tags.contains("vegan")
            default:
                compatible = tags.contains(diet)
            }
            if !compatible { return false }
        }
        let restrictions = expandedIngredientRestrictions(from: normalizedRestrictions(profile))
        guard !restrictions.isEmpty else { return true }
        let ingredientText = detail.ingredients
            .map { $0.displayTitle.lowercased() }
            .joined(separator: " ")
        return !restrictions.contains(where: { ingredientText.contains($0) })
    }

    private func expandedIngredientRestrictions(from restrictions: Set<String>) -> Set<String> {
        var expanded = restrictions
        for restriction in restrictions {
            if restriction.contains("dairy") || restriction == "milk" {
                expanded.formUnion(["milk", "cheese", "butter", "cream", "whey", "casein", "yogurt", "yoghurt"])
            }
            if restriction.contains("gluten") || restriction == "wheat" {
                expanded.formUnion(["wheat", "flour", "bread", "pasta", "barley", "rye"])
            }
            if restriction.contains("shellfish") {
                expanded.formUnion(["shrimp", "prawn", "crab", "lobster", "crayfish"])
            }
            if restriction.contains("tree nut") || restriction == "nuts" || restriction == "nut" {
                expanded.formUnion(["almond", "cashew", "walnut", "pecan", "pistachio", "hazelnut", "macadamia"])
            }
            if restriction == "soy" || restriction.contains("soya") {
                expanded.formUnion(["soy", "soya", "tofu", "edamame", "miso", "tempeh"])
            }
        }
        return expanded
    }

    private func stableUnique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    private func normalizedRestrictions(_ profile: UserProfile) -> Set<String> {
        Set((profile.allergies + profile.hardRestrictions + profile.neverIncludeFoods)
            .flatMap { $0.lowercased().split(whereSeparator: { $0 == "," || $0 == ";" }).map(String.init) }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0 != "none" })
    }

    private func storageKey(userID: String) -> String {
        "ounje-first-run-guide-v\(FirstRunGuideCatalog.currentVersion)-\(userID)"
    }

    private func loadLocal(userID: String) -> FirstRunGuideProgress? {
        guard let data = defaults.data(forKey: storageKey(userID: userID)) else { return nil }
        return try? JSONDecoder.ounjeGuide.decode(FirstRunGuideProgress.self, from: data)
    }

    private func persist(_ value: FirstRunGuideProgress) {
        // A replay is a disposable, local preview. It must never alter the
        // person's onboarding state or write any guide data cross-device.
        guard !value.isReplay else { return }
        if let data = try? JSONEncoder.ounjeGuide.encode(value) {
            defaults.set(data, forKey: storageKey(userID: value.userID))
        }
        Task(priority: .utility) {
            await FirstRunGuideProgressService.shared.upsert(value, accessToken: accessToken)
        }
    }

    private func resetInMemory() {
        progress = nil
        suggestedRecipes = []
        presetPlanRecipeDetails = []
        presetPlanTitle = nil
        isSpotlightSuspended = false
    }
}

private extension JSONEncoder {
    static var ounjeGuide: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var ounjeGuide: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)

            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: value) { return date }

            let standard = ISO8601DateFormatter()
            standard.formatOptions = [.withInternetDateTime]
            if let date = standard.date(from: value) { return date }

            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Expected an ISO-8601 timestamp."
            )
        }
        return decoder
    }
}

private actor FirstRunGuideProgressService {
    static let shared = FirstRunGuideProgressService()

    private struct PendingUpsert {
        let progress: FirstRunGuideProgress
        let accessToken: String?
    }

    private var pendingUpserts: [String: PendingUpsert] = [:]
    private var drainingUserIDs = Set<String>()
    private var latestAcceptedUpdateByUser: [String: Date] = [:]

    private struct Row: Codable {
        let userID: String
        let catalogVersion: Int
        let phase: String
        let seedRecipeID: String
        let presetPlanID: String?
        let planID: String
        let isReplay: Bool
        let updatedAt: Date
        let completedAt: Date?
        let dismissedAt: Date?

        enum CodingKeys: String, CodingKey {
            case userID = "user_id"
            case catalogVersion = "catalog_version"
            case phase
            case seedRecipeID = "seed_recipe_id"
            case presetPlanID = "preset_plan_id"
            case planID = "plan_id"
            case isReplay = "is_replay"
            case updatedAt = "updated_at"
            case completedAt = "completed_at"
            case dismissedAt = "dismissed_at"
        }

        init(progress: FirstRunGuideProgress) {
            userID = progress.userID
            catalogVersion = progress.catalogVersion
            phase = progress.phase.rawValue
            seedRecipeID = progress.seedRecipeID
            presetPlanID = progress.presetPlanID
            planID = progress.planID.uuidString
            isReplay = progress.isReplay
            updatedAt = progress.updatedAt
            completedAt = progress.completedAt
            dismissedAt = progress.dismissedAt
        }

        var progress: FirstRunGuideProgress? {
            guard let phase = FirstRunGuidePhase(rawValue: phase), let planID = UUID(uuidString: planID) else { return nil }
            return FirstRunGuideProgress(
                userID: userID,
                catalogVersion: catalogVersion,
                phase: phase,
                seedRecipeID: seedRecipeID,
                presetPlanID: presetPlanID,
                planID: planID,
                isReplay: isReplay,
                updatedAt: updatedAt,
                completedAt: completedAt,
                dismissedAt: dismissedAt
            )
        }
    }

    func fetch(userID: String, accessToken: String?) async -> FirstRunGuideProgress? {
        guard let request = request(
            path: "first_run_guide_progress?select=*&user_id=eq.\(userID)&limit=1",
            accessToken: accessToken,
            method: "GET"
        ) else { return nil }
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        let decoder = JSONDecoder.ounjeGuide
        return (try? decoder.decode([Row].self, from: data))?.first?.progress
    }

    func upsert(_ progress: FirstRunGuideProgress, accessToken: String?) async {
        if let latestAccepted = latestAcceptedUpdateByUser[progress.userID],
           progress.updatedAt < latestAccepted {
            return
        }
        latestAcceptedUpdateByUser[progress.userID] = progress.updatedAt
        pendingUpserts[progress.userID] = PendingUpsert(progress: progress, accessToken: accessToken)
        guard drainingUserIDs.insert(progress.userID).inserted else { return }

        while let pending = pendingUpserts.removeValue(forKey: progress.userID) {
            await sendUpsert(pending.progress, accessToken: pending.accessToken)
        }
        drainingUserIDs.remove(progress.userID)
    }

    private func sendUpsert(_ progress: FirstRunGuideProgress, accessToken: String?) async {
        guard let body = try? JSONEncoder.ounjeGuide.encode(Row(progress: progress)),
              var request = request(
                path: "first_run_guide_progress?on_conflict=user_id",
                accessToken: accessToken,
                method: "POST"
              ) else { return }
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("resolution=merge-duplicates,return=minimal", forHTTPHeaderField: "Prefer")
        _ = try? await URLSession.shared.data(for: request)
    }

    private func request(path: String, accessToken: String?, method: String) -> URLRequest? {
        guard let url = URL(string: "\(SupabaseConfig.url)/rest/v1/\(path)") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 12
        request.setValue(SupabaseConfig.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(accessToken ?? SupabaseConfig.anonKey)", forHTTPHeaderField: "Authorization")
        return request
    }
}
