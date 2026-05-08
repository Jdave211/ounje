import SwiftUI
import Foundation
import UIKit

@MainActor
final class SavedRecipesStore: ObservableObject {
    @Published private(set) var savedRecipes: [DiscoverRecipeCardData] = []

    private let legacyKey = "ounje-saved-recipes-v1"
    private let keyPrefix = "ounje-saved-recipes-v2"
    private let deletedKeyPrefix = "ounje-saved-recipes-deleted-v1"
    private let toastCenter: AppToastCenter
    private var activeUserID: String?
    private var activeAccessToken: String?
    private var deletedSavedRecipeIDs: Set<String> = []
    private var hasPendingRemoteSaveRetry = false
    private var lastRemoteSyncUserID: String?
    private var lastRemoteSyncAt: Date?
    private let remoteSyncTTL: TimeInterval = 45

    init(toastCenter: AppToastCenter) {
        self.toastCenter = toastCenter
        load(for: nil)
    }

    func isSaved(_ recipe: DiscoverRecipeCardData) -> Bool {
        savedRecipes.contains { $0.id == recipe.id }
    }

    func bootstrap(authSession: AuthSession?) async {
        let resolvedUserID = authSession?.userID

        if activeUserID != resolvedUserID {
            activeUserID = resolvedUserID
            load(for: resolvedUserID)
        }
        activeAccessToken = authSession?.accessToken

        guard let authSession else { return }
        if shouldSkipRemoteSync(for: authSession.userID) {
            return
        }

        do {
            let remoteRecipes = try await SupabaseSavedRecipesService.shared.fetchSavedRecipes(
                userID: authSession.userID,
                accessToken: authSession.accessToken
            )
            let mergedRecipes = merge(local: savedRecipes, remote: remoteRecipes)

            if mergedRecipes != savedRecipes {
                savedRecipes = mergedRecipes
                persist()
            }

            if !deletedSavedRecipeIDs.isEmpty {
                await reconcilePendingDeletes(userID: authSession.userID)
            }

            let remoteIDs = Set(remoteRecipes.map(\.id)).subtracting(deletedSavedRecipeIDs)
            let unsyncedLocalRecipes = mergedRecipes.filter { !remoteIDs.contains($0.id) && !deletedSavedRecipeIDs.contains($0.id) }
            if !unsyncedLocalRecipes.isEmpty {
                try await SupabaseSavedRecipesService.shared.upsertSavedRecipes(
                    userID: authSession.userID,
                    recipes: unsyncedLocalRecipes,
                    accessToken: authSession.accessToken
                )
            }
            markRemoteSyncComplete(for: authSession.userID)
        } catch {
            // Keep local saves available even when network sync fails.
            hasPendingRemoteSaveRetry = true
        }
    }

    func refreshFromRemote(authSession: AuthSession?, force: Bool = false) async {
        guard let authSession else { return }

        if activeUserID != authSession.userID {
            activeUserID = authSession.userID
            load(for: authSession.userID)
        }
        activeAccessToken = authSession.accessToken
        if !force, shouldSkipRemoteSync(for: authSession.userID) {
            return
        }

        do {
            let remoteRecipes = try await SupabaseSavedRecipesService.shared.fetchSavedRecipes(
                userID: authSession.userID,
                accessToken: authSession.accessToken
            )
            let localRecipes = savedRecipes
            deletedSavedRecipeIDs.removeAll()
            savedRecipes = deduplicated(remoteRecipes + localRecipes)
            persist()
            markRemoteSyncComplete(for: authSession.userID)
        } catch {
            await bootstrap(authSession: authSession)
        }
    }

    func toggle(_ recipe: DiscoverRecipeCardData) {
        let shouldSave = !isSaved(recipe)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()

        if shouldSave {
            deletedSavedRecipeIDs.remove(recipe.id)
            savedRecipes.removeAll { $0.id == recipe.id }
            savedRecipes.insert(recipe, at: 0)
            toastCenter.showSavedRecipe(recipe)
        } else {
            savedRecipes.removeAll { $0.id == recipe.id }
            deletedSavedRecipeIDs.insert(recipe.id)
            toastCenter.showUnsavedRecipe(
                title: recipe.title,
                thumbnailURLString: recipe.imageURLString ?? recipe.heroImageURLString,
                destination: nil,
                actionTitle: "Undo",
                action: { [weak self] in
                    self?.restoreSavedRecipe(recipe)
                }
            )
        }
        persist()

        guard let userID = activeUserID else { return }
        let accessToken = activeAccessToken

        Task(priority: .utility) {
            do {
                if shouldSave {
                    try await SupabaseSavedRecipesService.shared.upsertSavedRecipes(
                        userID: userID,
                        recipes: [recipe],
                        accessToken: accessToken
                    )
                    await MainActor.run {
                        self.hasPendingRemoteSaveRetry = false
                        self.markRemoteSyncComplete(for: userID)
                    }
                } else {
                    try await SupabaseSavedRecipesService.shared.deleteSavedRecipe(
                        userID: userID,
                        recipeID: recipe.id,
                        accessToken: accessToken
                    )
                    await MainActor.run {
                        self.deletedSavedRecipeIDs.remove(recipe.id)
                        self.persist()
                    }
                }
            } catch {
                if shouldSave {
                    await MainActor.run {
                        self.toastCenter.show(
                            title: "Save will retry",
                            subtitle: recipe.title,
                            systemImage: "arrow.clockwise"
                        )
                        self.hasPendingRemoteSaveRetry = true
                    }
                } else {
                    print("[SavedRecipesStore] Remote unsave failed; keeping local tombstone for retry:", error.localizedDescription)
                }
            }
        }
    }

    func saveImportedRecipe(_ recipe: DiscoverRecipeCardData, showToast: Bool = true) {
        let existing = savedRecipes.first(where: { $0.id == recipe.id })
        let resolved = mergeRecipeCards(primary: recipe, fallback: existing)
        deletedSavedRecipeIDs.remove(recipe.id)
        savedRecipes.removeAll { $0.id == recipe.id }
        savedRecipes.insert(resolved, at: 0)
        persist()

        if showToast {
            toastCenter.showSavedRecipe(resolved)
        }

        guard let userID = activeUserID else { return }
        let accessToken = activeAccessToken
        Task(priority: .utility) {
            do {
                try await SupabaseSavedRecipesService.shared.upsertSavedRecipes(
                    userID: userID,
                    recipes: [resolved],
                    accessToken: accessToken
                )
                await MainActor.run {
                    self.hasPendingRemoteSaveRetry = false
                    self.markRemoteSyncComplete(for: userID)
                }
            } catch {
                await MainActor.run {
                    self.toastCenter.show(
                        title: "Save will retry",
                        subtitle: resolved.title,
                        systemImage: "arrow.clockwise"
                    )
                    self.hasPendingRemoteSaveRetry = true
                }
            }
        }
    }

    private func restoreSavedRecipe(_ recipe: DiscoverRecipeCardData) {
        deletedSavedRecipeIDs.remove(recipe.id)
        savedRecipes.removeAll { $0.id == recipe.id }
        savedRecipes.insert(recipe, at: 0)
        persist()
        toastCenter.dismiss()

        guard let userID = activeUserID else { return }
        let accessToken = activeAccessToken
        Task(priority: .utility) {
            do {
                try await SupabaseSavedRecipesService.shared.upsertSavedRecipes(
                    userID: userID,
                    recipes: [recipe],
                    accessToken: accessToken
                )
                await MainActor.run {
                    self.hasPendingRemoteSaveRetry = false
                    self.markRemoteSyncComplete(for: userID)
                }
            } catch {
                await MainActor.run {
                    self.toastCenter.show(
                        title: "Save will retry",
                        subtitle: recipe.title,
                        systemImage: "arrow.clockwise"
                    )
                    self.hasPendingRemoteSaveRetry = true
                }
            }
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(savedRecipes) {
            UserDefaults.standard.set(data, forKey: storageKey(for: activeUserID))
        }
        if let deletedData = try? JSONEncoder().encode(Array(deletedSavedRecipeIDs)) {
            UserDefaults.standard.set(deletedData, forKey: deletedStorageKey(for: activeUserID))
        }
    }

    private func load(for userID: String?) {
        let defaults = UserDefaults.standard
        let primaryKey = storageKey(for: userID)
        let deletedKey = deletedStorageKey(for: userID)
        let fallbackKey = userID == nil ? legacyKey : nil

        let data = defaults.data(forKey: primaryKey)
            ?? fallbackKey.flatMap { defaults.data(forKey: $0) }
        let deletedData = defaults.data(forKey: deletedKey)

        guard let data,
              let decoded = try? JSONDecoder().decode([DiscoverRecipeCardData].self, from: data)
        else {
            savedRecipes = []
            deletedSavedRecipeIDs = loadDeletedRecipeIDs(from: deletedData)
            return
        }

        deletedSavedRecipeIDs = loadDeletedRecipeIDs(from: deletedData)
        savedRecipes = deduplicated(decoded.filter { !deletedSavedRecipeIDs.contains($0.id) })

        if defaults.data(forKey: primaryKey) == nil {
            defaults.set(data, forKey: primaryKey)
        }
    }

    private func storageKey(for userID: String?) -> String {
        "\(keyPrefix)-\(userID ?? "guest")"
    }

    private func deletedStorageKey(for userID: String?) -> String {
        "\(deletedKeyPrefix)-\(userID ?? "guest")"
    }

    private func loadDeletedRecipeIDs(from data: Data?) -> Set<String> {
        guard let data,
              let decoded = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return Set(decoded)
    }

    private func merge(local: [DiscoverRecipeCardData], remote: [DiscoverRecipeCardData]) -> [DiscoverRecipeCardData] {
        // Prefer the server's newest ordering first, then keep any local-only saves.
        let filteredRemote = remote.filter { !deletedSavedRecipeIDs.contains($0.id) }
        return deduplicated(filteredRemote + local)
    }

    private func deduplicated(_ recipes: [DiscoverRecipeCardData]) -> [DiscoverRecipeCardData] {
        var merged: [String: DiscoverRecipeCardData] = [:]
        var orderedIDs: [String] = []

        for recipe in recipes {
            if let existing = merged[recipe.id] {
                merged[recipe.id] = mergeRecipeCards(primary: existing, fallback: recipe)
            } else {
                merged[recipe.id] = recipe
                orderedIDs.append(recipe.id)
            }
        }

        return orderedIDs.compactMap { merged[$0] }
    }

    private func shouldSkipRemoteSync(for userID: String) -> Bool {
        guard !hasPendingRemoteSaveRetry,
              deletedSavedRecipeIDs.isEmpty,
              lastRemoteSyncUserID == userID,
              let lastRemoteSyncAt else {
            return false
        }
        return Date().timeIntervalSince(lastRemoteSyncAt) < remoteSyncTTL
    }

    private func markRemoteSyncComplete(for userID: String) {
        hasPendingRemoteSaveRetry = false
        lastRemoteSyncUserID = userID
        lastRemoteSyncAt = .now
    }

    private func mergeRecipeCards(primary: DiscoverRecipeCardData, fallback: DiscoverRecipeCardData?) -> DiscoverRecipeCardData {
        guard let fallback else { return primary }

        return DiscoverRecipeCardData(
            id: primary.id,
            title: primary.title,
            description: primary.description ?? fallback.description,
            authorName: primary.authorName ?? fallback.authorName,
            authorHandle: primary.authorHandle ?? fallback.authorHandle,
            category: primary.category ?? fallback.category,
            recipeType: primary.recipeType ?? fallback.recipeType,
            discoverBrackets: (primary.discoverBrackets?.isEmpty == false ? primary.discoverBrackets : fallback.discoverBrackets),
            cookTimeText: primary.cookTimeText ?? fallback.cookTimeText,
            cookTimeMinutes: primary.cookTimeMinutes ?? fallback.cookTimeMinutes,
            publishedDate: primary.publishedDate ?? fallback.publishedDate,
            imageURLString: primary.imageURLString ?? fallback.imageURLString,
            heroImageURLString: primary.heroImageURLString ?? fallback.heroImageURLString,
            recipeURLString: primary.recipeURLString ?? fallback.recipeURLString,
            source: primary.source ?? fallback.source
        )
    }

    private func reconcilePendingDeletes(userID: String) async {
        let pending = deletedSavedRecipeIDs
        guard !pending.isEmpty else { return }
        let accessToken = activeAccessToken

        for recipeID in pending {
            do {
                try await SupabaseSavedRecipesService.shared.deleteSavedRecipe(
                    userID: userID,
                    recipeID: recipeID,
                    accessToken: accessToken
                )
                deletedSavedRecipeIDs.remove(recipeID)
            } catch {
                // Keep the tombstone locally so the recipe does not resurrect on relaunch.
            }
        }

        persist()
    }
}
