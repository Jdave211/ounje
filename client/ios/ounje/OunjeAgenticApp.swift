import SwiftUI
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

@main
struct OunjeAgenticApp: App {
    @StateObject private var store = MealPlanningAppStore()
    @StateObject private var toastCenter = AppToastCenter()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(toastCenter)
                .preferredColorScheme(.dark)
        }
    }
}

private struct RootView: View {
    @EnvironmentObject private var store: MealPlanningAppStore
    @EnvironmentObject private var toastCenter: AppToastCenter

    var body: some View {
        Group {
            if !store.isAuthenticated {
                AuthenticationView()
                    .id("auth-entry")
            } else if !store.hasResolvedInitialState || store.isHydratingRemoteState {
                RemoteStateBootstrapView()
                    .id("remote-bootstrap")
            } else if store.requiresProfileOnboarding {
                FirstLoginOnboardingView()
                    .id("first-login-onboarding")
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
        }
    }
}

private struct AppToast: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let subtitle: String?
    let systemImage: String
    let thumbnailURLString: String?
}

extension Notification.Name {
    static let recipeImportReviewQueueNeedsRefresh = Notification.Name("recipeImportReviewQueueNeedsRefresh")
}

@MainActor
private final class AppToastCenter: ObservableObject {
    @Published var toast: AppToast?

    private var dismissTask: Task<Void, Never>?

    func showSavedRecipe(title: String, thumbnailURLString: String? = nil) {
        show(
            title: "Saved",
            subtitle: title,
            systemImage: "bookmark.fill",
            thumbnailURLString: thumbnailURLString
        )
    }

    func show(
        title: String,
        subtitle: String? = nil,
        systemImage: String = "checkmark.circle.fill",
        thumbnailURLString: String? = nil
    ) {
        dismissTask?.cancel()
        withAnimation(.spring(response: 0.36, dampingFraction: 0.82)) {
            toast = AppToast(
                title: title,
                subtitle: subtitle,
                systemImage: systemImage,
                thumbnailURLString: thumbnailURLString
            )
        }

        dismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_700_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                withAnimation(.spring(response: 0.36, dampingFraction: 0.92)) {
                    self.toast = nil
                }
            }
        }
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

    func refresh() async {
        envelopes = (try? SharedRecipeImportInbox.readAll()) ?? []
    }

    func envelope(withID envelopeID: String) -> SharedRecipeImportEnvelope? {
        envelopes.first(where: { $0.id == envelopeID })
    }

    func reconcileCompletedImports(_ completedItems: [RecipeImportCompletedItem]) async {
        guard !completedItems.isEmpty else {
            await refresh()
            return
        }

        let currentEnvelopes = (try? SharedRecipeImportInbox.readAll()) ?? []
        guard !currentEnvelopes.isEmpty else {
            envelopes = []
            return
        }

        let matchedIDs = currentEnvelopes
            .filter { envelope in
                completedItems.contains { $0.matches(envelope: envelope) }
            }
            .map(\.id)

        guard !matchedIDs.isEmpty else {
            envelopes = currentEnvelopes
            return
        }

        matchedIDs.forEach { envelopeID in
            try? SharedRecipeImportInbox.delete(envelopeID: envelopeID)
        }

        await refresh()
    }
}

@MainActor
private final class RecipeImportReviewQueueStore: ObservableObject {
    @Published private(set) var items: [RecipeImportReviewItem] = []
    @Published private(set) var completedItems: [RecipeImportCompletedItem] = []

    var badgeCount: Int {
        items.count
    }

    var completedCount: Int {
        completedItems.count
    }

    var draftCount: Int {
        items.filter { $0.reviewState == "draft" }.count
    }

    var needsReviewCount: Int {
        items.filter { $0.reviewState == "needs_review" }.count
    }

    func refresh(userID: String?) async {
        guard let userID, !userID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            items = []
            completedItems = []
            return
        }
        async let reviewFetch = RecipeImportAPIService.shared.fetchReviewQueue(userID: userID)
        async let completedFetch = RecipeImportAPIService.shared.fetchCompletedImports(userID: userID)
        items = (try? await reviewFetch) ?? []
        completedItems = (try? await completedFetch) ?? []
    }
}

private struct AppToastBanner: View {
    let toast: AppToast

    private var thumbnailURL: URL? {
        guard let raw = toast.thumbnailURLString?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        return URL(string: raw)
    }

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let thumbnailURL {
                    AsyncImage(url: thumbnailURL) { phase in
                        switch phase {
                        case .success(let image):
                            image
                                .resizable()
                                .scaledToFill()
                        default:
                            toastFallbackBadge
                        }
                    }
                } else {
                    toastFallbackBadge
                }
            }
            .frame(width: 30, height: 30)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(toast.title)
                    .font(.custom("Slee_handwritting-Regular", size: 16))
                    .tracking(0.05)
                    .foregroundStyle(OunjePalette.primaryText)
                    .lineLimit(1)

                if let subtitle = toast.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 11.5, weight: .medium, design: .rounded))
                        .foregroundStyle(OunjePalette.secondaryText)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(OunjePalette.panel.opacity(0.96))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.white.opacity(0.10), lineWidth: 1)
                )
        )
        .shadow(color: .black.opacity(0.12), radius: 12, y: 5)
    }

    private var toastFallbackBadge: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(OunjePalette.surface.opacity(0.96))

            Image(systemName: toast.systemImage)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(OunjePalette.softCream)
        }
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

    @State private var isGoogleSigningIn = false
    @State private var authErrorMessage: String?
    @State private var authStatusMessage: String?
    @State private var appleSignInNonce = ""
    @State private var showAuthSheet = false
    @State private var revealContent = false

    var body: some View {
        ZStack {
            Image("WelcomeBackground")
                .resizable()
                .scaledToFill()
                .ignoresSafeArea()

            LinearGradient(
                colors: [
                    .black.opacity(0.2),
                    .black.opacity(0.5),
                    OunjePalette.background.opacity(0.92),
                    OunjePalette.background
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            GeometryReader { proxy in
                let contentWidth = min(420, proxy.size.width - (OunjeLayout.screenHorizontalPadding * 2))

                VStack(spacing: 0) {
                    Spacer(minLength: max(170, proxy.size.height * 0.44))

                    VStack(alignment: .leading, spacing: 14) {
                        Text("Plan less.")
                            .font(.system(size: 48, weight: .black, design: .rounded))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Text("Cook easy.")
                            .font(.custom("Slee_handwritting-Regular", size: 30))
                            .tracking(0.08)
                            .foregroundStyle(OunjePalette.softCream)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        (
                            Text("Set your food style once. ")
                                .font(.system(size: 16, weight: .medium, design: .rounded))
                            + Text("Ounje")
                                .font(.custom("Slee_handwritting-Regular", size: 22))
                                .tracking(0.05)
                            + Text(" handles the weekly prep, recipe picks, and groceries after that.")
                                .font(.system(size: 16, weight: .medium, design: .rounded))
                        )
                            .foregroundStyle(.white.opacity(0.84))
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18)

                    Spacer(minLength: 24)

                    VStack(alignment: .center, spacing: 14) {
                        if let authStatusMessage {
                            Text(authStatusMessage)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.92))
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.bottom, 6)
                        }

                        Button {
                            showAuthSheet = true
                        } label: {
                            Text("Get started")
                                .font(.system(size: 19, weight: .semibold, design: .rounded))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(PrimaryPillButtonStyle())
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.horizontal, 18)

                    Spacer(minLength: max(22, proxy.safeAreaInsets.bottom + 12))
                }
                .frame(maxWidth: contentWidth)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
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
        .sheet(isPresented: $showAuthSheet) {
            NavigationStack {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 8) {
                        (
                            Text("Sign in to ")
                                .font(.system(size: 28, weight: .black, design: .rounded))
                            + Text("Ounje")
                                .font(.custom("Slee_handwritting-Regular", size: 34))
                                .tracking(0.08)
                        )
                            .foregroundStyle(.white)

                        Text("Use Apple or Google to keep your profile, prep, and cookbook synced.")
                            .font(.system(size: 15, weight: .medium, design: .rounded))
                            .foregroundStyle(OunjePalette.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.bottom, 26)

                    if let authStatusMessage {
                        Text(authStatusMessage)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.92))
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.bottom, 12)
                    }

                    VStack(spacing: 12) {
                        SignInWithAppleButton(.signIn) { request in
                            request.requestedScopes = [.fullName, .email]
                            let nonce = randomNonceString()
                            appleSignInNonce = nonce
                            request.nonce = sha256(nonce)
                        } onCompletion: { result in
                            handleAppleSignIn(result)
                        }
                        .signInWithAppleButtonStyle(.white)
                        .frame(height: OunjeLayout.authButtonHeight)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .disabled(isGoogleSigningIn)

                        Text("or")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.76))
                            .frame(maxWidth: .infinity)

                        Button {
                            signInWithGoogle()
                        } label: {
                            HStack(spacing: 10) {
                                if isGoogleSigningIn {
                                    ProgressView()
                                        .controlSize(.small)
                                        .tint(.black.opacity(0.8))
                                } else {
                                    Image("GoogleLogo")
                                        .resizable()
                                        .scaledToFit()
                                        .frame(width: 18, height: 18)
                                }

                                Text(isGoogleSigningIn ? "Signing in..." : "Sign in with Google")
                                    .font(.system(size: 19, weight: .semibold))
                            }
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.horizontal, 16)
                        }
                        .buttonStyle(WelcomeAuthButtonStyle())
                        .disabled(isGoogleSigningIn)
                    }
                    .padding(.top, 4)
                }
                .padding(.horizontal, 24)
                .padding(.top, 38)
                .padding(.bottom, 18)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .background(OunjePalette.background.ignoresSafeArea())
            }
            .presentationDetents([.height(420)])
            .presentationDragIndicator(.visible)
        }
        .onAppear {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.82)) {
                revealContent = true
            }
        }
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
                        accessToken: authResult.accessToken
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

                    if providerDisabled || hostLookupFailure || networkUnavailable {
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

    private func signInWithGoogle() {
        guard !isGoogleSigningIn else { return }
        isGoogleSigningIn = true

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 550_000_000)

            let session = AuthSession(
                provider: .google,
                userID: stableGoogleDevUserID(),
                email: stableGoogleDevEmail(),
                displayName: "Google user",
                signedInAt: Date(),
                accessToken: nil
            )

            await completeSignIn(with: session)
            isGoogleSigningIn = false
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
            accessToken: nil
        )
    }

    private func completeSignIn(with session: AuthSession, fallbackStatusMessage: String? = nil) async {
        do {
            let remoteState = try await SupabaseProfileStateService.shared.fetchOrCreateProfileState(
                userID: session.userID,
                email: session.email,
                displayName: session.displayName,
                authProvider: session.provider
            )

            let isSameCachedUser = store.authSession?.userID == session.userID
            let cachedProfile = isSameCachedUser ? store.profile : nil
            let cachedCompleted = isSameCachedUser && store.isOnboarded && cachedProfile != nil
            let resolvedOnboarded = remoteState.onboarded || cachedCompleted
            let resolvedProfile = remoteState.profile ?? cachedProfile
            let resolvedStep = resolvedOnboarded
                ? max(remoteState.lastOnboardingStep, FirstLoginOnboardingView.SetupStep.summary.rawValue)
                : max(remoteState.lastOnboardingStep, isSameCachedUser ? store.lastOnboardingStep : 0)

            store.signIn(
                with: session,
                onboarded: resolvedOnboarded,
                profile: resolvedProfile,
                lastOnboardingStep: resolvedStep
            )
            showAuthSheet = false

            if (resolvedOnboarded != remoteState.onboarded ||
                resolvedProfile != nil && remoteState.profile == nil ||
                resolvedStep != remoteState.lastOnboardingStep ||
                remoteState.authProvider != session.provider),
               let resolvedProfile {
                try? await SupabaseProfileStateService.shared.upsertProfile(
                    userID: session.userID,
                    email: session.email,
                    displayName: resolvedProfile.trimmedPreferredName ?? session.displayName,
                    authProvider: session.provider,
                    onboarded: true,
                    lastOnboardingStep: resolvedStep,
                    profile: resolvedProfile
                )
            } else if !resolvedOnboarded && resolvedStep != remoteState.lastOnboardingStep {
                try? await SupabaseProfileStateService.shared.upsertProfile(
                    userID: session.userID,
                    email: session.email,
                    displayName: resolvedProfile?.trimmedPreferredName ?? session.displayName,
                    authProvider: session.provider,
                    onboarded: false,
                    lastOnboardingStep: resolvedStep,
                    profile: resolvedProfile
                )
            }

            authStatusMessage = resolvedOnboarded
                ? "Signed in with \(session.provider.title)."
                : "Signed in. Let's finish setup."
        } catch {
            if let fallbackStatusMessage {
                store.signIn(
                    with: session,
                    onboarded: false,
                    profile: store.profile,
                    lastOnboardingStep: store.lastOnboardingStep
                )
                showAuthSheet = false
                authStatusMessage = fallbackStatusMessage
            } else {
                authErrorMessage = "Sign-in failed. Please try again."
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

    private func stableGoogleDevUserID() -> String {
        let defaults = UserDefaults.standard
        if let existing = defaults.string(forKey: MealPlanningAppStore.googleDevUserIDKey), !existing.isEmpty {
            return existing
        }

        let generated = "google-dev-\(UUID().uuidString.lowercased())"
        defaults.set(generated, forKey: MealPlanningAppStore.googleDevUserIDKey)
        return generated
    }

    private func stableGoogleDevEmail() -> String {
        let defaults = UserDefaults.standard
        if let existing = defaults.string(forKey: MealPlanningAppStore.googleDevEmailKey), !existing.isEmpty {
            return existing
        }

        let generated = "google-user@ounje.local"
        defaults.set(generated, forKey: MealPlanningAppStore.googleDevEmailKey)
        return generated
    }
}

private struct FirstLoginOnboardingView: View {
    @EnvironmentObject private var store: MealPlanningAppStore

    @State private var currentStep: SetupStep = .name
    @State private var preferredName = ""
    @State private var selectedDietaryPatterns = Set(UserProfile.starter.dietaryPatterns)
    @State private var selectedCuisines = Set(UserProfile.starter.preferredCuisines)
    @State private var selectedCuisineCountries = Set(UserProfile.starter.cuisineCountries)
    @State private var countryCuisineSearch = ""
    @State private var animatedCountryPlaceholder = ""
    @State private var animatedRestrictionPlaceholder = ""
    @State private var selectedFavoriteFoods = Set(UserProfile.starter.favoriteFoods)
    @State private var selectedNeverIncludeFoods = Set(UserProfile.starter.neverIncludeFoods)
    @State private var selectedGoals = Set(UserProfile.starter.mealPrepGoals)
    @State private var missingEquipment = Set<String>()
    @State private var cadence = UserProfile.starter.cadence
    @State private var deliveryAnchorDay = UserProfile.starter.deliveryAnchorDay
    @State private var deliveryTimeMinutes = UserProfile.starter.deliveryTimeMinutes
    @State private var adults = UserProfile.starter.consumption.adults
    @State private var kids = UserProfile.starter.consumption.kids
    @State private var cooksForOthers = UserProfile.starter.cooksForOthers
    @State private var mealsPerWeek = UserProfile.starter.consumption.mealsPerWeek
    @State private var includeLeftovers = UserProfile.starter.consumption.includeLeftovers
    @State private var budgetPerCycle = UserProfile.starter.budgetPerCycle
    @State private var budgetWindow = UserProfile.starter.budgetWindow
    @State private var budgetFlexibilityScore = UserProfile.starter.budgetFlexibility.calibrationScore
    @State private var allergiesText = ""
    @State private var extraFavoriteFoodsText = ""
    @State private var neverIncludeText = ""
    @State private var addressLine1 = ""
    @State private var addressLine2 = ""
    @State private var city = ""
    @State private var region = ""
    @State private var postalCode = ""
    @State private var deliveryNotes = ""
    @State private var isAddressSheetPresented = false
    @StateObject private var addressAutocomplete = AddressAutocompleteViewModel()
    @State private var purchasingBehavior = UserProfile.starter.purchasingBehavior
    @State private var orderingAutonomy = UserProfile.starter.orderingAutonomy
    @State private var isSaving = false
    @State private var presetSelectionPulseID = 0
    @State private var identityStepAnchorBaseline: CGFloat?
    @State private var hasUnlockedIdentityCTA = false
    @State private var presetSelectionPulseTask: Task<Void, Never>?
    @State private var briefPrefetchTask: Task<Void, Never>?
    @State private var isNameIntroAnimated = false
    @State private var previousStep: SetupStep = .name
    @State private var hasHydratedStoredDraft = false

    private let dietaryPatternOptions = [
        "Omnivore",
        "Halal",
        "Kosher",
        "Vegetarian",
        "Vegan",
        "Pescatarian",
        "Gluten-free",
        "Dairy-free",
        "Low-carb",
        "High-protein",
        "Keto"
    ]

    private let baseFavoriteFoodOptions = [
        "Chicken bowls",
        "Rice bowls",
        "Pasta",
        "Tacos",
        "Salads",
        "Wraps",
        "Stir-fry",
        "Salmon"
    ]

    private let baseNeverIncludeOptions = [
        "Mushrooms",
        "Olives",
        "Cilantro",
        "Tofu",
        "Seafood",
        "Beef",
        "Pork",
        "Spicy food"
    ]

    private let mealPrepGoalOptions = [
        "Speed",
        "Taste",
        "Cost",
        "Variety",
        "Macros",
        "Family-friendly",
        "Minimal cleanup",
        "Repeatability"
    ]

    private let equipmentOptions = [
        KitchenEquipmentOption(title: "Microwave", detail: "For reheating, steaming, and fast prep.", symbol: "microwave"),
        KitchenEquipmentOption(title: "Oven", detail: "For roasting, baking, and sheet-pan meals.", symbol: "oven"),
        KitchenEquipmentOption(title: "Stovetop", detail: "For sautés, pasta, and skillet meals.", symbol: "cooktop"),
        KitchenEquipmentOption(title: "Air fryer", detail: "For crisp textures without a full oven.", symbol: "fan"),
        KitchenEquipmentOption(title: "Blender", detail: "For sauces, smoothies, and marinades.", symbol: "drop"),
        KitchenEquipmentOption(title: "Rice cooker", detail: "For grains and simple batch cooking.", symbol: "takeoutbag.and.cup.and.straw"),
        KitchenEquipmentOption(title: "Instant Pot", detail: "For pressure-cooked or one-pot recipes.", symbol: "timer"),
        KitchenEquipmentOption(title: "Freezer", detail: "For bulk prep and longer storage.", symbol: "snowflake")
    ]

    private let countryCuisineOptions = Locale.Region.isoRegions
        .compactMap { Locale.current.localizedString(forRegionCode: $0.identifier) }
        .sorted()

    private let animatedCountryPlaceholderOptions = [
        "Nigeria",
        "Japan",
        "Mexico",
        "Lebanon",
        "Brazil",
        "Jamaica",
        "Ghana",
        "Italy"
    ]

    private let animatedRestrictionPlaceholderOptions = [
        "peanuts, shellfish",
        "pork, cilantro",
        "dairy, mushrooms",
        "sesame, beef"
    ]

    private var selectableCuisineOptions: [CuisinePreference] {
        let filtered = CuisinePreference.allCases.filter {
            ![
                .vegan,
                .greek,
                .brazilian,
                .ethiopian,
                .thai,
                .asian,
                .spanish
            ].contains($0)
        }

        let preferredOrder: [CuisinePreference] = [
            .italian,
            .american,
            .mexican,
            .chinese,
            .westAfrican,
            .indian,
            .japanese,
            .korean,
            .mediterranean,
            .middleEastern,
            .caribbean
        ]

        return filtered.sorted { lhs, rhs in
            let lhsIndex = preferredOrder.firstIndex(of: lhs) ?? .max
            let rhsIndex = preferredOrder.firstIndex(of: rhs) ?? .max

            if lhsIndex != rhsIndex {
                return lhsIndex < rhsIndex
            }

            return lhs.title < rhs.title
        }
    }

    private var selectableOrderingAutonomyOptions: [OrderingAutonomyLevel] {
        OrderingAutonomyLevel.allCases.filter { $0 != .suggestOnly }
    }

    private var favoriteFoodOptions: [String] {
        let cuisineSuggestions = selectedCuisines.flatMap { cuisineFavoriteFoodSuggestions[$0] ?? [] }
        let countrySignals = selectedCuisineCountries.flatMap { cuisineCountryFavoriteSuggestions[$0] ?? [] }
        let restrictedFoods = restrictedFoodSignals

        return deduplicatedOptions(
            from: cuisineSuggestions + countrySignals + baseFavoriteFoodOptions + Array(selectedFavoriteFoods),
            excluding: restrictedFoods
        )
    }

    private var neverIncludeOptions: [String] {
        let cuisineSuggestions = selectedCuisines.flatMap { cuisineNeverIncludeSuggestions[$0] ?? [] }
        let dietarySuggestions = selectedDietaryPatterns.flatMap { dietaryNeverIncludeSuggestions[$0] ?? [] }

        return deduplicatedOptions(
            from: dietarySuggestions + cuisineSuggestions + baseNeverIncludeOptions + Array(selectedNeverIncludeFoods)
        )
    }

    private var availableKitchenEquipment: [String] {
        equipmentOptions
            .map(\.title)
            .filter { !missingEquipment.contains($0) }
    }

    private let onboardingTopAnchorID = "onboarding-top-anchor"

    private let cuisineFavoriteFoodSuggestions: [CuisinePreference: [String]] = [
        .american: ["Burgers", "BBQ chicken", "Mac and cheese bowls", "Breakfast burritos"],
        .chinese: ["Lo mein", "Dumplings", "Sesame chicken", "Egg fried rice"],
        .italian: ["Vodka pasta", "Chicken parm", "Pesto pasta", "Baked ziti"],
        .mexican: ["Burrito bowls", "Quesadillas", "Street tacos", "Fajita bowls"],
        .mediterranean: ["Chicken shawarma bowls", "Falafel bowls", "Greek salad", "Hummus wraps"],
        .middleEastern: ["Kebabs", "Rice platters", "Chicken kofta", "Labneh bowls"],
        .indian: ["Butter chicken", "Biryani", "Tikka bowls", "Chana masala"],
        .japanese: ["Teriyaki bowls", "Katsu curry", "Sushi bake", "Miso salmon"],
        .korean: ["Bibimbap", "Bulgogi bowls", "Kimchi fried rice", "Spicy chicken"],
        .french: ["Roast chicken", "Herb potatoes", "Niçoise salad", "Creamy chicken"],
        .caribbean: ["Jerk chicken", "Plantain bowls", "Rice and peas", "Curry goat"],
        .westAfrican: ["Jollof rice", "Suya bowls", "Egusi soup", "Pepper soup"]
    ]

    private let cuisineCountryFavoriteSuggestions: [String: [String]] = [
        "Nigeria": ["Jollof rice", "Moi moi", "Suya bowls"],
        "Ghana": ["Waakye bowls", "Groundnut stew", "Jollof rice"],
        "Jamaica": ["Jerk chicken", "Rice and peas", "Curry chicken"],
        "Mexico": ["Street tacos", "Birria bowls", "Enchiladas"],
        "Japan": ["Onigiri", "Katsu curry", "Teriyaki bowls"],
        "Lebanon": ["Chicken tawook", "Kafta bowls", "Manakish"],
        "Brazil": ["Feijoada", "Grilled chicken plates", "Rice and beans"],
        "Italy": ["Rigatoni", "Chicken parm", "Pesto pasta"]
    ]

    private let cuisineNeverIncludeSuggestions: [CuisinePreference: [String]] = [
        .american: ["Pickles", "Blue cheese"],
        .chinese: ["Five-spice", "Oyster sauce"],
        .italian: ["Anchovies", "Capers"],
        .mexican: ["Jalapeños", "Sour cream"],
        .mediterranean: ["Feta", "Olives"],
        .middleEastern: ["Tahini", "Sumac"],
        .indian: ["Paneer", "Curry leaves"],
        .japanese: ["Seaweed", "Miso"],
        .korean: ["Kimchi", "Gochujang"],
        .caribbean: ["Scotch bonnet", "Allspice"],
        .westAfrican: ["Crayfish", "Palm oil"]
    ]

    private let dietaryNeverIncludeSuggestions: [String: [String]] = [
        "Vegan": ["Beef", "Chicken", "Seafood", "Eggs", "Cheese"],
        "Vegetarian": ["Beef", "Chicken", "Seafood"],
        "Pescatarian": ["Beef", "Chicken", "Pork"],
        "Halal": ["Pork"],
        "Kosher": ["Pork", "Shellfish"],
        "Dairy-free": ["Cheese", "Cream"],
        "Gluten-free": ["Pasta", "Breaded food"],
        "Keto": ["Rice", "Pasta"],
        "Low-carb": ["Pasta", "White rice"]
    ]

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

            GeometryReader { proxy in
                ScrollViewReader { scrollProxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            Color.clear
                                .frame(height: 0)
                                .id(onboardingTopAnchorID)
                                .background(
                                    GeometryReader { geometry in
                                        Color.clear.preference(
                                            key: OnboardingTopAnchorPreferenceKey.self,
                                            value: geometry.frame(in: .named("onboarding-scroll")).minY
                                        )
                                    }
                                )

                            if currentStep != .name {
                                onboardingProgressHeader
                                    .transition(
                                        .asymmetric(
                                            insertion: .move(edge: .top).combined(with: .opacity),
                                            removal: .opacity
                                        )
                                    )
                            }
                            if currentStep != .name {
                                OnboardingPromptCard(step: currentStep)
                                    .transition(
                                        .asymmetric(
                                            insertion: .move(edge: .top).combined(with: .opacity),
                                            removal: .opacity
                                        )
                                    )
                            }

                            currentStepContent
                                .transition(stepTransition)
                        }
                        .id(currentStep)
                        .padding(.horizontal, OunjeLayout.screenHorizontalPadding)
                        .padding(.top, 14)
                        .padding(.bottom, 120 + proxy.safeAreaInsets.bottom)
                    }
                    .coordinateSpace(name: "onboarding-scroll")
                    .scrollIndicators(.hidden)
                    .onChange(of: currentStep) { newStep in
                        previousStep = newStep.previous ?? .name
                        if currentStep == .identity {
                            identityStepAnchorBaseline = nil
                            hasUnlockedIdentityCTA = false
                        }
                        if currentStep.next == .summary {
                            prefetchAgentBrief()
                        }
                        withAnimation(.easeInOut(duration: 0.22)) {
                            scrollProxy.scrollTo(onboardingTopAnchorID, anchor: .top)
                        }
                        schedulePresetSelectionPulse()
                    }
                    .onPreferenceChange(OnboardingTopAnchorPreferenceKey.self) { minY in
                        guard currentStep == .identity else { return }

                        if identityStepAnchorBaseline == nil {
                            identityStepAnchorBaseline = minY
                        }

                        guard let baseline = identityStepAnchorBaseline else { return }
                        if !hasUnlockedIdentityCTA && minY < baseline - 48 {
                            withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
                                hasUnlockedIdentityCTA = true
                            }
                        }
                    }
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 10)
                            .onChanged { value in
                                guard currentStep == .identity, !hasUnlockedIdentityCTA else { return }
                                guard abs(value.translation.height) > 18 else { return }
                                withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
                                    hasUnlockedIdentityCTA = true
                                }
                            }
                    )
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 18)
                            .onEnded { value in
                                handleHorizontalSwipe(value)
                            }
                    )
                    .safeAreaInset(edge: .bottom) {
                        VStack(spacing: 0) {
                            if shouldShowOnboardingActionBar {
                                HStack(spacing: 10) {
                                    if let previousStep = currentStep.previous {
                                        Button {
                                            persistDraft(step: previousStep)
                                            withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
                                                currentStep = previousStep
                                            }
                                        } label: {
                                            Image(systemName: "arrow.left")
                                                .font(.system(size: 18, weight: .black))
                                                .frame(width: 54, height: 54)
                                        }
                                        .buttonStyle(OnboardingArrowButtonStyle())
                                    } else {
                                        Color.clear
                                            .frame(width: 54, height: 54)
                                    }

                                    Spacer()

                                    Button {
                                        advance()
                                    } label: {
                                        Group {
                                            if isSaving && currentStep == .summary {
                                                HStack(spacing: 8) {
                                                    ProgressView().tint(.black)
                                                    Text("Entering")
                                                        .biroHeaderFont(15)
                                                }
                                                .frame(minWidth: 140, minHeight: 54)
                                            } else if currentStep == .summary {
                                                HStack(spacing: 8) {
                                                    Text("Enter app")
                                                        .biroHeaderFont(15)
                                                    Image(systemName: "checkmark")
                                                        .font(.system(size: 15, weight: .black))
                                                }
                                                .frame(minWidth: 140, minHeight: 54)
                                            } else {
                                                Image(systemName: "arrow.right")
                                                    .font(.system(size: 18, weight: .black))
                                                    .frame(width: 54, height: 54)
                                            }
                                        }
                                    }
                                    .buttonStyle(OnboardingArrowButtonStyle(isPrimary: true))
                                    .disabled(!canAdvanceCurrentStep || isSaving)
                                }
                                .padding(.horizontal, OunjeLayout.screenHorizontalPadding)
                                .padding(.top, 10)
                                .padding(.bottom, max(12, proxy.safeAreaInsets.bottom + 8))
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                            }
                        }
                        .background(
                            LinearGradient(
                                colors: [
                                    OunjePalette.background.opacity(0),
                                    OunjePalette.background.opacity(0.9),
                                    OunjePalette.background
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .animation(.spring(response: 0.34, dampingFraction: 0.84), value: shouldShowOnboardingActionBar)
                    }
                }
            }
        }
        .tint(OunjePalette.accent)
        .preferredColorScheme(.dark)
        .onChange(of: budgetWindow) { _ in
            budgetPerCycle = min(max(budgetPerCycle, budgetRange.lowerBound), budgetRange.upperBound)
        }
        .onChange(of: cooksForOthers) { isCookingForOthers in
            if !isCookingForOthers {
                adults = 1
                kids = 0
            }
        }
        .onAppear {
            if !hasHydratedStoredDraft {
                hydrateDraftFromStore()
                hasHydratedStoredDraft = true
            }
            if orderingAutonomy == .suggestOnly {
                orderingAutonomy = .autoOrderWithinBudget
            }
            withAnimation(.easeInOut(duration: 3.6).repeatForever(autoreverses: true)) {
                isNameIntroAnimated = true
            }
            schedulePresetSelectionPulse()
        }
        .onChange(of: orderingAutonomy) { _ in
            guard currentStep.next == .summary else { return }
            prefetchAgentBrief()
        }
        .onDisappear {
            presetSelectionPulseTask?.cancel()
            briefPrefetchTask?.cancel()
            persistDraftLocally()
        }
        .sheet(isPresented: $isAddressSheetPresented) {
            AddressSetupSheet(
                addressLine1: $addressLine1,
                addressLine2: $addressLine2,
                city: $city,
                region: $region,
                postalCode: $postalCode,
                deliveryNotes: $deliveryNotes,
                autocomplete: addressAutocomplete,
                onSuggestionSelected: selectAddressSuggestion(_:),
                onClear: clearAddress
            )
        }
    }

    private var shouldShowOnboardingActionBar: Bool {
        currentStep != .identity || hasUnlockedIdentityCTA
    }

    private var stepTransition: AnyTransition {
        if previousStep == .name && currentStep != .name {
            return .asymmetric(
                insertion: .offset(y: 24)
                    .combined(with: .opacity)
                    .combined(with: .scale(scale: 0.98, anchor: .top)),
                removal: .opacity.combined(with: .scale(scale: 0.98))
            )
        }

        if currentStep == .name {
            return .asymmetric(
                insertion: .opacity.combined(with: .scale(scale: 0.98)),
                removal: .move(edge: .leading).combined(with: .opacity)
            )
        }

        return .asymmetric(
            insertion: .move(edge: .trailing).combined(with: .opacity),
            removal: .move(edge: .leading).combined(with: .opacity)
        )
    }

    private var onboardingProgressHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Build your prep profile")
                    .biroHeaderFont(24)
                    .foregroundStyle(.white)
                Spacer()
            }

            if currentStep != .name {
                Text("Ounje is shaping your first planning run as you go, so each tap should feel like progress, not paperwork.")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(OunjePalette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                ForEach(SetupStep.allCases, id: \.rawValue) { step in
                    Capsule()
                        .fill(step.index <= currentStep.index ? OunjePalette.accent : OunjePalette.elevated)
                        .frame(height: 6)
                }
            }
        }
    }

    @ViewBuilder
    private var currentStepContent: some View {
        switch currentStep {
        case .name:
            nameStepContent
        case .identity:
            identityStepContent
        case .cuisines:
            cuisineStepContent
        case .household:
            householdStepContent
        case .kitchen:
            kitchenStepContent
        case .budget:
            budgetStepContent
        case .ordering:
            orderingStepContent
        case .summary:
            summaryStepContent
        }
    }

    private var nameStepContent: some View {
        VStack(alignment: .leading, spacing: 24) {
            ZStack {
                Circle()
                    .fill(OunjePalette.accent.opacity(0.16))
                    .frame(width: 180, height: 180)
                    .blur(radius: 8)
                    .offset(x: isNameIntroAnimated ? 28 : -12, y: isNameIntroAnimated ? -10 : 18)

                Circle()
                    .fill(Color(hex: "6AD6FF").opacity(0.14))
                    .frame(width: 132, height: 132)
                    .blur(radius: 10)
                    .offset(x: isNameIntroAnimated ? -56 : -12, y: isNameIntroAnimated ? 26 : -20)

                Circle()
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
                    .frame(width: 126, height: 126)

                Circle()
                    .fill(OunjePalette.panel.opacity(0.92))
                    .frame(width: 94, height: 94)

                Image(systemName: "person.fill")
                    .font(.system(size: 30, weight: .black))
                    .foregroundStyle(OunjePalette.accent)
                    .scaleEffect(isNameIntroAnimated ? 1.06 : 0.96)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 52)
            .padding(.bottom, 10)

            VStack(alignment: .leading, spacing: 12) {
                Text("What's your name?")
                    .biroHeaderFont(32)
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)

                TextField("", text: $preferredName)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .modifier(OnboardingInputModifier())
            }
        }
    }

    private var identityStepContent: some View {
        VStack(spacing: 12) {
            OnboardingSectionCard(
                title: "Dietary identity",
                detail: "Pick every food rule the planner should respect from day one."
            ) {
                AnimatedSelectionBubbleGrid(
                    options: dietaryPatternOptions,
                    selection: $selectedDietaryPatterns,
                    animationTrigger: presetSelectionPulseID
                )
            }

            OnboardingSectionCard(
                title: "Allergies and hard restrictions",
                detail: "Use one field for allergies, banned ingredients, and any absolute opt-outs."
            ) {
                AnimatedPlaceholderTextEditor(
                    text: $allergiesText,
                    animatedPlaceholder: $animatedRestrictionPlaceholder,
                    animationOptions: animatedRestrictionPlaceholderOptions,
                    basePlaceholder: "Peanuts, shellfish, pork, cilantro..."
                )
            }
        }
    }

    private var cuisineStepContent: some View {
        VStack(spacing: 12) {
            OnboardingSectionCard(
                title: "Popular cuisines",
                detail: "Tell the planner what should show up more often."
            ) {
                AnimatedEnumBubbleGrid(
                    options: selectableCuisineOptions,
                    selection: $selectedCuisines,
                    animationTrigger: presetSelectionPulseID,
                    leadingEmoji: { $0.flagEmoji }
                ) { $0.title }

                Divider()
                    .overlay(OunjePalette.stroke)
                    .padding(.vertical, 2)

                VStack(alignment: .leading, spacing: 10) {
                    Text("Cuisine by country")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                    Text("Add a country when the taste signal is broader than one cuisine label.")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(OunjePalette.secondaryText)
                }

                AnimatedPlaceholderTextField(
                    text: $countryCuisineSearch,
                    animatedPlaceholder: $animatedCountryPlaceholder,
                    animationOptions: animatedCountryPlaceholderOptions,
                    basePlaceholder: "Search every country"
                )

                if !selectedCuisineCountries.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Selected countries")
                            .font(.system(size: 13, weight: .bold))
                        WrapFlow(items: Array(selectedCuisineCountries).sorted()) { country in
                            TagPill(text: country)
                        }
                    }
                }

                ForEach(filteredCountryCuisineOptions, id: \.self) { country in
                    SelectablePill(
                        title: country,
                        isSelected: selectedCuisineCountries.contains(country)
                    ) {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) {
                            if selectedCuisineCountries.contains(country) {
                                selectedCuisineCountries.remove(country)
                            } else {
                                selectedCuisineCountries.insert(country)
                            }
                        }
                    }
                }

                if filteredCountryCuisineOptions.isEmpty {
                    Text(countryCuisineSearch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Type to search countries." : "No countries match that search.")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(OunjePalette.secondaryText)
                }
            }
        }
    }

    private var householdStepContent: some View {
        VStack(spacing: 12) {
            OnboardingSectionCard(
                title: "Meal-prep intent",
                detail: "Pick what the system should optimize for."
            ) {
                AnimatedSelectionBubbleGrid(
                    options: mealPrepGoalOptions,
                    selection: $selectedGoals,
                    animationTrigger: presetSelectionPulseID
                )
            }

            OnboardingSectionCard(
                title: "Prep cadence",
                detail: "This controls how often groceries are ordered and meals are refreshed."
            ) {
                HStack(spacing: 10) {
                    cadenceMenuPill(
                        label: "Delivery frequency",
                        value: cadence.title
                    ) {
                        ForEach(MealCadence.allCases) { option in
                            Button {
                                withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
                                    cadence = option
                                }
                            } label: {
                                if cadence == option {
                                    Label(option.title, systemImage: "checkmark")
                                } else {
                                    Text(option.title)
                                }
                            }
                        }
                    }

                    if cadence != .daily {
                        cadenceMenuPill(
                            label: "Prime day",
                            value: deliveryAnchorDayMenuLabel
                        ) {
                            ForEach(DeliveryAnchorDay.allCases) { day in
                                Button {
                                    withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
                                        deliveryAnchorDay = day
                                    }
                                } label: {
                                    if deliveryAnchorDay == day {
                                        Label(day.title, systemImage: "checkmark")
                                    } else {
                                        Text(day.title)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private var deliveryAnchorDayMenuLabel: String {
        switch cadence {
        case .daily:
            return deliveryAnchorDay.title
        case .everyFewDays:
            return "Starting \(deliveryAnchorDay.pluralTitle)"
        case .twiceWeekly:
            return "Starting \(deliveryAnchorDay.pluralTitle)"
        case .weekly:
            return "On \(deliveryAnchorDay.pluralTitle)"
        case .biweekly:
            return "Every other \(deliveryAnchorDay.title)"
        case .monthly:
            return "First \(deliveryAnchorDay.title)"
        }
    }

    @ViewBuilder
    private func cadenceMenuPill<MenuContent: View>(
        label: String,
        value: String,
        @ViewBuilder content: () -> MenuContent
    ) -> some View {
        Menu {
            content()
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(label)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(OunjePalette.secondaryText)

                HStack(spacing: 8) {
                    Text(value)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)

                    Spacer(minLength: 0)

                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(OunjePalette.accent)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(OunjePalette.elevated)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(OunjePalette.stroke, lineWidth: 1)
                    )
            )
        }
    }

    private var kitchenStepContent: some View {
        VStack(spacing: 12) {
            OnboardingSectionCard(
                title: "Kitchen setup",
                detail: "Assume you have the basics. Just mark what is missing so Ounje avoids those recipes."
            ) {
                VStack(alignment: .leading, spacing: 10) {
                    if !missingEquipment.isEmpty {
                        Button("I have the basics") {
                            withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                                missingEquipment.removeAll()
                            }
                        }
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(OunjePalette.accent)
                    }

                    ForEach(equipmentOptions) { equipment in
                        MissingKitchenEquipmentRow(
                            title: equipment.title,
                            detail: equipment.detail,
                            symbol: equipment.symbol,
                            isMissing: missingEquipment.contains(equipment.title)
                        ) {
                            withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                                if missingEquipment.contains(equipment.title) {
                                    missingEquipment.remove(equipment.title)
                                } else {
                                    missingEquipment.insert(equipment.title)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private var budgetStepContent: some View {
        VStack(spacing: 12) {
            OnboardingSectionCard(
                title: "Budget",
                detail: "Set the target spend the planner should work within, then tune how tightly it should hold the line."
            ) {
                Picker("Budget window", selection: $budgetWindow) {
                    ForEach(BudgetWindow.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.segmented)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Target budget")
                        .biroHeaderFont(11)
                        .tracking(0.8)
                        .foregroundStyle(OunjePalette.secondaryText)

                    HStack(alignment: .lastTextBaseline, spacing: 8) {
                        Text(budgetPerCycle.asCurrency)
                            .biroHeaderFont(34)
                            .foregroundStyle(.white)

                        Text(budgetWindow == .weekly ? "per week" : "per month")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(OunjePalette.accent)
                    }

                    Text(translatedBudgetSummary)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(OunjePalette.secondaryText)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    OunjePalette.panel,
                                    OunjePalette.elevated.opacity(0.98),
                                    OunjePalette.accent.opacity(0.08)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .stroke(OunjePalette.accent.opacity(0.24), lineWidth: 1)
                        )
                )

                Slider(value: $budgetPerCycle, in: budgetRange, step: budgetStep)
                    .tint(OunjePalette.accent)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Budget flexibility")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(OunjePalette.secondaryText)

                    BudgetFlexibilityCalibrationCard(score: $budgetFlexibilityScore)
                }

                Divider()
                    .overlay(OunjePalette.stroke)
                    .padding(.vertical, 4)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Household context")
                        .font(.system(size: 13, weight: .bold))

                    Picker("Cooking for", selection: $cooksForOthers) {
                        Text("Just me").tag(false)
                        Text("Me + others").tag(true)
                    }
                    .pickerStyle(.segmented)

                    if cooksForOthers {
                        Stepper("Adults: \(adults)", value: $adults, in: 1...8)
                        Stepper("Kids: \(kids)", value: $kids, in: 0...6)
                    } else {
                        Text("Portions will default to solo meal prep.")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(OunjePalette.secondaryText)
                    }
                }
            }
        }
    }

    private var orderingStepContent: some View {
        VStack(spacing: 12) {
            OnboardingSectionCard(
                title: "Ordering autonomy",
                detail: "Decide how much checkout power the agent should have."
            ) {
                ForEach(selectableOrderingAutonomyOptions) { option in
                    SelectionCard(
                        title: option.title,
                        subtitle: autonomySubtitle(for: option),
                        isSelected: orderingAutonomy == option,
                        animationTrigger: presetSelectionPulseID,
                        animationIndex: selectableOrderingAutonomyOptions.firstIndex(of: option) ?? 0
                    ) {
                        orderingAutonomy = option
                    }
                }
            }

            OnboardingSectionCard(
                title: "Home address",
                detail: "Optional in onboarding. Open the address modal when you're ready, or fill it in later from the app."
            ) {
                Button {
                    isAddressSheetPresented = true
                } label: {
                    HStack(spacing: 14) {
                        Image(systemName: "house.fill")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(.black)
                            .frame(width: 42, height: 42)
                            .background(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(OunjePalette.accent)
                            )

                        VStack(alignment: .leading, spacing: 4) {
                            Text(addressButtonTitle)
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(.white)
                            Text(addressButtonSubtitle)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(OunjePalette.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Spacer(minLength: 12)

                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(OunjePalette.secondaryText)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(OunjePalette.elevated)
                            .overlay(
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .stroke(OunjePalette.stroke, lineWidth: 1)
                            )
                    )
                }
                .buttonStyle(.plain)

                if hasAnyAddress {
                    Button("Clear address") {
                        clearAddress()
                    }
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(OunjePalette.secondaryText)
                }
            }
        }
    }

    private var summaryStepContent: some View {
        AgentSummaryExperienceCard(profile: draftProfile)
    }

    private var canSubmit: Bool {
        !preferredName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !selectedDietaryPatterns.isEmpty &&
        (!selectedCuisines.isEmpty || !selectedCuisineCountries.isEmpty) &&
        !selectedGoals.isEmpty &&
        budgetPerCycle >= 25
    }

    private var canAdvanceCurrentStep: Bool {
        switch currentStep {
        case .name:
            return !preferredName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .identity:
            return !selectedDietaryPatterns.isEmpty
        case .cuisines:
            return !selectedCuisines.isEmpty || !selectedCuisineCountries.isEmpty
        case .household:
            return !selectedGoals.isEmpty
        case .kitchen:
            return true
        case .budget:
            return budgetPerCycle >= 25
        case .ordering:
            return true
        case .summary:
            return canSubmit
        }
    }

    private var primaryActionTitle: String {
        currentStep == .summary ? (isSaving ? "Saving..." : "Complete Onboarding") : "Next"
    }

    private var hasAnyAddress: Bool {
        !addressLine1.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
        !city.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
        !region.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
        !postalCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var hasValidAddress: Bool {
        !addressLine1.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !city.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !region.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !postalCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var translatedBudgetSummary: String {
        let convertedAmount: Double
        let convertedWindowLabel: String

        switch budgetWindow {
        case .weekly:
            convertedAmount = budgetPerCycle * 4
            convertedWindowLabel = "month"
        case .monthly:
            convertedAmount = budgetPerCycle / 4
            convertedWindowLabel = "week"
        }

        return "\(convertedAmount.asCurrency) per \(convertedWindowLabel)"
    }

    private var addressButtonTitle: String {
        hasValidAddress ? "Update home address" : "Set home address"
    }

    private var addressButtonSubtitle: String {
        if hasValidAddress {
            return "\(addressLine1), \(city), \(region) \(postalCode)"
        }
        return "Tap to add a delivery address. You can still skip this for now."
    }

    private func advance() {
        if currentStep == .summary {
            submit()
            return
        }

        guard canAdvanceCurrentStep, let next = currentStep.next else { return }
        persistDraft(step: next)
        if next == .summary {
            prefetchAgentBrief()
        }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
            currentStep = next
        }
    }

    private func handleHorizontalSwipe(_ value: DragGesture.Value) {
        guard !isSaving else { return }

        let horizontalDistance = value.translation.width
        let verticalDistance = value.translation.height

        guard abs(horizontalDistance) > abs(verticalDistance),
              abs(horizontalDistance) > 60 else { return }

        if horizontalDistance < 0 {
            advance()
            return
        }

        guard let previousStep = currentStep.previous else { return }
        persistDraft(step: previousStep)
        withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
            currentStep = previousStep
        }
    }

    private func schedulePresetSelectionPulse() {
        presetSelectionPulseTask?.cancel()
        presetSelectionPulseTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 140_000_000)
            guard !Task.isCancelled else { return }
            presetSelectionPulseID += 1
        }
    }

    private func prefetchAgentBrief() {
        let profile = draftProfile
        briefPrefetchTask?.cancel()
        briefPrefetchTask = Task(priority: .utility) {
            _ = try? await SupabaseAgentBriefService.shared.generateBrief(for: profile)
        }
    }

    private var restrictedFoodSignals: Set<String> {
        var restricted = Set<String>()

        for pattern in selectedDietaryPatterns {
            switch pattern.lowercased() {
            case "vegan":
                restricted.formUnion(["Chicken bowls", "Salmon", "Chicken parm", "Butter chicken", "Jerk chicken", "Kebabs", "Miso salmon", "Bulgogi bowls", "BBQ chicken", "Chicken shawarma bowls", "Teriyaki bowls", "Chicken tawook", "Curry chicken", "Grilled chicken plates", "Suya bowls"])
            case "vegetarian":
                restricted.formUnion(["Chicken bowls", "Salmon", "Chicken parm", "Butter chicken", "Jerk chicken", "Kebabs", "Miso salmon", "Bulgogi bowls", "BBQ chicken", "Chicken shawarma bowls", "Teriyaki bowls", "Chicken tawook", "Curry chicken", "Grilled chicken plates", "Suya bowls", "Curry goat"])
            case "pescatarian":
                restricted.formUnion(["Chicken bowls", "Chicken parm", "Butter chicken", "Jerk chicken", "Kebabs", "Bulgogi bowls", "BBQ chicken", "Chicken shawarma bowls", "Teriyaki bowls", "Chicken tawook", "Curry chicken", "Grilled chicken plates", "Suya bowls", "Curry goat"])
            case "halal":
                restricted.formUnion(["Pork"])
            case "kosher":
                restricted.formUnion(["Pork", "Shellfish"])
            case "dairy-free":
                restricted.formUnion(["Mac and cheese bowls"])
            default:
                break
            }
        }

        return restricted
    }

    private func deduplicatedOptions(from source: [String], excluding exclusions: Set<String> = []) -> [String] {
        var seen = Set<String>()
        var result: [String] = []

        for option in source {
            let trimmed = option.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard !exclusions.contains(trimmed) else { continue }
            guard seen.insert(trimmed).inserted else { continue }
            result.append(trimmed)
        }

        return result
    }

    private var parsedAllergies: [String] {
        parseList(allergiesText)
    }

    private var parsedExtraFavoriteFoods: [String] {
        parseList(extraFavoriteFoodsText)
    }

    private var parsedNeverIncludeFoods: [String] {
        parseList(neverIncludeText)
    }

    private var budgetRange: ClosedRange<Double> {
        switch budgetWindow {
        case .weekly:
            return 40...500
        case .monthly:
            return 160...2000
        }
    }

    private var budgetStep: Double {
        budgetWindow == .weekly ? 5 : 20
    }

    private var normalizedAdults: Int {
        cooksForOthers ? adults : 1
    }

    private var normalizedKids: Int {
        cooksForOthers ? kids : 0
    }

    private var filteredCountryCuisineOptions: [String] {
        let trimmedSearch = countryCuisineSearch.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmedSearch.isEmpty {
            return []
        }

        return countryCuisineOptions
            .filter { $0.localizedCaseInsensitiveContains(trimmedSearch) }
            .prefix(7)
            .map { $0 }
    }

    private var draftProfile: UserProfile {
        UserProfile(
            preferredName: preferredName.trimmingCharacters(in: .whitespacesAndNewlines),
            preferredCuisines: Array(selectedCuisines).sorted { $0.title < $1.title },
            cadence: cadence,
            deliveryAnchorDay: deliveryAnchorDay,
            deliveryTimeMinutes: deliveryTimeMinutes,
            rotationPreference: .dynamic,
            maxRepeatsPerCycle: UserProfile.starter.maxRepeatsPerCycle,
            storage: UserProfile.starter.storage,
            consumption: ConsumptionProfile(
                adults: normalizedAdults,
                kids: normalizedKids,
                mealsPerWeek: mealsPerWeek,
                includeLeftovers: includeLeftovers
            ),
            preferredProviders: [],
            pantryStaples: UserProfile.starter.pantryStaples,
            allergies: parsedAllergies,
            budgetPerCycle: budgetPerCycle,
            explorationLevel: .balanced,
            deliveryAddress: DeliveryAddress(
                line1: addressLine1.trimmingCharacters(in: .whitespacesAndNewlines),
                line2: addressLine2.trimmingCharacters(in: .whitespacesAndNewlines),
                city: city.trimmingCharacters(in: .whitespacesAndNewlines),
                region: region.trimmingCharacters(in: .whitespacesAndNewlines),
                postalCode: postalCode.trimmingCharacters(in: .whitespacesAndNewlines),
                deliveryNotes: deliveryNotes.trimmingCharacters(in: .whitespacesAndNewlines)
            ),
            dietaryPatterns: selectedDietaryPatterns.sorted(),
            cuisineCountries: selectedCuisineCountries.sorted(),
            hardRestrictions: [],
            favoriteFoods: Array(selectedFavoriteFoods).sorted() + parsedExtraFavoriteFoods,
            favoriteFlavors: [],
            neverIncludeFoods: Array(selectedNeverIncludeFoods).sorted() + parsedNeverIncludeFoods,
            mealPrepGoals: selectedGoals.sorted(),
            cooksForOthers: cooksForOthers,
            kitchenEquipment: availableKitchenEquipment,
            budgetWindow: budgetWindow,
            budgetFlexibility: BudgetFlexibility.from(calibrationScore: budgetFlexibilityScore),
            purchasingBehavior: purchasingBehavior,
            orderingAutonomy: orderingAutonomy
        )
    }

    private func submit() {
        guard canSubmit else { return }
        isSaving = true

        store.completeOnboarding(with: draftProfile, lastStep: SetupStep.summary.rawValue)

        if let session = store.authSession {
            Task {
                try? await SupabaseProfileStateService.shared.upsertProfile(
                    userID: session.userID,
                    email: session.email,
                    displayName: preferredName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? session.displayName
                        : preferredName.trimmingCharacters(in: .whitespacesAndNewlines),
                    authProvider: session.provider,
                    onboarded: true,
                    lastOnboardingStep: SetupStep.summary.rawValue,
                    profile: draftProfile
                )
                await MainActor.run {
                    isSaving = false
                }
            }
        } else {
            isSaving = false
        }
    }

    private func parseList(_ raw: String) -> [String] {
        raw
            .split(whereSeparator: { $0 == "," || $0 == ";" || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func hydrateDraftFromStore() {
        let sourceProfile = store.profile ?? .starter
        let availableEquipment = Set(equipmentOptions.map(\.title))
        let legacyStarterEquipment = Set(["Microwave", "Oven", "Stovetop"])

        if !store.isOnboarded {
            currentStep = SetupStep.resumeStep(from: store.lastOnboardingStep)
            previousStep = currentStep.previous ?? .name
        }

        preferredName = sourceProfile.trimmedPreferredName
            ?? store.authSession?.displayName?.components(separatedBy: .whitespacesAndNewlines).first
            ?? preferredName
        selectedDietaryPatterns = Set(sourceProfile.dietaryPatterns)
        selectedCuisines = Set(sourceProfile.preferredCuisines)
        selectedCuisineCountries = Set(sourceProfile.cuisineCountries)
        selectedFavoriteFoods = Set(sourceProfile.favoriteFoods)
        selectedNeverIncludeFoods = Set(sourceProfile.neverIncludeFoods)
        selectedGoals = Set(sourceProfile.mealPrepGoals)

        let storedEquipment = Set(sourceProfile.kitchenEquipment)
        if storedEquipment.isEmpty || (!store.isOnboarded && storedEquipment == legacyStarterEquipment) {
            missingEquipment.removeAll()
        } else {
            missingEquipment = availableEquipment.subtracting(storedEquipment)
        }
        cadence = sourceProfile.cadence
        deliveryAnchorDay = sourceProfile.deliveryAnchorDay
        deliveryTimeMinutes = sourceProfile.deliveryTimeMinutes
        adults = sourceProfile.consumption.adults
        kids = sourceProfile.consumption.kids
        cooksForOthers = sourceProfile.cooksForOthers
        mealsPerWeek = sourceProfile.consumption.mealsPerWeek
        includeLeftovers = sourceProfile.consumption.includeLeftovers
        budgetPerCycle = sourceProfile.budgetPerCycle
        budgetWindow = sourceProfile.budgetWindow
        budgetFlexibilityScore = sourceProfile.budgetFlexibility.calibrationScore
        allergiesText = sourceProfile.absoluteRestrictions.joined(separator: ", ")
        extraFavoriteFoodsText = additionalDraftEntryText(
            from: sourceProfile.favoriteFoods,
            excluding: favoriteFoodOptions
        )
        neverIncludeText = additionalDraftEntryText(
            from: sourceProfile.neverIncludeFoods,
            excluding: neverIncludeOptions
        )
        addressLine1 = sourceProfile.deliveryAddress.line1
        addressLine2 = sourceProfile.deliveryAddress.line2
        city = sourceProfile.deliveryAddress.city
        region = sourceProfile.deliveryAddress.region
        postalCode = sourceProfile.deliveryAddress.postalCode
        deliveryNotes = sourceProfile.deliveryAddress.deliveryNotes
        purchasingBehavior = sourceProfile.purchasingBehavior
        orderingAutonomy = sourceProfile.orderingAutonomy == .suggestOnly
            ? .autoOrderWithinBudget
            : sourceProfile.orderingAutonomy
    }

    private func additionalDraftEntryText(from source: [String], excluding knownOptions: [String]) -> String {
        let known = Set(knownOptions.map { $0.lowercased() })
        return source
            .filter { !known.contains($0.lowercased()) }
            .joined(separator: ", ")
    }

    private func persistDraftLocally() {
        store.saveOnboardingDraft(draftProfile, step: currentStep.rawValue)
    }

    private func persistDraft(step: SetupStep? = nil) {
        let profile = draftProfile
        let resolvedStep = step ?? currentStep
        store.saveOnboardingDraft(profile, step: resolvedStep.rawValue)

        guard let session = store.authSession else { return }
        Task(priority: .utility) {
            try? await SupabaseProfileStateService.shared.upsertProfile(
                userID: session.userID,
                email: session.email,
                displayName: profile.trimmedPreferredName ?? session.displayName,
                authProvider: session.provider,
                onboarded: false,
                lastOnboardingStep: resolvedStep.rawValue,
                profile: profile
            )
        }
    }

    private struct KitchenEquipmentOption: Identifiable {
        let title: String
        let detail: String
        let symbol: String

        var id: String { title }
    }

    private func autonomySubtitle(for option: OrderingAutonomyLevel) -> String {
        switch option {
        case .suggestOnly:
            return "The app builds a plan, but the user stays in full control."
        case .approvalRequired:
            return "The app can prep a cart, but it waits for approval before checkout."
        case .autoOrderWithinBudget:
            return "The app can place the order if it stays within the target budget."
        case .fullyAutonomousGuardrails:
            return "The app can run end to end, with hard rules around restrictions and spend."
        }
    }

    private func selectAddressSuggestion(_ suggestion: AddressSuggestion) async {
        guard let address = await addressAutocomplete.resolve(suggestion) else { return }

        await MainActor.run {
            addressLine1 = address.line1
            city = address.city
            region = address.region
            postalCode = address.postalCode
            if !address.line2.isEmpty {
                addressLine2 = address.line2
            }
            addressAutocomplete.query = ""
        }
    }

    private func clearAddress() {
        addressLine1 = ""
        addressLine2 = ""
        city = ""
        region = ""
        postalCode = ""
        deliveryNotes = ""
        addressAutocomplete.query = ""
    }

    fileprivate enum SetupStep: Int, CaseIterable {
        case name
        case identity
        case cuisines
        case household
        case kitchen
        case budget
        case ordering
        case summary

        var index: Int { rawValue }

        var title: String {
            switch self {
            case .name:
                return "Your name"
            case .identity:
                return "Dietary rules"
            case .cuisines:
                return "Cuisine focus"
            case .household:
                return "Goals and cadence"
            case .kitchen:
                return "Kitchen setup"
            case .budget:
                return "Budget and household"
            case .ordering:
                return "Ordering setup"
            case .summary:
                return "Review the agent brief"
            }
        }

        var subtitle: String {
            switch self {
            case .name:
                return "Let’s start with what Ounje should call you."
            case .identity:
                return "Set the hard rules the planner can never break."
            case .cuisines:
                return "Choose the cuisines you want more often, then add country-level signals."
            case .household:
                return "Set what the planner should optimize for and how often it should refresh."
            case .kitchen:
                return "Make sure recipes fit the tools you actually have at home."
            case .budget:
                return "Set the spend target and who these meals need to cover."
            case .ordering:
                return "Set the autonomy level now, and optionally save a home address for later."
            case .summary:
                return "Final check before first-run onboarding is marked complete."
            }
        }

        var prompt: String {
            switch self {
            case .name:
                return "What should I call you while I build this out?"
            case .identity:
                return "What food rules should I lock in before I start planning?"
            case .cuisines:
                return "What cuisines should show up in this household more often?"
            case .household:
                return "What should I optimize around, and how often should I refresh the plan?"
            case .kitchen:
                return "What equipment should I avoid assuming you have?"
            case .budget:
                return "What budget should I work inside, and how much room do I have to flex?"
            case .ordering:
                return "How autonomous should I be, and do you want to save home base now?"
            case .summary:
                return "Before I go live, does this meal-prep brief look right?"
            }
        }

        var symbolName: String {
            switch self {
            case .name:
                return "person.crop.circle.fill"
            case .identity:
                return "checklist"
            case .cuisines:
                return "globe.americas.fill"
            case .household:
                return "person.2.fill"
            case .kitchen:
                return "oven"
            case .budget:
                return "dollarsign.circle.fill"
            case .ordering:
                return "cart.fill"
            case .summary:
                return "sparkles"
            }
        }

        var next: SetupStep? {
            SetupStep(rawValue: rawValue + 1)
        }

        var previous: SetupStep? {
            SetupStep(rawValue: rawValue - 1)
        }

        static func resumeStep(from rawValue: Int) -> SetupStep {
            let clampedValue = min(max(rawValue, SetupStep.name.rawValue), SetupStep.summary.rawValue)
            return SetupStep(rawValue: clampedValue) ?? .name
        }
    }
}

@MainActor
private final class SavedRecipesStore: ObservableObject {
    @Published private(set) var savedRecipes: [DiscoverRecipeCardData] = []

    private let legacyKey = "ounje-saved-recipes-v1"
    private let keyPrefix = "ounje-saved-recipes-v2"
    private let toastCenter: AppToastCenter
    private var activeUserID: String?

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

        guard let authSession else { return }

        do {
            let remoteRecipes = try await SupabaseSavedRecipesService.shared.fetchSavedRecipes(userID: authSession.userID)
            let mergedRecipes = merge(local: savedRecipes, remote: remoteRecipes)

            if mergedRecipes != savedRecipes {
                savedRecipes = mergedRecipes
                persist()
            }

            let remoteIDs = Set(remoteRecipes.map(\.id))
            let unsyncedLocalRecipes = mergedRecipes.filter { !remoteIDs.contains($0.id) }
            if !unsyncedLocalRecipes.isEmpty {
                try await SupabaseSavedRecipesService.shared.upsertSavedRecipes(
                    userID: authSession.userID,
                    recipes: unsyncedLocalRecipes
                )
            }
        } catch {
            // Keep local saves available even when network sync fails.
        }
    }

    func toggle(_ recipe: DiscoverRecipeCardData) {
        let shouldSave = !isSaved(recipe)

        if shouldSave {
            savedRecipes.removeAll { $0.id == recipe.id }
            savedRecipes.insert(recipe, at: 0)
            toastCenter.showSavedRecipe(
                title: recipe.title,
                thumbnailURLString: recipe.imageURLString ?? recipe.heroImageURLString
            )
        } else {
            savedRecipes.removeAll { $0.id == recipe.id }
        }
        persist()

        guard let userID = activeUserID else { return }

        Task(priority: .utility) {
            do {
                if shouldSave {
                    try await SupabaseSavedRecipesService.shared.upsertSavedRecipes(
                        userID: userID,
                        recipes: [recipe]
                    )
                } else {
                    try await SupabaseSavedRecipesService.shared.deleteSavedRecipe(
                        userID: userID,
                        recipeID: recipe.id
                    )
                }
            } catch {
                // Local persistence remains the source of truth when sync fails.
            }
        }
    }

    func saveImportedRecipe(_ recipe: DiscoverRecipeCardData, showToast: Bool = true) {
        savedRecipes.removeAll { $0.id == recipe.id }
        savedRecipes.insert(recipe, at: 0)
        persist()

        if showToast {
            toastCenter.showSavedRecipe(
                title: recipe.title,
                thumbnailURLString: recipe.imageURLString ?? recipe.heroImageURLString
            )
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(savedRecipes) {
            UserDefaults.standard.set(data, forKey: storageKey(for: activeUserID))
        }
    }

    private func load(for userID: String?) {
        let defaults = UserDefaults.standard
        let primaryKey = storageKey(for: userID)
        let fallbackKey = userID == nil ? legacyKey : nil

        let data = defaults.data(forKey: primaryKey)
            ?? fallbackKey.flatMap { defaults.data(forKey: $0) }

        guard let data,
              let decoded = try? JSONDecoder().decode([DiscoverRecipeCardData].self, from: data)
        else {
            savedRecipes = []
            return
        }

        savedRecipes = deduplicated(decoded)

        if defaults.data(forKey: primaryKey) == nil {
            defaults.set(data, forKey: primaryKey)
        }
    }

    private func storageKey(for userID: String?) -> String {
        "\(keyPrefix)-\(userID ?? "guest")"
    }

    private func merge(local: [DiscoverRecipeCardData], remote: [DiscoverRecipeCardData]) -> [DiscoverRecipeCardData] {
        deduplicated(local + remote)
    }

    private func deduplicated(_ recipes: [DiscoverRecipeCardData]) -> [DiscoverRecipeCardData] {
        var seen = Set<String>()
        return recipes.filter { recipe in
            seen.insert(recipe.id).inserted
        }
    }
}

private struct MealPlannerShellView: View {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var store: MealPlanningAppStore
    @ObservedObject private var toastCenter: AppToastCenter
    @StateObject private var sharedImportInbox = SharedRecipeImportInboxStore()
    @StateObject private var recipeReviewQueue = RecipeImportReviewQueueStore()
    @StateObject private var savedStore: SavedRecipesStore
    @State private var selectedTab: AppTab = .prep
    @State private var discoverSearchText = ""
    @State private var cookbookSearchText = ""
    @State private var presentedRecipe: PresentedRecipeDetail?
    @State private var focusedCartRecipeID: String?
    @State private var requestedCookbookCycleID: String?
    @State private var isProcessingSharedImports = false

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
                    .environmentObject(savedStore)
                    .environmentObject(sharedImportInbox)
                    .transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.98)), removal: .opacity))
            }
            .background(OunjePalette.background.ignoresSafeArea())
            .overlay(alignment: .top) {
                if let toast = toastCenter.toast {
                    AppToastBanner(toast: toast)
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .allowsHitTesting(false)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                BottomNavigationDock(
                    selectedTab: $selectedTab,
                    searchText: activeSearchBinding,
                    searchPlaceholder: activeSearchPlaceholder,
                    safeAreaBottom: proxy.safeAreaInsets.bottom
                )
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .task(id: store.authSession?.userID ?? "signed-out") {
            await savedStore.bootstrap(authSession: store.authSession)
        }
        .task(id: "\(store.authSession?.userID ?? "signed-out")::\(store.isOnboarded)::\(store.profile?.trimmedPreferredName ?? "no-profile")") {
            await store.ensureFreshPlanIfNeeded()
        }
        .task(id: "shared-import::\(store.authSession?.userID ?? "signed-out")") {
            await processPendingSharedImports(scope: .queued)
        }
        .task(id: "shared-import-inbox::\(store.authSession?.userID ?? "signed-out")") {
            await sharedImportInbox.refresh()
        }
        .task(id: "recipe-review-queue::\(store.authSession?.userID ?? "signed-out")") {
            await recipeReviewQueue.refresh(userID: store.authSession?.userID)
            await sharedImportInbox.reconcileCompletedImports(recipeReviewQueue.completedItems)
        }
        .onOpenURL { url in
            guard SharedRecipeImportInbox.isShareImportURL(url) else { return }
            Task {
                await processPendingSharedImports(scope: .queued)
            }
        }
        .onChange(of: scenePhase) { phase in
            guard phase == .active else { return }
            Task {
                await processPendingSharedImports(scope: .queued)
            }
        }
        .onChange(of: selectedTab) { newTab in
            if newTab != .discover {
                discoverSearchText = ""
            }
        }
        .fullScreenCover(item: $presentedRecipe) { presentedRecipe in
            RecipeDetailExperienceView(
                presentedRecipe: presentedRecipe,
                onOpenCart: {
                    focusedCartRecipeID = presentedRecipe.plannedRecipe?.recipe.id ?? presentedRecipe.recipeCard.id
                    selectedTab = .cart
                },
                toastCenter: toastCenter
            )
            .environmentObject(savedStore)
            .background(OunjePalette.background.ignoresSafeArea())
            .preferredColorScheme(.dark)
        }
    }

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .prep:
            PrepTabView(
                selectedTab: $selectedTab,
                requestedCookbookCycleID: $requestedCookbookCycleID,
                onSelectRecipe: { plannedRecipe in
                    presentedRecipe = PresentedRecipeDetail(plannedRecipe: plannedRecipe)
                }
            )
        case .discover:
            DiscoverTabView(
                selectedTab: $selectedTab,
                searchText: $discoverSearchText,
                onSelectRecipe: { recipe in
                    presentedRecipe = PresentedRecipeDetail(recipeCard: recipe)
                }
            )
        case .cookbook:
                CookbookTabView(
                    selectedTab: $selectedTab,
                    searchText: $cookbookSearchText,
                    requestedCycleID: $requestedCookbookCycleID,
                    sharedImportInbox: sharedImportInbox,
                    recipeReviewQueue: recipeReviewQueue,
                    toastCenter: toastCenter,
                    onRefreshSharedImports: {
                        Task {
                            await refreshSharedImportState()
                        }
                    },
                    onRetryFailedSharedImports: {
                        Task {
                            await processPendingSharedImports(scope: .failed)
                            await refreshSharedImportState()
                        }
                    },
                    onSelectRecipe: { recipe in
                        presentedRecipe = PresentedRecipeDetail(recipeCard: recipe)
                    }
                )
        case .cart:
            CartTabView(selectedTab: $selectedTab, focusedRecipeID: $focusedCartRecipeID)
        case .profile:
            ProfileTabView()
        }
    }

    private var activeSearchBinding: Binding<String>? {
        switch selectedTab {
        case .prep:
            return nil
        case .discover:
            return nil
        case .cookbook:
            return nil
        case .cart:
            return nil
        case .profile:
            return nil
        }
    }

    private var activeSearchPlaceholder: String? {
        switch selectedTab {
        case .prep:
            return nil
        case .discover:
            return nil
        case .cookbook:
            return nil
        case .cart:
            return nil
        case .profile:
            return nil
        }
    }

    @MainActor
    private func refreshSharedImportState() async {
        await sharedImportInbox.refresh()
        await recipeReviewQueue.refresh(userID: store.authSession?.userID)
        await sharedImportInbox.reconcileCompletedImports(recipeReviewQueue.completedItems)
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
            do {
                var processingEnvelope = envelope
                let nextAttemptCount = (processingEnvelope.attemptCount ?? 0) + 1
                processingEnvelope = SharedRecipeImportEnvelope(
                    id: processingEnvelope.id,
                    createdAt: processingEnvelope.createdAt,
                    targetState: processingEnvelope.targetState,
                    sourceText: processingEnvelope.sourceText,
                    sourceURLString: processingEnvelope.sourceURLString,
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

                let attachments = try await sharedImportAttachmentPayloads(from: envelope.attachments)
                let response = try await RecipeImportAPIService.shared.importRecipe(
                    userID: userID,
                    accessToken: store.authSession?.accessToken,
                    sourceURL: envelope.sourceURLString?.trimmingCharacters(in: .whitespacesAndNewlines),
                    sourceText: envelope.resolvedSourceText,
                    targetState: envelope.targetState,
                    attachments: attachments
                )

                if let importedRecipe = response.recipe {
                    savedStore.saveImportedRecipe(importedRecipe, showToast: false)
                }
                NotificationCenter.default.post(name: .recipeImportReviewQueueNeedsRefresh, object: nil)

                if let detail = response.recipeDetail, envelope.targetState == "prepped" {
                    await store.updateLatestPlan(with: importedRecipePlanModel(from: detail), servings: detail.displayServings)
                    selectedTab = .prep
                    toastCenter.show(
                        title: "Added to next prep",
                        subtitle: detail.title,
                        systemImage: "sparkles",
                        thumbnailURLString: detail.discoverCardImageURLString ?? detail.heroImageURLString ?? detail.imageURL?.absoluteString
                    )
                    try? SharedRecipeImportInbox.delete(envelopeID: envelope.id)
                } else if response.job.status == "queued" || response.recipe == nil {
                    let queuedEnvelope = SharedRecipeImportEnvelope(
                        id: envelope.id,
                        createdAt: envelope.createdAt,
                        targetState: envelope.targetState,
                        sourceText: envelope.sourceText,
                        sourceURLString: envelope.sourceURLString,
                        sourceApp: envelope.sourceApp,
                        attachments: envelope.attachments,
                        processingState: "processing",
                        attemptCount: processingEnvelope.attemptCount,
                        lastAttemptAt: Date(),
                        lastError: nil,
                        updatedAt: Date()
                    )
                    try? SharedRecipeImportInbox.update(queuedEnvelope)
                    toastCenter.show(
                        title: "Import queued",
                        subtitle: envelope.resolvedSourceText.isEmpty ? "Ounje is pulling your recipe in now." : envelope.resolvedSourceText,
                        systemImage: "tray.and.arrow.down.fill"
                    )
                } else if response.job.reviewState == "draft" {
                    selectedTab = .cookbook
                    toastCenter.show(
                        title: "Saved as draft",
                        subtitle: response.recipe?.title ?? "Imported recipe",
                        systemImage: "doc.badge.gearshape",
                        thumbnailURLString: response.recipe?.imageURL?.absoluteString
                    )
                    try? SharedRecipeImportInbox.delete(envelopeID: envelope.id)
                } else if response.job.reviewState == "needs_review" {
                    selectedTab = .cookbook
                    toastCenter.show(
                        title: "Saved with notes",
                        subtitle: response.recipe?.title ?? "Imported recipe",
                        systemImage: "bookmark.fill",
                        thumbnailURLString: response.recipe?.imageURL?.absoluteString
                    )
                    try? SharedRecipeImportInbox.delete(envelopeID: envelope.id)
                } else if let recipe = response.recipe {
                    selectedTab = .cookbook
                    toastCenter.show(
                        title: "Saved",
                        subtitle: recipe.title,
                        systemImage: "bookmark.fill",
                        thumbnailURLString: recipe.imageURL?.absoluteString
                    )
                    try? SharedRecipeImportInbox.delete(envelopeID: envelope.id)
                }

                await sharedImportInbox.refresh()
                NotificationCenter.default.post(name: .recipeImportReviewQueueNeedsRefresh, object: nil)
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
                    targetState: envelope.targetState,
                    sourceText: envelope.sourceText,
                    sourceURLString: envelope.sourceURLString,
                    sourceApp: envelope.sourceApp,
                    attachments: envelope.attachments,
                    processingState: "failed",
                    attemptCount: (envelope.attemptCount ?? 0) + 1,
                    lastAttemptAt: Date(),
                    lastError: errorMessage,
                    updatedAt: Date()
                )
                try? SharedRecipeImportInbox.update(failedEnvelope)
                await sharedImportInbox.refresh()
                NotificationCenter.default.post(name: .recipeImportReviewQueueNeedsRefresh, object: nil)
                toastCenter.show(
                    title: "Couldn’t import share",
                    subtitle: errorMessage,
                    systemImage: "exclamationmark.circle.fill"
                )
            }
        }
    }
}

private struct DiscoverTabView: View {
    @EnvironmentObject private var store: MealPlanningAppStore
    @Binding var selectedTab: AppTab
    @Binding var searchText: String
    let onSelectRecipe: (DiscoverRecipeCardData) -> Void
    @StateObject private var viewModel = DiscoverRecipesViewModel()
    @StateObject private var environmentModel = DiscoverEnvironmentViewModel()
    @State private var hasAppearedOnce = false
    @State private var searchRefreshTask: Task<Void, Never>?

    private let recipeColumns = [
        GridItem(.flexible(), spacing: 16, alignment: .top),
        GridItem(.flexible(), spacing: 16, alignment: .top)
    ]

    private var filters: [String] {
        viewModel.filters
    }

    private var filteredRecipes: [DiscoverRecipeCardData] {
        viewModel.recipes
    }

    private var greetingLine: String {
        let name = store.profile?.trimmedPreferredName
        if let name, !name.isEmpty {
            return "Welcome back, \(name)."
        }
        return "Welcome back."
    }

    private var dateLine: String {
        Date.now.formatted(.dateTime.weekday(.wide).month(.wide).day())
    }

    private var mealPrompt: String {
        let hour = Calendar.current.component(.hour, from: .now)
        switch hour {
        case 5..<11:
            return "What are we making for breakfast?"
        case 11..<16:
            return "What are we making for lunch?"
        case 16..<22:
            return "What are we making for dinner?"
        default:
            return "What are we prepping next?"
        }
    }

    private var shortcutCards: [DiscoverShortcut] {
        [
            DiscoverShortcut(
                title: "Your profile",
                subtitle: "Preferences, budget, and guardrails",
                symbolName: "person.crop.circle",
                accent: OunjePalette.accent,
                action: { selectedTab = .profile }
            ),
            DiscoverShortcut(
                title: "Cookbook",
                subtitle: "Browse saved and scouted recipes",
                symbolName: "fork.knife",
                accent: Color(hex: "7A7DFF"),
                action: { selectedTab = .cookbook }
            ),
            DiscoverShortcut(
                title: "Cart",
                subtitle: "Review ingredients and checkout paths",
                symbolName: "calendar",
                accent: Color(hex: "56D7C8"),
                action: { selectedTab = .cart }
            ),
            DiscoverShortcut(
                title: "Prep",
                subtitle: "See the next cycle and meal lineup",
                symbolName: "wand.and.stars",
                accent: Color(hex: "F4B15E"),
                action: { selectedTab = .prep }
            )
        ]
    }

    private var visibleRecipes: [DiscoverRecipeCardData] {
        filteredRecipes
    }

    private var normalizedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isSearching: Bool {
        !normalizedSearchText.isEmpty
    }

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Compact header
                    VStack(alignment: .leading, spacing: 3) {
                        BiroScriptDisplayText("Discover", size: 31, color: OunjePalette.primaryText)
                        Text("Find your next meal")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(OunjePalette.secondaryText)
                    }

                    CompactDiscoverSearchField(
                        text: $searchText,
                        isLoading: viewModel.isLoading && isSearching
                    )

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .firstTextBaseline, spacing: 26) {
                            ForEach(filters, id: \.self) { filter in
                                DiscoverPresetTextButton(
                                    title: filter,
                                    isSelected: viewModel.selectedFilter == filter
                                ) {
                                    withAnimation(.spring(response: 0.3, dampingFraction: 0.84)) {
                                        viewModel.selectFilter(filter, isSearching: isSearching)
                                    }
                                }
                            }
                        }
                        .padding(.trailing, 10)
                        .padding(.top, 2)
                        .padding(.bottom, 4)
                    }

                    if let errorMessage = viewModel.errorMessage {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Recipe feed unavailable")
                                .biroHeaderFont(18)
                                .foregroundStyle(OunjePalette.primaryText)
                            Text(errorMessage)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(OunjePalette.secondaryText)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 6)
                    } else if !viewModel.hasResolvedInitialLoad || (viewModel.isLoading && isSearching) || (viewModel.isLoading && viewModel.recipes.isEmpty) || (viewModel.isTransitioningFeed && !isSearching) {
                        LazyVGrid(columns: recipeColumns, spacing: 14) {
                            ForEach(0..<6, id: \.self) { _ in
                                DiscoverRecipeCardLoadingPlaceholder()
                            }
                        }
                    } else if visibleRecipes.isEmpty {
                        RecipesEmptyState(
                            title: "No recipes matched",
                            detail: "Try a different keyword or category.",
                            symbolName: "fork.knife"
                        )
                    } else {
                        LazyVGrid(columns: recipeColumns, spacing: 16) {
                            ForEach(visibleRecipes) { recipe in
                                DiscoverRemoteRecipeCard(recipe: recipe) {
                                    onSelectRecipe(recipe)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, OunjeLayout.screenHorizontalPadding)
                .padding(.top, 14)
                .padding(.bottom, 140)
            }
            .scrollIndicators(.hidden)
        }
        .task(id: discoverFeedKey) {
            let initialContext = environmentModel.feedContext
            async let environmentRefresh: Void = environmentModel.refresh(profile: store.profile)
            await viewModel.loadIfNeeded(profile: store.profile, query: searchText, feedContext: initialContext)
            await environmentRefresh
            await viewModel.loadIfNeeded(profile: store.profile, query: searchText, feedContext: environmentModel.feedContext)
        }
        .onChange(of: searchText) { newValue in
            searchRefreshTask?.cancel()

            let normalized = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty else {
                Task {
                    await viewModel.forceReload(profile: store.profile, query: "", feedContext: environmentModel.feedContext)
                }
                return
            }

            searchRefreshTask = Task {
                try? await Task.sleep(nanoseconds: 240_000_000)
                guard !Task.isCancelled else { return }
                await viewModel.refresh(profile: store.profile, query: normalized, feedContext: environmentModel.feedContext)
            }
        }
        .onAppear {
            if normalizedSearchText.isEmpty {
                viewModel.selectedFilter = "All"
            }

            guard normalizedSearchText.isEmpty else { return }
            guard hasAppearedOnce else {
                hasAppearedOnce = true
                return
            }
            guard viewModel.selectedFilter == "All", !viewModel.recipes.isEmpty else { return }
            Task {
                await viewModel.rotateBaseFeedIfNeeded(profile: store.profile, feedContext: environmentModel.feedContext)
            }
            Task {
                if viewModel.recipes.isEmpty || viewModel.errorMessage != nil {
                    await viewModel.forceReload(profile: store.profile, query: searchText, feedContext: environmentModel.feedContext)
                }
            }
        }
    }

    private var discoverFeedKey: String {
        let cuisines = store.profile?.preferredCuisines.map(\.rawValue).joined(separator: ",") ?? ""
        let foods = store.profile?.favoriteFoods.joined(separator: ",") ?? ""
        let flavors = store.profile?.favoriteFlavors.joined(separator: ",") ?? ""
        let dietary = store.profile?.dietaryPatterns.joined(separator: ",") ?? ""
        let goals = store.profile?.mealPrepGoals.joined(separator: ",") ?? ""
        let address = store.profile?.deliveryAddress
        let environmentKey = [
            address?.city ?? "",
            address?.region ?? "",
            address?.postalCode ?? "",
            Date.now.formatted(.dateTime.year().month().day().hour())
        ].joined(separator: "|")
        return "\(cuisines)|\(foods)|\(flavors)|\(dietary)|\(goals)|\(viewModel.selectedFilter)|\(environmentKey)"
    }
}

private struct DiscoverInlineLoadingState: View {
    var body: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
                .tint(OunjePalette.softCream)
        }
        .padding(.horizontal, 4)
    }
}

private struct CompactDiscoverSearchField: View {
    @Binding var text: String
    let isLoading: Bool

    @FocusState private var isFocused: Bool
    @State private var animatedPlaceholder = ""
    @State private var animationTask: Task<Void, Never>?

    private let placeholderOptions = [
        "soups to fix a flu",
        "summer desserts for a cookout",
        "spicy food for a Nigerian potluck",
        "high-protein lunch meal prep",
        "comfort food under 30 minutes",
        "easy dinners for a rainy night",
        "crispy salmon rice bowls",
        "healthy snacks that actually taste good",
        "make-ahead brunch for friends",
        "cheap dinners with a lot of flavor",
        "something fresh with shrimp",
        "weeknight pasta that feels fancy"
    ]

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(OunjePalette.secondaryText)

            ZStack(alignment: .leading) {
                if text.isEmpty && !animatedPlaceholder.isEmpty {
                    Text(animatedPlaceholder)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(OunjePalette.secondaryText)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }

                TextField("", text: $text)
                    .textInputAutocapitalization(.sentences)
                    .disableAutocorrection(true)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(OunjePalette.primaryText)
                    .focused($isFocused)
            }

            if isLoading {
                ProgressView()
                    .controlSize(.small)
                    .tint(OunjePalette.softCream)
            } else if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(OunjePalette.secondaryText.opacity(0.75))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(OunjePalette.surface.opacity(0.96))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(OunjePalette.stroke, lineWidth: 1)
                )
        )
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
        guard !placeholderOptions.isEmpty else { return }

        animationTask?.cancel()
        animationTask = Task {
            var index = 0

            while !Task.isCancelled {
                let example = placeholderOptions[index % placeholderOptions.count]

                await MainActor.run {
                    animatedPlaceholder = ""
                }

                for character in example {
                    guard !Task.isCancelled else { return }
                    guard await shouldKeepAnimating else { return }

                    await MainActor.run {
                        animatedPlaceholder.append(character)
                    }
                    try? await Task.sleep(nanoseconds: 65_000_000)
                }

                try? await Task.sleep(nanoseconds: 900_000_000)

                while !(await MainActor.run { animatedPlaceholder.isEmpty }) {
                    guard !Task.isCancelled else { return }
                    guard await shouldKeepAnimating else { return }

                    await MainActor.run {
                        _ = animatedPlaceholder.popLast()
                    }
                    try? await Task.sleep(nanoseconds: 38_000_000)
                }

                try? await Task.sleep(nanoseconds: 220_000_000)
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

private enum CookbookSection: String, CaseIterable, Identifiable {
    case prepped
    case saved

    var id: String { rawValue }

    var title: String {
        switch self {
        case .saved: return "Saved"
        case .prepped: return "Prepped"
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
    @ObservedObject var sharedImportInbox: SharedRecipeImportInboxStore
    @ObservedObject var recipeReviewQueue: RecipeImportReviewQueueStore
    @ObservedObject var toastCenter: AppToastCenter
    let onRefreshSharedImports: () -> Void
    let onRetryFailedSharedImports: () -> Void
    let onSelectRecipe: (DiscoverRecipeCardData) -> Void

    @EnvironmentObject private var savedStore: SavedRecipesStore
    @EnvironmentObject private var store: MealPlanningAppStore

    @State private var selectedSection: CookbookSection = .prepped
    @State private var selectedFilter: String = "All"
    @State private var isComposerPresented = false
    @State private var composerContext: CookbookComposerContext = .saved
    @State private var selectedCycle: CookbookPreppedCycle?
    @State private var isSavedSearchPresented = false
    @State private var isImportQueuePresented = false
    @State private var isRecipeReviewQueuePresented = false
    @State private var keyboardHeight: CGFloat = 0

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

    private var showsSavedSearch: Bool {
        savedStore.savedRecipes.count >= 5
    }

    private var upcomingCycle: CookbookPreppedCycle? {
        guard let latestPlan = store.latestPlan, !latestPlan.recipes.isEmpty else { return nil }
        return CookbookPreppedCycle(
            id: latestPlan.id.uuidString,
            title: "Next cycle",
            detail: latestPlan.periodStart.formatted(.dateTime.weekday(.wide).month(.wide).day()),
            recipes: latestPlan.recipes.map(DiscoverRecipeCardData.init(preppedRecipe:))
        )
    }

    private var previousCycles: [CookbookPreppedCycle] {
        let latestID = store.latestPlan?.id
        let historicalPlans = store.planHistory.filter { $0.id != latestID }
        return historicalPlans.compactMap { plan in
            guard !plan.recipes.isEmpty else { return nil }
            return CookbookPreppedCycle(
                id: plan.id.uuidString,
                title: plan.periodStart.formatted(.dateTime.month(.wide).day()),
                detail: "\(plan.recipes.count) recipes",
                recipes: plan.recipes.map(DiscoverRecipeCardData.init(preppedRecipe:))
            )
        }
    }

    private var sectionTabs: [CookbookSectionTabItem] {
        [
            CookbookSectionTabItem(section: .prepped),
            CookbookSectionTabItem(section: .saved)
        ]
    }

    private var keyboardLift: CGFloat {
        max(0, keyboardHeight - 8)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
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
                        isImportQueuePresented = true
                    } label: {
                        ZStack(alignment: .topTrailing) {
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

                            if sharedImportInbox.badgeCount > 0 {
                                Text("\(sharedImportInbox.badgeCount)")
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
                    }
                    .buttonStyle(.plain)

                    Button {
                        composerContext = selectedSection == .prepped ? .prepped : .saved
                        isComposerPresented = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 16, weight: .bold))
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
                    }
                    .buttonStyle(.plain)
                }

                CookbookSectionTabs(
                    selection: $selectedSection,
                    tabs: sectionTabs
                )

                switch selectedSection {
                case .prepped:
                    preppedSection
                case .saved:
                    savedSection
                }
            }
            .padding(.horizontal, OunjeLayout.screenHorizontalPadding)
            .padding(.top, 14)
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
        .background(OunjePalette.background.ignoresSafeArea())
        .overlay {
            if selectedSection == .saved, isSavedSearchPresented {
                Color.black.opacity(0.001)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.9)) {
                            isSavedSearchPresented = false
                        }
                    }
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if selectedSection == .saved,
               showsSavedSearch,
               !isSavedSearchPresented,
               searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                FloatingSavedSearchButton(
                    isActive: false
                ) {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.88)) {
                        isSavedSearchPresented = true
                    }
                }
                .padding(.trailing, 16)
                .padding(.bottom, 18)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if selectedSection == .saved,
               showsSavedSearch,
               isSavedSearchPresented || !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                SavedSearchBottomDock(
                    text: $searchText,
                    placeholder: "Search saved recipes",
                    isPresented: $isSavedSearchPresented
                )
                .padding(.horizontal, 16)
                .padding(.bottom, 12 + keyboardLift)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .task(id: selectedSection == .saved ? (store.authSession?.userID ?? "guest") : "cookbook-idle") {
            guard selectedSection == .saved else { return }
            await savedStore.bootstrap(authSession: store.authSession)
        }
        .task(id: "recipe-review-queue::\(store.authSession?.userID ?? "signed-out")") {
            await recipeReviewQueue.refresh(userID: store.authSession?.userID)
        }
        .onReceive(NotificationCenter.default.publisher(for: .recipeImportReviewQueueNeedsRefresh)) { _ in
            Task {
                await recipeReviewQueue.refresh(userID: store.authSession?.userID)
                await sharedImportInbox.reconcileCompletedImports(recipeReviewQueue.completedItems)
            }
        }
        .sheet(isPresented: $isComposerPresented) {
            DiscoverComposerSheet(context: composerContext)
                .presentationDetents([.fraction(0.5)])
                .presentationDragIndicator(.hidden)
        }
        .sheet(isPresented: $isImportQueuePresented) {
            SharedRecipeImportQueueSheet(
                items: sharedImportInbox.envelopes,
                historyStore: recipeReviewQueue,
                onRefreshAll: {
                    onRefreshSharedImports()
                    isImportQueuePresented = false
                },
                onRetryFailed: {
                    onRetryFailedSharedImports()
                    isImportQueuePresented = false
                }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.hidden)
        }
        .sheet(isPresented: $isRecipeReviewQueuePresented) {
            RecipeImportReviewQueueSheet(
                items: recipeReviewQueue.items
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
        .onAppear {
            openRequestedCycleIfNeeded()
            isSavedSearchPresented = !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        .onChange(of: requestedCycleID) { _ in
            openRequestedCycleIfNeeded()
        }
        .onChange(of: selectedSection) { section in
            if section != .saved && searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                isSavedSearchPresented = false
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { notification in
            guard let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
            let screenHeight = UIScreen.main.bounds.height
            let overlap = max(0, screenHeight - frame.minY)
            withAnimation(.easeOut(duration: 0.22)) {
                keyboardHeight = overlap
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            withAnimation(.easeOut(duration: 0.2)) {
                keyboardHeight = 0
            }
        }
    }

    @ViewBuilder
    private var savedSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            if recipeReviewQueue.badgeCount > 0 {
                RecipeImportReviewQueueBanner(
                    draftCount: recipeReviewQueue.draftCount,
                    needsReviewCount: recipeReviewQueue.needsReviewCount,
                    totalCount: recipeReviewQueue.badgeCount,
                    onOpen: {
                        isRecipeReviewQueuePresented = true
                    }
                )
            }

            if showsSavedSearch {
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
            }

            if filteredRecipes.isEmpty {
                CookbookSavedEmptyState(
                    hasSavedRecipes: !savedStore.savedRecipes.isEmpty,
                    onBrowseDiscover: { selectedTab = .discover },
                    onAddRecipe: {
                        composerContext = .saved
                        isComposerPresented = true
                    }
                )
            } else {
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(filteredRecipes) { recipe in
                        DiscoverRemoteRecipeCard(recipe: recipe) {
                            onSelectRecipe(recipe)
                        }
                    }
                }
            }
        }
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
}

private enum SharedRecipeImportQueueTab: String, CaseIterable, Identifiable {
    case queued = "Queued"
    case failed = "Failed"
    case completed = "Completed"

    var id: String { rawValue }
}

private struct SharedRecipeImportQueueSheet: View {
    let items: [SharedRecipeImportEnvelope]
    @ObservedObject var historyStore: RecipeImportReviewQueueStore
    let onRefreshAll: () -> Void
    let onRetryFailed: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selectedTab: SharedRecipeImportQueueTab = .queued

    private var queuedItems: [SharedRecipeImportEnvelope] {
        items.filter { !$0.isRetryNeeded }
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
        selectedTab != .completed
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
            if !queuedItems.isEmpty {
                selectedTab = .queued
            } else if !failedItems.isEmpty {
                selectedTab = .failed
            } else if !historyStore.completedItems.isEmpty {
                selectedTab = .completed
            }
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
                            .font(.system(size: 14, weight: .semibold))
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
                        SharedRecipeImportQueueRow(item: item)
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
                        SharedRecipeImportQueueRow(item: item)
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
                    ForEach(historyStore.completedItems) { item in
                        RecipeImportCompletedRow(item: item)
                    }
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
                .foregroundStyle(OunjePalette.primaryText)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(OunjePalette.accent)
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

private struct RecipeImportReviewQueueBanner: View {
    let draftCount: Int
    let needsReviewCount: Int
    let totalCount: Int
    let onOpen: () -> Void

    private var subtitle: String {
        var parts: [String] = []
        if draftCount > 0 {
            parts.append("\(draftCount) draft\(draftCount == 1 ? "" : "s")")
        }
        if needsReviewCount > 0 {
            parts.append("\(needsReviewCount) needs review")
        }
        return parts.isEmpty ? "Imports waiting for a quick check." : parts.joined(separator: " • ")
    }

    var body: some View {
        Button(action: onOpen) {
            HStack(alignment: .center, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(OunjePalette.surface)
                        .frame(width: 44, height: 44)
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(OunjePalette.primaryText)
                }

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text("Recipe review queue")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(OunjePalette.primaryText)
                        Text("\(totalCount)")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(OunjePalette.background)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(OunjePalette.accent)
                            )
                    }

                    Text(subtitle)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(OunjePalette.secondaryText)
                        .lineLimit(2)
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(OunjePalette.secondaryText)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(OunjePalette.surface.opacity(0.95))
                    .overlay(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .stroke(OunjePalette.stroke, lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
    }
}

private struct RecipeImportReviewQueueSheet: View {
    let items: [RecipeImportReviewItem]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Recipe review queue")
                            .biroHeaderFont(30)
                            .foregroundStyle(OunjePalette.primaryText)
                        Text("Draft imports are usable, but they still need a quick check before they feel finished.")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(OunjePalette.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if items.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Nothing waiting")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(OunjePalette.primaryText)
                            Text("Short-form imports that need attention will show up here.")
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
                    } else {
                        VStack(spacing: 12) {
                            ForEach(items) { item in
                                RecipeImportReviewRow(item: item)
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
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(OunjePalette.secondaryText)
                }
            }
        }
    }
}

private struct RecipeImportReviewRow: View {
    let item: RecipeImportReviewItem

    private var sourceLine: String {
        let parts = [item.sourceProvenance?.platform, item.sourceProvenance?.sourceType]
            .compactMap { value -> String? in
                guard let value else { return nil }
                let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
                return normalized.isEmpty ? nil : normalized.capitalized
            }
        return parts.isEmpty ? "Imported draft" : parts.joined(separator: " • ")
    }

    private var stateText: String {
        switch item.reviewState {
        case "draft":
            return "Draft"
        case "needs_review":
            return "Needs review"
        default:
            return item.reviewState.capitalized
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(OunjePalette.surface)
                        .frame(width: 42, height: 42)

                    Image(systemName: item.reviewState == "draft" ? "doc.badge.gearshape" : "exclamationmark.triangle.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(item.reviewState == "draft" ? OunjePalette.accent : Color.orange)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(item.title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(OunjePalette.primaryText)
                        .lineLimit(2)
                    Text(sourceLine)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(OunjePalette.secondaryText)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                Text(stateText)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(OunjePalette.background)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(
                        Capsule(style: .continuous)
                            .fill(item.reviewState == "draft" ? OunjePalette.accent : Color.orange)
                    )
            }

            if let note = item.reviewReason, !note.isEmpty {
                Text(note)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(OunjePalette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
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

private struct SharedRecipeImportQueueRow: View {
    let item: SharedRecipeImportEnvelope

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

            Text(item.reviewState == "needs_review" ? "Needs review" : "Done")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(OunjePalette.background)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    Capsule(style: .continuous)
                        .fill(item.reviewState == "needs_review" ? Color.orange : OunjePalette.accent)
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

private struct PrepTabView: View {
    @EnvironmentObject private var store: MealPlanningAppStore
    @Binding var selectedTab: AppTab
    @Binding var requestedCookbookCycleID: String?
    let onSelectRecipe: (PlannedRecipe) -> Void
    @State private var isRegenerationSheetPresented = false
    @State private var selectedRegenerationFocus: PrepRegenerationFocus = .balanced
    @State private var prepLinkPulse = false

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    PrepTrackerCard(store: store)

                    VStack(alignment: .leading, spacing: 16) {
                        HStack(alignment: .center, spacing: 12) {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text("Meals in")
                                    .biroHeaderFont(26)
                                    .foregroundStyle(OunjePalette.primaryText)

                                Button {
                                    requestedCookbookCycleID = store.latestPlan?.id.uuidString
                                    selectedTab = .cookbook
                                } label: {
                                        HStack(alignment: .center, spacing: 5) {
                                            Text("this prep")
                                                .sleeDisplayFont(22)
                                                .foregroundStyle(prepLinkPulse ? OunjePalette.softCream : OunjePalette.softCream.opacity(0.96))

                                            Image(systemName: "pencil")
                                                .font(.system(size: 12, weight: .semibold))
                                                .foregroundStyle(OunjePalette.softCream.opacity(prepLinkPulse ? 1 : 0.88))
                                                .scaleEffect(prepLinkPulse ? 1.08 : 0.98)
                                                .rotationEffect(.degrees(prepLinkPulse ? 6 : -3))
                                                .offset(y: prepLinkPulse ? -1 : 0)
                                                .shadow(color: .black.opacity(0.22), radius: 1, y: 1)
                                        }
                                    .padding(.horizontal, 2)
                                    .padding(.vertical, 1)
                                    .scaleEffect(prepLinkPulse ? 1.03 : 0.985)
                                    .shadow(color: OunjePalette.accent.opacity(prepLinkPulse ? 0.16 : 0.08), radius: prepLinkPulse ? 6 : 3, x: 0, y: 2)
                                }
                                .buttonStyle(.plain)
                                .contentShape(Rectangle())
                                .onAppear {
                                    guard !prepLinkPulse else { return }
                                    withAnimation(.easeInOut(duration: 1.3).repeatForever(autoreverses: true)) {
                                        prepLinkPulse = true
                                    }
                                }
                            }

                            Spacer(minLength: 12)

                            Button {
                                selectedRegenerationFocus = .balanced
                                isRegenerationSheetPresented = true
                            } label: {
                                Group {
                                    if store.isGenerating {
                                        ProgressView()
                                            .controlSize(.small)
                                            .tint(OunjePalette.softCream)
                                    } else {
                                        Image(systemName: "wand.and.stars")
                                            .font(.system(size: 18, weight: .semibold))
                                            .foregroundStyle(OunjePalette.primaryText.opacity(0.92))
                                    }
                                }
                                .frame(width: 26, height: 26)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(store.isGenerating || !(store.profile?.isAutomationReady ?? false))
                            .opacity((store.isGenerating || !(store.profile?.isAutomationReady ?? false)) ? 0.65 : 1)
                        }

                        MealsPrepCarousel(
                            plannedRecipes: store.latestPlan?.recipes ?? [],
                            isGenerating: store.isGenerating,
                            onSelectRecipe: onSelectRecipe
                        )
                        .padding(.horizontal, -OunjeLayout.screenHorizontalPadding)
                    }
                    .padding(.top, 4)
                }
                .padding(.horizontal, OunjeLayout.screenHorizontalPadding)
                .padding(.top, 14)
                .padding(.bottom, 12)
            }
            .scrollIndicators(.hidden)
        }
        .background(OunjePalette.background.ignoresSafeArea())
        .sheet(isPresented: $isRegenerationSheetPresented) {
            PrepRegenerationSheet(
                selectedFocus: $selectedRegenerationFocus,
                isGenerating: store.isGenerating,
                onCancel: {
                    isRegenerationSheetPresented = false
                },
                onConfirm: { options in
                    isRegenerationSheetPresented = false
                    Task { await store.regeneratePrepBatch(using: options) }
                }
            )
            .presentationDetents([.fraction(0.78), .large])
            .presentationDragIndicator(.visible)
        }
    }

    private func recipeForSlot(_ index: Int) -> Recipe? {
        guard let recipes = store.latestPlan?.recipes.map(\.recipe), !recipes.isEmpty else { return nil }
        return recipes[index % recipes.count]
    }
}

private struct PrepRegenerationSheet: View {
    @Binding var selectedFocus: PrepRegenerationFocus
    let isGenerating: Bool
    let onCancel: () -> Void
    let onConfirm: (PrepGenerationOptions) -> Void

    var body: some View {
        ZStack {
            OunjePalette.background.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    SleeScriptDisplayText("Generate new prep?", size: 26, color: OunjePalette.primaryText)
                    Text("Pick the direction for the next batch. We’ll still respect your profile, saved meals, and allergy guardrails.")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(OunjePalette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 10) {
                        ForEach(PrepRegenerationFocus.allCases) { focus in
                            Button {
                                selectedFocus = focus
                            } label: {
                                HStack(spacing: 14) {
                                    Image(systemName: focus.systemImageName)
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundStyle(selectedFocus == focus ? OunjePalette.softCream.opacity(0.96) : OunjePalette.softCream.opacity(0.92))
                                        .frame(width: 18)

                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(focus.title)
                                            .sleeDisplayFont(17)
                                            .foregroundStyle(OunjePalette.primaryText)

                                        Text(focus.subtitle)
                                            .font(.system(size: 12.5, weight: .medium))
                                            .foregroundStyle(selectedFocus == focus ? OunjePalette.primaryText.opacity(0.72) : OunjePalette.secondaryText)
                                            .multilineTextAlignment(.leading)
                                            .lineLimit(2)
                                    }

                                    Spacer(minLength: 0)

                                    Image(systemName: selectedFocus == focus ? "checkmark.circle.fill" : "circle")
                                        .font(.system(size: 18, weight: .semibold))
                                        .foregroundStyle(selectedFocus == focus ? OunjePalette.softCream.opacity(0.96) : OunjePalette.secondaryText.opacity(0.72))
                                }
                                .padding(.horizontal, 15)
                                .padding(.vertical, 13)
                                .background(
                                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                                        .fill(
                                            selectedFocus == focus
                                                ? AnyShapeStyle(
                                                    LinearGradient(
                                                        colors: [
                                                            OunjePalette.surface.opacity(0.98),
                                                            OunjePalette.panel.opacity(0.98),
                                                            OunjePalette.accent.opacity(0.34)
                                                        ],
                                                        startPoint: .leading,
                                                        endPoint: .trailing
                                                    )
                                                )
                                                : AnyShapeStyle(OunjePalette.surface.opacity(0.96))
                                        )
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                                        .stroke(
                                            selectedFocus == focus
                                                ? OunjePalette.accent.opacity(0.46)
                                                : OunjePalette.stroke.opacity(0.84),
                                            lineWidth: 1
                                        )
                                )
                                .shadow(
                                    color: selectedFocus == focus ? OunjePalette.accent.opacity(0.12) : .clear,
                                    radius: 14,
                                    x: 0,
                                    y: 8
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.top, 2)
                    .padding(.bottom, 8)
                }

                HStack(spacing: 12) {
                    Button(action: onCancel) {
                        Text("Keep current")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(OunjePalette.primaryText)
                            .frame(maxWidth: .infinity)
                            .frame(height: 54)
                            .background(
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .fill(OunjePalette.surface.opacity(0.94))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .stroke(OunjePalette.stroke.opacity(0.84), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)

                    Button {
                        onConfirm(PrepGenerationOptions(focus: selectedFocus))
                    } label: {
                        Text(isGenerating ? "Generating..." : "Generate prep")
                            .sleeDisplayFont(19)
                            .foregroundStyle(OunjePalette.primaryText)
                            .frame(maxWidth: .infinity)
                            .frame(height: 54)
                            .background(
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .fill(
                                        LinearGradient(
                                            colors: [
                                                OunjePalette.accent.opacity(0.94),
                                                OunjePalette.accent.opacity(0.78)
                                            ],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        )
                                    )
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(isGenerating)
                    .opacity(isGenerating ? 0.72 : 1)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 24)
            .padding(.bottom, 20)
        }
    }
}

private extension PrepRegenerationFocus {
    var title: String {
        switch self {
        case .balanced:
            return "More satisfying"
        case .closerToFavorites:
            return "More like my favorites"
        case .moreVariety:
            return "More imaginative"
        case .lessPrepTime:
            return "Less prep time"
        case .tighterOverlap:
            return "Tighter grocery overlap"
        case .savedRecipeRefresh:
            return "Use more saved meals"
        }
    }

    var subtitle: String {
        switch self {
        case .balanced:
            return "Heartier picks that keep you full for longer."
        case .closerToFavorites:
            return "More of the cuisines and dishes you already love."
        case .moreVariety:
            return "Explore meals you likely would not have picked yourself."
        case .lessPrepTime:
            return "Quicker recipes with a lighter lift."
        case .tighterOverlap:
            return "Reuse more ingredients to keep the cart tighter."
        case .savedRecipeRefresh:
            return "Pull more strongly from saved meals that still fit."
        }
    }

    var systemImageName: String {
        switch self {
        case .balanced:
            return "fork.knife"
        case .closerToFavorites:
            return "heart.text.square"
        case .moreVariety:
            return "sparkles"
        case .lessPrepTime:
            return "timer"
        case .tighterOverlap:
            return "carrot"
        case .savedRecipeRefresh:
            return "bookmark"
        }
    }

    var promptSeed: String {
        switch self {
        case .balanced:
            return "more satisfying, keep the prep filling, and stay grounded in my saved meals"
        case .closerToFavorites:
            return "more like my favorites, lean into the cuisines and flavors I already love"
        case .moreVariety:
            return "more imaginative, explore meals I would not normally pick"
        case .lessPrepTime:
            return "less prep time, keep the meals simpler and faster to make"
        case .tighterOverlap:
            return "tighter grocery overlap, reuse more ingredients across the prep"
        case .savedRecipeRefresh:
            return "use more saved meals, but refresh them so the cycle still feels new"
        }
    }
}

private struct MealsPrepCarousel: View {
    let plannedRecipes: [PlannedRecipe]
    let isGenerating: Bool
    let onSelectRecipe: (PlannedRecipe) -> Void

    var body: some View {
        if isGenerating {
            MealsPrepLoadingCarousel()
        } else if plannedRecipes.isEmpty {
            PrepEmptyState(
                title: "No meals in this prep yet",
                detail: "Generate a fresh cycle and your scheduled meals will show up here.",
                symbolName: "fork.knife.circle"
            )
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(plannedRecipes) { plannedRecipe in
                        MealDeckCard(
                            plannedRecipe: plannedRecipe,
                            onSelect: { onSelectRecipe(plannedRecipe) }
                        )
                            .frame(width: 232)
                    }
                }
                .padding(.horizontal, OunjeLayout.screenHorizontalPadding)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct MealsPrepLoadingCarousel: View {
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 14) {
                ForEach(0..<4, id: \.self) { index in
                    VStack(alignment: .leading, spacing: 14) {
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .fill(OunjePalette.surface.opacity(0.82))
                            .frame(height: 188)
                            .overlay(alignment: .topTrailing) {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(OunjePalette.surface.opacity(0.95))
                                    .frame(width: 26, height: 26)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .stroke(OunjePalette.stroke.opacity(0.64), lineWidth: 1)
                                    )
                                    .padding(10)
                            }

                        VStack(alignment: .leading, spacing: 8) {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(OunjePalette.surface.opacity(0.82))
                                .frame(width: index.isMultiple(of: 2) ? 176 : 152, height: 22)

                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(OunjePalette.surface.opacity(0.82))
                                .frame(width: 104, height: 14)
                        }
                        .padding(.horizontal, 2)
                        .padding(.bottom, 2)
                    }
                    .padding(14)
                    .frame(width: 232, height: 292, alignment: .topLeading)
                    .background(
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        OunjePalette.panel.opacity(0.92),
                                        OunjePalette.surface.opacity(0.78)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .stroke(.white.opacity(0.05), lineWidth: 1)
                    )
                }
            }
            .padding(.horizontal, OunjeLayout.screenHorizontalPadding)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .redacted(reason: .placeholder)
    }
}

private struct PrepEmptyState: View {
    let title: String
    let detail: String
    let symbolName: String

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: symbolName)
                .font(.system(size: 72, weight: .light))
                .foregroundStyle(OunjePalette.secondaryText.opacity(0.42))
                .padding(.top, 24)

            VStack(spacing: 8) {
                Text(title)
                    .biroHeaderFont(20)
                    .foregroundStyle(OunjePalette.primaryText)

                Text(detail)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(OunjePalette.secondaryText)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: 280)
            .padding(.bottom, 6)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 4)
        .padding(.vertical, 8)
    }
}

private struct MealDeckCard: View {
    let plannedRecipe: PlannedRecipe
    let onSelect: () -> Void

    var body: some View {
        DiscoverRemoteRecipeCard(recipe: DiscoverRecipeCardData(preppedRecipe: plannedRecipe), onSelect: onSelect)
    }
}

private struct CookbookPreppedCycle: Identifiable, Hashable {
    let id: String
    let title: String
    let detail: String
    let recipes: [DiscoverRecipeCardData]
}

private struct CookbookCycleGroup: View {
    let title: String?
    var subtitle: String? = nil
    let cycles: [CookbookPreppedCycle]
    var showsRowMetadata: Bool = true
    let onSelectCycle: (CookbookPreppedCycle) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                if let title, !title.isEmpty {
                    BiroScriptDisplayText(title, size: 30, color: OunjePalette.primaryText)
                }

                if let subtitle, !subtitle.isEmpty {
                    BiroScriptDisplayText(subtitle, size: 26, color: OunjePalette.primaryText)
                }
            }

            VStack(spacing: 14) {
                ForEach(cycles) { cycle in
                    CookbookCycleRow(cycle: cycle, showsMetadata: showsRowMetadata) {
                        onSelectCycle(cycle)
                    }
                }
            }
        }
    }
}

private struct CookbookCycleRow: View {
    let cycle: CookbookPreppedCycle
    let showsMetadata: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 12) {
                if showsMetadata {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        VStack(alignment: .leading, spacing: 4) {
                            BiroScriptDisplayText(cycle.title, size: 23, color: OunjePalette.primaryText)
                            Text("\(cycle.detail) · \(cycle.recipes.count) recipes")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(OunjePalette.secondaryText)
                        }

                        Spacer()

                        Image(systemName: "arrow.right")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(OunjePalette.secondaryText.opacity(0.78))
                    }
                }

                ZStack(alignment: .topTrailing) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 14) {
                            ForEach(Array(cycle.recipes.prefix(5))) { recipe in
                                CookbookCyclePreviewCard(recipe: recipe)
                            }
                        }
                        .padding(.trailing, showsMetadata ? 4 : 28)
                    }

                    if !showsMetadata {
                        Image(systemName: "arrow.right")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(OunjePalette.secondaryText.opacity(0.78))
                            .padding(.top, 4)
                    }
                }
            }
            .padding(18)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: 26, style: .continuous)
                        .fill(Color.black.opacity(0.22))

                    DarkBlurView(style: .systemUltraThinMaterialDark)
                        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))

                    RoundedRectangle(cornerRadius: 26, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.035),
                                    Color.black.opacity(0.18)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )

                    RoundedRectangle(cornerRadius: 26, style: .continuous)
                        .stroke(.white.opacity(0.08), lineWidth: 1)
                }
            )
            .shadow(color: .black.opacity(0.22), radius: 20, y: 12)
        }
        .buttonStyle(.plain)
    }
}

private struct CookbookCyclePreviewCard: View {
    let recipe: DiscoverRecipeCardData

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CookbookCyclePlateImage(recipe: recipe)

            Text(recipe.displayTitle)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(OunjePalette.primaryText)
                .lineLimit(2)
                .frame(width: 92, alignment: .leading)
        }
    }
}

private struct CookbookCyclePlateImage: View {
    let recipe: DiscoverRecipeCardData
    @StateObject private var loader = DiscoverRecipeImageLoader()

    var body: some View {
        ZStack {
            if let uiImage = loader.image {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 90, height: 90)
                    .clipShape(Circle())
                    .shadow(color: .black.opacity(0.16), radius: 8, y: 5)
            } else if loader.isLoading {
                ProgressView()
                    .tint(OunjePalette.accent)
            } else {
                Text(recipe.emoji)
                    .font(.system(size: 38))
            }
        }
        .frame(width: 92, height: 92)
        .task(id: recipe.id) {
            await loader.load(from: recipe.imageCandidates)
        }
    }
}

private struct DarkBlurView: UIViewRepresentable {
    let style: UIBlurEffect.Style

    func makeUIView(context: Context) -> UIVisualEffectView {
        UIVisualEffectView(effect: UIBlurEffect(style: style))
    }

    func updateUIView(_ uiView: UIVisualEffectView, context: Context) {
        uiView.effect = UIBlurEffect(style: style)
    }
}

private struct CookbookCyclePage: View {
    let cycle: CookbookPreppedCycle
    @Binding var selectedTab: AppTab
    let toastCenter: AppToastCenter

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: MealPlanningAppStore
    @EnvironmentObject private var savedStore: SavedRecipesStore

    @State private var presentedRecipe: PresentedRecipeDetail?
    @State private var isRegenerationSheetPresented = false
    @State private var selectedRegenerationFocus: PrepRegenerationFocus = .balanced
    @State private var regenerationPromptText: String = ""

    private let columns = [
        GridItem(.flexible(), spacing: 14, alignment: .top),
        GridItem(.flexible(), spacing: 14, alignment: .top)
    ]

    private var isCurrentPrepCycle: Bool {
        store.latestPlan?.id.uuidString == cycle.id
    }

    private var displayedRecipes: [DiscoverRecipeCardData] {
        if isCurrentPrepCycle {
            return store.latestPlan?.recipes.map(DiscoverRecipeCardData.init(preppedRecipe:)) ?? []
        }
        return cycle.recipes
    }

    var body: some View {
        NavigationStack {
            ZStack {
                OunjePalette.background
                    .ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(cycle.title)
                                .biroHeaderFont(30)
                                .foregroundStyle(OunjePalette.primaryText)
                            Text(cycle.detail)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(OunjePalette.secondaryText)
                        }

                        if displayedRecipes.isEmpty {
                            RecipesEmptyState(
                                title: "No meals left in this prep",
                                detail: "Add a few back into next prep and they’ll show up here again.",
                                symbolName: "fork.knife.circle"
                            )
                        } else {
                            LazyVGrid(columns: columns, spacing: 14) {
                                ForEach(displayedRecipes) { recipe in
                                    DiscoverRemoteRecipeCard(
                                        recipe: recipe,
                                        secondaryTopAction: isCurrentPrepCycle
                                            ? .init(
                                                systemName: "xmark",
                                                accessibilityLabel: "Remove from prep",
                                                action: {
                                                    Task {
                                                        await store.removeRecipeFromLatestPlan(recipeID: recipe.id)
                                                    }
                                                }
                                            )
                                            : nil
                                    ) {
                                        presentedRecipe = PresentedRecipeDetail(recipeCard: recipe)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, OunjeLayout.screenHorizontalPadding)
                    .padding(.top, 12)
                    .padding(.bottom, 24)
                }
            }
            .scrollIndicators(.hidden)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .navigationBarBackButtonHidden()
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(OunjePalette.primaryText)
                    }
                }

                if isCurrentPrepCycle {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            selectedRegenerationFocus = .balanced
                            regenerationPromptText = ""
                            isRegenerationSheetPresented = true
                        } label: {
                            Image(systemName: "wand.and.stars")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(OunjePalette.primaryText)
                        }
                        .buttonStyle(.plain)
                        .disabled(store.isGenerating || !(store.profile?.isAutomationReady ?? false))
                        .opacity((store.isGenerating || !(store.profile?.isAutomationReady ?? false)) ? 0.65 : 1)
                    }
                }
            }
        }
        .fullScreenCover(item: $presentedRecipe) { presentedRecipe in
            RecipeDetailExperienceView(
                presentedRecipe: presentedRecipe,
                onOpenCart: {
                    selectedTab = .cart
                },
                toastCenter: toastCenter
            )
            .environmentObject(savedStore)
            .background(OunjePalette.background.ignoresSafeArea())
            .preferredColorScheme(.dark)
        }
        .sheet(isPresented: $isRegenerationSheetPresented) {
            CookbookCyclePromptSheet(
                cycleTitle: cycle.title,
                selectedFocus: $selectedRegenerationFocus,
                promptText: $regenerationPromptText,
                isGenerating: store.isGenerating,
                onCancel: {
                    isRegenerationSheetPresented = false
                },
                onConfirm: { options in
                    isRegenerationSheetPresented = false
                    Task { await store.regeneratePrepBatch(using: options) }
                }
            )
            .presentationDetents([.fraction(0.78), .large])
            .presentationDragIndicator(.visible)
        }
    }

}

private struct CookbookCyclePromptSheet: View {
    let cycleTitle: String
    @Binding var selectedFocus: PrepRegenerationFocus
    @Binding var promptText: String
    let isGenerating: Bool
    let onCancel: () -> Void
    let onConfirm: (PrepGenerationOptions) -> Void

    private let promptFocuses: [PrepRegenerationFocus] = [
        .balanced,
        .closerToFavorites,
        .moreVariety,
        .lessPrepTime,
        .tighterOverlap,
        .savedRecipeRefresh
    ]

    var body: some View {
        ZStack {
            OunjePalette.background.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    SleeScriptDisplayText("Shape this prep.", size: 26, color: OunjePalette.primaryText)
                    Text("Tell Ounje what to lean toward. It will fold your note into search, similarity, and reranking.")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(OunjePalette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(cycleTitle)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(OunjePalette.secondaryText.opacity(0.72))
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Prompt")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(OunjePalette.secondaryText)

                    ZStack(alignment: .topLeading) {
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .fill(OunjePalette.surface.opacity(0.96))
                            .overlay(
                                RoundedRectangle(cornerRadius: 22, style: .continuous)
                                    .stroke(OunjePalette.stroke.opacity(0.86), lineWidth: 1)
                            )

                        TextEditor(text: $promptText)
                            .scrollContentBackground(.hidden)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(OunjePalette.primaryText)
                            .padding(11)
                            .frame(minHeight: 116)
                            .tint(OunjePalette.accent)

                        if promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Text("Say what you want more of, less of, or what should feel different.")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(OunjePalette.secondaryText.opacity(0.78))
                                .padding(.horizontal, 17)
                                .padding(.vertical, 18)
                                .allowsHitTesting(false)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Quick starts")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(OunjePalette.secondaryText)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(promptFocuses) { focus in
                                Button {
                                    selectedFocus = focus
                                } label: {
                                    HStack(spacing: 7) {
                                        Image(systemName: focus.systemImageName)
                                            .font(.system(size: 11, weight: .semibold))
                                        Text(focus.title)
                                            .sleeDisplayFont(14)
                                    }
                                    .foregroundStyle(selectedFocus == focus ? OunjePalette.softCream.opacity(0.98) : OunjePalette.primaryText)
                                    .padding(.horizontal, 13)
                                    .padding(.vertical, 10)
                                    .background(
                                        Capsule(style: .continuous)
                                            .fill(selectedFocus == focus ? OunjePalette.accent.opacity(0.92) : OunjePalette.surface)
                                            .overlay(
                                                Capsule(style: .continuous)
                                                    .stroke(selectedFocus == focus ? OunjePalette.accent.opacity(0.22) : OunjePalette.stroke, lineWidth: 1)
                                            )
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }

                HStack(spacing: 12) {
                    Button(action: onCancel) {
                        Text("Keep current")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(OunjePalette.primaryText)
                            .frame(maxWidth: .infinity)
                            .frame(height: 54)
                            .background(
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .fill(OunjePalette.surface.opacity(0.94))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .stroke(OunjePalette.stroke.opacity(0.84), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)

                    Button {
                        onConfirm(PrepGenerationOptions(focus: selectedFocus, userPrompt: promptText))
                    } label: {
                        Text(isGenerating ? "Generating..." : "Generate prep")
                            .sleeDisplayFont(18)
                            .foregroundStyle(OunjePalette.primaryText)
                            .frame(maxWidth: .infinity)
                            .frame(height: 54)
                            .background(
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .fill(
                                        LinearGradient(
                                            colors: [
                                                OunjePalette.accent.opacity(0.94),
                                                OunjePalette.accent.opacity(0.78)
                                            ],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        )
                                    )
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(isGenerating)
                    .opacity(isGenerating ? 0.72 : 1)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 24)
            .padding(.bottom, 20)
        }
    }
}

private struct ProfileTabView: View {
    @EnvironmentObject private var store: MealPlanningAppStore
    @State private var isAddressSheetPresented = false
    @State private var isFoodProfilePresented = false
    @State private var isCadencePickerPresented = false
    @State private var isAutonomyPickerPresented = false
    @State private var isPaywallPresented = false
    @StateObject private var addressAutocomplete = AddressAutocompleteViewModel()

    @State private var addressLine1 = ""
    @State private var addressLine2 = ""
    @State private var city = ""
    @State private var region = ""
    @State private var postalCode = ""
    @State private var deliveryNotes = ""

    private var profile: UserProfile? {
        store.profile
    }

    private var addressSummary: String {
        [addressLine1, city, region, postalCode]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }

    private var accountDisplayName: String {
        let profileName = profile?.trimmedPreferredName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let sessionName = store.authSession?.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let emailPrefix = store.authSession?.email?
            .split(separator: "@")
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let candidates = [profileName, sessionName, emailPrefix]
            .compactMap { $0 }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard let firstRealCandidate = candidates.first(where: { candidate in
            let lowered = candidate.lowercased()
            return lowered != "debug" && lowered != "debug-user" && lowered != "debug_user"
        }) else {
            return "Your account"
        }

        return firstRealCandidate
    }

    private var accountEmail: String? {
        guard let email = store.authSession?.email?.trimmingCharacters(in: .whitespacesAndNewlines),
              !email.isEmpty,
              email.lowercased() != "debug@example.com" else {
            return nil
        }
        return email
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if let profile {
                    VStack(alignment: .leading, spacing: 18) {
                        VStack(alignment: .leading, spacing: 6) {
                            BiroScriptDisplayText("Profile", size: 29, color: OunjePalette.primaryText)
                            Text("Taste, cadence, delivery, and support.")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(OunjePalette.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        ProfileIdentityCard(
                            displayName: accountDisplayName,
                            email: accountEmail,
                            budgetSummary: profile.budgetSummary,
                            cadenceTitle: profile.cadence.title,
                            autonomyTitle: profile.orderingAutonomy.title
                        )

                        ProfileUpgradeCard {
                            isPaywallPresented = true
                        }

                        ProfileSettingsCard(
                            title: "Profile",
                            rows: [
                                .init(
                                    icon: "fork.knife",
                                    title: "Food profile",
                                    value: "Diet, cuisines, goals, and hard limits",
                                    action: { isFoodProfilePresented = true }
                                ),
                                .init(
                                    icon: "house",
                                    title: "Home address",
                                    value: addressSummary.isEmpty ? "Add address" : addressSummary,
                                    action: { isAddressSheetPresented = true }
                                )
                            ]
                        )

                        ProfileSettingsCard(
                            title: "Preferences",
                            rows: [
                                .init(
                                    icon: "calendar",
                                    title: "Delivery cadence",
                                    value: profile.cadence.title,
                                    action: { isCadencePickerPresented = true }
                                ),
                                .init(
                                    icon: "slider.horizontal.3",
                                    title: "Ordering autonomy",
                                    value: profile.orderingAutonomy.title,
                                    action: { isAutonomyPickerPresented = true }
                                )
                            ]
                        )

                        GroceryProvidersCard()

                        ProfileSettingsCard(
                            title: "Account",
                            rows: [
                                .init(
                                    icon: "rectangle.portrait.and.arrow.right",
                                    title: "Sign out",
                                    value: "Log out of this device",
                                    isDestructive: true,
                                    action: { store.signOutToWelcome() }
                                )
                            ]
                        )
                    }
                } else {
                    RecipesEmptyState(
                        title: "No profile loaded",
                        detail: "Once your onboarding sync is present, your planning profile shows up here.",
                        symbolName: "person.crop.circle"
                    )
                }
            }
            .padding(.horizontal, OunjeLayout.screenHorizontalPadding)
            .padding(.top, 14)
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
        .background(OunjePalette.background.ignoresSafeArea())
        .sheet(isPresented: $isAddressSheetPresented, onDismiss: saveAddressChanges) {
            AddressSetupSheet(
                addressLine1: $addressLine1,
                addressLine2: $addressLine2,
                city: $city,
                region: $region,
                postalCode: $postalCode,
                deliveryNotes: $deliveryNotes,
                autocomplete: addressAutocomplete,
                onSuggestionSelected: selectAddressSuggestion(_:),
                onClear: clearAddress
            )
        }
        .sheet(isPresented: $isFoodProfilePresented) {
            if let profile {
                FoodProfileSheet(profile: profile)
            }
        }
        .sheet(isPresented: $isPaywallPresented) {
            OunjePlusPaywallSheet()
                .presentationDragIndicator(.hidden)
        }
        .confirmationDialog("Delivery cadence", isPresented: $isCadencePickerPresented, titleVisibility: .visible) {
            if let profile {
                ForEach(MealCadence.allCases) { cadence in
                    Button(cadence.title) {
                        var updated = profile
                        updated.cadence = cadence
                        store.updateProfile(updated)
                    }
                }
            }
        }
        .confirmationDialog("Ordering autonomy", isPresented: $isAutonomyPickerPresented, titleVisibility: .visible) {
            if let profile {
                ForEach(OrderingAutonomyLevel.allCases.filter { $0 != .suggestOnly }) { autonomy in
                    Button(autonomy.title) {
                        var updated = profile
                        updated.orderingAutonomy = autonomy
                        store.updateProfile(updated)
                    }
                }
            }
        }
        .onAppear(perform: syncAddressFields)
    }

    private func syncAddressFields() {
        guard let address = store.profile?.deliveryAddress else { return }
        addressLine1 = address.line1
        addressLine2 = address.line2
        city = address.city
        region = address.region
        postalCode = address.postalCode
        deliveryNotes = address.deliveryNotes
    }

    private func saveAddressChanges() {
        guard var updated = store.profile else { return }
        updated.deliveryAddress = DeliveryAddress(
            line1: addressLine1,
            line2: addressLine2,
            city: city,
            region: region,
            postalCode: postalCode,
            deliveryNotes: deliveryNotes
        )
        store.updateProfile(updated)
    }

    private func clearAddress() {
        addressLine1 = ""
        addressLine2 = ""
        city = ""
        region = ""
        postalCode = ""
        deliveryNotes = ""
    }

    private func selectAddressSuggestion(_ suggestion: AddressSuggestion) async {
        guard let resolved = await addressAutocomplete.resolve(suggestion) else { return }
        addressLine1 = resolved.line1
        addressLine2 = resolved.line2
        city = resolved.city
        region = resolved.region
        postalCode = resolved.postalCode
        deliveryNotes = resolved.deliveryNotes
    }
}

private struct ProfileIdentityCard: View {
    let displayName: String
    let email: String?
    let budgetSummary: String
    let cadenceTitle: String
    let autonomyTitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text(displayName)
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .foregroundStyle(OunjePalette.primaryText)
                    .lineLimit(1)

                if let email {
                    Text(email)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(OunjePalette.secondaryText)
                        .lineLimit(1)
                } else {
                    Text("Defaults, delivery, and food profile")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(OunjePalette.secondaryText)
                }
            }

            ViewThatFits {
                HStack(alignment: .top, spacing: 16) {
                    ProfileMetaDetail(label: "Budget", value: budgetSummary)
                    ProfileMetaDivider()
                    ProfileMetaDetail(label: "Cadence", value: cadenceTitle)
                    ProfileMetaDivider()
                    ProfileMetaDetail(label: "Ordering", value: autonomyTitle)
                }
                VStack(alignment: .leading, spacing: 12) {
                    ProfileMetaDetail(label: "Budget", value: budgetSummary)
                    ProfileMetaDetail(label: "Cadence", value: cadenceTitle)
                    ProfileMetaDetail(label: "Ordering", value: autonomyTitle)
                }
            }
        }
        .padding(.bottom, 2)
    }
}

private struct ProfileMetaDetail: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.9)
                .foregroundStyle(OunjePalette.secondaryText)
            Text(value)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(OunjePalette.primaryText.opacity(0.92))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ProfileMetaDivider: View {
    var body: some View {
        Rectangle()
            .fill(OunjePalette.stroke.opacity(0.85))
            .frame(width: 1, height: 32)
    }
}

private struct ProfileSettingRowModel: Identifiable {
    let id = UUID()
    let icon: String
    let title: String
    let value: String
    var isDestructive = false
    let action: () -> Void
}

// MARK: - Grocery Providers Connection

private struct GroceryProvidersCard: View {
    @EnvironmentObject private var store: MealPlanningAppStore
    @StateObject private var viewModel = GroceryProvidersViewModel()
    @State private var selectedProvider: GroceryProviderInfo?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Providers")
                .biroHeaderFont(18)
                .foregroundStyle(OunjePalette.primaryText)

            VStack(spacing: 0) {
                ForEach(Array(viewModel.providers.enumerated()), id: \.element.id) { index, provider in
                    Button {
                        selectedProvider = provider
                    } label: {
                        HStack(alignment: .center, spacing: 12) {
                            Image(systemName: provider.connected ? "checkmark.circle.fill" : "cart.circle.fill")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(provider.connected ? OunjePalette.accent : OunjePalette.softCream.opacity(0.92))
                                .frame(width: 22)

                            VStack(alignment: .leading, spacing: 4) {
                                Text(provider.name)
                                .font(.system(size: 17, weight: .semibold))
                                    .foregroundStyle(OunjePalette.primaryText)
                                Text(provider.connected ? "Connected and ready" : "Tap to connect")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(provider.connected ? OunjePalette.accent : OunjePalette.secondaryText)
                            }

                            Spacer(minLength: 8)

                            if provider.connected {
                                Text("On")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundStyle(OunjePalette.accent)
                            } else {
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundStyle(OunjePalette.secondaryText.opacity(0.45))
                            }
                        }
                        .padding(.vertical, 15)
                    }
                    .buttonStyle(.plain)

                    if index < viewModel.providers.count - 1 {
                        Divider()
                            .overlay(OunjePalette.stroke.opacity(0.55))
                    }
                }
            }
        }
        .onAppear {
            viewModel.loadProviders(userId: store.authSession?.userID, accessToken: store.authSession?.accessToken)
        }
        .sheet(item: $selectedProvider) { provider in
            GroceryProviderConnectSheet(
                provider: provider,
                userId: store.authSession?.userID ?? "",
                accessToken: store.authSession?.accessToken,
                onConnected: {
                    viewModel.loadProviders(userId: store.authSession?.userID, accessToken: store.authSession?.accessToken)
                    selectedProvider = nil
                }
            )
        }
    }
}

private struct GroceryProviderInfo: Identifiable {
    let id: String
    let name: String
    var connected: Bool
}

@MainActor
private class GroceryProvidersViewModel: ObservableObject {
    @Published var providers: [GroceryProviderInfo] = [
        GroceryProviderInfo(id: "instacart", name: "Instacart", connected: false),
        GroceryProviderInfo(id: "walmart", name: "Walmart", connected: false),
    ]
    @Published var isLoading = false

    func loadProviders(userId: String?, accessToken: String?) {
        Task {
            isLoading = true
            defer { isLoading = false }

            guard let url = URL(string: "\(OunjeDevelopmentServer.baseURL)/v1/connect/providers") else { return }

            var request = URLRequest(url: url)
            if let userId = userId {
                request.setValue(userId, forHTTPHeaderField: "x-user-id")
            }
            if let accessToken, !accessToken.isEmpty {
                request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            }
            do {
                let (data, _) = try await URLSession.shared.data(for: request)
                let response = try JSONDecoder().decode(ProvidersResponse.self, from: data)
                providers = response.providers.map { p in
                    GroceryProviderInfo(id: p.id, name: p.name, connected: p.connected)
                }
            } catch {
                print("[GroceryProviders] Failed to load: \(error)")
            }
        }
    }

    private struct ProvidersResponse: Decodable {
        let providers: [ProviderData]
        struct ProviderData: Decodable {
            let id: String
            let name: String
            let connected: Bool
        }
    }
}

private struct GroceryProviderConnectSheet: View {
    let provider: GroceryProviderInfo
    let userId: String
    let accessToken: String?
    let onConnected: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var phase: Phase = .instructions
    @State private var isLoading = false
    @State private var isSaving = false

    enum Phase { case instructions, login, saving, connected, error(String) }

    private var loginURL: URL {
        switch provider.id {
        case "instacart":
            return URL(string: "https://www.instacart.ca/login")!
        case "walmart":
            return URL(string: "https://www.walmart.ca/sign-in")!
        default:
            return URL(string: "https://www.instacart.ca/login")!
        }
    }

    private var cookieDomain: String {
        switch provider.id {
        case "instacart":
            return "instacart.ca"
        case "walmart":
            return "walmart.ca"
        default:
            return provider.id
        }
    }

    private var cookieDomains: [String] {
        switch provider.id {
        case "instacart":
            return ["instacart.ca", "instacart.com"]
        case "walmart":
            return ["walmart.ca", "walmart.com"]
        default:
            return [cookieDomain]
        }
    }

    private var mobileUserAgent: String {
        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
    }

    var body: some View {
        NavigationStack {
            Group {
                switch phase {
                case .instructions: instructionsView
                case .login: loginView
                case .saving: savingView
                case .connected: connectedView
                case .error(let msg): errorView(msg)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(OunjePalette.background.ignoresSafeArea())
            .navigationTitle("Connect \(provider.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .onAppear {
            if provider.connected { phase = .connected }
        }
    }

    private var instructionsView: some View {
        VStack(spacing: 24) {
            Image(systemName: "iphone.and.arrow.forward")
                .font(.system(size: 64))
                .foregroundStyle(OunjePalette.accent)

            VStack(spacing: 8) {
                Text("Connect \(provider.name)")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(OunjePalette.primaryText)
                Text("Open the mobile login inside Ounje so we can save the session back into your account.")
                    .font(.system(size: 15))
                    .foregroundStyle(OunjePalette.secondaryText)
                    .multilineTextAlignment(.center)
            }

            VStack(alignment: .leading, spacing: 12) {
                stepRow("1", "Open the mobile login in Ounje")
                stepRow("2", "Sign in with your \(provider.name) account")
                stepRow("3", "Tap Link session after you’re signed in")
            }
            .padding()
            .background(OunjePalette.panel, in: RoundedRectangle(cornerRadius: 12))

            Button {
                phase = .login
            } label: {
                Text("Open \(provider.name)")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(OunjePalette.accent, in: RoundedRectangle(cornerRadius: 12))
            }
            Spacer()
        }
    }

    private var loginView: some View {
        VStack(spacing: 16) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(provider.name)
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(OunjePalette.primaryText)
                    Text("Mobile login")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(OunjePalette.secondaryText)
                }

                Spacer()

                Button("Back") {
                    phase = .instructions
                }
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(OunjePalette.secondaryText)
            }

            ProviderLoginWebView(
                url: loginURL,
                customUserAgent: mobileUserAgent,
                isLoading: $isLoading
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(alignment: .topTrailing) {
                if isLoading {
                    ProgressView()
                        .scaleEffect(0.9)
                        .padding(10)
                        .background(OunjePalette.panel.opacity(0.88), in: Capsule())
                        .padding(12)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("When you’re signed in, tap Link session and Ounje will transfer the login back into your profile.")
                    .font(.system(size: 14))
                    .foregroundStyle(OunjePalette.secondaryText)

                Button {
                    Task {
                        await saveSessionFromWebLogin()
                    }
                } label: {
                    HStack(spacing: 8) {
                        if isSaving {
                            ProgressView().tint(.white)
                        } else {
                            Image(systemName: "link")
                        }
                        Text(isSaving ? "Linking…" : "Link session")
                    }
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(OunjePalette.accent, in: RoundedRectangle(cornerRadius: 12))
                }
                .disabled(isSaving)
            }
        }
    }

    private var savingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.35)
            Text("Linking session…")
                .font(.system(size: 15))
                .foregroundStyle(OunjePalette.secondaryText)
        }
    }

    private var connectedView: some View {
        VStack(spacing: 24) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 80))
                .foregroundStyle(.green)
            VStack(spacing: 8) {
                Text("Connected!")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(OunjePalette.primaryText)
                Text("Your \(provider.name) account is linked.")
                    .font(.system(size: 15))
                    .foregroundStyle(OunjePalette.secondaryText)
                    .multilineTextAlignment(.center)
            }
            Button {
                dismiss()
            } label: {
                Text("Done")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(OunjePalette.accent, in: RoundedRectangle(cornerRadius: 12))
            }
            Spacer()
        }
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 50)).foregroundStyle(.orange)
            Text("Connection Failed")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(OunjePalette.primaryText)
            Text(message)
                .font(.system(size: 14))
                .foregroundStyle(OunjePalette.secondaryText)
                .multilineTextAlignment(.center)
            Button("Try Again") { phase = .instructions }
                .buttonStyle(.borderedProminent)
        }
    }

    private func stepRow(_ n: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(n)
                .font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(OunjePalette.accent, in: Circle())
            Text(text)
                .font(.system(size: 15)).foregroundStyle(OunjePalette.primaryText)
            Spacer()
        }
    }

    @MainActor
    private func saveSessionFromWebLogin() async {
        isSaving = true
        phase = .saving
        defer { isSaving = false }

        do {
            let cookies = await readProviderCookiesFromWebLogin()
            guard !cookies.isEmpty else {
                phase = .error("No session found yet. Finish logging in, then tap Link session again.")
                return
            }
            try await saveCookies(cookies, accessToken: accessToken)
            phase = .connected
            onConnected()
        } catch {
            phase = .error(error.localizedDescription)
        }
    }

    @MainActor
    private func readProviderCookiesFromWebLogin() async -> [[String: Any]] {
        await withCheckedContinuation { continuation in
            WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
                let relevant = cookies.filter { cookie in
                    let domain = cookie.domain.lowercased()
                    return cookieDomains.contains(where: { domain.contains($0) })
                }
                let data: [[String: Any]] = relevant.map { cookie in
                    var record: [String: Any] = [
                        "name": cookie.name,
                        "value": cookie.value,
                        "domain": cookie.domain,
                        "path": cookie.path
                    ]
                    if let expiresDate = cookie.expiresDate {
                        record["expires"] = expiresDate.timeIntervalSince1970
                    }
                    if cookie.isSecure { record["secure"] = true }
                    if cookie.isHTTPOnly { record["httpOnly"] = true }
                    return record
                }
                continuation.resume(returning: data)
            }
        }
    }

    private func saveCookies(_ cookies: [[String: Any]], accessToken: String?) async throws {
        guard let url = URL(string: "\(OunjeDevelopmentServer.baseURL)/v1/connect/\(provider.id)/save-session") else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(userId, forHTTPHeaderField: "x-user-id")
        if let accessToken, !accessToken.isEmpty {
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: ["cookies": cookies])
        let (_, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
    }
}

private struct ProviderLoginWebView: UIViewRepresentable {
    let url: URL
    let customUserAgent: String
    @Binding var isLoading: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(isLoading: $isLoading)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        configuration.defaultWebpagePreferences.preferredContentMode = .mobile

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.customUserAgent = customUserAgent
        webView.allowsBackForwardNavigationGestures = true
        webView.isOpaque = false
        webView.backgroundColor = UIColor.black
        webView.scrollView.backgroundColor = UIColor.black
        context.coordinator.webView = webView
        context.coordinator.lastLoadedURL = url
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        if context.coordinator.lastLoadedURL != url {
            context.coordinator.lastLoadedURL = url
            uiView.load(URLRequest(url: url))
        }
    }

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        uiView.navigationDelegate = nil
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        weak var webView: WKWebView?
        var lastLoadedURL: URL?
        private var isLoading: Binding<Bool>

        init(isLoading: Binding<Bool>) {
            self.isLoading = isLoading
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            isLoading.wrappedValue = true
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isLoading.wrappedValue = false
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            isLoading.wrappedValue = false
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            isLoading.wrappedValue = false
        }

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            guard let url = navigationAction.request.url else { return nil }
            if shouldAllow(url: url) {
                webView.load(URLRequest(url: url))
            }
            return nil
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }

            if shouldAllow(url: url) {
                decisionHandler(.allow)
            } else {
                decisionHandler(.cancel)
            }
        }

        private func shouldAllow(url: URL) -> Bool {
            guard let scheme = url.scheme?.lowercased() else { return false }
            return ["http", "https", "about", "data", "blob"].contains(scheme)
        }
    }
}

private struct ProfileSettingsCard: View {
    let title: String
    let rows: [ProfileSettingRowModel]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .biroHeaderFont(18)
                .foregroundStyle(OunjePalette.primaryText)

            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    Button(action: row.action) {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: row.icon)
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(row.isDestructive ? Color(hex: "FF8E8E") : OunjePalette.softCream.opacity(0.92))
                                .frame(width: 22)
                                .padding(.top, 2)

                            VStack(alignment: .leading, spacing: 4) {
                                Text(row.title)
                                    .font(.system(size: 17, weight: .semibold))
                                    .foregroundStyle(row.isDestructive ? Color(hex: "FF8E8E") : OunjePalette.primaryText)
                                Text(row.value)
                                    .font(.system(size: 13, weight: .regular))
                                    .foregroundStyle(OunjePalette.secondaryText)
                                    .lineLimit(2)
                            }

                            Spacer(minLength: 8)

                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(OunjePalette.secondaryText.opacity(0.45))
                                .padding(.top, 4)
                        }
                        .padding(.vertical, 15)
                    }
                    .buttonStyle(.plain)

                    if index < rows.count - 1 {
                        Divider()
                            .overlay(OunjePalette.stroke.opacity(0.55))
                    }
                }
            }
        }
    }
}

private struct ProfileUpgradeCard: View {
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("OUNJE PLUS")
                        .font(.system(size: 11, weight: .bold))
                        .tracking(1.8)
                        .foregroundStyle(OunjePalette.accent)

                    Text("Keep Ounje on call.")
                        .font(.system(size: 28, weight: .semibold, design: .serif))
                        .foregroundStyle(OunjePalette.primaryText)

                    Text("Prep, imports, carts, and ordering without the weekly drag.")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(OunjePalette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 12)

                VStack(alignment: .trailing, spacing: 6) {
                    Text("Founding 50")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(OunjePalette.softCream, in: Capsule())

                    VStack(alignment: .trailing, spacing: 1) {
                        Text("$300")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(OunjePalette.secondaryText.opacity(0.8))
                            .strikethrough(true, color: OunjePalette.secondaryText.opacity(0.8))

                        Text("$150")
                            .font(.system(size: 30, weight: .bold, design: .serif))
                            .foregroundStyle(OunjePalette.primaryText)
                    }

                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(OunjePalette.primaryText.opacity(0.72))
                }
            }
            .padding(18)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                OunjePalette.panel.opacity(0.86),
                                OunjePalette.surface.opacity(0.72)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .stroke(OunjePalette.stroke.opacity(0.72), lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
    }
}

private enum OunjeSubscriptionTier: String, CaseIterable, Identifiable {
    case weekly
    case monthly
    case foundingLifetime

    var id: String { rawValue }

    var title: String {
        switch self {
        case .weekly:
            return "Weekly"
        case .monthly:
            return "Monthly"
        case .foundingLifetime:
            return "Founding lifetime"
        }
    }

    var subtitle: String {
        switch self {
        case .weekly:
            return "Good for trying Ounje during a single prep cycle."
        case .monthly:
            return "Best value if Ounje is becoming part of your regular flow."
        case .foundingLifetime:
            return "Only 50 spots. One-time support for the first supporters."
        }
    }

    var priceText: String {
        switch self {
        case .weekly:
            return "$3.99"
        case .monthly:
            return "$14.99"
        case .foundingLifetime:
            return "$150"
        }
    }

    var originalPriceText: String? {
        switch self {
        case .foundingLifetime:
            return "$300"
        default:
            return nil
        }
    }

    var cadenceText: String {
        switch self {
        case .weekly:
            return "/week"
        case .monthly:
            return "/month"
        case .foundingLifetime:
            return "one-time"
        }
    }

    var badgeText: String? {
        switch self {
        case .weekly:
            return nil
        case .monthly:
            return "Best value"
        case .foundingLifetime:
            return "50% off"
        }
    }

    var accentColor: Color {
        switch self {
        case .weekly:
            return OunjePalette.softCream
        case .monthly:
            return OunjePalette.accent
        case .foundingLifetime:
            return Color(hex: "B57DFF")
        }
    }
}

private struct OunjePlusPaywallSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var selectedTier: OunjeSubscriptionTier = .monthly

    var body: some View {
        ZStack(alignment: .topTrailing) {
            OunjePalette.background
                .ignoresSafeArea()

            LinearGradient(
                colors: [
                    OunjePalette.panel.opacity(0.32),
                    .clear,
                    OunjePalette.accent.opacity(0.08)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 24) {
                    VStack(alignment: .center, spacing: 12) {
                        Text("OUNJE PLUS")
                            .font(.system(size: 11, weight: .bold))
                            .tracking(2.0)
                            .foregroundStyle(OunjePalette.accent)

                        Text("Keep Ounje on call.")
                            .font(.system(size: 40, weight: .semibold, design: .serif))
                            .foregroundStyle(OunjePalette.primaryText)
                            .multilineTextAlignment(.center)

                        Text("Meal prep, imports, carts, and ordering that stay grounded in your profile and the way you actually cook.")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(OunjePalette.secondaryText)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 320)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 64)

                    VStack(spacing: 12) {
                        ForEach(OunjeSubscriptionTier.allCases) { tier in
                            Button {
                                selectedTier = tier
                            } label: {
                                PaywallTierCard(
                                    tier: tier,
                                    isSelected: selectedTier == tier,
                                    featureLines: []
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        PaywallFeatureLine(text: "24/7 direct support")
                        PaywallFeatureLine(text: "Priority product feedback")
                        PaywallFeatureLine(text: "Beta features before wider release")
                        PaywallFeatureLine(text: "Smarter prep, cart, and ordering automation")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Text("For this founder window, the first fifty supporters can lock lifetime access in at half price: $150 instead of $300.")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(OunjePalette.secondaryText)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)

                    Button {
                        dismiss()
                    } label: {
                        Text("Continue with \(selectedTier.title)")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.black)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 17)
                    }
                    .buttonStyle(PrimaryPillButtonStyle())

                    Text("Cancel any time on weekly or monthly. Founder access is limited and one-time.")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(OunjePalette.secondaryText)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .padding(.bottom, 24)
                }
                .padding(.horizontal, OunjeLayout.screenHorizontalPadding)
            }

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(OunjePalette.primaryText.opacity(0.92))
                    .frame(width: 36, height: 36)
                    .background(OunjePalette.panel.opacity(0.8), in: Circle())
            }
            .padding(.top, 18)
            .padding(.trailing, OunjeLayout.screenHorizontalPadding)
        }
    }
}

private struct PaywallTag: View {
    let label: String

    var body: some View {
        Text(label)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(OunjePalette.primaryText)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule(style: .continuous)
                    .fill(OunjePalette.surface.opacity(0.96))
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(OunjePalette.stroke, lineWidth: 1)
                    )
            )
    }
}

private struct PaywallFeatureLine: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "checkmark")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(OunjePalette.accent)
                .padding(.top, 4)
            Text(text)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(OunjePalette.primaryText.opacity(0.92))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct PaywallTierCard: View {
    let tier: OunjeSubscriptionTier
    let isSelected: Bool
    let featureLines: [String]

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(tier.title)
                        .font(.system(size: 22, weight: .semibold, design: .serif))
                        .foregroundStyle(OunjePalette.primaryText)
                    if let badgeText = tier.badgeText {
                        Text(badgeText)
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(isSelected ? .black : tier.accentColor)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(isSelected ? OunjePalette.softCream : tier.accentColor.opacity(0.12))
                            )
                    }
                }

                Text(tier.subtitle)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(OunjePalette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            VStack(alignment: .trailing, spacing: 4) {
                if let originalPriceText = tier.originalPriceText {
                    Text(originalPriceText)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(OunjePalette.secondaryText.opacity(0.78))
                        .strikethrough(true, color: OunjePalette.secondaryText.opacity(0.78))
                }
                Text(tier.priceText)
                    .font(.system(size: 30, weight: .bold, design: .serif))
                    .foregroundStyle(OunjePalette.primaryText)
                Text(tier.cadenceText)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(OunjePalette.secondaryText)
            }

            ZStack {
                Circle()
                    .stroke(isSelected ? tier.accentColor : OunjePalette.stroke.opacity(0.7), lineWidth: 1.4)
                    .frame(width: 22, height: 22)

                if isSelected {
                    Circle()
                        .fill(tier.accentColor)
                        .frame(width: 10, height: 10)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(isSelected ? tier.accentColor.opacity(0.09) : OunjePalette.surface.opacity(0.72))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(isSelected ? tier.accentColor.opacity(0.5) : OunjePalette.stroke, lineWidth: 1.2)
                )
        )
    }
}

private struct FoodProfileSheet: View {
    let profile: UserProfile
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    BubblySurfaceCard(accent: profile.agentSummaryAesthetic.primary) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Food profile")
                                .biroHeaderFont(28)
                                .foregroundStyle(.white)
                            Text(profile.profileNarrative)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(.white.opacity(0.72))
                        }
                    }

                    ForEach(profile.structuredSummarySections) { section in
                        ThemedCard {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(section.title)
                                    .biroHeaderFont(16)
                                    .foregroundStyle(OunjePalette.primaryText)
                                Text(section.detail)
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundStyle(OunjePalette.secondaryText)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                }
                .padding(.horizontal, OunjeLayout.screenHorizontalPadding)
                .padding(.top, 18)
                .padding(.bottom, 24)
            }
            .background(OunjePalette.background.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .preferredColorScheme(.dark)
        }
    }
}

private struct CartTabView: View {
    @EnvironmentObject private var store: MealPlanningAppStore
    @Binding var selectedTab: AppTab
    @Binding var focusedRecipeID: String?
    @State private var displayMode: CartDisplayMode = .reconciled
    @State private var ingredientRows: [SupabaseRecipeIngredientRow] = []
    @State private var cartDisplayItems: [CartGroceryDisplayItem] = []
    @State private var reconciledCartItems: [CartGroceryDisplayItem] = []
    @State private var reconciledCartSections: [ReconciledCartSection] = []
    @State private var boxedCartCoverageSummary: BoxedCartCoverageSummary?
    @State private var isLoadingIngredients = false
    @State private var ingredientLoadError: String?

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    HStack(alignment: .center) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Cart")
                                .biroHeaderFont(32)
                                .foregroundStyle(OunjePalette.primaryText)
                            Text(cartSummaryLine)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(OunjePalette.secondaryText)
                        }

                        Spacer(minLength: 16)
                    }

                    if shouldShowLiveCartContent {
                        CartDisplayModeBar(selection: $displayMode)
                    }

                    if shouldShowEmptyCartState {
                        CartEmptyState(
                            onBrowseDiscover: { selectedTab = .discover }
                        )
                    } else if isLoadingIngredients && displayIngredientGroups.isEmpty && displayGroceryItems.isEmpty {
                        CartLoadingState()
                    } else {
                        cartDisplayContent
                    }
                }
                .padding(.horizontal, OunjeLayout.screenHorizontalPadding)
                .padding(.top, 14)
                .padding(.bottom, 12)
            }
            .scrollIndicators(.hidden)
        }
        .background(OunjePalette.background.ignoresSafeArea())
        .task(id: activeRecipeIDs.joined(separator: "|")) {
            await store.refreshLatestPlanGrocerySourcesIfNeeded()
            await reloadCartIngredients()
        }
    }

    private var activeRecipeIDs: [String] {
        (store.latestPlan?.recipes ?? []).map(\.recipe.id)
    }

    private var shouldShowEmptyCartState: Bool {
        activeRecipeIDs.isEmpty && displayGroceryItems.isEmpty && reconciledCartItems.isEmpty
    }

    private var shouldShowLiveCartContent: Bool {
        !shouldShowEmptyCartState
    }

    private var cartSummaryLine: String {
        if displayMode == .reconciled, !reconciledCartItems.isEmpty {
            let itemLabel = reconciledCartItems.count == 1 ? "shoppable item" : "shoppable items"
            if let boxedCartCoverageSummary, !boxedCartCoverageSummary.isFullyAccountedFor {
                let uncoveredCount = boxedCartCoverageSummary.uncoveredBaseLabels.count
                let uncoveredLabel = uncoveredCount == 1 ? "item still needs review" : "items still need review"
                return "\(reconciledCartItems.count) \(itemLabel) • \(uncoveredCount) \(uncoveredLabel)"
            }
            return "\(reconciledCartItems.count) \(itemLabel) for this prep"
        }

        let recipeCount = displayIngredientGroups.count
        let ingredientCount = allIngredientCards.count
        if recipeCount > 0 || ingredientCount > 0 {
            let recipeLabel = recipeCount == 1 ? "recipe" : "recipes"
            let ingredientLabel = ingredientCount == 1 ? "ingredient" : "ingredients"
            return "\(recipeCount) \(recipeLabel) • \(ingredientCount) \(ingredientLabel)"
        }
        return "Next prep ingredients"
    }

    private var displayIngredientGroups: [CartIngredientGroup] {
        guard let latestPlan = store.latestPlan else { return [] }

        return latestPlan.recipes.compactMap { plannedRecipe in
            let sourceRows = ingredientRows.filter { $0.recipeID == plannedRecipe.recipe.id }
            let fallbackRows = plannedRecipe.recipe.ingredients.enumerated().map { index, ingredient in
                SupabaseRecipeIngredientRow(
                    id: "\(plannedRecipe.recipe.id)::fallback::\(index)",
                    recipeID: plannedRecipe.recipe.id,
                    ingredientID: nil,
                    displayName: ingredient.name,
                    quantityText: CartQuantityFormatter.format(amount: ingredient.amount, unit: ingredient.unit),
                    imageURLString: nil,
                    sortOrder: index
                )
            }
            let rows = sourceRows.isEmpty ? fallbackRows : sourceRows
            guard !rows.isEmpty else { return nil }

            return CartIngredientGroup(
                recipeID: plannedRecipe.recipe.id,
                recipeTitle: plannedRecipe.recipe.title,
                servings: plannedRecipe.servings,
                cookTimeMinutes: plannedRecipe.recipe.prepMinutes,
                ingredients: rows
            )
            }
    }

    private var displayGroceryItems: [CartGroceryDisplayItem] {
        cartDisplayItems
    }

    private var allIngredientCards: [SupabaseRecipeIngredientRow] {
        var seen = Set<String>()
        return displayIngredientGroups
            .flatMap(\.ingredients)
            .filter { ingredient in
                let key = Self.normalizedIngredientKey(ingredient.displayName)
                return seen.insert(key).inserted
        }
    }

    @ViewBuilder
    private var cartDisplayContent: some View {
        switch displayMode {
        case .recipes:
            VStack(spacing: 18) {
                ForEach(displayIngredientGroups) { group in
                    CartRecipeListCard(group: group)
                }
            }
        case .grid:
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 18, alignment: .top), count: 4),
                spacing: 24
            ) {
                ForEach(allIngredientCards) { ingredient in
                    CartFlatIngredientTile(ingredient: ingredient)
                }
            }
        case .reconciled:
            VStack(alignment: .leading, spacing: 22) {
                if let quote = store.latestPlan?.bestQuote, !quote.reviewItems.isEmpty {
                    ProviderCartReviewCard(quote: quote)
                }

                if let boxedCartCoverageSummary, !boxedCartCoverageSummary.isFullyAccountedFor {
                    CartReconciledCoverageNotice(summary: boxedCartCoverageSummary)
                }

                ForEach(reconciledCartSections) { section in
                    VStack(alignment: .leading, spacing: 12) {
                        Text(section.title)
                            .biroHeaderFont(16)
                            .foregroundStyle(OunjePalette.primaryText)

                        if let subtitle = section.subtitle {
                            Text(subtitle)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(OunjePalette.secondaryText)
                        }

                        VStack(spacing: 14) {
                            ForEach(section.items) { item in
                                CartGroceryLineItemRow(item: item)
                            }
                        }
                    }
                }
            }
        }
    }

    private static func normalizedIngredientKey(_ value: String) -> String {
        value
            .lowercased()
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func bestMatchingRecipeIngredientRow(
        for ingredientNames: [String],
        rows: [SupabaseRecipeIngredientRow]
    ) -> SupabaseRecipeIngredientRow? {
        guard !rows.isEmpty else { return nil }

        let normalizedIngredientNames = ingredientNames
            .map(Self.normalizedIngredientKey)
            .filter { !$0.isEmpty }
        guard !normalizedIngredientNames.isEmpty else { return nil }

        if let exactMatch = rows.first(where: { row in
            let key = Self.normalizedIngredientKey(row.displayTitle)
            return normalizedIngredientNames.contains(key)
        }) {
            return exactMatch
        }

        return rows
            .compactMap { row -> (SupabaseRecipeIngredientRow, Int)? in
                let score = ingredientNames.reduce(0) { partialResult, name in
                    max(partialResult, ingredientSimilarityScore(lhs: name, rhs: row.displayTitle))
                } + (row.imageURL == nil ? 0 : 6)
                return score > 0 ? (row, score) : nil
            }
            .sorted { lhs, rhs in
                if lhs.1 == rhs.1 {
                    return (lhs.0.sortOrder ?? .max, lhs.0.id) < (rhs.0.sortOrder ?? .max, rhs.0.id)
                }
                return lhs.1 > rhs.1
            }
            .first?
            .0
    }

    private func ingredientSimilarityScore(lhs: String, rhs: String) -> Int {
        let lhsKey = Self.normalizedIngredientKey(lhs)
        let rhsKey = Self.normalizedIngredientKey(rhs)

        guard !lhsKey.isEmpty, !rhsKey.isEmpty else { return 0 }
        if lhsKey == rhsKey { return 100 }
        if lhsKey.contains(rhsKey) || rhsKey.contains(lhsKey) { return 80 }

        let lhsTokenList = lhsKey.split(separator: " ").map(String.init)
        let rhsTokenList = rhsKey.split(separator: " ").map(String.init)
        let lhsTokens = Set(lhsTokenList)
        let rhsTokens = Set(rhsTokenList)
        let overlap = lhsTokens.intersection(rhsTokens).count
        guard overlap > 0 else { return 0 }

        var score = overlap * 20
        if lhsTokenList.last == rhsTokenList.last {
            score += 25
        }

        return score
    }

    private func buildCartDisplayItems(
        from groceryItems: [GroceryItem],
        ingredientRows: [SupabaseRecipeIngredientRow]
    ) -> [CartGroceryDisplayItem] {
        let rowsByRecipeID = Dictionary(grouping: ingredientRows, by: \.recipeID)

        return groceryItems
            .map { item in
                let matchedRows = item.sourceIngredients.compactMap { source in
                    bestMatchingRecipeIngredientRow(
                        for: [source.ingredientName, item.name],
                        rows: rowsByRecipeID[source.recipeID] ?? []
                    )
                }

                let primaryMatch = matchedRows.first(where: { $0.imageURL != nil }) ?? matchedRows.first
                let displayName = resolvedCartDisplayName(itemName: item.name, matchedRows: matchedRows)
                let imageURL = primaryMatch?.imageURL

                return CartGroceryDisplayItem(
                    name: displayName,
                    quantityText: CartQuantityFormatter.format(amount: item.amount, unit: item.unit),
                    supportingText: nil,
                    imageURL: imageURL,
                    estimatedPriceText: item.estimatedPrice.asCurrency,
                    estimatedPriceValue: item.estimatedPrice
                )
            }
            .sorted { lhs, rhs in
                lhs.estimatedPriceValue > rhs.estimatedPriceValue
            }
    }

    private func buildReconciledCartDisplayItems(
        from groceryItems: [GroceryItem],
        ingredientRows: [SupabaseRecipeIngredientRow]
    ) -> [ReconciledCartSection] {
        let graph = buildBoxedCartGraph(from: groceryItems, ingredientRows: ingredientRows)
        let entries = graph.nodes.map { aggregate in
            let packaged = reconciledQuantity(
                for: aggregate.displayName,
                amount: aggregate.amount,
                unit: aggregate.unit,
                sourceCount: aggregate.sourceUseCount,
                recipeCount: aggregate.recipeIDs.count,
                isPantryStaple: aggregate.isPantryStaple,
                isOptional: aggregate.isOptional,
                packageRule: aggregate.packageRule
            )

            return (
                aggregate.category.sectionKind,
                CartGroceryDisplayItem(
                    name: aggregate.displayName,
                    quantityText: packaged.quantityText,
                    supportingText: packaged.supportingText,
                    imageURL: aggregate.imageURL,
                    estimatedPriceText: nil,
                    estimatedPriceValue: 0
                )
            )
        }

        let grouped = Dictionary(grouping: entries, by: \.0)
        return ReconciledCartSectionKind.allCases.compactMap { kind in
            guard let items = grouped[kind]?.map(\.1), !items.isEmpty else { return nil }
            return ReconciledCartSection(
                kind: kind,
                items: items.sorted {
                    $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                }
            )
        }
    }

    private func buildReconciledCartDisplayItems(
        from shoppingSpecItems: [GroceryShoppingSpecResponse.ShoppingSpecItem],
        ingredientRows: [SupabaseRecipeIngredientRow]
    ) -> [ReconciledCartSection] {
        let rowsByRecipeID = Dictionary(grouping: ingredientRows, by: \.recipeID)

        let entries = shoppingSpecItems.map { item in
            let matchedRows = item.sourceIngredients.compactMap { source in
                bestMatchingRecipeIngredientRow(
                    for: [source.ingredientName, item.canonicalName ?? item.name, item.name],
                    rows: rowsByRecipeID[source.recipeID] ?? []
                )
            }

            let primaryMatch = matchedRows.first(where: { $0.imageURL != nil }) ?? matchedRows.first
            let displayName = prettyShoppingName(item.shoppingContext?.canonicalName ?? item.canonicalName ?? item.name)
            let role = item.shoppingContext?.role ?? "ingredient"
            let isPantryStaple = item.shoppingContext?.isPantryStaple ?? false
            let isOptional = item.shoppingContext?.isOptional ?? false
            let category = reconciledCategory(
                for: displayName,
                role: role,
                isPantryStaple: isPantryStaple,
                isOptional: isOptional,
                combinedContext: [
                    role,
                    item.shoppingContext?.canonicalName,
                    item.shoppingContext?.sourceIngredientNames.joined(separator: " "),
                    item.shoppingContext?.neighborIngredients.joined(separator: " ")
                ]
                .compactMap { $0 }
                .joined(separator: " ")
            )

            let quantityText = CartQuantityFormatter.format(amount: item.amount, unit: item.unit)
            let sourceUseCount = max(
                1,
                Set(item.sourceIngredients.map {
                    "\(Self.normalizedIngredientKey($0.recipeID))::\(Self.normalizedIngredientKey($0.ingredientName))::\($0.unit.lowercased())"
                }).count
            )
            let recipeTitles = Set((item.shoppingContext?.recipeTitles ?? []) + item.sourceRecipes)
            let recipeCount = recipeTitles.count

            var supportingParts: [String] = []
            supportingParts.append(contentsOf: coverageSupportingParts(sourceUseCount: sourceUseCount, recipeCount: recipeCount))
            if isPantryStaple {
                supportingParts.append("Pantry check")
            }
            if isOptional {
                supportingParts.append("Optional")
            }

            return (
                category.sectionKind,
                CartGroceryDisplayItem(
                    name: displayName,
                    quantityText: quantityText,
                    supportingText: supportingParts.isEmpty ? nil : supportingParts.joined(separator: " • "),
                    imageURL: primaryMatch?.imageURL,
                    estimatedPriceText: nil,
                    estimatedPriceValue: 0
                )
            )
        }

        let grouped = Dictionary(grouping: entries, by: \.0)
        return ReconciledCartSectionKind.allCases.compactMap { kind in
            guard let items = grouped[kind]?.map(\.1), !items.isEmpty else { return nil }
            return ReconciledCartSection(
                kind: kind,
                items: items.sorted {
                    $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                }
            )
        }
    }

    private func packageRule(
        for ingredientName: String,
        unit: String,
        category: ReconciledShoppingCategory
    ) -> ReconciledPackageRule? {
        let normalizedName = Self.normalizedIngredientKey(ingredientName)

        if normalizedName.contains("egg") {
            return ReconciledPackageRule(packageSize: 12, singularLabel: "carton", pluralLabel: "cartons")
        }
        if normalizedName.contains("rice") {
            return ReconciledPackageRule(packageSize: 4, singularLabel: "bag", pluralLabel: "bags")
        }
        if normalizedName.contains("flour") || normalizedName.contains("sugar") {
            return ReconciledPackageRule(packageSize: 3, singularLabel: "bag", pluralLabel: "bags")
        }
        if normalizedName.contains("milk")
            || normalizedName.contains("cream")
            || normalizedName.contains("broth")
            || normalizedName.contains("stock") {
            return ReconciledPackageRule(packageSize: 1, singularLabel: "carton", pluralLabel: "cartons")
        }
        if normalizedName.contains("yogurt") {
            return ReconciledPackageRule(packageSize: 1, singularLabel: "tub", pluralLabel: "tubs")
        }
        if normalizedName.contains("cheese") {
            return ReconciledPackageRule(packageSize: 1, singularLabel: "pack", pluralLabel: "packs")
        }
        if normalizedName.contains("seasoning")
            || normalizedName.contains("pepper")
            || normalizedName.contains("cinnamon")
            || normalizedName.contains("baking powder")
            || normalizedName.contains("bouillon")
            || normalizedName.contains("curry powder")
            || normalizedName.contains("paprika") {
            return ReconciledPackageRule(packageSize: 1, singularLabel: "jar", pluralLabel: "jars")
        }
        if normalizedName.contains("dressing")
            || normalizedName.contains("sauce")
            || normalizedName.contains("juice") {
            return ReconciledPackageRule(packageSize: 1, singularLabel: "bottle", pluralLabel: "bottles")
        }
        if normalizedName.contains("beans") || normalizedName.contains("tomatoes") {
            return ReconciledPackageRule(packageSize: 1, singularLabel: "can", pluralLabel: "cans")
        }
        if normalizedName.contains("chips") {
            return ReconciledPackageRule(packageSize: 1, singularLabel: "bag", pluralLabel: "bags")
        }
        if normalizedName.contains("cilantro")
            || normalizedName.contains("parsley")
            || normalizedName.contains("green onions")
            || normalizedName.contains("scallions") {
            return ReconciledPackageRule(packageSize: 1, singularLabel: "bunch", pluralLabel: "bunches")
        }
        if normalizedName.contains("romaine")
            || normalizedName.contains("lettuce")
            || normalizedName.contains("greens") {
            return ReconciledPackageRule(packageSize: 1, singularLabel: "head", pluralLabel: "heads")
        }
        if category == .tool {
            return ReconciledPackageRule(packageSize: 1, singularLabel: "pack", pluralLabel: "packs")
        }
        if ["lb", "lbs", "kg"].contains(unit.lowercased()) {
            return ReconciledPackageRule(packageSize: 2, singularLabel: "pack", pluralLabel: "packs")
        }
        return nil
    }

    private func reconciledCategory(
        displayName: String,
        combinedContext: String,
        isPantryStaple: Bool,
        isOptional: Bool
    ) -> ReconciledShoppingCategory {
        let normalizedName = Self.normalizedIngredientKey(displayName)
        if isOptional { return .optional }
        if isPantryStaple { return .pantry }
        if combinedContext.contains("sauce")
            || combinedContext.contains("dressing")
            || combinedContext.contains("marinade")
            || combinedContext.contains("dip") {
            return .prepared
        }
        if normalizedName.contains("skewer") || normalizedName.contains("toothpick") {
            return .tool
        }
        if normalizedName.contains("chicken")
            || normalizedName.contains("shrimp")
            || normalizedName.contains("salmon")
            || normalizedName.contains("steak")
            || normalizedName.contains("egg") {
            return .protein
        }
        if normalizedName.contains("cheese")
            || normalizedName.contains("yogurt")
            || normalizedName.contains("milk")
            || normalizedName.contains("cream") {
            return .dairy
        }
        if normalizedName.contains("rice")
            || normalizedName.contains("flour")
            || normalizedName.contains("sugar")
            || normalizedName.contains("chips")
            || normalizedName.contains("beans")
            || normalizedName.contains("stock")
            || normalizedName.contains("broth") {
            return .dryGoods
        }
        if normalizedName.contains("romaine")
            || normalizedName.contains("greens")
            || normalizedName.contains("lettuce")
            || normalizedName.contains("cilantro")
            || normalizedName.contains("green onions")
            || normalizedName.contains("scallions")
            || normalizedName.contains("jalape")
            || normalizedName.contains("garlic")
            || normalizedName.contains("carrot")
            || normalizedName.contains("cucumber")
            || normalizedName.contains("apple")
            || normalizedName.contains("avocado")
            || normalizedName.contains("blueberr")
            || normalizedName.contains("broccoli")
            || normalizedName.contains("tomato") {
            return .produce
        }
        return .main
    }

    private func reconciledCategory(
        for displayName: String,
        role: String,
        isPantryStaple: Bool,
        isOptional: Bool,
        combinedContext: String
    ) -> ReconciledShoppingCategory {
        if isOptional { return .optional }
        if isPantryStaple { return .pantry }

        switch role.lowercased() {
        case "protein":
            return .protein
        case "dairy":
            return .dairy
        case "sauce":
            return .prepared
        case "wrapper", "pantry":
            return .dryGoods
        case "fresh garnish", "salad base":
            return .produce
        case "cooking tool":
            return .tool
        default:
            return reconciledCategory(
                displayName: displayName,
                combinedContext: combinedContext,
                isPantryStaple: isPantryStaple,
                isOptional: isOptional
            )
        }
    }

    private func prettyShoppingName(_ rawName: String) -> String {
        rawName
            .split(separator: " ")
            .map { token in
                let lowered = token.lowercased()
                return ["bbq", "caesar"].contains(lowered) ? lowered.uppercased() : lowered.capitalized
            }
            .joined(separator: " ")
    }

    private func buildBoxedCartGraph(
        from groceryItems: [GroceryItem],
        ingredientRows: [SupabaseRecipeIngredientRow]
    ) -> BoxedCartGraph {
        let rowsByRecipeID = Dictionary(grouping: ingredientRows, by: \.recipeID)
        var nodesByKey: [String: BoxedCartNode] = [:]
        var totalDemandIDs = Set<String>()
        var coveredDemandIDs = Set<String>()
        var uncoveredBaseLabels: [String] = []

        for item in groceryItems {
            let matchedRows = item.sourceIngredients.compactMap { source in
                bestMatchingRecipeIngredientRow(
                    for: [source.ingredientName, item.name],
                    rows: rowsByRecipeID[source.recipeID] ?? []
                )
            }
            let primaryMatch = matchedRows.first(where: { $0.imageURL != nil }) ?? matchedRows.first
            let displayName = resolvedCartDisplayName(itemName: item.name, matchedRows: matchedRows)
            let sourceEdges = item.sourceIngredients.map {
                BoxedCartSourceEdge(recipeID: $0.recipeID, ingredientName: $0.ingredientName, unit: $0.unit)
            }
            let demandIDs = baseDemandIdentifiers(for: item, sourceEdges: sourceEdges)
            totalDemandIDs.formUnion(demandIDs)

            let components = deconstructedBoxedComponents(
                for: item,
                displayName: displayName,
                imageURL: primaryMatch?.imageURL,
                sourceEdges: sourceEdges,
                demandIDs: demandIDs
            )

            guard !components.isEmpty else {
                uncoveredBaseLabels.append(item.name)
                continue
            }

            coveredDemandIDs.formUnion(demandIDs)

            for component in components {
                let key = Self.normalizedIngredientKey(component.displayName)
                guard !key.isEmpty else { continue }

                if var existing = nodesByKey[key] {
                    let mergedBaseNames = existing.baseItemNames.union(component.baseItemNames)
                    let mergedPantry = existing.isPantryStaple || component.isPantryStaple
                    let mergedOptional = existing.isOptional && component.isOptional
                    let mergedContext = mergedBaseNames
                        .map(Self.normalizedIngredientKey)
                        .joined(separator: " ")
                    existing.amount += component.amount
                    if existing.imageURL == nil {
                        existing.imageURL = component.imageURL
                    }
                    existing.baseItemNames = mergedBaseNames
                    existing.sourceEdges.formUnion(component.sourceEdges)
                    existing.recipeIDs.formUnion(component.recipeIDs)
                    existing.demandIDs.formUnion(component.demandIDs)
                    existing.isPantryStaple = mergedPantry
                    existing.isOptional = mergedOptional
                    existing.category = reconciledCategory(
                        displayName: existing.displayName,
                        combinedContext: mergedContext,
                        isPantryStaple: mergedPantry,
                        isOptional: mergedOptional
                    )
                    existing.packageRule = packageRule(
                        for: existing.displayName,
                        unit: existing.unit,
                        category: existing.category
                    )
                    nodesByKey[key] = existing
                } else {
                    nodesByKey[key] = component
                }
            }
        }

        return BoxedCartGraph(
            nodes: Array(nodesByKey.values),
            coverageSummary: BoxedCartCoverageSummary(
                totalBaseUses: totalDemandIDs.count,
                accountedBaseUses: coveredDemandIDs.count,
                uncoveredBaseLabels: uncoveredBaseLabels
            )
        )
    }

    private func baseDemandIdentifiers(
        for item: GroceryItem,
        sourceEdges: [BoxedCartSourceEdge]
    ) -> Set<String> {
        let identifiers = sourceEdges.map {
            "\(Self.normalizedIngredientKey($0.recipeID))::\(Self.normalizedIngredientKey($0.ingredientName))::\($0.unit.lowercased())"
        }
        if identifiers.isEmpty {
            return ["fallback::\(item.id)::\(CartQuantityFormatter.format(amount: item.amount, unit: item.unit))"]
        }
        return Set(identifiers)
    }

    private func deconstructedBoxedComponents(
        for item: GroceryItem,
        displayName: String,
        imageURL: URL?,
        sourceEdges: [BoxedCartSourceEdge],
        demandIDs: Set<String>
    ) -> [BoxedCartNode] {
        let normalizedDisplayName = Self.normalizedIngredientKey(displayName)
        let normalizedSourceNames = sourceEdges
            .map(\.ingredientName)
            .map(Self.normalizedIngredientKey)
        let combinedContext = ([normalizedDisplayName] + normalizedSourceNames)
            .joined(separator: " ")
        let recipeIDs = Set(sourceEdges.map(\.recipeID))
        let baseItemNames = Set([displayName, item.name])
        let optional = combinedContext.contains("optional")
        let pantryStaple = [
            "salt",
            "black pepper",
            "olive oil",
            "garlic powder",
            "onion powder",
            "paprika",
            "cinnamon",
            "baking powder",
            "bouillon powder",
            "curry powder",
        ].contains(where: { combinedContext.contains($0) || normalizedDisplayName.contains($0) })

        func component(
            name: String,
            amount: Double = item.amount,
            unit: String = item.unit,
            imageURL: URL? = imageURL,
            isPantryStaple: Bool = false,
            isOptional: Bool = false,
            category: ReconciledShoppingCategory? = nil
        ) -> BoxedCartNode {
            let resolvedName = prettyShoppingName(name)
            let resolvedCategory = category ?? reconciledCategory(
                displayName: resolvedName,
                combinedContext: combinedContext,
                isPantryStaple: isPantryStaple,
                isOptional: isOptional
            )
            return BoxedCartNode(
                displayName: resolvedName,
                amount: amount,
                unit: unit,
                imageURL: imageURL,
                baseItemNames: baseItemNames,
                sourceEdges: Set(sourceEdges),
                recipeIDs: recipeIDs,
                demandIDs: demandIDs,
                isPantryStaple: isPantryStaple,
                isOptional: isOptional,
                category: resolvedCategory,
                packageRule: packageRule(for: resolvedName, unit: unit, category: resolvedCategory)
            )
        }

        if combinedContext.contains("buffalo chicken") {
            let primaryChickenName = combinedContext.contains("thigh") ? "Chicken Thighs" : "Chicken Breast"
            return [
                component(name: primaryChickenName, category: .protein),
                component(name: "Buffalo Sauce", amount: 1, unit: "bottle", imageURL: nil, category: .prepared)
            ]
        }

        if combinedContext.contains("shredded chicken breast")
            || combinedContext.contains("cooked chicken breast")
            || combinedContext.contains("chicken breast") {
            return [component(name: "Chicken Breast")]
        }

        if combinedContext.contains("shredded chicken")
            || combinedContext.contains("cooked chicken")
            || combinedContext.contains("pulled chicken") {
            return [component(name: "Chicken Breast")]
        }

        if combinedContext.contains("chicken thighs") || combinedContext.contains("chicken thigh") {
            return [component(name: "Chicken Thighs", category: .protein)]
        }

        if combinedContext.contains("cooked jasmine rice") || combinedContext.contains("jasmine rice") {
            return [component(name: "Jasmine Rice", category: .dryGoods)]
        }

        if combinedContext.contains("cooked rice") {
            return [component(name: "Rice", category: .dryGoods)]
        }

        if combinedContext.contains("crispy romaine") || combinedContext.contains("romaine") {
            return [component(name: "Romaine Lettuce", category: .produce)]
        }

        return [component(name: displayName, isPantryStaple: pantryStaple, isOptional: optional)]
    }

    private func reconciledQuantity(
        for ingredientName: String,
        amount: Double,
        unit: String,
        sourceCount: Int,
        recipeCount: Int,
        isPantryStaple: Bool,
        isOptional: Bool,
        packageRule: ReconciledPackageRule?
    ) -> (quantityText: String, supportingText: String?) {
        let supportingParts = {
            var parts: [String] = []
            parts.append(contentsOf: coverageSupportingParts(sourceUseCount: sourceCount, recipeCount: recipeCount))
            if isPantryStaple {
                parts.append("Pantry check")
            }
            if isOptional {
                parts.append("Optional")
            }
            return parts
        }()
        let supportingText = supportingParts.isEmpty ? nil : supportingParts.joined(separator: " • ")

        guard let rule = packageRule else {
            return (CartQuantityFormatter.format(amount: amount, unit: unit), supportingText)
        }

        let packageCount = max(1, Int(ceil(amount / rule.packageSize)))
        let label = packageCount == 1 ? rule.singularLabel : rule.pluralLabel
        return ("\(packageCount) \(label)", supportingText)
    }

    private func resolvedCartDisplayName(
        itemName: String,
        matchedRows: [SupabaseRecipeIngredientRow]
    ) -> String {
        let trimmedItemName = itemName.trimmingCharacters(in: .whitespacesAndNewlines)
        let matchedTitles = matchedRows
            .map(\.displayTitle)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard let richestTitle = matchedTitles.max(by: { lhs, rhs in
            let lhsScore = ingredientDisplayScore(lhs)
            let rhsScore = ingredientDisplayScore(rhs)
            if lhsScore == rhsScore {
                return lhs.count < rhs.count
            }
            return lhsScore < rhsScore
        }) else {
            return trimmedItemName
        }

        return ingredientDisplayScore(richestTitle) >= ingredientDisplayScore(trimmedItemName)
            ? richestTitle
            : trimmedItemName
    }

    private func ingredientDisplayScore(_ name: String) -> Int {
        let normalized = Self.normalizedIngredientKey(name)
        guard !normalized.isEmpty else { return 0 }

        let tokenCount = normalized.split(separator: " ").count
        let abbreviationPenalty = normalized.count <= 3 ? 50 : 0
        return tokenCount * 20 + normalized.count - abbreviationPenalty
    }

    private func coverageSupportingParts(sourceUseCount: Int, recipeCount: Int) -> [String] {
        switch (sourceUseCount > 1, recipeCount > 1) {
        case (_, true):
            return ["Used in \(recipeCount) recipes"]
        case (true, false):
            return ["Used \(sourceUseCount)x in this prep"]
        case (false, false):
            return []
        }
    }

    private func reloadCartIngredients() async {
        guard let latestPlan = store.latestPlan, !latestPlan.recipes.isEmpty else {
            ingredientRows = []
            ingredientLoadError = nil
            cartDisplayItems = []
            reconciledCartItems = []
            reconciledCartSections = []
            boxedCartCoverageSummary = nil
            focusedRecipeID = nil
            return
        }

        isLoadingIngredients = true
        ingredientLoadError = nil
        defer { isLoadingIngredients = false }

        do {
            let rows = try await buildPrepRecipeIngredientRows(from: latestPlan.recipes)
            ingredientRows = rows
            cartDisplayItems = buildCartDisplayItems(
                from: latestPlan.groceryItems,
                ingredientRows: rows
            )

            if let shoppingSpec = try? await GroceryService.shared.fetchShoppingSpec(items: latestPlan.groceryItems) {
                boxedCartCoverageSummary = BoxedCartCoverageSummary(
                    totalBaseUses: shoppingSpec.coverageSummary.totalBaseUses,
                    accountedBaseUses: shoppingSpec.coverageSummary.accountedBaseUses,
                    uncoveredBaseLabels: shoppingSpec.coverageSummary.uncoveredBaseLabels
                )
                reconciledCartSections = buildReconciledCartDisplayItems(
                    from: shoppingSpec.items,
                    ingredientRows: rows
                )
                reconciledCartItems = reconciledCartSections.flatMap(\.items)
            } else {
                let boxedGraph = buildBoxedCartGraph(
                    from: latestPlan.groceryItems,
                    ingredientRows: rows
                )
                boxedCartCoverageSummary = boxedGraph.coverageSummary
                reconciledCartSections = buildReconciledCartDisplayItems(
                    from: latestPlan.groceryItems,
                    ingredientRows: rows
                )
                reconciledCartItems = reconciledCartSections.flatMap(\.items)
            }
        } catch {
            ingredientLoadError = error.localizedDescription
            ingredientRows = []
            cartDisplayItems = []
            reconciledCartItems = []
            reconciledCartSections = []
            boxedCartCoverageSummary = nil
        }
    }

    private func buildPrepRecipeIngredientRows(from recipes: [PlannedRecipe]) async throws -> [SupabaseRecipeIngredientRow] {
        var rows: [SupabaseRecipeIngredientRow] = []

        for plannedRecipe in recipes {
            let detail = try await RecipeDetailService.shared.fetchRecipeDetail(id: plannedRecipe.recipe.id)
            let scaledIngredients = prepRecipeIngredients(from: detail, servings: plannedRecipe.servings)

            let detailRows = scaledIngredients.enumerated().map { index, ingredient in
                let preferredID = ingredient.id?.trimmingCharacters(in: .whitespacesAndNewlines)
                let preferredResolvedID = (preferredID?.isEmpty == false) ? preferredID : nil
                let ingredientResolvedID = ingredient.ingredientID?.trimmingCharacters(in: .whitespacesAndNewlines)
                let resolvedID = preferredResolvedID ?? ingredientResolvedID ?? String(index)
                return SupabaseRecipeIngredientRow(
                    id: "\(plannedRecipe.recipe.id)::detail::\(resolvedID)",
                    recipeID: plannedRecipe.recipe.id,
                    ingredientID: ingredient.ingredientID,
                    displayName: ingredient.displayTitle,
                    quantityText: ingredient.displayQuantityText ?? "",
                    imageURLString: ingredient.imageURLString,
                    sortOrder: ingredient.sortOrder ?? index
                )
            }

            rows.append(contentsOf: detailRows)
        }

        return rows
    }

    private func prepRecipeIngredients(from detail: RecipeDetailData, servings: Int) -> [RecipeDetailIngredient] {
        let baseIngredients: [RecipeDetailIngredient]
        if !detail.ingredients.isEmpty {
            baseIngredients = detail.ingredients
        } else {
            var seen = Set<String>()
            baseIngredients = detail.steps
                .flatMap(\.ingredients)
                .filter { ingredient in
                    let key = Self.normalizedIngredientKey(ingredient.displayTitle)
                    guard !key.isEmpty else { return false }
                    return seen.insert(key).inserted
                }
        }

        let scale = Double(max(1, servings)) / Double(max(1, detail.displayServings))
        return baseIngredients.map { $0.scaled(by: scale) }
    }
}

private struct CartGroceryDisplayItem: Identifiable, Hashable {
    var id: String { "\(name.lowercased())::\(quantityText)::\(supportingText ?? "")" }
    let name: String
    let quantityText: String
    let supportingText: String?
    let imageURL: URL?
    let estimatedPriceText: String?
    let estimatedPriceValue: Double
}

private struct BoxedCartSourceEdge: Hashable {
    let recipeID: String
    let ingredientName: String
    let unit: String
}

private struct BoxedCartNode: Hashable {
    let displayName: String
    var amount: Double
    var unit: String
    var imageURL: URL?
    var baseItemNames: Set<String>
    var sourceEdges: Set<BoxedCartSourceEdge>
    var recipeIDs: Set<String>
    var demandIDs: Set<String>
    var isPantryStaple: Bool
    var isOptional: Bool
    var category: ReconciledShoppingCategory
    var packageRule: ReconciledPackageRule?

    var sourceUseCount: Int {
        max(1, demandIDs.count)
    }
}

private struct BoxedCartCoverageSummary: Hashable {
    let totalBaseUses: Int
    let accountedBaseUses: Int
    let uncoveredBaseLabels: [String]

    var isFullyAccountedFor: Bool {
        totalBaseUses == accountedBaseUses && uncoveredBaseLabels.isEmpty
    }
}

private struct BoxedCartGraph: Hashable {
    let nodes: [BoxedCartNode]
    let coverageSummary: BoxedCartCoverageSummary
}

private struct ReconciledPackageRule: Hashable {
    let packageSize: Double
    let singularLabel: String
    let pluralLabel: String
}

private enum ReconciledShoppingCategory: String, Hashable {
    case main
    case protein
    case produce
    case dairy
    case dryGoods
    case prepared
    case pantry
    case optional
    case tool

    var sectionKind: ReconciledCartSectionKind {
        switch self {
        case .protein, .produce, .dairy, .main:
            return .mainShop
        case .dryGoods:
            return .dryGoods
        case .prepared:
            return .prepared
        case .pantry:
            return .pantry
        case .optional:
            return .optional
        case .tool:
            return .tools
        }
    }
}

private enum ReconciledCartSectionKind: Int, CaseIterable, Identifiable {
    case mainShop
    case dryGoods
    case prepared
    case pantry
    case optional
    case tools

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .mainShop: return "Main shop"
        case .dryGoods: return "Dry goods"
        case .prepared: return "Sauces & prepared"
        case .pantry: return "Pantry check"
        case .optional: return "Optional extras"
        case .tools: return "Kitchen extras"
        }
    }

    var subtitle: String? {
        switch self {
        case .mainShop:
            return "What you actually need to buy for this prep."
        case .dryGoods:
            return "Shelf-stable staples grouped into real units."
        case .prepared:
            return "Sauces, dressings, and ready-made parts."
        case .pantry:
            return "Check these at home before you buy again."
        case .optional:
            return "Nice-to-haves that should not block the batch."
        case .tools:
            return "Non-ingredient kitchen extras."
        }
    }
}

private struct ReconciledCartSection: Identifiable, Hashable {
    let kind: ReconciledCartSectionKind
    let items: [CartGroceryDisplayItem]

    var id: ReconciledCartSectionKind { kind }
    var title: String { kind.title }
    var subtitle: String? { kind.subtitle }
}

private struct CartReconciledCoverageNotice: View {
    let summary: BoxedCartCoverageSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Some recipe uses still need review.")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(OunjePalette.primaryText)

            if summary.uncoveredBaseLabels.isEmpty {
                Text("We accounted for \(summary.accountedBaseUses) of \(summary.totalBaseUses) base uses.")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(OunjePalette.secondaryText)
            } else {
                Text("Uncovered ingredients: \(summary.uncoveredBaseLabels.prefix(3).joined(separator: ", "))")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(OunjePalette.secondaryText)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 4)
    }
}

private struct CartEmptyState: View {
    let onBrowseDiscover: () -> Void

    var body: some View {
        VStack(spacing: 22) {
            Image("CartEmptyIllustrationLight")
                .renderingMode(.original)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(maxWidth: 236)
                .opacity(0.92)
                .padding(.top, 8)

            VStack(spacing: 8) {
                BiroScriptDisplayText(
                    "Nothing in cart",
                    size: 28,
                    color: OunjePalette.primaryText
                )

                Text("Browse recipes and saved meals will build the ingredient shelves here.")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(OunjePalette.secondaryText)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: 290)

            Button(action: onBrowseDiscover) {
                Text("Browse Discover")
                    .biroHeaderFont(15)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(SecondaryPillButtonStyle())
            .frame(maxWidth: 248)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 12)
        .padding(.vertical, 28)
    }
}

private struct CartLoadingState: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 12) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(OunjePalette.surface.opacity(0.95))
                    .frame(width: 148, height: 18)
                    .redacted(reason: .placeholder)

                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(OunjePalette.surface.opacity(0.9))
                    .frame(height: 168)
                    .redacted(reason: .placeholder)
            }

            VStack(alignment: .leading, spacing: 12) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(OunjePalette.surface.opacity(0.95))
                    .frame(width: 174, height: 18)
                    .redacted(reason: .placeholder)

                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(OunjePalette.surface.opacity(0.9))
                    .frame(height: 124)
                    .redacted(reason: .placeholder)
            }
        }
    }
}

private struct DiscoverShortcut: Identifiable {
    let id = UUID()
    let title: String
    let subtitle: String
    let symbolName: String
    let accent: Color
    let action: () -> Void
}

private struct DiscoverHubCard: View {
    let shortcut: DiscoverShortcut

    @State private var isAnimating = false

    var body: some View {
        Button(action: shortcut.action) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(shortcut.title)
                        .biroHeaderFont(24)
                        .foregroundStyle(OunjePalette.primaryText)
                        .fixedSize(horizontal: false, vertical: true)

                    Spacer(minLength: 8)

                    Image(systemName: shortcut.symbolName)
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(shortcut.accent)
                        .scaleEffect(isAnimating ? 1.08 : 0.95)
                }

                Text(shortcut.subtitle)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(OunjePalette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 0)

                HStack {
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 16, weight: .black))
                        .foregroundStyle(OunjePalette.secondaryText.opacity(0.5))
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, minHeight: 144, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                OunjePalette.surface,
                                shortcut.accent.opacity(0.07)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .stroke(OunjePalette.stroke, lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
        .onAppear {
            withAnimation(.easeInOut(duration: 3.2).repeatForever(autoreverses: true)) {
                isAnimating = true
            }
        }
    }
}

private struct CookbookSectionTabItem: Identifiable {
    let section: CookbookSection

    var id: CookbookSection { section }
}

private struct CookbookSectionTabs: View {
    @Binding var selection: CookbookSection
    let tabs: [CookbookSectionTabItem]

    var body: some View {
        GeometryReader { proxy in
            let tabWidth = proxy.size.width / CGFloat(max(tabs.count, 1))

            VStack(spacing: 10) {
                HStack(spacing: 0) {
                    ForEach(tabs) { tab in
                        let isSelected = selection == tab.section

                        Button {
                            withAnimation(.spring(response: 0.32, dampingFraction: 0.84)) {
                                selection = tab.section
                            }
                        } label: {
                            Text(tab.section.title)
                                .sleeDisplayFont(isSelected ? 22 : 20)
                                .foregroundStyle(isSelected ? OunjePalette.primaryText : OunjePalette.secondaryText.opacity(0.94))
                                .opacity(isSelected ? 1 : 0.76)
                                .frame(maxWidth: .infinity)
                                .frame(height: 30, alignment: .center)
                                .padding(.vertical, 2)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }

                ZStack(alignment: .leading) {
                    Capsule(style: .continuous)
                        .fill(.white.opacity(0.08))
                        .frame(height: 1.5)

                    Capsule(style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    OunjePalette.softCream.opacity(0.95),
                                    OunjePalette.accent.opacity(0.72)
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: max(tabWidth - 28, 72), height: 3)
                        .offset(x: indicatorOffset(tabWidth: tabWidth))
                        .shadow(color: OunjePalette.accent.opacity(0.18), radius: 8, y: 2)
                }
            }
        }
        .frame(height: 40)
    }

    private func indicatorOffset(tabWidth: CGFloat) -> CGFloat {
        let index = tabs.firstIndex { $0.section == selection } ?? 0
        return CGFloat(index) * tabWidth + 14
    }
}

private struct FilterTagButton: View {
    let title: String
    let isSelected: Bool
    let accent: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .foregroundStyle(isSelected ? OunjePalette.softCream : OunjePalette.primaryText)
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .background(
                    Capsule(style: .continuous)
                        .fill(isSelected ? OunjePalette.surface : OunjePalette.elevated)
                        .overlay(
                            Capsule(style: .continuous)
                                .stroke(isSelected ? accent.opacity(0.55) : OunjePalette.stroke, lineWidth: 1)
                        )
                )
        }
        .buttonStyle(.plain)
    }
}

private struct DiscoverPresetTextButton: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                SleeScriptDisplayText(
                    title,
                    size: isSelected ? 20 : 18,
                    color: isSelected ? OunjePalette.softCream : OunjePalette.secondaryText.opacity(0.96)
                )
                .lineLimit(1)
                .minimumScaleFactor(0.9)

                Capsule(style: .continuous)
                    .fill(isSelected ? OunjePalette.accent : Color.clear)
                    .frame(width: isSelected ? 34 : 22, height: 3)
                    .overlay(
                        Capsule(style: .continuous)
                            .fill(OunjePalette.accent.opacity(isSelected ? 0.28 : 0))
                            .blur(radius: 5)
                    )
            }
            .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
    }
}

private struct InlineSearchBar: View {
    @Binding var text: String
    let placeholder: String
    var activeFilterLabel: String? = nil
    var onFilterTap: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(OunjePalette.secondaryText)

            TextField("", text: $text, prompt: Text(placeholder).foregroundColor(OunjePalette.secondaryText))
                .font(.system(size: 17, weight: .medium, design: .rounded))
                .foregroundStyle(OunjePalette.primaryText)

            Button(action: { onFilterTap?() }) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(activeFilterLabel == nil ? OunjePalette.secondaryText : OunjePalette.softCream)

                    if activeFilterLabel != nil {
                        Circle()
                            .fill(OunjePalette.accent)
                            .frame(width: 8, height: 8)
                            .offset(x: 4, y: -2)
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(onFilterTap == nil)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(OunjePalette.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(OunjePalette.stroke, lineWidth: 1)
                )
        )
    }
}

private struct CollapsibleSavedSearchBar: View {
    @Binding var text: String
    let placeholder: String
    @Binding var isExpanded: Bool
    @FocusState private var isFocused: Bool

    private var hasQuery: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        Group {
            if isExpanded || hasQuery {
                HStack(spacing: 10) {
                    HStack(spacing: 12) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(OunjePalette.secondaryText)

                        TextField("", text: $text, prompt: Text(placeholder).foregroundColor(OunjePalette.secondaryText))
                            .font(.system(size: 16, weight: .medium, design: .rounded))
                            .foregroundStyle(OunjePalette.primaryText)
                            .focused($isFocused)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 13)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(OunjePalette.surface)
                            .overlay(
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .stroke(OunjePalette.stroke, lineWidth: 1)
                            )
                    )

                    Button {
                        text = ""
                        withAnimation(.easeInOut(duration: 0.18)) {
                            isExpanded = false
                        }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(OunjePalette.secondaryText)
                            .frame(width: 36, height: 36)
                    }
                    .buttonStyle(.plain)
                }
                .onAppear {
                    DispatchQueue.main.async {
                        isFocused = true
                    }
                }
            } else {
                HStack {
                    Spacer(minLength: 0)

                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            isExpanded = true
                        }
                    } label: {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(OunjePalette.primaryText.opacity(0.92))
                            .frame(width: 36, height: 36)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .animation(.easeInOut(duration: 0.18), value: isExpanded)
        .animation(.easeInOut(duration: 0.18), value: hasQuery)
    }
}

private struct RecipesEmptyState: View {
    let title: String
    let detail: String
    let symbolName: String

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: symbolName)
                .font(.system(size: 88, weight: .light))
                .foregroundStyle(OunjePalette.secondaryText.opacity(0.5))
                .frame(maxWidth: .infinity)
                .padding(.top, 44)

            VStack(spacing: 8) {
                Text(title)
                    .biroHeaderFont(20)
                    .foregroundStyle(OunjePalette.primaryText)

                Text(detail)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(OunjePalette.secondaryText)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
        .padding(.bottom, 24)
        .background(
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .fill(OunjePalette.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 30, style: .continuous)
                        .stroke(OunjePalette.stroke, lineWidth: 1)
                )
        )
    }
}

private struct CookbookPreppedEmptyState: View {
    let title: String
    let detail: String
    let symbolName: String

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: symbolName)
                .font(.system(size: 74, weight: .light))
                .foregroundStyle(OunjePalette.secondaryText.opacity(0.45))
                .padding(.top, 18)

            VStack(spacing: 8) {
                BiroScriptDisplayText(title, size: 28, color: OunjePalette.primaryText)

                Text(detail)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(OunjePalette.secondaryText)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: 290)
        }
        .frame(maxWidth: .infinity, minHeight: 280, alignment: .center)
        .padding(.horizontal, 8)
        .padding(.vertical, 22)
    }
}

private struct CookbookSavedEmptyState: View {
    let hasSavedRecipes: Bool
    let onBrowseDiscover: () -> Void
    let onAddRecipe: () -> Void

    var body: some View {
        VStack(spacing: 22) {
            Image("CookbookEmptyIllustrationLight")
                .renderingMode(.original)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(maxWidth: 220)
                .opacity(0.84)
                .padding(.top, 8)

            VStack(spacing: 8) {
                BiroScriptDisplayText(
                    hasSavedRecipes ? "No saved matches" : "No saved recipes",
                    size: 28,
                    color: OunjePalette.primaryText
                )

                Text(
                    hasSavedRecipes
                        ? "Try another search or jump back to Discover."
                        : "Save recipes from Discover or add one directly into Cookbook."
                )
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(OunjePalette.secondaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: 280)

            HStack(spacing: 12) {
                Button(action: onBrowseDiscover) {
                    Text("Browse Discover")
                        .biroHeaderFont(15)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(SecondaryPillButtonStyle())

                Button(action: onAddRecipe) {
                    Text("Add recipe")
                        .biroHeaderFont(15)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryPillButtonStyle())
            }
            .frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 12)
        .padding(.vertical, 28)
    }
}

private struct CookbookInlineActionHeader: View {
    let title: String
    let detail: String
    let buttonTitle: String
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .biroHeaderFont(24)
                    .foregroundStyle(OunjePalette.primaryText)
                Text(detail)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(OunjePalette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 10)

            Button(action: action) {
                HStack(spacing: 8) {
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .bold))
                    Text(buttonTitle)
                        .biroHeaderFont(14)
                }
                .foregroundStyle(OunjePalette.primaryText)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    Capsule(style: .continuous)
                        .fill(OunjePalette.surface)
                        .overlay(
                            Capsule(style: .continuous)
                                .stroke(OunjePalette.stroke, lineWidth: 1)
                        )
                )
            }
            .buttonStyle(.plain)
        }
    }
}

private struct CookbookRecipesGroup: View {
    let title: String
    let detail: String
    let recipes: [DiscoverRecipeCardData]
    let columns: [GridItem]
    let onSelectRecipe: (DiscoverRecipeCardData) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                BiroScriptDisplayText(title, size: 26, color: OunjePalette.primaryText)
                Text(detail)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(OunjePalette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            LazyVGrid(columns: columns, spacing: 14) {
                ForEach(recipes) { recipe in
                    DiscoverRemoteRecipeCard(recipe: recipe) {
                        onSelectRecipe(recipe)
                    }
                }
            }
        }
    }
}

private struct ShoppingListRow: View {
    let item: GroceryItem

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            IngredientBadge(name: item.name)

            VStack(alignment: .leading, spacing: 4) {
                Text(item.name.capitalized)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(OunjePalette.primaryText)
                Text("\(item.amount.roundedString(1)) \(item.unit)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(OunjePalette.secondaryText)
            }

            Spacer()

            Text(item.estimatedPrice.asCurrency)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(OunjePalette.primaryText)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(OunjePalette.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(OunjePalette.stroke, lineWidth: 1)
                )
        )
    }
}

private enum CartDisplayMode: String, CaseIterable, Identifiable {
    case reconciled
    case recipes
    case grid

    var id: String { rawValue }

    var symbolName: String {
        switch self {
        case .reconciled: return "shippingbox"
        case .recipes: return "list.bullet.rectangle"
        case .grid: return "square.grid.2x2"
        }
    }
}

private struct CartDisplayModeBar: View {
    @Binding var selection: CartDisplayMode

    var body: some View {
        HStack(spacing: 22) {
            ForEach(CartDisplayMode.allCases) { mode in
                Button {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
                        selection = mode
                    }
                } label: {
                    VStack(spacing: 8) {
                        Image(systemName: mode.symbolName)
                            .font(.system(size: 17, weight: .semibold))

                        Capsule(style: .continuous)
                            .fill(selection == mode ? OunjePalette.accent : Color.clear)
                            .frame(width: 20, height: 3)
                    }
                    .foregroundStyle(selection == mode ? OunjePalette.primaryText : OunjePalette.secondaryText)
                    .frame(width: 28)
                }
                .buttonStyle(.plain)
            }

            Spacer(minLength: 0)
        }
    }
}

private struct CartIngredientGroup: Identifiable, Hashable {
    var id: String { recipeID }
    let recipeID: String
    let recipeTitle: String
    let servings: Int
    let cookTimeMinutes: Int
    let ingredients: [SupabaseRecipeIngredientRow]
}

private struct CartRecipeListCard: View {
    let group: CartIngredientGroup

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(group.recipeTitle)
                        .biroHeaderFont(24)
                        .foregroundStyle(OunjePalette.primaryText)
                    Text("\(group.servings) servings · \(group.cookTimeMinutes) mins")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(OunjePalette.secondaryText)
                }

                Spacer()
            }

            VStack(spacing: 0) {
                ForEach(Array(group.ingredients.enumerated()), id: \.element.id) { index, ingredient in
                    CartRecipeIngredientRow(ingredient: ingredient)

                    if index < group.ingredients.count - 1 {
                        Divider()
                            .overlay(OunjePalette.stroke.opacity(0.8))
                            .padding(.leading, 64)
                            .padding(.vertical, 10)
                    }
                }
            }
        }
        .padding(.bottom, 22)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(OunjePalette.stroke.opacity(0.72))
                .frame(height: 1)
        }
    }
}

private struct CartRecipeIngredientRow: View {
    let ingredient: SupabaseRecipeIngredientRow

    var body: some View {
        HStack(spacing: 12) {
            CartIngredientArtwork(ingredient: ingredient, compact: true)
                .frame(width: 50, height: 50)

            VStack(alignment: .leading, spacing: 3) {
                Text(ingredient.displayTitle)
                    .sleeDisplayFont(16)
                    .foregroundStyle(OunjePalette.primaryText)
                    .lineLimit(2)

                if let quantityText = ingredient.displayQuantityText, !quantityText.isEmpty {
                    Text(quantityText)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(OunjePalette.secondaryText)
                }
            }

            Spacer(minLength: 8)
        }
        .padding(.vertical, 2)
    }
}

private struct CartIngredientTile: View {
    let ingredient: SupabaseRecipeIngredientRow
    let compact: Bool
    var elevated: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CartIngredientArtwork(ingredient: ingredient, compact: compact)
                .frame(height: compact ? 88 : 102)

            Text(ingredient.displayTitle)
                .sleeDisplayFont(compact ? 16 : 17)
                .foregroundStyle(OunjePalette.primaryText)
                .lineLimit(2)

            if let quantityText = ingredient.displayQuantityText, !quantityText.isEmpty {
                Text(quantityText)
                    .font(.system(size: compact ? 11 : 12, weight: .medium))
                    .foregroundStyle(OunjePalette.secondaryText)
                    .lineLimit(1)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(elevated ? OunjePalette.elevated : OunjePalette.panel.opacity(0.52))
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(elevated ? OunjePalette.stroke : OunjePalette.stroke.opacity(0.72), lineWidth: 1)
                )
        )
    }
}

private struct CartFlatIngredientTile: View {
    let ingredient: SupabaseRecipeIngredientRow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CartIngredientArtwork(ingredient: ingredient, compact: false)
                .frame(height: 84)

            Text(ingredient.displayTitle)
                .sleeDisplayFont(16)
                .foregroundStyle(OunjePalette.primaryText)
                .lineLimit(2)
                .minimumScaleFactor(0.8)

            if let quantityText = ingredient.displayQuantityText, !quantityText.isEmpty {
                Text(quantityText)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(OunjePalette.secondaryText)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

private struct CartIngredientArtwork: View {
    let ingredient: SupabaseRecipeIngredientRow
    let compact: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(OunjePalette.panel)

            if let imageURL = ingredient.imageURL {
                AsyncImage(url: imageURL) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    case .empty:
                        ProgressView()
                            .tint(OunjePalette.accent)
                    default:
                        fallbackGlyph
                    }
                }
            } else {
                fallbackGlyph
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var fallbackGlyph: some View {
        Text(IngredientMonogramFormatter.monogram(for: ingredient.displayTitle))
            .sleeDisplayFont(compact ? 24 : 28)
            .foregroundStyle(OunjePalette.softCream)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct CartGroceryLineItemRow: View {
    let item: CartGroceryDisplayItem

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(OunjePalette.panel)
                    .frame(width: 68, height: 68)

                if let imageURL = item.imageURL {
                    AsyncImage(url: imageURL) { phase in
                        switch phase {
                        case .success(let image):
                            image
                                .resizable()
                                .scaledToFill()
                                .frame(width: 68, height: 68)
                        case .empty:
                            ProgressView()
                                .tint(OunjePalette.accent)
                        default:
                            fallbackGlyph
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                } else {
                    fallbackGlyph
                }
            }

            VStack(alignment: .leading, spacing: 5) {
                Text(item.name)
                    .sleeDisplayFont(17)
                    .foregroundStyle(OunjePalette.primaryText)
                    .lineLimit(2)

                Text(item.quantityText)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(OunjePalette.secondaryText)

                if let supportingText = item.supportingText, !supportingText.isEmpty {
                    Text(supportingText)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(OunjePalette.secondaryText.opacity(0.82))
                }
            }

            Spacer(minLength: 10)

            if let estimatedPriceText = item.estimatedPriceText, !estimatedPriceText.isEmpty {
                Text(estimatedPriceText)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(OunjePalette.primaryText)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(OunjePalette.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(OunjePalette.stroke, lineWidth: 1)
                )
        )
    }

    private var fallbackGlyph: some View {
        Text(IngredientMonogramFormatter.monogram(for: item.name))
            .sleeDisplayFont(18)
            .foregroundStyle(OunjePalette.softCream)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private enum CartQuantityFormatter {
    static func format(amount: Double, unit: String) -> String {
        let normalizedUnit = unit.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let roundedAmount = normalizedAmount(amount)

        if ["oz", "ounce", "ounces"].contains(normalizedUnit),
           amount >= 16,
           amount.truncatingRemainder(dividingBy: 16) == 0 {
            let pounds = amount / 16
            return "\(normalizedAmount(pounds)) lb"
        }

        if normalizedUnit == "ct" || normalizedUnit == "count" {
            let label = amount == 1 ? "item" : "items"
            return "\(roundedAmount) \(label)"
        }

        if normalizedUnit.isEmpty {
            return roundedAmount
        }

        return "\(roundedAmount) \(unit)"
    }

    private static func normalizedAmount(_ value: Double) -> String {
        if abs(value.rounded() - value) < 0.001 {
            return String(Int(value.rounded()))
        }
        return value.roundedString(1)
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0, !isEmpty else {
            return isEmpty ? [] : [self]
        }

        var chunks: [[Element]] = []
        var index = startIndex

        while index < endIndex {
            let nextIndex = self.index(index, offsetBy: size, limitedBy: endIndex) ?? endIndex
            chunks.append(Array(self[index ..< nextIndex]))
            index = nextIndex
        }

        return chunks
    }
}

private struct IngredientBadge: View {
    let name: String

    private var emoji: String {
        let normalized = name.lowercased()
        if normalized.contains("chicken") { return "🍗" }
        if normalized.contains("turkey") { return "🦃" }
        if normalized.contains("beef") || normalized.contains("steak") { return "🥩" }
        if normalized.contains("salmon") || normalized.contains("fish") || normalized.contains("shrimp") { return "🐟" }
        if normalized.contains("egg") { return "🥚" }
        if normalized.contains("broccoli") { return "🥦" }
        if normalized.contains("spinach") || normalized.contains("lettuce") || normalized.contains("kale") { return "🥬" }
        if normalized.contains("carrot") { return "🥕" }
        if normalized.contains("potato") { return "🥔" }
        if normalized.contains("rice") { return "🍚" }
        if normalized.contains("pasta") || normalized.contains("spaghetti") || normalized.contains("noodle") { return "🍝" }
        if normalized.contains("cheddar") || normalized.contains("cheese") { return "🧀" }
        if normalized.contains("milk") { return "🥛" }
        if normalized.contains("bread") || normalized.contains("bun") || normalized.contains("tortilla") { return "🍞" }
        if normalized.contains("tomato") { return "🍅" }
        if normalized.contains("pepper") { return "🫑" }
        if normalized.contains("onion") { return "🧅" }
        if normalized.contains("garlic") { return "🧄" }
        if normalized.contains("avocado") { return "🥑" }
        if normalized.contains("lemon") || normalized.contains("lime") { return "🍋" }
        if normalized.contains("bean") { return "🫘" }
        if normalized.contains("mushroom") { return "🍄" }
        return "🥣"
    }

    var body: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [
                        OunjePalette.panel,
                        OunjePalette.accent.opacity(0.08)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .frame(width: 56, height: 56)
            .overlay(
                Text(emoji)
                    .font(.system(size: 28))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(OunjePalette.stroke, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.16), radius: 10, y: 6)
    }
}

private struct AddActionRow: View {
    let title: String
    let detail: String
    let symbolName: String
    let accent: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(accent.opacity(0.14))
                    .frame(width: 50, height: 50)
                    .overlay(
                        Image(systemName: symbolName)
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(accent)
                    )

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .biroHeaderFont(18)
                        .foregroundStyle(OunjePalette.primaryText)
                        .lineLimit(1)
                    Text(detail)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(OunjePalette.secondaryText)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                Image(systemName: "arrow.up.right")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(OunjePalette.secondaryText.opacity(0.5))
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                OunjePalette.surface,
                                accent.opacity(0.06)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .stroke(OunjePalette.stroke, lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
    }
}

private struct AskOunjeSheet: View {
    let intro: String
    let suggestions: [String]
    @Binding var promptText: String

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Capsule()
                .fill(OunjePalette.elevated)
                .frame(width: 88, height: 6)
                .frame(maxWidth: .infinity)
                .padding(.top, 8)

            HStack {
                Text("Ask Ounje")
                    .biroHeaderFont(32)
                    .foregroundStyle(OunjePalette.primaryText)

                Spacer()

                if !promptText.isEmpty {
                    Button("Clear chat") {
                        promptText = ""
                    }
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(OunjePalette.secondaryText)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(
                        Capsule(style: .continuous)
                            .stroke(OunjePalette.stroke, lineWidth: 1)
                    )
                }
            }

            Text(intro)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(OunjePalette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 12) {
                Text("Need some inspiration?")
                    .biroHeaderFont(20)
                    .foregroundStyle(OunjePalette.primaryText)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(suggestions, id: \.self) { suggestion in
                            Button {
                                promptText = suggestion
                            } label: {
                                Text(suggestion)
                                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                                    .foregroundStyle(OunjePalette.primaryText)
                                    .padding(.horizontal, 18)
                                    .padding(.vertical, 14)
                                    .background(
                                        Capsule(style: .continuous)
                                            .stroke(OunjePalette.stroke, lineWidth: 1)
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.trailing, 4)
                }
            }

            HStack(spacing: 12) {
                TextField("Message", text: $promptText)
                    .font(.system(size: 18, weight: .medium, design: .rounded))
                    .foregroundStyle(OunjePalette.primaryText)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 16)
                    .background(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .fill(OunjePalette.elevated)
                    )

                Button("Send") {}
                    .biroHeaderFont(18)
                    .foregroundStyle(promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? OunjePalette.secondaryText : .white)
                    .frame(width: 116)
                    .padding(.vertical, 16)
                    .background(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .fill(promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? OunjePalette.elevated : OunjePalette.accent)
                    )
                    .disabled(promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 20)
        .background(
            RoundedRectangle(cornerRadius: 34, style: .continuous)
                .fill(OunjePalette.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 34, style: .continuous)
                .stroke(OunjePalette.stroke, lineWidth: 1)
        )
        .shadow(color: OunjePalette.primaryText.opacity(0.08), radius: 20, x: 0, y: -4)
    }
}

private struct MealsRecipeSlot: View {
    let title: String
    let recipe: Recipe?

    var body: some View {
        HStack(spacing: 14) {
            // Meal time circle icon
            ZStack {
                Circle()
                    .fill(recipe == nil ? OunjePalette.elevated : OunjePalette.accent.opacity(0.12))
                    .frame(width: 56, height: 56)
                        Image(systemName: recipe == nil ? "plus" : "fork.knife")
                    .font(.system(size: 18, weight: recipe == nil ? .light : .medium))
                    .foregroundStyle(recipe == nil ? OunjePalette.secondaryText : OunjePalette.accent)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(OunjePalette.secondaryText)
                    .textCase(.uppercase)
                    .kerning(0.5)
                Text(recipe?.title ?? "Choose a Recipe")
                    .biroHeaderFont(17)
                    .foregroundStyle(recipe == nil ? OunjePalette.secondaryText : OunjePalette.primaryText)
                        .lineLimit(2)
                }

                Spacer()

            if let recipe = recipe {
                Text("\(recipe.prepMinutes)m")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(OunjePalette.secondaryText)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(
                        Capsule(style: .continuous)
                            .fill(OunjePalette.elevated)
                    )
            } else {
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(OunjePalette.secondaryText.opacity(0.5))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
            .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(OunjePalette.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(
                            recipe == nil
                                ? OunjePalette.stroke
                                : OunjePalette.accent.opacity(0.2),
                            style: recipe == nil
                                ? StrokeStyle(lineWidth: 1, dash: [8, 6])
                                : StrokeStyle(lineWidth: 1)
                        )
                )
        )
    }
}

private struct WeekMealRow: View {
    let dayTitle: String
    let recipe: Recipe?

    private var dayInitial: String {
        String(dayTitle.prefix(3))
    }

    var body: some View {
        HStack(spacing: 14) {
            // Day badge
            VStack(spacing: 2) {
                Text(dayInitial)
                    .biroHeaderFont(13)
                    .foregroundStyle(recipe == nil ? OunjePalette.secondaryText : OunjePalette.accent)
            }
            .frame(width: 40)

            Rectangle()
                .fill(OunjePalette.stroke)
                .frame(width: 1, height: 32)

            VStack(alignment: .leading, spacing: 3) {
                Text(recipe?.title ?? "No recipe yet")
                    .biroHeaderFont(15)
                    .foregroundStyle(recipe == nil ? OunjePalette.secondaryText : OunjePalette.primaryText)
                    .lineLimit(1)
                if let recipe = recipe {
                    Text(recipe.cuisine.title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(OunjePalette.secondaryText)
                }
            }

            Spacer()

            if let recipe = recipe {
                Text("\(recipe.prepMinutes)m")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(OunjePalette.secondaryText)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Capsule(style: .continuous).fill(OunjePalette.elevated))
            } else {
                Image(systemName: "plus.circle")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(OunjePalette.secondaryText.opacity(0.5))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(OunjePalette.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(OunjePalette.stroke, lineWidth: 1)
                )
        )
    }
}

private struct MealsSummaryCard: View {
    let title: String
    let value: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(OunjePalette.secondaryText)
            Text(value)
                .biroHeaderFont(24)
                .foregroundStyle(OunjePalette.primaryText)
            Text(detail)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(OunjePalette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(OunjePalette.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(OunjePalette.stroke, lineWidth: 1)
                )
        )
    }
}

private struct PrepTrackerCard: View {
    @ObservedObject var store: MealPlanningAppStore
    @State private var isTimeEditorPresented = false
    @State private var isCadencePickerPresented = false
    @State private var selectedDeliveryTime = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Next delivery")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(OunjePalette.secondaryText)

                BiroScriptDisplayText(
                    nextDeliveryTitle,
                    size: 38,
                    color: OunjePalette.primaryText
                )
                .overlay(alignment: .topLeading) {
                    Text(nextDeliveryTitle)
                        .font(.custom("BiroScriptreduced", size: 38))
                        .tracking(0.2)
                        .foregroundStyle(OunjePalette.primaryText.opacity(0.22))
                        .offset(x: 0.9, y: 0.55)
                }
                
                if let profile = store.profile {
                    HStack(spacing: 10) {
                        cadenceControl(profile: profile)
                        deliveryTimeControl
                    }
                    .padding(.top, 10)

                    if !canEditDeliveryTime {
                        Text("Delivery time locks 24 hours before drop.")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(OunjePalette.secondaryText.opacity(0.88))
                            .padding(.top, 4)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 16) {
                PrepDeliveryMapPanel(
                    snapshot: snapshot,
                    quote: store.latestPlan?.bestQuote,
                    address: store.profile?.deliveryAddress
                )

                if let quote = store.latestPlan?.bestQuote, !quote.reviewItems.isEmpty {
                    ProviderCartReviewCard(quote: quote)
                }
            }
            .padding(.top, 4)
        }
        .padding(.bottom, 4)
        .confirmationDialog("Delivery frequency", isPresented: $isCadencePickerPresented, titleVisibility: .visible) {
            ForEach(MealCadence.allCases) { cadence in
                Button(cadence.title) {
                    updateCadence(cadence)
                }
            }
        } message: {
            Text("Choose how often Ounje should schedule the next delivery.")
        }
        .sheet(isPresented: $isTimeEditorPresented) {
            DeliveryTimeSheet(
                provider: activeProvider,
                scheduledDeliveryDate: scheduledDeliveryDate,
                selectedTime: $selectedDeliveryTime,
                canEdit: canEditDeliveryTime,
                onCancel: {
                    isTimeEditorPresented = false
                },
                onSave: {
                    saveDeliveryTime()
                }
            )
            .presentationDetents([.height(510)])
            .presentationDragIndicator(.visible)
        }
    }

    private func cadenceControl(profile: UserProfile) -> some View {
        Button {
            isCadencePickerPresented = true
        } label: {
            PrepMetaPill(title: profile.cadenceTitleOnly, accent: OunjePalette.softCream)
        }
        .buttonStyle(.plain)
    }

    private var snapshot: PrepDeliverySnapshot {
        PrepDeliverySnapshot(
            nextPrepDate: scheduledDeliveryDate,
            generatedAt: store.latestPlan?.generatedAt,
            quote: store.latestPlan?.bestQuote
        )
    }

    private var nextDeliveryTitle: String {
        guard let nextRun = scheduledDeliveryDate else {
            return "Set once your first plan runs"
        }
        return nextRun.formatted(.dateTime.weekday(.wide).month(.wide).day())
    }

    private var scheduledDeliveryDate: Date? {
        if let nextRun = store.nextRunDate {
            return nextRun
        }
        guard let profile = store.profile else { return nil }
        return profile.scheduledDeliveryDate()
    }

    private var canEditDeliveryTime: Bool {
        guard let scheduledDeliveryDate else { return false }
        return scheduledDeliveryDate.timeIntervalSinceNow >= 24 * 60 * 60
    }

    private var activeProvider: ShoppingProvider {
        store.latestPlan?.bestQuote?.provider ?? store.profile?.preferredProviders.first ?? .walmart
    }

    private var currentDeliveryWindow: DeliveryWindowOption {
        let windows = activeProvider.deliveryWindowOptions
        let currentMinutes = store.profile?.deliveryTimeMinutes ?? (18 * 60)
        return windows.first(where: { currentMinutes >= $0.startMinutes && currentMinutes < $0.endMinutes }) ?? windows[0]
    }

    @ViewBuilder
    private var deliveryTimeControl: some View {
        if canEditDeliveryTime {
            Button {
                let baseDate = scheduledDeliveryDate ?? .now
                selectedDeliveryTime = activeProvider.closestAvailableDeliveryTime(
                    from: store.profile?.dateForDeliveryTime(on: baseDate) ?? baseDate,
                    on: baseDate
                )
                isTimeEditorPresented = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "clock")
                        .font(.system(size: 12, weight: .bold))
                    Text(currentDeliveryWindow.shortTitle)
                        .biroHeaderFont(12)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .bold))
                }
                .foregroundStyle(OunjePalette.primaryText)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    Capsule(style: .continuous)
                        .fill(OunjePalette.surface)
                        .overlay(
                            Capsule(style: .continuous)
                                .stroke(OunjePalette.accent.opacity(0.34), lineWidth: 1)
                        )
                )
            }
            .buttonStyle(.plain)
        } else {
            HStack(spacing: 6) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 11, weight: .bold))
                Text(currentDeliveryWindow.shortTitle)
                    .biroHeaderFont(12)
            }
            .foregroundStyle(OunjePalette.secondaryText)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                Capsule(style: .continuous)
                    .fill(OunjePalette.surface)
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(OunjePalette.secondaryText.opacity(0.18), lineWidth: 1)
                    )
            )
        }
    }

    private func saveDeliveryTime() {
        guard var updatedProfile = store.profile else {
            isTimeEditorPresented = false
            return
        }

        let minutes = (Calendar.current.component(.hour, from: selectedDeliveryTime) * 60) + Calendar.current.component(.minute, from: selectedDeliveryTime)
        let selectedWindow = activeProvider.closestDeliveryWindow(to: minutes)
        updatedProfile.deliveryTimeMinutes = selectedWindow.startMinutes
        store.updateProfile(updatedProfile)
        isTimeEditorPresented = false
    }

    private func updateCadence(_ cadence: MealCadence) {
        guard var updatedProfile = store.profile else { return }
        updatedProfile.cadence = cadence
        store.updateProfile(updatedProfile)
    }
}

private struct PrepDeliverySnapshot {
    enum Stage {
        case store
        case preparing
        case enRoute
        case delivered
    }

    let nextPrepDate: Date?
    let generatedAt: Date?
    let quote: ProviderQuote?

    private var calendar: Calendar { .current }

    private var daysUntilPrep: Int? {
        guard let nextPrepDate = nextPrepDate else { return nil }
        let now = calendar.startOfDay(for: .now)
        let target = calendar.startOfDay(for: nextPrepDate)
        return calendar.dateComponents([.day], from: now, to: target).day
    }

    var stage: Stage {
        guard let days = daysUntilPrep, let quote = quote else { return .store }
        if days <= 0 { return .delivered }
        if days <= 1 { return .enRoute }
        if days <= quote.etaDays { return .enRoute }
        if days <= quote.etaDays + 1 { return .preparing }
        return .store
    }

    var progress: CGFloat {
        switch stage {
        case .store:
            return 0.14
        case .preparing:
            return 0.38
        case .enRoute:
            if let days = daysUntilPrep, let quote = quote {
                let totalWindow = max(1, quote.etaDays)
                let advanced = max(0, totalWindow - days + 1)
                return min(0.9, 0.46 + (CGFloat(advanced) / CGFloat(totalWindow)) * 0.36)
            }
            return 0.72
        case .delivered:
            return 1.0
        }
    }

    var statusLabel: String {
        switch stage {
        case .store:
            return "At the store"
        case .preparing:
            return "Packing"
        case .enRoute:
            return "On the way"
        case .delivered:
            return "Delivered"
        }
    }

    func etaLabel(for quote: ProviderQuote) -> String {
        let actualDaysRemaining = max(0, daysUntilPrep ?? quote.etaDays)

        switch stage {
        case .delivered:
            return "Now"
        case .preparing:
            return actualDaysRemaining <= 1 ? "Tomorrow" : "\(actualDaysRemaining)d away"
        case .enRoute:
            if actualDaysRemaining <= 0 { return "Today" }
            return actualDaysRemaining == 1 ? "Tomorrow" : "\(actualDaysRemaining)d away"
        case .store:
            return actualDaysRemaining == 1 ? "1d away" : "\(actualDaysRemaining)d away"
        }
    }
}

@MainActor
private final class PrepDeliveryMapModel: ObservableObject {
    @Published var homeCoordinate: CLLocationCoordinate2D?
    @Published var storeCoordinate: CLLocationCoordinate2D?
    @Published var region = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194),
        span: MKCoordinateSpan(latitudeDelta: 0.08, longitudeDelta: 0.08)
    )

    private let geocoder = CLGeocoder()
    private var lastAddressKey = ""

    func load(address: DeliveryAddress?, provider: ShoppingProvider?) async {
        guard let address = address, address.isComplete else {
            homeCoordinate = nil
            storeCoordinate = nil
            lastAddressKey = ""
            return
        }

        let addressKey = [address.line1, address.city, address.region, address.postalCode]
            .joined(separator: ", ")

        if addressKey == lastAddressKey, homeCoordinate != nil, storeCoordinate != nil {
            return
        }

        do {
            let placemarks = try await geocoder.geocodeAddressString(addressKey)
            guard let coordinate = placemarks.first?.location?.coordinate else { return }

            let storePoint = derivedStoreCoordinate(from: coordinate, provider: provider)
            homeCoordinate = coordinate
            storeCoordinate = storePoint
            region = regionFitting(from: storePoint, to: coordinate)
            lastAddressKey = addressKey
        } catch {
            homeCoordinate = nil
            storeCoordinate = nil
        }
    }

    private func derivedStoreCoordinate(from home: CLLocationCoordinate2D, provider: ShoppingProvider?) -> CLLocationCoordinate2D {
        let delta: (Double, Double)
        switch provider {
        case .instacart:
            delta = (0.018, -0.020)
        case .amazonFresh:
            delta = (0.014, 0.018)
        case .mealme, .kroger, .walmart, .none:
            delta = (0.020, -0.012)
        }

        return CLLocationCoordinate2D(
            latitude: home.latitude + delta.0,
            longitude: home.longitude + delta.1
        )
    }

    private func regionFitting(from start: CLLocationCoordinate2D, to end: CLLocationCoordinate2D) -> MKCoordinateRegion {
        let center = CLLocationCoordinate2D(
            latitude: (start.latitude + end.latitude) / 2,
            longitude: (start.longitude + end.longitude) / 2
        )

        return MKCoordinateRegion(
            center: center,
            span: MKCoordinateSpan(
                latitudeDelta: max(abs(start.latitude - end.latitude) * 1.8, 0.05),
                longitudeDelta: max(abs(start.longitude - end.longitude) * 1.8, 0.05)
            )
        )
    }
}

private struct PrepDeliveryMapPanel: View {
    let snapshot: PrepDeliverySnapshot
    let quote: ProviderQuote?
    let address: DeliveryAddress?

    @StateObject private var model = PrepDeliveryMapModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let home = model.homeCoordinate, let store = model.storeCoordinate {
                let _ = (home, store)
                Map(coordinateRegion: $model.region, interactionModes: [])
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .frame(height: 152)
            } else {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(OunjePalette.surface)
                    .overlay(
                        VStack(spacing: 8) {
                            Image(systemName: "map")
                                .font(.system(size: 26, weight: .medium))
                                .foregroundStyle(OunjePalette.secondaryText)
                            Text("Add a delivery address in Profile to map the route.")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(OunjePalette.secondaryText)
                                .multilineTextAlignment(.center)
                        }
                        .padding(.horizontal, 24)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .stroke(OunjePalette.stroke, lineWidth: 1)
                    )
                    .frame(height: 152)
            }

            PrepRouteOverlay(
                snapshot: snapshot,
                providerTitle: quote?.provider.title,
                storeTitle: quote?.selectedStore?.storeName,
                etaText: quote.map { snapshot.etaLabel(for: $0) }
            )
        }
        .task(id: mapTaskID) {
            await model.load(address: address, provider: quote?.provider)
        }
    }

    private var mapTaskID: String {
        let addressKey = [address?.line1, address?.city, address?.region, address?.postalCode]
            .compactMap { $0 }
            .joined(separator: "|")
        return "\(addressKey)::\(quote?.provider.rawValue ?? "none")"
    }
}

private struct PrepMetaPill: View {
    let title: String
    let accent: Color

    var body: some View {
        Text(title)
            .biroHeaderFont(12)
            .foregroundStyle(OunjePalette.primaryText)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                Capsule(style: .continuous)
                    .fill(OunjePalette.surface)
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(accent.opacity(0.34), lineWidth: 1)
                    )
            )
    }
}

private struct ProviderCartReviewCard: View {
    let quote: ProviderQuote

    private var substituted: [ProviderCartReviewItem] {
        quote.reviewItems.filter { $0.status.caseInsensitiveCompare("substituted") == .orderedSame }
    }

    private var unresolved: [ProviderCartReviewItem] {
        quote.reviewItems.filter { $0.status.caseInsensitiveCompare("unresolved") == .orderedSame }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center) {
                Text("Cart review")
                    .biroHeaderFont(16)
                    .foregroundStyle(OunjePalette.primaryText)

                Spacer(minLength: 12)

                Text(summaryLine)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(OunjePalette.secondaryText)
            }

            VStack(alignment: .leading, spacing: 14) {
                if !unresolved.isEmpty {
                    reviewGroup(
                        title: "Missing",
                        accent: OunjePalette.softCream,
                        items: Array(unresolved.prefix(3))
                    )
                }

                if !substituted.isEmpty {
                    reviewGroup(
                        title: "Substituted",
                        accent: OunjePalette.accent,
                        items: Array(substituted.prefix(3))
                    )
                }
            }

            let remainingCount = max(0, quote.reviewItems.count - min(3, unresolved.count) - min(3, substituted.count))
            if remainingCount > 0 {
                Text("\(remainingCount) more item\(remainingCount == 1 ? "" : "s") still need a look.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(OunjePalette.secondaryText)
            }
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(OunjePalette.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(OunjePalette.stroke, lineWidth: 1)
                )
        )
    }

    private var summaryLine: String {
        let parts = [
            unresolved.isEmpty ? nil : "\(unresolved.count) missing",
            substituted.isEmpty ? nil : "\(substituted.count) swapped"
        ].compactMap { $0 }

        return parts.isEmpty ? "No review needed" : parts.joined(separator: " • ")
    }

    private func prettyRequested(_ item: ProviderCartReviewItem) -> String {
        let value = item.requested.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "Unnamed item" : value
    }

    private func isUnresolved(_ item: ProviderCartReviewItem) -> Bool {
        item.status.caseInsensitiveCompare("unresolved") == .orderedSame
    }

    private func badgeText(for item: ProviderCartReviewItem) -> String {
        isUnresolved(item) ? "Missing" : "Swap"
    }

    private func badgeColor(for item: ProviderCartReviewItem) -> Color {
        isUnresolved(item) ? OunjePalette.softCream : OunjePalette.accent
    }

    @ViewBuilder
    private func reviewGroup(title: String, accent: Color, items: [ProviderCartReviewItem]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle()
                    .fill(accent)
                    .frame(width: 8, height: 8)

                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(OunjePalette.primaryText)
            }

            VStack(spacing: 10) {
                ForEach(items) { item in
                    reviewRow(for: item)
                }
            }
        }
    }

    @ViewBuilder
    private func reviewRow(for item: ProviderCartReviewItem) -> some View {
        let badgeColor = badgeColor(for: item)

        HStack(alignment: .top, spacing: 10) {
            Text(badgeText(for: item))
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(badgeColor)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    Capsule(style: .continuous)
                        .fill(badgeColor.opacity(0.14))
                )

            VStack(alignment: .leading, spacing: 3) {
                Text(prettyRequested(item))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(OunjePalette.primaryText)

                Text(detailLine(for: item))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(OunjePalette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
    }

    private func detailLine(for item: ProviderCartReviewItem) -> String {
        if isUnresolved(item) {
            if let refinedQuery = item.refinedQuery, !refinedQuery.isEmpty {
                return "Couldn’t place it. Last search: \(refinedQuery)."
            }
            return "Couldn’t find a safe match in the current cart run."
        }

        if let matched = item.matched, !matched.isEmpty {
            return "Using \(matched) instead."
        }

        return "Substituted during the provider fill."
    }
}

private struct DeliveryTimeSheet: View {
    let provider: ShoppingProvider
    let scheduledDeliveryDate: Date?
    @Binding var selectedTime: Date
    let canEdit: Bool
    let onCancel: () -> Void
    let onSave: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Capsule()
                .fill(OunjePalette.stroke.opacity(0.9))
                .frame(width: 56, height: 5)
                .frame(maxWidth: .infinity)
                .padding(.top, 4)

            HStack(alignment: .top) {
                Button("Cancel", action: onCancel)
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(OunjePalette.secondaryText)

                Spacer(minLength: 16)

                Button("Save", action: onSave)
                    .biroHeaderFont(16)
                    .foregroundStyle(OunjePalette.primaryText)
                    .disabled(!canEdit)
                    .opacity(canEdit ? 1 : 0.45)
            }
            .padding(.bottom, 2)

            VStack(alignment: .leading, spacing: 6) {
                Text("Delivery time")
                    .biroHeaderFont(30)
                    .foregroundStyle(OunjePalette.primaryText)

                Text(subtitle)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(OunjePalette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if canEdit {
                VStack(alignment: .leading, spacing: 10) {
                    DatePicker(
                        "",
                        selection: deliveryTimeBinding,
                        in: availableRange,
                        displayedComponents: .hourAndMinute
                    )
                    .datePickerStyle(.wheel)
                    .labelsHidden()
                    .colorScheme(.dark)
                    .frame(maxWidth: .infinity)
                    .frame(height: 238)
                    .clipped()
                    .background(
                        RoundedRectangle(cornerRadius: 26, style: .continuous)
                            .fill(OunjePalette.surface)
                            .overlay(
                                RoundedRectangle(cornerRadius: 26, style: .continuous)
                                    .stroke(OunjePalette.stroke, lineWidth: 1)
                            )
                    )

                    Spacer(minLength: 16)

                    HStack(spacing: 10) {
                        Text("Closest slot")
                            .biroHeaderFont(12)
                            .foregroundStyle(OunjePalette.secondaryText)
                        PrepMetaPill(title: selectedWindow.shortTitle, accent: OunjePalette.accent)
                        PrepMetaPill(title: selectedWindow.detail, accent: OunjePalette.softCream)
                    }
                }
            } else {
                ThemedCard {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(selectedWindow.shortTitle)
                            .biroHeaderFont(22)
                            .foregroundStyle(OunjePalette.primaryText)
                        Text("This delivery is already within the locked change window.")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(OunjePalette.secondaryText)
                    }
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 6)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(OunjePalette.background.ignoresSafeArea())
    }

    private var subtitle: String {
        guard let scheduledDeliveryDate else {
            return "Choose the delivery window for the next drop."
        }
        return "\(provider.title) for \(scheduledDeliveryDate.formatted(.dateTime.weekday(.wide).month(.wide).day()))"
    }

    private var availableRange: ClosedRange<Date> {
        let baseDate = scheduledDeliveryDate ?? .now
        let lowerMinutes = provider.availableDeliveryMinuteRange.lowerBound
        let upperMinutes = provider.availableDeliveryMinuteRange.upperBound
        let calendar = Calendar.current
        let lowerDate = calendar.date(bySettingHour: lowerMinutes / 60, minute: lowerMinutes % 60, second: 0, of: baseDate) ?? baseDate
        let upperDate = calendar.date(bySettingHour: upperMinutes / 60, minute: upperMinutes % 60, second: 0, of: baseDate) ?? baseDate
        return lowerDate...upperDate
    }

    private var selectedWindow: DeliveryWindowOption {
        let minutes = (Calendar.current.component(.hour, from: selectedTime) * 60) + Calendar.current.component(.minute, from: selectedTime)
        return provider.closestDeliveryWindow(to: minutes)
    }

    private var deliveryTimeBinding: Binding<Date> {
        Binding(
            get: { selectedTime },
            set: { newValue in
                let baseDate = scheduledDeliveryDate ?? .now
                selectedTime = provider.closestAvailableDeliveryTime(from: newValue, on: baseDate)
            }
        )
    }
}

private struct PrepRouteOverlay: View {
    let snapshot: PrepDeliverySnapshot
    let providerTitle: String?
    let storeTitle: String?
    let etaText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                let title = [providerTitle, storeTitle]
                    .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .joined(separator: " • ")

                Label(title.isEmpty ? "Delivery" : title, systemImage: "storefront.fill")
                    .biroHeaderFont(11)
                    .foregroundStyle(OunjePalette.primaryText)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(
                        Capsule(style: .continuous)
                            .fill(OunjePalette.panel.opacity(0.92))
                    )

                Spacer(minLength: 0)

                Image(systemName: snapshot.stage == .delivered ? "checkmark.circle.fill" : "box.truck.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(snapshot.stage == .delivered ? OunjePalette.softCream : OunjePalette.primaryText)
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule(style: .continuous)
                        .fill(OunjePalette.panel.opacity(0.92))

                    Capsule(style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Color(hex: "D7C295").opacity(0.96), Color(hex: "B88852").opacity(0.88)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: max(26, proxy.size.width * snapshot.progress))
                }
            }
            .frame(height: 7)

            HStack(spacing: 8) {
                Text(snapshot.statusLabel)
                    .biroHeaderFont(12)
                    .foregroundStyle(OunjePalette.primaryText)

                if let etaText {
                    Text("•")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(OunjePalette.secondaryText)
                    Text(etaText)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(OunjePalette.secondaryText)
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(OunjePalette.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(OunjePalette.stroke, lineWidth: 1)
                )
        )
        .shadow(color: .black.opacity(0.18), radius: 12, y: 6)
    }
}

private struct FloatingSearchDock: View {
    @Binding var text: String
    let placeholder: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(OunjePalette.secondaryText)

            TextField("", text: $text, prompt: Text(placeholder).foregroundColor(OunjePalette.secondaryText))
                .font(.system(size: 17, weight: .medium, design: .rounded))
                .foregroundStyle(OunjePalette.primaryText)

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(OunjePalette.secondaryText)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(
            Capsule(style: .continuous)
                .fill(OunjePalette.surface.opacity(0.96))
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(OunjePalette.stroke, lineWidth: 1)
                )
        )
    }
}

private enum AppTab: String, CaseIterable, Identifiable {
    case prep
    case discover
    case cookbook
    case cart
    case profile

    var id: String { rawValue }

    var title: String {
        switch self {
        case .prep: return "Prep"
        case .discover: return "Discover"
        case .cookbook: return "Cookbook"
        case .cart: return "Cart"
        case .profile: return "Profile"
        }
    }

    var symbol: String {
        switch self {
        case .prep: return "calendar"
        case .discover: return "safari"
        case .cookbook: return "book.closed"
        case .cart: return "basket"
        case .profile: return "person.crop.circle"
        }
    }

    var showsSearchDock: Bool {
        switch self {
        case .discover, .cookbook, .cart:
            return true
        case .prep, .profile:
            return false
        }
    }
}

private struct CustomTabBar: View {
    @Binding var selectedTab: AppTab

    var body: some View {
        HStack(spacing: 0) {
            ForEach(AppTab.allCases) { tab in
                Button {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.8)) {
                        selectedTab = tab
                    }
                } label: {
                    VStack(spacing: 3) {
                        Capsule(style: .continuous)
                            .fill(selectedTab == tab ? OunjePalette.accent.opacity(0.92) : .clear)
                            .frame(width: 22, height: 3)
                            .padding(.bottom, 3)

                        Image(systemName: tab.symbol)
                            .font(.system(size: 22, weight: selectedTab == tab ? .semibold : .medium))
                            .foregroundStyle(selectedTab == tab ? OunjePalette.primaryText : OunjePalette.secondaryText)

                        Text(tab.title)
                            .sleeDisplayFont(13)
                            .foregroundStyle(selectedTab == tab ? OunjePalette.primaryText : OunjePalette.secondaryText)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: OunjeLayout.tabBarHeight)
    }
}

private struct BottomNavigationDock: View {
    @Binding var selectedTab: AppTab
    var searchText: Binding<String>?
    var searchPlaceholder: String?
    var safeAreaBottom: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            if let searchText, let searchPlaceholder {
                VStack(spacing: 0) {
                    FloatingSearchDock(text: searchText, placeholder: searchPlaceholder)
                        .padding(.horizontal, 16)
                        .padding(.top, 14)
                        .padding(.bottom, 12)

                Rectangle()
                        .fill(OunjePalette.stroke)
                    .frame(height: 1)
                        .padding(.horizontal, 16)
                }
            }

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
    @EnvironmentObject private var store: MealPlanningAppStore
    @EnvironmentObject private var toastCenter: AppToastCenter
    let context: CookbookComposerContext
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
            return "Paste a link, add media, or describe what you want."
        case .saved:
            return "Paste a link, add media, or describe what you want."
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
                                Button {
                                    insertLinkFromClipboard()
                                } label: {
                                    HStack(spacing: 8) {
                                        Image(systemName: "link")
                                            .font(.system(size: 14, weight: .semibold))
                                        Text("Link")
                                            .font(.system(size: 14, weight: .medium))
                                            .lineLimit(1)
                                    }
                                    .foregroundStyle(OunjePalette.primaryText)
                                    .opacity(isSubmitting ? 0.6 : 1)
                                }
                                .buttonStyle(.plain)
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
                                        Text(attachments.isEmpty ? "Attach file" : mediaButtonTitle)
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

        Task {
            do {
                let response = try await RecipeImportAPIService.shared.importRecipe(
                    userID: store.authSession?.userID,
                    accessToken: store.authSession?.accessToken,
                    sourceURL: detectedLinks.first,
                    sourceText: trimmedDraftText,
                    targetState: context == .prepped ? "prepped" : "saved",
                    attachments: attachments.map(\.payload)
                )

                await MainActor.run {
                    let importedRecipe = response.recipe
                    if let importedRecipe {
                        savedStore.saveImportedRecipe(importedRecipe, showToast: context == .saved)
                    }
                }
                NotificationCenter.default.post(name: .recipeImportReviewQueueNeedsRefresh, object: nil)

                if context == .prepped, let detail = response.recipeDetail {
                    await store.updateLatestPlan(with: recipeFromImportedDetail(detail), servings: detail.displayServings)
                }

                await MainActor.run {
                    isSubmitting = false

                    if response.job.status == "queued" || response.recipe == nil {
                        toastCenter.show(
                            title: "Import queued",
                            subtitle: "Ounje is pulling the recipe in now.",
                            systemImage: "tray.and.arrow.down.fill"
                        )
                    } else if context == .prepped, let detail = response.recipeDetail {
                        toastCenter.show(
                            title: "Added to next prep",
                            subtitle: detail.title,
                            systemImage: "sparkles",
                            thumbnailURLString: detail.discoverCardImageURLString ?? detail.heroImageURLString ?? detail.imageURL?.absoluteString
                        )
                    } else if response.job.reviewState == "draft" {
                        toastCenter.show(
                            title: "Saved as draft",
                            subtitle: response.recipe?.title ?? "Imported recipe",
                            systemImage: "doc.badge.gearshape",
                            thumbnailURLString: response.recipe?.imageURL?.absoluteString
                        )
                    } else if response.job.reviewState == "needs_review" {
                        toastCenter.show(
                            title: "Saved with notes",
                            subtitle: response.recipe?.title ?? "Imported recipe",
                            systemImage: "bookmark.fill",
                            thumbnailURLString: response.recipe?.imageURL?.absoluteString
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
                if let draft = try await RecipeImportMediaDraft.load(from: item) {
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

    private func insertLinkFromClipboard() {
        errorMessage = nil
        if let raw = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines),
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

        errorMessage = "Copy a link first, then tap Link."
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
            prepMinutes: detail.prepTimeMinutes ?? detail.cookTimeMinutes ?? 0,
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

    static func load(from item: PhotosPickerItem) async throws -> RecipeImportMediaDraft? {
        let imageType = item.supportedContentTypes.first(where: { $0.conforms(to: .image) })
        let videoType = item.supportedContentTypes.first(where: { $0.conforms(to: .movie) || $0.conforms(to: .video) })

        if let imageType {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                throw RecipeImportMediaError.unreadable
            }
            return try makeImageAttachment(from: data, contentType: imageType)
        }

        if let videoType {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                throw RecipeImportMediaError.unreadable
            }
            return try await makeVideoAttachment(from: data, contentType: videoType)
        }

        throw RecipeImportMediaError.unsupported
    }

    private static func makeImageAttachment(from data: Data, contentType: UTType) throws -> RecipeImportMediaDraft {
        guard let image = UIImage(data: data) else {
            throw RecipeImportMediaError.unreadable
        }

        let prepared = image.ounjeResized(maxDimension: 1600)
        let jpegData = prepared.jpegData(compressionQuality: 0.82) ?? data
        let payload = RecipeImportAttachmentPayload(
            kind: "image",
            sourceURL: nil,
            dataURL: "data:image/jpeg;base64,\(jpegData.base64EncodedString())",
            mimeType: "image/jpeg",
            fileName: "recipe-photo.\(contentType.preferredFilenameExtension ?? "jpg")",
            previewFrameURLs: []
        )

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

private func importedRecipePlanModel(from detail: RecipeDetailData) -> Recipe {
    let ingredientSource = detail.ingredients.isEmpty ? detail.steps.flatMap(\.ingredients) : detail.ingredients
    let ingredients = ingredientSource.map { ingredient in
        let measurement = importedRecipeMeasurement(from: ingredient.quantityText)
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
        cuisine: importedRecipeCuisinePreference(from: detail),
        prepMinutes: detail.prepTimeMinutes ?? detail.cookTimeMinutes ?? 0,
        servings: max(1, detail.displayServings),
        storageFootprint: .medium,
        tags: importedRecipeTags(from: detail),
        ingredients: ingredients,
        cardImageURLString: detail.discoverCardImageURLString ?? detail.imageURL?.absoluteString,
        heroImageURLString: detail.heroImageURLString ?? detail.imageURL?.absoluteString,
        source: detail.source ?? detail.sourcePlatform ?? detail.authorLine
    )
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
        }
    }
}

private extension UIImage {
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

private struct ThemedCard<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        BubblySurfaceCard(accent: OunjePalette.accent, content: content)
    }
}

private struct DiscoverRemoteRecipeCard: View {
    let recipe: DiscoverRecipeCardData
    let secondaryTopAction: DiscoverRemoteRecipeCardTopAction?
    let onSelect: () -> Void
    @EnvironmentObject private var savedStore: SavedRecipesStore
    private let cardHeight: CGFloat = 292

    init(
        recipe: DiscoverRecipeCardData,
        secondaryTopAction: DiscoverRemoteRecipeCardTopAction? = nil,
        onSelect: @escaping () -> Void
    ) {
        self.recipe = recipe
        self.secondaryTopAction = secondaryTopAction
        self.onSelect = onSelect
    }

    var body: some View {
        Button {
            onSelect()
        } label: {
            VStack(alignment: .leading, spacing: 14) {
                DiscoverRemoteRecipeImage(recipe: recipe)
                    .frame(maxWidth: .infinity)
                    .frame(height: 188)
                    .clipped()

                VStack(alignment: .leading, spacing: 8) {
                    SleeRecipeCardTitleText(
                        recipe.displayTitle,
                        size: 22,
                        color: OunjePalette.primaryText
                    )
                        .lineLimit(2)
                        .minimumScaleFactor(0.84)
                        .frame(maxWidth: .infinity, minHeight: 42, maxHeight: 42, alignment: .topLeading)

                    HStack(spacing: 5) {
                        Image(systemName: "clock")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(OunjePalette.secondaryText)
                Text(recipe.compactCookTime ?? recipe.filterLabel)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(OunjePalette.secondaryText)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 64, maxHeight: 64, alignment: .topLeading)
                .padding(.horizontal, 2)
                .padding(.bottom, 2)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: cardHeight, maxHeight: cardHeight, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                OunjePalette.panel.opacity(0.98),
                                OunjePalette.surface.opacity(0.84)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            )
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(.white.opacity(0.06), lineWidth: 1)
            )
            .overlay(alignment: .topTrailing) {
                HStack(spacing: 8) {
                    Button {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                            savedStore.toggle(recipe)
                        }
                    } label: {
                        Image(systemName: savedStore.isSaved(recipe) ? "bookmark.fill" : "bookmark")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(savedStore.isSaved(recipe) ? OunjePalette.softCream : OunjePalette.primaryText.opacity(0.88))
                            .frame(width: 32, height: 32)
                            .background(
                                Circle()
                                    .fill(OunjePalette.surface.opacity(0.96))
                                    .overlay(
                                        Circle()
                                            .stroke(savedStore.isSaved(recipe) ? OunjePalette.accent.opacity(0.45) : OunjePalette.stroke, lineWidth: 1)
                                    )
                            )
                    }
                    .buttonStyle(.plain)

                    if let secondaryTopAction {
                        Button(action: secondaryTopAction.action) {
                            Image(systemName: secondaryTopAction.systemName)
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(OunjePalette.primaryText.opacity(0.88))
                                .frame(width: 32, height: 32)
                                .background(
                                    Circle()
                                        .fill(OunjePalette.surface.opacity(0.96))
                                        .overlay(
                                            Circle()
                                                .stroke(OunjePalette.stroke, lineWidth: 1)
                                        )
                                )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(secondaryTopAction.accessibilityLabel)
                    }
                }
                .padding(8)
            }
            .shadow(color: .black.opacity(0.16), radius: 12, x: 0, y: 8)
        }
        .buttonStyle(.plain)
    }
}

private struct DiscoverRemoteRecipeCardTopAction {
    let systemName: String
    let accessibilityLabel: String
    let action: () -> Void
}

private struct DiscoverRemoteRecipeImage: View {
    let recipe: DiscoverRecipeCardData
    @StateObject private var loader = DiscoverRecipeImageLoader()

    var body: some View {
        ZStack {
            if let uiImage = loader.image {
                Image(uiImage: uiImage)
                            .resizable()
                            .scaledToFill()
                    .frame(width: 146, height: 146)
                    .clipShape(Circle())
                    .overlay(
                        Circle()
                            .stroke(.white.opacity(0.08), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.24), radius: 18, x: 0, y: 12)
            } else if loader.isLoading {
                        ProgressView()
                            .tint(OunjePalette.accent)
            } else {
                fallback
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: recipe.id) {
            await loader.load(from: recipe.imageCandidates)
        }
    }

    private var fallback: some View {
        VStack(spacing: 10) {
            Text(recipe.emoji)
                .font(.system(size: 56))
            Text(recipe.filterLabel)
                .biroHeaderFont(13)
                .foregroundStyle(OunjePalette.secondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

@MainActor
private final class DiscoverRecipeImageLoader: ObservableObject {
    @Published var image: UIImage?
    @Published var isLoading = false
    private var lastKey: String?

    func load(from candidates: [URL]) async {
        let key = candidates.map(\.absoluteString).joined(separator: "|")
        if lastKey == key, image != nil {
            return
        }

        lastKey = key
        image = nil
        isLoading = true

        defer {
            isLoading = false
        }

        for url in candidates {
            do {
                var request = URLRequest(url: url)
                request.cachePolicy = .returnCacheDataElseLoad
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse,
                      (200 ... 299).contains(httpResponse.statusCode),
                      let fetched = UIImage(data: data)
                else {
                    continue
                }

                image = fetched
                return
            } catch {
                continue
            }
        }

        image = nil
    }
}

private struct RecipeDetailExperienceView: View {
    let presentedRecipe: PresentedRecipeDetail
    let onOpenCart: () -> Void
    @ObservedObject private var toastCenter: AppToastCenter

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @EnvironmentObject private var store: MealPlanningAppStore
    @EnvironmentObject private var savedStore: SavedRecipesStore
    @StateObject private var viewModel = RecipeDetailViewModel()
    @State private var relatedPresentedRecipe: PresentedRecipeDetail?
    @State private var servingsCount = 4
    @State private var baseServingsCount = 4
    @State private var shouldScrollToSteps = false
    @State private var showShareSheet = false
    @State private var showInlineVideo = false
    @State private var showInlineVideoFullscreen = false
    @State private var shouldResumeInlineVideoAfterFullscreen = false
    @State private var inlineVideoPlayer: AVPlayer?
    @State private var resolvedVideo: RecipeResolvedVideoData?
    @State private var isResolvingVideo = false
    @State private var webVideoAction: RecipeWebVideoAction = .none

    private let detailBackground = OunjePalette.background
    private let sectionDivider = OunjePalette.stroke

    init(presentedRecipe: PresentedRecipeDetail, onOpenCart: @escaping () -> Void, toastCenter: AppToastCenter) {
        self.presentedRecipe = presentedRecipe
        self.onOpenCart = onOpenCart
        _toastCenter = ObservedObject(wrappedValue: toastCenter)
    }

    private var detail: RecipeDetailData? {
        viewModel.detail
    }

    private var recipeID: String {
        detail?.id ?? presentedRecipe.id
    }

    private var isInCurrentPrep: Bool {
        store.latestPlan?.recipes.contains(where: { $0.recipe.id == recipeID }) ?? (presentedRecipe.plannedRecipe != nil)
    }

    private var primaryBottomActionTitle: String {
        isInCurrentPrep ? "Remove" : "Add"
    }

    private var ingredientSecondaryActionTitle: String {
        isInCurrentPrep ? "Remove from prep" : "Add to next prep"
    }

    private var servingsScale: Double {
        Double(max(1, servingsCount)) / Double(max(1, baseServingsCount))
    }

    private var imageCandidates: [URL] {
        detail?.imageCandidates ?? presentedRecipe.recipeCard.imageCandidates
    }

    private var titleText: String {
        detail?.title ?? presentedRecipe.recipeCard.title
    }

    private var descriptionText: String? {
        if let detailDescription = detail?.description, !detailDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return detailDescription
        }
        guard let fallback = presentedRecipe.recipeCard.description?.trimmingCharacters(in: .whitespacesAndNewlines),
              !fallback.isEmpty
        else {
            return nil
        }

        let blockedFallbacks = [
            "Scheduled for this prep cycle.",
            "Carried over from your last cycle.",
            "Find your next meal"
        ]
        if blockedFallbacks.contains(fallback) {
            return nil
        }

        return fallback
    }

    private var authorLine: String {
        detail?.authorLine ?? presentedRecipe.recipeCard.authorLabel
    }

    private var externalURL: URL? {
        detail?.originalURL ?? presentedRecipe.recipeCard.destinationURL
    }

    private var authorURL: URL? {
        guard let raw = detail?.authorURLString?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return nil
        }
        return URL(string: raw)
    }

    private var videoSourceURL: URL? {
        // Watch should only appear for recipes that explicitly have a DB video URL.
        detail?.attachedVideoURL
    }

    private var resolvedVideoURL: URL? {
        resolvedVideo?.url
    }

    private var hasVideoSource: Bool {
        videoSourceURL != nil
    }

    private var shareItems: [Any] {
        var items: [Any] = [titleText]
        if let url = externalURL {
            items.append(url)
        } else if let fallback = resolvedVideoURL {
            items.append(fallback)
        }
        return items
    }

    private var detailMetrics: [RecipeDetailMetric] {
        guard let detail else { return [] }
        return detail.detailsGrid.map { metric in
            guard metric.title == "Servings" else { return metric }
            return RecipeDetailMetric(title: metric.title, value: "\(max(1, servingsCount))")
        }
    }

    private var ingredientItems: [RecipeDetailIngredient] {
        guard let detail else { return [] }
        if !detail.ingredients.isEmpty {
            return detail.ingredients.map { $0.scaled(by: servingsScale) }
        }

        var seen = Set<String>()
        return detail.steps
            .flatMap(\.ingredients)
            .filter { ingredient in
                let key = ingredient.displayName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard !key.isEmpty else { return false }
                return seen.insert(key).inserted
            }
            .map { $0.scaled(by: servingsScale) }
    }

    private var instructionSteps: [RecipeDetailStep] {
        guard let detail else { return [] }
        return detail.steps.map { step in
            step.replacingIngredients(step.ingredients.map { $0.scaled(by: servingsScale) })
        }
    }

    private var isLoadingResolvedDetail: Bool {
        viewModel.isLoading && detail == nil
    }

    private var detailLoadFailed: Bool {
        !viewModel.isLoading && detail == nil && viewModel.errorMessage != nil
    }

    private var isLoadingSimilarRecipes: Bool {
        viewModel.isLoading && detail != nil && viewModel.similarRecipes.isEmpty
    }

    private var subtitleLine: String? {
        guard let detail else { return nil }
        let line = detail.authorLine.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.isEmpty || line.caseInsensitiveCompare("Ounje source") == .orderedSame || line.caseInsensitiveCompare("Source pending") == .orderedSame {
            return nil
        }
        return line
    }

    private var summaryLine: String? {
        guard let text = descriptionText?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return nil
        }
        let firstSentence = text.split(whereSeparator: { ".!?".contains($0) }).first.map(String.init) ?? text
        let collapsed = firstSentence.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !collapsed.isEmpty else { return nil }
        return collapsed
    }

    private func toggleInlineVideo() {
        if showInlineVideo {
            pauseInlineVideo()
            withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
                showInlineVideo = false
            }
            return
        }

        Task {
            guard let preparedVideo = await prepareInlineVideoIfNeeded() else { return }
            if preparedVideo.supportsNativePlayback, let videoURL = preparedVideo.url {
                let player = AVPlayer(url: videoURL)
                player.play()
                await MainActor.run {
                    inlineVideoPlayer = player
                }
            } else {
                await MainActor.run {
                    inlineVideoPlayer = nil
                }
            }

            await MainActor.run {
                withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
                    showInlineVideo = true
                }
            }
        }
    }

    private func closeInlineVideo() {
        pauseInlineVideo()
        withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
            showInlineVideo = false
        }
    }

    private func seekInlineVideo(delta: Double) {
        if let inlineVideoPlayer {
            let currentSeconds = inlineVideoPlayer.currentTime().seconds
            guard currentSeconds.isFinite else { return }
            let target = max(0, currentSeconds + delta)
            inlineVideoPlayer.seek(to: CMTime(seconds: target, preferredTimescale: 600))
            return
        }

        webVideoAction = RecipeWebVideoAction(kind: .seek(seconds: delta))
    }

    private func togglePlayback() {
        if let player = inlineVideoPlayer {
            if player.timeControlStatus == .playing {
                player.pause()
            } else {
                player.play()
            }
            return
        }

        webVideoAction = RecipeWebVideoAction(kind: .togglePlayback)
    }

    private func pauseInlineVideo() {
        inlineVideoPlayer?.pause()
        webVideoAction = RecipeWebVideoAction(kind: .pause)
    }

    private func prepareInlineVideoIfNeeded() async -> RecipeResolvedVideoData? {
        if let resolvedVideo, resolvedVideo.url != nil, resolvedVideo.mode != .unavailable {
            return resolvedVideo
        }

        guard let videoSourceURL else { return nil }

        await MainActor.run {
            isResolvingVideo = true
        }
        defer {
            Task { @MainActor in
                isResolvingVideo = false
            }
        }

        do {
            let resolved = try await RecipeVideoResolveService.shared.resolveVideo(from: videoSourceURL)
            await MainActor.run {
                resolvedVideo = resolved
            }
            return resolved
        } catch {
            let fallback = RecipeVideoURLResolver.fallbackVideo(from: videoSourceURL)
            await MainActor.run {
                resolvedVideo = fallback
            }
            return fallback
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let safeTop = geometry.safeAreaInsets.top
            let pageWidth = geometry.size.width
            let heroSize = min(pageWidth * 0.74, 312)
            let heroTopCrop = heroSize * 0.16
            let heroTopBleed: CGFloat = 18
            let heroHeight = max(160, heroSize - heroTopCrop - 8)
            let ingredientColumns = Array(repeating: GridItem(.flexible(), spacing: 18, alignment: .top), count: 4)
            ScrollViewReader { proxy in
                ZStack(alignment: .bottom) {
                    detailBackground
                        .ignoresSafeArea()

                    ScrollView {
                        VStack(spacing: 0) {
                            ZStack(alignment: .top) {
                                Color.clear
                                    .frame(height: heroHeight)
                                    .overlay(alignment: .topTrailing) {
                                        RecipeDetailHeroImage(candidates: imageCandidates)
                                            .frame(width: heroSize, height: heroSize)
                                            .offset(x: heroSize * 0.04, y: -(heroTopCrop + heroTopBleed))
                                            .allowsHitTesting(false)
                                    }
                                    .overlay(alignment: .topTrailing) {
                                        if hasVideoSource {
                                            RecipeDetailTopVideoButton(isActive: showInlineVideo) {
                                                toggleInlineVideo()
                                            }
                                            .padding(.trailing, 20)
                                            .padding(.top, max(safeTop - 2, 0) + 52 + 10)
                                        }
                                    }
                            }
                            .frame(maxWidth: .infinity, alignment: .topLeading)

                            VStack(alignment: .leading, spacing: 30) {
                                VStack(alignment: .leading, spacing: 16) {
                                    RecipeModalTitle(text: titleText)

                                if subtitleLine != nil || externalURL != nil {
                                    HStack(spacing: 8) {
                                        if let subtitleLine {
                                            Text(subtitleLine)
                                                .font(.system(size: 15, weight: .medium))
                                                .foregroundStyle(OunjePalette.secondaryText)
                                        }

                                        if let externalURL {
                                            if subtitleLine != nil {
                                                Text("•")
                                                    .foregroundStyle(OunjePalette.secondaryText)
                                            }

                                            Button("See original link") {
                                                openURL(externalURL)
                                            }
                                            .font(.system(size: 15, weight: .medium))
                                            .foregroundStyle(OunjePalette.softCream)
                                            .buttonStyle(.plain)
                                            .underline()
                                        }
                                    }
                                }

                                HStack(spacing: 8) {
                                    RecipeDetailCompactActionButton(
                                        title: savedStore.isSaved(presentedRecipe.recipeCard) ? "Saved" : "Save",
                                        systemImage: savedStore.isSaved(presentedRecipe.recipeCard) ? "bookmark.fill" : "bookmark",
                                        compact: true
                                    ) {
                                        withAnimation(.spring(response: 0.3, dampingFraction: 0.78)) {
                                            savedStore.toggle(presentedRecipe.recipeCard)
                                        }
                                    }

                                    RecipeDetailCompactActionButton(title: "Ask", systemImage: "sparkles", compact: true) {
                                        if let externalURL {
                                            openURL(externalURL)
                                        } else {
                                            shouldScrollToSteps = true
                                        }
                                    }

                                    if hasVideoSource {
                                        RecipeDetailCompactActionButton(title: "Watch", systemImage: "play.fill", compact: true) {
                                            toggleInlineVideo()
                                        }
                                    }

                                    RecipeDetailCompactActionButton(title: "Story", showsInstagramGlyph: true, compact: true) {
                                        if let authorURL {
                                            openURL(authorURL)
                                        } else if let externalURL {
                                            openURL(externalURL)
                                        }
                                    }
                                }

                            }

                            if let summaryLine {
                                Text(summaryLine)
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundStyle(OunjePalette.secondaryText)
                                    .lineLimit(2)
                                    .fixedSize(horizontal: false, vertical: true)
                            }

                            if isLoadingResolvedDetail {
                                RecipeDetailLoadingSections()
                            } else if detailLoadFailed {
                                RecipeDetailLoadFailedState(message: viewModel.errorMessage ?? "We couldn't load the full recipe.") {
                                    Task { await viewModel.load(for: presentedRecipe.id) }
                                }
                            } else {
                                if !detailMetrics.isEmpty {
                                    VStack(alignment: .leading, spacing: 16) {
                                        RecipeDetailSectionHeader(title: "Details")

                                        RecipeDetailMetricsGrid(metrics: detailMetrics)

                                        if let detailFootnote = detail?.detailFootnote, !detailFootnote.isEmpty {
                                            Text(detailFootnote)
                                                .font(.system(size: 14, weight: .medium))
                                                .foregroundStyle(OunjePalette.secondaryText)
                                                .fixedSize(horizontal: false, vertical: true)
                                                .padding(.top, 2)
                                        }
                                    }
                                }

                                if !ingredientItems.isEmpty {
                                    VStack(alignment: .leading, spacing: 20) {
                                        RecipeDetailSectionHeader(title: "Ingredients")

                                        LazyVGrid(
                                            columns: ingredientColumns,
                                            spacing: 24
                                        ) {
                                            ForEach(ingredientItems, id: \.stableID) { ingredient in
                                                RecipeIngredientTile(ingredient: ingredient)
                                            }
                                        }

                                        ingredientSecondaryButton
                                    }
                                    .padding(.top, detailMetrics.isEmpty ? 6 : 20)
                                }

                                if !instructionSteps.isEmpty {
                                    VStack(alignment: .leading, spacing: 12) {
                                        RecipeDetailSectionHeader(title: "Cooking Steps")
                                            .id("steps-anchor")

                                        VStack(spacing: 0) {
                                            ForEach(instructionSteps, id: \.number) { step in
                                                RecipeStepBlock(
                                                    step: step,
                                                    ingredientMatches: matchingIngredientChips(for: step, ingredients: ingredientItems),
                                                    dividerColor: sectionDivider
                                                )
                                            }
                                        }
                                    }
                                    .padding(.top, ingredientItems.isEmpty ? 8 : 26)
                                }

                                if detail != nil && (isLoadingSimilarRecipes || !viewModel.similarRecipes.isEmpty) {
                                    RecipeDetailEnjoySection(
                                        recipes: viewModel.similarRecipes,
                                        isLoading: isLoadingSimilarRecipes,
                                        onSelectRecipe: { recipe in
                                            relatedPresentedRecipe = PresentedRecipeDetail(recipeCard: recipe)
                                        }
                                    )
                                }
                            }

                            }
                            .frame(maxWidth: 820, alignment: .leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 14)
                            .padding(.top, 0)
                            .padding(.bottom, 160)
                        }
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                    .scrollIndicators(.hidden)
                    .onChange(of: shouldScrollToSteps) { shouldScroll in
                        guard shouldScroll else { return }
                        withAnimation(.spring(response: 0.42, dampingFraction: 0.84)) {
                            proxy.scrollTo("steps-anchor", anchor: .top)
                        }
                        shouldScrollToSteps = false
                    }

                    RecipeCookBottomBar(
                        servingsCount: $servingsCount,
                        actionTitle: primaryBottomActionTitle
                    ) {
                        handlePrimaryBottomAction()
                    }
                }
                .overlay(alignment: .top) {
                    LinearGradient(
                        colors: [
                            detailBackground,
                            detailBackground.opacity(0.82),
                            detailBackground.opacity(0)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: safeTop + 30)
                    .ignoresSafeArea(edges: .top)
                    .allowsHitTesting(false)
                }
                .overlay(alignment: .top) {
                    HStack(alignment: .top) {
                        RecipeDetailTopIconButton(symbolName: "arrow.left") {
                            dismiss()
                        }
                        Spacer()
                        RecipeDetailTopIconButton(symbolName: "arrow.up.right") {
                            showShareSheet = true
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, max(safeTop - 2, 0))
                }
                .overlay(alignment: .topTrailing) {
                    if showInlineVideo, let resolvedVideo, let resolvedURL = resolvedVideo.url {
                        VStack(alignment: .trailing, spacing: 10) {
                            VStack(spacing: 8) {
                                HStack(spacing: 8) {
                                    RecipeVideoControlButton(symbol: "backward.end.fill") {
                                        seekInlineVideo(delta: -5)
                                    }

                                    RecipeVideoControlButton(symbol: "forward.end.fill") {
                                        seekInlineVideo(delta: 5)
                                    }
                                }

                                HStack(spacing: 8) {
                                    RecipeVideoControlButton(symbol: "arrow.up.left.and.arrow.down.right") {
                                        pauseInlineVideo()
                                        shouldResumeInlineVideoAfterFullscreen = false
                                        showInlineVideoFullscreen = true
                                    }

                                    RecipeVideoControlButton(symbol: "xmark") {
                                        closeInlineVideo()
                                    }
                                }
                            }

                            RecipeInlineVideoCard(
                                video: resolvedVideo,
                                url: resolvedURL,
                                player: inlineVideoPlayer,
                                webAction: $webVideoAction
                            ) {
                                togglePlayback()
                            }
                        }
                        .padding(.trailing, 18)
                        .padding(.top, safeTop + 188)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                        .zIndex(4)
                    }
                }
                .frame(width: pageWidth, alignment: .topLeading)
                .clipped()
            }
            .overlay(alignment: .top) {
                if let toast = toastCenter.toast {
                    AppToastBanner(toast: toast)
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .allowsHitTesting(false)
                }
            }
            .task(id: presentedRecipe.id) {
                await viewModel.load(for: presentedRecipe.id)
                let loadedCount = presentedRecipe.plannedRecipe?.servings ?? viewModel.detail?.displayServings ?? 4
                baseServingsCount = max(1, loadedCount)
                servingsCount = max(1, loadedCount)
            }
        }
        .background(detailBackground.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showShareSheet) {
            RecipeShareSheet(activityItems: shareItems)
                .ignoresSafeArea()
        }
        .fullScreenCover(item: $relatedPresentedRecipe) { recipe in
            RecipeDetailExperienceView(
                presentedRecipe: recipe,
                onOpenCart: onOpenCart,
                toastCenter: toastCenter
            )
            .environmentObject(savedStore)
            .environmentObject(store)
        }
        .fullScreenCover(isPresented: $showInlineVideoFullscreen, onDismiss: {
            guard shouldResumeInlineVideoAfterFullscreen else { return }
            shouldResumeInlineVideoAfterFullscreen = false
            togglePlayback()
        }) {
            Group {
                if let resolvedVideo, let resolvedURL = resolvedVideo.url {
                    RecipeFullscreenVideoExperience(
                        video: resolvedVideo,
                        url: resolvedURL,
                        onMinimize: {
                            shouldResumeInlineVideoAfterFullscreen = true
                            showInlineVideoFullscreen = false
                        }
                    )
                } else {
                    Color.black.ignoresSafeArea()
                }
            }
        }
        .task(id: videoSourceURL?.absoluteString ?? "no-video") {
            guard videoSourceURL != nil else {
                resolvedVideo = nil
                return
            }
            _ = await prepareInlineVideoIfNeeded()
        }
        .onChange(of: servingsCount) { newValue in
            guard isInCurrentPrep else { return }
            guard newValue != baseServingsCount else { return }
            Task { await persistPrepServingsChange(newValue) }
        }
    }

    private var ingredientSecondaryButton: some View {
        Button {
            Task {
                if isInCurrentPrep {
                    await removeCurrentRecipeFromPrep()
                } else {
                    await addCurrentRecipeToPrep()
                }
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: isInCurrentPrep ? "minus.circle" : "wand.and.stars")
                Text(ingredientSecondaryActionTitle)
            }
            .font(.system(size: 18, weight: .medium))
            .foregroundStyle(OunjePalette.primaryText)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(
                        isInCurrentPrep
                            ? OunjePalette.surface
                            : OunjePalette.accent.opacity(0.22)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .stroke(
                                isInCurrentPrep
                                    ? OunjePalette.stroke
                                    : OunjePalette.accent.opacity(0.38),
                                lineWidth: 1
                            )
                    )
            )
            .shadow(
                color: isInCurrentPrep ? .clear : OunjePalette.accent.opacity(0.08),
                radius: 10,
                x: 0,
                y: 5
            )
        }
        .buttonStyle(.plain)
    }

    @MainActor
    private func handlePrimaryBottomAction() {
        Task {
            if isInCurrentPrep {
                await removeCurrentRecipeFromPrep()
            } else {
                await addCurrentRecipeToPrep()
            }
        }
    }

    @MainActor
    private func addCurrentRecipeToPrep() async {
        guard let detail else { return }
        let recipe = recipeFromDetail(detail)
        await store.updateLatestPlan(with: recipe, servings: servingsCount)
        baseServingsCount = max(1, servingsCount)
        toastCenter.show(
            title: "Added to next prep",
            subtitle: titleText,
            systemImage: "wand.and.stars",
            thumbnailURLString: toastPreviewImageURLString(for: detail)
        )
    }

    @MainActor
    private func persistPrepServingsChange(_ newServings: Int) async {
        guard let detail else { return }
        let recipe = recipeFromDetail(detail)
        await store.updateLatestPlan(with: recipe, servings: newServings)
        baseServingsCount = max(1, newServings)
    }

    @MainActor
    private func removeCurrentRecipeFromPrep() async {
        await store.removeRecipeFromLatestPlan(recipeID: recipeID)
        toastCenter.show(
            title: "Removed from next prep",
            subtitle: titleText,
            systemImage: "minus.circle.fill"
        )
    }

    private func recipeFromDetail(_ detail: RecipeDetailData) -> Recipe {
        let ingredientSource = detail.ingredients.isEmpty ? detail.steps.flatMap(\.ingredients) : detail.ingredients
        let ingredients = ingredientSource.map { ingredient in
            let measurement = Self.parsedIngredientMeasurement(from: ingredient.quantityText)
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
            cuisine: Self.cuisinePreference(from: detail),
            prepMinutes: detail.prepTimeMinutes ?? detail.cookTimeMinutes ?? 0,
            servings: max(1, servingsCount),
            storageFootprint: .medium,
            tags: Self.recipeTags(from: detail),
            ingredients: ingredients,
            cardImageURLString: detail.discoverCardImageURLString ?? detail.imageURL?.absoluteString,
            heroImageURLString: detail.heroImageURLString ?? detail.imageURL?.absoluteString,
            source: detail.source ?? detail.sourcePlatform ?? detail.authorLine
        )
    }

    private func toastPreviewImageURLString(for detail: RecipeDetailData) -> String? {
        let recipeImageCandidates = [
            detail.discoverCardImageURLString,
            detail.heroImageURLString,
            detail.imageURL?.absoluteString
        ]

        if let recipeImage = recipeImageCandidates
            .compactMap({ $0?.trimmingCharacters(in: .whitespacesAndNewlines) })
            .first(where: { !$0.isEmpty }) {
            return recipeImage
        }

        return detail.ingredients
            .compactMap(\.imageURL)
            .map(\.absoluteString)
            .first
    }

    private static func recipeTags(from detail: RecipeDetailData) -> [String] {
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

    private static func parsedIngredientMeasurement(from raw: String?) -> (amount: Double, unit: String)? {
        guard let raw else { return nil }
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }

        let pattern = #"^\s*((?:\d+\s+)?\d+/\d+|\d+(?:\.\d+)?)\s*(.*)$"#
        guard
            let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
            let match = regex.firstMatch(in: normalized, range: NSRange(normalized.startIndex..., in: normalized)),
            let amountRange = Range(match.range(at: 1), in: normalized)
        else {
            return nil
        }

        let amountText = String(normalized[amountRange])
        let amount = Self.parseIngredientAmount(amountText)
        let remainderRange = Range(match.range(at: 2), in: normalized)
        let unit = remainderRange.map { String(normalized[$0]).trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
        guard amount > 0 else { return nil }
        return (amount: amount, unit: unit.isEmpty ? "ct" : unit)
    }

    private static func parseIngredientAmount(_ text: String) -> Double {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains(" ") {
            let parts = trimmed.split(separator: " ", omittingEmptySubsequences: true)
            if parts.count == 2, let whole = Double(parts[0]), let fraction = parseSimpleFraction(String(parts[1])) {
                return whole + fraction
            }
        }

        if let fraction = parseSimpleFraction(trimmed) {
            return fraction
        }

        return Double(trimmed) ?? 0
    }

    private static func parseSimpleFraction(_ text: String) -> Double? {
        let parts = text.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count == 2,
              let numerator = Double(parts[0]),
              let denominator = Double(parts[1]),
              denominator != 0 else {
            return nil
        }
        return numerator / denominator
    }

    private static func cuisinePreference(from detail: RecipeDetailData) -> CuisinePreference {
        let candidates = detail.cuisineTags + [detail.category, detail.subcategory, detail.cookMethod, detail.mainProtein].compactMap { $0 }
        for candidate in candidates {
            let normalized = candidate
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: " ", with: "")
                .replacingOccurrences(of: "-", with: "")
                .lowercased()

            if let match = CuisinePreference.allCases.first(where: { $0.rawValue.lowercased() == normalized }) {
                return match
            }
        }

        return .american
    }

    private func ingredientTileTint(for index: Int) -> Color {
        let palette: [Color] = [
            OunjePalette.panel,
            OunjePalette.surface,
            OunjePalette.elevated,
            OunjePalette.panel
        ]
        return palette[index % palette.count]
    }

    private func recipeIngredientBadge(for ingredient: String) -> String {
        let normalized = ingredient.lowercased()
        if normalized.contains("chicken") { return "🍗" }
        if normalized.contains("turkey") { return "🦃" }
        if normalized.contains("beef") || normalized.contains("steak") || normalized.contains("pork") { return "🥩" }
        if normalized.contains("salmon") || normalized.contains("fish") || normalized.contains("shrimp") || normalized.contains("tilapia") { return "🐟" }
        if normalized.contains("egg") { return "🥚" }
        if normalized.contains("broccoli") { return "🥦" }
        if normalized.contains("spinach") || normalized.contains("lettuce") || normalized.contains("kale") { return "🥬" }
        if normalized.contains("carrot") { return "🥕" }
        if normalized.contains("potato") { return "🥔" }
        if normalized.contains("rice") { return "🍚" }
        if normalized.contains("pasta") || normalized.contains("noodle") { return "🍝" }
        if normalized.contains("cheese") || normalized.contains("cheddar") || normalized.contains("parmesan") { return "🧀" }
        if normalized.contains("milk") || normalized.contains("cream") { return "🥛" }
        if normalized.contains("bread") || normalized.contains("bun") { return "🍞" }
        if normalized.contains("tomato") { return "🍅" }
        if normalized.contains("pepper") { return "🫑" }
        if normalized.contains("garlic") { return "🧄" }
        if normalized.contains("onion") { return "🧅" }
        if normalized.contains("lemon") || normalized.contains("lime") { return "🍋" }
        if normalized.contains("bean") { return "🫘" }
        if normalized.contains("mushroom") { return "🍄" }
        if normalized.contains("oil") { return "🫒" }
        if normalized.contains("salt") { return "🧂" }
        if normalized.contains("water") || normalized.contains("broth") { return "🥣" }
        return "＋"
    }

    private func matchingIngredientChips(for step: RecipeDetailStep, ingredients: [RecipeDetailIngredient]) -> [String] {
        if !step.ingredients.isEmpty {
            return step.ingredients.prefix(4).map(\.lineText)
        }

        guard !ingredients.isEmpty else { return [] }
        let tokens = Set(
            step.text
                .lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.count > 2 }
        )

        return ingredients.filter { ingredient in
            let ingredientTokens = Set(
                ingredient.lineText
                    .lowercased()
                    .components(separatedBy: CharacterSet.alphanumerics.inverted)
                    .filter { $0.count > 2 }
            )
            return !tokens.isDisjoint(with: ingredientTokens)
        }
        .prefix(4)
        .map(\.lineText)
    }
}

private struct RecipeModalTitle: View {
    let text: String

    var body: some View {
        Text(text)
            .sleeDisplayFont(44)
            .foregroundStyle(OunjePalette.primaryText)
            .multilineTextAlignment(.leading)
            .lineSpacing(2)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct RecipeDetailSectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 28, weight: .regular, design: .serif))
            .foregroundStyle(OunjePalette.softCream)
    }
}

private struct RecipeDetailHeroImage: View {
    let candidates: [URL]
    @StateObject private var loader = DiscoverRecipeImageLoader()

    var body: some View {
        ZStack {
            if let image = loader.image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .clipShape(Circle())
                    .shadow(color: .black.opacity(0.24), radius: 18, y: 8)
            } else if loader.isLoading {
                ProgressView()
                    .tint(OunjePalette.softCream)
            } else {
                VStack(spacing: 18) {
                    Image(systemName: "fork.knife")
                        .font(.system(size: 34, weight: .medium))
                        .foregroundStyle(OunjePalette.secondaryText)
                    Text("Recipe preview")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(OunjePalette.secondaryText)
                }
            }
        }
        .task(id: candidates.map(\.absoluteString).joined(separator: "|")) {
            await loader.load(from: candidates)
        }
    }
}

private struct RecipeDetailTopIconButton: View {
    let symbolName: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbolName)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(OunjePalette.primaryText)
                .frame(width: 52, height: 52)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(OunjePalette.surface.opacity(0.96))
                        .overlay(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .stroke(OunjePalette.stroke, lineWidth: 1)
                        )
                )
        }
        .buttonStyle(.plain)
    }
}

private struct RecipeDetailTopVideoButton: View {
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        let baseFill: AnyShapeStyle = isActive
            ? AnyShapeStyle(OunjePalette.softCream.opacity(0.96))
            : AnyShapeStyle(
                LinearGradient(
                    colors: [
                        Color.white.opacity(0.20),
                        OunjePalette.accent.opacity(0.20),
                        OunjePalette.panel.opacity(0.58)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )

        Button(action: action) {
            Image(systemName: "play.fill")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(isActive ? Color.black.opacity(0.88) : OunjePalette.softCream)
                .frame(width: 52, height: 52)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(baseFill)
                        .background(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(.ultraThinMaterial)
                                .opacity(isActive ? 0 : 1)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(
                                    LinearGradient(
                                        colors: [
                                            Color.white.opacity(isActive ? 0.10 : 0.20),
                                            Color.white.opacity(0.02)
                                        ],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                                .blendMode(.screen)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .stroke(Color.white.opacity(isActive ? 0.24 : 0.18), lineWidth: 1)
                        )
                )
                .shadow(color: isActive ? OunjePalette.softCream.opacity(0.16) : .black.opacity(0.16), radius: 10, y: 6)
        }
        .buttonStyle(.plain)
    }
}

private struct FloatingSavedSearchButton: View {
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        let baseFill: AnyShapeStyle = isActive
            ? AnyShapeStyle(OunjePalette.softCream.opacity(0.96))
            : AnyShapeStyle(
                LinearGradient(
                    colors: [
                        Color.white.opacity(0.20),
                        OunjePalette.accent.opacity(0.20),
                        OunjePalette.panel.opacity(0.58)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )

        Button(action: action) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(isActive ? Color.black.opacity(0.88) : OunjePalette.softCream)
                .frame(width: 52, height: 52)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(baseFill)
                        .background(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(.ultraThinMaterial)
                                .opacity(isActive ? 0 : 1)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(
                                    LinearGradient(
                                        colors: [
                                            Color.white.opacity(isActive ? 0.10 : 0.20),
                                            Color.white.opacity(0.02)
                                        ],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                                .blendMode(.screen)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .stroke(Color.white.opacity(isActive ? 0.24 : 0.18), lineWidth: 1)
                        )
                )
                .shadow(color: isActive ? OunjePalette.softCream.opacity(0.16) : .black.opacity(0.16), radius: 10, y: 6)
        }
        .buttonStyle(.plain)
    }
}

private struct SavedSearchBottomDock: View {
    @Binding var text: String
    let placeholder: String
    @Binding var isPresented: Bool
    @FocusState private var isFocused: Bool

    private var hasQuery: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(OunjePalette.softCream.opacity(0.9))

            TextField("", text: $text, prompt: Text(placeholder).foregroundColor(OunjePalette.softCream.opacity(0.34)))
                .font(.system(size: 17, weight: .medium, design: .rounded))
                .foregroundStyle(OunjePalette.primaryText)
                .focused($isFocused)

            Spacer(minLength: 0)

            Button {
                if hasQuery {
                    text = ""
                }
                withAnimation(.spring(response: 0.28, dampingFraction: 0.9)) {
                    isPresented = false
                }
            } label: {
                Image(systemName: hasQuery ? "xmark.circle.fill" : "xmark")
                    .font(.system(size: hasQuery ? 18 : 15, weight: .semibold))
                    .foregroundStyle(OunjePalette.softCream.opacity(hasQuery ? 0.44 : 0.34))
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
        .background(
            Capsule(style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            OunjePalette.surface.opacity(0.98),
                            OunjePalette.panel.opacity(0.96),
                            OunjePalette.accent.opacity(0.12)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(OunjePalette.stroke.opacity(0.94), lineWidth: 1)
                )
        )
        .shadow(color: Color.black.opacity(0.22), radius: 22, y: 10)
        .onAppear {
            DispatchQueue.main.async {
                isFocused = true
            }
        }
    }
}

private struct RecipeInlineVideoCard: View {
    let video: RecipeResolvedVideoData
    let url: URL
    let player: AVPlayer?
    @Binding var webAction: RecipeWebVideoAction
    let onTap: () -> Void

    var body: some View {
        ZStack {
            Group {
                if video.supportsNativePlayback, let player {
                    RecipeNativeVideoView(player: player, videoGravity: .resizeAspectFill)
                } else {
                    RecipeInlineWebVideoView(video: video, url: url, action: $webAction)
                }
            }
            .allowsHitTesting(false)

            Color.clear
                .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .onTapGesture(perform: onTap)
        }
        .frame(width: 168, height: 248)
        .clipped()
        .frame(width: 168)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(OunjePalette.panel)
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(OunjePalette.stroke, lineWidth: 1)
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: .black.opacity(0.28), radius: 14, y: 8)
    }
}

private struct RecipeVideoControlButton: View {
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(OunjePalette.primaryText)
                .frame(width: 42, height: 42)
                .background(
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .fill(OunjePalette.surface.opacity(0.96))
                        .overlay(
                            RoundedRectangle(cornerRadius: 13, style: .continuous)
                                .stroke(OunjePalette.stroke, lineWidth: 1)
                        )
                )
        }
        .buttonStyle(.plain)
    }
}

private struct RecipeFullscreenVideoExperience: View {
    let video: RecipeResolvedVideoData
    let url: URL
    let onMinimize: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    @State private var webAction: RecipeWebVideoAction = .none

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topTrailing) {
                Color.black.ignoresSafeArea()

                Group {
                    if video.supportsNativePlayback {
                        if let player {
                            ZStack {
                                RecipeNativeVideoView(player: player, videoGravity: .resizeAspect)
                                    .allowsHitTesting(false)

                                Color.clear
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        if player.timeControlStatus == .playing {
                                            player.pause()
                                        } else {
                                            player.play()
                                        }
                                    }
                            }
                        } else {
                            ProgressView()
                                .tint(OunjePalette.softCream)
                        }
                    } else {
                        RecipeInlineWebVideoView(video: video, url: url, action: $webAction)
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
                .ignoresSafeArea()

                HStack(spacing: 10) {
                    RecipeDetailTopIconButton(symbolName: "pip.exit") {
                        onMinimize()
                    }

                    RecipeDetailTopIconButton(symbolName: "xmark") {
                        dismiss()
                    }
                }
                .padding(.trailing, 20)
                .padding(.top, geometry.safeAreaInsets.top + 10)
            }
        }
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .onAppear {
            guard video.supportsNativePlayback, player == nil else { return }
            let nextPlayer = AVPlayer(url: url)
            nextPlayer.play()
            player = nextPlayer
        }
        .onDisappear {
            player?.pause()
            webAction = RecipeWebVideoAction(kind: .pause)
        }
    }
}

private enum RecipeVideoURLResolver {
    static func fallbackVideo(from source: URL) -> RecipeResolvedVideoData {
        let resolvedURL = inAppPlayableURL(from: source)
        let mode: RecipeResolvedVideoData.PlaybackMode = supportsNativePlayback(resolvedURL ?? source) ? .native : .embed
        return RecipeResolvedVideoData(
            modeRawValue: mode.rawValue,
            provider: source.host,
            sourceURLString: source.absoluteString,
            resolvedURLString: resolvedURL?.absoluteString ?? source.absoluteString,
            posterURLString: nil,
            durationSeconds: nil
        )
    }

    static func inAppPlayableURL(from source: URL) -> URL? {
        guard let scheme = source.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return nil
        }

        if supportsNativePlayback(source) {
            return source
        }

        let host = source.host?.lowercased() ?? ""
        if host.contains("instagram.com") {
            return instagramEmbedURL(from: source)
        }
        if host.contains("tiktok.com") {
            return tiktokEmbedURL(from: source)
        }
        if host == "youtu.be" || host.contains("youtube.com") || host.contains("youtube-nocookie.com") {
            return youtubeEmbedURL(from: source)
        }
        if host.contains("vimeo.com") {
            return vimeoEmbedURL(from: source)
        }

        return source
    }

    static func supportsNativePlayback(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ["mp4", "m4v", "mov", "m3u8"].contains(ext)
    }

    private static func instagramEmbedURL(from source: URL) -> URL? {
        let components = source.pathComponents.filter { $0 != "/" }
        let kinds = Set(["reel", "p", "tv"])
        guard let kindIndex = components.firstIndex(where: { kinds.contains($0.lowercased()) }),
              kindIndex + 1 < components.count else {
            return nil
        }
        let kind = components[kindIndex].lowercased()
        let mediaID = components[kindIndex + 1]
        return URL(string: "https://www.instagram.com/\(kind)/\(mediaID)/embed/captioned/")
    }

    private static func tiktokEmbedURL(from source: URL) -> URL? {
        let components = source.pathComponents.filter { $0 != "/" }
        if components.contains("embed"), let original = URL(string: source.absoluteString) {
            return original
        }
        guard let videoIndex = components.firstIndex(of: "video"),
              videoIndex + 1 < components.count else {
            return nil
        }
        let videoID = components[videoIndex + 1]
        return URL(string: "https://www.tiktok.com/embed/v2/\(videoID)?autoplay=1")
    }

    private static func youtubeEmbedURL(from source: URL) -> URL? {
        let host = source.host?.lowercased() ?? ""
        let components = source.pathComponents.filter { $0 != "/" }
        var videoID: String?

        if host == "youtu.be" {
            videoID = components.first
        } else if components.first == "watch" || source.path == "/watch" {
            let queryItems = URLComponents(url: source, resolvingAgainstBaseURL: false)?.queryItems
            videoID = queryItems?.first(where: { $0.name == "v" })?.value
        } else if let shortsIndex = components.firstIndex(of: "shorts"), shortsIndex + 1 < components.count {
            videoID = components[shortsIndex + 1]
        } else if let embedIndex = components.firstIndex(of: "embed"), embedIndex + 1 < components.count {
            videoID = components[embedIndex + 1]
        }

        guard let videoID, !videoID.isEmpty else { return nil }
        return URL(string: "https://www.youtube.com/embed/\(videoID)?playsinline=1&autoplay=1&rel=0")
    }

    private static func vimeoEmbedURL(from source: URL) -> URL? {
        let components = source.pathComponents.filter { $0 != "/" }
        if components.first == "video", components.count >= 2 {
            return URL(string: "https://player.vimeo.com/video/\(components[1])?autoplay=1")
        }
        guard let numericID = components.reversed().first(where: { $0.allSatisfy(\.isNumber) }) else {
            return nil
        }
        return URL(string: "https://player.vimeo.com/video/\(numericID)?autoplay=1")
    }
}

private struct RecipeInlineWebVideoView: UIViewRepresentable {
    let video: RecipeResolvedVideoData
    let url: URL
    @Binding var action: RecipeWebVideoAction

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.userContentController.add(context.coordinator, name: "ounjeVideoState")

        let webView = WKWebView(frame: .zero, configuration: configuration)
        context.coordinator.webView = webView
        webView.navigationDelegate = context.coordinator
        webView.isOpaque = false
        webView.backgroundColor = UIColor.black
        webView.scrollView.backgroundColor = UIColor.black
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        context.coordinator.render(video: video, url: url, in: webView)
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        context.coordinator.render(video: video, url: url, in: uiView)

        if context.coordinator.lastActionID != action.id {
            context.coordinator.lastActionID = action.id
            context.coordinator.apply(action: action)
        }
    }

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: "ounjeVideoState")
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        weak var webView: WKWebView?
        var lastActionID: UUID?
        private var loadedSignature: String?
        private var currentMode: RecipeResolvedVideoData.PlaybackMode = .unavailable

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {}

        func render(video: RecipeResolvedVideoData, url: URL, in webView: WKWebView) {
            let signature = "\(video.mode.rawValue)|\(video.provider ?? "video")|\(url.absoluteString)"
            guard loadedSignature != signature else { return }

            loadedSignature = signature
            currentMode = video.mode

            if video.usesHostedIframe {
                webView.loadHTMLString(Self.iframeWrapperHTML(for: video, url: url), baseURL: URL(string: "https://iframe.ly"))
            } else {
                webView.load(URLRequest(url: url))
            }
        }

        func apply(action: RecipeWebVideoAction) {
            guard let webView else { return }

            let script: String?
            switch action.kind {
            case .none:
                script = nil
            case .togglePlayback:
                script = "window.ounjeTogglePlayback && window.ounjeTogglePlayback();"
            case let .seek(seconds):
                script = "window.ounjeSeekBy && window.ounjeSeekBy(\(seconds));"
            case .pause:
                script = "window.ounjePauseVideo && window.ounjePauseVideo();"
            }

            guard let script else { return }
            webView.evaluateJavaScript(script, completionHandler: nil)
        }

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            guard navigationAction.targetFrame == nil,
                  let url = navigationAction.request.url else {
                return nil
            }

            if shouldAllow(url: url) {
                webView.load(URLRequest(url: url))
            }
            return nil
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }

            if shouldAllow(url: url) {
                decisionHandler(.allow)
            } else {
                decisionHandler(.cancel)
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard currentMode != .iframe else { return }
            webView.evaluateJavaScript(Self.videoOnlyJavaScript, completionHandler: nil)
        }

        private func shouldAllow(url: URL) -> Bool {
            guard let scheme = url.scheme?.lowercased() else { return false }
            return ["http", "https", "about", "data", "blob"].contains(scheme)
        }

        private static func iframeWrapperHTML(for video: RecipeResolvedVideoData, url: URL) -> String {
            let source = htmlEscaped(url.absoluteString)
            let provider = (video.provider ?? "video").lowercased()
            if provider.contains("tiktok") {
                return tiktokPlayerHTML(src: source)
            }
            return iframelyPlayerHTML(src: source)
        }

        private static func tiktokPlayerHTML(src: String) -> String {
            """
            <!doctype html>
            <html>
            <head>
              <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no">
              <style>
                html, body { margin: 0; width: 100%; height: 100%; overflow: hidden; background: #000; }
                iframe { border: 0; width: 100vw; height: 100vh; background: #000; }
              </style>
            </head>
            <body>
              <iframe
                id="ounjePlayer"
                src="\(src)"
                allow="autoplay; fullscreen; picture-in-picture"
                allowfullscreen
                scrolling="no">
              </iframe>
              <script>
                const iframe = document.getElementById('ounjePlayer');
                let currentTime = 0;
                let paused = false;

                function post(type, value) {
                  if (!iframe || !iframe.contentWindow) return false;
                  const payload = { 'x-tiktok-player': true, type: type };
                  if (value !== undefined) payload.value = value;
                  iframe.contentWindow.postMessage(payload, '*');
                  return true;
                }

                window.addEventListener('message', function(event) {
                  try {
                    const data = typeof event.data === 'string' ? JSON.parse(event.data) : event.data;
                    if (!data || data['x-tiktok-player'] !== true) return;

                    const type = String(data.type || '');
                    const value = data.value;
                    if (type === 'onStateChange') {
                      const state = String(value || '').toLowerCase();
                      paused = !(state === 'playing' || state === 'play' || state === '1');
                    }

                    if (type === 'onCurrentTime') {
                      const next = Number((value && (value.currentTime || value.current_time || value.time)) ?? value ?? 0);
                      if (Number.isFinite(next)) currentTime = next;
                    }
                  } catch (_) {}
                });

                window.ounjeTogglePlayback = function() {
                  post(paused ? 'play' : 'pause');
                  paused = !paused;
                  return true;
                };

                window.ounjeSeekBy = function(seconds) {
                  const next = Math.max(0, currentTime + seconds);
                  currentTime = next;
                  post('seekTo', next);
                  return true;
                };

                window.ounjePauseVideo = function() {
                  paused = true;
                  post('pause');
                  return true;
                };
              </script>
            </body>
            </html>
            """
        }

        private static func iframelyPlayerHTML(src: String) -> String {
            """
            <!doctype html>
            <html>
            <head>
              <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no">
              <style>
                html, body { margin: 0; width: 100%; height: 100%; overflow: hidden; background: #000; }
                iframe { border: 0; width: 100vw; height: 100vh; background: #000; }
              </style>
              <script src="https://cdn.embed.ly/player-0.1.0.min.js"></script>
            </head>
            <body>
              <iframe
                id="ounjePlayer"
                src="\(src)"
                allow="autoplay; fullscreen; picture-in-picture"
                allowfullscreen
                scrolling="no">
              </iframe>
              <script>
                const iframe = document.getElementById('ounjePlayer');
                let player = null;
                let paused = false;
                let currentTime = 0;

                function boot() {
                  if (!window.playerjs || !iframe) return;
                  player = new playerjs.Player(iframe);

                  player.on('ready', function() {
                    try { player.play(); paused = false; } catch (_) {}
                  });
                  player.on('play', function() { paused = false; });
                  player.on('pause', function() { paused = true; });
                  player.on('timeupdate', function(data) {
                    const next = Number((data && (data.seconds || data.currentTime || data.time)) ?? 0);
                    if (Number.isFinite(next)) currentTime = next;
                  });
                }

                if (document.readyState === 'loading') {
                  document.addEventListener('DOMContentLoaded', boot);
                } else {
                  boot();
                }

                window.ounjeTogglePlayback = function() {
                  if (!player) return false;
                  try {
                    if (paused) { player.play(); paused = false; }
                    else { player.pause(); paused = true; }
                  } catch (_) {}
                  return true;
                };

                window.ounjeSeekBy = function(seconds) {
                  if (!player) return false;
                  const next = Math.max(0, currentTime + seconds);
                  currentTime = next;
                  try { player.setCurrentTime(next); } catch (_) {}
                  return true;
                };

                window.ounjePauseVideo = function() {
                  if (!player) return false;
                  paused = true;
                  try { player.pause(); } catch (_) {}
                  return true;
                };
              </script>
            </body>
            </html>
            """
        }

        private static func htmlEscaped(_ value: String) -> String {
            value
                .replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "\"", with: "&quot;")
                .replacingOccurrences(of: "'", with: "&#39;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
        }

        private static let videoOnlyJavaScript = """
        (function() {
          function rebuildIntoVideoOnly() {
            const videos = Array.from(document.querySelectorAll('video'));
            if (!videos.length) return false;
            videos.sort((a, b) => {
              const aSize = (a.videoWidth || a.clientWidth || 0) * (a.videoHeight || a.clientHeight || 0);
              const bSize = (b.videoWidth || b.clientWidth || 0) * (b.videoHeight || b.clientHeight || 0);
              return bSize - aSize;
            });
            const sourceVideo = videos[0];
            const src = sourceVideo.currentSrc || sourceVideo.src;
            const poster = sourceVideo.poster || "";
            if (!src) return false;

            if (!window.ounjeVideo || window.ounjeVideo.dataset.src !== src) {
              const video = document.createElement('video');
              video.src = src;
              if (poster) video.poster = poster;
              video.autoplay = true;
              video.loop = true;
              video.controls = false;
              video.muted = false;
              video.playsInline = true;
              video.preload = 'auto';
              video.dataset.src = src;
              video.style.width = '100%';
              video.style.height = '100%';
              video.style.objectFit = 'cover';
              video.style.background = '#000';

              document.documentElement.style.background = '#000';
              document.documentElement.style.margin = '0';
              document.documentElement.style.overflow = 'hidden';
              document.body.style.background = '#000';
              document.body.style.margin = '0';
              document.body.style.overflow = 'hidden';
              document.body.style.width = '100vw';
              document.body.style.height = '100vh';
              document.body.innerHTML = '';
              document.body.appendChild(video);
              window.ounjeVideo = video;
              video.play().catch(() => {});
            }
            return true;
          }

          window.ounjeTogglePlayback = function() {
            if (!window.ounjeVideo) return false;
            if (window.ounjeVideo.paused) {
              window.ounjeVideo.play().catch(() => {});
            } else {
              window.ounjeVideo.pause();
            }
            return true;
          };

          window.ounjeSeekBy = function(seconds) {
            if (!window.ounjeVideo) return false;
            const duration = Number.isFinite(window.ounjeVideo.duration) ? window.ounjeVideo.duration : 0;
            const nextTime = Math.max(0, window.ounjeVideo.currentTime + seconds);
            window.ounjeVideo.currentTime = duration > 0 ? Math.min(duration, nextTime) : nextTime;
            return true;
          };

          window.ounjePauseVideo = function() {
            if (!window.ounjeVideo) return false;
            window.ounjeVideo.pause();
            return true;
          };

          if (!rebuildIntoVideoOnly()) {
            let attempts = 0;
            const timer = setInterval(function() {
              attempts += 1;
              if (rebuildIntoVideoOnly() || attempts > 120) {
                clearInterval(timer);
              }
            }, 250);
          }
        })();
        """
    }
}

private struct RecipeNativeVideoView: UIViewRepresentable {
    let player: AVPlayer
    let videoGravity: AVLayerVideoGravity

    func makeUIView(context: Context) -> PlayerContainerView {
        let view = PlayerContainerView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = videoGravity
        view.backgroundColor = .black
        return view
    }

    func updateUIView(_ uiView: PlayerContainerView, context: Context) {
        uiView.playerLayer.player = player
        uiView.playerLayer.videoGravity = videoGravity
    }
}

private final class PlayerContainerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }

    var playerLayer: AVPlayerLayer {
        layer as! AVPlayerLayer
    }
}

private struct RecipeShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

private struct RecipeDetailActionButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 16, weight: .semibold))
                Text(title)
                    .font(.system(size: 16, weight: .medium))
            }
            .foregroundStyle(OunjePalette.primaryText)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(OunjePalette.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .stroke(OunjePalette.stroke, lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
    }
}

private struct RecipeDetailCompactActionButton: View {
    let title: String
    var systemImage: String? = nil
    var showsInstagramGlyph: Bool = false
    var compact: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if showsInstagramGlyph {
                    InstagramGlyphIcon(size: compact ? 15 : 17)
                } else if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: compact ? 14 : 16, weight: .semibold))
                }
                Text(title)
                    .font(.system(size: compact ? 15 : 16, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(OunjePalette.primaryText)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, compact ? 10 : 16)
            .padding(.vertical, compact ? 12 : 14)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(OunjePalette.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(OunjePalette.stroke, lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
    }
}

private struct InstagramGlyphIcon: View {
    let size: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .stroke(OunjePalette.primaryText, lineWidth: max(1.6, size * 0.12))
                .frame(width: size, height: size)

            Circle()
                .stroke(OunjePalette.primaryText, lineWidth: max(1.4, size * 0.11))
                .frame(width: size * 0.42, height: size * 0.42)

            Circle()
                .fill(OunjePalette.primaryText)
                .frame(width: size * 0.14, height: size * 0.14)
                .offset(x: size * 0.23, y: -size * 0.23)
        }
        .frame(width: size, height: size)
    }
}

private struct RecipeDetailMetricsGrid: View {
    let metrics: [RecipeDetailMetric]

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 0), count: 3)

    var body: some View {
        LazyVGrid(columns: columns, spacing: 0) {
            ForEach(Array(metrics.enumerated()), id: \.offset) { index, metric in
                VStack(alignment: .leading, spacing: 8) {
                    Text(metric.title)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(OunjePalette.secondaryText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                    Text(metric.value)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(OunjePalette.primaryText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .allowsTightening(true)
                }
                .frame(maxWidth: .infinity, minHeight: 94, alignment: .topLeading)
                .padding(16)
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(index >= 3 ? OunjePalette.stroke : .clear)
                        .frame(height: index >= 3 ? 1 : 0)
                }
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(index % 3 == 0 ? .clear : OunjePalette.stroke)
                        .frame(width: index % 3 == 0 ? 0 : 1)
                }
            }
        }
        .background(
            Rectangle()
                .fill(OunjePalette.background)
                .overlay(
                    Rectangle()
                        .stroke(OunjePalette.stroke, lineWidth: 1)
                )
        )
    }
}

private enum IngredientMonogramFormatter {
    static func monogram(for name: String) -> String {
        let parts = name
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { !$0.isEmpty }

        if parts.count >= 2 {
            let initials = parts.prefix(2).compactMap { $0.first.map { String($0).uppercased() } }.joined()
            if !initials.isEmpty {
                return initials
            }
        }

        if let first = parts.first {
            let pair = String(first.prefix(2)).uppercased()
            if !pair.isEmpty {
                return pair
            }
        }

        return "•"
    }
}

private struct RecipeIngredientTile: View {
    let ingredient: RecipeDetailIngredient
    @StateObject private var loader = DiscoverRecipeImageLoader()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack(alignment: .topTrailing) {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(OunjePalette.panel)

                if let image = loader.image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                } else if loader.isLoading {
                    ProgressView()
                        .tint(OunjePalette.softCream)
                } else {
                    Text(IngredientMonogramFormatter.monogram(for: ingredient.displayTitle))
                        .sleeDisplayFont(24)
                        .foregroundStyle(OunjePalette.softCream.opacity(0.9))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                }

            }
            .frame(height: 78)
            .task(id: ingredient.stableID) {
                if let url = ingredient.imageURL {
                    await loader.load(from: [url])
                }
            }

            Text(ingredient.displayTitle)
                .sleeDisplayFont(16)
                .foregroundStyle(OunjePalette.primaryText)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let quantityText = ingredient.displayQuantityText, !quantityText.isEmpty {
                Text(quantityText)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(OunjePalette.secondaryText)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

private struct RecipeStepBlock: View {
    let step: RecipeDetailStep
    let ingredientMatches: [String]
    let dividerColor: Color

    private let contentLeadingInset: CGFloat = 68

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 20) {
                Text(String(format: "%02d", step.number))
                    .biroHeaderFont(32)
                    .foregroundStyle(OunjePalette.softCream)
                    .frame(width: 48, alignment: .leading)

                VStack(alignment: .leading, spacing: 10) {
                    Text(step.text)
                        .font(.system(size: 18, weight: .regular))
                        .lineSpacing(4)
                        .foregroundStyle(OunjePalette.primaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)

                    if let tipText = step.tipText, !tipText.isEmpty {
                        Text(tipText)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(OunjePalette.secondaryText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if !ingredientMatches.isEmpty {
                GeometryReader { geometry in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(ingredientMatches, id: \.self) { match in
                                Text(match)
                                    .sleeDisplayFont(14)
                                    .foregroundStyle(OunjePalette.primaryText)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 10)
                                    .background(
                                        Capsule(style: .continuous)
                                            .fill(OunjePalette.panel.opacity(0.92))
                                            .overlay(
                                                Capsule(style: .continuous)
                                                    .stroke(OunjePalette.stroke, lineWidth: 1)
                                            )
                                    )
                            }
                        }
                        .padding(.leading, contentLeadingInset)
                        .padding(.trailing, 18)
                        .frame(minWidth: geometry.size.width + 92, alignment: .leading)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: 52)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 24)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(dividerColor)
                .frame(height: 1)
        }
    }
}

private struct RecipeDetailEnjoySection: View {
    let recipes: [DiscoverRecipeCardData]
    let isLoading: Bool
    let onSelectRecipe: (DiscoverRecipeCardData) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Spacer(minLength: 0)

                Text("Enjoy.")
                    .sleeDisplayFont(38)
                    .foregroundStyle(OunjePalette.softCream.opacity(0.9))
                    .shadow(color: .black.opacity(0.12), radius: 2, x: 0, y: 1)

                Spacer(minLength: 0)
            }
            .padding(.bottom, 34)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    if isLoading {
                        ForEach(0..<3, id: \.self) { _ in
                            RecipeEnjoyMiniCardPlaceholder()
                        }
                    } else {
                        ForEach(recipes) { recipe in
                            RecipeEnjoyMiniCard(recipe: recipe) {
                                onSelectRecipe(recipe)
                            }
                        }
                    }
                }
                .padding(.trailing, 8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 30)
        .padding(.bottom, 10)
    }
}

private struct RecipeEnjoyMiniCard: View {
    let recipe: DiscoverRecipeCardData
    let onSelect: () -> Void

    var body: some View {
        DiscoverRemoteRecipeCard(recipe: recipe) {
            onSelect()
        }
        .frame(width: 240)
    }
}

private struct RecipeEnjoyMiniCardPlaceholder: View {
    var body: some View {
        DiscoverRecipeCardLoadingPlaceholder(width: 240)
    }
}

private struct DiscoverRecipeCardLoadingPlaceholder: View {
    var width: CGFloat? = nil
    @State private var shimmerOffset: CGFloat = -1.2
    @State private var pulse = false

    init(width: CGFloat? = nil) {
        self.width = width
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Circle()
                .fill(OunjePalette.surface)
                .frame(width: 146, height: 146)
                .overlay(
                    Circle()
                        .stroke(.white.opacity(0.06), lineWidth: 1)
                )
                .modifier(LoadingSheen(offset: shimmerOffset))
                .scaleEffect(pulse ? 1.015 : 0.985)

            VStack(alignment: .leading, spacing: 9) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(OunjePalette.surface)
                    .frame(height: 22)
                    .modifier(LoadingSheen(offset: shimmerOffset))

                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(OunjePalette.surface.opacity(0.94))
                    .frame(width: 116, height: 14)
                    .modifier(LoadingSheen(offset: shimmerOffset))
            }
            .padding(.horizontal, 2)
        }
        .padding(14)
        .frame(width: width)
        .frame(maxWidth: width == nil ? .infinity : width, minHeight: 292, maxHeight: 292, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            OunjePalette.panel.opacity(0.98),
                            OunjePalette.surface.opacity(0.84)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(.white.opacity(0.06), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: .black.opacity(0.13), radius: 12, x: 0, y: 8)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.15).repeatForever(autoreverses: true)) {
                pulse.toggle()
            }
            withAnimation(.linear(duration: 1.35).repeatForever(autoreverses: false)) {
                shimmerOffset = 1.4
            }
        }
    }
}

private struct LoadingSheen: ViewModifier {
    let offset: CGFloat

    func body(content: Content) -> some View {
        content
            .overlay {
                GeometryReader { proxy in
                    let width = proxy.size.width
                    let height = proxy.size.height

                    LinearGradient(
                        colors: [
                            .clear,
                            .white.opacity(0.16),
                            .clear
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(width: max(54, width * 0.34), height: height * 1.7)
                    .rotationEffect(.degrees(18))
                    .offset(x: width * offset)
                }
                .allowsHitTesting(false)
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            }
    }
}

private struct FlexibleTagCloud: View {
    let tags: [String]

    var body: some View {
        WrappingHStack(tags, id: \.self, spacing: 10, lineSpacing: 12) { tag in
            Text(tag)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(OunjePalette.primaryText)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(
                    Capsule(style: .continuous)
                        .fill(OunjePalette.panel)
                        .overlay(
                            Capsule(style: .continuous)
                                .stroke(OunjePalette.stroke, lineWidth: 1)
                        )
                )
        }
    }
}

private struct RecipeCookBottomBar: View {
    @Binding var servingsCount: Int
    let actionTitle: String
    let onPrimaryAction: () -> Void

    var body: some View {
        GeometryReader { proxy in
            let availableWidth = proxy.size.width - 32
            let actionButtonWidth = min(max(118, availableWidth * 0.30), 142)

            HStack(spacing: 0) {
                HStack(spacing: 10) {
                    Button {
                        servingsCount = max(1, servingsCount - 1)
                    } label: {
                        Image(systemName: "minus")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(OunjePalette.primaryText)
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)

                    Text("\(servingsCount) servings")
                        .sleeDisplayFont(19)
                        .foregroundStyle(OunjePalette.primaryText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)
                        .fixedSize(horizontal: true, vertical: false)

                    Button {
                        servingsCount += 1
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(OunjePalette.primaryText)
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                }
                .frame(minHeight: 50)
                .padding(.leading, 6)

                Spacer(minLength: 20)

                Button(action: onPrimaryAction) {
                    Text(actionTitle)
                        .sleeDisplayFont(21)
                        .foregroundStyle(OunjePalette.primaryText)
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .background(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(actionTitle == "Remove" ? OunjePalette.surface : OunjePalette.accent)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                                        .stroke(
                                            actionTitle == "Remove"
                                                ? OunjePalette.stroke
                                                : Color.white.opacity(0.14),
                                            lineWidth: 1
                                        )
                                )
                        )
                        .shadow(
                            color: (actionTitle == "Remove" ? Color.black : OunjePalette.accent).opacity(0.12),
                            radius: 7,
                            x: 0,
                            y: 3
                        )
                }
                .frame(width: actionButtonWidth)
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 18)
            .padding(.top, 7)
            .padding(.bottom, 9)
        }
        .frame(height: 72)
        .background(
            OunjePalette.background
                .overlay(
                    Rectangle()
                        .fill(OunjePalette.stroke)
                        .frame(height: 1),
                    alignment: .top
                )
                .ignoresSafeArea(edges: .bottom)
        )
    }
}

private struct RecipeDetailLoadingSections: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            VStack(alignment: .leading, spacing: 16) {
                RecipeDetailSectionHeader(title: "Details")
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(OunjePalette.surface)
                    .frame(height: 282)
                    .redacted(reason: .placeholder)
            }

            VStack(alignment: .leading, spacing: 20) {
                RecipeDetailSectionHeader(title: "Ingredients")
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 4), spacing: 18) {
                    ForEach(0..<8, id: \.self) { _ in
                        VStack(alignment: .leading, spacing: 10) {
                            RoundedRectangle(cornerRadius: 20, style: .continuous)
                                .fill(OunjePalette.surface)
                                .frame(height: 96)
                                .redacted(reason: .placeholder)

                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(OunjePalette.surface)
                                .frame(height: 14)
                                .redacted(reason: .placeholder)

                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(OunjePalette.surface)
                                .frame(width: 48, height: 12)
                                .redacted(reason: .placeholder)
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 12) {
                RecipeDetailSectionHeader(title: "Cooking Steps")
                ForEach(0..<3, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(OunjePalette.surface)
                        .frame(height: 118)
                        .redacted(reason: .placeholder)
                }
            }
        }
    }
}

private struct RecipeDetailLoadFailedState: View {
    let message: String
    let onRetry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            RecipeDetailSectionHeader(title: "Recipe unavailable")

            Text(message)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(OunjePalette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            Button("Try again", action: onRetry)
                .buttonStyle(PrimaryPillButtonStyle())
                .frame(maxWidth: 180)
        }
        .padding(24)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(OunjePalette.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(OunjePalette.stroke, lineWidth: 1)
                )
        )
    }
}

private struct WrappingHStack<Data: RandomAccessCollection, ID: Hashable, Content: View>: View where Data.Element: Hashable {
    let data: Data
    let id: KeyPath<Data.Element, ID>
    let spacing: CGFloat
    let lineSpacing: CGFloat
    let content: (Data.Element) -> Content

    @State private var totalHeight: CGFloat = .zero

    init(_ data: Data, id: KeyPath<Data.Element, ID>, spacing: CGFloat, lineSpacing: CGFloat, @ViewBuilder content: @escaping (Data.Element) -> Content) {
        self.data = data
        self.id = id
        self.spacing = spacing
        self.lineSpacing = lineSpacing
        self.content = content
    }

    var body: some View {
        GeometryReader { geometry in
            generateContent(in: geometry)
        }
        .frame(height: totalHeight)
    }

    private func generateContent(in geometry: GeometryProxy) -> some View {
        var width = CGFloat.zero
        var height = CGFloat.zero

        return ZStack(alignment: .topLeading) {
            ForEach(Array(data), id: id) { item in
                content(item)
                    .padding(.trailing, spacing)
                    .padding(.bottom, lineSpacing)
                    .alignmentGuide(.leading) { dimension in
                        if abs(width - dimension.width) > geometry.size.width {
                            width = 0
                            height -= dimension.height + lineSpacing
                        }
                        let result = width
                        if item[keyPath: id] == data.last?[keyPath: id] {
                            width = 0
                        } else {
                            width -= dimension.width + spacing
                        }
                        return result
                    }
                    .alignmentGuide(.top) { _ in
                        let result = height
                        if item[keyPath: id] == data.last?[keyPath: id] {
                            height = 0
                        }
                        return result
                    }
            }
        }
        .background(
            GeometryReader { proxy in
                Color.clear
                    .onAppear {
                        totalHeight = proxy.size.height
                    }
                    .onChange(of: proxy.size.height) { newValue in
                        totalHeight = newValue
                    }
            }
        )
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

private struct BubblySurfaceCard<Content: View>: View {
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

private struct AddressSetupSheet: View {
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

                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        OnboardingSectionCard(
                            title: "Address details",
                            detail: "Start with street address. Picking a suggestion will fill the rest."
                        ) {
                            TextField("Street address", text: streetAddressSearchBinding)
                                .textInputAutocapitalization(.words)
                                .autocorrectionDisabled()
                                .modifier(OnboardingInputModifier())

                            if autocomplete.isResolving {
                                HStack(spacing: 8) {
                                    ProgressView()
                                        .controlSize(.small)
                                    Text("Checking address...")
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundStyle(OunjePalette.secondaryText)
                                }
                            }

                            if !autocomplete.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                if !autocomplete.results.isEmpty {
                                    VStack(spacing: 8) {
                                        ForEach(autocomplete.results) { suggestion in
                                            Button {
                                                Task { await onSuggestionSelected(suggestion) }
                                            } label: {
                                                VStack(alignment: .leading, spacing: 3) {
                                                    Text(suggestion.title)
                                                        .font(.system(size: 14, weight: .semibold))
                                                        .foregroundStyle(.white)
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
                                                        .fill(OunjePalette.elevated)
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

                        if !addressSummary.isEmpty {
                            OnboardingSectionCard(
                                title: "Current address",
                                detail: addressSummary
                            ) {
                                EmptyView()
                            }
                        }
                    }
                    .padding(.horizontal, OunjeLayout.screenHorizontalPadding)
                    .padding(.top, 18)
                    .padding(.bottom, 110)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done later") {
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
                Button(addressSummary.isEmpty ? "Skip for now" : "Save address") {
                    dismiss()
                }
                .buttonStyle(PrimaryPillButtonStyle())
                .padding(.horizontal, OunjeLayout.screenHorizontalPadding)
                .padding(.top, 10)
                .padding(.bottom, 14)
                .background(
                    LinearGradient(
                        colors: [
                            OunjePalette.background.opacity(0),
                            OunjePalette.background.opacity(0.9),
                            OunjePalette.background
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            if autocomplete.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               !addressLine1.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                autocomplete.query = [addressLine1, city, region]
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .joined(separator: ", ")
            }
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
    @ViewBuilder let content: () -> Content

    var body: some View {
        BubblySurfaceCard(accent: OunjePalette.accent) {
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
        }
    }
}

private struct OnboardingPromptCard: View {
    let step: FirstLoginOnboardingView.SetupStep

    @State private var isAnimating = false

    private var tint: Color {
        switch step {
        case .name:
            return OunjePalette.accent
        case .identity:
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
        case .summary:
            return Color(hex: "B2FFFF")
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
                    .fill(OunjePalette.surface.opacity(0.96))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(OunjePalette.stroke, lineWidth: 1)
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

private struct AgentSummaryAesthetic {
    let title: String
    let symbolName: String
    let primary: Color
    let secondary: Color
    let tertiary: Color
}

private extension UserProfile {
    var agentSummaryAesthetic: AgentSummaryAesthetic {
        let loweredCuisines = userFacingCuisineTitles.map { $0.lowercased() }
        let loweredGoals = mealPrepGoals.map { $0.lowercased() }
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

        if loweredGoals.contains(where: { $0.contains("speed") || $0.contains("cleanup") || $0.contains("cost") }) {
            return AgentSummaryAesthetic(
                title: "Control Mode",
                symbolName: "bolt.fill",
                primary: OunjePalette.accent,
                secondary: Color(hex: "6AD6FF"),
                tertiary: Color(hex: "B2FFFF")
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

private struct AddressSuggestion: Identifiable, Hashable {
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

private final class AddressAutocompleteViewModel: NSObject, ObservableObject, MKLocalSearchCompleterDelegate {
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

private struct AgentSummaryExperienceCard: View {
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

private struct InferredAgentBrief: Codable, Hashable {
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
        let varietyWeight = min(100, 25 + (profile.userFacingCuisineTitles.count * 10) + (profile.cuisineCountries.count * 8) + (profile.mealPrepGoals.contains(where: { $0.localizedCaseInsensitiveContains("variety") }) ? 14 : 0))
        let budgetWeight = profile.budgetFlexibility.calibrationScore
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
            AgentBriefGraphItem(label: "Budget flex", value: budgetWeight, caption: profile.budgetWindow == .weekly ? "Weekly spend tolerance" : "Monthly spend tolerance"),
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

private struct AgentBriefGraphItem: Codable, Hashable, Identifiable {
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

private final class SupabaseAgentBriefService {
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
        var endpoints: [AgentBriefEndpoint] = [.supabaseFunction]
#if targetEnvironment(simulator)
        endpoints.append(.localDevelopment)
#endif
        return endpoints
    }

    private func requestBrief(from endpoint: AgentBriefEndpoint, payload: SupabaseAgentBriefRequestPayload) async throws -> InferredAgentBrief {
        var request = URLRequest(url: endpoint.url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        switch endpoint {
        case .supabaseFunction:
            request.setValue(SupabaseConfig.anonKey, forHTTPHeaderField: "apikey")
            request.setValue("Bearer \(SupabaseConfig.anonKey)", forHTTPHeaderField: "Authorization")
        case .localDevelopment:
            break
        }

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
    case supabaseFunction
    case localDevelopment

    var url: URL {
        switch self {
        case .supabaseFunction:
            return URL(string: "\(SupabaseConfig.url)/functions/v1/agent-brief")!
        case .localDevelopment:
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

private struct PrimaryPillButtonStyle: ButtonStyle {
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

private struct WelcomeAuthButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.black.opacity(0.9))
            .frame(height: OunjeLayout.authButtonHeight)
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .background(
                Color.white,
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(.white.opacity(0.45), lineWidth: 1)
            )
            .shadow(color: .black.opacity(configuration.isPressed ? 0.14 : 0.24), radius: 10, x: 0, y: 5)
            .scaleEffect(configuration.isPressed ? 0.985 : 1.0)
    }
}

private struct SecondaryPillButtonStyle: ButtonStyle {
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
                                    ? [OunjePalette.accent.opacity(0.88), OunjePalette.linkText.opacity(0.72)]
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
                            ? (isPrimary ? .white.opacity(0.08) : OunjePalette.linkText.opacity(0.16))
                            : OunjePalette.stroke.opacity(0.7),
                        lineWidth: 1
                    )
            )
            .shadow(
                color: isEnabled
                    ? (isPrimary
                        ? OunjePalette.accent.opacity(configuration.isPressed ? 0.08 : 0.14)
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

private enum SupabaseConfig {
    static let url = "https://ztqptjimmcdoriefkqcx.supabase.co"
    static let anonKey = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Inp0cXB0amltbWNkb3JpZWZrcWN4Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzM2ODU3NDMsImV4cCI6MjA4OTI2MTc0M30.DncVXO-eWJDKlwQvceSHq4HYV-PuqSqlF8TbWVRZkLA"
}

private struct SupabaseAppleUserSession {
    let userID: String
    let email: String?
    let displayName: String?
    let accessToken: String?
}

private enum SupabaseAppleAuthError: LocalizedError {
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

private final class SupabaseAppleAuthService {
    static let shared = SupabaseAppleAuthService()

    private init() {}

    func signInWithApple(idToken: String, rawNonce: String) async throws -> SupabaseAppleUserSession {
        guard let url = URL(string: "\(SupabaseConfig.url)/auth/v1/token?grant_type=id_token") else {
            throw SupabaseAppleAuthError.invalidRequest
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(SupabaseConfig.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(SupabaseConfig.anonKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(SupabaseIdTokenRequest(
            provider: "apple",
            idToken: idToken,
            token: idToken,
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
            accessToken: tokenResponse.accessToken
        )
    }
}

private enum SupabaseProfileStateError: LocalizedError {
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

private enum SupabaseSavedRecipesError: LocalizedError {
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
                authProvider: row.authProvider.flatMap(AuthProvider.init(rawValue:))
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
                authProvider: authProvider ?? row.authProvider.flatMap(AuthProvider.init(rawValue:))
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
            authProvider: authProvider
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
            mealPrepGoals: profile?.mealPrepGoals ?? [],
            cadence: profile?.cadence.rawValue,
            deliveryAnchorDay: profile?.deliveryAnchorDay.rawValue,
            adults: profile?.consumption.adults,
            kids: profile?.consumption.kids,
            cooksForOthers: profile?.cooksForOthers,
            mealsPerWeek: profile?.consumption.mealsPerWeek,
            budgetPerCycle: profile?.budgetPerCycle,
            budgetWindow: profile?.budgetWindow.rawValue,
            budgetFlexibility: profile?.budgetFlexibility.rawValue,
            orderingAutonomy: profile?.orderingAutonomy.rawValue,
            kitchenEquipment: profile?.kitchenEquipment ?? [],
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

final class SupabaseSavedRecipesService {
    static let shared = SupabaseSavedRecipesService()
    private let legacyKey = "ounje-saved-recipes-v1"
    private let keyPrefix = "ounje-saved-recipes-v2"

    private init() {}

    func resolvedSavedRecipeIDs(userID: String?) async -> [String] {
        let localIDs = locallyCachedSavedRecipeIDs(userID: userID)
        guard let userID else { return localIDs }

        do {
            let remoteIDs = try await fetchSavedRecipeIDs(userID: userID)
            return Array(Set(localIDs + remoteIDs))
        } catch {
            return localIDs
        }
    }

    func fetchSavedRecipeIDs(userID: String) async throws -> [String] {
        guard let encodedUserID = userID.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(
                string: "\(SupabaseConfig.url)/rest/v1/saved_recipes?select=recipe_id&user_id=eq.\(encodedUserID)&order=saved_at.desc"
              ) else {
            throw SupabaseSavedRecipesError.invalidRequest
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(SupabaseConfig.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(SupabaseConfig.anonKey)", forHTTPHeaderField: "Authorization")

        let (data, httpResponse) = try await perform(request)
        guard (200...299).contains(httpResponse.statusCode) else {
            let errorPayload = try? JSONDecoder().decode(SupabaseRestErrorResponse.self, from: data)
            let fallback = "Failed to read saved recipe ids (\(httpResponse.statusCode))."
            throw SupabaseSavedRecipesError.requestFailed(errorPayload?.message ?? errorPayload?.error ?? fallback)
        }

        return try JSONDecoder().decode([SupabaseSavedRecipeIDRow].self, from: data).map(\.recipeID)
    }

    fileprivate func fetchSavedRecipes(userID: String) async throws -> [DiscoverRecipeCardData] {
        guard let encodedUserID = userID.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(
                string: "\(SupabaseConfig.url)/rest/v1/saved_recipes?select=recipe_id,title,description,author_name,author_handle,category,recipe_type,cook_time_text,published_date,discover_card_image_url,hero_image_url,recipe_url,source&user_id=eq.\(encodedUserID)&order=saved_at.desc"
              ) else {
            throw SupabaseSavedRecipesError.invalidRequest
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(SupabaseConfig.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(SupabaseConfig.anonKey)", forHTTPHeaderField: "Authorization")

        let (data, httpResponse) = try await perform(request)
        guard (200...299).contains(httpResponse.statusCode) else {
            let errorPayload = try? JSONDecoder().decode(SupabaseRestErrorResponse.self, from: data)
            let fallback = "Failed to read saved recipes (\(httpResponse.statusCode))."
            throw SupabaseSavedRecipesError.requestFailed(errorPayload?.message ?? errorPayload?.error ?? fallback)
        }

        return try JSONDecoder().decode([SupabaseSavedRecipeRow].self, from: data).map(\.recipe)
    }

    fileprivate func upsertSavedRecipes(userID: String, recipes: [DiscoverRecipeCardData]) async throws {
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
        request.setValue(SupabaseConfig.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(SupabaseConfig.anonKey)", forHTTPHeaderField: "Authorization")
        request.setValue("resolution=merge-duplicates,return=minimal", forHTTPHeaderField: "Prefer")
        request.httpBody = try JSONEncoder().encode(payload)

        let (data, httpResponse) = try await perform(request)
        guard (200...299).contains(httpResponse.statusCode) else {
            let errorPayload = try? JSONDecoder().decode(SupabaseRestErrorResponse.self, from: data)
            let fallback = "Failed to save recipe bookmark (\(httpResponse.statusCode))."
            throw SupabaseSavedRecipesError.requestFailed(errorPayload?.message ?? errorPayload?.error ?? fallback)
        }
    }

    fileprivate func deleteSavedRecipe(userID: String, recipeID: String) async throws {
        guard let encodedUserID = userID.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let encodedRecipeID = recipeID.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(
                string: "\(SupabaseConfig.url)/rest/v1/saved_recipes?user_id=eq.\(encodedUserID)&recipe_id=eq.\(encodedRecipeID)"
              ) else {
            throw SupabaseSavedRecipesError.invalidRequest
        }

        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue(SupabaseConfig.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(SupabaseConfig.anonKey)", forHTTPHeaderField: "Authorization")

        let (data, httpResponse) = try await perform(request)
        guard (200...299).contains(httpResponse.statusCode) else {
            let errorPayload = try? JSONDecoder().decode(SupabaseRestErrorResponse.self, from: data)
            let fallback = "Failed to remove saved recipe (\(httpResponse.statusCode))."
            throw SupabaseSavedRecipesError.requestFailed(errorPayload?.message ?? errorPayload?.error ?? fallback)
        }
    }

    private func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SupabaseSavedRecipesError.invalidResponse
        }
        return (data, httpResponse)
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

private enum SupabasePrepRecipeOverridesError: LocalizedError {
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

private struct SupabasePrepRecipeOverrideRow: Decodable, Identifiable, Hashable {
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

private struct SupabasePrepRecipeOverrideUpsertPayload: Encodable {
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

    func fetchPrepRecipeOverrides(userID: String) async throws -> [PrepRecipeOverride] {
        guard let encodedUserID = userID.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(
                string: "\(SupabaseConfig.url)/rest/v1/prep_recipe_overrides?select=user_id,recipe_id,recipe,servings,is_included_in_prep&user_id=eq.\(encodedUserID)&order=updated_at.desc"
              ) else {
            throw SupabasePrepRecipeOverridesError.invalidRequest
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(SupabaseConfig.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(SupabaseConfig.anonKey)", forHTTPHeaderField: "Authorization")

        let (data, httpResponse) = try await perform(request)
        guard (200...299).contains(httpResponse.statusCode) else {
            let errorPayload = try? JSONDecoder().decode(SupabaseRestErrorResponse.self, from: data)
            let fallback = "Failed to read prep overrides (\(httpResponse.statusCode))."
            throw SupabasePrepRecipeOverridesError.requestFailed(errorPayload?.message ?? errorPayload?.error ?? fallback)
        }

        return try JSONDecoder().decode([SupabasePrepRecipeOverrideRow].self, from: data).map(\.override)
    }

    func upsertPrepRecipeOverride(userID: String, override: PrepRecipeOverride) async throws {
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
        request.setValue("Bearer \(SupabaseConfig.anonKey)", forHTTPHeaderField: "Authorization")
        request.setValue("resolution=merge-duplicates,return=minimal", forHTTPHeaderField: "Prefer")
        request.httpBody = try JSONEncoder().encode([payload])

        let (data, httpResponse) = try await perform(request)
        guard (200...299).contains(httpResponse.statusCode) else {
            let errorPayload = try? JSONDecoder().decode(SupabaseRestErrorResponse.self, from: data)
            let fallback = "Failed to save prep override (\(httpResponse.statusCode))."
            throw SupabasePrepRecipeOverridesError.requestFailed(errorPayload?.message ?? errorPayload?.error ?? fallback)
        }
    }

    func deleteAllPrepRecipeOverrides(userID: String) async throws {
        guard let encodedUserID = userID.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(
                string: "\(SupabaseConfig.url)/rest/v1/prep_recipe_overrides?user_id=eq.\(encodedUserID)"
              ) else {
            throw SupabasePrepRecipeOverridesError.invalidRequest
        }

        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue(SupabaseConfig.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(SupabaseConfig.anonKey)", forHTTPHeaderField: "Authorization")

        let (data, httpResponse) = try await perform(request)
        guard (200...299).contains(httpResponse.statusCode) else {
            let errorPayload = try? JSONDecoder().decode(SupabaseRestErrorResponse.self, from: data)
            let fallback = "Failed to clear prep overrides (\(httpResponse.statusCode))."
            throw SupabasePrepRecipeOverridesError.requestFailed(errorPayload?.message ?? errorPayload?.error ?? fallback)
        }
    }

    private func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SupabasePrepRecipeOverridesError.invalidResponse
        }
        return (data, httpResponse)
    }
}

private enum SupabaseMealPrepCyclesError: LocalizedError {
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

private struct SupabaseMealPrepCycleUpsertPayload: Codable {
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

private struct SupabaseMealPrepCycleRow: Decodable {
    let plan: MealPlan
}

final class SupabaseMealPrepCycleService {
    static let shared = SupabaseMealPrepCycleService()
    private let timestampFormatter = ISO8601DateFormatter()

    private init() {}

    func fetchMealPrepCycles(userID: String) async throws -> [MealPlan] {
        guard let encodedUserID = userID.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(
                string: "\(SupabaseConfig.url)/rest/v1/meal_prep_cycles?select=plan&user_id=eq.\(encodedUserID)&order=generated_at.desc&limit=12"
              ) else {
            throw SupabaseMealPrepCyclesError.invalidRequest
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(SupabaseConfig.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(SupabaseConfig.anonKey)", forHTTPHeaderField: "Authorization")

        let (data, httpResponse) = try await perform(request)
        guard (200...299).contains(httpResponse.statusCode) else {
            let errorPayload = try? JSONDecoder().decode(SupabaseRestErrorResponse.self, from: data)
            let fallback = "Failed to read prep cycles (\(httpResponse.statusCode))."
            throw SupabaseMealPrepCyclesError.requestFailed(errorPayload?.message ?? errorPayload?.error ?? fallback)
        }

        return try JSONDecoder().decode([SupabaseMealPrepCycleRow].self, from: data).map(\.plan)
    }

    func upsertMealPrepCycle(userID: String, plan: MealPlan) async throws {
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
            let fallback = "Failed to save prep cycle (\(httpResponse.statusCode))."
            throw SupabaseMealPrepCyclesError.requestFailed(errorPayload?.message ?? errorPayload?.error ?? fallback)
        }
    }

    private func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SupabaseMealPrepCyclesError.invalidResponse
        }
        return (data, httpResponse)
    }
}

private enum SupabaseRecipeIngredientsError: LocalizedError {
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

private struct SupabaseRecipeIngredientRow: Decodable, Identifiable, Hashable {
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
            return promotedTitle
        }
        return displayName
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

        return replacingDisplayName(promotedDisplayName)
            .replacingQuantityText("")
    }

    private var normalizedQuantityText: String? {
        quantityText.trimmingCharacters(in: .whitespacesAndNewlines)
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
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if trimmed.rangeOfCharacter(from: .decimalDigits) != nil { return false }

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

private struct SupabaseIngredientRecord: Decodable, Hashable {
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

private struct SupabaseRecipeIngredientArtRow: Decodable, Hashable {
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

private struct CanonicalIngredientImageIndex {
    let records: [SupabaseIngredientRecord]

    private let recordsByID: [String: SupabaseIngredientRecord]
    private let recordsByName: [String: SupabaseIngredientRecord]

    init(records: [SupabaseIngredientRecord] = []) {
        self.records = records
        recordsByID = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        recordsByName = Dictionary(uniqueKeysWithValues: records.map {
            (SupabaseIngredientsCatalogService.normalizedName($0.matchKey), $0)
        })
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

private final class SupabaseIngredientsCatalogService {
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
            let fallbackArtByIngredientID = try await fetchFallbackRecipeArt(
                ingredientIDs: recordsNeedingFallbackArt.map(\.id)
            )

            for record in recordsNeedingFallbackArt {
                guard let fallbackImageURLString = fallbackArtByIngredientID[record.id] else { continue }
                merged[record.id] = record.replacingDefaultImageURLString(fallbackImageURLString)
            }
        }

        return Array(merged.values)
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

private final class SupabaseRecipeIngredientsService {
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

private final class SupabaseRecipeIngredientArtService {
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

private struct SupabaseIdTokenRequest: Codable {
    let provider: String
    let idToken: String
    let token: String
    let nonce: String

    enum CodingKeys: String, CodingKey {
        case provider
        case idToken = "id_token"
        case token
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
}

private struct SupabaseProfileUpsertPayload: Codable {
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
    let mealPrepGoals: [String]
    let cadence: String?
    let deliveryAnchorDay: String?
    let adults: Int?
    let kids: Int?
    let cooksForOthers: Bool?
    let mealsPerWeek: Int?
    let budgetPerCycle: Double?
    let budgetWindow: String?
    let budgetFlexibility: String?
    let orderingAutonomy: String?
    let kitchenEquipment: [String]
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
        case mealPrepGoals = "meal_prep_goals"
        case cadence
        case deliveryAnchorDay = "delivery_anchor_day"
        case adults
        case kids
        case cooksForOthers = "cooks_for_others"
        case mealsPerWeek = "meals_per_week"
        case budgetPerCycle = "budget_per_cycle"
        case budgetWindow = "budget_window"
        case budgetFlexibility = "budget_flexibility"
        case orderingAutonomy = "ordering_autonomy"
        case kitchenEquipment = "kitchen_equipment"
        case addressLine1 = "address_line1"
        case addressLine2 = "address_line2"
        case city
        case region
        case postalCode = "postal_code"
        case deliveryNotes = "delivery_notes"
        case profileJSON = "profile_json"
    }
}

private struct SupabaseProfileRow: Codable {
    let id: String?
    let email: String?
    let displayName: String?
    let authProvider: String?
    let onboarded: Bool?
    let lastOnboardingStep: Int?
    let profileJSON: UserProfile?
    let preferredName: String?
    let preferredCuisines: [String]?
    let cuisineCountries: [String]?
    let dietaryPatterns: [String]?
    let hardRestrictions: [String]?
    let mealPrepGoals: [String]?
    let cadence: String?
    let deliveryAnchorDay: String?
    let adults: Int?
    let kids: Int?
    let cooksForOthers: Bool?
    let mealsPerWeek: Int?
    let budgetPerCycle: Double?
    let budgetWindow: String?
    let budgetFlexibility: String?
    let orderingAutonomy: String?
    let kitchenEquipment: [String]?
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
        case onboarded
        case lastOnboardingStep = "last_onboarding_step"
        case profileJSON = "profile_json"
        case preferredName = "preferred_name"
        case preferredCuisines = "preferred_cuisines"
        case cuisineCountries = "cuisine_countries"
        case dietaryPatterns = "dietary_patterns"
        case hardRestrictions = "hard_restrictions"
        case mealPrepGoals = "meal_prep_goals"
        case cadence
        case deliveryAnchorDay = "delivery_anchor_day"
        case adults
        case kids
        case cooksForOthers = "cooks_for_others"
        case mealsPerWeek = "meals_per_week"
        case budgetPerCycle = "budget_per_cycle"
        case budgetWindow = "budget_window"
        case budgetFlexibility = "budget_flexibility"
        case orderingAutonomy = "ordering_autonomy"
        case kitchenEquipment = "kitchen_equipment"
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
              let budgetFlexibility,
              let orderingAutonomy else {
            return nil
        }

        let cuisines = preferredCuisines.compactMap(CuisinePreference.init(rawValue:))
        guard !cuisines.isEmpty,
              let cadenceValue = MealCadence(rawValue: cadence),
              let budgetWindowValue = BudgetWindow(rawValue: budgetWindow),
              let budgetFlexibilityValue = BudgetFlexibility(rawValue: budgetFlexibility),
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
                mealsPerWeek: mealsPerWeek ?? 5,
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
            mealPrepGoals: mealPrepGoals ?? [],
            cooksForOthers: cooksForOthers ?? false,
            kitchenEquipment: kitchenEquipment ?? [],
            budgetWindow: budgetWindowValue,
            budgetFlexibility: budgetFlexibilityValue,
            purchasingBehavior: .healthier,
            orderingAutonomy: orderingAutonomyValue
        )
    }
}

@MainActor
private final class DiscoverRecipesViewModel: ObservableObject {
    @Published private(set) var recipes: [DiscoverRecipeCardData] = []
    @Published private(set) var filters: [String] = DiscoverPreset.allTitles
    @Published private(set) var isLoading = false
    @Published private(set) var isTransitioningFeed = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var hasResolvedInitialLoad = false
    @Published var selectedFilter = "All"

    private var lastLoadKey: String?
    private var responseCache: [String: [DiscoverRecipeCardData]] = [:]
    private var activeRequestID: UUID?
    private let sessionSeed = String(UUID().uuidString.prefix(8))
    private var baseFeedRotationIndex = 0
    private var lastBaseRotationAt: Date?
    private var lastLoadedFilter = "All"

    func loadIfNeeded(profile: UserProfile?, query: String = "", feedContext: DiscoverFeedContext) async {
        let loadKey = cacheKey(profile: profile, filter: selectedFilter, query: query, feedContext: feedContext)
        guard lastLoadKey != loadKey else { return }
        await refresh(profile: profile, query: query, feedContext: feedContext)
    }

    func refresh(profile: UserProfile?, query: String = "", feedContext: DiscoverFeedContext) async {
        let requestID = UUID()
        activeRequestID = requestID
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let hadExistingRecipes = !recipes.isEmpty
        let isPresetTransition = normalizedQuery.isEmpty && selectedFilter != lastLoadedFilter
        let loadKey = cacheKey(profile: profile, filter: selectedFilter, query: normalizedQuery, feedContext: feedContext)

        if let cachedRecipes = responseCache[loadKey], !cachedRecipes.isEmpty {
            recipes = cachedRecipes
            hasResolvedInitialLoad = true
        }

        errorMessage = nil
        isLoading = true
        if isPresetTransition {
            isTransitioningFeed = true
        }
        if !normalizedQuery.isEmpty {
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled, activeRequestID == requestID else { return }
        }
        defer {
            if activeRequestID == requestID {
                isLoading = false
                isTransitioningFeed = false
            }
        }

        do {
            let requestSeed = normalizedQuery.isEmpty
                ? "\(sessionSeed)-base-\(baseFeedRotationIndex)"
                : "\(sessionSeed)-search"
            let feedLimit: Int
            if normalizedQuery.isEmpty {
                feedLimit = selectedFilter == "All" ? 40 : 54
            } else {
                feedLimit = 30
            }
            let response = try await SupabaseDiscoverRecipeService.shared.fetchRankedRecipes(
                profile: profile,
                filter: selectedFilter,
                query: normalizedQuery,
                sessionSeed: requestSeed,
                feedContext: feedContext,
                limit: feedLimit
            )
            guard activeRequestID == requestID else { return }
            recipes = response.recipes
            responseCache[loadKey] = response.recipes
            filters = DiscoverPreset.allTitles
            errorMessage = nil
            hasResolvedInitialLoad = true
            lastLoadedFilter = selectedFilter
            lastLoadKey = loadKey
            if !filters.contains(selectedFilter) {
                selectedFilter = "All"
            }
        } catch {
            guard activeRequestID == requestID else { return }

            do {
                let fallbackRecipes = try await SupabaseDiscoverRecipeService.shared.fetchRecipes(
                    limit: fallbackRecipeLimit(for: normalizedQuery)
                )
                guard activeRequestID == requestID else { return }
                recipes = applyLocalDiscoverFilters(to: fallbackRecipes, filter: selectedFilter, query: normalizedQuery)
                responseCache[loadKey] = recipes
                filters = DiscoverPreset.allTitles
                errorMessage = nil
                hasResolvedInitialLoad = true
                lastLoadedFilter = selectedFilter
                lastLoadKey = loadKey
                if !filters.contains(selectedFilter) {
                    selectedFilter = "All"
                }
            } catch {
                guard activeRequestID == requestID else { return }
                hasResolvedInitialLoad = true
                if hadExistingRecipes {
                    errorMessage = "Live Discover refresh failed, so we kept the last feed on screen."
                } else {
                    errorMessage = (error as? LocalizedError)?.errorDescription ?? "We couldn’t load the live recipe feed."
                }
            }
        }
    }

    func rotateBaseFeedIfNeeded(profile: UserProfile?, feedContext: DiscoverFeedContext) async {
        let now = Date()
        if let lastBaseRotationAt, now.timeIntervalSince(lastBaseRotationAt) < 4 {
            return
        }

        baseFeedRotationIndex += 1
        lastBaseRotationAt = now
        lastLoadKey = nil
        await refresh(profile: profile, query: "", feedContext: feedContext)
    }

    func forceReload(profile: UserProfile?, query: String = "", feedContext: DiscoverFeedContext) async {
        lastLoadKey = nil
        await refresh(profile: profile, query: query, feedContext: feedContext)
    }

    func selectFilter(_ filter: String, isSearching: Bool) {
        guard selectedFilter != filter else { return }
        selectedFilter = filter
        if !isSearching {
            isTransitioningFeed = true
        }
    }

    private func cacheKey(profile: UserProfile?, filter: String, query: String, feedContext: DiscoverFeedContext) -> String {
        let cuisines = profile?.preferredCuisines.map(\.rawValue).joined(separator: ",") ?? ""
        let dietary = profile?.dietaryPatterns.joined(separator: ",") ?? ""
        let foods = profile?.favoriteFoods.joined(separator: ",") ?? ""
        let flavors = profile?.favoriteFlavors.joined(separator: ",") ?? ""
        let goals = profile?.mealPrepGoals.joined(separator: ",") ?? ""
        let baseRotationKey = query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "|rotation:\(baseFeedRotationIndex)" : ""
        return "\(sessionSeed)|\(feedContext.cacheKey)|\(filter)|\(cuisines)|\(dietary)|\(foods)|\(flavors)|\(goals)|\(query)\(baseRotationKey)"
    }

    private func fallbackRecipeLimit(for normalizedQuery: String) -> Int {
        if normalizedQuery.isEmpty {
            return selectedFilter == "All" ? 300 : 600
        }
        return 600
    }

    private func applyLocalDiscoverFilters(
        to recipes: [DiscoverRecipeCardData],
        filter: String,
        query: String
    ) -> [DiscoverRecipeCardData] {
        let queryTerms = localDiscoverQueryTerms(from: query)

        return recipes.filter { recipe in
            let matchesFilter = recipe.matchesDiscoverFilter(filter)
            let matchesQuery = queryTerms.isEmpty || recipe.matchesDiscoverSearchTerms(queryTerms)
            return matchesFilter && matchesQuery
        }
    }

    private func localDiscoverQueryTerms(from query: String) -> [String] {
        let stopwords: Set<String> = [
            "a", "an", "the", "all",
            "what", "would", "like", "want", "need", "show", "find", "give",
            "me", "my", "you", "your", "can", "could", "should",
            "i", "im", "i'm", "to", "for", "of", "with", "in", "on", "at",
            "something", "anything", "ideas", "idea",
            "meal", "meals", "recipe", "recipes", "food", "foods",
            "today", "tonight", "now"
        ]

        return query
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { term in
                guard term.count > 1 else { return false }
                return !stopwords.contains(term)
            }
    }
}

private enum DiscoverPreset: CaseIterable {
    case all
    case breakfast
    case lunch
    case dinner
    case dessert
    case drinks
    case vegetarian
    case vegan
    case pasta
    case chicken
    case steak
    case fish
    case salad
    case sandwich
    case beans
    case potatoes
    case salmon
    case beginner
    case under500Cal

    var title: String {
        switch self {
        case .all: return "All"
        case .breakfast: return "Breakfast"
        case .lunch: return "Lunch"
        case .dinner: return "Dinner"
        case .dessert: return "Dessert"
        case .drinks: return "Drinks"
        case .vegetarian: return "Vegetarian"
        case .vegan: return "Vegan"
        case .pasta: return "Pasta"
        case .chicken: return "Chicken"
        case .steak: return "Steak"
        case .fish: return "Fish"
        case .salad: return "Salad"
        case .sandwich: return "Sandwich"
        case .beans: return "Beans"
        case .potatoes: return "Potatoes"
        case .salmon: return "Salmon"
        case .beginner: return "Beginner"
        case .under500Cal: return "Under 500 Cal"
        }
    }

    static var allTitles: [String] {
        DiscoverPreset.allCases.map(\.title)
    }

    static func normalizedKey(for title: String) -> String {
        let lowered = title
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "calories", with: "cal")
            .replacingOccurrences(of: "calorie", with: "cal")
            .replacingOccurrences(of: " ", with: "")

        switch lowered {
        case "", "all":
            return "all"
        case "breakfast":
            return "breakfast"
        case "lunch":
            return "lunch"
        case "dinner":
            return "dinner"
        case "dessert", "desserts":
            return "dessert"
        case "drinks", "drink":
            return "drinks"
        case "vegetarian":
            return "vegetarian"
        case "vegan":
            return "vegan"
        case "pasta":
            return "pasta"
        case "chicken":
            return "chicken"
        case "steak", "beef":
            return "steak"
        case "fish":
            return "fish"
        case "salad":
            return "salad"
        case "sandwich", "sandwiches":
            return "sandwich"
        case "beans", "bean", "legumes", "legume":
            return "beans"
        case "potatoes", "potato":
            return "potatoes"
        case "salmon":
            return "salmon"
        case "beginner":
            return "beginner"
        case "under500", "under500cal", "under500cals":
            return "under500"
        default:
            return lowered
        }
    }
}

private struct PresentedRecipeDetail: Identifiable {
    let recipeCard: DiscoverRecipeCardData
    let plannedRecipe: PlannedRecipe?

    init(recipeCard: DiscoverRecipeCardData, plannedRecipe: PlannedRecipe? = nil) {
        self.recipeCard = recipeCard
        self.plannedRecipe = plannedRecipe
    }

    init(plannedRecipe: PlannedRecipe) {
        self.recipeCard = DiscoverRecipeCardData(preppedRecipe: plannedRecipe)
        self.plannedRecipe = plannedRecipe
    }

    var id: String { recipeCard.id }
}

private struct RecipeDetailStep: Decodable, Hashable {
    let number: Int
    let text: String
    let tipText: String?
    let ingredientRefs: [String]
    let ingredients: [RecipeDetailIngredient]

    enum CodingKeys: String, CodingKey {
        case number
        case text
        case tipText = "tip_text"
        case ingredientRefs = "ingredient_refs"
        case ingredients
    }

    func replacingIngredients(_ ingredients: [RecipeDetailIngredient]) -> RecipeDetailStep {
        RecipeDetailStep(
            number: number,
            text: text,
            tipText: tipText,
            ingredientRefs: ingredientRefs,
            ingredients: ingredients
        )
    }
}

private struct RecipeDetailIngredient: Decodable, Hashable, Identifiable {
    let id: String?
    let ingredientID: String?
    let displayName: String
    let quantityText: String?
    let imageURLString: String?
    let sortOrder: Int?

    enum CodingKeys: String, CodingKey {
        case id
        case ingredientID = "ingredient_id"
        case displayName = "display_name"
        case quantityText = "quantity_text"
        case imageURLString = "image_url"
        case sortOrder = "sort_order"
    }

    var stableID: String {
        if let id, !id.isEmpty { return id }
        if let ingredientID, !ingredientID.isEmpty { return ingredientID }
        return displayName
    }

    var imageURL: URL? {
        guard let imageURLString, !imageURLString.isEmpty else { return nil }
        let normalized = imageURLString
            .replacingOccurrences(of: "https://firebasestorage.googleapis.com:443/", with: "https://firebasestorage.googleapis.com/")
            .replacingOccurrences(of: " ", with: "%20")
        return URL(string: normalized)
    }

    var lineText: String {
        [displayQuantityText, displayTitle]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    var displayTitle: String {
        if shouldPromoteQuantityTextToTitle, let promotedTitle = normalizedQuantityText {
            return promotedTitle
        }
        return displayName
    }

    var displayQuantityText: String? {
        if shouldPromoteQuantityTextToTitle {
            return nil
        }
        return RecipeQuantityFormatter.normalize(quantityText)
    }

    private var normalizedQuantityText: String? {
        quantityText?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var promotedDisplayName: String? {
        guard shouldPromoteQuantityTextToTitle else { return nil }
        return normalizedQuantityText
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
    }

    private func looksLikeIngredientName(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if trimmed.rangeOfCharacter(from: .decimalDigits) != nil { return false }

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

    func scaled(by factor: Double) -> RecipeDetailIngredient {
        guard factor > 0, abs(factor - 1) > 0.001 else { return self }
        return RecipeDetailIngredient(
            id: id,
            ingredientID: ingredientID,
            displayName: displayName,
            quantityText: RecipeQuantityFormatter.scaled(quantityText, by: factor),
            imageURLString: imageURLString,
            sortOrder: sortOrder
        )
    }

    func normalizedForDisplay() -> RecipeDetailIngredient {
        guard let promotedDisplayName else { return self }
        return RecipeDetailIngredient(
            id: id,
            ingredientID: ingredientID,
            displayName: promotedDisplayName,
            quantityText: nil,
            imageURLString: imageURLString,
            sortOrder: sortOrder
        )
    }

    func replacingDisplayName(_ value: String) -> RecipeDetailIngredient {
        RecipeDetailIngredient(
            id: id,
            ingredientID: ingredientID,
            displayName: value,
            quantityText: quantityText,
            imageURLString: imageURLString,
            sortOrder: sortOrder
        )
    }

    func replacingImageURLString(_ value: String?) -> RecipeDetailIngredient {
        RecipeDetailIngredient(
            id: id,
            ingredientID: ingredientID,
            displayName: displayName,
            quantityText: quantityText,
            imageURLString: value,
            sortOrder: sortOrder
        )
    }

    func replacingQuantityText(_ value: String?) -> RecipeDetailIngredient {
        RecipeDetailIngredient(
            id: id,
            ingredientID: ingredientID,
            displayName: displayName,
            quantityText: value,
            imageURLString: imageURLString,
            sortOrder: sortOrder
        )
    }
}

private enum RecipeQuantityFormatter {
    static func normalize(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let pounds = normalizedPounds(from: trimmed) {
            return pounds
        }

        return trimmed
            .replacingOccurrences(of: "  ", with: " ")
    }

    static func scaled(_ raw: String?, by factor: Double) -> String? {
        guard let normalized = normalize(raw) else { return nil }
        guard factor > 0, abs(factor - 1) > 0.001 else { return normalized }

        guard let measurement = parsedMeasurement(from: normalized) else {
            return normalized
        }

        let scaledAmount = measurement.amount * factor
        let amountText = formatAmount(scaledAmount)
        if measurement.unit.isEmpty {
            return amountText
        }
        return "\(amountText) \(measurement.unit)"
    }

    static func parsedMeasurement(from raw: String?) -> (amount: Double, unit: String)? {
        guard let normalized = normalize(raw) else { return nil }
        let pattern = #"^\s*((?:\d+\s+)?\d+/\d+|\d+(?:\.\d+)?)\s*(.*)$"#
        guard
            let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
            let match = regex.firstMatch(in: normalized, range: NSRange(normalized.startIndex..., in: normalized)),
            let amountRange = Range(match.range(at: 1), in: normalized)
        else {
            return nil
        }

        let amountText = String(normalized[amountRange])
        let amount = parseAmount(amountText)
        guard amount > 0 else { return nil }

        let unitRange = Range(match.range(at: 2), in: normalized)
        let unit = unitRange.map { String(normalized[$0]).trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
        return (amount: amount, unit: unit)
    }

    private static func parseAmount(_ text: String) -> Double {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains(" ") {
            let parts = trimmed.split(separator: " ", omittingEmptySubsequences: true)
            if parts.count == 2,
               let whole = Double(parts[0]),
               let fraction = parseFraction(String(parts[1])) {
                return whole + fraction
            }
        }

        if let fraction = parseFraction(trimmed) {
            return fraction
        }

        return Double(trimmed) ?? 0
    }

    private static func parseFraction(_ text: String) -> Double? {
        let parts = text.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count == 2,
              let numerator = Double(parts[0]),
              let denominator = Double(parts[1]),
              denominator != 0 else {
            return nil
        }
        return numerator / denominator
    }

    private static func formatAmount(_ amount: Double) -> String {
        let rounded = amount.rounded()
        if abs(amount - rounded) < 0.01 {
            return String(Int(rounded))
        }

        let whole = Int(floor(amount))
        let fraction = amount - Double(whole)
        let candidates = [2, 3, 4, 8, 16]
        var bestNumerator = 0
        var bestDenominator = 1
        var bestError = Double.greatestFiniteMagnitude

        for denominator in candidates {
            let numerator = Int((fraction * Double(denominator)).rounded())
            let candidate = Double(numerator) / Double(denominator)
            let error = abs(fraction - candidate)
            if error < bestError {
                bestError = error
                bestNumerator = numerator
                bestDenominator = denominator
            }
        }

        if bestNumerator > 0, bestError < 0.03 {
            if whole > 0 {
                return "\(whole) \(bestNumerator)/\(bestDenominator)"
            }
            return "\(bestNumerator)/\(bestDenominator)"
        }

        let formatter = NumberFormatter()
        formatter.maximumFractionDigits = 2
        formatter.minimumFractionDigits = 0
        formatter.minimumIntegerDigits = 1
        return formatter.string(from: NSNumber(value: amount)) ?? String(format: "%.2f", amount)
    }

    private static func normalizedPounds(from raw: String) -> String? {
        let pattern = #"^\s*(\d+(?:\.\d+)?)\s*(oz|ounce|ounces)\s*$"#
        guard
            let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
            let match = regex.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)),
            let amountRange = Range(match.range(at: 1), in: raw)
        else {
            return nil
        }

        guard let ounces = Double(raw[amountRange]), ounces >= 16 else { return nil }
        let pounds = ounces / 16
        let formatted =
            abs(pounds.rounded() - pounds) < 0.001
            ? String(Int(pounds.rounded()))
            : String(format: pounds.truncatingRemainder(dividingBy: 1) == 0.5 ? "%.1f" : "%.2f", pounds)
                .replacingOccurrences(of: ".00", with: "")

        return "\(formatted) lb"
    }
}

private struct RecipeDetailData: Identifiable, Decodable, Hashable {
    let id: String
    let title: String
    let description: String
    let authorName: String?
    let authorHandle: String?
    let authorURLString: String?
    let source: String?
    let sourcePlatform: String?
    let category: String?
    let subcategory: String?
    let recipeType: String?
    let skillLevel: String?
    let cookTimeText: String?
    let servingsText: String?
    let servingSizeText: String?
    let dailyDietText: String?
    let estCostText: String?
    let estCaloriesText: String?
    let carbsText: String?
    let proteinText: String?
    let fatsText: String?
    let caloriesKcal: Double?
    let proteinG: Double?
    let carbsG: Double?
    let fatG: Double?
    let prepTimeMinutes: Int?
    let cookTimeMinutes: Int?
    let heroImageURLString: String?
    let discoverCardImageURLString: String?
    let recipeURLString: String?
    let originalRecipeURLString: String?
    let attachedVideoURLString: String?
    let detailFootnote: String?
    let imageCaption: String?
    let dietaryTags: [String]
    let flavorTags: [String]
    let cuisineTags: [String]
    let occasionTags: [String]
    let mainProtein: String?
    let cookMethod: String?
    let ingredients: [RecipeDetailIngredient]
    let steps: [RecipeDetailStep]
    let servingsCount: Int?

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case description
        case authorName = "author_name"
        case authorHandle = "author_handle"
        case authorURLString = "author_url"
        case source
        case sourcePlatform = "source_platform"
        case category
        case subcategory
        case recipeType = "recipe_type"
        case skillLevel = "skill_level"
        case cookTimeText = "cook_time_text"
        case servingsText = "servings_text"
        case servingSizeText = "serving_size_text"
        case dailyDietText = "daily_diet_text"
        case estCostText = "est_cost_text"
        case estCaloriesText = "est_calories_text"
        case carbsText = "carbs_text"
        case proteinText = "protein_text"
        case fatsText = "fats_text"
        case caloriesKcal = "calories_kcal"
        case proteinG = "protein_g"
        case carbsG = "carbs_g"
        case fatG = "fat_g"
        case prepTimeMinutes = "prep_time_minutes"
        case cookTimeMinutes = "cook_time_minutes"
        case heroImageURLString = "hero_image_url"
        case discoverCardImageURLString = "discover_card_image_url"
        case recipeURLString = "recipe_url"
        case originalRecipeURLString = "original_recipe_url"
        case attachedVideoURLString = "attached_video_url"
        case detailFootnote = "detail_footnote"
        case imageCaption = "image_caption"
        case dietaryTags = "dietary_tags"
        case flavorTags = "flavor_tags"
        case cuisineTags = "cuisine_tags"
        case occasionTags = "occasion_tags"
        case mainProtein = "main_protein"
        case cookMethod = "cook_method"
        case ingredients
        case steps
        case servingsCount = "servings_count"
    }

    var imageCandidates: [URL] {
        [heroImageURLString, discoverCardImageURLString].compactMap(Self.normalizedImageURL(from:))
    }

    var imageURL: URL? {
        imageCandidates.first
    }

    var originalURL: URL? {
        let raw = [originalRecipeURLString, authorURLString, recipeURLString]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        guard let raw, !raw.isEmpty else { return nil }
        return URL(string: raw)
    }

    var attachedVideoURL: URL? {
        guard let attachedVideoURLString, !attachedVideoURLString.isEmpty else { return nil }
        return URL(string: attachedVideoURLString)
    }

    var sourceDisplayLine: String? {
        if let authorHandle, !authorHandle.isEmpty { return authorHandle }
        if let authorName, !authorName.isEmpty { return authorName }
        if let source, !source.isEmpty, source.lowercased() != "withjulienne" { return source.capitalized }
        return nil
    }

    var authorLine: String {
        if let sourceDisplayLine { return sourceDisplayLine }
        if let sourcePlatform, !sourcePlatform.isEmpty { return sourcePlatform }
        if let source, !source.isEmpty { return source.capitalized }
        return "Ounje source"
    }

    var displayServings: Int {
        if let servingsCount, servingsCount > 0 { return servingsCount }
        if let parsed = RecipeDetailData.extractLeadingInteger(from: servingsText), parsed > 0 { return parsed }
        return 4
    }

    var detailsGrid: [RecipeDetailMetric] {
        let values: [RecipeDetailMetric?] = [
            skillLevel.map { RecipeDetailMetric(title: "Skill", value: $0) },
            RecipeDetailMetric(title: "Cook Time", value: compactCookTime),
            RecipeDetailMetric(title: "Servings", value: "\(displayServings)"),
            caloriesDisplayText.map { RecipeDetailMetric(title: "Calories", value: $0) },
            (proteinText ?? proteinG.map { "\($0.roundedString(0))g" }).map { RecipeDetailMetric(title: "Protein", value: $0) },
            (carbsText ?? carbsG.map { "\($0.roundedString(0))g" }).map { RecipeDetailMetric(title: "Carbs", value: $0) },
            (fatsText ?? fatG.map { "\($0.roundedString(0))g" }).map { RecipeDetailMetric(title: "Fats", value: $0) },
            (recipeType ?? category ?? subcategory).map { RecipeDetailMetric(title: "Type", value: $0.capitalized) },
            (cuisineTags.first ?? category ?? subcategory).map { RecipeDetailMetric(title: "Cuisine", value: $0) },
            (cookMethod ?? mainProtein).map { RecipeDetailMetric(title: "Method", value: $0) },
            (dailyDietText ?? dietaryTags.first).map { RecipeDetailMetric(title: "Diet", value: $0) },
            occasionTags.first.map { RecipeDetailMetric(title: "Occasion", value: $0) },
            estCostText.map { RecipeDetailMetric(title: "Est. Cost", value: $0) },
            sourceDisplayLine.map { RecipeDetailMetric(title: "Source", value: $0) }
        ]

        return values
            .compactMap { $0 }
            .filter { !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.value != "—" }
            .prefix(9)
            .map { $0 }
    }

    var compactTagSummary: String {
        let values = (dietaryTags + cuisineTags).prefix(2)
        return values.isEmpty ? "—" : values.joined(separator: " • ")
    }

    var combinedCookTimeText: String? {
        if let prep = prepTimeMinutes, let cook = cookTimeMinutes, prep > 0 || cook > 0 {
            let total = prep + cook
            return total > 0 ? "\(total) mins" : nil
        }
        return nil
    }

    var compactCookTime: String {
        if let cookTimeMinutes, cookTimeMinutes > 0 {
            return "\(cookTimeMinutes) mins"
        }
        return cookTimeText ?? combinedCookTimeText ?? "—"
    }

    private var caloriesDisplayText: String? {
        if let caloriesKcal, caloriesKcal > 0 {
            return "\(Int(caloriesKcal.rounded())) kcal"
        }
        guard let estCaloriesText, let parsed = RecipeDetailData.extractFirstNumber(from: estCaloriesText) else {
            return nil
        }
        return "\(parsed) kcal"
    }

    private static func normalizedImageURL(from rawValue: String?) -> URL? {
        guard let rawValue, !rawValue.isEmpty else { return nil }
        let normalized = rawValue
            .replacingOccurrences(of: "https://firebasestorage.googleapis.com:443/", with: "https://firebasestorage.googleapis.com/")
            .replacingOccurrences(of: " ", with: "%20")
        return URL(string: normalized)
    }

    private static func extractLeadingInteger(from value: String?) -> Int? {
        guard let match = value?.range(of: #"\d{1,3}"#, options: .regularExpression) else { return nil }
        return Int(value?[match] ?? "")
    }

    private static func extractFirstNumber(from value: String?) -> Int? {
        guard let match = value?.range(of: #"\d{1,4}"#, options: .regularExpression) else { return nil }
        return Int(value?[match] ?? "")
    }

    func replacing(
        ingredients: [RecipeDetailIngredient],
        steps: [RecipeDetailStep]
    ) -> RecipeDetailData {
        RecipeDetailData(
            id: id,
            title: title,
            description: description,
            authorName: authorName,
            authorHandle: authorHandle,
            authorURLString: authorURLString,
            source: source,
            sourcePlatform: sourcePlatform,
            category: category,
            subcategory: subcategory,
            recipeType: recipeType,
            skillLevel: skillLevel,
            cookTimeText: cookTimeText,
            servingsText: servingsText,
            servingSizeText: servingSizeText,
            dailyDietText: dailyDietText,
            estCostText: estCostText,
            estCaloriesText: estCaloriesText,
            carbsText: carbsText,
            proteinText: proteinText,
            fatsText: fatsText,
            caloriesKcal: caloriesKcal,
            proteinG: proteinG,
            carbsG: carbsG,
            fatG: fatG,
            prepTimeMinutes: prepTimeMinutes,
            cookTimeMinutes: cookTimeMinutes,
            heroImageURLString: heroImageURLString,
            discoverCardImageURLString: discoverCardImageURLString,
            recipeURLString: recipeURLString,
            originalRecipeURLString: originalRecipeURLString,
            attachedVideoURLString: attachedVideoURLString,
            detailFootnote: detailFootnote,
            imageCaption: imageCaption,
            dietaryTags: dietaryTags,
            flavorTags: flavorTags,
            cuisineTags: cuisineTags,
            occasionTags: occasionTags,
            mainProtein: mainProtein,
            cookMethod: cookMethod,
            ingredients: ingredients,
            steps: steps,
            servingsCount: servingsCount
        )
    }
}

private struct RecipeDetailMetric: Hashable {
    let title: String
    let value: String
}

private struct RecipeDetailResponse: Decodable {
    let recipe: RecipeDetailData
}

private struct RecipeDetailRelatedResponse: Decodable {
    let recipes: [DiscoverRecipeCardData]
}

private struct RecipeResolvedVideoData: Decodable, Hashable {
    enum PlaybackMode: String {
        case native
        case iframe
        case embed
        case unavailable
    }

    let modeRawValue: String
    let provider: String?
    let sourceURLString: String
    let resolvedURLString: String?
    let posterURLString: String?
    let durationSeconds: Double?

    enum CodingKeys: String, CodingKey {
        case modeRawValue = "mode"
        case provider
        case sourceURLString = "source_url"
        case resolvedURLString = "resolved_url"
        case posterURLString = "poster_url"
        case durationSeconds = "duration_seconds"
    }

    var mode: PlaybackMode {
        PlaybackMode(rawValue: modeRawValue) ?? .unavailable
    }

    var url: URL? {
        guard let resolvedURLString, !resolvedURLString.isEmpty else { return nil }
        return URL(string: resolvedURLString)
    }

    var sourceURL: URL? {
        URL(string: sourceURLString)
    }

    var posterURL: URL? {
        guard let posterURLString, !posterURLString.isEmpty else { return nil }
        return URL(string: posterURLString)
    }

    var supportsNativePlayback: Bool {
        mode == .native
    }

    var usesHostedIframe: Bool {
        mode == .iframe
    }
}

private struct RecipeVideoResolveResponse: Decodable {
    let video: RecipeResolvedVideoData
}

private enum RecipeWebVideoActionKind: Equatable {
    case none
    case togglePlayback
    case seek(seconds: Double)
    case pause
}

private struct RecipeWebVideoAction: Equatable {
    let id = UUID()
    let kind: RecipeWebVideoActionKind

    static let none = RecipeWebVideoAction(kind: .none)
}

@MainActor
private final class RecipeDetailViewModel: ObservableObject {
    @Published private(set) var detail: RecipeDetailData?
    @Published private(set) var similarRecipes: [DiscoverRecipeCardData] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    func load(for recipeID: String) async {
        if detail?.id == recipeID { return }

        isLoading = true
        errorMessage = nil

        defer {
            isLoading = false
        }

        do {
            async let detailTask = RecipeDetailService.shared.fetchRecipeDetail(id: recipeID)
            async let similarTask = RecipeDetailService.shared.fetchSimilarRecipes(id: recipeID)
            detail = try await detailTask
            similarRecipes = (try? await similarTask) ?? []
        } catch {
            detail = nil
            similarRecipes = []
            errorMessage = error.localizedDescription
        }
    }
}

private actor RecipeDetailService {
    static let shared = RecipeDetailService()

    private var cache: [String: RecipeDetailData] = [:]
    private var similarCache: [String: [DiscoverRecipeCardData]] = [:]

    func fetchRecipeDetail(id: String) async throws -> RecipeDetailData {
        if let cached = cache[id] {
            return cached
        }

        let baseDetail: RecipeDetailData
        do {
            baseDetail = try await fetchRecipeDetailFromSupabase(id: id)
        } catch {
            baseDetail = try await fetchRecipeDetailFromBackend(id: id)
        }

        let detail = await enrichCanonicalImages(in: baseDetail)
        cache[id] = detail
        return detail
    }

    func fetchSimilarRecipes(id: String) async throws -> [DiscoverRecipeCardData] {
        if let cached = similarCache[id] {
            return cached
        }

        var lastError: Error?
        for baseURL in OunjeDevelopmentServer.candidateBaseURLs {
            do {
                return try await fetchSimilarRecipes(baseURL: baseURL, id: id)
            } catch {
                lastError = error
            }
        }

        throw lastError ?? SupabaseProfileStateError.invalidResponse
    }

    private func fetchSimilarRecipes(baseURL: String, id: String) async throws -> [DiscoverRecipeCardData] {
        guard let url = URL(string: "\(baseURL)/v1/recipe/detail/\(id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id)/similar?limit=5") else {
            throw SupabaseProfileStateError.invalidRequest
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SupabaseProfileStateError.invalidResponse
        }
        guard (200 ... 299).contains(httpResponse.statusCode) else {
            let errorPayload = try? JSONDecoder().decode(SupabaseRestErrorResponse.self, from: data)
            let fallback = "Failed to load similar recipes (\(httpResponse.statusCode))."
            throw SupabaseProfileStateError.requestFailed(errorPayload?.message ?? errorPayload?.error ?? fallback)
        }

        let decoded = try JSONDecoder().decode(RecipeDetailRelatedResponse.self, from: data)
        similarCache[id] = decoded.recipes
        return decoded.recipes
    }

    private func fetchRecipeDetailFromBackend(id: String) async throws -> RecipeDetailData {
        var lastError: Error?
        for baseURL in OunjeDevelopmentServer.candidateBaseURLs {
            do {
                return try await fetchRecipeDetailFromBackend(baseURL: baseURL, id: id)
            } catch {
                lastError = error
            }
        }

        throw lastError ?? SupabaseProfileStateError.invalidResponse
    }

    private func fetchRecipeDetailFromBackend(baseURL: String, id: String) async throws -> RecipeDetailData {
        guard let url = URL(string: "\(baseURL)/v1/recipe/detail/\(id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id)") else {
            throw SupabaseProfileStateError.invalidRequest
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SupabaseProfileStateError.invalidResponse
        }
        guard (200 ... 299).contains(httpResponse.statusCode) else {
            let errorPayload = try? JSONDecoder().decode(SupabaseRestErrorResponse.self, from: data)
            let fallback = "Failed to load recipe detail (\(httpResponse.statusCode))."
            throw SupabaseProfileStateError.requestFailed(errorPayload?.message ?? errorPayload?.error ?? fallback)
        }

        let decoded = try JSONDecoder().decode(RecipeDetailResponse.self, from: data)
        return decoded.recipe
    }

    private func fetchRecipeDetailFromSupabase(id: String) async throws -> RecipeDetailData {
        let encodedID = id.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? id
        let isUserImported = id.hasPrefix("uir_")
        let recipeTable = isUserImported ? "user_import_recipes" : "recipes"
        let ingredientTable = isUserImported ? "user_import_recipe_ingredients" : "recipe_ingredients"
        let stepTable = isUserImported ? "user_import_recipe_steps" : "recipe_steps"
        let stepIngredientTable = isUserImported ? "user_import_recipe_step_ingredients" : "recipe_step_ingredients"
        let recipeSelect = [
            "id",
            "title",
            "description",
            "author_name",
            "author_handle",
            "author_url",
            "source",
            "source_platform",
            "category",
            "subcategory",
            "recipe_type",
            "skill_level",
            "cook_time_text",
            "servings_text",
            "serving_size_text",
            "daily_diet_text",
            "est_cost_text",
            "est_calories_text",
            "carbs_text",
            "protein_text",
            "fats_text",
            "calories_kcal",
            "protein_g",
            "carbs_g",
            "fat_g",
            "prep_time_minutes",
            "cook_time_minutes",
            "hero_image_url",
            "discover_card_image_url",
            "recipe_url",
            "original_recipe_url",
            "attached_video_url",
            "detail_footnote",
            "image_caption",
            "dietary_tags",
            "flavor_tags",
            "cuisine_tags",
            "occasion_tags",
            "main_protein",
            "cook_method"
        ].joined(separator: ",")

        guard let recipeURL = URL(string: "\(SupabaseConfig.url)/rest/v1/\(recipeTable)?select=\(recipeSelect)&id=eq.\(encodedID)&limit=1") else {
            throw SupabaseProfileStateError.invalidRequest
        }

        let recipes: [SupabaseRecipeDetailRow] = try await performSupabaseGET(url: recipeURL, as: [SupabaseRecipeDetailRow].self)
        guard let recipe = recipes.first else {
            throw SupabaseProfileStateError.requestFailed("Recipe detail could not be found.")
        }

        guard let ingredientURL = URL(string: "\(SupabaseConfig.url)/rest/v1/\(ingredientTable)?select=id,ingredient_id,display_name,quantity_text,image_url,sort_order&recipe_id=eq.\(encodedID)&order=sort_order.asc") else {
            throw SupabaseProfileStateError.invalidRequest
        }
        let ingredients: [RecipeDetailIngredient] = try await performSupabaseGET(url: ingredientURL, as: [RecipeDetailIngredient].self)
            .map { $0.normalizedForDisplay() }

        guard let stepsURL = URL(string: "\(SupabaseConfig.url)/rest/v1/\(stepTable)?select=id,step_number,instruction_text,tip_text&recipe_id=eq.\(encodedID)&order=step_number.asc") else {
            throw SupabaseProfileStateError.invalidRequest
        }
        let stepRows: [SupabaseRecipeStepRow] = try await performSupabaseGET(url: stepsURL, as: [SupabaseRecipeStepRow].self)

        let stepIDs = stepRows.map(\.id)
        let stepIngredients: [SupabaseRecipeStepIngredientRow]
        if stepIDs.isEmpty {
            stepIngredients = []
        } else {
            let joined = stepIDs.joined(separator: ",")
            guard let stepIngredientsURL = URL(string: "\(SupabaseConfig.url)/rest/v1/\(stepIngredientTable)?select=id,recipe_step_id,ingredient_id,display_name,quantity_text,sort_order&recipe_step_id=in.(\(joined.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? joined))&order=recipe_step_id.asc,sort_order.asc") else {
                throw SupabaseProfileStateError.invalidRequest
            }
            stepIngredients = try await performSupabaseGET(url: stepIngredientsURL, as: [SupabaseRecipeStepIngredientRow].self)
        }

        let ingredientByID: [String: RecipeDetailIngredient] = Dictionary(
            uniqueKeysWithValues: ingredients.compactMap { ingredient in
                guard let ingredientID = ingredient.ingredientID, !ingredientID.isEmpty else { return nil }
                return (ingredientID, ingredient)
            }
        )
        let ingredientByName: [String: RecipeDetailIngredient] = Dictionary(
            uniqueKeysWithValues: ingredients.map {
                (SupabaseIngredientsCatalogService.normalizedName($0.displayTitle), $0)
            }
        )

        let stepIngredientMap = Dictionary(grouping: stepIngredients, by: \.recipeStepID)
        let steps = stepRows.map { stepRow in
            let mapped: [RecipeDetailIngredient] = (stepIngredientMap[stepRow.id] ?? []).map { (stepIngredient: SupabaseRecipeStepIngredientRow) -> RecipeDetailIngredient in
                if let ingredientID = stepIngredient.ingredientID,
                   let linked = ingredientByID[ingredientID] {
                    return RecipeDetailIngredient(
                        id: linked.id,
                        ingredientID: linked.ingredientID,
                        displayName: linked.displayTitle,
                        quantityText: stepIngredient.quantityText ?? linked.displayQuantityText,
                        imageURLString: linked.imageURLString,
                        sortOrder: stepIngredient.sortOrder ?? linked.sortOrder
                    )
                }

                if let linkedByName = ingredientByName[SupabaseIngredientsCatalogService.normalizedName(stepIngredient.displayName)] {
                    return RecipeDetailIngredient(
                        id: linkedByName.id,
                        ingredientID: linkedByName.ingredientID,
                        displayName: linkedByName.displayTitle,
                        quantityText: stepIngredient.quantityText ?? linkedByName.displayQuantityText,
                        imageURLString: linkedByName.imageURLString,
                        sortOrder: stepIngredient.sortOrder ?? linkedByName.sortOrder
                    )
                }

                return RecipeDetailIngredient(
                    id: stepIngredient.id,
                    ingredientID: stepIngredient.ingredientID,
                    displayName: stepIngredient.displayName,
                    quantityText: stepIngredient.quantityText,
                    imageURLString: nil,
                    sortOrder: stepIngredient.sortOrder
                )
            }

            return RecipeDetailStep(
                number: stepRow.stepNumber,
                text: stepRow.instructionText,
                tipText: stepRow.tipText,
                ingredientRefs: mapped.map(\.displayName),
                ingredients: mapped
            )
        }

        return RecipeDetailData(
            id: recipe.id,
            title: recipe.title,
            description: recipe.description ?? "",
            authorName: recipe.authorName,
            authorHandle: recipe.authorHandle,
            authorURLString: recipe.authorURLString,
            source: recipe.source,
            sourcePlatform: recipe.sourcePlatform,
            category: recipe.category,
            subcategory: recipe.subcategory,
            recipeType: recipe.recipeType,
            skillLevel: recipe.skillLevel,
            cookTimeText: recipe.cookTimeText,
            servingsText: recipe.servingsText,
            servingSizeText: recipe.servingSizeText,
            dailyDietText: recipe.dailyDietText,
            estCostText: recipe.estCostText,
            estCaloriesText: recipe.estCaloriesText,
            carbsText: recipe.carbsText,
            proteinText: recipe.proteinText,
            fatsText: recipe.fatsText,
            caloriesKcal: recipe.caloriesKcal,
            proteinG: recipe.proteinG,
            carbsG: recipe.carbsG,
            fatG: recipe.fatG,
            prepTimeMinutes: recipe.prepTimeMinutes,
            cookTimeMinutes: recipe.cookTimeMinutes,
            heroImageURLString: recipe.heroImageURLString,
            discoverCardImageURLString: recipe.discoverCardImageURLString,
            recipeURLString: recipe.recipeURLString,
            originalRecipeURLString: recipe.originalRecipeURLString,
            attachedVideoURLString: recipe.attachedVideoURLString,
            detailFootnote: recipe.detailFootnote,
            imageCaption: recipe.imageCaption,
            dietaryTags: recipe.dietaryTags ?? [],
            flavorTags: recipe.flavorTags ?? [],
            cuisineTags: recipe.cuisineTags ?? [],
            occasionTags: recipe.occasionTags ?? [],
            mainProtein: recipe.mainProtein,
            cookMethod: recipe.cookMethodValues.first,
            ingredients: ingredients,
            steps: steps,
            servingsCount: nil
        )
    }

    private func enrichCanonicalImages(in detail: RecipeDetailData) async -> RecipeDetailData {
        let rawIngredients = detail.ingredients
        let rawStepIngredients = detail.steps.flatMap(\.ingredients)
        let ingredientIDs = (rawIngredients + rawStepIngredients).compactMap(\.ingredientID)
        let names = (rawIngredients + rawStepIngredients).map(\.displayTitle)
        let quantityResolved = resolvedIngredientQuantities(
            ingredients: rawIngredients,
            steps: detail.steps
        )

        guard !ingredientIDs.isEmpty || !names.isEmpty else {
            return detail.replacing(
                ingredients: quantityResolved.ingredients,
                steps: quantityResolved.steps
            )
        }

        guard let canonicalRecords = try? await SupabaseIngredientsCatalogService.shared.fetchIngredients(
            ingredientIDs: ingredientIDs,
            normalizedNames: names
        ) else {
            return detail.replacing(
                ingredients: quantityResolved.ingredients,
                steps: quantityResolved.steps
            )
        }

        let canonicalIndex = CanonicalIngredientImageIndex(records: canonicalRecords)
        let ingredients = quantityResolved.ingredients.map(canonicalIndex.enrich(_:))
        let steps = quantityResolved.steps.map { step in
            step.replacingIngredients(step.ingredients.map(canonicalIndex.enrich(_:)))
        }

        return detail.replacing(ingredients: ingredients, steps: steps)
    }

    private func resolvedIngredientQuantities(
        ingredients: [RecipeDetailIngredient],
        steps: [RecipeDetailStep]
    ) -> (ingredients: [RecipeDetailIngredient], steps: [RecipeDetailStep]) {
        let candidates = ingredients + steps.flatMap(\.ingredients)
        var quantityByID: [String: String] = [:]
        var quantityByName: [String: String] = [:]

        for ingredient in candidates {
            guard let quantity = ingredient.displayQuantityText?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !quantity.isEmpty else {
                continue
            }

            if let ingredientID = ingredient.ingredientID?.trimmingCharacters(in: .whitespacesAndNewlines),
               !ingredientID.isEmpty,
               quantityByID[ingredientID.lowercased()] == nil {
                quantityByID[ingredientID.lowercased()] = quantity
            }

            let key = Self.normalizedIngredientKey(ingredient.displayTitle)
            if !key.isEmpty, quantityByName[key] == nil {
                quantityByName[key] = quantity
            }
        }

        let resolvedIngredients = ingredients.map { ingredient in
            resolveIngredientQuantity(for: ingredient, quantityByID: quantityByID, quantityByName: quantityByName)
        }

        let resolvedSteps = steps.map { step in
            step.replacingIngredients(
                step.ingredients.map { ingredient in
                    resolveIngredientQuantity(for: ingredient, quantityByID: quantityByID, quantityByName: quantityByName)
                }
            )
        }

        return (resolvedIngredients, resolvedSteps)
    }

    private func resolveIngredientQuantity(
        for ingredient: RecipeDetailIngredient,
        quantityByID: [String: String],
        quantityByName: [String: String]
    ) -> RecipeDetailIngredient {
        let existingQuantity = ingredient.displayQuantityText?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard existingQuantity?.isEmpty ?? true else {
            return ingredient
        }

        if let ingredientID = ingredient.ingredientID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !ingredientID.isEmpty,
           let quantity = quantityByID[ingredientID.lowercased()] {
            return ingredient.replacingQuantityText(quantity)
        }

        let key = Self.normalizedIngredientKey(ingredient.displayTitle)
        if let quantity = quantityByName[key] {
            return ingredient.replacingQuantityText(quantity)
        }

        return ingredient
    }

    private static func normalizedIngredientKey(_ value: String) -> String {
        value
            .lowercased()
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func performSupabaseGET<T: Decodable>(url: URL, as type: T.Type) async throws -> T {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue(SupabaseConfig.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(SupabaseConfig.anonKey)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SupabaseProfileStateError.invalidResponse
        }
        guard (200 ... 299).contains(httpResponse.statusCode) else {
            let errorPayload = try? JSONDecoder().decode(SupabaseRestErrorResponse.self, from: data)
            let fallback = "Failed to load recipe detail (\(httpResponse.statusCode))."
            throw SupabaseProfileStateError.requestFailed(errorPayload?.message ?? errorPayload?.error ?? fallback)
        }
        return try JSONDecoder().decode(type, from: data)
    }
}

private actor RecipeVideoResolveService {
    static let shared = RecipeVideoResolveService()

    private var cache: [String: RecipeResolvedVideoData] = [:]

    func resolveVideo(from sourceURL: URL) async throws -> RecipeResolvedVideoData {
        let cacheKey = sourceURL.absoluteString
        if let cached = cache[cacheKey] {
            return cached
        }

        let resolved = try await fetchResolvedVideoFromBackend(sourceURL: sourceURL)
        cache[cacheKey] = resolved
        return resolved
    }

    private func fetchResolvedVideoFromBackend(sourceURL: URL) async throws -> RecipeResolvedVideoData {
        var lastError: Error?
        for baseURL in OunjeDevelopmentServer.candidateBaseURLs {
            do {
                return try await fetchResolvedVideoFromBackend(baseURL: baseURL, sourceURL: sourceURL)
            } catch {
                lastError = error
            }
        }

        throw lastError ?? SupabaseProfileStateError.invalidResponse
    }

    private func fetchResolvedVideoFromBackend(baseURL: String, sourceURL: URL) async throws -> RecipeResolvedVideoData {
        guard
            var components = URLComponents(string: "\(baseURL)/v1/recipe/video/resolve")
        else {
            throw SupabaseProfileStateError.invalidRequest
        }

        components.queryItems = [URLQueryItem(name: "url", value: sourceURL.absoluteString)]
        guard let url = components.url else {
            throw SupabaseProfileStateError.invalidRequest
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 25

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SupabaseProfileStateError.invalidResponse
        }
        guard (200 ... 299).contains(httpResponse.statusCode) else {
            let errorPayload = try? JSONDecoder().decode(SupabaseRestErrorResponse.self, from: data)
            let fallback = "Failed to resolve video (\(httpResponse.statusCode))."
            throw SupabaseProfileStateError.requestFailed(errorPayload?.message ?? errorPayload?.error ?? fallback)
        }

        return try JSONDecoder().decode(RecipeVideoResolveResponse.self, from: data).video
    }
}

private struct SupabaseRecipeDetailRow: Decodable {
    let id: String
    let title: String
    let description: String?
    let authorName: String?
    let authorHandle: String?
    let authorURLString: String?
    let source: String?
    let sourcePlatform: String?
    let category: String?
    let subcategory: String?
    let recipeType: String?
    let skillLevel: String?
    let cookTimeText: String?
    let servingsText: String?
    let servingSizeText: String?
    let dailyDietText: String?
    let estCostText: String?
    let estCaloriesText: String?
    let carbsText: String?
    let proteinText: String?
    let fatsText: String?
    let caloriesKcal: Double?
    let proteinG: Double?
    let carbsG: Double?
    let fatG: Double?
    let prepTimeMinutes: Int?
    let cookTimeMinutes: Int?
    let heroImageURLString: String?
    let discoverCardImageURLString: String?
    let recipeURLString: String?
    let originalRecipeURLString: String?
    let attachedVideoURLString: String?
    let detailFootnote: String?
    let imageCaption: String?
    let dietaryTags: [String]?
    let flavorTags: [String]?
    let cuisineTags: [String]?
    let occasionTags: [String]?
    let mainProtein: String?
    let cookMethodValues: [String]

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case description
        case authorName = "author_name"
        case authorHandle = "author_handle"
        case authorURLString = "author_url"
        case source
        case sourcePlatform = "source_platform"
        case category
        case subcategory
        case recipeType = "recipe_type"
        case skillLevel = "skill_level"
        case cookTimeText = "cook_time_text"
        case servingsText = "servings_text"
        case servingSizeText = "serving_size_text"
        case dailyDietText = "daily_diet_text"
        case estCostText = "est_cost_text"
        case estCaloriesText = "est_calories_text"
        case carbsText = "carbs_text"
        case proteinText = "protein_text"
        case fatsText = "fats_text"
        case caloriesKcal = "calories_kcal"
        case proteinG = "protein_g"
        case carbsG = "carbs_g"
        case fatG = "fat_g"
        case prepTimeMinutes = "prep_time_minutes"
        case cookTimeMinutes = "cook_time_minutes"
        case heroImageURLString = "hero_image_url"
        case discoverCardImageURLString = "discover_card_image_url"
        case recipeURLString = "recipe_url"
        case originalRecipeURLString = "original_recipe_url"
        case attachedVideoURLString = "attached_video_url"
        case detailFootnote = "detail_footnote"
        case imageCaption = "image_caption"
        case dietaryTags = "dietary_tags"
        case flavorTags = "flavor_tags"
        case cuisineTags = "cuisine_tags"
        case occasionTags = "occasion_tags"
        case mainProtein = "main_protein"
        case cookMethodValues = "cook_method"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        authorName = try container.decodeIfPresent(String.self, forKey: .authorName)
        authorHandle = try container.decodeIfPresent(String.self, forKey: .authorHandle)
        authorURLString = try container.decodeIfPresent(String.self, forKey: .authorURLString)
        source = try container.decodeIfPresent(String.self, forKey: .source)
        sourcePlatform = try container.decodeIfPresent(String.self, forKey: .sourcePlatform)
        category = try container.decodeIfPresent(String.self, forKey: .category)
        subcategory = try container.decodeIfPresent(String.self, forKey: .subcategory)
        recipeType = try container.decodeIfPresent(String.self, forKey: .recipeType)
        skillLevel = try container.decodeIfPresent(String.self, forKey: .skillLevel)
        cookTimeText = try container.decodeIfPresent(String.self, forKey: .cookTimeText)
        servingsText = try container.decodeIfPresent(String.self, forKey: .servingsText)
        servingSizeText = try container.decodeIfPresent(String.self, forKey: .servingSizeText)
        dailyDietText = try container.decodeIfPresent(String.self, forKey: .dailyDietText)
        estCostText = try container.decodeIfPresent(String.self, forKey: .estCostText)
        estCaloriesText = try container.decodeIfPresent(String.self, forKey: .estCaloriesText)
        carbsText = try container.decodeIfPresent(String.self, forKey: .carbsText)
        proteinText = try container.decodeIfPresent(String.self, forKey: .proteinText)
        fatsText = try container.decodeIfPresent(String.self, forKey: .fatsText)
        caloriesKcal = try container.decodeIfPresent(Double.self, forKey: .caloriesKcal)
        proteinG = try container.decodeIfPresent(Double.self, forKey: .proteinG)
        carbsG = try container.decodeIfPresent(Double.self, forKey: .carbsG)
        fatG = try container.decodeIfPresent(Double.self, forKey: .fatG)
        prepTimeMinutes = try container.decodeIfPresent(Int.self, forKey: .prepTimeMinutes)
        cookTimeMinutes = try container.decodeIfPresent(Int.self, forKey: .cookTimeMinutes)
        heroImageURLString = try container.decodeIfPresent(String.self, forKey: .heroImageURLString)
        discoverCardImageURLString = try container.decodeIfPresent(String.self, forKey: .discoverCardImageURLString)
        recipeURLString = try container.decodeIfPresent(String.self, forKey: .recipeURLString)
        originalRecipeURLString = try container.decodeIfPresent(String.self, forKey: .originalRecipeURLString)
        attachedVideoURLString = try container.decodeIfPresent(String.self, forKey: .attachedVideoURLString)
        detailFootnote = try container.decodeIfPresent(String.self, forKey: .detailFootnote)
        imageCaption = try container.decodeIfPresent(String.self, forKey: .imageCaption)
        dietaryTags = try container.decodeIfPresent([String].self, forKey: .dietaryTags)
        flavorTags = try container.decodeIfPresent([String].self, forKey: .flavorTags)
        cuisineTags = try container.decodeIfPresent([String].self, forKey: .cuisineTags)
        occasionTags = try container.decodeIfPresent([String].self, forKey: .occasionTags)
        mainProtein = try container.decodeIfPresent(String.self, forKey: .mainProtein)
        cookMethodValues = (try? container.decode([String].self, forKey: .cookMethodValues))
            ?? (try? container.decode(String.self, forKey: .cookMethodValues)).map { [$0] }
            ?? []
    }
}

private struct SupabaseRecipeStepRow: Decodable {
    let id: String
    let stepNumber: Int
    let instructionText: String
    let tipText: String?

    enum CodingKeys: String, CodingKey {
        case id
        case stepNumber = "step_number"
        case instructionText = "instruction_text"
        case tipText = "tip_text"
    }
}

private struct SupabaseRecipeStepIngredientRow: Decodable {
    let id: String
    let recipeStepID: String
    let ingredientID: String?
    let displayName: String
    let quantityText: String?
    let sortOrder: Int?

    enum CodingKeys: String, CodingKey {
        case id
        case recipeStepID = "recipe_step_id"
        case ingredientID = "ingredient_id"
        case displayName = "display_name"
        case quantityText = "quantity_text"
        case sortOrder = "sort_order"
    }
}

private struct DiscoverRecipeCardData: Identifiable, Codable, Hashable {
    let id: String
    let title: String
    let description: String?
    let authorName: String?
    let authorHandle: String?
    let category: String?
    let recipeType: String?
    let cookTimeText: String?
    let cookTimeMinutes: Int?
    let publishedDate: String?
    let imageURLString: String?
    let heroImageURLString: String?
    let recipeURLString: String?
    let source: String?

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case description
        case authorName = "author_name"
        case authorHandle = "author_handle"
        case category
        case recipeType = "recipe_type"
        case cookTimeText = "cook_time_text"
        case cookTimeMinutes = "cook_time_minutes"
        case publishedDate = "published_date"
        case imageURLString = "discover_card_image_url"
        case heroImageURLString = "hero_image_url"
        case recipeURLString = "recipe_url"
        case source
    }

    var imageURL: URL? {
        imageCandidates.first
    }

    var imageCandidates: [URL] {
        [imageURLString, heroImageURLString]
            .compactMap(Self.normalizedImageURL(from:))
    }

    private static func normalizedImageURL(from rawValue: String?) -> URL? {
        guard let rawValue, !rawValue.isEmpty else { return nil }
        let normalized = rawValue
            .replacingOccurrences(of: "https://firebasestorage.googleapis.com:443/", with: "https://firebasestorage.googleapis.com/")
            .replacingOccurrences(of: " ", with: "%20")
        return URL(string: normalized)
    }

    var destinationURL: URL? {
        guard let recipeURLString, !recipeURLString.isEmpty else { return nil }
        return URL(string: recipeURLString)
    }

    var authorLabel: String {
        if let authorHandle, !authorHandle.isEmpty { return authorHandle }
        if let authorName, !authorName.isEmpty { return authorName }
        return "Source pending"
    }

    var filterLabel: String {
        if let normalizedRecipeType = Self.normalizedFilterLabel(from: recipeType) {
            return normalizedRecipeType
        }
        if let category, !category.isEmpty {
            if let normalizedCategory = Self.normalizedFilterLabel(
                from: category.replacingOccurrences(of: " Recipes", with: "")
            ) {
                return normalizedCategory
            }
        }
        return "Recipes"
    }

    var filterChipLabel: String? {
        let value = filterLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { return nil }
        if value.caseInsensitiveCompare("Recipes") == .orderedSame { return nil }
        if value.caseInsensitiveCompare("Other") == .orderedSame { return nil }
        return value
    }

    var compactFilterLabel: String? {
        let value = filterLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func normalizedFilterLabel(from rawValue: String?) -> String? {
        guard let rawValue else { return nil }
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let lowered = trimmed.lowercased()
        switch lowered {
        case "breakfast":
            return "Breakfast"
        case "lunch":
            return "Lunch"
        case "dinner":
            return "Dinner"
        case "dessert":
            return "Dessert"
        case "vegetarian":
            return "Vegetarian"
        case "vegan":
            return "Vegan"
        case "other", "recipes":
            return "Other"
        default:
            return lowered
                .split(separator: " ")
                .map { word in
                    word.prefix(1).uppercased() + word.dropFirst()
                }
                .joined(separator: " ")
        }
    }

    var compactCookTime: String? {
        if let cookTimeMinutes, cookTimeMinutes > 0 {
            return cookTimeMinutes == 1 ? "1 min" : "\(cookTimeMinutes) mins"
        }
        guard let cookTimeText, !cookTimeText.isEmpty else { return nil }
        return cookTimeText
    }

    var displayTitle: String {
        let withDigitSpacing = title.replacingOccurrences(
            of: #"(?<=\d)(?=[A-Za-z])"#,
            with: " ",
            options: .regularExpression
        )
        return withDigitSpacing.replacingOccurrences(
            of: #"(?<=[a-z])(?=[A-Z])"#,
            with: " ",
            options: .regularExpression
        )
    }

    var footerLine: String {
        let parts: [String] = [
            source?.capitalized,
            publishedDate?.replacingOccurrences(of: "_", with: "/")
        ].compactMap { value in
            guard let value, !value.isEmpty else { return nil }
            return value
        }

        if !parts.isEmpty {
            return parts.joined(separator: " • ")
        }

        if let description, !description.isEmpty {
            return description
        }

        return "Freshly scraped into your live recipe feed."
    }

    var emoji: String {
        switch filterLabel.lowercased() {
        case "breakfast":
            return "🍳"
        case "lunch":
            return "🥗"
        case "dinner":
            return "🍽️"
        case "dessert":
            return "🍰"
        default:
            return "🍴"
        }
    }

    var accentColor: Color {
        switch filterLabel.lowercased() {
        case "breakfast":
            return Color(hex: "F4B15E")
        case "lunch":
            return Color(hex: "56D7C8")
        case "dinner":
            return Color(hex: "52C67A")
        case "dessert":
            return Color(hex: "FF8AAE")
        default:
            return OunjePalette.accent
        }
    }

    init(
        id: String,
        title: String,
        description: String?,
        authorName: String?,
        authorHandle: String?,
        category: String?,
        recipeType: String?,
        cookTimeText: String?,
        cookTimeMinutes: Int? = nil,
        publishedDate: String?,
        imageURLString: String?,
        heroImageURLString: String?,
        recipeURLString: String?,
        source: String?
    ) {
        self.id = id
        self.title = title
        self.description = description
        self.authorName = authorName
        self.authorHandle = authorHandle
        self.category = category
        self.recipeType = recipeType
        self.cookTimeText = cookTimeText
        self.cookTimeMinutes = cookTimeMinutes
        self.publishedDate = publishedDate
        self.imageURLString = imageURLString
        self.heroImageURLString = heroImageURLString
        self.recipeURLString = recipeURLString
        self.source = source
    }

    init(preppedRecipe: PlannedRecipe) {
        let tags = preppedRecipe.recipe.tags.map { $0.lowercased() }
        let mealType = tags.first { ["breakfast", "lunch", "dinner", "dessert"].contains($0) }

        self.init(
            id: preppedRecipe.recipe.id,
            title: preppedRecipe.recipe.title,
            description: preppedRecipe.carriedFromPreviousPlan ? "Carried over from your last cycle." : "Scheduled for this prep cycle.",
            authorName: nil,
            authorHandle: nil,
            category: mealType,
            recipeType: mealType,
            cookTimeText: "\(preppedRecipe.recipe.prepMinutes) mins",
            cookTimeMinutes: preppedRecipe.recipe.prepMinutes,
            publishedDate: nil,
            imageURLString: preppedRecipe.recipe.cardImageURLString,
            heroImageURLString: preppedRecipe.recipe.heroImageURLString,
            recipeURLString: nil,
            source: preppedRecipe.recipe.source ?? preppedRecipe.recipe.cuisine.title
        )
    }

    func matchesDiscoverFilter(_ filter: String) -> Bool {
        let normalizedFilter = DiscoverPreset.normalizedKey(for: filter)
        guard normalizedFilter != "all" else { return true }

        switch normalizedFilter {
        case "under500":
            if let cookTimeMinutes, cookTimeMinutes > 0 {
                return cookTimeMinutes <= 500
            }
            return false
        case "beginner":
            let haystack = [category, recipeType, description, title]
                .compactMap { $0?.lowercased() }
                .joined(separator: " ")
            return haystack.contains("beginner") || haystack.contains("easy")
        default:
            let filterTokens = Set(discoverFilterTokens)
            return filterTokens.contains(normalizedFilter)
        }
    }

    func matchesDiscoverSearchTerms(_ terms: [String]) -> Bool {
        guard !terms.isEmpty else { return true }

        let haystack = [
            title,
            description,
            authorName,
            authorHandle,
            category,
            recipeType,
            source
        ]
        .compactMap { $0?.lowercased() }
        .joined(separator: " ")

        return terms.allSatisfy { haystack.contains($0) }
    }

    private var discoverFilterTokens: [String] {
        let rawValues = [category, recipeType, filterLabel]
            .compactMap { $0 }

        return rawValues.compactMap { value in
            let normalized = DiscoverPreset.normalizedKey(for: value)
            return normalized.isEmpty ? nil : normalized
        }
    }
}

private struct DiscoverRankedRecipesResponse: Decodable {
    let recipes: [DiscoverRecipeCardData]
    let filters: [String]
    let rankingMode: String?
}

private struct DiscoverRankedRecipesRequest: Encodable {
    let profile: UserProfile?
    let filter: String
    let query: String?
    let limit: Int
    let feedContext: DiscoverFeedContext
}

private struct DiscoverFeedContext: Encodable {
    let sessionSeed: String
    let windowKey: String
    let weekday: String
    let daypart: String
    let isWeekend: Bool
    let locationLabel: String?
    let regionCode: String?
    let weatherSummary: String?
    let weatherMood: String?
    let temperatureBand: String?
    let seasonCue: String?
    let sweetTreatBias: Double

    static var current: DiscoverFeedContext {
        let calendar = Calendar.current
        let now = Date()
        let hour = calendar.component(.hour, from: now)
        let minute = calendar.component(.minute, from: now)
        let halfHourBucket = (minute / 30) * 30
        let weekdayIndex = calendar.component(.weekday, from: now)
        let weekdaySymbols = calendar.weekdaySymbols
        let weekday = weekdaySymbols[max(0, min(weekdaySymbols.count - 1, weekdayIndex - 1))].lowercased()

        let daypart: String
        switch hour {
        case 5..<11:
            daypart = "morning"
        case 11..<15:
            daypart = "midday"
        case 15..<18:
            daypart = "afternoon"
        case 18..<22:
            daypart = "evening"
        default:
            daypart = "late-night"
        }

        return DiscoverFeedContext(
            sessionSeed: "",
            windowKey: "\(calendar.component(.year, from: now))-\(calendar.ordinality(of: .day, in: .year, for: now) ?? 0)-\(hour)-\(halfHourBucket)",
            weekday: weekday,
            daypart: daypart,
            isWeekend: calendar.isDateInWeekend(now),
            locationLabel: nil,
            regionCode: Locale.current.region?.identifier,
            weatherSummary: nil,
            weatherMood: nil,
            temperatureBand: nil,
            seasonCue: Self.seasonCue(for: now),
            sweetTreatBias: Self.baseSweetTreatBias(daypart: daypart, isWeekend: calendar.isDateInWeekend(now))
        )
    }

    func withSessionSeed(_ seed: String) -> DiscoverFeedContext {
        DiscoverFeedContext(
            sessionSeed: seed,
            windowKey: windowKey,
            weekday: weekday,
            daypart: daypart,
            isWeekend: isWeekend,
            locationLabel: locationLabel,
            regionCode: regionCode,
            weatherSummary: weatherSummary,
            weatherMood: weatherMood,
            temperatureBand: temperatureBand,
            seasonCue: seasonCue,
            sweetTreatBias: sweetTreatBias
        )
    }

    func withLocation(locationLabel: String?, regionCode: String?) -> DiscoverFeedContext {
        DiscoverFeedContext(
            sessionSeed: sessionSeed,
            windowKey: windowKey,
            weekday: weekday,
            daypart: daypart,
            isWeekend: isWeekend,
            locationLabel: locationLabel,
            regionCode: regionCode,
            weatherSummary: weatherSummary,
            weatherMood: weatherMood,
            temperatureBand: temperatureBand,
            seasonCue: seasonCue,
            sweetTreatBias: sweetTreatBias
        )
    }

    func withWeather(summary: String?, mood: String?, temperatureBand: String?, sweetTreatBias: Double) -> DiscoverFeedContext {
        DiscoverFeedContext(
            sessionSeed: sessionSeed,
            windowKey: windowKey,
            weekday: weekday,
            daypart: daypart,
            isWeekend: isWeekend,
            locationLabel: locationLabel,
            regionCode: regionCode,
            weatherSummary: summary,
            weatherMood: mood,
            temperatureBand: temperatureBand,
            seasonCue: seasonCue,
            sweetTreatBias: sweetTreatBias
        )
    }

    var cacheKey: String {
        [
            windowKey,
            weekday,
            daypart,
            isWeekend ? "weekend" : "weekday",
            locationLabel ?? "",
            regionCode ?? "",
            weatherSummary ?? "",
            weatherMood ?? "",
            temperatureBand ?? "",
            seasonCue ?? "",
            String(format: "%.2f", sweetTreatBias)
        ].joined(separator: "|")
    }

    private static func seasonCue(for date: Date) -> String {
        switch Calendar.current.component(.month, from: date) {
        case 12, 1, 2:
            return "winter"
        case 3, 4, 5:
            return "spring"
        case 6, 7, 8:
            return "summer"
        default:
            return "autumn"
        }
    }

    private static func baseSweetTreatBias(daypart: String, isWeekend: Bool) -> Double {
        var bias = 0.18
        if daypart == "evening" { bias += 0.12 }
        if daypart == "late-night" { bias += 0.18 }
        if isWeekend { bias += 0.1 }
        return min(max(bias, 0), 1)
    }
}

private struct DiscoverWeatherSnapshot {
    let summary: String
    let mood: String
    let temperatureBand: String
    let sweetTreatBias: Double
}

@MainActor
private final class DiscoverEnvironmentViewModel: ObservableObject {
    @Published private(set) var feedContext = DiscoverFeedContext.current
    private var lastKey: String?

    func refresh(profile: UserProfile?) async {
        let address = profile?.deliveryAddress
        let city = address?.city.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let region = address?.region.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let locationLabel = [city, region].filter { !$0.isEmpty }.joined(separator: ", ")
        let key = "\(DiscoverFeedContext.current.windowKey)|\(locationLabel)"
        if lastKey == key { return }

        var context = DiscoverFeedContext.current.withLocation(
            locationLabel: locationLabel.isEmpty ? nil : locationLabel,
            regionCode: region.isEmpty ? Locale.current.region?.identifier : region
        )

        if !city.isEmpty, let snapshot = try? await DiscoverWeatherService.shared.fetchWeather(city: city, region: region) {
            context = context.withWeather(
                summary: snapshot.summary,
                mood: snapshot.mood,
                temperatureBand: snapshot.temperatureBand,
                sweetTreatBias: snapshot.sweetTreatBias
            )
        }

        feedContext = context
        lastKey = key
    }
}

private final class SupabaseDiscoverRecipeService {
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
            "source"
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
        limit: Int = 30
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
                    limit: limit
                )
            } catch {
                lastError = error
            }
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
        limit: Int
    ) async throws -> DiscoverRankedRecipesResponse {
        guard let url = URL(string: "\(baseURL)/v1/recipe/discover") else {
            throw SupabaseProfileStateError.invalidRequest
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 25
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            DiscoverRankedRecipesRequest(
                profile: profile,
                filter: filter,
                query: query.isEmpty ? nil : query,
                limit: limit,
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

private actor DiscoverWeatherService {
    static let shared = DiscoverWeatherService()
    private var cache: [String: (timestamp: Date, snapshot: DiscoverWeatherSnapshot)] = [:]

    func fetchWeather(city: String, region: String) async throws -> DiscoverWeatherSnapshot {
        let key = "\(city.lowercased())|\(region.lowercased())"
        if let cached = cache[key], Date().timeIntervalSince(cached.timestamp) < 3600 {
            return cached.snapshot
        }

        let query = [city, region].filter { !$0.isEmpty }.joined(separator: ", ")
        guard let geocodeURL = URL(string: "https://geocoding-api.open-meteo.com/v1/search?name=\(query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query)&count=1&language=en&format=json") else {
            throw URLError(.badURL)
        }

        let (geoData, _) = try await URLSession.shared.data(from: geocodeURL)
        let geocode = try JSONDecoder().decode(DiscoverWeatherGeocodeResponse.self, from: geoData)
        guard let result = geocode.results?.first else {
            throw URLError(.resourceUnavailable)
        }

        guard let weatherURL = URL(string: "https://api.open-meteo.com/v1/forecast?latitude=\(result.latitude)&longitude=\(result.longitude)&current=temperature_2m,weather_code,cloud_cover,precipitation&temperature_unit=celsius") else {
            throw URLError(.badURL)
        }

        let (weatherData, _) = try await URLSession.shared.data(from: weatherURL)
        let weather = try JSONDecoder().decode(DiscoverWeatherForecastResponse.self, from: weatherData)

        let temperatureBand: String
        switch weather.current.temperature2m {
        case ..<4:
            temperatureBand = "cold"
        case 4..<14:
            temperatureBand = "cool"
        case 14..<24:
            temperatureBand = "mild"
        default:
            temperatureBand = "hot"
        }

        let mood: String
        switch weather.current.weatherCode {
        case 51...67, 80...99:
            mood = "rainy"
        case 71...77, 85...86:
            mood = "snowy"
        case 0, 1:
            mood = "sunny"
        case 2, 3, 45, 48:
            mood = "cloudy"
        default:
            mood = "mild"
        }

        var sweetTreatBias = DiscoverFeedContext.current.sweetTreatBias
        if mood == "sunny" && temperatureBand == "hot" { sweetTreatBias += 0.14 }
        if mood == "rainy" || mood == "snowy" { sweetTreatBias += 0.06 }
        if temperatureBand == "cold" { sweetTreatBias -= 0.04 }
        sweetTreatBias = min(max(sweetTreatBias, 0.05), 0.8)

        let snapshot = DiscoverWeatherSnapshot(
            summary: "\(temperatureBand)-\(mood)",
            mood: mood,
            temperatureBand: temperatureBand,
            sweetTreatBias: sweetTreatBias
        )
        cache[key] = (Date(), snapshot)
        return snapshot
    }
}

private struct DiscoverWeatherGeocodeResponse: Decodable {
    let results: [DiscoverWeatherGeocodeResult]?
}

private struct DiscoverWeatherGeocodeResult: Decodable {
    let latitude: Double
    let longitude: Double
}

private struct DiscoverWeatherForecastResponse: Decodable {
    let current: DiscoverWeatherCurrent
}

private struct DiscoverWeatherCurrent: Decodable {
    let temperature2m: Double
    let weatherCode: Int

    enum CodingKeys: String, CodingKey {
        case temperature2m = "temperature_2m"
        case weatherCode = "weather_code"
    }
}

private struct SupabaseTokenResponse: Codable {
    let accessToken: String
    let user: SupabaseAuthUser

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case user
    }
}

private struct SupabaseAuthUser: Codable {
    let id: String
    let email: String?
    let userMetadata: SupabaseUserMetadata?

    enum CodingKeys: String, CodingKey {
        case id
        case email
        case userMetadata = "user_metadata"
    }
}

private struct SupabaseUserMetadata: Codable {
    let fullName: String?
    let name: String?

    enum CodingKeys: String, CodingKey {
        case fullName = "full_name"
        case name
    }
}

private struct SupabaseAuthErrorResponse: Codable {
    let error: String?
    let msg: String?
    let errorDescription: String?

    enum CodingKeys: String, CodingKey {
        case error
        case msg
        case errorDescription = "error_description"
    }
}

private struct SupabaseRestErrorResponse: Codable {
    let message: String?
    let error: String?
}

private struct SupabaseSavedRecipeRow: Codable {
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
}

private struct SupabaseSavedRecipeIDRow: Codable {
    let recipeID: String

    enum CodingKeys: String, CodingKey {
        case recipeID = "recipe_id"
    }
}

private struct SupabaseSavedRecipeUpsertPayload: Codable {
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

private struct RecipeImportJobPayload: Decodable {
    let id: String
    let targetState: String
    let sourceType: String
    let sourceURL: String?
    let recipeID: String?
    let status: String
    let reviewState: String
    let confidenceScore: Double?
    let qualityFlags: [String]
    let reviewReason: String?
    let errorMessage: String?

    enum CodingKeys: String, CodingKey {
        case id
        case targetState = "target_state"
        case sourceType = "source_type"
        case sourceURL = "source_url"
        case recipeID = "recipe_id"
        case status
        case reviewState = "review_state"
        case confidenceScore = "confidence_score"
        case qualityFlags = "quality_flags"
        case reviewReason = "review_reason"
        case errorMessage = "error_message"
    }
}

private struct RecipeImportSourceProvenanceSummary: Decodable {
    let sourceType: String?
    let platform: String?
    let sourceURL: String?
    let canonicalURL: String?
    let attachedVideoURL: String?
    let transcriptPresent: Bool?
    let frameCount: Int?
    let frameOCRCount: Int?
    let reviewState: String?
    let confidenceScore: Double?

    enum CodingKeys: String, CodingKey {
        case sourceType = "source_type"
        case platform
        case sourceURL = "source_url"
        case canonicalURL = "canonical_url"
        case attachedVideoURL = "attached_video_url"
        case transcriptPresent = "transcript_present"
        case frameCount = "frame_count"
        case frameOCRCount = "frame_ocr_count"
        case reviewState = "review_state"
        case confidenceScore = "confidence_score"
    }
}

private struct RecipeImportReviewItem: Identifiable, Decodable {
    let id: String
    let title: String
    let description: String?
    let source: String?
    let sourcePlatform: String?
    let recipeType: String?
    let reviewState: String
    let confidenceScore: Double?
    let qualityFlags: [String]
    let sourceProvenance: RecipeImportSourceProvenanceSummary?
    let reviewReason: String?
    let createdAt: String?
    let updatedAt: String?
    let sourceURL: String?
    let attachedVideoURL: String?

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case description
        case source
        case sourcePlatform = "source_platform"
        case recipeType = "recipe_type"
        case reviewState = "review_state"
        case confidenceScore = "confidence_score"
        case qualityFlags = "quality_flags"
        case sourceProvenance = "source_provenance_json"
        case reviewReason = "review_reason"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case sourceURL = "recipe_url"
        case attachedVideoURL = "attached_video_url"
    }
}

private struct RecipeImportCompletedItem: Identifiable, Decodable {
    let id: String
    let recipeID: String?
    let title: String
    let status: String
    let reviewState: String
    let sourceURL: String?
    let canonicalURL: String?
    let imageURL: String?
    let source: String?
    let cookTimeText: String?
    let completedAt: String?
    let createdAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case recipeID = "recipe_id"
        case title
        case status
        case reviewState = "review_state"
        case sourceURL = "source_url"
        case canonicalURL = "canonical_url"
        case imageURL = "image_url"
        case source
        case cookTimeText = "cook_time_text"
        case completedAt = "completed_at"
        case createdAt = "created_at"
    }
}

private extension SharedRecipeImportEnvelope {
    var reconciliationKeys: Set<String> {
        var keys: Set<String> = []
        if let normalizedURL = Self.normalizedImportKey(from: sourceURLString) {
            keys.insert(normalizedURL)
        }
        if let normalizedText = Self.normalizedImportKey(from: resolvedSourceText) {
            keys.insert(normalizedText)
        }
        return keys
    }

    static func normalizedImportKey(from raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        if let url = URL(string: raw), let host = url.host?.lowercased(), !host.isEmpty {
            let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
            return ([host, path].filter { !$0.isEmpty }).joined(separator: "/")
        }

        return raw
            .lowercased()
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}

private extension RecipeImportCompletedItem {
    var reconciliationKeys: Set<String> {
        [
            SharedRecipeImportEnvelope.normalizedImportKey(from: sourceURL),
            SharedRecipeImportEnvelope.normalizedImportKey(from: canonicalURL)
        ]
        .compactMap { $0 }
        .reduce(into: Set<String>()) { partialResult, key in
            partialResult.insert(key)
        }
    }

    func matches(envelope: SharedRecipeImportEnvelope) -> Bool {
        !reconciliationKeys.isDisjoint(with: envelope.reconciliationKeys)
    }
}

private struct RecipeImportResponse: Decodable {
    let job: RecipeImportJobPayload
    let recipe: DiscoverRecipeCardData?
    let recipeDetail: RecipeDetailData?

    enum CodingKeys: String, CodingKey {
        case job
        case recipe
        case recipeDetail = "recipe_detail"
    }
}

private enum RecipeImportServiceError: Error {
    case invalidRequest
    case invalidResponse
    case requestFailed(String)
}

private struct RecipeImportAttachmentPayload: Encodable {
    let kind: String
    let sourceURL: String?
    let dataURL: String?
    let mimeType: String?
    let fileName: String?
    let previewFrameURLs: [String]

    enum CodingKeys: String, CodingKey {
        case kind
        case sourceURL = "source_url"
        case dataURL = "data_url"
        case mimeType = "mime_type"
        case fileName = "file_name"
        case previewFrameURLs = "preview_frame_urls"
    }
}

private struct RecipeImportRequestPayload: Encodable {
    let userID: String?
    let sourceURL: String?
    let sourceText: String
    let accessToken: String?
    let targetState: String
    let attachments: [RecipeImportAttachmentPayload]
    let processInline: Bool = false

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case sourceURL = "source_url"
        case sourceText = "source_text"
        case accessToken = "access_token"
        case targetState = "target_state"
        case attachments
        case processInline = "process_inline"
    }
}

private final class RecipeImportAPIService {
    static let shared = RecipeImportAPIService()

    private init() {}

    func importRecipe(
        userID: String?,
        accessToken: String? = nil,
        sourceURL: String? = nil,
        sourceText: String,
        targetState: String,
        attachments: [RecipeImportAttachmentPayload] = []
    ) async throws -> RecipeImportResponse {
        var lastError: Error?
        for baseURL in OunjeDevelopmentServer.candidateBaseURLs {
            do {
                return try await importRecipe(
                    baseURL: baseURL,
                    userID: userID,
                    accessToken: accessToken,
                    sourceURL: sourceURL,
                    sourceText: sourceText,
                    targetState: targetState,
                    attachments: attachments
                )
            } catch {
                lastError = error
            }
        }

        throw lastError ?? RecipeImportServiceError.invalidRequest
    }

    func fetchReviewQueue(userID: String) async throws -> [RecipeImportReviewItem] {
        var lastError: Error?
        for baseURL in OunjeDevelopmentServer.candidateBaseURLs {
            do {
                return try await fetchReviewQueue(baseURL: baseURL, userID: userID)
            } catch {
                lastError = error
            }
        }

        throw lastError ?? RecipeImportServiceError.invalidRequest
    }

    func fetchCompletedImports(userID: String) async throws -> [RecipeImportCompletedItem] {
        var lastError: Error?
        for baseURL in OunjeDevelopmentServer.candidateBaseURLs {
            do {
                return try await fetchCompletedImports(baseURL: baseURL, userID: userID)
            } catch {
                lastError = error
            }
        }

        throw lastError ?? RecipeImportServiceError.invalidRequest
    }

    private func importRecipe(
        baseURL: String,
        userID: String?,
        accessToken: String?,
        sourceURL: String?,
        sourceText: String,
        targetState: String,
        attachments: [RecipeImportAttachmentPayload]
    ) async throws -> RecipeImportResponse {
        guard let url = URL(string: "\(baseURL)/v1/recipe/imports") else {
            throw RecipeImportServiceError.invalidRequest
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 90
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            RecipeImportRequestPayload(
                userID: userID,
                sourceURL: sourceURL,
                sourceText: sourceText,
                accessToken: accessToken,
                targetState: targetState,
                attachments: attachments
            )
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw RecipeImportServiceError.invalidResponse
        }

        guard (200 ... 299).contains(httpResponse.statusCode) else {
            let errorPayload = try? JSONDecoder().decode(SupabaseRestErrorResponse.self, from: data)
            let fallback = "Recipe import failed (\(httpResponse.statusCode))."
            throw RecipeImportServiceError.requestFailed(errorPayload?.message ?? errorPayload?.error ?? fallback)
        }

        return try JSONDecoder().decode(RecipeImportResponse.self, from: data)
    }

    private func fetchReviewQueue(
        baseURL: String,
        userID: String
    ) async throws -> [RecipeImportReviewItem] {
        var components = URLComponents(string: "\(baseURL)/v1/recipe/imports/review") ?? URLComponents()
        components.queryItems = [
            URLQueryItem(name: "user_id", value: userID),
            URLQueryItem(name: "limit", value: "24"),
        ]
        guard let url = components.url else {
            throw RecipeImportServiceError.invalidRequest
        }

        let (data, response) = try await URLSession.shared.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw RecipeImportServiceError.invalidResponse
        }

        guard (200 ... 299).contains(httpResponse.statusCode) else {
            let errorPayload = try? JSONDecoder().decode(SupabaseRestErrorResponse.self, from: data)
            let fallback = "Recipe review queue failed (\(httpResponse.statusCode))."
            throw RecipeImportServiceError.requestFailed(errorPayload?.message ?? errorPayload?.error ?? fallback)
        }

        struct Payload: Decodable {
            let items: [RecipeImportReviewItem]
            let count: Int?
        }

        let payload = try JSONDecoder().decode(Payload.self, from: data)
        return payload.items
    }

    private func fetchCompletedImports(
        baseURL: String,
        userID: String
    ) async throws -> [RecipeImportCompletedItem] {
        var components = URLComponents(string: "\(baseURL)/v1/recipe/imports/completed") ?? URLComponents()
        components.queryItems = [
            URLQueryItem(name: "user_id", value: userID),
            URLQueryItem(name: "limit", value: "24"),
        ]
        guard let url = components.url else {
            throw RecipeImportServiceError.invalidRequest
        }

        let (data, response) = try await URLSession.shared.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw RecipeImportServiceError.invalidResponse
        }

        guard (200 ... 299).contains(httpResponse.statusCode) else {
            let errorPayload = try? JSONDecoder().decode(SupabaseRestErrorResponse.self, from: data)
            let fallback = "Completed imports failed (\(httpResponse.statusCode))."
            throw RecipeImportServiceError.requestFailed(errorPayload?.message ?? errorPayload?.error ?? fallback)
        }

        struct Payload: Decodable {
            let items: [RecipeImportCompletedItem]
            let count: Int?
        }

        let payload = try JSONDecoder().decode(Payload.self, from: data)
        return payload.items
    }
}

private enum OunjeLayout {
    static let screenHorizontalPadding: CGFloat = 16
    static let authButtonHeight: CGFloat = 52
    static let tabBarHeight: CGFloat = 58
    static let setupActionBarReservedHeight: CGFloat = 112
    static let welcomeActionBarHeight: CGFloat = 182
}

enum OunjeDevelopmentServer {
    static let productionBaseURL = "https://api.ounje.app"

    static var baseURL: String {
        if let explicitLocalBaseURL = explicitLocalBaseURL {
            return explicitLocalBaseURL
        }
        #if targetEnvironment(simulator)
        return "http://127.0.0.1:8080"
        #else
        return productionBaseURL
        #endif
    }

    static var candidateBaseURLs: [String] {
        var baseURLs: [String] = []
        if let explicitLocalBaseURL = explicitLocalBaseURL {
            baseURLs.append(explicitLocalBaseURL)
            return deduplicated(baseURLs)
        }
        #if targetEnvironment(simulator)
        baseURLs.append("http://127.0.0.1:8080")
        #endif
        baseURLs.append(productionBaseURL)

        return deduplicated(baseURLs)
    }

    private static var explicitLocalBaseURL: String? {
        guard
            let host = Bundle.main.object(forInfoDictionaryKey: "OunjeDevServerHost") as? String,
            !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return nil
        }

        let configuredPort = (Bundle.main.object(forInfoDictionaryKey: "OunjeDevServerPort") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let port = (configuredPort?.isEmpty == false ? configuredPort! : "8080")
        return "http://\(host):\(port)"
    }

    private static func deduplicated(_ baseURLs: [String]) -> [String] {
        var uniqueBaseURLs: [String] = []
        for baseURL in baseURLs where !uniqueBaseURLs.contains(baseURL) {
            uniqueBaseURLs.append(baseURL)
        }
        return uniqueBaseURLs
    }
}

private enum DiscoverAPIConfig {
    static let baseURL = OunjeDevelopmentServer.baseURL
}

private struct BiroScriptDisplayText: View {
    let text: String
    let size: CGFloat
    let color: Color

    init(_ text: String, size: CGFloat, color: Color = OunjePalette.primaryText) {
        self.text = text
        self.size = size
        self.color = color
    }

    var body: some View {
        ZStack {
            Text(text)
                .font(.custom("BiroScriptreduced", size: size))
                .tracking(0.2)
                .foregroundStyle(color.opacity(0.88))
                .offset(x: 0.55)

            Text(text)
                .font(.custom("BiroScriptreduced", size: size))
                .tracking(0.2)
                .foregroundStyle(color)
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }
}

private struct SleeScriptDisplayText: View {
    let text: String
    let size: CGFloat
    let color: Color

    init(_ text: String, size: CGFloat, color: Color = OunjePalette.primaryText) {
        self.text = text
        self.size = size
        self.color = color
    }

    var body: some View {
        Group {
            if shouldUseCustomNumerals {
                HandwrittenRunText(
                    text: text,
                    size: size,
                    color: color,
                    style: .slee
                )
            } else {
                ZStack(alignment: .topLeading) {
                    Text(text)
                        .font(.custom("Slee_handwritting-Regular", size: size))
                        .tracking(0.1)
                        .foregroundStyle(color.opacity(0.78))
                        .offset(x: 0.45, y: 0.35)

                    Text(text)
                        .font(.custom("Slee_handwritting-Regular", size: size))
                        .tracking(0.1)
                        .foregroundStyle(color)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }

    private var shouldUseCustomNumerals: Bool {
        guard text.contains(where: \.isNumber) else { return false }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowedScalars = CharacterSet.decimalDigits
            .union(.whitespaces)
            .union(CharacterSet(charactersIn: ":+-–—/.,"))

        let isMostlyNumericLabel = trimmed.unicodeScalars.allSatisfy { allowedScalars.contains($0) }
        return isMostlyNumericLabel && trimmed.count <= 14
    }
}

private struct SleeRecipeCardTitleText: View {
    let text: String
    let size: CGFloat
    let color: Color

    init(_ text: String, size: CGFloat, color: Color = OunjePalette.primaryText) {
        self.text = text
        self.size = size
        self.color = color
    }

    private var leadingDigitPrefix: String? {
        guard let match = text.range(of: #"^\d+"#, options: .regularExpression) else { return nil }
        return String(text[match])
    }

    private var remainderText: String {
        guard let prefix = leadingDigitPrefix else { return text }
        return text.dropFirst(prefix.count).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        Group {
            if let prefix = leadingDigitPrefix, !remainderText.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: size * 0.1) {
                    HandwrittenRunText(
                        text: prefix,
                        size: size,
                        color: color,
                        style: .slee
                    )
                    .fixedSize()

                    Text(remainderText)
                        .recipeCardTitleFont(size)
                        .foregroundStyle(color)
                        .lineLimit(2)
                        .minimumScaleFactor(0.84)
                }
            } else {
                Text(text)
                    .recipeCardTitleFont(size)
                    .foregroundStyle(color)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }
}

private extension View {
    func biroHeaderFont(_ size: CGFloat) -> some View {
        Group {
            if size >= 28 {
                self
                    .font(.custom("BiroScriptreduced", size: size))
                    .tracking(0.2)
            } else {
                self
                    .font(.system(size: size, weight: .bold, design: .rounded))
            }
        }
    }

    func sleeDisplayFont(_ size: CGFloat) -> some View {
        self.modifier(SleeDisplayModifier(size: size))
    }

    func recipeCardTitleFont(_ size: CGFloat) -> some View {
        self.modifier(RecipeCardTitleModifier(size: size))
    }
}

private struct SleeDisplayModifier: ViewModifier {
    let size: CGFloat

    func body(content: Content) -> some View {
        ZStack(alignment: .topLeading) {
            content
                .font(.custom("Slee_handwritting-Regular", size: size))
                .tracking(0.12)
                .foregroundStyle(OunjePalette.primaryText.opacity(0.82))
                .offset(x: 0.55, y: 0.4)

            content
                .font(.custom("Slee_handwritting-Regular", size: size))
                .tracking(0.12)
        }
    }
}

private struct RecipeCardTitleModifier: ViewModifier {
    let size: CGFloat

    func body(content: Content) -> some View {
        ZStack(alignment: .topLeading) {
            content
                .font(.custom("Slee_handwritting-Regular", size: size))
                .tracking(0.1)
                .foregroundStyle(OunjePalette.primaryText.opacity(0.78))
                .offset(x: 0.45, y: 0.35)

            content
                .font(.custom("Slee_handwritting-Regular", size: size))
                .tracking(0.1)
        }
    }
}

private enum HandwrittenNumeralStyle {
    case slee

    var baseFontName: String {
        switch self {
        case .slee:
            return "Slee_handwritting-Regular"
        }
    }

    var tracking: CGFloat {
        switch self {
        case .slee:
            return 0.1
        }
    }

    var shadowOffset: CGSize {
        switch self {
        case .slee:
            return CGSize(width: 0.45, height: 0.35)
        }
    }

    var strokeWidthFactor: CGFloat {
        switch self {
        case .slee:
            return 0.08
        }
    }

    var characterSpacingFactor: CGFloat {
        switch self {
        case .slee:
            return 0.025
        }
    }

    var wordSpacingFactor: CGFloat {
        switch self {
        case .slee:
            return 0.16
        }
    }

    var numeralWidthFactor: CGFloat {
        switch self {
        case .slee:
            return 0.54
        }
    }
}

private struct HandwrittenRunText: View {
    let text: String
    let size: CGFloat
    let color: Color
    let style: HandwrittenNumeralStyle

    var body: some View {
        FlowWrapLayout(
            lineSpacing: size * 0.16,
            itemSpacing: size * style.wordSpacingFactor
        ) {
            ForEach(tokenizedWords.indices, id: \.self) { index in
                HandwrittenWordView(
                    word: tokenizedWords[index],
                    size: size,
                    color: color,
                    style: style
                )
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }

    private var tokenizedWords: [String] {
        text
            .split(separator: " ", omittingEmptySubsequences: false)
            .map(String.init)
    }
}

private struct HandwrittenWordView: View {
    let word: String
    let size: CGFloat
    let color: Color
    let style: HandwrittenNumeralStyle

    var body: some View {
        HStack(spacing: size * style.characterSpacingFactor) {
            ForEach(Array(word.enumerated()), id: \.offset) { _, character in
                if character.isNumber {
                    HandwrittenDigitView(
                        digit: character,
                        size: size,
                        color: color,
                        style: style
                    )
                } else {
                    ZStack(alignment: .topLeading) {
                    Text(String(character))
                        .font(.custom(style.baseFontName, size: size))
                        .tracking(style.tracking)
                        .foregroundStyle(color.opacity(0.78))
                        .offset(style.shadowOffset)

                        Text(String(character))
                            .font(.custom(style.baseFontName, size: size))
                            .tracking(style.tracking)
                            .foregroundStyle(color)
                    }
                }
            }
        }
    }
}

private struct HandwrittenDigitView: View {
    let digit: Character
    let size: CGFloat
    let color: Color
    let style: HandwrittenNumeralStyle

    var body: some View {
        HandwrittenDigitShape(digit: digit)
            .stroke(
                color,
                style: StrokeStyle(
                    lineWidth: size * style.strokeWidthFactor,
                    lineCap: .round,
                    lineJoin: .round
                )
            )
            .frame(
                width: size * style.numeralWidthFactor,
                height: size * 0.9
            )
            .overlay(alignment: .topLeading) {
                HandwrittenDigitShape(digit: digit)
                    .stroke(
                        color.opacity(0.78),
                        style: StrokeStyle(
                            lineWidth: size * style.strokeWidthFactor,
                            lineCap: .round,
                            lineJoin: .round
                        )
                    )
                    .offset(style.shadowOffset)
            }
            .padding(.vertical, size * 0.02)
    }
}

private struct HandwrittenDigitShape: Shape {
    let digit: Character

    func path(in rect: CGRect) -> Path {
        switch digit {
        case "0":
            return zeroPath(in: rect)
        case "1":
            return onePath(in: rect)
        case "2":
            return twoPath(in: rect)
        case "3":
            return threePath(in: rect)
        case "4":
            return fourPath(in: rect)
        case "5":
            return fivePath(in: rect)
        case "6":
            return sixPath(in: rect)
        case "7":
            return sevenPath(in: rect)
        case "8":
            return eightPath(in: rect)
        case "9":
            return ninePath(in: rect)
        default:
            return Path()
        }
    }

    private func pt(_ x: CGFloat, _ y: CGFloat, in rect: CGRect) -> CGPoint {
        CGPoint(x: rect.minX + rect.width * x, y: rect.minY + rect.height * y)
    }

    private func zeroPath(in rect: CGRect) -> Path {
        var path = Path()
        path.addEllipse(in: CGRect(
            x: rect.minX + rect.width * 0.12,
            y: rect.minY + rect.height * 0.08,
            width: rect.width * 0.72,
            height: rect.height * 0.78
        ))
        return path
    }

    private func onePath(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: pt(0.28, 0.28, in: rect))
        path.addLine(to: pt(0.48, 0.12, in: rect))
        path.addLine(to: pt(0.48, 0.86, in: rect))
        path.move(to: pt(0.22, 0.84, in: rect))
        path.addLine(to: pt(0.64, 0.84, in: rect))
        return path
    }

    private func twoPath(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: pt(0.18, 0.28, in: rect))
        path.addQuadCurve(to: pt(0.72, 0.24, in: rect), control: pt(0.42, 0.02, in: rect))
        path.addQuadCurve(to: pt(0.26, 0.58, in: rect), control: pt(0.72, 0.46, in: rect))
        path.addLine(to: pt(0.14, 0.84, in: rect))
        path.addLine(to: pt(0.76, 0.84, in: rect))
        return path
    }

    private func threePath(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: pt(0.16, 0.2, in: rect))
        path.addQuadCurve(to: pt(0.66, 0.34, in: rect), control: pt(0.62, 0.02, in: rect))
        path.addQuadCurve(to: pt(0.3, 0.48, in: rect), control: pt(0.6, 0.46, in: rect))
        path.move(to: pt(0.3, 0.48, in: rect))
        path.addQuadCurve(to: pt(0.68, 0.82, in: rect), control: pt(0.7, 0.5, in: rect))
        path.addQuadCurve(to: pt(0.16, 0.8, in: rect), control: pt(0.46, 0.98, in: rect))
        return path
    }

    private func fourPath(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: pt(0.66, 0.12, in: rect))
        path.addLine(to: pt(0.66, 0.84, in: rect))
        path.move(to: pt(0.18, 0.56, in: rect))
        path.addLine(to: pt(0.76, 0.56, in: rect))
        path.move(to: pt(0.18, 0.56, in: rect))
        path.addLine(to: pt(0.5, 0.12, in: rect))
        return path
    }

    private func fivePath(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: pt(0.72, 0.12, in: rect))
        path.addLine(to: pt(0.24, 0.12, in: rect))
        path.addLine(to: pt(0.22, 0.46, in: rect))
        path.addQuadCurve(to: pt(0.7, 0.78, in: rect), control: pt(0.7, 0.44, in: rect))
        path.addQuadCurve(to: pt(0.18, 0.78, in: rect), control: pt(0.46, 0.96, in: rect))
        return path
    }

    private func sixPath(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: pt(0.68, 0.18, in: rect))
        path.addQuadCurve(to: pt(0.24, 0.54, in: rect), control: pt(0.32, 0.08, in: rect))
        path.addQuadCurve(to: pt(0.66, 0.82, in: rect), control: pt(0.18, 0.88, in: rect))
        path.addQuadCurve(to: pt(0.42, 0.52, in: rect), control: pt(0.76, 0.56, in: rect))
        path.addQuadCurve(to: pt(0.22, 0.62, in: rect), control: pt(0.28, 0.48, in: rect))
        return path
    }

    private func sevenPath(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: pt(0.16, 0.16, in: rect))
        path.addLine(to: pt(0.78, 0.16, in: rect))
        path.addLine(to: pt(0.32, 0.86, in: rect))
        return path
    }

    private func eightPath(in rect: CGRect) -> Path {
        var path = Path()
        path.addEllipse(in: CGRect(
            x: rect.minX + rect.width * 0.22,
            y: rect.minY + rect.height * 0.08,
            width: rect.width * 0.44,
            height: rect.height * 0.34
        ))
        path.addEllipse(in: CGRect(
            x: rect.minX + rect.width * 0.18,
            y: rect.minY + rect.height * 0.42,
            width: rect.width * 0.52,
            height: rect.height * 0.4
        ))
        return path
    }

    private func ninePath(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: pt(0.64, 0.46, in: rect))
        path.addQuadCurve(to: pt(0.26, 0.2, in: rect), control: pt(0.24, 0.48, in: rect))
        path.addQuadCurve(to: pt(0.7, 0.22, in: rect), control: pt(0.48, 0.0, in: rect))
        path.addLine(to: pt(0.62, 0.84, in: rect))
        return path
    }
}

private struct FlowWrapLayout: Layout {
    let lineSpacing: CGFloat
    let itemSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .greatestFiniteMagnitude
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var usedWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > maxWidth {
                usedWidth = max(usedWidth, x - itemSpacing)
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            lineHeight = max(lineHeight, size.height)
            x += size.width + itemSpacing
        }

        usedWidth = max(usedWidth, x > 0 ? x - itemSpacing : 0)
        return CGSize(width: min(maxWidth, usedWidth), height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var lineHeight: CGFloat = 0
        let maxWidth = bounds.width

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX && (x - bounds.minX) + size.width > maxWidth {
                x = bounds.minX
                y += lineHeight + lineSpacing
                lineHeight = 0
            }

            subview.place(
                at: CGPoint(x: x, y: y),
                proposal: ProposedViewSize(width: size.width, height: size.height)
            )
            x += size.width + itemSpacing
            lineHeight = max(lineHeight, size.height)
        }
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

private enum OunjePalette {
    static let background = Color(hex: "121212")
    static let panel = Color(hex: "1E1E1E")
    static let surface = Color(hex: "2E2E2E")
    static let elevated = Color(hex: "383838")
    static let navBar = Color(hex: "1B1D20")
    static let accent = Color(hex: "1E5A3E")
    static let accentDark = Color(hex: "123828")
    static let softCream = Color(hex: "E9E0D2")
    static let tabSelected = Color(hex: "2D6B4B")
    static let secondaryText = Color(hex: "8A8A8A")
    static let linkText = Color(hex: "B2FFFF")
    static let stroke = Color.white.opacity(0.08)
    static let primaryText = Color.white
}

private extension Color {
    init(hex: String) {
        let cleaned = hex.replacingOccurrences(of: "#", with: "")
        let scanner = Scanner(string: cleaned)
        var value: UInt64 = 0
        scanner.scanHexInt64(&value)

        let red = Double((value >> 16) & 0xFF) / 255
        let green = Double((value >> 8) & 0xFF) / 255
        let blue = Double(value & 0xFF) / 255

        self.init(.sRGB, red: red, green: green, blue: blue, opacity: 1)
    }
}
