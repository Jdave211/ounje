import Foundation
import Security
import StoreKit

private struct PendingCartSyncIntent: Codable, Hashable {
    var planID: UUID
    var cartSignature: String
    var deliveryAnchor: String
    var trigger: String
    var createdAt: String
}

private enum CachedAuthenticatedEntryRoute: String, Codable {
    case onboarding
    case planner
}

private enum RemoteMealPrepCycleLoadState: Equatable {
    case notRequested
    case loaded(Int)
    case empty
    case unavailable

    var confirmsNoUsablePrep: Bool {
        self == .empty
    }
}

@MainActor
final class MealPlanningAppStore: ObservableObject {
    @Published var authSession: AuthSession?
    @Published var isOnboarded = false
    @Published var profile: UserProfile?
    @Published var latestPlan: MealPlan?
    @Published var planHistory: [MealPlan] = []
    @Published var completedMealPrepCycles: [MealPrepCompletedCycle] = []
    @Published var recurringPrepRecipes: [RecurringPrepRecipe] = []
    @Published var automationState: MealPrepAutomationState?
    @Published var latestInstacartRun: InstacartRunLogSummary?
    @Published private(set) var latestBlockingInstacartRun: InstacartRunLogSummary?
    @Published var latestGroceryOrder: GroceryOrderSummaryRecord?
    @Published var membershipEntitlement: AppUserEntitlement?
    @Published var availableMembershipProducts: [OunjeMembershipPlan: StoreProductSnapshot] = [:]
    @Published var isBillingBusy = false
    @Published var billingStatusMessage: String?
    @Published var manualInstacartRerunQueuedAt: Date?
    @Published var isManualAutoshopRunning = false
    @Published var manualAutoshopErrorMessage: String?
    @Published var isDeactivatingAccount = false
    @Published var isGenerating = false
    @Published var isRefreshingPrepRecipes = false
    @Published private(set) var latestPlanRevision = 0
    @Published private(set) var isRefreshingMainShopSnapshot = false
    @Published var isHydratingRemoteState = false
    @Published var hasResolvedInitialState = false
    @Published var lastOnboardingStep = 0
    @Published private(set) var isCompletingOnboarding = false

    private let planner = MealPlanningAgent()
    private var activeGenerationToken = UUID()
    private var prepRecipeOverrides: [PrepRecipeOverride] = []
    private var latestPlanArtifactRefreshTask: Task<Void, Never>?
    private var recurringPrepToggleRecipeIDs = Set<String>()

    private let authSessionKey = "agentic-auth-session-v1"
    private let onboardedKey = "agentic-onboarded-v1"
    private let profileKey = "agentic-meal-profile-v1"
    private let historyKeyPrefix = "agentic-meal-history-v2"
    private let completedHistoryKeyPrefix = "agentic-meal-completed-history-v1"
    private let automationStateKeyPrefix = "agentic-meal-automation-state-v1"
    private let pendingCartSyncIntentKeyPrefix = "agentic-pending-cart-sync-intent-v1"
    private let prepRecipeOverridesKeyPrefix = "agentic-prep-recipe-overrides-v1"
    private let recurringPrepRecipesKeyPrefix = "agentic-recurring-prep-recipes-v1"
    private let legacyHistoryKey = "agentic-meal-history-v1"
    private let onboardingStepKey = "agentic-onboarding-step-v1"
    private let cachedEntryRouteKey = "agentic-cached-entry-route-v1"
    private let sharedAuthSessionKey = "agentic-share-auth-session-v1"
    private let liveUserIDKey = "agentic-live-user-id-v1"
    private let hiddenMainShopItemsKeyPrefix = "agentic-hidden-main-shop-items-v1"
    private let authKeychainService = "net.ounje.auth"
    private let authKeychainAccount = "agentic-auth-session-v1"
    static let googleDevUserIDKey = "agentic-google-dev-user-id-v1"
    static let googleDevEmailKey = "agentic-google-dev-email-v1"
    private var activeHistoryUserID: String?
    private var isRunningAutomationPass = false
    private var lastGrocerySourceRefreshFingerprint: String?
    private var lastAutomationSceneActiveAt: Date?
    private var lastTrackingAuthFailureAt: Date?
    private var lastTrackingAuthFailureUserID: String?
    private var authStateRevision = 0
    private var cachedAuthenticatedEntryRoute: CachedAuthenticatedEntryRoute?
    private var hasPersistedOnboardingState = false
    private var pendingCartSyncIntent: PendingCartSyncIntent?
    private var remoteMealPrepCycleLoadState: RemoteMealPrepCycleLoadState = .notRequested
    private var activeAutoPrepGenerationKey: String?
    @Published private(set) var hiddenMainShopItemKeys: Set<String> = []
    private var hiddenMainShopPlanID: UUID?
    private var cachedLiveUserID: String?
    private var sharedDefaults: UserDefaults? {
        UserDefaults(suiteName: SharedRecipeImportConstants.appGroupID)
    }

    private var shouldForceOnboardingIncomplete: Bool {
        OunjeLaunchFlags.forceOnboardingIncomplete
    }

    init() {
        loadState()
    }

    var isAutoshopManualBetaOnly: Bool {
        false
    }

    var nextRunDate: Date? {
        guard let profile else { return nil }
        return profile.scheduledDeliveryDate()
    }

    var effectivePricingTier: OunjePricingTier {
        membershipEntitlement?.effectiveTier ?? profile?.pricingTier ?? .free
    }

    var hasActivePaidEntitlement: Bool {
        effectivePricingTier != .free
    }

    var isAuthenticated: Bool {
        authSession != nil
    }

    var canRenderCachedPlannerState: Bool {
        provisionalAuthenticatedEntryRoute == .planner
    }

    var requiresProfileOnboarding: Bool {
        guard isAuthenticated else { return false }
        if hasResolvedInitialState {
            return !isOnboarded
        }
        return provisionalAuthenticatedEntryRoute == .onboarding
    }

    var shouldShowBootstrapLoadingView: Bool {
        guard isAuthenticated else { return false }
        guard !hasResolvedInitialState || isHydratingRemoteState else { return false }
        return provisionalAuthenticatedEntryRoute == nil
    }

    var shouldHoldPlannerSplash: Bool {
        guard isAuthenticated, isOnboarded else { return false }
        if isCompletingOnboarding {
            return true
        }
        if !hasResolvedInitialState || isHydratingRemoteState {
            return !canRenderCachedPlannerState && latestPlan == nil
        }
        return latestPlan == nil && isRefreshingPrepRecipes && !canRenderCachedPlannerState
    }

    var resolvedLiveUserID: String? {
        let authUserID = authSession?.userID.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !authUserID.isEmpty {
            return authUserID
        }

        let cachedUserID = cachedLiveUserID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return cachedUserID.isEmpty ? nil : cachedUserID
    }

    var activeRecurringPrepRecipeIDs: Set<String> {
        Set(recurringPrepRecipes.filter(\.isEnabled).map(\.recipeID))
    }

    var liveTrackingSession: AuthSession? {
        guard let resolvedLiveUserID else { return nil }
        return AuthSession(
            provider: authSession?.provider ?? .apple,
            userID: resolvedLiveUserID,
            email: authSession?.email,
            displayName: authSession?.displayName,
            signedInAt: authSession?.signedInAt ?? .now,
            accessToken: authSession?.accessToken,
            refreshToken: authSession?.refreshToken
        )
    }

    var resolvedTrackingSession: AuthSession? {
        authSession ?? liveTrackingSession
    }

    func signIn(
        with session: AuthSession,
        onboarded: Bool,
        profile remoteProfile: UserProfile? = nil,
        lastOnboardingStep remoteStep: Int = 0
    ) {
        authStateRevision += 1
        if activeHistoryUserID != session.userID {
            loadHistory(for: session.userID)
            loadCompletedMealPrepCycleCache(for: session.userID)
            loadAutomationStateCache(for: session.userID)
            loadPendingCartSyncIntentCache(for: session.userID)
            loadPrepRecipeOverridesCache(for: session.userID)
            loadRecurringPrepRecipesCache(for: session.userID)
        }
        remoteMealPrepCycleLoadState = .notRequested
        if shouldForceOnboardingIncomplete {
            profile = .starter
            saveProfile()
        } else if let remoteProfile {
            profile = remoteProfile
            saveProfile()
        } else if profile == nil {
            profile = .starter
            saveProfile()
        }
        authSession = session
        cachedLiveUserID = session.userID
        let effectiveOnboarded = shouldForceOnboardingIncomplete ? false : onboarded
        let effectiveOnboardingStep = shouldForceOnboardingIncomplete ? 0 : remoteStep
        isOnboarded = effectiveOnboarded
        lastOnboardingStep = effectiveOnboardingStep
        hasResolvedInitialState = true
        cacheAuthenticatedEntryRoute(effectiveOnboarded ? .planner : .onboarding)
        saveAuthSession(session)
        saveOnboardingState()
        saveOnboardingStep()
    }

    func persistAuthSession(_ session: AuthSession) {
        authStateRevision += 1
        authSession = session
        cachedLiveUserID = session.userID
        saveAuthSession(session)
    }

    @discardableResult
    func freshTrackingSession() async -> AuthSession? {
        let refreshed = await refreshAuthSessionIfNeeded()
        return refreshed ?? resolvedTrackingSession
    }

    @discardableResult
    private func freshUserDataSession() async -> AuthSession? {
        guard let session = await refreshAuthSessionIfNeeded() else { return nil }
        let token = session.accessToken?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return token.isEmpty ? nil : session
    }

    func refreshMembershipEntitlement(trigger: String) async {
        guard OunjeLaunchFlags.paywallsEnabled else {
            availableMembershipProducts = [:]
            membershipEntitlement = nil
            billingStatusMessage = nil
            syncProfilePricingTierToEntitlement()
            return
        }

        do {
            availableMembershipProducts = try await StoreKitMembershipBillingService.shared.fetchProductsByPlan()
        } catch {
            billingStatusMessage = error.localizedDescription
        }

        guard let session = await freshTrackingSession() else {
            membershipEntitlement = nil
            syncProfilePricingTierToEntitlement()
            return
        }

        do {
            let localSnapshot = try await StoreKitMembershipBillingService.shared.currentEntitlementSnapshot(userID: session.userID)
            if let localSnapshot {
                _ = try? await SupabaseEntitlementService.shared.syncCurrentEntitlement(
                    snapshot: localSnapshot,
                    userID: session.userID,
                    accessToken: session.accessToken
                )
            }
            let remoteEntitlement = try await SupabaseEntitlementService.shared.fetchCurrentEntitlement(
                userID: session.userID,
                accessToken: session.accessToken
            )
            membershipEntitlement = remoteEntitlement
            syncProfilePricingTierToEntitlement()
            billingStatusMessage = nil
        } catch {
            if membershipEntitlement == nil,
               let localSnapshot = try? await StoreKitMembershipBillingService.shared.currentEntitlementSnapshot(userID: session.userID) {
                membershipEntitlement = localSnapshot
                syncProfilePricingTierToEntitlement()
            }
            billingStatusMessage = "[\(trigger)] \(error.localizedDescription)"
        }
    }

    func purchaseMembershipPlan(_ plan: OunjeMembershipPlan) async -> Bool {
        guard OunjeLaunchFlags.paywallsEnabled else {
            billingStatusMessage = nil
            return false
        }

        guard plan.tier != .free, plan.tier != .foundingLifetime else {
            await refreshMembershipEntitlement(trigger: "billing-noop")
            return true
        }

        isBillingBusy = true
        defer { isBillingBusy = false }

        do {
            guard let session = await freshTrackingSession() else {
                throw StoreBillingError.authenticationRequired
            }
            let snapshot = try await StoreKitMembershipBillingService.shared.purchase(plan: plan, userID: session.userID)
            membershipEntitlement = snapshot
            syncProfilePricingTierToEntitlement()
            billingStatusMessage = nil

            do {
                _ = try await SupabaseEntitlementService.shared.syncCurrentEntitlement(
                    snapshot: snapshot,
                    userID: session.userID,
                    accessToken: session.accessToken
                )
                let remoteEntitlement = try await SupabaseEntitlementService.shared.fetchCurrentEntitlement(
                    userID: session.userID,
                    accessToken: session.accessToken
                )
                membershipEntitlement = remoteEntitlement ?? snapshot
                syncProfilePricingTierToEntitlement()
            } catch {
                print("[Membership] Post-purchase entitlement sync failed:", error.localizedDescription)
            }

            return true
        } catch {
            billingStatusMessage = error.localizedDescription
            await refreshMembershipEntitlement(trigger: "billing-purchase-failed")
            return false
        }
    }

    func purchaseMembershipTier(_ tier: OunjePricingTier) async -> Bool {
        await purchaseMembershipPlan(.init(tier: tier, cadence: .monthly))
    }

    func restoreMembershipPurchases() async -> Bool {
        guard OunjeLaunchFlags.paywallsEnabled else {
            billingStatusMessage = nil
            return true
        }

        isBillingBusy = true
        defer { isBillingBusy = false }

        do {
            guard let session = await freshTrackingSession() else {
                throw StoreBillingError.authenticationRequired
            }
            let localSnapshot = try await StoreKitMembershipBillingService.shared.restorePurchases(userID: session.userID)
            if let localSnapshot {
                _ = try? await SupabaseEntitlementService.shared.syncCurrentEntitlement(
                    snapshot: localSnapshot,
                    userID: session.userID,
                    accessToken: session.accessToken
                )
            }
            await refreshMembershipEntitlement(trigger: "billing-restore")
            billingStatusMessage = nil
            return true
        } catch {
            billingStatusMessage = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func refreshAuthSessionIfNeeded() async -> AuthSession? {
        guard let currentSession = authSession else { return nil }
        let refreshedSession = await refreshAuthSessionIfPossible(currentSession)
        if refreshedSession != currentSession {
            authSession = refreshedSession
            saveAuthSession(refreshedSession)
        }
        return authSession
    }

    func completeOnboarding(with profile: UserProfile, lastStep: Int) async {
        self.profile = profile
        isOnboarded = shouldForceOnboardingIncomplete ? false : true
        lastOnboardingStep = lastStep
        hasResolvedInitialState = true
        isCompletingOnboarding = true
        cacheAuthenticatedEntryRoute(isOnboarded ? .planner : .onboarding)
        saveProfile()
        saveOnboardingState()
        saveOnboardingStep()

        await finalizeCompletedOnboarding(with: profile, lastStep: lastStep)
        isCompletingOnboarding = false
    }

    func updateProfile(_ updated: UserProfile) {
        profile = updated
        saveProfile()

        guard let session = authSession else { return }
        Task(priority: .utility) {
            let writeSession = await self.freshUserDataSession() ?? session
            try? await SupabaseProfileStateService.shared.upsertProfile(
                userID: writeSession.userID,
                email: writeSession.email,
                displayName: updated.trimmedPreferredName ?? writeSession.displayName,
                authProvider: writeSession.provider,
                onboarded: isOnboarded,
                lastOnboardingStep: lastOnboardingStep,
                profile: updated,
                accessToken: writeSession.accessToken
                )
        }

        Task {
            await runAutomationPassIfNeeded(trigger: "profile_updated")
        }
    }

    func saveOnboardingDraft(_ profile: UserProfile, step: Int) {
        self.profile = profile
        lastOnboardingStep = step
        cacheAuthenticatedEntryRoute(.onboarding)
        saveProfile()
        saveOnboardingState()
        saveOnboardingStep()
    }

    func bootstrapFromSupabaseIfNeeded() async {
        let bootstrapRevision = authStateRevision
        guard resolvedLiveUserID != nil else {
            hasResolvedInitialState = true
            isHydratingRemoteState = false
            return
        }

        guard !isHydratingRemoteState else { return }
        isHydratingRemoteState = true

        defer {
            if authStateRevision == bootstrapRevision {
                isHydratingRemoteState = false
                isRefreshingPrepRecipes = false
                hasResolvedInitialState = true
            }
        }

        guard let session = await freshUserDataSession() else { return }
        guard authStateRevision == bootstrapRevision else { return }
        cachedLiveUserID = authSession?.userID ?? cachedLiveUserID

        do {
            let remoteState = try await SupabaseProfileStateService.shared.fetchOrCreateProfileState(
                userID: session.userID,
                email: session.email,
                displayName: session.displayName,
                authProvider: session.provider,
                accessToken: session.accessToken
            )
            guard authStateRevision == bootstrapRevision else { return }
            if remoteState.isDeactivated {
                resetAll()
                return
            }

            let cachedCompleted = isOnboarded && profile != nil
            let persistedOnboarded = remoteState.onboarded || cachedCompleted
            let resolvedOnboarded = shouldForceOnboardingIncomplete ? false : persistedOnboarded
            let recoveredProfile = remoteState.profile ?? profile
            let recoveredStep = shouldForceOnboardingIncomplete
                ? 0
                : (
                    persistedOnboarded
                        ? remoteState.lastOnboardingStep
                        : FirstLoginOnboardingView.SetupStep.latestStoredRawValue(remoteState.lastOnboardingStep, lastOnboardingStep)
                )

            authSession = AuthSession(
                provider: remoteState.authProvider ?? session.provider,
                userID: session.userID,
                email: remoteState.email ?? session.email,
                displayName: remoteState.displayName ?? session.displayName,
                signedInAt: session.signedInAt,
                accessToken: session.accessToken,
                refreshToken: session.refreshToken
            )
            isOnboarded = resolvedOnboarded
            profile = shouldForceOnboardingIncomplete ? .starter : (recoveredProfile ?? (resolvedOnboarded ? nil : .starter))
            lastOnboardingStep = max(0, recoveredStep)
            cacheAuthenticatedEntryRoute(resolvedOnboarded ? .planner : .onboarding)

            if let authSession {
                saveAuthSession(authSession)
            }
            saveOnboardingState()
            saveOnboardingStep()
            if profile != nil {
                saveProfile()
            }

            hasResolvedInitialState = true

            isRefreshingPrepRecipes = true
            let remotePlanLoadState = await loadMealPrepCycles(userID: session.userID, accessToken: session.accessToken)
            guard authStateRevision == bootstrapRevision else { return }
            if latestPlan?.recipes.isEmpty == false {
                isRefreshingPrepRecipes = false
            }
            await loadCompletedMealPrepCycles(userID: session.userID, accessToken: session.accessToken)
            guard authStateRevision == bootstrapRevision else { return }
            await loadPrepRecipeOverrides(userID: session.userID, accessToken: session.accessToken)
            guard authStateRevision == bootstrapRevision else { return }
            await loadRecurringPrepRecipes(userID: session.userID, accessToken: session.accessToken)
            guard authStateRevision == bootstrapRevision else { return }
            await loadAutomationState(userID: session.userID, accessToken: session.accessToken)
            guard authStateRevision == bootstrapRevision else { return }
            await repairRemotePrepStateIfNeeded(session: session, remotePlanLoadState: remotePlanLoadState)
            guard authStateRevision == bootstrapRevision else { return }
            await reconcileLatestPlanWithPrepOverrides()
            guard authStateRevision == bootstrapRevision else { return }
            await repairRemoteCartStateIfNeeded(session: session)
            guard authStateRevision == bootstrapRevision else { return }
            if let latestPlan, !latestPlan.recipes.isEmpty {
                _ = await persistLatestPlanRemotelyIfPossible(latestPlan)
            }
            isRefreshingPrepRecipes = false
            isHydratingRemoteState = false
            hasResolvedInitialState = true
            guard authStateRevision == bootstrapRevision else { return }
            await loadLatestInstacartRun()
            guard authStateRevision == bootstrapRevision else { return }
            await loadLatestGroceryOrder()
            guard authStateRevision == bootstrapRevision else { return }
            await emitLifecycleNotificationsIfNeeded(trigger: "bootstrap")
            await emitEngagementNudgesIfNeeded()

            if !shouldForceOnboardingIncomplete,
                (persistedOnboarded != remoteState.onboarded ||
                recoveredProfile != nil && remoteState.profile == nil ||
                recoveredStep != remoteState.lastOnboardingStep ||
                remoteState.authProvider != session.provider) {
                try? await SupabaseProfileStateService.shared.upsertProfile(
                    userID: session.userID,
                    email: remoteState.email ?? session.email,
                    displayName: recoveredProfile?.trimmedPreferredName ?? remoteState.displayName ?? session.displayName,
                    authProvider: session.provider,
                    onboarded: persistedOnboarded,
                    lastOnboardingStep: recoveredStep,
                    profile: recoveredProfile,
                    accessToken: session.accessToken
                )
            }
        } catch {
            if authSession != nil, profile == nil {
                profile = .starter
                saveProfile()
            }
        }
    }

    private func refreshAuthSessionIfPossible(_ session: AuthSession) async -> AuthSession {
        let refreshToken = session.refreshToken?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !refreshToken.isEmpty else { return session }

        do {
            let tokenResponse = try await SupabaseAuthSessionRefreshService.shared.refreshSession(refreshToken: refreshToken)
            return AuthSession(
                provider: session.provider,
                userID: tokenResponse.userID,
                email: tokenResponse.email ?? session.email,
                displayName: tokenResponse.displayName ?? session.displayName,
                signedInAt: session.signedInAt,
                accessToken: tokenResponse.accessToken,
                refreshToken: tokenResponse.refreshToken ?? session.refreshToken
            )
        } catch {
            return session
        }
    }

    private func syncProfilePricingTierToEntitlement() {
        guard var profile else { return }
        let resolvedTier = effectivePricingTier
        guard profile.pricingTier != resolvedTier else { return }
        profile.pricingTier = resolvedTier
        self.profile = profile
        saveProfile()
    }

    @discardableResult
    func generatePlan(
        options: PrepGenerationOptions = .standard,
        regenerationContext: PrepRegenerationContext? = nil,
        deferSlowArtifacts: Bool = false
    ) async -> MealPlan? {
        guard let profile, profile.isPlanningReady, !isGenerating else { return nil }
        let generationToken = UUID()
        activeGenerationToken = generationToken
        isGenerating = true
        isRefreshingPrepRecipes = true
        defer {
            isGenerating = false
            isRefreshingPrepRecipes = false
        }
        let previousPlan = latestPlan
        let savedRecipeIDs = await resolvedSavedRecipeIDs()
        let savedRecipeTitles = await resolvedSavedRecipeTitles()
        let generationSession = await freshUserDataSession()
        let generatedPlan = await planner.generatePlan(
            profile: profile,
            history: planHistory,
            savedRecipeIDs: savedRecipeIDs,
            recurringRecipes: recurringPrepRecipes.filter(\.isEnabled),
            savedRecipeTitles: savedRecipeTitles,
            options: options,
            regenerationContext: regenerationContext,
            userID: generationSession?.userID ?? authSession?.userID,
            accessToken: generationSession?.accessToken,
            includeRemoteQuotes: !deferSlowArtifacts
        )
        guard activeGenerationToken == generationToken, self.profile == profile else { return nil }
        let plan = await planHydratedWithRecipeDetailsIfNeeded(
            generatedPlan,
            refreshProviders: !deferSlowArtifacts
        )
        guard activeGenerationToken == generationToken, self.profile == profile else { return nil }
        if plan.recipes.isEmpty, let previousPlan {
            updateCurrentPlanCache(with: previousPlan)
            return nil
        }
        updateCurrentPlanCache(with: plan, persistRemote: false)
        await persistAutomationGenerationCheckpoint(
            plan: plan,
            reason: regenerationContext?.focus.rawValue ?? options.focus.rawValue
        )
        await reconcileLatestPlanWithPrepOverrides()
        if deferSlowArtifacts {
            let generatedPlan = latestPlan?.id == plan.id ? latestPlan ?? plan : plan
            scheduleGeneratedPlanArtifactRefresh(planID: generatedPlan.id)
        } else {
            if let latestPlan, latestPlan.id == plan.id {
                _ = await persistLatestPlanRemotelyIfPossible(latestPlan)
            } else {
                _ = await persistLatestPlanRemotelyIfPossible(plan)
            }
            await emitMealPrepReadyNotification(plan: plan)
        }
        return latestPlan?.id == plan.id ? latestPlan : plan
    }

    private func planHydratedWithRecipeDetailsIfNeeded(_ plan: MealPlan, refreshProviders: Bool) async -> MealPlan {
        guard let profile, !plan.recipes.isEmpty else { return plan }

        let refreshedRecipes = await hydratedPlannedRecipesForCart(plan.recipes)
        guard refreshedRecipes != plan.recipes else { return plan }

        let recurringRecipeIDs = plan.recurringRecipeIDs ?? recurringPrepRecipes.filter(\.isEnabled).map(\.recipeID)
        if refreshProviders {
            return await planner.rebuildPlan(
                profile: profile,
                basePlan: plan,
                recipes: refreshedRecipes,
                history: planHistory,
                recurringRecipeIDs: recurringRecipeIDs
            )
        }

        return planner.rebuildPlanCartOnly(
            profile: profile,
            basePlan: plan,
            recipes: refreshedRecipes,
            history: planHistory,
            recurringRecipeIDs: recurringRecipeIDs
        )
    }

    private func hydratedPlannedRecipeForCart(
        recipe: Recipe,
        servings: Int,
        carriedFromPreviousPlan: Bool
    ) async -> PlannedRecipe {
        let plannedRecipe = PlannedRecipe(
            recipe: recipe,
            servings: max(1, servings),
            carriedFromPreviousPlan: carriedFromPreviousPlan
        )
        return await hydratedPlannedRecipesForCart([plannedRecipe]).first ?? plannedRecipe
    }

    private func hydratedPlannedRecipesForCart(_ recipes: [PlannedRecipe]) async -> [PlannedRecipe] {
        await PlannedRecipeRefreshService.shared.refreshedPlannedRecipes(from: recipes)
    }

    func startManualAutoshopRun(
        trigger: String = "prep_overlay",
        allowedMainShopItemKeys: Set<String>? = nil,
        quantityOverridesByMainShopKey: [String: Int] = [:]
    ) async {
        guard !isManualAutoshopRunning else { return }
        guard let session = await freshUserDataSession() else {
            manualAutoshopErrorMessage = "Sign in again before running Autoshop."
            return
        }
        guard let profile, profile.deliveryAddress.isComplete else {
            manualAutoshopErrorMessage = "Add a delivery address before running Autoshop."
            return
        }
        guard latestPlan != nil else {
            manualAutoshopErrorMessage = "Generate a prep before running Autoshop."
            return
        }
        if hasBlockingInstacartActivity {
            manualAutoshopErrorMessage = "A cart run is already in progress."
            await loadLatestInstacartRun()
            await loadLatestGroceryOrder()
            return
        }

        isManualAutoshopRunning = true
        manualAutoshopErrorMessage = nil
        defer { isManualAutoshopRunning = false }

        if let latestPlanArtifactRefreshTask {
            await latestPlanArtifactRefreshTask.value
        }

        _ = await rebuildLatestPlanGroceriesIfNeeded(force: true)
        guard await refreshLatestPlanMainShopSnapshotIfNeeded(forceRebuild: true) else {
            manualAutoshopErrorMessage = "Main Shop is still syncing. Try again in a moment."
            return
        }

        guard var latestPlan,
              latestPlan.bestQuote?.provider == .instacart,
              !latestPlan.groceryItems.isEmpty,
              latestPlan.mainShopSnapshot?.items.isEmpty == false
        else {
            manualAutoshopErrorMessage = "Autoshop needs a synced Instacart cart first."
            return
        }
        latestPlan = planCappedForAutoshop(latestPlan)

        if let allowedMainShopItemKeys {
            latestPlan = filterPlanForManualAutoshopRun(
                latestPlan,
                allowedMainShopItemKeys: allowedMainShopItemKeys,
                quantityOverridesByMainShopKey: quantityOverridesByMainShopKey
            )
            guard latestPlan.mainShopSnapshot?.items.isEmpty == false else {
                manualAutoshopErrorMessage = "There are no visible shop items to send."
                return
            }
        }

        let cartSignature = automationCartSignature(for: latestPlan.groceryItems)
        let nextDelivery = profile.scheduledDeliveryDate()
        let deliveryAnchor = automationAnchorString(for: nextDelivery)

        do {
            let response = try await InstacartAutomationAPIService.shared.startRun(
                items: latestPlan.groceryItems,
                mealPlan: latestPlan,
                userID: session.userID,
                accessToken: session.accessToken,
                deliveryAddress: profile.deliveryAddress,
                manualIntent: true,
                trigger: trigger
            )
            automationState = updatedAutomationState {
                $0.autoshopEnabled = profile.isAutoshopOptedIn
                $0.autoshopLeadDays = profile.autoshopLeadDays
                $0.nextPrepAt = ISO8601DateFormatter().string(from: nextDelivery)
                $0.nextCartSyncAt = ISO8601DateFormatter().string(from: cartSetupWindowOpenDate(for: profile, nextDelivery: nextDelivery))
                $0.lastCartSyncTrigger = trigger
                $0.lastCartSyncForDeliveryAt = deliveryAnchor
                $0.lastCartSyncPlanID = latestPlan.id
                $0.lastCartSignature = cartSignature
                $0.lastInstacartRunID = response.runID
                $0.lastInstacartRunStatus = response.normalizedStatus
                $0.lastGeneratedReason = "manual_start:\(trigger)"
            }
            clearPendingCartSyncIntentIfMatched(
                planID: latestPlan.id,
                cartSignature: cartSignature,
                deliveryAnchor: deliveryAnchor
            )
            manualInstacartRerunQueuedAt = nil
            saveAutomationStateCache()
            persistAutomationStateIfPossible()
            await hydrateInstacartArtifacts(
                runID: response.runID,
                groceryOrderID: response.groceryOrderID,
                session: session
            )
            await emitLifecycleNotificationsIfNeeded(trigger: "manual_autoshop_started")
        } catch {
            manualAutoshopErrorMessage = error.localizedDescription
            automationState = updatedAutomationState {
                $0.autoshopEnabled = profile.isAutoshopOptedIn
                $0.autoshopLeadDays = profile.autoshopLeadDays
                $0.nextPrepAt = ISO8601DateFormatter().string(from: nextDelivery)
                $0.nextCartSyncAt = ISO8601DateFormatter().string(from: cartSetupWindowOpenDate(for: profile, nextDelivery: nextDelivery))
                $0.lastCartSyncTrigger = trigger
                $0.lastInstacartRunStatus = "failed"
                $0.lastGeneratedReason = "manual_start_failed:\(trigger)"
            }
            saveAutomationStateCache()
            persistAutomationStateIfPossible()
            await loadLatestInstacartRun()
            await loadLatestGroceryOrder()
        }
    }

    func rerunInstacartShopping() async {
        await startManualAutoshopRun(trigger: "manual_instacart_rerun")
    }

    func requestInstacartShoppingRerun() async {
        manualInstacartRerunQueuedAt = nil
        await startManualAutoshopRun(trigger: "manual_instacart_rerun")
    }

    private func filterPlanForManualAutoshopRun(
        _ plan: MealPlan,
        allowedMainShopItemKeys: Set<String>,
        quantityOverridesByMainShopKey: [String: Int]
    ) -> MealPlan {
        let allowedKeys = Set(allowedMainShopItemKeys.map(Self.normalizedCartKey).filter { !$0.isEmpty })
        let normalizedOverrides = quantityOverridesByMainShopKey.reduce(into: [String: Int]()) { result, entry in
            let normalizedKey = Self.normalizedCartKey(entry.key)
            guard !normalizedKey.isEmpty else { return }
            result[normalizedKey] = max(1, entry.value)
        }
        guard !allowedKeys.isEmpty,
              var snapshot = plan.mainShopSnapshot else {
            return plan
        }

        let filteredItems = snapshot.items.compactMap { item -> MainShopSnapshotItem? in
            let keys = mainShopKeys(for: item)
            guard keys.contains(where: { allowedKeys.contains($0) }) else { return nil }
            guard let override = keys.compactMap({ normalizedOverrides[$0] }).first else {
                return item
            }
            var adjustedItem = item
            adjustedItem.quantityText = overriddenQuantityText(item.quantityText, count: override)
            return adjustedItem
        }
        snapshot.items = filteredItems

        var filteredPlan = plan
        filteredPlan.mainShopSnapshot = snapshot
        return filteredPlan
    }

    private func planCappedForAutoshop(_ plan: MealPlan, maxRecipes: Int = 10) -> MealPlan {
        guard plan.recipes.count > maxRecipes else { return plan }

        var cappedPlan = plan
        let cappedRecipes = Array(plan.recipes.prefix(maxRecipes))
        let allowedRecipeIDs = Set(cappedRecipes.map { Self.normalizedCartKey($0.recipe.id) })
        cappedPlan.recipes = cappedRecipes
        cappedPlan.groceryItems = plan.groceryItems.compactMap { item in
            guard !item.sourceIngredients.isEmpty else { return item }
            let filteredSources = item.sourceIngredients.filter {
                allowedRecipeIDs.contains(Self.normalizedCartKey($0.recipeID))
            }
            guard !filteredSources.isEmpty else { return nil }
            var copy = item
            copy.sourceIngredients = filteredSources
            return copy
        }

        if var snapshot = plan.mainShopSnapshot {
            snapshot.signature = MainShopSnapshotBuilder.signature(for: cappedPlan.groceryItems)
            snapshot.items = snapshot.items.filter { item in
                guard let sourceIngredients = item.sourceIngredients, !sourceIngredients.isEmpty else { return true }
                return sourceIngredients.contains {
                    allowedRecipeIDs.contains(Self.normalizedCartKey($0.recipeID))
                }
            }
            cappedPlan.mainShopSnapshot = snapshot
        }

        return cappedPlan
    }

    private func mainShopKeys(for item: MainShopSnapshotItem) -> [String] {
        Self.normalizedUnique([
            item.removalKey,
            item.canonicalKey,
            item.name,
            item.sourceEdgeIDs?.joined(separator: " "),
        ].compactMap { $0 })
    }

    private func overriddenQuantityText(_ quantityText: String, count: Int) -> String {
        let trimmed = quantityText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return count == 1 ? "1 item" : "\(count) items"
        }

        let pattern = #"^\s*\d+(?:\.\d+)?\s*(.*)$"#
        if let range = trimmed.range(of: pattern, options: .regularExpression) {
            let unit = trimmed[range]
                .replacingOccurrences(of: #"^\s*\d+(?:\.\d+)?\s*"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return unit.isEmpty ? "\(count)" : "\(count) \(unit)"
        }

        return "\(count) \(trimmed)"
    }

    func updateLatestPlan(with recipe: Recipe, servings: Int) async {
        guard let profile, profile.isPlanningReady else { return }

        let sanitizedServings = max(1, servings)
        let immediatePlannedRecipe = PlannedRecipe(
            recipe: recipe,
            servings: sanitizedServings,
            carriedFromPreviousPlan: false
        )
        let override = PrepRecipeOverride(recipe: recipe, servings: sanitizedServings, isIncludedInPrep: true)
        cachePrepRecipeOverride(override)

        let updatedRecipes: [PlannedRecipe]
        let mutationSummary: String
        if let latestPlan {
            var recipes = latestPlan.recipes
            let hadRecipe = recipes.contains { $0.recipe.id == recipe.id }
            if let index = recipes.firstIndex(where: { $0.recipe.id == recipe.id }) {
                recipes[index].recipe = recipe
                recipes[index].servings = sanitizedServings
            } else {
                recipes.append(immediatePlannedRecipe)
            }
            updatedRecipes = recipes
            mutationSummary = hadRecipe
                ? "Updated \(recipe.title) in prep."
                : "Added \(recipe.title) to prep."
        } else {
            updatedRecipes = [immediatePlannedRecipe]
            mutationSummary = "Added \(recipe.title) to prep."
        }

        await applyImmediateLatestPlanRecipeMutation(
            profile: profile,
            recipes: updatedRecipes,
            basePlan: latestPlan,
            mutationSummary: mutationSummary
        )
        await persistPrepRecipeOverrideIfPossible(override)
        await syncPrepMutationToAutomation(trigger: "prep_recipe_updated", forceCartSync: true)
    }

    func ensureFreshPlanIfNeeded() async {
        guard hasResolvedInitialState, isOnboarded, let profile, profile.isPlanningReady else { return }
        guard !isHydratingRemoteState else { return }
        if let latestPlan, !latestPlan.recipes.isEmpty {
            return
        }
        guard remoteMealPrepCycleLoadState.confirmsNoUsablePrep else {
            return
        }
        let userID = resolvedLiveUserID ?? authSession?.userID ?? "anonymous"
        let generationKey = "\(userID)::\(automationAnchorString(for: profile.scheduledDeliveryDate()))"
        guard activeAutoPrepGenerationKey != generationKey else { return }
        activeAutoPrepGenerationKey = generationKey
        defer {
            if activeAutoPrepGenerationKey == generationKey {
                activeAutoPrepGenerationKey = nil
            }
        }
        if latestPlan?.recipes.isEmpty != false {
            await generatePlan()
        }
    }

    @discardableResult
    func regeneratePrepBatch(using options: PrepGenerationOptions = .standard) async -> Bool {
        guard profile?.isPlanningReady == true, !isGenerating else { return false }
        let originalPlan = latestPlan
        let originalOverrides = prepRecipeOverrides
        let originalRecipeIDs = originalPlan?.recipes.map { $0.recipe.id } ?? []
        let enabledRecurringRecipes = recurringPrepRecipes.filter(\.isEnabled)
        let recurringRecipeIDs = Set(enabledRecurringRecipes.map(\.recipeID))
        prepRecipeOverrides = []
        savePrepRecipeOverridesCache()

        let sessionForOverrideCleanup = await freshUserDataSession()

        for attempt in 0..<2 {
            let rerollNonce = UUID().uuidString
            let retryPrompt = attempt == 0
                ? options.userPrompt
                : [
                    options.userPrompt,
                    "Do not repeat the current non-recurring prep recipes."
                ]
                    .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")

            let regenerationContext = originalPlan.map {
                PrepRegenerationContext(
                    focus: options.focus,
                    targetRecipeCount: options.targetRecipeCount,
                    currentRecipes: $0.recipes.map(\.recipe),
                    userPrompt: retryPrompt,
                    rerollNonce: rerollNonce
                )
            }

            var rerollOptions = options
            rerollOptions.userPrompt = retryPrompt
            rerollOptions.rerollNonce = rerollNonce

            guard let generatedPlan = await generatePlan(
                options: rerollOptions,
                regenerationContext: regenerationContext,
                deferSlowArtifacts: true
            ) else {
                continue
            }
            let finalPlan = generatedPlanByEnforcingRecurringAnchors(
                in: generatedPlan,
                targetRecipeCount: rerollOptions.targetRecipeCount ?? originalPlan?.recipes.count,
                recurringRecipes: enabledRecurringRecipes
            )
            if finalPlan != generatedPlan {
                updateCurrentPlanCache(with: finalPlan, persistRemote: false)
                scheduleGeneratedPlanArtifactRefresh(planID: finalPlan.id)
            }
            let expectedRecipeCount = max(
                enabledRecurringRecipes.count,
                rerollOptions.targetRecipeCount ?? originalPlan?.recipes.count ?? generatedPlan.recipes.count
            )
            guard finalPlan.recipes.count >= expectedRecipeCount else {
                latestPlanArtifactRefreshTask?.cancel()
                latestPlanArtifactRefreshTask = nil
                if let originalPlan {
                    updateCurrentPlanCache(with: originalPlan, persistRemote: false)
                }
                continue
            }

            if didMeaningfullyRegeneratePrep(
                from: originalRecipeIDs,
                to: finalPlan.recipes.map { $0.recipe.id },
                recurringRecipeIDs: recurringRecipeIDs
            ) {
                _ = await persistLatestPlanRemotelyIfPossible(finalPlan)
                deleteRemotePrepOverridesAfterSuccessfulRegeneration(session: sessionForOverrideCleanup)
                return true
            }
        }

        prepRecipeOverrides = originalOverrides
        savePrepRecipeOverridesCache()
        if let session = await freshUserDataSession() {
            for override in originalOverrides {
                try? await SupabasePrepRecipeOverridesService.shared.upsertPrepRecipeOverride(
                    userID: session.userID,
                    override: override,
                    accessToken: session.accessToken
                )
            }
        }

        if let originalPlan {
            updateCurrentPlanCache(with: originalPlan, persistRemote: false)
            _ = await persistLatestPlanRemotelyIfPossible(originalPlan)
        }

        return false
    }

    private func deleteRemotePrepOverridesAfterSuccessfulRegeneration(session: AuthSession?) {
        guard let session else { return }
        let userID = session.userID
        let accessToken = session.accessToken
        Task.detached(priority: .utility) {
            try? await SupabasePrepRecipeOverridesService.shared.deleteAllPrepRecipeOverrides(
                userID: userID,
                accessToken: accessToken
            )
        }
    }

    private func generatedPlanByEnforcingRecurringAnchors(
        in plan: MealPlan,
        targetRecipeCount: Int?,
        recurringRecipes: [RecurringPrepRecipe]
    ) -> MealPlan {
        guard let profile else { return plan }
        let enabledRecurringRecipes = recurringRecipes.filter(\.isEnabled)
        guard !enabledRecurringRecipes.isEmpty else { return plan }

        let recurringRecipeIDs = enabledRecurringRecipes.map(\.recipeID)
        let recurringRecipeIDSet = Set(recurringRecipeIDs)
        let recurringPlannedRecipes = enabledRecurringRecipes.map { recurringRecipe in
            if let existing = plan.recipes.first(where: { $0.recipe.id == recurringRecipe.recipeID }) {
                return existing
            }

            return PlannedRecipe(
                recipe: recurringRecipe.recipe,
                servings: max(1, recurringRecipe.recipe.servings),
                carriedFromPreviousPlan: false
            )
        }

        let nonRecurringRecipes = plan.recipes.filter { !recurringRecipeIDSet.contains($0.recipe.id) }
        let resolvedTargetCount = max(
            recurringPlannedRecipes.count,
            targetRecipeCount ?? plan.recipes.count
        )
        let remainingSlots = max(0, resolvedTargetCount - recurringPlannedRecipes.count)
        let repairedRecipes = recurringPlannedRecipes + Array(nonRecurringRecipes.prefix(remainingSlots))

        let currentRecipeIDs = plan.recipes.map { $0.recipe.id }
        let repairedRecipeIDs = repairedRecipes.map { $0.recipe.id }
        guard currentRecipeIDs != repairedRecipeIDs || (plan.recurringRecipeIDs ?? []) != recurringRecipeIDs else {
            return plan
        }

        return planner.rebuildPlanCartOnly(
            profile: profile,
            basePlan: plan,
            recipes: repairedRecipes,
            history: planHistory,
            recurringRecipeIDs: recurringRecipeIDs
        )
    }

    private func scheduleGeneratedPlanArtifactRefresh(planID: UUID) {
        latestPlanArtifactRefreshTask?.cancel()
        latestPlanArtifactRefreshTask = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            guard let plan = self.latestPlan, plan.id == planID else { return }

            let hydratedPlan = await self.planHydratedWithRecipeDetailsIfNeeded(plan, refreshProviders: false)
            if !Task.isCancelled, hydratedPlan != plan {
                guard self.latestPlan?.id == planID else { return }
                self.updateCurrentPlanCache(with: hydratedPlan, persistRemote: false)
            }

            _ = await self.persistLatestPlanRemotelyIfPossible(hydratedPlan)

            if !Task.isCancelled, let refreshedPlan = self.latestPlan, refreshedPlan.id == planID {
                _ = await self.persistLatestPlanRemotelyIfPossible(refreshedPlan)
                await self.emitMealPrepReadyNotification(plan: refreshedPlan)
            }

            self.latestPlanArtifactRefreshTask = nil
        }
    }

    private func didMeaningfullyRegeneratePrep(from oldRecipeIDs: [String], to newRecipeIDs: [String], recurringRecipeIDs: Set<String>) -> Bool {
        guard !newRecipeIDs.isEmpty else { return false }
        guard !oldRecipeIDs.isEmpty else { return true }

        let oldNonRecurring = Set(oldRecipeIDs).subtracting(recurringRecipeIDs)
        let newNonRecurring = Set(newRecipeIDs).subtracting(recurringRecipeIDs)
        guard !oldNonRecurring.isEmpty else {
            return Set(oldRecipeIDs) != Set(newRecipeIDs)
        }

        return oldNonRecurring != newNonRecurring
    }

    func refreshLatestPlanGrocerySourcesIfNeeded() async -> Bool {
        guard let latestPlan, let profile, !isGenerating else { return false }
        guard !latestPlan.recipes.isEmpty, !latestPlan.groceryItems.isEmpty else { return false }

        guard let refreshFingerprint = grocerySourceRefreshFingerprint(for: latestPlan) else {
            lastGrocerySourceRefreshFingerprint = nil
            return false
        }
        guard lastGrocerySourceRefreshFingerprint != refreshFingerprint else { return false }
        lastGrocerySourceRefreshFingerprint = refreshFingerprint

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

        guard activeGenerationToken == generationToken, self.profile == profile else { return false }
        guard refreshedPlan != latestPlan else { return false }
        updateCurrentPlanCache(with: refreshedPlan, persistRemote: false)
        _ = await persistLatestPlanRemotelyIfPossible(refreshedPlan)
        if grocerySourceRefreshFingerprint(for: refreshedPlan) == nil {
            lastGrocerySourceRefreshFingerprint = nil
        }
        return true
    }

    private func finalizeCompletedOnboarding(with profile: UserProfile, lastStep: Int) async {
        if let session = await freshUserDataSession() {
            await persistCompletedOnboardingState(
                profile: profile,
                lastStep: lastStep,
                session: session
            )
        }

        if profile.isPlanningReady {
            await generatePlan()
        }

        await refreshMembershipEntitlement(trigger: "post-onboarding")
        if let session = await freshUserDataSession() {
            _ = await loadMealPrepCycles(userID: session.userID, accessToken: session.accessToken)
            await loadCompletedMealPrepCycles(userID: session.userID, accessToken: session.accessToken)
            await loadPrepRecipeOverrides(userID: session.userID, accessToken: session.accessToken)
            await loadRecurringPrepRecipes(userID: session.userID, accessToken: session.accessToken)
            await loadAutomationState(userID: session.userID, accessToken: session.accessToken)
        }
        await loadLatestInstacartRun()
        await loadLatestGroceryOrder()
    }

    private func persistCompletedOnboardingState(
        profile: UserProfile,
        lastStep: Int,
        session: AuthSession
    ) async {
        for attempt in 1...2 {
            do {
                try await SupabaseProfileStateService.shared.upsertProfile(
                    userID: session.userID,
                    email: session.email,
                    displayName: profile.trimmedPreferredName ?? session.displayName,
                    authProvider: session.provider,
                    onboarded: true,
                    lastOnboardingStep: lastStep,
                    profile: profile,
                    accessToken: session.accessToken
                )
                return
            } catch {
                guard attempt == 1 else {
                    print("[onboarding] failed to persist completed profile:", error.localizedDescription)
                    return
                }
                try? await Task.sleep(nanoseconds: 450_000_000)
            }
        }
    }

    func removeRecipeFromLatestPlan(recipeID: String) async {
        guard let profile, let latestPlan, !isGenerating else { return }
        guard let removedRecipe = latestPlan.recipes.first(where: { $0.recipe.id == recipeID }) else { return }

        let override = PrepRecipeOverride(
            recipe: removedRecipe.recipe,
            servings: removedRecipe.servings,
            isIncludedInPrep: false
        )
        cachePrepRecipeOverride(override)

        let remainingRecipes = latestPlan.recipes.filter { $0.recipe.id != recipeID }
        await applyImmediateLatestPlanRecipeMutation(
            profile: profile,
            recipes: remainingRecipes,
            basePlan: latestPlan,
            mutationSummary: "Removed \(removedRecipe.recipe.title) from prep."
        )
        await persistPrepRecipeOverrideIfPossible(override)
        await syncPrepMutationToAutomation(trigger: "prep_recipe_removed", forceCartSync: true)
    }

    func reorderLatestPlanRecipes(recipeIDs orderedRecipeIDs: [String]) async {
        guard let latestPlan, !isGenerating else { return }
        guard orderedRecipeIDs.count == latestPlan.recipes.count else { return }

        let lookup = Dictionary(uniqueKeysWithValues: latestPlan.recipes.map { ($0.recipe.id, $0) })
        let orderedSet = Set(orderedRecipeIDs)
        let reorderedRecipes = orderedRecipeIDs.compactMap { lookup[$0] }
        guard reorderedRecipes.count == latestPlan.recipes.count, orderedSet.count == latestPlan.recipes.count else {
            return
        }

        guard reorderedRecipes != latestPlan.recipes else { return }

        var updatedPlan = latestPlan
        updatedPlan.recipes = reorderedRecipes
        updateCurrentPlanCache(with: updatedPlan)
    }

    func updateLatestPlanMainShopSnapshot(
        _ snapshot: MainShopSnapshot,
        for planID: UUID,
        persistRemote: Bool = false
    ) {
        guard var latestPlan, latestPlan.id == planID else { return }
        guard latestPlan.mainShopSnapshot != snapshot else { return }
        latestPlan.mainShopSnapshot = snapshot
        updateCurrentPlanCache(with: latestPlan, persistRemote: persistRemote)
    }

    func resetAll() {
        authStateRevision += 1
        activeGenerationToken = UUID()
        authSession = nil
        cachedLiveUserID = nil
        isOnboarded = false
        profile = nil
        latestPlan = nil
        planHistory = []
        completedMealPrepCycles = []
        recurringPrepRecipes = []
        automationState = nil
        latestInstacartRun = nil
        latestBlockingInstacartRun = nil
        latestGroceryOrder = nil
        membershipEntitlement = nil
        availableMembershipProducts = [:]
        isBillingBusy = false
        billingStatusMessage = nil
        isGenerating = false
        isRefreshingPrepRecipes = false
        isManualAutoshopRunning = false
        manualAutoshopErrorMessage = nil
        isDeactivatingAccount = false
        pendingCartSyncIntent = nil
        prepRecipeOverrides = []
        remoteMealPrepCycleLoadState = .notRequested
        hiddenMainShopItemKeys = []
        hiddenMainShopPlanID = nil
        UserDefaults.standard.removeObject(forKey: authSessionKey)
        sharedDefaults?.removeObject(forKey: authSessionKey)
        sharedDefaults?.removeObject(forKey: sharedAuthSessionKey)
        UserDefaults.standard.removeObject(forKey: liveUserIDKey)
        sharedDefaults?.removeObject(forKey: liveUserIDKey)
        sharedDefaults?.synchronize()
        deleteAuthSessionFromKeychain()
        UserDefaults.standard.removeObject(forKey: onboardedKey)
        UserDefaults.standard.removeObject(forKey: profileKey)
        UserDefaults.standard.removeObject(forKey: onboardingStepKey)
        UserDefaults.standard.removeObject(forKey: cachedEntryRouteKey)
        UserDefaults.standard.removeObject(forKey: automationStateStorageKey(for: activeHistoryUserID))
        UserDefaults.standard.removeObject(forKey: pendingCartSyncIntentStorageKey(for: activeHistoryUserID))
        UserDefaults.standard.removeObject(forKey: prepRecipeOverridesStorageKey(for: activeHistoryUserID))
        UserDefaults.standard.removeObject(forKey: recurringPrepRecipesStorageKey(for: activeHistoryUserID))
        UserDefaults.standard.removeObject(forKey: Self.googleDevUserIDKey)
        UserDefaults.standard.removeObject(forKey: Self.googleDevEmailKey)
        lastOnboardingStep = 0
        hasResolvedInitialState = true
        isHydratingRemoteState = false
        isCompletingOnboarding = false
        activeHistoryUserID = nil
        activeAutoPrepGenerationKey = nil
        isRunningAutomationPass = false
        cachedAuthenticatedEntryRoute = nil
        hasPersistedOnboardingState = false
    }

    func signOutToWelcome() {
        resetAll()
    }

    func deactivateAccount() async throws {
        guard !isDeactivatingAccount else { return }
        guard let session = await freshUserDataSession() else {
            throw OunjeAccountServiceError.requestFailed("Sign in again before deleting your account.")
        }

        isDeactivatingAccount = true
        defer { isDeactivatingAccount = false }

        try await OunjeAccountService.shared.deactivateAccount(
            userID: session.userID,
            accessToken: session.accessToken
        )
        resetAll()
    }

    private func loadState() {
        let decoder = JSONDecoder()

        if let authData = loadAuthSessionData(),
           let decodedAuth = try? decoder.decode(AuthSession.self, from: authData) {
            authSession = decodedAuth
        }

        cachedLiveUserID = loadLiveUserID()
        let resolvedUserID = authSession?.userID ?? cachedLiveUserID

        hasPersistedOnboardingState = UserDefaults.standard.object(forKey: onboardedKey) != nil
        let persistedOnboardingState = UserDefaults.standard.bool(forKey: onboardedKey)
        isOnboarded = shouldForceOnboardingIncomplete ? false : persistedOnboardingState
        lastOnboardingStep = shouldForceOnboardingIncomplete ? 0 : UserDefaults.standard.integer(forKey: onboardingStepKey)
        if let rawRoute = UserDefaults.standard.string(forKey: cachedEntryRouteKey) {
            cachedAuthenticatedEntryRoute = CachedAuthenticatedEntryRoute(rawValue: rawRoute)
        }

        if let profileData = UserDefaults.standard.data(forKey: profileKey),
           let decodedProfile = try? decoder.decode(UserProfile.self, from: profileData) {
            profile = decodedProfile
        }

        loadHistory(for: resolvedUserID)
        loadPendingCartSyncIntentCache(for: resolvedUserID)
        loadPrepRecipeOverridesCache(for: resolvedUserID)
        loadRecurringPrepRecipesCache(for: resolvedUserID)

        if shouldPurgePersistedPlan(planHistory) {
            planHistory = usablePersistedPlans(from: planHistory)
            latestPlan = planHistory.first
            saveHistory()
        }

        loadCompletedMealPrepCycleCache(for: resolvedUserID)
        loadAutomationStateCache(for: resolvedUserID)

        if authSession != nil, profile == nil {
            profile = .starter
            saveProfile()
        }

        hasResolvedInitialState = authSession == nil
    }

    private func updateCurrentPlanCache(with plan: MealPlan, persistRemote: Bool = true) {
        let previousPlanID = latestPlan?.id
        let previousRecipeSignature = latestPlan?.recipes.map(\.recipe.id).joined(separator: "|") ?? ""
        let nextRecipeSignature = plan.recipes.map(\.recipe.id).joined(separator: "|")
        if grocerySourceRefreshFingerprint(for: latestPlan) != grocerySourceRefreshFingerprint(for: plan) {
            lastGrocerySourceRefreshFingerprint = nil
        }
        latestPlan = plan
        if previousPlanID != plan.id || previousRecipeSignature != nextRecipeSignature {
            latestPlanRevision += 1
        }
        loadHiddenMainShopItems(for: plan.id)
        planHistory.removeAll { $0.id == plan.id }
        planHistory.insert(plan, at: 0)
        if planHistory.count > 12 {
            planHistory = Array(planHistory.prefix(12))
        }
        saveHistory()

        guard persistRemote else { return }
        persistMealPrepCycleIfPossible(plan)
    }

    private func resolvedRecurringRecipeIDs(for plan: MealPlan?) -> [String] {
        recurringPrepRecipes.filter(\.isEnabled).map(\.recipeID)
    }

    private func applyImmediateLatestPlanRecipeMutation(
        profile: UserProfile,
        recipes: [PlannedRecipe],
        basePlan: MealPlan?,
        mutationSummary: String
    ) async {
        let recurringRecipeIDs = resolvedRecurringRecipeIDs(for: basePlan)
        let immediatePlan: MealPlan
        if let basePlan {
            immediatePlan = planner.rebuildPlanCartOnly(
                profile: profile,
                basePlan: basePlan,
                recipes: recipes,
                history: planHistory,
                recurringRecipeIDs: recurringRecipeIDs
            )
        } else {
            immediatePlan = planner.buildPlanCartOnly(
                profile: profile,
                recipes: recipes,
                history: planHistory,
                recurringRecipeIDs: recurringRecipeIDs
            )
        }

        var visiblePlan = immediatePlan
        visiblePlan.pipeline.append(
            PipelineDecision(
                stage: .composeGroceries,
                summary: mutationSummary
            )
        )
        updateCurrentPlanCache(with: visiblePlan)

        let hydratedRecipes = await hydratedPlannedRecipesForCart(recipes)
        guard hydratedRecipes != recipes else {
            _ = await persistLatestPlanRemotelyIfPossible(visiblePlan)
            return
        }

        let hydratedPlan: MealPlan
        if let basePlan {
            hydratedPlan = planner.rebuildPlanCartOnly(
                profile: profile,
                basePlan: basePlan,
                recipes: hydratedRecipes,
                history: planHistory,
                recurringRecipeIDs: recurringRecipeIDs
            )
        } else {
            hydratedPlan = planner.buildPlanCartOnly(
                profile: profile,
                recipes: hydratedRecipes,
                history: planHistory,
                recurringRecipeIDs: recurringRecipeIDs
            )
        }

        var refreshedPlan = hydratedPlan
        refreshedPlan.pipeline.append(
            PipelineDecision(
                stage: .composeGroceries,
                summary: mutationSummary
            )
        )

        updateCurrentPlanCache(with: refreshedPlan)
        _ = await persistLatestPlanRemotelyIfPossible(refreshedPlan)
    }

    private func latestPlanNeedsGroceryRebuild(_ plan: MealPlan) -> Bool {
        guard !plan.recipes.isEmpty else { return false }
        guard !plan.groceryItems.isEmpty else { return true }

        return !planner.hasCompleteGrocerySourceCoverage(
            recipes: plan.recipes,
            groceries: plan.groceryItems
        )
    }

    @discardableResult
    private func rebuildLatestPlanGroceriesIfNeeded(force: Bool = false) async -> Bool {
        guard let latestPlan,
              let profile,
              profile.isPlanningReady,
              !isGenerating
        else {
            return false
        }

        guard force || latestPlanNeedsGroceryRebuild(latestPlan) else {
            return false
        }

        let generationToken = UUID()
        activeGenerationToken = generationToken
        isGenerating = true
        defer { isGenerating = false }

        let refreshedRecipes = await hydratedPlannedRecipesForCart(latestPlan.recipes)
        let recurringRecipeIDs = recurringPrepRecipes.filter(\.isEnabled).map(\.recipeID)
        let rebuiltPlan = planner.rebuildPlanCartOnly(
            profile: profile,
            basePlan: latestPlan,
            recipes: refreshedRecipes,
            history: planHistory,
            recurringRecipeIDs: recurringRecipeIDs
        )

        guard activeGenerationToken == generationToken, self.profile == profile else { return false }
        guard rebuiltPlan != latestPlan else { return false }
        updateCurrentPlanCache(with: rebuiltPlan, persistRemote: false)
        _ = await persistLatestPlanRemotelyIfPossible(rebuiltPlan)
        return true
    }

    private func scheduleLatestPlanArtifactRefresh(
        profile: UserProfile,
        basePlan: MealPlan,
        recipes: [PlannedRecipe],
        recurringRecipeIDs: [String]
    ) {
        let planID = basePlan.id
        latestPlanArtifactRefreshTask?.cancel()
        latestPlanArtifactRefreshTask = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            let refreshedRecipes = await self.hydratedPlannedRecipesForCart(recipes)

            let refreshedPlan = await self.planner.rebuildPlan(
                profile: profile,
                basePlan: basePlan,
                recipes: refreshedRecipes,
                history: self.planHistory,
                recurringRecipeIDs: recurringRecipeIDs
            )

            guard !Task.isCancelled else { return }
            guard let currentPlan = self.latestPlan, currentPlan.id == planID else { return }
            guard currentPlan.recipes == recipes || currentPlan.recipes == refreshedRecipes else { return }
            guard (currentPlan.recurringRecipeIDs ?? []).sorted() == recurringRecipeIDs.sorted() else { return }

            self.updateCurrentPlanCache(with: refreshedPlan)
            _ = await self.persistLatestPlanRemotelyIfPossible(refreshedPlan)
            self.latestPlanArtifactRefreshTask = nil
        }
    }

    private func cachePrepRecipeOverride(_ override: PrepRecipeOverride) {
        guard !override.recipe.isLegacySeedRecipe else { return }

        if let index = prepRecipeOverrides.firstIndex(where: { $0.recipe.id == override.recipe.id }) {
            prepRecipeOverrides[index] = override
        } else {
            prepRecipeOverrides.append(override)
        }
        savePrepRecipeOverridesCache()
    }

    private func prepRecipeOverrideLookup() -> [String: PrepRecipeOverride] {
        Dictionary(uniqueKeysWithValues: prepRecipeOverrides.map { ($0.recipe.id, $0) })
    }

    private func resolvedSavedRecipeIDs() async -> Set<String> {
        guard let session = await freshUserDataSession() else { return [] }
        let ids = await SupabaseSavedRecipesService.shared.resolvedSavedRecipeIDs(
            userID: session.userID,
            accessToken: session.accessToken
        )
        return Set(ids)
    }

    private func resolvedSavedRecipeTitles() async -> [String] {
        guard let session = await freshUserDataSession() else { return [] }
        return (try? await SupabaseSavedRecipesService.shared.fetchSavedRecipeTitles(
            userID: session.userID,
            accessToken: session.accessToken
        )) ?? []
    }

    func isRecurringPrepRecipe(recipeID: String) -> Bool {
        recurringPrepRecipes.first(where: { $0.recipeID == recipeID })?.isEnabled == true
    }

    func isRecurringPrepRecipeToggleInFlight(recipeID: String) -> Bool {
        recurringPrepToggleRecipeIDs.contains(recipeID)
    }

    func toggleRecurringPrepRecipe(_ recipe: Recipe) async -> Bool {
        guard !recurringPrepToggleRecipeIDs.contains(recipe.id) else { return true }
        guard let fallbackSession = await freshUserDataSession() else { return false }

        recurringPrepToggleRecipeIDs.insert(recipe.id)
        defer { recurringPrepToggleRecipeIDs.remove(recipe.id) }

        let now = ISO8601DateFormatter().string(from: .now)
        let previousRecipes = recurringPrepRecipes

        if let existingIndex = recurringPrepRecipes.firstIndex(where: { $0.recipeID == recipe.id }) {
            var existing = recurringPrepRecipes[existingIndex]
            existing.isEnabled.toggle()
            existing.updatedAt = now
            recurringPrepRecipes[existingIndex] = existing
            recurringPrepRecipes = recurringPrepRecipes.sorted { $0.sortDate > $1.sortDate }
            saveRecurringPrepRecipesCache()

            do {
                let session = await freshUserDataSession() ?? fallbackSession
                try await SupabaseRecurringPrepRecipesService.shared.upsertRecurringPrepRecipe(
                    existing,
                    accessToken: session.accessToken
                )
            } catch {
                recurringPrepRecipes = previousRecipes
                saveRecurringPrepRecipesCache()
                print("[MealPlanningAppStore] Failed to save recurring prep toggle for \(recipe.id): \(error)")
                return false
            }
        } else {
            let recurring = RecurringPrepRecipe(
                userID: fallbackSession.userID,
                recipeID: recipe.id,
                recipe: recipe,
                isEnabled: true,
                createdAt: now,
                updatedAt: now
            )
            recurringPrepRecipes.insert(recurring, at: 0)
            recurringPrepRecipes = recurringPrepRecipes.sorted { $0.sortDate > $1.sortDate }
            saveRecurringPrepRecipesCache()

            do {
                let session = await refreshAuthSessionIfNeeded() ?? fallbackSession
                try await SupabaseRecurringPrepRecipesService.shared.upsertRecurringPrepRecipe(
                    recurring,
                    accessToken: session.accessToken
                )
            } catch {
                recurringPrepRecipes = previousRecipes
                saveRecurringPrepRecipesCache()
                print("[MealPlanningAppStore] Failed to save recurring prep recipe for \(recipe.id): \(error)")
                return false
            }
        }

        return true
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

        let hydratedRecipes = await hydratedPlannedRecipesForCart(updatedRecipes)
        guard hydratedRecipes != plan.recipes else { return plan }
        return await planner.rebuildPlan(
            profile: profile,
            basePlan: plan,
            recipes: hydratedRecipes,
            history: planHistory
        )
    }

    private func reconcileLatestPlanWithPrepOverrides() async {
        guard let latestPlan else { return }
        let wasRefreshingPrepRecipes = isRefreshingPrepRecipes
        if !wasRefreshingPrepRecipes {
            isRefreshingPrepRecipes = true
        }
        defer {
            if !wasRefreshingPrepRecipes {
                isRefreshingPrepRecipes = false
            }
        }
        let reconciledPlan = await applyPrepOverridesIfNeeded(to: latestPlan)
        guard reconciledPlan != latestPlan else { return }
        updateCurrentPlanCache(with: reconciledPlan, persistRemote: false)
        _ = await persistLatestPlanRemotelyIfPossible(reconciledPlan)
    }

    func refreshLatestPlanMainShopSnapshotIfNeeded(forceRebuild: Bool = false) async -> Bool {
        guard let latestPlan else { return false }
        guard !latestPlan.recipes.isEmpty, !latestPlan.groceryItems.isEmpty else { return false }

        let signature = MainShopSnapshotBuilder.signature(for: latestPlan.groceryItems)
        if !forceRebuild,
           let snapshot = latestPlan.mainShopSnapshot,
           snapshot.signature == signature,
           snapshot.items.allSatisfy({ $0.sectionKindRawValue != nil }) {
            return false
        }

        isRefreshingMainShopSnapshot = true
        defer { isRefreshingMainShopSnapshot = false }

        do {
            let snapshot = try await MainShopSnapshotBuilder.buildSnapshot(
                for: latestPlan,
                profile: profile,
                refreshToken: forceRebuild ? UUID().uuidString : nil
            )
            guard let currentPlan = self.latestPlan, currentPlan.id == latestPlan.id else { return false }
            updateLatestPlanMainShopSnapshot(snapshot, for: currentPlan.id)
            return true
        } catch {
            return false
        }
    }

    private func loadPrepRecipeOverrides(userID: String, accessToken: String?) async {
        guard !userID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            prepRecipeOverrides = []
            return
        }

        do {
            let fetched = try await SupabasePrepRecipeOverridesService.shared.fetchPrepRecipeOverrides(
                userID: userID,
                accessToken: accessToken
            )
            let legacySeedOverrides = fetched.filter { $0.recipe.isLegacySeedRecipe }
            prepRecipeOverrides = fetched.filter { !$0.recipe.isLegacySeedRecipe }
            savePrepRecipeOverridesCache()

            if !legacySeedOverrides.isEmpty {
                Task(priority: .utility) {
                    for seedOverride in legacySeedOverrides {
                        var disabled = seedOverride
                        disabled.isIncludedInPrep = false
                        try? await SupabasePrepRecipeOverridesService.shared.upsertPrepRecipeOverride(
                            userID: userID,
                            override: disabled,
                            accessToken: accessToken
                        )
                    }
                }
            }
        } catch {
            // Keep the local cache if remote sync fails.
        }
    }

    @discardableResult
    private func loadMealPrepCycles(userID: String, accessToken: String?) async -> RemoteMealPrepCycleLoadState {
        guard !userID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            remoteMealPrepCycleLoadState = .unavailable
            return .unavailable
        }

        do {
            let fetched = try await SupabaseMealPrepCycleService.shared.fetchMealPrepCycles(
                userID: userID,
                accessToken: accessToken
            )
            let usableFetched = usablePersistedPlans(from: fetched)
            guard !usableFetched.isEmpty else {
                remoteMealPrepCycleLoadState = .empty
                return .empty
            }

            let localLatestPlan = latestPlan
            let remoteLatestPlan = usableFetched.first
            let preferredLatestPlan: MealPlan? = {
                guard let localLatestPlan, !localLatestPlan.recipes.isEmpty else {
                    return remoteLatestPlan
                }
                guard let remoteLatestPlan else {
                    return localLatestPlan
                }
                return shouldKeepLocalLatestPlan(localLatestPlan, overRemote: remoteLatestPlan)
                    ? localLatestPlan
                    : remoteLatestPlan
            }()

            if let preferredLatestPlan {
                latestPlan = preferredLatestPlan
                planHistory = mergedMealPrepHistory(
                    preferredLatestPlan: preferredLatestPlan,
                    remotePlans: usableFetched,
                    localPlans: planHistory
                )
            } else {
                latestPlan = remoteLatestPlan
                planHistory = usableFetched
            }
            saveHistory()
            let loadedState: RemoteMealPrepCycleLoadState = .loaded(usableFetched.count)
            remoteMealPrepCycleLoadState = loadedState
            return loadedState
        } catch {
            // Keep the local cache if remote sync fails.
            remoteMealPrepCycleLoadState = .unavailable
            return .unavailable
        }
    }

    private func shouldKeepLocalLatestPlan(_ localPlan: MealPlan, overRemote remotePlan: MealPlan) -> Bool {
        guard localPlan.id != remotePlan.id else { return false }
        return localPlan.generatedAt >= remotePlan.generatedAt
    }

    private func mergedMealPrepHistory(
        preferredLatestPlan: MealPlan,
        remotePlans: [MealPlan],
        localPlans: [MealPlan]
    ) -> [MealPlan] {
        var seenPlanIDs = Set<UUID>()
        var remaining: [MealPlan] = []

        func appendIfNeeded(_ plan: MealPlan) {
            guard !plan.recipes.isEmpty, !seenPlanIDs.contains(plan.id) else { return }
            seenPlanIDs.insert(plan.id)
            if plan.id != preferredLatestPlan.id {
                remaining.append(plan)
            }
        }

        appendIfNeeded(preferredLatestPlan)
        remotePlans.forEach(appendIfNeeded)
        localPlans.forEach(appendIfNeeded)

        return [preferredLatestPlan]
            + remaining
                .sorted { lhs, rhs in
                    if lhs.generatedAt == rhs.generatedAt {
                        return lhs.id.uuidString < rhs.id.uuidString
                    }
                    return lhs.generatedAt > rhs.generatedAt
                }
                .prefix(11)
    }

    private func repairRemotePrepStateIfNeeded(session: AuthSession, remotePlanLoadState: RemoteMealPrepCycleLoadState) async {
        guard remotePlanLoadState.confirmsNoUsablePrep else { return }
        guard let localPlan = latestPlan, !localPlan.recipes.isEmpty else { return }

        if latestPlanNeedsGroceryRebuild(localPlan) {
            _ = await rebuildLatestPlanGroceriesIfNeeded(force: true)
        }

        guard let repairedPlan = latestPlan, !repairedPlan.recipes.isEmpty else { return }

        do {
            try await SupabaseMealPrepCycleService.shared.upsertMealPrepCycle(
                userID: session.userID,
                plan: repairedPlan,
                accessToken: session.accessToken
            )
            _ = await loadMealPrepCycles(userID: session.userID, accessToken: session.accessToken)
        } catch {
            print("[MealPlanningAppStore] Failed to repair remote prep state for user \(session.userID): \(error.localizedDescription)")
        }
    }

    private func repairRemoteCartStateIfNeeded(session: AuthSession) async {
        guard latestPlan?.recipes.isEmpty == false else { return }

        if let plan = latestPlan, latestPlanNeedsGroceryRebuild(plan) {
            _ = await rebuildLatestPlanGroceriesIfNeeded(force: true)
        }
        guard let plan = latestPlan else { return }
        guard !plan.recipes.isEmpty, !plan.groceryItems.isEmpty else { return }

        do {
            try await SupabaseMealPrepCycleService.shared.upsertMealPrepCycle(
                userID: session.userID,
                plan: plan,
                accessToken: session.accessToken
            )
        } catch {
            print("[MealPlanningAppStore] Failed to repair remote cart state for user \(session.userID): \(error.localizedDescription)")
        }
    }

    private func loadCompletedMealPrepCycles(userID: String, accessToken: String?) async {
        guard !userID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        do {
            let fetched = try await SupabaseMealPrepCycleCompletionService.shared.fetchCompletedMealPrepCycles(
                userID: userID,
                accessToken: accessToken
            )
            guard !fetched.isEmpty else { return }
            completedMealPrepCycles = fetched.sorted { $0.sortDate > $1.sortDate }
            saveCompletedMealPrepCycleCache()
        } catch {
            // Keep the local cache if remote sync fails.
        }
    }

    private func loadRecurringPrepRecipes(userID: String, accessToken: String?) async {
        guard !userID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            recurringPrepRecipes = []
            return
        }

        do {
            let fetched = try await SupabaseRecurringPrepRecipesService.shared.fetchRecurringPrepRecipes(
                userID: userID,
                accessToken: accessToken
            )
            recurringPrepRecipes = fetched.sorted { $0.sortDate > $1.sortDate }
            saveRecurringPrepRecipesCache()
        } catch {
            // Keep the local cache if remote sync fails.
        }
    }

    private func loadAutomationState(userID: String, accessToken: String?) async {
        guard !userID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            automationState = nil
            return
        }

        do {
            automationState = try await SupabaseMealPrepAutomationStateService.shared.fetchAutomationState(
                userID: userID,
                accessToken: accessToken
            )
            saveAutomationStateCache()
        } catch {
            // Keep local cache if remote sync fails.
        }
    }

    private func loadLatestInstacartRun() async {
        guard let session = await freshUserDataSession() else {
            latestInstacartRun = nil
            latestBlockingInstacartRun = nil
            return
        }

        do {
            let normalizedCurrentPlanID = latestPlan?.id.uuidString.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
            let selectedRun = try await InstacartRunLogAPIService.shared.fetchCurrentRunSummary(
                userID: session.userID,
                accessToken: session.accessToken,
                mealPlanID: normalizedCurrentPlanID.isEmpty ? nil : normalizedCurrentPlanID
            )
            let isRetryActive: (InstacartRunLogSummary) -> Bool = { run in
                let retryState = run.normalizedRetryState
                return retryState == "queued" || retryState == "running"
            }
            let activeRun = selectedRun.flatMap { run -> InstacartRunLogSummary? in
                let status = run.normalizedStatusKind
                return (status == "running" || status == "queued" || isRetryActive(run) || status == "partial") ? run : nil
            }
            latestBlockingInstacartRun = activeRun
            latestInstacartRun = selectedRun
            if let latestPlan, let profile {
                let currentSignature = automationCartSignature(for: latestPlan.groceryItems)
                let deliveryAnchor = automationAnchorString(for: profile.scheduledDeliveryDate())
                if pendingCartSyncIntent?.planID == latestPlan.id,
                   pendingCartSyncIntent?.cartSignature == currentSignature,
                   pendingCartSyncIntent?.deliveryAnchor == deliveryAnchor,
                   automationState?.lastCartSyncPlanID == latestPlan.id,
                   automationState?.lastCartSignature == currentSignature,
                   automationState?.lastCartSyncForDeliveryAt == deliveryAnchor {
                    pendingCartSyncIntent = nil
                    savePendingCartSyncIntentCache()
                }
            }
            if let latestPlan,
               let profile,
               pendingCartSyncIntent?.planID == latestPlan.id,
               pendingCartSyncIntent?.cartSignature == automationCartSignature(for: latestPlan.groceryItems),
               pendingCartSyncIntent?.deliveryAnchor == automationAnchorString(for: profile.scheduledDeliveryDate()),
               let selectedRun,
               selectedRun.normalizedStatusKind != "running",
               selectedRun.normalizedStatusKind != "queued",
               !["queued", "running"].contains(selectedRun.normalizedRetryState) {
                latestInstacartRun = nil
            }
            await clearStaleQueuedInstacartRerunIfNeeded(trigger: "run_load")
        } catch {
            latestInstacartRun = nil
            latestBlockingInstacartRun = nil
        }
    }

    private func hydrateInstacartArtifacts(
        runID: String?,
        groceryOrderID: UUID?,
        session: AuthSession
    ) async {
        let trimmedRunID = runID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if !trimmedRunID.isEmpty,
           let summary = try? await InstacartRunLogAPIService.shared.fetchRunSummary(
                runID: trimmedRunID,
                userID: session.userID,
                accessToken: session.accessToken
           ) {
            if isCurrentPlanRun(summary) {
                latestInstacartRun = summary
            } else if summary.normalizedStatusKind == "running" || ["queued", "running"].contains(summary.normalizedRetryState) {
                latestBlockingInstacartRun = summary
            }
            NotificationCenter.default.post(name: .instacartRunSummaryDidUpdate, object: summary)
        } else {
            await loadLatestInstacartRun()
        }

        if let groceryOrderID,
           let order = try? await GroceryOrderAPIService.shared.fetchOrder(
                orderID: groceryOrderID,
                userID: session.userID,
                accessToken: session.accessToken
           ) {
            latestGroceryOrder = order
        } else {
            await loadLatestGroceryOrder()
        }
    }

    private func loadLatestGroceryOrder() async {
        guard let session = await freshUserDataSession() else {
            latestGroceryOrder = nil
            return
        }

        if let linkedOrderID = latestInstacartRun?.linkedGroceryOrderID,
           let linkedOrder = try? await GroceryOrderAPIService.shared.fetchOrder(
                orderID: linkedOrderID,
                userID: session.userID,
                accessToken: session.accessToken
           ) {
            latestGroceryOrder = linkedOrder
        } else {
            latestGroceryOrder = nil
        }
    }

    func refreshLatestGroceryOrderTracking() async {
        if latestGroceryOrder == nil {
            await loadLatestGroceryOrder()
        }
        guard let latestGroceryOrder, latestGroceryOrder.normalizedProvider == "instacart" else { return }
        guard let userID = resolvedLiveUserID else {
            await loadLatestGroceryOrder()
            return
        }
        if shouldBackoffTrackingAuthFailure(for: userID) {
            await loadLatestGroceryOrder()
            return
        }

        do {
            if let session = await freshUserDataSession(),
               let accessToken = session.accessToken?.trimmingCharacters(in: .whitespacesAndNewlines),
               !accessToken.isEmpty {
                try await GroceryOrderAPIService.shared.trackOrder(
                    orderID: latestGroceryOrder.id,
                    userID: userID,
                    accessToken: accessToken
                )
                lastTrackingAuthFailureUserID = nil
                lastTrackingAuthFailureAt = nil
            }
            await loadLatestGroceryOrder()
        } catch {
            if isAuthorizationFailure(error) {
                recordTrackingAuthFailure(for: userID)
            }
            if isAuthorizationFailure(error),
               let retriedSession = await freshUserDataSession(),
               let refreshedToken = retriedSession.accessToken?.trimmingCharacters(in: .whitespacesAndNewlines),
               !refreshedToken.isEmpty {
                do {
                    try await GroceryOrderAPIService.shared.trackOrder(
                        orderID: latestGroceryOrder.id,
                        userID: userID,
                        accessToken: refreshedToken
                    )
                } catch {}
            }
            await loadLatestGroceryOrder()
        }
    }

    func refreshLiveTrackingState() async {
        _ = await refreshAuthSessionIfNeeded()

        guard resolvedLiveUserID != nil else {
            latestInstacartRun = nil
            latestBlockingInstacartRun = nil
            latestGroceryOrder = nil
            return
        }

        await loadLatestInstacartRun()
        await loadLatestGroceryOrder()
        await clearStaleQueuedInstacartRerunIfNeeded(trigger: "live_refresh")
        await maybeRefreshLatestGroceryOrderTrackingIfNeeded(trigger: "live_refresh")
        await processQueuedInstacartRerunIfNeeded()
    }

    func refreshRealtimeTrackingState(runID: String? = nil, groceryOrderID: UUID? = nil) async {
        _ = await refreshAuthSessionIfNeeded()

        guard resolvedLiveUserID != nil else {
            latestInstacartRun = nil
            latestBlockingInstacartRun = nil
            latestGroceryOrder = nil
            return
        }

        if let session = await freshUserDataSession() {
            await hydrateInstacartArtifacts(
                runID: runID,
                groceryOrderID: groceryOrderID,
                session: session
            )
            await clearStaleQueuedInstacartRerunIfNeeded(trigger: "realtime")
            await maybeRefreshLatestGroceryOrderTrackingIfNeeded(trigger: "realtime")
            await processQueuedInstacartRerunIfNeeded()
        } else {
            await refreshLiveTrackingState()
        }
    }

    func refreshRealtimeMealPrepState(trigger: String = "realtime") async {
        guard let session = await freshUserDataSession() else { return }
        isRefreshingPrepRecipes = true
        defer { isRefreshingPrepRecipes = false }

        let remotePlanLoadState = await loadMealPrepCycles(
            userID: session.userID,
            accessToken: session.accessToken
        )
        await loadCompletedMealPrepCycles(userID: session.userID, accessToken: session.accessToken)
        await loadPrepRecipeOverrides(userID: session.userID, accessToken: session.accessToken)
        await loadRecurringPrepRecipes(userID: session.userID, accessToken: session.accessToken)
        await loadAutomationState(userID: session.userID, accessToken: session.accessToken)
        await repairRemotePrepStateIfNeeded(session: session, remotePlanLoadState: remotePlanLoadState)
        await reconcileLatestPlanWithPrepOverrides()
        await repairRemoteCartStateIfNeeded(session: session)

        if trigger == "main_shop_snapshot.updated" {
            _ = await refreshLatestPlanMainShopSnapshotIfNeeded(forceRebuild: false)
        }
    }

    func refreshRealtimeRecurringPrepRecipes(trigger: String = "realtime") async {
        guard let session = await freshUserDataSession() else { return }
        await loadRecurringPrepRecipes(userID: session.userID, accessToken: session.accessToken)
    }

    private func clearStaleQueuedInstacartRerunIfNeeded(trigger: String) async {
        guard let latestRun = latestInstacartRun else { return }
        guard latestRun.normalizedStatusKind == "completed",
              latestRun.unresolvedCount == 0,
              latestRun.shortfallCount == 0 else {
            return
        }

        var didClearState = false
        if manualInstacartRerunQueuedAt != nil {
            manualInstacartRerunQueuedAt = nil
            didClearState = true
        }
        if let latestPlan,
           let pendingCartSyncIntent,
           pendingCartSyncIntent.planID == latestPlan.id,
           pendingCartSyncIntent.cartSignature == automationCartSignature(for: latestPlan.groceryItems) {
            self.pendingCartSyncIntent = nil
            savePendingCartSyncIntentCache()
            didClearState = true
        }

        if automationState?.lastInstacartRetryQueuedForRunID != nil || automationState?.lastInstacartRetryQueuedAt != nil {
            automationState = updatedAutomationState {
                $0.lastInstacartRetryQueuedForRunID = nil
                $0.lastInstacartRetryQueuedAt = nil
                $0.lastInstacartRunStatus = "completed"
                $0.lastGeneratedReason = "instacart_completed:\(trigger)"
            }
            saveAutomationStateCache()
            persistAutomationStateIfPossible()
            didClearState = true
        }

        if didClearState {
            NotificationCenter.default.post(name: .instacartRunSummaryDidUpdate, object: latestRun)
        }
    }

    private func processQueuedInstacartRerunIfNeeded() async {
        guard manualInstacartRerunQueuedAt != nil || pendingCartSyncIntent != nil else { return }
        guard !hasBlockingInstacartActivity else { return }

        if pendingCartSyncIntent != nil {
            pendingCartSyncIntent = nil
            savePendingCartSyncIntentCache()
            return
        }

        manualInstacartRerunQueuedAt = nil
        await rerunInstacartShopping()
    }

    var hasLiveInstacartActivity: Bool {
        for run in [latestInstacartRun, latestBlockingInstacartRun].compactMap({ $0 }) {
            if ["queued", "running"].contains(run.normalizedRetryState) {
                return true
            }
            switch run.normalizedStatusKind {
            case "running", "queued", "partial":
                return true
            default:
                break
            }
        }

        if latestGroceryOrderBelongsToCurrentRun, let order = latestGroceryOrder {
            let status = order.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if status == "failed" || status == "cancelled" || status == "completed" {
                return false
            }
            if order.deliveredAt != nil {
                return false
            }
            if order.normalizedTrackingStatus == "delivered" {
                return false
            }
            if order.normalizedProvider == "instacart" {
                return true
            }
        }

        return false
    }

    var hasBlockingInstacartActivity: Bool {
        for run in [latestInstacartRun, latestBlockingInstacartRun].compactMap({ $0 }) {
            if ["queued", "running"].contains(run.normalizedRetryState) {
                return true
            }
            switch run.normalizedStatusKind {
            case "running", "queued":
                return true
            default:
                break
            }
        }

        if latestGroceryOrderBelongsToCurrentRun, let order = latestGroceryOrder {
            let status = order.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if ["awaiting_review", "user_approved", "checkout_started", "shopping", "out_for_delivery"].contains(status) {
                return true
            }
            if order.deliveredAt != nil || order.normalizedTrackingStatus == "delivered" {
                return false
            }
        }

        return false
    }

    private var latestGroceryOrderBelongsToCurrentRun: Bool {
        guard let linkedOrderID = latestInstacartRun?.linkedGroceryOrderID,
              let latestGroceryOrder else {
            return false
        }
        return linkedOrderID == latestGroceryOrder.id
    }

    var resolvedRecurringAnchorCount: Int {
        recurringPrepRecipes.filter(\.isEnabled).count
    }

    private func persistMealPrepCycleIfPossible(_ plan: MealPlan) {
        guard !plan.recipes.isEmpty else {
            print("[MealPlanningAppStore] Skipping remote meal prep cycle persistence for empty-shell plan \(plan.id)")
            return
        }

        Task(priority: .utility) {
            _ = await self.persistLatestPlanRemotelyIfPossible(plan)
        }
    }

    @discardableResult
    private func persistLatestPlanRemotelyIfPossible(_ plan: MealPlan, syncCart: Bool = false) async -> Bool {
        guard let session = await freshUserDataSession() else { return false }
        guard isUsablePersistedPlan(plan) else {
            print("[MealPlanningAppStore] Skipping remote meal prep cycle persistence for unsupported plan \(plan.id) with \(plan.recipes.count) recipes")
            return false
        }

        do {
            try await SupabaseMealPrepCycleService.shared.upsertMealPrepCycle(
                userID: session.userID,
                plan: plan,
                accessToken: session.accessToken,
                syncCart: syncCart
            )
            return true
        } catch {
            print("[MealPlanningAppStore] Failed to immediately persist meal prep cycle \(plan.id) for user \(session.userID): \(error.localizedDescription)")
            return false
        }
    }

    private func persistPrepRecipeOverrideIfPossible(_ override: PrepRecipeOverride) async {
        guard !override.recipe.isLegacySeedRecipe else { return }
        guard let session = await freshUserDataSession() else { return }

        try? await SupabasePrepRecipeOverridesService.shared.upsertPrepRecipeOverride(
            userID: session.userID,
            override: override,
            accessToken: session.accessToken
        )
    }

    private func persistAutomationStateIfPossible() {
        guard let state = automationState else { return }
        Task(priority: .utility) {
            guard let session = await self.freshUserDataSession() else { return }
            var stateToPersist = state
            if stateToPersist.userID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                stateToPersist.userID = session.userID
            }
            try? await SupabaseMealPrepAutomationStateService.shared.upsertAutomationState(
                stateToPersist,
                accessToken: session.accessToken
            )
        }
    }

    private func syncPrepMutationToAutomation(trigger: String, forceCartSync: Bool) async {
        if forceCartSync {
            let needsGroceryRebuild = latestPlan.map { latestPlanNeedsGroceryRebuild($0) } ?? false
            _ = await rebuildLatestPlanGroceriesIfNeeded(force: needsGroceryRebuild)
        }
        automationState = updatedAutomationState {
            $0.lastEvaluatedAt = ISO8601DateFormatter().string(from: .now)
            $0.lastGeneratedReason = trigger
            if forceCartSync {
                $0.lastCartSignature = nil
                $0.lastCartSyncPlanID = nil
                $0.lastCartSyncForDeliveryAt = nil
            }
        }
        if forceCartSync,
           let latestRun = latestInstacartRun,
           latestRun.normalizedStatusKind == "partial" || latestRun.normalizedStatusKind == "failed" || !isCurrentPlanRun(latestRun) {
            latestInstacartRun = nil
        }
        saveAutomationStateCache()
        persistAutomationStateIfPossible()
    }

    func runAutomationPassIfNeeded(trigger: String) async {
        let isPassiveStartupTrigger = trigger == "scene_active" || trigger == "ensure_fresh_plan"
        if !hasResolvedInitialState {
            return
        }
        if isPassiveStartupTrigger && latestPlan == nil && planHistory.isEmpty {
            return
        }

        guard let profile,
              isOnboarded,
              profile.isAutomationReady,
              !isGenerating,
              !isRunningAutomationPass
        else {
            return
        }

        if trigger == "scene_active",
           let lastAutomationSceneActiveAt,
           Date().timeIntervalSince(lastAutomationSceneActiveAt) < 30 {
            return
        }

        isRunningAutomationPass = true
        defer { isRunningAutomationPass = false }
        if trigger == "scene_active" {
            lastAutomationSceneActiveAt = .now
        }

        let nextDelivery = profile.scheduledDeliveryDate()
        await loadLatestInstacartRun()
        await loadLatestGroceryOrder()
        await maybeRefreshLatestGroceryOrderTrackingIfNeeded(trigger: trigger)
        automationState = updatedAutomationState {
            let formatter = ISO8601DateFormatter()
            $0.lastEvaluatedAt = formatter.string(from: .now)
            $0.nextPlanningWindowAt = formatter.string(from: planningWindowOpenDate(for: profile, nextDelivery: nextDelivery))
            $0.autoshopEnabled = profile.isAutoshopOptedIn
            $0.autoshopLeadDays = profile.autoshopLeadDays
            $0.nextPrepAt = formatter.string(from: nextDelivery)
            $0.nextCartSyncAt = formatter.string(from: cartSetupWindowOpenDate(for: profile, nextDelivery: nextDelivery))
        }
        saveAutomationStateCache()
        persistAutomationStateIfPossible()

        await maybeRotateCompletedPrepIfNeeded()

        if isPassiveStartupTrigger {
            // Passive app-entry triggers should never mutate prep recipes/groceries.
            // Keep this to view-model hygiene only.
            return
        } else if shouldGeneratePlan(for: profile, nextDelivery: nextDelivery) {
            await generatePlan()
            return
        }

        if !isPassiveStartupTrigger {
            _ = await rebuildLatestPlanGroceriesIfNeeded(force: false)
        }
    }

    private func shouldGeneratePlan(for profile: UserProfile, nextDelivery: Date) -> Bool {
        let now = Date()
        let planningWindowOpen = planningWindowOpenDate(for: profile, nextDelivery: nextDelivery)
        guard now >= planningWindowOpen else { return false }

        guard let latestPlan else { return true }

        let hasLegacySeedRecipes = latestPlan.recipes.contains(where: { $0.recipe.isLegacySeedRecipe })
        let hasKnownSampleRecipes = latestPlan.recipes.contains(where: { $0.recipe.isKnownSampleRecipe })
        let missingImageCount = latestPlan.recipes.reduce(into: 0) { partialResult, plannedRecipe in
            if plannedRecipe.recipe.isImagePoor {
                partialResult += 1
            }
        }
        let planIsImagePoor = missingImageCount >= max(2, Int(ceil(Double(latestPlan.recipes.count) * 0.5)))
        let planIsExpired = latestPlan.periodEnd < now
        let planDrift = abs(latestPlan.periodStart.timeIntervalSince(nextDelivery))
        let isMisalignedWithNextDelivery = planDrift > max(18 * 60 * 60, Double(profile.cadence.dayInterval) * 0.18 * 24 * 60 * 60)
        let alreadyGeneratedForAnchor = automationState?.lastGeneratedForDeliveryAt == automationAnchorString(for: nextDelivery)

        if alreadyGeneratedForAnchor && latestPlan.periodEnd >= now && !isMisalignedWithNextDelivery {
            return false
        }

        return hasLegacySeedRecipes
            || hasKnownSampleRecipes
            || planIsImagePoor
            || planIsExpired
            || isMisalignedWithNextDelivery
            || latestPlan.recipes.isEmpty
            || latestPlan.groceryItems.isEmpty
    }

    private func maybeStartInstacartRunIfNeeded(
        trigger: String,
        force: Bool = false,
        allowPlanRepair: Bool = true
    ) async {
        guard !isAutoshopManualBetaOnly else { return }
        if let latestPlanArtifactRefreshTask {
            await latestPlanArtifactRefreshTask.value
        }

        guard let session = await freshUserDataSession(),
              let profile,
              profile.deliveryAddress.isComplete,
              profile.isAutoshopOptedIn
        else {
            return
        }

        if allowPlanRepair {
            if let latestPlan, latestPlanNeedsGroceryRebuild(latestPlan) {
                _ = await rebuildLatestPlanGroceriesIfNeeded(force: true)
            } else if latestPlan?.groceryItems.isEmpty == true {
                _ = await refreshLatestPlanGrocerySourcesIfNeeded()
            }
        }

        guard let latestPlan,
              latestPlan.bestQuote?.provider == .instacart,
              !latestPlan.groceryItems.isEmpty
        else {
            return
        }
        let autoshopPlan = planCappedForAutoshop(latestPlan)

        let nextDelivery = profile.scheduledDeliveryDate()
        let initialSetupWindowOpen = cartSetupWindowOpenDate(for: profile, nextDelivery: nextDelivery)
        let confirmationWindowOpen = cartConfirmationWindowOpenDate(for: profile, nextDelivery: nextDelivery)
        let now = Date()

        let normalizedItems = autoshopPlan.groceryItems

        guard !normalizedItems.isEmpty else { return }
        let cartSignature = automationCartSignature(for: normalizedItems)
        let deliveryAnchor = automationAnchorString(for: nextDelivery)
        if let intent = pendingCartSyncIntent,
           intent.planID != autoshopPlan.id || intent.cartSignature != cartSignature || intent.deliveryAnchor != deliveryAnchor {
            pendingCartSyncIntent = nil
            savePendingCartSyncIntentCache()
        }
        let hasPendingCartSyncIntent = pendingCartSyncIntent?.planID == autoshopPlan.id
            && pendingCartSyncIntent?.cartSignature == cartSignature
            && pendingCartSyncIntent?.deliveryAnchor == deliveryAnchor
        let shouldForceRun = force || hasPendingCartSyncIntent
        guard shouldForceRun || now >= initialSetupWindowOpen else { return }
        let hasSyncedCurrentSignature = automationState?.lastCartSignature == cartSignature
            && automationState?.lastCartSyncForDeliveryAt == deliveryAnchor
        let latestRun = latestInstacartRun
        let latestRunReady = latestRun.map { run in
            let normalizedStatus = run.statusKind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return normalizedStatus == "completed"
                && run.unresolvedCount == 0
                && run.shortfallCount == 0
        } ?? false
        if hasBlockingInstacartActivity, latestRun?.normalizedStatusKind != "running" {
            manualInstacartRerunQueuedAt = .now
            return
        }
        if latestRun?.normalizedStatusKind == "running" {
            return
        }
        if !shouldForceRun, let partialRun = latestRun, partialRun.normalizedStatusKind == "partial" {
            if !partialRun.normalizedRetryState.isEmpty {
                return
            }
            if automationState?.lastInstacartRetryQueuedForRunID == partialRun.runId {
                return
            }

            await queuePartialInstacartRetryIfNeeded(
                rootRunID: partialRun.runId,
                latestPlan: autoshopPlan,
                session: session,
                deliveryAddress: profile.deliveryAddress,
                trigger: trigger
            )
            return
        }
        let needsConfirmationPass = now >= confirmationWindowOpen && !latestRunReady

        if !shouldForceRun, hasSyncedCurrentSignature && !needsConfirmationPass {
            return
        }

        do {
            let response = try await InstacartAutomationAPIService.shared.startRun(
                items: normalizedItems,
                mealPlan: autoshopPlan,
                userID: session.userID,
                accessToken: session.accessToken,
                deliveryAddress: profile.deliveryAddress
            )
            automationState = updatedAutomationState {
                $0.autoshopEnabled = profile.isAutoshopOptedIn
                $0.autoshopLeadDays = profile.autoshopLeadDays
                $0.nextPrepAt = ISO8601DateFormatter().string(from: nextDelivery)
                $0.nextCartSyncAt = ISO8601DateFormatter().string(from: initialSetupWindowOpen)
                $0.lastCartSyncTrigger = needsConfirmationPass ? "confirm:\(trigger)" : trigger
                $0.lastCartSyncForDeliveryAt = deliveryAnchor
                $0.lastCartSyncPlanID = autoshopPlan.id
                $0.lastCartSignature = cartSignature
                $0.lastInstacartRunID = response.runID
                $0.lastInstacartRunStatus = response.normalizedStatus
                $0.lastGeneratedReason = needsConfirmationPass ? "confirm:\(trigger)" : trigger
            }
            clearPendingCartSyncIntentIfMatched(
                planID: autoshopPlan.id,
                cartSignature: cartSignature,
                deliveryAnchor: deliveryAnchor
            )
            manualInstacartRerunQueuedAt = nil
            saveAutomationStateCache()
            persistAutomationStateIfPossible()
            await hydrateInstacartArtifacts(
                runID: response.runID,
                groceryOrderID: response.groceryOrderID,
                session: session
            )
            await emitLifecycleNotificationsIfNeeded(trigger: needsConfirmationPass ? "confirmation_run_started" : (force ? "manual_rerun_started" : "instacart_run_started"))
        } catch {
            automationState = updatedAutomationState {
                $0.autoshopEnabled = profile.isAutoshopOptedIn
                $0.autoshopLeadDays = profile.autoshopLeadDays
                $0.nextPrepAt = ISO8601DateFormatter().string(from: nextDelivery)
                $0.nextCartSyncAt = ISO8601DateFormatter().string(from: initialSetupWindowOpen)
                $0.lastCartSyncTrigger = needsConfirmationPass ? "confirm:\(trigger)" : trigger
                $0.lastCartSyncForDeliveryAt = nil
                $0.lastCartSyncPlanID = nil
                $0.lastCartSignature = nil
                $0.lastInstacartRunStatus = "failed"
                $0.lastGeneratedReason = needsConfirmationPass ? "instacart_confirm_failed:\(trigger)" : "instacart_run_failed:\(trigger)"
            }
            saveAutomationStateCache()
            persistAutomationStateIfPossible()
            await loadLatestInstacartRun()
            await loadLatestGroceryOrder()
            await emitInstacartIssueNotification(
                title: "Ounje is updating Instacart",
                body: "We hit a snag while lining up your groceries. Ounje will keep retrying in the background.",
                dedupeSuffix: "\(deliveryAnchor)-\(trigger)"
            )
        }
    }

    private func queuePartialInstacartRetryIfNeeded(
        rootRunID: String,
        latestPlan: MealPlan,
        session: AuthSession,
        deliveryAddress: DeliveryAddress,
        trigger: String
    ) async {
        let trimmedRunID = rootRunID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRunID.isEmpty else { return }
        guard automationState?.lastInstacartRetryQueuedForRunID != trimmedRunID else { return }

        do {
            let trace = try await InstacartRunLogAPIService.shared.fetchRunTrace(
                runID: trimmedRunID,
                userID: session.userID,
                accessToken: session.accessToken
            )
            let retryItems = partialRetryItems(from: trace, in: latestPlan)
            guard !retryItems.isEmpty else {
            automationState = updatedAutomationState {
                $0.lastInstacartRetryQueuedForRunID = trimmedRunID
                $0.lastInstacartRetryQueuedAt = ISO8601DateFormatter().string(from: Date())
                $0.lastInstacartRunStatus = "partial_retry_skipped"
            }
                saveAutomationStateCache()
                persistAutomationStateIfPossible()
                return
            }

            automationState = updatedAutomationState {
                $0.lastInstacartRetryQueuedForRunID = trimmedRunID
                $0.lastInstacartRetryQueuedAt = ISO8601DateFormatter().string(from: Date())
                $0.lastInstacartRunStatus = "partial_retry_queued"
                $0.lastGeneratedReason = "partial_retry_queued:\(trigger)"
            }
            saveAutomationStateCache()
            persistAutomationStateIfPossible()

            automationState = updatedAutomationState {
                $0.lastInstacartRetryQueuedForRunID = trimmedRunID
                $0.lastInstacartRetryQueuedAt = ISO8601DateFormatter().string(from: Date())
                $0.lastInstacartRunStatus = "running"
                $0.lastGeneratedReason = "partial_retry_running:\(trigger)"
            }
            saveAutomationStateCache()
            persistAutomationStateIfPossible()

            let response = try await InstacartAutomationAPIService.shared.startRun(
                items: retryItems,
                mealPlan: latestPlan,
                userID: session.userID,
                accessToken: session.accessToken,
                deliveryAddress: deliveryAddress,
                retryContext: InstacartAutomationRetryContextPayload(
                    kind: "partial_retry",
                    rootRunID: trimmedRunID,
                    attempt: 1
                )
            )

            automationState = updatedAutomationState {
                $0.lastCartSignature = automationCartSignature(for: retryItems)
                $0.lastInstacartRunID = response.runID
                if response.normalizedStatus == "queued" || response.normalizedStatus == "running" {
                    $0.lastInstacartRunStatus = "partial_retry_queued"
                    $0.lastGeneratedReason = "partial_retry_queued:\(trigger)"
                } else if response.success {
                    $0.lastInstacartRunStatus = "completed"
                    $0.lastGeneratedReason = "partial_retry_completed:\(trigger)"
                } else if response.partialSuccess {
                    $0.lastInstacartRunStatus = "partial_retry_started"
                    $0.lastGeneratedReason = "partial_retry_started:\(trigger)"
                } else {
                    $0.lastInstacartRunStatus = "partial_retry_failed"
                    $0.lastGeneratedReason = "partial_retry_failed:\(trigger)"
                }
            }
            saveAutomationStateCache()
            persistAutomationStateIfPossible()
            await hydrateInstacartArtifacts(
                runID: response.runID,
                groceryOrderID: response.groceryOrderID,
                session: session
            )
            await emitLifecycleNotificationsIfNeeded(trigger: "partial_retry_started")
        } catch {
            automationState = updatedAutomationState {
                $0.lastInstacartRetryQueuedForRunID = trimmedRunID
                $0.lastInstacartRetryQueuedAt = ISO8601DateFormatter().string(from: Date())
                $0.lastInstacartRunStatus = "partial_retry_failed"
                $0.lastGeneratedReason = "partial_retry_failed:\(trigger)"
            }
            saveAutomationStateCache()
            persistAutomationStateIfPossible()
            await emitInstacartIssueNotification(
                title: "Ounje is updating Instacart",
                body: "The unfinished items are queued for background retry.",
                dedupeSuffix: "partial-retry-\(trimmedRunID)"
            )
        }
    }

    private func partialRetryItems(from trace: InstacartRunTracePayload, in latestPlan: MealPlan) -> [GroceryItem] {
        let retryKeys = Set(
            trace.items.compactMap { item -> String? in
                let status = item.finalStatus?.status?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
                let shortfall = item.finalStatus?.shortfall ?? 0
                guard status == "unresolved" || status == "failed" || shortfall > 0 else {
                    return nil
                }
                return [
                    item.requested,
                    item.canonicalName,
                    item.normalizedQuery
                ]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first
            }
            .map { Self.normalizedCartKey($0) }
            .filter { !$0.isEmpty }
        )

        guard !retryKeys.isEmpty else { return [] }

        var items: [GroceryItem] = []
        var seen = Set<String>()
        for item in latestPlan.groceryItems {
            let itemKey = Self.normalizedCartKey(item.name)
            guard !itemKey.isEmpty, retryKeys.contains(itemKey), seen.insert(itemKey).inserted else {
                continue
            }
            items.append(item)
        }

        return items
    }

    private func maybeRefreshLatestGroceryOrderTrackingIfNeeded(trigger: String) async {
        guard let latestGroceryOrder,
              latestGroceryOrder.normalizedProvider == "instacart",
              latestGroceryOrder.needsTrackingRefresh
        else {
            return
        }

        let normalizedTrigger = trigger.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalizedTrigger == "profile_updated" {
            return
        }

        await refreshLatestGroceryOrderTracking()
    }

    private func maybeRotateCompletedPrepIfNeeded() async {
        if let latestPlan, latestPlan.periodEnd < .now {
            await recordCompletedMealPrepCycleIfNeeded(for: latestPlan)
            return
        }

        guard let latestPlan,
              let latestGroceryOrder,
              latestGroceryOrder.normalizedTrackingStatus == "delivered"
        else {
            return
        }

        let calendar = Calendar.current
        let deliveryDate = latestGroceryOrder.deliveredAt ?? latestGroceryOrder.completedAt ?? .now
        let deliveredOnOrAfterPlanStart = deliveryDate >= latestPlan.periodStart.addingTimeInterval(-12 * 60 * 60)
        let deliveredInCurrentCycle = calendar.isDate(deliveryDate, inSameDayAs: latestPlan.periodStart)
            || deliveryDate >= latestPlan.periodStart

        if deliveredOnOrAfterPlanStart || deliveredInCurrentCycle {
            await recordCompletedMealPrepCycleIfNeeded(for: latestPlan)
        }
    }

    private func maybeAdvanceGroceryCheckoutIfNeeded(trigger: String) async {
        guard !isAutoshopManualBetaOnly else { return }
        guard let profile,
              let latestGroceryOrder,
              latestGroceryOrder.normalizedProvider == "instacart"
        else {
            return
        }

        guard let session = await freshTrackingSession() else { return }

        let normalizedStatus = latestGroceryOrder.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        switch normalizedStatus {
        case "awaiting_review":
            guard canAutoAdvanceCheckout(for: profile) else { return }
            do {
                try await approveOrderWithRefresh(orderID: latestGroceryOrder.id, session: session)
                await loadLatestGroceryOrder()
                await emitNotificationEvent(
                    kind: "grocery_order_confirmed",
                    dedupeKey: "grocery-auto-approved-\(latestGroceryOrder.id.uuidString)",
                    title: "Checkout moved forward automatically",
                    body: "Ounje approved the Instacart checkout because it stayed within your budget.",
                    orderID: latestGroceryOrder.id,
                    metadata: [
                        "trigger": trigger,
                        "approval_mode": "auto"
                    ]
                )
            } catch {
                await loadLatestGroceryOrder()
            }
        case "checkout_started", "user_approved":
            guard latestGroceryOrder.normalizedTrackingStatus != "unknown"
                    || (latestGroceryOrder.providerTrackingURLString?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
            else {
                return
            }
            do {
                try await completeOrderWithRefresh(orderID: latestGroceryOrder.id, session: session)
                await loadLatestGroceryOrder()
            } catch {
                await loadLatestGroceryOrder()
            }
        default:
            return
        }
    }

    private func approveOrderWithRefresh(orderID: UUID, session: AuthSession) async throws {
        do {
            try await GroceryOrderAPIService.shared.approveOrder(
                orderID: orderID,
                tipCents: 0,
                userID: session.userID,
                accessToken: session.accessToken
            )
        } catch {
            guard isAuthorizationFailure(error),
                  let refreshedSession = await freshTrackingSession()
            else {
                throw error
            }
            try await GroceryOrderAPIService.shared.approveOrder(
                orderID: orderID,
                tipCents: 0,
                userID: refreshedSession.userID,
                accessToken: refreshedSession.accessToken
            )
        }
    }

    private func completeOrderWithRefresh(orderID: UUID, session: AuthSession) async throws {
        do {
            try await GroceryOrderAPIService.shared.completeOrder(
                orderID: orderID,
                providerOrderID: nil,
                userID: session.userID,
                accessToken: session.accessToken
            )
        } catch {
            guard isAuthorizationFailure(error),
                  let refreshedSession = await freshTrackingSession()
            else {
                throw error
            }
            try await GroceryOrderAPIService.shared.completeOrder(
                orderID: orderID,
                providerOrderID: nil,
                userID: refreshedSession.userID,
                accessToken: refreshedSession.accessToken
            )
        }
    }

    private func isAuthorizationFailure(_ error: Error) -> Bool {
        let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return message.contains("authorization")
            || message.contains("jwt")
            || message.contains("token is expired")
            || message.contains("401")
            || message.contains("userauthenticationrequired")
    }

    private func shouldBackoffTrackingAuthFailure(for userID: String) -> Bool {
        guard lastTrackingAuthFailureUserID == userID,
              let lastTrackingAuthFailureAt
        else {
            return false
        }

        return Date().timeIntervalSince(lastTrackingAuthFailureAt) < 15 * 60
    }

    private func recordTrackingAuthFailure(for userID: String) {
        lastTrackingAuthFailureUserID = userID
        lastTrackingAuthFailureAt = Date()
    }

    private func canAutoAdvanceCheckout(for profile: UserProfile) -> Bool {
        switch effectivePricingTier {
        case .free:
            return false
        case .plus:
            return profile.orderingAutonomy == .autoOrderWithinBudget
        case .autopilot, .foundingLifetime:
            return profile.orderingAutonomy == .autoOrderWithinBudget
                || profile.orderingAutonomy == .fullyAutonomousGuardrails
        }
    }

    private func emitLifecycleNotificationsIfNeeded(trigger: String) async {
        guard let profile,
              let latestPlan
        else {
            return
        }

        let nextDelivery = profile.scheduledDeliveryDate()
        let anchor = automationAnchorString(for: nextDelivery)

        if let latestInstacartRun,
           latestInstacartRun.normalizedStatusKind == "completed",
           latestInstacartRun.unresolvedCount == 0,
           latestInstacartRun.shortfallCount == 0 {
            if profile.orderingAutonomy == .approvalRequired {
                await emitNotificationEvent(
                    kind: "checkout_approval_required",
                    dedupeKey: "checkout-approval-\(anchor)-\(latestPlan.id.uuidString)",
                    title: "Meal prep is locked. Checkout needs your go-ahead.",
                    body: "Cart, store, and groceries are ready. Give Instacart the final yes so delivery stays on track.",
                    actionURLString: latestInstacartRun.trackingURL?.absoluteString,
                    actionLabel: "Open cart",
                    planID: latestPlan.id,
                    metadata: [
                        "trigger": trigger,
                        "run_id": latestInstacartRun.runId,
                    ]
                )
            } else {
                await emitNotificationEvent(
                    kind: "grocery_cart_ready",
                    dedupeKey: "grocery-cart-ready-\(anchor)-\(latestPlan.id.uuidString)",
                    title: "Groceries are set for this prep",
                    body: "Instacart has the cart lined up and ready for the delivery flow.",
                    actionURLString: latestInstacartRun.trackingURL?.absoluteString,
                    actionLabel: "Open cart",
                    planID: latestPlan.id,
                    metadata: [
                        "trigger": trigger,
                        "run_id": latestInstacartRun.runId,
                    ]
                )
            }
        } else if let latestInstacartRun,
                  latestInstacartRun.normalizedStatusKind == "partial" || latestInstacartRun.normalizedStatusKind == "failed" {
            await emitInstacartIssueNotification(
                title: "Instacart still has loose ends",
                body: latestInstacartRun.topIssue ?? "A few grocery matches are still syncing before delivery is fully set.",
                dedupeSuffix: "\(anchor)-\(latestInstacartRun.runId)"
            )
        }
    }

    private func emitMealPrepReadyNotification(plan: MealPlan) async {
        guard let profile else { return }
        let nextDelivery = profile.scheduledDeliveryDate()
        let body = "Meals, servings, and grocery plan are lined up for \(nextDelivery.formatted(.dateTime.weekday(.wide).month(.wide).day()))."
        await emitNotificationEvent(
            kind: "meal_prep_ready",
            dedupeKey: "meal-prep-ready-\(plan.id.uuidString)",
            title: "Your next prep is ready",
            body: body,
            planID: plan.id,
            metadata: [
                "recipe_count": "\(plan.recipes.count)",
            ]
        )
    }

    private func emitInstacartIssueNotification(title: String, body: String, dedupeSuffix: String) async {
        await emitNotificationEvent(
            kind: "grocery_issue",
            dedupeKey: "grocery-issue-\(dedupeSuffix)",
            title: title,
            body: body
        )
    }

    private func emitEngagementNudgesIfNeeded() async {
        guard let profile,
              let session = await freshUserDataSession()
        else {
            return
        }

        let weekKey = ISO8601DateFormatter().string(from: Calendar.current.dateInterval(of: .weekOfYear, for: .now)?.start ?? .now)
        let savedTitles = await resolvedSavedRecipeTitles()

        if let savedTitle = savedTitles.first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            await emitNotificationEvent(
                kind: "recipe_nudge",
                dedupeKey: "saved-recipe-nudge-\(session.userID)-\(weekKey)",
                title: "You saved \(savedTitle) this week",
                body: "Bring it into your next prep if you want something familiar in the rotation.",
                metadata: [
                    "source": "saved_recipe",
                    "preferred_name": profile.trimmedPreferredName ?? "",
                ]
            )
        }

        let trendingRecipes = (try? await SupabaseDiscoverRecipeService.shared.fetchRecipes(limit: 12)) ?? []
        if let trending = trendingRecipes.first,
           !savedTitles.contains(where: { $0.caseInsensitiveCompare(trending.title) == .orderedSame }) {
            await emitNotificationEvent(
                kind: "trending_recipe_nudge",
                dedupeKey: "trending-recipe-nudge-\(session.userID)-\(weekKey)",
                title: "Try something new",
                body: trending.title,
                imageURLString: trending.imageURL?.absoluteString,
                recipeID: trending.id,
                metadata: [
                    "source": "discover_trending",
                ]
            )
        }
    }

    private func emitNotificationEvent(
        kind: String,
        dedupeKey: String,
        title: String,
        body: String,
        subtitle: String? = nil,
        imageURLString: String? = nil,
        actionURLString: String? = nil,
        actionLabel: String? = nil,
        orderID: UUID? = nil,
        planID: UUID? = nil,
        recipeID: String? = nil,
        metadata: [String: String] = [:],
        scheduledFor: Date = .now
    ) async {
        guard let session = await freshUserDataSession() else {
            return
        }
        do {
            try await SupabaseAppNotificationEventService.shared.createEvent(
                userID: session.userID,
                accessToken: session.accessToken,
                kind: kind,
                dedupeKey: dedupeKey,
                title: title,
                body: body,
                subtitle: subtitle,
                imageURLString: imageURLString,
                actionURLString: actionURLString,
                actionLabel: actionLabel,
                orderID: orderID,
                planID: planID,
                recipeID: recipeID,
                metadata: metadata,
                scheduledFor: scheduledFor
            )
        } catch {
            return
        }
    }

    private func persistAutomationGenerationCheckpoint(plan: MealPlan, reason: String) async {
        guard let profile else { return }
        let nextDelivery = profile.scheduledDeliveryDate()
        automationState = updatedAutomationState {
            $0.lastGeneratedForDeliveryAt = automationAnchorString(for: nextDelivery)
            $0.lastGeneratedPlanID = plan.id
            $0.lastGeneratedReason = reason
        }
        saveAutomationStateCache()
        persistAutomationStateIfPossible()
    }

    private func updatedAutomationState(_ mutate: (inout MealPrepAutomationState) -> Void) -> MealPrepAutomationState {
        var state = automationState ?? MealPrepAutomationState(
            userID: authSession?.userID ?? "",
            lastEvaluatedAt: nil,
            nextPlanningWindowAt: nil,
            autoshopEnabled: nil,
            autoshopLeadDays: nil,
            nextPrepAt: nil,
            nextCartSyncAt: nil,
            lastCartSyncTrigger: nil,
            lastGeneratedForDeliveryAt: nil,
            lastGeneratedPlanID: nil,
            lastGeneratedReason: nil,
            lastCartSyncForDeliveryAt: nil,
            lastCartSyncPlanID: nil,
            lastCartSignature: nil,
            lastInstacartRunID: nil,
            lastInstacartRunStatus: nil,
            lastInstacartRetryQueuedForRunID: nil,
            lastInstacartRetryQueuedAt: nil
        )
        if state.userID.isEmpty {
            state.userID = authSession?.userID ?? ""
        }
        mutate(&state)
        return state
    }

    private func automationAnchorString(for date: Date) -> String {
        ISO8601DateFormatter().string(from: Calendar.current.startOfDay(for: date))
    }

    private func planningWindowOpenDate(for profile: UserProfile, nextDelivery: Date) -> Date {
        let leadHours: Double
        switch profile.cadence {
        case .daily:
            leadHours = 4
        case .everyFewDays:
            leadHours = 10
        case .twiceWeekly:
            leadHours = 14
        case .weekly:
            leadHours = 24
        case .biweekly:
            leadHours = 40
        case .monthly:
            leadHours = 72
        }
        return nextDelivery.addingTimeInterval(-(leadHours * 60 * 60))
    }

    private func cartSetupWindowOpenDate(for profile: UserProfile, nextDelivery: Date) -> Date {
        let calendar = Calendar.current
        let prepDayStart = calendar.startOfDay(for: nextDelivery)
        return calendar.date(byAdding: .day, value: -profile.autoshopLeadDays, to: prepDayStart) ?? nextDelivery
    }

    private func cartConfirmationWindowOpenDate(for profile: UserProfile, nextDelivery: Date) -> Date {
        let calendar = Calendar.current
        let prepDayStart = calendar.startOfDay(for: nextDelivery)
        guard profile.autoshopLeadDays > 1 else {
            return cartSetupWindowOpenDate(for: profile, nextDelivery: nextDelivery)
        }
        return calendar.date(byAdding: .day, value: -1, to: prepDayStart) ?? nextDelivery
    }

    private func automationCartSignature(for items: [GroceryItem]) -> String {
        items
            .map { item in
                let sourceSignature = item.sourceIngredients
                    .map { source in
                        [
                            source.recipeID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                            source.ingredientName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                            source.unit.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                        ].joined(separator: "::")
                    }
                    .sorted()
                    .joined(separator: "|")

                return [
                    item.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                    String(format: "%.3f", item.amount),
                    item.unit.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                    String(format: "%.2f", item.estimatedPrice),
                    sourceSignature,
                ].joined(separator: "::")
            }
            .sorted()
            .joined(separator: "\n")
    }

    private func isCurrentPlanRun(_ run: InstacartRunLogSummary?) -> Bool {
        guard let run, let latestPlan else { return false }
        return normalizedPlanID(run.mealPlanID) == normalizedPlanID(latestPlan.id.uuidString)
    }

    private func normalizedPlanID(_ value: String?) -> String {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
    }

    private func enqueueCartSyncForLatestPlan(trigger: String, resetSyncedState: Bool) async {
        guard let latestPlan,
              let profile,
              !latestPlan.groceryItems.isEmpty
        else {
            pendingCartSyncIntent = nil
            savePendingCartSyncIntentCache()
            return
        }

        let cartSignature = automationCartSignature(for: latestPlan.groceryItems)
        let deliveryAnchor = automationAnchorString(for: profile.scheduledDeliveryDate())
        pendingCartSyncIntent = PendingCartSyncIntent(
            planID: latestPlan.id,
            cartSignature: cartSignature,
            deliveryAnchor: deliveryAnchor,
            trigger: trigger,
            createdAt: ISO8601DateFormatter().string(from: .now)
        )
        savePendingCartSyncIntentCache()

        if resetSyncedState {
            if let currentRun = latestInstacartRun,
               currentRun.normalizedStatusKind == "running" || currentRun.normalizedStatusKind == "queued" || ["queued", "running"].contains(currentRun.normalizedRetryState) {
                latestBlockingInstacartRun = currentRun
            }
            automationState = updatedAutomationState {
                $0.lastCartSignature = nil
                $0.lastCartSyncPlanID = nil
                $0.lastCartSyncForDeliveryAt = nil
                $0.lastGeneratedReason = trigger
            }
            saveAutomationStateCache()
            persistAutomationStateIfPossible()
            latestInstacartRun = nil
            latestGroceryOrder = nil
        } else if !isCurrentPlanRun(latestInstacartRun) {
            latestInstacartRun = nil
            latestGroceryOrder = nil
        }
    }

    private func clearPendingCartSyncIntentIfMatched(planID: UUID, cartSignature: String, deliveryAnchor: String) {
        guard let intent = pendingCartSyncIntent,
              intent.planID == planID,
              intent.cartSignature == cartSignature,
              intent.deliveryAnchor == deliveryAnchor
        else { return }
        pendingCartSyncIntent = nil
        savePendingCartSyncIntentCache()
    }

    private func saveProfile() {
        guard let profile else { return }
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(profile) else { return }
        UserDefaults.standard.set(data, forKey: profileKey)
    }

    private func saveAuthSession(_ authSession: AuthSession) {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(authSession) else { return }
        cachedLiveUserID = authSession.userID
        let sharedSessionData = try? encoder.encode(SharedAuthSessionRecord(
            userID: authSession.userID,
            accessToken: authSession.accessToken
        ))
        UserDefaults.standard.set(data, forKey: authSessionKey)
        UserDefaults.standard.synchronize()
        sharedDefaults?.set(data, forKey: authSessionKey)
        saveLiveUserID(authSession.userID)
        if let sharedSessionData {
            sharedDefaults?.set(sharedSessionData, forKey: sharedAuthSessionKey)
        }
        sharedDefaults?.synchronize()
        saveAuthSessionToKeychain(data)
    }

    private func saveLiveUserID(_ userID: String) {
        let trimmed = userID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        UserDefaults.standard.set(trimmed, forKey: liveUserIDKey)
        sharedDefaults?.set(trimmed, forKey: liveUserIDKey)
    }

    private func loadLiveUserID() -> String? {
        let sharedValue = sharedDefaults?.string(forKey: liveUserIDKey)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !sharedValue.isEmpty {
            return sharedValue
        }
        let defaultsValue = UserDefaults.standard.string(forKey: liveUserIDKey)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return defaultsValue.isEmpty ? nil : defaultsValue
    }

    private func saveOnboardingState() {
        hasPersistedOnboardingState = true
        UserDefaults.standard.set(isOnboarded, forKey: onboardedKey)
    }

    private func saveOnboardingStep() {
        UserDefaults.standard.set(lastOnboardingStep, forKey: onboardingStepKey)
    }

    private var provisionalAuthenticatedEntryRoute: CachedAuthenticatedEntryRoute? {
        guard isAuthenticated else { return nil }
        if isOnboarded {
            return .planner
        }
        if hasPersistedOnboardingState {
            return .onboarding
        }
        if let cachedAuthenticatedEntryRoute {
            return cachedAuthenticatedEntryRoute
        }
        if latestPlan != nil || !planHistory.isEmpty || automationState != nil {
            return .planner
        }
        return nil
    }

    private func cacheAuthenticatedEntryRoute(_ route: CachedAuthenticatedEntryRoute) {
        cachedAuthenticatedEntryRoute = route
        UserDefaults.standard.set(route.rawValue, forKey: cachedEntryRouteKey)
    }

    func hideMainShopItem(removalKey: String, for planID: UUID?) {
        let normalizedKey = removalKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedKey.isEmpty else { return }
        loadHiddenMainShopItems(for: planID)
        guard let currentPlanID = planID ?? latestPlan?.id else { return }
        hiddenMainShopPlanID = currentPlanID
        hiddenMainShopItemKeys.insert(normalizedKey)
        saveHiddenMainShopItems(for: currentPlanID)

        Task(priority: .utility) {
            guard let session = await self.freshUserDataSession() else { return }
            try? await SupabaseMealPrepCycleService.shared.deleteMainShopItem(
                userID: session.userID,
                planID: currentPlanID,
                removalKey: normalizedKey,
                accessToken: session.accessToken
            )
        }
    }

    func unhideMainShopItem(removalKey: String, for planID: UUID?) {
        let trimmedKey = removalKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedKey = Self.normalizedCartKey(trimmedKey)
        guard !trimmedKey.isEmpty || !normalizedKey.isEmpty else { return }
        loadHiddenMainShopItems(for: planID)
        guard let currentPlanID = planID ?? latestPlan?.id else { return }
        hiddenMainShopPlanID = currentPlanID
        hiddenMainShopItemKeys.remove(trimmedKey)
        hiddenMainShopItemKeys.remove(normalizedKey)
        saveHiddenMainShopItems(for: currentPlanID)

        Task {
            await refreshLatestPlanMainShopSnapshotIfNeeded(forceRebuild: true)
        }
    }

    func markMainShopItemOwned(removalKey: String, for planID: UUID?) {
        let normalizedKey = removalKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedKey.isEmpty else { return }
        hideMainShopItem(removalKey: normalizedKey, for: planID)

        let ownedKey = Self.normalizedCartKey(normalizedKey)
        guard !ownedKey.isEmpty else { return }

        var updatedProfile = profile ?? .starter
        let existingOwnedKeys = Set(updatedProfile.ownedMainShopItems.map(Self.normalizedCartKey))
        if !existingOwnedKeys.contains(ownedKey) {
            updatedProfile.ownedMainShopItems = Self.normalizedUnique(
                updatedProfile.ownedMainShopItems + [normalizedKey]
            )
            profile = updatedProfile
            saveProfile()

            Task(priority: .utility) {
                guard let session = await self.freshUserDataSession() else { return }
                try? await SupabaseProfileStateService.shared.upsertProfile(
                    userID: session.userID,
                    email: session.email,
                    displayName: updatedProfile.trimmedPreferredName ?? session.displayName,
                    authProvider: session.provider,
                    onboarded: isOnboarded,
                    lastOnboardingStep: lastOnboardingStep,
                    profile: updatedProfile,
                    accessToken: session.accessToken
                )
            }
        }

        Task {
            await refreshLatestPlanMainShopSnapshotIfNeeded(forceRebuild: true)
        }
    }

    func unmarkMainShopItemOwned(removalKey: String, for planID: UUID?) {
        let normalizedKey = Self.normalizedCartKey(removalKey)
        guard !normalizedKey.isEmpty else { return }

        var updatedProfile = profile ?? .starter
        updatedProfile.ownedMainShopItems.removeAll {
            Self.matchesOwnedMainShopItem($0, candidate: normalizedKey)
        }
        profile = updatedProfile
        saveProfile()

        Task(priority: .utility) {
            guard let session = await self.freshUserDataSession() else { return }
            try? await SupabaseProfileStateService.shared.upsertProfile(
                userID: session.userID,
                email: session.email,
                displayName: updatedProfile.trimmedPreferredName ?? session.displayName,
                authProvider: session.provider,
                onboarded: isOnboarded,
                lastOnboardingStep: lastOnboardingStep,
                profile: updatedProfile,
                accessToken: session.accessToken
            )
        }

        unhideMainShopItem(removalKey: normalizedKey, for: planID)
    }

    func isOwnedMainShopItem(_ value: String) -> Bool {
        guard let profile else { return false }
        let candidate = Self.normalizedCartKey(value)
        guard !candidate.isEmpty else { return false }

        return profile.ownedMainShopItems.contains { owned in
            Self.matchesOwnedMainShopItem(owned, candidate: candidate)
        }
    }

    func ownedMainShopItemKeys() -> Set<String> {
        Set(
            (profile?.ownedMainShopItems ?? [])
                .map(Self.normalizedCartKey)
                .filter { !$0.isEmpty }
        )
    }

    func mainShopRemovalKey(for itemName: String) -> String {
        Self.normalizedCartKey(itemName)
    }

    private func saveHistory() {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(planHistory) else { return }
        UserDefaults.standard.set(data, forKey: historyStorageKey(for: activeHistoryUserID))
    }

    private func saveCompletedMealPrepCycleCache() {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(completedMealPrepCycles) else { return }
        UserDefaults.standard.set(data, forKey: completedHistoryStorageKey(for: activeHistoryUserID))
    }

    private func saveAutomationStateCache() {
        let encoder = JSONEncoder()
        let key = automationStateStorageKey(for: activeHistoryUserID)
        guard let state = automationState,
              let data = try? encoder.encode(state) else {
            UserDefaults.standard.removeObject(forKey: key)
            return
        }
        UserDefaults.standard.set(data, forKey: key)
    }

    private func savePendingCartSyncIntentCache() {
        let encoder = JSONEncoder()
        let key = pendingCartSyncIntentStorageKey(for: activeHistoryUserID)
        guard let intent = pendingCartSyncIntent,
              let data = try? encoder.encode(intent) else {
            UserDefaults.standard.removeObject(forKey: key)
            return
        }
        UserDefaults.standard.set(data, forKey: key)
    }

    private func savePrepRecipeOverridesCache() {
        let encoder = JSONEncoder()
        let key = prepRecipeOverridesStorageKey(for: activeHistoryUserID)
        let persistedOverrides = prepRecipeOverrides.filter { !$0.recipe.isLegacySeedRecipe }
        guard !persistedOverrides.isEmpty,
              let data = try? encoder.encode(persistedOverrides) else {
            UserDefaults.standard.removeObject(forKey: key)
            return
        }
        UserDefaults.standard.set(data, forKey: key)
    }

    private func saveRecurringPrepRecipesCache() {
        let encoder = JSONEncoder()
        let key = recurringPrepRecipesStorageKey(for: activeHistoryUserID)
        guard !recurringPrepRecipes.isEmpty,
              let data = try? encoder.encode(recurringPrepRecipes) else {
            UserDefaults.standard.removeObject(forKey: key)
            return
        }
        UserDefaults.standard.set(data, forKey: key)
    }

    private func loadHiddenMainShopItems(for planID: UUID?) {
        guard let planID else {
            hiddenMainShopPlanID = nil
            hiddenMainShopItemKeys = []
            return
        }

        if hiddenMainShopPlanID == planID {
            return
        }

        hiddenMainShopPlanID = planID
        let defaults = UserDefaults.standard
        let key = hiddenMainShopStorageKey(for: activeHistoryUserID, planID: planID)
        let data = defaults.data(forKey: key)

        guard
            let data,
            let decoded = try? JSONDecoder().decode([String].self, from: data)
        else {
            hiddenMainShopItemKeys = []
            return
        }

        hiddenMainShopItemKeys = Set(decoded.map(Self.normalizedCartKey))
    }

    private func saveHiddenMainShopItems(for planID: UUID) {
        let encoder = JSONEncoder()
        let key = hiddenMainShopStorageKey(for: activeHistoryUserID, planID: planID)
        let data = try? encoder.encode(Array(hiddenMainShopItemKeys).sorted())
        UserDefaults.standard.set(data, forKey: key)
    }

    private func hiddenMainShopStorageKey(for userID: String?, planID: UUID) -> String {
        "\(hiddenMainShopItemsKeyPrefix)-\(userID ?? "guest")-\(planID.uuidString)"
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

    private static func matchesOwnedMainShopItem(_ ownedValue: String, candidate: String) -> Bool {
        let owned = normalizedCartKey(ownedValue)
        let normalizedCandidate = normalizedCartKey(candidate)
        guard !owned.isEmpty, !normalizedCandidate.isEmpty else { return false }

        if owned == normalizedCandidate {
            return true
        }

        if owned.contains(normalizedCandidate) || normalizedCandidate.contains(owned) {
            return true
        }

        let ownedTokens = Set(owned.split(separator: " ").map(String.init))
        let candidateTokens = Set(normalizedCandidate.split(separator: " ").map(String.init))
        guard !ownedTokens.isEmpty, !candidateTokens.isEmpty else { return false }

        return ownedTokens.isSubset(of: candidateTokens) || candidateTokens.isSubset(of: ownedTokens)
    }

    private func loadCompletedMealPrepCycleCache(for userID: String?) {
        let defaults = UserDefaults.standard
        let primaryKey = completedHistoryStorageKey(for: userID)
        let data = defaults.data(forKey: primaryKey)

        guard let data,
              let decodedCycles = try? JSONDecoder().decode([MealPrepCompletedCycle].self, from: data)
        else {
            completedMealPrepCycles = []
            return
        }

        completedMealPrepCycles = decodedCycles.sorted { $0.sortDate > $1.sortDate }

        if defaults.data(forKey: primaryKey) == nil {
            defaults.set(data, forKey: primaryKey)
        }
    }

    private func loadAutomationStateCache(for userID: String?) {
        let defaults = UserDefaults.standard
        let primaryKey = automationStateStorageKey(for: userID)
        guard let data = defaults.data(forKey: primaryKey),
              let decoded = try? JSONDecoder().decode(MealPrepAutomationState.self, from: data)
        else {
            automationState = nil
            return
        }

        automationState = decoded
    }

    private func loadPendingCartSyncIntentCache(for userID: String?) {
        let defaults = UserDefaults.standard
        let primaryKey = pendingCartSyncIntentStorageKey(for: userID)
        guard let data = defaults.data(forKey: primaryKey),
              let decoded = try? JSONDecoder().decode(PendingCartSyncIntent.self, from: data)
        else {
            pendingCartSyncIntent = nil
            return
        }

        pendingCartSyncIntent = decoded
    }

    private func loadPrepRecipeOverridesCache(for userID: String?) {
        let defaults = UserDefaults.standard
        let primaryKey = prepRecipeOverridesStorageKey(for: userID)
        guard let data = defaults.data(forKey: primaryKey),
              let decoded = try? JSONDecoder().decode([PrepRecipeOverride].self, from: data)
        else {
            prepRecipeOverrides = []
            return
        }

        prepRecipeOverrides = decoded.filter { !$0.recipe.isLegacySeedRecipe }
    }

    private func loadRecurringPrepRecipesCache(for userID: String?) {
        let defaults = UserDefaults.standard
        let primaryKey = recurringPrepRecipesStorageKey(for: userID)
        guard let data = defaults.data(forKey: primaryKey),
              let decoded = try? JSONDecoder().decode([RecurringPrepRecipe].self, from: data)
        else {
            recurringPrepRecipes = []
            return
        }

        recurringPrepRecipes = decoded.sorted { $0.sortDate > $1.sortDate }
    }

    private func historyStorageKey(for userID: String?) -> String {
        "\(historyKeyPrefix)-\(userID ?? "guest")"
    }

    private func completedHistoryStorageKey(for userID: String?) -> String {
        "\(completedHistoryKeyPrefix)-\(userID ?? "guest")"
    }

    private func automationStateStorageKey(for userID: String?) -> String {
        "\(automationStateKeyPrefix)-\(userID ?? "guest")"
    }

    private func pendingCartSyncIntentStorageKey(for userID: String?) -> String {
        "\(pendingCartSyncIntentKeyPrefix)-\(userID ?? "guest")"
    }

    private func prepRecipeOverridesStorageKey(for userID: String?) -> String {
        "\(prepRecipeOverridesKeyPrefix)-\(userID ?? "guest")"
    }

    private func recurringPrepRecipesStorageKey(for userID: String?) -> String {
        "\(recurringPrepRecipesKeyPrefix)-\(userID ?? "guest")"
    }

    private func grocerySourceRefreshFingerprint(for plan: MealPlan?) -> String? {
        guard let plan else { return nil }
        let missingSourceCount = plan.groceryItems.reduce(into: 0) { count, item in
            if item.sourceIngredients.isEmpty {
                count += 1
            }
        }
        guard missingSourceCount > 0 else { return nil }
        return "\(plan.id.uuidString)::\(plan.groceryItems.count)::\(missingSourceCount)"
    }

    private static func normalizedCartKey(_ value: String) -> String {
        value
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression)
            .split(separator: " ")
            .filter { !$0.isEmpty }
            .map(String.init)
            .joined(separator: " ")
    }

    private static func normalizedUnique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var unique: [String] = []

        for value in values {
            let normalized = normalizedCartKey(value)
            guard !normalized.isEmpty, seen.insert(normalized).inserted else { continue }
            unique.append(normalized)
        }

        return unique
    }

    private func loadAuthSessionData() -> Data? {
        if let keychainData = loadAuthSessionFromKeychain() {
            return keychainData
        }

        if let sharedData = sharedDefaults?.data(forKey: sharedAuthSessionKey) {
            return sharedData
        }

        if let defaultsData = UserDefaults.standard.data(forKey: authSessionKey) {
            return defaultsData
        }

        return sharedDefaults?.data(forKey: authSessionKey)
    }

    private func saveAuthSessionToKeychain(_ data: Data) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: authKeychainService,
            kSecAttrAccount as String: authKeychainAccount,
        ]

        SecItemDelete(query as CFDictionary)

        let addQuery: [String: Any] = query.merging([
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]) { _, new in new }

        SecItemAdd(addQuery as CFDictionary, nil)
    }

    private func loadAuthSessionFromKeychain() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: authKeychainService,
            kSecAttrAccount as String: authKeychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    private func deleteAuthSessionFromKeychain() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: authKeychainService,
            kSecAttrAccount as String: authKeychainAccount,
        ]
        SecItemDelete(query as CFDictionary)
    }

    private func shouldPurgePersistedPlan(_ history: [MealPlan]) -> Bool {
        history.contains(where: { plan in
            !isUsablePersistedPlan(plan)
        })
    }

    private func usablePersistedPlans(from history: [MealPlan]) -> [MealPlan] {
        history.filter(isUsablePersistedPlan)
    }

    private func isUsablePersistedPlan(_ plan: MealPlan) -> Bool {
        guard !plan.recipes.isEmpty else { return false }
        return !plan.recipes.contains(where: { recipe in
            recipe.recipe.isLegacySeedRecipe || recipe.recipe.isKnownSampleRecipe
        })
    }

    private func recordCompletedMealPrepCycleIfNeeded(for plan: MealPlan) async {
        guard let session = await freshUserDataSession() else { return }
        guard !completedMealPrepCycles.contains(where: { $0.planID == plan.id }) else { return }

        let completedCycle = MealPrepCompletedCycle(
            id: UUID(),
            userID: session.userID,
            planID: plan.id,
            plan: plan,
            completedAt: ISO8601DateFormatter().string(from: Date())
        )

        completedMealPrepCycles.removeAll { $0.planID == plan.id }
        completedMealPrepCycles.insert(completedCycle, at: 0)
        if completedMealPrepCycles.count > 12 {
            completedMealPrepCycles = Array(completedMealPrepCycles.prefix(12))
        }
        saveCompletedMealPrepCycleCache()

        Task(priority: .utility) {
            try? await SupabaseMealPrepCycleCompletionService.shared.upsertMealPrepCycleCompletion(
                userID: session.userID,
                cycle: completedCycle,
                accessToken: session.accessToken
            )
        }
    }
}

private struct SharedAuthSessionRecord: Codable {
    let userID: String
    let accessToken: String?
}
