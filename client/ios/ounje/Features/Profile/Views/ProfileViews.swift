import SwiftUI
import Foundation
import UserNotifications
import UIKit
import WebKit
import SafariServices
import PhotosUI
import StoreKit
import AuthenticationServices
import CryptoKit
import Security

struct ProfileTabView: View {
    @EnvironmentObject private var store: MealPlanningAppStore
    @EnvironmentObject private var savedStore: SavedRecipesStore
    @State private var isRecurringRecipesPresented = false
    @State private var isCadencePickerPresented = false
    @State private var selectedCadence: MealCadence = .weekly
    @State private var selectedAnchorDate = Date()
    @State private var isSettingsPresented = false
    @State private var isNameEditorPresented = false
    @State private var isFeedbackPresented = false
    @State private var isBudgetSheetPresented = false
    let importedRecipeCount: Int
    let aiEditCount: Int

    init(importedRecipeCount: Int = 0, aiEditCount: Int = 0) {
        self.importedRecipeCount = importedRecipeCount
        self.aiEditCount = aiEditCount
    }

    private var profile: UserProfile? {
        store.profile
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
            return ""
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
            VStack(alignment: .leading, spacing: 20) {
                if profile != nil {
                    ProfileMinimalHeader(
                        displayName: profileDisplayName,
                        email: accountEmail,
                        onEditName: { isNameEditorPresented = true },
                        onOpenFeedback: { isFeedbackPresented = true },
                        onOpenSettings: { isSettingsPresented = true }
                    )

                    ProfileMinimalActionGrid(actions: profileGridActions)

                    ProfileUsageBlock(
                        importedRecipeCount: importedRecipeCount,
                        savedRecipeCount: savedStore.savedRecipes.count,
                        aiEditCount: aiEditCount
                    )

                    ProfileMinimalSection(rows: primaryProfileRows)
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
            .padding(.bottom, 124)
        }
        .scrollIndicators(.hidden)
        .background(OunjePalette.background.ignoresSafeArea())
        .sheet(isPresented: $isNameEditorPresented) {
            ProfileNameEditSheet(
                initialName: profile?.trimmedPreferredName ?? accountDisplayName,
                onSave: updateProfileName(_:)
            )
            .presentationDetents([.height(260)])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $isBudgetSheetPresented) {
            ProfileBudgetSheet()
        }
        .sheet(isPresented: $isFeedbackPresented) {
            FeedbackSheet()
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $isRecurringRecipesPresented) {
            RecurringPrepRecipesSheet()
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $isCadencePickerPresented) {
            DeliveryScheduleSheet(
                selectedCadence: $selectedCadence,
                selectedAnchorDate: $selectedAnchorDate,
                onCancel: {
                    isCadencePickerPresented = false
                },
                onSave: {
                    saveCadenceScheduleChanges()
                }
            )
            .presentationDetents([.height(640)])
            .presentationDragIndicator(.visible)
        }
        .fullScreenCover(isPresented: $isSettingsPresented) {
            ProfileSettingsPage()
        }
    }

    private var recurringRecipeSummary: String {
        let activeCount = store.resolvedRecurringAnchorCount
        if activeCount == 0 {
            return "No active anchors"
        }
        return activeCount == 1 ? "1 active anchor" : "\(activeCount) active anchors"
    }

    private var profileDisplayName: String {
        accountDisplayName.isEmpty ? "Ounje" : accountDisplayName
    }

    private var profileGridActions: [ProfileGridActionModel] {
        guard let profile else { return [] }

        var actions: [ProfileGridActionModel] = [
            .init(
                title: "Schedule",
                detail: "\(profile.cadenceScheduleSummary) · \(profile.deliveryTimeText)",
                symbolName: "calendar",
                tint: Color(hex: "8ED4FF"),
                action: {
                    selectedCadence = profile.cadence
                    selectedAnchorDate = DeliveryScheduleSelectionBounds.clamped(
                        profile.deliveryAnchorDate ?? profile.scheduledDeliveryDate()
                    )
                    isCadencePickerPresented = true
                }
            )
        ]

        if shouldShowBudgetTile(for: profile) {
            actions.append(.init(
                title: "Budget",
                detail: profile.budgetSummary,
                symbolName: "creditcard",
                tint: OunjePalette.softCream,
                action: { isBudgetSheetPresented = true }
            ))
        }

        return actions
    }

    private var primaryProfileRows: [ProfileMinimalRowModel] {
        guard let profile else { return [] }

        var rows: [ProfileMinimalRowModel] = []

        rows.append(contentsOf: [
            .init(
                title: "Recurring meals",
                detail: recurringRecipeSummary,
                value: "Manage",
                action: { isRecurringRecipesPresented = true }
            ),
            .init(
                title: "Delivery schedule",
                detail: "\(profile.cadenceScheduleSummary) · \(profile.deliveryTimeText)",
                value: "Edit",
                action: {
                    selectedCadence = profile.cadence
                    selectedAnchorDate = DeliveryScheduleSelectionBounds.clamped(
                        profile.deliveryAnchorDate ?? profile.scheduledDeliveryDate()
                    )
                    isCadencePickerPresented = true
                }
            )
        ])

        return rows
    }

    private var profileBackground: some View {
        ZStack {
            OunjePalette.background.ignoresSafeArea()

            LinearGradient(
                colors: [
                    OunjePalette.background,
                    OunjePalette.panel.opacity(0.9),
                    OunjePalette.background
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            Circle()
                .fill(OunjePalette.accent.opacity(0.12))
                .frame(width: 220, height: 220)
                .blur(radius: 90)
            .offset(x: 120, y: -340)
        }
    }

    private func shouldShowBudgetTile(for profile: UserProfile) -> Bool {
        let budgetGoalKeywords = [
            "budget",
            "save money",
            "spend less",
            "groceries",
            "cheap",
            "cost"
        ]

        return profile.mealPrepGoals.contains { goal in
            let normalized = goal.lowercased()
            return budgetGoalKeywords.contains { normalized.contains($0) }
        }
    }

    private func saveCadenceScheduleChanges() {
        guard var updated = store.profile else {
            isCadencePickerPresented = false
            return
        }

        let resolvedAnchor = DeliveryScheduleSelectionBounds.clamped(selectedAnchorDate)
        updated.cadence = selectedCadence
        updated.deliveryAnchorDate = resolvedAnchor
        updated.deliveryAnchorDay = DeliveryAnchorDay.from(date: resolvedAnchor)
        store.updateProfile(updated)
        isCadencePickerPresented = false
    }

    private func updateProfileName(_ name: String) {
        guard var updated = store.profile else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.preferredName = trimmed.isEmpty ? nil : trimmed
        store.updateProfile(updated)
    }
}

struct ProfileMinimalRowModel: Identifiable {
    let title: String
    let detail: String
    let value: String
    let action: () -> Void

    var id: String { title }
}

struct ProfileGridActionModel: Identifiable {
    let title: String
    let detail: String
    let symbolName: String
    var tint: Color = OunjePalette.softCream
    let action: () -> Void

    var id: String { title }
}

struct ProfileMinimalHeader: View {
    let displayName: String
    let email: String?
    let onEditName: () -> Void
    let onOpenFeedback: () -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 7) {
                Button(action: onEditName) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        BiroScriptDisplayText(displayName, size: 34, color: OunjePalette.primaryText)
                            .lineLimit(1)
                            .minimumScaleFactor(0.72)

                        Image(systemName: "pencil")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(OunjePalette.secondaryText)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if let email, !email.isEmpty {
                    Text(email)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(OunjePalette.secondaryText)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            HStack(spacing: 10) {
                ProfileHeaderIconButton(
                    systemName: "bubble.left.and.bubble.right",
                    accessibilityLabel: "Open feedback",
                    action: onOpenFeedback
                )

                ProfileHeaderIconButton(
                    systemName: "gearshape",
                    accessibilityLabel: "Open settings",
                    action: onOpenSettings
                )
            }
        }
        .padding(.top, 2)
    }
}

struct ProfileHeaderIconButton: View {
    let systemName: String
    let accessibilityLabel: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(OunjePalette.primaryText.opacity(0.88))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }
}

struct ProfileNameEditSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    let onSave: (String) -> Void

    init(initialName: String, onSave: @escaping (String) -> Void) {
        _name = State(initialValue: initialName)
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Profile name")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(OunjePalette.primaryText)

                    Text("This is how Ounje addresses you in the app.")
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(OunjePalette.secondaryText)
                }

                TextField("Your name", text: $name)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled(false)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(OunjePalette.primaryText)
                    .padding(.horizontal, 14)
                    .frame(height: 52)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(OunjePalette.surface)
                            .overlay(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .stroke(Color.white.opacity(0.82), lineWidth: 2)
                            )
                    )

                Spacer(minLength: 0)
            }
            .padding(.horizontal, OunjeLayout.screenHorizontalPadding)
            .padding(.top, 20)
            .background(OunjePalette.background.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(name)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }
}

struct ProfileMinimalActionGrid: View {
    let actions: [ProfileGridActionModel]

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 12) {
            ForEach(actions) { action in
                Button(action: action.action) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .center, spacing: 0) {
                            Image(systemName: action.symbolName)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(OunjePalette.primaryText)
                                .frame(width: 28, height: 28)

                            Spacer(minLength: 0)

                            Image(systemName: "chevron.right")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(OunjePalette.secondaryText.opacity(0.48))
                        }

                        VStack(alignment: .leading, spacing: 5) {
                            Text(action.title)
                                .font(.system(size: 16, weight: .bold))
                                .foregroundStyle(OunjePalette.primaryText)
                                .lineLimit(1)

                            Text(action.detail)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(OunjePalette.secondaryText)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, minHeight: 108, alignment: .topLeading)
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(OunjePalette.panel.opacity(0.96))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(Color.white.opacity(0.82), lineWidth: 2)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct ProfileUsageBlock: View {
    let importedRecipeCount: Int
    let savedRecipeCount: Int
    let aiEditCount: Int

    private var stats: [ProfileUsageStat] {
        [
            .init(title: "Imported", value: importedRecipeCount, symbolName: "square.and.arrow.down"),
            .init(title: "Saved", value: savedRecipeCount, symbolName: "bookmark.fill"),
            .init(title: "AI edits", value: aiEditCount, symbolName: "sparkles")
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Usage")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(OunjePalette.secondaryText)

            HStack(spacing: 10) {
                ForEach(stats) { stat in
                    VStack(alignment: .leading, spacing: 8) {
                        Image(systemName: stat.symbolName)
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(OunjePalette.primaryText.opacity(0.9))

                        Text("\(stat.value)")
                            .font(.system(size: 24, weight: .heavy))
                            .foregroundStyle(OunjePalette.primaryText)
                            .monospacedDigit()

                        Text(stat.title)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(OunjePalette.secondaryText)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(OunjePalette.panel.opacity(0.92))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(OunjePalette.stroke.opacity(0.72), lineWidth: 1)
                    )
                }
            }
        }
    }
}

private struct ProfileUsageStat: Identifiable {
    let title: String
    let value: Int
    let symbolName: String

    var id: String { title }
}

struct ProfileMinimalSection: View {
    let rows: [ProfileMinimalRowModel]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                Button(action: row.action) {
                    HStack(alignment: .center, spacing: 14) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(row.title)
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(OunjePalette.primaryText)
                                .lineLimit(1)

                            Text(row.detail)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(OunjePalette.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                                .lineLimit(2)
                        }

                        Spacer(minLength: 10)

                        Text(row.value)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(OunjePalette.secondaryText)
                            .lineLimit(1)

                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(OunjePalette.secondaryText.opacity(0.45))
                    }
                    .padding(.vertical, 12)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if index < rows.count - 1 {
                    Divider()
                        .overlay(OunjePalette.stroke.opacity(0.48))
                }
            }
        }
    }
}

struct ProfileSettingsPage: View {
    @EnvironmentObject private var store: MealPlanningAppStore
    @EnvironmentObject private var notificationCenter: AppNotificationCenterManager
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @AppStorage("ounje.recipeTypographyStyle") private var recipeTypographyStyleRawValue = RecipeTypographyStyle.defaultStyle.rawValue
    @StateObject private var providersViewModel = GroceryProvidersViewModel()
    @State private var isAutonomyPickerPresented = false
    @State private var isMembershipPresented = false
    @State private var isProvidersPresented = false
    @State private var isRecipeStylePresented = false
    @State private var isFeedbackPresented = false
    @State private var isFoundersCallDialogPresented = false
    @State private var isSignOutDialogPresented = false
    @State private var isDeleteAccountDialogPresented = false
    @State private var deleteAccountErrorMessage: String?

    private var currentTier: OunjePricingTier {
        store.effectivePricingTier
    }

    private var providersSummary: String {
        if providersViewModel.isLoading {
            return "Loading"
        }

        let connectedCount = providersViewModel.providers.filter(\.connected).count
        guard !providersViewModel.providers.isEmpty else { return "Not connected" }
        return connectedCount == 0 ? "Not connected" : connectedCount == 1 ? "1 connected" : "\(connectedCount) connected"
    }

    private var instacartProvider: GroceryProviderInfo? {
        providersViewModel.providers.first { $0.id.lowercased() == "instacart" }
    }

    private var instacartConnectionSummary: String {
        if providersViewModel.isLoading {
            return "Checking"
        }
        guard let provider = instacartProvider else {
            return "Unavailable"
        }
        return provider.connected ? "Connected" : "Not connected"
    }

    private var instacartConnectionTint: Color {
        guard let provider = instacartProvider else { return OunjePalette.secondaryText }
        return provider.connected ? OunjePalette.primaryText : OunjePalette.secondaryText
    }

    private var instacartConnectionIcon: String {
        guard let provider = instacartProvider else { return "questionmark.circle.fill" }
        return provider.connected ? "checkmark.circle.fill" : "xmark.circle.fill"
    }

    private var settingsOrderingAutonomyOptions: [OrderingAutonomyLevel] {
        if !OunjeLaunchFlags.paywallsEnabled {
            return [.approvalRequired]
        }
        return OrderingAutonomyLevel.allCases.filter { $0 != .suggestOnly }
    }

    private var notificationStatusTitle: String {
        notificationCenter.authorizationStatus.ounjeSettingsTitle
    }

    private var notificationStatusTint: Color {
        notificationCenter.authorizationStatus.ounjeNeutralSettingsTint
    }

    private var privacyPolicyURL: URL? {
        URL(string: "\(OunjeDevelopmentServer.productionBaseURL)/privacy")
    }

    private var termsOfServiceURL: URL? {
        URL(string: "\(OunjeDevelopmentServer.productionBaseURL)/terms")
    }

    private var sections: [ProfileSettingsSectionModel] {
        [
            ProfileSettingsSectionModel(
                title: "Connections",
                rows: [
                    ProfileSettingsMenuRowModel(
                        icon: instacartConnectionIcon,
                        iconTint: instacartConnectionTint,
                        title: "Instacart",
                        detail: "Connection status for cart filling",
                        trailingValue: instacartConnectionSummary,
                        trailingTint: instacartConnectionTint,
                        action: {
                            providersViewModel.loadProviders(
                                userId: store.resolvedTrackingSession?.userID ?? store.authSession?.userID,
                                accessToken: store.resolvedTrackingSession?.accessToken ?? store.authSession?.accessToken
                            )
                            isProvidersPresented = true
                        }
                    )
                ]
            ),
            ProfileSettingsSectionModel(
                title: "Privacy and safety",
                rows: [
                    ProfileSettingsMenuRowModel(
                        icon: "bell.fill",
                        iconTint: notificationStatusTint,
                        title: "Notifications",
                        detail: "Device alerts and delivery updates",
                        trailingValue: notificationStatusTitle,
                        trailingTint: notificationStatusTint,
                        action: openNotificationSettings
                    ),
                    ProfileSettingsMenuRowModel(
                        icon: "star.bubble.fill",
                        iconTint: OunjePalette.secondaryText,
                        title: "Give feedback",
                        detail: "Bug reports and product notes",
                        trailingValue: nil,
                        trailingTint: OunjePalette.secondaryText,
                        action: { isFeedbackPresented = true }
                    )
                ]
            ),
            ProfileSettingsSectionModel(
                title: "Support",
                rows: [
                    ProfileSettingsMenuRowModel(
                        icon: "phone.fill",
                        iconTint: OunjePalette.secondaryText,
                        title: "Call founders",
                        detail: "Dave (CEO) · Chukelu (CTO)",
                        trailingValue: nil,
                        trailingTint: OunjePalette.secondaryText,
                        action: {
                            isFoundersCallDialogPresented = true
                        }
                    )
                ]
            ),
            ProfileSettingsSectionModel(
                title: "Legal",
                rows: [
                    ProfileSettingsMenuRowModel(
                        icon: "lock.shield.fill",
                        iconTint: OunjePalette.secondaryText,
                        title: "Privacy policy",
                        detail: "How we handle account, shopping, and feedback data",
                        trailingValue: nil,
                        trailingTint: OunjePalette.secondaryText,
                        action: {
                            if let privacyPolicyURL {
                                openURL(privacyPolicyURL)
                            }
                        }
                    ),
                    ProfileSettingsMenuRowModel(
                        icon: "doc.text.fill",
                        iconTint: OunjePalette.secondaryText,
                        title: "Terms of service",
                        detail: "Rules for using Ounje",
                        trailingValue: nil,
                        trailingTint: OunjePalette.secondaryText,
                        action: {
                            if let termsOfServiceURL {
                                openURL(termsOfServiceURL)
                            }
                        }
                    )
                ]
            ),
            ProfileSettingsSectionModel(
                title: "Session",
                rows: [
                    ProfileSettingsMenuRowModel(
                        icon: "rectangle.portrait.and.arrow.right",
                        iconTint: Color(hex: "FF8E8E"),
                        title: "Sign out",
                        detail: "Log out on this device",
                        trailingValue: nil,
                        trailingTint: OunjePalette.secondaryText,
                        showsChevron: false,
                        action: {
                            isSignOutDialogPresented = true
                        }
                    ),
                    ProfileSettingsMenuRowModel(
                        icon: "person.crop.circle.badge.xmark",
                        iconTint: Color(hex: "FF8E8E"),
                        title: "Delete account",
                        detail: store.isDeactivatingAccount ? "Deactivating account..." : "Deactivate account and stop automation",
                        trailingValue: nil,
                        trailingTint: OunjePalette.secondaryText,
                        showsChevron: false,
                        action: {
                            guard !store.isDeactivatingAccount else { return }
                            isDeleteAccountDialogPresented = true
                        }
                    )
                ]
            )
        ]
    }

    var body: some View {
        NavigationStack {
            ZStack {
                OunjePalette.background.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        settingsHeader

                        VStack(alignment: .leading, spacing: 22) {
                            ProfileSettingsAccountSectionView(
                                membershipTier: currentTier,
                                membershipSummary: currentTier.subtitle,
                                recipeStyle: RecipeTypographyStyle.resolved(from: recipeTypographyStyleRawValue),
                                isAutoshopEnabled: autoshopOptInBinding,
                                onOpenMembership: { isMembershipPresented = true },
                                onOpenRecipeStyle: { isRecipeStylePresented = true }
                            )

                            ForEach(sections) { section in
                                ProfileSettingsSectionView(section: section)
                            }
                        }
                    }
                    .padding(.horizontal, OunjeLayout.screenHorizontalPadding)
                    .padding(.top, 8)
                    .padding(.bottom, 28)
                }
                .scrollIndicators(.hidden)
            }
            .toolbar(.hidden, for: .navigationBar)
            .preferredColorScheme(.dark)
            .task {
                providersViewModel.loadProviders(
                    userId: store.resolvedTrackingSession?.userID ?? store.authSession?.userID,
                    accessToken: store.resolvedTrackingSession?.accessToken ?? store.authSession?.accessToken
                )
            }
            .confirmationDialog("Call founders", isPresented: $isFoundersCallDialogPresented, titleVisibility: .visible) {
                Button("Dave, CEO") {
                    callFounder(phoneNumber: "+14168712611")
                }

                Button("Chukelu, CTO") {
                    callFounder(phoneNumber: "+447943859174")
                }

                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Choose who you want to reach.")
            }
        }
        .sheet(isPresented: $isMembershipPresented) {
            MembershipSettingsSheet(currentTier: currentTier)
                .environmentObject(store)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $isRecipeStylePresented) {
            RecipeStyleSettingsSheet()
                .presentationDetents([.height(460)])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $isProvidersPresented) {
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        GroceryProvidersCard()
                    }
                    .padding(.horizontal, OunjeLayout.screenHorizontalPadding)
                    .padding(.top, 16)
                    .padding(.bottom, 24)
                }
                .background(OunjePalette.background.ignoresSafeArea())
                .navigationTitle("Providers")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") { isProvidersPresented = false }
                    }
                }
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $isFeedbackPresented) {
            FeedbackSheet()
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .confirmationDialog("Ordering autonomy", isPresented: $isAutonomyPickerPresented, titleVisibility: .visible) {
            if let profile = store.profile {
                ForEach(settingsOrderingAutonomyOptions) { autonomy in
                    Button(autonomy.title) {
                        if !OunjeLaunchFlags.paywallsEnabled, autonomy != .approvalRequired {
                            return
                        } else if currentTier.supports(autonomy) {
                            var updated = profile
                            updated.orderingAutonomy = autonomy
                            store.updateProfile(updated)
                        } else if OunjeLaunchFlags.paywallsEnabled {
                            isMembershipPresented = true
                        }
                    }
                }
            }
        }
        .confirmationDialog("Sign out of Ounje?", isPresented: $isSignOutDialogPresented, titleVisibility: .visible) {
            Button("Sign Out", role: .destructive) {
                store.signOutToWelcome()
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You can sign back in any time.")
        }
        .confirmationDialog("Delete your Ounje account?", isPresented: $isDeleteAccountDialogPresented, titleVisibility: .visible) {
            Button("Delete Account", role: .destructive) {
                Task { await deactivateAccount() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This deactivates your account, stops pending automation, disconnects provider sessions, and signs you out.")
        }
        .alert("Couldn’t delete account", isPresented: Binding(
            get: { deleteAccountErrorMessage != nil },
            set: { if !$0 { deleteAccountErrorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(deleteAccountErrorMessage ?? "Please try again.")
        }
    }

    private func callFounder(phoneNumber: String) {
        guard let phoneURL = URL(string: "tel:\(phoneNumber)") else { return }
        openURL(phoneURL)
    }

    private func deactivateAccount() async {
        do {
            try await store.deactivateAccount()
            dismiss()
        } catch {
            deleteAccountErrorMessage = (error as? OunjeAccountServiceError)?.errorDescription ?? error.localizedDescription
        }
    }

    private var autoshopOptInBinding: Binding<Bool> {
        Binding(
            get: {
                store.profile?.orderingAutonomy == .approvalRequired
            },
            set: { isEnabled in
                guard var updated = store.profile else { return }
                updated.orderingAutonomy = isEnabled ? .approvalRequired : .suggestOnly
                store.updateProfile(updated)
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }
        )
    }

    private var settingsHeader: some View {
        VStack(alignment: .leading, spacing: 14) {
            ZStack {
                HStack {
                    Button(action: dismiss.callAsFunction) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(OunjePalette.primaryText)
                            .frame(width: 34, height: 34)
                            .background(
                                Circle()
                                    .fill(OunjePalette.panel.opacity(0.9))
                            )
                    }
                    .buttonStyle(.plain)

                    Spacer(minLength: 0)

                    Color.clear.frame(width: 34, height: 34)
                }

                Text("Settings")
                    .font(.system(size: 23, weight: .semibold))
                    .foregroundStyle(OunjePalette.primaryText)
            }

            Capsule(style: .continuous)
                .fill(OunjePalette.stroke.opacity(0.95))
                .frame(width: 74, height: 3)
                .padding(.leading, 2)

            Divider()
                .overlay(OunjePalette.stroke.opacity(0.9))
        }
    }

    private func openNotificationSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        openURL(url)
    }
}

struct ProfileSettingsSectionModel: Identifiable {
    let id = UUID()
    let title: String
    let rows: [ProfileSettingsMenuRowModel]
}

struct ProfileSettingsMenuRowModel: Identifiable {
    let id = UUID()
    let icon: String
    let iconTint: Color
    let title: String
    let detail: String
    let trailingValue: String?
    let trailingTint: Color
    var showsChevron: Bool = true
    let action: () -> Void
}

struct ProfileSettingsAccountSectionView: View {
    let membershipTier: OunjePricingTier
    let membershipSummary: String
    let recipeStyle: RecipeTypographyStyle
    @Binding var isAutoshopEnabled: Bool
    let onOpenMembership: () -> Void
    let onOpenRecipeStyle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Account")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(OunjePalette.secondaryText)
                .padding(.leading, 2)

            VStack(spacing: 0) {
                ProfileSettingsMenuRow(
                    row: ProfileSettingsMenuRowModel(
                        icon: "creditcard.fill",
                        iconTint: OunjePalette.secondaryText,
                        title: "Membership",
                        detail: membershipSummary,
                        trailingValue: membershipTier.title,
                        trailingTint: OunjePalette.secondaryText,
                        action: onOpenMembership
                    )
                )

                Divider()
                    .overlay(OunjePalette.stroke.opacity(0.75))
                    .padding(.leading, 36)

                ProfileSettingsAutoshopToggleRow(isEnabled: $isAutoshopEnabled)

                Divider()
                    .overlay(OunjePalette.stroke.opacity(0.75))
                    .padding(.leading, 36)

                ProfileSettingsMenuRow(
                    row: ProfileSettingsMenuRowModel(
                        icon: recipeStyle == .playful ? "signature" : "textformat",
                        iconTint: OunjePalette.secondaryText,
                        title: "Visual style",
                        detail: "Choose Personal handwriting or Clean type",
                        trailingValue: recipeStyle.displayName,
                        trailingTint: OunjePalette.secondaryText,
                        action: onOpenRecipeStyle
                    )
                )
            }
            .padding(.horizontal, 2)
        }
    }
}

struct ProfileSettingsAutoshopToggleRow: View {
    @Binding var isEnabled: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "cart.badge.plus")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(OunjePalette.secondaryText)
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 4) {
                Text("Autoshop")
                    .font(.system(size: 15.5, weight: .semibold))
                    .foregroundStyle(OunjePalette.primaryText)
                    .lineLimit(1)

                Text("Fill Instacart for review. Ounje never checks out.")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(OunjePalette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 10)

            Toggle("", isOn: $isEnabled)
                .labelsHidden()
                .tint(OunjePalette.accent)
        }
        .padding(.vertical, 14)
        .contentShape(Rectangle())
    }
}

struct ProfileSettingsSectionView: View {
    let section: ProfileSettingsSectionModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(section.title)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(OunjePalette.secondaryText)
                .padding(.leading, 2)

            VStack(spacing: 0) {
                ForEach(Array(section.rows.enumerated()), id: \.element.id) { index, row in
                    ProfileSettingsMenuRow(row: row)

                    if index < section.rows.count - 1 {
                        Divider()
                            .overlay(OunjePalette.stroke.opacity(0.75))
                            .padding(.leading, 36)
                    }
                }
            }
            .padding(.horizontal, 2)
        }
    }
}

struct ProfileSettingsMenuRow: View {
    let row: ProfileSettingsMenuRowModel

    var body: some View {
        Button(action: row.action) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: row.icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(row.iconTint)
                    .frame(width: 24, height: 24)

                VStack(alignment: .leading, spacing: 4) {
                    Text(row.title)
                        .font(.system(size: 15.5, weight: .semibold))
                        .foregroundStyle(OunjePalette.primaryText)
                        .lineLimit(1)

                    Text(row.detail)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(OunjePalette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 10)

                if let trailingValue = row.trailingValue {
                    Text(trailingValue)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(row.trailingTint)
                        .multilineTextAlignment(.trailing)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(
                            Capsule(style: .continuous)
                                .fill(OunjePalette.elevated.opacity(0.82))
                                .overlay(
                                    Capsule(style: .continuous)
                                        .stroke(OunjePalette.stroke.opacity(0.58), lineWidth: 1)
                                )
                        )
                }

                if row.showsChevron {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(OunjePalette.secondaryText.opacity(0.55))
                }
            }
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

extension UNAuthorizationStatus {
    var ounjeSettingsTitle: String {
        switch self {
        case .notDetermined:
            return "Not set"
        case .denied:
            return "Off"
        case .authorized:
            return "On"
        case .provisional:
            return "Quiet"
        case .ephemeral:
            return "Temp"
        @unknown default:
            return "Unknown"
        }
    }

    var ounjeSettingsTint: Color {
        switch self {
        case .authorized, .provisional, .ephemeral:
            return OunjePalette.accent
        case .denied:
            return Color(hex: "FF8E8E")
        case .notDetermined:
            return OunjePalette.secondaryText
        @unknown default:
            return OunjePalette.secondaryText
        }
    }

    var ounjeNeutralSettingsTint: Color {
        switch self {
        case .denied:
            return Color(hex: "FF8E8E")
        default:
            return OunjePalette.secondaryText
        }
    }
}

struct MembershipSettingsSheet: View {
    @EnvironmentObject private var store: MealPlanningAppStore
    @Environment(\.dismiss) private var dismiss
    let currentTier: OunjePricingTier
    @State private var isOpeningSubscriptionManager = false
    @State private var isRestoringPurchases = false
    @State private var actionMessage: String?

    private var benefits: [(String, String)] {
        let entitlement = store.membershipEntitlement
        let cadence = currentCadence?.title ?? "Managed by Apple"
        let renewalText = entitlement?.expiresAt.map {
            $0.formatted(date: .abbreviated, time: .omitted)
        } ?? "Apple subscription settings"

        return [
            ("Membership", currentPlanTitle),
            ("Access", currentTier.subtitle),
            ("Billing", cadence),
            ("Renews", renewalText)
        ]
    }

    private var currentPlanTitle: String {
        guard currentTier != .free else { return currentTier.title }
        if let cadence = currentCadence {
            return "\(currentTier.title) · \(cadence.title)"
        }
        return currentTier.title
    }

    private var currentCadence: OunjeMembershipBillingCadence? {
        if let raw = store.membershipEntitlement?.metadata["billing_cadence"],
           let cadence = OunjeMembershipBillingCadence(rawValue: raw) {
            return cadence
        }

        guard let productID = store.membershipEntitlement?.productID?.lowercased() else {
            return nil
        }

        if productID.contains("annual") || productID.contains("year") {
            return .yearly
        }

        if productID.contains("month") {
            return .monthly
        }

        return nil
    }

    var body: some View {
        NavigationStack {
            ZStack {
                OunjePalette.background.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Membership")
                                .font(.system(size: 28, weight: .bold))
                                .foregroundStyle(OunjePalette.primaryText)
                            Text("Change your plan, cancel renewal, or update billing through Apple subscriptions.")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(OunjePalette.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(benefits.enumerated()), id: \.offset) { index, item in
                                HStack(alignment: .top, spacing: 14) {
                                    Text(item.0)
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(OunjePalette.secondaryText)
                                        .frame(width: 72, alignment: .leading)

                                    Text(item.1)
                                        .font(.system(size: 14.5, weight: .semibold))
                                        .foregroundStyle(OunjePalette.primaryText)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Spacer(minLength: 0)
                                }
                                .padding(.vertical, 14)

                                if index < benefits.count - 1 {
                                    Divider()
                                        .overlay(OunjePalette.stroke.opacity(0.8))
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                        .background(
                            RoundedRectangle(cornerRadius: 22, style: .continuous)
                                .fill(OunjePalette.panel.opacity(0.85))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                                        .stroke(OunjePalette.stroke, lineWidth: 1)
                                )
                        )

                        VStack(alignment: .leading, spacing: 8) {
                            Text("Manage membership")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(OunjePalette.primaryText)
                            Text("Apple handles subscription changes. You can switch monthly or annual, cancel renewal, and update payment there.")
                                .font(.system(size: 13.5, weight: .medium))
                                .foregroundStyle(OunjePalette.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)

                            Button {
                                Task { await openSubscriptionManager() }
                            } label: {
                                HStack(spacing: 10) {
                                    if isOpeningSubscriptionManager {
                                        ProgressView()
                                            .tint(.white)
                                            .controlSize(.small)
                                    } else {
                                        Image(systemName: "arrow.up.arrow.down.circle.fill")
                                            .font(.system(size: 16, weight: .semibold))
                                    }
                                    Text("Change or cancel plan")
                                        .font(.system(size: 15, weight: .bold))
                                    Spacer(minLength: 0)
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 12, weight: .bold))
                                }
                                .foregroundStyle(.white)
                                .padding(.horizontal, 15)
                                .frame(height: 50)
                                .background(
                                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                                        .fill(OunjePalette.accent.opacity(0.92))
                                )
                            }
                            .buttonStyle(.plain)
                            .disabled(isOpeningSubscriptionManager)
                            .padding(.top, 8)

                            Button {
                                Task { await restorePurchases() }
                            } label: {
                                HStack(spacing: 10) {
                                    if isRestoringPurchases {
                                        ProgressView()
                                            .tint(OunjePalette.primaryText)
                                            .controlSize(.small)
                                    } else {
                                        Image(systemName: "arrow.clockwise")
                                            .font(.system(size: 14, weight: .semibold))
                                    }
                                    Text("Restore purchases")
                                        .font(.system(size: 14, weight: .semibold))
                                    Spacer(minLength: 0)
                                }
                                .foregroundStyle(OunjePalette.primaryText)
                                .padding(.horizontal, 15)
                                .frame(height: 46)
                                .background(
                                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                                        .fill(OunjePalette.panel.opacity(0.88))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 15, style: .continuous)
                                                .stroke(OunjePalette.stroke, lineWidth: 1)
                                        )
                                )
                            }
                            .buttonStyle(.plain)
                            .disabled(isRestoringPurchases)
                            .padding(.top, 4)

                            VStack(alignment: .leading, spacing: 6) {
                                Text("Pause membership")
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundStyle(OunjePalette.primaryText)
                                Text("App Store subscriptions do not support an app-side pause. Cancel renewal instead; your access stays active until Apple’s expiry date.")
                                    .font(.system(size: 12.5, weight: .medium))
                                    .foregroundStyle(OunjePalette.secondaryText)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(.top, 8)

                            if let actionMessage {
                                Text(actionMessage)
                                    .font(.system(size: 12.5, weight: .semibold))
                                    .foregroundStyle(OunjePalette.secondaryText)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .padding(.top, 4)
                            }
                        }
                        .padding(16)
                        .background(
                            RoundedRectangle(cornerRadius: 22, style: .continuous)
                                .fill(OunjePalette.surface.opacity(0.88))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                                        .stroke(OunjePalette.stroke, lineWidth: 1)
                                )
                        )
                    }
                    .padding(.horizontal, OunjeLayout.screenHorizontalPadding)
                    .padding(.top, 14)
                    .padding(.bottom, 24)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    @MainActor
    private func openSubscriptionManager() async {
        guard !isOpeningSubscriptionManager else { return }
        isOpeningSubscriptionManager = true
        actionMessage = nil
        defer { isOpeningSubscriptionManager = false }

        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) else {
            actionMessage = "Couldn’t open Apple subscription settings from here."
            return
        }

        do {
            try await AppStore.showManageSubscriptions(in: scene)
            await store.refreshMembershipEntitlement(trigger: "membership-manager")
        } catch {
            actionMessage = "Couldn’t open Apple subscription settings. Try again from iOS Settings."
        }
    }

    @MainActor
    private func restorePurchases() async {
        guard !isRestoringPurchases else { return }
        isRestoringPurchases = true
        actionMessage = nil
        defer { isRestoringPurchases = false }

        let restored = await store.restoreMembershipPurchases()
        actionMessage = restored ? "Purchases restored." : "No active App Store membership found."
    }
}

struct RecipeStyleSettingsSheet: View {
    @EnvironmentObject private var store: MealPlanningAppStore
    @Environment(\.dismiss) private var dismiss
    @AppStorage("ounje.recipeTypographyStyle") private var recipeTypographyStyleRawValue = RecipeTypographyStyle.defaultStyle.rawValue

    private var selectedStyle: RecipeTypographyStyle {
        RecipeTypographyStyle.resolved(from: recipeTypographyStyleRawValue)
    }

    private var previewRecipe: DiscoverRecipeCardData {
        DiscoverRecipeCardData(
            id: "8c02aaff-33cd-4927-8c81-aae45e015c0d",
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
            recipeURLString: nil,
            source: "Ounje"
        )
    }

    var body: some View {
        NavigationStack {
            ZStack {
                OunjePalette.background.ignoresSafeArea()

                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Visual style")
                            .font(.system(size: 26, weight: .bold))
                            .foregroundStyle(OunjePalette.primaryText)

                        Text("Switch between our personal handwritten recipe style and a cleaner standard style.")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(OunjePalette.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    HStack(spacing: 12) {
                        styleChoice(.playful)
                        styleChoice(.clean)
                    }

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, OunjeLayout.screenHorizontalPadding)
                .padding(.top, 20)
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func styleChoice(_ style: RecipeTypographyStyle) -> some View {
        Button {
            recipeTypographyStyleRawValue = style.rawValue
            persistRecipeStyle(style)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    if style == .playful {
                        Text(style.displayName)
                            .sleeDisplayFont(20)
                            .foregroundStyle(OunjePalette.primaryText)
                    } else {
                        Text(style.displayName)
                            .font(.system(size: 17, weight: .bold, design: .serif))
                            .foregroundStyle(OunjePalette.primaryText)
                    }

                    Spacer(minLength: 8)

                    Image(systemName: selectedStyle == style ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(selectedStyle == style ? OunjePalette.accent : Color.white.opacity(0.42))
                }

                VStack(alignment: .leading, spacing: 12) {
                    Image("CrunchyMisoSalmonPreview")
                        .resizable()
                        .scaledToFill()
                        .frame(width: 108, height: 108)
                        .clipShape(Circle())
                        .frame(maxWidth: .infinity)

                    RecipeTypographyTitleText(
                        previewRecipe.title,
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
                        Text(previewRecipe.compactCookTime ?? "15 mins")
                            .font(.system(size: 12, weight: .bold))
                    }
                    .foregroundStyle(OunjePalette.secondaryText)
                }
                .padding(12)
                .frame(maxWidth: .infinity, minHeight: 224, maxHeight: 224, alignment: .topLeading)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(OunjePalette.panel.opacity(0.95))
                        .overlay(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .stroke(selectedStyle == style ? Color.white.opacity(0.9) : OunjePalette.stroke.opacity(0.8), lineWidth: selectedStyle == style ? 2 : 1)
                        )
                )
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .buttonStyle(.plain)
    }

    private func persistRecipeStyle(_ style: RecipeTypographyStyle) {
        guard var updated = store.profile else { return }
        let prefix = "Recipe style:"
        var goals = updated.mealPrepGoals.filter {
            !$0.localizedCaseInsensitiveContains(prefix)
        }
        goals.append("\(prefix) \(style.rawValue)")
        updated.mealPrepGoals = goals
        store.updateProfile(updated)
    }
}

struct ProfileBudgetSheet: View {
    @EnvironmentObject private var store: MealPlanningAppStore
    @Environment(\.dismiss) private var dismiss
    @State private var budgetPerCycle = UserProfile.starter.budgetPerCycle
    @State private var budgetWindow = UserProfile.starter.budgetWindow

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ThemedCard {
                        VStack(alignment: .leading, spacing: 14) {
                            SleeScriptDisplayText("Budget", size: 30, color: OunjePalette.primaryText)

                            Picker("Budget window", selection: $budgetWindow) {
                                ForEach(BudgetWindow.allCases) { option in
                                    Text(option == .weekly ? "Weekly" : "Monthly")
                                        .tag(option)
                                }
                            }
                            .pickerStyle(.segmented)

                            VStack(alignment: .leading, spacing: 8) {
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text(budgetPerCycle.asCurrency)
                                        .sleeDisplayFont(32)
                                        .foregroundStyle(OunjePalette.primaryText)
                                    Text(budgetWindow == .weekly ? "per week" : "per month")
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundStyle(OunjePalette.secondaryText)
                                }

                                Slider(value: $budgetPerCycle, in: budgetRange, step: budgetStep)
                                    .tint(OunjePalette.softCream)
                            }
                        }
                    }

                }
                .padding(.horizontal, OunjeLayout.screenHorizontalPadding)
                .padding(.top, 18)
                .padding(.bottom, 24)
            }
            .background(OunjePalette.background.ignoresSafeArea())
            .navigationTitle("Budget")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saveBudget()
                    }
                }
            }
        }
        .onAppear {
            syncFromProfile()
        }
        .onChange(of: budgetWindow) { _ in
            budgetPerCycle = min(max(budgetPerCycle, budgetRange.lowerBound), budgetRange.upperBound)
        }
    }

    private var budgetRange: ClosedRange<Double> {
        switch budgetWindow {
        case .weekly:
            return 25...400
        case .monthly:
            return 100...1600
        }
    }

    private var budgetStep: Double {
        budgetWindow == .weekly ? 5 : 20
    }

    private func syncFromProfile() {
        let source = store.profile ?? .starter
        budgetPerCycle = source.budgetPerCycle
        budgetWindow = source.budgetWindow
    }

    private func saveBudget() {
        guard var updated = store.profile else {
            dismiss()
            return
        }

        updated.budgetPerCycle = budgetPerCycle
        updated.budgetWindow = budgetWindow
        store.updateProfile(updated)
        dismiss()
    }
}

struct FeedbackSheet: View {
    @EnvironmentObject private var store: MealPlanningAppStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var feedbackDraft: String = ""
    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    @State private var photoAttachments: [FeedbackPhotoAttachment] = []
    @State private var threadMessages: [AppFeedbackMessage] = []
    @State private var isLoadingMessages = false
    @State private var isSubmittingFeedback = false
    @State private var feedbackErrorMessage: String?
    @State private var isFoundersCallDialogPresented = false
    @FocusState private var isComposerFocused: Bool

    private let feedbackBottomAnchorID = "feedback-thread-bottom-anchor"
    private let feedbackCanvasBackground = OunjePalette.background
    private let feedbackSystemBubbleBackground = OunjePalette.panel
    private let feedbackUserBubbleBackground = OunjePalette.accent
    private let feedbackComposerBackground = OunjePalette.panel.opacity(0.92)
    private let feedbackPromptTimestamp = Date().formatted(date: .omitted, time: .shortened)
    private var trimmedFeedbackDraft: String {
        feedbackDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSubmit: Bool {
        !trimmedFeedbackDraft.isEmpty || !photoAttachments.isEmpty
    }

    private var groupedFeedbackSections: [FeedbackDateSection] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: threadMessages) { message in
            calendar.startOfDay(for: message.createdAt)
        }
        return grouped.keys.sorted().map { day in
            FeedbackDateSection(
                day: day,
                title: feedbackDateTitle(for: day),
                messages: grouped[day, default: []].sorted { $0.createdAt < $1.createdAt }
            )
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                feedbackCanvasBackground.ignoresSafeArea()

                VStack(spacing: 0) {
                    feedbackHeader
                    feedbackThread
                }
            }
            .confirmationDialog("Call founders", isPresented: $isFoundersCallDialogPresented, titleVisibility: .visible) {
                Button("Dave, CEO") {
                    callFounder(phoneNumber: "+14168712611")
                }

                Button("Chukelu, CTO") {
                    callFounder(phoneNumber: "+447943859174")
                }

                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Choose who you want to reach.")
            }
            .safeAreaInset(edge: .bottom) {
                feedbackComposer
                    .padding(.horizontal, OunjeLayout.screenHorizontalPadding)
                    .padding(.top, 6)
                    .padding(.bottom, 8)
                    .background(feedbackCanvasBackground.ignoresSafeArea(edges: .bottom))
            }
            .onChange(of: selectedPhotoItems.count) { count in
                guard count > 0 else { return }
                let items = selectedPhotoItems
                Task {
                    await preparePhotoAttachments(from: items)
                }
            }
            .task {
                await loadFeedbackThread()
            }
            .navigationBarBackButtonHidden(true)
            .scrollDismissesKeyboard(.interactively)
        }
    }

    private var feedbackHeader: some View {
        HStack {
            Button(action: dismiss.callAsFunction) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(OunjePalette.secondaryText)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)

            SleeScriptDisplayText("Ounje", size: 28, color: OunjePalette.softCream)
                .frame(maxWidth: .infinity, alignment: .center)

            Button {
                isFoundersCallDialogPresented = true
            } label: {
                Image(systemName: "phone.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(OunjePalette.softCream)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, OunjeLayout.screenHorizontalPadding)
        .padding(.top, 14)
        .padding(.bottom, 4)
    }

    private func callFounder(phoneNumber: String) {
        guard let phoneURL = URL(string: "tel:\(phoneNumber)") else { return }
        openURL(phoneURL)
    }

    private var feedbackThread: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    openingPromptBubble

                    if isLoadingMessages {
                        ProgressView()
                            .tint(OunjePalette.accent)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, 8)
                    } else if threadMessages.isEmpty {
                        EmptyView()
                    } else {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(groupedFeedbackSections) { section in
                                feedbackDateSeparator(section.title)
                                    .id(section.id)

                                ForEach(section.messages) { message in
                                    feedbackMessageRow(message)
                                        .id(message.id)
                                }
                            }
                        }
                    }

                    if let feedbackErrorMessage, !feedbackErrorMessage.isEmpty {
                        Text(feedbackErrorMessage)
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(Color(red: 0.82, green: 0.32, blue: 0.27))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    Color.clear
                        .frame(height: 1)
                        .id(feedbackBottomAnchorID)
                }
                .padding(.horizontal, OunjeLayout.screenHorizontalPadding)
                .padding(.top, 10)
                .padding(.bottom, 16)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                isComposerFocused = false
            }
            .onChange(of: threadMessages.count) { _ in
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(feedbackBottomAnchorID, anchor: .bottom)
                }
            }
        }
    }

    private var openingPromptBubble: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("What do you love/hate about Ounje? This goes directly to the founders.")
                .font(.system(size: 14.5, weight: .regular))
                .foregroundStyle(OunjePalette.primaryText)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(feedbackSystemBubbleBackground)
                )
                .frame(maxWidth: 310, alignment: .leading)

            Text(feedbackPromptTimestamp)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(OunjePalette.secondaryText.opacity(0.82))
                .padding(.leading, 2)
        }
    }

    private var feedbackComposer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !photoAttachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(photoAttachments) { attachment in
                            ZStack(alignment: .topTrailing) {
                                Image(uiImage: attachment.image)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 72, height: 72)
                                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                                Button {
                                    removePhotoAttachment(id: attachment.id)
                                } label: {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 9, weight: .black))
                                        .foregroundStyle(Color.white)
                                        .frame(width: 18, height: 18)
                                        .background(Circle().fill(Color.black.opacity(0.78)))
                                }
                                .buttonStyle(.plain)
                                .offset(x: 5, y: -5)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }

            HStack(alignment: .bottom, spacing: 8) {
                PhotosPicker(
                    selection: $selectedPhotoItems,
                    maxSelectionCount: max(0, 4 - photoAttachments.count),
                    matching: .images,
                    photoLibrary: .shared()
                ) {
                    Circle()
                        .fill(Color(hex: "E7E7EA"))
                        .frame(width: 36, height: 36)
                        .overlay(
                            Image(systemName: "plus")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(Color(hex: "7A7A7A"))
                        )
                }
                .buttonStyle(.plain)

                TextField("Message", text: $feedbackDraft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .focused($isComposerFocused)
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(OunjePalette.primaryText)
                    .lineLimit(1...4)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(feedbackComposerBackground)
                    )

                Button {
                    Task {
                        await submitFeedback()
                    }
                } label: {
                    Image(systemName: isSubmittingFeedback ? "hourglass" : "paperplane.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(canSubmit ? Color.white : OunjePalette.secondaryText.opacity(0.72))
                        .frame(width: 36, height: 36)
                        .background(
                            Circle()
                                .fill(canSubmit ? OunjePalette.accent : OunjePalette.surface)
                        )
                }
                .buttonStyle(.plain)
                .disabled(!canSubmit || isSubmittingFeedback)
            }
        }
    }

    private func feedbackDateTitle(for day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(date: .abbreviated, time: .omitted)
    }

    private func feedbackDateSeparator(_ title: String) -> some View {
        HStack(spacing: 10) {
            Rectangle()
                .fill(OunjePalette.stroke.opacity(0.72))
                .frame(height: 1)

            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(OunjePalette.secondaryText.opacity(0.82))
                .lineLimit(1)

            Rectangle()
                .fill(OunjePalette.stroke.opacity(0.72))
                .frame(height: 1)
        }
        .padding(.vertical, 4)
        .accessibilityLabel(title)
    }

    @ViewBuilder
    private func feedbackMessageRow(_ message: AppFeedbackMessage) -> some View {
        let isOutgoing = message.authorRole.lowercased() == "user"

        VStack(alignment: isOutgoing ? .trailing : .leading, spacing: 4) {
            HStack {
                if isOutgoing { Spacer(minLength: 44) }

                VStack(alignment: .leading, spacing: 6) {
                    if !message.body.isEmpty {
                        Text(message.body)
                            .font(.system(size: 14.5, weight: .regular))
                            .foregroundStyle(isOutgoing ? OunjePalette.softCream : OunjePalette.primaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if !message.attachments.isEmpty {
                        Text(message.attachments.count == 1 ? "1 photo attached" : "\(message.attachments.count) photos attached")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(isOutgoing ? OunjePalette.softCream.opacity(0.84) : OunjePalette.secondaryText)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(isOutgoing ? feedbackUserBubbleBackground : feedbackSystemBubbleBackground)
                        .overlay(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .stroke(isOutgoing ? OunjePalette.accent.opacity(0.12) : OunjePalette.stroke.opacity(0.9), lineWidth: 1)
                        )
                )
                .frame(maxWidth: 300, alignment: isOutgoing ? .trailing : .leading)

                if !isOutgoing { Spacer(minLength: 44) }
            }

            Text(message.createdAt.formatted(date: .omitted, time: .shortened))
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(OunjePalette.secondaryText.opacity(0.82))
                .padding(.leading, isOutgoing ? 0 : 2)
                .padding(.trailing, isOutgoing ? 2 : 0)
        }
        .frame(maxWidth: .infinity, alignment: isOutgoing ? .trailing : .leading)
    }

    private func submitFeedback() async {
        guard canSubmit, !isSubmittingFeedback else { return }

        guard let userID = store.resolvedTrackingSession?.userID ?? store.authSession?.userID else {
            feedbackErrorMessage = "Feedback is unavailable until your session is live."
            return
        }

        UINotificationFeedbackGenerator().notificationOccurred(.success)
        let draftBody = trimmedFeedbackDraft
        let outgoingPhotos = photoAttachments
        let attachmentMetadata = outgoingPhotos.map { attachment in
            AppFeedbackMessageAttachment(
                fileName: attachment.fileName,
                mimeType: attachment.mimeType,
                kind: "image"
            )
        }

        isSubmittingFeedback = true
        defer { isSubmittingFeedback = false }

        do {
            let response = try await OunjeFeedbackService.shared.submitFeedback(
                userID: userID,
                body: draftBody,
                attachments: attachmentMetadata
            )

            feedbackErrorMessage = nil
            threadMessages = mergedThreadMessages(threadMessages + response.items)
            feedbackDraft = ""
            photoAttachments = []
            selectedPhotoItems = []
            isComposerFocused = false

        } catch {
            feedbackErrorMessage = (error as? FeedbackServiceError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func preparePhotoAttachments(from items: [PhotosPickerItem]) async {
        var loaded: [FeedbackPhotoAttachment] = photoAttachments
        for item in items {
            guard loaded.count < 4 else { break }
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data) else { continue }

            let normalizedImage = image.ounjeResized(maxDimension: 1600)
            let jpegData = normalizedImage.jpegData(compressionQuality: 0.82) ?? data
            loaded.append(
                FeedbackPhotoAttachment(
                    image: normalizedImage,
                    data: jpegData,
                    mimeType: "image/jpeg",
                    fileName: "feedback-photo-\(UUID().uuidString).jpg"
                )
            )
        }

        await MainActor.run {
            photoAttachments = Array(loaded.prefix(4))
            selectedPhotoItems = []
        }
    }

    private func removePhotoAttachment(id: UUID) {
        photoAttachments.removeAll { $0.id == id }
    }

    private func loadFeedbackThread() async {
        guard let userID = store.resolvedTrackingSession?.userID ?? store.authSession?.userID else { return }
        isLoadingMessages = true
        defer { isLoadingMessages = false }

        do {
            let fetched = try await OunjeFeedbackService.shared.fetchMessages(userID: userID)
            threadMessages = mergedThreadMessages(fetched)
            feedbackErrorMessage = nil
        } catch {
            feedbackErrorMessage = (error as? FeedbackServiceError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func mergedThreadMessages(_ messages: [AppFeedbackMessage]) -> [AppFeedbackMessage] {
        var seen = Set<UUID>()
        return messages
            .sorted { $0.createdAt < $1.createdAt }
            .filter { !isMutedAutomationFollowUpMessage($0) }
            .filter { seen.insert($0.id).inserted }
    }

    private func isMutedAutomationFollowUpMessage(_ message: AppFeedbackMessage) -> Bool {
        guard message.authorRole.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "system" else {
            return false
        }

        let normalized = message.body
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return normalized.contains("keep you posted")
    }
}

struct FeedbackDateSection: Identifiable {
    let day: Date
    let title: String
    let messages: [AppFeedbackMessage]

    var id: String { String(Int(day.timeIntervalSince1970)) }
}

struct FeedbackPhotoAttachment: Identifiable {
    let id = UUID()
    let image: UIImage
    let data: Data
    let mimeType: String
    let fileName: String
}

struct RecurringPrepRecipesSheet: View {
    @EnvironmentObject private var store: MealPlanningAppStore
    @EnvironmentObject private var toastCenter: AppToastCenter
    @Environment(\.dismiss) private var dismiss
    @State private var isUpdatingRecipeIDs: Set<String> = []

    private var recurringRecipes: [RecurringPrepRecipe] {
        store.recurringPrepRecipes
            .filter(\.isEnabled)
            .sorted { $0.sortDate > $1.sortDate }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ThemedCard {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Recurring recipes")
                                .biroHeaderFont(28)
                                .foregroundStyle(OunjePalette.primaryText)

                            Text("Recurring anchors are folded into the next prep generation automatically. Remove one here if you want future prep cycles to stop carrying it forward.")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(OunjePalette.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    if recurringRecipes.isEmpty {
                        ThemedCard {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("No recurring recipes yet")
                                    .font(.system(size: 18, weight: .semibold))
                                    .foregroundStyle(OunjePalette.primaryText)
                                Text("Tap the recurring icon on a prep card to pin it into future prep cycles.")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(OunjePalette.secondaryText)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    } else {
                        VStack(spacing: 12) {
                            ForEach(recurringRecipes) { recurring in
                                Button {
                                    guard !isUpdatingRecipeIDs.contains(recurring.recipeID) else { return }
                                    guard !store.isRecurringPrepRecipeToggleInFlight(recipeID: recurring.recipeID) else { return }
                                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                    toastCenter.show(
                                        title: "Removed from recurring",
                                        subtitle: recurring.recipe.title,
                                        systemImage: "repeat.circle"
                                    )
                                    isUpdatingRecipeIDs.insert(recurring.recipeID)
                                    Task {
                                        let succeeded = await store.toggleRecurringPrepRecipe(recurring.recipe)
                                        await MainActor.run {
                                            isUpdatingRecipeIDs.remove(recurring.recipeID)
                                            guard !succeeded else { return }
                                            toastCenter.show(
                                                title: "Couldn’t update recurring",
                                                subtitle: "Check your connection and try again.",
                                                systemImage: "exclamationmark.triangle.fill"
                                            )
                                        }
                                    }
                                } label: {
                                    HStack(alignment: .top, spacing: 14) {
                                        RecurringRecipeThumbnail(
                                            recipe: DiscoverRecipeCardData(
                                                preppedRecipe: PlannedRecipe(
                                                    recipe: recurring.recipe,
                                                    servings: 1,
                                                    carriedFromPreviousPlan: false
                                                )
                                            )
                                        )
                                            .frame(width: 56, height: 56)

                                        VStack(alignment: .leading, spacing: 5) {
                                            Text(recurring.recipe.title)
                                                .font(.system(size: 16, weight: .semibold))
                                                .foregroundStyle(OunjePalette.primaryText)
                                                .lineLimit(2)

                                            Text("Will be pulled into the next prep build unless removed.")
                                                .font(.system(size: 12.5, weight: .medium))
                                                .foregroundStyle(OunjePalette.secondaryText)
                                                .fixedSize(horizontal: false, vertical: true)
                                        }

                                        Spacer(minLength: 8)

                                        if isUpdatingRecipeIDs.contains(recurring.recipeID) {
                                            ProgressView()
                                                .tint(OunjePalette.accent)
                                                .padding(.top, 10)
                                        } else {
                                            Text("Remove")
                                                .font(.system(size: 12, weight: .semibold))
                                                .foregroundStyle(OunjePalette.primaryText)
                                                .padding(.horizontal, 10)
                                                .padding(.vertical, 6)
                                                .background(OunjePalette.surface, in: Capsule())
                                        }
                                    }
                                    .padding(14)
                                    .background(
                                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                                            .fill(OunjePalette.surface)
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 20, style: .continuous)
                                                    .stroke(OunjePalette.stroke, lineWidth: 1)
                                            )
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding(.horizontal, OunjeLayout.screenHorizontalPadding)
                .padding(.top, 14)
                .padding(.bottom, 18)
            }
            .background(OunjePalette.background.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

struct RecurringRecipeThumbnail: View {
    let recipe: DiscoverRecipeCardData
    @StateObject private var loader = DiscoverRecipeImageLoader()

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(OunjePalette.surface)

            if let uiImage = loader.image {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 56, height: 56)
                    .clipped()
            } else if loader.isLoading {
                ProgressView()
                    .tint(OunjePalette.accent)
            } else {
                VStack(spacing: 4) {
                    Text(String(recipe.displayTitle.prefix(2)).uppercased())
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(OunjePalette.primaryText)
                    Text(recipe.filterLabel)
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(OunjePalette.secondaryText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .padding(.horizontal, 4)
            }
        }
        .frame(width: 56, height: 56)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(OunjePalette.stroke, lineWidth: 1)
        )
        .task(id: recipe.imageCandidates.map(\.absoluteString).joined(separator: "|")) {
            await loader.load(from: recipe.imageCandidates)
        }
    }
}

@MainActor
final class OunjeBackendHealthMonitor: ObservableObject {
    enum Status: Equatable {
        case checking
        case connected
        case unreachable

        var title: String {
            switch self {
            case .checking: return "Checking"
            case .connected: return "Connected"
            case .unreachable: return "Unreachable"
            }
        }

        var accentColor: Color {
            switch self {
            case .checking: return OunjePalette.secondaryText
            case .connected: return OunjePalette.accent
            case .unreachable: return Color(hex: "FF8E8E")
            }
        }

        var neutralTint: Color {
            switch self {
            case .unreachable:
                return Color(hex: "FF8E8E")
            default:
                return OunjePalette.secondaryText
            }
        }

        var iconName: String {
            switch self {
            case .checking: return "clock"
            case .connected: return "checkmark.circle.fill"
            case .unreachable: return "exclamationmark.triangle.fill"
            }
        }
    }

    @Published private(set) var status: Status = .checking
    @Published private(set) var baseURL: String = OunjeDevelopmentServer.baseURL
    @Published private(set) var lastCheckedAt: Date?

    var routingDescription: String {
        #if targetEnvironment(simulator)
        return "Simulator checks the primary API route first"
        #else
        return "Device checks the primary API before the worker fallback"
        #endif
    }

    func refresh() async {
        baseURL = OunjeDevelopmentServer.baseURL
        status = .checking

        guard let url = URL(string: "\(baseURL)/") else {
            status = .unreachable
            lastCheckedAt = Date()
            return
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 4

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) {
                status = .connected
            } else {
                status = .unreachable
            }
        } catch {
            status = .unreachable
        }

        lastCheckedAt = Date()
    }
}

struct BackendConnectionStatusCard: View {
    @ObservedObject var monitor: OunjeBackendHealthMonitor

    var body: some View {
        ThemedCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Server connection")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(OunjePalette.primaryText)
                        Text(monitor.routingDescription)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(OunjePalette.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 8)

                    HStack(spacing: 6) {
                        Image(systemName: monitor.status.iconName)
                            .font(.system(size: 11, weight: .bold))
                        Text(monitor.status.title)
                            .font(.system(size: 11, weight: .bold))
                    }
                    .foregroundStyle(monitor.status.accentColor)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        Capsule(style: .continuous)
                            .fill(monitor.status.accentColor.opacity(0.12))
                    )
                }

                Text(monitor.baseURL)
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundStyle(OunjePalette.primaryText.opacity(0.88))
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    if let lastCheckedAt = monitor.lastCheckedAt {
                        Text("Checked \(lastCheckedAt.formatted(date: .omitted, time: .shortened))")
                    } else {
                        Text("Last check pending")
                    }

                    Spacer(minLength: 8)

                    Button {
                        Task {
                            await monitor.refresh()
                        }
                    } label: {
                        Text("Refresh")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(OunjePalette.accent)
                    }
                    .buttonStyle(.plain)
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(OunjePalette.secondaryText)
            }
        }
    }
}

struct ProfileSettingRowModel: Identifiable {
    let id = UUID()
    let icon: String
    let title: String
    let value: String
    var isDestructive = false
    let action: () -> Void
}

// MARK: - Grocery Providers Connection

struct GroceryProvidersCard: View {
    @EnvironmentObject private var store: MealPlanningAppStore
    @StateObject private var viewModel = GroceryProvidersViewModel()
    @State private var selectedProvider: GroceryProviderInfo?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SleeScriptDisplayText("Providers", size: 24, color: OunjePalette.primaryText)

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

struct GroceryProviderInfo: Identifiable {
    let id: String
    let name: String
    var connected: Bool
}

@MainActor
class GroceryProvidersViewModel: ObservableObject {
    @Published var providers: [GroceryProviderInfo] = [
        GroceryProviderInfo(id: "instacart", name: "Instacart", connected: false),
    ]
    @Published var isLoading = false

    func loadProviders(userId: String?, accessToken: String?) {
        Task {
            isLoading = true
            defer { isLoading = false }

            guard let url = URL(string: "\(OunjeDevelopmentServer.workerBaseURL)/v1/connect/providers") else { return }

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
                providers = response.providers
                    .filter {
                        let id = $0.id.lowercased()
                        let name = $0.name.lowercased()
                        return !id.contains("walmart") && !name.contains("walmart")
                    }
                    .map { p in
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

struct GroceryProviderConnectSheet: View {
    @EnvironmentObject private var store: MealPlanningAppStore
    let provider: GroceryProviderInfo
    let userId: String
    let accessToken: String?
    let onConnected: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var phase: Phase = .instructions
    @State private var isLoading = false
    @State private var isSaving = false
    @State private var appleReauthNonce = ""
    @State private var isRefreshingOunjeLogin = false

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

            Text("* we don't store any log in details")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(OunjePalette.secondaryText.opacity(0.9))
                .frame(maxWidth: .infinity, alignment: .leading)

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

            if isOunjeSessionRefreshRequired(message) {
                SignInWithAppleButton(.continue) { request in
                    prepareAppleReauthRequest(request)
                } onCompletion: { result in
                    handleAppleReauthCompletion(result)
                }
                .signInWithAppleButtonStyle(.white)
                .frame(maxWidth: 320)
                .frame(height: 48)
                .clipShape(Capsule(style: .continuous))
                .disabled(isRefreshingOunjeLogin)

                Text("This only refreshes your Ounje login token so Instacart can link securely.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(OunjePalette.secondaryText.opacity(0.9))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8)
            } else {
                Button("Try Again") { phase = .instructions }
                    .buttonStyle(.borderedProminent)
            }
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
            let liveSession = await store.freshTrackingSession() ?? store.resolvedTrackingSession ?? store.authSession
            let resolvedUserID = liveSession?.userID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                ? liveSession!.userID
                : userId.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedAccessToken = liveSession?.accessToken?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                ? liveSession?.accessToken?.trimmingCharacters(in: .whitespacesAndNewlines)
                : accessToken?.trimmingCharacters(in: .whitespacesAndNewlines)

            guard !resolvedUserID.isEmpty else {
                phase = .error("Your Ounje session is missing. Close this sheet and sign in again.")
                return
            }

            guard let resolvedAccessToken, !resolvedAccessToken.isEmpty else {
                phase = .error(sessionRefreshRequiredMessage)
                return
            }

            let cookies = await readProviderCookiesFromWebLogin()
            guard !cookies.isEmpty else {
                phase = .error("No session found yet. Finish logging in, then tap Link session again.")
                return
            }
            try await saveCookies(cookies, userID: resolvedUserID, accessToken: resolvedAccessToken)
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

    private func saveCookies(_ cookies: [[String: Any]], userID: String, accessToken: String) async throws {
        guard let url = URL(string: "\(OunjeDevelopmentServer.workerBaseURL)/v1/connect/\(provider.id)/save-session") else {
            throw URLError(.badURL)
        }
        do {
            try await performSaveCookiesRequest(cookies, userID: userID, accessToken: accessToken, url: url)
        } catch let error as ProviderConnectAPIError {
            guard error.isExpiredJWT else {
                throw error
            }

            let refreshedSession: AuthSession?
            do {
                refreshedSession = try await refreshProviderConnectSession()
            } catch {
                throw ProviderConnectAPIError(message: sessionRefreshRequiredMessage)
            }

            guard let refreshedSession,
                  let refreshedAccessToken = refreshedSession.accessToken?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !refreshedAccessToken.isEmpty
            else {
                throw ProviderConnectAPIError(message: sessionRefreshRequiredMessage)
            }

            let refreshedUserID = refreshedSession.userID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !refreshedUserID.isEmpty else {
                throw ProviderConnectAPIError(message: sessionRefreshRequiredMessage)
            }

            try await performSaveCookiesRequest(
                cookies,
                userID: refreshedUserID,
                accessToken: refreshedAccessToken,
                url: url
            )
        }
    }

    private func performSaveCookiesRequest(
        _ cookies: [[String: Any]],
        userID: String,
        accessToken: String,
        url: URL
    ) async throws {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(userID, forHTTPHeaderField: "x-user-id")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["cookies": cookies])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let backendError = (try? JSONDecoder().decode(ProviderConnectAPIErrorPayload.self, from: data))?.error
            throw ProviderConnectAPIError(message: backendError ?? "Link session failed (\(httpResponse.statusCode)).")
        }
    }

    @MainActor
    private func refreshProviderConnectSession() async throws -> AuthSession? {
        let fallbackSession = [store.authSession, store.resolvedTrackingSession]
            .compactMap { $0 }
            .first { session in
                session.refreshToken?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            }
        guard let fallbackSession,
              let refreshToken = fallbackSession.refreshToken?.trimmingCharacters(in: .whitespacesAndNewlines),
              !refreshToken.isEmpty else {
            return nil
        }

        let tokenResponse = try await SupabaseAuthSessionRefreshService.shared.refreshSession(refreshToken: refreshToken)
        let refreshedSession = AuthSession(
            provider: fallbackSession.provider,
            userID: tokenResponse.userID,
            email: tokenResponse.email ?? fallbackSession.email,
            displayName: tokenResponse.displayName ?? fallbackSession.displayName,
            signedInAt: fallbackSession.signedInAt,
            accessToken: tokenResponse.accessToken,
            refreshToken: tokenResponse.refreshToken ?? fallbackSession.refreshToken
        )
        store.persistAuthSession(refreshedSession)
        return refreshedSession
    }

    private var sessionRefreshRequiredMessage: String {
        "Your Ounje login needs to be refreshed before linking \(provider.name)."
    }

    private func isOunjeSessionRefreshRequired(_ message: String) -> Bool {
        message.localizedCaseInsensitiveContains("Ounje login needs to be refreshed") ||
            message.localizedCaseInsensitiveContains("Ounje session expired") ||
            message.localizedCaseInsensitiveContains("Authorization expired or invalid") ||
            message.localizedCaseInsensitiveContains("Could not resolve authenticated user")
    }

    private func prepareAppleReauthRequest(_ request: ASAuthorizationAppleIDRequest) {
        request.requestedScopes = [.fullName, .email]
        let nonce = randomNonceString()
        appleReauthNonce = nonce
        request.nonce = sha256(nonce)
    }

    private func handleAppleReauthCompletion(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .success(let authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else {
                phase = .error("Could not read Apple account credentials.")
                return
            }
            guard let identityTokenData = credential.identityToken,
                  let identityToken = String(data: identityTokenData, encoding: .utf8),
                  !identityToken.isEmpty else {
                phase = .error("Apple sign-in did not return a valid identity token.")
                return
            }
            guard !appleReauthNonce.isEmpty else {
                phase = .error("Apple sign-in nonce was missing. Please try again.")
                return
            }

            isRefreshingOunjeLogin = true
            Task { @MainActor in
                defer { isRefreshingOunjeLogin = false }
                do {
                    let formatter = PersonNameComponentsFormatter()
                    let fallbackName = credential.fullName
                        .map { formatter.string(from: $0).trimmingCharacters(in: .whitespacesAndNewlines) }
                        .flatMap { $0.isEmpty ? nil : $0 }
                    let authResult = try await SupabaseAppleAuthService.shared.signInWithApple(
                        idToken: identityToken,
                        rawNonce: appleReauthNonce
                    )
                    let expectedUserID = (store.authSession?.userID ?? userId)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let appleSubject = appleSubject(fromIdentityToken: identityToken)
                    let isSameCachedAppleUser = appleSubject?.isEmpty == false && appleSubject == expectedUserID
                    guard expectedUserID.isEmpty || authResult.userID == expectedUserID || isSameCachedAppleUser else {
                        phase = .error("Use the same Ounje account you started with before linking \(provider.name).")
                        return
                    }

                    let refreshedSession = AuthSession(
                        provider: .apple,
                        userID: authResult.userID,
                        email: authResult.email ?? credential.email ?? store.authSession?.email,
                        displayName: authResult.displayName ?? fallbackName ?? store.authSession?.displayName,
                        signedInAt: store.authSession?.signedInAt ?? Date(),
                        accessToken: authResult.accessToken,
                        refreshToken: authResult.refreshToken
                    )
                    store.persistAuthSession(refreshedSession)
                    await saveSessionFromWebLogin()
                } catch {
                    phase = .error(error.localizedDescription)
                }
            }
        case .failure(let error):
            if let authError = error as? ASAuthorizationError, authError.code == .canceled {
                return
            }
            phase = .error(error.localizedDescription)
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
            if status == errSecSuccess, random < charset.count {
                result.append(charset[Int(random)])
            }
        }

        return result
    }

    private func sha256(_ input: String) -> String {
        let digest = SHA256.hash(data: Data(input.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func appleSubject(fromIdentityToken identityToken: String) -> String? {
        let segments = identityToken.split(separator: ".")
        guard segments.count >= 2 else { return nil }
        var payload = String(segments[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = payload.count % 4
        if padding > 0 {
            payload += String(repeating: "=", count: 4 - padding)
        }
        guard let data = Data(base64Encoded: payload),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return (object["sub"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct ProviderConnectAPIErrorPayload: Decodable {
    let error: String?
}

private struct ProviderConnectAPIError: LocalizedError {
    let message: String

    var errorDescription: String? { message }

    var isExpiredJWT: Bool {
        let lowered = message.lowercased()
        return lowered.contains("token is expired")
            || lowered.contains("invalid jwt")
            || lowered.contains("unable to parse or verify signature")
    }
}

struct ProviderLoginWebView: UIViewRepresentable {
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

struct ProfileSettingsCard: View {
    let title: String
    let rows: [ProfileSettingRowModel]

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            SleeScriptDisplayText(title, size: 24, color: OunjePalette.primaryText)

            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    Button(action: row.action) {
                        HStack(alignment: .center, spacing: 12) {
                            Image(systemName: row.icon)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(row.isDestructive ? Color(hex: "FF8E8E") : OunjePalette.secondaryText)
                                .frame(width: 22, height: 22)

                            VStack(alignment: .leading, spacing: 3) {
                                Text(row.title)
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(row.isDestructive ? Color(hex: "FF8E8E") : OunjePalette.primaryText)
                                Text(row.value)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(OunjePalette.secondaryText)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .lineLimit(2)
                            }

                            Spacer(minLength: 8)

                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(OunjePalette.secondaryText.opacity(0.45))
                        }
                        .padding(.vertical, 11)
                        .padding(.horizontal, 0)
                    }
                    .buttonStyle(.plain)

                    if index < rows.count - 1 {
                        Divider()
                            .overlay(OunjePalette.stroke.opacity(0.45))
                    }
                }
            }
        }
    }
}

struct ProfileMembershipCard: View {
    @EnvironmentObject private var store: MealPlanningAppStore
    let onTap: () -> Void
    @AppStorage("ounje.selectedPricingTier") private var selectedTierRawValue = "free"

    private var selectedTier: OunjePricingTier {
        store.effectivePricingTier
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            SleeScriptDisplayText("Membership", size: 24, color: OunjePalette.primaryText)

            Button(action: onTap) {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(selectedTier.title)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(OunjePalette.primaryText)
                        Text(selectedTier.subtitle)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(OunjePalette.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 8)

                    VStack(alignment: .trailing, spacing: 3) {
                        if let badgeText = selectedTier.badgeText {
                            Text(badgeText)
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.black)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(selectedTier.accentColor, in: Capsule())
                        }

                        Text("\(selectedTier.priceText)\(selectedTier.cadenceText == "starter" ? "" : " \(selectedTier.cadenceText)")")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(OunjePalette.accent)

                        Text(selectedTier.economicsText)
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(OunjePalette.secondaryText)
                            .multilineTextAlignment(.trailing)
                    }

                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(OunjePalette.secondaryText.opacity(0.45))
                }
                .padding(.vertical, 12)
            }
            .buttonStyle(.plain)
        }
    }
}

struct NotificationInboxSheet: View {
    @EnvironmentObject private var store: MealPlanningAppStore
    @EnvironmentObject private var notificationCenter: AppNotificationCenterManager
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var isRefreshing = false

    private var inboxEvents: [AppNotificationEvent] {
        notificationCenter.inboxEvents.sorted { left, right in
            if left.createdAt != right.createdAt {
                return left.createdAt > right.createdAt
            }
            return left.scheduledFor > right.scheduledFor
        }
    }

    private var unreadCount: Int {
        inboxEvents.reduce(into: 0) { count, event in
            if event.seenAt == nil { count += 1 }
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if inboxEvents.isEmpty {
                        NotificationInboxEmptyState()
                    } else {
                        ForEach(inboxEvents) { event in
                            NotificationInboxRow(event: event) {
                                Task {
                                    await notificationCenter.markInboxEventsSeen([event.id], session: store.authSession)
                                    if let actionURLString = event.actionURLString,
                                       let url = URL(string: actionURLString) {
                                        openURL(url)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, OunjeLayout.screenHorizontalPadding)
                .padding(.top, 10)
                .padding(.bottom, 20)
            }
            .background(OunjePalette.background.ignoresSafeArea())
            .navigationTitle("Inbox")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task {
                            isRefreshing = true
                            await notificationCenter.refreshInbox(for: store.resolvedTrackingSession)
                            isRefreshing = false
                        }
                    } label: {
                        if isRefreshing {
                            ProgressView()
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                }
            }
            .task {
                await notificationCenter.refreshInbox(for: store.resolvedTrackingSession)
            }
            .safeAreaInset(edge: .top) {
                if unreadCount > 0 {
                    HStack {
                        Text("\(unreadCount) unread")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(OunjePalette.secondaryText)
                        Spacer()
                        Button {
                            Task {
                                let unreadIDs = inboxEvents.filter { $0.seenAt == nil }.map(\.id)
                                await notificationCenter.markInboxEventsSeen(unreadIDs, session: store.resolvedTrackingSession)
                            }
                        } label: {
                            Text("Mark all read")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(OunjePalette.accent)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, OunjeLayout.screenHorizontalPadding)
                    .padding(.vertical, 8)
                    .background(OunjePalette.background.opacity(0.96))
                }
            }
        }
    }
}

struct NotificationInboxEmptyState: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image("EnjoyCarrots")
                .resizable()
                .scaledToFit()
                .frame(width: 92, height: 72, alignment: .leading)
                .opacity(0.82)
                .accessibilityHidden(true)

            Text("Your inbox is quiet")
                .biroHeaderFont(20)
                .foregroundStyle(OunjePalette.primaryText)

            Text("Prep confirmations, delivery updates, and nudges will show up here.")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(OunjePalette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 10)
    }
}

struct NotificationInboxRow: View {
    let event: AppNotificationEvent
    let onTap: () -> Void

    private var dateLabel: String {
        event.createdAt.formatted(date: .abbreviated, time: .shortened)
    }

    private var kindLabel: String {
        switch event.kind {
        case "meal_prep_ready": return "Prep"
        case "grocery_cart_ready": return "Shopping"
        case "checkout_approval_required": return "Checkout"
        case "grocery_order_confirmed": return "Order"
        case "grocery_delivery_update", "grocery_delivery_arrived": return "Delivery"
        case "recipe_nudge", "trending_recipe_nudge": return "Discover"
        case "grocery_issue": return "Alert"
        default: return event.kind.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    private var leadingIcon: String {
        switch event.kind {
        case "grocery_cart_ready": return "cart.fill"
        case "grocery_delivery_arrived": return "checkmark.circle.fill"
        case "grocery_issue": return "exclamationmark.triangle.fill"
        case "checkout_approval_required": return "cart.fill.badge.gearshape"
        case "grocery_order_confirmed": return "checkmark.seal.fill"
        case "meal_prep_ready": return "fork.knife.circle.fill"
        case "recipe_nudge", "trending_recipe_nudge": return "sparkles"
        default: return "bell.fill"
        }
    }

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .top, spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(event.seenAt == nil ? OunjePalette.accent.opacity(0.12) : OunjePalette.elevated)
                    Image(systemName: leadingIcon)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(event.seenAt == nil ? OunjePalette.accent : OunjePalette.secondaryText)
                }
                .frame(width: 52, height: 52)

                VStack(alignment: .leading, spacing: 7) {
                    HStack(alignment: .top, spacing: 10) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(kindLabel.uppercased())
                                .font(.system(size: 11, weight: .bold))
                                .tracking(1.1)
                                .foregroundStyle(OunjePalette.secondaryText)
                            Text(event.title)
                                .biroHeaderFont(16)
                                .foregroundStyle(OunjePalette.primaryText)
                                .lineLimit(2)
                        }

                        Spacer(minLength: 10)

                        if event.seenAt == nil {
                            Circle()
                                .fill(OunjePalette.accent)
                                .frame(width: 8, height: 8)
                                .padding(.top, 4)
                        }
                    }

                    Text(event.body)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(OunjePalette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .lineLimit(3)

                    HStack(spacing: 8) {
                        Text(dateLabel)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(OunjePalette.secondaryText.opacity(0.9))
                        if let actionLabel = event.actionLabel, !actionLabel.isEmpty {
                            Text("•")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(OunjePalette.secondaryText.opacity(0.7))
                            Text(actionLabel)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(OunjePalette.accent)
                        }
                    }
                }
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(OunjePalette.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .stroke(event.seenAt == nil ? OunjePalette.accent.opacity(0.18) : OunjePalette.stroke, lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
    }
}

struct ProfileUpgradeCard: View {
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

extension OunjePricingTier {
    var accentColor: Color {
        switch self {
        case .free:
            return OunjePalette.softCream
        case .plus:
            return OunjePalette.accent
        case .autopilot:
            return Color(hex: "5CC8FF")
        case .foundingLifetime:
            return Color(hex: "B57DFF")
        }
    }
}

private let privacyPolicyURL = URL(string: "\(OunjeDevelopmentServer.productionBaseURL)/privacy")!
private let termsOfServiceURL = URL(string: "\(OunjeDevelopmentServer.productionBaseURL)/terms")!
private let supportURL = URL(string: "\(OunjeDevelopmentServer.productionBaseURL)/support")!

struct PaywallFeature: Identifiable {
    let id = UUID()
    let icon: String
    let title: String
    let subtitle: String
}

private let premiumFeatures: [PaywallFeature] = [
    .init(icon: "crown.fill", title: "Cart sync", subtitle: "Prep changes merge into your cart automatically"),
    .init(icon: "crown.fill", title: "Dynamic prep planning", subtitle: "Weekly plans adapt to your budget and preferences"),
    .init(icon: "crown.fill", title: "Zero manual rebuilds", subtitle: "Keep cart + prep aligned without extra passes")
]

struct OunjePlusPaywallSheet: View {
    @Environment(\.dismiss) private var dismiss
    let initialTier: OunjePricingTier?
    let isDismissible: Bool
    let usesDummyTrialFlow: Bool
    let onUpgradeSuccess: (() -> Void)?

    init(
        initialTier: OunjePricingTier?,
        isDismissible: Bool = true,
        usesDummyTrialFlow: Bool = false,
        onUpgradeSuccess: (() -> Void)? = nil
    ) {
        self.initialTier = initialTier
        self.isDismissible = isDismissible
        self.usesDummyTrialFlow = usesDummyTrialFlow
        self.onUpgradeSuccess = onUpgradeSuccess
    }

    var body: some View {
        OunjePaywallHostView(
            initialTier: initialTier,
            isDismissible: isDismissible,
            usesDummyTrialFlow: usesDummyTrialFlow,
            onClose: { dismiss() },
            onUpgradeSuccess: onUpgradeSuccess
        )
    }
}
