import SwiftUI
import Foundation

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

    private var greetingLine: String {
        let name = store.profile?.trimmedPreferredName
        if let name, !name.isEmpty {
            return "Welcome back, \(name)."
        }
        return "Welcome back."
    }

    private var dateLine: String {
        Date.now.formatted(.dateTime.weekday(.wide).month(.wide).day())
    }

    private var mealPrompt: String {
        let hour = Calendar.current.component(.hour, from: .now)
        switch hour {
        case 5..<11:
            return "What are we making for breakfast?"
        case 11..<16:
            return "What are we making for lunch?"
        case 16..<22:
            return "What are we making for dinner?"
        default:
            return "What are we prepping next?"
        }
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
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 3) {
                        BiroScriptDisplayText("Discover", size: 31, color: OunjePalette.primaryText)
                        Text("Find your next meal")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(OunjePalette.secondaryText)
                    }

                    CompactDiscoverSearchField(
                        text: $searchText,
                        isLoading: false,
                        isRefreshing: !isSearching && viewModel.isTransitioningFeed && !visibleRecipes.isEmpty,
                        onSubmitSearch: submitDiscoverSearch
                    )

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .firstTextBaseline, spacing: 26) {
                            ForEach(filters, id: \.self) { filter in
                                DiscoverPresetTextButton(
                                    title: filter,
                                    isSelected: viewModel.selectedFilter == filter
                                ) {
                                    withAnimation(.spring(response: 0.3, dampingFraction: 0.84)) {
                                        viewModel.selectFilter(filter, isSearching: isSearching)
                                    }
                                }
                            }
                        }
                        .padding(.trailing, 10)
                        .padding(.top, 2)
                        .padding(.bottom, 4)
                    }

                }
                .padding(.horizontal, OunjeLayout.screenHorizontalPadding)
                .padding(.top, 14)
                .padding(.bottom, 10)

                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
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
        }
        .task(id: discoverFeedKey) {
            guard !isSearching else { return }
            let initialContext = environmentModel.feedContext
            viewModel.updateFeedbackRevision(discoverFeedbackRevision)
            async let environmentRefresh: Void = environmentModel.refresh(profile: store.profile)
            await viewModel.loadIfNeeded(profile: store.profile, query: normalizedSearchText, feedContext: initialContext)
            await environmentRefresh
            let refreshedContext = environmentModel.feedContext
            guard refreshedContext.cacheKey != initialContext.cacheKey else { return }
            guard viewModel.recipes.isEmpty || viewModel.errorMessage != nil else { return }
            await viewModel.forceReload(profile: store.profile, query: normalizedSearchText, feedContext: refreshedContext)
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
            if normalizedSearchText.isEmpty {
                viewModel.selectedFilter = "All"
            }

            guard normalizedSearchText.isEmpty else { return }
            guard hasAppearedOnce else {
                hasAppearedOnce = true
                return
            }
            Task {
                if viewModel.recipes.isEmpty || viewModel.errorMessage != nil {
                    await viewModel.loadIfNeeded(profile: store.profile, query: normalizedSearchText, feedContext: environmentModel.feedContext)
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
        if isSearchRefreshing {
            VStack(alignment: .center, spacing: 14) {
                DiscoverInlineLoadingState(message: "Searching", tint: .white, textColor: Color.white.opacity(0.9))
                    .frame(maxWidth: .infinity, alignment: .center)
                LazyVGrid(columns: recipeColumns, spacing: 14) {
                    ForEach(0..<6, id: \.self) { _ in
                        DiscoverRecipeCardLoadingPlaceholder()
                    }
                }
            }
            .transition(.opacity)
        } else if let errorMessage = viewModel.errorMessage,
           viewModel.hasResolvedInitialLoad,
           !viewModel.isLoading,
           !isSearching,
           !visibleRecipes.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Recipe feed unavailable")
                    .biroHeaderFont(18)
                    .foregroundStyle(OunjePalette.primaryText)
                Text(errorMessage)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(OunjePalette.secondaryText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 6)
        } else if !viewModel.hasResolvedInitialLoad
                    || (visibleRecipes.isEmpty && (viewModel.isLoading || viewModel.isTransitioningFeed)) {
            LazyVGrid(columns: recipeColumns, spacing: 14) {
                ForEach(0..<6, id: \.self) { _ in
                    DiscoverRecipeCardLoadingPlaceholder()
                }
            }
        } else if let errorMessage = viewModel.errorMessage,
                  visibleRecipes.isEmpty {
            RecipesEmptyState(
                title: isSearching ? "Search unavailable" : "Recipe feed unavailable",
                detail: errorMessage,
                symbolName: "fork.knife",
                assetName: "CookbookEmptyIllustrationLight"
            )
        } else if visibleRecipes.isEmpty {
            RecipesEmptyState(
                title: "No recipes matched",
                detail: "Try a different keyword or category.",
                symbolName: "fork.knife",
                assetName: "CookbookEmptyIllustrationLight"
            )
        } else {
            if viewModel.isTransitioningFeed && !visibleRecipes.isEmpty {
                DiscoverInlineLoadingState(message: "Refreshing your feed")
            }

            LazyVGrid(columns: recipeColumns, spacing: 16) {
                ForEach(visibleRecipes) { recipe in
                    DiscoverRemoteRecipeCard(
                        recipe: recipe,
                        transitionNamespace: recipeTransitionNamespace
                    ) {
                        onSelectRecipe(recipe)
                    }
                    .onAppear {
                        guard shouldPrefetch(after: recipe) else { return }
                        Task {
                            await viewModel.loadMoreIfNeeded(profile: store.profile, query: normalizedSearchText, feedContext: environmentModel.feedContext)
                        }
                    }
                }
            }
            if viewModel.isFetchingMore {
                LazyVGrid(columns: recipeColumns, spacing: 14) {
                    ForEach(0..<2, id: \.self) { _ in
                        DiscoverRecipeCardLoadingPlaceholder()
                    }
                }
                .padding(.top, 2)
            }

            Color.clear
                .frame(height: 1)
                .onAppear {
                    guard viewModel.hasMoreRecipes, !viewModel.isLoading, !viewModel.isFetchingMore else { return }
                    Task {
                        await viewModel.loadMoreIfNeeded(profile: store.profile, query: normalizedSearchText, feedContext: environmentModel.feedContext)
                    }
                }
        }
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
        return "\(cuisines)|\(foods)|\(flavors)|\(dietary)|\(viewModel.selectedFilter)|\(environmentKey)|feedback:\(discoverFeedbackRevision)"
    }

    private var discoverFeedbackRevision: Int {
        savedStore.savedRecipes.count / 3
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

    private func refreshDiscoverFromPull() async {
        guard !isManualRefreshing else { return }
        isManualRefreshing = true
        defer { isManualRefreshing = false }
        viewModel.updateFeedbackRevision(discoverFeedbackRevision)
        await viewModel.forceReload(
            profile: store.profile,
            query: normalizedSearchText,
            feedContext: environmentModel.feedContext,
            rotateBaseFeed: normalizedSearchText.isEmpty,
            forceNetwork: true
        )
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
        if viewModel.selectedFilter != "All" {
            viewModel.selectFilter("All", isSearching: true)
        }
        viewModel.resetFeedPagination()
        viewModel.prepareForQueryRefresh()

        searchRefreshTask = Task {
            await viewModel.refresh(profile: store.profile, query: normalized, feedContext: environmentModel.feedContext, offset: 0, forceNetwork: false)
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
            await viewModel.loadIfNeeded(profile: store.profile, query: "", feedContext: environmentModel.feedContext)
        }
    }

    private func shouldPrefetch(after recipe: DiscoverRecipeCardData) -> Bool {
        guard let currentIndex = visibleRecipes.firstIndex(where: { $0.id == recipe.id }) else { return false }
        let thresholdIndex = max(visibleRecipes.count - 4, 0)
        return currentIndex >= thresholdIndex
    }
}

private struct DiscoverInlineLoadingState: View {
    var message: String = "Refreshing"
    var tint: Color = OunjePalette.accent
    var textColor: Color = OunjePalette.secondaryText

    var body: some View {
        HStack(spacing: 10) {
            DiscoverRiveLoader(size: 18, tint: tint)

            Text(message)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(textColor)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule(style: .continuous)
                .fill(OunjePalette.surface.opacity(0.82))
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(OunjePalette.stroke.opacity(0.8), lineWidth: 1)
                )
        )
    }
}

private enum PullStretchRefreshPhase: Equatable {
    case hint
    case pulling
    case release
    case refreshing
    case complete
}

private struct PullStretchRefreshOffsetPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct PullStretchRefreshIndicator: View {
    let phase: PullStretchRefreshPhase
    var pullDistance: CGFloat = 0
    @State private var isAnimating = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var pullProgress: CGFloat {
        min(max(pullDistance / 62, 0), 1)
    }

    private var title: String {
        switch phase {
        case .hint:
            return "Pull here for fresh ideas"
        case .pulling:
            return "Keep pulling"
        case .release:
            return "Release to refresh"
        case .refreshing:
            return "Refreshing ideas"
        case .complete:
            return "Fresh ideas ready"
        }
    }

    var body: some View {
        HStack(spacing: 9) {
            if phase == .refreshing {
                DiscoverRiveLoader(size: 18)
            } else if phase == .complete {
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .bold))
            } else {
                Image(systemName: "arrow.down")
                    .font(.system(size: 12, weight: .bold))
                    .rotationEffect(.degrees(phase == .release ? 180 : 0))
                    .offset(y: reduceMotion ? 0 : (isAnimating ? 3 : -2))
            }

            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.82)
        }
        .foregroundStyle(OunjePalette.softCream.opacity(phase == .refreshing ? 0.95 : 0.76))
        .padding(.vertical, 4)
        .scaleEffect(
            x: reduceMotion ? 1 : 1 + (pullProgress * 0.06),
            y: reduceMotion ? 1 : 1 + (pullProgress * 0.16),
            anchor: .center
        )
        .frame(maxWidth: .infinity, alignment: .center)
        .animation(.spring(response: 0.28, dampingFraction: 0.82), value: phase)
        .animation(.spring(response: 0.24, dampingFraction: 0.78), value: pullProgress)
        .accessibilityLabel(phase == .refreshing ? "Refreshing Discover recipes" : "Pull down to refresh Discover recipes")
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.62).repeatForever(autoreverses: true)) {
                isAnimating = true
            }
        }
    }
}

private struct DiscoverRiveLoader: View {
    var size: CGFloat = 18
    var tint: Color = OunjePalette.accent

    var body: some View {
        ProgressView()
            .tint(tint)
            .scaleEffect(0.8)
            .frame(width: size, height: size)
            .allowsHitTesting(false)
    }
}

private struct CompactDiscoverSearchField: View {
    @Binding var text: String
    let isLoading: Bool
    let isRefreshing: Bool
    let onSubmitSearch: () -> Void

    @FocusState private var isFocused: Bool
    @State private var placeholderIndex = Int.random(in: 0..<DiscoverSearchPlaceholderPrompts.values.count)

    private var placeholder: String {
        DiscoverSearchPlaceholderPrompts.values[
            min(max(placeholderIndex, 0), DiscoverSearchPlaceholderPrompts.values.count - 1)
        ]
    }

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onSubmitSearch) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(OunjePalette.secondaryText)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            TextField(placeholder, text: $text)
                .textInputAutocapitalization(.never)
                .disableAutocorrection(true)
                .submitLabel(.search)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(OunjePalette.primaryText)
                .focused($isFocused)
                .onSubmit(onSubmitSearch)

            if isLoading || isRefreshing {
                DiscoverRiveLoader(size: 18)
            }

            if !text.isEmpty && !isLoading {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(OunjePalette.secondaryText.opacity(0.75))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(OunjePalette.surface.opacity(0.96))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(OunjePalette.stroke, lineWidth: 1)
                )
        )
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 4_800_000_000)
                guard !Task.isCancelled else { return }
                guard text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !isFocused else { continue }
                await MainActor.run {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        placeholderIndex = (placeholderIndex + 1) % DiscoverSearchPlaceholderPrompts.values.count
                    }
                }
            }
        }
    }
}

private enum DiscoverSearchPlaceholderPrompts {
    static let values: [String] = [
        "Search recipes",
        "Search chicken bowls",
        "Search salmon dinner",
        "Search veggie pasta",
        "Search shrimp tacos",
        "Search turkey chili",
        "Search tofu stir fry",
        "Search cozy soups",
        "Search breakfast wraps",
        "Search lunch salads",
        "Search rice bowls",
        "Search sheet pan meals",
        "Search pasta bakes",
        "Search air fryer ideas",
        "Search one-pot dinners",
        "Search family meals",
        "Search high protein",
        "Search meal prep lunches",
        "Search quick breakfasts",
        "Search snacks",
        "Search desserts",
        "Search smoothies",
        "Search hot tea for winter",
        "Search rainy day soup",
        "Search sunny picnic food",
        "Search cozy Sunday dinner",
        "Search late night noodles",
        "Search food for Nigerian potluck",
        "Search jollof sides",
        "Search Caribbean cookout",
        "Search Korean comfort food",
        "Search Mexican weeknight",
        "Search Mediterranean lunch",
        "Search Japanese breakfast",
        "Search Indian dinner",
        "Search Southern brunch",
        "Search French dessert",
        "Search game day food",
        "Search date night pasta",
        "Search movie night snacks",
        "Search gym day dinner",
        "Search sick day soup",
        "Search under 15 minutes",
        "Search under 30 minutes",
        "Search cheap dinner",
        "Search surprise me",
        "Search no dishes please",
        "Search fridge cleanout",
        "Search low effort",
        "Search spicy and sweet",
        "Search something crispy",
        "Search saucy noodles",
        "Search no oven",
        "Search no dairy",
        "Search vegetarian dinner",
        "Search freezer friendly"
    ]
}
