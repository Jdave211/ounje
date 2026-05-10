import SwiftUI

struct DiscoverRecipeFeedContentView: View {
    let isSearchRefreshing: Bool
    let errorMessage: String?
    let hasResolvedInitialLoad: Bool
    let isLoading: Bool
    let isSearching: Bool
    let isTransitioningFeed: Bool
    let isFetchingMore: Bool
    let hasMoreRecipes: Bool
    let selectedFilter: String
    let visibleRecipes: [DiscoverRecipeCardData]
    let recipeColumns: [GridItem]
    let transitionNamespace: Namespace.ID
    let onSelectRecipe: (DiscoverRecipeCardData) -> Void
    let shouldPrefetchRecipe: (DiscoverRecipeCardData) -> Bool
    let onLoadMore: () async -> Void

    var body: some View {
        if isSearchRefreshing || !hasResolvedInitialLoad
            || isLoading
            || isTransitioningFeed {
            LazyVGrid(columns: recipeColumns, spacing: 14) {
                ForEach(0..<6, id: \.self) { _ in
                    DiscoverRecipeCardLoadingPlaceholder()
                }
            }
            .transition(.opacity)
        } else if let errorMessage,
                  hasResolvedInitialLoad,
                  !isLoading,
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
        } else if let errorMessage, visibleRecipes.isEmpty {
            RecipesEmptyState(
                title: isSearching ? "Search unavailable" : "Recipe feed unavailable",
                detail: errorMessage,
                symbolName: "fork.knife",
                assetName: "CookbookEmptyIllustrationLight"
            )
        } else if visibleRecipes.isEmpty {
            RecipesEmptyState(
                title: emptyStateTitle,
                detail: emptyStateDetail,
                symbolName: "fork.knife",
                assetName: "CookbookEmptyIllustrationLight"
            )
        } else {
            LazyVGrid(columns: recipeColumns, spacing: 16) {
                ForEach(visibleRecipes) { recipe in
                    DiscoverRemoteRecipeCard(
                        recipe: recipe,
                        transitionNamespace: transitionNamespace
                    ) {
                        onSelectRecipe(recipe)
                    }
                    .onAppear {
                        guard shouldPrefetchRecipe(recipe) else { return }
                        Task {
                            await onLoadMore()
                        }
                    }
                }
            }

            if isFetchingMore {
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
                    guard hasMoreRecipes, !isLoading, !isFetchingMore else { return }
                    Task {
                        await onLoadMore()
                    }
                }
        }
    }

    private var isFeedFilter: Bool {
        DiscoverPreset.normalizedKey(for: selectedFilter) == "all"
    }

    private var emptyStateTitle: String {
        if isSearching { return "No recipes matched" }
        return isFeedFilter ? "Recipe feed unavailable" : "No recipes here yet"
    }

    private var emptyStateDetail: String {
        if isSearching { return "Try a different keyword or category." }
        return isFeedFilter
            ? "Pull to refresh or try another section."
            : "Try another section or pull to refresh."
    }
}
