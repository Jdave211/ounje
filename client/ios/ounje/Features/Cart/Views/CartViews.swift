import SwiftUI
import Foundation
import UIKit
import ImageIO

actor CartSupportWarmupCache {
    static let shared = CartSupportWarmupCache()

    private struct Entry {
        let planID: UUID
        let signature: String
        var rows: [SupabaseRecipeIngredientRow]
        var snapshot: MainShopSnapshot?
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
        return entry.rows.isEmpty ? nil : entry.rows
    }

    func snapshot(for plan: MealPlan) -> MainShopSnapshot? {
        let signature = MainShopSnapshotBuilder.signature(for: plan.groceryItems)
        guard let entry = entriesByPlanID[plan.id],
              entry.signature == signature,
              Date().timeIntervalSince(entry.warmedAt) < 30 * 60 else {
            return nil
        }
        return entry.snapshot
    }

    func store(rows: [SupabaseRecipeIngredientRow], for plan: MealPlan) {
        guard !rows.isEmpty else { return }
        let signature = MainShopSnapshotBuilder.signature(for: plan.groceryItems)
        let snapshot = entriesByPlanID[plan.id].flatMap { $0.signature == signature ? $0.snapshot : nil }
        store(Entry(planID: plan.id, signature: signature, rows: rows, snapshot: snapshot, warmedAt: .now))
    }

    func store(snapshot: MainShopSnapshot, for plan: MealPlan) {
        let signature = MainShopSnapshotBuilder.signature(for: plan.groceryItems)
        guard snapshot.signature == signature else { return }
        let rows = entriesByPlanID[plan.id].flatMap { $0.signature == signature ? $0.rows : nil } ?? []
        store(Entry(planID: plan.id, signature: signature, rows: rows, snapshot: snapshot, warmedAt: .now))
    }

    private func store(_ entry: Entry) {
        entriesByPlanID[entry.planID] = entry
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

        guard let plan = await MainActor.run(body: { store.latestPlan }),
              !plan.recipes.isEmpty else {
            return
        }

        let localSnapshot: MainShopSnapshot
        if let cached = await CartSupportWarmupCache.shared.snapshot(for: plan) {
            localSnapshot = cached
        } else {
            let groceryItems = plan.groceryItems
            localSnapshot = await Task.detached(priority: .utility) {
                MainShopSnapshotBuilder.buildLocalSnapshot(for: groceryItems)
            }.value
            guard !Task.isCancelled else { return }
            await CartSupportWarmupCache.shared.store(snapshot: localSnapshot, for: plan)
        }
        prewarmArtwork(for: plan, rows: [], snapshot: localSnapshot)

        try? await Task.sleep(nanoseconds: 600_000_000)
        guard !Task.isCancelled else { return }

        if await CartSupportWarmupCache.shared.rows(for: plan) != nil {
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
            prewarmArtwork(for: activePlan, rows: rows, snapshot: localSnapshot)
        } catch {
            // The local snapshot is already ready even when artwork lookup fails.
        }
    }

    static func cachedIngredientRows(for plan: MealPlan) async -> [SupabaseRecipeIngredientRow]? {
        await CartSupportWarmupCache.shared.rows(for: plan)
    }

    static func cachedSnapshot(for plan: MealPlan) async -> MainShopSnapshot? {
        await CartSupportWarmupCache.shared.snapshot(for: plan)
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

    private static func prewarmArtwork(
        for plan: MealPlan,
        rows: [SupabaseRecipeIngredientRow],
        snapshot: MainShopSnapshot
    ) {
        var seen = Set<String>()
        let urls = (
            rows.compactMap(\.imageURL)
                + (plan.mainShopSnapshot?.items ?? snapshot.items).compactMap { item in
                    guard let value = item.imageURLString?.trimmingCharacters(in: .whitespacesAndNewlines),
                          !value.isEmpty else {
                        return nil
                    }
                    return URL(string: value)
                }
        )
        .filter { seen.insert($0.absoluteString).inserted }
        .prefix(12)
        guard !urls.isEmpty else { return }
        Task { @MainActor in
            CartArtworkImageLoader.prewarm(urls: Array(urls))
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
    private enum CartListScope: String {
        case toBuy
        case alreadyHave
    }

    @EnvironmentObject private var store: MealPlanningAppStore
    @EnvironmentObject private var toastCenter: AppToastCenter
    @EnvironmentObject private var firstRunGuide: FirstRunGuideCoordinator
    @Environment(\.openURL) private var openURL
    @Binding var selectedTab: AppTab
    @Binding var focusedRecipeID: String?
    @AppStorage(RecipeTypographyStyle.storageKey) private var recipeTypographyStyleRawValue = RecipeTypographyStyle.defaultStyle.rawValue
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
    @State private var isShoppingListMode = false
    @State private var checkedShoppingItemIDs = Set<String>()
    @State private var tripOwnedItemKeys = Set<String>()
    @State private var automaticHouseholdOptOutKeys = Set<String>()
    @State private var cartListScope: CartListScope = .toBuy
    @State private var isTransferSelectionMode = false
    @State private var selectedTransferItemKeys = Set<String>()
    @State private var resolvedReviewItemKeys = Set<String>()
    @State private var selectedCartItem: CartGroceryDisplayItem?
    @State private var selectedProblemItem: CartProblemItem?
    @State private var isShoppingActionPresented = false
    @State private var isBasketExpanded = false

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .center, spacing: 12) {
                            BiroScriptDisplayText("Cart", size: 31, color: OunjePalette.primaryText)

                            Spacer(minLength: 0)

                            if !isShoppingListMode, !isTransferSelectionMode {
                                Button {
                                    isShoppingActionPresented = true
                                } label: {
                                    Label("Shop now", systemImage: "cart")
                                        .font(.system(size: 13, weight: .bold))
                                        .foregroundStyle(OunjePalette.primaryText)
                                        .padding(.horizontal, 12)
                                        .frame(height: 38)
                                        .background(
                                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                                .fill(OunjePalette.surface)
                                                .overlay(
                                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                                        .stroke(OunjePalette.stroke, lineWidth: 1)
                                                )
                                        )
                                }
                                .buttonStyle(.plain)
                                .firstRunGuideTarget(
                                    .shopNow,
                                    enabled: firstRunGuide.phase == .cartShopNow
                                )
                                .disabled(visibleReconciledCartItems.isEmpty)
                                .opacity(visibleReconciledCartItems.isEmpty ? 0.42 : 1)
                                .offset(y: 15)
                            }
                        }

                        if cartPlanOptions.count > 1 {
                            Menu {
                                ForEach(cartPlanOptions) { batch in
                                    Button {
                                        selectCartPlan(batch)
                                    } label: {
                                        if batch.id == activeCartPlan?.id {
                                            Label(batch.name, systemImage: "checkmark")
                                        } else {
                                            Text(batch.name)
                                        }
                                    }
                                }
                            } label: {
                                cartPlanSelectorLabel(showsChevron: true)
                            }
                            .buttonStyle(.plain)
                        } else {
                            cartPlanSelectorLabel(showsChevron: false)
                        }

                        if isShoppingListMode {
                            HStack(spacing: 12) {
                                Text(operationalCartSummaryLine)
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundStyle(OunjePalette.secondaryText)

                                Spacer(minLength: 0)

                                if !basketItems.isEmpty {
                                    Menu {
                                        Button {
                                            resetShoppingListChecks()
                                        } label: {
                                            Label("Reset checks", systemImage: "arrow.counterclockwise")
                                        }
                                    } label: {
                                        Image(systemName: "ellipsis")
                                            .font(.system(size: 14, weight: .bold))
                                            .foregroundStyle(OunjePalette.secondaryText)
                                            .frame(width: 34, height: 34)
                                            .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("Shopping list options")
                                }

                                Button("Done", action: finishShoppingList)
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundStyle(OunjePalette.primaryText)
                                    .buttonStyle(.plain)
                                    .padding(.horizontal, 13)
                                    .frame(height: 34)
                                    .background(
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .fill(OunjePalette.surface)
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                                    .stroke(OunjePalette.stroke, lineWidth: 1)
                                            )
                                    )
                                    .firstRunGuideTarget(
                                        .checklistDone,
                                        enabled: firstRunGuide.phase == .cartChecklistDone
                                    )
                            }
                            .padding(.top, 16)
                        } else {
                            cartListScopeSelector

                            if cartListScope == .alreadyHave, !isTransferSelectionMode {
                                Text("These items are already in your kitchen.")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(OunjePalette.secondaryText)
                            }

                        }
                    }
                    .id("first-guide-cart-top")

                    if shouldShowEmptyCartState {
                        CartEmptyState(
                            onBrowseDiscover: { selectedTab = .discover }
                        )
                    } else if isLoadingIngredients && visibleReconciledCartItems.isEmpty {
                        CartMainShopLoadingState()
                    } else if shouldShowUnavailableCartState {
                        CartUnavailableState {
                            Task { await reloadCartIngredients(forceRebuild: true) }
                        }
                    } else {
                        operationalCartContent
                    }
                }
                .padding(.horizontal, OunjeLayout.screenHorizontalPadding)
                .padding(.top, 14)
                .padding(.bottom, 18)
            }
            .scrollIndicators(.hidden)
            .onAppear {
                scrollToGuideTarget(firstRunGuide.phase, using: proxy)
            }
            .onChange(of: firstRunGuide.phase) { phase in
                scrollToGuideTarget(phase, using: proxy)
            }
            .onChange(of: firstGuideCartItemScrollID) { _ in
                scrollToGuideTarget(firstRunGuide.phase, using: proxy)
            }
        }
        .background(OunjePalette.background.ignoresSafeArea())
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if isTransferSelectionMode {
                cartTransferSelectionActions
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .sheet(item: $selectedCartItem) { item in
            let quantity = mainShopQuantityDisplay(for: item)
            CartItemDetailSheet(
                item: item,
                quantityCount: quantity.count,
                quantityUnitLabel: quantity.unitLabel,
                isAlreadyHave: tripOwnedItemKeys.contains(cartItemKey(item)),
                sourceEntries: cartMappingEntry(for: item)?.sourceEntries ?? [],
                onDecreaseQuantity: { adjustMainShopQuantity(for: item, delta: -1) },
                onIncreaseQuantity: { adjustMainShopQuantity(for: item, delta: 1) },
                onToggleAlreadyHave: { toggleMainShopItemOnHandForTrip(item) },
                onRemove: { removeMainShopItem(item) }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.hidden)
        }
        .sheet(item: $selectedProblemItem) { problem in
            CartProblemItemSheet(
                item: problem,
                onCorrect: { correctedName in
                    resolveProblemItem(problem, correctedName: correctedName)
                },
                onRemove: {
                    dismissProblemItem(problem)
                }
            )
            .presentationDetents([.height(340)])
            .presentationDragIndicator(.hidden)
        }
        .sheet(isPresented: $isShoppingActionPresented, onDismiss: {
            if firstRunGuide.phase == .cartChecklistOption {
                firstRunGuide.advance(to: .cartShopNow)
            }
        }) {
            CartShoppingActionSheet(
                planName: activeCartPlan?.name ?? "Usual",
                itemCount: visibleReconciledCartItems.count,
                instacartTitle: shoppingSheetInstacartTitle,
                instacartSubtitle: shoppingSheetInstacartSubtitle,
                isInstacartDisabled: shoppingSheetInstacartDisabled,
                choosesProvider: cartBuyNowStatusTone == .idle,
                onChecklist: beginShoppingList,
                onInstacart: handleShoppingSheetInstacartAction
            )
            .presentationDetents([.height(296)])
            .presentationDragIndicator(.hidden)
        }
        .sheet(isPresented: $isRunLogsPresented) {
            InstacartRunLogsSheet(
                store: instacartRunLogsStore,
                mealStore: store,
                userID: store.authSession?.userID ?? store.resolvedTrackingSession?.userID,
                accessToken: store.authSession?.accessToken,
                onRerun: {
                    await performCartBuyNowRun(trigger: "instacart_runs_rerun")
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
        .onAppear {
            loadShoppingListState()
            loadTripCartState()
            syncCartGuideInteractionState()
        }
        .onChange(of: shoppingListPersistenceKey) { _ in
            loadShoppingListState()
        }
        .onChange(of: tripCartPersistenceScope) { _ in
            loadTripCartState()
            loadShoppingListState()
        }
        .onChange(of: automaticHouseholdDefaultsSignature) { _ in
            applyAutomaticHouseholdDefaults()
        }
        .onChange(of: firstRunGuide.phase) { _ in
            syncCartGuideInteractionState()
        }
        .onChange(of: firstGuideCartItemScrollID) { _ in
            syncCartGuideInteractionState()
        }
        .onChange(of: isShoppingActionPresented) { isPresented in
            if isPresented, firstRunGuide.phase == .cartShopNow {
                firstRunGuide.advance(to: .cartChecklistOption)
            }
        }
    }

    private var cartPlanOptions: [PrepBatch] {
        guard let plan = store.latestPlan else { return [] }
        if let batches = plan.batches, !batches.isEmpty {
            return batches
        }
        return [
            PrepBatch(
                id: plan.id,
                name: "Usual",
                recipes: plan.recipes,
                groceryItems: plan.groceryItems,
                recurringRecipeIDs: plan.recurringRecipeIDs,
                createdAt: plan.generatedAt
            )
        ]
    }

    private var cartTypographyStyle: RecipeTypographyStyle {
        RecipeTypographyStyle.resolved(from: recipeTypographyStyleRawValue)
    }

    private var activeCartPlan: PrepBatch? {
        store.activeBatch ?? cartPlanOptions.first
    }

    private var activeCartPlanDescriptor: String {
        let count = activeCartPlan?.recipes.count ?? store.latestPlan?.recipes.count ?? 0
        return "Plan · \(count) \(count == 1 ? "recipe" : "recipes")"
    }

    private var activeCartPlanFlagshipURL: URL? {
        activeCartPlan?.flagshipImageURL
    }

    private func cartPlanSelectorLabel(showsChevron: Bool) -> some View {
        HStack(spacing: 12) {
            CartPlanFlagshipArtwork(
                imageURL: activeCartPlanFlagshipURL,
                title: activeCartPlan?.name ?? "Usual"
            )

            VStack(alignment: .leading, spacing: 2) {
                CartPreferenceText(
                    activeCartPlan?.name ?? "Usual",
                    size: 18,
                    style: cartTypographyStyle,
                    cleanWeight: .bold
                )
                .lineLimit(1)

                Text(activeCartPlanDescriptor)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(OunjePalette.secondaryText)
            }

            if showsChevron {
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(OunjePalette.secondaryText)
            }

            Spacer(minLength: 0)
        }
        .foregroundStyle(OunjePalette.primaryText)
        .contentShape(Rectangle())
    }

    private func selectCartPlan(_ batch: PrepBatch) {
        guard store.latestPlan?.batches?.contains(where: { $0.id == batch.id }) == true else { return }
        _ = store.setPrimePrepBatch(batchID: batch.id)
    }

    private var tripCartPersistenceScope: String {
        let userID = store.authSession?.userID ?? store.resolvedTrackingSession?.userID ?? "signed-out"
        let planID = store.latestPlan?.id.uuidString ?? "no-plan"
        let batchID = store.activeBatch?.id.uuidString
            ?? store.latestPlan?.activeBatchID?.uuidString
            ?? "legacy"
        return "\(userID)::\(planID)::\(batchID)"
    }

    private var kitchenInventoryPersistenceScope: String {
        store.authSession?.userID ?? store.resolvedTrackingSession?.userID ?? "signed-out"
    }

    private var tripOwnedPersistenceKey: String {
        "ounje.cart.on-hand.v2::\(kitchenInventoryPersistenceScope)"
    }

    private var reviewResolutionPersistenceKey: String {
        "ounje.cart.reviewed.v1::\(tripCartPersistenceScope)"
    }

    private var automaticHouseholdOptOutPersistenceKey: String {
        "ounje.cart.household-opt-out.v2::\(kitchenInventoryPersistenceScope)"
    }

    private func cartItemKey(_ item: CartGroceryDisplayItem) -> String {
        Self.normalizedIngredientKey(item.removalKey ?? item.name)
    }

    private var planScopedCartItems: [CartGroceryDisplayItem] {
        reconciledCartItems.filter { item in
            !isHiddenMainShopRelatedItem(named: item.name, removalKey: item.removalKey)
        }
    }

    private var tripOwnedCartItems: [CartGroceryDisplayItem] {
        planScopedCartItems.filter { tripOwnedItemKeys.contains(cartItemKey($0)) }
    }

    private var operationalCartSummaryLine: String {
        let total = visibleReconciledCartItems.count
        if isShoppingListMode {
            let picked = visibleReconciledCartItems.filter {
                checkedShoppingItemIDs.contains(cartItemKey($0))
            }.count
            return "\(picked) of \(total) picked"
        }

        let owned = tripOwnedCartItems.count
        return "\(total) \(total == 1 ? "item" : "items") to buy · \(owned) already have"
    }

    private var scopedOperationalCartItems: [CartGroceryDisplayItem] {
        switch cartListScope {
        case .toBuy:
            return visibleReconciledCartItems
        case .alreadyHave:
            return tripOwnedCartItems
        }
    }

    private var uncheckedCartItems: [CartGroceryDisplayItem] {
        guard isShoppingListMode else { return scopedOperationalCartItems }
        return visibleReconciledCartItems
    }

    private var basketItems: [CartGroceryDisplayItem] {
        guard isShoppingListMode else { return [] }
        return visibleReconciledCartItems.filter {
            checkedShoppingItemIDs.contains(cartItemKey($0))
        }
    }

    private var operationalCartSections: [CartAisleGroup] {
        let grouped = Dictionary(grouping: uncheckedCartItems, by: CartAisle.classify)
        return CartAisle.allCases.compactMap { aisle in
            guard let items = grouped[aisle], !items.isEmpty else { return nil }
            return CartAisleGroup(
                aisle: aisle,
                items: items.sorted {
                    $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                }
            )
        }
    }

    private var problemItems: [CartProblemItem] {
        (boxedCartCoverageSummary?.actionableUncoveredBaseLabels ?? [])
            .filter { !resolvedReviewItemKeys.contains(Self.normalizedIngredientKey($0)) }
            .map(CartProblemItem.init(name:))
    }

    private var scopedProblemItems: [CartProblemItem] {
        cartListScope == .toBuy ? problemItems : []
    }

    private var cartListScopeSelector: some View {
        HStack(spacing: 18) {
            cartListScopeButton(
                scope: .toBuy,
                title: "\(visibleReconciledCartItems.count) items to buy"
            )
            cartListScopeButton(
                scope: .alreadyHave,
                title: "\(tripOwnedCartItems.count) already have"
            )

            Spacer(minLength: 0)

            if !isTransferSelectionMode, !scopedOperationalCartItems.isEmpty {
                Button("Select") {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    withAnimation(OunjeMotion.quickSpring) {
                        isTransferSelectionMode = true
                        selectedTransferItemKeys.removeAll()
                    }
                    if firstRunGuide.phase == .cartSelect {
                        firstRunGuide.advance(to: .cartIngredient)
                    }
                }
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(OunjePalette.primaryText)
                .buttonStyle(.plain)
                .padding(.horizontal, 13)
                .frame(height: 34)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(OunjePalette.surface)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(OunjePalette.stroke, lineWidth: 1)
                        )
                )
                .firstRunGuideTarget(
                    firstRunGuide.phase == .cartSelect ? .cartSelect : .cartRestoreSelect,
                    enabled: firstRunGuide.phase == .cartSelect || firstRunGuide.phase == .cartRestoreInfo
                )
            }
        }
        .padding(.top, 16)
    }

    private func cartListScopeButton(
        scope: CartListScope,
        title: String
    ) -> some View {
        let isSelected = cartListScope == scope
        return Button {
            withAnimation(OunjeMotion.quickSpring) {
                cartListScope = scope
                isTransferSelectionMode = false
                selectedTransferItemKeys.removeAll()
            }
            if scope == .alreadyHave, firstRunGuide.phase == .cartScope {
                firstRunGuide.advance(to: .cartRestoreInfo)
            }
        } label: {
            Text(title)
                .font(.system(size: 14, weight: isSelected ? .bold : .semibold))
                .foregroundStyle(isSelected ? OunjePalette.primaryText : OunjePalette.secondaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.82)
                .padding(.vertical, 4)
                .overlay(alignment: .bottom) {
                    if isSelected {
                        Rectangle()
                            .fill(OunjePalette.primaryText)
                            .frame(height: 2)
                    }
                }
        }
        .buttonStyle(.plain)
        .firstRunGuideTarget(
            firstRunGuide.phase == .cartScope ? .cartScope : .cartAlreadyHaveIntro,
            enabled: scope == .alreadyHave
                && (firstRunGuide.phase == .cartAlreadyHaveIntro || firstRunGuide.phase == .cartScope)
        )
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var transferDestinationTitle: String {
        cartListScope == .toBuy ? "Already have" : "Items to buy"
    }

    private var cartTransferSelectionActions: some View {
        HStack(spacing: 10) {
            Button("Cancel") {
                withAnimation(OunjeMotion.quickSpring) {
                    isTransferSelectionMode = false
                    selectedTransferItemKeys.removeAll()
                }
            }
            .font(.system(size: 15, weight: .bold))
            .foregroundStyle(OunjePalette.primaryText)
            .buttonStyle(.plain)
            .frame(width: 104, height: 48)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(OunjePalette.surface)
            )

            Button(transferDestinationTitle) {
                moveSelectedCartItems()
                if firstRunGuide.phase == .cartAlreadyHave {
                    firstRunGuide.advance(to: .cartScope)
                }
            }
            .font(.system(size: 15, weight: .bold))
            .foregroundStyle(OunjePalette.background)
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(OunjePalette.softCream)
            )
            .disabled(selectedTransferItemKeys.isEmpty)
            .opacity(selectedTransferItemKeys.isEmpty ? 0.42 : 1)
            .accessibilityLabel("Move selected items to \(transferDestinationTitle)")
            .firstRunGuideTarget(
                .cartAlreadyHave,
                enabled: firstRunGuide.phase == .cartAlreadyHave
            )
        }
        .padding(.horizontal, OunjeLayout.screenHorizontalPadding)
        .padding(.vertical, 10)
        .background(OunjePalette.background.opacity(0.98))
        .overlay(alignment: .top) {
            Divider().background(OunjePalette.stroke.opacity(0.8))
        }
    }

    private func toggleTransferSelection(for item: CartGroceryDisplayItem) {
        let key = cartItemKey(item)
        guard !key.isEmpty else { return }
        withAnimation(OunjeMotion.quickSpring) {
            if selectedTransferItemKeys.contains(key) {
                selectedTransferItemKeys.remove(key)
            } else {
                selectedTransferItemKeys.insert(key)
            }
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func moveSelectedCartItems() {
        let keys = selectedTransferItemKeys
        guard !keys.isEmpty else { return }
        let previouslyOwned = tripOwnedItemKeys.intersection(keys)
        let previousOptOuts = automaticHouseholdOptOutKeys.intersection(keys)
        let destination = transferDestinationTitle

        withAnimation(OunjeMotion.quickSpring) {
            if cartListScope == .toBuy {
                automaticHouseholdOptOutKeys.subtract(keys)
                tripOwnedItemKeys.formUnion(keys)
            } else {
                tripOwnedItemKeys.subtract(keys)
                automaticHouseholdOptOutKeys.formUnion(keys)
            }
            isTransferSelectionMode = false
            selectedTransferItemKeys.removeAll()
        }
        persistTripCartState()
        toastCenter.show(
            title: "Moved to \(destination)",
            subtitle: "\(keys.count) \(keys.count == 1 ? "item" : "items")",
            systemImage: "arrow.left.arrow.right",
            actionTitle: "Undo",
            action: { [toastCenter] in
                tripOwnedItemKeys.subtract(keys)
                tripOwnedItemKeys.formUnion(previouslyOwned)
                automaticHouseholdOptOutKeys.subtract(keys)
                automaticHouseholdOptOutKeys.formUnion(previousOptOuts)
                persistTripCartState()
                toastCenter.dismiss()
            }
        )
    }

    @ViewBuilder
    private var operationalCartContent: some View {
        LazyVStack(alignment: .leading, spacing: 24) {
            if operationalCartSections.isEmpty,
               scopedProblemItems.isEmpty,
               basketItems.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(OunjePalette.accent)
                    CartPreferenceText(
                        cartListScope == .toBuy ? "Nothing left to buy" : "Nothing marked on hand",
                        size: 19,
                        style: cartTypographyStyle,
                        cleanWeight: .bold
                    )
                    Text(cartListScope == .toBuy ? "Everything in this plan is already handled." : "Items marked as already have will appear here.")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(OunjePalette.secondaryText)
                }
                .padding(.top, 12)
            }

            if !scopedProblemItems.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Needs review")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(OunjePalette.primaryText)
                        .padding(.bottom, 8)

                    ForEach(scopedProblemItems) { item in
                        Button {
                            selectedProblemItem = item
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "exclamationmark.circle")
                                    .font(.system(size: 17, weight: .semibold))
                                    .foregroundStyle(OunjePalette.accent)
                                    .frame(width: 48, height: 48)

                                CartPreferenceText(
                                    item.name,
                                    size: 16,
                                    style: cartTypographyStyle,
                                    cleanWeight: .semibold
                                )
                                    .frame(maxWidth: .infinity, alignment: .leading)

                                Image(systemName: "pencil")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(OunjePalette.secondaryText)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        if item.id != scopedProblemItems.last?.id {
                            Divider()
                                .background(OunjePalette.stroke.opacity(0.8))
                                .padding(.leading, 60)
                        }
                    }
                }
            }

            ForEach(operationalCartSections) { section in
                VStack(alignment: .leading, spacing: 0) {
                    Text(section.aisle.title)
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(OunjePalette.primaryText)
                        .padding(.bottom, 8)

                    ForEach(section.items) { item in
                        let quantity = mainShopQuantityDisplay(for: item)
                        CartOperationalItemRow(
                            item: item,
                            quantityAmountText: quantity.amountText,
                            quantityUnitLabel: quantity.unitLabel,
                            isShoppingMode: isShoppingListMode,
                            isChecked: isShoppingListMode && checkedShoppingItemIDs.contains(cartItemKey(item)),
                            isAlreadyHave: tripOwnedItemKeys.contains(cartItemKey(item)),
                            isTransferSelectionMode: isTransferSelectionMode,
                            isTransferSelected: selectedTransferItemKeys.contains(cartItemKey(item)),
                            typographyStyle: cartTypographyStyle,
                            onTap: {
                                if isTransferSelectionMode {
                                    toggleTransferSelection(for: item)
                                    if firstRunGuide.phase == .cartIngredient {
                                        firstRunGuide.advance(to: .cartAlreadyHave)
                                    }
                                } else if isShoppingListMode {
                                    toggleCheckedShoppingItem(item)
                                    if firstRunGuide.phase == .cartChecklistInfo {
                                        let itemKey = cartItemKey(item)
                                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                                            guard firstRunGuide.phase == .cartChecklistInfo,
                                                  checkedShoppingItemIDs.contains(itemKey) else { return }
                                            firstRunGuide.advance(to: .cartChecklistDone)
                                        }
                                    }
                                } else {
                                    selectedCartItem = item
                                }
                            },
                            onDecrease: { adjustMainShopQuantity(for: item, delta: -1) },
                            onIncrease: { adjustMainShopQuantity(for: item, delta: 1) }
                        )
                        .equatable()
                        .firstRunGuideTarget(
                            cartListGuideTargetID(for: item),
                            enabled: firstRunGuide.phase == .cartOverview
                                || firstRunGuide.phase == .cartChecklistInfo
                        )
                        .firstRunGuideTarget(
                            .cartIngredient,
                            enabled: firstRunGuide.phase == .cartIngredient
                                && item.id == operationalCartSections.first?.items.first?.id
                        )
                        .id("first-guide-cart-item-\(item.id)")

                        if item.id != section.items.last?.id {
                            Divider()
                                .background(OunjePalette.stroke.opacity(0.8))
                                .padding(.leading, 60)
                        }
                    }
                }
            }

        }
    }

    private var firstGuideCartItemScrollID: String? {
        guard let itemID = operationalCartSections.first?.items.first?.id else { return nil }
        return "first-guide-cart-item-\(itemID)"
    }

    private var firstGuideCartItemIDs: [String] {
        Array(operationalCartSections.flatMap(\.items).prefix(5).map(\.id))
    }

    private func cartListGuideTargetID(for item: CartGroceryDisplayItem) -> FirstRunGuideTargetID? {
        FirstRunGuideTargetID.cartListItemTarget(at: firstGuideCartItemIDs.firstIndex(of: item.id))
    }

    private func syncCartGuideInteractionState() {
        switch firstRunGuide.phase {
        case .cartOverview:
            cartListScope = .toBuy
            isTransferSelectionMode = false
            selectedTransferItemKeys.removeAll()
        case .cartAlreadyHaveIntro:
            cartListScope = .toBuy
            isTransferSelectionMode = false
            selectedTransferItemKeys.removeAll()
        case .cartSelect:
            cartListScope = .toBuy
            isTransferSelectionMode = false
            selectedTransferItemKeys.removeAll()
        case .cartIngredient:
            cartListScope = .toBuy
            isTransferSelectionMode = true
            selectedTransferItemKeys.removeAll()
        case .cartAlreadyHave:
            cartListScope = .toBuy
            isTransferSelectionMode = true
            if selectedTransferItemKeys.isEmpty,
               let item = operationalCartSections.first?.items.first {
                selectedTransferItemKeys.insert(cartItemKey(item))
            }
        case .cartScope:
            cartListScope = .toBuy
            isTransferSelectionMode = false
            selectedTransferItemKeys.removeAll()
        case .cartRestoreInfo:
            cartListScope = .alreadyHave
            isTransferSelectionMode = false
            selectedTransferItemKeys.removeAll()
        case .cartShopNow:
            cartListScope = .toBuy
            isTransferSelectionMode = false
            selectedTransferItemKeys.removeAll()
            isShoppingListMode = false
        case .cartChecklistInfo, .cartChecklistDone:
            cartListScope = .toBuy
            isTransferSelectionMode = false
            selectedTransferItemKeys.removeAll()
            isShoppingListMode = true
        default:
            break
        }
    }

    private func scrollToGuideTarget(_ phase: FirstRunGuidePhase?, using proxy: ScrollViewProxy) {
        let targetID: String?
        switch phase {
        case .cartIngredient, .cartAlreadyHave:
            targetID = firstGuideCartItemScrollID
        case .cartOverview, .cartSelect, .cartAlreadyHaveIntro, .cartScope,
             .cartRestoreInfo, .cartShopNow, .cartChecklistInfo, .cartChecklistDone:
            targetID = "first-guide-cart-top"
        default:
            targetID = nil
        }
        guard let targetID else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
            withAnimation(OunjeMotion.quickSpring) {
                proxy.scrollTo(targetID, anchor: phase == .cartIngredient ? .center : .top)
            }
        }
    }

    private var shouldShowAutomationStatus: Bool {
        cartBuyNowStatusTone != .idle || currentInstacartCartURL != nil
    }

    private var automationStatusTitle: String {
        let run = activeInstacartRunSummary ?? store.latestInstacartRun
        switch cartBuyNowStatusTone {
        case .running:
            let total = max(run?.itemCount ?? visibleReconciledCartItems.count, 1)
            let complete = min(run?.resolvedCount ?? 0, total)
            return "Building cart · \(complete) of \(total) items"
        case .partial:
            let reviewCount = max(1, (run?.unresolvedCount ?? 0) + (run?.shortfallCount ?? 0))
            return "\(reviewCount) \(reviewCount == 1 ? "item needs" : "items need") review"
        case .complete:
            return "Cart ready"
        case .failed:
            return "Cart build needs attention"
        case .idle:
            return "Instacart status"
        }
    }

    private var cartAutomationStatusRow: some View {
        Button(action: openInstacartRunsSheet) {
            HStack(spacing: 12) {
                Image(systemName: cartBuyNowStatusTone == .complete ? "checkmark.circle.fill" : "cart")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(OunjePalette.accent)
                    .frame(width: 36, height: 36)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(OunjePalette.surface)
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text(automationStatusTitle)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(OunjePalette.primaryText)
                    Text("Tap for status and item review")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(OunjePalette.secondaryText)
                }

                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(OunjePalette.secondaryText)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(OunjePalette.surface.opacity(0.82))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(OunjePalette.stroke, lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
    }

    private func finishShoppingList() {
        let pickedCount = basketItems.count
        withAnimation(OunjeMotion.quickSpring) {
            isShoppingListMode = false
        }
        if firstRunGuide.phase == .cartChecklistDone {
            firstRunGuide.advance(to: .discover)
        }
        persistShoppingListState()
        toastCenter.show(
            title: "Shopping progress saved",
            subtitle: pickedCount == 1
                ? "1 item checked off."
                : "\(pickedCount) items checked off.",
            systemImage: "checkmark.circle.fill"
        )
    }

    private func resetShoppingListChecks() {
        guard !checkedShoppingItemIDs.isEmpty else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        withAnimation(OunjeMotion.quickSpring) {
            checkedShoppingItemIDs.removeAll()
        }
        persistShoppingListState()
        toastCenter.show(
            title: "Checks reset",
            subtitle: "Everything is back on your list.",
            systemImage: "arrow.counterclockwise"
        )
    }

    private func beginShoppingList() {
        isShoppingActionPresented = false
        withAnimation(OunjeMotion.quickSpring) {
            cartListScope = .toBuy
            isTransferSelectionMode = false
            selectedTransferItemKeys.removeAll()
            isShoppingListMode = true
            isBasketExpanded = false
        }
        if firstRunGuide.phase == .cartChecklistOption {
            firstRunGuide.advance(to: .cartChecklistInfo)
        }
    }

    private var shoppingSheetInstacartTitle: String {
        switch cartBuyNowStatusTone {
        case .running:
            return "Instacart in progress"
        case .partial, .failed:
            return "Needs review"
        case .complete:
            return currentInstacartCartURL == nil ? "View Instacart status" : "Review in Instacart"
        case .idle:
            return "Build Instacart cart"
        }
    }

    private var shoppingSheetInstacartSubtitle: String {
        switch cartBuyNowStatusTone {
        case .running:
            return "Ounje is matching the items in this list."
        case .partial:
            let run = activeInstacartRunSummary ?? store.latestInstacartRun
            let reviewCount = max(1, (run?.unresolvedCount ?? 0) + (run?.shortfallCount ?? 0))
            return "\(reviewCount) \(reviewCount == 1 ? "item needs" : "items need") your choice."
        case .failed:
            return "Open the item review and try the unresolved matches again."
        case .complete:
            return "Your matched items are ready for a final check."
        case .idle:
            return cartBuyNowDisabledReason ?? "Ounje will match these items in Instacart."
        }
    }

    private var shoppingSheetInstacartSymbol: String {
        switch cartBuyNowStatusTone {
        case .running:
            return "clock"
        case .partial, .failed:
            return "exclamationmark.circle"
        case .complete:
            return "checkmark.circle"
        case .idle:
            return "cart.badge.plus"
        }
    }

    private var shoppingSheetInstacartDisabled: Bool {
        cartBuyNowStatusTone == .idle && cartBuyNowDisabledReason != nil
    }

    private func handleShoppingSheetInstacartAction() {
        switch cartBuyNowStatusTone {
        case .running, .partial, .failed:
            isShoppingActionPresented = false
            openInstacartRunsSheet()
        case .complete:
            isShoppingActionPresented = false
            if let url = currentInstacartCartURL {
                openURL(url)
            } else {
                openInstacartRunsSheet()
            }
        case .idle:
            guard cartBuyNowDisabledReason == nil else { return }
            isShoppingActionPresented = false
            startCartBuyNowRun(trigger: "cart_shop_this_list")
        }
    }

    private func cartMappingEntry(for item: CartGroceryDisplayItem) -> CartMainShopMappingEntry? {
        cartMainShopMappingEntries.first { $0.id == item.id }
    }

    private func markMainShopItemOnHandForTrip(_ item: CartGroceryDisplayItem) {
        let key = cartItemKey(item)
        guard !key.isEmpty else { return }
        withAnimation(OunjeMotion.quickSpring) {
            automaticHouseholdOptOutKeys.remove(key)
            tripOwnedItemKeys.insert(key)
            selectedCartItem = nil
        }
        persistTripCartState()
        toastCenter.show(
            title: "Already have this",
            subtitle: item.name,
            systemImage: "checkmark.circle.fill",
            destination: nil,
            actionTitle: "Undo",
            action: { [toastCenter] in
                tripOwnedItemKeys.remove(key)
                automaticHouseholdOptOutKeys.insert(key)
                persistTripCartState()
                toastCenter.dismiss()
            }
        )
    }

    private func toggleMainShopItemOnHandForTrip(_ item: CartGroceryDisplayItem) {
        let key = cartItemKey(item)
        guard !key.isEmpty else { return }

        if tripOwnedItemKeys.contains(key) {
            withAnimation(OunjeMotion.quickSpring) {
                tripOwnedItemKeys.remove(key)
                automaticHouseholdOptOutKeys.insert(key)
                selectedCartItem = nil
            }
            persistTripCartState()
            toastCenter.show(
                title: "Back on shop list",
                subtitle: item.name,
                systemImage: "cart.badge.plus",
                destination: nil,
                actionTitle: "Undo",
                action: { [toastCenter] in
                    automaticHouseholdOptOutKeys.remove(key)
                    tripOwnedItemKeys.insert(key)
                    persistTripCartState()
                    toastCenter.dismiss()
                }
            )
        } else {
            markMainShopItemOnHandForTrip(item)
        }
    }

    private func loadTripCartState() {
        migratePlanScopedKitchenInventoryIfNeeded()
        tripOwnedItemKeys = decodedStringSet(forKey: tripOwnedPersistenceKey)
        automaticHouseholdOptOutKeys = decodedStringSet(forKey: automaticHouseholdOptOutPersistenceKey)
        resolvedReviewItemKeys = decodedStringSet(forKey: reviewResolutionPersistenceKey)
        applyAutomaticHouseholdDefaults()
    }

    private func migratePlanScopedKitchenInventoryIfNeeded() {
        let defaults = UserDefaults.standard
        let migrationKey = "ounje.cart.on-hand-migrated-v2::\(kitchenInventoryPersistenceScope)"
        guard !defaults.bool(forKey: migrationKey) else { return }
        defer { defaults.set(true, forKey: migrationKey) }
        let ownedPrefix = "ounje.cart.on-hand.v1::\(kitchenInventoryPersistenceScope)::"
        let optOutPrefix = "ounje.cart.household-opt-out.v1::\(kitchenInventoryPersistenceScope)::"
        let allKeys = defaults.dictionaryRepresentation().keys

        var ownedKeys = decodedStringSet(forKey: tripOwnedPersistenceKey)
        var optOutKeys = decodedStringSet(forKey: automaticHouseholdOptOutPersistenceKey)
        var migratedKeys: [String] = []

        for key in allKeys where key.hasPrefix(ownedPrefix) {
            ownedKeys.formUnion(decodedStringSet(forKey: key))
            migratedKeys.append(key)
        }
        for key in allKeys where key.hasPrefix(optOutPrefix) {
            optOutKeys.formUnion(decodedStringSet(forKey: key))
            migratedKeys.append(key)
        }

        guard !migratedKeys.isEmpty else { return }
        optOutKeys.subtract(ownedKeys)
        encodeStringSet(ownedKeys, forKey: tripOwnedPersistenceKey)
        encodeStringSet(optOutKeys, forKey: automaticHouseholdOptOutPersistenceKey)
        migratedKeys.forEach(defaults.removeObject(forKey:))
    }

    private func persistTripCartState() {
        encodeStringSet(tripOwnedItemKeys, forKey: tripOwnedPersistenceKey)
        encodeStringSet(automaticHouseholdOptOutKeys, forKey: automaticHouseholdOptOutPersistenceKey)
        encodeStringSet(resolvedReviewItemKeys, forKey: reviewResolutionPersistenceKey)
    }

    private var automaticHouseholdDefaultsSignature: String {
        planScopedCartItems
            .map(cartItemKey)
            .sorted()
            .joined(separator: "|")
    }

    private func applyAutomaticHouseholdDefaults() {
        let householdCanonicalKeys: Set<String> = [
            "salt", "black pepper", "granulated sugar", "honey"
        ]
        let defaultOwnedKeys = Set(
            planScopedCartItems.compactMap { item -> String? in
                let canonicalKey = ShoppingIngredientCanonicalizer.match(for: item.name).key
                let itemKey = cartItemKey(item)
                guard householdCanonicalKeys.contains(canonicalKey),
                      !itemKey.isEmpty,
                      !automaticHouseholdOptOutKeys.contains(itemKey) else {
                    return nil
                }
                return itemKey
            }
        )
        let updatedOwnedKeys = tripOwnedItemKeys.union(defaultOwnedKeys)
        guard updatedOwnedKeys != tripOwnedItemKeys else { return }
        tripOwnedItemKeys = updatedOwnedKeys
        persistTripCartState()
    }

    private func decodedStringSet(forKey key: String) -> Set<String> {
        guard let data = UserDefaults.standard.data(forKey: key),
              let values = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return Set(values)
    }

    private func encodeStringSet(_ values: Set<String>, forKey key: String) {
        guard let data = try? JSONEncoder().encode(values.sorted()) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    private func resolveProblemItem(_ item: CartProblemItem, correctedName: String) {
        let corrected = correctedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !corrected.isEmpty else { return }
        let key = Self.normalizedIngredientKey(item.name)
        resolvedReviewItemKeys.insert(key)
        persistTripCartState()
        selectedProblemItem = nil
        store.correctMainShopItemName(originalName: item.name, correctedName: corrected)
        toastCenter.show(
            title: "Item corrected",
            subtitle: corrected,
            systemImage: "checkmark.circle.fill"
        )
    }

    private func dismissProblemItem(_ item: CartProblemItem) {
        resolvedReviewItemKeys.insert(Self.normalizedIngredientKey(item.name))
        persistTripCartState()
        selectedProblemItem = nil
    }

    private func openInstacartRunsSheet() {
        isRunLogsPresented = true
        Task {
            let session = await store.freshUserDataSession()
            await instacartRunLogsStore.refresh(
                userID: session?.userID,
                accessToken: session?.accessToken
            )
        }
    }

    private var isInstacartShoppingActivelyRunning: Bool {
        if store.hasLiveInstacartActivity {
            return true
        }

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

    private var activeRecipeIDs: [String] {
        (store.latestPlan?.recipes ?? []).map(\.recipe.id)
    }

    private var cartReloadKey: String {
        guard let latestPlan = store.latestPlan else { return "empty-cart" }
        let batchKey = latestPlan.activeBatchID?.uuidString ?? "legacy"
        let recipeKey = latestPlan.recipes.map(\.recipe.id).joined(separator: "|")
        let groceryKey = mainShopSignature(for: latestPlan.groceryItems)
        let snapshotKey = latestPlan.mainShopSnapshot.map { snapshot in
            "\(snapshot.signature)::\(snapshot.generatedAt.timeIntervalSince1970)"
        } ?? "no-snapshot"
        return [batchKey, recipeKey, groceryKey, snapshotKey].joined(separator: "::")
    }

    private var shoppingListSignature: String {
        let itemKey = visibleReconciledCartItems.map(\.id).joined(separator: "|")
        return itemKey.isEmpty ? "empty" : itemKey
    }

    private var shoppingListPersistenceKey: String {
        "ounje.cart.shopping.v2::\(tripCartPersistenceScope)"
    }

    private var shouldShowEmptyCartState: Bool {
        activeRecipeIDs.isEmpty && displayGroceryItems.isEmpty && visibleReconciledCartItems.isEmpty
    }

    private var shouldShowUnavailableCartState: Bool {
        !activeRecipeIDs.isEmpty
            && !isLoadingIngredients
            && planScopedCartItems.isEmpty
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

    private var visibleReconciledCartItems: [CartGroceryDisplayItem] {
        planScopedCartItems.filter { item in
            !tripOwnedItemKeys.contains(cartItemKey(item))
        }
    }

    private var hasSourceCartContent: Bool {
        !ingredientRows.isEmpty || !displayGroceryItems.isEmpty
    }

    private var hasRenderedCartContent: Bool {
        !ingredientRows.isEmpty || !cartDisplayItems.isEmpty || !reconciledCartItems.isEmpty
    }

    private var shouldShowCartUpdatingBanner: Bool {
        false
    }

    private var cartBuyNowDisabledReason: String? {
        if hasActiveInstacartRun {
            return nil
        }
        guard let latestPlan = store.latestPlan, !latestPlan.recipes.isEmpty else {
            return "Generate a prep first."
        }
        guard visibleReconciledCartItems.isEmpty == false else {
            return store.isRefreshingMainShopSnapshot || isLoadingIngredients
                ? "Shop list is syncing."
                : "No visible shop items to send."
        }
        guard latestPlan.bestQuote?.provider == .instacart
                || store.latestGroceryOrder?.normalizedProvider == "instacart"
                || store.isInstacartProviderConnected else {
            return "Connect Instacart first."
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
        guard let run = activeInstacartRunSummary ?? store.latestInstacartRun else { return nil }
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
        switch (activeInstacartRunSummary ?? store.latestInstacartRun)?.normalizedStatusKind {
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
        if let url = activeInstacartRunSummary?.trackingURL {
            return url
        }
        if let url = store.latestInstacartRun?.trackingURL {
            return url
        }
        guard let raw = store.latestGroceryOrder?.providerTrackingURLString?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return nil
        }
        return URL(string: raw)
    }

    private var activeInstacartRunSummary: InstacartRunLogSummary? {
        for run in [store.latestBlockingInstacartRun, store.latestInstacartRun].compactMap({ $0 }) {
            if ["queued", "running"].contains(run.normalizedRetryState) {
                return run
            }
            if ["queued", "running", "partial"].contains(run.normalizedStatusKind) {
                return run
            }
        }

        if store.hasLiveInstacartActivity {
            return store.latestBlockingInstacartRun ?? store.latestInstacartRun
        }

        return nil
    }

    private var hasActiveInstacartRun: Bool {
        activeInstacartRunSummary != nil
            || store.hasLiveInstacartActivity
            || store.isManualAutoshopRunning
    }

    private var activeInstacartRunTitle: String {
        guard activeInstacartRunSummary != nil else { return "Open active run" }
        return "Open active run"
    }

    private var liveInstacartRunBannerMessage: String? {
        guard hasActiveInstacartRun || store.manualAutoshopErrorMessage != nil else {
            return nil
        }
        return cartBuyNowStatusMessage ?? "Your Instacart run is live."
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
        Task {
            await performCartBuyNowRun(trigger: trigger)
        }
    }

    private func performCartBuyNowRun(trigger: String = "cart_buy_now") async {
        let allowedKeys = visibleMainShopKeysForAutoshop
        let quantityOverrides = visibleMainShopQuantityOverridesForAutoshop
        await store.rerunInstacartShopping(
            trigger: trigger,
            allowedMainShopItemKeys: allowedKeys,
            quantityOverridesByMainShopKey: quantityOverrides
        )
        if let message = store.manualAutoshopErrorMessage?.trimmingCharacters(in: .whitespacesAndNewlines),
           !message.isEmpty {
            toastCenter.show(title: message, destination: nil)
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
            amountText: override == nil ? parsed?.amountText ?? "\(resolvedCount)" : "\(resolvedCount)",
            unitLabel: resolvedUnit,
            baseCount: baseCount
        )
    }

    private func toggleShoppingListMode() {
        withAnimation(OunjeMotion.quickSpring) {
            isShoppingListMode.toggle()
        }
    }

    private func toggleCheckedShoppingItem(_ item: CartGroceryDisplayItem) {
        let key = cartItemKey(item)
        guard !key.isEmpty else { return }
        withAnimation(OunjeMotion.quickSpring) {
            if checkedShoppingItemIDs.contains(key) {
                checkedShoppingItemIDs.remove(key)
            } else {
                checkedShoppingItemIDs.insert(key)
            }
        }
        persistShoppingListState()
    }

    private func loadShoppingListState() {
        guard let data = UserDefaults.standard.data(forKey: shoppingListPersistenceKey),
              let ids = try? JSONDecoder().decode([String].self, from: data) else {
            checkedShoppingItemIDs = []
            return
        }
        let visibleKeys = Set(planScopedCartItems.map(cartItemKey))
        checkedShoppingItemIDs = Set(ids).intersection(visibleKeys)
    }

    private func persistShoppingListState() {
        let ids = Array(checkedShoppingItemIDs).sorted()
        guard let data = try? JSONEncoder().encode(ids) else { return }
        UserDefaults.standard.set(data, forKey: shoppingListPersistenceKey)
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

        let leadingUnit = normalized.split(separator: " ").first.map(String.init) ?? normalized
        if ["g", "gram", "grams"].contains(leadingUnit) {
            return "g"
        }
        if ["kg", "kilogram", "kilograms"].contains(leadingUnit) {
            return "kg"
        }
        if ["oz", "ounce", "ounces"].contains(leadingUnit) {
            return "oz"
        }
        if ["lb", "lbs", "pound", "pounds"].contains(leadingUnit) {
            return "lb"
        }
        if ["ml", "milliliter", "milliliters", "millilitre", "millilitres"].contains(leadingUnit) {
            return "ml"
        }
        if ["l", "liter", "liters", "litre", "litres"].contains(leadingUnit) {
            return "l"
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
        in items: [CartGroceryDisplayItem]
    ) -> Bool {
        let candidateKey = Self.semanticMainShopMergeKey(candidateName)
        guard !candidateKey.isEmpty else { return false }

        return items.contains { item in
            let itemKey = Self.semanticMainShopMergeKey(item.name)
            return itemKey == candidateKey
        }
    }

    private func mergeLexicallyIdenticalMainShopItems(_ items: [CartGroceryDisplayItem]) -> [CartGroceryDisplayItem] {
        struct Aggregate {
            var item: CartGroceryDisplayItem
            var totalAmount: Double
            var preferredUnitLabel: String
            var supportingParts: Set<String>
        }

        var aggregates: [String: Aggregate] = [:]
        var order: [String] = []

        for item in items {
            guard !Self.isExcludedMainShopIngredient(item.name) else { continue }
            let displayName = Self.canonicalMainShopDisplayName(item.name)
            let parsed = CartQuantityFormatter.mainShopDisplayComponents(from: item.quantityText)
            let resolvedMeasurement = ShoppingIngredientCanonicalizer.resolvedMeasurement(
                amount: parsed?.amount ?? 1,
                unit: parsed?.unitLabel ?? "items"
            )
            let rawUnit = resolvedMeasurement.unit
            let ingredientKey = Self.semanticMainShopMergeKey(displayName)
            guard !ingredientKey.isEmpty else { continue }
            let key = ingredientKey

            let amount = max(0, resolvedMeasurement.amount)
            let supportingParts = splitSupportingText(item.supportingText)

            if var existing = aggregates[key] {
                let mergedMeasurement = ShoppingIngredientCanonicalizer.mergedMeasurement(
                    amount: existing.totalAmount,
                    unit: existing.preferredUnitLabel,
                    adding: amount,
                    unit: rawUnit
                )
                existing.totalAmount = mergedMeasurement.amount
                existing.preferredUnitLabel = mergedMeasurement.unit
                existing.supportingParts.formUnion(supportingParts)
                let preferredItem = preferredMergedMainShopItem(existing.item, item)
                let displayCount = max(1, Int(ceil(existing.totalAmount)))
                existing.preferredUnitLabel = normalizedMainShopUnitLabel(
                    existing.preferredUnitLabel,
                    count: displayCount
                )

                let chosenImage = preferredItem.imageURL ?? existing.item.imageURL ?? item.imageURL
                let chosenSection = preferredItem.sectionKind.rawValue < existing.item.sectionKind.rawValue
                    ? preferredItem.sectionKind
                    : existing.item.sectionKind

                existing.item = CartGroceryDisplayItem(
                    name: Self.canonicalMainShopDisplayName(preferredItem.name),
                    quantityText: CartQuantityFormatter.format(
                        amount: existing.totalAmount,
                        unit: existing.preferredUnitLabel
                    ),
                    supportingText: combinedSupportingText(from: existing.supportingParts),
                    imageURL: chosenImage,
                    estimatedPriceText: preferredItem.estimatedPriceText ?? existing.item.estimatedPriceText ?? item.estimatedPriceText,
                    estimatedPriceValue: existing.item.estimatedPriceValue + item.estimatedPriceValue,
                    sectionKind: chosenSection,
                    removalKey: preferredItem.removalKey ?? existing.item.removalKey ?? item.removalKey ?? ingredientKey
                )
                aggregates[key] = existing
            } else {
                let displayCount = max(1, Int(ceil(amount)))
                let normalizedUnit = normalizedMainShopUnitLabel(rawUnit, count: displayCount)
                aggregates[key] = Aggregate(
                    item: CartGroceryDisplayItem(
                        name: displayName,
                        quantityText: CartQuantityFormatter.format(amount: amount, unit: normalizedUnit),
                        supportingText: combinedSupportingText(from: supportingParts),
                        imageURL: item.imageURL,
                        estimatedPriceText: item.estimatedPriceText,
                        estimatedPriceValue: item.estimatedPriceValue,
                        sectionKind: item.sectionKind,
                        removalKey: ingredientKey
                    ),
                    totalAmount: amount,
                    preferredUnitLabel: normalizedUnit,
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
                let ingredientKey = Self.semanticMainShopMergeKey(component.displayName)
                guard !ingredientKey.isEmpty else { continue }
                let unitKey = ShoppingIngredientCanonicalizer.normalizedUnitKey(component.unit)
                let key = "\(ingredientKey)::\(unitKey)"

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

        return (CartQuantityFormatter.format(amount: amount, unit: unit), supportingText)
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
        ShoppingIngredientCanonicalizer.isNonShoppingWater(value)
    }

    private static func semanticMainShopMergeKey(_ value: String) -> String {
        ShoppingIngredientCanonicalizer.match(for: value).key
    }

    private static func canonicalMainShopDisplayName(_ rawName: String) -> String {
        ShoppingIngredientCanonicalizer.match(for: rawName).displayName
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
        let preserveVisibleContent = hasRenderedCartContent
        isLoadingIngredients = !preserveVisibleContent
        ingredientLoadError = nil
        if !preserveVisibleContent {
            ingredientRows = []
            cartDisplayItems = []
            reconciledCartItems = []
            boxedCartCoverageSummary = nil
        }
        focusedRecipeID = nil
        defer { isLoadingIngredients = false }

        do {
            if forceRebuild {
                _ = await store.refreshLatestPlanMainShopSnapshotIfNeeded(forceRebuild: true)
                guard !Task.isCancelled else { return }
            }

            let storedSnapshot = allowSnapshotFastPath
                ? latestPlan.mainShopSnapshot.flatMap { snapshot in
                    snapshot.signature == signature
                        && snapshot.items.allSatisfy { $0.sectionKindRawValue != nil }
                        ? snapshot
                        : nil
                }
                : nil
            let cachedSnapshot: MainShopSnapshot?
            if let storedSnapshot {
                cachedSnapshot = storedSnapshot
            } else {
                cachedSnapshot = await CartSupportWarmupService.cachedSnapshot(for: latestPlan)
            }

            let initialSnapshot: MainShopSnapshot
            if let cachedSnapshot, !forceRebuild {
                initialSnapshot = cachedSnapshot
            } else {
                let groceryItems = latestPlan.groceryItems
                initialSnapshot = await Task.detached(priority: .userInitiated) {
                    MainShopSnapshotBuilder.buildLocalSnapshot(for: groceryItems)
                }.value
                guard !Task.isCancelled else { return }
                await CartSupportWarmupCache.shared.store(snapshot: initialSnapshot, for: latestPlan)
            }

            guard let planAfterSnapshot = store.latestPlan,
                  planAfterSnapshot.id == latestPlan.id,
                  mainShopSignature(for: planAfterSnapshot.groceryItems) == signature else {
                return
            }

            if hasMainShopItems {
                let initialItems = makeReconciledCartItems(fromSnapshotItems: initialSnapshot.items)
                reconciledCartItems = initialItems
                cartDisplayItems = initialItems
                boxedCartCoverageSummary = makeBoxedCoverageSummary(
                    fromSnapshotSummary: initialSnapshot.coverageSummary
                )
                isLoadingIngredients = false
                prewarmCartArtwork(rows: [], cartItems: [], reconciledItems: initialItems)
            }

            let rows = try await cachedOrLoadedPrepRecipeIngredientRows(from: latestPlan)
            guard !Task.isCancelled else { return }
            guard let activePlan = store.latestPlan,
                  activePlan.id == latestPlan.id,
                  mainShopSignature(for: activePlan.groceryItems) == signature else {
                return
            }
            ingredientRows = rows
            if reconciledCartItems.isEmpty {
                let fallbackItems = ensureMainShopCoverage(
                    reconciledItems: [],
                    from: activePlan.groceryItems,
                    ingredientRows: rows
                )
                reconciledCartItems = mergeLexicallyIdenticalMainShopItems(fallbackItems)
            }
            reconciledCartItems = applyingIngredientArtwork(
                to: reconciledCartItems,
                from: rows
            )
            cartDisplayItems = reconciledCartItems
            ingredientLoadError = nil
            focusedRecipeID = nil
            prewarmCartArtwork(
                rows: rows,
                cartItems: cartDisplayItems,
                reconciledItems: reconciledCartItems
            )
        } catch {
            if !preserveVisibleContent {
                ingredientLoadError = nil
                ingredientRows = []
            } else {
                ingredientLoadError = nil
            }
        }
    }

    private func applyingIngredientArtwork(
        to items: [CartGroceryDisplayItem],
        from rows: [SupabaseRecipeIngredientRow]
    ) -> [CartGroceryDisplayItem] {
        var artworkByKey: [String: URL] = [:]
        for row in rows {
            guard let imageURL = row.imageURL else { continue }
            let normalizedKey = Self.normalizedIngredientKey(row.displayTitle)
            let canonicalKey = ShoppingIngredientCanonicalizer.match(for: row.displayTitle).key
            if !normalizedKey.isEmpty {
                artworkByKey[normalizedKey] = artworkByKey[normalizedKey] ?? imageURL
            }
            if !canonicalKey.isEmpty {
                artworkByKey[canonicalKey] = artworkByKey[canonicalKey] ?? imageURL
            }
        }

        guard !artworkByKey.isEmpty else { return items }
        return items.map { item in
            guard item.imageURL == nil else { return item }
            let normalizedKey = Self.normalizedIngredientKey(item.removalKey ?? item.name)
            let canonicalKey = ShoppingIngredientCanonicalizer.match(for: item.name).key
            guard let imageURL = artworkByKey[normalizedKey] ?? artworkByKey[canonicalKey] else {
                return item
            }
            return CartGroceryDisplayItem(
                name: item.name,
                quantityText: item.quantityText,
                supportingText: item.supportingText,
                imageURL: imageURL,
                estimatedPriceText: item.estimatedPriceText,
                estimatedPriceValue: item.estimatedPriceValue,
                sectionKind: item.sectionKind,
                removalKey: item.removalKey
            )
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
        var seen = Set<String>()
        let urls = (
            reconciledItems.compactMap(\.imageURL)
                + rows.compactMap(\.imageURL)
                + cartItems.compactMap(\.imageURL)
        )
        .filter { seen.insert($0.absoluteString).inserted }
        .prefix(12)
        guard !urls.isEmpty else { return }
        CartArtworkImageLoader.prewarm(urls: Array(urls))
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

private extension PrepBatch {
    var flagshipImageURL: URL? {
        for plannedRecipe in recipes {
            for candidate in [
                plannedRecipe.recipe.cardImageURLString,
                plannedRecipe.recipe.heroImageURLString,
            ] {
                guard let value = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !value.isEmpty,
                      let url = URL(string: value) else {
                    continue
                }
                return url
            }
        }
        return nil
    }
}

private struct CartPreferenceText: View {
    let text: String
    let size: CGFloat
    let color: Color
    let style: RecipeTypographyStyle
    let cleanWeight: Font.Weight
    let usesDisplayFont: Bool

    init(
        _ text: String,
        size: CGFloat,
        color: Color = OunjePalette.primaryText,
        style: RecipeTypographyStyle,
        cleanWeight: Font.Weight = .semibold,
        usesDisplayFont: Bool = false
    ) {
        self.text = text
        self.size = size
        self.color = color
        self.style = style
        self.cleanWeight = cleanWeight
        self.usesDisplayFont = usesDisplayFont
    }

    var body: some View {
        Group {
            if style == .playful {
                SleeScriptDisplayText(text, size: size, color: color)
            } else if usesDisplayFont {
                HelveticaNowDisplayText(text, size: size, color: color, weight: cleanWeight)
            } else {
                Text(text)
                    .font(.system(size: size, weight: cleanWeight))
                    .tracking(0)
                    .foregroundStyle(color)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }
}

private struct CartPlanFlagshipArtwork: View {
    let imageURL: URL?
    let title: String
    var size: CGFloat = 54

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(OunjePalette.panel)

            if imageURL != nil {
                CartCachedArtworkView(imageURL: imageURL) {
                    fallback
                }
            } else {
                fallback
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(OunjePalette.stroke.opacity(0.8), lineWidth: 1)
        )
    }

    private var fallback: some View {
        Text(IngredientMonogramFormatter.monogram(for: title))
            .sleeDisplayFont(size * 0.34)
            .foregroundStyle(OunjePalette.softCream.opacity(0.78))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

enum CartAisle: Int, CaseIterable, Identifiable {
    case produce
    case meat
    case dairy
    case pantry
    case other

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .produce: return "Produce"
        case .meat: return "Meat"
        case .dairy: return "Dairy"
        case .pantry: return "Pantry"
        case .other: return "Other"
        }
    }

    static func classify(_ item: CartGroceryDisplayItem) -> CartAisle {
        let name = item.name.lowercased()
        let containsAny: ([String]) -> Bool = { terms in
            terms.contains { name.contains($0) }
        }

        if [.dryGoods, .prepared, .pantry].contains(item.sectionKind) || containsAny([
            "adobo sauce", "black pepper", "cayenne", "chili flake", "cinnamon",
            "cocoa", "coriander", "cumin", "flour", "granule", "honey", "noodle",
            "oil", "paprika", "pasta", "peppercorn", "powder", "rice", "salt",
            "sauce", "seasoning", "spice", "sugar", "syrup", "turmeric", "canned",
            "tin"
        ]) {
            return .pantry
        }
        if containsAny([
            "apple", "avocado", "banana", "berry", "berries", "broccoli", "cabbage",
            "carrot", "celery", "cilantro", "cucumber", "garlic", "ginger", "herb",
            "lemon", "lime", "lettuce", "mango", "mushroom", "onion", "orange",
            "bell pepper", "chili pepper", "jalape", "poblano", "plantain", "potato",
            "scallion", "spinach", "tomato", "zucchini"
        ]) {
            return .produce
        }
        if containsAny([
            "beef", "chicken", "fish", "lamb", "meat", "pork", "salmon", "sausage",
            "shrimp", "steak", "turkey", "bacon", "mince", "ground"
        ]) {
            return .meat
        }
        if containsAny([
            "butter", "cheese", "cream", "egg", "milk", "yogurt", "yoghurt", "mozzarella",
            "parmesan", "ricotta", "custard"
        ]) {
            return .dairy
        }
        if containsAny([
            "bread", "cereal", "chocolate"
        ]) {
            return .pantry
        }
        return .other
    }
}

struct CartAisleGroup: Identifiable {
    let aisle: CartAisle
    let items: [CartGroceryDisplayItem]

    var id: CartAisle { aisle }
}

struct CartProblemItem: Identifiable {
    let name: String
    var id: String { name.lowercased() }
}

struct CartOperationalItemRow: View, Equatable {
    let item: CartGroceryDisplayItem
    let quantityAmountText: String
    let quantityUnitLabel: String
    let isShoppingMode: Bool
    let isChecked: Bool
    var isAlreadyHave = false
    var isTransferSelectionMode = false
    var isTransferSelected = false
    let typographyStyle: RecipeTypographyStyle
    let onTap: () -> Void
    let onDecrease: () -> Void
    let onIncrease: () -> Void

    static func == (lhs: CartOperationalItemRow, rhs: CartOperationalItemRow) -> Bool {
        lhs.item == rhs.item
            && lhs.quantityAmountText == rhs.quantityAmountText
            && lhs.quantityUnitLabel == rhs.quantityUnitLabel
            && lhs.isShoppingMode == rhs.isShoppingMode
            && lhs.isChecked == rhs.isChecked
            && lhs.isAlreadyHave == rhs.isAlreadyHave
            && lhs.isTransferSelectionMode == rhs.isTransferSelectionMode
            && lhs.isTransferSelected == rhs.isTransferSelected
            && lhs.typographyStyle == rhs.typographyStyle
    }

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onTap) {
                HStack(spacing: 12) {
                    artwork

                    CartPreferenceText(
                        item.name,
                        size: 16,
                        color: (isChecked || isAlreadyHave) ? OunjePalette.secondaryText : OunjePalette.primaryText,
                        style: typographyStyle,
                        cleanWeight: .semibold
                    )
                    .strikethrough(isChecked, color: OunjePalette.secondaryText)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isTransferSelectionMode {
                Button(action: onTap) {
                    Image(systemName: isTransferSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 23, weight: .semibold))
                        .foregroundStyle(isTransferSelected ? OunjePalette.primaryText : OunjePalette.secondaryText.opacity(0.72))
                        .frame(width: 42, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isTransferSelected ? "Deselect \(item.name)" : "Select \(item.name)")
            } else if isAlreadyHave {
                Button(action: onTap) {
                    Image(systemName: "nosign")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(OunjePalette.secondaryText)
                        .frame(width: 42, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Already have \(item.name). Add back to shop list")
            } else if isShoppingMode {
                Button(action: onTap) {
                    if isChecked {
                        Image(systemName: "checkmark.circle.fill")
                            .symbolRenderingMode(.palette)
                            .font(.system(size: 23, weight: .semibold))
                            .foregroundStyle(OunjePalette.background, OunjePalette.softCream)
                            .frame(width: 30, height: 44)
                    } else {
                        Image(systemName: "circle")
                            .font(.system(size: 23, weight: .semibold))
                            .foregroundStyle(OunjePalette.secondaryText.opacity(0.7))
                            .frame(width: 30, height: 44)
                    }
                }
                .buttonStyle(.plain)
            } else {
                HStack(spacing: 8) {
                    quantityButton(systemName: "minus", action: onDecrease)

                    VStack(spacing: 1) {
                        Text(quantityAmountText)
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(OunjePalette.primaryText)
                            .lineLimit(1)

                        Text(quantityUnitLabel)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(OunjePalette.secondaryText)
                            .lineLimit(1)
                    }
                    .frame(width: 42)

                    quantityButton(systemName: "plus", action: onIncrease)
                }
            }
        }
        .padding(.vertical, 8)
        .saturation(isAlreadyHave ? 0 : 1)
        .opacity(isAlreadyHave && !isTransferSelectionMode ? 0.48 : 1)
    }

    private var artwork: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(item.imageURL == nil ? OunjePalette.surface : OunjePalette.panel)

            if item.imageURL != nil {
                CartCachedArtworkView(imageURL: item.imageURL) {
                    fallbackArtwork
                }
            } else {
                fallbackArtwork
            }
        }
        .frame(width: 48, height: 48)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func quantityButton(systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(OunjePalette.primaryText)
                .frame(width: 32, height: 32)
                .background(Circle().fill(OunjePalette.surface))
        }
        .buttonStyle(.plain)
    }

    private var fallbackArtwork: some View {
        Text(IngredientMonogramFormatter.monogram(for: item.name))
            .sleeDisplayFont(17)
            .foregroundStyle(OunjePalette.softCream.opacity(0.78))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct CartPlanSelectorSheet: View {
    @Environment(\.dismiss) private var dismiss
    let batches: [PrepBatch]
    let activeBatchID: UUID?
    let typographyStyle: RecipeTypographyStyle
    let onSelect: (PrepBatch) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            OunjeSheetHeader(
                title: "Choose plan",
                titleStyle: .recipe(typographyStyle),
                onClose: { dismiss() }
            )

            VStack(spacing: 0) {
                ForEach(Array(batches.enumerated()), id: \.element.id) { index, batch in
                    Button {
                        onSelect(batch)
                        dismiss()
                    } label: {
                        HStack(spacing: 12) {
                            CartPlanFlagshipArtwork(
                                imageURL: batch.flagshipImageURL,
                                title: batch.name,
                                size: 48
                            )

                            VStack(alignment: .leading, spacing: 3) {
                                CartPreferenceText(
                                    batch.name,
                                    size: 17,
                                    style: typographyStyle,
                                    cleanWeight: .bold
                                )
                                .lineLimit(1)

                                Text("Plan · \(batch.recipes.count) \(batch.recipes.count == 1 ? "recipe" : "recipes")")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(OunjePalette.secondaryText)
                            }
                            Spacer()
                            if batch.id == activeBatchID {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 19, weight: .semibold))
                                    .foregroundStyle(OunjePalette.accent)
                            }
                        }
                        .frame(minHeight: 64)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if index < batches.count - 1 {
                        Divider().background(OunjePalette.stroke)
                    }
                }
            }
        }
        .padding(.horizontal, OunjeLayout.sheetHorizontalPadding)
        .padding(.top, OunjeLayout.sheetTopPadding)
        .padding(.bottom, OunjeLayout.sheetBottomPadding)
        .ounjeSheetSurface()
    }
}

struct CartItemDetailSheet: View {
    @Environment(\.dismiss) private var dismiss
    let item: CartGroceryDisplayItem
    let quantityUnitLabel: String
    let isAlreadyHave: Bool
    let sourceEntries: [CartMainShopMappingSourceEntry]
    let onDecreaseQuantity: () -> Void
    let onIncreaseQuantity: () -> Void
    let onToggleAlreadyHave: () -> Void
    let onRemove: () -> Void
    @State private var displayedQuantityCount: Int

    init(
        item: CartGroceryDisplayItem,
        quantityCount: Int,
        quantityUnitLabel: String,
        isAlreadyHave: Bool,
        sourceEntries: [CartMainShopMappingSourceEntry],
        onDecreaseQuantity: @escaping () -> Void,
        onIncreaseQuantity: @escaping () -> Void,
        onToggleAlreadyHave: @escaping () -> Void,
        onRemove: @escaping () -> Void
    ) {
        self.item = item
        self.quantityUnitLabel = quantityUnitLabel
        self.isAlreadyHave = isAlreadyHave
        self.sourceEntries = sourceEntries
        self.onDecreaseQuantity = onDecreaseQuantity
        self.onIncreaseQuantity = onIncreaseQuantity
        self.onToggleAlreadyHave = onToggleAlreadyHave
        self.onRemove = onRemove
        _displayedQuantityCount = State(initialValue: quantityCount)
    }

    private var uniqueSources: [CartMainShopMappingSourceEntry] {
        var seen = Set<String>()
        return sourceEntries.filter { seen.insert($0.recipeTitle.lowercased()).inserted }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .top, spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(OunjePalette.surface)
                        CartCachedArtworkView(imageURL: item.imageURL) {
                            Text(IngredientMonogramFormatter.monogram(for: item.name))
                                .sleeDisplayFont(21)
                                .foregroundStyle(OunjePalette.softCream.opacity(0.8))
                        }
                    }
                    .frame(width: 64, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                    VStack(alignment: .leading, spacing: 5) {
                        Text(item.name)
                            .sleeDisplayFont(21)
                            .foregroundStyle(OunjePalette.primaryText)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("Total for this plan")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(OunjePalette.secondaryText)
                    }

                    Spacer()
                    OunjeSheetCloseButton {
                        dismiss()
                    }
                }

                HStack {
                    Text("Quantity")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(OunjePalette.primaryText)
                    Spacer()
                    HStack(spacing: 14) {
                        Button {
                            onDecreaseQuantity()
                            if displayedQuantityCount <= 1 {
                                dismiss()
                            } else {
                                displayedQuantityCount -= 1
                            }
                        } label: {
                            Image(systemName: "minus")
                                .font(.system(size: 13, weight: .bold))
                                .frame(width: 36, height: 36)
                        }
                        Text("\(displayedQuantityCount) \(quantityUnitLabel)")
                            .font(.system(size: 15, weight: .bold))
                            .monospacedDigit()
                            .frame(minWidth: 76)
                        Button {
                            onIncreaseQuantity()
                            displayedQuantityCount += 1
                        } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 13, weight: .bold))
                                .frame(width: 36, height: 36)
                        }
                    }
                    .foregroundStyle(OunjePalette.primaryText)
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Used by")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(OunjePalette.primaryText)

                    if uniqueSources.isEmpty {
                        Text("This plan")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(OunjePalette.secondaryText)
                    } else {
                        ForEach(uniqueSources) { source in
                            HStack(spacing: 10) {
                                Circle()
                                    .fill(OunjePalette.accent.opacity(0.72))
                                    .frame(width: 6, height: 6)
                                Text(source.recipeTitle)
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundStyle(OunjePalette.primaryText)
                                Spacer()
                                if let quantityText = source.quantityText, !quantityText.isEmpty {
                                    Text(quantityText)
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(OunjePalette.secondaryText)
                                }
                            }
                        }
                    }
                }

                Divider().background(OunjePalette.stroke)

                Button {
                    onToggleAlreadyHave()
                    dismiss()
                } label: {
                    Label(
                        isAlreadyHave ? "Add back to shop list" : "Already have this",
                        systemImage: isAlreadyHave ? "cart.badge.plus" : "checkmark.circle"
                    )
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(OunjePalette.primaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(height: 46)
                }
                .buttonStyle(.plain)

                Button(role: .destructive) {
                    onRemove()
                    dismiss()
                } label: {
                    Label("Remove from cart", systemImage: "trash")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(height: 46)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 22)
            .padding(.top, 20)
            .padding(.bottom, 28)
        }
        .background(OunjePalette.background.ignoresSafeArea())
    }
}

struct CartProblemItemSheet: View {
    @Environment(\.dismiss) private var dismiss
    let item: CartProblemItem
    let onCorrect: (String) -> Void
    let onRemove: () -> Void
    @State private var correctedName: String

    init(
        item: CartProblemItem,
        onCorrect: @escaping (String) -> Void,
        onRemove: @escaping () -> Void
    ) {
        self.item = item
        self.onCorrect = onCorrect
        self.onRemove = onRemove
        _correctedName = State(initialValue: item.name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Review item")
                    .biroHeaderFont(25)
                    .foregroundStyle(OunjePalette.primaryText)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(OunjePalette.secondaryText)
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)
            }

            TextField("Ingredient name", text: $correctedName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(OunjePalette.primaryText)
                .padding(.horizontal, 14)
                .frame(height: 50)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(OunjePalette.surface)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(OunjePalette.stroke, lineWidth: 1)
                        )
                )

            Button {
                onCorrect(correctedName)
                dismiss()
            } label: {
                Text("Use this name")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(OunjePalette.background)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(RoundedRectangle(cornerRadius: 8).fill(OunjePalette.accent))
            }
            .buttonStyle(.plain)
            .disabled(correctedName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            Button(role: .destructive) {
                onRemove()
                dismiss()
            } label: {
                Text("Remove from this cart")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 42)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 22)
        .padding(.top, 18)
        .background(OunjePalette.background.ignoresSafeArea())
    }
}

struct CartShoppingActionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var firstRunGuide: FirstRunGuideCoordinator
    @State private var isChoosingProvider = false
    let planName: String
    let itemCount: Int
    let instacartTitle: String
    let instacartSubtitle: String
    let isInstacartDisabled: Bool
    let choosesProvider: Bool
    let onChecklist: () -> Void
    let onInstacart: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            OunjeSheetHeader(
                title: isChoosingProvider ? "Choose a store" : "Shop now",
                subtitle: isChoosingProvider
                    ? "Ounje builds the cart for your review."
                    : "\(planName) · \(itemCount) \(itemCount == 1 ? "item" : "items")",
                onClose: {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    dismiss()
                }
            )

            VStack(spacing: 0) {
                if isChoosingProvider {
                    CartShoppingChoiceButton(
                        title: instacartTitle,
                        subtitle: instacartSubtitle,
                        icon: .instacart,
                        isDisabled: isInstacartDisabled,
                        action: onInstacart
                    )

                    Divider()
                        .overlay(OunjePalette.stroke)
                        .padding(.leading, 66)

                    CartShoppingChoiceButton(
                        title: "Walmart",
                        subtitle: "Not available yet",
                        icon: .walmart,
                        isDisabled: true,
                        action: {}
                    )
                } else {
                    CartShoppingChoiceButton(
                        title: "Use as checklist",
                        subtitle: "Shop and tick off items in Ounje.",
                        icon: .checklist,
                        action: onChecklist
                    )
                    .firstRunGuideTarget(
                        .checklistOption,
                        enabled: firstRunGuide.phase == .cartChecklistOption
                    )

                    Divider()
                        .overlay(OunjePalette.stroke)
                        .padding(.leading, 66)

                    CartShoppingChoiceButton(
                        title: "Let Ounje shop for you",
                        subtitle: "Instacart and Walmart",
                        icon: .shoppingProviders,
                        isDisabled: isInstacartDisabled,
                        action: {
                            if choosesProvider {
                                withAnimation(OunjeMotion.quickSpring) {
                                    isChoosingProvider = true
                                }
                            } else {
                                onInstacart()
                            }
                        }
                    )
                }
            }
            .background(
                RoundedRectangle(cornerRadius: OunjeLayout.panelCornerRadius, style: .continuous)
                    .fill(OunjePalette.panel)
                    .overlay(
                        RoundedRectangle(cornerRadius: OunjeLayout.panelCornerRadius, style: .continuous)
                            .stroke(OunjePalette.stroke, lineWidth: 1)
                    )
            )
        }
        .padding(.horizontal, OunjeLayout.sheetHorizontalPadding)
        .padding(.top, OunjeLayout.sheetTopPadding)
        .padding(.bottom, OunjeLayout.sheetBottomPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .ounjeSheetSurface()
        .firstRunGuideHost()
    }
}

enum CartShoppingChoiceIcon {
    case checklist
    case shoppingProviders
    case instacart
    case walmart
}

struct CartShoppingChoiceButton: View {
    let title: String
    let subtitle: String
    let icon: CartShoppingChoiceIcon
    var isDisabled = false
    let action: () -> Void

    var body: some View {
        OunjeSheetActionRow(
            title: title,
            subtitle: subtitle,
            isDisabled: isDisabled,
            action: action
        ) {
            choiceIcon
                .frame(width: 54, height: 44)
        }
    }

    @ViewBuilder
    private var choiceIcon: some View {
        switch icon {
        case .checklist:
            checklistIcon
        case .shoppingProviders:
            shoppingProviderIcons
        case .instacart:
            providerIcon(named: "InstacartAppIcon", accessibilityLabel: "Instacart")
        case .walmart:
            providerIcon(named: "WalmartAppIcon", accessibilityLabel: "Walmart")
        }
    }

    private func providerIcon(named imageName: String, accessibilityLabel: String) -> some View {
        Image(imageName)
            .resizable()
            .scaledToFill()
            .frame(width: 42, height: 42)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .saturation(isDisabled ? 0 : 1)
            .opacity(isDisabled ? 0.55 : 1)
            .accessibilityLabel(accessibilityLabel)
    }

    private var checklistIcon: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(OunjePalette.softCream.opacity(isDisabled ? 0.05 : 0.11))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(OunjePalette.softCream.opacity(0.16), lineWidth: 1)
                )

            Image("NotebookPenIcon")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 25, height: 25)
                .foregroundStyle(isDisabled ? OunjePalette.secondaryText : OunjePalette.softCream)
        }
        .frame(width: 42, height: 42)
        .accessibilityHidden(true)
    }

    private var shoppingProviderIcons: some View {
        ZStack {
            Image("WalmartAppIcon")
                .resizable()
                .scaledToFill()
                .frame(width: 36, height: 36)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(OunjePalette.background.opacity(0.85), lineWidth: 1)
                )
                .rotationEffect(.degrees(7))
                .offset(x: 8, y: 5)

            Image("InstacartAppIcon")
                .resizable()
                .scaledToFill()
                .frame(width: 36, height: 36)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(OunjePalette.background.opacity(0.85), lineWidth: 1)
                )
                .rotationEffect(.degrees(-7))
                .offset(x: -7, y: -4)
                .zIndex(1)
        }
        .frame(width: 54, height: 44)
        .saturation(isDisabled ? 0 : 1)
        .opacity(isDisabled ? 0.55 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Instacart and Walmart")
    }
}

struct CartGroceryDisplayItem: Identifiable, Hashable {
    var id: String {
        let stableKey = (removalKey.flatMap { $0.isEmpty ? nil : $0 } ?? name).lowercased()
        return "\(sectionKind.rawValue)::\(stableKey)"
    }
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
    let amountText: String
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

                Text("Add recipes to a plan and Ounje will build the shopping list here.")
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

struct CartUnavailableState: View {
    let onRetry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(OunjePalette.secondaryText)

            Text("Shopping items are not ready yet")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(OunjePalette.primaryText)

            Text("Your plan is intact. Try building its shopping list again.")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(OunjePalette.secondaryText)

            Button("Try again", action: onRetry)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(OunjePalette.primaryText)
                .buttonStyle(.plain)
                .padding(.horizontal, 14)
                .frame(height: 38)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(OunjePalette.surface)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(OunjePalette.stroke, lineWidth: 1)
                        )
                )
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 18)
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

struct CookbookSavedSearchField: View {
    @Binding var text: String
    let placeholder: String
    @FocusState private var isFocused: Bool

    private var hasQuery: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(isFocused ? OunjePalette.primaryText : OunjePalette.secondaryText)

            TextField("", text: $text, prompt: Text(placeholder).foregroundColor(OunjePalette.secondaryText))
                .textFieldStyle(.plain)
                .font(.system(size: 16, weight: .medium, design: .rounded))
                .foregroundStyle(OunjePalette.primaryText)
                .lineLimit(1)
                .submitLabel(.search)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .focused($isFocused)

            if hasQuery {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(OunjePalette.secondaryText.opacity(0.85))
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear saved recipe search")
            }
        }
        .padding(.leading, 15)
        .padding(.trailing, hasQuery ? 8 : 15)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(OunjePalette.surface.opacity(0.96))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(isFocused ? OunjePalette.primaryText.opacity(0.20) : OunjePalette.stroke, lineWidth: 1)
                )
        )
        .animation(.easeInOut(duration: 0.16), value: hasQuery)
        .animation(.easeInOut(duration: 0.16), value: isFocused)
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

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 12
        configuration.httpMaximumConnectionsPerHost = 4
        configuration.urlCache = URLCache(
            memoryCapacity: 16 * 1_024 * 1_024,
            diskCapacity: 96 * 1_024 * 1_024
        )
        return URLSession(configuration: configuration)
    }()

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
                trimCacheIfNeeded()
            }
            return image
        }

        let task = Task.detached(priority: .utility) { await Self.loadThumbnail(from: url) }

        inFlight[key] = task
        let image = await task.value
        inFlight[key] = nil
        if let image {
            cache[key] = image
            trimCacheIfNeeded()
        }
        return image
    }

    func prewarm(urls: [URL]) {
        for url in urls.prefix(12) {
            let key = url.absoluteString
            guard cache[key] == nil, inFlight[key] == nil else { continue }
            inFlight[key] = Task.detached(priority: .utility) { await Self.loadThumbnail(from: url) }
        }
    }

    private func trimCacheIfNeeded() {
        guard cache.count > 96 else { return }
        for key in cache.keys.prefix(cache.count - 96) {
            cache[key] = nil
        }
    }

    private static func loadThumbnail(from url: URL) async -> UIImage? {
        do {
            var request = URLRequest(url: url)
            request.cachePolicy = .returnCacheDataElseLoad
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200 ... 299).contains(httpResponse.statusCode),
                  data.count <= 12 * 1_024 * 1_024,
                  let source = CGImageSourceCreateWithData(data as CFData, nil) else {
                return nil
            }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: 192
            ]
            guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(
                source,
                0,
                options as CFDictionary
            ) else {
                return nil
            }
            return UIImage(cgImage: thumbnail)
        } catch {
            return nil
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
        let loadedImage = await CartArtworkImageRepository.shared.image(for: url)
        guard currentKey == key else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            image = loadedImage
        }
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
    var isShoppingListMode = false
    var isChecked = false
    var onDecreaseQuantity: (() -> Void)? = nil
    var onIncreaseQuantity: (() -> Void)? = nil
    var onToggleChecked: (() -> Void)? = nil
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
            .opacity(isChecked ? 0.45 : 1)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.name)
                    .sleeDisplayFont(16)
                    .foregroundStyle(isChecked ? OunjePalette.secondaryText : OunjePalette.primaryText)
                    .strikethrough(isChecked, color: OunjePalette.secondaryText.opacity(0.85))
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)

                if let supportingText = item.supportingText, !supportingText.isEmpty {
                    Text(supportingText)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(OunjePalette.secondaryText.opacity(0.82))
                        .strikethrough(isChecked, color: OunjePalette.secondaryText.opacity(0.7))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 3) {
                if isShoppingListMode {
                    Button(action: { onToggleChecked?() }) {
                        if isChecked {
                            Image(systemName: "checkmark.circle.fill")
                                .symbolRenderingMode(.palette)
                                .font(.system(size: 27, weight: .semibold))
                                .foregroundStyle(OunjePalette.background, OunjePalette.softCream)
                                .frame(width: 44, height: 44)
                                .contentShape(Circle())
                        } else {
                            Image(systemName: "circle")
                                .font(.system(size: 27, weight: .semibold))
                                .foregroundStyle(OunjePalette.secondaryText.opacity(0.72))
                                .frame(width: 44, height: 44)
                                .contentShape(Circle())
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(isChecked ? "Mark \(item.name) as not picked" : "Mark \(item.name) as picked")
                } else {
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
            }
            .frame(width: 122, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
        .onTapGesture {
            guard isShoppingListMode else { return }
            onToggleChecked?()
        }
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
        let amount: Double
        let amountText: String
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
            amount: baseAmount,
            amountText: normalizedAmount(baseAmount),
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
