import Foundation

protocol RecipeCatalog {
    func recipes(
        for profile: UserProfile,
        historyRecipeIDs: [String],
        regenerationContext: PrepRegenerationContext?,
        savedRecipeIDs: [String]
    ) async -> [Recipe]
}

actor LocalRecipeCatalog: RecipeCatalog {
    func recipes(
        for profile: UserProfile,
        historyRecipeIDs: [String] = [],
        regenerationContext: PrepRegenerationContext? = nil,
        savedRecipeIDs: [String] = []
    ) async -> [Recipe] {
        []
    }
}

actor RemoteRecipeCatalog: RecipeCatalog {
    private let fallbackCatalog: RecipeCatalog
    private let session: URLSession

    init(fallbackCatalog: RecipeCatalog = LocalRecipeCatalog(), session: URLSession = .shared) {
        self.fallbackCatalog = fallbackCatalog
        self.session = session
    }

    func recipes(
        for profile: UserProfile,
        historyRecipeIDs: [String] = [],
        regenerationContext: PrepRegenerationContext? = nil,
        savedRecipeIDs: [String] = []
    ) async -> [Recipe] {
        do {
            let response = try await fetchRemoteRecipesWithFallback(
                profile: profile,
                historyRecipeIDs: historyRecipeIDs,
                regenerationContext: regenerationContext,
                savedRecipeIDs: savedRecipeIDs,
                limit: max(48, profile.cadence.baseRecipeCount * 12)
            )
            if !response.recipes.isEmpty {
                return response.recipes
            }
        } catch {
            // Keep prep empty if remote candidates fail; we no longer ship seeded sample recipes.
        }

        return await fallbackCatalog.recipes(
            for: profile,
            historyRecipeIDs: historyRecipeIDs,
            regenerationContext: regenerationContext,
            savedRecipeIDs: savedRecipeIDs
        )
    }

    private func fetchRemoteRecipesWithFallback(
        profile: UserProfile,
        historyRecipeIDs: [String],
        regenerationContext: PrepRegenerationContext?,
        savedRecipeIDs: [String],
        limit: Int
    ) async throws -> PrepCandidateRecipesResponse {
        var lastError: Error?

        for candidateBaseURL in OunjeDevelopmentServer.candidateBaseURLs {
            do {
                return try await fetchRemoteRecipes(
                    baseURL: candidateBaseURL,
                    profile: profile,
                    historyRecipeIDs: historyRecipeIDs,
                    regenerationContext: regenerationContext,
                    savedRecipeIDs: savedRecipeIDs,
                    limit: limit
                )
            } catch {
                lastError = error
            }
        }

        throw lastError ?? URLError(.cannotConnectToHost)
    }

    private func fetchRemoteRecipes(
        baseURL: String,
        profile: UserProfile,
        historyRecipeIDs: [String],
        regenerationContext: PrepRegenerationContext?,
        savedRecipeIDs: [String],
        limit: Int
    ) async throws -> PrepCandidateRecipesResponse {
        guard let url = URL(string: "\(baseURL)/v1/recipe/prep-candidates") else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 25
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            PrepCandidateRecipesRequest(
                profile: profile,
                historyRecipeIDs: historyRecipeIDs,
                regenerationContext: regenerationContext.map(PrepRegenerationContextPayload.init),
                savedRecipeIDs: savedRecipeIDs,
                limit: limit
            )
        )

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw URLError(.badServerResponse)
        }

        return try JSONDecoder().decode(PrepCandidateRecipesResponse.self, from: data)
    }
}

private struct PrepCandidateRecipesRequest: Encodable {
    let profile: UserProfile
    let historyRecipeIDs: [String]
    let regenerationContext: PrepRegenerationContextPayload?
    let savedRecipeIDs: [String]
    let limit: Int

    enum CodingKeys: String, CodingKey {
        case profile
        case historyRecipeIDs = "history_recipe_ids"
        case regenerationContext = "regeneration_context"
        case savedRecipeIDs = "saved_recipe_ids"
        case limit
    }
}

private struct PrepRegenerationContextPayload: Encodable {
    let focus: String
    let currentRecipeIDs: [String]
    let currentRecipes: [PrepRegenerationRecipePayload]
    let userPrompt: String?

    init(_ context: PrepRegenerationContext) {
        focus = context.focus.rawValue
        currentRecipeIDs = context.currentRecipes.map(\.id)
        currentRecipes = context.currentRecipes.map(PrepRegenerationRecipePayload.init)
        let trimmedPrompt = context.userPrompt?.trimmingCharacters(in: .whitespacesAndNewlines)
        userPrompt = (trimmedPrompt?.isEmpty == false) ? trimmedPrompt : nil
    }

    enum CodingKeys: String, CodingKey {
        case focus
        case currentRecipeIDs = "current_recipe_ids"
        case currentRecipes = "current_recipes"
        case userPrompt = "user_prompt"
    }
}

private struct PrepRegenerationRecipePayload: Encodable {
    let id: String
    let title: String
    let cuisine: String
    let prepMinutes: Int
    let tags: [String]
    let ingredients: [String]

    init(_ recipe: Recipe) {
        id = recipe.id
        title = recipe.title
        cuisine = recipe.cuisine.rawValue
        prepMinutes = recipe.prepMinutes
        tags = recipe.tags
        ingredients = recipe.ingredients.map(\.name)
    }

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case cuisine
        case prepMinutes = "prep_minutes"
        case tags
        case ingredients
    }
}

private struct PrepCandidateRecipesResponse: Decodable {
    let recipes: [Recipe]
    let rankingMode: String?
}
