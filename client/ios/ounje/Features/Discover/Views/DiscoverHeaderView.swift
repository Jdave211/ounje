import SwiftUI

struct DiscoverHeaderView: View {
    @Binding var searchText: String
    let onSubmitSearch: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 3) {
                BiroScriptDisplayText("Discover", size: 31, color: OunjePalette.primaryText)
                Text("Find your next meal")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(OunjePalette.secondaryText)
            }

            CompactDiscoverSearchField(
                text: $searchText,
                onSubmitSearch: onSubmitSearch
            )
        }
        .padding(.horizontal, OunjeLayout.screenHorizontalPadding)
        .padding(.top, 14)
        .padding(.bottom, 14)
    }
}
