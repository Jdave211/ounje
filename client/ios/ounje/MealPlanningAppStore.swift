import Foundation

@MainActor
final class MealPlanningAppStore: ObservableObject {
    @Published var authSession: AuthSession?
    @Published var isOnboarded = false
    @Published var profile: UserProfile?
    @Published var latestPlan: MealPlan?
    @Published var planHistory: [MealPlan] = []
    @Published var isGenerating = false
    @Published var isHydratingRemoteState = false
    @Published var hasResolvedInitialState = false
    @Published var lastOnboardingStep = 0

    private let planner = MealPlanningAgent()
    private var activeGenerationToken = UUID()
    private var prepRecipeOverrides: [PrepRecipeOverride] = []

    private let authSessionKey = "agentic-auth-session-v1"
    private let onboardedKey = "agentic-onboarded-v1"
    private let profileKey = "agentic-meal-profile-v1"
    private let historyKeyPrefix = "agentic-meal-history-v2"
    private let legacyHistoryKey = "agentic-meal-history-v1"
    private let onboardingStepKey = "agentic-onboarding-step-v1"
    static let googleDevUserIDKey = "agentic-google-dev-user-id-v1"
    static let googleDevEmailKey = "agentic-google-dev-email-v1"
    private var activeHistoryUserID: String?

    init() {
        loadState()
    }

    var nextRunDate: Date? {
        guard let profile else { return nil }
        return profile.scheduledDeliveryDate()
    }

    var isAuthenticated: Bool {
        authSession != nil
    }

    var requiresProfileOnboarding: Bool {
        guard isAuthenticated, hasResolvedInitialState else { return false }
        return !isOnboarded
    }

    func signIn(
        with session: AuthSession,
        onboarded: Bool,
        profile remoteProfile: UserProfile? = nil,
        lastOnboardingStep remoteStep: Int = 0
    ) {
        if activeHistoryUserID != session.userID {
            loadHistory(for: session.userID)
        }
        if let remoteProfile {
            profile = remoteProfile
            saveProfile()
        } else if profile == nil {
            profile = .starter
            saveProfile()
        }
        authSession = session
        isOnboarded = onboarded
        lastOnboardingStep = remoteStep
        hasResolvedInitialState = true
        saveAuthSession()
        saveOnboardingState()
        saveOnboardingStep()
    }

    func completeOnboarding(with profile: UserProfile, lastStep: Int) {
        self.profile = profile
        isOnboarded = true
        lastOnboardingStep = lastStep
        hasResolvedInitialState = true
        saveProfile()
        saveOnboardingState()
        saveOnboardingStep()

        Task {
            await generatePlan()
        }
    }

    func updateProfile(_ updated: UserProfile) {
        profile = updated
        saveProfile()

        guard let session = authSession else { return }
        Task(priority: .utility) {
            try? await SupabaseProfileStateService.shared.upsertProfile(
                userID: session.userID,
                email: session.email,
                displayName: updated.trimmedPreferredName ?? session.displayName,
                authProvider: session.provider,
                onboarded: isOnboarded,
                lastOnboardingStep: lastOnboardingStep,
                profile: updated
            )
        }
    }

    func saveOnboardingDraft(_ profile: UserProfile, step: Int) {
        self.profile = profile
        lastOnboardingStep = step
        saveProfile()
        saveOnboardingStep()
    }

    func bootstrapFromSupabaseIfNeeded() async {
        guard let session = authSession else {
            hasResolvedInitialState = true
            isHydratingRemoteState = false
            return
        }

        guard !isHydratingRemoteState else { return }
        isHydratingRemoteState = true

        defer {
            isHydratingRemoteState = false
            hasResolvedInitialState = true
        }

        do {
            let remoteState = try await SupabaseProfileStateService.shared.fetchOrCreateProfileState(
                userID: session.userID,
                email: session.email,
                displayName: session.displayName,
                authProvider: session.provider
            )

            let cachedCompleted = isOnboarded && profile != nil
            let resolvedOnboarded = remoteState.onboarded || cachedCompleted
            let recoveredProfile = remoteState.profile ?? profile
            let recoveredStep = resolvedOnboarded
                ? remoteState.lastOnboardingStep
                : max(remoteState.lastOnboardingStep, lastOnboardingStep)

            authSession = AuthSession(
                provider: remoteState.authProvider ?? session.provider,
                userID: session.userID,
                email: remoteState.email ?? session.email,
                displayName: remoteState.displayName ?? session.displayName,
                signedInAt: session.signedInAt,
                accessToken: session.accessToken
            )
            isOnboarded = resolvedOnboarded
            profile = recoveredProfile ?? (resolvedOnboarded ? nil : .starter)
            lastOnboardingStep = max(0, recoveredStep)

            saveAuthSession()
            saveOnboardingState()
            saveOnboardingStep()
            if profile != nil {
                saveProfile()
        }

        await loadMealPrepCycles()
        await loadPrepRecipeOverrides()
        await reconcileLatestPlanWithPrepOverrides()

        if resolvedOnboarded != remoteState.onboarded ||
                recoveredProfile != nil && remoteState.profile == nil ||
                recoveredStep != remoteState.lastOnboardingStep ||
                remoteState.authProvider != session.provider {
                try? await SupabaseProfileStateService.shared.upsertProfile(
                    userID: session.userID,
                    email: remoteState.email ?? session.email,
                    displayName: recoveredProfile?.trimmedPreferredName ?? remoteState.displayName ?? session.displayName,
                    authProvider: session.provider,
                    onboarded: resolvedOnboarded,
                    lastOnboardingStep: recoveredStep,
                    profile: recoveredProfile
                )
            }
        } catch {
            if authSession != nil, profile == nil {
                profile = .starter
                saveProfile()
            }
        }
    }

    func generatePlan(
        options: PrepGenerationOptions = .standard,
        regenerationContext: PrepRegenerationContext? = nil
    ) async {
        guard let profile, profile.isAutomationReady else { return }
        let generationToken = UUID()
        activeGenerationToken = generationToken
        isGenerating = true
        let previousPlan = latestPlan
        let savedRecipeIDs = await resolvedSavedRecipeIDs()
        let plan = await planner.generatePlan(
            profile: profile,
            history: planHistory,
            savedRecipeIDs: savedRecipeIDs,
            options: options,
            regenerationContext: regenerationContext,
            userID: authSession?.userID,
            accessToken: authSession?.accessToken
        )
        guard activeGenerationToken == generationToken, self.profile == profile else { return }
        if plan.recipes.isEmpty, let previousPlan {
            isGenerating = false
            updateCurrentPlanCache(with: previousPlan)
            return
        }
        updateCurrentPlanCache(with: plan)
        await reconcileLatestPlanWithPrepOverrides()
        isGenerating = false
    }

    func updateLatestPlan(with recipe: Recipe, servings: Int) async {
        guard let profile, profile.isAutomationReady else { return }

        let generationToken = UUID()
        activeGenerationToken = generationToken
        isGenerating = true
        defer {
            isGenerating = false
        }

        let sanitizedServings = max(1, servings)
        let override = PrepRecipeOverride(recipe: recipe, servings: sanitizedServings, isIncludedInPrep: true)
        cachePrepRecipeOverride(override)
        await persistPrepRecipeOverrideIfPossible(override)

        let updatedRecipes: [PlannedRecipe]
        if let latestPlan {
            var recipes = latestPlan.recipes
            if let index = recipes.firstIndex(where: { $0.recipe.id == recipe.id }) {
                recipes[index].recipe = recipe
                recipes[index].servings = sanitizedServings
            } else {
                recipes.append(
                    PlannedRecipe(
                        recipe: recipe,
                        servings: sanitizedServings,
                        carriedFromPreviousPlan: false
                    )
                )
            }
            updatedRecipes = recipes
        } else {
            updatedRecipes = [
                PlannedRecipe(
                    recipe: recipe,
                    servings: sanitizedServings,
                    carriedFromPreviousPlan: false
                )
            ]
        }

        let plan: MealPlan
        if let latestPlan {
            plan = await planner.rebuildPlan(
                profile: profile,
                basePlan: latestPlan,
                recipes: updatedRecipes,
                history: planHistory
            )
        } else {
            plan = await planner.buildPlan(
                profile: profile,
                recipes: updatedRecipes,
                history: planHistory
            )
        }

        guard activeGenerationToken == generationToken, self.profile == profile else { return }

        updateCurrentPlanCache(with: plan)
    }

    func ensureFreshPlanIfNeeded() async {
        guard let profile, isOnboarded, profile.isAutomationReady, !isGenerating else { return }

        let shouldRegenerate: Bool
        if let latestPlan {
            let hasLegacySeedRecipes = latestPlan.recipes.contains(where: { $0.recipe.isLegacySeedRecipe })
            let hasKnownSampleRecipes = latestPlan.recipes.contains(where: { $0.recipe.isKnownSampleRecipe })
            let missingImageCount = latestPlan.recipes.reduce(into: 0) { partialResult, plannedRecipe in
                if plannedRecipe.recipe.isImagePoor {
                    partialResult += 1
                }
            }
            let planIsImagePoor = missingImageCount >= max(2, Int(ceil(Double(latestPlan.recipes.count) * 0.5)))
            let planIsExpired = latestPlan.periodEnd < Date.now
            shouldRegenerate = hasLegacySeedRecipes || hasKnownSampleRecipes || planIsImagePoor || planIsExpired
        } else {
            shouldRegenerate = true
        }

        guard shouldRegenerate else { return }
        await generatePlan()
    }

    func regeneratePrepBatch(using options: PrepGenerationOptions = .standard) async {
        guard profile?.isAutomationReady == true, !isGenerating else { return }
        let regenerationContext = latestPlan.map {
            PrepRegenerationContext(
                focus: options.focus,
                currentRecipes: $0.recipes.map(\.recipe),
                userPrompt: options.userPrompt
            )
        }
        prepRecipeOverrides = []

        if let session = authSession {
            try? await SupabasePrepRecipeOverridesService.shared.deleteAllPrepRecipeOverrides(userID: session.userID)
        }

        await generatePlan(options: options, regenerationContext: regenerationContext)
    }

    func refreshLatestPlanGrocerySourcesIfNeeded() async {
        guard let latestPlan, let profile, !isGenerating else { return }
        guard !latestPlan.recipes.isEmpty, !latestPlan.groceryItems.isEmpty else { return }

        let needsSourceRefresh = latestPlan.groceryItems.contains { $0.sourceIngredients.isEmpty }
        guard needsSourceRefresh else { return }

        let generationToken = UUID()
        activeGenerationToken = generationToken
        isGenerating = true
        defer { isGenerating = false }

        let refreshedPlan = await planner.rebuildPlan(
            profile: profile,
            basePlan: latestPlan,
            recipes: latestPlan.recipes,
            history: planHistory
        )

        guard activeGenerationToken == generationToken, self.profile == profile else { return }
        updateCurrentPlanCache(with: refreshedPlan)
    }

    func removeRecipeFromLatestPlan(recipeID: String) async {
        guard let profile, let latestPlan, !isGenerating else { return }
        guard let removedRecipe = latestPlan.recipes.first(where: { $0.recipe.id == recipeID }) else { return }

        let generationToken = UUID()
        activeGenerationToken = generationToken
        isGenerating = true
        defer { isGenerating = false }

        let override = PrepRecipeOverride(
            recipe: removedRecipe.recipe,
            servings: removedRecipe.servings,
            isIncludedInPrep: false
        )
        cachePrepRecipeOverride(override)
        await persistPrepRecipeOverrideIfPossible(override)

        let remainingRecipes = latestPlan.recipes.filter { $0.recipe.id != recipeID }
        let rebuiltPlan = await planner.rebuildPlan(
            profile: profile,
            basePlan: latestPlan,
            recipes: remainingRecipes,
            history: planHistory
        )

        guard activeGenerationToken == generationToken, self.profile == profile else { return }
        updateCurrentPlanCache(with: rebuiltPlan)
    }

    func resetAll() {
        activeGenerationToken = UUID()
        authSession = nil
        isOnboarded = false
        profile = nil
        latestPlan = nil
        planHistory = []
        isGenerating = false
        prepRecipeOverrides = []
        UserDefaults.standard.removeObject(forKey: authSessionKey)
        UserDefaults.standard.removeObject(forKey: onboardedKey)
        UserDefaults.standard.removeObject(forKey: profileKey)
        UserDefaults.standard.removeObject(forKey: onboardingStepKey)
        UserDefaults.standard.removeObject(forKey: Self.googleDevUserIDKey)
        UserDefaults.standard.removeObject(forKey: Self.googleDevEmailKey)
        lastOnboardingStep = 0
        hasResolvedInitialState = false
        isHydratingRemoteState = false
        activeHistoryUserID = nil
    }

    func signOutToWelcome() {
        resetAll()
    }

    private func loadState() {
        let decoder = JSONDecoder()

        if let authData = UserDefaults.standard.data(forKey: authSessionKey),
           let decodedAuth = try? decoder.decode(AuthSession.self, from: authData) {
            authSession = decodedAuth
        }

        isOnboarded = UserDefaults.standard.bool(forKey: onboardedKey)
        lastOnboardingStep = UserDefaults.standard.integer(forKey: onboardingStepKey)

        if let profileData = UserDefaults.standard.data(forKey: profileKey),
           let decodedProfile = try? decoder.decode(UserProfile.self, from: profileData) {
            profile = decodedProfile
        }

        loadHistory(for: authSession?.userID)

        if shouldPurgePersistedPlan(planHistory) {
            latestPlan = nil
            planHistory = []
            saveHistory()
        }

        if authSession != nil, profile == nil {
            profile = .starter
            saveProfile()
        }

        hasResolvedInitialState = authSession == nil
    }

    private func updateCurrentPlanCache(with plan: MealPlan, persistRemote: Bool = true) {
        latestPlan = plan
        planHistory.removeAll { $0.id == plan.id }
        planHistory.insert(plan, at: 0)
        if planHistory.count > 12 {
            planHistory = Array(planHistory.prefix(12))
        }
        saveHistory()

        guard persistRemote else { return }
        persistMealPrepCycleIfPossible(plan)
    }

    private func cachePrepRecipeOverride(_ override: PrepRecipeOverride) {
        guard !override.recipe.isLegacySeedRecipe else { return }

        if let index = prepRecipeOverrides.firstIndex(where: { $0.recipe.id == override.recipe.id }) {
            prepRecipeOverrides[index] = override
        } else {
            prepRecipeOverrides.append(override)
        }
    }

    private func prepRecipeOverrideLookup() -> [String: PrepRecipeOverride] {
        Dictionary(uniqueKeysWithValues: prepRecipeOverrides.map { ($0.recipe.id, $0) })
    }

    private func resolvedSavedRecipeIDs() async -> Set<String> {
        guard let userID = authSession?.userID else { return [] }
        let ids = await SupabaseSavedRecipesService.shared.resolvedSavedRecipeIDs(userID: userID)
        return Set(ids)
    }

    private func applyPrepOverridesIfNeeded(to plan: MealPlan) async -> MealPlan {
        guard let profile, !prepRecipeOverrides.isEmpty else { return plan }

        let overrideLookup = prepRecipeOverrideLookup()
        var updatedRecipes: [PlannedRecipe] = []
        var seenRecipeIDs = Set<String>()

        for plannedRecipe in plan.recipes {
            let recipeID = plannedRecipe.recipe.id
            guard let override = overrideLookup[recipeID] else {
                updatedRecipes.append(plannedRecipe)
                continue
            }

            seenRecipeIDs.insert(recipeID)
            guard override.isIncludedInPrep, !override.recipe.isLegacySeedRecipe else { continue }
            updatedRecipes.append(
                PlannedRecipe(
                    recipe: override.recipe,
                    servings: override.servings,
                    carriedFromPreviousPlan: plannedRecipe.carriedFromPreviousPlan
                )
            )
        }

        for override in prepRecipeOverrides
            where override.isIncludedInPrep
                && !override.recipe.isLegacySeedRecipe
                && !seenRecipeIDs.contains(override.recipe.id) {
            updatedRecipes.append(
                PlannedRecipe(
                    recipe: override.recipe,
                    servings: override.servings,
                    carriedFromPreviousPlan: false
                )
            )
        }

        guard updatedRecipes != plan.recipes else { return plan }
        return await planner.rebuildPlan(
            profile: profile,
            basePlan: plan,
            recipes: updatedRecipes,
            history: planHistory
        )
    }

    private func reconcileLatestPlanWithPrepOverrides() async {
        guard let latestPlan else { return }
        let reconciledPlan = await applyPrepOverridesIfNeeded(to: latestPlan)
        guard reconciledPlan != latestPlan else { return }
        updateCurrentPlanCache(with: reconciledPlan)
    }

    private func loadPrepRecipeOverrides() async {
        guard let session = authSession else {
            prepRecipeOverrides = []
            return
        }

        do {
            let fetched = try await SupabasePrepRecipeOverridesService.shared.fetchPrepRecipeOverrides(userID: session.userID)
            let legacySeedOverrides = fetched.filter { $0.recipe.isLegacySeedRecipe }
            prepRecipeOverrides = fetched.filter { !$0.recipe.isLegacySeedRecipe }

            if !legacySeedOverrides.isEmpty {
                Task(priority: .utility) {
                    for seedOverride in legacySeedOverrides {
                        var disabled = seedOverride
                        disabled.isIncludedInPrep = false
                        try? await SupabasePrepRecipeOverridesService.shared.upsertPrepRecipeOverride(
                            userID: session.userID,
                            override: disabled
                        )
                    }
                }
            }
        } catch {
            // Keep the local cache if remote sync fails.
        }
    }

    private func loadMealPrepCycles() async {
        guard let session = authSession else { return }

        do {
            let fetched = try await SupabaseMealPrepCycleService.shared.fetchMealPrepCycles(userID: session.userID)
            guard !fetched.isEmpty else { return }
            guard !shouldPurgePersistedPlan(fetched) else { return }

            latestPlan = fetched.first
            planHistory = fetched
            saveHistory()
        } catch {
            // Keep the local cache if remote sync fails.
        }
    }

    private func persistMealPrepCycleIfPossible(_ plan: MealPlan) {
        guard let session = authSession else { return }

        Task(priority: .utility) {
            try? await SupabaseMealPrepCycleService.shared.upsertMealPrepCycle(
                userID: session.userID,
                plan: plan
            )
        }
    }

    private func persistPrepRecipeOverrideIfPossible(_ override: PrepRecipeOverride) async {
        guard !override.recipe.isLegacySeedRecipe else { return }
        guard let session = authSession else { return }

        Task(priority: .utility) {
            try? await SupabasePrepRecipeOverridesService.shared.upsertPrepRecipeOverride(
                userID: session.userID,
                override: override
            )
        }
    }

    private func saveProfile() {
        guard let profile else { return }
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(profile) else { return }
        UserDefaults.standard.set(data, forKey: profileKey)
    }

    private func saveAuthSession() {
        guard let authSession else { return }
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(authSession) else { return }
        UserDefaults.standard.set(data, forKey: authSessionKey)
    }

    private func saveOnboardingState() {
        UserDefaults.standard.set(isOnboarded, forKey: onboardedKey)
    }

    private func saveOnboardingStep() {
        UserDefaults.standard.set(lastOnboardingStep, forKey: onboardingStepKey)
    }

    private func saveHistory() {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(planHistory) else { return }
        UserDefaults.standard.set(data, forKey: historyStorageKey(for: activeHistoryUserID))
    }

    private func loadHistory(for userID: String?) {
        let defaults = UserDefaults.standard
        let primaryKey = historyStorageKey(for: userID)
        let fallbackKeys = [legacyHistoryKey, historyStorageKey(for: nil)].filter { $0 != primaryKey }
        let data = defaults.data(forKey: primaryKey)
            ?? fallbackKeys.compactMap { defaults.data(forKey: $0) }.first

        activeHistoryUserID = userID

        guard let data,
              let decodedHistory = try? JSONDecoder().decode([MealPlan].self, from: data)
        else {
            planHistory = []
            latestPlan = nil
            return
        }

        planHistory = decodedHistory
        latestPlan = decodedHistory.first

        if defaults.data(forKey: primaryKey) == nil {
            defaults.set(data, forKey: primaryKey)
        }
    }

    private func historyStorageKey(for userID: String?) -> String {
        "\(historyKeyPrefix)-\(userID ?? "guest")"
    }

    private func shouldPurgePersistedPlan(_ history: [MealPlan]) -> Bool {
        history.contains(where: { plan in
            plan.recipes.contains(where: { recipe in
                recipe.recipe.isLegacySeedRecipe || recipe.recipe.isKnownSampleRecipe
            })
        })
    }
}
