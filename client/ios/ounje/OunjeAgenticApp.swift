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

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.03, green: 0.05, blue: 0.08),
                    Color(red: 0.06, green: 0.11, blue: 0.10),
                    OunjePalette.background
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            RadialGradient(
                colors: [
                    OunjePalette.accent.opacity(0.18),
                    .clear
                ],
                center: .bottomTrailing,
                startRadius: 10,
                endRadius: 360
            )
            .ignoresSafeArea()

            GeometryReader { proxy in
                let authButtonWidth = min(320, proxy.size.width - 56)

                VStack(alignment: .leading, spacing: 24) {
                    Spacer(minLength: max(60, proxy.safeAreaInsets.top + 40))

                    VStack(alignment: .leading, spacing: 12) {
                        Text("Ounje")
                            .font(.system(size: 13, weight: .black, design: .rounded))
                            .tracking(1.8)
                            .foregroundStyle(OunjePalette.accent)

                        Text("Meal prep that learns your taste, builds the cart, and gets the groceries moving.")
                            .font(.system(size: 34, weight: .black, design: .rounded))
                            .foregroundStyle(.white)
                            .fixedSize(horizontal: false, vertical: true)

                        Text("First sign-in goes into a guided setup. After that, your agent plans meals, prices the cart, and keeps delivery on cadence.")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(OunjePalette.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    AuthenticationPreviewDeck(isLifted: previewLift)

                    VStack(alignment: .leading, spacing: 18) {
                        if let authStatusMessage {
                            Text(authStatusMessage)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.92))
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
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .fill(OunjePalette.panel)
                            .overlay(
                                RoundedRectangle(cornerRadius: 24, style: .continuous)
                                    .stroke(OunjePalette.stroke, lineWidth: 1)
                            )
                    )

                    Spacer()
                }
                .padding(.horizontal, OunjeLayout.screenHorizontalPadding)
                .padding(.bottom, max(24, proxy.safeAreaInsets.bottom + 16))
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
                userID: UUID().uuidString.lowercased(),
                email: nil,
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
            let onboarded = try await SupabaseProfileStateService.shared.fetchOrCreateOnboardingState(
                userID: session.userID,
                email: session.email,
                displayName: session.displayName
            )

            store.signIn(with: session, onboarded: onboarded)
            authStatusMessage = onboarded
                ? "Signed in with \(session.provider.title)."
                : "Signed in. Let's finish setup."
        } catch {
            store.signIn(with: session, onboarded: false)
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
}

private struct FirstLoginOnboardingView: View {
    @EnvironmentObject private var store: MealPlanningAppStore

    @State private var currentStep: SetupStep = .identity
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
    @State private var adults = UserProfile.starter.consumption.adults
    @State private var kids = UserProfile.starter.consumption.kids
    @State private var cooksForOthers = UserProfile.starter.cooksForOthers
    @State private var mealsPerWeek = UserProfile.starter.consumption.mealsPerWeek
    @State private var includeLeftovers = UserProfile.starter.consumption.includeLeftovers
    @State private var budgetPerCycle = UserProfile.starter.budgetPerCycle
    @State private var budgetWindow = UserProfile.starter.budgetWindow
    @State private var budgetFlexibility = UserProfile.starter.budgetFlexibility
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
    @State private var presetSelectionPulseTask: Task<Void, Never>?

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
        CuisinePreference.allCases.filter {
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

                            onboardingProgressHeader
                            OnboardingPromptCard(step: currentStep)

                            Group {
                                switch currentStep {
                                case .identity:
                                    identityStepContent
                                case .cuisines:
                                    cuisineStepContent
                                case .taste:
                                    tasteStepContent
                                case .household:
                                    householdStepContent
                                case .kitchenBudget:
                                    kitchenBudgetStepContent
                                case .ordering:
                                    orderingStepContent
                                case .summary:
                                    summaryStepContent
                                }
                            }
                        }
                        .id(currentStep)
                        .padding(.horizontal, OunjeLayout.screenHorizontalPadding)
                        .padding(.top, max(18, proxy.safeAreaInsets.top + 10))
                        .padding(.bottom, 120 + proxy.safeAreaInsets.bottom)
                    }
                    .scrollIndicators(.hidden)
                    .onChange(of: currentStep) { _ in
                        withAnimation(.easeInOut(duration: 0.22)) {
                            scrollProxy.scrollTo(onboardingTopAnchorID, anchor: .top)
                        }
                        schedulePresetSelectionPulse()
                    }
                    .safeAreaInset(edge: .bottom) {
                        HStack(spacing: 10) {
                            if currentStep != .identity {
                                Button("Back") {
                                    withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
                                        currentStep = currentStep.previous ?? .identity
                                    }
                                }
                                .buttonStyle(SecondaryPillButtonStyle())
                            }

                            Button {
                                advance()
                            } label: {
                                HStack {
                                    if isSaving && currentStep == .summary {
                                        ProgressView().tint(.black)
                                    }
                                    Text(primaryActionTitle)
                                        .font(.system(size: 16, weight: .bold))
                                }
                                .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(PrimaryPillButtonStyle())
                            .disabled(!canAdvanceCurrentStep || isSaving)
                        }
                        .padding(.horizontal, OunjeLayout.screenHorizontalPadding)
                        .padding(.top, 10)
                        .padding(.bottom, max(12, proxy.safeAreaInsets.bottom + 8))
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
            if orderingAutonomy == .suggestOnly {
                orderingAutonomy = .autoOrderWithinBudget
            }
            schedulePresetSelectionPulse()
        }
        .onDisappear {
            presetSelectionPulseTask?.cancel()
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

    private var onboardingProgressHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Build your prep profile")
                    .font(.system(size: 24, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
                Spacer()
                Text("\(currentStep.index + 1)/\(SetupStep.allCases.count)")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(OunjePalette.secondaryText)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(OunjePalette.elevated, in: Capsule())
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
                    animationTrigger: presetSelectionPulseID
                ) { $0.title }
            }

            OnboardingSectionCard(
                title: "Cuisine by country",
                detail: "Search a country when the taste signal is broader than one cuisine label."
            ) {
                Text("Search any country and use it as a cuisine signal for sourcing.")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(OunjePalette.secondaryText)

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

    private var tasteStepContent: some View {
        VStack(spacing: 12) {
            OnboardingSectionCard(
                title: "Foods you enjoy",
                detail: favoriteFoodsDetail
            ) {
                AnimatedSelectionBubbleGrid(
                    options: favoriteFoodOptions,
                    selection: $selectedFavoriteFoods,
                    animationTrigger: presetSelectionPulseID
                )
                TextField("Anything else you love", text: $extraFavoriteFoodsText, axis: .vertical)
                    .lineLimit(1...3)
                    .modifier(OnboardingInputModifier())
            }

            OnboardingSectionCard(
                title: "Never include",
                detail: neverIncludeDetail
            ) {
                AnimatedSelectionBubbleGrid(
                    options: neverIncludeOptions,
                    selection: $selectedNeverIncludeFoods,
                    animationTrigger: presetSelectionPulseID
                )
                TextField("Anything else you never want", text: $neverIncludeText, axis: .vertical)
                    .lineLimit(1...3)
                    .modifier(OnboardingInputModifier())
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
                title: "Household context",
                detail: "Tell Ounje how many people these meals should feed."
            ) {
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

                Stepper("Planned meals per week: \(mealsPerWeek)", value: $mealsPerWeek, in: 3...21)
            }

            OnboardingSectionCard(
                title: "Prep cadence",
                detail: "This controls how often groceries are ordered and meals are refreshed."
            ) {
                Picker("Planning frequency", selection: $cadence) {
                    ForEach(MealCadence.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.menu)
            }
        }
    }

    private var kitchenBudgetStepContent: some View {
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

            OnboardingSectionCard(
                title: "Budget",
                detail: "Set the target spend the planner should work within."
            ) {
                Picker("Budget window", selection: $budgetWindow) {
                    ForEach(BudgetWindow.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                Text("Target: \(budgetPerCycle.asCurrency) \(budgetWindow == .weekly ? "per week" : "per month")")
                    .font(.system(size: 13, weight: .semibold))
                Slider(value: $budgetPerCycle, in: budgetRange, step: budgetStep)
                    .tint(OunjePalette.accent)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Budget flexibility")
                        .font(.system(size: 13, weight: .bold))
                    ForEach(BudgetFlexibility.allCases) { option in
                        SelectionCard(
                            title: option.title,
                            subtitle: option.subtitle,
                            isSelected: budgetFlexibility == option,
                            animationTrigger: presetSelectionPulseID,
                            animationIndex: BudgetFlexibility.allCases.firstIndex(of: option) ?? 0
                        ) {
                            budgetFlexibility = option
                        }
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
                detail: "Optional in onboarding. You can add it now or fill it in later inside the app."
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
                } else {
                    Text("Leave it blank for now. Ounje can collect the address later before any delivery step.")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(OunjePalette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var summaryStepContent: some View {
        VStack(spacing: 14) {
            AgentSummaryExperienceCard(profile: draftProfile)

            OnboardingSectionCard(
                title: "What the agent will run with",
                detail: "This is the operating brief the planner will use on first launch."
            ) {
                ForEach(draftProfile.structuredSummarySections) { section in
                    SummarySectionCard(section: section)
                }
            }
        }
    }

    private var canSubmit: Bool {
        !selectedDietaryPatterns.isEmpty &&
        (!selectedCuisines.isEmpty || !selectedCuisineCountries.isEmpty) &&
        !selectedGoals.isEmpty &&
        budgetPerCycle >= 25
    }

    private var canAdvanceCurrentStep: Bool {
        switch currentStep {
        case .identity:
            return !selectedDietaryPatterns.isEmpty
        case .cuisines:
            return !selectedCuisines.isEmpty || !selectedCuisineCountries.isEmpty
        case .taste:
            return true
        case .household:
            return !selectedGoals.isEmpty
        case .kitchenBudget:
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

    private var hasValidAddress: Bool {
        !addressLine1.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !city.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !region.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !postalCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var hasAnyAddress: Bool {
        !addressLine1.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
        !city.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
        !region.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
        !postalCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var addressButtonTitle: String {
        hasValidAddress ? "Update home address" : "Set home address"
    }

    private var addressButtonSubtitle: String {
        if hasValidAddress {
            return "\(addressLine1), \(city), \(region) \(postalCode)"
        }
        return "Add a delivery address now, or skip this and fill it in later."
    }

    private func advance() {
        if currentStep == .summary {
            submit()
            return
        }

        guard canAdvanceCurrentStep, let next = currentStep.next else { return }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
            currentStep = next
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

    private var favoriteFoodsDetail: String {
        if !selectedCuisines.isEmpty || !selectedCuisineCountries.isEmpty {
            return "Suggestions are adapting to your cuisine picks so the agent gets sharper signals."
        }
        return "These are strong positive signals for meal selection."
    }

    private var neverIncludeDetail: String {
        if !selectedDietaryPatterns.isEmpty || !selectedCuisines.isEmpty {
            return "These opt-outs update with your food rules and cuisine focus."
        }
        return "Negative signals help the agent avoid meals that feel off."
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
            .prefix(24)
            .map { $0 }
    }

    private var draftProfile: UserProfile {
        UserProfile(
            preferredCuisines: Array(selectedCuisines).sorted { $0.title < $1.title },
            cadence: cadence,
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
            budgetFlexibility: budgetFlexibility,
            purchasingBehavior: purchasingBehavior,
            orderingAutonomy: orderingAutonomy
        )
    }

    private func submit() {
        guard canSubmit else { return }
        isSaving = true

        store.completeOnboarding(with: draftProfile)

        if let session = store.authSession {
            Task {
                try? await SupabaseProfileStateService.shared.upsertOnboardingState(
                    userID: session.userID,
                    email: session.email,
                    displayName: session.displayName,
                    onboarded: true
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
        case identity
        case cuisines
        case taste
        case household
        case kitchenBudget
        case ordering
        case summary

        var index: Int { rawValue }

        var title: String {
            switch self {
            case .identity:
                return "Dietary rules"
            case .cuisines:
                return "Cuisine focus"
            case .taste:
                return "Taste profile"
            case .household:
                return "Household and cadence"
            case .kitchenBudget:
                return "Kitchen and budget"
            case .ordering:
                return "Ordering setup"
            case .summary:
                return "Review the agent brief"
            }
        }

        var subtitle: String {
            switch self {
            case .identity:
                return "Set the hard rules the planner can never break."
            case .cuisines:
                return "Choose the cuisines you want more often, then add country-level signals."
            case .taste:
                return "Tell the system what should show up more, and what should never appear."
            case .household:
                return "Define who this feeds and what the planner should optimize for."
            case .kitchenBudget:
                return "Make sure recipes fit the tools available and the spend target."
            case .ordering:
                return "Set the autonomy level now, and optionally save a home address for later."
            case .summary:
                return "Final check before first-run onboarding is marked complete."
            }
        }

        var prompt: String {
            switch self {
            case .identity:
                return "What food rules should I lock in before I start planning?"
            case .cuisines:
                return "What cuisines should show up in this household more often?"
            case .taste:
                return "What should feel exciting to eat, and what should stay out?"
            case .household:
                return "Who am I cooking for, and what should I optimize around?"
            case .kitchenBudget:
                return "What tools and spend range do I need to stay inside?"
            case .ordering:
                return "How autonomous should I be, and do you want to save home base now?"
            case .summary:
                return "Before I go live, does this meal-prep brief look right?"
            }
        }

        var symbolName: String {
            switch self {
            case .identity:
                return "checklist"
            case .cuisines:
                return "globe.americas.fill"
            case .taste:
                return "fork.knife.circle.fill"
            case .household:
                return "person.2.fill"
            case .kitchenBudget:
                return "oven"
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
    }
}

private struct MealPlannerShellView: View {
    @EnvironmentObject private var store: MealPlanningAppStore
    @State private var selectedTab: AppTab = .dashboard

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .bottom) {
                tabContent
                    .padding(.bottom, OunjeLayout.tabBarHeight + proxy.safeAreaInsets.bottom + 12)

                CustomTabBar(selectedTab: $selectedTab)
                    .padding(.horizontal, 12)
                    .padding(.bottom, max(8, proxy.safeAreaInsets.bottom + 4))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(OunjePalette.background.ignoresSafeArea())
    }

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .dashboard:
            HomeTabView()
        case .plan:
            PlanWorkspaceView()
        case .profile:
            ProfileTabView()
        }
    }
}

private struct HomeTabView: View {
    @EnvironmentObject private var store: MealPlanningAppStore

    var body: some View {
        ZStack {
            Image("PlannerBackground")
                .resizable()
                .scaledToFill()
                .ignoresSafeArea()
            Color.black.opacity(0.58).ignoresSafeArea()

            GeometryReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Dashboard")
                            .font(.system(size: 30, weight: .black))
                            .foregroundStyle(.white)

                        if let profile = store.profile {
                            ThemedCard {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("Cadence: \(profile.cadence.title)")
                                        .font(.system(size: 16, weight: .bold))
                                    Text("Cuisines: \(profile.userFacingCuisineTitles.joined(separator: ", "))")
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(OunjePalette.secondaryText)
                                    Text("Budget target: \(profile.budgetSummary)")
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(OunjePalette.secondaryText)
                                    if !profile.mealPrepGoals.isEmpty {
                                        Text("Optimize for: \(profile.mealPrepGoals.joined(separator: ", "))")
                                            .font(.system(size: 13, weight: .medium))
                                            .foregroundStyle(OunjePalette.secondaryText)
                                    }
                                    if profile.deliveryAddress.isComplete {
                                        Text("Delivery: \(profile.deliveryAddress.city), \(profile.deliveryAddress.region)")
                                            .font(.system(size: 13, weight: .medium))
                                            .foregroundStyle(OunjePalette.secondaryText)
                                    }
                                    if let next = store.nextRunDate {
                                        Text("Next cycle target: \(next.formatted(date: .abbreviated, time: .omitted))")
                                            .font(.system(size: 13, weight: .medium))
                                    }
                                }
                            }
                        }

                        if let latestPlan = store.latestPlan {
                            ThemedCard {
                                VStack(alignment: .leading, spacing: 10) {
                                    Text("What happens now")
                                        .font(.system(size: 18, weight: .bold))
                                    dashboardFlowRow(
                                        title: "1. Recipes selected",
                                        detail: "\(latestPlan.recipes.count) meals were chosen to match your constraints and goals."
                                    )
                                    dashboardFlowRow(
                                        title: "2. Grocery cart prepared",
                                        detail: "\(latestPlan.groceryItems.count) ingredient lines were generated after pantry deduction."
                                    )
                                    if let best = latestPlan.bestQuote {
                                        dashboardFlowRow(
                                            title: "3. Best ordering path",
                                            detail: "\(best.provider.title) is currently leading at \(best.estimatedTotal.asCurrency)."
                                        )
                                    }
                                }
                            }
                        }

                        Button {
                            Task { await store.generatePlan() }
                        } label: {
                            HStack {
                                if store.isGenerating {
                                    ProgressView().tint(.black)
                                }
                                Text(store.isGenerating ? "Generating plan..." : "Run Planning Cycle")
                                    .font(.system(size: 16, weight: .bold))
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(PrimaryPillButtonStyle())
                        .disabled(store.isGenerating)
                        .accessibilityHint("Generate a new meal plan, recipes, and grocery options.")

                        if let plan = store.latestPlan {
                            ThemedCard {
                                VStack(alignment: .leading, spacing: 10) {
                                    Text("Latest Plan")
                                        .font(.system(size: 18, weight: .bold))
                                    Text("\(plan.recipes.count) recipes • \(plan.groceryItems.count) grocery lines")
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundStyle(OunjePalette.secondaryText)

                                    if let best = plan.bestQuote {
                                        HStack {
                                            Text("Best Provider")
                                            Spacer()
                                            Text("\(best.provider.title) • \(best.estimatedTotal.asCurrency)")
                                                .font(.system(size: 14, weight: .bold))
                                                .foregroundStyle(OunjePalette.accent)
                                        }
                                    }

                                    Divider().overlay(OunjePalette.stroke)

                                    ForEach(plan.pipeline.prefix(3)) { step in
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(step.stage.title)
                                                .font(.system(size: 12, weight: .bold))
                                            Text(step.summary)
                                                .font(.system(size: 12, weight: .medium))
                                                .foregroundStyle(OunjePalette.secondaryText)
                                        }
                                    }
                                }
                            }
                        } else if !store.isGenerating {
                            ThemedCard {
                                Text("Run your first planning cycle to generate recipes, groceries, and provider quotes.")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(OunjePalette.secondaryText)
                            }
                        }

                        if !store.planHistory.isEmpty {
                            Text("Recent Cycles")
                                .font(.system(size: 16, weight: .bold))
                                .padding(.top, 6)

                            ForEach(store.planHistory.prefix(5)) { plan in
                                ThemedCard {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(plan.generatedAt.formatted(date: .abbreviated, time: .omitted))
                                                .font(.system(size: 14, weight: .bold))
                                            Text("\(plan.recipes.count) recipes • \(plan.groceryItems.count) items")
                                                .font(.system(size: 12, weight: .medium))
                                                .foregroundStyle(OunjePalette.secondaryText)
                                        }
                                        Spacer()
                                        if let best = plan.bestQuote {
                                            TagPill(text: best.provider.title)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, OunjeLayout.screenHorizontalPadding)
                    .padding(.top, max(18, proxy.safeAreaInsets.top + 12))
                    .padding(.bottom, 12)
                }
                .scrollIndicators(.hidden)
            }
        }
    }

    @ViewBuilder
    private func dashboardFlowRow(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 13, weight: .bold))
            Text(detail)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(OunjePalette.secondaryText)
        }
    }
}

private struct PlanWorkspaceView: View {
    @EnvironmentObject private var store: MealPlanningAppStore

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Current Plan")
                        .font(.system(size: 28, weight: .black))
                        .foregroundStyle(.white)
                        .padding(.bottom, 4)

                    if let plan = store.latestPlan {
                        ThemedCard {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Cycle overview")
                                    .font(.system(size: 18, weight: .bold))

                                Text(plan.generatedAt.formatted(date: .complete, time: .shortened))
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(OunjePalette.secondaryText)

                                if let best = plan.bestQuote {
                                    HStack {
                                        Text("Preferred checkout")
                                            .font(.system(size: 13, weight: .bold))
                                        Spacer()
                                        Text("\(best.provider.title) • \(best.estimatedTotal.asCurrency)")
                                            .font(.system(size: 14, weight: .bold))
                                            .foregroundStyle(OunjePalette.accent)
                                    }
                                }

                                if !plan.pipeline.isEmpty {
                                    Divider().overlay(OunjePalette.stroke)
                                    ForEach(plan.pipeline.prefix(4)) { step in
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
                        }

                        if !plan.recipes.isEmpty {
                            Text("Recipes")
                                .font(.system(size: 16, weight: .bold))
                                .padding(.top, 6)
                        }

                        ForEach(plan.recipes) { planned in
                            ThemedCard {
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack {
                                        Text(planned.recipe.title)
                                            .font(.system(size: 18, weight: .bold))
                                        Spacer()
                                        if planned.carriedFromPreviousPlan {
                                            TagPill(text: "Repeat")
                                        }
                                    }

                                    Text("\(planned.recipe.cuisine.title) • \(planned.recipe.prepMinutes) min • \(planned.servings) servings")
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(OunjePalette.secondaryText)

                                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                                        ForEach(planned.recipe.tags.prefix(4), id: \.self) { tag in
                                            TagPill(text: tag.capitalized)
                                        }
                                    }
                                }
                            }
                        }

                        if !plan.providerQuotes.isEmpty {
                            Text("Provider options")
                                .font(.system(size: 16, weight: .bold))
                                .padding(.top, 4)
                        }

                        ForEach(plan.providerQuotes) { quote in
                            ThemedCard {
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack {
                                        Text(quote.provider.title)
                                            .font(.system(size: 16, weight: .bold))
                                        Spacer()
                                        if quote.id == plan.bestQuote?.id {
                                            TagPill(text: "Best")
                                        }
                                    }

                                    Text("Subtotal: \(quote.subtotal.asCurrency) • Delivery: \(quote.deliveryFee.asCurrency)")
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundStyle(OunjePalette.secondaryText)

                                    Text("Estimated total: \(quote.estimatedTotal.asCurrency)")
                                        .font(.system(size: 15, weight: .bold))

                                    if let profile = store.profile {
                                        let budgetDelta = quote.estimatedTotal - profile.budgetPerCycle
                                        let budgetText = budgetDelta <= 0
                                            ? "Within budget by \((-budgetDelta).asCurrency)"
                                            : "Over budget by \(budgetDelta.asCurrency)"
                                        Text(budgetText)
                                            .font(.system(size: 12, weight: .semibold))
                                            .foregroundStyle(budgetDelta <= 0 ? OunjePalette.accent : Color.orange)
                                    }

                                    if let profile = store.profile, profile.deliveryAddress.isComplete {
                                        Text("Deliver to: \(profile.deliveryAddress.city), \(profile.deliveryAddress.region) \(profile.deliveryAddress.postalCode)")
                                            .font(.system(size: 12, weight: .medium))
                                            .foregroundStyle(OunjePalette.secondaryText)
                                    }

                                    Link("Open cart", destination: quote.orderURL)
                                        .font(.system(size: 14, weight: .bold))
                                        .foregroundStyle(OunjePalette.linkText)
                                }
                            }
                        }

                        if !plan.groceryItems.isEmpty {
                            Text("Needed ingredients")
                                .font(.system(size: 16, weight: .bold))
                                .padding(.top, 4)
                        }

                        ForEach(plan.groceryItems) { item in
                            ThemedCard {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(item.name.capitalized)
                                            .font(.system(size: 15, weight: .bold))
                                        Text("\(item.amount.roundedString(1)) \(item.unit)")
                                            .font(.system(size: 12, weight: .medium))
                                            .foregroundStyle(OunjePalette.secondaryText)
                                    }
                                    Spacer()
                                    Text(item.estimatedPrice.asCurrency)
                                        .font(.system(size: 14, weight: .bold))
                                        .foregroundStyle(.white)
                                }
                            }
                        }
                    } else {
                        ThemedCard {
                            Text("Finish onboarding and run a planning cycle to populate your workspace.")
                            .foregroundStyle(OunjePalette.secondaryText)
                        }
                    }
                }
                .padding(.horizontal, OunjeLayout.screenHorizontalPadding)
                .padding(.top, max(18, proxy.safeAreaInsets.top + 12))
                .padding(.bottom, 12)
            }
            .scrollIndicators(.hidden)
        }
        .background(OunjePalette.background.ignoresSafeArea())
    }
}

private struct ProfileTabView: View {
    @EnvironmentObject private var store: MealPlanningAppStore

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Profile")
                        .font(.system(size: 28, weight: .black))
                        .foregroundStyle(.white)

                    if let authSession = store.authSession {
                        ThemedCard {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Account")
                                    .font(.system(size: 17, weight: .bold))
                                Text("Provider: \(authSession.provider.title)")
                                    .font(.system(size: 13, weight: .semibold))
                                Text("User ID: \(authSession.userID)")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(OunjePalette.secondaryText)
                                if let displayName = authSession.displayName {
                                    Text("Name: \(displayName)")
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundStyle(OunjePalette.secondaryText)
                                }
                                if let email = authSession.email {
                                    Text("Email: \(email)")
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundStyle(OunjePalette.secondaryText)
                                }
                            }
                        }
                    }

                    if let profile = store.profile {
                        ThemedCard {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Meal-prep profile")
                                    .font(.system(size: 17, weight: .bold))

                                ForEach(Array(profile.structuredSummarySections.enumerated()), id: \.offset) { index, section in
                                    if index > 0 {
                                        Divider().overlay(OunjePalette.stroke)
                                    }

                                    VStack(alignment: .leading, spacing: 6) {
                                        Text(section.title)
                                            .font(.system(size: 13, weight: .bold))
                                        Text(section.detail)
                                            .font(.system(size: 13, weight: .medium))
                                            .foregroundStyle(OunjePalette.secondaryText)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                            }
                        }
                    }

                    Button("Generate New Plan") {
                        Task { await store.generatePlan() }
                    }
                    .buttonStyle(PrimaryPillButtonStyle())
                    .accessibilityHint("Create a fresh plan based on your current profile.")

                    Button("Sign Out") {
                        store.signOutToWelcome()
                    }
                    .buttonStyle(DestructivePillButtonStyle())
                    .accessibilityHint("Sign out and return to the welcome screen.")
                }
                .padding(.horizontal, OunjeLayout.screenHorizontalPadding)
                .padding(.top, max(18, proxy.safeAreaInsets.top + 12))
                .padding(.bottom, 12)
            }
            .scrollIndicators(.hidden)
        }
        .background(OunjePalette.background.ignoresSafeArea())
    }
}

private enum AppTab: String, CaseIterable, Identifiable {
    case dashboard
    case plan
    case profile

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard: return "Dashboard"
        case .plan: return "Plan"
        case .profile: return "Profile"
        }
    }

    var symbol: String {
        switch self {
        case .dashboard: return "square.grid.2x2.fill"
        case .plan: return "fork.knife"
        case .profile: return "person.fill"
        }
    }
}

private struct CustomTabBar: View {
    @Binding var selectedTab: AppTab

    var body: some View {
        HStack(spacing: 0) {
            ForEach(AppTab.allCases) { tab in
                Button {
                    selectedTab = tab
                } label: {
                    VStack(spacing: 5) {
                        Image(systemName: tab.symbol)
                            .font(.system(size: 18, weight: .bold))
                        Text(tab.title)
                            .font(.system(size: 10, weight: .bold))
                    }
                    .foregroundStyle(selectedTab == tab ? OunjePalette.tabSelected : .white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                }
                .accessibilityLabel(tab.title)
                .accessibilityHint("Open the \(tab.title) tab")
            }
        }
        .frame(height: OunjeLayout.tabBarHeight)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(OunjePalette.navBar)
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(OunjePalette.stroke, lineWidth: 1)
                )
        )
    }
}

private struct ThemedCard<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .foregroundStyle(.white)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(OunjePalette.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(OunjePalette.stroke, lineWidth: 1)
                    )
            )
    }
}

private struct StatusBarShield: View {
    var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .overlay(
                        LinearGradient(
                            colors: [
                                OunjePalette.background.opacity(0.62),
                                OunjePalette.background.opacity(0.32),
                                .clear
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .mask(
                        LinearGradient(
                            colors: [
                                .black,
                                .black.opacity(0.96),
                                .clear
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(height: proxy.safeAreaInsets.top + 28)

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
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.9)
                Spacer(minLength: 4)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(isSelected ? OunjePalette.accent : .white.opacity(0.75))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isSelected ? OunjePalette.accent.opacity(0.2) : OunjePalette.elevated)
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
                        .foregroundColor(.white)
                    Text(subtitle)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(OunjePalette.secondaryText)
                }
                Spacer()
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(isSelected ? OunjePalette.accent : .white.opacity(0.75))
                    .scaleEffect(isSelected && isPresetPulsing ? 1.18 : 1)
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isSelected ? OunjePalette.accent.opacity(0.22) : OunjePalette.elevated)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(isSelected && isPresetPulsing ? OunjePalette.accent.opacity(0.52) : OunjePalette.stroke, lineWidth: 1)
            )
            .scaleEffect(isSelected && isPresetPulsing ? 1.02 : 1)
            .shadow(color: isSelected && isPresetPulsing ? OunjePalette.accent.opacity(0.2) : .clear, radius: 12, x: 0, y: 8)
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
                            title: "Set home address",
                            detail: "Optional for now. Add it here when you're ready, or come back later from the app."
                        ) {
                            TextField("Start typing your address", text: $autocomplete.query)
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
                        }

                        OnboardingSectionCard(
                            title: "Address details",
                            detail: "Only fill in what search didn’t catch."
                        ) {
                            TextField("Street address", text: $addressLine1)
                                .modifier(OnboardingInputModifier())
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
            if autocomplete.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !addressLine1.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                autocomplete.query = [addressLine1, city, region]
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .joined(separator: ", ")
            }
        }
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
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(OunjePalette.panel)
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(OunjePalette.stroke, lineWidth: 1)
                )
        )
    }
}

private struct OnboardingPromptCard: View {
    let step: FirstLoginOnboardingView.SetupStep

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(OunjePalette.accent.opacity(0.18))
                    .frame(width: 48, height: 48)

                Image(systemName: step.symbolName)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(OunjePalette.accent)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(step.prompt)
                    .font(.system(size: 22, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)

                Text(step.subtitle)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(OunjePalette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
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
        )
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
                .padding(.vertical, 8)
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
    let label: (Option) -> String

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 116), spacing: 8)], spacing: 8) {
            ForEach(Array(options.enumerated()), id: \.element.id) { index, option in
                AnimatedSelectionBubble(
                    title: label(option),
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

private struct AnimatedSelectionBubble: View {
    let title: String
    let isSelected: Bool
    var animationTrigger: Int = 0
    var animationIndex: Int = 0
    let action: () -> Void

    @State private var isPresetPulsing = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 13, weight: .bold))
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
                    .foregroundStyle(isSelected ? .black : .white)

                Spacer(minLength: 0)

                Image(systemName: isSelected ? "checkmark.circle.fill" : "plus.circle")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(isSelected ? .black.opacity(0.85) : OunjePalette.secondaryText)
                    .scaleEffect(isSelected && isPresetPulsing ? 1.2 : 1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isSelected ? OunjePalette.accent : OunjePalette.elevated)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(isSelected ? (isPresetPulsing ? OunjePalette.accent.opacity(0.54) : OunjePalette.accent.opacity(0.2)) : OunjePalette.stroke, lineWidth: 1)
            )
            .scaleEffect((isSelected ? 1.01 : 0.985) * (isPresetPulsing ? 1.03 : 1))
            .shadow(color: isSelected && isPresetPulsing ? OunjePalette.accent.opacity(0.24) : .clear, radius: 14, x: 0, y: 8)
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
                primary: Color(hex: "38F096"),
                secondary: Color(hex: "FF8A3D"),
                tertiary: Color(hex: "FFD166")
            )
        }

        if loweredDietaryPatterns.contains(where: { $0.contains("vegan") || $0.contains("vegetarian") || $0.contains("dairy-free") || $0.contains("gluten-free") }) {
            return AgentSummaryAesthetic(
                title: "Clean Grid",
                symbolName: "leaf.fill",
                primary: Color(hex: "38F096"),
                secondary: Color(hex: "7DFFCF"),
                tertiary: Color(hex: "C6FFE8")
            )
        }

        if loweredGoals.contains(where: { $0.contains("speed") || $0.contains("cleanup") || $0.contains("cost") }) {
            return AgentSummaryAesthetic(
                title: "Control Mode",
                symbolName: "bolt.fill",
                primary: Color(hex: "38F096"),
                secondary: Color(hex: "6AD6FF"),
                tertiary: Color(hex: "B2FFFF")
            )
        }

        if loweredCuisines.contains(where: { $0.contains("japanese") || $0.contains("chinese") || $0.contains("korean") }) {
            return AgentSummaryAesthetic(
                title: "Neon Pantry",
                symbolName: "moon.stars.fill",
                primary: Color(hex: "38F096"),
                secondary: Color(hex: "4EA8FF"),
                tertiary: Color(hex: "A6C8FF")
            )
        }

        return AgentSummaryAesthetic(
            title: "Ounje Core",
            symbolName: "sparkles",
            primary: Color(hex: "38F096"),
            secondary: Color(hex: "7CFFB2"),
            tertiary: Color(hex: "B2FFFF")
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

    private var aesthetic: AgentSummaryAesthetic {
        profile.agentSummaryAesthetic
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Agent readout")
                        .font(.system(size: 12, weight: .black))
                        .foregroundStyle(.black.opacity(0.78))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.white.opacity(0.9), in: Capsule())

                    Text(profile.profileHeadline)
                        .font(.system(size: 30, weight: .black, design: .rounded))
                        .foregroundStyle(.white)
                        .fixedSize(horizontal: false, vertical: true)
                        .shadow(color: .black.opacity(0.18), radius: 10, x: 0, y: 8)

                    Text(profile.profileNarrative)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white.opacity(0.78))
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 16)

                VStack(spacing: 8) {
                    Image(systemName: aesthetic.symbolName)
                        .font(.system(size: 18, weight: .black))
                        .foregroundStyle(.black.opacity(0.82))
                        .frame(width: 46, height: 46)
                        .background(.white.opacity(0.88), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .rotationEffect(.degrees(isAnimated ? 4 : -4))

                    Text(aesthetic.title)
                        .font(.system(size: 11, weight: .black))
                        .foregroundStyle(.white.opacity(0.86))
                        .multilineTextAlignment(.center)
                        .frame(width: 74)
                }
            }

            WrapFlow(items: profile.profileSignals) { signal in
                AgentSignalBadge(text: signal, tint: aesthetic.primary)
                    .scaleEffect(isAnimated ? 1 : 0.96)
                    .animation(.spring(response: 0.5, dampingFraction: 0.8).delay(Double(abs(signal.hashValue % 6)) * 0.03), value: isAnimated)
            }

            VStack(spacing: 10) {
                ForEach(Array(profile.profileReadinessNotes.enumerated()), id: \.offset) { index, note in
                    AgentReadoutRow(
                        note: note,
                        tint: index.isMultiple(of: 2) ? aesthetic.primary : aesthetic.secondary
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
                                aesthetic.primary.opacity(0.42),
                                aesthetic.secondary.opacity(0.2),
                                .clear
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                Circle()
                    .fill(aesthetic.primary.opacity(0.26))
                    .frame(width: 190, height: 190)
                    .blur(radius: 28)
                    .offset(x: isAnimated ? 110 : 70, y: isAnimated ? -90 : -40)

                Circle()
                    .fill(aesthetic.secondary.opacity(0.23))
                    .frame(width: 150, height: 150)
                    .blur(radius: 24)
                    .offset(x: isAnimated ? -90 : -50, y: isAnimated ? 120 : 80)

                Circle()
                    .fill(aesthetic.tertiary.opacity(0.18))
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
        .shadow(color: aesthetic.primary.opacity(0.12), radius: 20, x: 0, y: 12)
        .onAppear {
            withAnimation(.easeInOut(duration: 4.2).repeatForever(autoreverses: true)) {
                isAnimated = true
            }
        }
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
            .padding(.vertical, 8)
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
            .foregroundStyle(.black)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity)
            .background(OunjePalette.accent, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .opacity(configuration.isPressed ? 0.85 : 1)
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
            .foregroundStyle(.white)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity)
            .background(OunjePalette.elevated, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .opacity(configuration.isPressed ? 0.85 : 1)
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

private final class SupabaseProfileStateService {
    static let shared = SupabaseProfileStateService()

    private init() {}

    func fetchOrCreateOnboardingState(userID: String, email: String?, displayName: String?) async throws -> Bool {
        if let onboarded = try await fetchOnboardingState(userID: userID) {
            return onboarded
        }

        try await upsertOnboardingState(
            userID: userID,
            email: email,
            displayName: displayName,
            onboarded: false
        )
        return false
    }

    func upsertOnboardingState(userID: String, email: String?, displayName: String?, onboarded: Bool) async throws {
        guard let url = URL(string: "\(SupabaseConfig.url)/rest/v1/profiles?on_conflict=id") else {
            throw SupabaseProfileStateError.invalidRequest
        }

        let payload = SupabaseProfileUpsertPayload(
            id: userID,
            email: email,
            displayName: displayName,
            onboarded: onboarded
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

    private func fetchOnboardingState(userID: String) async throws -> Bool? {
        guard let encodedID = userID.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "\(SupabaseConfig.url)/rest/v1/profiles?select=onboarded&id=eq.\(encodedID)&limit=1") else {
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

        let rows = try JSONDecoder().decode([SupabaseProfileStateRow].self, from: data)
        guard let row = rows.first else { return nil }
        return row.onboarded ?? false
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

private struct SupabaseProfileStateRow: Codable {
    let onboarded: Bool?
}

private struct SupabaseProfileUpsertPayload: Codable {
    let id: String
    let email: String?
    let displayName: String?
    let onboarded: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case email
        case displayName = "display_name"
        case onboarded
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
    static let tabBarHeight: CGFloat = 64
    static let setupActionBarReservedHeight: CGFloat = 112
    static let welcomeActionBarHeight: CGFloat = 182
}

private enum OunjePalette {
    static let background = Color(hex: "121212")
    static let panel = Color(hex: "1E1E1E")
    static let surface = Color(hex: "2E2E2E")
    static let elevated = Color(hex: "383838")
    static let navBar = Color(hex: "282C35")
    static let accent = Color(hex: "38F096")
    static let tabSelected = Color(hex: "4CBB17")
    static let secondaryText = Color(hex: "8A8A8A")
    static let linkText = Color(hex: "B2FFFF")
    static let stroke = Color.white.opacity(0.08)
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
