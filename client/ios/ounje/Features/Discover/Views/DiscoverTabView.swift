import SwiftUI
import Foundation

extension Notification.Name {
    static let ounjeDiscoverTabTapped = Notification.Name("ounje.discover.tab.tapped")
}

struct DiscoverTabView: View {
    @EnvironmentObject private var store: MealPlanningAppStore
    @EnvironmentObject private var savedStore: SavedRecipesStore
    @Binding var selectedTab: AppTab
    @Binding var searchText: String
    let recipeTransitionNamespace: Namespace.ID
    let onSelectRecipe: (DiscoverRecipeCardData) -> Void
    @ObservedObject var viewModel: DiscoverRecipesViewModel
    @ObservedObject var environmentModel: DiscoverEnvironmentViewModel
    @State private var hasAppearedOnce = false
    @State private var searchRefreshTask: Task<Void, Never>?
    @State private var submittedSearchText = ""
    @State private var isSearchInputPending = false
    @State private var isManualRefreshing = false
    @State private var isShowingPullRefreshCue = false
    @State private var hasPresentedPullRefreshCue = false
    @State private var discoverPullDistance: CGFloat = 0
    @State private var discoverPullBaseline: CGFloat?
    @State private var hasTriggeredCurrentPullRefresh = false
    @State private var filterRailResetToken = UUID()
    @State private var lastAppliedDiscoverFeedKey: String?

    private static let feedTopAnchorID = "discover-feed-top-anchor"

    private let recipeColumns = [
        GridItem(.flexible(), spacing: 16, alignment: .top),
        GridItem(.flexible(), spacing: 16, alignment: .top)
    ]

    private var filters: [String] {
        viewModel.filters
    }

    private var filteredRecipes: [DiscoverRecipeCardData] {
        viewModel.recipes
    }

    private var visibleRecipes: [DiscoverRecipeCardData] {
        filteredRecipes
    }

    private var normalizedSearchText: String {
        submittedSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var normalizedDraftSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isSearching: Bool {
        !normalizedSearchText.isEmpty
    }

    private var isSearchRefreshing: Bool {
        isSearching && (isSearchInputPending || viewModel.isLoading || viewModel.isTransitioningFeed)
    }

    var body: some View {
        GeometryReader { proxy in
            ScrollViewReader { feedProxy in
                VStack(alignment: .leading, spacing: 0) {
                    DiscoverHeaderView(
                        searchText: $searchText,
                        filters: filters,
                        selectedFilter: viewModel.selectedFilter,
                        resetToken: filterRailResetToken,
                        onSubmitSearch: submitDiscoverSearch
                    ) { filter in
                        let didChangeFilter = viewModel.selectedFilter != filter
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.84)) {
                            viewModel.selectFilter(filter, isSearching: isSearching)
                        }
                        if didChangeFilter {
                            scrollDiscoverFeedToTop(feedProxy)
                        }
                    }

                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            Color.clear
                                .frame(height: 0)
                                .id(Self.feedTopAnchorID)

                            GeometryReader { geometry in
                                Color.clear.preference(
                                    key: PullStretchRefreshOffsetPreferenceKey.self,
                                    value: geometry.frame(in: .named("discover-feed-scroll")).minY
                                )
                            }
                            .frame(height: 0)

                            if shouldShowDiscoverPullIndicator {
                                PullStretchRefreshIndicator(
                                    phase: discoverPullRefreshPhase,
                                    pullDistance: discoverPullDistance
                                )
                                    .transition(.opacity.combined(with: .move(edge: .top)))
                            }

                            discoverRecipeFeedContent
                        }
                        .padding(.horizontal, OunjeLayout.screenHorizontalPadding)
                        .padding(.top, 2)
                        .padding(.bottom, 140)
                    }
                    .coordinateSpace(name: "discover-feed-scroll")
                    .scrollIndicators(.hidden)
                    .onPreferenceChange(PullStretchRefreshOffsetPreferenceKey.self) { value in
                        updateDiscoverPullDistance(value)
                    }
                    .refreshable {
                        await refreshDiscoverFromPull()
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
                .onAppear {
                    resetDiscoverToFeedIfNeeded(feedProxy)
                }
                .onChange(of: selectedTab) { newTab in
                    guard newTab == .discover else { return }
                    resetDiscoverToFeedIfNeeded(feedProxy)
                }
                .onReceive(NotificationCenter.default.publisher(for: .ounjeDiscoverTabTapped)) { _ in
                    resetDiscoverToFeedIfNeeded(feedProxy)
                }
            }
        }
        .task(id: discoverFeedKey) {
            guard !isSearching else { return }
            let taskFeedKey = discoverFeedKey
            let shouldForcePersonalizedReload = lastAppliedDiscoverFeedKey != nil
                && lastAppliedDiscoverFeedKey != taskFeedKey
                && !viewModel.recipes.isEmpty
            lastAppliedDiscoverFeedKey = taskFeedKey

            let initialContext = environmentModel.feedContext
            viewModel.updateFeedbackRevision(discoverFeedbackRevision)
            async let environmentRefresh: Void = environmentModel.refresh(profile: store.profile)

            if shouldForcePersonalizedReload {
                viewModel.prepareForQueryRefresh()
                await environmentRefresh
                await viewModel.forceReload(
                    profile: store.profile,
                    query: normalizedSearchText,
                    feedContext: environmentModel.feedContext,
                    behaviorSeeds: savedStore.savedRecipes,
                    rotateBaseFeed: normalizedSearchText.isEmpty,
                    forceNetwork: true
                )
                return
            }

            await viewModel.loadIfNeeded(
                profile: store.profile,
                query: normalizedSearchText,
                feedContext: initialContext,
                behaviorSeeds: savedStore.savedRecipes
            )
            await environmentRefresh
            let refreshedContext = environmentModel.feedContext
            guard refreshedContext.cacheKey != initialContext.cacheKey else { return }
            guard viewModel.recipes.isEmpty || viewModel.errorMessage != nil else { return }
            await viewModel.forceReload(
                profile: store.profile,
                query: normalizedSearchText,
                feedContext: refreshedContext,
                behaviorSeeds: savedStore.savedRecipes
            )
        }
        .onChange(of: searchText) { newValue in
            searchRefreshTask?.cancel()

            let normalized = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty else {
                clearSubmittedDiscoverSearch()
                return
            }

            isSearchInputPending = false
            if normalized != normalizedSearchText {
                viewModel.clearTransientError()
            }
        }
        .onAppear {
            viewModel.clearTransientError()
            viewModel.updateFeedbackRevision(discoverFeedbackRevision)
            presentPullRefreshCueIfNeeded()

            guard normalizedSearchText.isEmpty else { return }
            guard hasAppearedOnce else {
                hasAppearedOnce = true
                return
            }
            Task {
                if viewModel.recipes.isEmpty || viewModel.errorMessage != nil {
                    await viewModel.loadIfNeeded(
                        profile: store.profile,
                        query: normalizedSearchText,
                        feedContext: environmentModel.feedContext,
                        behaviorSeeds: savedStore.savedRecipes
                    )
                }
            }
        }
        .onDisappear {
            searchRefreshTask?.cancel()
            isSearchInputPending = false
        }
    }

    @ViewBuilder
    private var discoverRecipeFeedContent: some View {
        DiscoverRecipeFeedContentView(
            isSearchRefreshing: isSearchRefreshing,
            errorMessage: viewModel.errorMessage,
            hasResolvedInitialLoad: viewModel.hasResolvedInitialLoad,
            isLoading: viewModel.isLoading,
            isSearching: isSearching,
            isTransitioningFeed: viewModel.isTransitioningFeed,
            isFetchingMore: viewModel.isFetchingMore,
            hasMoreRecipes: viewModel.hasMoreRecipes,
            selectedFilter: viewModel.selectedFilter,
            visibleRecipes: visibleRecipes,
            recipeColumns: recipeColumns,
            transitionNamespace: recipeTransitionNamespace,
            onSelectRecipe: onSelectRecipe,
            shouldPrefetchRecipe: shouldPrefetch(after:),
            onLoadMore: loadMoreRecipes
        )
    }

    private var discoverFeedKey: String {
        let cuisines = store.profile?.preferredCuisines.map(\.rawValue).joined(separator: ",") ?? ""
        let foods = store.profile?.favoriteFoods.joined(separator: ",") ?? ""
        let flavors = store.profile?.favoriteFlavors.joined(separator: ",") ?? ""
        let dietary = store.profile?.dietaryPatterns.joined(separator: ",") ?? ""
        let address = store.profile?.deliveryAddress
        let environmentKey = [
            address?.city ?? "",
            address?.region ?? "",
            address?.postalCode ?? ""
        ].joined(separator: "|")
        return "\(cuisines)|\(foods)|\(flavors)|\(dietary)|\(viewModel.selectedFilter)|\(environmentKey)"
    }

    private var discoverFeedbackRevision: Int {
        savedStore.savedRecipes.count
    }

    private var shouldShowDiscoverPullIndicator: Bool {
        isShowingPullRefreshCue
            || isManualRefreshing
            || (!isSearching && viewModel.isTransitioningFeed && !visibleRecipes.isEmpty)
            || discoverPullDistance > 6
    }

    private var discoverPullRefreshPhase: PullStretchRefreshPhase {
        if isManualRefreshing || (viewModel.isTransitioningFeed && !visibleRecipes.isEmpty) {
            return .refreshing
        }
        if discoverPullDistance >= 62 {
            return .release
        }
        if discoverPullDistance > 6 {
            return .pulling
        }
        return .hint
    }

    private func updateDiscoverPullDistance(_ offset: CGFloat) {
        if discoverPullBaseline == nil {
            discoverPullBaseline = offset
        }

        let baseline = discoverPullBaseline ?? offset
        let distance = max(0, offset - baseline)
        discoverPullDistance = distance > 1 ? distance : 0

        if discoverPullDistance < 8, !isManualRefreshing {
            hasTriggeredCurrentPullRefresh = false
        }

        guard discoverPullDistance >= 78,
              !hasTriggeredCurrentPullRefresh,
              !isManualRefreshing,
              !viewModel.isLoading
        else { return }

        hasTriggeredCurrentPullRefresh = true
        Task {
            await refreshDiscoverFromPull()
        }
    }

    private func refreshDiscoverFromPull() async {
        guard !isManualRefreshing else { return }
        isManualRefreshing = true
        defer { isManualRefreshing = false }

        // A cleared search field must mean "refresh the feed", even if a previous
        // submitted query is still hanging around from an older search session.
        if normalizedDraftSearchText.isEmpty, !submittedSearchText.isEmpty {
            submittedSearchText = ""
            isSearchInputPending = false
        }

        let refreshQuery = normalizedDraftSearchText.isEmpty ? "" : normalizedSearchText
        viewModel.updateFeedbackRevision(discoverFeedbackRevision)
        viewModel.beginManualRefreshPresentation()
        let refreshStartedAt = Date()
        try? await Task.sleep(nanoseconds: 180_000_000)
        await environmentModel.refresh(profile: store.profile)
        await viewModel.forceReload(
            profile: store.profile,
            query: refreshQuery,
            feedContext: environmentModel.feedContext,
            behaviorSeeds: savedStore.savedRecipes,
            rotateBaseFeed: refreshQuery.isEmpty,
            forceNetwork: true
        )
        let elapsed = Date().timeIntervalSince(refreshStartedAt)
        if elapsed < 0.45 {
            try? await Task.sleep(nanoseconds: UInt64((0.45 - elapsed) * 1_000_000_000))
        }
    }

    private func resetDiscoverToFeedIfNeeded(_ proxy: ScrollViewProxy) {
        guard selectedTab == .discover else { return }

        searchRefreshTask?.cancel()
        isSearchInputPending = false

        if !submittedSearchText.isEmpty {
            submittedSearchText = ""
        }
        if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            searchText = ""
        }

        if normalizedSearchText.isEmpty, !filters.contains(viewModel.selectedFilter) {
            viewModel.selectedFilter = DiscoverPreset.all.title
        }

        if viewModel.selectedFilter != DiscoverPreset.all.title {
            viewModel.selectFilter(DiscoverPreset.all.title, isSearching: false)
        }
        filterRailResetToken = UUID()

        scrollDiscoverFeedToTop(proxy)

        if viewModel.recipes.isEmpty || viewModel.errorMessage != nil {
            Task {
                await viewModel.forceReload(
                    profile: store.profile,
                    query: "",
                    feedContext: environmentModel.feedContext,
                    behaviorSeeds: savedStore.savedRecipes
                )
            }
        }
    }

    private func scrollDiscoverFeedToTop(_ proxy: ScrollViewProxy) {
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.18)) {
                proxy.scrollTo(Self.feedTopAnchorID, anchor: .top)
            }
        }
    }

    private func submitDiscoverSearch() {
        searchRefreshTask?.cancel()
        let normalized = normalizedDraftSearchText
        guard !normalized.isEmpty else {
            clearSubmittedDiscoverSearch()
            return
        }

        guard normalized != normalizedSearchText || viewModel.recipes.isEmpty || viewModel.errorMessage != nil else { return }
        submittedSearchText = normalized
        isSearchInputPending = true
        if DiscoverPreset.normalizedKey(for: viewModel.selectedFilter) != "all" {
            viewModel.selectFilter(DiscoverPreset.all.title, isSearching: true)
        }
        viewModel.resetFeedPagination()
        viewModel.prepareForQueryRefresh()

        searchRefreshTask = Task {
            await viewModel.refresh(
                profile: store.profile,
                query: normalized,
                feedContext: environmentModel.feedContext,
                behaviorSeeds: savedStore.savedRecipes,
                offset: 0,
                forceNetwork: false
            )
            guard !Task.isCancelled else { return }
            await MainActor.run {
                isSearchInputPending = false
            }
        }
    }

    private func clearSubmittedDiscoverSearch() {
        searchRefreshTask?.cancel()
        isSearchInputPending = false
        guard !submittedSearchText.isEmpty else { return }
        submittedSearchText = ""
        Task {
            await viewModel.loadIfNeeded(
                profile: store.profile,
                query: "",
                feedContext: environmentModel.feedContext,
                behaviorSeeds: savedStore.savedRecipes
            )
        }
    }

    private func shouldPrefetch(after recipe: DiscoverRecipeCardData) -> Bool {
        guard let currentIndex = visibleRecipes.firstIndex(where: { $0.id == recipe.id }) else { return false }
        let thresholdIndex = max(visibleRecipes.count - 4, 0)
        return currentIndex >= thresholdIndex
    }

    private func loadMoreRecipes() async {
        await viewModel.loadMoreIfNeeded(
            profile: store.profile,
            query: normalizedSearchText,
            feedContext: environmentModel.feedContext,
            behaviorSeeds: savedStore.savedRecipes
        )
    }

    private func presentPullRefreshCueIfNeeded() {
        guard !hasPresentedPullRefreshCue, normalizedSearchText.isEmpty else { return }
        hasPresentedPullRefreshCue = true
        Task { @MainActor in
            withAnimation(.easeOut(duration: 0.22)) {
                isShowingPullRefreshCue = true
            }
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            withAnimation(.easeInOut(duration: 0.24)) {
                isShowingPullRefreshCue = false
            }
        }
    }
}
