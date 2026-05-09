import Foundation

final class SupabaseDiscoverRecipeService {
    static let shared = SupabaseDiscoverRecipeService()

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
            if normalizedFilter != "all" {
                return try await fetchBracketRecipesFallback(filter: filter, limit: limit, offset: offset)
            }

            let fallbackRecipes = try await fetchRecipes(limit: limit, offset: offset)
            return DiscoverRankedRecipesResponse(
                recipes: fallbackRecipes,
                filters: DiscoverPreset.allTitles,
                rankingMode: "supabase_direct_fallback",
                totalAvailable: fallbackRecipes.count,
                hasMore: fallbackRecipes.count >= limit,
                nextOffset: fallbackRecipes.count >= limit ? offset + fallbackRecipes.count : nil
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
}
