import SwiftUI
import UIKit
import AuthenticationServices
import CryptoKit
import Security
import MapKit

@main
struct OunjeAgenticApp: App {
    @StateObject private var store = MealPlanningAppStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
        }
    }
}

private struct RootView: View {
    @EnvironmentObject private var store: MealPlanningAppStore

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
                MealPlannerShellView()
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

private struct RemoteStateBootstrapView: View {
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

            VStack(spacing: 18) {
                ProgressView()
                    .tint(OunjePalette.accent)
                    .scaleEffect(1.2)

                Text("Loading your setup")
                    .font(.system(size: 22, weight: .black, design: .rounded))
                    .foregroundStyle(.white)

                Text("We’re syncing your profile from Supabase so we can drop you into the right place.")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(OunjePalette.secondaryText)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 280)
            }
            .padding(32)
            .background(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(OunjePalette.panel.opacity(0.92))
                    .overlay(
                        RoundedRectangle(cornerRadius: 28, style: .continuous)
                            .strokeBorder(.white.opacity(0.06), lineWidth: 1)
                    )
            )
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
    @State private var revealContent = false
    @State private var previewLift = false

    private let googleDevUserIDKey = "agentic-google-dev-user-id-v1"
    private let googleDevEmailKey = "agentic-google-dev-email-v1"

    var body: some View {
        ZStack {
            Image("WelcomeBackground")
                .resizable()
                .scaledToFill()
                .ignoresSafeArea()

            LinearGradient(
                colors: [
                    .black.opacity(0.14),
                    .black.opacity(0.36),
                    OunjePalette.background.opacity(0.92),
                    OunjePalette.background
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            GeometryReader { proxy in
                let authButtonWidth = min(320, proxy.size.width - 56)

                VStack(alignment: .leading, spacing: 22) {
                    Spacer(minLength: max(120, proxy.safeAreaInsets.top + 120))

                    VStack(alignment: .leading, spacing: 12) {
                        Text("Meals that plan,\nsource, and restock\nthemselves.")
                            .font(.system(size: 38, weight: .black, design: .rounded))
                            .foregroundStyle(.white)
                            .fixedSize(horizontal: false, vertical: true)

                        Text("meal prepping for gen-z's")
                            .font(.system(size: 15, weight: .black, design: .rounded))
                            .tracking(0.8)
                            .foregroundStyle(OunjePalette.accent)
                    }
                    .padding(.top, 40)

                    Spacer()

                    VStack(alignment: .center, spacing: 16) {
                        if let authStatusMessage {
                            Text(authStatusMessage)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.92))
                                .frame(maxWidth: .infinity, alignment: .center)
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
                            .frame(width: authButtonWidth, height: OunjeLayout.authButtonHeight)
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
                            .frame(width: authButtonWidth, alignment: .leading)
                            .buttonStyle(WelcomeAuthButtonStyle())
                            .disabled(isGoogleSigningIn)
                        }

                        Text("After sign-in: setup -> plan generation -> recipes and groceries.")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(OunjePalette.secondaryText)
                            .frame(maxWidth: .infinity, alignment: .center)
                    }

                    Spacer()
                }
                .padding(.horizontal, OunjeLayout.screenHorizontalPadding)
                .padding(.bottom, max(36, proxy.safeAreaInsets.bottom + 24))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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
            withAnimation(.easeInOut(duration: 1.35).repeatForever(autoreverses: true)) {
                previewLift = true
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
                        signedInAt: Date()
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
                signedInAt: Date()
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
            signedInAt: Date()
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
            store.signIn(
                with: session,
                onboarded: false,
                profile: store.profile,
                lastOnboardingStep: store.lastOnboardingStep
            )
            authStatusMessage = fallbackStatusMessage ?? "Signed in. Let's finish setup."
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
        if let existing = defaults.string(forKey: googleDevUserIDKey), !existing.isEmpty {
            return existing
        }

        let generated = "google-dev-\(UUID().uuidString.lowercased())"
        defaults.set(generated, forKey: googleDevUserIDKey)
        return generated
    }

    private func stableGoogleDevEmail() -> String {
        let defaults = UserDefaults.standard
        if let existing = defaults.string(forKey: googleDevEmailKey), !existing.isEmpty {
            return existing
        }

        let generated = "google-user@ounje.local"
        defaults.set(generated, forKey: googleDevEmailKey)
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
                                                        .font(.system(size: 15, weight: .black, design: .rounded))
                                                }
                                                .frame(minWidth: 140, minHeight: 54)
                                            } else if currentStep == .summary {
                                                HStack(spacing: 8) {
                                                    Text("Enter app")
                                                        .font(.system(size: 15, weight: .black, design: .rounded))
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
                    .font(.system(size: 24, weight: .black, design: .rounded))
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
                    .font(.system(size: 32, weight: .black, design: .rounded))
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
                        .font(.system(size: 11, weight: .black, design: .rounded))
                        .tracking(0.8)
                        .foregroundStyle(OunjePalette.secondaryText)

                    HStack(alignment: .lastTextBaseline, spacing: 8) {
                        Text(budgetPerCycle.asCurrency)
                            .font(.system(size: 34, weight: .black, design: .rounded))
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

    private let key = "ounje-saved-recipes-v1"

    init() { load() }

    func isSaved(_ recipe: DiscoverRecipeCardData) -> Bool {
        savedRecipes.contains { $0.id == recipe.id }
    }

    func toggle(_ recipe: DiscoverRecipeCardData) {
        if isSaved(recipe) {
            savedRecipes.removeAll { $0.id == recipe.id }
        } else {
            savedRecipes.insert(recipe, at: 0)
        }
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(savedRecipes) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([DiscoverRecipeCardData].self, from: data)
        else { return }
        savedRecipes = decoded
    }
}

private struct MealPlannerShellView: View {
    @EnvironmentObject private var store: MealPlanningAppStore
    @StateObject private var savedStore = SavedRecipesStore()
    @State private var selectedTab: AppTab = .prep
    @State private var discoverSearchText = ""
    @State private var cookbookSearchText = ""
    @State private var cartSearchText = ""
    @State private var isCookbookComposerPresented = false

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                MainAppBackdrop()

                tabContent
                    .environmentObject(savedStore)
                    .transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.98)), removal: .opacity))
            }
            .background(OunjePalette.background.ignoresSafeArea())
            .safeAreaInset(edge: .bottom, spacing: 0) {
                BottomNavigationDock(
                    selectedTab: $selectedTab,
                    searchText: activeSearchBinding,
                    searchPlaceholder: activeSearchPlaceholder,
                    showsComposer: selectedTab == .cookbook,
                    safeAreaBottom: proxy.safeAreaInsets.bottom,
                    onComposerTap: { isCookbookComposerPresented = true }
                )
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .sheet(isPresented: $isCookbookComposerPresented) {
            DiscoverComposerSheet()
                .presentationDetents([.fraction(0.5)])
                .presentationDragIndicator(.hidden)
        }
    }

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .prep:
            PrepTabView(selectedTab: $selectedTab)
        case .discover:
            DiscoverTabView(selectedTab: $selectedTab, searchText: $discoverSearchText)
        case .cookbook:
            CookbookTabView(searchText: $cookbookSearchText)
        case .cart:
            CartTabView(searchText: $cartSearchText)
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
            return $cartSearchText
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
            return "Search cart"
        case .profile:
            return nil
        }
    }
}

private struct DiscoverTabView: View {
    @EnvironmentObject private var store: MealPlanningAppStore
    @Binding var selectedTab: AppTab
    @Binding var searchText: String
    @StateObject private var viewModel = DiscoverRecipesViewModel()

    private let recipeColumns = [
        GridItem(.flexible(), spacing: 16, alignment: .top),
        GridItem(.flexible(), spacing: 16, alignment: .top)
    ]

    private var filters: [String] {
        var values = ["All"]
        for value in viewModel.recipes.compactMap(\.filterChipLabel) where !values.contains(value) {
            values.append(value)
        }
        return Array(values.prefix(6))
    }

    private var filteredRecipes: [DiscoverRecipeCardData] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return viewModel.recipes.filter { recipe in
            let matchesFilter = viewModel.selectedFilter == "All" || recipe.filterChipLabel == viewModel.selectedFilter
            let matchesQuery = query.isEmpty ||
                recipe.title.lowercased().contains(query) ||
                recipe.authorLabel.lowercased().contains(query) ||
                recipe.filterLabel.lowercased().contains(query)
            return matchesFilter && matchesQuery
        }
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
        Array(filteredRecipes.prefix(12))
    }

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Compact header
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Discover")
                                .font(.system(size: 32, weight: .black, design: .rounded))
                            .foregroundStyle(OunjePalette.primaryText)
                        Text("Find your next meal")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(OunjePalette.secondaryText)
                    }

                    // Category chips
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 10) {
                                ForEach(filters, id: \.self) { filter in
                                    FilterTagButton(
                                        title: filter,
                                        isSelected: viewModel.selectedFilter == filter,
                                    accent: OunjePalette.accent
                                    ) {
                                        withAnimation(.spring(response: 0.3, dampingFraction: 0.84)) {
                                            viewModel.selectedFilter = filter
                                        }
                                    }
                                }
                            }
                            .padding(.trailing, 4)
                    }

                    if let errorMessage = viewModel.errorMessage {
                        BubblySurfaceCard(accent: Color(hex: "FF8E8E")) {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Recipe feed unavailable")
                                    .font(.system(size: 18, weight: .black, design: .rounded))
                                    .foregroundStyle(OunjePalette.primaryText)
                                Text(errorMessage)
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundStyle(OunjePalette.secondaryText)
                            }
                        }
                    } else if viewModel.isLoading && viewModel.recipes.isEmpty {
                        LazyVGrid(columns: recipeColumns, spacing: 14) {
                            ForEach(0..<6, id: \.self) { _ in
                                RoundedRectangle(cornerRadius: 24, style: .continuous)
                                    .fill(OunjePalette.surface.opacity(0.9))
                                    .frame(height: 292)
                                    .redacted(reason: .placeholder)
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
                                DiscoverRemoteRecipeCard(recipe: recipe)
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
        .task {
            await viewModel.loadIfNeeded()
        }
    }
}

private struct CookbookTabView: View {
    @Binding var searchText: String
    @EnvironmentObject private var savedStore: SavedRecipesStore
    @State private var selectedFilter: String = "All"

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

    private let columns = [
        GridItem(.flexible(), spacing: 14, alignment: .top),
        GridItem(.flexible(), spacing: 14, alignment: .top)
    ]

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack(alignment: .center) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Cookbook")
                                .font(.system(size: 32, weight: .black, design: .rounded))
                                .foregroundStyle(OunjePalette.primaryText)
                            Text("Your saved recipes")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(OunjePalette.secondaryText)
                        }

                        Spacer(minLength: 16)

                        Button {
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "crown")
                                    .font(.system(size: 13, weight: .bold))
                                Text("Try Pro")
                                    .font(.system(size: 15, weight: .bold, design: .rounded))
                            }
                            .padding(.horizontal, 18)
                            .padding(.vertical, 12)
                        }
                        .buttonStyle(DiscoverTopActionButtonStyle())
                    }

                        HStack(spacing: 14) {
                            FilterTagButton(
                                title: "All",
                                isSelected: selectedFilter == "All",
                            accent: OunjePalette.accent
                            ) {
                                selectedFilter = "All"
                            }

                            Button {
                            } label: {
                            HStack(spacing: 6) {
                                    Image(systemName: "plus")
                                    .font(.system(size: 14, weight: .bold))
                                Text("Add collection")
                                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                            }
                            .foregroundStyle(OunjePalette.secondaryText)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(
                                Capsule(style: .continuous)
                                    .stroke(OunjePalette.stroke, lineWidth: 1)
                            )
                            }
                            .buttonStyle(.plain)
                        }

                        InlineSearchBar(text: $searchText, placeholder: "Search recipes")

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 10) {
                                ForEach(filters, id: \.self) { filter in
                                    FilterTagButton(
                                        title: filter,
                                        isSelected: selectedFilter == filter,
                                    accent: OunjePalette.accent
                                    ) {
                                        withAnimation(.spring(response: 0.3, dampingFraction: 0.84)) {
                                            selectedFilter = filter
                                        }
                                    }
                                }
                            }
                            .padding(.trailing, 4)
                        }

                    if filteredRecipes.isEmpty {
                            RecipesEmptyState(
                            title: savedStore.savedRecipes.isEmpty
                                ? "No saved recipes yet"
                                : "No matches found",
                            detail: savedStore.savedRecipes.isEmpty
                                ? "Tap the bookmark icon on any recipe in Discover to save it here."
                                : "Try a different search or category.",
                            symbolName: "bookmark"
                            )
                        } else {
                            LazyVGrid(columns: columns, spacing: 14) {
                                ForEach(filteredRecipes) { recipe in
                                    DiscoverRemoteRecipeCard(recipe: recipe)
                            }
                        }
                    }
                }
                .padding(.horizontal, OunjeLayout.screenHorizontalPadding)
                .padding(.top, 14)
                .padding(.bottom, 12)
            }
            .scrollIndicators(.hidden)
        }
        .background(OunjePalette.background.ignoresSafeArea())
    }
}

private struct PrepTabView: View {
    @EnvironmentObject private var store: MealPlanningAppStore
    @Binding var selectedTab: AppTab

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    PrepTrackerCard(store: store)

                    VStack(alignment: .leading, spacing: 12) {
                        Text("Meals in this prep")
                                .font(.system(size: 26, weight: .black, design: .rounded))
                            .foregroundStyle(OunjePalette.primaryText)

                        MealsRecipeSlot(title: "Breakfast", recipe: recipeForSlot(0))
                        MealsRecipeSlot(title: "Lunch", recipe: recipeForSlot(1))
                        MealsRecipeSlot(title: "Dinner", recipe: recipeForSlot(2))
                    }
                    .padding(.top, 4)

                    VStack(alignment: .leading, spacing: 12) {
                        Text("Shopping list")
                            .font(.system(size: 26, weight: .black, design: .rounded))
                            .foregroundStyle(OunjePalette.primaryText)

                        if (store.latestPlan?.groceryItems.isEmpty ?? true) {
                            RecipesEmptyState(
                                title: "No current cart",
                                detail: "Generate a fresh prep and Ounje will attach a grocery list here.",
                                symbolName: "cart"
                            )
                        } else {
                            ForEach(Array((store.latestPlan?.groceryItems ?? []).prefix(4))) { item in
                                ShoppingListRow(item: item)
                            }
                        }

                        VStack(spacing: 10) {
                        AddActionRow(
                                title: "Open cart",
                                detail: "See the full ingredient list and provider history.",
                                symbolName: "cart",
                            accent: Color(hex: "56D7C8")
                        ) {
                                selectedTab = .cart
                        }

                        AddActionRow(
                                title: "Open cookbook",
                                detail: "Browse recipes in your saved feed.",
                                symbolName: "fork.knife",
                                accent: Color(hex: "7A7DFF")
                            ) {
                                selectedTab = .cookbook
                            }
                        }
                    }
                }
                .padding(.horizontal, OunjeLayout.screenHorizontalPadding)
                .padding(.top, 14)
                .padding(.bottom, 12)
            }
            .scrollIndicators(.hidden)
        }
        .background(OunjePalette.background.ignoresSafeArea())
    }

    private func recipeForSlot(_ index: Int) -> Recipe? {
        guard let recipes = store.latestPlan?.recipes.map(\.recipe), !recipes.isEmpty else { return nil }
        return recipes[index % recipes.count]
    }
}

private struct ProfileTabView: View {
    @EnvironmentObject private var store: MealPlanningAppStore

    var body: some View {
        GeometryReader { proxy in
                    ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .center) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Profile")
                                .font(.system(size: 32, weight: .black, design: .rounded))
                                .foregroundStyle(OunjePalette.primaryText)
                            Text("Your prep identity, defaults, and account details")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(OunjePalette.secondaryText)
                        }

                        Spacer(minLength: 16)

                        Button {
                            store.signOutToWelcome()
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "rectangle.portrait.and.arrow.right")
                                    .font(.system(size: 13, weight: .bold))
                                Text("Sign out")
                                    .font(.system(size: 15, weight: .bold, design: .rounded))
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                        }
                        .buttonStyle(DiscoverTopActionButtonStyle())
                    }

                    if let profile = store.profile {
                        BubblySurfaceCard(accent: OunjePalette.accent) {
                            VStack(alignment: .leading, spacing: 10) {
                                Text(profile.trimmedPreferredName ?? "Ounje profile")
                                    .font(.system(size: 28, weight: .black, design: .rounded))
                                    .foregroundStyle(.white)
                                Text(profile.profileNarrative)
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.7))
                                    .fixedSize(horizontal: false, vertical: true)

                                HStack(spacing: 10) {
                                    ProfileMetaPill(title: profile.budgetSummary)
                                    ProfileMetaPill(title: profile.cadence.title)
                                    ProfileMetaPill(title: profile.orderingAutonomy.title)
                                }
                            }
                        }

                        VStack(spacing: 12) {
                            ForEach(profile.structuredSummarySections) { section in
                                ThemedCard {
                                    VStack(alignment: .leading, spacing: 8) {
                                        Text(section.title)
                                            .font(.system(size: 16, weight: .black, design: .rounded))
                                            .foregroundStyle(OunjePalette.primaryText)
                                        Text(section.detail)
                                            .font(.system(size: 14, weight: .medium))
                                            .foregroundStyle(OunjePalette.secondaryText)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                }
                            }
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
                .padding(.bottom, 12)
            }
            .scrollIndicators(.hidden)
        }
        .background(OunjePalette.background.ignoresSafeArea())
    }
}

private struct ProfileMetaPill: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 12, weight: .bold, design: .rounded))
            .foregroundStyle(.white.opacity(0.82))
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                Capsule(style: .continuous)
                    .fill(.white.opacity(0.08))
            )
    }
}

private struct CartTabView: View {
    @EnvironmentObject private var store: MealPlanningAppStore
    @Binding var searchText: String

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack(alignment: .center) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Cart")
                                .font(.system(size: 32, weight: .black, design: .rounded))
                                .foregroundStyle(OunjePalette.primaryText)
                            Text("Current list, previous orders, and checkout paths")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(OunjePalette.secondaryText)
                        }

                        Spacer(minLength: 16)

                        Button {
                            Task { await store.generatePlan() }
                        } label: {
                            HStack(spacing: 6) {
                                if store.isGenerating {
                                    ProgressView().controlSize(.small).tint(.white)
                                } else {
                                Image(systemName: "sparkles")
                                        .font(.system(size: 13, weight: .bold))
                                }
                                Text(store.isGenerating ? "Generating" : "Generate")
                                    .font(.system(size: 15, weight: .bold, design: .rounded))
                            }
                            .padding(.horizontal, 18)
                            .padding(.vertical, 12)
                        }
                        .buttonStyle(DiscoverTopActionButtonStyle())
                        .disabled(store.isGenerating)
                    }

                    InlineSearchBar(text: $searchText, placeholder: "Search shopping list")

                    if let best = store.latestPlan?.bestQuote {
                        BubblySurfaceCard(accent: Color(hex: "56D7C8")) {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Buying from")
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundStyle(OunjePalette.secondaryText)
                                Text(best.provider.title)
                                    .font(.system(size: 24, weight: .black, design: .rounded))
                                Text("\(best.estimatedTotal.asCurrency) total • \(best.etaDays)-day ETA")
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundStyle(OunjePalette.secondaryText)
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        MainAppSectionHeader(eyebrow: "Current cart", title: "Shopping list")
                        Text("Ingredients tied to the active prep.")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(OunjePalette.secondaryText)

                        if filteredGroceryItems.isEmpty {
                            RecipesEmptyState(
                                title: "No active shopping list",
                                detail: "Generate a prep and Ounje will build the ingredient list here.",
                                symbolName: "cart"
                            )
                        } else {
                            ForEach(filteredGroceryItems) { item in
                                ShoppingListRow(item: item)
                            }
                        }
                    }

                    if let previousQuote = store.planHistory.dropFirst().first?.bestQuote {
                        VStack(alignment: .leading, spacing: 12) {
                            MainAppSectionHeader(eyebrow: "Order memory", title: "Previously bought")
                            Text("Recent order history Ounje can learn from.")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(OunjePalette.secondaryText)
                            BubblySurfaceCard(accent: OunjePalette.softCream) {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(previousQuote.provider.title)
                                        .font(.system(size: 20, weight: .black, design: .rounded))
                                    Text("Recent total \(previousQuote.estimatedTotal.asCurrency)")
                                        .font(.system(size: 14, weight: .medium))
                                        .foregroundStyle(OunjePalette.secondaryText)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, OunjeLayout.screenHorizontalPadding)
                .padding(.top, 14)
                .padding(.bottom, 12)
            }
            .scrollIndicators(.hidden)
        }
        .background(OunjePalette.background.ignoresSafeArea())
    }

    private var filteredGroceryItems: [GroceryItem] {
        guard let items = store.latestPlan?.groceryItems else { return [] }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return items }
        return items.filter { $0.name.lowercased().contains(query) }
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
                        .font(.system(size: 24, weight: .black, design: .rounded))
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

private struct CapsuleSegmentControl<Option: Hashable>: View {
    @Binding var selection: Option
    let options: [Option]
    let title: (Option) -> String

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.self) { option in
                Button {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                        selection = option
                    }
                } label: {
                    Text(title(option))
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundStyle(selection == option ? OunjePalette.primaryText : OunjePalette.secondaryText)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(
                            RoundedRectangle(cornerRadius: 24, style: .continuous)
                                .fill(selection == option ? OunjePalette.surface : .clear)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(OunjePalette.elevated.opacity(0.7))
                .overlay(
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .stroke(OunjePalette.stroke, lineWidth: 1)
                )
        )
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

private struct InlineSearchBar: View {
    @Binding var text: String
    let placeholder: String

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(OunjePalette.secondaryText)

            TextField("", text: $text, prompt: Text(placeholder).foregroundColor(OunjePalette.secondaryText))
                .font(.system(size: 17, weight: .medium, design: .rounded))
                .foregroundStyle(OunjePalette.primaryText)

            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(OunjePalette.secondaryText)
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
                    .font(.system(size: 20, weight: .black, design: .rounded))
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
                        .font(.system(size: 18, weight: .black, design: .rounded))
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
                    .font(.system(size: 32, weight: .black, design: .rounded))
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
                    .font(.system(size: 20, weight: .black, design: .rounded))
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
                    .font(.system(size: 18, weight: .bold, design: .rounded))
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
                    .font(.system(size: 17, weight: .bold, design: .rounded))
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
                    .font(.system(size: 13, weight: .black, design: .rounded))
                    .foregroundStyle(recipe == nil ? OunjePalette.secondaryText : OunjePalette.accent)
            }
            .frame(width: 40)

            Rectangle()
                .fill(OunjePalette.stroke)
                .frame(width: 1, height: 32)

            VStack(alignment: .leading, spacing: 3) {
                Text(recipe?.title ?? "No recipe yet")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
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
                .font(.system(size: 24, weight: .black, design: .rounded))
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

                Text(nextDeliveryTitle)
                    .font(.system(size: 32, weight: .black, design: .rounded))
                    .foregroundStyle(OunjePalette.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                
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
                        .font(.system(size: 12, weight: .bold, design: .rounded))
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
                    .font(.system(size: 12, weight: .bold, design: .rounded))
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
            .font(.system(size: 12, weight: .bold, design: .rounded))
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
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(OunjePalette.primaryText)
                    .disabled(!canEdit)
                    .opacity(canEdit ? 1 : 0.45)
            }
            .padding(.bottom, 2)

            VStack(alignment: .leading, spacing: 6) {
                Text("Delivery time")
                    .font(.system(size: 30, weight: .black, design: .rounded))
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
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .foregroundStyle(OunjePalette.secondaryText)
                        PrepMetaPill(title: selectedWindow.shortTitle, accent: OunjePalette.accent)
                        PrepMetaPill(title: selectedWindow.detail, accent: OunjePalette.softCream)
                    }
                }
            } else {
                ThemedCard {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(selectedWindow.shortTitle)
                            .font(.system(size: 22, weight: .black, design: .rounded))
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
    let etaText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label(providerTitle ?? "Delivery", systemImage: "storefront.fill")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
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
                    .font(.system(size: 12, weight: .bold, design: .rounded))
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
        case .prep: return "calendar.badge.clock"
        case .discover: return "safari"
        case .cookbook: return "fork.knife"
        case .cart: return "cart"
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
                    VStack(spacing: 4) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(selectedTab == tab ? OunjePalette.elevated : .clear)
                                .frame(width: 40, height: 36)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .stroke(selectedTab == tab ? OunjePalette.accent.opacity(0.55) : .clear, lineWidth: 1)
                                )

                            Image(systemName: tab.symbol)
                                .font(.system(size: 18, weight: .bold))
                                .foregroundStyle(selectedTab == tab ? OunjePalette.softCream : OunjePalette.secondaryText)
                        }

                        Text(tab.title)
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundStyle(selectedTab == tab ? OunjePalette.softCream : OunjePalette.secondaryText)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: OunjeLayout.tabBarHeight)
    }
}

private struct BottomNavigationDock: View {
    @Binding var selectedTab: AppTab
    var searchText: Binding<String>?
    var searchPlaceholder: String?
    var showsComposer: Bool = false
    var safeAreaBottom: CGFloat = 0
    var onComposerTap: (() -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            if showsComposer, let onComposerTap {
                VStack(spacing: 0) {
                    DiscoverComposerDockButton(action: onComposerTap)
                        .padding(.horizontal, 16)
                        .padding(.top, 14)
                        .padding(.bottom, 12)

                    Rectangle()
                        .fill(OunjePalette.stroke)
                        .frame(height: 1)
                        .padding(.horizontal, 16)
                }
            } else if let searchText, let searchPlaceholder {
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
    }
}

private struct DiscoverComposerDockButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(OunjePalette.accentDark)
                        .frame(width: 38, height: 38)

                    Image(systemName: "plus")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(.white)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("Add to Ounje")
                        .font(.system(size: 16, weight: .black, design: .rounded))
                        .foregroundStyle(OunjePalette.primaryText)
                    Text("Import a link, photo, or idea")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(OunjePalette.secondaryText)
                }

                Spacer()

                Image(systemName: "sparkles")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(OunjePalette.softCream)
            }
            .padding(.horizontal, 18)
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
        .buttonStyle(.plain)
    }
}

private struct DiscoverComposerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draftText = ""

    private let suggestionChips = [
        "Dinner ideas",
        "Meal-prep lunch",
        "High protein",
        "Nigerian recipes",
        "Budget dinners",
        "Comfort food"
    ]

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

                ZStack(alignment: .topTrailing) {
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .fill(OunjePalette.panel)
                        .overlay(
                            RoundedRectangle(cornerRadius: 28, style: .continuous)
                                .stroke(OunjePalette.stroke, lineWidth: 1)
                        )

                    Circle()
                        .fill(OunjePalette.accent.opacity(0.14))
                        .frame(width: 120, height: 120)
                        .blur(radius: 26)
                        .offset(x: 18, y: -8)

                    VStack(alignment: .leading, spacing: 18) {
                        TextEditor(text: $draftText)
                            .scrollContentBackground(.hidden)
                            .foregroundStyle(OunjePalette.primaryText)
                            .font(.system(size: 16, weight: .medium, design: .rounded))
                            .frame(minHeight: 104)
                            .overlay(alignment: .topLeading) {
                                if draftText.isEmpty {
                                    Text("Import a recipe using a link, photo, video, or just describe what you want to make.")
                                        .font(.system(size: 16, weight: .medium, design: .rounded))
                                        .foregroundStyle(OunjePalette.secondaryText)
                                        .padding(.horizontal, 6)
                                        .padding(.top, 8)
                                }
                            }

                        VStack(alignment: .leading, spacing: 12) {
                            LazyVGrid(
                                columns: [
                                    GridItem(.flexible(), spacing: 10),
                                    GridItem(.flexible(), spacing: 10)
                                ],
                                spacing: 10
                            ) {
                                ComposerActionChip(title: "Attach file", systemImage: "plus")
                                ComposerActionChip(title: "Import links", systemImage: "link")
                                ComposerActionChip(title: "Recipe photos", systemImage: "photo")
                            }

                            Button {
                                dismiss()
                            } label: {
                                HStack(spacing: 8) {
                                    Text("Surprise me")
                                        .font(.system(size: 15, weight: .bold, design: .rounded))
                                    Image(systemName: "sparkles")
                                        .font(.system(size: 13, weight: .bold))
                                    Spacer(minLength: 0)
                                }
                                .foregroundStyle(.black.opacity(0.9))
                                .padding(.horizontal, 18)
                                .padding(.vertical, 14)
                                .frame(maxWidth: .infinity)
                                .background(
                                    Capsule(style: .continuous)
                                        .fill(OunjePalette.softCream)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(18)
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("Try prompts")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(OunjePalette.secondaryText)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(suggestionChips, id: \.self) { chip in
                                Text(chip)
                                    .font(.system(size: 14, weight: .medium, design: .rounded))
                                    .foregroundStyle(OunjePalette.primaryText)
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 12)
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
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 18)
            .padding(.top, 14)
            .padding(.bottom, 24)
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
    @Environment(\.openURL) private var openURL
    @EnvironmentObject private var savedStore: SavedRecipesStore
    private let cardHeight: CGFloat = 292

    var body: some View {
        Button {
            guard let url = recipe.destinationURL else { return }
            openURL(url)
        } label: {
            VStack(alignment: .leading, spacing: 14) {
                DiscoverRemoteRecipeImage(recipe: recipe)
                    .frame(maxWidth: .infinity)
                    .frame(height: 188)
                    .clipped()

                VStack(alignment: .leading, spacing: 8) {
                    Text(recipe.title)
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(OunjePalette.primaryText)
                        .lineLimit(2)
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
                .padding(8)
            }
            .shadow(color: .black.opacity(0.16), radius: 12, x: 0, y: 8)
        }
        .buttonStyle(.plain)
    }
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
                .font(.system(size: 13, weight: .black, design: .rounded))
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
                .font(.system(size: 12, weight: .black, design: .rounded))
                .tracking(1.2)
                .foregroundStyle(OunjePalette.accent)

            Text(title)
                .font(.system(size: 31, weight: .black, design: .rounded))
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
                .font(.system(size: 11, weight: .black, design: .rounded))
                .tracking(1)
                .foregroundStyle(OunjePalette.softCream.opacity(0.72))
            Text(title)
                .font(.system(size: 18, weight: .black, design: .rounded))
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
                        .font(.system(size: 24, weight: .black, design: .rounded))
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
                .font(.system(size: 10, weight: .black, design: .rounded))
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
                        .font(.system(size: 34, weight: .black, design: .rounded))
                        .foregroundStyle(OunjePalette.primaryText)
                    Text(selection.title)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(OunjePalette.secondaryText)
                }

                Spacer(minLength: 0)

                Text(modeLabel)
                    .font(.system(size: 11, weight: .black, design: .rounded))
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
                            .font(.system(size: 20, weight: .bold, design: .rounded))
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
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.white)
                Text(detail)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(OunjePalette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            ZStack(alignment: .topTrailing) {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                OunjePalette.panel,
                                OunjePalette.surface.opacity(0.96)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .stroke(OunjePalette.stroke, lineWidth: 1)
                    )

                Circle()
                    .fill(OunjePalette.accent.opacity(0.1))
                    .frame(width: 92, height: 92)
                    .blur(radius: 18)
                    .offset(x: 18, y: -18)
            }
        )
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
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Agent-guided step")
                    .font(.system(size: 12, weight: .black))
                    .foregroundStyle(.black.opacity(0.82))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.white.opacity(0.9), in: Capsule())

                Spacer()

                Text(step.title)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white.opacity(0.82))
            }

            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    Circle()
                        .stroke(tint.opacity(0.3), lineWidth: 1)
                        .frame(width: 58, height: 58)
                        .scaleEffect(isAnimating ? 1.1 : 0.92)
                        .opacity(isAnimating ? 0.35 : 0.85)

                    Circle()
                        .fill(tint.opacity(0.18))
                        .frame(width: 48, height: 48)

                    Image(systemName: step.symbolName)
                        .font(.system(size: 19, weight: .black))
                        .foregroundStyle(tint)
                        .rotationEffect(.degrees(isAnimating ? 6 : -6))
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text(step.prompt)
                        .font(.system(size: 20, weight: .black, design: .rounded))
                        .foregroundStyle(.white)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(step.subtitle)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.68))
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 6) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(tint)
                        Text("Tap what feels like you. Ounje adapts the next steps in real time.")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.76))
                            .lineLimit(2)
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            ZStack(alignment: .topTrailing) {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
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
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .stroke(OunjePalette.stroke, lineWidth: 1)
                    )

                Circle()
                    .fill(tint.opacity(0.16))
                    .frame(width: 130, height: 130)
                    .blur(radius: 28)
                    .offset(x: 30, y: -24)
            }
        )
        .onAppear {
            withAnimation(.easeInOut(duration: 3.2).repeatForever(autoreverses: true)) {
                isAnimating = true
            }
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
                        .font(.system(size: 12, weight: .black, design: .rounded))
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
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(OunjePalette.elevated)
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
                    .font(.system(size: 12, weight: .black, design: .rounded))
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
                        .font(.system(size: 30, weight: .black, design: .rounded))
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
            return URL(string: "http://127.0.0.1:8080/agent-brief")!
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
                    .font(.system(size: 20, weight: .black, design: .rounded))
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
            displayName: displayName
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
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published var selectedFilter = "All"

    private var hasLoaded = false

    func loadIfNeeded() async {
        guard !hasLoaded else { return }
        hasLoaded = true
        await refresh()
    }

    func refresh() async {
        isLoading = true
        defer { isLoading = false }

        do {
            recipes = try await SupabaseDiscoverRecipeService.shared.fetchRecipes()
            errorMessage = nil
            if !availableFilters.contains(selectedFilter) {
                selectedFilter = "All"
            }
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "We couldn’t load the live recipe feed."
        }
    }

    private var availableFilters: Set<String> {
        Set(recipes.compactMap(\.filterChipLabel))
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
        guard let cookTimeText, !cookTimeText.isEmpty else { return nil }
        return cookTimeText
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
}

private struct SupabaseTokenResponse: Codable {
    let user: SupabaseAuthUser
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

private enum OunjeLayout {
    static let screenHorizontalPadding: CGFloat = 16
    static let authButtonHeight: CGFloat = 52
    static let tabBarHeight: CGFloat = 54
    static let setupActionBarReservedHeight: CGFloat = 112
    static let welcomeActionBarHeight: CGFloat = 182
}

private enum OunjePalette {
    static let background = Color(hex: "121212")
    static let panel = Color(hex: "1E1E1E")
    static let surface = Color(hex: "2E2E2E")
    static let elevated = Color(hex: "383838")
    static let navBar = Color(hex: "282C35")
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
