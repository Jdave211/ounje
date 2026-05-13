import SwiftUI
import Foundation

struct FirstLoginOnboardingView: View {
    @EnvironmentObject private var store: MealPlanningAppStore
    @EnvironmentObject private var toastCenter: AppToastCenter
    @AppStorage("ounje.selectedPricingTier") private var selectedTierRawValue = "free"
    @AppStorage(RecipeTypographyStyle.storageKey) private var recipeTypographyStyleRawValue = RecipeTypographyStyle.defaultStyle.rawValue

    @StateObject private var onboardingSavedStore = SavedRecipesStore(toastCenter: AppToastCenter())
    @State private var currentStep: SetupStep = .identity
    @State private var preferredName = ""
    @State private var selectedFoodPersona = ""
    @State private var selectedFoodChallenges = Set<String>()
    @State private var selectedDietaryPatterns = Set<String>()
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
    @State private var isOtherAllergyPromptPresented = false
    @State private var otherAllergyInput = ""
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
    @State private var orderingAutonomy: OrderingAutonomyLevel = .suggestOnly
    @State private var isSaving = false
    @State private var isPaywallPresented = false
    @State private var hasCompletedOnboardingBeforePaywall = false
    @State private var paywallInitialTier: OunjePricingTier? = nil
    @State private var pendingCompletedOnboardingProfile: UserProfile?
    @State private var pendingCompletedOnboardingStep: Int?
    @StateObject private var onboardingProvidersViewModel = GroceryProvidersViewModel()
    @State private var selectedOnboardingProvider: GroceryProviderInfo?
    @State private var presetSelectionPulseID = 0
    @State private var identityStepAnchorBaseline: CGFloat?
    @State private var hasUnlockedIdentityCTA = false
    @State private var presetSelectionPulseTask: Task<Void, Never>?
    @State private var briefPrefetchTask: Task<Void, Never>?
    @State private var stepTransitionDirection = 1
    @State private var hasHydratedStoredDraft = false
    @State private var solutionAnimationVisible = false
    @State private var solutionAnimationExiting = false
    @State private var solutionTypedCharacterCount = 0
    @State private var solutionHelpVisibleCount = 0
    @State private var completedSolutionAnimationSteps = Set<Int>()
    @State private var solutionRevealTask: Task<Void, Never>?
    @State private var introAutoAdvanceTask: Task<Void, Never>?
    @State private var onboardingAutoAdvanceTask: Task<Void, Never>?
    @State private var recipeUpgradeIntroTextVisible = false
    @State private var recipeUpgradeIntroTextExiting = false
    @State private var recipeStylePreviewRecipe: DiscoverRecipeCardData?
    @State private var isRecipeStylePreviewLoading = false
    @State private var recipeEditDemoRecipes: [OnboardingRecipeEditDemoRecipe] = []
    @State private var isRecipeEditDemoLoading = false
    @State private var selectedRecipeEditDemoRecipe: OnboardingRecipeEditDemoRecipe?
    @State private var hasCompletedRecipeEditDemo = false
    @State private var didChooseRecipeTypographyStyle = false
    @State private var shouldUseBudgetGuardrail = false
    @FocusState private var isBudgetFieldFocused: Bool

    // shareImport step — the hands-on "send Ounje a recipe" demo. We capture
    // the user's pasted link, the in-flight import state, and a status
    // message so the step can show a success / error confirmation without
    // navigating away.
    @State private var shareImportDraftLink: String = ""
    @State private var isSubmittingShareImport: Bool = false
    @State private var didQueueShareImport: Bool = false
    @State private var shareImportStatusMessage: String? = nil
    @FocusState private var isShareImportFieldFocused: Bool

    private let recipeStylePreviewRecipeID = "8c02aaff-33cd-4927-8c81-aae45e015c0d"
    private let foodGoalSelectionLimit = 3

    private let dietaryPatternOptions = [
        "Vegetarian",
        "Keto",
        "Gluten-free",
        "Dairy-free"
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

    private let foodPersonaOptions = [
        "Student",
        "Early professional",
        "Parent",
        "Home cook"
    ]

    private let foodChallengeOptions = [
        "Cook new things",
        "Spend less on groceries",
        "Save time & energy shopping",
        "Eat less takeout",
        "Stick to a diet",
        "Find good eats",
        "Learn to cook better"
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
        "Dairy",
        "Shellfish",
        "Other"
    ]

    private var allergyChipColumns: [GridItem] {
        [
            GridItem(.flexible(), spacing: 12)
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

    private var selectedFoodChallengeList: [String] {
        foodChallengeOptions.filter { selectedFoodChallenges.contains($0) }
    }

    private var selectedDietaryPatternList: [String] {
        dietaryPatternOptions.filter { selectedDietaryPatterns.contains($0) }
    }

    private var solutionProfile: OnboardingSolutionProfile {
        let persona = selectedFoodPersona.isEmpty ? "you" : selectedFoodPersona.lowercased()
        let personaPhrase: String

        switch persona {
        case "student":
            personaPhrase = "students like you"
        case "early professional":
            personaPhrase = "early professionals like you"
        case "parent":
            personaPhrase = "parents like you"
        case "home cook":
            personaPhrase = "home cooks like you"
        case "fitness-focused", "gym bro":
            personaPhrase = "fitness-focused people like you"
        default:
            personaPhrase = "cooks like you"
        }

        let primaryChallenge = selectedFoodChallengeList.first ?? "Save time & energy shopping"
        let reviewerNames = ["Naomi O.", "Khalid I.", "Ava F.", "John E.", "Brian M."]
        let reviewerIndex = abs((selectedFoodPersona + primaryChallenge).hashValue) % reviewerNames.count

        switch primaryChallenge {
        case "Spend less on groceries", "Eat less takeout":
            return OnboardingSolutionProfile(
                headline: "Ounje was made for\n\(personaPhrase)",
                subtitle: "Turn cravings into cheaper preps, smarter swaps, and carts that waste less.",
                metrics: [
                    .init(value: "AI", label: "CHEAPER SWAPS"),
                    .init(value: "1", label: "SMART CART"),
                    .init(value: "0", label: "WASTED EXTRAS")
                ],
                reviewer: reviewerNames[reviewerIndex],
                review: "Ounje helped me keep the food I actually wanted, then found cheaper ways to shop it."
            )
        case "Learn to cook better":
            return OnboardingSolutionProfile(
                headline: "Ounje was made for\n\(personaPhrase)",
                subtitle: "Import recipes, ask for simpler steps, and learn by cooking food you already want.",
                metrics: [
                    .init(value: "AI", label: "STEP EDITS"),
                    .init(value: "ANY", label: "RECIPE SOURCE"),
                    .init(value: "1", label: "COOKABLE PLAN")
                ],
                reviewer: reviewerNames[reviewerIndex],
                review: "I stopped guessing. Ounje made recipes feel doable without making them boring."
            )
        case "Cook new things", "Find good eats":
            return OnboardingSolutionProfile(
                headline: "Ounje was made for\n\(personaPhrase)",
                subtitle: "Pull food from TikTok, Instagram, photos, and Discover so prep stops repeating itself.",
                metrics: [
                    .init(value: "TT", label: "TO RECIPE"),
                    .init(value: "IG", label: "TO PREP"),
                    .init(value: "AI", label: "NEW VARIATIONS")
                ],
                reviewer: reviewerNames[reviewerIndex],
                review: "My saved videos finally became meals instead of sitting in a folder forever."
            )
        case "Save time & energy shopping":
            return OnboardingSolutionProfile(
                headline: "Ounje was made for\n\(personaPhrase)",
                subtitle: "Ounje plans the prep, builds the shop list, and can fill Instacart when you choose.",
                metrics: [
                    .init(value: "1", label: "PREP PLAN"),
                    .init(value: "1", label: "SHOP LIST"),
                    .init(value: "YOU", label: "APPROVE BUYING")
                ],
                reviewer: reviewerNames[reviewerIndex],
                review: "The cart was the part I always avoided. Ounje got it ready without buying anything for me."
            )
        case "Stick to a diet":
            return OnboardingSolutionProfile(
                headline: "Ounje was made for\n\(personaPhrase)",
                subtitle: "Save any recipe, then ask Ounje to make it fit the way you eat.",
                metrics: [
                    .init(value: "AI", label: "RECIPE EDITS"),
                    .init(value: "ANY", label: "DIET STYLE"),
                    .init(value: "1", label: "CONNECTED PREP")
                ],
                reviewer: reviewerNames[reviewerIndex],
                review: "I could keep the food I liked and still make it match how I wanted to eat."
            )
        default:
            return OnboardingSolutionProfile(
                headline: "Ounje was made for\n\(personaPhrase)",
                subtitle: "Save what looks good, let Ounje plan the prep, and keep the cart connected to your week.",
                metrics: [
                    .init(value: "AI", label: "MEAL PLANS"),
                    .init(value: "4+", label: "LINKED RECIPES"),
                    .init(value: "1", label: "GROCERY LIST")
                ],
                reviewer: reviewerNames[reviewerIndex],
                review: "It turned meal planning from a blank page into a plan I could actually follow."
            )
        }
    }

    private var solutionHelpItems: [(title: String, detail: String)] {
        let selected = Set(selectedFoodChallengeList)

        if selected.contains("Spend less on groceries") || selected.contains("Eat less takeout") {
            return [
                ("Make recipes cheaper", "Ask Ounje for swaps that keep the dish close without wasting your budget."),
                ("Plan recipes that overlap", "Your prep can share ingredients, so one shop list stretches further."),
                ("Build the cart when ready", "Ounje organizes the groceries; you still review before spending.")
            ]
        }

        if selected.contains("Learn to cook better") {
            return [
                ("Turn cravings into steps", "Import a recipe and get it cleaned into a cookable plan."),
                ("Rewrite what feels hard", "Ask Ounje to simplify, speed up, or adjust the method."),
                ("Cook from your taste", "Learn through food you already want to eat.")
            ]
        }

        if selected.contains("Cook new things") || selected.contains("Find good eats") {
            return [
                ("Pull food from anywhere", "Save TikTok, Instagram, YouTube, Discover, or a food photo."),
                ("Make it fit your week", "Ounje turns inspiration into recipes, prep, and servings."),
                ("Keep the rotation fresh", "Ask for spicy, lighter, high-protein, or totally new versions.")
            ]
        }

        if selected.contains("Save time & energy shopping") {
            return [
                ("Start from one good idea", "Ounje turns saved recipes into a full prep plan."),
                ("Collapse it into one list", "Ingredients merge into a smarter grocery list automatically."),
                ("Shop only when you choose", "Autoshop can fill Instacart, but you always approve checkout.")
            ]
        }

        if selected.contains("Stick to a diet") {
            return [
                ("Keep the recipe", "Ask Ounje to adapt meals without losing the original idea."),
                ("Respect your rules", "Diet choices and allergies stay attached to your profile."),
                ("Plan from there", "Edited recipes can go straight into prep and the grocery list.")
            ]
        }

        return [
            ("Save the food you want", "From social videos, Discover, or photos."),
            ("Let Ounje shape the prep", "Recipes, servings, and grocery logic stay connected."),
            ("Cook with less planning", "You focus on the kitchen; Ounje handles the busywork.")
        ]
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
        GeometryReader { proxy in
            ZStack {
                onboardingLessonBackground
                onboardingStepContentLayer(
                    topSafeArea: proxy.safeAreaInsets.top,
                    bottomSafeArea: proxy.safeAreaInsets.bottom
                )
                onboardingChromeLayer(
                    topSafeArea: proxy.safeAreaInsets.top,
                    bottomSafeArea: proxy.safeAreaInsets.bottom
                )

                if OunjeLaunchFlags.paywallsEnabled && isPaywallPresented {
                    onboardingPaywallPage
                        .transition(.asymmetric(
                            insertion: .move(edge: .trailing).combined(with: .opacity),
                            removal: .opacity
                        ))
                        .zIndex(10)
                }
            }
        }
        .ignoresSafeArea(.container, edges: .all)
        .environmentObject(onboardingSavedStore)
        .tint(currentStepAccent)
        .preferredColorScheme(.dark)
        .task(id: store.authSession?.userID ?? "signed-out") {
            await onboardingSavedStore.bootstrap(authSession: store.authSession)
        }
        .onChange(of: currentStep) { newStep in
            introAutoAdvanceTask?.cancel()
            onboardingAutoAdvanceTask?.cancel()
            schedulePresetSelectionPulse()
            if newStep == .solution {
                scheduleSolutionTypewriterTransition()
            }
            if newStep == .solutionWays {
                scheduleSolutionWaysTransition()
            }
            if newStep == .recipeEditIntro {
                scheduleRecipeUpgradeIntroAdvance()
            }
            if newStep == .recipeEditDemo {
                Task {
                    await loadRecipeEditDemoIfNeeded()
                }
            }
            if newStep == .paywallIntro {
                schedulePaywallIntroPresentation()
            }
            persistDraftForResume(step: newStep)
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
        .onChange(of: isPaywallPresented) { isPresented in
            if !isPresented {
                completePendingOnboardingAfterPaywall()
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
            loadOnboardingProviders()
            schedulePresetSelectionPulse()
            if currentStep == .solution {
                scheduleSolutionTypewriterTransition()
            }
            if currentStep == .solutionWays {
                scheduleSolutionWaysTransition()
            }
            if currentStep == .recipeEditIntro {
                scheduleRecipeUpgradeIntroAdvance()
            }
            if currentStep == .recipeEditDemo {
                Task {
                    await loadRecipeEditDemoIfNeeded()
                }
            }
            if currentStep == .paywallIntro {
                schedulePaywallIntroPresentation()
            }
        }
        .onDisappear {
            presetSelectionPulseTask?.cancel()
            solutionRevealTask?.cancel()
            introAutoAdvanceTask?.cancel()
            onboardingAutoAdvanceTask?.cancel()
            briefPrefetchTask?.cancel()
            persistDraftLocally()
        }
        .alert("Other allergy", isPresented: $isOtherAllergyPromptPresented) {
            TextField("Type allergy", text: $otherAllergyInput)
                .textInputAutocapitalization(.words)
            Button("Add") {
                addOtherAllergy()
            }
            Button("Cancel", role: .cancel) {
                otherAllergyInput = ""
            }
        } message: {
            Text("Add anything Ounje should always avoid.")
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
                userId: store.authSession?.userID ?? store.resolvedTrackingSession?.userID ?? "",
                accessToken: store.authSession?.accessToken,
                onConnected: {
                    loadOnboardingProviders()
                    selectedOnboardingProvider = nil
                }
            )
        }
        .fullScreenCover(item: $selectedRecipeEditDemoRecipe) { demoRecipe in
            RecipeDetailExperienceView(
                presentedRecipe: PresentedRecipeDetail(
                    recipeCard: demoRecipe.card,
                    initialDetail: demoRecipe.detail
                ),
                onOpenCart: {},
                toastCenter: toastCenter,
                onDismiss: {
                    selectedRecipeEditDemoRecipe = nil
                },
                onboardingContext: .baseDemo(
                    demoRecipe: demoRecipe,
                    selectedDietaryPatterns: selectedDietaryPatterns,
                    onComplete: completeRecipeEditDemo
                )
            )
            .environmentObject(onboardingSavedStore)
            .environmentObject(store)
        }
    }

    private var onboardingPaywallPage: some View {
        OunjePaywallHostView(
            initialTier: paywallInitialTier,
            isDismissible: false,
            onClose: {
                withAnimation(.spring(response: 0.36, dampingFraction: 0.86)) {
                    isPaywallPresented = false
                }
            },
            onUpgradeSuccess: {
                completePendingOnboardingAfterPaywall()
            }
        )
        .environmentObject(store)
        .ignoresSafeArea()
    }

    private func onboardingStepContentLayer(topSafeArea: CGFloat, bottomSafeArea: CGFloat) -> some View {
        let protectedTopInset = onboardingProtectedTopInset(topSafeArea)

        return VStack(alignment: .leading, spacing: 16) {
            currentStepContent
                .transition(stepTransition)
        }
        .id(currentStep)
        .padding(.horizontal, usesIntroChoiceLayout ? 22 : OunjeLayout.screenHorizontalPadding)
        .padding(.top, protectedTopInset + onboardingTopChromeHeight + (usesIntroChoiceLayout ? 0 : 8))
        .padding(.bottom, bottomSafeArea + onboardingBottomChromeHeight + (usesIntroChoiceLayout ? 0 : 18))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func onboardingChromeLayer(topSafeArea: CGFloat, bottomSafeArea: CGFloat) -> some View {
        VStack(spacing: 0) {
            onboardingTopChrome(topSafeArea: topSafeArea)
            Spacer(minLength: 0)
            onboardingBottomChrome(bottomSafeArea: bottomSafeArea)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func onboardingTopChrome(topSafeArea: CGFloat) -> some View {
        onboardingLessonHeader
            .padding(.top, onboardingProtectedTopInset(topSafeArea))
            .background(OunjePalette.background.ignoresSafeArea(edges: .top))
    }

    private func onboardingBottomChrome(bottomSafeArea: CGFloat) -> some View {
        onboardingLessonFooter
            .padding(.bottom, usesIntroChoiceLayout ? 0 : bottomSafeArea)
            .background(OunjePalette.background.ignoresSafeArea(edges: .bottom))
    }

    private var onboardingTopChromeHeight: CGFloat {
        usesIntroChoiceLayout ? 58 : 44
    }

    private var onboardingBottomChromeHeight: CGFloat {
        usesIntroChoiceLayout ? 0 : 74
    }

    private func onboardingProtectedTopInset(_ topSafeArea: CGFloat) -> CGFloat {
        max(topSafeArea, 64)
    }

    private var onboardingLessonBackground: some View {
        ZStack {
            OunjePalette.background
                .ignoresSafeArea()
        }
    }

    @ViewBuilder
    private var onboardingLessonHeader: some View {
        if usesIntroChoiceLayout {
            introOnboardingHeader
        } else {
            standardOnboardingHeader
        }
    }

    private var standardOnboardingHeader: some View {
        HStack(spacing: 12) {
            onboardingProgressBar(progress: lessonProgress)

            Text("\(currentStep.index + 1)/\(SetupStep.allCases.count)")
                .font(.custom("Slee_handwritting-Regular", size: 17))
                .foregroundStyle(OunjePalette.secondaryText)
                .monospacedDigit()
        }
        .padding(.horizontal, OunjeLayout.screenHorizontalPadding)
        .frame(height: onboardingTopChromeHeight, alignment: .center)
        .background(
            OunjePalette.background
                .ignoresSafeArea(edges: .top)
        )
    }

    private var introOnboardingHeader: some View {
        HStack(spacing: 12) {
            Button {
                goBack()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(OunjePalette.primaryText.opacity(currentStep.previous == nil ? 0.2 : 0.9))
                    .frame(width: 30, height: 30)
                    .frame(width: 56, height: 56)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(currentStep.previous == nil)

            onboardingProgressBar(progress: introProgressFraction)
                .frame(maxWidth: .infinity)

            Button {
                handleIntroHeaderAction()
            } label: {
                Text(introHeaderActionTitle)
                    .font(.system(size: 17, weight: .black, design: .rounded))
                    .foregroundStyle(OunjePalette.primaryText.opacity(0.88))
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
                    .frame(width: 98, height: 34, alignment: .trailing)
            }
            .buttonStyle(.plain)
            .disabled(introHeaderActionTitle.isEmpty)
        }
        .padding(.horizontal, 22)
        .frame(height: onboardingTopChromeHeight, alignment: .center)
        .background(OunjePalette.background.ignoresSafeArea(edges: .top))
    }

    private func onboardingProgressBar(progress: CGFloat) -> some View {
        GeometryReader { proxy in
            let segmentCount = SetupStep.allCases.count
            let clampedProgress = min(max(progress, 0), 1)

            ZStack(alignment: .leading) {
                HStack(spacing: 5) {
                    ForEach(0..<segmentCount, id: \.self) { _ in
                        Capsule(style: .continuous)
                            .fill(Color.white.opacity(0.13))
                    }
                }

                Capsule(style: .continuous)
                    .fill(currentStepAccent)
                    .frame(width: max(clampedProgress > 0 ? 8 : 0, proxy.size.width * clampedProgress))
                    .animation(.spring(response: 0.34, dampingFraction: 0.86), value: clampedProgress)
            }
        }
        .frame(height: 4)
    }

    private var introProgressFraction: CGFloat {
        CGFloat(currentStep.index + 1) / CGFloat(max(1, SetupStep.allCases.count))
    }

    private var introHeaderActionTitle: String {
        if currentStep == .recipeEditIntro || currentStep == .paywallIntro {
            return ""
        }

        if currentStep == .address {
            return isOnboardingInstacartConnected ? "Continue" : "Do later"
        }

        if currentStep == .recipeEditDemo {
            return hasCompletedRecipeEditDemo ? "Continue" : ""
        }

        if (currentStep == .challenge && !selectedFoodChallenges.isEmpty) ||
            (currentStep == .allergies && !parsedAllergies.isEmpty) ||
            (currentStep == .diets && !selectedDietaryPatterns.isEmpty) ||
            (currentStep == .ordering && orderingAutonomy == .approvalRequired) ||
            (currentStep == .budget && shouldUseBudgetGuardrail) ||
            (currentStep == .recipeStyle && didChooseRecipeTypographyStyle) {
            return "Continue"
        }

        return "Skip"
    }

    @ViewBuilder
    private var onboardingLessonFooter: some View {
        if usesIntroChoiceLayout {
            EmptyView()
        } else {
            standardOnboardingFooter
        }
    }

    private var introContinueFooter: some View {
        Button {
            advance()
        } label: {
            Text("Continue")
                .font(.system(size: 16, weight: .black, design: .rounded))
                .foregroundStyle(.black)
                .frame(maxWidth: .infinity)
                .frame(height: 56)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(currentStepAccent)
                )
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 22)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .background(OunjePalette.background.ignoresSafeArea(edges: .bottom))
    }

    private var standardOnboardingFooter: some View {
        HStack(spacing: 10) {
            if currentStep.previous != nil {
                Button {
                    goBack()
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

    private var usesIntroChoiceLayout: Bool {
        currentStep == .identity ||
        currentStep == .challenge ||
        currentStep == .solution ||
        currentStep == .solutionWays ||
        currentStep == .recipeStyle ||
        currentStep == .allergies ||
        currentStep == .diets ||
        currentStep == .recipeEditIntro ||
        currentStep == .recipeEditDemo ||
        currentStep == .paywallIntro ||
        currentStep == .budget ||
        currentStep == .ordering ||
        currentStep == .address
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

    @ViewBuilder
    private var currentStepContent: some View {
        switch currentStep {
        case .identity:
            identityStepContent
        case .challenge:
            challengeStepContent
        case .solution:
            solutionStepContent
        case .solutionWays:
            solutionWaysStepContent
        case .recipeStyle:
            recipeStyleStepContent
        case .allergies:
            allergyStepContent
        case .diets:
            dietStepContent
        case .recipeEditIntro:
            recipeUpgradeIntroStepContent
        case .recipeEditDemo:
            recipeEditDemoStepContent
        case .shareImport:
            shareImportStepContent
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
        case .paywallIntro:
            paywallIntroStepContent
        }
    }

    private var identityStepContent: some View {
        onboardingStackedChoicePage(
            title: "What best describes you?",
            options: foodPersonaOptions,
            selection: selectedFoodPersona
        ) { option in
            withAnimation(.spring(response: 0.24, dampingFraction: 0.82)) {
                selectedFoodPersona = option
            }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            persistDraft()
            advanceIntroChoice(after: 0.12)
        }
    }

    private var challengeStepContent: some View {
        introQuestionLayout {
            Text("What food goals do you have?")
                .font(.system(size: 31, weight: .black, design: .rounded))
                .foregroundStyle(OunjePalette.primaryText)
                .multilineTextAlignment(.center)
                .lineSpacing(-1)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 324)

            Text("\(selectedFoodChallenges.count)/\(foodGoalSelectionLimit)")
                .font(.system(size: 12, weight: .black, design: .rounded))
                .foregroundStyle(selectedFoodChallenges.isEmpty ? OunjePalette.secondaryText : currentStepAccent)

            VStack(spacing: introOptionSpacing(for: foodChallengeOptions.count)) {
                ForEach(foodChallengeOptions, id: \.self) { option in
                    OnboardingIntroChoiceButton(
                        title: option,
                        isSelected: selectedFoodChallenges.contains(option),
                        accent: currentStepAccent
                    ) {
                        toggleFoodChallenge(option)
                    }
                }
            }
            .frame(maxWidth: 352)
        }
    }

    private var dietStepContent: some View {
        introQuestionLayout {
            Text("Any diets?")
                .font(.system(size: 33, weight: .black, design: .rounded))
                .foregroundStyle(OunjePalette.primaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 306)

            VStack(spacing: introOptionSpacing(for: dietaryPatternOptions.count)) {
                ForEach(dietaryPatternOptions, id: \.self) { option in
                    OnboardingIntroChoiceButton(
                        title: option,
                        isSelected: selectedDietaryPatterns.contains(option),
                        accent: currentStepAccent
                    ) {
                        toggleDietaryPattern(option)
                    }
                }
            }
            .frame(maxWidth: 352)
        }
    }

    private var recipeUpgradeIntroStepContent: some View {
        VStack {
            Spacer(minLength: 0)

            Text("Upgrade any recipe to fit you")
                .font(.system(size: 35, weight: .black, design: .rounded))
                .foregroundStyle(OunjePalette.primaryText)
                .multilineTextAlignment(.center)
                .lineSpacing(-1)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 340)
                .opacity(recipeUpgradeIntroTextVisible ? 1 : 0)
                .offset(x: recipeUpgradeIntroTextExiting ? 110 : (recipeUpgradeIntroTextVisible ? 0 : -40))
                .scaleEffect(recipeUpgradeIntroTextVisible && !recipeUpgradeIntroTextExiting ? 1 : 0.96)
                .animation(.spring(response: 0.34, dampingFraction: 0.84), value: recipeUpgradeIntroTextVisible)
                .animation(.easeInOut(duration: 0.28), value: recipeUpgradeIntroTextExiting)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private var recipeEditDemoStepContent: some View {
        VStack(spacing: 12) {
            Text("Pick a recipe to upgrade")
                .font(.system(size: 31, weight: .black, design: .rounded))
                .foregroundStyle(OunjePalette.primaryText)
                .multilineTextAlignment(.center)
                .lineSpacing(-1)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 320)

            Text("Choose one card and Ounje will walk you through a guided recipe edit.")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(OunjePalette.secondaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 320)

            if isRecipeEditDemoLoading && recipeEditDemoRecipes.isEmpty {
                VStack(spacing: 14) {
                    ProgressView()
                        .tint(currentStepAccent)
                    Text("Loading demo recipes")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(OunjePalette.secondaryText)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 40)
            } else if recipeEditDemoRecipes.isEmpty {
                VStack(spacing: 14) {
                    Text("We couldn't load the demo right now.")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(OunjePalette.primaryText)

                    Button {
                        Task {
                            await loadRecipeEditDemoIfNeeded(forceRefresh: true)
                        }
                    } label: {
                        Text("Try again")
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 18)
                            .frame(height: 42)
                            .background(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(currentStepAccent)
                            )
                    }
                    .buttonStyle(.plain)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 40)
            } else {
                OnboardingRecipeEditDemoPickerGrid(
                    recipes: recipeEditDemoRecipes,
                    onSelect: openRecipeEditDemo
                )
                .frame(maxWidth: 360)
                .padding(.top, 6)
            }
        }
        .padding(.top, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var paywallIntroStepContent: some View {
        OnboardingMinimalTransitionPage(title: "One last thing")
        .onAppear(perform: schedulePaywallIntroPresentation)
    }

    /// Hands-on "send Ounje a recipe" step. Shows the three sharing surfaces
    /// (TikTok / Instagram / camera roll) plus an inline link composer so the
    /// user can actually kick off a real import job from inside onboarding.
    /// The job runs in the background; the user can advance immediately and
    /// will get an APNs push when the recipe is ready.
    private var shareImportStepContent: some View {
        VStack(spacing: 18) {
            Text("Send recipes from anywhere")
                .font(.system(size: 28, weight: .black, design: .rounded))
                .foregroundStyle(OunjePalette.primaryText)
                .multilineTextAlignment(.center)
                .lineSpacing(-1)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 320)

            Text("Tap **Share** on a TikTok or Instagram post, snap a photo of a dish, or paste any recipe link — Ounje turns it into a cookbook card you can actually cook.")
                .font(.system(size: 14.5, weight: .medium))
                .foregroundStyle(OunjePalette.secondaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 320)

            shareImportFlowChips

            shareImportComposer

            // Inline confirmation strip — replaces the toast / banner so the
            // user sees the state right where they tapped.
            if let message = shareImportStatusMessage {
                Label {
                    Text(message)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(OunjePalette.primaryText)
                        .multilineTextAlignment(.leading)
                } icon: {
                    Image(systemName: didQueueShareImport ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .foregroundStyle(didQueueShareImport ? Color.green : Color.orange)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: 320, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(OunjePalette.panel.opacity(0.6))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(OunjePalette.stroke.opacity(0.5), lineWidth: 1)
                        )
                )
                .transition(.opacity)
            }
        }
        .padding(.top, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.easeInOut(duration: 0.2), value: shareImportStatusMessage)
    }

    /// Three pill chips showing the share surfaces. Visual only — taps don't
    /// do anything (the iOS share sheet can't be simulated from inside the
    /// app). They exist to anchor users' mental model of what's possible.
    private var shareImportFlowChips: some View {
        HStack(spacing: 10) {
            shareImportFlowChip(symbol: "music.note", label: "TikTok")
            shareImportFlowChip(symbol: "camera.fill", label: "Photos")
            shareImportFlowChip(symbol: "link", label: "Any link")
        }
        .frame(maxWidth: 320)
    }

    private func shareImportFlowChip(symbol: String, label: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(currentStepAccent)
            Text(label)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(OunjePalette.primaryText)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(OunjePalette.panel.opacity(0.5))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(OunjePalette.stroke.opacity(0.5), lineWidth: 1)
                )
        )
    }

    /// Inline composer card: textfield + Send button + "Try a sample" link.
    private var shareImportComposer: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Try it now")
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(OunjePalette.primaryText)

            HStack(spacing: 8) {
                Image(systemName: "link")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(OunjePalette.secondaryText)
                TextField("Paste a TikTok or recipe link", text: $shareImportDraftLink)
                    .font(.system(size: 14, weight: .medium))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .keyboardType(.URL)
                    .focused($isShareImportFieldFocused)
                    .submitLabel(.send)
                    .onSubmit { Task { await submitShareImportDraft() } }
            }
            .padding(.horizontal, 12)
            .frame(height: 44)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(OunjePalette.panel.opacity(0.8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(OunjePalette.stroke.opacity(0.6), lineWidth: 1)
                    )
            )

            HStack(spacing: 12) {
                Button {
                    // Sample TikTok-style link. The ingestion service handles
                    // a wide range of inputs so this is just to demonstrate
                    // the flow — even a plain recipe URL works.
                    shareImportDraftLink = "https://www.bonappetit.com/recipe/chicken-noodle-soup"
                    Task { await submitShareImportDraft() }
                } label: {
                    Label("Try a sample", systemImage: "wand.and.stars")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(OunjePalette.primaryText)
                }
                .buttonStyle(.plain)
                .disabled(isSubmittingShareImport)

                Spacer()

                Button {
                    Task { await submitShareImportDraft() }
                } label: {
                    HStack(spacing: 6) {
                        if isSubmittingShareImport {
                            ProgressView()
                                .controlSize(.mini)
                                .tint(.black)
                        }
                        Text(isSubmittingShareImport ? "Sending" : "Send")
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .foregroundStyle(.black)
                    }
                    .padding(.horizontal, 16)
                    .frame(height: 36)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(canSubmitShareImport ? currentStepAccent : currentStepAccent.opacity(0.35))
                    )
                }
                .buttonStyle(.plain)
                .disabled(!canSubmitShareImport)
            }
        }
        .padding(14)
        .frame(maxWidth: 320)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(OunjePalette.panel.opacity(0.35))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(OunjePalette.stroke.opacity(0.5), lineWidth: 1)
                )
        )
    }

    private var canSubmitShareImport: Bool {
        let trimmed = shareImportDraftLink.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && !isSubmittingShareImport
    }

    /// Sends the typed link to /v1/recipe/imports. The import runs in the
    /// background; we report status inline and let the user keep going.
    private func submitShareImportDraft() async {
        let trimmed = shareImportDraftLink.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isSubmittingShareImport else { return }
        isSubmittingShareImport = true
        defer { isSubmittingShareImport = false }
        isShareImportFieldFocused = false

        let session = await store.freshUserDataSession()
        let userID = session?.userID
        let accessToken = session?.accessToken

        do {
            _ = try await RecipeImportAPIService.shared.importRecipe(
                userID: userID,
                accessToken: accessToken,
                sourceURL: trimmed,
                sourceText: trimmed,
                targetState: "saved"
            )
            await MainActor.run {
                didQueueShareImport = true
                shareImportStatusMessage = "Got it — we'll let you know when your recipe is ready in your cookbook."
                shareImportDraftLink = ""
            }
        } catch {
            await MainActor.run {
                didQueueShareImport = false
                shareImportStatusMessage = "Couldn't send that link. You can also share recipes after setup — tap Share on any TikTok or recipe site and pick Ounje."
            }
        }
    }

    private struct OnboardingRecipeEditDemoPickerGrid: View {
        let recipes: [OnboardingRecipeEditDemoRecipe]
        let onSelect: (OnboardingRecipeEditDemoRecipe) -> Void

        private let spacing: CGFloat = 12
        private let layout: DiscoverRemoteRecipeCardLayout = .compact

        var body: some View {
            GeometryReader { proxy in
                let displayedRecipes = Array(recipes.prefix(4))
                let gridWidth = min(proxy.size.width, 360)
                let cardWidth = (gridWidth - spacing) / 2
                let gridHeight = (layout.cardHeight * 2) + spacing

                ZStack(alignment: .topLeading) {
                    LazyVGrid(
                        columns: [
                            GridItem(.fixed(cardWidth), spacing: spacing),
                            GridItem(.fixed(cardWidth), spacing: spacing)
                        ],
                        spacing: spacing
                    ) {
                        ForEach(displayedRecipes) { demoRecipe in
                            DiscoverRemoteRecipeCard(
                                recipe: demoRecipe.card,
                                showsSaveAction: false,
                                showsTopActions: false,
                                showsImageLoadingSkeleton: false,
                                layout: layout
                            ) {
                                onSelect(demoRecipe)
                            }
                            .frame(width: cardWidth, height: layout.cardHeight)
                        }
                    }
                    .frame(width: gridWidth, height: gridHeight, alignment: .top)

                    OnboardingRecipeCardCueOverlay(
                        cardCount: displayedRecipes.count,
                        cardWidth: cardWidth,
                        cardHeight: layout.cardHeight,
                        spacing: spacing
                    )
                }
                .frame(width: gridWidth, height: gridHeight, alignment: .topLeading)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .frame(height: (layout.cardHeight * 2) + spacing)
        }
    }

    private struct OnboardingRecipeCardCueOverlay: View {
        let cardCount: Int
        let cardWidth: CGFloat
        let cardHeight: CGFloat
        let spacing: CGFloat

        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var cueStep = 0

        private var sequence: [Int] {
            [0, 1, 3, 2].filter { $0 < cardCount }
        }

        var body: some View {
            if let cardIndex = sequence.isEmpty ? nil : sequence[cueStep % sequence.count] {
                let column = CGFloat(cardIndex % 2)
                let row = CGFloat(cardIndex / 2)
                let x = column * (cardWidth + spacing) + cardWidth * 0.78
                let y = row * (cardHeight + spacing) + cardHeight * 0.34

                OnboardingTapCueView()
                    .scaleEffect(0.9)
                    .position(x: x, y: y)
                    .animation(.spring(response: 0.62, dampingFraction: 0.76), value: cueStep)
                    .allowsHitTesting(false)
                    .task {
                        guard !reduceMotion, sequence.count > 1 else { return }
                        while !Task.isCancelled {
                            try? await Task.sleep(nanoseconds: 1_180_000_000)
                            cueStep += 1
                        }
                    }
                    .accessibilityHidden(true)
                }
            }
    }

    private var solutionStepContent: some View {
        let profile = solutionProfile

        return VStack {
            Spacer(minLength: 0)

            Text(solutionTypedHeadline(for: profile.headline))
                .font(.system(size: 34, weight: .black, design: .rounded))
                .foregroundStyle(OunjePalette.primaryText)
                .multilineTextAlignment(.center)
                .lineSpacing(-1)
                .lineLimit(nil)
                .minimumScaleFactor(0.88)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 356)
                .opacity(solutionTypedCharacterCount > 0 ? 1 : 0)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .onAppear(perform: scheduleSolutionTypewriterTransition)
    }

    private var solutionWaysStepContent: some View {
        let items = solutionHelpItems

        return VStack(spacing: 42) {
            Spacer(minLength: 0)

            Text("Here's how Ounje helps you")
                .font(.system(size: 33, weight: .black, design: .rounded))
                .foregroundStyle(OunjePalette.primaryText)
                .multilineTextAlignment(.center)

            VStack(alignment: .leading, spacing: 30) {
                ForEach(items.indices, id: \.self) { index in
                    HStack(alignment: .top, spacing: 18) {
                        Text(String(format: "%02d", index + 1))
                            .font(.system(size: 34, weight: .black, design: .rounded))
                            .foregroundStyle(currentStepAccent)
                            .frame(width: 58, alignment: .leading)

                        VStack(alignment: .leading, spacing: 7) {
                            Text(items[index].title)
                                .font(.system(size: 20, weight: .black, design: .rounded))
                                .foregroundStyle(OunjePalette.primaryText)

                            Text(items[index].detail)
                                .font(.system(size: 14, weight: .semibold, design: .rounded))
                                .foregroundStyle(OunjePalette.secondaryText)
                                .lineSpacing(3)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .opacity(solutionHelpVisibleCount > index ? 1 : 0)
                    .offset(x: solutionHelpVisibleCount > index ? 0 : 26)
                    .animation(.spring(response: 0.42, dampingFraction: 0.82), value: solutionHelpVisibleCount)
                }
            }
            .frame(maxWidth: 356, alignment: .leading)

            Spacer(minLength: 48)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .onAppear(perform: scheduleSolutionWaysTransition)
    }

    private var allergyStepContent: some View {
        introQuestionLayout {
            Text("Any allergies?")
                .font(.system(size: 33, weight: .black, design: .rounded))
                .foregroundStyle(OunjePalette.primaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 306)

            LazyVGrid(columns: allergyChipColumns, spacing: 14) {
                ForEach(allergyDisplayOptions, id: \.self) { option in
                    OnboardingIntroChoiceButton(
                        title: option,
                        isSelected: allergyListContains(option),
                        accent: currentStepAccent
                    ) {
                        toggleAllergy(option)
                    }
                }
            }
            .frame(maxWidth: 352)
        }
    }

    private var recipeStyleStepContent: some View {
        introQuestionLayout {
            VStack(spacing: 10) {
                Text("Choose your style")
                    .font(.system(size: 30, weight: .black, design: .rounded))
                    .foregroundStyle(OunjePalette.primaryText)
                    .multilineTextAlignment(.center)
                    .lineSpacing(-1)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 326)

                VStack(spacing: 8) {
                    Text("We added our team’s handwriting style to make recipes and cookbooks feel more personal.")

                    Text("Handwritten text can be harder to read for some people, so we also made a cleaner standard style.")
                }
                .font(.system(size: 14.5, weight: .semibold, design: .rounded))
                .foregroundStyle(OunjePalette.secondaryText)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 344)
            }

            let previewRecipe = recipeStylePreviewRecipe ?? staticRecipeStylePreviewRecipe

            HStack(spacing: 12) {
                ForEach([RecipeTypographyStyle.playful, .clean], id: \.self) { style in
                    OnboardingRecipeStylePreviewChoice(
                        recipe: previewRecipe,
                        style: style,
                        isSelected: didChooseRecipeTypographyStyle && selectedRecipeTypographyStyle == style,
                        accent: currentStepAccent
                    ) {
                        selectRecipeTypographyStyle(style)
                    }
                }
            }
            .frame(maxWidth: 352)
        }
        .task {
            await loadRecipeStylePreviewIfNeeded()
        }
    }

    private var staticRecipeStylePreviewRecipe: DiscoverRecipeCardData {
        DiscoverRecipeCardData(
            id: recipeStylePreviewRecipeID,
            title: "Crunchy Miso Salmon Bites",
            description: "Crunchy broiled miso salmon bites over rice.",
            authorName: "@kalejunkie",
            authorHandle: "@kalejunkie",
            category: "Dinner Recipes",
            recipeType: "Dinner",
            cookTimeText: "15 mins",
            cookTimeMinutes: 15,
            publishedDate: nil,
            imageURLString: nil,
            heroImageURLString: nil,
            recipeURLString: "https://withjulienne.com/days/2_3_2026/recipes/2828FDBC-B21A-4EC5-AB94-8CB4258B96AB",
            source: "withjulienne"
        )
    }

    private func selectRecipeTypographyStyle(_ style: RecipeTypographyStyle) {
        withAnimation(.spring(response: 0.24, dampingFraction: 0.82)) {
            recipeTypographyStyleRawValue = style.rawValue
            didChooseRecipeTypographyStyle = true
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        persistDraft()
        advanceIntroChoice(after: 0.16)
    }

    @MainActor
    private func loadRecipeStylePreviewIfNeeded() async {
        guard recipeStylePreviewRecipe == nil, !isRecipeStylePreviewLoading else { return }
        isRecipeStylePreviewLoading = true
        defer { isRecipeStylePreviewLoading = false }

        do {
            let detail = try await RecipeDetailService.shared.fetchRecipeDetail(id: recipeStylePreviewRecipeID)
            recipeStylePreviewRecipe = DiscoverRecipeCardData(
                id: detail.id,
                title: detail.title,
                description: detail.description,
                authorName: detail.authorName,
                authorHandle: detail.authorHandle,
                category: detail.category,
                recipeType: detail.recipeType,
                cookTimeText: detail.cookTimeText,
                cookTimeMinutes: detail.cookTimeMinutes,
                publishedDate: nil,
                imageURLString: detail.discoverCardImageURLString,
                heroImageURLString: detail.heroImageURLString,
                recipeURLString: detail.recipeURLString ?? detail.originalRecipeURLString,
                source: detail.source
            )
        } catch {
            print("[Onboarding] Failed to fetch recipe style preview: \(error.localizedDescription)")
        }
    }

    private func onboardingStackedChoicePage(
        title: String,
        options: [String],
        selection: String,
        onSelect: @escaping (String) -> Void
    ) -> some View {
        introQuestionLayout {
            Text(title)
                .font(.system(size: 33, weight: .black, design: .rounded))
                .foregroundStyle(OunjePalette.primaryText)
                .multilineTextAlignment(.center)
                .lineSpacing(-1)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 306)

            VStack(spacing: introOptionSpacing(for: options.count)) {
                ForEach(options, id: \.self) { option in
                    OnboardingIntroChoiceButton(
                        title: option,
                        isSelected: selection == option,
                        accent: currentStepAccent
                    ) {
                        onSelect(option)
                    }
                }
            }
            .frame(maxWidth: 352)
        }
    }

    private func introOptionSpacing(for optionCount: Int) -> CGFloat {
        optionCount < 5 ? 18 : 12
    }

    private func introQuestionLayout<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(spacing: 24) {
            content()
            Spacer(minLength: 40)
        }
        .padding(.top, 52)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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

                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), spacing: 8),
                        GridItem(.flexible(), spacing: 8)
                    ],
                    spacing: 8
                ) {
                    ForEach(cadenceDisplayOrder) { option in
                        Button {
                            withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
                                cadence = option
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(option.title)
                                    .font(.custom("Slee_handwritting-Regular", size: 19))
                                    .foregroundStyle(cadence == option ? .black : OunjePalette.primaryText)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.78)

                                Text(cadenceSubtitle(for: option))
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(cadence == option ? .black.opacity(0.62) : OunjePalette.secondaryText)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.78)
                            }
                            .padding(.horizontal, 12)
                            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .fill(cadence == option ? currentStepAccent : OunjePalette.elevated)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                                            .stroke(cadence == option ? currentStepAccent : currentStepAccent.opacity(0.22), lineWidth: 1)
                                    )
                            )
                        }
                        .buttonStyle(.plain)
                    }
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
        introQuestionLayout {
            VStack(spacing: 10) {
                Text("Should Ounje watch your budget?")
                    .font(.system(size: 31, weight: .black, design: .rounded))
                    .foregroundStyle(OunjePalette.primaryText)
                    .multilineTextAlignment(.center)
                    .lineSpacing(-1)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 326)

                Text("Turn this on if you want carts and swaps to stay price-aware.")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(OunjePalette.secondaryText)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .frame(maxWidth: 336)
            }

            Button {
                withAnimation(.spring(response: 0.26, dampingFraction: 0.84)) {
                    shouldUseBudgetGuardrail.toggle()
                    budgetWindow = .weekly
                }
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                persistDraft()
            } label: {
                HStack(spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(shouldUseBudgetGuardrail ? currentStepAccent : Color.white.opacity(0.13))
                            .frame(width: 62, height: 36)

                        Circle()
                            .fill(shouldUseBudgetGuardrail ? .black : Color.white.opacity(0.72))
                            .frame(width: 26, height: 26)
                            .offset(x: shouldUseBudgetGuardrail ? 13 : -13)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text(shouldUseBudgetGuardrail ? "Budget-aware carts" : "No budget guardrail")
                            .font(.system(size: 16, weight: .black, design: .rounded))
                            .foregroundStyle(OunjePalette.primaryText)
                        Text(shouldUseBudgetGuardrail ? "Ounje will plan with this weekly target in mind." : "Ounje will optimize for the recipe first.")
                            .font(.system(size: 13.5, weight: .semibold, design: .rounded))
                            .foregroundStyle(OunjePalette.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 0)
                }
                .padding(16)
                .frame(maxWidth: 352, minHeight: 88)
                .background(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(OunjePalette.elevated)
                        .overlay(
                            RoundedRectangle(cornerRadius: 22, style: .continuous)
                                .stroke(Color.white.opacity(0.28), lineWidth: 1.2)
                        )
                )
            }
            .buttonStyle(.plain)

            if shouldUseBudgetGuardrail {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .lastTextBaseline, spacing: 8) {
                        Text("$")
                            .font(.system(size: 44, weight: .black, design: .rounded))
                            .foregroundStyle(OunjePalette.primaryText)

                        TextField("", text: $budgetInput)
                            .keyboardType(.numberPad)
                            .submitLabel(.done)
                            .focused($isBudgetFieldFocused)
                            .font(.system(size: 44, weight: .black, design: .rounded))
                            .foregroundStyle(OunjePalette.primaryText)
                            .onTapGesture {
                                isBudgetFieldFocused = true
                            }
                            .onSubmit {
                                commitBudgetInput()
                                isBudgetFieldFocused = false
                            }
                            .frame(minWidth: 86)

                        Text("per week")
                            .font(.system(size: 16, weight: .bold, design: .rounded))
                            .foregroundStyle(OunjePalette.secondaryText)
                    }

                    Text("About \((budgetPerCycle * 4).asCurrency) monthly.")
                        .font(.system(size: 13.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(OunjePalette.secondaryText)

                    Slider(
                        value: Binding(
                            get: { budgetPerCycle },
                            set: { newValue in
                                budgetPerCycle = newValue
                                if !isBudgetFieldFocused {
                                    syncBudgetInput()
                                }
                            }
                        ),
                        in: budgetRange(for: .weekly),
                        step: 5
                    )
                        .tint(currentStepAccent)

                    HStack {
                        Text("$40")
                        Spacer()
                        Text("$500")
                    }
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(OunjePalette.secondaryText.opacity(0.8))
                }
                .padding(18)
                .frame(maxWidth: 352, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(Color.white.opacity(0.045))
                        .overlay(
                            RoundedRectangle(cornerRadius: 22, style: .continuous)
                                .stroke(Color.white.opacity(0.16), lineWidth: 1)
                        )
                )
            }
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
        introQuestionLayout {
            VStack(spacing: 10) {
                Text("Opt in to Autoshop?")
                    .font(.system(size: 33, weight: .black, design: .rounded))
                    .foregroundStyle(OunjePalette.primaryText)
                    .multilineTextAlignment(.center)
                    .lineSpacing(-1)
                    .frame(maxWidth: 326)

                Text("Ounje adds the right groceries to Instacart.")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(OunjePalette.secondaryText)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .frame(maxWidth: 336)
            }

            Button {
                let nextState: OrderingAutonomyLevel = orderingAutonomy == .approvalRequired ? .suggestOnly : .approvalRequired
                withAnimation(.spring(response: 0.26, dampingFraction: 0.84)) {
                    orderingAutonomy = nextState
                }
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                persistDraft()
                if nextState == .approvalRequired {
                    advanceIntroChoice(after: 0.14)
                }
            } label: {
                HStack(spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(orderingAutonomy == .approvalRequired ? currentStepAccent : Color.white.opacity(0.13))
                            .frame(width: 62, height: 36)

                        Circle()
                            .fill(orderingAutonomy == .approvalRequired ? .black : .white.opacity(0.8))
                            .frame(width: 28, height: 28)
                            .offset(x: orderingAutonomy == .approvalRequired ? 13 : -13)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("No purchase made ever. Just filling cart with best options.")
                            .font(.system(size: 15, weight: .black, design: .rounded))
                            .foregroundStyle(OunjePalette.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 0)
                }
                .padding(18)
                .frame(maxWidth: 352, minHeight: 92)
                .background(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(OunjePalette.elevated)
                        .overlay(
                            RoundedRectangle(cornerRadius: 22, style: .continuous)
                                .stroke(orderingAutonomy == .approvalRequired ? Color.black.opacity(0.9) : Color.white.opacity(0.38), lineWidth: orderingAutonomy == .approvalRequired ? 2.25 : 1.5)
                        )
                )
            }
            .buttonStyle(.plain)
        }
    }

    private var addressStepContent: some View {
        introQuestionLayout {
            Text("Connect Instacart")
                .font(.system(size: 33, weight: .black, design: .rounded))
                .foregroundStyle(OunjePalette.primaryText)
                .multilineTextAlignment(.center)
                .lineSpacing(-1)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 306)

            Text("Ounje fills your cart. You choose when to buy.")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(OunjePalette.secondaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 304)

            Button {
                openOnboardingInstacartConnection()
            } label: {
                HStack(spacing: 14) {
                    InstacartLogoMark()
                        .frame(width: 86, height: 36)

                    VStack(alignment: .leading, spacing: 5) {
                        Text(onboardingInstacartConnectionTitle)
                            .font(.system(size: 16, weight: .black, design: .rounded))
                            .foregroundStyle(OunjePalette.primaryText)
                        Text(onboardingInstacartConnectionSubtitle)
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundStyle(OunjePalette.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 12)

                    Image(systemName: isOnboardingInstacartConnected ? "checkmark.circle.fill" : "chevron.right")
                        .font(.system(size: isOnboardingInstacartConnected ? 19 : 13, weight: .bold))
                        .foregroundStyle(isOnboardingInstacartConnected ? currentStepAccent : OunjePalette.secondaryText)
                }
                .padding(16)
                .frame(maxWidth: 352, minHeight: 92, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(OunjePalette.elevated)
                        .overlay(
                            RoundedRectangle(cornerRadius: 22, style: .continuous)
                                .stroke(Color.white.opacity(0.28), lineWidth: 1.2)
                        )
                )
            }
            .buttonStyle(OunjeCardPressButtonStyle())

            Text("* we don't store login details")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(OunjePalette.secondaryText.opacity(0.9))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 304)
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
        budgetPerCycle >= 25
    }

    private var canAdvanceCurrentStep: Bool {
        switch currentStep {
        case .identity:
            return !selectedFoodPersona.isEmpty
        case .challenge:
            return !selectedFoodChallenges.isEmpty
        case .solution:
            return true
        case .solutionWays:
            return true
        case .recipeStyle:
            return true
        case .allergies:
            return true
        case .diets:
            return true
        case .recipeEditIntro:
            return true
        case .recipeEditDemo:
            return hasCompletedRecipeEditDemo
        case .shareImport:
            // Always advanceable: the demo is interactive but skippable. Users
            // who paste a link kick off a real import in the background; users
            // who tap "Skip for now" still see the visual primer.
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
            return true
        case .paywallIntro:
            return true
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
        persistDraftForResume(step: next)
        stepTransitionDirection = 1
        withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
            currentStep = next
        }
    }

    private func advanceFromAutoTransition() {
        guard let next = currentStep.next else { return }
        persistDraft(step: next)
        stepTransitionDirection = 1
        withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
            currentStep = next
        }
    }

    private func advanceIntroChoice(after delay: TimeInterval) {
        let scheduledStep = currentStep
        let effectiveDelay = max(delay, 0.42)
        introAutoAdvanceTask?.cancel()
        introAutoAdvanceTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(effectiveDelay * 1_000_000_000))
            guard !Task.isCancelled,
                  currentStep == scheduledStep,
                  usesIntroChoiceLayout,
                  canAdvanceCurrentStep
            else { return }
            advance()
        }
    }

    private func scheduleRecipeUpgradeIntroAdvance() {
        onboardingAutoAdvanceTask?.cancel()
        recipeUpgradeIntroTextVisible = false
        recipeUpgradeIntroTextExiting = false
        onboardingAutoAdvanceTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled, currentStep == .recipeEditIntro else { return }
            recipeUpgradeIntroTextVisible = true
            try? await Task.sleep(nanoseconds: 1_350_000_000)
            guard !Task.isCancelled, currentStep == .recipeEditIntro else { return }
            recipeUpgradeIntroTextExiting = true
            try? await Task.sleep(nanoseconds: 360_000_000)
            guard !Task.isCancelled, currentStep == .recipeEditIntro else { return }
            advanceFromAutoTransition()
        }
    }

    private func schedulePaywallIntroPresentation() {
        onboardingAutoAdvanceTask?.cancel()
        onboardingAutoAdvanceTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled, currentStep == .paywallIntro else { return }
            finishOnboardingOrPresentPaywall()
        }
    }

    private func scheduleSolutionTypewriterTransition() {
        onboardingAutoAdvanceTask?.cancel()
        solutionAnimationVisible = false
        solutionAnimationExiting = false
        solutionTypedCharacterCount = 0
        solutionHelpVisibleCount = 0
        onboardingAutoAdvanceTask = Task { @MainActor in
            let headline = solutionProfile.headline
            guard !headline.isEmpty else { return }
            try? await Task.sleep(nanoseconds: 120_000_000)
            for characterCount in 1...headline.count {
                try? await Task.sleep(nanoseconds: 42_000_000)
                guard !Task.isCancelled, currentStep == .solution else { return }
                solutionTypedCharacterCount = characterCount
            }
            try? await Task.sleep(nanoseconds: 1_700_000_000)
            guard !Task.isCancelled, currentStep == .solution else { return }
            advanceFromAutoTransition()
        }
    }

    private func scheduleSolutionWaysTransition() {
        onboardingAutoAdvanceTask?.cancel()
        solutionHelpVisibleCount = 0
        onboardingAutoAdvanceTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 160_000_000)
            guard !Task.isCancelled, currentStep == .solutionWays else { return }
            for index in 1...solutionHelpItems.count {
                solutionHelpVisibleCount = index
                try? await Task.sleep(nanoseconds: 460_000_000)
                guard !Task.isCancelled, currentStep == .solutionWays else { return }
            }
            try? await Task.sleep(nanoseconds: 1_900_000_000)
            guard !Task.isCancelled, currentStep == .solutionWays else { return }
            advanceFromAutoTransition()
        }
    }

    private func handleIntroHeaderAction() {
        if currentStep == .address {
            moveForward(to: .budget)
            return
        }

        if currentStep == .challenge, !selectedFoodChallenges.isEmpty {
            advance()
            return
        }

        if currentStep == .allergies, !parsedAllergies.isEmpty {
            advance()
            return
        }

        if currentStep == .diets, !selectedDietaryPatterns.isEmpty {
            advance()
            return
        }

        if currentStep == .recipeEditDemo {
            if hasCompletedRecipeEditDemo {
                advance()
            }
            return
        }

        if currentStep == .budget {
            if !shouldUseBudgetGuardrail {
                budgetWindow = .weekly
                budgetPerCycle = UserProfile.starter.budgetPerCycle
                syncBudgetInput()
            }
            advance()
            return
        }

        if currentStep == .allergies || currentStep == .diets || currentStep == .solution || currentStep == .solutionWays || currentStep == .recipeStyle {
            advance()
            return
        }

        if currentStep == .ordering {
            if orderingAutonomy == .approvalRequired {
                advance()
            } else {
                orderingAutonomy = .suggestOnly
                moveForward(to: .budget)
            }
            return
        }

        skipCurrentStep()
    }

    private func moveForward(to step: SetupStep) {
        persistDraftForResume(step: step)
        stepTransitionDirection = 1
        withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
            currentStep = step
        }
    }

    private func skipCurrentStep() {
        guard let next = currentStep.next else {
            submit()
            return
        }
        moveForward(to: next)
    }

    private func goBack() {
        guard let previousStep = currentStep.previous else { return }
        persistDraftForResume(step: previousStep)
        stepTransitionDirection = -1
        withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
            currentStep = previousStep
        }
    }

    @MainActor
    private func loadRecipeEditDemoIfNeeded(forceRefresh: Bool = false) async {
        if isRecipeEditDemoLoading { return }
        if !forceRefresh, !recipeEditDemoRecipes.isEmpty { return }

        isRecipeEditDemoLoading = true
        let recipes = await OnboardingRecipeEditDemoService.shared.loadRecipes(forceRefresh: forceRefresh)
        recipeEditDemoRecipes = recipes
        isRecipeEditDemoLoading = false
    }

    private func openRecipeEditDemo(_ demoRecipe: OnboardingRecipeEditDemoRecipe) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        selectedRecipeEditDemoRecipe = demoRecipe
    }

    private func completeRecipeEditDemo() {
        hasCompletedRecipeEditDemo = true
        selectedRecipeEditDemoRecipe = nil
        moveForward(to: .ordering)
    }

    private func toggleFoodChallenge(_ option: String) {
        withAnimation(.spring(response: 0.24, dampingFraction: 0.82)) {
            if selectedFoodChallenges.contains(option) {
                selectedFoodChallenges.remove(option)
            } else if selectedFoodChallenges.count < foodGoalSelectionLimit {
                selectedFoodChallenges.insert(option)
            }
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        persistDraft()

        if selectedFoodChallenges.count == foodGoalSelectionLimit {
            advanceIntroChoice(after: 0.16)
        }
    }

    private func toggleDietaryPattern(_ option: String) {
        withAnimation(.spring(response: 0.24, dampingFraction: 0.82)) {
            if selectedDietaryPatterns.contains(option) {
                selectedDietaryPatterns.remove(option)
            } else {
                selectedDietaryPatterns.insert(option)
            }
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        persistDraft()
    }

    private func solutionTypedHeadline(for headline: String) -> String {
        guard currentStep == .solution else { return headline }
        let visibleCount = min(max(0, solutionTypedCharacterCount), headline.count)
        return String(headline.prefix(visibleCount))
    }

    private func revealSolutionPage() {
        let stepRawValue = currentStep.rawValue
        let shouldAutoAdvance = stepTransitionDirection >= 0
        solutionRevealTask?.cancel()

        if completedSolutionAnimationSteps.contains(stepRawValue) {
            solutionAnimationVisible = true
            solutionAnimationExiting = false
            solutionTypedCharacterCount = currentStep == .solution ? solutionProfile.headline.count : 0
            solutionHelpVisibleCount = solutionHelpItems.count
            if shouldAutoAdvance {
                solutionRevealTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 1_150_000_000)
                    guard !Task.isCancelled,
                          currentStep == .solution || currentStep == .solutionWays
                    else { return }
                    solutionAnimationExiting = true
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    guard !Task.isCancelled,
                          currentStep == .solution || currentStep == .solutionWays
                    else { return }
                    advanceFromAutoTransition()
                }
            }
            return
        }

        solutionAnimationVisible = false
        solutionAnimationExiting = false
        solutionTypedCharacterCount = 0
        solutionHelpVisibleCount = 0
        solutionRevealTask = Task { @MainActor in
            guard currentStep == .solution || currentStep == .solutionWays else { return }
            try? await Task.sleep(nanoseconds: 80_000_000)
            guard currentStep == .solution || currentStep == .solutionWays else { return }
            withAnimation {
                solutionAnimationVisible = true
            }

            if currentStep == .solution {
                let headline = solutionProfile.headline
                for characterCount in 1...headline.count {
                    try? await Task.sleep(nanoseconds: 28_000_000)
                    guard currentStep == .solution else { return }
                    solutionTypedCharacterCount = characterCount
                }

                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard currentStep == .solution else { return }
                completedSolutionAnimationSteps.insert(stepRawValue)
                if shouldAutoAdvance {
                    solutionAnimationExiting = true
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    guard currentStep == .solution else { return }
                    advanceFromAutoTransition()
                }
                return
            }

            for index in 1...solutionHelpItems.count {
                try? await Task.sleep(nanoseconds: 440_000_000)
                guard currentStep == .solutionWays else { return }
                solutionHelpVisibleCount = index
            }

            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard currentStep == .solutionWays else { return }
            completedSolutionAnimationSteps.insert(stepRawValue)
            if shouldAutoAdvance {
                solutionAnimationExiting = true
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard currentStep == .solutionWays else { return }
                advanceFromAutoTransition()
            }
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

        goBack()
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

    private var knownAllergyOptions: [String] {
        Array(commonAllergyOptions.prefix(3))
    }

    private var customAllergy: String? {
        parsedAllergies.first { allergy in
            !knownAllergyOptions.contains { known in
                allergy.compare(known, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
            }
        }
    }

    private var allergyDisplayOptions: [String] {
        knownAllergyOptions + [customAllergy ?? "Other"]
    }

    private func allergyListContains(_ option: String) -> Bool {
        if option == "Other" {
            return customAllergy != nil
        }

        if customAllergy?.compare(option, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame,
           !knownAllergyOptions.contains(where: { $0.compare(option, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }) {
            return true
        }

        return parsedAllergies.contains { $0.compare(option, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
    }

    private func toggleAllergy(_ option: String) {
        if option == "Other" || customAllergy?.compare(option, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame {
            otherAllergyInput = customAllergy ?? ""
            isOtherAllergyPromptPresented = true
            return
        }

        var items = parsedAllergies
        if let existingIndex = items.firstIndex(where: { $0.compare(option, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }) {
            items.remove(at: existingIndex)
        } else {
            items.append(option)
        }
        allergiesText = items.joined(separator: ", ")
        persistDraft()
    }

    private func addOtherAllergy() {
        let trimmed = otherAllergyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        otherAllergyInput = ""

        var items = parsedAllergies.filter { allergy in
            knownAllergyOptions.contains { known in
                allergy.compare(known, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
            }
        }

        guard !trimmed.isEmpty else {
            allergiesText = items.joined(separator: ", ")
            persistDraft()
            return
        }

        if !items.contains(where: { $0.compare(trimmed, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }) {
            items.append(trimmed)
        }
        allergiesText = items.joined(separator: ", ")
        persistDraft()
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

    private var isOnboardingInstacartConnected: Bool {
        onboardingInstacartProvider?.connected == true
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

    private var onboardingInstacartConnectionSubtitle: String {
        if onboardingProvidersViewModel.isLoading {
            return "Checking your cart connection."
        }
        if isOnboardingInstacartConnected {
            return "Ready to build carts when you are."
        }
        return "Connect now, or connect later in the app."
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
        Task {
            let session = await store.freshUserDataSession()
            onboardingProvidersViewModel.loadProviders(
                userId: session?.userID,
                accessToken: session?.accessToken
            )
        }
    }

    private func openOnboardingInstacartConnection() {
        Task {
            _ = await store.freshUserDataSession()
            selectedOnboardingProvider = onboardingInstacartProvider
                ?? GroceryProviderInfo(id: "instacart", name: "Instacart", connected: false)
        }
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
            mealPrepGoals: onboardingProfileGoalSignals,
            cooksForOthers: cooksForOthers,
            kitchenEquipment: [],
            budgetWindow: budgetWindow,
            budgetFlexibility: .slightlyFlexible,
            purchasingBehavior: purchasingBehavior,
            orderingAutonomy: orderingAutonomy,
            pricingTier: store.effectivePricingTier,
            foodPersona: selectedFoodPersona,
            foodGoals: selectedFoodChallengeList
        )
    }

    private var onboardingProfileGoalSignals: [String] {
        [
            selectedFoodPersona.isEmpty ? nil : "Describes me: \(selectedFoodPersona)",
            selectedFoodChallengeList.isEmpty ? nil : "Food goals: \(selectedFoodChallengeList.joined(separator: "; "))",
            didChooseRecipeTypographyStyle ? "\(RecipeTypographyPreferenceStore.profileSignalPrefix) \(selectedRecipeTypographyStyle.rawValue)" : nil,
            "Budget considered: \(shouldUseBudgetGuardrail ? "Yes" : "No")"
        ]
        .compactMap { $0 }
    }

    private var selectedRecipeTypographyStyle: RecipeTypographyStyle {
        RecipeTypographyStyle.resolved(from: recipeTypographyStyleRawValue)
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
        finishOnboardingOrPresentPaywall()
    }

    private func finishOnboardingOrPresentPaywall() {
        guard canSubmit else { return }

        let completedProfile = draftProfile
        let completedStep = SetupStep.completedRawValue
        Task(priority: .utility) {
            _ = try? await SupabaseAgentBriefService.shared.generateBrief(for: completedProfile)
        }

        if OunjeLaunchFlags.paywallsEnabled && !hasCompletedOnboardingBeforePaywall {
            pendingCompletedOnboardingProfile = completedProfile
            pendingCompletedOnboardingStep = completedStep
            paywallInitialTier = .plus
            stepTransitionDirection = 1
            withAnimation(.spring(response: 0.36, dampingFraction: 0.86)) {
                isPaywallPresented = true
            }
            return
        }

        completeOnboarding(completedProfile, lastStep: completedStep)
    }

    private func completePendingOnboardingAfterPaywall() {
        guard let pendingProfile = pendingCompletedOnboardingProfile else { return }
        let pendingStep = pendingCompletedOnboardingStep ?? SetupStep.completedRawValue
        pendingCompletedOnboardingProfile = nil
        pendingCompletedOnboardingStep = nil
        hasCompletedOnboardingBeforePaywall = true
        completeOnboarding(pendingProfile, lastStep: pendingStep)
    }

    private func completeOnboarding(_ completedProfile: UserProfile, lastStep completedStep: Int) {
        guard !isSaving else { return }
        isSaving = true
        Task {
            await store.completeOnboarding(with: completedProfile, lastStep: completedStep)
            await MainActor.run {
                isSaving = false
            }
        }
    }

    private func parseList(_ raw: String) -> [String] {
        raw
            .split(whereSeparator: { $0 == "," || $0 == ";" || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func hydrateDraftFromStore() {
        if OunjeLaunchFlags.forceOnboardingIncomplete {
            hydrateFreshForcedOnboardingDraft()
            return
        }

        let sourceProfile = store.profile ?? .starter

        if !store.isOnboarded {
            currentStep = SetupStep.resumeStep(from: store.lastOnboardingStep)
        }
        hasCompletedRecipeEditDemo = currentStep.index > SetupStep.recipeEditDemo.index

        preferredName = sourceProfile.trimmedPreferredName
            ?? store.authSession?.displayName?.components(separatedBy: .whitespacesAndNewlines).first
            ?? preferredName
        selectedDietaryPatterns = Set(sourceProfile.dietaryPatterns.filter { dietaryPatternOptions.contains($0) })
        selectedCuisines = Set(sourceProfile.preferredCuisines)
        selectedCuisineCountries = Set(sourceProfile.cuisineCountries)
        selectedFoodPersona = Self.prefixedProfileSignal(
            in: sourceProfile.mealPrepGoals,
            prefix: "Describes me:"
        ) ?? selectedFoodPersona
        selectedFoodChallenges = Set(
            normalizedStoredFoodGoals(
                from: Self.prefixedProfileSignal(in: sourceProfile.mealPrepGoals, prefix: "Food goals:")
                    .map { splitStoredProfileSignal($0) }
                    ?? Self.prefixedProfileSignal(in: sourceProfile.mealPrepGoals, prefix: "Main challenges:")
                        .map { splitStoredProfileSignal($0) }
                    ?? Self.prefixedProfileSignal(in: sourceProfile.mealPrepGoals, prefix: "Main challenge:")
                        .map { [$0] }
                    ?? Array(selectedFoodChallenges)
            )
        )
        if let storedRecipeStyle = RecipeTypographyPreferenceStore.style(in: sourceProfile) {
            recipeTypographyStyleRawValue = storedRecipeStyle.rawValue
            didChooseRecipeTypographyStyle = true
        } else {
            recipeTypographyStyleRawValue = RecipeTypographyStyle.defaultStyle.rawValue
            didChooseRecipeTypographyStyle = false
        }
        if let storedBudgetChoice = Self.prefixedProfileSignal(
            in: sourceProfile.mealPrepGoals,
            prefix: "Budget considered:"
        ) {
            shouldUseBudgetGuardrail = storedBudgetChoice.localizedCaseInsensitiveContains("yes")
        } else {
            shouldUseBudgetGuardrail = false
        }
        selectedFavoriteFoods = Set(sourceProfile.favoriteFoods)
        selectedNeverIncludeFoods = Set(sourceProfile.neverIncludeFoods)
        selectedGoals = Set(sourceProfile.mealPrepGoals)
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
        allergiesText = SetupStep.hasReached(.allergies, storedRawValue: store.lastOnboardingStep)
            ? sourceProfile.absoluteRestrictions.joined(separator: ", ")
            : ""
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
        orderingAutonomy = SetupStep.hasReached(.ordering, storedRawValue: store.lastOnboardingStep)
            ? sourceProfile.orderingAutonomy
            : .suggestOnly
        selectedTierRawValue = sourceProfile.pricingTier.rawValue
    }

    private func hydrateFreshForcedOnboardingDraft() {
        let sourceProfile = UserProfile.starter

        currentStep = .identity
        hasCompletedRecipeEditDemo = false
        preferredName = ""
        selectedFoodPersona = ""
        selectedFoodChallenges.removeAll()
        selectedDietaryPatterns.removeAll()
        selectedCuisines = Set(sourceProfile.preferredCuisines)
        selectedCuisineCountries = Set(sourceProfile.cuisineCountries)
        selectedFavoriteFoods = Set(sourceProfile.favoriteFoods)
        selectedNeverIncludeFoods = Set(sourceProfile.neverIncludeFoods)
        selectedGoals.removeAll()
        missingEquipment.removeAll()
        recipeTypographyStyleRawValue = RecipeTypographyStyle.defaultStyle.rawValue
        didChooseRecipeTypographyStyle = false
        shouldUseBudgetGuardrail = false
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
        budgetFlexibilityScore = sourceProfile.budgetFlexibility.calibrationScore
        allergiesText = ""
        otherAllergyInput = ""
        extraFavoriteFoodsText = ""
        neverIncludeText = ""
        addressLine1 = ""
        addressLine2 = ""
        city = ""
        region = ""
        postalCode = ""
        deliveryNotes = ""
        addressAutocomplete.query = ""
        purchasingBehavior = sourceProfile.purchasingBehavior
        orderingAutonomy = .suggestOnly
        selectedTierRawValue = sourceProfile.pricingTier.rawValue
    }

    private func splitStoredProfileSignal(_ value: String) -> [String] {
        value
            .split(separator: ";")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func normalizedStoredFoodGoals(from values: [String]) -> [String] {
        let aliases = [
            "Bored of the same meals": "Cook new things",
            "Meal planning is too much": "Save time & energy shopping",
            "Learning how to cook": "Learn to cook better",
            "Groceries cost too much": "Spend less on groceries",
            "No time to shop or prep": "Save time & energy shopping",
            "Can't find good eats": "Find good eats"
        ]

        var seen = Set<String>()
        var result: [String] = []

        for value in values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            let mapped = aliases[trimmed] ?? trimmed
            guard foodChallengeOptions.contains(mapped),
                  seen.insert(mapped).inserted else { continue }
            result.append(mapped)
        }

        return result
    }

    private static func prefixedProfileSignal(in goals: [String], prefix: String) -> String? {
        goals
            .first { $0.localizedCaseInsensitiveContains(prefix) }
            .map { $0.replacingOccurrences(of: prefix, with: "").trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 }
    }

    private func additionalDraftEntryText(from source: [String], excluding knownOptions: [String]) -> String {
        let known = Set(knownOptions.map { $0.lowercased() })
        return source
            .filter { !known.contains($0.lowercased()) }
            .joined(separator: ", ")
    }

    private func persistDraftLocally() {
        guard !currentStep.isAutoTransition else { return }
        store.saveOnboardingDraft(draftProfile, step: currentStep.rawValue)
    }

    private func persistDraftForResume(step: SetupStep) {
        guard !step.isAutoTransition else { return }
        persistDraft(step: step)
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
                profile: profile,
                accessToken: session.accessToken
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
        case identity = 1
        case challenge = 2
        case solution = 3
        case solutionWays = 4
        case recipeStyle = 12
        case allergies = 5
        case diets = 13
        case recipeEditIntro = 15
        case recipeEditDemo = 14
        case paywallIntro = 16
        case cuisines = 6
        case household = 7
        case kitchen = 8
        case budget = 9
        case ordering = 10
        case address = 11
        // New step teaching users to send recipes to Ounje from outside apps
        // (TikTok / Instagram / photos / links). Interactive — the user can
        // actually paste a link and kick off a real import right here.
        case shareImport = 17

        static var allCases: [SetupStep] {
            [
                .identity,
                .challenge,
                .solution,
                .solutionWays,
                .shareImport,
                .allergies,
                .diets,
                .recipeEditIntro,
                .recipeEditDemo,
                .ordering,
                .address,
                .budget,
                .recipeStyle,
                .paywallIntro
            ]
        }

        static var completedRawValue: Int {
            Self.allCases.last?.rawValue ?? SetupStep.address.rawValue
        }

        var index: Int {
            Self.allCases.firstIndex(of: self) ?? 0
        }

        var title: String {
            switch self {
            case .identity:
                return "You"
            case .challenge:
                return "Challenge"
            case .solution:
                return "Ounje"
            case .solutionWays:
                return "How it works"
            case .recipeStyle:
                return "Recipe style"
            case .allergies:
                return "Food rules"
            case .diets:
                return "Diet"
            case .recipeEditIntro:
                return "Recipe upgrades"
            case .recipeEditDemo:
                return "Recipe edit"
            case .shareImport:
                return "Send recipes"
            case .paywallIntro:
                return "Trial"
            case .cuisines:
                return "Taste"
            case .household:
                return "Prep rhythm"
            case .kitchen:
                return "Who we're feeding"
            case .budget:
                return "Cart budget"
            case .ordering:
                return "Autoshop"
            case .address:
                return "Instacart"
            }
        }

        var subtitle: String {
            switch self {
            case .identity:
                return "Start with the kind of help that fits your kitchen."
            case .challenge:
                return "Tell Ounje what food goals matter right now."
            case .solution:
                return "Ounje was made for people like you."
            case .solutionWays:
                return "A quick map of what Ounje handles."
            case .recipeStyle:
                return "Pick how recipe cards should feel."
            case .allergies:
                return "Allergies and hard stops beat every recipe suggestion."
            case .diets:
                return "Choose any eating styles Ounje should keep in mind."
            case .recipeEditIntro:
                return "Ounje can adapt recipes to your taste, diet, and routine."
            case .recipeEditDemo:
                return "See how recipe edits work before Ounje starts planning for you."
            case .shareImport:
                return "Recipes from anywhere — TikTok, Instagram, photos, links."
            case .paywallIntro:
                return "Your setup is ready before the trial starts."
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
                return "Connect the cart lane when you're ready."
            }
        }

        var prompt: String {
            switch self {
            case .identity:
                return "Help Ounje understand your food life."
            case .challenge:
                return "Pick the food goals Ounje should understand."
            case .solution:
                return "See how Ounje will help."
            case .solutionWays:
                return "See the plan."
            case .recipeStyle:
                return "Choose your recipe look."
            case .allergies:
                return "Set the rules Ounje cannot break."
            case .diets:
                return "Set the eating styles Ounje should understand."
            case .recipeEditIntro:
                return "See how Ounje upgrades recipes."
            case .recipeEditDemo:
                return "Pick a recipe and try a guided edit."
            case .shareImport:
                return "Try sending Ounje a recipe."
            case .paywallIntro:
                return "Get ready to start your trial."
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
                return "Connect Instacart for cart building."
            }
        }

        var plateEmojis: [String] {
            switch self {
            case .identity:
                return ["👤", "🍽️", "✓"]
            case .challenge:
                return ["?", "🍳", "→"]
            case .solution:
                return ["✨", "🛒", "✓"]
            case .solutionWays:
                return ["1", "2", "3"]
            case .recipeStyle:
                return ["Aa", "🍣", "✓"]
            case .allergies:
                return ["✅", "🥗", "🛡️"]
            case .diets:
                return ["🥗", "✓", "AI"]
            case .recipeEditIntro:
                return ["✨", "🍽️", "✓"]
            case .recipeEditDemo:
                return ["✍️", "🍽️", "✨"]
            case .shareImport:
                return ["📲", "🔗", "✨"]
            case .paywallIntro:
                return ["🎉", "✓", "→"]
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
                return ["🛒", "✓", "→"]
            }
        }

        var symbolName: String {
            switch self {
            case .identity:
                return "person.crop.circle.fill"
            case .challenge:
                return "questionmark.circle.fill"
            case .solution:
                return "sparkles"
            case .solutionWays:
                return "list.number"
            case .recipeStyle:
                return "textformat"
            case .allergies:
                return "checklist"
            case .diets:
                return "leaf.fill"
            case .recipeEditIntro:
                return "sparkles"
            case .recipeEditDemo:
                return "wand.and.stars"
            case .shareImport:
                return "paperplane.circle.fill"
            case .paywallIntro:
                return "party.popper.fill"
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
                return "cart.fill"
            }
        }

        var next: SetupStep? {
            guard let index = Self.allCases.firstIndex(of: self),
                  Self.allCases.indices.contains(index + 1) else { return nil }
            return Self.allCases[index + 1]
        }

        var previous: SetupStep? {
            guard let index = Self.allCases.firstIndex(of: self),
                  index > Self.allCases.startIndex else { return nil }
            return Self.allCases[index - 1]
        }

        var isAutoTransition: Bool {
            self == .solution ||
            self == .solutionWays ||
            self == .recipeEditIntro ||
            self == .paywallIntro
        }

        static func resumeStep(from rawValue: Int) -> SetupStep {
            guard rawValue >= SetupStep.identity.rawValue else { return .identity }
            let maxActiveRawValue = Self.allCases.map(\.rawValue).max() ?? SetupStep.address.rawValue
            let clampedValue = min(rawValue, maxActiveRawValue)
            if let exactStep = SetupStep(rawValue: clampedValue),
               Self.allCases.contains(exactStep) {
                return exactStep
            }
            return Self.allCases.first(where: { $0.rawValue > clampedValue }) ?? .identity
        }

        static func hasReached(_ step: SetupStep, storedRawValue: Int) -> Bool {
            orderedIndex(for: storedRawValue) >= step.index
        }

        static func latestStoredRawValue(_ lhs: Int, _ rhs: Int) -> Int {
            let lhsIndex = orderedIndex(for: lhs)
            let rhsIndex = orderedIndex(for: rhs)

            if lhsIndex == rhsIndex {
                return max(lhs, rhs)
            }

            return lhsIndex > rhsIndex ? lhs : rhs
        }

        private static func orderedIndex(for rawValue: Int) -> Int {
            guard rawValue >= SetupStep.identity.rawValue else { return -1 }

            if let exactStep = SetupStep(rawValue: rawValue),
               let exactIndex = Self.allCases.firstIndex(of: exactStep) {
                return exactIndex
            }

            return resumeStep(from: rawValue).index
        }
    }
}

private struct OnboardingAutoTransitionPage: View {
    let eyebrow: String
    let title: String
    let subtitle: String
    let chips: [String]
    let accent: Color
    let showsConfetti: Bool

    var body: some View {
        ZStack {
            if showsConfetti {
                OnboardingConfettiRain()
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }

            VStack(spacing: 18) {
                Spacer(minLength: 0)

                VStack(spacing: 12) {
                    Text(eyebrow.uppercased())
                        .font(.system(size: 12, weight: .black, design: .rounded))
                        .tracking(1.2)
                        .foregroundStyle(accent)

                    Text(title)
                        .font(.system(size: 34, weight: .black, design: .rounded))
                        .foregroundStyle(OunjePalette.primaryText)
                        .multilineTextAlignment(.center)
                        .lineSpacing(-1)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 340)

                    Text(subtitle)
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .foregroundStyle(OunjePalette.secondaryText)
                        .multilineTextAlignment(.center)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 332)
                }

                HStack(spacing: 8) {
                    ForEach(chips, id: \.self) { chip in
                        Text(chip)
                            .font(.system(size: 12, weight: .black, design: .rounded))
                            .foregroundStyle(OunjePalette.primaryText)
                            .lineLimit(1)
                            .minimumScaleFactor(0.72)
                            .padding(.horizontal, 11)
                            .frame(height: 34)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(OunjePalette.panel)
                                    .overlay(
                                        Capsule(style: .continuous)
                                            .stroke(accent.opacity(0.34), lineWidth: 1)
                                    )
                            )
                    }
                }
                .frame(maxWidth: 350)

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct OnboardingMinimalTransitionPage: View {
    let title: String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isVisible = false

    var body: some View {
        VStack {
            Spacer(minLength: 0)

            Text(title)
                .font(.system(size: 35, weight: .black, design: .rounded))
                .foregroundStyle(OunjePalette.primaryText)
                .multilineTextAlignment(.center)
                .lineSpacing(-1)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 340)
                .opacity(isVisible ? 1 : 0)
                .offset(x: reduceMotion ? 0 : (isVisible ? 0 : -40))
                .scaleEffect(reduceMotion || isVisible ? 1 : 0.96)
                .animation(.spring(response: 0.34, dampingFraction: 0.84), value: isVisible)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .onAppear {
            isVisible = false
            DispatchQueue.main.async {
                isVisible = true
            }
        }
    }
}

private struct OnboardingConfettiRain: View {
    @State private var isFalling = false

    private let pieces = Array(0..<42)
    private let colors: [Color] = [
        Color(hex: "63D471"),
        Color(hex: "F6E7B0"),
        Color(hex: "FFFFFF"),
        Color(hex: "9BE7B0"),
        Color(hex: "F8B36A")
    ]

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                ForEach(pieces, id: \.self) { index in
                    let startX = xPosition(for: index, width: proxy.size.width)
                    let drift = CGFloat((index % 7) - 3) * 14
                    let targetY = proxy.size.height * CGFloat(0.30 + Double(index % 8) * 0.045)
                    let color = colors[index % colors.count]

                    OnboardingConfettiPiece(color: color, isCapsule: index % 3 == 0)
                        .frame(width: index % 3 == 0 ? 7 : 8, height: index % 3 == 0 ? 15 : 8)
                        .rotationEffect(.degrees(isFalling ? Double(index * 31 + 120) : Double(index * 9)))
                        .position(x: startX, y: -30)
                        .offset(x: isFalling ? drift : 0, y: isFalling ? targetY + 30 : 0)
                        .opacity(isFalling ? 0.95 : 0)
                        .animation(
                            .easeOut(duration: 1.05).delay(Double(index % 10) * 0.025),
                            value: isFalling
                        )
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .onAppear {
                isFalling = false
                DispatchQueue.main.async {
                    isFalling = true
                }
            }
        }
    }

    private func xPosition(for index: Int, width: CGFloat) -> CGFloat {
        let slots = max(1, pieces.count - 1)
        let base = CGFloat(index) / CGFloat(slots)
        let wave = sin(Double(index) * 1.7) * 0.045
        return width * min(max(base + wave, 0.04), 0.96)
    }
}

private struct OnboardingConfettiPiece: View {
    let color: Color
    let isCapsule: Bool

    var body: some View {
        Group {
            if isCapsule {
                Capsule(style: .continuous)
                    .fill(color)
            } else {
                Circle()
                    .fill(color)
            }
        }
        .shadow(color: color.opacity(0.24), radius: 5, y: 3)
    }
}

private struct OnboardingSolutionMetric {
    let value: String
    let label: String
}

private struct OnboardingSolutionProfile {
    let headline: String
    let subtitle: String
    let metrics: [OnboardingSolutionMetric]
    let reviewer: String
    let review: String
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
        step.prompt
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

struct OnboardingIntroChoiceButton: View {
    let title: String
    let isSelected: Bool
    let accent: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 0) {
                Text(title)
                    .font(.system(size: 15, weight: .black, design: .rounded))
                    .foregroundStyle(isSelected ? .black : OunjePalette.primaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity, minHeight: 58)
            .background(
                Capsule(style: .continuous)
                    .fill(isSelected ? accent : OunjePalette.elevated)
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(Color.black.opacity(isSelected ? 0.9 : 0.72), lineWidth: isSelected ? 2.25 : 1.8)
                    )
            )
            .scaleEffect(isSelected ? 1.01 : 1)
            .shadow(color: isSelected ? accent.opacity(0.22) : .clear, radius: 10, x: 0, y: 6)
        }
        .buttonStyle(.plain)
    }
}

struct OnboardingRecipeStylePreviewChoice: View {
    let recipe: DiscoverRecipeCardData
    let style: RecipeTypographyStyle
    let isSelected: Bool
    let accent: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 7) {
                    styleLabel
                        .foregroundStyle(isSelected ? OunjePalette.primaryText : OunjePalette.secondaryText)

                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(isSelected ? Color.white : Color.white.opacity(0.5))

                    Spacer(minLength: 0)
                }

                VStack(alignment: .leading, spacing: 12) {
                    Image("CrunchyMisoSalmonPreview")
                        .resizable()
                        .scaledToFill()
                        .frame(width: 112, height: 112)
                        .clipShape(Circle())
                        .overlay(
                            Circle()
                                .stroke(Color.white.opacity(0.2), lineWidth: 1)
                        )
                        .frame(maxWidth: .infinity)

                    RecipeTypographyTitleText(
                        recipe.title,
                        size: style == .clean ? 15 : 17,
                        color: OunjePalette.primaryText,
                        style: style
                    )
                    .lineLimit(3)
                    .minimumScaleFactor(0.72)
                    .frame(height: 54, alignment: .topLeading)

                    HStack(spacing: 5) {
                        Image(systemName: "clock")
                            .font(.system(size: 10, weight: .bold))
                        Text(recipe.compactCookTime ?? "15 mins")
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                    }
                    .foregroundStyle(OunjePalette.secondaryText)
                }
                .padding(12)
                .frame(width: 148, height: 224, alignment: .topLeading)
                .background(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.075),
                                    Color.white.opacity(0.035)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 20, style: .continuous)
                                .stroke(isSelected ? Color.white.opacity(0.9) : Color.white.opacity(0.08), lineWidth: isSelected ? 2 : 1)
                        )
                )
            }
            .frame(width: 170, alignment: .topLeading)
            .scaleEffect(isSelected ? 1.01 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.84), value: isSelected)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var styleLabel: some View {
        if style == .playful {
            Text(style.displayName)
                .font(.custom("Slee_handwritting-Regular", size: 20))
                .fontWeight(.black)
        } else {
            Text(style.displayName)
                .font(.system(size: 14, weight: .black, design: .rounded))
        }
    }
}

struct InstacartLogoMark: View {
    var body: some View {
        Image("InstacartLogo")
            .resizable()
            .scaledToFit()
            .accessibilityLabel("Instacart")
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
