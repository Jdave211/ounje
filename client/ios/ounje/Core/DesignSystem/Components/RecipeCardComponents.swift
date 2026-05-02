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

struct DiscoverRemoteRecipeCard: View {
    let recipe: DiscoverRecipeCardData
    let showsSaveAction: Bool
    let secondaryTopAction: DiscoverRemoteRecipeCardTopAction?
    let transitionNamespace: Namespace.ID?
    let onSelect: () -> Void
    let isInteractive: Bool
    let showsTopActions: Bool
    let showsImageLoadingSkeleton: Bool
    @EnvironmentObject private var savedStore: SavedRecipesStore
    private let cardHeight: CGFloat = 292

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
        onSelect: @escaping () -> Void
    ) {
        self.recipe = recipe
        self.showsSaveAction = showsSaveAction
        self.secondaryTopAction = secondaryTopAction
        self.transitionNamespace = transitionNamespace
        self.isInteractive = isInteractive
        self.showsTopActions = showsTopActions
        self.showsImageLoadingSkeleton = showsImageLoadingSkeleton
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
        VStack(alignment: .leading, spacing: 14) {
            DiscoverRemoteRecipeImage(
                recipe: recipe,
                transitionContext: transitionContext,
                showsLoadingSkeleton: showsImageLoadingSkeleton
            )
                .frame(maxWidth: .infinity)
                .frame(height: 188)
                .clipped()

            VStack(alignment: .leading, spacing: 8) {
                SleeRecipeCardTitleText(
                    recipe.displayTitle,
                    size: 22,
                    color: OunjePalette.primaryText
                )
                .lineLimit(2)
                .minimumScaleFactor(0.84)
                .frame(maxWidth: .infinity, minHeight: 42, maxHeight: 42, alignment: .topLeading)
                .modifier(RecipeTitleTransitionModifier(transitionContext: transitionContext))

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
    @StateObject private var loader = DiscoverRecipeImageLoader()
    @State private var shimmerOffset: CGFloat = -1.2

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
                if showsLoadingSkeleton {
                    MealPrepLoadingArtworkBlock(shimmerOffset: shimmerOffset)
                } else {
                    ProgressView()
                        .tint(OunjePalette.accent)
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
                .font(.system(size: 56))
            Text(recipe.filterLabel)
                .biroHeaderFont(13)
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
