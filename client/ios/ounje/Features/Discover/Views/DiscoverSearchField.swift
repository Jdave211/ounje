import SwiftUI

struct CompactDiscoverSearchField: View {
    @Binding var text: String
    let onSubmitSearch: () -> Void

    @FocusState private var isFocused: Bool
    @State private var placeholderIndex = Int.random(in: 0..<DiscoverSearchPlaceholderPrompts.values.count)

    private var placeholder: String {
        DiscoverSearchPlaceholderPrompts.values[
            min(max(placeholderIndex, 0), DiscoverSearchPlaceholderPrompts.values.count - 1)
        ]
    }

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onSubmitSearch) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(OunjePalette.secondaryText)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            TextField(placeholder, text: $text)
                .textInputAutocapitalization(.never)
                .disableAutocorrection(true)
                .submitLabel(.search)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(OunjePalette.primaryText)
                .focused($isFocused)
                .onSubmit(onSubmitSearch)

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(OunjePalette.secondaryText.opacity(0.75))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(OunjePalette.surface.opacity(0.96))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(OunjePalette.stroke, lineWidth: 1)
                )
        )
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 4_800_000_000)
                guard !Task.isCancelled else { return }
                guard text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !isFocused else { continue }
                await MainActor.run {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        placeholderIndex = (placeholderIndex + 1) % DiscoverSearchPlaceholderPrompts.values.count
                    }
                }
            }
        }
    }
}

enum DiscoverSearchPlaceholderPrompts {
    static let values: [String] = [
        "Search recipes",
        "Search chicken bowls",
        "Search salmon dinner",
        "Search veggie pasta",
        "Search shrimp tacos",
        "Search turkey chili",
        "Search tofu stir fry",
        "Search cozy soups",
        "Search breakfast wraps",
        "Search lunch salads",
        "Search rice bowls",
        "Search sheet pan meals",
        "Search pasta bakes",
        "Search air fryer ideas",
        "Search one-pot dinners",
        "Search family meals",
        "Search high protein",
        "Search meal prep lunches",
        "Search quick breakfasts",
        "Search snacks",
        "Search desserts",
        "Search smoothies",
        "Search hot tea for winter",
        "Search rainy day soup",
        "Search sunny picnic food",
        "Search cozy Sunday dinner",
        "Search late night noodles",
        "Search food for Nigerian potluck",
        "Search jollof sides",
        "Search Caribbean cookout",
        "Search Korean comfort food",
        "Search Mexican weeknight",
        "Search Mediterranean lunch",
        "Search Japanese breakfast",
        "Search Indian dinner",
        "Search Southern brunch",
        "Search French dessert",
        "Search game day food",
        "Search date night pasta",
        "Search movie night snacks",
        "Search gym day dinner",
        "Search sick day soup",
        "Search under 15 minutes",
        "Search under 30 minutes",
        "Search cheap dinner",
        "Search surprise me",
        "Search no dishes please",
        "Search fridge cleanout",
        "Search low effort",
        "Search spicy and sweet",
        "Search something crispy",
        "Search saucy noodles",
        "Search no oven",
        "Search no dairy",
        "Search vegetarian dinner",
        "Search freezer friendly"
    ]
}
