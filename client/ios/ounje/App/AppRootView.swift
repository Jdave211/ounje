import SwiftUI
import Foundation
import UIKit
import AVKit
import PhotosUI
import AuthenticationServices
import CryptoKit
import Security
import MapKit
import UniformTypeIdentifiers
import WebKit
import SafariServices
import UserNotifications
import StoreKit
import DotLottie

typealias Color = SwiftUI.Color
typealias Alignment = SwiftUI.Alignment

struct OunjeAppScene: View {
    @StateObject private var store = MealPlanningAppStore()
    @StateObject private var toastCenter = AppToastCenter()
    @StateObject private var notificationCenter = AppNotificationCenterManager()
    @StateObject private var realtimeCoordinator = AppRealtimeInvalidationCoordinator()

    var body: some View {
        AppRootView()
            .environmentObject(store)
            .environmentObject(toastCenter)
            .environmentObject(notificationCenter)
            .environmentObject(realtimeCoordinator)
            .preferredColorScheme(.dark)
    }
}

struct AppRootView: View {
    var body: some View {
        RootView()
    }
}

struct RootView: View {
    @EnvironmentObject private var store: MealPlanningAppStore
    @EnvironmentObject private var toastCenter: AppToastCenter
    @EnvironmentObject private var notificationCenter: AppNotificationCenterManager
    @EnvironmentObject private var realtimeCoordinator: AppRealtimeInvalidationCoordinator
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if !store.isAuthenticated {
                AuthenticationView()
                    .id("auth-entry")
            } else if store.shouldHoldPlannerSplash || store.shouldShowBootstrapLoadingView {
                OunjeSplashLoaderView()
                .id(store.isCompletingOnboarding ? "onboarding-preparation" : "bootstrap-loading")
            } else if store.requiresProfileOnboarding {
                FirstLoginOnboardingView()
                    .id("profile-onboarding")
            } else {
                MealPlannerShellView(toastCenter: toastCenter)
                    .id("planner-shell")
            }
        }
        .overlay(alignment: .top) {
            StatusBarShield()
        }
        .task(id: store.authSession?.userID ?? "signed-out") {
            await store.bootstrapFromSupabaseIfNeeded()
            await store.refreshMembershipEntitlement(trigger: "root-bootstrap")
            let session = await store.refreshAuthSessionIfNeeded() ?? store.resolvedTrackingSession
            await notificationCenter.syncForCurrentSession(session, force: true)
        }
        .onChange(of: scenePhase) { newPhase in
            guard newPhase == .active else {
                realtimeCoordinator.disconnect()
                return
            }
            Task {
                await store.refreshMembershipEntitlement(trigger: "scene-active")
                let session = await store.refreshAuthSessionIfNeeded() ?? store.resolvedTrackingSession
                realtimeCoordinator.connect(session: session) { event in
                    await handleRealtimeInvalidation(event)
                }
                await store.refreshLiveTrackingState()
                await notificationCenter.syncForCurrentSession(session)
            }
        }
        .task(id: "\(store.authSession?.userID ?? "signed-out")::\(scenePhase == .active ? "active" : "inactive")::live-sync") {
            guard scenePhase == .active else {
                realtimeCoordinator.disconnect()
                return
            }
            let initialSession = await store.refreshAuthSessionIfNeeded() ?? store.resolvedTrackingSession
            realtimeCoordinator.connect(session: initialSession) { event in
                await handleRealtimeInvalidation(event)
            }
            while !Task.isCancelled {
                let session = await store.refreshAuthSessionIfNeeded() ?? store.resolvedTrackingSession
                realtimeCoordinator.connect(session: session) { event in
                    await handleRealtimeInvalidation(event)
                }
                if store.hasLiveInstacartActivity {
                    await store.refreshLiveTrackingState()
                }
                await notificationCenter.syncForCurrentSession(session)
                let sleepInterval: UInt64 = realtimeCoordinator.isRunning
                    ? (store.hasLiveInstacartActivity ? 15_000_000_000 : 90_000_000_000)
                    : (store.hasLiveInstacartActivity ? 8_000_000_000 : 30_000_000_000)
                try? await Task.sleep(nanoseconds: sleepInterval)
            }
        }
    }

    @MainActor
    private func handleRealtimeInvalidation(_ event: AppRealtimeInvalidationEvent) async {
        switch event.name {
        case "recipe_import.updated", "recipe_import.completed", "recipe_import.failed":
            NotificationCenter.default.post(name: .recipeImportHistoryNeedsRefresh, object: event)

        case "instacart_run.updated", "grocery_order.updated":
            await store.refreshRealtimeTrackingState(
                runID: event.string("run_id"),
                groceryOrderID: event.uuid("grocery_order_id")
            )

        case "main_shop_snapshot.updated", "meal_prep_cycle.updated":
            await store.refreshRealtimeMealPrepState(trigger: event.name)

        case "prep.updated":
            if event.string("table") == "prep_recurring_recipes" {
                await store.refreshRealtimeRecurringPrepRecipes(trigger: event.name)
            } else {
                await store.refreshRealtimeMealPrepState(trigger: event.name)
            }

        case "notification.updated":
            let session = await store.refreshAuthSessionIfNeeded() ?? store.resolvedTrackingSession
            await notificationCenter.syncForCurrentSession(session, force: true)

        case "entitlement.updated":
            await store.refreshMembershipEntitlement(trigger: "realtime")

        default:
            break
        }
    }
}

private struct OunjeSplashLoaderView: View {
    private let animation = DotLottieAnimation(
        fileName: "run_forrest_run_white",
        config: AnimationConfig(
            autoplay: true,
            loop: true,
            speed: 1.0,
            useFrameInterpolation: true
        )
    )

    var body: some View {
        ZStack {
            OunjePalette.background
                .ignoresSafeArea()

            VStack(spacing: 20) {
                Spacer(minLength: 0)

                DotLottiePlayerView(animation: animation)
                    .looping()
                    .frame(width: 190, height: 190)
                    .accessibilityHidden(true)

                Text("Getting Things Ready.")
                    .font(.system(size: 19, weight: .bold, design: .rounded))
                    .foregroundStyle(OunjePalette.primaryText)
                    .multilineTextAlignment(.center)
                    .tracking(0.2)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 40)
        }
    }
}

private struct OunjeSplashLoaderFallbackView: View {
    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
                .tint(Color.white)
                .scaleEffect(1.08)
                .accessibilityHidden(true)

            Text("Getting Things Ready.")
                .font(.system(size: 19, weight: .bold, design: .rounded))
                .foregroundStyle(OunjePalette.primaryText)
        }
    }
}

@MainActor
final class AppNotificationCenterManager: ObservableObject {
    @Published private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined
    @Published private(set) var inboxEvents: [AppNotificationEvent] = []

    private let notificationCenter = UNUserNotificationCenter.current()
    private var isSyncing = false
    private var lastSyncedUserID: String?
    private var lastSyncedAt: Date?
    private var lastTrackingAuthFailureAt: Date?
    private var lastTrackingAuthFailureUserID: String?
    private let passiveSyncInterval: TimeInterval = 5 * 60

    func syncForCurrentSession(_ session: AuthSession?, force: Bool = false) async {
        guard let session,
              !session.userID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return
        }

        if !force,
           lastSyncedUserID == session.userID,
           let lastSyncedAt,
           Date().timeIntervalSince(lastSyncedAt) < passiveSyncInterval {
            return
        }

        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }

        await refreshInbox(for: session)
        await refreshAuthorizationStatus()
        if authorizationStatus == .notDetermined {
            await requestAuthorizationIfNeeded()
        }

        guard authorizationStatus == .authorized || authorizationStatus == .provisional else {
            return
        }

        do {
            if let accessToken = session.accessToken?.trimmingCharacters(in: .whitespacesAndNewlines),
               !accessToken.isEmpty,
               !shouldBackoffTracking(for: session.userID),
               let latestOrder = try? await GroceryOrderAPIService.shared.fetchLatestOrder(
                userID: session.userID,
                accessToken: accessToken
            ),
               latestOrder.needsTrackingRefresh {
                do {
                    try await GroceryOrderAPIService.shared.trackOrder(
                        orderID: latestOrder.id,
                        userID: session.userID,
                        accessToken: accessToken
                    )
                    lastTrackingAuthFailureUserID = nil
                    lastTrackingAuthFailureAt = nil
                } catch {
                    if isTrackingAuthorizationFailure(error) {
                        lastTrackingAuthFailureUserID = session.userID
                        lastTrackingAuthFailureAt = Date()
                    }
                }
            }

            let pendingEvents = try await SupabaseAppNotificationEventService.shared.fetchPendingEvents(
                userID: session.userID,
                accessToken: session.accessToken,
                limit: 40
            )
            if !pendingEvents.isEmpty {
                if authorizationStatus == .authorized || authorizationStatus == .provisional {
                    for event in pendingEvents {
                        try await scheduleNotificationIfNeeded(event)
                    }
                }

                try await SupabaseAppNotificationEventService.shared.markDelivered(
                    eventIDs: pendingEvents.map(\.id),
                    userID: session.userID,
                    accessToken: session.accessToken
                )
            }

            await refreshInbox(for: session)
            lastSyncedUserID = session.userID
            lastSyncedAt = Date()
        } catch {
            lastSyncedUserID = session.userID
            lastSyncedAt = Date()
        }
    }

    func refreshInbox(for session: AuthSession?) async {
        guard let session,
              !session.userID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            inboxEvents = []
            return
        }

        do {
            inboxEvents = try await SupabaseAppNotificationEventService.shared.fetchRecentEvents(
                userID: session.userID,
                accessToken: session.accessToken,
                limit: 60
            )
        } catch {
            inboxEvents = []
        }
    }

    var unreadCount: Int {
        inboxEvents.reduce(into: 0) { count, event in
            if event.seenAt == nil { count += 1 }
        }
    }

    func markInboxEventsSeen(_ eventIDs: [UUID], session: AuthSession?) async {
        guard let session,
              !session.userID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !eventIDs.isEmpty
        else {
            return
        }

        do {
            try await SupabaseAppNotificationEventService.shared.markSeen(
                eventIDs: eventIDs,
                userID: session.userID,
                accessToken: session.accessToken
            )
            await refreshInbox(for: session)
        } catch {
            // Keep the inbox list even if seen state fails to save.
        }
    }

    private func requestAuthorizationIfNeeded() async {
        do {
            let granted = try await notificationCenter.requestAuthorization(options: [.alert, .sound, .badge])
            authorizationStatus = granted ? .authorized : .denied
        } catch {
            authorizationStatus = .denied
        }
    }

    private func refreshAuthorizationStatus() async {
        let settings = await notificationCenter.notificationSettings()
        authorizationStatus = settings.authorizationStatus
    }

    private func scheduleNotificationIfNeeded(_ event: AppNotificationEvent) async throws {
        let identifier = "app-notification-\(event.id.uuidString)"
        let pending = await notificationCenter.pendingNotificationRequests()
        if pending.contains(where: { $0.identifier == identifier }) {
            return
        }

        let content = UNMutableNotificationContent()
        content.title = event.title
        content.body = event.body
        if let subtitle = event.subtitle, !subtitle.isEmpty {
            content.subtitle = subtitle
        }
        content.sound = .default
        content.userInfo = [
            "eventID": event.id.uuidString,
            "kind": event.kind,
            "actionURL": event.actionURLString ?? "",
            "orderID": event.orderID?.uuidString ?? "",
        ]

        let interval = max(1, event.scheduledFor.timeIntervalSinceNow)
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
        try await notificationCenter.add(request)
    }

    private func shouldBackoffTracking(for userID: String) -> Bool {
        guard lastTrackingAuthFailureUserID == userID,
              let lastTrackingAuthFailureAt
        else {
            return false
        }
        return Date().timeIntervalSince(lastTrackingAuthFailureAt) < 15 * 60
    }

    private func isTrackingAuthorizationFailure(_ error: Error) -> Bool {
        let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return message.contains("authorization")
            || message.contains("jwt")
            || message.contains("token is expired")
            || message.contains("401")
            || message.contains("userauthenticationrequired")
    }
}

@MainActor
private final class SharedRecipeImportInboxStore: ObservableObject {
    @Published private(set) var envelopes: [SharedRecipeImportEnvelope] = []

    var badgeCount: Int {
        envelopes.count
    }

    var failedCount: Int {
        envelopes.filter(\.isRetryNeeded).count
    }

    var queuedCount: Int {
        envelopes.filter(\.isLiveQueueState).count
    }

    func refresh() async {
        try? SharedRecipeImportInbox.reconcileStaleProcessingEnvelopes()
        envelopes = (try? SharedRecipeImportInbox.readAll()) ?? []
    }

    func envelope(withID envelopeID: String) -> SharedRecipeImportEnvelope? {
        envelopes.first(where: { $0.id == envelopeID })
    }

    func reconcileCompletedImports(
        _ completedItems: [RecipeImportCompletedItem],
        onCompletedPreppedImport: ((RecipeImportResponse) async -> Void)? = nil
    ) async {
        let currentEnvelopes = (try? SharedRecipeImportInbox.readAll()) ?? []
        guard !currentEnvelopes.isEmpty else {
            envelopes = []
            return
        }

        let matchedIDs: [String] = completedItems.isEmpty
            ? []
            : currentEnvelopes
                .filter { envelope in
                    guard !envelope.isPinnedTypedImport else { return false }
                    guard envelope.targetState != "prepped" else { return false }
                    return completedItems.contains(where: { $0.matches(envelope: envelope) })
                }
                .map(\.id)

        if !matchedIDs.isEmpty {
            matchedIDs.forEach { envelopeID in
                try? SharedRecipeImportInbox.delete(envelopeID: envelopeID)
            }
        }

        let remainingEnvelopes = currentEnvelopes.filter { envelope in
            !matchedIDs.contains(envelope.id)
        }

        for envelope in remainingEnvelopes where !envelope.isPinnedTypedImport {
            guard let jobID = envelope.jobID?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !jobID.isEmpty else {
                continue
            }

            do {
                let response = try await RecipeImportAPIService.shared.fetchImportJob(jobID: jobID)
                let backendProcessingState = response.job.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let normalizedCanonicalURL = [
                    response.recipeDetail?.originalRecipeURLString,
                    response.recipeDetail?.recipeURLString,
                    response.job.sourceURL
                ]
                .compactMap { raw -> String? in
                    let trimmed = raw?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines) ?? ""
                    return trimmed.isEmpty ? nil : trimmed
                }
                .first
                let isTerminalServerState = ["saved", "needs_review", "draft"].contains(backendProcessingState)

                if isTerminalServerState || response.recipe != nil {
                    if envelope.targetState == "prepped", response.recipeDetail != nil {
                        await onCompletedPreppedImport?(response)
                    }
                    try? SharedRecipeImportInbox.delete(envelopeID: envelope.id)
                    continue
                }

                let healedEnvelope = SharedRecipeImportEnvelope(
                    id: envelope.id,
                    createdAt: envelope.createdAt,
                    jobID: response.job.id,
                    targetState: envelope.targetState,
                    sourceText: envelope.sourceText,
                    sourceURLString: envelope.sourceURLString,
                    canonicalSourceURLString: normalizedCanonicalURL,
                    sourceApp: envelope.sourceApp,
                    attachments: envelope.attachments,
                    processingState: backendProcessingState.isEmpty ? envelope.normalizedProcessingState : backendProcessingState,
                    attemptCount: envelope.attemptCount,
                    lastAttemptAt: envelope.lastAttemptAt,
                    lastError: response.job.errorMessage ?? envelope.lastError,
                    updatedAt: Date()
                )
                try? SharedRecipeImportInbox.update(healedEnvelope)
            } catch {
                continue
            }
        }

        await refresh()
    }
}

@MainActor
private final class RecipeImportHistoryStore: ObservableObject {
    @Published private(set) var completedItems: [RecipeImportCompletedItem] = []
    private var lastRefreshUserID: String?
    private var lastRefreshAt: Date?
    private let passiveRefreshTTL: TimeInterval = 45

    var badgeCount: Int {
        completedItems.count
    }

    var completedCount: Int {
        completedItems.count
    }

    func refresh(userID: String?, force: Bool = false) async {
        guard let userID, !userID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            completedItems = []
            lastRefreshUserID = nil
            lastRefreshAt = nil
            return
        }
        if !force,
           lastRefreshUserID == userID,
           let lastRefreshAt,
           Date().timeIntervalSince(lastRefreshAt) < passiveRefreshTTL {
            return
        }
        completedItems = (try? await RecipeImportAPIService.shared.fetchCompletedImports(userID: userID)) ?? []
        lastRefreshUserID = userID
        lastRefreshAt = .now
    }
}

private extension RecipeImportCompletedItem {
    var looksLikeAIEdit: Bool {
        [
            sourceType,
            source,
            Optional(title),
            sourceText
        ]
        .compactMap { $0?.lowercased() }
        .contains { value in
            value.contains("adaptation")
                || value.contains("ai edit")
                || value.contains("ask ounje")
                || value.contains("onboarding-demo")
        }
    }
}

private extension DiscoverRecipeCardData {
    var looksLikeAIEdit: Bool {
        [
            source,
            category,
            recipeType,
            Optional(title)
        ]
        .compactMap { $0?.lowercased() }
        .contains { value in
            value.contains("adaptation")
                || value.contains("ai edit")
                || value.contains("ask ounje")
                || value.contains("onboarding-demo")
        }
    }
}

@MainActor
final class InstacartRunLogsStore: ObservableObject {
    private static let cacheVersion = 3

    @Published private(set) var runs: [InstacartRunLogSummary] = []
    @Published private(set) var totalCount: Int = 0
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingMore = false
    @Published private(set) var hasMore = false
    @Published private(set) var errorMessage: String?

    private var currentUserID: String?
    private var currentAccessToken: String?
    private var currentQuery = ""
    private var currentStatus = "all"
    private var currentOffset = 0
    private var lastRefreshSignature: String?
    private var lastRefreshAt: Date?

    private func cacheKey(for userID: String?, status: String, query: String) -> String? {
        let normalized = userID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !normalized.isEmpty else { return nil }
        let normalizedStatus = status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return "instacart.runLogs.cache.v\(Self.cacheVersion).\(normalized).\(normalizedStatus).\(normalizedQuery)"
    }

    private func loadCachedRuns(for userID: String?, status: String, query: String) {
        guard let key = cacheKey(for: userID, status: status, query: query),
              let data = UserDefaults.standard.data(forKey: key) else {
            return
        }
        guard let cached = try? JSONDecoder().decode(InstacartRunLogsListResponse.self, from: data) else {
            return
        }
        runs = cached.items
        totalCount = cached.total
        hasMore = cached.hasMore
    }

    private func persistCachedRuns(_ payload: InstacartRunLogsListResponse, for userID: String?, status: String, query: String) {
        guard let key = cacheKey(for: userID, status: status, query: query),
              let data = try? JSONEncoder().encode(payload) else {
            return
        }
        UserDefaults.standard.set(data, forKey: key)
    }

    func applyRunSummary(_ summary: InstacartRunLogSummary) {
        if let existingIndex = runs.firstIndex(where: { $0.runId == summary.runId }) {
            runs[existingIndex] = summary
        } else {
            runs.insert(summary, at: 0)
            totalCount = max(totalCount + 1, runs.count)
        }
        hasMore = totalCount > runs.count
        let payload = InstacartRunLogsListResponse(
            items: runs,
            total: max(totalCount, runs.count),
            offset: 0,
            limit: max(20, runs.count),
            hasMore: hasMore,
            query: currentQuery,
            status: currentStatus,
            userID: currentUserID
        )
        persistCachedRuns(payload, for: currentUserID, status: currentStatus, query: currentQuery)
    }

    func refresh(userID: String?, accessToken: String?, query: String = "", status: String = "all") async {
        currentUserID = userID?.trimmingCharacters(in: .whitespacesAndNewlines)
        currentAccessToken = accessToken?.trimmingCharacters(in: .whitespacesAndNewlines)
        currentQuery = query
        currentStatus = status
        currentOffset = 0

        let refreshSignature = [
            currentUserID ?? "",
            currentQuery.trimmingCharacters(in: .whitespacesAndNewlines),
            currentStatus.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        ]
        .joined(separator: "::")

        if runs.isEmpty {
            loadCachedRuns(for: currentUserID, status: currentStatus, query: currentQuery)
        }

        if let lastRefreshSignature,
           lastRefreshSignature == refreshSignature,
           let lastRefreshAt,
           Date().timeIntervalSince(lastRefreshAt) < 12,
           !runs.isEmpty {
            return
        }

        lastRefreshSignature = refreshSignature
        lastRefreshAt = .now

        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let payload = try await InstacartRunLogAPIService.shared.fetchRuns(
                userID: currentUserID,
                accessToken: currentAccessToken,
                query: currentQuery,
                status: currentStatus,
                limit: 20,
                offset: currentOffset,
                includeCount: true
            )
            runs = payload.items
            totalCount = payload.total
            hasMore = payload.hasMore
            persistCachedRuns(payload, for: currentUserID, status: currentStatus, query: currentQuery)
        } catch is CancellationError {
            return
        } catch {
            if runs.isEmpty {
                errorMessage = error.localizedDescription
                totalCount = 0
                hasMore = false
            } else {
                errorMessage = nil
            }
        }
    }

    func loadMore() async {
        guard hasMore, !isLoading, !isLoadingMore else { return }

        isLoadingMore = true
        defer { isLoadingMore = false }

        do {
            let nextOffset = runs.count
            let payload = try await InstacartRunLogAPIService.shared.fetchRuns(
                userID: currentUserID,
                accessToken: currentAccessToken,
                query: currentQuery,
                status: currentStatus,
                limit: 20,
                offset: nextOffset,
                includeCount: true
            )
            currentOffset = nextOffset
            runs.append(contentsOf: payload.items)
            totalCount = payload.total
            hasMore = payload.hasMore
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func markWaitingForAuthentication() {
        runs = []
        totalCount = 0
        hasMore = false
        errorMessage = "Waiting for your account to finish loading."
    }
}

private struct RemoteStateBootstrapView: View {
    var body: some View {
        ZStack {
            Color.black
            .ignoresSafeArea()

            Circle()
                .fill(OunjePalette.accent.opacity(0.16))
                .frame(width: 180, height: 180)
                .blur(radius: 42)
                .offset(x: 96, y: -48)

            VStack(spacing: 14) {
                Text("ounje")
                    .font(.custom("Slee_handwritting-Regular", size: 52))
                    .tracking(0.2)
                    .foregroundStyle(OunjePalette.accent)

                Text("Getting your kitchen ready")
                    .font(.system(size: 15, weight: .medium, design: .rounded))
                    .foregroundStyle(OunjePalette.softCream.opacity(0.78))
            }
            .padding(.horizontal, 28)
        }
    }
}

private struct AuthenticationView: View {
    @EnvironmentObject private var store: MealPlanningAppStore

    @State private var authErrorMessage: String?
    @State private var authStatusMessage: String?
    @State private var appleSignInNonce = ""
    @State private var revealContent = false
    @State private var showQuickTour = false
    @StateObject private var appleSignInDriver = AppleSignInPresentationDriver()

    var body: some View {
        ZStack {
            WelcomeVideoBackgroundView()
                .ignoresSafeArea()

            LinearGradient(
                colors: [
                    .black.opacity(0.0),
                    .black.opacity(0.04),
                    .black.opacity(0.12),
                    .black.opacity(0.3),
                    .black.opacity(0.58)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            GeometryReader { proxy in
                let contentWidth = max(1, min(392, proxy.size.width - 36))
                let authButtonWidth = max(1, min(340, proxy.size.width - 56))
                let logoTopSpacing = max(148, min(proxy.size.height * 0.22, 190))
                let bottomSpacing = max(28, proxy.safeAreaInsets.bottom + 22)

                ZStack {
                    VStack(spacing: 10) {
                            Text("ounje")
                                .font(.custom("Slee_handwritting-Regular", size: min(62, proxy.size.width * 0.148)))
                                .tracking(0.16)
                                .foregroundStyle(.white)

                            Text("Your taste, on autopilot")
                                .font(.system(size: 15, weight: .semibold, design: .rounded))
                                .foregroundStyle(OunjePalette.softCream.opacity(0.8))
                        }
                        .frame(maxWidth: contentWidth)
                        .padding(.horizontal, 28)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .padding(.top, logoTopSpacing)

                    VStack(alignment: .center, spacing: 14) {
                            if let authStatusMessage {
                                Text(authStatusMessage)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(.white.opacity(0.92))
                                    .frame(maxWidth: .infinity, alignment: .center)
                                    .padding(.bottom, 4)
                            }

                            Button {
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                showQuickTour = true
                            } label: {
                                Text("Take a quick tour")
                                    .font(.system(size: 17, weight: .semibold))
                                    .foregroundStyle(.black.opacity(0.9))
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.plain)
                            .frame(height: 48)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(Color.white.opacity(0.94))
                            )

                            SignInWithAppleButton(.signIn) { request in
                                prepareAppleSignInRequest(request)
                            } onCompletion: { result in
                                handleAppleSignIn(result)
                            }
                            .signInWithAppleButtonStyle(.black)
                            .frame(height: 48)
                            .clipShape(Capsule(style: .continuous))
                    }
                    .frame(width: authButtonWidth)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, bottomSpacing)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .opacity(revealContent ? 1 : 0)
            .offset(y: revealContent ? 0 : 18)
        }
        .alert("Sign-in failed", isPresented: Binding(
            get: { authErrorMessage != nil },
            set: { if !$0 { authErrorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(authErrorMessage ?? "Please try again.")
        }
        .onAppear {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.82)) {
                revealContent = true
            }
        }
        .fullScreenCover(isPresented: $showQuickTour) {
            WelcomeQuickTourView(
                onClose: {
                    showQuickTour = false
                },
                onAppleRequest: { request in
                    prepareAppleSignInRequest(request)
                },
                onAppleCompletion: { result in
                    handleAppleSignIn(result)
                },
                onAppleSignInRequested: {
                    startAppleSignIn()
                }
            )
        }
    }

    private func startAppleSignIn() {
        appleSignInDriver.start(
            configure: { request in
                prepareAppleSignInRequest(request)
            },
            completion: { result in
                handleAppleSignIn(result)
            }
        )
    }

    private func prepareAppleSignInRequest(_ request: ASAuthorizationAppleIDRequest) {
        request.requestedScopes = [.fullName, .email]
        let nonce = randomNonceString()
        appleSignInNonce = nonce
        request.nonce = sha256(nonce)
    }

    private func handleAppleSignIn(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .success(let authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else {
                authErrorMessage = "Could not read Apple account credentials."
                return
            }
            guard let identityTokenData = credential.identityToken,
                  let identityToken = String(data: identityTokenData, encoding: .utf8),
                  !identityToken.isEmpty else {
                authErrorMessage = "Apple sign-in did not return a valid identity token."
                return
            }
            guard !appleSignInNonce.isEmpty else {
                authErrorMessage = "Apple sign-in nonce was missing. Please try again."
                return
            }

            Task { @MainActor in
                do {
                    let formatter = PersonNameComponentsFormatter()
                    let fallbackName = credential.fullName
                        .map { formatter.string(from: $0).trimmingCharacters(in: .whitespacesAndNewlines) }
                        .flatMap { $0.isEmpty ? nil : $0 }

                    let authResult = try await SupabaseAppleAuthService.shared.signInWithApple(
                        idToken: identityToken,
                        rawNonce: appleSignInNonce
                    )

                    let session = AuthSession(
                        provider: .apple,
                        userID: authResult.userID,
                        email: authResult.email ?? credential.email,
                        displayName: authResult.displayName ?? fallbackName,
                        signedInAt: Date(),
                        accessToken: authResult.accessToken,
                        refreshToken: authResult.refreshToken
                    )
                    await completeSignIn(with: session)
                } catch {
                    let message = error.localizedDescription.lowercased()
                    let nsError = error as NSError
                    let providerDisabled = message.contains("appleid.apple.com") && message.contains("not enabled")
                    let hostLookupFailure = nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCannotFindHost
                    let networkUnavailable = nsError.domain == NSURLErrorDomain && (
                        nsError.code == NSURLErrorNotConnectedToInternet ||
                        nsError.code == NSURLErrorNetworkConnectionLost ||
                        nsError.code == NSURLErrorTimedOut
                    )

                    if (providerDisabled || hostLookupFailure || networkUnavailable) && allowsLocalOnlyAuthFallback {
                        let localSession = localSessionFromAppleCredential(credential)
                        await completeSignIn(
                            with: localSession,
                            fallbackStatusMessage: providerDisabled
                                ? "Apple auth provider is disabled in Supabase. Signed in locally."
                                : "Supabase auth is unreachable right now. Signed in locally."
                        )
                    } else {
                        authErrorMessage = error.localizedDescription
                    }
                }
            }
        case .failure(let error):
            if let authError = error as? ASAuthorizationError, authError.code == .canceled {
                return
            }
            authErrorMessage = error.localizedDescription
        }
    }

    private func localSessionFromAppleCredential(_ credential: ASAuthorizationAppleIDCredential) -> AuthSession {
        let formatter = PersonNameComponentsFormatter()
        let fallbackName = credential.fullName
            .map { formatter.string(from: $0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 }

        return AuthSession(
            provider: .apple,
            userID: credential.user,
            email: credential.email,
            displayName: fallbackName,
            signedInAt: Date(),
            accessToken: nil,
            refreshToken: nil
        )
    }

    private var allowsLocalOnlyAuthFallback: Bool {
#if targetEnvironment(simulator)
        return true
#else
        return ProcessInfo.processInfo.environment["OUNJE_ALLOW_LOCAL_AUTH_FALLBACK"] == "1"
#endif
    }

    private func completeSignIn(with session: AuthSession, fallbackStatusMessage: String? = nil) async {
        let isSameCachedUser = store.authSession?.userID == session.userID || store.resolvedTrackingSession?.userID == session.userID
        let cachedProfile = isSameCachedUser ? store.profile : nil
        let cachedCompleted = isSameCachedUser && store.isOnboarded && cachedProfile != nil
        let initialStep = cachedCompleted
            ? FirstLoginOnboardingView.SetupStep.completedRawValue
            : (isSameCachedUser ? store.lastOnboardingStep : 0)

        store.signIn(
            with: session,
            onboarded: cachedCompleted,
            profile: cachedProfile,
            lastOnboardingStep: initialStep
        )
        showQuickTour = false
        authStatusMessage = cachedCompleted
            ? "Signed in with \(session.provider.title)."
            : "Signed in. Let's finish setup."

        do {
            let remoteState = try await SupabaseProfileStateService.shared.fetchOrCreateProfileState(
                userID: session.userID,
                email: session.email,
                displayName: session.displayName,
                authProvider: session.provider,
                accessToken: session.accessToken
            )
            if remoteState.isDeactivated {
                store.signOutToWelcome()
                authErrorMessage = "This account is deactivated. Email thisisounje@gmail.com for help."
                return
            }

            let persistedOnboarded = remoteState.onboarded || cachedCompleted
            let resolvedOnboarded = OunjeLaunchFlags.forceOnboardingIncomplete ? false : persistedOnboarded
            let resolvedProfile = remoteState.profile ?? cachedProfile
            let resolvedStep = OunjeLaunchFlags.forceOnboardingIncomplete
                ? 0
                : (
                    persistedOnboarded
                        ? FirstLoginOnboardingView.SetupStep.latestStoredRawValue(
                            remoteState.lastOnboardingStep,
                            FirstLoginOnboardingView.SetupStep.completedRawValue
                        )
                        : FirstLoginOnboardingView.SetupStep.latestStoredRawValue(
                            remoteState.lastOnboardingStep,
                            isSameCachedUser ? store.lastOnboardingStep : 0
                        )
                )

            store.signIn(
                with: session,
                onboarded: resolvedOnboarded,
                profile: resolvedProfile,
                lastOnboardingStep: resolvedStep
            )

            if !OunjeLaunchFlags.forceOnboardingIncomplete &&
                (persistedOnboarded != remoteState.onboarded ||
                resolvedProfile != nil && remoteState.profile == nil ||
                resolvedStep != remoteState.lastOnboardingStep ||
                remoteState.authProvider != session.provider),
               let resolvedProfile {
                try? await SupabaseProfileStateService.shared.upsertProfile(
                    userID: session.userID,
                    email: session.email,
                    displayName: resolvedProfile.trimmedPreferredName ?? session.displayName,
                    authProvider: session.provider,
                    onboarded: persistedOnboarded,
                    lastOnboardingStep: resolvedStep,
                    profile: resolvedProfile,
                    accessToken: session.accessToken
                )
            } else if !OunjeLaunchFlags.forceOnboardingIncomplete &&
                        !persistedOnboarded &&
                        resolvedStep != remoteState.lastOnboardingStep {
                try? await SupabaseProfileStateService.shared.upsertProfile(
                    userID: session.userID,
                    email: session.email,
                    displayName: resolvedProfile?.trimmedPreferredName ?? session.displayName,
                    authProvider: session.provider,
                    onboarded: false,
                    lastOnboardingStep: resolvedStep,
                    profile: resolvedProfile,
                    accessToken: session.accessToken
                )
            }

            authStatusMessage = resolvedOnboarded
                ? "Signed in with \(session.provider.title)."
                : "Signed in. Let's finish setup."
        } catch {
            if let fallbackStatusMessage {
                authStatusMessage = fallbackStatusMessage
            } else {
                authStatusMessage = "Signed in. We’ll keep syncing in the background."
            }
        }
    }

    private func randomNonceString(length: Int = 32) -> String {
        precondition(length > 0)
        let charset: [Character] = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        var result = ""
        result.reserveCapacity(length)

        while result.count < length {
            var random: UInt8 = 0
            let status = SecRandomCopyBytes(kSecRandomDefault, 1, &random)
            if status == errSecSuccess {
                if random < charset.count {
                    result.append(charset[Int(random)])
                }
            }
        }

        return result
    }

    private func sha256(_ input: String) -> String {
        let digest = SHA256.hash(data: Data(input.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

}

@MainActor
private final class AppleSignInPresentationDriver: NSObject, ObservableObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    private var completion: ((Result<ASAuthorization, Error>) -> Void)?
    private var isPresenting = false

    func start(
        configure: (ASAuthorizationAppleIDRequest) -> Void,
        completion: @escaping (Result<ASAuthorization, Error>) -> Void
    ) {
        guard !isPresenting else { return }

        let request = ASAuthorizationAppleIDProvider().createRequest()
        configure(request)

        self.completion = completion
        isPresenting = true

        let controller = ASAuthorizationController(authorizationRequests: [request])
        controller.delegate = self
        controller.presentationContextProvider = self
        controller.performRequests()
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        finish(.success(authorization))
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        finish(.failure(error))
    }

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow) ?? UIWindow()
    }

    private func finish(_ result: Result<ASAuthorization, Error>) {
        let completion = completion
        self.completion = nil
        isPresenting = false
        completion?(result)
    }
}

private struct WelcomeVideoBackgroundView: View {
    @StateObject private var videoPlayer = WelcomeLoopingVideoPlayer(
        resourceName: "welcome-vid-bg",
        fileExtension: "mp4"
    )

    var body: some View {
        WelcomeVideoPlayerRepresentable(player: videoPlayer.player)
            .brightness(0.055)
            .onAppear {
                videoPlayer.start()
            }
            .onDisappear {
                videoPlayer.pause()
            }
    }
}

@MainActor
private final class WelcomeLoopingVideoPlayer: ObservableObject {
    let player = AVPlayer()

    private let resourceName: String
    private let fileExtension: String
    private var endObserver: NSObjectProtocol?
    private var interruptionObserver: NSObjectProtocol?

    init(resourceName: String, fileExtension: String) {
        self.resourceName = resourceName
        self.fileExtension = fileExtension
        player.volume = 0
        player.isMuted = true
        player.actionAtItemEnd = .none
        player.allowsExternalPlayback = false
        player.preventsDisplaySleepDuringVideoPlayback = false
    }

    func start() {
        configureNonInterruptingAudioSession()

        if player.currentItem == nil,
           let url = Bundle.main.url(forResource: resourceName, withExtension: fileExtension) {
            let asset = AVURLAsset(url: url)
            let item = AVPlayerItem(asset: asset)
            applySilentAudioMix(to: item, asset: asset)
            player.replaceCurrentItem(with: item)
            endObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: item,
                queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                self.player.seek(to: .zero)
                self.player.play()
            }
            interruptionObserver = NotificationCenter.default.addObserver(
                forName: AVAudioSession.interruptionNotification,
                object: AVAudioSession.sharedInstance(),
                queue: .main
            ) { [weak self] _ in
                self?.player.play()
            }
        }

        player.play()
    }

    func pause() {
        player.pause()
    }

    deinit {
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
        }
    }

    private func configureNonInterruptingAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(
                .ambient,
                mode: .default,
                options: [.mixWithOthers]
            )
        } catch {
            print("[WelcomeVideo] Failed to configure non-interrupting audio session:", error.localizedDescription)
        }
    }

    private func applySilentAudioMix(to item: AVPlayerItem, asset: AVAsset) {
        Task { @MainActor in
            let audioTracks = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
            guard !audioTracks.isEmpty else { return }

            let parameters = audioTracks.map { track in
                let input = AVMutableAudioMixInputParameters(track: track)
                input.setVolume(0, at: .zero)
                return input
            }
            let mix = AVMutableAudioMix()
            mix.inputParameters = parameters
            item.audioMix = mix
        }
    }
}

private struct WelcomeVideoPlayerRepresentable: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> WelcomeVideoPlayerView {
        let view = WelcomeVideoPlayerView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspectFill
        view.backgroundColor = .clear
        view.isOpaque = false
        return view
    }

    func updateUIView(_ uiView: WelcomeVideoPlayerView, context: Context) {
        uiView.playerLayer.player = player
        uiView.playerLayer.videoGravity = .resizeAspectFill
    }
}

private final class WelcomeVideoPlayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }

    var playerLayer: AVPlayerLayer {
        layer as! AVPlayerLayer
    }
}

private struct WelcomeQuickTourView: View {
    @Environment(\.dismiss) private var dismiss

    let onClose: () -> Void
    let onAppleRequest: (ASAuthorizationAppleIDRequest) -> Void
    let onAppleCompletion: (Result<ASAuthorization, Error>) -> Void
    let onAppleSignInRequested: () -> Void

    private let pages = WelcomeQuickTourPage.orderedPages

    @State private var selectedPage = 0
    @State private var cardEntered = false
    @State private var isHandlingLastPageSwipe = false

    var body: some View {
        GeometryReader { proxy in
            let topVisualHeight = min(proxy.size.height * 0.71, 640)
            let tourBackground = Color(red: 0.085, green: 0.085, blue: 0.082)

            ZStack {
                tourBackground
                    .ignoresSafeArea()

                TabView(selection: $selectedPage) {
                    ForEach(Array(pages.enumerated()), id: \.offset) { index, page in
                        VStack(spacing: 0) {
                                ZStack(alignment: .bottom) {
                                    Image(page.assetName)
                                        .resizable()
                                        .scaledToFill()
                                        .frame(width: proxy.size.width, height: topVisualHeight)
                                        .clipped()

                                    LinearGradient(
                                        colors: [
                                            tourBackground.opacity(0),
                                            tourBackground.opacity(0.62),
                                            tourBackground
                                        ],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    )
                                    .frame(height: 150)
                                }
                                .offset(y: cardEntered ? 0 : -180)
                                .opacity(cardEntered ? 1 : 0)

                            VStack(spacing: 8) {
                                Text(page.title)
                                    .font(.system(size: 20, weight: .semibold))
                                    .foregroundStyle(.white.opacity(0.96))
                                    .multilineTextAlignment(.center)

                                Text(page.subtitle)
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.58))
                                    .multilineTextAlignment(.center)
                                    .lineSpacing(1)
                            }
                            .frame(maxWidth: 290)
                            .padding(.top, 30)

                            Spacer(minLength: 16)
                                .frame(minHeight: 92)
                        }
                        .ignoresSafeArea(edges: .top)
                        .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .ignoresSafeArea(edges: .top)

                VStack(spacing: 14) {
                    HStack(spacing: 5) {
                        ForEach(pages.indices, id: \.self) { pageIndex in
                            Capsule(style: .continuous)
                                .fill(pageIndex == selectedPage ? Color.white.opacity(0.94) : Color.white.opacity(0.22))
                                .frame(width: pageIndex == selectedPage ? 14 : 4, height: 4)
                                .animation(.spring(response: 0.24, dampingFraction: 0.82), value: selectedPage)
                        }
                    }

                    SignInWithAppleButton(.signIn) { request in
                        onAppleRequest(request)
                    } onCompletion: { result in
                        onAppleCompletion(result)
                    }
                    .signInWithAppleButtonStyle(.black)
                    .frame(width: max(1, min(340, proxy.size.width - 56)), height: 48)
                    .clipShape(Capsule(style: .continuous))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, max(18, proxy.safeAreaInsets.bottom + 8))
                .zIndex(6)

                HStack {
                    Spacer()
                    Button {
                        dismiss()
                        onClose()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.white.opacity(0.9))
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .contentShape(Rectangle())
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(.top, max(12, proxy.safeAreaInsets.top + 4))
                .padding(.trailing, 18)
                .zIndex(8)
            }
            .simultaneousGesture(
                DragGesture(minimumDistance: 28)
                    .onEnded { value in
                        guard selectedPage == pages.indices.last else { return }
                        guard !isHandlingLastPageSwipe else { return }
                        let horizontalIntent = abs(value.translation.width) > abs(value.translation.height) * 1.2
                        let didSwipeForward = value.translation.width < -54 || value.predictedEndTranslation.width < -92
                        guard horizontalIntent, didSwipeForward else { return }

                        isHandlingLastPageSwipe = true
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        onAppleSignInRequested()

                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                            isHandlingLastPageSwipe = false
                        }
                    }
            )
            .onAppear {
                withAnimation(.spring(response: 0.62, dampingFraction: 0.83).delay(0.06)) {
                    cardEntered = true
                }
            }
        }
    }
}

private struct WelcomeQuickTourPage {
    let assetName: String
    let title: String
    let subtitle: String

    static let orderedPages: [WelcomeQuickTourPage] = [
        WelcomeQuickTourPage(
            assetName: "FeatureCard4",
            title: "Ounje handles the hard part.",
            subtitle: "We take care of the sourcing, plan, and shopping so you can just show up & do what you love."
        ),
        WelcomeQuickTourPage(
            assetName: "FeatureCard5",
            title: "Send recipes from anywhere.",
            subtitle: "Share from TikTok or Instagram, or take a picture and we’ll build the recipe."
        ),
        WelcomeQuickTourPage(
            assetName: "FeatureCard2",
            title: "Build a smarter cart.",
            subtitle: "Collapse your next prep into one shop list that remembers what you already have."
        ),
        WelcomeQuickTourPage(
            assetName: "FeatureCard8",
            title: "Agents shop with your say-so.",
            subtitle: "Connect Instacart and Ounje can find better groceries. You review before checkout."
        ),
        WelcomeQuickTourPage(
            assetName: "FeatureCard1",
            title: "Edit any recipe with AI.",
            subtitle: "Make it healthier, add protein, go keto, or change the vibe in one tap."
        ),
        WelcomeQuickTourPage(
            assetName: "FeatureCard9",
            title: "Build Ounje with us.",
            subtitle: "Send feedback straight to the founders and help shape what ships next."
        )
    ]
}

private struct MealPlannerShellView: View {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var store: MealPlanningAppStore
    @EnvironmentObject private var realtimeCoordinator: AppRealtimeInvalidationCoordinator
    @ObservedObject private var toastCenter: AppToastCenter
    @StateObject private var sharedImportInbox = SharedRecipeImportInboxStore()
    @StateObject private var recipeImportHistory = RecipeImportHistoryStore()
    @StateObject private var savedStore: SavedRecipesStore
    @StateObject private var discoverRecipesViewModel = DiscoverRecipesViewModel()
    @StateObject private var discoverEnvironmentModel = DiscoverEnvironmentViewModel()
    @Namespace private var recipeTransitionNamespace
    @State private var selectedTab: AppTab = .discover
    @State private var discoverSearchText = ""
    @State private var cookbookSearchText = ""
    @State private var presentedRecipe: PresentedRecipeDetail?
    @State private var focusedCartRecipeID: String?
    @State private var requestedCookbookCycleID: String?
    @State private var requestedImportQueueTab: SharedRecipeImportQueueTab?
    @State private var isProcessingSharedImports = false
    @State private var syncedCompletedImportIDs = Set<String>()
    @State private var prewarmedCompletedImportIDs = Set<String>()
    @State private var lastSharedImportRefreshAt = Date.distantPast
    @State private var previousSelectedTab: AppTab = .discover
    @State private var tabTransitionDirection: CGFloat = 1
    @State private var requestedCookbookImportText: String?
    @State private var isPhotoImportComposerPresented = false
    @State private var photoImportComposerContext: CookbookComposerContext = .saved
    @State private var isProcessingPrepPhotoImport = false

    private enum SharedImportProcessingScope {
        case queued
        case failed
        case all
    }

    init(toastCenter: AppToastCenter) {
        _toastCenter = ObservedObject(wrappedValue: toastCenter)
        _savedStore = StateObject(wrappedValue: SavedRecipesStore(toastCenter: toastCenter))
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                MainAppBackdrop()

                tabContent
                    .id(selectedTab)
                    .environmentObject(savedStore)
                    .environmentObject(sharedImportInbox)
                    .transition(shellTabTransition)
                    .animation(OunjeMotion.screenSpring, value: selectedTab)
                    .allowsHitTesting(presentedRecipe == nil)
            }
            .background(OunjePalette.background.ignoresSafeArea())
            .overlay(alignment: .top) {
                ZStack {
                    if let toast = toastCenter.toast {
                        AppToastBanner(
                            toast: toast,
                            onTap: toast.destination == nil ? nil : {
                                handleToastTap(toast)
                            }
                        )
                            .id(toast.id)
                            .padding(.horizontal, 16)
                            .padding(.top, 12)
                            .transition(
                                .asymmetric(
                                    insertion: .modifier(
                                        active: DirectionalSurfaceRevealModifier(
                                            xOffset: 0,
                                            yOffset: -18,
                                            scale: 0.96,
                                            blur: 10,
                                            opacity: 0.001
                                        ),
                                        identity: DirectionalSurfaceRevealModifier()
                                    ),
                                    removal: .modifier(
                                        active: DirectionalSurfaceRevealModifier(
                                            xOffset: 0,
                                            yOffset: -12,
                                            scale: 0.985,
                                            blur: 6,
                                            opacity: 0.001
                                        ),
                                        identity: DirectionalSurfaceRevealModifier()
                                    )
                                )
                            )
                            .allowsHitTesting(toast.destination != nil || toast.action != nil)
                    }
                }
                .animation(OunjeMotion.screenSpring, value: toastCenter.toast?.id)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                BottomNavigationDock(
                    selectedTab: $selectedTab,
                    safeAreaBottom: proxy.safeAreaInsets.bottom
                )
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .animation(OunjeMotion.tabSpring, value: selectedTab)
            }
            .overlay {
                if let presentedRecipe {
                    RecipeDetailExperienceView(
                        presentedRecipe: presentedRecipe,
                        onOpenCart: {
                            focusedCartRecipeID = presentedRecipe.plannedRecipe?.recipe.id ?? presentedRecipe.recipeCard.id
                            withAnimation(OunjeMotion.heroSpring) {
                                selectedTab = .cart
                                self.presentedRecipe = nil
                            }
                        },
                        toastCenter: toastCenter,
                        onDismiss: dismissPresentedRecipe,
                        transitionNamespace: recipeTransitionNamespace,
                        onOpenToastDestination: openToastDestination
                    )
                    .environmentObject(savedStore)
                    .transition(.opacity)
                    .zIndex(6)
                }
            }
        }
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .onAppear {
            savedStore.configureAuthSessionProvider {
                await store.refreshAuthSessionIfNeeded()
            }
        }
        .task(id: store.authSession?.userID ?? "signed-out") {
            syncedCompletedImportIDs.removeAll()
            prewarmedCompletedImportIDs.removeAll()
            await savedStore.refreshFromRemote(authSession: store.authSession, force: true)
        }
        .task(id: savedStoreAuthKey) {
            await savedStore.bootstrap(authSession: store.authSession)
        }
        .task(id: "fresh-plan::\(store.authSession?.userID ?? "signed-out")") {
            await store.ensureFreshPlanIfNeeded()
        }
        .task(id: discoverPrewarmKey) {
            guard scenePhase == .active else { return }
            await prewarmBaseDiscoverFeed()
        }
        .task(id: cartSupportWarmupKey) {
            guard scenePhase == .active else { return }
            await CartSupportWarmupService.prewarmLatestPlanCartSupport(for: store)
        }
        .task(id: "shared-import::\(store.authSession?.userID ?? "signed-out")") {
            await processPendingSharedImports(scope: .queued)
        }
        .task(id: "shared-import-inbox::\(store.authSession?.userID ?? "signed-out")") {
            await sharedImportInbox.refresh()
        }
        .task(id: "recipe-import-history::\(store.authSession?.userID ?? "signed-out")") {
            await recipeImportHistory.refresh(userID: store.authSession?.userID)
            await sharedImportInbox.reconcileCompletedImports(
                recipeImportHistory.completedItems,
                onCompletedPreppedImport: { response in
                    await handleCompletedPreppedImport(response)
                }
            )
        }
        .onReceive(NotificationCenter.default.publisher(for: .recipeImportHistoryNeedsRefresh)) { _ in
            Task {
                await refreshSharedImportState(force: true)
                lastSharedImportRefreshAt = .now
            }
        }
        .task(id: "shared-import-poll::\(store.authSession?.userID ?? "signed-out")::\(scenePhase == .active ? "active" : "inactive")") {
            guard scenePhase == .active else { return }

            while !Task.isCancelled {
                await sharedImportInbox.refresh()

                let hasQueuedWork = hasQueuedSharedImportWork
                guard hasQueuedWork || hasLiveSharedImportWork else {
                    let idleSleep: UInt64 = realtimeCoordinator.isRunning ? 90_000_000_000 : 30_000_000_000
                    try? await Task.sleep(nanoseconds: idleSleep)
                    continue
                }

                if hasQueuedWork {
                    await processPendingSharedImports(scope: .queued)
                }

                let hasLiveImport = hasLiveSharedImportWork
                let shouldRefreshSharedState = hasLiveImport || Date().timeIntervalSince(lastSharedImportRefreshAt) >= 30
                if shouldRefreshSharedState {
                    await refreshSharedImportState(force: hasLiveImport)
                    lastSharedImportRefreshAt = .now
                }

                let sleepSeconds: Double
                if hasLiveImport {
                    sleepSeconds = realtimeCoordinator.isRunning ? 10 : 4
                } else {
                    sleepSeconds = realtimeCoordinator.isRunning ? 30 : 12
                }
                try? await Task.sleep(nanoseconds: UInt64(sleepSeconds * 1_000_000_000))
            }
        }
        .onOpenURL { url in
            handleIncomingURL(url)
        }
        .onChange(of: scenePhase) { phase in
            guard phase == .active else { return }
            Task {
                await prewarmBaseDiscoverFeed()
                await store.runAutomationPassIfNeeded(trigger: "scene_active")
                await sharedImportInbox.refresh()
                if hasQueuedSharedImportWork || hasLiveSharedImportWork {
                    await processPendingSharedImports(scope: .queued)
                    await refreshSharedImportState(force: true)
                    lastSharedImportRefreshAt = .now
                }
            }
        }
        .onChange(of: selectedTab) { newTab in
            let previousTab = previousSelectedTab
            tabTransitionDirection = newTab.motionIndex >= previousTab.motionIndex ? 1 : -1
            previousSelectedTab = newTab
            if newTab != .discover {
                discoverSearchText = ""
            }
        }
        .sheet(isPresented: $isPhotoImportComposerPresented) {
            DiscoverComposerSheet(context: photoImportComposerContext, initialText: nil)
                .environmentObject(savedStore)
                .environmentObject(sharedImportInbox)
                .environmentObject(store)
                .environmentObject(toastCenter)
                .presentationDetents([.fraction(0.68), .large])
                .presentationDragIndicator(.hidden)
        }
    }

    private var shellTabTransition: AnyTransition {
        let insertionOffset: CGFloat = tabTransitionDirection >= 0 ? 40 : -40
        let removalOffset: CGFloat = tabTransitionDirection >= 0 ? -18 : 18

        return .asymmetric(
            insertion: .modifier(
                active: DirectionalSurfaceRevealModifier(
                    xOffset: insertionOffset,
                    yOffset: 0,
                    scale: 0.985,
                    blur: 10,
                    opacity: 0.001
                ),
                identity: DirectionalSurfaceRevealModifier()
            ),
            removal: .modifier(
                active: DirectionalSurfaceRevealModifier(
                    xOffset: removalOffset,
                    yOffset: 0,
                    scale: 0.992,
                    blur: 6,
                    opacity: 0.001
                ),
                identity: DirectionalSurfaceRevealModifier()
            )
        )
    }

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .prep:
            PrepTabView(
                selectedTab: $selectedTab,
                requestedCookbookCycleID: $requestedCookbookCycleID,
                recipeTransitionNamespace: recipeTransitionNamespace,
                onSelectRecipe: { plannedRecipe in
                    presentRecipeDetail(PresentedRecipeDetail(plannedRecipe: plannedRecipe))
                },
                onImportFoodPhotos: { items in
                    Task {
                        await importFoodPhotosToPrep(items)
                    }
                },
                onCaptureFoodPhoto: { image in
                    Task {
                        await importCapturedFoodPhotoToPrep(image)
                    }
                }
            )
        case .discover:
            DiscoverTabView(
                selectedTab: $selectedTab,
                searchText: $discoverSearchText,
                recipeTransitionNamespace: recipeTransitionNamespace,
                onSelectRecipe: { recipe in
                    presentRecipeDetail(PresentedRecipeDetail(recipeCard: recipe))
                },
                viewModel: discoverRecipesViewModel,
                environmentModel: discoverEnvironmentModel
            )
        case .cookbook:
                CookbookTabView(
                    selectedTab: $selectedTab,
                    searchText: $cookbookSearchText,
                    requestedCycleID: $requestedCookbookCycleID,
                    requestedImportQueueTab: $requestedImportQueueTab,
                    requestedImportText: $requestedCookbookImportText,
                    recipeTransitionNamespace: recipeTransitionNamespace,
                    sharedImportInbox: sharedImportInbox,
                    recipeImportHistory: recipeImportHistory,
                    toastCenter: toastCenter,
                    onRefreshSharedImports: {
                        await refreshSharedImportState(force: true)
                    },
                    onRetryFailedSharedImports: {
                        Task {
                            await processPendingSharedImports(scope: .failed)
                            await refreshSharedImportState(force: true)
                        }
                    },
                    onDeleteFailedSharedImport: { envelopeID in
                        Task {
                            try? SharedRecipeImportInbox.delete(envelopeID: envelopeID)
                            await refreshSharedImportState(force: true)
                        }
                    },
                    onSelectRecipe: { recipe in
                        presentRecipeDetail(PresentedRecipeDetail(recipeCard: recipe))
                    }
                )
        case .cart:
            CartTabView(selectedTab: $selectedTab, focusedRecipeID: $focusedCartRecipeID)
        case .profile:
            ProfileTabView(
                importedRecipeCount: recipeImportHistory.completedCount,
                aiEditCount: profileAIEditsCount
            )
        }
    }

    @MainActor
    private func refreshSharedImportState(force: Bool = false) async {
        await sharedImportInbox.refresh()
        await recipeImportHistory.refresh(userID: store.authSession?.userID, force: force)
        await sharedImportInbox.reconcileCompletedImports(
            recipeImportHistory.completedItems,
            onCompletedPreppedImport: { response in
                await handleCompletedPreppedImport(response)
            }
        )
        await syncCompletedImportsIntoSavedStore()
        await prewarmCompletedImportDetails()
    }

    @MainActor
    private func handleCompletedPreppedImport(_ response: RecipeImportResponse) async {
        guard let detail = response.recipeDetail else { return }
        await store.updateLatestPlan(with: importedRecipePlanModel(from: detail), servings: detail.displayServings)
        selectedTab = .prep
        toastCenter.show(
            title: "Added to next prep",
            subtitle: detail.title,
            systemImage: "sparkles",
            thumbnailURLString: detail.discoverCardImageURLString ?? detail.heroImageURLString ?? detail.imageURL?.absoluteString,
            destination: .appTab(.prep)
        )
    }

    @MainActor
    private func importFoodPhotosToPrep(_ items: [PhotosPickerItem]) async {
        guard !isProcessingPrepPhotoImport else { return }
        let selectedItems = Array(items.prefix(4))
        guard !selectedItems.isEmpty else { return }

        isProcessingPrepPhotoImport = true
        toastCenter.show(
            title: "Checking photo",
            subtitle: "Ounje is building a recipe from it.",
            systemImage: "camera.viewfinder",
            destination: nil
        )
        defer { isProcessingPrepPhotoImport = false }

        do {
            var drafts: [RecipeImportMediaDraft] = []
            for item in selectedItems {
                if let draft = try await RecipeImportMediaDraft.load(
                    from: item,
                    userID: store.authSession?.userID,
                    accessToken: store.authSession?.accessToken
                ) {
                    drafts.append(draft)
                }
            }

            await finishFoodPhotoImportToPrep(drafts: drafts, sourceApp: "Ounje Photo")
        } catch {
            toastCenter.show(
                title: "Photo import failed",
                subtitle: error.localizedDescription,
                systemImage: "exclamationmark.circle.fill",
                destination: nil
            )
        }
    }

    @MainActor
    private func importCapturedFoodPhotoToPrep(_ image: UIImage) async {
        guard !isProcessingPrepPhotoImport else { return }

        isProcessingPrepPhotoImport = true
        toastCenter.show(
            title: "Checking photo",
            subtitle: "Ounje is building a recipe from it.",
            systemImage: "camera.viewfinder",
            destination: nil
        )
        defer { isProcessingPrepPhotoImport = false }

        do {
            let draft = try await RecipeImportMediaDraft.loadCapturedImage(
                image,
                userID: store.authSession?.userID,
                accessToken: store.authSession?.accessToken
            )
            await finishFoodPhotoImportToPrep(drafts: [draft], sourceApp: "Ounje Camera")
        } catch {
            toastCenter.show(
                title: "Photo import failed",
                subtitle: error.localizedDescription,
                systemImage: "exclamationmark.circle.fill",
                destination: nil
            )
        }
    }

    @MainActor
    private func finishFoodPhotoImportToPrep(drafts: [RecipeImportMediaDraft], sourceApp: String) async {
        do {
            guard !drafts.isEmpty else {
                toastCenter.show(
                    title: "No photo found",
                    subtitle: "Pick a clear food photo and try again.",
                    systemImage: "exclamationmark.circle.fill",
                    destination: nil
                )
                return
            }

            let localEnvelope = SharedRecipeImportEnvelope(
                id: UUID().uuidString,
                createdAt: Date(),
                jobID: nil,
                targetState: "prepped",
                sourceText: "",
                sourceURLString: nil,
                canonicalSourceURLString: nil,
                sourceApp: sourceApp,
                attachments: [],
                processingState: "queued",
                attemptCount: 1,
                lastAttemptAt: Date(),
                lastError: nil,
                updatedAt: Date()
            )
            try? SharedRecipeImportInbox.write(localEnvelope)
            await sharedImportInbox.refresh()

            let response = try await RecipeImportAPIService.shared.importRecipe(
                userID: store.authSession?.userID,
                accessToken: store.authSession?.accessToken,
                sourceURL: nil,
                sourceText: "",
                targetState: "prepped",
                attachments: drafts.map(\.payload),
                photoContext: RecipeImportPhotoContextPayload(
                    dishHint: nil,
                    coarsePlaceContext: nil
                )
            )

            NotificationCenter.default.post(name: .recipeImportHistoryNeedsRefresh, object: nil)

            if let importedRecipe = response.recipe {
                savedStore.saveImportedRecipe(importedRecipe, showToast: false)
            }
            if let detail = response.recipeDetail {
                await store.updateLatestPlan(with: importedRecipePlanModel(from: detail), servings: detail.displayServings)
            }

            let backendState = response.job.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let reviewState = response.job.reviewState.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let canDisplayRecipe = response.recipe != nil || response.recipeDetail != nil
            let failureReason = [
                response.job.errorMessage,
                response.job.reviewReason,
                "Ounje could not extract a displayable recipe from this photo."
            ]
            .compactMap { raw -> String? in
                let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return trimmed.isEmpty ? nil : trimmed
            }
            .first
            let shouldFail = backendState == "failed"
                || (["draft", "needs_review"].contains(reviewState) && !canDisplayRecipe)
            let isLiveState = ["queued", "processing", "fetching", "parsing", "normalized"].contains(backendState)

            if shouldFail {
                let failedEnvelope = SharedRecipeImportEnvelope(
                    id: localEnvelope.id,
                    createdAt: localEnvelope.createdAt,
                    jobID: response.job.id,
                    targetState: localEnvelope.targetState,
                    sourceText: localEnvelope.sourceText,
                    sourceURLString: nil,
                    canonicalSourceURLString: response.job.sourceURL,
                    sourceApp: localEnvelope.sourceApp,
                    attachments: localEnvelope.attachments,
                    processingState: "failed",
                    attemptCount: localEnvelope.attemptCount,
                    lastAttemptAt: Date(),
                    lastError: failureReason,
                    updatedAt: Date()
                )
                try? SharedRecipeImportInbox.update(failedEnvelope)
                await sharedImportInbox.refresh()
                toastCenter.show(
                    title: "Couldn’t read photo",
                    subtitle: failureReason,
                    systemImage: "exclamationmark.circle.fill",
                    destination: .recipeImportQueue(.failed)
                )
                return
            }

            if isLiveState && !canDisplayRecipe {
                let queuedEnvelope = SharedRecipeImportEnvelope(
                    id: localEnvelope.id,
                    createdAt: localEnvelope.createdAt,
                    jobID: response.job.id,
                    targetState: localEnvelope.targetState,
                    sourceText: localEnvelope.sourceText,
                    sourceURLString: nil,
                    canonicalSourceURLString: response.job.sourceURL,
                    sourceApp: localEnvelope.sourceApp,
                    attachments: localEnvelope.attachments,
                    processingState: backendState,
                    attemptCount: localEnvelope.attemptCount,
                    lastAttemptAt: Date(),
                    lastError: nil,
                    updatedAt: Date()
                )
                try? SharedRecipeImportInbox.update(queuedEnvelope)
                await sharedImportInbox.refresh()
                toastCenter.show(
                    title: "Photo queued",
                    subtitle: "Ounje is checking the dish photo now.",
                    systemImage: "camera.viewfinder",
                    destination: .recipeImportQueue(.queued)
                )
                return
            }

            try? SharedRecipeImportInbox.delete(envelopeID: localEnvelope.id)
            await sharedImportInbox.refresh()
            selectedTab = .prep
            toastCenter.show(
                title: "Added to next prep",
                subtitle: response.recipeDetail?.title ?? response.recipe?.title ?? "Photo recipe ready.",
                systemImage: "sparkles",
                thumbnailURLString: response.recipeDetail?.discoverCardImageURLString
                    ?? response.recipeDetail?.heroImageURLString
                    ?? response.recipe?.imageURLString,
                destination: .appTab(.prep)
            )
        } catch {
            toastCenter.show(
                title: "Photo import failed",
                subtitle: error.localizedDescription,
                systemImage: "exclamationmark.circle.fill",
                destination: nil
            )
        }
    }

    @MainActor
    private func syncCompletedImportsIntoSavedStore() async {
        for item in recipeImportHistory.completedItems.reversed() {
            guard syncedCompletedImportIDs.insert(item.id).inserted else { continue }
            guard let savedRecipe = item.savedRecipeCard else { continue }
            savedStore.saveImportedRecipe(savedRecipe, showToast: false)
        }
    }

    private func prewarmCompletedImportDetails() async {
        let recipeIDs = recipeImportHistory.completedItems.compactMap { item -> String? in
            guard let id = item.recipeID?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty else {
                return nil
            }
            return id
        }

        for recipeID in recipeIDs.reversed() {
            guard prewarmedCompletedImportIDs.insert(recipeID).inserted else { continue }
            Task(priority: .utility) {
                _ = try? await RecipeDetailService.shared.fetchRecipeDetail(id: recipeID)
            }
        }
    }

    @MainActor
    private func prewarmBaseDiscoverFeed() async {
        guard discoverSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        discoverRecipesViewModel.updateFeedbackRevision(discoverFeedbackRevision)
        await discoverEnvironmentModel.refresh(profile: store.profile)
        await discoverRecipesViewModel.loadIfNeeded(
            profile: store.profile,
            query: "",
            feedContext: discoverEnvironmentModel.feedContext,
            behaviorSeeds: []
        )
    }

    private func presentRecipeDetail(_ recipe: PresentedRecipeDetail) {
        withAnimation(OunjeMotion.heroSpring) {
            presentedRecipe = recipe
        }
    }

    private func dismissPresentedRecipe() {
        withAnimation(OunjeMotion.heroSpring) {
            presentedRecipe = nil
        }
    }

    private func handleToastTap(_ toast: AppToast) {
        guard let destination = toast.destination else { return }
        toastCenter.dismiss()
        openToastDestination(destination)
    }

    private func openToastDestination(_ destination: AppToastDestination) {
        withAnimation(OunjeMotion.heroSpring) {
            switch destination {
            case .recipe(let recipe):
                selectedTab = .cookbook
                presentedRecipe = PresentedRecipeDetail(recipeCard: recipe)
            case .recipeImportQueue(let tab):
                presentedRecipe = nil
                requestedImportQueueTab = tab
                selectedTab = .cookbook
            case .appTab(let tab):
                presentedRecipe = nil
                selectedTab = tab
            }
        }
    }

    private func handleIncomingURL(_ url: URL) {
        if let shareID = RecipeDetailService.shareID(from: url) {
            Task { await openSharedRecipeLink(shareID) }
            return
        }

        guard SharedRecipeImportInbox.isShareImportURL(url) else { return }
        withAnimation(OunjeMotion.heroSpring) {
            requestedImportQueueTab = .queued
            selectedTab = .cookbook
        }
        Task {
            await sharedImportInbox.refresh()
            await processPendingSharedImports(scope: .queued)
            await refreshSharedImportState(force: true)
            lastSharedImportRefreshAt = .now
        }
    }

    @MainActor
    private func openSharedRecipeLink(_ shareID: String) async {
        do {
            let resolved = try await RecipeDetailService.shared.resolveShareLink(shareID: shareID)
            withAnimation(OunjeMotion.heroSpring) {
                presentedRecipe = PresentedRecipeDetail(
                    recipeCard: resolved.recipeCard,
                    initialDetail: resolved.recipeDetail
                )
            }
        } catch {
            toastCenter.show(
                title: "Recipe link unavailable",
                subtitle: "Try opening it again in a moment.",
                systemImage: "link.badge.plus"
            )
        }
    }

    private func openCookbookImportComposer(with text: String) {
        requestedCookbookImportText = text
        withAnimation(OunjeMotion.heroSpring) {
            selectedTab = .cookbook
        }
    }

    private var hasQueuedSharedImportWork: Bool {
        sharedImportInbox.envelopes.contains { envelope in
            envelope.shouldAutoProcess
        }
    }

    private var cartSupportWarmupKey: String {
        let userKey = store.authSession?.userID ?? "signed-out"
        let planKey = store.latestPlan?.id.uuidString ?? "no-plan"
        let activeKey = scenePhase == .active ? "active" : "inactive"
        return "cart-support-warmup::\(userKey)::\(planKey)::\(store.latestPlanRevision)::\(activeKey)"
    }

    private var savedStoreAuthKey: String {
        let userKey = store.authSession?.userID ?? "signed-out"
        let tokenKey = store.authSession?.accessToken?.suffix(18) ?? "no-token"
        return "saved-store-auth::\(userKey)::\(tokenKey)"
    }

    private var discoverPrewarmKey: String {
        let userKey = store.authSession?.userID ?? "signed-out"
        let profile = store.profile
        let preferredName = profile?.preferredName ?? ""
        let cuisines = profile?.preferredCuisines.map(\.rawValue).joined(separator: ",") ?? ""
        let dietaryPatterns = profile?.dietaryPatterns.joined(separator: ",") ?? ""
        let city = profile?.deliveryAddress.city ?? ""
        let region = profile?.deliveryAddress.region ?? ""
        let postalCode = profile?.deliveryAddress.postalCode ?? ""
        let profileKey = [preferredName, cuisines, dietaryPatterns, city, region, postalCode]
            .joined(separator: "|")
        let activeKey = scenePhase == .active ? "active" : "inactive"
        return "discover-prewarm::\(userKey)::\(profileKey)::feedback:\(discoverFeedbackRevision)::\(activeKey)"
    }

    private var discoverFeedbackRevision: Int {
        0
    }

    private var profileAIEditsCount: Int {
        var ids = Set<String>()
        for item in recipeImportHistory.completedItems where item.looksLikeAIEdit {
            let recipeID = item.recipeID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            ids.insert(recipeID.isEmpty ? item.id : recipeID)
        }
        for recipe in savedStore.savedRecipes where recipe.looksLikeAIEdit {
            ids.insert(recipe.id)
        }
        return ids.count
    }

    private var hasLiveSharedImportWork: Bool {
        sharedImportInbox.envelopes.contains { envelope in
            switch envelope.normalizedProcessingState {
            case "queued", "processing", "fetching", "parsing", "normalized":
                return true
            default:
                return false
            }
        }
    }

    @MainActor
    private func processPendingSharedImports(scope: SharedImportProcessingScope = .queued) async {
        guard !isProcessingSharedImports, let userID = store.authSession?.userID else { return }

        let envelopes: [SharedRecipeImportEnvelope]
        do {
            envelopes = try SharedRecipeImportInbox.readAll()
        } catch {
            return
        }

        guard !envelopes.isEmpty else {
            await sharedImportInbox.refresh()
            return
        }
        isProcessingSharedImports = true
        defer { isProcessingSharedImports = false }

        let eligibleEnvelopes = envelopes.filter { envelope in
            switch scope {
            case .queued:
                return envelope.shouldAutoProcess
            case .failed:
                return envelope.isRetryNeeded
            case .all:
                return envelope.shouldAutoProcess || envelope.isRetryNeeded
            }
        }

        guard !eligibleEnvelopes.isEmpty else {
            await sharedImportInbox.refresh()
            return
        }

        for envelope in eligibleEnvelopes {
            var activeAttemptCount = envelope.attemptCount ?? 0
            do {
                var processingEnvelope = envelope
                let existingJobID = envelope.jobID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let shouldPollExistingJob = !existingJobID.isEmpty
                    && !envelope.isRetryNeeded
                let nextAttemptCount = shouldPollExistingJob
                    ? (processingEnvelope.attemptCount ?? 0)
                    : (processingEnvelope.attemptCount ?? 0) + 1
                activeAttemptCount = nextAttemptCount
                processingEnvelope = SharedRecipeImportEnvelope(
                    id: processingEnvelope.id,
                    createdAt: processingEnvelope.createdAt,
                    jobID: processingEnvelope.jobID,
                    targetState: processingEnvelope.targetState,
                    sourceText: processingEnvelope.sourceText,
                    sourceURLString: processingEnvelope.sourceURLString,
                    canonicalSourceURLString: processingEnvelope.canonicalSourceURLString,
                    sourceApp: processingEnvelope.sourceApp,
                    attachments: processingEnvelope.attachments,
                    processingState: "processing",
                    attemptCount: nextAttemptCount,
                    lastAttemptAt: Date(),
                    lastError: nil,
                    updatedAt: Date()
                )
                try? SharedRecipeImportInbox.update(processingEnvelope)
                await sharedImportInbox.refresh()

                let response: RecipeImportResponse
                if shouldPollExistingJob {
                    response = try await RecipeImportAPIService.shared.fetchImportJob(jobID: existingJobID)
                } else {
                    let attachments = try await sharedImportAttachmentPayloads(from: envelope.attachments)
                    response = try await RecipeImportAPIService.shared.importRecipe(
                        userID: userID,
                        accessToken: store.authSession?.accessToken,
                        sourceURL: envelope.sourceURLString?.trimmingCharacters(in: .whitespacesAndNewlines),
                        sourceText: envelope.resolvedSourceText,
                        targetState: envelope.targetState,
                        attachments: attachments
                    )
                }

                if let importedRecipe = response.recipe {
                    savedStore.saveImportedRecipe(importedRecipe, showToast: false)
                }
                NotificationCenter.default.post(name: .recipeImportHistoryNeedsRefresh, object: nil)
                let backendProcessingState = response.job.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let isLiveBackendState = ["queued", "processing", "fetching", "parsing", "normalized"].contains(backendProcessingState)
                let visibleAttemptCount = max(processingEnvelope.attemptCount ?? 0, response.job.attempts ?? 0)
                let reviewState = response.job.reviewState.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let canDisplayImportedRecipe = response.recipe != nil || response.recipeDetail != nil
                let importFailureReason = [
                    response.job.errorMessage,
                    response.job.reviewReason,
                    "Ounje could not extract a displayable recipe from this share."
                ]
                .compactMap { raw -> String? in
                    let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    return trimmed.isEmpty ? nil : trimmed
                }
                .first
                let shouldFailImport = backendProcessingState == "failed"
                    || (["draft", "needs_review"].contains(reviewState) && !canDisplayImportedRecipe)

                if shouldFailImport {
                    let failedEnvelope = SharedRecipeImportEnvelope(
                        id: envelope.id,
                        createdAt: envelope.createdAt,
                        jobID: response.job.id,
                        targetState: envelope.targetState,
                        sourceText: envelope.sourceText,
                        sourceURLString: envelope.sourceURLString,
                        canonicalSourceURLString: [
                            response.recipeDetail?.originalRecipeURLString,
                            response.recipeDetail?.recipeURLString,
                            response.job.sourceURL
                        ]
                        .compactMap { raw -> String? in
                            let trimmed = raw?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines) ?? ""
                            return trimmed.isEmpty ? nil : trimmed
                        }
                        .first
                            ?? envelope.canonicalSourceURLString,
                        sourceApp: envelope.sourceApp,
                        attachments: envelope.attachments,
                        processingState: "failed",
                        attemptCount: visibleAttemptCount,
                        lastAttemptAt: Date(),
                        lastError: importFailureReason,
                        updatedAt: Date()
                    )
                    try? SharedRecipeImportInbox.update(failedEnvelope)
                    toastCenter.show(
                        title: "Couldn’t import share",
                        subtitle: importFailureReason,
                        systemImage: "exclamationmark.circle.fill",
                        destination: .recipeImportQueue(.failed)
                    )
                } else if let detail = response.recipeDetail, envelope.targetState == "prepped" {
                    await store.updateLatestPlan(with: importedRecipePlanModel(from: detail), servings: detail.displayServings)
                    selectedTab = .prep
                    toastCenter.show(
                        title: "Added to next prep",
                        subtitle: detail.title,
                        systemImage: "sparkles",
                        thumbnailURLString: detail.discoverCardImageURLString ?? detail.heroImageURLString ?? detail.imageURL?.absoluteString,
                        destination: .appTab(.prep)
                    )
                    try? SharedRecipeImportInbox.delete(envelopeID: envelope.id)
                } else if isLiveBackendState {
                    let normalizedProcessingState: String = {
                        switch backendProcessingState {
                        case "queued", "processing", "fetching", "parsing", "normalized", "saved":
                            return backendProcessingState
                        default:
                            return "queued"
                        }
                    }()
                    let queuedEnvelope = SharedRecipeImportEnvelope(
                        id: envelope.id,
                        createdAt: envelope.createdAt,
                        jobID: response.job.id,
                        targetState: envelope.targetState,
                        sourceText: envelope.sourceText,
                        sourceURLString: envelope.sourceURLString,
                        canonicalSourceURLString: [
                            response.recipeDetail?.originalRecipeURLString,
                            response.recipeDetail?.recipeURLString,
                            response.job.sourceURL
                        ]
                        .compactMap { raw -> String? in
                            let trimmed = raw?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines) ?? ""
                            return trimmed.isEmpty ? nil : trimmed
                        }
                        .first
                            ?? envelope.canonicalSourceURLString,
                        sourceApp: envelope.sourceApp,
                        attachments: envelope.attachments,
                        processingState: normalizedProcessingState,
                        attemptCount: visibleAttemptCount,
                        lastAttemptAt: Date(),
                        lastError: nil,
                        updatedAt: Date()
                    )
                    try? SharedRecipeImportInbox.update(queuedEnvelope)
                    if !shouldPollExistingJob && (envelope.attemptCount ?? 0) <= 1 {
                        toastCenter.show(
                            title: "Import queued",
                            subtitle: envelope.resolvedSourceText.isEmpty ? "Ounje is pulling your recipe in now." : envelope.resolvedSourceText,
                            systemImage: "tray.and.arrow.down.fill",
                            destination: .recipeImportQueue(.queued)
                        )
                    }
                } else if ["draft", "needs_review", "saved"].contains(backendProcessingState) || response.recipe != nil {
                    selectedTab = .cookbook
                    toastCenter.show(
                        title: "Saved",
                        subtitle: response.recipe?.title ?? "Imported recipe",
                        systemImage: "bookmark.fill",
                        thumbnailURLString: response.recipe?.imageURL?.absoluteString,
                        destination: response.recipe.map(AppToastDestination.recipe) ?? .recipeImportQueue(.completed)
                    )
                    try? SharedRecipeImportInbox.delete(envelopeID: envelope.id)
                }

                await sharedImportInbox.refresh()
                NotificationCenter.default.post(name: .recipeImportHistoryNeedsRefresh, object: nil)
            } catch {
                let errorMessage = (error as? RecipeImportServiceError).map {
                    switch $0 {
                    case .invalidRequest:
                        return "Invalid import request."
                    case .invalidResponse:
                        return "Unexpected import response."
                    case .requestFailed(let message):
                        return message
                    }
                } ?? error.localizedDescription
                let failedEnvelope = SharedRecipeImportEnvelope(
                    id: envelope.id,
                    createdAt: envelope.createdAt,
                    jobID: envelope.jobID,
                    targetState: envelope.targetState,
                    sourceText: envelope.sourceText,
                    sourceURLString: envelope.sourceURLString,
                    canonicalSourceURLString: envelope.canonicalSourceURLString,
                    sourceApp: envelope.sourceApp,
                    attachments: envelope.attachments,
                    processingState: "failed",
                    attemptCount: max(activeAttemptCount, (envelope.attemptCount ?? 0) + 1),
                    lastAttemptAt: Date(),
                    lastError: errorMessage,
                    updatedAt: Date()
                )
                try? SharedRecipeImportInbox.update(failedEnvelope)
                await sharedImportInbox.refresh()
                NotificationCenter.default.post(name: .recipeImportHistoryNeedsRefresh, object: nil)
                toastCenter.show(
                    title: "Couldn’t import share",
                    subtitle: errorMessage,
                    systemImage: "exclamationmark.circle.fill",
                    destination: .recipeImportQueue(.failed)
                )
            }
        }
    }
}

struct HoppingCartIcon: View {
    let isActive: Bool
    var color: Color = Color.white.opacity(0.86)
    var size: CGFloat = 16
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if isActive && !reduceMotion {
                TimelineView(.animation) { context in
                    let time = context.date.timeIntervalSinceReferenceDate
                    let hop = -CGFloat(max(0, sin(time * 5.8))) * 5
                    let squash = 1 + CGFloat(max(0, sin(time * 5.8))) * 0.04

                    Image(systemName: "cart.fill")
                        .font(.system(size: size, weight: .semibold))
                        .foregroundStyle(color)
                        .offset(y: -2 + hop)
                        .scaleEffect(x: squash, y: 1 - ((squash - 1) * 0.5), anchor: .bottom)
                }
            } else {
                Image(systemName: "cart.fill")
                    .font(.system(size: size, weight: .semibold))
                    .foregroundStyle(color)
                    .offset(y: -2)
            }
        }
        .accessibilityHidden(true)
    }
}

private struct PulsingTrayIcon: View {
    let count: Int
    let isPulsing: Bool
    @State private var pulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ZStack {
                if isPulsing && !reduceMotion {
                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .stroke(OunjePalette.accent.opacity(pulse ? 0.14 : 0.42), lineWidth: 1.4)
                        .frame(width: 44, height: 44)
                        .scaleEffect(pulse ? 1.16 : 0.96)
                }

                Image(systemName: "tray.full")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(OunjePalette.primaryText)
                    .frame(width: 42, height: 42)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(OunjePalette.surface)
                            .overlay(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .stroke(OunjePalette.stroke, lineWidth: 1)
                            )
                    )
                    .scaleEffect(isPulsing && !reduceMotion && pulse ? 1.04 : 1)
            }

            if count > 0 {
                Text("\(count)")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(OunjePalette.background)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(
                        Capsule(style: .continuous)
                            .fill(OunjePalette.accent)
                    )
                    .offset(x: 4, y: -4)
            }
        }
        .onAppear { updatePulseAnimation() }
        .onChange(of: isPulsing) { _ in
            updatePulseAnimation()
        }
    }

    private func updatePulseAnimation() {
        guard isPulsing, !reduceMotion else {
            pulse = false
            return
        }

        withAnimation(.easeInOut(duration: 0.92).repeatForever(autoreverses: true)) {
            pulse = true
        }
    }
}

struct MotionEmptyIllustration: View {
    let assetName: String
    var height: CGFloat
    var maxWidth: CGFloat? = nil
    var alignment: Alignment = .center
    @State private var floats = false
    @State private var shine = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Image(assetName)
            .renderingMode(.original)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(height: height)
            .frame(maxWidth: maxWidth, alignment: alignment)
            .frame(maxWidth: .infinity, alignment: alignment)
            .opacity(0.92)
            .offset(y: reduceMotion ? 0 : (floats ? -4 : 3))
            .scaleEffect(reduceMotion ? 1 : (floats ? 1.012 : 0.992))
            .overlay {
                if !reduceMotion {
                    LinearGradient(
                        colors: [
                            .clear,
                            .white.opacity(0.24),
                            .clear
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(width: max(38, height * 0.34), height: height * 1.45)
                    .rotationEffect(.degrees(18))
                    .offset(x: shine ? height * 1.85 : -height * 1.85)
                    .blendMode(.screen)
                    .opacity(0.7)
                    .allowsHitTesting(false)
                }
            }
            .clipped()
            .accessibilityHidden(true)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 1.45).repeatForever(autoreverses: true)) {
                    floats = true
                }
                withAnimation(.linear(duration: 2.1).repeatForever(autoreverses: false)) {
                    shine = true
                }
            }
    }
}

struct StaggeredRevealModifier: ViewModifier {
    let isVisible: Bool
    var delay: Double = 0
    var xOffset: CGFloat = 0
    var yOffset: CGFloat = 16
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(isVisible ? 1 : 0)
            .offset(
                x: reduceMotion ? 0 : (isVisible ? 0 : xOffset),
                y: reduceMotion ? 0 : (isVisible ? 0 : yOffset)
            )
            .scaleEffect(reduceMotion ? 1 : (isVisible ? 1 : 0.985))
            .animation(
                .spring(response: 0.38, dampingFraction: 0.86).delay(delay),
                value: isVisible
            )
    }
}

enum PurchaseCTAVisualState: Equatable {
    case idle
    case processing
    case success
    case failed
}

struct PurchasingCTAButton: View {
    let title: String
    let state: PurchaseCTAVisualState
    var height: CGFloat = 44
    var isDisabled: Bool = false
    var foregroundColor: Color = .black
    var fillColor: Color = OunjePalette.accent
    var progressFillColor: Color = Color.white.opacity(0.28)
    var cornerRadius: CGFloat = 8
    var fontSize: CGFloat = 11
    let action: () -> Void

    @GestureState private var isPressed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            TimelineView(.animation) { context in
                let progress = fillProgress(at: context.date)

                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(fillColor)

                    if progress > 0 {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(state == .failed ? Color.white.opacity(0.20) : progressFillColor)
                            .frame(maxWidth: .infinity)
                            .scaleEffect(x: progress, y: 1, anchor: .leading)
                    }

                    HStack(spacing: 9) {
                        Spacer(minLength: 0)

                        if state == .success {
                            Image(systemName: "checkmark")
                                .font(.system(size: 13, weight: .bold))
                        } else if state == .failed {
                            Image(systemName: "exclamationmark")
                                .font(.system(size: 13, weight: .bold))
                        }

                        Text(state == .success ? "All set" : title)
                            .font(.system(size: fontSize, weight: .bold, design: .rounded))
                            .foregroundStyle(foregroundColor)
                            .textCase(.uppercase)
                            .lineLimit(1)
                            .minimumScaleFactor(0.82)

                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(foregroundColor)
                }
                .frame(maxWidth: .infinity)
                .frame(height: height)
            }
        }
        .buttonStyle(.plain)
        .disabled(isDisabled || state == .processing)
        .scaleEffect(!reduceMotion && isPressed ? 0.975 : 1)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .updating($isPressed) { _, state, _ in
                    state = true
                }
        )
        .animation(.spring(response: 0.2, dampingFraction: 0.82), value: isPressed)
        .accessibilityLabel(title)
    }

    private func fillProgress(at _: Date) -> CGFloat {
        switch state {
        case .idle:
            return 0
        case .processing:
            return 0
        case .success:
            return 1
        case .failed:
            return 1
        }
    }
}

enum CookbookSection: String, CaseIterable, Identifiable {
    case prepped
    case saved

    var id: String { rawValue }

    var motionIndex: Int {
        switch self {
        case .prepped:
            return 0
        case .saved:
            return 1
        }
    }

    var title: String {
        switch self {
        case .saved: return "Saved"
        case .prepped: return "Prep"
        }
    }

    var subtitle: String {
        switch self {
        case .saved:
            return "Recipes you’ve kept for later."
        case .prepped:
            return "Meals you’re cooking."
        }
    }
}

private enum CookbookComposerContext {
    case prepped
    case saved

    var title: String {
        switch self {
        case .prepped: return "Add to prep"
        case .saved: return "Add to saved"
        }
    }

    var placeholder: String {
        switch self {
        case .prepped:
            return "Import a recipe using a link, photo, video, or describe what you want in the next prep cycle."
        case .saved:
            return "Import a recipe using a link, photo, video, or describe what you want to save to your cookbook."
        }
    }

    var primaryActionTitle: String {
        switch self {
        case .prepped: return "Add to next prep"
        case .saved: return "Save to cookbook"
        }
    }
}

private struct CookbookTabView: View {
    @Binding var selectedTab: AppTab
    @Binding var searchText: String
    @Binding var requestedCycleID: String?
    @Binding var requestedImportQueueTab: SharedRecipeImportQueueTab?
    @Binding var requestedImportText: String?
    let recipeTransitionNamespace: Namespace.ID
    @ObservedObject var sharedImportInbox: SharedRecipeImportInboxStore
    @ObservedObject var recipeImportHistory: RecipeImportHistoryStore
    @ObservedObject var toastCenter: AppToastCenter
    let onRefreshSharedImports: () async -> Void
    let onRetryFailedSharedImports: () -> Void
    let onDeleteFailedSharedImport: (String) -> Void
    let onSelectRecipe: (DiscoverRecipeCardData) -> Void

    @EnvironmentObject private var savedStore: SavedRecipesStore
    @EnvironmentObject private var store: MealPlanningAppStore

    @State private var selectedSection: CookbookSection = .prepped
    @State private var selectedFilter: String = "All"
    @State private var isComposerPresented = false
    @State private var composerContext: CookbookComposerContext = .saved
    @State private var composerInitialText: String?
    @State private var selectedCycle: CookbookPreppedCycle?
    @State private var isImportQueuePresented = false
    @State private var importQueueInitialTab: SharedRecipeImportQueueTab?
    @State private var isSavedSearchExpanded = false
    @State private var savedSearchKeyboardHeight: CGFloat = 0
    @State private var previousSelectedSection: CookbookSection = .prepped
    @State private var sectionTransitionDirection: CGFloat = 1
    @Namespace private var savedSearchTransitionNamespace

    private let columns = [
        GridItem(.flexible(), spacing: 14, alignment: .top),
        GridItem(.flexible(), spacing: 14, alignment: .top)
    ]

    private var filters: [String] {
        var values = ["All"]
        for value in savedStore.savedRecipes.compactMap(\.filterChipLabel) where !values.contains(value) {
            values.append(value)
        }
        return Array(values.prefix(8))
    }

    private var filteredRecipes: [DiscoverRecipeCardData] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return savedStore.savedRecipes.filter { recipe in
            let matchesFilter = selectedFilter == "All" || recipe.filterChipLabel == selectedFilter
            let matchesQuery = query.isEmpty ||
                recipe.title.lowercased().contains(query) ||
                recipe.authorLabel.lowercased().contains(query) ||
                recipe.filterLabel.lowercased().contains(query)
            return matchesFilter && matchesQuery
        }
    }

    private var upcomingCycle: CookbookPreppedCycle? {
        guard let latestPlan = store.latestPlan, !latestPlan.recipes.isEmpty else { return nil }
        return CookbookPreppedCycle(
            id: latestPlan.id.uuidString,
            title: "Next cycle",
            detail: prepDateLabel(for: latestPlan),
            prepDateLabel: prepShortDateLabel(for: latestPlan),
            prepDateRangeLabel: prepDateRangeLabel(for: latestPlan),
            recipes: latestPlan.recipes.map(DiscoverRecipeCardData.init(preppedRecipe:))
        )
    }

    private var previousCycles: [CookbookPreppedCycle] {
        store.completedMealPrepCycles.compactMap { cycle -> CookbookPreppedCycle? in
            let plan = cycle.plan
            guard !plan.recipes.isEmpty else { return nil }
            return CookbookPreppedCycle(
                id: cycle.planID.uuidString,
                title: (cycle.completedAtDate ?? plan.periodEnd).formatted(.dateTime.month(.wide).day()),
                detail: prepDateLabel(for: plan),
                prepDateLabel: prepShortDateLabel(for: plan),
                prepDateRangeLabel: prepDateRangeLabel(for: plan),
                recipes: plan.recipes.map(DiscoverRecipeCardData.init(preppedRecipe:))
            )
        }
    }

    private func prepDateLabel(for plan: MealPlan) -> String {
        plan.periodStart.formatted(.dateTime.weekday(.wide).month(.wide).day())
    }

    private func prepShortDateLabel(for plan: MealPlan) -> String {
        plan.periodStart.formatted(.dateTime.month(.abbreviated).day())
    }

    private func prepDateRangeLabel(for plan: MealPlan) -> String {
        let start = plan.periodStart.formatted(.dateTime.month(.abbreviated).day())
        let end = plan.periodEnd.formatted(.dateTime.month(.abbreviated).day())
        return "\(start) - \(end)"
    }

    private var sectionTabs: [CookbookSectionTabItem] {
        [
            CookbookSectionTabItem(section: .prepped),
            CookbookSectionTabItem(section: .saved)
        ]
    }

    private var hasSavedRecipes: Bool {
        !savedStore.savedRecipes.isEmpty
    }

    private var activeImportProgressItem: SharedRecipeImportEnvelope? {
        sharedImportInbox.envelopes.first(where: \.isLiveQueueState)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 18) {
                cookbookHeader

                CookbookSectionTabs(
                    selection: $selectedSection,
                    tabs: sectionTabs
                )
                .zIndex(20)
            }
            .padding(.horizontal, OunjeLayout.screenHorizontalPadding)
            .padding(.top, 14)
            .padding(.bottom, 10)

            cookbookFeedScroll
        }
        .background(OunjePalette.background.ignoresSafeArea())
        .overlay(alignment: .bottom) {
            if selectedSection == .saved {
                savedSearchDock
                    .frame(maxWidth: 360, alignment: .center)
                    .padding(.horizontal, OunjeLayout.screenHorizontalPadding)
                    .padding(.bottom, max(12, savedSearchKeyboardHeight > 0 ? savedSearchKeyboardHeight + 16 : 12))
                    .offset(y: savedSearchKeyboardOffset)
                    .zIndex(30)
            }
        }
        .animation(OunjeMotion.screenSpring, value: isSavedSearchExpanded)
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { notification in
            updateSavedSearchKeyboardHeight(from: notification)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            withAnimation(OunjeMotion.screenSpring) {
                savedSearchKeyboardHeight = 0
            }
        }
        .task(id: selectedSection == .saved ? (store.authSession?.userID ?? "guest") : "cookbook-idle") {
            guard selectedSection == .saved else { return }
            await savedStore.bootstrap(authSession: store.authSession)
        }
        .task(id: "recipe-import-history::\(store.authSession?.userID ?? "signed-out")") {
            await recipeImportHistory.refresh(userID: store.authSession?.userID)
        }
        .onReceive(NotificationCenter.default.publisher(for: .recipeImportHistoryNeedsRefresh)) { _ in
            Task {
                await onRefreshSharedImports()
            }
        }
        .onAppear {
            openRequestedCycleIfNeeded()
            presentRequestedImportQueueIfNeeded()
            presentRequestedImportComposerIfNeeded()
        }
        .onChange(of: requestedImportQueueTab) { _ in
            presentRequestedImportQueueIfNeeded()
        }
        .onChange(of: requestedImportText) { _ in
            presentRequestedImportComposerIfNeeded()
        }
        .sheet(isPresented: $isComposerPresented) {
            DiscoverComposerSheet(context: composerContext, initialText: composerInitialText)
                .presentationDetents([.fraction(0.5)])
                .presentationDragIndicator(.hidden)
                .onDisappear {
                    composerInitialText = nil
                }
        }
        .sheet(isPresented: $isImportQueuePresented) {
            SharedRecipeImportQueueSheet(
                items: sharedImportInbox.envelopes,
                historyStore: recipeImportHistory,
                initialTab: importQueueInitialTab,
                onOpenRecipe: { recipe in
                    onSelectRecipe(recipe)
                },
                onRefreshAll: {
                    Task {
                        await onRefreshSharedImports()
                    }
                    isImportQueuePresented = false
                },
                onRetryFailed: {
                    onRetryFailedSharedImports()
                    isImportQueuePresented = false
                },
                onDeleteFailed: { envelopeID in
                    try? SharedRecipeImportInbox.delete(envelopeID: envelopeID)
                    Task {
                        await onRefreshSharedImports()
                    }
                }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.hidden)
        }
        .fullScreenCover(item: $selectedCycle) { cycle in
            CookbookCyclePage(
                cycle: cycle,
                selectedTab: $selectedTab,
                toastCenter: toastCenter
            )
        }
        .onChange(of: requestedCycleID) { _ in
            openRequestedCycleIfNeeded()
        }
        .onChange(of: selectedSection) { newValue in
            let previousSection = previousSelectedSection
            sectionTransitionDirection = newValue.motionIndex >= previousSection.motionIndex ? 1 : -1
            previousSelectedSection = newValue
            guard newValue != .saved,
                  searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                return
            }
            withAnimation(OunjeMotion.screenSpring) {
                isSavedSearchExpanded = false
            }
        }
        .onChange(of: searchText) { newValue in
            if newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                withAnimation(OunjeMotion.screenSpring) {
                    isSavedSearchExpanded = false
                }
            }
        }
    }

    @ViewBuilder
    private var cookbookFeedScroll: some View {
        if selectedSection == .saved {
            ScrollView {
                cookbookFeedContent
            }
            .scrollIndicators(.hidden)
            .refreshable {
                await refreshSavedCookbookFeed()
            }
        } else {
            ScrollView {
                cookbookFeedContent
            }
            .scrollIndicators(.hidden)
        }
    }

    private var cookbookFeedContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            activeImportTracker

            ZStack(alignment: .topLeading) {
                currentSectionContent
                    .id(selectedSection)
                    .transition(cookbookSectionTransition)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .animation(OunjeMotion.screenSpring, value: selectedSection)
    }
    .padding(.horizontal, OunjeLayout.screenHorizontalPadding)
    .padding(.top, 0)
    .padding(.bottom, 24)
}

    private var cookbookHeader: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                BiroScriptDisplayText("Cookbook", size: 30, color: OunjePalette.primaryText)
                Text(selectedSection.subtitle)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(OunjePalette.secondaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.92)
            }

            Spacer(minLength: 0)

            Button {
                openImportQueue()
            } label: {
                PulsingTrayIcon(
                    count: sharedImportInbox.badgeCount,
                    isPulsing: sharedImportInbox.queuedCount > 0
                )
            }
            .buttonStyle(.plain)

            Button {
                openComposer(context: selectedSection == .prepped ? .prepped : .saved)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 14, weight: .bold))
                    Text("Import")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                }
                .foregroundStyle(OunjePalette.primaryText)
                .padding(.horizontal, 14)
                .frame(height: 42)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(OunjePalette.surface)
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(OunjePalette.stroke, lineWidth: 1)
                        )
                )
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private var activeImportTracker: some View {
        if let activeImportProgressItem {
            SharedRecipeImportProgressCard(
                item: activeImportProgressItem,
                onTap: { openImportQueue() }
            )
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    @ViewBuilder
    private var currentSectionContent: some View {
        switch selectedSection {
        case .prepped:
            preppedSection
        case .saved:
            savedSection
        }
    }

    private var cookbookSectionTransition: AnyTransition {
        let insertionOffset: CGFloat = sectionTransitionDirection >= 0 ? 30 : -30
        let removalOffset: CGFloat = sectionTransitionDirection >= 0 ? -14 : 14

        return .asymmetric(
            insertion: .modifier(
                active: DirectionalSurfaceRevealModifier(
                    xOffset: insertionOffset,
                    yOffset: 8,
                    scale: 0.988,
                    blur: 8,
                    opacity: 0.001
                ),
                identity: DirectionalSurfaceRevealModifier()
            ),
            removal: .modifier(
                active: DirectionalSurfaceRevealModifier(
                    xOffset: removalOffset,
                    yOffset: -4,
                    scale: 0.994,
                    blur: 5,
                    opacity: 0.001
                ),
                identity: DirectionalSurfaceRevealModifier()
            )
        )
    }

    @ViewBuilder
    private var savedSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            if filters.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 22) {
                        ForEach(filters, id: \.self) { filter in
                            DiscoverPresetTextButton(
                                title: filter,
                                isSelected: selectedFilter == filter
                            ) {
                                selectedFilter = filter
                            }
                        }
                    }
                    .padding(.horizontal, 2)
                    .padding(.vertical, 2)
                }
            }

            if filteredRecipes.isEmpty {
                CookbookSavedEmptyState(
                    hasSavedRecipes: !savedStore.savedRecipes.isEmpty,
                    onBrowseDiscover: { selectedTab = .discover },
                    onAddRecipe: {
                        openComposer(context: .saved)
                    }
                )
            } else {
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(filteredRecipes) { recipe in
                        DiscoverRemoteRecipeCard(
                            recipe: recipe,
                            transitionNamespace: recipeTransitionNamespace
                        ) {
                            onSelectRecipe(recipe)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var savedSearchDock: some View {
        if isSavedSearchExpanded || !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                SavedRecipesSearchField(
                    text: $searchText,
                    placeholder: "Search saved recipes",
                    isExpanded: $isSavedSearchExpanded,
                    transitionNamespace: savedSearchTransitionNamespace
                )
                .frame(maxWidth: 360)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                Spacer(minLength: 0)
            }
        } else {
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                FloatingSavedSearchButton(
                    isActive: false,
                    transitionNamespace: savedSearchTransitionNamespace
                ) {
                    withAnimation(OunjeMotion.screenSpring) {
                        isSavedSearchExpanded = true
                    }
                }
                .transition(.scale.combined(with: .opacity))
            }
        }
    }

    private var savedSearchKeyboardOffset: CGFloat {
        guard savedSearchKeyboardHeight > 0 else { return 0 }
        return -(savedSearchKeyboardHeight - 16)
    }

    private func updateSavedSearchKeyboardHeight(from notification: Notification) {
        guard let userInfo = notification.userInfo else { return }

        let endFrame = (userInfo[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue ?? .zero
        guard endFrame.height > 0 else { return }

        let screenHeight = UIScreen.main.bounds.height
        let keyboardHeight = max(0, screenHeight - endFrame.minY)
        withAnimation(OunjeMotion.screenSpring) {
            savedSearchKeyboardHeight = keyboardHeight
        }
    }

    private func refreshSavedCookbookFeed() async {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        await savedStore.refreshFromRemote(authSession: store.authSession, force: true)
    }

    @ViewBuilder
    private var preppedSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            if upcomingCycle == nil && previousCycles.isEmpty {
                CookbookPreppedEmptyState(
                    title: "No prep meals yet",
                    detail: "Once Ounje builds a cycle, the meals you’re cooking next and the ones you’ve already run will live here.",
                    symbolName: "fork.knife.circle"
                )
            } else {
                if let upcomingCycle {
                    CookbookCycleGroup(
                        title: nil,
                        subtitle: upcomingCycle.detail,
                        cycles: [upcomingCycle],
                        showsRowMetadata: false,
                        onSelectCycle: { selectedCycle = $0 }
                    )
                }

                if !previousCycles.isEmpty {
                    CookbookCycleGroup(
                        title: "Previous cycles",
                        cycles: previousCycles,
                        onSelectCycle: { selectedCycle = $0 }
                    )
                }
            }
        }
    }

    private func openRequestedCycleIfNeeded() {
        guard let requestedCycleID, !requestedCycleID.isEmpty else { return }

        if let upcomingCycle, upcomingCycle.id == requestedCycleID {
            selectedSection = .prepped
            selectedCycle = upcomingCycle
            self.requestedCycleID = nil
            return
        }

        if let matchedPreviousCycle = previousCycles.first(where: { $0.id == requestedCycleID }) {
            selectedSection = .prepped
            selectedCycle = matchedPreviousCycle
            self.requestedCycleID = nil
        }
    }

    private func openImportQueue(initialTab: SharedRecipeImportQueueTab? = nil) {
        importQueueInitialTab = initialTab
        Task {
            await onRefreshSharedImports()
        }
        isImportQueuePresented = true
    }

    private func openComposer(context: CookbookComposerContext, initialText: String? = nil) {
        composerContext = context
        composerInitialText = initialText
        isComposerPresented = true
    }

    private func presentRequestedImportQueueIfNeeded() {
        guard let tab = requestedImportQueueTab else { return }
        openImportQueue(initialTab: tab)
        requestedImportQueueTab = nil
    }

    private func presentRequestedImportComposerIfNeeded() {
        guard let text = requestedImportText?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return
        }
        selectedSection = .saved
        openComposer(context: .saved, initialText: text)
        requestedImportText = nil
    }
}

enum SharedRecipeImportQueueTab: String, CaseIterable, Identifiable {
    case queued = "Queued"
    case failed = "Failed"
    case completed = "Completed"

    var id: String { rawValue }
}

private struct SharedRecipeImportQueueSheet: View {
    let items: [SharedRecipeImportEnvelope]
    @ObservedObject var historyStore: RecipeImportHistoryStore
    let initialTab: SharedRecipeImportQueueTab?
    let onOpenRecipe: (DiscoverRecipeCardData) -> Void
    let onRefreshAll: () -> Void
    let onRetryFailed: () -> Void
    let onDeleteFailed: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selectedTab: SharedRecipeImportQueueTab = .queued
    @State private var revealedCompletedImportIDs: Set<String> = []
    @State private var hasInitializedCompletedReveal = false

    private var queuedItems: [SharedRecipeImportEnvelope] {
        items.filter(\.isLiveQueueState)
    }

    private var failedItems: [SharedRecipeImportEnvelope] {
        items.filter(\.isRetryNeeded)
    }

    private var queuedTabCount: Int {
        queuedItems.count
    }

    private var failedTabCount: Int {
        failedItems.count
    }

    private var shouldShowFooter: Bool {
        selectedTab == .queued || selectedTab == .failed
    }

    private var activeProgressItem: SharedRecipeImportEnvelope? {
        queuedItems.first
    }

    private var footerButtonTitle: String {
        switch selectedTab {
        case .queued:
            return "Refresh imports"
        case .failed:
            return failedItems.isEmpty ? "Refresh imports" : "Retry imports"
        case .completed:
            return "Refresh imports"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            tabBar

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if selectedTab == .queued, let activeProgressItem {
                        SharedRecipeImportProgressCard(item: activeProgressItem, onTap: nil)
                    }
                    subtitle
                    content
                }
                .padding(.horizontal, 18)
                .padding(.top, 12)
                .padding(.bottom, shouldShowFooter ? 120 : 28)
            }
            .scrollIndicators(.hidden)
        }
        .background(OunjePalette.background.ignoresSafeArea())
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if shouldShowFooter {
                retryFooter
            }
        }
        .onAppear {
            if let initialTab {
                selectedTab = initialTab
            } else if !queuedItems.isEmpty {
                selectedTab = .queued
            } else if !failedItems.isEmpty {
                selectedTab = .failed
            } else if !historyStore.completedItems.isEmpty {
                selectedTab = .completed
            }
            initializeCompletedRevealIfNeeded()
        }
        .onChange(of: completedImportRevealKey) { _ in
            revealNewCompletedImports()
        }
    }

    private var header: some View {
        HStack(alignment: .center) {
            Text("Recipe imports")
                .sleeDisplayFont(30)
                .foregroundStyle(OunjePalette.primaryText)

            Spacer(minLength: 0)

            Button("Done") { dismiss() }
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(OunjePalette.secondaryText)
        }
        .padding(.horizontal, 18)
        .padding(.top, 18)
        .padding(.bottom, 8)
    }

    private var tabBar: some View {
        HStack(spacing: 10) {
            ForEach(SharedRecipeImportQueueTab.allCases) { tab in
                Button {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.9)) {
                        selectedTab = tab
                    }
                } label: {
                    HStack(spacing: 8) {
                        Text(tab.rawValue)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .fixedSize(horizontal: true, vertical: false)
                        if tab == .queued, queuedTabCount > 0 {
                            countBadge(queuedTabCount, isSelected: selectedTab == tab)
                        } else if tab == .failed, failedTabCount > 0 {
                            countBadge(failedTabCount, isSelected: selectedTab == tab)
                        } else if tab == .completed, historyStore.completedCount > 0 {
                            countBadge(historyStore.completedCount, isSelected: selectedTab == tab)
                        }
                    }
                    .foregroundStyle(selectedTab == tab ? OunjePalette.primaryText : OunjePalette.secondaryText)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        Capsule(style: .continuous)
                            .fill(selectedTab == tab ? OunjePalette.surface : OunjePalette.surface.opacity(0.5))
                    )
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(selectedTab == tab ? OunjePalette.stroke : Color.clear, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 4)
    }

    private var subtitle: some View {
        Group {
            if selectedTab == .queued {
                Text("Queued shares live here until Ounje finishes pulling them in.")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(OunjePalette.secondaryText)
            } else if selectedTab == .failed {
                Text("Imports that timed out or need another pass live here until you retry them.")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(OunjePalette.secondaryText)
            } else {
                Text("Completed imports live here so you can trace what already made it through.")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(OunjePalette.secondaryText)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var content: some View {
        if selectedTab == .queued {
            if queuedItems.isEmpty {
                emptyState(
                    title: "No imports waiting",
                    detail: "Fresh shares will show up here while Ounje is pulling and parsing them."
                )
            } else {
                    VStack(spacing: 12) {
                        ForEach(queuedItems) { item in
                            SharedRecipeImportQueueRow(item: item, onDelete: nil)
                        }
                    }
            }
        } else if selectedTab == .failed {
            if failedItems.isEmpty {
                emptyState(
                    title: "No failed imports",
                    detail: "If a share needs another pass, it will land here with the retry reason."
                )
                } else {
                    VStack(spacing: 12) {
                        ForEach(failedItems) { item in
                            SharedRecipeImportQueueRow(
                                item: item,
                                onDelete: {
                                    onDeleteFailed(item.id)
                                }
                            )
                        }
                    }
                }
        } else {
            if historyStore.completedItems.isEmpty {
                emptyState(
                    title: "No completed imports yet",
                    detail: "Once Ounje finishes a shared recipe cleanly, it will show up here."
                )
            } else {
                VStack(spacing: 12) {
                    ForEach(Array(historyStore.completedItems.enumerated()), id: \.element.id) { index, item in
                        RecipeImportCompletedRow(
                            item: item,
                            onOpenRecipe: { recipe in
                                onOpenRecipe(recipe)
                            }
                        )
                        .modifier(
                            StaggeredRevealModifier(
                                isVisible: revealedCompletedImportIDs.contains(item.id),
                                delay: Double(index) * 0.045,
                                yOffset: 12
                            )
                        )
                    }
                }
            }
        }
    }

    private var completedImportRevealKey: String {
        historyStore.completedItems.map(\.id).joined(separator: "|")
    }

    private func initializeCompletedRevealIfNeeded() {
        guard !hasInitializedCompletedReveal else { return }
        revealedCompletedImportIDs = Set(historyStore.completedItems.map(\.id))
        hasInitializedCompletedReveal = true
    }

    private func revealNewCompletedImports() {
        guard hasInitializedCompletedReveal else {
            initializeCompletedRevealIfNeeded()
            return
        }

        let missingIDs = historyStore.completedItems
            .map(\.id)
            .filter { !revealedCompletedImportIDs.contains($0) }

        guard !missingIDs.isEmpty else { return }

        for (index, id) in missingIDs.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * 0.055) {
                withAnimation(.spring(response: 0.36, dampingFraction: 0.86)) {
                    _ = revealedCompletedImportIDs.insert(id)
                }
            }
        }
    }

    private var retryFooter: some View {
        VStack(spacing: 0) {
            Divider()
                .overlay(OunjePalette.stroke)

            Button {
                if selectedTab == .failed, !failedItems.isEmpty {
                    onRetryFailed()
                } else {
                    onRefreshAll()
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.clockwise")
                    Text(footerButtonTitle)
                        .biroHeaderFont(17)
                }
                .foregroundStyle(OunjePalette.softCream)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(OunjePalette.panel.opacity(0.96))
                        .overlay(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .stroke(OunjePalette.accent.opacity(0.22), lineWidth: 1)
                        )
                )
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 18)
            .padding(.top, 12)
            .padding(.bottom, 14)
            .background(OunjePalette.background)
        }
    }

    private func emptyState(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(OunjePalette.primaryText)
            Text(detail)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(OunjePalette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(OunjePalette.surface.opacity(0.94))
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(OunjePalette.stroke, lineWidth: 1)
                )
        )
    }

    private func countBadge(_ count: Int, isSelected: Bool) -> some View {
        Text("\(count)")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(isSelected ? OunjePalette.background : OunjePalette.primaryText)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule(style: .continuous)
                    .fill(isSelected ? OunjePalette.accent : OunjePalette.stroke)
            )
    }
}

private enum InstacartRunHistoryView: String, CaseIterable, Identifiable {
    case current = "Current"
    case historic = "Historic"

    var id: String { rawValue }

    var label: String { rawValue }
}

private enum InstacartRunDisplayMode {
    case current
    case historic
}

private struct InstacartRunDateSection: Identifiable {
    let date: Date
    let runs: [InstacartRunLogSummary]

    var id: String {
        String(date.timeIntervalSince1970)
    }
}

private enum InstacartRunDateParser {
    private static let fractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let standardFormatter: ISO8601DateFormatter = {
        ISO8601DateFormatter()
    }()

    static func parse(_ raw: String?) -> Date? {
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        if let parsed = fractionalFormatter.date(from: raw) {
            return parsed
        }
        return standardFormatter.date(from: raw)
    }
}

struct InstacartRunLogsSheet: View {
    @ObservedObject var store: InstacartRunLogsStore
    @ObservedObject var mealStore: MealPlanningAppStore
    let userID: String?
    let accessToken: String?
    let onRerun: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var historyView: InstacartRunHistoryView = .current

    private var titleLine: String {
        if store.isLoading && store.runs.isEmpty {
            return "Loading Instacart runs"
        }
        if visibleRunCount == 1 {
            return historyView == .current ? "1 current run" : "1 historic run"
        }
        return historyView == .current ? "\(visibleRunCount) current runs" : "\(visibleRunCount) historic runs"
    }

    private var authStateKey: String {
        [
            userID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            accessToken?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        ]
        .joined(separator: "::")
    }

    private var currentPlanID: String? {
        mealStore.latestPlan?.id.uuidString
    }

    private var latestMealStoreCurrentRun: InstacartRunLogSummary? {
        guard let run = mealStore.latestInstacartRun else { return nil }
        let retryState = run.normalizedRetryState
        let isLiveState = run.normalizedStatusKind == "running" || retryState == "queued" || retryState == "running"
        let isCleanCompletion = run.normalizedStatusKind == "completed"
            && run.unresolvedCount == 0
            && run.shortfallCount == 0
            && run.success
            && !run.partialSuccess
        return (isLiveState || isCleanCompletion) ? run : nil
    }

    private func batchRootID(for run: InstacartRunLogSummary) -> String {
        let root = run.rootRunID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return root.isEmpty ? run.runId.trimmingCharacters(in: .whitespacesAndNewlines) : root
    }

    private func representativeRun(from runs: [InstacartRunLogSummary]) -> InstacartRunLogSummary? {
        runs.sorted { left, right in
            let leftWeight = currentRunSummaryWeight(left)
            let rightWeight = currentRunSummaryWeight(right)
            if leftWeight != rightWeight {
                return leftWeight > rightWeight
            }
            return runDate(left) > runDate(right)
        }.first
    }

    private func isSupersededRun(_ run: InstacartRunLogSummary) -> Bool {
        let title = run.latestEventTitle?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let kind = run.latestEventKind?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        return run.normalizedStatusKind == "superseded"
            || kind == "run_superseded"
            || title == "run superseded"
    }

    private func isCleanCompletedRun(_ run: InstacartRunLogSummary) -> Bool {
        run.normalizedStatusKind == "completed"
            && run.success
            && !run.partialSuccess
            && run.unresolvedCount == 0
            && run.shortfallCount == 0
    }

    private var currentPrepRuns: [InstacartRunLogSummary] {
        guard let currentPlanID else { return [] }
        return store.runs
            .filter {
                !isSupersededRun($0)
                    && normalizedPlanID($0.mealPlanID) == normalizedPlanID(currentPlanID)
            }
            .sorted { left, right in
                let leftWeight = currentRunSummaryWeight(left)
                let rightWeight = currentRunSummaryWeight(right)
                if leftWeight != rightWeight {
                    return leftWeight > rightWeight
                }
                return runDate(left) > runDate(right)
            }
    }

    private var currentPrepCleanCompletedRun: InstacartRunLogSummary? {
        currentPrepRuns.first(where: isCleanCompletedRun)
    }

    private var currentPrepHasLiveRun: Bool {
        if currentPrepCleanCompletedRun != nil {
            return false
        }
        return currentPrepRuns.contains {
            $0.normalizedStatusKind == "running"
                || ["queued", "running"].contains($0.normalizedRetryState)
                || $0.normalizedStatusKind == "partial"
        }
    }

    private var currentBatchRootID: String? {
        if !currentPrepRuns.isEmpty {
            return nil
        }

        if let anchoredRun = latestMealStoreCurrentRun {
            return batchRootID(for: anchoredRun)
        }

        if let running = representativeRun(from: store.runs.filter({
            !isSupersededRun($0)
                && ($0.normalizedStatusKind == "running" || ["queued", "running"].contains($0.normalizedRetryState))
        })) {
            return batchRootID(for: running)
        }

        if let completed = representativeRun(from: store.runs.filter({
            !isSupersededRun($0)
            &&
            $0.normalizedStatusKind == "completed"
            && $0.unresolvedCount == 0
            && $0.shortfallCount == 0
        })) {
            return batchRootID(for: completed)
        }

        if let currentPlanID {
            let matchingRuns = store.runs.filter {
                !isSupersededRun($0)
                    && normalizedPlanID($0.mealPlanID) == normalizedPlanID(currentPlanID)
            }
            if let primary = representativeRun(from: matchingRuns) {
                return batchRootID(for: primary)
            }
        }

        return nil
    }

    private var currentRunningRunID: String? {
        store.runs
            .filter { !isSupersededRun($0) && $0.normalizedStatusKind == "running" }
            .sorted { left, right in
                let leftWeight = currentRunSummaryWeight(left)
                let rightWeight = currentRunSummaryWeight(right)
                if leftWeight != rightWeight {
                    return leftWeight > rightWeight
                }
                return runDate(left) > runDate(right)
            }
            .first?
            .runId
    }

    private var currentRuns: [InstacartRunLogSummary] {
        if !currentPrepRuns.isEmpty {
            if currentPrepHasLiveRun {
                return currentPrepRuns
            }
            if let cleanCompleted = currentPrepCleanCompletedRun {
                return [cleanCompleted]
            }
            if let representative = representativeRun(from: currentPrepRuns) {
                return [representative]
            }
        }

        let visibleRuns = store.runs.filter { !isSupersededRun($0) && isCurrentVisible($0) }
        guard !visibleRuns.isEmpty else {
            return []
        }

        if let currentBatchRootID {
            return visibleRuns
                .filter { batchRootID(for: $0) == currentBatchRootID }
                .sorted { left, right in
                    let leftWeight = currentRunSummaryWeight(left)
                    let rightWeight = currentRunSummaryWeight(right)
                    if leftWeight != rightWeight {
                        return leftWeight > rightWeight
                    }
                    return runDate(left) > runDate(right)
                }
        }

        if let currentRunningRunID,
           let runningRun = visibleRuns.first(where: { $0.runId == currentRunningRunID }) {
            return [runningRun]
        }

        return visibleRuns
            .sorted { left, right in
                switch (left.normalizedStatusKind == "running", right.normalizedStatusKind == "running") {
                case (true, false):
                    return true
                case (false, true):
                    return false
                default:
                    return runDate(left) > runDate(right)
                }
            }
            .prefix(1)
            .map { $0 }
    }

    private var visibleResolvedCount: Int {
        switch historyView {
        case .current:
            return currentRuns.reduce(0) { $0 + $1.resolvedCount }
        case .historic:
            return historicSections.reduce(0) { partialResult, section in
                partialResult + section.runs.reduce(0) { $0 + $1.resolvedCount }
            }
        }
    }

    private var visibleIssueCount: Int {
        switch historyView {
        case .current:
            return currentRuns.reduce(0) { partialResult, run in
                partialResult + run.unresolvedCount + run.shortfallCount
            }
        case .historic:
            return historicSections.reduce(0) { partialResult, section in
                partialResult + section.runs.reduce(0) { $0 + $1.unresolvedCount + $1.shortfallCount }
            }
        }
    }

    private var historicSections: [InstacartRunDateSection] {
        let runs = store.runs.filter { isHistoricVisible($0) }
        let grouped = Dictionary(grouping: runs) { run in
            Calendar.current.startOfDay(for: runDate(run))
        }

        return grouped
            .map { date, value in
                InstacartRunDateSection(
                    date: date,
                    runs: value.sorted { runDate($0) > runDate($1) }
                )
            }
            .sorted { $0.date > $1.date }
    }

    private var visibleRunCount: Int {
        switch historyView {
        case .current:
            return currentRuns.count
        case .historic:
            return historicSections.reduce(0) { $0 + $1.runs.count }
        }
    }

    private var hasVisibleRuns: Bool {
        switch historyView {
        case .current:
            return !currentRuns.isEmpty
        case .historic:
            return !historicSections.isEmpty
        }
    }

    private func isCurrentVisible(_ run: InstacartRunLogSummary) -> Bool {
        if !currentPrepRuns.isEmpty {
            if currentPrepHasLiveRun {
                return currentPrepRuns.contains(where: { $0.runId == run.runId })
            }
            if let cleanCompleted = currentPrepCleanCompletedRun {
                return run.runId == cleanCompleted.runId
            }
            if let representative = representativeRun(from: currentPrepRuns) {
                return run.runId == representative.runId
            }
        }

        if let currentBatchRootID {
            return batchRootID(for: run) == currentBatchRootID
        }
        return run.runId == currentRunningRunID
    }

    private func normalizedPlanID(_ value: String?) -> String {
        String(value ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private func isHistoricVisible(_ run: InstacartRunLogSummary) -> Bool {
        !isSupersededRun(run) && !isCurrentVisible(run)
    }

    private func currentRunSummaryWeight(_ run: InstacartRunLogSummary) -> Int {
        var weight = 0
        if run.success && !run.partialSuccess && run.unresolvedCount == 0 && run.shortfallCount == 0 {
            weight += 8
        }
        if run.selectedStore?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            weight += 4
        }
        if run.normalizedRetryState == "running" {
            weight += 5
        } else if run.normalizedStatusKind == "running" {
            weight += 4
        } else if run.normalizedRetryState == "queued" {
            weight += 3
        }
        if run.itemCount > 0 {
            weight += 3
        }
        if run.resolvedCount > 0 {
            weight += 2
        }
        if run.unresolvedCount > 0 || run.shortfallCount > 0 {
            weight += 1
        }
        if run.completedAt != nil {
            weight += 1
        }
        if run.normalizedStatusKind == "failed" || run.normalizedStatusKind == "superseded" {
            weight -= 4
        }
        return weight
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 8) {
                        SleeScriptDisplayText("Instacart runs", size: 29)
                            .foregroundStyle(OunjePalette.primaryText)
                        Text("Current runs update live. Historic runs keep the completed trace history.")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(OunjePalette.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    viewToggle

                    HStack(spacing: 10) {
                        Text(titleLine)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(OunjePalette.primaryText)
                        Spacer(minLength: 0)
                        Button {
                            onRerun()
                            Task {
                                try? await Task.sleep(nanoseconds: 650_000_000)
                                await refreshLogs()
                            }
                        } label: {
                            HStack(spacing: 6) {
                                if mealStore.isManualAutoshopRunning {
                                    ProgressView()
                                        .controlSize(.small)
                                        .tint(OunjePalette.background)
                                } else {
                                    Image(systemName: "arrow.clockwise")
                                        .font(.system(size: 11, weight: .bold))
                                }

                                Text(mealStore.isManualAutoshopRunning ? "Rerunning" : "Rerun")
                                    .font(.system(size: 12, weight: .bold))
                            }
                            .foregroundStyle(OunjePalette.background)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 7)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(OunjePalette.accent)
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(mealStore.isManualAutoshopRunning || currentPrepHasLiveRun)
                        .opacity((mealStore.isManualAutoshopRunning || currentPrepHasLiveRun) ? 0.58 : 1)
                    }

                    HStack(spacing: 8) {
                        summaryChip(
                            title: historyView == .current ? "Current" : "Historic",
                            value: "\(visibleRunCount)"
                        )
                        summaryChip(title: "Resolved", value: "\(visibleResolvedCount)")
                        summaryChip(title: "Issues", value: "\(visibleIssueCount)")
                        Spacer(minLength: 0)
                    }

                    if store.isLoading && store.runs.isEmpty {
                        loadingState
                    } else if let errorMessage = store.errorMessage, store.runs.isEmpty {
                        errorState(errorMessage)
                    } else if !hasVisibleRuns {
                        emptyState
                    } else {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            if historyView == .current {
                                sectionHeader("Current runs")
                                LazyVStack(spacing: 12) {
                                    ForEach(Array(currentRuns.enumerated()), id: \.element.id) { index, run in
                                        NavigationLink(value: run.runId) {
                                            InstacartRunLogRow(
                                                run: run,
                                                displayMode: .current
                                            )
                                        }
                                        .buttonStyle(.plain)

                                        if index == currentRuns.count - 1, store.hasMore {
                                            Color.clear
                                                .frame(height: 1)
                                                .task {
                                                    await store.loadMore()
                                                }
                                        }
                                    }
                                }
                            } else {
                                LazyVStack(alignment: .leading, spacing: 16) {
                                    ForEach(historicSections) { section in
                                        VStack(alignment: .leading, spacing: 12) {
                                            historicSectionHeader(section.date, count: section.runs.count)
                                            LazyVStack(spacing: 12) {
                                                ForEach(Array(section.runs.enumerated()), id: \.element.id) { index, run in
                                                    NavigationLink(value: run.runId) {
                                                        InstacartRunLogRow(run: run, displayMode: .historic)
                                                    }
                                                    .buttonStyle(.plain)

                                                    if index == section.runs.count - 1,
                                                       store.hasMore,
                                                       section.id == historicSections.last?.id {
                                                        Color.clear
                                                            .frame(height: 1)
                                                            .task {
                                                                await store.loadMore()
                                                            }
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }

                            if store.isLoadingMore {
                                ProgressView()
                                    .tint(OunjePalette.secondaryText)
                                    .frame(maxWidth: .infinity, alignment: .center)
                                    .padding(.vertical, 10)
                            }
                        }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 18)
                .padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)
            .background(OunjePalette.background.ignoresSafeArea())
            .navigationDestination(for: String.self) { runID in
                InstacartRunLogDetailView(runID: runID, userID: userID, accessToken: accessToken)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(OunjePalette.secondaryText)
                }
            }
        }
        .task(id: authStateKey) {
            await refreshLogs()
        }
        .task(id: "\(authStateKey)::\(historyView.rawValue)") {
            await refreshLogs()
            guard historyView == .current else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                guard !Task.isCancelled else { return }
                await refreshLogs()
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 15, weight: .bold))
            .foregroundStyle(OunjePalette.primaryText)
            .textCase(.uppercase)
            .kerning(0.6)
            .padding(.leading, 4)
    }

    private func historicSectionHeader(_ date: Date, count: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(date.formatted(date: .abbreviated, time: .omitted))
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(OunjePalette.primaryText)
                Text("\(count) completed")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(OunjePalette.secondaryText)
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 4)
    }

    private var viewToggle: some View {
        HStack(spacing: 10) {
            ForEach(InstacartRunHistoryView.allCases) { view in
                Button {
                    historyView = view
                } label: {
                    VStack(spacing: 6) {
                        Text(view.label)
                            .sleeDisplayFont(16)
                            .foregroundStyle(historyView == view ? OunjePalette.softCream : OunjePalette.secondaryText)
                        RoundedRectangle(cornerRadius: 1, style: .continuous)
                            .fill(historyView == view ? OunjePalette.accent : Color.clear)
                            .frame(width: 28, height: 3)
                    }
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
    }

    private func summaryChip(title: String, value: String) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(OunjePalette.secondaryText)
                .textCase(.uppercase)
            Text(value)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(OunjePalette.primaryText)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule(style: .continuous)
                .fill(OunjePalette.surface.opacity(0.9))
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(OunjePalette.stroke.opacity(0.75), lineWidth: 1)
                )
        )
    }

    private func runDate(_ run: InstacartRunLogSummary) -> Date {
        let raw = run.completedAt ?? run.startedAt ?? ""
        return InstacartRunDateParser.parse(raw) ?? .distantPast
    }

    private func refreshLogs() async {
        guard let userID = userID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !userID.isEmpty else {
            await MainActor.run {
                store.markWaitingForAuthentication()
            }
            return
        }

        let token = accessToken?.trimmingCharacters(in: .whitespacesAndNewlines)
        await store.refresh(
            userID: userID,
            accessToken: token,
            query: "",
            status: "all"
        )
    }

    private var loadingState: some View {
        VStack(alignment: .leading, spacing: 14) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(OunjePalette.surface.opacity(0.95))
                .frame(width: 138, height: 18)
                .redacted(reason: .placeholder)

            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(OunjePalette.surface.opacity(0.88))
                .frame(width: 208, height: 12)
                .redacted(reason: .placeholder)

            VStack(spacing: 12) {
                ForEach(0..<3, id: \.self) { index in
                    InstacartRunLogSkeletonRow(seed: index)
                }
            }
        }
    }

    private func errorState(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Couldn’t load logs")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(OunjePalette.primaryText)
            Text(message)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(OunjePalette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(OunjePalette.surface.opacity(0.94))
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(OunjePalette.stroke, lineWidth: 1)
                )
        )
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(historyView == .current ? "No current runs yet" : "No historic runs yet")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(OunjePalette.primaryText)
            Text(historyView == .current ? "Current runs will appear here with their store, item progress, and failure notes." : "Older runs will appear here with their store, item progress, and failure notes.")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(OunjePalette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(OunjePalette.surface.opacity(0.94))
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(OunjePalette.stroke, lineWidth: 1)
                )
        )
    }
}

private struct InstacartRunLogSkeletonRow: View {
    let seed: Int

    private var progressWidth: CGFloat {
        [0.36, 0.54, 0.42][seed % 3]
    }

    private var detailWidth: CGFloat {
        [0.66, 0.58, 0.72][seed % 3]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(OunjePalette.surface.opacity(0.9))
                    .frame(width: 42, height: 42)
                    .redacted(reason: .placeholder)

                VStack(alignment: .leading, spacing: 6) {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(OunjePalette.surface.opacity(0.95))
                        .frame(width: 146, height: 16)
                        .redacted(reason: .placeholder)

                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(OunjePalette.surface.opacity(0.84))
                        .frame(width: 172, height: 11)
                        .redacted(reason: .placeholder)
                }

                Spacer(minLength: 0)

                RoundedRectangle(cornerRadius: 999, style: .continuous)
                    .fill(OunjePalette.surface.opacity(0.88))
                    .frame(width: 58, height: 24)
                    .redacted(reason: .placeholder)
            }

            RoundedRectangle(cornerRadius: 999, style: .continuous)
                .fill(OunjePalette.surface.opacity(0.88))
                .frame(height: 4)
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 999, style: .continuous)
                        .fill(OunjePalette.surface.opacity(0.96))
                        .frame(width: UIScreen.main.bounds.width * progressWidth, height: 4)
                }
                .redacted(reason: .placeholder)

            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(OunjePalette.surface.opacity(0.84))
                .frame(width: UIScreen.main.bounds.width * detailWidth, height: 11)
                .redacted(reason: .placeholder)

            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(OunjePalette.surface.opacity(0.8))
                .frame(width: UIScreen.main.bounds.width * (0.48 + Double(seed % 2) * 0.08), height: 10)
                .redacted(reason: .placeholder)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(OunjePalette.surface.opacity(0.94))
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(OunjePalette.stroke, lineWidth: 1)
                )
        )
    }
}

private struct InstacartRunLogRow: View {
    let run: InstacartRunLogSummary
    let displayMode: InstacartRunDisplayMode
    var statusOverride: String? = nil
    var retryNote: String? = nil

    private var statusTint: Color {
        if let statusOverride {
            switch statusOverride {
            case "Retry running":
                return OunjePalette.accent
            case "Retry queued":
                return Color.orange
            case "Retry skipped":
                return OunjePalette.secondaryText
            case "Retry needs attention":
                return Color.red
            default:
                break
            }
        }
        switch run.normalizedStatusKind {
        case "running":
            return OunjePalette.accent
        case "completed":
            return OunjePalette.accent
        case "partial":
            return Color.orange
        default:
            return Color.red
        }
    }

    private var statusLabel: String {
        if let statusOverride, !statusOverride.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return statusOverride
        }
        switch run.normalizedStatusKind {
        case "running":
            return "Running"
        case "completed":
            return "Completed"
        case "partial":
            return "Partial"
        default:
            return "Failed"
        }
    }

    private var storeLabel: String {
        sanitizedInstacartStoreName(run.selectedStore)
            ?? sanitizedInstacartStoreName(run.preferredStore)
            ?? sanitizedInstacartStoreName(run.strictStore)
            ?? "Instacart run"
    }

    private var storeLogoURL: URL? {
        run.selectedStoreLogoURL
    }

    private var timestampLabel: String {
        let date = InstacartRunDateParser.parse(run.completedAt) ?? InstacartRunDateParser.parse(run.startedAt)
        guard let date else { return "Recently" }
        switch displayMode {
        case .current:
            return run.normalizedStatusKind == "running" ? "Running now" : date.formatted(.relative(presentation: .named))
        case .historic:
            return date.formatted(date: .omitted, time: .shortened)
        }
    }

    private var quickSummary: String {
        let resolved = max(0, run.resolvedCount)
        let unresolved = max(0, run.unresolvedCount)
        if unresolved > 0 {
            return "\(resolved) matched • \(unresolved) unresolved"
        }
        return "\(resolved) matched"
    }

    private var displayedItemCount: Int {
        run.itemCount
    }

    private var statusSummary: String {
        let total = max(displayedItemCount, 1)
        let resolved = max(0, run.resolvedCount)
        let pending = max(0, run.unresolvedCount + run.shortfallCount)

        if let statusOverride {
            switch statusOverride {
            case "Retry queued":
                return "Queued for rerun."
            case "Retry running":
                return "Rerun in progress."
            case "Retry skipped":
                return "Rerun skipped."
            case "Retry needs attention":
                return "Rerun needs attention."
            default:
                break
            }
        }

        switch run.normalizedStatusKind {
        case "running":
            return resolved > 0
                ? "Building cart now: \(resolved) of \(total) items are in."
                : "Building cart now."
        case "completed":
            return "Cart is ready to open."
            case "partial":
                return pending > 0
                    ? "\(run.unresolvedCount) items still need attention."
                    : "Partial checkout is ready."
            default:
                return "Run needs attention before cart completion."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                InstacartStoreBadgeView(
                    storeName: storeLabel,
                    logoURL: storeLogoURL
                )

                VStack(alignment: .leading, spacing: 4) {
                    Text(storeLabel)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(OunjePalette.primaryText)
                        .lineLimit(2)
                    Text("\(timestampLabel) • \(displayedItemCount) items")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(OunjePalette.secondaryText)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                Text(statusLabel)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(OunjePalette.background)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule(style: .continuous)
                            .fill(statusTint)
                )
            }

            ProgressView(value: run.progress)
                .tint(statusTint)

            if let retryNote, !retryNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(retryNote)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(OunjePalette.accent)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(quickSummary)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(OunjePalette.secondaryText)
                .lineLimit(1)

            Text(statusSummary)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(statusTint.opacity(0.92))
                .lineLimit(2)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(OunjePalette.surface.opacity(0.94))
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(OunjePalette.stroke, lineWidth: 1)
                )
        )
    }
}

private struct InstacartStoreBadgeView: View {
    let storeName: String
    let logoURL: URL?

    private var initials: String {
        let words = storeName
            .split(whereSeparator: { $0.isWhitespace || $0 == "-" })
            .prefix(2)
        let value = words.compactMap { $0.first }.map(String.init).joined()
        return value.isEmpty ? "IC" : value.uppercased()
    }

    private var tint: Color {
        switch storeName.replacingOccurrences(of: " ", with: "").lowercased() {
        case let value where value.contains("foodbasics"):
            return Color(red: 0.98, green: 0.55, blue: 0.18)
        case let value where value.contains("metro"):
            return Color(red: 0.85, green: 0.18, blue: 0.18)
        case let value where value.contains("nofrills"):
            return Color(red: 0.95, green: 0.76, blue: 0.11)
        case let value where value.contains("freshco"):
            return Color(red: 0.60, green: 0.76, blue: 0.17)
        case let value where value.contains("walmart"):
            return Color(red: 0.13, green: 0.35, blue: 0.80)
        case let value where value.contains("costco"):
            return Color(red: 0.86, green: 0.19, blue: 0.18)
        case let value where value.contains("sobeys"):
            return Color(red: 0.78, green: 0.21, blue: 0.17)
        case let value where value.contains("loblaws"):
            return Color(red: 0.84, green: 0.18, blue: 0.18)
        default:
            return OunjePalette.accent
        }
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(tint.opacity(0.14))
                .frame(width: 44, height: 44)
            if let logoURL {
                CartCachedArtworkView(imageURL: logoURL) {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(tint.opacity(0.14))
                        .overlay(
                            Text(initials)
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(tint)
                        )
                }
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            } else {
                Text(initials)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(tint)
            }
        }
        .accessibilityLabel(storeName)
    }
}

private struct InstacartRunLogDetailView: View {
    let runID: String
    let userID: String?
    let accessToken: String?

    @State private var summary: InstacartRunLogSummary?
    @State private var trace: InstacartRunTracePayload?
    @State private var itemImageLookup: [String: String] = [:]
    @State private var isLoadingSummary = false
    @State private var isLoadingTrace = false
    @State private var summaryErrorMessage: String?
    @State private var traceErrorMessage: String?
    @State private var itemSortMode: InstacartRunItemSortMode = .default
    @State private var itemFilterMode: InstacartRunItemFilterMode = .all
    @State private var activeTraceDropdown: InstacartRunTraceDropdown?
    @State private var lastTraceRefreshAt: Date?
    @State private var presentedImage: InstacartRunPresentedImage?

    private var displayedItems: [InstacartRunLogItemPayload] {
        guard let items = trace?.items else { return [] }
        let attemptedItems = items.filter { ($0.attempts?.isEmpty == false) || $0.finalStatus != nil }
        let dedupedItems = dedupeTraceItems(attemptedItems)
        let orderIndexMap = traceItemOrderIndexMap()
        let filtered = dedupedItems.filter { matchesTraceItemFilter($0) }

        return filtered.sorted { lhs, rhs in
            switch itemSortMode {
            case .default:
                let leftLatestAttempt = latestAttemptDate(for: lhs)
                let rightLatestAttempt = latestAttemptDate(for: rhs)
                if leftLatestAttempt != rightLatestAttempt { return leftLatestAttempt > rightLatestAttempt }
                let leftOrder = traceItemOrderIndex(for: lhs, orderIndexMap: orderIndexMap)
                let rightOrder = traceItemOrderIndex(for: rhs, orderIndexMap: orderIndexMap)
                if leftOrder != rightOrder { return leftOrder > rightOrder }
                return traceItemSortName(for: lhs) < traceItemSortName(for: rhs)
            case .priceLowToHigh:
                let leftPrice = traceItemPriceValue(for: lhs) ?? Double.greatestFiniteMagnitude
                let rightPrice = traceItemPriceValue(for: rhs) ?? Double.greatestFiniteMagnitude
                if leftPrice != rightPrice { return leftPrice < rightPrice }
                let leftOrder = traceItemOrderIndex(for: lhs, orderIndexMap: orderIndexMap)
                let rightOrder = traceItemOrderIndex(for: rhs, orderIndexMap: orderIndexMap)
                if leftOrder != rightOrder { return leftOrder < rightOrder }
                return traceItemSortName(for: lhs) < traceItemSortName(for: rhs)
            case .priceHighToLow:
                let leftPrice = traceItemPriceValue(for: lhs) ?? Double.leastNormalMagnitude
                let rightPrice = traceItemPriceValue(for: rhs) ?? Double.leastNormalMagnitude
                if leftPrice != rightPrice { return leftPrice > rightPrice }
                let leftOrder = traceItemOrderIndex(for: lhs, orderIndexMap: orderIndexMap)
                let rightOrder = traceItemOrderIndex(for: rhs, orderIndexMap: orderIndexMap)
                if leftOrder != rightOrder { return leftOrder < rightOrder }
                return traceItemSortName(for: lhs) < traceItemSortName(for: rhs)
            }
        }
    }

    private var displayedItemCount: Int {
        summary?.itemCount ?? trace?.items.count ?? 0
    }

    private func dedupeTraceItems(_ items: [InstacartRunLogItemPayload]) -> [InstacartRunLogItemPayload] {
        var latestByKey: [String: InstacartRunLogItemPayload] = [:]
        for item in items {
            let key = traceItemDeduplicationKey(for: item)
            if let existing = latestByKey[key] {
                if latestAttemptDate(for: item) > latestAttemptDate(for: existing) {
                    latestByKey[key] = item
                }
            } else {
                latestByKey[key] = item
            }
        }
        return Array(latestByKey.values)
    }

    private func traceItemDeduplicationKey(for item: InstacartRunLogItemPayload) -> String {
        [
            item.shoppingContext?.familyKey,
            item.canonicalName,
            item.requested,
            item.normalizedQuery
        ]
        .compactMap { value in
            let cleaned = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
            return cleaned.isEmpty ? nil : cleaned
        }
        .first ?? item.id.lowercased()
    }

    private func latestAttemptDate(for item: InstacartRunLogItemPayload) -> Date {
        let attemptDates = (item.attempts ?? [])
            .compactMap { attempt -> Date? in
                guard let raw = attempt.at else { return nil }
                return InstacartRunDateParser.parse(raw)
            }
        if let maxDate = attemptDates.max() {
            return maxDate
        }

        let statusDate = item.finalStatus?.quantityAdded != nil ? Date.distantPast : Date.distantPast
        return statusDate
    }

    private func traceItemOrderIndexMap() -> [String: Int] {
        guard let items = trace?.items else { return [:] }
        var map: [String: Int] = [:]
        for (index, item) in items.enumerated() {
            let key = traceItemDeduplicationKey(for: item)
            if map[key] == nil {
                map[key] = index
            }
        }
        return map
    }

    private func traceItemOrderIndex(for item: InstacartRunLogItemPayload, orderIndexMap: [String: Int]) -> Int {
        orderIndexMap[traceItemDeduplicationKey(for: item)] ?? Int.max
    }

    private func traceItemSortName(for item: InstacartRunLogItemPayload) -> String {
        [
            item.canonicalName,
            item.requested,
            item.normalizedQuery
        ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        .first ?? ""
    }

    private enum TraceItemOutcomeBucket {
        case completed
        case failed
        case other
    }

    private func traceItemOutcomeBucket(for item: InstacartRunLogItemPayload) -> TraceItemOutcomeBucket {
        let status = item.finalStatus?.status?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let decision = item.finalStatus?.decision?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if ["retry_queued", "queued_retry", "broad_retry_queued"].contains(status) {
            return .other
        }
        if ["exact", "substituted", "saved", "done", "completed"].contains(status) || ["exact_match", "partial_match"].contains(decision) {
            return .completed
        }
        if ["unresolved", "failed", "error", "cancelled", "missing"].contains(status) {
            return .failed
        }
        if (item.finalStatus?.quantityAdded ?? 0) > 0 {
            return .completed
        }
        return .failed
    }

    private func traceItemOutcomeRank(for item: InstacartRunLogItemPayload) -> Int {
        switch traceItemOutcomeBucket(for: item) {
        case .failed:
            return 0
        case .completed:
            return 1
        case .other:
            return 2
        }
    }

    private func matchesTraceItemFilter(_ item: InstacartRunLogItemPayload) -> Bool {
        switch itemFilterMode {
        case .all:
            return true
        case .completed:
            return traceItemOutcomeBucket(for: item) == .completed
        case .failed:
            return traceItemOutcomeBucket(for: item) == .failed
        }
    }

    private func traceItemPriceValue(for item: InstacartRunLogItemPayload) -> Double? {
        let candidate = item.attempts?.last?.selectionTrace?.selectedCandidate
            ?? item.attempts?.last?.selectionTrace?.fallbackCandidate
            ?? item.attempts?.last?.selectionTrace?.topCandidates?.first
        let raw = candidate?.priceText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !raw.isEmpty else { return nil }

        let normalized = raw.replacingOccurrences(of: "\u{00a0}", with: " ")
        if let match = normalized.range(of: #"\$[0-9][0-9,]*(?:\.[0-9]{2})?"#, options: .regularExpression) {
            return Double(String(normalized[match]).replacingOccurrences(of: "$", with: "").replacingOccurrences(of: ",", with: ""))
        }
        if let numeric = normalized.range(of: #"[0-9]+(?:\.[0-9]+)?"#, options: .regularExpression) {
            return Double(String(normalized[numeric]))
        }
        return nil
    }

    private var estimatedCartTotalValue: Double? {
        let prices = displayedItems.compactMap(traceItemPriceValue(for:))
        guard !prices.isEmpty else { return nil }
        return prices.reduce(0, +)
    }

    private var estimatedCartTotalText: String? {
        guard let estimatedCartTotalValue else { return nil }
        return estimatedCartTotalValue.formatted(.currency(code: "USD"))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let summary {
                    HStack(alignment: .center, spacing: 12) {
                        InstacartStoreBadgeView(
                            storeName: sanitizedInstacartStoreName(summary.selectedStore)
                                ?? sanitizedInstacartStoreName(summary.preferredStore)
                                ?? "Instacart run",
                            logoURL: summary.selectedStoreLogoURL
                        )

                        VStack(alignment: .leading, spacing: 8) {
                            Text(
                                sanitizedInstacartStoreName(summary.selectedStore)
                                ?? sanitizedInstacartStoreName(summary.preferredStore)
                                ?? "Instacart run"
                            )
                                .biroHeaderFont(30)
                                .foregroundStyle(OunjePalette.primaryText)
                            Text(summary.statusKind.capitalized + " • " + (summary.completedAt ?? summary.startedAt ?? ""))
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(OunjePalette.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Spacer(minLength: 0)
                    }

                    summaryGrid(summary)
                    traceSection
                } else if isLoadingSummary {
                    loadingState
                } else if let summaryErrorMessage {
                    errorState(message: summaryErrorMessage)
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 18)
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
        .background(OunjePalette.background.ignoresSafeArea())
        .overlay {
            if let presentedImage {
                InstacartRunImageModal(image: presentedImage) {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        self.presentedImage = nil
                    }
                }
                .transition(.opacity)
                .zIndex(20)
            }
        }
        .task(id: runID) {
            await refreshRun(resetState: true)
        }
        .task(id: "\(runID)::\(summary?.normalizedStatusKind ?? "idle")") {
            guard summary?.normalizedStatusKind == "running" else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard !Task.isCancelled else { return }
                await refreshRun(resetState: false)
                if summary?.normalizedStatusKind != "running" {
                    return
                }
            }
        }
    }

    private var traceSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            if trace != nil || isLoadingTrace || traceErrorMessage != nil {
                traceControls

                if let traceErrorMessage {
                    errorState(message: traceErrorMessage)
                } else if isLoadingTrace && trace == nil {
                    loadingTraceState
                } else if displayedItems.isEmpty {
                    emptyState
                } else {
                    VStack(spacing: 0) {
                        ForEach(displayedItems) { item in
                            InstacartRunItemRow(
                                item: item,
                                imageURLString: imageURLString(for: item),
                                onOpenImage: { image in
                                    withAnimation(.easeInOut(duration: 0.16)) {
                                        presentedImage = image
                                    }
                                }
                            )
                            if item.id != displayedItems.last?.id {
                                Divider()
                                    .overlay(OunjePalette.stroke.opacity(0.45))
                                    .padding(.leading, 52)
                            }
                        }
                        if isLoadingTrace && trace == nil {
                            HStack(spacing: 8) {
                                ProgressView()
                                    .tint(OunjePalette.secondaryText)
                                Text("Updating item details")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(OunjePalette.secondaryText)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 10)
                            .padding(.leading, 2)
                        }
                    }
                }
            } else {
                tracePlaceholder
                    .onAppear {
                        Task {
                            await loadTraceIfNeeded()
                        }
                    }
            }
        }
    }

    private func summaryGrid(_ summary: InstacartRunLogSummary) -> some View {
        return LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
            summaryCard(
                title: "Store",
                value: sanitizedInstacartStoreName(summary.selectedStore)
                    ?? sanitizedInstacartStoreName(summary.preferredStore)
                    ?? "—"
            )
            summaryCard(title: "Status", value: summary.statusKind.capitalized)
            summaryCard(title: "Items", value: "\(summary.resolvedCount)/\(max(summary.itemCount, displayedItemCount))")
            summaryCard(title: "Shortfall", value: "\(summary.shortfallCount)")
            if let estimatedCartTotalText {
                summaryCard(title: "Total", value: estimatedCartTotalText)
            }
        }
    }

    private func summaryCard(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(OunjePalette.secondaryText)
                .textCase(.uppercase)
            Text(value)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(OunjePalette.primaryText)
                .lineLimit(2)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 74, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(OunjePalette.surface.opacity(0.94))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(OunjePalette.stroke, lineWidth: 1)
                )
        )
    }

    private var traceControls: some View {
        ZStack(alignment: .topLeading) {
            HStack(spacing: 14) {
                traceControlSlot(
                    title: "Sort",
                    value: itemSortMode.title,
                    systemImage: "arrow.up.arrow.down",
                    kind: .sort
                )

                traceControlSlot(
                    title: "Filter",
                    value: itemFilterMode.title,
                    systemImage: "line.3.horizontal.decrease.circle",
                    kind: .filter
                )
            }
            .frame(height: 40)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func traceControlSlot(title: String, value: String, systemImage: String, kind: InstacartRunTraceDropdown) -> some View {
        traceControlButton(title: title, value: value, systemImage: systemImage, kind: kind)
            .frame(maxWidth: .infinity, alignment: kind == .sort ? .leading : .trailing)
            .overlay(alignment: kind == .sort ? .bottomLeading : .bottomTrailing) {
                if activeTraceDropdown == kind {
                    traceDropdownPanel(kind: kind)
                        .offset(y: 12)
                        .zIndex(2)
                }
            }
    }

    private func traceControlButton(title: String, value: String, systemImage: String, kind: InstacartRunTraceDropdown) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) {
                activeTraceDropdown = activeTraceDropdown == kind ? nil : kind
            }
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Image(systemName: systemImage)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(OunjePalette.secondaryText)
                    Text(title.uppercased())
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(OunjePalette.secondaryText.opacity(0.82))
                }

                HStack(spacing: 6) {
                    SleeScriptDisplayText(
                        value,
                        size: 16,
                        color: activeTraceDropdown == kind ? OunjePalette.softCream : OunjePalette.primaryText
                    )
                    .lineLimit(1)
                    .minimumScaleFactor(0.9)

                    Image(systemName: activeTraceDropdown == kind ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(OunjePalette.secondaryText)
                }
            }
            .frame(maxWidth: 150, alignment: kind == .sort ? .leading : .trailing)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func traceDropdownPanel(kind: InstacartRunTraceDropdown) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            switch kind {
            case .sort:
                ForEach(InstacartRunItemSortMode.allCases) { mode in
                    traceDropdownOption(
                        title: mode.title,
                        isSelected: itemSortMode == mode
                    ) {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            itemSortMode = mode
                            activeTraceDropdown = nil
                        }
                    }
                }
            case .filter:
                ForEach(InstacartRunItemFilterMode.allCases) { mode in
                    traceDropdownOption(
                        title: mode.title,
                        isSelected: itemFilterMode == mode
                    ) {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            itemFilterMode = mode
                            activeTraceDropdown = nil
                        }
                    }
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(OunjePalette.surface.opacity(0.96))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(OunjePalette.stroke.opacity(0.95), lineWidth: 1)
                )
        )
        .frame(maxWidth: 290, alignment: .leading)
    }

    private func traceDropdownOption(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                SleeScriptDisplayText(
                    title,
                    size: 16,
                    color: isSelected ? OunjePalette.softCream : OunjePalette.primaryText
                )
                .lineLimit(1)
                .minimumScaleFactor(0.9)

                Spacer(minLength: 0)

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(OunjePalette.accent)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isSelected ? OunjePalette.elevated.opacity(0.96) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var loadingState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Loading run")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(OunjePalette.primaryText)
            Text("Fetching the stored summary.")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(OunjePalette.secondaryText)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(OunjePalette.surface.opacity(0.94))
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(OunjePalette.stroke, lineWidth: 1)
                )
        )
    }

    private var loadingTraceState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Loading item details")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(OunjePalette.primaryText)
            Text("Fetching the details only when this list is opened.")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(OunjePalette.secondaryText)
            traceSkeletonRows
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(OunjePalette.surface.opacity(0.94))
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(OunjePalette.stroke, lineWidth: 1)
                )
        )
    }

    private var tracePlaceholder: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Item details")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(OunjePalette.primaryText)
            Text("Scroll here to load the cart-to-Instacart details.")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(OunjePalette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(OunjePalette.surface.opacity(0.94))
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(OunjePalette.stroke, lineWidth: 1)
                )
        )
    }

    private func errorState(message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Couldn’t load run")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(OunjePalette.primaryText)
            Text(message)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(OunjePalette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(OunjePalette.surface.opacity(0.94))
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(OunjePalette.stroke, lineWidth: 1)
                )
        )
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("No matching items")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(OunjePalette.primaryText)
            Text("Try a different sort or filter.")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(OunjePalette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(OunjePalette.surface.opacity(0.94))
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(OunjePalette.stroke, lineWidth: 1)
                )
        )
    }

    private var traceSkeletonRows: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(0..<3, id: \.self) { index in
                HStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(OunjePalette.stroke.opacity(0.28))
                        .frame(width: 42, height: 42)
                    VStack(alignment: .leading, spacing: 8) {
                        RoundedRectangle(cornerRadius: 999, style: .continuous)
                            .fill(OunjePalette.stroke.opacity(0.22))
                            .frame(width: index == 0 ? 180 : 140, height: 14)
                        RoundedRectangle(cornerRadius: 999, style: .continuous)
                            .fill(OunjePalette.stroke.opacity(0.18))
                            .frame(width: index == 0 ? 220 : 180, height: 10)
                    }
                    Spacer(minLength: 0)
                }
                if index < 2 {
                    Divider()
                        .overlay(OunjePalette.stroke.opacity(0.35))
                        .padding(.leading, 54)
                }
            }
        }
    }

    private func refreshRun(resetState: Bool) async {
        if resetState {
            isLoadingSummary = true
            summaryErrorMessage = nil
            summary = nil
            trace = nil
            traceErrorMessage = nil
            itemImageLookup = [:]
        } else if isLoadingSummary {
            return
        }

        defer {
            isLoadingSummary = false
        }

        do {
            let loadedSummary = try await InstacartRunLogAPIService.shared.fetchRunSummary(
                runID: runID,
                userID: userID,
                accessToken: accessToken
            )
            summary = loadedSummary
            summaryErrorMessage = nil
            await loadTrace(forceRefresh: shouldRefreshTrace(for: loadedSummary))
        } catch {
            summaryErrorMessage = error.localizedDescription
        }
    }

    private func loadTraceIfNeeded() async {
        await loadTrace(forceRefresh: false)
    }

    private func loadTrace(forceRefresh: Bool) async {
        guard summary != nil else { return }
        if !forceRefresh, trace != nil { return }
        guard !isLoadingTrace else { return }

        isLoadingTrace = true
        lastTraceRefreshAt = Date()
        traceErrorMessage = nil
        defer {
            isLoadingTrace = false
        }

        do {
            let loadedTrace = try await InstacartRunLogAPIService.shared.fetchRunTrace(
                runID: runID,
                userID: userID,
                accessToken: accessToken
            )
            trace = loadedTrace
            Task.detached(priority: .utility) { [loadedTrace] in
                await loadItemImages(for: loadedTrace.items)
            }
        } catch {
            if trace == nil {
                traceErrorMessage = error.localizedDescription
            } else {
                traceErrorMessage = nil
            }
        }
    }

    private func shouldRefreshTrace(for loadedSummary: InstacartRunLogSummary) -> Bool {
        if trace == nil {
            return true
        }
        guard loadedSummary.normalizedStatusKind == "running" else {
            return false
        }
        guard let lastTraceRefreshAt else {
            return true
        }
        return Date().timeIntervalSince(lastTraceRefreshAt) >= 20
    }

    private func imageURLString(for item: InstacartRunLogItemPayload) -> String? {
        let keys = [
            item.shoppingContext?.familyKey,
            item.canonicalName,
            item.requested,
            item.normalizedQuery
        ]
        .compactMap { $0 }

        for key in keys {
            let normalized = SupabaseIngredientsCatalogService.normalizedName(key)
            if let imageURLString = itemImageLookup[normalized], !imageURLString.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty {
                return imageURLString
            }
        }

        return nil
    }

    private func loadItemImages(for items: [InstacartRunLogItemPayload]) async {
        let normalizedNames = Array(
            Set(
                items
                    .compactMap { $0.canonicalName ?? $0.requested ?? $0.normalizedQuery }
                    .map { SupabaseIngredientsCatalogService.normalizedName($0) }
                    .filter { !$0.isEmpty }
            )
        ).sorted()

        guard !normalizedNames.isEmpty else { return }

        do {
            let imageLookup = try await SupabaseIngredientsCatalogService.shared.fetchImageLookup(
                normalizedNames: normalizedNames
            )
            var lookup = itemImageLookup
            for (key, imageURLString) in imageLookup {
                guard !key.isEmpty, !imageURLString.isEmpty else { continue }
                lookup[key] = imageURLString
            }
            itemImageLookup = lookup
        } catch {
            // Image lookup is best-effort only.
        }
    }
}

private enum InstacartRunItemSortMode: String, CaseIterable, Identifiable {
    case `default`
    case priceLowToHigh
    case priceHighToLow

    var id: String { rawValue }

    var title: String {
        switch self {
        case .default:
            return "Default"
        case .priceLowToHigh:
            return "Price: low to high"
        case .priceHighToLow:
            return "Price: high to low"
        }
    }
}

private enum InstacartRunTraceDropdown {
    case sort
    case filter
}

private enum InstacartRunItemFilterMode: String, CaseIterable, Identifiable {
    case all
    case completed
    case failed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all:
            return "All"
        case .completed:
            return "Completed"
        case .failed:
            return "Failed"
        }
    }
}

private struct InstacartRunItemRow: View {
    let item: InstacartRunLogItemPayload
    let imageURLString: String?
    let onOpenImage: (InstacartRunPresentedImage) -> Void

    private var cartItemTitle: String {
        item.canonicalName ?? item.requested ?? item.normalizedQuery ?? "Item"
    }

    private var selectionTrace: InstacartRunSelectionTracePayload? {
        item.attempts?.last?.selectionTrace
    }

    private var mappedCandidate: InstacartRunSelectionCandidatePayload? {
        selectionTrace?.selectedCandidate
            ?? selectionTrace?.fallbackCandidate
            ?? selectionTrace?.topCandidates?.first
    }

    private var mappedItemTitle: String {
        instacartMappedProductTitle(
            mappedCandidate?.title,
            mappedCandidate?.rawLabel,
            mappedCandidate?.cardText,
            item.attempts?.last?.matchedLabel,
            item.canonicalName,
            item.requested
        ) ?? (
            item.finalStatus?.status?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "unresolved"
                ? "Not added"
                : (item.canonicalName ?? item.requested ?? item.normalizedQuery ?? "Matched item")
        )
    }

    private var mappedItemPriceText: String? {
        conciseInstacartPriceText(mappedCandidate?.priceText)
    }

    private var mappedItemDetailText: String? {
        mappedItemPriceText
            ?? (item.finalStatus?.status?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "unresolved"
                ? "Not added"
                : (item.finalStatus?.status?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "retry_queued"
                    ? "Queued for broader retry"
                    : nil))
    }

    private var failureReasonText: String? {
        let status = item.finalStatus?.status?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        guard ["unresolved", "failed", "error", "missing"].contains(status) else { return nil }

        if let summary = cleanedInstacartFailureReasonText(item.finalStatus?.failureSummary) {
            return summary
        }

        let reasons = (item.finalStatus?.failureReasons ?? [])
            .compactMap { cleanedInstacartFailureReasonText($0) }
        if !reasons.isEmpty {
            return reasons.prefix(2).joined(separator: " • ")
        }

        return cleanedInstacartFailureReasonText(item.attempts?.last?.reason)
    }

    private var mappedItemImageURL: URL? {
        mappedCandidate?.imageURLString.flatMap { raw in
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return URL(string: trimmed)
        }
    }

    private var cartPresentedImage: InstacartRunPresentedImage? {
        guard let raw = imageURLString?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              let url = URL(string: raw) else {
            return nil
        }
        return InstacartRunPresentedImage(title: cartItemTitle, imageURL: url)
    }

    private var mappedPresentedImage: InstacartRunPresentedImage? {
        guard let mappedItemImageURL else { return nil }
        return InstacartRunPresentedImage(title: mappedItemTitle, imageURL: mappedItemImageURL)
    }

    private var matchTone: InstacartRunMatchTone {
        let status = item.finalStatus?.status?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let matchType = item.finalStatus?.matchType?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if ["retry_queued", "queued_retry", "broad_retry_queued"].contains(status) {
            return .partial
        }
        if status == "exact" || matchType == "exact" || item.finalStatus?.decision?.lowercased() == "exact_match" {
            return .exact
        }
        if status == "partial" || status == "substituted" || matchType == "partial" || item.finalStatus?.decision?.lowercased() == "partial_match" {
            return .partial
        }
        return .mismatch
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .center, spacing: 8) {
                InstacartRunItemImageView(title: cartItemTitle, imageURLString: imageURLString)
                    .onTapGesture {
                        guard let cartPresentedImage else { return }
                        onOpenImage(cartPresentedImage)
                    }

                VStack(alignment: .center, spacing: 2) {
                    SleeScriptDisplayText(cartItemTitle, size: 18, color: OunjePalette.primaryText)
                        .foregroundStyle(OunjePalette.primaryText)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                    SleeScriptDisplayText("Cart ingredient", size: 12, color: OunjePalette.secondaryText.opacity(0.85))
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)

            Image(systemName: "arrow.right")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(matchTone.tint.opacity(0.9))
                .frame(width: 28, alignment: .center)

            VStack(alignment: .center, spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(OunjePalette.surface)
                        .frame(width: 42, height: 42)

                    if let mappedItemImageURL {
                        CartCachedArtworkView(imageURL: mappedItemImageURL) {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(OunjePalette.surface)
                                .overlay(
                                    Image(systemName: "cart.fill")
                                        .font(.system(size: 12, weight: .bold))
                                        .foregroundStyle(matchTone.tint.opacity(0.9))
                                )
                        }
                        .frame(width: 42, height: 42)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .onTapGesture {
                            guard let mappedPresentedImage else { return }
                            onOpenImage(mappedPresentedImage)
                        }
                    } else {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(OunjePalette.surface)
                            .overlay(
                                Image(systemName: "cart.fill")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundStyle(matchTone.tint.opacity(0.9))
                            )
                    }
                }

                VStack(alignment: .center, spacing: 2) {
                    Text(mappedItemTitle)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(OunjePalette.primaryText)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .minimumScaleFactor(0.88)

                    if let mappedItemDetailText, !mappedItemDetailText.isEmpty {
                        Text(mappedItemDetailText)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(OunjePalette.secondaryText)
                            .lineLimit(1)
                    }

                    if let failureReasonText, !failureReasonText.isEmpty {
                        Text(failureReasonText)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(matchTone.tint.opacity(0.96))
                            .lineLimit(3)
                            .multilineTextAlignment(.center)
                            .padding(.top, 2)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(.vertical, 12)
    }
}

private struct InstacartRunItemImageView: View {
    let title: String
    let imageURLString: String?

    private var fallbackInitials: String {
        let words = title
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0.isWhitespace || $0 == "-" })
            .prefix(2)
        let initials = words.compactMap { $0.first }.map(String.init).joined()
        return initials.isEmpty ? "I" : initials.uppercased()
    }

    var body: some View {
        Group {
            if let raw = imageURLString?.trimmingCharacters(in: .whitespacesAndNewlines),
               let url = URL(string: raw),
               !raw.isEmpty {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                    default:
                        fallback
                    }
                }
            } else {
                fallback
            }
        }
        .frame(width: 42, height: 42)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var fallback: some View {
        RoundedRectangle(cornerRadius: 13, style: .continuous)
            .fill(OunjePalette.surface)
            .overlay(
                Text(fallbackInitials)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(OunjePalette.primaryText)
            )
    }
}

private struct InstacartRunPresentedImage: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let imageURL: URL
}

private struct InstacartRunImageModal: View {
    let image: InstacartRunPresentedImage
    let onDismiss: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.72)
                .ignoresSafeArea()
                .onTapGesture(perform: onDismiss)

            VStack(alignment: .center, spacing: 14) {
                HStack {
                    Spacer()
                    Button(action: onDismiss) {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(OunjePalette.primaryText)
                            .frame(width: 32, height: 32)
                            .background(
                                Circle()
                                    .fill(OunjePalette.surface.opacity(0.94))
                            )
                    }
                    .buttonStyle(.plain)
                }

                CartCachedArtworkView(imageURL: image.imageURL) {
                    RoundedRectangle(cornerRadius: 26, style: .continuous)
                        .fill(OunjePalette.surface)
                }
                .frame(width: 280, height: 280)
                .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))

                Text(image.title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(OunjePalette.primaryText)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
            .padding(18)
            .frame(maxWidth: 340)
            .background(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(OunjePalette.surface.opacity(0.98))
                    .overlay(
                        RoundedRectangle(cornerRadius: 28, style: .continuous)
                            .stroke(OunjePalette.stroke, lineWidth: 1)
                    )
            )
            .padding(.horizontal, 24)
        }
    }
}

private enum InstacartRunMatchTone {
    case exact
    case partial
    case mismatch

    var tint: Color {
        switch self {
        case .exact:
            return Color(red: 0.19, green: 0.72, blue: 0.42)
        case .partial:
            return Color(red: 0.95, green: 0.69, blue: 0.16)
        case .mismatch:
            return Color(red: 0.94, green: 0.28, blue: 0.31)
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .exact:
            return "Exact match"
        case .partial:
            return "Partial match"
        case .mismatch:
            return "Mismatch"
        }
    }
}

private func cleanedCandidateTitle(_ raw: String?) -> String? {
    guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
        return nil
    }

    value = value.replacingOccurrences(
        of: #"(?i)^current price:\s*\$?[0-9.,]+(?:\$?[0-9.,]+)?\s*"#,
        with: "",
        options: .regularExpression
    )
    value = value.replacingOccurrences(
        of: #"(?i)\b(many in stock|low in stock|out of stock|add)\b"#,
        with: "",
        options: .regularExpression
    )
    value = value.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
    value = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return value.isEmpty ? nil : value
}

private func conciseInstacartCandidateTitle(_ values: String?...) -> String? {
    for raw in values {
        if let title = cleanedInstacartDisplayText(raw) {
            return title
        }
    }
    return nil
}

private func instacartMappedProductTitle(_ values: String?...) -> String? {
    for raw in values {
        guard let title = cleanedInstacartDisplayText(raw) else { continue }
        let lower = title.lowercased()
        if lower.contains("instacart item") || lower == "current price" || lower == "matched item" || lower == "store choice" { continue }
        if lower.hasPrefix("no frills") || lower.hasPrefix("food basics") || lower.hasPrefix("metro") { continue }
        return title
    }

    return nil
}

private func cleanedInstacartDisplayText(_ raw: String?) -> String? {
    guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
        return nil
    }

    value = value.replacingOccurrences(of: "\u{00a0}", with: " ")
    let lines = value
        .components(separatedBy: .newlines)
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }

    if lines.count > 1 {
        for line in lines {
            if let title = cleanedInstacartDisplayText(line) {
                return title
            }
        }
    }

    let lower = value.lowercased()
    let cutMarkers = [
        "current price:",
        "many in stock",
        "low in stock",
        "out of stock",
        "best seller",
        "top pick",
        "pickup by",
        "delivery by"
    ]
    for marker in cutMarkers {
        if let range = lower.range(of: marker) {
            value = String(value[..<range.lowerBound])
            break
        }
    }

    value = value.replacingOccurrences(of: #"(?i)^(best seller|top pick)\s*"#, with: "", options: .regularExpression)
    value = value.replacingOccurrences(of: #"(?i)^store choice\s*"#, with: "", options: .regularExpression)
    value = value.replacingOccurrences(of: #"(?i)\b(add|choose)\b.*$"#, with: "", options: .regularExpression)
    value = value.replacingOccurrences(of: #"(?i)current price:\s*"#, with: "", options: .regularExpression)
    value = value.replacingOccurrences(of: #"(?i)\s*\$[0-9][0-9,]*(?:\.[0-9]{2})?.*$"#, with: "", options: .regularExpression)
    value = value.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
    value = value.trimmingCharacters(in: .whitespacesAndNewlines)

    guard !value.isEmpty else { return nil }
    let lowerValue = value.lowercased()
    if lowerValue == "instacart item" || lowerValue == "current price" || lowerValue == "store choice" {
        return nil
    }
    if value.rangeOfCharacter(from: .letters) == nil {
        return nil
    }

    if value.count > 62, let lastSpace = value[..<value.index(value.startIndex, offsetBy: 62)].lastIndex(of: " ") {
        value = String(value[..<lastSpace])
    } else if value.count > 62 {
        value = String(value.prefix(62))
    }

    return value.trimmingCharacters(in: .whitespacesAndNewlines)
}

private func cleanedInstacartFailureReasonText(_ raw: String?) -> String? {
    guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
        return nil
    }

    value = value.replacingOccurrences(of: "\u{00a0}", with: " ")
    value = value.replacingOccurrences(of: ";", with: " • ")
    value = value.replacingOccurrences(of: "_", with: " ")
    value = value.replacingOccurrences(of: #"(?i)\bfamily guard\b"#, with: "wrong product family", options: .regularExpression)
    value = value.replacingOccurrences(of: #"(?i)\bdescriptor guard\b"#, with: "wrong product details", options: .regularExpression)
    value = value.replacingOccurrences(of: #"(?i)\bquantity guard\b"#, with: "package size mismatch", options: .regularExpression)
    value = value.replacingOccurrences(of: #"(?i)\bheuristic reject low confidence\b"#, with: "match confidence was too weak", options: .regularExpression)
    value = value.replacingOccurrences(of: #"(?i)\bllm exhausted candidate windows\b"#, with: "the visible results never showed a safe match", options: .regularExpression)
    value = value.replacingOccurrences(of: #"(?i)\bcandidate click not found\b"#, with: "Instacart did not expose a usable add action", options: .regularExpression)
    value = value.replacingOccurrences(of: #"(?i)\bcart count not verified\b"#, with: "the product could not be verified in the cart", options: .regularExpression)
    value = value.replacingOccurrences(of: #"(?i)\bpackage too small\b"#, with: "package size was too small", options: .regularExpression)
    value = value.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    value = value.trimmingCharacters(in: .whitespacesAndNewlines)

    if value.count > 120, let lastSpace = value[..<value.index(value.startIndex, offsetBy: 120)].lastIndex(of: " ") {
        value = String(value[..<lastSpace])
    } else if value.count > 120 {
        value = String(value.prefix(120))
    }

    return value.isEmpty ? nil : value
}

private func conciseInstacartPriceText(_ raw: String?) -> String? {
    guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
        return nil
    }

    value = value.replacingOccurrences(of: "\u{00a0}", with: " ")
    value = value.replacingOccurrences(of: #"(?i)^current price:\s*"#, with: "", options: .regularExpression)
    value = value.replacingOccurrences(of: #"(?i)^price:\s*"#, with: "", options: .regularExpression)
    value = value.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)

    if let match = value.range(of: #"\$[0-9][0-9,]*(?:\.[0-9]{2})?"#, options: .regularExpression) {
        return String(value[match]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    value = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return value.isEmpty ? nil : value
}

private enum RecipeImportProgressStage: Int, CaseIterable {
    case fetching
    case readingVideo
    case buildingRecipe
    case saved

    var title: String {
        switch self {
        case .fetching: return "Queued"
        case .readingVideo: return "Reading"
        case .buildingRecipe: return "Writing"
        case .saved: return "Saved"
        }
    }

    var displayTitle: String {
        switch self {
        case .fetching: return "Queued for import"
        case .readingVideo: return "Reading the source"
        case .buildingRecipe: return "Writing the recipe"
        case .saved: return "Saved to Cookbook"
        }
    }

    var symbolName: String {
        switch self {
        case .fetching: return "tray.and.arrow.down.fill"
        case .readingVideo: return "text.viewfinder"
        case .buildingRecipe: return "list.bullet.clipboard.fill"
        case .saved: return "checkmark.seal.fill"
        }
    }

    static func current(for item: SharedRecipeImportEnvelope) -> RecipeImportProgressStage {
        switch item.normalizedProcessingState {
        case "parsing":
            return .readingVideo
        case "normalized":
            return .buildingRecipe
        case "saved":
            return .saved
        default:
            return .fetching
        }
    }
}

private struct SharedRecipeImportProgressCard: View {
    let item: SharedRecipeImportEnvelope
    let onTap: (() -> Void)?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isPulsing = false

    private var currentStage: RecipeImportProgressStage {
        RecipeImportProgressStage.current(for: item)
    }

    private var isPhotoImport: Bool {
        (item.sourceApp ?? "").lowercased().contains("photo")
    }

    private var subtitle: String {
        if isPhotoImport {
            switch currentStage {
            case .fetching:
                return "Checking photo."
            case .readingVideo:
                return "Finding recipe references."
            case .buildingRecipe:
                return "Writing the recipe."
            case .saved:
                return "Saved to Cookbook."
            }
        }
        switch currentStage {
        case .fetching:
            return "Queued for the recipe worker."
        case .readingVideo:
            return "Reading the source."
        case .buildingRecipe:
            return "Building the recipe."
        case .saved:
            return "Ready to open."
        }
    }

    private var sourceLabel: String {
        if isPhotoImport {
            let sourceText = item.sourceText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return sourceText.isEmpty ? "food photo" : sourceText.components(separatedBy: .newlines).first ?? "food photo"
        }
        let sourceURL = item.sourceURLString?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !sourceURL.isEmpty {
            if let host = URL(string: sourceURL)?.host?.replacingOccurrences(of: "www.", with: ""), !host.isEmpty {
                return host
            }
            return sourceURL
        }

        let sourceText = item.sourceText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !sourceText.isEmpty {
            return sourceText.components(separatedBy: .newlines).first ?? sourceText
        }

        return "shared recipe"
    }

    private var progressFraction: CGFloat {
        let maxIndex = max(RecipeImportProgressStage.allCases.count - 1, 1)
        return CGFloat(currentStage.rawValue) / CGFloat(maxIndex)
    }

    var body: some View {
        Group {
            if let onTap {
                Button(action: onTap) {
                    content
                }
                .buttonStyle(.plain)
            } else {
                content
            }
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                isPulsing = true
            }
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 11) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(OunjePalette.accent.opacity(currentStage == .saved ? 0.22 : 0.12))
                        .frame(width: 32, height: 32)

                    Image(systemName: currentStage.symbolName)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(currentStage == .saved ? OunjePalette.accent : OunjePalette.softCream)
                        .scaleEffect(isPulsing && !reduceMotion && currentStage != .saved ? 1.08 : 1)
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(isPhotoImport ? "Cloning dish" : "Pulling in recipe")
                            .contentTransition(.opacity)
                            .font(.system(size: 15, weight: .heavy, design: .rounded))
                            .foregroundStyle(OunjePalette.primaryText)
                            .lineLimit(1)

                        Text(currentStage.displayTitle)
                            .font(.system(size: 10, weight: .heavy, design: .rounded))
                            .foregroundStyle(currentStage == .saved ? OunjePalette.background : OunjePalette.softCream.opacity(0.82))
                            .lineLimit(1)
                            .padding(.horizontal, 8)
                            .frame(height: 20)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(currentStage == .saved ? OunjePalette.accent : OunjePalette.surface.opacity(0.9))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .stroke(OunjePalette.stroke, lineWidth: 1)
                                    )
                            )
                    }

                    Text(subtitle)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(OunjePalette.secondaryText)
                        .lineLimit(2)
                }

                Spacer(minLength: 0)
            }

            progressBar

            HStack(spacing: 6) {
                Image(systemName: "link")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(OunjePalette.secondaryText.opacity(0.85))
                Text(sourceLabel)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(OunjePalette.secondaryText.opacity(0.86))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 2)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(OunjePalette.surface.opacity(0.54))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(OunjePalette.stroke.opacity(0.86), lineWidth: 1)
                )
        )
    }

    private var progressBar: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 999, style: .continuous)
                    .fill(OunjePalette.background.opacity(0.44))

                RoundedRectangle(cornerRadius: 999, style: .continuous)
                    .fill(OunjePalette.accent.opacity(0.9))
                    .frame(width: max(18, proxy.size.width * progressFraction))
                    .shadow(color: OunjePalette.accent.opacity(isPulsing && !reduceMotion ? 0.2 : 0.05), radius: 7, x: 0, y: 0)
            }
        }
        .frame(height: 4)
    }

    private func stageMarker(for stage: RecipeImportProgressStage) -> some View {
        let isComplete = stage.rawValue < currentStage.rawValue || currentStage == .saved
        let isCurrent = stage == currentStage && currentStage != .saved

        return VStack(spacing: 5) {
            Circle()
                .fill(isComplete ? OunjePalette.accent : isCurrent ? OunjePalette.softCream : OunjePalette.surface)
                .frame(width: isCurrent ? 8 : 6, height: isCurrent ? 8 : 6)
                .overlay(
                    Circle()
                        .stroke(isCurrent ? OunjePalette.primaryText.opacity(0.34) : Color.clear, lineWidth: 1)
                )
                .scaleEffect(isCurrent && isPulsing && !reduceMotion ? 1.18 : 1)

            Text(stage.title)
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .foregroundStyle(stage.rawValue <= currentStage.rawValue ? OunjePalette.primaryText.opacity(0.76) : OunjePalette.secondaryText.opacity(0.58))
                .lineLimit(1)
                .minimumScaleFactor(0.78)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct SharedRecipeImportQueueRow: View {
    let item: SharedRecipeImportEnvelope
    let onDelete: (() -> Void)?

    private var titleText: String {
        let source = item.sourceURLString?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let source, !source.isEmpty {
            return source
        }

        let sourceText = item.sourceText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !sourceText.isEmpty {
            return sourceText.components(separatedBy: .newlines).first ?? sourceText
        }

        if let app = item.sourceApp?.trimmingCharacters(in: .whitespacesAndNewlines), !app.isEmpty {
            return app
        }

        return "Imported recipe"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(OunjePalette.surface)
                        .frame(width: 42, height: 42)

                    Image(systemName: item.isRetryNeeded ? "exclamationmark.triangle.fill" : "tray.full.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(item.isRetryNeeded ? Color.orange : OunjePalette.primaryText)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(titleText)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(OunjePalette.primaryText)
                        .lineLimit(2)
                    Text(item.queueStatusLabel)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(item.isRetryNeeded ? Color.orange : OunjePalette.secondaryText)
                }

                Spacer(minLength: 0)

                if item.isRetryNeeded, let onDelete {
                    Button(role: .destructive, action: onDelete) {
                        Image(systemName: "trash")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(Color.red)
                            .frame(width: 30, height: 30)
                            .background(
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .fill(Color.red.opacity(0.12))
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Delete failed import")
                }
            }

            if let error = item.lastError, !error.isEmpty {
                Text(error)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(OunjePalette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                if let attemptCount = item.attemptCount {
                    Text("Attempts: \(attemptCount)")
                }
                if let attemptAt = item.lastAttemptAt {
                    Text(attemptAt.formatted(.relative(presentation: .named)))
                } else {
                    Text(item.createdAt.formatted(.relative(presentation: .named)))
                }
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(OunjePalette.secondaryText)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(OunjePalette.surface.opacity(0.94))
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(OunjePalette.stroke, lineWidth: 1)
                )
        )
    }
}

private struct RecipeImportCompletedRow: View {
    let item: RecipeImportCompletedItem
    let onOpenRecipe: ((DiscoverRecipeCardData) -> Void)?

    private var relativeTimestamp: String? {
        let formatter = ISO8601DateFormatter()
        if let completedAt = item.completedAt,
           let date = formatter.date(from: completedAt) {
            return date.formatted(.relative(presentation: .named))
        }
        if let createdAt = item.createdAt,
           let date = formatter.date(from: createdAt) {
            return date.formatted(.relative(presentation: .named))
        }
        return nil
    }

    private var sourceLine: String {
        let parts = [item.source, item.cookTimeText]
            .compactMap { raw -> String? in
                guard let raw else { return nil }
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
        return parts.isEmpty ? "Imported recipe" : parts.joined(separator: " • ")
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Group {
                if let raw = item.imageURL?.trimmingCharacters(in: .whitespacesAndNewlines),
                   let url = URL(string: raw),
                   !raw.isEmpty {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let image):
                            image
                                .resizable()
                                .scaledToFill()
                        default:
                            completedFallbackIcon
                        }
                    }
                } else {
                    completedFallbackIcon
                }
            }
            .frame(width: 46, height: 46)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

            VStack(alignment: .leading, spacing: 5) {
                Text(item.title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(OunjePalette.primaryText)
                    .lineLimit(2)

                Text(sourceLine)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(OunjePalette.secondaryText)
                    .lineLimit(1)

                if let sourceKindLabel = item.sourceKindLabel {
                    Text(sourceKindLabel)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(OunjePalette.background)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(
                            Capsule(style: .continuous)
                                .fill(OunjePalette.accent.opacity(0.9))
                        )
                }

                if let sourceURL = item.sourceURL, !sourceURL.isEmpty {
                    Text(sourceURL)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(OunjePalette.secondaryText.opacity(0.9))
                        .lineLimit(1)
                }

                if let relativeTimestamp {
                    Text(relativeTimestamp)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(OunjePalette.secondaryText)
                }
            }

            Spacer(minLength: 0)

            Text("Done")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(OunjePalette.background)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    Capsule(style: .continuous)
                        .fill(OunjePalette.accent)
                )
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(OunjePalette.surface.opacity(0.94))
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(OunjePalette.stroke, lineWidth: 1)
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .onTapGesture {
            guard let recipe = item.savedRecipeCard else { return }
            onOpenRecipe?(recipe)
        }
    }

    private var completedFallbackIcon: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(OunjePalette.surface)
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(OunjePalette.accent)
        }
    }
}

private struct CustomTabBar: View {
    @Binding var selectedTab: AppTab
    @Namespace private var selectionNamespace

    var body: some View {
        HStack(spacing: 0) {
            ForEach(AppTab.allCases) { tab in
                Button {
                    withAnimation(OunjeMotion.tabSpring) {
                        selectedTab = tab
                    }
                    if tab == .discover {
                        NotificationCenter.default.post(name: .ounjeDiscoverTabTapped, object: nil)
                    }
                } label: {
                    VStack(spacing: 3) {
                        if selectedTab == tab {
                            Capsule(style: .continuous)
                                .fill(OunjePalette.accent.opacity(0.92))
                                .frame(width: 22, height: 3)
                                .padding(.bottom, 3)
                                .matchedGeometryEffect(id: "tab-indicator", in: selectionNamespace)
                        } else {
                            Capsule(style: .continuous)
                                .fill(Color.clear)
                                .frame(width: 22, height: 3)
                                .padding(.bottom, 3)
                        }

                        Image(systemName: tab.symbol)
                            .font(.system(size: 22, weight: selectedTab == tab ? .semibold : .medium))
                            .foregroundStyle(selectedTab == tab ? OunjePalette.primaryText : OunjePalette.secondaryText)
                            .scaleEffect(selectedTab == tab ? 1.06 : 1)

                        Text(tab.title)
                            .sleeDisplayFont(selectedTab == tab ? 13 : 12)
                            .foregroundStyle(selectedTab == tab ? OunjePalette.primaryText : OunjePalette.secondaryText)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .contentShape(Rectangle())
                    .background {
                        if selectedTab == tab {
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(OunjePalette.surface.opacity(0.68))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                                        .stroke(OunjePalette.stroke.opacity(0.72), lineWidth: 1)
                                )
                                .matchedGeometryEffect(id: "tab-highlight", in: selectionNamespace)
                        }
                    }
                }
                .buttonStyle(OunjeCardPressButtonStyle())
            }
        }
        .padding(.horizontal, 10)
        .frame(height: OunjeLayout.tabBarHeight)
    }
}

private struct BottomNavigationDock: View {
    @Binding var selectedTab: AppTab
    var safeAreaBottom: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            CustomTabBar(selectedTab: $selectedTab)
                .frame(
                    maxWidth: .infinity,
                    minHeight: OunjeLayout.tabBarHeight + safeAreaBottom,
                    maxHeight: OunjeLayout.tabBarHeight + safeAreaBottom,
                    alignment: .center
                )
        }
        .frame(maxWidth: .infinity)
        .background(
            OunjePalette.navBar
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(OunjePalette.stroke)
                        .frame(height: 1)
                }
                .ignoresSafeArea(edges: .bottom)
        )
        .ignoresSafeArea(.keyboard, edges: .bottom)
    }
}

private struct DiscoverComposerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var savedStore: SavedRecipesStore
    @EnvironmentObject private var sharedImportInbox: SharedRecipeImportInboxStore
    @EnvironmentObject private var store: MealPlanningAppStore
    @EnvironmentObject private var toastCenter: AppToastCenter
    let context: CookbookComposerContext
    let initialText: String?
    @State private var draftText = ""
    @State private var selectedMediaItems: [PhotosPickerItem] = []
    @State private var attachments: [RecipeImportMediaDraft] = []
    @State private var isSubmitting = false
    @State private var isPreparingMedia = false
    @State private var attachmentMessage: String?
    @State private var errorMessage: String?
    @FocusState private var isTextFocused: Bool

    private var trimmedDraftText: String {
        draftText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSubmit: Bool {
        !trimmedDraftText.isEmpty || !attachments.isEmpty
    }

    private var hasPromptTextBeyondLinks: Bool {
        guard !trimmedDraftText.isEmpty else { return false }
        var remaining = trimmedDraftText
        for link in detectedLinks {
            remaining = remaining.replacingOccurrences(of: link, with: " ")
        }
        remaining = remaining
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return !remaining.isEmpty
    }

    private var primaryActionTitle: String {
        switch context {
        case .prepped:
            return "Prep"
        case .saved:
            return hasPromptTextBeyondLinks ? "Generate" : "Save"
        }
    }

    private var submittingActionTitle: String {
        switch context {
        case .prepped:
            return "Prepping..."
        case .saved:
            return hasPromptTextBeyondLinks ? "Generating..." : "Saving..."
        }
    }

    private var mediaButtonTitle: String {
        if isPreparingMedia {
            return "Preparing media…"
        }
        if attachments.isEmpty {
            return "Attach photo or video"
        }
        return attachments.count == 1 ? "1 attachment ready" : "\(attachments.count) attachments ready"
    }

    private var helperCopy: String {
        switch context {
        case .prepped:
            return "Paste a TikTok or IG link, attach a food photo, or describe what you want."
        case .saved:
            return "Paste a TikTok or IG link, attach a food photo, or describe what you want."
        }
    }

    private var detectedLinks: [String] {
        let nsRange = NSRange(draftText.startIndex..<draftText.endIndex, in: draftText)
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return []
        }
        var seen = Set<String>()
        var ordered: [String] = []
        detector.matches(in: draftText, options: [], range: nsRange).forEach { result in
            guard
                let range = Range(result.range, in: draftText),
                let url = result.url?.absoluteString ?? URL(string: String(draftText[range]))?.absoluteString
            else { return }
            if seen.insert(url).inserted {
                ordered.append(url)
            }
        }
        return ordered
    }

    var body: some View {
        ZStack {
            OunjePalette.background
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 18) {
                Capsule()
                    .fill(OunjePalette.stroke)
                    .frame(width: 72, height: 6)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 8)

                VStack(alignment: .leading, spacing: 14) {
                    Text(context == .saved ? "What are we saving?" : "What are we prepping?")
                        .font(.system(size: 24, weight: .regular, design: .serif))
                        .foregroundStyle(OunjePalette.primaryText)

                    Text(helperCopy)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(OunjePalette.secondaryText)

                    ZStack(alignment: .topTrailing) {
                        RoundedRectangle(cornerRadius: 28, style: .continuous)
                            .fill(OunjePalette.panel)
                            .overlay(
                                RoundedRectangle(cornerRadius: 28, style: .continuous)
                                    .stroke(OunjePalette.stroke.opacity(0.82), lineWidth: 1)
                            )

                        RoundedRectangle(cornerRadius: 28, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        OunjePalette.accent.opacity(0.20),
                                        .clear
                                    ],
                                    startPoint: .topTrailing,
                                    endPoint: .bottomLeading
                                )
                            )
                            .frame(width: 118, height: 80)
                            .blur(radius: 22)
                            .offset(x: 18, y: -10)

                        VStack(alignment: .leading, spacing: 16) {
                            if isPreparingMedia || !attachments.isEmpty || !detectedLinks.isEmpty {
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 10) {
                                        if isPreparingMedia {
                                            HStack(spacing: 8) {
                                                ProgressView()
                                                    .progressViewStyle(.circular)
                                                    .tint(OunjePalette.primaryText)
                                                Text("Preparing media")
                                                    .font(.system(size: 13, weight: .medium))
                                            }
                                            .foregroundStyle(OunjePalette.secondaryText)
                                            .padding(.horizontal, 12)
                                            .padding(.vertical, 10)
                                            .background(
                                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                                    .fill(OunjePalette.surface)
                                            )
                                        }

                                        ForEach(attachments) { attachment in
                                            HStack(spacing: 8) {
                                                Image(systemName: attachment.kind == .image ? "photo" : "video")
                                                    .font(.system(size: 13, weight: .semibold))
                                                Text(attachment.title)
                                                    .font(.system(size: 13, weight: .medium))
                                                    .lineLimit(1)
                                                Button {
                                                    removeAttachment(id: attachment.id)
                                                } label: {
                                                    Image(systemName: "xmark")
                                                        .font(.system(size: 11, weight: .bold))
                                                }
                                            }
                                            .foregroundStyle(OunjePalette.primaryText)
                                            .padding(.horizontal, 12)
                                            .padding(.vertical, 10)
                                            .background(
                                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                                    .fill(OunjePalette.surface)
                                                    .overlay(
                                                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                                                            .stroke(OunjePalette.stroke, lineWidth: 1)
                                                    )
                                            )
                                        }

                                        ForEach(detectedLinks, id: \.self) { link in
                                            HStack(spacing: 8) {
                                                Image(systemName: "link")
                                                    .font(.system(size: 13, weight: .semibold))
                                                Text(compactLinkLabel(for: link))
                                                    .font(.system(size: 13, weight: .medium))
                                                    .lineLimit(1)
                                                Button {
                                                    removeDetectedLink(link)
                                                } label: {
                                                    Image(systemName: "xmark")
                                                        .font(.system(size: 11, weight: .bold))
                                                }
                                            }
                                            .foregroundStyle(OunjePalette.primaryText)
                                            .padding(.horizontal, 12)
                                            .padding(.vertical, 10)
                                            .background(
                                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                                    .fill(OunjePalette.surface)
                                                    .overlay(
                                                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                                                            .stroke(OunjePalette.stroke, lineWidth: 1)
                                                    )
                                            )
                                        }
                                    }
                                }
                            }

                            TextEditor(text: $draftText)
                                .scrollContentBackground(.hidden)
                                .foregroundStyle(OunjePalette.primaryText)
                                .font(.system(size: 16, weight: .medium, design: .rounded))
                                .frame(minHeight: 120)
                                .focused($isTextFocused)
                                .overlay(alignment: .topLeading) {
                                    if draftText.isEmpty {
                                        Text(context == .saved
                                             ? "Drop a link, media, or a quick recipe idea."
                                             : "Drop a link, media, or a quick meal idea.")
                                            .font(.system(size: 15, weight: .medium, design: .rounded))
                                            .foregroundStyle(OunjePalette.secondaryText)
                                            .padding(.top, 8)
                                    }
                                }

                            HStack(alignment: .bottom, spacing: 12) {
                                PasteButton(payloadType: String.self) { pastedStrings in
                                    insertPastedLink(pastedStrings.first)
                                }
                                .buttonBorderShape(.roundedRectangle(radius: 14))
                                .tint(OunjePalette.surface)
                                .disabled(isSubmitting)

                                PhotosPicker(
                                    selection: $selectedMediaItems,
                                    maxSelectionCount: 4,
                                    matching: .any(of: [.images, .videos]),
                                    photoLibrary: .shared()
                                ) {
                                    HStack(spacing: 8) {
                                        Image(systemName: "paperclip")
                                            .font(.system(size: 14, weight: .semibold))
                                        Text(attachments.isEmpty ? "Photo/video" : mediaButtonTitle)
                                            .font(.system(size: 14, weight: .medium))
                                            .lineLimit(1)
                                    }
                                    .foregroundStyle(OunjePalette.primaryText)
                                    .opacity(isPreparingMedia ? 0.78 : 1)
                                }
                                .buttonStyle(.plain)

                                Spacer(minLength: 0)

                                Button {
                                    submitImport()
                                } label: {
                                    HStack(spacing: 8) {
                                        if isSubmitting {
                                            ProgressView()
                                                .progressViewStyle(.circular)
                                                .tint(.white)
                                                .scaleEffect(0.9)
                                        }
                                        Text(isSubmitting ? submittingActionTitle : primaryActionTitle)
                                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                                            .lineLimit(1)
                                            .fixedSize(horizontal: true, vertical: false)
                                        Image(systemName: "sparkles")
                                            .font(.system(size: 12, weight: .bold))
                                    }
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 18)
                                    .padding(.vertical, 12)
                                    .frame(minWidth: 112)
                                    .background(
                                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                                            .fill(Color(hex: "D97A3A"))
                                    )
                                }
                                .buttonStyle(.plain)
                                .disabled(!canSubmit || isSubmitting || isPreparingMedia)
                                .opacity(!canSubmit || isSubmitting || isPreparingMedia ? 0.62 : 1)
                            }

                        }
                        .padding(16)
                    }
                    if let errorMessage, !errorMessage.isEmpty {
                        Text(errorMessage)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color(red: 0.94, green: 0.53, blue: 0.49))
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 18)
            .padding(.top, 14)
            .padding(.bottom, 24)
        }
        .onAppear {
            if draftText.isEmpty,
               let initialText = initialText?.trimmingCharacters(in: .whitespacesAndNewlines),
               !initialText.isEmpty {
                draftText = initialText
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                isTextFocused = true
            }
        }
        .onChange(of: selectedMediaItems.count) { count in
            guard count > 0 else { return }
            let items = selectedMediaItems
            Task {
                await prepareAttachments(from: items)
            }
        }
    }

    private func submitImport() {
        guard canSubmit, !isSubmitting, !isPreparingMedia else { return }

        isSubmitting = true
        errorMessage = nil
        attachmentMessage = nil
        let hasImageAttachments = attachments.contains { $0.kind == .image }
        let isPhotoRecipeImport = detectedLinks.isEmpty && hasImageAttachments
        let isTypedPromptImport = detectedLinks.isEmpty && !trimmedDraftText.isEmpty && !isPhotoRecipeImport
        let photoContext = isPhotoRecipeImport
            ? RecipeImportPhotoContextPayload(
                dishHint: trimmedDraftText.isEmpty ? nil : trimmedDraftText,
                coarsePlaceContext: nil
            )
            : nil

        Task {
            do {
                let localEnvelope = SharedRecipeImportEnvelope(
                    id: UUID().uuidString,
                    createdAt: Date(),
                    jobID: nil,
                    targetState: context == .prepped ? "prepped" : "saved",
                    sourceText: trimmedDraftText,
                    sourceURLString: detectedLinks.first,
                    canonicalSourceURLString: nil,
                    sourceApp: isPhotoRecipeImport ? "Ounje Photo" : "Ounje",
                    attachments: [],
                    processingState: "queued",
                    attemptCount: 1,
                    lastAttemptAt: Date(),
                    lastError: nil,
                    updatedAt: Date()
                )
                try? SharedRecipeImportInbox.write(localEnvelope)
                await sharedImportInbox.refresh()

                let response = try await RecipeImportAPIService.shared.importRecipe(
                    userID: store.authSession?.userID,
                    accessToken: store.authSession?.accessToken,
                    sourceURL: detectedLinks.first,
                    sourceText: trimmedDraftText,
                    targetState: context == .prepped ? "prepped" : "saved",
                    attachments: attachments.map(\.payload),
                    photoContext: photoContext
                )

                await MainActor.run {
                    let importedRecipe = response.recipe
                    if let importedRecipe {
                        savedStore.saveImportedRecipe(importedRecipe, showToast: context == .saved)
                    }
                }
                NotificationCenter.default.post(name: .recipeImportHistoryNeedsRefresh, object: nil)

                if context == .prepped, let detail = response.recipeDetail {
                    await store.updateLatestPlan(with: recipeFromImportedDetail(detail), servings: detail.displayServings)
                }

                let backendProcessingState = response.job.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let isLiveBackendState = ["queued", "processing", "fetching", "parsing", "normalized"].contains(backendProcessingState)
                let reviewState = response.job.reviewState.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let canDisplayImportedRecipe = response.recipe != nil || response.recipeDetail != nil
                let importFailureReason = [
                    response.job.errorMessage,
                    response.job.reviewReason,
                    "Ounje could not extract a displayable recipe from this import."
                ]
                .compactMap { raw -> String? in
                    let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    return trimmed.isEmpty ? nil : trimmed
                }
                .first
                let shouldFailImport = backendProcessingState == "failed"
                    || (["draft", "needs_review"].contains(reviewState) && !canDisplayImportedRecipe)
                let normalizedProcessingState: String = {
                    switch backendProcessingState {
                    case "queued", "processing", "fetching", "parsing", "normalized", "saved":
                        return backendProcessingState
                    default:
                        return "queued"
                    }
                }()
                let shouldTrackAsQueued = !shouldFailImport && ((context == .saved && isTypedPromptImport) || isLiveBackendState)

                if shouldFailImport {
                    let failedEnvelope = SharedRecipeImportEnvelope(
                        id: localEnvelope.id,
                        createdAt: localEnvelope.createdAt,
                        jobID: response.job.id,
                        targetState: localEnvelope.targetState,
                        sourceText: localEnvelope.sourceText,
                        sourceURLString: localEnvelope.sourceURLString,
                        canonicalSourceURLString: [
                            response.recipeDetail?.originalRecipeURLString,
                            response.recipeDetail?.recipeURLString,
                            response.job.sourceURL
                        ]
                        .compactMap { raw -> String? in
                            let trimmed = raw?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines) ?? ""
                            return trimmed.isEmpty ? nil : trimmed
                        }
                        .first
                            ?? localEnvelope.canonicalSourceURLString,
                        sourceApp: localEnvelope.sourceApp,
                        attachments: localEnvelope.attachments,
                        processingState: "failed",
                        attemptCount: localEnvelope.attemptCount,
                        lastAttemptAt: Date(),
                        lastError: importFailureReason,
                        updatedAt: Date()
                    )
                    try? SharedRecipeImportInbox.update(failedEnvelope)
                } else if shouldTrackAsQueued {
                    let queuedEnvelope = SharedRecipeImportEnvelope(
                        id: localEnvelope.id,
                        createdAt: localEnvelope.createdAt,
                        jobID: response.job.id,
                        targetState: localEnvelope.targetState,
                        sourceText: localEnvelope.sourceText,
                        sourceURLString: localEnvelope.sourceURLString,
                        canonicalSourceURLString: [
                            response.recipeDetail?.originalRecipeURLString,
                            response.recipeDetail?.recipeURLString,
                            response.job.sourceURL
                        ]
                        .compactMap { raw -> String? in
                            let trimmed = raw?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines) ?? ""
                            return trimmed.isEmpty ? nil : trimmed
                        }
                        .first
                            ?? localEnvelope.canonicalSourceURLString,
                        sourceApp: localEnvelope.sourceApp,
                        attachments: localEnvelope.attachments,
                        processingState: normalizedProcessingState,
                        attemptCount: localEnvelope.attemptCount,
                        lastAttemptAt: Date(),
                        lastError: nil,
                        updatedAt: Date()
                    )
                    try? SharedRecipeImportInbox.update(queuedEnvelope)
                } else {
                    try? SharedRecipeImportInbox.delete(envelopeID: localEnvelope.id)
                }

                await sharedImportInbox.refresh()

                await MainActor.run {
                    isSubmitting = false

                    if shouldFailImport {
                        toastCenter.show(
                            title: "Couldn’t import recipe",
                            subtitle: importFailureReason,
                            systemImage: "exclamationmark.circle.fill",
                            destination: .recipeImportQueue(.failed)
                        )
                    } else if shouldTrackAsQueued {
                        toastCenter.show(
                            title: "Import queued",
                            subtitle: isPhotoRecipeImport ? "Ounje is checking the dish photo now." : "Ounje is pulling the recipe in now.",
                            systemImage: isPhotoRecipeImport ? "camera.viewfinder" : "tray.and.arrow.down.fill",
                            destination: .recipeImportQueue(.queued)
                        )
                    } else if context == .prepped, let detail = response.recipeDetail {
                        toastCenter.show(
                            title: "Added to next prep",
                            subtitle: detail.title,
                            systemImage: "sparkles",
                            thumbnailURLString: detail.discoverCardImageURLString ?? detail.heroImageURLString ?? detail.imageURL?.absoluteString,
                            destination: .appTab(.prep)
                        )
                    }

                    dismiss()
                }
            } catch {
                await MainActor.run {
                    isSubmitting = false
                    errorMessage = (error as? RecipeImportServiceError).map {
                        switch $0 {
                        case .invalidRequest:
                            return "The import request could not be built."
                        case .invalidResponse:
                            return "The import response came back in an unexpected format."
                        case .requestFailed(let message):
                            return message
                        }
                    } ?? error.localizedDescription
                }
            }
        }
    }

    private func prepareAttachments(from items: [PhotosPickerItem]) async {
        await MainActor.run {
            isPreparingMedia = true
            attachmentMessage = "Preparing attachments…"
            errorMessage = nil
        }

        do {
            var drafts: [RecipeImportMediaDraft] = []
            for item in items.prefix(4) {
                if let draft = try await RecipeImportMediaDraft.load(
                    from: item,
                    userID: store.authSession?.userID,
                    accessToken: store.authSession?.accessToken
                ) {
                    drafts.append(draft)
                }
            }

            await MainActor.run {
                attachments = drafts
                selectedMediaItems = []
                isPreparingMedia = false
                attachmentMessage = drafts.isEmpty
                    ? nil
                    : drafts.count == 1
                        ? "1 attachment ready"
                        : "\(drafts.count) attachments ready"
            }
        } catch {
            await MainActor.run {
                attachments = []
                selectedMediaItems = []
                isPreparingMedia = false
                attachmentMessage = nil
                errorMessage = error.localizedDescription
            }
        }
    }

    private func removeAttachment(id: UUID) {
        attachments.removeAll { $0.id == id }
        attachmentMessage = attachments.isEmpty
            ? nil
            : attachments.count == 1
                ? "1 attachment ready"
                : "\(attachments.count) attachments ready"
    }

    private func compactLinkLabel(for link: String) -> String {
        guard let url = URL(string: link), let host = url.host, !host.isEmpty else {
            return link
        }
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if path.isEmpty {
            return host
        }
        let firstPath = path.split(separator: "/").first.map(String.init) ?? ""
        return "\(host)/\(firstPath)"
    }

    private func removeDetectedLink(_ link: String) {
        draftText = draftText.replacingOccurrences(of: link, with: "")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func insertPastedLink(_ rawValue: String?) {
        errorMessage = nil
        if let raw = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty {
            let normalized: String
            if raw.lowercased().hasPrefix("http://") || raw.lowercased().hasPrefix("https://") {
                normalized = raw
            } else if raw.contains(".") && !raw.contains(" ") {
                normalized = "https://\(raw)"
            } else {
                errorMessage = "No valid link found in clipboard."
                isTextFocused = true
                return
            }
            if !draftText.isEmpty, !draftText.hasSuffix("\n") {
                draftText.append("\n")
            }
            draftText.append(normalized)
            isTextFocused = true
            return
        }

        errorMessage = "Copy a link first, then tap Paste."
        isTextFocused = true
    }

    private func recipeFromImportedDetail(_ detail: RecipeDetailData) -> Recipe {
        let ingredientSource = detail.ingredients.isEmpty ? detail.steps.flatMap(\.ingredients) : detail.ingredients
        let ingredients = ingredientSource.map { ingredient in
            let measurement = parsedIngredientMeasurement(from: ingredient.quantityText)
            return RecipeIngredient(
                name: ingredient.displayTitle,
                amount: measurement?.amount ?? 1,
                unit: measurement?.unit ?? "ct",
                estimatedUnitPrice: 0
            )
        }

        return Recipe(
            id: detail.id,
            title: detail.title,
            cuisine: cuisinePreference(from: detail),
            prepMinutes: resolvedRecipeDurationMinutes(from: detail),
            servings: max(1, detail.displayServings),
            storageFootprint: .medium,
            tags: recipeTags(from: detail),
            ingredients: ingredients,
            cardImageURLString: detail.discoverCardImageURLString ?? detail.imageURL?.absoluteString,
            heroImageURLString: detail.heroImageURLString ?? detail.imageURL?.absoluteString,
            source: detail.source ?? detail.sourcePlatform ?? detail.authorLine
        )
    }

    private func parsedIngredientMeasurement(from quantityText: String?) -> (amount: Double, unit: String)? {
        guard let quantityText else { return nil }
        let raw = quantityText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }

        let pattern = #"^(\d+\s+\d\/\d|\d+\/\d|\d+(?:\.\d+)?)(?:\s+(.*))?$"#
        guard
            let regex = try? NSRegularExpression(pattern: pattern),
            let match = regex.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)),
            let amountRange = Range(match.range(at: 1), in: raw)
        else {
            return nil
        }

        let amountText = String(raw[amountRange])
        let unitText: String
        if let unitRange = Range(match.range(at: 2), in: raw) {
            unitText = String(raw[unitRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            unitText = "ct"
        }

        if amountText.contains(" ") {
            let pieces = amountText.split(separator: " ", maxSplits: 1).map(String.init)
            if pieces.count == 2, let whole = Double(pieces[0]), let fraction = fractionalAmount(from: pieces[1]) {
                return (whole + fraction, unitText.isEmpty ? "ct" : unitText)
            }
        }

        if let fraction = fractionalAmount(from: amountText) {
            return (fraction, unitText.isEmpty ? "ct" : unitText)
        }

        if let amount = Double(amountText) {
            return (amount, unitText.isEmpty ? "ct" : unitText)
        }

        return nil
    }

    private func fractionalAmount(from raw: String) -> Double? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains("/") else { return nil }
        let pieces = trimmed.split(separator: "/", maxSplits: 1).map(String.init)
        guard pieces.count == 2, let numerator = Double(pieces[0]), let denominator = Double(pieces[1]), denominator != 0 else {
            return nil
        }
        return numerator / denominator
    }

    private func cuisinePreference(from detail: RecipeDetailData) -> CuisinePreference {
        let raw = (detail.cuisineTags.first ?? detail.category ?? detail.recipeType ?? "american")
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
            .lowercased()

        switch raw {
        case "italian":
            return .italian
        case "mexican":
            return .mexican
        case "mediterranean":
            return .mediterranean
        case "asian":
            return .asian
        case "indian":
            return .indian
        case "american":
            return .american
        case "middleeastern", "levantine":
            return .middleEastern
        case "japanese":
            return .japanese
        case "thai":
            return .thai
        case "korean":
            return .korean
        case "chinese":
            return .chinese
        case "greek":
            return .greek
        case "french":
            return .french
        case "spanish":
            return .spanish
        case "caribbean":
            return .caribbean
        case "westafrican", "nigerian":
            return .westAfrican
        case "ethiopian":
            return .ethiopian
        case "brazilian":
            return .brazilian
        case "vegan":
            return .vegan
        default:
            return .american
        }
    }

    private func recipeTags(from detail: RecipeDetailData) -> [String] {
        let combinedTags = detail.dietaryTags + detail.flavorTags + detail.occasionTags + [detail.recipeType, detail.category].compactMap { $0 }
        return Array(
            Set(
                combinedTags
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            )
        ).sorted()
    }
}

private struct RecipeImportMediaDraft: Identifiable {
    enum Kind {
        case image
        case video
    }

    let id = UUID()
    let kind: Kind
    let title: String
    let subtitle: String
    let payload: RecipeImportAttachmentPayload

    static func load(from item: PhotosPickerItem, userID: String?, accessToken: String?) async throws -> RecipeImportMediaDraft? {
        let imageType = item.supportedContentTypes.first(where: { $0.conforms(to: .image) })
        let videoType = item.supportedContentTypes.first(where: { $0.conforms(to: .movie) || $0.conforms(to: .video) })

        if let imageType {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                throw RecipeImportMediaError.unreadable
            }
            return try await makeImageAttachment(from: data, contentType: imageType, userID: userID, accessToken: accessToken)
        }

        if let videoType {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                throw RecipeImportMediaError.unreadable
            }
            return try await makeVideoAttachment(from: data, contentType: videoType)
        }

        throw RecipeImportMediaError.unsupported
    }

    static func loadCapturedImage(_ image: UIImage, userID: String?, accessToken: String?) async throws -> RecipeImportMediaDraft {
        guard let data = image.jpegData(compressionQuality: 0.9) else {
            throw RecipeImportMediaError.unreadable
        }
        return try await makeImageAttachment(from: data, contentType: .jpeg, userID: userID, accessToken: accessToken)
    }

    private static func makeImageAttachment(from data: Data, contentType: UTType, userID: String?, accessToken: String?) async throws -> RecipeImportMediaDraft {
        guard let image = UIImage(data: data) else {
            throw RecipeImportMediaError.unreadable
        }

        let prepared = image.ounjeResized(maxDimension: 1600)
        let jpegData = prepared.jpegData(compressionQuality: 0.82) ?? data
        let heroImage = image.ounjeCenterCroppedSquare().ounjeResized(maxDimension: 1200)
        let heroData = heroImage.jpegData(compressionQuality: 0.86) ?? jpegData

        let payload: RecipeImportAttachmentPayload
        if let userID, let accessToken, !userID.isEmpty, !accessToken.isEmpty,
           let uploaded = try? await RecipeImportPhotoStorageUploader.uploadPhotoPair(
            sourceData: jpegData,
            heroData: heroData,
            userID: userID,
            accessToken: accessToken
           ) {
            payload = RecipeImportAttachmentPayload(
                kind: "image",
                sourceURL: nil,
                dataURL: nil,
                mimeType: "image/jpeg",
                fileName: "recipe-photo.\(contentType.preferredFilenameExtension ?? "jpg")",
                previewFrameURLs: [],
                storageBucket: uploaded.privateBucket,
                storagePath: uploaded.privatePath,
                publicHeroURL: uploaded.publicHeroURL,
                width: Int(prepared.size.width),
                height: Int(prepared.size.height)
            )
        } else {
            let fallbackLimit = 1_250_000
            guard jpegData.count <= fallbackLimit else {
                throw RecipeImportMediaError.uploadRequired
            }
            payload = RecipeImportAttachmentPayload(
                kind: "image",
                sourceURL: nil,
                dataURL: "data:image/jpeg;base64,\(jpegData.base64EncodedString())",
                mimeType: "image/jpeg",
                fileName: "recipe-photo.\(contentType.preferredFilenameExtension ?? "jpg")",
                previewFrameURLs: [],
                width: Int(prepared.size.width),
                height: Int(prepared.size.height)
            )
        }

        let subtitle = ByteCountFormatter.string(fromByteCount: Int64(jpegData.count), countStyle: .file)
        return RecipeImportMediaDraft(
            kind: .image,
            title: "Photo attached",
            subtitle: subtitle,
            payload: payload
        )
    }

    private static func makeVideoAttachment(from data: Data, contentType: UTType) async throws -> RecipeImportMediaDraft {
        let byteLimit = 25 * 1024 * 1024
        guard data.count <= byteLimit else {
            throw RecipeImportMediaError.videoTooLarge
        }

        let extensionName = contentType.preferredFilenameExtension ?? "mov"
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ounje-import-\(UUID().uuidString)")
            .appendingPathExtension(extensionName)
        try data.write(to: tempURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let frameDataURLs = try await previewFrameDataURLs(from: tempURL)
        guard !frameDataURLs.isEmpty else {
            throw RecipeImportMediaError.videoPreviewUnavailable
        }

        let payload = RecipeImportAttachmentPayload(
            kind: "video",
            sourceURL: nil,
            dataURL: nil,
            mimeType: contentType.preferredMIMEType ?? "video/quicktime",
            fileName: "recipe-video.\(extensionName)",
            previewFrameURLs: frameDataURLs
        )

        let subtitle = frameDataURLs.count == 1
            ? "1 preview frame ready"
            : "\(frameDataURLs.count) preview frames ready"
        return RecipeImportMediaDraft(
            kind: .video,
            title: "Short video attached",
            subtitle: subtitle,
            payload: payload
        )
    }

    private static func previewFrameDataURLs(from videoURL: URL) async throws -> [String] {
        let asset = AVAsset(url: videoURL)
        let duration = try await asset.load(.duration)
        let durationSeconds = max(CMTimeGetSeconds(duration), 0.6)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1200, height: 1200)

        let fractions: [Double] = durationSeconds < 1.2 ? [0.3, 0.7] : [0.18, 0.5, 0.82]
        return fractions.compactMap { fraction in
            let second = max(0.05, min(durationSeconds * fraction, max(durationSeconds - 0.05, 0.05)))
            let time = CMTime(seconds: second, preferredTimescale: 600)
            guard let cgImage = try? generator.copyCGImage(at: time, actualTime: nil) else {
                return nil
            }
            let image = UIImage(cgImage: cgImage).ounjeResized(maxDimension: 1200)
            guard let data = image.jpegData(compressionQuality: 0.78) else {
                return nil
            }
            return "data:image/jpeg;base64,\(data.base64EncodedString())"
        }
    }
}

private enum RecipeImportPhotoStorageUploader {
    struct UploadedPair {
        let privateBucket: String
        let privatePath: String
        let publicHeroURL: String
    }

    private struct UploadRequest: Encodable {
        let userID: String
        let sourceImageBase64: String
        let heroImageBase64: String
        let mimeType: String

        enum CodingKeys: String, CodingKey {
            case userID = "user_id"
            case sourceImageBase64 = "source_image_base64"
            case heroImageBase64 = "hero_image_base64"
            case mimeType = "mime_type"
        }
    }

    private struct UploadResponse: Decodable {
        let privateBucket: String
        let privatePath: String
        let publicHeroURL: String

        enum CodingKeys: String, CodingKey {
            case privateBucket = "private_bucket"
            case privatePath = "private_path"
            case publicHeroURL = "public_hero_url"
        }
    }

    static func uploadPhotoPair(
        sourceData: Data,
        heroData: Data,
        userID: String,
        accessToken: String
    ) async throws -> UploadedPair {
        var lastError: Error?
        for baseURL in OunjeDevelopmentServer.workerCandidateBaseURLs {
            do {
                return try await uploadPhotoPair(
                    baseURL: baseURL,
                    sourceData: sourceData,
                    heroData: heroData,
                    userID: userID,
                    accessToken: accessToken
                )
            } catch {
                lastError = error
            }
        }

        throw lastError ?? RecipeImportMediaError.uploadRequired
    }

    private static func uploadPhotoPair(
        baseURL: String,
        sourceData: Data,
        heroData: Data,
        userID: String,
        accessToken: String
    ) async throws -> UploadedPair {
        guard let url = URL(string: "\(baseURL)/v1/recipe/import-media/photo-pair") else {
            throw RecipeImportMediaError.uploadRequired
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 45
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(userID, forHTTPHeaderField: "x-user-id")
        request.httpBody = try JSONEncoder().encode(
            UploadRequest(
                userID: userID,
                sourceImageBase64: sourceData.base64EncodedString(),
                heroImageBase64: heroData.base64EncodedString(),
                mimeType: "image/jpeg"
            )
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200 ... 299).contains(httpResponse.statusCode) else {
            if let errorPayload = try? JSONDecoder().decode(SupabaseRestErrorResponse.self, from: data),
               let message = errorPayload.message ?? errorPayload.error,
               !message.isEmpty {
                throw RecipeImportMediaError.uploadRequired
            }
            throw RecipeImportMediaError.uploadRequired
        }

        let payload = try JSONDecoder().decode(UploadResponse.self, from: data)
        return UploadedPair(
            privateBucket: payload.privateBucket,
            privatePath: payload.privatePath,
            publicHeroURL: payload.publicHeroURL
        )
    }
}

private func sharedImportAttachmentPayloads(
    from attachments: [SharedRecipeImportAttachment]
) async throws -> [RecipeImportAttachmentPayload] {
    try await attachments.asyncCompactMap { attachment in
        let fileURL = try SharedRecipeImportInbox.absoluteURL(forRelativePath: attachment.relativePath)
        switch attachment.kind.lowercased() {
        case "image":
            let data = try Data(contentsOf: fileURL)
            return try makeRecipeImportImageAttachment(
                from: data,
                mimeType: attachment.mimeType,
                fileName: attachment.fileName
            )
        case "video":
            return try await makeRecipeImportVideoAttachment(
                from: fileURL,
                mimeType: attachment.mimeType,
                fileName: attachment.fileName
            )
        default:
            return nil
        }
    }
}

private func makeRecipeImportImageAttachment(
    from data: Data,
    mimeType: String?,
    fileName: String
) throws -> RecipeImportAttachmentPayload {
    guard let image = UIImage(data: data) else {
        throw RecipeImportMediaError.unreadable
    }

    let prepared = image.ounjeResized(maxDimension: 1600)
    let jpegData = prepared.jpegData(compressionQuality: 0.82) ?? data
    return RecipeImportAttachmentPayload(
        kind: "image",
        sourceURL: nil,
        dataURL: "data:image/jpeg;base64,\(jpegData.base64EncodedString())",
        mimeType: mimeType ?? "image/jpeg",
        fileName: fileName,
        previewFrameURLs: []
    )
}

private func makeRecipeImportVideoAttachment(
    from fileURL: URL,
    mimeType: String?,
    fileName: String
) async throws -> RecipeImportAttachmentPayload {
    let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
    let byteLimit = 25 * 1024 * 1024
    if let size = attributes[.size] as? NSNumber, size.intValue > byteLimit {
        throw RecipeImportMediaError.videoTooLarge
    }

    let frameDataURLs = try await recipeImportPreviewFrameDataURLs(from: fileURL)
    guard !frameDataURLs.isEmpty else {
        throw RecipeImportMediaError.videoPreviewUnavailable
    }

    return RecipeImportAttachmentPayload(
        kind: "video",
        sourceURL: nil,
        dataURL: nil,
        mimeType: mimeType ?? "video/quicktime",
        fileName: fileName,
        previewFrameURLs: frameDataURLs
    )
}

private func recipeImportPreviewFrameDataURLs(from videoURL: URL) async throws -> [String] {
    let asset = AVAsset(url: videoURL)
    let duration = try await asset.load(.duration)
    let durationSeconds = max(CMTimeGetSeconds(duration), 0.6)
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    generator.maximumSize = CGSize(width: 1200, height: 1200)

    let fractions: [Double] = durationSeconds < 1.2 ? [0.3, 0.7] : [0.18, 0.5, 0.82]
    return fractions.compactMap { fraction in
        let second = max(0.05, min(durationSeconds * fraction, max(durationSeconds - 0.05, 0.05)))
        let time = CMTime(seconds: second, preferredTimescale: 600)
        guard let cgImage = try? generator.copyCGImage(at: time, actualTime: nil) else {
            return nil
        }
        let image = UIImage(cgImage: cgImage).ounjeResized(maxDimension: 1200)
        guard let data = image.jpegData(compressionQuality: 0.78) else {
            return nil
        }
        return "data:image/jpeg;base64,\(data.base64EncodedString())"
    }
}

private func parsedCookMinutes(from text: String?) -> Int? {
    guard let text else { return nil }
    let lowered = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    guard !lowered.isEmpty else { return nil }

    var hours = 0
    var minutes = 0

    if let hourRegex = try? NSRegularExpression(pattern: #"(\\d{1,2})\\s*(?:h|hr|hrs|hour|hours)"#),
       let hourMatch = hourRegex.firstMatch(in: lowered, range: NSRange(lowered.startIndex..., in: lowered)),
       let hourRange = Range(hourMatch.range(at: 1), in: lowered),
       let parsedHours = Int(lowered[hourRange]) {
        hours = parsedHours
    }

    if let minuteRegex = try? NSRegularExpression(pattern: #"(\\d{1,3})\\s*(?:m|min|mins|minute|minutes)"#),
       let minuteMatch = minuteRegex.firstMatch(in: lowered, range: NSRange(lowered.startIndex..., in: lowered)),
       let minuteRange = Range(minuteMatch.range(at: 1), in: lowered),
       let parsedMinutes = Int(lowered[minuteRange]) {
        minutes = parsedMinutes
    }

    let total = (hours * 60) + minutes
    if total > 0 { return total }

    guard let firstNumberRange = lowered.range(of: #"\d{1,3}"#, options: .regularExpression),
          let firstNumber = Int(lowered[firstNumberRange]) else {
        return nil
    }

    if lowered.contains("hour") || lowered.contains("hr") || lowered.contains(" h") {
        return firstNumber * 60
    }

    return firstNumber
}

func resolvedRecipeDurationMinutes(from detail: RecipeDetailData) -> Int {
    if let parsedTextMinutes = parsedCookMinutes(from: detail.cookTimeText), parsedTextMinutes > 0 {
        return parsedTextMinutes
    }

    let prep = max(0, detail.prepTimeMinutes ?? 0)
    let cook = max(0, detail.cookTimeMinutes ?? 0)

    if prep > 0 && cook > 0 {
        return prep + cook
    }

    return max(prep, cook)
}

func importedRecipePlanModel(from detail: RecipeDetailData) -> Recipe {
    recipePlanModel(from: detail, targetServings: detail.displayServings, fallbackRecipe: nil)
}

func recipePlanModel(
    from detail: RecipeDetailData,
    targetServings: Int,
    fallbackRecipe: Recipe?
) -> Recipe {
    let resolvedTargetServings = max(1, targetServings)
    let scale = Double(resolvedTargetServings) / Double(max(1, detail.displayServings))
    let ingredientSource = detail.ingredients.isEmpty ? detail.steps.flatMap(\.ingredients) : detail.ingredients
    let ingredients = ingredientSource
        .map { $0.scaled(by: scale) }
        .map { ingredient in
        let measurement = importedRecipeMeasurement(from: ingredient.displayQuantityText ?? ingredient.quantityText)
        let normalized = normalizedRecipeIngredientNameAndUnit(
            displayTitle: ingredient.displayTitle,
            measurementUnit: measurement?.unit
        )
        return RecipeIngredient(
            name: normalized.name,
            amount: measurement?.amount ?? 1,
            unit: normalized.unit ?? measurement?.unit ?? "ct",
            estimatedUnitPrice: 0
        )
    }

    return Recipe(
        id: detail.id,
        title: detail.title,
        cuisine: importedRecipeCuisinePreference(from: detail),
        prepMinutes: resolvedRecipeDurationMinutes(from: detail),
        servings: resolvedTargetServings,
        storageFootprint: .medium,
        tags: importedRecipeTags(from: detail),
        ingredients: ingredients,
        cardImageURLString: detail.discoverCardImageURLString
            ?? detail.imageURL?.absoluteString
            ?? fallbackRecipe?.cardImageURLString,
        heroImageURLString: detail.heroImageURLString
            ?? detail.imageURL?.absoluteString
            ?? fallbackRecipe?.heroImageURLString,
        source: detail.source
    )
}

private func normalizedRecipeIngredientNameAndUnit(
    displayTitle: String,
    measurementUnit: String?
) -> (name: String, unit: String?) {
    let trimmedTitle = displayTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let measurementUnit else {
        return (trimmedTitle, nil)
    }

    let unitTokens = measurementUnit
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .split(whereSeparator: { $0.isWhitespace })
        .map(String.init)
    guard let firstUnitToken = unitTokens.first else {
        return (trimmedTitle, nil)
    }

    let knownUnits: Set<String> = [
        "cup", "cups", "tbsp", "tbsps", "tablespoon", "tablespoons",
        "tsp", "tsps", "teaspoon", "teaspoons",
        "lb", "lbs", "pound", "pounds", "oz", "ounce", "ounces",
        "g", "gram", "grams", "kg", "kilogram", "kilograms",
        "ml", "milliliter", "milliliters", "l", "liter", "liters",
        "clove", "cloves", "slice", "slices", "can", "cans",
        "jar", "jars", "package", "packages", "medium", "large", "small"
    ]
    let normalizedUnit = firstUnitToken
        .trimmingCharacters(in: .punctuationCharacters)
        .lowercased()
    let titleLooksAbbreviated = trimmedTitle.count <= 4
        && trimmedTitle.rangeOfCharacter(from: .letters) != nil
        && trimmedTitle.rangeOfCharacter(from: .whitespacesAndNewlines) == nil

    if knownUnits.contains(normalizedUnit), unitTokens.count > 1, titleLooksAbbreviated {
        let recoveredName = unitTokens.dropFirst().joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !recoveredName.isEmpty {
            return (recoveredName, firstUnitToken)
        }
    }

    return (trimmedTitle, measurementUnit)
}

private func importedRecipeMeasurement(from quantityText: String?) -> (amount: Double, unit: String)? {
    guard let quantityText else { return nil }
    let raw = quantityText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !raw.isEmpty else { return nil }

    let pattern = #"^(\d+\s+\d\/\d|\d+\/\d|\d+(?:\.\d+)?)(?:\s+(.*))?$"#
    guard
        let regex = try? NSRegularExpression(pattern: pattern),
        let match = regex.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)),
        let amountRange = Range(match.range(at: 1), in: raw)
    else {
        return nil
    }

    let amountText = String(raw[amountRange])
    let unitText: String
    if let unitRange = Range(match.range(at: 2), in: raw) {
        unitText = String(raw[unitRange]).trimmingCharacters(in: .whitespacesAndNewlines)
    } else {
        unitText = "ct"
    }

    if amountText.contains(" ") {
        let pieces = amountText.split(separator: " ", maxSplits: 1).map(String.init)
        if pieces.count == 2, let whole = Double(pieces[0]), let fraction = importedRecipeFraction(from: pieces[1]) {
            return (whole + fraction, unitText.isEmpty ? "ct" : unitText)
        }
    }

    if let fraction = importedRecipeFraction(from: amountText) {
        return (fraction, unitText.isEmpty ? "ct" : unitText)
    }

    if let amount = Double(amountText) {
        return (amount, unitText.isEmpty ? "ct" : unitText)
    }

    return nil
}

private func importedRecipeFraction(from raw: String) -> Double? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.contains("/") else { return nil }
    let pieces = trimmed.split(separator: "/", maxSplits: 1).map(String.init)
    guard pieces.count == 2, let numerator = Double(pieces[0]), let denominator = Double(pieces[1]), denominator != 0 else {
        return nil
    }
    return numerator / denominator
}

private func importedRecipeCuisinePreference(from detail: RecipeDetailData) -> CuisinePreference {
    let raw = (detail.cuisineTags.first ?? detail.category ?? detail.recipeType ?? "american")
        .replacingOccurrences(of: " ", with: "")
        .replacingOccurrences(of: "-", with: "")
        .lowercased()

    switch raw {
    case "italian":
        return .italian
    case "mexican":
        return .mexican
    case "mediterranean":
        return .mediterranean
    case "asian":
        return .asian
    case "indian":
        return .indian
    case "american":
        return .american
    case "middleeastern", "levantine":
        return .middleEastern
    case "japanese":
        return .japanese
    case "thai":
        return .thai
    case "korean":
        return .korean
    case "chinese":
        return .chinese
    case "greek":
        return .greek
    case "french":
        return .french
    case "spanish":
        return .spanish
    case "caribbean":
        return .caribbean
    case "westafrican", "nigerian":
        return .westAfrican
    case "ethiopian":
        return .ethiopian
    case "brazilian":
        return .brazilian
    case "vegan":
        return .vegan
    default:
        return .american
    }
}

private func importedRecipeTags(from detail: RecipeDetailData) -> [String] {
    let rawTags = detail.dietaryTags + detail.flavorTags + detail.cuisineTags + detail.occasionTags
    let contextualTags = [
        detail.recipeType,
        detail.category,
        detail.subcategory,
        detail.cookMethod,
        detail.mainProtein
    ].compactMap { $0 }

    var seen = Set<String>()
    return (rawTags + contextualTags)
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        .filter { !$0.isEmpty }
        .filter { seen.insert($0).inserted }
}

private extension Sequence {
    func asyncCompactMap<T>(_ transform: (Element) async throws -> T?) async rethrows -> [T] {
        var results: [T] = []
        for element in self {
            if let transformed = try await transform(element) {
                results.append(transformed)
            }
        }
        return results
    }
}

private enum RecipeImportMediaError: LocalizedError {
    case unsupported
    case unreadable
    case videoTooLarge
    case videoPreviewUnavailable
    case uploadRequired

    var errorDescription: String? {
        switch self {
        case .unsupported:
            return "That file type is not supported yet."
        case .unreadable:
            return "We couldn’t read that attachment. Try another photo or a shorter video."
        case .videoTooLarge:
            return "Short videos only for now. Try one under 25 MB."
        case .videoPreviewUnavailable:
            return "We couldn’t pull clear frames from that video."
        case .uploadRequired:
            return "We couldn’t upload that photo. Try again with a smaller image or check your connection."
        }
    }
}

extension UIImage {
    func ounjeResized(maxDimension: CGFloat) -> UIImage {
        let largestDimension = max(size.width, size.height)
        guard largestDimension > maxDimension, largestDimension > 0 else {
            return self
        }

        let scaleRatio = maxDimension / largestDimension
        let targetSize = CGSize(
            width: floor(size.width * scaleRatio),
            height: floor(size.height * scaleRatio)
        )

        let renderer = UIGraphicsImageRenderer(size: targetSize)
        return renderer.image { _ in
            draw(in: CGRect(origin: .zero, size: targetSize))
        }
    }

    func ounjeCenterCroppedSquare() -> UIImage {
        let side = min(size.width, size.height)
        guard side > 0 else { return self }
        let cropRect = CGRect(
            x: (size.width - side) / 2,
            y: (size.height - side) / 2,
            width: side,
            height: side
        )
        guard let cgImage = cgImage?.cropping(to: cropRect.applying(CGAffineTransform(scaleX: scale, y: scale))) else {
            return self
        }
        return UIImage(cgImage: cgImage, scale: scale, orientation: imageOrientation)
    }
}

private struct ComposerActionChip: View {
    let title: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .bold))
            Text(title)
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.9)
            Spacer(minLength: 0)
        }
        .foregroundStyle(OunjePalette.primaryText)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: 46, alignment: .leading)
        .background(
            Capsule(style: .continuous)
                .fill(OunjePalette.surface)
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(OunjePalette.stroke, lineWidth: 1)
                )
        )
    }
}

struct ThemedCard<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        BubblySurfaceCard(accent: OunjePalette.accent, content: content)
    }
}

private struct MainAppBackdrop: View {
    @State private var isAnimating = false

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    OunjePalette.background,
                    OunjePalette.panel,
                    OunjePalette.background
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            Circle()
                .fill(OunjePalette.accent.opacity(0.10))
                .frame(width: 260, height: 260)
                .blur(radius: 50)
                .offset(x: isAnimating ? 130 : 80, y: isAnimating ? -250 : -190)

            Circle()
                .fill(OunjePalette.softCream.opacity(0.10))
                .frame(width: 220, height: 220)
                .blur(radius: 44)
                .offset(x: isAnimating ? -110 : -70, y: isAnimating ? 190 : 130)

            Circle()
                .fill(OunjePalette.softCream.opacity(0.14))
                .frame(width: 160, height: 160)
                .blur(radius: 28)
                .offset(x: isAnimating ? 150 : 95, y: isAnimating ? 420 : 360)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 6.5).repeatForever(autoreverses: true)) {
                isAnimating = true
            }
        }
    }
}

struct BubblySurfaceCard<Content: View>: View {
    var accent: Color = OunjePalette.accent
    @ViewBuilder let content: () -> Content

    @State private var isAnimated = false

    var body: some View {
        content()
            .foregroundStyle(OunjePalette.primaryText)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                ZStack(alignment: .topTrailing) {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    OunjePalette.surface.opacity(0.98),
                                    OunjePalette.panel.opacity(0.96)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )

                    Circle()
                        .fill(accent.opacity(0.13))
                        .frame(width: 100, height: 100)
                        .blur(radius: 22)
                        .offset(x: isAnimated ? 16 : 6, y: isAnimated ? -18 : -8)
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(OunjePalette.stroke, lineWidth: 1)
            )
            .shadow(color: OunjePalette.primaryText.opacity(0.06), radius: 12, x: 0, y: 6)
            .onAppear {
                withAnimation(.easeInOut(duration: 3.6).repeatForever(autoreverses: true)) {
                    isAnimated = true
                }
            }
    }
}

private struct MainAppHeader: View {
    let eyebrow: String
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(eyebrow.uppercased())
                .biroHeaderFont(12)
                .tracking(1.2)
                .foregroundStyle(OunjePalette.accent)

            Text(title)
                .biroHeaderFont(31)
                .foregroundStyle(OunjePalette.primaryText)
                .fixedSize(horizontal: false, vertical: true)

            Text(detail)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(OunjePalette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct MainAppSectionHeader: View {
    let eyebrow: String
    let title: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(eyebrow.uppercased())
                .biroHeaderFont(11)
                .tracking(1)
                .foregroundStyle(OunjePalette.softCream.opacity(0.72))
            Text(title)
                .biroHeaderFont(18)
                .foregroundStyle(OunjePalette.primaryText)
        }
    }
}

private struct SignedInHeroCard<Content: View>: View {
    let title: String
    let detail: String
    let badge: String
    let symbolName: String
    let primary: Color
    let secondary: Color
    @ViewBuilder let content: () -> Content

    @State private var isAnimating = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(badge)
                        .font(.system(size: 11, weight: .black))
                        .foregroundStyle(.black.opacity(0.82))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.white.opacity(0.88), in: Capsule())

                    Text(title)
                        .biroHeaderFont(24)
                        .foregroundStyle(OunjePalette.primaryText)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(detail)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(OunjePalette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                ZStack {
                    Circle()
                        .fill(.white.opacity(0.12))
                        .frame(width: 54, height: 54)
                        .scaleEffect(isAnimating ? 1.08 : 0.95)

                    Image(systemName: symbolName)
                        .font(.system(size: 20, weight: .black))
                        .foregroundStyle(.black.opacity(0.82))
                        .frame(width: 44, height: 44)
                        .background(.white.opacity(0.9), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .rotationEffect(.degrees(isAnimating ? 5 : -5))
                }
            }

            content()
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                OunjePalette.surface,
                                OunjePalette.panel
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                primary.opacity(0.28),
                                secondary.opacity(0.18),
                                .clear
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                Circle()
                    .fill(primary.opacity(0.22))
                    .frame(width: 150, height: 150)
                    .blur(radius: 28)
                    .offset(x: isAnimating ? 110 : 70, y: isAnimating ? -90 : -50)

                Circle()
                    .fill(secondary.opacity(0.16))
                    .frame(width: 110, height: 110)
                    .blur(radius: 24)
                    .offset(x: isAnimating ? -90 : -50, y: isAnimating ? 100 : 60)
            }
        )
        .overlay(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .stroke(.white.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: primary.opacity(0.12), radius: 22, x: 0, y: 14)
        .onAppear {
            withAnimation(.easeInOut(duration: 4.5).repeatForever(autoreverses: true)) {
                isAnimating = true
            }
        }
    }
}

private struct DashboardBubbleStat: View {
    let title: String
    let value: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .biroHeaderFont(10)
                .tracking(0.9)
                .foregroundStyle(OunjePalette.secondaryText)

            Text(value)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(OunjePalette.primaryText)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(tint.opacity(0.16))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(tint.opacity(0.26), lineWidth: 1)
                )
        )
    }
}

private struct PipelinePreviewRow: View {
    let step: PipelineDecision

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(OunjePalette.accent)
                .frame(width: 9, height: 9)
                .padding(.top, 5)

            VStack(alignment: .leading, spacing: 4) {
                Text(step.stage.title)
                    .font(.system(size: 12, weight: .bold))
                Text(step.summary)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(OunjePalette.secondaryText)
            }
        }
    }
}

private struct StatusBarShield: View {
    var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                ZStack {
                        LinearGradient(
                            colors: [
                            OunjePalette.background.opacity(0.80),
                            OunjePalette.background.opacity(0.34),
                                .clear
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )

                    LinearGradient(
                        colors: [
                            .white.opacity(0.05),
                            .clear
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .blendMode(.softLight)
                }
                    .mask(
                        LinearGradient(
                            colors: [
                                .black,
                            .black.opacity(0.88),
                                .clear
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                .frame(height: proxy.safeAreaInsets.top + 10)

                Spacer()
            }
            .ignoresSafeArea()
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct SelectablePill: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(OunjePalette.primaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.9)
                Spacer(minLength: 4)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(isSelected ? OunjePalette.accent : OunjePalette.secondaryText)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isSelected ? OunjePalette.accent.opacity(0.12) : OunjePalette.elevated)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(isSelected ? OunjePalette.accent.opacity(0.3) : OunjePalette.stroke, lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
    }
}

private struct SelectionCard: View {
    let title: String
    let subtitle: String
    let isSelected: Bool
    var animationTrigger: Int = 0
    var animationIndex: Int = 0
    let action: () -> Void

    @State private var isPresetPulsing = false

    var body: some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(OunjePalette.primaryText)
                    Text(subtitle)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(OunjePalette.secondaryText)
                }
                Spacer()
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(isSelected ? OunjePalette.accent : OunjePalette.secondaryText)
                    .scaleEffect(isSelected && isPresetPulsing ? 1.18 : 1)
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isSelected ? OunjePalette.surface : OunjePalette.elevated)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(
                        isSelected
                            ? (isPresetPulsing ? OunjePalette.accent.opacity(0.65) : OunjePalette.accent.opacity(0.4))
                            : OunjePalette.stroke,
                        lineWidth: isSelected ? 1.2 : 1
                    )
            )
            .scaleEffect(isSelected && isPresetPulsing ? 1.02 : 1)
            .shadow(color: isSelected && isPresetPulsing ? OunjePalette.accent.opacity(0.12) : .clear, radius: 12, x: 0, y: 8)
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.28, dampingFraction: 0.78), value: isSelected)
        .onAppear {
            triggerPresetPulseIfNeeded()
        }
        .onChange(of: animationTrigger) { _ in
            triggerPresetPulseIfNeeded()
        }
    }

    private func triggerPresetPulseIfNeeded() {
        guard isSelected else {
            isPresetPulsing = false
            return
        }

        isPresetPulsing = false
        let delay = 0.04 * Double(animationIndex)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            withAnimation(.spring(response: 0.24, dampingFraction: 0.62)) {
                isPresetPulsing = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.24) {
                withAnimation(.spring(response: 0.34, dampingFraction: 0.84)) {
                    isPresetPulsing = false
                }
            }
        }
    }
}

private struct BudgetFlexibilityCalibrationCard: View {
    @Binding var score: Int

    private var selection: BudgetFlexibility {
        BudgetFlexibility.from(calibrationScore: score)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(score)")
                        .biroHeaderFont(34)
                        .foregroundStyle(OunjePalette.primaryText)
                    Text(selection.title)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(OunjePalette.secondaryText)
                }

                Spacer(minLength: 0)

                Text(modeLabel)
                    .biroHeaderFont(11)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        Capsule(style: .continuous)
                            .fill(OunjePalette.accent.opacity(0.14))
                            .overlay(
                                Capsule(style: .continuous)
                                    .stroke(OunjePalette.accent.opacity(0.34), lineWidth: 1)
                            )
                    )
            }

            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(OunjePalette.panel.opacity(0.74))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(.white.opacity(0.06), lineWidth: 1)
                    )

                Picker("Budget flexibility", selection: $score) {
                    ForEach(0...100, id: \.self) { value in
                        Text("\(value)")
                            .biroHeaderFont(20)
                            .foregroundStyle(OunjePalette.primaryText)
                            .tag(value)
                    }
                }
                .pickerStyle(.wheel)
                .labelsHidden()
                .frame(height: 126)
                .clipped()
            }
            .frame(height: 126)
            .overlay(alignment: .center) {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(OunjePalette.accent.opacity(0.48), lineWidth: 1.2)
                    .frame(height: 38)
                    .padding(.horizontal, 6)
                    .allowsHitTesting(false)
            }

            HStack(alignment: .top, spacing: 12) {
                BudgetFlexibilityStop(
                    title: "Save",
                    detail: "Often under budget",
                    isSelected: selection == .strict,
                    horizontalAlignment: .leading,
                    textAlignment: .leading
                )
                BudgetFlexibilityStop(
                    title: "Hold",
                    detail: "Hold the line",
                    isSelected: selection == .slightlyFlexible,
                    horizontalAlignment: .center,
                    textAlignment: .center
                )
                BudgetFlexibilityStop(
                    title: "Flex",
                    detail: "Most dynamic",
                    isSelected: selection == .convenienceFirst,
                    horizontalAlignment: .trailing,
                    textAlignment: .trailing
                )
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            OunjePalette.elevated,
                            OunjePalette.elevated.opacity(0.96),
                            OunjePalette.accent.opacity(0.06)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(OunjePalette.stroke, lineWidth: 1)
                )
        )
    }

    private var modeLabel: String {
        switch selection {
        case .strict:
            return "Saving"
        case .slightlyFlexible:
            return "Balanced"
        case .convenienceFirst:
            return "Dynamic"
        }
    }
}

private struct BudgetFlexibilityStop: View {
    let title: String
    let detail: String
    let isSelected: Bool
    let horizontalAlignment: Alignment
    let textAlignment: TextAlignment

    var body: some View {
        VStack(alignment: stackAlignment, spacing: 5) {
            Text(title)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(isSelected ? OunjePalette.primaryText : OunjePalette.secondaryText)

            Text(detail)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isSelected ? OunjePalette.accent : OunjePalette.secondaryText.opacity(0.82))
                .multilineTextAlignment(textAlignment)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: horizontalAlignment)
    }

    private var stackAlignment: HorizontalAlignment {
        switch textAlignment {
        case .leading:
            return .leading
        case .trailing:
            return .trailing
        default:
            return .center
        }
    }
}

struct AddressSetupSheet: View {
    let title: String
    let detail: String
    let primaryButtonTitle: String
    @Binding var addressLine1: String
    @Binding var addressLine2: String
    @Binding var city: String
    @Binding var region: String
    @Binding var postalCode: String
    @Binding var deliveryNotes: String
    @ObservedObject var autocomplete: AddressAutocompleteViewModel
    let onSuggestionSelected: (AddressSuggestion) async -> Void
    let onClear: () -> Void

    @Environment(\.dismiss) private var dismiss

    private var addressSummary: String {
        [addressLine1, city, region, postalCode]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }

    private var hasTypedQuery: Bool {
        !autocomplete.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var streetAddressSearchBinding: Binding<String> {
        Binding(
            get: {
                let query = autocomplete.query.trimmingCharacters(in: .whitespacesAndNewlines)
                return query.isEmpty ? addressLine1 : autocomplete.query
            },
            set: { newValue in
                addressLine1 = newValue
                autocomplete.query = newValue
            }
        )
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    addressHeaderSection
                    addressFormSection
                    currentAddressSection
                }
                .padding(.horizontal, OunjeLayout.screenHorizontalPadding)
                .padding(.top, 18)
                .padding(.bottom, 110)
            }
            .background(OunjePalette.background.ignoresSafeArea())
            .navigationTitle("Address")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    if !addressSummary.isEmpty {
                        Button("Clear") {
                            onClear()
                        }
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button(primaryButtonTitle) {
                    dismiss()
                }
                .buttonStyle(PrimaryPillButtonStyle())
                .padding(.horizontal, OunjeLayout.screenHorizontalPadding)
                .padding(.top, 10)
                .padding(.bottom, 14)
                .background(OunjePalette.background)
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            autocomplete.resetSearchState()
        }
    }

    private var addressHeaderSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(OunjePalette.primaryText)
            Text(detail)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(OunjePalette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var addressFormSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Street address", text: streetAddressSearchBinding)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .modifier(OnboardingInputModifier())

            autocompleteStatusSection
            autocompleteResultsSection

            TextField("Unit / Apt (optional)", text: $addressLine2)
                .modifier(OnboardingInputModifier())

            HStack(spacing: 10) {
                TextField("City", text: $city)
                    .modifier(OnboardingInputModifier())
                TextField("State / Province", text: $region)
                    .modifier(OnboardingInputModifier())
            }

            TextField("ZIP / Postal code", text: $postalCode)
                .modifier(OnboardingInputModifier())

            TextField("Delivery notes (optional)", text: $deliveryNotes, axis: .vertical)
                .lineLimit(1...3)
                .modifier(OnboardingInputModifier())
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(OunjePalette.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(OunjePalette.stroke, lineWidth: 1)
                )
        )
    }

    @ViewBuilder
    private var autocompleteStatusSection: some View {
        if autocomplete.isResolving {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Checking address...")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(OunjePalette.secondaryText)
            }
        }
    }

    @ViewBuilder
    private var autocompleteResultsSection: some View {
        if hasTypedQuery {
            if !autocomplete.results.isEmpty {
                VStack(spacing: 8) {
                    ForEach(autocomplete.results) { suggestion in
                        Button {
                            Task { await onSuggestionSelected(suggestion) }
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(suggestion.title)
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(OunjePalette.primaryText)

                                if !suggestion.subtitle.isEmpty {
                                    Text(suggestion.subtitle)
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(OunjePalette.secondaryText)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(OunjePalette.background)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                                            .stroke(OunjePalette.stroke, lineWidth: 1)
                                    )
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            } else if autocomplete.hasQueried {
                Text("No matching addresses yet.")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(OunjePalette.secondaryText)
            }
        }
    }

    @ViewBuilder
    private var currentAddressSection: some View {
        if !addressSummary.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Current address")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(OunjePalette.secondaryText)
                Text(addressSummary)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(OunjePalette.primaryText)
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(OunjePalette.surface.opacity(0.82))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(OunjePalette.stroke, lineWidth: 1)
                    )
            )
        }
    }
}

private struct MissingKitchenEquipmentRow: View {
    let title: String
    let detail: String
    let symbol: String
    let isMissing: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(isMissing ? .white.opacity(0.85) : OunjePalette.accent)
                    .frame(width: 36, height: 36)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(isMissing ? OunjePalette.elevated : OunjePalette.accent.opacity(0.16))
                    )

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                    Text(detail)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(OunjePalette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 12)

                Text(isMissing ? "Missing" : "Available")
                    .font(.system(size: 11, weight: .black))
                    .foregroundStyle(isMissing ? .white : .black)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(
                        Capsule()
                            .fill(isMissing ? OunjePalette.elevated : OunjePalette.accent)
                    )
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(isMissing ? OunjePalette.surface.opacity(0.78) : OunjePalette.accent.opacity(0.12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(isMissing ? OunjePalette.stroke : OunjePalette.accent.opacity(0.35), lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
    }
}

private struct OnboardingSectionCard<Content: View>: View {
    let title: String
    let detail: String
    var accent: Color = OunjePalette.accent
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .biroHeaderFont(18)
                    .foregroundStyle(.white)
                Text(detail)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(OunjePalette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(OunjePalette.panel.opacity(0.84))
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
                .overlay(alignment: .topLeading) {
                    Capsule(style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [accent.opacity(0.86), accent.opacity(0.2)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: 84, height: 4)
                        .padding(.top, 10)
                        .padding(.leading, 14)
                }
        )
        .shadow(color: .black.opacity(0.18), radius: 14, x: 0, y: 8)
    }
}

private struct OnboardingPromptCard: View {
    let step: FirstLoginOnboardingView.SetupStep

    @State private var isAnimating = false

    private var tint: Color {
        switch step {
        case .identity:
            return OunjePalette.accent
        case .challenge:
            return OunjePalette.accent
        case .solution:
            return OunjePalette.accent
        case .solutionWays:
            return OunjePalette.accent
        case .recipeStyle:
            return OunjePalette.accent
        case .allergies:
            return OunjePalette.accent
        case .diets:
            return OunjePalette.accent
        case .recipeEditIntro:
            return OunjePalette.accent
        case .recipeEditDemo:
            return OunjePalette.accent
        case .paywallIntro:
            return OunjePalette.accent
        case .cuisines:
            return Color(hex: "6AD6FF")
        case .household:
            return OunjePalette.softCream
        case .kitchen:
            return Color(hex: "8FD3FF")
        case .budget:
            return OunjePalette.softCream
        case .ordering:
            return OunjePalette.accent
        case .address:
            return OunjePalette.accent
        }
    }

    var body: some View {
        BubblySurfaceCard(accent: tint) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Step \(step.index + 1) of \(FirstLoginOnboardingView.SetupStep.allCases.count)")
                        .font(.system(size: 11, weight: .black))
                        .foregroundStyle(.black.opacity(0.82))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.white.opacity(0.9), in: Capsule())

                    Spacer()

                    Text(step.title)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(OunjePalette.secondaryText)
                }

                HStack(alignment: .top, spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(tint.opacity(0.16))
                            .frame(width: 52, height: 52)

                        Image(systemName: step.symbolName)
                            .font(.system(size: 18, weight: .black))
                            .foregroundStyle(tint)
                            .rotationEffect(.degrees(isAnimating ? 4 : -4))
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text(step.prompt)
                            .biroHeaderFont(20)
                            .foregroundStyle(.white)
                            .fixedSize(horizontal: false, vertical: true)

                        Text(step.subtitle)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(OunjePalette.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)

                        Text("These choices shape what Ounje learns next.")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.74))
                    }
                }
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 3.2).repeatForever(autoreverses: true)) {
                isAnimating = true
            }
        }
    }
}

private struct OnboardingStepRail: View {
    let currentStep: FirstLoginOnboardingView.SetupStep

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(FirstLoginOnboardingView.SetupStep.allCases, id: \.rawValue) { step in
                    let isCurrent = step == currentStep
                    let isComplete = step.index < currentStep.index

                    Text(step.title)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(
                            isCurrent
                                ? OunjePalette.softCream
                                : (isComplete ? OunjePalette.primaryText : OunjePalette.secondaryText)
                        )
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(
                            Capsule(style: .continuous)
                                .fill(
                                    isCurrent
                                        ? OunjePalette.accent
                                        : OunjePalette.surface
                                )
                                .overlay(
                                    Capsule(style: .continuous)
                                        .stroke(
                                            isCurrent
                                                ? OunjePalette.accent.opacity(0.22)
                                                : OunjePalette.stroke,
                                            lineWidth: 1
                                        )
                                )
                        )
                }
            }
            .padding(.trailing, 4)
        }
    }
}

private struct AuthenticationPreviewDeck: View {
    let isLifted: Bool

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            OunjePalette.surface,
                            OunjePalette.panel
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 30, style: .continuous)
                        .stroke(OunjePalette.stroke, lineWidth: 1)
                )

            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Your meal agent")
                        .biroHeaderFont(12)
                        .tracking(1.3)
                        .foregroundStyle(OunjePalette.accent)
                    Spacer()
                    HStack(spacing: 6) {
                        Circle().fill(.white.opacity(0.28)).frame(width: 6, height: 6)
                        Circle().fill(.white.opacity(0.2)).frame(width: 6, height: 6)
                        Circle().fill(OunjePalette.accent).frame(width: 6, height: 6)
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    speechBubble(text: "I learn your tastes, watch the budget, and prep the grocery cart for approval or auto-order.")

                    HStack(spacing: 10) {
                        previewMiniCard(title: "Taste profile", detail: "Cuisine, restrictions, goals")
                        previewMiniCard(title: "Weekly plan", detail: "Recipes picked for your cadence")
                    }

                    previewTimelineRow(step: "1", title: "Profile captured", detail: "Diet, kitchen, address, cadence")
                    previewTimelineRow(step: "2", title: "Meals selected", detail: "Recipes matched to taste and guardrails")
                    previewTimelineRow(step: "3", title: "Cart optimized", detail: "Best provider within budget")
                }
            }
            .padding(18)
        }
        .frame(height: 280)
        .offset(y: isLifted ? -5 : 5)
    }

    private func speechBubble(text: String) -> some View {
        Text(text)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(OunjePalette.elevated)
            )
    }

    private func previewMiniCard(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white)
            Text(detail)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(OunjePalette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(OunjePalette.elevated)
        )
    }

    private func previewTimelineRow(step: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(step)
                .font(.system(size: 12, weight: .black))
                .foregroundStyle(.black)
                .frame(width: 24, height: 24)
                .background(OunjePalette.accent, in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                Text(detail)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(OunjePalette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct OnboardingInputModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.black.opacity(0.28))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(Color.white.opacity(0.1), lineWidth: 1)
                    )
            )
    }
}

private struct AnimatedPlaceholderTextField: View {
    @Binding var text: String
    @Binding var animatedPlaceholder: String

    let animationOptions: [String]
    let basePlaceholder: String

    @FocusState private var isFocused: Bool
    @State private var animationTask: Task<Void, Never>?

    private var displayedPlaceholder: String {
        return animatedPlaceholder
    }

    var body: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(OunjePalette.elevated)

            if text.isEmpty && !displayedPlaceholder.isEmpty {
                Text(displayedPlaceholder)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(OunjePalette.secondaryText)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }

            TextField("", text: $text)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .focused($isFocused)
        }
        .onAppear {
            startAnimationLoop()
        }
        .onDisappear {
            animationTask?.cancel()
        }
        .onChange(of: text) { newValue in
            if newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                startAnimationLoop()
            } else {
                animationTask?.cancel()
            }
        }
        .onChange(of: isFocused) { focused in
            if focused {
                animationTask?.cancel()
            } else if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                startAnimationLoop()
            }
        }
    }

    private func startAnimationLoop() {
        guard text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard !animationOptions.isEmpty else { return }

        animationTask?.cancel()
        animationTask = Task {
            var index = 0

            while !Task.isCancelled {
                let country = animationOptions[index % animationOptions.count]

                await MainActor.run {
                    animatedPlaceholder = ""
                }

                for character in country {
                    guard !Task.isCancelled else { return }
                    guard await shouldKeepAnimating else { return }

                    await MainActor.run {
                        animatedPlaceholder.append(character)
                    }
                    try? await Task.sleep(nanoseconds: 75_000_000)
                }

                try? await Task.sleep(nanoseconds: 850_000_000)

                while !(await MainActor.run { animatedPlaceholder.isEmpty }) {
                    guard !Task.isCancelled else { return }
                    guard await shouldKeepAnimating else { return }

                    await MainActor.run {
                        _ = animatedPlaceholder.popLast()
                    }
                    try? await Task.sleep(nanoseconds: 45_000_000)
                }

                try? await Task.sleep(nanoseconds: 180_000_000)
                index += 1
            }
        }
    }

    private var shouldKeepAnimating: Bool {
        get async {
            await MainActor.run {
                text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isFocused
            }
        }
    }
}

private struct AnimatedPlaceholderTextEditor: View {
    @Binding var text: String
    @Binding var animatedPlaceholder: String

    let animationOptions: [String]
    let basePlaceholder: String

    @FocusState private var isFocused: Bool
    @State private var animationTask: Task<Void, Never>?

    private var displayedPlaceholder: String {
        if animatedPlaceholder.isEmpty {
            return basePlaceholder
        }
        return animatedPlaceholder
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(OunjePalette.elevated)

            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(displayedPlaceholder)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(OunjePalette.secondaryText)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 16)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }

            TextEditor(text: $text)
                .scrollContentBackground(.hidden)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .foregroundStyle(.white)
                .frame(minHeight: 110)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .focused($isFocused)
        }
        .onAppear {
            startAnimationLoop()
        }
        .onDisappear {
            animationTask?.cancel()
        }
        .onChange(of: text) { newValue in
            if newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                startAnimationLoop()
            } else {
                animationTask?.cancel()
            }
        }
        .onChange(of: isFocused) { focused in
            if focused {
                animationTask?.cancel()
            } else if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                startAnimationLoop()
            }
        }
    }

    private func startAnimationLoop() {
        guard text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard !animationOptions.isEmpty else { return }

        animationTask?.cancel()
        animationTask = Task {
            var index = 0

            while !Task.isCancelled {
                let example = animationOptions[index % animationOptions.count]

                await MainActor.run {
                    animatedPlaceholder = ""
                }

                for character in example {
                    guard !Task.isCancelled else { return }
                    guard await shouldKeepAnimating else { return }

                    await MainActor.run {
                        animatedPlaceholder.append(character)
                    }
                    try? await Task.sleep(nanoseconds: 70_000_000)
                }

                try? await Task.sleep(nanoseconds: 900_000_000)

                while !(await MainActor.run { animatedPlaceholder.isEmpty }) {
                    guard !Task.isCancelled else { return }
                    guard await shouldKeepAnimating else { return }

                    await MainActor.run {
                        _ = animatedPlaceholder.popLast()
                    }
                    try? await Task.sleep(nanoseconds: 40_000_000)
                }

                try? await Task.sleep(nanoseconds: 180_000_000)
                index += 1
            }
        }
    }

    private var shouldKeepAnimating: Bool {
        get async {
            await MainActor.run {
                text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isFocused
            }
        }
    }
}

private struct AnimatedSelectionBubbleGrid: View {
    let options: [String]
    @Binding var selection: Set<String>
    var animationTrigger: Int = 0

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 116), spacing: 8)], spacing: 8) {
            ForEach(Array(options.enumerated()), id: \.element) { index, option in
                AnimatedSelectionBubble(
                    title: option,
                    isSelected: selection.contains(option),
                    animationTrigger: animationTrigger,
                    animationIndex: index
                ) {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.78)) {
                        if selection.contains(option) {
                            selection.remove(option)
                        } else {
                            selection.insert(option)
                        }
                    }
                }
            }
        }
    }
}

private struct AnimatedEnumBubbleGrid<Option: Hashable & Identifiable>: View {
    let options: [Option]
    @Binding var selection: Set<Option>
    var animationTrigger: Int = 0
    var leadingEmoji: ((Option) -> String?)? = nil
    let label: (Option) -> String

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 116), spacing: 8)], spacing: 8) {
            ForEach(Array(options.enumerated()), id: \.element.id) { index, option in
                AnimatedSelectionBubble(
                    title: label(option),
                    isSelected: selection.contains(option),
                    animationTrigger: animationTrigger,
                    animationIndex: index,
                    leadingEmoji: leadingEmoji?(option)
                ) {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.78)) {
                        if selection.contains(option) {
                            selection.remove(option)
                        } else {
                            selection.insert(option)
                        }
                    }
                }
            }
        }
    }
}

private struct AnimatedSelectionBubble: View {
    let title: String
    let isSelected: Bool
    var animationTrigger: Int = 0
    var animationIndex: Int = 0
    var leadingEmoji: String? = nil
    let action: () -> Void

    @State private var isPresetPulsing = false

    private var badgeEmoji: String? {
        if let leadingEmoji {
            return leadingEmoji
        }

        let lowered = title.lowercased()

        if lowered.contains("omnivore") { return "🍽" }
        if lowered.contains("halal") { return "🛡" }
        if lowered.contains("kosher") { return "✡️" }
        if lowered.contains("vegetarian") { return "🥕" }
        if lowered.contains("vegan") { return "🌿" }
        if lowered.contains("pescatarian") { return "🐟" }
        if lowered.contains("gluten-free") { return "🌾" }
        if lowered.contains("dairy-free") { return "🥛" }
        if lowered.contains("low-carb") { return "⚡️" }
        if lowered.contains("high-protein") { return "💪" }
        if lowered.contains("keto") { return "🔥" }
        if lowered.contains("speed") { return "⚡️" }
        if lowered.contains("taste") { return "😋" }
        if lowered.contains("cost") { return "💸" }
        if lowered.contains("variety") { return "🎉" }
        if lowered.contains("macros") { return "📊" }
        if lowered.contains("family") { return "👨‍👩‍👧" }
        if lowered.contains("minimal cleanup") { return "🧼" }
        if lowered.contains("repeatability") { return "🔁" }
        if lowered.contains("rice") || lowered.contains("jollof") || lowered.contains("biryani") { return "🍚" }
        if lowered.contains("chicken") { return "🍗" }
        if lowered.contains("beef") { return "🥩" }
        if lowered.contains("salmon") || lowered.contains("seafood") { return "🐟" }
        if lowered.contains("pasta") { return "🍝" }
        if lowered.contains("dumplings") { return "🥟" }
        if lowered.contains("tacos") || lowered.contains("burrito") { return "🌮" }
        if lowered.contains("salad") { return "🥗" }
        if lowered.contains("mushroom") { return "🍄" }
        if lowered.contains("olive") { return "🫒" }
        if lowered.contains("tofu") { return "🧈" }
        if lowered.contains("wrap") { return "🌯" }
        if lowered.contains("bowls") { return "🥣" }
        if lowered.contains("stir-fry") { return "🥢" }

        return nil
    }

    private var symbolName: String {
        let lowered = title.lowercased()

        if lowered.contains("omnivore") {
            return "fork.knife.circle.fill"
        }
        if lowered.contains("halal") {
            return "checkmark.shield.fill"
        }
        if lowered.contains("kosher") {
            return "staroflife.fill"
        }
        if lowered.contains("vegetarian") || lowered.contains("vegan") {
            return "leaf.fill"
        }
        if lowered.contains("pescatarian") {
            return "fish.fill"
        }
        if lowered.contains("gluten-free") {
            return "checkmark.rectangle.portrait.fill"
        }
        if lowered.contains("dairy-free") {
            return "drop.fill"
        }
        if lowered.contains("low-carb") {
            return "bolt.fill"
        }
        if lowered.contains("high-protein") {
            return "figure.strengthtraining.traditional"
        }
        if lowered.contains("keto") {
            return "flame.fill"
        }
        if lowered.contains("rice") || lowered.contains("jollof") || lowered.contains("biryani") {
            return "takeoutbag.and.cup.and.straw.fill"
        }
        if lowered.contains("chicken") || lowered.contains("beef") || lowered.contains("salmon") || lowered.contains("seafood") {
            return "fork.knife.circle.fill"
        }
        if lowered.contains("pasta") || lowered.contains("dumplings") || lowered.contains("tacos") || lowered.contains("burrito") {
            return "flame.fill"
        }
        if lowered.contains("salad") || lowered.contains("cilantro") || lowered.contains("mushroom") || lowered.contains("olive") || lowered.contains("tofu") {
            return "leaf.fill"
        }
        if lowered.contains("wrap") || lowered.contains("bowls") || lowered.contains("stir-fry") {
            return "sparkles"
        }

        return isSelected ? "checkmark.seal.fill" : "sparkles"
    }

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 9) {
                if let badgeEmoji {
                    Text(badgeEmoji)
                        .font(.system(size: 18))
                        .saturation(isSelected ? 1 : 0.18)
                        .grayscale(isSelected ? 0 : 0.22)
                        .opacity(isSelected ? 1 : 0.72)
                        .frame(width: 26, height: 26)
                        .background(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(isSelected ? OunjePalette.accent.opacity(0.16) : OunjePalette.surface)
                        )
                } else {
                    Image(systemName: symbolName)
                        .font(.system(size: 13, weight: .black))
                        .foregroundStyle(isSelected ? OunjePalette.accent : OunjePalette.accent)
                        .frame(width: 26, height: 26)
                        .background(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(isSelected ? OunjePalette.accent.opacity(0.16) : OunjePalette.surface)
                        )
                }

                Text(title)
                    .biroHeaderFont(12)
                    .multilineTextAlignment(.leading)
                    .lineLimit(title.contains(" ") ? 2 : 1)
                    .minimumScaleFactor(title.contains(" ") ? 1 : 0.84)
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(.white)
                    .layoutPriority(1)

                Spacer(minLength: 4)

                Image(systemName: isSelected ? "checkmark.circle.fill" : "plus.circle")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(isSelected ? OunjePalette.accent : OunjePalette.secondaryText)
                    .scaleEffect(isSelected && isPresetPulsing ? 1.2 : 1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: isSelected
                                ? [OunjePalette.surface, OunjePalette.panel]
                                : [OunjePalette.surface, OunjePalette.elevated],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(
                        isSelected
                            ? (isPresetPulsing ? OunjePalette.accent.opacity(0.65) : OunjePalette.accent.opacity(0.42))
                            : OunjePalette.stroke,
                        lineWidth: isSelected ? 1.3 : 1
                    )
            )
            .scaleEffect((isSelected ? 1.01 : 0.985) * (isPresetPulsing ? 1.03 : 1))
            .shadow(color: isSelected && isPresetPulsing ? OunjePalette.accent.opacity(0.12) : .clear, radius: 14, x: 0, y: 8)
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.28, dampingFraction: 0.78), value: isSelected)
        .onAppear {
            triggerPresetPulseIfNeeded()
        }
        .onChange(of: animationTrigger) { _ in
            triggerPresetPulseIfNeeded()
        }
    }

    private func triggerPresetPulseIfNeeded() {
        guard isSelected else {
            isPresetPulsing = false
            return
        }

        isPresetPulsing = false
        let delay = 0.04 * Double(animationIndex)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            withAnimation(.spring(response: 0.24, dampingFraction: 0.62)) {
                isPresetPulsing = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.24) {
                withAnimation(.spring(response: 0.34, dampingFraction: 0.84)) {
                    isPresetPulsing = false
                }
            }
        }
    }
}

private struct SummarySectionCard: View {
    let section: MealPrepSummarySection

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(section.title)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)
            Text(section.detail)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(OunjePalette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(OunjePalette.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(OunjePalette.stroke, lineWidth: 1)
                )
        )
    }
}

private struct OnboardingTopAnchorPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

struct AgentSummaryAesthetic {
    let title: String
    let symbolName: String
    let primary: Color
    let secondary: Color
    let tertiary: Color
}

extension UserProfile {
    var agentSummaryAesthetic: AgentSummaryAesthetic {
        let loweredCuisines = userFacingCuisineTitles.map { $0.lowercased() }
        let loweredDietaryPatterns = dietaryPatterns.map { $0.lowercased() }

        if loweredCuisines.contains(where: { $0.contains("nigerian") || $0.contains("caribbean") || $0.contains("mexican") }) {
            return AgentSummaryAesthetic(
                title: "Night Heat",
                symbolName: "flame.fill",
                primary: OunjePalette.accent,
                secondary: Color(hex: "FF8A3D"),
                tertiary: Color(hex: "FFD166")
            )
        }

        if loweredDietaryPatterns.contains(where: { $0.contains("vegan") || $0.contains("vegetarian") || $0.contains("dairy-free") || $0.contains("gluten-free") }) {
            return AgentSummaryAesthetic(
                title: "Clean Grid",
                symbolName: "leaf.fill",
                primary: OunjePalette.accent,
                secondary: OunjePalette.softCream,
                tertiary: Color(hex: "C7D9CF")
            )
        }

        if loweredCuisines.contains(where: { $0.contains("japanese") || $0.contains("chinese") || $0.contains("korean") }) {
            return AgentSummaryAesthetic(
                title: "Neon Pantry",
                symbolName: "moon.stars.fill",
                primary: OunjePalette.accent,
                secondary: Color(hex: "4EA8FF"),
                tertiary: Color(hex: "A6C8FF")
            )
        }

        return AgentSummaryAesthetic(
            title: "Ounje Core",
            symbolName: "sparkles",
            primary: OunjePalette.accent,
            secondary: OunjePalette.softCream,
            tertiary: Color(hex: "B8CDC2")
        )
    }
}

struct AddressSuggestion: Identifiable, Hashable {
    let id: String
    let title: String
    let subtitle: String
    fileprivate let completion: MKLocalSearchCompletion

    init(completion: MKLocalSearchCompletion) {
        self.id = "\(completion.title)::\(completion.subtitle)"
        self.title = completion.title
        self.subtitle = completion.subtitle
        self.completion = completion
    }
}

final class AddressAutocompleteViewModel: NSObject, ObservableObject, MKLocalSearchCompleterDelegate {
    @Published var query = "" {
        didSet {
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            hasQueried = !trimmed.isEmpty
            completer.queryFragment = trimmed
            if trimmed.isEmpty {
                results = []
            }
        }
    }
    @Published private(set) var results: [AddressSuggestion] = []
    @Published private(set) var hasQueried = false
    @Published private(set) var isResolving = false

    private let completer = MKLocalSearchCompleter()

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = .address
    }

    func resetSearchState() {
        query = ""
        hasQueried = false
        results = []
        isResolving = false
    }

    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        results = completer.results.map(AddressSuggestion.init)
    }

    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        results = []
    }

    func resolve(_ suggestion: AddressSuggestion) async -> DeliveryAddress? {
        await MainActor.run {
            isResolving = true
        }

        defer {
            Task { @MainActor in
                self.isResolving = false
            }
        }

        let request = MKLocalSearch.Request(completion: suggestion.completion)
        let search = MKLocalSearch(request: request)

        do {
            let response = try await search.start()
            guard let placemark = response.mapItems.first?.placemark else { return nil }

            let streetNumber = placemark.subThoroughfare?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let streetName = placemark.thoroughfare?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let line1 = "\(streetNumber) \(streetName)".trimmingCharacters(in: .whitespacesAndNewlines)

            await MainActor.run {
                self.query = [line1, placemark.locality, placemark.administrativeArea]
                    .compactMap { value in
                        guard let value, !value.isEmpty else { return nil }
                        return value
                    }
                    .joined(separator: ", ")
                self.results = []
            }

            return DeliveryAddress(
                line1: line1.isEmpty ? suggestion.title : line1,
                line2: "",
                city: placemark.locality ?? "",
                region: placemark.administrativeArea ?? "",
                postalCode: placemark.postalCode ?? "",
                deliveryNotes: ""
            )
        } catch {
            return nil
        }
    }
}

private struct TagPill: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .bold))
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(OunjePalette.elevated, in: Capsule())
    }
}

private struct WrapFlow<Data: RandomAccessCollection, Content: View>: View where Data.Element: Hashable {
    let items: Data
    let content: (Data.Element) -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            let rows = Array(items)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 90), spacing: 8)], spacing: 8) {
                ForEach(rows, id: \.self) { item in
                    content(item)
                }
            }
        }
    }
}

struct AgentSummaryExperienceCard: View {
    let profile: UserProfile

    @State private var isAnimated = false
    @State private var inferredBrief: InferredAgentBrief?
    @State private var isLoadingBrief = false
    @State private var briefErrorMessage: String?

    private var displayedBrief: InferredAgentBrief {
        inferredBrief ?? .fallback(from: profile)
    }

    private var displayedAesthetic: AgentSummaryAesthetic {
        displayedBrief.resolvedAesthetic(fallback: profile.agentSummaryAesthetic)
    }

    private var briefBadgeTitle: String {
        if let preferredName = profile.trimmedPreferredName {
            return "\(preferredName)'s agent brief"
        }
        return "Your agent brief"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text(briefBadgeTitle)
                            .font(.system(size: 12, weight: .black))
                            .foregroundStyle(.black.opacity(0.78))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(.white.opacity(0.9), in: Capsule())

                        if isLoadingBrief {
                            ProgressView()
                                .controlSize(.small)
                                .tint(.white.opacity(0.84))
                        } else if inferredBrief != nil {
                            Image(systemName: "sparkles")
                                .font(.system(size: 12, weight: .black))
                                .foregroundStyle(.white.opacity(0.78))
                        }
                    }

                    Text(displayedBrief.headline)
                        .biroHeaderFont(30)
                        .foregroundStyle(.white)
                        .fixedSize(horizontal: false, vertical: true)
                        .shadow(color: .black.opacity(0.18), radius: 10, x: 0, y: 8)

                    Text(displayedBrief.narrative)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white.opacity(0.78))
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 16)

                VStack(spacing: 8) {
                    Image(systemName: displayedAesthetic.symbolName)
                        .font(.system(size: 18, weight: .black))
                        .foregroundStyle(.black.opacity(0.82))
                        .frame(width: 46, height: 46)
                        .background(.white.opacity(0.88), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .rotationEffect(.degrees(isAnimated ? 4 : -4))

                    Text(displayedAesthetic.title)
                        .font(.system(size: 11, weight: .black))
                        .foregroundStyle(.white.opacity(0.86))
                        .multilineTextAlignment(.center)
                        .frame(width: 74)
                }
            }

            AgentBriefMetricsGrid(
                metrics: displayedBrief.graphItems,
                primary: displayedAesthetic.primary,
                secondary: displayedAesthetic.secondary
            )

            WrapFlow(items: displayedBrief.signals) { signal in
                AgentSignalBadge(text: signal, tint: displayedAesthetic.primary)
                    .scaleEffect(isAnimated ? 1 : 0.96)
                    .animation(.spring(response: 0.5, dampingFraction: 0.8).delay(Double(abs(signal.hashValue % 6)) * 0.03), value: isAnimated)
            }

            VStack(spacing: 10) {
                ForEach(Array(displayedBrief.readinessNotes.enumerated()), id: \.offset) { index, note in
                    AgentReadoutRow(
                        note: note,
                        tint: index.isMultiple(of: 2) ? displayedAesthetic.primary : displayedAesthetic.secondary
                    )
                    .offset(x: isAnimated ? 0 : -10, y: isAnimated ? 0 : 6)
                    .opacity(isAnimated ? 1 : 0.45)
                    .animation(.spring(response: 0.55, dampingFraction: 0.82).delay(Double(index) * 0.08), value: isAnimated)
                }
            }

        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                OunjePalette.surface,
                                OunjePalette.panel
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                displayedAesthetic.primary.opacity(0.42),
                                displayedAesthetic.secondary.opacity(0.2),
                                .clear
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                Circle()
                    .fill(displayedAesthetic.primary.opacity(0.26))
                    .frame(width: 190, height: 190)
                    .blur(radius: 28)
                    .offset(x: isAnimated ? 110 : 70, y: isAnimated ? -90 : -40)

                Circle()
                    .fill(displayedAesthetic.secondary.opacity(0.23))
                    .frame(width: 150, height: 150)
                    .blur(radius: 24)
                    .offset(x: isAnimated ? -90 : -50, y: isAnimated ? 120 : 80)

                Circle()
                    .fill(displayedAesthetic.tertiary.opacity(0.18))
                    .frame(width: 110, height: 110)
                    .blur(radius: 24)
                    .offset(x: isAnimated ? 150 : 100, y: isAnimated ? 140 : 90)
            }
        )
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(.white.opacity(0.08), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .shadow(color: displayedAesthetic.primary.opacity(0.12), radius: 20, x: 0, y: 12)
        .onAppear {
            withAnimation(.easeInOut(duration: 4.2).repeatForever(autoreverses: true)) {
                isAnimated = true
            }
        }
        .task(id: profile) {
            await loadInferredBrief()
        }
    }

    private func loadInferredBrief() async {
        guard !isLoadingBrief else { return }
        isLoadingBrief = true
        briefErrorMessage = nil

        do {
            inferredBrief = try await SupabaseAgentBriefService.shared.generateBrief(for: profile)
        } catch {
            inferredBrief = nil
            briefErrorMessage = error.localizedDescription
        }

        isLoadingBrief = false
    }
}

struct InferredAgentBrief: Codable, Hashable {
    let headline: String
    let narrative: String
    let signals: [String]
    let readinessNotes: [String]
    let visualTone: String?
    let graphItems: [AgentBriefGraphItem]

    enum CodingKeys: String, CodingKey {
        case headline
        case narrative
        case signals
        case readinessNotes = "readiness_notes"
        case visualTone = "visual_tone"
        case graphItems = "graph_items"
    }

    static func fallback(from profile: UserProfile) -> InferredAgentBrief {
        InferredAgentBrief(
            headline: profile.profileHeadline,
            narrative: profile.profileNarrative,
            signals: Array(profile.profileSignals.prefix(6)),
            readinessNotes: Array(profile.profileReadinessNotes.prefix(4)),
            visualTone: nil,
            graphItems: fallbackGraphItems(from: profile)
        )
    }

    private static func fallbackGraphItems(from profile: UserProfile) -> [AgentBriefGraphItem] {
        let restrictionWeight = min(100, 18 + (profile.absoluteRestrictions.count * 16) + (profile.dietaryPatterns.count * 7))
        let varietyWeight = min(100, 25 + (profile.userFacingCuisineTitles.count * 10) + (profile.cuisineCountries.count * 8))
        let budgetWeight = min(100, max(10, Int(profile.budgetWindow == .weekly ? profile.budgetPerCycle / 4 : profile.budgetPerCycle / 16)))
        let autonomyWeight: Int

        switch profile.orderingAutonomy {
        case .suggestOnly:
            autonomyWeight = 18
        case .approvalRequired:
            autonomyWeight = 42
        case .autoOrderWithinBudget:
            autonomyWeight = 72
        case .fullyAutonomousGuardrails:
            autonomyWeight = 90
        }

        return [
            AgentBriefGraphItem(label: "Guardrails", value: restrictionWeight, caption: "Hard limits locked in"),
            AgentBriefGraphItem(label: "Variety", value: varietyWeight, caption: "Cuisine range on deck"),
            AgentBriefGraphItem(label: "Budget", value: budgetWeight, caption: profile.budgetSummary),
            AgentBriefGraphItem(label: "Autonomy", value: autonomyWeight, caption: "How far Ounje can run")
        ]
    }

    func resolvedAesthetic(fallback: AgentSummaryAesthetic) -> AgentSummaryAesthetic {
        switch visualTone?.lowercased() {
        case "night_heat":
            return AgentSummaryAesthetic(
                title: "Night Heat",
                symbolName: "flame.fill",
                primary: OunjePalette.accent,
                secondary: Color(hex: "FF8A3D"),
                tertiary: Color(hex: "FFD166")
            )
        case "clean_grid":
            return AgentSummaryAesthetic(
                title: "Clean Grid",
                symbolName: "leaf.fill",
                primary: OunjePalette.accent,
                secondary: OunjePalette.softCream,
                tertiary: Color(hex: "C7D9CF")
            )
        case "control_mode":
            return AgentSummaryAesthetic(
                title: "Control Mode",
                symbolName: "bolt.fill",
                primary: OunjePalette.accent,
                secondary: Color(hex: "6AD6FF"),
                tertiary: Color(hex: "B2FFFF")
            )
        case "neon_pantry":
            return AgentSummaryAesthetic(
                title: "Neon Pantry",
                symbolName: "moon.stars.fill",
                primary: OunjePalette.accent,
                secondary: Color(hex: "4EA8FF"),
                tertiary: Color(hex: "A6C8FF")
            )
        case "ounje_core":
            return AgentSummaryAesthetic(
                title: "Ounje Core",
                symbolName: "sparkles",
                primary: OunjePalette.accent,
                secondary: OunjePalette.softCream,
                tertiary: Color(hex: "B8CDC2")
            )
        default:
            return fallback
        }
    }
}

struct AgentBriefGraphItem: Codable, Hashable, Identifiable {
    var id: String { label }
    let label: String
    let value: Int
    let caption: String
}

private actor AgentBriefCache {
    static let shared = AgentBriefCache()

    private var briefsByKey: [String: InferredAgentBrief] = [:]

    func brief(for key: String) -> InferredAgentBrief? {
        briefsByKey[key]
    }

    func store(_ brief: InferredAgentBrief, for key: String) {
        briefsByKey[key] = brief
    }
}

private enum SupabaseAgentBriefError: LocalizedError {
    case invalidRequest
    case invalidResponse
    case requestFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidRequest:
            return "Could not construct the agent brief request."
        case .invalidResponse:
            return "Unexpected response from the brief service."
        case .requestFailed(let message):
            return message
        }
    }
}

final class SupabaseAgentBriefService {
    static let shared = SupabaseAgentBriefService()

    private init() {}

    func generateBrief(for profile: UserProfile) async throws -> InferredAgentBrief {
        let cacheKey = try cacheKey(for: profile)
        if let cached = await AgentBriefCache.shared.brief(for: cacheKey) {
            return cached
        }

        let payload = SupabaseAgentBriefRequestPayload(
            profile: profile,
            fallbackBrief: .fallback(from: profile),
            summarySections: profile.structuredSummarySections
        )

        for endpoint in candidateEndpoints {
            do {
                let brief = try await requestBrief(from: endpoint, payload: payload)
                await AgentBriefCache.shared.store(brief, for: cacheKey)
                return brief
            } catch {
                continue
            }
        }

        throw SupabaseAgentBriefError.requestFailed("Live brief generation is unavailable right now.")
    }

    private var candidateEndpoints: [AgentBriefEndpoint] {
        [.backend]
    }

    private func requestBrief(from endpoint: AgentBriefEndpoint, payload: SupabaseAgentBriefRequestPayload) async throws -> InferredAgentBrief {
        var request = URLRequest(url: endpoint.url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        request.httpBody = try JSONEncoder().encode(payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SupabaseAgentBriefError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let errorPayload = try? JSONDecoder().decode(SupabaseRestErrorResponse.self, from: data)
            throw SupabaseAgentBriefError.requestFailed(
                errorPayload?.message ?? errorPayload?.error ?? "Brief endpoint returned \(httpResponse.statusCode)."
            )
        }
        return try JSONDecoder().decode(InferredAgentBrief.self, from: data)
    }

    private func cacheKey(for profile: UserProfile) throws -> String {
        let data = try JSONEncoder().encode(profile)
        return data.base64EncodedString()
    }
}

private enum AgentBriefEndpoint {
    case backend

    var url: URL {
        switch self {
        case .backend:
            return URL(string: "\(OunjeDevelopmentServer.baseURL)/agent-brief")!
        }
    }
}

private struct SupabaseAgentBriefRequestPayload: Codable {
    let profile: UserProfile
    let fallbackBrief: InferredAgentBrief
    let summarySections: [MealPrepSummarySection]

    enum CodingKeys: String, CodingKey {
        case profile
        case fallbackBrief = "fallback_brief"
        case summarySections = "summary_sections"
    }
}

private struct AgentSignalBadge: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .black))
            .foregroundStyle(.white)
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .background(
                Capsule()
                    .fill(tint.opacity(0.18))
                    .overlay(
                        Capsule()
                            .stroke(tint.opacity(0.34), lineWidth: 1)
                    )
            )
    }
}

private struct AgentBriefMetricsGrid: View {
    let metrics: [AgentBriefGraphItem]
    let primary: Color
    let secondary: Color

    private let columns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10)
    ]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 10) {
            ForEach(Array(metrics.prefix(4).enumerated()), id: \.element.id) { index, metric in
                AgentBriefMetricCard(
                    metric: metric,
                    tint: index.isMultiple(of: 2) ? primary : secondary
                )
            }
        }
    }
}

private struct AgentBriefMetricCard: View {
    let metric: AgentBriefGraphItem
    let tint: Color

    private var normalizedValue: Double {
        min(max(Double(metric.value) / 100, 0), 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(metric.label)
                    .font(.system(size: 12, weight: .black))
                    .foregroundStyle(.white)

                Spacer(minLength: 8)

                Text("\(metric.value)")
                    .biroHeaderFont(20)
                    .foregroundStyle(.white)
            }

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.white.opacity(0.08))

                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [
                                    tint.opacity(0.92),
                                    tint.opacity(0.5)
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: max(18, geometry.size.width * normalizedValue))
                }
            }
            .frame(height: 8)

            Text(metric.caption)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.66))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.black.opacity(0.14))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(tint.opacity(0.14), lineWidth: 1)
                )
        )
    }
}

private struct AgentReadoutRow: View {
    let note: String
    let tint: Color

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(tint)
                .frame(width: 8, height: 8)
                .padding(.top, 6)

            Text(note)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.88))
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.black.opacity(0.16))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(.white.opacity(0.06), lineWidth: 1)
                )
        )
    }
}

private struct WelcomeValueRow: View {
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(OunjePalette.accent)
                .frame(width: 7, height: 7)
                .padding(.top, 6)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                Text(detail)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(OunjePalette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct PrimaryPillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity)
            .background(
                        OunjePalette.accent,
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(OunjePalette.accentDark.opacity(0.3), lineWidth: 1)
            )
            .shadow(color: OunjePalette.accent.opacity(configuration.isPressed ? 0.12 : 0.2), radius: 12, x: 0, y: 8)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
    }
}

private struct DiscoverTopActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(OunjePalette.accent)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(OunjePalette.accentDark.opacity(0.25), lineWidth: 1)
            )
            .shadow(color: OunjePalette.accent.opacity(configuration.isPressed ? 0.1 : 0.18), radius: 12, x: 0, y: 8)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
    }
}

struct SecondaryPillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(OunjePalette.primaryText)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity)
            .background(
                OunjePalette.surface,
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(OunjePalette.stroke, lineWidth: 1)
            )
            .shadow(color: OunjePalette.primaryText.opacity(configuration.isPressed ? 0.06 : 0.10), radius: 10, x: 0, y: 4)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
    }
}

private struct OnboardingArrowButtonStyle: ButtonStyle {
    var isPrimary: Bool = false
    var accent: Color = OunjePalette.accent

    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(
                isEnabled
                    ? (isPrimary ? .black : .white.opacity(0.92))
                    : .white.opacity(0.42)
            )
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: isEnabled
                                ? (isPrimary
                                    ? [accent.opacity(0.94), accent.opacity(0.74)]
                                    : [OunjePalette.navBar.opacity(0.96), OunjePalette.panel.opacity(0.94)])
                                : [OunjePalette.elevated.opacity(0.96), OunjePalette.surface.opacity(0.94)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(
                        isEnabled
                            ? (isPrimary ? .white.opacity(0.14) : Color.white.opacity(0.14))
                            : OunjePalette.stroke.opacity(0.7),
                        lineWidth: 1
                    )
            )
            .shadow(
                color: isEnabled
                    ? (isPrimary
                        ? accent.opacity(configuration.isPressed ? 0.12 : 0.24)
                        : .black.opacity(configuration.isPressed ? 0.08 : 0.16))
                    : .clear,
                radius: isEnabled ? 10 : 0,
                x: 0,
                y: 6
            )
            .opacity(isEnabled ? 1 : 0.86)
            .scaleEffect(isEnabled && configuration.isPressed ? 0.97 : 1)
    }
}

private struct DestructivePillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity)
            .background(Color.red.opacity(0.75), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

struct SupabaseTokenResponse: Codable {
    let accessToken: String
    let refreshToken: String?
    let expiresIn: Int?
    let user: SupabaseAuthUser

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case user
    }
}

struct SupabaseAuthUser: Codable {
    let id: String
    let email: String?
    let userMetadata: SupabaseUserMetadata?

    enum CodingKeys: String, CodingKey {
        case id
        case email
        case userMetadata = "user_metadata"
    }
}

struct SupabaseUserMetadata: Codable {
    let fullName: String?
    let name: String?

    enum CodingKeys: String, CodingKey {
        case fullName = "full_name"
        case name
    }
}

struct SupabaseAuthErrorResponse: Codable {
    let error: String?
    let msg: String?
    let errorDescription: String?

    enum CodingKeys: String, CodingKey {
        case error
        case msg
        case errorDescription = "error_description"
    }
}

private struct InlineAddButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .bold))
                Text(title)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
            }
            .foregroundStyle(OunjePalette.primaryText)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                Capsule(style: .continuous)
                    .fill(OunjePalette.panel.opacity(0.88))
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(OunjePalette.stroke, lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
    }
}
