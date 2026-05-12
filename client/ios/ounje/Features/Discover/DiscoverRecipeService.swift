import Foundation

final class SupabaseDiscoverRecipeService {
    static let shared = SupabaseDiscoverRecipeService()

    private var catalogPoolCache: [Int: [DiscoverRecipeCardData]] = [:]

    private init() {}

    func fetchRecipes(limit: Int = 30, offset: Int = 0) async throws -> [DiscoverRecipeCardData] {
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

        guard let url = URL(string: "\(SupabaseConfig.url)/rest/v1/recipes?select=\(select)&order=updated_at.desc.nullslast,published_date.desc.nullslast&limit=\(limit)&offset=\(max(0, offset))") else {
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
        _ = try? await fetchCatalogPool(fetchLimit: max(1, limit))
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
        let fetchLimit = min(max(normalizedOffset + (normalizedLimit * 8), 96), 240)
        let catalog = try await fetchCatalogPool(fetchLimit: fetchLimit, forceRefresh: forceRefresh)

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

        let shuffledCatalog = catalog.sorted { lhs, rhs in
            let leftScore = deterministicCatalogOrderScore(id: lhs.id, seed: sessionSeed)
            let rightScore = deterministicCatalogOrderScore(id: rhs.id, seed: sessionSeed)
            if leftScore == rightScore {
                return lhs.id < rhs.id
            }
            return leftScore < rightScore
        }

        let pageRecipes = Array(shuffledCatalog.dropFirst(normalizedOffset).prefix(normalizedLimit))
        let hasMore = normalizedOffset + pageRecipes.count < shuffledCatalog.count
        return DiscoverRankedRecipesResponse(
            recipes: pageRecipes,
            filters: DiscoverPreset.allTitles,
            rankingMode: "supabase_direct_rotating_catalog",
            totalAvailable: shuffledCatalog.count,
            hasMore: hasMore,
            nextOffset: hasMore ? normalizedOffset + pageRecipes.count : nil
        )
    }

    private func deterministicCatalogOrderScore(id: String, seed: String) -> UInt64 {
        "\(seed)|\(id)".utf8.reduce(UInt64(1469598103934665603)) { partial, byte in
            (partial ^ UInt64(byte)) &* 1099511628211
        }
    }

    private func fetchCatalogPool(fetchLimit: Int, forceRefresh: Bool = false) async throws -> [DiscoverRecipeCardData] {
        if !forceRefresh, let cached = catalogPoolCache[fetchLimit], !cached.isEmpty {
            return cached
        }

        let catalog = try await fetchRecipes(limit: fetchLimit, offset: 0)
        catalogPoolCache[fetchLimit] = catalog
        return catalog
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
