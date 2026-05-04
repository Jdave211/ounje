import SwiftUI
import Foundation
import UIKit
import MapKit

struct PrepTabView: View {
    @EnvironmentObject private var store: MealPlanningAppStore
    @EnvironmentObject private var toastCenter: AppToastCenter
    @Binding var selectedTab: AppTab
    @Binding var requestedCookbookCycleID: String?
    let recipeTransitionNamespace: Namespace.ID
    let onSelectRecipe: (PlannedRecipe) -> Void
    @State private var isRegenerationSheetPresented = false
    @State private var selectedRegenerationFocus: PrepRegenerationFocus = .balanced
    @State private var prepLinkPulse = false

    private var currentPrepRecipeCount: Int {
        store.latestPlan?.recipes.count ?? 0
    }

    private var currentRecurringCount: Int {
        store.resolvedRecurringAnchorCount
    }

    private var showsPrepLoadingState: Bool {
        let hasRenderablePlan = store.latestPlan?.recipes.isEmpty == false
        guard !hasRenderablePlan else { return false }
        return store.isRefreshingPrepRecipes
            || store.isGenerating
            || store.isHydratingRemoteState
            || !store.hasResolvedInitialState
    }

    private var showsRegenerationPlaceholders: Bool {
        store.isGenerating && store.latestPlan?.recipes.isEmpty == false
    }

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
                            .disabled(store.isGenerating || !(store.profile?.isPlanningReady ?? false))
                            .opacity((store.isGenerating || !(store.profile?.isPlanningReady ?? false)) ? 0.65 : 1)
                        }

                        MealsPrepCarousel(
                            plannedRecipes: store.latestPlan?.recipes ?? [],
                            showsLoadingState: showsPrepLoadingState,
                            showsRegenerationPlaceholders: showsRegenerationPlaceholders,
                            recurringRecipeIDs: store.activeRecurringPrepRecipeIDs,
                            recipeTransitionNamespace: recipeTransitionNamespace,
                            onSelectRecipe: onSelectRecipe
                        )
                        .id("\(store.latestPlan?.id.uuidString ?? "empty")::\(store.latestPlanRevision)::\(showsRegenerationPlaceholders)")
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
                recipeCount: currentPrepRecipeCount,
                recurringCount: currentRecurringCount,
                isGenerating: store.isGenerating,
                onCancel: {
                    isRegenerationSheetPresented = false
                },
                onConfirm: { options in
                    isRegenerationSheetPresented = false
                    toastCenter.show(
                        title: "Generating prep",
                        subtitle: "Fresh meals are on the way.",
                        systemImage: "wand.and.stars"
                    )
                    Task {
                        let succeeded = await store.regeneratePrepBatch(using: options)
                        await MainActor.run {
                            if succeeded {
                                showPrepGenerationCompleteToast()
                            } else {
                                toastCenter.show(
                                    title: "Prep did not change",
                                    subtitle: "Try a stronger prompt or check your connection.",
                                    systemImage: "exclamationmark.triangle.fill"
                                )
                            }
                        }
                    }
                }
            )
            .presentationDetents([.height(500)])
            .presentationDragIndicator(.visible)
        }
    }

    private func recipeForSlot(_ index: Int) -> Recipe? {
        guard let recipes = store.latestPlan?.recipes.map(\.recipe), !recipes.isEmpty else { return nil }
        return recipes[index % recipes.count]
    }

    private func showPrepGenerationCompleteToast() {
        let recipeCard = store.latestPlan?.recipes
            .map(DiscoverRecipeCardData.init(preppedRecipe:))
            .randomElement()
        toastCenter.show(
            title: "Gen complete",
            subtitle: recipeCard?.title ?? "Fresh prep is ready.",
            systemImage: "checkmark.circle.fill",
            thumbnailURLString: recipeCard?.imageURLString ?? recipeCard?.heroImageURLString,
            destination: recipeCard.map(AppToastDestination.recipe)
        )
    }
}

struct PrepRegenerationSheet: View {
    @Binding var selectedFocus: PrepRegenerationFocus
    let recipeCount: Int
    let recurringCount: Int
    let isGenerating: Bool
    let onCancel: () -> Void
    let onConfirm: (PrepGenerationOptions) -> Void
    @State private var targetRecipeCount: Int

    init(
        selectedFocus: Binding<PrepRegenerationFocus>,
        recipeCount: Int,
        recurringCount: Int,
        isGenerating: Bool,
        onCancel: @escaping () -> Void,
        onConfirm: @escaping (PrepGenerationOptions) -> Void
    ) {
        _selectedFocus = selectedFocus
        self.recipeCount = recipeCount
        self.recurringCount = recurringCount
        self.isGenerating = isGenerating
        self.onCancel = onCancel
        self.onConfirm = onConfirm
        let minimumRecipeCount = max(recurringCount, 1)
        let maximumRecipeCount = max(10, minimumRecipeCount)
        _targetRecipeCount = State(initialValue: min(max(recipeCount, minimumRecipeCount), maximumRecipeCount))
    }

    private var recurringCountText: String {
        recurringCount == 1 ? "1 recurring locked" : "\(recurringCount) recurring locked"
    }

    private var targetRecipeCountText: String {
        targetRecipeCount == 1 ? "1 meal" : "\(targetRecipeCount) meals"
    }

    private var minimumRecipeCount: Int {
        max(recurringCount, 1)
    }

    private var maximumRecipeCount: Int {
        max(10, minimumRecipeCount)
    }

    var body: some View {
        ZStack {
            OunjePalette.background.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    SleeScriptDisplayText("Generate new prep?", size: 24, color: OunjePalette.primaryText)
                    Text("\(targetRecipeCountText) • \(recurringCountText)")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(OunjePalette.secondaryText)
                }

                PrepRecipeCountControl(
                    value: $targetRecipeCount,
                    minimumValue: minimumRecipeCount,
                    maximumValue: maximumRecipeCount
                )

                VStack(spacing: 0) {
                    ForEach(Array(PrepRegenerationFocus.allCases.enumerated()), id: \.element.id) { index, focus in
                        Button {
                            selectedFocus = focus
                        } label: {
                            HStack(spacing: 14) {
                                Image(systemName: focus.systemImageName)
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(selectedFocus == focus ? OunjePalette.accent.opacity(0.96) : OunjePalette.secondaryText.opacity(0.92))
                                    .frame(width: 18)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(focus.title)
                                        .font(.system(size: 14, weight: .bold))
                                        .foregroundStyle(selectedFocus == focus ? OunjePalette.primaryText : OunjePalette.primaryText.opacity(0.92))

                                    Text(focus.subtitle)
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(OunjePalette.secondaryText)
                                        .multilineTextAlignment(.leading)
                                        .lineLimit(2)
                                        .fixedSize(horizontal: false, vertical: true)
                                }

                                Spacer(minLength: 0)

                                Image(systemName: selectedFocus == focus ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 18, weight: .semibold))
                                    .foregroundStyle(selectedFocus == focus ? OunjePalette.accent.opacity(0.96) : OunjePalette.secondaryText.opacity(0.72))
                            }
                            .padding(.vertical, 10)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        if index < PrepRegenerationFocus.allCases.count - 1 {
                            Rectangle()
                                .fill(OunjePalette.stroke.opacity(0.55))
                                .frame(height: 1)
                                .padding(.vertical, 2)
                        }
                    }
                }

                Spacer(minLength: 0)

                HStack(spacing: 12) {
                    Button(action: onCancel) {
                        Text("Keep current")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(OunjePalette.primaryText)
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                            .background(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .fill(OunjePalette.surface.opacity(0.94))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .stroke(OunjePalette.stroke.opacity(0.84), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(isGenerating)
                    .opacity(isGenerating ? 0.72 : 1)

                    Button {
                        onConfirm(
                            PrepGenerationOptions(
                                focus: selectedFocus,
                                targetRecipeCount: targetRecipeCount
                            )
                        )
                    } label: {
                        Text(isGenerating ? "Generating..." : "Generate prep")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(OunjePalette.primaryText)
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                            .background(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
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
            .padding(.top, 12)
            .padding(.bottom, 10)
        }
    }
}

struct PrepRecipeCountControl: View {
    @Binding var value: Int
    let minimumValue: Int
    let maximumValue: Int

    var body: some View {
        HStack(spacing: 12) {
            Text("Meals")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(OunjePalette.secondaryText)

            Spacer(minLength: 0)

            Button {
                value = max(minimumValue, value - 1)
            } label: {
                Image(systemName: "minus")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(OunjePalette.primaryText)
                    .frame(width: 32, height: 32)
                    .background(
                        Circle()
                            .fill(OunjePalette.surface.opacity(0.96))
                    )
                    .overlay(
                        Circle()
                            .stroke(OunjePalette.stroke.opacity(0.82), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .disabled(value <= minimumValue)
            .opacity(value <= minimumValue ? 0.42 : 1)

            Text("\(value)")
                .sleeDisplayFont(18)
                .foregroundStyle(OunjePalette.primaryText)
                .frame(minWidth: 22)

            Button {
                value = min(maximumValue, value + 1)
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(OunjePalette.primaryText)
                    .frame(width: 32, height: 32)
                    .background(
                        Circle()
                            .fill(OunjePalette.surface.opacity(0.96))
                    )
                    .overlay(
                        Circle()
                            .stroke(OunjePalette.stroke.opacity(0.82), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .disabled(value >= maximumValue)
            .opacity(value >= maximumValue ? 0.42 : 1)
        }
        .padding(.horizontal, 12)
    }
}

extension PrepRegenerationFocus {
    var title: String {
        switch self {
        case .balanced:
            return "More satisfying"
        case .closerToFavorites:
            return "My taste"
        case .moreVariety:
            return "More imaginative"
        case .lessPrepTime:
            return "Less prep time"
        case .tighterOverlap:
            return "Tighter grocery overlap"
        case .savedRecipeRefresh:
            return "My taste"
        }
    }

    var subtitle: String {
        switch self {
        case .balanced:
            return "Heartier picks that keep you full for longer."
        case .closerToFavorites:
            return "Lean harder into your cuisines, favorites, and saved meals."
        case .moreVariety:
            return "Explore meals you likely would not have picked yourself."
        case .lessPrepTime:
            return "Quicker recipes with a lighter lift."
        case .tighterOverlap:
            return "Reuse more ingredients to keep the cart tighter."
        case .savedRecipeRefresh:
            return "Lean harder into your cuisines, favorites, and saved meals."
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
            return "heart.text.square"
        }
    }

    var promptSeed: String {
        switch self {
        case .balanced:
            return "more satisfying, keep the prep filling, and stay grounded in my saved meals"
        case .closerToFavorites:
            return "more like my taste, lean into my cuisines, favorite foods, and saved meals"
        case .moreVariety:
            return "more imaginative, explore meals I would not normally pick"
        case .lessPrepTime:
            return "less prep time, keep the meals simpler and faster to make"
        case .tighterOverlap:
            return "tighter grocery overlap, reuse more ingredients across the prep"
        case .savedRecipeRefresh:
            return "more like my taste, lean into my cuisines, favorite foods, and saved meals"
        }
    }
}

struct MealsPrepCarousel: View {
    let plannedRecipes: [PlannedRecipe]
    let showsLoadingState: Bool
    let showsRegenerationPlaceholders: Bool
    let recurringRecipeIDs: Set<String>
    let recipeTransitionNamespace: Namespace.ID
    let onSelectRecipe: (PlannedRecipe) -> Void
    @State private var revealedRecipeIDs: Set<String> = []

    var body: some View {
        content
            .onAppear {
                revealPlannedRecipes(immediately: true)
            }
            .onChange(of: plannedRecipeRevealKey) { _ in
                revealPlannedRecipes(immediately: false)
            }
            .onChange(of: showsLoadingState) { isLoading in
                guard !isLoading else { return }
                revealPlannedRecipes(immediately: revealedRecipeIDs.isEmpty)
            }
    }

    @ViewBuilder
    private var content: some View {
        if showsLoadingState {
            MealsPrepLoadingCarousel()
        } else if showsRegenerationPlaceholders {
            MealsPrepRegeneratingCarousel(
                plannedRecipes: plannedRecipes,
                recurringRecipeIDs: recurringRecipeIDs,
                recipeTransitionNamespace: recipeTransitionNamespace
            )
        } else if plannedRecipes.isEmpty {
            PrepShareImportEmptyState()
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(Array(plannedRecipes.enumerated()), id: \.element.id) { index, plannedRecipe in
                        MealDeckCard(
                            plannedRecipe: plannedRecipe,
                            recipeTransitionNamespace: recipeTransitionNamespace,
                            onSelect: { onSelectRecipe(plannedRecipe) }
                        )
                            .frame(width: 232)
                            .modifier(
                                StaggeredRevealModifier(
                                    isVisible: revealedRecipeIDs.contains(plannedRecipe.id),
                                    delay: Double(index) * 0.055,
                                    xOffset: 18,
                                    yOffset: 8
                                )
                            )
                    }
                }
                .padding(.horizontal, OunjeLayout.screenHorizontalPadding)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var plannedRecipeRevealKey: String {
        plannedRecipes.map(\.id).joined(separator: "|")
    }

    private func revealPlannedRecipes(immediately: Bool) {
        guard !showsLoadingState, !showsRegenerationPlaceholders else { return }
        let ids = plannedRecipes.map(\.id)
        guard !ids.isEmpty else {
            revealedRecipeIDs = []
            return
        }

        if immediately {
            revealedRecipeIDs = Set(ids)
            return
        }

        revealedRecipeIDs = revealedRecipeIDs.intersection(Set(ids))
        let missingIDs = ids.filter { !revealedRecipeIDs.contains($0) }

        for (index, id) in missingIDs.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * 0.055) {
                withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) {
                    _ = revealedRecipeIDs.insert(id)
                }
            }
        }
    }
}

struct MealsPrepLoadingCarousel: View {
    @State private var shimmerOffset: CGFloat = -1.2
    @State private var pulse = false

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 14) {
                ForEach(0..<4, id: \.self) { index in
                    MealPrepLoadingCard(
                        index: index,
                        shimmerOffset: shimmerOffset,
                        pulse: pulse
                    )
                }
            }
            .padding(.horizontal, OunjeLayout.screenHorizontalPadding)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .redacted(reason: .placeholder)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.08).repeatForever(autoreverses: true)) {
                pulse.toggle()
            }
            withAnimation(.linear(duration: 1.3).repeatForever(autoreverses: false)) {
                shimmerOffset = 1.4
            }
        }
    }
}

struct MealsPrepRegeneratingCarousel: View {
    let plannedRecipes: [PlannedRecipe]
    let recurringRecipeIDs: Set<String>
    let recipeTransitionNamespace: Namespace.ID
    @State private var shimmerOffset: CGFloat = -1.2
    @State private var pulse = false

    private var recurringRecipes: [PlannedRecipe] {
        plannedRecipes.filter { recurringRecipeIDs.contains($0.recipe.id) }
    }

    private var loadingSlotCount: Int {
        max(1, plannedRecipes.count - recurringRecipes.count)
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 14) {
                ForEach(Array(recurringRecipes.enumerated()), id: \.element.id) { index, plannedRecipe in
                    MealDeckCard(
                        plannedRecipe: plannedRecipe,
                        recipeTransitionNamespace: recipeTransitionNamespace,
                        onSelect: {}
                    )
                    .frame(width: 232)
                    .rotationEffect(.degrees(pulse ? (index.isMultiple(of: 2) ? 1.4 : -1.4) : (index.isMultiple(of: 2) ? -0.9 : 0.9)))
                    .scaleEffect(pulse ? 1.01 : 0.99)
                    .allowsHitTesting(false)
                    .overlay(alignment: .topLeading) {
                        HStack(spacing: 5) {
                            Image(systemName: "repeat")
                                .font(.system(size: 10, weight: .bold))
                            Text("Locked")
                                .font(.system(size: 10, weight: .bold))
                        }
                        .foregroundStyle(OunjePalette.softCream)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(
                            Capsule(style: .continuous)
                                .fill(Color.black.opacity(0.46))
                                .background(.ultraThinMaterial, in: Capsule(style: .continuous))
                        )
                        .padding(12)
                    }
                }

                ForEach(0..<loadingSlotCount, id: \.self) { index in
                    MealPrepLoadingCard(
                        index: index,
                        shimmerOffset: shimmerOffset,
                        pulse: pulse
                    )
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
                }
            }
            .padding(.horizontal, OunjeLayout.screenHorizontalPadding)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.05).repeatForever(autoreverses: true)) {
                pulse.toggle()
            }
            withAnimation(.linear(duration: 1.3).repeatForever(autoreverses: false)) {
                shimmerOffset = 1.4
            }
        }
    }
}

struct MealPrepLoadingCard: View {
    let index: Int
    let shimmerOffset: CGFloat
    let pulse: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            MealPrepLoadingArtworkBlock(shimmerOffset: shimmerOffset)
                .scaleEffect(pulse ? 1.012 : 0.988)

            VStack(alignment: .leading, spacing: 8) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(OunjePalette.surface.opacity(0.82))
                    .frame(width: index.isMultiple(of: 2) ? 176 : 152, height: 22)
                    .modifier(LoadingSheen(offset: shimmerOffset))

                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(OunjePalette.surface.opacity(0.82))
                    .frame(width: 104, height: 14)
                    .modifier(LoadingSheen(offset: shimmerOffset))
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
        .shadow(color: .black.opacity(pulse ? 0.16 : 0.1), radius: pulse ? 16 : 10, x: 0, y: pulse ? 10 : 6)
    }
}

struct PrepShareImportEmptyState: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(OunjePalette.accent)
                    .frame(width: 28, height: 28)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Share from TikTok")
                        .sleeDisplayFont(24)
                        .foregroundStyle(OunjePalette.primaryText)

                    Text("Send a recipe to Ounje and it can land here for your next prep.")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(OunjePalette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(spacing: 8) {
                Image(systemName: "play.rectangle.fill")
                Text("TikTok or Instagram share sheet")
            }
            .font(.system(size: 11, weight: .bold, design: .rounded))
            .foregroundStyle(OunjePalette.softCream.opacity(0.74))
            .padding(.leading, 40)
        }
        .padding(.horizontal, OunjeLayout.screenHorizontalPadding)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct PrepEmptyState: View {
    let title: String
    let detail: String
    let symbolName: String

    var body: some View {
        VStack(spacing: 16) {
            Image("EnjoyCarrots")
                .resizable()
                .scaledToFit()
                .frame(height: 118)
                .opacity(0.92)
                .padding(.top, 14)
                .accessibilityHidden(true)

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

struct MealDeckCard: View {
    let plannedRecipe: PlannedRecipe
    let recipeTransitionNamespace: Namespace.ID
    let onSelect: () -> Void
    @EnvironmentObject private var store: MealPlanningAppStore
    @EnvironmentObject private var toastCenter: AppToastCenter

    private var recurringAction: DiscoverRemoteRecipeCardTopAction? {
        let recipe = plannedRecipe.recipe
        let isRecurring = store.isRecurringPrepRecipe(recipeID: recipe.id)
        let recipeTitle = recipe.title
        return DiscoverRemoteRecipeCardTopAction(
            systemName: isRecurring ? "repeat.circle.fill" : "repeat.circle",
            accessibilityLabel: isRecurring ? "Remove from recurring prep" : "Make recurring for prep",
            showsBackground: false,
            action: {
                Task {
                    let succeeded = await store.toggleRecurringPrepRecipe(recipe)
                    await MainActor.run {
                        toastCenter.show(
                            title: succeeded
                                ? (isRecurring ? "Removed from recurring" : "Added to recurring")
                                : "Couldn’t update recurring",
                            subtitle: succeeded ? recipeTitle : "Check your connection and try again.",
                            systemImage: succeeded
                                ? (isRecurring ? "repeat.circle" : "repeat.circle.fill")
                                : "exclamationmark.triangle.fill"
                        )
                    }
                }
            }
        )
    }

    var body: some View {
        DiscoverRemoteRecipeCard(
            recipe: DiscoverRecipeCardData(preppedRecipe: plannedRecipe),
            showsSaveAction: false,
            secondaryTopAction: recurringAction,
            transitionNamespace: recipeTransitionNamespace,
            showsImageLoadingSkeleton: true,
            onSelect: onSelect
        )
    }
}

struct CookbookPreppedCycle: Identifiable, Hashable {
    let id: String
    let title: String
    let detail: String
    var prepDateLabel: String? = nil
    var prepDateRangeLabel: String? = nil
    let recipes: [DiscoverRecipeCardData]
}

struct CookbookCycleGroup: View {
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

struct CookbookCycleRow: View {
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

                CookbookCycleTablePreview(
                    recipes: Array(cycle.recipes.prefix(6)),
                    dateLabel: cycle.prepDateLabel,
                    showsArrow: !showsMetadata
                )
            }
        }
        .buttonStyle(.plain)
    }
}

struct CookbookEditableRecipeCard: View {
    let recipe: DiscoverRecipeCardData
    let isEditing: Bool
    let isRecurring: Bool
    let transitionNamespace: Namespace.ID?
    let onRemove: () -> Void
    let onToggleRecurring: () -> Void
    let onSelect: () -> Void

    var body: some View {
        let card = DiscoverRemoteRecipeCard(
            recipe: recipe,
            transitionNamespace: transitionNamespace,
            isInteractive: !isEditing,
            showsTopActions: !isEditing,
            onSelect: onSelect
        )

        Group {
            if isEditing {
                card
                    .contentShape(Rectangle())
                    .overlay(alignment: .topTrailing) {
                        HStack(spacing: 8) {
                            Button(action: onToggleRecurring) {
                                Image(systemName: isRecurring ? "repeat.circle.fill" : "repeat.circle")
                                    .font(.system(size: 16, weight: .bold))
                                    .foregroundStyle(OunjePalette.primaryText)
                                    .frame(width: 28, height: 28)
                                    .background(
                                        Circle()
                                            .fill(OunjePalette.surface.opacity(0.95))
                                            .overlay(
                                                Circle()
                                                    .stroke(OunjePalette.stroke, lineWidth: 1)
                                            )
                                    )
                            }
                            .buttonStyle(.plain)

                            Button(action: onRemove) {
                                Image(systemName: "xmark")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundStyle(OunjePalette.primaryText)
                                    .frame(width: 28, height: 28)
                                    .background(
                                        Circle()
                                            .fill(OunjePalette.surface.opacity(0.95))
                                            .overlay(
                                                Circle()
                                                    .stroke(OunjePalette.stroke, lineWidth: 1)
                                            )
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(10)
                    }
            } else {
                card
            }
        }
    }
}

struct CookbookCyclePlateImage: View {
    let recipe: DiscoverRecipeCardData
    var size: CGFloat = 90
    @StateObject private var loader = DiscoverRecipeImageLoader()

    var body: some View {
        ZStack {
            if let uiImage = loader.image {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(Circle())
                    .overlay(
                        Circle()
                            .stroke(.white.opacity(0.08), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.24), radius: 9, y: 6)
            } else if loader.isLoading {
                ProgressView()
                    .tint(OunjePalette.accent)
                    .frame(width: size, height: size)
            } else {
                Text(recipe.emoji)
                    .font(.system(size: max(28, size * 0.42)))
                    .frame(width: size, height: size)
                    .clipShape(Circle())
            }
        }
        .frame(width: size, height: size)
        .task(id: recipe.imageCandidates.map(\.absoluteString).joined(separator: "|")) {
            await loader.load(from: recipe.imageCandidates)
        }
    }
}

struct CookbookCycleTablePreview: View {
    let recipes: [DiscoverRecipeCardData]
    var dateLabel: String? = nil
    let showsArrow: Bool

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = proxy.size.height
            let basePlateSize = min(max(width * 0.23, 72), 100)
            let activePlacements = placements(for: recipes.count)

            ZStack(alignment: .topTrailing) {
                Image("OunjeTable")
                    .resizable()
                    .scaledToFill()
                    .frame(width: width * 1.22, height: height * 1.36)
                    .offset(y: -height * 0.16)
                    .brightness(-0.24)
                    .saturation(0.86)
                    .overlay(Color.black.opacity(0.30))
                    .clipped()

                ForEach(Array(recipes.prefix(activePlacements.count).enumerated()), id: \.element.id) { index, recipe in
                    let placement = activePlacements[index]
                    let size = basePlateSize * placement.scale

                    CookbookCyclePlateImage(recipe: recipe, size: size)
                        .position(x: width * placement.x, y: height * placement.y)
                        .accessibilityLabel(recipe.displayTitle)
                }

                if let dateLabel, !dateLabel.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "calendar")
                            .font(.system(size: 10, weight: .bold))
                        Text(dateLabel)
                            .font(.system(size: 11, weight: .bold))
                    }
                    .foregroundStyle(Color.white.opacity(0.94))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color.black.opacity(0.42))
                            .background(.ultraThinMaterial, in: Capsule(style: .continuous))
                    )
                    .fixedSize()
                    .position(x: 56, y: height - 24)
                }

                if showsArrow {
                    Image(systemName: "arrow.right")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Color.white.opacity(0.92))
                        .frame(width: 34, height: 34)
                        .background(
                            Circle()
                                .fill(Color.black.opacity(0.34))
                                .background(.ultraThinMaterial, in: Circle())
                        )
                        .padding(12)
                }
            }
            .frame(width: width, height: height)
            .clipped()
        }
        .frame(height: 168)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private func placements(for count: Int) -> [(x: CGFloat, y: CGFloat, scale: CGFloat)] {
        switch count {
        case 0:
            return []
        case 1:
            return [(0.50, 0.52, 1.34)]
        case 2:
            return [
                (0.36, 0.52, 1.16),
                (0.64, 0.52, 1.16)
            ]
        case 3:
            return [
                (0.22, 0.54, 1.04),
                (0.50, 0.50, 1.10),
                (0.78, 0.54, 1.04)
            ]
        case 4:
            return [
                (0.22, 0.46, 0.98),
                (0.50, 0.43, 1.06),
                (0.78, 0.47, 0.98),
                (0.50, 0.74, 0.92)
            ]
        default:
            return [
                (0.20, 0.48, 0.96),
                (0.50, 0.43, 1.04),
                (0.80, 0.49, 0.96),
                (0.30, 0.74, 0.88),
                (0.62, 0.75, 0.90),
                (0.88, 0.65, 0.84)
            ]
        }
    }
}

struct DarkBlurView: UIViewRepresentable {
    let style: UIBlurEffect.Style

    func makeUIView(context: Context) -> UIVisualEffectView {
        UIVisualEffectView(effect: UIBlurEffect(style: style))
    }

    func updateUIView(_ uiView: UIVisualEffectView, context: Context) {
        uiView.effect = UIBlurEffect(style: style)
    }
}

struct CookbookCyclePage: View {
    let cycle: CookbookPreppedCycle
    @Binding var selectedTab: AppTab
    let toastCenter: AppToastCenter

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: MealPlanningAppStore
    @EnvironmentObject private var savedStore: SavedRecipesStore

    @Namespace private var recipeTransitionNamespace
    @State private var presentedRecipe: PresentedRecipeDetail?
    @State private var isRegenerationSheetPresented = false
    @State private var selectedRegenerationFocus: PrepRegenerationFocus = .balanced
    @State private var regenerationPromptText: String = ""
    @State private var isEditingPrep = false
    @State private var selectedRecipePage = 0
    @State private var tracksLatestPrepCycle = false

    private let columns = [
        GridItem(.flexible(), spacing: 14, alignment: .top),
        GridItem(.flexible(), spacing: 14, alignment: .top)
    ]
    private let cardsPerPage = 4
    private let recipeCardHeight: CGFloat = 292
    private let recipeGridSpacing: CGFloat = 14

    private var isCurrentPrepCycle: Bool {
        tracksLatestPrepCycle || store.latestPlan?.id.uuidString == cycle.id
    }

    private var displayedRecipes: [DiscoverRecipeCardData] {
        if isCurrentPrepCycle {
            return store.latestPlan?.recipes.map(DiscoverRecipeCardData.init(preppedRecipe:)) ?? []
        }
        return cycle.recipes
    }

    private var recipesForDisplay: [DiscoverRecipeCardData] {
        displayedRecipes
    }

    private var canEditCurrentCycle: Bool {
        isCurrentPrepCycle && displayedRecipes.count > 1
    }

    private var currentRecurringCount: Int {
        store.resolvedRecurringAnchorCount
    }

    private var recipePages: [[DiscoverRecipeCardData]] {
        recipesForDisplay.chunked(into: cardsPerPage)
    }

    private var currentRecipePageRecipes: [DiscoverRecipeCardData] {
        guard recipePages.indices.contains(selectedRecipePage) else {
            return recipePages.first ?? []
        }
        return recipePages[selectedRecipePage]
    }

    private var showsRecipePagingControls: Bool {
        recipePages.count > 1
    }

    private var recipePagerHeight: CGFloat {
        let recipeCount = max(currentRecipePageRecipes.count, 1)
        let rowCount = Int(ceil(Double(recipeCount) / 2.0))
        return CGFloat(rowCount) * recipeCardHeight + CGFloat(max(0, rowCount - 1)) * recipeGridSpacing + 4
    }

    private var currentPageLabel: String {
        guard !recipesForDisplay.isEmpty else { return "No recipes" }
        let startIndex = selectedRecipePage * cardsPerPage + 1
        let endIndex = min(startIndex + cardsPerPage - 1, recipesForDisplay.count)
        return "Recipes \(startIndex)-\(endIndex) of \(recipesForDisplay.count)"
    }

    var body: some View {
        NavigationStack {
            ZStack {
                OunjePalette.background
                    .ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(cycle.title)
                                    .biroHeaderFont(30)
                                    .foregroundStyle(OunjePalette.primaryText)

                                Text("Prep \(cycle.prepDateRangeLabel ?? cycle.detail)")
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundStyle(OunjePalette.primaryText.opacity(0.86))

                                Text(isEditingPrep && isCurrentPrepCycle ? "Tap x to remove a recipe from this prep." : "\(recipesForDisplay.count) recipes in this cycle")
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundStyle(OunjePalette.secondaryText)
                                    .fixedSize(horizontal: false, vertical: true)
                            }

                            Spacer(minLength: 8)

                            if canEditCurrentCycle {
                                Button {
                                    togglePrepEditing()
                                } label: {
                                    Text(isEditingPrep ? "Done" : "Edit")
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundStyle(OunjePalette.primaryText)
                                }
                                .buttonStyle(.plain)
                            }
                        }

                        if recipesForDisplay.isEmpty {
                            RecipesEmptyState(
                                title: "No meals left in this prep",
                                detail: "Add a few back into next prep and they’ll show up here again.",
                                symbolName: "fork.knife.circle"
                            )
                        } else {
                            recipePagingSection
                        }
                    }
                    .padding(.horizontal, OunjeLayout.screenHorizontalPadding)
                    .padding(.top, 12)
                    .padding(.bottom, 24)
                }
                .allowsHitTesting(presentedRecipe == nil)

                if let presentedRecipe {
                    RecipeDetailExperienceView(
                        presentedRecipe: presentedRecipe,
                        onOpenCart: {
                            withAnimation(OunjeMotion.heroSpring) {
                                selectedTab = .cart
                                self.presentedRecipe = nil
                            }
                        },
                        toastCenter: toastCenter,
                        onDismiss: dismissPresentedRecipe,
                        transitionNamespace: recipeTransitionNamespace
                    )
                    .environmentObject(savedStore)
                    .background(OunjePalette.background.ignoresSafeArea())
                    .preferredColorScheme(.dark)
                    .transition(.opacity)
                    .zIndex(6)
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
                        if isEditingPrep {
                            Button {
                                togglePrepEditing()
                            } label: {
                                Text("Done")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(OunjePalette.primaryText)
                            }
                            .buttonStyle(.plain)
                        } else {
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
                            .disabled(store.isGenerating || !(store.profile?.isPlanningReady ?? false))
                            .opacity((store.isGenerating || !(store.profile?.isPlanningReady ?? false)) ? 0.65 : 1)
                        }
                    }
                }
            }
            .onAppear {
                if store.latestPlan?.id.uuidString == cycle.id {
                    tracksLatestPrepCycle = true
                }
                if isCurrentPrepCycle {
                    isEditingPrep = false
                }
                clampSelectedRecipePage()
            }
            .onChange(of: cycle.id) { _ in
                isEditingPrep = false
                selectedRecipePage = 0
            }
            .onChange(of: store.latestPlan?.id) { _ in
                clampSelectedRecipePage()
            }
            .onChange(of: store.latestPlan?.recipes.map(\.recipe.id).joined(separator: "|") ?? "") { _ in
                clampSelectedRecipePage()
            }
        }
        .sheet(isPresented: $isRegenerationSheetPresented) {
            CookbookCyclePromptSheet(
                cycleTitle: cycle.title,
                recipeCount: recipesForDisplay.count,
                recurringCount: currentRecurringCount,
                selectedFocus: $selectedRegenerationFocus,
                promptText: $regenerationPromptText,
                isGenerating: store.isGenerating,
                onCancel: {
                    isRegenerationSheetPresented = false
                },
                onConfirm: { options in
                    isRegenerationSheetPresented = false
                    toastCenter.show(
                        title: "Generating prep",
                        subtitle: "Fresh meals are on the way.",
                        systemImage: "wand.and.stars"
                    )
                    Task {
                        let succeeded = await store.regeneratePrepBatch(using: options)
                        await MainActor.run {
                            if succeeded {
                                regenerationPromptText = ""
                                showPrepGenerationCompleteToast()
                            } else {
                                toastCenter.show(
                                    title: "Prep did not change",
                                    subtitle: "Try a stronger prompt or check your connection.",
                                    systemImage: "exclamationmark.triangle.fill"
                                )
                            }
                        }
                    }
                }
            )
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
    }

    @ViewBuilder
    private var recipePagingSection: some View {
        if showsRecipePagingControls {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(currentPageLabel)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(OunjePalette.primaryText)
                        Text("Swipe through this cycle or jump using the arrows.")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(OunjePalette.secondaryText)
                    }

                    Spacer(minLength: 0)

                    HStack(spacing: 10) {
                        Button {
                            shiftRecipePage(by: -1)
                        } label: {
                            Image(systemName: "arrow.left")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(OunjePalette.primaryText)
                                .frame(width: 36, height: 36)
                                .background(
                                    Circle()
                                        .fill(OunjePalette.surface.opacity(0.94))
                                        .overlay(
                                            Circle()
                                                .stroke(OunjePalette.stroke, lineWidth: 1)
                                        )
                                )
                        }
                        .buttonStyle(.plain)
                        .disabled(selectedRecipePage == 0)
                        .opacity(selectedRecipePage == 0 ? 0.45 : 1)

                        Button {
                            shiftRecipePage(by: 1)
                        } label: {
                            Image(systemName: "arrow.right")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(OunjePalette.primaryText)
                                .frame(width: 36, height: 36)
                                .background(
                                    Circle()
                                        .fill(OunjePalette.surface.opacity(0.94))
                                        .overlay(
                                            Circle()
                                                .stroke(OunjePalette.stroke, lineWidth: 1)
                                        )
                                )
                        }
                        .buttonStyle(.plain)
                        .disabled(selectedRecipePage >= recipePages.count - 1)
                        .opacity(selectedRecipePage >= recipePages.count - 1 ? 0.45 : 1)
                    }
                }

                HStack(spacing: 8) {
                    ForEach(recipePages.indices, id: \.self) { index in
                        Capsule(style: .continuous)
                            .fill(index == selectedRecipePage ? OunjePalette.accent : OunjePalette.stroke.opacity(0.45))
                            .frame(width: index == selectedRecipePage ? 28 : 10, height: 6)
                            .animation(OunjeMotion.quickSpring, value: selectedRecipePage)
                    }
                }

                TabView(selection: $selectedRecipePage) {
                    ForEach(Array(recipePages.enumerated()), id: \.offset) { index, pageRecipes in
                        recipeGridPage(pageRecipes)
                            .tag(index)
                            .padding(.top, 2)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .frame(height: recipePagerHeight)
                .animation(OunjeMotion.screenSpring, value: selectedRecipePage)
                .animation(OunjeMotion.screenSpring, value: recipePagerHeight)
            }
        } else {
            recipeGridPage(currentRecipePageRecipes)
        }
    }

    private func recipeGridPage(_ recipes: [DiscoverRecipeCardData]) -> some View {
        LazyVGrid(columns: columns, spacing: recipeGridSpacing) {
            ForEach(recipes) { recipe in
                CookbookEditableRecipeCard(
                    recipe: recipe,
                    isEditing: isEditingPrep && canEditCurrentCycle,
                    isRecurring: store.isRecurringPrepRecipe(recipeID: recipe.id),
                    transitionNamespace: recipeTransitionNamespace,
                    onRemove: {
                        guard isEditingPrep, isCurrentPrepCycle else { return }
                        let removedPlannedRecipe = store.latestPlan?.recipes.first { $0.recipe.id == recipe.id }
                        toastCenter.show(
                            title: "Removed from next prep",
                            subtitle: recipe.title,
                            systemImage: "minus.circle.fill",
                            thumbnailURLString: recipe.imageURLString,
                            destination: nil,
                            actionTitle: "Undo",
                            action: { [store, toastCenter] in
                                guard let removedPlannedRecipe else { return }
                                Task {
                                    await store.updateLatestPlan(
                                        with: removedPlannedRecipe.recipe,
                                        servings: removedPlannedRecipe.servings
                                    )
                                    await MainActor.run {
                                        toastCenter.dismiss()
                                    }
                                }
                            }
                        )
                        Task {
                            await Task.yield()
                            await store.removeRecipeFromLatestPlan(recipeID: recipe.id)
                        }
                    },
                    onToggleRecurring: {
                        guard isCurrentPrepCycle else { return }
                        guard let plannedRecipe = store.latestPlan?.recipes.first(where: { $0.recipe.id == recipe.id })?.recipe else { return }
                        Task {
                            let succeeded = await store.toggleRecurringPrepRecipe(plannedRecipe)
                            await MainActor.run {
                                toastCenter.show(
                                    title: succeeded ? "Recurring anchor updated" : "Couldn’t update recurring",
                                    subtitle: succeeded ? plannedRecipe.title : "Check your connection and try again.",
                                    systemImage: succeeded ? "repeat.circle.fill" : "exclamationmark.triangle.fill"
                                )
                            }
                        }
                    },
                    onSelect: {
                        presentRecipeDetail(for: recipe)
                    }
                )
            }
        }
    }

    private func shiftRecipePage(by delta: Int) {
        guard !recipePages.isEmpty else { return }
        let nextIndex = min(max(selectedRecipePage + delta, 0), recipePages.count - 1)
        guard nextIndex != selectedRecipePage else { return }
        withAnimation(OunjeMotion.screenSpring) {
            selectedRecipePage = nextIndex
        }
    }

    private func clampSelectedRecipePage() {
        guard !recipePages.isEmpty else {
            selectedRecipePage = 0
            return
        }
        selectedRecipePage = min(selectedRecipePage, recipePages.count - 1)
    }

    private func presentRecipeDetail(for recipe: DiscoverRecipeCardData) {
        withAnimation(OunjeMotion.heroSpring) {
            presentedRecipe = PresentedRecipeDetail(recipeCard: recipe)
        }
    }

    private func togglePrepEditing() {
        withAnimation(OunjeMotion.quickSpring) {
            isEditingPrep.toggle()
        }
    }

    private func dismissPresentedRecipe() {
        withAnimation(OunjeMotion.heroSpring) {
            presentedRecipe = nil
        }
    }

    private func showPrepGenerationCompleteToast() {
        let recipeCard = store.latestPlan?.recipes
            .map(DiscoverRecipeCardData.init(preppedRecipe:))
            .randomElement()
        toastCenter.show(
            title: "Gen complete",
            subtitle: recipeCard?.title ?? "Fresh prep is ready.",
            systemImage: "checkmark.circle.fill",
            thumbnailURLString: recipeCard?.imageURLString ?? recipeCard?.heroImageURLString,
            destination: recipeCard.map(AppToastDestination.recipe)
        )
    }
}

struct CookbookCyclePromptSheet: View {
    let cycleTitle: String
    let recipeCount: Int
    let recurringCount: Int
    @Binding var selectedFocus: PrepRegenerationFocus
    @Binding var promptText: String
    let isGenerating: Bool
    let onCancel: () -> Void
    let onConfirm: (PrepGenerationOptions) -> Void
    @State private var targetRecipeCount: Int

    private let promptFocuses: [PrepRegenerationFocus] = PrepRegenerationFocus.allCases

    init(
        cycleTitle: String,
        recipeCount: Int,
        recurringCount: Int,
        selectedFocus: Binding<PrepRegenerationFocus>,
        promptText: Binding<String>,
        isGenerating: Bool,
        onCancel: @escaping () -> Void,
        onConfirm: @escaping (PrepGenerationOptions) -> Void
    ) {
        self.cycleTitle = cycleTitle
        self.recipeCount = recipeCount
        self.recurringCount = recurringCount
        _selectedFocus = selectedFocus
        _promptText = promptText
        self.isGenerating = isGenerating
        self.onCancel = onCancel
        self.onConfirm = onConfirm
        let minimumRecipeCount = max(recurringCount, 1)
        let maximumRecipeCount = max(10, minimumRecipeCount)
        _targetRecipeCount = State(initialValue: min(max(recipeCount, minimumRecipeCount), maximumRecipeCount))
    }

    private var recurringCountText: String {
        recurringCount == 1 ? "1 recurring locked" : "\(recurringCount) recurring locked"
    }

    private var targetRecipeCountText: String {
        targetRecipeCount == 1 ? "1 meal" : "\(targetRecipeCount) meals"
    }

    private var minimumRecipeCount: Int {
        max(recurringCount, 1)
    }

    private var maximumRecipeCount: Int {
        max(10, minimumRecipeCount)
    }

    var body: some View {
        ZStack {
            OunjePalette.background.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 10) {
                    SleeScriptDisplayText("Shape this prep.", size: 26, color: OunjePalette.primaryText)
                    Text(cycleTitle)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(OunjePalette.secondaryText.opacity(0.72))

                    Text("\(targetRecipeCountText) • \(recurringCountText)")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(OunjePalette.secondaryText)
                }

                PrepRecipeCountControl(
                    value: $targetRecipeCount,
                    minimumValue: minimumRecipeCount,
                    maximumValue: maximumRecipeCount
                )

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

                Spacer(minLength: 0)

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
                    .disabled(isGenerating)
                    .opacity(isGenerating ? 0.72 : 1)

                    Button {
                        onConfirm(
                            PrepGenerationOptions(
                                focus: selectedFocus,
                                targetRecipeCount: targetRecipeCount,
                                userPrompt: promptText
                            )
                        )
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
            .padding(.bottom, 12)
        }
    }
}

struct AskOunjeSheet: View {
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

struct MealsRecipeSlot: View {
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

struct WeekMealRow: View {
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

struct MealsSummaryCard: View {
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

struct PrepTrackerCard: View {
    @ObservedObject var store: MealPlanningAppStore
    @Environment(\.openURL) private var openURL
    @State private var isTimeEditorPresented = false
    @State private var isScheduleEditorPresented = false
    @State private var selectedDeliveryTime = Date()
    @State private var selectedCadence: MealCadence = .weekly
    @State private var selectedAnchorDate = Date()

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
                    run: store.latestInstacartRun,
                    address: store.profile?.deliveryAddress,
                    isProfileHydrating: store.isHydratingRemoteState && store.profile == nil,
                    autoshopOverlayPhase: autoshopOverlayPhase,
                    onRunAutoshop: {
                        Task { await store.startManualAutoshopRun(trigger: "prep_overlay") }
                    },
                    onOpenAutoshop: {
                        if let url = autoshopReviewURL {
                            openURL(url)
                        } else {
                            Task { await store.refreshLatestGroceryOrderTracking() }
                        }
                    },
                    onRefreshTracking: {
                        Task {
                            await store.refreshLatestGroceryOrderTracking()
                        }
                    }
                )

                if let quote = store.latestPlan?.bestQuote, !quote.reviewItems.isEmpty {
                    ProviderCartReviewCard(quote: quote)
                }
            }
            .padding(.top, 4)
        }
        .padding(.bottom, 4)
        .sheet(isPresented: $isScheduleEditorPresented) {
            DeliveryScheduleSheet(
                selectedCadence: $selectedCadence,
                selectedAnchorDate: $selectedAnchorDate,
                onCancel: {
                    isScheduleEditorPresented = false
                },
                onSave: {
                    saveDeliverySchedule()
                }
            )
            .presentationDetents([.height(640)])
            .presentationDragIndicator(.visible)
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
            selectedCadence = profile.cadence
            selectedAnchorDate = DeliveryScheduleSelectionBounds.clamped(
                profile.deliveryAnchorDate ?? profile.scheduledDeliveryDate()
            )
            isScheduleEditorPresented = true
        } label: {
            PrepMetaPill(title: profile.cadenceScheduleSummary, accent: OunjePalette.softCream)
        }
        .buttonStyle(.plain)
    }

    private var snapshot: PrepDeliverySnapshot {
        PrepDeliverySnapshot(
            nextPrepDate: scheduledDeliveryDate,
            generatedAt: store.latestPlan?.generatedAt,
            quote: store.latestPlan?.bestQuote,
            latestRun: store.latestInstacartRun,
            latestOrder: store.latestGroceryOrder,
            automationState: store.automationState
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

    private var autoshopOverlayPhase: PrepAutoshopOverlayPhase {
        let runStatus = store.latestInstacartRun?.normalizedStatusKind ?? ""
        let retryState = store.latestInstacartRun?.normalizedRetryState ?? ""
        let orderStatus = store.latestGroceryOrder?.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""

        if store.isManualAutoshopRunning || ["queued", "running"].contains(runStatus) || ["queued", "running"].contains(retryState) {
            return .running
        }
        if store.manualAutoshopErrorMessage?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            || runStatus == "failed"
            || runStatus == "partial" {
            return .error
        }
        if ["awaiting_review", "user_approved", "checkout_started"].contains(orderStatus)
            || (runStatus == "completed" && autoshopReviewURL != nil) {
            return .reviewReady
        }
        if isReadyForManualAutoshop {
            return .ready
        }
        return .hidden
    }

    private var isReadyForManualAutoshop: Bool {
        guard store.profile?.deliveryAddress.isComplete == true,
              store.latestPlan?.bestQuote?.provider == .instacart,
              store.latestPlan?.mainShopSnapshot?.items.isEmpty == false,
              store.latestPlan?.groceryItems.isEmpty == false,
              !store.isRefreshingMainShopSnapshot,
              !store.hasBlockingInstacartActivity
        else {
            return false
        }
        return true
    }

    private var autoshopReviewURL: URL? {
        if let trackingURL = store.latestGroceryOrder?.providerTrackingURLString
            .flatMap({ URL(string: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }) {
            return trackingURL
        }
        return store.latestInstacartRun?.trackingURL
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

    private func saveDeliverySchedule() {
        guard var updatedProfile = store.profile else {
            isScheduleEditorPresented = false
            return
        }

        let resolvedAnchor = DeliveryScheduleSelectionBounds.clamped(selectedAnchorDate)
        updatedProfile.cadence = selectedCadence
        updatedProfile.deliveryAnchorDate = resolvedAnchor
        updatedProfile.deliveryAnchorDay = DeliveryAnchorDay.from(date: resolvedAnchor)
        store.updateProfile(updatedProfile)
        isScheduleEditorPresented = false
    }
}

struct PrepDeliverySnapshot {
    enum Stage {
        case queuedForSetup
        case matchingToInstacart
        case selectingStore
        case finalizingGroceries
        case checkoutReady
        case waitingForDelivery
        case handoffToTracking
        case delivered
    }

    let nextPrepDate: Date?
    let generatedAt: Date?
    let quote: ProviderQuote?
    let latestRun: InstacartRunLogSummary?
    let latestOrder: GroceryOrderSummaryRecord?
    let automationState: MealPrepAutomationState?

    private var calendar: Calendar { .current }
    private let setupLeadDays = 2
    private let confirmationLeadDays = 1

    private var daysUntilPrep: Int? {
        guard let nextPrepDate = nextPrepDate else { return nil }
        let now = calendar.startOfDay(for: .now)
        let target = calendar.startOfDay(for: nextPrepDate)
        return calendar.dateComponents([.day], from: now, to: target).day
    }

    private var selectedStoreName: String? {
        if let quoteStore = sanitizedInstacartStoreName(quote?.selectedStore?.storeName) {
            return quoteStore
        }
        return sanitizedInstacartStoreName(latestRun?.selectedStore)
    }

    private var normalizedOrderStatus: String {
        latestOrder?.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
    }

    private var normalizedRunStatus: String {
        latestRun?.normalizedStatusKind ?? ""
    }

    private var normalizedRetryState: String {
        latestRun?.normalizedRetryState ?? ""
    }

    private var normalizedTrackingStatus: String {
        latestOrder?.normalizedTrackingStatus ?? "unknown"
    }

    private var latestOrderStepLogEntry: GroceryOrderStepLogEntry? {
        latestOrder?.latestStepLogEntry
    }

    private var latestOrderStepLogTitle: String? {
        latestOrderStepLogEntry?.displayTitle
    }

    private var latestOrderStepLogBody: String? {
        latestOrderStepLogEntry?.displayBody
    }

    private var latestRunEventTitle: String? {
        let value = latestRun?.latestEventTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (value?.isEmpty == false) ? value : nil
    }

    private var latestRunEventBody: String? {
        let value = latestRun?.latestEventBody?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (value?.isEmpty == false) ? value : nil
    }

    private var hasStoreSelection: Bool {
        sanitizedInstacartStoreName(quote?.selectedStore?.storeName) != nil
            || sanitizedInstacartStoreName(latestRun?.selectedStore) != nil
    }

    private var hasStoreOptions: Bool {
        guard let quote else { return false }
        return !quote.storeOptions.isEmpty
    }

    private var requiresCartFinalization: Bool {
        if let latestRun {
            if latestRun.normalizedStatusKind == "failed" { return true }
            if latestRun.unresolvedCount > 0 || latestRun.shortfallCount > 0 { return true }
            if latestRun.partialSuccess { return true }
        }
        guard let quote else { return false }
        let unresolvedItems = quote.reviewItems.filter { item in
            item.needsReview || item.status.caseInsensitiveCompare("unresolved") == .orderedSame
        }
        return quote.providerStatus != .live || quote.partialSuccess || !unresolvedItems.isEmpty
    }

    private var supportsTrackingHandoff: Bool {
        if latestRun?.trackingURL != nil { return true }
        guard let quote else { return false }
        let host = quote.orderURL.host?.lowercased() ?? ""
        if quote.provider == .instacart, host.contains("instacart") { return true }
        return quote.providerStatus == .live
    }

    private var hasCompletedRun: Bool {
        guard let latestRun else { return false }
        return latestRun.normalizedStatusKind == "completed"
            && latestRun.unresolvedCount == 0
            && latestRun.shortfallCount == 0
    }

    private var hasReachedSetupWindow: Bool {
        guard let daysUntilPrep else { return true }
        return daysUntilPrep <= setupLeadDays
    }

    private var hasReachedConfirmationWindow: Bool {
        guard let daysUntilPrep else { return false }
        return daysUntilPrep <= confirmationLeadDays
    }

    var displayStoreTitle: String? {
        selectedStoreName
    }

    var trackingURL: URL? {
        if let latestOrderProviderTrackingURLString = latestOrder?.providerTrackingURLString,
           !latestOrderProviderTrackingURLString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let url = URL(string: latestOrderProviderTrackingURLString) {
            return url
        }
        return latestRun?.trackingURL ?? quote?.orderURL
    }

    var stage: Stage {
        switch normalizedTrackingStatus {
        case "delivered":
            return .delivered
        case "out_for_delivery":
            return .handoffToTracking
        case "shopping", "submitted":
            return .waitingForDelivery
        case "issue":
            return .finalizingGroceries
        default:
            break
        }

        switch normalizedOrderStatus {
        case "awaiting_review", "user_approved", "checkout_started":
            return .checkoutReady
        case "completed":
            return .handoffToTracking
        default:
            break
        }

        if let latestRun {
            if !hasStoreSelection, hasStoreOptions {
                return .selectingStore
            }
            if ["queued", "running"].contains(normalizedRetryState) {
                return .finalizingGroceries
            }
            if latestRun.normalizedStatusKind == "completed",
               latestRun.unresolvedCount == 0,
               latestRun.shortfallCount == 0 {
                return .checkoutReady
            }
            if requiresCartFinalization {
                return .finalizingGroceries
            }
            return .matchingToInstacart
        }

        if let days = daysUntilPrep, days > setupLeadDays {
            return .queuedForSetup
        }
        if let days = daysUntilPrep, days <= 0, hasCompletedRun {
            return .delivered
        }
        if !hasReachedSetupWindow {
            return .queuedForSetup
        }
        return .matchingToInstacart
    }

    var progress: CGFloat {
        switch normalizedTrackingStatus {
        case "shopping":
            return 0.78
        case "out_for_delivery":
            return 0.92
        case "delivered":
            return 1.0
        case "issue":
            return 0.58
        default:
            break
        }

        switch normalizedOrderStatus {
        case "awaiting_review":
            return 0.74
        case "user_approved", "checkout_started":
            return 0.84
        case "completed":
            return 0.91
        default:
            break
        }

        switch stage {
        case .queuedForSetup:
            return 0.06
        case .matchingToInstacart:
            return latestRun.map { max(0.14, min(0.42, CGFloat($0.progress) * 0.46)) } ?? 0.12
        case .selectingStore:
            return latestRun.map { max(0.26, min(0.50, CGFloat($0.progress) * 0.58)) } ?? 0.34
        case .finalizingGroceries:
            return latestRun.map { max(0.48, min(0.70, CGFloat($0.progress) * 0.82)) } ?? 0.58
        case .checkoutReady:
            return 0.76
        case .waitingForDelivery:
            return 0.72
        case .handoffToTracking:
            return 0.92
        case .delivered:
            return 1.0
        }
    }

    var statusLabel: String {
        switch normalizedRetryState {
        case "queued":
            return latestRunEventTitle ?? "Retry queued"
        case "running":
            return latestRunEventTitle ?? "Retrying unfinished items"
        case "completed":
            return latestRunEventTitle ?? "Retry completed"
        case "skipped":
            return latestRunEventTitle ?? "Retry skipped"
        case "failed", "partial":
            return latestRunEventTitle ?? "Retry needs attention"
        default:
            break
        }

        if let trackingTitle = latestOrder?.trackingTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
           !trackingTitle.isEmpty,
           ["shopping", "out_for_delivery", "delivered", "issue"].contains(normalizedTrackingStatus) {
            return trackingTitle
        }

        if let stepTitle = latestOrderStepLogTitle {
            return stepTitle
        }

        switch normalizedOrderStatus {
        case "awaiting_review":
            return "Checkout is ready"
        case "user_approved":
            return "Checkout approved"
        case "checkout_started":
            return "Opening Instacart checkout"
        case "completed":
            return "Tracking is starting"
        default:
            break
        }

        if normalizedRunStatus == "completed",
           let latestRun,
           latestRun.unresolvedCount == 0,
           latestRun.shortfallCount == 0 {
            return "Instacart cart is ready"
        }

        switch stage {
        case .queuedForSetup:
            return "Queued for setup"
        case .matchingToInstacart:
            if normalizedRunStatus == "running" || normalizedRunStatus == "queued" {
                return hasReachedConfirmationWindow ? "Confirming Instacart cart" : "Building Instacart cart"
            }
            return "Matching to Instacart"
        case .selectingStore:
            return "Selecting store"
        case .finalizingGroceries:
            return "Working on your cart"
        case .checkoutReady:
            return "Checkout is ready"
        case .waitingForDelivery:
            return "Waiting for delivery"
        case .handoffToTracking:
            return "Tracking in Instacart"
        case .delivered:
            return "Delivered"
        }
    }

    var statusSymbol: String {
        switch stage {
        case .queuedForSetup:
            return "calendar.badge.clock"
        case .matchingToInstacart:
            return "magnifyingglass"
        case .selectingStore:
            return "storefront.fill"
        case .finalizingGroceries:
            return "cart.fill"
        case .checkoutReady:
            return "creditcard.fill"
        case .waitingForDelivery:
            return "shippingbox.fill"
        case .handoffToTracking:
            return "location.fill"
        case .delivered:
            return "checkmark.circle.fill"
        }
    }

    var etaText: String? {
        switch normalizedRetryState {
        case "queued":
            return "Unfinished items only"
        case "running":
            return "Retrying now"
        case "completed":
            return "Retry done"
        case "skipped":
            return "Nothing left"
        case "failed", "partial":
            return "Needs attention"
        default:
            break
        }

        if let trackingEtaText = latestOrder?.trackingEtaText?.trimmingCharacters(in: .whitespacesAndNewlines),
           !trackingEtaText.isEmpty {
            return trackingEtaText
        }
        if stage == .delivered { return "Now" }
        if stage == .handoffToTracking { return normalizedOrderStatus == "completed" ? "Tracking live soon" : "Open app tracking" }
        if stage == .checkoutReady {
            if normalizedOrderStatus == "awaiting_review" {
                return "Awaiting checkout"
            }
            if normalizedOrderStatus == "checkout_started" || normalizedOrderStatus == "user_approved" {
                return "At provider checkout"
            }
            return "Cart built"
        }
        if stage == .queuedForSetup, let daysUntilPrep {
            return daysUntilPrep == 1 ? "1 day out" : "\(daysUntilPrep)d out"
        }
        if stage == .matchingToInstacart, hasReachedConfirmationWindow {
            return "Final check"
        }
        if stage == .finalizingGroceries {
            if latestRun?.normalizedStatusKind == "failed" {
                return "Trying again"
            }
            if latestRun?.normalizedStatusKind == "partial" {
                return "Checking a few items"
            }
            return "Still matching items"
        }

        guard let quote else { return nil }
        let daysRemaining = max(0, daysUntilPrep ?? quote.etaDays)
        if daysRemaining <= 0 { return "Today" }
        if daysRemaining == 1 { return "Tomorrow" }
        return "\(daysRemaining)d away"
    }

    var liveUpdateText: String? {
        nil
    }
}

@MainActor
final class PrepDeliveryMapModel: ObservableObject {
    @Published var homeCoordinate: CLLocationCoordinate2D?
    @Published var storeCoordinate: CLLocationCoordinate2D?
    @Published var region = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194),
        span: MKCoordinateSpan(latitudeDelta: 0.08, longitudeDelta: 0.08)
    )
    @Published private(set) var isLoading = false
    @Published private(set) var hasResolvedAttempt = false
    @Published private(set) var didFailResolution = false

    private let geocoder = CLGeocoder()
    private var lastAddressKey = ""

    func load(address: DeliveryAddress?, provider: ShoppingProvider?, selectedStoreName: String?) async {
        geocoder.cancelGeocode()

        guard let address = address, address.isComplete else {
            isLoading = false
            hasResolvedAttempt = true
            didFailResolution = false
            homeCoordinate = nil
            storeCoordinate = nil
            lastAddressKey = ""
            return
        }

        let addressKey = [address.line1, address.city, address.region, address.postalCode]
            .joined(separator: ", ")
        let storeKey = selectedStoreName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let cacheKey = "\(addressKey)::\(provider?.rawValue ?? "none")::\(storeKey.lowercased())"

        if cacheKey == lastAddressKey, homeCoordinate != nil, storeCoordinate != nil {
            isLoading = false
            hasResolvedAttempt = true
            didFailResolution = false
            return
        }

        isLoading = true
        hasResolvedAttempt = false
        didFailResolution = false
        defer {
            isLoading = false
            hasResolvedAttempt = true
        }

        do {
            let placemarks = try await geocoder.geocodeAddressString(addressKey)
            guard let coordinate = placemarks.first?.location?.coordinate else {
                didFailResolution = true
                homeCoordinate = nil
                storeCoordinate = nil
                return
            }

            let storePoint = await resolveStoreCoordinate(
                from: coordinate,
                provider: provider,
                selectedStoreName: selectedStoreName,
                address: address
            )
            homeCoordinate = coordinate
            storeCoordinate = storePoint
            region = regionFitting(from: storePoint, to: coordinate)
            lastAddressKey = cacheKey
        } catch {
            didFailResolution = true
            homeCoordinate = nil
            storeCoordinate = nil
        }
    }

    private func resolveStoreCoordinate(
        from home: CLLocationCoordinate2D,
        provider: ShoppingProvider?,
        selectedStoreName: String?,
        address: DeliveryAddress
    ) async -> CLLocationCoordinate2D {
        guard let selectedStoreName else {
            return derivedStoreCoordinate(from: home, provider: provider)
        }

        let trimmedStore = selectedStoreName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedStore.isEmpty else {
            return derivedStoreCoordinate(from: home, provider: provider)
        }

        let storeQuery = [trimmedStore, address.city, address.region, address.postalCode]
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: ", ")

        do {
            let placemarks = try await geocoder.geocodeAddressString(storeQuery)
            if let coordinate = placemarks.first?.location?.coordinate {
                return coordinate
            }
        } catch {}

        return derivedStoreCoordinate(from: home, provider: provider)
    }

    private func derivedStoreCoordinate(from home: CLLocationCoordinate2D, provider: ShoppingProvider?) -> CLLocationCoordinate2D {
        let delta: (Double, Double)
        switch provider {
        case .instacart:
            delta = (0.018, -0.020)
        case .amazonFresh:
            delta = (0.014, 0.018)
        case .kroger, .walmart, .none:
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

enum PrepAutoshopOverlayPhase: Equatable {
    case hidden
    case ready
    case running
    case reviewReady
    case error

    var isVisible: Bool { self != .hidden }

    var title: String {
        switch self {
        case .hidden:
            return ""
        case .ready:
            return "Cart is ready when you are"
        case .running:
            return "Building your Instacart cart..."
        case .reviewReady:
            return "Cart ready for review"
        case .error:
            return "Autoshop needs a retry"
        }
    }

    var symbol: String {
        switch self {
        case .hidden:
            return "cart"
        case .ready:
            return "cart.fill"
        case .running:
            return "cart.badge.plus"
        case .reviewReady:
            return "checkmark.circle.fill"
        case .error:
            return "exclamationmark.triangle.fill"
        }
    }
}

struct PrepDeliveryMapPanel: View {
    let snapshot: PrepDeliverySnapshot
    let quote: ProviderQuote?
    let run: InstacartRunLogSummary?
    let address: DeliveryAddress?
    let isProfileHydrating: Bool
    let autoshopOverlayPhase: PrepAutoshopOverlayPhase
    let onRunAutoshop: (() -> Void)?
    let onOpenAutoshop: (() -> Void)?
    let onRefreshTracking: (() -> Void)?

    @StateObject private var model = PrepDeliveryMapModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ZStack(alignment: .center) {
                if let home = model.homeCoordinate, let store = model.storeCoordinate {
                    let _ = (home, store)
                    Map(coordinateRegion: $model.region, interactionModes: [])
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                        .transition(.opacity.combined(with: .scale(scale: 0.98)))
                } else {
                    PrepDeliveryMapPlaceholderCard(
                        title: mapPlaceholderTitle,
                        detail: mapPlaceholderDetail,
                        accent: mapPlaceholderAccent,
                        visualState: mapVisualState
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.opacity)
                }

                if autoshopOverlayPhase.isVisible {
                    PrepAutoshopOverlayCue(
                        phase: autoshopOverlayPhase,
                        action: autoshopOverlayAction
                    )
                    .padding(.horizontal, 18)
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.92).combined(with: .opacity),
                        removal: .scale(scale: 0.96).combined(with: .opacity)
                    ))
                }
            }
            .frame(height: 152)

            PrepRouteOverlay(
                snapshot: snapshot,
                providerTitle: quote?.provider.marketingTitle,
                storeTitle: snapshot.displayStoreTitle,
                etaText: snapshot.etaText,
                trackingURL: snapshot.stage == .handoffToTracking ? snapshot.trackingURL : nil,
                onRefreshTracking: onRefreshTracking
            )
        }
        .task(id: mapTaskID) {
            await model.load(
                address: address,
                provider: quote?.provider,
                selectedStoreName: snapshot.displayStoreTitle
            )
        }
        .animation(OunjeMotion.screenSpring, value: mapVisualState)
        .animation(.spring(response: 0.34, dampingFraction: 0.78), value: autoshopOverlayPhase)
    }

    private var autoshopOverlayAction: () -> Void {
        switch autoshopOverlayPhase {
        case .ready, .error:
            return onRunAutoshop ?? {}
        case .reviewReady:
            return onOpenAutoshop ?? {}
        case .running, .hidden:
            return {}
        }
    }

    private var mapVisualState: PrepDeliveryMapVisualState {
        if model.homeCoordinate != nil && model.storeCoordinate != nil {
            return .resolved
        }
        if isProfileHydrating {
            return .loadingProfile
        }
        if model.isLoading || (address?.isComplete == true && !model.hasResolvedAttempt) {
            return .resolvingAddress
        }
        if address?.isComplete == true, model.didFailResolution {
            return .addressLookupFailed
        }
        return .missingAddress
    }

    private var mapPlaceholderTitle: String {
        switch mapVisualState {
        case .loadingProfile:
            return "Loading home base"
        case .resolvingAddress:
            return "Mapping your route"
        case .missingAddress:
            return "Add a delivery address"
        case .addressLookupFailed:
            return "Couldn't map this address"
        case .resolved:
            return ""
        }
    }

    private var mapPlaceholderDetail: String {
        switch mapVisualState {
        case .loadingProfile:
            return "Pulling your saved delivery address into Prep."
        case .resolvingAddress:
            return "Resolving your home and grocery coordinates."
        case .missingAddress:
            return "Set home base in Profile and the live route will wake up here."
        case .addressLookupFailed:
            return "We couldn't place your saved address yet. Check it in Profile and we'll retry."
        case .resolved:
            return ""
        }
    }

    private var mapPlaceholderAccent: Color {
        switch mapVisualState {
        case .loadingProfile, .resolvingAddress:
            return OunjePalette.accent
        case .missingAddress:
            return OunjePalette.secondaryText.opacity(0.92)
        case .addressLookupFailed:
            return Color(red: 0.94, green: 0.68, blue: 0.28)
        case .resolved:
            return OunjePalette.accent
        }
    }

    private var mapTaskID: String {
        let addressKey = [address?.line1, address?.city, address?.region, address?.postalCode]
            .compactMap { $0 }
            .joined(separator: "|")
        return "\(addressKey)::\(quote?.provider.rawValue ?? "none")::\(snapshot.displayStoreTitle ?? sanitizedInstacartStoreName(run?.selectedStore) ?? "none")"
    }
}

private struct PrepAutoshopOverlayCue: View {
    let phase: PrepAutoshopOverlayPhase
    let action: () -> Void

    @State private var isAnimating = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                icon

                Text(phase.title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)

                if phase == .reviewReady {
                    Image(systemName: "arrow.up.forward")
                        .font(.system(size: 10, weight: .bold))
                } else if phase == .ready || phase == .error {
                    Image(systemName: "arrow.right")
                        .font(.system(size: 10, weight: .bold))
                        .offset(x: reduceMotion ? 0 : (isAnimating ? 2 : -1))
                }
            }
            .foregroundStyle(foregroundColor)
            .padding(.horizontal, 13)
            .padding(.vertical, 8)
            .background(
                Capsule(style: .continuous)
                    .fill(OunjePalette.background.opacity(0.86))
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(strokeColor, lineWidth: 1)
                    )
                    .shadow(color: Color.black.opacity(0.24), radius: 12, x: 0, y: 8)
            )
            .scaleEffect(reduceMotion || phase == .running ? 1 : (isAnimating ? 1.03 : 0.98))
        }
        .buttonStyle(.plain)
        .disabled(phase == .running || phase == .hidden)
        .accessibilityLabel(phase.title)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.72).repeatForever(autoreverses: true)) {
                isAnimating = true
            }
        }
    }

    @ViewBuilder
    private var icon: some View {
        if phase == .running {
            ProgressView()
                .tint(OunjePalette.softCream)
                .scaleEffect(0.72)
                .frame(width: 15, height: 15)
        } else {
            Image(systemName: phase.symbol)
                .font(.system(size: 12, weight: .bold))
                .offset(y: reduceMotion ? 0 : (isAnimating && phase == .ready ? -1.5 : 1))
        }
    }

    private var foregroundColor: Color {
        switch phase {
        case .error:
            return Color(hex: "FFB0A0")
        case .reviewReady:
            return OunjePalette.accent
        case .hidden, .ready, .running:
            return OunjePalette.softCream.opacity(0.95)
        }
    }

    private var strokeColor: Color {
        switch phase {
        case .error:
            return Color(hex: "FF8E8E").opacity(0.58)
        case .reviewReady, .ready, .running:
            return OunjePalette.accent.opacity(0.52)
        case .hidden:
            return OunjePalette.stroke.opacity(0.5)
        }
    }
}

enum PrepDeliveryMapVisualState: Equatable {
    case resolved
    case loadingProfile
    case resolvingAddress
    case missingAddress
    case addressLookupFailed

    var isLoading: Bool {
        self == .loadingProfile || self == .resolvingAddress
    }
}

struct PrepDeliveryMapPlaceholderCard: View {
    let title: String
    let detail: String
    var accent: Color = OunjePalette.accent
    var visualState: PrepDeliveryMapVisualState = .loadingProfile

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Image("TorontoPrepMapPlaceholder")
                .resizable()
                .scaledToFill()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()

            LinearGradient(
                colors: [
                    OunjePalette.background.opacity(0.18),
                    OunjePalette.background.opacity(0.34),
                    OunjePalette.background.opacity(0.86)
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            HStack {
                Spacer()
                PrepMapStateGlyph(visualState: visualState, accent: accent)
                    .frame(width: 44, height: 44)
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .padding(14)

            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 7) {
                    Image(systemName: statusSymbolName)
                        .font(.system(size: 11, weight: .bold))
                    Text(statusTitle)
                        .font(.system(size: 11, weight: .bold))
                }
                .foregroundStyle(accent)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    Capsule(style: .continuous)
                        .fill(OunjePalette.background.opacity(0.72))
                        .overlay(
                            Capsule(style: .continuous)
                                .stroke(accent.opacity(0.25), lineWidth: 1)
                        )
                )

                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(OunjePalette.primaryText)

                Text(detail)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(OunjePalette.secondaryText)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(OunjePalette.stroke.opacity(0.8), lineWidth: 1)
        )
    }

    private var statusTitle: String {
        switch visualState {
        case .loadingProfile:
            return "Loading base"
        case .resolvingAddress:
            return "Mapping route"
        case .missingAddress:
            return "Home base needed"
        case .addressLookupFailed:
            return "Check address"
        case .resolved:
            return "Route ready"
        }
    }

    private var statusSymbolName: String {
        switch visualState {
        case .loadingProfile:
            return "icloud.and.arrow.down.fill"
        case .resolvingAddress:
            return "location.magnifyingglass"
        case .missingAddress:
            return "mappin.and.ellipse"
        case .addressLookupFailed:
            return "exclamationmark.triangle.fill"
        case .resolved:
            return "checkmark"
        }
    }
}

struct PrepMapStateGlyph: View {
    let visualState: PrepDeliveryMapVisualState
    let accent: Color

    var body: some View {
        ZStack {
            Circle()
                .fill(OunjePalette.surface.opacity(0.84))
                .overlay(
                    Circle()
                        .stroke(accent.opacity(0.22), lineWidth: 1)
                )

            switch visualState {
            case .loadingProfile, .resolvingAddress:
                ProgressView()
                    .controlSize(.small)
                    .tint(accent)
            case .missingAddress:
                Image(systemName: "mappin.slash")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(OunjePalette.secondaryText)
            case .addressLookupFailed:
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.orange)
            case .resolved:
                Image(systemName: "checkmark")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(accent)
            }
        }
        .clipShape(Circle())
    }
}

struct PrepMetaPill: View {
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

struct ProviderCartReviewCard: View {
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
                Text("Cart choices")
                    .font(.system(size: 16, weight: .bold))
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

        return parts.isEmpty ? "All set" : parts.joined(separator: " • ")
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

enum DeliveryScheduleSelectionBounds {
    static var range: ClosedRange<Date> {
        let calendar = Calendar.current
        let lower = calendar.startOfDay(for: .now)
        let upper = calendar.date(byAdding: .year, value: 1, to: lower) ?? lower
        return lower...upper
    }

    static func clamped(_ value: Date) -> Date {
        let calendar = Calendar.current
        let day = calendar.startOfDay(for: value)
        let bounds = range
        return min(max(day, bounds.lowerBound), bounds.upperBound)
    }
}

struct DeliveryScheduleSheet: View {
    @Binding var selectedCadence: MealCadence
    @Binding var selectedAnchorDate: Date
    let onCancel: () -> Void
    let onSave: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Capsule()
                .fill(OunjePalette.stroke.opacity(0.9))
                .frame(width: 56, height: 5)
                .frame(maxWidth: .infinity)
                .padding(.top, 4)

            VStack(alignment: .leading, spacing: 6) {
                Text("Delivery schedule")
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .foregroundStyle(OunjePalette.primaryText)

                Text("Pick frequency, then choose the next delivery date.")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(OunjePalette.secondaryText)
            }
            .padding(.bottom, 2)

            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(MealCadence.allCases) { cadence in
                            Button {
                                selectedCadence = cadence
                            } label: {
                                Text(cadence.title)
                                    .sleeDisplayFont(14)
                                    .foregroundStyle(selectedCadence == cadence ? OunjePalette.primaryText : OunjePalette.secondaryText)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 9)
                                    .background(
                                        Capsule(style: .continuous)
                                            .fill(
                                                selectedCadence == cadence
                                                    ? OunjePalette.accent.opacity(0.26)
                                                    : OunjePalette.surface
                                            )
                                    )
                                    .overlay(
                                        Capsule(style: .continuous)
                                            .stroke(
                                                selectedCadence == cadence
                                                    ? OunjePalette.accent.opacity(0.48)
                                                    : OunjePalette.stroke,
                                                lineWidth: 1
                                            )
                                    )
                            }
                            .buttonStyle(.plain)
                            .id(cadence.id)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .onAppear {
                    scrollToSelectedCadence(using: proxy)
                }
                .onChange(of: selectedCadence) { _ in
                    scrollToSelectedCadence(using: proxy)
                }
            }

            DatePicker(
                "Start date",
                selection: clampedAnchorDateBinding,
                in: DeliveryScheduleSelectionBounds.range,
                displayedComponents: .date
            )
            .datePickerStyle(.graphical)
            .labelsHidden()
            .tint(Color(hex: "2FAF78"))
            .colorScheme(.dark)
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(OunjePalette.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .stroke(OunjePalette.stroke, lineWidth: 1)
                    )
            )
            Spacer(minLength: 10)

            HStack(spacing: 12) {
                Button(action: onCancel) {
                    Text("Cancel")
                        .sleeDisplayFont(16)
                        .foregroundStyle(OunjePalette.primaryText)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
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

                Button(action: onSave) {
                    Text("Save")
                        .sleeDisplayFont(16)
                        .foregroundStyle(OunjePalette.primaryText)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
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
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 6)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(OunjePalette.background.ignoresSafeArea())
    }

    private var clampedAnchorDateBinding: Binding<Date> {
        Binding(
            get: { DeliveryScheduleSelectionBounds.clamped(selectedAnchorDate) },
            set: { selectedAnchorDate = DeliveryScheduleSelectionBounds.clamped($0) }
        )
    }

    private func scrollToSelectedCadence(using proxy: ScrollViewProxy) {
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.25)) {
                proxy.scrollTo(selectedCadence.id, anchor: .center)
            }
        }
    }
}

struct DeliveryTimeSheet: View {
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
        return "\(provider.marketingTitle) for \(scheduledDeliveryDate.formatted(.dateTime.weekday(.wide).month(.wide).day()))"
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

struct PrepRouteOverlay: View {
    let snapshot: PrepDeliverySnapshot
    let providerTitle: String?
    let storeTitle: String?
    let etaText: String?
    let trackingURL: URL?
    let onRefreshTracking: (() -> Void)?

    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                let trimmedStoreTitle = storeTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
                let trimmedProviderTitle = providerTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
                let title = (trimmedStoreTitle?.isEmpty == false ? trimmedStoreTitle : nil)
                    ?? (trimmedProviderTitle?.isEmpty == false ? trimmedProviderTitle : nil)
                    ?? ""

                HStack(spacing: 6) {
                    Image(systemName: "storefront.fill")
                        .font(.system(size: 11, weight: .bold))
                    Text(title.isEmpty ? "Delivery" : title)
                        .biroHeaderFont(11)
                }
                .foregroundStyle(OunjePalette.primaryText)

                Spacer(minLength: 0)

                Image(systemName: snapshot.statusSymbol)
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

            if snapshot.stage == .handoffToTracking, let trackingURL {
                HStack(spacing: 8) {
                    Button {
                        openURL(trackingURL)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "location.fill")
                                .font(.system(size: 11, weight: .bold))
                            Text("Open Instacart tracking")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .foregroundStyle(OunjePalette.softCream)
                    }
                    .buttonStyle(.plain)

                    if let onRefreshTracking {
                        Button {
                            onRefreshTracking()
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "arrow.clockwise")
                                    .font(.system(size: 11, weight: .bold))
                                Text("Refresh delivery")
                                    .font(.system(size: 11, weight: .semibold))
                            }
                            .foregroundStyle(OunjePalette.primaryText)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(.horizontal, 2)
        .padding(.vertical, 4)
    }
}
