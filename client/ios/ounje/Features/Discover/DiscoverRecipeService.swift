import Foundation

final class SupabaseDiscoverRecipeService {
    static let shared = SupabaseDiscoverRecipeService()

    private init() {}

    func fetchRecipes(limit: Int = 30) async throws -> [DiscoverRecipeCardData] {
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

        guard let url = URL(string: "\(SupabaseConfig.url)/rest/v1/recipes?select=\(select)&order=updated_at.desc.nullslast,published_date.desc.nullslast&limit=\(limit)") else {
            throw SupabaseProfileStateError.invalidRequest
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
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
        offset: Int = 0
    ) async throws -> DiscoverRankedRecipesResponse {
        var lastError: Error?
        for candidateBaseURL in OunjeDevelopmentServer.candidateBaseURLs {
            do {
                return try await fetchRankedRecipes(
                    baseURL: candidateBaseURL,
                    profile: profile,
                    filter: filter,
                    query: query,
                    sessionSeed: sessionSeed,
                    feedContext: feedContext,
                    limit: limit,
                    offset: offset
                )
            } catch {
                lastError = error
            }
        }

        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalizedQuery.isEmpty {
            let normalizedFilter = DiscoverPreset.normalizedKey(for: filter)
            let fallbackLimit = normalizedFilter == "all" ? limit : max(limit * 10, 180)
            let fallbackRecipes = try await fetchRecipes(limit: fallbackLimit)
            let visibleRecipes = normalizedFilter == "all"
                ? fallbackRecipes
                : fallbackRecipes.filter { $0.matchesDiscoverFilter(filter) }
            let pageEnd = min(visibleRecipes.count, offset + limit)
            let pageRecipes = offset < pageEnd
                ? Array(visibleRecipes[offset..<pageEnd])
                : []
            return DiscoverRankedRecipesResponse(
                recipes: pageRecipes,
                filters: DiscoverPreset.allTitles,
                rankingMode: "supabase_direct_fallback",
                totalAvailable: visibleRecipes.count,
                hasMore: pageEnd < visibleRecipes.count,
                nextOffset: pageEnd < visibleRecipes.count ? pageEnd : nil
            )
        }

        throw lastError ?? SupabaseProfileStateError.invalidResponse
    }

    private func fetchRankedRecipes(
        baseURL: String,
        profile: UserProfile?,
        filter: String,
        query: String,
        sessionSeed: String,
        feedContext: DiscoverFeedContext,
        limit: Int,
        offset: Int
    ) async throws -> DiscoverRankedRecipesResponse {
        guard let url = URL(string: "\(baseURL)/v1/recipe/discover") else {
            throw SupabaseProfileStateError.invalidRequest
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            DiscoverRankedRecipesRequest(
                profile: profile,
                filter: filter,
                query: query.isEmpty ? nil : query,
                limit: limit,
                offset: offset,
                feedContext: feedContext.withSessionSeed(sessionSeed)
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
}
