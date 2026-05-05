import SwiftUI
import Foundation

struct FirstLoginOnboardingView: View {
    @EnvironmentObject private var store: MealPlanningAppStore
    @AppStorage("ounje.selectedPricingTier") private var selectedTierRawValue = "free"

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
    @State private var budgetInput = "\(Int(UserProfile.starter.budgetPerCycle.rounded()))"
    @State private var budgetWindow = UserProfile.starter.budgetWindow
    @State private var previousBudgetWindow = UserProfile.starter.budgetWindow
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
    @State private var isPaywallPresented = false
    @State private var paywallInitialTier: OunjePricingTier? = nil
    @StateObject private var onboardingProvidersViewModel = GroceryProvidersViewModel()
    @State private var selectedOnboardingProvider: GroceryProviderInfo?
    @State private var presetSelectionPulseID = 0
    @State private var identityStepAnchorBaseline: CGFloat?
    @State private var hasUnlockedIdentityCTA = false
    @State private var presetSelectionPulseTask: Task<Void, Never>?
    @State private var briefPrefetchTask: Task<Void, Never>?
    @State private var isNameIntroAnimated = false
    @State private var previousStep: SetupStep = .name
    @State private var stepTransitionDirection = 1
    @State private var hasHydratedStoredDraft = false
    @FocusState private var isNameFieldFocused: Bool
    @FocusState private var isBudgetFieldFocused: Bool

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

    private let commonAllergyOptions = [
        "Peanuts",
        "Tree nuts",
        "Shellfish",
        "Dairy",
        "Eggs",
        "Gluten",
        "Sesame",
        "Soy",
        "Fish",
        "Wheat",
        "Mustard",
        "Corn",
        "Coconut",
        "Strawberries",
        "Kiwi",
        "Avocado",
        "Banana",
        "Tomato",
        "Garlic",
        "Onion",
        "Lentils",
        "Chickpeas"
    ]

    private var allergyChipColumns: [GridItem] {
        [
            GridItem(.flexible(), spacing: 10),
            GridItem(.flexible(), spacing: 10),
            GridItem(.flexible(), spacing: 10)
        ]
    }

    private var cuisineChipColumns: [GridItem] {
        [
            GridItem(.flexible(minimum: 132), spacing: 10),
            GridItem(.flexible(minimum: 132), spacing: 10)
        ]
    }

    private var selectableCuisineOptions: [CuisinePreference] {
        let filtered = CuisinePreference.allCases.filter {
            $0 != .vegan
        }

        let preferredOrder: [CuisinePreference] = [
            .american,
            .mexican,
            .southern,
            .cajun,
            .caribbean,
            .brazilian,
            .italian,
            .french,
            .spanish,
            .portuguese,
            .mediterranean,
            .greek,
            .middleEastern,
            .turkish,
            .moroccan,
            .persian,
            .westAfrican,
            .ethiopian,
            .indian,
            .chinese,
            .japanese,
            .korean,
            .thai,
            .vietnamese,
            .filipino,
            .asian,
            .german,
            .british
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

    private var selectedPricingTier: OunjePricingTier {
        store.effectivePricingTier
    }

    private var paywallPresentationBinding: Binding<Bool> {
        Binding(
            get: { OunjeLaunchFlags.paywallsEnabled && isPaywallPresented },
            set: { isPaywallPresented = $0 }
        )
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
            onboardingLessonBackground

            if currentStep == .name {
                nameOnlyOnboardingScreen
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            } else {
                VStack(spacing: 0) {
                    onboardingLessonHeader

                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(alignment: .leading, spacing: 16) {
                                if currentStep != .identity && currentStep != .cuisines && currentStep != .household && currentStep != .kitchen && currentStep != .budget && currentStep != .ordering && currentStep != .address {
                                    OnboardingCoachPanel(
                                        step: currentStep,
                                        accent: currentStepAccent,
                                        secondaryAccent: currentStepSecondaryAccent,
                                        preferredName: preferredName
                                    )
                                    .padding(.top, 4)
                                }

                                currentStepContent
                                    .transition(stepTransition)
                            }
                            .id(currentStep)
                            .padding(.horizontal, OunjeLayout.screenHorizontalPadding)
                            .padding(.top, 8)
                            .padding(.bottom, 18)
                        }
                        .scrollIndicators(.hidden)
                        .onChange(of: currentStep) { step in
                            withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) {
                                proxy.scrollTo(step, anchor: .top)
                            }
                        }
                    }

                    onboardingLessonFooter
                }
            }
        }
        .tint(currentStepAccent)
        .preferredColorScheme(.dark)
        .onChange(of: currentStep) { newStep in
            previousStep = newStep.previous ?? .name
            schedulePresetSelectionPulse()
            persistDraft(step: newStep)
        }
        .onChange(of: budgetWindow) { newValue in
            guard previousBudgetWindow != newValue else { return }
            convertBudgetPerCycle(from: previousBudgetWindow, to: newValue)
            previousBudgetWindow = newValue
        }
        .onChange(of: budgetPerCycle) { _ in
            guard !isBudgetFieldFocused else { return }
            syncBudgetInput()
        }
        .onChange(of: isBudgetFieldFocused) { isFocused in
            if !isFocused {
                commitBudgetInput()
            }
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
            if !store.isOnboarded,
               OunjePricingTier(rawValue: selectedTierRawValue) == nil {
                selectedTierRawValue = UserProfile.starter.pricingTier.rawValue
            }
            if orderingAutonomy == .suggestOnly {
                orderingAutonomy = .autoOrderWithinBudget
            }
            withAnimation(.easeInOut(duration: 3.6).repeatForever(autoreverses: true)) {
                isNameIntroAnimated = true
            }
            loadOnboardingProviders()
            schedulePresetSelectionPulse()
        }
        .onDisappear {
            presetSelectionPulseTask?.cancel()
            briefPrefetchTask?.cancel()
            persistDraftLocally()
        }
        .sheet(isPresented: $isAddressSheetPresented) {
            AddressSetupSheet(
                title: "Address details",
                detail: "Start with street address. Picking a suggestion will fill the rest.",
                primaryButtonTitle: "Save address",
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
        .sheet(item: $selectedOnboardingProvider) { provider in
            GroceryProviderConnectSheet(
                provider: provider,
                userId: store.resolvedTrackingSession?.userID ?? store.authSession?.userID ?? "",
                accessToken: store.resolvedTrackingSession?.accessToken ?? store.authSession?.accessToken,
                onConnected: {
                    loadOnboardingProviders()
                    selectedOnboardingProvider = nil
                }
            )
        }
        .fullScreenCover(isPresented: paywallPresentationBinding) {
            OunjePlusPaywallSheet(initialTier: paywallInitialTier)
        }
    }

    private var onboardingLessonBackground: some View {
        ZStack {
            OunjePalette.background
                .ignoresSafeArea()
        }
    }

    private var onboardingLessonHeader: some View {
        HStack(spacing: 12) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule(style: .continuous)
                        .fill(Color.white.opacity(0.08))

                    Capsule(style: .continuous)
                        .fill(Color(hex: "63D471"))
                        .frame(width: max(8, proxy.size.width * lessonProgress))
                        .animation(.spring(response: 0.34, dampingFraction: 0.86), value: lessonProgress)
                }
            }
            .frame(height: 4)

            Text("\(currentStep.index + 1)/\(SetupStep.allCases.count)")
                .font(.custom("Slee_handwritting-Regular", size: 17))
                .foregroundStyle(OunjePalette.secondaryText)
                .monospacedDigit()
        }
        .padding(.horizontal, OunjeLayout.screenHorizontalPadding)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(
            OunjePalette.background
                .ignoresSafeArea(edges: .top)
        )
    }

    private var onboardingLessonFooter: some View {
        HStack(spacing: 10) {
            if let previousStep = currentStep.previous {
                Button {
                    stepTransitionDirection = -1
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                        currentStep = previousStep
                    }
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(OunjePalette.primaryText)
                        .frame(width: 54, height: 54)
                        .background(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(OunjePalette.panel)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                                        .stroke(OunjePalette.stroke, lineWidth: 1)
                                )
                        )
                }
                .buttonStyle(.plain)
            }

            Button {
                advance()
            } label: {
                HStack(spacing: 8) {
                    if isSaving && currentStep.next == nil {
                        ProgressView().tint(.black)
                    }
                    Text(currentStep.next == nil ? "Start Ounje" : "Continue")
                        .font(.custom("Slee_handwritting-Regular", size: 22))
                    if currentStep.next != nil {
                        Image(systemName: "arrow.right")
                            .font(.system(size: 14, weight: .bold))
                    }
                }
                .foregroundStyle(.black)
                .frame(maxWidth: .infinity)
                .frame(height: 54)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(currentStepAccent)
                        .shadow(color: currentStepAccent.opacity(0.12), radius: 8, x: 0, y: 4)
                )
            }
            .buttonStyle(.plain)
            .disabled(!canAdvanceCurrentStep || isSaving)
            .opacity((!canAdvanceCurrentStep || isSaving) ? 0.62 : 1)
        }
        .padding(.horizontal, OunjeLayout.screenHorizontalPadding)
        .padding(.top, 10)
        .padding(.bottom, 10)
        .background(
            OunjePalette.background
                .ignoresSafeArea(edges: .bottom)
        )
    }

    private var lessonProgress: CGFloat {
        CGFloat(currentStep.index + 1) / CGFloat(max(1, SetupStep.allCases.count))
    }

    private var stepTransition: AnyTransition {
        let insertionEdge: Edge = stepTransitionDirection >= 0 ? .trailing : .leading
        let removalEdge: Edge = stepTransitionDirection >= 0 ? .leading : .trailing
        return .asymmetric(
            insertion: .push(from: insertionEdge).combined(with: .opacity),
            removal: .push(from: removalEdge).combined(with: .opacity)
        )
    }

    private var currentStepAccent: Color {
        Color(hex: "63D471")
    }

    private var currentStepSecondaryAccent: Color {
        Color(hex: "0F6E42")
    }

    private var nameOnlyOnboardingScreen: some View {
        GeometryReader { proxy in
            let nameWidth = min(proxy.size.width * 0.84, 372)
            let habitatHeight = min(max(proxy.size.height * 0.40, 292), 360)
            let nameTopOffset = habitatHeight + 52

            ZStack(alignment: .top) {
                OunjePalette.background
                    .ignoresSafeArea()

                TurtleOnboardingScene(
                    prompt: "What should I call you?",
                    mode: .name
                )
                    .frame(
                        width: proxy.size.width,
                        height: habitatHeight + proxy.safeAreaInsets.top
                    )
                    .ignoresSafeArea(.container, edges: .top)
                    .allowsHitTesting(false)

                VStack(spacing: 0) {
                    Spacer()
                        .frame(height: nameTopOffset)

                    nameEntryBar
                        .frame(width: nameWidth)

                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .ignoresSafeArea(.container, edges: .top)
        .ignoresSafeArea(.keyboard, edges: .bottom)
    }

    private var nameEntryBar: some View {
        TextField(
            "",
            text: $preferredName
        )
        .textInputAutocapitalization(.words)
        .autocorrectionDisabled()
        .submitLabel(.next)
        .font(.custom("Slee_handwritting-Regular", size: 38))
        .fontWeight(.bold)
        .foregroundStyle(OunjePalette.primaryText)
        .tint(Color(hex: "C9CDC6"))
        .focused($isNameFieldFocused)
        .padding(.bottom, 7)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color(hex: "C9CDC6").opacity(isNameFieldFocused ? 0.95 : 0.62))
                .frame(height: isNameFieldFocused ? 2 : 1)
                .animation(.easeOut(duration: 0.18), value: isNameFieldFocused)
        }
        .overlay(alignment: .leading) {
            if preferredName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                NameLineCursor(color: Color(hex: "C9CDC6"))
                    .opacity(isNameFieldFocused ? 1 : 0)
                    .padding(.bottom, 15)
                    .allowsHitTesting(false)
            }
        }
        .onSubmit {
            guard canAdvanceCurrentStep else { return }
            advance()
        }
        .task {
            try? await Task.sleep(nanoseconds: 260_000_000)
            isNameFieldFocused = true
        }
        .frame(height: 58)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onTapGesture {
            isNameFieldFocused = true
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
        case .address:
            addressStepContent
        }
    }

    private var nameStepContent: some View {
        VStack(spacing: 14) {
            OnboardingLessonCard(
                eyebrow: "Start here",
                title: "What should Ounje call you?",
                detail: "This names the prep plan, cart updates, and nudges Ounje sends you.",
                accent: currentStepAccent
            ) {
                TextField("First name", text: $preferredName)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .modifier(OnboardingLightInputModifier())

                HStack(spacing: 8) {
                    OnboardingPromiseChip(title: "Taste", symbol: "sparkles", accent: currentStepAccent)
                    OnboardingPromiseChip(title: "Prep", symbol: "calendar", accent: currentStepAccent)
                    OnboardingPromiseChip(title: "Cart", symbol: "cart", accent: currentStepAccent)
                }
            }
        }
    }

    private var identityStepContent: some View {
        VStack(alignment: .leading, spacing: 24) {
            OnboardingStepHeader(
                title: "Allergies?",
                subtitle: "Tell Ounje what never goes in.",
                turtlePlacement: .leading
            )

            OnboardingLineEntry(
                placeholder: "Peanuts, shellfish, sesame...",
                text: $allergiesText
            )

            LazyVGrid(columns: allergyChipColumns, spacing: 10) {
                ForEach(commonAllergyOptions, id: \.self) { option in
                    OnboardingAllergyPill(
                        title: option,
                        isSelected: allergyListContains(option),
                        accent: currentStepAccent
                    ) {
                        toggleAllergy(option)
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 18)
    }

    private var cuisineStepContent: some View {
        VStack(alignment: .leading, spacing: 24) {
            OnboardingStepHeader(
                title: "Cuisines",
                subtitle: "Pick the flavors Ounje should reach for first.",
                turtlePlacement: .trailing
            )

            OnboardingCuisineSelectionLine(
                placeholder: "Italian, West African, Japanese...",
                selectedText: selectedCuisineSummaryText
            )

            LazyVGrid(columns: cuisineChipColumns, spacing: 10) {
                ForEach(selectableCuisineOptions, id: \.self) { option in
                    OnboardingCuisinePill(
                        title: option.title,
                        flagCode: option.flagCode,
                        badgeText: option.badgeText,
                        badgeHex: option.badgeHex,
                        isSelected: selectedCuisines.contains(option),
                        accent: currentStepAccent
                    ) {
                        toggleCuisine(option)
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 18)
    }

    private var householdStepContent: some View {
        VStack(alignment: .leading, spacing: 24) {
            OnboardingStepHeader(
                title: "Rhythm",
                subtitle: "Set your prep tempo.",
                turtlePlacement: .trailing
            )

            VStack(alignment: .leading, spacing: 14) {
                Text("Delivery frequency")
                    .font(.system(size: 12, weight: .black))
                    .foregroundStyle(OunjePalette.secondaryText)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .bottom, spacing: 22) {
                        ForEach(cadenceDisplayOrder) { option in
                            Button {
                                withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
                                    cadence = option
                                }
                            } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(option.title)
                                        .font(.custom("Slee_handwritting-Regular", size: 22))
                                        .foregroundStyle(cadence == option ? OunjePalette.primaryText : OunjePalette.primaryText.opacity(0.62))

                                    Text(cadenceSubtitle(for: option))
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundStyle(cadence == option ? currentStepAccent : OunjePalette.secondaryText)

                                    Capsule(style: .continuous)
                                        .fill(cadence == option ? currentStepAccent : Color.white.opacity(0.08))
                                        .frame(width: cadence == option ? 38 : 18, height: 3)
                                }
                                .frame(width: 146, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }

            if cadence != .daily {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Prime day")
                        .font(.system(size: 12, weight: .black))
                        .foregroundStyle(OunjePalette.secondaryText)

                    HStack(spacing: 9) {
                        ForEach(DeliveryAnchorDay.allCases) { day in
                            Button {
                                withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
                                    deliveryAnchorDay = day
                                }
                            } label: {
                                Text(dayShortLabel(for: day))
                                    .font(.custom("Slee_handwritting-Regular", size: 18))
                                    .foregroundStyle(deliveryAnchorDay == day ? .black : OunjePalette.primaryText)
                                    .frame(width: 42, height: 42)
                                    .background(
                                        Circle()
                                            .fill(deliveryAnchorDay == day ? currentStepAccent : Color.white.opacity(0.06))
                                    )
                                .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Recipes per prep")
                        .font(.system(size: 12, weight: .black))
                        .foregroundStyle(OunjePalette.secondaryText)

                    Spacer(minLength: 0)

                    Text("\(mealsPerWeek)")
                        .font(.custom("Slee_handwritting-Regular", size: 34))
                        .foregroundStyle(currentStepAccent)
                }

                Slider(
                    value: Binding(
                        get: { Double(mealsPerWeek) },
                        set: { mealsPerWeek = Int($0.rounded()) }
                    ),
                    in: 1...10,
                    step: 1
                )
                .tint(currentStepAccent)

                HStack {
                    ForEach([1, 2, 4, 6, 8, 10], id: \.self) { tick in
                        Text("\(tick)")
                            .font(.custom("Slee_handwritting-Regular", size: 16))
                            .foregroundStyle(mealsPerWeek == tick ? currentStepAccent : OunjePalette.secondaryText.opacity(0.72))
                        if tick != 10 {
                            Spacer(minLength: 0)
                        }
                    }
                }

                Text(mealsPerWeekRhythmNote)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(OunjePalette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
    }

    private var kitchenStepContent: some View {
        VStack {
            Spacer()
                .frame(height: cooksForOthers ? 92 : 148)

            VStack(alignment: .leading, spacing: 24) {
                OnboardingStepHeader(
                    title: "How many mouths?",
                    subtitle: "Set the headcount.",
                    turtlePlacement: .none
                )

                HStack(spacing: 10) {
                    OnboardingBorderOptionCard(
                        title: "Just me",
                        subtitle: "Solo meal prep",
                        isSelected: !cooksForOthers,
                        accent: currentStepAccent,
                        titleFont: .custom("Slee_handwritting-Regular", size: 22),
                        subtitleFont: .custom("Slee_handwritting-Regular", size: 16)
                    ) {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
                            cooksForOthers = false
                        }
                    }

                    OnboardingBorderOptionCard(
                        title: "Me + others",
                        subtitle: "Cook for the table",
                        isSelected: cooksForOthers,
                        accent: currentStepAccent,
                        titleFont: .custom("Slee_handwritting-Regular", size: 22),
                        subtitleFont: .custom("Slee_handwritting-Regular", size: 16)
                    ) {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
                            cooksForOthers = true
                        }
                    }
                }

                if cooksForOthers {
                    HStack(spacing: 12) {
                        OnboardingWheelNumberCard(
                            title: "Adults",
                            selection: $adults,
                            values: Array(1...8),
                            accent: currentStepAccent
                        )

                        OnboardingWheelNumberCard(
                            title: "Kids",
                            selection: $kids,
                            values: Array(0...6),
                            accent: currentStepAccent
                        )
                    }
                }
            }

            Spacer(minLength: 0)
        }
    }

    private var budgetStepContent: some View {
        VStack(alignment: .leading, spacing: 24) {
            OnboardingStepHeader(
                title: "Grocery budget",
                subtitle: "Pick your spend lane.",
                turtlePlacement: .leading
            )

            VStack(alignment: .leading, spacing: 12) {
                Text("Budget window")
                    .font(.custom("Slee_handwritting-Regular", size: 20))
                    .foregroundStyle(OunjePalette.secondaryText)

                HStack(spacing: 10) {
                    ForEach(BudgetWindow.allCases) { option in
                        OnboardingBorderOptionCard(
                            title: option.title,
                            subtitle: option == .weekly ? "Faster feedback loop" : "Broader monthly lane",
                            isSelected: budgetWindow == option,
                            accent: currentStepAccent
                        ) {
                            withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
                                budgetWindow = option
                            }
                        }
                    }
                }
            }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Target")
                        .font(.custom("Slee_handwritting-Regular", size: 20))
                        .foregroundStyle(OunjePalette.secondaryText)

                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .lastTextBaseline, spacing: 8) {
                            Text("$")
                                .font(.custom("Slee_handwritting-Regular", size: 50))
                                .foregroundStyle(OunjePalette.primaryText)

                            TextField("", text: $budgetInput)
                                .keyboardType(.numberPad)
                                .submitLabel(.done)
                                .focused($isBudgetFieldFocused)
                                .font(.custom("Slee_handwritting-Regular", size: 50))
                                .foregroundStyle(OunjePalette.primaryText)
                                .onTapGesture {
                                    isBudgetFieldFocused = true
                                }
                                .onSubmit {
                                    commitBudgetInput()
                                    isBudgetFieldFocused = false
                                }
                                .frame(minWidth: 88)

                            Text(budgetWindow == .weekly ? "per week" : "per month")
                                .font(.custom("Slee_handwritting-Regular", size: 22))
                                .foregroundStyle(OunjePalette.secondaryText)
                        }

                    Text(translatedBudgetSummary)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(OunjePalette.secondaryText)
                }

                Slider(value: $budgetPerCycle, in: budgetRange, step: budgetStep)
                    .tint(currentStepAccent)

                HStack {
                    Text(budgetRange.lowerBound.asCurrency)
                    Spacer()
                    Text(budgetRange.upperBound.asCurrency)
                }
                .font(.custom("Slee_handwritting-Regular", size: 18))
                .foregroundStyle(OunjePalette.secondaryText)
            }

            Spacer(minLength: 0)
        }
    }

    private var budgetFlexibilitySelection: BudgetFlexibility {
        BudgetFlexibility.from(calibrationScore: budgetFlexibilityScore)
    }

    private var cadenceDisplayOrder: [MealCadence] {
        [.monthly, .biweekly, .weekly, .twiceWeekly, .everyFewDays, .daily]
    }

    private var mealsPerWeekRhythmNote: String {
        switch mealsPerWeek {
        case 1...3:
            return "A lighter prep with room for spontaneity."
        case 4...6:
            return "A steady prep run with enough coverage for most days."
        case 7...8:
            return "A fuller prep drop with stronger repeat support."
        default:
            return "A big prep swing that can carry most of the week in one run."
        }
    }

    private var householdServingSummary: String {
        let totalPeople = normalizedAdults + normalizedKids
        if cooksForOthers {
            return "Planning for \(normalizedAdults) adult\(normalizedAdults == 1 ? "" : "s") and \(normalizedKids) kid\(normalizedKids == 1 ? "" : "s"), \(max(1, totalPeople)) plate\(totalPeople == 1 ? "" : "s") at a time."
        }
        return "Planning solo. Ounje will keep portions tighter and avoid inflating the cart."
    }

    private func dayShortLabel(for day: DeliveryAnchorDay) -> String {
        switch day {
        case .sunday:
            return "Su"
        case .monday:
            return "Mo"
        case .tuesday:
            return "Tu"
        case .wednesday:
            return "We"
        case .thursday:
            return "Th"
        case .friday:
            return "Fr"
        case .saturday:
            return "Sa"
        }
    }

    private func cadenceSubtitle(for cadence: MealCadence) -> String {
        switch cadence {
        case .daily:
            return "Always fresh"
        case .everyFewDays:
            return "Short-cycle restock"
        case .twiceWeekly:
            return "Two drops a week"
        case .weekly:
            return "Classic weekly prep"
        case .biweekly:
            return "Longer, bigger run"
        case .monthly:
            return "Big monthly sweep"
        }
    }

    private func primeDaySubtitle(for day: DeliveryAnchorDay) -> String {
        switch day {
        case .sunday:
            return "Reset"
        case .monday:
            return "Kickoff"
        case .tuesday:
            return "Catch-up"
        case .wednesday:
            return "Midweek"
        case .thursday:
            return "Reload"
        case .friday:
            return "Weekend-ready"
        case .saturday:
            return "Big shop"
        }
    }

    private var orderingStepContent: some View {
        VStack(alignment: .leading, spacing: 24) {
            OnboardingStepHeader(
                title: "Autoshop beta",
                subtitle: "Ounje builds the cart. You review and buy.",
                turtlePlacement: .trailing
            )

            HStack(spacing: 8) {
                Text("Current access")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(OunjePalette.secondaryText)
                Text(selectedPricingTier.title)
                    .font(.custom("Slee_handwritting-Regular", size: 18))
                    .foregroundStyle(selectedPricingTier.accentColor)
            }

            ForEach(selectableOrderingAutonomyOptions) { option in
                let isLocked = isOrderingAutonomyLocked(option)
                OnboardingAutonomyCard(
                    title: option.title,
                    subtitle: autonomySubtitle(for: option),
                    isSelected: orderingAutonomy == option,
                    isLocked: isLocked,
                    accent: currentStepAccent
                ) {
                    if isOrderingAutonomySelectable(option) {
                        orderingAutonomy = option
                    } else if OunjeLaunchFlags.paywallsEnabled {
                        paywallInitialTier = OunjePricingTier.minimumTier(for: option)
                        isPaywallPresented = true
                    }
                }
            }

            Spacer(minLength: 0)
        }
    }

    private var addressStepContent: some View {
        VStack(alignment: .leading, spacing: 24) {
            OnboardingStepHeader(
                title: "Delivery",
                subtitle: "Add your drop-off details.",
                turtlePlacement: .trailing
            )

            VStack(alignment: .leading, spacing: 12) {
                Text("Instacart connection beta")
                    .font(.custom("Slee_handwritting-Regular", size: 20))
                    .foregroundStyle(OunjePalette.secondaryText)

                Button {
                    openOnboardingInstacartConnection()
                } label: {
                    HStack(spacing: 14) {
                        Image(systemName: onboardingInstacartConnectionIcon)
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(onboardingInstacartConnectionTint)
                            .frame(width: 42, height: 42)
                            .background(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(OunjePalette.elevated)
                            )

                        VStack(alignment: .leading, spacing: 4) {
                            Text(onboardingInstacartConnectionTitle)
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(OunjePalette.primaryText)
                            Text("Ounje only adds groceries to your cart. You choose when to buy.")
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
                .buttonStyle(OunjeCardPressButtonStyle())
            }

            VStack(alignment: .leading, spacing: 12) {
                Text("Delivery address & instructions")
                    .font(.custom("Slee_handwritting-Regular", size: 20))
                    .foregroundStyle(OunjePalette.secondaryText)

                Text("We only use your address for grocery delivery, delivery estimates, and nearby food context.")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(OunjePalette.secondaryText.opacity(0.82))
                    .fixedSize(horizontal: false, vertical: true)

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
                                    .fill(currentStepAccent)
                            )

                        VStack(alignment: .leading, spacing: 4) {
                            Text(addressButtonTitle)
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(OunjePalette.primaryText)
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
                .buttonStyle(OunjeCardPressButtonStyle())
            }

            Spacer(minLength: 0)
        }
    }

    private var summaryStepContent: some View {
        VStack(spacing: 12) {
            AgentSummaryExperienceCard(profile: draftProfile)

            OnboardingLessonCard(
                eyebrow: "Ready",
                title: "What happens next",
                detail: "Ounje will build the first prep, keep recurring meals in mind, and sync the cart quietly.",
                accent: currentStepAccent
            ) {
                OnboardingSummaryRow(symbol: "sparkles", title: "First prep", detail: "Recipes selected from your taste, budget, and hard stops.", accent: currentStepAccent)
                OnboardingSummaryRow(symbol: "cart.fill", title: "Main shop", detail: "Ingredients collapse into one grocery list and provider cart.", accent: currentStepAccent)
                OnboardingSummaryRow(symbol: "clock.arrow.circlepath", title: "Recurring prep", detail: "Future prep follows the cadence and favorites you chose.", accent: currentStepAccent)
            }
        }
    }

    private var canSubmit: Bool {
        !preferredName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        (!selectedCuisines.isEmpty || !selectedCuisineCountries.isEmpty) &&
        budgetPerCycle >= 25
    }

    private var canAdvanceCurrentStep: Bool {
        switch currentStep {
        case .name:
            return !preferredName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .identity:
            return true
        case .cuisines:
            return !selectedCuisines.isEmpty || !selectedCuisineCountries.isEmpty
        case .household:
            return mealsPerWeek >= 1
        case .kitchen:
            return true
        case .budget:
            return budgetPerCycle >= 25
        case .ordering:
            return true
        case .address:
            return canSubmit
        }
    }

    private var primaryActionTitle: String {
        currentStep.next == nil ? (isSaving ? "Saving..." : "Start Ounje") : "Next"
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

    private func convertBudgetPerCycle(from oldWindow: BudgetWindow, to newWindow: BudgetWindow) {
        let convertedAmount: Double

        switch (oldWindow, newWindow) {
        case (.weekly, .monthly):
            convertedAmount = budgetPerCycle * 4
        case (.monthly, .weekly):
            convertedAmount = budgetPerCycle / 4
        default:
            convertedAmount = budgetPerCycle
        }

        let newRange = budgetRange(for: newWindow)
        budgetPerCycle = min(max(convertedAmount, newRange.lowerBound), newRange.upperBound)
        syncBudgetInput()
    }

    private func commitBudgetInput() {
        let sanitized = budgetInput
            .filter { $0.isNumber || $0 == "." }

        guard let typedValue = Double(sanitized), typedValue.isFinite else {
            syncBudgetInput()
            return
        }

        budgetPerCycle = min(max(typedValue, budgetRange.lowerBound), budgetRange.upperBound)
        syncBudgetInput()
    }

    private func syncBudgetInput() {
        budgetInput = String(Int(budgetPerCycle.rounded()))
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
        if currentStep.next == nil {
            submit()
            return
        }

        guard canAdvanceCurrentStep, let next = currentStep.next else { return }
        persistDraft(step: next)
        stepTransitionDirection = 1
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
        stepTransitionDirection = -1
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

    private func allergyListContains(_ option: String) -> Bool {
        parsedAllergies.contains { $0.compare(option, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
    }

    private func toggleAllergy(_ option: String) {
        var items = parsedAllergies
        if let existingIndex = items.firstIndex(where: { $0.compare(option, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }) {
            items.remove(at: existingIndex)
        } else {
            items.append(option)
        }
        allergiesText = items.joined(separator: ", ")
    }

    private var selectedCuisineSummaryText: String {
        let titles = selectableCuisineOptions
            .filter { selectedCuisines.contains($0) }
            .map(\.title)
        return titles.isEmpty ? "" : titles.joined(separator: ", ")
    }

    private var onboardingInstacartProvider: GroceryProviderInfo? {
        onboardingProvidersViewModel.providers.first { $0.id.lowercased() == "instacart" }
    }

    private var onboardingInstacartConnectionTitle: String {
        if onboardingProvidersViewModel.isLoading {
            return "Checking connection"
        }
        guard let provider = onboardingInstacartProvider else {
            return "Connect Instacart"
        }
        return provider.connected ? "Instacart connected" : "Connect Instacart"
    }

    private var onboardingInstacartConnectionTint: Color {
        guard let provider = onboardingInstacartProvider else { return OunjePalette.secondaryText }
        return provider.connected ? currentStepAccent : OunjePalette.secondaryText
    }

    private var onboardingInstacartConnectionIcon: String {
        guard let provider = onboardingInstacartProvider else { return "cart.circle.fill" }
        return provider.connected ? "checkmark.circle.fill" : "cart.circle.fill"
    }

    private func toggleCuisine(_ option: CuisinePreference) {
        withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
            if selectedCuisines.contains(option) {
                selectedCuisines.remove(option)
            } else {
                selectedCuisines.insert(option)
            }
        }
    }

    private func loadOnboardingProviders() {
        onboardingProvidersViewModel.loadProviders(
            userId: store.resolvedTrackingSession?.userID ?? store.authSession?.userID,
            accessToken: store.resolvedTrackingSession?.accessToken ?? store.authSession?.accessToken
        )
    }

    private func openOnboardingInstacartConnection() {
        selectedOnboardingProvider = onboardingInstacartProvider
            ?? GroceryProviderInfo(id: "instacart", name: "Instacart", connected: false)
    }

    private var parsedExtraFavoriteFoods: [String] {
        parseList(extraFavoriteFoodsText)
    }

    private var parsedNeverIncludeFoods: [String] {
        parseList(neverIncludeText)
    }

    private func budgetRange(for window: BudgetWindow) -> ClosedRange<Double> {
        switch window {
        case .weekly:
            return 40...500
        case .monthly:
            return 160...2000
        }
    }

    private var budgetRange: ClosedRange<Double> {
        budgetRange(for: budgetWindow)
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
            deliveryAnchorDate: resolvedOnboardingDeliveryAnchorDate,
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
            mealPrepGoals: [],
            cooksForOthers: cooksForOthers,
            kitchenEquipment: [],
            budgetWindow: budgetWindow,
            budgetFlexibility: .slightlyFlexible,
            purchasingBehavior: purchasingBehavior,
            orderingAutonomy: orderingAutonomy,
            pricingTier: store.effectivePricingTier
        )
    }

    private var resolvedOnboardingDeliveryAnchorDate: Date {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let todayWeekday = calendar.component(.weekday, from: today)
        let desiredWeekday = deliveryAnchorDay.weekdayIndex
        let offset = (desiredWeekday - todayWeekday + 7) % 7
        return calendar.date(byAdding: .day, value: offset, to: today) ?? today
    }

    private func submit() {
        guard canSubmit else { return }
        isSaving = true

        let completedProfile = draftProfile
        Task(priority: .utility) {
            _ = try? await SupabaseAgentBriefService.shared.generateBrief(for: completedProfile)
        }
        Task {
            await store.completeOnboarding(with: completedProfile, lastStep: SetupStep.address.rawValue)
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
        selectedGoals = []
        missingEquipment.removeAll()
        cadence = sourceProfile.cadence
        deliveryAnchorDay = sourceProfile.deliveryAnchorDay
        deliveryTimeMinutes = sourceProfile.deliveryTimeMinutes
        adults = sourceProfile.consumption.adults
        kids = sourceProfile.consumption.kids
        cooksForOthers = sourceProfile.cooksForOthers
        mealsPerWeek = sourceProfile.consumption.mealsPerWeek
        includeLeftovers = sourceProfile.consumption.includeLeftovers
        budgetPerCycle = sourceProfile.budgetPerCycle
        syncBudgetInput()
        budgetWindow = sourceProfile.budgetWindow
        previousBudgetWindow = sourceProfile.budgetWindow
        budgetFlexibilityScore = UserProfile.starter.budgetFlexibility.calibrationScore
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
        selectedTierRawValue = sourceProfile.pricingTier.rawValue
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

        guard !store.isOnboarded, let session = store.authSession else { return }
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
            return "Ounje fills the cart, then you review and buy."
        case .autoOrderWithinBudget:
            return "Auto-buying is off. We do not purchase for you."
        case .fullyAutonomousGuardrails:
            return "Full checkout stays manual. You make the purchase."
        }
    }

    private func isOrderingAutonomySelectable(_ option: OrderingAutonomyLevel) -> Bool {
        if !OunjeLaunchFlags.paywallsEnabled {
            return option == .approvalRequired
        }
        return selectedPricingTier.supports(option)
    }

    private func isOrderingAutonomyLocked(_ option: OrderingAutonomyLevel) -> Bool {
        !isOrderingAutonomySelectable(option)
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

    enum SetupStep: Int, CaseIterable {
        case name
        case identity
        case cuisines
        case household
        case kitchen
        case budget
        case ordering
        case address

        var index: Int { rawValue }

        var title: String {
            switch self {
            case .name:
                return "Meet Ounje"
            case .identity:
                return "Food rules"
            case .cuisines:
                return "Taste"
            case .household:
                return "Prep rhythm"
            case .kitchen:
                return "Who we're feeding"
            case .budget:
                return "Cart budget"
            case .ordering:
                return "Autoshop beta"
            case .address:
                return "Delivery"
            }
        }

        var subtitle: String {
            switch self {
            case .name:
                return "Ounje turns a few signals into prep, recurring meals, and a cart."
            case .identity:
                return "Allergies and hard stops beat every recipe suggestion."
            case .cuisines:
                return "These are the plates Ounje should reach for first."
            case .household:
                return "This sets your delivery timing and recurring meal loop."
            case .kitchen:
                return "Tell Ounje how many people each prep should carry."
            case .budget:
                return "Set the target spend and how hard Ounje should defend it."
            case .ordering:
                return "Ounje can fill the cart. You still make the purchase."
            case .address:
                return "Connect your cart lane and add delivery details when you're ready."
            }
        }

        var prompt: String {
            switch self {
            case .name:
                return "Tell Ounje who it is planning for."
            case .identity:
                return "Set the rules Ounje cannot break."
            case .cuisines:
                return "Point Ounje toward the food you actually want."
            case .household:
                return "Choose how your prep week should run."
            case .kitchen:
                return "Choose the crowd Ounje is cooking for."
            case .budget:
                return "Set the cart guardrails."
            case .ordering:
                return "Pick how Ounje should hand the cart back to you."
            case .address:
                return "Set the handoff details for checkout."
            }
        }

        var plateEmojis: [String] {
            switch self {
            case .name:
                return ["🍽️", "📝", "🛒"]
            case .identity:
                return ["✅", "🥗", "🛡️"]
            case .cuisines:
                return ["🍛", "🌮", "🍜"]
            case .household:
                return ["📅", "🍱", "🔁"]
            case .kitchen:
                return ["🍳", "🥘", "🔥"]
            case .budget:
                return ["🛒", "$", "✓"]
            case .ordering:
                return ["🏠", "🛍️", "→"]
            case .address:
                return ["📍", "📝", "🚪"]
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
                return "person.2.fill"
            case .budget:
                return "dollarsign.circle.fill"
            case .ordering:
                return "cart.fill"
            case .address:
                return "house.fill"
            }
        }

        var next: SetupStep? {
            SetupStep(rawValue: rawValue + 1)
        }

        var previous: SetupStep? {
            SetupStep(rawValue: rawValue - 1)
        }

        static func resumeStep(from rawValue: Int) -> SetupStep {
            let clampedValue = min(max(rawValue, SetupStep.name.rawValue), SetupStep.address.rawValue)
            return SetupStep(rawValue: clampedValue) ?? .name
        }
    }
}

struct OunjeOnboardingCoachVisual: View {
    let plateEmojis: [String]
    let accent: Color
    let secondaryAccent: Color

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(secondaryAccent)
                .overlay(
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                )

            VStack(spacing: 8) {
                HStack(spacing: 7) {
                    ForEach(Array(plateEmojis.prefix(3).enumerated()), id: \.offset) { index, emoji in
                        Text(emoji)
                            .font(.system(size: index == 1 ? 22 : 18, weight: .bold, design: .rounded))
                            .frame(width: index == 1 ? 42 : 34, height: index == 1 ? 42 : 34)
                            .background(
                                Circle()
                                    .fill(OunjePalette.panel)
                                    .overlay(
                                        Circle()
                                            .stroke(accent.opacity(0.72), lineWidth: 3)
                                    )
                            )
                            .offset(y: index == 1 ? -4 : 5)
                    }
                }

                HStack(spacing: 4) {
                    ForEach(0..<4, id: \.self) { index in
                        Capsule(style: .continuous)
                            .fill(index == 0 ? accent : Color.white.opacity(0.38))
                            .frame(width: index == 0 ? 22 : 8, height: 6)
                    }
                }

                HStack(spacing: 6) {
                    Image(systemName: "calendar")
                    Image(systemName: "cart")
                    Image(systemName: "repeat")
                }
                .font(.system(size: 11, weight: .black))
                .foregroundStyle(accent)
            }
        }
    }
}

enum TurtleOnboardingSceneMode: Equatable {
    case name
    case rules

    var turtleWidthRatio: CGFloat {
        switch self {
        case .name:
            return 0.26
        case .rules:
            return 0.22
        }
    }

    var maxTurtleWidth: CGFloat {
        switch self {
        case .name:
            return 96
        case .rules:
            return 78
        }
    }

    var sideInset: CGFloat {
        switch self {
        case .name:
            return 64
        case .rules:
            return 50
        }
    }

    var yBaseRatio: CGFloat {
        switch self {
        case .name:
            return 0.72
        case .rules:
            return 0.66
        }
    }

    var waveHeight: CGFloat {
        switch self {
        case .name:
            return 28
        case .rules:
            return 28
        }
    }

    var cornerRadius: CGFloat {
        switch self {
        case .name:
            return 0
        case .rules:
            return 26
        }
    }
}

struct TurtleOnboardingScene: View {
    let prompt: String
    let mode: TurtleOnboardingSceneMode

    var body: some View {
        ZStack {
            Image("OnboardingTurtleHabitat")
                .resizable()
                .scaledToFill()

            LinearGradient(
                colors: [
                    Color.black.opacity(0.08),
                    Color.black.opacity(0.28)
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            if mode == .rules {
                TurtleGuardrailMarkers()
            }

            TurtleNamePrompt(prompt: prompt, mode: mode)
                .padding(.horizontal, 12)
                .padding(.vertical, 14)
        }
        .clipShape(RoundedRectangle(cornerRadius: mode.cornerRadius, style: .continuous))
        .overlay {
            if mode == .rules {
                RoundedRectangle(cornerRadius: mode.cornerRadius, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            }
        }
        .overlay(alignment: .bottom) {
            if mode.waveHeight > 0 {
                ZStack(alignment: .top) {
                    OnboardingHabitatWaveFill()
                        .fill(OunjePalette.background)

                    OnboardingHabitatWaveLine()
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                }
                .frame(height: mode.waveHeight)
                .offset(y: 1)
            }
        }
    }
}

struct NameLineCursor: View {
    let color: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.55)) { timeline in
            let tick = Int(timeline.date.timeIntervalSinceReferenceDate / 0.55)
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(color)
                .frame(width: 3, height: 30)
                .opacity(reduceMotion || tick.isMultiple(of: 2) ? 1 : 0.18)
        }
        .frame(width: 8, height: 34, alignment: .leading)
    }
}

struct TurtleNamePrompt: View {
    var prompt: String = "What should I call you?"
    var mode: TurtleOnboardingSceneMode = .name
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let frameNames = [
        "OnboardingTurtleFrame1",
        "OnboardingTurtleFrame2",
        "OnboardingTurtleFrame3",
        "OnboardingTurtleFrame4",
        "OnboardingTurtleFrame5",
        "OnboardingTurtleFrame6",
        "OnboardingTurtleFrame7",
        "OnboardingTurtleFrame8"
    ]

    var body: some View {
        GeometryReader { proxy in
            TimelineView(.periodic(from: .now, by: 1.0 / 24.0)) { timeline in
                let time = timeline.date.timeIntervalSinceReferenceDate
                let frameIndex = reduceMotion
                    ? 0
                    : Int(time / 0.13) % frameNames.count
                let cycle = 11.2
                let progress = reduceMotion ? 0.5 : time.truncatingRemainder(dividingBy: cycle) / cycle
                let movingRight = progress < 0.5
                let legProgress = CGFloat(movingRight ? progress * 2 : (1 - progress) * 2)
                let turtleWidth = min(proxy.size.width * mode.turtleWidthRatio, mode.maxTurtleWidth)
                let turtleHeight = turtleWidth * 650 / 1141
                let sideInset = mode.sideInset
                let left = sideInset + turtleWidth / 2
                let right = max(left, proxy.size.width - sideInset - turtleWidth / 2)
                let x = left + (right - left) * legProgress
                let yRange = max(turtleHeight / 2, proxy.size.height - turtleHeight / 2)
                let yBase = min(yRange, max(turtleHeight / 2, proxy.size.height * mode.yBaseRatio))
                let yDrift = CGFloat(sin(progress * Double.pi * 4)) * min(12, proxy.size.height * 0.045)
                let y = reduceMotion
                    ? yBase
                    : min(
                        yRange,
                        max(
                            turtleHeight / 2,
                            yBase + yDrift
                        )
                )
                let bubbleWidth: CGFloat = mode == .rules ? 154 : 142
                let bubbleXOffset = movingRight ? min(48, turtleWidth * 0.52) : -min(48, turtleWidth * 0.52)
                let bubbleInset: CGFloat = 30
                let bubbleX = min(proxy.size.width - bubbleWidth / 2 - bubbleInset, max(bubbleWidth / 2 + bubbleInset, x + bubbleXOffset))
                let bubbleY = max(mode == .rules ? 38 : 44, y - turtleHeight * 0.72)

                ZStack {
                    TurtleSpeechBubble(text: prompt, pointsRight: movingRight)
                        .frame(width: bubbleWidth)
                        .position(x: bubbleX, y: bubbleY)

                    Image(frameNames[frameIndex])
                        .resizable()
                        .scaledToFit()
                        .frame(width: turtleWidth, height: turtleHeight)
                        .scaleEffect(x: movingRight ? 1 : -1, y: 1, anchor: .center)
                        .shadow(color: Color.black.opacity(0.34), radius: 14, x: 0, y: 10)
                        .position(x: x, y: y)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(maxHeight: .infinity)
        .accessibilityLabel(mode == .name ? "Ounje turtle asking for your name" : "Ounje turtle asking about food rules")
    }
}

struct OnboardingPointingTurtle: View {
    let mirrored: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let frameNames = [
        "OnboardingTurtlePointFrame1",
        "OnboardingTurtlePointFrame2",
        "OnboardingTurtlePointFrame3",
        "OnboardingTurtlePointFrame4",
        "OnboardingTurtlePointFrame5",
        "OnboardingTurtlePointFrame6",
        "OnboardingTurtlePointFrame7",
        "OnboardingTurtlePointFrame8",
        "OnboardingTurtlePointFrame9"
    ]

    private var timedFrameNames: [String] {
        [
            "OnboardingTurtlePointFrame1",
            "OnboardingTurtlePointFrame2",
            "OnboardingTurtlePointFrame3",
            "OnboardingTurtlePointFrame4",
            "OnboardingTurtlePointFrame5",
            "OnboardingTurtlePointFrame6",
            "OnboardingTurtlePointFrame7",
            "OnboardingTurtlePointFrame8",
            "OnboardingTurtlePointFrame8",
            "OnboardingTurtlePointFrame8",
            "OnboardingTurtlePointFrame9",
            "OnboardingTurtlePointFrame9",
            "OnboardingTurtlePointFrame9",
            "OnboardingTurtlePointFrame9"
        ]
    }

    init(mirrored: Bool = false) {
        self.mirrored = mirrored
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0 / 18.0)) { timeline in
            let frameIndex = reduceMotion
                ? 1
                : Int(timeline.date.timeIntervalSinceReferenceDate / 0.12) % timedFrameNames.count

            Image(reduceMotion ? frameNames[1] : timedFrameNames[frameIndex])
                .resizable()
                .scaledToFit()
                .scaleEffect(x: mirrored ? -1 : 1, y: 1, anchor: .center)
                .shadow(color: Color.black.opacity(0.18), radius: 8, x: 0, y: 5)
        }
    }
}

enum OnboardingHeaderTurtlePlacement {
    case none
    case leading
    case trailing
}

struct OnboardingStepHeader: View {
    let title: String
    let subtitle: String
    var turtlePlacement: OnboardingHeaderTurtlePlacement = .none

    var body: some View {
        HStack(alignment: .bottom, spacing: 14) {
            if turtlePlacement == .leading {
                OnboardingPointingTurtle()
                    .frame(width: 116, height: 116)
                    .accessibilityHidden(true)
            }

            VStack(alignment: .leading, spacing: 7) {
                Text(title)
                    .font(.system(size: 38, weight: .heavy, design: .rounded))
                    .foregroundStyle(OunjePalette.primaryText)

                Text(subtitle)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(OunjePalette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.bottom, 10)
            .frame(maxWidth: .infinity, alignment: .leading)

            if turtlePlacement == .trailing {
                OnboardingPointingTurtle(mirrored: true)
                    .frame(width: 116, height: 116)
                    .accessibilityHidden(true)
            } else if turtlePlacement == .none {
                Color.clear
                    .frame(width: 116, height: 116)
                    .allowsHitTesting(false)
            }
        }
    }
}

struct TurtleGuardrailMarkers: View {
    var body: some View {
        GeometryReader { proxy in
            let baseline = proxy.size.height * 0.74
            ForEach(Array(([CGFloat(0.20), 0.42, 0.66, 0.84]).enumerated()), id: \.offset) { index, xRatio in
                VStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(Color(hex: "C9CDC6").opacity(0.64))
                        .frame(width: 3, height: index.isMultiple(of: 2) ? 25 : 18)

                    Circle()
                        .fill(Color(hex: "CFFF37").opacity(0.72))
                        .frame(width: 7, height: 7)
                }
                .position(x: proxy.size.width * xRatio, y: baseline + CGFloat(index % 2) * 7)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct OnboardingHabitatWaveFill: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let first = CGPoint(x: rect.minX, y: rect.height * 0.34)
        path.move(to: first)
        path.addCurve(
            to: CGPoint(x: rect.width * 0.34, y: rect.height * 0.22),
            control1: CGPoint(x: rect.width * 0.10, y: rect.height * 0.52),
            control2: CGPoint(x: rect.width * 0.20, y: rect.height * 0.06)
        )
        path.addCurve(
            to: CGPoint(x: rect.width * 0.68, y: rect.height * 0.34),
            control1: CGPoint(x: rect.width * 0.46, y: rect.height * 0.40),
            control2: CGPoint(x: rect.width * 0.54, y: rect.height * 0.54)
        )
        path.addCurve(
            to: CGPoint(x: rect.maxX, y: rect.height * 0.28),
            control1: CGPoint(x: rect.width * 0.82, y: rect.height * 0.12),
            control2: CGPoint(x: rect.width * 0.92, y: rect.height * 0.22)
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

struct OnboardingHabitatWaveLine: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.height * 0.34))
        path.addCurve(
            to: CGPoint(x: rect.width * 0.34, y: rect.height * 0.22),
            control1: CGPoint(x: rect.width * 0.10, y: rect.height * 0.52),
            control2: CGPoint(x: rect.width * 0.20, y: rect.height * 0.06)
        )
        path.addCurve(
            to: CGPoint(x: rect.width * 0.68, y: rect.height * 0.34),
            control1: CGPoint(x: rect.width * 0.46, y: rect.height * 0.40),
            control2: CGPoint(x: rect.width * 0.54, y: rect.height * 0.54)
        )
        path.addCurve(
            to: CGPoint(x: rect.maxX, y: rect.height * 0.28),
            control1: CGPoint(x: rect.width * 0.82, y: rect.height * 0.12),
            control2: CGPoint(x: rect.width * 0.92, y: rect.height * 0.22)
        )
        return path
    }
}

struct TurtleSpeechBubble: View {
    let text: String
    let pointsRight: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(text)
                .font(.system(size: 15, weight: .heavy, design: .rounded))
                .foregroundStyle(Color(hex: "121212"))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(OunjePalette.softCream)
                        .overlay(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .stroke(Color.white.opacity(0.72), lineWidth: 1)
                        )
                )

            BubbleTail(pointsRight: pointsRight)
                .fill(OunjePalette.softCream)
                .frame(width: 22, height: 13)
                .offset(x: pointsRight ? 116 : 30, y: -1)
        }
        .shadow(color: Color.black.opacity(0.24), radius: 10, x: 0, y: 6)
    }
}

struct BubbleTail: Shape {
    let pointsRight: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path()
        if pointsRight {
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX * 0.15, y: rect.maxY))
        } else {
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX * 0.85, y: rect.maxY))
        }
        path.closeSubpath()
        return path
    }
}

struct OnboardingCoachPanel: View {
    let step: FirstLoginOnboardingView.SetupStep
    let accent: Color
    let secondaryAccent: Color
    let preferredName: String

    @State private var isFloating = false

    private var greeting: String {
        let name = preferredName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, step == .name else { return step.prompt }
        return "Nice. I’ll call you \(name)."
    }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            OunjeOnboardingCoachVisual(
                plateEmojis: step.plateEmojis,
                accent: accent,
                secondaryAccent: secondaryAccent
            )
            .frame(width: 118, height: 118)
            .shadow(color: secondaryAccent.opacity(0.18), radius: 16, x: 0, y: 10)
            .offset(y: isFloating ? -4 : 3)

            VStack(alignment: .leading, spacing: 8) {
                Text(step.title)
                    .font(.system(size: 13, weight: .black))
                    .foregroundStyle(OunjePalette.secondaryText)
                    .textCase(.uppercase)

                Text(greeting)
                    .font(.system(size: 23, weight: .heavy, design: .rounded))
                    .foregroundStyle(OunjePalette.primaryText)
                    .fixedSize(horizontal: false, vertical: true)

                Text(step.subtitle)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(OunjePalette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 6)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .fill(OunjePalette.panel.opacity(0.92))
                .overlay(
                    RoundedRectangle(cornerRadius: 30, style: .continuous)
                        .stroke(OunjePalette.stroke, lineWidth: 1)
                )
        )
        .onAppear {
            withAnimation(.easeInOut(duration: 2.8).repeatForever(autoreverses: true)) {
                isFloating = true
            }
        }
    }
}

struct OnboardingLessonCard<Content: View>: View {
    let eyebrow: String
    let title: String
    let detail: String
    let accent: Color
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Text(eyebrow)
                    .font(.system(size: 11, weight: .black))
                    .foregroundStyle(OunjePalette.secondaryText)
                    .textCase(.uppercase)

                Text(title)
                    .font(.system(size: 23, weight: .heavy, design: .rounded))
                    .foregroundStyle(OunjePalette.primaryText)
                    .fixedSize(horizontal: false, vertical: true)

                Text(detail)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(OunjePalette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(OunjePalette.panel)
                .overlay(
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .stroke(OunjePalette.stroke, lineWidth: 1)
                )
                .overlay(alignment: .topLeading) {
                    Capsule(style: .continuous)
                        .fill(accent)
                        .frame(width: 76, height: 7)
                        .padding(.top, 12)
                        .padding(.leading, 16)
                }
        )
        .shadow(color: Color.black.opacity(0.22), radius: 18, x: 0, y: 10)
    }
}

struct OnboardingLightInputModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.system(size: 18, weight: .bold, design: .rounded))
            .foregroundStyle(OunjePalette.primaryText)
            .padding(.horizontal, 15)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(OunjePalette.elevated)
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(OunjePalette.stroke, lineWidth: 1)
                    )
            )
    }
}

struct OnboardingPromiseChip: View {
    let title: String
    let symbol: String
    let accent: Color

    var body: some View {
        VStack(spacing: 7) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .black))
                .foregroundStyle(.black)
                .frame(width: 34, height: 34)
                .background(accent.opacity(0.78), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            Text(title)
                .font(.system(size: 11, weight: .black))
                .foregroundStyle(OunjePalette.secondaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.78)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(OunjePalette.elevated)
        )
    }
}

struct OnboardingPillGrid: View {
    let options: [String]
    @Binding var selection: Set<String>
    let accent: Color

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 122), spacing: 9)], spacing: 9) {
            ForEach(options, id: \.self) { option in
                OnboardingChoicePill(
                    title: option,
                    emoji: onboardingEmoji(for: option),
                    isSelected: selection.contains(option),
                    accent: accent
                ) {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
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

struct OnboardingEnumPillGrid<Option: Hashable & Identifiable>: View {
    let options: [Option]
    @Binding var selection: Set<Option>
    let accent: Color
    var leadingEmoji: ((Option) -> String?)? = nil
    let label: (Option) -> String

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 122), spacing: 9)], spacing: 9) {
            ForEach(options) { option in
                OnboardingChoicePill(
                    title: label(option),
                    emoji: leadingEmoji?(option),
                    isSelected: selection.contains(option),
                    accent: accent
                ) {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
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

struct OnboardingCuisineSelectionLine: View {
    let placeholder: String
    let selectedText: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(selectedText.isEmpty ? placeholder : selectedText)
                .font(.custom("Slee_handwritting-Regular", size: 24))
                .foregroundStyle(selectedText.isEmpty ? OunjePalette.secondaryText.opacity(0.8) : OunjePalette.primaryText)
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 16)
                .padding(.vertical, 12)
                .overlay(alignment: .leading) {
                    NameLineCursor(color: Color(hex: "C9CDC6"))
                        .allowsHitTesting(false)
                }

            Rectangle()
                .fill(Color(hex: "C9CDC6").opacity(0.82))
                .frame(height: 1.5)
        }
    }
}

struct OnboardingCuisinePill: View {
    let title: String
    let flagCode: String?
    let badgeText: String
    let badgeHex: String
    let isSelected: Bool
    let accent: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Group {
                    if let flagCode {
                        CuisineFlagBadge(code: flagCode)
                            .frame(width: 20, height: 20)
                    } else {
                        Text(badgeText)
                            .font(.system(size: 10, weight: .black, design: .rounded))
                            .foregroundStyle(Color(hex: badgeHex))
                    }
                }
                .frame(width: 24, height: 20)

                Text(title)
                    .font(.custom("Slee_handwritting-Regular", size: 18))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 0)

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .black))
                        .foregroundStyle(accent)
                }
            }
            .foregroundStyle(OunjePalette.primaryText)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.white.opacity(0.055))
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(isSelected ? accent.opacity(0.9) : Color.white.opacity(0.16), lineWidth: 1.4)
                    )
            )
            .scaleEffect(isSelected ? 1.015 : 1)
            .animation(OunjeMotion.quickSpring, value: isSelected)
        }
        .buttonStyle(OunjeCardPressButtonStyle())
    }
}

struct CuisineFlagBadge: View {
    let code: String

    var body: some View {
        flagBody
            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
    }

    @ViewBuilder
    private var flagBody: some View {
        switch code {
        case "US":
            usFlag
        case "MX":
            verticalFlag(left: "1E8E3E", center: "F3F4F6", right: "D93F39")
        case "IT":
            verticalFlag(left: "009246", center: "F3F4F6", right: "CE2B37")
        case "FR":
            verticalFlag(left: "1F4DB6", center: "F3F4F6", right: "E53935")
        case "PT":
            portugalFlag
        case "ES":
            horizontalFlag(top: "AA151B", middle: "F1BF00", bottom: "AA151B", middleRatio: 0.5)
        case "GR":
            greeceFlag
        case "LB":
            lebanonFlag
        case "JM":
            jamaicaFlag
        case "NG":
            verticalFlag(left: "128A49", center: "F3F4F6", right: "128A49")
        case "ET":
            horizontalFlag(top: "1F8A43", middle: "F2D43D", bottom: "D83A34")
        case "BR":
            brazilFlag
        case "CN":
            chinaFlag
        case "JP":
            japanFlag
        case "KR":
            koreaFlag
        case "TH":
            thailandFlag
        case "VN":
            vietnamFlag
        case "TR":
            turkeyFlag
        case "MA":
            moroccoFlag
        case "IR":
            horizontalFlag(top: "239F40", middle: "F3F4F6", bottom: "DA0000")
        case "PH":
            philippinesFlag
        case "IN":
            indiaFlag
        case "DE":
            horizontalFlag(top: "111111", middle: "C62828", bottom: "F2C037")
        case "GB":
            ukFlag
        case "AS":
            asiaFlag
        default:
            Color.clear
        }
    }

    private func verticalFlag(left: String, center: String, right: String) -> some View {
        HStack(spacing: 0) {
            Color(hex: left)
            Color(hex: center)
            Color(hex: right)
        }
    }

    private func horizontalFlag(top: String, middle: String, bottom: String, middleRatio: CGFloat = 0.34) -> some View {
        GeometryReader { proxy in
            let middleHeight = proxy.size.height * middleRatio
            let sideHeight = (proxy.size.height - middleHeight) / 2

            VStack(spacing: 0) {
                Color(hex: top).frame(height: sideHeight)
                Color(hex: middle).frame(height: middleHeight)
                Color(hex: bottom).frame(height: sideHeight)
            }
        }
    }

    private var usFlag: some View {
        GeometryReader { proxy in
            let stripeHeight = proxy.size.height / 7
            ZStack(alignment: .topLeading) {
                VStack(spacing: 0) {
                    ForEach(0..<7, id: \.self) { index in
                        (index.isMultiple(of: 2) ? Color(hex: "B22234") : Color.white)
                            .frame(height: stripeHeight)
                    }
                }

                Color(hex: "3C3B6E")
                    .frame(width: proxy.size.width * 0.45, height: stripeHeight * 4)
            }
        }
    }

    private var portugalFlag: some View {
        GeometryReader { proxy in
            ZStack {
                HStack(spacing: 0) {
                    Color(hex: "046A38").frame(width: proxy.size.width * 0.4)
                    Color(hex: "DA291C")
                }
                Circle()
                    .fill(Color(hex: "F2C037"))
                    .frame(width: proxy.size.height * 0.52, height: proxy.size.height * 0.52)
            }
        }
    }

    private var greeceFlag: some View {
        GeometryReader { proxy in
            let stripeHeight = proxy.size.height / 5
            ZStack(alignment: .topLeading) {
                VStack(spacing: 0) {
                    ForEach(0..<5, id: \.self) { index in
                        (index.isMultiple(of: 2) ? Color(hex: "0D5EAF") : Color.white)
                            .frame(height: stripeHeight)
                    }
                }

                Color(hex: "0D5EAF")
                    .frame(width: proxy.size.width * 0.42, height: stripeHeight * 3)
                    .overlay {
                        ZStack {
                            Rectangle()
                                .fill(Color.white)
                                .frame(width: proxy.size.width * 0.42, height: stripeHeight * 0.45)
                            Rectangle()
                                .fill(Color.white)
                                .frame(width: stripeHeight * 0.45, height: stripeHeight * 3)
                        }
                    }
            }
        }
    }

    private var lebanonFlag: some View {
        GeometryReader { proxy in
            ZStack {
                VStack(spacing: 0) {
                    Color(hex: "D32F2F").frame(height: proxy.size.height * 0.25)
                    Color.white
                    Color(hex: "D32F2F").frame(height: proxy.size.height * 0.25)
                }
                Triangle()
                    .fill(Color(hex: "1F8A43"))
                    .frame(width: proxy.size.width * 0.32, height: proxy.size.height * 0.48)
            }
        }
    }

    private var jamaicaFlag: some View {
        GeometryReader { proxy in
            ZStack {
                Color(hex: "111111")
                Triangle()
                    .fill(Color(hex: "1F8A43"))
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .rotationEffect(.degrees(90))
                Triangle()
                    .fill(Color(hex: "1F8A43"))
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .rotationEffect(.degrees(-90))
                DiagonalCross(color: Color(hex: "F2C037"), lineWidth: proxy.size.height * 0.22)
            }
        }
    }

    private var brazilFlag: some View {
        GeometryReader { proxy in
            ZStack {
                Color(hex: "229E45")
                Diamond()
                    .fill(Color(hex: "F7C948"))
                    .frame(width: proxy.size.width * 0.58, height: proxy.size.height * 0.62)
                Circle()
                    .fill(Color(hex: "22408C"))
                    .frame(width: proxy.size.height * 0.38, height: proxy.size.height * 0.38)
            }
        }
    }

    private var chinaFlag: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                Color(hex: "DE2910")
                StarShape(points: 5)
                    .fill(Color(hex: "FFDE00"))
                    .frame(width: proxy.size.height * 0.34, height: proxy.size.height * 0.34)
                    .padding(.leading, proxy.size.width * 0.12)
                    .padding(.top, proxy.size.height * 0.12)
            }
        }
    }

    private var japanFlag: some View {
        ZStack {
            Color.white
            Circle().fill(Color(hex: "BC002D")).frame(width: 10, height: 10)
        }
    }

    private var koreaFlag: some View {
        ZStack {
            Color.white
            Circle().fill(Color(hex: "CD2E3A")).frame(width: 10, height: 10).offset(y: -2)
            Circle().fill(Color(hex: "0047A0")).frame(width: 10, height: 10).offset(y: 2)
        }
    }

    private var thailandFlag: some View {
        horizontalFlag(top: "A51931", middle: "2D2A4A", bottom: "A51931", middleRatio: 0.42)
            .overlay {
                GeometryReader { proxy in
                    VStack(spacing: 0) {
                        Color.clear.frame(height: proxy.size.height * 0.2)
                        Color.white.frame(height: proxy.size.height * 0.12)
                        Spacer()
                        Color.white.frame(height: proxy.size.height * 0.12)
                        Color.clear.frame(height: proxy.size.height * 0.2)
                    }
                }
            }
    }

    private var vietnamFlag: some View {
        ZStack {
            Color(hex: "DA251D")
            StarShape(points: 5)
                .fill(Color(hex: "FFFF00"))
                .frame(width: 11, height: 11)
        }
    }

    private var turkeyFlag: some View {
        ZStack {
            Color(hex: "E30A17")
            Circle().fill(Color.white).frame(width: 10, height: 10).offset(x: -2)
            Circle().fill(Color(hex: "E30A17")).frame(width: 8, height: 8)
            StarShape(points: 5).fill(Color.white).frame(width: 5, height: 5).offset(x: 4)
        }
    }

    private var moroccoFlag: some View {
        ZStack {
            Color(hex: "C1272D")
            StarShape(points: 5)
                .stroke(Color(hex: "006233"), lineWidth: 1.2)
                .frame(width: 11, height: 11)
        }
    }

    private var philippinesFlag: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                VStack(spacing: 0) {
                    Color(hex: "0038A8")
                    Color(hex: "CE1126")
                }
                Triangle()
                    .fill(Color.white)
                    .frame(width: proxy.size.width * 0.52, height: proxy.size.height)
                    .offset(x: -proxy.size.width * 0.08)
            }
        }
    }

    private var indiaFlag: some View {
        ZStack {
            horizontalFlag(top: "FF9933", middle: "FFFFFF", bottom: "138808")
            Circle()
                .stroke(Color(hex: "000080"), lineWidth: 1)
                .frame(width: 7, height: 7)
        }
    }

    private var ukFlag: some View {
        GeometryReader { proxy in
            ZStack {
                Color(hex: "012169")
                DiagonalCross(color: .white, lineWidth: proxy.size.height * 0.2)
                DiagonalCross(color: Color(hex: "C8102E"), lineWidth: proxy.size.height * 0.1)
                Rectangle().fill(Color.white).frame(height: proxy.size.height * 0.24)
                Rectangle().fill(Color.white).frame(width: proxy.size.width * 0.18)
                Rectangle().fill(Color(hex: "C8102E")).frame(height: proxy.size.height * 0.12)
                Rectangle().fill(Color(hex: "C8102E")).frame(width: proxy.size.width * 0.09)
            }
        }
    }

    private var asiaFlag: some View {
        ZStack {
            LinearGradient(
                colors: [Color(hex: "1D4ED8"), Color(hex: "14B8A6")],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Image(systemName: "globe.asia.australia.fill")
                .font(.system(size: 10, weight: .black))
                .foregroundStyle(.white)
        }
    }
}

struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

struct Diamond: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
        path.closeSubpath()
        return path
    }
}

struct DiagonalCross: View {
    let color: Color
    let lineWidth: CGFloat

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Rectangle()
                    .fill(color)
                    .frame(width: proxy.size.width * 1.5, height: lineWidth)
                    .rotationEffect(.degrees(34))
                Rectangle()
                    .fill(color)
                    .frame(width: proxy.size.width * 1.5, height: lineWidth)
                    .rotationEffect(.degrees(-34))
            }
        }
    }
}

struct StarShape: Shape {
    let points: Int

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let outerRadius = min(rect.width, rect.height) / 2
        let innerRadius = outerRadius * 0.42
        let angle = Double.pi / Double(points)

        var path = Path()
        for index in 0..<(points * 2) {
            let radius = index.isMultiple(of: 2) ? outerRadius : innerRadius
            let pointAngle = (Double(index) * angle) - (.pi / 2)
            let point = CGPoint(
                x: center.x + CGFloat(cos(pointAngle)) * radius,
                y: center.y + CGFloat(sin(pointAngle)) * radius
            )

            if index == 0 {
                path.move(to: point)
            } else {
                path.addLine(to: point)
            }
        }
        path.closeSubpath()
        return path
    }
}

struct OnboardingChoicePill: View {
    let title: String
    let emoji: String?
    let isSelected: Bool
    let accent: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let emoji {
                    Text(emoji)
                        .font(.system(size: 18))
                        .frame(width: 26, height: 26)
                } else {
                    Image(systemName: isSelected ? "checkmark.seal.fill" : "sparkles")
                        .font(.system(size: 13, weight: .black))
                        .foregroundStyle(isSelected ? .black : OunjePalette.secondaryText)
                        .frame(width: 26, height: 26)
                }

                Text(title)
                    .font(.system(size: 13, weight: .black, design: .rounded))
                    .foregroundStyle(isSelected ? .black : OunjePalette.primaryText)
                    .lineLimit(2)
                    .minimumScaleFactor(0.82)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16, weight: .black))
                    .foregroundStyle(isSelected ? .black : OunjePalette.secondaryText.opacity(0.82))
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(isSelected ? accent.opacity(0.9) : OunjePalette.elevated)
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(isSelected ? accent.opacity(0.9) : OunjePalette.stroke, lineWidth: 1)
                    )
            )
            .scaleEffect(isSelected ? 1.01 : 1)
        }
        .buttonStyle(.plain)
    }
}

struct OnboardingTextEntry: View {
    let placeholder: String
    @Binding var text: String

    var body: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $text)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(OunjePalette.primaryText)
                .scrollContentBackground(.hidden)
                .padding(10)
                .frame(minHeight: 104)

            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(placeholder)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(OunjePalette.secondaryText)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 18)
                    .allowsHitTesting(false)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(OunjePalette.elevated)
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(OunjePalette.stroke, lineWidth: 1)
                )
        )
    }
}

struct OnboardingLineEntry: View {
    let placeholder: String
    @Binding var text: String

    var body: some View {
        TextField(placeholder, text: $text)
            .textInputAutocapitalization(.words)
            .autocorrectionDisabled()
            .submitLabel(.done)
            .font(.custom("Slee_handwritting-Regular", size: 24))
            .foregroundStyle(OunjePalette.primaryText)
            .tint(Color(hex: "C9CDC6"))
            .padding(.leading, 16)
            .padding(.vertical, 12)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(Color(hex: "C9CDC6").opacity(0.82))
                    .frame(height: 1.5)
            }
            .overlay(alignment: .leading) {
                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    NameLineCursor(color: Color(hex: "C9CDC6"))
                        .padding(.leading, 2)
                        .allowsHitTesting(false)
                }
            }
    }
}

struct OnboardingRuleChip: View {
    let title: String
    let emoji: String?
    let isSelected: Bool
    let accent: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if let emoji {
                    Text(emoji)
                        .font(.system(size: 15))
                }

                Text(title)
                    .font(.system(size: 13, weight: .black, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .black))
                }
            }
            .foregroundStyle(isSelected ? Color.black : OunjePalette.primaryText)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                Capsule(style: .continuous)
                    .fill(isSelected ? accent : OunjePalette.elevated)
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(isSelected ? accent.opacity(0.72) : OunjePalette.stroke, lineWidth: 1)
                    )
            )
            .scaleEffect(isSelected ? 1.02 : 1)
            .animation(OunjeMotion.quickSpring, value: isSelected)
        }
        .buttonStyle(OunjeCardPressButtonStyle())
    }
}

struct OnboardingAllergyPill: View {
    let title: String
    let isSelected: Bool
    let accent: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .heavy, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.76)
                .foregroundStyle(isSelected ? Color.black : OunjePalette.primaryText)
                .frame(maxWidth: .infinity)
                .frame(height: 38)
                .background(
                    Capsule(style: .continuous)
                        .fill(isSelected ? accent : Color.white.opacity(0.055))
                        .overlay(
                            Capsule(style: .continuous)
                                .stroke(isSelected ? accent.opacity(0.75) : Color.white.opacity(0.16), lineWidth: 1)
                        )
                )
                .scaleEffect(isSelected ? 1.015 : 1)
                .animation(OunjeMotion.quickSpring, value: isSelected)
        }
        .buttonStyle(OunjeCardPressButtonStyle())
    }
}

struct OnboardingInlineField: View {
    let title: String
    let placeholder: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .black))
                .foregroundStyle(OunjePalette.secondaryText)

            TextField(placeholder, text: $text)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .modifier(OnboardingLightInputModifier())
        }
    }
}

struct OnboardingTinyTag: View {
    let text: String
    let accent: Color

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .black))
            .foregroundStyle(.black)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(accent.opacity(0.72), in: Capsule(style: .continuous))
    }
}

struct OnboardingStepperRow: View {
    let title: String
    let value: Int
    let range: ClosedRange<Int>
    let accent: Color
    let onChange: (Int) -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.system(size: 14, weight: .black))
                .foregroundStyle(OunjePalette.primaryText)

            Spacer(minLength: 0)

            Button {
                onChange(max(range.lowerBound, value - 1))
            } label: {
                Image(systemName: "minus")
                    .font(.system(size: 13, weight: .black))
                    .frame(width: 34, height: 34)
            }
            .disabled(value <= range.lowerBound)

            Text("\(value)")
                .font(.system(size: 18, weight: .heavy, design: .rounded))
                .foregroundStyle(OunjePalette.primaryText)
                .frame(width: 34)

            Button {
                onChange(min(range.upperBound, value + 1))
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .black))
                    .frame(width: 34, height: 34)
            }
            .disabled(value >= range.upperBound)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(OunjePalette.elevated)
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(OunjePalette.stroke, lineWidth: 1)
                )
        )
        .tint(OunjePalette.primaryText)
    }
}

struct OnboardingBorderOptionCard: View {
    let title: String
    let subtitle: String?
    let isSelected: Bool
    let accent: Color
    var minWidth: CGFloat? = nil
    var titleFont: Font = .system(size: 14, weight: .black)
    var subtitleFont: Font = .system(size: 12, weight: .semibold)
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(titleFont)
                    .foregroundStyle(OunjePalette.primaryText)
                    .fixedSize(horizontal: false, vertical: true)

                if let subtitle {
                    Text(subtitle)
                        .font(subtitleFont)
                        .foregroundStyle(OunjePalette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(isSelected ? accent.opacity(0.14) : OunjePalette.elevated)
                    .overlay(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .stroke(isSelected ? accent.opacity(0.9) : OunjePalette.stroke, lineWidth: isSelected ? 1.4 : 1)
                    )
            )
            .scaleEffect(isSelected ? 1.015 : 1)
            .animation(OunjeMotion.quickSpring, value: isSelected)
        }
        .buttonStyle(OunjeCardPressButtonStyle())
        .frame(minWidth: minWidth)
    }
}

struct OnboardingWheelNumberCard: View {
    let title: String
    @Binding var selection: Int
    let values: [Int]
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 13, weight: .black))
                .foregroundStyle(OunjePalette.secondaryText)

            Picker(title, selection: $selection) {
                ForEach(values, id: \.self) { value in
                    Text("\(value)").tag(value)
                }
            }
            .pickerStyle(.wheel)
            .frame(maxWidth: .infinity)
            .frame(height: 118)
            .clipped()
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(OunjePalette.elevated)
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(OunjePalette.stroke, lineWidth: 1)
                )
        )
        .animation(OunjeMotion.quickSpring, value: selection)
    }
}

struct OnboardingEquipmentToggle: View {
    let title: String
    let detail: String
    let symbol: String
    let isMissing: Bool
    let accent: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .black))
                    .foregroundStyle(isMissing ? OunjePalette.secondaryText : .black)
                    .frame(width: 42, height: 42)
                    .background(
                        RoundedRectangle(cornerRadius: 15, style: .continuous)
                            .fill(isMissing ? Color.white.opacity(0.08) : accent.opacity(0.78))
                    )

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 14, weight: .black))
                        .foregroundStyle(OunjePalette.primaryText)
                    Text(isMissing ? "Do not assume this." : detail)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(OunjePalette.secondaryText)
                }

                Spacer(minLength: 0)

                Image(systemName: isMissing ? "xmark.circle.fill" : "checkmark.circle.fill")
                    .font(.system(size: 19, weight: .black))
                    .foregroundStyle(isMissing ? OunjePalette.secondaryText : accent)
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(OunjePalette.elevated)
                    .overlay(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .stroke(isMissing ? OunjePalette.stroke : accent.opacity(0.52), lineWidth: 1)
                    )
            )
            .scaleEffect(isMissing ? 1 : 1.015)
            .animation(OunjeMotion.quickSpring, value: isMissing)
        }
        .buttonStyle(OunjeCardPressButtonStyle())
    }
}

struct OnboardingBudgetFlexControl: View {
    @Binding var score: Int
    let accent: Color

    private var selection: BudgetFlexibility {
        BudgetFlexibility.from(calibrationScore: score)
    }

    private var scoreBinding: Binding<Double> {
        Binding(
            get: { Double(score) },
            set: { score = min(100, max(0, Int($0.rounded()))) }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(selection.title)
                    .font(.system(size: 15, weight: .black))
                    .foregroundStyle(OunjePalette.primaryText)

                Spacer()

                Text("\(score)")
                    .font(.system(size: 15, weight: .black))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(accent.opacity(0.78), in: Capsule(style: .continuous))
            }

            Slider(value: scoreBinding, in: 0...100, step: 1)
                .tint(accent)

            Text(selection.subtitle)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(OunjePalette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(OunjePalette.elevated)
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(OunjePalette.stroke, lineWidth: 1)
                )
        )
    }
}

struct OnboardingAutonomyCard: View {
    let title: String
    let subtitle: String
    let isSelected: Bool
    let isLocked: Bool
    let accent: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: isLocked ? "lock.fill" : (isSelected ? "checkmark.seal.fill" : "circle"))
                    .font(.system(size: 18, weight: .black))
                    .foregroundStyle(isSelected ? .black : OunjePalette.primaryText)
                    .frame(width: 42, height: 42)
                    .background(
                        RoundedRectangle(cornerRadius: 15, style: .continuous)
                            .fill(isSelected ? accent.opacity(0.82) : Color.white.opacity(0.08))
                    )

                VStack(alignment: .leading, spacing: 5) {
                    Text(title)
                        .font(.system(size: 15, weight: .black))
                        .foregroundStyle(OunjePalette.primaryText)
                    Text(subtitle)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(OunjePalette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }
            .padding(13)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(isSelected ? accent.opacity(0.18) : OunjePalette.elevated)
                    .overlay(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .stroke(isSelected ? accent.opacity(0.7) : OunjePalette.stroke, lineWidth: 1.2)
                    )
            )
            .scaleEffect(isSelected ? 1.015 : 1)
            .animation(OunjeMotion.quickSpring, value: isSelected)
        }
        .buttonStyle(OunjeCardPressButtonStyle())
    }
}

struct OnboardingAutonomyLaneRow: View {
    let title: String
    let subtitle: String
    let isSelected: Bool
    let isLocked: Bool
    let accent: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: isLocked ? "lock.fill" : (isSelected ? "checkmark.circle.fill" : "circle"))
                    .font(.system(size: 18, weight: .black))
                    .foregroundStyle(isSelected ? accent : OunjePalette.primaryText.opacity(isLocked ? 0.42 : 0.8))
                    .frame(width: 24, height: 24)
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(OunjePalette.primaryText)

                    Text(subtitle)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(OunjePalette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }
            .padding(.vertical, 12)
            .contentShape(Rectangle())
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill((isSelected ? accent : OunjePalette.stroke).opacity(isSelected ? 0.9 : 0.68))
                    .frame(height: isSelected ? 1.4 : 1)
            }
            .scaleEffect(isSelected ? 1.01 : 1)
            .animation(OunjeMotion.quickSpring, value: isSelected)
        }
        .buttonStyle(OunjeCardPressButtonStyle())
    }
}

struct OnboardingSummaryRow: View {
    let symbol: String
    let title: String
    let detail: String
    let accent: Color

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .black))
                .foregroundStyle(.black)
                .frame(width: 38, height: 38)
                .background(accent.opacity(0.8), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 14, weight: .black))
                    .foregroundStyle(OunjePalette.primaryText)
                Text(detail)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(OunjePalette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(OunjePalette.elevated)
        )
    }
}

private func onboardingEmoji(for value: String) -> String? {
    let lowered = value.lowercased()

    if lowered.contains("omnivore") { return "🍽" }
    if lowered.contains("halal") || lowered.contains("kosher") { return "🛡" }
    if lowered.contains("vegetarian") || lowered.contains("vegan") { return "🌿" }
    if lowered.contains("pescatarian") || lowered.contains("seafood") || lowered.contains("salmon") { return "🐟" }
    if lowered.contains("gluten") { return "🌾" }
    if lowered.contains("dairy") { return "🥛" }
    if lowered.contains("protein") || lowered.contains("macros") { return "💪" }
    if lowered.contains("speed") { return "⚡️" }
    if lowered.contains("taste") { return "😋" }
    if lowered.contains("cost") { return "💸" }
    if lowered.contains("variety") { return "🎲" }
    if lowered.contains("family") { return "👥" }
    if lowered.contains("cleanup") { return "🧼" }
    if lowered.contains("repeat") { return "🔁" }
    if lowered.contains("rice") || lowered.contains("jollof") || lowered.contains("biryani") { return "🍚" }
    if lowered.contains("chicken") { return "🍗" }
    if lowered.contains("pasta") { return "🍝" }
    if lowered.contains("taco") || lowered.contains("burrito") { return "🌮" }
    if lowered.contains("salad") { return "🥗" }
    if lowered.contains("wrap") { return "🌯" }
    if lowered.contains("stir") { return "🥢" }
    if lowered.contains("mushroom") { return "🍄" }
    if lowered.contains("olive") { return "🫒" }
    if lowered.contains("tofu") { return "🧈" }
    return nil
}
