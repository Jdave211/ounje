import SwiftUI
import UIKit
import Foundation

struct DiscoverPresetTextButton: View {
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

struct RecipesEmptyState: View {
    let title: String
    let detail: String
    let symbolName: String
    var assetName: String? = nil

    var body: some View {
        VStack(spacing: 18) {
            if let assetName {
                Image(assetName)
                    .resizable()
                    .scaledToFit()
                    .frame(height: 132)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 24)
                    .accessibilityHidden(true)
            } else {
                Image(systemName: symbolName)
                    .font(.system(size: 88, weight: .light))
                    .foregroundStyle(OunjePalette.secondaryText.opacity(0.5))
                    .frame(maxWidth: .infinity)
                    .padding(.top, 44)
            }

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

struct MealPrepLoadingArtworkBlock: View {
    let shimmerOffset: CGFloat

    var body: some View {
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
                    .modifier(LoadingSheen(offset: shimmerOffset))
                    .padding(10)
            }
            .modifier(LoadingSheen(offset: shimmerOffset))
    }
}

enum DiscoverRemoteRecipeCardLayout {
    case standard
    case compact

    var cardHeight: CGFloat {
        switch self {
        case .standard: return 292
        case .compact: return 214
        }
    }

    var imageFrameHeight: CGFloat {
        switch self {
        case .standard: return 188
        case .compact: return 116
        }
    }

    var imageSize: CGFloat {
        switch self {
        case .standard: return 146
        case .compact: return 100
        }
    }

    var outerPadding: CGFloat {
        switch self {
        case .standard: return 14
        case .compact: return 11
        }
    }

    var contentSpacing: CGFloat {
        switch self {
        case .standard: return 14
        case .compact: return 9
        }
    }

    var titleHeight: CGFloat {
        switch self {
        case .standard: return 42
        case .compact: return 38
        }
    }

    var detailsHeight: CGFloat {
        switch self {
        case .standard: return 64
        case .compact: return 52
        }
    }

    var titleSizeClean: CGFloat {
        switch self {
        case .standard: return 19
        case .compact: return 14
        }
    }

    var titleSizeExpressive: CGFloat {
        switch self {
        case .standard: return 22
        case .compact: return 16
        }
    }

    var detailsSpacing: CGFloat {
        switch self {
        case .standard: return 8
        case .compact: return 6
        }
    }

    var metadataTextSize: CGFloat {
        switch self {
        case .standard: return 12
        case .compact: return 10.5
        }
    }

    var metadataIconSize: CGFloat {
        switch self {
        case .standard: return 11
        case .compact: return 10
        }
    }

    var cornerRadius: CGFloat {
        switch self {
        case .standard: return 24
        case .compact: return 20
        }
    }

    var fallbackEmojiSize: CGFloat {
        switch self {
        case .standard: return 56
        case .compact: return 42
        }
    }

    var fallbackLabelSize: CGFloat {
        switch self {
        case .standard: return 13
        case .compact: return 11
        }
    }
}

struct RecipeCommunityStars: View {
    let averageRating: Double?
    let ratingCount: Int
    let size: CGFloat
    var showsValue = true

    private let filledColor = Color(red: 0.98, green: 0.72, blue: 0.22)

    private var displayedHalfSteps: Int {
        guard let averageRating else { return 0 }
        let clampedRating = min(max(averageRating, 0), 5)
        let wholeStars = Int(clampedRating.rounded(.down))
        let fraction = clampedRating - Double(wholeStars)

        if fraction < 0.25 {
            return wholeStars * 2
        }
        if fraction < 0.75 {
            return wholeStars * 2 + 1
        }
        return min(10, wholeStars * 2 + 2)
    }

    private func symbolName(for position: Int) -> String {
        let fullThreshold = position * 2
        if displayedHalfSteps >= fullThreshold {
            return "star.fill"
        }
        if displayedHalfSteps == fullThreshold - 1 {
            return "star.leadinghalf.filled"
        }
        return "star"
    }

    var body: some View {
        HStack(spacing: 3) {
            HStack(spacing: 1) {
                ForEach(1 ... 5, id: \.self) { position in
                    Image(systemName: symbolName(for: position))
                        .font(.system(size: size, weight: .bold))
                        .foregroundStyle(
                            displayedHalfSteps >= (position * 2 - 1)
                                ? filledColor
                                : OunjePalette.softCream.opacity(0.72)
                        )
                }
            }

            if showsValue {
                Text(averageRating.map { String(format: "%.1f", $0) } ?? "New")
                    .font(.system(size: max(9, size - 0.5), weight: .semibold))
                    .foregroundStyle(OunjePalette.secondaryText)
                    .monospacedDigit()
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            ratingCount > 0
                ? "Rated \(String(format: "%.1f", averageRating ?? 0)) out of 5 from \(ratingCount) ratings"
                : "Recipe score \(String(format: "%.1f", averageRating ?? 0)) out of 5"
        )
    }
}

struct DiscoverRemoteRecipeCard: View {
    let recipe: DiscoverRecipeCardData
    let showsSaveAction: Bool
    let secondaryTopAction: DiscoverRemoteRecipeCardTopAction?
    let transitionNamespace: Namespace.ID?
    let onSelect: () -> Void
    let isInteractive: Bool
    let showsTopActions: Bool
    let showsImageLoadingSkeleton: Bool
    let typographyStyleOverride: RecipeTypographyStyle?
    let layout: DiscoverRemoteRecipeCardLayout
    @EnvironmentObject private var savedStore: SavedRecipesStore
    @AppStorage(RecipeTypographyStyle.storageKey) private var recipeTypographyStyleRawValue = RecipeTypographyStyle.defaultStyle.rawValue

    private var resolvedTypographyStyle: RecipeTypographyStyle {
        typographyStyleOverride ?? RecipeTypographyStyle.resolved(from: recipeTypographyStyleRawValue)
    }

    private var transitionContext: RecipeTransitionContext? {
        guard let transitionNamespace else { return nil }
        return RecipeTransitionContext(namespace: transitionNamespace, recipeID: recipe.id)
    }

    init(
        recipe: DiscoverRecipeCardData,
        showsSaveAction: Bool = true,
        secondaryTopAction: DiscoverRemoteRecipeCardTopAction? = nil,
        transitionNamespace: Namespace.ID? = nil,
        isInteractive: Bool = true,
        showsTopActions: Bool = true,
        showsImageLoadingSkeleton: Bool = false,
        typographyStyleOverride: RecipeTypographyStyle? = nil,
        layout: DiscoverRemoteRecipeCardLayout = .standard,
        onSelect: @escaping () -> Void
    ) {
        self.recipe = recipe
        self.showsSaveAction = showsSaveAction
        self.secondaryTopAction = secondaryTopAction
        self.transitionNamespace = transitionNamespace
        self.isInteractive = isInteractive
        self.showsTopActions = showsTopActions
        self.showsImageLoadingSkeleton = showsImageLoadingSkeleton
        self.typographyStyleOverride = typographyStyleOverride
        self.layout = layout
        self.onSelect = onSelect
    }

    var body: some View {
        content
            .buttonStyle(OunjeCardPressButtonStyle())
    }

    @ViewBuilder
    private var content: some View {
        cardBody
            .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .onTapGesture {
                guard isInteractive else { return }
                onSelect()
            }
    }

    @ViewBuilder
    private var cardBody: some View {
        VStack(alignment: .leading, spacing: layout.contentSpacing) {
            DiscoverRemoteRecipeImage(
                recipe: recipe,
                transitionContext: transitionContext,
                showsLoadingSkeleton: showsImageLoadingSkeleton,
                imageSize: layout.imageSize,
                fallbackEmojiSize: layout.fallbackEmojiSize,
                fallbackLabelSize: layout.fallbackLabelSize
            )
                .frame(maxWidth: .infinity)
                .frame(height: layout.imageFrameHeight)
                .clipped()

            VStack(alignment: .leading, spacing: layout.detailsSpacing) {
                RecipeTypographyTitleText(
                    recipe.displayTitle,
                    size: resolvedTypographyStyle == .clean ? layout.titleSizeClean : layout.titleSizeExpressive,
                    color: OunjePalette.primaryText,
                    style: resolvedTypographyStyle
                )
                .lineLimit(2)
                .minimumScaleFactor(0.84)
                .frame(maxWidth: .infinity, minHeight: layout.titleHeight, maxHeight: layout.titleHeight, alignment: .topLeading)
                .modifier(RecipeTitleTransitionModifier(transitionContext: transitionContext))

                HStack {
                    Spacer(minLength: 0)
                    RecipeCommunityStars(
                        averageRating: recipe.displayRating,
                        ratingCount: recipe.ratingCount ?? 0,
                        size: layout.metadataIconSize,
                        showsValue: false
                    )
                }
                .font(.system(size: layout.metadataTextSize, weight: .medium))
            }
            .frame(maxWidth: .infinity, minHeight: layout.detailsHeight, maxHeight: layout.detailsHeight, alignment: .topLeading)
            .padding(.horizontal, 2)
            .padding(.bottom, 2)
        }
        .padding(layout.outerPadding)
        .frame(maxWidth: .infinity, minHeight: layout.cardHeight, maxHeight: layout.cardHeight, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: layout.cornerRadius, style: .continuous)
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
        .clipShape(RoundedRectangle(cornerRadius: layout.cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: layout.cornerRadius, style: .continuous)
                .stroke(.white.opacity(0.06), lineWidth: 1)
        )
        .overlay(alignment: .topTrailing) {
            if showsTopActions {
                HStack(spacing: 8) {
                    if showsSaveAction {
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
                    }

                    if let secondaryTopAction {
                        Button(action: secondaryTopAction.action) {
                            Image(systemName: secondaryTopAction.systemName)
                                .font(.system(size: secondaryTopAction.symbolSize, weight: .bold))
                                .foregroundStyle(OunjePalette.primaryText.opacity(0.88))
                                .frame(width: secondaryTopAction.frameSize, height: secondaryTopAction.frameSize)
                                .background(
                                    Group {
                                        if secondaryTopAction.showsBackground {
                                            Circle()
                                                .fill(OunjePalette.surface.opacity(0.96))
                                                .overlay(
                                                    Circle()
                                                        .stroke(OunjePalette.stroke, lineWidth: 1)
                                                )
                                        }
                                    }
                                )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(secondaryTopAction.accessibilityLabel)
                    }
                }
                .padding(8)
            }
        }
        .shadow(color: .black.opacity(0.16), radius: 12, x: 0, y: 8)
    }
}

struct DiscoverRemoteRecipeCardTopAction {
    let systemName: String
    let accessibilityLabel: String
    let showsBackground: Bool
    let symbolSize: CGFloat
    let frameSize: CGFloat
    let action: () -> Void

    init(
        systemName: String,
        accessibilityLabel: String,
        showsBackground: Bool,
        symbolSize: CGFloat = 20,
        frameSize: CGFloat = 42,
        action: @escaping () -> Void
    ) {
        self.systemName = systemName
        self.accessibilityLabel = accessibilityLabel
        self.showsBackground = showsBackground
        self.symbolSize = symbolSize
        self.frameSize = frameSize
        self.action = action
    }
}

private struct DiscoverRemoteRecipeImage: View {
    let recipe: DiscoverRecipeCardData
    let transitionContext: RecipeTransitionContext?
    var showsLoadingSkeleton: Bool = false
    var imageSize: CGFloat = 146
    var fallbackEmojiSize: CGFloat = 56
    var fallbackLabelSize: CGFloat = 13
    @StateObject private var loader = DiscoverRecipeImageLoader()
    @State private var shimmerOffset: CGFloat = -1.2

    var body: some View {
        ZStack {
            if let uiImage = loader.image {
                Image(uiImage: uiImage)
                            .resizable()
                            .scaledToFill()
                    .frame(width: imageSize, height: imageSize)
                    .clipShape(Circle())
                    .overlay(
                        Circle()
                            .stroke(.white.opacity(0.08), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.24), radius: 18, x: 0, y: 12)
            } else if loader.isLoading {
                if showsLoadingSkeleton {
                    MealPrepLoadingArtworkBlock(shimmerOffset: shimmerOffset)
                } else {
                    ProgressView()
                        .tint(.white.opacity(0.72))
                }
            } else {
                fallback
            }
        }
        .modifier(RecipeImageTransitionModifier(transitionContext: transitionContext))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: recipe.imageCandidates.map(\.absoluteString).joined(separator: "|")) {
            await loader.load(from: recipe.imageCandidates)
        }
        .onAppear {
            guard showsLoadingSkeleton else { return }
            withAnimation(.linear(duration: 1.3).repeatForever(autoreverses: false)) {
                shimmerOffset = 1.4
            }
        }
    }

    private var fallback: some View {
        VStack(spacing: 10) {
            Text(recipe.emoji)
                .font(.system(size: fallbackEmojiSize))
            Text(recipe.filterLabel)
                .biroHeaderFont(fallbackLabelSize)
                .foregroundStyle(OunjePalette.secondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

@MainActor
final class DiscoverRecipeImageLoader: ObservableObject {
    @Published var image: UIImage?
    @Published var isLoading = false
    private var lastKey: String?

    func load(from candidates: [URL]) async {
        let key = candidates.map(\.absoluteString).joined(separator: "|")
        if lastKey == key, image != nil {
            return
        }

        lastKey = key
        isLoading = true

        defer {
            isLoading = false
        }

        for url in candidates {
            if let fetched = await ImagePrefetcher.shared.image(for: url.absoluteString) {
                image = fetched
                return
            }
        }

        image = nil
    }
}

/// A library-specific recipe tile: the food visual carries the card instead of
/// sitting in a separate circular treatment used by the Discover feed.
struct RecipeLibraryVisualCard: View {
    let recipe: DiscoverRecipeCardData
    let topAction: DiscoverRemoteRecipeCardTopAction?
    let guideTargetID: FirstRunGuideTargetID?
    let selectionState: Bool?
    let selectionAction: (() -> Void)?
    let onSelect: () -> Void

    @StateObject private var loader = DiscoverRecipeImageLoader()
    @AppStorage(RecipeTypographyStyle.storageKey) private var recipeTypographyStyleRawValue = RecipeTypographyStyle.defaultStyle.rawValue

    private let visualHeight: CGFloat = 176
    private let visualCornerRadius: CGFloat = 24

    private var resolvedTypographyStyle: RecipeTypographyStyle {
        RecipeTypographyStyle.resolved(from: recipeTypographyStyleRawValue)
    }

    private var isOunjeNativeRecipe: Bool {
        [recipe.source, recipe.category, recipe.recipeType]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .contains { $0.localizedCaseInsensitiveCompare("Ounje") == .orderedSame }
    }

    init(
        recipe: DiscoverRecipeCardData,
        topAction: DiscoverRemoteRecipeCardTopAction? = nil,
        guideTargetID: FirstRunGuideTargetID? = nil,
        selectionState: Bool? = nil,
        selectionAction: (() -> Void)? = nil,
        onSelect: @escaping () -> Void
    ) {
        self.recipe = recipe
        self.topAction = topAction
        self.guideTargetID = guideTargetID
        self.selectionState = selectionState
        self.selectionAction = selectionAction
        self.onSelect = onSelect
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button(action: onSelect) {
                VStack(alignment: .leading, spacing: 6) {
                    imageSurface
                        .frame(maxWidth: .infinity)
                        .frame(height: visualHeight)
                        .background(OunjePalette.surface)
                        .clipShape(RoundedRectangle(cornerRadius: visualCornerRadius, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: visualCornerRadius, style: .continuous)
                                .stroke(.white.opacity(0.09), lineWidth: 1)
                        )
                        .clipped()
                        .firstRunGuideTarget(guideTargetID)

                    VStack(alignment: .leading, spacing: 2) {
                        RecipeTypographyTitleText(
                            recipe.displayTitle,
                            size: 16,
                            color: OunjePalette.primaryText,
                            style: resolvedTypographyStyle
                        )
                        .lineLimit(2)
                        .minimumScaleFactor(0.78)
                        .frame(maxWidth: .infinity, minHeight: 20, maxHeight: 40, alignment: .topLeading)
                        .padding(.trailing, 4)
                        .clipped()

                        Text(recipe.authorLabel)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(OunjePalette.secondaryText)
                            .lineLimit(1)
                            .padding(.top, 0)
                    }
                    .padding(.horizontal, 2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .clipped()
                .contentShape(Rectangle())
            }
            .buttonStyle(OunjeCardPressButtonStyle())

            if let isSelected = selectionState, let selectionAction {
                Button(action: selectionAction) {
                    ZStack {
                        Circle()
                            .fill(
                                isSelected
                                    ? OunjePalette.accent
                                    : OunjePalette.background.opacity(0.82)
                            )

                        Circle()
                            .stroke(
                                isSelected
                                    ? OunjePalette.softCream
                                    : OunjePalette.softCream.opacity(0.96),
                                lineWidth: 2.4
                            )

                        if isSelected {
                            Image(systemName: "checkmark")
                                .font(.system(size: 14, weight: .black))
                                .foregroundStyle(OunjePalette.softCream)
                        }
                    }
                    .frame(width: 34, height: 34)
                    .contentShape(Circle())
                    .shadow(color: .black.opacity(0.58), radius: 5, y: 2)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    isSelected
                        ? "Remove \(recipe.displayTitle) from selection"
                        : "Select \(recipe.displayTitle)"
                )
                .accessibilityValue(isSelected ? "Selected" : "Not selected")
                .padding(9)
            } else if let topAction {
                Button(action: topAction.action) {
                    Image(systemName: topAction.systemName)
                        .font(.system(size: topAction.symbolSize, weight: .bold))
                        .foregroundStyle(OunjePalette.primaryText)
                        .frame(width: topAction.frameSize, height: topAction.frameSize)
                        .background {
                            if topAction.showsBackground {
                                Circle()
                                    .fill(OunjePalette.background.opacity(0.78))
                                    .overlay(Circle().stroke(.white.opacity(0.16), lineWidth: 1))
                            }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(topAction.accessibilityLabel)
                .padding(9)
            }
        }
        .accessibilityLabel(recipe.displayTitle)
        .task(id: recipe.imageCandidates.map(\.absoluteString).joined(separator: "|")) {
            await loader.load(from: recipe.imageCandidates)
        }
    }

    @ViewBuilder
    private var imageSurface: some View {
        if let image = loader.image {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .colorMultiply(isOunjeNativeRecipe ? Color(hex: "858982") : .white)
                .saturation(isOunjeNativeRecipe ? 0.9 : 1)
                .brightness(isOunjeNativeRecipe ? -0.04 : 0)
                .overlay {
                    if isOunjeNativeRecipe {
                        ZStack {
                            Color.black.opacity(0.08)
                            LinearGradient(
                                colors: [
                                    Color.clear,
                                    OunjePalette.surface.opacity(0.18)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        }
                    }
                }
        } else if loader.isLoading {
            Rectangle()
                .fill(OunjePalette.surface)
                .overlay {
                    ProgressView()
                        .tint(OunjePalette.softCream)
                }
        } else {
            ZStack {
                OunjePalette.surface
                Text(recipe.emoji)
                    .font(.system(size: 56))
            }
        }
    }
}

struct DiscoverRecipeCardLoadingPlaceholder: View {
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

struct LoadingSheen: ViewModifier {
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
