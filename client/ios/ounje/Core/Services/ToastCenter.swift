import SwiftUI
import Foundation

struct AppToast: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let subtitle: String?
    let systemImage: String
    let thumbnailURLString: String?
    let destination: AppToastDestination?
    let actionTitle: String?
    let action: (() -> Void)?

    static func == (lhs: AppToast, rhs: AppToast) -> Bool {
        lhs.id == rhs.id
    }
}

enum AppToastDestination: Hashable {
    case recipe(DiscoverRecipeCardData)
    case recipeImportQueue(SharedRecipeImportQueueTab)
    case appTab(AppTab)
}

@MainActor
final class AppToastCenter: ObservableObject {
    @Published var toast: AppToast?

    private var dismissTask: Task<Void, Never>?

    func showSavedRecipe(_ recipe: DiscoverRecipeCardData) {
        showSavedRecipe(
            title: recipe.title,
            thumbnailURLString: recipe.imageURLString ?? recipe.heroImageURLString,
            destination: .recipe(recipe)
        )
    }

    func showSavedRecipe(title: String, thumbnailURLString: String? = nil) {
        showSavedRecipe(title: title, thumbnailURLString: thumbnailURLString, destination: nil)
    }

    func showSavedRecipe(
        title: String,
        thumbnailURLString: String? = nil,
        destination: AppToastDestination?
    ) {
        show(
            title: "Saved",
            subtitle: title,
            systemImage: "bookmark.fill",
            thumbnailURLString: thumbnailURLString,
            destination: destination
        )
    }

    func showUnsavedRecipe(_ recipe: DiscoverRecipeCardData) {
        showUnsavedRecipe(
            title: recipe.title,
            thumbnailURLString: recipe.imageURLString ?? recipe.heroImageURLString,
            destination: .recipe(recipe)
        )
    }

    func showUnsavedRecipe(title: String, thumbnailURLString: String? = nil) {
        showUnsavedRecipe(title: title, thumbnailURLString: thumbnailURLString, destination: nil)
    }

    func showUnsavedRecipe(
        title: String,
        thumbnailURLString: String? = nil,
        destination: AppToastDestination?,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) {
        show(
            title: "Removed from saved",
            subtitle: title,
            systemImage: "bookmark.slash.fill",
            thumbnailURLString: thumbnailURLString,
            destination: destination,
            actionTitle: actionTitle,
            action: action
        )
    }

    func show(
        title: String,
        subtitle: String? = nil,
        systemImage: String = "checkmark.circle.fill",
        thumbnailURLString: String? = nil,
        destination: AppToastDestination? = nil,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) {
        dismissTask?.cancel()
        withAnimation(.spring(response: 0.36, dampingFraction: 0.82)) {
            toast = AppToast(
                title: title,
                subtitle: subtitle,
                systemImage: systemImage,
                thumbnailURLString: thumbnailURLString,
                destination: destination,
                actionTitle: actionTitle,
                action: action
            )
        }

        dismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                withAnimation(.spring(response: 0.36, dampingFraction: 0.92)) {
                    self.toast = nil
                }
            }
        }
    }

    func dismiss() {
        dismissTask?.cancel()
        dismissTask = nil
        withAnimation(.spring(response: 0.36, dampingFraction: 0.92)) {
            toast = nil
        }
    }
}

struct AppToastBanner: View {
    let toast: AppToast
    let onTap: (() -> Void)?

    private var thumbnailURL: URL? {
        guard let raw = toast.thumbnailURLString?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        return URL(string: raw)
    }

    var body: some View {
        content
    }

    private var content: some View {
        HStack(spacing: 10) {
            toastMainContent
                .contentShape(Rectangle())
                .onTapGesture {
                    onTap?()
                }

            if let actionTitle = toast.actionTitle, let action = toast.action {
                Button {
                    action()
                } label: {
                    Text(actionTitle)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(OunjePalette.softCream)
                        .padding(.horizontal, 2)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(OunjePalette.panel.opacity(0.96))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.white.opacity(0.10), lineWidth: 1)
                )
        )
        .shadow(color: .black.opacity(0.12), radius: 12, y: 5)
    }

    private var toastMainContent: some View {
        HStack(spacing: 10) {
            Group {
                if let thumbnailURL {
                    AsyncImage(url: thumbnailURL) { phase in
                        switch phase {
                        case .success(let image):
                            image
                                .resizable()
                                .scaledToFill()
                        default:
                            toastFallbackBadge
                        }
                    }
                } else {
                    toastFallbackBadge
                }
            }
            .frame(width: 30, height: 30)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(toast.title)
                    .font(.custom("Slee_handwritting-Regular", size: 16))
                    .tracking(0.05)
                    .foregroundStyle(OunjePalette.primaryText)
                    .lineLimit(1)

                if let subtitle = toast.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 11.5, weight: .medium, design: .rounded))
                        .foregroundStyle(OunjePalette.secondaryText)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            if toast.actionTitle == nil, toast.destination != nil {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(OunjePalette.secondaryText.opacity(0.82))
            }
        }
    }

    private var toastFallbackBadge: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(OunjePalette.surface.opacity(0.96))

            Image(systemName: toast.systemImage)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(OunjePalette.softCream)
        }
    }
}
