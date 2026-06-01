import SwiftUI
import Foundation
import UIKit

@MainActor
final class SavedRecipesStore: ObservableObject {
    @Published private(set) var savedRecipes: [DiscoverRecipeCardData] = []
    @Published private(set) var isSyncingRemote = false

    private let legacyKey = "ounje-saved-recipes-v1"
    private let keyPrefix = "ounje-saved-recipes-v2"
    private let deletedKeyPrefix = "ounje-saved-recipes-deleted-v1"
    private let pendingDeleteKeyPrefix = "ounje-saved-recipes-pending-delete-v1"
    private let toastCenter: AppToastCenter
    private var activeUserID: String?
    private var activeAccessToken: String?
    private var deletedSavedRecipeIDs: Set<String> = []
    private var pendingRemoteDeleteRecipeIDs: Set<String> = []
    // Recipes saved locally this session that the server hasn't confirmed back yet.
    // Kept in-memory only (never persisted) so a freshly imported/saved card survives
    // refreshes that race ahead of the backend, while relaunches stay remote-authoritative.
    private var pendingRemoteSaveRecipeIDs: Set<String> = []
    private var hasPendingRemoteSaveRetry = false
    private var lastRemoteSyncUserID: String?
    private var lastRemoteSyncAt: Date?
    private let remoteSyncTTL: TimeInterval = 15 * 60
    private var authSessionProvider: (() async -> AuthSession?)?
    var onSavedRecipesChanged: ((String?, [DiscoverRecipeCardData]) -> Void)?

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

    func applyRuntimeSnapshot(_ snapshot: UserRuntimeSnapshot) {
        if activeUserID != snapshot.userID {
            activeUserID = snapshot.userID
            load(for: snapshot.userID, preserveExistingWhenMissing: true)
        }

        if snapshot.savedRecipes.isEmpty {
            // Snapshot carries no saved cards. If it still lists IDs the cards just
            // haven't hydrated yet; if it's fully empty but we already hold saves,
            // treat it as a partial snapshot and don't wipe the cookbook.
            if !snapshot.savedRecipeIDs.isEmpty || !savedRecipes.isEmpty {
                if savedRecipes.isEmpty {
                    isSyncingRemote = true
                }
                return
            }
        }

        let remoteRecipes = snapshot.savedRecipes.filter { !deletedSavedRecipeIDs.contains($0.id) }
        let mergedRecipes = merge(local: savedRecipes, remote: remoteRecipes)
        if mergedRecipes != savedRecipes {
            savedRecipes = mergedRecipes
            persist(notifyRuntime: false)
        }
        lastRemoteSyncUserID = snapshot.userID
        lastRemoteSyncAt = snapshot.updatedAt
    }

    func bootstrap(authSession: AuthSession?) async {
        let resolvedUserID = authSession?.userID

        if activeUserID != resolvedUserID {
            activeUserID = resolvedUserID
            load(for: resolvedUserID, preserveExistingWhenMissing: true)
        }
        activeAccessToken = authSession?.accessToken

        guard let authSession else {
            isSyncingRemote = false
            return
        }
        if shouldSkipRemoteSync(for: authSession.userID) {
            isSyncingRemote = false
            return
        }

        isSyncingRemote = true
        defer { isSyncingRemote = false }

        do {
            if !pendingRemoteDeleteRecipeIDs.isEmpty {
                await reconcilePendingDeletes(userID: authSession.userID)
            }

            let remoteRecipes = try await SupabaseSavedRecipesService.shared.fetchSavedRecipes(
                userID: authSession.userID,
                accessToken: authSession.accessToken
            )
            // A successful-but-empty fetch must not wipe a non-empty cookbook — it's
            // almost always a transient/partial read (the saved-recipes query has been
            // seen taking 8-12s). Genuine per-recipe unsaves are reconciled via
            // tombstones, not by an empty bulk result, so this stays deterministic.
            if remoteRecipes.isEmpty, !savedRecipes.isEmpty {
                hasPendingRemoteSaveRetry = true
            } else {
                let mergedRecipes = merge(local: savedRecipes, remote: remoteRecipes)
                if mergedRecipes != savedRecipes {
                    savedRecipes = mergedRecipes
                    persist()
                }
                markRemoteSyncComplete(for: authSession.userID)
            }
        } catch {
            // Keep local saves available even when network sync fails.
            hasPendingRemoteSaveRetry = true
        }
    }

    func refreshFromRemote(authSession: AuthSession?, force: Bool = false) async {
        guard let authSession else { return }

        if activeUserID != authSession.userID {
            activeUserID = authSession.userID
            load(for: authSession.userID, preserveExistingWhenMissing: true)
        }
        activeAccessToken = authSession.accessToken
        if !force, shouldSkipRemoteSync(for: authSession.userID) {
            return
        }

        isSyncingRemote = true
        defer { isSyncingRemote = false }

        do {
            if !pendingRemoteDeleteRecipeIDs.isEmpty {
                await reconcilePendingDeletes(userID: authSession.userID)
            }

            let remoteRecipes = try await SupabaseSavedRecipesService.shared.fetchSavedRecipes(
                userID: authSession.userID,
                accessToken: authSession.accessToken
            )
            // Don't let a transient empty read wipe a populated cookbook (see bootstrap()).
            if remoteRecipes.isEmpty, !savedRecipes.isEmpty {
                hasPendingRemoteSaveRetry = true
            } else {
                let filteredRemoteRecipes = remoteRecipes.filter { !deletedSavedRecipeIDs.contains($0.id) }
                savedRecipes = merge(local: savedRecipes, remote: filteredRemoteRecipes)
                persist()
                markRemoteSyncComplete(for: authSession.userID)
            }
        } catch {
            // Avoid immediately repeating the same failing remote read. The next
            // explicit or TTL-based sync will retry while local saves stay visible.
            hasPendingRemoteSaveRetry = true
        }
    }

    func toggle(_ recipe: DiscoverRecipeCardData) {
        let shouldSave = !isSaved(recipe)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()

        if shouldSave {
            deletedSavedRecipeIDs.remove(recipe.id)
            pendingRemoteDeleteRecipeIDs.remove(recipe.id)
            pendingRemoteSaveRecipeIDs.insert(recipe.id)
            savedRecipes.removeAll { $0.id == recipe.id }
            savedRecipes.insert(recipe, at: 0)
            toastCenter.showSavedRecipe(recipe)
        } else {
            savedRecipes.removeAll { $0.id == recipe.id }
            pendingRemoteSaveRecipeIDs.remove(recipe.id)
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
                        accessToken: remoteSession.accessToken ?? accessToken,
                        clearTombstones: true,
                        touchSavedAt: true
                    )
                    await SupabaseUserBootstrapService.shared.invalidateServerCache(
                        userID: remoteSession.userID,
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
                    await SupabaseUserBootstrapService.shared.invalidateServerCache(
                        userID: remoteSession.userID,
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
        let existingIndex = savedRecipes.firstIndex(where: { $0.id == recipe.id })
        let existing = existingIndex.map { savedRecipes[$0] }
        let resolved = mergeRecipeCards(primary: recipe, fallback: existing)
        deletedSavedRecipeIDs.remove(recipe.id)
        pendingRemoteDeleteRecipeIDs.remove(recipe.id)
        // Guard this freshly imported card against being dropped by a remote refresh
        // that races ahead of the backend write.
        pendingRemoteSaveRecipeIDs.insert(recipe.id)
        if let existingIndex {
            savedRecipes[existingIndex] = resolved
        } else {
            savedRecipes.insert(resolved, at: 0)
        }
        persist()

        if showToast {
            toastCenter.showSavedRecipe(resolved)
        }

        guard existing == nil else { return }
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
                await SupabaseUserBootstrapService.shared.invalidateServerCache(
                    userID: remoteSession.userID,
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
                    accessToken: remoteSession.accessToken ?? accessToken,
                    clearTombstones: true,
                    touchSavedAt: true
                )
                await SupabaseUserBootstrapService.shared.invalidateServerCache(
                    userID: remoteSession.userID,
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

    private func persist(notifyRuntime: Bool = true) {
        if let data = try? JSONEncoder().encode(savedRecipes) {
            UserDefaults.standard.set(data, forKey: storageKey(for: activeUserID))
        }
        if let deletedData = try? JSONEncoder().encode(Array(deletedSavedRecipeIDs)) {
            UserDefaults.standard.set(deletedData, forKey: deletedStorageKey(for: activeUserID))
        }
        if let pendingDeleteData = try? JSONEncoder().encode(Array(pendingRemoteDeleteRecipeIDs)) {
            UserDefaults.standard.set(pendingDeleteData, forKey: pendingDeleteStorageKey(for: activeUserID))
        }
        if notifyRuntime {
            onSavedRecipesChanged?(activeUserID, savedRecipes)
        }
    }

    private func load(for userID: String?, preserveExistingWhenMissing: Bool = false) {
        // load() runs only on a user switch (or first launch); pending-save guards are
        // session/user scoped, so clear them to avoid leaking across accounts.
        pendingRemoteSaveRecipeIDs.removeAll()
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
            deletedSavedRecipeIDs = loadDeletedRecipeIDs(from: deletedData)
            pendingRemoteDeleteRecipeIDs = loadDeletedRecipeIDs(from: pendingDeleteData)
            if preserveExistingWhenMissing,
               data == nil,
               !savedRecipes.isEmpty {
                savedRecipes = deduplicated(savedRecipes.filter { !deletedSavedRecipeIDs.contains($0.id) })
            } else {
                savedRecipes = []
            }
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
        let filteredRemote = remote.filter { !deletedSavedRecipeIDs.contains($0.id) }
        let filteredLocal = local.filter { !deletedSavedRecipeIDs.contains($0.id) }
        let remoteIDs = Set(filteredRemote.map(\.id))

        // A remote fetch is authoritative, so once a card shows up remotely it no
        // longer needs the pending-confirmation guard below.
        pendingRemoteSaveRecipeIDs.subtract(remoteIDs)

        // Remote saved rows are authoritative after bootstrap/refresh. Previously we
        // dropped every local row missing from remote, which deleted a recipe that was
        // JUST imported/saved whenever a refresh raced ahead of the server — it only
        // reappeared after an app relaunch. Keep local rows that remote already knows
        // about, plus recent local saves still awaiting remote confirmation. Tombstoned
        // (explicitly unsaved) recipes are already filtered out above, so this no longer
        // resurrects unsaved items.
        return deduplicated(filteredRemote + filteredLocal.filter { recipe in
            remoteIDs.contains(recipe.id) || pendingRemoteSaveRecipeIDs.contains(recipe.id)
        })
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
                await SupabaseUserBootstrapService.shared.invalidateServerCache(
                    userID: remoteSession.userID,
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
