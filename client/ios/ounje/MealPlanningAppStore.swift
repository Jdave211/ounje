import Foundation

@MainActor
final class MealPlanningAppStore: ObservableObject {
    @Published var authSession: AuthSession?
    @Published var isOnboarded = false
    @Published var profile: UserProfile?
    @Published var latestPlan: MealPlan?
    @Published var planHistory: [MealPlan] = []
    @Published var isGenerating = false

    private let planner = MealPlanningAgent()
    private var activeGenerationToken = UUID()

    private let authSessionKey = "agentic-auth-session-v1"
    private let onboardedKey = "agentic-onboarded-v1"
    private let profileKey = "agentic-meal-profile-v1"
    private let historyKey = "agentic-meal-history-v1"

    init() {
        loadState()
    }

    var nextRunDate: Date? {
        guard let profile, profile.isAutomationReady else { return nil }
        let anchor = latestPlan?.generatedAt ?? Date()
        return anchor.adding(days: profile.cadence.dayInterval)
    }

    var isAuthenticated: Bool {
        authSession != nil
    }

    var requiresProfileOnboarding: Bool {
        guard isAuthenticated else { return false }
        return !isOnboarded
    }

    func signIn(with session: AuthSession, onboarded: Bool) {
        if profile == nil {
            profile = .starter
            saveProfile()
        }
        authSession = session
        isOnboarded = onboarded
        saveAuthSession()
        saveOnboardingState()

        if isOnboarded, profile?.isAutomationReady == true {
            Task {
                await generatePlan()
            }
        }
    }

    func completeOnboarding(with profile: UserProfile) {
        self.profile = profile
        isOnboarded = true
        saveProfile()
        saveOnboardingState()

        Task {
            await generatePlan()
        }
    }

    func updateProfile(_ updated: UserProfile) {
        profile = updated
        saveProfile()
    }

    func generatePlan() async {
        guard let profile, profile.isAutomationReady else { return }
        let generationToken = UUID()
        activeGenerationToken = generationToken
        isGenerating = true
        let plan = await planner.generatePlan(profile: profile, history: planHistory)
        guard activeGenerationToken == generationToken, self.profile == profile else { return }
        latestPlan = plan
        planHistory.insert(plan, at: 0)

        if planHistory.count > 12 {
            planHistory = Array(planHistory.prefix(12))
        }

        saveHistory()
        isGenerating = false
    }

    func resetAll() {
        activeGenerationToken = UUID()
        authSession = nil
        isOnboarded = false
        profile = nil
        latestPlan = nil
        planHistory = []
        isGenerating = false
        UserDefaults.standard.removeObject(forKey: authSessionKey)
        UserDefaults.standard.removeObject(forKey: onboardedKey)
        UserDefaults.standard.removeObject(forKey: profileKey)
        UserDefaults.standard.removeObject(forKey: historyKey)
    }

    func signOutToWelcome() {
        resetAll()
    }

    private func loadState() {
        let decoder = JSONDecoder()

        if let authData = UserDefaults.standard.data(forKey: authSessionKey),
           let decodedAuth = try? decoder.decode(AuthSession.self, from: authData) {
            authSession = decodedAuth
        }

        isOnboarded = UserDefaults.standard.bool(forKey: onboardedKey)

        if let profileData = UserDefaults.standard.data(forKey: profileKey),
           let decodedProfile = try? decoder.decode(UserProfile.self, from: profileData) {
            profile = decodedProfile
        }

        if let historyData = UserDefaults.standard.data(forKey: historyKey),
           let decodedHistory = try? decoder.decode([MealPlan].self, from: historyData) {
            planHistory = decodedHistory
            latestPlan = decodedHistory.first
        }

        if authSession != nil, profile == nil {
            profile = .starter
            saveProfile()
        }
    }

    private func saveProfile() {
        guard let profile else { return }
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(profile) else { return }
        UserDefaults.standard.set(data, forKey: profileKey)
    }

    private func saveAuthSession() {
        guard let authSession else { return }
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(authSession) else { return }
        UserDefaults.standard.set(data, forKey: authSessionKey)
    }

    private func saveOnboardingState() {
        UserDefaults.standard.set(isOnboarded, forKey: onboardedKey)
    }

    private func saveHistory() {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(planHistory) else { return }
        UserDefaults.standard.set(data, forKey: historyKey)
    }
}
