import SwiftUI
import Foundation
import CryptoKit

@MainActor
final class DiscoverRecipesViewModel: ObservableObject {
    private struct DiscoverShelfCacheEntry: Codable {
        let key: String
        let recipes: [DiscoverRecipeCardData]
        let filters: [String]
        let hasMoreRecipes: Bool
        let nextOffset: Int
        let storedAt: Date
    }

    private struct DiscoverShelfCacheStore: Codable {
        var entries: [String: DiscoverShelfCacheEntry] = [:]
    }

    @Published private(set) var recipes: [DiscoverRecipeCardData] = []
    @Published private(set) var filters: [String]
    @Published private(set) var isLoading = false
    @Published private(set) var isTransitioningFeed = false
    @Published private(set) var isFetchingMore = false
    @Published private(set) var hasMoreRecipes = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var hasResolvedInitialLoad = false
    @Published var selectedFilter = "All"

    private var lastLoadKey: String?
    private var responseCache: [String: [DiscoverRecipeCardData]] = [:]
    private var activeRequestID: UUID?
    private let sessionSeed = String(UUID().uuidString.prefix(8))
    private let filterShuffleSeed = UUID().uuidString
    private var baseFeedRotationIndex = 0
    private var baseFeedRefreshToken = UUID().uuidString
    private var lastBaseRotationAt: Date?
    private var lastLoadedFilter = "All"
    private var feedbackRevision = 0
    private let stagedPageSize = 18
    private var currentFeedLimit = 18
    private var currentFeedOffset = 0
    private let shelfCacheTTL: TimeInterval = 12 * 60 * 60
    private let shelfCacheStoreKey = "ounje-discover-shelf-cache-v2"
    private let shelfCacheSchemaVersion = "2026-04-27"
    private let recipeCatalogVersion = "ounje-recipes-v1"
    private let rankingConfigVersion = "ranked-discover-v1"

    init() {
        filters = DiscoverPreset.shuffledTitles(seed: filterShuffleSeed)
    }

    func loadIfNeeded(profile: UserProfile?, query: String = "", feedContext: DiscoverFeedContext) async {
        let loadKey = cacheKey(
            profile: profile,
            filter: selectedFilter,
            query: query.trimmingCharacters(in: .whitespacesAndNewlines),
            feedContext: feedContext,
            limit: stagedPageSize,
            offset: 0
        )
        guard lastLoadKey != loadKey else {
            isLoading = false
            isTransitioningFeed = false
            return
        }
        currentFeedLimit = stagedPageSize
        currentFeedOffset = 0
        await refresh(profile: profile, query: query, feedContext: feedContext, limit: currentFeedLimit, offset: 0)
    }

    func refresh(
        profile: UserProfile?,
        query: String = "",
        feedContext: DiscoverFeedContext,
        limit: Int? = nil,
        offset: Int = 0,
        appendResults: Bool = false,
        forceNetwork: Bool = false
    ) async {
        let requestID = UUID()
        activeRequestID = requestID
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var hadExistingRecipes = !recipes.isEmpty
        let isPresetTransition = normalizedQuery.isEmpty && selectedFilter != lastLoadedFilter
        let requestedLimit = max(1, limit ?? currentFeedLimit)
        currentFeedLimit = requestedLimit
        let requestedOffset = max(0, offset)
        currentFeedOffset = requestedOffset
        let loadKey = cacheKey(profile: profile, filter: selectedFilter, query: normalizedQuery, feedContext: feedContext, limit: requestedLimit, offset: requestedOffset)
        let shelfKey = persistentShelfKey(profile: profile, filter: selectedFilter, query: normalizedQuery, feedContext: feedContext)

        if !forceNetwork,
           let cachedRecipes = responseCache[loadKey],
           !cachedRecipes.isEmpty {
            applyCachedRecipes(
                cachedRecipes,
                filters: filters,
                hasMore: cachedRecipes.count >= requestedLimit,
                nextOffset: requestedOffset + cachedRecipes.count,
                loadKey: loadKey,
                appendResults: appendResults,
                requestedOffset: requestedOffset
            )
            isLoading = false
            isTransitioningFeed = false
            return
        }

        if !appendResults,
           !forceNetwork,
           let storedShelf = storedShelf(for: shelfKey),
           !storedShelf.recipes.isEmpty {
            applyStoredShelf(storedShelf, loadKey: loadKey)
            hadExistingRecipes = true
            if Date().timeIntervalSince(storedShelf.storedAt) < shelfCacheTTL {
                isLoading = false
                isTransitioningFeed = false
                return
            }
        }

        errorMessage = nil
        isLoading = true
        if isPresetTransition {
            isTransitioningFeed = true
        }
        let shouldClearVisibleRecipes = !appendResults
            && responseCache[loadKey] == nil
            && !hadExistingRecipes
        if shouldClearVisibleRecipes {
            recipes = []
        }
        defer {
            if activeRequestID == requestID {
                isLoading = false
                isTransitioningFeed = false
            }
        }
        if !normalizedQuery.isEmpty {
            try? await Task.sleep(nanoseconds: 90_000_000)
            guard !Task.isCancelled, activeRequestID == requestID else { return }
        }

        do {
            let requestSeed = normalizedQuery.isEmpty
                ? "\(sessionSeed)-base-\(baseFeedRotationIndex)-\(baseFeedRefreshToken)-\(feedContext.windowKey)"
                : "\(sessionSeed)-search"
            let response = try await SupabaseDiscoverRecipeService.shared.fetchRankedRecipes(
                profile: profile,
                filter: selectedFilter,
                query: normalizedQuery,
                sessionSeed: requestSeed,
                feedContext: feedContext,
                limit: requestedLimit,
                offset: requestedOffset
            )
            guard activeRequestID == requestID else { return }
            recipes = appendResults && requestedOffset > 0
                ? dedupeRecipesByID(recipes + response.recipes)
                : response.recipes
            responseCache[loadKey] = response.recipes
            filters = DiscoverPreset.shuffledTitles(seed: filterShuffleSeed)
            errorMessage = nil
            hasResolvedInitialLoad = true
            hasMoreRecipes = response.hasMore ?? (response.recipes.count >= requestedLimit)
            currentFeedOffset = response.nextOffset ?? (requestedOffset + response.recipes.count)
            lastLoadedFilter = selectedFilter
            lastLoadKey = loadKey
            if !filters.contains(selectedFilter) {
                selectedFilter = "All"
            }
            if !appendResults && requestedOffset == 0 {
                storeShelf(
                    key: shelfKey,
                    recipes: response.recipes,
                    filters: filters,
                    hasMore: hasMoreRecipes,
                    nextOffset: currentFeedOffset
                )
            }
        } catch {
            guard activeRequestID == requestID else { return }
            hasResolvedInitialLoad = true
            hasMoreRecipes = false
            if hadExistingRecipes {
                errorMessage = normalizedQuery.isEmpty
                    ? "Live Discover refresh failed, so we kept the last feed on screen."
                    : "Search refresh failed, so we kept the last results on screen."
            } else {
                errorMessage = (error as? LocalizedError)?.errorDescription ?? "We couldn’t load the live recipe feed."
            }
        }
    }

    func loadMoreIfNeeded(profile: UserProfile?, query: String = "", feedContext: DiscoverFeedContext) async {
        guard hasResolvedInitialLoad, hasMoreRecipes, !isLoading, !isFetchingMore else { return }
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let nextOffset = recipes.count
        let loadKey = cacheKey(profile: profile, filter: selectedFilter, query: normalizedQuery, feedContext: feedContext, limit: stagedPageSize, offset: nextOffset)
        guard responseCache[loadKey] == nil else {
            currentFeedOffset = nextOffset
            return await refresh(profile: profile, query: query, feedContext: feedContext, limit: stagedPageSize, offset: nextOffset, appendResults: true)
        }

        isFetchingMore = true
        defer { isFetchingMore = false }
        await refresh(profile: profile, query: query, feedContext: feedContext, limit: stagedPageSize, offset: nextOffset, appendResults: true)
    }

    func rotateBaseFeedIfNeeded(profile: UserProfile?, feedContext: DiscoverFeedContext) async {
        let now = Date()
        if let lastBaseRotationAt, now.timeIntervalSince(lastBaseRotationAt) < 4 {
            return
        }

        invalidateBaseFeedRotation()
        lastBaseRotationAt = now
        await refresh(profile: profile, query: "", feedContext: feedContext)
    }

    func forceReload(profile: UserProfile?, query: String = "", feedContext: DiscoverFeedContext) async {
        await forceReload(profile: profile, query: query, feedContext: feedContext, rotateBaseFeed: false, forceNetwork: false)
    }

    func forceReload(
        profile: UserProfile?,
        query: String = "",
        feedContext: DiscoverFeedContext,
        rotateBaseFeed: Bool,
        forceNetwork: Bool
    ) async {
        lastLoadKey = nil
        currentFeedLimit = stagedPageSize
        currentFeedOffset = 0
        if rotateBaseFeed {
            invalidateBaseFeedRotation()
        }
        await refresh(profile: profile, query: query, feedContext: feedContext, limit: currentFeedLimit, offset: 0, forceNetwork: forceNetwork)
    }

    func resetFeedPagination() {
        currentFeedLimit = stagedPageSize
        currentFeedOffset = 0
        hasMoreRecipes = true
    }

    func selectFilter(_ filter: String, isSearching: Bool) {
        guard selectedFilter != filter else { return }
        selectedFilter = filter
        if !isSearching {
            isTransitioningFeed = true
            currentFeedOffset = 0
        }
    }

    func prepareForQueryRefresh() {
        isTransitioningFeed = true
        if recipes.isEmpty {
            hasMoreRecipes = false
        }
        errorMessage = nil
        currentFeedOffset = 0
    }

    func clearTransientError() {
        errorMessage = nil
    }

    func updateFeedbackRevision(_ revision: Int) {
        let normalized = max(0, revision)
        guard feedbackRevision != normalized else { return }
        feedbackRevision = normalized
        lastLoadKey = nil
    }

    private func cacheKey(profile: UserProfile?, filter: String, query: String, feedContext: DiscoverFeedContext, limit: Int, offset: Int = 0) -> String {
        let cuisines = profile?.preferredCuisines.map(\.rawValue).joined(separator: ",") ?? ""
        let dietary = profile?.dietaryPatterns.joined(separator: ",") ?? ""
        let foods = profile?.favoriteFoods.joined(separator: ",") ?? ""
        let flavors = profile?.favoriteFlavors.joined(separator: ",") ?? ""
        let baseRotationKey = query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "|rotation:\(baseFeedRotationIndex)|token:\(baseFeedRefreshToken)"
            : ""
        return "\(sessionSeed)|\(feedContext.cacheKey)|\(filter)|\(cuisines)|\(dietary)|\(foods)|\(flavors)|\(query)|feedback:\(feedbackRevision)|limit:\(limit)|offset:\(offset)\(baseRotationKey)"
    }

    private func persistentShelfKey(profile: UserProfile?, filter: String, query: String, feedContext: DiscoverFeedContext) -> String {
        [
            shelfCacheSchemaVersion,
            recipeCatalogVersion,
            rankingConfigVersion,
            profileFingerprint(profile),
            normalizedCacheComponent(filter),
            normalizedCacheComponent(query),
            normalizedCacheComponent(feedContext.locationLabel ?? ""),
            normalizedCacheComponent(feedContext.regionCode ?? ""),
            normalizedCacheComponent(feedContext.seasonCue ?? ""),
            "feedback-\(feedbackRevision)"
        ].joined(separator: "|")
    }

    private func profileFingerprint(_ profile: UserProfile?) -> String {
        guard let profile,
              let data = try? JSONEncoder().encode(profile) else {
            return "anonymous-profile"
        }
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func normalizedCacheComponent(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
    }

    private func applyCachedRecipes(
        _ cachedRecipes: [DiscoverRecipeCardData],
        filters cachedFilters: [String],
        hasMore: Bool,
        nextOffset: Int,
        loadKey: String,
        appendResults: Bool,
        requestedOffset: Int
    ) {
        recipes = appendResults && requestedOffset > 0
            ? dedupeRecipesByID(recipes + cachedRecipes)
            : cachedRecipes
        if !cachedFilters.isEmpty {
            filters = cachedFilters
        }
        errorMessage = nil
        hasResolvedInitialLoad = true
        hasMoreRecipes = hasMore
        currentFeedOffset = nextOffset
        lastLoadedFilter = selectedFilter
        lastLoadKey = loadKey
    }

    private func applyStoredShelf(_ shelf: DiscoverShelfCacheEntry, loadKey: String) {
        applyCachedRecipes(
            shelf.recipes,
            filters: shelf.filters,
            hasMore: shelf.hasMoreRecipes,
            nextOffset: shelf.nextOffset,
            loadKey: loadKey,
            appendResults: false,
            requestedOffset: 0
        )
        responseCache[loadKey] = shelf.recipes
    }

    private func storedShelf(for key: String) -> DiscoverShelfCacheEntry? {
        guard let data = UserDefaults.standard.data(forKey: shelfCacheStoreKey),
              let store = try? JSONDecoder().decode(DiscoverShelfCacheStore.self, from: data) else {
            return nil
        }
        return store.entries[key]
    }

    private func storeShelf(
        key: String,
        recipes: [DiscoverRecipeCardData],
        filters: [String],
        hasMore: Bool,
        nextOffset: Int
    ) {
        guard !recipes.isEmpty else { return }

        var store: DiscoverShelfCacheStore
        if let data = UserDefaults.standard.data(forKey: shelfCacheStoreKey),
           let decoded = try? JSONDecoder().decode(DiscoverShelfCacheStore.self, from: data) {
            store = decoded
        } else {
            store = DiscoverShelfCacheStore()
        }

        store.entries[key] = DiscoverShelfCacheEntry(
            key: key,
            recipes: Array(recipes.prefix(stagedPageSize)),
            filters: filters,
            hasMoreRecipes: hasMore,
            nextOffset: nextOffset,
            storedAt: Date()
        )

        let sortedKeys = store.entries
            .sorted { $0.value.storedAt > $1.value.storedAt }
            .map(\.key)
        for oldKey in sortedKeys.dropFirst(18) {
            store.entries.removeValue(forKey: oldKey)
        }

        if let data = try? JSONEncoder().encode(store) {
            UserDefaults.standard.set(data, forKey: shelfCacheStoreKey)
        }
    }

    private func dedupeRecipesByID(_ recipes: [DiscoverRecipeCardData]) -> [DiscoverRecipeCardData] {
        var seen = Set<String>()
        return recipes.filter { recipe in
            let identifier = recipe.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !identifier.isEmpty else { return false }
            return seen.insert(identifier).inserted
        }
    }

    private func invalidateBaseFeedRotation() {
        baseFeedRotationIndex += 1
        baseFeedRefreshToken = UUID().uuidString
        lastLoadKey = nil
    }

    private func fallbackRecipeLimit(for normalizedQuery: String) -> Int {
        if normalizedQuery.isEmpty {
            return selectedFilter == "All" ? 300 : 600
        }
        return 600
    }

    private func applyLocalDiscoverFilters(
        to recipes: [DiscoverRecipeCardData],
        filter: String,
        query: String
    ) -> [DiscoverRecipeCardData] {
        let queryTerms = localDiscoverQueryTerms(from: query)

        return recipes.filter { recipe in
            let matchesFilter = recipe.matchesDiscoverFilter(filter)
            let matchesQuery = queryTerms.isEmpty || recipe.matchesDiscoverSearchTerms(queryTerms)
            return matchesFilter && matchesQuery
        }
    }

    private func localDiscoverQueryTerms(from query: String) -> [String] {
        let stopwords: Set<String> = [
            "a", "an", "the", "all",
            "what", "would", "like", "want", "need", "show", "find", "give",
            "me", "my", "you", "your", "can", "could", "should",
            "i", "im", "i'm", "to", "for", "of", "with", "in", "on", "at",
            "something", "anything", "ideas", "idea",
            "meal", "meals", "recipe", "recipes", "food", "foods",
            "today", "tonight", "now"
        ]

        return query
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { term in
                guard term.count > 1 else { return false }
                return !stopwords.contains(term)
            }
    }
}
