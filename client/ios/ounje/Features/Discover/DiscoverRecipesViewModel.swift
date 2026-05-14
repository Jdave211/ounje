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

    private struct InMemoryDiscoverCacheEntry {
        let recipes: [DiscoverRecipeCardData]
        let filters: [String]
        let hasMoreRecipes: Bool
        let nextOffset: Int
    }

    @Published private(set) var recipes: [DiscoverRecipeCardData] = []
    @Published private(set) var filters: [String]
    @Published private(set) var isLoading = false
    @Published private(set) var isTransitioningFeed = false
    @Published private(set) var isFetchingMore = false
    @Published private(set) var hasMoreRecipes = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var hasResolvedInitialLoad = false
    @Published var selectedFilter = DiscoverPreset.all.title

    private var lastLoadKey: String?
    private var responseCache: [String: InMemoryDiscoverCacheEntry] = [:]
    private var activeRequestID: UUID?
    private var inFlightLoadKey: String?
    private var inFlightRequestID: UUID?
    private let sessionSeed = String(UUID().uuidString.prefix(8))
    private var baseFeedRotationIndex = 0
    private var baseFeedRefreshToken = UUID().uuidString
    private var lastBaseRotationAt: Date?
    private var lastLoadedFilter = DiscoverPreset.all.title
    private var feedbackRevision = 0
    private let stagedPageSize = 12
    private var currentFeedLimit = 12
    private var currentFeedOffset = 0
    private let shelfCacheTTL: TimeInterval = 12 * 60 * 60
    private let shelfCacheStoreKey = "ounje-discover-shelf-cache-v2"
    private let shelfCacheSchemaVersion = "2026-05-09-onboarding-blend"
    private let recipeCatalogVersion = "ounje-recipes-v1"
    private let rankingConfigVersion = "ranked-discover-v2-onboarding-profile"

    init() {
        filters = Self.stableFilters
    }

    func loadIfNeeded(
        profile: UserProfile?,
        query: String = "",
        feedContext: DiscoverFeedContext,
        behaviorSeeds: [DiscoverRecipeCardData] = []
    ) async {
        let loadKey = cacheKey(
            profile: profile,
            behaviorSeeds: behaviorSeeds,
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
        guard inFlightLoadKey != loadKey else { return }
        currentFeedLimit = stagedPageSize
        currentFeedOffset = 0
        await refresh(profile: profile, query: query, feedContext: feedContext, behaviorSeeds: behaviorSeeds, limit: currentFeedLimit, offset: 0)
    }

    func refresh(
        profile: UserProfile?,
        query: String = "",
        feedContext: DiscoverFeedContext,
        behaviorSeeds: [DiscoverRecipeCardData] = [],
        limit: Int? = nil,
        offset: Int = 0,
        appendResults: Bool = false,
        forceNetwork: Bool = false
    ) async {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let hadExistingRecipes = !recipes.isEmpty
        let previousRecipes = recipes
        let previousHasMoreRecipes = hasMoreRecipes
        let previousFeedOffset = currentFeedOffset
        let previousLastLoadedFilter = lastLoadedFilter
        let isPresetTransition = normalizedQuery.isEmpty && selectedFilter != lastLoadedFilter
        let requestedLimit = max(1, limit ?? currentFeedLimit)
        currentFeedLimit = requestedLimit
        let requestedOffset = max(0, offset)
        currentFeedOffset = requestedOffset
        let loadKey = cacheKey(profile: profile, behaviorSeeds: behaviorSeeds, filter: selectedFilter, query: normalizedQuery, feedContext: feedContext, limit: requestedLimit, offset: requestedOffset)
        let shelfKey = persistentShelfKey(profile: profile, behaviorSeeds: behaviorSeeds, filter: selectedFilter, query: normalizedQuery, feedContext: feedContext)

        if !forceNetwork, inFlightLoadKey == loadKey {
            if inFlightRequestID == nil {
                inFlightLoadKey = nil
                isLoading = false
                isTransitioningFeed = false
            }
            return
        }

        if !forceNetwork,
           let cachedEntry = responseCache[loadKey],
           !cachedEntry.recipes.isEmpty {
            applyCachedRecipes(
                cachedEntry.recipes,
                filters: cachedEntry.filters,
                hasMore: cachedEntry.hasMoreRecipes,
                nextOffset: cachedEntry.nextOffset,
                loadKey: loadKey,
                appendResults: appendResults,
                requestedOffset: requestedOffset
            )
            isLoading = false
            isTransitioningFeed = false
            return
        }

        let canUseStoredShelf = DiscoverPreset.normalizedKey(for: selectedFilter) == "all"
        if canUseStoredShelf,
           !appendResults,
           !forceNetwork,
           let storedShelf = storedShelf(for: shelfKey),
           !storedShelf.recipes.isEmpty {
            applyStoredShelf(storedShelf, loadKey: loadKey)
            if Date().timeIntervalSince(storedShelf.storedAt) < shelfCacheTTL {
                isLoading = false
                isTransitioningFeed = false
                return
            }
        }

        let requestID = UUID()
        activeRequestID = requestID
        inFlightLoadKey = loadKey
        inFlightRequestID = requestID

        errorMessage = nil
        isLoading = true
        if isPresetTransition {
            isTransitioningFeed = true
        }
        let shouldPreserveVisibleRecipes = forceNetwork
            && !appendResults
            && hadExistingRecipes
            && normalizedQuery.isEmpty
        // Use `recipes.isEmpty` here (not `hadExistingRecipes`) so that a stale stored shelf
        // applied above keeps recipes visible while the network fetch runs in the background.
        let shouldClearVisibleRecipes = !appendResults
            && !shouldPreserveVisibleRecipes
            && (
                forceNetwork
                || isPresetTransition
                || (responseCache[loadKey] == nil && recipes.isEmpty)
            )
        if shouldClearVisibleRecipes {
            recipes = []
        }
        defer {
            if inFlightRequestID == requestID {
                inFlightLoadKey = nil
                inFlightRequestID = nil
            }
            if activeRequestID == requestID {
                activeRequestID = nil
                isLoading = false
                isTransitioningFeed = false
            }
        }
        if !normalizedQuery.isEmpty {
            try? await Task.sleep(nanoseconds: 20_000_000)
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
                offset: requestedOffset,
                forceRefresh: forceNetwork
            )
            guard activeRequestID == requestID else { return }
            let mixedRecipes = DiscoverOnboardingFeedMixer.mixedFeed(
                recipes: response.recipes,
                profile: profile,
                behaviorSeeds: behaviorSeeds,
                requestSeed: requestSeed,
                filter: selectedFilter,
                query: normalizedQuery
            )
            let firstPageEmpty = !appendResults
                && requestedOffset == 0
                && normalizedQuery.isEmpty
                && mixedRecipes.isEmpty
            if firstPageEmpty {
                debugLogDiscoverRefresh(
                    "empty first-page response",
                    filter: selectedFilter,
                    query: normalizedQuery,
                    forceNetwork: forceNetwork,
                    fallbackMode: response.rankingMode,
                    keptExistingRecipes: hadExistingRecipes
                )
                if hadExistingRecipes {
                    recipes = previousRecipes
                    errorMessage = nil
                    hasResolvedInitialLoad = true
                    hasMoreRecipes = previousHasMoreRecipes
                    currentFeedOffset = previousFeedOffset
                    lastLoadedFilter = previousLastLoadedFilter
                    return
                }

                if DiscoverPreset.normalizedKey(for: selectedFilter) != "all" {
                    recipes = []
                    errorMessage = nil
                    hasResolvedInitialLoad = true
                    hasMoreRecipes = false
                    currentFeedOffset = 0
                    lastLoadedFilter = selectedFilter
                    lastLoadKey = loadKey
                    return
                }

                errorMessage = "We couldn’t load the live recipe feed."
                hasResolvedInitialLoad = true
                hasMoreRecipes = false
                currentFeedOffset = 0
                return
            }

            recipes = appendResults && requestedOffset > 0
                ? dedupeRecipesByID(recipes + mixedRecipes)
                : mixedRecipes
            responseCache[loadKey] = InMemoryDiscoverCacheEntry(
                recipes: mixedRecipes,
                filters: response.filters,
                hasMoreRecipes: response.hasMore ?? (mixedRecipes.count >= requestedLimit),
                nextOffset: response.nextOffset ?? (requestedOffset + response.recipes.count)
            )
            filters = Self.stableFilters
            errorMessage = nil
            hasResolvedInitialLoad = true
            hasMoreRecipes = response.hasMore ?? (mixedRecipes.count >= requestedLimit)
            currentFeedOffset = response.nextOffset ?? (requestedOffset + response.recipes.count)
            lastLoadedFilter = selectedFilter
            lastLoadKey = loadKey
            if !filters.contains(selectedFilter) {
                selectedFilter = DiscoverPreset.all.title
            }
            if canUseStoredShelf && !appendResults && requestedOffset == 0 {
                storeShelf(
                    key: shelfKey,
                    recipes: mixedRecipes,
                    filters: filters,
                    hasMore: hasMoreRecipes,
                    nextOffset: currentFeedOffset
                )
            }
        } catch {
            guard activeRequestID == requestID else { return }
            hasResolvedInitialLoad = true
            if hadExistingRecipes {
                recipes = previousRecipes
                hasMoreRecipes = previousHasMoreRecipes
                currentFeedOffset = previousFeedOffset
                lastLoadedFilter = previousLastLoadedFilter
                errorMessage = nil
                debugLogDiscoverRefresh(
                    "refresh failed; keeping stale recipes",
                    filter: selectedFilter,
                    query: normalizedQuery,
                    forceNetwork: forceNetwork,
                    fallbackMode: nil,
                    keptExistingRecipes: true,
                    error: error
                )
            } else {
                hasMoreRecipes = false
                errorMessage = (error as? LocalizedError)?.errorDescription ?? "We couldn’t load the live recipe feed."
                debugLogDiscoverRefresh(
                    "cold refresh failed",
                    filter: selectedFilter,
                    query: normalizedQuery,
                    forceNetwork: forceNetwork,
                    fallbackMode: nil,
                    keptExistingRecipes: false,
                    error: error
                )
            }
        }
    }

    func loadMoreIfNeeded(
        profile: UserProfile?,
        query: String = "",
        feedContext: DiscoverFeedContext,
        behaviorSeeds: [DiscoverRecipeCardData] = []
    ) async {
        guard hasResolvedInitialLoad, hasMoreRecipes, !isLoading, !isFetchingMore else { return }
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let nextOffset = currentFeedOffset
        let loadKey = cacheKey(profile: profile, behaviorSeeds: behaviorSeeds, filter: selectedFilter, query: normalizedQuery, feedContext: feedContext, limit: stagedPageSize, offset: nextOffset)
        guard responseCache[loadKey] == nil else {
            currentFeedOffset = nextOffset
            return await refresh(profile: profile, query: query, feedContext: feedContext, behaviorSeeds: behaviorSeeds, limit: stagedPageSize, offset: nextOffset, appendResults: true)
        }

        isFetchingMore = true
        defer { isFetchingMore = false }
        await refresh(profile: profile, query: query, feedContext: feedContext, behaviorSeeds: behaviorSeeds, limit: stagedPageSize, offset: nextOffset, appendResults: true)
    }

    func rotateBaseFeedIfNeeded(profile: UserProfile?, feedContext: DiscoverFeedContext, behaviorSeeds: [DiscoverRecipeCardData] = []) async {
        let now = Date()
        if let lastBaseRotationAt, now.timeIntervalSince(lastBaseRotationAt) < 4 {
            return
        }

        invalidateBaseFeedRotation()
        lastBaseRotationAt = now
        await refresh(profile: profile, query: "", feedContext: feedContext, behaviorSeeds: behaviorSeeds)
    }

    func forceReload(
        profile: UserProfile?,
        query: String = "",
        feedContext: DiscoverFeedContext,
        behaviorSeeds: [DiscoverRecipeCardData] = []
    ) async {
        await forceReload(profile: profile, query: query, feedContext: feedContext, behaviorSeeds: behaviorSeeds, rotateBaseFeed: false, forceNetwork: false)
    }

    func forceReload(
        profile: UserProfile?,
        query: String = "",
        feedContext: DiscoverFeedContext,
        behaviorSeeds: [DiscoverRecipeCardData] = [],
        rotateBaseFeed: Bool,
        forceNetwork: Bool
    ) async {
        lastLoadKey = nil
        currentFeedLimit = stagedPageSize
        currentFeedOffset = 0
        if forceNetwork {
            responseCache.removeAll()
            hasResolvedInitialLoad = false
            errorMessage = nil
        }
        if rotateBaseFeed {
            invalidateBaseFeedRotation()
        }
        await refresh(profile: profile, query: query, feedContext: feedContext, behaviorSeeds: behaviorSeeds, limit: currentFeedLimit, offset: 0, forceNetwork: forceNetwork)
    }

    func resetFeedPagination() {
        currentFeedLimit = stagedPageSize
        currentFeedOffset = 0
        hasMoreRecipes = true
    }

    func selectFilter(_ filter: String, isSearching: Bool) {
        guard selectedFilter != filter else { return }
        selectedFilter = filter
        lastLoadKey = nil
        currentFeedOffset = 0
        hasMoreRecipes = false
        errorMessage = nil
        if !isSearching {
            isTransitioningFeed = true
            hasResolvedInitialLoad = false
            recipes = []
        }
    }

    func prepareForQueryRefresh() {
        isTransitioningFeed = true
        // Keep existing recipes visible while the search loads — the server response
        // will replace them when it arrives. Clearing immediately causes a blank screen.
        hasMoreRecipes = false
        errorMessage = nil
        currentFeedOffset = 0
    }

    func beginManualRefreshPresentation() {
        isTransitioningFeed = true
        hasResolvedInitialLoad = false
        errorMessage = nil
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

    private func cacheKey(
        profile: UserProfile?,
        behaviorSeeds: [DiscoverRecipeCardData],
        filter: String,
        query: String,
        feedContext: DiscoverFeedContext,
        limit: Int,
        offset: Int = 0
    ) -> String {
        let usesSharedBaseCache = usesSharedBaseFeedCache(
            behaviorSeeds: behaviorSeeds,
            filter: filter,
            query: query
        )
        let cuisines = usesSharedBaseCache ? "" : (profile?.preferredCuisines.map(\.rawValue).joined(separator: ",") ?? "")
        let dietary = usesSharedBaseCache ? "" : (profile?.dietaryPatterns.joined(separator: ",") ?? "")
        let foods = usesSharedBaseCache ? "" : (profile?.favoriteFoods.joined(separator: ",") ?? "")
        let flavors = usesSharedBaseCache ? "" : (profile?.favoriteFlavors.joined(separator: ",") ?? "")
        let profileKey = usesSharedBaseCache ? "shared-base-profile" : String(profileFingerprint(profile).prefix(16))
        let contextKey = usesSharedBaseCache ? "base|\(feedContext.windowKey)" : feedContext.cacheKey
        let behaviorKey = DiscoverOnboardingFeedMixer.behaviorSignature(behaviorSeeds)
        let baseRotationKey = query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "|rotation:\(baseFeedRotationIndex)|token:\(baseFeedRefreshToken)"
            : ""
        return "\(sessionSeed)|\(contextKey)|\(filter)|\(profileKey)|\(cuisines)|\(dietary)|\(foods)|\(flavors)|behavior:\(behaviorKey)|\(query)|feedback:\(feedbackRevision)|limit:\(limit)|offset:\(offset)\(baseRotationKey)"
    }

    private func persistentShelfKey(
        profile: UserProfile?,
        behaviorSeeds: [DiscoverRecipeCardData],
        filter: String,
        query: String,
        feedContext: DiscoverFeedContext
    ) -> String {
        let usesSharedBaseCache = usesSharedBaseFeedCache(
            behaviorSeeds: behaviorSeeds,
            filter: filter,
            query: query
        )
        return [
            shelfCacheSchemaVersion,
            recipeCatalogVersion,
            rankingConfigVersion,
            usesSharedBaseCache ? "shared-base-profile" : profileFingerprint(profile),
            usesSharedBaseCache ? "shared-base-behavior" : normalizedCacheComponent(DiscoverOnboardingFeedMixer.behaviorSignature(behaviorSeeds)),
            normalizedCacheComponent(filter),
            normalizedCacheComponent(query),
            usesSharedBaseCache ? "shared-base-location" : normalizedCacheComponent(feedContext.locationLabel ?? ""),
            usesSharedBaseCache ? "shared-base-region" : normalizedCacheComponent(feedContext.regionCode ?? ""),
            normalizedCacheComponent(feedContext.seasonCue ?? ""),
            "feedback-\(feedbackRevision)"
        ].joined(separator: "|")
    }

    private func usesSharedBaseFeedCache(
        behaviorSeeds: [DiscoverRecipeCardData],
        filter: String,
        query: String
    ) -> Bool {
        query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && DiscoverPreset.normalizedKey(for: filter) == "all"
            && behaviorSeeds.isEmpty
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
        filters = Self.stableFilters
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
        responseCache[loadKey] = InMemoryDiscoverCacheEntry(
            recipes: shelf.recipes,
            filters: shelf.filters,
            hasMoreRecipes: shelf.hasMoreRecipes,
            nextOffset: shelf.nextOffset
        )
    }

    private static var stableFilters: [String] {
        DiscoverPreset.allTitles
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

    private func debugLogDiscoverRefresh(
        _ message: String,
        filter: String,
        query: String,
        forceNetwork: Bool,
        fallbackMode: String?,
        keptExistingRecipes: Bool,
        error: Error? = nil
    ) {
        #if DEBUG
        let normalizedFilter = DiscoverPreset.normalizedKey(for: filter)
        let errorDescription = error.map { " error=\($0.localizedDescription)" } ?? ""
        let fallbackDescription = fallbackMode.map { " fallback=\($0)" } ?? ""
        print("[Discover] \(message) filter=\(normalizedFilter) query=\"\(query)\" force=\(forceNetwork) keptExisting=\(keptExistingRecipes)\(fallbackDescription)\(errorDescription)")
        #endif
    }

    private func fallbackRecipeLimit(for normalizedQuery: String) -> Int {
        if normalizedQuery.isEmpty {
            return DiscoverPreset.normalizedKey(for: selectedFilter) == "all" ? 300 : 600
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
