import Foundation
import UIKit

struct SupabaseAppleUserSession {
    let userID: String
    let email: String?
    let displayName: String?
    let accessToken: String?
    let refreshToken: String?
}

enum SupabaseAppleAuthError: LocalizedError {
    case invalidRequest
    case invalidResponse
    case authFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidRequest:
            return "Could not construct Apple sign-in request."
        case .invalidResponse:
            return "Unexpected response from auth server."
        case .authFailed(let message):
            return message
        }
    }
}

final class SupabaseAppleAuthService {
    static let shared = SupabaseAppleAuthService()

    private init() {}

    func signInWithApple(idToken: String, rawNonce: String) async throws -> SupabaseAppleUserSession {
        guard let url = URL(string: "\(SupabaseConfig.url)/auth/v1/token?grant_type=id_token") else {
            throw SupabaseAppleAuthError.invalidRequest
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(SupabaseConfig.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(SupabaseConfig.anonKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(SupabaseIdTokenRequest(
            provider: "apple",
            idToken: idToken,
            nonce: rawNonce
        ))

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SupabaseAppleAuthError.invalidResponse
        }

        if !(200...299).contains(httpResponse.statusCode) {
            let errorPayload = try? JSONDecoder().decode(SupabaseAuthErrorResponse.self, from: data)
            let fallback = "Apple sign-in failed (\(httpResponse.statusCode))."
            let message = errorPayload?.errorDescription ?? errorPayload?.msg ?? errorPayload?.error ?? fallback
            throw SupabaseAppleAuthError.authFailed(message)
        }

        let tokenResponse = try JSONDecoder().decode(SupabaseTokenResponse.self, from: data)
        let user = tokenResponse.user
        let displayName = user.userMetadata?.fullName ?? user.userMetadata?.name

        return SupabaseAppleUserSession(
            userID: user.id,
            email: user.email,
            displayName: displayName,
            accessToken: tokenResponse.accessToken,
            refreshToken: tokenResponse.refreshToken
        )
    }
}

struct SupabaseRefreshedSession {
    let userID: String
    let email: String?
    let displayName: String?
    let accessToken: String
    let refreshToken: String?
}

enum SupabaseAuthSessionRefreshError: LocalizedError {
    case invalidRequest
    case invalidResponse
    case refreshFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidRequest:
            return "Could not construct the auth refresh request."
        case .invalidResponse:
            return "Unexpected auth refresh response."
        case .refreshFailed(let message):
            return message
        }
    }
}

final class SupabaseAuthSessionRefreshService {
    static let shared = SupabaseAuthSessionRefreshService()

    private init() {}

    func refreshSession(refreshToken: String) async throws -> SupabaseRefreshedSession {
        guard let url = URL(string: "\(SupabaseConfig.url)/auth/v1/token?grant_type=refresh_token") else {
            throw SupabaseAuthSessionRefreshError.invalidRequest
        }

        let normalizedRefreshToken = refreshToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedRefreshToken.isEmpty else {
            throw SupabaseAuthSessionRefreshError.invalidRequest
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(SupabaseConfig.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(SupabaseConfig.anonKey)", forHTTPHeaderField: "Authorization")
        var bodyComponents = URLComponents()
        bodyComponents.queryItems = [
            URLQueryItem(name: "refresh_token", value: normalizedRefreshToken),
        ]
        request.httpBody = bodyComponents.percentEncodedQuery?.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SupabaseAuthSessionRefreshError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let errorPayload = try? JSONDecoder().decode(SupabaseAuthErrorResponse.self, from: data)
            let fallback = "Supabase session refresh failed (\(httpResponse.statusCode))."
            let message = errorPayload?.errorDescription ?? errorPayload?.msg ?? errorPayload?.error ?? fallback
            throw SupabaseAuthSessionRefreshError.refreshFailed(message)
        }

        let tokenResponse = try JSONDecoder().decode(SupabaseTokenResponse.self, from: data)
        let user = tokenResponse.user
        let displayName = user.userMetadata?.fullName ?? user.userMetadata?.name
        return SupabaseRefreshedSession(
            userID: user.id,
            email: user.email,
            displayName: displayName,
            accessToken: tokenResponse.accessToken,
            refreshToken: tokenResponse.refreshToken
        )
    }
}

enum SupabaseProfileStateError: LocalizedError {
    case invalidRequest
    case invalidResponse
    case requestFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidRequest:
            return "Could not construct profile state request."
        case .invalidResponse:
            return "Unexpected response from profile state API."
        case .requestFailed(let message):
            return message
        }
    }
}

enum SupabaseSavedRecipesError: LocalizedError {
    case invalidRequest
    case invalidResponse
    case requestFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidRequest:
            return "Could not construct saved recipes request."
        case .invalidResponse:
            return "Unexpected response from saved recipes API."
        case .requestFailed(let message):
            return message
        }
    }
}

final class SupabaseProfileStateService {
    static let shared = SupabaseProfileStateService()

    private init() {}

    func fetchOrCreateProfileState(
        userID: String,
        email: String?,
        displayName: String?,
        authProvider: AuthProvider?
    ) async throws -> SupabaseProfileStateSnapshot {
        if let row = try await fetchProfile(userID: userID) {
            let hasPersistedProfile = row.decodedProfile != nil
            let resolvedOnboarded = (row.onboarded ?? false) && hasPersistedProfile

            if (row.onboarded ?? false) && !hasPersistedProfile {
                try await upsertProfile(
                    userID: userID,
                    email: email,
                    displayName: displayName,
                    authProvider: authProvider,
                    onboarded: false,
                    lastOnboardingStep: row.lastOnboardingStep ?? 0,
                    profile: nil
                )
            }

            return SupabaseProfileStateSnapshot(
                onboarded: resolvedOnboarded,
                profile: row.decodedProfile,
                lastOnboardingStep: row.lastOnboardingStep ?? 0,
                email: row.email,
                displayName: row.displayName,
                authProvider: row.authProvider.flatMap(AuthProvider.init(rawValue:)),
                accountStatus: row.accountStatus,
                deactivatedAt: row.deactivatedAt
            )
        }

        if let email, let row = try await fetchProfile(email: email) {
            let recoveredProfile = row.decodedProfile
            let resolvedOnboarded = (row.onboarded ?? false) && recoveredProfile != nil
            let resolvedStep = row.lastOnboardingStep ?? 0

            try await upsertProfile(
                userID: userID,
                email: row.email ?? email,
                displayName: recoveredProfile?.trimmedPreferredName ?? row.displayName ?? displayName,
                authProvider: authProvider ?? row.authProvider.flatMap(AuthProvider.init(rawValue:)),
                onboarded: resolvedOnboarded,
                lastOnboardingStep: resolvedStep,
                profile: recoveredProfile
            )

            return SupabaseProfileStateSnapshot(
                onboarded: resolvedOnboarded,
                profile: recoveredProfile,
                lastOnboardingStep: resolvedStep,
                email: row.email ?? email,
                displayName: recoveredProfile?.trimmedPreferredName ?? row.displayName ?? displayName,
                authProvider: authProvider ?? row.authProvider.flatMap(AuthProvider.init(rawValue:)),
                accountStatus: row.accountStatus,
                deactivatedAt: row.deactivatedAt
            )
        }

        try await upsertProfile(
            userID: userID,
            email: email,
            displayName: displayName,
            authProvider: authProvider,
            onboarded: false,
            lastOnboardingStep: 0,
            profile: nil
        )
        return SupabaseProfileStateSnapshot(
            onboarded: false,
            profile: nil,
            lastOnboardingStep: 0,
            email: email,
            displayName: displayName,
            authProvider: authProvider,
            accountStatus: "active",
            deactivatedAt: nil
        )
    }

    func upsertProfile(
        userID: String,
        email: String?,
        displayName: String?,
        authProvider: AuthProvider?,
        onboarded: Bool,
        lastOnboardingStep: Int,
        profile: UserProfile?
    ) async throws {
        guard let url = URL(string: "\(SupabaseConfig.url)/rest/v1/profiles?on_conflict=id") else {
            throw SupabaseProfileStateError.invalidRequest
        }

        let payload = SupabaseProfileUpsertPayload(
            id: userID,
            email: email,
            displayName: displayName,
            authProvider: authProvider?.rawValue,
            onboarded: onboarded,
            onboardingCompletedAt: onboarded ? ISO8601DateFormatter().string(from: Date()) : nil,
            lastOnboardingStep: lastOnboardingStep,
            preferredName: profile?.trimmedPreferredName,
            preferredCuisines: profile?.preferredCuisines.map(\.rawValue) ?? [],
            cuisineCountries: profile?.cuisineCountries ?? [],
            dietaryPatterns: profile?.dietaryPatterns ?? [],
            hardRestrictions: profile?.absoluteRestrictions ?? [],
            cadence: profile?.cadence.rawValue,
            deliveryAnchorDay: profile?.deliveryAnchorDay.rawValue,
            adults: profile?.consumption.adults,
            kids: profile?.consumption.kids,
            cooksForOthers: profile?.cooksForOthers,
            mealsPerWeek: profile?.consumption.mealsPerWeek,
            budgetPerCycle: profile?.budgetPerCycle,
            budgetWindow: profile?.budgetWindow.rawValue,
            orderingAutonomy: profile?.orderingAutonomy.rawValue,
            addressLine1: profile?.deliveryAddress.line1,
            addressLine2: profile?.deliveryAddress.line2,
            city: profile?.deliveryAddress.city,
            region: profile?.deliveryAddress.region,
            postalCode: profile?.deliveryAddress.postalCode,
            deliveryNotes: profile?.deliveryAddress.deliveryNotes,
            profileJSON: profile
        )

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(SupabaseConfig.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(SupabaseConfig.anonKey)", forHTTPHeaderField: "Authorization")
        request.setValue("resolution=merge-duplicates,return=minimal", forHTTPHeaderField: "Prefer")
        request.httpBody = try JSONEncoder().encode([payload])

        let (data, httpResponse) = try await perform(request)
        guard (200...299).contains(httpResponse.statusCode) else {
            let errorPayload = try? JSONDecoder().decode(SupabaseRestErrorResponse.self, from: data)
            let fallback = "Failed to save onboarding state (\(httpResponse.statusCode))."
            throw SupabaseProfileStateError.requestFailed(errorPayload?.message ?? errorPayload?.error ?? fallback)
        }
    }

    private func fetchProfile(userID: String) async throws -> SupabaseProfileRow? {
        guard let encodedID = userID.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "\(SupabaseConfig.url)/rest/v1/profiles?select=*&id=eq.\(encodedID)&limit=1") else {
            throw SupabaseProfileStateError.invalidRequest
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(SupabaseConfig.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(SupabaseConfig.anonKey)", forHTTPHeaderField: "Authorization")

        let (data, httpResponse) = try await perform(request)
        guard (200...299).contains(httpResponse.statusCode) else {
            let errorPayload = try? JSONDecoder().decode(SupabaseRestErrorResponse.self, from: data)
            let fallback = "Failed to read onboarding state (\(httpResponse.statusCode))."
            throw SupabaseProfileStateError.requestFailed(errorPayload?.message ?? errorPayload?.error ?? fallback)
        }

        let rows = try JSONDecoder().decode([SupabaseProfileRow].self, from: data)
        return rows.first
    }

    private func fetchProfile(email: String) async throws -> SupabaseProfileRow? {
        guard let encodedEmail = email.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "\(SupabaseConfig.url)/rest/v1/profiles?select=*&email=eq.\(encodedEmail)&limit=1") else {
            throw SupabaseProfileStateError.invalidRequest
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(SupabaseConfig.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(SupabaseConfig.anonKey)", forHTTPHeaderField: "Authorization")

        let (data, httpResponse) = try await perform(request)
        guard (200...299).contains(httpResponse.statusCode) else {
            let errorPayload = try? JSONDecoder().decode(SupabaseRestErrorResponse.self, from: data)
            let fallback = "Failed to read onboarding state by email (\(httpResponse.statusCode))."
            throw SupabaseProfileStateError.requestFailed(errorPayload?.message ?? errorPayload?.error ?? fallback)
        }

        let rows = try JSONDecoder().decode([SupabaseProfileRow].self, from: data)
        return rows.first
    }

    private func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SupabaseProfileStateError.invalidResponse
        }
        return (data, httpResponse)
    }
}

enum OunjeAccountServiceError: LocalizedError {
    case invalidRequest
    case invalidResponse
    case requestFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidRequest:
            return "Could not create the account request."
        case .invalidResponse:
            return "Unexpected response from account service."
        case .requestFailed(let message):
            return message
        }
    }
}

final class OunjeAccountService {
    static let shared = OunjeAccountService()

    private init() {}

    func deactivateAccount(userID: String, accessToken: String?) async throws {
        var lastError: Error?
        for baseURL in OunjeDevelopmentServer.candidateBaseURLs {
            do {
                try await deactivateAccount(baseURL: baseURL, userID: userID, accessToken: accessToken)
                return
            } catch {
                lastError = error
            }
        }

        throw lastError ?? URLError(.cannotConnectToHost)
    }

    private func deactivateAccount(baseURL: String, userID: String, accessToken: String?) async throws {
        guard let url = URL(string: "\(baseURL)/v1/account/deactivate") else {
            throw OunjeAccountServiceError.invalidRequest
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(userID, forHTTPHeaderField: "X-User-ID")
        if let accessToken, !accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw OunjeAccountServiceError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let errorPayload = try? JSONDecoder().decode(SupabaseRestErrorResponse.self, from: data)
            throw OunjeAccountServiceError.requestFailed(
                errorPayload?.message ?? errorPayload?.error ?? "Account deletion failed (\(httpResponse.statusCode))."
            )
        }
    }
}

final class SupabaseSavedRecipesService {
    static let shared = SupabaseSavedRecipesService()
    private let legacyKey = "ounje-saved-recipes-v1"
    private let keyPrefix = "ounje-saved-recipes-v2"

    private init() {}

    func resolvedSavedRecipeIDs(userID: String?, accessToken: String? = nil) async -> [String] {
        let localIDs = locallyCachedSavedRecipeIDs(userID: userID)
        guard let userID else { return localIDs }

        do {
            let remoteIDs = try await fetchSavedRecipeIDs(userID: userID, accessToken: accessToken)
            return Array(Set(localIDs + remoteIDs))
        } catch {
            return localIDs
        }
    }

    func fetchSavedRecipeIDs(userID: String, accessToken: String? = nil) async throws -> [String] {
        guard let encodedUserID = userID.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(
                string: "\(SupabaseConfig.url)/rest/v1/saved_recipes?select=recipe_id&user_id=eq.\(encodedUserID)&order=saved_at.desc"
              ) else {
            throw SupabaseSavedRecipesError.invalidRequest
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        applyAuthHeaders(to: &request, accessToken: accessToken)

        let (data, httpResponse) = try await perform(request)
        guard (200...299).contains(httpResponse.statusCode) else {
            let errorPayload = try? JSONDecoder().decode(SupabaseRestErrorResponse.self, from: data)
            let fallback = "Failed to read saved recipe ids (\(httpResponse.statusCode))."
            throw SupabaseSavedRecipesError.requestFailed(errorPayload?.message ?? errorPayload?.error ?? fallback)
        }

        return try JSONDecoder().decode([SupabaseSavedRecipeIDRow].self, from: data).map(\.recipeID)
    }

    func fetchSavedRecipeTitles(userID: String, accessToken: String? = nil) async throws -> [String] {
        guard let encodedUserID = userID.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(
                string: "\(SupabaseConfig.url)/rest/v1/saved_recipes?select=title&user_id=eq.\(encodedUserID)&order=saved_at.desc"
              ) else {
            throw SupabaseSavedRecipesError.invalidRequest
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        applyAuthHeaders(to: &request, accessToken: accessToken)

        let (data, httpResponse) = try await perform(request)
        guard (200...299).contains(httpResponse.statusCode) else {
            let errorPayload = try? JSONDecoder().decode(SupabaseRestErrorResponse.self, from: data)
            let fallback = "Failed to read saved recipe titles (\(httpResponse.statusCode))."
            throw SupabaseSavedRecipesError.requestFailed(errorPayload?.message ?? errorPayload?.error ?? fallback)
        }

        return try JSONDecoder().decode([SupabaseSavedRecipeTitleRow].self, from: data)
            .map(\.title)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    func fetchSavedRecipes(userID: String, accessToken: String? = nil) async throws -> [DiscoverRecipeCardData] {
        guard let encodedUserID = userID.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(
                string: "\(SupabaseConfig.url)/rest/v1/saved_recipes?select=recipe_id,title,description,author_name,author_handle,category,recipe_type,cook_time_text,published_date,discover_card_image_url,hero_image_url,recipe_url,source&user_id=eq.\(encodedUserID)&order=saved_at.desc"
              ) else {
            throw SupabaseSavedRecipesError.invalidRequest
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        applyAuthHeaders(to: &request, accessToken: accessToken)

        let (data, httpResponse) = try await perform(request)
        guard (200...299).contains(httpResponse.statusCode) else {
            let errorPayload = try? JSONDecoder().decode(SupabaseRestErrorResponse.self, from: data)
            let fallback = "Failed to read saved recipes (\(httpResponse.statusCode))."
            throw SupabaseSavedRecipesError.requestFailed(errorPayload?.message ?? errorPayload?.error ?? fallback)
        }

        let rows = try JSONDecoder().decode([SupabaseSavedRecipeRow].self, from: data)
        let hydratedRows = (try? await hydrateSavedRecipeRows(rows, accessToken: accessToken)) ?? rows
        return hydratedRows.map(\.recipe)
    }

    func upsertSavedRecipes(userID: String, recipes: [DiscoverRecipeCardData], accessToken: String? = nil) async throws {
        guard !recipes.isEmpty,
              let url = URL(string: "\(SupabaseConfig.url)/rest/v1/saved_recipes?on_conflict=user_id,recipe_id") else {
            throw SupabaseSavedRecipesError.invalidRequest
        }

        let formatter = ISO8601DateFormatter()
        let payload = recipes.map {
            SupabaseSavedRecipeUpsertPayload(
                userID: userID,
                recipe: $0,
                savedAt: formatter.string(from: Date())
            )
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyAuthHeaders(to: &request, accessToken: accessToken)
        request.setValue("resolution=merge-duplicates,return=minimal", forHTTPHeaderField: "Prefer")
        request.httpBody = try JSONEncoder().encode(payload)

        let (data, httpResponse) = try await perform(request)
        guard (200...299).contains(httpResponse.statusCode) else {
            let errorPayload = try? JSONDecoder().decode(SupabaseRestErrorResponse.self, from: data)
            let fallback = "Failed to save recipe bookmark (\(httpResponse.statusCode))."
            throw SupabaseSavedRecipesError.requestFailed(errorPayload?.message ?? errorPayload?.error ?? fallback)
        }
    }

    func deleteSavedRecipe(userID: String, recipeID: String, accessToken: String? = nil) async throws {
        guard let encodedUserID = userID.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let encodedRecipeID = recipeID.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(
                string: "\(SupabaseConfig.url)/rest/v1/saved_recipes?user_id=eq.\(encodedUserID)&recipe_id=eq.\(encodedRecipeID)"
              ) else {
            throw SupabaseSavedRecipesError.invalidRequest
        }

        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        applyAuthHeaders(to: &request, accessToken: accessToken)

        let (data, httpResponse) = try await perform(request)
        guard (200...299).contains(httpResponse.statusCode) else {
            let errorPayload = try? JSONDecoder().decode(SupabaseRestErrorResponse.self, from: data)
            let fallback = "Failed to remove saved recipe (\(httpResponse.statusCode))."
            throw SupabaseSavedRecipesError.requestFailed(errorPayload?.message ?? errorPayload?.error ?? fallback)
        }
    }

    private func applyAuthHeaders(to request: inout URLRequest, accessToken: String?) {
        let bearer = accessToken?.trimmingCharacters(in: .whitespacesAndNewlines)
        request.setValue(SupabaseConfig.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \((bearer?.isEmpty == false ? bearer : nil) ?? SupabaseConfig.anonKey)", forHTTPHeaderField: "Authorization")
    }

    private func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SupabaseSavedRecipesError.invalidResponse
        }
        return (data, httpResponse)
    }

    private func hydrateSavedRecipeRows(_ rows: [SupabaseSavedRecipeRow], accessToken: String?) async throws -> [SupabaseSavedRecipeRow] {
        let idsNeedingHydration = rows
            .filter(\.needsCanonicalImageHydration)
            .map(\.recipeID)

        guard !idsNeedingHydration.isEmpty else { return rows }

        let canonicalImages = try await fetchCanonicalRecipeCardImages(recipeIDs: idsNeedingHydration, accessToken: accessToken)
        guard !canonicalImages.isEmpty else { return rows }

        return rows.map { row in
            guard let canonical = canonicalImages[row.recipeID] else {
                return row
            }
            return row.hydratingImages(from: canonical)
        }
    }

    private func fetchCanonicalRecipeCardImages(recipeIDs: [String], accessToken: String?) async throws -> [String: SupabaseRecipeCardImageRow] {
        let uniqueIDs = Array(Set(recipeIDs))
        let importedIDs = uniqueIDs.filter { $0.hasPrefix("uir_") }
        let baseRecipeIDs = uniqueIDs.filter { !$0.hasPrefix("uir_") }

        var resolved: [String: SupabaseRecipeCardImageRow] = [:]
        for (tableName, ids) in [("user_import_recipes", importedIDs), ("recipes", baseRecipeIDs)] where !ids.isEmpty {
            let rows = try await fetchCanonicalRecipeCardImages(tableName: tableName, recipeIDs: ids, accessToken: accessToken)
            for row in rows {
                resolved[row.id] = row
            }
        }

        return resolved
    }

    private func fetchCanonicalRecipeCardImages(tableName: String, recipeIDs: [String], accessToken: String?) async throws -> [SupabaseRecipeCardImageRow] {
        guard !recipeIDs.isEmpty else { return [] }

        var aggregated: [SupabaseRecipeCardImageRow] = []
        let chunkSize = 40

        for startIndex in stride(from: 0, to: recipeIDs.count, by: chunkSize) {
            let endIndex = min(startIndex + chunkSize, recipeIDs.count)
            let chunk = Array(recipeIDs[startIndex..<endIndex])

            var components = URLComponents(string: "\(SupabaseConfig.url)/rest/v1/\(tableName)")
            components?.queryItems = [
                URLQueryItem(name: "select", value: "id,discover_card_image_url,hero_image_url"),
                URLQueryItem(name: "id", value: "in.(\(chunk.joined(separator: ",")))")
            ]

            guard let url = components?.url else {
                throw SupabaseSavedRecipesError.invalidRequest
            }

            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            applyAuthHeaders(to: &request, accessToken: accessToken)

            let (data, httpResponse) = try await perform(request)
            guard (200...299).contains(httpResponse.statusCode) else {
                let errorPayload = try? JSONDecoder().decode(SupabaseRestErrorResponse.self, from: data)
                let fallback = "Failed to load canonical recipe images (\(httpResponse.statusCode))."
                throw SupabaseSavedRecipesError.requestFailed(errorPayload?.message ?? errorPayload?.error ?? fallback)
            }

            aggregated.append(contentsOf: try JSONDecoder().decode([SupabaseRecipeCardImageRow].self, from: data))
        }

        return aggregated
    }

    private func locallyCachedSavedRecipeIDs(userID: String?) -> [String] {
        let defaults = UserDefaults.standard
        let primaryKey = "\(keyPrefix)-\(userID ?? "guest")"
        let data = defaults.data(forKey: primaryKey)
            ?? (userID == nil ? defaults.data(forKey: legacyKey) : nil)

        guard let data,
              let decoded = try? JSONDecoder().decode([DiscoverRecipeCardData].self, from: data)
        else {
            return []
        }

        return decoded.map(\.id)
    }
}

enum SupabasePrepRecipeOverridesError: LocalizedError {
    case invalidRequest
    case invalidResponse
    case requestFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidRequest:
            return "Could not build the prep override request."
        case .invalidResponse:
            return "Unexpected prep override response."
        case .requestFailed(let message):
            return message
        }
    }
}

struct SupabasePrepRecipeOverrideRow: Decodable, Identifiable, Hashable {
    let userID: String
    let recipeID: String
    let recipe: Recipe
    let servings: Int
    let isIncludedInPrep: Bool

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case recipeID = "recipe_id"
        case recipe
        case servings
        case isIncludedInPrep = "is_included_in_prep"
    }

    var id: String {
        recipeID
    }

    var override: PrepRecipeOverride {
        var normalizedRecipe = recipe
        normalizedRecipe.id = recipeID
        return PrepRecipeOverride(
            recipe: normalizedRecipe,
            servings: servings,
            isIncludedInPrep: isIncludedInPrep
        )
    }
}

struct SupabasePrepRecipeOverrideUpsertPayload: Encodable {
    let userID: String
    let recipeID: String
    let recipe: Recipe
    let servings: Int
    let isIncludedInPrep: Bool

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case recipeID = "recipe_id"
        case recipe
        case servings
        case isIncludedInPrep = "is_included_in_prep"
    }
}

final class SupabasePrepRecipeOverridesService {
    static let shared = SupabasePrepRecipeOverridesService()

    private init() {}

    func fetchPrepRecipeOverrides(userID: String, accessToken: String?) async throws -> [PrepRecipeOverride] {
        guard let encodedUserID = userID.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(
                string: "\(SupabaseConfig.url)/rest/v1/prep_recipe_overrides?select=user_id,recipe_id,recipe,servings,is_included_in_prep&user_id=eq.\(encodedUserID)&order=updated_at.desc"
              ) else {
            throw SupabasePrepRecipeOverridesError.invalidRequest
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(SupabaseConfig.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(accessToken ?? SupabaseConfig.anonKey)", forHTTPHeaderField: "Authorization")

        let (data, httpResponse) = try await perform(request)
        guard (200...299).contains(httpResponse.statusCode) else {
            let errorPayload = try? JSONDecoder().decode(SupabaseRestErrorResponse.self, from: data)
            let fallback = "Failed to read prep overrides (\(httpResponse.statusCode))."
            throw SupabasePrepRecipeOverridesError.requestFailed(errorPayload?.message ?? errorPayload?.error ?? fallback)
        }

        return try JSONDecoder().decode([SupabasePrepRecipeOverrideRow].self, from: data).map(\.override)
    }

    func upsertPrepRecipeOverride(userID: String, override: PrepRecipeOverride, accessToken: String?) async throws {
        guard let url = URL(string: "\(SupabaseConfig.url)/rest/v1/prep_recipe_overrides?on_conflict=user_id,recipe_id") else {
            throw SupabasePrepRecipeOverridesError.invalidRequest
        }

        let payload = SupabasePrepRecipeOverrideUpsertPayload(
            userID: userID,
            recipeID: override.recipe.id,
            recipe: override.recipe,
            servings: max(1, override.servings),
            isIncludedInPrep: override.isIncludedInPrep
        )

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(SupabaseConfig.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(accessToken ?? SupabaseConfig.anonKey)", forHTTPHeaderField: "Authorization")
        request.setValue("resolution=merge-duplicates,return=minimal", forHTTPHeaderField: "Prefer")
        request.httpBody = try JSONEncoder().encode([payload])

        let (data, httpResponse) = try await perform(request)
        guard (200...299).contains(httpResponse.statusCode) else {
            let errorPayload = try? JSONDecoder().decode(SupabaseRestErrorResponse.self, from: data)
            let fallback = "Failed to save prep override (\(httpResponse.statusCode))."
            throw SupabasePrepRecipeOverridesError.requestFailed(errorPayload?.message ?? errorPayload?.error ?? fallback)
        }
    }

    func deleteAllPrepRecipeOverrides(userID: String, accessToken: String?) async throws {
        guard let encodedUserID = userID.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(
                string: "\(SupabaseConfig.url)/rest/v1/prep_recipe_overrides?user_id=eq.\(encodedUserID)"
              ) else {
            throw SupabasePrepRecipeOverridesError.invalidRequest
        }

        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue(SupabaseConfig.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(accessToken ?? SupabaseConfig.anonKey)", forHTTPHeaderField: "Authorization")

        let (data, httpResponse) = try await perform(request)
        guard (200...299).contains(httpResponse.statusCode) else {
            let errorPayload = try? JSONDecoder().decode(SupabaseRestErrorResponse.self, from: data)
            let fallback = "Failed to clear prep overrides (\(httpResponse.statusCode))."
            throw SupabasePrepRecipeOverridesError.requestFailed(errorPayload?.message ?? errorPayload?.error ?? fallback)
        }
    }

    private func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        var request = request
        if request.timeoutInterval <= 0 {
            request.timeoutInterval = 8
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SupabasePrepRecipeOverridesError.invalidResponse
        }
        return (data, httpResponse)
    }
}

enum SupabaseMealPrepCyclesError: LocalizedError {
    case invalidRequest
    case invalidResponse
    case requestFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidRequest:
            return "Could not build the prep cycle request."
        case .invalidResponse:
            return "Unexpected prep cycle response."
        case .requestFailed(let message):
            return message
        }
    }
}

struct SupabaseMealPrepCycleUpsertPayload: Codable {
    let userID: String
    let planID: UUID
    let plan: MealPlan
    let generatedAt: String
    let periodStart: String
    let periodEnd: String
    let cadence: String

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case planID = "plan_id"
        case plan
        case generatedAt = "generated_at"
        case periodStart = "period_start"
        case periodEnd = "period_end"
        case cadence
    }
}

struct SupabaseMealPrepCycleRow: Decodable {
    let plan: MealPlan
}

struct SupabaseMainShopItemUpsertPayload: Codable {
    let userID: String
    let planID: UUID
    let canonicalKey: String
    let name: String
    let quantityText: String
    let supportingText: String?
    let imageURL: String?
    let estimatedPriceText: String?
    let estimatedPriceValue: Double
    let sectionKind: Int?
    let removalKey: String?
    let sourceIngredients: [GroceryItemSource]
    let sourceEdgeIDs: [String]
    let reconciliationMeta: [String: String]?

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case planID = "plan_id"
        case canonicalKey = "canonical_key"
        case name
        case quantityText = "quantity_text"
        case supportingText = "supporting_text"
        case imageURL = "image_url"
        case estimatedPriceText = "estimated_price_text"
        case estimatedPriceValue = "estimated_price_value"
        case sectionKind = "section_kind"
        case removalKey = "removal_key"
        case sourceIngredients = "source_ingredients"
        case sourceEdgeIDs = "source_edge_ids"
        case reconciliationMeta = "reconciliation_meta"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(userID, forKey: .userID)
        try container.encode(planID, forKey: .planID)
        try container.encode(canonicalKey, forKey: .canonicalKey)
        try container.encode(name, forKey: .name)
        try container.encode(quantityText, forKey: .quantityText)
        if let supportingText {
            try container.encode(supportingText, forKey: .supportingText)
        } else {
            try container.encodeNil(forKey: .supportingText)
        }
        if let imageURL {
            try container.encode(imageURL, forKey: .imageURL)
        } else {
            try container.encodeNil(forKey: .imageURL)
        }
        if let estimatedPriceText {
            try container.encode(estimatedPriceText, forKey: .estimatedPriceText)
        } else {
            try container.encodeNil(forKey: .estimatedPriceText)
        }
        try container.encode(estimatedPriceValue, forKey: .estimatedPriceValue)
        if let sectionKind {
            try container.encode(sectionKind, forKey: .sectionKind)
        } else {
            try container.encodeNil(forKey: .sectionKind)
        }
        if let removalKey {
            try container.encode(removalKey, forKey: .removalKey)
        } else {
            try container.encodeNil(forKey: .removalKey)
        }
        try container.encode(sourceIngredients, forKey: .sourceIngredients)
        try container.encode(sourceEdgeIDs, forKey: .sourceEdgeIDs)
        if let reconciliationMeta {
            try container.encode(reconciliationMeta, forKey: .reconciliationMeta)
        } else {
            try container.encodeNil(forKey: .reconciliationMeta)
        }
    }
}

struct SupabaseMainShopItemRow: Decodable {
    let id: UUID
    let canonicalKey: String

    enum CodingKeys: String, CodingKey {
        case id
        case canonicalKey = "canonical_key"
    }
}

struct SupabaseBaseCartItemUpsertPayload: Codable {
    let userID: String
    let planID: UUID
    let groceryKey: String
    let name: String
    let amount: Double
    let unit: String
    let estimatedPrice: Double
    let sourceIngredients: [GroceryItemSource]
    let mainShopItemID: UUID

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case planID = "plan_id"
        case groceryKey = "grocery_key"
        case name
        case amount
        case unit
        case estimatedPrice = "estimated_price"
        case sourceIngredients = "source_ingredients"
        case mainShopItemID = "main_shop_item_id"
    }
}

struct SupabaseMealPrepCycleCompletionUpsertPayload: Codable {
    let userID: String
    let planID: UUID
    let plan: MealPlan
    let generatedAt: String
    let periodStart: String
    let periodEnd: String
    let cadence: String
    let completedAt: String

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case planID = "plan_id"
        case plan
        case generatedAt = "generated_at"
        case periodStart = "period_start"
        case periodEnd = "period_end"
        case cadence
        case completedAt = "completed_at"
    }
}

struct SupabaseMealPrepCycleCompletionRow: Decodable {
    let id: UUID
    let userID: String
    let planID: UUID
    let plan: MealPlan
    let completedAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case userID = "user_id"
        case planID = "plan_id"
        case plan
        case completedAt = "completed_at"
    }
}

final class SupabaseMealPrepCycleService {
    static let shared = SupabaseMealPrepCycleService()
    private let timestampFormatter = ISO8601DateFormatter()

    private init() {}

    private func authorizationTokens(accessToken: String?) -> [String] {
        var tokens: [String] = []
        for token in [accessToken, SupabaseConfig.anonKey] {
            let trimmed = token?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !trimmed.isEmpty, !tokens.contains(trimmed) else { continue }
            tokens.append(trimmed)
        }
        return tokens
    }

    func fetchMealPrepCycles(userID: String, accessToken: String?) async throws -> [MealPlan] {
        guard let encodedUserID = userID.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(
                string: "\(SupabaseConfig.url)/rest/v1/meal_prep_cycles?select=plan&user_id=eq.\(encodedUserID)&order=generated_at.desc&limit=12"
              ) else {
            throw SupabaseMealPrepCyclesError.invalidRequest
        }

        var lastError: SupabaseMealPrepCyclesError?
        for token in authorizationTokens(accessToken: accessToken) {
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.setValue(SupabaseConfig.anonKey, forHTTPHeaderField: "apikey")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

            let (data, httpResponse) = try await perform(request)
            guard (200...299).contains(httpResponse.statusCode) else {
                let errorPayload = try? JSONDecoder().decode(SupabaseRestErrorResponse.self, from: data)
                let fallback = "Failed to read prep cycles (\(httpResponse.statusCode))."
                let error = SupabaseMealPrepCyclesError.requestFailed(errorPayload?.message ?? errorPayload?.error ?? fallback)
                lastError = error
                continue
            }

            return try JSONDecoder().decode([SupabaseMealPrepCycleRow].self, from: data)
                .map(\.plan)
                .filter { !$0.recipes.isEmpty }
        }

        throw lastError ?? SupabaseMealPrepCyclesError.requestFailed("Failed to read prep cycles.")
    }

    func upsertMealPrepCycle(
        userID: String,
        plan: MealPlan,
        accessToken: String?,
        syncCart: Bool = false
    ) async throws {
        guard let url = URL(string: "\(SupabaseConfig.url)/rest/v1/meal_prep_cycles?on_conflict=user_id,plan_id") else {
            throw SupabaseMealPrepCyclesError.invalidRequest
        }

        let payload = SupabaseMealPrepCycleUpsertPayload(
            userID: userID,
            planID: plan.id,
            plan: plan,
            generatedAt: timestampFormatter.string(from: plan.generatedAt),
            periodStart: timestampFormatter.string(from: plan.periodStart),
            periodEnd: timestampFormatter.string(from: plan.periodEnd),
            cadence: plan.cadence.rawValue
        )

        let body = try JSONEncoder().encode([payload])
        var lastError: SupabaseMealPrepCyclesError?

        for token in authorizationTokens(accessToken: accessToken) {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(SupabaseConfig.anonKey, forHTTPHeaderField: "apikey")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("resolution=merge-duplicates,return=minimal", forHTTPHeaderField: "Prefer")
            request.httpBody = body

            let (data, httpResponse) = try await perform(request)
            guard (200...299).contains(httpResponse.statusCode) else {
                let errorPayload = try? JSONDecoder().decode(SupabaseRestErrorResponse.self, from: data)
                let fallback = "Failed to save prep cycle (\(httpResponse.statusCode))."
                lastError = SupabaseMealPrepCyclesError.requestFailed(errorPayload?.message ?? errorPayload?.error ?? fallback)
                continue
            }

            if syncCart {
                try await syncMainShopAndBaseCart(userID: userID, plan: plan, accessToken: accessToken)
            }
            return
        }

        throw lastError ?? SupabaseMealPrepCyclesError.requestFailed("Failed to save prep cycle.")
    }

    private func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SupabaseMealPrepCyclesError.invalidResponse
        }
        return (data, httpResponse)
    }

    private func syncMainShopAndBaseCart(userID: String, plan: MealPlan, accessToken: String?) async throws {
        let mainShopPayloads = buildMainShopPayloads(userID: userID, plan: plan)
        guard !mainShopPayloads.isEmpty else { return }

        try await deleteCartRows(userID: userID, planID: plan.id, tableName: "base_cart_items", accessToken: accessToken)
        try await deleteCartRows(userID: userID, planID: plan.id, tableName: "main_shop_items", accessToken: accessToken)

        let insertedMainShopRows = try await insertMainShopRows(mainShopPayloads, accessToken: accessToken)
        guard !insertedMainShopRows.isEmpty else { return }

        let mainShopLookup = Dictionary(uniqueKeysWithValues: insertedMainShopRows.map { ($0.canonicalKey, $0.id) })
        let baseCartPayloads = buildBaseCartPayloads(
            userID: userID,
            plan: plan,
            mainShopLookup: mainShopLookup,
            snapshotItems: plan.mainShopSnapshot?.items ?? []
        )
        guard !baseCartPayloads.isEmpty else { return }
        try validateBaseCartCoverage(plan: plan, payloads: baseCartPayloads)
        try await insertBaseCartRows(baseCartPayloads, accessToken: accessToken)
    }

    private func buildMainShopPayloads(userID: String, plan: MealPlan) -> [SupabaseMainShopItemUpsertPayload] {
        var payloadsByKey: [String: SupabaseMainShopItemUpsertPayload] = [:]
        let snapshotItems = plan.mainShopSnapshot?.items ?? []

        for item in snapshotItems {
            let canonicalKey = item.canonicalKey ?? normalizedCartKey(item.name)
            guard !canonicalKey.isEmpty else { continue }
            if payloadsByKey[canonicalKey] != nil { continue }

            payloadsByKey[canonicalKey] = SupabaseMainShopItemUpsertPayload(
                userID: userID,
                planID: plan.id,
                canonicalKey: canonicalKey,
                name: item.name,
                quantityText: item.quantityText,
                supportingText: item.supportingText,
                imageURL: item.imageURLString,
                estimatedPriceText: item.estimatedPriceText,
                estimatedPriceValue: item.estimatedPriceValue,
                sectionKind: item.sectionKindRawValue,
                removalKey: item.removalKey,
                sourceIngredients: item.sourceIngredients ?? [],
                sourceEdgeIDs: item.sourceEdgeIDs ?? (item.sourceIngredients ?? []).map(mainShopSourceKey),
                reconciliationMeta: [
                    "coverageState": item.coverageState ?? "unknown",
                    "alternativeNames": (item.alternativeNames ?? []).joined(separator: "|")
                ]
            )
        }

        for groceryItem in plan.groceryItems {
            let canonicalKey = normalizedCartKey(groceryItem.name)
            guard !canonicalKey.isEmpty else { continue }
            if payloadsByKey[canonicalKey] != nil { continue }

            payloadsByKey[canonicalKey] = SupabaseMainShopItemUpsertPayload(
                userID: userID,
                planID: plan.id,
                canonicalKey: canonicalKey,
                name: groceryItem.name,
                quantityText: CartQuantityFormatter.format(amount: groceryItem.amount, unit: groceryItem.unit),
                supportingText: mainShopFallbackSupportingText(for: groceryItem),
                imageURL: nil,
                estimatedPriceText: nil,
                estimatedPriceValue: groceryItem.estimatedPrice,
                sectionKind: nil,
                removalKey: canonicalKey,
                sourceIngredients: groceryItem.sourceIngredients,
                sourceEdgeIDs: groceryItem.sourceIngredients.map(mainShopSourceKey),
                reconciliationMeta: ["coverageState": groceryItem.sourceIngredients.isEmpty ? "fallback" : "covered"]
            )
        }

        return payloadsByKey.values.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private func buildBaseCartPayloads(
        userID: String,
        plan: MealPlan,
        mainShopLookup: [String: UUID],
        snapshotItems: [MainShopSnapshotItem]
    ) -> [SupabaseBaseCartItemUpsertPayload] {
        var payloads: [SupabaseBaseCartItemUpsertPayload] = []
        var seenKeys = Set<String>()

        for snapshotItem in snapshotItems {
            let canonicalMainShopKey = snapshotItem.canonicalKey ?? normalizedCartKey(snapshotItem.name)
            guard !canonicalMainShopKey.isEmpty,
                  let mainShopItemID = mainShopLookup[canonicalMainShopKey]
            else { continue }

            let sources = snapshotItem.sourceIngredients ?? []
            let parsedQuantity = CartQuantityFormatter.mainShopDisplayComponents(from: snapshotItem.quantityText)
            let amount = Double(max(1, parsedQuantity?.roundedCount ?? 1))
            let unit = parsedQuantity?.unitLabel ?? "item"
            let groceryKeyValue = ([
                canonicalMainShopKey,
                normalizedCartKey(snapshotItem.name),
                unit.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            ] + sources
                .map(mainShopSourceKey)
                .filter { !$0.isEmpty }
                .sorted())
                .joined(separator: "::")

            guard seenKeys.insert(groceryKeyValue).inserted else { continue }

            payloads.append(
                SupabaseBaseCartItemUpsertPayload(
                    userID: userID,
                    planID: plan.id,
                    groceryKey: groceryKeyValue,
                    name: snapshotItem.name,
                    amount: amount,
                    unit: unit,
                    estimatedPrice: snapshotItem.estimatedPriceValue,
                    sourceIngredients: sources,
                    mainShopItemID: mainShopItemID
                )
            )
        }

        if payloads.isEmpty {
            for item in plan.groceryItems {
                let canonicalMainShopKey = resolveMainShopCanonicalKey(
                    for: item,
                    snapshotItems: snapshotItems
                ) ?? normalizedCartKey(item.name)
                guard !canonicalMainShopKey.isEmpty,
                      let mainShopItemID = mainShopLookup[canonicalMainShopKey]
                else { continue }

                let groceryKeyValue = ([
                    canonicalMainShopKey,
                    normalizedCartKey(item.name),
                    item.unit.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                ] + baseCartSourceSignatureComponents(for: item))
                    .joined(separator: "::")
                guard seenKeys.insert(groceryKeyValue).inserted else { continue }

                payloads.append(
                    SupabaseBaseCartItemUpsertPayload(
                        userID: userID,
                        planID: plan.id,
                        groceryKey: groceryKeyValue,
                        name: item.name,
                        amount: item.amount,
                        unit: item.unit,
                        estimatedPrice: item.estimatedPrice,
                        sourceIngredients: item.sourceIngredients,
                        mainShopItemID: mainShopItemID
                    )
                )
            }
        }

        return payloads
    }

    private func mainShopFallbackSupportingText(for item: GroceryItem) -> String {
        let recipeCount = Set(item.sourceIngredients.map(\.recipeID)).filter { !$0.isEmpty }.count
        switch recipeCount {
        case 0:
            return "Direct from recipe ingredients"
        case 1:
            return "Used in 1 recipe"
        default:
            return "Used in \(recipeCount) recipes"
        }
    }

    private func validateBaseCartCoverage(plan: MealPlan, payloads: [SupabaseBaseCartItemUpsertPayload]) throws {
        let expectedSourceKeys = Set(
            plan.groceryItems
                .flatMap(\.sourceIngredients)
                .map(baseCartSourceCoverageKey)
                .filter { !$0.isEmpty }
        )
        guard !expectedSourceKeys.isEmpty else { return }

        let persistedSourceKeys = Set(
            payloads
                .flatMap(\.sourceIngredients)
                .map(baseCartSourceCoverageKey)
                .filter { !$0.isEmpty }
        )
        let missingSourceKeys = expectedSourceKeys.subtracting(persistedSourceKeys)
        guard missingSourceKeys.isEmpty else {
            throw SupabaseMealPrepCyclesError.requestFailed(
                "Base cart sync dropped ingredient sources: \(missingSourceKeys.sorted().prefix(12).joined(separator: ", "))"
            )
        }
    }

    private func baseCartSourceCoverageKey(_ source: GroceryItemSource) -> String {
        let recipeID = source.recipeID.trimmingCharacters(in: .whitespacesAndNewlines)
        let ingredientName = normalizedCartKey(source.ingredientName)
        let unit = source.unit.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !recipeID.isEmpty, !ingredientName.isEmpty else { return "" }
        return "\(recipeID.lowercased())::\(ingredientName)::\(unit)"
    }

    private func baseCartSourceSignatureComponents(for item: GroceryItem) -> [String] {
        let sourceComponents = item.sourceIngredients
            .map {
                [
                    normalizedCartKey($0.recipeID),
                    normalizedCartKey($0.ingredientName),
                    normalizedCartKey($0.unit)
                ]
                .joined(separator: "|")
            }
            .filter { !$0.isEmpty }
            .sorted()

        if !sourceComponents.isEmpty {
            return sourceComponents
        }

        return [normalizedCartKey(item.name)]
    }

    private func resolveMainShopCanonicalKey(
        for groceryItem: GroceryItem,
        snapshotItems: [MainShopSnapshotItem]
    ) -> String? {
        let fallbackKey = normalizedCartKey(groceryItem.name)
        guard !snapshotItems.isEmpty else {
            return fallbackKey.isEmpty ? nil : fallbackKey
        }

        let grocerySourceKeys = Set(groceryItem.sourceIngredients.map(mainShopSourceKey))
        var bestMatch: (canonicalKey: String, score: Int)?

        for snapshotItem in snapshotItems {
            let canonicalKey = snapshotItem.canonicalKey ?? normalizedCartKey(snapshotItem.name)
            guard !canonicalKey.isEmpty else { continue }

            let snapshotSourceKeys = Set((snapshotItem.sourceIngredients ?? []).map(mainShopSourceKey))
            let hasSourceOverlap = !grocerySourceKeys.isEmpty && !snapshotSourceKeys.isDisjoint(with: grocerySourceKeys)
            let matchesFallbackKey = canonicalKey == fallbackKey
            let lexicalScore = mainShopNameMatchScore(lhs: groceryItem.name, rhs: snapshotItem.name)

            guard hasSourceOverlap || matchesFallbackKey || lexicalScore >= 70 else { continue }

            let score = (hasSourceOverlap ? 1000 : 0) + (matchesFallbackKey ? 200 : 0) + lexicalScore
            if let existing = bestMatch, existing.score >= score {
                continue
            }
            bestMatch = (canonicalKey, score)
        }

        return bestMatch?.canonicalKey ?? (fallbackKey.isEmpty ? nil : fallbackKey)
    }

    private func mainShopSourceKey(_ source: GroceryItemSource) -> String {
        let recipeID = normalizedCartKey(source.recipeID)
        let ingredientName = normalizedCartKey(source.ingredientName)
        let unit = source.unit.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !recipeID.isEmpty, !ingredientName.isEmpty else { return "" }
        return "\(recipeID)::\(ingredientName)::\(unit)"
    }

    private func mainShopNameMatchScore(lhs: String, rhs: String) -> Int {
        let left = normalizedCartKey(lhs)
        let right = normalizedCartKey(rhs)
        guard !left.isEmpty, !right.isEmpty else { return 0 }
        if left == right { return 100 }
        if left.contains(right) || right.contains(left) { return 80 }

        let leftTokens = Set(left.split(separator: " ").map(String.init))
        let rightTokens = Set(right.split(separator: " ").map(String.init))
        let overlapCount = leftTokens.intersection(rightTokens).count
        guard overlapCount > 0 else { return 0 }
        return overlapCount * 24
    }

    private func insertMainShopRows(_ payloads: [SupabaseMainShopItemUpsertPayload], accessToken: String?) async throws -> [SupabaseMainShopItemRow] {
        guard let url = URL(string: "\(SupabaseConfig.url)/rest/v1/main_shop_items") else {
            throw SupabaseMealPrepCyclesError.invalidRequest
        }

        let body = try JSONEncoder().encode(payloads)
        var lastError: SupabaseMealPrepCyclesError?

        for token in authorizationTokens(accessToken: accessToken) {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(SupabaseConfig.anonKey, forHTTPHeaderField: "apikey")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("return=representation", forHTTPHeaderField: "Prefer")
            request.httpBody = body

            let (data, httpResponse) = try await perform(request)
            guard (200...299).contains(httpResponse.statusCode) else {
                let errorPayload = try? JSONDecoder().decode(SupabaseRestErrorResponse.self, from: data)
                let fallback = "Failed to write main shop items (\(httpResponse.statusCode))."
                lastError = SupabaseMealPrepCyclesError.requestFailed(errorPayload?.message ?? errorPayload?.error ?? fallback)
                continue
            }

            return try JSONDecoder().decode([SupabaseMainShopItemRow].self, from: data)
        }

        throw lastError ?? SupabaseMealPrepCyclesError.requestFailed("Failed to write main shop items.")
    }

    private func insertBaseCartRows(_ payloads: [SupabaseBaseCartItemUpsertPayload], accessToken: String?) async throws {
        guard let url = URL(string: "\(SupabaseConfig.url)/rest/v1/base_cart_items") else {
            throw SupabaseMealPrepCyclesError.invalidRequest
        }

        let body = try JSONEncoder().encode(payloads)
        var lastError: SupabaseMealPrepCyclesError?

        for token in authorizationTokens(accessToken: accessToken) {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(SupabaseConfig.anonKey, forHTTPHeaderField: "apikey")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("return=minimal", forHTTPHeaderField: "Prefer")
            request.httpBody = body

            let (data, httpResponse) = try await perform(request)
            guard (200...299).contains(httpResponse.statusCode) else {
                let errorPayload = try? JSONDecoder().decode(SupabaseRestErrorResponse.self, from: data)
                let fallback = "Failed to write base cart items (\(httpResponse.statusCode))."
                lastError = SupabaseMealPrepCyclesError.requestFailed(errorPayload?.message ?? errorPayload?.error ?? fallback)
                continue
            }

            return
        }

        throw lastError ?? SupabaseMealPrepCyclesError.requestFailed("Failed to write base cart items.")
    }

    private func deleteCartRows(userID: String, planID: UUID, tableName: String, accessToken: String?) async throws {
        guard let encodedUserID = userID.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "\(SupabaseConfig.url)/rest/v1/\(tableName)?user_id=eq.\(encodedUserID)&plan_id=eq.\(planID.uuidString)")
        else {
            throw SupabaseMealPrepCyclesError.invalidRequest
        }

        var lastError: SupabaseMealPrepCyclesError?
        for token in authorizationTokens(accessToken: accessToken) {
            var request = URLRequest(url: url)
            request.httpMethod = "DELETE"
            request.setValue(SupabaseConfig.anonKey, forHTTPHeaderField: "apikey")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

            let (data, httpResponse) = try await perform(request)
            guard (200...299).contains(httpResponse.statusCode) else {
                let errorPayload = try? JSONDecoder().decode(SupabaseRestErrorResponse.self, from: data)
                let fallback = "Failed to clear \(tableName) rows (\(httpResponse.statusCode))."
                lastError = SupabaseMealPrepCyclesError.requestFailed(errorPayload?.message ?? errorPayload?.error ?? fallback)
                continue
            }

            return
        }

        throw lastError ?? SupabaseMealPrepCyclesError.requestFailed("Failed to clear \(tableName) rows.")
    }

    func deleteMainShopItem(userID: String, planID: UUID, removalKey: String, accessToken: String?) async throws {
        let normalizedUserID = userID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedRemovalKey = removalKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedUserID.isEmpty, !normalizedRemovalKey.isEmpty else { return }

        guard let url = URL(string: "\(SupabaseConfig.url)/rest/v1/main_shop_items")
        else {
            throw SupabaseMealPrepCyclesError.invalidRequest
        }

        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "user_id", value: "eq.\(normalizedUserID)"),
            URLQueryItem(name: "plan_id", value: "eq.\(planID.uuidString)"),
            URLQueryItem(
                name: "or",
                value: "(removal_key.eq.\(normalizedRemovalKey),canonical_key.eq.\(normalizedRemovalKey))"
            )
        ]

        guard let deleteURL = components?.url else {
            throw SupabaseMealPrepCyclesError.invalidRequest
        }

        var lastError: SupabaseMealPrepCyclesError?
        for token in authorizationTokens(accessToken: accessToken) {
            var request = URLRequest(url: deleteURL)
            request.httpMethod = "DELETE"
            request.setValue(SupabaseConfig.anonKey, forHTTPHeaderField: "apikey")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

            let (data, httpResponse) = try await perform(request)
            guard (200...299).contains(httpResponse.statusCode) else {
                let errorPayload = try? JSONDecoder().decode(SupabaseRestErrorResponse.self, from: data)
                let fallback = "Failed to delete main shop item (\(httpResponse.statusCode))."
                lastError = SupabaseMealPrepCyclesError.requestFailed(errorPayload?.message ?? errorPayload?.error ?? fallback)
                continue
            }

            return
        }

        throw lastError ?? SupabaseMealPrepCyclesError.requestFailed("Failed to delete main shop item.")
    }

    private func normalizedCartKey(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }
}

enum SupabaseMealPrepCycleCompletionsError: LocalizedError {
    case invalidRequest
    case invalidResponse
    case requestFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidRequest:
            return "Could not build the completed cycle request."
        case .invalidResponse:
            return "Unexpected completed cycle response."
        case .requestFailed(let message):
            return message
        }
    }
}

final class SupabaseMealPrepCycleCompletionService {
    static let shared = SupabaseMealPrepCycleCompletionService()
    private let timestampFormatter = ISO8601DateFormatter()

    private init() {}

    func fetchCompletedMealPrepCycles(userID: String, accessToken: String?) async throws -> [MealPrepCompletedCycle] {
        guard let encodedUserID = userID.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(
                string: "\(SupabaseConfig.url)/rest/v1/meal_prep_cycle_completions?select=id,user_id,plan_id,plan,completed_at&user_id=eq.\(encodedUserID)&order=completed_at.desc&limit=12"
              ) else {
            throw SupabaseMealPrepCycleCompletionsError.invalidRequest
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(SupabaseConfig.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(accessToken ?? SupabaseConfig.anonKey)", forHTTPHeaderField: "Authorization")

        let (data, httpResponse) = try await perform(request)
        guard (200...299).contains(httpResponse.statusCode) else {
            let errorPayload = try? JSONDecoder().decode(SupabaseRestErrorResponse.self, from: data)
            let fallback = "Failed to read completed prep cycles (\(httpResponse.statusCode))."
            throw SupabaseMealPrepCycleCompletionsError.requestFailed(errorPayload?.message ?? errorPayload?.error ?? fallback)
        }

        let rows = try JSONDecoder().decode([SupabaseMealPrepCycleCompletionRow].self, from: data)
        return rows.map {
            MealPrepCompletedCycle(
                id: $0.id,
                userID: $0.userID,
                planID: $0.planID,
                plan: $0.plan,
                completedAt: $0.completedAt
            )
        }
    }

    func upsertMealPrepCycleCompletion(userID: String, cycle: MealPrepCompletedCycle, accessToken: String?) async throws {
        guard let url = URL(string: "\(SupabaseConfig.url)/rest/v1/meal_prep_cycle_completions?on_conflict=user_id,plan_id") else {
            throw SupabaseMealPrepCycleCompletionsError.invalidRequest
        }

        let payload = SupabaseMealPrepCycleCompletionUpsertPayload(
            userID: userID,
            planID: cycle.planID,
            plan: cycle.plan,
            generatedAt: timestampFormatter.string(from: cycle.plan.generatedAt),
            periodStart: timestampFormatter.string(from: cycle.plan.periodStart),
            periodEnd: timestampFormatter.string(from: cycle.plan.periodEnd),
            cadence: cycle.plan.cadence.rawValue,
            completedAt: cycle.completedAt
        )

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(SupabaseConfig.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(accessToken ?? SupabaseConfig.anonKey)", forHTTPHeaderField: "Authorization")
        request.setValue("resolution=merge-duplicates,return=minimal", forHTTPHeaderField: "Prefer")
        request.httpBody = try JSONEncoder().encode([payload])

        let (data, httpResponse) = try await perform(request)
        guard (200...299).contains(httpResponse.statusCode) else {
            let errorPayload = try? JSONDecoder().decode(SupabaseRestErrorResponse.self, from: data)
            let fallback = "Failed to save completed prep cycle (\(httpResponse.statusCode))."
            throw SupabaseMealPrepCycleCompletionsError.requestFailed(errorPayload?.message ?? errorPayload?.error ?? fallback)
        }
    }

    private func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SupabaseMealPrepCycleCompletionsError.invalidResponse
        }
        return (data, httpResponse)
    }
}

enum SupabaseRecurringPrepRecipesError: LocalizedError {
    case invalidRequest
    case invalidResponse
    case requestFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidRequest:
            return "Could not build the recurring prep request."
        case .invalidResponse:
            return "Unexpected recurring prep response."
        case .requestFailed(let message):
            return message
        }
    }
}

struct SupabaseRecurringPrepRecipeRow: Decodable {
    let userID: String
    let recipeID: String
    let recipe: Recipe
    let isEnabled: Bool
    let createdAt: String?
    let updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case recipeID = "recipe_id"
        case recipe
        case isEnabled = "is_enabled"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    var recurringRecipe: RecurringPrepRecipe {
        RecurringPrepRecipe(
            userID: userID,
            recipeID: recipeID,
            recipe: recipe,
            isEnabled: isEnabled,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
}

struct SupabaseRecurringPrepRecipeUpsertPayload: Encodable {
    let userID: String
    let recipeID: String
    let recipe: Recipe
    let recipeTitle: String
    let isEnabled: Bool

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case recipeID = "recipe_id"
        case recipe
        case recipeTitle = "recipe_title"
        case isEnabled = "is_enabled"
    }
}

final class SupabaseRecurringPrepRecipesService {
    static let shared = SupabaseRecurringPrepRecipesService()

    private init() {}

    func fetchRecurringPrepRecipes(userID: String, accessToken: String?) async throws -> [RecurringPrepRecipe] {
        do {
            return try await fetchRecurringPrepRecipesViaBackend(userID: userID, accessToken: accessToken, directError: nil)
        } catch {
            guard hasUsableAccessToken(accessToken) else { throw error }
            return try await fetchRecurringPrepRecipesDirect(userID: userID, accessToken: accessToken)
        }
    }

    private func fetchRecurringPrepRecipesDirect(userID: String, accessToken: String?) async throws -> [RecurringPrepRecipe] {
        var components = URLComponents(string: "\(SupabaseConfig.url)/rest/v1/prep_recurring_recipes")
        components?.queryItems = [
            URLQueryItem(name: "select", value: "user_id,recipe_id,recipe,recipe_title,is_enabled,created_at,updated_at"),
            URLQueryItem(name: "user_id", value: "eq.\(userID)"),
            URLQueryItem(name: "order", value: "updated_at.desc")
        ]
        guard let url = components?.url else {
            throw SupabaseRecurringPrepRecipesError.invalidRequest
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(SupabaseConfig.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(accessToken ?? SupabaseConfig.anonKey)", forHTTPHeaderField: "Authorization")

        let (data, httpResponse) = try await perform(request)
        guard (200...299).contains(httpResponse.statusCode) else {
            let errorPayload = try? JSONDecoder().decode(SupabaseRestErrorResponse.self, from: data)
            let fallback = "Failed to read recurring prep recipes (\(httpResponse.statusCode))."
            throw SupabaseRecurringPrepRecipesError.requestFailed(errorPayload?.message ?? errorPayload?.error ?? fallback)
        }

        return try JSONDecoder().decode([SupabaseRecurringPrepRecipeRow].self, from: data)
            .map(\.recurringRecipe)
    }

    func upsertRecurringPrepRecipe(_ recipe: RecurringPrepRecipe, accessToken: String?) async throws {
        do {
            try await upsertRecurringPrepRecipeViaBackend(recipe, accessToken: accessToken, directError: nil)
            return
        } catch {
            guard hasUsableAccessToken(accessToken) else { throw error }
            try await upsertRecurringPrepRecipeDirect(recipe, accessToken: accessToken)
        }
    }

    private func upsertRecurringPrepRecipeDirect(_ recipe: RecurringPrepRecipe, accessToken: String?) async throws {
        guard let url = URL(string: "\(SupabaseConfig.url)/rest/v1/prep_recurring_recipes?on_conflict=user_id,recipe_id") else {
            throw SupabaseRecurringPrepRecipesError.invalidRequest
        }

        let payload = SupabaseRecurringPrepRecipeUpsertPayload(
            userID: recipe.userID,
            recipeID: recipe.recipeID,
            recipe: recipe.recipe,
            recipeTitle: recipe.recipe.title,
            isEnabled: recipe.isEnabled
        )

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(SupabaseConfig.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(accessToken ?? SupabaseConfig.anonKey)", forHTTPHeaderField: "Authorization")
        request.setValue("resolution=merge-duplicates", forHTTPHeaderField: "Prefer")
        request.httpBody = try JSONEncoder().encode([payload])

        let (data, httpResponse) = try await perform(request)
        guard (200...299).contains(httpResponse.statusCode) else {
            let errorPayload = try? JSONDecoder().decode(SupabaseRestErrorResponse.self, from: data)
            let fallback = "Failed to save recurring prep recipe (\(httpResponse.statusCode))."
            throw SupabaseRecurringPrepRecipesError.requestFailed(errorPayload?.message ?? errorPayload?.error ?? fallback)
        }
    }

    func deleteRecurringPrepRecipe(userID: String, recipeID: String, accessToken: String?) async throws {
        do {
            try await deleteRecurringPrepRecipeViaBackend(userID: userID, recipeID: recipeID, accessToken: accessToken, directError: nil)
            return
        } catch {
            guard hasUsableAccessToken(accessToken) else { throw error }
            try await deleteRecurringPrepRecipeDirect(userID: userID, recipeID: recipeID, accessToken: accessToken)
        }
    }

    private func deleteRecurringPrepRecipeDirect(userID: String, recipeID: String, accessToken: String?) async throws {
        var components = URLComponents(string: "\(SupabaseConfig.url)/rest/v1/prep_recurring_recipes")
        components?.queryItems = [
            URLQueryItem(name: "user_id", value: "eq.\(userID)"),
            URLQueryItem(name: "recipe_id", value: "eq.\(recipeID)")
        ]
        guard let url = components?.url else {
            throw SupabaseRecurringPrepRecipesError.invalidRequest
        }

        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue(SupabaseConfig.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(accessToken ?? SupabaseConfig.anonKey)", forHTTPHeaderField: "Authorization")

        let (data, httpResponse) = try await perform(request)
        guard (200...299).contains(httpResponse.statusCode) else {
            let errorPayload = try? JSONDecoder().decode(SupabaseRestErrorResponse.self, from: data)
            let fallback = "Failed to remove recurring prep recipe (\(httpResponse.statusCode))."
            throw SupabaseRecurringPrepRecipesError.requestFailed(errorPayload?.message ?? errorPayload?.error ?? fallback)
        }
    }

    private func fetchRecurringPrepRecipesViaBackend(userID: String, accessToken: String?, directError: Error?) async throws -> [RecurringPrepRecipe] {
        var lastError: Error?

        for baseURL in OunjeDevelopmentServer.workerCandidateBaseURLs {
            do {
                var components = URLComponents(string: "\(baseURL)/v1/recurring")
                components?.queryItems = [URLQueryItem(name: "user_id", value: userID)]
                guard let url = components?.url else {
                    throw SupabaseRecurringPrepRecipesError.invalidRequest
                }

                var request = backendRequest(url: url, userID: userID, accessToken: accessToken)
                request.httpMethod = "GET"

                let (data, httpResponse) = try await perform(request)
                guard (200...299).contains(httpResponse.statusCode) else {
                    throw recurringBackendError(data: data, statusCode: httpResponse.statusCode, fallback: "Failed to read recurring prep recipes.")
                }

                return try JSONDecoder().decode([SupabaseRecurringPrepRecipeRow].self, from: data)
                    .map(\.recurringRecipe)
            } catch {
                lastError = error
            }
        }

        throw lastError ?? directError ?? SupabaseRecurringPrepRecipesError.invalidResponse
    }

    private func upsertRecurringPrepRecipeViaBackend(_ recipe: RecurringPrepRecipe, accessToken: String?, directError: Error?) async throws {
        let payload = SupabaseRecurringPrepRecipeUpsertPayload(
            userID: recipe.userID,
            recipeID: recipe.recipeID,
            recipe: recipe.recipe,
            recipeTitle: recipe.recipe.title,
            isEnabled: recipe.isEnabled
        )
        var lastError: Error?

        for baseURL in OunjeDevelopmentServer.workerCandidateBaseURLs {
            do {
                guard let url = URL(string: "\(baseURL)/v1/recurring") else {
                    throw SupabaseRecurringPrepRecipesError.invalidRequest
                }

                var request = backendRequest(url: url, userID: recipe.userID, accessToken: accessToken)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONEncoder().encode([payload])

                let (data, httpResponse) = try await perform(request)
                guard (200...299).contains(httpResponse.statusCode) else {
                    throw recurringBackendError(data: data, statusCode: httpResponse.statusCode, fallback: "Failed to save recurring prep recipe.")
                }
                return
            } catch {
                lastError = error
            }
        }

        throw lastError ?? directError ?? SupabaseRecurringPrepRecipesError.invalidResponse
    }

    private func deleteRecurringPrepRecipeViaBackend(userID: String, recipeID: String, accessToken: String?, directError: Error?) async throws {
        var lastError: Error?

        for baseURL in OunjeDevelopmentServer.workerCandidateBaseURLs {
            do {
                var components = URLComponents(string: "\(baseURL)/v1/recurring")
                components?.queryItems = [
                    URLQueryItem(name: "user_id", value: userID),
                    URLQueryItem(name: "recipe_id", value: recipeID)
                ]
                guard let url = components?.url else {
                    throw SupabaseRecurringPrepRecipesError.invalidRequest
                }

                var request = backendRequest(url: url, userID: userID, accessToken: accessToken)
                request.httpMethod = "DELETE"

                let (data, httpResponse) = try await perform(request)
                guard (200...299).contains(httpResponse.statusCode) else {
                    throw recurringBackendError(data: data, statusCode: httpResponse.statusCode, fallback: "Failed to remove recurring prep recipe.")
                }
                return
            } catch {
                lastError = error
            }
        }

        throw lastError ?? directError ?? SupabaseRecurringPrepRecipesError.invalidResponse
    }

    private func backendRequest(url: URL, userID: String, accessToken: String?) -> URLRequest {
        var request = URLRequest(url: url)
        request.timeoutInterval = 18
        request.setValue(userID, forHTTPHeaderField: "x-user-id")
        if let token = accessToken?.trimmingCharacters(in: .whitespacesAndNewlines),
           !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func hasUsableAccessToken(_ accessToken: String?) -> Bool {
        accessToken?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    private func recurringBackendError(data: Data, statusCode: Int, fallback: String) -> SupabaseRecurringPrepRecipesError {
        let errorPayload = try? JSONDecoder().decode(SupabaseRestErrorResponse.self, from: data)
        return .requestFailed(errorPayload?.message ?? errorPayload?.error ?? "\(fallback) (\(statusCode)).")
    }

    private func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SupabaseRecurringPrepRecipesError.invalidResponse
        }
        return (data, httpResponse)
    }
}

enum SupabaseMealPrepAutomationStateError: LocalizedError {
    case invalidRequest
    case invalidResponse
    case requestFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidRequest:
            return "Could not build the automation state request."
        case .invalidResponse:
            return "Unexpected automation state response."
        case .requestFailed(let message):
            return message
        }
    }
}

struct SupabaseMealPrepAutomationStateRow: Decodable {
    let userID: String
    let lastEvaluatedAt: String?
    let nextPlanningWindowAt: String?
    let lastGeneratedForDeliveryAt: String?
    let lastGeneratedPlanID: UUID?
    let lastGeneratedReason: String?
    let lastCartSyncForDeliveryAt: String?
    let lastCartSyncPlanID: UUID?
    let lastCartSignature: String?
    let lastInstacartRunID: String?
    let lastInstacartRunStatus: String?

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case lastEvaluatedAt = "last_evaluated_at"
        case nextPlanningWindowAt = "next_planning_window_at"
        case lastGeneratedForDeliveryAt = "last_generated_for_delivery_at"
        case lastGeneratedPlanID = "last_generated_plan_id"
        case lastGeneratedReason = "last_generated_reason"
        case lastCartSyncForDeliveryAt = "last_cart_sync_for_delivery_at"
        case lastCartSyncPlanID = "last_cart_sync_plan_id"
        case lastCartSignature = "last_cart_signature"
        case lastInstacartRunID = "last_instacart_run_id"
        case lastInstacartRunStatus = "last_instacart_run_status"
    }

    var automationState: MealPrepAutomationState {
        MealPrepAutomationState(
            userID: userID,
            lastEvaluatedAt: lastEvaluatedAt,
            nextPlanningWindowAt: nextPlanningWindowAt,
            lastGeneratedForDeliveryAt: lastGeneratedForDeliveryAt,
            lastGeneratedPlanID: lastGeneratedPlanID,
            lastGeneratedReason: lastGeneratedReason,
            lastCartSyncForDeliveryAt: lastCartSyncForDeliveryAt,
            lastCartSyncPlanID: lastCartSyncPlanID,
            lastCartSignature: lastCartSignature,
            lastInstacartRunID: lastInstacartRunID,
            lastInstacartRunStatus: lastInstacartRunStatus
        )
    }
}

struct SupabaseMealPrepAutomationStateUpsertPayload: Encodable {
    let userID: String
    let lastEvaluatedAt: String?
    let nextPlanningWindowAt: String?
    let lastGeneratedForDeliveryAt: String?
    let lastGeneratedPlanID: UUID?
    let lastGeneratedReason: String?
    let lastCartSyncForDeliveryAt: String?
    let lastCartSyncPlanID: UUID?
    let lastCartSignature: String?
    let lastInstacartRunID: String?
    let lastInstacartRunStatus: String?

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case lastEvaluatedAt = "last_evaluated_at"
        case nextPlanningWindowAt = "next_planning_window_at"
        case lastGeneratedForDeliveryAt = "last_generated_for_delivery_at"
        case lastGeneratedPlanID = "last_generated_plan_id"
        case lastGeneratedReason = "last_generated_reason"
        case lastCartSyncForDeliveryAt = "last_cart_sync_for_delivery_at"
        case lastCartSyncPlanID = "last_cart_sync_plan_id"
        case lastCartSignature = "last_cart_signature"
        case lastInstacartRunID = "last_instacart_run_id"
        case lastInstacartRunStatus = "last_instacart_run_status"
    }
}

final class SupabaseMealPrepAutomationStateService {
    static let shared = SupabaseMealPrepAutomationStateService()

    private init() {}

    func fetchAutomationState(userID: String, accessToken: String?) async throws -> MealPrepAutomationState? {
        guard let encodedUserID = userID.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(
                string: "\(SupabaseConfig.url)/rest/v1/meal_prep_automation_state?select=*&user_id=eq.\(encodedUserID)&limit=1"
              ) else {
            throw SupabaseMealPrepAutomationStateError.invalidRequest
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(SupabaseConfig.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(accessToken ?? SupabaseConfig.anonKey)", forHTTPHeaderField: "Authorization")

        let (data, httpResponse) = try await perform(request)
        guard (200...299).contains(httpResponse.statusCode) else {
            let errorPayload = try? JSONDecoder().decode(SupabaseRestErrorResponse.self, from: data)
            let fallback = "Failed to read automation state (\(httpResponse.statusCode))."
            throw SupabaseMealPrepAutomationStateError.requestFailed(errorPayload?.message ?? errorPayload?.error ?? fallback)
        }

        let rows = try JSONDecoder().decode([SupabaseMealPrepAutomationStateRow].self, from: data)
        return rows.first?.automationState
    }

    func upsertAutomationState(_ state: MealPrepAutomationState, accessToken: String?) async throws {
        guard let url = URL(string: "\(SupabaseConfig.url)/rest/v1/meal_prep_automation_state?on_conflict=user_id") else {
            throw SupabaseMealPrepAutomationStateError.invalidRequest
        }

        let payload = SupabaseMealPrepAutomationStateUpsertPayload(
            userID: state.userID,
            lastEvaluatedAt: state.lastEvaluatedAt,
            nextPlanningWindowAt: state.nextPlanningWindowAt,
            lastGeneratedForDeliveryAt: state.lastGeneratedForDeliveryAt,
            lastGeneratedPlanID: state.lastGeneratedPlanID,
            lastGeneratedReason: state.lastGeneratedReason,
            lastCartSyncForDeliveryAt: state.lastCartSyncForDeliveryAt,
            lastCartSyncPlanID: state.lastCartSyncPlanID,
            lastCartSignature: state.lastCartSignature,
            lastInstacartRunID: state.lastInstacartRunID,
            lastInstacartRunStatus: state.lastInstacartRunStatus
        )

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(SupabaseConfig.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(accessToken ?? SupabaseConfig.anonKey)", forHTTPHeaderField: "Authorization")
        request.setValue("resolution=merge-duplicates,return=minimal", forHTTPHeaderField: "Prefer")
        request.httpBody = try JSONEncoder().encode([payload])

        let (data, httpResponse) = try await perform(request)
        guard (200...299).contains(httpResponse.statusCode) else {
            let errorPayload = try? JSONDecoder().decode(SupabaseRestErrorResponse.self, from: data)
            let fallback = "Failed to save automation state (\(httpResponse.statusCode))."
            throw SupabaseMealPrepAutomationStateError.requestFailed(errorPayload?.message ?? errorPayload?.error ?? fallback)
        }
    }

    private func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SupabaseMealPrepAutomationStateError.invalidResponse
        }
        return (data, httpResponse)
    }
}

enum SupabaseRecipeIngredientsError: LocalizedError {
    case invalidRequest
    case invalidResponse
    case requestFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidRequest:
            return "Could not build the ingredient request."
        case .invalidResponse:
            return "Unexpected ingredient response."
        case .requestFailed(let message):
            return message
        }
    }
}

struct SupabaseRecipeIngredientRow: Decodable, Identifiable, Hashable {
    let id: String
    let recipeID: String
    let ingredientID: String?
    let displayName: String
    let quantityText: String
    let imageURLString: String?
    let sortOrder: Int?

    enum CodingKeys: String, CodingKey {
        case id
        case recipeID = "recipe_id"
        case ingredientID = "ingredient_id"
        case displayName = "display_name"
        case quantityText = "quantity_text"
        case imageURLString = "image_url"
        case sortOrder = "sort_order"
    }

    var imageURL: URL? {
        Self.normalizedImageURL(from: imageURLString)
    }

    var displayTitle: String {
        if shouldPromoteQuantityTextToTitle, let promotedTitle = normalizedQuantityText {
            return Self.cleanedIngredientName(from: promotedTitle)
        }
        return Self.cleanedIngredientName(from: displayName)
    }

    var displayQuantityText: String? {
        if shouldPromoteQuantityTextToTitle {
            return nil
        }
        return RecipeQuantityFormatter.normalize(quantityText)
    }

    static func normalizedImageURL(from rawValue: String?) -> URL? {
        guard let rawValue, !rawValue.isEmpty else { return nil }
        let normalized = rawValue
            .replacingOccurrences(of: "https://firebasestorage.googleapis.com:443/", with: "https://firebasestorage.googleapis.com/")
            .replacingOccurrences(of: " ", with: "%20")
        return URL(string: normalized)
    }

    func replacingImageURLString(_ value: String?) -> SupabaseRecipeIngredientRow {
        SupabaseRecipeIngredientRow(
            id: id,
            recipeID: recipeID,
            ingredientID: ingredientID,
            displayName: displayName,
            quantityText: quantityText,
            imageURLString: value,
            sortOrder: sortOrder
        )
    }

    func replacingDisplayName(_ value: String) -> SupabaseRecipeIngredientRow {
        SupabaseRecipeIngredientRow(
            id: id,
            recipeID: recipeID,
            ingredientID: ingredientID,
            displayName: value,
            quantityText: quantityText,
            imageURLString: imageURLString,
            sortOrder: sortOrder
        )
    }

    func replacingQuantityText(_ value: String) -> SupabaseRecipeIngredientRow {
        SupabaseRecipeIngredientRow(
            id: id,
            recipeID: recipeID,
            ingredientID: ingredientID,
            displayName: displayName,
            quantityText: value,
            imageURLString: imageURLString,
            sortOrder: sortOrder
        )
    }

    func normalizedForDisplay() -> SupabaseRecipeIngredientRow {
        guard let promotedDisplayName = normalizedQuantityText,
              shouldPromoteQuantityTextToTitle
        else {
            return self
        }

        return replacingDisplayName(Self.cleanedIngredientName(from: promotedDisplayName))
            .replacingQuantityText("")
    }

    private var normalizedQuantityText: String? {
        quantityText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func cleanedIngredientName(from raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return raw }

        let quantityWords: Set<String> = [
            "a", "an", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten",
            "half", "dozen", "couple", "few",
            "cup", "cups", "tablespoon", "tablespoons", "tbsp", "tbsps", "teaspoon", "teaspoons", "tsp", "tsps",
            "gram", "grams", "g", "kilogram", "kilograms", "kg", "milligram", "milligrams", "mg",
            "ounce", "ounces", "oz", "pound", "pounds", "lb", "lbs",
            "pinch", "pinches", "dash", "dashes",
            "clove", "cloves", "slice", "slices", "strip", "strips", "piece", "pieces",
            "bunch", "bunches", "sprig", "sprigs", "stalk", "stalks",
            "can", "cans", "jar", "jars", "bottle", "bottles", "package", "packages", "packet", "packets",
            "large", "small", "medium", "extra-large", "jumbo"
        ]

        var tokens = trimmed
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)

        while let first = tokens.first {
            let lowered = first.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let numericLike = lowered.rangeOfCharacter(from: CharacterSet.decimalDigits) != nil
                || lowered.rangeOfCharacter(from: CharacterSet(charactersIn: "¼½¾⅐⅑⅒⅓⅔⅕⅖⅗⅘⅙⅚⅛⅜⅝⅞")) != nil
            let fractionalLike = lowered.contains("/") || lowered.contains("-")
            let isQuantityWord = quantityWords.contains(lowered)

            if numericLike || fractionalLike || isQuantityWord {
                tokens.removeFirst()
                continue
            }

            break
        }

        let cleaned = tokens.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? trimmed : cleaned
    }

    private var shouldPromoteQuantityTextToTitle: Bool {
        guard isLikelyAbbreviation(displayName),
              let normalizedQuantityText,
              looksLikeIngredientName(normalizedQuantityText)
        else {
            return false
        }
        return true
    }

    private func isLikelyAbbreviation(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 4, !trimmed.contains(" ") else {
            return false
        }
        return trimmed == trimmed.uppercased()
            || trimmed.count <= 2
    }

    private func looksLikeIngredientName(_ value: String) -> Bool {
        let trimmed = Self.cleanedIngredientName(from: value).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let lowered = trimmed.lowercased()
        let disallowed = [
            "to taste",
            "as needed",
            "for serving",
            "optional",
            "divided"
        ]
        if disallowed.contains(lowered) { return false }

        return trimmed.rangeOfCharacter(from: .letters) != nil
    }
}

struct SupabaseIngredientRecord: Decodable, Hashable {
    let id: String
    let normalizedName: String?
    let displayName: String?
    let defaultImageURLString: String?

    enum CodingKeys: String, CodingKey {
        case id
        case normalizedName = "normalized_name"
        case displayName = "display_name"
        case defaultImageURLString = "default_image_url"
    }

    var imageURL: URL? {
        SupabaseRecipeIngredientRow.normalizedImageURL(from: defaultImageURLString)
    }

    var matchKey: String {
        let normalized = normalizedName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !normalized.isEmpty { return normalized }
        return displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    func replacingDefaultImageURLString(_ value: String?) -> SupabaseIngredientRecord {
        SupabaseIngredientRecord(
            id: id,
            normalizedName: normalizedName,
            displayName: displayName,
            defaultImageURLString: value
        )
    }
}

struct SupabaseRecipeIngredientArtRow: Decodable, Hashable {
    let ingredientID: String
    let displayName: String
    let imageURLString: String?

    enum CodingKeys: String, CodingKey {
        case ingredientID = "ingredient_id"
        case displayName = "display_name"
        case imageURLString = "image_url"
    }

    var imageURL: URL? {
        SupabaseRecipeIngredientRow.normalizedImageURL(from: imageURLString)
    }
}

struct CanonicalIngredientImageIndex {
    let records: [SupabaseIngredientRecord]

    private let recordsByID: [String: SupabaseIngredientRecord]
    private let recordsByName: [String: SupabaseIngredientRecord]

    init(records: [SupabaseIngredientRecord] = []) {
        self.records = records
        recordsByID = records.reduce(into: [:]) { partialResult, record in
            let key = record.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, partialResult[key] == nil else { return }
            partialResult[key] = record
        }
        recordsByName = records.reduce(into: [:]) { partialResult, record in
            let key = SupabaseIngredientsCatalogService.normalizedName(record.matchKey)
            guard !key.isEmpty else { return }
            if let existing = partialResult[key] {
                let existingDisplay = existing.displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let incomingDisplay = record.displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                if existingDisplay.count >= incomingDisplay.count {
                    return
                }
            }
            partialResult[key] = record
        }
    }

    func imageURL(forName name: String) -> URL? {
        guard let record = record(ingredientID: nil, displayName: name) else { return nil }
        return record.imageURL
    }

    func enrich(_ ingredient: RecipeDetailIngredient) -> RecipeDetailIngredient {
        var enriched = ingredient

        if let replacementDisplayName = replacementDisplayName(
            ingredientID: ingredient.ingredientID,
            displayName: ingredient.displayName
        ) {
            enriched = enriched.replacingDisplayName(replacementDisplayName)
        }

        if let existing = enriched.imageURLString?.trimmingCharacters(in: .whitespacesAndNewlines),
           !existing.isEmpty {
            return enriched
        }

        guard let imageURLString = imageURLString(
            ingredientID: enriched.ingredientID,
            displayName: enriched.displayTitle
        ) else {
            return enriched
        }

        return enriched.replacingImageURLString(imageURLString)
    }

    func enrich(_ ingredient: SupabaseRecipeIngredientRow) -> SupabaseRecipeIngredientRow {
        var enriched = ingredient

        if let replacementDisplayName = replacementDisplayName(
            ingredientID: ingredient.ingredientID,
            displayName: ingredient.displayName
        ) {
            enriched = enriched.replacingDisplayName(replacementDisplayName)
        }

        if let existing = enriched.imageURLString?.trimmingCharacters(in: .whitespacesAndNewlines),
           !existing.isEmpty {
            return enriched
        }

        guard let imageURLString = imageURLString(
            ingredientID: enriched.ingredientID,
            displayName: enriched.displayName
        ) else {
            return enriched
        }

        return enriched.replacingImageURLString(imageURLString)
    }

    private func imageURLString(ingredientID: String?, displayName: String) -> String? {
        guard let record = record(ingredientID: ingredientID, displayName: displayName),
              let imageURLString = record.defaultImageURLString,
              !imageURLString.isEmpty
        else {
            return nil
        }

        return imageURLString
    }

    private func record(ingredientID: String?, displayName: String) -> SupabaseIngredientRecord? {
        if let ingredientID,
           let record = recordsByID[ingredientID] {
            return record
        }

        let key = SupabaseIngredientsCatalogService.normalizedName(displayName)
        guard !key.isEmpty else { return nil }
        return recordsByName[key]
    }

    private func replacementDisplayName(ingredientID: String?, displayName: String) -> String? {
        guard let record = record(ingredientID: ingredientID, displayName: displayName),
              let canonicalDisplayName = record.displayName?.trimmingCharacters(in: .whitespacesAndNewlines),
              shouldReplaceDisplayName(displayName, with: canonicalDisplayName)
        else {
            return nil
        }

        return canonicalDisplayName
    }

    private func shouldReplaceDisplayName(_ current: String, with candidate: String) -> Bool {
        let trimmedCurrent = current.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCandidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCandidate.isEmpty else { return false }

        let currentKey = SupabaseIngredientsCatalogService.normalizedName(trimmedCurrent)
        let candidateKey = SupabaseIngredientsCatalogService.normalizedName(trimmedCandidate)
        guard currentKey != candidateKey else { return false }

        return trimmedCurrent.isEmpty || (!trimmedCurrent.contains(" ") && trimmedCurrent.count <= 3)
    }
}

final class SupabaseIngredientsCatalogService {
    static let shared = SupabaseIngredientsCatalogService()

    private init() {}

    func fetchIngredients(ingredientIDs: [String], normalizedNames: [String]) async throws -> [SupabaseIngredientRecord] {
        var merged: [String: SupabaseIngredientRecord] = [:]

        let ids = Array(Set(ingredientIDs.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })).sorted()
        if !ids.isEmpty {
            for record in try await fetch(byColumn: "id", values: ids) {
                merged[record.id] = record
            }
        }

        let names = Array(
            Set(
                normalizedNames
                    .map { Self.normalizedName($0) }
                    .filter { !$0.isEmpty }
            )
        ).sorted()
        if !names.isEmpty {
            for record in try await fetch(byColumn: "normalized_name", values: names) {
                merged[record.id] = record
            }
        }

        let recordsNeedingFallbackArt = merged.values.filter {
            ($0.defaultImageURLString?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "").isEmpty
        }

        if !recordsNeedingFallbackArt.isEmpty {
            let fallbackArtRows = try await SupabaseRecipeIngredientArtService.shared.fetchArtRows(
                ingredientIDs: recordsNeedingFallbackArt.map(\.id),
                displayNames: recordsNeedingFallbackArt.compactMap { $0.displayName ?? $0.normalizedName }
            )
            let fallbackArtByIngredientID: [String: String] = fallbackArtRows.reduce(into: [:]) { partial, row in
                guard let imageURLString = row.imageURL?.absoluteString, !imageURLString.isEmpty else { return }
                partial[row.ingredientID] = imageURLString
            }
            let fallbackArtByName: [String: String] = fallbackArtRows.reduce(into: [:]) { partial, row in
                guard let imageURLString = row.imageURL?.absoluteString, !imageURLString.isEmpty else { return }
                let key = SupabaseIngredientsCatalogService.normalizedName(row.displayName)
                guard !key.isEmpty, partial[key] == nil else { return }
                partial[key] = imageURLString
            }

            for record in recordsNeedingFallbackArt {
                let nameKey = SupabaseIngredientsCatalogService.normalizedName(record.matchKey)
                let fallbackImageURLString = fallbackArtByIngredientID[record.id]
                    ?? (nameKey.isEmpty ? nil : fallbackArtByName[nameKey])
                guard let fallbackImageURLString else { continue }
                merged[record.id] = record.replacingDefaultImageURLString(fallbackImageURLString)
            }
        }

        return Array(merged.values)
    }

    func fetchImageLookup(normalizedNames: [String]) async throws -> [String: String] {
        let records = try await fetchIngredients(ingredientIDs: [], normalizedNames: normalizedNames)
        var lookup: [String: String] = [:]
        for record in records {
            let key = Self.normalizedName(record.matchKey)
            guard !key.isEmpty else { continue }
            guard let imageURLString = record.defaultImageURLString?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !imageURLString.isEmpty,
                  lookup[key] == nil
            else {
                continue
            }
            lookup[key] = imageURLString
        }
        return lookup
    }

    private func fetch(byColumn column: String, values: [String]) async throws -> [SupabaseIngredientRecord] {
        let select = "id,normalized_name,display_name,default_image_url"
        let inClause = Self.encodedInClause(values)
        guard let url = URL(
            string: "\(SupabaseConfig.url)/rest/v1/ingredients?select=\(select)&\(column)=in.\(inClause)"
        ) else {
            throw SupabaseRecipeIngredientsError.invalidRequest
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(SupabaseConfig.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(SupabaseConfig.anonKey)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SupabaseRecipeIngredientsError.invalidResponse
        }

        guard (200 ... 299).contains(httpResponse.statusCode) else {
            let errorPayload = try? JSONDecoder().decode(SupabaseRestErrorResponse.self, from: data)
            let fallback = "Failed to load canonical ingredient art (\(httpResponse.statusCode))."
            throw SupabaseRecipeIngredientsError.requestFailed(errorPayload?.message ?? errorPayload?.error ?? fallback)
        }

        return try JSONDecoder().decode([SupabaseIngredientRecord].self, from: data)
    }

    private func fetchFallbackRecipeArt(ingredientIDs: [String]) async throws -> [String: String] {
        let ids = Array(Set(ingredientIDs.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })).sorted()
        guard !ids.isEmpty else { return [:] }

        let select = "ingredient_id,display_name,image_url"
        let inClause = Self.encodedInClause(ids)
        guard let url = URL(
            string: "\(SupabaseConfig.url)/rest/v1/recipe_ingredients?select=\(select)&ingredient_id=in.\(inClause)&image_url=not.is.null&order=ingredient_id.asc&limit=5000"
        ) else {
            throw SupabaseRecipeIngredientsError.invalidRequest
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(SupabaseConfig.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(SupabaseConfig.anonKey)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SupabaseRecipeIngredientsError.invalidResponse
        }

        guard (200 ... 299).contains(httpResponse.statusCode) else {
            let errorPayload = try? JSONDecoder().decode(SupabaseRestErrorResponse.self, from: data)
            let fallback = "Failed to load fallback ingredient art (\(httpResponse.statusCode))."
            throw SupabaseRecipeIngredientsError.requestFailed(errorPayload?.message ?? errorPayload?.error ?? fallback)
        }

        let rows = try JSONDecoder().decode([SupabaseRecipeIngredientArtRow].self, from: data)
        var lookup: [String: String] = [:]

        for row in rows {
            guard let imageURLString = row.imageURLString?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !imageURLString.isEmpty,
                  lookup[row.ingredientID] == nil
            else {
                continue
            }
            lookup[row.ingredientID] = imageURLString
        }

        return lookup
    }

    private static func encodedInClause(_ values: [String]) -> String {
        let quoted = values
            .map { value in
                "\"\(value.replacingOccurrences(of: "\"", with: "\\\""))\""
            }
            .joined(separator: ",")
        let clause = "(\(quoted))"
        return clause.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? clause
    }

    static func normalizedName(_ value: String) -> String {
        value
            .lowercased()
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

final class SupabaseRecipeIngredientsService {
    static let shared = SupabaseRecipeIngredientsService()

    private init() {}

    func fetchIngredients(recipeIDs: [String]) async throws -> [SupabaseRecipeIngredientRow] {
        let ids = Array(Set(recipeIDs)).sorted()
        guard !ids.isEmpty else { return [] }

        let joinedIDs = ids.joined(separator: ",")
        guard let encodedIDs = joinedIDs.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(
                string: "\(SupabaseConfig.url)/rest/v1/recipe_ingredients?select=id,recipe_id,ingredient_id,display_name,quantity_text,image_url,sort_order&recipe_id=in.(\(encodedIDs))&order=sort_order.asc"
              ) else {
            throw SupabaseRecipeIngredientsError.invalidRequest
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(SupabaseConfig.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(SupabaseConfig.anonKey)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SupabaseRecipeIngredientsError.invalidResponse
        }

        guard (200 ... 299).contains(httpResponse.statusCode) else {
            let errorPayload = try? JSONDecoder().decode(SupabaseRestErrorResponse.self, from: data)
            let fallback = "Failed to load recipe ingredients (\(httpResponse.statusCode))."
            throw SupabaseRecipeIngredientsError.requestFailed(errorPayload?.message ?? errorPayload?.error ?? fallback)
        }

        return try JSONDecoder().decode([SupabaseRecipeIngredientRow].self, from: data)
    }
}

final class SupabaseRecipeIngredientArtService {
    static let shared = SupabaseRecipeIngredientArtService()

    private init() {}

    func fetchArtRows(ingredientIDs: [String], displayNames: [String] = []) async throws -> [SupabaseRecipeIngredientArtRow] {
        let ids = Array(
            Set(
                ingredientIDs
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            )
        ).sorted()
        let normalizedDisplayNames = Array(
            Set(
                displayNames
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            )
        ).sorted()

        var artRows: [SupabaseRecipeIngredientArtRow] = []

        if !ids.isEmpty {
            let select = "ingredient_id,display_name,image_url"
            let inClause = ids.joined(separator: ",")
            guard let encodedIDs = inClause.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
                  let url = URL(
                    string: "\(SupabaseConfig.url)/rest/v1/recipe_ingredients?select=\(select)&ingredient_id=in.(\(encodedIDs))&image_url=not.is.null&order=ingredient_id.asc&limit=5000"
                  ) else {
                throw SupabaseRecipeIngredientsError.invalidRequest
            }

            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.setValue(SupabaseConfig.anonKey, forHTTPHeaderField: "apikey")
            request.setValue("Bearer \(SupabaseConfig.anonKey)", forHTTPHeaderField: "Authorization")

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw SupabaseRecipeIngredientsError.invalidResponse
            }

            guard (200 ... 299).contains(httpResponse.statusCode) else {
                let errorPayload = try? JSONDecoder().decode(SupabaseRestErrorResponse.self, from: data)
                let fallback = "Failed to load recipe ingredient art (\(httpResponse.statusCode))."
                throw SupabaseRecipeIngredientsError.requestFailed(errorPayload?.message ?? errorPayload?.error ?? fallback)
            }

            artRows.append(contentsOf: try JSONDecoder().decode([SupabaseRecipeIngredientArtRow].self, from: data))
        }

        for displayName in normalizedDisplayNames {
            guard let encodedPattern = displayName
                .replacingOccurrences(of: " ", with: "%")
                .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
                  let url = URL(
                    string: "\(SupabaseConfig.url)/rest/v1/recipe_ingredients?select=ingredient_id,display_name,image_url&display_name=ilike.*\(encodedPattern)*&image_url=not.is.null&limit=12"
                  ) else {
                continue
            }

            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.setValue(SupabaseConfig.anonKey, forHTTPHeaderField: "apikey")
            request.setValue("Bearer \(SupabaseConfig.anonKey)", forHTTPHeaderField: "Authorization")

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw SupabaseRecipeIngredientsError.invalidResponse
            }

            guard (200 ... 299).contains(httpResponse.statusCode) else {
                continue
            }

            let rows = try JSONDecoder().decode([SupabaseRecipeIngredientArtRow].self, from: data)
            artRows.append(contentsOf: rows)
        }

        var seen = Set<String>()
        return artRows.filter { row in
            let key = [
                row.ingredientID,
                SupabaseIngredientsCatalogService.normalizedName(row.displayName),
                row.imageURL?.absoluteString ?? ""
            ].joined(separator: "::")
            return seen.insert(key).inserted
        }
    }
}

struct SupabaseIdTokenRequest: Codable {
    let provider: String
    let idToken: String
    let nonce: String

    enum CodingKeys: String, CodingKey {
        case provider
        case idToken = "id_token"
        case nonce
    }
}

struct SupabaseProfileStateSnapshot {
    let onboarded: Bool
    let profile: UserProfile?
    let lastOnboardingStep: Int
    let email: String?
    let displayName: String?
    let authProvider: AuthProvider?
    let accountStatus: String?
    let deactivatedAt: String?

    var isDeactivated: Bool {
        accountStatus?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "deactivated"
            || deactivatedAt?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }
}

struct SupabaseProfileUpsertPayload: Codable {
    let id: String
    let email: String?
    let displayName: String?
    let authProvider: String?
    let onboarded: Bool
    let onboardingCompletedAt: String?
    let lastOnboardingStep: Int
    let preferredName: String?
    let preferredCuisines: [String]
    let cuisineCountries: [String]
    let dietaryPatterns: [String]
    let hardRestrictions: [String]
    let cadence: String?
    let deliveryAnchorDay: String?
    let adults: Int?
    let kids: Int?
    let cooksForOthers: Bool?
    let mealsPerWeek: Int?
    let budgetPerCycle: Double?
    let budgetWindow: String?
    let orderingAutonomy: String?
    let addressLine1: String?
    let addressLine2: String?
    let city: String?
    let region: String?
    let postalCode: String?
    let deliveryNotes: String?
    let profileJSON: UserProfile?

    enum CodingKeys: String, CodingKey {
        case id
        case email
        case displayName = "display_name"
        case authProvider = "auth_provider"
        case onboarded
        case onboardingCompletedAt = "onboarding_completed_at"
        case lastOnboardingStep = "last_onboarding_step"
        case preferredName = "preferred_name"
        case preferredCuisines = "preferred_cuisines"
        case cuisineCountries = "cuisine_countries"
        case dietaryPatterns = "dietary_patterns"
        case hardRestrictions = "hard_restrictions"
        case cadence
        case deliveryAnchorDay = "delivery_anchor_day"
        case adults
        case kids
        case cooksForOthers = "cooks_for_others"
        case mealsPerWeek = "meals_per_week"
        case budgetPerCycle = "budget_per_cycle"
        case budgetWindow = "budget_window"
        case orderingAutonomy = "ordering_autonomy"
        case addressLine1 = "address_line1"
        case addressLine2 = "address_line2"
        case city
        case region
        case postalCode = "postal_code"
        case deliveryNotes = "delivery_notes"
        case profileJSON = "profile_json"
    }
}

struct SupabaseProfileRow: Codable {
    let id: String?
    let email: String?
    let displayName: String?
    let authProvider: String?
    let accountStatus: String?
    let deactivatedAt: String?
    let onboarded: Bool?
    let lastOnboardingStep: Int?
    let profileJSON: UserProfile?
    let preferredName: String?
    let preferredCuisines: [String]?
    let cuisineCountries: [String]?
    let dietaryPatterns: [String]?
    let hardRestrictions: [String]?
    let cadence: String?
    let deliveryAnchorDay: String?
    let adults: Int?
    let kids: Int?
    let cooksForOthers: Bool?
    let mealsPerWeek: Int?
    let budgetPerCycle: Double?
    let budgetWindow: String?
    let orderingAutonomy: String?
    let addressLine1: String?
    let addressLine2: String?
    let city: String?
    let region: String?
    let postalCode: String?
    let deliveryNotes: String?

    enum CodingKeys: String, CodingKey {
        case id
        case email
        case displayName = "display_name"
        case authProvider = "auth_provider"
        case accountStatus = "account_status"
        case deactivatedAt = "deactivated_at"
        case onboarded
        case lastOnboardingStep = "last_onboarding_step"
        case profileJSON = "profile_json"
        case preferredName = "preferred_name"
        case preferredCuisines = "preferred_cuisines"
        case cuisineCountries = "cuisine_countries"
        case dietaryPatterns = "dietary_patterns"
        case hardRestrictions = "hard_restrictions"
        case cadence
        case deliveryAnchorDay = "delivery_anchor_day"
        case adults
        case kids
        case cooksForOthers = "cooks_for_others"
        case mealsPerWeek = "meals_per_week"
        case budgetPerCycle = "budget_per_cycle"
        case budgetWindow = "budget_window"
        case orderingAutonomy = "ordering_autonomy"
        case addressLine1 = "address_line1"
        case addressLine2 = "address_line2"
        case city
        case region
        case postalCode = "postal_code"
        case deliveryNotes = "delivery_notes"
    }

    var decodedProfile: UserProfile? {
        if let profileJSON {
            return profileJSON
        }

        guard let preferredCuisines,
              let cadence,
              let budgetPerCycle,
              let budgetWindow,
              let orderingAutonomy else {
            return nil
        }

        let cuisines = preferredCuisines.compactMap(CuisinePreference.init(rawValue:))
        guard !cuisines.isEmpty,
              let cadenceValue = MealCadence(rawValue: cadence),
              let budgetWindowValue = BudgetWindow(rawValue: budgetWindow),
              let orderingAutonomyValue = OrderingAutonomyLevel(rawValue: orderingAutonomy) else {
            return nil
        }

        return UserProfile(
            preferredName: preferredName,
            preferredCuisines: cuisines,
            cadence: cadenceValue,
            deliveryAnchorDay: DeliveryAnchorDay(rawValue: deliveryAnchorDay ?? "") ?? .sunday,
            deliveryTimeMinutes: UserProfile.starter.deliveryTimeMinutes,
            rotationPreference: .dynamic,
            maxRepeatsPerCycle: 2,
            storage: .starter,
            consumption: ConsumptionProfile(
                adults: adults ?? 1,
                kids: kids ?? 0,
                mealsPerWeek: mealsPerWeek ?? 4,
                includeLeftovers: true
            ),
            preferredProviders: [],
            pantryStaples: [],
            allergies: hardRestrictions ?? [],
            budgetPerCycle: budgetPerCycle,
            explorationLevel: .balanced,
            deliveryAddress: DeliveryAddress(
                line1: addressLine1 ?? "",
                line2: addressLine2 ?? "",
                city: city ?? "",
                region: region ?? "",
                postalCode: postalCode ?? "",
                deliveryNotes: deliveryNotes ?? ""
            ),
            dietaryPatterns: dietaryPatterns ?? [],
            cuisineCountries: cuisineCountries ?? [],
            hardRestrictions: hardRestrictions ?? [],
            favoriteFoods: [],
            favoriteFlavors: [],
            neverIncludeFoods: [],
            mealPrepGoals: [],
            cooksForOthers: cooksForOthers ?? false,
            kitchenEquipment: [],
            budgetWindow: budgetWindowValue,
            budgetFlexibility: .slightlyFlexible,
            purchasingBehavior: .healthier,
            orderingAutonomy: orderingAutonomyValue
        )
    }
}


struct SupabaseRestErrorResponse: Codable {
    let message: String?
    let error: String?
}

struct SupabaseSavedRecipeRow: Codable {
    let recipeID: String
    let title: String
    let description: String?
    let authorName: String?
    let authorHandle: String?
    let category: String?
    let recipeType: String?
    let cookTimeText: String?
    let publishedDate: String?
    let discoverCardImageURL: String?
    let heroImageURL: String?
    let recipeURL: String?
    let source: String?

    enum CodingKeys: String, CodingKey {
        case recipeID = "recipe_id"
        case title
        case description
        case authorName = "author_name"
        case authorHandle = "author_handle"
        case category
        case recipeType = "recipe_type"
        case cookTimeText = "cook_time_text"
        case publishedDate = "published_date"
        case discoverCardImageURL = "discover_card_image_url"
        case heroImageURL = "hero_image_url"
        case recipeURL = "recipe_url"
        case source
    }

    var recipe: DiscoverRecipeCardData {
        DiscoverRecipeCardData(
            id: recipeID,
            title: title,
            description: description,
            authorName: authorName,
            authorHandle: authorHandle,
            category: category,
            recipeType: recipeType,
            cookTimeText: cookTimeText,
            publishedDate: publishedDate,
            imageURLString: discoverCardImageURL,
            heroImageURLString: heroImageURL,
            recipeURLString: recipeURL,
            source: source
        )
    }

    var needsCanonicalImageHydration: Bool {
        if recipe.imageCandidates.isEmpty {
            return true
        }

        return Self.isEphemeralSocialImageURL(discoverCardImageURL) || Self.isEphemeralSocialImageURL(heroImageURL)
    }

    func hydratingImages(from canonical: SupabaseRecipeCardImageRow) -> SupabaseSavedRecipeRow {
        SupabaseSavedRecipeRow(
            recipeID: recipeID,
            title: title,
            description: description,
            authorName: authorName,
            authorHandle: authorHandle,
            category: category,
            recipeType: recipeType,
            cookTimeText: cookTimeText,
            publishedDate: publishedDate,
            discoverCardImageURL: canonical.preferredDiscoverCardImageURL ?? discoverCardImageURL,
            heroImageURL: canonical.preferredHeroImageURL ?? heroImageURL,
            recipeURL: recipeURL,
            source: source
        )
    }

    private static func isEphemeralSocialImageURL(_ rawValue: String?) -> Bool {
        guard let rawValue,
              let host = URL(string: rawValue)?.host?.lowercased()
        else {
            return false
        }

        return host.contains("cdninstagram")
            || host.contains("instagram")
            || host.contains("fbcdn")
    }
}

struct SupabaseRecipeCardImageRow: Codable {
    let id: String
    let discoverCardImageURL: String?
    let heroImageURL: String?

    enum CodingKeys: String, CodingKey {
        case id
        case discoverCardImageURL = "discover_card_image_url"
        case heroImageURL = "hero_image_url"
    }

    var preferredDiscoverCardImageURL: String? {
        normalizedURLString(discoverCardImageURL) ?? normalizedURLString(heroImageURL)
    }

    var preferredHeroImageURL: String? {
        normalizedURLString(heroImageURL) ?? normalizedURLString(discoverCardImageURL)
    }

    private func normalizedURLString(_ rawValue: String?) -> String? {
        guard let rawValue else { return nil }
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

struct SupabaseSavedRecipeIDRow: Codable {
    let recipeID: String

    enum CodingKeys: String, CodingKey {
        case recipeID = "recipe_id"
    }
}

struct SupabaseSavedRecipeTitleRow: Codable {
    let title: String
}

struct SupabaseSavedRecipeUpsertPayload: Codable {
    let userID: String
    let recipeID: String
    let title: String
    let description: String?
    let authorName: String?
    let authorHandle: String?
    let category: String?
    let recipeType: String?
    let cookTimeText: String?
    let publishedDate: String?
    let discoverCardImageURL: String?
    let heroImageURL: String?
    let recipeURL: String?
    let source: String?
    let savedAt: String

    init(userID: String, recipe: DiscoverRecipeCardData, savedAt: String) {
        self.userID = userID
        self.recipeID = recipe.id
        self.title = recipe.title
        self.description = recipe.description
        self.authorName = recipe.authorName
        self.authorHandle = recipe.authorHandle
        self.category = recipe.category
        self.recipeType = recipe.recipeType
        self.cookTimeText = recipe.cookTimeText
        self.publishedDate = recipe.publishedDate
        self.discoverCardImageURL = recipe.imageURLString
        self.heroImageURL = recipe.heroImageURLString
        self.recipeURL = recipe.recipeURLString
        self.source = recipe.source
        self.savedAt = savedAt
    }

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case recipeID = "recipe_id"
        case title
        case description
        case authorName = "author_name"
        case authorHandle = "author_handle"
        case category
        case recipeType = "recipe_type"
        case cookTimeText = "cook_time_text"
        case publishedDate = "published_date"
        case discoverCardImageURL = "discover_card_image_url"
        case heroImageURL = "hero_image_url"
        case recipeURL = "recipe_url"
        case source
        case savedAt = "saved_at"
    }
}
