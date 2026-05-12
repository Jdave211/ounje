import SwiftUI
import Foundation
import UIKit

@MainActor
final class SavedRecipesStore: ObservableObject {
    @Published private(set) var savedRecipes: [DiscoverRecipeCardData] = []

    private let legacyKey = "ounje-saved-recipes-v1"
    private let keyPrefix = "ounje-saved-recipes-v2"
    private let deletedKeyPrefix = "ounje-saved-recipes-deleted-v1"
    private let pendingDeleteKeyPrefix = "ounje-saved-recipes-pending-delete-v1"
    private let toastCenter: AppToastCenter
    private var activeUserID: String?
    private var activeAccessToken: String?
    private var deletedSavedRecipeIDs: Set<String> = []
    private var pendingRemoteDeleteRecipeIDs: Set<String> = []
    private var hasPendingRemoteSaveRetry = false
    private var lastRemoteSyncUserID: String?
    private var lastRemoteSyncAt: Date?
    private let remoteSyncTTL: TimeInterval = 15 * 60
    private var authSessionProvider: (() async -> AuthSession?)?

    init(toastCenter: AppToastCenter) {
        self.toastCenter = toastCenter
        load(for: nil)
    }

    func isSaved(_ recipe: DiscoverRecipeCardData) -> Bool {
        savedRecipes.contains { $0.id == recipe.id }
    }

    func configureAuthSessionProvider(_ provider: @escaping () async -> AuthSession?) {
        authSessionProvider = provider
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
            if !pendingRemoteDeleteRecipeIDs.isEmpty {
                await reconcilePendingDeletes(userID: authSession.userID)
            }

            let remoteRecipes = try await SupabaseSavedRecipesService.shared.fetchSavedRecipes(
                userID: authSession.userID,
                accessToken: authSession.accessToken
            )
            let remoteIDSet = Set(remoteRecipes.map(\.id))

            let mergedRecipes = merge(local: savedRecipes, remote: remoteRecipes)

            if mergedRecipes != savedRecipes {
                savedRecipes = mergedRecipes
                persist()
            }

            let remoteIDs = remoteIDSet.subtracting(deletedSavedRecipeIDs)
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
            if !pendingRemoteDeleteRecipeIDs.isEmpty {
                await reconcilePendingDeletes(userID: authSession.userID)
            }

            let remoteRecipes = try await SupabaseSavedRecipesService.shared.fetchSavedRecipes(
                userID: authSession.userID,
                accessToken: authSession.accessToken
            )
            let localRecipes = savedRecipes.filter { !deletedSavedRecipeIDs.contains($0.id) }
            let filteredRemoteRecipes = remoteRecipes.filter { !deletedSavedRecipeIDs.contains($0.id) }
            savedRecipes = deduplicated(filteredRemoteRecipes + localRecipes)
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
            pendingRemoteDeleteRecipeIDs.remove(recipe.id)
            savedRecipes.removeAll { $0.id == recipe.id }
            savedRecipes.insert(recipe, at: 0)
            toastCenter.showSavedRecipe(recipe)
        } else {
            savedRecipes.removeAll { $0.id == recipe.id }
            deletedSavedRecipeIDs.insert(recipe.id)
            pendingRemoteDeleteRecipeIDs.insert(recipe.id)
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
                guard let remoteSession = await self.resolvedRemoteSession(fallbackUserID: userID) else { return }
                if shouldSave {
                    try await SupabaseSavedRecipesService.shared.upsertSavedRecipes(
                        userID: remoteSession.userID,
                        recipes: [recipe],
                        accessToken: remoteSession.accessToken ?? accessToken
                    )
                    await MainActor.run {
                        self.hasPendingRemoteSaveRetry = false
                        self.markRemoteSyncComplete(for: remoteSession.userID)
                    }
                } else {
                    try await SupabaseSavedRecipesService.shared.deleteSavedRecipe(
                        userID: remoteSession.userID,
                        recipeID: recipe.id,
                        accessToken: remoteSession.accessToken ?? accessToken
                    )
                    await MainActor.run {
                        self.pendingRemoteDeleteRecipeIDs.remove(recipe.id)
                        self.persist()
                    }
                }
            } catch {
                if shouldSave {
                    print("[SavedRecipesStore] Remote save failed; will retry:", error.localizedDescription)
                    await MainActor.run {
                        self.hasPendingRemoteSaveRetry = true
                    }
                } else {
                    print("[SavedRecipesStore] Remote unsave failed; keeping local tombstone for retry:", error.localizedDescription)
                }
            }
        }
    }

    /// Saves an imported recipe. When `respectUnsave` is true the call is silently
    /// skipped if the user has explicitly unsaved this recipe, so background sync
    /// and repeated import refreshes never resurrect tombstoned items.
    /// Pass `respectUnsave: false` only for an explicit user action that should
    /// override the tombstone.
    func saveImportedRecipe(
        _ recipe: DiscoverRecipeCardData,
        showToast: Bool = true,
        respectUnsave: Bool = true
    ) {
        if respectUnsave, deletedSavedRecipeIDs.contains(recipe.id) { return }
        let existing = savedRecipes.first(where: { $0.id == recipe.id })
        let resolved = mergeRecipeCards(primary: recipe, fallback: existing)
        deletedSavedRecipeIDs.remove(recipe.id)
        pendingRemoteDeleteRecipeIDs.remove(recipe.id)
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
                guard let remoteSession = await self.resolvedRemoteSession(fallbackUserID: userID) else { return }
                try await SupabaseSavedRecipesService.shared.upsertSavedRecipes(
                    userID: remoteSession.userID,
                    recipes: [resolved],
                    accessToken: remoteSession.accessToken ?? accessToken
                )
                await MainActor.run {
                    self.hasPendingRemoteSaveRetry = false
                    self.markRemoteSyncComplete(for: remoteSession.userID)
                }
            } catch {
                print("[SavedRecipesStore] Remote imported recipe save failed; will retry:", error.localizedDescription)
                await MainActor.run {
                    self.hasPendingRemoteSaveRetry = true
                }
            }
        }
    }

    private func restoreSavedRecipe(_ recipe: DiscoverRecipeCardData) {
        deletedSavedRecipeIDs.remove(recipe.id)
        pendingRemoteDeleteRecipeIDs.remove(recipe.id)
        savedRecipes.removeAll { $0.id == recipe.id }
        savedRecipes.insert(recipe, at: 0)
        persist()
        toastCenter.dismiss()

        guard let userID = activeUserID else { return }
        let accessToken = activeAccessToken
        Task(priority: .utility) {
            do {
                guard let remoteSession = await self.resolvedRemoteSession(fallbackUserID: userID) else { return }
                try await SupabaseSavedRecipesService.shared.upsertSavedRecipes(
                    userID: remoteSession.userID,
                    recipes: [recipe],
                    accessToken: remoteSession.accessToken ?? accessToken
                )
                await MainActor.run {
                    self.hasPendingRemoteSaveRetry = false
                    self.markRemoteSyncComplete(for: remoteSession.userID)
                }
            } catch {
                print("[SavedRecipesStore] Remote save restore failed; will retry:", error.localizedDescription)
                await MainActor.run {
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
        if let pendingDeleteData = try? JSONEncoder().encode(Array(pendingRemoteDeleteRecipeIDs)) {
            UserDefaults.standard.set(pendingDeleteData, forKey: pendingDeleteStorageKey(for: activeUserID))
        }
    }

    private func load(for userID: String?) {
        let defaults = UserDefaults.standard
        let primaryKey = storageKey(for: userID)
        let deletedKey = deletedStorageKey(for: userID)
        let pendingDeleteKey = pendingDeleteStorageKey(for: userID)
        let fallbackKey = userID == nil ? legacyKey : nil

        let data = defaults.data(forKey: primaryKey)
            ?? fallbackKey.flatMap { defaults.data(forKey: $0) }
        let deletedData = defaults.data(forKey: deletedKey)
        let pendingDeleteData = defaults.data(forKey: pendingDeleteKey)

        let primaryRecipes = data
            .flatMap { try? JSONDecoder().decode([DiscoverRecipeCardData].self, from: $0) } ?? []
        let decoded = deduplicated(primaryRecipes)

        guard !decoded.isEmpty else {
            savedRecipes = []
            deletedSavedRecipeIDs = loadDeletedRecipeIDs(from: deletedData)
            pendingRemoteDeleteRecipeIDs = loadDeletedRecipeIDs(from: pendingDeleteData)
            return
        }

        deletedSavedRecipeIDs = loadDeletedRecipeIDs(from: deletedData)
        pendingRemoteDeleteRecipeIDs = loadDeletedRecipeIDs(from: pendingDeleteData)
        savedRecipes = deduplicated(decoded.filter { !deletedSavedRecipeIDs.contains($0.id) })

        if let mergedData = try? JSONEncoder().encode(savedRecipes),
           defaults.data(forKey: primaryKey) == nil || primaryRecipes != savedRecipes {
            defaults.set(mergedData, forKey: primaryKey)
        }
    }

    private func storageKey(for userID: String?) -> String {
        "\(keyPrefix)-\(userID ?? "guest")"
    }

    private func deletedStorageKey(for userID: String?) -> String {
        "\(deletedKeyPrefix)-\(userID ?? "guest")"
    }

    private func pendingDeleteStorageKey(for userID: String?) -> String {
        "\(pendingDeleteKeyPrefix)-\(userID ?? "guest")"
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
        let filteredLocal = local.filter { !deletedSavedRecipeIDs.contains($0.id) }
        return deduplicated(filteredRemote + filteredLocal)
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
              pendingRemoteDeleteRecipeIDs.isEmpty,
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
        let pending = pendingRemoteDeleteRecipeIDs
        guard !pending.isEmpty else { return }

        for recipeID in pending {
            do {
                guard let remoteSession = await resolvedRemoteSession(fallbackUserID: userID) else { return }
                try await SupabaseSavedRecipesService.shared.deleteSavedRecipe(
                    userID: remoteSession.userID,
                    recipeID: recipeID,
                    accessToken: remoteSession.accessToken
                )
                pendingRemoteDeleteRecipeIDs.remove(recipeID)
            } catch {
                // Keep the explicit unsave tombstone and retry the remote delete later.
            }
        }

        persist()
    }

    private func resolvedRemoteSession(fallbackUserID: String) async -> (userID: String, accessToken: String?)? {
        if let session = await authSessionProvider?(),
           session.userID == fallbackUserID {
            activeUserID = session.userID
            activeAccessToken = session.accessToken
            return (session.userID, session.accessToken)
        }

        return (fallbackUserID, activeAccessToken)
    }
}
