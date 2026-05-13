import SwiftUI
import Foundation
import UIKit
import AVKit
import WebKit

struct RecipeAskOnboardingConfig {
    let demoRecipe: OnboardingRecipeEditDemoRecipe
    let selectedDietaryPatterns: Set<String>
    let onComplete: () -> Void
}

enum RecipeAskMode {
    case live
    case onboarding(RecipeAskOnboardingConfig)
}

enum RecipeDetailOnboardingContext {
    case baseDemo(
        demoRecipe: OnboardingRecipeEditDemoRecipe,
        selectedDietaryPatterns: Set<String>,
        onComplete: () -> Void
    )
    case adaptedDemo(onContinue: () -> Void)

    var askMode: RecipeAskMode? {
        switch self {
        case let .baseDemo(demoRecipe, selectedDietaryPatterns, onComplete):
            return .onboarding(
                RecipeAskOnboardingConfig(
                    demoRecipe: demoRecipe,
                    selectedDietaryPatterns: selectedDietaryPatterns,
                    onComplete: onComplete
                )
            )
        case .adaptedDemo:
            return nil
        }
    }

    var showsAskCue: Bool {
        if case .baseDemo = self {
            return true
        }
        return false
    }

    var continueAction: (() -> Void)? {
        guard case let .adaptedDemo(onContinue) = self else { return nil }
        return onContinue
    }
}

struct RecipeDetailExperienceView: View {
    let presentedRecipe: PresentedRecipeDetail
    let onOpenCart: () -> Void
    let onDismiss: (() -> Void)?
    let transitionNamespace: Namespace.ID?
    let onOpenToastDestination: ((AppToastDestination) -> Void)?
    let onboardingContext: RecipeDetailOnboardingContext?
    @ObservedObject private var toastCenter: AppToastCenter

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @EnvironmentObject private var store: MealPlanningAppStore
    @EnvironmentObject private var savedStore: SavedRecipesStore
    @StateObject private var viewModel: RecipeDetailViewModel
    @State private var relatedPresentedRecipe: PresentedRecipeDetail?
    @State private var servingsCount = 4
    @State private var baseServingsCount = 4
    @State private var shouldScrollToSteps = false
    @State private var showShareSheet = false
    @State private var isPreparingShareLink = false
    @State private var preparedShareItems: [Any] = []
    @State private var showStorySheet = false
    @State private var showAskSheet = false
    @State private var showInlineVideo = false
    @State private var showInlineVideoFullscreen = false
    @State private var shouldResumeInlineVideoAfterFullscreen = false
    @State private var inlineVideoPlayer: AVPlayer?
    @State private var resolvedVideo: RecipeResolvedVideoData?
    @State private var isResolvingVideo = false
    @State private var webVideoAction: RecipeWebVideoAction = .none
    @State private var detailChromeVisible = false
    @State private var hasScrolledAdaptedOnboardingRecipe = false
    @State private var adaptedOnboardingCueTarget: OnboardingAdaptedRecipeCueTarget = .save
    @State private var adaptedOnboardingCueTask: Task<Void, Never>?
    @State private var recipeDetailScrollOffset: CGFloat = 0

    private let detailBackground = OunjePalette.background
    private let sectionDivider = OunjePalette.stroke

    private var accessToken: String? {
        store.authSession?.accessToken ?? store.resolvedTrackingSession?.accessToken
    }

    private var transitionContext: RecipeTransitionContext? {
        guard let transitionNamespace else { return nil }
        return RecipeTransitionContext(namespace: transitionNamespace, recipeID: presentedRecipe.id)
    }

    init(
        presentedRecipe: PresentedRecipeDetail,
        onOpenCart: @escaping () -> Void,
        toastCenter: AppToastCenter,
        onDismiss: (() -> Void)? = nil,
        transitionNamespace: Namespace.ID? = nil,
        onOpenToastDestination: ((AppToastDestination) -> Void)? = nil,
        onboardingContext: RecipeDetailOnboardingContext? = nil
    ) {
        self.presentedRecipe = presentedRecipe
        self.onOpenCart = onOpenCart
        self.onDismiss = onDismiss
        self.transitionNamespace = transitionNamespace
        self.onOpenToastDestination = onOpenToastDestination
        self.onboardingContext = onboardingContext
        _toastCenter = ObservedObject(wrappedValue: toastCenter)
        _viewModel = StateObject(wrappedValue: RecipeDetailViewModel(initialDetail: presentedRecipe.initialDetail))
    }

    private var detail: RecipeDetailData? {
        viewModel.detail
    }

    private var recipeID: String {
        detail?.id ?? presentedRecipe.id
    }

    private var isImportedRecipe: Bool {
        recipeID.hasPrefix("uir_") || presentedRecipe.id.hasPrefix("uir_")
    }

    @MainActor
    private func loadResolvedRecipeDetail() async {
        guard !isOnboardingDemo else { return }
        let session = await store.freshUserDataSession()
        let firstError = await viewModel.load(
            for: presentedRecipe.id,
            similarFallbackRecipeID: presentedRecipe.adaptedFromRecipeID,
            accessToken: session?.accessToken,
            deferAuthorizationError: true
        )

        guard let message = firstError, isRecipeDetailAuthorizationFailure(message) else {
            return
        }

        guard let refreshedSession = await store.refreshAuthSessionAfterAuthorizationFailure() else {
            await viewModel.load(
                for: presentedRecipe.id,
                similarFallbackRecipeID: presentedRecipe.adaptedFromRecipeID,
                accessToken: session?.accessToken
            )
            return
        }

        await viewModel.load(
            for: presentedRecipe.id,
            similarFallbackRecipeID: presentedRecipe.adaptedFromRecipeID,
            accessToken: refreshedSession.accessToken
        )
    }

    private func isRecipeDetailAuthorizationFailure(_ message: String) -> Bool {
        let normalized = message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.contains("authorization")
            || normalized.contains("session expired")
            || normalized.contains("sign in")
            || normalized.contains("jwt")
            || normalized.contains("token is expired")
            || normalized.contains("401")
            || normalized.contains("403")
    }

    private var isInCurrentPrep: Bool {
        store.latestPlan?.recipes.contains(where: { $0.recipe.id == recipeID }) ?? (presentedRecipe.plannedRecipe != nil)
    }

    private var replaceablePrepRecipeID: String? {
        guard let adaptedFromRecipeID = presentedRecipe.adaptedFromRecipeID,
              adaptedFromRecipeID != recipeID,
              store.latestPlan?.recipes.contains(where: { $0.recipe.id == adaptedFromRecipeID }) == true,
              !isInCurrentPrep
        else {
            return nil
        }
        return adaptedFromRecipeID
    }

    private var primaryBottomActionTitle: String {
        if replaceablePrepRecipeID != nil { return "Replace" }
        return isInCurrentPrep ? "Remove" : "Add"
    }

    private var ingredientSecondaryActionTitle: String {
        if replaceablePrepRecipeID != nil { return "Replace in prep" }
        return isInCurrentPrep ? "Remove from prep" : "Add to next prep"
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

    private var isAdaptedRecipe: Bool {
        if presentedRecipe.adaptedFromRecipeID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            return true
        }
        if detail?.source?.localizedCaseInsensitiveContains("adaptation") == true {
            return true
        }
        if detail?.detailFootnote?.localizedCaseInsensitiveContains("Adapted from") == true {
            return true
        }
        return false
    }

    private var isOnboardingDemo: Bool {
        onboardingContext != nil
    }

    private var showsOnboardingAskCue: Bool {
        onboardingContext?.showsAskCue == true
    }

    private var showsFloatingOnboardingAskReturnCue: Bool {
        showsOnboardingAskCue && !showAskSheet && recipeDetailScrollOffset < -124
    }

    private var onboardingContinueAction: (() -> Void)? {
        onboardingContext?.continueAction
    }

    private var isAdaptedOnboardingDemo: Bool {
        onboardingContinueAction != nil
    }

    private var showsRecipeSaveAction: Bool {
        !isOnboardingDemo || isAdaptedOnboardingDemo
    }

    private var showsRecipeAskAction: Bool {
        !isOnboardingDemo || showsOnboardingAskCue
    }

    private var showsRecipeSecondaryActions: Bool {
        !isOnboardingDemo
    }

    private func markAdaptedOnboardingRecipeScrolled() {
        guard onboardingContinueAction != nil, !hasScrolledAdaptedOnboardingRecipe else { return }
        adaptedOnboardingCueTask?.cancel()
        withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) {
            hasScrolledAdaptedOnboardingRecipe = true
            adaptedOnboardingCueTarget = .continue
        }
    }

    private func advanceAdaptedOnboardingCueToScroll() {
        guard isAdaptedOnboardingDemo, !hasScrolledAdaptedOnboardingRecipe else { return }
        adaptedOnboardingCueTask?.cancel()
        withAnimation(.spring(response: 0.5, dampingFraction: 0.84)) {
            adaptedOnboardingCueTarget = .scroll
        }
    }

    private func handleRecipeSaveTap() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.78)) {
            savedStore.toggle(presentedRecipe.recipeCard)
        }

        advanceAdaptedOnboardingCueToScroll()
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

    private var displayExternalURL: URL? {
        externalURL
    }

    private var authorURL: URL? {
        guard let raw = detail?.authorURLString?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return nil
        }
        return URL(string: raw)
    }

    private var videoSourceURL: URL? {
        if let attachedVideoURL = detail?.attachedVideoURL {
            return attachedVideoURL
        }

        return [detail?.originalURL, presentedRecipe.recipeCard.destinationURL]
            .compactMap { $0 }
            .first(where: Self.isWatchableSocialVideoURL)
    }

    private var resolvedVideoURL: URL? {
        resolvedVideo?.url
    }

    private var hasVideoSource: Bool {
        videoSourceURL != nil
    }

    private static func isWatchableSocialVideoURL(_ url: URL) -> Bool {
        let host = url.host?.lowercased() ?? ""
        let path = url.path.lowercased()
        if host.contains("tiktok.com") {
            return true
        }
        if host.contains("instagram.com") {
            return path.contains("/reel/") || path.contains("/p/") || path.contains("/tv/")
        }
        if host == "youtu.be" || host.contains("youtube.com") || host.contains("youtube-nocookie.com") {
            return path.contains("/shorts/") || path.contains("/watch") || host == "youtu.be"
        }
        return false
    }

    private var fallbackShareItems: [Any] {
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
        viewModel.isLoadingSimilarRecipes && detail != nil && viewModel.similarRecipes.isEmpty
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
        let collapsed = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !collapsed.isEmpty else { return nil }
        return collapsed
    }

    private func handleShareTap() {
        guard !isPreparingShareLink else { return }
        isPreparingShareLink = true
        Task { @MainActor in
            defer { isPreparingShareLink = false }
            do {
                let session = await store.freshUserDataSession()
                let response = try await RecipeDetailService.shared.createShareLink(
                    recipeID: recipeID,
                    userID: session?.userID ?? store.resolvedTrackingSession?.userID ?? store.authSession?.userID,
                    accessToken: session?.accessToken ?? accessToken
                )
                guard let shareURL = response.shareURL else {
                    throw SupabaseProfileStateError.invalidResponse
                }
                preparedShareItems = [titleText, shareURL]
                showShareSheet = true
            } catch {
                preparedShareItems = fallbackShareItems
                toastCenter.show(
                    title: "Sharing source link",
                    subtitle: "Ounje link was unavailable.",
                    systemImage: "square.and.arrow.up"
                )
                showShareSheet = true
            }
        }
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
            let heroSize = min(pageWidth * (isImportedRecipe ? 0.78 : 0.9), isImportedRecipe ? 326 : 376)
            let heroTopCrop = heroSize * 0.16
            let heroTopBleed = safeTop + (isImportedRecipe ? -16 : 18)
            let heroHeight = max(isImportedRecipe ? 216 : 198, heroSize - heroTopCrop + (isImportedRecipe ? 44 : 18))
            let topControlTop = max(safeTop + 26, 72)
            let videoButtonTop = topControlTop + 64
            let ingredientGrid = Self.ingredientGridSpec(for: pageWidth)
            ScrollViewReader { proxy in
                ZStack(alignment: .bottom) {
                    detailBackground
                        .ignoresSafeArea()

                    ScrollView {
                        VStack(spacing: 0) {
                            GeometryReader { scrollProxy in
                                Color.clear
                                    .preference(
                                        key: RecipeDetailScrollOffsetPreferenceKey.self,
                                        value: scrollProxy.frame(in: .named("recipe-detail-scroll")).minY
                                    )
                            }
                            .frame(height: 0)

                            ZStack(alignment: .top) {
                                Color.clear
                                    .frame(height: heroHeight)
                                    .overlay(alignment: .topTrailing) {
                                        RecipeDetailHeroImage(candidates: imageCandidates)
                                            .frame(width: heroSize, height: heroSize)
                                            .offset(
                                                x: heroSize * (isImportedRecipe ? 0.06 : 0.09),
                                                y: -(heroTopCrop + heroTopBleed)
                                            )
                                            .ignoresSafeArea(.container, edges: .top)
                                            .allowsHitTesting(false)
                                    }
                                    .overlay(alignment: .topTrailing) {
                                        if hasVideoSource && !isOnboardingDemo {
                                            RecipeDetailTopVideoButton(isActive: showInlineVideo) {
                                                toggleInlineVideo()
                                            }
                                            .padding(.trailing, 20)
                                            .padding(.top, videoButtonTop)
                                        }
                                    }
                            }
                            .frame(maxWidth: .infinity, alignment: .topLeading)

                            VStack(alignment: .leading, spacing: 30) {
                                RecipeModalTitle(text: titleText, isAdapted: isAdaptedRecipe)

                                VStack(alignment: .leading, spacing: 16) {
                                    if subtitleLine != nil || displayExternalURL != nil {
                                        HStack(spacing: 8) {
                                            if let subtitleLine {
                                                Text(subtitleLine)
                                                    .font(.system(size: 15, weight: .medium))
                                                    .foregroundStyle(OunjePalette.secondaryText)
                                            }

                                            if let displayExternalURL {
                                                if subtitleLine != nil {
                                                    Text("•")
                                                        .foregroundStyle(OunjePalette.secondaryText)
                                                }

                                                Button("See original link") {
                                                    openURL(displayExternalURL)
                                                }
                                                .font(.system(size: 15, weight: .medium))
                                                .foregroundStyle(OunjePalette.softCream)
                                                .buttonStyle(.plain)
                                                .underline()
                                            }
                                        }
                                    }

                                    if showsRecipeSaveAction || showsRecipeAskAction || showsRecipeSecondaryActions {
                                        HStack(spacing: 8) {
                                            if showsRecipeSaveAction {
                                                RecipeDetailCompactActionButton(
                                                    title: savedStore.isSaved(presentedRecipe.recipeCard) ? "Saved" : "Save",
                                                    systemImage: savedStore.isSaved(presentedRecipe.recipeCard) ? "bookmark.fill" : "bookmark",
                                                    compact: true
                                                ) {
                                                    handleRecipeSaveTap()
                                                }
                                                .overlay(alignment: .topTrailing) {
                                                    if isAdaptedOnboardingDemo, adaptedOnboardingCueTarget == .save {
                                                        OnboardingSaveRecipeCueView()
                                                            .allowsHitTesting(false)
                                                            .accessibilityHidden(true)
                                                    }
                                                }
                                            }

                                            if showsRecipeAskAction {
                                                RecipeDetailCompactActionButton(title: "Ask", systemImage: "sparkles", compact: true) {
                                                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                                    showAskSheet = true
                                                }
                                                .overlay(alignment: .topTrailing) {
                                                    if showsOnboardingAskCue && !showsFloatingOnboardingAskReturnCue {
                                                        OnboardingAskButtonCueView()
                                                    }
                                                }
                                            }

                                            if showsRecipeSecondaryActions {
                                                RecipeDetailCompactActionButton(title: "Story", showsInstagramGlyph: true, compact: true) {
                                                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                                    showStorySheet = true
                                                }
                                            }

                                            if hasVideoSource && showsRecipeSecondaryActions {
                                                RecipeDetailCompactActionButton(title: "Watch", systemImage: "play.fill", compact: true) {
                                                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                                    toggleInlineVideo()
                                                }
                                            }
                                        }
                                    }
                                }
                                .modifier(RecipeDetailChromeRevealModifier(isVisible: detailChromeVisible, yOffset: 12, delay: 0.04))

                                if let summaryLine {
                                    Text(summaryLine)
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundStyle(OunjePalette.secondaryText)
                                        .lineLimit(nil)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .modifier(RecipeDetailChromeRevealModifier(isVisible: detailChromeVisible, yOffset: 14, delay: 0.06))
                                }

                                Group {
                                    if isLoadingResolvedDetail {
                                        RecipeDetailLoadingSections()
                                    } else if detailLoadFailed {
                                        RecipeDetailLoadFailedState(message: viewModel.errorMessage ?? "We couldn't load the full recipe.") {
                                            Task {
                                                await loadResolvedRecipeDetail()
                                            }
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
                                                    columns: ingredientGrid.columns,
                                                    spacing: 24
                                                ) {
                                                    ForEach(ingredientItems, id: \.stableID) { ingredient in
                                                        RecipeIngredientTile(
                                                            ingredient: ingredient,
                                                            imageSize: ingredientGrid.tileWidth
                                                        )
                                                            .frame(width: ingredientGrid.tileWidth, alignment: .topLeading)
                                                    }
                                                }

                                                if !isOnboardingDemo {
                                                    ingredientSecondaryButton
                                                }
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

                                        if detail != nil && !isOnboardingDemo {
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
                                .modifier(RecipeDetailChromeRevealModifier(isVisible: detailChromeVisible, yOffset: 18, delay: 0.09))
                            }
                            .frame(maxWidth: 820, alignment: .leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 14)
                            .padding(.top, 12)
                            .padding(.bottom, 160)
                        }
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                    .coordinateSpace(name: "recipe-detail-scroll")
                    .scrollIndicators(.hidden)
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 8)
                            .onChanged { value in
                                if value.translation.height < -8 {
                                    markAdaptedOnboardingRecipeScrolled()
                                }
                            }
                    )
                    .onPreferenceChange(RecipeDetailScrollOffsetPreferenceKey.self) { minY in
                        recipeDetailScrollOffset = minY
                        if minY < -16 {
                            markAdaptedOnboardingRecipeScrolled()
                        }
                    }
                    .onChange(of: shouldScrollToSteps) { shouldScroll in
                        guard shouldScroll else { return }
                        withAnimation(.spring(response: 0.42, dampingFraction: 0.84)) {
                            proxy.scrollTo("steps-anchor", anchor: .top)
                        }
                        shouldScrollToSteps = false
                    }

                    if showsFloatingOnboardingAskReturnCue {
                        OnboardingAskReturnCueView()
                            .padding(.top, topControlTop + 82)
                            .padding(.trailing, 18)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }

                    if !isOnboardingDemo {
                        RecipeCookBottomBar(
                            servingsCount: $servingsCount,
                            actionTitle: primaryBottomActionTitle
                        ) {
                            handlePrimaryBottomAction()
                        }
                        .modifier(RecipeDetailChromeRevealModifier(isVisible: detailChromeVisible, yOffset: 22, delay: 0.1))
                    }
                }
                .overlay(alignment: .top) {
                    HStack(alignment: .top) {
                        RecipeDetailTopIconButton(symbolName: "arrow.left") {
                            closeExperience()
                        }
                        Spacer()
                        if !isOnboardingDemo {
                            RecipeDetailTopIconButton(symbolName: "arrow.up.right", isLoading: isPreparingShareLink) {
                                handleShareTap()
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, topControlTop)
                    .modifier(RecipeDetailChromeRevealModifier(isVisible: detailChromeVisible, yOffset: -8, delay: 0.02))
                }
                .overlay(alignment: .center) {
                    if onboardingContinueAction != nil, adaptedOnboardingCueTarget != .save {
                        OnboardingAdaptedRecipeNavigationCueView(
                            target: adaptedOnboardingCueTarget,
                            availableWidth: geometry.size.width,
                            availableHeight: geometry.size.height
                        )
                            .transition(.opacity.combined(with: .scale(scale: 0.96)))
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                .overlay(alignment: .bottom) {
                    if let onboardingContinueAction {
                        OnboardingRecipeContinueBar(action: onboardingContinueAction)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                            .modifier(RecipeDetailChromeRevealModifier(isVisible: detailChromeVisible, yOffset: 18, delay: 0.12))
                    }
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
                    AppToastBanner(
                        toast: toast,
                        onTap: toast.destination == nil ? nil : {
                            handleToastTap(toast)
                        }
                    )
                        .padding(.horizontal, 16)
                        .padding(.top, safeTop + 12)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .allowsHitTesting(toast.destination != nil || toast.action != nil)
                }
            }
            .task(id: presentedRecipe.id) {
                triggerChromeReveal()
                let loadedCount = presentedRecipe.plannedRecipe?.servings ?? viewModel.detail?.displayServings ?? 4
                baseServingsCount = max(1, loadedCount)
                servingsCount = max(1, loadedCount)
                await loadResolvedRecipeDetail()
            }
        }
        .background(detailBackground.ignoresSafeArea())
        .ignoresSafeArea(.container, edges: .top)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showShareSheet) {
            RecipeShareSheet(activityItems: preparedShareItems.isEmpty ? fallbackShareItems : preparedShareItems)
                .ignoresSafeArea()
        }
        .sheet(isPresented: $showStorySheet) {
            RecipeStoryShareSheet(
                recipeTitle: titleText,
                recipeSubtitle: subtitleLine ?? summaryLine,
                imageCandidates: imageCandidates,
                recipeURL: externalURL,
                onFallbackShare: {
                    showShareSheet = true
                }
            )
            .ignoresSafeArea()
        }
        .sheet(isPresented: $showAskSheet) {
            RecipeAskSheet(
                recipeTitle: titleText,
                recipeSubtitle: subtitleLine ?? summaryLine,
                recipeKind: detail?.recipeType ?? detail?.category ?? presentedRecipe.recipeCard.recipeType ?? presentedRecipe.recipeCard.category,
                recipeID: recipeID,
                baseImageURL: presentedRecipe.recipeCard.imageURL ?? imageCandidates.first,
                userID: store.resolvedTrackingSession?.userID ?? store.authSession?.userID,
                profile: store.profile,
                onOpenCart: onOpenCart,
                toastCenter: toastCenter,
                onOpenToastDestination: onOpenToastDestination,
                mode: onboardingContext?.askMode ?? .live
            )
            .ignoresSafeArea()
        }
        .fullScreenCover(item: $relatedPresentedRecipe) { recipe in
            RecipeDetailExperienceView(
                presentedRecipe: recipe,
                onOpenCart: onOpenCart,
                toastCenter: toastCenter,
                onOpenToastDestination: onOpenToastDestination
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
                    RecipeVideoLoadingOverlay(label: "Loading video")
                        .ignoresSafeArea()
                }
            }
        }
        .task(id: videoSourceURL?.absoluteString ?? "no-video") {
            guard videoSourceURL != nil, !isOnboardingDemo else {
                resolvedVideo = nil
                return
            }
            _ = await prepareInlineVideoIfNeeded()
        }
        .onAppear {
            triggerChromeReveal()
        }
        .onDisappear {
            adaptedOnboardingCueTask?.cancel()
            adaptedOnboardingCueTask = nil
        }
        .onChange(of: servingsCount) { newValue in
            guard isInCurrentPrep else { return }
            guard newValue != baseServingsCount else { return }
            Task { await persistPrepServingsChange(newValue) }
        }
    }

    private func closeExperience() {
        if let onDismiss {
            onDismiss()
        } else {
            dismiss()
        }
    }

    private func handleToastTap(_ toast: AppToast) {
        guard let destination = toast.destination else { return }
        toastCenter.dismiss()
        if let onOpenToastDestination {
            onOpenToastDestination(destination)
            return
        }

        switch destination {
        case .recipe(let recipe):
            relatedPresentedRecipe = PresentedRecipeDetail(recipeCard: recipe)
        case .appTab(.cart):
            onOpenCart()
        case .appTab, .recipeImportQueue:
            closeExperience()
        }
    }

    private func triggerChromeReveal() {
        detailChromeVisible = false
        DispatchQueue.main.async {
            withAnimation(OunjeMotion.screenSpring.delay(0.01)) {
                detailChromeVisible = true
            }
        }
    }

    private var ingredientSecondaryButton: some View {
        Button {
            Task {
                if let replaceablePrepRecipeID {
                    await replaceRecipeInPrep(sourceRecipeID: replaceablePrepRecipeID)
                } else if isInCurrentPrep {
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
            if let replaceablePrepRecipeID {
                await replaceRecipeInPrep(sourceRecipeID: replaceablePrepRecipeID)
            } else if isInCurrentPrep {
                await removeCurrentRecipeFromPrep()
            } else {
                await addCurrentRecipeToPrep()
            }
        }
    }

    @MainActor
    private func addCurrentRecipeToPrep() async {
        guard let detail else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        let recipe = recipeFromDetail(detail)
        baseServingsCount = max(1, servingsCount)
        toastCenter.show(
            title: "Added to next prep",
            subtitle: titleText,
            systemImage: "wand.and.stars",
            thumbnailURLString: toastPreviewImageURLString(for: detail),
            destination: .appTab(.prep)
        )
        Task {
            await Task.yield()
            await store.updateLatestPlan(with: recipe, servings: servingsCount)
        }
    }

    @MainActor
    private func replaceRecipeInPrep(sourceRecipeID: String) async {
        guard let detail else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        let recipe = recipeFromDetail(detail)
        baseServingsCount = max(1, servingsCount)
        toastCenter.show(
            title: "Prep recipe replaced",
            subtitle: titleText,
            systemImage: "arrow.triangle.2.circlepath",
            thumbnailURLString: toastPreviewImageURLString(for: detail),
            destination: .appTab(.prep)
        )
        Task {
            await store.removeRecipeFromLatestPlan(recipeID: sourceRecipeID)
            await store.updateLatestPlan(with: recipe, servings: servingsCount)
        }
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
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        let recipeToRestore = detail.map(recipeFromDetail)
        let restoreServings = max(1, baseServingsCount)
        toastCenter.show(
            title: "Removed from next prep",
            subtitle: titleText,
            systemImage: "minus.circle.fill",
            destination: nil,
            actionTitle: "Undo",
            action: { [store, toastCenter] in
                guard let recipeToRestore else { return }
                Task {
                    await store.updateLatestPlan(with: recipeToRestore, servings: restoreServings)
                    await MainActor.run {
                        toastCenter.dismiss()
                    }
                }
            }
        )
        Task {
            await Task.yield()
            await store.removeRecipeFromLatestPlan(recipeID: recipeID)
        }
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
            prepMinutes: resolvedRecipeDurationMinutes(from: detail),
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

    private static func ingredientGridSpec(for pageWidth: CGFloat) -> (columns: [GridItem], tileWidth: CGFloat) {
        let count: Int
        let spacing: CGFloat
        if pageWidth < 360 {
            count = 3
            spacing = 12
        } else if pageWidth < 760 {
            count = 4
            spacing = 12
        } else {
            count = 5
            spacing = 14
        }

        let contentWidth = min(pageWidth, 820) - 28
        let tileWidth = max(72, floor((contentWidth - spacing * CGFloat(count - 1)) / CGFloat(count)))
        let columns = Array(repeating: GridItem(.fixed(tileWidth), spacing: spacing, alignment: .top), count: count)
        return (columns, tileWidth)
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

struct RecipeModalTitle: View {
    let text: String
    var isAdapted = false
    @AppStorage("ounje.recipeTypographyStyle") private var recipeTypographyStyleRawValue = RecipeTypographyStyle.defaultStyle.rawValue

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            RecipeTypographyTitleText(
                text,
                size: RecipeTypographyStyle.resolved(from: recipeTypographyStyleRawValue) == .clean ? 40 : 44,
                color: OunjePalette.primaryText,
                style: RecipeTypographyStyle.resolved(from: recipeTypographyStyleRawValue)
            )
                .multilineTextAlignment(.leading)
                .lineSpacing(2)
                .lineLimit(5)
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(1)

            if isAdapted {
                Image(systemName: "sparkles")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(OunjePalette.accent)
                    .accessibilityLabel("Edited recipe")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct RecipeDetailSectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 28, weight: .regular, design: .serif))
            .foregroundStyle(OunjePalette.softCream)
    }
}

struct RecipeDetailHeroImage: View {
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
                RecipeDetailHeroImagePlaceholder()
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

struct RecipeDetailHeroImagePlaceholder: View {
    @State private var shimmerOffset: CGFloat = -1.2
    @State private var pulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Circle()
            .fill(OunjePalette.surface.opacity(0.92))
            .overlay(
                Circle()
                    .stroke(OunjePalette.softCream.opacity(0.12), lineWidth: 1)
            )
            .modifier(LoadingSheen(offset: shimmerOffset))
            .scaleEffect(reduceMotion ? 1 : (pulse ? 1.018 : 0.986))
            .shadow(color: .black.opacity(0.12), radius: 16, y: 7)
            .accessibilityLabel("Loading recipe image")
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                    pulse = true
                }
                withAnimation(.linear(duration: 1.25).repeatForever(autoreverses: false)) {
                    shimmerOffset = 1.35
                }
            }
    }
}

struct RecipeDetailTopIconButton: View {
    let symbolName: String
    var isLoading = false
    let action: () -> Void

    var body: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            action()
        } label: {
            ZStack {
                if isLoading {
                    ProgressView()
                        .tint(OunjePalette.primaryText)
                        .scaleEffect(0.82)
                } else {
                    Image(systemName: symbolName)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(OunjePalette.primaryText)
                }
            }
            .frame(width: 52, height: 52)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(OunjePalette.surface.opacity(0.92))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(OunjePalette.stroke.opacity(0.88), lineWidth: 1)
                    )
                    .shadow(color: Color.black.opacity(0.16), radius: 14, x: 0, y: 8)
            )
            .padding(10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isLoading)
    }
}

struct RecipeDetailTopVideoButton: View {
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

struct FloatingSavedSearchButton: View {
    let isActive: Bool
    let transitionNamespace: Namespace.ID
    let action: () -> Void
    @State private var iconScale: CGFloat = 1

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

        Button {
            withAnimation(.spring(response: 0.16, dampingFraction: 0.72)) {
                iconScale = 0.84
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.11) {
                withAnimation(.spring(response: 0.24, dampingFraction: 0.74)) {
                    iconScale = 1
                }
            }
            action()
        } label: {
            ZStack {
                Capsule(style: .continuous)
                    .fill(baseFill)
                    .matchedGeometryEffect(id: "saved-search-shell", in: transitionNamespace)
                    .background(
                        Capsule(style: .continuous)
                            .fill(.ultraThinMaterial)
                            .opacity(isActive ? 0 : 1)
                    )
                    .overlay(
                        Capsule(style: .continuous)
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
                        Capsule(style: .continuous)
                            .stroke(Color.white.opacity(isActive ? 0.24 : 0.18), lineWidth: 1)
                    )

                Image(systemName: "magnifyingglass")
                    .font(.system(size: 17, weight: .bold))
                    .scaleEffect(iconScale)
                    .foregroundStyle(isActive ? Color.black.opacity(0.88) : OunjePalette.softCream.opacity(0.88))
                    .matchedGeometryEffect(id: "saved-search-icon", in: transitionNamespace)
            }
            .frame(width: 52, height: 52)
            .shadow(color: isActive ? OunjePalette.softCream.opacity(0.16) : .black.opacity(0.16), radius: 10, y: 6)
        }
        .buttonStyle(.plain)
    }
}

struct SavedRecipesSearchField: View {
    @Binding var text: String
    let placeholder: String
    @Binding var isExpanded: Bool
    let transitionNamespace: Namespace.ID
    @FocusState private var isFocused: Bool

    private var hasQuery: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(OunjePalette.softCream.opacity(0.9))
                .matchedGeometryEffect(id: "saved-search-icon", in: transitionNamespace)

            TextField("", text: $text, prompt: Text(placeholder).foregroundColor(OunjePalette.softCream.opacity(0.34)))
                .font(.system(size: 17, weight: .medium, design: .rounded))
                .foregroundStyle(OunjePalette.primaryText)
                .focused($isFocused)

            Spacer(minLength: 0)

            Button {
                if hasQuery {
                    text = ""
                } else {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        isExpanded = false
                    }
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
            ZStack {
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
                    .matchedGeometryEffect(id: "saved-search-shell", in: transitionNamespace)

                Capsule(style: .continuous)
                    .stroke(OunjePalette.stroke.opacity(0.94), lineWidth: 1)
            }
        )
        .shadow(color: Color.black.opacity(0.22), radius: 22, y: 10)
        .onAppear {
            DispatchQueue.main.async {
                isFocused = true
            }
        }
        .onChange(of: isExpanded) { newValue in
            if newValue {
                DispatchQueue.main.async {
                    isFocused = true
                }
            } else {
                isFocused = false
            }
        }
    }
}

struct RecipeInlineVideoCard: View {
    let video: RecipeResolvedVideoData
    let url: URL
    let player: AVPlayer?
    @Binding var webAction: RecipeWebVideoAction
    let onTap: () -> Void
    @State private var showsLoadingOverlay = true

    private var loadingSignature: String {
        "\(video.mode.rawValue)|\(url.absoluteString)"
    }

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

            if showsLoadingOverlay {
                RecipeVideoLoadingOverlay(label: "Loading video")
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
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
        .task(id: loadingSignature) {
            showsLoadingOverlay = true
            if video.supportsNativePlayback, let player {
                for _ in 0..<80 {
                    guard !Task.isCancelled else { return }
                    let itemStatus = player.currentItem?.status
                    if itemStatus == .readyToPlay || itemStatus == .failed || player.timeControlStatus == .playing {
                        break
                    }
                    try? await Task.sleep(nanoseconds: 150_000_000)
                }
            } else {
                try? await Task.sleep(nanoseconds: 900_000_000)
            }
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.18)) {
                showsLoadingOverlay = false
            }
        }
    }
}

struct RecipeVideoLoadingOverlay: View {
    let label: String

    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color.black.opacity(0.62))

            VStack(spacing: 10) {
                ProgressView()
                    .tint(OunjePalette.softCream)
                    .scaleEffect(0.9)

                Text(label)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(OunjePalette.secondaryText)
            }
        }
    }
}

struct RecipeVideoControlButton: View {
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

struct RecipeFullscreenVideoExperience: View {
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

enum RecipeVideoURLResolver {
    static func fallbackVideo(from source: URL) -> RecipeResolvedVideoData {
        let resolvedURL = inAppPlayableURL(from: source)
        let mode: RecipeResolvedVideoData.PlaybackMode = {
            if supportsNativePlayback(resolvedURL ?? source) {
                return .native
            }
            if usesIframeWrapper(source: source) {
                return .iframe
            }
            return .embed
        }()
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

    private static func usesIframeWrapper(source: URL) -> Bool {
        let host = source.host?.lowercased() ?? ""
        return host.contains("tiktok.com") || host.contains("instagram.com")
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
        return URL(string: "https://www.tiktok.com/player/v1/\(videoID)?controls=0&progress_bar=0&play_button=0&volume_control=0&fullscreen_button=0&timestamp=0&description=0&music_info=0&rel=0&native_context_menu=0&closed_caption=0&autoplay=1")
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

struct RecipeInlineWebVideoView: UIViewRepresentable {
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

struct RecipeNativeVideoView: UIViewRepresentable {
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

final class PlayerContainerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }

    var playerLayer: AVPlayerLayer {
        layer as! AVPlayerLayer
    }
}

struct RecipeShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

enum RecipeAlterationIntent: String, CaseIterable, Identifiable {
    case healthier
    case spicy
    case quick
    case moreProtein
    case extraVeggies
    case lessSugar
    case kidFriendly
    case sweeter
    case budgetFriendly
    case mealPrep
    case lighter
    case dairyFree
    case vegetarian
    case keto
    case glutenFree
    case lowCarb
    case saucy
    case crispy

    var id: String { rawValue }

    var intentKey: String {
        switch self {
        case .healthier: return "healthier"
        case .spicy: return "spicy"
        case .quick: return "quick"
        case .moreProtein: return "more_protein"
        case .extraVeggies: return "extra_veggies"
        case .lessSugar: return "less_sugar"
        case .kidFriendly: return "kid_friendly"
        case .sweeter: return "sweeter"
        case .budgetFriendly: return "budget_friendly"
        case .mealPrep: return "meal_prep"
        case .lighter: return "lighter"
        case .dairyFree: return "dairy_free"
        case .vegetarian: return "vegetarian"
        case .keto: return "keto"
        case .glutenFree: return "gluten_free"
        case .lowCarb: return "low_carb"
        case .saucy: return "saucy"
        case .crispy: return "crispy"
        }
    }

    var title: String {
        switch self {
        case .healthier: return "Healthy"
        case .spicy: return "Spicy"
        case .quick: return "Quick"
        case .moreProtein: return "More protein"
        case .extraVeggies: return "Extra veggies"
        case .lessSugar: return "Less sugar"
        case .kidFriendly: return "Kid friendly"
        case .sweeter: return "Sweeter"
        case .budgetFriendly: return "Budget friendly"
        case .mealPrep: return "Meal prep"
        case .lighter: return "Lighter"
        case .dairyFree: return "Dairy-free"
        case .vegetarian: return "Vegetarian"
        case .keto: return "Keto"
        case .glutenFree: return "Gluten-free"
        case .lowCarb: return "Low carb"
        case .saucy: return "Saucy"
        case .crispy: return "Crunchy"
        }
    }

    var displayTitle: String {
        switch self {
        case .healthier: return "Make it healthy"
        case .spicy: return "Make it spicy"
        case .quick: return "Make it quick"
        case .moreProtein: return "More protein"
        case .extraVeggies: return "More veggies"
        case .lessSugar: return "Less sugar"
        case .kidFriendly: return "Kid-friendly"
        case .sweeter: return "Make it sweet"
        case .budgetFriendly: return "Budget-friendly"
        case .mealPrep: return "Make it reheat well"
        case .lighter: return "Make it lighter"
        case .dairyFree: return "Make it dairy-free"
        case .vegetarian: return "Make it vegetarian"
        case .keto: return "Make it keto"
        case .glutenFree: return "Make it gluten-free"
        case .lowCarb: return "Make it low carb"
        case .saucy: return "Make it saucy"
        case .crispy: return "Make it crunchy"
        }
    }

    var pillWidth: CGFloat {
        switch self {
        case .mealPrep, .vegetarian, .dairyFree, .glutenFree:
            return 176
        case .keto:
            return 150
        case .budgetFriendly:
            return 160
        case .kidFriendly, .moreProtein, .extraVeggies, .lessSugar, .lowCarb:
            return 146
        case .healthier, .spicy, .quick, .sweeter, .lighter, .saucy, .crispy:
            return 140
        }
    }

    var subtitle: String {
        switch self {
        case .healthier: return "Fresh, balanced, still satisfying."
        case .spicy: return "More heat, still balanced."
        case .quick: return "Shorter prep, fewer fussy steps."
        case .moreProtein: return "Boost protein without flattening flavor."
        case .extraVeggies: return "Work more produce into the dish."
        case .lessSugar: return "Dial sweetness down cleanly."
        case .kidFriendly: return "Gentler flavors, easy to eat."
        case .sweeter: return "Lean into dessert energy."
        case .budgetFriendly: return "Keep it smart on groceries."
        case .mealPrep: return "Make it hold up for later."
        case .lighter: return "Less heavy, same comfort."
        case .dairyFree: return "Skip dairy without losing body."
        case .vegetarian: return "Plant-forward, not boring."
        case .keto: return "Lower carb, still full."
        case .glutenFree: return "No gluten, still sturdy."
        case .lowCarb: return "Reduce starch where it makes sense."
        case .saucy: return "Add a sauce that fits the dish."
        case .crispy: return "Add crunch and texture."
        }
    }

    var promptSeed: String {
        switch self {
        case .healthier:
            return "Make this healthy while keeping it satisfying and close to the original. Identify the least balanced parts of the recipe, then improve the ingredient list with more produce, fiber, protein, or better fats where they fit. Reduce excess sugar, heavy fat, or refined starch only when it improves the dish, and update quantities plus steps so the new version is fully cookable. Do not turn it into a generic salad, strip out flavor, or only change tags."
        case .spicy:
            return "Make this spicy in a way that fits the recipe. Add a real heat source that belongs with the cuisine or flavor profile, balance it with acid, fat, freshness, or sweetness where needed, and update the steps so the spice is bloomed, cooked, finished, or served correctly. Do not just add hot sauce, make it one-note hot, or leave the spice out of the steps."
        case .quick:
            return "Make this quick for a busy day. Shorten active prep and cook time by simplifying fussy steps, long marinades, slow bakes, or unnecessary components while preserving the core flavor. Update ingredients, quantities, timing, and steps so the faster version still works. Do not only change the time label or remove food-safety steps."
        case .moreProtein:
            return "Make this higher in protein using real food that fits the dish. Add or increase a specific protein source such as eggs, yogurt, tofu, beans, lentils, fish, chicken, turkey, cheese, nuts, or seeds only when it makes culinary sense. Update quantities and every affected cooking step; do not add vague ingredients like 'extra protein' or 'protein boost'."
        case .extraVeggies:
            return "Add more vegetables in a way that feels natural to the recipe. Choose vegetables that match the sauce, spice, texture, and cook time. Adjust seasoning, moisture, and cooking order so the added vegetables do not water the dish down or feel tacked on. Do not add random vegetables or use them only as garnish."
        case .lessSugar:
            return "Make this less sweet. Reduce sugar, syrup, honey, sweetened dairy, sweet sauces, or sugary toppings where present, but keep the recipe balanced and satisfying. Update quantities and any steps that depend on sweetness, glazing, caramelization, browning, sauce thickness, or dessert texture. Do not remove all sweetness when sweetness is structurally needed."
        case .kidFriendly:
            return "Make this kid-friendly without making it bland. Reduce harsh heat or sharp flavors, keep textures easy to eat, use familiar serving formats where helpful, and move intense garnishes or spicy finishes to the side. Update ingredients, quantities, and steps accordingly. Do not make it sugary by default or remove all seasoning."
        case .sweeter:
            return "Make this sweet in a balanced way. Add or increase fruit, honey, maple, chocolate, warm spices, glaze, or dessert-style toppings only where they fit the dish. Update quantities and steps so the sweetness is integrated rather than just added on top. Do not dump sugar into a savory dish or only change the title."
        case .budgetFriendly:
            return "Make this cheaper to cook while keeping it appealing. Swap expensive proteins, specialty cheeses, nuts, oils, or one-off ingredients for practical grocery alternatives. Keep the dish recognizable, avoid adding too many new items, and update quantities plus steps for the substitutions. Do not reduce portion size or remove the satisfying part without replacing it."
        case .mealPrep:
            return "Make this reheat well for meal prep. Adjust ingredients, sauces, and steps so the dish stores cleanly and stays good later. Do not leave delicate greens, crisp toppings, or fragile sauces mixed in if they will get soggy."
        case .lighter:
            return "Make this lighter and less heavy while preserving the dish's comfort and flavor. Reduce excess cream, butter, oil, cheese, fried components, or heavy starch where appropriate, then add freshness, acid, herbs, broth, yogurt, vegetables, or a lighter cooking technique. Update quantities and steps so the lighter version still feels complete. Do not make it bland or watery."
        case .dairyFree:
            return "Make this dairy-free. Remove milk, cream, butter, cheese, yogurt, sour cream, and dairy-based sauces where present. Replace texture, fat, creaminess, or saltiness with realistic dairy-free ingredients, then update quantities and steps so the recipe still cooks properly. Do not leave dairy in ingredients or steps, and do not use unnamed substitutes."
        case .vegetarian:
            return "Make this vegetarian. Remove meat, seafood, gelatin, meat stock, and fish sauce; add a satisfying plant-forward protein or base; update quantities, steps, and tags. Do not simply remove the protein or leave animal ingredients in the method."
        case .keto:
            return "Make this keto-friendly. Keep the dish satisfying while sharply reducing high-carb ingredients like bread, pasta, rice, potatoes, flour, sugar, syrup, and sweet sauces. Replace the structure with practical keto-friendly ingredients such as eggs, cheese, avocado, leafy vegetables, cauliflower, nuts, seeds, meat, fish, or tofu where they fit. Update quantities, steps, timing, tags, and serving format. Do not only rename it keto, and do not leave a high-carb base unchanged."
        case .glutenFree:
            return "Make this gluten-free. Remove wheat flour, bread, pasta, breadcrumbs, tortillas, soy sauce with wheat, and other gluten-containing ingredients where present. Replace structure or seasoning with practical gluten-free alternatives such as rice, corn tortillas, gluten-free pasta, tamari, potatoes, oats labeled gluten-free, or naturally gluten-free starches where they fit. Update quantities and every affected cooking step. Do not leave gluten-containing ingredients in the ingredients or method."
        case .lowCarb:
            return "Make this lower carb by reducing starch thoughtfully without turning it into a different dish. Replace or reduce bread, pasta, rice, tortillas, potatoes, flour, or sugary components only where it makes culinary sense, then update serving format, quantities, and steps. Do not delete the main base without a practical replacement."
        case .saucy:
            return "Make this saucier with a practical sauce, glaze, dressing, or pan sauce that fits the dish. Update quantities and steps so the sauce is cooked, mixed, or served correctly. Do not just say serve with sauce or make the recipe watery."
        case .crispy:
            return "Make this crunchier with better texture contrast while keeping the original dish recognizable. Add or improve crisp texture through technique or ingredients such as toasted nuts, seeds, panko, roasted edges, fried shallots, crisp vegetables, or a high-heat finish. Update steps with the exact timing so the crunch stays crisp. Do not add a topping that will get soggy without timing instructions."
        }
    }

    var systemImageName: String {
        switch self {
        case .healthier: return "leaf.fill"
        case .spicy: return "flame.fill"
        case .quick: return "timer"
        case .moreProtein: return "dumbbell.fill"
        case .extraVeggies: return "carrot.fill"
        case .lessSugar: return "birthday.cake.fill"
        case .kidFriendly: return "person.2.fill"
        case .sweeter: return "drop.fill"
        case .budgetFriendly: return "dollarsign.circle.fill"
        case .mealPrep: return "takeoutbag.and.cup.and.straw.fill"
        case .lighter: return "wind"
        case .dairyFree: return "drop.fill"
        case .vegetarian: return "leaf.circle.fill"
        case .keto: return "chart.pie.fill"
        case .glutenFree: return "checkmark.seal.fill"
        case .lowCarb: return "chart.line.downtrend.xyaxis"
        case .saucy: return "drop.circle.fill"
        case .crispy: return "circle.grid.cross.fill"
        }
    }

    var iconColor: Color {
        switch self {
        case .healthier:
            return Color(hex: "6DDF7B")
        case .spicy:
            return Color(hex: "FF6B4A")
        case .quick:
            return Color(hex: "FFD05A")
        case .moreProtein:
            return Color(hex: "E89B62")
        case .extraVeggies, .vegetarian:
            return Color(hex: "7ED957")
        case .lessSugar:
            return Color(hex: "FFB86B")
        case .lighter:
            return Color(hex: "8FD6FF")
        case .kidFriendly:
            return Color(hex: "FF8BCB")
        case .sweeter:
            return Color(hex: "DDAA45")
        case .budgetFriendly:
            return Color(hex: "5DDC8B")
        case .mealPrep:
            return Color(hex: "B8A27A")
        case .dairyFree:
            return Color(hex: "A7D8FF")
        case .keto:
            return Color(hex: "C7E27A")
        case .glutenFree:
            return Color(hex: "F1D67A")
        case .lowCarb:
            return Color(hex: "FFB35C")
        case .saucy:
            return Color(hex: "D9A16E")
        case .crispy:
            return Color(hex: "F4C95D")
        }
    }

    static var inspirationPages: [[RecipeAlterationIntent]] {
        let intents = RecipeAlterationIntent.allCases
        return stride(from: 0, to: intents.count, by: 3).map { start in
            Array(intents[start..<min(start + 3, intents.count)])
        }
    }

    static func recommendations(for recipeKind: String?, title: String) -> [RecipeAlterationIntent] {
        let descriptor = [recipeKind, title]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")

        let primary: [RecipeAlterationIntent]
        if descriptor.contains("dessert")
            || descriptor.contains("cookie")
            || descriptor.contains("cake")
            || descriptor.contains("brownie")
            || descriptor.contains("pie")
            || descriptor.contains("pastry")
            || descriptor.contains("banana bread")
            || descriptor.contains("sweet") {
            primary = [
                .lessSugar,
                .healthier,
                .crispy,
                .sweeter,
                .quick,
                .dairyFree,
                .glutenFree,
                .keto,
                .kidFriendly,
                .lighter,
                .saucy,
                .budgetFriendly,
                .lowCarb,
                .mealPrep,
                .moreProtein,
                .vegetarian,
                .extraVeggies,
                .spicy,
            ]
        } else if descriptor.contains("breakfast")
                    || descriptor.contains("brunch")
                    || descriptor.contains("oat")
                    || descriptor.contains("pancake")
                    || descriptor.contains("toast") {
            primary = [
                .quick,
                .moreProtein,
                .healthier,
                .keto,
                .glutenFree,
                .lighter,
                .lessSugar,
                .crispy,
                .mealPrep,
                .saucy,
                .extraVeggies,
                .dairyFree,
                .sweeter,
                .budgetFriendly,
                .kidFriendly,
                .lowCarb,
                .vegetarian,
                .spicy,
            ]
        } else if descriptor.contains("lunch")
                    || descriptor.contains("sandwich")
                    || descriptor.contains("wrap")
                    || descriptor.contains("salad")
                    || descriptor.contains("bowl") {
            primary = [
                .moreProtein,
                .spicy,
                .extraVeggies,
                .keto,
                .dairyFree,
                .vegetarian,
                .glutenFree,
                .saucy,
                .quick,
                .mealPrep,
                .budgetFriendly,
                .lighter,
                .lowCarb,
                .crispy,
                .kidFriendly,
                .healthier,
                .lessSugar,
                .sweeter,
            ]
        } else {
            primary = [
                .moreProtein,
                .spicy,
                .extraVeggies,
                .keto,
                .dairyFree,
                .vegetarian,
                .glutenFree,
                .saucy,
                .quick,
                .mealPrep,
                .budgetFriendly,
                .lighter,
                .crispy,
                .lowCarb,
                .kidFriendly,
                .healthier,
                .lessSugar,
                .sweeter,
            ]
        }

        var seen: Set<RecipeAlterationIntent> = []
        return (primary + RecipeAlterationIntent.allCases).filter { intent in
            if seen.contains(intent) { return false }
            seen.insert(intent)
            return true
        }
    }
}

struct RecipeAdaptationResponse: Decodable {
    let adaptedRecipe: RecipeAdaptationRecipe
    let recipeID: String?
    let adaptedFromRecipeID: String?
    let recipeCard: DiscoverRecipeCardData
    let recipeDetail: RecipeDetailData
    let changeSummary: String?
    let editSummary: RecipeAdaptationEditSummary?
    let pairingTerms: [String]
    let styleExamplesUsed: [String]
    let modelMode: String
    let model: String
    let validationStatus: String?

    enum CodingKeys: String, CodingKey {
        case adaptedRecipe = "adapted_recipe"
        case recipeID = "recipe_id"
        case adaptedFromRecipeID = "adapted_from_recipe_id"
        case recipeCard = "recipe_card"
        case recipeDetail = "recipe_detail"
        case changeSummary = "change_summary"
        case editSummary = "edit_summary"
        case pairingTerms = "pairing_terms"
        case styleExamplesUsed = "style_examples_used"
        case modelMode = "model_mode"
        case model
        case validationStatus = "validation_status"
    }

    var historyID: String {
        recipeID ?? recipeDetail.id
    }
}

struct RecipeAdaptationEditSummary: Decodable {
    let changedIngredients: [String]
    let changedQuantities: [String]
    let changedSteps: [String]
    let addedIngredients: [String]?
    let removedIngredients: [String]?
    let validationNotes: [String]?

    enum CodingKeys: String, CodingKey {
        case changedIngredients = "changed_ingredients"
        case changedQuantities = "changed_quantities"
        case changedSteps = "changed_steps"
        case addedIngredients = "added_ingredients"
        case removedIngredients = "removed_ingredients"
        case validationNotes = "validation_notes"
    }
}

struct RecipeAdaptationRecipe: Decodable, Identifiable {
    let title: String
    let summary: String
    let cookTimeText: String
    let ingredients: [String]
    let steps: [String]
    let substitutions: [String]
    let pairingNotes: [String]
    let dietaryFit: [String]

    var id: String { title }

    init(
        title: String,
        summary: String,
        cookTimeText: String,
        ingredients: [String],
        steps: [String],
        substitutions: [String],
        pairingNotes: [String],
        dietaryFit: [String]
    ) {
        self.title = title
        self.summary = summary
        self.cookTimeText = cookTimeText
        self.ingredients = ingredients
        self.steps = steps
        self.substitutions = substitutions
        self.pairingNotes = pairingNotes
        self.dietaryFit = dietaryFit
    }

    enum CodingKeys: String, CodingKey {
        case title
        case summary
        case cookTimeText = "cook_time_text"
        case ingredients
        case steps
        case substitutions
        case pairingNotes = "pairing_notes"
        case dietaryFit = "dietary_fit"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decode(String.self, forKey: .title)
        summary = try container.decode(String.self, forKey: .summary)
        cookTimeText = try container.decode(String.self, forKey: .cookTimeText)
        if let stringIngredients = try? container.decode([String].self, forKey: .ingredients) {
            ingredients = stringIngredients
        } else {
            let structuredIngredients = (try? container.decode([RecipeAdaptationIngredientPayload].self, forKey: .ingredients)) ?? []
            ingredients = structuredIngredients.map(\.lineText)
        }
        steps = try container.decode([String].self, forKey: .steps)
        substitutions = try container.decode([String].self, forKey: .substitutions)
        pairingNotes = try container.decode([String].self, forKey: .pairingNotes)
        dietaryFit = try container.decode([String].self, forKey: .dietaryFit)
    }
}

private struct RecipeAdaptationIngredientPayload: Decodable {
    let displayName: String
    let quantityText: String?

    enum CodingKeys: String, CodingKey {
        case displayName = "display_name"
        case quantityText = "quantity_text"
    }

    var lineText: String {
        [quantityText, displayName]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

struct RecipeAdaptationRequestPayload: Codable {
    let recipeID: String
    let userID: String
    let adaptationPrompt: String
    let intentKey: String?
    let intentLabel: String?
    let rerollNonce: String
    let strictEditValidation: Bool
    let profile: UserProfile?

    enum CodingKeys: String, CodingKey {
        case recipeID = "recipe_id"
        case userID = "user_id"
        case adaptationPrompt = "adaptation_prompt"
        case intentKey = "intent_key"
        case intentLabel = "intent_label"
        case rerollNonce = "reroll_nonce"
        case strictEditValidation = "strict_edit_validation"
        case profile
    }
}

struct RecipeAdaptationHistoryResponse: Decodable {
    let history: [RecipeAdaptationResponse]
}

actor RecipeAdaptationService {
    static let shared = RecipeAdaptationService()

    private var historyCache: [String: [RecipeAdaptationResponse]] = [:]

    func history(recipeID: String, userID: String?, limit: Int = 8, accessToken: String? = nil) async throws -> [RecipeAdaptationResponse] {
        let normalizedRecipeID = recipeID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedUserID = userID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !normalizedRecipeID.isEmpty, !normalizedUserID.isEmpty else {
            return []
        }

        let cacheKey = "\(normalizedUserID.lowercased())::\(normalizedRecipeID.lowercased())::history"
        if let cached = historyCache[cacheKey], !cached.isEmpty {
            return cached
        }

        var lastError: Error?
        for baseURL in OunjeDevelopmentServer.candidateBaseURLs {
            do {
                let history = try await history(baseURL: baseURL, recipeID: normalizedRecipeID, userID: normalizedUserID, limit: limit, accessToken: accessToken)
                historyCache[cacheKey] = history
                return history
            } catch {
                lastError = error
            }
        }

        throw lastError ?? SupabaseProfileStateError.invalidResponse
    }

    func latestHistory(recipeID: String, userID: String?, accessToken: String? = nil) async throws -> RecipeAdaptationResponse? {
        try await history(recipeID: recipeID, userID: userID, limit: 1, accessToken: accessToken).first
    }

    func adapt(recipeID: String, userID: String?, prompt: String, intent: RecipeAlterationIntent?, profile: UserProfile?, accessToken: String? = nil) async throws -> RecipeAdaptationResponse {
        let normalizedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedUserID = userID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !recipeID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !normalizedUserID.isEmpty,
              !normalizedPrompt.isEmpty else {
            throw SupabaseProfileStateError.invalidRequest
        }

        var lastError: Error?
        for baseURL in OunjeDevelopmentServer.candidateBaseURLs {
            do {
                let adapted = try await adapt(
                    baseURL: baseURL,
                    recipeID: recipeID,
                    userID: normalizedUserID,
                    prompt: normalizedPrompt,
                    intent: intent,
                    profile: profile,
                    accessToken: accessToken
                )
                let historyKey = "\(normalizedUserID.lowercased())::\(recipeID.lowercased())::history"
                let cached = historyCache[historyKey] ?? []
                historyCache[historyKey] = Self.prepending(adapted, to: cached)
                return adapted
            } catch {
                lastError = error
            }
        }

        throw lastError ?? SupabaseProfileStateError.invalidResponse
    }

    private func adapt(baseURL: String, recipeID: String, userID: String, prompt: String, intent: RecipeAlterationIntent?, profile: UserProfile?, accessToken: String? = nil) async throws -> RecipeAdaptationResponse {
        guard let url = URL(string: "\(baseURL)/v1/recipe/adapt") else {
            throw SupabaseProfileStateError.invalidRequest
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let accessToken = accessToken?.trimmingCharacters(in: .whitespacesAndNewlines), !accessToken.isEmpty {
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONEncoder().encode(
            RecipeAdaptationRequestPayload(
                recipeID: recipeID,
                userID: userID,
                adaptationPrompt: prompt,
                intentKey: intent?.intentKey,
                intentLabel: intent?.displayTitle,
                rerollNonce: UUID().uuidString,
                strictEditValidation: false,
                profile: profile
            )
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SupabaseProfileStateError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let errorPayload = try? JSONDecoder().decode(SupabaseRestErrorResponse.self, from: data)
            let fallback = "Failed to adapt recipe (\(httpResponse.statusCode))."
            throw SupabaseProfileStateError.requestFailed(errorPayload?.message ?? errorPayload?.error ?? fallback)
        }

        return try JSONDecoder().decode(RecipeAdaptationResponse.self, from: data)
    }

    private func history(baseURL: String, recipeID: String, userID: String, limit: Int, accessToken: String? = nil) async throws -> [RecipeAdaptationResponse] {
        var components = URLComponents(string: "\(baseURL)/v1/recipe/adapt/history")
        components?.queryItems = [
            URLQueryItem(name: "recipe_id", value: recipeID),
            URLQueryItem(name: "user_id", value: userID),
            URLQueryItem(name: "limit", value: String(max(1, min(limit, 20)))),
        ]
        guard let url = components?.url else {
            throw SupabaseProfileStateError.invalidRequest
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        if let accessToken = accessToken?.trimmingCharacters(in: .whitespacesAndNewlines), !accessToken.isEmpty {
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SupabaseProfileStateError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let errorPayload = try? JSONDecoder().decode(SupabaseRestErrorResponse.self, from: data)
            let fallback = "Failed to load recipe ask history (\(httpResponse.statusCode))."
            throw SupabaseProfileStateError.requestFailed(errorPayload?.message ?? errorPayload?.error ?? fallback)
        }

        let decoded = try JSONDecoder().decode(RecipeAdaptationHistoryResponse.self, from: data)
        return decoded.history
    }

    private static func prepending(_ response: RecipeAdaptationResponse, to history: [RecipeAdaptationResponse]) -> [RecipeAdaptationResponse] {
        ([response] + history.filter { $0.historyID != response.historyID })
            .prefix(8)
            .map { $0 }
    }
}

@MainActor
final class RecipeAdaptationViewModel: ObservableObject {
    @Published private(set) var result: RecipeAdaptationResponse?
    @Published private(set) var history: [RecipeAdaptationResponse] = []
    @Published private(set) var isGenerating = false
    @Published private(set) var isLoadingHistory = false
    @Published var errorMessage: String?

    func clearResult() {
        result = nil
        history = []
        errorMessage = nil
    }

    func loadHistory(recipeID: String, userID: String?, accessToken: String? = nil) async {
        guard history.isEmpty, !isGenerating, !isLoadingHistory else { return }
        isLoadingHistory = true
        defer { isLoadingHistory = false }

        do {
            let loadedHistory = try await RecipeAdaptationService.shared.history(recipeID: recipeID, userID: userID, limit: 8, accessToken: accessToken)
            history = loadedHistory
            result = loadedHistory.first
        } catch {
            // History is best-effort; the Ask sheet should still be usable when it misses.
        }
    }

    @discardableResult
    func adapt(recipeID: String, userID: String?, prompt: String, intent: RecipeAlterationIntent?, profile: UserProfile?, accessToken: String? = nil) async -> RecipeAdaptationResponse? {
        isGenerating = true
        errorMessage = nil
        defer { isGenerating = false }

        do {
            let adapted = try await RecipeAdaptationService.shared.adapt(recipeID: recipeID, userID: userID, prompt: prompt, intent: intent, profile: profile, accessToken: accessToken)
            history = ([adapted] + history.filter { $0.historyID != adapted.historyID })
                .prefix(8)
                .map { $0 }
            result = adapted
            return adapted
        } catch let error as URLError where error.code == .timedOut {
            errorMessage = "Recipe rewrite took too long. Try again."
            return nil
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }
}

struct RecipeAskSheet: View {
    let recipeTitle: String
    let recipeSubtitle: String?
    let recipeKind: String?
    let recipeID: String
    let baseImageURL: URL?
    let userID: String?
    let profile: UserProfile?
    let onOpenCart: () -> Void
    let toastCenter: AppToastCenter
    let onOpenToastDestination: ((AppToastDestination) -> Void)?
    let mode: RecipeAskMode

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var savedStore: SavedRecipesStore
    @EnvironmentObject private var store: MealPlanningAppStore
    @StateObject private var viewModel = RecipeAdaptationViewModel()
    @State private var selectedIntent: RecipeAlterationIntent?
    @State private var presentedAdaptedRecipe: PresentedRecipeDetail?
    @State private var isAddingAdaptedRecipeToPrep = false
    @State private var onboardingResult: RecipeAdaptationResponse?
    @State private var isOnboardingGenerating = false

    private var accessToken: String? {
        store.authSession?.accessToken ?? store.resolvedTrackingSession?.accessToken
    }

    private var canGenerate: Bool {
        switch mode {
        case .live:
            return !(userID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
                && !viewModel.isGenerating
        case .onboarding:
            return !isOnboardingGenerating
        }
    }

    private var isGenerating: Bool {
        switch mode {
        case .live:
            return viewModel.isGenerating
        case .onboarding:
            return isOnboardingGenerating
        }
    }

    private var onboardingConfig: RecipeAskOnboardingConfig? {
        guard case let .onboarding(config) = mode else { return nil }
        return config
    }

    private var isLiveMode: Bool {
        if case .live = mode {
            return true
        }
        return false
    }

    private var onboardingFixtures: [OnboardingRecipeEditDemoOptionFixture] {
        guard let onboardingConfig else { return [] }
        return onboardingConfig.demoRecipe.resolvedOptionFixtures(
            selectedDietaryPatterns: onboardingConfig.selectedDietaryPatterns
        )
    }

    private var selectedOnboardingFixture: OnboardingRecipeEditDemoOptionFixture? {
        guard let selectedIntent else { return nil }
        return onboardingFixtures.first { $0.intent == selectedIntent }
    }

    private var displayedResults: [RecipeAdaptationResponse] {
        switch mode {
        case .live:
            return viewModel.history
        case .onboarding:
            return onboardingResult.map { [$0] } ?? []
        }
    }

    private func submit(_ intent: RecipeAlterationIntent) {
        guard canGenerate else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        selectedIntent = intent
        switch mode {
        case .live:
            Task {
                let session = await store.freshUserDataSession()
                await viewModel.adapt(
                    recipeID: recipeID,
                    userID: session?.userID ?? userID,
                    prompt: intent.promptSeed,
                    intent: intent,
                    profile: profile,
                    accessToken: session?.accessToken ?? accessToken
                )
            }
        case let .onboarding(config):
            guard let fixture = onboardingFixtures.first(where: { $0.intent == intent }) else { return }
            onboardingResult = nil
            isOnboardingGenerating = true

            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_300_000_000)
                guard !Task.isCancelled else { return }
                onboardingResult = fixture.makeResponse(from: config.demoRecipe)
                isOnboardingGenerating = false
            }
        }
    }

    private func openAdaptedRecipePreview(_ result: RecipeAdaptationResponse) {
        presentedAdaptedRecipe = PresentedRecipeDetail(
            recipeCard: result.recipeCard,
            initialDetail: result.recipeDetail,
            adaptedFromRecipeID: result.adaptedFromRecipeID ?? recipeID
        )
    }

    private func clearConversation() {
        selectedIntent = nil
        switch mode {
        case .live:
            viewModel.clearResult()
        case .onboarding:
            onboardingResult = nil
        }
    }

    private func completeOnboardingRecipeFlow(_ config: RecipeAskOnboardingConfig) {
        presentedAdaptedRecipe = nil
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 120_000_000)
            dismiss()
            try? await Task.sleep(nanoseconds: 120_000_000)
            config.onComplete()
        }
    }

    private func addAdaptedRecipeToPrep(_ result: RecipeAdaptationResponse) {
        guard !isAddingAdaptedRecipeToPrep else { return }
        isAddingAdaptedRecipeToPrep = true

        Task { @MainActor in
            defer { isAddingAdaptedRecipeToPrep = false }

            let detail = result.recipeDetail
            let servings = max(1, detail.displayServings)
            let adaptedRecipe = recipePlanModel(
                from: detail,
                targetServings: servings,
                fallbackRecipe: nil
            )
            let sourceRecipeID = (result.adaptedFromRecipeID ?? recipeID)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let shouldReplaceOriginal = !sourceRecipeID.isEmpty
                && sourceRecipeID != adaptedRecipe.id
                && (store.latestPlan?.recipes.contains { $0.recipe.id == sourceRecipeID } == true)

            if shouldReplaceOriginal {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                await store.removeRecipeFromLatestPlan(recipeID: sourceRecipeID)
            }

            await store.updateLatestPlan(with: adaptedRecipe, servings: servings)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            toastCenter.show(
                title: shouldReplaceOriginal ? "Prep recipe replaced" : "Added to prep",
                subtitle: detail.title,
                systemImage: shouldReplaceOriginal ? "arrow.triangle.2.circlepath" : "plus.circle.fill",
                thumbnailURLString: detail.discoverCardImageURLString ?? detail.heroImageURLString ?? detail.imageURL?.absoluteString,
                destination: .appTab(.prep)
            )
        }
    }

    var body: some View {
        ZStack {
            OunjePalette.background.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 18) {
                ZStack {
                    Capsule()
                        .fill(OunjePalette.elevated)
                        .frame(width: 88, height: 6)

                    HStack {
                        Spacer()
                        Button(action: dismiss.callAsFunction) {
                            Image(systemName: "xmark")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(OunjePalette.primaryText)
                                .frame(width: 42, height: 42)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Close")
                    }
                }
                .padding(.top, 6)

                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .center) {
                        SleeScriptDisplayText("Ask Ounje", size: 30, color: OunjePalette.primaryText)

                        if isLiveMode {
                            Spacer(minLength: 12)

                            Button {
                                clearConversation()
                            } label: {
                                Text("Clear chat")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(OunjePalette.primaryText.opacity(0.88))
                                    .padding(.horizontal, 15)
                                    .frame(height: 38)
                                    .background(
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .fill(OunjePalette.surface.opacity(0.88))
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .stroke(OunjePalette.stroke.opacity(0.85), lineWidth: 1)
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    (
                        Text("Bonjour.")
                            .fontWeight(.bold)
                        + Text(isLiveMode
                            ? " Did you have a special request about this "
                            : " Pick one of these guided edits for this "
                        )
                        + Text(recipeTitle)
                            .underline(true, color: OunjePalette.primaryText.opacity(0.86))
                        + Text(isLiveMode
                            ? " recipe? I can modify it based on your dietary restrictions, taste preferences and more. Just ask!"
                            : " recipe? Choose a direction and Ounje will show you how it changes."
                        )
                    )
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(OunjePalette.primaryText)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
                }

                if isGenerating {
                    RecipeAskGeneratingPanel(
                        message: isLiveMode
                            ? "Great! Give me a few seconds while I prepare a different recipe for you."
                            : "Great. Give me a couple seconds while I upgrade the recipe.",
                        supportingText: nil
                    )
                        .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
                }

                if !displayedResults.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        if isLiveMode && displayedResults.count > 1 {
                            Text("Recent rewrites")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(OunjePalette.secondaryText)
                        }

                        ForEach(displayedResults, id: \.historyID) { result in
                            if isLiveMode {
                                RecipeAskInlineResultPanel(
                                    result: result,
                                    baseImageURL: baseImageURL,
                                    isSaved: savedStore.isSaved(result.recipeCard),
                                    isAddingToPrep: isAddingAdaptedRecipeToPrep,
                                    onAskAgain: {
                                        clearConversation()
                                    },
                                    onSave: {
                                        if !savedStore.isSaved(result.recipeCard) {
                                            savedStore.toggle(result.recipeCard)
                                        }
                                    },
                                    onOpenPreview: {
                                        openAdaptedRecipePreview(result)
                                    },
                                    onAddToPrep: {
                                        addAdaptedRecipeToPrep(result)
                                    }
                                )
                            } else {
                                OnboardingRecipeAskInlineResultPanel(
                                    result: result,
                                    baseImageURL: baseImageURL,
                                    isSaved: savedStore.isSaved(result.recipeCard),
                                    summary: selectedOnboardingFixture?.oneLineChangeSummary ?? result.changeSummary,
                                    onSave: {
                                        if !savedStore.isSaved(result.recipeCard) {
                                            saveOnboardingAdaptedRecipe(result)
                                        }
                                    },
                                    onOpenPreview: {
                                        openAdaptedRecipePreview(result)
                                    }
                                )
                            }
                        }
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
                }

                if let errorMessage = viewModel.errorMessage, isLiveMode {
                    Text(errorMessage)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.red.opacity(0.9))
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)

                if isLiveMode {
                    RecipeInspirationSwiper(
                        selectedIntent: selectedIntent,
                        isGenerating: isGenerating,
                        canGenerate: canGenerate,
                        recipeKind: recipeKind,
                        recipeTitle: recipeTitle,
                        onSelect: submit
                    )
                } else {
                    OnboardingRecipeInspirationList(
                        fixtures: onboardingFixtures,
                        selectedIntent: selectedIntent,
                        isGenerating: isGenerating,
                        onSelect: submit
                    )
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 100)
        }
        .task(id: "\(userID ?? "")::\(recipeID)") {
            guard isLiveMode else { return }
            let session = await store.freshUserDataSession()
            await viewModel.loadHistory(
                recipeID: recipeID,
                userID: session?.userID ?? userID,
                accessToken: session?.accessToken ?? accessToken
            )
        }
        .fullScreenCover(item: $presentedAdaptedRecipe) { recipe in
            RecipeDetailExperienceView(
                presentedRecipe: recipe,
                onOpenCart: onOpenCart,
                toastCenter: toastCenter,
                onOpenToastDestination: onOpenToastDestination,
                onboardingContext: onboardingConfig.map { config in
                    .adaptedDemo(onContinue: {
                        completeOnboardingRecipeFlow(config)
                    })
                }
            )
            .environmentObject(savedStore)
            .environmentObject(store)
        }
    }

    private func saveOnboardingAdaptedRecipe(_ result: RecipeAdaptationResponse) {
        savedStore.saveImportedRecipe(result.recipeCard, showToast: false)
        toastCenter.show(
            title: "Your first of many.",
            subtitle: result.recipeCard.title,
            systemImage: "bookmark.fill",
            thumbnailURLString: result.recipeCard.imageURLString ?? result.recipeCard.heroImageURLString,
            destination: .recipe(result.recipeCard)
        )
    }
}

struct RecipeAskGeneratingPanel: View {
    var message = "Great! Give me a few seconds while I prepare a different recipe for you."
    var supportingText: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(message)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(OunjePalette.primaryText)
                .fixedSize(horizontal: false, vertical: true)

            if let supportingText,
               !supportingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(supportingText)
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(OunjePalette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ProgressView()
                .progressViewStyle(.circular)
                .tint(OunjePalette.primaryText.opacity(0.72))
                .scaleEffect(1.08)
        }
        .padding(.top, 6)
    }
}

struct OnboardingRecipePlanSummaryCard: View {
    let summary: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Planned changes")
                .font(.system(size: 12, weight: .black, design: .rounded))
                .foregroundStyle(OunjePalette.secondaryText)

            Text(summary)
                .font(.system(size: 14.5, weight: .medium))
                .foregroundStyle(OunjePalette.primaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(OunjePalette.surface.opacity(0.92))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(OunjePalette.stroke.opacity(0.85), lineWidth: 1)
                )
        )
    }
}

struct RecipeAskInlineResultPanel: View {
    let result: RecipeAdaptationResponse
    let baseImageURL: URL?
    let isSaved: Bool
    let isAddingToPrep: Bool
    let onAskAgain: () -> Void
    let onSave: () -> Void
    let onOpenPreview: () -> Void
    let onAddToPrep: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            RecipeAdaptedPreviewCard(result: result, baseImageURL: baseImageURL, onOpen: onOpenPreview)

            HStack(spacing: 8) {
                Button(action: onAskAgain) {
                    Text("Try again")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(OunjePalette.primaryText)
                        .frame(maxWidth: .infinity)
                        .frame(height: 38)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(OunjePalette.surface.opacity(0.94))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(OunjePalette.stroke.opacity(0.84), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)

                Button(action: onSave) {
                    HStack(spacing: 6) {
                        Image(systemName: isSaved ? "bookmark.fill" : "bookmark")
                            .font(.system(size: 12, weight: .semibold))
                        Text(isSaved ? "Saved" : "Save")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(OunjePalette.primaryText.opacity(isSaved ? 0.72 : 1))
                    .frame(maxWidth: .infinity)
                    .frame(height: 38)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(OunjePalette.surface.opacity(0.94))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(OunjePalette.stroke.opacity(0.84), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .disabled(isSaved)

                Button(action: onAddToPrep) {
                    Text(isAddingToPrep ? "Adding" : "Add")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(OunjePalette.primaryText)
                        .frame(maxWidth: .infinity)
                        .frame(height: 38)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
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
                .disabled(isAddingToPrep)
                .opacity(isAddingToPrep ? 0.72 : 1)
            }
        }
        .padding(.top, 6)
    }
}

struct OnboardingRecipeAskInlineResultPanel: View {
    let result: RecipeAdaptationResponse
    let baseImageURL: URL?
    let isSaved: Bool
    let summary: String?
    let onSave: () -> Void
    let onOpenPreview: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let summary, !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                (
                    Text("Great, here is the new recipe: ")
                        .fontWeight(.bold)
                    + Text(summary)
                )
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(OunjePalette.primaryText)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
            }

            RecipeAdaptedPreviewCard(
                result: result,
                baseImageURL: baseImageURL,
                showsOnboardingCue: true,
                onOpen: onOpenPreview
            )

            Button(action: onSave) {
                HStack(spacing: 8) {
                    Image(systemName: isSaved ? "bookmark.fill" : "bookmark")
                        .font(.system(size: 13, weight: .semibold))

                    Text(isSaved ? "Saved" : "Save this recipe")
                        .font(.system(size: 14, weight: .semibold))
                }
                .foregroundStyle(OunjePalette.primaryText.opacity(isSaved ? 0.72 : 1))
                .frame(maxWidth: .infinity)
                .frame(height: 42)
                .background(
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .fill(OunjePalette.surface.opacity(0.94))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .stroke(OunjePalette.stroke.opacity(0.84), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .disabled(isSaved)
        }
        .padding(.top, 6)
    }
}

struct RecipeInspirationSwiper: View {
    let selectedIntent: RecipeAlterationIntent?
    let isGenerating: Bool
    let canGenerate: Bool
    let recipeKind: String?
    let recipeTitle: String
    let onSelect: (RecipeAlterationIntent) -> Void

    private var intents: [RecipeAlterationIntent] {
        RecipeAlterationIntent.recommendations(for: recipeKind, title: recipeTitle)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Need some inspiration? Try these")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(OunjePalette.primaryText)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 9) {
                    ForEach(intents) { intent in
                        Button {
                            onSelect(intent)
                        } label: {
                            RecipeAdaptationIntentPill(
                                intent: intent,
                                isSelected: selectedIntent == intent,
                                isDisabled: isGenerating || !canGenerate
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(isGenerating || !canGenerate)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.trailing, 20)
            }
            .padding(.horizontal, -20)
            .frame(height: 46)
        }
    }
}

struct OnboardingRecipeInspirationList: View {
    let fixtures: [OnboardingRecipeEditDemoOptionFixture]
    let selectedIntent: RecipeAlterationIntent?
    let isGenerating: Bool
    let onSelect: (RecipeAlterationIntent) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Need some inspiration? Try these")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(OunjePalette.primaryText)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 9) {
                    ForEach(fixtures) { fixture in
                        Button {
                            onSelect(fixture.intent)
                        } label: {
                            RecipeAdaptationIntentPill(
                                intent: fixture.intent,
                                isSelected: selectedIntent == fixture.intent,
                                isDisabled: isGenerating
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(isGenerating)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.trailing, 20)
            }
            .overlay(alignment: .topLeading) {
                if selectedIntent == nil && !isGenerating {
                    OnboardingInspirationCueView()
                }
            }
            .padding(.horizontal, -20)
            .frame(height: 46)
        }
    }
}

struct RecipeAdaptationIntentPill: View {
    let intent: RecipeAlterationIntent
    let isSelected: Bool
    let isDisabled: Bool

    var body: some View {
        HStack(spacing: 7) {
            Text(intent.displayTitle)
                .font(.system(size: 13.2, weight: .semibold))
                .foregroundStyle(OunjePalette.primaryText)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)

            Image(systemName: intent.systemImageName)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(intent.iconColor)
                .symbolRenderingMode(.hierarchical)
        }
            .padding(.horizontal, 12)
            .frame(height: 44, alignment: .center)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(isSelected ? OunjePalette.accent.opacity(0.12) : OunjePalette.surface.opacity(0.88))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(
                        isSelected ? OunjePalette.accent.opacity(0.86) : Color.white.opacity(0.32),
                        lineWidth: isSelected ? 1.25 : 1
                    )
            )
            .scaleEffect(isSelected ? 1.01 : 1)
            .opacity(isDisabled && !isSelected ? 0.58 : 1)
            .animation(OunjeMotion.quickSpring, value: isSelected)
            .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
    }
}

struct RecipeAdaptationResultSheet: View {
    let recipeTitle: String
    let recipeSubtitle: String?
    let result: RecipeAdaptationResponse
    let isGenerating: Bool
    let onAskAgain: () -> Void
    let isSaved: Bool
    let onSave: () -> Void
    let onOpenPreview: () -> Void
    let onAddToPrep: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Capsule()
                .fill(OunjePalette.elevated)
                .frame(width: 88, height: 6)
                .frame(maxWidth: .infinity)
                .padding(.top, 8)

            VStack(alignment: .leading, spacing: 14) {
                SleeScriptDisplayText("Recipe rewrite.", size: 28, color: OunjePalette.primaryText)
                Text("Great. Ounje made a new version while keeping the dish grounded.")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(OunjePalette.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            RecipeAdaptedPreviewCard(result: result, onOpen: onOpenPreview)

            HStack(spacing: 12) {
                Button(action: onAskAgain) {
                    Text("Try again")
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

                Button(action: onSave) {
                    HStack(spacing: 8) {
                        Image(systemName: isSaved ? "bookmark.fill" : "bookmark")
                            .font(.system(size: 15, weight: .semibold))
                        Text(isSaved ? "Saved" : "Save")
                            .font(.system(size: 16, weight: .semibold))
                    }
                    .foregroundStyle(OunjePalette.primaryText.opacity(isSaved ? 0.72 : 1))
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
                .disabled(isSaved)

                Button(action: onAddToPrep) {
                    Text("Add")
                        .font(.system(size: 16, weight: .semibold))
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
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 20)
    }
}

struct RecipeAdaptedPreviewCard: View {
    let result: RecipeAdaptationResponse
    let baseImageURL: URL?
    let showsOnboardingCue: Bool
    let onOpen: () -> Void

    init(
        result: RecipeAdaptationResponse,
        baseImageURL: URL? = nil,
        showsOnboardingCue: Bool = false,
        onOpen: @escaping () -> Void
    ) {
        self.result = result
        self.baseImageURL = baseImageURL
        self.showsOnboardingCue = showsOnboardingCue
        self.onOpen = onOpen
    }

    private var imageCandidates: [URL] {
        var seen = Set<String>()
        return ([baseImageURL].compactMap { $0 } + result.recipeCard.imageCandidates).filter { url in
            seen.insert(url.absoluteString).inserted
        }
    }

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(result.adaptedRecipe.title)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(OunjePalette.primaryText)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)

                    Text(cardMetaText)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(OunjePalette.secondaryText)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                RecipeAdaptedPreviewArtwork(
                    imageCandidates: imageCandidates,
                    fallbackTitle: result.adaptedRecipe.title
                )

                Image(systemName: "chevron.right")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(OunjePalette.primaryText.opacity(0.82))
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(OunjePalette.surface.opacity(0.96))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .stroke(Color.white.opacity(0.16), lineWidth: 1)
            )
            .overlay(alignment: .topTrailing) {
                if showsOnboardingCue {
                    OnboardingTakeLookCueView()
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var cardMetaText: String {
        let ingredientCount = result.adaptedRecipe.ingredients.count
        let cookTime = result.adaptedRecipe.cookTimeText.trimmingCharacters(in: .whitespacesAndNewlines)
        if cookTime.isEmpty {
            return "\(ingredientCount) ingredients"
        }
        return "\(cookTime), \(ingredientCount) ingredients"
    }
}

private struct RecipeAdaptedPreviewArtwork: View {
    let imageCandidates: [URL]
    let fallbackTitle: String
    @StateObject private var loader = DiscoverRecipeImageLoader()

    private var loaderKey: String {
        imageCandidates.map(\.absoluteString).joined(separator: "|")
    }

    var body: some View {
        ZStack {
            if let uiImage = loader.image {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()
            } else if loader.isLoading {
                ProgressView()
                    .tint(.white.opacity(0.72))
                    .scaleEffect(0.78)
            } else {
                OunjePalette.elevated
                    .overlay {
                        Text(initials)
                            .biroHeaderFont(15)
                            .foregroundStyle(OunjePalette.primaryText.opacity(0.78))
                    }
            }
        }
        .frame(width: 58, height: 58)
        .clipShape(Circle())
        .overlay(
            Circle()
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.18), radius: 10, x: 0, y: 7)
        .task(id: loaderKey) {
            await loader.load(from: imageCandidates)
        }
    }

    private var initials: String {
        let words = fallbackTitle
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .prefix(2)
            .compactMap(\.first)
        let value = String(words).uppercased()
        return value.isEmpty ? "O" : value
    }
}

struct RecipeAdaptationSection: View {
    let title: String
    let items: [String]
    var numbered: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(OunjePalette.secondaryText)

            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .top, spacing: 10) {
                        Text(numbered ? "\(index + 1)." : "•")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(OunjePalette.accent)
                        Text(item)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(OunjePalette.primaryText)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(OunjePalette.surface.opacity(0.96))
                    .overlay(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .stroke(OunjePalette.stroke.opacity(0.84), lineWidth: 1)
                    )
            )
        }
    }
}

struct RecipeStoryShareSheet: View {
    let recipeTitle: String
    let recipeSubtitle: String?
    let imageCandidates: [URL]
    let recipeURL: URL?
    let onFallbackShare: () -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var loader = DiscoverRecipeImageLoader()
    @State private var isSharing = false
    @State private var statusMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Capsule()
                .fill(OunjePalette.elevated)
                .frame(width: 88, height: 6)
                .frame(maxWidth: .infinity)
                .padding(.top, 8)

            VStack(alignment: .leading, spacing: 6) {
                SleeScriptDisplayText("Add to Story.", size: 28, color: OunjePalette.primaryText)
                Text("Drop this recipe into Instagram Story with a link sticker so people can tap straight back into Ounje.")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(OunjePalette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                Text(recipeTitle)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(OunjePalette.primaryText)
                    .lineLimit(2)

                if let recipeSubtitle, !recipeSubtitle.isEmpty {
                    Text(recipeSubtitle)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(OunjePalette.secondaryText)
                        .lineLimit(2)
                }
            }

            VStack(alignment: .leading, spacing: 12) {
                Text("Preview")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(OunjePalette.secondaryText)

                RecipeStoryShareArtworkView(
                    title: recipeTitle,
                    subtitle: recipeSubtitle,
                    image: loader.image
                )
                .frame(height: 420)
                .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 30, style: .continuous)
                        .stroke(OunjePalette.stroke.opacity(0.84), lineWidth: 1)
                )
                .task(id: imageCandidates.map(\.absoluteString).joined(separator: "|")) {
                    await loader.load(from: imageCandidates)
                }
            }

            if let statusMessage {
                Text(statusMessage)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(OunjePalette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 12) {
                Button {
                    dismiss()
                } label: {
                    Text("Cancel")
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
                    Task {
                        await shareToInstagramStory()
                    }
                } label: {
                    Text(isSharing ? "Opening..." : "Share to Instagram")
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
                .disabled(isSharing)
                .opacity(isSharing ? 0.72 : 1)
            }

            Button {
                dismiss()
                onFallbackShare()
            } label: {
                Text("More share options")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(OunjePalette.secondaryText)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 20)
        .background(OunjePalette.background.ignoresSafeArea())
        .task {
            if loader.image == nil {
                await loader.load(from: imageCandidates)
            }
        }
    }

    private func shareToInstagramStory() async {
        isSharing = true
        defer { isSharing = false }

        let renderedImage = renderRecipeStoryArtwork(
            title: recipeTitle,
            subtitle: recipeSubtitle,
            recipeImage: loader.image
        )

        guard let backgroundData = renderedImage.jpegData(compressionQuality: 0.93) ?? renderedImage.pngData() else {
            statusMessage = "Couldn’t prepare the Story image."
            return
        }

        var payload: [String: Any] = [
            "com.instagram.sharedSticker.backgroundImage": backgroundData
        ]
        if let recipeURL {
            payload["com.instagram.sharedSticker.contentURL"] = recipeURL.absoluteString
        }

        UIPasteboard.general.setItems(
            [payload],
            options: [.expirationDate: Date().addingTimeInterval(5 * 60)]
        )

        guard let instagramStoryURL = URL(string: "instagram-stories://share"),
              UIApplication.shared.canOpenURL(instagramStoryURL) else {
            statusMessage = "Instagram isn’t available on this device."
            return
        }

        let opened = await withCheckedContinuation { continuation in
            UIApplication.shared.open(instagramStoryURL, options: [:]) { success in
                continuation.resume(returning: success)
            }
        }

        if opened {
            dismiss()
        } else {
            statusMessage = "Instagram couldn’t open the Story share."
        }
    }
}

struct RecipeStoryShareArtworkView: View {
    let title: String
    let subtitle: String?
    let image: UIImage?

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    OunjePalette.panel,
                    OunjePalette.surface,
                    OunjePalette.background
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            VStack(alignment: .leading, spacing: 0) {
                ZStack(alignment: .bottomLeading) {
                    if let image {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                    } else {
                        LinearGradient(
                            colors: [
                                OunjePalette.accent.opacity(0.52),
                                OunjePalette.panel.opacity(0.94)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                        .overlay(
                            Image(systemName: "camera.fill")
                                .font(.system(size: 54, weight: .semibold))
                                .foregroundStyle(OunjePalette.softCream.opacity(0.88))
                        )
                    }

                    LinearGradient(
                        colors: [
                            .clear,
                            .black.opacity(0.18),
                            .black.opacity(0.82)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )

                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            InstagramGlyphIcon(size: 34)
                            Spacer(minLength: 0)
                        }

                        Text(title)
                            .font(.system(size: 42, weight: .black, design: .rounded))
                            .foregroundStyle(.white)
                            .lineLimit(3)
                            .minimumScaleFactor(0.82)
                            .fixedSize(horizontal: false, vertical: true)

                        if let subtitle, !subtitle.isEmpty {
                            Text(subtitle)
                                .font(.system(size: 20, weight: .semibold, design: .rounded))
                                .foregroundStyle(.white.opacity(0.82))
                                .lineLimit(4)
                                .minimumScaleFactor(0.86)
                        }

                        Text("Tap the link sticker to open it in Ounje.")
                            .font(.system(size: 18, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.74))
                    }
                    .padding(26)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 1240)
                .clipped()

                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 12) {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(OunjePalette.accent.opacity(0.18))
                            .frame(width: 54, height: 54)
                            .overlay(
                                Image(systemName: "link")
                                    .font(.system(size: 22, weight: .semibold))
                                    .foregroundStyle(OunjePalette.primaryText)
                            )

                        VStack(alignment: .leading, spacing: 3) {
                            Text("Ounje")
                                .font(.system(size: 20, weight: .bold))
                                .foregroundStyle(OunjePalette.primaryText)
                            Text("Recipe story share")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(OunjePalette.secondaryText)
                        }
                    }

                    Text("Recipe card created in Ounje")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(OunjePalette.secondaryText)
                }
                .padding(26)
            }
        }
    }
}

@MainActor
private func renderRecipeStoryArtwork(title: String, subtitle: String?, recipeImage: UIImage?) -> UIImage {
    let targetSize = CGSize(width: 1080, height: 1920)
    let rootView = RecipeStoryShareArtworkView(title: title, subtitle: subtitle, image: recipeImage)
        .frame(width: targetSize.width, height: targetSize.height)
        .preferredColorScheme(.dark)
    let controller = UIHostingController(rootView: rootView)
    controller.view.bounds = CGRect(origin: .zero, size: targetSize)
    controller.view.backgroundColor = .clear
    controller.view.setNeedsLayout()
    controller.view.layoutIfNeeded()

    let renderer = UIGraphicsImageRenderer(size: targetSize)
    return renderer.image { _ in
        controller.view.drawHierarchy(in: CGRect(origin: .zero, size: targetSize), afterScreenUpdates: true)
    }
}

struct RecipeDetailActionButton: View {
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

struct RecipeDetailCompactActionButton: View {
    let title: String
    var systemImage: String? = nil
    var showsInstagramGlyph: Bool = false
    var compact: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if showsInstagramGlyph {
                    InstagramGlyphIcon(size: compact ? 13 : 17)
                } else if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: compact ? 13 : 16, weight: .semibold))
                }
                Text(title)
                    .font(.system(size: compact ? 14 : 16, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(OunjePalette.primaryText)
            .frame(width: compact ? 82 : nil, height: compact ? 42 : nil)
            .padding(.horizontal, compact ? 0 : 16)
            .padding(.vertical, compact ? 0 : 14)
            .background(
                RoundedRectangle(cornerRadius: compact ? 13 : 18, style: .continuous)
                    .fill(OunjePalette.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: compact ? 13 : 18, style: .continuous)
                            .stroke(OunjePalette.stroke, lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
    }
}

private struct RecipeDetailScrollOffsetPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

struct OnboardingTapCueView: View {
    let label: String?
    let labelOffset: CGSize

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isFloating = false
    @State private var isPulsing = false

    init(label: String? = nil, labelOffset: CGSize = CGSize(width: -48, height: -32)) {
        self.label = label
        self.labelOffset = labelOffset
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.white.opacity(0.12))
                .frame(width: 34, height: 34)
                .scaleEffect(isPulsing ? 1.16 : 0.88)
                .opacity(isPulsing ? 0.18 : 0.46)

            Image(systemName: "hand.tap.fill")
                .font(.system(size: 24, weight: .bold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Color.white, Color.white.opacity(0.8))
                .shadow(color: .black.opacity(0.22), radius: 8, y: 6)
                .rotationEffect(.degrees(-10))

            if let label {
                OnboardingCueLabel(text: label)
                    .offset(labelOffset)
            }
        }
        .offset(y: reduceMotion ? 0 : (isFloating ? -7 : 5))
        .scaleEffect(reduceMotion ? 1 : (isPulsing ? 1.02 : 0.96))
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.05).repeatForever(autoreverses: true)) {
                isFloating = true
            }
            withAnimation(.easeInOut(duration: 0.78).repeatForever(autoreverses: true)) {
                isPulsing = true
            }
        }
    }
}

struct OnboardingCueLabel: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .black, design: .rounded))
            .foregroundStyle(OunjePalette.primaryText)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                Capsule(style: .continuous)
                    .fill(OunjePalette.surface.opacity(0.96))
                    .shadow(color: .black.opacity(0.22), radius: 10, y: 6)
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(Color.white.opacity(0.18), lineWidth: 1)
            )
    }
}

struct OnboardingAskButtonCueView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0 / 30.0)) { timeline in
            let offset = reduceMotion ? CGPoint(x: 16, y: 8) : cueOffset(at: timeline.date)

            OnboardingTapCueView(label: "Edit Recipe", labelOffset: CGSize(width: 50, height: -32))
                .offset(x: offset.x, y: offset.y)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    private func cueOffset(at date: Date) -> CGPoint {
        let cycle: TimeInterval = 4.2
        let progress = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: cycle) / cycle
        let points = [
            CGPoint(x: 16, y: 8),
            CGPoint(x: 34, y: -24),
            CGPoint(x: -8, y: -18),
            CGPoint(x: 26, y: 0),
            CGPoint(x: 16, y: 8)
        ]
        let scaled = progress * Double(points.count - 1)
        let index = min(points.count - 2, max(0, Int(scaled)))
        let localProgress = CGFloat(scaled - Double(index))
        let eased = localProgress * localProgress * (3 - 2 * localProgress)
        let start = points[index]
        let end = points[index + 1]
        let bob = CGFloat(sin(progress * Double.pi * 2)) * 2

        return CGPoint(
            x: start.x + (end.x - start.x) * eased,
            y: start.y + (end.y - start.y) * eased + bob
        )
    }
}

struct OnboardingAskReturnCueView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            OnboardingCueLabel(text: "Edit Recipe")

            Image(systemName: "hand.point.up.left.fill")
                .font(.system(size: 30, weight: .bold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Color.white, Color.white.opacity(0.78))
                .shadow(color: .black.opacity(0.24), radius: 10, y: 7)
                .rotationEffect(.degrees(isHovering ? -8 : 5))
                .offset(x: reduceMotion ? 0 : (isHovering ? -5 : 2), y: reduceMotion ? 0 : (isHovering ? -8 : 5))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            Capsule(style: .continuous)
                .fill(OunjePalette.panel.opacity(0.92))
                .shadow(color: .black.opacity(0.24), radius: 14, y: 8)
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.92).repeatForever(autoreverses: true)) {
                isHovering = true
            }
        }
    }
}

struct OnboardingInspirationCueView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var startDate: Date?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0 / 30.0)) { timeline in
            let offset = reduceMotion ? CGPoint(x: 122, y: 1) : cueOffset(at: timeline.date)

            OnboardingTapCueView()
                .scaleEffect(0.88)
                .offset(x: offset.x, y: offset.y)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .onAppear {
            if startDate == nil {
                startDate = Date()
            }
        }
    }

    private func cueOffset(at date: Date) -> CGPoint {
        let introDuration: TimeInterval = 1.35
        let elapsed = max(0, date.timeIntervalSince(startDate ?? date))
        let settledPoint = CGPoint(x: 122, y: 1)

        if elapsed < introDuration {
            return interpolatedPoint(
                from: CGPoint(x: 145, y: -220),
                to: settledPoint,
                progress: CGFloat(elapsed / introDuration),
                bobPhase: elapsed
            )
        }

        let cycle: TimeInterval = 3.9
        let hoverElapsed = elapsed - introDuration
        let progress = hoverElapsed.truncatingRemainder(dividingBy: cycle) / cycle
        let points = [
            settledPoint,
            CGPoint(x: 180, y: -18),
            CGPoint(x: 246, y: 8),
            CGPoint(x: 154, y: 18),
            settledPoint
        ]
        return pathPoint(points: points, progress: progress, bobPhase: hoverElapsed)
    }

    private func interpolatedPoint(from start: CGPoint, to end: CGPoint, progress: CGFloat, bobPhase: TimeInterval) -> CGPoint {
        let eased = progress * progress * (3 - 2 * progress)
        let bob = CGFloat(sin(bobPhase * Double.pi * 2)) * 2

        return CGPoint(
            x: start.x + (end.x - start.x) * eased,
            y: start.y + (end.y - start.y) * eased + bob
        )
    }

    private func pathPoint(points: [CGPoint], progress: TimeInterval, bobPhase: TimeInterval) -> CGPoint {
        let scaled = progress * Double(points.count - 1)
        let index = min(points.count - 2, max(0, Int(scaled)))
        let localProgress = CGFloat(scaled - Double(index))
        let eased = localProgress * localProgress * (3 - 2 * localProgress)
        let start = points[index]
        let end = points[index + 1]
        let bob = CGFloat(sin(bobPhase * Double.pi * 2)) * 2

        return CGPoint(
            x: start.x + (end.x - start.x) * eased,
            y: start.y + (end.y - start.y) * eased + bob
        )
    }
}

private enum OnboardingAdaptedRecipeCueTarget {
    case save
    case scroll
    case `continue`
}

private struct OnboardingSaveRecipeCueView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var startDate: Date?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0 / 30.0)) { timeline in
            let offset = reduceMotion ? CGPoint(x: 10, y: 20) : cueOffset(at: timeline.date)

            OnboardingTapCueView(label: "Save recipe", labelOffset: CGSize(width: -28, height: -34))
                .scaleEffect(0.9)
                .offset(x: offset.x, y: offset.y)
        }
        .onAppear {
            if startDate == nil {
                startDate = Date()
            }
        }
    }

    private func cueOffset(at date: Date) -> CGPoint {
        let introDuration: TimeInterval = 1.05
        let elapsed = max(0, date.timeIntervalSince(startDate ?? date))
        let settledPoint = CGPoint(x: 10, y: 20)

        if elapsed < introDuration {
            let progress = CGFloat(elapsed / introDuration)
            let eased = progress * progress * (3 - 2 * progress)
            return CGPoint(
                x: 132 + (settledPoint.x - 132) * eased,
                y: 238 + (settledPoint.y - 238) * eased
            )
        }

        let hoverElapsed = elapsed - introDuration
        let cycle: TimeInterval = 3.2
        let progress = hoverElapsed.truncatingRemainder(dividingBy: cycle) / cycle
        let points = [
            settledPoint,
            CGPoint(x: 18, y: 8),
            CGPoint(x: 0, y: 2),
            CGPoint(x: 14, y: 24),
            settledPoint
        ]

        return OnboardingCuePath.point(points: points, progress: progress, bobPhase: hoverElapsed)
    }
}

private struct OnboardingAdaptedRecipeNavigationCueView: View {
    let target: OnboardingAdaptedRecipeCueTarget
    let availableWidth: CGFloat
    let availableHeight: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isDragging = false

    private var labelText: String {
        switch target {
        case .scroll:
            return "Scroll to review"
        case .continue:
            return "Finish onboarding"
        case .save:
            return ""
        }
    }

    private var iconRotation: Double {
        switch target {
        case .scroll:
            return 0
        case .continue:
            return -28
        case .save:
            return 10
        }
    }

    private var cueOffset: CGSize {
        switch target {
        case .scroll:
            return .zero
        case .continue:
            return CGSize(width: 14, height: max(96, availableHeight * 0.36))
        case .save:
            return .zero
        }
    }

    private var hoverOffset: CGFloat {
        guard !reduceMotion else { return 0 }
        switch target {
        case .scroll:
            return isDragging ? 18 : -4
        case .continue:
            return isDragging ? 9 : -5
        case .save:
            return 0
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            OnboardingCueLabel(text: labelText)

            Image(systemName: "hand.point.down.fill")
                .font(.system(size: 30, weight: .bold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Color.white, Color.white.opacity(0.76))
                .shadow(color: .black.opacity(0.24), radius: 10, y: 7)
                .rotationEffect(.degrees(iconRotation))
                .offset(y: hoverOffset)
        }
        .offset(cueOffset)
        .animation(.spring(response: 0.82, dampingFraction: 0.84), value: target)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.96).repeatForever(autoreverses: true)) {
                isDragging = true
            }
        }
    }
}

struct OnboardingTakeLookCueView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var startDate: Date?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0 / 30.0)) { timeline in
            let offset = reduceMotion ? CGPoint(x: -22, y: 12) : cueOffset(at: timeline.date)

            OnboardingTapCueView(label: "Take a look")
                .scaleEffect(0.9)
                .offset(x: offset.x, y: offset.y)
        }
        .onAppear {
            if startDate == nil {
                startDate = Date()
            }
        }
    }

    private func cueOffset(at date: Date) -> CGPoint {
        let introDuration: TimeInterval = 1.15
        let elapsed = max(0, date.timeIntervalSince(startDate ?? date))
        let settledPoint = CGPoint(x: -22, y: 12)

        if elapsed < introDuration {
            let progress = CGFloat(elapsed / introDuration)
            let eased = progress * progress * (3 - 2 * progress)
            return CGPoint(
                x: -6 + (settledPoint.x + 6) * eased,
                y: 156 + (settledPoint.y - 156) * eased
            )
        }

        let hoverElapsed = elapsed - introDuration
        let cycle: TimeInterval = 3.6
        let progress = hoverElapsed.truncatingRemainder(dividingBy: cycle) / cycle
        let points = [
            settledPoint,
            CGPoint(x: -36, y: 4),
            CGPoint(x: -18, y: -3),
            CGPoint(x: -8, y: 16),
            settledPoint
        ]

        return OnboardingCuePath.point(points: points, progress: progress, bobPhase: hoverElapsed)
    }
}

struct OnboardingRecipeContinueBar: View {
    let action: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Button(action: action) {
                Text("Continue")
                    .font(.system(size: 16, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 56)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(OunjePalette.accent)
                    )
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.top, 0)
        .padding(.bottom, 14)
        .background(
            LinearGradient(
                colors: [
                    OunjePalette.background.opacity(0),
                    OunjePalette.background.opacity(0.84),
                    OunjePalette.background
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea(edges: .bottom)
        )
    }
}

private enum OnboardingCuePath {
    static func point(points: [CGPoint], progress: TimeInterval, bobPhase: TimeInterval) -> CGPoint {
        let scaled = progress * Double(points.count - 1)
        let index = min(points.count - 2, max(0, Int(scaled)))
        let localProgress = CGFloat(scaled - Double(index))
        let eased = localProgress * localProgress * (3 - 2 * localProgress)
        let start = points[index]
        let end = points[index + 1]
        let bob = CGFloat(sin(bobPhase * Double.pi * 2)) * 2

        return CGPoint(
            x: start.x + (end.x - start.x) * eased,
            y: start.y + (end.y - start.y) * eased + bob
        )
    }
}

struct InstagramGlyphIcon: View {
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

struct RecipeDetailMetricsGrid: View {
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

enum IngredientMonogramFormatter {
    static func monogram(for name: String) -> String {
        let parts = name
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { $0.rangeOfCharacter(from: .letters) != nil }
            .filter { $0.count > 1 }

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

struct RecipeIngredientTile: View {
    let ingredient: RecipeDetailIngredient
    let imageSize: CGFloat
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
                        .sleeDisplayFont(22)
                        .foregroundStyle(OunjePalette.softCream.opacity(0.9))
                        .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                }

            }
            .frame(width: imageSize, height: imageSize)
            .clipped()
            .task(id: ingredient.stableID) {
                if let url = ingredient.imageURL {
                    await loader.load(from: [url])
                }
            }

            Text(ingredient.displayTitle)
                .sleeDisplayFont(14)
                .foregroundStyle(OunjePalette.primaryText)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let quantityText = ingredient.displayQuantityText, !quantityText.isEmpty {
                Text(quantityText)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(OunjePalette.secondaryText)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
        }
        .frame(width: imageSize, alignment: .topLeading)
    }
}

struct RecipeStepBlock: View {
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

struct RecipeDetailEnjoySection: View {
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
                    } else if recipes.isEmpty {
                        Text("More ideas are still warming up.")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(OunjePalette.secondaryText)
                            .frame(width: 240, height: 116, alignment: .leading)
                    } else {
                        ForEach(recipes, id: \.id) { recipe in
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

struct RecipeEnjoyMiniCard: View {
    let recipe: DiscoverRecipeCardData
    let onSelect: () -> Void

    var body: some View {
        DiscoverRemoteRecipeCard(recipe: recipe) {
            onSelect()
        }
        .frame(width: 240)
    }
}

struct RecipeEnjoyMiniCardPlaceholder: View {
    var body: some View {
        DiscoverRecipeCardLoadingPlaceholder(width: 240)
    }
}

struct FlexibleTagCloud: View {
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

struct RecipeCookBottomBar: View {
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

struct RecipeDetailLoadingSections: View {
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

struct RecipeDetailLoadFailedState: View {
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

struct WrappingHStack<Data: RandomAccessCollection, ID: Hashable, Content: View>: View where Data.Element: Hashable {
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
