import Foundation
import SwiftUI

struct OunjePaywallHostView: View {
    let initialTier: OunjePricingTier?
    let isDismissible: Bool
    let usesDummyTrialFlow: Bool
    let onClose: () -> Void
    let onUpgradeSuccess: (() -> Void)?

    @EnvironmentObject private var store: MealPlanningAppStore
    @Environment(\.openURL) private var openURL
    @State private var selectedTier: OunjePricingTier
    @State private var selectedCadence: OunjeMembershipBillingCadence
    @State private var localErrorMessage: String?
    @State private var purchaseVisualState: PurchaseCTAVisualState = .idle
    @State private var confettiBurstID = 0

    init(
        initialTier: OunjePricingTier?,
        isDismissible: Bool = true,
        usesDummyTrialFlow: Bool = false,
        onClose: @escaping () -> Void,
        onUpgradeSuccess: (() -> Void)? = nil
    ) {
        self.initialTier = initialTier
        self.isDismissible = isDismissible
        self.usesDummyTrialFlow = usesDummyTrialFlow
        self.onClose = onClose
        self.onUpgradeSuccess = onUpgradeSuccess
        _selectedTier = State(initialValue: Self.defaultTier(from: initialTier))
        _selectedCadence = State(initialValue: .monthly)
    }

    var body: some View {
        GeometryReader { proxy in
            let compact = proxy.size.height < 760
            let contentWidth = min(proxy.size.width - 32, 430)
            let headerHeight = max(compact ? 392 : 462, proxy.size.height * (compact ? 0.54 : 0.56))
            let panelOverlap: CGFloat = compact ? 12 : 18
            let panelHeight = max(0, proxy.size.height - headerHeight + panelOverlap + proxy.safeAreaInsets.bottom)
            let contentBottomPadding = max(14, proxy.safeAreaInsets.bottom + 8)
            let backgroundScale: CGFloat = compact ? 1.18 : 1.14

            ZStack(alignment: .topTrailing) {
                Image("OunjePaywallHero")
                    .resizable()
                    .scaledToFill()
                    .frame(
                        width: proxy.size.width * backgroundScale,
                        height: proxy.size.height * backgroundScale,
                        alignment: .topLeading
                    )
                    .offset(
                        x: proxy.size.width * (backgroundScale - 1) * 0.12 - proxy.size.width * 0.02,
                        y: -proxy.size.height * (backgroundScale - 1) * 0.12
                    )
                    .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
                    .clipped()
                    .ignoresSafeArea()

                Color.black
                    .opacity(0.18)
                    .ignoresSafeArea()

                LinearGradient(
                    gradient: Gradient(stops: [
                        .init(color: Color.black.opacity(0.03), location: 0.00),
                        .init(color: Color.black.opacity(0.16), location: 0.34),
                        .init(color: Color.black.opacity(0.46), location: 0.50),
                        .init(color: Color.black.opacity(0.74), location: 0.62),
                        .init(color: Color.black.opacity(0.92), location: 0.74),
                        .init(color: Color.black, location: 0.88),
                        .init(color: Color.black, location: 1.00)
                    ]),
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()

                VStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: compact ? 9 : 12) {
                        Capsule()
                            .fill(OunjePalette.accent)
                            .frame(width: 42, height: 10)

                        Text("3 days free")
                            .font(.custom("Slee_handwritting-Regular", size: compact ? 20 : 26))
                            .foregroundStyle(.white.opacity(0.92))
                            .lineLimit(1)
                            .padding(.top, 2)

                        Text(paywallTitle)
                            .font(.system(size: compact ? 26 : 32, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.white)
                            .lineSpacing(1)
                            .fixedSize(horizontal: false, vertical: true)

                        Text(paywallSubtitle)
                            .font(.system(size: compact ? 12 : 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color.white.opacity(0.62))
                            .lineSpacing(2)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(width: contentWidth, alignment: .leading)
                    .padding(.leading, max(16, (proxy.size.width - contentWidth) / 2))
                    .padding(.bottom, compact ? 54 : 64)
                    .frame(width: proxy.size.width, height: headerHeight, alignment: .bottomLeading)

                    VStack {
                        VStack(spacing: compact ? 8 : 11) {
                            CleanPaywallCadenceCard(
                                title: "Monthly",
                                price: displayPriceValue(for: monthlyPlan),
                                badgeText: nil,
                                isSelected: selectedCadence == .monthly
                            ) {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    selectedCadence = .monthly
                                }
                            }
                            .frame(width: contentWidth * 0.92)

                            CleanPaywallCadenceCard(
                                title: "Annual",
                                price: displayPriceValue(for: yearlyPlan),
                                badgeText: yearlySavingsBadgeText,
                                isSelected: selectedCadence == .yearly
                            ) {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    selectedCadence = .yearly
                                }
                            }
                            .frame(width: contentWidth * 0.92)

                            Text("Try 3 days free. Cancel anytime.")
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                                .foregroundStyle(Color.white.opacity(0.82))
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.top, compact ? 24 : 30)

                            if let error = displayedErrorMessage {
                                Text(error)
                                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                                    .foregroundStyle(Color(hex: "FF8E8E"))
                                    .lineLimit(2)
                                    .minimumScaleFactor(0.8)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }

                            PurchasingCTAButton(
                                title: ctaTitle,
                                state: purchaseVisualState,
                                height: compact ? 44 : 50,
                                isDisabled: store.isBillingBusy || purchaseVisualState == .processing,
                                foregroundColor: .white,
                                fillColor: Color(hex: "1F4D3A"),
                                progressFillColor: Color(hex: "2A634C"),
                                cornerRadius: 18,
                                fontSize: compact ? 12 : 13
                            ) {
                                Task {
                                    if usesDummyTrialFlow {
                                        await startDummyTrial()
                                    } else {
                                        await purchaseSelectedPlan()
                                    }
                                }
                            }
                            .frame(width: contentWidth * 0.88)
                            .padding(.top, 2)

                            HStack(spacing: 14) {
                                Button("Restore") {
                                    Task {
                                        _ = await store.restoreMembershipPurchases()
                                        if store.membershipEntitlement?.isActive == true {
                                            handleUnlockSuccess()
                                        }
                                    }
                                }

                                Button("Terms") { openURL(paywallTermsOfServiceURL) }
                                Button("Privacy") { openURL(paywallPrivacyPolicyURL) }
                            }
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(OunjePalette.secondaryText.opacity(0.82))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .padding(.top, 2)
                        }
                        .frame(width: contentWidth)
                        .padding(.top, compact ? 12 : 18)
                        .padding(.horizontal, 16)
                        .padding(.bottom, contentBottomPadding + (compact ? 14 : 22))
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: panelHeight, alignment: .top)
                    .background(
                        LinearGradient(
                            gradient: Gradient(stops: [
                                .init(color: Color.black.opacity(0.0), location: 0.00),
                                .init(color: Color.black.opacity(0.46), location: 0.12),
                                .init(color: Color.black.opacity(0.82), location: 0.24),
                                .init(color: Color.black, location: 0.38),
                                .init(color: Color.black, location: 1.00)
                            ]),
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .ignoresSafeArea(edges: .bottom)
                    )
                    .offset(y: -panelOverlap)
                }
                .frame(width: proxy.size.width, height: proxy.size.height + panelOverlap, alignment: .top)
                .clipped()

                if isDismissible {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(OunjePalette.primaryText.opacity(0.82))
                            .padding(10)
                            .background(OunjePalette.panel.opacity(0.92))
                            .clipShape(Circle())
                    }
                    .padding(.top, max(16, proxy.safeAreaInsets.top + 8))
                    .padding(.trailing, 22)
                }

                if confettiBurstID > 0 {
                    PaywallConfettiBurst(burstID: confettiBurstID)
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                }
            }
        }
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled(!isDismissible)
        .task {
            await store.refreshMembershipEntitlement(trigger: "paywall-presented")
            if store.membershipEntitlement?.isActive == true {
                handleUnlockSuccess()
            }
        }
        .onChange(of: store.membershipEntitlement?.isActive == true) { isActive in
            if isActive {
                handleUnlockSuccess()
            }
        }
        .onChange(of: selectedCadence) { _ in
            localErrorMessage = nil
            purchaseVisualState = .idle
        }
        .onChange(of: selectedTier) { _ in
            localErrorMessage = nil
            purchaseVisualState = .idle
        }
    }

    private static func defaultTier(from initialTier: OunjePricingTier?) -> OunjePricingTier {
        .plus
    }

    private var selectedPlan: OunjeMembershipPlan {
        .init(tier: selectedTier, cadence: selectedCadence)
    }

    private var monthlyPlan: OunjeMembershipPlan {
        .init(tier: selectedTier, cadence: .monthly)
    }

    private var yearlyPlan: OunjeMembershipPlan {
        .init(tier: selectedTier, cadence: .yearly)
    }

    private var paywallTitle: String {
        "Try Ounje"
    }

    private var paywallSubtitle: String {
        "Unlimited recipe imports and AI recipe edits, personalized prep, and an Instacart agent that finds better groceries for less."
    }

    private var ctaTitle: String {
        if usesDummyTrialFlow && purchaseVisualState == .processing {
            return "Opening Ounje"
        }
        return "Start Free Trial"
    }

    private var displayedErrorMessage: String? {
        let message = localErrorMessage ?? store.billingStatusMessage
        guard let message, !message.isEmpty else { return nil }
        let lowercased = message.lowercased()
        if lowercased.contains("invalid jwt")
            || lowercased.contains("token is expired")
            || lowercased.contains("unable to parse or verify signature")
            || lowercased.contains("membership session is missing") {
            return nil
        }

        if message.hasPrefix("["),
           let closingBracket = message.firstIndex(of: "]"),
           message.index(after: closingBracket) < message.endIndex {
            let start = message.index(after: closingBracket)
            let trimmed = message[start...].trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? message : trimmed
        }

        return message
    }

    private func displayPriceValue(for plan: OunjeMembershipPlan) -> String {
        if let snapshot = store.availableMembershipProducts[plan] {
            return snapshot.displayPrice
        }
        return plan.displayPriceText
    }

    private func introTrialAvailable(for plan: OunjeMembershipPlan) -> Bool {
        guard let snapshot = store.availableMembershipProducts[plan] else {
            return true
        }
        return snapshot.hasIntroductoryOffer && snapshot.isEligibleForIntroOffer
    }

    private var yearlySavingsBadgeText: String? {
        guard let savings = yearlyPlan.savingsText else { return nil }
        let normalized = savings.replacingOccurrences(of: "Save ", with: "")
        return "\(normalized) off"
    }

    @MainActor
    private func startDummyTrial() async {
        guard purchaseVisualState != .processing else { return }
        localErrorMessage = nil
        purchaseVisualState = .processing
        confettiBurstID += 1
        try? await Task.sleep(nanoseconds: 650_000_000)
        purchaseVisualState = .success
        try? await Task.sleep(nanoseconds: 550_000_000)
        handleUnlockSuccess()
    }

    @MainActor
    private func purchaseSelectedPlan() async {
        guard !store.isBillingBusy else { return }
        localErrorMessage = nil
        purchaseVisualState = .processing

        if await store.purchaseMembershipPlan(selectedPlan) {
            purchaseVisualState = .success
            try? await Task.sleep(nanoseconds: 450_000_000)
            handleUnlockSuccess()
        } else {
            purchaseVisualState = .failed
            localErrorMessage = store.billingStatusMessage ?? "Purchase failed."
            try? await Task.sleep(nanoseconds: 450_000_000)
            purchaseVisualState = .idle
        }
    }

    private func handleUnlockSuccess() {
        onUpgradeSuccess?()
        onClose()
    }
}

private let paywallPrivacyPolicyURL = URL(string: "\(OunjeDevelopmentServer.productionBaseURL)/privacy")!
private let paywallTermsOfServiceURL = URL(string: "\(OunjeDevelopmentServer.productionBaseURL)/terms")!

private struct PaywallConfettiBurst: View {
    let burstID: Int
    @State private var isExpanded = false

    private let pieces = Array(0..<34)
    private let colors: [Color] = [
        OunjePalette.accent,
        Color(hex: "F6E7B0"),
        Color(hex: "FFFFFF"),
        Color(hex: "9BE7B0"),
        Color(hex: "F8B36A")
    ]

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                ForEach(pieces, id: \.self) { index in
                    let vector = vector(for: index, in: proxy.size)
                    let color = colors[index % colors.count]

                    ConfettiPiece(color: color, isCapsule: index % 3 == 0)
                        .frame(width: index % 3 == 0 ? 7 : 8, height: index % 3 == 0 ? 14 : 8)
                        .rotationEffect(.degrees(isExpanded ? Double(index * 37 + 160) : Double(index * 11)))
                        .position(x: proxy.size.width * 0.5, y: proxy.size.height * 0.66)
                        .offset(x: isExpanded ? vector.dx : 0, y: isExpanded ? vector.dy : 0)
                        .opacity(isExpanded ? 0 : 1)
                        .animation(
                            .easeOut(duration: 1.05).delay(Double(index % 8) * 0.018),
                            value: isExpanded
                        )
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .onAppear {
                isExpanded = false
                DispatchQueue.main.async {
                    isExpanded = true
                }
            }
            .id(burstID)
        }
    }

    private func vector(for index: Int, in size: CGSize) -> (dx: CGFloat, dy: CGFloat) {
        let angle = (-150.0 + Double(index) * (300.0 / Double(max(1, pieces.count - 1)))) * Double.pi / 180
        let radius = min(size.width, size.height) * CGFloat(0.20 + Double(index % 7) * 0.022)
        let dx = cos(angle) * radius
        let dy = sin(angle) * radius - CGFloat(70 + (index % 5) * 18)
        return (dx, dy)
    }
}

private struct ConfettiPiece: View {
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
        .shadow(color: color.opacity(0.28), radius: 6, y: 3)
    }
}
