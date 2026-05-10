import SwiftUI
import Foundation
import UIKit

actor CartSupportWarmupCache {
    static let shared = CartSupportWarmupCache()

    private struct Entry {
        let planID: UUID
        let signature: String
        let rows: [SupabaseRecipeIngredientRow]
        let warmedAt: Date
    }

    private var entriesByPlanID: [UUID: Entry] = [:]

    func rows(for plan: MealPlan) -> [SupabaseRecipeIngredientRow]? {
        let signature = MainShopSnapshotBuilder.signature(for: plan.groceryItems)
        guard let entry = entriesByPlanID[plan.id],
              entry.signature == signature,
              Date().timeIntervalSince(entry.warmedAt) < 30 * 60 else {
            return nil
        }
        return entry.rows
    }

    func store(rows: [SupabaseRecipeIngredientRow], for plan: MealPlan) {
        guard !rows.isEmpty else { return }
        entriesByPlanID[plan.id] = Entry(
            planID: plan.id,
            signature: MainShopSnapshotBuilder.signature(for: plan.groceryItems),
            rows: rows,
            warmedAt: .now
        )
        if entriesByPlanID.count > 4 {
            let stalePlanIDs = entriesByPlanID
                .values
                .sorted { $0.warmedAt < $1.warmedAt }
                .prefix(entriesByPlanID.count - 4)
                .map(\.planID)
            stalePlanIDs.forEach { entriesByPlanID.removeValue(forKey: $0) }
        }
    }
}

enum CartSupportWarmupService {
    static func prewarmLatestPlanCartSupport(for store: MealPlanningAppStore) async {
        guard await MainActor.run(body: {
            store.isAuthenticated
                && store.isOnboarded
                && !store.isHydratingRemoteState
                && store.latestPlan?.recipes.isEmpty == false
        }) else {
            return
        }

        try? await Task.sleep(nanoseconds: 900_000_000)
        guard !Task.isCancelled else { return }

        guard let plan = await MainActor.run(body: { store.latestPlan }),
              !plan.recipes.isEmpty else {
            return
        }

        if await CartSupportWarmupCache.shared.rows(for: plan) != nil {
            prewarmArtwork(for: plan, rows: [])
            return
        }

        do {
            let rows = try await buildPrepRecipeIngredientRows(from: plan.recipes)
            guard !Task.isCancelled else { return }
            guard let activePlan = await MainActor.run(body: { store.latestPlan }),
                  activePlan.id == plan.id,
                  MainShopSnapshotBuilder.signature(for: activePlan.groceryItems) == MainShopSnapshotBuilder.signature(for: plan.groceryItems) else {
                return
            }
            await CartSupportWarmupCache.shared.store(rows: rows, for: activePlan)
            prewarmArtwork(for: activePlan, rows: rows)
        } catch {
            prewarmArtwork(for: plan, rows: [])
        }
    }

    static func cachedIngredientRows(for plan: MealPlan) async -> [SupabaseRecipeIngredientRow]? {
        await CartSupportWarmupCache.shared.rows(for: plan)
    }

    static func buildPrepRecipeIngredientRows(from recipes: [PlannedRecipe]) async throws -> [SupabaseRecipeIngredientRow] {
        let candidateImageNames = Array(
            Set(
                recipes.flatMap { plannedRecipe in
                    plannedRecipe.recipe.ingredients.map { ingredient in
                        SupabaseIngredientsCatalogService.normalizedName(ingredient.name)
                    }
                }
                .filter { !$0.isEmpty }
            )
        )
        let imageLookup = (try? await SupabaseIngredientsCatalogService.shared.fetchImageLookup(
            normalizedNames: candidateImageNames
        )) ?? [:]
        let indexedRows: [(Int, [SupabaseRecipeIngredientRow])] = recipes.enumerated().map { recipeIndex, plannedRecipe in
            let scale = Double(max(1, plannedRecipe.servings)) / Double(max(1, plannedRecipe.recipe.servings))
            var seenIngredientKeys = Set<String>()
            var recipeRows: [SupabaseRecipeIngredientRow] = []
            for (index, ingredient) in plannedRecipe.recipe.ingredients.enumerated() {
                let normalizedKey = normalizedIngredientKey(ingredient.name)
                guard !normalizedKey.isEmpty, seenIngredientKeys.insert(normalizedKey).inserted else {
                    continue
                }
                let quantityText = CartQuantityFormatter.format(
                    amount: max(ingredient.amount * scale, ingredient.amount > 0 ? 0.0001 : 0),
                    unit: ingredient.unit
                )
                recipeRows.append(
                    SupabaseRecipeIngredientRow(
                        id: "\(plannedRecipe.recipe.id)::local::\(index)",
                        recipeID: plannedRecipe.recipe.id,
                        ingredientID: nil,
                        displayName: ingredient.name,
                        quantityText: quantityText,
                        imageURLString: imageLookup[normalizedKey],
                        sortOrder: ingredient.amount <= 0 ? nil : index
                    )
                )
            }
            return (recipeIndex, recipeRows)
        }

        return indexedRows
            .sorted { $0.0 < $1.0 }
            .flatMap(\.1)
    }

    private static func prewarmArtwork(for plan: MealPlan, rows: [SupabaseRecipeIngredientRow]) {
        let urls = Array(
            Set(
                rows.compactMap(\.imageURL)
                + (plan.mainShopSnapshot?.items ?? []).compactMap { item in
                    guard let value = item.imageURLString?.trimmingCharacters(in: .whitespacesAndNewlines),
                          !value.isEmpty else {
                        return nil
                    }
                    return URL(string: value)
                }
            )
        )
        guard !urls.isEmpty else { return }
        Task { @MainActor in
            CartArtworkImageLoader.prewarm(urls: urls)
        }
    }

    private static func normalizedIngredientKey(_ value: String) -> String {
        value
            .lowercased()
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct CartTabView: View {
    @EnvironmentObject private var store: MealPlanningAppStore
    @EnvironmentObject private var toastCenter: AppToastCenter
    @Environment(\.openURL) private var openURL
    @Binding var selectedTab: AppTab
    @Binding var focusedRecipeID: String?
    @State private var displayMode: CartDisplayMode = .reconciled
    @State private var isRunLogsPresented = false
    @State private var isCartMappingPresented = false
    @State private var ingredientRows: [SupabaseRecipeIngredientRow] = []
    @State private var cartDisplayItems: [CartGroceryDisplayItem] = []
    @State private var reconciledCartItems: [CartGroceryDisplayItem] = []
    @State private var mainShopQuantityOverrides: [String: Int] = [:]
    @State private var boxedCartCoverageSummary: BoxedCartCoverageSummary?
    @State private var isLoadingIngredients = false
    @State private var ingredientLoadError: String?
    @StateObject private var instacartRunLogsStore = InstacartRunLogsStore()
    @State private var collapsedRecipeGroupIDs = Set<String>()

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Cart")
                            .biroHeaderFont(32)
                            .foregroundStyle(OunjePalette.primaryText)
                        Text(cartSummaryLine)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(OunjePalette.secondaryText)
                    }

                    Spacer(minLength: 0)
                }

                    if shouldShowLiveCartContent {
                        CartDisplayModeBar(
                            selection: $displayMode,
                            trailingAction: {
                                handleCartModeTrailingAction()
                            },
                            trailingDisabled: isCartBuyNowModeBarDisabled,
                            trailingContent: {
                                cartModeTrailingContent
                            }
                        )
                        .padding(.top, -12)
                    }

                    if shouldShowEmptyCartState {
                        CartEmptyState(
                            onBrowseDiscover: { selectedTab = .discover }
                        )
                    } else if displayMode == .reconciled && isLoadingIngredients && visibleReconciledCartItems.isEmpty {
                        CartMainShopLoadingState()
                    } else if displayMode != .reconciled && isLoadingIngredients && displayIngredientGroups.isEmpty && visibleCartItems.isEmpty {
                        CartLoadingState()
                    } else {
                        cartDisplayContent
                    }
                }
                .padding(.horizontal, OunjeLayout.screenHorizontalPadding)
                .padding(.top, 14)
                .padding(.bottom, 12)
            }
            .scrollIndicators(.hidden)
        }
        .background(OunjePalette.background.ignoresSafeArea())
        .sheet(isPresented: $isRunLogsPresented) {
            InstacartRunLogsSheet(
                store: instacartRunLogsStore,
                mealStore: store,
                userID: store.resolvedTrackingSession?.userID,
                accessToken: store.resolvedTrackingSession?.accessToken,
                onRerun: {
                    startCartBuyNowRun(trigger: "instacart_runs_rerun")
                }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.hidden)
        }
        .sheet(isPresented: $isCartMappingPresented) {
            CartMainShopMappingSheet(
                entries: cartMainShopMappingEntries,
                totalBaseUses: boxedCartCoverageSummary?.totalBaseUses ?? 0,
                accountedBaseUses: boxedCartCoverageSummary?.accountedBaseUses ?? 0,
                uncoveredBaseLabels: boxedCartCoverageSummary?.uncoveredBaseLabels ?? []
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.hidden)
        }
        .onReceive(NotificationCenter.default.publisher(for: .instacartRunSummaryDidUpdate)) { notification in
            guard let summary = notification.object as? InstacartRunLogSummary else { return }
            instacartRunLogsStore.applyRunSummary(summary)
        }
        .task(id: cartReloadKey) {
            await reloadCartIngredients(forceRebuild: false)
        }
        .task(id: store.resolvedTrackingSession?.userID ?? "signed-out") {
            await store.refreshLiveTrackingState()
        }
    }

    @ViewBuilder
    private var runLogsButtonContent: some View {
        let isShoppingActive = isCartWorkAnimating
        let inactiveIconColor = Color.white.opacity(0.58)
        if instacartRunLogsStore.isLoading {
            liveRunLogsButtonShell(isActive: isShoppingActive, activeChrome: false) {
                ProgressView()
                    .tint(Color.white.opacity(isShoppingActive ? 0.88 : 0.58))
            }
        } else if isShoppingActive {
            liveRunLogsButtonShell(
                isActive: true,
                activeChrome: false,
                pulseScale: 1.0
            ) {
                HoppingCartIcon(
                    isActive: true,
                    color: Color.white.opacity(0.88),
                    size: 17
                )
            }
        } else {
            liveRunLogsButtonShell(isActive: false) {
                HoppingCartIcon(
                    isActive: false,
                    color: inactiveIconColor,
                    size: 15
                )
            }
        }
    }

    @ViewBuilder
    private var cartModeTrailingContent: some View {
        if shouldShowBuyNowInModeBar {
            compactBuyNowButtonContent
        } else {
            runLogsButtonContent
        }
    }

    @ViewBuilder
    private var compactBuyNowButtonContent: some View {
        HStack(spacing: 8) {
            if store.isManualAutoshopRunning || isInstacartShoppingActivelyRunning {
                ProgressView()
                    .controlSize(.small)
                    .tint(OunjePalette.primaryText)
            }

            Text(compactBuyNowButtonTitle)
                .font(.system(size: 13, weight: .bold))
        }
        .foregroundStyle(OunjePalette.primaryText)
        .padding(.horizontal, 14)
        .frame(height: 42)
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(cartBuyNowDisabledReason == nil ? OunjePalette.accent : OunjePalette.surface.opacity(0.92))
                .overlay(
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .stroke(
                            cartBuyNowDisabledReason == nil ? OunjePalette.accent.opacity(0.75) : OunjePalette.stroke,
                            lineWidth: 1
                        )
                )
        )
        .opacity(isCartBuyNowModeBarDisabled ? 0.58 : 1)
    }

    private var compactBuyNowButtonTitle: String {
        if store.isManualAutoshopRunning || isInstacartShoppingActivelyRunning {
            return "Building"
        }
        if cartBuyNowStatusTone == .failed {
            return "Retry"
        }
        return "Buy now"
    }

    private var shouldShowBuyNowInModeBar: Bool {
        displayMode == .reconciled
            && shouldShowLiveCartContent
            && currentInstacartCartURL == nil
    }

    private var isCartBuyNowModeBarDisabled: Bool {
        shouldShowBuyNowInModeBar
            && (cartBuyNowDisabledReason != nil || store.isManualAutoshopRunning || isInstacartShoppingActivelyRunning)
    }

    private func handleCartModeTrailingAction() {
        if shouldShowBuyNowInModeBar {
            guard !isCartBuyNowModeBarDisabled else {
                if let reason = cartBuyNowDisabledReason {
                    toastCenter.show(title: reason, destination: nil)
                }
                return
            }
            startCartBuyNowRun()
            return
        }

        isRunLogsPresented = true
        Task {
            await instacartRunLogsStore.refresh(
                userID: store.resolvedTrackingSession?.userID,
                accessToken: store.resolvedTrackingSession?.accessToken
            )
        }
    }

    private var isCartWorkAnimating: Bool {
        isInstacartShoppingActivelyRunning
            || store.hasLiveInstacartActivity
            || isLoadingIngredients
    }

    private var isInstacartShoppingActivelyRunning: Bool {
        if let run = store.latestInstacartRun {
            if ["queued", "running"].contains(run.normalizedRetryState) {
                return true
            }
            if ["queued", "running"].contains(run.normalizedStatusKind) {
                return true
            }
        }

        if let order = store.latestGroceryOrder {
            let status = order.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if ["checkout_started", "shopping", "out_for_delivery"].contains(status) {
                return true
            }
        }

        return false
    }

    private func liveRunLogsButtonShell<Content: View>(
        isActive: Bool,
        activeChrome: Bool = true,
        pulseScale: CGFloat = 1.0,
        glowOpacity: Double = 0.0,
        ringScale: CGFloat = 1.0,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: 8) {
            ZStack {
                if isActive {
                    if activeChrome {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(OunjePalette.accent.opacity(0.16))
                            .frame(width: 44, height: 44)
                            .scaleEffect(ringScale)
                            .opacity(glowOpacity)
                            .blur(radius: 0.5)
                    }

                    if activeChrome {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(OunjePalette.surface.opacity(0.92))
                            .overlay(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .stroke(OunjePalette.accent.opacity(0.68), lineWidth: 1)
                            )
                            .shadow(color: OunjePalette.accent.opacity(0.42), radius: 16, x: 0, y: 5)
                    }
                } else {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(OunjePalette.surface.opacity(0.84))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(OunjePalette.stroke, lineWidth: 1)
                        )
                }

                content()
            }
            .frame(width: isActive && !activeChrome ? 34 : 46, height: isActive && !activeChrome ? 34 : 46)
            .scaleEffect(isActive ? pulseScale : 1.0)
        }
    }

    private var activeRecipeIDs: [String] {
        (store.latestPlan?.recipes ?? []).map(\.recipe.id)
    }

    private var cartReloadKey: String {
        guard let latestPlan = store.latestPlan else { return "empty-cart" }
        let recipeKey = latestPlan.recipes.map(\.recipe.id).joined(separator: "|")
        let groceryKey = mainShopSignature(for: latestPlan.groceryItems)
        let snapshotKey = latestPlan.mainShopSnapshot.map { snapshot in
            "\(snapshot.signature)::\(snapshot.generatedAt.timeIntervalSince1970)"
        } ?? "no-snapshot"
        return [recipeKey, groceryKey, snapshotKey].joined(separator: "::")
    }

    private var shouldShowEmptyCartState: Bool {
        activeRecipeIDs.isEmpty && displayGroceryItems.isEmpty && visibleReconciledCartItems.isEmpty
    }

    private var shouldShowLiveCartContent: Bool {
        !shouldShowEmptyCartState
    }

    private var cartSummaryLine: String {
        if displayMode == .reconciled, !visibleReconciledCartItems.isEmpty {
            let itemLabel = visibleReconciledCartItems.count == 1 ? "shop item" : "shop items"
            if let boxedCartCoverageSummary, !boxedCartCoverageSummary.isFullyAccountedFor {
                let uncoveredCount = boxedCartCoverageSummary.actionableUncoveredBaseLabels.count
                return "\(visibleReconciledCartItems.count) \(itemLabel) ready • \(uncoveredCount) unmatched"
            }
            return "\(visibleReconciledCartItems.count) \(itemLabel) ready"
        }

        let recipeCount = displayIngredientGroups.count
        let ingredientCount = displayMode == .grid
            ? allIngredientCards.count
            : displayIngredientGroups.reduce(0) { $0 + $1.ingredients.count }
        if recipeCount > 0 || ingredientCount > 0 {
            let recipeLabel = recipeCount == 1 ? "recipe" : "recipes"
            let ingredientLabel = ingredientCount == 1 ? "ingredient" : "ingredients"
            return "\(recipeCount) \(recipeLabel) • \(ingredientCount) \(ingredientLabel)"
        }
        return "Next prep ingredients"
    }

    private var displayIngredientGroups: [CartIngredientGroup] {
        guard let latestPlan = store.latestPlan else { return [] }

        return latestPlan.recipes.compactMap { plannedRecipe in
            let sourceRows = ingredientRows
                .filter { $0.recipeID == plannedRecipe.recipe.id }
                .filter { !isHiddenMainShopRelatedItem(named: $0.displayTitle) }

            let fallbackRows = plannedRecipe.recipe.ingredients.enumerated().map { index, ingredient in
                SupabaseRecipeIngredientRow(
                    id: "\(plannedRecipe.recipe.id)::fallback::\(index)",
                    recipeID: plannedRecipe.recipe.id,
                    ingredientID: nil,
                    displayName: ingredient.name,
                    quantityText: CartQuantityFormatter.format(amount: ingredient.amount, unit: ingredient.unit),
                    imageURLString: nil,
                    sortOrder: index
                )
            }
            .filter {
                !isHiddenMainShopRelatedItem(named: $0.displayTitle)
                && !isOwnedMainShopRelatedItem(named: $0.displayTitle)
            }

            let rows = sourceRows.isEmpty ? fallbackRows : sourceRows
            guard !rows.isEmpty else { return nil }

            return CartIngredientGroup(
                recipeID: plannedRecipe.recipe.id,
                recipeTitle: plannedRecipe.recipe.title,
                servings: plannedRecipe.servings,
                cookTimeMinutes: plannedRecipe.recipe.prepMinutes,
                ingredients: rows
            )
            }
    }

    private func isHiddenMainShopRelatedItem(
        named name: String,
        removalKey: String? = nil
    ) -> Bool {
        guard !store.hiddenMainShopItemKeys.isEmpty else { return false }

        let candidateNameKey = Self.normalizedIngredientKey(name)
        let candidateRemovalKey = removalKey.map(Self.normalizedIngredientKey)
        guard !candidateNameKey.isEmpty || (candidateRemovalKey?.isEmpty == false) else { return false }

        return store.hiddenMainShopItemKeys.contains { hiddenKey in
            let normalizedHidden = Self.normalizedIngredientKey(hiddenKey)
            guard !normalizedHidden.isEmpty else { return false }

            if let candidateRemovalKey,
               !candidateRemovalKey.isEmpty,
               normalizedHidden == candidateRemovalKey {
                return true
            }

            if normalizedHidden == candidateNameKey {
                return true
            }

            if normalizedHidden.contains(candidateNameKey), !candidateNameKey.isEmpty, candidateNameKey.count >= 6 {
                return true
            }

            if candidateNameKey.contains(normalizedHidden), !normalizedHidden.isEmpty, normalizedHidden.count >= 6 {
                return true
            }

            return false
        }
    }

    private func isOwnedMainShopRelatedItem(
        named name: String,
        removalKey: String? = nil
    ) -> Bool {
        guard let profile = store.profile, !profile.ownedMainShopItems.isEmpty else { return false }

        let candidateNameKey = Self.normalizedIngredientKey(name)
        let candidateRemovalKey = removalKey.map(Self.normalizedIngredientKey)
        guard !candidateNameKey.isEmpty || (candidateRemovalKey?.isEmpty == false) else { return false }

        return profile.ownedMainShopItems.contains { ownedKey in
            let normalizedOwned = Self.normalizedIngredientKey(ownedKey)
            guard !normalizedOwned.isEmpty else { return false }

            if let candidateRemovalKey,
               !candidateRemovalKey.isEmpty,
               normalizedOwned == candidateRemovalKey {
                return true
            }

            if normalizedOwned == candidateNameKey {
                return true
            }

            if normalizedOwned.contains(candidateNameKey), !candidateNameKey.isEmpty, candidateNameKey.count >= 6 {
                return true
            }

            if candidateNameKey.contains(normalizedOwned), !normalizedOwned.isEmpty, normalizedOwned.count >= 6 {
                return true
            }

            return false
        }
    }

    private var displayGroceryItems: [CartGroceryDisplayItem] {
        cartDisplayItems
    }

    private var visibleCartItems: [CartGroceryDisplayItem] {
        displayMode == .reconciled ? visibleReconciledCartItems : displayGroceryItems
    }

    private var visibleReconciledCartItems: [CartGroceryDisplayItem] {
        guard !store.hiddenMainShopItemKeys.isEmpty else {
            return reconciledCartItems.filter {
                !isOwnedMainShopRelatedItem(named: $0.name, removalKey: $0.removalKey)
            }
        }

        return reconciledCartItems.filter { item in
            !isHiddenMainShopRelatedItem(named: item.name, removalKey: item.removalKey)
            && !isOwnedMainShopRelatedItem(named: item.name, removalKey: item.removalKey)
        }
    }

    private var hasSourceCartContent: Bool {
        !displayIngredientGroups.isEmpty || !displayGroceryItems.isEmpty
    }

    private var hasRenderedCartContent: Bool {
        !ingredientRows.isEmpty || !cartDisplayItems.isEmpty || !reconciledCartItems.isEmpty
    }

    private var allIngredientCards: [SupabaseRecipeIngredientRow] {
        var seen = Set<String>()
        return displayIngredientGroups
            .flatMap(\.ingredients)
            .filter { ingredient in
                guard !isHiddenMainShopRelatedItem(named: ingredient.displayTitle) else { return false }
                guard !isOwnedMainShopRelatedItem(named: ingredient.displayTitle) else { return false }
                let key = Self.normalizedIngredientKey(ingredient.displayName)
                return seen.insert(key).inserted
        }
    }

    @ViewBuilder
    private var cartDisplayContent: some View {
        switch displayMode {
        case .recipes:
            VStack(spacing: 18) {
                ForEach(displayIngredientGroups) { group in
                    CartRecipeListCard(
                        group: group,
                        isCollapsed: collapsedRecipeGroupIDs.contains(group.id),
                        onToggleCollapsed: {
                            withAnimation(OunjeMotion.quickSpring) {
                                if collapsedRecipeGroupIDs.contains(group.id) {
                                    collapsedRecipeGroupIDs.remove(group.id)
                                } else {
                                    collapsedRecipeGroupIDs.insert(group.id)
                                }
                            }
                        }
                    )
                }
            }
        case .grid:
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 18, alignment: .top), count: 4),
                spacing: 24
            ) {
                ForEach(allIngredientCards) { ingredient in
                    CartFlatIngredientTile(ingredient: ingredient)
                }
            }
        case .reconciled:
            VStack(alignment: .leading, spacing: 18) {
                if let ingredientLoadError {
                    CartMainShopRetryState(
                        message: ingredientLoadError,
                        onOpenRuns: {
                            isRunLogsPresented = true
                            Task {
                                await instacartRunLogsStore.refresh(
                                    userID: store.resolvedTrackingSession?.userID,
                                    accessToken: store.resolvedTrackingSession?.accessToken
                                )
                            }
                        }
                    )
                }

                if shouldShowCartUpdatingBanner {
                    CartMainShopUpdatingBanner()
                }

                if let quote = store.latestPlan?.bestQuote, !quote.reviewItems.isEmpty {
                    ProviderCartReviewCard(quote: quote)
                }

                if let boxedCartCoverageSummary, !boxedCartCoverageSummary.isFullyAccountedFor {
                    CartUnmatchedItemsNotice(summary: boxedCartCoverageSummary)
                }

                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("Shop list")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(OunjePalette.primaryText)

                    Spacer(minLength: 0)

                    if displayMode == .reconciled {
                        Button(action: {
                            isCartMappingPresented = true
                        }) {
                            Label("How grouped", systemImage: "square.stack.3d.up")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(OunjePalette.secondaryText)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .background(
                                    Capsule(style: .continuous)
                                        .fill(OunjePalette.surface.opacity(0.9))
                                        .overlay(
                                            Capsule(style: .continuous)
                                                .stroke(OunjePalette.stroke, lineWidth: 1)
                                        )
                                )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Show how this shop list was grouped")
                    }
                }

                if isLoadingIngredients && !visibleReconciledCartItems.isEmpty {
                    CartMainShopLoadingState()
                } else if visibleReconciledCartItems.isEmpty {
                    if isLoadingIngredients || hasRenderedCartContent || hasSourceCartContent {
                        CartMainShopLoadingState()
                    } else {
                        CartMainShopEmptyState()
                    }
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(visibleReconciledCartItems.enumerated()), id: \.element.id) { index, item in
                            let quantityDisplay = mainShopQuantityDisplay(for: item)

                            if shouldShowMainShopDemarcation(
                                beforeIndex: index,
                                in: visibleReconciledCartItems
                            ) {
                                CartMainShopDemarcationRow(kind: item.sectionKind)
                                    .padding(.top, index == 0 ? 0 : 8)
                                    .padding(.bottom, 6)
                            }

                            CartGroceryLineItemRow(
                                item: item,
                                quantityCount: quantityDisplay.count,
                                quantityUnitLabel: quantityDisplay.unitLabel
                            ) {
                                adjustMainShopQuantity(for: item, delta: -1)
                            } onIncreaseQuantity: {
                                adjustMainShopQuantity(for: item, delta: 1)
                            } onRemove: {
                                removeMainShopItem(item)
                            } onMarkOwned: {
                                markMainShopItemOwned(item)
                            }
                            if index < visibleReconciledCartItems.count - 1 {
                                Divider()
                                    .background(OunjePalette.stroke.opacity(0.85))
                                    .padding(.leading, 68)
                                    .padding(.vertical, 3)
                            }
                        }
                    }
                }
            }
        }
    }

    private var shouldShowCartUpdatingBanner: Bool {
        false
    }

    private var cartBuyNowDisabledReason: String? {
        guard let latestPlan = store.latestPlan, !latestPlan.recipes.isEmpty else {
            return "Generate a prep first."
        }
        guard visibleReconciledCartItems.isEmpty == false else {
            return store.isRefreshingMainShopSnapshot || isLoadingIngredients
                ? "Shop list is syncing."
                : "No visible shop items to send."
        }
        guard latestPlan.bestQuote?.provider == .instacart else {
            return "Connect Instacart first."
        }
        if store.isManualAutoshopRunning || isInstacartShoppingActivelyRunning {
            return "Cart build already running."
        }
        return nil
    }

    private var cartBuyNowStatusMessage: String? {
        if store.isManualAutoshopRunning || isInstacartShoppingActivelyRunning {
            return "Building your Instacart cart..."
        }
        if let error = store.manualAutoshopErrorMessage, !error.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return error
        }
        guard let run = store.latestInstacartRun else { return nil }
        switch run.normalizedStatusKind {
        case "queued", "running":
            return "Building your Instacart cart..."
        case "completed":
            if run.unresolvedCount > 0 || run.shortfallCount > 0 || run.partialSuccess {
                return "A few items need review"
            }
            return "Cart ready for review"
        case "partial":
            return "A few items need review"
        case "failed":
            return run.topIssue ?? "Cart build failed. Try again."
        default:
            return nil
        }
    }

    private var cartBuyNowStatusTone: CartBuyNowStatusTone {
        if store.isManualAutoshopRunning || isInstacartShoppingActivelyRunning {
            return .running
        }
        if store.manualAutoshopErrorMessage != nil {
            return .failed
        }
        switch store.latestInstacartRun?.normalizedStatusKind {
        case "queued", "running":
            return .running
        case "completed":
            if (store.latestInstacartRun?.unresolvedCount ?? 0) > 0
                || (store.latestInstacartRun?.shortfallCount ?? 0) > 0
                || store.latestInstacartRun?.partialSuccess == true {
                return .partial
            }
            return .complete
        case "partial":
            return .partial
        case "failed":
            return .failed
        default:
            return .idle
        }
    }

    private var currentInstacartCartURL: URL? {
        if let url = store.latestInstacartRun?.trackingURL {
            return url
        }
        guard let raw = store.latestGroceryOrder?.providerTrackingURLString?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return nil
        }
        return URL(string: raw)
    }

    private var visibleMainShopKeysForAutoshop: Set<String> {
        Set(
            visibleReconciledCartItems.flatMap { item in
                [
                    item.removalKey,
                    item.name,
                ]
                .compactMap { $0 }
                .map(Self.normalizedIngredientKey)
                .filter { !$0.isEmpty }
            }
        )
    }

    private var visibleMainShopQuantityOverridesForAutoshop: [String: Int] {
        visibleReconciledCartItems.reduce(into: [:]) { result, item in
            guard let override = mainShopQuantityOverrides[item.id], override > 0 else { return }
            [
                item.removalKey,
                item.name,
            ]
            .compactMap { $0 }
            .map(Self.normalizedIngredientKey)
            .filter { !$0.isEmpty }
            .forEach { result[$0] = override }
        }
    }

    private func startCartBuyNowRun(trigger: String = "cart_buy_now") {
        let allowedKeys = visibleMainShopKeysForAutoshop
        let quantityOverrides = visibleMainShopQuantityOverridesForAutoshop
        Task {
            await store.startManualAutoshopRun(
                trigger: trigger,
                allowedMainShopItemKeys: allowedKeys,
                quantityOverridesByMainShopKey: quantityOverrides
            )
        }
    }

    private func shouldShowMainShopDemarcation(
        beforeIndex index: Int,
        in items: [CartGroceryDisplayItem]
    ) -> Bool {
        guard index > 0 else {
            return items.first?.sectionKind != .mainShop
        }
        return items[index - 1].sectionKind != items[index].sectionKind
    }

    private func mainShopQuantityDisplay(for item: CartGroceryDisplayItem) -> CartMainShopQuantityDisplay {
        let parsed = CartQuantityFormatter.mainShopDisplayComponents(from: item.quantityText)
        let baseCount = max(1, parsed?.roundedCount ?? 1)
        let override = mainShopQuantityOverrides[item.id]
        let resolvedCount = max(0, override ?? baseCount)
        let resolvedUnit = standardizedMainShopUnitLabel(
            raw: parsed?.unitLabel ?? "items",
            count: resolvedCount
        )
        return CartMainShopQuantityDisplay(
            count: resolvedCount,
            unitLabel: resolvedUnit,
            baseCount: baseCount
        )
    }

    private func standardizedMainShopUnitLabel(raw: String, count: Int) -> String {
        let normalized = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: #"[^a-z0-9 ]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !normalized.isEmpty else {
            return count == 1 ? "item" : "items"
        }

        if normalized.contains("tablespoon") || normalized.contains("tbsp") {
            return "tbsp"
        }
        if normalized.contains("teaspoon") || normalized.contains("tsp") {
            return "tsp"
        }
        if normalized.contains("cup") {
            return count == 1 ? "cup" : "cups"
        }
        if normalized.contains("pound") || normalized == "lb" || normalized == "lbs" {
            return "lb"
        }
        if normalized.contains("ounce") || normalized == "oz" {
            return "oz"
        }
        if normalized.contains("kilogram") || normalized == "kg" {
            return "kg"
        }
        if normalized.contains("gram") || normalized == "g" {
            return "g"
        }

        let canonicalToken = normalized
            .split(separator: " ")
            .first
            .map(String.init) ?? normalized
        return normalizedMainShopUnitLabel(canonicalToken, count: count)
    }

    private func adjustMainShopQuantity(for item: CartGroceryDisplayItem, delta: Int) {
        let display = mainShopQuantityDisplay(for: item)
        let nextValue = display.count + delta

        if nextValue <= 0 {
            _ = withAnimation(OunjeMotion.quickSpring) {
                mainShopQuantityOverrides.removeValue(forKey: item.id)
            }
            removeMainShopItem(item)
            return
        }

        if nextValue == display.baseCount {
            _ = withAnimation(OunjeMotion.quickSpring) {
                mainShopQuantityOverrides.removeValue(forKey: item.id)
            }
        } else {
            withAnimation(OunjeMotion.quickSpring) {
                mainShopQuantityOverrides[item.id] = nextValue
            }
        }
    }

    private func removeMainShopItem(_ item: CartGroceryDisplayItem) {
        guard let planID = store.latestPlan?.id else { return }
        let removalKey = item.removalKey ?? Self.normalizedIngredientKey(item.name)
        withAnimation(OunjeMotion.quickSpring) {
            store.hideMainShopItem(removalKey: removalKey, for: planID)
        }
        toastCenter.show(
            title: "Removed from shop list",
            subtitle: item.name,
            systemImage: "minus.circle.fill",
            destination: nil,
            actionTitle: "Undo",
            action: { [store, toastCenter] in
                store.unhideMainShopItem(removalKey: removalKey, for: planID)
                toastCenter.dismiss()
            }
        )
    }

    private func markMainShopItemOwned(_ item: CartGroceryDisplayItem) {
        guard let planID = store.latestPlan?.id else { return }
        let removalKey = item.removalKey ?? Self.normalizedIngredientKey(item.name)
        withAnimation(OunjeMotion.quickSpring) {
            store.markMainShopItemOwned(removalKey: removalKey, for: planID)
        }
        toastCenter.show(
            title: "Marked as on hand",
            subtitle: item.name,
            systemImage: "checkmark.circle.fill",
            destination: nil,
            actionTitle: "Undo",
            action: { [store, toastCenter] in
                store.unmarkMainShopItemOwned(removalKey: removalKey, for: planID)
                toastCenter.dismiss()
            }
        )
    }

    private var cartMainShopMappingEntries: [CartMainShopMappingEntry] {
        guard let plan = store.latestPlan else { return [] }

        let recipeTitlesByID = Dictionary(
            uniqueKeysWithValues: plan.recipes.map { ($0.recipe.id, $0.recipe.title) }
        )
        let groceryItemsByKey = Dictionary(grouping: plan.groceryItems) { item in
            Self.normalizedIngredientKey(item.name)
        }
        let rowsByRecipeID = Dictionary(grouping: ingredientRows, by: \.recipeID)

        return visibleReconciledCartItems.compactMap { mainShopItem in
            let key = Self.normalizedIngredientKey(mainShopItem.name)
            let exactMatches = groceryItemsByKey[key] ?? []
            let fuzzyMatches = exactMatches.isEmpty
                ? plan.groceryItems.filter { groceryItem in
                    ingredientSimilarityScore(lhs: groceryItem.name, rhs: mainShopItem.name) >= 75
                }
                : []
            let matchedGroceryItems = exactMatches.isEmpty ? fuzzyMatches : exactMatches

            var sourceEntries: [CartMainShopMappingSourceEntry] = []
            var seenSourceKeys = Set<String>()

            for groceryItem in matchedGroceryItems {
                for source in groceryItem.sourceIngredients {
                    let sourceKey = [
                        Self.normalizedIngredientKey(source.recipeID),
                        Self.normalizedIngredientKey(source.ingredientName),
                        source.unit.lowercased()
                    ]
                    .joined(separator: "::")

                    guard seenSourceKeys.insert(sourceKey).inserted else { continue }

                    let sourceRows = rowsByRecipeID[source.recipeID] ?? []
                    let matchedRow = bestMatchingRecipeIngredientRow(
                        for: [source.ingredientName, groceryItem.name, mainShopItem.name],
                        rows: sourceRows
                    )
                    let recipeTitle = recipeTitlesByID[source.recipeID] ?? source.recipeID
                    let displayQuantity = matchedRow?.displayQuantityText
                        ?? CartQuantityFormatter.format(amount: groceryItem.amount, unit: groceryItem.unit)

                    sourceEntries.append(
                        CartMainShopMappingSourceEntry(
                            id: sourceKey,
                            recipeTitle: recipeTitle,
                            ingredientName: source.ingredientName,
                            quantityText: displayQuantity,
                            imageURL: matchedRow?.imageURL
                        )
                    )
                }
            }

            if sourceEntries.isEmpty {
                let fallbackRows = ingredientRows.filter { row in
                    ingredientSimilarityScore(lhs: row.displayTitle, rhs: mainShopItem.name) >= 75
                }

                var seenFallbackIDs = Set<String>()
                for row in fallbackRows {
                    guard seenFallbackIDs.insert(row.id).inserted else { continue }
                    let sourceKey = "fallback::\(row.id)"
                    let recipeTitle = recipeTitlesByID[row.recipeID] ?? row.recipeID
                    sourceEntries.append(
                        CartMainShopMappingSourceEntry(
                            id: sourceKey,
                            recipeTitle: recipeTitle,
                            ingredientName: row.displayTitle,
                            quantityText: row.displayQuantityText ?? mainShopItem.quantityText,
                            imageURL: row.imageURL
                        )
                    )
                }
            }

            return CartMainShopMappingEntry(
                id: mainShopItem.id,
                mainShopItem: mainShopItem,
                sourceEntries: sourceEntries
            )
        }
    }

    private static func normalizedIngredientKey(_ value: String) -> String {
        value
            .lowercased()
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func bestMatchingRecipeIngredientRow(
        for ingredientNames: [String],
        rows: [SupabaseRecipeIngredientRow]
    ) -> SupabaseRecipeIngredientRow? {
        guard !rows.isEmpty else { return nil }

        let normalizedIngredientNames = ingredientNames
            .map(Self.normalizedIngredientKey)
            .filter { !$0.isEmpty }
        guard !normalizedIngredientNames.isEmpty else { return nil }

        if let exactMatch = rows.first(where: { row in
            let key = Self.normalizedIngredientKey(row.displayTitle)
            return normalizedIngredientNames.contains(key)
        }) {
            return exactMatch
        }

        return rows
            .compactMap { row -> (SupabaseRecipeIngredientRow, Int)? in
                let score = ingredientNames.reduce(0) { partialResult, name in
                    max(partialResult, ingredientSimilarityScore(lhs: name, rhs: row.displayTitle))
                } + (row.imageURL == nil ? 0 : 6)
                return score > 0 ? (row, score) : nil
            }
            .sorted { lhs, rhs in
                if lhs.1 == rhs.1 {
                    return (lhs.0.sortOrder ?? .max, lhs.0.id) < (rhs.0.sortOrder ?? .max, rhs.0.id)
                }
                return lhs.1 > rhs.1
            }
            .first?
            .0
    }

    private func ingredientSimilarityScore(lhs: String, rhs: String) -> Int {
        let lhsKey = Self.normalizedIngredientKey(lhs)
        let rhsKey = Self.normalizedIngredientKey(rhs)

        guard !lhsKey.isEmpty, !rhsKey.isEmpty else { return 0 }
        if lhsKey == rhsKey { return 100 }
        if lhsKey.contains(rhsKey) || rhsKey.contains(lhsKey) { return 80 }

        let lhsTokenList = lhsKey.split(separator: " ").map(String.init)
        let rhsTokenList = rhsKey.split(separator: " ").map(String.init)
        let lhsTokens = Set(lhsTokenList)
        let rhsTokens = Set(rhsTokenList)
        let overlap = lhsTokens.intersection(rhsTokens).count
        guard overlap > 0 else { return 0 }

        var score = overlap * 20
        if lhsTokenList.last == rhsTokenList.last {
            score += 25
        }

        return score
    }

    private func buildCartDisplayItems(
        from groceryItems: [GroceryItem],
        ingredientRows: [SupabaseRecipeIngredientRow]
    ) -> [CartGroceryDisplayItem] {
        let rowsByRecipeID = Dictionary(grouping: ingredientRows, by: \.recipeID)

        return groceryItems
            .map { item in
                let matchedRows = item.sourceIngredients.compactMap { source in
                    bestMatchingRecipeIngredientRow(
                        for: [source.ingredientName, item.name],
                        rows: rowsByRecipeID[source.recipeID] ?? []
                    )
                }

                let primaryMatch = matchedRows.first(where: { $0.imageURL != nil }) ?? matchedRows.first
                let displayName = Self.canonicalMainShopDisplayName(
                    resolvedCartDisplayName(itemName: item.name, matchedRows: matchedRows)
                )
                let imageURL = primaryMatch?.imageURL

                return CartGroceryDisplayItem(
                    name: displayName,
                    quantityText: CartQuantityFormatter.format(amount: item.amount, unit: item.unit),
                    supportingText: nil,
                    imageURL: imageURL,
                    estimatedPriceText: nil,
                    estimatedPriceValue: 0,
                    removalKey: Self.normalizedIngredientKey(displayName)
                )
            }
            .sorted { lhs, rhs in
                lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    private func buildReconciledCartDisplayItems(
        from groceryItems: [GroceryItem],
        ingredientRows: [SupabaseRecipeIngredientRow]
    ) -> [CartGroceryDisplayItem] {
        let graph = buildBoxedCartGraph(from: groceryItems, ingredientRows: ingredientRows)
        let entries = graph.nodes.map { aggregate in
            let packaged = reconciledQuantity(
                for: aggregate.displayName,
                amount: aggregate.amount,
                unit: aggregate.unit,
                sourceCount: aggregate.sourceUseCount,
                recipeCount: aggregate.recipeIDs.count,
                isPantryStaple: aggregate.isPantryStaple,
                isOptional: aggregate.isOptional,
                packageRule: aggregate.packageRule
            )

            return (
                aggregate.category,
                CartGroceryDisplayItem(
                    name: aggregate.displayName,
                    quantityText: packaged.quantityText,
                    supportingText: packaged.supportingText,
                    imageURL: aggregate.imageURL,
                    estimatedPriceText: nil,
                    estimatedPriceValue: 0,
                    sectionKind: aggregate.category.sectionKind
                )
            )
        }

        return entries
            .sorted { lhs, rhs in
                if lhs.0.sectionKind.rawValue == rhs.0.sectionKind.rawValue {
                    return lhs.1.name.localizedCaseInsensitiveCompare(rhs.1.name) == .orderedAscending
                }
                return lhs.0.sectionKind.rawValue < rhs.0.sectionKind.rawValue
            }
            .map(\.1)
    }

    private func buildReconciledCartDisplayItems(
        from shoppingSpecItems: [GroceryShoppingSpecResponse.ShoppingSpecItem],
        ingredientRows: [SupabaseRecipeIngredientRow]
    ) -> [CartGroceryDisplayItem] {
        let rowsByRecipeID = Dictionary(grouping: ingredientRows, by: \.recipeID)

        let entries: [(ReconciledShoppingCategory, CartGroceryDisplayItem)] = shoppingSpecItems.compactMap { item -> (ReconciledShoppingCategory, CartGroceryDisplayItem)? in
            let rawItemName = item.shoppingContext?.canonicalName ?? item.canonicalName ?? item.name
            guard !Self.isExcludedMainShopIngredient(rawItemName)
            else { return nil }
            let matchedRows = item.sourceIngredients.compactMap { source in
                bestMatchingRecipeIngredientRow(
                    for: [source.ingredientName, item.canonicalName ?? item.name, item.name],
                    rows: rowsByRecipeID[source.recipeID] ?? []
                )
            }

            let primaryMatch = matchedRows.first(where: { $0.imageURL != nil }) ?? matchedRows.first
            let displayName = Self.canonicalMainShopDisplayName(rawItemName)
            let canonicalKey = item.canonicalKey
                ?? item.shoppingContext?.canonicalKey
                ?? Self.semanticMainShopMergeKey(rawItemName)
            let role = item.shoppingContext?.role ?? "ingredient"
            let isPantryStaple = item.shoppingContext?.isPantryStaple ?? false
            let isOptional = item.shoppingContext?.isOptional ?? false
            let category = reconciledCategory(
                for: displayName,
                role: role,
                isPantryStaple: isPantryStaple,
                isOptional: isOptional,
                combinedContext: [
                    role,
                    item.shoppingContext?.canonicalName,
                    item.shoppingContext?.sourceIngredientNames.joined(separator: " "),
                    item.shoppingContext?.neighborIngredients.joined(separator: " ")
                ]
                .compactMap { $0 }
                .joined(separator: " ")
            )

            let quantityText = CartQuantityFormatter.format(amount: item.amount, unit: item.unit)
            let sourceUseCount = max(
                1,
                Set(item.sourceIngredients.map {
                    "\(Self.normalizedIngredientKey($0.recipeID))::\(Self.normalizedIngredientKey($0.ingredientName))::\($0.unit.lowercased())"
                }).count
            )
            let recipeTitles = Set((item.shoppingContext?.recipeTitles ?? []) + item.sourceRecipes)
            let recipeCount = recipeTitles.count

            var supportingParts: [String] = []
            supportingParts.append(contentsOf: coverageSupportingParts(sourceUseCount: sourceUseCount, recipeCount: recipeCount))
            if isOptional {
                supportingParts.append("Optional")
            }

            return (
                category,
                CartGroceryDisplayItem(
                    name: displayName,
                    quantityText: quantityText,
                    supportingText: supportingParts.isEmpty ? nil : supportingParts.joined(separator: " • "),
                    imageURL: primaryMatch?.imageURL,
                    estimatedPriceText: nil,
                    estimatedPriceValue: 0,
                    sectionKind: category.sectionKind,
                    removalKey: canonicalKey
                )
            )
        }

        return entries
            .sorted { lhs, rhs in
                if lhs.0.sectionKind.rawValue == rhs.0.sectionKind.rawValue {
                    return lhs.1.name.localizedCaseInsensitiveCompare(rhs.1.name) == .orderedAscending
                }
                return lhs.0.sectionKind.rawValue < rhs.0.sectionKind.rawValue
            }
            .map { $0.1 }
    }

    private func makeMainShopSnapshotItems(from items: [CartGroceryDisplayItem]) -> [MainShopSnapshotItem] {
        items.compactMap { item in
            guard !Self.isExcludedMainShopIngredient(item.name) else { return nil }
            return MainShopSnapshotItem(
                name: item.name,
                quantityText: item.quantityText,
                supportingText: item.supportingText,
                imageURLString: item.imageURL?.absoluteString,
                estimatedPriceText: item.estimatedPriceText,
                estimatedPriceValue: item.estimatedPriceValue,
                sectionKindRawValue: item.sectionKind.rawValue,
                removalKey: item.removalKey
            )
        }
    }

    private func makeReconciledCartItems(fromSnapshotItems snapshotItems: [MainShopSnapshotItem]) -> [CartGroceryDisplayItem] {
        let items: [CartGroceryDisplayItem] = snapshotItems.compactMap { item -> CartGroceryDisplayItem? in
            guard !Self.isExcludedMainShopIngredient(item.name) else { return nil }
            return CartGroceryDisplayItem(
                name: item.name,
                quantityText: item.quantityText,
                supportingText: item.supportingText,
                imageURL: item.imageURLString.flatMap(URL.init(string:)),
                estimatedPriceText: item.estimatedPriceText,
                estimatedPriceValue: item.estimatedPriceValue,
                sectionKind: item.sectionKindRawValue.flatMap(ReconciledCartSectionKind.init(rawValue:)) ?? .mainShop,
                removalKey: item.removalKey
            )
        }

        return items.sorted { lhs, rhs in
            if lhs.sectionKind != rhs.sectionKind {
                return lhs.sectionKind.rawValue < rhs.sectionKind.rawValue
            }

            let nameComparison = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
            if nameComparison != .orderedSame {
                return nameComparison == .orderedAscending
            }

            return lhs.quantityText.localizedCaseInsensitiveCompare(rhs.quantityText) == .orderedAscending
        }
    }

    private func mainShopCoverageSummary(from summary: BoxedCartCoverageSummary?) -> MainShopCoverageSummary? {
        guard let summary else { return nil }
        return MainShopCoverageSummary(
            totalBaseUses: summary.totalBaseUses,
            accountedBaseUses: summary.accountedBaseUses,
            uncoveredBaseLabels: summary.uncoveredBaseLabels
        )
    }

    private func makeBoxedCoverageSummary(fromSnapshotSummary summary: MainShopCoverageSummary?) -> BoxedCartCoverageSummary? {
        guard let summary else { return nil }
        return BoxedCartCoverageSummary(
            totalBaseUses: summary.totalBaseUses,
            accountedBaseUses: summary.accountedBaseUses,
            uncoveredBaseLabels: summary.uncoveredBaseLabels
        )
    }

    private func mainShopSignature(for groceryItems: [GroceryItem]) -> String {
        groceryItems
            .map { item in
                let normalizedName = Self.normalizedIngredientKey(item.name)
                let normalizedUnit = item.unit.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let normalizedAmount = String(format: "%.4f", item.amount)
                let sources = item.sourceIngredients
                    .map {
                        [
                            Self.normalizedIngredientKey($0.recipeID),
                            Self.normalizedIngredientKey($0.ingredientName),
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
    }

    private func ensureMainShopCoverage(
        reconciledItems: [CartGroceryDisplayItem],
        from groceryItems: [GroceryItem],
        ingredientRows: [SupabaseRecipeIngredientRow]
    ) -> [CartGroceryDisplayItem] {
        var items = reconciledItems

        for groceryItem in groceryItems {
            guard !Self.isExcludedMainShopIngredient(groceryItem.name)
            else { continue }
            let normalizedBaseName = Self.normalizedIngredientKey(groceryItem.name)
            guard !normalizedBaseName.isEmpty else { continue }

            let representedByItem = isMainShopNameRepresented(groceryItem.name, in: items)
            let representedBySourceName = groceryItem.sourceIngredients.contains { source in
                isMainShopNameRepresented(source.ingredientName, in: items)
            }

            guard !representedByItem, !representedBySourceName else { continue }

            let matchedRows = groceryItem.sourceIngredients.compactMap { source in
                bestMatchingRecipeIngredientRow(
                    for: [source.ingredientName, groceryItem.name],
                    rows: ingredientRows.filter { $0.recipeID == source.recipeID }
                )
            }
            let primaryMatch = matchedRows.first(where: { $0.imageURL != nil }) ?? matchedRows.first
            let displayName = Self.canonicalMainShopDisplayName(
                resolvedCartDisplayName(itemName: groceryItem.name, matchedRows: matchedRows)
            )
            let combinedContext = (
                [groceryItem.name] + groceryItem.sourceIngredients.map(\.ingredientName)
            )
            .joined(separator: " ")
            let category = reconciledCategory(
                displayName: displayName,
                combinedContext: combinedContext,
                isPantryStaple: false,
                isOptional: false
            )

            items.append(
                CartGroceryDisplayItem(
                    name: displayName,
                    quantityText: CartQuantityFormatter.format(amount: groceryItem.amount, unit: groceryItem.unit),
                    supportingText: "Direct from recipe ingredients",
                    imageURL: primaryMatch?.imageURL,
                    estimatedPriceText: nil,
                    estimatedPriceValue: groceryItem.estimatedPrice,
                    sectionKind: category.sectionKind,
                    removalKey: Self.normalizedIngredientKey(displayName)
                )
            )
        }

        // Backfill only genuinely missing ingredients. Canonical-equivalent rows are already covered.
        var seenIngredientKeys = Set<String>()
        for row in ingredientRows {
            guard !Self.isExcludedMainShopIngredient(row.displayTitle)
            else { continue }
            let displayName = Self.canonicalMainShopDisplayName(row.displayTitle)
            let normalizedDisplayName = Self.semanticMainShopMergeKey(displayName)
            guard !normalizedDisplayName.isEmpty else { continue }
            guard seenIngredientKeys.insert(normalizedDisplayName).inserted else { continue }
            guard !isMainShopNameRepresented(displayName, in: items) else { continue }

            let category = reconciledCategory(
                displayName: displayName,
                combinedContext: [
                    displayName,
                    row.displayQuantityText ?? "",
                ]
                .joined(separator: " "),
                isPantryStaple: false,
                isOptional: false
            )

            let quantityText = row.displayQuantityText?.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedQuantityText: String
            if let parsed = CartQuantityFormatter.mainShopDisplayComponents(from: quantityText ?? "") {
                let count = max(1, parsed.roundedCount)
                let unit = standardizedMainShopUnitLabel(raw: parsed.unitLabel, count: count)
                resolvedQuantityText = "\(count) \(unit)"
            } else {
                resolvedQuantityText = "1 item"
            }

            items.append(
                CartGroceryDisplayItem(
                    name: displayName,
                    quantityText: resolvedQuantityText,
                    supportingText: nil,
                    imageURL: row.imageURL,
                    estimatedPriceText: nil,
                    estimatedPriceValue: 0,
                    sectionKind: category.sectionKind,
                    removalKey: Self.semanticMainShopMergeKey(displayName)
                )
            )
        }

        return items.sorted { lhs, rhs in
            if lhs.sectionKind.rawValue == rhs.sectionKind.rawValue {
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
            return lhs.sectionKind.rawValue < rhs.sectionKind.rawValue
        }
    }

    private func isMainShopNameRepresented(
        _ candidateName: String,
        in items: [CartGroceryDisplayItem],
        similarityThreshold: Int = 70
    ) -> Bool {
        let candidateKey = Self.semanticMainShopMergeKey(candidateName)
        guard !candidateKey.isEmpty else { return false }

        return items.contains { item in
            let itemKey = Self.semanticMainShopMergeKey(item.name)
            return itemKey == candidateKey
                || ingredientSimilarityScore(lhs: candidateName, rhs: item.name) >= similarityThreshold
                || ingredientSimilarityScore(
                    lhs: Self.canonicalMainShopDisplayName(candidateName),
                    rhs: Self.canonicalMainShopDisplayName(item.name)
                ) >= similarityThreshold
        }
    }

    private func mergeLexicallyIdenticalMainShopItems(_ items: [CartGroceryDisplayItem]) -> [CartGroceryDisplayItem] {
        struct Aggregate {
            var item: CartGroceryDisplayItem
            var totalCount: Int
            var preferredUnitLabel: String
            var preferredUnitRank: Int
            var supportingParts: Set<String>
        }

        var aggregates: [String: Aggregate] = [:]
        var order: [String] = []

        for item in items {
            guard !Self.isExcludedMainShopIngredient(item.name) else { continue }
            let displayName = Self.canonicalMainShopDisplayName(item.name)
            let key = Self.semanticMainShopMergeKey(displayName)
            guard !key.isEmpty else { continue }

            let parsed = CartQuantityFormatter.mainShopDisplayComponents(from: item.quantityText)
            let count = max(1, parsed?.roundedCount ?? 1)
            let rawUnit = parsed?.unitLabel ?? "items"
            let unitRank = canonicalMainShopUnitRank(rawUnit)
            let supportingParts = splitSupportingText(item.supportingText)

            if var existing = aggregates[key] {
                existing.totalCount += count
                existing.supportingParts.formUnion(supportingParts)
                let preferredItem = preferredMergedMainShopItem(existing.item, item)

                if unitRank > existing.preferredUnitRank {
                    existing.preferredUnitRank = unitRank
                    existing.preferredUnitLabel = normalizedMainShopUnitLabel(rawUnit, count: existing.totalCount)
                } else {
                    existing.preferredUnitLabel = normalizedMainShopUnitLabel(existing.preferredUnitLabel, count: existing.totalCount)
                }

                let chosenImage = preferredItem.imageURL ?? existing.item.imageURL ?? item.imageURL
                let chosenSection = preferredItem.sectionKind.rawValue < existing.item.sectionKind.rawValue
                    ? preferredItem.sectionKind
                    : existing.item.sectionKind

                existing.item = CartGroceryDisplayItem(
                    name: Self.canonicalMainShopDisplayName(preferredItem.name),
                    quantityText: "\(existing.totalCount) \(existing.preferredUnitLabel)",
                    supportingText: combinedSupportingText(from: existing.supportingParts),
                    imageURL: chosenImage,
                    estimatedPriceText: preferredItem.estimatedPriceText ?? existing.item.estimatedPriceText ?? item.estimatedPriceText,
                    estimatedPriceValue: existing.item.estimatedPriceValue + item.estimatedPriceValue,
                    sectionKind: chosenSection,
                    removalKey: preferredItem.removalKey ?? existing.item.removalKey ?? item.removalKey ?? key
                )
                aggregates[key] = existing
            } else {
                let normalizedUnit = normalizedMainShopUnitLabel(rawUnit, count: count)
                aggregates[key] = Aggregate(
                    item: CartGroceryDisplayItem(
                        name: displayName,
                        quantityText: "\(count) \(normalizedUnit)",
                        supportingText: combinedSupportingText(from: supportingParts),
                        imageURL: item.imageURL,
                        estimatedPriceText: item.estimatedPriceText,
                        estimatedPriceValue: item.estimatedPriceValue,
                        sectionKind: item.sectionKind,
                        removalKey: key
                    ),
                    totalCount: count,
                    preferredUnitLabel: normalizedUnit,
                    preferredUnitRank: unitRank,
                    supportingParts: supportingParts
                )
                order.append(key)
            }
        }

        return order
            .compactMap { aggregates[$0]?.item }
            .sorted { lhs, rhs in
                if lhs.sectionKind.rawValue == rhs.sectionKind.rawValue {
                    return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                }
                return lhs.sectionKind.rawValue < rhs.sectionKind.rawValue
            }
    }

    private func incrementalMainShopItemsFromSnapshot(
        snapshotItems: [MainShopSnapshotItem],
        groceryItems: [GroceryItem],
        ingredientRows: [SupabaseRecipeIngredientRow]
    ) -> [CartGroceryDisplayItem] {
        let existingItems = mergeLexicallyIdenticalMainShopItems(
            makeReconciledCartItems(fromSnapshotItems: snapshotItems)
        )

        var derivedItems = buildReconciledCartDisplayItems(
            from: groceryItems,
            ingredientRows: ingredientRows
        )
        derivedItems = ensureMainShopCoverage(
            reconciledItems: derivedItems,
            from: groceryItems,
            ingredientRows: ingredientRows
        )
        derivedItems = mergeLexicallyIdenticalMainShopItems(derivedItems)

        let existingByKey = Dictionary(
            uniqueKeysWithValues: existingItems.map { (Self.normalizedIngredientKey($0.name), $0) }
        )

        let incrementallyUpdated = derivedItems.map { derived in
            let key = Self.normalizedIngredientKey(derived.name)
            guard let existing = existingByKey[key] else {
                return derived
            }

            let chosenImage = derived.imageURL ?? existing.imageURL
            let mergedSupporting = combinedSupportingText(
                from: splitSupportingText(existing.supportingText).union(splitSupportingText(derived.supportingText))
            )

            return CartGroceryDisplayItem(
                name: derived.name,
                quantityText: derived.quantityText,
                supportingText: mergedSupporting,
                imageURL: chosenImage,
                estimatedPriceText: derived.estimatedPriceText ?? existing.estimatedPriceText,
                estimatedPriceValue: max(derived.estimatedPriceValue, existing.estimatedPriceValue),
                sectionKind: derived.sectionKind,
                removalKey: derived.removalKey ?? existing.removalKey ?? key
            )
        }

        return incrementallyUpdated
            .sorted { lhs, rhs in
                if lhs.sectionKind.rawValue == rhs.sectionKind.rawValue {
                    return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                }
                return lhs.sectionKind.rawValue < rhs.sectionKind.rawValue
            }
    }

    private func splitSupportingText(_ value: String?) -> Set<String> {
        guard let value else { return [] }
        let parts = value
            .split(separator: "•")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter {
                !$0.isEmpty
                && $0.caseInsensitiveCompare("Pantry check") != .orderedSame
            }
        return Set(parts)
    }

    private func combinedSupportingText(from parts: Set<String>) -> String? {
        guard !parts.isEmpty else { return nil }
        return parts
            .sorted { lhs, rhs in
                lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
            }
            .joined(separator: " • ")
    }

    private func canonicalMainShopUnitRank(_ rawLabel: String) -> Int {
        let normalized = rawLabel.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return 0 }

        if normalized.contains(",")
            || normalized.contains(" to ")
            || normalized.hasPrefix("to ")
            || normalized.contains("optional")
            || normalized.contains("taste")
            || normalized.contains("peeled")
            || normalized.contains("chopped")
            || normalized.contains("diced")
            || normalized.contains("sliced")
            || normalized.contains("halved")
            || normalized.split(separator: " ").count >= 4 {
            return 2
        }

        let weightUnits: Set<String> = ["lb", "lbs", "kg", "g", "oz", "ounce", "ounces"]
        let packageUnits: Set<String> = [
            "item", "items",
            "bottle", "bottles",
            "jar", "jars",
            "can", "cans",
            "bag", "bags",
            "pack", "packs",
            "head", "heads",
            "bunch", "bunches",
            "carton", "cartons",
            "tub", "tubs",
            "clove", "cloves"
        ]
        let cookingUnits: Set<String> = [
            "tbsp", "tablespoon", "tablespoons",
            "tsp", "teaspoon", "teaspoons",
            "cup", "cups",
            "ml", "l"
        ]

        if weightUnits.contains(normalized) { return 90 }
        if packageUnits.contains(normalized) { return 70 }
        if cookingUnits.contains(normalized) { return 30 }
        return 40
    }

    private func normalizedMainShopUnitLabel(_ rawLabel: String, count: Int) -> String {
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

    private func packageRule(
        for ingredientName: String,
        unit: String,
        category: ReconciledShoppingCategory
    ) -> ReconciledPackageRule? {
        let normalizedName = Self.normalizedIngredientKey(ingredientName)

        if normalizedName.contains("egg") {
            return ReconciledPackageRule(packageSize: 12, singularLabel: "carton", pluralLabel: "cartons")
        }
        if normalizedName.contains("rice") {
            return ReconciledPackageRule(packageSize: 4, singularLabel: "bag", pluralLabel: "bags")
        }
        if normalizedName.contains("flour") || normalizedName.contains("sugar") {
            return ReconciledPackageRule(packageSize: 3, singularLabel: "bag", pluralLabel: "bags")
        }
        if normalizedName.contains("milk")
            || normalizedName.contains("cream")
            || normalizedName.contains("broth")
            || normalizedName.contains("stock") {
            return ReconciledPackageRule(packageSize: 1, singularLabel: "carton", pluralLabel: "cartons")
        }
        if normalizedName.contains("yogurt") {
            return ReconciledPackageRule(packageSize: 1, singularLabel: "tub", pluralLabel: "tubs")
        }
        if normalizedName.contains("cheese") {
            return ReconciledPackageRule(packageSize: 1, singularLabel: "pack", pluralLabel: "packs")
        }
        if normalizedName.contains("seasoning")
            || normalizedName.contains("pepper")
            || normalizedName.contains("cinnamon")
            || normalizedName.contains("baking powder")
            || normalizedName.contains("bouillon")
            || normalizedName.contains("curry powder")
            || normalizedName.contains("paprika") {
            return ReconciledPackageRule(packageSize: 1, singularLabel: "jar", pluralLabel: "jars")
        }
        if normalizedName.contains("dressing")
            || normalizedName.contains("sauce")
            || normalizedName.contains("juice") {
            return ReconciledPackageRule(packageSize: 1, singularLabel: "bottle", pluralLabel: "bottles")
        }
        if normalizedName.contains("beans") || normalizedName.contains("tomatoes") {
            return ReconciledPackageRule(packageSize: 1, singularLabel: "can", pluralLabel: "cans")
        }
        if normalizedName.contains("chips") {
            return ReconciledPackageRule(packageSize: 1, singularLabel: "bag", pluralLabel: "bags")
        }
        if normalizedName.contains("cilantro")
            || normalizedName.contains("parsley")
            || normalizedName.contains("green onions")
            || normalizedName.contains("scallions") {
            return ReconciledPackageRule(packageSize: 1, singularLabel: "bunch", pluralLabel: "bunches")
        }
        if normalizedName.contains("romaine")
            || normalizedName.contains("lettuce")
            || normalizedName.contains("greens") {
            return ReconciledPackageRule(packageSize: 1, singularLabel: "head", pluralLabel: "heads")
        }
        if category == .tool {
            return ReconciledPackageRule(packageSize: 1, singularLabel: "pack", pluralLabel: "packs")
        }
        if ["lb", "lbs", "kg"].contains(unit.lowercased()) {
            return ReconciledPackageRule(packageSize: 2, singularLabel: "pack", pluralLabel: "packs")
        }
        return nil
    }

    private func reconciledCategory(
        displayName: String,
        combinedContext: String,
        isPantryStaple: Bool,
        isOptional: Bool
    ) -> ReconciledShoppingCategory {
        let normalizedName = Self.normalizedIngredientKey(displayName)
        if isOptional { return .optional }
        if isPantryStaple { return .pantry }
        if combinedContext.contains("sauce")
            || combinedContext.contains("dressing")
            || combinedContext.contains("marinade")
            || combinedContext.contains("dip") {
            return .prepared
        }
        if normalizedName.contains("skewer") || normalizedName.contains("toothpick") {
            return .tool
        }
        if normalizedName.contains("chicken")
            || normalizedName.contains("shrimp")
            || normalizedName.contains("salmon")
            || normalizedName.contains("steak")
            || normalizedName.contains("egg") {
            return .protein
        }
        if normalizedName.contains("cheese")
            || normalizedName.contains("yogurt")
            || normalizedName.contains("milk")
            || normalizedName.contains("cream") {
            return .dairy
        }
        if normalizedName.contains("rice")
            || normalizedName.contains("flour")
            || normalizedName.contains("sugar")
            || normalizedName.contains("chips")
            || normalizedName.contains("beans")
            || normalizedName.contains("stock")
            || normalizedName.contains("broth") {
            return .dryGoods
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
            return .produce
        }
        return .main
    }

    private func reconciledCategory(
        for displayName: String,
        role: String,
        isPantryStaple: Bool,
        isOptional: Bool,
        combinedContext: String
    ) -> ReconciledShoppingCategory {
        if isOptional { return .optional }
        if isPantryStaple { return .pantry }

        switch role.lowercased() {
        case "protein":
            return .protein
        case "dairy":
            return .dairy
        case "sauce":
            return .prepared
        case "wrapper", "pantry":
            return .dryGoods
        case "fresh garnish", "salad base":
            return .produce
        case "cooking tool":
            return .tool
        default:
            return reconciledCategory(
                displayName: displayName,
                combinedContext: combinedContext,
                isPantryStaple: isPantryStaple,
                isOptional: isOptional
            )
        }
    }

    private func prettyShoppingName(_ rawName: String) -> String {
        Self.prettifiedShoppingName(rawName)
    }

    private func buildBoxedCartGraph(
        from groceryItems: [GroceryItem],
        ingredientRows: [SupabaseRecipeIngredientRow]
    ) -> BoxedCartGraph {
        let rowsByRecipeID = Dictionary(grouping: ingredientRows, by: \.recipeID)
        var nodesByKey: [String: BoxedCartNode] = [:]
        var totalDemandIDs = Set<String>()
        var coveredDemandIDs = Set<String>()
        var uncoveredBaseLabels: [String] = []

        for item in groceryItems {
            guard !Self.isExcludedMainShopIngredient(item.name)
            else { continue }
            let matchedRows = item.sourceIngredients.compactMap { source in
                bestMatchingRecipeIngredientRow(
                    for: [source.ingredientName, item.name],
                    rows: rowsByRecipeID[source.recipeID] ?? []
                )
            }
            let primaryMatch = matchedRows.first(where: { $0.imageURL != nil }) ?? matchedRows.first
            let displayName = resolvedCartDisplayName(itemName: item.name, matchedRows: matchedRows)
            let sourceEdges = item.sourceIngredients.map {
                BoxedCartSourceEdge(recipeID: $0.recipeID, ingredientName: $0.ingredientName, unit: $0.unit)
            }
            let demandIDs = baseDemandIdentifiers(for: item, sourceEdges: sourceEdges)
            totalDemandIDs.formUnion(demandIDs)

            let components = deconstructedBoxedComponents(
                for: item,
                displayName: displayName,
                imageURL: primaryMatch?.imageURL,
                sourceEdges: sourceEdges,
                demandIDs: demandIDs
            )

            guard !components.isEmpty else {
                uncoveredBaseLabels.append(item.name)
                continue
            }

            coveredDemandIDs.formUnion(demandIDs)

            for component in components {
                let key = Self.normalizedIngredientKey(component.displayName)
                guard !key.isEmpty else { continue }

                if var existing = nodesByKey[key] {
                    let mergedBaseNames = existing.baseItemNames.union(component.baseItemNames)
                    let mergedPantry = existing.isPantryStaple || component.isPantryStaple
                    let mergedOptional = existing.isOptional && component.isOptional
                    let mergedContext = mergedBaseNames
                        .map(Self.normalizedIngredientKey)
                        .joined(separator: " ")
                    existing.amount += component.amount
                    if existing.imageURL == nil {
                        existing.imageURL = component.imageURL
                    }
                    existing.baseItemNames = mergedBaseNames
                    existing.sourceEdges.formUnion(component.sourceEdges)
                    existing.recipeIDs.formUnion(component.recipeIDs)
                    existing.demandIDs.formUnion(component.demandIDs)
                    existing.isPantryStaple = mergedPantry
                    existing.isOptional = mergedOptional
                    existing.category = reconciledCategory(
                        displayName: existing.displayName,
                        combinedContext: mergedContext,
                        isPantryStaple: mergedPantry,
                        isOptional: mergedOptional
                    )
                    existing.packageRule = packageRule(
                        for: existing.displayName,
                        unit: existing.unit,
                        category: existing.category
                    )
                    nodesByKey[key] = existing
                } else {
                    nodesByKey[key] = component
                }
            }
        }

        return BoxedCartGraph(
            nodes: Array(nodesByKey.values),
            coverageSummary: BoxedCartCoverageSummary(
                totalBaseUses: totalDemandIDs.count,
                accountedBaseUses: coveredDemandIDs.count,
                uncoveredBaseLabels: uncoveredBaseLabels
            )
        )
    }

    private func baseDemandIdentifiers(
        for item: GroceryItem,
        sourceEdges: [BoxedCartSourceEdge]
    ) -> Set<String> {
        let identifiers = sourceEdges.map {
            "\(Self.normalizedIngredientKey($0.recipeID))::\(Self.normalizedIngredientKey($0.ingredientName))::\($0.unit.lowercased())"
        }
        if identifiers.isEmpty {
            return ["fallback::\(item.id)::\(CartQuantityFormatter.format(amount: item.amount, unit: item.unit))"]
        }
        return Set(identifiers)
    }

    private func deconstructedBoxedComponents(
        for item: GroceryItem,
        displayName: String,
        imageURL: URL?,
        sourceEdges: [BoxedCartSourceEdge],
        demandIDs: Set<String>
    ) -> [BoxedCartNode] {
        let normalizedDisplayName = Self.normalizedIngredientKey(displayName)
        if Self.isExcludedMainShopIngredient(normalizedDisplayName) {
            return []
        }
        let normalizedSourceNames = sourceEdges
            .map(\.ingredientName)
            .map(Self.normalizedIngredientKey)
        let combinedContext = ([normalizedDisplayName] + normalizedSourceNames)
            .joined(separator: " ")
        let recipeIDs = Set(sourceEdges.map(\.recipeID))
        let baseItemNames = Set([displayName, item.name])
        let optional = combinedContext.contains("optional")
        let pantryStaple = [
            "salt",
            "black pepper",
            "olive oil",
            "garlic powder",
            "onion powder",
            "paprika",
            "cinnamon",
            "baking powder",
            "bouillon powder",
            "curry powder",
        ].contains(where: { combinedContext.contains($0) || normalizedDisplayName.contains($0) })

        func component(
            name: String,
            amount: Double = item.amount,
            unit: String = item.unit,
            imageURL: URL? = imageURL,
            isPantryStaple: Bool = false,
            isOptional: Bool = false,
            category: ReconciledShoppingCategory? = nil
        ) -> BoxedCartNode {
            let resolvedName = prettyShoppingName(name)
            let resolvedCategory = category ?? reconciledCategory(
                displayName: resolvedName,
                combinedContext: combinedContext,
                isPantryStaple: isPantryStaple,
                isOptional: isOptional
            )
            return BoxedCartNode(
                displayName: resolvedName,
                amount: amount,
                unit: unit,
                imageURL: imageURL,
                baseItemNames: baseItemNames,
                sourceEdges: Set(sourceEdges),
                recipeIDs: recipeIDs,
                demandIDs: demandIDs,
                isPantryStaple: isPantryStaple,
                isOptional: isOptional,
                category: resolvedCategory,
                packageRule: packageRule(for: resolvedName, unit: unit, category: resolvedCategory)
            )
        }

        if combinedContext.contains("buffalo chicken") {
            let primaryChickenName = combinedContext.contains("thigh") ? "Chicken Thighs" : "Chicken Breast"
            return [
                component(name: primaryChickenName, category: .protein),
                component(name: "Buffalo Sauce", amount: 1, unit: "bottle", imageURL: nil, category: .prepared)
            ]
        }

        let canonicalDisplayName = Self.canonicalMainShopDisplayName(displayName)
        return [component(name: canonicalDisplayName, isPantryStaple: pantryStaple, isOptional: optional)]
    }

    private func reconciledQuantity(
        for ingredientName: String,
        amount: Double,
        unit: String,
        sourceCount: Int,
        recipeCount: Int,
        isPantryStaple: Bool,
        isOptional: Bool,
        packageRule: ReconciledPackageRule?
    ) -> (quantityText: String, supportingText: String?) {
        let supportingParts = {
            var parts: [String] = []
            parts.append(contentsOf: coverageSupportingParts(sourceUseCount: sourceCount, recipeCount: recipeCount))
            if isOptional {
                parts.append("Optional")
            }
            return parts
        }()
        let supportingText = supportingParts.isEmpty ? nil : supportingParts.joined(separator: " • ")

        guard let rule = packageRule else {
            return (CartQuantityFormatter.format(amount: amount, unit: unit), supportingText)
        }

        let packageCount = max(1, Int(ceil(amount / rule.packageSize)))
        let label = packageCount == 1 ? rule.singularLabel : rule.pluralLabel
        return ("\(packageCount) \(label)", supportingText)
    }

    private func resolvedCartDisplayName(
        itemName: String,
        matchedRows: [SupabaseRecipeIngredientRow]
    ) -> String {
        let trimmedItemName = itemName.trimmingCharacters(in: .whitespacesAndNewlines)
        let matchedTitles = matchedRows
            .map(\.displayTitle)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard let richestTitle = matchedTitles.max(by: { lhs, rhs in
            let lhsScore = ingredientDisplayScore(lhs)
            let rhsScore = ingredientDisplayScore(rhs)
            if lhsScore == rhsScore {
                return lhs.count < rhs.count
            }
            return lhsScore < rhsScore
        }) else {
            return trimmedItemName
        }

        return ingredientDisplayScore(richestTitle) >= ingredientDisplayScore(trimmedItemName)
            ? richestTitle
            : trimmedItemName
    }

    private func ingredientDisplayScore(_ name: String) -> Int {
        let normalized = Self.normalizedIngredientKey(name)
        guard !normalized.isEmpty else { return 0 }

        let tokenCount = normalized.split(separator: " ").count
        let abbreviationPenalty = normalized.count <= 3 ? 50 : 0
        return tokenCount * 20 + normalized.count - abbreviationPenalty
    }

    private func coverageSupportingParts(sourceUseCount: Int, recipeCount: Int) -> [String] {
        switch (sourceUseCount > 1, recipeCount > 1) {
        case (_, true):
            return ["Used in \(recipeCount) recipes"]
        case (true, false):
            return ["Used \(sourceUseCount)x in this prep"]
        case (false, false):
            return []
        }
    }

    private static func isExcludedMainShopIngredient(_ value: String) -> Bool {
        false
    }

    private static func semanticMainShopMergeKey(_ value: String) -> String {
        let normalized = normalizedIngredientKey(canonicalMainShopDisplayName(value))
        guard !normalized.isEmpty else { return "" }
        let tokens = normalized
            .split(separator: " ")
            .map { normalizedMainShopToken(String($0)) }
            .filter { !$0.isEmpty }
        let key = tokens.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return key.isEmpty ? normalized : key
    }

    private static func canonicalMainShopDisplayName(_ rawName: String) -> String {
        let normalized = normalizedIngredientKey(rawName)
        guard !normalized.isEmpty else { return prettifiedShoppingName(rawName) }

        let tokens = normalized
            .split(separator: " ")
            .map { normalizedMainShopToken(String($0)) }
            .filter { !$0.isEmpty }
        let canonical = tokens.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return prettifiedShoppingName(canonical.isEmpty ? normalized : canonical)
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

    private static func prettifiedShoppingName(_ rawName: String) -> String {
        rawName
            .split(separator: " ")
            .map { token in
                let lowered = token.lowercased()
                return ["bbq", "caesar"].contains(lowered) ? lowered.uppercased() : lowered.capitalized
            }
            .joined(separator: " ")
    }

    private func preferredMergedMainShopItem(_ lhs: CartGroceryDisplayItem, _ rhs: CartGroceryDisplayItem) -> CartGroceryDisplayItem {
        let lhsScore = ingredientDisplayScore(lhs.name)
        let rhsScore = ingredientDisplayScore(rhs.name)
        if lhsScore == rhsScore {
            return lhs.name.count >= rhs.name.count ? lhs : rhs
        }
        return lhsScore >= rhsScore ? lhs : rhs
    }

    private func reloadCartIngredients(
        forceRebuild: Bool = false,
        allowSnapshotFastPath: Bool = true
    ) async {
        guard let latestPlan = store.latestPlan, !latestPlan.recipes.isEmpty else {
            ingredientRows = []
            ingredientLoadError = nil
            cartDisplayItems = []
            reconciledCartItems = []
            boxedCartCoverageSummary = nil
            focusedRecipeID = nil
            return
        }

        let hasMainShopItems = !latestPlan.groceryItems.isEmpty
        let signature = mainShopSignature(for: latestPlan.groceryItems)
        let snapshot = latestPlan.mainShopSnapshot
        let canRenderStoredSnapshotImmediately = allowSnapshotFastPath
            && !forceRebuild
            && hasMainShopItems
            && snapshot?.signature == signature
            && snapshot?.items.allSatisfy({ $0.sectionKindRawValue != nil }) == true

        if canRenderStoredSnapshotImmediately, let snapshot {
            ingredientLoadError = nil
            reconciledCartItems = mergeLexicallyIdenticalMainShopItems(
                makeReconciledCartItems(fromSnapshotItems: snapshot.items)
            )
            boxedCartCoverageSummary = makeBoxedCoverageSummary(fromSnapshotSummary: snapshot.coverageSummary)
            focusedRecipeID = nil
            prewarmCartArtwork(rows: [], cartItems: cartDisplayItems, reconciledItems: reconciledCartItems)
        }

        let canRenderMainShopFallbackImmediately = hasMainShopItems && !canRenderStoredSnapshotImmediately
        if canRenderMainShopFallbackImmediately {
            let fallbackCartItems = buildCartDisplayItems(from: latestPlan.groceryItems, ingredientRows: [])
            cartDisplayItems = fallbackCartItems
            reconciledCartItems = mergeLexicallyIdenticalMainShopItems(
                ensureMainShopCoverage(
                    reconciledItems: buildReconciledCartDisplayItems(
                        from: latestPlan.groceryItems,
                        ingredientRows: []
                    ),
                    from: latestPlan.groceryItems,
                    ingredientRows: []
                )
            )
            boxedCartCoverageSummary = nil
            focusedRecipeID = nil
            prewarmCartArtwork(rows: [], cartItems: fallbackCartItems, reconciledItems: reconciledCartItems)
        }

        let preserveVisibleContent = hasRenderedCartContent
        let shouldBlockForLoad = !canRenderStoredSnapshotImmediately
            && !canRenderMainShopFallbackImmediately
            && !preserveVisibleContent
        isLoadingIngredients = shouldBlockForLoad
        ingredientLoadError = nil
        if !preserveVisibleContent {
            ingredientRows = []
            if !canRenderMainShopFallbackImmediately {
                cartDisplayItems = []
            }
            if !canRenderStoredSnapshotImmediately && !canRenderMainShopFallbackImmediately {
                reconciledCartItems = []
                boxedCartCoverageSummary = nil
            }
        }
        focusedRecipeID = nil
        defer { isLoadingIngredients = false }

        do {
            if forceRebuild {
                _ = await store.refreshLatestPlanMainShopSnapshotIfNeeded(forceRebuild: true)
                guard !Task.isCancelled else { return }
            }

            let rows = try await cachedOrLoadedPrepRecipeIngredientRows(from: latestPlan)
            guard !Task.isCancelled else { return }
            guard let activePlan = store.latestPlan,
                  activePlan.id == latestPlan.id,
                  mainShopSignature(for: activePlan.groceryItems) == signature else {
                return
            }
            ingredientRows = rows
            cartDisplayItems = buildCartDisplayItems(
                from: activePlan.groceryItems,
                ingredientRows: rows
            )
            let canRenderStoredSnapshot = allowSnapshotFastPath
                && !forceRebuild
                && hasMainShopItems
                && snapshot?.signature == signature
                && snapshot?.items.allSatisfy({ $0.sectionKindRawValue != nil }) == true

            guard hasMainShopItems else {
                ingredientLoadError = nil
                reconciledCartItems = mergeLexicallyIdenticalMainShopItems(
                    ensureMainShopCoverage(
                        reconciledItems: [],
                        from: [],
                        ingredientRows: rows
                    )
                )
                boxedCartCoverageSummary = nil
                focusedRecipeID = nil
                prewarmCartArtwork(
                    rows: rows,
                    cartItems: cartDisplayItems,
                    reconciledItems: reconciledCartItems
                )
                return
            }

            if canRenderStoredSnapshot, let snapshot {
                ingredientLoadError = nil
                reconciledCartItems = incrementalMainShopItemsFromSnapshot(
                    snapshotItems: snapshot.items,
                    groceryItems: activePlan.groceryItems,
                    ingredientRows: rows
                )
                boxedCartCoverageSummary = makeBoxedCoverageSummary(fromSnapshotSummary: snapshot.coverageSummary)
                focusedRecipeID = nil
                prewarmCartArtwork(
                    rows: rows,
                    cartItems: cartDisplayItems,
                    reconciledItems: reconciledCartItems
                )

                if let currentPlan = store.latestPlan, currentPlan.id == latestPlan.id,
                   let resolvedSnapshot = currentPlan.mainShopSnapshot {
                    reconciledCartItems = incrementalMainShopItemsFromSnapshot(
                        snapshotItems: resolvedSnapshot.items,
                        groceryItems: currentPlan.groceryItems,
                        ingredientRows: rows
                    )
                    boxedCartCoverageSummary = makeBoxedCoverageSummary(fromSnapshotSummary: resolvedSnapshot.coverageSummary)
                }

                warmCartIngredientSupportData(for: latestPlan)
                return
            }

            guard !Task.isCancelled else { return }

            guard let currentPlan = store.latestPlan, currentPlan.id == latestPlan.id,
                  let resolvedSnapshot = currentPlan.mainShopSnapshot,
                  resolvedSnapshot.signature == signature else {
                ingredientLoadError = nil
                let fallbackItems = mergeLexicallyIdenticalMainShopItems(
                    ensureMainShopCoverage(
                        reconciledItems: buildReconciledCartDisplayItems(
                            from: activePlan.groceryItems,
                            ingredientRows: rows
                        ),
                        from: activePlan.groceryItems,
                        ingredientRows: rows
                    )
                )
                if !fallbackItems.isEmpty {
                    reconciledCartItems = fallbackItems
                } else if !preserveVisibleContent && !canRenderStoredSnapshotImmediately {
                    reconciledCartItems = []
                    boxedCartCoverageSummary = nil
                }
                return
            }

            ingredientLoadError = nil
            reconciledCartItems = incrementalMainShopItemsFromSnapshot(
                snapshotItems: resolvedSnapshot.items,
                groceryItems: currentPlan.groceryItems,
                ingredientRows: rows
            )
            boxedCartCoverageSummary = makeBoxedCoverageSummary(fromSnapshotSummary: resolvedSnapshot.coverageSummary)
            prewarmCartArtwork(
                rows: rows,
                cartItems: cartDisplayItems,
                reconciledItems: reconciledCartItems
            )
        } catch {
            if !preserveVisibleContent {
                ingredientLoadError = nil
                ingredientRows = []
                if !canRenderMainShopFallbackImmediately {
                    cartDisplayItems = []
                }
                if !canRenderStoredSnapshotImmediately && !canRenderMainShopFallbackImmediately {
                    reconciledCartItems = []
                    boxedCartCoverageSummary = nil
                }
            } else {
                ingredientLoadError = nil
            }
        }
    }

    private func warmCartIngredientSupportData(for latestPlan: MealPlan) {
        Task(priority: .utility) {
            do {
                let rows = try await cachedOrLoadedPrepRecipeIngredientRows(from: latestPlan)
                await MainActor.run {
                    guard store.latestPlan?.id == latestPlan.id else { return }
                    ingredientRows = rows
                    let refreshedCartItems = buildCartDisplayItems(
                        from: latestPlan.groceryItems,
                        ingredientRows: rows
                    )
                    cartDisplayItems = refreshedCartItems
                    prewarmCartArtwork(
                        rows: rows,
                        cartItems: refreshedCartItems,
                        reconciledItems: reconciledCartItems
                    )
                }
            } catch {
                // Keep the stored snapshot visible even if support hydration fails.
            }
        }
    }

    private func prewarmCartArtwork(
        rows: [SupabaseRecipeIngredientRow],
        cartItems: [CartGroceryDisplayItem],
        reconciledItems: [CartGroceryDisplayItem]
    ) {
        let urls = Array(
            Set(
                rows.compactMap(\.imageURL) +
                cartItems.compactMap(\.imageURL) +
                reconciledItems.compactMap(\.imageURL)
            )
        )
        guard !urls.isEmpty else { return }
        CartArtworkImageLoader.prewarm(urls: urls)
    }

    private func buildPrepRecipeIngredientRows(from recipes: [PlannedRecipe]) async throws -> [SupabaseRecipeIngredientRow] {
        try await CartSupportWarmupService.buildPrepRecipeIngredientRows(from: recipes)
    }

    private func cachedOrLoadedPrepRecipeIngredientRows(from plan: MealPlan) async throws -> [SupabaseRecipeIngredientRow] {
        if let cachedRows = await CartSupportWarmupService.cachedIngredientRows(for: plan) {
            return cachedRows
        }
        let rows = try await buildPrepRecipeIngredientRows(from: plan.recipes)
        await CartSupportWarmupCache.shared.store(rows: rows, for: plan)
        return rows
    }
}

struct CartGroceryDisplayItem: Identifiable, Hashable {
    var id: String { "\(sectionKind.rawValue)::\(name.lowercased())::\(quantityText)::\(supportingText ?? "")" }
    let name: String
    let quantityText: String
    let supportingText: String?
    let imageURL: URL?
    let estimatedPriceText: String?
    let estimatedPriceValue: Double
    var sectionKind: ReconciledCartSectionKind = .mainShop
    var removalKey: String? = nil
}

struct CartMainShopQuantityDisplay {
    let count: Int
    let unitLabel: String
    let baseCount: Int
}

struct BoxedCartSourceEdge: Hashable {
    let recipeID: String
    let ingredientName: String
    let unit: String
}

struct BoxedCartNode: Hashable {
    let displayName: String
    var amount: Double
    var unit: String
    var imageURL: URL?
    var baseItemNames: Set<String>
    var sourceEdges: Set<BoxedCartSourceEdge>
    var recipeIDs: Set<String>
    var demandIDs: Set<String>
    var isPantryStaple: Bool
    var isOptional: Bool
    var category: ReconciledShoppingCategory
    var packageRule: ReconciledPackageRule?

    var sourceUseCount: Int {
        max(1, demandIDs.count)
    }
}

struct BoxedCartCoverageSummary: Hashable {
    let totalBaseUses: Int
    let accountedBaseUses: Int
    let uncoveredBaseLabels: [String]

    private static let ignorableCoverageLabels: Set<String> = [
        "water",
        "ice",
        "salt",
        "pepper",
        "black pepper",
        "olive oil",
        "oil"
    ]

    var actionableUncoveredBaseLabels: [String] {
        uncoveredBaseLabels.filter { label in
            let normalized = label
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            return !normalized.isEmpty && !Self.ignorableCoverageLabels.contains(normalized)
        }
    }

    var isFullyAccountedFor: Bool {
        actionableUncoveredBaseLabels.isEmpty
    }
}

struct BoxedCartGraph: Hashable {
    let nodes: [BoxedCartNode]
    let coverageSummary: BoxedCartCoverageSummary
}

struct ReconciledPackageRule: Hashable {
    let packageSize: Double
    let singularLabel: String
    let pluralLabel: String
}

enum ReconciledShoppingCategory: String, Hashable {
    case main
    case protein
    case produce
    case dairy
    case dryGoods
    case prepared
    case pantry
    case optional
    case tool

    var sectionKind: ReconciledCartSectionKind {
        switch self {
        case .protein, .produce, .dairy, .main:
            return .mainShop
        case .dryGoods:
            return .dryGoods
        case .prepared:
            return .prepared
        case .pantry:
            return .pantry
        case .optional:
            return .optional
        case .tool:
            return .tools
        }
    }
}

enum ReconciledCartSectionKind: Int, CaseIterable, Identifiable {
    case mainShop
    case dryGoods
    case prepared
    case pantry
    case optional
    case tools

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .mainShop: return "Shop list"
        case .dryGoods: return "Dry goods"
        case .prepared: return "Sauces & prepared"
        case .pantry: return "Pantry check"
        case .optional: return "Optional extras"
        case .tools: return "Kitchen extras"
        }
    }

    var subtitle: String? {
        switch self {
        case .mainShop:
            return nil
        case .dryGoods:
            return "Shelf-stable staples grouped into real units."
        case .prepared:
            return "Sauces, dressings, and ready-made parts."
        case .pantry:
            return "Check these at home before you buy again."
        case .optional:
            return "Nice-to-haves that should not block the batch."
        case .tools:
            return "Non-ingredient kitchen extras."
        }
    }
}

struct ReconciledCartSection: Identifiable, Hashable {
    let kind: ReconciledCartSectionKind
    let items: [CartGroceryDisplayItem]

    var id: ReconciledCartSectionKind { kind }
    var title: String { kind.title }
    var subtitle: String? { kind.subtitle }
}

struct CartUnmatchedItemsNotice: View {
    let summary: BoxedCartCoverageSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Some items could not be matched.")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(OunjePalette.primaryText)

            if summary.actionableUncoveredBaseLabels.isEmpty {
                Text("Your shop list is still ready. Ounje kept the unmatched items separate for now.")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(OunjePalette.secondaryText)
            } else {
                Text(summary.actionableUncoveredBaseLabels.prefix(3).joined(separator: ", "))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(OunjePalette.secondaryText)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 4)
    }
}

struct CartMainShopDemarcationRow: View {
    let kind: ReconciledCartSectionKind

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(kind.title)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(OunjePalette.primaryText.opacity(0.95))
            Rectangle()
                .fill(OunjePalette.stroke.opacity(0.8))
                .frame(height: 1)
        }
        .padding(.horizontal, 2)
    }
}

struct CartEmptyState: View {
    let onBrowseDiscover: () -> Void

    var body: some View {
        VStack(spacing: 22) {
            MotionEmptyIllustration(
                assetName: "CartEmptyIllustrationLight",
                height: 158,
                maxWidth: 236
            )
                .padding(.top, 8)

            VStack(spacing: 8) {
                BiroScriptDisplayText(
                    "Nothing in cart",
                    size: 28,
                    color: OunjePalette.primaryText
                )

                Text("Browse recipes and saved meals will build the ingredient shelves here.")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(OunjePalette.secondaryText)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: 290)

            Button(action: onBrowseDiscover) {
                Text("Browse Discover")
                    .font(.system(size: 14, weight: .bold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(SecondaryPillButtonStyle())
            .frame(maxWidth: 248)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 12)
        .padding(.vertical, 28)
    }
}

struct CartLoadingState: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 12) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(OunjePalette.surface.opacity(0.95))
                    .frame(width: 148, height: 18)
                    .redacted(reason: .placeholder)

                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(OunjePalette.surface.opacity(0.9))
                    .frame(height: 168)
                    .redacted(reason: .placeholder)
            }

            VStack(alignment: .leading, spacing: 12) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(OunjePalette.surface.opacity(0.95))
                    .frame(width: 174, height: 18)
                    .redacted(reason: .placeholder)

                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(OunjePalette.surface.opacity(0.9))
                    .frame(height: 124)
                    .redacted(reason: .placeholder)
            }
        }
    }
}

struct CartMainShopRetryState: View {
    let message: String
    let onOpenRuns: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.orange)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Ounje is updating your cart")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(OunjePalette.primaryText)

                    Text(message)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(OunjePalette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Button(action: onOpenRuns) {
                Text("View cart activity")
                    .font(.system(size: 14, weight: .bold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(PrimaryPillButtonStyle())
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(OunjePalette.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(OunjePalette.stroke, lineWidth: 1)
                )
        )
    }
}

struct CartMainShopUpdatingBanner: View {
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 12) {
            ProgressView()
                .controlSize(.small)
                .tint(OunjePalette.softCream)

            VStack(alignment: .leading, spacing: 3) {
                Text("Updating shop list")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(OunjePalette.primaryText)
                Text("Fresh prep ingredients are being grouped.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(OunjePalette.secondaryText)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(OunjePalette.surface.opacity(pulse ? 0.98 : 0.9))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(OunjePalette.accent.opacity(pulse ? 0.34 : 0.18), lineWidth: 1)
                )
        )
        .onAppear {
            withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }
}

enum CartBuyNowStatusTone {
    case idle
    case running
    case complete
    case partial
    case failed
}

struct CartMainShopMappingSheet: View {
    let entries: [CartMainShopMappingEntry]
    let totalBaseUses: Int
    let accountedBaseUses: Int
    let uncoveredBaseLabels: [String]

    @Environment(\.dismiss) private var dismiss

    private var actionableUncoveredBaseLabels: [String] {
        uncoveredBaseLabels.filter { label in
            let normalized = label
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            return !["water", "ice", "salt", "pepper", "black pepper", "olive oil", "oil"].contains(normalized)
        }
    }

    private var representedSourceCount: Int {
        entries.reduce(into: 0) { partial, entry in
            partial += entry.sourceEntries.count
        }
    }

    private var resolvedTotalBaseUses: Int {
        max(totalBaseUses, representedSourceCount)
    }

    private var resolvedAccountedBaseUses: Int {
        min(resolvedTotalBaseUses, max(accountedBaseUses, representedSourceCount))
    }

    private var summaryLine: String {
        let uncoveredCount = actionableUncoveredBaseLabels.count

        if uncoveredCount > 0 {
            return "\(entries.count) shop rows • \(representedSourceCount) recipe links • \(uncoveredCount) unmatched"
        }
        return "\(entries.count) shop rows • \(representedSourceCount) recipe links"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("How this was grouped")
                            .font(.system(size: 26, weight: .bold))
                            .foregroundStyle(OunjePalette.primaryText)

                        Text("See which recipe ingredients became each shop item.")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(OunjePalette.secondaryText)

                        Text(summaryLine)
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(OunjePalette.secondaryText.opacity(0.85))
                    }

                    if resolvedTotalBaseUses > 0 {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Grouped items")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(OunjePalette.secondaryText)
                            Text("\(resolvedAccountedBaseUses) of \(resolvedTotalBaseUses) ingredient uses are in the shop list")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(OunjePalette.primaryText)
                        }
                        .padding(14)
                        .background(
                            RoundedRectangle(cornerRadius: 20, style: .continuous)
                                .fill(OunjePalette.surface)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                                        .stroke(OunjePalette.stroke, lineWidth: 1)
                                )
                        )
                    }

                    if !actionableUncoveredBaseLabels.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Could not match")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(OunjePalette.secondaryText)
                            Text(actionableUncoveredBaseLabels.prefix(6).joined(separator: " • "))
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(OunjePalette.secondaryText.opacity(0.85))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(14)
                        .background(
                            RoundedRectangle(cornerRadius: 20, style: .continuous)
                                .fill(OunjePalette.surface)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                                        .stroke(OunjePalette.stroke, lineWidth: 1)
                                )
                        )
                    }

                    if entries.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Nothing grouped yet")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundStyle(OunjePalette.primaryText)
                            Text("Once a shop list is ready, grouping details will show here.")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(OunjePalette.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(18)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 22, style: .continuous)
                                .fill(OunjePalette.surface)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                                        .stroke(OunjePalette.stroke, lineWidth: 1)
                                )
                        )
                    } else {
                        VStack(spacing: 14) {
                            ForEach(entries) { entry in
                                CartMainShopMappingEntryCard(entry: entry)
                            }
                        }
                    }
                }
                .padding(.horizontal, OunjeLayout.screenHorizontalPadding)
                .padding(.top, 12)
                .padding(.bottom, 24)
            }
            .background(OunjePalette.background.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

struct CartMainShopMappingEntryCard: View {
    let entry: CartMainShopMappingEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(entry.mainShopItem.imageURL == nil ? OunjePalette.panel : OunjePalette.surface)
                        .frame(width: 52, height: 52)

                    if entry.mainShopItem.imageURL != nil {
                        CartCachedArtworkView(imageURL: entry.mainShopItem.imageURL) {
                            Text(IngredientMonogramFormatter.monogram(for: entry.mainShopItem.name))
                                .sleeDisplayFont(16)
                                .foregroundStyle(OunjePalette.softCream)
                        }
                        .frame(width: 52, height: 52)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    } else {
                        Text(IngredientMonogramFormatter.monogram(for: entry.mainShopItem.name))
                            .sleeDisplayFont(16)
                            .foregroundStyle(OunjePalette.softCream)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.mainShopItem.name)
                        .biroHeaderFont(18)
                        .foregroundStyle(OunjePalette.primaryText)
                        .lineLimit(2)

                    Text(entry.mainShopItem.quantityText)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(OunjePalette.secondaryText)
                }

                Spacer(minLength: 0)

                if let supportingText = entry.mainShopItem.supportingText, !supportingText.isEmpty {
                    Text(supportingText)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(OunjePalette.secondaryText.opacity(0.78))
                        .multilineTextAlignment(.trailing)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Used by")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(OunjePalette.secondaryText)

                if entry.sourceEntries.isEmpty {
                    Text("No recipe links found for this shop item.")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(OunjePalette.secondaryText.opacity(0.78))
                } else {
                    VStack(spacing: 10) {
                        ForEach(Array(entry.sourceEntries.enumerated()), id: \.element.id) { index, source in
                            CartMainShopMappingSourceRow(source: source)

                            if index < entry.sourceEntries.count - 1 {
                                Divider()
                                    .overlay(OunjePalette.stroke.opacity(0.65))
                                    .padding(.leading, 58)
                            }
                        }
                    }
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(OunjePalette.panel.opacity(0.98))
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(OunjePalette.stroke.opacity(0.78), lineWidth: 1)
                )
        )
    }
}

struct CartMainShopMappingSourceRow: View {
    let source: CartMainShopMappingSourceEntry

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(source.imageURL == nil ? OunjePalette.panel : OunjePalette.elevated)
                    .frame(width: 46, height: 46)

                if source.imageURL != nil {
                    CartCachedArtworkView(imageURL: source.imageURL) {
                        Text(IngredientMonogramFormatter.monogram(for: source.ingredientName))
                            .sleeDisplayFont(14)
                            .foregroundStyle(OunjePalette.softCream)
                    }
                    .frame(width: 46, height: 46)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                } else {
                    Text(IngredientMonogramFormatter.monogram(for: source.ingredientName))
                        .sleeDisplayFont(14)
                        .foregroundStyle(OunjePalette.softCream)
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(source.recipeTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(OunjePalette.primaryText)
                    .lineLimit(1)

                Text(source.ingredientName)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(OunjePalette.secondaryText)
                    .lineLimit(2)

                if let quantityText = source.quantityText, !quantityText.isEmpty {
                    Text(quantityText)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(OunjePalette.secondaryText.opacity(0.82))
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(OunjePalette.background.opacity(0.58))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(OunjePalette.stroke.opacity(0.56), lineWidth: 1)
                )
        )
    }
}

struct CartMainShopLoadingState: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(OunjePalette.surface.opacity(0.95))
                .frame(width: 164, height: 18)
                .redacted(reason: .placeholder)

            ForEach(0..<4, id: \.self) { _ in
                HStack(spacing: 14) {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(OunjePalette.surface.opacity(0.9))
                        .frame(width: 62, height: 62)
                        .redacted(reason: .placeholder)

                    VStack(alignment: .leading, spacing: 7) {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(OunjePalette.surface.opacity(0.95))
                            .frame(width: 132, height: 15)
                            .redacted(reason: .placeholder)

                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(OunjePalette.surface.opacity(0.9))
                            .frame(width: 88, height: 11)
                            .redacted(reason: .placeholder)

                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(OunjePalette.surface.opacity(0.84))
                            .frame(width: 160, height: 11)
                            .redacted(reason: .placeholder)
                    }

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(OunjePalette.surface.opacity(0.95))
                        .overlay(
                            RoundedRectangle(cornerRadius: 20, style: .continuous)
                                .stroke(OunjePalette.stroke, lineWidth: 1)
                        )
                )
            }
        }
    }
}

struct CartMainShopEmptyState: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            MotionEmptyIllustration(
                assetName: "CartEmptyIllustrationLight",
                height: 96,
                alignment: .leading
            )

            HStack(spacing: 10) {
                Image(systemName: "tray")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(OunjePalette.secondaryText)

                Text("No shop list yet")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(OunjePalette.primaryText)
            }

            Text("Once prep has ingredients, Ounje will group them into a simple shop list.")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(OunjePalette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(OunjePalette.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(OunjePalette.stroke, lineWidth: 1)
                )
        )
    }
}

struct CookbookSectionTabItem: Identifiable {
    let section: CookbookSection

    var id: CookbookSection { section }
}

struct CookbookSectionTabs: View {
    @Binding var selection: CookbookSection
    let tabs: [CookbookSectionTabItem]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(tabs) { tab in
                let isSelected = selection == tab.section

                VStack(spacing: 8) {
                    Text(tab.section.title)
                        .font(.system(size: isSelected ? 16 : 15, weight: isSelected ? .bold : .semibold))
                        .foregroundStyle(isSelected ? OunjePalette.primaryText : OunjePalette.secondaryText.opacity(0.94))
                        .opacity(isSelected ? 1 : 0.76)

                    Capsule(style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    OunjePalette.softCream.opacity(0.95),
                                    OunjePalette.accent.opacity(0.72)
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: isSelected ? 72 : 24, height: isSelected ? 3 : 1.5)
                        .opacity(isSelected ? 1 : 0.18)
                        .shadow(color: OunjePalette.accent.opacity(isSelected ? 0.18 : 0), radius: 8, y: 2)
                        .animation(OunjeMotion.quickSpring, value: isSelected)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .contentShape(Rectangle())
                .highPriorityGesture(TapGesture().onEnded {
                    guard selection != tab.section else { return }
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.84)) {
                        selection = tab.section
                    }
                })
                .accessibilityElement(children: .combine)
                .accessibilityLabel(tab.section.title)
                .accessibilityAddTraits(.isButton)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 56)
        .contentShape(Rectangle())
    }
}

struct FilterTagButton: View {
    let title: String
    let isSelected: Bool
    let accent: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .foregroundStyle(isSelected ? OunjePalette.softCream : OunjePalette.primaryText)
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .background(
                    Capsule(style: .continuous)
                        .fill(isSelected ? OunjePalette.surface : OunjePalette.elevated)
                        .overlay(
                            Capsule(style: .continuous)
                                .stroke(isSelected ? accent.opacity(0.55) : OunjePalette.stroke, lineWidth: 1)
                        )
                )
        }
        .buttonStyle(.plain)
    }
}

struct InlineSearchBar: View {
    @Binding var text: String
    let placeholder: String
    var activeFilterLabel: String? = nil
    var onFilterTap: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(OunjePalette.secondaryText)

            TextField("", text: $text, prompt: Text(placeholder).foregroundColor(OunjePalette.secondaryText))
                .font(.system(size: 17, weight: .medium, design: .rounded))
                .foregroundStyle(OunjePalette.primaryText)

            Button(action: { onFilterTap?() }) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(activeFilterLabel == nil ? OunjePalette.secondaryText : OunjePalette.softCream)

                    if activeFilterLabel != nil {
                        Circle()
                            .fill(OunjePalette.accent)
                            .frame(width: 8, height: 8)
                            .offset(x: 4, y: -2)
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(onFilterTap == nil)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(OunjePalette.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(OunjePalette.stroke, lineWidth: 1)
                )
        )
    }
}

struct CollapsibleSavedSearchBar: View {
    @Binding var text: String
    let placeholder: String
    @Binding var isExpanded: Bool
    @FocusState private var isFocused: Bool

    private var hasQuery: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        Group {
            if isExpanded || hasQuery {
                HStack(spacing: 10) {
                    HStack(spacing: 12) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(OunjePalette.secondaryText)

                        TextField("", text: $text, prompt: Text(placeholder).foregroundColor(OunjePalette.secondaryText))
                            .font(.system(size: 16, weight: .medium, design: .rounded))
                            .foregroundStyle(OunjePalette.primaryText)
                            .focused($isFocused)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 13)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(OunjePalette.surface)
                            .overlay(
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .stroke(OunjePalette.stroke, lineWidth: 1)
                            )
                    )

                    Button {
                        text = ""
                        withAnimation(.easeInOut(duration: 0.18)) {
                            isExpanded = false
                        }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(OunjePalette.secondaryText)
                            .frame(width: 36, height: 36)
                    }
                    .buttonStyle(.plain)
                }
                .onAppear {
                    DispatchQueue.main.async {
                        isFocused = true
                    }
                }
            } else {
                HStack {
                    Spacer(minLength: 0)

                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            isExpanded = true
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 14, weight: .semibold))
                            Text("Search")
                                .font(.system(size: 15, weight: .medium))
                        }
                        .foregroundStyle(OunjePalette.primaryText)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 11)
                        .background(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(OunjePalette.surface)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                                        .stroke(OunjePalette.stroke, lineWidth: 1)
                                )
                        )
                        .shadow(color: .black.opacity(0.10), radius: 8, x: 0, y: 4)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .animation(.easeInOut(duration: 0.18), value: isExpanded)
        .animation(.easeInOut(duration: 0.18), value: hasQuery)
    }
}

struct CookbookPreppedEmptyState: View {
    let title: String
    let detail: String
    let symbolName: String

    var body: some View {
        VStack(spacing: 18) {
            ShareToOunjeEmptyArtwork(maxWidth: 210, maxHeight: 260)
                .padding(.top, 8)

            VStack(spacing: 8) {
                BiroScriptDisplayText(title, size: 28, color: OunjePalette.primaryText)

                Text(detail)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(OunjePalette.secondaryText)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: 290)
        }
        .frame(maxWidth: .infinity, minHeight: 280, alignment: .center)
        .padding(.horizontal, 8)
        .padding(.vertical, 22)
    }
}

struct CookbookSavedEmptyState: View {
    let hasSavedRecipes: Bool
    let onBrowseDiscover: () -> Void
    let onAddRecipe: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            ShareToOunjeEmptyArtwork(maxWidth: 300, maxHeight: 330)

            VStack(spacing: 8) {
                Text(hasSavedRecipes ? "No saved matches" : "Send recipes from anywhere.")
                    .font(.system(size: 25, weight: .heavy))
                    .foregroundStyle(OunjePalette.primaryText)
                    .multilineTextAlignment(.center)

                Text(
                    hasSavedRecipes
                        ? "Try another search, browse Discover, or import from a photo."
                        : "Share from TikTok or Instagram, or take a picture and we’ll build the recipe."
                )
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(OunjePalette.secondaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: 280)

            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    Button(action: onBrowseDiscover) {
                        HStack(spacing: 7) {
                            Image(systemName: "safari")
                                .font(.system(size: 13, weight: .bold))
                            Text("Discover")
                                .biroHeaderFont(15)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(SecondaryPillButtonStyle())

                    Button(action: onAddRecipe) {
                        HStack(spacing: 7) {
                            Image(systemName: "camera.viewfinder")
                                .font(.system(size: 13, weight: .bold))
                            Text("Photo import")
                                .biroHeaderFont(15)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(SecondaryPillButtonStyle())
                }

                Button(action: onAddRecipe) {
                    HStack(spacing: 7) {
                        Image(systemName: "link")
                            .font(.system(size: 13, weight: .bold))
                        Text("Paste TikTok or Instagram link")
                            .biroHeaderFont(15)
                            .lineLimit(1)
                            .minimumScaleFactor(0.82)
                    }
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryPillButtonStyle())
            }
            .frame(maxWidth: 340)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 12)
        .padding(.top, 0)
        .padding(.bottom, 24)
    }
}

private struct ShareToOunjeEmptyArtwork: View {
    let maxWidth: CGFloat
    let maxHeight: CGFloat

    var body: some View {
        Image("FeatureCard5")
            .renderingMode(.original)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(maxWidth: maxWidth, maxHeight: maxHeight)
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: .white, location: 0),
                        .init(color: .white, location: 0.76),
                        .init(color: .clear, location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
    }
}

struct CookbookInlineActionHeader: View {
    let title: String
    let detail: String
    let buttonTitle: String
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .biroHeaderFont(24)
                    .foregroundStyle(OunjePalette.primaryText)
                Text(detail)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(OunjePalette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 10)

            Button(action: action) {
                HStack(spacing: 8) {
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .bold))
                    Text(buttonTitle)
                        .biroHeaderFont(14)
                }
                .foregroundStyle(OunjePalette.primaryText)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    Capsule(style: .continuous)
                        .fill(OunjePalette.surface)
                        .overlay(
                            Capsule(style: .continuous)
                                .stroke(OunjePalette.stroke, lineWidth: 1)
                        )
                )
            }
            .buttonStyle(.plain)
        }
    }
}

struct CookbookRecipesGroup: View {
    let title: String
    let detail: String
    let recipes: [DiscoverRecipeCardData]
    let columns: [GridItem]
    let onSelectRecipe: (DiscoverRecipeCardData) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                BiroScriptDisplayText(title, size: 26, color: OunjePalette.primaryText)
                Text(detail)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(OunjePalette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            LazyVGrid(columns: columns, spacing: 14) {
                ForEach(recipes) { recipe in
                    DiscoverRemoteRecipeCard(recipe: recipe) {
                        onSelectRecipe(recipe)
                    }
                }
            }
        }
    }
}

struct ShoppingListRow: View {
    let item: GroceryItem

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            IngredientBadge(name: item.name)

            VStack(alignment: .leading, spacing: 4) {
                Text(item.name.capitalized)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(OunjePalette.primaryText)
                Text("\(item.amount.roundedString(1)) \(item.unit)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(OunjePalette.secondaryText)
            }

            Spacer()

            Text(item.estimatedPrice.asCurrency)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(OunjePalette.primaryText)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(OunjePalette.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(OunjePalette.stroke, lineWidth: 1)
                )
        )
    }
}

enum CartDisplayMode: String, CaseIterable, Identifiable {
    case reconciled
    case recipes
    case grid

    var id: String { rawValue }

    var symbolName: String {
        switch self {
        case .reconciled: return "shippingbox"
        case .recipes: return "list.bullet.rectangle"
        case .grid: return "square.grid.2x2"
        }
    }
}

struct CartDisplayModeBar<TrailingContent: View>: View {
    @Binding var selection: CartDisplayMode
    @Namespace private var selectionNamespace
    let trailingAction: (() -> Void)?
    var trailingDisabled = false
    @ViewBuilder let trailingContent: () -> TrailingContent

    var body: some View {
        HStack(spacing: 18) {
            ForEach(CartDisplayMode.allCases) { mode in
                Button {
                    withAnimation(OunjeMotion.quickSpring) {
                        selection = mode
                    }
                } label: {
                    VStack(spacing: 8) {
                        Image(systemName: mode.symbolName)
                            .font(.system(size: 17, weight: .semibold))

                        if selection == mode {
                            Capsule(style: .continuous)
                                .fill(OunjePalette.accent)
                                .frame(width: 20, height: 3)
                                .matchedGeometryEffect(id: "cart-mode-indicator", in: selectionNamespace)
                        } else {
                            Capsule(style: .continuous)
                                .fill(Color.clear)
                                .frame(width: 20, height: 3)
                        }
                    }
                    .foregroundStyle(selection == mode ? OunjePalette.primaryText : OunjePalette.secondaryText)
                    .frame(width: 28)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background {
                        if selection == mode {
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(OunjePalette.surface.opacity(0.86))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                                        .stroke(OunjePalette.stroke.opacity(0.78), lineWidth: 1)
                                )
                                .matchedGeometryEffect(id: "cart-mode-highlight", in: selectionNamespace)
                        }
                    }
                }
                .buttonStyle(OunjeCardPressButtonStyle())
            }

            Spacer(minLength: 0)

            if let trailingAction {
                Button(action: trailingAction) {
                    trailingContent()
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct CartMainShopMappingEntry: Identifiable, Hashable {
    let id: String
    let mainShopItem: CartGroceryDisplayItem
    let sourceEntries: [CartMainShopMappingSourceEntry]
}

struct CartMainShopMappingSourceEntry: Identifiable, Hashable {
    let id: String
    let recipeTitle: String
    let ingredientName: String
    let quantityText: String?
    let imageURL: URL?
}

struct CartIngredientGroup: Identifiable, Hashable {
    var id: String { recipeID }
    let recipeID: String
    let recipeTitle: String
    let servings: Int
    let cookTimeMinutes: Int
    let ingredients: [SupabaseRecipeIngredientRow]
}

struct CartRecipeListCard: View {
    let group: CartIngredientGroup
    let isCollapsed: Bool
    let onToggleCollapsed: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(group.recipeTitle)
                        .biroHeaderFont(24)
                        .foregroundStyle(OunjePalette.primaryText)
                    Text("\(group.servings) servings · \(group.cookTimeMinutes) mins")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(OunjePalette.secondaryText)
                }

                Spacer()

                Button(action: onToggleCollapsed) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(OunjePalette.secondaryText)
                        .frame(width: 30, height: 30)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(OunjePalette.surface.opacity(0.88))
                        )
                        .rotationEffect(.degrees(isCollapsed ? 0 : 180))
                }
                .buttonStyle(.plain)
            }

            if !isCollapsed {
                VStack(spacing: 0) {
                    ForEach(Array(group.ingredients.enumerated()), id: \.element.id) { index, ingredient in
                        CartRecipeIngredientRow(ingredient: ingredient)

                        if index < group.ingredients.count - 1 {
                            Divider()
                                .overlay(OunjePalette.stroke.opacity(0.8))
                                .padding(.leading, 64)
                                .padding(.vertical, 10)
                        }
                    }
                }
            }
        }
        .padding(.bottom, 22)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(OunjePalette.stroke.opacity(0.72))
                .frame(height: 1)
        }
    }
}

struct CartRecipeIngredientRow: View {
    let ingredient: SupabaseRecipeIngredientRow

    var body: some View {
        HStack(spacing: 12) {
            CartIngredientArtwork(ingredient: ingredient, compact: true)
                .frame(width: 50, height: 50)

            VStack(alignment: .leading, spacing: 3) {
                Text(ingredient.displayTitle)
                    .sleeDisplayFont(16)
                    .foregroundStyle(OunjePalette.primaryText)
                    .lineLimit(2)

                if let quantityText = ingredient.displayQuantityText, !quantityText.isEmpty {
                    Text(quantityText)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(OunjePalette.secondaryText)
                }
            }

            Spacer(minLength: 8)
        }
        .padding(.vertical, 2)
    }
}

struct CartIngredientTile: View {
    let ingredient: SupabaseRecipeIngredientRow
    let compact: Bool
    var elevated: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CartIngredientArtwork(ingredient: ingredient, compact: compact)
                .frame(height: compact ? 88 : 102)

            Text(ingredient.displayTitle)
                .sleeDisplayFont(compact ? 16 : 17)
                .foregroundStyle(OunjePalette.primaryText)
                .lineLimit(2)

            if let quantityText = ingredient.displayQuantityText, !quantityText.isEmpty {
                Text(quantityText)
                    .font(.system(size: compact ? 11 : 12, weight: .medium))
                    .foregroundStyle(OunjePalette.secondaryText)
                    .lineLimit(1)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(elevated ? OunjePalette.elevated : OunjePalette.panel.opacity(0.52))
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(elevated ? OunjePalette.stroke : OunjePalette.stroke.opacity(0.72), lineWidth: 1)
                )
        )
    }
}

struct CartFlatIngredientTile: View {
    let ingredient: SupabaseRecipeIngredientRow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CartIngredientArtwork(ingredient: ingredient, compact: false)
                .frame(height: 84)

            Text(ingredient.displayTitle)
                .sleeDisplayFont(16)
                .foregroundStyle(OunjePalette.primaryText)
                .lineLimit(2)
                .minimumScaleFactor(0.8)

            if let quantityText = ingredient.displayQuantityText, !quantityText.isEmpty {
                Text(quantityText)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(OunjePalette.secondaryText)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

actor CartArtworkImageRepository {
    static let shared = CartArtworkImageRepository()

    private var cache: [String: UIImage] = [:]
    private var inFlight: [String: Task<UIImage?, Never>] = [:]

    func image(for url: URL) async -> UIImage? {
        let key = url.absoluteString
        if let cached = cache[key] {
            return cached
        }
        if let task = inFlight[key] {
            let image = await task.value
            inFlight[key] = nil
            if let image {
                cache[key] = image
            }
            return image
        }

        let task = Task<UIImage?, Never> {
            do {
                var request = URLRequest(url: url)
                request.cachePolicy = .returnCacheDataElseLoad
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse,
                      (200 ... 299).contains(httpResponse.statusCode),
                      let image = UIImage(data: data) else {
                    return nil
                }
                return image
            } catch {
                return nil
            }
        }

        inFlight[key] = task
        let image = await task.value
        inFlight[key] = nil
        if let image {
            cache[key] = image
        }
        return image
    }

    func prewarm(urls: [URL]) {
        for url in urls {
            let key = url.absoluteString
            guard cache[key] == nil, inFlight[key] == nil else { continue }
            inFlight[key] = Task<UIImage?, Never> {
                do {
                    var request = URLRequest(url: url)
                    request.cachePolicy = .returnCacheDataElseLoad
                    let (data, response) = try await URLSession.shared.data(for: request)
                    guard let httpResponse = response as? HTTPURLResponse,
                          (200 ... 299).contains(httpResponse.statusCode),
                          let image = UIImage(data: data) else {
                        return nil
                    }
                    return image
                } catch {
                    return nil
                }
            }
        }
    }
}

@MainActor
final class CartArtworkImageLoader: ObservableObject {
    @Published var image: UIImage?
    private var currentKey: String?

    func load(from url: URL?) async {
        guard let url else {
            image = nil
            currentKey = nil
            return
        }

        let key = url.absoluteString
        if currentKey == key, image != nil {
            return
        }

        currentKey = key
        image = await CartArtworkImageRepository.shared.image(for: url)
    }

    static func prewarm(urls: [URL]) {
        Task(priority: .utility) {
            await CartArtworkImageRepository.shared.prewarm(urls: urls)
        }
    }
}

struct CartCachedArtworkView<Placeholder: View>: View {
    let imageURL: URL?
    let placeholder: Placeholder

    @StateObject private var loader = CartArtworkImageLoader()

    init(imageURL: URL?, @ViewBuilder placeholder: () -> Placeholder) {
        self.imageURL = imageURL
        self.placeholder = placeholder()
    }

    var body: some View {
        Group {
            if let image = loader.image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                placeholder
            }
        }
        .task(id: imageURL?.absoluteString) {
            await loader.load(from: imageURL)
        }
    }
}

struct CartIngredientArtwork: View {
    let ingredient: SupabaseRecipeIngredientRow
    let compact: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(OunjePalette.panel)

            CartCachedArtworkView(imageURL: ingredient.imageURL) {
                fallbackGlyph
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var fallbackGlyph: some View {
        Text(IngredientMonogramFormatter.monogram(for: ingredient.displayTitle))
            .sleeDisplayFont(compact ? 24 : 28)
            .foregroundStyle(OunjePalette.softCream)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct CartGroceryLineItemRow: View {
    let item: CartGroceryDisplayItem
    let quantityCount: Int
    let quantityUnitLabel: String
    var onDecreaseQuantity: (() -> Void)? = nil
    var onIncreaseQuantity: (() -> Void)? = nil
    var onRemove: (() -> Void)? = nil
    var onMarkOwned: (() -> Void)? = nil
    @State private var isQuantityAnimating = false

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(item.imageURL == nil ? Color(hex: "F2EFE6") : OunjePalette.panel)
                    .frame(width: 56, height: 56)

                if item.imageURL != nil {
                    CartCachedArtworkView(imageURL: item.imageURL) {
                        fallbackGlyph
                    }
                    .frame(width: 56, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                } else {
                    fallbackGlyph
                }
            }
            .frame(width: 56, height: 56)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.name)
                    .sleeDisplayFont(16)
                    .foregroundStyle(OunjePalette.primaryText)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)

                if let supportingText = item.supportingText, !supportingText.isEmpty {
                    Text(supportingText)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(OunjePalette.secondaryText.opacity(0.82))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 3) {
                HStack(spacing: 9) {
                    Button(action: { onDecreaseQuantity?() }) {
                        Image(systemName: "minus")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(OunjePalette.primaryText)
                            .frame(width: 26, height: 26)
                            .background(
                                Circle()
                                    .fill(OunjePalette.panel)
                            )
                    }
                    .buttonStyle(.plain)

                    VStack(spacing: 0) {
                        Text("\(quantityCount)")
                            .font(.system(size: 19, weight: .semibold))
                            .foregroundStyle(OunjePalette.primaryText)
                            .monospacedDigit()

                        Text(quantityUnitLabel)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(OunjePalette.secondaryText)
                            .lineLimit(1)
                            .minimumScaleFactor(0.82)
                    }
                    .frame(width: 52)
                    .scaleEffect(isQuantityAnimating ? 1.08 : 1)

                    Button(action: { onIncreaseQuantity?() }) {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(OunjePalette.primaryText)
                            .frame(width: 26, height: 26)
                            .background(
                                Circle()
                                    .fill(OunjePalette.panel)
                            )
                    }
                    .buttonStyle(.plain)
                }
                .frame(width: 122, alignment: .trailing)

            }
            .frame(width: 122, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            if let onMarkOwned {
                Button {
                    onMarkOwned()
                } label: {
                    Label("Owned", systemImage: "checkmark.circle")
                }
                .tint(Color(red: 0.21, green: 0.68, blue: 0.41))
            }
            if let onRemove {
                Button(role: .destructive) {
                    onRemove()
                } label: {
                    Label("Remove", systemImage: "minus.circle")
                }
            }
        }
        .onChange(of: quantityCount) { _ in
            withAnimation(OunjeMotion.quickSpring) {
                isQuantityAnimating = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                withAnimation(OunjeMotion.subtleEase) {
                    isQuantityAnimating = false
                }
            }
        }
    }

    private var fallbackGlyph: some View {
        Text(IngredientMonogramFormatter.monogram(for: item.name))
            .sleeDisplayFont(18)
            .foregroundStyle(Color.black.opacity(0.62))
            .frame(width: 56, height: 56, alignment: .center)
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.black.opacity(0.06), lineWidth: 1)
            )
    }
}

enum CartQuantityFormatter {
    struct MainShopDisplayComponents {
        let roundedCount: Int
        let unitLabel: String
    }

    static func format(amount: Double, unit: String) -> String {
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

    static func mainShopDisplayComponents(from quantityText: String) -> MainShopDisplayComponents? {
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
        return MainShopDisplayComponents(
            roundedCount: roundedCount,
            unitLabel: unitLabel
        )
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
}

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0, !isEmpty else {
            return isEmpty ? [] : [self]
        }

        var chunks: [[Element]] = []
        var index = startIndex

        while index < endIndex {
            let nextIndex = self.index(index, offsetBy: size, limitedBy: endIndex) ?? endIndex
            chunks.append(Array(self[index ..< nextIndex]))
            index = nextIndex
        }

        return chunks
    }
}

struct IngredientBadge: View {
    let name: String

    private var emoji: String {
        let normalized = name.lowercased()
        if normalized.contains("chicken") { return "🍗" }
        if normalized.contains("turkey") { return "🦃" }
        if normalized.contains("beef") || normalized.contains("steak") { return "🥩" }
        if normalized.contains("salmon") || normalized.contains("fish") || normalized.contains("shrimp") { return "🐟" }
        if normalized.contains("egg") { return "🥚" }
        if normalized.contains("broccoli") { return "🥦" }
        if normalized.contains("spinach") || normalized.contains("lettuce") || normalized.contains("kale") { return "🥬" }
        if normalized.contains("carrot") { return "🥕" }
        if normalized.contains("potato") { return "🥔" }
        if normalized.contains("rice") { return "🍚" }
        if normalized.contains("pasta") || normalized.contains("spaghetti") || normalized.contains("noodle") { return "🍝" }
        if normalized.contains("cheddar") || normalized.contains("cheese") { return "🧀" }
        if normalized.contains("milk") { return "🥛" }
        if normalized.contains("bread") || normalized.contains("bun") || normalized.contains("tortilla") { return "🍞" }
        if normalized.contains("tomato") { return "🍅" }
        if normalized.contains("pepper") { return "🫑" }
        if normalized.contains("onion") { return "🧅" }
        if normalized.contains("garlic") { return "🧄" }
        if normalized.contains("avocado") { return "🥑" }
        if normalized.contains("lemon") || normalized.contains("lime") { return "🍋" }
        if normalized.contains("bean") { return "🫘" }
        if normalized.contains("mushroom") { return "🍄" }
        return "🥣"
    }

    var body: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [
                        OunjePalette.panel,
                        OunjePalette.accent.opacity(0.08)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .frame(width: 56, height: 56)
            .overlay(
                Text(emoji)
                    .font(.system(size: 28))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(OunjePalette.stroke, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.16), radius: 10, y: 6)
    }
}

struct AddActionRow: View {
    let title: String
    let detail: String
    let symbolName: String
    let accent: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(accent.opacity(0.14))
                    .frame(width: 50, height: 50)
                    .overlay(
                        Image(systemName: symbolName)
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(accent)
                    )

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .biroHeaderFont(18)
                        .foregroundStyle(OunjePalette.primaryText)
                        .lineLimit(1)
                    Text(detail)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(OunjePalette.secondaryText)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                Image(systemName: "arrow.up.right")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(OunjePalette.secondaryText.opacity(0.5))
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                OunjePalette.surface,
                                accent.opacity(0.06)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .stroke(OunjePalette.stroke, lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
    }
}
