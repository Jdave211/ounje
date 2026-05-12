import Foundation

final class SupabaseDiscoverRecipeService {
    static let shared = SupabaseDiscoverRecipeService()

    private struct CatalogPoolResult {
        let recipes: [DiscoverRecipeCardData]
        let totalCount: Int
        let windowsFetched: Int
    }

    private static let recipeSelect = [
        "id",
        "title",
        "description",
        "author_name",
        "author_handle",
        "category",
        "recipe_type",
        "cook_time_text",
        "cook_time_minutes",
        "published_date",
        "discover_card_image_url",
        "hero_image_url",
        "recipe_url",
        "source",
        "discover_brackets"
    ].joined(separator: ",")

    private var catalogPoolCache: [String: CatalogPoolResult] = [:]
    private var recipeCountCache: (count: Int, fetchedAt: Date)?
    private let recipeCountCacheTTL: TimeInterval = 10 * 60

    private init() {}

    func fetchRecipes(limit: Int = 30, offset: Int = 0) async throws -> [DiscoverRecipeCardData] {
        try await fetchRecipes(
            limit: limit,
            offset: offset,
            orderClause: "updated_at.desc.nullslast,published_date.desc.nullslast"
        )
    }

    private func fetchRecipes(
        limit: Int,
        offset: Int,
        orderClause: String
    ) async throws -> [DiscoverRecipeCardData] {
        guard let url = URL(string: "\(SupabaseConfig.url)/rest/v1/recipes?select=\(Self.recipeSelect)&order=\(orderClause)&limit=\(max(1, limit))&offset=\(max(0, offset))") else {
            throw SupabaseProfileStateError.invalidRequest
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        request.setValue(SupabaseConfig.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(SupabaseConfig.anonKey)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SupabaseProfileStateError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let errorPayload = try? JSONDecoder().decode(SupabaseRestErrorResponse.self, from: data)
            let fallback = "Failed to load recipes (\(httpResponse.statusCode))."
            throw SupabaseProfileStateError.requestFailed(errorPayload?.message ?? errorPayload?.error ?? fallback)
        }

        return try JSONDecoder().decode([DiscoverRecipeCardData].self, from: data)
    }

    func fetchRankedRecipes(
        profile: UserProfile?,
        filter: String,
        query: String,
        sessionSeed: String,
        feedContext: DiscoverFeedContext,
        limit: Int = 30,
        offset: Int = 0,
        forceRefresh: Bool = false
    ) async throws -> DiscoverRankedRecipesResponse {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedFilter = DiscoverPreset.normalizedKey(for: filter)

        // The base feed should render from the public catalog immediately.
        // Waiting on the ranked Render route here can stall first paint and
        // pull-to-refresh for 20s+ before falling back to the same catalog.
        if normalizedQuery.isEmpty,
           normalizedFilter == "all" {
            do {
                let directFeed = try await fetchRotatedCatalogFeed(
                    limit: limit,
                    offset: offset,
                    sessionSeed: sessionSeed,
                    forceRefresh: forceRefresh
                )
                debugLogDiscoverFallback(
                    forceRefresh ? "direct refreshed catalog feed" : "direct catalog feed",
                    filter: filter,
                    offset: offset,
                    recipes: directFeed.recipes.count,
                    mode: directFeed.rankingMode
                )
                return directFeed
            } catch {
                debugLogDiscoverFallback(
                    "fast initial catalog failed; trying render",
                    filter: filter,
                    offset: offset,
                    recipes: 0,
                    mode: nil,
                    error: error
                )
            }
        }

        var lastError: Error?
        for candidateBaseURL in OunjeDevelopmentServer.candidateBaseURLs {
            do {
                let response = try await fetchRankedRecipes(
                    baseURL: candidateBaseURL,
                    profile: profile,
                    filter: filter,
                    query: query,
                    sessionSeed: sessionSeed,
                    feedContext: feedContext,
                    limit: limit,
                    offset: offset,
                    forceRefresh: forceRefresh
                )
                if response.recipes.isEmpty,
                   query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let normalizedFilter = DiscoverPreset.normalizedKey(for: filter)
                    if normalizedFilter != "all" {
                        let fallback = try await fetchBracketRecipesFallback(filter: filter, limit: limit, offset: offset)
                        debugLogDiscoverFallback(
                            "render empty; bracket fallback",
                            filter: filter,
                            offset: offset,
                            recipes: fallback.recipes.count,
                            mode: fallback.rankingMode
                        )
                        return fallback
                    }

                    let directFeed = try await fetchRotatedCatalogFeed(
                        limit: limit,
                        offset: offset,
                        sessionSeed: sessionSeed
                    )
                    debugLogDiscoverFallback(
                        "render empty; feed fallback",
                        filter: filter,
                        offset: offset,
                        recipes: directFeed.recipes.count,
                        mode: "supabase_direct_empty_response_fallback"
                    )
                    return DiscoverRankedRecipesResponse(
                        recipes: directFeed.recipes,
                        filters: directFeed.filters,
                        rankingMode: "supabase_direct_empty_response_fallback",
                        totalAvailable: directFeed.totalAvailable,
                        hasMore: directFeed.hasMore,
                        nextOffset: directFeed.nextOffset
                    )
                }

                return response
            } catch {
                lastError = error
                debugLogDiscoverFallback(
                    "render candidate failed",
                    filter: filter,
                    offset: offset,
                    recipes: 0,
                    mode: nil,
                    error: error
                )
            }
        }

        if normalizedQuery.isEmpty {
            if normalizedFilter != "all" {
                let fallback = try await fetchBracketRecipesFallback(filter: filter, limit: limit, offset: offset)
                debugLogDiscoverFallback(
                    "all render candidates failed; bracket fallback",
                    filter: filter,
                    offset: offset,
                    recipes: fallback.recipes.count,
                    mode: fallback.rankingMode
                )
                return fallback
            }

            let directFeed = try await fetchRotatedCatalogFeed(
                limit: limit,
                offset: offset,
                sessionSeed: sessionSeed
            )
            debugLogDiscoverFallback(
                "all render candidates failed; feed fallback",
                filter: filter,
                offset: offset,
                recipes: directFeed.recipes.count,
                mode: "supabase_direct_fallback"
            )
            return DiscoverRankedRecipesResponse(
                recipes: directFeed.recipes,
                filters: directFeed.filters,
                rankingMode: "supabase_direct_fallback",
                totalAvailable: directFeed.totalAvailable,
                hasMore: directFeed.hasMore,
                nextOffset: directFeed.nextOffset
            )
        }

        throw lastError ?? SupabaseProfileStateError.invalidResponse
    }

    func prewarmBaseCatalog(limit: Int = 96) async {
        _ = try? await fetchRecipeCount()
        _ = try? await fetchFullCatalogPool(
            fetchLimit: max(1, limit),
            sessionSeed: "prewarm",
            forceRefresh: false
        )
    }

    private func fetchRankedRecipes(
        baseURL: String,
        profile: UserProfile?,
        filter: String,
        query: String,
        sessionSeed: String,
        feedContext: DiscoverFeedContext,
        limit: Int,
        offset: Int,
        forceRefresh: Bool
    ) async throws -> DiscoverRankedRecipesResponse {
        guard let url = URL(string: "\(baseURL)/v1/recipe/discover") else {
            throw SupabaseProfileStateError.invalidRequest
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if forceRefresh {
            request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        }
        request.httpBody = try JSONEncoder().encode(
            DiscoverRankedRecipesRequest(
                profile: profile,
                filter: filter,
                query: query.isEmpty ? nil : query,
                limit: limit,
                offset: offset,
                feedContext: feedContext.withSessionSeed(sessionSeed),
                forceRefresh: forceRefresh
            )
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SupabaseProfileStateError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let errorPayload = try? JSONDecoder().decode(SupabaseRestErrorResponse.self, from: data)
            let fallback = "Failed to load ranked recipes (\(httpResponse.statusCode))."
            throw SupabaseProfileStateError.requestFailed(errorPayload?.message ?? errorPayload?.error ?? fallback)
        }

        return try JSONDecoder().decode(DiscoverRankedRecipesResponse.self, from: data)
    }

    private func fetchBracketRecipesFallback(
        filter: String,
        limit: Int,
        offset: Int
    ) async throws -> DiscoverRankedRecipesResponse {
        let normalizedFilter = DiscoverPreset.normalizedKey(for: filter)
        let select = [
            "id",
            "title",
            "description",
            "author_name",
            "author_handle",
            "category",
            "recipe_type",
            "cook_time_text",
            "cook_time_minutes",
            "published_date",
            "discover_card_image_url",
            "hero_image_url",
            "recipe_url",
            "source",
            "discover_brackets"
        ].joined(separator: ",")
        let fetchLimit = max(1, limit + 1)
        guard let encodedSelect = select.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let encodedBracket = "{\(normalizedFilter)}".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "\(SupabaseConfig.url)/rest/v1/recipes?select=\(encodedSelect)&discover_brackets=cs.\(encodedBracket)&order=id.asc&limit=\(fetchLimit)&offset=\(max(0, offset))")
        else {
            throw SupabaseProfileStateError.invalidRequest
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        request.setValue(SupabaseConfig.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(SupabaseConfig.anonKey)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SupabaseProfileStateError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let errorPayload = try? JSONDecoder().decode(SupabaseRestErrorResponse.self, from: data)
            let fallback = "Failed to load \(filter) recipes (\(httpResponse.statusCode))."
            throw SupabaseProfileStateError.requestFailed(errorPayload?.message ?? errorPayload?.error ?? fallback)
        }

        let decoded = try JSONDecoder().decode([DiscoverRecipeCardData].self, from: data)
        let pageRecipes = Array(decoded.prefix(limit))
        let hasMore = decoded.count > limit
        return DiscoverRankedRecipesResponse(
            recipes: pageRecipes,
            filters: DiscoverPreset.allTitles,
            rankingMode: "supabase_bracket_direct_fallback",
            totalAvailable: nil,
            hasMore: hasMore,
            nextOffset: hasMore ? offset + pageRecipes.count : nil
        )
    }

    private func fetchRotatedCatalogFeed(
        limit: Int,
        offset: Int,
        sessionSeed: String,
        forceRefresh: Bool = false
    ) async throws -> DiscoverRankedRecipesResponse {
        let normalizedLimit = max(1, limit)
        let normalizedOffset = max(0, offset)
        let fetchLimit = max(normalizedOffset + (normalizedLimit * 10), 144)
        let catalogResult = try await fetchFullCatalogPool(
            fetchLimit: fetchLimit,
            sessionSeed: sessionSeed,
            forceRefresh: forceRefresh
        )
        let catalog = catalogResult.recipes

        guard !catalog.isEmpty else {
            return DiscoverRankedRecipesResponse(
                recipes: [],
                filters: DiscoverPreset.allTitles,
                rankingMode: "supabase_direct_rotating_catalog",
                totalAvailable: 0,
                hasMore: false,
                nextOffset: nil
            )
        }

        let pageRecipes = Array(catalog.dropFirst(normalizedOffset).prefix(normalizedLimit))
        let totalAvailable = max(catalogResult.totalCount, catalog.count)
        let hasMore = !pageRecipes.isEmpty && normalizedOffset + pageRecipes.count < totalAvailable
        return DiscoverRankedRecipesResponse(
            recipes: pageRecipes,
            filters: DiscoverPreset.allTitles,
            rankingMode: "supabase_direct_full_catalog_sample",
            totalAvailable: totalAvailable,
            hasMore: hasMore,
            nextOffset: hasMore ? normalizedOffset + pageRecipes.count : nil
        )
    }

    private func deterministicCatalogOrderScore(id: String, seed: String) -> UInt64 {
        "\(seed)|\(id)".utf8.reduce(UInt64(1469598103934665603)) { partial, byte in
            (partial ^ UInt64(byte)) &* 1099511628211
        }
    }

    private func deterministicUnitInterval(seed: String) -> Double {
        let score = seed.utf8.reduce(UInt64(1469598103934665603)) { partial, byte in
            (partial ^ UInt64(byte)) &* 1099511628211
        }
        return Double(score % 1_000_000) / 1_000_000.0
    }

    private func fetchRecipeCount(forceRefresh: Bool = false) async throws -> Int {
        if !forceRefresh,
           let cached = recipeCountCache,
           Date().timeIntervalSince(cached.fetchedAt) < recipeCountCacheTTL {
            return cached.count
        }

        guard let url = URL(string: "\(SupabaseConfig.url)/rest/v1/recipes?select=id&limit=1") else {
            throw SupabaseProfileStateError.invalidRequest
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 8
        request.setValue(SupabaseConfig.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(SupabaseConfig.anonKey)", forHTTPHeaderField: "Authorization")
        request.setValue("count=planned", forHTTPHeaderField: "Prefer")

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SupabaseProfileStateError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw SupabaseProfileStateError.requestFailed("Failed to count recipes (\(httpResponse.statusCode)).")
        }

        let contentRange = httpResponse.value(forHTTPHeaderField: "Content-Range") ?? ""
        let total = Int(contentRange.split(separator: "/").last ?? "") ?? 0
        recipeCountCache = (count: total, fetchedAt: Date())
        return total
    }

    private func fetchFullCatalogPool(
        fetchLimit: Int,
        sessionSeed: String,
        forceRefresh: Bool = false
    ) async throws -> CatalogPoolResult {
        let normalizedFetchLimit = max(1, fetchLimit)
        let cacheKey = sessionSeed
        if !forceRefresh,
           let cached = catalogPoolCache[cacheKey],
           cached.recipes.count >= normalizedFetchLimit {
            return cached
        }

        let totalCount = try await fetchRecipeCount(forceRefresh: forceRefresh)
        if totalCount <= normalizedFetchLimit {
            let recipes = try await fetchRecipes(limit: max(totalCount, normalizedFetchLimit), offset: 0)
            let result = CatalogPoolResult(
                recipes: deduplicatedRecipes(recipes),
                totalCount: max(totalCount, recipes.count),
                windowsFetched: 0
            )
            catalogPoolCache[cacheKey] = result
            return result
        }

        let cached = forceRefresh ? nil : catalogPoolCache[cacheKey]
        let existingRecipes = cached?.recipes ?? []
        if !existingRecipes.isEmpty, existingRecipes.count >= totalCount {
            let result = CatalogPoolResult(
                recipes: existingRecipes,
                totalCount: totalCount,
                windowsFetched: cached?.windowsFetched ?? 0
            )
            catalogPoolCache[cacheKey] = result
            return result
        }

        let windowSize = min(max(normalizedFetchLimit / 4, 36), 60)
        let startWindowIndex = cached?.windowsFetched ?? 0
        let requestedWindowCount = max(4, Int(ceil(Double(normalizedFetchLimit) / Double(windowSize))))
        let targetWindowCount = min(max(requestedWindowCount, startWindowIndex + 4), 30)
        let maxOffset = max(0, totalCount - windowSize)
        var windows: [[DiscoverRecipeCardData]] = []

        try await withThrowingTaskGroup(of: [DiscoverRecipeCardData].self) { group in
            for index in startWindowIndex..<targetWindowCount {
                let windowOffset = Int(
                    floor(deterministicUnitInterval(seed: "\(sessionSeed)|window|\(index)") * Double(maxOffset + 1))
                )
                group.addTask {
                    try await self.fetchRecipes(
                        limit: windowSize,
                        offset: windowOffset,
                        orderClause: "id.asc"
                    )
                }
            }

            for try await recipes in group {
                windows.append(recipes)
            }
        }

        let orderedNewRecipes = windows.flatMap { $0 }.sorted { lhs, rhs in
            let leftScore = deterministicCatalogOrderScore(id: lhs.id, seed: sessionSeed)
            let rightScore = deterministicCatalogOrderScore(id: rhs.id, seed: sessionSeed)
            if leftScore == rightScore {
                return lhs.id < rhs.id
            }
            return leftScore < rightScore
        }
        let sampledRecipes = deduplicatedRecipes(existingRecipes + orderedNewRecipes)
        let recipes: [DiscoverRecipeCardData]
        if sampledRecipes.isEmpty {
            recipes = try await fetchRecipes(limit: min(normalizedFetchLimit, max(totalCount, 1)), offset: 0)
        } else {
            recipes = sampledRecipes
        }

        let result = CatalogPoolResult(
            recipes: recipes,
            totalCount: totalCount,
            windowsFetched: max(cached?.windowsFetched ?? 0, targetWindowCount)
        )
        catalogPoolCache[cacheKey] = result
        return result
    }

    private func deduplicatedRecipes(_ recipes: [DiscoverRecipeCardData]) -> [DiscoverRecipeCardData] {
        var seen = Set<String>()
        return recipes.filter { recipe in
            seen.insert(recipe.id).inserted
        }
    }

    private func debugLogDiscoverFallback(
        _ message: String,
        filter: String,
        offset: Int,
        recipes: Int,
        mode: String?,
        error: Error? = nil
    ) {
        #if DEBUG
        let normalizedFilter = DiscoverPreset.normalizedKey(for: filter)
        let modeDescription = mode.map { " mode=\($0)" } ?? ""
        let errorDescription = error.map { " error=\($0.localizedDescription)" } ?? ""
        print("[DiscoverService] \(message) filter=\(normalizedFilter) offset=\(offset) recipes=\(recipes)\(modeDescription)\(errorDescription)")
        #endif
    }
}
